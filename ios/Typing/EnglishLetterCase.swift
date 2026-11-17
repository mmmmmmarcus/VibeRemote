import Foundation

/// Capitalization affects the English spelling, never availability of Chinese candidates.
enum EnglishLetterCase: Equatable {
    case lowercase, initialCapital, uppercase

    func apply(to text: String) -> String {
        switch self {
        case .lowercase: return text
        case .initialCapital: return text.prefix(1).uppercased() + text.dropFirst()
        case .uppercase: return text.uppercased()
        }
    }
}
