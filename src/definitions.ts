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
}

// --- Events ---

export interface CallStateEvent {
  callId: string;
  state: CallState;
  remoteUri?: string;
}

export interface RegistrationStateEvent {
  state: RegistrationState;
  reason?: string;
}

export interface IncomingCallEvent {
  callId: string;
  remoteUri: string;
  callerName?: string;
  /** The PBX-side call identifier, lifted from the INVITE's
   *  `X-Redyrect-Call-UUID` header when present. Lets the client
   *  address this specific call via REST (decline/hangup) and correlate
   *  with the FCM push that announced it. Optional — older PBX versions
   *  don't emit the header. */
  callUuid?: string;
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

/**
 * A call the engine currently knows about. Returned by `getActiveCalls`
 * so a client that lost its in-memory state (web hot-reload, native
 * background→resume after the OS reclaimed the webview) can re-adopt
 * in-flight calls instead of orphaning them.
 */
export interface ActiveCall {
  callId: string;
  state: CallState;
  remoteUri?: string;
  callerName?: string;
}

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
  getActiveCalls(): Promise<{ calls: ActiveCall[] }>;

  // In-call controls
  holdCall(options: { callId: string; hold: boolean }): Promise<void>;
  muteCall(options: { callId: string; mute: boolean }): Promise<void>;
  sendDtmf(options: { callId: string; digit: string }): Promise<void>;
  transferCall(options: { callId: string; target: string }): Promise<void>;
  setAudioRoute(options: { route: AudioRoute }): Promise<void>;

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
  unregisterPush(): Promise<void>;

  // Events
  addListener(
    event: 'callStateChanged',
    listener: (data: CallStateEvent) => void,
  ): Promise<PluginListenerHandle>;
  addListener(
    event: 'registrationStateChanged',
    listener: (data: RegistrationStateEvent) => void,
  ): Promise<PluginListenerHandle>;
  addListener(
    event: 'incomingCall',
    listener: (data: IncomingCallEvent) => void,
  ): Promise<PluginListenerHandle>;
  addListener(
    event: 'pushTokenUpdated',
    listener: (data: PushTokenEvent) => void,
  ): Promise<PluginListenerHandle>;
}
