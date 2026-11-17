# Computer Use routing

Implementation direction approved 2026-11-15: **local actions first, Jev where judgment
helps, and the full agent where planning is necessary**. Every model request uses
OpenRouter. This is one Computer Use experience; the user does not choose a route per task.

## Configuration

Settings › Computer Use exposes an Automation Model for tool-driven planning, a Decision
Model for Jev’s bounded choices, and a single OpenRouter key stored in Keychain. Decision
requests use `/api/alpha/decisions`; automation requests use `/api/v1/chat/completions`.
An ordinary chat model cannot be substituted into the decision field unless it supports
that endpoint. Existing CLI configuration values remain available for compatibility;
they are not the current settings interface.

User-confirmed application names can be pinned locally with `agentApplicationAliases`
in the existing preferences domain: display name → bundle ID. This makes a user's chosen
name stable across app renames and distinguishes multiple apps with the same display name.
An explicit bundle-ID command remains exact. A missing configured app never falls back
to another app with that display name; conflicting normalized aliases require clarification.

## Execution boundaries

1. Parse a complete, supported command conservatively. Opening or activating an app and
   opening an explicit HTTP(S) URL can use native actions without an inference request.
   A multi-step request must not be mistaken for a simple command by matching its prefix.
2. The conversation adapter supports ChatGPT (`com.openai.chat`), Codex
   (`com.openai.codex`, also locally named ChatGPT), and Claude. It makes a bounded read of
   the app’s exposed conversation navigation, not chat contents or a private database.
   A unique exact title is resolved locally. Otherwise Jev can choose among the observed
   candidates. Local code owns candidate IDs and executable parameters. Unknown choices,
   missing or invalid confidence, ambiguity, a timeout, and cancellation must not become
   arbitrary clicks.
   Navigation is recognized from native outlines, semantic navigation landmarks, or
   explicit sidebar/list identifiers. Button/group rows are eligible only for an exact
   requested title inside that navigation; Jev never receives those controls as guesses.
   A row may expose its title in a single static-text child. Action controls and main
   conversation/editor content remain excluded.
3. Requests outside the direct capabilities go to the automation model with agent-desktop.
   Conversation fallback is allowed before a target-selection action is dispatched. If
   the app was already activated, the handoff records that fact. Once selection has been
   dispatched, failed verification is reported without automatically replaying the request
   through the full agent.
4. Completion is grounded in execution results and observed state. A model’s confidence
   score or statement of success alone is not a completion check.

The initial scope is intentionally bounded. Application activation does not imply that any
conversation in any app can be opened through a universal native API. Conversations not
exposed in the current navigation, collapsed sidebars, and unsupported app structures need
the full automation path. The quick adapter does not implement a search of hidden chat
history. The same selected target must remain valid at dispatch, and its selected state or
matching focused-window title must verify the result.
An entry's `AXARIACurrent` value of `true` or `page` also verifies selection; keyboard focus
and a selected enclosing project/group do not. If the app re-renders the selected row,
verification observes a fresh exact target in the same focused window without clicking again.

## Responsiveness and cancellation

The command bar appears and takes focus at a fixed bottom-center position, 24 points above
the active screen's usable bottom edge (above a visible bottom Dock). It has no arrow and
does not locate or follow the app's Dock icon. The screen's usable frame is captured when
the bar opens, so Dock animation and later text/status resizing cannot move its anchor.
Reopening on another screen chooses that screen's anchor.

Direct actions avoid loading agent guides, taking a general app snapshot, and starting a
planner. Model-backed work remains cancellable. Do not execute speculative UI actions from
unfinished speech: the current dictation path submits its finalized transcript.

Sidebar metadata is fetched in batches. Each scan has a 350 ms budget (600 nodes, 64 levels,
64 candidates), with a total 900 ms readiness budget for a just-activated app. The shared
traversal deduplicates references and bounds the total queued nodes; it has no separate
200-child cutoff. Nested label reads share the deadline. Only an explicitly unsupported
batch API permits individual attribute reads; a stalled batch is not retried that way. Truncated
snapshots cannot establish a unique match. Selection verification polls for up to 1.2 seconds
and stops immediately on observed success. These are scheduling/IPC budgets, not a promise
that the operating system always returns within them.

Current monotonic timing logs record routing, target/planner readiness, action requests,
and completion. `first_action_requested` is a tool dispatch request, not an observation of
a visible UI change; direct actions currently report their total completion time. Live
acceptance must measure the first visible action and full speech-release latency separately.
Logs contain route names, phases and durations, not command text, conversation titles, API
keys, or captured credentials.
Parsing and app resolution also emit sanitized phase/result codes and match counts, so
an unsupported command can be distinguished from a missing or ambiguous app before a
conversation adapter starts.
Conversation runs additionally record navigation readiness, exact matching, Jev request/
response, selection request/verification, and explicit fallback reasons. Scan diagnostics
contain only structural counts and reason codes, never titles or captured UI text. Exact
matches do not read the OpenRouter key or make a model request.

User-confirmed conversation shorthand can be stored locally in `agentConversationAliases`
under the existing `com.viberemote.app` preferences domain. Its schema is a dictionary of
bundle ID → shorthand → full visible title, for example
`{"example.chat": {"launch notes": "Planning the autumn launch"}}`. A user-confirmed
section can instead use `{"title": "Planning the autumn launch", "section": "Recent"}`
as the target. There is currently no settings editor for these shortcuts. Do not embed personal titles in the source or learn
aliases from a model's unsupported success claim. Expansion happens once, scoped to the
activated app; normalized duplicate alias keys stop selection. A confirmed alias remains
exact-only and never enters the semantic selector. Missing, renamed, hidden or duplicate
destinations use the existing safe fallback with the original command. Every destination
still passes sidebar ownership, action-label rejection, visibility, uniqueness and selection
verification. Matching folds runs of Unicode whitespace without removing word boundaries.
Section selection requires an explicitly named containing region or a visible semantic
heading in the same navigation scope. Every intervening heading remains a boundary,
including disabled headings and headings whose text is shorter than an indented row.
Unknown or ambiguous geometry cannot establish membership. Hidden ancestors exclude their
whole subtree. Scope is checked again before dispatch and after re-rendering; scoped targets
require their own selected/current state, never just a same-name window title.

## Validation

Use fixture-driven tests for command recognition, strict candidate selection, malformed
provider responses, no-action fallback, cancellation, and settings persistence. Mocked
provider responses establish protocol handling, not model quality or real desktop success.

The initial user-driven trial on 2026-11-15 recorded one local action at 275 ms and four
planner runs at 8.095–11.831 seconds. The conversation attempt reached app focus at 300 ms,
fell back at 321 ms, and reported completion at 11.831 seconds. The user confirmed operations
felt faster. These are app-reported timings, not an independent screen/frame measurement.
The first expanded-adapter trial opened the requested visible `AIOS 小标` conversation in
all three user-confirmed runs, but every run still fell back: 10.965, 8.856, and 9.031 seconds
(median 9.031 seconds). Scans stopped after roughly 113–115 nodes in 15–53 ms, reporting the
then-combined `scan_limit` reason. This did not establish whether the old 24-level cutoff,
the sibling cutoff, or a failed read was responsible. The subsequent traversal revision
tests deep wrapper chains and broad lists directly and logs those failure causes separately.
The subsequent user-driven retry completed its scan in 64–98 ms across 456 nodes and 34
levels with no truncation or read failures, but found no exact requested title and still
fell back (`no_candidates`). App focus took 405 ms, planner dispatch began at 6.894 seconds,
and total reported completion was 16.517 seconds. The user confirmed the correct conversation
opened and felt fast; that does not establish a successful local route. Exact sidebar-title
matching remains under investigation. Automated inspection/control of this ChatGPT host app
is blocked by the test tool, so fixture tests cannot establish its actual exposed sidebar
structure. The same installed update was user-confirmed to require no permission reauthorization.
The user then clarified that the requested name was shorthand for a longer sidebar title.
A user-local alias resolved that title, but the next scans found two exact eligible entries.
They safely fell back at 705 ms and 246 ms; neither established quick-route success. The user
reported the duplicate-title ambiguity and identified the intended section as Recent.
Both shorthand and full-title shortcuts now require that section. The next user-confirmed
successful run used the planner without entering the conversation adapter: first action
request at 3.845 seconds, total completion at 13.436 seconds. The user's confirmed command
matches the parser, which narrows this bypass to missing/ambiguous application resolution.
The chosen app name is now pinned to the previously established bundle ID in local
preferences. Popup buttons are also excluded from section-heading detection because
`AXExpanded` alone does not identify a disclosure heading. Live quick-route verification
of the app-resolution and section-scoped path remains pending.

Live acceptance should compare the same commands and success criteria across direct,
Jev-assisted, and full-agent routes. Include cold and warm app launches, ambiguous targets,
network failures, user cancellation, and the complete dictation-to-action flow. Record
median and slow-case latency alongside success and fallback rates. Historical JEV reports
under `scripts/benchmarks/` describe the removed executor and are not current performance
claims. No speed guarantee follows from adding this routing architecture alone.

## References

- [OpenRouter’s Jev and Decisions API documentation](https://openrouter.ai/blog/insights/what-is-jev/)
- [TypeSafe primitives](https://docs.typesafe.ai/introduction)
- [Electron's accessibility opt-in](https://www.electronjs.org/docs/latest/tutorial/accessibility/)
- [Chromium's macOS accessibility mapping](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/accessibility/platform/ax_platform_node_cocoa.mm)
- [Product direction](ProductDirection.md)
