import OpenCodeKit
import SwiftUI

struct ConversationMCPPill: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @ScaledMetric(relativeTo: .caption) private var height = 30.0
  let store: ConversationMCPStore
  var body: some View {
    Button {
      if store.isOpen { store.close() } else { store.open() }
    } label: {
      HStack(spacing: 5) {
        Circle().fill(theme.color(store.summary.connected > 0 ? .success : .textWeak))
          .frame(width: 7, height: 7)
        Text(store.summary.label).appFont(.footnote).monospacedDigit()
        Image(systemName: store.isOpen ? "chevron.up" : "chevron.down")
          .appSymbol(.disclosure)
      }.foregroundStyle(theme.color(.glassSecondary)).padding(.horizontal, 8).frame(minHeight: height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay { Capsule().strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
    }.buttonStyle(.plain).fixedSize().accessibilityLabel(store.summary.accessibilityLabel)
      .accessibilityHint(store.isOpen ? "Fechar painel de MCPs" : "Abrir painel de MCPs")
      .accessibilityIdentifier("conversation-mcp-pill")
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.pillFrame = $0 }
  }
}

struct MCPComposerAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

struct ConversationMCPOverlay: ViewModifier {
  let store: ConversationMCPStore
  func body(content: Content) -> some View {
    content.simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { value in
      if store.isOpen && !store.panelFrame.contains(value.location)
        && !store.transcriptFrame.contains(value.location)
        && !store.pillFrame.contains(value.location) { store.close() }
    }).overlayPreferenceValue(MCPComposerAnchorKey.self) { composer in
      GeometryReader { geometry in
        if store.isOpen, let composer {
          let frame = geometry[composer]
          ConversationMCPPanel(store: store)
            .frame(width: max(0, geometry.size.width - 40))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, geometry.size.height - frame.minY + 8)
            .padding(.horizontal, 20)
        }
      }
    }
  }
}

struct ConversationMCPPanel: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  let store: ConversationMCPStore
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("MCPs").appFont(.secondary, weight: .medium)
        .foregroundStyle(theme.color(.glassSecondary)).accessibilityAddTraits(.isHeader)
      if store.loading {
        ProgressView("Carregando MCPs…").font(.caption).tint(theme.color(.textSecondary))
      }
      if store.failed && !store.loading {
        Button("Não foi possível carregar · Tentar novamente") { Task { await store.refresh() } }
          .font(.caption).foregroundStyle(theme.color(.textSecondary))
      }
      MCPFlowLayout(spacing: 7, centered: false) {
        ForEach(store.chips) { server in
          MCPChip(server: server, preview: false) { Task { await store.toggle(server) } }
        }
      }
    }.padding(13).glassEffect(.regular, in: .rect(cornerRadius: 18))
      .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
      .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
      .accessibilityIdentifier("conversation-mcp-panel")
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.panelFrame = $0 }
      .accessibilityAction(.escape) { store.close() }
      .task { await store.refresh() }
  }
}
