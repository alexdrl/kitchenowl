package com.tombursch.kitchenowl.wear.data

import java.time.LocalDate
import java.time.LocalTime

enum class MealKind(val key: String) { BREAKFAST("breakfast"), LUNCH("lunch"), DINNER("dinner"), OTHER("any") }

/** One day of the menu. */
data class DayMenu(val date: LocalDate, val meals: Map<MealKind, List<String>>) {
    fun dishes(meal: MealKind): List<String> = meals[meal].orEmpty()

    val isEmpty: Boolean get() = meals.values.all { it.isEmpty() }

    /** All dishes of the day in meal order, for a one-line summary. */
    val summary: String get() = MealKind.entries.flatMap { dishes(it) }.joinToString(", ")
}

/** The day, or null when the phone's menu does not cover it (not the same as "nothing planned"). */
fun PhoneMenu.day(date: LocalDate): DayMenu? {
    val day = days[date.toString()] ?: return null
    return DayMenu(date, MealKind.entries.associateWith { day[it.key].orEmpty() })
}

/** [today] and every later day the menu covers, in order. */
fun PhoneMenu.daysFrom(today: LocalDate): List<DayMenu> = days.keys
    .mapNotNull { runCatching { LocalDate.parse(it) }.getOrNull() }
    .filter { !it.isBefore(today) }
    .sorted()
    .mapNotNull { day(it) }

/** The meal that is "now": breakfast until 11, lunch until 16 (the app's own cut), then dinner. */
fun currentMeal(time: LocalTime): MealKind = when {
    time.hour < 11 -> MealKind.BREAKFAST
    time.hour < 16 -> MealKind.LUNCH
    else -> MealKind.DINNER
}

/** 0 for today, 1 for tomorrow, null for any other day. */
fun relativeDay(date: LocalDate, today: LocalDate): Int? = when (date) {
    today -> 0
    today.plusDays(1) -> 1
    else -> null
}
