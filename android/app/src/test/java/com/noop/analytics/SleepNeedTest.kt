package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SleepNeedTest {
    @Test fun officialValuesWin() {
        val s = SleepNeed.summarize(500.0, 75.0, 420.0, listOf(300.0))!!
        assertTrue(s.isOfficial); assertEquals(500.0, s.needMin, 0.0); assertEquals(75.0, s.debtMin, 0.0)
    }

    @Test fun officialNeedWithoutDebtDerivesShortfall() {
        assertEquals(80.0, SleepNeed.summarize(480.0, null, 400.0, emptyList())!!.debtMin, 0.0)
    }

    @Test fun estimateUsesFloorAndRecentMean() {
        val low = SleepNeed.summarize(null, null, 400.0, listOf(360.0, 380.0))!!
        assertFalse(low.isOfficial); assertEquals(450.0, low.needMin, 0.0); assertEquals(50.0, low.debtMin, 0.0)
        val high = SleepNeed.summarize(null, null, 500.0, listOf(480.0, 520.0))!!
        assertEquals(500.0, high.needMin, 0.0); assertEquals(0.0, high.debtMin, 0.0)
    }

    @Test fun noSleepNoSummary() {
        assertNull(SleepNeed.summarize(480.0, 10.0, null, emptyList()))
    }
}
