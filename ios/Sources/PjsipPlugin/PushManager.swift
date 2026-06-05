import Foundation
import PushKit

protocol PushManagerDelegate: AnyObject {
    func pushManagerDidReceiveVoIPPush(payload: [AnyHashable: Any])
    func pushManagerDidUpdatePushToken(token: String, environment: String)
}

/// The APNs environment this build will receive pushes from. Debug-signed
/// builds from Xcode use the sandbox gateway; release builds (Ad-hoc,
/// TestFlight, App Store) use the production gateway. Apple gives no
/// runtime API for this — the conventional and reliable signal is the
/// build configuration. PBX uses this to pick the right APNs endpoint
/// per device instead of a global flag.
private func currentApnsEnvironment() -> String {
    #if DEBUG
    return "sandbox"
    #else
    return "production"
    #endif
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
        let env = currentApnsEnvironment()
        print("[PushManager] VoIP push token: \(token) (env: \(env))")
        delegate?.pushManagerDidUpdatePushToken(token: token, environment: env)
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }

        let data = payload.dictionaryPayload

        // Extract call info from the push payload. The PBX sends:
        //   {
        //     "call_uuid": "<freeswitch-channel-uuid>",
        //     "callee_extension": "<dest>",
        //     "caller_id_number": "<from-number>",
        //     "caller_id_name": "<from-display>",
        //     "server_time": "<rfc3339>"
        //   }
        // The call_uuid value also appears as the X-Redyrect-Call-UUID
        // header on the eventual SIP INVITE, so we use it as the
        // CallKit + plugin call id from the start — push, INVITE, and
        // answer all share one identifier.
        let callId = data["call_uuid"] as? String ?? "push-\(UUID().uuidString)"
        let handle = (data["caller_id_number"] as? String)
            ?? (data["callee_extension"] as? String)
            ?? "unknown"
        let callerName = data["caller_id_name"] as? String

        // STEP 1: Report to CallKit IMMEDIATELY — this MUST happen before completion()
        // This is the strict iOS 13+ requirement.
        guard let callKit = callKitManager else {
            print("[PushManager] ERROR: CallKitManager not set — cannot report incoming call!")
            // Still must report something or iOS kills us. Report and immediately end.
            let fallbackKit = CallKitManager()
            fallbackKit.reportIncomingCall(callId: callId, handle: handle, callerName: callerName)
            completion()
            return
        }

        callKit.reportIncomingCall(callId: callId, handle: handle, callerName: callerName)

        // STEP 2: Notify delegate (plugin) so it can wake PJSIP, fire
        // an immediate REGISTER so FreeSWITCH has a live contact for
        // the INVITE, and emit JS events.
        delegate?.pushManagerDidReceiveVoIPPush(payload: data)

        // STEP 3: Call completion — CallKit has already been notified
        completion()
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("[PushManager] Push token invalidated for type: \(type)")
    }
}
