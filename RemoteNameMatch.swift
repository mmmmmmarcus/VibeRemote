import Foundation

/// Bluetooth-name heuristics for recognizing the Siri Remote outside of IOKit HID.
///
/// Some remotes are paired under their serial number (for example "XXXXXXXXXXXX"), which no
/// "remote"/"siri" substring can recognize, while AirPods renamed after the owner's Siri
/// voice ("Siri's AirPods") match it. `RemoteDetector` identifies the remote by product ID,
/// so it records the HID product name of every accepted remote here; the name-only lookups
/// (microphone address, PacketLogger button sources, battery, connection quarantine) then
/// accept that learned name for the same physical remote. Learned names persist so the
/// lookups work before the remote's HID interfaces enumerate after launch.
enum RemoteNameMatch {
    static let learnedNamesKey = "learnedRemoteNames"
    private static let maxLearnedNames = 8

    static func learn(_ name: String, defaults: UserDefaults = .standard) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isHeuristicRemoteName(trimmed) else { return }
        var names = defaults.stringArray(forKey: learnedNamesKey) ?? []
        guard !names.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        names.append(trimmed)
        defaults.set(Array(names.suffix(maxLearnedNames)), forKey: learnedNamesKey)
    }

    static func isLearned(_ name: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let names = defaults.stringArray(forKey: learnedNamesKey) ?? []
        return names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Names that belong to other Apple audio accessories even when they mention Siri.
    static func isExcludedAccessoryName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("airpods") || lowered.contains("beats")
    }

    static func isHeuristicRemoteName(_ name: String) -> Bool {
        guard !isExcludedAccessoryName(name) else { return false }
        let lowered = name.lowercased()
        return lowered.contains("remote") || lowered.contains("siri") || lowered.contains("apple tv")
    }

    static func isRemoteName(_ name: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return isLearned(name, defaults: defaults) || isHeuristicRemoteName(name)
    }
}
