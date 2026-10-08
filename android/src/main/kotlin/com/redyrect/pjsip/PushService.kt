package com.redyrect.pjsip

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * The FCM adapter: hands tokens and incoming-call pushes to `CallController`.
 *
 * Push payload from your server must include:
 *   {
 *     "type": "incoming_call",
 *     "callId": "unique-call-id",
 *     "remoteUri": "sip:1001@example.com",
 *     "callerName": "John Doe"  // optional
 *   }
 */
class PushService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        pjsipLog("FCM token updated: ${token.take(20)}...")

        CallController.pushTokenUpdated(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)

        val data = message.data
        val type = data["type"] ?: return

        when (type) {
            "incoming_call" -> handleIncomingCall(data)
            else -> pjsipLog("Unknown push type: $type")
        }
    }

    private fun handleIncomingCall(data: Map<String, String>) {
        val remoteUri = data["remoteUri"] ?: run {
            pjsipLog("Missing remoteUri in push payload")
            return
        }
        val callerName = data["callerName"]
        val callId = data["callId"] ?: "push-${System.currentTimeMillis()}"

        CallController.onIncomingPush(applicationContext, callId, remoteUri, callerName)
    }
}
