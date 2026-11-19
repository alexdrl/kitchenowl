package com.tombursch.kitchenowl.wear.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import com.tombursch.kitchenowl.wear.R
import com.tombursch.kitchenowl.wear.data.CategoryStyle
import com.tombursch.kitchenowl.wear.data.DisplayItem
import com.tombursch.kitchenowl.wear.data.ItemGroup
import com.tombursch.kitchenowl.wear.data.ListRef
import com.tombursch.kitchenowl.wear.data.WatchItem
import com.tombursch.kitchenowl.wear.data.WatchState
import com.tombursch.kitchenowl.wear.data.categoryStyle
import com.tombursch.kitchenowl.wear.data.groupByCategory
import com.tombursch.kitchenowl.wear.data.nextGroup

/** Older than this, the screen says how old the phone's list is. */
const val STALE_AFTER_MILLIS = 60 * 60 * 1000L

/** The app's item icon font (the phone sends each item's code point). */
private val ItemsFont = FontFamily(Font(R.font.items))

internal val BarHeight = 56.dp
internal val SmallBarHeight = 48.dp

private fun CategoryStyle.bg() = Color(background)
private fun CategoryStyle.fg() = Color(accent)
private fun CategoryStyle.soft() = Color(muted)

@Composable
fun WearRoot(viewModel: ShoppingViewModel) {
    // MaterialTheme of Wear Compose Material 3 is dark by default, which is what Wear OS expects.
    MaterialTheme {
        AppScaffold {
            val state by viewModel.state.collectAsState()
            var picking by remember { mutableStateOf(false) }
            val open by viewModel.open.collectAsState()
            val menu by viewModel.menu.collectAsState()
            val menuNav by viewModel.menuNav.collectAsState()

            BackHandler(enabled = picking || open != null || menuNav != null) {
                val nav = menuNav
                when {
                    picking -> picking = false
                    nav != null -> if (nav.day != null) viewModel.openMenu(null) else viewModel.closeMenu()
                    else -> viewModel.closeCategory()
                }
            }

            when {
                menuNav != null -> MenuScreen(viewModel, menu, menuNav!!)
                state.snapshot == null -> NoSnapshotScreen()
                picking -> ListPicker(
                    lists = state.lists,
                    selectedId = state.snapshot?.listId,
                    onPick = {
                        viewModel.selectList(it)
                        viewModel.closeCategory()
                        picking = false
                    },
                )
                open == null -> CategoriesScreen(viewModel, state, onPickList = { picking = true })
                else -> CategoryScreen(viewModel, state, open!!.name)
            }
        }
    }
}

/** The phone has not sent a list yet. */
@Composable
private fun NoSnapshotScreen() {
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text(stringResource(R.string.no_snapshot_title), textAlign = TextAlign.Center) } }
            item {
                Text(
                    stringResource(R.string.no_snapshot_body),
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                )
            }
        }
    }
}

// --- E1: the categories ---------------------------------------------------------------------

/** One bar per category, edge to edge, with how many are left. Order = the phone's category order. */
@Composable
private fun CategoriesScreen(viewModel: ShoppingViewModel, state: WatchState, onPickList: () -> Unit) {
    val refreshing by viewModel.refreshing.collectAsState()
    val menu by viewModel.menu.collectAsState()
    val groups = remember(state.items) { groupByCategory(state.items) }
    val total = state.items.size
    val ageText = ageText(state.updatedMs)

    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(
            state = listState,
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding()),
            verticalArrangement = Arrangement.spacedBy(1.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "header") {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(SmallBarHeight)
                        .clickable(enabled = state.lists.size > 1, role = Role.Button, onClick = onPickList),
                    verticalArrangement = Arrangement.Center,
                ) {
                    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("$total", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Color(0xFF20AC64))
                        Text(stringResource(R.string.to_buy), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text(
                        state.listName + if (state.lists.size > 1) "  ▾" else "",
                        fontSize = 11.sp,
                        color = Color(0xFFA8A8B0),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (state.switchingList) item(key = "switching") { StatusLine(stringResource(R.string.switching_list), warn = false) }
            if (ageText != null) item(key = "age") { StatusLine(ageText, warn = true) }
            if (state.pendingCount > 0) {
                item(key = "pending") { StatusLine(stringResource(R.string.not_confirmed, state.pendingCount), warn = false) }
            }
            if (groups.isEmpty()) {
                item(key = "empty") {
                    Text(
                        stringResource(R.string.all_bought),
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 14.dp),
                    )
                }
            }
            items(groups, key = { "cat-${it.category}" }) { group ->
                val style = categoryStyle(group.category)
                Bar(style.bg(), BarHeight, onClick = { viewModel.openCategory(group.category) }) {
                    Glyph(group.items.firstNotNullOfOrNull { it.item.icon }, group.category ?: "·", style.fg())
                    Column(Modifier.weight(1f)) {
                        Text(
                            group.category ?: stringResource(R.string.uncategorized),
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            group.items.joinToString(", ") { it.item.name },
                            fontSize = 10.sp,
                            color = style.soft(),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Text("${group.items.size}", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = style.fg())
                }
            }
            if (menu != null) {
                item(key = "menu") {
                    Bar(Color(0xFF26262B), SmallBarHeight, onClick = { viewModel.openMenu() }) {
                        Text(
                            stringResource(R.string.menu_title) + "  ›",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
            item(key = "refresh") {
                Bar(Color(0xFF26262B), SmallBarHeight, enabled = !refreshing, onClick = { viewModel.refresh() }) {
                    Text(
                        stringResource(if (refreshing) R.string.refreshing else R.string.refresh),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

// --- E2 / E3: inside a category ------------------------------------------------------------

@Composable
private fun CategoryScreen(viewModel: ShoppingViewModel, state: WatchState, category: String?) {
    val struck by viewModel.struck.collectAsState()
    val undo by viewModel.undo.collectAsState()

    // What the phone confirmed plus what was done since, and what was ticked a moment ago
    // (still drawn, struck through for 2 s).
    val groups = remember(state.items, struck) {
        val missing = struck.values
            .filter { t -> state.items.none { it.item.id == t.id } }
            .map { DisplayItem(it) }
        groupByCategory(state.items + missing)
    }
    val current = groups.firstOrNull { it.category == category }
    // The route as it was when this category was opened, so "next" is still right once it is empty.
    val order = remember(category) { groupByCategory(state.items).map { it.category } }
    val next = nextGroup(groups, category, order)

    if (current == null) {
        CategoryDoneScreen(viewModel, state, category, next, undo != null)
    } else {
        CategoryItemsScreen(viewModel, current, next, struck.keys, undo)
    }
}

@Composable
private fun CategoryItemsScreen(
    viewModel: ShoppingViewModel,
    group: ItemGroup,
    next: ItemGroup?,
    struckIds: Set<Long>,
    undo: WatchItem?,
) {
    val style = categoryStyle(group.category)
    val left = group.items.count { it.item.id !in struckIds }
    val listState = rememberScalingLazyListState()

    ScreenScaffold(scrollState = listState) { padding ->
        Box(Modifier.fillMaxSize()) {
            ScalingLazyColumn(
                state = listState,
                contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding()),
                verticalArrangement = Arrangement.spacedBy(1.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                // Back: a whole bar, not a small arrow.
                item(key = "back") {
                    Bar(Color(style.background).copy(alpha = 1f), SmallBarHeight, onClick = { viewModel.closeCategory() }) {
                        Text("‹", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = style.fg())
                        Text(
                            "${(group.category ?: stringResource(R.string.uncategorized)).uppercase()} · $left",
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 1.sp,
                            color = style.fg(),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                items(group.items, key = { "item-${it.item.id}" }) { shown ->
                    ItemBar(shown, style, struckIds.contains(shown.item.id)) { viewModel.onItemTap(shown.item) }
                }
                if (next != null) item(key = "next") { NextBar(next, onClick = { viewModel.openCategory(next.category) }) }
            }

            if (undo != null) {
                Button(
                    onClick = { viewModel.onUndo() },
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 14.dp),
                    label = {
                        Text(stringResource(R.string.undo_item, undo.name), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    },
                )
            }
        }
    }
}

@Composable
private fun ItemBar(shown: DisplayItem, style: CategoryStyle, struck: Boolean, onClick: () -> Unit) {
    val item = shown.item
    Bar(style.bg(), BarHeight, enabled = !struck, onClick = onClick, modifier = Modifier.alpha(if (struck) 0.55f else 1f)) {
        if (struck) {
            Box(Modifier.size(24.dp).clip(CircleShape).background(Color(0xFF20AC64)), contentAlignment = Alignment.Center) {
                Text("✓", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black)
            }
        } else {
            Glyph(item.icon, item.name, style.fg())
        }
        Column(Modifier.weight(1f)) {
            Text(
                item.name,
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                textDecoration = if (struck) TextDecoration.LineThrough else null,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (shown.pending) {
                Text(stringResource(R.string.item_not_confirmed), fontSize = 10.sp, color = style.soft())
            }
        }
        if (item.description.isNotBlank()) {
            Text(item.description, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = style.soft(), maxLines = 1)
        }
    }
}

@Composable
private fun NextBar(next: ItemGroup, onClick: () -> Unit) {
    val style = categoryStyle(next.category)
    Bar(style.bg(), SmallBarHeight, onClick = onClick) {
        Text(
            stringResource(R.string.next_category, next.category ?: stringResource(R.string.uncategorized)),
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            color = style.fg(),
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Text("›", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = style.fg())
    }
}

/** The last item of the category was ticked. */
@Composable
private fun CategoryDoneScreen(
    viewModel: ShoppingViewModel,
    state: WatchState,
    category: String?,
    next: ItemGroup?,
    canUndo: Boolean,
) {
    val listState = rememberScalingLazyListState()
    val name = category ?: stringResource(R.string.uncategorized)
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(
            state = listState,
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding()),
            verticalArrangement = Arrangement.spacedBy(1.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxSize(),
        ) {
            item(key = "check") {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(bottom = 6.dp)) {
                    Box(Modifier.size(44.dp).clip(CircleShape).background(Color(0xFF20AC64)), contentAlignment = Alignment.Center) {
                        Text("✓", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Color.Black)
                    }
                    Text(
                        stringResource(R.string.category_done, name),
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 6.dp, start = 24.dp, end = 24.dp),
                    )
                    Text(
                        if (state.items.isEmpty()) stringResource(R.string.all_bought)
                        else stringResource(R.string.to_buy_total, state.items.size),
                        fontSize = 11.sp,
                        color = Color(0xFFA8A8B0),
                    )
                }
            }
            if (canUndo) {
                item(key = "undo") {
                    Bar(Color(0xFF2A2A30), SmallBarHeight, onClick = { viewModel.onUndo() }) {
                        Text(
                            "↶  " + stringResource(R.string.undo),
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
            if (next != null) {
                val style = categoryStyle(next.category)
                item(key = "next") {
                    Bar(style.bg(), BarHeight, onClick = { viewModel.openCategory(next.category) }) {
                        Glyph(next.items.firstNotNullOfOrNull { it.item.icon }, next.category ?: "·", style.fg())
                        Text(
                            next.category ?: stringResource(R.string.uncategorized),
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Bold,
                            color = style.fg(),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Text("${next.items.size}", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = style.fg())
                    }
                }
            }
            item(key = "categories") {
                Bar(Color(0xFF26262B), SmallBarHeight, onClick = { viewModel.closeCategory() }) {
                    Text(
                        "‹  " + stringResource(R.string.back_to_categories),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

// --- building blocks -------------------------------------------------------------------------

/**
 * An edge-to-edge tappable bar: the whole rectangle is the touch target (at least 48 dp high).
 * The padding keeps the content clear of the round screen's corners.
 */
@Composable
internal fun Bar(
    background: Color,
    height: androidx.compose.ui.unit.Dp,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
    content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .background(background)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(start = 34.dp, end = 30.dp),
        content = content,
    )
}

/** The item's glyph from the Items font, or its first letter when it has none. */
@Composable
private fun Glyph(codePoint: Int?, fallbackText: String, color: Color) {
    Box(Modifier.size(26.dp), contentAlignment = Alignment.Center) {
        if (codePoint != null) {
            Text(String(Character.toChars(codePoint)), fontFamily = ItemsFont, fontSize = 24.sp, color = color)
        } else {
            Text(
                fallbackText.trim().take(1).uppercase().ifEmpty { "·" },
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = color,
            )
        }
    }
}

@Composable
private fun StatusLine(text: String, warn: Boolean) {
    Text(
        text,
        color = if (warn) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.bodySmall,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
    )
}

@Composable
private fun ListPicker(lists: List<ListRef>, selectedId: Long?, onPick: (Long) -> Unit) {
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(
            state = listState,
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding()),
            verticalArrangement = Arrangement.spacedBy(1.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item { ListHeader { Text(stringResource(R.string.pick_list)) } }
            items(lists, key = { it.id }) { l ->
                val selected = l.id == selectedId
                Bar(
                    if (selected) Color(0xFF20AC64) else Color(0xFF26262B),
                    BarHeight,
                    onClick = { onPick(l.id) },
                ) {
                    Text(
                        l.name,
                        fontSize = 16.sp,
                        fontWeight = if (selected) FontWeight.Bold else FontWeight.SemiBold,
                        color = if (selected) Color.Black else Color.Unspecified,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    if (selected) Text("✓", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Color.Black)
                }
            }
        }
    }
}

/** "Updated 3 h ago" when the phone's list is older than [STALE_AFTER_MILLIS], else null. */
@Composable
internal fun ageText(updatedMs: Long, nowMs: Long = System.currentTimeMillis()): String? {
    val age = nowMs - updatedMs
    if (updatedMs <= 0 || age < STALE_AFTER_MILLIS) return null
    val hours = (age / (60 * 60 * 1000L)).toInt()
    return if (hours < 48) stringResource(R.string.updated_hours, hours)
    else stringResource(R.string.updated_days, hours / 24)
}
