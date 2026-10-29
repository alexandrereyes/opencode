import SwiftUI

/// Every keyboard shortcut of the Mac app in one table. Menus and buttons bind theirs from here (`.shortcut(_:)`),
/// and Atalhos do teclado (⌘/) lists the table, so the sheet cannot drift from the menus. Entries without a `key`
/// are handled elsewhere (the editor, dictation, the ⌘K list, the system's Ajustes and sidebar items): update them
/// together with the code named in their comment.
struct MacShortcut: Identifiable {
  enum Group: String, CaseIterable, Identifiable {
    case general = "Geral", sessions = "Sessões", conversation = "Conversa", window = "Janela", image = "Imagem"
    var id: String { rawValue }
  }

  let group: Group
  let title: String
  /// Bound by `.shortcut(_:)`; `nil` when other code handles the keys.
  let key: KeyEquivalent?
  let modifiers: EventModifiers
  /// The keycaps shown; "…" is drawn as plain text between them.
  let caps: [String]
  var id: String { group.rawValue + "·" + title }

  init(_ group: Group, _ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command) {
    self.group = group
    self.title = title
    self.key = key
    self.modifiers = modifiers
    caps = Self.caps(modifiers) + [Self.cap(key)]
  }

  init(_ group: Group, _ title: String, caps: [String]) {
    self.group = group
    self.title = title
    key = nil
    modifiers = []
    self.caps = caps
  }

  // Geral
  static let search = MacShortcut(.general, "Buscar projetos e sessões", "k")
  static let newSession = MacShortcut(.general, "Nova sessão", "n")
  static let newWindow = MacShortcut(.general, "Nova janela", "n", [.option, .command])
  static let reload = MacShortcut(.general, "Atualizar sessões", "r")
  static let compose = MacShortcut(.general, "Escrever mensagem", "l")
  static let shortcuts = MacShortcut(.general, "Atalhos do teclado", "/")
  // The Settings scene's own item.
  static let settings = MacShortcut(.general, "Ajustes", caps: ["⌘", ","])
  // MacSearchPresentation: moveDown:/moveUp: in the ⌘K field.
  static let searchNext = MacShortcut(.general, "Busca: próximo resultado", caps: ["⌃", "N"])
  static let searchPrevious = MacShortcut(.general, "Busca: resultado anterior", caps: ["⌃", "P"])

  // Sessões (⌘1…⌘9 are bound per row in Ir ▸ Sessões da lista)
  static let numbered = MacShortcut(.sessions, "Abrir sessão 1–9", caps: ["⌘", "1", "…", "⌘", "9"])
  static let previous = MacShortcut(.sessions, "Sessão anterior", .upArrow, [.option, .command])
  static let next = MacShortcut(.sessions, "Próxima sessão", .downArrow, [.option, .command])
  static let back = MacShortcut(.sessions, "Voltar à sessão principal", "[")
  static let master = MacShortcut(.sessions, "Sessão mestra", "m", [.shift, .command])
  static let fromThis = MacShortcut(.sessions, "Nova sessão a partir desta", "n", [.shift, .command])
  static let rename = MacShortcut(.sessions, "Renomear sessão", "r", [.shift, .command])
  static let pin = MacShortcut(.sessions, "Fixar ou desafixar", "p", [.shift, .command])
  // Both confirm first; with sessions selected they act on the selection.
  static let archive = MacShortcut(.sessions, "Arquivar sessão", .delete, [.option, .command])
  static let delete = MacShortcut(.sessions, "Excluir sessão", .delete)
  static let selectAll = MacShortcut(.sessions, "Selecionar todas as sessões", "a", [.option, .command])

  // Conversa
  static let find = MacShortcut(.conversation, "Buscar na conversa", "f")
  static let model = MacShortcut(.conversation, "Trocar modelo e esforço", "m", [.option, .command])
  static let sideQuestion = MacShortcut(.conversation, "Pergunta paralela", "b", [.option, .command])
  // MacComposerText: Return sends, Shift+Return breaks the line, ⌃⌥Space dictates; MacDictationKey: right Option.
  static let send = MacShortcut(.conversation, "Enviar", caps: ["↩"])
  static let newline = MacShortcut(.conversation, "Nova linha", caps: ["⇧", "↩"])
  static let dictationKey = MacShortcut(.conversation, "Ditado", caps: ["⌥", "direito"])
  static let dictationEditor = MacShortcut(.conversation, "Ditado no editor", caps: ["⌃", "⌥", "Espaço"])
  static let createSession = MacShortcut(.conversation, "Enviar em Nova sessão", .return)

  // Janela
  static let context = MacShortcut(.window, "Mostrar ou ocultar Contexto", "i", [.option, .command])
  static let files = MacShortcut(.window, "Arquivos", "f", [.shift, .command])
  static let previousFile = MacShortcut(.window, "Arquivo anterior", .leftArrow, [.option, .command])
  static let nextFile = MacShortcut(.window, "Próximo arquivo", .rightArrow, [.option, .command])
  // NavigationSplitView's own sidebar command.
  static let sidebar = MacShortcut(.window, "Mostrar ou ocultar Sessões", caps: ["⌃", "⌘", "S"])
  static let proxy = MacShortcut(.window, "LLM proxy", "l", [.shift, .command])

  // Imagem: the image viewer's window. MacImageScrollView handles the zoom keys (⌘= too) and the arrows there,
  // ahead of the menus, so ⌘1 is Tamanho real in it.
  static let copyImage = MacShortcut(.image, "Copiar imagem", "c")
  static let zoomIn = MacShortcut(.image, "Ampliar", caps: ["⌘", "+"])
  static let zoomOut = MacShortcut(.image, "Reduzir", caps: ["⌘", "−"])
  static let zoomFit = MacShortcut(.image, "Ajustar à janela", caps: ["⌘", "0"])
  static let zoomActual = MacShortcut(.image, "Tamanho real", caps: ["⌘", "1"])
  static let panImage = MacShortcut(.image, "Mover a imagem", caps: ["←", "↑", "↓", "→"])

  static let all: [MacShortcut] = [
    search, newSession, newWindow, reload, compose, settings, shortcuts, searchNext, searchPrevious,
    numbered, previous, next, back, master, fromThis, rename, pin, archive, delete, selectAll,
    find, model, sideQuestion, send, newline, dictationKey, dictationEditor, createSession,
    context, files, previousFile, nextFile, sidebar, proxy,
    copyImage, zoomIn, zoomOut, zoomFit, zoomActual, panImage,
  ]

  private static func caps(_ modifiers: EventModifiers) -> [String] {
    [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { modifiers.contains($0.0) }.map(\.1)
  }

  private static func cap(_ key: KeyEquivalent) -> String {
    switch key {
    case .upArrow: "↑"
    case .downArrow: "↓"
    case .leftArrow: "←"
    case .rightArrow: "→"
    case .delete: "⌫"
    case .return: "↩"
    case .space: "Espaço"
    default: String(key.character).uppercased()
    }
  }
}

/// ⌘⌫ is also the text system's "delete to the start of the line": typed in an editable field (the composer, the
/// search), it edits the text instead of running the menu item that has it as its key equivalent.
@MainActor enum MacTextKeys {
  static func deleteToLineStart() -> Bool {
    guard NSApp.currentEvent?.type == .keyDown,
      let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable else { return false }
    text.deleteToBeginningOfLine(nil)
    return true
  }
}

extension View {
  /// Binds a table entry; `enabled` false (a menu's second copy) leaves it unbound.
  @ViewBuilder func shortcut(_ value: MacShortcut, enabled: Bool = true) -> some View {
    if enabled, let key = value.key { keyboardShortcut(key, modifiers: value.modifiers) } else { self }
  }
}

/// Atalhos do teclado (⌘/ or the keyboard in the project rail): the table above, searchable, grouped in columns.
/// It only lists; nothing is editable. Esc, Fechar or a click outside closes it.
struct MacShortcutsSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Atalhos do teclado").font(.title3.bold()).foregroundStyle(theme.color(.textStrong))
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
            .background(theme.color(.surface), in: Circle())
            .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 0.7) }
        }
        .buttonStyle(.plain).foregroundStyle(theme.color(.text))
        .keyboardShortcut(.cancelAction).help("Fechar").accessibilityLabel("Fechar")
      }
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textSecondary))
        TextField("Buscar atalho", text: $query).textFieldStyle(.plain)
      }
      .padding(.horizontal, 12).frame(height: 32)
      .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      HStack(alignment: .top, spacing: 0) {
        column([.general, .image])
        divider
        column([.sessions])
        divider
        column([.conversation, .window])
      }
    }
    .padding(22)
    .frame(width: 820)
    .frame(minHeight: 440, alignment: .top)
    .background(theme.color(.background))
  }

  private var divider: some View {
    Rectangle().fill(theme.color(.border)).frame(width: 0.7).padding(.horizontal, 16)
  }

  private func column(_ groups: [MacShortcut.Group]) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      ForEach(groups) { group in
        let rows = MacShortcut.all.filter { $0.group == group && matches($0) }
        if !rows.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            Text(group.rawValue.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9)
              .foregroundStyle(theme.color(.textSecondary)).padding(.bottom, 8)
            ForEach(rows) { row in
              HStack(spacing: 8) {
                Text(row.title).appFont(.caption).foregroundStyle(theme.color(.text)).lineLimit(1)
                Spacer(minLength: 8)
                caps(row.caps)
              }
              .padding(.vertical, 7)
              .overlay(alignment: .bottom) { Rectangle().fill(theme.color(.border)).frame(height: 0.5) }
              .accessibilityElement(children: .combine)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func caps(_ values: [String]) -> some View {
    HStack(spacing: 4) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        if value == "…" {
          Text(value).foregroundStyle(theme.color(.textSecondary))
        } else {
          Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.color(.text))
            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
            .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color(.border), lineWidth: 0.7) }
        }
      }
    }
    .fixedSize()
  }

  private func matches(_ shortcut: MacShortcut) -> Bool {
    let text = query.trimmingCharacters(in: .whitespaces)
    return text.isEmpty || shortcut.title.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      || shortcut.caps.joined().range(of: text, options: .caseInsensitive) != nil
  }
}
