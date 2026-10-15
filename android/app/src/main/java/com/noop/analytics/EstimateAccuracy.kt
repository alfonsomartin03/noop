package com.noop.analytics

import kotlin.math.abs

/**
 * EstimateAccuracy.kt — how close NOOP's own estimate is to the score WHOOP reported.
 * Kotlin port of StrandAnalytics/EstimateAccuracy.swift. Descriptive comparison on the user's own
 * data only; not a validation claim.
 */
object EstimateAccuracy {
    /** Version tag of the on-device estimate formulas. Keep in step with Swift. */
    const val MODEL_VERSION = "noop-est-1"

    /** Below this many shared days the comparison is not shown (cold start). */
    const val MIN_DAYS = 7

    data class Result(val days: Int, val meanAbsError: Double, val bias: Double) {
        val isReliable: Boolean get() = days >= MIN_DAYS
    }

    /** Compare day-keyed official values with day-keyed estimates. Null when no day overlaps. */
    fun compare(official: Map<String, Double>, estimate: Map<String, Double>): Result? {
        val diffs = official.mapNotNull { (day, o) -> estimate[day]?.let { it - o } }
        if (diffs.isEmpty()) return null
        val n = diffs.size.toDouble()
        return Result(diffs.size, diffs.sumOf { abs(it) } / n, diffs.sum() / n)
    }
}
