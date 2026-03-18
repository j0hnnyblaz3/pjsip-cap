import type { PluginListenerHandle } from '@capacitor/core';

// --- Enums ---

export type RegistrationState =
  | 'unregistered'
  | 'registering'
  | 'registered'
  | 'unregistering'
  | 'failed';

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
}

export interface PushTokenEvent {
  token: string;
  platform: PushPlatform;
}

// --- Plugin Interface ---

export interface PjsipPlugin {
  // Registration
  register(options: SipAccountConfig): Promise<void>;
  unregister(): Promise<void>;
  getRegistrationState(): Promise<{ state: RegistrationState }>;

  // Calls
  makeCall(options: { uri: string }): Promise<{ callId: string }>;
  answerCall(options: { callId: string }): Promise<void>;
  hangupCall(options: { callId: string }): Promise<void>;

  // In-call controls
  holdCall(options: { callId: string; hold: boolean }): Promise<void>;
  muteCall(options: { callId: string; mute: boolean }): Promise<void>;
  sendDtmf(options: { callId: string; digit: string }): Promise<void>;
  transferCall(options: { callId: string; target: string }): Promise<void>;
  setAudioRoute(options: { route: AudioRoute }): Promise<void>;

  // Push notifications
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
