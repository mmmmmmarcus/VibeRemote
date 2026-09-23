import Foundation
import IOBluetooth
import CoreBluetooth
import Darwin

private struct PacketCaptureFileState {
    let inode: UInt64
    let size: UInt64

    static func read(path: String) -> Self? {
        var info = Darwin.stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        guard result == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return nil }
        return Self(inode: UInt64(info.st_ino), size: UInt64(info.st_size))
    }
}

enum PacketLoggerLineRoute: Equatable {
    case buttons
    case touch
    case irrelevant

    static func classify(_ line: String) -> Self {
        classifyASCII(line.utf8)
    }

    static func classify(_ bytes: Data.SubSequence) -> Self {
        classifyASCII(bytes)
    }

    private static func classifyASCII<S: Sequence>(_ bytes: S) -> Self where S.Element == UInt8 {
        var window: UInt64 = 0
        for byte in bytes {
            window = ((window << 8) | UInt64(byte)) & 0x00FF_FFFF_FFFF_FFFF
            switch window {
            case 0x20_31_42_20_33_39_20: return .buttons // " 1B 39 "
            case 0x20_31_42_20_32_33_20,               // " 1B 23 "
                 0x20_31_42_20_33_44_20: return .touch // " 1B 3D "
            default: break
            }
        }
        return .irrelevant
    }
}

/// Aluminum remote report FB: mute is bit 7, play/pause bit 8 in its HID
/// descriptor. Captured ATT characteristic 0039 carries that same 16-bit mask.
/// Old-remote 0023 reports are never interpreted as button masks; only their
/// narrowly framed 0x32 touch payloads are decoded by `touch` below.
struct PacketLoggerButtonParser {
    struct Edge: Equatable {
        let button: String
        let pressed: Bool
        let sender: UInt64
        let capturedAt: Date
        let deviceLabel: String
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
        let edges: [Edge] = [("playPause", UInt16(0x100)), ("mute", UInt16(0x80)), ("back", UInt16(0x40)), ("tv", UInt16(0x01)), ("volumeUp", UInt16(0x02)), ("volumeDown", UInt16(0x04))].compactMap { button, bit in
            guard (previous ^ mask) & bit != 0 else { return nil }
            return Edge(button: button, pressed: mask & bit != 0,
                        sender: UInt64(handle) + 1, capturedAt: stamp, deviceLabel: label)
        }
        // One BLE report can contain multiple transitions. Establish the menu hold
        // before chord downs, and release it after them, regardless of descriptor order.
        func priority(_ edge: Edge) -> Int { edge.button == "mute" ? (edge.pressed ? 0 : 2) : 1 }
        return edges.sorted { priority($0) < priority($1) }
    }

    func touch(line: String, allowedLabels: Set<String>, now: Date) -> RemoteTextTouchFrame? {
        guard let split = line.range(of: " RECV ") else { return nil }
        let header = line[..<split.lowerBound].split(whereSeparator: { $0.isWhitespace })
        guard header.count >= 5, allowedLabels.contains(header.dropFirst(3).dropLast().joined(separator: " ")) else { return nil }
        let hex = line[split.upperBound...].split(whereSeparator: { $0.isWhitespace })
        let b = hex.compactMap { UInt8($0, radix: 16) }
        guard b.count == hex.count, b.count >= 11, b[1] & 0xf0 == 0x20,
              Int(b[2]) == b.count - 4, b[3] == 0, Int(b[4]) == b.count - 8,
              Array(b[5...8]) == [0, 4, 0, 0x1b] else { return nil }
        let handle = UInt16(b[0]) | UInt16(b[1] & 15) << 8
        guard UInt16(header.last!.dropFirst(2), radix: 16) == handle,
              let stamp = formatter.date(from: "\(header[0]) \(header[1]) \(header[2]) \(Calendar.current.component(.year, from: now))"),
              now.timeIntervalSince(stamp) >= -0.03, now.timeIntervalSince(stamp) <= 0.18 else { return nil }
        let payload = Array(b[11...])
        switch (b[9], b[10]) {
        case (0x3d, 0):
            return RemoteTextTouchFrame.decode(payload, sender: UInt64(handle) + 1, time: stamp)
        case (0x23, 0):
            return RemoteTextTouchFrame.decodeGlass(payload, sender: UInt64(handle) + 1, time: stamp)
        default:
            return nil
        }
    }

}

/// Bounded reads of the private capture file: never opens a remote HID/GATT interface.
/// Inode/truncation changes reset button state; timestamps reject PacketLogger replay.
@MainActor
final class PacketLoggerButtonMonitor {
    private static let maximumCaptureBytes: UInt64 = 32 * 1024 * 1024
    var onEdge: ((PacketLoggerButtonParser.Edge) -> Void)?
    var onTouch: ((RemoteTextTouchFrame) -> Void)?
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
    var isReadingCapture: Bool { reader != nil }
    func pollNow() { if let path { poll(path: path) } }

    func start(path: String) {
        guard timer == nil else { return }
        startedAt = Date()
        self.path = path
        rmDebug("PacketLogger button monitor started: \(path)")
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
            let updatedLabels = Set(devices.compactMap { device -> String? in
                guard let name = device.name, name.lowercased().contains("remote") || name.lowercased().contains("siri") else { return nil }
                let label = String(name.prefix(17))
                return allLabels.filter { $0 == label }.count == 1 ? label : nil
            })
            if labels != updatedLabels {
                labels = updatedLabels
                rmDebug("PacketLogger button sources: \(labels.sorted())")
            }
            labelsUpdated = now
        }
        // This runs at the touch-report cadence. Foundation's full attribute lookup also
        // fetches extended attributes and user/group metadata, which made an idle app burn
        // several percent CPU. lstat supplies the two fields needed for replacement and
        // truncation detection without that extra filesystem work. Reject symlinks here;
        // the privileged supervisor creates a regular, user-owned capture file.
        guard let state = PacketCaptureFileState.read(path: path) else {
            if reader != nil { resetReader() }; return
        }
        let id = state.inode, size = state.size
        if inode != id || size < offset {
            resetReader()
            inode = id
        }
        if reader == nil {
            // The root supervisor creates the file before chown/chmod. Its inode can
            // already be visible while open is denied. Retry the same inode next poll.
            let descriptor = path.withCString {
                Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { return }
            var openedInfo = Darwin.stat()
            guard Darwin.fstat(descriptor, &openedInfo) == 0,
                  openedInfo.st_mode & S_IFMT == S_IFREG,
                  UInt64(openedInfo.st_ino) == id else {
                Darwin.close(descriptor)
                return
            }
            let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            reader = opened
            rmDebug("PacketLogger button reader opened: inode=\(id) size=\(size)")
        }
        if size > Self.maximumCaptureBytes, let reader {
            // The voice helper reads the live FIFO, not this history file. Bound only the
            // passive button/touch copy through its already-open descriptor so replacing
            // the path cannot redirect a privileged truncate. tee uses O_APPEND and will
            // continue at byte zero. Resetting releases any gesture spanning the boundary.
            if Darwin.ftruncate(reader.fileDescriptor, 0) == 0 {
                rmDebug("PacketLogger capture reached 32 MB; truncating passive history")
                resetReader()
                return
            }
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
                let route = PacketLoggerLineRoute.classify(pending[..<end])
                let line = route == .irrelevant ? nil : String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                // PacketLogger includes every Bluetooth controller record. Route only the
                // remote ATT characteristics before splitting and hex-decoding the line;
                // otherwise unrelated traffic is parsed twice at the touch polling rate.
                switch route {
                case .buttons:
                    guard let line else { continue }
                    let edges = parser.events(line: line, allowedLabels: labels, now: now)
                    for edge in edges where edge.capturedAt >= startedAt { onEdge?(edge) }
                case .touch:
                    guard let line else { continue }
                    if let touch = parser.touch(line: line, allowedLabels: labels, now: now),
                       touch.time >= startedAt { onTouch?(touch) }
                case .irrelevant:
                    break
                }
            }
            if pending.count > 16384 { pending.removeAll() }
        } catch { resetReader() }
    }
}
