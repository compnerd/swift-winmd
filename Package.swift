// swift-tools-version:5.3

import PackageDescription

let SwiftWinUI = Package(
  name: "SwiftWinUI",
  products: [
    .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
  ],
  dependencies: [
  ],
  targets: [
    .target(name: "WinMD", dependencies: []),
    .target(name: "winmd-inspect", dependencies: ["WinMD"]),
  ]
)
