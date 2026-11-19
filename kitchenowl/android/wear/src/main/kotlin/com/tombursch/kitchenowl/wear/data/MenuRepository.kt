package com.tombursch.kitchenowl.wear.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

interface MenuStorage {
    fun loadMenu(): PhoneMenu?
    fun saveMenu(menu: PhoneMenu)
}

/** The phone's last menu, kept for offline use. No network: it only changes when the phone publishes. */
class MenuRepository(private val storage: MenuStorage) {
    private val _state = MutableStateFlow(storage.loadMenu())
    val state: StateFlow<PhoneMenu?> = _state.asStateFlow()

    fun onMenu(menu: PhoneMenu) {
        val current = _state.value
        if (current != null && menu.updatedMs < current.updatedMs) return // stale delivery
        storage.saveMenu(menu)
        _state.value = menu
    }
}
