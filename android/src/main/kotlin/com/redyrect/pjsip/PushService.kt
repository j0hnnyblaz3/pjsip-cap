package com.redyrect.pjsip

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM handler for incoming call push notifications.
 *
 * Push payload from your server must include:
 *   {
 *     "type": "incoming_call",
 *     "callId": "unique-call-id",
 *     "remoteUri": "sip:1001@example.com",
 *     "callerName": "John Doe"  // optional
 *   }
 *
 * Flow:
 *   FCM push arrives → PushService.onMessageReceived
 *     → CallConnectionService.reportIncomingCall (shows native call UI)
 *     → SipManager.handleIncomingCall (wakes SIP stack)
 *     → PjsipPlugin listener notifies JS layer
 */
class PushService : FirebaseMessagingService() {

    companion object {
        private const val TAG = "PjsipPush"

        /**
         * Reference to the plugin so we can emit token updates to JS.
         * Set by PjsipPlugin during load().
         */
        var plugin: PjsipPlugin? = null
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.d(TAG, "FCM token updated: ${token.take(20)}...")

        // Notify plugin → JS layer with the new token
        plugin?.onPushTokenUpdated(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)

        val data = message.data
        val type = data["type"] ?: return

        when (type) {
            "incoming_call" -> handleIncomingCall(data)
            else -> Log.d(TAG, "Unknown push type: $type")
        }
    }

    private fun handleIncomingCall(data: Map<String, String>) {
        val remoteUri = data["remoteUri"] ?: run {
            Log.e(TAG, "Missing remoteUri in push payload")
            return
        }
        val callerName = data["callerName"]
        val callId = data["callId"] ?: "push-${System.currentTimeMillis()}"

        Log.d(TAG, "Incoming call push: $callId from $remoteUri")

        // Step 1: Show native call UI via ConnectionService
        val context = applicationContext
        CallConnectionService.reportIncomingCall(context, callId, remoteUri, callerName)

        // Step 2: Wake SIP stack to handle the actual SIP INVITE
        CallConnectionService.sipManager?.handleIncomingCall(remoteUri, callerName)

        // Step 3: Notify JS layer
        plugin?.onPushIncomingCall(callId, remoteUri, callerName)
    }
}
