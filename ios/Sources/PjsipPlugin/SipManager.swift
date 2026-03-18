import Foundation
import AVFoundation
import PjsipSDK

struct SipConfig {
    let server: String
    let port: Int
    let username: String
    let password: String
    let domain: String
    let transport: String
    let proxy: String?       // outbound proxy / SBC URI
}

protocol SipManagerDelegate: AnyObject {
    func onRegistrationStateChanged(state: String, reason: String?)
    func onCallStateChanged(callId: String, state: String, remoteUri: String?)
    func onIncomingCall(callId: String, remoteUri: String, callerName: String?)
}

// MARK: - PJSIP Thread

/// A dedicated thread registered with pjlib. All pjsua calls MUST run on this thread.
private class PjsipThread: Thread {
    private let readyGroup = DispatchGroup()
    private var runLoop: CFRunLoop!

    override init() {
        readyGroup.enter()
        super.init()
        name = "pjsip-worker"
        qualityOfService = .userInitiated
    }

    // Must remain alive for the lifetime of the registered thread
    private let threadDescPtr = UnsafeMutablePointer<Int>.allocate(capacity: 64)

    override func main() {
        // Register this thread with pjlib
        threadDescPtr.initialize(repeating: 0, count: 64)
        var threadRef: OpaquePointer? = nil
        pj_thread_register("pjsip-worker", threadDescPtr, &threadRef)

        runLoop = CFRunLoopGetCurrent()
        readyGroup.leave()

        // Keep the thread alive via its run loop
        var sourceCtx = CFRunLoopSourceContext()
        let dummySource = CFRunLoopSourceCreate(nil, 0, &sourceCtx)!
        CFRunLoopAddSource(runLoop, dummySource, .defaultMode)
        CFRunLoopRun()
    }

    /// Execute a block synchronously on the PJSIP thread.
    func performSync(_ block: @escaping () -> Void) {
        if Thread.current === self {
            block()
            return
        }
        readyGroup.wait()
        let group = DispatchGroup()
        group.enter()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            block()
            group.leave()
        }
        CFRunLoopWakeUp(runLoop)
        group.wait()
    }

    /// Execute a block asynchronously on the PJSIP thread.
    func performAsync(_ block: @escaping () -> Void) {
        readyGroup.wait()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

// MARK: - SipManager

/// Wrapper around the PJSIP C (pjsua) library.
/// Uses a singleton so that global C function-pointer callbacks can reach back into Swift.
class SipManager: NSObject {

    static let shared = SipManager()

    weak var delegate: SipManagerDelegate?

    private(set) var registrationState: String = "unregistered"
    private var config: SipConfig?

    /// Maps pjsua_call_id (Int32) -> plugin callId string
    private var callMap: [pjsua_call_id: String] = [:]
    /// Reverse map: plugin callId string -> pjsua_call_id
    private var reverseCallMap: [String: pjsua_call_id] = [:]
    private var callIdCounter = 0

    /// The pjsua account id after successful registration
    private var accountId: pjsua_acc_id = -1

    /// Whether pjsua_create + pjsua_init + pjsua_start have been called
    private var pjsuaStarted = false

    /// Dedicated thread for all PJSIP calls
    private let pjThread = PjsipThread()

    private override init() {
        super.init()
        pjThread.start()
    }

    // MARK: - Registration

    func register(config: SipConfig, completion: @escaping (Error?) -> Void) {
        self.config = config

        delegate?.onRegistrationStateChanged(state: "registering", reason: nil)

        pjThread.performAsync { [weak self] in
            guard let self = self else { return }

            do {
                try self.initPjsua()
                try self.createTransport(config: config)
                try self.startPjsua()
                try self.addAccount(config: config)
            } catch {
                DispatchQueue.main.async {
                    self.registrationState = "failed"
                    self.delegate?.onRegistrationStateChanged(state: "failed", reason: error.localizedDescription)
                    completion(error)
                }
                return
            }

            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }

    func unregister(completion: @escaping (Error?) -> Void) {
        pjThread.performAsync { [weak self] in
            guard let self = self else { return }

            if self.accountId != -1 {
                pjsua_acc_del(self.accountId)
                self.accountId = -1
            }

            if self.pjsuaStarted {
                pjsua_destroy()
                self.pjsuaStarted = false
            }

            DispatchQueue.main.async {
                self.registrationState = "unregistered"
                self.callMap.removeAll()
                self.reverseCallMap.removeAll()
                self.delegate?.onRegistrationStateChanged(state: "unregistered", reason: nil)
                completion(nil)
            }
        }
    }

    // MARK: - PJSUA Initialization

    private func initPjsua() throws {
        guard !pjsuaStarted else { return }

        var status = pjsua_create()
        guard status == Int32(PJ_SUCCESS.rawValue) else {
            throw sipError("pjsua_create failed", status: status)
        }

        var cfg = pjsua_config()
        pjsua_config_default(&cfg)

        // Wire up callbacks
        cfg.cb.on_reg_state2 = onRegState2
        cfg.cb.on_incoming_call = onIncomingCall
        cfg.cb.on_call_state = onCallState
        cfg.cb.on_call_media_state = onCallMediaState

        var logCfg = pjsua_logging_config()
        pjsua_logging_config_default(&logCfg)
        logCfg.level = 4
        logCfg.console_level = 4

        var mediaCfg = pjsua_media_config()
        pjsua_media_config_default(&mediaCfg)
        mediaCfg.snd_auto_close_time = -1  // Keep sound device open

        status = pjsua_init(&cfg, &logCfg, &mediaCfg)
        guard status == Int32(PJ_SUCCESS.rawValue) else {
            pjsua_destroy()
            throw sipError("pjsua_init failed", status: status)
        }
    }

    private func createTransport(config: SipConfig) throws {
        var transportType: pjsip_transport_type_e

        switch config.transport.lowercased() {
        case "tcp":
            transportType = PJSIP_TRANSPORT_TCP
        case "tls":
            transportType = PJSIP_TRANSPORT_TLS
        case "wss":
            transportType = PJSIP_TRANSPORT_TLS
        default:
            transportType = PJSIP_TRANSPORT_UDP
        }

        var transportCfg = pjsua_transport_config()
        pjsua_transport_config_default(&transportCfg)

        var transportId: pjsua_transport_id = -1
        let status = pjsua_transport_create(transportType, &transportCfg, &transportId)
        guard status == Int32(PJ_SUCCESS.rawValue) else {
            throw sipError("pjsua_transport_create failed", status: status)
        }
    }

    private func startPjsua() throws {
        guard !pjsuaStarted else { return }

        let status = pjsua_start()
        guard status == Int32(PJ_SUCCESS.rawValue) else {
            pjsua_destroy()
            throw sipError("pjsua_start failed", status: status)
        }
        pjsuaStarted = true
    }

    private func addAccount(config: SipConfig) throws {
        var accCfg = pjsua_acc_config()
        pjsua_acc_config_default(&accCfg)

        let sipUri = "sip:\(config.username)@\(config.domain)"
        let regUri = "sip:\(config.server):\(config.port)"

        accCfg.id = pj_str_from_swift(sipUri)
        accCfg.reg_uri = pj_str_from_swift(regUri)

        accCfg.cred_count = 1
        accCfg.cred_info.0.realm = pj_str_from_swift("*")
        accCfg.cred_info.0.scheme = pj_str_from_swift("digest")
        accCfg.cred_info.0.username = pj_str_from_swift(config.username)
        accCfg.cred_info.0.data_type = Int32(PJSIP_CRED_DATA_PLAIN_PASSWD.rawValue)
        accCfg.cred_info.0.data = pj_str_from_swift(config.password)

        // Outbound proxy
        if let proxy = config.proxy, !proxy.isEmpty {
            accCfg.proxy_cnt = 1
            accCfg.proxy.0 = pj_str_from_swift(proxy)
        }

        accCfg.reg_retry_interval = 300
        accCfg.reg_first_retry_interval = 30

        var accId: pjsua_acc_id = -1
        let status = pjsua_acc_add(&accCfg, pj_bool_t(1), &accId)
        guard status == Int32(PJ_SUCCESS.rawValue) else {
            throw sipError("pjsua_acc_add failed", status: status)
        }

        self.accountId = accId
    }

    // MARK: - Calls

    func makeCall(uri: String) -> String? {
        guard accountId != -1 else { return nil }

        var resultCallId: String? = nil

        pjThread.performSync { [self] in
            callIdCounter += 1
            let pluginCallId = "ios-call-\(callIdCounter)"

            var pjUri = pj_str_from_swift(uri)
            var pjCallId: pjsua_call_id = -1

            let status = pjsua_call_make_call(accountId, &pjUri, nil, nil, nil, &pjCallId)
            guard status == Int32(PJ_SUCCESS.rawValue) else {
                print("[SipManager] makeCall failed: \(status)")
                return
            }

            callMap[pjCallId] = pluginCallId
            reverseCallMap[pluginCallId] = pjCallId
            resultCallId = pluginCallId
        }

        if let callId = resultCallId {
            delegate?.onCallStateChanged(callId: callId, state: "calling", remoteUri: uri)
        }
        return resultCallId
    }

    func answerCall(callId: String, completion: ((Error?) -> Void)?) {
        guard let pjCallId = reverseCallMap[callId] else {
            completion?(NSError(domain: "PjsipPlugin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Call not found"]))
            return
        }

        pjThread.performAsync { [self] in
            let status = pjsua_call_answer(pjCallId, 200, nil, nil)
            if status == Int32(PJ_SUCCESS.rawValue) {
                DispatchQueue.main.async { completion?(nil) }
            } else {
                DispatchQueue.main.async { completion?(self.sipError("pjsua_call_answer failed", status: status)) }
            }
        }
    }

    func hangupCall(callId: String) {
        guard let pjCallId = reverseCallMap[callId] else { return }

        pjThread.performAsync { [self] in
            pjsua_call_hangup(pjCallId, 0, nil, nil)
        }
        callMap.removeValue(forKey: pjCallId)
        reverseCallMap.removeValue(forKey: callId)
        delegate?.onCallStateChanged(callId: callId, state: "disconnected", remoteUri: nil)
    }

    // MARK: - In-call controls

    func holdCall(callId: String, hold: Bool) {
        guard let pjCallId = reverseCallMap[callId] else { return }

        pjThread.performAsync {
            if hold {
                pjsua_call_set_hold(pjCallId, nil)
            } else {
                pjsua_call_reinvite(pjCallId, UInt32(1), nil)
            }
        }
    }

    func muteCall(callId: String, mute: Bool) {
        guard let pjCallId = reverseCallMap[callId] else { return }

        pjThread.performAsync { [self] in
            guard let info = self.getCallInfo(pjCallId) else { return }
            if mute {
                pjsua_conf_adjust_tx_level(info.conf_slot, 0.0)
            } else {
                pjsua_conf_adjust_tx_level(info.conf_slot, 1.0)
            }
        }
    }

    func sendDtmf(callId: String, digit: String) {
        guard let pjCallId = reverseCallMap[callId] else { return }

        pjThread.performAsync {
            var digits = pj_str_from_swift(digit)
            pjsua_call_dial_dtmf(pjCallId, &digits)
        }
    }

    func transferCall(callId: String, target: String) {
        guard let pjCallId = reverseCallMap[callId] else { return }

        pjThread.performAsync {
            var dest = pj_str_from_swift(target)
            pjsua_call_xfer(pjCallId, &dest, nil)
        }
    }

    func setAudioRoute(route: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat)
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
            print("[SipManager] Audio route error: \(error)")
        }
    }

    // MARK: - PJSIP Callback Handlers (called from PJSIP's internal thread)

    func handleRegistrationStateChange(accountId: pjsua_acc_id, info: pjsua_reg_info) {
        let code = info.cbparam.pointee.code
        let state: String
        let reason: String?

        if code / 100 == 2 {
            state = "registered"
            reason = nil
        } else if code == 0 {
            state = "unregistered"
            reason = nil
        } else {
            state = "failed"
            reason = "SIP \(code)"
        }

        DispatchQueue.main.async { [weak self] in
            self?.registrationState = state
            self?.delegate?.onRegistrationStateChanged(state: state, reason: reason)
        }
    }

    func handleIncomingCall(accountId: pjsua_acc_id, pjCallId: pjsua_call_id, rdata: UnsafeMutablePointer<pjsip_rx_data>?) {
        callIdCounter += 1
        let pluginCallId = "ios-call-\(callIdCounter)"

        callMap[pjCallId] = pluginCallId
        reverseCallMap[pluginCallId] = pjCallId

        // Extract remote URI and caller name from call info
        var remoteUri = "unknown"
        var callerName: String? = nil

        if let info = getCallInfo(pjCallId) {
            remoteUri = pjStringToSwift(info.remote_info)
            callerName = extractDisplayName(from: remoteUri)
        }

        // Ring the call (180 Ringing)
        pjsua_call_answer(pjCallId, 180, nil, nil)

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.onIncomingCall(callId: pluginCallId, remoteUri: remoteUri, callerName: callerName)
        }
    }

    func handleCallStateChange(pjCallId: pjsua_call_id) {
        guard let info = getCallInfo(pjCallId) else { return }

        let pluginCallId = callMap[pjCallId] ?? "unknown-\(pjCallId)"
        let state = mapCallState(info.state)
        let remoteUri = pjStringToSwift(info.remote_info)

        if info.state == PJSIP_INV_STATE_DISCONNECTED {
            callMap.removeValue(forKey: pjCallId)
            reverseCallMap.removeValue(forKey: pluginCallId)
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.onCallStateChanged(callId: pluginCallId, state: state, remoteUri: remoteUri)
        }
    }

    func handleCallMediaState(pjCallId: pjsua_call_id) {
        guard let info = getCallInfo(pjCallId) else { return }

        // Connect call audio to the sound device when media is active
        if info.media_status == PJSUA_CALL_MEDIA_ACTIVE {
            pjsua_conf_connect(info.conf_slot, 0)  // call -> speaker
            pjsua_conf_connect(0, info.conf_slot)  // mic -> call
        }
    }

    // MARK: - Helpers

    private func getCallInfo(_ pjCallId: pjsua_call_id) -> pjsua_call_info? {
        var info = pjsua_call_info()
        let status = pjsua_call_get_info(pjCallId, &info)
        guard status == Int32(PJ_SUCCESS.rawValue) else { return nil }
        return info
    }

    private func mapCallState(_ state: pjsip_inv_state) -> String {
        switch state {
        case PJSIP_INV_STATE_NULL:        return "null"
        case PJSIP_INV_STATE_CALLING:     return "calling"
        case PJSIP_INV_STATE_INCOMING:    return "incoming"
        case PJSIP_INV_STATE_EARLY:       return "early"
        case PJSIP_INV_STATE_CONNECTING:  return "connecting"
        case PJSIP_INV_STATE_CONFIRMED:   return "confirmed"
        case PJSIP_INV_STATE_DISCONNECTED: return "disconnected"
        default:                          return "unknown"
        }
    }

    private func extractDisplayName(from sipUri: String) -> String? {
        // Parse "Display Name" <sip:user@domain> format
        guard let quoteStart = sipUri.firstIndex(of: "\"") else { return nil }
        let afterQuote = sipUri.index(after: quoteStart)
        guard let quoteEnd = sipUri[afterQuote...].firstIndex(of: "\"") else { return nil }
        let name = String(sipUri[afterQuote..<quoteEnd])
        return name.isEmpty ? nil : name
    }

    private func sipError(_ message: String, status: pj_status_t) -> NSError {
        var buf = [CChar](repeating: 0, count: 256)
        pj_strerror(status, &buf, pj_size_t(buf.count))
        let detail = String(cString: buf)
        return NSError(
            domain: "PjsipPlugin",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(message): \(detail)"]
        )
    }
}

// MARK: - pj_str helpers

/// Creates a pj_str_t from a Swift String.
/// The underlying C string is allocated with strdup and must be freed if needed.
private func pj_str_from_swift(_ string: String) -> pj_str_t {
    let cString = strdup(string)!
    return pj_str_t(ptr: cString, slen: pj_ssize_t(strlen(cString)))
}

private func pjStringToSwift(_ pjStr: pj_str_t) -> String {
    guard pjStr.slen > 0, let ptr = pjStr.ptr else { return "" }
    return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(pjStr.slen)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
}

// MARK: - Global C Callback Functions
// These run on PJSIP's own registered worker thread, so no pj_thread_register needed.

/// Called by PJSIP when registration state changes
private func onRegState2(accountId: pjsua_acc_id, info: UnsafeMutablePointer<pjsua_reg_info>?) {
    guard let info = info else { return }
    SipManager.shared.handleRegistrationStateChange(accountId: accountId, info: info.pointee)
}

/// Called by PJSIP when an incoming call arrives
private func onIncomingCall(accountId: pjsua_acc_id, callId: pjsua_call_id, rdata: UnsafeMutablePointer<pjsip_rx_data>?) {
    SipManager.shared.handleIncomingCall(accountId: accountId, pjCallId: callId, rdata: rdata)
}

/// Called by PJSIP when call state changes
private func onCallState(callId: pjsua_call_id, event: UnsafeMutablePointer<pjsip_event>?) {
    SipManager.shared.handleCallStateChange(pjCallId: callId)
}

/// Called by PJSIP when call media state changes
private func onCallMediaState(callId: pjsua_call_id) {
    SipManager.shared.handleCallMediaState(pjCallId: callId)
}
