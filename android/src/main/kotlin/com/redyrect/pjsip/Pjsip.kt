package com.redyrect.pjsip

import android.util.Log

class Pjsip {

    fun echo(value: String?): String? {
        Log.i("Echo", value ?: "null")

        return value
    }
}
