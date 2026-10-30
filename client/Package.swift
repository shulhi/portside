// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Portside",
  platforms: [.macOS("27.0")],
  products: [
    .library(name: "PortsideCore", targets: ["PortsideCore"]),
    .executable(name: "Portside", targets: ["Portside"]),
  ],
  targets: [
    .target(name: "PortsideCore"),
    .executableTarget(name: "Portside", dependencies: ["PortsideCore"]),
    .testTarget(name: "PortsideCoreTests", dependencies: ["PortsideCore"]),
  ]
)
