// swift-tools-version:5.3

import Foundation
import PackageDescription

let SwiftSyntaxRequirement: Package.Dependency.Requirement
if let branch = ProcessInfo.processInfo.environment["SWIFT_SYNTAX_BRANCH"] {
    SwiftSyntaxRequirement = .branch(branch)
} else {
    SwiftSyntaxRequirement = .branch("main")
}

let SwiftWinMD = Package(
  name: "SwiftWinMD",
  products: [
    .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
  ],
  dependencies: [
    .package(url: "http://github.com/apple/swift-argument-parser",
             .upToNextMinor(from: "1.0.0")),
    .package(url: "http://github.com/apple/swift-syntax",
             SwiftSyntaxRequirement),
  ],
  targets: [
    .target(name: "CPE", dependencies: []),

    // WinMD
    .target(name: "WinMD",
            dependencies: [
              "CPE",
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
              .product(name: "SwiftSyntax", package: "swift-syntax"),
              .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            swiftSettings: [
              .unsafeFlags([
                "-parse-as-library",
              ]),
            ]),
  ]
)
