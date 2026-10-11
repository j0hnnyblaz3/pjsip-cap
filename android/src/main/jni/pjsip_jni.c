/**
 * JNI bridge for pjsua C API.
 * Maps Kotlin PjsipNative external functions to pjsua calls.
 */
#include <jni.h>
#include <string.h>
#include <pjsua-lib/pjsua.h>
#include <android/log.h>

/* One logcat tag for the whole plugin — Kotlin (Logging.kt) and PJSIP. */
#define TAG "Pjsip"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* PJSIP log callback: every PJSIP line to logcat, minus the sound-device
 * underflow chatter that fires every ~20 ms while no media flows. */
static void pjsip_log_writer(int level, const char *data, int len)
{
    char line[2048];
    int n = len < (int)sizeof(line) - 1 ? len : (int)sizeof(line) - 1;
    (void)level;
    if (strstr(data, "Underflow") && (strstr(data, "capdbuf") || strstr(data, "playdbuf")))
        return;
    memcpy(line, data, (size_t)n);
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) n--;
    line[n] = '\0';
    __android_log_write(ANDROID_LOG_INFO, TAG, line);
}

/* Global references for callback dispatch */
/* pjlib (os_core_unix.c, PJ_ANDROID) defines JNI_OnLoad itself and stores
 * the JavaVM in pj_jni_jvm. Defining our own JNI_OnLoad here collides with
 * it at link time (duplicate symbol), so we reuse pjlib's. */
extern JavaVM *pj_jni_jvm;
#define g_vm pj_jni_jvm
static jobject g_callback = NULL;
static pjsua_acc_id g_acc_id = PJSUA_INVALID_ID;
/* The SIP transport the account is bound to (createTransport). */
static pjsua_transport_id g_tid = PJSUA_INVALID_ID;
static int g_started = 0;

/* Helper: get JNIEnv for the current thread, attaching if needed */
static JNIEnv* get_env(int *need_detach) {
    JNIEnv *env = NULL;
    *need_detach = 0;
    if ((*g_vm)->GetEnv(g_vm, (void**)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
        (*g_vm)->AttachCurrentThread(g_vm, &env, NULL);
        *need_detach = 1;
    }
    return env;
}

static void release_env(int need_detach) {
    if (need_detach) {
        (*g_vm)->DetachCurrentThread(g_vm);
    }
}

/* Helper: call a void method on the callback object */
static void call_callback(const char *method, const char *sig, ...) {
    if (!g_callback || !g_vm) return;

    int need_detach;
    JNIEnv *env = get_env(&need_detach);
    if (!env) return;

    jclass cls = (*env)->GetObjectClass(env, g_callback);
    jmethodID mid = (*env)->GetMethodID(env, cls, method, sig);
    if (mid) {
        va_list args;
        va_start(args, sig);
        (*env)->CallVoidMethodV(env, g_callback, mid, args);
        va_end(args);
    }
    (*env)->DeleteLocalRef(env, cls);
    release_env(need_detach);
}

/* ---- PJSIP Callbacks ---- */

static void on_reg_state2(pjsua_acc_id acc_id, pjsua_reg_info *info) {
    if (!g_callback || !g_vm) return;

    int code = info->cbparam->code;
    const char *state;
    const char *reason = NULL;
    char reason_buf[32];

    if (code / 100 == 2) {
        state = "registered";
    } else if (code == 0) {
        state = "unregistered";
    } else {
        state = "failed";
        snprintf(reason_buf, sizeof(reason_buf), "SIP %d", code);
        reason = reason_buf;
    }

    int need_detach;
    JNIEnv *env = get_env(&need_detach);
    if (!env) return;

    jstring jstate = (*env)->NewStringUTF(env, state);
    jstring jreason = reason ? (*env)->NewStringUTF(env, reason) : NULL;

    jclass cls = (*env)->GetObjectClass(env, g_callback);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onRegState",
        "(Ljava/lang/String;Ljava/lang/String;)V");
    if (mid) {
        (*env)->CallVoidMethod(env, g_callback, mid, jstate, jreason);
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, jstate);
    if (jreason) (*env)->DeleteLocalRef(env, jreason);
    release_env(need_detach);
}

static void on_incoming_call(pjsua_acc_id acc_id, pjsua_call_id call_id,
                             pjsip_rx_data *rdata) {
    pjsua_call_info ci;
    pjsua_call_get_info(call_id, &ci);

    char remote_info[256];
    snprintf(remote_info, sizeof(remote_info), "%.*s",
             (int)ci.remote_info.slen, ci.remote_info.ptr);

    /* The PBX's call id, which its push carried too: ties this INVITE to the
     * call the push already reported. Empty when the header is absent. */
    static const pj_str_t uuid_hdr_name = { "X-Redyrect-Call-UUID", 20 };
    char call_uuid[128] = "";
    if (rdata && rdata->msg_info.msg) {
        pjsip_generic_string_hdr *h = (pjsip_generic_string_hdr *)
            pjsip_msg_find_hdr_by_name(rdata->msg_info.msg, &uuid_hdr_name, NULL);
        if (h) {
            snprintf(call_uuid, sizeof(call_uuid), "%.*s",
                     (int)h->hvalue.slen, h->hvalue.ptr);
        }
    }

    int need_detach;
    JNIEnv *env = get_env(&need_detach);
    if (!env) return;

    jstring jremote = (*env)->NewStringUTF(env, remote_info);
    jstring juuid = (*env)->NewStringUTF(env, call_uuid);

    jclass cls = (*env)->GetObjectClass(env, g_callback);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onIncomingCall",
        "(ILjava/lang/String;Ljava/lang/String;)V");
    if (mid) {
        (*env)->CallVoidMethod(env, g_callback, mid, (jint)call_id, jremote, juuid);
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, jremote);
    (*env)->DeleteLocalRef(env, juuid);
    release_env(need_detach);

    /* Ring only after Kotlin knows the call: the 180 fires a state change,
     * and one arriving first gave the call a second, made-up id. */
    pjsua_call_answer(call_id, 180, NULL, NULL);
}

/* Report call [call_id] to Kotlin as it stands now: the state the app
 * sees (held included), which side placed it, and the SIP status it has
 * reached. The one report for both PJSIP callbacks, so a hold that changes
 * only the media is reported like any other change — as on iOS. */
static void report_call(pjsua_call_id call_id) {
    /* pjsua invalidates the call before/while delivering the terminal
     * DISCONNECTED transition, so pjsua_call_get_info() routinely fails
     * exactly here. The invocation itself is the authoritative signal:
     * pjsua called us for this call, so something changed. If we cannot
     * read the call, the only thing it can be is gone. Never report
     * "unknown" — every consumer treats a non-terminal state as "still up". */
    pjsua_call_info ci;
    pj_bzero(&ci, sizeof(ci));

    const char *state;
    pj_status_t status = pjsua_call_get_info(call_id, &ci);

    if (status != PJ_SUCCESS) {
        LOGI("call %d: get_info failed (%d) — reporting disconnected",
             (int)call_id, (int)status);
        state = "disconnected";
    } else {
        switch (ci.state) {
            case PJSIP_INV_STATE_NULL:          state = "null"; break;
            case PJSIP_INV_STATE_CALLING:       state = "calling"; break;
            case PJSIP_INV_STATE_INCOMING:      state = "incoming"; break;
            case PJSIP_INV_STATE_EARLY:
                /* EARLY means opposite things by direction. Outbound: the far
                 * end is ringing. Inbound: we answered the INVITE with 180
                 * Ringing and the call is still waiting to be picked up, which
                 * the app must draw with an Answer button. */
                state = (ci.role == PJSIP_ROLE_UAS) ? "incoming" : "early";
                break;
            case PJSIP_INV_STATE_CONNECTING:    state = "connecting"; break;
            case PJSIP_INV_STATE_CONFIRMED:
                /* PJSIP has no held inv state: a held call stays CONFIRMED
                 * and the hold lives in the media status. */
                state = (ci.media_status == PJSUA_CALL_MEDIA_LOCAL_HOLD ||
                         ci.media_status == PJSUA_CALL_MEDIA_REMOTE_HOLD)
                            ? "held" : "confirmed";
                break;
            case PJSIP_INV_STATE_DISCONNECTED:  state = "disconnected"; break;
            /* An inv_state pjsua added after this was written. Reporting it
             * as still-up would strand the call; disconnected is the safe
             * terminal answer and is logged so it can't pass unnoticed. */
            default:
                LOGE("call %d: unmapped inv_state %d — reporting disconnected",
                     (int)call_id, (int)ci.state);
                state = "disconnected";
                break;
        }
    }

    char remote_info[256] = "";
    char last_reason[128] = "";
    if (status == PJ_SUCCESS) {
        if (ci.remote_info.slen > 0)
            snprintf(remote_info, sizeof(remote_info), "%.*s",
                     (int)ci.remote_info.slen, ci.remote_info.ptr);
        if (ci.last_status_text.slen > 0)
            snprintf(last_reason, sizeof(last_reason), "%.*s",
                     (int)ci.last_status_text.slen, ci.last_status_text.ptr);
    }
    jboolean incoming = (status == PJ_SUCCESS && ci.role == PJSIP_ROLE_UAS);
    jint last_status = (status == PJ_SUCCESS) ? (jint)ci.last_status : 0;

    int need_detach;
    JNIEnv *env = get_env(&need_detach);
    if (!env) return;

    jstring jstate = (*env)->NewStringUTF(env, state);
    jstring jremote = (*env)->NewStringUTF(env, remote_info);
    jstring jreason = (*env)->NewStringUTF(env, last_reason);

    jclass cls = (*env)->GetObjectClass(env, g_callback);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onCallState",
        "(ILjava/lang/String;Ljava/lang/String;ZILjava/lang/String;)V");
    if (mid) {
        (*env)->CallVoidMethod(env, g_callback, mid, (jint)call_id, jstate, jremote,
                               incoming, last_status, jreason);
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, jstate);
    (*env)->DeleteLocalRef(env, jremote);
    (*env)->DeleteLocalRef(env, jreason);
    release_env(need_detach);
}

static void on_call_state(pjsua_call_id call_id, pjsip_event *e) {
    PJ_UNUSED_ARG(e);
    report_call(call_id);
}

static void on_call_media_state(pjsua_call_id call_id) {
    pjsua_call_info ci;
    if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) return;

    /* Wire the call to the sound device while its media is active; take it
     * off while held, so a held call is silent and a second call can have
     * the device to itself. */
    if (ci.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        pjsua_conf_connect(ci.conf_slot, 0);
        pjsua_conf_connect(0, ci.conf_slot);
    } else if (ci.conf_slot != PJSUA_INVALID_ID) {
        pjsua_conf_disconnect(ci.conf_slot, 0);
        pjsua_conf_disconnect(0, ci.conf_slot);
    }
    /* A hold or resume changes only the media; report it. */
    report_call(call_id);
}

/* ---- JNI Methods ---- */


JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_init(JNIEnv *env, jclass cls, jobject callback) {
    pj_status_t status;

    if (g_started) return 0;

    /* Store global ref for callbacks */
    if (g_callback) (*env)->DeleteGlobalRef(env, g_callback);
    g_callback = (*env)->NewGlobalRef(env, callback);

    /* Create pjsua */
    status = pjsua_create();
    if (status != PJ_SUCCESS) {
        LOGE("pjsua_create failed: %d", status);
        return status;
    }

    /* Init with callbacks */
    pjsua_config cfg;
    pjsua_config_default(&cfg);
    cfg.cb.on_reg_state2 = &on_reg_state2;
    cfg.cb.on_incoming_call = &on_incoming_call;
    cfg.cb.on_call_state = &on_call_state;
    cfg.cb.on_call_media_state = &on_call_media_state;

    /* PJSIP's own lines, SIP messages included, go to logcat through
     * pjsip_log_writer. Without a callback pjsua's default writer prints to
     * stdout, which Android discards. console_level gates the callback
     * (pjsua hands it only lines at or below console_level), so it must
     * match `level`. */
    pjsua_logging_config log_cfg;
    pjsua_logging_config_default(&log_cfg);
    log_cfg.level = 5;
    log_cfg.console_level = 5;
    log_cfg.msg_logging = PJ_TRUE;
    log_cfg.cb = &pjsip_log_writer;

    pjsua_media_config media_cfg;
    pjsua_media_config_default(&media_cfg);

    status = pjsua_init(&cfg, &log_cfg, &media_cfg);
    if (status != PJ_SUCCESS) {
        LOGE("pjsua_init failed: %d", status);
        pjsua_destroy();
        g_tid = PJSUA_INVALID_ID;
        return status;
    }

    g_started = 1;
    return 0;
}

JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_createTransport(JNIEnv *env, jclass cls, jint type) {
    pjsip_transport_type_e tp;
    switch (type) {
        case 1:  tp = PJSIP_TRANSPORT_TCP; break;
        case 2:  tp = PJSIP_TRANSPORT_TLS; break;
        default: tp = PJSIP_TRANSPORT_UDP; break;
    }

    pjsua_transport_config tcfg;
    pjsua_transport_config_default(&tcfg);

    pj_status_t status = pjsua_transport_create(tp, &tcfg, &g_tid);
    if (status != PJ_SUCCESS) {
        LOGE("pjsua_transport_create failed: %d", status);
        g_tid = PJSUA_INVALID_ID;
    }
    return status;
}

JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_start(JNIEnv *env, jclass cls) {
    pj_status_t status = pjsua_start();
    if (status != PJ_SUCCESS) {
        LOGE("pjsua_start failed: %d", status);
        pjsua_destroy();
        g_tid = PJSUA_INVALID_ID;
        g_started = 0;
    }
    return status;
}

JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_addAccount(JNIEnv *env, jclass cls,
    jstring jsipUri, jstring jregUri, jstring jrealm,
    jstring jusername, jstring jpassword, jstring jproxy, jint jsrtp,
    jint jregExpires, jint jkeepAlive) {

    const char *sip_uri = (*env)->GetStringUTFChars(env, jsipUri, NULL);
    const char *reg_uri = (*env)->GetStringUTFChars(env, jregUri, NULL);
    const char *realm = (*env)->GetStringUTFChars(env, jrealm, NULL);
    const char *username = (*env)->GetStringUTFChars(env, jusername, NULL);
    const char *password = (*env)->GetStringUTFChars(env, jpassword, NULL);
    const char *proxy = jproxy ? (*env)->GetStringUTFChars(env, jproxy, NULL) : NULL;

    pjsua_acc_config acc_cfg;
    pjsua_acc_config_default(&acc_cfg);

    acc_cfg.id = pj_str((char*)sip_uri);
    acc_cfg.reg_uri = pj_str((char*)reg_uri);
    /* Media encryption. -1 means the caller stated no policy, so pjsua's
       default stands. srtp_secure_signaling is forced to 0 so this governs
       MEDIA only — requiring a secure signalling transport is the separate
       transport setting's job, and coupling them here would fail
       registrations the admin never asked to change. */
    if (jsrtp >= 0) {
        acc_cfg.use_srtp = (pjmedia_srtp_use)jsrtp;
        acc_cfg.srtp_secure_signaling = 0;
    }

    acc_cfg.cred_count = 1;
    acc_cfg.cred_info[0].realm = pj_str((char*)realm);
    acc_cfg.cred_info[0].scheme = pj_str("digest");
    acc_cfg.cred_info[0].username = pj_str((char*)username);
    acc_cfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    acc_cfg.cred_info[0].data = pj_str((char*)password);

    if (proxy && strlen(proxy) > 0) {
        acc_cfg.proxy_cnt = 1;
        acc_cfg.proxy[0] = pj_str((char*)proxy);
    }

    /* Bind the account to its transport, as iOS does. Every request of the
     * account — in-dialog ones included — then leaves on it, i.e. on the TLS
     * connection to the SBC. Unbound, a BYE followed the SBC's
     * Record-Route (no ;transport) to UDP, which this phone has no transport
     * for: the BYE was never sent and the other phone stayed in the call. */
    if (g_tid != PJSUA_INVALID_ID) {
        acc_cfg.transport_id = g_tid;
    }

    acc_cfg.reg_retry_interval = 300;
    acc_cfg.reg_first_retry_interval = 30;
    /* How often to refresh REGISTER and ping the registration connection:
     * the PBX's numbers (/me/sip-config), the same ones iOS and web use. */
    acc_cfg.reg_timeout = (unsigned)jregExpires;
    acc_cfg.ka_interval = (unsigned)jkeepAlive;
    /* Refresh halfway through, as web does (refreshFrequency 50). */
    acc_cfg.reg_delay_before_refresh = (unsigned)jregExpires / 2;

    pj_status_t status = pjsua_acc_add(&acc_cfg, PJ_TRUE, &g_acc_id);

    (*env)->ReleaseStringUTFChars(env, jsipUri, sip_uri);
    (*env)->ReleaseStringUTFChars(env, jregUri, reg_uri);
    (*env)->ReleaseStringUTFChars(env, jrealm, realm);
    (*env)->ReleaseStringUTFChars(env, jusername, username);
    (*env)->ReleaseStringUTFChars(env, jpassword, password);
    if (proxy) (*env)->ReleaseStringUTFChars(env, jproxy, proxy);

    if (status != PJ_SUCCESS) {
        LOGE("pjsua_acc_add failed: %d", status);
    }
    return status;
}

JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_removeAccount(JNIEnv *env, jclass cls) {
    if (g_acc_id != PJSUA_INVALID_ID) {
        pjsua_acc_del(g_acc_id);
        g_acc_id = PJSUA_INVALID_ID;
    }
}

JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_destroy(JNIEnv *env, jclass cls) {
    if (g_started) {
        pjsua_destroy();
        g_tid = PJSUA_INVALID_ID;
        g_started = 0;
        g_acc_id = PJSUA_INVALID_ID;
    }
    if (g_callback) {
        (*env)->DeleteGlobalRef(env, g_callback);
        g_callback = NULL;
    }
}

JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_makeCall(JNIEnv *env, jclass cls, jstring juri) {
    /* Failure returns the negated pj_status_t, so Kotlin can ask statusText
     * for PJSIP's own reason. */
    if (g_acc_id == PJSUA_INVALID_ID) return -PJ_EINVALIDOP;

    const char *uri = (*env)->GetStringUTFChars(env, juri, NULL);
    pj_str_t pj_uri = pj_str((char*)uri);
    pjsua_call_id call_id;

    pj_status_t status = pjsua_call_make_call(g_acc_id, &pj_uri, NULL, NULL, NULL, &call_id);
    (*env)->ReleaseStringUTFChars(env, juri, uri);

    if (status != PJ_SUCCESS) {
        LOGE("pjsua_call_make_call failed: %d", status);
        return -status;
    }
    return call_id;
}

/* PJSIP's description of a pj_status_t ("Invalid Request URI", ...). */
JNIEXPORT jstring JNICALL
Java_com_redyrect_pjsip_PjsipNative_statusText(JNIEnv *env, jclass cls, jint status) {
    char buf[160];
    pj_strerror((pj_status_t)status, buf, sizeof(buf));
    return (*env)->NewStringUTF(env, buf);
}

/* Send a fresh REGISTER: the transport may have died while the phone slept,
 * leaving the PBX a contact that no longer reaches us. */
/* Offer exactly the PBX's codecs, in its order, and nothing else — as iOS
 * does. A PJSIP codec id is name/rate[/channels]; a listed name enables
 * every rate of it. */
JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_setCodecs(JNIEnv *env, jclass cls, jobjectArray jnames) {
    pjsua_codec_info codecs[64];
    unsigned count = PJ_ARRAY_SIZE(codecs);
    if (pjsua_enum_codecs(codecs, &count) != PJ_SUCCESS) {
        LOGE("pjsua_enum_codecs failed — codecs left as they were");
        return;
    }
    jsize wanted = (*env)->GetArrayLength(env, jnames);
    char offered[512] = "";
    for (unsigned i = 0; i < count; i++) {
        const pj_str_t *id = &codecs[i].codec_id;
        int name_len = 0;
        while (name_len < id->slen && id->ptr[name_len] != '/') name_len++;
        pj_uint8_t priority = 0;
        for (jsize w = 0; w < wanted; w++) {
            jstring jname = (jstring)(*env)->GetObjectArrayElement(env, jnames, w);
            const char *name = (*env)->GetStringUTFChars(env, jname, NULL);
            int match = (int)strlen(name) == name_len && strncasecmp(name, id->ptr, name_len) == 0;
            (*env)->ReleaseStringUTFChars(env, jname, name);
            (*env)->DeleteLocalRef(env, jname);
            if (match) {
                int p = 250 - (int)w * 10;
                priority = (pj_uint8_t)(p < 1 ? 1 : p);
                break;
            }
        }
        pjsua_codec_set_priority(id, priority);
        if (priority > 0) {
            size_t used = strlen(offered);
            snprintf(offered + used, sizeof(offered) - used, "%s%.*s=%u",
                     used ? ", " : "", (int)id->slen, id->ptr, priority);
        }
    }
    LOGI("codecs offered: %s", offered);
}

JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_renewRegistration(JNIEnv *env, jclass cls) {
    if (g_acc_id == PJSUA_INVALID_ID) return -PJ_EINVALIDOP;
    return pjsua_acc_set_registration(g_acc_id, PJ_TRUE);
}

JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_answerCall(JNIEnv *env, jclass cls, jint callId, jint code) {
    return pjsua_call_answer((pjsua_call_id)callId, (unsigned)code, NULL, NULL);
}

JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_hangupCall(JNIEnv *env, jclass cls, jint callId) {
    pjsua_call_hangup((pjsua_call_id)callId, 0, NULL, NULL);
}

JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_setHold(JNIEnv *env, jclass cls, jint callId) {
    pjsua_call_set_hold((pjsua_call_id)callId, NULL);
}

JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_reinvite(JNIEnv *env, jclass cls, jint callId) {
    pjsua_call_reinvite((pjsua_call_id)callId, PJ_TRUE, NULL);
}

JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_adjustTxLevel(JNIEnv *env, jclass cls,
    jint callId, jfloat level) {
    pjsua_call_info ci;
    if (pjsua_call_get_info((pjsua_call_id)callId, &ci) == PJ_SUCCESS) {
        pjsua_conf_adjust_tx_level(ci.conf_slot, level);
    }
}

JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_dialDtmf(JNIEnv *env, jclass cls,
    jint callId, jstring jdigits) {
    const char *digits = (*env)->GetStringUTFChars(env, jdigits, NULL);
    pj_str_t pj_digits = pj_str((char*)digits);
    pjsua_call_dial_dtmf((pjsua_call_id)callId, &pj_digits);
    (*env)->ReleaseStringUTFChars(env, jdigits, digits);
}

JNIEXPORT void JNICALL
Java_com_redyrect_pjsip_PjsipNative_transferCall(JNIEnv *env, jclass cls,
    jint callId, jstring jtarget) {
    const char *target = (*env)->GetStringUTFChars(env, jtarget, NULL);
    pj_str_t pj_target = pj_str((char*)target);
    pjsua_call_xfer((pjsua_call_id)callId, &pj_target, NULL);
    (*env)->ReleaseStringUTFChars(env, jtarget, target);
}
