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
  dependencies: [
    .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.34.1"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
  ],
  targets: [
    .executableTarget(
      name: "NamiFileManager",
      dependencies: [
        .product(name: "Citadel", package: "Citadel"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOTLS", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
      ],
      path: "Sources/NamiFileManager",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CoreServices"),
        .linkedFramework("NetFS"),
        .linkedFramework("Network"),
        .linkedFramework("QuickLook"),
        .linkedFramework("QuickLookUI"),
        .linkedFramework("Security"),
      ]
    )
  ],
  swiftLanguageModes: [.v5]
)
