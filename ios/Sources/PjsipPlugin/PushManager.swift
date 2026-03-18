import Foundation
import PushKit

protocol PushManagerDelegate: AnyObject {
    func pushManagerDidReceiveVoIPPush(payload: [AnyHashable: Any])
    func pushManagerDidUpdatePushToken(token: String)
}

/// Manages PushKit VoIP push notifications for incoming calls.
///
/// CRITICAL iOS 13+ RULE:
/// When a VoIP push arrives, you MUST report a new incoming call to CallKit
/// synchronously — before the push callback returns. Failure to do so will cause
/// iOS to terminate the app and eventually blacklist it from receiving VoIP pushes.
///
/// This class holds a direct reference to CallKitManager so it can report the
/// incoming call immediately, without going through async delegate chains.
class PushManager: NSObject {
    weak var delegate: PushManagerDelegate?

    /// Direct reference to CallKit — required for synchronous call reporting
    var callKitManager: CallKitManager?

    private var voipRegistry: PKPushRegistry?

    func registerForVoIPPushes() {
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry?.delegate = self
        voipRegistry?.desiredPushTypes = [.voIP]
    }

    func unregister() {
        voipRegistry?.desiredPushTypes = nil
        voipRegistry = nil
    }
}

// MARK: - PKPushRegistryDelegate

extension PushManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }

        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        print("[PushManager] VoIP push token: \(token)")
        delegate?.pushManagerDidUpdatePushToken(token: token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }

        let data = payload.dictionaryPayload

        // Extract call info from push payload.
        // Your push server must include these fields.
        let callId = data["callId"] as? String ?? "push-\(UUID().uuidString)"
        let remoteUri = data["remoteUri"] as? String ?? "unknown"
        let callerName = data["callerName"] as? String

        // STEP 1: Report to CallKit IMMEDIATELY — this MUST happen before completion()
        // This is the strict iOS 13+ requirement.
        guard let callKit = callKitManager else {
            print("[PushManager] ERROR: CallKitManager not set — cannot report incoming call!")
            // Still must report something or iOS kills us. Report and immediately end.
            let fallbackKit = CallKitManager()
            fallbackKit.reportIncomingCall(callId: callId, handle: remoteUri, callerName: callerName)
            completion()
            return
        }

        callKit.reportIncomingCall(callId: callId, handle: remoteUri, callerName: callerName)

        // STEP 2: Notify delegate (plugin) so it can wake PJSIP and emit JS events
        delegate?.pushManagerDidReceiveVoIPPush(payload: data)

        // STEP 3: Call completion — CallKit has already been notified
        completion()
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("[PushManager] Push token invalidated for type: \(type)")
    }
}
