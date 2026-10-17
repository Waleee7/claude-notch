// swift-tools-version:5.9
// For opening in Xcode. The canonical build is scripts/build.sh (plain swiftc), which
// also works on Command Line Tools installs whose PackageDescription is out of sync.
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            path: "Sources/ClaudeNotch"
        )
    ]
)
