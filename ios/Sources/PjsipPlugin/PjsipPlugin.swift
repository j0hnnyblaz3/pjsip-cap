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
            proxy: call.getString("proxy"),
            // SRTP policy passes through from the JS layer's
            // srtpPolicy field. Accept "disabled" | "optional" |
            // "mandatory". Default MANDATORY — modern SBCs (including
            // FreeSWITCH behind dSIPRouter, which is what Redyrect
            // runs) accept clean RTP/SAVP profile offers but reject
            // the OPTIONAL hybrid (RTP/AVP profile with embedded
            // crypto attribute). MANDATORY matches the TLS/HIPAA
            // encryption posture: the SDP m-line says RTP/SAVP, FS
            // accepts, audio is end-to-end SRTP all the way to the
            // SBC. To run unencrypted, set srtpPolicy = "disabled"
            // via the admin VoIP overrides.
            srtp: call.getString("srtpPolicy") ?? "mandatory"
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

        // Optional displayName from the JS dialer — when set, CallKit
        // shows this in the Dynamic Island / iOS Phone-app UI instead
        // of the raw sip URI / Firebase UID. Without it the user sees
        // strings like `y5ft3JFWtHPTewC8aiPwBEiQGpl1` as the call's
        // identity, which is nonsense to a human.
        let displayName = call.getString("displayName")

        let callId = sipManager.makeCall(uri: uri)
        if let callId = callId {
            callKitManager.reportOutgoingCall(
                callId: callId,
                handle: uri,
                callerName: displayName
            )
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

        // Don't optimistically call reportCallEnded here. PJSIP will
        // emit a "disconnected" state change once the BYE/CANCEL is
        // acknowledged (or after the local-force-disconnected fallback
        // path in SipManager.hangupCall), and onCallStateChanged owns
        // the single CallKit-end report. Doing it both here AND on
        // disconnected leaves a stale entry in CallKit's recents log
        // on the second invocation.
        sipManager.hangupCall(callId: callId)
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

        // Drive CallKit's lifecycle from the authoritative SIP state.
        // Two transitions matter here:
        //   confirmed   → reportCallConnected (CXCall flips from
        //                 "Connecting…" to live duration timer)
        //   disconnected → reportCallEnded (clears the Dynamic Island
        //                 entry, lets the OS finalize the call log)
        // Note: we DON'T also fire reportCallEnded from hangupCall —
        // hangupCall just initiates teardown; pjsua will follow up
        // with a "disconnected" state change and we report ended once
        // here. Double-reporting leaves a stale call in CallKit's call
        // log on the second invocation.
        switch state {
        case "confirmed":
            callKitManager.reportCallConnected(callId: callId)
        case "disconnected":
            callKitManager.reportCallEnded(callId: callId)
        default:
            break
        }
    }

    func onIncomingCall(callId: String, remoteUri: String, callerName: String?, callUuid: String?) {
        callKitManager.reportIncomingCall(callId: callId, handle: remoteUri, callerName: callerName)

        var data: [String: Any] = ["callId": callId, "remoteUri": remoteUri]
        if let callerName = callerName {
            data["callerName"] = callerName
        }
        // Surface the PBX-side X-Redyrect-Call-UUID header to JS. When
        // the INVITE carries this header (it always should from a
        // Redyrect SBC), callId == callUuid — but we emit both fields
        // anyway so the JS layer doesn't have to know about that
        // identity-conflation rule. Web sip.js layer does the same.
        if let callUuid = callUuid {
            data["callUuid"] = callUuid
        }
        notifyListeners("incomingCall", data: data)
    }
}

// MARK: - PushManagerDelegate

extension PjsipPlugin: PushManagerDelegate {
    func pushManagerDidReceiveVoIPPush(payload: [AnyHashable: Any]) {
        // CallKit was already reported synchronously by PushManager.
        // The remaining work here is native-only — we deliberately do
        // NOT fire a JS `incomingCall` event from the push, because:
        //   - CallKit is the appropriate ringing surface on iOS, not
        //     the in-app overlay. Firing a JS event would race with
        //     CallKit and create a duplicate UI (and a stale Answer
        //     button that calls pjsua.answer on a call that doesn't
        //     exist yet).
        //   - The JS layer learns about the call when the real SIP
        //     INVITE arrives and handleIncomingCall fires its event
        //     with the bridged callId.
        //
        // What we DO here:
        //   1. Tell SipManager which call_uuid is incoming so when
        //      the INVITE arrives carrying X-Redyrect-Call-UUID, the
        //      pluginCallId binds to that pjsua call.
        //   2. Force a fresh SIP REGISTER. iOS tore the TLS socket
        //      when it suspended the app, so FreeSWITCH has a stale
        //      contact — without this REGISTER, the INVITE the PBX
        //      is about to send has nowhere to go and the caller is
        //      bounced to voicemail.
        let callUuid = payload["call_uuid"] as? String
        if let uuid = callUuid {
            sipManager.expectIncomingCall(callUuid: uuid)
        }
        sipManager.forceRegister()
    }

    func pushManagerDidUpdatePushToken(token: String, environment: String) {
        // environment is "sandbox" or "production" — the PBX uses this to
        // pick the right APNs endpoint for THIS specific token, so a debug
        // Xcode build and a TestFlight build of the same app can coexist
        // against the same global config. See PushManager.currentApnsEnvironment.
        notifyListeners("pushTokenUpdated", data: [
            "token": token,
            "platform": "apns",
            "environment": environment,
        ])
    }
}

// MARK: - CallKitManagerDelegate

extension PjsipPlugin: CallKitManagerDelegate {
    func callKitDidAnswerCall(callId: String, completion: @escaping (Bool) -> Void) {
        // Forward the CallKit answer completion through to SipManager.
        // For a real pjsua call this resolves immediately; for a push-
        // only placeholder waiting on the INVITE, SipManager holds the
        // completion until the INVITE lands (then completion(true)) or
        // the 5s budget expires (then completion(false), which lets
        // CallKit fail the action cleanly instead of leaving a stuck
        // entry).
        sipManager.answerCall(callId: callId) { error in
            completion(error == nil)
        }
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
