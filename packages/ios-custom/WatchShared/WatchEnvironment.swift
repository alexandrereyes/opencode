import Foundation
import OpenCodeKit

/// The APNs environment of this bundle (the app or the complication extension), from its own signing profile:
/// development-signed builds (installed from Xcode) use the sandbox; TestFlight builds, with no embedded profile,
/// production. Same rule as the iPhone's Live Activity registration.
enum WatchEnvironment {
  static var push: PushEnvironment {
    #if targetEnvironment(simulator)
      PushEnvironment.resolve(profile: nil, simulator: true)
    #else
      PushEnvironment.resolve(
        profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
          .flatMap { try? Data(contentsOf: $0) }, simulator: false)
    #endif
  }
}
