# KitchenOwl for Wear OS

A small watch app to tick off the shopping list in the supermarket without taking the phone out.

**The watch never talks to the server and holds no token.** The phone app relays everything over
the Wearable Data Layer, so the watch needs no Wi-Fi or LTE and there is nothing to revoke on it.

- **List**: items of one shopping list, grouped under category headers (the phone's category order).
  Tap an item: it is struck through, disappears after 2 s, and is removed on the server by the
  phone. An **Undo** button stays for 5 s and puts it back.
- **Several lists**: tap the list name at the top to switch (the phone publishes the chosen list).
- **Offline**: the watch always shows the phone's last list. When the watch is away from the phone,
  ticks wait in the Data Layer and are applied when it is back. They are shown as "N not confirmed
  yet"; a put-back item carries "not confirmed" until the phone's next list confirms it. When the
  phone's list is older than 1 h the screen says how old it is.
- **Tile**: "N items left" plus the first three. Tap opens the app. It reads the same list.
- Dark theme only (Wear OS expects that). English and Spanish.

## How it works

```
 phone (Flutter app)                                   watch (this module)
 ShoppinglistCubit.onChange ─┐
 WearBridge.publish          ├─ /kitchenowl/shoppinglist  ──────────►  PhoneListenerService
 periodic worker (~30 min) ──┘   JSON snapshot                          WatchRepository (cache + merge)
                                                                         │ tap / undo / refresh / pick list
 WearActionsService  ◄──────────  /kitchenowl/actions/<uuid>  ◄──────────┘
   app open:   nudge Dart (MethodChannel)   JSON action, one DataItem each
   app closed: WearActionsWorker (expedited) → headless FlutterEngine → wearActionsMain
 Dart applies it with the normal transactions (queued when offline),
 deletes the DataItem, republishes the list
```

**Snapshot** (phone → watch), UTF-8 JSON, built by `lib/models/wear_snapshot.dart`:

```json
{"version":1,"household_id":9,"list_id":7,"list_name":"Groceries","updated_ms":1700000000000,
 "lists":[{"id":7,"name":"Groceries"}],
 "items":[{"id":1,"name":"Milk","description":"2 l","category":"Dairy"}]}
```

Items are sorted like the app's category view (category order, then name, uncategorized last). The
Data Layer allows 100 KB per item, so a huge list is cut to 90 KB (the last categories are dropped).

**Action** (watch → phone), `/kitchenowl/actions/<uuid>`:
`{type: remove|add|refresh|select_list, item_id?, item_name?, description?, list_id, created_ms}`.
`add` is the undo of `remove` (by name; adding what is already there does nothing, removing what is
already gone does nothing). The phone applies actions in `created_ms` order.

**Confirmation**: the phone applies an action, deletes its DataItem, then republishes. The watch treats
the deletion as "confirmed" and drops the action when the next snapshot arrives (so a ticked item does
not flash back between the two). Actions the phone never confirms are forgotten after 12 h.

The Data Layer only connects apps with the **same package name and signing key**, so the watch app uses
the phone app's `applicationId` (`com.tombursch.kitchenowl`) and the same `key.properties`.

## Phone side

`kitchenowl/lib/services/wear_bridge.dart` + `android/app/.../WearBridge.kt`, `WearActionsService.kt`,
`WearActionsWorker.kt`. Nothing to configure and no UI: with no watch paired it does nothing. The
phone app must have been opened once (logged in) so that the headless engine can connect.

## Build

The module is `:wear` of `kitchenowl/android`. `flutter build apk` only runs `:app` tasks and does not
build it. It needs the Flutter SDK (the root `settings.gradle.kts` reads `local.properties`), the Android
SDK 37 and JDK 17+.

```bash
cd kitchenowl/android
./gradlew :wear:testDebugUnitTest          # JVM unit tests
./gradlew :wear:assembleRelease \
  -PwearVersionName=0.1.0 -PwearVersionCode=1   # → build/wear/outputs/apk/release/wear-release.apk
```

(`kitchenowl/build/wear/...` because the root build redirects the build directories.) Release builds are
signed with `kitchenowl/android/key.properties`, the same file as the phone app (git-ignored); without
it the APK is unsigned. Check the certificate is the phone app's:

```bash
apksigner verify --print-certs wear-release.apk
```

In the fork's Docker setup (see `fork/build-apk.sh` on branch `fork/claude-md`) run the Gradle command in
the same container with its own source volume, after `flutter pub get` and writing `local.properties`
(`flutter.sdk`, `sdk.dir`). Do not run it at the same time as a phone build: they share the Gradle cache
and the memory of the Docker VM.

## Install on a Galaxy Watch (sideload)

1. Watch: **Settings → About watch → Software** → tap *Software version* 5 times to enable developer mode.
2. **Settings → Developer options** → turn on **ADB debugging** and **Debug over Wi-Fi** (or *Wireless
   debugging*). The watch and the PC must be on the same Wi-Fi.
3. Under *Wireless debugging* choose **Pair new device**: it shows an IP:port and a pairing code.
   ```bash
   adb pair <ip>:<pairing-port>        # enter the code
   adb connect <ip>:<debug-port>       # the port shown on the Wireless debugging screen
   adb -s <ip>:<debug-port> install kitchenowl-wear-<version>.apk
   ```
4. Install the matching phone APK (same key), open it once, open the KitchenOwl app on the watch. The
   list appears when the phone has published it. Add the tile from the tile carousel (long-press the
   watch face → swipe to the end → +).

To update, install again with `adb install -r` (same key, higher or equal version code).

## Tests

`./gradlew :wear:testDebugUnitTest`: snapshot parsing, the action wire format, category grouping, and
`WatchRepository` (optimistic merge, undo before and after sending, confirmation, restart and
reconcile, refresh and list switching, expiry). On the phone `flutter test test/models/wear_snapshot_test.dart`
covers the snapshot JSON (round trip, ordering, size limit) and action parsing.

Not covered by automated tests (needs a paired phone and watch or two emulators): the Data Layer
transport itself, the `WearableListenerService`, and the headless engine run by `WearActionsWorker`.

## Layout

```
wear/src/main/kotlin/com/tombursch/kitchenowl/wear/
  data/    Models, Parsing, Grouping, WatchRepository (cache, queue, optimistic merge), PrefsStore
  sync/    DataLayer.kt: DataLayerActionSink (writes actions), PhoneListenerService (snapshots, confirmations)
  ui/      MainActivity, ShoppingViewModel, Screens (Compose for Wear OS, Material 3)
  tile/    ShoppingTileService
  WearApp  ServiceLocator
```
