// swift-tools-version: 6.4

import PackageDescription
import CompilerPluginSupport

let _ =
    Package(name: "SwiftWinMD",
            platforms: [
              .macOS(.v26),
            ],
            products: [
              .executable(name: "winmd-inspect", targets: ["winmd-inspect"]),
              .library(name: "SQL", targets: ["SQL"]),
              .library(name: "SQLEngine", targets: ["SQLEngine"]),
              .library(name: "SQLStandard", targets: ["SQLStandard"]),
              .library(name: "WinMDSynthesis", targets: ["WinMDSynthesis"]),
              .library(name: "Decant", targets: ["Decant"]),
              .library(name: "DecantMacros", targets: ["DecantMacros"]),
              .library(name: "DecantJSON", targets: ["DecantJSON"]),
            ],
            dependencies: [
              .package(url: "https://github.com/apple/swift-argument-parser",
                       from: "1.5.0"),
              .package(url: "https://github.com/hummingbird-project/swift-mustache",
                       from: "2.0.0"),
              .package(url: "https://github.com/swiftlang/swift-syntax.git",
                       branch: "main"),
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

              .macro(name: "DecantMacrosPlugin",
                     dependencies: [
                       .product(name: "SwiftSyntax",
                                package: "swift-syntax"),
                       .product(name: "SwiftSyntaxBuilder",
                                package: "swift-syntax"),
                       .product(name: "SwiftSyntaxMacros",
                                package: "swift-syntax"),
                       .product(name: "SwiftDiagnostics",
                                package: "swift-syntax"),
                       .product(name: "SwiftCompilerPlugin",
                                package: "swift-syntax"),
                     ]),
              .target(name: "DecantMacros",
                      dependencies: ["Decant", "DecantMacrosPlugin"],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .testTarget(name: "DecantMacrosTests",
                          dependencies: [
                            "DecantMacrosPlugin",
                            .product(name: "SwiftSyntaxMacroExpansion",
                                     package: "swift-syntax"),
                            .product(name: "SwiftSyntaxMacrosGenericTestSupport",
                                     package: "swift-syntax"),
                          ],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),

              .target(name: "DecantJSON", dependencies: ["Decant"],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .testTarget(name: "DecantJSONTests",
                          dependencies: [
                            "Decant", "DecantMacros", "DecantJSON",
                          ],
                          swiftSettings: [
                            .enableExperimentalFeature("Lifetimes"),
                          ]),

              // Throwaway benchmark harness (DecantJSON vs Foundation Codable).
              .executableTarget(name: "decant-bench",
                                dependencies: [
                                  "Decant", "DecantMacros", "DecantJSON",
                                ],
                                swiftSettings: [
                                  .enableExperimentalFeature("Lifetimes"),
                                ]),
              .executableTarget(name: "decant-size-decant",
                                dependencies: [
                                  "Decant", "DecantMacros", "DecantJSON",
                                ],
                                swiftSettings: [
                                  .enableExperimentalFeature("Lifetimes"),
                                ]),
              .executableTarget(name: "decant-size-codable",
                                dependencies: []),

              // SQLEngine
              .target(name: "SQLEngine", dependencies: [],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .target(name: "SQLStandard", dependencies: ["SQLEngine"],
                      swiftSettings: [
                        .enableExperimentalFeature("Lifetimes"),
                      ]),
              .target(name: "SQL",
                      dependencies: ["SQLEngine", "SQLStandard"],
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
