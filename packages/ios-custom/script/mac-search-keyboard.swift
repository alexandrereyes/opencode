// The window search driven like a person: real mouse and keyboard events posted to the HID stream (CGEvent),
// checked through Accessibility (focus, field value, the results panel's window) and the app's DEBUG trace
// (`-OpenCodeMacSearchTrace`: selection, opened session, timings). `test-mac-search-keyboard.sh` builds and runs it.
//
//   mac-search-keyboard <pid> <app log> <captures folder>
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count == 4, let pid = pid_t(arguments[1]) else {
  print("usage: mac-search-keyboard <pid> <app log> <captures folder>")
  exit(2)
}
let logPath = arguments[2]
let captures = arguments[3]
let app = AXUIElementCreateApplication(pid)
let source = CGEventSource(stateID: .hidSystemState)
var failures: [String] = []

// MARK: Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  AXUIElementCopyAttributeValue(element, name as CFString, &value)
  return value
}
func identifier(_ element: AXUIElement?) -> String? { element.flatMap { attribute($0, "AXIdentifier") as? String } }
func value(_ element: AXUIElement?) -> String { element.flatMap { attribute($0, kAXValueAttribute) as? String } ?? "" }
func frame(_ element: AXUIElement) -> CGRect {
  var point = CGPoint.zero, size = CGSize.zero
  if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
  if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
  return CGRect(origin: point, size: size)
}
func elements(_ root: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
  let own = match(root) ? [root] : []
  guard depth < 45, let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] else { return own }
  return own + children.flatMap { elements($0, depth: depth + 1, where: match) }
}
var focused: AXUIElement? { attribute(app, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement } }
/// The app's standard windows, without the results panels.
var windows: [AXUIElement] {
  (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
    attribute($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
  }
}
/// The search field of the front (focused) window.
var field: AXUIElement? { front.flatMap { elements($0) { identifier($0) == "mac-window-search" }.first } }
var composer: AXUIElement? { front.flatMap { elements($0) { identifier($0) == "conversation-composer" }.first } }
var front: AXUIElement? { attribute(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement } ?? windows.first }

// MARK: Window server

/// On-screen windows of the app, in CG (top-left) coordinates.
func cgWindows() -> [CGRect] {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
}
/// The results panel: a window of the field's width hanging 4 pt under it.
func panel(under field: CGRect) -> CGRect? {
  cgWindows().first { abs($0.width - field.width) < 3 && abs($0.minX - field.minX) < 3 && abs($0.minY - field.maxY - 4) < 4 }
}

// MARK: Events

func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, text: String? = nil) {
  let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
  event.flags = flags
  if let text { let units = Array(text.utf16); event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
  event.post(tap: .cghidEventTap)
}
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
  let modifiers: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, 55), (.maskAlternate, 58), (.maskControl, 59), (.maskShift, 56)]
    .filter { flags.contains($0.0) }
  for modifier in modifiers { post(modifier.1, down: true, flags: flags); usleep(12_000) }
  post(code, down: true, flags: flags)
  usleep(25_000)
  post(code, down: false, flags: flags)
  for modifier in modifiers.reversed() { usleep(12_000); post(modifier.1, down: false, flags: []) }
  usleep(120_000)
}
/// US ANSI virtual key codes, so each letter is the physical key a person would press.
let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
  "j": 38, "k": 40, "n": 45, "m": 46]
func type(_ text: String) {
  for character in text {
    post(letters[character] ?? 0, down: true, flags: [], text: String(character))
    usleep(25_000)
    post(letters[character] ?? 0, down: false, flags: [], text: String(character))
    usleep(90_000)
  }
}
func click(_ point: CGPoint) {
  for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(type == .mouseMoved ? 80_000 : 40_000)
  }
  usleep(150_000)
}

// MARK: Checks

func wait(_ seconds: Double = 2, _ condition: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    if condition() { return true }
    usleep(30_000)
  }
  return condition()
}
func check(_ ok: Bool, _ message: String) {
  print((ok ? "ok    " : "FALHA ") + message)
  if !ok { failures.append(message) }
}
var logOffset = 0
/// Trace lines written since the last call.
func trace() -> [String] {
  let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
  let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("MacSearchTrace ") }
  defer { logOffset = lines.count }
  return Array(lines.dropFirst(logOffset)).map { String($0.dropFirst("MacSearchTrace ".count)) }
}
var timings: [String: [Double]] = [:]
func collect(_ lines: [String]) {
  for line in lines {
    let parts = line.split(separator: " ")
    if parts.count == 3, ["abrir", "filtrar"].contains(String(parts[0])), let ms = Double(parts[1]) {
      timings[String(parts[0]), default: []].append(ms)
    }
  }
}
/// The last trace line starting with `prefix`, waiting for it.
func traced(_ prefix: String, seconds: Double = 2) -> String? {
  var seen: [String] = []
  _ = wait(seconds) {
    seen += trace()
    return seen.contains { $0.hasPrefix(prefix) }
  }
  collect(seen)
  return seen.last { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}
func capture(_ name: String) {
  guard let window = front.map(frame) else { return }
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  task.arguments = ["-x", "-R", "\(Int(window.minX)),\(Int(window.minY)),\(Int(window.width)),\(Int(window.height))",
    captures + "/" + name + ".png"]
  try? task.run()
  task.waitUntilExit()
}

// MARK: Run

guard AXIsProcessTrusted() else { print("Accessibility permission missing for the terminal"); exit(2) }
guard let running = NSRunningApplication(processIdentifier: pid) else { print("app not running"); exit(2) }
let previous = NSWorkspace.shared.frontmostApplication
// Launched in the background, SwiftUI opens no window until the app is active; Arquivo ▸ Nova janela opens one.
if !wait(6, { !windows.isEmpty }), let bar = attribute(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
  let item = elements(bar, where: { attribute($0, kAXTitleAttribute) as? String == "Nova janela" }).first {
  AXUIElementPerformAction(item, kAXPressAction as CFString)
}
running.activate()
check(wait(5) { running.isActive && field != nil }, "app ativo com o campo de busca na janela")
_ = trace()

// 1. A click focuses the field and opens the list.
let fieldFrame = frame(field!)
click(CGPoint(x: fieldFrame.minX + 80, y: fieldFrame.midY))
check(wait { identifier(focused) == "mac-window-search" }, "clique: o campo recebe o foco de teclado")
check(wait { panel(under: fieldFrame) != nil }, "clique: a lista abre ancorada sob o campo")
capture("1-foco-apos-clique")

// 2. Typing goes straight to the field and filters on each key.
_ = trace()
type("live")
check(wait { value(field) == "live" }, "digitação: o texto vai para o campo (\(value(field)))")
let filtered = trace()
collect(filtered)
check(filtered.filter { $0.hasPrefix("filtrar") }.count >= 4, "digitação: a lista filtra a cada tecla")
capture("2-digitacao")

// 3. ↓/↑ and ⌃N/⌃P move through the groups; Return opens the selected session.
key(125)
let first = traced("seleção ")
key(125)
let second = traced("seleção ")
key(126)
check(traced("seleção ") == first && first != second && first != nil, "↓ ↓ ↑ movem a seleção (\(first ?? "-") → \(second ?? "-"))")
key(45, .maskControl)
check(second != nil && traced("seleção ") == second, "⌃N funciona como ↓")
key(35, .maskControl)
check(first != nil && traced("seleção ") == first, "⌃P funciona como ↑")
var selection = first ?? ""
for _ in 0..<12 where !selection.hasPrefix("session:") {
  key(125)
  selection = traced("seleção ") ?? selection
}
check(selection.hasPrefix("session:"), "↓ atravessa os grupos até Sessões (\(selection))")
capture("3-selecao-pelas-setas")
check(identifier(focused) == "mac-window-search" && value(composer).isEmpty, "o compositor não recebeu as setas nem ⌃N/⌃P")
key(36)
var opened: [String] = []
_ = wait { opened += trace(); return opened.contains { $0.hasPrefix("janela mostra ") } }
check(opened.contains("abriu " + selection), "Return abre o item selecionado")
check(opened.contains("janela mostra " + selection.dropFirst("session:".count)), "Return: a janela mostra a sessão escolhida")
check(wait { panel(under: fieldFrame) == nil }, "Return: a lista fecha")
check(wait { identifier(focused) == "conversation-composer" }, "Return: o foco vai para o compositor")
check(value(focused).isEmpty, "Return: o compositor não recebeu o Return nem o texto")

// 4. ⌘K from the composer focuses the field with its text selected; Esc clears, then closes.
key(40, .maskCommand)
check(wait { identifier(focused) == "mac-window-search" }, "⌘K com o compositor focado: o campo recebe o foco")
check(wait { panel(under: fieldFrame) != nil }, "⌘K: a lista abre")
type("arq")
check(wait { value(field) == "arq" }, "⌘K: o texto anterior fica selecionado e a digitação o substitui (\(value(field)))")
key(53)
check(wait { value(field).isEmpty } && panel(under: fieldFrame) != nil && identifier(focused) == "mac-window-search",
  "Esc com texto: limpa o texto e mantém a lista")
key(53)
check(wait { panel(under: fieldFrame) == nil }, "Esc com o campo vazio: fecha a lista")
check(wait { identifier(focused) == "conversation-composer" }, "Esc com o campo vazio: o foco volta ao compositor")
check(value(focused).isEmpty, "Esc: o compositor não recebeu o Esc nem o texto")

// 4b. With the empty query the list scrolls: ↓ keeps the selected row inside the panel, ↑ brings the top back.
key(40, .maskCommand)
_ = wait { panel(under: fieldFrame) != nil }
func selectedRow() -> CGRect? {
  elements(app) { attribute($0, kAXSelectedAttribute) as? Bool == true && (attribute($0, kAXDescriptionAttribute) as? String) != nil }
    .map(frame).first { $0.width > 0 && $0.width < fieldFrame.width + 4 && $0.minY > fieldFrame.maxY }
}
for _ in 0..<15 { key(125) }
let bottom = panel(under: fieldFrame) ?? .zero
let row = selectedRow()
check(row.map { bottom.insetBy(dx: 0, dy: -1).contains($0) } == true,
  "↓ rola a lista e mantém a seleção visível (linha \(row.map { "\(Int($0.minY))–\(Int($0.maxY))" } ?? "-"), lista \(Int(bottom.minY))–\(Int(bottom.maxY)))")
capture("4-rolagem-pela-seta")
for _ in 0..<15 { key(126) }
let top = selectedRow()
check(top.map { bottom.contains($0) && $0.minY < bottom.minY + 80 } == true, "↑ volta ao topo da lista")
key(53)
check(wait { panel(under: fieldFrame) == nil }, "Esc fecha a lista rolada")

// 5. Clicking a result opens it; clicking outside closes.
key(40, .maskCommand)
type("live")
_ = wait { panel(under: fieldFrame) != nil }
_ = trace()
let list = panel(under: fieldFrame) ?? .zero
let rows = elements(app) { (attribute($0, kAXDescriptionAttribute) as? String)?.hasPrefix("Sessões, ") == true }
if let row = rows.first(where: { list.contains(CGPoint(x: frame($0).midX, y: frame($0).midY)) }) {
  let rowFrame = frame(row)
  click(CGPoint(x: rowFrame.midX, y: rowFrame.midY))
  let opened = traced("abriu ")
  check(opened?.hasPrefix("session:") == true, "clique num resultado abre a sessão (\(opened ?? "-"))")
  check(wait { panel(under: fieldFrame) == nil }, "clique num resultado fecha a lista")
} else {
  check(false, "a lista expõe as linhas de Sessões à Acessibilidade")
}
key(40, .maskCommand)
check(wait { panel(under: fieldFrame) != nil }, "⌘K reabre a lista")
click(CGPoint(x: fieldFrame.minX - 6, y: fieldFrame.midY))
check(wait { panel(under: fieldFrame) == nil }, "clicar fora (na barra de título) fecha a lista")
check(traced("fechou") != nil && identifier(focused) != "mac-window-search", "clicar fora solta o foco do campo")
key(40, .maskCommand)
check(wait { panel(under: fieldFrame) != nil }, "⌘K reabre a lista")
if let box = composer.map(frame) {
  click(CGPoint(x: box.midX, y: box.midY))
  check(wait { panel(under: fieldFrame) == nil }, "clicar no compositor fecha a lista")
  check(wait { identifier(focused) == "conversation-composer" }, "clicar no compositor o foca")
}

// 6. Two windows: each has its own search, ⌘K acts on the front one.
key(45, [.maskCommand, .maskAlternate])
check(wait(5) { windows.count >= 2 && field.map(frame) != fieldFrame }, "⌥⌘N abre uma segunda janela na frente")
if let second = field.map(frame), second != fieldFrame {
  key(40, .maskCommand)
  check(wait { panel(under: second) != nil }, "⌘K na segunda janela abre a lista dela")
  check(panel(under: fieldFrame) == nil, "⌘K não abre a lista da outra janela")
  check(wait { identifier(focused) == "mac-window-search" && frame(focused!) == second }, "⌘K foca o campo da janela da frente")
  key(53)
  key(13, .maskCommand)
  check(wait(3) { windows.count == 1 }, "⌘W fecha a segunda janela")
}

for (name, values) in timings.sorted(by: { $0.key < $1.key }) {
  let sorted = values.sorted()
  print(String(format: "tempo %@: n=%d mediana=%.1f ms máx=%.1f ms", name, sorted.count, sorted[sorted.count / 2], sorted.last!))
}
print(failures.isEmpty ? "busca com eventos reais: ok" : "busca com eventos reais: \(failures.count) falha(s)")
if previous?.processIdentifier != pid { previous?.activate() }
exit(failures.isEmpty ? 0 : 1)
