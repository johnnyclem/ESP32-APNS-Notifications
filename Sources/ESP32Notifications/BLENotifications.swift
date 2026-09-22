// The phone-side twin of the ESP32 library's `BLENotifications` class.
//
// On the ESP32:                       On the phone:
//   begin(name)  — advertise            begin(deviceName:) — find & connect
//   startAdvertising()                  startScanning()
//   state callback                      onStateChanged / observable `state`
//   notification callback (receive)     send(_:) (author)
//   removed callback                    remove(id:)
//   stop()                              stop()
//
// Everything here is portable and tested with fakes on Linux; the
// CoreBluetooth and UserNotifications adapters are injected.

import Foundation
import Observation

@Observable
@MainActor
public final class BLENotifications {
    public typealias State = LinkState

    public struct Configuration: Sendable {
        /// Advertised name of the ESP32 to auto-connect to. nil accepts any
        /// device that solicits ANCS (see `requireANCSSolicitation`).
        public var deviceName: String?
        /// Only consider devices that solicit ANCS in their advertisement.
        public var requireANCSSolicitation = true
        /// Connect to the first matching device seen while scanning. Turn
        /// off to show a picker and call `connect(_:)` yourself.
        public var autoConnect = true
        /// Re-issue the connection whenever the device drops.
        public var autoReconnect = true
        /// Persist the device across launches and reconnect at `begin`.
        public var rememberDevice = true
        /// CoreBluetooth state-restoration key. Requires the
        /// `bluetooth-central` background mode in Info.plist; with it the
        /// link survives the app being suspended or relaunched by the
        /// system.
        public var restoreIdentifier: String?
        /// Ask iOS to require ANCS on the connection
        /// (`CBConnectPeripheralOptionRequiresANCS`), which raises the
        /// pairing/authorization sheet for an unpaired ESP32.
        public var requiresANCS = true
        /// Prefix on every phone-side notification identifier, so the
        /// library can find and clear its own.
        public var notificationIdentifierPrefix = "esp32."
        /// How foreground posts are presented on the phone.
        public var foregroundPresentation: ForegroundPresentation = .list

        public init() {}
    }

    /// Current link state. Observable; also delivered to `onStateChanged`.
    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChanged?(state)
        }
    }
    /// Devices seen during the current scan, strongest signal first.
    public private(set) var discovered: [DiscoveredDevice] = []
    /// The remembered device, if any.
    public private(set) var rememberedDevice: (id: UUID, name: String?)?
    /// Last transport error, for a UI to show.
    public private(set) var lastError: String?
    /// Mirror of `setConnectionStateChangedCallback` on the ESP32.
    public var onStateChanged: ((State) -> Void)?
    /// Called for every device discovered while scanning.
    public var onDeviceDiscovered: ((DiscoveredDevice) -> Void)?

    public let configuration: Configuration

    @ObservationIgnored private let transport: any CentralTransport
    @ObservationIgnored private let poster: any NotificationPoster
    @ObservationIgnored private let memory: any DeviceMemory
    @ObservationIgnored private var filter: DeviceFilter
    @ObservationIgnored private var started = false
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var targetID: UUID?
    @ObservationIgnored private var targetName: String?
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var scanNames: [UUID: String] = [:]

    /// Designated initializer with injected seams — what the tests use and
    /// what an app uses for previews.
    public init(
        configuration: Configuration = Configuration(),
        transport: any CentralTransport,
        poster: any NotificationPoster,
        memory: any DeviceMemory
    ) {
        self.configuration = configuration
        self.transport = transport
        self.poster = poster
        self.memory = memory
        self.filter = DeviceFilter(
            deviceName: configuration.deviceName,
            requireANCSSolicitation: configuration.requireANCSSolicitation)
        if configuration.rememberDevice, let id = memory.rememberedDeviceID {
            rememberedDevice = (id, memory.rememberedDeviceName)
        }
        transport.delegate = self
    }

    public var isConnected: Bool { state.isConnected }
    public var isScanning: Bool { state == .scanning }

    // MARK: - Lifecycle (mirrors begin / startAdvertising / stop)

    /// Start the link. Reconnects to the remembered device if there is one,
    /// otherwise scans and (when `autoConnect`) connects to the first device
    /// matching `deviceName` / ANCS solicitation.
    public func begin(deviceName: String? = nil) {
        if let deviceName {
            filter.deviceName = deviceName
        }
        started = true
        userDisconnected = false
        evaluate()
    }

    /// Scan for devices (populates `discovered`). Scanning needs the app in
    /// the foreground; reconnecting to a remembered device does not.
    public func startScanning() {
        started = true
        scanRequested = true
        discovered = []
        scanNames = [:]
        guard transport.radioState == .poweredOn else {
            applyRadioState(transport.radioState)
            return
        }
        transport.startScan()
        if !state.isConnected, !isConnectingState {
            state = .scanning
        }
    }

    public func stopScanning() {
        scanRequested = false
        transport.stopScan()
        if state == .scanning {
            state = rememberedDevice == nil ? .idle : .disconnected
        }
    }

    /// Connect to a device from `discovered` (or any known identifier).
    public func connect(_ device: DiscoveredDevice) {
        connect(id: device.id, name: device.name)
    }

    /// Drop the connection but keep the device remembered; `begin` or
    /// `reconnect` picks it up again.
    public func disconnect() {
        userDisconnected = true
        retryTask?.cancel()
        if let targetID {
            transport.disconnect(id: targetID)
        }
        if !state.isConnected, isConnectingState {
            state = .disconnected
        }
    }

    /// Reconnect to the remembered device after a manual `disconnect`.
    public func reconnect() {
        userDisconnected = false
        started = true
        evaluate()
    }

    /// Disconnect and forget the remembered device.
    public func forgetDevice() {
        disconnect()
        memory.rememberedDeviceID = nil
        memory.rememberedDeviceName = nil
        rememberedDevice = nil
        targetID = nil
        targetName = nil
        state = started ? .disconnected : .idle
    }

    /// Stop scanning and disconnect; the link goes back to `.idle`.
    public func stop() {
        started = false
        scanRequested = false
        retryTask?.cancel()
        transport.stopScan()
        if let targetID {
            userDisconnected = true
            transport.disconnect(id: targetID)
        }
        state = .idle
    }

    // MARK: - Notifications (the ESP32's receive side)

    /// Ask the user for notification permission. Without it nothing reaches
    /// the ESP32.
    @discardableResult
    public func requestNotificationAuthorization() async -> Bool {
        await poster.requestAuthorization()
    }

    public func notificationsAuthorized() async -> Bool {
        await poster.isAuthorized()
    }

    /// Post a notification on the phone; a connected, ANCS-authorized ESP32
    /// receives it as `title` / `message` / `type` (this app's bundle id).
    /// Returns the phone-side identifier (`prefix + notification.id`).
    @discardableResult
    public func send(_ notification: BLENotification) async throws -> String {
        if let error = notification.validationError { throw error }
        let identifier = configuration.notificationIdentifierPrefix + notification.id
        try await poster.post(notification, identifier: identifier)
        return identifier
    }

    @discardableResult
    public func send(title: String, message: String, id: String = UUID().uuidString) async throws -> String {
        try await send(BLENotification(id: id, title: title, message: message))
    }

    /// Clear a notification on the phone; the ESP32 sees a "removed" event.
    public func remove(id: String) {
        poster.remove(identifiers: [configuration.notificationIdentifierPrefix + id])
    }

    /// Clear every notification this library posted.
    public func removeAll() async {
        await poster.removeAll(withPrefix: configuration.notificationIdentifierPrefix)
    }

    // MARK: - Internals

    private var isConnectingState: Bool {
        if case .connecting = state { return true }
        return false
    }

    private func evaluate() {
        guard started else { return }
        let radio = transport.radioState
        guard radio == .poweredOn else {
            applyRadioState(radio)
            return
        }
        if state.isConnected || isConnectingState { return }
        if !userDisconnected, let remembered = rememberedDevice,
           transport.hasKnownPeripheral(id: remembered.id) {
            connect(id: remembered.id, name: remembered.name ?? transport.knownPeripheralName(id: remembered.id))
            return
        }
        if scanRequested || configuration.autoConnect || rememberedDevice == nil {
            scanRequested = true
            transport.startScan()
            state = .scanning
        } else {
            state = .disconnected
        }
    }

    private func applyRadioState(_ radio: RadioState) {
        if let reason = radio.unavailableReason {
            state = .unavailable(reason: reason)
        } else if started, !state.isConnected {
            state = rememberedDevice == nil && !scanRequested ? .idle : .disconnected
        }
    }

    private func connect(id: UUID, name: String?) {
        retryTask?.cancel()
        userDisconnected = false
        targetID = id
        targetName = name
        transport.stopScan()
        scanRequested = false
        state = .connecting(deviceName: name)
        transport.connect(id: id)
    }

    private func remember(id: UUID, name: String?) {
        guard configuration.rememberDevice else { return }
        memory.rememberedDeviceID = id
        if let name { memory.rememberedDeviceName = name }
        rememberedDevice = (id, name ?? memory.rememberedDeviceName)
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }
}

extension BLENotifications: CentralTransportDelegate {
    public func radioStateChanged(_ radio: RadioState) {
        if radio == .poweredOn {
            if scanRequested, !state.isConnected, !isConnectingState {
                transport.startScan()
                state = .scanning
            }
            evaluate()
        } else {
            if isConnectingState || state.isConnected {
                targetID = rememberedDevice?.id
            }
            applyRadioState(radio)
        }
    }

    public func didDiscover(id: UUID, advertisement: Advertisement) {
        let name = advertisement.localName ?? transport.knownPeripheralName(id: id)
        if let name { scanNames[id] = name }
        let device = DiscoveredDevice(
            id: id, name: name ?? scanNames[id], rssi: advertisement.rssi,
            solicitsANCS: advertisement.solicitsANCS)
        if let index = discovered.firstIndex(where: { $0.id == id }) {
            discovered[index] = device
        } else {
            discovered.append(device)
        }
        discovered.sort { $0.rssi > $1.rssi }
        onDeviceDiscovered?(device)

        guard configuration.autoConnect, !state.isConnected, !isConnectingState else { return }
        if let remembered = rememberedDevice, remembered.id == id {
            connect(id: id, name: device.name ?? remembered.name)
        } else if rememberedDevice == nil, filter.matches(advertisement) {
            connect(id: id, name: device.name)
        }
    }

    public func didConnect(id: UUID, name: String?) {
        guard id == targetID || targetID == nil else {
            // A connection we did not ask for (restoration handed it back).
            return
        }
        targetID = id
        let resolvedName = name ?? targetName ?? transport.knownPeripheralName(id: id)
        targetName = resolvedName
        lastError = nil
        remember(id: id, name: resolvedName)
        state = .connected(
            deviceName: resolvedName,
            notificationsAuthorized: transport.isANCSAuthorized(id: id))
    }

    public func didFailToConnect(id: UUID, error: String?) {
        guard id == targetID else { return }
        lastError = error
        state = .disconnected
        if started, configuration.autoReconnect, !userDisconnected {
            scheduleRetry()
        }
    }

    public func didDisconnect(id: UUID, error: String?) {
        guard id == targetID else { return }
        lastError = error
        state = .disconnected
        guard started, !userDisconnected, configuration.autoReconnect else { return }
        // A pending connect is how iOS keeps a link alive: it completes
        // whenever the device comes back into range, even from the
        // background.
        connect(id: id, name: targetName)
    }

    public func ancsAuthorizationChanged(id: UUID, authorized: Bool) {
        guard id == targetID, case .connected(let name, _) = state else { return }
        state = .connected(deviceName: name, notificationsAuthorized: authorized)
    }

    public func didRestore(connected: [UUID]) {
        guard let remembered = rememberedDevice ?? targetID.map({ ($0, targetName) }) else { return }
        started = true
        if connected.contains(remembered.id) {
            targetID = remembered.id
            targetName = remembered.name ?? transport.knownPeripheralName(id: remembered.id)
            state = .connected(
                deviceName: targetName,
                notificationsAuthorized: transport.isANCSAuthorized(id: remembered.id))
        }
    }
}
