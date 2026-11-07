// swift-tools-version: 6.0
// Fixture for the mutation run with --verify (#79): tests/mutate-fixture.sh copies it, adds the
// setup templates (KeyboardCheck, LayoutContract, Screenshot, Snapshot, SwiftLint, verify.sh),
// approves its snapshots, and checks that each operator is killed by the check it targets.
import PackageDescription

let package = Package(
    name: "MutateVerifyFixture",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Components"),
        .testTarget(name: "ComponentsTests", dependencies: ["Components"]),
    ]
)
