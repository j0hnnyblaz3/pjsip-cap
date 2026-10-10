package com.redyrect.pjsip

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.telecom.DisconnectCause
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.Chronometer
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The call screen over the lock screen — what CallKit shows on iOS. Android
 * opens it as the ringing notification's full-screen intent when the phone
 * is locked, and from the notifications while a call is up.
 *
 * It shows only who is calling; the app (patient data) still needs an
 * unlock. On an unlocked phone it hands straight over to the app, which has
 * the full call screen. Ringing: Answer / Decline. Answered: timer, Mute,
 * Speaker, Hang up. It closes when the call ends.
 */
class CallScreenActivity : Activity() {
    private lateinit var callId: String
    private var unsubscribe: (() -> Unit)? = null
    private var muted = false
    private var speaker = false

    private lateinit var status: TextView
    private lateinit var timer: Chronometer
    private lateinit var ringingRow: LinearLayout
    private lateinit var activeRow: LinearLayout
    private lateinit var muteButton: Button
    private lateinit var speakerButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        callId = intent.getStringExtra(CallNotifications.EXTRA_CALL_ID) ?: return finish()
        if (!CallController.isLive(callId)) return finish()
        if (!isLocked()) {
            // The app has the whole call screen; nothing to hide from.
            startActivity(CallNotifications.launchIntent(this))
            return finish()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(buildLayout())

        val now = CallController.snapshot(callId)
        render(now)
        unsubscribe = CallController.observe(callId) { snapshot -> render(snapshot) }
    }

    override fun onDestroy() {
        unsubscribe?.invoke()
        super.onDestroy()
    }

    private fun isLocked(): Boolean =
        getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true

    /** Draw the call as its snapshot says; null before its INVITE is here. */
    private fun render(snapshot: Map<String, Any?>?) {
        val state = snapshot?.get("state") as? String ?: "incoming"
        if (state == "disconnected") return finish()
        val answered = snapshot?.get("answered") == true
        val ringing = state == "incoming" && !answered
        val name = (snapshot?.get("callerName") as? String)
            ?: CallController.pushedName(callId)
            ?: (snapshot?.get("remoteUri") as? String)?.let { CallController.telecomAddress(it).schemeSpecificPart?.substringBefore('@') }
            ?: "Incoming call"
        findViewById<TextView>(NAME_ID).text = name
        ringingRow.visibility = if (ringing) View.VISIBLE else View.GONE
        activeRow.visibility = if (ringing) View.GONE else View.VISIBLE
        status.text = when {
            ringing -> "Incoming call"
            state == "held" -> "On hold"
            answered -> ""
            else -> "Connecting…"
        }
        if (answered && timer.visibility != View.VISIBLE) {
            timer.base = SystemClock.elapsedRealtime()
            timer.visibility = View.VISIBLE
            timer.start()
        }
    }

    private fun answer() {
        CallController.answer(callId) { error ->
            if (error != null) {
                pjsipLog("[CallScreen] answer $callId failed: ${error.message}")
                status.text = "Couldn’t answer"
            }
        }
    }

    private fun buildLayout(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(Color.rgb(18, 18, 20))
            setPadding(dp(24), dp(96), dp(24), dp(64))
        }
        root.addView(TextView(this).apply {
            id = NAME_ID
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 32f)
            gravity = Gravity.CENTER
        })
        status = TextView(this).apply {
            setTextColor(Color.rgb(170, 170, 176))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            gravity = Gravity.CENTER
            setPadding(0, dp(8), 0, 0)
        }
        root.addView(status)
        timer = Chronometer(this).apply {
            setTextColor(Color.rgb(170, 170, 176))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            visibility = View.GONE
        }
        root.addView(timer)
        root.addView(View(this), LinearLayout.LayoutParams(0, 0, 1f))

        ringingRow = row(
            roundButton("Decline", Color.rgb(220, 53, 69)) {
                CallController.hangup(callId, DisconnectCause.REJECTED)
            },
            roundButton("Answer", Color.rgb(40, 167, 69)) { answer() },
        )
        root.addView(ringingRow)

        muteButton = roundButton("Mute", Color.rgb(58, 58, 64)) {
            muted = !muted
            CallController.mute(callId, muted)
            muteButton.text = if (muted) "Unmute" else "Mute"
        }
        speakerButton = roundButton("Speaker", Color.rgb(58, 58, 64)) {
            speaker = !speaker
            CallController.setAudioRoute(if (speaker) "speaker" else "earpiece")
            speakerButton.text = if (speaker) "Earpiece" else "Speaker"
        }
        activeRow = row(
            muteButton,
            roundButton("Hang up", Color.rgb(220, 53, 69)) { CallController.hangup(callId) },
            speakerButton,
        )
        root.addView(activeRow)
        return root
    }

    private fun row(vararg buttons: View) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        buttons.forEach { button ->
            addView(button, LinearLayout.LayoutParams(dp(88), dp(88)).apply { setMargins(dp(14), 0, dp(14), 0) })
        }
    }

    private fun roundButton(label: String, color: Int, onClick: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(color)
        }
        setOnClickListener { onClick() }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        private val NAME_ID = View.generateViewId()

        fun intent(context: Context, callId: String): Intent =
            Intent(context, CallScreenActivity::class.java)
                .putExtra(CallNotifications.EXTRA_CALL_ID, callId)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}
