/// Relative ordering within this app, not APNs delivery priority. Keep agents in sync with the plugin's
/// `live-activity/lifecycle.ts` payload. Voice keeps priority through mute, interruption and network recovery.
public enum LiveActivityRelevance {
  public static let voice: Double = 100
  public static let agents: Double = 50
}
