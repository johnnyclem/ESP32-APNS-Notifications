import Foundation
@testable import ESP32Notifications

@MainActor
final class FakeTransport: CentralTransport {
    weak var delegate: CentralTransportDelegate?
    var radioState: RadioState = .unknown
    var known: [UUID: String?] = [:]
    var ancsAuthorized: Set<UUID> = []
    var scanning = false
    var connectCalls: [UUID] = []
    var disconnectCalls: [UUID] = []
    var scanStarts = 0

    func startScan() { scanning = true; scanStarts += 1 }
    func stopScan() { scanning = false }
    func hasKnownPeripheral(id: UUID) -> Bool { known[id] != nil }
    func knownPeripheralName(id: UUID) -> String? { known[id] ?? nil }
    func connect(id: UUID) { connectCalls.append(id) }
    func disconnect(id: UUID) { disconnectCalls.append(id) }
    func isANCSAuthorized(id: UUID) -> Bool { ancsAuthorized.contains(id) }

    // Radio-side events, as CoreBluetooth would report them.
    func powerOn() { radioState = .poweredOn; delegate?.radioStateChanged(.poweredOn) }
    func powerOff() { radioState = .poweredOff; delegate?.radioStateChanged(.poweredOff) }
    func advertise(id: UUID, name: String?, solicitsANCS: Bool = true, rssi: Int = -50) {
        known[id] = name
        delegate?.didDiscover(
            id: id,
            advertisement: Advertisement(
                localName: name,
                solicitedServiceUUIDs: solicitsANCS ? [ANCS.serviceUUID] : [],
                rssi: rssi))
    }
    func completeConnect(id: UUID, name: String? = nil) {
        if let name { known[id] = name }
        delegate?.didConnect(id: id, name: name ?? (known[id] ?? nil))
    }
    func drop(id: UUID, error: String? = "Peripheral went away") {
        delegate?.didDisconnect(id: id, error: error)
    }
}

@MainActor
final class FakePoster: NotificationPoster {
    var authorized = true
    var posted: [(BLENotification, String)] = []
    var removed: [String] = []
    var removedPrefixes: [String] = []
    var failNext: String?

    func requestAuthorization() async -> Bool { authorized }
    func isAuthorized() async -> Bool { authorized }
    func post(_ notification: BLENotification, identifier: String) async throws {
        if let failNext {
            self.failNext = nil
            throw LinkError.postFailed(failNext)
        }
        posted.append((notification, identifier))
    }
    func remove(identifiers: [String]) { removed += identifiers }
    func removeAll(withPrefix prefix: String) async { removedPrefixes.append(prefix) }
}

@MainActor
struct Harness {
    let transport = FakeTransport()
    let poster = FakePoster()
    let memory: InMemoryDeviceMemory
    let link: BLENotifications
    var states: [LinkState] { box.states }
    private let box = StateBox()

    init(configure: (inout BLENotifications.Configuration) -> Void = { _ in }, memory: InMemoryDeviceMemory = InMemoryDeviceMemory()) {
        var configuration = BLENotifications.Configuration()
        configure(&configuration)
        self.memory = memory
        link = BLENotifications(configuration: configuration, transport: transport, poster: poster, memory: memory)
        let box = self.box
        link.onStateChanged = { box.states.append($0) }
    }

    @MainActor final class StateBox { var states: [LinkState] = [] }
}
