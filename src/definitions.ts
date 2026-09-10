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

/** Media encryption policy handed to pjsip's `use_srtp`. */
export type SrtpPolicy = 'disabled' | 'optional' | 'mandatory';

/** Per-permission state, mirroring Capacitor's PermissionState vocabulary. */
export type SipPermissionState = 'prompt' | 'prompt-with-rationale' | 'granted' | 'denied';

export interface SipPermissionStatus {
  microphone: SipPermissionState;
}

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

// --- Config ---

export interface SipAccountConfig {
  server: string;
  port?: number;
  username: string;
  password: string;
  domain: string;
  transport?: SipTransport;
  proxy?: string;          // outbound proxy / SBC URI (e.g. "sip:sbc.example.com:5060;lr")
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
