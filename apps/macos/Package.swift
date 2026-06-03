// swift-tools-version:5.9
import PackageDescription

// Native macOS app for Philips WiZ lights. `WizKit` is the engine layer: it runs
// the shared, tested wiz-light-core logic (colour maths + light-state model) inside
// JavaScriptCore, and adds the UDP transport, discovery, and persistence in
// Swift. `WizApp` is the SwiftUI/AppKit menu-bar app on top of it. No third-party
// Swift dependencies — Apple frameworks only.
let package = Package(
  name: "WizLightController",
  platforms: [.macOS(.v13)],
  targets: [
    .target(
      name: "WizKit",
      resources: [.copy("Resources/wiz-core.global.js")]
    ),
    .executableTarget(
      name: "WizApp",
      dependencies: ["WizKit"]
    ),
    .testTarget(
      name: "WizKitTests",
      dependencies: ["WizKit"]
    ),
  ]
)
