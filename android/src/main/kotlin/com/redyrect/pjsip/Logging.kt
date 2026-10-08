package com.redyrect.pjsip

import android.util.Log

/** The plugin's one way to log. Same logcat tag as PJSIP's own lines (the
 *  JNI log writer), so one `adb logcat -s Pjsip` shows a whole call. */
internal fun pjsipLog(message: String) {
    Log.i("Pjsip", message)
}
