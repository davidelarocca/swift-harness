# Porting plan: macOS to iOS

Assessed on {{DATE}} at commit {{COMMIT}}, by `/swift-harness:port-to-ios`. Evidence is `file:line` at that commit. Static analysis is not a build: see the status below for what was actually built, tested and reviewed.

## Summary

{{FIVE_LINES: the share of modules per class, the decisions needed, the recommended structure, the biggest risk, the first step.}}

## Status per platform

| Platform | Built | Tests | UX review | Notes |
|---|---|---|---|---|
| macOS | {{yes, date / not run}} | {{passed, date / not run}} | {{done / not done}} | |
| iOS | {{not built / builds, date / fails, date}} | not run | not done | |

Never "ready": each column says what happened, on which date.

## Platforms and dependencies

{{Platforms declared (porting.sh summary). External dependencies and the platforms they declare, or "not checked".}}

## Modules

| Module | Class | Evidence | What it needs |
|---|---|---|---|
| {{Packages/Core › Sources/Core}} | {{Share as is}} | {{porting.sh: no macOS-only API}} | {{platforms: .iOS}} |

## Features and screens

| Feature or screen | Class | Evidence | iPhone | iPad |
|---|---|---|---|---|

## Unavailable on iOS and redesigns

| What | Evidence | Options | Decision needed from |
|---|---|---|---|

## Audio on iOS

Only for an app that plays or records audio; delete it otherwise. From `porting.sh audio`, as printed: static evidence, nothing was run.

| What iOS needs | Evidence (`file:line` or not found) | What is missing | Proved on a device or simulator |
|---|---|---|---|
| Audio session category and activation | {{...}} | {{...}} | {{no}} |
| Interruptions (calls, Siri, other apps) | {{...}} | {{...}} | {{no}} |
| Route changes (headphones, Bluetooth, AirPlay) | {{...}} | {{...}} | {{no}} |
| Remote commands and Now Playing | {{...}} | {{...}} | {{no}} |
| Background audio (`UIBackgroundModes`) | {{...}} | {{...}} | {{no}} |

macOS-only audio with no iOS equivalent (exclusive device access, device sample rate, output device selection): {{each with `file:line`, and the adapter or the product decision it needs}}.

## Target structure

| Option | What changes | Shared | Effort | Risks for macOS |
|---|---|---|---|---|

Recommendation: {{option, and why; what would change it}}.

## Steps

{{Ordered, each small and verifiable: change, how it is verified on macOS, how on iOS.}}

## Not assessed

{{What, and why.}}
