import XCTest
@testable import vvhisper

final class AgentConversationTests: XCTestCase {
    func testExactMatchMustBeUniqueAndNeverSubstring() {
        let candidates = [AgentDecisionCandidate(id: "one", label: "vvhisper"),
                          AgentDecisionCandidate(id: "two", label: "vvhisper release")]
        XCTAssertEqual(AgentConversationSelection.exact(" Vvhisper ", candidates: candidates), "one")
        XCTAssertNil(AgentConversationSelection.exact("whisper", candidates: candidates))
        XCTAssertNil(AgentConversationSelection.exact("vvhisper", candidates: candidates + [.init(id: "three", label: "vvhisper")]))
    }

    func testConversationTargetsRequireNavigationAndRejectActionControls() {
        XCTAssertTrue(AgentConversationSelection.isNavigation(role: "AXOutline", label: ""))
        XCTAssertTrue(AgentConversationSelection.isNavigation(role: "AXGroup", label: "Chats"))
        XCTAssertFalse(AgentConversationSelection.isNavigation(role: "AXGroup", label: "Message contents"))
        XCTAssertTrue(AgentConversationSelection.isCandidate(role: "AXLink", label: "Release planning", navigation: true, pressable: true))
        XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXLink", label: "Release planning", navigation: false, pressable: true))
        XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXLink", label: "Release planning", navigation: true, pressable: false))
        for label in ["Delete", "New chat", "Settings", "搜索"] {
            XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXButton", label: label, navigation: true, pressable: true))
        }
    }

    func testUnlabelledSemanticSidebarCanContainAnExactChildLabelButton() {
        // Synthetic Electron-style fixture, not a capture of any installed app.
        let navigation = AgentConversationSelection.isNavigation(
            role: "AXGroup", label: "", subrole: "AXLandmarkNavigation")
        let title = AgentConversationSelection.candidateLabel(
            title: "", description: "", childTexts: [" AIOS 小标 "])
        XCTAssertTrue(navigation)
        XCTAssertEqual(title, "AIOS 小标")
        XCTAssertTrue(AgentConversationSelection.isCandidate(role: "AXButton", label: title ?? "", navigation: navigation,
                                                            pressable: true, requestedTitle: "AIOS 小标"))
        XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXButton", label: title ?? "", navigation: navigation,
                                                             pressable: true)) // never a Jev candidate
        XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXButton", label: title ?? "", navigation: navigation,
                                                             pressable: true, requestedTitle: "AIOS"))
    }

    func testNavigationRequiresContainerSemanticsAndTokenBoundaries() {
        XCTAssertTrue(AgentConversationSelection.isNavigation(role: "AXGroup", label: "", subrole: "AXLandmarkComplementary"))
        XCTAssertTrue(AgentConversationSelection.isNavigation(role: "AXGroup", label: "", identifier: "app.sidebar.threads"))
        XCTAssertTrue(AgentConversationSelection.isNavigation(role: "AXList", label: "", identifier: "recent-conversation-list"))
        XCTAssertTrue(AgentConversationSelection.isNavigation(role: "AXGroup", label: "", roleDescription: "navigation"))
        XCTAssertFalse(AgentConversationSelection.isNavigation(role: "AXGroup", label: "", identifier: "notasidebar"))
        XCTAssertFalse(AgentConversationSelection.isNavigation(role: "AXGroup", label: "", identifier: "chat-message-list"))
        XCTAssertFalse(AgentConversationSelection.isNavigation(role: "AXButton", label: "Chats", identifier: "sidebar"))
        XCTAssertFalse(AgentConversationSelection.isNavigation(role: "AXStaticText", label: "Chats"))
    }

    func testMainContentAndEditorsCannotEstablishNavigation() {
        XCTAssertTrue(AgentConversationSelection.isContent(role: "AXGroup", subrole: "AXLandmarkMain"))
        XCTAssertTrue(AgentConversationSelection.isContent(role: "AXTextArea"))
        XCTAssertTrue(AgentConversationSelection.isContent(role: "AXTextField", subrole: "AXSearchField"))
        XCTAssertFalse(AgentConversationSelection.isNavigation(role: "AXGroup", label: "Chats", subrole: "AXLandmarkMain"))
        XCTAssertFalse(AgentConversationSelection.isNavigation(role: "AXTextArea", label: "Sidebar", identifier: "sidebar"))
        XCTAssertFalse(AgentConversationSelection.isContent(role: "AXGroup", subrole: "AXLandmarkNavigation"))
        XCTAssertFalse(AgentConversationSelection.isContent(role: "AXWebArea")) // may contain both sidebar and content
        XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXButton", label: "AIOS 小标", navigation: false,
                                                             pressable: true, requestedTitle: "AIOS 小标"))
    }

    func testCandidateLabelsDoNotConcatenateMetadataOrActionTitles() {
        XCTAssertEqual(AgentConversationSelection.candidateLabel(title: "AIOS 小标", description: "Conversation", childTexts: ["Yesterday"]), "AIOS 小标")
        XCTAssertEqual(AgentConversationSelection.candidateLabel(title: "", description: "AIOS 小标", childTexts: []), "AIOS 小标")
        XCTAssertEqual(AgentConversationSelection.candidateLabel(title: "", description: "", childTexts: ["", "AIOS 小标", " AIOS 小标 "]), "AIOS 小标")
        XCTAssertNil(AgentConversationSelection.candidateLabel(title: "", description: "", childTexts: ["AIOS 小标", "Yesterday"]))
        XCTAssertNil(AgentConversationSelection.candidateLabel(title: "", description: "", childTexts: []))
        XCTAssertNil(AgentConversationSelection.candidateLabel(title: "AIOS 小标\nYesterday", description: ""))
    }

    func testExactChineseSessionIsUniqueAndNeverAMatchingAction() {
        let target = "AIOS 小标"
        let candidates = [AgentDecisionCandidate(id: "a", label: target), .init(id: "b", label: "AIOS 小标旧版")]
        XCTAssertEqual(AgentConversationSelection.exact(target, candidates: candidates), "a")
        XCTAssertNil(AgentConversationSelection.exact(target, candidates: candidates + [.init(id: "c", label: " AIOS 小标 ")]))
        for action in ["Delete", "Delete AIOS 小标", "Archive: AIOS 小标", "Share “AIOS 小标”", "Rename AIOS 小标", "删除AIOS 小标", "归档 AIOS 小标", "新聊天", "More options"] {
            for role in ["AXRow", "AXLink", "AXButton", "AXGroup"] {
                XCTAssertFalse(AgentConversationSelection.isCandidate(role: role, label: action, navigation: true,
                                                                     pressable: true, requestedTitle: action), "\(role): \(action)")
            }
        }
        XCTAssertTrue(AgentConversationSelection.isCandidate(role: "AXGroup", label: target, navigation: true,
                                                            pressable: true, requestedTitle: target))
        XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXGroup", label: target, navigation: true,
                                                             pressable: true))
        XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXButton", label: "AIOS 小标旧版", navigation: true,
                                                             pressable: true, requestedTitle: target))
    }

    func testCurrentConversationRequiresSelectionOrPageCurrentEvidence() {
        XCTAssertTrue(AgentConversationSelection.isCurrent(selected: true, ariaCurrent: nil))
        XCTAssertTrue(AgentConversationSelection.isCurrent(selected: nil, ariaCurrent: "page"))
        XCTAssertTrue(AgentConversationSelection.isCurrent(selected: false, ariaCurrent: "true"))
        XCTAssertTrue(AgentConversationSelection.isCurrent(selected: nil, ariaCurrent: " PAGE "))
        for value in [nil, "", "false", "location", "date", "time", "step", "focused"] as [String?] {
            XCTAssertFalse(AgentConversationSelection.isCurrent(selected: nil, ariaCurrent: value))
            XCTAssertFalse(AgentConversationSelection.isCurrent(selected: false, ariaCurrent: value))
        }
    }

    func testExactTitleNormalizesUnicodeWhitespaceWithoutRemovingWordBoundaries() {
        for title in [" AIOS  小标 ", "AIOS\u{00A0}小标", "AIOS\u{2009}\u{202F}小标", "AIOS\u{3000}小标", "AIOS\t 小标"] {
            XCTAssertEqual(AgentConversationSelection.normalize(title), "aios 小标")
            XCTAssertEqual(AgentConversationSelection.exact("AIOS 小标", candidates: [.init(id: "target", label: title)]), "target")
        }
        for different in ["AIOS小标", "AIOS 小 标", "AIOS / 小标", "AIOS-小标", "AIOS 小标旧版"] {
            XCTAssertNotEqual(AgentConversationSelection.normalize(different), "aios 小标")
            XCTAssertNil(AgentConversationSelection.exact("AIOS 小标", candidates: [.init(id: "different", label: different)]))
        }
    }

    func testWhitespaceEquivalentTitlesRemainAmbiguous() {
        let candidates = [AgentDecisionCandidate(id: "one", label: "AIOS 小标"),
                          AgentDecisionCandidate(id: "two", label: "AIOS\u{00A0}\u{2009}小标")]
        XCTAssertNil(AgentConversationSelection.exact("AIOS 小标", candidates: candidates))
        XCTAssertNil(AgentConversationSelection.exact("AIOS\u{3000}小标", candidates: candidates))
        XCTAssertTrue(AgentConversationSelection.isCandidate(role: "AXButton", label: "AIOS\u{00A0}小标", navigation: true,
                                                            pressable: true, requestedTitle: "AIOS 小标"))
        XCTAssertFalse(AgentConversationSelection.isCandidate(role: "AXButton", label: "AIOS小标", navigation: true,
                                                             pressable: true, requestedTitle: "AIOS 小标"))
    }

    func testLegacyBackendMigratesToOpenRouterWithoutLosingModels() {
        let name = "AgentMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("codex", forKey: AgentSettings.backendKey)
        defaults.set("personal-codex-choice", forKey: AgentSettings.codexModelKey)
        defaults.set("provider/custom-model", forKey: AgentSettings.modelKey)
        let settings = AgentSettings.load(from: defaults)
        XCTAssertEqual(settings.backend, .openRouter)
        XCTAssertEqual(settings.openRouterModel, "provider/custom-model")
        XCTAssertEqual(settings.codexModel, "personal-codex-choice")
        XCTAssertEqual(settings.decisionModel, AgentSettings.defaultDecisionModel)
        settings.save(to: defaults)
        XCTAssertEqual(defaults.string(forKey: AgentSettings.backendKey), "openRouter")
        defaults.set("  ", forKey: AgentSettings.decisionModelKey)
        XCTAssertEqual(AgentSettings.load(from: defaults).decisionModel, AgentSettings.defaultDecisionModel)
    }
}
