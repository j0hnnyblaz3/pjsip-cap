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
        val callId = extras.getString("callId") ?: "unknown"
        val remoteUri = extras.getString("remoteUri") ?: "unknown"

        return SipConnection(callId).apply {
            setAddress(CallController.telecomAddress(remoteUri), TelecomManager.PRESENTATION_ALLOWED)
            extras.getString("callerName")?.let { setCallerDisplayName(it, TelecomManager.PRESENTATION_ALLOWED) }
            setRinging()
            connectionCapabilities = CallController.connectionCapabilities
            CallController.attach(callId, this)
        }
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callId = extras.getString("callId") ?: "unknown"

        return SipConnection(callId).apply {
            setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED)
            setDialing()
            connectionCapabilities = CallController.connectionCapabilities
            CallController.attach(callId, this)
        }
    }

    /** One SIP call as Telecom sees it; its callbacks go to the controller. */
    class SipConnection(private val callId: String) : Connection() {
        override fun onAnswer() = CallController.answer(callId) {}
        override fun onReject() = CallController.hangup(callId, DisconnectCause.REJECTED)
        override fun onDisconnect() = CallController.hangup(callId, DisconnectCause.LOCAL)
        override fun onHold() = CallController.hold(callId, true)
        override fun onUnhold() = CallController.hold(callId, false)
        override fun onPlayDtmfTone(c: Char) = CallController.sendDtmf(callId, c.toString())
    }
}
