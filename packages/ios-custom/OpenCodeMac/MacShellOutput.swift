import AppKit
import OpenCodeKit
import SwiftUI

/// A background task's output (`/api/shell/:id/output`), read by cursor while it grows and kept to its last
/// 256 KB, in its own window: the command, its state, Parar and Copiar. Opened from Tarefas in Contexto, where
/// the iPhone reveals the task's tool in the conversation.
struct MacShellOutputWindow: View {
  static let id = "shell-output"
  struct Target: Codable, Hashable {
    let shellID: String
    let directory: String
    let command: String
  }

  @Environment(\.appTheme) private var theme
  let target: Target
  let runtime: MacRuntime
  @State private var log = ShellOutputLog()
  @State private var running = true
  @State private var failure: String?
  @State private var stopping = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: running ? "play" : "stop").font(.system(size: 13)).foregroundStyle(theme.color(.icon))
        VStack(alignment: .leading, spacing: 2) {
          Text(target.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.color(.textStrong))
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          Text(status).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        }
        Spacer()
        Button("Copiar") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(log.text, forType: .string)
        }
        .disabled(log.text.isEmpty)
        if running {
          Button("Parar", role: .destructive) { Task { await stop() } }.disabled(stopping)
        }
      }
      .padding(12)
      ContextHairline()
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if log.clipped {
              Text("… saída anterior omitida").appFont(.caption).foregroundStyle(theme.color(.textWeak)).padding(.bottom, 6)
            }
            Text(log.text.isEmpty ? (failure ?? "Sem saída ainda.") : log.text)
              .font(.system(size: 11.5, design: .monospaced))
              .foregroundStyle(theme.color(log.text.isEmpty ? .textSecondary : .codeText))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(height: 1).id("end")
          }
          .padding(12)
        }
        .background(theme.color(.codeSurface))
        // Follows the end as the output grows, like a terminal.
        .onChange(of: log.cursor) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
      }
    }
    .frame(minWidth: 480, minHeight: 300)
    .background(theme.color(.background))
    .navigationTitle(target.command)
    .task(id: target) { await follow() }
  }

  private var status: String {
    ([running ? "rodando" : "encerrado"] + (log.cursor > 0 ? [log.cursor.formatted(.byteCount(style: .file))] : []))
      .joined(separator: " · ")
  }

  private func follow() async {
    guard let client = runtime.store?.client else { return }
    do {
      // The end first: a long-running server's output starts near its tail.
      let size = try await client.shellOutput(target.shellID, directory: target.directory, cursor: Int.max / 2).size
      log.start(size: size)
    } catch {
      failure = "Saída indisponível. \(error.localizedDescription)"
      return
    }
    while !Task.isCancelled {
      do {
        // The state first: a task that just ended still has its last output read below.
        running = (try? await client.shells(directory: target.directory))?.contains { $0.id == target.shellID } ?? running
        var chunk = try await client.shellOutput(target.shellID, directory: target.directory, cursor: log.cursor)
        while !chunk.output.isEmpty {
          log.append(chunk)
          chunk = try await client.shellOutput(target.shellID, directory: target.directory, cursor: log.cursor)
        }
        failure = nil
      } catch {
        failure = "Saída indisponível. \(error.localizedDescription)"
      }
      if !running { return }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func stop() async {
    guard let client = runtime.store?.client else { return }
    stopping = true
    defer { stopping = false }
    do {
      try await client.stopShell(target.shellID, directory: target.directory)
      running = false
    } catch {
      runtime.store?.toast.show("Não foi possível parar a tarefa. \(error.localizedDescription)", kind: .error)
    }
  }
}
