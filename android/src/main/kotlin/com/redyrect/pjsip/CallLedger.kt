package com.redyrect.pjsip

/**
 * The calls this phone knows about, and the one place `callUpdated` is sent
 * from. It keeps the rules the plugin's `CallSnapshot` promises — one id per
 * call, fields only added, `disconnected` once and then silence — so the
 * engine can report whatever PJSIP tells it, as often as PJSIP tells it.
 *
 * The same rules as `src/ledger.ts` (web) and `CallLedger.swift` (iOS);
 * change all three together. Main thread only.
 */
internal class CallLedger(private val emit: (Map<String, Any?>) -> Unit) {

    data class Call(
        val callId: String,
        val incoming: Boolean,
        var state: String,
        var remoteUri: String,
        var callerName: String?,
        var callUuid: String?,
        var answered: Boolean,
        var end: Map<String, Any?>? = null,
    ) {
        fun toMap(): Map<String, Any?> = buildMap {
            put("callId", callId)
            put("direction", if (incoming) "incoming" else "outgoing")
            put("state", state)
            put("remoteUri", remoteUri)
            callerName?.let { put("callerName", it) }
            callUuid?.let { put("callUuid", it) }
            put("answered", answered)
            end?.let { put("end", it) }
        }
    }

    private val calls = LinkedHashMap<String, Call>()
    /** Calls this side asked to end, so their end is `local`. */
    private val endedHere = mutableSetOf<String>()
    /** Calls already reported `disconnected`; anything later is dropped. */
    private val finished = mutableSetOf<String>()
    private val lastSent = mutableMapOf<String, Map<String, Any?>>()

    /** Start tracking a call, or add what is newly known about it. */
    fun open(
        callId: String,
        incoming: Boolean,
        state: String,
        remoteUri: String? = null,
        callerName: String? = null,
        callUuid: String? = null,
    ) {
        if (callId in finished) return
        if (calls.containsKey(callId)) {
            merge(callId, remoteUri, callerName, callUuid)
            return
        }
        if (state == "disconnected") return
        calls[callId] = Call(
            callId = callId,
            incoming = incoming,
            state = state,
            remoteUri = remoteUri.orEmpty(),
            callerName = callerName?.takeIf { it.isNotBlank() },
            callUuid = callUuid?.takeIf { it.isNotBlank() },
            answered = state == "confirmed",
        )
        send(callId)
    }

    /** Add the caller name, URI or PBX id learned after the call opened. */
    fun merge(callId: String, remoteUri: String? = null, callerName: String? = null, callUuid: String? = null) {
        val call = calls[callId] ?: return
        remoteUri?.takeIf { it.isNotBlank() }?.let { call.remoteUri = it }
        callerName?.takeIf { it.isNotBlank() }?.let { call.callerName = it }
        callUuid?.takeIf { it.isNotBlank() }?.let { call.callUuid = it }
        send(callId)
    }

    /** The engine's state for a call it already opened. */
    fun update(callId: String, state: String, remoteUri: String? = null) {
        val call = calls[callId] ?: return
        call.state = state
        remoteUri?.takeIf { it.isNotBlank() }?.let { call.remoteUri = it }
        if (state == "confirmed") call.answered = true
        send(callId)
    }

    /** This side is ending the call: its end is `local`, whoever finishes it. */
    fun endingHere(callId: String) {
        if (calls.containsKey(callId)) endedHere.add(callId)
    }

    /** The call is over. Sent once; every later report for it is dropped. */
    fun finish(callId: String, sipStatus: Int? = null, sipReason: String? = null) {
        val call = calls[callId] ?: return
        call.state = "disconnected"
        call.end = buildMap {
            put("by", if (callId in endedHere) "local" else "remote")
            sipStatus?.takeIf { it > 0 }?.let { put("sipStatus", it) }
            sipReason?.takeIf { it.isNotBlank() }?.let { put("sipReason", it) }
        }
        send(callId)
        calls.remove(callId)
        endedHere.remove(callId)
        lastSent.remove(callId)
        finished.add(callId)
    }

    /** A call that ended before it was ever opened — a push whose INVITE
     *  never came. Nothing is sent (the app never saw it), and later reports
     *  for it are dropped like any finished call's. */
    fun endUnopened(callId: String) {
        if (!calls.containsKey(callId)) finished.add(callId)
    }

    /** Whether the call is over here — a late or repeated push for it must
     *  not ring again. */
    fun isFinished(callId: String): Boolean = callId in finished

    fun has(callId: String): Boolean = calls.containsKey(callId)
    fun callerName(callId: String): String? = calls[callId]?.callerName

    /** Every live call, for `getActiveCalls`. */
    fun active(): List<Map<String, Any?>> = calls.values.map { it.toMap() }

    private fun send(callId: String) {
        val snapshot = calls[callId]?.toMap() ?: return
        if (lastSent[callId] == snapshot) return
        lastSent[callId] = snapshot
        emit(snapshot)
    }
}
