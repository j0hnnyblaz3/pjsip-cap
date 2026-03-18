import Foundation
import CallKit
import AVFoundation

protocol CallKitManagerDelegate: AnyObject {
    func callKitDidAnswerCall(callId: String)
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
        let uuid = UUID()
        callMap[uuid] = callId
        reverseCallMap[callId] = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsDTMF = true

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("[CallKitManager] Report incoming call error: \(error)")
                self.callMap.removeValue(forKey: uuid)
                self.reverseCallMap.removeValue(forKey: callId)
            }
        }
    }

    func reportOutgoingCall(callId: String, handle: String) {
        let uuid = UUID()
        callMap[uuid] = callId
        reverseCallMap[callId] = uuid

        let callHandle = CXHandle(type: .generic, value: handle)
        let startAction = CXStartCallAction(call: uuid, handle: callHandle)
        startAction.isVideo = false

        let transaction = CXTransaction(action: startAction)
        callController.request(transaction) { error in
            if let error = error {
                print("[CallKitManager] Start call error: \(error)")
            } else {
                self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
            }
        }
    }

    func reportCallConnected(callId: String) {
        guard let uuid = reverseCallMap[callId] else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }

    func reportCallEnded(callId: String) {
        guard let uuid = reverseCallMap[callId] else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        callMap.removeValue(forKey: uuid)
        reverseCallMap.removeValue(forKey: callId)
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

        configureAudioSession()
        delegate?.callKitDidAnswerCall(callId: callId)
        action.fulfill()
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
        // PJSIP should be notified that audio session is active
        // TODO: Notify PJSIP to start audio
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // TODO: Notify PJSIP to stop audio
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            print("[CallKitManager] Audio session error: \(error)")
        }
    }
}
