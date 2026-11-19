package com.tombursch.kitchenowl.wear.data

import java.text.Collator
import java.util.Locale

/** An item as drawn: [pending] = put back by the user and not confirmed by the phone yet. */
data class DisplayItem(val item: WatchItem, val pending: Boolean = false)

/** A block of the list under one category header; [category] null = uncategorized. */
data class ItemGroup(val category: String?, val items: List<DisplayItem>)

/**
 * The phone sends the items in category order, so categories keep the order in which they first
 * appear (uncategorized last); inside a category items are sorted by name, which also puts an
 * item that was put back in its place.
 */
fun groupByCategory(items: List<DisplayItem>, locale: Locale = Locale.getDefault()): List<ItemGroup> {
    val collator = Collator.getInstance(locale).apply { strength = Collator.PRIMARY }
    val byName = Comparator<DisplayItem> { a, b -> collator.compare(a.item.name, b.item.name) }
    val groups = LinkedHashMap<String?, MutableList<DisplayItem>>()
    for (item in items) {
        groups.getOrPut(item.item.category?.takeIf { it.isNotBlank() }) { mutableListOf() }.add(item)
    }
    val categorized = groups.filterKeys { it != null }.map { (name, list) -> ItemGroup(name, list.sortedWith(byName)) }
    val uncategorized = groups[null]?.let { listOf(ItemGroup(null, it.sortedWith(byName))) }.orEmpty()
    return categorized + uncategorized
}

/** Colours of a category (ARGB): a dark background for its rows and a bright accent for its text. */
data class CategoryStyle(val background: Long, val accent: Long, val muted: Long)

private val palette = listOf(
    CategoryStyle(0xFF1A3322, 0xFF6FD08C, 0xFFB8DCC4), // green
    CategoryStyle(0xFF3A2E1A, 0xFFF2B35E, 0xFFE6D2AC), // amber
    CategoryStyle(0xFF1B2A42, 0xFF7FB2FF, 0xFFBCD2F0), // blue
    CategoryStyle(0xFF3A1F26, 0xFFF08A9A, 0xFFEBC0C8), // rose
    CategoryStyle(0xFF2E2340, 0xFFB79CF0, 0xFFD6C8F2), // violet
    CategoryStyle(0xFF17333A, 0xFF6FD3E0, 0xFFB8E4EA), // teal
)
private val noCategory = CategoryStyle(0xFF26262B, 0xFFC8C8D0, 0xFFA8A8B0)

/** The same name always gets the same colour (String.hashCode is the same on every device). */
fun categoryStyle(category: String?): CategoryStyle =
    if (category == null) noCategory else palette[Math.floorMod(category.hashCode(), palette.size)]

/**
 * The category to offer after [current], in list order; once the last one is done it goes back to
 * the first one that still has items, so nothing is left behind. Null when [current] is the only
 * one with items.
 *
 * [order] is the category order from before [current] was finished (it is no longer among
 * [groups] then), so its place in the route is still known.
 */
fun nextGroup(groups: List<ItemGroup>, current: String?, order: List<String?> = groups.map { it.category }): ItemGroup? {
    val others = groups.filter { it.category != current && it.items.isNotEmpty() }
    if (others.isEmpty()) return null
    val position = order.indexOf(current)
    return others.firstOrNull { order.indexOf(it.category) > position } ?: others.first()
}
