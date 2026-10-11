package com.redyrect.pjsip

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
 * - FCM pushes and incoming INVITEs are reported to Telecom, once per call:
 *   a push and its INVITE share the PBX call id (`X-Redyrect-Call-UUID`).
 * - A push re-registers SIP from the saved login when the app isn't running.
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
    private var credentials: SipCredentialStore? = null
    private val main = Handler(Looper.getMainLooper())

    /** Telecom connections by plugin callId. */
    private val connections = mutableMapOf<String, CallConnectionService.SipConnection>()
    /** Calls reported to Telecom, so a push and its INVITE ring once. */
    private val reported = mutableSetOf<String>()
    /** Pushed calls whose INVITE hasn't arrived, with the give-up timer. */
    private val awaitingInvite = mutableMapOf<String, Runnable>()
    /** The caller name each push carried, for an INVITE without one. */
    private val pushedNames = mutableMapOf<String, String>()

    /** Every call event the app gets — see `CallLedger`. Main thread. */
    private val ledger = CallLedger { snapshot ->
        events?.emit("callUpdated", snapshot)
        refreshLive()
    }

    /** Told whether any call is up — ringing included — each time that
     *  changes. The plugin lets the app show over the lock screen only then.
     *  Main thread. */
    var onLiveChanged: ((Boolean) -> Unit)? = null
        set(value) {
            field = value
            value?.invoke(live)
        }
    private var live = false

    val hasLiveCalls: Boolean get() = live

    private fun refreshLive() {
        val now = reported.isNotEmpty() || connections.isNotEmpty() || ledger.active().isNotEmpty()
        if (now == live) return
        live = now
        onLiveChanged?.invoke(now)
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    /** Start the SIP engine once per process. Idempotent: the plugin and the
     *  push service both call it, whichever runs first. */
    fun start(context: Context): SipManager {
        engine?.let { return it }
        val app = context.applicationContext
        appContext = app
        credentials = SipCredentialStore(app)
        return SipManager(app).also { sip ->
            sip.listener = sipListener
            engine = sip
        }
    }

    private fun sip(): SipManager =
        engine ?: throw IllegalStateException("SIP is not started")

    // Registration

    val registrationState: String get() = engine?.registrationState ?: "unregistered"

    /** Register, keeping the login so a push can re-register while the app isn't running. */
    fun register(config: SipConfig, completion: (Exception?) -> Unit) =
        sip().register(config) { error ->
            if (error == null) credentials?.save(config)
            completion(error)
        }

    fun unregister(completion: (Exception?) -> Unit) {
        credentials?.clear()
        sip().unregister(completion)
    }

    fun pushTokenUpdated(token: String) {
        events?.emit("pushTokenUpdated", mapOf("token" to token, "platform" to "fcm"))
    }

    // Pushes

    /** Handle an FCM message if it is a PBX incoming-call push (the
     *  `domain::reach::IncomingCall` payload). Returns false for anything
     *  else, so the host can pass it on. Any thread. */
    fun onPushMessage(context: Context, data: Map<String, String>): Boolean {
        val callUuid = data["call_uuid"]?.takeIf { it.isNotBlank() } ?: return false
        val number = data["caller_id_number"].orEmpty()
        val name = data["caller_id_name"]?.takeIf { it.isNotBlank() }
        main.post { onIncomingPush(context, callUuid, number, name) }
        return true
    }

    /** Telecom rings now; SIP re-registers so the INVITE that follows reaches us. */
    private fun onIncomingPush(context: Context, callUuid: String, number: String, name: String?) {
        pjsipLog("[CallController] incoming push $callUuid from ${name ?: number}")
        val sip = start(context)
        sip.expectIncomingCall(callUuid)
        if (sip.isRegistered) {
            sip.renewRegistration()
        } else {
            val login = credentials?.load()
            if (login == null) {
                pjsipLog("[CallController] push $callUuid: no saved SIP login — the call cannot reach this phone until the app signs in")
                return
            }
            sip.register(login) { error ->
                if (error != null) pjsipLog("[CallController] push $callUuid: re-register failed: ${error.message}")
            }
        }
        name?.let { pushedNames[callUuid] = it }
        if (callUuid in reported) return
        reportIncoming(callUuid, number, name)
        val giveUp = Runnable {
            awaitingInvite.remove(callUuid)
            pjsipLog("[CallController] push $callUuid: no INVITE within ${SipManager.EXPECT_INVITE_MS / 1000}s — ending")
            closeConnection(callUuid, DisconnectCause.MISSED)
        }
        awaitingInvite[callUuid] = giveUp
        main.postDelayed(giveUp, SipManager.EXPECT_INVITE_MS)
    }

    // Calls

    /** Place a call and report it to Telecom. [displayName] is who the app
     *  is calling, for the call's snapshot and the system call UI. */
    fun makeCall(uri: String, displayName: String?): String {
        val callId = sip().makeCall(uri)
        onMain {
            ledger.open(callId, incoming = false, state = "calling", remoteUri = uri, callerName = displayName)
        }
        appContext?.let { CallService.start(it, callId, displayName ?: uri) }
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
        appContext?.let {
            CallNotifications.cancel(it, callId)
            // Now, while whoever asked to answer is on screen: Android lets a
            // call service start only then, and the call needs it for the
            // microphone once the app is off screen.
            CallService.start(it, callId, ledger.callerName(callId) ?: pushedNames[callId])
        }
        sip.answerCall(callId) { error ->
            if (error == null) {
                connection?.setActive()
            } else {
                pjsipLog("[CallController] answer $callId failed: ${error.message}")
                stopServiceIfIdle()
            }
            completion(error)
        }
    }

    /** The one way a call is ended from this side. */
    fun hangup(callId: String, cause: Int = DisconnectCause.LOCAL) {
        pjsipLog("[CallController] hangup $callId (cause $cause)")
        onMain { ledger.endingHere(callId) }
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
    /** Every live call, as the app's snapshots. Main thread, like the ledger. */
    fun activeCalls(): List<Map<String, Any?>> {
        if (Looper.myLooper() == Looper.getMainLooper()) return ledger.active()
        val latch = java.util.concurrent.CountDownLatch(1)
        var calls: List<Map<String, Any?>> = emptyList()
        main.post { calls = ledger.active(); latch.countDown() }
        latch.await()
        return calls
    }

    /** Update the caller name the system call UI shows, once the app has
     *  resolved the SIP handle to a real person. */
    fun updateCallDisplay(callId: String, displayName: String?) {
        connections[callId]?.setCallerDisplayName(displayName, TelecomManager.PRESENTATION_ALLOWED)
    }

    // Telecom connections (CallConnectionService hands them here)

    fun attach(callId: String, connection: CallConnectionService.SipConnection) {
        connections[callId] = connection
        refreshLive()
    }

    /** Telecom wants the incoming-call screen shown for [callId]. */
    fun showIncomingUi(callId: String, callerName: String) {
        val context = appContext ?: run {
            pjsipLog("[CallController] incoming call $callId: not started — no ringing screen")
            return
        }
        CallNotifications.showIncoming(context, callId, callerName)
    }

    /** The call service runs while any call is up. */
    private fun stopServiceIfIdle() {
        if (connections.isEmpty() && ledger.active().isEmpty()) appContext?.let { CallService.stop(it) }
    }

    private fun closeConnection(callId: String, cause: Int) {
        reported.remove(callId)
        pushedNames.remove(callId)
        awaitingInvite.remove(callId)?.let { main.removeCallbacks(it) }
        appContext?.let { CallNotifications.cancel(it, callId) }
        connections.remove(callId)?.let { connection ->
            connection.setDisconnected(DisconnectCause(cause))
            connection.destroy()
        }
        stopServiceIfIdle()
        refreshLive()
    }

    // SIP engine events

    private val sipListener = object : SipManager.Listener {
        override fun onRegistrationStateChanged(state: String, reason: String?) {
            events?.emit("registrationStateChanged", mapOf("state" to state, "reason" to reason))
        }

        override fun onCallStateChanged(
            callId: String, state: String, remoteUri: String?,
            incoming: Boolean, sipStatus: Int, sipReason: String?,
        ) {
            // Telecom follows the SIP state from this one place; it is the
            // copy the system call UI, audio routing and the ongoing-call
            // notification read. A call ended from this side has already
            // closed its connection, so closing it again is a no-op.
            when (state) {
                "disconnected" -> {
                    ledger.finish(callId, sipStatus, sipReason)
                    closeConnection(callId, DisconnectCause.REMOTE)
                    stopServiceIfIdle()
                    return
                }
                "confirmed" -> connections[callId]?.setActive()
                "held" -> connections[callId]?.setOnHold()
                else -> Unit
            }
            if (ledger.has(callId)) ledger.update(callId, state, remoteUri)
            else ledger.open(callId, incoming, state, remoteUri)
        }

        override fun onIncomingCall(callId: String, remoteUri: String, callerName: String?, callUuid: String?) {
            awaitingInvite.remove(callId)?.let { main.removeCallbacks(it) }
            val name = callerName ?: pushedNames[callId]
            if (callId in reported) {
                name?.let { connections[callId]?.setCallerDisplayName(it, TelecomManager.PRESENTATION_ALLOWED) }
            } else {
                reportIncoming(callId, remoteUri, name)
            }
            ledger.open(callId, incoming = true, state = "incoming", remoteUri = remoteUri, callerName = name, callUuid = callUuid)
        }
    }

    private fun reportIncoming(callId: String, remoteUri: String, callerName: String?) {
        reported.add(callId)
        refreshLive()
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
