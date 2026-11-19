package com.tombursch.kitchenowl.wear.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.FilledTonalButton
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import com.tombursch.kitchenowl.wear.R
import com.tombursch.kitchenowl.wear.data.DisplayItem
import com.tombursch.kitchenowl.wear.data.ListRef
import com.tombursch.kitchenowl.wear.data.WatchItem
import com.tombursch.kitchenowl.wear.data.groupByCategory

/** Older than this, the screen says how old the phone's list is. */
const val STALE_AFTER_MILLIS = 60 * 60 * 1000L

@Composable
fun WearRoot(viewModel: ShoppingViewModel) {
    // MaterialTheme of Wear Compose Material 3 is dark by default, which is what Wear OS expects.
    MaterialTheme {
        AppScaffold {
            val state by viewModel.state.collectAsState()
            if (state.snapshot == null) NoSnapshotScreen() else ShoppingScreen(viewModel)
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

@Composable
private fun ShoppingScreen(viewModel: ShoppingViewModel) {
    val state by viewModel.state.collectAsState()
    val struck by viewModel.struck.collectAsState()
    val undo by viewModel.undo.collectAsState()
    val refreshing by viewModel.refreshing.collectAsState()
    var picking by remember { mutableStateOf(false) }

    BackHandler(enabled = picking) { picking = false }

    if (picking) {
        ListPicker(
            lists = state.lists,
            selectedId = state.snapshot?.listId,
            onPick = {
                viewModel.selectList(it)
                picking = false
            },
        )
        return
    }

    // What the phone confirmed plus what was done since, and what was ticked a moment ago
    // (still drawn, struck through).
    val shown = remember(state.items, struck) {
        val missing = struck.values
            .filter { t -> state.items.none { it.item.id == t.id } }
            .map { DisplayItem(it) }
        groupByCategory(state.items + missing)
    }

    val ageText = ageText(state.updatedMs)
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        Box(Modifier.fillMaxSize()) {
            ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
                item(key = "title") {
                    if (state.lists.size > 1) {
                        FilledTonalButton(
                            onClick = { picking = true },
                            modifier = Modifier.fillMaxWidth(),
                            label = { Text(state.listName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            secondaryLabel = { Text(stringResource(R.string.change_list)) },
                        )
                    } else {
                        ListHeader {
                            Text(
                                state.listName.ifEmpty { stringResource(R.string.app_name) },
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
                if (state.switchingList) {
                    item(key = "switching") { StatusLine(stringResource(R.string.switching_list), warn = false) }
                }
                if (ageText != null) {
                    item(key = "age") { StatusLine(ageText, warn = true) }
                }
                if (state.pendingCount > 0) {
                    item(key = "pending") {
                        StatusLine(stringResource(R.string.not_confirmed, state.pendingCount), warn = false)
                    }
                }
                if (shown.isEmpty()) {
                    item(key = "empty") {
                        Text(
                            stringResource(R.string.list_empty),
                            style = MaterialTheme.typography.bodyMedium,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        )
                    }
                }
                for (group in shown) {
                    if (shown.size > 1 || group.category != null) {
                        item(key = "cat-${group.category}") {
                            ListHeader {
                                Text(
                                    group.category ?: stringResource(R.string.uncategorized),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                    items(group.items, key = { it.item.id }) { shownItem ->
                        ItemRow(
                            item = shownItem.item,
                            pending = shownItem.pending,
                            struck = struck.containsKey(shownItem.item.id),
                            onClick = { viewModel.onItemTap(shownItem.item) },
                        )
                    }
                }
                item(key = "refresh") {
                    FilledTonalButton(
                        onClick = { viewModel.refresh() },
                        enabled = !refreshing,
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(stringResource(if (refreshing) R.string.refreshing else R.string.refresh)) },
                    )
                }
            }

            val pending = undo
            if (pending != null) {
                Button(
                    onClick = { viewModel.onUndo() },
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 18.dp),
                    label = {
                        Text(
                            stringResource(R.string.undo_item, pending.name),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                )
            }
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
private fun ItemRow(item: WatchItem, pending: Boolean, struck: Boolean, onClick: () -> Unit) {
    val nameStyle = MaterialTheme.typography.titleSmall.let {
        if (struck) it.copy(textDecoration = TextDecoration.LineThrough) else it
    }
    val secondary = listOf(
        item.description.takeIf { it.isNotBlank() },
        if (pending) stringResource(R.string.item_not_confirmed) else null,
    ).filterNotNull().joinToString(" · ")
    FilledTonalButton(
        onClick = onClick,
        enabled = !struck,
        modifier = Modifier.fillMaxWidth().alpha(if (struck) 0.5f else 1f),
        label = { Text(item.name, style = nameStyle, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        secondaryLabel = if (secondary.isEmpty()) null else {
            { Text(secondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        },
    )
}

@Composable
private fun ListPicker(lists: List<ListRef>, selectedId: Long?, onPick: (Long) -> Unit) {
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text(stringResource(R.string.pick_list)) } }
            items(lists, key = { it.id }) { l ->
                FilledTonalButton(
                    onClick = { onPick(l.id) },
                    modifier = Modifier.fillMaxWidth(),
                    label = {
                        Text(
                            l.name,
                            style = if (l.id == selectedId) MaterialTheme.typography.titleSmall else MaterialTheme.typography.labelLarge,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                )
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
