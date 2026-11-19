package com.tombursch.kitchenowl.wear.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tombursch.kitchenowl.wear.ServiceLocator
import com.tombursch.kitchenowl.wear.data.PhoneMenu
import com.tombursch.kitchenowl.wear.data.WatchItem
import com.tombursch.kitchenowl.wear.data.WatchState
import com.tombursch.kitchenowl.wear.log.LogRelay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The category being looked at; a null name is "uncategorized". */
data class OpenCategory(val name: String?)

class ShoppingViewModel : ViewModel() {
    private val repo = ServiceLocator.repository

    val state: StateFlow<WatchState> = repo.state

    /** Ticked items still drawn (struck through) although the repository dropped them. */
    private val _struck = MutableStateFlow<Map<Long, WatchItem>>(emptyMap())
    val struck: StateFlow<Map<Long, WatchItem>> = _struck

    /** The last tick, offered for undo. */
    private val _undo = MutableStateFlow<WatchItem?>(null)
    val undo: StateFlow<WatchItem?> = _undo

    /** Shown on the refresh button until the phone answers (or a few seconds pass). */
    private val _refreshing = MutableStateFlow(false)
    val refreshing: StateFlow<Boolean> = _refreshing

    /** The category that is open (E2/E3); null = the category overview (E1). */
    private val _open = MutableStateFlow<OpenCategory?>(null)
    val open: StateFlow<OpenCategory?> = _open

    fun openCategory(name: String?) {
        _open.value = OpenCategory(name)
    }

    fun closeCategory() {
        _open.value = null
    }

    /** The phone's planned menu (for the menu screens and the tile). */
    val menu: StateFlow<PhoneMenu?> = ServiceLocator.menuRepository.state

    /** Where the user is in the menu screens; null = not in the menu. */
    private val _menuNav = MutableStateFlow<MenuNav?>(null)
    val menuNav: StateFlow<MenuNav?> = _menuNav

    /** [day] = `yyyy-MM-dd` for one day, null for the week. */
    fun openMenu(day: String? = null) {
        _menuNav.value = MenuNav(day)
    }

    fun closeMenu() {
        _menuNav.value = null
    }

    /** "Send logs": null, then true/false (handed to the phone or not) for a few seconds. */
    private val _logsSent = MutableStateFlow<Boolean?>(null)
    val logsSent: StateFlow<Boolean?> = _logsSent

    /** Hands the log buffer to the phone, which sends it right away (no network on the watch). */
    fun sendLogs(context: android.content.Context) {
        val app = context.applicationContext
        viewModelScope.launch(Dispatchers.IO) {
            _logsSent.value = LogRelay.sendNow(app)
            delay(LOGS_FEEDBACK_MILLIS)
            _logsSent.value = null
        }
    }

    private var undoTimeout: Job? = null
    private var refreshTimeout: Job? = null

    init {
        // A newer snapshot is the phone's answer.
        viewModelScope.launch {
            repo.state.map { it.updatedMs }.distinctUntilChanged().drop(1).collect { _refreshing.value = false }
        }
    }

    fun onItemTap(item: WatchItem) {
        if (_struck.value.containsKey(item.id)) return
        repo.remove(item)
        _struck.update { it + (item.id to item) }
        viewModelScope.launch {
            delay(STRIKE_MILLIS)
            _struck.update { it - item.id }
        }
        _undo.value = item
        undoTimeout?.cancel()
        undoTimeout = viewModelScope.launch {
            delay(UNDO_MILLIS)
            _undo.value = null
        }
    }

    fun onUndo() {
        val item = _undo.value ?: return
        _undo.value = null
        undoTimeout?.cancel()
        _struck.update { it - item.id }
        repo.undo(item)
    }

    fun selectList(id: Long) = repo.selectList(id)

    /** Asks the phone for a fresh snapshot (on resume, and from the refresh button). */
    fun refresh() {
        if (!repo.refresh()) return
        _refreshing.value = true
        refreshTimeout?.cancel()
        refreshTimeout = viewModelScope.launch {
            delay(REFRESH_FEEDBACK_MILLIS)
            _refreshing.value = false
        }
    }

    companion object {
        const val STRIKE_MILLIS = 2_000L
        const val UNDO_MILLIS = 5_000L
        const val REFRESH_FEEDBACK_MILLIS = 8_000L
        const val LOGS_FEEDBACK_MILLIS = 4_000L
    }
}
