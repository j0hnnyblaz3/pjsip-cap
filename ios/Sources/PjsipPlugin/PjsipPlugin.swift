import Foundation
import AVFoundation
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
        CAPPluginMethod(name: "getPushFeatures", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "holdCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "muteCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendDtmf", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "transferCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setAudioRoute", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "registerPush", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unregisterPush", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateCallDisplay", returnType: CAPPluginReturnPromise),
    ]

    /// The bridge only: each method parses its arguments and asks the call
    /// controller, which owns the call lifecycle; the controller's events
    /// come back through `CallEventSink`.
    private lazy var calls: CallController = {
        let controller = CallController()
        controller.events = self
        return controller
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
        // How the engine runs comes from the PBX (/me/sip-config); there is
        // no local default to fall back on.
        guard let registerExpires = call.getInt("registerExpiresSec"),
              let keepAlive = call.getInt("keepAliveSec"),
              let codecs = call.getArray("codecs", String.self), !codecs.isEmpty else {
            call.reject("Missing engine settings: registerExpiresSec, keepAliveSec, codecs (from the PBX's /me/sip-config)")
            return
        }

        let config = SipConfig(
            server: server,
            port: call.getInt("port") ?? 5060,
            username: username,
            password: password,
            domain: domain,
            transport: call.getString("transport") ?? "udp",
            proxy: call.getString("proxy"),
            // The app's media-encryption setting (Admin → VoIP). nil
            // leaves pjsua's default. FreeSWITCH behind dSIPRouter takes a
            // clean RTP/SAVP offer ("mandatory") and rejects the OPTIONAL
            // hybrid — set it there, not here.
            srtpPolicy: call.getString("srtpPolicy"),
            registerExpiresSec: registerExpires,
            keepAliveSec: keepAlive,
            codecs: codecs
        )

        calls.register(config: config) { error in
            if let error = error {
                call.reject("Registration failed: \(error.localizedDescription)")
            } else {
                call.resolve()
            }
        }
    }

    @objc func unregister(_ call: CAPPluginCall) {
        calls.unregister { error in
            if let error = error {
                call.reject("Unregister failed: \(error.localizedDescription)")
            } else {
                call.resolve()
            }
        }
    }

    @objc func getRegistrationState(_ call: CAPPluginCall) {
        call.resolve(["state": calls.registrationState])
    }

    // MARK: - Calls

    @objc func makeCall(_ call: CAPPluginCall) {
        guard let uri = call.getString("uri") else {
            call.reject("Missing required field: uri")
            return
        }

        // Optional displayName from the JS dialer — when set, CallKit
        // shows this in the Dynamic Island / iOS Phone-app UI instead
        // of the raw sip URI / Firebase UID. Without it the user sees
        // strings like `y5ft3JFWtHPTewC8aiPwBEiQGpl1` as the call's
        // identity, which is nonsense to a human.
        let displayName = call.getString("displayName")

        do {
            let callId = try calls.makeCall(uri: uri, displayName: displayName)
            call.resolve(["callId": callId])
        } catch {
            call.reject(error.localizedDescription)
        }
    }

    @objc func answerCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }

        calls.answer(callId: callId) { error in
            if let error = error {
                call.reject("Answer failed: \(error.localizedDescription)")
            } else {
                call.resolve()
            }
        }
    }

    /// Push a fresh display name to CallKit AFTER an inbound call has
    /// already been reported. The PBX's `From:` header on inbound calls
    /// is `sip:<uid>@<host>` with no display-name part, so CallKit's
    /// initial reportNewIncomingCall has nothing but a UID handle to
    /// show — the Dynamic Island ends up displaying the raw Firebase
    /// UID, which is meaningless to a human.
    ///
    /// The JS layer resolves the UID to a real user via GraphQL (in
    /// SipContext) and then calls this so CallKit's
    /// CXCallUpdate.localizedCallerName picks up the real name. Safe
    /// to call multiple times — only updates if the call is still
    /// known to CallKit.
    @objc func updateCallDisplay(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }
        let displayName = call.getString("displayName")
        calls.updateCallDisplay(callId: callId, displayName: displayName)
        call.resolve()
    }

    @objc func hangupCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }

        calls.end(callId: callId) {
            call.resolve()
        }
    }

    /// None beyond the wake: a PushKit push must report a call to CallKit,
    /// so it can't stop one — the SIP CANCEL does, once registered.
    @objc func getPushFeatures(_ call: CAPPluginCall) {
        call.resolve(["features": [String]()])
    }

    @objc func getActiveCalls(_ call: CAPPluginCall) {
        call.resolve(["calls": calls.activeCalls()])
    }

    // MARK: - In-call controls

    @objc func holdCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }
        let hold = call.getBool("hold") ?? true
        calls.hold(callId: callId, hold: hold)
        call.resolve()
    }

    @objc func muteCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId") else {
            call.reject("Missing required field: callId")
            return
        }
        let mute = call.getBool("mute") ?? true
        calls.mute(callId: callId, mute: mute)
        call.resolve()
    }

    @objc func sendDtmf(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId"),
              let digit = call.getString("digit") else {
            call.reject("Missing required fields: callId, digit")
            return
        }
        calls.sendDtmf(callId: callId, digit: digit)
        call.resolve()
    }

    @objc func transferCall(_ call: CAPPluginCall) {
        guard let callId = call.getString("callId"),
              let target = call.getString("target") else {
            call.reject("Missing required fields: callId, target")
            return
        }
        calls.transfer(callId: callId, target: target)
        call.resolve()
    }

    @objc func setAudioRoute(_ call: CAPPluginCall) {
        guard let route = call.getString("route") else {
            call.reject("Missing required field: route")
            return
        }
        calls.setAudioRoute(route)
        call.resolve()
    }

    // MARK: - Push notifications

    @objc func registerPush(_ call: CAPPluginCall) {
        calls.registerPush()
        call.resolve()
    }

    @objc func unregisterPush(_ call: CAPPluginCall) {
        calls.unregisterPush()
        call.resolve()
    }

    // MARK: - Permissions
    //
    // CAPPlugin already declares checkPermissions / requestPermissions
    // as `@objc open func` for Capacitor's standard permission
    // protocol — these are overrides, not new methods. `override
    // public` is required: Swift rejects an override that's less
    // accessible than the base method, and the base is `open` (=
    // public + overridable).

    /// Current microphone permission, without prompting. The plugin is
    /// audio-only (CallKit `supportsVideo = false`), so the contract reports
    /// the microphone alone.
    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        call.resolve(["microphone": microphonePermissionState()])
    }

    /// Ask for the microphone ahead of the first call. Without this the
    /// system prompt only fires when CallKit activates the audio session —
    /// the moment the call should start — and a Deny there leaves the call
    /// broken with no recovery path. Resolves with the state afterwards.
    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        guard call.getBool("microphone") ?? true,
              AVAudioSession.sharedInstance().recordPermission == .undetermined else {
            call.resolve(["microphone": microphonePermissionState()])
            return
        }
        // requestRecordPermission is deprecated in iOS 17 for
        // AVAudioApplication, but the deployment range still includes 15.
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] _ in
            DispatchQueue.main.async {
                call.resolve(["microphone": self?.microphonePermissionState() ?? "prompt"])
            }
        }
    }

    /// iOS's record permission in the cross-platform vocabulary
    /// (granted / denied / prompt).
    private func microphonePermissionState() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "prompt"
        @unknown default: return "prompt"
        }
    }
}

// MARK: - CallEventSink

extension PjsipPlugin: CallEventSink {
    func emit(event: String, data: [String: Any]) {
        notifyListeners(event, data: data)
    }
}
