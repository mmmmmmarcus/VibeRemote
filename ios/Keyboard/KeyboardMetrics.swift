import UIKit

/// iOS 27 Figma references: 12890:27040 / 31610 / 31654 / 30558, and 12740:24279.
/// Keep device-specific safe areas system-owned rather than drawing a phone frame.
struct KeyboardMetrics {
    enum Arrangement { case phone, outerPortrait, innerPortrait, outerLandscape, innerLandscape, tablet }
    let arrangement: Arrangement
    let mini: Bool
    var tablet: Bool { arrangement == .tablet }
    /// Language and emoji sit inside the bottom key row. Regular iPhones use
    /// the same single bottom row as Duo (2026-11-26); no extra accessory row.
    var inlineAccessories: Bool { arrangement == .phone || arrangement == .outerPortrait || arrangement == .innerPortrait || arrangement == .outerLandscape }
    var split: Bool { arrangement == .innerLandscape }
    private(set) var inset: CGFloat
    let keyHeight: CGFloat
    let rowGap: CGFloat
    let keyGap: CGFloat
    let middleInset: CGFloat
    let sideGap: CGFloat
    let shiftWidth: CGFloat
    let returnWidth: CGFloat
    let cornerRadius: CGFloat
    let fontSize: CGFloat
    var candidateHeight: CGFloat { mini ? 0 : split ? 43.333 : arrangement == .outerLandscape ? 43 : 47 }
    var topInset: CGFloat { mini ? inset : 0 }
    var bottomInset: CGFloat { mini ? inset : arrangement == .outerLandscape ? 4 : split ? 3.667 : arrangement == .innerPortrait ? 3.333 : arrangement == .outerPortrait ? 6.667 : 0 }
    var contentHeight: CGFloat { topInset + candidateHeight + (mini ? 1 : tablet ? 5 : 4) * keyHeight + (mini ? 0 : tablet ? 4 : 3) * rowGap + bottomInset }
    var miniFunctionWidth: CGFloat { max(44, min(60, shiftWidth)) }
    /// One letter key in the phone's ten-key top row.
    let letterWidth: CGFloat
    var switcherWidth: CGFloat { arrangement == .phone ? letterWidth : split ? 46.667 : arrangement == .outerLandscape ? 45.333 : arrangement == .innerPortrait ? 50.667 : arrangement == .outerPortrait ? 39.667 : 42 }
    let modeWidth: CGFloat
    /// Phone: 123 and Language are both 1.25 letter keys. Duo keeps its measured widths.
    var languageWidth: CGFloat { arrangement == .phone ? modeWidth : switcherWidth }
    var letterFont: UIFont { UIFont(name: "SFCompact-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize) }

    init(width: CGFloat, landscape: Bool = false, mini: Bool = false, tablet: Bool = false) {
        self.mini = mini
        var phoneLetter: CGFloat = 0
        if tablet && width >= 600 {
            arrangement = .tablet
            inset = 8; keyHeight = landscape ? 54 : 50; rowGap = 8; keyGap = 7
            middleInset = 20; sideGap = 12; shiftWidth = 76; returnWidth = 100
            modeWidth = 60; cornerRadius = 8; fontSize = 24
        } else if width >= 750 && landscape || width >= 800 {
            arrangement = .innerLandscape
            inset = 10.333; keyHeight = 42.333; rowGap = 13; keyGap = 10.333
            middleInset = 39.67; sideGap = 26; shiftWidth = 92.667
            returnWidth = 112; modeWidth = 46.667; cornerRadius = 12; fontSize = 30
        } else if landscape {
            arrangement = .outerLandscape
            inset = 5; keyHeight = 33.333; rowGap = 9; keyGap = 7.333
            middleInset = 26; sideGap = 17.67; shiftWidth = 60.333
            returnWidth = 104; modeWidth = 45.333; cornerRadius = 10; fontSize = 25
        } else if width >= 600 {
            arrangement = .innerPortrait
            inset = 11.667; keyHeight = 49.667; rowGap = 14; keyGap = 9
            middleInset = 32.333; sideGap = 22; shiftWidth = 74.333
            returnWidth = 120; modeWidth = 50.667; cornerRadius = 12; fontSize = 31
        } else if width >= 450 {
            arrangement = .outerPortrait
            // Measured against both native keyboards on iPhone Duo, 2026-11-16.
            inset = 0; keyHeight = 44.667; rowGap = 11.667; keyGap = 6.667
            middleInset = 22.667; sideGap = 14.667; shiftWidth = 54
            returnWidth = 96; modeWidth = 39.667; cornerRadius = 10; fontSize = 28
        } else {
            arrangement = .phone
            inset = 6.67; keyHeight = 43; rowGap = 11; keyGap = 6
            middleInset = 20; sideGap = 13.333; shiftWidth = 45
            // Bottom row (designer spec 2026-11-26): 123 and Language 1.25,
            // Emoji 1, Return 2.5 letter keys; Space takes the rest.
            let letter = max(20, (width - 2 * 6.67 - 9 * 6) / 10); phoneLetter = letter
            returnWidth = 2.5 * letter
            modeWidth = 1.25 * letter; cornerRadius = 8.5; fontSize = 25
        }
        letterWidth = phoneLetter
        // Mini has no candidate strip to provide breathing room. Match its top
        // and sides, including the full-layout Duo variant with no side inset.
        if mini { inset = max(8, inset) }
    }

    @MainActor static let actionKeyFill = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
    @MainActor static let actionKeyInk = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }

    /// Opaque candidate strip: nothing behind the keyboard shows through the
    /// words. With `.label` text this stays well above 4.5:1 in both appearances.
    @MainActor static let candidateFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.137, green: 0.137, blue: 0.149, alpha: 1)
            : UIColor(red: 0.835, green: 0.847, blue: 0.867, alpha: 1)
    }

    @MainActor static let keyFill = UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        if traits.accessibilityContrast == .high || UIAccessibility.isReduceTransparencyEnabled {
            return UIColor(white: dark ? 0.27 : 1, alpha: 1)
        }
        // Near-white caps in light mode, with a little of the system's tinted
        // backdrop still visible. Keep the darker glass treatment in dark mode.
        return UIColor(white: 1, alpha: dark ? 0.18 : 0.96)
    }
}
