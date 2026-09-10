package com.redyrect.pjsip

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.PhoneAccount

class CallConnectionService : ConnectionService() {

    companion object {
        var sipManager: SipManager? = null
        private val connections = mutableMapOf<String, SipConnection>()

        fun reportIncomingCall(context: Context, callId: String, remoteUri: String, callerName: String?) {
            val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val phoneAccountHandle = getPhoneAccountHandle(context)

            ensurePhoneAccountRegistered(context, telecomManager, phoneAccountHandle)

            val extras = Bundle().apply {
                putString("callId", callId)
                putString("remoteUri", remoteUri)
                callerName?.let { putString("callerName", it) }
            }

            telecomManager.addNewIncomingCall(phoneAccountHandle, extras)
        }

        fun reportOutgoingCall(context: Context, callId: String, uri: String) {
            val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val phoneAccountHandle = getPhoneAccountHandle(context)

            ensurePhoneAccountRegistered(context, telecomManager, phoneAccountHandle)

            val extras = Bundle().apply {
                putString("callId", callId)
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, phoneAccountHandle)
            }

            telecomManager.placeCall(Uri.parse("sip:$uri"), extras)
        }

        /** Mirror a PJSIP call-state transition onto the Telecom connection.
         *  Telecom keeps its own copy of "is this call up", and it is the
         *  copy the system call UI, audio routing and the ongoing-call
         *  notification read. Driving it from the same funnel that emits to
         *  JS is what keeps the two from drifting — previously nothing
         *  reported the answered state, so Telecom sat in DIALING for the
         *  whole call. */
        fun reportCallState(callId: String, state: String) {
            when (state) {
                "confirmed" -> connections[callId]?.setActive()
                "disconnected" -> reportCallEnded(callId)
                // calling/early/connecting are already reflected by the
                // connection's own initial state; nothing to mirror.
                else -> Unit
            }
        }

        fun reportCallEnded(callId: String) {
            connections[callId]?.let { conn ->
                conn.setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.REMOTE))
                conn.destroy()
                connections.remove(callId)
            }
        }

        private fun getPhoneAccountHandle(context: Context): PhoneAccountHandle {
            return PhoneAccountHandle(
                ComponentName(context, CallConnectionService::class.java),
                "pjsip_account"
            )
        }

        private fun ensurePhoneAccountRegistered(
            context: Context,
            telecomManager: TelecomManager,
            handle: PhoneAccountHandle
        ) {
            val account = PhoneAccount.builder(handle, "PJSIP")
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .addSupportedUriScheme(PhoneAccount.SCHEME_SIP)
                .build()
            telecomManager.registerPhoneAccount(account)
        }
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callId = extras.getString("callId") ?: "unknown"
        val remoteUri = extras.getString("remoteUri") ?: "unknown"

        val connection = SipConnection(callId).apply {
            setAddress(Uri.parse("sip:$remoteUri"), TelecomManager.PRESENTATION_ALLOWED)
            setRinging()
            connectionCapabilities = Connection.CAPABILITY_HOLD or
                    Connection.CAPABILITY_SUPPORT_HOLD or
                    Connection.CAPABILITY_MUTE
        }

        connections[callId] = connection
        return connection
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callId = extras.getString("callId") ?: "unknown"

        val connection = SipConnection(callId).apply {
            setAddress(request?.address, TelecomManager.PRESENTATION_ALLOWED)
            setDialing()
            connectionCapabilities = Connection.CAPABILITY_HOLD or
                    Connection.CAPABILITY_SUPPORT_HOLD or
                    Connection.CAPABILITY_MUTE
        }

        connections[callId] = connection
        return connection
    }

    /**
     * Represents a single SIP call connection in the Android Telecom framework.
     */
    class SipConnection(private val callId: String) : Connection() {

        override fun onAnswer() {
            setActive()
            sipManager?.answerCall(callId) {}
        }

        override fun onReject() {
            setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.REJECTED))
            destroy()
            sipManager?.hangupCall(callId)
            connections.remove(callId)
        }

        override fun onDisconnect() {
            setDisconnected(android.telecom.DisconnectCause(android.telecom.DisconnectCause.LOCAL))
            destroy()
            sipManager?.hangupCall(callId)
            connections.remove(callId)
        }

        override fun onHold() {
            setOnHold()
            sipManager?.holdCall(callId, true)
        }

        override fun onUnhold() {
            setActive()
            sipManager?.holdCall(callId, false)
        }

        override fun onPlayDtmfTone(c: Char) {
            sipManager?.sendDtmf(callId, c.toString())
        }
    }
}
