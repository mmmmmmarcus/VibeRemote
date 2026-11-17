import Foundation

enum KeyboardLanguage: String {
    case chinese, english

    static let preferenceKey = "keyboardTypingLanguage"
    var keyTitle: String { self == .chinese ? "中" : "EN" }
    var name: String { self == .chinese ? "Chinese" : "English" }
    var next: Self { self == .chinese ? .english : .chinese }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .chinese
    }
    func save(to defaults: UserDefaults = .standard) {
        // Extension-local preferences keep ordinary typing independent of Full Access.
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}
