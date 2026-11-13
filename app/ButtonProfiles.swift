import AppKit

/// Per-app button profiles (2026-11-10, user's request, modeled on Logitech's app-specific
/// profiles). General is the fallback: an app with no profile of its own, or a button an app
/// profile leaves alone, does what General says. An app profile stores only the buttons the
/// user changed for that app, so a later change to General still reaches every button an app
/// never touched.
///
/// The profile is chosen by the frontmost app at the press and latched until the release (see
/// `ButtonProfileLatch`), so a press that switches apps itself, such as Toggle Codex / Claude,
/// never releases under a different profile from the one it pressed under.
struct ButtonProfile: Equatable, Sendable {
    static let generalID = "general"

    /// nil for General.
    var bundleID: String?
    var name: String
    /// Siri's choice. General always has one; nil in an app profile follows General.
    var siriAction: ButtonAction?
    /// Explicit per-button choices, per remote family, keyed by `RemoteButtonMapping.overrideKey`.
    var overrides: [RemoteGeneration: [String: ButtonAction]] = [:]

    var id: String { bundleID ?? Self.generalID }
    var isGeneral: Bool { bundleID == nil }
}

struct ButtonProfileSet: Equatable, Sendable {
    var general: ButtonProfile
    var apps: [ButtonProfile]

    static let claudeBundleID = "com.anthropic.claudefordesktop"
    /// The Codex desktop app, installed locally as ChatGPT.app.
    static let chatGPTBundleID = "com.openai.codex"

    var all: [ButtonProfile] { [general] + apps }

    func profile(id: String) -> ButtonProfile? { all.first { $0.id == id } }

    /// The profile a press in `bundleID` uses: its own, or General.
    func profileID(forFrontmost bundleID: String?) -> String {
        guard let bundleID, apps.contains(where: { $0.bundleID == bundleID }) else { return ButtonProfile.generalID }
        return bundleID
    }

    func siriAction(profile id: String) -> ButtonAction {
        let fallback = general.siriAction ?? Self.siriDefault
        guard id != ButtonProfile.generalID else { return fallback }
        return profile(id: id)?.siriAction ?? fallback
    }

    /// General's choices with the app's explicit ones on top.
    func overrides(profile id: String, generation: RemoteGeneration) -> [String: ButtonAction] {
        var merged = general.overrides[generation] ?? [:]
        if id != ButtonProfile.generalID, let app = profile(id: id) {
            merged.merge(app.overrides[generation] ?? [:]) { _, explicit in explicit }
        }
        return merged
    }

    func action(button: String, generation: RemoteGeneration, profile id: String) -> ButtonAction {
        RemoteButtonMapping.action(button: button, generation: generation, siriAction: siriAction(profile: id),
                                   overrides: overrides(profile: id, generation: generation))
    }

    /// Whether `key` ("siri" or an override key) follows General in this app profile.
    func inherits(_ key: String, profile id: String, generation: RemoteGeneration) -> Bool {
        guard id != ButtonProfile.generalID, let app = profile(id: id) else { return false }
        if key == "siri" { return app.siriAction == nil }
        return app.overrides[generation]?[RemoteButtonMapping.overrideKey(key)] == nil
    }

    /// Profiles whose Siri ends up as `action`, for the Dictation pane.
    func profiles(withSiri action: ButtonAction) -> [ButtonProfile] {
        all.filter { siriAction(profile: $0.id) == action }
    }

    // MARK: Editing

    /// `nil` makes an app profile follow General again; General cannot follow itself, so there
    /// it means the button's default. Choosing General's default removes the entry.
    mutating func set(_ action: ButtonAction?, for button: String, generation: RemoteGeneration, profile id: String) {
        let key = RemoteButtonMapping.overrideKey(button)
        guard let choices = RemoteButtonMapping.choices(button: key, generation: generation) else { return }
        if let action, !choices.contains(action) { return }
        update(id) { profile in
            if profile.isGeneral, let action, action != choices.first {
                profile.overrides[generation, default: [:]][key] = action
            } else if !profile.isGeneral, let action {
                profile.overrides[generation, default: [:]][key] = action
            } else {
                profile.overrides[generation]?[key] = nil
            }
            if profile.overrides[generation]?.isEmpty == true { profile.overrides[generation] = nil }
        }
    }

    mutating func setSiri(_ action: ButtonAction?, profile id: String) {
        if let action, !action.isAssignableToSiriButton { return }
        update(id) { profile in profile.siriAction = profile.isGeneral ? (action ?? Self.siriDefault) : action }
    }

    /// Appends a profile for the app, starting from its seed (the Skill trigger for Claude and
    /// ChatGPT, nothing for anything else). Adding an app that already has one does nothing.
    mutating func add(bundleID: String, name: String) {
        guard !apps.contains(where: { $0.bundleID == bundleID }) else { return }
        apps.append(Self.seed(bundleID: bundleID, name: name))
    }

    mutating func remove(_ id: String) {
        apps.removeAll { $0.id == id }
    }

    /// Restore Defaults for one profile: General loses every choice, an app profile returns to
    /// its seed.
    mutating func restore(_ id: String) {
        if id == ButtonProfile.generalID {
            general.siriAction = Self.siriDefault
            general.overrides = [:]
        } else if let index = apps.firstIndex(where: { $0.id == id }), let bundleID = apps[index].bundleID {
            apps[index] = Self.seed(bundleID: bundleID, name: apps[index].name)
        }
    }

    func isAtDefaults(_ id: String) -> Bool {
        guard let profile = profile(id: id) else { return true }
        if let bundleID = profile.bundleID { return profile == Self.seed(bundleID: bundleID, name: profile.name) }
        return profile.siriAction == Self.siriDefault && profile.overrides.isEmpty
    }

    private mutating func update(_ id: String, _ change: (inout ButtonProfile) -> Void) {
        if id == ButtonProfile.generalID { change(&general); return }
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        change(&apps[index])
    }

    // MARK: Seeds

    static let siriDefault: ButtonAction =
        remoteButtonDescriptors.first { $0.key == "siri" }?.defaultAction ?? .spaceKey

    /// A new app profile starts empty: every button follows General until the user changes it.
    /// (Claude's and ChatGPT's seeds used to pin the Skill trigger on Play/Pause; Play/Pause
    /// defaults to Esc since 2026-11-11, and `ButtonProfileStore` removed those seeds once.)
    static func seed(bundleID: String, name: String) -> ButtonProfile {
        ButtonProfile(bundleID: bundleID, name: name, siriAction: nil)
    }

    /// The Skill triggers the original Claude/ChatGPT seeds pinned on aluminum Play/Pause.
    static let retiredPlayPauseSeeds: [String: ButtonAction] = [claudeBundleID: .slashSkill, chatGPTBundleID: .dollarSkill]

    static func defaults(generalSiri: ButtonAction = siriDefault,
                         generalOverrides: [RemoteGeneration: [String: ButtonAction]] = [:]) -> ButtonProfileSet {
        ButtonProfileSet(
            general: ButtonProfile(bundleID: nil, name: "General", siriAction: generalSiri, overrides: generalOverrides),
            apps: [seed(bundleID: claudeBundleID, name: "Claude"), seed(bundleID: chatGPTBundleID, name: "ChatGPT")])
    }
}

// MARK: - Persistence

/// General keeps the keys it always had (`siriButtonAction`, `buttonActionOverrides`), so an
/// existing install keeps its choices with no migration. App profiles live in `buttonProfiles`
/// as plist dictionaries; the key's absence means "never seeded", so Claude and ChatGPT are
/// added once and stay deleted if the user removes them. Anything unknown or no longer offered
/// is dropped on read, so a stale choice never reaches the input path.
enum ButtonProfileStore {
    static let siriKey = "siriButtonAction"
    static let generalOverridesKey = "buttonActionOverrides"
    static let appsKey = "buttonProfiles"

    /// Set once the retired Play/Pause Skill seeds have been removed from saved profiles, so a
    /// later deliberate Skill choice on Play/Pause is kept.
    static let playPauseMigrationKey = "buttonProfilesPlayPauseEscMigrated"

    static func load(_ defaults: UserDefaults = .standard) -> ButtonProfileSet {
        var set = loadStored(defaults)
        if !defaults.bool(forKey: playPauseMigrationKey) {
            defaults.set(true, forKey: playPauseMigrationKey)
            var changed = false
            for index in set.apps.indices {
                guard let bundleID = set.apps[index].bundleID,
                      let seeded = ButtonProfileSet.retiredPlayPauseSeeds[bundleID] else { continue }
                for generation in RemoteGeneration.allCases
                where set.apps[index].overrides[generation]?["playPause"] == seeded {
                    set.apps[index].overrides[generation]?["playPause"] = nil
                    if set.apps[index].overrides[generation]?.isEmpty == true { set.apps[index].overrides[generation] = nil }
                    changed = true
                }
            }
            if changed, defaults.array(forKey: appsKey) != nil { save(set, defaults) }
        }
        return set
    }

    private static func loadStored(_ defaults: UserDefaults) -> ButtonProfileSet {
        let siri = defaults.string(forKey: siriKey).flatMap(ButtonAction.init(rawValue:))
            .flatMap { $0.isAssignableToSiriButton ? $0 : nil } ?? ButtonProfileSet.siriDefault
        let general = decodeOverrides(defaults.dictionary(forKey: generalOverridesKey))
        guard let stored = defaults.array(forKey: appsKey) as? [[String: Any]] else {
            return .defaults(generalSiri: siri, generalOverrides: general)
        }
        var set = ButtonProfileSet(
            general: ButtonProfile(bundleID: nil, name: "General", siriAction: siri, overrides: general), apps: [])
        for entry in stored {
            guard let bundleID = entry["bundleID"] as? String, !bundleID.isEmpty,
                  !set.apps.contains(where: { $0.bundleID == bundleID }) else { continue }
            let name = entry["name"] as? String ?? bundleID
            let siri = (entry["siri"] as? String).flatMap(ButtonAction.init(rawValue:))
                .flatMap { $0.isAssignableToSiriButton ? $0 : nil }
            set.apps.append(ButtonProfile(bundleID: bundleID, name: name, siriAction: siri,
                                          overrides: decodeOverrides(entry["overrides"] as? [String: Any])))
        }
        return set
    }

    static func save(_ set: ButtonProfileSet, _ defaults: UserDefaults = .standard) {
        defaults.set((set.general.siriAction ?? ButtonProfileSet.siriDefault).rawValue, forKey: siriKey)
        defaults.set(encodeOverrides(set.general.overrides), forKey: generalOverridesKey)
        defaults.set(set.apps.map { profile -> [String: Any] in
            var entry: [String: Any] = ["bundleID": profile.bundleID ?? "", "name": profile.name,
                                        "overrides": encodeOverrides(profile.overrides)]
            if let siri = profile.siriAction { entry["siri"] = siri.rawValue }
            return entry
        }, forKey: appsKey)
    }

    static func decodeOverrides(_ stored: [String: Any]?) -> [RemoteGeneration: [String: ButtonAction]] {
        var result: [RemoteGeneration: [String: ButtonAction]] = [:]
        for (rawGeneration, value) in stored ?? [:] {
            guard let generation = RemoteGeneration(rawValue: rawGeneration),
                  let buttons = value as? [String: String] else { continue }
            for (button, rawAction) in buttons {
                guard let action = ButtonAction(rawValue: rawAction),
                      RemoteButtonMapping.choices(button: button, generation: generation)?.contains(action) == true
                else { continue }
                result[generation, default: [:]][button] = action
            }
        }
        return result
    }

    static func encodeOverrides(_ overrides: [RemoteGeneration: [String: ButtonAction]]) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: overrides.filter { !$0.value.isEmpty }.map {
            ($0.key.rawValue, $0.value.mapValues(\.rawValue))
        })
    }
}

/// Remembers which profile each held button pressed under. The release (and every repeat in
/// between) must act under the same profile as the press: the press itself can change the
/// frontmost app, and the user can switch apps mid-hold, and a held key released under a
/// different mapping would stay down.
struct ButtonProfileLatch {
    private var pressed: [String: String] = [:]

    /// `pressed` true resolves and records; false or nil reuses the press's profile (or
    /// resolves fresh when no press was seen, e.g. a release that arrived first).
    mutating func profile(button: String, generation: RemoteGeneration, pressed isPressed: Bool?,
                          resolve: () -> String) -> String {
        let key = "\(generation.rawValue).\(button)"
        if isPressed == true {
            let id = resolve()
            pressed[key] = id
            return id
        }
        return pressed[key] ?? resolve()
    }
}

// MARK: - Installed apps

/// The apps Settings' Add App menu offers: every application bundle in the standard folders,
/// one entry per bundle identifier, sorted by name. VibeRemote itself is left out.
struct InstalledApp: Equatable, Sendable {
    let bundleID: String
    let name: String
    let url: URL

    static func scan(fileManager: FileManager = .default) -> [InstalledApp] {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", home.appendingPathComponent("Applications").path]
        var found: [String: InstalledApp] = [:]
        func visit(_ folder: URL, depth: Int) {
            guard let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension == "app" {
                    guard let bundle = Bundle(url: item), let id = bundle.bundleIdentifier,
                          id != Bundle.main.bundleIdentifier, found[id] == nil else { continue }
                    let name = fileManager.displayName(atPath: item.path)
                    found[id] = InstalledApp(bundleID: id, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                                             url: item)
                } else if depth > 0, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // Vendor folders such as /Applications/Setapp hold apps one level down.
                    visit(item, depth: depth - 1)
                }
            }
        }
        for root in roots { visit(URL(fileURLWithPath: root, isDirectory: true), depth: 1) }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A small icon for a menu item; the app's own when it is installed, a generic one otherwise.
    @MainActor
    static func icon(bundleID: String?, size: CGFloat = 16) -> NSImage {
        let image: NSImage
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if bundleID == nil {
            image = NSImage(systemSymbolName: "globe", accessibilityDescription: "General") ?? NSImage()
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}
