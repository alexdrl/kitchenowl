package com.tombursch.kitchenowl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone

class MenuCalendarTest {
    private val madrid = TimeZone.getTimeZone("Europe/Madrid")
    private val labels = mapOf("breakfast" to "Desayuno", "lunch" to "Comida", "dinner" to "Cena")

    private fun events(days: Map<String, Map<String, List<String>>>) =
        MenuCalendar.events(1, days, labels, madrid)

    @Test
    fun timedMealsAreLocalTimesAndAnyIsAllDay() {
        val result = events(
            mapOf(
                "2026-11-19" to mapOf(
                    "dinner" to listOf("Pollo", " Sobras "),
                    "lunch" to listOf("Paella"),
                    "any" to listOf("Fruta"),
                ),
            ),
        )
        assertEquals(listOf("1/2026-11-19/lunch", "1/2026-11-19/dinner", "1/2026-11-19/any"), result.map { it.key })

        val lunch = result[0]
        assertEquals("Comida: Paella", lunch.title)
        // 14:00 in Madrid (UTC+1 in November) = 13:00 UTC
        assertEquals(1_795_093_200_000L, lunch.start)
        assertEquals(lunch.start + 3_600_000L, lunch.end)
        assertEquals("Europe/Madrid", lunch.timeZone)

        assertEquals("Cena: Pollo · Sobras", result[1].title)

        val any = result[2]
        assertTrue(any.allDay)
        assertEquals("Fruta", any.title)
        assertEquals(1_795_046_400_000L, any.start) // 2026-11-19T00:00Z
        assertEquals("UTC", any.timeZone)
    }

    @Test
    fun summerTimeIsHonoured() {
        val lunch = events(mapOf("2026-07-01" to mapOf("lunch" to listOf("Gazpacho")))).single()
        // 14:00 in Madrid (UTC+2 in July) = 12:00 UTC
        assertEquals(1_782_907_200_000L, lunch.start)
    }

    @Test
    fun emptyNamesAndBadDaysAreSkipped() {
        val result = events(
            mapOf(
                "2026-11-19" to mapOf("lunch" to listOf("  ")),
                "not-a-day" to mapOf("lunch" to listOf("X")),
            ),
        )
        assertTrue(result.isEmpty())
    }

    private fun existing(id: Long, event: MenuEvent) =
        ExistingEvent(id, event.key, event.title, event.start, event.end, event.allDay)

    @Test
    fun reconcileInsertsUpdatesAndDeletesInsideTheWindowOnly() {
        val old = events(
            mapOf(
                "2026-11-10" to mapOf("lunch" to listOf("Lentejas")), // last week: kept
                "2026-11-19" to mapOf("lunch" to listOf("Paella"), "dinner" to listOf("Pizza")),
            ),
        )
        val desired = events(
            mapOf(
                "2026-11-19" to mapOf("lunch" to listOf("Paella"), "any" to listOf("Fruta")),
                "2026-11-20" to mapOf("dinner" to listOf("Tortilla")),
            ),
        )
        val renamed = desired.first { it.key.endsWith("lunch") }.copy(title = "Comida: Arroz")
        val current = listOf(
            existing(1, old[0]), // 2026-11-10 lunch, outside the window
            existing(2, renamed.copy(title = "Comida: Paella (old)")),
            existing(3, old.first { it.key.endsWith("dinner") }), // no longer planned
            ExistingEvent(4, null, "stray", 0, 0, false),
        )
        val changes = MenuCalendar.reconcile(
            desired.map { if (it.key == renamed.key) renamed else it },
            current,
            window = setOf("2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20"),
        )
        assertEquals(listOf("1/2026-11-19/any", "1/2026-11-20/dinner"), changes.inserts.map { it.key })
        assertEquals(listOf(2L), changes.updates.map { it.first })
        assertEquals(setOf(3L, 4L), changes.deletes.toSet())
    }

    @Test
    fun reconcileIsEmptyWhenNothingChanged() {
        val desired = events(mapOf("2026-11-19" to mapOf("lunch" to listOf("Paella"))))
        val changes = MenuCalendar.reconcile(
            desired,
            desired.mapIndexed { i, e -> existing(i.toLong(), e) },
            setOf("2026-11-19"),
        )
        assertTrue(changes.isEmpty)
    }

    @Test
    fun duplicateKeysAreCollapsed() {
        val event = events(mapOf("2026-11-19" to mapOf("lunch" to listOf("Paella")))).single()
        val changes = MenuCalendar.reconcile(
            listOf(event),
            listOf(existing(1, event), existing(2, event)),
            setOf("2026-11-19"),
        )
        assertTrue(changes.inserts.isEmpty())
        assertTrue(changes.updates.isEmpty())
        assertEquals(listOf(2L), changes.deletes)
    }

    @Test
    fun otherHouseholdsEventsInTheWindowGo() {
        val mine = events(mapOf("2026-11-19" to mapOf("lunch" to listOf("Paella")))).single()
        val other = mine.copy(key = "2/2026-11-19/lunch")
        val changes = MenuCalendar.reconcile(
            listOf(mine),
            listOf(existing(1, mine), existing(2, other)),
            setOf("2026-11-19"),
        )
        assertEquals(listOf(2L), changes.deletes)
    }
}
