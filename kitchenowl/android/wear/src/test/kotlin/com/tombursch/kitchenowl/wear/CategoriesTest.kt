package com.tombursch.kitchenowl.wear

import com.tombursch.kitchenowl.wear.data.DisplayItem
import com.tombursch.kitchenowl.wear.data.ItemGroup
import com.tombursch.kitchenowl.wear.data.WatchItem
import com.tombursch.kitchenowl.wear.data.categoryStyle
import com.tombursch.kitchenowl.wear.data.groupByCategory
import com.tombursch.kitchenowl.wear.data.nextGroup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Locale

class CategoriesTest {
    private fun group(name: String?, vararg items: String) =
        ItemGroup(name, items.mapIndexed { i, n -> DisplayItem(WatchItem(i.toLong(), n, category = name)) })

    private val fruit = group("Fruta", "Tomates")
    private val bakery = group("Panadería", "Rosquilletas", "Pan")
    private val dairy = group("Lácteos", "Leche")
    private val none = group(null, "Pilas")

    @Test
    fun nextIsTheFollowingCategoryInTheStoreOrder() {
        val groups = listOf(fruit, bakery, dairy, none)
        assertEquals(bakery, nextGroup(groups, "Fruta"))
        assertEquals(dairy, nextGroup(groups, "Panadería"))
        assertEquals(none, nextGroup(groups, "Lácteos"))
    }

    @Test
    fun afterTheLastOneItGoesBackToWhatIsLeft() {
        val groups = listOf(fruit, bakery, dairy)
        assertEquals(fruit, nextGroup(groups, "Lácteos"))
    }

    @Test
    fun aFinishedCategoryIsSkippedAndOfferedFromItsPlace() {
        // Panadería was ticked off completely: it is no longer among the groups, but its place in
        // the route (from before) still decides what comes next
        val before = listOf("Fruta", "Panadería", "Lácteos")
        assertEquals(dairy, nextGroup(listOf(fruit, dairy), "Panadería", before))
        // it was the last one: back to the first one that is left
        assertEquals(fruit, nextGroup(listOf(fruit, dairy), "Zumos", before + "Zumos"))
    }

    @Test
    fun noNextWhenItIsTheOnlyOne() {
        assertNull(nextGroup(listOf(bakery), "Panadería"))
        assertNull(nextGroup(emptyList(), "Panadería"))
    }

    @Test
    fun uncategorizedCanBeTheNextAndTheCurrentOne() {
        assertEquals(bakery, nextGroup(listOf(bakery, none), null))
        assertEquals(none, nextGroup(listOf(bakery, none), "Panadería"))
    }

    @Test
    fun categoryColoursAreStableAndUncategorizedIsGrey() {
        assertEquals(categoryStyle("Lácteos"), categoryStyle("Lácteos"))
        assertEquals(0xFF26262B, categoryStyle(null).background)
        // the user's categories should not all look alike
        val styles = listOf("Fruta", "Panadería", "Lácteos", "Carne", "Bebidas").map { categoryStyle(it) }
        assertNotEquals(1, styles.toSet().size)
    }

    @Test
    fun groupsFollowThePhoneOrderAndCountsAreTheirSizes() {
        fun item(id: Long, name: String, category: String?) = DisplayItem(WatchItem(id, name, category = category))
        val groups = groupByCategory(
            listOf(item(1, "Tomates", "Fruta"), item(2, "Pan", "Panadería"), item(3, "Limones", "Fruta")),
            Locale.ENGLISH,
        )
        assertEquals(listOf("Fruta" to 2, "Panadería" to 1), groups.map { it.category to it.items.size })
    }
}
