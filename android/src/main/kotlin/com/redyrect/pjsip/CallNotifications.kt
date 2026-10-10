package com.redyrect.pjsip

import android.app.Activity
import android.app.KeyguardManager
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
 * The call's notifications. A self-managed Telecom call gets no system UI,
 * so the plugin draws it: a ringing call-style notification (Answer /
 * Decline, both usable on the lock screen), then, from [CallService], the
 * ongoing call (Hang up; tapping it opens the app, which needs an unlocked
 * phone — the app holds patient data). Every button goes to
 * [CallController] like every other answer and end.
 */
internal object CallNotifications {
    private const val CHANNEL_ID = "pjsip_incoming_calls"
    private const val ONGOING_CHANNEL_ID = "pjsip_ongoing_calls"
    const val EXTRA_CALL_ID = "com.redyrect.pjsip.CALL_ID"
    const val EXTRA_CAUSE = "com.redyrect.pjsip.CAUSE"
    /** The ongoing call's notification, owned by [CallService]. */
    const val ONGOING_ID = 0x5C411

    fun showIncoming(context: Context, callId: String, callerName: String) {
        ensureChannel(context)
        val decline = endIntent(context, callId, android.telecom.DisconnectCause.REJECTED, 1)
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
            pjsipLog("[CallNotifications] incoming call $callId shown")
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted: the call still rings in Telecom but nothing is visible.
            pjsipLog("[CallNotifications] cannot show incoming call $callId: notifications not permitted")
        }
    }

    /** The ongoing call, for [CallService] to run under. */
    fun ongoing(context: Context, callId: String, callerName: String): android.app.Notification {
        ensureOngoingChannel(context)
        val hangUp = endIntent(context, callId, android.telecom.DisconnectCause.LOCAL, 4)
        val openApp = PendingIntent.getActivity(
            context,
            requestCode(callId, 5),
            launchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val caller = Person.Builder().setName(callerName).setImportant(true).build()
        return NotificationCompat.Builder(context, ONGOING_CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(callerName)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setUsesChronometer(true)
            .setContentIntent(openApp)
            .setStyle(NotificationCompat.CallStyle.forOngoingCall(caller, hangUp))
            .build()
    }

    private fun endIntent(context: Context, callId: String, cause: Int, action: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            requestCode(callId, action),
            Intent(context, CallEndReceiver::class.java)
                .putExtra(EXTRA_CALL_ID, callId)
                .putExtra(EXTRA_CAUSE, cause),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

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

    private fun ensureOngoingChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(ONGOING_CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(ONGOING_CHANNEL_ID, "Ongoing calls", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null)
                lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            },
        )
    }

    private fun notificationId(callId: String) = callId.hashCode()
    private fun requestCode(callId: String, action: Int) = callId.hashCode() * 31 + action
}

/** Decline or Hang up from a notification: ends the call without opening
 *  the app, so it works on the lock screen. */
class CallEndReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra(CallNotifications.EXTRA_CALL_ID) ?: return
        val cause = intent.getIntExtra(CallNotifications.EXTRA_CAUSE, android.telecom.DisconnectCause.LOCAL)
        CallController.hangup(callId, cause)
    }
}

/** Answer from the notification. It shows over the lock screen, so answering
 *  needs no unlock; the app opens only on an unlocked phone — on a locked one
 *  the call carries on under [CallService]'s notification, as a CallKit call
 *  does on iOS. An activity, not a broadcast, because [CallService] can only
 *  start while something of the app is on screen. */
class CallAnswerActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent.getStringExtra(CallNotifications.EXTRA_CALL_ID)?.let { callId ->
            CallController.answer(callId) { error ->
                if (error != null) pjsipLog("[CallAnswerActivity] answer $callId failed: ${error.message}")
            }
        }
        val locked = getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
        if (!locked) startActivity(CallNotifications.launchIntent(this))
        finish()
    }
}
