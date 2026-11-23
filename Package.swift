// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Ferry",
  defaultLocalization: "zh-Hans",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Ferry", targets: ["FerryApp"])],
  targets: [
    .target(name: "FerryCore", resources: [.process("Resources")]),
    .executableTarget(name: "FerryApp", dependencies: ["FerryCore"]),
    .testTarget(name: "FerryCoreTests", dependencies: ["FerryCore"]),
    .testTarget(name: "FerryAppTests", dependencies: ["FerryApp", "FerryCore"]),
  ]
)
