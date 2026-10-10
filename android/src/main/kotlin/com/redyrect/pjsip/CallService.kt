package com.redyrect.pjsip

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat

/**
 * Runs while a call is up, as Android requires of a call: a foreground
 * service of type phoneCall|microphone keeps the microphone open when the
 * app is not on screen — locked phone, app in the background, swiped away —
 * and its notification is the ongoing call (Hang up; tap to open the app).
 *
 * [CallController] starts it when a call is answered or placed — while the
 * app or the answer screen is visible, which Android requires — and stops
 * it when the last call ends.
 */
class CallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callId = intent?.getStringExtra(CallNotifications.EXTRA_CALL_ID)
        if (callId == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val name = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "Call"
        val notification = CallNotifications.ongoing(this, callId, name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                CallNotifications.ONGOING_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(CallNotifications.ONGOING_ID, notification)
        }
        return START_NOT_STICKY
    }

    companion object {
        private const val EXTRA_CALLER_NAME = "com.redyrect.pjsip.CALLER_NAME"

        /** Start (or update) the service for [callId]. Fails loud: without it
         *  the call has no microphone once the app leaves the screen. */
        fun start(context: Context, callId: String, callerName: String?) {
            val intent = Intent(context, CallService::class.java)
                .putExtra(CallNotifications.EXTRA_CALL_ID, callId)
                .putExtra(EXTRA_CALLER_NAME, callerName)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                pjsipLog("[CallService] could not start for $callId — the microphone stops when the app leaves the screen: ${e.message}")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallService::class.java))
        }
    }
}
