import Foundation

/// Parses copied/pasted text only. It never reads messages or accesses the clipboard itself.
enum VerificationCode {
    static func extract(from text: String) -> String? {
        guard text.utf16.count <= 4096 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A copied code alone may be numeric or alphanumeric, with visual separators.
        let compact = trimmed.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        if (4...8).contains(compact.count), compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
           compact.contains(where: { $0.isNumber }) { return compact }
        // Require a code-related message, and never guess among several possible codes.
        let lower = trimmed.lowercased()
        guard ["code", "otp", "pin", "验证码", "驗證碼", "校验码", "动态码", "安全码", "登录", "登入"].contains(where: { lower.contains($0) }),
              let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([0-9]{3}[- ][0-9]{3}|[A-Za-z0-9]{4,8})(?![A-Za-z0-9])"#) else { return nil }
        let matches = expression.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        let codes = Set(matches.compactMap { Range($0.range(at: 1), in: trimmed).map { String(trimmed[$0]).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") } }.filter { $0.contains(where: { $0.isNumber }) })
        return codes.count == 1 ? codes.first : nil
    }
}
