// The value types the link is built from. All Sendable, all Foundation-only.

import Foundation

/// A notification authored on the phone for the ESP32 to receive.
///
/// The ESP32 library fetches the app identifier, title, message and date of
/// every ANCS notification and fires its callback only once **both title
/// and message are non-empty** — so both are required here. `id` is stable
/// per topic if you want the module to see an update rather than a pile:
/// re-sending with the same id replaces the previous notification on the
/// phone, which the ESP32 sees as a remove followed by an add.
public struct BLENotification: Equatable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var message: String
    /// Play the default sound on the phone. The ESP32 sees the same
    /// notification either way (silent ones carry `EventFlags.silent`).
    public var sound: Bool
    /// Groups notifications in the phone's Notification Center.
    public var threadIdentifier: String?
    /// A `UNNotificationCategory` identifier registered by the app, if any.
    public var categoryIdentifier: String?
    /// Extra string payload stored on the phone-side notification.
    public var userInfo: [String: String]

    public init(
        id: String = UUID().uuidString,
        title: String,
        message: String,
        sound: Bool = false,
        threadIdentifier: String? = nil,
        categoryIdentifier: String? = nil,
        userInfo: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.sound = sound
        self.threadIdentifier = threadIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.userInfo = userInfo
    }

    /// Nil when the ESP32 library would deliver it; otherwise why not.
    public var validationError: LinkError? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyTitle
        }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyMessage
        }
        return nil
    }
}

public enum LinkError: Error, Equatable, Sendable, LocalizedError {
    case emptyTitle
    case emptyMessage
    case notificationsNotAuthorized
    case postFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "The ESP32 library ignores notifications without a title."
        case .emptyMessage:
            "The ESP32 library ignores notifications without a message."
        case .notificationsNotAuthorized:
            "Notification permission was not granted; the ESP32 receives nothing until it is."
        case .postFailed(let reason):
            "Could not post the notification: \(reason)"
        }
    }
}

/// What a BLE advertisement told us, reduced to what the link cares about.
public struct Advertisement: Equatable, Sendable, Hashable {
    public var localName: String?
    /// Uppercased UUID strings from the service-solicitation AD types.
    public var solicitedServiceUUIDs: [String]
    /// Uppercased UUID strings from the service AD types.
    public var serviceUUIDs: [String]
    public var rssi: Int

    public init(localName: String? = nil, solicitedServiceUUIDs: [String] = [], serviceUUIDs: [String] = [], rssi: Int = 0) {
        self.localName = localName
        self.solicitedServiceUUIDs = solicitedServiceUUIDs.map { $0.uppercased() }
        self.serviceUUIDs = serviceUUIDs.map { $0.uppercased() }
        self.rssi = rssi
    }

    /// True when the device asks the phone for ANCS — the fingerprint of the
    /// ESP32 library's advertisement.
    public var solicitsANCS: Bool {
        solicitedServiceUUIDs.contains(ANCS.serviceUUID)
    }
}

/// A peripheral seen while scanning.
public struct DiscoveredDevice: Identifiable, Equatable, Sendable, Hashable {
    public var id: UUID
    public var name: String?
    public var rssi: Int
    public var solicitsANCS: Bool
    public var lastSeen: Date

    public init(id: UUID, name: String?, rssi: Int, solicitsANCS: Bool, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.solicitsANCS = solicitsANCS
        self.lastSeen = lastSeen
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Unnamed device"
    }
}

/// Which devices `BLENotifications` will connect to on its own.
public struct DeviceFilter: Equatable, Sendable, Hashable {
    /// Exact advertised name to match (case-insensitive, trimmed). nil
    /// matches any name.
    public var deviceName: String?
    /// Only accept devices that solicit ANCS. Leave on unless your firmware
    /// advertises differently from the ESP32 library.
    public var requireANCSSolicitation: Bool

    public init(deviceName: String? = nil, requireANCSSolicitation: Bool = true) {
        self.deviceName = deviceName
        self.requireANCSSolicitation = requireANCSSolicitation
    }

    public func matches(_ advertisement: Advertisement) -> Bool {
        if requireANCSSolicitation, !advertisement.solicitsANCS { return false }
        guard let wanted = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty else {
            return true
        }
        guard let name = advertisement.localName?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return name.caseInsensitiveCompare(wanted) == .orderedSame
    }
}

/// State of the BLE link, the phone-side twin of `BLENotifications::State`
/// on the ESP32.
public enum LinkState: Equatable, Sendable, Hashable {
    /// `begin` has not been called (or `stop` was).
    case idle
    /// Bluetooth is off, unauthorized, or unsupported; `reason` says which.
    case unavailable(reason: String)
    case scanning
    case connecting(deviceName: String?)
    /// `notificationsAuthorized` is iOS's ANCS grant for this device: the
    /// "Share System Notifications" switch in the pairing sheet / Settings.
    case connected(deviceName: String?, notificationsAuthorized: Bool)
    case disconnected

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var connectedDeviceName: String? {
        if case .connected(let name, _) = self { return name }
        return nil
    }

    /// True only when the ESP32 is connected *and* iOS lets it read
    /// notifications.
    public var isDeliveringNotifications: Bool {
        if case .connected(_, let authorized) = self { return authorized }
        return false
    }

    /// Short human-readable status for a UI label.
    public var label: String {
        switch self {
        case .idle: "Off"
        case .unavailable(let reason): reason
        case .scanning: "Scanning"
        case .connecting(let name): "Connecting to \(name ?? "device")"
        case .connected(let name, let authorized):
            authorized
                ? "Connected to \(name ?? "device") · notifications on"
                : "Connected to \(name ?? "device") · notifications not allowed"
        case .disconnected: "Disconnected"
        }
    }
}

/// Bluetooth radio state, abstracted from CoreBluetooth so the link can be
/// driven without it.
public enum RadioState: Equatable, Sendable, Hashable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    var unavailableReason: String? {
        switch self {
        case .poweredOn, .unknown, .resetting: nil
        case .unsupported: "Bluetooth is not supported on this device"
        case .unauthorized: "Bluetooth permission was denied — allow it in Settings"
        case .poweredOff: "Bluetooth is off"
        }
    }
}
