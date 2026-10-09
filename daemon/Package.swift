// swift-tools-version: 6.0
import PackageDescription

// The executable goes into UtsuriPanel.app (install.sh), whose Info.plist is
// ./Info.plist.
let package = Package(
    name: "utsuripanel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "utsuripanel", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
