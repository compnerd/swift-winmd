// swift-tools-version:5.3
import PackageDescription

let SwiftWinMD = Package(
  name: "SwiftWinMD",
  products: [
    .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
  ],
  dependencies: [
    .package(url: "http://github.com/apple/swift-argument-parser", from: "0.3.2"),
  ],
  targets: [
    .target(name: "CPE", dependencies: []),
    .target(name: "WinMD", dependencies: [
      .target(name: "CPE")
    ]),
    .target(
      name: "winmd-inspect",
      dependencies: [
        .target(name: "WinMD"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
  ]
)
