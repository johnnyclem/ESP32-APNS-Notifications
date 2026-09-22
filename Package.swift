// swift-tools-version: 6.0

// ESP32Notifications — the iOS half of the ESP32 BLE notification link.
//
// The Arduino library this repo forked (Smartphone-Companions/ESP32-ANCS-
// Notifications) runs *on the ESP32*: it advertises, solicits Apple's
// Notification Center Service (ANCS), and receives the phone's
// notifications over BLE. This package is the phone side of that same
// link: it finds the ESP32, connects and pairs it so iOS starts feeding it
// ANCS, keeps the link alive across disconnects and app restarts, and lets
// the app author notifications that the ESP32 will receive.
//
// Layout: everything that can be reasoned about without a radio (the link
// state machine, device filter, ANCS wire codec, notification model) is
// Foundation-only and tested on Linux. CoreBluetooth and UserNotifications
// live behind `#if canImport` in two thin adapters.

import PackageDescription

let package = Package(
    name: "ESP32Notifications",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ESP32Notifications", targets: ["ESP32Notifications"])
    ],
    targets: [
        .target(name: "ESP32Notifications"),
        .testTarget(
            name: "ESP32NotificationsTests",
            dependencies: ["ESP32Notifications"]
        ),
    ]
)
