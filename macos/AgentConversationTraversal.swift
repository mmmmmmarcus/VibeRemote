/// Bounded breadth-first traversal shared by native conversation discovery and its
/// fixtures. Limits count actual queued elements, not arbitrary siblings per parent.
enum AgentConversationTraversal {
    enum Step<Element, Context> {
        case children([Element], Context)
        case leaf
        case unavailable
    }

    struct Report: Equatable {
        var visited = 0
        var maxDepth = 0
        /// Branches whose unvisited children could not be inspected at the depth bound.
        var depthLimits = 0
        var readFailures = 0
        var nodeLimit = false
        var timeLimit = false

        var complete: Bool {
            depthLimits == 0 && readFailures == 0 && !nodeLimit && !timeLimit
        }
    }

    /// An element is queued once, with the context of the first path to it. Native AX
    /// trees have one owning parent; deduplication also terminates malformed cycles.
    static func walk<Element: Hashable, Context>(
        root: Element,
        context: Context,
        maximumNodes: Int = 600,
        maximumDepth: Int = 64,
        shouldContinue: () -> Bool,
        visit: (Element, Context, Int) -> Step<Element, Context>
    ) -> Report {
        var report = Report()
        guard maximumNodes > 0, maximumDepth >= 0 else {
            report.nodeLimit = true
            return report
        }
        var queue = [(element: root, context: context, depth: 0)]
        var seen: Set<Element> = [root]
        var cursor = 0
        traversal: while cursor < queue.count {
            guard shouldContinue() else { report.timeLimit = true; break }
            let item = queue[cursor]
            cursor += 1
            report.visited += 1
            report.maxDepth = max(report.maxDepth, item.depth)
            switch visit(item.element, item.context, item.depth) {
            case .leaf:
                continue
            case .unavailable:
                // Failure is not an empty subtree: it may conceal another matching title.
                report.readFailures += 1
            case .children(let children, let childContext):
                for child in children {
                    guard shouldContinue() else {
                        report.timeLimit = true
                        break traversal
                    }
                    guard !seen.contains(child) else { continue }
                    guard item.depth < maximumDepth else {
                        report.depthLimits += 1
                        break
                    }
                    guard queue.count < maximumNodes else {
                        report.nodeLimit = true
                        break
                    }
                    seen.insert(child)
                    queue.append((child, childContext, item.depth + 1))
                }
            }
        }
        return report
    }
}
