public enum ComposerReturn {
  public static func shouldSubmit(
    shifted: Bool, autoShifted: Bool, shiftLocked: Bool, available: Bool = true,
    markedText: Bool, suggestionsOpen: Bool, canSubmit: Bool
  ) -> Bool {
    available && shifted && !autoShifted && !shiftLocked && !markedText && !suggestionsOpen
      && canSubmit
  }
  /// Return picks the suggestion panel's first (highlighted) item, like Enter on the web, once that panel
  /// shows results for the current query. While composing, loading or empty, Return keeps its usual meaning.
  public static func selectsSuggestion(markedText: Bool, suggestionsOpen: Bool, firstItemReady: Bool) -> Bool {
    !markedText && suggestionsOpen && firstItemReady
  }
}
