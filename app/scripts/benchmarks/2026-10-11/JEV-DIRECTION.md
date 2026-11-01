# Jev execution direction — 2026-10-11

## Primary evidence

- [Cua announcement and thread](https://x.com/trycua/status/2100649543079502213), read directly in the browser. The reported 5× speed / roughly 1000× cost improvement is one 2048 run, not a general desktop benchmark.
- [Official jev-use recipe](https://github.com/trycua/cua/tree/main/libs/cua-driver/examples/jev-use), inspected on this date. Its current native examples go beyond the announcement: bounded click, field input, popup/menu selection and checkboxes, with task-owned parameters and independent fixture state verification.

These are architectural references, not evidence that VibeRemote supports those tasks yet. The recipe's native instructions require Driver 0.30.1+; this Mac has 0.28.2. Do not assume the newest semantic or perception contracts exist locally.

## Why the first cooperation path was slow

Codex discovered the target and delegated; Jev then independently chose every next click, including a known arithmetic sequence, and Codex read the result again. This preserved large-model planning overhead while adding a network decision per click. Some batches handed back early and caused another delegation. Historical slow and failed samples remain in the October 10 report.

The current optimization uses one complete ordered plan, local resolution of unique freshly observed labels, Jev only for ambiguity and final checking, and one evidence-rich handoff. Every action still gets a fresh Driver token. Uncertain delivery is recorded before dispatch and must not be retried blindly. This improves a predictable sequence; it is not yet a general adaptive Jev worker.

## Two complementary execution paths

1. **Known sequence (implemented):** Codex supplies the ordered steps. Execute uniquely matched controls without another model call. Stop on a missing control or uncertain result; return the completed prefix and current evidence.
2. **Adaptive bounded task (proposed):** Codex supplies the goal, allowed actions, literal input parameters, dependencies, verification conditions and scope once. Jev selects among newly observed, immutable action candidates until the subtask finishes or requires escalation. Do not force a predetermined click sequence when later controls depend on the UI response.

Suitable next tasks include writing supplied text into a named search field, choosing a result, filling a small form, and selecting a popup option plus checkbox. Codex remains responsible for generating new prose, ambiguous goals and cross-application plans. Existing foreground consent and consequential-action boundaries apply to both paths.

## Expansion requirements before shipping

- Introduce typed candidates (`click`, `set_value`, `type_text`) whose parameters are owned by the executor. Jev selects an ID; it must not invent text, tool arguments or permission.
- Derive stable candidate identity from role, label and actionable ancestry; bind execution to a fresh token. Filter enabled/on-screen elements, cap candidates and prioritize those relevant to declared steps. Never persist an element index as identity.
- Supply compact task-relevant state and progress, not the complete unrelated window tree. Redact private parameter values where the decision does not require them. This is not permission to expose more apps or data to OpenRouter.
- Express dependencies and expected state changes. Count dispatched actions separately from verified outcomes. A final model opinion is not proof of completion.
- Add `reobserve` and `abstain`, bounded no-progress limits, cancellation and uncertain-delivery handoffs. Codex should resume the unfinished work without replaying successful actions.
- Prefer AX or DOM. Only add optional screenshot perception when semantic content genuinely fails; capability-check capture-bound clicks and keep foreground escalation behind the existing human Continue action. Do not install or enable perception merely because it is mentioned in the recipe.
- Verify against disposable native fixtures with independent state, then real apps: exact text, selected option, checkbox state, step order, duplicates, cancellation and foreground resumption. Include failed samples and compare total user latency, not only Jev inference time.

No Driver upgrade, perception installation, browser permissions or broader Jev action scope was introduced by this research.
