// Apple Notification Center Service (ANCS) vocabulary, as the ESP32 firmware
// sees it. These mirror `ble_notification.h` in the Arduino library this
// repo forked, so the two halves of the link speak the same names.

import Foundation

/// Notification category, assigned by iOS to every notification it hands to
/// an ANCS consumer. Third-party apps cannot choose their category — iOS
/// classifies them — so on the send side this is informational: it is what
/// the ESP32's `notification->category` will read.
public enum NotificationCategory: UInt8, CaseIterable, Sendable, Codable, Hashable {
    case other = 0
    case incomingCall = 1
    case missedCall = 2
    case voicemail = 3
    case social = 4
    case schedule = 5
    case email = 6
    case news = 7
    case healthAndFitness = 8
    case businessAndFinance = 9
    case location = 10
    case entertainment = 11

    /// The English description the ESP32 library returns from
    /// `getNotificationCategoryDescription`, verbatim.
    public var description: String {
        switch self {
        case .other: "other"
        case .incomingCall: "incoming call"
        case .missedCall: "missed call"
        case .voicemail: "voicemail"
        case .social: "social"
        case .schedule: "schedule"
        case .email: "email"
        case .news: "news"
        case .healthAndFitness: "health and fitness"
        case .businessAndFinance: "business and finance"
        case .location: "location"
        case .entertainment: "entertainment"
        }
    }
}

/// ANCS constants and enums specific to the Apple service.
public enum ANCS {
    /// The primary service UUID. The ESP32 puts this in its advertisement as
    /// a *service solicitation* (AD type 0x15), which is how the phone side
    /// recognises a notification consumer in a scan.
    public static let serviceUUID = "7905F431-B5CE-4E99-A40F-4B1E122D00D0"
    public static let notificationSourceUUID = "9FBF120D-6301-42D9-8C58-25E699A21DBD"
    public static let controlPointUUID = "69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9"
    public static let dataSourceUUID = "22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB"

    public enum EventID: UInt8, Sendable, Hashable {
        case added = 0
        case modified = 1
        case removed = 2
    }

    public struct EventFlags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let silent = EventFlags(rawValue: 1 << 0)
        public static let important = EventFlags(rawValue: 1 << 1)
        public static let preExisting = EventFlags(rawValue: 1 << 2)
        public static let positiveAction = EventFlags(rawValue: 1 << 3)
        public static let negativeAction = EventFlags(rawValue: 1 << 4)
    }

    public enum Action: UInt8, Sendable, Hashable {
        case positive = 0
        case negative = 1
    }

    public enum CommandID: UInt8, Sendable, Hashable {
        case getNotificationAttributes = 0
        case getAppAttributes = 1
        case performNotificationAction = 2
    }

    public enum NotificationAttributeID: UInt8, Sendable, Hashable {
        case appIdentifier = 0
        case title = 1
        case subtitle = 2
        case message = 3
        case messageSize = 4
        case date = 5
        case positiveActionLabel = 6
        case negativeActionLabel = 7

        /// Attributes whose request carries a 2-byte max-length parameter.
        public var takesMaxLength: Bool {
            switch self {
            case .title, .subtitle, .message: true
            default: false
            }
        }
    }
}
