package com.redyrect.pjsip

import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

/**
 * The Telecom adapter: creates the connection Telecom asks for and hands it to
 * `CallController`, which owns what happens to it.
 */
class CallConnectionService : ConnectionService() {

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callId = extras.getString("callId") ?: return unidentified("incoming")
        // One connection per call. A second one for the same id would take
        // the first one's place in the controller, leaving the first ringing
        // in Telecom with nothing able to end it — the phone held in ringtone
        // mode, and every later call silent.
        if (CallController.hasConnection(callId)) {
            pjsipLog("[CallConnectionService] incoming $callId already has a connection — refused")
            return Connection.createFailedConnection(
                DisconnectCause(DisconnectCause.CANCELED, "already ringing"),
            )
        }
        val remoteUri = extras.getString("remoteUri")?.takeIf { it.isNotBlank() }

        return SipConnection(callId).apply {
            // A pushed call whose push carried no number has no address yet:
            // say so, rather than show the word "unknown" as the caller.
            if (remoteUri != null) {
                setAddress(CallController.telecomAddress(remoteUri), TelecomManager.PRESENTATION_ALLOWED)
            } else {
                setAddress(null, TelecomManager.PRESENTATION_UNKNOWN)
            }
            extras.getString("callerName")?.let { setCallerDisplayName(it, TelecomManager.PRESENTATION_ALLOWED) }
            setRinging()
            connectionCapabilities = CallController.connectionCapabilities
            CallController.attach(callId, this)
            // Show the ringing screen now rather than only from
            // onShowIncomingCallUi: Samsung's Telecom never calls it.
            showIncomingUi()
        }
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callId = extras.getString("callId") ?: return unidentified("outgoing")
        if (CallController.hasConnection(callId)) {
            pjsipLog("[CallConnectionService] outgoing $callId already has a connection — refused")
            return Connection.createFailedConnection(
                DisconnectCause(DisconnectCause.CANCELED, "already placed"),
            )
        }

        return SipConnection(callId).apply {
            setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED)
            setDialing()
            connectionCapabilities = CallController.connectionCapabilities
            CallController.attach(callId, this)
        }
    }

    /** A connection request without our call id has no SIP call behind it:
     *  refuse it rather than create one nothing can ever end. */
    private fun unidentified(direction: String): Connection {
        pjsipLog("[CallConnectionService] $direction connection without a callId — refused")
        return Connection.createFailedConnection(
            DisconnectCause(DisconnectCause.ERROR, "call id missing"),
        )
    }

    /** One SIP call as Telecom sees it; its callbacks go to the controller. */
    class SipConnection(private val callId: String) : Connection() {
        init {
            // Without it Telecom treats the call as a cellular one and sets
            // MODE_IN_CALL, which routes audio to the modem: the app's
            // microphone and speaker streams carry nothing.
            audioModeIsVoip = true
        }

        /** Self-managed calls get no system ringing screen; Telecom asks the
         *  app to show one. Also called when the connection is created, since
         *  not every Telecom asks; both post the same notification. */
        override fun onShowIncomingCallUi() = showIncomingUi()

        fun showIncomingUi() =
            CallController.showIncomingUi(
                callId,
                callerDisplayName?.takeIf { it.isNotBlank() }
                    ?: address?.schemeSpecificPart?.substringBefore('@')
                    ?: "Incoming call",
            )
        override fun onAnswer() = CallController.answer(callId) {}
        override fun onReject() = CallController.hangup(callId, DisconnectCause.REJECTED)
        override fun onDisconnect() = CallController.hangup(callId, DisconnectCause.LOCAL)
        override fun onHold() = CallController.hold(callId, true)
        override fun onUnhold() = CallController.hold(callId, false)
        override fun onPlayDtmfTone(c: Char) = CallController.sendDtmf(callId, c.toString())
    }
}
