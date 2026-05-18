import Foundation
import Capacitor

@objc(PjsipPlugin)
public class PjsipPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "PjsipPlugin"
    public let jsName = "Pjsip"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "register", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unregister", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getRegistrationState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "makeCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "answerCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hangupCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getActiveCalls", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "holdCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "muteCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendDtmf", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "transferCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setAudioRoute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "registerPush", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unregisterPush", returnType: CAPPluginReturnPromise),
    ]

    private lazy var sipManager: SipManager = {
        let manager = SipManager.shared
        manager.delegate = self
        return manager
    }()

    private lazy var callKitManager: CallKitManager = {
        let manager = CallKitManager()
        manager.delegate = self
        return manager
    }()

    private lazy var pushManager: PushManager = {
        let manager = PushManager()
        manager.delegate = self
        // Direct reference so push → CallKit is synchronous (iOS 13+ requirement)
        manager.callKitManager = callKitManager
        return manager
    }()

    // MARK: - Registration

    @objc func register(_ call: CAPPluginCall) {
        guard let server = call.getString("server"),
              let username = call.getString("username"),
              let password = call.getString("password"),
              let domain = call.getString("domain") else {
            call.reject("Missing required fields: server, username, password, domain")
            return
        }

        let config = SipConfig(
            server: server,
            port: call.getInt("port") ?? 5060,
            username: username,
            password: password,
            domain: domain,
            transport: call.getString("transport") ?? "udp",
            proxy: call.getString("proxy")
        )

        sipManager.register(config: config) { error in
            if let error = error {
                call.reject("Registration failed: \(error.localizedDescription)")
            } else {
                call.resolve()
            }
        }
    }

    @objc func unregister(_ call: CAPPluginCall) {
        pushManager.unregister()
        sipManager.unregister { error in
            if let error = error {
                call.reject("Unregister failed: \(error.localizedDescription)")
            } else {
                call.resolve()
            }
        }
    }

    @objc func getRegistrationState(_ call: CAPPluginCall) {
        call.resolve(["state": sipManager.registrationState])
    }

    // MARK: - Calls

    @objc func makeCall(_ call: CAPPluginCall) {
        guard let uri = call.getString("uri") else {
            call.reject("Missing required field: uri")
            return
        }

        let callId = sipManager.makeCall(uri: uri)
        if let callId = callId {
            callKitManager.reportOutgoingCall(callId: callId, handle: uri)
            call.resolve(["callId": callId])
        } else {
            call.reject("Failed to make call")
        }
    }

    @objc func answerCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }

        sipManager.answerCall(callId: callId) { error in
            if let error = error {
                call.reject("Answer failed: \(error.localizedDescription)")
            } else {
                call.resolve()
            }
        }
    }

    @objc func hangupCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }

        sipManager.hangupCall(callId: callId)
        callKitManager.reportCallEnded(callId: callId)
        call.resolve()
    }

    @objc func getActiveCalls(_ call: CAPPluginCall) {
        call.resolve(["calls": sipManager.getActiveCalls()])
    }

    // MARK: - In-call controls

    @objc func holdCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }
        let hold = call.getBool("hold") ?? true
        sipManager.holdCall(callId: callId, hold: hold)
        call.resolve()
    }

    @objc func muteCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }
        let mute = call.getBool("mute") ?? true
        sipManager.muteCall(callId: callId, mute: mute)
        call.resolve()
    }

    @objc func sendDtmf(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId"),
              let digit = call.getString("digit") else {
            call.reject("Missing required fields: callId, digit")
            return
        }
        sipManager.sendDtmf(callId: callId, digit: digit)
        call.resolve()
    }

    @objc func transferCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId"),
              let target = call.getString("target") else {
            call.reject("Missing required fields: callId, target")
            return
        }
        sipManager.transferCall(callId: callId, target: target)
        call.resolve()
    }

    @objc func setAudioRoute(_ call: CAPPluginCall) {
        guard let route = call.getString("route") else {
            call.reject("Missing required field: route")
            return
        }
        sipManager.setAudioRoute(route: route)
        call.resolve()
    }

    // MARK: - Push notifications

    @objc func registerPush(_ call: CAPPluginCall) {
        pushManager.registerForVoIPPushes()
        call.resolve()
    }

    @objc func unregisterPush(_ call: CAPPluginCall) {
        pushManager.unregister()
        call.resolve()
    }
}

// MARK: - SipManagerDelegate

extension PjsipPlugin: SipManagerDelegate {
    func onRegistrationStateChanged(state: String, reason: String?) {
        var data: [String: Any] = ["state": state]
        if let reason = reason {
            data["reason"] = reason
        }
        notifyListeners("registrationStateChanged", data: data)
    }

    func onCallStateChanged(callId: String, state: String, remoteUri: String?) {
        var data: [String: Any] = ["callId": callId, "state": state]
        if let remoteUri = remoteUri {
            data["remoteUri"] = remoteUri
        }
        notifyListeners("callStateChanged", data: data)

        if state == "disconnected" {
            callKitManager.reportCallEnded(callId: callId)
        }
    }

    func onIncomingCall(callId: String, remoteUri: String, callerName: String?) {
        callKitManager.reportIncomingCall(callId: callId, handle: remoteUri, callerName: callerName)

        var data: [String: Any] = ["callId": callId, "remoteUri": remoteUri]
        if let callerName = callerName {
            data["callerName"] = callerName
        }
        notifyListeners("incomingCall", data: data)
    }
}

// MARK: - PushManagerDelegate

extension PjsipPlugin: PushManagerDelegate {
    func pushManagerDidReceiveVoIPPush(payload: [AnyHashable: Any]) {
        // CallKit was already reported synchronously by PushManager.
        // CallKit was already reported synchronously by PushManager.
        // The actual SIP INVITE will arrive via PJSIP's on_incoming_call callback
        // which will trigger handleIncomingCall with proper pjsua call context.
        // Just emit a JS event so the app knows a push arrived.
        let callId = payload["callId"] as? String ?? "push-\(UUID().uuidString)"
        let remoteUri = payload["remoteUri"] as? String ?? "unknown"
        let callerName = payload["callerName"] as? String

        var data: [String: Any] = ["callId": callId, "remoteUri": remoteUri]
        if let callerName = callerName {
            data["callerName"] = callerName
        }
        notifyListeners("incomingCall", data: data)
    }

    func pushManagerDidUpdatePushToken(token: String) {
        notifyListeners("pushTokenUpdated", data: ["token": token, "platform": "apns"])
    }
}

// MARK: - CallKitManagerDelegate

extension PjsipPlugin: CallKitManagerDelegate {
    func callKitDidAnswerCall(callId: String) {
        sipManager.answerCall(callId: callId, completion: nil)
    }

    func callKitDidEndCall(callId: String) {
        sipManager.hangupCall(callId: callId)
    }

    func callKitDidSetHeld(callId: String, isOnHold: Bool) {
        sipManager.holdCall(callId: callId, hold: isOnHold)
    }

    func callKitDidSetMuted(callId: String, isMuted: Bool) {
        sipManager.muteCall(callId: callId, mute: isMuted)
    }
}
