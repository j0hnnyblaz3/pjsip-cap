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

    func reportIncomingCall(callId: String, handle: String, callerName: String?) {
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
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsDTMF = true

        if let existingUuid = reverseCallMap[callId] {
            print("[CallKitManager] reportIncomingCall: \(callId) already known — updating CXCall in place")
            provider.reportCall(with: existingUuid, updated: update)
            return
        }

        let uuid = UUID()
        callMap[uuid] = callId
        reverseCallMap[callId] = uuid

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("[CallKitManager] Report incoming call error: \(error)")
                self.callMap.removeValue(forKey: uuid)
                self.reverseCallMap.removeValue(forKey: callId)
            }
        }
    }

    func reportOutgoingCall(callId: String, handle: String, callerName: String? = nil) {
        let uuid = UUID()
        callMap[uuid] = callId
        reverseCallMap[callId] = uuid
        outboundCallIds.insert(callId)

        let callHandle = CXHandle(type: .generic, value: handle)
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
                print("[CallKitManager] Start call error: \(error)")
                return
            }
            self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
            // Push the real caller name into CallKit so the Dynamic
            // Island / Phone-app UI shows the contact's name instead
            // of the URI handle. Without this, iOS displays whatever
            // string we passed as the handle — usually a sip URI or
            // a bare Firebase UID, which is meaningless to a human.
            if let callerName = callerName, !callerName.isEmpty {
                let update = CXCallUpdate()
                update.remoteHandle = callHandle
                update.localizedCallerName = callerName
                update.hasVideo = false
                update.supportsHolding = true
                update.supportsDTMF = true
                self.provider.reportCall(with: uuid, updated: update)
            }
        }
    }

    func reportCallConnected(callId: String) {
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
            action.fail()
            return
        }

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
                } else {
                    action.fail()
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let callId = callMap[action.callUUID] else {
            action.fail()
            return
        }

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
        print("[CallKitManager] AVAudioSession activated by CallKit — attaching PJSIP sound device")
        SipManager.shared.startAudioDevice()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Detach PJSIP from the device so it doesn't keep AURemoteIO
        // alive when CallKit has released the session. Signaling
        // (REGISTER, INVITE) continues independently.
        print("[CallKitManager] AVAudioSession deactivated by CallKit — detaching PJSIP sound device")
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
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers]
            )
        } catch {
            print("[CallKitManager] Audio session category error: \(error)")
        }
    }
}
