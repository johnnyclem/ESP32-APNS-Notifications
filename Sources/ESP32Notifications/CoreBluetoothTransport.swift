// CoreBluetooth behind the `CentralTransport` seam. Created on the main
// queue so every delegate callback arrives on the main actor.

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

@MainActor
public final class CoreBluetoothTransport: NSObject, CentralTransport {
    public weak var delegate: CentralTransportDelegate?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private let requiresANCS: Bool

    /// - Parameters:
    ///   - restoreIdentifier: `CBCentralManagerOptionRestoreIdentifierKey`;
    ///     needs the `bluetooth-central` background mode.
    ///   - requiresANCS: pass `CBConnectPeripheralOptionRequiresANCS` on
    ///     connect (iOS only) so an unpaired ESP32 raises the pairing sheet.
    ///   - showPowerAlert: let iOS prompt when Bluetooth is off.
    public init(restoreIdentifier: String? = nil, requiresANCS: Bool = true, showPowerAlert: Bool = true) {
        self.requiresANCS = requiresANCS
        super.init()
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: showPowerAlert]
        if let restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        }
        central = CBCentralManager(delegate: self, queue: nil, options: options)
    }

    public var radioState: RadioState { RadioState(central.state) }

    public func startScan() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        // No service filter: the ESP32 advertises an ANCS *solicitation*,
        // which CoreBluetooth cannot filter on. Foreground only, by design.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        guard central.isScanning else { return }
        central.stopScan()
    }

    public func hasKnownPeripheral(id: UUID) -> Bool {
        if peripherals[id] != nil { return true }
        guard central.state == .poweredOn,
              let found = central.retrievePeripherals(withIdentifiers: [id]).first
        else { return false }
        peripherals[id] = found
        return true
    }

    public func knownPeripheralName(id: UUID) -> String? {
        peripherals[id]?.name
    }

    public func connect(id: UUID) {
        guard let peripheral = peripherals[id] else {
            delegate?.didFailToConnect(id: id, error: "Unknown peripheral")
            return
        }
        var options: [String: Any] = [:]
        #if os(iOS)
        if requiresANCS {
            options[CBConnectPeripheralOptionRequiresANCS] = true
        }
        #endif
        central.connect(peripheral, options: options)
    }

    public func disconnect(id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    public func isANCSAuthorized(id: UUID) -> Bool {
        #if os(iOS)
        return peripherals[id]?.ancsAuthorized ?? false
        #else
        return false
        #endif
    }

    private func adopt(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
    }
}

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            delegate?.radioStateChanged(RadioState(central.state))
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            adopt(peripheral)
            let solicited = (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID]) ?? []
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let advertisement = Advertisement(
                localName: (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name,
                solicitedServiceUUIDs: solicited.map(\.uuidString),
                serviceUUIDs: services.map(\.uuidString),
                rssi: RSSI.intValue)
            delegate?.didDiscover(id: peripheral.identifier, advertisement: advertisement)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            adopt(peripheral)
            delegate?.didConnect(id: peripheral.identifier, name: peripheral.name)
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            delegate?.didFailToConnect(id: peripheral.identifier, error: error?.localizedDescription)
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            delegate?.didDisconnect(id: peripheral.identifier, error: error?.localizedDescription)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
            restored.forEach(adopt)
            delegate?.didRestore(connected: restored.filter { $0.state == .connected }.map(\.identifier))
        }
    }

    #if os(iOS)
    nonisolated public func centralManager(
        _ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral
    ) {
        MainActor.assumeIsolated {
            adopt(peripheral)
            delegate?.ancsAuthorizationChanged(id: peripheral.identifier, authorized: peripheral.ancsAuthorized)
        }
    }
    #endif
}

extension RadioState {
    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .resetting: self = .resetting
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}
#endif
