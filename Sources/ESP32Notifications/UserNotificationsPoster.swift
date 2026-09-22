// UserNotifications behind the `NotificationPoster` seam. A local
// notification that lands in Notification Center is exactly what iOS
// forwards to an ANCS consumer, so "send to the ESP32" is "post locally".

#if canImport(UserNotifications)
import Foundation
import UserNotifications

@MainActor
public final class UserNotificationsPoster: NSObject, NotificationPoster {
    private let center = UNUserNotificationCenter.current()
    private let prefix: String
    private let presentation: ForegroundPresentation

    /// - Parameters:
    ///   - identifierPrefix: the prefix `BLENotifications` puts on its ids.
    ///   - foregroundPresentation: anything but `.none` installs this object
    ///     as the notification center delegate. If the app has its own
    ///     delegate, pass `.none` and call `presentationOptions(for:)` from
    ///     its `willPresent`.
    public init(identifierPrefix: String, foregroundPresentation: ForegroundPresentation) {
        self.prefix = identifierPrefix
        self.presentation = foregroundPresentation
        super.init()
        if foregroundPresentation != .none, center.delegate == nil {
            center.delegate = self
        }
    }

    /// What a foreground `willPresent` should answer for a notification with
    /// this identifier so the ESP32 still receives it.
    public static func presentationOptions(
        for identifier: String, prefix: String, presentation: ForegroundPresentation = .list
    ) -> UNNotificationPresentationOptions {
        guard identifier.hasPrefix(prefix) else { return [] }
        switch presentation {
        case .none: return []
        case .list: return [.list]
        case .banner: return [.banner, .list, .sound]
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    public func post(_ notification: BLENotification, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.message
        if notification.sound {
            content.sound = .default
        }
        if let thread = notification.threadIdentifier {
            content.threadIdentifier = thread
        }
        if let category = notification.categoryIdentifier {
            content.categoryIdentifier = category
        }
        if !notification.userInfo.isEmpty {
            content.userInfo = notification.userInfo
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            throw LinkError.postFailed(error.localizedDescription)
        }
    }

    public func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func removeAll(withPrefix prefix: String) async {
        let delivered = await center.deliveredNotifications()
        let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
        if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}

extension UserNotificationsPoster: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(
            Self.presentationOptions(
                for: notification.request.identifier, prefix: prefix, presentation: presentation))
    }
}
#endif
