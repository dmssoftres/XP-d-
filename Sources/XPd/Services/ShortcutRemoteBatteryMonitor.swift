import CoreBluetooth
import Foundation
import OSLog

/// Reads the ACK05/Shortcut Remote's verified BLE battery notification and,
/// when enabled, switches the remote into XPPen's Bluetooth driver mode. The
/// only writes are XPPen's own driver-mode commands to FFE0/0001 (`02 B0 04`
/// on, `02 B0 00` off), sent only after the exact PnP ID is verified. It does
/// not scan while the matching HID remote is disconnected.
@MainActor
final class ShortcutRemoteBatteryMonitor: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onBatteryPercentage: ((Int?) -> Void)?
    /// Called with `true` once the remote acknowledges `02 B0 04`, and with
    /// `false` when driver mode ends (command off, disconnect, or failure).
    var onDriverModeActive: ((Bool) -> Void)?
    /// Raw FFE0/0003 notifications received while driver mode is active.
    var onDriverModePacket: ((Data) -> Void)?
    /// Called when a driver-mode request failed or was not acknowledged.
    var onDriverModeRequestFailed: (() -> Void)?

    static let driverModeOnCommand = Data([0x02, 0xB0, 0x04, 0, 0, 0, 0, 0, 0, 0])
    static let driverModeOffCommand = Data([0x02, 0xB0, 0x00, 0, 0, 0, 0, 0, 0, 0])

    private static let deviceInformationServiceUUID = CBUUID(string: "180A")
    private static let deviceInformationCharacteristicUUID = CBUUID(string: "2A50")
    private static let vendorServiceUUID = CBUUID(string: "FFE0")
    private static let companionNotificationCharacteristicUUID = CBUUID(string: "0002")
    private static let batteryNotificationCharacteristicUUID = CBUUID(string: "0003")
    private static let commandCharacteristicUUID = CBUUID(string: "0001")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var pendingCompanionCharacteristic: CBCharacteristic?
    private var pendingBatteryCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var notificationsReady: Set<CBUUID> = []
    private var awaitingDriverModeAcknowledgement = false
    private(set) var isDriverModeActive = false
    private var driverModeRequestGeneration = 0
    private var pendingTerminationWrite = false
    static let driverModeAcknowledgementTimeout: TimeInterval = 1.5
    /// Driver mode is only requested while the matched HID connection is
    /// Bluetooth; over USB the remote must keep its normal HID input.
    var isBluetoothTransport = false {
        didSet {
            guard isBluetoothTransport != oldValue else { return }
            if isBluetoothTransport {
                requestDriverModeIfReady()
            } else {
                leaveDriverMode()
            }
        }
    }
    /// Owner setting. Applied on every verified connection, because the
    /// remote leaves driver mode whenever it is switched off.
    var isDriverModeEnabled = false {
        didSet {
            guard isDriverModeEnabled != oldValue else { return }
            if isDriverModeEnabled {
                requestDriverModeIfReady()
            } else {
                leaveDriverMode()
            }
        }
    }
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
        commandCharacteristic = nil
        notificationsReady = []
        isVerifiedRemote = false
        setDriverModeInactive()
        onBatteryPercentage?(nil)
        logger.info("BLE battery monitor stopped")
    }

    /// Best-effort return to normal keyboard behaviour when XP[d] quits, so
    /// the remote's keys keep working without XP[d]. A crash cannot run
    /// this; switching the remote off and on also leaves driver mode.
    func leaveDriverModeForTermination() {
        guard isDriverModeActive || awaitingDriverModeAcknowledgement,
              let peripheral, let command = commandCharacteristic
        else { return }
        pendingTerminationWrite = true
        peripheral.writeValue(Self.driverModeOffCommand, for: command, type: .withResponse)
        setDriverModeInactive()
        logger.info("BLE driver mode off requested at termination")
        // CoreBluetooth delivers the write asynchronously; keep the main run
        // loop alive briefly so it reaches the remote before the process exits.
        let deadline = Date().addingTimeInterval(0.5)
        while pendingTerminationWrite, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
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
                Self.batteryNotificationCharacteristicUUID,
                Self.commandCharacteristicUUID
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
            commandCharacteristic = service.characteristics?.first(where: {
                $0.uuid == Self.commandCharacteristicUUID && $0.properties.contains(.write)
            })
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

        if characteristic.uuid == Self.companionNotificationCharacteristicUUID {
            handleCompanionNotification(data)
            return
        }

        if characteristic.uuid == Self.batteryNotificationCharacteristicUUID,
           isDriverModeActive,
           data.count >= 2, data[data.startIndex + 1] == 0xF0 {
            onDriverModePacket?(data)
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
        notificationsReady.insert(characteristic.uuid)
        requestDriverModeIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral,
              characteristic.uuid == Self.commandCharacteristicUUID
        else { return }
        pendingTerminationWrite = false
        guard error != nil else { return }
        logger.error("BLE driver-mode command write failed; staying in normal mode")
        let failedRequest = awaitingDriverModeAcknowledgement
        setDriverModeInactive()
        if failedRequest {
            onDriverModeRequestFailed?()
        }
    }

    /// `02 B0 01` on FFE0/0002 is the remote's acknowledgement of a
    /// driver-mode command. Only an acknowledgement of our own `02 B0 04`
    /// activates key routing.
    private func handleCompanionNotification(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x02, bytes[1] == 0xB0, bytes[2] == 0x01,
              awaitingDriverModeAcknowledgement
        else { return }
        awaitingDriverModeAcknowledgement = false
        guard isDriverModeEnabled, isBluetoothTransport else { return }
        isDriverModeActive = true
        logger.info("BLE driver mode active")
        onDriverModeActive?(true)
    }

    private func requestDriverModeIfReady() {
        guard isDriverModeEnabled,
              isBluetoothTransport,
              isVerifiedRemote,
              !isDriverModeActive,
              !awaitingDriverModeAcknowledgement,
              notificationsReady.contains(Self.companionNotificationCharacteristicUUID),
              notificationsReady.contains(Self.batteryNotificationCharacteristicUUID),
              let peripheral,
              let command = commandCharacteristic
        else { return }
        awaitingDriverModeAcknowledgement = true
        driverModeRequestGeneration += 1
        let generation = driverModeRequestGeneration
        peripheral.writeValue(Self.driverModeOnCommand, for: command, type: .withResponse)
        logger.info("BLE driver mode requested")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.driverModeAcknowledgementTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.driverModeRequestGeneration == generation,
                      self.awaitingDriverModeAcknowledgement
                else { return }
                // The remote may have switched modes without the reply
                // reaching us; send off so its normal keys keep working.
                self.logger.error("BLE driver mode not acknowledged; returning remote to normal mode")
                self.leaveDriverMode()
                self.onDriverModeRequestFailed?()
            }
        }
    }

    private func leaveDriverMode() {
        let wasRequested = isDriverModeActive || awaitingDriverModeAcknowledgement
        if wasRequested, let peripheral, let command = commandCharacteristic {
            peripheral.writeValue(Self.driverModeOffCommand, for: command, type: .withResponse)
            logger.info("BLE driver mode off requested")
        }
        setDriverModeInactive()
    }

    private func setDriverModeInactive() {
        awaitingDriverModeAcknowledgement = false
        guard isDriverModeActive else { return }
        isDriverModeActive = false
        onDriverModeActive?(false)
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
        commandCharacteristic = nil
        notificationsReady = []
        isVerifiedRemote = false
        setDriverModeInactive()
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
