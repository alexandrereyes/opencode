# Question drafts (`custom.question-drafts`)

The unsent answers of a pending question form (a `form.created` request shown as a question card), shared by every
client of one server: answers given on the iPhone are there on the Mac, after switching sessions or after reopening the
app. Only drafts live here; the answer itself still goes through `POST /api/session/:id/form/:formID/reply`.

## Storage

One document per session in the plugin's storage (`question-drafts:session:<sessionID>`), written through
`ctx.storage.update` under the plugin's process-wide lock, the same mechanism as `custom.quotes`: it is in the
server's database, survives restarts and `custom:update`, needs no table or migration, and a session's drafts are one
key to remove. The document has a session `revision` that grows on every change and the drafts, one per form.

## Contract

- `Field`: `{ selected: string[], text: string, added: string[] }`, one question's answer: the options marked (one for
  a single choice), the free text ("Outra resposta…", or the text waiting in a multiple choice's own answer) and the
  items a multiple choice added on its own.
- `Draft`: `{ requestID, fields: Record<questionKey, Field>, updatedAt, revision }`.
- `get({ sessionID, requestID })` → `{ draft: Draft | null }`.
- `save({ sessionID, requestID, fields, client? })` → `Draft`. **Merges by question**: the questions sent replace their
  stored value, the others keep theirs, so two devices answering different questions keep both. Errors:
  `session_not_found`, `limit_exceeded` (`{ limit, max }`).
- `clear({ sessionID, requestID, client? })` → `{ revision }`.
- Event `updated`: `{ sessionID, requestID, revision, cleared, client? }` after every save or clear (`cleared: true`
  when the draft is gone). `client` is the opaque ID the saving client sent, so it can skip its own change; the event
  reaches clients as `rpc.custom.question-drafts.updated`.
- Limits (`QuestionDrafts.limits`): 50 drafts per session, 100 questions per draft, 100 items per list, 32,768
  characters of text, keys up to 256 characters.

## Cleanup

Nothing is left behind: a draft is dropped when its form is answered (`form.replied`) or cancelled (`form.cancelled`:
dismissed, interrupted or expired), and a session's document is removed when the session is archived
(`session.archived`) or deleted (`session.deleted`). Forms live in the server's memory, so a restart drops pending forms
without events: drafts nobody touched for 14 days are dropped on the next save of the session and never returned by
`get`.

## Clients

The iOS and Mac apps (`OpenCodeKit/QuestionDrafts.swift`, `QuestionDraftSync`): see "Question drafts" in
`packages/ios-custom/README.md`. A client without this RPC (an older server answers `rpc.unavailable`) keeps the draft
on its own device only.
