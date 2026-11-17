import UIKit

/// iOS 27 Figma references: 12890:27040 / 31610 / 31654 / 30558, and 12740:24279.
/// Keep device-specific safe areas system-owned rather than drawing a phone frame.
struct KeyboardMetrics {
    enum Arrangement { case phone, outerPortrait, innerPortrait, outerLandscape, innerLandscape }
    let arrangement: Arrangement
    var inlineAccessories: Bool { arrangement == .outerPortrait || arrangement == .innerPortrait || arrangement == .outerLandscape }
    var belowAccessories: Bool { arrangement == .phone }
    var split: Bool { arrangement == .innerLandscape }
    let inset: CGFloat
    let keyHeight: CGFloat
    let rowGap: CGFloat
    let keyGap: CGFloat
    let middleInset: CGFloat
    let sideGap: CGFloat
    let shiftWidth: CGFloat
    let returnWidth: CGFloat
    let cornerRadius: CGFloat
    let fontSize: CGFloat
    var candidateHeight: CGFloat { split ? 43.333 : arrangement == .outerLandscape ? 43 : 47 }
    var bottomInset: CGFloat { arrangement == .outerLandscape ? 4 : split ? 3.667 : arrangement == .innerPortrait ? 3.333 : arrangement == .outerPortrait ? 6.667 : 0 }
    var contentHeight: CGFloat { candidateHeight + 4 * keyHeight + 3 * rowGap + bottomInset + (belowAccessories ? 50 : 0) }
    var switcherWidth: CGFloat { split ? 46.667 : arrangement == .outerLandscape ? 45.333 : arrangement == .innerPortrait ? 50.667 : arrangement == .outerPortrait ? 39.667 : 42 }
    let modeWidth: CGFloat
    var letterFont: UIFont { UIFont(name: "SFCompact-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize) }

    init(width: CGFloat, landscape: Bool = false) {
        if width >= 750 && landscape || width >= 800 {
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
            returnWidth = min(120, (width - 13.34) * 0.32)
            modeWidth = min(93, (width - 13.34) * 0.238); cornerRadius = 8.5; fontSize = 25
        }
    }

    @MainActor static let keyFill = UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        if traits.accessibilityContrast == .high || UIAccessibility.isReduceTransparencyEnabled {
            return UIColor(white: dark ? 0.27 : 1, alpha: 1)
        }
        // Let the system keyboard's blurred, tinted backdrop show through each cap.
        return UIColor(white: 1, alpha: dark ? 0.18 : 0.78)
    }
}
