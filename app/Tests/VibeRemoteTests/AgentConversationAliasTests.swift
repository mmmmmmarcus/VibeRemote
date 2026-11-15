import XCTest
@testable import VibeRemote

final class AgentConversationAliasTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "ConversationAliases.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testConfirmedAliasIsScopedToOneAppAndNeverAContainsMatch() {
        withDefaults { defaults in
            defaults.set(["example.chat": ["launch notes": "Planning the autumn launch"]],
                         forKey: AgentConversationAliases.defaultsKey)
            XCTAssertEqual(AgentConversationAliases.resolve("LAUNCH\u{00a0}notes", bundleID: "example.chat", defaults: defaults),
                           .title("Planning the autumn launch"))
            XCTAssertEqual(AgentConversationAliases.resolve("launch notes", bundleID: "other.chat", defaults: defaults), .unchanged)
            XCTAssertEqual(AgentConversationAliases.resolve("launch", bundleID: "example.chat", defaults: defaults), .unchanged)
        }
    }

    func testAliasesExpandOnceAndKeepTheTargetLiteral() {
        withDefaults { defaults in
            defaults.set(["example.chat": ["short": "long", "long": "another title"]],
                         forKey: AgentConversationAliases.defaultsKey)
            XCTAssertEqual(AgentConversationAliases.resolve("short", bundleID: "example.chat", defaults: defaults), .title("long"))
        }
    }

    func testSectionScopeAppliesToShorthandAndFullTitleWithoutRecursion() {
        withDefaults { defaults in
            let target = ["title": "Planning the autumn launch", "section": "Recent"]
            defaults.set(["example.chat": ["launch notes": target, "Planning the autumn launch": target]],
                         forKey: AgentConversationAliases.defaultsKey)
            for name in ["launch notes", "Planning the autumn launch"] {
                XCTAssertEqual(AgentConversationAliases.resolve(name, bundleID: "example.chat", defaults: defaults),
                               .scopedTitle("Planning the autumn launch", section: "Recent"))
            }
            defaults.set(["example.chat": ["launch notes": ["title": "Planning", "section": "Recent\nPinned"]]],
                         forKey: AgentConversationAliases.defaultsKey)
            XCTAssertEqual(AgentConversationAliases.resolve("launch notes", bundleID: "example.chat", defaults: defaults), .unchanged)
        }
    }

    func testMalformedTargetDoesNotHideAnAliasCollision() {
        withDefaults { defaults in
            defaults.set(["example.chat": ["notes": "Valid title", " NOTES ": 42]],
                         forKey: AgentConversationAliases.defaultsKey)
            XCTAssertEqual(AgentConversationAliases.resolve("notes", bundleID: "example.chat", defaults: defaults), .ambiguous)
        }
    }

    func testEquivalentAliasKeysCannotChooseAnArbitraryDestination() {
        withDefaults { defaults in
            defaults.set(["example.chat": ["launch notes": "First title", "LAUNCH\u{2009}notes": "Second title"]],
                         forKey: AgentConversationAliases.defaultsKey)
            XCTAssertEqual(AgentConversationAliases.resolve("launch notes", bundleID: "example.chat", defaults: defaults), .ambiguous)
        }
    }

    func testMalformedAndOversizedAliasesDoNotBecomeTargets() {
        withDefaults { defaults in
            let invalidValues: [Any] = ["unexpected", ["example.chat": ["short": ""]],
                               ["example.chat": ["short": "a\nb"]],
                               ["example.chat": ["short": String(repeating: "x", count: 201)]],
                               ["example.chat": ["short": 42]]]
            for value in invalidValues {
                defaults.set(value, forKey: AgentConversationAliases.defaultsKey)
                XCTAssertEqual(AgentConversationAliases.resolve("short", bundleID: "example.chat", defaults: defaults), .unchanged)
            }
        }
    }
}
