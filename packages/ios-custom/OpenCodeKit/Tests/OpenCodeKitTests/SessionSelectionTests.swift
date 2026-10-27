import Testing

@testable import OpenCodeKit

@Test func selectionStartsWithTheLongPressedRowAndEndsWhenEmptied() {
  var selection = SessionSelection()
  selection.toggle("ses_a")
  #expect(!selection.active)
  selection.start("ses_a")
  #expect(selection.active && selection.ids == ["ses_a"])
  selection.toggle("ses_b")
  selection.toggle("ses_c")
  #expect(selection.ids == ["ses_a", "ses_b", "ses_c"])
  selection.toggle("ses_b")
  #expect(selection.ids == ["ses_a", "ses_c"])
  selection.toggle("ses_a")
  selection.toggle("ses_c")
  #expect(selection == SessionSelection())
}

@Test func selectAllAddsVisibleRowsWithoutDuplicates() {
  var selection = SessionSelection()
  selection.selectAll(["ses_a"])
  #expect(!selection.active)
  selection.start("ses_b")
  selection.selectAll(["ses_a", "ses_b", "ses_c"])
  #expect(selection.ids == ["ses_b", "ses_a", "ses_c"])
}

@Test func hiddenOrRemovedRowsLeaveTheSelection() {
  var selection = SessionSelection()
  selection.start("ses_a")
  selection.toggle("ses_b")
  selection.retain(["ses_b", "ses_c"])
  #expect(selection.ids == ["ses_b"])
  selection.retain(["ses_c"])
  #expect(!selection.active)
}

@Test func partialResultKeepsOnlyFailuresSelected() {
  var selection = SessionSelection()
  selection.start("ses_a")
  selection.toggle("ses_b")
  selection.toggle("ses_c")
  let partial = SessionBulkResult(succeeded: ["ses_a", "ses_c"], failed: ["ses_b"])
  selection.complete(partial)
  #expect(selection.active && selection.ids == ["ses_b"])
  #expect(SessionBulkCopy.failure(partial) == "2 concluídas; 1 falhou. As que falharam continuam selecionadas.")
  selection.complete(SessionBulkResult(succeeded: ["ses_b"]))
  #expect(!selection.active)
}

@Test func bulkDeleteCopyWarnsAboutRunningAndMasterSessions() {
  #expect(SessionBulkCopy.deleteTitle(1) == "Excluir 1 sessão")
  #expect(SessionBulkCopy.deleteTitle(3) == "Excluir 3 sessões")
  #expect(SessionBulkCopy.count(2) == "2 selecionadas")
  let plain = SessionBulkCopy.deleteMessage(count: 3, running: 0, master: false)
  #expect(plain.hasPrefix("Excluir as 3 sessões selecionadas"))
  #expect(plain.hasSuffix("arquive em vez de excluir."))
  #expect(!plain.contains("trabalhando") && !plain.contains("Sessão mestra"))
  let warned = SessionBulkCopy.deleteMessage(count: 2, running: 2, master: true)
  #expect(warned.contains("2 sessões estão trabalhando e serão interrompidas."))
  #expect(warned.contains("Sessão mestra do iPhone"))
  #expect(SessionBulkCopy.done(1, archived: true) == "1 sessão arquivada")
  #expect(SessionBulkCopy.done(4, archived: false) == "4 sessões excluídas")
}
