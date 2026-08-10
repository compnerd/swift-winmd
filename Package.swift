// swift-tools-version: 6.4

import PackageDescription

let _ =
    Package(name: "SwiftWinMD",
            platforms: [
              .macOS(.v26),
            ],
            products: [
              .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
              .library(name: "WinMDSynthesis", targets: ["WinMDSynthesis"]),
              .library(name: "SQLEngineWinMD", targets: ["SQLEngineWinMD"]),
              .library(name: "Decant", targets: ["Decant"]),
            ],
            dependencies: [
              // The SQL engine, standard-prelude overlay, LINQ query builder,
              // and their test support now live in the nested SwiftSQL package
              // (a local path dependency so a clone still builds); a later step
              // splits SwiftSQL into its own repository.
              .package(path: "SwiftSQL"),
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

              // SQLEngineWinMD
              .target(name: "SQLEngineWinMD",
                      dependencies: [
                        "WinMD",
                        "WinMDSynthesis",
                        .product(name: "SQLEngine", package: "SwiftSQL"),
                        .product(name: "SQLStandard", package: "SwiftSQL"),
                      ],
                      resources: [
                        .copy("Resources"),
                      ],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                        .enableUpcomingFeature("InternalImportsByDefault"),
                      ]),
              .testTarget(name: "SQLEngineWinMDTests",
                          dependencies: [
                            "SQLEngineWinMD",
                            .product(name: "SQLEngine", package: "SwiftSQL"),
                            .product(name: "SQLStandard", package: "SwiftSQL"),
                            "WinMD",
                            "WinMDSynthesis",
                            .product(name: "Mustache",
                                     package: "swift-mustache"),
                          ],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),

              // winmd-inspect
              .executableTarget(name: "winmd-inspect",
                                dependencies: [
                                  "SQLEngineWinMD",
                                  .product(name: "SQLEngine",
                                           package: "SwiftSQL"),
                                  .product(name: "SQLShell",
                                           package: "SwiftSQL"),
                                  .product(name: "SQLStandard",
                                           package: "SwiftSQL"),
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
                            "SQLEngineWinMD",
                            .product(name: "SQLEngine", package: "SwiftSQL"),
                            .product(name: "SQLShell", package: "SwiftSQL"),
                            .product(name: "SQLStandard", package: "SwiftSQL"),
                            "WinMD",
                            .product(name: "Mustache",
                                     package: "swift-mustache"),
                          ],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),
            ])
