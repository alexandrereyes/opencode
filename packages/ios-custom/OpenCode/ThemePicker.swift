import OpenCodeKit
import SwiftUI

/// Você → Aparência → Tema on the iPhone and the Aparência tab of the Mac's Ajustes: the 38 families with a
/// preview of their colors.
struct ThemePicker: View {
  @Environment(\.appTheme) private var theme
  @Bindable var settings: AppearanceSettings
  var body: some View {
    List {
      ForEach(AppTheme.families) { family in
        Button {
          settings.family = family.id
          Haptics.play(.selection)
        } label: {
          HStack(spacing: 14) {
            ThemePreview(theme: AppTheme.load(theme.dark ? family.dark : family.light))
            Text(family.name).foregroundStyle(theme.color(.textStrong))
            Spacer()
            if currentFamily == family.id {
              Image(systemName: "checkmark").foregroundStyle(theme.color(.primary))
            }
          }.padding(.vertical, 5).contentShape(Rectangle())
        }.accessibilityIdentifier("theme-" + family.id)
          .accessibilityAddTraits(currentFamily == family.id ? .isSelected : [])
      }.listRowBackground(theme.color(.surface))
    }
    #if os(iOS)
    .settingsList(theme).navigationTitle("Temas").navigationBarTitleDisplayMode(.inline)
    #else
    .buttonStyle(.plain).scrollContentBackground(.hidden).background(theme.color(.background))
    #endif
  }
  private var currentFamily: String {
    guard let override = settings.override else { return settings.family }
    return AppTheme.families.first { $0.dark == override || $0.light == override }?.id ?? "openchamber"
  }
}

private struct ThemePreview: View {
  let theme: AppTheme
  var body: some View {
    HStack(spacing: 3) {
      ForEach([ThemeRole.primary, .accent, .success, .textStrong], id: \.self) { role in
        Capsule().fill(theme.color(role)).frame(width: 7, height: role == .textStrong ? 14 : 22)
      }
    }.padding(8).background(theme.color(.background), in: RoundedRectangle(cornerRadius: 9))
      .overlay { RoundedRectangle(cornerRadius: 9).stroke(theme.color(.border)) }
      .accessibilityHidden(true)
  }
}
