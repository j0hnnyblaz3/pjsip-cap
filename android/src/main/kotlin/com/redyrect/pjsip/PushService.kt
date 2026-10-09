package com.redyrect.pjsip

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * A ready-made FCM service for an app whose only pushes are calls. The plugin
 * does not declare it: Android delivers each FCM message to one service, so
 * the host app owns that one and routes call pushes to
 * [CallController.onPushMessage] — declare this class only if nothing else
 * in the app receives FCM.
 */
class PushService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        CallController.pushTokenUpdated(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        if (!CallController.onPushMessage(applicationContext, message.data)) {
            pjsipLog("[PushService] ignoring a push that is not an incoming call")
        }
    }
}
