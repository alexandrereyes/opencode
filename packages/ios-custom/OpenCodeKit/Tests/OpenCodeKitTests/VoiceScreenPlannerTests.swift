import CoreGraphics
import Foundation
import Testing
@testable import OpenCodeKit

struct VoiceScreenPlannerTests {
  private let own: Int32 = 10
  private let chrome: Int32 = 20
  private let simulator: Int32 = 30
  private var apps: [VoiceScreenPlanner.App] {
    [.init(pid: own, name: "OpenCode"), .init(pid: chrome, name: "Google Chrome"), .init(pid: simulator, name: "Simulator"),
     .init(pid: 40, name: "Música")]
  }
  /// Front to back: OpenCode's voice bar panel above everything, Chrome, the Simulator, the menu bar layer.
  private var windows: [VoiceScreenWindow] {
    [VoiceScreenWindow(id: 1, pid: own, app: "OpenCode", frame: CGRect(x: 0, y: 900, width: 400, height: 60), layer: 3),
     VoiceScreenWindow(id: 2, pid: chrome, app: "Google Chrome", title: "Docs", frame: CGRect(x: 2000, y: 0, width: 1200, height: 800)),
     VoiceScreenWindow(id: 3, pid: simulator, app: "Simulator", title: "iPhone 18 Pro", frame: CGRect(x: 100, y: 100, width: 400, height: 800)),
     VoiceScreenWindow(id: 4, pid: 50, app: "Window Server", frame: CGRect(x: 0, y: 0, width: 1728, height: 30), layer: 25)]
  }
  private let displays = [VoiceScreenPlanner.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117)),
    VoiceScreenPlanner.Display(id: 2, frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440))]

  private func plan(_ target: VoiceScreenTarget, front: Int32?, permission: Bool = true, asked: Bool = true,
    ownWindow: Bool = true) throws(VoiceScreenRefusal) -> VoiceScreenPlan {
    try VoiceScreenPlanner.plan(target, own: own, front: front, apps: apps, windows: windows, displays: displays,
      permission: permission, asked: asked, ownWindow: ownWindow)
  }

  @Test func frontWindowSkipsOpenCodeUnlessItIsTheAppInFront() throws {
    #expect(try plan(.front, front: chrome).source == .window(windows[1]))
    #expect(try plan(.front, front: own).source == .own)
    // OpenCode in front needs no permission at all.
    #expect(try plan(.front, front: own, permission: false) == VoiceScreenPlan(source: .own, notice: nil, requestsPermission: false))
    // An app in front without windows: the frontmost ordinary window of another app, never OpenCode's bar.
    #expect(try plan(.front, front: 40).source == .window(windows[1]))
  }

  @Test func appByNameIgnoresCaseAccentsAndPartialNames() throws {
    #expect(try plan(.app("simulator"), front: chrome).source == .window(windows[2]))
    #expect(try plan(.app("Chrome"), front: own).source == .window(windows[1]))
    #expect(try plan(.app("opencode"), front: chrome).source == .own)
    #expect(VoiceScreenPlanner.match("musica", in: apps)?.pid == 40)
    #expect(throws: VoiceScreenRefusal.appNotRunning("Xcode")) { try plan(.app("Xcode"), front: chrome) }
    #expect(throws: VoiceScreenRefusal.noWindow("Música")) { try plan(.app("Música"), front: chrome) }
  }

  @Test func displayIsTheOneWithTheFrontWindowAndHidesOpenCodeBehind() throws {
    #expect(try plan(.display, front: chrome).source == .display(id: 2, includesOwn: false, front: "Google Chrome"))
    #expect(try plan(.display, front: simulator).source == .display(id: 1, includesOwn: false, front: "Simulator"))
    #expect(try plan(.display, front: own).source == .display(id: 1, includesOwn: true, front: "OpenCode"))
  }

  @Test func withoutPermissionOnlyOpenCodeGoesWithANotice() throws {
    let first = try plan(.app("Simulator"), front: chrome, permission: false, asked: false)
    #expect(first == VoiceScreenPlan(source: .own, notice: VoiceScreenPlanner.firstRequestNotice, requestsPermission: true))
    let later = try plan(.front, front: chrome, permission: false, asked: true)
    #expect(later == VoiceScreenPlan(source: .own, notice: VoiceScreenPlanner.deniedNotice, requestsPermission: false))
    #expect(later.notice?.contains("Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela") == true)
    #expect(try plan(.display, front: chrome, permission: false).source == .own)
    #expect(throws: VoiceScreenRefusal.permission) {
      try plan(.front, front: chrome, permission: false, ownWindow: false)
    }
    // A missing app is reported as such, without asking for permission it would not need.
    #expect(throws: VoiceScreenRefusal.appNotRunning("Xcode")) { try plan(.app("Xcode"), front: chrome, permission: false) }
  }

  @Test func masterLineNamesWhatWasCapturedWithoutDescribingIt() {
    #expect(VoiceScreenShot(jpeg: Data(), sessionID: "ses_1", subject: VoiceScreenPlanner.subject(.own)).prompt("Olha")
      == "Olha\n\n[Captura da janela do OpenCode anexada. Sessão aberta no app: ses_1]")
    #expect(VoiceScreenShot(jpeg: Data(), sessionID: nil, subject: VoiceScreenPlanner.subject(.window(windows[1]))).prompt("Olha")
      == "Olha\n\n[Captura da janela de Google Chrome (“Docs”) anexada.]")
    #expect(VoiceScreenPlanner.subject(.window(windows[0])) == "da janela de OpenCode")
    #expect(VoiceScreenPlanner.subject(.display(id: 1, includesOwn: false, front: "Simulator"))
      == "da tela inteira do Mac (Simulator na frente)")
  }

  @Test func refusalsSaySomethingGPTLiveCanRepeat() {
    #expect(VoiceScreenRefusal.appNotRunning("Xcode").localizedDescription
      == "Não encontrei o app “Xcode” aberto neste Mac. Nada foi enviado à Sessão mestra.")
    #expect(VoiceScreenRefusal.noWindow(nil).localizedDescription.hasPrefix("Não há nenhuma janela na frente"))
    #expect(VoiceScreenRefusal.protected("Senhas").localizedDescription.contains("não deixa capturar"))
    #expect(VoiceScreenRefusal.permission.localizedDescription.contains("Gravação de Tela"))
  }
}
