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

enum PacketLoggerLineRoute: Equatable, Sendable {
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
    struct Edge: Equatable, Sendable {
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
        let hex = line[split.upperBound...].split(whereSeparator: { $0.isWhitespace })
        guard hex.count == 13 else { return [] }
        let bytes = hex.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == hex.count, bytes.count == 13,
              bytes[1] & 0xf0 == 0x20, Array(bytes[2...10]) == [9, 0, 5, 0, 4, 0, 0x1b, 0x39, 0] else { return [] }
        let handle = UInt16(bytes[0]) | UInt16(bytes[1] & 0x0f) << 8
        guard UInt16(header.last!.dropFirst(2), radix: 16) == handle else { return [] }
        let year = Calendar.current.component(.year, from: now)
        guard let stamp = formatter.date(from: "\(header[0]) \(header[1]) \(header[2]) \(year)"),
              now.timeIntervalSince(stamp) >= -0.03, now.timeIntervalSince(stamp) <= 3 else { return [] }
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
        // Only the two generations' documented touch frame sizes can reach the
        // decoder. Voice/media records do not need hex conversion or date parsing.
        guard [22, 29, 24, 31].contains(hex.count) else { return nil }
        let b = hex.compactMap { UInt8($0, radix: 16) }
        guard b.count == hex.count, b.count >= 11, b[1] & 0xf0 == 0x20,
              Int(b[2]) == b.count - 4, b[3] == 0, Int(b[4]) == b.count - 8,
              Array(b[5...8]) == [0, 4, 0, 0x1b] else { return nil }
        let handle = UInt16(b[0]) | UInt16(b[1] & 15) << 8
        guard UInt16(header.last!.dropFirst(2), radix: 16) == handle,
              let stamp = formatter.date(from: "\(header[0]) \(header[1]) \(header[2]) \(Calendar.current.component(.year, from: now))"),
              // PacketLogger's capture clock can lead the app's wall clock: live
              // records on this Mac arrived 80–93 ms "in the future". The former
              // 30 ms bound silently dropped every touch. Allow bounded clock skew
              // without widening stale replay acceptance or rewriting frame times
              // (batched frames must keep their original gesture intervals).
              now.timeIntervalSince(stamp) >= -0.18, now.timeIntervalSince(stamp) <= 0.18 else { return nil }
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

/// Main-thread delivery preserves ordering with the NX event tap. In particular,
/// pollNow is a serial-worker barrier: queued capture edges are delivered before
/// MediaKeyInterceptor resolves its 160 ms deferred native event.
@MainActor
final class PacketLoggerButtonMonitor {
    var onEdge: ((PacketLoggerButtonParser.Edge) -> Void)?
    var onTouch: ((RemoteTextTouchFrame) -> Void)?
    var onReset: (() -> Void)?
    private var worker: PacketCaptureReader?
    private var labelsTimer: Timer?
    private let labelProvider: (() -> Set<String>)?
    private var labels: Set<String> = []

    init(labelProvider: (() -> Set<String>)? = nil) { self.labelProvider = labelProvider }
    var isReadingCapture: Bool { worker?.isReading ?? false }
    var capturePollCount: Int { worker?.pollCount ?? 0 }

    func start(path: String) {
        guard worker == nil else { return }
        refreshLabels()
        let reader = PacketCaptureReader(path: path, labels: labels) { [weak self] in
            DispatchQueue.main.async { self?.deliverPending() }
        }
        worker = reader
        reader.start()
        rmDebug("PacketLogger button monitor started: \(path)")
        // Device inventory is independent of file traffic. No Bluetooth work on
        // every capture notification, and no persistent high-frequency main timer.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLabels() }
        }
        timer.tolerance = 1
        labelsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        labelsTimer?.invalidate(); labelsTimer = nil
        worker?.stop(); worker = nil
        onReset?()
    }

    func pollNow() {
        if labelProvider != nil { refreshLabels() }
        worker?.pollNow()
        deliverPending()
    }

    private func refreshLabels() {
        let updated: Set<String>
        if let labelProvider { updated = labelProvider() }
        else {
            guard CBManager.authorization == .allowedAlways else { return }
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let allLabels = devices.compactMap { $0.name }.map { String($0.prefix(17)) }
            updated = Set(devices.compactMap { device -> String? in
                guard let name = device.name, name.lowercased().contains("remote") || name.lowercased().contains("siri") else { return nil }
                let label = String(name.prefix(17))
                return allLabels.filter { $0 == label }.count == 1 ? label : nil
            })
        }
        if labels != updated {
            labels = updated
            rmDebug("PacketLogger button sources: \(labels.sorted())")
        }
        worker?.updateLabels(labels)
    }

    private func deliverPending() {
        guard let worker else { return }
        for delivery in worker.takeDeliveries() {
            // A callback can stop/restart capture. Never deliver the old reader's
            // remaining events into the new session.
            guard self.worker === worker else { break }
            switch delivery {
            case .reset: onReset?()
            case .edge(let edge): onEdge?(edge)
            case .touch(let frame): onTouch?(frame)
            }
        }
    }
}

/// All mutable state is confined to queue. It never calls main synchronously;
/// the main facade can therefore safely flush it before NX source matching.
private final class PacketCaptureReader: @unchecked Sendable {
    enum Delivery: Sendable {
        case reset
        case edge(PacketLoggerButtonParser.Edge)
        case touch(RemoteTextTouchFrame)
    }
    private static let maximumCaptureBytes: UInt64 = 32 * 1024 * 1024
    private let queue = DispatchQueue(label: "com.viberemote.capture-reader", qos: .userInitiated)
    private let path: String
    private let notify: @Sendable () -> Void
    private let startedAt = Date()
    private var labels: Set<String>
    private var reader: FileHandle?
    private var inode: UInt64?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var parser = PacketLoggerButtonParser()
    private var loggedTouchStream = false
    private var source: DispatchSourceFileSystemObject?
    private var fallback: DispatchSourceTimer?
    private var scheduledRead: DispatchWorkItem?
    private var running = false
    private var deliveries: [Delivery] = []
    private let output = DeliveryBuffer()
    private var polls = 0

    /// Main delivery never waits for file I/O or parser work. Only the explicit
    /// NX pollNow barrier waits on queue; this lock protects a small value buffer.
    private final class DeliveryBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Delivery] = []
        private var scheduled = false
        private var reading = false
        var isReading: Bool { lock.lock(); defer { lock.unlock() }; return reading }
        func setReading(_ value: Bool) { lock.lock(); reading = value; lock.unlock() }
        func append(_ batch: [Delivery]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            values.append(contentsOf: batch)
            // A stalled main runloop cannot build unbounded buffered touch data.
            // A dropped batch resets held buttons and gestures before new data.
            if values.count > 4096 { values = [.reset] }
            guard !values.isEmpty, !scheduled else { return false }
            scheduled = true
            return true
        }
        func take() -> [Delivery] {
            lock.lock(); defer { lock.unlock() }
            let result = values
            values.removeAll(keepingCapacity: true); scheduled = false
            return result
        }
    }

    init(path: String, labels: Set<String>, notify: @escaping @Sendable () -> Void) {
        self.path = path; self.labels = labels; self.notify = notify
    }
    var isReading: Bool { output.isReading }
    var pollCount: Int { queue.sync { polls } }
    func updateLabels(_ labels: Set<String>) { queue.async { self.labels = labels } }
    func start() {
        queue.async {
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.setEventHandler { [weak self] in self?.readAndNotify() }
            self.fallback = timer
            self.scheduleFallback(open: false)
            timer.resume()
            self.readAndNotify()
        }
    }
    func stop() {
        queue.sync {
            running = false
            scheduledRead?.cancel(); scheduledRead = nil
            fallback?.cancel(); fallback = nil
            resetReader(); deliveries.removeAll(); _ = output.take()
        }
    }
    func pollNow() { queue.sync { readAndNotify() } }
    func takeDeliveries() -> [Delivery] { output.take() }
    private func scheduleFallback(open: Bool) {
        // Notification is primary. A one-second safety check catches lost events
        // or path replacement; denied/missing opens retry in 100 ms so a new
        // capture still arrives within the existing 180 ms touch freshness bound.
        let interval: DispatchTimeInterval = open ? .seconds(1) : .milliseconds(100)
        fallback?.schedule(deadline: .now() + interval, repeating: interval,
                           leeway: open ? .milliseconds(100) : .milliseconds(10))
    }
    private func watch(descriptor: Int32) {
        let watched = Darwin.dup(descriptor)
        guard watched >= 0 else { return }
        // dup clears FD_CLOEXEC; command/helper launches must not inherit this fd.
        guard Darwin.fcntl(watched, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(watched); return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watched,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.running, self.scheduledRead == nil else { return }
            // Coalesce Bluetooth bursts without postponing indefinitely. The
            // former 20 ms cadence is retained as an upper batching delay.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scheduledRead = nil; self.readAndNotify()
            }
            self.scheduledRead = work
            self.queue.asyncAfter(deadline: .now() + .milliseconds(20), execute: work)
        }
        source.setCancelHandler { Darwin.close(watched) }
        self.source = source
        source.resume()
    }
    private func resetReader() {
        source?.cancel(); source = nil
        try? reader?.close(); reader = nil; inode = nil; offset = 0
        output.setReading(false)
        loggedTouchStream = false
        pending.removeAll(); parser = PacketLoggerButtonParser()
        deliveries.append(.reset)
        if running { scheduleFallback(open: false) }
    }
    private func readAndNotify() {
        guard running else { return }
        polls += 1
        poll()
        let shouldNotify = output.append(deliveries)
        deliveries.removeAll(keepingCapacity: true)
        if shouldNotify { notify() }
    }
    private func poll() {
        let now = Date()
        // Metadata and parsing stay on this serial queue. Reject symlinks before
        // opening the private capture; the supervisor creates a regular file.
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
            output.setReading(true)
            watch(descriptor: descriptor)
            scheduleFallback(open: source != nil)
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
                pending.removeAll(); parser = PacketLoggerButtonParser(); deliveries.append(.reset)
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
                    for edge in edges where edge.capturedAt >= startedAt { deliveries.append(.edge(edge)) }
                case .touch:
                    guard let line else { continue }
                    if let touch = parser.touch(line: line, allowedLabels: labels, now: now),
                       touch.time >= startedAt {
                        if !loggedTouchStream {
                            loggedTouchStream = true
                            rmDebug("PacketLogger touch stream received: source=\(touch.sender) captureAgeMs=\(Int(now.timeIntervalSince(touch.time) * 1000))")
                        }
                        deliveries.append(.touch(touch))
                    }
                case .irrelevant:
                    break
                }
            }
            if pending.count > 16384 { pending.removeAll() }
        } catch { resetReader() }
    }
}
