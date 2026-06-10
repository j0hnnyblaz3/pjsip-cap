import Foundation
import AVFoundation
import PjsipSDK

/// Custom log writer that filters out the spammy capdbuf/playdbuf
/// underflow chatter PJSIP emits every ~20ms whenever the audio
/// device is open but no media is flowing (between call setup and
/// media negotiation, during hold, etc). Those lines have zero
/// diagnostic value and bury everything else in the log.
///
/// Kept lines are re-emitted via `NSLog`. We tried both
/// `fputs(stderr)` and Swift `print()` first — both got silently
/// dropped depending on which thread PJSIP called us from (the
/// pjsip-worker thread's stdout/stderr aren't routed to the same
/// destination iOS's unified logging is). NSLog goes through the
/// unified logging system, which Capacitor, idevicesyslog, and
/// Console.app all reliably surface. Cost is a duplicated
/// timestamp prefix on every line, which is a small price.
///
/// Must be a free function with @convention(c) — PJSIP takes a raw
/// C function pointer.
private let pjsipFilteredLogWriter: @convention(c) (Int32, UnsafePointer<CChar>?, Int32) -> Void = { _, data, _ in
    guard let data = data else { return }
    let msg = String(cString: data)
    if (msg.contains("capdbuf") || msg.contains("playdbuf"))
        && msg.contains("Underflow") {
        return
    }
    // Strip PJSIP's trailing newline — NSLog adds its own line break.
    let trimmed = msg.hasSuffix("\n") ? String(msg.dropLast()) : msg
    NSLog("%@", trimmed as NSString)
}

struct SipConfig {
    let server: String
    let port: Int
    let username: String
    let password: String
    let domain: String
    let transport: String
    let proxy: String?       // outbound proxy / SBC URI
    /// SRTP policy. "disabled" (default), "optional", or "mandatory".
    /// PJSIP defaults to DISABLED which means we don't offer SRTP in
    /// SDP — fine for legacy unencrypted PBXes, but a SBC that
    /// requires SRTP (as most modern deployments do, especially when
    /// also serving WebRTC clients) rejects the offer and the call
    /// has no media. "optional" is the safest default: offer SRTP,
    /// accept either; the peer chooses.
    let srtp: String?
}

protocol SipManagerDelegate: AnyObject {
    func onRegistrationStateChanged(state: String, reason: String?)
    func onCallStateChanged(callId: String, state: String, remoteUri: String?)
    /// Fires for inbound calls. `callUuid` is the value of the INVITE's
    /// `X-Redyrect-Call-UUID` header when present — this is the
    /// PBX-side identifier (FreeSWITCH channel UUID) the same as the
    /// VoIP push `call_uuid`. Nil when the INVITE came in without the
    /// header (foreground inbound from a non-Redyrect upstream). The
    /// plugin forwards it to JS so the client can call REST-side
    /// decline/cancel against the PBX without depending on the
    /// synthetic plugin callId.
    func onIncomingCall(callId: String, remoteUri: String, callerName: String?, callUuid: String?)
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

    /// Whether a SIP transport has been created via pjsua_transport_create.
    /// Like accountId, this is a per-process resource — calling
    /// pjsua_transport_create again leaks a listener and at some point
    /// exhausts PJSIP's transport slots. The JS layer calls register()
    /// on every reconnect / resume; the guards on startPjsua + this
    /// flag + accountId make those calls idempotent.
    private var transportCreated = false

    /// The transport id pjsua_transport_create returned. Stored so we
    /// can bind the account to this specific transport — without an
    /// explicit accCfg.transport_id, PJSIP picks UDP by default (and
    /// fails with PJSIP_EUNSUPTRANSPORT if only a TLS listener exists).
    private var transportId: pjsua_transport_id = -1
    /// What kind of transport was created — drives the ;transport= tag
    /// we append to the registration URI so the SBC routes the REGISTER
    /// over the right protocol.
    private var transportType: pjsip_transport_type_e = PJSIP_TRANSPORT_UDP

    // MARK: - Push correlation state
    //
    // When a VoIP push arrives, iOS requires we report a call to CallKit
    // synchronously. The push payload carries `call_uuid` — the same
    // value the PBX stamps on the eventual INVITE as the
    // X-Redyrect-Call-UUID header. We track those pending UUIDs here so
    // that when the INVITE lands, handleIncomingCall can match its
    // header value against pendingCallUuids and use the SAME identifier
    // for the plugin callId — keeping CallKit, the pjsua call, and the
    // JS layer all on one stable id from push → INVITE → answer.

    /// Call UUIDs from VoIP pushes whose SIP INVITE hasn't arrived yet. */
    private var pendingCallUuids: Set<String> = []

    /// Call UUIDs the user tapped Answer on before the INVITE arrived.
    /// When the matching INVITE lands, we fire pjsua_call_answer(200)
    /// immediately AND resolve the held CallKit answer completion.
    private var pendingAnswerCallUuids: Set<String> = []

    /// Pending CallKit answer completions keyed by callUuid. When the
    /// user taps Accept before the SIP INVITE has arrived, we hold the
    /// completion here instead of fulfilling/failing the CXAnswerCall-
    /// Action right away. If the INVITE lands within ANSWER_WAIT_GRACE
    /// the completion fires with success and CallKit fulfills the
    /// action; if it doesn't, expireAnswer fires with failure and
    /// CallKit fails the action — surfacing a clean "Call Failed" to
    /// the user instead of a stuck call entry with no audio.
    private var pendingAnswerCompletions: [String: (Error?) -> Void] = [:]

    /// Budget per tapped-Accept-without-INVITE. The push arrived but
    /// the SIP INVITE hasn't yet; we hold the CallKit completion until
    /// either the INVITE lands (success) or this window expires (fail
    /// the CXAction so CallKit shows "Call Failed" instead of a stuck
    /// entry with no audio).
    ///
    /// Set to 10s because the realistic worst case is:
    ///   push wakes app → forceRegister → SBC processes REGISTER
    ///   200 OK → routing engine notices new contact → re-attempts
    ///   call routing → INVITE arrives.
    /// That chain commonly takes 3-6s on a contended SBC; a 5s
    /// budget was timing out before the INVITE even reached us in
    /// real-world testing. 10s still gives prompt feedback if the
    /// call genuinely can't connect, but no longer false-fails the
    /// push-wake path. Not to be confused with iOS's own PushKit
    /// grace window (~30s) — that one handles the no-tap case at the
    /// OS level and we don't override it.
    private var pendingAnswerTimers: [String: DispatchWorkItem] = [:]
    private static let ANSWER_WAIT_GRACE_SEC: TimeInterval = 10.0

    /// Insertion-order tracking for pendingCallUuids so we can evict
    /// the oldest when a PBX storm tries to balloon the set. Parallel
    /// to the Set above — the Set is for O(1) lookup, this Array
    /// gives us FIFO eviction.
    private var pendingCallUuidsOrder: [String] = []
    private static let MAX_PENDING_PUSHES = 8

    /// Debounce for forceRegister. The PBX storm fires this dozens of
    /// times per second; each call to pjsua_acc_set_registration that
    /// arrives while a previous REGISTER is in flight returns
    /// PJ_EBUSY (171001). Trying to REGISTER more than once a second
    /// has no upside anyway — even if iOS just suspended us, the TLS
    /// socket re-establishment takes a beat.
    private var lastForceRegisterAt: Date?
    private static let FORCE_REGISTER_DEBOUNCE_SEC: TimeInterval = 1.0

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

    /// Force an immediate re-REGISTER on the existing account. Called
    /// from the VoIP push handler — iOS tears the TLS socket when the
    /// app is suspended, so even though PJSIP's internal state thinks
    /// it's registered, FreeSWITCH no longer has a working contact to
    /// send the INVITE to. A fresh REGISTER re-establishes the TLS
    /// transport and refreshes the Contact URI server-side, so the
    /// INVITE the PBX is about to send actually reaches us.
    ///
    /// No-op if the account hasn't been created yet (cold start case
    /// where SIP isn't configured) — there's nothing to refresh.
    func forceRegister() {
        pjThread.performAsync { [weak self] in
            guard let self = self else { return }
            // Debounce — a PBX push storm calls this dozens of times
            // per second and every call after the first immediately
            // returns PJ_EBUSY (171001) because the prior REGISTER
            // is still in flight. Skipping after the first within a
            // 1s window saves the noise without losing useful work.
            let now = Date()
            if let last = self.lastForceRegisterAt,
               now.timeIntervalSince(last) < Self.FORCE_REGISTER_DEBOUNCE_SEC {
                let dtMs = Int(now.timeIntervalSince(last) * 1000)
                print("[SipManager] forceRegister: debounced (last \(dtMs)ms ago, window \(Int(Self.FORCE_REGISTER_DEBOUNCE_SEC * 1000))ms)")
                return
            }
            self.lastForceRegisterAt = now
            print("[SipManager] forceRegister: state=\(self.registrationState) "
                + "accountId=\(self.accountId) transportId=\(self.transportId) "
                + "transportType=\(self.transportType.rawValue) "
                + "server=\(self.config?.server ?? "<nil>"):\(self.config?.port ?? -1)")
            guard self.accountId != -1 else {
                print("[SipManager] forceRegister: no account — skipping (call setup will hit Call not found)")
                return
            }
            let status = pjsua_acc_set_registration(
                self.accountId,
                pj_bool_t(PJ_TRUE.rawValue)
            )
            if status == Int32(PJ_SUCCESS.rawValue) {
                print("[SipManager] forceRegister: pjsua_acc_set_registration ok")
            } else {
                print("[SipManager] forceRegister failed status=\(status)")
            }
        }
    }

    /// Tell the manager to expect an inbound SIP INVITE carrying
    /// X-Redyrect-Call-UUID: <callUuid>. Called from the push handler.
    /// When the matching INVITE lands, handleIncomingCall will reuse
    /// this UUID as the plugin callId so CallKit's call UUID is the
    /// same identifier across push → INVITE → answer.
    ///
    /// No background timer here — if the user never taps Accept,
    /// iOS's own PushKit/CallKit ring timeout (~30s, OS-controlled)
    /// dismisses the incoming-call UI. The case we DO actively
    /// time-bound is when the user *does* tap Accept and the INVITE
    /// still hasn't arrived — see the 5s answer budget in
    /// `answerCall` below.
    func expectIncomingCall(callUuid: String) {
        pjThread.performAsync { [weak self] in
            guard let self = self else { return }
            self.addPendingCallUuid(callUuid)
            // Snapshot of state at push time so we can diagnose
            // "INVITE never arrived" failures. If accountId == -1
            // we haven't registered yet — the PBX has no contact
            // to send to and this call will fail.
            print("[SipManager] expectIncomingCall: callUuid=\(callUuid) "
                + "regState=\(self.registrationState) accountId=\(self.accountId) "
                + "activeCalls=\(self.reverseCallMap.count) "
                + "pendingPushSet=\(self.pendingCallUuidsOrder)")
        }
    }

    /// Insert into both the Set (lookup) and the Order array (FIFO).
    /// Evict the oldest entries when capacity is exceeded so a PBX
    /// push storm can't grow the set unboundedly. The set was
    /// previously seen at 50+ entries during the worst storm, which
    /// made the diagnostic logs unreadable and bloated the heap.
    private func addPendingCallUuid(_ uuid: String) {
        if pendingCallUuids.contains(uuid) { return }
        pendingCallUuids.insert(uuid)
        pendingCallUuidsOrder.append(uuid)
        while pendingCallUuidsOrder.count > Self.MAX_PENDING_PUSHES {
            let evicted = pendingCallUuidsOrder.removeFirst()
            pendingCallUuids.remove(evicted)
            // Route through failPendingAnswer rather than removing
            // the completion inline — keeps the answer-timer cleanup,
            // pendingAnswerCallUuids removal, and the diagnostic dump
            // (regState / activeCalls / set sizes) all in one place
            // so an evicted-with-held-completion case still shows up
            // in the logs the same way a graceful expiry does.
            failPendingAnswer(callUuid: evicted, reason: "evicted by push-storm cap")
            print("[SipManager] addPendingCallUuid: evicted \(evicted) (cap=\(Self.MAX_PENDING_PUSHES) reached)")
        }
    }

    /// Remove from both structures. Idempotent.
    private func removePendingCallUuid(_ uuid: String) {
        pendingCallUuids.remove(uuid)
        if let idx = pendingCallUuidsOrder.firstIndex(of: uuid) {
            pendingCallUuidsOrder.remove(at: idx)
        }
    }

    /// Cancel any in-flight answer budget for this UUID. Called from
    /// handleIncomingCall when the INVITE bridges in, and from hangup /
    /// unregister teardown paths.
    private func cancelAnswerTimer(callUuid: String) {
        if let work = pendingAnswerTimers.removeValue(forKey: callUuid) {
            work.cancel()
        }
    }

    /// Fail the held CallKit answer completion for a UUID, if any,
    /// and clean up its bookkeeping. Used both by the 5s budget
    /// expiry and by hangup/unregister teardown.
    private func failPendingAnswer(callUuid: String, reason: String) {
        cancelAnswerTimer(callUuid: callUuid)
        pendingAnswerCallUuids.remove(callUuid)
        guard let completion = pendingAnswerCompletions.removeValue(forKey: callUuid) else {
            return
        }
        // Dump full diagnostic context so we can trace where the
        // INVITE was supposed to land but didn't. If activeCalls is
        // 0 here, PJSIP never received a single SIP message on this
        // dialog — the issue is upstream of pjsua (PBX bridge picked
        // the wrong contact, INVITE lost in transit, etc).
        print("[SipManager] failPendingAnswer: callUuid=\(callUuid) reason=\(reason) "
            + "regState=\(registrationState) accountId=\(accountId) "
            + "activeCalls=\(reverseCallMap.count) "
            + "pendingPushSet=\(pendingCallUuids.sorted()) "
            + "pendingAnswerSet=\(pendingAnswerCallUuids.sorted())")
        DispatchQueue.main.async {
            completion(NSError(
                domain: "PjsipPlugin",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: reason]
            ))
        }
    }

    func unregister(completion: @escaping (Error?) -> Void) {
        pjThread.performAsync { [weak self] in
            guard let self = self else { return }

            if self.accountId != -1 {
                pjsua_acc_del(self.accountId)
                self.accountId = -1
            }

            // pjsua_destroy tears the transport down for us, so once
            // we're done here the next register() needs to recreate
            // both the account and the transport.
            self.transportCreated = false
            self.transportId = -1
            self.transportType = PJSIP_TRANSPORT_UDP

            if self.pjsuaStarted {
                pjsua_destroy()
                self.pjsuaStarted = false
            }

            // Cancel any in-flight answer budgets and fail their
            // CallKit completions — the SIP stack is going away so
            // no INVITE will ever bridge to them.
            for callUuid in Array(self.pendingAnswerCompletions.keys) {
                self.failPendingAnswer(callUuid: callUuid, reason: "SIP stack shutting down")
            }
            self.pendingCallUuids.removeAll()
            self.pendingCallUuidsOrder.removeAll()
            self.pendingAnswerCallUuids.removeAll()
            self.pendingAnswerTimers.removeAll()
            self.lastForceRegisterAt = nil

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
        // Level 5 dumps every TX/RX SIP message body, transport-layer
        // events (TLS handshake, socket open/close), call state
        // transitions, media negotiation. The chatty audio-buffer
        // underflow lines that fire at this level are dropped by
        // pjsipFilteredLogWriter; everything else passes through.
        logCfg.level = 5
        // console_level=0 stops PJSIP's built-in stderr writer.
        // Combined with logCfg.cb below, every PJSIP log line flows
        // through our filter exactly once — no built-in writer
        // producing duplicates with the capdbuf/playdbuf lines we
        // wanted to drop.
        logCfg.console_level = 0
        // msg_logging is true by default but set explicitly so we
        // never lose SIP wire-trace dumps even if a future PJSIP
        // version changes defaults.
        logCfg.msg_logging = pj_bool_t(PJ_TRUE.rawValue)
        logCfg.cb = pjsipFilteredLogWriter

        var mediaCfg = pjsua_media_config()
        pjsua_media_config_default(&mediaCfg)
        // Close the sound device promptly when no call is using it.
        // Previously this was -1 (always open) which caused
        //   capdbuf  Underflow, buf_cnt=0, will generate 1 frame
        // to spam the log continuously — PJSIP was polling the mic
        // 50× per second with nowhere to send the data. A 1-second
        // idle close keeps rapid call sequences fast (no reopen
        // penalty between back-to-back calls) without burning CPU
        // or filling the log when idle.
        mediaCfg.snd_auto_close_time = 1

        status = pjsua_init(&cfg, &logCfg, &mediaCfg)
        guard status == Int32(PJ_SUCCESS.rawValue) else {
            pjsua_destroy()
            throw sipError("pjsua_init failed", status: status)
        }
    }

    private func createTransport(config: SipConfig) throws {
        // Idempotent — transport is per-process. Re-creating leaks
        // listeners and eventually exhausts PJSIP slots.
        guard !transportCreated else { return }

        let type: pjsip_transport_type_e
        switch config.transport.lowercased() {
        case "tcp":
            type = PJSIP_TRANSPORT_TCP
        case "tls":
            type = PJSIP_TRANSPORT_TLS
        case "wss":
            type = PJSIP_TRANSPORT_TLS
        default:
            type = PJSIP_TRANSPORT_UDP
        }

        var transportCfg = pjsua_transport_config()
        pjsua_transport_config_default(&transportCfg)

        var newId: pjsua_transport_id = -1
        let status = pjsua_transport_create(type, &transportCfg, &newId)
        guard status == Int32(PJ_SUCCESS.rawValue) else {
            throw sipError("pjsua_transport_create failed", status: status)
        }
        transportCreated = true
        transportId = newId
        transportType = type
    }

    private func startPjsua() throws {
        guard !pjsuaStarted else { return }

        let status = pjsua_start()
        guard status == Int32(PJ_SUCCESS.rawValue) else {
            pjsua_destroy()
            throw sipError("pjsua_start failed", status: status)
        }
        pjsuaStarted = true

        // Detach from the sound device immediately. We let CallKit's
        // didActivate handler attach it when AVAudioSession is ready.
        // Without this, PJSIP grabs the audio unit at pjsua_start time
        // — before AVAudioSession is active — and AURemoteIO fails to
        // initialize (561017449 across every sample rate it tries).
        // PJSIP then has a half-initialized audio path even after
        // CallKit activates the session, and calls connect with no
        // working media. See `startAudioDevice` / `stopAudioDevice`
        // below for the CallKit-driven lifecycle.
        //
        // pjsua_set_no_snd_dev returns a pjmedia_port* (a "null"
        // sound device port the conf bridge can connect to) rather
        // than a status code — discarding it is fine; the side
        // effect we want is detaching from coreaudio.
        _ = pjsua_set_no_snd_dev()
        print("[SipManager] startPjsua: detached sound device")

        // After pjsua_start, the codec subsystem is initialized and we
        // can enumerate + reprioritize. Without this, PJSIP offers its
        // full compiled-in codec list (PCMU, PCMA, G722, iLBC, GSM,
        // several speex variants, L16 at multiple sample rates, opus
        // when enabled, telephone-event) — fine for SIP↔SIP but
        // unfriendly to PSTN gateways behind dSIPRouter / similar
        // SBCs, which can respond 488 Not Acceptable Here / Q.850
        // cause 88 INCOMPATIBLE_DESTINATION when the offer is too
        // broad or contains profiles their carrier link can't match.
        configureCodecs()
    }

    /// Narrow the offered codec set to what PSTN trunks and modern
    /// SBCs actually negotiate cleanly. Priority order:
    ///   1. PCMU/8000   (G.711 μ-law)  — universal PSTN
    ///   2. PCMA/8000   (G.711 a-law)  — universal PSTN (EU origin)
    ///   3. G722/8000   (wideband HD)  — when both legs support it
    ///   4. opus/48000  (WebRTC interop) — for SBC bridges to web clients
    ///   5. telephone-event/8000 — DTMF, must stay enabled
    /// Everything else disabled. To add a codec back, bump its
    /// priority above 0 here.
    private func configureCodecs() {
        // Enumerate first so the log shows what's actually available
        // in this PJSIP build — invaluable for diagnosing "why is
        // codec X missing from my SDP offer".
        var codecCount: pj_uint32_t = 64
        var codecs = Array(repeating: pjsua_codec_info(), count: 64)
        let enumStatus = pjsua_enum_codecs(&codecs, &codecCount)
        guard enumStatus == Int32(PJ_SUCCESS.rawValue) else {
            print("[SipManager] pjsua_enum_codecs failed status=\(enumStatus)")
            return
        }

        print("[SipManager] PJSIP compiled-in codecs (\(codecCount)):")
        for i in 0..<Int(codecCount) {
            let id = pjStringToSwift(codecs[i].codec_id)
            print("  - \(id) (default priority=\(codecs[i].priority))")
        }

        // Apply priorities. Codec IDs are case-sensitive in pjsua —
        // they're matched against the registered factory names.
        let priorities: [(String, UInt8)] = [
            ("PCMU/8000", 240),
            ("PCMA/8000", 230),
            ("G722/8000", 220),
            ("opus/48000", 210),
            ("telephone-event/8000", 200),
        ]

        // First pass: disable everything by setting priority to 0.
        // We re-enable the wanted ones in the second pass. Doing it
        // this way means new codecs that appear in future PJSIP
        // versions are off by default — safer than allow-listing
        // every possible new codec name.
        for i in 0..<Int(codecCount) {
            var id = codecs[i].codec_id
            let status = pjsua_codec_set_priority(&id, 0)
            if status != Int32(PJ_SUCCESS.rawValue) {
                print("[SipManager] disable codec failed for \(pjStringToSwift(id)) status=\(status)")
            }
        }

        // Second pass: re-enable the wanted ones with priority.
        for (name, prio) in priorities {
            var id = pj_str_from_swift(name)
            let status = pjsua_codec_set_priority(&id, prio)
            if status == Int32(PJ_SUCCESS.rawValue) {
                print("[SipManager] codec enabled: \(name) priority=\(prio)")
            } else {
                // Not a hard failure — the codec may not be compiled
                // into this PJSIP build. e.g. opus is conditional.
                print("[SipManager] codec \(name) not available (status=\(status))")
            }
        }
    }

    private func addAccount(config: SipConfig) throws {
        // Idempotent — every call to pjsua_acc_add consumes a slot
        // from PJSUA_MAX_ACC (8 by default). The JS layer calls
        // register() on every reconnect / resume; without this guard,
        // the ~8th invocation crashes with an assertion in pjsua_acc_add.
        // When we already have an account, just trigger a re-REGISTER
        // (covers the "config refresh" case JS expects) and return.
        if accountId != -1 {
            let status = pjsua_acc_set_registration(
                accountId,
                pj_bool_t(PJ_TRUE.rawValue)
            )
            if status != Int32(PJ_SUCCESS.rawValue) {
                print("[SipManager] addAccount: re-register failed status=\(status)")
            }
            return
        }

        var accCfg = pjsua_acc_config()
        pjsua_acc_config_default(&accCfg)

        // Tag the registration URI with the actual transport. Without
        // this, PJSIP defaults to UDP — which fails with
        // PJSIP_EUNSUPTRANSPORT when we only have a TLS listener.
        let sipUri = "sip:\(config.username)@\(config.domain)"
        let regUri: String = {
            switch transportType {
            case PJSIP_TRANSPORT_TLS:
                return "sip:\(config.server):\(config.port);transport=tls"
            case PJSIP_TRANSPORT_TCP:
                return "sip:\(config.server):\(config.port);transport=tcp"
            default:
                return "sip:\(config.server):\(config.port)"
            }
        }()

        accCfg.id = pj_str_from_swift(sipUri)
        accCfg.reg_uri = pj_str_from_swift(regUri)

        // Bind the account to the transport we created. Belt-and-
        // suspenders with the ;transport= tag — pjsua_acc still has
        // to find an outbound transport when building the Contact
        // header, and explicit binding is the reliable way.
        if transportId != -1 {
            accCfg.transport_id = transportId
        }

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

        // SRTP policy. Without this, PJSIP defaults to
        // PJSUA_SRTP_DISABLED — we offer plain RTP only and the SBC
        // (which sits in front of the PBX and is also serving WebRTC
        // clients that require encryption) rejects the media offer or
        // routes audio nowhere. "optional" is the safe modern default:
        // offer SRTP, accept either at the peer's choice.
        // `use_srtp` is typed `pjmedia_srtp_use` (PJMEDIA_SRTP_*),
        // NOT `pjsua_srtp_*` — the SRTP enum lives in the pjmedia
        // layer even though pjsua_acc_config exposes the field.
        switch (config.srtp ?? "optional").lowercased() {
        case "mandatory":
            accCfg.use_srtp = PJMEDIA_SRTP_MANDATORY
        case "disabled", "none", "off":
            accCfg.use_srtp = PJMEDIA_SRTP_DISABLED
        default:
            accCfg.use_srtp = PJMEDIA_SRTP_OPTIONAL
        }
        // SRTP-over-TLS-only requirement. We're already on TLS so
        // this is satisfied; setting it explicitly hardens against
        // a future UDP fallback path accidentally negotiating SRTP
        // over an unencrypted signaling channel.
        accCfg.srtp_secure_signaling = 1

        accCfg.reg_retry_interval = 300
        accCfg.reg_first_retry_interval = 30

        // Tighten the registration refresh cycle and add SIP-level
        // keep-alive, mirroring the web sip.js fix:
        //
        //   reg_timeout=180  →  refresh REGISTER every ~3 minutes
        //     instead of PJSIP's default 3600s (1 hour). The SBC
        //     drops stale contacts faster after a real network loss
        //     (no "phone rings but no audio" ghost-contact window),
        //     and we detect upstream auth/policy drift within minutes
        //     rather than within an hour.
        //
        //   ka_interval=30  →  PJSIP sends a SIP-level CRLF ping on
        //     the registration transport every 30s. Required to keep
        //     idle TLS sockets alive through aggressive corporate
        //     NAT / proxies / some mobile carriers that close idle
        //     TCP connections within 60-90s. Without it, the TLS
        //     socket goes silent and dies while we look-registered-
        //     but-aren't until the next REGISTER refresh notices.
        //
        // These match what web/sip.js sets (keepAliveInterval=30 +
        // expires=180) — same defenses, same numbers, both ends of
        // the client behave identically against the SBC.
        accCfg.reg_timeout = 180
        accCfg.ka_interval = 30

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
        // Fast path — pjsua call is already there, answer immediately.
        if let pjCallId = reverseCallMap[callId] {
            pjThread.performAsync { [self] in
                let status = pjsua_call_answer(pjCallId, 200, nil, nil)
                if status == Int32(PJ_SUCCESS.rawValue) {
                    DispatchQueue.main.async { completion?(nil) }
                } else {
                    DispatchQueue.main.async {
                        completion?(self.sipError("pjsua_call_answer failed", status: status))
                    }
                }
            }
            return
        }

        // Slow path — push arrived but the SIP INVITE hasn't landed
        // yet. Common when the user taps Accept the moment CallKit
        // appears; the INVITE is still in flight from the PBX over
        // TLS. We don't fulfill or fail the CallKit action here —
        // the completion is held until either:
        //   - handleIncomingCall fires for the matching UUID
        //     (INVITE arrived → auto-answer, completion(nil)), or
        //   - the 5s budget expires (no INVITE in time →
        //     completion(error) → CallKit fails the action and
        //     surfaces "Call Failed" to the user cleanly).
        // This replaces the older 30s wall-clock cleanup timer —
        // tied to actual user intent (Accept) rather than a
        // background watchdog.
        if pendingCallUuids.contains(callId) {
            pjThread.performAsync { [weak self] in
                guard let self = self else { return }
                self.pendingAnswerCallUuids.insert(callId)
                // Stash the CallKit completion until INVITE arrival
                // or the budget expires. If completion is nil (e.g.
                // an internal call from somewhere other than CallKit),
                // we'd just drop it — but in practice the CallKit
                // path always passes one.
                if let completion = completion {
                    self.pendingAnswerCompletions[callId] = completion
                }
                print("[SipManager] answerCall: \(callId) pending INVITE — 5s budget armed")

                // Re-arm semantics: cancel any prior budget for the
                // same UUID (shouldn't happen in practice — CallKit
                // gives a single CXAnswerCallAction per call — but
                // defensive).
                self.pendingAnswerTimers[callId]?.cancel()

                let work = DispatchWorkItem { [weak self] in
                    self?.pjThread.performAsync {
                        self?.failPendingAnswer(
                            callUuid: callId,
                            reason: "INVITE timeout"
                        )
                    }
                }
                self.pendingAnswerTimers[callId] = work
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + Self.ANSWER_WAIT_GRACE_SEC,
                    execute: work
                )
            }
            return
        }

        completion?(NSError(
            domain: "PjsipPlugin",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Call not found"]
        ))
    }

    func hangupCall(callId: String) {
        // Fast path — there's a real pjsua call, tear it down.
        //
        // Critical: do NOT optimistically remove from callMap/
        // reverseCallMap here. The previous code removed maps on
        // the caller's thread (main) before pjsua_call_hangup ran
        // on pjThread — racy with the pjsip worker, and worse,
        // if the BYE failed to leave the wire (stale TLS, network
        // drop) the local side cleaned up while the remote softphone
        // kept showing the call as live (user-reported: "i hung up
        // on the phone but the softphone thought the call was still
        // active"). Now we leave the maps alone here; the proper
        // teardown happens in handleCallStateChange when PJSIP fires
        // on_call_state with DISCONNECTED — which only happens
        // after the BYE round-trip actually completes (or the
        // transaction times out).
        //
        // The status check on pjsua_call_hangup is also new: a
        // non-zero return means PJSIP couldn't even queue the BYE
        // (e.g. invalid call id, transport gone). If we see that
        // status logged after a "hangup not working" report, we
        // know to look at transport state.
        if let pjCallId = reverseCallMap[callId] {
            pjThread.performAsync { [weak self] in
                let status = pjsua_call_hangup(pjCallId, 0, nil, nil)
                if status == Int32(PJ_SUCCESS.rawValue) {
                    print("[SipManager] hangupCall: BYE queued for pjCallId=\(pjCallId) (callId=\(callId))")
                } else {
                    print("[SipManager] hangupCall: pjsua_call_hangup failed status=\(status) (callId=\(callId))")
                    // BYE couldn't be queued — force the local
                    // cleanup so the UI doesn't stay stuck. Remote
                    // will eventually time out the dialog on its own.
                    self?.callMap.removeValue(forKey: pjCallId)
                    self?.reverseCallMap.removeValue(forKey: callId)
                    DispatchQueue.main.async {
                        self?.delegate?.onCallStateChanged(
                            callId: callId,
                            state: "disconnected",
                            remoteUri: nil
                        )
                    }
                }
            }
            return
        }

        // Slow path — hangup on a push-only placeholder (CallKit
        // reported, INVITE never arrived, user declined or CallKit's
        // own ring timeout fired). Clear pending state. If the user
        // had also tapped Accept and we're holding their CallKit
        // answer completion, fail it so the action ends cleanly.
        if pendingCallUuids.contains(callId) {
            pjThread.performAsync { [weak self] in
                guard let self = self else { return }
                self.removePendingCallUuid(callId)
                self.failPendingAnswer(callUuid: callId, reason: "call ended before INVITE")
            }
            delegate?.onCallStateChanged(callId: callId, state: "disconnected", remoteUri: nil)
        }
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

    /// Attach PJSIP to the actual iOS audio device. Called from
    /// CallKitManager.provider(didActivate:) — only after CallKit
    /// has activated AVAudioSession is the device able to open
    /// successfully (AURemoteIO unit needs an active session). The
    /// pjsua_call_get_info / conf_connect plumbing that
    /// handleCallMediaState set up earlier will start pushing audio
    /// the instant the device opens.
    func startAudioDevice() {
        pjThread.performAsync { [weak self] in
            guard let self = self, self.pjsuaStarted else { return }
            // PJMEDIA_AUD_DEFAULT_CAPTURE_DEV / PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV
            // are imported as Int32 directly (not enum types), so we
            // pass them through without `.rawValue`.
            let status = pjsua_set_snd_dev(
                PJMEDIA_AUD_DEFAULT_CAPTURE_DEV,
                PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV
            )
            if status == Int32(PJ_SUCCESS.rawValue) {
                print("[SipManager] startAudioDevice: attached")
            } else {
                print("[SipManager] startAudioDevice failed status=\(status)")
            }
        }
    }

    /// Detach PJSIP from the audio device. Called from
    /// CallKitManager.provider(didDeactivate:) so PJSIP doesn't keep
    /// the audio unit running when CallKit isn't using it. Signaling
    /// (REGISTER, INVITE handling) continues — only media stops.
    ///
    /// pjsua_set_no_snd_dev returns a pjmedia_port* (the "null" sound
    /// device port) rather than a pj_status_t; the side effect is
    /// what we want, the return value is unused.
    func stopAudioDevice() {
        pjThread.performAsync { [weak self] in
            guard let self = self, self.pjsuaStarted else { return }
            _ = pjsua_set_no_snd_dev()
            print("[SipManager] stopAudioDevice: detached")
        }
    }

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
        // Diagnostic: PJSIP's on_incoming_call fired, which means we
        // received a SIP INVITE. Log everything we can pull off the
        // wire — header presence, pending push correlation, basic
        // routing info. If this line appears in the user's log, the
        // INVITE actually arrived; if it doesn't, the PBX never sent
        // one (or it was lost upstream of pjsua).
        let headerUuid = parseRedyrectCallUuid(rdata: rdata)
        print("[SipManager] handleIncomingCall: pjCallId=\(pjCallId) "
            + "X-Redyrect-Call-UUID=\(headerUuid ?? "<not present>") "
            + "pendingPushSet=\(pendingCallUuids.sorted()) "
            + "pendingAnswerSet=\(pendingAnswerCallUuids.sorted())")

        // Try to read X-Redyrect-Call-UUID from the INVITE. The PBX
        // stamps this with FreeSWITCH's channel UUID — the same value
        // that landed in the VoIP push payload's `call_uuid` field.
        // If we have a matching pending push, we bind to its UUID so
        // CallKit, pjsua, and the JS layer all share one identifier
        // from push → INVITE → answer. Otherwise we fall back to the
        // synthetic ios-call-N (foreground inbound case, no push).
        let pluginCallId: String
        if let uuid = headerUuid {
            pluginCallId = uuid
            let wasPending = pendingCallUuids.contains(uuid)
            removePendingCallUuid(uuid)
            print("[SipManager] handleIncomingCall: bridged to push placeholder=\(wasPending) pluginCallId=\(uuid)")
        } else {
            callIdCounter += 1
            pluginCallId = "ios-call-\(callIdCounter)"
            print("[SipManager] handleIncomingCall: synthesized pluginCallId=\(pluginCallId) (foreground inbound, no push correlation)")
        }

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

        // If the user already tapped Accept on CallKit while the
        // INVITE was in flight, fire the 200 OK now AND resolve the
        // held CallKit answer completion (CallKitManager fulfills the
        // CXAnswerCallAction, configures the audio session, and
        // attaches to the now-real pjsua call). The 5s budget timer
        // is cancelled in the same step so it doesn't fail what
        // we just succeeded.
        if pendingAnswerCallUuids.contains(pluginCallId) {
            pendingAnswerCallUuids.remove(pluginCallId)
            cancelAnswerTimer(callUuid: pluginCallId)
            let status = pjsua_call_answer(pjCallId, 200, nil, nil)
            let answeredOk = (status == Int32(PJ_SUCCESS.rawValue))
            print("[SipManager] auto-answered pending \(pluginCallId) status=\(status)")
            if let completion = pendingAnswerCompletions.removeValue(forKey: pluginCallId) {
                DispatchQueue.main.async { [weak self] in
                    if answeredOk {
                        completion(nil)
                    } else {
                        completion(self?.sipError(
                            "pjsua_call_answer failed",
                            status: status
                        ))
                    }
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.onIncomingCall(
                callId: pluginCallId,
                remoteUri: remoteUri,
                callerName: callerName,
                callUuid: headerUuid
            )
        }
    }

    /// Read the X-Redyrect-Call-UUID header off an inbound SIP message.
    /// Returns nil if the header isn't present (foreground inbound or
    /// non-Redyrect upstream). Uses PJSIP's generic header lookup —
    /// the cast from pjsip_hdr* to pjsip_generic_string_hdr* is safe
    /// because custom string-valued headers register as generic.
    private func parseRedyrectCallUuid(rdata: UnsafeMutablePointer<pjsip_rx_data>?) -> String? {
        guard let rdata = rdata else { return nil }
        let msg = rdata.pointee.msg_info.msg
        guard let msg = msg else { return nil }
        var headerName = pj_str_from_swift("X-Redyrect-Call-UUID")
        guard let hdrPtr = pjsip_msg_find_hdr_by_name(msg, &headerName, nil) else {
            return nil
        }
        let stringHdr = UnsafeRawPointer(hdrPtr)
            .assumingMemoryBound(to: pjsip_generic_string_hdr.self)
        let value = pjStringToSwift(stringHdr.pointee.hvalue)
        return value.isEmpty ? nil : value
    }

    func handleCallStateChange(pjCallId: pjsua_call_id) {
        guard let info = getCallInfo(pjCallId) else { return }

        let pluginCallId = callMap[pjCallId] ?? "unknown-\(pjCallId)"
        let state = effectiveCallState(info: info)
        let remoteUri = pjStringToSwift(info.remote_info)

        if info.state == PJSIP_INV_STATE_DISCONNECTED {
            callMap.removeValue(forKey: pjCallId)
            reverseCallMap.removeValue(forKey: pluginCallId)
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.onCallStateChanged(callId: pluginCallId, state: state, remoteUri: remoteUri)
        }
    }

    /// PJSIP has no separate "held" inv state — a held call stays in
    /// PJSIP_INV_STATE_CONFIRMED and the hold lives in media_status.
    /// The JS UI (ActiveCallScreen) needs to distinguish so the user
    /// sees Hold flip to Resume on tap. Synthesize the "held" state
    /// from `info.media_status` when the call is otherwise confirmed.
    private func effectiveCallState(info: pjsua_call_info) -> String {
        let base = mapCallState(info.state)
        if base == "confirmed" {
            switch info.media_status {
            case PJSUA_CALL_MEDIA_LOCAL_HOLD,
                 PJSUA_CALL_MEDIA_REMOTE_HOLD:
                return "held"
            default:
                return "confirmed"
            }
        }
        return base
    }

    func handleCallMediaState(pjCallId: pjsua_call_id) {
        guard let info = getCallInfo(pjCallId) else { return }

        // The conf bridge connects call audio ↔ sound device (slot 0).
        // We must:
        //   - ACTIVE → wire both directions so audio flows.
        //   - LOCAL_HOLD / REMOTE_HOLD → tear those connections down
        //     so the user doesn't hear silent audio from a held call,
        //     AND so a SECOND active call (call-waiting scenario) can
        //     own the speaker/mic without mixing with the held one.
        //   - NONE / ERROR → also disconnect; nothing to play.
        // Without the disconnect branches, two concurrent calls would
        // both stay wired to slot 0 and audio would be mixed or
        // chaotic when the user swapped.
        switch info.media_status {
        case PJSUA_CALL_MEDIA_ACTIVE:
            pjsua_conf_connect(info.conf_slot, 0)  // call -> speaker
            pjsua_conf_connect(0, info.conf_slot)  // mic  -> call
            print("[SipManager] handleCallMediaState: pjCallId=\(pjCallId) ACTIVE — bridges connected (slot=\(info.conf_slot))")
        case PJSUA_CALL_MEDIA_LOCAL_HOLD,
             PJSUA_CALL_MEDIA_REMOTE_HOLD:
            pjsua_conf_disconnect(info.conf_slot, 0)
            pjsua_conf_disconnect(0, info.conf_slot)
            print("[SipManager] handleCallMediaState: pjCallId=\(pjCallId) HOLD — bridges disconnected (slot=\(info.conf_slot))")
        case PJSUA_CALL_MEDIA_NONE,
             PJSUA_CALL_MEDIA_ERROR:
            pjsua_conf_disconnect(info.conf_slot, 0)
            pjsua_conf_disconnect(0, info.conf_slot)
            print("[SipManager] handleCallMediaState: pjCallId=\(pjCallId) NONE/ERROR — bridges disconnected")
        default:
            break
        }

        // PJSIP's hold/resume is signaled at the media layer — the
        // inv state stays CONFIRMED across both. on_call_state never
        // fires for hold transitions, so handleCallStateChange never
        // re-emits the JS event. The UI then can't flip the Hold
        // button to Resume (or back). Re-emit the effective state
        // here whenever media transitions so React state stays in
        // sync. effectiveCallState() picks "held" when media is in
        // LOCAL_HOLD/REMOTE_HOLD on an otherwise confirmed call.
        let pluginCallId = callMap[pjCallId] ?? "unknown-\(pjCallId)"
        let state = effectiveCallState(info: info)
        let remoteUri = pjStringToSwift(info.remote_info)
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.onCallStateChanged(
                callId: pluginCallId,
                state: state,
                remoteUri: remoteUri
            )
        }
    }

    /// Snapshot every call PJSIP is still tracking, for client-side
    /// recovery after a webview reload. Authoritative: state/remote come
    /// straight from `pjsua_call_get_info`, not cached bookkeeping.
    ///
    /// Must run on `pjThread` — `pjsua_call_get_info` calls `pj_thread_this`
    /// internally, which asserts when invoked from a thread pjlib didn't
    /// register. The Capacitor bridge calls this on its own queue, so
    /// without performSync the assertion crashes the app on resume /
    /// during reconcile polls.
    func getActiveCalls() -> [[String: Any]] {
        var calls: [[String: Any]] = []
        pjThread.performSync { [weak self] in
            guard let self = self else { return }
            for (pluginCallId, pjCallId) in self.reverseCallMap {
                guard let info = self.getCallInfo(pjCallId) else { continue }
                if info.state == PJSIP_INV_STATE_DISCONNECTED
                    || info.state == PJSIP_INV_STATE_NULL { continue }
                let remoteUri = pjStringToSwift(info.remote_info)
                var entry: [String: Any] = [
                    "callId": pluginCallId,
                    // effectiveCallState picks "held" when media is in
                    // LOCAL_HOLD/REMOTE_HOLD — so recovery polls after
                    // app resume show the correct hold state.
                    "state": self.effectiveCallState(info: info),
                ]
                if !remoteUri.isEmpty { entry["remoteUri"] = remoteUri }
                if let name = extractDisplayName(from: remoteUri) {
                    entry["callerName"] = name
                }
                calls.append(entry)
            }
        }
        return calls
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
