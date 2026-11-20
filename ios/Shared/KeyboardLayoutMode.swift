import Foundation

enum KeyboardLayoutMode: String {
    case full, mini

    static let preferenceKey = "keyboardLayoutMode"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .full
    }
    func save(to defaults: UserDefaults = .standard) {
        // Extension-local, so reopening the keyboard needs no Full Access.
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}
