package com.redyrect.pjsip

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

data class SipConfig(
    val server: String,
    val port: Int,
    val username: String,
    val password: String,
    val domain: String,
    val transport: String,
    val proxy: String? = null  // outbound proxy / SBC URI
)

/**
 * Wrapper around PJSIP native library.
 *
 * NOTE: PJSIP must be linked via prebuilt .aar or built from source with NDK.
 * The method bodies below are placeholders that map 1:1 to pjsua2 Java API.
 * They will compile once the pjsip .aar is added to the libs/ directory.
 */
class SipManager(private val context: Context) {

    interface Listener {
        fun onRegistrationStateChanged(state: String, reason: String?)
        fun onCallStateChanged(callId: String, state: String, remoteUri: String?)
        fun onIncomingCall(callId: String, remoteUri: String, callerName: String?)
    }

    var listener: Listener? = null
    var registrationState: String = "unregistered"
        private set

    private var config: SipConfig? = null
    private val activeCalls = mutableMapOf<String, String>()
    private var callIdCounter = 0
    private val mainHandler = Handler(Looper.getMainLooper())

    // Registration

    fun register(config: SipConfig, callback: (Exception?) -> Unit) {
        this.config = config
        listener?.onRegistrationStateChanged("registering", null)

        // TODO: Initialize PJSIP endpoint and create account
        // Endpoint.instance().libCreate()
        // Endpoint.instance().libInit(epConfig)
        // Endpoint.instance().transportCreate(...)
        // Endpoint.instance().libStart()
        // account.create(accountConfig)
        //
        // If config.proxy is set, configure outbound proxy on the account:
        //   accountConfig.sipConfig.proxies = StringVector().apply { add(config.proxy) }

        mainHandler.post {
            registrationState = "registered"
            listener?.onRegistrationStateChanged("registered", null)
            callback(null)
        }
    }

    fun unregister(callback: (Exception?) -> Unit) {
        // TODO: account.delete() / Endpoint.instance().libDestroy()
        registrationState = "unregistered"
        activeCalls.clear()
        listener?.onRegistrationStateChanged("unregistered", null)
        callback(null)
    }

    // Calls

    fun makeCall(uri: String): String? {
        if (config == null) return null

        callIdCounter++
        val callId = "android-call-$callIdCounter"

        // TODO: Call().makeCall(account, uri, callOpParam)
        activeCalls[callId] = uri
        listener?.onCallStateChanged(callId, "calling", uri)
        return callId
    }

    fun answerCall(callId: String, callback: (Exception?) -> Unit) {
        if (!activeCalls.containsKey(callId)) {
            callback(Exception("Call not found"))
            return
        }

        // TODO: call.answer(CallOpParam(true).apply { statusCode = 200 })
        listener?.onCallStateChanged(callId, "confirmed", null)
        callback(null)
    }

    fun hangupCall(callId: String) {
        if (!activeCalls.containsKey(callId)) return

        // TODO: call.hangup(CallOpParam())
        activeCalls.remove(callId)
        listener?.onCallStateChanged(callId, "disconnected", null)
    }

    // In-call controls

    fun holdCall(callId: String, hold: Boolean) {
        if (!activeCalls.containsKey(callId)) return
        // TODO: if (hold) call.setHold(CallOpParam()) else call.reinvite(CallOpParam())
        listener?.onCallStateChanged(callId, if (hold) "held" else "confirmed", null)
    }

    fun muteCall(callId: String, mute: Boolean) {
        if (!activeCalls.containsKey(callId)) return
        // TODO: Adjust audio media rx/tx level
    }

    fun sendDtmf(callId: String, digit: String) {
        if (!activeCalls.containsKey(callId)) return
        // TODO: call.dialDtmf(digit)
    }

    fun transferCall(callId: String, target: String) {
        if (!activeCalls.containsKey(callId)) return
        // TODO: call.xfer(target, CallOpParam())
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

    // PJSIP callbacks (to be wired from native callbacks)

    fun handleIncomingCall(remoteUri: String, callerName: String?) {
        callIdCounter++
        val callId = "android-call-$callIdCounter"
        activeCalls[callId] = remoteUri
        listener?.onIncomingCall(callId, remoteUri, callerName)
    }

    fun handleCallStateChange(callId: String, state: String) {
        if (state == "disconnected") {
            activeCalls.remove(callId)
        }
        listener?.onCallStateChanged(callId, state, null)
    }

    fun handleRegistrationStateChange(state: String, reason: String?) {
        registrationState = state
        listener?.onRegistrationStateChanged(state, reason)
    }
}
