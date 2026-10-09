package com.redyrect.pjsip

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person

/**
 * The incoming-call screen. A self-managed Telecom call gets no system UI,
 * so when Telecom asks (`onShowIncomingCallUi`) the app posts a call-style
 * notification whose full-screen intent opens the app over the lock screen.
 * Answer and Decline go to [CallController] like every other answer/end.
 */
internal object CallNotifications {
    private const val CHANNEL_ID = "pjsip_incoming_calls"
    const val EXTRA_CALL_ID = "com.redyrect.pjsip.CALL_ID"

    fun showIncoming(context: Context, callId: String, callerName: String) {
        ensureChannel(context)
        val decline = PendingIntent.getBroadcast(
            context,
            requestCode(callId, 1),
            Intent(context, CallDeclineReceiver::class.java).putExtra(EXTRA_CALL_ID, callId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val answer = PendingIntent.getActivity(
            context,
            requestCode(callId, 2),
            Intent(context, CallAnswerActivity::class.java)
                .putExtra(EXTRA_CALL_ID, callId)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val openApp = PendingIntent.getActivity(
            context,
            requestCode(callId, 3),
            launchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val caller = Person.Builder().setName(callerName).setImportant(true).build()
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(callerName)
            .setContentText("Incoming call")
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
            .setFullScreenIntent(openApp, true)
            .setContentIntent(openApp)
            .setStyle(NotificationCompat.CallStyle.forIncomingCall(caller, decline, answer))
            .build()
        try {
            NotificationManagerCompat.from(context).notify(notificationId(callId), notification)
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted: the call still rings in Telecom but nothing is visible.
            pjsipLog("[CallNotifications] cannot show incoming call $callId: notifications not permitted")
        }
    }

    fun cancel(context: Context, callId: String) {
        NotificationManagerCompat.from(context).cancel(notificationId(callId))
    }

    fun launchIntent(context: Context): Intent =
        (context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                enableVibration(true)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            },
        )
    }

    private fun notificationId(callId: String) = callId.hashCode()
    private fun requestCode(callId: String, action: Int) = callId.hashCode() * 31 + action
}

/** Decline from the notification: ends the call without opening the app. */
class CallDeclineReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra(CallNotifications.EXTRA_CALL_ID) ?: return
        CallController.hangup(callId, android.telecom.DisconnectCause.REJECTED)
    }
}

/** Answer from the notification: answers, then opens the app on the call. An
 *  activity because Android 12+ won't let a notification's broadcast start one. */
class CallAnswerActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent.getStringExtra(CallNotifications.EXTRA_CALL_ID)?.let { callId ->
            CallController.answer(callId) { error ->
                if (error != null) pjsipLog("[CallAnswerActivity] answer $callId failed: ${error.message}")
            }
        }
        startActivity(CallNotifications.launchIntent(this))
        finish()
    }
}
