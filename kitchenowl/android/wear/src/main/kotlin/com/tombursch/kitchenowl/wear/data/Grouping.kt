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
