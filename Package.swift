// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NafiFileManager",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "nafi", targets: ["NafiFileManager"]),
    .executable(name: "nafi-background-agent", targets: ["NafiBackgroundAgent"])
  ],
  dependencies: [],
  targets: [
    .executableTarget(
      name: "NafiFileManager",
      dependencies: [],
      path: "Sources/NafiFileManager",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CoreServices"),
        .linkedFramework("NetFS"),
        .linkedFramework("Network"),
        .linkedFramework("QuickLook"),
        .linkedFramework("QuickLookThumbnailing"),
        .linkedFramework("QuickLookUI"),
        .linkedFramework("Security"),
        .linkedFramework("ServiceManagement"),
        .linkedFramework("FileProvider"),
        .linkedFramework("Carbon"),
      ]
    ),
    .executableTarget(
      name: "NafiBackgroundAgent",
      path: "Sources/NafiBackgroundAgent",
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .testTarget(
      name: "NafiFileManagerTests",
      dependencies: ["NafiFileManager"],
      path: "Tests/NafiFileManagerTests"
    )
  ],
  swiftLanguageModes: [.v5]
)
