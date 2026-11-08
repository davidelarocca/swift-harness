---
paths:
  - "**/*Tests/**"
  - "**/*Tests.swift"
---

# Rules for tests

- A UI test launches the app on its own data, never the user's: its own store, defaults domain and support folders, through the launch arguments or environment keys the project lists in `uiTests.isolation` of `.claude/swift-harness.json` (for example `-UITestingSuite`). Launch through the project's launch helper when there is one. `/swift-harness:doctor` warns about a UI test file that launches the app without them.
- A test that writes files writes into a temporary folder it creates, never into the project, the user's home or the app's real support folder.
- A defect found by hand becomes, in the same change, a test that fails on the old code, and a line in `docs/PITFALLS.md` if it cost real time or could come back.
