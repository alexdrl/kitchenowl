package com.tombursch.kitchenowl.wear.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// The watch has no network access and no token. Everything it knows comes from the phone
// app through the Wearable Data Layer (lib/services/wear_bridge.dart on the phone):
//   /kitchenowl/shoppinglist       phone -> watch  PhoneSnapshot (JSON)
//   /kitchenowl/actions/<uuid>     watch -> phone  WatchAction (JSON), deleted by the phone once applied

const val SNAPSHOT_PATH = "/kitchenowl/shoppinglist"
const val ACTIONS_PATH = "/kitchenowl/actions"

@Serializable
data class WatchItem(
    val id: Long,
    val name: String,
    val description: String = "",
    val category: String? = null,
    /** Code point of the item's glyph in the app's Items font (bundled as R.font.items); null = none. */
    val icon: Int? = null,
)

@Serializable
data class ListRef(val id: Long, val name: String)

/** The shopping list as the phone last saw it. Items are already in category order. */
@Serializable
data class PhoneSnapshot(
    val version: Int = 1,
    @SerialName("household_id") val householdId: Long = 0,
    @SerialName("list_id") val listId: Long,
    @SerialName("list_name") val listName: String = "",
    @SerialName("updated_ms") val updatedMs: Long = 0,
    val lists: List<ListRef> = emptyList(),
    val items: List<WatchItem> = emptyList(),
)

@Serializable
enum class ActionType {
    @SerialName("remove") REMOVE,
    @SerialName("add") ADD,
    @SerialName("refresh") REFRESH,
    @SerialName("select_list") SELECT_LIST,
}

/** What is written to `/kitchenowl/actions/<uuid>` (the uuid is the last path segment). */
@Serializable
data class WatchAction(
    val type: ActionType,
    @SerialName("list_id") val listId: Long,
    @SerialName("item_id") val itemId: Long? = null,
    @SerialName("item_name") val itemName: String? = null,
    val description: String? = null,
    /** When the user did it; the phone applies actions in this order. */
    @SerialName("created_ms") val createdMs: Long = 0,
)

/**
 * An action the phone has not confirmed yet. It stays applied on top of the snapshot until
 * the phone has deleted it (= applied it) and a newer snapshot has arrived.
 */
@Serializable
data class PendingAction(
    val uuid: String,
    val action: WatchAction,
    /** The item for remove/add, to redraw the list without the phone. */
    val item: WatchItem? = null,
    /** Handed to the Data Layer. */
    val sent: Boolean = false,
    /** The phone deleted the action item: it applied it. Dropped at the next snapshot. */
    val confirmed: Boolean = false,
)
