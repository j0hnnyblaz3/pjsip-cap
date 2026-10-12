import Foundation
import CallKit
import AVFoundation

protocol CallKitManagerDelegate: AnyObject {
    /// Called when the user taps Accept in CallKit. The delegate MUST
    /// call `completion(true)` when the underlying SIP call has been
    /// answered, or `completion(false)` if the answer attempt failed
    /// (e.g. no INVITE arrived in time after a VoIP push). CallKit
    /// then either fulfills or fails the CXAnswerCallAction —
    /// failing surfaces a clean "Call Failed" to the user instead of
    /// a stuck call entry with no audio.
    func callKitDidAnswerCall(callId: String, completion: @escaping (Bool) -> Void)
    func callKitDidEndCall(callId: String)
    func callKitDidSetHeld(callId: String, isOnHold: Bool)
    func callKitDidSetMuted(callId: String, isMuted: Bool)
}

class CallKitManager: NSObject {
    weak var delegate: CallKitManagerDelegate?

    private let provider: CXProvider
    private let callController = CXCallController()

    /// Maps CXCall UUIDs to plugin callIds
    private var callMap: [UUID: String] = [:]
    private var reverseCallMap: [String: UUID] = [:]
    /// Tracks call direction so reportCallConnected can pick the right
    /// CallKit API. Inbound calls flip to "connected" via the answer
    /// action's fulfill(); outbound calls need an explicit
    /// reportOutgoingCall(connectedAt:). Calling the outbound API on
    /// an inbound call confuses CallKit's call-log state.
    private var outboundCallIds: Set<String> = []

    override init() {
        let config = CXProviderConfiguration()
        config.maximumCallsPerCallGroup = 1
        config.supportsVideo = false
        config.supportedHandleTypes = [.phoneNumber, .generic]
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: - Reporting calls to CallKit
    //
    // The call maps are CallKit's state and live on the main thread, where
    // CXProvider delivers its actions (delegate queue nil). Plugin methods
    // arrive on the Capacitor bridge thread, so each entry point hops to main
    // first; on main already (PushKit's queue) it runs inline, which keeps
    // reportNewIncomingCall inside the push handler as PushKit requires.

    func reportIncomingCall(callId: String, handle: String, callerName: String?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.reportIncomingCall(callId: callId, handle: handle, callerName: callerName) }
            return
        }
        // Dedup by callId. Both the VoIP push path and PJSIP's
        // on_incoming_call (after the INVITE lands) end up calling
        // this with the same callId — the push uses call_uuid, the
        // INVITE bridges via X-Redyrect-Call-UUID, they're identical.
        // Without this guard, the second call creates a brand-new
        // CXCall with a fresh UUID, leaving the first one orphaned:
        // CallKit then shows a "still ringing" Dynamic Island pill
        // for the orphan even after the user answered the real one.
        // reportCallEnded() only knows about the second (latest)
        // UUID since reverseCallMap overwrote, so the orphan never
        // gets cleaned up either — the user has to force-quit.
        //
        // The right thing here is to update the EXISTING CXCall with
        // whatever fresher caller info the second report carries.
        // CXProvider.reportCall(with:updated:) does that without
        // creating a new entry.
        // Sanitize the handle BEFORE handing it to CallKit. The handle
        // is what iOS persists to the Phone app's Recents log; a raw
        // SIP URI / UID stays there forever. friendlyHandleValue
        // collapses UID-shaped strings into "Circles caller" and
        // preserves PSTN-style phone numbers.
        let friendlyHandleString = friendlyHandleValue(
            handle: handle,
            callerName: callerName,
        )
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: friendlyHandleString)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsDTMF = true

        if let existingUuid = reverseCallMap[callId] {
            pjsipLog("[CallKitManager] reportIncomingCall: \(callId) already known — updating CXCall in place")
            provider.reportCall(with: existingUuid, updated: update)
            return
        }

        let uuid = UUID()
        callMap[uuid] = callId
        reverseCallMap[callId] = uuid

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                pjsipLog("[CallKitManager] Report incoming call error: \(error)")
                self.callMap.removeValue(forKey: uuid)
                self.reverseCallMap.removeValue(forKey: callId)
            }
        }
    }

    // MARK: - Requests from the app
    //
    // CallKit owns a call's lifecycle. The app's own Accept and Hang Up
    // buttons ask CallKit, exactly as the system UI does, so answering and
    // ending always run through the action handlers below — which drive
    // PJSIP and, for an answer, activate the audio session. Answering pjsua
    // directly left CallKit holding a still-ringing call with no audio
    // session, which CallKit then ended on its own.

    /// Ask CallKit to answer `callId`. Completion reports whether CallKit
    /// accepted the request; the answer itself surfaces as call state.
    func requestAnswer(callId: String, completion: @escaping (Error?) -> Void) {
        request(callId: callId, label: "answer", completion: completion) { CXAnswerCallAction(call: $0) }
    }

    /// Ask CallKit to end `callId`, as the system End button does.
    func requestEnd(callId: String, completion: @escaping (Error?) -> Void) {
        request(callId: callId, label: "end", completion: completion) { CXEndCallAction(call: $0) }
    }

    /// Ask CallKit to hold or resume `callId`, so the system UI shows it.
    func requestHold(callId: String, onHold: Bool, completion: @escaping (Error?) -> Void) {
        request(callId: callId, label: onHold ? "hold" : "resume", completion: completion) {
            CXSetHeldCallAction(call: $0, onHold: onHold)
        }
    }

    /// Ask CallKit to mute or unmute `callId`, so the system UI shows it.
    func requestMute(callId: String, muted: Bool, completion: @escaping (Error?) -> Void) {
        request(callId: callId, label: muted ? "mute" : "unmute", completion: completion) {
            CXSetMutedCallAction(call: $0, muted: muted)
        }
    }

    private func request(
        callId: String,
        label: String,
        completion: @escaping (Error?) -> Void,
        action: @escaping (UUID) -> CXCallAction
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.request(callId: callId, label: label, completion: completion, action: action) }
            return
        }
        guard let uuid = reverseCallMap[callId] else {
            pjsipLog("[CallKitManager] request \(label): CallKit has no call \(callId)")
            completion(NSError(
                domain: "PjsipPlugin",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "CallKit has no call \(callId)"]
            ))
            return
        }
        pjsipLog("[CallKitManager] request \(label): \(callId)")
        callController.request(CXTransaction(action: action(uuid))) { error in
            if let error = error {
                pjsipLog("[CallKitManager] request \(label) refused for \(callId): \(error)")
            }
            DispatchQueue.main.async { completion(error) }
        }
    }

    func reportOutgoingCall(callId: String, handle: String, callerName: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.reportOutgoingCall(callId: callId, handle: handle, callerName: callerName) }
            return
        }
        let uuid = UUID()
        callMap[uuid] = callId
        reverseCallMap[callId] = uuid
        outboundCallIds.insert(callId)

        // The CXHandle is what iOS persists to the system Phone app's
        // Recents log — NOT just what shows in the live Dynamic
        // Island. Anything we pass here ends up in the user's call
        // history forever, so it must be human-readable from the
        // first call. `friendlyHandleValue` collapses UID-shaped
        // strings into "Circles caller" so a raw Firebase UID never
        // leaks into the system call log.
        let initialHandleValue = friendlyHandleValue(
            handle: handle,
            callerName: callerName,
        )
        let callHandle = CXHandle(type: .generic, value: initialHandleValue)
        let startAction = CXStartCallAction(call: uuid, handle: callHandle)
        startAction.isVideo = false
        // CXStartCallAction.contactIdentifier is a hint CallKit uses
        // when constructing the call's identity. It's a soft signal —
        // the authoritative label comes from CXCallUpdate (set below
        // once the action completes).
        if let callerName = callerName {
            startAction.contactIdentifier = callerName
        }

        let transaction = CXTransaction(action: startAction)
        callController.request(transaction) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                pjsipLog("[CallKitManager] Start call error: \(error)")
                return
            }
            self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
            // Refresh the call's identity once the start action is
            // accepted. localizedCallerName drives the Dynamic Island;
            // remoteHandle drives Phone Recents. Both must be the
            // friendly value — passing the URI through here is what
            // historically leaked UIDs into the call log.
            if let callerName = callerName, !callerName.isEmpty {
                let update = CXCallUpdate()
                update.remoteHandle = CXHandle(type: .generic, value: callerName)
                update.localizedCallerName = callerName
                update.hasVideo = false
                update.supportsHolding = true
                update.supportsDTMF = true
                self.provider.reportCall(with: uuid, updated: update)
            }
        }
    }

    /// Update both the localized caller name AND the handle on an
    /// already-reported CXCall. Used after JS resolves an inbound
    /// call's uid to a real user — the initial reportIncomingCall
    /// had only "Circles caller" / a phone number / etc. as the
    /// handle (UIDs were stripped via `friendlyHandleValue`), and
    /// the Dynamic Island / Recents UI shows that until we update.
    ///
    /// Updating remoteHandle (not just localizedCallerName) is
    /// critical: iOS Phone's Recents log persists the handle, not
    /// the name overlay. So a call that was answered + ended before
    /// updateCallDisplay fired would still show the placeholder in
    /// Recents unless we also write the resolved name to the handle.
    func updateCallDisplay(callId: String, callerName: String?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.updateCallDisplay(callId: callId, callerName: callerName) }
            return
        }
        guard let uuid = reverseCallMap[callId] else { return }
        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        if let name = callerName, !name.isEmpty {
            update.remoteHandle = CXHandle(type: .generic, value: name)
        }
        provider.reportCall(with: uuid, updated: update)
    }

    /// Produce a human-readable CXHandle value from a SIP URI / raw
    /// handle. Hard rule: the result NEVER contains a Firebase UID or
    /// PBX-internal `u_<hex>` identifier — those leak into iOS Phone's
    /// Recents log otherwise (CXHandle.value is what shows there, not
    /// localizedCallerName). Priority order:
    ///   1. `callerName` — when the dialer already resolved the
    ///      contact, use the human name directly.
    ///   2. The user-part of the URI when it's PSTN-shaped
    ///      (`+`-prefixed or all-digit) — keeps useful info like
    ///      phone numbers visible.
    ///   3. The user-part when it's clearly NOT a uid (not 20+
    ///      alphanumerics, not `u_<hex>`).
    ///   4. Fallback: `Circles caller` — generic but safe; never a uid.
    private func friendlyHandleValue(handle: String, callerName: String?) -> String {
        if let name = callerName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        let userPart = extractUserPart(from: handle)
        if looksLikePhoneNumber(userPart) {
            return userPart
        }
        if !looksLikeIdentifier(userPart) {
            return userPart
        }
        return "Circles caller"
    }

    /// Pull the user portion out of `sip:user@host`, `sips:user@host`,
    /// or the bracketed `"Display" <sip:user@host>` form PJSIP gives
    /// us. Returns the raw input when it isn't URI-shaped.
    private func extractUserPart(from value: String) -> String {
        if let angle = value.range(
            of: #"<sips?:([^@>]+)"#,
            options: .regularExpression
        ) {
            let matched = String(value[angle])
            if let colon = matched.firstIndex(of: ":") {
                return String(matched[matched.index(after: colon)...])
            }
        }
        let stripped: String
        if value.hasPrefix("sip:") {
            stripped = String(value.dropFirst("sip:".count))
        } else if value.hasPrefix("sips:") {
            stripped = String(value.dropFirst("sips:".count))
        } else {
            stripped = value
        }
        if let at = stripped.firstIndex(of: "@") {
            return String(stripped[..<at])
        }
        return stripped
    }

    /// Firebase UIDs (~28 char [A-Za-z0-9]) or `u_<hex>` PBX internal
    /// IDs — anything that's a machine identifier rather than something
    /// a human would recognize.
    private func looksLikeIdentifier(_ s: String) -> Bool {
        if s.range(of: #"^u_[A-Fa-f0-9]+$"#, options: .regularExpression) != nil {
            return true
        }
        return s.range(of: #"^[A-Za-z0-9]{20,}$"#, options: .regularExpression) != nil
    }

    /// `+15551234567` or `5551234567` — keep these visible in Recents
    /// since they're actually useful for the user (caller IDs from
    /// the PSTN side of the SBC).
    private func looksLikePhoneNumber(_ s: String) -> Bool {
        return s.range(of: #"^\+?[0-9]{4,15}$"#, options: .regularExpression) != nil
    }

    func reportCallConnected(callId: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.reportCallConnected(callId: callId) }
            return
        }
        guard let uuid = reverseCallMap[callId] else { return }
        // Only outbound calls need the explicit connectedAt report —
        // inbound calls flip from ringing to connected when the
        // CXAnswerCallAction is fulfilled. Calling
        // reportOutgoingCall(connectedAt:) on an inbound entry
        // would re-classify the call type and confuse the call log.
        guard outboundCallIds.contains(callId) else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }

    func reportCallEnded(callId: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.reportCallEnded(callId: callId) }
            return
        }
        guard let uuid = reverseCallMap[callId] else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        callMap.removeValue(forKey: uuid)
        reverseCallMap.removeValue(forKey: callId)
        outboundCallIds.remove(callId)
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        callMap.removeAll()
        reverseCallMap.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let callId = callMap[action.callUUID] else {
            pjsipLog("[CallKitManager] answer action: no call for \(action.callUUID) — failing")
            action.fail()
            return
        }
        pjsipLog("[CallKitManager] answer action: \(callId)")

        // Defer fulfill — we don't know yet if the answer will
        // actually succeed. If the call is push-only (CallKit-reported
        // from a VoIP push, INVITE not yet received), the delegate
        // will hold the completion until the INVITE lands or a short
        // grace window expires. That avoids fulfilling the action and
        // then having AVAudioSession activation silently fail with
        // nothing for CallKit to attach audio to.
        delegate?.callKitDidAnswerCall(callId: callId) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.configureAudioSession()
                    action.fulfill()
                    pjsipLog("[CallKitManager] answer action fulfilled: \(callId)")
                } else {
                    action.fail()
                    pjsipLog("[CallKitManager] answer action failed: \(callId)")
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let callId = callMap[action.callUUID] else {
            pjsipLog("[CallKitManager] end action: no call for \(action.callUUID) — failing")
            action.fail()
            return
        }
        pjsipLog("[CallKitManager] end action: \(callId)")

        delegate?.callKitDidEndCall(callId: callId)
        callMap.removeValue(forKey: action.callUUID)
        reverseCallMap.removeValue(forKey: callId)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard let callId = callMap[action.callUUID] else {
            action.fail()
            return
        }
        delegate?.callKitDidSetHeld(callId: callId, isOnHold: action.isOnHold)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard let callId = callMap[action.callUUID] else {
            action.fail()
            return
        }
        delegate?.callKitDidSetMuted(callId: callId, isMuted: action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSession()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CallKit has activated AVAudioSession — only now is it safe
        // for PJSIP to open the audio device. The PJSIP/iOS recipe is:
        //  1. At pjsua_start, call pjsua_set_no_snd_dev (detach).
        //  2. On CallKit didActivate, call pjsua_set_snd_dev (attach).
        //  3. On CallKit didDeactivate, call pjsua_set_no_snd_dev.
        // Without (2), PJSIP's AURemoteIO unit fails to enable with
        // status 561017449 on every sample rate because the session
        // isn't active when it tries to open the device. Calls reach
        // "confirmed" but no audio flows.
        pjsipLog("[CallKitManager] AVAudioSession activated by CallKit — attaching PJSIP sound device")
        SipManager.shared.startAudioDevice()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Detach PJSIP from the device so it doesn't keep AURemoteIO
        // alive when CallKit has released the session. Signaling
        // (REGISTER, INVITE) continues independently.
        pjsipLog("[CallKitManager] AVAudioSession deactivated by CallKit — detaching PJSIP sound device")
        SipManager.shared.stopAudioDevice()
    }

    // MARK: - Audio Session

    /// Configure the AVAudioSession category for a voice call.
    /// Deliberately does NOT call `setActive(true)` — per Apple's
    /// CallKit documentation, the framework activates the session
    /// itself once the call action is fulfilled. Calling setActive
    /// ourselves races CallKit's activation and leaves the session
    /// in a half-state where AVAudioSession reports "active" but
    /// PJSIP's coreaudio backend can't open the device — calls
    /// connect but no audio flows in either direction.
    ///
    /// Setting the category here (before action.fulfill) is fine
    /// and is actually required — CallKit only handles activation,
    /// not category selection.
    /// Speaker / earpiece / Bluetooth: an override on the audio session this
    /// class configures for the call — the owner of call audio on iOS, as
    /// Telecom is on Android.
    func setAudioRoute(route: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            // Don't re-set the category here. CallKit (via
            // CallKitManager.configureAudioSession) already chose
            // (.playAndRecord, .voiceChat) with [.allowBluetooth,
            // .allowBluetoothA2DP, .duckOthers]. If we re-set without
            // carrying the same options, the speaker toggle strips
            // Bluetooth support mid-call — user taps Speaker and their
            // AirPods get dropped. The route override below is what
            // actually switches the speaker/earpiece/BT path; it
            // doesn't need a category change first.
            switch route {
            case "speaker":
                try session.overrideOutputAudioPort(.speaker)
            case "earpiece":
                try session.overrideOutputAudioPort(.none)
            case "bluetooth":
                let bluetoothRoutes: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
                if let availableInputs = session.availableInputs,
                   let btInput = availableInputs.first(where: { bluetoothRoutes.contains($0.portType) }) {
                    try session.setPreferredInput(btInput)
                }
            default:
                break
            }
        } catch {
            pjsipLog("[CallKitManager] Audio route error: \(error)")
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers]
            )
        } catch {
            pjsipLog("[CallKitManager] Audio session category error: \(error)")
        }
    }
}
