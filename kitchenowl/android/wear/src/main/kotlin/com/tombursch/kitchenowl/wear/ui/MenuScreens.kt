package com.tombursch.kitchenowl.wear.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import com.tombursch.kitchenowl.wear.R
import com.tombursch.kitchenowl.wear.data.DayMenu
import com.tombursch.kitchenowl.wear.data.MealKind
import com.tombursch.kitchenowl.wear.data.PhoneMenu
import com.tombursch.kitchenowl.wear.data.currentMeal
import com.tombursch.kitchenowl.wear.data.day
import com.tombursch.kitchenowl.wear.data.daysFrom
import com.tombursch.kitchenowl.wear.data.relativeDay
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.TextStyle
import java.util.Locale

private val Amber = Color(0xFFFFB74D)
private val Green = Color(0xFF6FD08C)
private val Blue = Color(0xFF9DB8FF)
private val Muted = Color(0xFFA8A8B0)

/** Where the user is in the menu: the week (null day) or one day (`yyyy-MM-dd`). */
data class MenuNav(val day: String?)

/** The menu screens: the week, and one day with its meals. Read only; the shopping list is the other screen. */
@Composable
internal fun MenuScreen(viewModel: ShoppingViewModel, menu: PhoneMenu?, nav: MenuNav) {
    val today = LocalDate.now()
    val day = nav.day?.let { runCatching { LocalDate.parse(it) }.getOrNull() }?.let { menu?.day(it) }
    if (menu != null && day != null) {
        DayScreen(viewModel, day, today)
    } else {
        WeekScreen(viewModel, menu, today)
    }
}

/** M4: today, tomorrow and the days after, with a dot per planned meal. */
@Composable
private fun WeekScreen(viewModel: ShoppingViewModel, menu: PhoneMenu?, today: LocalDate) {
    val days = menu?.daysFrom(today).orEmpty()
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(
            state = listState,
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding()),
            verticalArrangement = Arrangement.spacedBy(1.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "back") {
                Bar(Color(0xFF26262B), SmallBarHeight, onClick = { viewModel.closeMenu() }) {
                    Text("‹", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                    Text(
                        stringResource(R.string.menu_title).uppercase(),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.sp,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            if (menu == null) {
                item(key = "empty") {
                    Column(
                        horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
                    ) {
                        Text(stringResource(R.string.menu_empty_title), fontSize = 16.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                        Text(
                            stringResource(R.string.menu_empty_body),
                            style = MaterialTheme.typography.bodySmall,
                            color = Muted,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
            items(days, key = { "day-${it.date}" }) { day ->
                val isToday = day.date == today
                Bar(
                    if (isToday) Color(0xFF14301F) else Color(0xFF1C1C20),
                    BarHeight,
                    onClick = { viewModel.openMenu(day.date.toString()) },
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(dayLabel(day.date, today), fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                        Text(
                            day.summary.ifEmpty { stringResource(R.string.menu_nothing) },
                            fontSize = 11.sp,
                            color = if (isToday) Color(0xFFC8E8D4) else Muted,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    MealDots(day)
                }
            }
        }
    }
}

/** M1: the meals of one day, the one that is on now marked. */
@Composable
private fun DayScreen(viewModel: ShoppingViewModel, day: DayMenu, today: LocalDate) {
    val listState = rememberScalingLazyListState()
    val now = if (day.date == today) currentMeal(LocalTime.now()) else null
    val meals = MealKind.entries.filter { it != MealKind.OTHER || day.dishes(it).isNotEmpty() }
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(
            state = listState,
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding()),
            verticalArrangement = Arrangement.spacedBy(1.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "back") {
                Bar(Color(0xFF26262B), SmallBarHeight, onClick = { viewModel.openMenu(null) }) {
                    Text("‹", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                    Text(
                        dayLabel(day.date, today).uppercase(),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            items(meals, key = { "meal-$it" }) { meal ->
                MealBlock(meal, day.dishes(meal), isNow = meal == now)
            }
        }
    }
}

@Composable
private fun MealBlock(meal: MealKind, dishes: List<String>, isNow: Boolean) {
    val (background, accent) = mealColors(meal)
    Column(
        verticalArrangement = Arrangement.Center,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = BarHeight)
            .background(background)
            .padding(start = 34.dp, end = 30.dp, top = 8.dp, bottom = 8.dp),
    ) {
        Text(
            mealName(meal).uppercase() + if (isNow) " · " + stringResource(R.string.now_suffix).uppercase() else "",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 1.sp,
            color = accent,
        )
        if (dishes.isEmpty()) {
            Text(stringResource(R.string.menu_nothing), fontSize = 14.sp, color = Muted)
        } else {
            for (dish in dishes) {
                Text(dish, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Breakfast, lunch and dinner: a filled dot when something is planned for it. */
@Composable
private fun MealDots(day: DayMenu) {
    androidx.compose.foundation.layout.Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        for (meal in listOf(MealKind.BREAKFAST, MealKind.LUNCH, MealKind.DINNER)) {
            val planned = day.dishes(meal).isNotEmpty()
            val color = mealColors(meal).second
            Box(
                Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(if (planned) color else Color(0xFF3A3A42)),
            )
        }
    }
}

/** Background and accent of a meal (the same family as the phone's planner). */
private fun mealColors(meal: MealKind): Pair<Color, Color> = when (meal) {
    MealKind.BREAKFAST -> Color(0xFF3A2A10) to Amber
    MealKind.LUNCH -> Color(0xFF14301F) to Green
    MealKind.DINNER -> Color(0xFF24345C) to Blue
    MealKind.OTHER -> Color(0xFF26262B) to Muted
}

@Composable
private fun mealName(meal: MealKind): String = stringResource(
    when (meal) {
        MealKind.BREAKFAST -> R.string.meal_breakfast
        MealKind.LUNCH -> R.string.meal_lunch
        MealKind.DINNER -> R.string.meal_dinner
        MealKind.OTHER -> R.string.meal_other
    },
)

/** "Hoy", "Mañana", or "sáb 21". */
@Composable
private fun dayLabel(date: LocalDate, today: LocalDate): String = when (relativeDay(date, today)) {
    0 -> stringResource(R.string.day_today)
    1 -> stringResource(R.string.day_tomorrow)
    else -> date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault()) + " " + date.dayOfMonth
}
