# Drift score

Issue [#80](https://github.com/davidelarocca/swift-harness/issues/80). Drift is the problem the plugin exists for. `scripts/drift.sh` (`/swift-harness:drift`) measures it the same way at every commit, so a project can see whether it gets more or less coherent.

## Method

In the UI code (Swift files outside tests, outside the files the SwiftLint padding rule excludes, and outside `--exclude`):
- **Design values.** Padding, stack spacing, corner radius and font size. Each use is classed as a literal number or a token (any other expression). Literals are counted as distinct values and uses. The token share is tokens / (tokens + literals). Colors made from components are counted as literals.
- **Near-duplicates.** A View or ViewModifier the registry does not list, whose role (the last word of its name) is the role of a registered component.
- **Problems.** What the registry, layout contract, docs and architecture contract checks report.

The **score** is the sum of the things to fix. It grows with the code, so each commit also gets its non-empty UI lines and the literal uses per 1000 of them. The token share and that density compare across sizes. `history <range> --every N` measures one commit in N, plus the last, each extracted with `git archive`.

## On the fixtures

`tests/run.sh` builds a three-commit history:
1. **Clean:** every design value is a token.
2. **Planted drift:** five literal values, a hardcoded color, a `StatusPill` beside the registered `Pill`, and a broken docs link.
3. **Clean-up:** the drift removed again.

The scores are 0, 8, 0. Token share is 100%, 29%, 100%, and the near-duplicate is found.

## On an open-source app

[IceCubesApp](https://github.com/Dimillian/IceCubesApp), a SwiftUI Mastodon client: 2696 commits from 2022-11-20 to 2026-10-13. It has no swift-harness config, no registry and no SwiftLint config, and its design-system package (`Packages/DesignSystem/`) is left out with `--exclude`. One commit in 50 was measured, 55 points, in 50 seconds on an M-series Mac (about 1 second per commit for a 36k-line UI).

```bash
drift.sh history HEAD --every 50 --exclude '^Packages/DesignSystem/' --json
```

| Date | Score | Token share | Literals per 1k UI lines | UI lines | Distinct literal values |
|---|---|---|---|---|---|
| 2022-12-21 | 33 | 59% | 11.9 | 2,776 | 11 |
| 2023-01-23 | 123 | 53% | 10.5 | 11,684 | 25 |
| 2023-07-06 | 144 | 52% | 7.6 | 19,038 | 29 |
| 2023-12-05 | 154 | 52% | 7.2 | 21,395 | 30 |
| 2024-09-19 | 238 | 50% | 8.7 | 27,505 | 35 |
| 2026-10-13 | 298 | 46% | 8.3 | 35,786 | 40 |

What the curve says:
- **Growth and drift are mixed in the score.** The score grows 9 times over four years and the UI code 13 times. That is why the density and the token share exist.
- **Drift is there, slow.**
  - The token share falls from 59% to 46%.
  - The distinct literal values grow from 11 to 40: paddings of 22 different sizes, radii of 8.
  - The density falls until the end of 2023 (7.2 per 1k lines), then rises again (8.3).
- **A jump is one commit.** Between two samples the literal radii go from 53 to 69. Measuring every commit of that stretch puts 12 of them in one commit, "Enhance visionOS support" (b9b3d0e7, 2024-02-06), which adds `RoundedRectangle(cornerRadius: 8)` twelve times. That is a repeated value with no token, exactly what a radius token would have kept in one place.
- **The drops in this history are rewrites, not clean-ups.** The largest early fall in literal paddings (61 to 55, end of January 2023) comes from moving the notifications and the timeline into a `List`, which removed the code. No commit in the sample replaces literals with tokens.

Near-duplicates and check problems are 0 throughout, because there is no registry or contract to read.

## Limits

- A token is any expression that is not a number. `.layoutPadding + 16` and `isEmbedded ? 0 : .layoutPadding` count as tokens, though they carry a literal.
- Colors have no token count. Named and system colors cannot be told from tokens by reading text.
- Near-duplicates are matched by name only. A component with another name and the same structure is not found, and two components with the same role word can be different things. The list is for a person to confirm.
- The score weighs every item the same: a literal padding counts as much as a broken contract.
