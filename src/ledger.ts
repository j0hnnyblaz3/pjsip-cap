import type { CallDirection, CallSnapshot, CallState } from './definitions';

/**
 * The calls this engine knows about, and the one place `callUpdated` is sent
 * from. It keeps the rules `CallSnapshot` promises — one id per call, fields
 * only added, `disconnected` once and then silence — so the engine around it
 * can report whatever its SIP stack tells it, as often as it tells it.
 *
 * The iOS (`CallLedger.swift`) and Android (`CallLedger.kt`) ledgers are the
 * same rules in those languages; change all three together.
 */
export class CallLedger {
  private readonly calls = new Map<string, CallSnapshot>();
  /** Calls this side asked to end, so their `end.by` is `local`. */
  private readonly endedHere = new Set<string>();
  /** Calls already reported `disconnected`; anything later is dropped. */
  private readonly finished = new Set<string>();
  /** The last snapshot sent per call, so a repeat of it is not sent again. */
  private readonly lastSent = new Map<string, string>();

  constructor(private readonly emit: (snapshot: CallSnapshot) => void) {}

  /** Start tracking a call, or add what is newly known about it. */
  open(call: {
    callId: string;
    direction: CallDirection;
    state: CallState;
    remoteUri?: string;
    callerName?: string;
    callUuid?: string;
  }): void {
    if (this.finished.has(call.callId)) return;
    const known = this.calls.get(call.callId);
    if (known) {
      this.merge(call.callId, call);
      return;
    }
    if (call.state === 'disconnected') return;
    this.calls.set(call.callId, {
      callId: call.callId,
      direction: call.direction,
      state: call.state,
      remoteUri: call.remoteUri ?? '',
      callerName: call.callerName || undefined,
      callUuid: call.callUuid,
      answered: call.state === 'confirmed',
    });
    this.send(call.callId);
  }

  /** Add the caller name, URI or PBX id learned after the call opened. */
  merge(
    callId: string,
    fields: { remoteUri?: string; callerName?: string; callUuid?: string },
  ): void {
    const call = this.calls.get(callId);
    if (!call) return;
    if (fields.remoteUri) call.remoteUri = fields.remoteUri;
    if (fields.callerName) call.callerName = fields.callerName;
    if (fields.callUuid) call.callUuid = fields.callUuid;
    this.send(callId);
  }

  /** The engine's state for a call it already opened. `disconnected` goes
   *  through `finish`, which is where its SIP status belongs. */
  update(callId: string, state: CallState, remoteUri?: string): void {
    if (state === 'disconnected') {
      this.finish(callId);
      return;
    }
    const call = this.calls.get(callId);
    if (!call) return;
    call.state = state;
    if (remoteUri) call.remoteUri = remoteUri;
    if (state === 'confirmed') call.answered = true;
    this.send(callId);
  }

  /** This side is ending the call: its end is `local`, whoever finishes it. */
  endingHere(callId: string): void {
    if (this.calls.has(callId)) this.endedHere.add(callId);
  }

  /** The call is over. Sent once; every later report for it is dropped. */
  finish(callId: string, sipStatus?: number, sipReason?: string): void {
    const call = this.calls.get(callId);
    if (!call) return;
    call.state = 'disconnected';
    call.end = {
      by: this.endedHere.has(callId) ? 'local' : 'remote',
      ...(sipStatus ? { sipStatus } : {}),
      ...(sipReason ? { sipReason } : {}),
    };
    this.send(callId);
    this.calls.delete(callId);
    this.endedHere.delete(callId);
    this.lastSent.delete(callId);
    this.finished.add(callId);
  }

  has(callId: string): boolean {
    return this.calls.has(callId);
  }

  /** Every live call, for `getActiveCalls`. */
  active(): CallSnapshot[] {
    return [...this.calls.values()].map((c) => ({ ...c }));
  }

  private send(callId: string): void {
    const call = this.calls.get(callId);
    if (!call) return;
    const key = JSON.stringify(call);
    if (this.lastSent.get(callId) === key) return;
    this.lastSent.set(callId, key);
    this.emit({ ...call, ...(call.end ? { end: { ...call.end } } : {}) });
  }
}
