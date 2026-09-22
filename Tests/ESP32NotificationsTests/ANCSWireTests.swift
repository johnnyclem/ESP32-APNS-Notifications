import XCTest
@testable import ESP32Notifications

final class ANCSWireTests: XCTestCase {
    func testNotificationSourcePacketRoundTrip() {
        let packet = ANCS.NotificationSourcePacket(
            eventID: .added, eventFlags: [.silent, .negativeAction],
            category: .social, categoryCount: 3, notificationUID: 0x0102_0304)
        XCTAssertEqual(packet.bytes, [0x00, 0x11, 0x04, 0x03, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(ANCS.NotificationSourcePacket(bytes: packet.bytes), packet)
    }

    func testNotificationSourcePacketRejectsShortOrUnknown() {
        XCTAssertNil(ANCS.NotificationSourcePacket(bytes: [0, 0, 0, 0]))
        XCTAssertNil(ANCS.NotificationSourcePacket(bytes: [9, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertNil(ANCS.NotificationSourcePacket(bytes: [0, 0, 99, 0, 0, 0, 0, 0]))
    }

    /// The exact writes `retrieveExtraNotificationData` makes on the ESP32,
    /// concatenated: `{0x0, uid[0..3], AttrID}` and `{..., AttrID, 0x0, 0x10}`.
    func testGetNotificationAttributesMatchesFirmwareWrites() {
        let uid: UInt32 = 0xAABB_CCDD
        let bytes = ANCS.ControlPoint.getNotificationAttributes(
            uid: uid, attributes: ANCS.ControlPoint.esp32DefaultRequests)
        XCTAssertEqual(
            bytes,
            [0x00, 0xDD, 0xCC, 0xBB, 0xAA,
             0x00,               // app identifier
             0x01, 0x00, 0x10,   // title, max 0x1000
             0x03, 0x00, 0x10,   // message, max 0x1000
             0x05])              // date
    }

    func testPerformActionMatchesFirmwareWrite() {
        XCTAssertEqual(
            ANCS.ControlPoint.performAction(uid: 7, action: .negative),
            [0x02, 0x07, 0x00, 0x00, 0x00, 0x01])
        XCTAssertEqual(
            ANCS.ControlPoint.performAction(uid: 0x0100, action: .positive),
            [0x02, 0x00, 0x01, 0x00, 0x00, 0x00])
    }

    func testDataSourceResponseRoundTripAndCompleteness() {
        let bytes = ANCS.DataSourceResponse.encode(
            notificationUID: 42,
            attributes: [(.appIdentifier, "com.neonlink.neon"), (.title, "NEON"), (.message, "3 peers · 120.0 BPM")])
        let response = ANCS.DataSourceResponse(bytes: bytes)
        XCTAssertEqual(response?.commandID, .getNotificationAttributes)
        XCTAssertEqual(response?.notificationUID, 42)
        XCTAssertEqual(response?.attributes[.appIdentifier], "com.neonlink.neon")
        XCTAssertEqual(response?.attributes[.title], "NEON")
        XCTAssertEqual(response?.attributes[.message], "3 peers · 120.0 BPM")
        XCTAssertEqual(response?.satisfiesESP32Callback, true)

        let titleOnly = ANCS.DataSourceResponse.encode(notificationUID: 1, attributes: [(.title, "x")])
        XCTAssertEqual(ANCS.DataSourceResponse(bytes: titleOnly)?.satisfiesESP32Callback, false)
    }

    func testDataSourceResponseTruncatedReturnsNil() {
        let bytes = ANCS.DataSourceResponse.encode(notificationUID: 1, attributes: [(.title, "hello")])
        XCTAssertNil(ANCS.DataSourceResponse(bytes: Array(bytes.dropLast())))
        XCTAssertNil(ANCS.DataSourceResponse(bytes: Array(bytes.prefix(6))))
        XCTAssertNotNil(ANCS.DataSourceResponse(bytes: Array(bytes.prefix(5))))
    }

    func testCategoryDescriptionsMatchFirmware() {
        let expected = [
            "other", "incoming call", "missed call", "voicemail", "social", "schedule",
            "email", "news", "health and fitness", "business and finance", "location", "entertainment",
        ]
        XCTAssertEqual(NotificationCategory.allCases.map(\.description), expected)
        XCTAssertEqual(NotificationCategory.allCases.map(\.rawValue), Array(0...11))
    }
}
