package com.tombursch.kitchenowl

import java.util.Calendar
import java.util.TimeZone

/** An event the KitchenOwl calendar should hold: one per day and meal. */
data class MenuEvent(
    /** `<household>/<yyyy-MM-dd>/<meal>`, stored in the event's `_SYNC_ID`. */
    val key: String,
    val title: String,
    val start: Long,
    val end: Long,
    val allDay: Boolean,
    val timeZone: String,
)

/** An event already in the calendar, as the sync adapter read it. */
data class ExistingEvent(
    val id: Long,
    val key: String?,
    val title: String?,
    val start: Long,
    val end: Long,
    val allDay: Boolean,
)

data class CalendarChanges(
    val inserts: List<MenuEvent>,
    val updates: List<Pair<Long, MenuEvent>>,
    val deletes: List<Long>,
) {
    val isEmpty get() = inserts.isEmpty() && updates.isEmpty() && deletes.isEmpty()
}

/**
 * Turns the menu the app stored for the widget (`lib/services/menu_widget.dart`) into calendar
 * events, and works out what to change in the calendar. No Android calls: unit tested.
 */
object MenuCalendar {
    /** Start time and length of the timed meals. "any" becomes an all-day event. */
    private val TIMED = mapOf(
        "breakfast" to Triple(8, 30, 30),
        "lunch" to Triple(14, 0, 60),
        "dinner" to Triple(21, 0, 60),
    )
    private val MEAL_ORDER = listOf("breakfast", "lunch", "dinner", "any")

    /**
     * [days]: `yyyy-MM-dd` → meal → names, as in the widget JSON. [labels]: meal → "Lunch" etc.
     * Timed meals are local times in [zone]; all-day events are UTC midnights, as the calendar
     * provider requires.
     */
    fun events(
        householdId: Int,
        days: Map<String, Map<String, List<String>>>,
        labels: Map<String, String>,
        zone: TimeZone,
    ): List<MenuEvent> {
        val result = mutableListOf<MenuEvent>()
        for ((day, meals) in days.toSortedMap()) {
            val (year, month, dayOfMonth) = parseDay(day) ?: continue
            for (meal in MEAL_ORDER) {
                val names = meals[meal]?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
                if (names.isEmpty()) continue
                val joined = names.joinToString(" · ")
                val key = "$householdId/$day/$meal"
                val timed = TIMED[meal]
                if (timed != null) {
                    val start = Calendar.getInstance(zone).apply {
                        clear()
                        set(year, month - 1, dayOfMonth, timed.first, timed.second, 0)
                    }.timeInMillis
                    result += MenuEvent(
                        key = key,
                        title = labels[meal]?.let { "$it: $joined" } ?: joined,
                        start = start,
                        end = start + timed.third * 60_000L,
                        allDay = false,
                        timeZone = zone.id,
                    )
                } else {
                    val start = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
                        clear()
                        set(year, month - 1, dayOfMonth, 0, 0, 0)
                    }.timeInMillis
                    result += MenuEvent(
                        key = key,
                        title = joined,
                        start = start,
                        end = start + 24 * 3_600_000L,
                        allDay = true,
                        timeZone = "UTC",
                    )
                }
            }
        }
        return result
    }

    /**
     * What to do so the calendar holds exactly [desired] for the days in [window] (the days the
     * menu JSON covers). Events of other days are left alone, so past weeks stay in the calendar.
     */
    fun reconcile(
        desired: List<MenuEvent>,
        existing: List<ExistingEvent>,
        window: Set<String>,
    ): CalendarChanges {
        val byKey = existing.filter { it.key != null }.groupBy { it.key!! }
        val inserts = mutableListOf<MenuEvent>()
        val updates = mutableListOf<Pair<Long, MenuEvent>>()
        val deletes = mutableListOf<Long>()

        // Rows without a key are not ours to keep (the calendar is read-only for the user)
        existing.filter { it.key == null }.forEach { deletes += it.id }

        val wanted = desired.associateBy { it.key }
        for (event in desired) {
            val matches = byKey[event.key]
            if (matches.isNullOrEmpty()) {
                inserts += event
                continue
            }
            val first = matches.first()
            if (first.title != event.title || first.start != event.start ||
                first.end != event.end || first.allDay != event.allDay
            ) {
                updates += first.id to event
            }
            matches.drop(1).forEach { deletes += it.id }
        }
        for ((key, matches) in byKey) {
            if (key in wanted) continue
            if (dayOf(key) in window) matches.forEach { deletes += it.id }
        }
        return CalendarChanges(inserts, updates, deletes)
    }

    /** The day part of an event key, or null. */
    fun dayOf(key: String): String? = key.split('/').getOrNull(1)

    private fun parseDay(day: String): Triple<Int, Int, Int>? {
        val parts = day.split('-')
        if (parts.size != 3) return null
        val (y, m, d) = parts.map { it.toIntOrNull() ?: return null }
        return Triple(y, m, d)
    }
}
