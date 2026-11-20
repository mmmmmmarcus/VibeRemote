import Foundation

enum KeyboardSymbols {
    // Native Chinese punctuation changes selected marks, not every ASCII symbol.
    static let chinese: [String: String] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
        "(": "（", ")": "）", "[": "【", "]": "】", "{": "｛", "}": "｝",
        "<": "《", ">": "》", "\"": "「", "'": "」", "~": "～", "|": "｜"
    ]
    /// Captured from Apple's English (US) and Simplified Pinyin palettes on Duo.
    /// Corner quotes are our requested exception to the native paired curly quotes.
    static func rows(page: Int, language: KeyboardLanguage) -> [[String]] {
        if language == .chinese {
            if page == 1 {
                return [Array("1234567890").map(String.init),
                        ["-", "/", "：", "；", "（", "）", "$", "@", "「", "」"],
                        ["#+=", "。", "，", "、", "？", "！", ".", "delete"]]
            }
            return [["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="],
                    ["_", "—", "\\", "｜", "～", "《", "》", "€", "&", "·"],
                    ["123", "…", "「", "kaomoji", "」", "", "'", "delete"]]
        }
        if page == 1 {
            return [Array("1234567890").map(String.init),
                    ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
                    ["#+=", ".", ",", "?", "!", "'", "delete"]]
        }
        return [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                ["123", ".", ",", "?", "!", "'", "delete"]]
    }
    static func key(_ value: String, language: KeyboardLanguage) -> String {
        guard language == .chinese else { return value }
        return chinese[value] ?? value
    }

    /// Keep the printed symbol first, so holding and releasing without sliding is literal.
    static func alternatives(for value: String) -> [String] {
        if value != "「", value != "」", let original = chinese.first(where: { $0.value == value })?.key {
            var seen: Set<String> = [value]
            return [value] + alternatives(for: original).filter { seen.insert($0).inserted }
        }
        let variants: [String: [String]] = [
            "1": ["¹", "₁", "½", "⅓", "¼"], "2": ["²", "₂", "⅔"], "3": ["³", "₃", "¾"],
            "4": ["⁴", "₄"], "5": ["⁵", "₅"], "6": ["⁶", "₆"], "7": ["⁷", "₇"],
            "8": ["⁸", "₈"], "9": ["⁹", "₉"], "0": ["⁰", "₀", "°"],
            "—": ["–", "-", "−"], "…": ["……", "..."], "·": ["•", "・"],
            "-": ["–", "—", "−", "•"], "/": ["\\", "÷", "／"], ":": ["：", ";"], ";": ["；", ":"],
            "(": ["（", "[", "{", "〈"], ")": ["）", "]", "}", "〉"],
            "$": ["¢", "€", "£", "¥", "₩", "₹"], "€": ["$", "£", "¥", "₩", "₹"],
            "£": ["$", "€", "¥", "₩", "₹"], "¥": ["￥", "$", "€", "£", "₩"],
            "&": ["＆", "§"], "@": ["＠", "©", "®", "™"],
            "\"": ["“", "”", "„", "«", "»", "「"], "'": ["‘", "’", "‚", "′", "`", "」"],
            "「": ["『", "“", "\"", "«", "〈"], "」": ["』", "”", "'", "»", "〉"],
            ".": ["…", "。", "·", "．"], ",": ["，", "、", "‚"], "?": ["？", "¿"], "!": ["！", "¡"],
            "[": ["【", "〔", "［"], "]": ["】", "〕", "］"], "{": ["｛", "[", "("], "}": ["｝", "]", ")"],
            "#": ["＃", "№"], "%": ["％", "‰", "‱"], "^": ["＾", "↑", "ˆ"], "*": ["＊", "×", "※", "★"],
            "+": ["＋", "±", "×"], "=": ["＝", "≠", "≈", "≡"], "_": ["＿", "—"],
            "\\": ["/", "＼"], "|": ["｜", "¦", "‖"], "~": ["～", "≈"],
            "<": ["≤", "〈", "《", "＜"], ">": ["≥", "〉", "》", "＞"], "•": ["·", "●", "○", "▪", "★"]
        ]
        guard let choices = variants[value] else { return [] }
        return [value] + choices
    }
}
