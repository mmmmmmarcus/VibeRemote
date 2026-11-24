import Foundation

/// Personal-build credentials. Generated locally before signing, never synchronized or logged.
/// The resource is intentionally extractable: these builds are for private use only.
enum PrivateCredentials {
    private static let values: [String: String] = {
        #if os(macOS)
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "credentials", withExtension: "json", subdirectory: "PrivateCredentials"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }()

    static func key(_ name: String) -> String? {
        validKey(values[name])
    }

    static func validKey(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 8192,
              !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value
    }
}
