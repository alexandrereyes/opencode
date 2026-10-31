import Foundation
import OSLog

/// Startup phases without content: no SDP, addresses, sessions, transcripts or tokens.
enum VoiceLaunchLog {
  static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "VoiceStartup")
  /// `detail` (a user-facing message, never transcripts or credentials) only reaches the DEBUG file.
  /// `reason` is a diagnostic category such as `service_error code=invalid_request_error/…`, public in every build.
  static func record(_ phase: String, detail: String? = nil, reason: String? = nil) {
    if let reason {
      log.notice("phase=\(phase, privacy: .public) reason=\(reason, privacy: .public)")
    } else {
      log.notice("phase=\(phase, privacy: .public)")
    }
    #if DEBUG
    // Device verification reads this from the app container; os_log needs a privileged collector.
    let line = "\(Date.now.ISO8601Format(.iso8601.time(includingFractionalSeconds: true))) "
      + "\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(phase)\(reason.map { " reason=" + $0 } ?? "")"
      + "\(detail.map { " — " + $0 } ?? "")\n"
    guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appending(path: "voice-launch.log") else { return }
    if let handle = try? FileHandle(forWritingTo: url), (try? handle.seekToEnd()).map({ $0 < 262_144 }) == true {
      handle.write(Data(line.utf8)); try? handle.close()
    } else {
      try? Data(line.utf8).write(to: url, options: .atomic)
    }
    #endif
  }
}
