public enum ComposerReturn {
  public static func shouldSubmit(
    shifted: Bool, autoShifted: Bool, shiftLocked: Bool, available: Bool = true,
    markedText: Bool, suggestionsOpen: Bool, canSubmit: Bool
  ) -> Bool {
    available && shifted && !autoShifted && !shiftLocked && !markedText && !suggestionsOpen
      && canSubmit
  }
}
