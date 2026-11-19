package com.tombursch.kitchenowl

import android.Manifest
import android.accounts.AbstractAccountAuthenticator
import android.accounts.Account
import android.accounts.AccountAuthenticatorResponse
import android.accounts.AccountManager
import android.app.Service
import android.content.AbstractThreadedSyncAdapter
import android.content.BroadcastReceiver
import android.content.ContentProviderClient
import android.content.ContentProviderOperation
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SyncResult
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.IBinder
import android.provider.CalendarContract
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.util.Log
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject
import java.util.TimeZone

/**
 * The planned meals as a calendar of the phone, like Outlook does it: an account of our own
 * type ("KitchenOwl" under Settings → Accounts) owns a read-only calendar, and a sync adapter
 * writes the menu into it. Calendar apps (Samsung Calendar, Google Calendar) show it like any
 * other calendar, without subscribing to a URL.
 *
 * The data is the menu the app already stores for the home screen widget
 * (`lib/services/menu_widget.dart`, 14 days from this week's Monday), so the calendar follows
 * the same updates: opening the planner and the background fetch task. After each one the app
 * pokes [CalendarSyncTrigger], which asks Android for a sync.
 */
object CalendarSync {
    const val ACCOUNT_TYPE = "com.tombursch.kitchenowl.account"
    private const val ACCOUNT_NAME = "KitchenOwl"
    private const val CALENDAR_NAME = "kitchenowl_menu"
    private const val AUTHORITY = CalendarContract.AUTHORITY
    private const val PERIODIC_SECONDS = 6 * 3600L

    /** Mirrored into the widget storage so the Dart side (also headless) can read it. */
    const val ENABLED_KEY = "calendar_sync"
    private const val TAG = "KitchenOwlCalendar"

    val PERMISSIONS = arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)

    fun hasPermissions(context: Context) = PERMISSIONS.all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    fun account(context: Context): Account? =
        AccountManager.get(context).getAccountsByType(ACCOUNT_TYPE).firstOrNull()

    fun isEnabled(context: Context) = account(context) != null

    /** Adds the account and asks for a first sync. The caller has the calendar permissions. */
    fun enable(context: Context): Boolean {
        val account = account(context) ?: Account(ACCOUNT_NAME, ACCOUNT_TYPE).also {
            if (!AccountManager.get(context).addAccountExplicitly(it, null, null)) return false
        }
        ContentResolver.setIsSyncable(account, AUTHORITY, 1)
        ContentResolver.setSyncAutomatically(account, AUTHORITY, true)
        ContentResolver.addPeriodicSync(account, AUTHORITY, Bundle.EMPTY, PERIODIC_SECONDS)
        setFlag(context, true)
        requestSync(context)
        return true
    }

    /** Removes the calendar and the account: every event goes with them. */
    fun disable(context: Context) {
        account(context)?.let { account ->
            if (hasPermissions(context)) {
                runCatching {
                    context.contentResolver.delete(
                        asSyncAdapter(Calendars.CONTENT_URI, account),
                        "${Calendars.ACCOUNT_NAME} = ? AND ${Calendars.ACCOUNT_TYPE} = ?",
                        arrayOf(account.name, account.type),
                    )
                }.onFailure { Log.w(TAG, "Could not delete the calendar", it) }
            }
            AccountManager.get(context).removeAccountExplicitly(account)
        }
        setFlag(context, false)
    }

    fun requestSync(context: Context) {
        val account = account(context) ?: return
        ContentResolver.requestSync(account, AUTHORITY, Bundle().apply {
            putBoolean(ContentResolver.SYNC_EXTRAS_MANUAL, true)
            putBoolean(ContentResolver.SYNC_EXTRAS_EXPEDITED, true)
        })
    }

    private fun setFlag(context: Context, enabled: Boolean) {
        HomeWidgetPlugin.getData(context).edit().putBoolean(ENABLED_KEY, enabled).apply()
    }

    fun asSyncAdapter(uri: Uri, account: Account): Uri = uri.buildUpon()
        .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
        .appendQueryParameter(Calendars.ACCOUNT_NAME, account.name)
        .appendQueryParameter(Calendars.ACCOUNT_TYPE, account.type)
        .build()

    /** One sync: makes the calendar match the stored menu. */
    fun sync(context: Context, account: Account, provider: ContentProviderClient, result: SyncResult) {
        if (!hasPermissions(context)) return
        val json = HomeWidgetPlugin.getData(context).getString(MenuWidgetProvider.DATA_KEY, null)
            ?: return
        val data = runCatching { JSONObject(json) }.getOrNull() ?: return
        val household = data.optJSONObject("household") ?: return
        val householdId = household.optInt("id", -1).takeIf { it >= 0 } ?: return
        val days = parseDays(data.optJSONObject("days") ?: return)
        if (days.isEmpty()) return

        val zone = TimeZone.getDefault()
        val calendarId = ensureCalendar(context, provider, account, household.optString("name"), zone)
        val labels = mapOf(
            "breakfast" to context.getString(R.string.menu_widget_breakfast),
            "lunch" to context.getString(R.string.menu_widget_lunch),
            "dinner" to context.getString(R.string.menu_widget_dinner),
        )
        val desired = MenuCalendar.events(householdId, days, labels, zone)
        val changes = MenuCalendar.reconcile(desired, existingEvents(provider, account, calendarId), days.keys)
        if (changes.isEmpty) return

        val eventsUri = asSyncAdapter(Events.CONTENT_URI, account)
        val ops = ArrayList<ContentProviderOperation>()
        changes.deletes.forEach { id ->
            ops += ContentProviderOperation.newDelete(
                asSyncAdapter(Uri.withAppendedPath(Events.CONTENT_URI, id.toString()), account),
            ).build()
        }
        changes.updates.forEach { (id, event) ->
            ops += ContentProviderOperation.newUpdate(
                asSyncAdapter(Uri.withAppendedPath(Events.CONTENT_URI, id.toString()), account),
            ).withValues(values(event, calendarId)).build()
        }
        changes.inserts.forEach { event ->
            ops += ContentProviderOperation.newInsert(eventsUri).withValues(values(event, calendarId)).build()
        }
        provider.applyBatch(ops)
        result.stats.numDeletes += changes.deletes.size
        result.stats.numUpdates += changes.updates.size
        result.stats.numInserts += changes.inserts.size
    }

    private fun parseDays(days: JSONObject): Map<String, Map<String, List<String>>> =
        days.keys().asSequence().associateWith { day ->
            val meals = days.optJSONObject(day) ?: JSONObject()
            meals.keys().asSequence().associateWith { meal ->
                val names = meals.optJSONArray(meal)
                (0 until (names?.length() ?: 0)).map { names!!.optString(it) }
            }
        }

    private fun ensureCalendar(
        context: Context,
        provider: ContentProviderClient,
        account: Account,
        householdName: String,
        zone: TimeZone,
    ): Long {
        val displayName = householdName.ifBlank { context.getString(R.string.calendar_sync_name) }
        val calendarsUri = asSyncAdapter(Calendars.CONTENT_URI, account)
        provider.query(
            calendarsUri,
            arrayOf(Calendars._ID, Calendars.CALENDAR_DISPLAY_NAME),
            "${Calendars.ACCOUNT_NAME} = ? AND ${Calendars.ACCOUNT_TYPE} = ? AND ${Calendars.NAME} = ?",
            arrayOf(account.name, account.type, CALENDAR_NAME),
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(0)
                if (cursor.getString(1) != displayName) {
                    provider.update(
                        asSyncAdapter(Uri.withAppendedPath(Calendars.CONTENT_URI, id.toString()), account),
                        ContentValues().apply { put(Calendars.CALENDAR_DISPLAY_NAME, displayName) },
                        null,
                        null,
                    )
                }
                return id
            }
        }
        val uri = provider.insert(calendarsUri, ContentValues().apply {
            put(Calendars.ACCOUNT_NAME, account.name)
            put(Calendars.ACCOUNT_TYPE, account.type)
            put(Calendars.NAME, CALENDAR_NAME)
            put(Calendars.CALENDAR_DISPLAY_NAME, displayName)
            put(Calendars.CALENDAR_COLOR, context.getColor(R.color.calendar_sync_color))
            // Read only: the planner is the place to change meals
            put(Calendars.CALENDAR_ACCESS_LEVEL, Calendars.CAL_ACCESS_READ)
            put(Calendars.OWNER_ACCOUNT, account.name)
            put(Calendars.VISIBLE, 1)
            put(Calendars.SYNC_EVENTS, 1)
            put(Calendars.CALENDAR_TIME_ZONE, zone.id)
        }) ?: error("Could not create the calendar")
        return uri.lastPathSegment!!.toLong()
    }

    private fun existingEvents(
        provider: ContentProviderClient,
        account: Account,
        calendarId: Long,
    ): List<ExistingEvent> {
        val events = mutableListOf<ExistingEvent>()
        provider.query(
            asSyncAdapter(Events.CONTENT_URI, account),
            arrayOf(Events._ID, Events._SYNC_ID, Events.TITLE, Events.DTSTART, Events.DTEND, Events.ALL_DAY),
            "${Events.CALENDAR_ID} = ?",
            arrayOf(calendarId.toString()),
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                events += ExistingEvent(
                    id = c.getLong(0),
                    key = c.getString(1),
                    title = c.getString(2),
                    start = c.getLong(3),
                    end = c.getLong(4),
                    allDay = c.getInt(5) == 1,
                )
            }
        }
        return events
    }

    private fun values(event: MenuEvent, calendarId: Long) = ContentValues().apply {
        put(Events.CALENDAR_ID, calendarId)
        put(Events._SYNC_ID, event.key)
        put(Events.TITLE, event.title)
        put(Events.DTSTART, event.start)
        put(Events.DTEND, event.end)
        put(Events.ALL_DAY, if (event.allDay) 1 else 0)
        put(Events.EVENT_TIMEZONE, event.timeZone)
        put(Events.AVAILABILITY, Events.AVAILABILITY_FREE)
    }
}

class CalendarSyncAdapter(context: Context) : AbstractThreadedSyncAdapter(context, true) {
    override fun onPerformSync(
        account: Account,
        extras: Bundle,
        authority: String,
        provider: ContentProviderClient,
        syncResult: SyncResult,
    ) {
        try {
            CalendarSync.sync(context, account, provider, syncResult)
        } catch (e: Exception) {
            Log.w("KitchenOwlCalendar", "Sync failed", e)
            syncResult.stats.numIoExceptions++
        }
    }
}

class CalendarSyncService : Service() {
    override fun onBind(intent: Intent?): IBinder = adapter(applicationContext).syncAdapterBinder

    private companion object {
        private var instance: CalendarSyncAdapter? = null

        @Synchronized
        fun adapter(context: Context) = instance ?: CalendarSyncAdapter(context).also { instance = it }
    }
}

/** The account holds no credentials: the app is signed in already. It only owns the calendar. */
class CalendarAuthenticator(private val context: Context) : AbstractAccountAuthenticator(context) {
    override fun addAccount(
        response: AccountAuthenticatorResponse?,
        accountType: String?,
        authTokenType: String?,
        requiredFeatures: Array<out String>?,
        options: Bundle?,
    ): Bundle = Bundle().apply {
        // From Settings → Accounts → Add: open the app, the toggle is in the planner
        putParcelable(
            AccountManager.KEY_INTENT,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    override fun editProperties(response: AccountAuthenticatorResponse?, accountType: String?) = null
    override fun confirmCredentials(
        response: AccountAuthenticatorResponse?,
        account: Account?,
        options: Bundle?,
    ) = null

    override fun getAuthToken(
        response: AccountAuthenticatorResponse?,
        account: Account?,
        authTokenType: String?,
        options: Bundle?,
    ) = null

    override fun getAuthTokenLabel(authTokenType: String?) = null
    override fun updateCredentials(
        response: AccountAuthenticatorResponse?,
        account: Account?,
        authTokenType: String?,
        options: Bundle?,
    ) = null

    override fun hasFeatures(
        response: AccountAuthenticatorResponse?,
        account: Account?,
        features: Array<out String>?,
    ) = Bundle().apply { putBoolean(AccountManager.KEY_BOOLEAN_RESULT, false) }
}

class CalendarAuthenticatorService : Service() {
    private lateinit var authenticator: CalendarAuthenticator

    override fun onCreate() {
        super.onCreate()
        authenticator = CalendarAuthenticator(this)
    }

    override fun onBind(intent: Intent?): IBinder? = authenticator.iBinder
}

/**
 * The app sends this (through `HomeWidget.updateWidget`, which works in the headless background
 * engine too) right after it stored a new menu.
 */
class CalendarSyncTrigger : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CalendarSync.requestSync(context)
    }
}
