# Pitfalls

Traps that already cost real time in this project, or came back. Read this list before starting a task; the checkpoint after a compaction names it. Keep about a dozen entries: when one no longer applies (the code that caused it is gone, or a check now catches it), move it to the archive or delete it.

Each entry: what goes wrong, how it shows, and what to do instead. Link the test or check that now catches it, if any.

## Build and tooling

- (none yet)

## Data and tests

- UI tests must never open the user's real data: they launch with the isolation arguments in `uiTests.isolation` (the tests rule of the setup says how).

## UI

- (none yet)
