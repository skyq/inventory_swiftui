// swift-tools-version: 6.0
import PackageDescription

let strictSettings: [SwiftSetting] = [
  .unsafeFlags(["-warnings-as-errors"]),
  .swiftLanguageMode(.v6),
]

let package = Package(
  name: "Inventory",
  defaultLocalization: "ru",
  platforms: [.macOS(.v12)],
  products: [
    .library(name: "InventoryCore", targets: ["InventoryCore"]),
    .library(name: "InventoryPlatform", targets: ["InventoryPlatform"]),
    .library(name: "InventoryUI", targets: ["InventoryUI"]),
    .executable(name: "InventoryApp", targets: ["InventoryApp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
  ],
  targets: [
    .target(
      name: "InventoryCore",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      path: "Sources/InventoryCore",
      swiftSettings: strictSettings
    ),
    .target(
      name: "InventoryPlatform",
      dependencies: ["InventoryCore"],
      path: "Sources/InventoryPlatform",
      swiftSettings: strictSettings
    ),
    .target(
      name: "InventoryUI",
      dependencies: ["InventoryCore"],
      path: "Sources/InventoryUI",
      resources: [.process("Resources")],
      swiftSettings: strictSettings
    ),
    .executableTarget(
      name: "InventoryApp",
      dependencies: ["InventoryCore", "InventoryPlatform", "InventoryUI"],
      path: "Sources/InventoryApp",
      swiftSettings: strictSettings
    ),
    .executableTarget(
      name: "InventoryFixture",
      dependencies: [
        "InventoryCore",
        "InventoryPlatform",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Sources/InventoryFixture",
      swiftSettings: strictSettings
    ),
    .testTarget(
      name: "InventoryCoreTests",
      dependencies: [
        "InventoryCore",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      path: "Tests/InventoryCoreTests",
      swiftSettings: strictSettings
    ),
    .testTarget(
      name: "InventoryPlatformTests",
      dependencies: ["InventoryCore", "InventoryPlatform"],
      path: "Tests/InventoryPlatformTests",
      swiftSettings: strictSettings
    ),
    .testTarget(
      name: "InventoryUITests",
      dependencies: ["InventoryCore", "InventoryUI"],
      path: "Tests/InventoryUITests",
      swiftSettings: strictSettings
    ),
  ]
)
