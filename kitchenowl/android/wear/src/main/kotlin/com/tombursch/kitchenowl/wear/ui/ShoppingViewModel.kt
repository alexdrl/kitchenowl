package com.tombursch.kitchenowl.wear.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tombursch.kitchenowl.wear.ServiceLocator
import com.tombursch.kitchenowl.wear.data.WatchItem
import com.tombursch.kitchenowl.wear.data.WatchState
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

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
    }
}
