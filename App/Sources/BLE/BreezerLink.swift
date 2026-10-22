import Combine
import CoreBluetooth
import Foundation
import TionKit

enum TionBLE {
    static let service = CBUUID(string: "98F00001-3788-83EA-453E-F52244709DDB")
    static let write = CBUUID(string: "98F00002-3788-83EA-453E-F52244709DDB")
    static let notify = CBUUID(string: "98F00003-3788-83EA-453E-F52244709DDB")
}

struct DiscoveredBreezer: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var pairingMode: Bool
    var lastSeen: Date
}

enum LinkStatus: Equatable {
    case bluetoothUnavailable(String)
    case idle
    case connecting
    case preparing
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var title: String {
        switch self {
        case .bluetoothUnavailable(let reason): return reason
        case .idle: return "Not connected"
        case .connecting: return "Looking for your breezer…"
        case .preparing: return "Connecting…"
        case .ready: return "Connected"
        case .failed(let reason): return reason
        }
    }
}

enum LinkError: LocalizedError {
    case notConnected
    case noReply(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "The breezer isn't connected."
        case .noReply(let name): return "The breezer didn't answer (\(name))."
        case .transport(let message): return message
        }
    }
}

struct LinkLogEntry: Identifiable {
    enum Kind {
        case sent, received, info, error
    }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
}

/// Owns the CoreBluetooth connection to one Breezer 4S and runs one request at a time.
@MainActor
final class BreezerLink: NSObject, ObservableObject {
    @Published private(set) var status: LinkStatus = .idle
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredBreezer] = []
    @Published private(set) var log: [LinkLogEntry] = []

    var onReady: (@MainActor () -> Void)?
    var onUnsolicitedPacket: (@MainActor (TionPacket) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var targetId: UUID?
    private var keepConnected = false
    private var wantsScan = false
    private var assembler = FrameAssembler()

    private struct InFlight {
        let token: UUID
        let request: TionRequest
        let continuation: CheckedContinuation<TionPacket?, Error>
        var allFramesWritten = false
    }

    private var inFlight: InFlight?
    private var outgoingFrames: [Data] = []
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Scanning

    func startScan() {
        wantsScan = true
        guard central.state == .poweredOn, !isScanning else { return }
        discovered.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        wantsScan = false
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    // MARK: Connection

    /// Connects and keeps reconnecting whenever the breezer is in range, until `disconnect()`.
    func connect(to id: UUID) {
        targetId = id
        keepConnected = true
        guard central.state == .poweredOn else { return }
        if let peripheral, peripheral.identifier == id, peripheral.state != .disconnected { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            beginConnection(to: known)
        } else {
            status = .connecting
            addLog(.info, "Breezer not known to iOS yet; scanning for it")
            startScan()
        }
    }

    func disconnect() {
        keepConnected = false
        targetId = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        connectionClosed()
        status = .idle
    }

    func reconnect() {
        guard let id = targetId ?? peripheral?.identifier else { return }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        connectionClosed()
        connect(to: id)
    }

    private func beginConnection(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        status = .connecting
        addLog(.info, "Connecting to \(peripheral.name ?? "breezer")")
        // A pending connection has no timeout: iOS completes it whenever the breezer comes into range.
        central.connect(peripheral, options: nil)
    }

    private func connectionClosed() {
        writeCharacteristic = nil
        assembler.reset()
        failInFlight(LinkError.notConnected)
    }

    // MARK: Requests

    /// Sends a request and waits for its reply. Returns nil for requests whose reply is absent or optional.
    @discardableResult
    func send(_ request: TionRequest) async throws -> TionPacket? {
        await acquire()
        defer { release() }
        guard status.isReady, peripheral != nil, writeCharacteristic != nil else { throw LinkError.notConnected }

        let packet = request.packet(requestId: TionRequest.randomId(), random: UInt8.random(in: 0...255))
        let bytes = packet.encoded()
        addLog(.sent, "\(request.name): \(bytes.hexString)")
        let token = UUID()
        let timeout = request.timeout

        return try await withCheckedThrowingContinuation { continuation in
            inFlight = InFlight(token: token, request: request, continuation: continuation)
            outgoingFrames = TionFraming.frames(for: bytes).map { Data($0) }
            writeNextFrame()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.timeoutExpired(token)
            }
        }
    }

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func writeNextFrame() {
        guard inFlight != nil else { return }
        guard let peripheral, let characteristic = writeCharacteristic else {
            failInFlight(LinkError.notConnected)
            return
        }
        while !outgoingFrames.isEmpty {
            if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                return // resumed by peripheralIsReady(toSendWriteWithoutResponse:)
            }
            let frame = outgoingFrames.removeFirst()
            peripheral.writeValue(frame, for: characteristic, type: writeType)
            if writeType == .withResponse {
                return // resumed by didWriteValueFor
            }
        }
        allFramesWritten()
    }

    private func allFramesWritten() {
        guard var flight = inFlight, !flight.allFramesWritten else { return }
        flight.allFramesWritten = true
        inFlight = flight
        if flight.request.reply == .noReply {
            finish(flight.token, with: .success(nil))
        }
    }

    private func timeoutExpired(_ token: UUID) {
        guard let flight = inFlight, flight.token == token else { return }
        if case .maybe = flight.request.reply, flight.allFramesWritten {
            finish(token, with: .success(nil))
        } else {
            addLog(.error, "No reply to \(flight.request.name)")
            finish(token, with: .failure(LinkError.noReply(flight.request.name)))
        }
    }

    private func finish(_ token: UUID, with result: Result<TionPacket?, Error>) {
        guard let flight = inFlight, flight.token == token else { return }
        inFlight = nil
        outgoingFrames.removeAll()
        flight.continuation.resume(with: result)
    }

    private func failInFlight(_ error: Error) {
        guard let flight = inFlight else { return }
        finish(flight.token, with: .failure(error))
    }

    private func received(_ bytes: [UInt8]) {
        guard let packetBytes = assembler.append(bytes) else { return }
        do {
            let packet = try TionPacket.decode(packetBytes)
            addLog(packet.checksumValid ? .received : .error,
                   "\(FrameType.name(of: packet.frameType))\(packet.checksumValid ? "" : " (bad checksum)"): \(packetBytes.hexString)")
            if let flight = inFlight, flight.request.isReply(packet) {
                finish(flight.token, with: .success(packet))
            } else {
                onUnsolicitedPacket?(packet)
            }
        } catch {
            addLog(.error, "Unreadable packet \(packetBytes.hexString): \(error)")
        }
    }

    // MARK: Log

    func addLog(_ kind: LinkLogEntry.Kind, _ text: String) {
        log.append(LinkLogEntry(kind: kind, text: text))
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }

    // MARK: Delegate handlers (main actor)

    private func centralStateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            if case .bluetoothUnavailable = status {
                status = .idle
            }
            if wantsScan {
                startScan()
            }
            if keepConnected, let targetId {
                connect(to: targetId)
            }
        case .poweredOff:
            isScanning = false
            connectionClosed()
            status = .bluetoothUnavailable("Bluetooth is off")
        case .unauthorized:
            status = .bluetoothUnavailable("Bluetooth access is off for this app. Turn it on in Settings › Privacy & Security › Bluetooth.")
        case .unsupported:
            status = .bluetoothUnavailable("This device doesn't support Bluetooth LE")
        default:
            break
        }
    }

    private func didDiscover(_ peripheral: CBPeripheral, name: String?, manufacturerData: [UInt8]?, rssi: Int) {
        let advertisement = manufacturerData.flatMap { TionAdvertisement(manufacturerData: $0) }
        let isBreezer = advertisement?.isBreezer4S == true
            || (name?.localizedCaseInsensitiveContains("breezer") ?? false)
            || (name?.localizedCaseInsensitiveContains("4S") ?? false)
        guard isBreezer else { return }

        if keepConnected, peripheral.identifier == targetId, self.peripheral == nil {
            stopScan()
            beginConnection(to: peripheral)
            return
        }

        let entry = DiscoveredBreezer(
            id: peripheral.identifier,
            name: name ?? "Breezer 4S",
            rssi: rssi,
            pairingMode: advertisement?.pairingMode ?? false,
            lastSeen: Date()
        )
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            let previous = discovered[index]
            if previous.pairingMode != entry.pairingMode || abs(previous.rssi - entry.rssi) >= 4 || entry.lastSeen.timeIntervalSince(previous.lastSeen) > 2 {
                discovered[index] = entry
            }
        } else {
            discovered.append(entry)
        }
    }

    private func didConnect(_ peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        status = .preparing
        addLog(.info, "Connected, discovering services")
        peripheral.discoverServices([TionBLE.service])
    }

    private func connectionLost(_ peripheral: CBPeripheral, reason: String?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        connectionClosed()
        let suffix = reason.map { ": " + $0 } ?? ""
        addLog(.info, "Disconnected" + suffix)
        if keepConnected, central.state == .poweredOn {
            status = .connecting
            central.connect(peripheral, options: nil)
        } else if case .failed = status {
            // Keep the more specific message set by giveUp(_:_:).
        } else {
            status = .failed(reason ?? "Disconnected")
        }
    }

    private func servicesDiscovered(_ peripheral: CBPeripheral, error: String?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == TionBLE.service }) else {
            giveUp(peripheral, "This device doesn't look like a Breezer 4S (service not found). \(error ?? "")")
            return
        }
        peripheral.discoverCharacteristics([TionBLE.write, TionBLE.notify], for: service)
    }

    private func characteristicsDiscovered(_ peripheral: CBPeripheral, service: CBService, error: String?) {
        let characteristics = service.characteristics ?? []
        guard let write = characteristics.first(where: { $0.uuid == TionBLE.write }),
              let notify = characteristics.first(where: { $0.uuid == TionBLE.notify }) else {
            giveUp(peripheral, "Breezer characteristics not found. \(error ?? "")")
            return
        }
        writeCharacteristic = write
        writeType = write.properties.contains(.write) ? .withResponse : .withoutResponse
        // Subscribing triggers iOS's pairing prompt the first time; the breezer must be in pairing mode.
        peripheral.setNotifyValue(true, for: notify)
    }

    private func notificationStateChanged(_ peripheral: CBPeripheral, isNotifying: Bool, error: String?) {
        if let error {
            giveUp(peripheral, "Pairing or subscription failed: \(error). Put the breezer in pairing mode (hold its button until the light flashes blue) and try again.")
            return
        }
        guard isNotifying else { return }
        assembler.reset()
        status = .ready
        addLog(.info, "Ready")
        onReady?()
    }

    private func wroteValue(error: String?) {
        if let error {
            addLog(.error, "Write failed: \(error)")
            failInFlight(LinkError.transport(error))
            return
        }
        writeNextFrame()
    }

    private func giveUp(_ peripheral: CBPeripheral, _ message: String) {
        addLog(.error, message)
        keepConnected = false
        central.cancelPeripheralConnection(peripheral)
        connectionClosed()
        status = .failed(message)
    }
}

extension BreezerLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { self.centralStateChanged(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let manufacturer = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) }
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            self.didDiscover(peripheral, name: name, manufacturerData: manufacturer, rssi: rssi)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.didConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "Couldn't connect"
        MainActor.assumeIsolated { self.connectionLost(peripheral, reason: reason) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription
        MainActor.assumeIsolated { self.connectionLost(peripheral, reason: reason) }
    }
}

extension BreezerLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { self.servicesDiscovered(peripheral, error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { self.characteristicsDiscovered(peripheral, service: service, error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        let notifying = characteristic.isNotifying
        MainActor.assumeIsolated { self.notificationStateChanged(peripheral, isNotifying: notifying, error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == TionBLE.notify, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        MainActor.assumeIsolated { self.received(bytes) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { self.wroteValue(error: message) }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.writeNextFrame() }
    }
}
