// swift-tools-version: 6.0
import PackageDescription

// The performance budget fixture (#33): a measured operation, a regressed version of it
// (SLOW=1 decodes twice) and other work in the test process (HOG=1).
let package = Package(
    name: "Library",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Library"),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ]
)
