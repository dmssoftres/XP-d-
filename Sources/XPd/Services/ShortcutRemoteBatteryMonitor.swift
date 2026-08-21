import CoreBluetooth
import Foundation
import OSLog

/// Reads the ACK05/Shortcut Remote's verified BLE battery notification. It
/// neither writes proprietary characteristics nor scans while the matching HID
/// remote is disconnected.
@MainActor
final class ShortcutRemoteBatteryMonitor: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onBatteryPercentage: ((Int?) -> Void)?

    private static let deviceInformationServiceUUID = CBUUID(string: "180A")
    private static let deviceInformationCharacteristicUUID = CBUUID(string: "2A50")
    private static let vendorServiceUUID = CBUUID(string: "FFE0")
    private static let companionNotificationCharacteristicUUID = CBUUID(string: "0002")
    private static let batteryNotificationCharacteristicUUID = CBUUID(string: "0003")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var pendingCompanionCharacteristic: CBCharacteristic?
    private var pendingBatteryCharacteristic: CBCharacteristic?
    private var isVerifiedRemote = false
    private var isMonitoring = false
    private let logger = Logger(subsystem: "com.dmssoftres.xpd", category: "Battery")

    func startMonitoring() {
        isMonitoring = true
        logger.info("BLE battery monitor started")

        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            discoverRemote()
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        central?.stopScan()
        peripheral?.delegate = nil
        peripheral = nil
        pendingCompanionCharacteristic = nil
        pendingBatteryCharacteristic = nil
        isVerifiedRemote = false
        onBatteryPercentage?(nil)
        logger.info("BLE battery monitor stopped")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isMonitoring else { return }
        logger.info(
            "BLE state=\(central.state.rawValue, privacy: .public) authorization=\(CBCentralManager.authorization.rawValue, privacy: .public)"
        )
        guard central.state == .poweredOn else {
            resetCandidate()
            return
        }
        discoverRemote()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isMonitoring, peripheral.name == "Shortcut Remote" else { return }
        logger.info("BLE matching-name candidate discovered")
        inspect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isMonitoring, peripheral === self.peripheral else { return }
        logger.info("BLE candidate connected; discovering required services")
        peripheral.delegate = self
        peripheral.discoverServices([
            Self.deviceInformationServiceUUID,
            Self.vendorServiceUUID
        ])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        resetCandidate()
        logger.error("BLE candidate connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        logger.info("BLE candidate disconnected; clearing battery value")
        resetCandidate()
        if isMonitoring, central.state == .poweredOn {
            discoverRemote()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isMonitoring, peripheral === self.peripheral else { return }
        guard error == nil else {
            logger.error("BLE required-service discovery failed")
            resetCandidate()
            return
        }

        let services = peripheral.services ?? []
        guard let deviceInformationService = services.first(where: { $0.uuid == Self.deviceInformationServiceUUID }),
              let vendorService = services.first(where: { $0.uuid == Self.vendorServiceUUID })
        else {
            logger.error("BLE required services unavailable")
            resetCandidate()
            return
        }

        logger.info("BLE required services discovered")
        peripheral.discoverCharacteristics([Self.deviceInformationCharacteristicUUID], for: deviceInformationService)
        peripheral.discoverCharacteristics(
            [
                Self.companionNotificationCharacteristicUUID,
                Self.batteryNotificationCharacteristicUUID
            ],
            for: vendorService
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isMonitoring, peripheral === self.peripheral else { return }
        guard error == nil else {
            logger.error("BLE required-characteristic discovery failed")
            resetCandidate()
            return
        }

        switch service.uuid {
        case Self.deviceInformationServiceUUID:
            guard let characteristic = service.characteristics?.first(where: {
                $0.uuid == Self.deviceInformationCharacteristicUUID && $0.properties.contains(.read)
            }) else {
                logger.error("BLE PnP ID characteristic unavailable")
                resetCandidate()
                return
            }
            logger.info("BLE PnP ID characteristic ready")
            peripheral.readValue(for: characteristic)

        case Self.vendorServiceUUID:
            guard let companion = service.characteristics?.first(where: {
                $0.uuid == Self.companionNotificationCharacteristicUUID && $0.properties.contains(.notify)
            }), let battery = service.characteristics?.first(where: {
                $0.uuid == Self.batteryNotificationCharacteristicUUID && $0.properties.contains(.notify)
            }) else {
                logger.error("BLE required battery notification characteristics unavailable")
                resetCandidate()
                return
            }
            pendingCompanionCharacteristic = companion
            pendingBatteryCharacteristic = battery
            logger.info("BLE battery notification characteristics ready")
            enableBatteryNotificationsIfVerified()

        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isMonitoring, peripheral === self.peripheral else { return }
        guard error == nil, let data = characteristic.value else {
            logger.error("BLE characteristic read or notification failed")
            resetCandidate()
            return
        }

        if characteristic.uuid == Self.deviceInformationCharacteristicUUID {
            isVerifiedRemote = Self.isExpectedRemoteDeviceInformation(data)
            if !isVerifiedRemote {
                logger.error("BLE PnP ID rejected")
                onBatteryPercentage?(nil)
            } else {
                logger.info("BLE PnP ID accepted")
            }
            enableBatteryNotificationsIfVerified()
            return
        }

        guard characteristic.uuid == Self.batteryNotificationCharacteristicUUID,
              isVerifiedRemote,
              let percentage = Self.batteryPercentage(fromBatteryNotification: data)
        else {
            return
        }

        onBatteryPercentage?(percentage)
        logger.info("BLE accepted exact battery percentage=\(percentage, privacy: .public)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral,
              characteristic.uuid == Self.companionNotificationCharacteristicUUID
                || characteristic.uuid == Self.batteryNotificationCharacteristicUUID
        else {
            return
        }

        guard error == nil, characteristic.isNotifying else {
            logger.error("BLE battery notification subscription failed")
            resetCandidate()
            return
        }

        if characteristic.uuid == Self.companionNotificationCharacteristicUUID {
            logger.info("BLE companion notification subscription enabled")
        } else {
            logger.info("BLE battery notification subscription enabled")
        }
    }

    private func discoverRemote() {
        guard let central, isMonitoring else { return }

        let connected = central.retrieveConnectedPeripherals(withServices: [Self.vendorServiceUUID])
        let remote = connected.first(where: { $0.name == "Shortcut Remote" })
        logger.info(
            "BLE retrieved candidates=\(connected.count, privacy: .public) matching-name=\(remote != nil, privacy: .public)"
        )
        if let remote {
            inspect(remote)
            return
        }

        logger.info("BLE scanning for matching FFE0 peripheral")
        central.scanForPeripherals(withServices: [Self.vendorServiceUUID])
    }

    private func inspect(_ candidate: CBPeripheral) {
        guard peripheral == nil else { return }

        central?.stopScan()
        peripheral = candidate
        candidate.delegate = self
        if candidate.state == .connected {
            logger.info("BLE inspecting existing connected candidate")
            candidate.discoverServices([
                Self.deviceInformationServiceUUID,
                Self.vendorServiceUUID
            ])
        } else {
            logger.info("BLE connecting candidate")
            central?.connect(candidate)
        }
    }

    private func enableBatteryNotificationsIfVerified() {
        guard isVerifiedRemote,
              let peripheral,
              let companion = pendingCompanionCharacteristic,
              let characteristic = pendingBatteryCharacteristic
        else {
            return
        }

        logger.info("BLE enabling companion and battery notifications")
        peripheral.setNotifyValue(true, for: companion)
        peripheral.setNotifyValue(true, for: characteristic)
    }

    private func resetCandidate() {
        peripheral?.delegate = nil
        peripheral = nil
        pendingCompanionCharacteristic = nil
        pendingBatteryCharacteristic = nil
        isVerifiedRemote = false
        onBatteryPercentage?(nil)
    }

    /// The paired remote publishes its Device Information PnP ID as LE vendor
    /// 0x28BD and product 0x0202. This prevents accepting packets from another
    /// FFE0 peripheral with the same display name.
    static func isExpectedRemoteDeviceInformation(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count == 7 else { return false }
        return bytes == [0x02, 0xBD, 0x28, 0x02, 0x02, 0x01, 0x00]
    }

    /// ACK05 sends `02 F2 01 <percent> <state> …` as an FFE0/0003 BLE
    /// notification. The XPPen driver handles the F2/type-1 packet and uses
    /// byte 3 for its battery UI value. Only an exact byte in 0...100 is used.
    static func batteryPercentage(fromBatteryNotification data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4,
              bytes[0] == 0x02,
              bytes[1] == 0xF2,
              bytes[2] == 0x01,
              (0...100).contains(Int(bytes[3]))
        else {
            return nil
        }

        return Int(bytes[3])
    }
}
