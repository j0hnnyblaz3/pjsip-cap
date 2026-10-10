import Foundation

/// The calls this phone knows about, and the one place `callUpdated` is sent
/// from. It keeps the rules the plugin's `CallSnapshot` promises — one id per
/// call, fields only added, `disconnected` once and then silence — so the
/// engine can report whatever PJSIP tells it, as often as PJSIP tells it.
///
/// The same rules as `src/ledger.ts` (web) and `CallLedger.kt` (Android);
/// change all three together. Main thread only.
final class CallLedger {
    private struct Call {
        let callId: String
        let incoming: Bool
        var state: String
        var remoteUri: String
        var callerName: String?
        var callUuid: String?
        var answered: Bool
        var end: [String: Any]?

        var snapshot: [String: Any] {
            var data: [String: Any] = [
                "callId": callId,
                "direction": incoming ? "incoming" : "outgoing",
                "state": state,
                "remoteUri": remoteUri,
                "answered": answered,
            ]
            if let callerName = callerName { data["callerName"] = callerName }
            if let callUuid = callUuid { data["callUuid"] = callUuid }
            if let end = end { data["end"] = end }
            return data
        }
    }

    private let emit: ([String: Any]) -> Void
    private var calls: [String: Call] = [:]
    /// Order the calls were opened in, for `active()`.
    private var order: [String] = []
    /// Calls this side asked to end, so their end is `local`.
    private var endedHere = Set<String>()
    /// Calls already reported `disconnected`; anything later is dropped.
    private var finished = Set<String>()
    private var lastSent: [String: NSDictionary] = [:]

    init(emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
    }

    /// Start tracking a call, or add what is newly known about it.
    func open(callId: String, incoming: Bool, state: String,
              remoteUri: String? = nil, callerName: String? = nil, callUuid: String? = nil) {
        if finished.contains(callId) { return }
        if calls[callId] != nil {
            merge(callId: callId, remoteUri: remoteUri, callerName: callerName, callUuid: callUuid)
            return
        }
        if state == "disconnected" { return }
        calls[callId] = Call(
            callId: callId,
            incoming: incoming,
            state: state,
            remoteUri: remoteUri ?? "",
            callerName: nonBlank(callerName),
            callUuid: nonBlank(callUuid),
            answered: state == "confirmed"
        )
        order.append(callId)
        send(callId)
    }

    /// Add the caller name, URI or PBX id learned after the call opened.
    func merge(callId: String, remoteUri: String? = nil, callerName: String? = nil, callUuid: String? = nil) {
        guard var call = calls[callId] else { return }
        if let remoteUri = nonBlank(remoteUri) { call.remoteUri = remoteUri }
        if let callerName = nonBlank(callerName) { call.callerName = callerName }
        if let callUuid = nonBlank(callUuid) { call.callUuid = callUuid }
        calls[callId] = call
        send(callId)
    }

    /// The engine's state for a call it already opened.
    func update(callId: String, state: String, remoteUri: String? = nil) {
        guard var call = calls[callId] else { return }
        call.state = state
        if let remoteUri = nonBlank(remoteUri) { call.remoteUri = remoteUri }
        if state == "confirmed" { call.answered = true }
        calls[callId] = call
        send(callId)
    }

    /// This side is ending the call: its end is `local`, whoever finishes it.
    func endingHere(callId: String) {
        if calls[callId] != nil { endedHere.insert(callId) }
    }

    /// The call is over. Sent once; every later report for it is dropped.
    func finish(callId: String, sipStatus: Int? = nil, sipReason: String? = nil) {
        guard var call = calls[callId] else { return }
        call.state = "disconnected"
        var end: [String: Any] = ["by": endedHere.contains(callId) ? "local" : "remote"]
        if let sipStatus = sipStatus, sipStatus > 0 { end["sipStatus"] = sipStatus }
        if let sipReason = nonBlank(sipReason) { end["sipReason"] = sipReason }
        call.end = end
        calls[callId] = call
        send(callId)
        calls.removeValue(forKey: callId)
        order.removeAll { $0 == callId }
        endedHere.remove(callId)
        lastSent.removeValue(forKey: callId)
        finished.insert(callId)
    }

    func has(_ callId: String) -> Bool { calls[callId] != nil }

    /// Every live call, for `getActiveCalls`.
    func active() -> [[String: Any]] {
        order.compactMap { calls[$0]?.snapshot }
    }

    private func send(_ callId: String) {
        guard let snapshot = calls[callId]?.snapshot else { return }
        let key = snapshot as NSDictionary
        if lastSent[callId] == key { return }
        lastSent[callId] = key
        emit(snapshot)
    }

    private func nonBlank(_ s: String?) -> String? {
        guard let s = s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
