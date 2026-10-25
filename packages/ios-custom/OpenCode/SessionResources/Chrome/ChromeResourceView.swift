import OpenCodeKit
import SwiftUI

/// Chrome viewer (layout 4B): the shell's live frame and touch surface with a Safari-style address bar at the bottom
/// instead of side tools. The bar stays while Alexandre holds control and rises with the keyboard. The keyboard opens
/// by itself when the page focuses an editable field, with the field's traits: a password field gets secure entry and
/// the `.password` content type, so iOS offers saved passwords. Typed text goes straight to `insertText` and is never
/// logged.
struct ChromeResourceView: View {
  let model: ResourceViewerModel

  var body: some View {
    let state = ChromeViewerState(meta: model.meta)
    ResourceViewerShell(model: model, tools: { EmptyView() }) {
      ChromeAddressBar(model: model, state: state)
    }
    .onChange(of: model.inControl) { _, inControl in
      // The address bar holds Devolver and navigation, so it stays visible in control.
      if inControl { model.controlsVisible = true }
    }
    .onChange(of: state.focus) { _, focus in follow(focus) }
    .onChange(of: state.editTaps) { _, _ in follow(state.focus) }
  }

  private func follow(_ focus: ChromeFocus) {
    guard model.inControl else { return }
    if let field = focus.field { model.keyboardStyle = ResourceKeyboardStyle(ChromeKeyboard(field)) }
    model.keyboardVisible = focus.editable
  }
}

extension ResourceKeyboardStyle {
  init(_ keyboard: ChromeKeyboard) {
    let contentType: UITextContentType? =
      switch keyboard.contentType {
      case .none: nil
      case .password: .password
      case .username: .username
      case .email: .emailAddress
      case .url: .URL
      case .telephone: .telephoneNumber
      case .oneTimeCode: .oneTimeCode
      }
    let type: UIKeyboardType =
      switch keyboard.keyboard {
      case .standard: .default
      case .email: .emailAddress
      case .url: .URL
      case .numbers: .numbersAndPunctuation
      case .webSearch: .webSearch
      }
    self.init(contentType: contentType, keyboard: type, secure: keyboard.secure, returnKey: .go)
  }
}

/// Chrome glyph, the address (tap to edit in control; Return navigates) and reload; below it back, forward, the
/// control action and a menu. While the page keyboard is up only the address row stays, with **Devolver**.
struct ChromeAddressBar: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  let model: ResourceViewerModel
  let state: ChromeViewerState
  @State private var address = ""
  @State private var selection: TextSelection?
  @FocusState private var editingAddress: Bool

  private var inControl: Bool { model.inControl }
  private var compact: Bool { inControl && (model.keyboardVisible || editingAddress) }

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "globe").font(.system(size: 20, weight: .medium))
          .foregroundStyle(theme.color(.icon)).frame(width: 30, height: 30).accessibilityHidden(true)
        addressField
        if compact {
          Button("Devolver") { giveBack() }.appFont(.body, weight: .semibold)
            .foregroundStyle(theme.color(.primary)).accessibilityIdentifier("chrome-give-back-inline")
        }
      }
      if !compact {
        HStack(spacing: 10) {
          circle("chevron.backward", label: "Voltar", id: "chrome-back", enabled: inControl && state.canGoBack) {
            model.send([.navigate("back")])
          }
          circle("chevron.forward", label: "Avançar", id: "chrome-forward", enabled: inControl && state.canGoForward) {
            model.send([.navigate("forward")])
          }
          controlButton
          menu
        }
      }
    }
    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, compact ? 8 : 6)
    .frame(maxWidth: .infinity)
    .background {
      // An opaque theme surface: the page behind can have any color and the bar must stay legible in both themes.
      let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 28, topTrailing: 28))
      shape.fill(theme.color(.surface))
        .overlay { shape.strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
        .ignoresSafeArea(edges: .bottom)
    }
    .animation(.snappy(duration: 0.25), value: compact)
    .onChange(of: editingAddress) { _, editing in
      guard editing else { return }
      // The address keyboard replaces the page keyboard until Return.
      model.keyboardVisible = false
      // Like Safari: the whole address is selected, so typing replaces it.
      address = state.url
      selection = TextSelection(range: address.startIndex..<address.endIndex)
    }
  }

  private func giveBack() {
    editingAddress = false
    Task { await model.giveBack() }
  }

  private var addressField: some View {
    HStack(spacing: 6) {
      if !editingAddress, state.isSecure {
        Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold))
          .foregroundStyle(theme.color(.textSecondary)).accessibilityLabel("Conexão segura")
      }
      TextField("Endereço", text: editingAddress ? $address : .constant(state.displayAddress), selection: $selection)
        .focused($editingAddress)
        .disabled(!inControl)
        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        .submitLabel(.go)
        .multilineTextAlignment(editingAddress ? .leading : .center)
        .appFont(.body).foregroundStyle(theme.color(.text))
        .onSubmit {
          let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
          if !typed.isEmpty { model.send([.navigate("url", url: typed)]) }
          editingAddress = false
        }
        .accessibilityIdentifier("chrome-address")
      if !editingAddress {
        Button {
          model.send([.navigate("reload")])
        } label: {
          Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
            .frame(width: 32, height: 32).contentShape(.rect)
        }
        .buttonStyle(.plain).foregroundStyle(theme.color(inControl ? .icon : .textWeak)).disabled(!inControl)
        .accessibilityLabel("Recarregar").accessibilityIdentifier("chrome-reload")
      }
    }
    .padding(.leading, 14).padding(.trailing, 6).frame(height: 44)
    .background(theme.color(.surfaceRaised), in: .capsule)
    .overlay { Capsule().strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
  }

  private var controlButton: some View {
    Button {
      if inControl { giveBack() } else { Task { await model.takeControl() } }
    } label: {
      Label(inControl ? "Devolver" : "Assumir controle", systemImage: inControl ? "hand.raised.slash" : "hand.raised.fill")
        .appFont(.body, weight: .semibold).lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity).frame(height: 48)
        .foregroundStyle(theme.color(inControl ? .text : .onPrimary))
        .background(inControl ? theme.color(.surfaceRaised) : theme.color(.primary), in: .capsule)
        .overlay {
          if inControl { Capsule().strokeBorder(theme.color(.borderStrong), lineWidth: 1 / displayScale) }
        }
    }
    .buttonStyle(.plain)
    .disabled(model.busy || (!inControl && (model.holder == .elsewhere || !model.resource.state.running)))
    .accessibilityIdentifier(inControl ? "resource-give-back" : "resource-take")
  }

  private var menu: some View {
    Menu {
      if inControl {
        Button("Mostrar teclado", systemImage: "keyboard") { model.keyboardVisible = true }
      }
      if state.tabs.count > 1 {
        Section("Abas") {
          ForEach(state.tabs) { tab in
            Button {
              model.send([.selectTab(tab.id)])
            } label: {
              Label(tab.title.isEmpty ? ChromeViewerState.displayAddress(tab.url) : tab.title,
                    systemImage: tab.id == state.targetID ? "checkmark" : "square.on.square")
            }.disabled(!inControl)
          }
        }
      }
      Button("Copiar endereço", systemImage: "doc.on.doc") { UIPasteboard.general.string = state.url }
        .disabled(state.url.isEmpty)
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
        .frame(width: 48, height: 48).contentShape(.circle)
    }
    .foregroundStyle(theme.color(.icon))
    .background(theme.color(.surfaceRaised), in: .circle)
    .accessibilityLabel("Mais").accessibilityIdentifier("chrome-more")
  }

  private func circle(_ symbol: String, label: String, id: String, enabled: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
        .frame(width: 48, height: 48).contentShape(.circle)
    }
    .buttonStyle(.plain).foregroundStyle(theme.color(enabled ? .icon : .textWeak))
    .background(theme.color(.surfaceRaised), in: .circle).disabled(!enabled)
    .accessibilityLabel(label).accessibilityIdentifier(id)
  }
}
