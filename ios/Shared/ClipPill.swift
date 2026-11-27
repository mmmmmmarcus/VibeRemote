import Foundation

/// One tappable clipboard pill on the symbol-page strip (designer spec
/// 2026-11-27, `.airbuild/specs/clip-pills.md`). Pure model: no clipboard
/// access, no persistence, never logs `text`.
struct ClipPill: Equatable {
    enum Kind: String, CaseIterable {
        case link, email, phone, number, text
        /// SF Symbol shown at 14pt semibold, secondaryLabel.
        var symbol: String {
            switch self {
            case .link: "link"
            case .email: "envelope"
            case .phone: "phone"
            case .number: "number"
            case .text: "text.alignleft"
            }
        }
    }
    let kind: Kind
    /// Exactly what a tap inserts: the full original clip, or the extracted code.
    let text: String
    /// Single-line pill title (collapsed whitespace, at most 20 Characters).
    let title: String
    /// The copied-code pill pastes through the re-validated codeOnly path.
    let isCode: Bool

    static let maximumTitleLength = 20
    static let maximumSpokenLength = 70
    static let maximumClips = 5

    init(clip: String) {
        kind = Self.classify(clip); text = clip; title = Self.title(clip); isCode = false
    }
    /// `code` is nil when the digits are unknown (concealed copy or an extension
    /// relaunch, where only expiry metadata survives); the pill then reads "Code".
    init(code: String?) {
        kind = .number; text = code ?? ""; title = code.map(Self.title) ?? "Code"; isCode = true
    }

    var accessibilityLabel: String {
        if isCode && text.isEmpty { return "Paste code" }
        return "Paste \(kind.rawValue): \(String(Self.collapsed(text).prefix(Self.maximumSpokenLength)))"
    }

    /// Newlines and runs of whitespace become one space (leading/trailing dropped).
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
    /// More than 20 Characters (CJK and Latin alike): first 19 + "…".
    static func title(_ text: String) -> String {
        let line = collapsed(text)
        guard line.count > maximumTitleLength else { return line }
        return String(line.prefix(maximumTitleLength - 1)) + "…"
    }

    /// Checked in order, first match wins: link, email, phone, number, text.
    static func classify(_ text: String) -> Kind {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf16.count <= 4096 else { return .text }
        if matches(value, #"^[A-Za-z][A-Za-z0-9+.-]*://\S+$"#) && !value.lowercased().hasPrefix("mailto:")
            || matches(value, #"^(?i)www\.\S+$"#)
            || !value.contains("@") && matches(value, #"^(?i)([a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(:[0-9]{1,5})?([/?#]\S*)?$"#) {
            return .link
        }
        if matches(value, #"^(?i)(mailto:)?[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$"#) { return .email }
        if isPhone(value) { return .phone }
        if matches(value, #"^[0-9]+([ -][0-9]+)*$"#) { return .number }
        if let code = VerificationCode.extract(from: value), code.allSatisfy(\.isNumber) { return .number }
        return .text
    }

    /// "tel:" links, "+"-prefixed or separated numbers (7–15 digits), and
    /// bare 11-digit mainland mobile numbers. Plain digit runs stay `number`.
    private static func isPhone(_ value: String) -> Bool {
        var body = value
        if body.lowercased().hasPrefix("tel:") { body.removeFirst(4) }
        guard matches(body, #"^\+?[0-9()][0-9 ().-]*[0-9]$"#) else { return false }
        let digits = body.filter(\.isNumber).count
        guard (7...15).contains(digits) else { return false }
        if body != value || body.hasPrefix("+") || body.contains("(") { return true }
        if matches(body, #"^[0-9]{4}[-./][0-9]{1,2}[-./][0-9]{1,2}$"#) { return false } // a date
        let groups = body.split(whereSeparator: { " .-".contains($0) })
        if groups.count >= 2 { return !(groups.count == 2 && body.contains(".")) } // not a decimal
        return digits == 11 && body.hasPrefix("1")
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// Strip order after the two shortcuts: the copied code first (if fresh),
    /// then up to five history clips newest first. The clip the code came from
    /// is not repeated as a separate pill.
    static func pills(history: [String], code: String?, codeAvailable: Bool, codeSource: String?) -> [ClipPill] {
        var result: [ClipPill] = []
        if codeAvailable { result.append(ClipPill(code: code)) }
        let clips = history.filter { !(codeAvailable && $0 == codeSource) && !collapsed($0).isEmpty }
        result += clips.prefix(maximumClips).map(ClipPill.init(clip:))
        return result
    }
}

/// Pasteboard markers that mean "do not show or record" (nspasteboard.org
/// conventions, also set by password managers such as 1Password).
enum ConcealedPasteboard {
    static let types: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]
    static func isConcealed(_ types: [String]) -> Bool { types.contains { Self.types.contains($0) } }
}
