# Adoption audit

Issue [#104](https://github.com/davidelarocca/swift-harness/issues/104), v0. A project that already has its own rules, commands and checks should be adopted without being reshaped. The audit (`scripts/audit.sh`, `/swift-harness:setup audit`) says what the project already has, reading it as text only, and proposes a guest setup with the project's own commands.

## Method

- **Static observation only.** Rules, docs, scripts, CI files and manifests are read as text. No project command, script or test runs, no `swift package dump-package` (it runs `Package.swift`), and not even git, since a repository's config can make git run programs (`core.fsmonitor`). Files that may hold secrets are listed by path and never opened. Output goes to stdout only.
- **Levels.** Each finding is *declared* (a document says so), *configured* (a file defines it), *executed* (the harness's own end-of-turn record says it ran), *observed* (the audit saw the property in the files, such as an entitlement value), or *unknown* with the reason.
- **Proof of no writes and no runs** (`tests/run.sh`):
  - fake `swift`, `xcodebuild`, `python3`, `make`, `xcrun` and `git` record every call;
  - the project's scripts, and git through a `core.fsmonitor` hook, would each leave a sentinel file if they ran;
  - the project tree and the plugin data folder are compared before and after.

  No call, no sentinel and no change were recorded.
- **Cases from an external review**, each a test on the fixture:

  | Case | What the audit must do |
  |---|---|
  | V-01 | a platform only the README claims stays *declared* |
  | V-07 | an accessibility helper used by one test is *observed*, and the screens it reaches are *unknown* |
  | V-08 | the project's own agent rules, formatter and docs check are kept and reused |
  | V-09 | an executable build script is listed, never run |
  | V-15 | a workflow that cannot be read as YAML, and an unreadable Xcode project, are *unknown* with the reason |
  | V-17 | past the file or byte limits the result says incomplete, with the numbers |
  | V-18 | an `.env` file and a `Secrets.xcconfig` are never opened, and their values never appear |

- **Baseline:** the file-presence checklist, what `ls` shows about the well-known names, without reading content:
  - `Package.swift`: `swift build` and `swift test`;
  - an Xcode project: its first shared scheme;
  - a config file: the tool is enforced;
  - a script named like a docs check: the project has one.
- **Ground truth:** for each project, seven adoption decisions labelled by hand from the project's rules, CI and scripts:
  - D1, D2: the build and test command the maintainers use;
  - D3: whether it has its own docs check;
  - D4: whether lint is run by something (not only configured);
  - D5: the same for the formatter;
  - D6: the platforms configured;
  - D7: the app sandbox value.

  The labels are not blind: the fixture and the labels are by the same author.
- **Do not ship if:** any write or run, any secret value in the output, more than 10 seconds on the real app, or not at least 20 points better than the baseline.

## Results

| Project | Files listed / file reads | Time | Audit correct | Baseline correct |
|---|---|---|---|---|
| The fixture in `tests/run.sh` | 23 / 24 | 1 s | 7 / 7 | 4 / 7 |
| [IceCubesApp](https://github.com/Dimillian/IceCubesApp) @ `98098b9c` | 742 / 30 | 1 s | 7 / 7 | 2 / 7 |
| A real ~97k-line macOS app with its own rules, scripts and UI tests (a copy, read-only) | 1035 / 122 | 2 s | 7 / 7 | 5 / 7 |
| **All** | | | **21 / 21 (100%)** | **11 / 21 (52%)** |

Where the baseline goes wrong:
- **IceCubesApp: build and tests.** Its first shared scheme is an extension. Its rules build and test through an agent tool (XcodeBuildMCP), not a shell command. The audit names the app's own scheme, `xcodebuild -project IceCubesApp.xcodeproj -scheme IceCubesApp build`, with "inferred from the shared scheme" and a note that `verify.sh` needs a shell command. That proposal still lacks the simulator destination, which a person has to add. For tests it proposes `swift test` in the six packages that declare test targets.
- **A formatter config that nothing runs** (the fixture, IceCubesApp). The baseline calls it enforced. The audit says "config present; nothing found that runs it", and for IceCubesApp also that its rules name `swiftformat`.
- **Platforms and the sandbox.** The baseline cannot tell them without reading the files. The audit gives both, and shows where documents and configuration differ: IceCubesApp's README and rules mention macOS, while its packages and project configure iOS and visionOS.

On the real app the audit also:
- proposes the commands its rules give (`swift build`, `swift test`);
- finds its own docs checker, so it proposes `--no-docs`;
- shows that 4 of 46 UI test files set launch arguments and 4 launch the app themselves;
- leaves its secrets file unopened.

**Noise:** 2 of about 45 rows on the real app are wrong. Both are prose that names a command, in a script's comment and in its usage text, read as a configured command.

## Decision

Ship v0: it passes every do-not-ship condition, and it beats the baseline by 48 points on the decisions an adoption needs.

## Limits

- **Small sample:** three projects, labelled by the author, not blind.
- **Text only.** A command found in a file is not proof that it works or is the one people use. A proposal *inferred* from a scheme or test targets says so. Commands found in prose are a known source of noise.
- **No time measured.** The cost of each command is "not measured" until the user approves the timing step (next in #104), which runs them.
- **YAML is checked for structure** (brackets, quotes, tabs), not parsed. A file that passes may still be invalid.
