import XCTest
@testable import ESP32Notifications

@MainActor
final class BLENotificationsTests: XCTestCase {
    private let esp = UUID()

    func testBeginBeforePowerOnWaitsThenScans() {
        let h = Harness()
        h.link.begin(deviceName: "NEON LINK")
        XCTAssertEqual(h.link.state, .idle)
        XCTAssertFalse(h.transport.scanning)

        h.transport.powerOn()
        XCTAssertEqual(h.link.state, .scanning)
        XCTAssertTrue(h.transport.scanning)
    }

    func testAutoConnectsToMatchingDeviceAndRemembersIt() async throws {
        let h = Harness()
        h.transport.powerOn()
        h.link.begin(deviceName: "NEON LINK")

        h.transport.advertise(id: UUID(), name: "Some Headphones", solicitsANCS: false)
        h.transport.advertise(id: UUID(), name: "Other ANCS Watch")
        XCTAssertEqual(h.link.state, .scanning)
        XCTAssertEqual(h.link.discovered.count, 2)

        h.transport.advertise(id: esp, name: "NEON LINK", rssi: -40)
        XCTAssertEqual(h.link.state, .connecting(deviceName: "NEON LINK"))
        XCTAssertEqual(h.transport.connectCalls, [esp])
        XCTAssertFalse(h.transport.scanning)
        XCTAssertEqual(h.link.discovered.first?.id, esp, "strongest signal sorts first")

        h.transport.ancsAuthorized.insert(esp)
        h.transport.completeConnect(id: esp)
        XCTAssertEqual(h.link.state, .connected(deviceName: "NEON LINK", notificationsAuthorized: true))
        XCTAssertEqual(h.memory.rememberedDeviceID, esp)
        XCTAssertEqual(h.memory.rememberedDeviceName, "NEON LINK")
        XCTAssertEqual(h.states, [.scanning, .connecting(deviceName: "NEON LINK"),
                                  .connected(deviceName: "NEON LINK", notificationsAuthorized: true)])
    }

    func testAnyANCSDeviceWhenNoNameGiven() {
        let h = Harness()
        h.transport.powerOn()
        h.link.begin()
        h.transport.advertise(id: UUID(), name: "Speaker", solicitsANCS: false)
        XCTAssertEqual(h.link.state, .scanning)
        h.transport.advertise(id: esp, name: nil)
        XCTAssertEqual(h.link.state, .connecting(deviceName: nil))
    }

    func testPickerModeDoesNotAutoConnect() {
        let h = Harness { $0.autoConnect = false }
        h.transport.powerOn()
        h.link.begin()
        h.transport.advertise(id: esp, name: "NEON LINK")
        XCTAssertEqual(h.link.state, .scanning)
        XCTAssertTrue(h.transport.connectCalls.isEmpty)

        h.link.connect(h.link.discovered[0])
        XCTAssertEqual(h.transport.connectCalls, [esp])
        XCTAssertEqual(h.link.state, .connecting(deviceName: "NEON LINK"))
    }

    func testRememberedDeviceReconnectsWithoutScanning() {
        let memory = InMemoryDeviceMemory(rememberedDeviceID: esp, rememberedDeviceName: "NEON LINK")
        let h = Harness(memory: memory)
        h.transport.known[esp] = "NEON LINK"
        h.transport.powerOn()
        h.link.begin()
        XCTAssertEqual(h.transport.connectCalls, [esp])
        XCTAssertEqual(h.transport.scanStarts, 0)
        XCTAssertEqual(h.link.state, .connecting(deviceName: "NEON LINK"))
        h.transport.completeConnect(id: esp)
        XCTAssertEqual(h.link.state, .connected(deviceName: "NEON LINK", notificationsAuthorized: false))
    }

    func testRememberedButUnknownToSystemFallsBackToScan() {
        let memory = InMemoryDeviceMemory(rememberedDeviceID: esp, rememberedDeviceName: "NEON LINK")
        let h = Harness(memory: memory)
        h.transport.powerOn()
        h.link.begin()
        XCTAssertEqual(h.link.state, .scanning)
        // Only the remembered device is auto-connected; a different ANCS
        // device is listed, not taken.
        h.transport.advertise(id: UUID(), name: "NEON LINK")
        XCTAssertEqual(h.link.state, .scanning)
        h.transport.advertise(id: esp, name: "NEON LINK")
        XCTAssertEqual(h.transport.connectCalls, [esp])
    }

    func testDropReconnectsImmediately() {
        let h = connected()
        h.transport.drop(id: esp)
        XCTAssertEqual(h.link.state, .connecting(deviceName: "NEON LINK"))
        XCTAssertEqual(h.transport.connectCalls, [esp, esp])
        XCTAssertEqual(h.link.lastError, "Peripheral went away")
        h.transport.completeConnect(id: esp)
        XCTAssertTrue(h.link.isConnected)
    }

    func testManualDisconnectStaysDown() {
        let h = connected()
        h.link.disconnect()
        XCTAssertEqual(h.transport.disconnectCalls, [esp])
        h.transport.drop(id: esp, error: nil)
        XCTAssertEqual(h.link.state, .disconnected)
        XCTAssertEqual(h.transport.connectCalls, [esp])

        h.link.reconnect()
        XCTAssertEqual(h.transport.connectCalls, [esp, esp])
    }

    func testForgetDeviceClearsMemoryAndDisconnects() {
        let h = connected()
        h.link.forgetDevice()
        XCTAssertEqual(h.transport.disconnectCalls, [esp])
        XCTAssertNil(h.memory.rememberedDeviceID)
        XCTAssertNil(h.link.rememberedDevice)
        h.transport.drop(id: esp, error: nil)
        XCTAssertEqual(h.link.state, .disconnected)
    }

    func testPowerOffAndBackReconnects() {
        let h = connected()
        h.transport.powerOff()
        XCTAssertEqual(h.link.state, .unavailable(reason: "Bluetooth is off"))
        h.transport.powerOn()
        XCTAssertEqual(h.link.state, .connecting(deviceName: "NEON LINK"))
        XCTAssertEqual(h.transport.connectCalls, [esp, esp])
    }

    func testANCSAuthorizationUpdatesState() {
        let h = connected()
        XCTAssertFalse(h.link.state.isDeliveringNotifications)
        h.transport.delegate?.ancsAuthorizationChanged(id: esp, authorized: true)
        XCTAssertEqual(h.link.state, .connected(deviceName: "NEON LINK", notificationsAuthorized: true))
        h.transport.delegate?.ancsAuthorizationChanged(id: UUID(), authorized: false)
        XCTAssertTrue(h.link.state.isDeliveringNotifications)
    }

    func testRestoreAdoptsConnectedRememberedDevice() {
        let memory = InMemoryDeviceMemory(rememberedDeviceID: esp, rememberedDeviceName: "NEON LINK")
        let h = Harness(memory: memory)
        h.transport.known[esp] = "NEON LINK"
        h.transport.ancsAuthorized.insert(esp)
        h.transport.delegate?.didRestore(connected: [esp])
        XCTAssertEqual(h.link.state, .connected(deviceName: "NEON LINK", notificationsAuthorized: true))
        // The radio reports powered-on afterwards; nothing to redo.
        h.transport.powerOn()
        XCTAssertTrue(h.transport.connectCalls.isEmpty)
        XCTAssertTrue(h.link.isConnected)
    }

    func testStopGoesIdle() {
        let h = connected()
        h.link.stop()
        XCTAssertEqual(h.link.state, .idle)
        XCTAssertEqual(h.transport.disconnectCalls, [esp])
        h.transport.drop(id: esp, error: nil)
        XCTAssertEqual(h.link.state, .disconnected)
        XCTAssertEqual(h.transport.connectCalls, [esp], "stopped links do not reconnect")
    }

    func testSendPrefixesIdentifierAndValidates() async throws {
        let h = Harness { $0.notificationIdentifierPrefix = "neon." }
        let id = try await h.link.send(title: "NEON", message: "3 peers", id: "session")
        XCTAssertEqual(id, "neon.session")
        XCTAssertEqual(h.poster.posted.map(\.1), ["neon.session"])
        XCTAssertEqual(h.poster.posted.first?.0.message, "3 peers")

        do {
            _ = try await h.link.send(title: "", message: "x")
            XCTFail("expected validation error")
        } catch let error as LinkError {
            XCTAssertEqual(error, .emptyTitle)
        }
        XCTAssertEqual(h.poster.posted.count, 1)

        h.link.remove(id: "session")
        XCTAssertEqual(h.poster.removed, ["neon.session"])
        await h.link.removeAll()
        XCTAssertEqual(h.poster.removedPrefixes, ["neon."])
    }

    func testSendDoesNotRequireConnection() async throws {
        let h = Harness()
        _ = try await h.link.send(title: "a", message: "b")
        XCTAssertEqual(h.poster.posted.count, 1)
    }

    func testFailedConnectRetriesLater() async {
        let h = Harness()
        h.transport.powerOn()
        h.link.begin()
        h.transport.advertise(id: esp, name: "NEON LINK")
        h.transport.delegate?.didFailToConnect(id: esp, error: "boom")
        XCTAssertEqual(h.link.state, .disconnected)
        XCTAssertEqual(h.link.lastError, "boom")
        // The retry is scheduled ~2 s out; it evaluates against the
        // remembered-or-scan path. Nothing is remembered, so it scans.
        try? await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertEqual(h.link.state, .scanning)
    }

    // MARK: - Helpers

    private func connected() -> Harness {
        let h = Harness()
        h.transport.powerOn()
        h.link.begin(deviceName: "NEON LINK")
        h.transport.advertise(id: esp, name: "NEON LINK")
        h.transport.completeConnect(id: esp)
        XCTAssertEqual(h.link.state, .connected(deviceName: "NEON LINK", notificationsAuthorized: false))
        return h
    }
}
