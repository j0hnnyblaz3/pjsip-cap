import type { PluginListenerHandle } from '@capacitor/core';

// --- Enums ---

/**
 * Registration lifecycle states this plugin actually emits.
 *
 * No `unregistering`: neither backend ever reports it. unregister() goes
 * straight from `registered` to `unregistered` once the far end ACKs the
 * de-REGISTER. Declaring it forced every consumer to handle a state that
 * cannot occur, and narrowing it away was reported as a type error against
 * accurate code.
 */
export type RegistrationState =
  | 'unregistered'
  | 'registering'
  | 'registered'
  | 'failed';

/** Per-permission state, mirroring Capacitor's PermissionState vocabulary. */
export type SipPermissionState = 'prompt' | 'prompt-with-rationale' | 'granted' | 'denied';

export interface SipPermissionStatus {
  microphone: SipPermissionState;
}

/**
 * Call lifecycle states.
 *
 * Cross-platform notes:
 *   • `calling` — outbound INVITE sent, no provisional response yet.
 *   • `early` — outbound 183 Session Progress received (e.g. ringback
 *     from the SBC). iOS distinguishes this; web's sip.js folds it
 *     into `connecting`, so web never emits `early`. UI treats
 *     `calling` and `early` identically ("Calling…").
 *   • `connecting` — 200 OK received, ACK in flight (web) or
 *     PJSIP_INV_STATE_CONNECTING transient (iOS).
 *   • `confirmed` — ACK done, media flowing.
 *   • `held` — synthesized: iOS derives from PJSIP media_status
 *     (LOCAL_HOLD or REMOTE_HOLD); web currently only emits this on
 *     local hold — see [[project_future_work]] for remote-hold
 *     synthesis on web.
 */
export type CallState =
  | 'calling'
  | 'incoming'
  | 'early'
  | 'connecting'
  | 'confirmed'
  | 'disconnected'
  | 'held';

export type AudioRoute = 'speaker' | 'earpiece' | 'bluetooth';

export type SipTransport = 'udp' | 'tcp' | 'tls' | 'wss';

export type PushPlatform = 'apns' | 'fcm' | 'web';

/**
 * APNs environment for the push token. Sandbox is Xcode debug builds;
 * production is TestFlight / App Store. The PBX uses this to pick the
 * correct APNs endpoint per-token so a debug install and a TestFlight
 * install of the same app can coexist against the same global config.
 */
export type PushEnvironment = 'sandbox' | 'production';

/**
 * SRTP enforcement policy for outbound INVITEs:
 * - `disabled`: plain RTP, no SAVP offer
 * - `optional`: offer RTP/AVP with embedded crypto attribute (hybrid)
 * - `mandatory`: offer RTP/SAVP profile cleanly (recommended for SBCs
 *   like FreeSWITCH behind dSIPRouter which reject the OPTIONAL hybrid)
 *
 * Consumed by the native backends (iOS, Android); web (sip.js) leaves
 * SRTP to the browser's DTLS-SRTP and ignores it. Omitted means the
 * backend's own default — the policy is the app's setting.
 */
export type SrtpPolicy = 'disabled' | 'optional' | 'mandatory';

// --- Config ---

export interface SipAccountConfig {
  server: string;
  port?: number;
  username: string;
  password: string;
  domain: string;
  transport?: SipTransport;
  proxy?: string;          // outbound proxy / SBC URI (e.g. "sip:sbc.example.com:5060;lr")
  /**
   * Opaque push token forwarded to the SBC in the REGISTER's
   * `pn-tok` / contact params so the server can wake the app via VoIP
   * push when an INVITE arrives. Currently informational — the iOS
   * backend acquires its own token via PushKit and the SBC pairs by
   * extension, but the field is forwarded for SBCs that key on the
   * registered token instead.
   */
  pushToken?: string;
  /**
   * Media encryption policy. Omit to leave the decision to the server.
   * 'mandatory' fails the call rather than falling back to plain RTP.
   */
  srtpPolicy?: SrtpPolicy;
  /**
   * How the engine runs, from the PBX (`/me/sip-config`) — no platform keeps
   * numbers or codec lists of its own.
   *
   * Seconds between REGISTER refreshes.
   */
  registerExpiresSec: number;
  /** Seconds between keep-alive pings on the registration connection. */
  keepAliveSec: number;
  /**
   * Codecs to offer, in preference order, by encoding name (`OPUS`,
   * `G722`, `PCMU` …, any case). Everything else is off; DTMF stays on.
   * Native only — a browser negotiates its own WebRTC codecs.
   */
  codecs: string[];
}

// --- Events ---

export interface RegistrationStateEvent {
  state: RegistrationState;
  reason?: string;
}

/** Which side placed the call. */
export type CallDirection = 'incoming' | 'outgoing';

/**
 * How a call ended — facts only. What that means to a person ("declined",
 * "busy", "no answer") is the app's to decide, from these and `answered`.
 */
export interface CallEnd {
  /** `local`: this device ended it (the app, the system call UI, a
   *  notification's Decline). `remote`: anything else — the far end, the
   *  PBX, the network. */
  by: 'local' | 'remote';
  /** The SIP status the call ended with (486 busy, 603 decline, 487
   *  cancelled, 408 timeout, 200 after a BYE …), when the engine has one. */
  sipStatus?: number;
  /** The reason phrase that came with `sipStatus`. */
  sipReason?: string;
}

/**
 * A call, whole. The one event every platform sends (`callUpdated`), every
 * time anything about the call changes, and what `getActiveCalls` returns.
 *
 * Every platform keeps these rules, so a consumer never has to repair them:
 *   • One `callId` for the call's whole life — the PBX call id
 *     (`X-Redyrect-Call-UUID`) when the INVITE carries one.
 *   • Fields are only ever added: a later snapshot never drops the caller
 *     name or URI an earlier one carried.
 *   • `disconnected` is sent exactly once, with `end`, and nothing is sent
 *     for that call afterwards.
 */
export interface CallSnapshot {
  callId: string;
  direction: CallDirection;
  state: CallState;
  /** The other party as SIP gave it, display name included when present
   *  (`"Ann Lee" <sip:uid@host>`). Empty only for a pushed call whose
   *  INVITE hasn't arrived and whose push had no number. */
  remoteUri: string;
  /** The other party's name as SIP gave it: the INVITE's From display name
   *  for incoming, the dialer's `displayName` for outgoing, the push's
   *  caller name for a pushed call. Unset when none of those had one. */
  callerName?: string;
  /** The PBX call id, when known. Equal to `callId` when present. */
  callUuid?: string;
  /** True once the call has been connected (`confirmed`) at any point. */
  answered: boolean;
  /** Set on the `disconnected` snapshot only. */
  end?: CallEnd;
}

export interface PushTokenEvent {
  token: string;
  platform: PushPlatform;
  /**
   * APNs environment (`sandbox` or `production`). Emitted on iOS only —
   * web/FCM don't have the same dual-endpoint setup. Lets the PBX route
   * pushes to the right APNs server for THIS specific token so debug
   * and TestFlight installs of the same app can coexist.
   */
  environment?: PushEnvironment;
}

// --- Recovery ---

// --- Plugin Interface ---

export interface PjsipPlugin {
  // Registration
  register(options: SipAccountConfig): Promise<void>;
  unregister(): Promise<void>;
  getRegistrationState(): Promise<{ state: RegistrationState }>;

  // Calls
  /**
   * Place an outbound call.
   *
   * `displayName` is optional and, on iOS, is fed into CallKit's
   * `CXCallUpdate.localizedCallerName` so the Dynamic Island /
   * Phone-app UI shows the contact's display name instead of the
   * raw SIP URI / Firebase UID. Web ignores it (UI surfaces the
   * dialer-known name itself).
   */
  makeCall(options: { uri: string; displayName?: string }): Promise<{ callId: string }>;
  answerCall(options: { callId: string }): Promise<void>;
  hangupCall(options: { callId: string }): Promise<void>;

  /**
   * Enumerate calls the engine is currently tracking. Used for call
   * recovery: a freshly-(re)loaded client queries this on init and
   * re-adopts any in-flight call so it stays controllable.
   */
  getActiveCalls(): Promise<{ calls: CallSnapshot[] }>;

  // In-call controls
  holdCall(options: { callId: string; hold: boolean }): Promise<void>;
  muteCall(options: { callId: string; mute: boolean }): Promise<void>;
  sendDtmf(options: { callId: string; digit: string }): Promise<void>;
  transferCall(options: { callId: string; target: string }): Promise<void>;
  setAudioRoute(options: { route: AudioRoute }): Promise<void>;

  // Full-screen incoming-call permission (Android 14+). See the method
  // docs on the Android implementation.
  /**
   * Whether incoming calls may present full-screen over the lock screen.
   * Android 14+ revokes this by default for non-dialer apps; when false,
   * the incoming call degrades to a heads-up banner and never wakes the
   * screen. Always true on iOS (CallKit owns the incoming-call UI) and web.
   */
  canUseFullScreenIntent(): Promise<{ granted: boolean }>;
  /**
   * Open the OS page where the user grants full-screen incoming calls
   * (the app's notification settings on Android). No-op on iOS and web.
   */
  openFullScreenIntentSettings(): Promise<void>;

  // Push notifications
  /**
   * Update the caller name shown by the OS call UI (CallKit on iOS,
   * ConnectionService on Android) for a call already in progress.
   * Pass null to clear a previous override.
   */
  updateCallDisplay(options: {
    callId: string;
    displayName: string | null;
  }): Promise<void>;

  /** Current microphone permission, without prompting. */
  checkPermissions(): Promise<SipPermissionStatus>;

  /** Prompt for microphone permission. */
  requestPermissions(options?: {
    microphone?: boolean;
  }): Promise<SipPermissionStatus>;

  registerPush(): Promise<void>;
  /**
   * The pushes this build handles beyond the incoming-call wake, to declare
   * when its token is registered with the PBX — e.g. `call_ended` (stop a
   * call still ringing here). A push a build doesn't list is never sent to
   * it: builds from before `call_ended` read any call push as a new call.
   */
  getPushFeatures(): Promise<{ features: string[] }>;
  unregisterPush(): Promise<void>;

  // Events
  /** Every change to every call, as a whole `CallSnapshot`. */
  addListener(
    event: 'callUpdated',
    listener: (data: CallSnapshot) => void,
  ): Promise<PluginListenerHandle>;
  addListener(
    event: 'registrationStateChanged',
    listener: (data: RegistrationStateEvent) => void,
  ): Promise<PluginListenerHandle>;
  addListener(
    event: 'pushTokenUpdated',
    listener: (data: PushTokenEvent) => void,
  ): Promise<PluginListenerHandle>;
}
