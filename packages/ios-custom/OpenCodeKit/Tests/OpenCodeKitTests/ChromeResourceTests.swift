import Foundation
import Testing
@testable import OpenCodeKit

@Test func chromeStateDecodesTheAdapterMetaAndToleratesMissingFields() throws {
  let json = """
    {"url":"http://localhost:5173/login","title":"Entrar","canGoBack":true,"canGoForward":false,
     "targetID":"T1","tabs":[{"id":"T1","title":"Entrar","url":"http://localhost:5173/login"}],
     "focus":{"editable":true,"field":"password"},"editTaps":3,"viewport":{"width":412,"height":915}}
    """
  let meta = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
  let state = ChromeViewerState(meta: meta)
  #expect(state.displayAddress == "localhost:5173/login")
  #expect(state.isSecure)
  #expect(state.canGoBack && !state.canGoForward)
  #expect(state.tabs == [ChromeTab(id: "T1", title: "Entrar", url: "http://localhost:5173/login")])
  #expect(state.focus == ChromeFocus(editable: true, field: .password))
  #expect(state.viewport == CGSize(width: 412, height: 915))
  #expect(state.editTaps == 3)

  let sparse = ChromeViewerState(meta: ["focus": .object(["editable": .bool(true), "field": .string("new")])])
  #expect(sparse.focus == ChromeFocus(editable: true, field: .text))
  #expect(sparse.url.isEmpty && sparse.tabs.isEmpty && sparse.viewport == nil)
  #expect(ChromeViewerState(meta: ["url": .number(1)]) == ChromeViewerState())
}

@Test func chromeAddressesAndSecureContexts() {
  #expect(ChromeViewerState.displayAddress("https://abacato.app/") == "abacato.app")
  #expect(ChromeViewerState.displayAddress("https://abacato.app/a/b?x=1") == "abacato.app/a/b")
  #expect(ChromeViewerState.displayAddress("http://localhost:5173/login") == "localhost:5173/login")
  #expect(ChromeViewerState.displayAddress("about:blank") == "about:blank")
  #expect(!ChromeViewerState(url: "http://example.com").isSecure)
  #expect(ChromeViewerState(url: "http://127.0.0.1:5173").isSecure)
  #expect(ChromeViewerState(url: "https://example.com").isSecure)
}

@Test func chromeKeyboardFollowsTheFocusedField() {
  #expect(ChromeKeyboard(.password) == ChromeKeyboard(.password, .standard, secure: true))
  #expect(ChromeKeyboard(.username).contentType == .username)
  #expect(ChromeKeyboard(.email).keyboard == .email)
  #expect(ChromeKeyboard(.oneTimeCode).contentType == .oneTimeCode)
  #expect(ChromeKeyboard(.number).keyboard == .numbers)
  #expect(!ChromeKeyboard(.multiline).secure)
}

@Test func chromeTabSelectionEncodesANavigateTabInput() throws {
  let data = try JSONEncoder().encode(ResourceInput.selectTab("T2"))
  let json = try JSONDecoder().decode([String: String].self, from: data)
  #expect(json == ["type": "navigate", "action": "tab", "target": "T2"])
}
