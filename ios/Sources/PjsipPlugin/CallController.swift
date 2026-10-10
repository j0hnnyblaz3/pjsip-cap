import Foundation

/// Where the call controller sends events for the app. `PjsipPlugin`
/// implements it by forwarding to Capacitor's `notifyListeners`.
protocol CallEventSink: AnyObject {
    func emit(event: String, data: [String: Any])
}

/// The one owner of a call's lifecycle on iOS.
///
/// - The app's requests — answer, end, hold, mute — go to CallKit, exactly as
///   the system call UI's do, so every call is answered and ended through
///   CallKit's actions (which also activate and release the audio session).
/// - CallKit's actions drive the SIP engine.
/// - SIP events are mirrored onto CallKit and emitted to the app.
/// - VoIP pushes and incoming INVITEs are reported to CallKit.
///
/// Each collaborator does one thing: `SipManager` SIP, `CallKitManager`
/// CallKit, `PushManager` PushKit, `PjsipPlugin` the bridge to JS.
final class CallController: NSObject {
    weak var events: CallEventSink?

    private let sip: SipManager
    private let callKit: CallKitManager
    private let push: PushManager
    /// Every call event the app gets — see `CallLedger`. Main thread.
    private lazy var ledger = CallLedger { [weak self] snapshot in
        self?.events?.emit(event: "callUpdated", data: snapshot)
    }
    /// The caller name each VoIP push carried, for an INVITE without one.
    private var pushedNames: [String: String] = [:]

    override init() {
        sip = SipManager.shared
        callKit = CallKitManager()
        push = PushManager()
        super.init()
        sip.delegate = self
        callKit.delegate = self
        push.delegate = self
        // Direct reference so a VoIP push is reported to CallKit inside the
        // PushKit handler, as iOS 13+ requires.
        push.callKitManager = callKit
    }

    // MARK: - Registration

    var registrationState: String { sip.registrationState }

    func register(config: SipConfig, completion: @escaping (Error?) -> Void) {
        sip.register(config: config, completion: completion)
    }

    func unregister(completion: @escaping (Error?) -> Void) {
        push.unregister()
        sip.unregister(completion: completion)
    }

    func registerPush() { push.registerForVoIPPushes() }
    func unregisterPush() { push.unregister() }

    // MARK: - Calls

    /// Place a call and report it to CallKit. `displayName` is what CallKit
    /// shows instead of the raw SIP URI.
    func makeCall(uri: String, displayName: String?) throws -> String {
        let callId = try sip.makeCall(uri: uri)
        onMain { [self] in
            ledger.open(callId: callId, incoming: false, state: "calling", remoteUri: uri, callerName: displayName)
        }
        callKit.reportOutgoingCall(callId: callId, handle: uri, callerName: displayName)
        return callId
    }

    /// Answer through CallKit, like the system Accept button.
    func answer(callId: String, completion: @escaping (Error?) -> Void) {
        callKit.requestAnswer(callId: callId, completion: completion)
    }

    /// End through CallKit, like the system End button. A call CallKit never
    /// took (its report failed) is still ended — in SIP directly — so a
    /// hangup can never leave a call up.
    func end(callId: String, completion: @escaping () -> Void) {
        onMain { [self] in ledger.endingHere(callId: callId) }
        callKit.requestEnd(callId: callId) { [weak self] error in
            if error != nil {
                pjsipLog("[CallController] end \(callId): CallKit refused — ending the SIP call directly")
                self?.sip.hangupCall(callId: callId)
            }
            completion()
        }
    }

    /// Hold or resume through CallKit; SIP directly if CallKit has no call.
    func hold(callId: String, hold: Bool) {
        callKit.requestHold(callId: callId, onHold: hold) { [weak self] error in
            if error != nil {
                pjsipLog("[CallController] hold \(callId): CallKit refused — holding the SIP call directly")
                self?.sip.holdCall(callId: callId, hold: hold)
            }
        }
    }

    /// Mute or unmute through CallKit; SIP directly if CallKit has no call.
    func mute(callId: String, mute: Bool) {
        callKit.requestMute(callId: callId, muted: mute) { [weak self] error in
            if error != nil {
                pjsipLog("[CallController] mute \(callId): CallKit refused — muting the SIP call directly")
                self?.sip.muteCall(callId: callId, mute: mute)
            }
        }
    }

    func sendDtmf(callId: String, digit: String) { sip.sendDtmf(callId: callId, digit: digit) }
    func transfer(callId: String, target: String) { sip.transferCall(callId: callId, target: target) }
    func setAudioRoute(_ route: String) { sip.setAudioRoute(route: route) }
    /// Every live call, as the app's snapshots — from the ledger, so it never
    /// touches pjsua (whose thread checks aborted the app when this ran on
    /// the bridge thread).
    func activeCalls() -> [[String: Any]] {
        if Thread.isMainThread { return ledger.active() }
        return DispatchQueue.main.sync { ledger.active() }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    func updateCallDisplay(callId: String, displayName: String?) {
        callKit.updateCallDisplay(callId: callId, callerName: displayName)
    }
}

// MARK: - SIP engine events

extension CallController: SipManagerDelegate {
    func onRegistrationStateChanged(state: String, reason: String?) {
        var data: [String: Any] = ["state": state]
        if let reason = reason {
            data["reason"] = reason
        }
        events?.emit(event: "registrationStateChanged", data: data)
    }

    func onCallStateChanged(callId: String, state: String, remoteUri: String?,
                            incoming: Bool, sipStatus: Int, sipReason: String?) {
        // CallKit follows the SIP state from this one place:
        //   confirmed    → reportCallConnected (outbound: live timer)
        //   disconnected → reportCallEnded (clears the call, finalizes the
        //                  call log). Ending through CallKit's end action
        //                  removes the entry first, so this is a no-op then —
        //                  never a second report.
        switch state {
        case "confirmed":
            callKit.reportCallConnected(callId: callId)
        case "disconnected":
            ledger.finish(callId: callId, sipStatus: sipStatus, sipReason: sipReason)
            pushedNames.removeValue(forKey: callId)
            callKit.reportCallEnded(callId: callId)
            return
        default:
            break
        }
        if ledger.has(callId) {
            ledger.update(callId: callId, state: state, remoteUri: remoteUri)
        } else {
            ledger.open(callId: callId, incoming: incoming, state: state, remoteUri: remoteUri)
        }
    }

    func onIncomingCall(callId: String, remoteUri: String, callerName: String?, callUuid: String?) {
        let name = callerName ?? pushedNames[callId]
        callKit.reportIncomingCall(callId: callId, handle: remoteUri, callerName: name)
        ledger.open(callId: callId, incoming: true, state: "incoming",
                    remoteUri: remoteUri, callerName: name, callUuid: callUuid)
    }
}

// MARK: - VoIP push events

extension CallController: PushManagerDelegate {
    func pushManagerDidReceiveVoIPPush(payload: [AnyHashable: Any]) {
        // PushManager has already reported the call to CallKit. No JS event
        // here: CallKit is the ringing surface, and JS learns of the call
        // when the INVITE arrives with the bridged callId.
        //   1. Tell SIP which call_uuid to expect, so the INVITE carrying
        //      X-Redyrect-Call-UUID binds to it.
        //   2. Re-REGISTER: iOS closed the TLS socket while the app was
        //      suspended, so the PBX's contact is stale and the INVITE would
        //      have nowhere to go.
        if let uuid = payload["call_uuid"] as? String {
            if let name = payload["caller_id_name"] as? String, !name.isEmpty {
                pushedNames[uuid] = name
            }
            sip.expectIncomingCall(callUuid: uuid)
        }
        sip.forceRegister()
    }

    func pushManagerDidUpdatePushToken(token: String, environment: String) {
        // environment ("sandbox" / "production") lets the PBX pick the APNs
        // endpoint per token, so debug and TestFlight builds coexist.
        events?.emit(event: "pushTokenUpdated", data: [
            "token": token,
            "platform": "apns",
            "environment": environment,
        ])
    }
}

// MARK: - CallKit actions

extension CallController: CallKitManagerDelegate {
    func callKitDidAnswerCall(callId: String, completion: @escaping (Bool) -> Void) {
        // For a live pjsua call this resolves at once; for a push placeholder
        // still waiting on its INVITE, SipManager holds the completion until
        // the INVITE lands or the answer budget expires, so CallKit fails the
        // action cleanly instead of keeping a stuck entry.
        sip.answerCall(callId: callId) { error in
            completion(error == nil)
        }
    }

    func callKitDidEndCall(callId: String) {
        // The system End/Decline button reaches here without `end`.
        ledger.endingHere(callId: callId)
        sip.hangupCall(callId: callId)
    }

    func callKitDidSetHeld(callId: String, isOnHold: Bool) {
        sip.holdCall(callId: callId, hold: isOnHold)
    }

    func callKitDidSetMuted(callId: String, isMuted: Bool) {
        sip.muteCall(callId: callId, mute: isMuted)
    }
}
