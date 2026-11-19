package com.tombursch.kitchenowl.wear.ui

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import com.tombursch.kitchenowl.wear.sync.PhoneListenerService

class MainActivity : ComponentActivity() {
    private val viewModel: ShoppingViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { WearRoot(viewModel) }
        if (savedInstanceState == null) openScreenFrom(intent)
        // Pick up what arrived while nothing was listening and send what is still unsent.
        PhoneListenerService.checkPending(applicationContext)
    }

    // The menu tile opens the app on its menu screen.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openScreenFrom(intent)
    }

    private fun openScreenFrom(intent: Intent?) {
        if (intent?.getStringExtra(EXTRA_SCREEN) == SCREEN_MENU) {
            viewModel.openMenu()
            intent.removeExtra(EXTRA_SCREEN)
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refresh()
    }

    companion object {
        const val EXTRA_SCREEN = "screen"
        const val SCREEN_MENU = "menu"
    }
}
