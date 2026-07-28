// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NamiFileManager",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "nafi", targets: ["NamiFileManager"])
  ],
  targets: [
    .executableTarget(
      name: "NamiFileManager",
      path: "Sources/NamiFileManager",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("QuickLook"),
        .linkedFramework("QuickLookUI"),
        .linkedFramework("Security"),
      ]
    )
  ],
  swiftLanguageModes: [.v5]
)
