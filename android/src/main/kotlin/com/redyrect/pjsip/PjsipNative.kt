package com.redyrect.pjsip

/**
 * JNI bridge to the pjsua C API.
 * All methods run on the caller's thread — SipManager is responsible for
 * ensuring they are called from the correct (dedicated) thread.
 */
object PjsipNative {

    init {
        System.loadLibrary("pjsip_jni")
    }

    /** Callback interface invoked from native PJSIP threads */
    interface Callback {
        fun onRegState(state: String, reason: String?)
        /** [callUuid] is the INVITE's X-Redyrect-Call-UUID, empty when absent. */
        fun onIncomingCall(pjCallId: Int, remoteUri: String, callUuid: String)
        /** [incoming]: this phone was called. [sipStatus]/[sipReason]: the last
         *  SIP status the call reached (0/empty before any). */
        fun onCallState(pjCallId: Int, state: String, remoteUri: String, incoming: Boolean, sipStatus: Int, sipReason: String)
    }

    @JvmStatic external fun init(callback: Callback): Int
    @JvmStatic external fun createTransport(type: Int): Int
    @JvmStatic external fun start(): Int
    @JvmStatic external fun addAccount(
        sipUri: String, regUri: String, realm: String,
        username: String, password: String, proxy: String?,
        srtp: Int
    ): Int
    @JvmStatic external fun removeAccount()
    @JvmStatic external fun destroy()

    /** The pjsua call id, or the negated pj_status_t on failure. */
    @JvmStatic external fun makeCall(uri: String): Int
    /** PJSIP's description of a pj_status_t. */
    @JvmStatic external fun statusText(status: Int): String
    /** Re-REGISTER the account; 0 on success. */
    @JvmStatic external fun renewRegistration(): Int
    @JvmStatic external fun answerCall(callId: Int, code: Int): Int
    @JvmStatic external fun hangupCall(callId: Int)
    @JvmStatic external fun setHold(callId: Int)
    @JvmStatic external fun reinvite(callId: Int)
    @JvmStatic external fun adjustTxLevel(callId: Int, level: Float)
    @JvmStatic external fun dialDtmf(callId: Int, digits: String)
    @JvmStatic external fun transferCall(callId: Int, target: String)
}
