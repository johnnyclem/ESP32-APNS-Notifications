# ESP32 Notifications for iOS

The iOS half of the ESP32 BLE notification link, as a Swift package.

This repository forked [Smartphone-Companions/ESP32-ANCS-Notifications](https://github.com/Smartphone-Companions/ESP32-ANCS-Notifications),
an Arduino library that runs **on the ESP32**: it advertises, solicits Apple's
Notification Center Service (ANCS) and receives the phone's notifications over
Bluetooth LE. That library is the *consumer* end and it is still what you flash
on the module (it lives in this repo's history up to commit `c71030e`, and
upstream).

This package is the *phone* end of the same link. iOS already ships the ANCS
server, so there is no protocol to write; what an app has to do is:

1. find the ESP32 (it advertises an ANCS service solicitation, not a service),
2. connect it and let iOS pair/authorize it for notifications,
3. keep that link alive across drops, backgrounding and relaunches,
4. author the notifications the module should receive, with the constraints the
   ESP32 library actually has.

`BLENotifications` does all four, and mirrors the ESP32 class of the same name:

| ESP32 (Arduino)                        | iPhone (this package)                      |
| -------------------------------------- | ------------------------------------------ |
| `begin(name)` — advertise as *name*    | `begin(deviceName:)` — find & connect *name* |
| `startAdvertising()`                   | `startScanning()`                          |
| `setConnectionStateChangedCallback`    | `onStateChanged` / observable `state`      |
| `setNotificationCallback` (receive)    | `send(_:)` (author)                        |
| `setRemovedCallback`                   | `remove(id:)`                              |
| `stop()`                               | `stop()`                                   |
| `getNotificationCategoryDescription`   | `NotificationCategory.description`         |

## Requirements

- iOS 17+ (macOS 14+ compiles the package, but ANCS itself is iOS-only).
- Swift 6 tools; the package is Swift 6 language mode and `@MainActor`.
- `NSBluetoothAlwaysUsageDescription` in Info.plist.
- `bluetooth-central` in `UIBackgroundModes` if you set a `restoreIdentifier`
  (recommended: it is what keeps the module fed while the phone is in a pocket).

## Install

Swift Package Manager, by URL or as a local/sibling checkout:

```swift
.package(url: "https://github.com/johnnyclem/ESP32-APNS-Notifications", branch: "master")
// or
.package(path: "../ESP32-APNS-Notifications")
```

Product and module are both `ESP32Notifications`.

## Usage

```swift
import ESP32Notifications

@MainActor
final class ModuleLink {
    let notifications: BLENotifications

    init() {
        var config = BLENotifications.Configuration()
        config.deviceName = "NEON LINK"                       // as flashed in begin(name) on the ESP32
        config.restoreIdentifier = "com.example.app.esp32"    // survives suspension / relaunch
        config.notificationIdentifierPrefix = "module."
        notifications = BLENotifications(configuration: config)

        notifications.onStateChanged = { state in
            print(state.label)   // "Connected to NEON LINK · notifications on"
        }
    }

    func start() async {
        await notifications.requestNotificationAuthorization()
        notifications.begin()   // reconnects the remembered module, else scans
    }

    func tempoChanged(bpm: Double) async throws {
        // Same id every time → the module sees remove + add, not a pile.
        try await notifications.send(title: "Link", message: "\(bpm) BPM", id: "session")
    }
}
```

`state` is `@Observable`, so a SwiftUI view can read it directly. For a device
picker, set `configuration.autoConnect = false`, call `startScanning()`, list
`discovered`, and call `connect(_:)` on the one the user taps; the choice is
remembered in `UserDefaults` and reconnected at the next `begin()`.

### What the ESP32 receives

A notification you `send` reaches the module's callback as:

| `Notification` field on the ESP32 | Comes from                                    |
| --------------------------------- | --------------------------------------------- |
| `title`                           | `BLENotification.title`                       |
| `message`                         | `BLENotification.message`                     |
| `type`                            | your app's bundle identifier                  |
| `category`                        | assigned by iOS (`other` for most apps)       |
| `time`                            | when it was posted                            |
| `uuid`                            | iOS's per-notification ANCS id                |

The ESP32 library only fires its callback once it has a **non-empty title and
message**, so `send` refuses either being blank (`LinkError`). It also only
fetches those two attributes plus app id and date — subtitles never reach it.

`remove(id:)` clears the notification on the phone; the module gets the
"removed" event. Re-sending with the same `id` replaces the earlier one.

### Pairing and authorization

The first connection raises iOS's pairing sheet (the ESP32 library asks for
bonding). The sheet includes **Share System Notifications**; that switch is
what ANCS needs, and the link reports it as
`LinkState.connected(notificationsAuthorized:)`. If the user declines, they can
turn it on later in Settings → Bluetooth → the device. Pairing from Settings
directly also works; the app then just connects.

`Configuration.requiresANCS` (default on) passes
`CBConnectPeripheralOptionRequiresANCS`, which makes iOS raise the sheet for a
device that is connected but not yet authorized.

### Foreground delivery

iOS drops a local notification posted while the app is in front unless a
`UNUserNotificationCenterDelegate` says otherwise — and a dropped notification
never reaches ANCS. By default the package installs a delegate that answers
`.list` for its own identifiers (added to Notification Center silently). If
your app already owns that delegate, set `foregroundPresentation = .none` and
return `UserNotificationsPoster.presentationOptions(for:prefix:)` from your
own `willPresent`.

### Background behaviour

- Scanning is foreground-only: the ESP32 advertises an ANCS *solicitation*,
  which CoreBluetooth cannot filter a background scan on.
- Reconnecting is not: a pending `connect` completes whenever the remembered
  module comes back into range, in the background too, given the
  `bluetooth-central` mode and a `restoreIdentifier`.
- After a drop the link re-issues the connect immediately; after a failed
  connect it re-evaluates two seconds later.

## Layout

```
Sources/ESP32Notifications/
  ANCS.swift                     ANCS vocabulary (categories, event ids, flags, attribute ids)
  ANCSWire.swift                 The byte layouts the ESP32 firmware encodes/decodes
  Models.swift                   BLENotification, DiscoveredDevice, DeviceFilter, LinkState
  Seams.swift                    CentralTransport / NotificationPoster / DeviceMemory protocols
  BLENotifications.swift         The link state machine (portable, tested with fakes)
  CoreBluetoothTransport.swift   CoreBluetooth adapter          (#if canImport(CoreBluetooth))
  UserNotificationsPoster.swift  UserNotifications adapter      (#if canImport(UserNotifications))
  BLENotifications+Platform.swift  The one-line `init(configuration:)` for apps
Tests/ESP32NotificationsTests/   29 tests; `swift test` on Linux or macOS
```

`ANCSWire` is here for the same reason the enums are: it is the contract with
the firmware. `ANCS.ControlPoint.esp32DefaultRequests` encodes byte-for-byte the
writes `retrieveExtraNotificationData` makes, and the tests pin them.

## License

GPL-3.0, inherited from the fork. Note this before linking it into a closed
App Store binary.
