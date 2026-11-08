// swift-tools-version:5.9
import Foundation
import PackageDescription

// Embed Info.plist into the executable so the app also works when started
// straight from `swift run` or Xcode (menu-bar only, audio-capture permission text).
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist")
    .path

let package = Package(
    name: "Leveler",
    // Core Audio process taps need macOS 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "LevelerDSP"),
        .executableTarget(
            name: "Leveler",
            dependencies: ["LevelerDSP"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ]),
            ]
        ),
        .testTarget(name: "LevelerDSPTests", dependencies: ["LevelerDSP"]),
    ]
)
