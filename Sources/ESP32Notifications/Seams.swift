// The two seams between the portable link logic and the platform: a BLE
// central and a notification poster. CoreBluetooth and UserNotifications
// implement them on Apple platforms; the tests implement them with fakes.

import Foundation

/// A BLE central, reduced to the calls the link needs. Everything is
/// main-actor: CoreBluetooth is created on the main queue and reports there.
@MainActor
public protocol CentralTransport: AnyObject {
    var delegate: CentralTransportDelegate? { get set }
    var radioState: RadioState { get }

    func startScan()
    func stopScan()

    /// True if the system still knows this peripheral (it was seen in a
    /// scan, restored, or can be retrieved by identifier). Only meaningful
    /// while the radio is powered on.
    func hasKnownPeripheral(id: UUID) -> Bool
    func knownPeripheralName(id: UUID) -> String?
    func connect(id: UUID)
    func disconnect(id: UUID)
    /// iOS's ANCS grant for the peripheral (false where unknown or not iOS).
    func isANCSAuthorized(id: UUID) -> Bool
}

@MainActor
public protocol CentralTransportDelegate: AnyObject {
    func radioStateChanged(_ state: RadioState)
    func didDiscover(id: UUID, advertisement: Advertisement)
    func didConnect(id: UUID, name: String?)
    func didFailToConnect(id: UUID, error: String?)
    func didDisconnect(id: UUID, error: String?)
    func ancsAuthorizationChanged(id: UUID, authorized: Bool)
    /// State restoration handed back peripherals; `connected` are the ones
    /// the system reports as still connected.
    func didRestore(connected: [UUID])
}

/// How a notification posted while the app is in the foreground shows on
/// the phone. Whatever the choice, it must land in Notification Center for
/// the ESP32 to receive it — `.none` is only for apps that run their own
/// `UNUserNotificationCenterDelegate` and answer `willPresent` themselves.
public enum ForegroundPresentation: Equatable, Sendable {
    /// Do not install a delegate. See `UserNotificationsPoster.presentationOptions`.
    case none
    /// Add to Notification Center silently (no banner, no sound). Default.
    case list
    /// Banner, list, and sound — the same as a background delivery.
    case banner
}

/// Posts the phone-side notifications that the ESP32 receives over ANCS.
@MainActor
public protocol NotificationPoster: AnyObject {
    func requestAuthorization() async -> Bool
    func isAuthorized() async -> Bool
    func post(_ notification: BLENotification, identifier: String) async throws
    func remove(identifiers: [String])
    func removeAll(withPrefix prefix: String) async
}

/// Remembers the paired device between launches.
@MainActor
public protocol DeviceMemory: AnyObject {
    var rememberedDeviceID: UUID? { get set }
    var rememberedDeviceName: String? { get set }
}

/// `UserDefaults`-backed device memory.
@MainActor
public final class UserDefaultsDeviceMemory: DeviceMemory {
    private let defaults: UserDefaults
    private let idKey: String
    private let nameKey: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "esp32notifications") {
        self.defaults = defaults
        self.idKey = "\(keyPrefix).deviceID"
        self.nameKey = "\(keyPrefix).deviceName"
    }

    public var rememberedDeviceID: UUID? {
        get { defaults.string(forKey: idKey).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: idKey)
            } else {
                defaults.removeObject(forKey: idKey)
            }
        }
    }

    public var rememberedDeviceName: String? {
        get { defaults.string(forKey: nameKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: nameKey)
            } else {
                defaults.removeObject(forKey: nameKey)
            }
        }
    }
}

/// Forgets everything at the end of the process. For tests and previews.
@MainActor
public final class InMemoryDeviceMemory: DeviceMemory {
    public var rememberedDeviceID: UUID?
    public var rememberedDeviceName: String?
    public init(rememberedDeviceID: UUID? = nil, rememberedDeviceName: String? = nil) {
        self.rememberedDeviceID = rememberedDeviceID
        self.rememberedDeviceName = rememberedDeviceName
    }
}
