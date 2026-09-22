// The one-line constructor for apps: CoreBluetooth + UserNotifications +
// UserDefaults. Everything else in the package builds without either.

#if canImport(CoreBluetooth) && canImport(UserNotifications)
import Foundation

extension BLENotifications {
    /// The stock link: CoreBluetooth central, local notifications, device
    /// remembered in `UserDefaults.standard`.
    public convenience init(configuration: Configuration = Configuration()) {
        self.init(
            configuration: configuration,
            transport: CoreBluetoothTransport(
                restoreIdentifier: configuration.restoreIdentifier,
                requiresANCS: configuration.requiresANCS),
            poster: UserNotificationsPoster(
                identifierPrefix: configuration.notificationIdentifierPrefix,
                foregroundPresentation: configuration.foregroundPresentation),
            memory: UserDefaultsDeviceMemory())
    }
}
#endif
