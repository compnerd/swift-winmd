// swift-tools-version:5.3

import PackageDescription

let SwiftWinMD = Package(
  name: "SwiftWinMD",
  products: [
    .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
  ],
  dependencies: [
  ],
  targets: [
    .target(name: "CPE", dependencies: []),
    .target(name: "WinMD", dependencies: ["CPE"]),
    .target(name: "winmd-inspect", dependencies: ["WinMD"]),
  ]
)
