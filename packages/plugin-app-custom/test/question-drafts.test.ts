import { expect, test } from "bun:test"
import { Schema } from "effect"
import { clearDraft, Doc, empty, saveDraft } from "../src/question-drafts"
import { QuestionDrafts } from "../src/question-drafts/rpc"

const field = (selected: string[] = [], text = "", added: string[] = []) => ({ selected, text, added })
function saved(result: ReturnType<typeof saveDraft>) {
  if (!result.ok) throw new Error(`unexpected failure: ${result.failure.limit}`)
  return result
}

test("the contract round-trips through the stored document", () => {
  const first = saved(saveDraft(empty, { requestID: "frm_a", fields: { voz: field(["marin"]) } }, 10))
  expect(Schema.decodeUnknownSync(Doc)(Schema.encodeSync(Doc)(first.doc))).toEqual(first.doc)
  expect(QuestionDrafts.Definition.id).toBe("custom.question-drafts")
  expect(Object.keys(QuestionDrafts.Definition.methods)).toEqual(["get", "save", "clear"])
})

test("saving merges by field, so two devices editing different questions keep both answers", () => {
  const phone = saved(saveDraft(empty, { requestID: "frm_a", fields: { voz: field(["marin"]) } }, 10))
  const mac = saved(saveDraft(phone.doc, { requestID: "frm_a", fields: { nota: field([], "ok") } }, 20))
  expect(mac.draft).toEqual({
    requestID: "frm_a",
    fields: { voz: field(["marin"]), nota: field([], "ok") },
    updatedAt: 20,
    revision: 2,
  })
  // The same field: last write wins, here a multiple choice with an added item.
  const again = saved(saveDraft(mac.doc, { requestID: "frm_a", fields: { voz: field([], "viola", ["coral"]) } }, 30))
  expect(again.draft.fields.voz).toEqual(field([], "viola", ["coral"]))
  expect(again.doc.revision).toBe(3)
})

test("clearing drops only that request and leaves the revision alone when there was nothing", () => {
  const a = saved(saveDraft(empty, { requestID: "frm_a", fields: { voz: field(["marin"]) } }, 10))
  const b = saved(saveDraft(a.doc, { requestID: "frm_b", fields: { x: field([], "y") } }, 20))
  const cleared = clearDraft(b.doc, "frm_a")
  expect(cleared.drafts.map((draft) => draft.requestID)).toEqual(["frm_b"])
  expect(cleared.revision).toBe(3)
  expect(clearDraft(cleared, "frm_a")).toBe(cleared)
})

test("stale drafts are dropped and the limits hold", () => {
  const day = 24 * 60 * 60 * 1000
  const old = saved(saveDraft(empty, { requestID: "frm_old", fields: { a: field(["x"]) } }, 0))
  const fresh = saved(
    saveDraft(old.doc, { requestID: "frm_new", fields: { a: field(["y"]) } }, QuestionDrafts.limits.staleDays * day),
  )
  expect(fresh.doc.drafts.map((draft) => draft.requestID)).toEqual(["frm_new"])
  const full = Array.from({ length: QuestionDrafts.limits.draftsPerSession }, (_, index) => `frm_${index}`).reduce(
    (doc, requestID) => saved(saveDraft(doc, { requestID, fields: { a: field() } }, 1)).doc,
    empty,
  )
  expect(saveDraft(full, { requestID: "frm_more", fields: {} }, 2)).toEqual({
    ok: false,
    failure: { limit: "draftsPerSession", max: QuestionDrafts.limits.draftsPerSession },
  })
  const many = Object.fromEntries(
    Array.from({ length: QuestionDrafts.limits.fieldsPerDraft + 1 }, (_, index) => [`q${index}`, field()]),
  )
  expect(saveDraft(empty, { requestID: "frm_a", fields: many }, 1).ok).toBe(false)
  expect(() =>
    Schema.decodeUnknownSync(QuestionDrafts.Field)(field([], "x".repeat(QuestionDrafts.limits.textLength + 1))),
  ).toThrow()
})
