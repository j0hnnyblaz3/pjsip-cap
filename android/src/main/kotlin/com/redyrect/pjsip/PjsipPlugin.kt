package com.redyrect.pjsip

import android.Manifest
import com.getcapacitor.JSArray
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import com.google.firebase.messaging.FirebaseMessaging

@CapacitorPlugin(
    name = "Pjsip",
    permissions = [
        // Android won't auto-prompt for RECORD_AUDIO when JNI opens the
        // mic — the request has to originate from a normal Activity
        // call, which Capacitor's permission plumbing provides for us
        // via requestPermissionForAlias() below.
        Permission(
            strings = [Manifest.permission.RECORD_AUDIO],
            alias = "microphone",
        ),
    ],
)
class PjsipPlugin : Plugin() {

    companion object {
        // Must match the `alias` in @Permission above. Kept here rather
        // than reused from the annotation because annotation arguments
        // can't reference companion-object consts without a forward-
        // reference compile error.
        private const val MIC_PERMISSION = "microphone"
    }

    /** The bridge only: each method parses its arguments and asks
     *  `CallController`, which owns the call lifecycle; its events come back
     *  through `CallEventSink`. */
    override fun load() {
        CallController.start(context)
        CallController.events = object : CallEventSink {
            override fun emit(event: String, data: Map<String, Any?>) {
                notifyListeners(event, toJs(data))
            }
        }
    }

    // Permissions: the microphone, the one this plugin owns. Same contract as
    // iOS — `requestPermissions({ microphone })` resolves with
    // `{ microphone }` — so the app has one way to ask on both platforms.

    @PluginMethod
    override fun requestPermissions(call: PluginCall) {
        if (call.getBoolean("microphone", true) == false ||
            getPermissionState(MIC_PERMISSION) == PermissionState.GRANTED
        ) {
            checkPermissions(call)
            return
        }
        requestPermissionForAlias(MIC_PERMISSION, call, "microphonePermissionResult")
    }

    @PermissionCallback
    private fun microphonePermissionResult(call: PluginCall) = checkPermissions(call)

    // Registration

    @PluginMethod
    fun register(call: PluginCall) {
        val server = call.getString("server") ?: return call.reject("Missing server")
        val username = call.getString("username") ?: return call.reject("Missing username")
        val password = call.getString("password") ?: return call.reject("Missing password")
        val domain = call.getString("domain") ?: return call.reject("Missing domain")

        val config = SipConfig(
            server = server,
            port = call.getInt("port", 5060)!!,
            username = username,
            password = password,
            domain = domain,
            transport = call.getString("transport", "udp")!!,
            proxy = call.getString("proxy"),
            srtpPolicy = call.getString("srtpPolicy")
        )

        CallController.register(config) { error ->
            if (error != null) {
                call.reject("Registration failed: ${error.message}")
            } else {
                call.resolve()
            }
        }
    }

    @PluginMethod
    fun unregister(call: PluginCall) {
        CallController.unregister { error ->
            if (error != null) {
                call.reject("Unregister failed: ${error.message}")
            } else {
                call.resolve()
            }
        }
    }

    @PluginMethod
    fun getRegistrationState(call: PluginCall) {
        call.resolve(JSObject().apply {
            put("state", CallController.registrationState)
        })
    }

    // Calls

    @PluginMethod
    fun makeCall(call: PluginCall) {
        if (getPermissionState(MIC_PERMISSION) != PermissionState.GRANTED) {
            // Hand the same PluginCall to Capacitor's permission flow;
            // when the user grants/denies, makeCallAfterMicPermission()
            // runs with the original arguments still intact.
            requestPermissionForAlias(MIC_PERMISSION, call, "makeCallAfterMicPermission")
            return
        }
        performMakeCall(call)
    }

    @PermissionCallback
    private fun makeCallAfterMicPermission(call: PluginCall) {
        if (getPermissionState(MIC_PERMISSION) == PermissionState.GRANTED) {
            performMakeCall(call)
        } else {
            call.reject("Microphone permission is required to place calls")
        }
    }

    private fun performMakeCall(call: PluginCall) {
        val uri = call.getString("uri") ?: return call.reject("Missing uri")

        try {
            val callId = CallController.makeCall(uri, call.getString("displayName"))
            call.resolve(JSObject().apply { put("callId", callId) })
        } catch (e: Exception) {
            call.reject(e.message ?: "Cannot place the call")
        }
    }

    @PluginMethod
    fun answerCall(call: PluginCall) {
        if (getPermissionState(MIC_PERMISSION) != PermissionState.GRANTED) {
            requestPermissionForAlias(MIC_PERMISSION, call, "answerCallAfterMicPermission")
            return
        }
        performAnswerCall(call)
    }

    @PermissionCallback
    private fun answerCallAfterMicPermission(call: PluginCall) {
        if (getPermissionState(MIC_PERMISSION) == PermissionState.GRANTED) {
            performAnswerCall(call)
        } else {
            call.reject("Microphone permission is required to answer calls")
        }
    }

    private fun performAnswerCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")

        CallController.answer(callId) { error ->
            if (error != null) {
                call.reject("Answer failed: ${error.message}")
            } else {
                call.resolve()
            }
        }
    }

    @PluginMethod
    fun hangupCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        CallController.hangup(callId)
        call.resolve()
    }

    @PluginMethod
    fun updateCallDisplay(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        // Explicit null clears a previous override; absent means the same.
        val displayName = call.getString("displayName")
        CallController.updateCallDisplay(callId, displayName)
        call.resolve()
    }

    @PluginMethod
    fun getActiveCalls(call: PluginCall) {
        val arr = JSArray()
        for (c in CallController.activeCalls()) arr.put(toJs(c))
        call.resolve(JSObject().apply { put("calls", arr) })
    }

    // In-call controls

    @PluginMethod
    fun holdCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        val hold = call.getBoolean("hold", true)!!
        CallController.hold(callId, hold)
        call.resolve()
    }

    @PluginMethod
    fun muteCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        val mute = call.getBoolean("mute", true)!!
        CallController.mute(callId, mute)
        call.resolve()
    }

    @PluginMethod
    fun sendDtmf(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        val digit = call.getString("digit") ?: return call.reject("Missing digit")
        CallController.sendDtmf(callId, digit)
        call.resolve()
    }

    @PluginMethod
    fun transferCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        val target = call.getString("target") ?: return call.reject("Missing target")
        CallController.transfer(callId, target)
        call.resolve()
    }

    @PluginMethod
    fun setAudioRoute(call: PluginCall) {
        val route = call.getString("route") ?: return call.reject("Missing route")
        CallController.setAudioRoute(route)
        call.resolve()
    }

    // Push notifications

    @PluginMethod
    fun registerPush(call: PluginCall) {
        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
            if (task.isSuccessful) {
                CallController.pushTokenUpdated(task.result)
                call.resolve()
            } else {
                call.reject("Failed to get FCM token: ${task.exception?.message}")
            }
        }
    }

    @PluginMethod
    fun unregisterPush(call: PluginCall) {
        FirebaseMessaging.getInstance().deleteToken().addOnCompleteListener { task ->
            if (task.isSuccessful) {
                call.resolve()
            } else {
                call.reject("Failed to delete FCM token: ${task.exception?.message}")
            }
        }
    }
}

/** An event's map as the JS object it describes; nested maps (a snapshot's
 *  `end`) become objects too, not their toString. Nulls are left out. */
private fun toJs(data: Map<String, Any?>): JSObject = JSObject().apply {
    for ((key, value) in data) {
        when (value) {
            null -> Unit
            is Map<*, *> -> {
                @Suppress("UNCHECKED_CAST")
                put(key, toJs(value as Map<String, Any?>))
            }
            else -> put(key, value)
        }
    }
}
