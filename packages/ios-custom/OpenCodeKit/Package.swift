// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OpenCodeKit",
  platforms: [.iOS("27.0"), .macOS(.v15)],
  products: [.library(name: "OpenCodeKit", targets: ["OpenCodeKit"])],
  dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.7.3")],
  targets: [
    .target(
      name: "OpenCodeKit", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
    .testTarget(
      name: "OpenCodeKitTests", dependencies: ["OpenCodeKit"],
      resources: [
        .copy("Fixtures/Conversation"),
        .process("Fixtures/active.json"), .process("Fixtures/forms.json"),
        .process("Fixtures/navigation.json"), .process("Fixtures/permissions.json"),
        .process("Fixtures/preferences.json"), .process("Fixtures/projects.json"),
        .process("Fixtures/sessions.json"), .process("Fixtures/subscriptions.json"),
        .process("Fixtures/transcript-image.json"), .process("Fixtures/transcript-running.json"),
        .process("Fixtures/transcript-user.json"), .process("Fixtures/unknown-message.json"),
      ]),
  ],
  swiftLanguageModes: [.v6]
)
