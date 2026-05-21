package com.redyrect.pjsip

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log

data class SipConfig(
    val server: String,
    val port: Int,
    val username: String,
    val password: String,
    val domain: String,
    val transport: String,
    val proxy: String? = null
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
            callIdCounter++
            val pluginCallId = "android-call-$callIdCounter"
            callMap[pjCallId] = pluginCallId
            reverseCallMap[pluginCallId] = pjCallId

            val callerName = extractDisplayName(remoteUri)
            activeCalls[pluginCallId] =
                ActiveCallSnapshot("incoming", remoteUri, callerName)
            mainHandler.post {
                listener?.onIncomingCall(pluginCallId, remoteUri, callerName)
            }
        }

        override fun onCallState(pjCallId: Int, state: String, remoteUri: String) {
            val pluginCallId = callMap[pjCallId] ?: "unknown-$pjCallId"

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
                    config.username, config.password, proxy)
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
                callIdCounter++
                val pluginCallId = "android-call-$callIdCounter"
                callMap[pjCallId] = pluginCallId
                reverseCallMap[pluginCallId] = pjCallId
                resultCallId = pluginCallId
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
