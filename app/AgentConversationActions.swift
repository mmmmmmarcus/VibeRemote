import AppKit
import ApplicationServices

/// References are local to one bounded observation; never persisted or reused by a later run.
private final class ConversationSnapshot: @unchecked Sendable {
    struct Entry {
        let element: AXUIElement
        let label: String
        let role: String
        let clip: CGRect?
        let frame: CGRect
        let scope: Int
        let explicitSection: Bool
    }
    let pid: pid_t
    let entries: [Entry]
    let window: AXUIElement?
    let complete: Bool
    let reason: String
    let section: String?
    init(pid: pid_t, entries: [Entry] = [], window: AXUIElement? = nil,
         complete: Bool = true, reason: String = "ready", section: String? = nil) {
        self.pid = pid; self.entries = entries; self.window = window
        self.complete = complete; self.reason = reason
        self.section = section
    }
    var candidates: [AgentDecisionCandidate] {
        entries.enumerated().map { AgentDecisionCandidate(id: "conversation_\($0.offset)", label: $0.element.label) }
    }
}

@MainActor
enum AgentConversationActions {
    static let supportedApps: Set<String> = ["com.openai.codex", "com.openai.chat", "com.anthropic.claudefordesktop"]

    /// App activation precedes this call. A short readiness retry handles delayed AX windows
    /// and sidebars; it never repeats a selection or waits on the main actor.
    static func execute(title: String, model: String,
                        apiKey: @escaping @MainActor () -> String?,
                        onPhase: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> AgentLocalActions.Outcome {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier, supportedApps.contains(bundleID) else {
            return .unhandled("The requested app was activated. No supported conversation navigation adapter was available; inspect its current UI.")
        }
        guard AXIsProcessTrusted() else {
            onPhase("accessibility_required")
            return .failed("Allow vvhisper in System Settings › Privacy & Security › Accessibility, then try again.")
        }
        let resolvedTitle: String
        let confirmedAlias: Bool
        let requestedSection: String?
        switch AgentConversationAliases.resolve(title, bundleID: bundleID) {
        case .unchanged:
            resolvedTitle = title
            confirmedAlias = false
            requestedSection = nil
        case .title(let destination):
            resolvedTitle = destination
            confirmedAlias = true
            requestedSection = nil
            onPhase("alias_resolved")
        case .scopedTitle(let destination, let section):
            resolvedTitle = destination
            requestedSection = section
            confirmedAlias = true
            onPhase("alias_resolved")
        case .ambiguous:
            onPhase("alias_ambiguous")
            return .failed("More than one saved conversation shortcut uses that name. Use the full conversation title.")
        }
        let pid = app.processIdentifier
        let deadline = ProcessInfo.processInfo.systemUptime + 0.9
        var snapshot: ConversationSnapshot?
        repeat {
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return .failed("Stopped because the focused app changed.")
            }
            let first = snapshot == nil
            let observed = Task.detached(priority: .userInitiated) {
                observe(pid: pid, requestedTitle: resolvedTitle, section: requestedSection, requestAccessibility: first, limit: deadline)
            }
            let next = await withTaskCancellationHandler { await observed.value } onCancel: { observed.cancel() }
            if let expected = snapshot?.window, let actual = next.window, !CFEqual(expected, actual) {
                return .failed("Stopped because the focused window changed.")
            }
            snapshot = next
            if next.complete && !next.entries.isEmpty { break }
            guard ProcessInfo.processInfo.systemUptime + 0.06 < deadline else { break }
            do { try await Task.sleep(nanoseconds: 60_000_000) }
            catch { return .failed("Stopped.") }
        } while !Task.isCancelled
        guard let snapshot else { return .failed("Stopped.") }
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return .failed("Stopped because the focused app changed.")
        }
        guard snapshot.complete, !snapshot.entries.isEmpty else {
            onPhase("fallback_" + snapshot.reason)
            return await fallback("The requested app was activated, but its visible conversation navigation was not fully available. Inspect the sidebar to find the requested conversation.", snapshot: snapshot)
        }
        onPhase("navigation_ready")
        let candidates = snapshot.candidates
        var id = AgentConversationSelection.exact(resolvedTitle, candidates: candidates)
        if id != nil { onPhase("exact_match") }
        // Duplicate exact labels require clarification. Never let a model break that tie.
        if id == nil, candidates.filter({ AgentConversationSelection.normalize($0.label) == AgentConversationSelection.normalize(resolvedTitle) }).count > 1 {
            onPhase("fallback_ambiguous_title")
            return await fallback("More than one visible conversation has the requested title. Clarify which one to open.", snapshot: snapshot)
        }
        // A saved, user-confirmed alias names one literal target; never reinterpret a
        // missing/renamed target as permission to select a similar conversation.
        if id == nil, !confirmedAlias, let key = apiKey(), !key.isEmpty {
            // Buttons/groups are exact-only. They are never offered as semantic guesses.
            let decisionCandidates = candidates.enumerated().compactMap { index, candidate in
                ["AXRow", "AXLink"].contains(snapshot.entries[index].role) ? candidate : nil
            }
            if !decisionCandidates.isEmpty {
                do {
                    onPhase("decision_requested")
                    id = try await AgentDecisionClient().select(command: "Choose the existing conversation matching this requested title or topic: \(resolvedTitle)",
                                                               candidates: decisionCandidates, model: model, apiKey: key)
                    onPhase("decision_ready")
                } catch is CancellationError { return .failed("Stopped.") }
                catch {
                    onPhase("fallback_decision_unavailable")
                    return await fallback("The app is open. The quick conversation selector was unavailable; inspect its conversation navigation to resolve the request.", snapshot: snapshot)
                }
            }
        }
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return .failed("Stopped because the focused app changed.")
        }
        guard let id, let index = candidates.firstIndex(where: { $0.id == id }),
              candidates.filter({ AgentConversationSelection.normalize($0.label) == AgentConversationSelection.normalize(candidates[index].label) }).count == 1 else {
            onPhase("fallback_unresolved_title")
            return await fallback("The app is open, but the conversation name was not resolved confidently. Inspect the navigation and clarify if multiple conversations match.", snapshot: snapshot)
        }
        let action = Task.detached(priority: .userInitiated) {
            await pressAndVerify(snapshot, index: index, onPhase: onPhase)
        }
        return await withTaskCancellationHandler { await action.value } onCancel: { action.cancel() }
    }

    private static func fallback(_ evidence: String, snapshot: ConversationSnapshot) async -> AgentLocalActions.Outcome {
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else {
            return .failed("Stopped because the focused app changed.")
        }
        let matches = await Task.detached(priority: .userInitiated) {
            guard let expected = snapshot.window else { return true }
            return windowMatches(pid: snapshot.pid, expected: expected)
        }.value
        guard !Task.isCancelled, matches, NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else {
            return .failed("Stopped because the focused window changed.")
        }
        return .unhandled(evidence)
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String, deadline: TimeInterval = .infinity) -> CFTypeRef? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, !Task.isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(0.02, remaining)))
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private nonisolated static func text(_ element: AXUIElement, _ name: String, deadline: TimeInterval = .infinity) -> String {
        attribute(element, name, deadline: deadline) as? String ?? ""
    }
    private struct Node {
        let role: String, subrole: String, title: String, description: String
        let identifier: String, roleDescription: String
        let children: [AXUIElement]
        let readFailed: Bool
        let readError: Int32
        let hidden: Bool
        let expanded: Bool?
        let hasPopup: Bool?
        let popupValue: String?
        var label: String { AgentConversationSelection.candidateLabel(title: title, description: description) ?? "" }
        var navigation: Bool {
            AgentConversationSelection.isNavigation(role: role, label: label, subrole: subrole,
                                                     identifier: identifier, roleDescription: roleDescription)
        }
    }
    /// One IPC call per node instead of one call per attribute. Unsupported values are
    /// AX error values and are ignored by the typed casts below. Composer values are not read.
    private nonisolated static func node(_ element: AXUIElement, deadline: TimeInterval = .infinity) -> Node {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXIdentifierAttribute, kAXRoleDescriptionAttribute, kAXChildrenAttribute, "AXHidden", kAXExpandedAttribute,
                     "AXHasPopup", "AXPopupValue"]
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        AXUIElementSetMessagingTimeout(element, Float(max(0.001, min(0.02, remaining))))
        var raw: CFArray?
        let status = remaining > 0 && !Task.isCancelled
            ? AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw) : .cannotComplete
        var values = raw as? [Any] ?? []
        var effectiveStatus = status
        // Only an explicit unsupported batch API permits bounded individual reads.
        // Timeouts are never expanded into seven more calls, and failed subtree reads
        // remain incomplete rather than silently hiding a duplicate conversation.
        if status == .notImplemented || status == .attributeUnsupported {
            values = []
            effectiveStatus = .success
            for name in names {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0, !Task.isCancelled else { effectiveStatus = .cannotComplete; break }
                AXUIElementSetMessagingTimeout(element, Float(min(0.02, remaining)))
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                if result == .success { values.append(value ?? NSNull()) }
                else if result == .attributeUnsupported || result == .noValue { values.append(NSNull()) }
                else { effectiveStatus = result; break }
            }
        }
        if effectiveStatus == .success,
           let failure = AgentConversationAttributes.failure(in: values, expectedCount: names.count, requiredIndices: [0]) {
            effectiveStatus = failure
        }
        func value(_ index: Int) -> Any? { values.indices.contains(index) ? values[index] : nil }
        let role = value(0) as? String ?? ""
        let failed = effectiveStatus != .success || role.isEmpty
        return Node(role: role, subrole: value(1) as? String ?? "",
                    title: value(2) as? String ?? "", description: value(3) as? String ?? "",
                    identifier: value(4) as? String ?? "", roleDescription: value(5) as? String ?? "",
                    children: value(6) as? [AXUIElement] ?? [], readFailed: failed,
                    readError: failed ? effectiveStatus.rawValue : 0,
                    hidden: value(7) as? Bool == true, expanded: value(8) as? Bool,
                    hasPopup: value(9) as? Bool, popupValue: value(10) as? String)
    }

    private nonisolated static func frame(_ element: AXUIElement, deadline: TimeInterval = .infinity) -> CGRect? {
        guard let rawSize = attribute(element, kAXSizeAttribute, deadline: deadline), CFGetTypeID(rawSize) == AXValueGetTypeID(),
              let rawPosition = attribute(element, kAXPositionAttribute, deadline: deadline), CFGetTypeID(rawPosition) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero, point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size),
              AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &point),
              size.width.isFinite, size.height.isFinite, point.x.isFinite, point.y.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
    private nonisolated static func visible(_ element: AXUIElement, clip: CGRect?, deadline: TimeInterval = .infinity) -> Bool {
        guard attribute(element, "AXHidden", deadline: deadline) as? Bool != true,
              attribute(element, kAXEnabledAttribute, deadline: deadline) as? Bool != false, let rect = frame(element, deadline: deadline) else { return false }
        guard let clip else { return true }
        return !rect.intersection(clip).isEmpty
    }
    private nonisolated static func pressable(_ element: AXUIElement, deadline: TimeInterval = .infinity) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, !Task.isCancelled else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(0.02, remaining)))
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success
            && ((actions as? [String]) ?? []).contains(kAXPressAction)
    }
    private struct AXIdentity: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    private struct LabelRead {
        let value: String?
        let complete: Bool
    }
    private nonisolated static func candidateLabel(_ element: AXUIElement, node: Node, deadline: TimeInterval = .infinity) -> LabelRead {
        if let label = AgentConversationSelection.candidateLabel(title: node.title, description: node.description) { return LabelRead(value: label, complete: true) }
        // Native layouts often wrap the one visible text several times. Walk transparent
        // wrappers, but never borrow the labels of nested action controls or truncate texts.
        var texts: [String] = []
        let root = AXIdentity(element: element)
        let walk = AgentConversationTraversal.walk(root: root, context: (), maximumNodes: 64, maximumDepth: 8,
                                                   shouldContinue: { ProcessInfo.processInfo.systemUptime < deadline && !Task.isCancelled }) { item, _, depth in
            let info = item == root ? node : self.node(item.element, deadline: deadline)
            if info.readFailed { return .unavailable }
            if info.hidden { return .leaf }
            if info.role == "AXStaticText" {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return .unavailable }
                AXUIElementSetMessagingTimeout(item.element, Float(min(0.02, remaining)))
                var raw: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(item.element, kAXValueAttribute as CFString, &raw)
                guard status == .success || status == .noValue || status == .attributeUnsupported else { return .unavailable }
                if let value = raw as? String, !value.isEmpty { texts.append(value) }
                else if !info.label.isEmpty { texts.append(info.label) }
                return .leaf
            }
            if depth == 0 || (["AXGroup", "AXUnknown"].contains(info.role) && !pressable(item.element, deadline: deadline)) {
                return .children(info.children.map { AXIdentity(element: $0) }, ())
            }
            return .leaf
        }
        guard walk.complete, ProcessInfo.processInfo.systemUptime < deadline else { return LabelRead(value: nil, complete: false) }
        return LabelRead(value: AgentConversationSelection.candidateLabel(title: node.title, description: node.description, childTexts: texts), complete: true)
    }
    private struct ScanContext {
        let navigation: Bool
        let clip: CGRect?
        let scope: Int
        let explicitSection: Bool
    }
    private nonisolated static func observe(pid: pid_t, requestedTitle: String, section: String? = nil, requestAccessibility: Bool, limit: TimeInterval) -> ConversationSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = min(started + 0.35, limit)
        let app = AXUIElementCreateApplication(pid)
        if requestAccessibility, let enabled = attribute(app, "AXManualAccessibility", deadline: deadline) as? Bool, !enabled {
            // Same opt-in used by the caret integration. Unsupported native shells are untouched.
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let rawWindow = attribute(app, kAXFocusedWindowAttribute, deadline: deadline), CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            rmDebug("🤖 Conversation scan: reason=no_window nodes=0 navigation=0 candidates=0")
            return ConversationSnapshot(pid: pid, reason: "no_window")
        }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        var navigationCount = 0
        var roleCounts = ["AXRow": 0, "AXLink": 0, "AXButton": 0, "AXGroup": 0]
        var exactOutsideNavigation = 0, exactInsideNavigation = 0
        var supportedNodes = 0, actionableNodes = 0, labelledNodes = 0, visibleNodes = 0
        var lastReadError: Int32 = 0
        var hiddenSubtrees = 0
        var entries: [ConversationSnapshot.Entry] = []
        var sectionMarkers: [AgentConversationSections.Marker] = []
        let walk = AgentConversationTraversal.walk(
            root: AXIdentity(element: window), context: ScanContext(navigation: false, clip: frame(window, deadline: deadline), scope: 0, explicitSection: false),
            shouldContinue: { ProcessInfo.processInfo.systemUptime < deadline && !Task.isCancelled && entries.count < 64 }
        ) { item, parent, _ in
            let element = item.element
            let info = node(element, deadline: deadline)
            if info.readFailed { lastReadError = info.readError; return .unavailable }
            // A hidden ancestor hides its whole subtree even when child frames are stale.
            if info.hidden { hiddenSubtrees += 1; return .leaf }
            if AgentConversationSelection.isContent(role: info.role, subrole: info.subrole, roleDescription: info.roleDescription) { return .leaf }
            let navigation = parent.navigation || info.navigation
            if roleCounts[info.role] != nil { roleCounts[info.role, default: 0] += 1 }
            let staticValue = info.role == "AXStaticText" && navigation
                ? text(element, kAXValueAttribute, deadline: deadline) : ""
            let nodeLabel = staticValue.isEmpty ? info.label : staticValue
            if AgentConversationSelection.normalize(nodeLabel) == AgentConversationSelection.normalize(requestedTitle) {
                if navigation { exactInsideNavigation += 1 } else { exactOutsideNavigation += 1 }
            }
            var scope = parent.scope
            if info.navigation { navigationCount += 1; scope = navigationCount }
            let explicitSection = parent.explicitSection || (navigation && section != nil
                && ["AXGroup", "AXList", "AXOutline", "AXScrollArea"].contains(info.role)
                && AgentConversationSelection.normalize(info.label) == AgentConversationSelection.normalize(section ?? ""))
            var clip = parent.clip
            if info.role == "AXScrollArea", let rect = frame(element, deadline: deadline) { clip = clip.map { $0.intersection(rect) } ?? rect }
            if let clip, clip.isEmpty { return .leaf }
            if section != nil, navigation,
               AgentConversationSections.isMarker(role: info.role, expanded: info.expanded,
                                                  hasPopup: info.hasPopup, popupValue: info.popupValue) {
                // Disabled headings still delimit sections. Unknown geometry must make
                // the scope unresolved rather than silently hiding an intervening heading.
                if let bounds = frame(element, deadline: deadline) {
                    if clip == nil || !bounds.intersection(clip!).isEmpty {
                        let label = candidateLabel(element, node: info, deadline: deadline)
                        guard label.complete else { return .unavailable }
                        sectionMarkers.append(.init(label: label.value ?? "", frame: bounds, scope: scope))
                    }
                } else {
                    sectionMarkers.append(.init(label: "", frame: .null, scope: scope))
                }
            }
            if navigation, ["AXRow", "AXLink", "AXButton", "AXGroup"].contains(info.role) {
                supportedNodes += 1
                if pressable(element, deadline: deadline) {
                    actionableNodes += 1
                    let label = candidateLabel(element, node: info, deadline: deadline)
                    guard label.complete else { return .unavailable }
                    if let name = label.value {
                        labelledNodes += 1
                        if AgentConversationSelection.isCandidate(role: info.role, label: name, navigation: true,
                                                                 pressable: true, requestedTitle: requestedTitle),
                           visible(element, clip: clip, deadline: deadline), let bounds = frame(element, deadline: deadline) {
                            visibleNodes += 1
                            entries.append(.init(element: element, label: name, role: info.role, clip: clip,
                                                 frame: bounds, scope: scope, explicitSection: explicitSection))
                            return .leaf // A row and its nested link are one target.
                        }
                    }
                }
            }
            return .children(info.children.map { AXIdentity(element: $0) }, ScanContext(navigation: navigation, clip: clip,
                                                                                    scope: scope, explicitSection: explicitSection))
        }
        if let section {
            entries = entries.filter { AgentConversationSections.belongs(to: section, candidateFrame: $0.frame,
                scope: $0.scope, explicitSection: $0.explicitSection, markers: sectionMarkers) }
        }
        let expired = ProcessInfo.processInfo.systemUptime >= deadline
        let reason = walk.readFailures > 0 ? "read_failure" : walk.depthLimits > 0 ? "depth_limit" : walk.nodeLimit ? "node_limit"
            : (walk.timeLimit || expired) ? "scan_budget" : navigationCount == 0 ? "no_navigation" : entries.isEmpty ? "no_candidates" : "ready"
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        rmDebug("🤖 Conversation scan: reason=\(reason) nodes=\(walk.visited) navigation=\(navigationCount) candidates=\(entries.count) elapsed_ms=\(elapsed)")
        rmDebug("🤖 Conversation bounds: depth=\(walk.maxDepth) depth_limits=\(walk.depthLimits) read_failures=\(walk.readFailures) read_error=\(lastReadError) node_limit=\(walk.nodeLimit) time_limit=\(walk.timeLimit)")
        rmDebug("🤖 Conversation structure: rows=\(roleCounts["AXRow", default: 0]) links=\(roleCounts["AXLink", default: 0]) buttons=\(roleCounts["AXButton", default: 0]) groups=\(roleCounts["AXGroup", default: 0]) exact_inside_navigation=\(exactInsideNavigation) exact_outside_navigation=\(exactOutsideNavigation)")
        rmDebug("🤖 Conversation candidates: supported=\(supportedNodes) actionable=\(actionableNodes) labelled=\(labelledNodes) eligible_visible=\(visibleNodes)")
        rmDebug("🤖 Conversation sections: requested=\(section != nil) markers=\(sectionMarkers.count) eligible=\(entries.count) hidden_subtrees=\(hiddenSubtrees)")
        return ConversationSnapshot(pid: pid, entries: entries, window: window, complete: walk.complete && !expired, reason: reason, section: section)
    }
    private nonisolated static func windowMatches(pid: pid_t, expected: AXUIElement) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let actual = attribute(app, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(expected, actual)
    }
    private nonisolated static func isCurrent(_ element: AXUIElement, deadline: TimeInterval = .infinity) -> Bool {
        AgentConversationSelection.isCurrent(selected: attribute(element, kAXSelectedAttribute, deadline: deadline) as? Bool,
                                             ariaCurrent: attribute(element, "AXARIACurrent", deadline: deadline) as? String)
    }
    private nonisolated static func confirmed(_ entry: ConversationSnapshot.Entry, snapshot: ConversationSnapshot, deadline: TimeInterval = .infinity) -> Bool {
        // An enclosing selected project/group does not prove its child conversation is active.
        if isCurrent(entry.element, deadline: deadline) { return true }
        // A scoped shortcut disambiguates identical titles. The other conversation's
        // window title cannot prove that this particular section entry is selected.
        if snapshot.section == nil, let window = snapshot.window {
            let title = text(window, kAXTitleAttribute, deadline: deadline)
            if AgentConversationSelection.normalize(title) == AgentConversationSelection.normalize(entry.label) { return true }
        }
        return false
    }
    private nonisolated static func pressAndVerify(_ originalSnapshot: ConversationSnapshot, index: Int,
                                                  onPhase: @escaping @MainActor @Sendable (String) -> Void) async -> AgentLocalActions.Outcome {
        let snapshot: ConversationSnapshot
        let entry: ConversationSnapshot.Entry
        if let section = originalSnapshot.section {
            // Section ownership depends on the live layout. Recheck it before dispatch,
            // and require the same focused window and one exact target in that section.
            let fresh = observe(pid: originalSnapshot.pid, requestedTitle: originalSnapshot.entries[index].label,
                                section: section, requestAccessibility: false,
                                limit: ProcessInfo.processInfo.systemUptime + 0.35)
            guard fresh.complete, let originalWindow = originalSnapshot.window, let freshWindow = fresh.window,
                  CFEqual(originalWindow, freshWindow),
                  let id = AgentConversationSelection.exact(originalSnapshot.entries[index].label, candidates: fresh.candidates),
                  let selected = fresh.candidates.firstIndex(where: { $0.id == id }) else {
                return .failed("The conversation section changed. Please try again.")
            }
            snapshot = fresh
            entry = fresh.entries[selected]
        } else {
            snapshot = originalSnapshot
            entry = snapshot.entries[index]
        }
        guard let expectedWindow = snapshot.window else { return .failed("The focused window is no longer available.") }
        let validationDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        let info = node(entry.element, deadline: validationDeadline)
        let label = candidateLabel(entry.element, node: info, deadline: validationDeadline)
        guard !Task.isCancelled, !info.readFailed, info.role == entry.role,
              label.complete, label.value == entry.label,
              AgentConversationSelection.isCandidate(role: info.role, label: entry.label, navigation: true, pressable: true, requestedTitle: entry.label),
              visible(entry.element, clip: entry.clip, deadline: validationDeadline), pressable(entry.element, deadline: validationDeadline) else {
            return .failed("The conversation list changed. Please try again.")
        }
        let focused = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard !Task.isCancelled, focused == snapshot.pid, windowMatches(pid: snapshot.pid, expected: expectedWindow) else {
            return .failed("Stopped because the focused app or window changed.")
        }
        if confirmed(entry, snapshot: snapshot) {
            await onPhase("already_selected")
            return .completed("The conversation is already selected.")
        }
        guard !Task.isCancelled else { return .failed("Stopped.") }
        await onPhase("selection_requested")
        // Recheck focus after the logging actor hop, immediately before dispatch.
        let stillFocused = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid }
        guard !Task.isCancelled, stillFocused, windowMatches(pid: snapshot.pid, expected: expectedWindow) else {
            return .failed("Stopped because the focused app or window changed.")
        }
        let result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
        // After dispatch, verification failure must never replay the selection through a planner.
        guard result == .success else { return .failed("Could not verify conversation selection. Please check the app before retrying.") }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        repeat {
            guard !Task.isCancelled else { return .failed("Stopped.") }
            let currentPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            guard currentPID == snapshot.pid, windowMatches(pid: snapshot.pid, expected: expectedWindow) else {
                return .failed("Conversation selection was sent, but the focused app or window changed.")
            }
            if confirmed(entry, snapshot: snapshot, deadline: deadline) {
                await onPhase("selection_verified")
                return .completed("Opened the conversation.")
            }
            // Re-rendering can replace an AX row. Re-observe and require one exact current
            // target in the same window; the stale reference itself is never clicked again.
            let fresh = observe(pid: snapshot.pid, requestedTitle: entry.label, section: snapshot.section, requestAccessibility: false, limit: deadline)
            if fresh.complete, let window = fresh.window, CFEqual(expectedWindow, window),
               let id = AgentConversationSelection.exact(entry.label, candidates: fresh.candidates),
               let selected = fresh.candidates.firstIndex(where: { $0.id == id }), confirmed(fresh.entries[selected], snapshot: fresh, deadline: deadline) {
                let focused = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid }
                guard !Task.isCancelled, focused, windowMatches(pid: snapshot.pid, expected: expectedWindow) else {
                    return .failed("Conversation selection was sent, but the focused app or window changed.")
                }
                await onPhase("selection_verified")
                return .completed("Opened the conversation.")
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return .failed("Stopped.") }
        } while ProcessInfo.processInfo.systemUptime < deadline
        await onPhase("selection_unverified")
        return .failed("Conversation selection was sent, but the result could not be verified. Please check the app.")
    }
}
