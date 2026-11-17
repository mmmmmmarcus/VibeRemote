import Foundation

/// Section membership uses only visible semantic headings supplied by the observer.
/// Frames use Accessibility coordinates, where larger y values are farther down.
enum AgentConversationSections {
    struct Marker: Equatable, Sendable {
        let label: String
        let frame: CGRect
        let scope: Int
    }

    /// Chromium exposes AXExpanded for popup buttons too. Their menus do not
    /// establish conversation sections, even when the button has a section-like label.
    static func isMarker(role: String, expanded: Bool?, hasPopup: Bool?, popupValue: String?) -> Bool {
        if role == "AXHeading" || role == "AXDisclosureTriangle" { return true }
        guard role == "AXButton", expanded != nil, hasPopup != true else { return false }
        let popup = AgentConversationSelection.normalize(popupValue ?? "")
        return !["true", "menu", "listbox", "tree", "grid", "dialog"].contains(popup)
    }

    /// `explicitSection` means the observer proved that a containing semantic region
    /// has the requested section label. It is stronger evidence than heading geometry.
    static func belongs(to requestedSection: String, candidateFrame: CGRect, scope: Int,
                        explicitSection: Bool, markers: [Marker]) -> Bool {
        let requested = AgentConversationSelection.normalize(requestedSection)
        guard !requested.isEmpty, requestedSection.count <= 200,
              !requestedSection.contains(where: { $0.isNewline }), valid(candidateFrame) else { return false }
        if explicitSection { return true }

        let scoped = markers.filter { $0.scope == scope }
        // A heading with unknown geometry could be a section boundary. Do not skip it
        // and silently attribute the candidate to an earlier heading.
        guard scoped.allSatisfy({ valid($0.frame) }) else { return false }
        let preceding = scoped.filter { marker in
            marker.frame.maxY <= candidateFrame.minY + 1
        }
        guard let nearest = preceding.enumerated().max(by: { $0.element.frame.maxY < $1.element.frame.maxY }) else {
            return false
        }
        for (index, marker) in preceding.enumerated() where index != nearest.offset {
            let overlaps = marker.frame.minY < nearest.element.frame.maxY
                && marker.frame.maxY > nearest.element.frame.minY
            if overlaps || abs(marker.frame.maxY - nearest.element.frame.maxY) <= 1 { return false }
        }
        // Indented entries must not skip a short intervening heading and inherit an
        // earlier section. All same-scope headings are boundaries, even off to the side.
        guard min(nearest.element.frame.maxX, candidateFrame.maxX)
                > max(nearest.element.frame.minX, candidateFrame.minX) else { return false }
        return AgentConversationSelection.normalize(nearest.element.label) == requested
    }

    private static func valid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
            && frame.maxX.isFinite && frame.maxY.isFinite
    }
}
