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
              .library(name: "SQLQuery", targets: ["SQLQuery"]),
              .library(name: "SQLStandard", targets: ["SQLStandard"]),
              .library(name: "WinMDSynthesis", targets: ["WinMDSynthesis"]),
              .library(name: "Decant", targets: ["Decant"]),
            ],
            dependencies: [
              .package(url: "https://github.com/apple/swift-argument-parser",
                       from: "1.5.0"),
              .package(url: "https://github.com/hummingbird-project/swift-mustache",
                       from: "2.0.0"),
            ],
            targets: [
              .target(name: "CPE", dependencies: []),

              .target(name: "Decant", dependencies: [],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .testTarget(name: "DecantTests", dependencies: ["Decant"],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),

              // SQLEngine
              .target(name: "SQLEngine", dependencies: [],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .target(name: "SQLStandard", dependencies: ["SQLEngine"],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .target(name: "SQLQuery", dependencies: ["SQLEngine"],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .testTarget(name: "SQLQueryTests",
                          dependencies: ["SQLEngine", "SQLQuery",
                                         "SQLStandard", "SQLTestSupport"],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),
              .target(name: "SQLTestSupport",
                      dependencies: ["SQLEngine", "SQLStandard"],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .testTarget(name: "SQLTests",
                          dependencies: ["SQLEngine", "SQLStandard",
                                         "SQLTestSupport"],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),
              .testTarget(name: "SQLStandardTests",
                          dependencies: ["SQLEngine", "SQLStandard",
                                         "SQLTestSupport"],
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
                                  "SQLStandard",
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
                            "SQLStandard",
                            "WinMD",
                            .product(name: "Mustache",
                                     package: "swift-mustache"),
                          ],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),
            ])
