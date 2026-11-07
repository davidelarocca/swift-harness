// swift-tools-version: 6.0
// Fixture for the mutation run (#79): scripts/mutate.sh copies it, plants one defect at a
// time and checks that the check it targets fails. Only read with `swift package dump-package`.
import PackageDescription

let package = Package(
    name: "MutateFixture",
    platforms: [.macOS(.v14)],
    products: [.library(name: "App", targets: ["App"])],
    targets: [
        .target(name: "App", dependencies: ["Feature", "DesignSystem"]),
        .target(name: "Feature", dependencies: ["Domain", "DesignSystem"]),
        .target(name: "Domain"),
        .target(name: "DesignSystem"),
        .testTarget(name: "AppTests", dependencies: ["App"]),
    ]
)
