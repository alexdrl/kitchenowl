package com.tombursch.kitchenowl.wear

import com.tombursch.kitchenowl.wear.data.ActionType
import com.tombursch.kitchenowl.wear.data.DisplayItem
import com.tombursch.kitchenowl.wear.data.WatchAction
import com.tombursch.kitchenowl.wear.data.WatchItem
import com.tombursch.kitchenowl.wear.data.actionUuid
import com.tombursch.kitchenowl.wear.data.encodeAction
import com.tombursch.kitchenowl.wear.data.groupByCategory
import com.tombursch.kitchenowl.wear.data.parseSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Locale

class ParsingTest {
    // Exactly what lib/models/wear_snapshot.dart produces (plus an unknown field from a newer phone app).
    private val snapshot = """
        {"version":1,"household_id":9,"list_id":7,"list_name":"Groceries","updated_ms":1700000000000,
         "lists":[{"id":7,"name":"Groceries"},{"id":8,"name":"DIY"}],
         "items":[
           {"id":5,"name":"Butter","description":"","category":"Dairy","icon":259},
           {"id":1,"name":"Milk","description":"2 l","category":"Dairy"},
           {"id":4,"name":"Bread","description":"","category":null,"future_field":true}
         ],
         "something_new": 1}
    """.trimIndent()

    @Test
    fun parsesThePhonesSnapshot() {
        val s = parseSnapshot(snapshot.toByteArray())!!
        assertEquals(9L, s.householdId)
        assertEquals(7L, s.listId)
        assertEquals("Groceries", s.listName)
        assertEquals(1700000000000, s.updatedMs)
        assertEquals(listOf("Groceries", "DIY"), s.lists.map { it.name })
        assertEquals(listOf("Butter", "Milk", "Bread"), s.items.map { it.name })
        assertEquals("2 l", s.items[1].description)
        assertEquals("Dairy", s.items[1].category)
        assertNull(s.items[2].category)
        // the item's glyph in the Items font, when it has one
        assertEquals(259, s.items[0].icon)
        assertNull(s.items[1].icon)
    }

    @Test
    fun garbageIsNotASnapshot() {
        assertNull(parseSnapshot("not json".toByteArray()))
        assertNull(parseSnapshot("{}".toByteArray())) // no list_id
        assertNull(parseSnapshot(ByteArray(0)))
    }

    @Test
    fun actionsHaveTheWireShapeThePhoneReads() {
        val remove = WatchAction(ActionType.REMOVE, listId = 7, itemId = 3, itemName = "Milk", description = "2 l", createdMs = 1700000000123)
        assertEquals(
            """{"type":"remove","list_id":7,"item_id":3,"item_name":"Milk","description":"2 l","created_ms":1700000000123}""",
            String(encodeAction(remove)),
        )
        // what an action does not use is left out
        assertEquals(
            """{"type":"refresh","list_id":7,"created_ms":5}""",
            String(encodeAction(WatchAction(ActionType.REFRESH, 7, createdMs = 5))),
        )
        assertEquals(
            """{"type":"select_list","list_id":8,"created_ms":6}""",
            String(encodeAction(WatchAction(ActionType.SELECT_LIST, 8, createdMs = 6))),
        )
        assertEquals(
            """{"type":"add","list_id":7,"item_id":3,"item_name":"Milk","description":"","created_ms":7}""",
            String(encodeAction(WatchAction(ActionType.ADD, 7, 3, "Milk", "", 7))),
        )
    }

    @Test
    fun uuidIsTheLastPathSegment() {
        assertEquals("abc-123", actionUuid("/kitchenowl/actions/abc-123"))
        assertNull(actionUuid("/kitchenowl/shoppinglist"))
        assertNull(actionUuid("/kitchenowl/actions/"))
        assertNull(actionUuid("/kitchenowl/actions/a/b"))
        assertNull(actionUuid(null))
    }

    @Test
    fun groupsKeepTheCategoryOrderOfThePhone() {
        fun item(id: Long, name: String, category: String?) = DisplayItem(WatchItem(id, name, category = category))
        val groups = groupByCategory(
            listOf(
                item(1, "Tomatoes", "Vegetables"),
                item(2, "Bread", null),
                item(3, "Milk", "Dairy"),
                item(4, "apples", "Vegetables"),
            ),
            Locale.ENGLISH,
        )
        // Vegetables came first in the phone's order, uncategorized stays last
        assertEquals(listOf("Vegetables", "Dairy", null), groups.map { it.category })
        assertEquals(listOf("apples", "Tomatoes"), groups[0].items.map { it.item.name })
        assertEquals(listOf("Bread"), groups[2].items.map { it.item.name })
    }
}
