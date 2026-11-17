import ApplicationServices
import Foundation

/// AX batch reads can succeed overall while individual values contain AX errors.
/// An unreadable subtree is not evidence that the subtree has no conversations.
enum AgentConversationAttributes {
    static func failure(in values: [Any], expectedCount: Int, requiredIndices: Set<Int>) -> AXError? {
        guard values.count == expectedCount,
              requiredIndices.allSatisfy({ values.indices.contains($0) }) else { return .cannotComplete }
        for (index, value) in values.enumerated() {
            let required = requiredIndices.contains(index)
            if value is NSNull {
                if required { return .noValue }
                continue
            }
            if let string = value as? String {
                if required && string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noValue }
                continue
            }
            let object = value as CFTypeRef
            guard CFGetTypeID(object) == AXValueGetTypeID() else { continue }
            let axValue = unsafeBitCast(object, to: AXValue.self)
            guard AXValueGetType(axValue) == .axError else { continue }
            var error = AXError.success
            guard AXValueGetValue(axValue, .axError, &error), error != .success else { return .cannotComplete }
            if !required && (error == .noValue || error == .attributeUnsupported) { continue }
            return error
        }
        return nil
    }
}
