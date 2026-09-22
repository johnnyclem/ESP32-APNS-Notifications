// The ANCS byte layouts the ESP32 firmware encodes and decodes
// (`ancs_ble_client.cpp`). Kept here so the phone side can test, simulate,
// and document exactly what the module will see — none of this touches a
// radio, and all of it runs on Linux.

import Foundation

extension ANCS {
    /// One 8-byte packet from the Notification Source characteristic.
    public struct NotificationSourcePacket: Equatable, Sendable, Hashable {
        public static let length = 8

        public var eventID: EventID
        public var eventFlags: EventFlags
        public var category: NotificationCategory
        public var categoryCount: UInt8
        public var notificationUID: UInt32

        public init(
            eventID: EventID,
            eventFlags: EventFlags = [],
            category: NotificationCategory,
            categoryCount: UInt8 = 0,
            notificationUID: UInt32
        ) {
            self.eventID = eventID
            self.eventFlags = eventFlags
            self.category = category
            self.categoryCount = categoryCount
            self.notificationUID = notificationUID
        }

        /// Decodes a packet; nil if it is short or carries an unknown event
        /// or category value.
        public init?(bytes: [UInt8]) {
            guard bytes.count >= Self.length,
                  let event = EventID(rawValue: bytes[0]),
                  let category = NotificationCategory(rawValue: bytes[2])
            else { return nil }
            self.eventID = event
            self.eventFlags = EventFlags(rawValue: bytes[1])
            self.category = category
            self.categoryCount = bytes[3]
            self.notificationUID = UInt32(littleEndian: bytes[4...7])
        }

        public var bytes: [UInt8] {
            [eventID.rawValue, eventFlags.rawValue, category.rawValue, categoryCount]
                + notificationUID.littleEndianBytes
        }
    }

    /// Commands written to the Control Point characteristic.
    public enum ControlPoint {
        public struct AttributeRequest: Equatable, Sendable, Hashable {
            public var id: NotificationAttributeID
            /// Only sent for attributes that take one (title/subtitle/message).
            public var maxLength: UInt16?

            public init(_ id: NotificationAttributeID, maxLength: UInt16? = nil) {
                self.id = id
                self.maxLength = maxLength
            }
        }

        /// The ESP32 library's attribute fetch, one write per attribute:
        /// app identifier, title (4096 max), message (4096 max), date.
        public static let esp32DefaultRequests: [AttributeRequest] = [
            AttributeRequest(.appIdentifier),
            AttributeRequest(.title, maxLength: 0x1000),
            AttributeRequest(.message, maxLength: 0x1000),
            AttributeRequest(.date),
        ]

        /// `CommandIDGetNotificationAttributes` for one notification.
        public static func getNotificationAttributes(
            uid: UInt32, attributes: [AttributeRequest]
        ) -> [UInt8] {
            var out: [UInt8] = [CommandID.getNotificationAttributes.rawValue]
            out += uid.littleEndianBytes
            for attribute in attributes {
                out.append(attribute.id.rawValue)
                if attribute.id.takesMaxLength {
                    out += (attribute.maxLength ?? 0x1000).littleEndianBytes
                }
            }
            return out
        }

        /// `CommandIDPerformNotificationAction` — what `actionPositive` /
        /// `actionNegative` on the ESP32 write.
        public static func performAction(uid: UInt32, action: Action) -> [UInt8] {
            [CommandID.performNotificationAction.rawValue] + uid.littleEndianBytes + [action.rawValue]
        }
    }

    /// A Data Source response to `getNotificationAttributes`, reassembled
    /// from however many BLE notifications it took to arrive.
    public struct DataSourceResponse: Equatable, Sendable {
        public var commandID: CommandID
        public var notificationUID: UInt32
        public var attributes: [NotificationAttributeID: String]

        public init(commandID: CommandID, notificationUID: UInt32, attributes: [NotificationAttributeID: String]) {
            self.commandID = commandID
            self.notificationUID = notificationUID
            self.attributes = attributes
        }

        /// Encodes a response the way iOS does: header, then
        /// `[id][len LE16][utf8]` per attribute in the order given.
        public static func encode(
            commandID: CommandID = .getNotificationAttributes,
            notificationUID: UInt32,
            attributes: [(NotificationAttributeID, String)]
        ) -> [UInt8] {
            var out: [UInt8] = [commandID.rawValue] + notificationUID.littleEndianBytes
            for (id, value) in attributes {
                let utf8 = Array(value.utf8)
                out.append(id.rawValue)
                out += UInt16(clamping: utf8.count).littleEndianBytes
                out += utf8
            }
            return out
        }

        /// Parses a complete response. Returns nil if the buffer is
        /// truncated mid-attribute — keep accumulating and try again.
        public init?(bytes: [UInt8]) {
            guard bytes.count >= 5, let command = CommandID(rawValue: bytes[0]) else { return nil }
            commandID = command
            notificationUID = UInt32(littleEndian: bytes[1...4])
            var attributes: [NotificationAttributeID: String] = [:]
            var index = 5
            while index < bytes.count {
                guard index + 3 <= bytes.count else { return nil }
                let rawID = bytes[index]
                let length = Int(UInt16(littleEndian: bytes[(index + 1)...(index + 2)]))
                let start = index + 3
                guard start + length <= bytes.count else { return nil }
                let value = String(decoding: bytes[start..<(start + length)], as: UTF8.self)
                if let id = NotificationAttributeID(rawValue: rawID) {
                    attributes[id] = value
                }
                index = start + length
            }
            self.attributes = attributes
        }

        /// True once the ESP32 library would fire its "arrived" callback:
        /// it waits for a non-empty title *and* a non-empty message.
        public var satisfiesESP32Callback: Bool {
            !(attributes[.title] ?? "").isEmpty && !(attributes[.message] ?? "").isEmpty
        }
    }
}

extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 24) & 0xFF)]
    }

    init(littleEndian slice: ArraySlice<UInt8>) {
        var value: UInt32 = 0
        for (offset, byte) in slice.enumerated() where offset < 4 {
            value |= UInt32(byte) << (8 * UInt32(offset))
        }
        self = value
    }
}

extension UInt16 {
    var littleEndianBytes: [UInt8] {
        [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF)]
    }

    init(littleEndian slice: ArraySlice<UInt8>) {
        var value: UInt16 = 0
        for (offset, byte) in slice.enumerated() where offset < 2 {
            value |= UInt16(byte) << (8 * UInt16(offset))
        }
        self = value
    }
}
