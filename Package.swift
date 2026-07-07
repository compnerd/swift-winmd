// swift-tools-version: 6.4

import PackageDescription

let _ =
    Package(name: "SwiftWinMD",
            platforms: [
              .macOS(.v26),
            ],
            products: [
              .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
              .library(name: "SQLEngine", targets: ["SQLEngine"]),
              .library(name: "WinMDSynthesis", targets: ["WinMDSynthesis"]),
            ],
            dependencies: [
              .package(url: "https://github.com/apple/swift-argument-parser",
                       from: "1.5.0"),
              .package(url: "https://github.com/hummingbird-project/swift-mustache",
                       from: "2.0.0"),
            ],
            targets: [
              .target(name: "CPE", dependencies: []),

              // SQLEngine
              .target(name: "SQLEngine", dependencies: [],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .target(name: "SQLTestSupport", dependencies: ["SQLEngine"],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .testTarget(name: "SQLTests",
                          dependencies: ["SQLEngine", "SQLTestSupport"],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),

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

              // WinMDSynthesis
              .target(name: "WinMDSynthesis",
                      dependencies: [
                        "WinMD",
                      ]),
              .testTarget(name: "WinMDSynthesisTests",
                          dependencies: ["WinMDSynthesis"]),

              // winmd-inspect
              .executableTarget(name: "winmd-inspect",
                                dependencies: [
                                  "SQLEngine",
                                  "WinMD",
                                  "WinMDSynthesis",
                                  .product(name: "ArgumentParser",
                                           package: "swift-argument-parser"),
                                  .product(name: "Mustache",
                                           package: "swift-mustache"),
                                ],
                                resources: [
                                  .copy("Resources"),
                                ],
                                swiftSettings: [
                                  .enableExperimentalFeature("Lifetimes"),
                                  .enableUpcomingFeature(
                                      "InternalImportsByDefault"),
                                ]),
              .testTarget(name: "winmd-inspectTests",
                          dependencies: [
                            "winmd-inspect",
                            "SQLEngine",
                            "WinMD",
                            .product(name: "Mustache",
                                     package: "swift-mustache"),
                          ],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),
            ])
