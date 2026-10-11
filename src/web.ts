import { WebPlugin } from '@capacitor/core';
import {
  UserAgent,
  Registerer,
  RegistererState,
  TransportState,
  Inviter,
  Invitation,
  SessionState,
  type Session,
} from 'sip.js';

import type {
  PjsipPlugin,
  SipAccountConfig,
  RegistrationState,
  CallState,
  AudioRoute,
  CallSnapshot,
  SipPermissionStatus,
} from './definitions';
import { CallLedger } from './ledger';

/**
 * SIP header the Redyrect PBX adds to inbound INVITEs carrying its own
 * `call_uuid` (matches the FCM push payload + the CDR `uuid`). The header
 * name is also published via `/public-config -> features.call_uuid_header`
 * for discoverability; we hardcode the canonical value here because the
 * plugin runs in any client and shouldn't depend on a config round-trip
 * before the first incoming INVITE.
 */
const CALL_UUID_HEADER = 'X-Redyrect-Call-UUID';

export class PjsipWeb extends WebPlugin implements PjsipPlugin {
  private ua: UserAgent | null = null;
  private registerer: Registerer | null = null;
  private sessions: Map<string, Session> = new Map();
  private callIdCounter = 0;
  private registrationState: RegistrationState = 'unregistered';
  /** Every call event goes out through here — see `CallLedger`. */
  private readonly ledger = new CallLedger((snapshot) =>
    this.notifyListeners('callUpdated', snapshot),
  );
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
        // RFC 6223 CRLF keep-alive on the WSS, at the PBX's interval
        // (/me/sip-config, the same one iOS and Android use). Corporate
        // NATs, proxies and some carriers close idle WebSockets within
        // 60-90s; without it the WSS dies silently while the user thinks
        // they're still registered.
        keepAliveInterval: options.keepAliveSec,
      },
      // Cap the ICE-gathering wait. sip.js defaults to 5000ms and many
      // browsers/networks never fire `icegatheringstatechange: complete`,
      // so the offer/answer SDP (and thus the INVITE / 200 OK) stalls the
      // full 5s — the visible "buttons lag ~5 seconds" symptom. Host +
      // srflx candidates gather in well under a second; 1s is a safe cap.
      sessionDescriptionHandlerFactoryOptions: {
        iceGatheringTimeout: 1000,
      },
      // sip.js's transport-level auto-reconnect. These are documented
      // as deprecated in the type defs but the API surface they drive
      // is still active and the only built-in way to recover a dropped
      // WSS. 999 attempts × 4s delay covers ~1 hour of network
      // outage; SipService.scheduleRetry is the umbrella above this
      // for whole-account re-init when even reconnects don't work.
      reconnectionAttempts: 999,
      reconnectionDelay: 4,
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

    // Subscribe to transport state — sip.js auto-reconnects the WSS
    // via reconnectionAttempts but does NOT auto re-REGISTER once the
    // socket comes back. Without this hook, the user looks registered
    // for the brief moment between transport-down and the next
    // refresh-window — and IS NOT actually reachable. Re-firing
    // register() on every Connected event re-syncs the SBC's contact
    // record immediately.
    this.ua.transport.stateChange.addListener((state) => {
      console.info(`[capacitor-pjsip] transport state → ${state}`);
      if (state === TransportState.Connected && this.registerer) {
        // Re-register if the Registerer thinks it's not registered.
        // When the Registerer's own state is still Registered (refresh
        // hasn't expired yet), skip — the SBC already has us.
        if (this.registerer.state !== RegistererState.Registered) {
          console.info(
            '[capacitor-pjsip] transport reconnected — firing fresh REGISTER',
          );
          void this.registerer.register().catch((err) => {
            console.warn(
              '[capacitor-pjsip] re-register after transport reconnect failed:',
              err,
            );
          });
        }
      }
      if (state === TransportState.Disconnected) {
        // Surface the drop to JS so SipService can flip the chip from
        // green to "reconnecting" instead of staying stale-green until
        // the next REGISTER refresh fails. sip.js's own auto-reconnect
        // handles the recovery; this is just visibility.
        if (this.registrationState === 'registered') {
          this.updateRegistrationState('unregistered', 'transport disconnected');
        }
      }
    });

    this.updateRegistrationState('registering');

    await this.ua.start();

    this.registerer = new Registerer(this.ua, {
      // The PBX's expiry (/me/sip-config), the same one iOS and Android
      // use: short, so the SBC drops a vanished client's contact quickly.
      expires: options.registerExpiresSec,
      // Refresh at 50% of expires instead of the default 99%. The
      // 99% default means a refresh attempt 6 seconds before expiry —
      // if it fails or the network blips, we lose registration with
      // no headroom. 50% (90s in) gives us multiple retry windows
      // before the SBC purges us.
      refreshFrequency: 50,
    });

    this.registerer.stateChange.addListener((state: RegistererState) => {
      console.info(`[capacitor-pjsip] registerer state → ${state}`);
      switch (state) {
        case RegistererState.Registered:
          this.updateRegistrationState('registered');
          break;
        case RegistererState.Unregistered:
          this.updateRegistrationState('unregistered');
          break;
        case RegistererState.Terminated:
          // The Registerer is dead — sip.js won't re-register from
          // this instance. Drop the reference so the next connect()
          // builds a fresh one. SipService's state-machine handles
          // the actual retry scheduling above us.
          this.updateRegistrationState('unregistered', 'registerer terminated');
          this.registerer = null;
          break;
      }
    });

    await this.registerer.register();
  }

  async updateCallDisplay(_options: {
    callId: string;
    displayName: string | null;
  }): Promise<void> {
    // No OS-level call UI on the web — the in-app UI already shows the name.
  }

  async checkPermissions(): Promise<SipPermissionStatus> {
    // The browser decides at getUserMedia time; nothing to report up front.
    return { microphone: 'prompt' };
  }

  async requestPermissions(_options?: {
    microphone?: boolean;
  }): Promise<SipPermissionStatus> {
    return { microphone: 'prompt' };
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

  async makeCall(options: { uri: string; displayName?: string }): Promise<{ callId: string }> {
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
    this.ledger.open({
      callId,
      direction: 'outgoing',
      state: 'calling',
      remoteUri: options.uri,
      callerName: options.displayName,
    });
    inviter
      .invite({
        requestDelegate: {
          // The final response refusing the call (486 busy, 603 decline,
          // 404 …) — what the call ended with.
          onReject: (response) => {
            const { statusCode, reasonPhrase } = response.message;
            this.ledger.finish(callId, statusCode, reasonPhrase);
          },
        },
      })
      .catch((err) => {
        console.error('[capacitor-pjsip] inviter.invite failed', err);
        this.sessions.delete(callId);
        this.ledger.finish(callId, undefined, String(err?.message ?? err));
      });

    return { callId };
  }

  async answerCall(options: { callId: string }): Promise<void> {
    const { callId } = options;
    const session = this.getSession(callId);
    if (!(session instanceof Invitation)) {
      throw new Error(`Call ${callId} is not an incoming call; it cannot be answered`);
    }
    // accept() takes the microphone, builds the answer SDP and sends the
    // 200 OK; until it resolves the PBX still sees this device ringing. Each
    // step is logged so a call that "did not connect" shows where it stopped.
    console.info(`[capacitor-pjsip] answer ${callId}: taking the microphone and sending 200 OK`);
    try {
      await session.accept({
        sessionDescriptionHandlerOptions: {
          constraints: { audio: true, video: false },
        },
      });
    } catch (err) {
      console.error(`[capacitor-pjsip] answer ${callId} failed`, err);
      throw err;
    }
    console.info(`[capacitor-pjsip] answer ${callId}: 200 OK sent`);
  }

  async hangupCall(options: { callId: string }): Promise<void> {
    const session = this.getSession(options.callId);
    this.ledger.endingHere(options.callId);
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
    // Don't `sessions.delete()` here. The `setupSessionListeners`
    // stateChange handler removes on SessionState.Terminated — which
    // is the authoritative transition once sip.js confirms the remote
    // (or the local timer) finalized the dialog. Optimistic cleanup
    // here matches the bug the iOS plugin warns about ("local side
    // cleared while the remote softphone kept showing the call as
    // live") if our local cancel/bye/reject fails to actually reach
    // the SBC — we'd lose the ability to retry or to surface the
    // ongoing state to the user.
  }

  async getActiveCalls(): Promise<{ calls: CallSnapshot[] }> {
    return { calls: this.ledger.active() };
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

    this.ledger.update(options.callId, options.hold ? 'held' : 'confirmed');
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
    // PBX-side correlation header. Optional — only present when the PBX
    // emits it. Wrap defensively because sip.js's request shape can vary
    // between versions and a thrown error here would lose the whole
    // incomingCall event.
    let callUuid: string | undefined;
    try {
      const raw = invitation.request.getHeader(CALL_UUID_HEADER);
      if (raw) callUuid = raw.trim() || undefined;
    } catch {
      /* header absent or unreadable — fine */
    }

    // One-line breadcrumb so any future inbound-routing debug has a
    // visible anchor on the wire side. Trimmed down from the diagnostic
    // listener-state dump used during initial bring-up — that helped
    // find the Capacitor singleton-race; not noise we need on every call.
    console.info(
      `[capacitor-pjsip] incoming INVITE → callId=${callId} ` +
        `callUuid=${callUuid ?? '(none)'} from=${remoteUri} ` +
        `displayName=${callerName || '(none)'}`,
    );

    this.ledger.open({
      callId,
      direction: 'incoming',
      state: 'incoming',
      remoteUri,
      callerName: callerName || undefined,
      callUuid,
    });
  }

  private setupSessionListeners(callId: string, session: Session): void {
    session.stateChange.addListener((state: SessionState) => {
      // One-line trace so a "stuck in call" report can confirm whether
      // sip.js's state machine actually transitioned. If we never see
      // Terminating/Terminated for a call the user already hung up
      // on, the issue is upstream of us (PBX didn't relay BYE, WSS
      // dropped before BYE arrived, etc).
      console.info(
        `[capacitor-pjsip] session ${callId} → ${state}`,
      );
      const mapped = this.mapSessionState(state, session);
      if (mapped) {
        this.ledger.update(callId, mapped);
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
    // sessions, onCancel for INVITE-phase aborts. The delegate is
    // called with the incoming Bye / Cancel request as the first arg;
    // we ignore the body and just surface the disconnect.
    session.delegate = {
      onBye: () => {
        console.info(`[capacitor-pjsip] onBye ${callId} (remote hangup)`);
        this.ledger.finish(callId);
      },
      onCancel: () => {
        console.info(`[capacitor-pjsip] onCancel ${callId} (remote cancel)`);
        this.ledger.finish(callId, 487, 'Request Terminated');
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
   *  Also watches signalingState for hold/resume re-INVITES — see
   *  watchHoldState for the rationale.
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
        this.ledger.finish(callId, undefined, `media ${s}`);
        // Authoritative cleanup happens via stateChange→Terminated in
        // setupSessionListeners. Try to send BYE on our end so the
        // PBX cleans up its leg too — best-effort, session may
        // already be torn down.
        try {
          void session.bye();
        } catch {
          /* already gone */
        }
      }
    };
    pc.addEventListener('connectionstatechange', handler);
    this.watchHoldState(callId, session, pc);
  }

  /** Track effective hold state by inspecting the remote SDP after
   *  every re-negotiation. The local-hold path in `holdCall` already
   *  emits 'held'/'confirmed' explicitly when the user pauses from
   *  THIS side, but a *remote*-initiated hold (the other party's
   *  softphone presses Hold) arrives as an incoming re-INVITE that
   *  changes the remote SDP direction without firing any state-
   *  transition we were listening for. Without this watch, the iOS
   *  plugin would show 'held' for a remote hold (it derives from
   *  PJSIP media_status) but the web build would stay on 'confirmed'
   *  — same call, different state.
   *
   *  Direction attribute readings from the REMOTE description:
   *    - sendrecv (or absent): nobody is holding → 'confirmed'
   *    - sendonly: remote is sending (their hold music) → 'held'
   *    - recvonly: WE held, remote answered recvonly → 'held'
   *    - inactive: both holds, or some IVRs idle → 'held'
   *
   *  Both local- and remote-initiated holds end up showing as 'held'
   *  in the UI — the user only cares that the audio is paused, not
   *  which side paused it. This makes the same `watchHoldState`
   *  handler the single source of truth for hold UI on web,
   *  redundantly emitting alongside `holdCall`'s explicit notify but
   *  with the same state — harmless. */
  private watchHoldState(
    callId: string,
    session: Session,
    pc: RTCPeerConnection,
  ): void {
    // Remember the last hold-state we emitted so a noisy
    // signalingstatechange (one fires PER negotiation step) doesn't
    // flood the bridge with redundant events.
    let lastHeld: boolean | null = null;
    const evaluate = () => {
      // Only sample on `stable` — that's when offer/answer is done
      // and the remote description reflects the final negotiated
      // direction. Sampling mid-negotiation reads stale state.
      if (pc.signalingState !== 'stable') return;
      const sdp = pc.remoteDescription?.sdp;
      if (!sdp) return;
      const held = isAudioHeld(sdp);
      if (held === lastHeld) return;
      lastHeld = held;
      // Don't fire while the session is mid-teardown — the
      // stateChange→Terminated path owns that surface.
      if (
        session.state === SessionState.Terminated ||
        session.state === SessionState.Terminating
      ) {
        return;
      }
      this.ledger.update(callId, held ? 'held' : 'confirmed');
    };
    pc.addEventListener('signalingstatechange', evaluate);
    // Sample once at install time too — covers the case where a
    // hold-on-answer arrives (the PBX places the leg on hold the
    // moment the call connects, e.g. a join-after-hold transfer).
    evaluate();
  }

  /**
   * Map sip.js's symmetric Session lifecycle to our app's direction-aware
   * CallState. `SessionState.Initial` means very different things for the
   * two kinds of session and there is NO way to know which from the enum
   * alone — Inviter starts in Initial before sending INVITE (we're
   * dialing) while Invitation starts in Initial after receiving INVITE
   * (we're being rung). Pass the session so we can disambiguate; without
   * it, the safe default mirrors the outbound semantics so a context-less
   * lookup never silently reports an Initial session as ringing.
   */
  private mapSessionState(
    state: SessionState,
    session?: Session,
  ): CallState | null {
    switch (state) {
      case SessionState.Initial:
        return session instanceof Invitation ? 'incoming' : 'calling';
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

/**
 * Returns true if the SDP advertises a paused-audio direction.
 *
 * A standard sendrecv media line has no direction attribute (or
 * explicitly `a=sendrecv`). When a SIP hold takes effect the SDP for
 * the audio media line is rewritten to one of:
 *   - `a=sendonly` — the writer sends only (typical "I'm holding you")
 *   - `a=recvonly` — the writer receives only (typical answer to a
 *     remote sendonly offer when WE held them)
 *   - `a=inactive` — neither direction (mutual hold / IVR idle)
 *
 * Any of those, found in the REMOTE description, means the call is
 * not flowing audio in both directions — surface as 'held' in the UI.
 *
 * The regex is intentionally permissive: we don't try to scope to the
 * audio m-section, because direction attributes only ever appear with
 * a media line above them in practice (the session-level `a=`
 * direction in RFC 4566 §6 is vanishingly rare and would mean the
 * same thing for our purposes anyway).
 */
function isAudioHeld(sdp: string): boolean {
  return /^a=(?:sendonly|recvonly|inactive)\b/m.test(sdp);
}
