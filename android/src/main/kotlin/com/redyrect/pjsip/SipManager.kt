package com.redyrect.pjsip

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper

/** 'disabled'|'optional'|'mandatory' -> pjsip use_srtp; -1 = unspecified. */
fun srtpPolicyToPjsip(policy: String?): Int = when (policy?.lowercase()) {
    "disabled" -> 0
    "optional" -> 1
    "mandatory" -> 2
    else -> -1
}

data class SipConfig(
    val server: String,
    val port: Int,
    val username: String,
    val password: String,
    val domain: String,
    val transport: String,
    val proxy: String? = null,
    /** 'disabled'|'optional'|'mandatory'. null leaves pjsua's default. */
    val srtpPolicy: String? = null
)

/**
 * Wrapper around PJSIP via JNI.
 * All pjsua calls are dispatched to a dedicated HandlerThread.
 */
class SipManager(private val context: Context) {

    companion object {
        /** How long a push's call id is expected before its INVITE is presumed lost. */
        const val EXPECT_INVITE_MS = 30_000L
        /** How long an answer waits for an INVITE still in flight. */
        const val ANSWER_WAIT_MS = 10_000L
    }

    interface Listener {
        fun onRegistrationStateChanged(state: String, reason: String?)
        fun onCallStateChanged(callId: String, state: String, remoteUri: String?)
        fun onIncomingCall(callId: String, remoteUri: String, callerName: String?)
    }

    var listener: Listener? = null
    var registrationState: String = "unregistered"
        private set

    val isRegistered: Boolean get() = registrationState == "registered"

    /** The one way registration state changes: stored and reported
     *  together, on the main thread, so `registrationState` can never
     *  contradict the last event. */
    private fun setRegistrationState(state: String, reason: String? = null) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { setRegistrationState(state, reason) }
            return
        }
        registrationState = state
        listener?.onRegistrationStateChanged(state, reason)
    }

    private var config: SipConfig? = null

    /** Maps pjsua call_id (Int) -> plugin callId string */
    private val callMap = mutableMapOf<Int, String>()
    /** Reverse map: plugin callId string -> pjsua call_id */
    private val reverseCallMap = mutableMapOf<String, Int>()
    private var callIdCounter = 0

    /** Last-known snapshot per live plugin callId, for client-side call
     *  recovery after a webview reload. The native bridge pushes state
     *  rather than exposing a call-info getter, so we maintain this
     *  alongside the same funnels that already drive state callbacks. */
    private data class ActiveCallSnapshot(
        val state: String,
        val remoteUri: String?,
        val callerName: String?,
    )
    private val activeCalls = mutableMapOf<String, ActiveCallSnapshot>()

    /**
     * The one place a pjsip call id becomes a plugin-facing call id.
     *
     * pjsip does not guarantee that onIncomingCall arrives before the first
     * onCallState for the same call, so both callbacks route through here and
     * whichever runs first allocates. Every later event for that pjsip call
     * resolves to the same string, which is what CallConnectionService and
     * updateCallDisplay key on.
     */
    @Synchronized
    private fun pluginIdFor(pjCallId: Int): String =
        callMap.getOrPut(pjCallId) {
            callIdCounter++
            val allocated = "android-call-$callIdCounter"
            reverseCallMap[allocated] = pjCallId
            allocated
        }

    /** Give pjsip call [pjCallId] the id [id] — the PBX call id an INVITE
     *  carried — replacing one a state event may have allocated first. */
    @Synchronized
    private fun bindPluginId(pjCallId: Int, id: String): String {
        callMap[pjCallId]?.let { old ->
            if (old != id) {
                reverseCallMap.remove(old)
                activeCalls.remove(old)?.let { activeCalls[id] = it }
            }
        }
        callMap[pjCallId] = id
        reverseCallMap[id] = pjCallId
        return id
    }

    /** PBX call ids a push announced whose INVITE hasn't arrived. Main thread. */
    private val expected = mutableSetOf<String>()
    private class PendingAnswer(val callback: (Exception?) -> Unit, val timeout: Runnable)
    /** Answers requested before the call's INVITE arrived. Main thread. */
    private val pendingAnswers = mutableMapOf<String, PendingAnswer>()

    private var pjsuaStarted = false
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dedicated thread for all PJSIP native calls */
    private val pjThread = HandlerThread("pjsip-worker").also { it.start() }
    private val pjHandler = Handler(pjThread.looper)

    /** JNI callback — invoked from native PJSIP threads */
    private val nativeCallback = object : PjsipNative.Callback {
        override fun onRegState(state: String, reason: String?) {
            setRegistrationState(state, reason)
        }

        override fun onIncomingCall(pjCallId: Int, remoteUri: String, callUuid: String) {
            val pluginCallId =
                if (callUuid.isNotBlank()) bindPluginId(pjCallId, callUuid) else pluginIdFor(pjCallId)

            val callerName = extractDisplayName(remoteUri)
            activeCalls[pluginCallId] =
                ActiveCallSnapshot("incoming", remoteUri, callerName)
            mainHandler.post {
                expected.remove(pluginCallId)
                listener?.onIncomingCall(pluginCallId, remoteUri, callerName)
                pendingAnswers.remove(pluginCallId)?.let { pending ->
                    mainHandler.removeCallbacks(pending.timeout)
                    pjsipLog("[SipManager] INVITE for $pluginCallId arrived — completing the answer requested before it")
                    answerCall(pluginCallId, pending.callback)
                }
            }
        }

        override fun onCallState(pjCallId: Int, state: String, remoteUri: String) {
            // Reuse the call's existing identity, allocating one if this event
            // beat onIncomingCall. Fabricating "unknown-$pjCallId" here used to
            // give a single call TWO identities — the phantom that arrived
            // first and the real one moments later — and consumers latched
            // onto the phantom, which has no ConnectionService behind it.
            // A call that already ended has no id to report against; giving it
            // a new one made the app show a call that "failed".
            if (state == "disconnected" && !callMap.containsKey(pjCallId)) {
                pjsipLog("[SipManager] DISCONNECTED for pjsip call $pjCallId, which is no longer tracked — ignored")
                return
            }
            val pluginCallId = pluginIdFor(pjCallId)

            if (state == "disconnected") {
                callMap.remove(pjCallId)
                reverseCallMap.remove(pluginCallId)
                activeCalls.remove(pluginCallId)
            } else {
                activeCalls[pluginCallId] = ActiveCallSnapshot(
                    state,
                    remoteUri.ifEmpty { activeCalls[pluginCallId]?.remoteUri },
                    activeCalls[pluginCallId]?.callerName,
                )
            }

            mainHandler.post {
                listener?.onCallStateChanged(pluginCallId, state, remoteUri)
            }
        }
    }

    // Registration

    fun register(config: SipConfig, callback: (Exception?) -> Unit) {
        this.config = config
        setRegistrationState("registering")

        pjHandler.post {
            try {
                if (!pjsuaStarted) {
                    var status = PjsipNative.init(nativeCallback)
                    if (status != 0) throw Exception("pjsua init failed: $status")

                    val transportType = when (config.transport.lowercase()) {
                        "tcp" -> 1
                        "tls", "wss" -> 2
                        else -> 0  // UDP
                    }
                    status = PjsipNative.createTransport(transportType)
                    if (status != 0) throw Exception("transport create failed: $status")

                    status = PjsipNative.start()
                    if (status != 0) throw Exception("pjsua start failed: $status")

                    pjsuaStarted = true
                }

                val sipUri = "sip:${config.username}@${config.domain}"
                val regUri = "sip:${config.server}:${config.port}"
                val proxy = config.proxy?.let {
                    if (it.isNotEmpty()) it else null
                }

                val status = PjsipNative.addAccount(sipUri, regUri, "*",
                    config.username, config.password, proxy,
                    srtpPolicyToPjsip(config.srtpPolicy))
                if (status != 0) throw Exception("account add failed: $status")

                mainHandler.post { callback(null) }
            } catch (e: Exception) {
                mainHandler.post {
                    setRegistrationState("failed", e.message)
                    callback(e)
                }
            }
        }
    }

    fun unregister(callback: (Exception?) -> Unit) {
        pjHandler.post {
            PjsipNative.removeAccount()
            if (pjsuaStarted) {
                PjsipNative.destroy()
                pjsuaStarted = false
            }

            mainHandler.post {
                callMap.clear()
                reverseCallMap.clear()
                activeCalls.clear()
                setRegistrationState("unregistered")
                callback(null)
            }
        }
    }

    // Calls

    /** Place a call. Throws with PJSIP's own reason ("Invalid Request
     *  URI", …) so the app can say why, instead of a bare failure. */
    fun makeCall(uri: String): String {
        if (!pjsuaStarted) throw IllegalStateException("Not registered: the phone has no SIP account yet")

        var result = 0
        var resultCallId: String? = null
        val latch = java.util.concurrent.CountDownLatch(1)

        pjHandler.post {
            result = PjsipNative.makeCall(uri)
            if (result >= 0) {
                // Same reason as the callbacks: pjsip can report state for
                // this call before makeCall returns, so allocating a fresh id
                // here would create a second identity for one call.
                resultCallId = pluginIdFor(result)
            }
            latch.countDown()
        }

        latch.await()

        val callId = resultCallId
            ?: throw IllegalStateException("Cannot call $uri: ${PjsipNative.statusText(-result)}")
        activeCalls[callId] = ActiveCallSnapshot("calling", uri, null)
        listener?.onCallStateChanged(callId, "calling", uri)
        return callId
    }

    /** Snapshot every call still being tracked, for client-side
     *  recovery after a webview reload. */
    fun getActiveCalls(): List<Map<String, Any?>> =
        activeCalls.map { (callId, c) ->
            buildMap<String, Any?> {
                put("callId", callId)
                put("state", c.state)
                c.remoteUri?.let { put("remoteUri", it) }
                c.callerName?.let { put("callerName", it) }
            }
        }

    /** A push announced call [callUuid]; its INVITE should follow. Main thread. */
    fun expectIncomingCall(callUuid: String) {
        expected.add(callUuid)
        mainHandler.postDelayed({ expected.remove(callUuid) }, EXPECT_INVITE_MS)
    }

    /** Re-REGISTER now: after the phone slept the PBX's contact for us may be dead. */
    fun renewRegistration() {
        pjHandler.post {
            val status = PjsipNative.renewRegistration()
            if (status != 0) pjsipLog("[SipManager] renewRegistration failed: ${PjsipNative.statusText(status)}")
        }
    }

    /** Answer [callId]. For a call a push announced whose INVITE is still on
     *  its way, the answer waits for it, up to [ANSWER_WAIT_MS]. Main thread. */
    fun answerCall(callId: String, callback: (Exception?) -> Unit) {
        val pjCallId = reverseCallMap[callId]
        if (pjCallId == null) {
            if (callId !in expected) {
                callback(Exception("Call not found"))
                return
            }
            pjsipLog("[SipManager] answer $callId: INVITE not here yet — waiting up to ${ANSWER_WAIT_MS / 1000}s")
            val timeout = Runnable {
                pendingAnswers.remove(callId)?.callback?.invoke(
                    Exception("The call did not arrive within ${ANSWER_WAIT_MS / 1000}s of answering"),
                )
            }
            pendingAnswers[callId] = PendingAnswer(callback, timeout)
            mainHandler.postDelayed(timeout, ANSWER_WAIT_MS)
            return
        }

        pjHandler.post {
            val status = PjsipNative.answerCall(pjCallId, 200)
            mainHandler.post {
                if (status == 0) callback(null)
                else callback(Exception("answer failed: $status"))
            }
        }
    }

    /** End [callId]. The call stays mapped until PJSIP reports DISCONNECTED,
     *  which clears it and reports it once — as on iOS. Clearing it here and
     *  reporting "disconnected" early left PJSIP's own DISCONNECTED with no
     *  call to find, and it invented a second id the app showed as failed. */
    fun hangupCall(callId: String) {
        val pjCallId = reverseCallMap[callId] ?: run {
            pjsipLog("[SipManager] hangup $callId: no SIP call by that id — nothing was ended")
            return
        }
        pjHandler.post { PjsipNative.hangupCall(pjCallId) }
    }

    // In-call controls

    fun holdCall(callId: String, hold: Boolean) {
        val pjCallId = reverseCallMap[callId] ?: return
        pjHandler.post {
            if (hold) PjsipNative.setHold(pjCallId)
            else PjsipNative.reinvite(pjCallId)
        }
    }

    fun muteCall(callId: String, mute: Boolean) {
        val pjCallId = reverseCallMap[callId] ?: return
        pjHandler.post {
            PjsipNative.adjustTxLevel(pjCallId, if (mute) 0f else 1f)
        }
    }

    fun sendDtmf(callId: String, digit: String) {
        val pjCallId = reverseCallMap[callId] ?: return
        pjHandler.post { PjsipNative.dialDtmf(pjCallId, digit) }
    }

    fun transferCall(callId: String, target: String) {
        val pjCallId = reverseCallMap[callId] ?: return
        pjHandler.post { PjsipNative.transferCall(pjCallId, target) }
    }

    fun setAudioRoute(route: String) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        when (route) {
            "speaker" -> {
                audioManager.isSpeakerphoneOn = true
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            }
            "earpiece" -> {
                audioManager.isSpeakerphoneOn = false
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            }
            "bluetooth" -> {
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true
            }
        }
    }


    // Helpers

    private fun extractDisplayName(sipUri: String): String? {
        val quoteStart = sipUri.indexOf('"')
        if (quoteStart < 0) return null
        val quoteEnd = sipUri.indexOf('"', quoteStart + 1)
        if (quoteEnd < 0) return null
        val name = sipUri.substring(quoteStart + 1, quoteEnd)
        return name.ifEmpty { null }
    }
}
