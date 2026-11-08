# Evals

Measurements of the harness itself: whether its checks catch what they claim, on fixtures and on a real app. Each eval says how it was run, what it found, and what it cannot tell.

| Eval | Question | Issue |
|---|---|---|
| [Check sensitivity](check-sensitivity.md) | Does each check notice a defect planted in the code or the docs it guards? | [#79](https://github.com/davidelarocca/swift-harness/issues/79) |
| [Adoption audit](adoption-audit.md) | Does a read-only audit find what a project already has, better than checking which files exist? | [#104](https://github.com/davidelarocca/swift-harness/issues/104) |
| [Sensitivity of a project's own checks](adapter-sensitivity.md) | Does a check that runs and passes catch defects of its own class? | [#105](https://github.com/davidelarocca/swift-harness/issues/105) |
| [Drift score](drift.md) | Does the drift score move with real drift over a project's history? | [#80](https://github.com/davidelarocca/swift-harness/issues/80) |

## How an experiment is run

The research track of the [roadmap](../../ROADMAP.md#research-track) studies methods from other fields as hypotheses. Each experiment is written down before its results, with:

- **question:** the decision it resolves;
- **hypothesis** and the **simple baseline** it must beat, run on the same extracted data (the most frequent values, identifier overlap, the declared order);
- **data:** repositories pinned to a commit, with the selection rule; tuning and evaluation on different repositories, or on a chronological hold-out for histories;
- **controls:** planted defects that must be caught, and healthy cases that must not be flagged;
- **metrics and thresholds,** fixed in advance, with raw counts and runtime;
- **decision:** adopt, revise or archive. A negative result is published like a positive one.

Results are labelled by how much they can carry: *verified in the repository* (code, tests, CI), *measured* (an experiment here, with its script and data), *reported* (someone else's numbers, not reproduced yet) or *hypothesis*. A feature ships only when it beats its baseline, its false alarms are known, and its cost is bounded on a real project.

Evals with and without the plugin in real Claude Code sessions ([#8](https://github.com/davidelarocca/swift-harness/issues/8)) will be added here. The smoke runs so far are in [`tests/smoke/RESULTS.md`](../smoke/RESULTS.md).
