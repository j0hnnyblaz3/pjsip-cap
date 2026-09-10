package com.redyrect.pjsip

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log

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
        private const val TAG = "PjsipSipManager"
    }

    interface Listener {
        fun onRegistrationStateChanged(state: String, reason: String?)
        fun onCallStateChanged(callId: String, state: String, remoteUri: String?)
        fun onIncomingCall(callId: String, remoteUri: String, callerName: String?)
    }

    var listener: Listener? = null
    var registrationState: String = "unregistered"
        private set

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

    private var pjsuaStarted = false
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dedicated thread for all PJSIP native calls */
    private val pjThread = HandlerThread("pjsip-worker").also { it.start() }
    private val pjHandler = Handler(pjThread.looper)

    /** JNI callback — invoked from native PJSIP threads */
    private val nativeCallback = object : PjsipNative.Callback {
        override fun onRegState(state: String, reason: String?) {
            mainHandler.post {
                registrationState = state
                listener?.onRegistrationStateChanged(state, reason)
            }
        }

        override fun onIncomingCall(pjCallId: Int, remoteUri: String) {
            val pluginCallId = pluginIdFor(pjCallId)

            val callerName = extractDisplayName(remoteUri)
            activeCalls[pluginCallId] =
                ActiveCallSnapshot("incoming", remoteUri, callerName)
            mainHandler.post {
                listener?.onIncomingCall(pluginCallId, remoteUri, callerName)
            }
        }

        override fun onCallState(pjCallId: Int, state: String, remoteUri: String) {
            // Reuse the call's existing identity, allocating one if this event
            // beat onIncomingCall. Fabricating "unknown-$pjCallId" here used to
            // give a single call TWO identities — the phantom that arrived
            // first and the real one moments later — and consumers latched
            // onto the phantom, which has no ConnectionService behind it.
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
        listener?.onRegistrationStateChanged("registering", null)

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
                    registrationState = "failed"
                    listener?.onRegistrationStateChanged("failed", e.message)
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
                registrationState = "unregistered"
                callMap.clear()
                reverseCallMap.clear()
                activeCalls.clear()
                listener?.onRegistrationStateChanged("unregistered", null)
                callback(null)
            }
        }
    }

    // Calls

    fun makeCall(uri: String): String? {
        if (!pjsuaStarted) return null

        var resultCallId: String? = null
        val latch = java.util.concurrent.CountDownLatch(1)

        pjHandler.post {
            val pjCallId = PjsipNative.makeCall(uri)
            if (pjCallId >= 0) {
                // Same reason as the callbacks: pjsip can report state for
                // this call before makeCall returns, so allocating a fresh id
                // here would create a second identity for one call.
                resultCallId = pluginIdFor(pjCallId)
            }
            latch.countDown()
        }

        latch.await()

        resultCallId?.let {
            activeCalls[it] = ActiveCallSnapshot("calling", uri, null)
            listener?.onCallStateChanged(it, "calling", uri)
        }
        return resultCallId
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

    fun answerCall(callId: String, callback: (Exception?) -> Unit) {
        val pjCallId = reverseCallMap[callId]
        if (pjCallId == null) {
            callback(Exception("Call not found"))
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

    fun hangupCall(callId: String) {
        val pjCallId = reverseCallMap[callId] ?: return
        pjHandler.post { PjsipNative.hangupCall(pjCallId) }
        callMap.remove(pjCallId)
        reverseCallMap.remove(callId)
        activeCalls.remove(callId)
        listener?.onCallStateChanged(callId, "disconnected", null)
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

    /** Push pre-INVITE hint. Called from PushService when an FCM VoIP
     *  push announces an incoming call is imminent — i.e. a SIP INVITE
     *  is about to land on the registered transport. PushService also
     *  reports the call to ConnectionService independently, so the
     *  system call UI rings without waiting on the SIP layer.
     *
     *  Phase 3 work fills this in: re-acquire the network, ensure the
     *  account is registered, and (optionally) optimistically register
     *  the inbound call against ConnectionService's existing connection
     *  so the eventual PJSIP `onIncomingCall` from JNI maps cleanly. For
     *  the Phase 1 outbound-only smoke test this is never reached at
     *  runtime; PushService.onMessageReceived only runs when a real
     *  push arrives, which requires google-services.json + PBX-side
     *  push delivery to both be live. The stub exists so the plugin
     *  compiles and the Phase 3 contract is documented in code. */
    fun handleIncomingCall(remoteUri: String, callerName: String?) {
        Log.i(
            TAG,
            "handleIncomingCall (push pre-INVITE): $remoteUri ($callerName) — " +
                "stub; Phase 3 wires this to wake the SIP stack",
        )
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
