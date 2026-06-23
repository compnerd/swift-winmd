// swift-tools-version: 6.4

import PackageDescription

let SwiftWinMD = Package(
  name: "SwiftWinMD",
  platforms: [
    .macOS(.v26),
  ],
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
            ],
            swiftSettings: [
              .enableExperimentalFeature("Lifetimes"),
            ]),
    .testTarget(name: "WinMDTests", dependencies: ["WinMD"],
            swiftSettings: [
              .enableExperimentalFeature("Lifetimes"),
            ]),

    // winmd-inspect
    .executableTarget(name: "winmd-inspect",
            dependencies: [
              "WinMD",
              .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
              .enableExperimentalFeature("Lifetimes"),
            ]),
  ]
)
