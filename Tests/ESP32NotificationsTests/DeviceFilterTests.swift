import XCTest
@testable import ESP32Notifications

final class DeviceFilterTests: XCTestCase {
    private let ancs = Advertisement(localName: "NEON LINK", solicitedServiceUUIDs: [ANCS.serviceUUID.lowercased()])
    private let plain = Advertisement(localName: "NEON LINK")

    func testDefaultRequiresSolicitationAndAcceptsAnyName() {
        let filter = DeviceFilter()
        XCTAssertTrue(filter.matches(ancs))
        XCTAssertFalse(filter.matches(plain))
        XCTAssertTrue(filter.matches(Advertisement(localName: nil, solicitedServiceUUIDs: [ANCS.serviceUUID])))
    }

    func testNameMatchIsCaseInsensitiveAndTrimmed() {
        let filter = DeviceFilter(deviceName: " neon link ")
        XCTAssertTrue(filter.matches(ancs))
        XCTAssertFalse(filter.matches(Advertisement(localName: "Other", solicitedServiceUUIDs: [ANCS.serviceUUID])))
        XCTAssertFalse(filter.matches(Advertisement(localName: nil, solicitedServiceUUIDs: [ANCS.serviceUUID])))
    }

    func testSolicitationCanBeWaived() {
        let filter = DeviceFilter(deviceName: "NEON LINK", requireANCSSolicitation: false)
        XCTAssertTrue(filter.matches(plain))
    }

    func testAdvertisementUppercasesUUIDs() {
        XCTAssertTrue(ancs.solicitsANCS)
        XCTAssertEqual(ancs.solicitedServiceUUIDs, [ANCS.serviceUUID])
    }

    func testNotificationValidation() {
        XCTAssertNil(BLENotification(title: "a", message: "b").validationError)
        XCTAssertEqual(BLENotification(title: " ", message: "b").validationError, .emptyTitle)
        XCTAssertEqual(BLENotification(title: "a", message: "").validationError, .emptyMessage)
    }

    func testStateLabels() {
        XCTAssertEqual(LinkState.connected(deviceName: "NEON", notificationsAuthorized: true).label,
                       "Connected to NEON · notifications on")
        XCTAssertTrue(LinkState.connected(deviceName: nil, notificationsAuthorized: true).isDeliveringNotifications)
        XCTAssertFalse(LinkState.connected(deviceName: nil, notificationsAuthorized: false).isDeliveringNotifications)
        XCTAssertEqual(LinkState.unavailable(reason: "Bluetooth is off").label, "Bluetooth is off")
    }
}
