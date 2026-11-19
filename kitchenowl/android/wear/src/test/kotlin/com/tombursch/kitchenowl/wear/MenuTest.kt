package com.tombursch.kitchenowl.wear

import com.tombursch.kitchenowl.wear.data.MealKind
import com.tombursch.kitchenowl.wear.data.MenuRepository
import com.tombursch.kitchenowl.wear.data.MenuStorage
import com.tombursch.kitchenowl.wear.data.PhoneMenu
import com.tombursch.kitchenowl.wear.data.currentMeal
import com.tombursch.kitchenowl.wear.data.day
import com.tombursch.kitchenowl.wear.data.daysFrom
import com.tombursch.kitchenowl.wear.data.parseMenu
import com.tombursch.kitchenowl.wear.data.relativeDay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalTime

class MenuTest {
    // Exactly what lib/models/wear_menu.dart produces (plus a field from a newer phone app).
    private val json = """
        {"version":1,"household_id":9,"updated_ms":1700000000000,"future":true,
         "days":{
           "2026-11-18":{"lunch":["Ayer"]},
           "2026-11-19":{"breakfast":["Tostadas"],"lunch":["Lentejas","Ensalada"],"dinner":["Tortilla"]},
           "2026-11-20":{"lunch":["Paella"],"any":["Picnic"]},
           "2026-11-21":{}
         }}
    """.trimIndent()

    private val menu = parseMenu(json.toByteArray())!!
    private val today = LocalDate.of(2026, 11, 19)

    @Test
    fun parsesThePhonesMenu() {
        assertEquals(9L, menu.householdId)
        assertEquals(1700000000000, menu.updatedMs)
        assertEquals(4, menu.days.size)
        assertEquals(listOf("Lentejas", "Ensalada"), menu.days["2026-11-19"]!!["lunch"])
    }

    @Test
    fun garbageIsNotAMenu() {
        assertNull(parseMenu("nope".toByteArray()))
        assertNull(parseMenu(ByteArray(0)))
        assertNull(parseMenu("""{"days": 3}""".toByteArray()))
    }

    @Test
    fun aDayGivesItsMealsInOrder() {
        val d = menu.day(today)!!
        assertEquals(listOf("Tostadas"), d.dishes(MealKind.BREAKFAST))
        assertEquals(listOf("Lentejas", "Ensalada"), d.dishes(MealKind.LUNCH))
        assertEquals(listOf("Tortilla"), d.dishes(MealKind.DINNER))
        assertEquals(emptyList<String>(), d.dishes(MealKind.OTHER))
        assertEquals("Tostadas, Lentejas, Ensalada, Tortilla", d.summary)
        assertFalse(d.isEmpty)
    }

    @Test
    fun nothingPlannedIsNotTheSameAsNoData() {
        // the phone covered 21 November and had nothing: an empty day
        val empty = menu.day(LocalDate.of(2026, 11, 21))!!
        assertTrue(empty.isEmpty)
        assertEquals("", empty.summary)
        // it did not cover this one at all
        assertNull(menu.day(LocalDate.of(2026, 12, 25)))
    }

    @Test
    fun theWeekStartsToday() {
        val days = menu.daysFrom(today)
        assertEquals(listOf("2026-11-19", "2026-11-20", "2026-11-21"), days.map { it.date.toString() })
    }

    @Test
    fun theMealThatIsOnNow() {
        assertEquals(MealKind.BREAKFAST, currentMeal(LocalTime.of(8, 0)))
        assertEquals(MealKind.BREAKFAST, currentMeal(LocalTime.of(10, 59)))
        assertEquals(MealKind.LUNCH, currentMeal(LocalTime.of(11, 0)))
        assertEquals(MealKind.LUNCH, currentMeal(LocalTime.of(15, 59)))
        assertEquals(MealKind.DINNER, currentMeal(LocalTime.of(16, 0)))
        assertEquals(MealKind.DINNER, currentMeal(LocalTime.of(23, 30)))
    }

    @Test
    fun todayAndTomorrowAreNamedTheRestAreNot() {
        assertEquals(0, relativeDay(today, today))
        assertEquals(1, relativeDay(today.plusDays(1), today))
        assertNull(relativeDay(today.plusDays(2), today))
        assertNull(relativeDay(today.minusDays(1), today))
    }

    @Test
    fun theMenuSurvivesARestartAndOlderOnesAreIgnored() {
        var stored: PhoneMenu? = null
        val storage = object : MenuStorage {
            override fun loadMenu() = stored
            override fun saveMenu(menu: PhoneMenu) {
                stored = menu
            }
        }
        val repo = MenuRepository(storage)
        assertNull(repo.state.value)

        repo.onMenu(menu)
        assertEquals(menu, repo.state.value)
        assertEquals(menu, MenuRepository(storage).state.value) // restart

        repo.onMenu(menu.copy(updatedMs = 5, days = emptyMap())) // a stale delivery
        assertEquals(menu, repo.state.value)

        val newer = menu.copy(updatedMs = menu.updatedMs + 1, days = mapOf("2026-11-19" to mapOf("lunch" to listOf("Paella"))))
        repo.onMenu(newer)
        assertEquals(newer, repo.state.value)
    }
}
