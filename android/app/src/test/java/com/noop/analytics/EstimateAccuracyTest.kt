package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class EstimateAccuracyTest {
    @Test fun onlyOverlappingDaysCompared() {
        val r = EstimateAccuracy.compare(
            mapOf("d1" to 60.0, "d2" to 80.0, "d3" to 50.0),
            mapOf("d1" to 66.0, "d2" to 74.0, "d9" to 10.0),
        )!!
        assertEquals(2, r.days)
        assertEquals(6.0, r.meanAbsError, 1e-9)
        assertEquals(0.0, r.bias, 1e-9)
    }

    @Test fun noOverlapIsNull() {
        assertNull(EstimateAccuracy.compare(mapOf("a" to 1.0), mapOf("b" to 2.0)))
    }

    @Test fun reliabilityThreshold() {
        val o = (0 until 6).associate { "d$it" to 50.0 }
        assertFalse(EstimateAccuracy.compare(o, o)!!.isReliable)
    }
}
