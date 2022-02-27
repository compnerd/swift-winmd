// swift-tools-version:5.3

import PackageDescription

let SwiftWinMD = Package(
  name: "SwiftWinMD",
  products: [
    .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
  ],
  dependencies: [
    .package(url: "http://github.com/apple/swift-argument-parser",
             .upToNextMinor(from: "1.0.0")),
    .package(url: "https://github.com/apple/swift-collections.git",
             .upToNextMinor(from: "1.0.0")),
  ],
  targets: [
    .target(name: "CPE", dependencies: []),

    // WinMD
    .target(name: "WinMD",
            dependencies: [
              "CPE",
              .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            swiftSettings: [
              .unsafeFlags([
                "-Xfrontend", "-validate-tbd-against-ir=none",
              ]),
            ]),
    .testTarget(name: "WinMDTests", dependencies: ["WinMD"]),

    // winmd-inspect
    .target(name: "winmd-inspect",
            dependencies: [
              "WinMD",
              .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
              .unsafeFlags([
                "-parse-as-library",
              ]),
            ]),
  ]
)
