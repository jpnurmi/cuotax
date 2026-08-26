// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CuotaX",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "CuotaX", targets: ["CuotaX"])
  ],
  targets: [
    .executableTarget(name: "CuotaX"),
    .testTarget(
      name: "CuotaXTests",
      dependencies: ["CuotaX"],
      path: "tests/CuotaXTests",
      resources: [.copy("Fixtures")]
    ),
  ]
)
