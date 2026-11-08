# Sensitivity of a project's own checks

Hypothesis H1 of [#105](https://github.com/davidelarocca/swift-harness/issues/105#issuecomment-6722064261). A project check that runs and passes may still be blind to defects of its own class. Would a "sensitive" level, a planted defect that the project's check must catch, tell an adoption something that "executed" does not?

## Method

- **Projects and checks**, each run the way the project's CI or rules run it:

  | Project | Check |
  |---|---|
  | [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) @ `65b51f2` | `swiftlint lint --strict` |
  | [Ice](https://github.com/jordanbaird/Ice) @ `11edd39` | `swiftlint lint --strict` |
  | A real ~97k-line macOS app, on a read-only copy | its own docs checker, a script in its repository |

- **Operators**, one site each, appended to the first non-test Swift file the lint config includes, or applied to a document:
  - lint: a forced cast, a `try!`, a 240-character line, trailing spaces, a one-letter name;
  - docs: a link to a file that does not exist, a path in backticks that does not exist.
- **Procedure.** The check runs on the clean copy, then once per operator, and the file is restored after each.
- **Result per operator:**
  - *caught*: the check fails with a new problem on the planted file and, for lint, under the expected rule;
  - *wrong reason*: it fails elsewhere;
  - *not caught*.
- **Baseline:** the *executed* level (a check that runs and passes is assumed to work).
- **Drop the hypothesis if any of these holds:**
  - every check is sensitive on every project;
  - in two projects of three no operator matches;
  - more than 10% of catches are for the wrong reason;
  - a check costs more than 5 minutes.

## Results

| Project | Clean run | Caught | Not caught | Wrong reason | Time per run |
|---|---|---|---|---|---|
| NetNewsWire | passes (727 files, 0 violations) | trailing spaces | forced cast, `try!`, long line, one-letter name | 0 | ≤ 1 s |
| Ice | fails already with SwiftLint 0.65 (9 violations; its CI pins an older action) | forced cast, `try!`, trailing spaces | long line, one-letter name | 0 | ≤ 1 s |
| The real app | passes | stale link (1 of 1), stale path in the agent rules and the docs hub (2 of 2) | stale path in a decisions log, probably out of the checker's scope as a record of the past (inferred, not confirmed) | 0 | ≤ 1 s |

No drop condition holds: H1 stands against its baseline. A lint that runs strict in CI and passes caught one of five defect classes in one project, and three of five in the other.

## Against a stronger baseline

Every lint defect that was not caught comes from the project's own config:
- NetNewsWire turns off `force_cast`, `force_try` and `line_length`, and relaxes `identifier_name`;
- Ice turns off `identifier_name` and `line_length`.

For SwiftLint, most of that can be read from the config without running anything. A baseline the experiment did not plan, "read the check's declarative config", gives the same answer for the rules turned off. It misses only the relaxed rule.

For a check with no declarative config, such as the real app's docs script, the scope could only be seen by planting defects. "Not caught" is also mostly a deliberate choice of the project, not a broken check. The value is information for adoption: what the project's check covers, so the harness neither assumes coverage that is not there nor duplicates coverage that is.

## Decision

- **In the adoption audit (#104):** for SwiftLint, swift-format and SwiftFormat, read the rules turned off, turned on or listed as the only ones, statically, and report them. Shipped with this eval.
- **In #105:** the sensitive level only for checks without a declarative config (scripts), only with the user's approval, and as information, never as a gate.

## Limits

- **Small sample:** three projects, five lint operators and two docs operators, one site each.
- **Generic operators.** They measure the default classes of SwiftLint and a docs checker, not the defects each project cares about most.
- **Inferred, not confirmed:** the reason one docs operator was not caught.
- The experiment script is not part of the plugin.
