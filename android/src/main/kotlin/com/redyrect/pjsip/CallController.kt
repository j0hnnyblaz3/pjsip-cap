package com.redyrect.pjsip

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

/** Where the call controller sends events for the app. `PjsipPlugin`
 *  implements it by forwarding to Capacitor's `notifyListeners`. */
interface CallEventSink {
    fun emit(event: String, data: Map<String, Any?>)
}

/**
 * The one owner of a call's lifecycle on Android.
 *
 * - The app's requests and Telecom's callbacks (system UI, headset button)
 *   answer, end and hold through the same functions here, so the Telecom
 *   connection and the SIP call can never disagree.
 * - SIP events are mirrored onto the Telecom connection and emitted to the app.
 * - FCM pushes and incoming INVITEs are reported to Telecom.
 *
 * Each collaborator does one thing: `SipManager` SIP, `CallConnectionService`
 * Telecom (it creates connections and hands them here), `PushService` FCM,
 * `PjsipPlugin` the bridge to JS. A process-level object because Android, not
 * the plugin, creates the Telecom and FCM services.
 */
object CallController {
    var events: CallEventSink? = null

    private var appContext: Context? = null
    private var engine: SipManager? = null

    /** Telecom connections by plugin callId. */
    private val connections = mutableMapOf<String, CallConnectionService.SipConnection>()

    /** Start the SIP engine once per process. Idempotent: the plugin and the
     *  push service both call it, whichever runs first. */
    fun start(context: Context): SipManager {
        engine?.let { return it }
        val app = context.applicationContext
        appContext = app
        return SipManager(app).also { sip ->
            sip.listener = sipListener
            engine = sip
        }
    }

    private fun sip(): SipManager =
        engine ?: throw IllegalStateException("SIP is not started")

    // Registration

    val registrationState: String get() = engine?.registrationState ?: "unregistered"

    fun register(config: SipConfig, completion: (Exception?) -> Unit) =
        sip().register(config, completion)

    fun unregister(completion: (Exception?) -> Unit) = sip().unregister(completion)

    fun pushTokenUpdated(token: String) {
        events?.emit("pushTokenUpdated", mapOf("token" to token, "platform" to "fcm"))
    }

    // Calls

    /** Place a call and report it to Telecom. */
    fun makeCall(uri: String): String? {
        val callId = sip().makeCall(uri) ?: return null
        reportToTelecom(callId) { telecom, handle ->
            telecom.placeCall(telecomAddress(uri), Bundle().apply {
                putString("callId", callId)
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
            })
        }
        return callId
    }

    /** The one way a call is answered. */
    fun answer(callId: String, completion: (Exception?) -> Unit) {
        val sip = engine ?: run {
            pjsipLog("[CallController] answer $callId: SIP is not started")
            completion(IllegalStateException("SIP is not started"))
            return
        }
        val connection = connections[callId]
        if (connection == null) {
            pjsipLog("[CallController] answer $callId: no Telecom connection — answering the SIP call only")
        }
        pjsipLog("[CallController] answer $callId")
        sip.answerCall(callId) { error ->
            if (error == null) {
                connection?.setActive()
            } else {
                pjsipLog("[CallController] answer $callId failed: ${error.message}")
            }
            completion(error)
        }
    }

    /** The one way a call is ended from this side. */
    fun hangup(callId: String, cause: Int = DisconnectCause.LOCAL) {
        pjsipLog("[CallController] hangup $callId (cause $cause)")
        closeConnection(callId, cause)
        engine?.hangupCall(callId)
    }

    /** The one way a call is held or resumed. */
    fun hold(callId: String, hold: Boolean) {
        pjsipLog("[CallController] ${if (hold) "hold" else "resume"} $callId")
        connections[callId]?.let { if (hold) it.setOnHold() else it.setActive() }
        engine?.holdCall(callId, hold)
    }

    /** A self-managed Telecom call has no system mute; the app's is the only
     *  one, so it goes straight to SIP. */
    fun mute(callId: String, mute: Boolean) = sip().muteCall(callId, mute)

    fun sendDtmf(callId: String, digit: String) = sip().sendDtmf(callId, digit)
    fun transfer(callId: String, target: String) = sip().transferCall(callId, target)
    fun setAudioRoute(route: String) = sip().setAudioRoute(route)
    fun activeCalls(): List<Map<String, Any?>> = engine?.getActiveCalls() ?: emptyList()

    /** Update the caller name the system call UI shows, once the app has
     *  resolved the SIP handle to a real person. */
    fun updateCallDisplay(callId: String, displayName: String?) {
        connections[callId]?.setCallerDisplayName(displayName, TelecomManager.PRESENTATION_ALLOWED)
    }

    // Incoming pushes

    /** An FCM incoming-call push: Telecom rings now, the SIP engine wakes for
     *  the INVITE that follows. No JS event — the INVITE brings the call to
     *  the app with its SIP callId, as on iOS. */
    fun onIncomingPush(context: Context, callId: String, remoteUri: String, callerName: String?) {
        pjsipLog("[CallController] incoming push $callId from $remoteUri")
        start(context).handleIncomingCall(remoteUri, callerName)
        reportIncoming(callId, remoteUri, callerName)
    }

    // Telecom connections (CallConnectionService hands them here)

    fun attach(callId: String, connection: CallConnectionService.SipConnection) {
        connections[callId] = connection
    }

    private fun closeConnection(callId: String, cause: Int) {
        connections.remove(callId)?.let { connection ->
            connection.setDisconnected(DisconnectCause(cause))
            connection.destroy()
        }
    }

    // SIP engine events

    private val sipListener = object : SipManager.Listener {
        override fun onRegistrationStateChanged(state: String, reason: String?) {
            events?.emit("registrationStateChanged", mapOf("state" to state, "reason" to reason))
        }

        override fun onCallStateChanged(callId: String, state: String, remoteUri: String?) {
            events?.emit("callStateChanged", mapOf("callId" to callId, "state" to state, "remoteUri" to remoteUri))

            // Telecom follows the SIP state from this one place; it is the
            // copy the system call UI, audio routing and the ongoing-call
            // notification read. A call ended from this side has already
            // closed its connection, so this is a no-op then.
            when (state) {
                "confirmed" -> connections[callId]?.setActive()
                "disconnected" -> closeConnection(callId, DisconnectCause.REMOTE)
                else -> Unit
            }
        }

        override fun onIncomingCall(callId: String, remoteUri: String, callerName: String?) {
            reportIncoming(callId, remoteUri, callerName)
            events?.emit("incomingCall", mapOf("callId" to callId, "remoteUri" to remoteUri, "callerName" to callerName))
        }
    }

    private fun reportIncoming(callId: String, remoteUri: String, callerName: String?) {
        reportToTelecom(callId) { telecom, handle ->
            telecom.addNewIncomingCall(handle, Bundle().apply {
                putString("callId", callId)
                putString("remoteUri", remoteUri)
                callerName?.let { putString("callerName", it) }
            })
        }
    }

    // Telecom plumbing

    private fun reportToTelecom(callId: String, report: (TelecomManager, PhoneAccountHandle) -> Unit) {
        val context = appContext ?: run {
            pjsipLog("[CallController] $callId: not started — Telecom not told")
            return
        }
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val handle = PhoneAccountHandle(ComponentName(context, CallConnectionService::class.java), "pjsip_account")
        telecom.registerPhoneAccount(
            PhoneAccount.builder(handle, "PJSIP")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .addSupportedUriScheme(PhoneAccount.SCHEME_SIP)
                .build()
        )
        try {
            report(telecom, handle)
        } catch (e: SecurityException) {
            // Fail loud: a call Telecom does not know has no system UI and
            // no audio focus, which is a broken call, not a quiet one.
            pjsipLog("[CallController] $callId: Telecom refused the call: ${e.message}")
        }
    }

    /** The address Telecom shows for a call: the SIP URI itself, taken out of
     *  a From header (`"Name" <sip:user@host>`) when it is one. Prefixing
     *  "sip:" to what was already a URI gave Telecom `sip:sip:…`. */
    fun telecomAddress(uri: String): Uri {
        val inner = (Regex("<([^>]+)>").find(uri)?.groupValues?.get(1) ?: uri).trim()
        val isUri = inner.startsWith("sip:", ignoreCase = true) || inner.startsWith("sips:", ignoreCase = true)
        return Uri.parse(if (isUri) inner else "sip:$inner")
    }

    internal val connectionCapabilities =
        Connection.CAPABILITY_HOLD or Connection.CAPABILITY_SUPPORT_HOLD or Connection.CAPABILITY_MUTE
}
