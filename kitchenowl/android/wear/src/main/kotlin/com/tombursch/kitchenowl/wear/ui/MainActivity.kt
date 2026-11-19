package com.tombursch.kitchenowl.wear.ui

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
        // Pick up what arrived while nothing was listening and send what is still unsent.
        PhoneListenerService.checkPending(applicationContext)
    }

    override fun onResume() {
        super.onResume()
        viewModel.refresh()
    }
}
