import { WebPlugin } from '@capacitor/core';
import {
  UserAgent,
  Registerer,
  RegistererState,
  Inviter,
  SessionState,
  type Session,
  type Invitation,
} from 'sip.js';

import type {
  PjsipPlugin,
  SipAccountConfig,
  RegistrationState,
  CallState,
  AudioRoute,
  ActiveCall,
} from './definitions';

export class PjsipWeb extends WebPlugin implements PjsipPlugin {
  private ua: UserAgent | null = null;
  private registerer: Registerer | null = null;
  private sessions: Map<string, Session> = new Map();
  private callIdCounter = 0;
  private registrationState: RegistrationState = 'unregistered';
  async register(options: SipAccountConfig): Promise<void> {
    const port = options.port ?? 7443;
    const transport = options.transport ?? 'wss';
    const wsServer = `${transport}://${options.server}:${port}`;

    const uri = UserAgent.makeURI(`sip:${options.username}@${options.domain}`);
    if (!uri) {
      throw new Error(`Invalid SIP URI: sip:${options.username}@${options.domain}`);
    }

    const uaOptions: any = {
      uri,
      authorizationUsername: options.username,
      authorizationPassword: options.password,
      transportOptions: {
        server: wsServer,
      },
      // Cap the ICE-gathering wait. sip.js defaults to 5000ms and many
      // browsers/networks never fire `icegatheringstatechange: complete`,
      // so the offer/answer SDP (and thus the INVITE / 200 OK) stalls the
      // full 5s — the visible "buttons lag ~5 seconds" symptom. Host +
      // srflx candidates gather in well under a second; 1s is a safe cap.
      sessionDescriptionHandlerFactoryOptions: {
        iceGatheringTimeout: 1000,
      },
      delegate: {
        onInvite: (invitation: Invitation) => {
          this.handleIncomingCall(invitation);
        },
      },
    };

    if (options.proxy) {
      uaOptions.preloadedRouteSet = [options.proxy];
    }

    this.ua = new UserAgent(uaOptions);

    this.updateRegistrationState('registering');

    await this.ua.start();

    this.registerer = new Registerer(this.ua);

    this.registerer.stateChange.addListener((state: RegistererState) => {
      switch (state) {
        case RegistererState.Registered:
          this.updateRegistrationState('registered');
          break;
        case RegistererState.Unregistered:
          this.updateRegistrationState('unregistered');
          break;
        case RegistererState.Terminated:
          this.updateRegistrationState('unregistered');
          break;
      }
    });

    await this.registerer.register();
  }

  async unregister(): Promise<void> {
    if (this.registerer) {
      await this.registerer.unregister();
    }
    if (this.ua) {
      await this.ua.stop();
      this.ua = null;
    }
    this.registerer = null;
    this.sessions.clear();
  }

  async getRegistrationState(): Promise<{ state: RegistrationState }> {
    return { state: this.registrationState };
  }

  async makeCall(options: { uri: string }): Promise<{ callId: string }> {
    if (!this.ua) {
      throw new Error('Not registered');
    }

    const targetUri = UserAgent.makeURI(options.uri);
    if (!targetUri) {
      throw new Error(`Invalid URI: ${options.uri}`);
    }

    const inviter = new Inviter(this.ua, targetUri, {
      sessionDescriptionHandlerOptions: {
        constraints: { audio: true, video: false },
      },
    });

    const callId = this.nextCallId();
    this.sessions.set(callId, inviter);
    this.setupSessionListeners(callId, inviter);

    // Emit 'calling' and return the id IMMEDIATELY. Do not block the
    // caller on inviter.invite(): it internally waits for ICE gathering
    // (capped by iceGatheringTimeout above) before the INVITE goes out,
    // which would otherwise freeze the UI until the SDP is ready. The
    // session.stateChange listeners drive every subsequent state; a
    // failed invite is surfaced as 'disconnected' so the UI recovers.
    this.notifyCallState(callId, 'calling', options.uri);
    inviter.invite().catch((err) => {
      console.error('[capacitor-pjsip] inviter.invite failed', err);
      this.sessions.delete(callId);
      this.notifyCallState(callId, 'disconnected', options.uri);
    });

    return { callId };
  }

  async answerCall(options: { callId: string }): Promise<void> {
    const session = this.getSession(options.callId);
    if (session instanceof Object && 'accept' in session) {
      await (session as Invitation).accept({
        sessionDescriptionHandlerOptions: {
          constraints: { audio: true, video: false },
        },
      });
    }
  }

  async hangupCall(options: { callId: string }): Promise<void> {
    const session = this.getSession(options.callId);
    switch (session.state) {
      case SessionState.Initial:
      case SessionState.Establishing:
        if (session instanceof Inviter) {
          await session.cancel();
        } else {
          await (session as Invitation).reject();
        }
        break;
      case SessionState.Established:
        await session.bye();
        break;
    }
    this.sessions.delete(options.callId);
  }

  async getActiveCalls(): Promise<{ calls: ActiveCall[] }> {
    const calls: ActiveCall[] = [];
    for (const [callId, session] of this.sessions) {
      // Terminated sessions are pruned in setupSessionListeners, but
      // guard anyway so a recovering client never re-adopts a dead call.
      if (session.state === SessionState.Terminated) continue;
      const state = this.mapSessionState(session.state) ?? 'connecting';
      let remoteUri: string | undefined;
      let callerName: string | undefined;
      try {
        remoteUri = session.remoteIdentity?.uri?.toString();
        callerName = session.remoteIdentity?.displayName || undefined;
      } catch {
        // remoteIdentity can be unavailable very early in an Inviter's
        // lifecycle — fine, the callId alone still makes it controllable.
      }
      calls.push({ callId, state, remoteUri, callerName });
    }
    return { calls };
  }

  async holdCall(options: { callId: string; hold: boolean }): Promise<void> {
    const session = this.getSession(options.callId);
    if (!session.sessionDescriptionHandler) {
      throw new Error('No session description handler');
    }

    if (options.hold) {
      await session.invite({
        sessionDescriptionHandlerModifiers: [
          (description) => {
            description.sdp = description.sdp?.replace(
              /a=sendrecv/g,
              'a=sendonly',
            );
            return Promise.resolve(description);
          },
        ],
      });
    } else {
      await session.invite({
        sessionDescriptionHandlerModifiers: [
          (description) => {
            description.sdp = description.sdp?.replace(
              /a=sendonly/g,
              'a=sendrecv',
            );
            return Promise.resolve(description);
          },
        ],
      });
    }

    this.notifyCallState(
      options.callId,
      options.hold ? 'held' : 'confirmed',
    );
  }

  async muteCall(options: { callId: string; mute: boolean }): Promise<void> {
    const session = this.getSession(options.callId);
    const pc = this.getPeerConnection(session);
    pc.getSenders().forEach((sender) => {
      if (sender.track?.kind === 'audio') {
        sender.track.enabled = !options.mute;
      }
    });
  }

  async sendDtmf(options: { callId: string; digit: string }): Promise<void> {
    const session = this.getSession(options.callId);
    const pc = this.getPeerConnection(session);
    const sender = pc.getSenders().find((s) => s.track?.kind === 'audio');
    if (sender) {
      await sender.dtmf?.insertDTMF(options.digit, 100, 70);
    }
  }

  async transferCall(options: {
    callId: string;
    target: string;
  }): Promise<void> {
    const session = this.getSession(options.callId);
    const targetUri = UserAgent.makeURI(options.target);
    if (!targetUri) {
      throw new Error(`Invalid transfer target: ${options.target}`);
    }
    await session.refer(targetUri);
  }

  async registerPush(): Promise<void> {
    // Web uses persistent WSS connection for incoming calls — no push needed.
    // If the app wants browser push notifications for background tabs,
    // it can use the Web Push API separately.
    this.notifyListeners('pushTokenUpdated', {
      token: 'web-no-push',
      platform: 'web',
    });
  }

  async unregisterPush(): Promise<void> {
    // No-op on web
  }

  async setAudioRoute(options: { route: AudioRoute }): Promise<void> {
    // Web has limited audio routing control — only speaker toggle via setSinkId
    const session = this.sessions.values().next().value;
    if (!session) return;

    const pc = this.getPeerConnection(session);
    const receivers = pc.getReceivers();
    for (const receiver of receivers) {
      if (receiver.track?.kind === 'audio') {
        const audioEl =
          document.querySelector<HTMLAudioElement>('#pjsip-remote-audio') ??
          this.createAudioElement();

        const stream = new MediaStream([receiver.track]);
        audioEl.srcObject = stream;

        if ('setSinkId' in audioEl && options.route === 'speaker') {
          await (audioEl as any).setSinkId('default');
        }
      }
    }
  }

  // --- Private helpers ---

  private nextCallId(): string {
    return `web-call-${++this.callIdCounter}`;
  }

  private getSession(callId: string): Session {
    const session = this.sessions.get(callId);
    if (!session) {
      throw new Error(`No session for callId: ${callId}`);
    }
    return session;
  }

  private getPeerConnection(session: Session): RTCPeerConnection {
    const sdh = session.sessionDescriptionHandler as any;
    if (!sdh?.peerConnection) {
      throw new Error('No peer connection available');
    }
    return sdh.peerConnection as RTCPeerConnection;
  }

  private handleIncomingCall(invitation: Invitation): void {
    const callId = this.nextCallId();
    this.sessions.set(callId, invitation);
    this.setupSessionListeners(callId, invitation);

    const remoteUri = invitation.remoteIdentity.uri.toString();
    const callerName = invitation.remoteIdentity.displayName;

    // Inbound is the lowest-visibility code path — when 180 Ringing
    // goes out but the UI never shows, the only way to tell where the
    // chain broke is a breadcrumb at every link. Keep it as a one-line
    // info log so it's visible in production console without spamming.
    console.info(
      `[capacitor-pjsip] incoming INVITE → callId=${callId} ` +
        `from=${remoteUri} displayName=${callerName || '(none)'}`,
    );

    this.notifyListeners('incomingCall', {
      callId,
      remoteUri,
      callerName: callerName || undefined,
    });
  }

  private setupSessionListeners(callId: string, session: Session): void {
    session.stateChange.addListener((state: SessionState) => {
      const mapped = this.mapSessionState(state);
      if (mapped) {
        this.notifyCallState(callId, mapped);
      }
      if (state === SessionState.Terminated) {
        this.sessions.delete(callId);
      }
    });

    // Auto-attach remote audio when established, and start watching the
    // peer connection — see watchPeerConnectionHealth.
    session.stateChange.addListener((state: SessionState) => {
      if (state === SessionState.Established) {
        this.attachRemoteAudio(session);
        this.watchPeerConnectionHealth(callId, session);
      }
    });

    // Dedicated "remote ended the call" signal. sip.js calls these
    // delegate methods synchronously on receipt of the BYE/CANCEL,
    // BEFORE the state-machine transition that drives the stateChange
    // listener above. Having an independent code path means a remote
    // hangup is surfaced even when stateChange→Terminated would
    // otherwise be missed by our subscribers.
    //
    // See sip.js api/session-delegate.d.ts — onBye for established
    // sessions, onCancel for INVITE-phase aborts.
    session.delegate = {
      onBye: () => {
        this.notifyCallState(callId, 'disconnected');
      },
      onCancel: () => {
        this.notifyCallState(callId, 'disconnected');
      },
    };
  }

  /** Detect the *other* remote-hangup failure mode: the BYE never
   *  reaches sip.js at all (WSS transport drop, intermediate proxy
   *  swallowed it, etc.) so neither stateChange nor delegate.onBye
   *  fires. We watch the WebRTC peer connection directly — ICE consent
   *  freshness fails ~30s after the remote stops sending, transitioning
   *  `pc.connectionState` to 'disconnected' → 'failed'. That's an
   *  authoritative "the other side is gone" signal independent of
   *  SIP-layer events.
   *
   *  Bound at Established (when the peer connection exists) and
   *  removed when state transitions away or the call ends. */
  private watchPeerConnectionHealth(callId: string, session: Session): void {
    let pc: RTCPeerConnection;
    try {
      pc = this.getPeerConnection(session);
    } catch {
      return;
    }
    const handler = () => {
      const s = pc.connectionState;
      if (s === 'failed' || s === 'disconnected' || s === 'closed') {
        console.warn(
          `[capacitor-pjsip] peer connection ${s} on ${callId} — ` +
            `treating as remote hangup`,
        );
        pc.removeEventListener('connectionstatechange', handler);
        this.notifyCallState(callId, 'disconnected');
        this.sessions.delete(callId);
        // Try to send BYE on our end so the PBX cleans up its leg too —
        // best-effort, session may already be torn down.
        try {
          void session.bye();
        } catch {
          /* already gone */
        }
      }
    };
    pc.addEventListener('connectionstatechange', handler);
  }

  private mapSessionState(state: SessionState): CallState | null {
    switch (state) {
      case SessionState.Initial:
        return 'calling';
      case SessionState.Establishing:
        return 'connecting';
      case SessionState.Established:
        return 'confirmed';
      case SessionState.Terminated:
        return 'disconnected';
      default:
        return null;
    }
  }

  private notifyCallState(
    callId: string,
    state: CallState,
    remoteUri?: string,
  ): void {
    this.notifyListeners('callStateChanged', { callId, state, remoteUri });
  }

  private updateRegistrationState(state: RegistrationState, reason?: string): void {
    this.registrationState = state;
    this.notifyListeners('registrationStateChanged', { state, reason });
  }

  private attachRemoteAudio(session: Session): void {
    try {
      const pc = this.getPeerConnection(session);
      const receivers = pc.getReceivers();
      const audioReceiver = receivers.find((r) => r.track?.kind === 'audio');
      if (audioReceiver?.track) {
        const audioEl = this.createAudioElement();
        audioEl.srcObject = new MediaStream([audioReceiver.track]);
        audioEl.play().catch(() => {
          // Autoplay may be blocked — user gesture required
        });
      }
    } catch {
      // Session may not have peer connection yet
    }
  }

  private createAudioElement(): HTMLAudioElement {
    let el = document.querySelector<HTMLAudioElement>('#pjsip-remote-audio');
    if (!el) {
      el = document.createElement('audio');
      el.id = 'pjsip-remote-audio';
      el.autoplay = true;
      document.body.appendChild(el);
    }
    return el;
  }
}
