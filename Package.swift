// swift-tools-version: 6.4

import PackageDescription

let SwiftWinMD = Package(
  name: "SwiftWinMD",
  products: [
    .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser",
             from: "1.5.0"),
  ],
  targets: [
    .target(name: "CPE", dependencies: []),

    // WinMD
    .target(name: "WinMD",
            dependencies: [
              "CPE",
            ]),
    .testTarget(name: "WinMDTests", dependencies: ["WinMD"]),

    // winmd-inspect
    .executableTarget(name: "winmd-inspect",
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
