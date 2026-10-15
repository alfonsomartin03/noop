package com.noop.analytics

import kotlin.math.max

/**
 * SleepNeed.kt — how much sleep a night asked for, and how far short it fell.
 * Kotlin port of StrandAnalytics/SleepNeed.swift. Prefers WHOOP-reported need/debt from the
 * export; otherwise a simple estimate (larger of 7.5 h and recent average sleep) whose "debt" is
 * only that night's shortfall, not WHOOP's accumulated debt.
 */
object SleepNeed {
    /** Floor for the estimated need, minutes (7.5 h). */
    const val FLOOR_MIN = 450.0

    data class Summary(
        val needMin: Double,
        val asleepMin: Double,
        /** Official: WHOOP's reported debt. Estimate: this night's shortfall vs need. */
        val debtMin: Double,
        /** True when need (and debt, if present) came from the WHOOP export. */
        val isOfficial: Boolean,
    )

    fun summarize(
        officialNeed: Double?,
        officialDebt: Double?,
        asleep: Double?,
        recentAsleep: List<Double>,
    ): Summary? {
        if (asleep == null || asleep <= 0) return null
        if (officialNeed != null && officialNeed > 0) {
            return Summary(officialNeed, asleep, officialDebt ?: max(0.0, officialNeed - asleep), true)
        }
        val valid = recentAsleep.filter { it > 0 }
        val typical = if (valid.isEmpty()) 0.0 else valid.sum() / valid.size
        val need = max(FLOOR_MIN, typical)
        return Summary(need, asleep, max(0.0, need - asleep), false)
    }
}
