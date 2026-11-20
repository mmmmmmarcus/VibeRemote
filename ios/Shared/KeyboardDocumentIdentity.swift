import UIKit

/// UIKit's remote proxy sometimes returns nil during an input-mode transition,
/// despite the public getter being annotated nonnull. Avoid Swift's forced UUID
/// bridge. This invokes only the public documentIdentifier getter.
@MainActor enum KeyboardDocumentIdentity {
    static func read(_ object: AnyObject) -> UUID? {
        guard let object = object as? NSObject else { return nil }
        let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter)?.takeUnretainedValue() as? UUID
    }
    /// Unavailable documents must never compare equal to a prior snapshot or
    /// another unavailable document. Never reuse the last valid identity.
    static func snapshot(_ proxy: UITextDocumentProxy) -> UUID { read(proxy) ?? UUID() }
}
