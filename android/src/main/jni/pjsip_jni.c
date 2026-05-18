/**
 * JNI bridge for pjsua C API.
 * Maps Kotlin PjsipNative external functions to pjsua calls.
 */
#include <jni.h>
#include <string.h>
#include <pjsua-lib/pjsua.h>
#include <android/log.h>

#define TAG "PjsipJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* Global references for callback dispatch */
static JavaVM *g_vm = NULL;
static jobject g_callback = NULL;
static pjsua_acc_id g_acc_id = PJSUA_INVALID_ID;
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
    /* Auto-ring 180 */
    pjsua_call_answer(call_id, 180, NULL, NULL);

    pjsua_call_info ci;
    pjsua_call_get_info(call_id, &ci);

    char remote_info[256];
    snprintf(remote_info, sizeof(remote_info), "%.*s",
             (int)ci.remote_info.slen, ci.remote_info.ptr);

    int need_detach;
    JNIEnv *env = get_env(&need_detach);
    if (!env) return;

    jstring jremote = (*env)->NewStringUTF(env, remote_info);

    jclass cls = (*env)->GetObjectClass(env, g_callback);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onIncomingCall",
        "(ILjava/lang/String;)V");
    if (mid) {
        (*env)->CallVoidMethod(env, g_callback, mid, (jint)call_id, jremote);
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, jremote);
    release_env(need_detach);
}

static void on_call_state(pjsua_call_id call_id, pjsip_event *e) {
    pjsua_call_info ci;
    pjsua_call_get_info(call_id, &ci);

    const char *state;
    switch (ci.state) {
        case PJSIP_INV_STATE_NULL:          state = "null"; break;
        case PJSIP_INV_STATE_CALLING:       state = "calling"; break;
        case PJSIP_INV_STATE_INCOMING:      state = "incoming"; break;
        case PJSIP_INV_STATE_EARLY:         state = "early"; break;
        case PJSIP_INV_STATE_CONNECTING:    state = "connecting"; break;
        case PJSIP_INV_STATE_CONFIRMED:     state = "confirmed"; break;
        case PJSIP_INV_STATE_DISCONNECTED:  state = "disconnected"; break;
        default:                            state = "unknown"; break;
    }

    char remote_info[256];
    snprintf(remote_info, sizeof(remote_info), "%.*s",
             (int)ci.remote_info.slen, ci.remote_info.ptr);

    int need_detach;
    JNIEnv *env = get_env(&need_detach);
    if (!env) return;

    jstring jstate = (*env)->NewStringUTF(env, state);
    jstring jremote = (*env)->NewStringUTF(env, remote_info);

    jclass cls = (*env)->GetObjectClass(env, g_callback);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onCallState",
        "(ILjava/lang/String;Ljava/lang/String;)V");
    if (mid) {
        (*env)->CallVoidMethod(env, g_callback, mid, (jint)call_id, jstate, jremote);
    }
    (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, jstate);
    (*env)->DeleteLocalRef(env, jremote);
    release_env(need_detach);
}

static void on_call_media_state(pjsua_call_id call_id) {
    pjsua_call_info ci;
    pjsua_call_get_info(call_id, &ci);

    if (ci.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        pjsua_conf_connect(ci.conf_slot, 0);
        pjsua_conf_connect(0, ci.conf_slot);
    }
}

/* ---- JNI Methods ---- */

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    g_vm = vm;
    return JNI_VERSION_1_6;
}

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

    pjsua_logging_config log_cfg;
    pjsua_logging_config_default(&log_cfg);
    log_cfg.level = 4;
    log_cfg.console_level = 4;

    pjsua_media_config media_cfg;
    pjsua_media_config_default(&media_cfg);

    status = pjsua_init(&cfg, &log_cfg, &media_cfg);
    if (status != PJ_SUCCESS) {
        LOGE("pjsua_init failed: %d", status);
        pjsua_destroy();
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

    pjsua_transport_id tid;
    pj_status_t status = pjsua_transport_create(tp, &tcfg, &tid);
    if (status != PJ_SUCCESS) {
        LOGE("pjsua_transport_create failed: %d", status);
    }
    return status;
}

JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_start(JNIEnv *env, jclass cls) {
    pj_status_t status = pjsua_start();
    if (status != PJ_SUCCESS) {
        LOGE("pjsua_start failed: %d", status);
        pjsua_destroy();
        g_started = 0;
    }
    return status;
}

JNIEXPORT jint JNICALL
Java_com_redyrect_pjsip_PjsipNative_addAccount(JNIEnv *env, jclass cls,
    jstring jsipUri, jstring jregUri, jstring jrealm,
    jstring jusername, jstring jpassword, jstring jproxy) {

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

    acc_cfg.reg_retry_interval = 300;
    acc_cfg.reg_first_retry_interval = 30;

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
    if (g_acc_id == PJSUA_INVALID_ID) return -1;

    const char *uri = (*env)->GetStringUTFChars(env, juri, NULL);
    pj_str_t pj_uri = pj_str((char*)uri);
    pjsua_call_id call_id;

    pj_status_t status = pjsua_call_make_call(g_acc_id, &pj_uri, NULL, NULL, NULL, &call_id);
    (*env)->ReleaseStringUTFChars(env, juri, uri);

    if (status != PJ_SUCCESS) {
        LOGE("pjsua_call_make_call failed: %d", status);
        return -1;
    }
    return call_id;
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
