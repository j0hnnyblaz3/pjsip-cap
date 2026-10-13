package com.redyrect.pjsip

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallLedgerTest {

    @Test
    fun aCallThatEndedIsFinishedAndStaysSilent() {
        val sent = mutableListOf<Map<String, Any?>>()
        val ledger = CallLedger { sent += it }

        ledger.open("call-1", incoming = true, state = "incoming")
        ledger.finish("call-1", 200, "OK")
        val count = sent.size

        assertTrue(ledger.isFinished("call-1"))
        // A late push or INVITE for the same call opens nothing.
        ledger.open("call-1", incoming = true, state = "incoming")
        assertFalse(ledger.has("call-1"))
        assertEquals(count, sent.size)
    }

    @Test
    fun aPushedCallThatNeverRangIsFinishedWithoutBeingSent() {
        val sent = mutableListOf<Map<String, Any?>>()
        val ledger = CallLedger { sent += it }

        ledger.endUnopened("pushed-1")

        assertTrue(ledger.isFinished("pushed-1"))
        assertTrue(sent.isEmpty())
        ledger.open("pushed-1", incoming = true, state = "incoming")
        assertFalse(ledger.has("pushed-1"))
    }

    @Test
    fun endUnopenedLeavesALiveCallAlone() {
        val ledger = CallLedger { }

        ledger.open("call-2", incoming = true, state = "confirmed")
        ledger.endUnopened("call-2")

        assertFalse(ledger.isFinished("call-2"))
        assertTrue(ledger.has("call-2"))
    }
}
