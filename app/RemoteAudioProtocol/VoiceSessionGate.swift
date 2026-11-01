/// Once suppressed, a physical voice session stays silent through its buffered tail.
/// Only a new protocol start can re-enable output.
public struct VoiceSessionGate {
    public private(set) var allowsPackets = false
    public init() {}
    public mutating func update(blocked: Bool) {
        if blocked { allowsPackets = false }
    }
    public mutating func started(blocked: Bool) { allowsPackets = !blocked }
}
