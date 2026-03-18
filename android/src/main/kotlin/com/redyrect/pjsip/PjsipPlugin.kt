package com.redyrect.pjsip

import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.google.firebase.messaging.FirebaseMessaging

@CapacitorPlugin(name = "Pjsip")
class PjsipPlugin : Plugin() {

    private lateinit var sipManager: SipManager

    override fun load() {
        sipManager = SipManager(context)
        sipManager.listener = object : SipManager.Listener {
            override fun onRegistrationStateChanged(state: String, reason: String?) {
                val data = JSObject().apply {
                    put("state", state)
                    reason?.let { put("reason", it) }
                }
                notifyListeners("registrationStateChanged", data)
            }

            override fun onCallStateChanged(callId: String, state: String, remoteUri: String?) {
                val data = JSObject().apply {
                    put("callId", callId)
                    put("state", state)
                    remoteUri?.let { put("remoteUri", it) }
                }
                notifyListeners("callStateChanged", data)

                if (state == "disconnected") {
                    CallConnectionService.reportCallEnded(callId)
                }
            }

            override fun onIncomingCall(callId: String, remoteUri: String, callerName: String?) {
                CallConnectionService.reportIncomingCall(context, callId, remoteUri, callerName)

                val data = JSObject().apply {
                    put("callId", callId)
                    put("remoteUri", remoteUri)
                    callerName?.let { put("callerName", it) }
                }
                notifyListeners("incomingCall", data)
            }
        }

        CallConnectionService.sipManager = sipManager

        // Wire PushService so it can emit events to JS
        PushService.plugin = this
    }

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
            proxy = call.getString("proxy")
        )

        sipManager.register(config) { error ->
            if (error != null) {
                call.reject("Registration failed: ${error.message}")
            } else {
                call.resolve()
            }
        }
    }

    @PluginMethod
    fun unregister(call: PluginCall) {
        sipManager.unregister { error ->
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
            put("state", sipManager.registrationState)
        })
    }

    // Calls

    @PluginMethod
    fun makeCall(call: PluginCall) {
        val uri = call.getString("uri") ?: return call.reject("Missing uri")

        val callId = sipManager.makeCall(uri)
        if (callId != null) {
            CallConnectionService.reportOutgoingCall(context, callId, uri)
            call.resolve(JSObject().apply { put("callId", callId) })
        } else {
            call.reject("Failed to make call")
        }
    }

    @PluginMethod
    fun answerCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")

        sipManager.answerCall(callId) { error ->
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
        sipManager.hangupCall(callId)
        CallConnectionService.reportCallEnded(callId)
        call.resolve()
    }

    // In-call controls

    @PluginMethod
    fun holdCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        val hold = call.getBoolean("hold", true)!!
        sipManager.holdCall(callId, hold)
        call.resolve()
    }

    @PluginMethod
    fun muteCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        val mute = call.getBoolean("mute", true)!!
        sipManager.muteCall(callId, mute)
        call.resolve()
    }

    @PluginMethod
    fun sendDtmf(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        val digit = call.getString("digit") ?: return call.reject("Missing digit")
        sipManager.sendDtmf(callId, digit)
        call.resolve()
    }

    @PluginMethod
    fun transferCall(call: PluginCall) {
        val callId = call.getString("callId") ?: return call.reject("Missing callId")
        val target = call.getString("target") ?: return call.reject("Missing target")
        sipManager.transferCall(callId, target)
        call.resolve()
    }

    @PluginMethod
    fun setAudioRoute(call: PluginCall) {
        val route = call.getString("route") ?: return call.reject("Missing route")
        sipManager.setAudioRoute(route)
        call.resolve()
    }

    // Push notifications

    @PluginMethod
    fun registerPush(call: PluginCall) {
        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
            if (task.isSuccessful) {
                val token = task.result
                notifyListeners("pushTokenUpdated", JSObject().apply {
                    put("token", token)
                    put("platform", "fcm")
                })
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

    // Called by PushService when a new FCM token is issued
    fun onPushTokenUpdated(token: String) {
        notifyListeners("pushTokenUpdated", JSObject().apply {
            put("token", token)
            put("platform", "fcm")
        })
    }

    // Called by PushService when an incoming call push arrives
    fun onPushIncomingCall(callId: String, remoteUri: String, callerName: String?) {
        val data = JSObject().apply {
            put("callId", callId)
            put("remoteUri", remoteUri)
            callerName?.let { put("callerName", it) }
        }
        notifyListeners("incomingCall", data)
    }
}
