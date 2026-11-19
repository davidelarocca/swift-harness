---
paths:
  - "**/*.swift"
---

# Architecture rules for all Swift code

- Respect module boundaries documented in `docs/ARCHITECTURE.md`. A new dependency between modules needs a reason in the change description; a new direction of dependency needs an ADR.
- If `docs/architecture-contracts.json` exists, it lists the dependencies each SwiftPM target may have, and the end-of-turn check enforces it. To make code compile, change the code, not `Package.swift` or the contract; a new dependency needs the user's agreement first. Test targets are checked only when the contract lists them: the rule holds for them all the same, so ask before a test target gains a dependency on another module. <!-- check: architecture contracts -->
- One state management pattern: {{STATE_PATTERN}}. Do not introduce a competing one.
- UI updates on the main actor. Heavy work (decoding, metadata, artwork, file scanning) runs off the main actor.
- Concurrency escape hatches (`@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, `assumeIsolated`) silence data race checks: never add one just to make code compile. Try first an actor, `@MainActor`, a `Mutex` or `let` state, Sendable values, `await` instead of assuming isolation, or an updated dependency. When one is truly needed (a type guarded by a lock the compiler cannot see, a callback the system guarantees on the main thread), write the reason on the same line, `// concurrency: <why it is safe>`; SwiftLint rejects a new one without it. <!-- check: lint concurrency_unchecked_sendable --> <!-- check: lint concurrency_nonisolated_unsafe --> <!-- check: lint concurrency_preconcurrency --> <!-- check: lint concurrency_assume_isolated -->
- Prefer dependency injection through initializers or the environment over singletons.
- Before editing a type, find its callers. Keep the change as small as the task allows.
- Optimizations need a measurement first (Instruments or a benchmark test). Fewer lines is not an optimization.
