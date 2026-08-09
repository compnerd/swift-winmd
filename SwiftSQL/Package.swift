// swift-tools-version: 6.4

import PackageDescription

let _ =
    Package(name: "SwiftSQL",
            platforms: [
              .macOS(.v26),
            ],
            products: [
              .library(name: "SQLEngine", targets: ["SQLEngine"]),
              .library(name: "SQLQuery", targets: ["SQLQuery"]),
              .library(name: "SQLStandard", targets: ["SQLStandard"]),
              .library(name: "SQLTestSupport", targets: ["SQLTestSupport"]),
            ],
            targets: [
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
              .testTarget(name: "SQLQueryTests",
                          dependencies: ["SQLEngine", "SQLQuery",
                                         "SQLStandard", "SQLTestSupport"],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),
            ])
