# Chat quotes on the server

`custom.quotes` stores the **pending** chat quotes of a Session (text selected in an assistant answer plus the user's comment) on the server, so the iOS and Mac apps show and edit the same drafts: start commenting on the Mac, finish and send on the iPhone. The custom web app that also used it was removed on 2026-10-29 (tag `web-custom-final`); the standard web app the server now serves does not know `custom.quotes`. Code: `src/quotes/rpc.ts` (contract and limits), `src/quotes/index.ts` (policy and storage). This file is the contract both clients follow.

## What moves to the server, and what does not

| State                                                                                                                                  | Today                                                                                                                                                                                                                                                                                                                              | With `custom.quotes`                                                        |
| -------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Pending quotes of a Session (drafts not yet sent)                                                                                      | Web: `ComposerStore.quotes` in IndexedDB `opencode-drafts` (`documents` key `opencode.workspace.<head>.<checksum>.dat:session:<sessionID>:prompt`, bytes in `blobs`). iOS: `quotes` in `<Application Support>/OpenCode/Drafts/<sha256(serverURL)>/<sessionID>/draft.json`, attachment files beside it (`DraftAttachment.quoteID`). | **Server**, one document per Session.                                       |
| Comment attachments (pasted images, files)                                                                                             | Web: IndexedDB blobs, `blob.id` = SHA-256 hex of the bytes. iOS: files named by attachment UUID in the draft directory.                                                                                                                                                                                                            | **Server**, content-addressed (`id` = SHA-256 hex), separate from listings. |
| Hidden marks of sent quotes (iOS only)                                                                                                 | `<Application Support>/OpenCode/QuoteMarks/<sha256(serverURL)>.json`, `[{sessionID, quotes: [id]}]`.                                                                                                                                                                                                                               | **Server**, `dismissed` of the Session.                                     |
| Sent quotes                                                                                                                            | `metadata.quotes` of the carrying user message (plus the `Comments on earlier assistant messages:` text and the message `files`). Previews and sent marks derive from it.                                                                                                                                                          | **Unchanged.** Already on the server; this RPC never touches messages.      |
| Composer text, web prompt history (`opencode.global.dat:prompt-history`), quote editor geometry, hover, the iOS ephemeral quote editor | Local.                                                                                                                                                                                                                                                                                                                             | **Local.** History is a log, not a draft.                                   |

Quotes always belong to an existing Session: they cite an assistant message, so a new-session composer never has any.

## Model

```ts
Quote {
  id: string               // 1–128 chars, client-generated (UUID); stable across clients and the migration
  messageID: string        // quoted assistant message
  partID: string           // quoted text part
  text: string             // copyable quoted text as the client shows it (≤ 32768)
  comment: string          // plain comment (≤ 32768)
  commentPrompt?: Json[]   // opaque composer parts of the comment (web `Prompt` shape), ≤ 256 KiB as JSON
  anchor?: Anchor
  attachments: Attachment[] // display order; metadata only, never bytes
  createdAt: number        // ms, server clock, kept across edits
  updatedAt: number        // ms, server clock of the last write
  revision: number         // Session revision of the last write of this quote
}

Anchor {
  start: number            // UTF-16 code units, [start, end), end ≥ start
  end: number
  exact: string            // the text at [start, end) in `coordinate`
  coordinate?: "rendered" | "source"   // absent = "rendered" (web drafts written so far)
  prefix?: string          // ≤ 256 chars of rendered plain text right before the selection
  suffix?: string          // ≤ 256 chars of rendered plain text right after it
}

Attachment { id: sha256-hex, mime: string, filename?: string, size: number }

State {                    // `list` output
  sessionID: string
  revision: number         // increases on every change of quotes or dismissals; 0 = nothing stored
  quotes: Quote[]          // display order: number = index + 1; new quotes append, edits keep their place
  dismissed: string[]      // sent quote IDs whose marks are hidden (bounded, oldest dropped first)
}
```

`QuoteInput` (what clients write) has the same fields except `createdAt`, `updatedAt`, `revision`, and `attachments` is `string[]` of attachment IDs. Extra fields are dropped, not stored; keep client-only data out of the quote.

## RPCs

All calls are `POST /api/rpc/custom.quotes/<method>?location[directory]=<session directory>` with body `{"input": {...}}`; success is `{"output": ...}`. Declared errors are HTTP 400 `{"_tag":"RpcError","type":"<error>","message":"…","data":{…}}`; schema violations are `rpc.invalid_input`. Pass the Session's directory like the other custom RPCs (the plugin is registered per Location; the store itself is global to the server).

| Method       | Input                                                | Output                                              | Errors                                                                                              |
| ------------ | ---------------------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `info`       | `{}`                                                 | `{ version: 1, limits }`                            | —                                                                                                   |
| `list`       | `{ sessionID }`                                      | `State` (unknown Session = empty state, revision 0) | —                                                                                                   |
| `save`       | `{ sessionID, quote: QuoteInput }`                   | `{ revision, quote }`                               | `session_not_found`, `limit_exceeded {limit,max}`, `attachment_missing {ids}`, `already_sent {ids}` |
| `remove`     | `{ sessionID, id }`                                  | `{ revision }` (no-op if absent)                    | —                                                                                                   |
| `clear`      | `{ sessionID, ids?, reason: "sent" \| "discarded" }` | `{ revision }`                                      | —                                                                                                   |
| `import`     | `{ sessionID, quotes: QuoteInput[] (≤ 100) }`        | `{ state, imported: id[], skipped: id[] }`          | `session_not_found`, `limit_exceeded`, `attachment_missing`                                         |
| `dismiss`    | `{ sessionID, ids }`                                 | `{ revision }`                                      | —                                                                                                   |
| `upload`     | `{ sessionID, mime, filename?, data: base64 }`       | `Attachment`                                        | `session_not_found`, `limit_exceeded`, `invalid_data`                                               |
| `attachment` | `{ sessionID, id }`                                  | `Attachment & { data: base64 }`                     | `not_found`                                                                                         |

Examples:

```json
POST /api/rpc/custom.quotes/save
{"input":{"sessionID":"ses_…","quote":{"id":"6F1C…","messageID":"msg_…","partID":"prt_…","text":"Rodando: nada.","comment":"Comentário","commentPrompt":[{"type":"text","start":0,"end":10,"content":"Comentário"}],"anchor":{"start":4,"end":21,"exact":"**Rodando:** nada","coordinate":"source","prefix":"Status:\n","suffix":".\nPronto para publicar"},"attachments":["b298…ff72"]}}}

POST /api/rpc/custom.quotes/clear
{"input":{"sessionID":"ses_…","ids":["6F1C…"],"reason":"sent"}}
```

- `save` creates or replaces the whole quote (last write wins). `messageID`, `partID`, `text` and `anchor` do not change after creation in practice, but the server does not enforce it.
- `clear` without `ids` clears every quote. With `reason: "sent"` every listed ID is tombstoned (see Conflicts), even when another client already removed it. **After sending, always pass the exact IDs that went out**, never omit `ids`: a quote added meanwhile on another device must survive.
- `remove` and `clear` are idempotent; a change that alters nothing does not bump the revision nor emit an event.

## Live updates

Every change that bumps the revision emits the plugin RPC event on the normal server event stream `GET /api/event`:

```json
{
  "type": "rpc.custom.quotes.updated",
  "location": { "directory": "…" },
  "data": { "sessionID": "ses_…", "revision": 7 }
}
```

The `location` is the caller's, not necessarily the viewer's: **listen globally and filter by `data.sessionID`**, not by `location.directory`. On an event for the open Session with `revision` greater than the last known one, call `list` and replace the state. Also call `list` when a Session opens, after every SSE reconnect (`server.connected`) and when the app returns to the foreground; events missed while disconnected are not replayed. Ignore `list`/`save` responses whose revision is lower than the one already applied. `upload` does not emit (it changes nothing visible).

## Anchor: capture and resolution

The two clients render Markdown differently, so a single offset system cannot serve both. Each quote keeps the offsets in the creating client's native system plus renderer-independent text context:

- **Web** captures `coordinate: "rendered"` (always written explicitly since the web migration; older web drafts omit it): offsets and `exact` in `body.textContent` of the part's `[data-slot="text-part-body"]` (`captureChatQuoteAnchor`).
- **iOS** captures `coordinate: "source"`: offsets and `exact` in the part's raw Markdown (`part.text`), as `ChatQuote.selection` does today.
- **Both** add `prefix` and `suffix`: up to 64 characters (max 256) of _rendered plain text_ immediately around the selection (web: `textContent`; iOS: the flattened rendered text used by `ConversationSearch`). `text` stays the trimmed, copyable selection.

Resolution, in the part identified by `partID` (load `messageID` when the part is not in memory):

1. **Native coordinate** (web: `rendered`/absent; iOS: `source`): if `exact` equals the text at `[start, end)`, use it. iOS keeps its existing compatibility path for `rendered` anchors (flattened rendered text) before step 2.
2. **Text search** in the rendered plain text with whitespace-insensitive matching (collapse every whitespace run to one space and trim, on both sides; map the match back to original offsets). The needle is `exact` for `rendered` anchors and `text` for `source` anchors (raw Markdown syntax never appears in rendered text). One occurrence: use it. Several: score each by the length of the common suffix between the normalized `prefix` and the text before it plus the common prefix between the normalized `suffix` and the text after it; use the single best score; a tie is unresolved.
3. **Unresolved**: draw no mark. The quote stays in the list and the panel, and "go to quote" scrolls to the message with the existing "o trecho foi alterado" message. Never delete or silently move a quote because its anchor failed.

A `rendered` anchor without `prefix` and `suffix` (web drafts written before this contract) skips step 2: when its offsets no longer match it is unresolved, never moved to another occurrence. Quotes without `anchor` (old drafts) keep today's rule: search `text`, accept only a unique occurrence.

## Attachments

- **Upload first, then reference.** `upload` takes standard base64 of the bytes (≤ 20 MiB decoded) and returns `{ id, mime, filename?, size }`; `id` is the SHA-256 hex of the bytes computed by the server, so re-uploading equal bytes is free and idempotent. Put the IDs in `quote.attachments` (display order), and in `commentPrompt` make every part that carries bytes reference the attachment by `blob: { id: <attachment id>, url: "" }`; never put data URLs or `blob:`/`file:` URLs in `commentPrompt`. The web's `blob.id` is already a SHA-256 hex of the bytes, so it equals the server ID. `path` parts (files already staged on the server) stay as they are.
- `save`/`import` fail with `attachment_missing {ids}` when an ID was never uploaded or was already collected; upload again and retry.
- `list` returns metadata only. Fetch bytes with `attachment` when rendering a thumbnail or sending, and cache them locally by ID (the ID is the content hash, so a cache never goes stale).
- **Lifecycle.** An attachment a quote stops referencing in a change (edit, `remove`, `clear`) is deleted with that change. An upload no quote ever referenced is kept for one hour (`attachmentGraceMs`) and collected by the next change of that Session. Deleting the Session deletes everything.
- Limits: 20 MiB per attachment, 10 per quote, 64 MiB per Session counting uploads still in their grace period (`limit_exceeded` with `limit: "sessionAttachmentBytes"`). Convert HEIC/HEIF to JPEG before uploading, as the iOS composer already does for inline images.

## Sending

The prompt wire format does not change: clients still append the `Comments on earlier assistant messages:` block, put the quotes in `metadata.quotes` and the attachments in `files` (inline data URL) or as staged paths, exactly as today; fetch the bytes with `attachment` when they are not cached.

1. Capture the IDs of the quotes being sent.
2. `POST /api/session/<id>/prompt`.
3. **Only after the server admits it** (including `queue` delivery), call `clear { ids, reason: "sent" }`. On failure, nothing on the server changed; just restore the local UI.

## Conflicts

Kept deliberately simple:

- **Per quote, last write wins.** Each `save` replaces the quote; `revision`/`updatedAt` tell which state is newer. Two devices editing the same comment at the same time keep the later save. While the local editor of a quote is open, keep the local text and apply the server version only after Done.
- **Tombstones for sent quotes** (the one extra rule). Concrete case it prevents: the Mac sends quotes 1 and 2 and clears them; the iPhone, still showing quote 1, flushes a debounced comment edit a second later. Without a tombstone that `save` recreates quote 1, it appears again in the composer and is sent twice. The server keeps the last 1000 sent IDs per Session: `save` of one fails with `already_sent` (drop it locally) and `import` skips it.
- `remove`/`discarded` leave no tombstone: a later edit of a deleted quote from a stale device brings it back, which is harmless and keeps the user's text.

## One-time migration of local drafts

Each client migrates per server and Session, the first time it has local pending quotes (or iOS dismissals) for a Session whose server answered `info`:

1. Upload each local attachment that a local quote references (`upload`; equal bytes give the same ID) and rewrite the quote's `attachments` and `commentPrompt` `blob.id` to the returned IDs.
2. Call `import { sessionID, quotes }` with the local quotes **keeping their local IDs**, in local order.
3. On success, delete those quotes and their attachment bytes from the local draft and persist (keep the rest of the draft: text, attachments of the main prompt, model…). From now on the server is the source of truth for that Session.
4. iOS also calls `dismiss { sessionID, ids }` with that Session's entry of `QuoteMarks` and then deletes the entry.

`import` never overwrites: quotes whose ID already exists, that were sent (tombstone), or whose content (message, part, text, anchor offsets and exact text, comment) equals an existing quote are reported in `skipped`. So a crash between steps 2 and 3, a second browser importing the same draft, or two devices importing at once cannot duplicate anything; distinct quotes from different devices are merged in import order. Do not migrate when `import` fails: `attachment_missing` → upload again and retry once; `limit_exceeded` or `session_not_found` → keep the local draft and stay local for that Session (a deleted Session's local draft can simply be discarded, as both clients already do on 404).

## Compatibility with servers without `custom.quotes`

A new client may talk to a server that has not run `custom:update` yet. Probe once per server connection, again after each SSE reconnect and when returning to the foreground:

```json
POST /api/rpc/custom.quotes/info   {"input":{}}
```

- `200` with `version: 1` → **server mode**: migrate (above), then read and write quotes only through the RPCs.
- `400` with `type` `rpc.unavailable` (`RPC is unavailable: custom.quotes`) or `rpc.method_not_found` → **local mode**: keep today's local storage and behavior untouched. `rpc.unavailable` can also be transient while plugins reload, which the next probe corrects.
- Network errors, `401`, `5xx` → keep the current mode and probe again later; never migrate or delete local data on an unknown outcome.

Switching from server mode back to local mode (rollback of the server) starts from an empty local draft for already-migrated Sessions; the server keeps their quotes until the server is updated again.

## Limits

| Limit                             | Value                                                                                           |
| --------------------------------- | ----------------------------------------------------------------------------------------------- |
| Quotes per Session                | 100 (`save` of a new quote and `import` beyond it fail with `limit_exceeded`; edits still work) |
| `id`, `messageID`, `partID`       | 1–128 chars                                                                                     |
| `text`, `comment`, `anchor.exact` | 32768 chars each                                                                                |
| `anchor.prefix` / `suffix`        | 256 chars (64 recommended)                                                                      |
| `commentPrompt`                   | 256 KiB as JSON                                                                                 |
| Attachments                       | 20 MiB each, 10 per quote, 64 MiB per Session                                                   |
| Unreferenced upload grace         | 1 hour                                                                                          |
| Sent tombstones / dismissals      | last 1000 per Session                                                                           |

`info` returns the size limits so clients can check before uploading.

## Storage

Plugin KV (`ctx.storage`, SQLite `kv`, namespaced by plugin): `quotes:session:<sessionID>` holds the Session document (quotes, attachment index, tombstones, dismissals) and every change is one atomic `update` of that key. Bytes live in `quotes:attachment:<sessionID>:<sha256>` as `{ data: base64 }`, so listings never read them. The plugin subscribes to `session.deleted` and removes both. No Core, Protocol, Server or generated client change was needed.

## Phase 2 checklist

**Web (`packages/app-custom`, removed; tag `web-custom-final`): done.** `src/composer/quote-sync.ts` bound every Session composer to its server: `info` probe (again on reconnect, focus and visibility), one-time import of the IndexedDB drafts, `list` mirrored into the composer, `rpc.custom.quotes.updated` read from the app's shared event stream, comment saves debounced by 400 ms and flushed on Done, trash and page hide, images uploaded before the save, `clear` with `reason: "sent"` only after admission. Without `custom.quotes` the composer keeps its IndexedDB drafts. History browsing and editing a queued prompt show their quotes as a local preview that is never published. Quotes restored from a sent message (revert, an undone queued prompt) are saved under new IDs when the server reports `already_sent`; a stale edit of a quote sent elsewhere is dropped.

**iOS (`packages/ios-custom`)**

- Probe `info`; in server mode, `ConversationDraft.quotes` mirrors `list` (keep a local cache for offline display if wanted, but the server wins), refresh on the event, reconnect and foreground.
- `QuoteCommentEditor` Done → `upload` new attachments, then `save`; trash → `remove`; keep the ephemeral editor local.
- Add `prefix`/`suffix` on capture; keep `coordinate: "source"`; add the text search fallback for web (`rendered`) anchors when the existing compatibility path fails.
- After admission, `clear { ids, reason: "sent" }`; replace `ChatQuoteDismissals` writes with `dismiss` and read `dismissed` from `list`.
- Migrate `draft.json` quotes and `QuoteMarks` once per Session.

## Verification

- `test/quotes.test.ts`: order and last-write-wins, sent tombstones against stale saves and imports, idempotent import by ID and content, limits without partial writes, content-addressed attachments and their collection, bounded dismissals.
- `packages/server/test/plugin-quotes.test.ts`: real server with the plugin over HTTP (`{"input":…}` bodies), live `rpc.custom.quotes.updated` on `/api/event`, upload/list without bytes/download, import twice, `already_sent`, `session_not_found`, `rpc.invalid_input` for reversed anchors, `invalid_data`, `rpc.unavailable` for an unknown RPC, cleanup on Session deletion.
