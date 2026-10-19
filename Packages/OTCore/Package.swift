// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OTCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OTCore", targets: ["OTCore"]),
    ],
    targets: [
        .target(name: "OTModels"),
        .target(name: "OTLedger", dependencies: ["OTModels"]),
        .target(name: "OTTracking", dependencies: ["OTModels", "OTLedger"]),
        .target(name: "OTZip"),
        .target(name: "OTXLSX", dependencies: ["OTZip"]),
        .target(name: "OTCSV"),
        .target(name: "OTExchange", dependencies: ["OTModels", "OTLedger", "OTXLSX", "OTCSV"]),
        .target(name: "OTCore", dependencies: ["OTModels", "OTLedger", "OTTracking", "OTZip", "OTXLSX", "OTCSV", "OTExchange"]),

        .testTarget(name: "OTModelsTests", dependencies: ["OTModels"]),
        .testTarget(name: "OTLedgerTests", dependencies: ["OTLedger", "OTModels"]),
        .testTarget(name: "OTTrackingTests", dependencies: ["OTTracking", "OTLedger", "OTModels"]),
        .testTarget(name: "OTZipTests", dependencies: ["OTZip"]),
        .testTarget(name: "OTXLSXTests", dependencies: ["OTXLSX", "OTZip"]),
        .testTarget(name: "OTCSVTests", dependencies: ["OTCSV"]),
        .testTarget(name: "OTExchangeTests", dependencies: ["OTExchange", "OTLedger", "OTModels", "OTXLSX", "OTCSV"]),
    ]
)
