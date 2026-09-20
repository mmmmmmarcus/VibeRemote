import Foundation
import IOBluetooth
import CoreBluetooth

/// Aluminum remote report FB: mute is bit 7, play/pause bit 8 in its HID
/// descriptor. Captured ATT characteristic 0039 carries that same 16-bit mask.
/// Old-remote 0023 voice reports are deliberately not interpreted as button masks.
struct PacketLoggerButtonParser {
    struct Edge: Equatable {
        let button: String
        let pressed: Bool
        let sender: UInt64
        let capturedAt: Date
    }
    private var masks: [UInt16: UInt16] = [:]
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm:ss.SSS yyyy"
        return f
    }()

    mutating func events(line: String, allowedLabels: Set<String>, now: Date) -> [Edge] {
        guard let split = line.range(of: " RECV ") else { return [] }
        let header = line[..<split.lowerBound].split(whereSeparator: { $0.isWhitespace })
        guard header.count >= 5 else { return [] }
        let label = header.dropFirst(3).dropLast().joined(separator: " ")
        guard allowedLabels.contains(label) else { return [] }
        let year = Calendar.current.component(.year, from: now)
        guard let stamp = formatter.date(from: "\(header[0]) \(header[1]) \(header[2]) \(year)"),
              now.timeIntervalSince(stamp) >= -0.03, now.timeIntervalSince(stamp) <= 3 else { return [] }
        let hex = line[split.upperBound...].split(whereSeparator: { $0.isWhitespace })
        let bytes = hex.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == hex.count, bytes.count == 13,
              bytes[1] & 0xf0 == 0x20, Array(bytes[2...10]) == [9, 0, 5, 0, 4, 0, 0x1b, 0x39, 0] else { return [] }
        let handle = UInt16(bytes[0]) | UInt16(bytes[1] & 0x0f) << 8
        guard UInt16(header.last!.dropFirst(2), radix: 16) == handle else { return [] }
        let mask = UInt16(bytes[11]) | UInt16(bytes[12]) << 8
        let previous = masks[handle] ?? 0
        if masks.count > 16 { masks.removeAll() }
        masks[handle] = mask
        return [("playPause", UInt16(0x100)), ("mute", UInt16(0x80))].compactMap { button, bit in
            guard (previous ^ mask) & bit != 0 else { return nil }
            return Edge(button: button, pressed: mask & bit != 0,
                        sender: UInt64(handle) + 1, capturedAt: stamp)
        }
    }
}

/// Bounded reads of the private capture file: never opens a remote HID/GATT interface.
/// Inode/truncation changes reset button state; timestamps reject PacketLogger replay.
@MainActor
final class PacketLoggerButtonMonitor {
    var onEdge: ((PacketLoggerButtonParser.Edge) -> Void)?
    var onReset: (() -> Void)?
    private var timer: Timer?
    private var reader: FileHandle?
    private var inode: UInt64?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var parser = PacketLoggerButtonParser()
    private var labels: Set<String> = []
    private var labelsUpdated = Date.distantPast
    private var startedAt = Date()
    private var path: String?
    func pollNow() { if let path { poll(path: path) } }

    func start(path: String) {
        guard timer == nil else { return }
        startedAt = Date()
        self.path = path
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(path: path) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        timer?.invalidate(); timer = nil; path = nil
        resetReader()
    }
    private func resetReader() {
        try? reader?.close(); reader = nil; inode = nil; offset = 0
        pending.removeAll(); parser = PacketLoggerButtonParser(); onReset?()
    }
    private func poll(path: String) {
        let now = Date()
        if now.timeIntervalSince(labelsUpdated) > 15, CBManager.authorization == .allowedAlways {
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            // PacketLogger truncates names to 17 characters. Ambiguous labels fail closed.
            let allLabels = devices.compactMap { $0.name }.map { String($0.prefix(17)) }
            labels = Set(devices.compactMap { device -> String? in
                guard let name = device.name, name.lowercased().contains("remote") || name.lowercased().contains("siri") else { return nil }
                let label = String(name.prefix(17))
                return allLabels.filter { $0 == label }.count == 1 ? label : nil
            })
            labelsUpdated = now
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let id = attrs[.systemFileNumber] as? UInt64, let size = attrs[.size] as? UInt64 else {
            if reader != nil { resetReader() }; return
        }
        if inode != id || size < offset {
            resetReader()
            reader = FileHandle(forReadingAtPath: path); inode = id
        }
        guard let reader, size > offset else { return }
        do {
            // After a stall skip a large backlog rather than block the main event tap.
            if size - offset > 65536 {
                offset = size - 65536; try reader.seek(toOffset: offset)
                pending.removeAll(); parser = PacketLoggerButtonParser(); onReset?()
                let data = try reader.read(upToCount: 65536) ?? Data()
                offset += UInt64(data.count)
                if let newline = data.firstIndex(of: 10) { pending.append(data.suffix(from: data.index(after: newline))) }
            } else {
                let data = try reader.read(upToCount: 65536) ?? Data()
                offset += UInt64(data.count); pending.append(data)
            }
            while let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                for edge in parser.events(line: line, allowedLabels: labels, now: now) where edge.capturedAt >= startedAt {
                    onEdge?(edge)
                }
            }
            if pending.count > 16384 { pending.removeAll() }
        } catch { resetReader() }
    }
}
