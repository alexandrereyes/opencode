# OpenCode iOS (custom)

Native iOS client, written in Swift, for the OpenCode backend. It talks to the same server as the TUI and the custom
web app (`packages/app-custom`), and adds no separate backend of its own.

The goal is to replace the custom web app on the phone, where it runs today as a PWA, with a native experience. It
will grow feature by feature until the phone no longer needs the web app. Other form factors (iPad, Mac) may follow
later.

This is a personal app. It is distributed only through a private TestFlight (internal testing) and will never be
submitted to the App Store.

> **Status:** "Sessões", "Nova sessão", the conversation screen and "Você" (settings) are implemented. All conversation waves (0–7) are complete
> (see [Second screen: Conversa](#second-screen-conversa)); the remaining exclusions are listed below.

## Ownership

- This package exists only on the `custom` branch. Branch from `custom` (or `origin/custom`) and target `custom`.
- It is not a Bun workspace package: it has no `package.json`, and Turbo and `bun run check` do not build it. Use the
  Xcode toolchain to build it.
- It must not require changes to the upstream-owned `packages/app`, `packages/ui`, or `packages/session-ui`, or to
  the custom web packages.
- Backend needs follow the repository order: use the existing endpoints and `packages/plugin-app-custom` RPCs first.
  Extend the plugin with a small, reusable extension point when needed. Use backend aggregation only as a last
  resort. Mobile-specific policy, such as push notifications or aggregated reads to save round trips on cellular,
  belongs in the plugin, not in shared backend packages.
- Priorities, in order: stability, simplicity, performance.

## Goals

- Connect to a server, by default the Mac reached through Cloudflare One (see [Network access](#network-access)).
  Other servers can be added by scanning `opencode pair` or entering the address and password manually, with
  credentials in the Keychain.
- Browse projects, worktrees, and sessions, including the custom navigation, archive, and session-family views.
- Read transcripts with live streaming, including Markdown, code, diffs, and tool output.
- Act on sessions: prompt and steer, manage the inbox queue, interrupt, choose the model and agent, answer permissions
  and forms, revert, and fork.
- Use the custom features exposed by the plugin, such as snippets, chats, requests, app mentions, and preferences.
- After the MVP: push notifications sent by the backend (see [Notifications](#notifications)).
- Integrate with the platform where it clearly beats the web: share sheet, Live Activities for running sessions,
  widgets, and App Intents.

Out of scope at first: iPad and Mac layouts, offline editing, and terminals (PTY).

## First screen: Sessões

The equivalent of WhatsApp's "Conversas": the same sessions, in the same order, as "Recentes" in the custom web
app's sidebar, with a different presentation. The web app is the behavior reference
(`packages/app-custom/src/shell/titlebar/sidebar-model.ts`, `sidebar-order.ts`, `sidebar-rows.ts`, and
`packages/app-custom/src/shell/notifications/session-attention.ts`) and is not changed by this work.

- **Rows:** only root sessions, without archived sessions or chats. Running state, permissions, and questions of
  subagents roll up into their root session. Managed chats (`custom.chats`) are listed only under the **Chats** chip,
  after the status chip and before repositories, like the web sidebar's separate Chats section; their requests still
  count in **Precisa de você** and the tab badge. Pinned sessions come first, then the activity order. When a session has
  several states, the priority is permission > question > running > unread.
- **Row metadata (wave 10):** the PWA sidebar's exact compact elapsed time (`0s`, `59s`, `1m`, `1h`, `1d`), floored
  at 60 seconds, 60 minutes and 24 hours, using `messageAt ?? time.created`, never metadata updates or recent rank.
  `shell/time.ts` and `shell/titlebar/sidebar.tsx` are the reference; `br.ts` has no compact overrides, so their `en.ts`
  suffixes apply in pt-BR too. A shared 60-second visible-screen timeline refreshes all rows, with natural Portuguese
  VoiceOver phrases. Below the title, `path · branch` retains the PWA/app separator: the server's home becomes `~`,
  paths truncate in the middle and branch labels at the tail, on one line. The preview, badges and avatar remain.
  Root checkouts show their current branch; detached worktrees use the folder-name fallback; non-Git paths have no
  branch and chats hide the line. Attention actions sit below their row; archived rows reuse the same metadata line.
  One deduplicated `custom.worktrees/locate` batch covers live and archived directories per existing throttled reload;
  `custom.directories/home` is cached per server after its first successful read. Both RPC contracts and implementations
  match installed `1de0005…`. Missing RPCs hide branch metadata/leave absolute paths, without affecting the list.
- **Data:** the `custom.navigation` RPC (paginated by 500), `custom.preferences` (selected repositories, pinned and
  muted sessions), `custom.subscriptions` (usage strip), and `custom.transcript/list` for previews. Previews read the
  latest messages of each visible session, as `packages/app-custom/src/agent-dashboard/preview.ts` does.
- **"Precisa de você" card:** sessions with a pending question or permission, which leave the main list while pending.
  "Permitir" and "Negar" answer the permission; "Responder" opens the session.
- **Working:** list, status and repository filters (including removing, reordering, and adding repositories), opening
  a session (the native conversation reader), Permitir/Negar, archive, pin, mute, "Marcar todas como lidas",
  "Atualizar", deletion, and the list of archived sessions (open/delete; the backend has no unarchive).
- **Swipe actions:** trailing, from left to right, **Silenciar/Reativar**, **Arquivar**, **Renomear** and
  **Excluir**; leading, **Marcar como lida** (unread only) and **Fixar/Desafixar**. There is no "Mais" action: the
  long-press menu keeps the full row action list (Abrir sessão, Renomear, Fixar, Silenciar, Marcar como lida, Excluir
  sessão). Pinning reuses `custom.preferences` (`sidebar.pin`), shared with the web, and the row moves into the pinned
  group as soon as the mutation returns. Renomear reuses the conversation menu's alert, validation (`SessionRename`),
  `PATCH /api/session/:id` and toasts, then reloads the list once the server confirms. After `build-for-testing`,
  `python3 packages/ios-custom/script/test-session-swipe.py --device … --derived … --server-url … --home …` imports two
  owned sessions (no model calls), runs `OpenCodeUITests/SessionSwipeTests` and deletes them with their pin keys.
- **Visual only for now:** "Selecionar sessões", "Configurações", and the other
  tabs except Você.
- **Unread:** a dot, with no count. Marking a session as unread is not offered, because the backend only moves the
  viewed watermark forward.
- **Muting:** stored in `custom.preferences` (`mutedSessions`, intent `sidebar.mute`) and respected by in-app alerts.
  A muted session shows a crossed-out bell, appears in the "Silenciadas" filter, and shows
  its unread dot in a neutral color. It still appears in "Precisa de você".
- **Avatar:** two-letter monogram of the repository (the first letters of the first two words, or the first two
  letters of a single word: `abacato-v2` → `AV`, `opencode2` → `OP`). The color comes from `project.icon.color`, or a
  stable choice from the project ID when the project has none, through the theme's avatar tokens.
- **Components:** native iOS components themed by tokens: Liquid Glass tab bar, `tabViewBottomAccessory` for the
  "Sessão mestra" pill, `swipeActions`, `contextMenu` for long presses, and a large title with toolbar buttons.

### Excluir sessão

**Excluir** is the outer trailing swipe action (full swipe disabled). **Excluir sessão** also appears in the row's
long-press menu, archived rows, and the conversation's stable UIKit `…` menu, including child conversations.
The native confirmation uses the web's title/buttons and its cascade/permanence warning in Portuguese, with no child
count. The web currently falls back to English for that warning because `br.ts` lacks `session.delete.confirmCascade`.

The client reads `custom.session-family/page` for cleanup IDs and sends **one** bodyless `DELETE /api/session/:id`.
The server interrupts active work and recursively deletes descendants **before** the selected session; iOS does not
send child DELETEs. These endpoints match installed custom `1042585c…`. Success animates rows away and returns an
affected conversation stack to Sessões. Failure keeps local data and reports a toast. No undo is offered.

Successful deletion clears parent/child drafts and attachments, reading positions, expansion memory, previews,
request state, alert claims and recent ranks, plus exact pin/mute preference keys (legacy IDs and server-qualified
JSON tuples). Late disappearing-editor saves cannot recreate deleted drafts. A saved-data cleanup failure after
successful deletion is reported separately. The current master remains hidden from ordinary rows and cannot be
deleted; its existing trash still archives and resets it.

Verification: **OpenCode Excluir** (`BAF8F32A-941F-4407-84A7-BF205CDC9EA6`), `ios-excluir-derived`, explicit sandbox
launch URL/password. After `build-for-testing`, run `python3 packages/ios-custom/script/test-session-deletion.py
--live-family`, then repeat with `OPENCODE_TEST_THEME=openchamber-light`. The runner creates only owned sessions in
an isolated fake repository, uses Luna 6/low, verifies a real spawned child cascade, and keeps a creation/deletion
ledger. The failure test intercepts only its named session's DELETE with HTTP 503 in Debug. Pass existing test IDs
as arguments for regressions. Screenshots, ledgers and xcresults live in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-excluir-prints/`.

Wave-10 checks use the dedicated **OpenCode Linhas** simulator and `ios-linhas-derived`: after `build-for-testing`,
run `python3 packages/ios-custom/script/test-session-rows.py`, repeat with `OPENCODE_TEST_THEME=openchamber-light`,
and pass `OpenCodeUITests/SessionReadingTests` for the existing four reading regressions (disposable owned imports,
no model calls). All launches explicitly use the sandbox URL/password. Evidence, including a read-only headless PWA
sidebar comparison and fixture-driven real-row renders for root/worktree/chat/extreme names, is in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-onda10-prints/`.

### Nova sessão from a conversation

**Nova sessão** is the first item of the conversation's `…` menu, for roots and children. Like the web's
`tab.new` from a session (`packages/app-custom/src/shell/titlebar/titlebar.tsx`), it opens the ordinary new-session
screen with the session's project and checkout already selected: the main directory, or that existing worktree with its
branch (no base branch, which only applies to a new worktree). It also preselects the composer's current model and
effort (`draft.model ?? session.model`); the agent is **not** inherited. `NewSessionOrigin` builds this context and
rides on the pushed `ConversationRoute`; `NewSessionStore.open()` applies it over Sessões' repository/Chats filter,
a restored draft and the remembered last-used category. Sending replaces the route with the created session, so Voltar
returns to the origin. Sending the inherited model/effort unchanged does not replace the default for new sessions;
choosing another one on that screen does (see [Nova sessão](#nova-sessão-wave-9)).

A chat session (under the managed chats root) selects the [Chats destination](#chats-destination) with the same
model and effort, as the web's `openChat(connection, model)` does. A project missing from the new-session list falls
back to the ordinary choice.

`OpenCodeUITests/MenuNewSessionTests` needs `OPENCODE_TEST_ORIGIN_SESSION` (a sandbox session in a listed project or
in Chats) and optionally `OPENCODE_TEST_ORIGIN_PROJECT` (the project name, or `Chats`), passed through
`test-isolated.py --environment`; it sends one short prompt with the origin's model.

## Second screen: Conversa

The conversation of one session, opened from "Sessões" (row tap and "Responder"). It replaces the provisional session
screen. The layout was approved through mockups; the mockups and the full layout briefing live outside the repository,
in `.agent-artifacts/tela-conversa/` of the working tree that produced them (`BRIEFING.md`, `r2-*`, `r4-*`, `r5-*`,
`r6-*`). The custom web app is the behavior reference (`packages/app-custom/src/session`, `src/composer`, and
`packages/session-ui-custom`), and it is not changed by this work. The backend contract for every element is recorded
in [`docs/conversation-contract.md`](docs/conversation-contract.md).

### Layout decisions

- **Header:** back; repository avatar whose ring is the **context window** (static arc of the used fraction, neutral
  color, warning color above 80%; tapping opens the usage details); title; a status line below it, like WhatsApp's
  "digitando…" (`neon-mountain · trabalhando…`, `aguardando você`); on the right, a glass capsule with the running
  agents counter (animated 5×5 pixel grid and the number of active subagents and background tasks; tapping lists them
  and opens a child session; hidden when nothing runs) and a separate `…` button.
- **Messages:** the user's messages are bubbles on the right, with undo/copy/time in a right-aligned meta row below the bubble.
  **Alexandre, 25/10:** copy (`doc.on.doc`, 48 × 44 pt target without layout size) copies the same text as the
  long-press **Copiar** (`displayText`, mentions as their labels, quotes and attachment names excluded), even while the
  bubble is folded; it shows ✓ for 1.5 s with a light haptic and no toast. Every user bubble has it: pinned, pending
  (after its queue/delete actions) and child-session bubbles. The agent's text uses the full
  width, without a bubble, and is rendered as selectable Markdown with GFM tables/tasks, highlighted code,
  formulas, diagrams and disclosures (see [Markdown rendering](#markdown-rendering)).
- **Activity groups:** follow the custom web's default **compact** preset. Consecutive tools, edits, subagents,
  nonempty reasoning and ordinary notices share one disclosure **across backend steps**. Visible assistant text,
  user messages, answered questions, compaction, model/location changes and interruption delimit the groups.
  Running questions, empty parts and successful `todowrite` do not count or split them; failed tools remain visible.
  Summaries count tool calls (reasoning only when there are no calls), deduplicate titles in first-use order, and
  use native pt-BR copy: `Usou 33 · Patch, Shell, Ler e Grep`, `Pensou 1s`, `Raciocínio(s)` and `Atualizações`.
  The app localizes the web's untranslated fallbacks: `Loaded … skill(s)` becomes `Carregou a(s) habilidade(s) …`,
  `match(es)` becomes `correspondência(s)`, and `Browser` becomes `Navegador`. Tool identifiers remain identifiers.
  Groups start **closed even while running**; streaming never overwrites a disclosure choice. Expanded consecutive
  reads share a filename list whose disclosure only wraps names, searches/skills are informational rows, and
  edit/write/patch sequences aggregate per-file accordions with `+N −M` and independently collapsed diffs.
  Complete chained file snapshots show net changes; partial patches retain their separate diffs. Stable member-based
  IDs, subgroup IDs and message anchors preserve expansion during streaming, splits and history prepend. The pure
  `ConversationActivity`/`ConversationActivityItem` projection feeds the existing single cached-measurement scroll owner.
- **Response footer:** only when the response finishes, a discreet line with model, effort, date, and copy
  (`Opus 5.5 · xhigh · 21/10 10:42 ⧉`).
- **Sticky message:** the current turn's user message always sticks below the header. **Alexandre, 22/10: user bubble
  like OpenChamber** — scrolling never collapses or expands it. **Você → Leitura → Recolher mensagens longas do usuário**
  is on by default: overflow beyond two rendered lines offers **Mostrar mensagem completa** / **Mostrar menos**.
  Tapping truncated text also expands; expanded text does not collapse on tap. There is no height animation or text
  fade. **Alexandre, 25/10:** while the bubble is pinned at the top edge, tapping its body (the prompt text and the
  bubble around it) scrolls once (0.35 s ease-out; instant with Reduzir Movimento) until the turn's first row,
  the first step even when tools and subagents precede the final-answer divider, sits right below the bubble. The
  owner (`ConversationScrollState.revealTurn`) starts a distant jump one viewport from that row, after revealing it by
  identity when it is not laid out, aims each frame at its live position, then holds it as the reading anchor and
  saves the position. While it runs, it owns the offset like a finger: corrections, older pages and settling wait;
  a touch or drag stops it; **Ir para a mais recente** and new prompts replace it. A pinned bubble already at its
  turn's start only plays a selection haptic. An inline bubble keeps its old taps, so its truncated text expands;
  pinned, expansion is the **Mostrar mensagem completa** control. Its buttons (**Mostrar mensagem completa**,
  **Ir ao trecho citado**, context cards, image thumbnails) and the actions below the bubble (redefinir, copiar) keep their
  own behavior, as does the long-press menu. VoiceOver offers **Ir para o começo da resposta** on the prompt text. The text/context area has internal scrolling capped at 40% of the view; attachments, timestamp and copy
  actions stay outside it. Attachments use 48-point square image thumbnails in a horizontal strip, no repeated image
  filename, and wrapping one-line file chips (filename up to 140 points). **Alexandre, 24/10:** while the bubble is
  folded (so **Mostrar mensagem completa** is shown), image thumbnails are hidden; expanding reveals them. File/PDF
  chips stay visible in both states, and a message that never folds (short or image-only, without quotes) always shows
  its images.
  This deliberately differs from the custom web, which hides every attachment until expanded and makes any message
  with attachments or context expandable, even when its text is short.
  **Alexandre, 24/10 (citações):** as on the web, any quote or file comment makes the bubble fold by default, even
  with short text, and the folded bubble hides those cards, their **Ir ao trecho citado** links and its image
  thumbnails until **Mostrar mensagem completa**. **Alexandre, 25/10:** a quote-only bubble (no prompt text) folds into
  one prompt-like text instead of a card per quote: a small inline quote icon, then each quote's comment (its passage
  when the comment is empty) and each file comment, whitespace collapsed and joined with ` · `, in the secondary color
  and with the prompt's two-line clamp and ellipsis; no **Ir ao trecho citado** links. **Ir à mensagem com o
  comentário** expands the carrying bubble.
  Expanding reveals the quote's separate four-line/full disclosure.
  Collapsing off shows the content immediately. VoiceOver retains full filenames and announces attached context.
  The same UserBubble renders in the list and pinned header. Sticky has no off switch; there is no other pinned banner.
- **Requests:** permission (`Quer rodar: …`, `Negar` outlined, `Permitir` filled) and question (options as buttons,
  free answer) cards inside the conversation.
- **Tray above the composer:** one tray with the running pill (`Opus 5.5 · trabalhando`, `Background`, `■ Parar`) and
  the queued messages (`Enviar agora`, edit, `×`).
- **Composer (V2):** one rounded card with the text at full width and, inside it below the text, a row with a small
  outlined `+` (attachments), `Opus 5.5 · xhigh`, the compact `MCP · N/M` pill, a flexible space and a round button:
  microphone when the field is empty (WhatsApp style); with text, send plus a compact microphone at its left
  ([Microphone beside Send](#microphone-beside-send--25-october)). The agent (`build ⌄`) opens the line below the card.
- **Triggers:** `@` context (files, sessions, agents), `/` commands, `$` skills, and `#` snippets open a suggestion
  panel above the composer; the chosen item becomes a colored token in the field. Return picks the panel's first
  (highlighted) item (see [Quote comment composer](#quote-comment-composer--24-october)).
- **Selection:** selecting text in a response shows the native edit menu with `Copiar`, `Comentar`, and `Pergunta
paralela`. A comment attaches the quoted passage above the composer (`Citações · 1`) and is sent with the message.
  The side question (`/btw`) opens in a sheet that is not saved to the conversation.
  Consecutive paragraphs, headings, list items, quotations and rules of a completed response are one
  `UITextView` (`MarkdownProse`), so a selection, copy (Markdown paragraphs, one list item per line) or comment
  spans them; spacing, nesting and quotation levels are paragraph attributes, and borders and rules are drawn by the
  view. The joined runs keep every source offset, so quotation anchors, search, file links and notes are unchanged.
  Code, tables, media, display formulas, disclosures and notes stay separate views, and a selection stops at them.
  While a response streams, each block keeps its own text until the message completes. A display formula's
  `Copiar fórmula` menu is a UIKit interaction on the formula itself: SwiftUI's `.contextMenu` inside a List row
  claimed the whole response and blocked text selection.
- **Other:** plain background, day chips (`Hoje`, `Ontem`) and one ↓ **Ir para a mais recente** control, following the
  custom web's geometry rather than an unread-message boundary. There is no new-message divider, count or ↑ pill.
  The tab bar and the "Sessão mestra" accessory are hidden inside the conversation.
- **Token colors** come from the theme, never from fixed values: dedicated semantic roles for context mentions,
  agent mentions, commands, skills, and snippets, generated by `script/generate-themes.ts` from the same web tokens the
  web composer uses where they exist (files: `syntax-property`; agents: `syntax-type`; snippets and sessions:
  `v2-text-text-accent`) and, for commands and skills, which the web leaves uncolored, from the theme's `info` and
  `accent` palette colors.

### Quote marks — 23 October

Selected assistant text remains marked with the web's focus-token background (12%; 28% while its details are open),
one-point underline (40%) and a small raised inline number at each marked range's end. Numbering follows
draft order. Markers use `quoteBadge`, add only their own inline advance and never reserve a right-hand column;
marked and unmarked wrapped blocks use the same full text width. A transparent 44 pt hit target opens the existing
details without changing layout, and VoiceOver announces **Citação 1** plus draft/sent state. The existing **Citações · N** tray
retains comments, editing and removal, now with numbered items and **Ir ao trecho citado**. Text taps and badge taps
open a compact native quote/comment sheet; links and active text selections retain their original behavior. Code and
table selections use the same source mappings. No font scale, transcript margins or user metadata-row changes belong
to this feature.

The web currently marks **draft quotes only**. Sent marks, **Ir à mensagem com o comentário** and reverse
source navigation are requested native additions, not claims of web parity. Sent marks reconstruct from ordinary
`metadata.quotes` on loaded user messages, including old sessions; no formatted-prompt parsing, annotation RPC or
thread service is introduced. Sent comments remain immutable; whole-message undo retains its existing behavior.

**Alexandre, 24/10: citou e enviou, remove.** Once the server acknowledges a prompt or command (successful admission,
including queued delivery; not the send tap), its quote IDs join a per-server, per-Session local list
(`Application Support/OpenCode/QuoteMarks`, 200 Sessions, cleared by Session deletion) and their response marks
disappear. A rejected send keeps the draft quotes and marks. Sent marks from older sessions or other clients stay until
**Remover marcação**, a destructive, unconfirmed action in the sent **Citação · N** sheet. Neither path rewrites
`metadata.quotes` or uses a server API, so the web is unaffected. The bubble's quote card and **Ir ao trecho citado**
remain: navigation briefly draws the dismissed passage's background (no number, so no reflow) for three seconds.
Restoring a queued or undone message puts its quotes back into the draft, where they are marked again.

New native anchors retain exact UTF-16 source coordinates with an optional `coordinate: "source"` discriminator;
untagged old native anchors remain readable, and web rendered-text anchors use the existing Markdown source mapping.
Exact offsets must still match: streaming append survives, edits before/inside the quote do not silently relocate it.
Unanchored legacy text resolves only when unique. The metadata index caches decoded user quotes independently of text
streaming; only changed marks/parsed blocks recompute range projections. TextKit draws the background/underline;
the inline numbers participate in native wrapping with a capped 12 pt font and raised baseline. A rendered/original
UTF-16 map excludes those decoration characters from copy, source selection, comments, search and file-link ranges.
Adding/removing markers invalidates measured geometry, while active-state changes reuse measurements. Explicit source jumps reuse the sole reading/scroll owner and its
five-page continuation affordance; unavailable/changed sources retain the comment and report a pt-BR notice.
Session IDs are local to each conversation, including children; there is no invented cross-session source identity.

The source audit is `.agent-artifacts/citacoes/WEB.md`. Verification uses only **OpenCode Citacoes**
(`C8FF24A6-89EE-42D4-B7E2-4BEDBE5E5060`) and **OpenCode Citacoes Light**
(`473B6A95-46F4-4A9C-AF04-0992216DC2D2`), iPhone 18 Pro/iOS 27, sandbox **4184** and
`$TMPDIR/opencode/ios-citacoes-derived`. After `build-for-testing` with `COPY_PHASE_STRIP=NO`, run
`python3 packages/ios-custom/script/test-quotes.py prepare`, then `test --label dark` and
`test --device 473B6A95-46F4-4A9C-AF04-0992216DC2D2 --theme openchamber-light --label light` concurrently.
Use separate labels/results, never overlapping launches on a simulator. The runner imports only owned synthetic
histories in its fake repository, restores only an owned simulator draft for full-passage visual comparison, supplies
explicit sandbox credentials, and deletes private xctestrun files. Finish with `cleanup`. No model call, physical
device or production request is needed for those fixtures. Explicitly selecting `OpenCodeUITests/QuoteSendingTests`
adds one tiny real Luna-6/low send per theme in the worker's owned Session; the runner verifies the persisted comment,
model and exact anchor from the backend afterward, and the test checks that the acknowledged quote leaves no mark,
also after relaunch. The rejected-send case uses the DEBUG prompt-failure transport, so run the sandbox on **4183**
(`--server-url http://127.0.0.1:4183 --home …`); the runner resets only its removable fixtures' local dismissals. `profile-scrolling.py --server-url … --home …` accepts this sandbox.
The quotation runner also accepts `--server-url`, `--home`, `--derived`, `--evidence` and `--content-size` for an
isolated worker. It validates sandbox ownership before importing data. Inline-marker checks compare marked/unmarked
text widths, independent markers in one paragraph, the 44 pt targets, and original UTF-16 copy/selection offsets.
Both-theme web/native captures and result bundles live under `$TMPDIR/opencode/ios-citacoes-prints/`.
The five quote UI cases pass in both themes; five focused UIKit/cache tests and all 320 Kit tests pass. Debug/Release
builds are warning-free. The existing five-iteration conversation scrolling test passes (3.155 s mean process CPU).
The 12-second 300-message simulator trace kept p95 at **16.67 → 16.67 ms**, with process CPU **3063 → 3008 ms**,
main-thread CPU **2620 → 2986 ms**, and display-link stall ratio **4.72% → 3.51%**. These are individual shared-Mac
samples, not a claim of improved CPU or physical-device frame performance. Captures compare the real sandbox web
renderer against the native production views. Both real-send checks also passed, with Luna/low, zero tool calls and
marks retained after relaunch. No physical device, production mutation or new backend API was used.

### Quote comment composer — 24 October

**Alexandre, 24/10: o comentário usa o mesmo compositor.** The **Comentário** sheet hosts the message composer's own
`ComposerEditor`, configured by `ComposerComment` (placeholder, the message draft's other attachment bytes for the
shared 25 MiB limit, and the commit action), instead of a separate text field. It keeps the same card, `ComposerTextView`
(label **Comentário**, identifier `comment-composer`), `@`/`$`/`#` suggestions and tokens, focus, dictation (hold, lock,
pending download; a finished transcription refocuses the comment) and the **+** menu with **Fotos** and **Arquivos**.
It omits the model/effort, MCP and agent selectors (they belong to the message, as on the web, whose comment editor has
none), `/` commands (they only run at the start of the message itself; the web's comment editor has no commands either)
and **Expandir compositor** (the sheet already rises to full height with the keyboard; a fullscreen cover over a sheet
would add a second presentation for no extra room). The round action shows a checkmark, **Concluir comentário**
(`comment-done`), when there is content; Shift+Return does the same. **Concluir** in the bar stays the only commit and
**Cancelar**/swipe-down still discard everything.

The sheet edits an ephemeral `ConversationDraft` (`commentEditor(_:)`) that never saves a snapshot; new attachment files
wait in its own `tmp/QuoteComments/<uuid>` directory. Reopening a quote lends it clones of that quote's attachments
(`lend(_:to:)`). Concluir (`commit(_:from:)`) moves new files into the message draft (`DraftPersistence.adopt`), stores
them as `quoteID` attachments, writes web-shaped `commentPrompt` image/path parts and removes files the comment dropped;
the editor's directory is then deleted. Sending is unchanged: images travel inline after the prompt's own files (or as
staged paths for models without image input), other files as staged paths, so they appear in the bubble and in
`Comments on earlier assistant messages`. A PDF in a comment is always a staged path now (the previous inline branch
kept a `path` part with an empty path and never delivered its bytes). Multiple quotes, mark removal after an acknowledged
send, rejected-send retention and the optimistic/pending bubble are unaffected. The web reference is
`app-custom/src/composer/chat-quotes.tsx`, whose comment editor accepts pasted/dropped attachments but has no picker.

Verification used **OpenCode Comentario** (iPhone 18 Pro/iOS 27), its own DerivedData and sandbox **4183** (the dictation
fixture accepts only 4177/4183). `test-quotes.py` ran `OpenCodeUITests/QuoteHighlightTests` (now including
`testCommentUsesTheComposerWithoutSelectorsAndCancelKeepsNothing`) and
`QuoteSendingTests/testCommentPhotoFromPlusTravelsWithTheQuote` (one Luna 6/low send; it needs a photo added with
`xcrun simctl addmedia`) in both themes, plus `DictationUITests` with
`testCommentDictationLandsInTheCommentAndConcluirKeepsIt` (`-OpenCodeDictationComment`) and `ComposerEditingUITests`.
Hosted `QuoteCommentTests` cover lending, adoption, dropped files, the never-saved editor and cancellation.
`profile-composer.py` with the `comment-*` scenarios showed no regression (simulator, final build, two interleaved
runs each on the shared Mac, medians before → after): plain busy p50/p95 7.7/10.3 → 7.1/9.9 ms, main CPU 1.60 → 1.47 s,
no hitches; mentions 9.0/99.3 → 7.7/97.2 ms, 28 → 24 hitches (the keyboard trait relayout described above);
suggestions 9.3/12.6 → 9.2/13.2 ms, one hitch each. An earlier batch varied by about ±1 ms p50 in both directions.
Captures are in `$TMPDIR/opencode/ios-comment-composer/prints/`.

**Return in suggestions (Alexandre, 24/10).** In both composers (message and comment), Return on the software or a
hardware keyboard picks the suggestion panel's first, highlighted item for `@`, `$`, `#` and `/` exactly as a tap
does, instead of a line break. `ComposerSuggestions` records that item in a non-observed `ComposerSuggestionReturn`
once its results for the current trigger have loaded, so typing still does not re-render the composer.
`ComposerReturn.selectsSuggestion` gates it: no marked text (composition keeps Return), panel open, and an item loaded
for the trigger still being typed. With no panel, or while it is loading (the 180 ms debounce plus the request) or empty,
Return keeps its previous meaning (line break; Shift+Return still sends). The web
(`app-custom/src/composer/suggestions/machine.ts`) selects its active item on Enter/Tab too, but swallows Enter while its
list is empty or loading; iOS deliberately keeps the line break there. Dictation inserts through the draft, not Return,
and is unaffected. Covered by the Kit truth table, `ComposerEditingUITests/testReturnPicksTheLoadedFirstSuggestionAndOtherwiseBreaksTheLine`
(`$` picked, line break without a panel, empty `#` list and an unloaded `@` query) and the comment/message checks in
`testCommentUsesTheComposerWithoutSelectorsAndCancelKeepsNothing`. Interleaved profiles stayed flat (plain busy p50
7.1 → 6.0 ms, suggestions 8.1 → 8.5 ms, mentions 8.3 → 8.0 ms).

### MCPs in the conversation — 23 October

The approved B layout puts a compact glass pill immediately after model/effort, without adding a composer row or
changing its height. Its success/neutral dot and `N/M` count reflect confirmed connections. Tapping opens a small
glass **MCPs** panel above the composer; the shared wave-9 switches wrap into rows, never a horizontal strip.
Outside taps, conversation scrolling and keyboard dismissal close it. Opening/toggling does not replace the draft,
move its selection or take keyboard focus. VoiceOver reads **MCPs, 1 de 5 conectados** and a modal switch container.

`GET /api/mcp?location[directory]=…` loads lazily for the viewed Session's own Location (including children, chats and
the master), then refreshes on panel opening. Empty/unsupported Locations have no pill or error row; loading appears
only inside the panel. Connect/disconnect uses bodyless `POST /api/experimental/mcp/:server/connect|disconnect` with
the same Location query, shows pending, then verifies the server's state with a fresh list. These routes, responses
and Location semantics were checked against installed backend `1042585c285c25d4b5d4fd292d0b7eb5fb7c470e`.
Conversation MCPs need no `/api/config` read. Failed actions use the existing toast; login-required switches only
explain web-app authentication and never start OAuth.

Both this panel and **Nova sessão** now sort connected first, then `codex-computer-use`, then `safari-devtools`, then
alphabetically, applying those priorities independently in connected and nonconnected groups. Order is captured when
the chips become visible and retained through pending/status changes and refreshes; reopening re-sorts. New-worktree
previews still derive their displayed connection state from saved intent/configuration defaults, not root runtime.

Verification uses only **OpenCode Chips** (`9C92A4EB-5CD9-4F31-9A79-707A18D27976`, iPhone 18 Pro/iOS 27),
`ios-chips-derived` and explicit sandbox URL/password. After `build-for-testing`, run
`python3 packages/ios-custom/script/test-mcp-chips.py --label dark` and repeat with
`OPENCODE_TEST_THEME=openchamber-light` and a different label. The DEBUG-only, loopback-gated
`-OpenCodeMCPFixture conversation|pending|empty|unsupported|new-session` renders production views using a client
that rejects unknown requests and never forwards MCP operations. `--live` imports/deletes only its own history in a
fake repository and toggles **only safari-devtools off and back on**, verifying every other MCP remains unchanged.
Screenshots, logs, xcresults and sanitized verification ledgers live in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-chips-prints/`.

The eight MCP checks pass in both themes: three hosted store tests, four stubbed UI cases and one live Safari-only
case. They cover ordering/reopening, pending/confirmation, counts/hiding, auth/failure toasts, outside/scroll/keyboard
dismissal and preserved draft/focus/geometry. The Kit suite passed in Debug and optimized Release; the app built without
warnings (`COPY_PHASE_STRIP=NO` avoids re-stripping already signed embedded frameworks/extensions). Compared with the
mockup, this uses native Liquid Glass and a rounded panel without a drawn speech-bubble tail; the generator's stray
dash/dot are absent. `pill-closed`, `panel-open`, `toggle-pending` and `new-session-order` captures exist in both themes.

### App mentions — 24 October

Like the web, `@` offers the Mac apps of the enabled app MCPs (**Apps**: Computer use apps of
`codex-computer-use` and **Safari DevTools** of `safari-devtools`), from the plugin RPC `custom.app-mentions/list`.
Apps match by name only. Choosing one inserts an atomic `@Name` token (`ComposerTokenKind.app`); sending writes the
web's `metadata.apps` parts (`{type:"app", content, start, end, app}`) and appends the web's `formatAppContext`
instruction to the prompt text. Web messages restore their app tokens from `metadata.apps`; quotes carry them as
`app` parts.

Listing Computer Use apps takes about 2.5 s, so it never runs in the typing path. `ComposerAppMentions.shared` keeps
one listing per server and Location for a minute (`ComposerAppCache`), keyed by the enabled app MCPs. A conversation
lists as soon as its MCP list loads or changes; `@` uses what is cached, and an open panel merges a listing that
arrives later without re-debouncing or clearing the item Return would choose. A changed enabled set (disconnect,
reconnect) lists again; no enabled app MCP lists nothing. A new chat or worktree only records MCP intents, so its
request sends `enabled`; the plugin then answers Computer Use from its latest listing kept in plugin storage (shared
by all Locations), until the chat exists and connects the MCP.

After `build-for-testing`, `script/test-app-mentions.py` runs `ComposerAppMentionsUITests` (or the test IDs given)
against an isolated sandbox: `OPENCODE_TEST_SERVER_URL`, `OPENCODE_TEST_HOME`, `OPENCODE_TEST_DERIVED`,
`OPENCODE_TEST_SIMULATOR`, `OPENCODE_TEST_EVIDENCE`, `OPENCODE_TEST_THEME`. It imports one disposable Session in
`<home>/repos/app-mentions`, connects the real `codex-computer-use` there (only `list_apps` runs; no app is
controlled and nothing is sent), restores the MCP state and deletes the Session.

### Case-insensitive suggestions — 24 October

Every trigger ignores case. `$`, `#`, `/`, agents, references and apps rank locally with case- and
diacritic-insensitive folding; files come from `/api/fs/find`, whose fuzzy search ignores case too. Session titles
are searched by the server with SQLite `LIKE`, which ignores case only for ASCII letters, so a query with other
cased letters (Ã, Í, Ç…) is also sent lowered, uppercased and capitalized (`ComposerSources.caseVariants`) and the
results are merged by recency; accents are still matched as typed there ("sessao" does not find "Sessão"). The web
composer does the same in `composer/session-search.ts`.

After `build-for-testing`, `script/test-composer-case.py` (same environment variables as `test-app-mentions.py`)
creates a fake repository, two disposable Sessions and one snippet, runs `ComposerCaseUITests` (`@`, `$`, `#`, `/`
in several cases, then Return on `#COMMIT`) and removes them.

### Composer editing stability — 23 October

The live `UITextView.textStorage` owns editing. Native edits publish a lightweight content revision; SwiftUI only
loads storage for an external document replacement and never echoes the cursor back during typing or selection.
Suggestion insertion and rich paste replace only their affected range and join native undo/redo. Marked text defers
external loads, keyboard-trait changes and typing-attribute resets. The compact editor uses TextKit's existing content
size rather than requesting an unbounded layout on every keystroke. Content-height changes invalidate intrinsic
size, including TextKit layout that completes after SwiftUI's first measurement. Without this notification a restored
500-line draft could remain 22 pt tall despite 11,022 pt of content; focus events sometimes masked the issue.
The restoration regression covers both focused and unfocused editors and waits for layout rather than a fixed delay.

Each skill/file/agent/reference/session/command/snippet is one attachment character, with a cached rendered label and
semantic theme colors (no attachment view providers). UIKit therefore owns atomic cursor movement, double-tap,
selection and deletion. Document expansion happens at serialization/persistence/copy boundaries: backend wave-3
encoding, legacy draft JSON and full-label UTF-16 cursor offsets are retained. Copy publishes plain labels plus a
structured rich document representation; pasting that representation restores tokens. Adjacent identical legacy token
attributes are split back into individual tokens rather than silently dropping their metadata.

The custom web reference is `app-custom/src/composer/editor/codemirror.ts`: its current implementation uses mark
decorations and drops metadata for partially edited mentions. Single-character atomic native tokens deliberately
follow the requested iOS behavior; the wire representation remains the same.

Verification uses **OpenCode Composer** (`8A5B01F4-0114-43FB-A1E4-0E8F2679473B`, iPhone 18 Pro/iOS 27) and
`$TMPDIR/opencode/ios-composer-derived`. After `build-for-testing`, `python3 script/test-composer.py` runs hosted
editing regressions; append `OpenCodeUITests/ComposerEditingUITests` for native suggestion/selection/restore tests,
and repeat with `OPENCODE_TEST_THEME=openchamber-light`. Every launch explicitly selects the sandbox URL/password.
The DEBUG-only `-OpenCodeComposerFixture` uses the real editor/suggestion views, local skill/file sources, and a
transport that rejects every HTTP request. It is also available for server-free physical-device diagnosis.

The recorded baseline reproduced partial token deletion (`$sample` becoming `$sampl`) and lost metadata on undo.
Thirty native insertions per document measured the synchronous main-thread `insertText` + `layoutIfNeeded` interval:
1/100/500 tokens (50/5,090/25,890 UTF-16 units) averaged **2.58/6.56/18.49 ms before** and
**1.56/2.14/1.81 ms after** in the initial comparable runs. These are local simulator samples on a shared Mac, not
physical-device or end-to-end latency claims. The performance regression also checks that attachment identities and
the external document revision remain unchanged while typing. `COMPOSER_PROFILE=1` requests a separate longer
Time Profiler run; profiling overhead is excluded from those numbers. Evidence and before/after videos are under
`$TMPDIR/opencode/ios-composer-prints/`.
The valid `final-time-profiler.trace` records 27.86 seconds and 5,963 samples; all 84 sampled editing-callback stacks
contain neither full-document decoding nor attachment construction. `time-profiler-summary.json` and the exported
table retain that inspection. The first all-processes baseline trace failed with simulator dylib-overlap errors;
the before/after latency comparison uses the explicit monotonic measurements above, not sampled CPU attribution.

The four native UI cases pass in both themes, including dragging a selection handle from a token across adjacent
prose. The Kit suite passes 232 tests, all 11 app-hosted editing/key-command tests pass, and Debug/Release builds are
warning-free. Seven real-sandbox regressions cover new-session selector/focus restoration,
software Shift+Return, tokenized comments, and all four session-reading cases. Enable `COMPOSER_SANDBOX_REGRESSIONS=1`
when selecting those cases in the runner; it imports/deletes only its disposable sessions. The tiny keyboard/comment
sends use Luna 6/low, and `comment-wire.json` verifies the received file/skill payload and UTF-16 mention offsets.
Marked text, adjacent replacements and theme changes during composition are exercised through native text-input
APIs. Microphone/audio dictation was not exercised; no physical device was needed to reproduce the bug.

**Typing without re-rendering the conversation — 24 October.** A keystroke used to bump `contentRevision`, which
`ComposerTextView.updateUIView`, `hasText`, `isEmpty` and `trigger` all read: every key re-evaluated the composer card,
`ConversationComposer` and `ConversationView` (via its trigger `onChange`), diffed the transcript `List` and remeasured
its text views' baselines (`UITextView._baselineOffsetsAtSize`). Now `hasText`, `isEmpty` and `trigger` are stored and
published only when their value changes; the editor observes only `editorRefresh`, bumped when an update deferred
during composition must run, or when stale storage must reload. The conversation observes the trigger in a leaf view,
and `ConversationMCPStore.close()` no longer notifies when already closed. `ComposerDocument(editor:)` and
`validTokens` bridge the string once. Highlighting, tokens, suggestions, dictation, focus and fullscreen are unchanged;
the comment sheet (`QuoteCommentEditor`) shares the fix.

The DEBUG `-OpenCodeFixtureAutoType idle|plain|mentions|suggestions|long|toggle` driver (offline conversation fixture) types
200 steps through `UITextInput` at 100 ms and records main-run-loop busy time per keystroke and display-link frames;
`script/profile-composer.py --simulator <udid>|--physical --derived … --evidence …` runs it (`--trace` adds Instruments).
iPhone 14, `-O` Debug build, medians of two runs, before → after:

| Scenario | Busy p50 / p95 per key | Main CPU (200 keys) | Frames > 25 ms | Hitch time |
| --- | ---: | ---: | ---: | ---: |
| Plain prose | 36.4 / 39.6 → 11.9 / 14.1 ms | 7.37 → 2.49 s | 228 → 0 | 186 → 0 ms/s |
| `@file` + `$skill` tokens | 36.3 / 98.3 → 14.5 / 100.6 ms | 8.31 → 4.61 s | 186 → 46 | 200 → 77 ms/s |
| Suggestion panel open | 48.2 / 49.2 → 15.6 / 18.5 ms | 9.70 → 3.23 s | 214 → 2 | 303 → 3 ms/s |
| 200-line draft, 200 tokens | 36.6 / 38.5 → 13.7 / 16.3 ms | 7.38 → 2.83 s | 214 → 0 | 170 → 0 ms/s |

The remaining mention p95 is the keyboard itself: opening/closing a query toggles autocorrection/QuickType traits,
whose keyboard-height change relayouts the screen (~100 ms on the iPhone 14). Deferring `reloadInputViews` out of the
SwiftUI update did not change it; keeping the traits stable would change mention behavior and was left as is.

Changing the editor's editability during send is deferred outside SwiftUI's graph update and applied only when its
value changes and the UIKit view still represents that draft. `UITextView.setEditable(false)` can synchronously resign
focus and ask the hosting view for its next responder; doing that inside `updateUIView` reenters AttributeGraph and
freezes repeated sends. A focused-editor hosted regression exercises disabling, re-enabling and refocusing.

**Expanded composer after send:** a successfully acknowledged prompt (including steer/queue), backend command or
local compact operation closes the fullscreen composer using the normal cover dismissal. That dismissal does not
restore keyboard focus; manual **Recolher** retains its existing focus restoration. A failed operation keeps its
draft and expanded presentation. Expansion is runtime-only and is not part of `DraftSnapshot` or persisted JSON.
New-session success opens the conversation compact; if a Session was created but submission failed, its restored
draft inherits the expanded presentation. The initial master-session flow follows the same rule. Side questions
use their own nonexpandable input/sheet, rather than this fullscreen composer.

Run `COMPOSER_COLLAPSE=1 COMPOSER_SANDBOX_REGRESSIONS=1 python3 script/test-composer.py
OpenCodeUITests/ComposerCollapseTests` in both themes. It checks success and relaunch, rejection with continued
editing, and a new-session root send. The rejection transport is DEBUG-only, restricted to one disposable sandbox
Session's prompt endpoint; the two real sends use Luna 6/low. It seeds only the dedicated simulator's new-session
draft, creates no worktrees, and removes its Sessions afterwards.
Follow-up verification: all three collapse cases pass in dark/light, the four existing composer UI cases and all
12 hosted composer/key-command tests pass, and `swift test` passes 253 tests in the concurrent working tree.
Debug/test and Release builds are warning-free. Videos/results are `collapse-dark-pass.*` and `collapse-light-pass.*`
under the composer evidence directory; cleanup ledgers list the disposable Sessions removed after each run.

### Jump to latest — 22 October

**Alexandre, 22/10: novas mensagens como no web.** The custom web has no `Novas mensagens` divider or upward unread
jump. `ConversationScrollPlan.Viewport` mirrors `app-custom/src/session/timeline/interaction.ts`: show ↓ only with
more than 1 point of overflow and a distance from the bottom **strictly greater than `max(400 pt, viewport height)`**.
This is independent of author, tool-only steps, streaming, watermark and parent/child status. Being near the bottom
hides the button without silently resuming follow; arriving at the real end uses the web's 0.5-point tolerance.

Tapping **Ir para a mais recente** clears reading restoration/selection pause and asks the existing single scroll
owner for one end animation; later height changes follow without replaying it. Submitting a prompt/command or a
question reply resumes the same follow mode before the request finishes, without an extra animation. Streaming while
reading retains the bookmark. Dismissal is purely geometric, so scrolling up can show the button again without new
messages. Per-session native reading persistence and parent/child return behavior remain independent of read receipts.

Opening the route acknowledges that session's observed `time.idle` through `POST /api/session/:id/view` with `{idle}`,
without waiting for catalogs, pagination, bottom or a visible response. Root and child acknowledge only themselves.
The request/payload exist unchanged on installed `1de0005…`; there is no message-level receipt and no backward move.
Deduplication remembers the requested watermark and releases it on failure, like the web. No `custom.preferences`
write or local unread boundary is involved. The original wave notes below describe historical checks; unread skips
and seed-reset instructions are superseded by the deterministic jump tests.

Verification uses only **OpenCode Novas** (`66EA82DF-D048-4E54-85D0-FB32A02CEC20`), `ios-novas-derived`, and explicit
sandbox launch arguments/password, including hosted tests. After `build-for-testing`, run
`python3 packages/ios-custom/script/test-novas.py --label decisions-follow`; `--live` plus
`OpenCodeUITests/NewMessagesTests` adds owned fake-repository parent/child scenarios with Luna 6/low. The runner never
resets seeds, answers seeded requests, or changes the sandbox service. Its ledger lists retained owned sessions.
Pure viewport tests cover thresholds, no overflow, bounce, growth, dismissal and end tolerance; hosted tests cover
acknowledgement before catalogs and root/child isolation. The follow regression still requires zero backward movement
and exactly one explicit end animation. Evidence and comparisons live in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-novas-prints/`.

### Waves

**All waves below are complete.** Wave 7's native banners are foreground-only, not system notifications or APNs.

Each wave is implemented by a fresh agent, ends with a warning-free build, passing tests, and real simulator
screenshots against the sandbox in both themes, and is reviewed before the next one starts. The waves are committed
on one feature branch and integrated into `custom` together at the end. Order: 0–4, then 6, 5, and 7 (wave 5's
search navigates to messages and reuses wave 6's position restoration).

| Wave                     | Scope                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0. Contract and fixtures | Map the endpoints, events, and RPCs of every element into `docs/conversation-contract.md`; seed reproducible conversation states in the sandbox; capture sanitized JSON fixtures.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| 1. Reading               | Open from "Sessões"; header with context ring, status line, and agents capsule; bubbles, Markdown, code blocks, step groups, tools, subagents, footer; sticky message, day chips, `Novas mensagens`, scroll-to-bottom; older pages; live updates; marks the session viewed; opens child sessions from subagent cards (read-only, no composer). The composer appears in its V2 shape but is not functional yet.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 2. Acting                | Composer V2 with send and model/effort/agent selection; running tray with stop and background; queue with `Enviar agora`, edit, and remove; permission and question cards; agents list from the header capsule; context usage details. Model picker as in the web app (search over name, ID, and provider; favorites; default model; model and provider visibility); reusable toasts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| 3. Advanced composer     | `@ / $ #` triggers with the suggestion panel and tokens; commands; snippets; attachments through `+`. Full-screen composer; drafts (with tokens and attachments) kept across app launches.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| 4. Selection             | Native edit menu on responses; comments with quotes sent with the message; side question sheet. Copy a user message from its long-press menu.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| 5. Session and reading   | Rename and archive from the `…` menu; session details sheet (project, worktree, branch, +/−, MCP/plugin/skill/LSP configuration); search in the conversation (loaded messages, then older pages on demand; there is no server-side search); incompatible-server and missing-directory notices. V2 removed `todowrite`: its historical parts remain suppressed. Native components, approved from real screenshots without mockups. |
| 6. Reading continuity    | Final-answer divider with the web rule (`finish stop`, completed, no error or retry, after activity, prefers `final_answer`, possibly several per exchange). Reading position per server and session (follow the tail, or message ID plus offset), kept in memory and across launches, restored with cancellable paging and a fallback to the tail. Selecting text pauses following the tail. Expanded tools remembered per session (IDs only). "Ir às novas mensagens" when unread messages are above. Shift+Return sends and Return alone inserts a newline, on hardware keyboards (`UIKeyCommand`) and on the software keyboard through the private `UIKeyboardImpl` state (`isShifted` without `isAutoShifted` or `isShiftLocked`), isolated in one file and falling back to a newline; remove it if TestFlight processing rejects the build (`ITMS-90338`). Edge-swipe back keeps working. |
| 7. Subagents and alerts  | Composer in child sessions, keeping the child's agent and with no notice; replies sent after the child delivered its result stay in the child (automatic delivery to the parent would need backend work and is out). In-app banner, tappable, when another session finishes, fails, or needs you, respecting mutes, ignoring child completions, deduplicated. Light haptics on explicit actions.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |

Out of scope for this screen for now: "Alterações" and "Arquivos" in the `…` menu,
and the fork action on messages.

### Pending and optimistic user bubbles — 24 October

The custom web is the reference (`session-ui-custom/src/actions.ts`, `message/message-content.tsx`,
`components/message-part.css`, `app-custom/src/session/composer/region.tsx`, `client/src/solid/data.ts`). Undelivered
user **steers** render as user bubbles below the transcript, in admission order; queued items stay in the tray.
`PendingInputs.status` ports the web's `DataPendingStatus`: `starting` (promoted at the next idle boundary),
`steering` (behind input this execution already delivered), `stranded` (an execution ended without it) and `queued`.
The web drops the sent-message accent only while `steering`/`stranded`. **Intentional difference (Alexandre, 24/10):**
iOS uses the pending style (`userBubblePending*` roles, generated from `v2-background-bg-layer-02`/`v2-text-text-base`)
and the **Pendente** time prefix for every undelivered bubble, including `starting`, optimistic and child rows, from the
tap until delivery. Actions still follow the web: every non-queued status
replaces **Redefinir para este ponto** with **Mover para a fila** (`PATCH …/inbox/:id` `{delivery:"queue"}`) and
**Excluir** (`DELETE …/inbox/:id`), in the meta row and the long-press menu, without confirmation. Child sessions show
their pending steers without actions, as the web passes no pending actions there. Delivery turns the row into
the ordinary sticky bubble with the same ID. The web has no "back to composer" action on the bubble; a steer moved to
the queue can be edited from the tray. Its English copy (`Pending`, `Move to queue`, `Delete`) has no pt-BR keys.

Sending in an existing conversation is optimistic, like the web's `session.prompt`: the admission ID is minted first,
the row appears and the composer clears on tap, and a refresh after acknowledgement reconciles that ID with the inbox
or transcript. A failed send retracts the row, restores text, attachments, quotes and context into the composer (disk
keeps the unsent draft meanwhile) and keeps the existing error/toast; a retry reuses the ID. Inbox actions wait until
the server knows the item. There is no success toast. New sessions still wait for creation (and, in Chats, for
allocation/claim/MCPs) on the new-session screen. Staged attachments show as filename chips until the echo arrives.

Verification uses **OpenCode Pendente** (`FDB1B4E0-2C49-4642-AB8D-88AA57C38F9A`) and **OpenCode Pendente Light**
(`C84000CE-14E9-464E-8B6B-259E0CA4E8B9`), an isolated `custom-sandbox.ts` home on port 4193 and `ios-pendente-derived`:
`script/test-pending.py prepare --label L`, then `test --label L [--theme openchamber-light --device …]`. Steers are
admitted with `resume:false`; the DEBUG-only, loopback-gated `OPENCODE_TEST_PROMPT_FIXTURE=<session|*|create>:<ms>:<admit|fail>`
delays the app's admission or new-session creation, then admits without waking execution or rejects it. This and the
deletion, revert and composer-failure fixtures accept any loopback sandbox port except 4096/4178
(`ServerConfiguration.isolatedTestSandbox`); the old 4177/4183 allowlist silently disabled them on agents' own sandbox
ports, which is why `ComposerCollapseTests/testFailedSendKeepsExpandedDraftEditable` sent for real and failed. Only the
delivery case makes one tiny Luna 6/low call. With the same build, a probe measured tap-to-bubble at 0.14–0.21 s
(immediate admission) and 3.2–3.3 s (3 s admission delay) before, and 0.06–0.08 s in both cases after; on the phone,
the old path also waited for the agent/model selection, prompt and full conversation refresh round trips.

### Desfazer mensagem enviada

The backward-arrow action on delivered root/master user messages, including their sticky presentation and long-press
menu, uses the web's **Redefinir para este ponto** label. **Alexandre, 24/10:** it, and the **Desfazer** button of the
bar above the composer, first ask in a native alert (**Redefinir para este ponto?**, explaining that the message returns
to the composer, later ones stay hidden until **Refazer**, and sending a new message deletes them for good) with
**Cancelar** and destructive **Redefinir**; **Refazer** stays immediate. The web acts without confirmation. Child
bubbles omit it. Undo hides
the selected message and later history, restores its text/tokens, attachments, quotes and file/comment context into the
composer, and preserves the selected model/agent. **Refazer** advances one message at a time, then restores all history.
The progress row covers descendant planning, Session rollback and pending-inbox cleanup. A partial child failure is
reported explicitly. Submissions wait for rollback to settle; new admission commits the parent boundary before model
selection, just like the web. Draft restoration also survives app relaunch.

The cascade is orchestrated by the client: `custom.session-family/revert` only returns boundaries, then children are
staged sequentially with `files:false`, followed by interrupt/wait and ordinary file-enabled staging of the parent.
Children are retained; their drafts, reading state, pins and mutes remain intact. These contracts match installed custom
`1042585c…`. See [the contract](docs/conversation-contract.md#sent-message-undo-23-october) and
`.agent-artifacts/desfazer/WEB.md` for the source audit and the live web request trace.

Verification uses only **OpenCode Desfazer** (`8AE067E9-2D79-4BBF-80A5-A8965804CB6E`, iPhone 18 Pro/iOS 27),
`ios-desfazer-derived` and explicit sandbox URL/password. `script/test-revert.py prepare --role dark|light|web` creates
isolated Git repositories and parent/child Sessions using Luna 6/low. After `build-for-testing`, run
`script/test-revert.py test --role dark` (then light), and `verify` to check staged parent/child boundaries and the real
child-created file's rollback. `OPENCODE_TEST_SERVER_URL`, `OPENCODE_TEST_HOME`, `OPENCODE_TEST_DERIVED`,
`OPENCODE_TEST_DEVICE`, `OPENCODE_TEST_EVIDENCE` and `OPENCODE_REVERT_LEDGER` select another isolated sandbox; run the
roles sequentially, since they share one ledger. Creation and verification records are in `.agent-artifacts/desfazer/LEDGER.json`.
Screenshots, xcresults and sanitized evidence are under
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-desfazer-prints/`.
The six undo UI cases pass in both themes, including the pinned header, and each native parent's rollback patch matches the live web twin byte for
byte. Children remain staged with empty file diffs; a separate real prompt verifies irreversible history commit.
The Swift package suite passes 289 tests; three hosted tests cover replacement/persistence and serialized duplicate
requests without overwriting edits. Simulator Release verification uses `COPY_PHASE_STRIP=NO` to avoid stripping the
already-signed VoiceActivity extension; this is a command-line verification option, not a project setting change.

Grouping verification uses **OpenCode Grupos2** (iPhone 18 Pro / iOS 27) and `ios-grupos2-derived`. After
`build-for-testing`, run `python3 packages/ios-custom/script/test-groups.py`, then repeat with
`OPENCODE_TEST_THEME=openchamber-light`. It supplies explicit sandbox credentials, imports/deletes only its own
sanitized 19-step histories (33 tools, including eight patches and one patch failure; no model calls), and includes
the existing session-reading regressions plus grouped-tool transport parity and parent/child expansion continuity.
The older working fixture expects `Usou 5 · Ler, Agente e Editar` and a compact `Ler infra.md` row; continuity verifies
expanded reasoning, since ordinary reads no longer expose their output. Tests reopen owned sessions by ID and scroll
through the transcript gutter to avoid the pinned bubble's inner scrolling. The tool order/states come from a GET-only production child-session read;
the fixture contains neutral content and paths. Native collapsed/expanded/running captures and headless PWA comparisons
are in `$TMPDIR/opencode/ios-grupos2-prints/`; the rule audit is `.agent-artifacts/agrupamento/WEB.md`.

Wave 1 must already render text in a way that supports a custom selection menu (wave 4), and the composer must be
able to hold attributed tokens (wave 3), so later waves do not rewrite earlier ones.

### Markdown rendering

OpenChamber revision `801f59b5ba2cf4be0145edc8451c1593169898bb` is the visual/capability reference.
`MarkdownBlocks` projects CommonMark/GFM plus footnotes, math and nested `<details>` into typed blocks while
retaining rendered-to-source UTF-16 selection mappings. H1–H6 use the shared title/heading/message/secondary styles;
body uses the 17 pt/22.5 pt baseline and code the 15 pt secondary style (UIKit rounds scaled sizes);
headings, list items and ordinary blocks have distinct spacing. Soft breaks remain spaces, explicit breaks remain
newlines, and straight punctuation is not silently changed. Nested lists have hanging indents and depth-specific
markers; disabled task checkboxes and nested quote borders retain their state/depth. General HTML, `<kbd>`, emoji
shortcodes, `==highlight==` and GitHub-alert markers remain literal, as in the reference chat; the previously approved
native HTML-image loader is preserved.

Tables are native, horizontally scrollable grids with header styling, column alignment, wrapping, per-cell selection,
CSV/TSV/Markdown copy and CSV/Markdown export through Files. Code cards retain one selectable TextKit 2 text view,
including source-line numbers aligned to wrapped lines, a language header, wrap toggle and copy without the gutter.
TextKit 2-backed caret geometry is cached; the legacy layout manager is never accessed. Inline-code backgrounds have
native rounded drawing with compact 2.4 pt horizontal expansion rather than inserting invisible padding characters
into selectable text. Links use a dedicated semantic role, not the primary-button color.

Parsing, highlighting, math layout/rasterization and Mermaid SVG generation stay off the main actor. The existing
bounded Markdown cache, row-remount retention and per-width text measurement cache remain. Table measurements are
cached by width and invalidated only by changed content/style/wrapping. Formula geometry is known before publishing
the parsed blocks, so bitmap arrival never changes their reserved dimensions. Footnote links open a native sheet;
closing it preserves the reading position instead of coordinating a second DOM-like scroll owner. Definitions also
remain at the end of the response. Math copies its original LaTeX, including when an inline attachment is selected.

**Dependencies:** SwaTexRender 0.5.0 provides native CoreText/CoreGraphics math with Swift 6 value types and bundled
KaTeX fonts. It is not literally every KaTeX feature (`\includegraphics`/DOM attributes are not supported). The local
JavaScriptCore bundle uses highlight.js 11.11.1 grammars and beautiful-mermaid 1.1.3, the same diagram library as the
reference. Rebuild it with `bun script/build-markdown-engines.ts`; no npm runtime, remote CDN or dynamic download is
used by the app. Licenses/source links, including ELK EPL-2.0, are bundled under `Resources/Markdown`.

Mermaid uses a fixed 384 pt viewport and starts only when its native scroll viewport becomes visible. A lazy,
nonpersistent WKWebView displays the generated SVG because iOS has no built-in general SVG view; its JavaScript is
disabled and CSP/navigation policy block external loads. Pan/pinch, zoom/reset, selectable ASCII, source, copy, fullscreen and SVG
export remain available. Failed/oversized formulas and diagrams retain selectable source rather than blocking the
reader. Highlighting falls back to plain text for unknown languages or more than 1200 lines/200k UTF-16 units;
diagrams are bounded to 400 lines/20k units and formulas to 8k units with bounded matrix column counts/bitmap sizes.

**Verification fixture:** Debug accepts `-OpenCodeScrollFixture conversation -OpenCodeMarkdownFixture
-OpenCodeFixturePosition top` with the usual explicit sandbox URL/password. Its two-message transcript uses
`OpenCode/Fixtures/markdown-fixture.md`, identical to `.agent-artifacts/formatacao/teste-formatacao.md`; the offline
transport refuses every HTTP request. Release excludes both the fixture mode and its Markdown resource.
Use only **OpenCode Formatacao** (`7C70FB07-A886-43BD-8A39-42D92E0C9937`, iPhone 18 Pro/iOS 27) and
`$TMPDIR/opencode/ios-formatacao-derived`. After `build-for-testing`, run `python3 script/test-markdown.py --label …`;
pass `--regressions OpenCodeUITests/SessionReadingTests` for disposable owned sandbox action/missing-directory
histories, with no model calls or seed resets. `profile-scrolling.py` accepts this simulator/DerivedData/evidence
directory for before/after frame measurements; `--markdown --frames` profiles the comprehensive document itself.
`python3 script/capture-markdown.py` captures all 17 sections in both themes, using DEBUG-only native geometry
positioning (`-OpenCodeMarkdownSection 0…16`) with the same full assistant message. It expands disclosures and fixes
wrap settings only for those launches, retains geometry/source/binary hashes and warms cold simulator WebKit for the
diagram shot. Functional XCTest uses real gestures/actions, independently of that capture driver.
Both runners accept `--simulator`, `--derived`, `--evidence`, `--server-url` and `--home` for isolated workers.
Use `--offline` for the server-free Markdown/rendering suites without reading sandbox credentials or starting a
backend. Captures additionally accept `--text` to align a particular block and `--top` to clear a taller pinned bubble.
The fixture includes leading-strong numbered/nested items; UIKit tests check regular body/markers after strong spans,
semibold headings/table headers, inline code, both themes and Dynamic Type without changing the shared font sizes.
List structure affects indentation, not font weight: body text and markers are regular; only strong spans remain
semibold. Headings h1–h6 and table headers remain semibold. Note that the pinned `801f59b` web renderer's custom
`<strong>` computes to 700 (not Streamdown's default 600); the native app deliberately retains the requested 600.
Source hashes, test results and both-theme reference/native captures
are under `$TMPDIR/opencode/ios-formatacao-prints/`; the pinned, backend-free reference harness is documented in
`.agent-artifacts/formatacao/reference/README.md`.

Verified on the dedicated simulator: 223 Swift tests in Debug and optimized Release, seven UIKit/engine/cache tests,
both complete Markdown UI cases, and conversation/follow/scroll regressions (the optional live replay is intentionally
skipped without model calls). The 12-second 300-message conversation trace kept p95 at 16.67 ms; observed CPU changed
from 4802 to 3549 ms and 60-Hz stall ratio from 11.42% to 6.71%. The document trace recorded 720/720 frames and
16.67 ms maximum; sessions with preview updates recorded p95 16.67 ms. These are single local traces in a shared
working tree, not a statistically isolated or physical-device performance claim.

### Conversation images

Markdown images and HTML `<img>` tags, user attachments, and expanded tool images share the authenticated native
loader. Relative paths resolve against the Session directory; absolute paths, `file://` and `~` resolve on the server,
never on the phone. Like the PWA, each resolved file uses `GET /api/fs/read/<filename>` scoped to its parent through
`location[directory]`, so existing files outside the repository need no new backend route. The same route exists in
installed `1de0005…`. Empty inline tool images from the lean RPC reload the read path or the canonical full message.

ImageIO downsamples off the main actor. A server/credential/directory-scoped cache holds at most 32 MiB of decoded
images and 128 MiB on disk (24-hour disk freshness); individual images are limited to 32 MiB. Tap opens a full-screen
viewer. The viewer decodes the full-resolution, orientation-correct image off the main actor through the same
authenticated disk cache, with a loading placeholder. Its native `UIScrollView` supports pinch from fit to 5×,
double-tap at a point to 3×/fit, panning with edge bounce and centering, and re-fit after rotation. Swipe down closes
only at fit; **Fechar**, VoiceOver activation, adjustable zoom and named zoom/fit/close actions remain available.
All image entry points, including the pinned user's attachments, use this viewer. Failures show
**Imagem indisponível no iPhone**, the path/URL without query credentials, and retry.
HTTPS and base64 image data URLs retain their sources. Only loopback URLs naming the native file route are moved
to the configured server; arbitrary localhost services cannot be proxied. `seaweedfs-svc` loads directly, with a
host-specific HTTP ATS exception: the phone still needs its own authorized WARP DNS/route to port 8333, and signed
URLs may expire. Other unapproved HTTP hosts and image formats unsupported by ImageIO fail explicitly.

Verification uses only **OpenCode Imagens** and `ios-imagens-derived`; after `build-for-testing`, run
`python3 packages/ios-custom/script/test-images.py` and repeat with `OPENCODE_TEST_THEME=openchamber-light`.
The runner imports/deletes only its own fake-repository histories and image files, makes no model call, supplies the
explicit sandbox URL/password on every launch, and saves evidence in `$TMPDIR/opencode/ios-imagens-prints/`.
Internal-host reachability is a network dependency, not claimed by the synthetic unreachable-host failure case.
Zoom checks use **OpenCode Zoom** (`55A2D57A-6DC1-4645-BB0A-40D79707F311`), `ios-zoom-derived` and
`ios-zoom-prints`. Set `OPENCODE_IMAGE_DEVICE`, `OPENCODE_IMAGE_DERIVED` and `OPENCODE_IMAGE_EVIDENCE` to those
values when invoking the same runner; its zoom case covers gestures and a tall screenshot in both themes.
The app remains portrait-locked: UIKit hosted tests exercise actual viewport resizing, centering and re-fit;
the UI case also checks device rotation leaves the viewer usable. Debug/Release builds are warning-free,
254 Swift tests pass, and all four image UI cases pass in both themes (dark tool regression rerun after its label update).
Final image checks pass in both themes (three UI cases plus all thirteen app-hosted tests), with a warning-free build and
194 Swift tests green. The four existing `SessionReadingTests` also pass together in light mode; the dark child
Details case repeatedly missed its native menu tap and was left unchanged. The GET-only Temas audit separately
decoded/resolved all six Markdown references and all 20 stored PNGs, then deleted its raw page.

### File references and native previews

Assistant Markdown local links now open a native file viewer, including links in lists and table cells. Inline code
uses the custom web `1042585c28` candidate rules and becomes an underlined path only after the server confirms a file
through listing/search; HTTP code links retain their external destination. Checks wait until the owning backend message
finishes (conservative versus the web's block-level streaming boundary). Relative paths prefer exact matches, then
unique workspace suffixes; ambiguous matches offer a picker. Explicit links also try their literal relative path.
Absolute paths and `~` use the server filesystem, including temp folders outside the Session directory. The native `~`
support extends the web resolver. Ellipsis abbreviations are deliberately not expanded. Plain prose/code fences and
the user-message body remain literal, preserving the web's user-message/token/copy behavior.

`FileViewer` reuses the authenticated image request builder with basename + parent Location, probes size using a one-byte
Range GET, asks before downloads above 50 MiB, and uses cancellable URLSession downloads with progress rather than
buffering a movie in memory. Images reuse `ZoomableImageView`; audio/video use AVPlayerViewController; documents,
PDF/text/code/Markdown/JSON/CSV use Quick Look. Unknown types show metadata and Share, or Quick Look when supported.
Every viewer offers Share and Copy path. Protected temporary files retain their original names and are removed on
dismissal/cancellation or at the next app launch. Feed image loading, cache and downsampling are retained; table images
use the same thumbnail/zoom path. A video/audio file mistakenly written with Markdown image syntax becomes an explicit
play-file card instead of an ImageIO failure. Code/document previews use a temporary `.txt` copy when necessary
(notably `.ts`, whose registered MIME/UTI can otherwise mean MPEG transport stream); sharing retains the original file.
No backend/protocol changes or public credential-bearing URLs are introduced.

Verify only on **OpenCode Imagens**, with `ios-imagens-derived`, by running
`python3 packages/ios-custom/script/test-files.py` in each theme after `build-for-testing`. The runner creates small
PNG/MP4/WAV/PDF/TXT fixtures plus an owned sparse large-file fixture inside the sandbox fake repository, imports its own
histories without model calls, and removes them afterwards. Every launch explicitly supplies the 4177 sandbox URL and
password. Evidence lives in `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-arquivos-prints/`.
Verification: 287 Swift tests and all 63 app-hosted tests pass; the four new viewer UI cases pass in both themes,
including real MP4/WAV playback, TypeScript/PDF/text previews, table-image zoom/share, missing files and large-file
consent. Both complete Markdown UI documents and all four image UI regressions also pass. A follow-up verified all
four SessionReadingTests on a clean local clone of `67426eaa46` and on the working tree, using separate DerivedData
and fresh simulator installs. The earlier red reports used intermediate test assumptions: new context/cache rows
shifted Details content, and larger polish rows moved the renamed session outside the initial list viewport. Existing
working-tree frame-based, bidirectional reveal checks and reveal-before-assert changes are preserved; bounded drags
replace fast swipes that could skip/virtualize the short Skills heading. Search Cancel now has a header-specific
identifier and the test waits for search to disappear before tapping Back. All four reading tests pass in both themes
after these selector/scroll changes, plus a separate Details/search repeat. Comparison
logs, binary/source hashes and captures are in `$TMPDIR/opencode/ios-arquivos-comparison/`; the clone and its
DerivedData are removed after comparison. Debug test builds use `COPY_PHASE_STRIP=NO` to avoid the new signed
VoiceActivity extension's copy/strip warning. No backend, seed, model or production mutation was performed.

#### Viewer zoom, sibling paging and file kinds — 24 October

- **Zoom reset on touch:** UIKit's double tap accepted two quick touches that each moved up to ~10 points, so two
  small nudges of a zoomed image counted as a double tap and fitted it again. `StrictDoubleTapRecognizer` accepts
  only nearly still (≤ 6 pt), brief (≤ 0.3 s) taps and ignores a touch that stops a moving or zooming image.
  A viewport change keeps a zoomed image's relative zoom and visible center (a fitted image re-fits), and a
  status-bar tap no longer scrolls it. Pinch and a real double tap remain the explicit zoom gestures.
- **Siblings:** a server file (chat link, feed image, explorer entry) pages through files in its own directory,
  inside or above the Session directory, in `listDirectory` order: the server's `fs.list` order, which is also the
  web file tree's (directories first, then `localeCompare`). Folders and kinds the viewer cannot preview are
  skipped (the open file always stays). Glass ‹/› buttons appear only when a neighbour exists on that side; data:
  and remote images, or a directory that cannot be listed, show none. A horizontal swipe pages only when it
  starts outside controls, a zoomed image, a text selection or content that can still scroll horizontally
  (zoomed PDF/SVG); a new file always starts fitted. Quick Look content (Office/iWork, CSV fallback) runs out of
  process, so only the buttons page over it.
- **Kinds:** PNG/JPEG/HEIC/WebP and animated GIF/APNG (frame by frame through `CGAnimateImageAtURLWithBlock`) use the
  zoom view; Markdown renders with the response renderer (no quote/comment actions); text/code/JSON up to 2 MiB
  use a selectable native text view; PDF uses PDFKit; SVG uses a JavaScript-free WKWebView with an `<img>` data
  URL under a CSP; audio/video keep AVPlayer. Larger or non-UTF-8 text keeps Quick Look. Unsupported files show
  **Pré-visualização indisponível** with Share (which includes “Abrir em…”).

#### Markdown files — 24 October

- **Termination on open:** the viewer drew the whole document at once (`ScrollView` around one `ResponseMarkdown`).
  Each text view keeps bitmaps for its full height, so opening this README took the footprint from 57 MB to 1.9 GB
  in the iOS 27 Simulator and grew with document length; on a phone that ends in a jetsam kill, which leaves no
  crash report in App Store Connect. No TestFlight crash log was available for the reported build.
- `FileMarkdownPreview` now uses the response engine in slices (`MarkdownDocument.chunks`, ≤ 1,500 UTF-16 units or
  12 blocks) inside a `LazyVStack`: the same README stays near 160 MB while scrolling to its end. Prose joins within
  each slice, so selection spans its paragraphs, headings and lists; quote/comment/side-question actions are off.
  A single block over 40,000 units (a huge listing) opens in the scrolling source view instead.
- Images and links resolve against the file's directory; a link to another file opens in the same viewer with
  **Voltar**. YAML front matter renders as a YAML code block. The `</>` button switches to the selectable source.
  In-document anchors (`#secao`) are not links yet.

#### Read aloud — 25 October

- Markdown files (rendered or `</>` source) show a floating pill in the bottom trailing corner: play/pause inside a
  progress ring, elapsed/total time and speed (`1×` → `1,5×` → `2×`, remembered, pitch preserved). Tapping the time
  opens the full player (draggable position, time, speed, chevron or swipe down to collapse). The bottom inset keeps
  the last lines visible, and the sibling arrows stay clear above it. Nothing is generated before play.
- `ReadAloud` (OpenCodeKit) turns blocks into speakable text: prose as written, list tasks as "Concluído/Pendente",
  code and tables announced ("Bloco de código em swift, com 2 linhas"), image alt text, formulas named; rules,
  footnotes and front matter skipped. Pieces of 220, 650, then 1,500 characters end at sentences.
- `ReadAloudPlayer` asks `custom.speech` (plugin; Gemini 3.8 Flash-Lite TTS through the Vercel AI Gateway, voice
  Kore, cached on the server) only for the piece at the playhead and the next two, so seeking or stopping early
  never pays for the rest. The total starts from the server's speaking rate and settles with each generated piece.
  Seeking into a piece without audio generates it and starts at the same proportion. Documents over 30 minutes of
  audio ask first, with the estimated cost.
- Audio: `.playback`/`.spokenAudio` on the app's serial audio queue; pauses for voice mode, dictation, system
  interruptions (resuming when the system recommends) and unplugged headphones; plays in the background with Now
  Playing and lock screen play/pause, ±15 s and scrubbing. Closing or leaving the file stops it.
- **Estimate:** the total starts from `custom.speech/info`'s rate, which the server learns from the audio it
  generates, and then blends in the rate measured on this document's generated pieces (the server rate counts as
  1,000 characters), so the first, often unrepresentative piece only nudges it.
- **Resume:** the place is saved on the server per file (`custom.speech` positions: text offset, text hash, sentence
  and elapsed seconds) on pause, close, file change, background and every 8 s while playing. Reopening shows the pill
  paused there without generating anything (an unchanged document shows the same time); play resumes from it. A
  finished document clears it, and the full player offers **Recomeçar do início** while one is saved. An edited
  document resumes at the saved sentence, else the nearest sentence start, else the top (see the plugin's
  `docs/speech.md`).
- `FileReadAloudTests` (through `test-file-viewer.py`, both themes) uses the sandbox's real gateway: the run's first
  piece numbers the run, so about a cent of speech is generated per run; the rest comes from the sandbox cache.

#### Reading answers aloud — 25 October

- A finished answer with text has a play icon beside Copiar in its footer (never while streaming). It reads what
  Copiar copies: the text parts of the turn's messages from the prompt to the footer's message, in order (text written
  between tools included), through the same speakable extraction; reasoning, tool calls and tool output are skipped.
- The answer's identity is its footer message, the last message of the turn: the place is saved on the server as
  `message:<sessionID>/<messageID>` with the text hash, exactly like a file. The button reads `store.messages` only in
  its action, and rows do not observe the player, so streaming never re-renders them for it.
- The same pill/full player as the Markdown viewer floats over the transcript's bottom trailing corner, above the
  composer, with **Ir para a mais recente** stacked above it; the transcript's end grows by the player's height so the
  last answer stays visible. The pinned prompt, usage row, voice bar and composer keep their places. The full player's
  **Ir para a resposta** scrolls back to the answer being read. Reading continues while scrolling.
- One reading at a time: playing another answer, or opening a Markdown file, stops the previous one and saves its
  place; leaving the conversation does too. Tapping an answer with a saved place opens the pill paused there; play
  resumes from it (the server's per-text audio cache avoids paying again).
- `ChatReadAloudTests` (through `test-file-viewer.py`, both themes) imports a two-turn session and uses the sandbox's
  real gateway (a few seconds of speech per run).

#### Viewer reload — 25 October

- **Zoom reset without a touch:** chat images presented their viewer from their own transcript row. While a reply
  streamed, following the tail scrolled that row away and the recycling `List` released it; the next scene
  deactivation (Notification Center, Control Center, app switcher, background) rebuilt the orphaned presentation with
  a new `FileViewer` state, which downloaded, decoded and fitted the image again. The UI test reproduced it on the
  previous code (`FEED after Notification Center`). Links already used the conversation-level host.
- `FileViewerHost` now presents both files and chat images (`openImage`), so the viewer outlives transcript rows.
  A viewer's disappearance only suspends an unfinished download; the downloaded file is removed when its store goes
  away, and the decoded image is not reloaded when the view reappears. Images inside a file viewer still present
  over it.

Run `packages/ios-custom/script/test-file-viewer.py` after `build-for-testing` with `OPENCODE_SANDBOX_HOME`,
`OPENCODE_TEST_SERVER_URL`, `OPENCODE_TEST_DEVICE`, `OPENCODE_TEST_DERIVED` and `OPENCODE_TEST_EVIDENCE`; it creates
and removes its own fixture directory and sessions (no model calls).

Media tables size each row independently with intrinsic-height, top-aligned cells; grid borders no longer force the
header to share an image row's height. Plain UIKit tables also top-align short and multiline cells. Geometry UI checks
cover media/plain/wide tables and the four literal tables extracted from the formatting fixture, in both themes.

### Session file explorer

In **Detalhes da sessão**, the **Diretório de trabalho** row (chevron; long press copies the path) pushes a native
explorer of the session's checkout on the server. It ports the web's session file tree (`app-custom/src/session/files`)
as folder navigation: `GET /api/fs/list` with the Session's Location and an absolute `path`, in server order
(directories first, then files, each by `localeCompare`), including dotfiles and omitting symlinks, as the web does;
the web marks no ignored entries either. The current path heads the list. Folders push a new level and Back returns.
`../` also pushes the parent and, unlike the web tree, keeps going above the session directory up to `/`; listing
outside a Location never switches it. Files show the web tree's **A/M** markers from the working-copy diff already
loaded by the sheet (paths relative to the checkout root). Search is the web's: ranked `GET /api/fs/find` across the
session directory (`type=file`, `limit=200`, ignore-aware), shown as a flat list while the field has text. Tapping a file
opens the existing `FileViewer` with its absolute path, from a `FileViewerHost` on the sheet, because the
conversation's own host cannot present over it. Missing folders (404) and unreadable ones (permission, 500) show an
explicit message with retry. `OpenCodeClient.listDirectory(_:location:)` is the shared listing; the project explorer's
`directories(at:)` filters it. Not ported: the web's expandable tree/tabs, the separate "Alterados" view, ancestor
change dots of the legacy tree and file drag. Verify after `build-for-testing` with
`python3 packages/ios-custom/script/test-file-explorer.py --device … --derived … --home <sandbox> --server-url …
--evidence …` (optionally `--theme openchamber-light`); it owns a temporary git checkout and an imported session,
and deletes both.

### Session details sections

**Detalhes da sessão** lists Uso da sessão, Sessão, MCP, Skills and Plugins, in that order; LSP is no longer shown.

- **MCP** starts expanded. Each server is a native toggle bound to the conversation's `ConversationMCPStore`, the
  same live state, `POST /api/experimental/mcp/:name/{connect,disconnect}` call, verification, pending pulse, login
  toast and error toast as the composer's `MCP · N/M` panel; toggling here updates that pill. Rows stay in name order
  while toggling and show the status (and the server error for failed/needs-login servers).
- **Skills** are the skills this session **loaded**, not the catalog: `custom.transcript/skills` (plugin) reduces direct
  activations, prompt-attached skills and completed `skill` tool calls server-side into `{ id, name }` in first-load
  order. An empty session says **Nenhuma skill carregada**; an older server without the method says **Indisponível**.
- **Skills** and **Plugins** start collapsed to their first five rows with **Mostrar todos (N)** / **Mostrar menos**;
  the header chevron toggles the same state (MCP's hides the section's rows). **Atualizar** moved to the toolbar.

After `build-for-testing`, `python3 packages/ios-custom/script/test-session-details.py --device … --derived … --home
<sandbox> --server-url … --evidence …` (optionally `--theme openchamber-light`) owns a git checkout with seven fixture
skills and six fixture plugins, loads skills for real (one Luna 6 / low `skill` tool call, two prompt attachments,
four direct activations), runs `OpenCodeUITests/SessionDetailsTests`, toggles a connected MCP off and back on, and
deletes the session and checkout.

## Voice conversation

### Composer dictation (independent of GPT Live calls)

The empty composer's microphone records locally in conversations, Nova sessão and Sessão mestra. The gesture is
ported from Abacato v2's `VoiceRecordingGesture.swift` (including its `voz/gravacao-fluida` merge, `5733cb4ef`).
With the microphone already allowed, recording starts **at the touch**, so the first word is not lost to the hold
delay; releasing within 300 ms keeps recording hands-free. Before permission is known, the touch waits for the
system prompt as before: a tap starts hands-free and a hold begins at 300 ms. Holding, slide left 100 pt to discard
or up 80 pt to lock; diagonal movement uses normalized dominant progress. Releasing a hold transcribes it from one
second on; earlier it keeps recording hands-free (as in WhatsApp on iPhone), never discarding speech. A locked
recording offers pause, local preview/seek/resume, trash and **Parar e transcrever**; stopping one shorter than one
second discards it. Background, route changes, interruption, another recorder or the system cancelling the touch
(Home, lock, alert) turn a locked recording, or a hold of one second or more, into a paused draft locked to
**Parar e transcrever**; it never resumes automatically, and a shorter hold is discarded. The live waveform slides
on every frame between its 100 ms meter samples (static with Reduce Motion), the panel starts at 0:00 instead of the
previous recording's time, and the paused preview is ready after 200 ms without file growth instead of 500 ms.
The UIKit touch target stays mounted throughout.

**Nothing sends automatically.** Parakeet Ultra inserts plain text at the current caret through the existing
incremental/undoable editing path, preserving tokens and any text typed during a download. It then opens the real
fullscreen composer with the keyboard and caret after the inserted text. A selected range is not overwritten.
Completed audio is removed only after insertion/persistence; failures retain protected local audio with **Tentar
de novo** / **Descartar**. Pending audio is scoped to the existing server/draft persistence and survives relaunch;
leaving a conversation keeps its own paused or pending recording. Simultaneous recorders yield audio ownership.
An active GPT Live call disables dictation with an explanation; these paths share no proxy or server API.

**Você → Transcrição** shows model status/progress, download/disk size, retry, deletion and redownload. First use
asks before downloading **632,162,964 bytes** (632 MB / 603 MiB), recommends Wi-Fi and explains the roughly 15-second
Neural Engine optimization. Core ML caches it per installed bundle and iOS build, so it recurs after every install,
TestFlight update or iOS update. `TranscriptionController` therefore prewarms once shortly after such a launch or a
finished download (`.medium`; `.utility` took 38 s on the iPhone 14) and again when a recording starts, so the
compilation overlaps speech. All callers share one load, serialized after any pending unload; idle unload is unchanged.
While it runs, the pending row says "Otimizando o modelo para este iPhone (uma vez por atualização)…".
AVAudioSession activation/deactivation, creating the `AVAudioRecorder`, `record()` and preview `play()` (which
activate internally) run on one serial queue off the main thread, and the expanded composer raises the keyboard only
after its cover finishes presenting. Stopping during an activation no longer drains that queue on the main thread:
`stop()` advances a lock-protected epoch that the queue checks right before recording, so the main thread waits at
most for one `record()` call, a stopped opening never records, and one that recorded just before the stop is closed
and its file deleted (it cannot reappear as pending audio). Recording remains usable while missing/downloading; audio waits locally. The download
uses background URLSession, resumable files, exact byte counts and SHA-256 before atomic installation. Inference
starts only on-device in the foreground, one recording at a time, with the CPU preprocessor and Neural Engine;
the model unloads after idle time. Download continuation is not a promise of background inference.

The package is **FluidAudio 0.17.7** (`503b4bd1…`), a tagged descendant of Abacato's `c3881073…` that includes
`.ultra` and the same `loadLocal` API. Weights remain pinned to Hugging Face
`FluidInference/parakeet-ultra-coreml@95eaa59a39d4394f047a4dc5cce480388a60d1b6`, 18 files, never bundled.
The model supports 25 languages including Portuguese, using Abacato's automatic language/no-VAD setup and serial
long-audio chunks. `Resources/TranscriptionNotices.txt` bundles FluidAudio's Apache-2.0, its third-party notices and
the model's CC-BY-4.0 license/attribution. Regenerate with `script/update-transcription-notices.py`.

The port also draws from Abacato's `VoiceRecordingComposer`, `VoiceRecordingCapture`, `VoiceRecordingSnapshot`,
`VoiceRecordingPreparation`, `VoiceRecordingDrafts`, `TranscriptionEngine`, `TranscriptionManifest`,
`TranscriptionModelFiles` and `TranscriptionDownloader`. Abacato's WhatsApp posting/media preparation, received-message
priorities and background backlog processing are deliberately not imported. iOS 27's new inactive notification
replaces the deprecated interruption-type API. Every color uses the app's typed semantic theme roles.

#### Microphone beside Send — 25 October

**Alexandre, 25/10: opção A.** Once the field has content the big round button sends (✓ **Concluir comentário** in
the comment sheet), and a compact outlined microphone (`DictationCompactMicrophone`, 44 pt target, **Gravar áudio**,
`composer-microphone`) sits at its left, so dictation can complement typed text. It is the same
`VoiceRecordingTouchTarget`, `VoiceRecordingGesture` and `VoiceRecordingComposer`: recording at the touch when
allowed, hold/release, slide left to cancel, up to lock, tap for hands-free, sub-second releases continuing, paused
drafts on interruption, panel and preview. While its hold lasts, the compact microphone grows under the finger with
the lock guide, Send hides and the panel makes room; a locked or hands-free recording then continues exactly as from
the empty field (stop in the main button, the panel's trash/pause/preview), and the compact microphone returns once
the recording is transcribed or discarded. The long-press **Enviar agora / Adicionar à fila** menu stays on Send only.
The empty field is unchanged. During a GPT Live call, sending or importing it is shown dimmed and disabled; VoiceOver
reads it before Send. Showing or hiding it eases in 0.15 s (none with Reduce Motion).

The transcription goes **at the caret while the field is focused, otherwise at the end** (keyboard down, or a pending
download finishing later); a selection is never replaced. `DictationInsertion.spaced` trims the text and adds one
space only where it touches a word or token on either side, none against whitespace, closing punctuation or an
opening bracket. Tokens, quotes and attachments are untouched (the native incremental, undoable insertion). The
review stays as before, also with earlier text: the message composer opens fullscreen with the caret after the
inserted text, so the whole message is reread before sending; the comment sheet refocuses the comment.

To make room, the agent (`build ⌄`, `agent-picker`; `child-agent` text for children and the master) left the control
row for the line below the card (`ComposerFooter`): before the usage in a conversation, alone in Nova sessão, the
empty master composer and the fullscreen composer. Tapping it (or `/agent`) opens the same sheet, now presented from
`ConversationDraft.choosingAgent`. The comment sheet has no agent, as before. When the row runs out of width the model
label shrinks to 75% and then truncates; `+`, the MCP pill and both round buttons keep their size (iPhone SE 375 pt
shows `Opus 5.5 · xhi…` with text). Accessibility sizes keep the row's horizontal scroll, and in the footer the usage
folds into two lines before the agent gives way.

Showing the compact microphone depends only on the published `hasText`, which changes when the field empties or
fills, never per keystroke, and its hold state is read inside its own view. `profile-composer.py` (iPhone 18 Pro
simulator, `-O` Debug, four interleaved rounds per side on the shared Mac, medians before → after; `toggle` empties
and refills the field on every key, swapping the controls each time): plain p50/p95 6.7/10.2 → 6.2/9.8 ms, mentions
7.2/53.1 → 8.0/53.0 ms, suggestions 8.7/12.3 → 9.4/13.6 ms, toggle 9.1/12.4 → 9.7/13.7 ms; no frame above 16.7 ms
p95 and the same hitch counts. Differences are within the run-to-run spread (±1 ms) of this busy Mac, not a
physical-device claim. Kit `transcriptionGetsOneSpace…`, hosted `testInsertionUsesNativeIncrementalPath…` (caret,
off-screen and unfocused end), `DictationUITests` (`testCompactMicrophoneBesideSendInsertsAtTheCaret`,
`testCompactMicrophoneTapIsHandsFreeAndTheAgentMovedToTheFooter`, the comment case) and `SizingTests` (typed text on
iPhone 18 Pro and SE) cover it in both themes. Captures are in `$TMPDIR/opencode/composer-mic-text/prints/`.

#### Isolated dictation verification

Use **OpenCode Gravacao** (`0C2C8A7F-CD76-43D5-88F5-A880D5A80B78`) and
**OpenCode Gravacao Light** (`EAFA2B6D-1296-47CE-A6B2-BF6A19312F20`), iPhone 18 Pro/iOS 27.
Build-for-testing with `$TMPDIR/opencode/ios-gravacao-derived`, then run these concurrently on the separate simulators:

```sh
python3 packages/ios-custom/script/test-dictation.py --label dark
python3 packages/ios-custom/script/test-dictation.py --label light --theme openchamber-light \
  --simulator EAFA2B6D-1296-47CE-A6B2-BF6A19312F20 OpenCodeUITests/DictationUITests
```

The runner supplies explicit sandbox-4177 arguments/password but never accesses the server or changes its lifecycle.
The DEBUG-only, explicit-loopback-gated `-OpenCodeDictationFixture fake` mounts the production composer with prerecorded
pt-BR PCM and a fake model/engine: no microphone, model download, inference server or auto-send is involved. Release
excludes the fixture audio and code. `-OpenCodeDictationFixture device` instead exercises the real microphone,
background downloader and Parakeet in the same server-free root; acquire the physical iPhone 14 lease first.
Evidence is under `$TMPDIR/opencode/ios-gravacao-prints/`. Run `swift test` from `OpenCodeKit` for pure gesture,
manifest/checksum/resume-file and draft-retention coverage; hosted `DictationPipelineTests` exercise queue/failure/retry,
permission cancellation, recording at an authorized touch, sub-second releases continuing hands-free, interruption and
system-cancelled holds becoming paused drafts (or discarded under one second), the panel restarting at zero, and
native token-preserving insertion/undo. No live server or GPT Live call is required.

After the leased iPhone has downloaded the real model, `python3 packages/ios-custom/script/test-dictation-device.py`
feeds the bundled Portuguese PCM (padded to 10 seconds) directly into only the server-free fixture's pending draft,
then verifies real Parakeet inference/fullscreen review in both themes. It uses `ios-gravacao-device-derived`, preserves
the installed model, saves timing JSON and screenshots, and copies no recorded microphone audio off the device.
This deterministic quality check is separate from live microphone/gesture checks: music/noise from Mac-speaker
playback is test-environment contamination, not an accuracy assertion or a reason to change audio-session policy.

Verification: 315 Kit tests; 27 hosted composer/dictation/voice regressions passed, with the two existing opt-in live
proxy probes skipped. All six dictation UI cases passed in each theme on separate simulators, including gestures,
large-text 44-point controls, preview, settings confirmation and fullscreen review with keyboard/caret restoration.
Hosted checks cover incremental token-preserving insertion/undo, off-screen insertion and failed-audio retention/retry.
The decoder explicitly bounds its
last PCM read: normal end-of-file must not be reported as a failed recording, while actual read failures retain audio.

The leased iPhone 14 verified real recording, hold/release, left cancellation, up-lock, pause/resume and the real model
download. The clean 10-second PCM benchmark (7.96 seconds of synthesized Portuguese plus end padding) measured
**15.89 s** cold preparation, **0.19 s** warm load and **0.19 / 0.11 s** inference in dark/light respectively. These are
individual local runs, not latency guarantees; loading is measured separately from inference. Both outputs preserved
the sentence with one extra **“o”** in **“Não o envie…”**, demonstrating why review is required. After success, device
inspection found only `draft.json`, no recording/preview audio. The device was released and owned simulators shut down.

**Touch-to-recording latency (iPhone 14, 24/10/2026).** `script/measure-dictation-device.py --app … --label …`
installs an optimized DEBUG build (`SWIFT_OPTIMIZATION_LEVEL=-O`, whole module, `GCC_OPTIMIZATION_LEVEL=s`, generic
iOS destination, `DEVELOPMENT_TEAM=ERRYZ68LX5`) under its own process lease, launches `-OpenCodeDictationFixture
device -OpenCodeDictationTimeline` (real microphone and Parakeet, no server) and drives the microphone with
agent-device: five taps followed by pause and trash, then five 4.5 s holds, each after a relaunch with an empty
draft, while the Mac says a short Portuguese phrase. The DEBUG-only timeline records `ProcessInfo.systemUptime` marks
at the touch/release handling, `state = .recording` (after `record()` returned), pause, preview ready and text
insertion, and the script copies them back; it measures inside the app, not frame by frame on video. Medians of
five, same gesture, same build flags, `origin/custom` `026bd5a44a5` against this change:

| Milestone | Before | After |
|---|---|---|
| Tap → recording | 184 ms (180–337) | 116 ms (107–148) |
| Hold → recording | 339 ms (336–397) | 123 ms (122–147) |
| Release → text in the composer | 206 ms (201–227) | 202 ms (164–210) |
| Pause → preview ready | 719 ms (556–735) | 389 ms (221–403) |

Before, a hold waited the 220 ms hold delay and a tap only opened the microphone after the finger left; now both
start at the touch, so the remaining time is the session activation and `record()`. Release → text (reading the
file, resampling and warm Parakeet inference of about four seconds of audio) did not change and was not a goal.
Individual local runs, not latency guarantees.

Debug/test builds and the signed Release archive/export are warning-free. The dry-run uses a temporary
`XCODE_XCCONFIG_FILE` containing `COPY_PHASE_STRIP = NO`, the existing verification workaround for an already-signed
VoiceActivity extension; no permanent project setting changes. The signed IPA is about 31.9 MB, contains the notices
and contains neither Parakeet weights nor DEBUG fixture audio. Nothing was uploaded. Screenshots, videos, xcresults,
device timing/cleanup JSON and the artifact manifest are in `$TMPDIR/opencode/ios-gravacao-prints/`.

The waveform in **Sessões** starts a native, full-duplex GPT Live call through the private
`llm-proxy-svc:8080` lease/signaling contract. The floating glass bar stacks above the master accessory
on tabs and sits above the composer; mute/end also appear in the Live Activity/Dynamic Island extension.
Audio continues in the background after microphone consent. Real actions and answers are delegated
to the existing **Sessão mestra**, with throttled live progress rather than waiting silently for the
final answer. Ending the call does not interrupt work already submitted to OpenCode.

The same call starts without opening the app from the **Falar com a mestra** Control (Action
button, Control Center, Lock Screen) or the App Shortcut of the same name: only the Live Activity
appears. It requires an unlocked iPhone, only vibrates when a call is already running, and brings the
app forward when iOS needs it (microphone prompt, Live Activities off or refused, no server). Set it up
in **Ajustes → Botão de Ação → Controles**. See
[`docs/voice.md`](docs/voice.md#início-pelo-botão-de-ação-controles-e-atalhos).

See [`docs/voice.md`](docs/voice.md) for the exact proxy contract, WARP requirements, transport and
background ownership, source revisions, limitations, and test commands. The DEBUG-only
`-OpenCodeVoiceFixture` uses no microphone, GPT Live or master inference (KV appends may trigger
server compaction above its threshold); `-OpenCodeVoiceFakeMaster` isolates the
master during physical audio checks. Both require explicit loopback sandbox arguments (4177 or 4180).
`script/test-voice.py` uses the dedicated **OpenCode Voz** simulator and an owned disposable history.
The TestFlight script also accepts `OPENCODE_DERIVED_DATA` for an isolated archive directory.

Voice memory uses the plugin's KV record, **not an OpenCode Session**. Canonical
`turn.done` text, roles, native IDs, timestamps and interruptions are written to an
atomic protected local file before RPC append. Ordered pending operations survive
crash/offline periods and replay on launch/call; end checks follow their turns.
`custom.voice` version 2 context becomes `session.initial_items` with both roles,
summary/master data labels and a client-enforced 128-item/8,192-estimated-token cap.
Instructions remain behavior-only. Unsupported/older servers do not block voice;
local turns remain queued. The master receives only explicit delegations, not the
voice transcript, as plain request text without a voice preamble (its agent prompt
covers voice). See [`docs/voice.md`](docs/voice.md) for persistence and fallback.

The expanded bar's **Ver transcrição** opens the record read-only (summary and
recent turns), observing local captures live without UI polling. It is rolling
memory, not an unlimited verbatim archive; there is no composer or delete action.
This integration uses **OpenCode Voz Memoria** and sandbox **4180**, with
`ios-vozmem-derived` / `ios-vozmem-prints`; the voice runners honor `OPENCODE_VOICE_*`
overrides so other agents' simulators and services are untouched.

### Faixa de voz

**Você → Conversa por voz → Voz** selects the next call's voice. Rio is the default when no choice
was saved; Rio and Viola appear first in **Brasileiras**. `OpenCodeVoice` is a device-local
UserDefaults preference, not a server preference. Changing it during a call never restarts audio.
An explicit voice-validation rejection tries Rio, then Cove, without repeating IDs; a toast names
the accepted fallback and the saved choice stays intact. There is no preview. The contract, catalog
and isolated **OpenCode Voz Escolha** checks are in [`docs/voice.md`](docs/voice.md#escolha-da-voz).

`FloatingVoiceBar` is a pure SwiftUI surface driven by `VoiceBarState`: phase, elapsed time, spoken line,
master progress, mute, expansion, error and pending controls. The adapter in `FloatingVoicePresentation`
reads the engine's `connectedAt`, `currentSpokenLine` and `masterProgressLine`; it owns only UI expansion.
The waveform, state and active Sessions waveform button use `primary` (orange in OpenChamber),
and ending uses the destructive `error` role with a tonal background.
Typography comes from `AppTypography`; there are no fixed palette colors.

On tab screens the voice surface stacks above the master accessory (**Alexandre, 25/10**): voice bar,
then the still tappable "Sessão mestra" accessory, then the tab bar, on every tab. The accessory keeps its
place when a call starts or ends. The voice bar's safe-area inset sits inside the accessory's own inset and
reserves the whole expanded height, so the last list row remains reachable above both. In a conversation it is
a sibling immediately above the composer, including with the keyboard open. It starts compact; tap the
summary to expand, tap again or swipe down inside the bar to collapse. The microphone and end controls
stay in the same header row. VoiceOver exposes one element with its state/duration and named actions.
Reduce Motion stops the waveform; long lines truncate and large Dynamic Type keeps the controls reachable.

The independent DEBUG-only `-OpenCodeVoiceBarFixture <state>` requires explicit
`-OpenCodeServerURL http://127.0.0.1:4177` (or explicit 4180). States: `listening`, `speaking`, `thinking`, `connecting`,
`reconnecting`, `muted`, `error`, `idle` (master idle), `long`, `interrupted`. It never starts the engine,
microphone, Live Activity or proxy. `script/test-voice-bar.py` imports and deletes one owned history,
leaves sandbox seeds untouched, and runs on **OpenCode Faixa Voz** (`41015785-0AB5-413B-8CEC-8C986E83BC1E`).
Use `ios-faixavoz-derived` for `build-for-testing`; repeat the runner with
`OPENCODE_TEST_THEME=openchamber-light`. The runner also imports and deletes 16 owned filler rows
(`OPENCODE_VOICE_BAR_FILLERS`) so the list scrolls behind both strips, and uses `<home>/repos/voice-bar`
when the sandbox has no conversation seed. `testMasterAccessoryStaysVisibleBelowTheVoiceBar` and
`testStackedStripsWithLargeText` cover the stacked strips on every tab, their taps and the largest text size. Captures, results and cleanup ledgers are in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-faixavoz-prints/`.
The provisional root `VoiceOverlay` has been removed. New-session/master drafts and the fullscreen
composer also reserve space above their input; ordinary sheets reserve their bottom safe area.
See [`docs/voice-bar-integration.md`](docs/voice-bar-integration.md).
The final layout checks pass in both themes: eight presentation cases, 20 fake-engine/hosted composer
regressions per theme, and 289 Kit tests in the last shared-checkout run. Debug/test and Release builds are warning-free. The evidence
directory includes `verification.json` with absolute paths to all 80 state captures and result bundles.

## Context and cache usage

One fixed, left-aligned line below the conversation composer starts with the agent (`build ⌄`, see
[Microphone beside Send](#microphone-beside-send--25-october)) and then shows a compact context ring, used/limit tokens and
cache-hit percentage with monospaced digits and the capped 9 pt metrics role. It uses this conversation's latest
measured assistant step (including the cache ratio), retaining it while a new step streams without measurements.
Child and master conversations use their own store; there is no usage before any measurement or on Nova sessão
(the line then holds only the agent).
Answer footers contain only the existing model/date and copy action. An unknown limit keeps tokens without a percentage.

The usage part of the line opens **Uso da sessão** in the existing Details sheet. It is a normal bottom-stack child, not an overlay:
its height reduces the transcript viewport, stays above the keyboard and below the composer, and disappears in the
fullscreen composer (where only the agent follows the editor). The voice bar reserves its own height above the composer without sharing this line's inset.
The composer is 12 pt from each side. The 40 pt usage hit area owns the bottom home-indicator band, with its text
centered 20 pt above the edge; without measurements the same band holds only the agent, preserving the input's position. Only the
container bottom safe area is extended, so the native keyboard still reduces the available viewport.

The header ring opens **Detalhes da sessão**, as a native sheet initially at the large detent. **Uso da sessão** sits
above the existing details: context is the latest measured step, while cache counts/ratio, tokens and cost are Session
totals; descendant and combined cost remain explicit. The existing detailed context breakdown stays available below.
[Agentes e tarefas](#agentes-e-tarefas) reads each child's `context` from the already-loaded family page, retaining the clock, chevron
and stop action. Existing SSE invalidation refreshes those measurements without a transcript request per child.

### Agentes e tarefas

The header's agent button pushes **Agentes e tarefas** onto the conversation's own navigation stack, with the system
back button, instead of a grabber sheet with **Concluir**. It is a `ConversationRoute` with `agents: true`; the screen
reuses the live `ConversationStore` of the conversation below it (a weak registry in `SessionStore`) and keeps it
listening while it covers that conversation, so counts, states and child context stay live without a second store.
`ConversationProjection.work` lists **every** direct subagent of the owner, running or finished, plus running
background shells, in one list ordered by start time, newest first (ties by ID); running work is not promoted. Each
row has the same layout: agent, task title, state (Em execução with elapsed time, Concluído, Erro, Interrompido or
Encerrado with duration), chevron and child context/cache line. Only running rows show the stop button (and swipe/menu
stop); the column stays reserved so rows line up. State comes from `/session/active` first, then the child's
`outcome`, then its `subagent` tool status. The header button appears whenever the list has an entry: green with the
running count while something runs, neutral without a number otherwise.

One row is one child session. A `subagent` call's child ID reaches its part only through ephemeral
`session.tool.progress` and the final result, so a reloaded **running** call has `metadata: {}`. Production showed
such a call as a second "Em execução" row without context that opened the root. `ConversationProjection.subagentLinks`
now links calls to children: the part's `sessionID`, a continuation's `input.sessionID`, or else the first unclaimed
child of the owner with the same agent created within 5 s before to 60 s after the call ran. A linked call only feeds
its child's row (the running call's start is that row's elapsed time); the transcript's subagent card opens the same
child. A running call with no child yet is shown as **Iniciando**, without chevron, stop or navigation, and only while
the owner is active; stale running parts and failed calls without a child stay in the transcript only. The header
count uses the same deduplicated rows; the "Respondeu · N agentes rodando" banner already counts active sessions.

Opening a child pushes it above the list, so Back returns to the list and then to the conversation; **Voltar à sessão
principal** returns straight to the parent conversation, skipping its agents screen. A shell row without a child pops
back and reveals its tool. No other screen had an agent list (Detalhes da sessão shows only the descendants' cost),
so there is a single list component. Verify after `build-for-testing` with
`python3 packages/ios-custom/script/test-agents-screen.py --device … --derived … --home <sandbox> --server-url … --evidence …`
(optionally `--theme openchamber-light`): it imports a parent with succeeded, failed and interrupted children plus one
child made running by a Luna 6 / low `sleep`, runs `OpenCodeUITests/ConversationAgentsTests`, then interrupts and
deletes the family.

### Recursos das sessões (simulador, emulador, Chrome) — 25 October

Simulators, Android emulators and Chrome browsers that agents use on the Mac can be watched and controlled from the
app, also with the Mac locked. The contract, hub routes, adapter interface and lock are specified in
`packages/plugin-app-custom/docs/resources.md`; `OpenCodeKit/SessionResources.swift` mirrors it. The viewer lives in
`OpenCode/SessionResources/`: the shared shell (`ResourceViewer.swift`, `ResourceViewerModel.swift`,
`ResourceSurface.swift`) and one folder per kind (`IOSSimulator/`, `AndroidEmulator/`, `Chrome/`), so kinds evolve
without touching each other. `SessionStore.openResource` presents it full screen above everything;
`-OpenCodeOpenResource <id>` opens one at launch for tests.

**Stream delivery (25 October).** The viewer acknowledges frames, so the hub keeps at most three in flight and only
the newest waiting (a slow or cellular link sees a recent picture, never a growing backlog); it asks for the
`economy` profile on cellular or Low Data Mode, takes control on the open socket (`auth`) instead of reconnecting,
reconnects on a missed heartbeat with a backoff that restarts after success, never reconnects after the viewer
closes, pauses in the background and resumes at once. A long press on the status pill lists frame age (capture → on
screen, clock-corrected), capture → device, capture → hub, decode, round trip, rate and quality. Details in
`docs/resources.md` ("Delivery and flow control"); `ResourceStreamTelemetry` in OpenCodeKit holds the measurements.

The shell is the approved layout B: the stream fills the screen and glass controls float above it (close, status
pill with the frame age or the hub round trip, who controls it, a side column of kind tools, **Assumir controle**). Taking control
makes touches (multi-touch, normalized to the frame) and the iPhone keyboard go to the resource, draws a primary
border and hides the controls. Hiding/showing never steals a touch: while watching, touches do not reach the
resource, so a tap on the screen toggles the controls; in control, every touch on the screen goes to the resource
except on floating controls, which register their frames (`.excludedFromTouches`). A small edge handle, draggable
along the edge, brings the controls back, and the **Você no controle** pill offers **Mostrar controles** and
**Devolver controle**. Floating controls that stay visible in control (Android's navigation pill) are also draggable
anywhere with `.resourceDraggable(key)`, remembered per key. Floating controls use `.resourceGlass` (material tinted with the
theme background, hairline border, shadow) rather than Liquid Glass, for contrast over any page in both themes.

**Agentes e tarefas (layout 1B):** the conversation header pill adds a devices icon and the count of running
resources of the family beside the agents. The screen lists **Esta sessão · <agente>** (resources the session itself
used) above **Subagentes**, where each subagent row carries its resources on a tree line (or **Sem recursos**). Rows
show a snapshot thumbnail (refreshed every 5 s while visible, `custom.resources/snapshot` at 240 px), an **AO VIVO**
badge, kind, name and state (Agente usando, Ao vivo, Livre, Você no controle, Desligado, Encerrado); tapping opens the
viewer, and stopped/ended ones can be removed from the list. `ConversationStore.resources` reloads on
`rpc.custom.resources.changed`. `opencode-resource:` links in responses and the **Abrir …** buttons of shell tool
details (from `metadata.resources`) open the viewer.

**Chrome (layout 4B, `Chrome/ChromeResourceView.swift`).** Instead of side tools, a Safari-style address bar at the
bottom: Chrome glyph, the address (lock for HTTPS and loopback origins; tap to edit in control, the whole address
selected, Return navigates), reload; below it back, forward, **Assumir controle**/**Devolver** and **…** (show the
keyboard, the browser's tabs to follow another one, copy the address). The bar stays visible in control and rises
with the keyboard, then keeps only the address row with **Devolver**. When the page focuses an editable field the
keyboard opens by itself with the field's traits (`ChromeKeyboard` in OpenCodeKit): a password field gets secure
entry and `.password`, so iOS offers **Passwords** AutoFill; e-mail/username, URL, numbers, search and one-time codes
get their keyboards and content types. Typing goes straight to the page (`insertText`) and is never logged. The tab
state comes from the hub's `meta` (`ChromeViewerState`). After `build-for-testing`, run
`bun packages/ios-custom/script/test-chrome-resource.ts --device <sim> --derived … --evidence … --server-url … --home <sandbox> [--theme openchamber-light]`:
it starts the login fixture, opens a headless Pixel-sized Chrome through the sandbox's own shell (so the plugin's
hook gives it a CDP port, as for an agent), registers it in the sandbox hub and runs
`OpenCodeUITests/ChromeResourceTests` (watch, take control, type e-mail and password, submit, scroll, address bar,
back, give back), then closes the browser and removes the registration.

Verify after `build-for-testing` with your own booted target simulator:
`python3 packages/ios-custom/script/test-resources.py --device <app-sim> --target <target-sim> --derived … --home <sandbox> --server-url … --evidence … [--theme openchamber-light] [--lock]`.
It registers the target in the sandbox hub, measures the stream, runs `OpenCodeUITests/ResourceViewerTests`; with
`--discovery` the session finds the target by name (and, with `--android emulator-NNNN`, your own running emulator by
serial) and a subagent opens a headless Chrome through real Luna 6 / low shell calls, then
`OpenCodeUITests/ResourceListTests` checks the pill, the list, and opening every kind from its row and its
`opencode-resource:` link; with
`--lock` it checks with one Luna 6 / low shell call that the agent is refused while Alexandre holds control and is told
when control returns.

**iOS Simulator (layout 2B, `IOSSimulator/IOSSimulatorResourceView.swift`).** The live serve-sim stream (see
`docs/resources-ios-simulator.md`) with the side column **Início**, **Girar** (rotate right), **Teclado** and
**Captura de tela**; the first three wait for control. In landscape the hub reports `meta.rotation` and the shell's
frame and touch overlay turn the unrotated framebuffer upright (`OpenCodeKit/ResourceScreenGeometry.swift`). Typing
uses the shell's keyboard bridge: short US text goes as keys, accents and longer text through the simulator's paste.
**Captura de tela** fetches the full-size, upright `simctl` screenshot through the snapshot RPC and pops the share
sheet over the button (**Salvar imagem**, **Copiar**…), removing the temporary file when it closes. After
`build-for-testing`, with your own booted target simulator:
`python3 packages/ios-custom/script/test-ios-simulator-resource.py --device <app-sim> --target <target-sim> --derived … --home <sandbox> --server-url … --evidence … [--theme openchamber-light]`.
It opens a local page in the target's Safari, measures touch → frame through the hub in control, then runs
`OpenCodeUITests/IOSSimulatorResourceTests` (watch, take control, tap the field, type `Ola acao 42 á` + Return and
check what the page received, rotate, capture, Início, give back). `OpenCodeTests/ResourceSurfaceTests` covers the
rotated touch mapping and the keyboard tool staying in step with the field's focus.

**Android Emulator (layout 3B).** `AndroidEmulator/AndroidEmulatorResourceView.swift` has no side column: a glass
pill with **Voltar**, **Início**, **Recentes** and the keyboard, plus a round **…** menu (rotate left/right, lock,
volume), sits under **Assumir controle** / **Devolver controle** while the controls show and is disabled until
Alexandre holds control. In control, with the controls hidden, the same pill floats over the screen (default bottom
right) and drags anywhere, remembered under `android-navigation`, since any fixed place would cover some app's bottom
bar. Frames arrive upright (the adapter rotates them with the display), so touches need no rotation on the phone.
Verify after `build-for-testing` with your own running emulator:
`python3 packages/ios-custom/script/test-resources-android.py --device <app-sim> --serial emulator-<port> --derived … --home <sandbox> --server-url … --evidence … [--theme openchamber-light]`.
It registers the emulator in the sandbox hub, measures the stream and input latency over the hub WebSocket, runs
`OpenCodeUITests/AndroidEmulatorViewerTests` (watch, take control, drag the pill, tap a contact field, type
`Olá João 123` with the iPhone keyboard, Início, Recentes, Voltar, give back) and checks over adb that the text
reached the field and that the launcher and the overview appeared.

`ContextUsage` in OpenCodeKit owns the shared math, pt-BR abbreviations, VoiceOver wording and >80% warning threshold.
A bounded store-local formatter cache is keyed by step ID, measured tokens and resolved context limit, so text/tool
deltas do not repeatedly format metrics. The ring clamps drawing only, not the displayed percentage or token count.
All contracts already exist unchanged on installed `1042585c285c25d4b5d4fd292d0b7eb5fb7c470e`.

After building for **OpenCode Abertura** with `ios-abertura-derived`, run
`python3 packages/ios-custom/script/test-context-usage.py`. It imports only its own histories into a fake repository,
uses one real Luna-6/low child to verify live family updates in both themes, and interrupts/removes its sessions and
shells afterwards. Every launch supplies the explicit sandbox 4177 URL/password. Screenshots and the cleanup ledger
are under `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-cache-prints/review-1/`.

## Language

The app is Portuguese (pt-BR) only, since it is for personal use. User-visible strings are written in pt-BR, which is
the project's development language; there is no English source copy.

## Themes

No view uses a fixed color: every color comes from semantic tokens of a registered theme. Themes are generated, not
written by hand: a Bun script in this package runs the custom web app's own resolver
(`packages/ui-custom/src/theme`) over the OpenCode theme JSON files and writes the resolved tokens, which the app
bundles. Adding a theme means running the script. Você → Aparência lists the 38 generated families with previews,
one row per family. OpenChamber with **Sistema** is the default. **Sistema**, **Claro** and **Escuro** select the
variant independently of the family; Sistema follows device changes live. Family and appearance persist locally.
`-OpenCodeTheme <variant>` takes precedence for the whole launch, including over settings changes. The old
`OpenCodeTheme` preference migrates its family; new preferences are `OpenCodeThemeFamily` and `OpenCodeAppearance`.

### Typography and readable roles

`OpenCode/AppTypography.swift` owns the shared SF scale. The approved size adjustment restores Apple-default bases,
without the earlier blanket ~9% increase. At the default Dynamic Type size the styles are:

| Style | Points | Use |
| --- | ---: | --- |
| `largeTitle` | 34 | Native large navigation title |
| `title` | 20 | H1 response headings |
| `heading` / `body` / `message` | 17 | Row titles, H2–H3, prose and user/composer text (22.5 pt body/message line height) |
| `preview` / `secondary` | 15 | Session previews, row times, controls and code |
| `caption` / `path` | 13 | Response footer, paths and regular-weight message expansion control |
| `footnote` | 12 | Small counts |
| `micro` | 11 | Avatar badges |
| `navigation` | 17, capped | Native/custom bar titles; conversation title is regular |
| `chrome` / `bubbleMeta` | 12, capped | Composer model/agent and undo/copy/time below user bubbles |
| `mcp` | 11, capped | MCP pill (20 pt high, 6 pt horizontal padding, 5 pt dot) |
| `metrics` | 9, capped | Composer usage line (8 pt ring) |

The quotation tray label and its raised inline numbers also use the capped 12 pt `chrome` role. Quoted
passages/comments keep their reading styles and Dynamic Type growth; the quote decoration/theme/selection pipeline
remains shared with the integrated quotation implementation.

SwiftUI uses `appFont`; TextKit uses `AppTypography.font`/`lineHeight`, with the same Dynamic Type category and
named styles. Capped roles stop growing at the default (`large`) category in both SwiftUI and UIKit; reading text
continues through accessibility sizes. Icons have a separate optical scale (`appSymbol`). The list uses
16 pt side margins, a 44 pt avatar plus 12 pt gap, 14 pt row padding and native pixel-aligned separators.
Rows and quota labels reflow at accessibility sizes. Native fixed-height tab captions are bounded by the caption
style; the master accessory fits its full labels onto one line instead of drawing text outside the system capsule.

The generator retains each family's surfaces and hue. `textMuted` makes paths quieter but AA-readable;
`textSecondary` is one step brighter, and `textPreview` approaches body text. `textAccent` is readable interactive
text without changing the palette's primary button fill. Success/info/error text is derived to meet 4.5:1 against
the actual background, surface, raised surface and tool surface. `infoFill`/`onInfo` are a separate light fill/dark
foreground pair for **Responder**. `userBubbleText` and `userBubbleSecondary` are evaluated against the composited
bubble, whose brightness differs considerably across families. Generated role maps mark these as `ios-derived-*`.
Syntax, code-line numbers and added/removed diff text also receive the same hue-preserving AA floor on code/table
surfaces; this fixes light-family syntax colors without replacing their palette with another family's colors.
No shadow, gradient, material or elevation is introduced by this pass.

`glassSecondary` covers metadata on existing native glass (voice, MCP capsule/panel, inactive tabs and master accessory), including a
conservative palette-derived glass luminance bound in addition to ordinary surfaces. It changes neither the
voice waveform/state's `primary` color nor the tonal destructive button. The response text, user bubble and
composer share the named scale; rendered-text and table measurement keys include the Dynamic Type category,
and changing the attributed font clears cached widths/heights. Numbered lists retain hanging indents with a
24 pt minimum marker column, regular body/markers (strong spans remain semibold) and 10 pt between items; prose uses 14 pt paragraph spacing.
Context/cache stays in the fixed, left-aligned line below the composer, never repeated in response footers.
The collapsed-bubble regression derives its expected height from two scaled 22.5 pt message lines. The footnote UI selector measures the body font before
tapping its inline reference, while the copy/selection/expansion behavior assertions remain unchanged.
The Sessões test helper searches unmounted rows with fast swipes, then uses slow adjustment once mounted;
it retains the same 60-second budget and requires the whole target row above the native accessory/tab bar.
The live row-metadata test narrows its root/long-path checks with the existing project chips, excluding unrelated
parallel-test histories without changing server preferences or hiding any assertion.

Run `bun packages/ios-custom/script/generate-themes.ts`, then `bun packages/ios-custom/script/check-theme-contrast.ts`
to audit all 76 variants. `capture-polish.py` and `test-polish.py` use only **OpenCode Polimento**, explicit sandbox
URL/password and `ios-polimento-derived`; captures and results go to `$TMPDIR/opencode/ios-polimento-prints`.

Polish verification: Debug/test and Release builds are warning-free; 289 Kit tests and all 64 hosted app tests
pass. The final focused UI runs pass in both themes: row metadata, session reading, grouping, user collapse/copy/
search and attachment/context presentation, MCP chips, fixed usage, voice layout/keyboard and Markdown. The
scroll/follow/menu regressions pass as well; explicit live model/audio scenarios were not run. All owned imports
were deleted. `verification.json` in the evidence directory records the absolute screenshot/result paths and
all 76 contrast variants, including OpenChamber, Dracula and GitHub in dark/light.

The 12-second simulator trace measured p95 frame times of 16.67 → 16.67 ms for Sessões, 16.67 → 16.67 ms with
preview updates, and 18.46 → 16.67 ms for the conversation. CPU totals were 2413 → 2220, 3546 → 2303 and
4682 → 3138 ms respectively. These are single local samples on a shared Mac, not isolated or device benchmarks.

#### Approved size/viewport adjustment — 23 October

The size pass uses **OpenCode Tamanhos 1/2/3** (440 pt iPhone 17 Pro Max and two iPhone 18 Pro simulators), isolated
`ios-tamanhos-derived*` products, sandbox **4183**, and a separately owned master/quotation sandbox. The conversation
owns a 40 pt bottom band for usage; Nova sessão and the empty master instead retain the native home-indicator safe
area plus 6 pt padding. Extending their container bottom interfered with keyboard restoration after interactive
selector dismissal, so their native safe-area ownership is deliberate.

Final coverage: **320 Kit tests**, **86 hosted cases** (84 passed, two opt-in real-audio/proxy probes skipped), and
**132 UI methods** (131 passed, the explicit opt-in live-child replay skipped). The full three-simulator sweep took
**36m52s**, followed by focused fixes/reruns for real viewport bounds, native menu readiness, fixture registration,
two-line heights and interactive selector focus. No assertion of behavior was replaced by a tap retry. The leased
iPhone 14 passed both complete Markdown documents and the growth fixture; AssistiveTouch was moved out of the way,
restored afterwards, and the private automation daemon/device lease released.

The matching 12-second simulator drivers kept p95 at **16.67 → 16.67 ms** in Sessões, preview updates and the
conversation. Process CPU was **2084 → 2403**, **2407 → 2501** and **2880 → 3455 ms** respectively: this is not a CPU
improvement claim, and the smaller scale exposes more text per viewport. The three direct iPhone runs had median
long-scroll p95 **16.68 ms**; growth had **36.34 fps / 82.46 ms p95 / 0 pt backward**. XCTest-video growth samples are
recorded separately rather than compared with the direct driver. These are shared-machine samples, not an isolated
benchmark or a guarantee. Debug/Release builds and the 76-theme contrast audit are warning-free/passing.

Both-theme/default/xxxLarge comparisons (`hoje · ajustada (mockup) · implementada`), accessibility captures, inline
quotation before/after images, xcresults, source/binary manifests and cleanup records live under
`$TMPDIR/opencode/ios-tamanhos-prints/`. The approved single dark mockup is reused unchanged as layout guidance in
the comparison's center column; the native captures, not generated mockup pixels, establish sizes and theme behavior.

## Third screen: Você (wave 8)

Native grouped lists expose Aparência, Servidor and Sobre, retaining the AR tab icon and quota ring.
Theme changes update the shared SwiftUI environment without replacing the session runtime: existing conversation,
drafts, sheets, avatars, tab icon and UIKit text views receive the new theme. A small UIKit bridge refreshes already
mounted navigation/tab bars as well as their appearance proxies. No theme colors are copied into views.

- **Servers:** a built-in, nonremovable server plus named saved entries. Add/edit uses a URL and optional masked
  password. **Testar conexão** performs only authenticated `GET /api/info`, with a five-second timeout and explicit
  success/failure before Save becomes available. A failed test may still be saved (for an offline server). URLs may
  not contain credentials, queries or fragments. Remove requires confirmation and deletes only the local credential,
  not backend sessions. Removing an active entry returns to the built-in entry.
- **Credentials:** `ServerStore` persists only IDs, names, URLs and the selected ID in UserDefaults. `ServerCredentials`
  uses generic-password Keychain items, nonsynchronizing and
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; passwords/tokens never enter preferences, app logs or URLs.
  Tests inject an in-memory Keychain backend. The system may independently offer Password AutoFill's save prompt;
  sandbox automation always chooses **Agora Não**, never saving test credentials there.
- **Switching:** `AppRuntime` awaits the old session store's stop, cancels/awaits its shared SSE task and draft-pruning
  task, flushes drafts/reading metadata, then replaces the entire server-bound view identity. The new `SessionStore`
  has its own hub, conversation path, catalog and alerts. Drafts, reading positions and alert dedupe retain their
  existing URL-scoped keys, so two entries for the same URL intentionally share that server's local state.
  The initial `-OpenCodeOpenSession` is not replayed on a replacement server runtime.
- **Pairing:** camera scanning uses VisionKit's native QR scanner and a pt-BR camera permission description. Manual
  paste is also available, including on the simulator or after camera denial. Both `{"code","urls"}` JSON and
  `<url>/auth/connect/<code>` links use the same parser. Redemption issues parallel unauthenticated JSON GETs,
  retains the first successful token, and mirrors the web's preference for URL 0: wait at most one extra second for
  its answer, then validate the winning token there with `/api/info`. A 401 proves an expired/spent code; unreachable
  addresses do not. A redeemed token remains available to save even if the subsequent health check fails.
- **About:** version/build, `OpenCodeCommit` (or desenvolvimento), current server version and the GitHub README link.
- **Child messages:** presentation and copy strip only the exact backend prefix
  `You are a subagent spawned by another session.\n`, and only in child user messages. Wire history remains untouched;
  changed wording, leading whitespace, CRLF or a missing newline is deliberately displayed in full.

### Sandbox safety and verification

Every launch/relaunch **must** supply `-OpenCodeServerURL http://127.0.0.1:4177` plus the sandbox password in the
environment, as shown below. This replaces the built-in entry **in memory**, selects it at each launch ahead of any
saved selection, and uses a separate registry keyed by the override URL. With a loopback launch override, add, edit,
select, test and pairing reject non-loopback destinations before any request. Production is never saved, selected or
tested by the runners. The one default-URL constant and the private-host ATS exception are unchanged.

After `xcodebuild … build-for-testing`, run:

```sh
python3 packages/ios-custom/script/test-settings.py
OPENCODE_TEST_THEME=openchamber-light python3 packages/ios-custom/script/test-settings.py \
  OpenCodeUITests/SettingsTests/testManualServersTestSwitchEditRemoveAndPairing \
  OpenCodeUITests/SettingsTests/testChildPreambleHiddenAndCopyUsesAuthoredText
```

The runner creates/deletes only its own imported root/child histories (no model call), requests a fresh pairing code
with `POST /api/pair`, and redeems it through the real app. Dark uses QR JSON; light uses the printed-link shape.
The simulator cannot scan a camera image: a **DEBUG-only**, explicit sandbox launch environment enables the
**Usar código de teste do sandbox** button. It injects the payload into the same parsing/redemption path; no token is
fabricated. The same debug environment prefills the launch password in the manual form, avoiding secret `typeText`
actions in XCTest recordings. Neither hook is compiled into Release. Configured xctestrun files are private and
removed after the run. The runner never resets seeds, answers seeded requests or operates production services.
UI checks cover live theme/appearance changes across settings/Sessões/Conversa, offline-server isolation/reconnect,
manual health results, pairing plus a real token-backed SSE connection, edit/remove and the exact child prefix.
After the live-theme test leaves OpenChamber/Sistema selected, run
`python3 packages/ios-custom/script/verify-system-appearance.py` to change the dedicated simulator from light → dark →
light **in one app process**, compare the real background pixels with generated tokens and capture both modes.
It launches with the explicit sandbox URL/password and no theme override, terminates only that app afterwards and
restores the simulator's previous appearance.
Screenshots with the clean 10:58 status bar and verification JSON live in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-onda8-prints/`.
`SettingsTests.swift` in OpenCodeKit covers the 38-family registry, variant/launch precedence, URL/pair parsing,
parallel redemption/preferred-first health, server CRUD/selection/credential failures and preamble exactness.

Wave-8 verification: **123 Swift Testing tests**, warning-free simulator build and test build, all three new UI
cases plus light-mode server/child repeats pass. Existing regressions also pass: four app-hosted tests, six reading
continuity cases (one additional unread case correctly skips after viewed acknowledgement), four session/reading
cases and six subagent/alert cases. The sandbox seed's permission and question remain pending; no seed reset was run.

## Nova sessão (wave 9)

The orange **+** in Sessões pushes a local draft, not a server Session. The tab bar and "Sessão mestra" accessory are
hidden, as in a conversation, and the existing V2 composer focuses automatically. The repository avatar uses the
same monogram/color projection as Sessões. MCP chips wrap centrally above the repository/directory selectors. With a
second selector and an open keyboard, the avatar/question compact slightly to keep all chips and the preview note
visible; with the keyboard hidden, the introduction is centered in the available space.

Typography uses the shared scale (see [Typography and readable roles](#typography-and-readable-roles)): the bar title
is `navigation` with the conversation's `appSymbol(.navigation)` back chevron and 16 pt margin; the question is
`title`; the 44 pt avatar uses the Sessões monogram (`message`, medium) or an `action` Chats symbol; MCP chips use
`caption` (growing from a 32 pt minimum height), with `caption` loading/empty/error lines and a `footnote` preview note;
project/directory/base selectors use `secondary` with `disclosure` chevrons and a `micro` monogram in their 23 pt avatar.
The Projeto sheet's 38 pt avatars use `secondary`/`action`. The no-project state keeps the native
`ContentUnavailableView`, like Sessões and Arquivadas. The shared composer (Nova sessão, conversations, children and
the master) has no visible placeholder; its text view keeps the VoiceOver label **Mensagem**.
`OpenCodeUITests/NewSessionTypographyTests` checks that and captures project, Chats and, when the isolated sandbox
has no selected projects, the empty state (otherwise it skips).

- **Project:** the Sessões `+` starts in **Chats**, even with a repository filter active, unless the restored
  new-session draft is project work in progress (text or attachments). Otherwise an active Sessões repository filter
  takes precedence, then an explicitly restored draft keeps its project; a fresh draft uses
  `custom.preferences.data.projects["local"].lastProject`, then the first selected project. The conversation menu's
  Nova sessão still inherits its origin (Chats for a chat). The Projeto sheet lists **Chats** first (when the server
  has `custom.chats`), then preserves saved selection order and searches display names without sorting; see [Chats](#chats-destination) below. The `+` in the Projeto
  header ("Adicionar projeto") opens the folder explorer described below; selecting/opening the draft's
  project calls `project.touch` without reordering the saved list. No selected projects produces an honest empty state,
  and an empty Projeto list points to that `+`.
- **Adicionar repositório:** shared by Projeto and Sessões' repository filters, it ports the web's project explorer
  (`app-custom/src/workspaces/selection/explorer.tsx`, single selection). It starts at `~/Dev/`, resolved from the
  server home reported by `custom.directories/home` (the server's default Location when unavailable). The path field
  doubles as location and prefix filter (`~/Dev/op`); tapping a folder enters it, and `..` at the top of the list
  goes up while not filtering. Hidden folders appear with **Mostrar ocultas** or a `.` filter. Rows list only folders
  from `GET /api/fs/list`, already selected projects show **Adicionado**, and the home and `/` are never offered.
  The action under the path adds the current or exactly named folder, or **Criar e adicionar** creates its final
  segment with `custom.directories/create`; each row's `+` adds that folder. Adding resolves `GET /api/location` for
  the folder (registering the server project, as the web's sidebar does) and then sends `project.open`. The web's
  batch selection (sidebar/home) and keyboard hints are not ported. A folder inside another repository is saved like
  on the web but, as before, iOS lists only saved folders that match a server project root or sandbox.
- **Directory:** `POST /api/worktree/refresh` (as the web's sidebar does; a failed refresh is ignored) prunes checkouts
  removed outside OpenCode and discovers new ones, then `GET /api/worktree?projectID=…`, known project worktrees and
  sandboxes are merged in that order, deduplicated and stripped of the root. `custom.worktrees/branches` labels each
  checkout without booting every Location; the folder name is the fallback (detached HEADs have no branch). The root
  uses its current branch (VCS, then the branches RPC), never the `main` sentinel as a guessed branch, exactly like the
  web's root label: "custom ⌄" is the directory selector, not a branch picker. Search appears only with ten or more
  existing worktrees. A failed inventory or branches read shows "Não foi possível listar as worktrees · Tentar
  novamente" in the sheet instead of a silently shorter list; an empty inventory says so. Non-Git projects keep their
  principal directory and explain that worktrees are unavailable. **+ Nova worktree** is a labeled button in the
  Diretório header (the web's "+ New"), never hidden by listing errors: it selects that destination and closes the
  sheet; while selected it is filled with a checkmark, no list row is checked and a note says it will be created on
  send. The main selector then shows "+ Nova worktree" plus "a partir de …". `NewSessionWorktreeTests` (UI) reproduces
  a root on `custom` with detached, named and externally removed worktrees; its environment provides
  `OPENCODE_TEST_GIT_REPO` and `OPENCODE_TEST_STALE_WORKTREE`.
  Projeto and Diretório wait for the composer's real keyboard dismissal before presentation. Closing a selector,
  including a swipe without changes, restores composer focus; the base-branch sheet instead owns its search keyboard
  while presented. The shared editor suppresses background focus restoration until the selector has closed.
- **Defaults:** the native client uses the web's **last-used** destination rule, separately per server URL/project:
  `local` means root, `workspace` means **Nova worktree** on the next implicit selection. It remembers the category,
  not the last existing path/base branch. An explicit restored draft retains its destination. The pure resolver also
  covers the web's `local` and `new` modes; Você does not yet expose a global destination-mode setting. This client
  memory is not `custom.preferences` and cannot read the browser's local `settings.v3`.
- **New worktree:** choosing it creates nothing. "a partir de …" opens a searchable base-branch sheet using the root's
  `/api/vcs/branch`, 100-ms debounce and limit 50; the current branch is included/deduplicated. There is no branch-name
  field in this flow: the base-branch sheet uses a large native presentation with its search focused so results stay
  usable above the keyboard. There is no folder-location promise. Send uses only
  `{projectID,from:<canonical>,branch:<base>}` in `POST /api/worktree`;
  the backend's configured strategy chooses its folder and may create a detached checkout.
- **MCPs:** `/api/mcp` plus `/api/config` are Location-scoped. Connected servers come first; within each group,
  `codex-computer-use`, `safari-devtools`, then alphabetical names. The visible order is frozen until reopening or
  selecting another destination; taps/refreshes update state without moving chips. Connected/disabled/failed/needs-login/pending have semantic dots, dashed disabled
  borders and a pulsing pending state. VoiceOver exposes switches. Root/existing taps connect/disconnect immediately
  for **all sessions of that directory**. New-worktree preview starts from configuration defaults (not the root's
  runtime connection state); taps only save intent, with "Vale quando a worktree for criada".
  Loading, empty and retry states are explicit. Login-required chips explain that authentication belongs in the web
  app; iOS never starts OAuth.
- **Model/effort/agent:** the same wave-2 pickers and wave-3 editor, suggestions, attachments and fullscreen composer
  are reused. Initial valid model: explicit draft → saved default → agent configuration → location configuration →
  native recent history → first available model. Explicit effort includes "Padrão"; otherwise the saved default's
  variant wins for that model, then per-model preference, agent/configured variant, constrained to available variants.
  Recent model identities are server-local and updated after successful conversation/new-session sends. Hidden and
  subagent-only agents are not choices.
  **Alexandre, 24/10: a escolha vira o padrão.** Once a Session exists (successful send, or a later failure after
  creation), a model/effort chosen in the picker on this screen (project or Chats) becomes the saved default above:
  `custom.preferences` `model.default`, the same preference as the picker's **Usar como padrão para novas sessões**
  and the web's **Use as default for new sessions**, so the next new session starts with it on iOS and on the web.
  Only a choice made here counts: a send without touching the picker, or Nova sessão from a conversation sending the
  inherited model/effort unchanged, keeps the saved default (changing it there does count). It is written after
  creation without delaying navigation, and skipped when unchanged; a failed write shows a toast. If that model is
  no longer available or enabled, the previous order applies; if it lost the effort, the model keeps its per-model
  effort, then agent/configured. The master keeps the plugin's own preferred model, and agents are unchanged.
  The web itself does not adopt its last choice: it only honors this preference, set explicitly there.
  Kit tests cover `NewSessionProjection.remembered` and the fallbacks;
  `OpenCodeUITests/NewSessionModelDefaultTests` chooses Luna 6 · low in Chats, creates the chat (one tiny send), finds
  it again on the next Nova sessão, checks that an inherited menu Nova sessão (second send) keeps the default, and
  that missing models/efforts fall back (no send). It needs Chats and `llm-proxy` Luna/Astra in an isolated sandbox
  and restores the saved default. `/compact` and `/btw` require an existing session and are disabled here;
  known backend slash commands use the command endpoint, including when typed without choosing a suggestion.
- **Send:** generate the Session ID on the client → resolve/create the worktree → await live MCP mutations and apply/
  verify explicit destination intents → create Session with agent/model/Location → serialize attachments/tokens with
  the existing wave-3 encoder and submit prompt (or backend command). Progress uses the shared send button. Success
  replaces the draft route with the conversation, so Back goes directly to Sessões, and clears the new-session draft.
- **Errors:** worktree/MCP failures do not create a Session. Filesystem creation is not atomic with later requests:
  any newly created checkout is retained as the draft's selected destination after MCP/session failure, preventing
  another checkout on retry. A failure after Session creation opens that conversation with the text/tokens/attachments
  transferred to its draft and an error toast. Nothing silently deletes a checkout or claims filesystem rollback.
- **Draft:** exactly one `new-session` draft per server URL, using the same protected/atomic `DraftPersistence` file
  and attachment storage as conversations. Its snapshot includes project, destination, base branch, MCP intent maps,
  document/token ranges, cursor, attachments, model/variant and agent. It persists while editing, on leaving and on
  background/server switch, restores after relaunch, and is excluded from missing-Session pruning.

`ProjectExplorerTests` (Swift Testing) cover the explorer's query, `..`, filtering, blocking and submission rules and
the `fs.list` path resolution. `AddProjectTests` (UI) start at `~/Dev/`, go up, filter, quick-add an existing folder,
create and add another, and check the Nova worktree header choice, its selected state and per-project memory. Run them
with `script/test-isolated.py --environment <json>` whose `OPENCODE_TEST_ADD_PROJECT_DIR` is an isolated folder
containing `alvo/` (the test creates `criado/`); the second case adds the server home's `Dev/opencode2` if needed.

### Chats destination

Like the web's project selector (`packages/app-custom/src/new-session/project/selector.tsx`), Nova sessão offers
**Chats**: a session without a repository in a managed `custom.chats/<date>/session-<uuid>` directory. It is listed
first in Projeto, before every project (speech bubble, filtered by its label), the default of the Sessões `+` (see
Project above), offered by the no-project empty state, preselected by an active Chats chip in Sessões, and kept by a
restored chat draft unless a repository filter is active. The directory selector is
hidden. Nothing is allocated until Send, as for the master: catalogs and MCP defaults load from the chats root, and MCP
taps only record intent (“Vale quando o chat for criado”). Send allocates (or reuses the draft's
allocation) → `claim` with the draft's fixed Session ID → MCP intents on the allocated directory → create Session →
`confirm` (ignored on failure, as on the web; the plugin reconciles pending claims) → prompt. Failures before Session
creation keep the allocation in the protected draft, so a retry claims the same directory instead of allocating another.

`NewSessionChatsTests` (UI) checks the Sessões `+` opens in Chats, Chats stays first in Projeto (also while searching
"chat"), sends a Luna 6/low prompt, checks Recentes is unchanged and the Chats chip lists the new row and preselects
Chats. Its second case checks the `+` with a repository filter, a restored project draft with text, and an emptied one.
Run it against an isolated sandbox with one selected project (`OPENCODE_TEST_CHATS_PROJECT`, default `demo`) and an
empty or chat new-session draft; it creates one real chat per run. `script/test-new-session.py` accepts
`OPENCODE_TEST_SERVER_URL`, `OPENCODE_TEST_HOME`, `OPENCODE_TEST_DERIVED`, `OPENCODE_TEST_SIMULATOR` and
`OPENCODE_TEST_EVIDENCE` to run `NewSessionTests` against another isolated sandbox and simulator.

`NewSessionView`/`NewSessionStore` own presentation and navigation; selectors live in `NewSessionSelectors.swift`.
`OpenCodeKit/NewSession.swift` owns projections and the narrow typed HTTP contracts, and
`NewSessionSubmission.swift` owns the fake-client-testable ordered pipeline and phase-specific failures. The existing
`ConversationStore` exposes a draft-only Location mode for the shared composer; no provisional server Session or
separate composer copy is created.

### Sandbox verification

After the simulator `build-for-testing`, run `python3 packages/ios-custom/script/test-new-session.py` and repeat with
`OPENCODE_TEST_THEME=openchamber-light`. Every app launch/relaunch supplies the explicit sandbox URL/password. The
runner checks entry with/without a repository filter, project/add-picker switching, root/existing/new directories,
only safari-devtools live/preview toggles, base-branch selection, keyboard/layout, route replacement and persistent
draft restoration. An invalid base is injected **only into the stopped simulator app's own draft**, without changing
Git refs or adding a production test hook. Root/existing/new sends use Luna 6/low/build and tiny no-tool prompts.
Screenshots and JSON evidence go to
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-onda9-prints/`.
The checkout path is opaque: the runner verifies its Git common directory belongs to the fake repository, rather
than assuming the sandbox's configured strategy creates folders beneath the sandbox home. **No verification checkout
is retained:** immediately after each send case, verify the fake repository identity, base revision and MCP state,
then call `DELETE /api/worktree` with `{projectID,directory,force:true}`. Failure cleanup uses the same API. The runner
compares the fake repositories' Git worktree registrations and the `~/Worktrees` folder inventory before/after; it
never removes a real repository's folder. New-worktree mockup screenshots are captured before send.
No seeds or pending seed requests are changed, and no production server or physical device is used.

Wave-9 verification: **141 Swift Testing tests**, warning-free simulator build/test build, all three new UI cases in
both themes, and the existing four app-hosted, six reading-continuity, four session/reading, three settings and six
subagent/alert cases pass. The additional unread case skips because its existing viewed watermark cannot be moved
backwards. One first-pass native Details-menu tap missed; the complete session/reading rerun passed without product
or existing-test changes. `execution-ledger.json` in the screenshot directory records the real new Sessions,
worktree identity/base/MCP verification and cleanup; the original permission and question still remain pending.

Wave-9 review adds `test04SelectorKeyboardDismissalAndComposerRestoration`: open each selector from a focused composer,
assert Projeto/Diretório have no keyboard, swipe-dismiss without changing anything, choose items, and prove restored
composer focus by typing without retapping it. Base search owns its keyboard and cannot change the underlying draft.
Both themes capture only the fake repository's five existing worktrees; no verification checkout is kept. Focus
restoration avoids overlapping an interactive sheet-dismissal animation, and selector presentation waits on the
public UIKit keyboard layout guide/did-hide notification rather than a fixed delay.

## LLM proxy (wave 11)

**Você → LLM proxy**, above Aparência, and each provider in the existing Sessões usage strip open the same large
native sheet. Codex and Claude use the approved A3 layout: provider balance, combined weekly quota, capacity and
renewal; tier groups; account state, stacked independent 5-hour/weekly windows, paired renewal dates and
**Mostrar no resumo**. Other tiers remain visible outside the headline balance. Real proxy display names are shown.
The strip retains its existing styling; a selected account name truncates rather than increasing its height.

- **Data and compatibility:** the full hand-written `Subscriptions` contract mirrors `custom.subscriptions/list`,
  `setAutomation` and `consumeReset`, without Location or direct proxy-admin access. All three contracts and their
  backend implementation match installed release `1de0005da68932f4ab7856e464978ad06f99d652`. Missing RPCs degrade to an
  explicit unavailable/update-server message, never blocking sessions or the composer. Unknown status/plan strings
  and added JSON fields do not break decoding; null capacity, quota, inventory and credits remain unknown, not zero.
- **Projection:** `SubscriptionProjection` ports the PWA rules with an injected `now`. Enabled/authenticated Pro Max
  and Pro 20x each contribute one Codex unit; Claude includes Max 20x only. Equivalents are the sum of weekly remaining
  divided by 100; combined percent divides that sum by all members, including exhausted/cooling accounts. No lower-tier
  weighting or partial reassuring totals. Stale, null-capacity and either unobserved elapsed renewal suppress the whole
  weekly balance. Readiness uses authoritative capacity, not rounded percentages. Five-hour average, seven-day pace,
  oldest observation, stable plan/readiness ordering and complete-only inventory aggregation follow the PWA separately.
  Weekly exhaustion hides the five-hour row and both rails. Paid credits sum known values across all displayed accounts.
- **Refresh:** one server-bound observable `SubscriptionStore` is owned by `SessionStore`, shared by both entry points
  and the sheet. It reads initially, every 60 seconds only in foreground, immediately on foreground/SSE reconnect,
  pull-to-refresh and the explicit refresh button. Concurrent reads join one task; opening a fresh sheet only refreshes
  when due. Cached same-server content remains visible during refresh, but a completed failure replaces it with an
  honest unavailable state. Runtime shutdown cancels requests/actions and invalidates their generation before the next
  server runtime exists, so late old-server results are discarded. Observation times remain backend measurement times.
- **Selection:** IDs only are persisted in `OpenCodeSubscriptionSelection.v1`, scoped by server URL/provider. Selecting
  again restores the pool; a successful list removes vanished IDs. Both compact surfaces use that account while the
  large detail header always remains the pool. No model, request routing or backend preference is changed.
- **Actions:** automatic resets and consuming one banked reset require a native confirmation alert with Cancel. Pending
  automation is provider-specific; pending reset is account-specific and prevents duplicates. Every action refetches;
  failures roll back optimistic automation and distinguish `no_credit`, `busy`, `consume_failed`, `update_failed` and
  unsupported RPCs. Consumption has a **110-second HTTP timeout** for the proxy's 90-second path and is never retried
  automatically: an unconfirmed result may already have consumed inventory. Inventory/expiry/non-expiring counts and
  automation state are visible even when weekly capacity is unavailable. Theme roles and VoiceOver values convey state
  independently of color; all dates use local pt-BR 24-hour time with an abbreviated weekday
  (`sáb, 24/10 às 09:49`), including renewals, the header's next renewal and inventory expirations.

### Safe verification

Use only **OpenCode Proxy** (`83335951-0D45-4D53-9884-55047D7F78CA`), with DerivedData
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-proxy-derived`. After `build-for-testing`, run
`python3 packages/ios-custom/script/test-subscriptions.py`, then repeat with `OPENCODE_TEST_THEME=openchamber-light`.
The runner supplies the explicit sandbox URL/password on every launch and writes private xctestrun files, removed
afterwards. Live UI checks only read pools, select locally, open a confirmation and **cancel it**. Confirmed actions run
solely against a DEBUG-only, loopback-gated `SubscriptionTestClient` that never forwards any request to the real proxy.
Its explicit `OPENCODE_PROXY_STUB` scenarios cover pending, success and typed errors. Unit tests use injected clocks,
clients and transport, including the sanitized real snapshot and long-reset request contract. Screenshots/results live in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-onda11-prints/`.

The native segmented control and provider glyphs come from the platform/PWA rather than AI-generated decorations;
alerts replace iOS 27 confirmation popovers to retain an explicit Cancel action. Additional inventory/action rows make
account cards taller than the read-only A3 illustration. No proxy mutation has been exercised live.

Wave-11 verification: **169 Swift Testing tests**, warning-free simulator test build, four new UI cases plus four
app-hosted regressions in both themes. Existing read-only continuity/details/search checks and all three settings
cases also pass; the unread-jump check correctly skips after its viewed watermark has advanced. Settings tests now
reveal links displaced by the new section and wait for the delayed AutoFill overlay before cancelling it. Use the
normal simulator signing configuration when running Keychain/server regressions, not `CODE_SIGNING_ALLOWED=NO`.

## Offline scrolling fixtures and performance checks

Debug builds accept `-OpenCodeScrollFixture conversation` or `-OpenCodeScrollFixture sessions`, optionally
`-OpenCodeFixturePosition top|middle|tail` or a fixture message ID (`msg_scroll_0204` opens deep in a turn whose
first row is not laid out), `-OpenCodeTheme openchamber-light|openchamber-dark` and
`-OpenCodeFixtureUpdates` (four local preview updates per second). This bypasses server setup, SSE and pruning;
the fixture client's HTTP transport rejects every request. Never combine this mode with a live-server test.
The bundled JSON has 300 messages/525 parts and 300 rows. Only sizes, Markdown structure and tool kinds came
from three read-only, 100-message pages; every displayed string/identifier/path is synthetic. The raw pages were deleted.
`script/generate-scroll-fixture.py` documents safe regeneration from temporary GET response files.
Release builds exclude the fixture JSON and compile out its launch mode/client/driver.

Scroll regression scenarios add `-OpenCodeFixturePosition nearTail` (a bookmark three messages above the end, so
the history above it was never measured), `-OpenCodeFixtureStream <ms>` (token-sized growth of the newest response
at the event batch cadence while the Session executes), `-OpenCodeFixturePaged` (only the newest 30 messages; each
`older()` prepends 30 more after 400 ms, like a cursor read) and two `-OpenCodeFixtureAutoScroll` driver modes:
`-OpenCodeFixtureScrollUp` moves 1,500 pt/s upward relative to the current offset, as a finger would,
`-OpenCodeFixtureFlings` alternates 0.9 s of that touch (a virtual finger the scroll owner treats as dragging) with
0.5 s at rest, and `-OpenCodeFixtureHold` never scrolls, so following owns every offset change. Besides frame intervals and CPU the
report counts frames over 33/50/100 ms, the unrequested on-screen movement of rows visible in consecutive frames
(`jumpMaxPoints`/`jumpTotalPoints`), frames whose small step shows none of the previous rows
(`replacedFrames`, an uncorrected prepend), the largest unrequested backward step and the final distance from the end.
`script/measure-scroll.py --app base=<A.app> --app candidate=<B.app>` alternates builds over the five scenarios
(`read`, `history-up`, `stream-reading`, `stream-follow`, `paged-up`) on a simulator or, with
`--device iphone14` and a lease acquired from the same worktree, on the iPhone 14. Build Debug with
`SWIFT_OPTIMIZATION_LEVEL=-O` for representative numbers.

### Following a changing tail

`ConversationScrollState` is the sole owner of tail and reading corrections. It coalesces row/revision/viewport
notifications and requires matching native display-layout passes without restarting on each notification. It never
combines `ScrollViewReader.scrollTo` with a tail offset. User scrolling, selection, reading restoration and navigation
cancel following. An explicit request waits for existing tracking/deceleration, never fighting it. **Ir para o fim**
requests one animation, then follows later growth without replaying it.
Prompt expansion is manual and independent of native pinning; following never prepares or changes prompt height.
Initial tail restoration remains active until the real final native cell is materialized and pinned; automatic
history prepend is disabled while following, so a transient zero offset cannot page backwards during entry.
Parsed blocks survive transient row disappearance; the shared bounded Markdown cache and size-only viewport
observation remain unchanged. Returning from a child reuses a materialized reading anchor instead of first scrolling
that message back to its top (pinned-header targets still materialize their original message).

### Transcript update and history paging cost

Streamed deltas republish the whole message list; rows must not re-render because of it. Conversation environment
contexts and transcript rows compare by rendered data (their handlers capture the view's state storage), rows
never read `store.messages`, and day chips/usage footers come from one `TranscriptMarks` pass. Each response
`UITextView` sits in a neutral `ResponseTextContainer`: SwiftUI stacks query hosted views for text baselines on
every layout pass, and a text view answers each query with a fresh TextKit layout. Pinned prompts style their
native header once per container/color and follow offsets synchronously; they read the 40% cap from
`ConversationViewport`, so keyboard transitions do not re-render the transcript. While a finger or fling owns the
transcript, deltas publish every 120 ms instead of 32 ms. The follow owner measures once per display tick; its
plan still requires two consecutive matching layouts.

An older page fetched during a touch or fling is held until scrolling settles. It is then admitted with its
anchor captured at that moment and corrected in the same transaction (forcing the hosting layout, and revealing
the anchor by identity if a tall page pushed it out of the materialized rows); later passes in which List
re-estimates the inserted rows are corrected in the frame they occur. Fetching earlier than 40 pt from the top
was measured and rejected: pages then land mid-history, where those re-estimations show.

`measure-scroll.py` on the iPhone 14, 24 October (Debug `-O`, medians of three alternating 12-second runs;
frames of 720 / p95 / main-thread CPU):

| Scenario | Before | After |
| --- | ---: | ---: |
| `stream-follow` | 95 / 146.6 ms / 12.1 s | 720 / 16.7 ms / 6.4 s |
| `stream-reading` | 330 / 54.9 ms / 11.7 s | 690 / 16.7 ms / 5.0 s |
| `read` | 679 / 16.7 ms / 4.8 s | 678 / 16.7 ms / 4.4 s |
| `history-up` (frames over 50 ms) | 668 (11) | 668 (10) |
| `paged-up` (replaced frames, over 100 ms) | 577 (1, 10) | 652 (0, 5) |

Materializing rows never shown before is unchanged: a message is one List cell holding a `UITextView` per
Markdown block, and creating, styling and sizing those views still produces 100–190 ms frames.

User-prompt parity has its own **OpenCode Bolha** simulator (`49BFE0E0-8D48-406C-A5D1-491DE91CA392`) and
`ios-bolha-derived`. After `build-for-testing` for that destination, run `script/test-user-bubble.py` with Python:
`--prepare` imports eight owned synthetic histories (two with an image, four with quotes), `--label <run>` exercises `UserBubbleTests`, and `--cleanup`
removes only those imports. No model call or seed reset is needed. The runner always supplies explicit sandbox-4177
arguments/password and removes its private xctestrun file. Both themes cover manual expansion invariant under scrolling,
the persisted Você option, short-message threshold, copy/quote menu, user-message search, image thumbnails hidden
while folded and quotes folded until expanded (long, short, quote-only and six quotes without text). `UserPromptTests` checks
native line measurement, width changes and search reveal after viewport shrink. Research/source references are in
`.agent-artifacts/bolha-usuario/OPENCHAMBER.md`; results and evidence paths are in `RESULTADO.md` beside it.

Follow verification uses **OpenCode Follow** (`8291AAB6-DF26-4128-BE44-A459BAD14186`) and `ios-follow-derived`.
After `build-for-testing` with that destination/DerivedData, run
`python3 packages/ios-custom/script/test-follow.py --label follow`.
The DEBUG-only `-OpenCodeFixtureFollow` control uses a four-message measured slice, grows three real Markdown rows in
sequence, then continues growing the last row (24 updates per run). XCTest records native offsets at display cadence
in both themes, requiring no backward step above 2 pt and a final gap
within 2 pt. Pure `ConversationScrollPlan` tests cover coalescing, layout changes, exclusive reading ownership and
cancellation; the UIKit-hosted check proves an explicit end request waits for existing deceleration and cannot run
after navigation hides the reader. Empty-tail restoration and offline jump-to-latest navigation are also checked without
resetting any viewed watermark. `--live` explicitly enables tiny read-only follow-ups in the two owned sandbox replay
children; it never answers seeded requests. The runner supplies sandbox credentials even for the disconnected fixture client,
records video/follow logs in `$TMPDIR/opencode/ios-follow-prints/`, and removes private xctestrun credentials.
`--regressions` supplies disposable action/missing-directory imports for the existing `SessionReadingTests`.
`profile-scrolling.py` accepts `--simulator`, `--derived` and `--evidence` to keep performance verification isolated.

Device verification against shipped `63d8650d44` used the same offline JSON and DEBUG growth harness in a temporary
local clone (no scrolling/rendering production code ported). On iPhone 14, five-iteration long-scroll XCTest results
were **59.20 → 58.89 fps**, **1.31 → 0 ms/s hitches**, **4.62 → 4.58 s CPU**; three fresh-process driver runs had
median p95 **16.682 → 16.680 ms**. For 60 edits at 100-ms cadence, median growth results were **49.60 → 49.50 fps**,
**41.86 → 43.01 ms p95**, **3.74 → 3.70 s CPU**, with backward movement **35.33 → 0 pt**. An Animation Hitches
capture bounded by the complete `FixtureGrowth` signpost measured **79.13 → 40.90 ms/s**. The simulator p95 increase
did not reproduce as a perceptible device regression; the coalesced follow owner is retained.
`script/compare-scroll-device.py --label <name>` records the comparison after a leased device build; `--growth-trace-only`
adds an 8-second lead-in and Points of Interest instrumentation so the complete growth interval is captured.
The final menu build was rechecked at **59.20 fps**, **0 ms/s**, **4.56 s CPU**, **16.686 ms p95** for the long scroll;
growth medians were **49.93 fps**, **42.53 ms p95**, **3.68 s CPU**, still **0 pt backward**. Matched all-processes
captures, filtered by app PID and the complete growth signpost, measured **131.57 → 66.98 ms/s**. Instrumented and
uninstrumented frame runs are separate series. `--no-trace` avoids Instruments discovery for frame-only rechecks;
`--trace-all-processes` works around CoreDevice's stale per-process discovery while exported hitches remain PID-filtered.

### Menu interaction during updates

`ConversationOptionsMenu` keeps one native UIButton/UIMenu and refreshes it only when command availability, Session
identity or theme changes; handlers read the latest callbacks. Rebuilding SwiftUI menu content with unrelated header
updates restarted native menu animations indefinitely in the 4-Hz offline stress fixture. The stable owner removes
those quiescence stalls without sleeps, delayed actions or tap retries. Root/child archive availability is preserved.
`ConversationMenuTests` exercises first-tap Details presentation during header-only and transcript updates; the UIKit
test also asserts stable menu identity and fresh callbacks. Repeat the original real-sandbox check with
`test-scrolling.py --sandbox --iterations 10 --label <unique> OpenCodeUITests/SessionReadingTests/testDetailsRootAndChild`,
once per `OPENCODE_TEST_THEME=openchamber-dark` / `openchamber-light`. Logs and snapshots record the actual first tap.

Use **OpenCode Fluidez** (`C960B2FA-F2AB-4E39-BF82-50050DF20A27`) and DerivedData
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-fluidez-derived`:

```sh
xcodebuild build-for-testing -project packages/ios-custom/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,id=C960B2FA-F2AB-4E39-BF82-50050DF20A27' \
  -derivedDataPath /private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-fluidez-derived
python3 packages/ios-custom/script/test-scrolling.py --label current
python3 packages/ios-custom/script/profile-scrolling.py --label current-conversation --template 'Time Profiler'
```

XCTest measures real swipes/deceleration (five iterations), CPU and, on physical iOS, Apple's hitch-time ratio.
`--device iphone14` requires a separately acquired `aparelhos-fisicos` lease and a device `build-for-testing`;
all device execution goes through `device-lease exec`. Simulator SwiftUI/Animation Hitches templates are unsupported
by this Xcode runtime; Time Profiler/Hangs work there, and both additional templates work on the iPhone 14.
The optional `-OpenCodeFixtureAutoScroll` driver records frame intervals and main-thread CPU over 12 seconds;
its `stallRatio60Hz` is a display-link diagnostic, **not** Apple's hitch metric. Traces, screenshots, exported XCTest
metrics and per-run HEAD/source-hash manifests go to the temporary `ios-fluidez-prints/` directory above.
Use `profile-scrolling.py --frames` for the same driver without Instruments, or `--mode sessions --updates --frames`.
`compare-scroll-device.py --frames-only --no-trace --derived … --evidence … --server-url …` measures the same
server-free device drivers without XCTest's automatic video; acquire/release the iPhone lease separately.

October 22, 2026 measurements (Debug, HEAD `e6988007d3`, concurrent working-tree snapshots recorded in the manifests):

| Conversation, iPhone 14 | Before | After |
| --- | ---: | ---: |
| XCTest frame rate | 27.36 fps | 58.87 fps |
| XCTest hitch-time ratio | 452.08 ms/s | 0 ms/s |
| XCTest process CPU / four-swipe batch | 11.88 s | 4.59 s |
| 12-second driver: main-thread CPU | 12.15 s | 5.00 s |
| Driver p50 / p95 frame interval | 137.61 / 382.33 ms | 16.69 / 16.69 ms |

Simulator driver stages: baseline p95 **453 ms**, per-text-view measurement cache **398 ms**, isolated viewport
observation/size-only row geometry **60.5 ms**, bounded Markdown reuse/compact-header measurement **37.7 ms**.
These are directional stage comparisons, not isolated A/B tests: the other agents' concurrent source changes are
recorded too. Static Sessões stays near **59.5 fps** (preview updates: **58.7 fps**); its device hitch ratio varies
between iterations, so this does not establish a fix for every live-server Sessões hitch.

## Sessão mestra

The bottom accessory is the only entry to the current master. With no master it opens an empty conversation using the
existing composer, keyboard focused, hidden **Mestra** agent and **Sol 6.1 ultrafast / medium** preselected. Nothing is
allocated until the first send. The plugin's preferred model wins over personal new-session defaults; when unavailable,
the server's default model is used. The existing model/effort picker remains available; the agent stays Mestra.

The master header uses the accessory's icon inside its context ring, with model/status below the title. Ordinary managed
chats use their conversation title for the avatar initials and the same model/status subtitle, never the allocation folder.
Their Contexto/Detalhes sheets and missing-directory notice also hide the managed path; non-repository alert avatars use
the conversation title too. Repository branch/directory presentation is unchanged.

The plugin owns the short invisible agent instructions (including prompt-injection precautions and on-demand `opencode`
skill guidance), typed control tools and their agent-only execution guard. It controls only other nonarchived root
sessions, never itself or children. It executes Alexandre's explicit requests directly, without extra confirmations.
Messages sent/created through the tools carry `custom.master: {sessionID}` metadata; target user bubbles show a small
**Sessão mestra** marker. No web rendering changes are required.

The Session lives in a managed `custom.chats` directory, not a repository. `custom.preferences.data.masterSessions.local`
stores its ID in that backend's profile (separate backend persistence = separate server pointer). Old profiles decode
unchanged. The current master is excluded from the Sessões projection and its **Precisa de você** counts, including any
requests of its own; pending master requests remain actionable inside the master conversation. Its own events do not
create global alert shortcuts, keeping entry through the accessory.

The top-right trash immediately archives the current master, clears the pointer, and opens the empty composer. Its old
transcript remains readable in **Arquivadas**. **Undo/unarchive is not implemented:** the backend has no native unarchive
operation, so the optional toast action was intentionally omitted rather than simulating recovery or editing storage.
Voice, autonomous notifications, opening summaries and subagent management are not included.

This needs Alexandre to run **`custom:update`** before using the installed backend; release `1de0005…` has no master
capability. The app probes `custom.master/info` independently of normal session loading. A missing RPC shows
**Atualize o servidor para usar a Sessão mestra** in the accessory and its screen; network/auth failures are not mislabeled
as old-server support. Other sessions and settings continue working.

Verification is isolated to **OpenCode Mestra** (`EC672074-0EF6-47AB-9299-8AF7FE2658C1`), iOS 27, port **4179**, and
`$TMPDIR/opencode/ios-mestra-derived`. After `build-for-testing`, run `python3 packages/ios-custom/script/test-master.py`
and repeat with `OPENCODE_TEST_THEME=openchamber-light`. Every launch explicitly supplies the sandbox URL/password;
private xctestrun credentials are removed afterwards. The old-server UI scenario is a DEBUG-only, 127.0.0.1:4179-gated
missing-RPC injection; unit transport tests also cover the actual HTTP/RPC error shapes. Live tool verification uses
`bun packages/plugin-app-custom/script/verify-master.ts` with fake repositories beneath that sandbox's home and Luna/low
controlled targets. Evidence and the bounded conversation transcript are in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-mestra-prints/`.

Verification: **205 Swift tests**, warning-free simulator build, three new master UI cases and all 18 app-hosted tests
in both themes. `test-master.py --regressions` also passes the four existing `SessionReadingTests` in both themes using
disposable imports under the owned fake repository; it supplies `OPENCODE_TEST_SERVER_URL=…:4179` and deletes only those
imports afterwards. The action fixture has a short title because the existing rename test taps the field's middle before
Backspace. The sandbox currently lacks Sol ultrafast, so the live/UI runs verified the honest server-default Astra
fallback; plugin tests cover preferred Sol/medium registration. Every requested tool completed in the live transcript.

Review-1 verification: `test-master.py --review-1` adds an ordinary managed-chat header/context/details check and saves
captures into `ios-mestra-prints/review-1/`. All four master/chat UI cases and the current 26 app-hosted tests pass in both
themes; simulator build and root `bun run check` pass. The runner deletes only its own ordinary-chat import/allocation.

## Dados do iPhone

The `iphone_status` and `iphone_query` tools, available to every agent, read this iPhone on demand through
`custom.device` (contract: [`plugin-app-custom/docs/device.md`](../plugin-app-custom/docs/device.md)). `DeviceAgent` keeps a presence
lease while the `EventHub` is connected (renewed every 30 s), detaches when the stream stops for good, and answers
`rpc.custom.device.request` events, which never reach screen subscribers, through the request's Location. It
therefore answers with the app open or during a voice call, also with the screen locked; otherwise the tool reports
`offline` immediately.

**Você → Dados do iPhone** has one switch per source (Aparelho and Rede on by default; the others ask for their iOS
permission when turned on), each permission state and the last answered query. Sources: `device` (UIKit/
ProcessInfo), `network` (`NWPathMonitor`, no SSID), `location` ("While Using", fresh fix plus `MKReverseGeocodingRequest`
address in the foreground, last known position in the background), `health` (read-only HealthKit:
`HKStatisticsCollectionQueryDescriptor` daily aggregates, sleep and workout samples, up to 90 days), `motion`
(`CMPedometer` per day and `CMMotionActivityManager` minutes, last 7 days) and `photos` (PhotoKit metadata and
384-pixel JPEG thumbnails returned as tool images). While the iPhone is locked HealthKit is unreadable; a 90-day daily
summary protected until first unlock (`Application Support/OpenCode/DeviceData`) answers instead. In the
conversation the tool reads **Consultou o iPhone · Saúde** with the `iphone` symbol; voice, which follows only the
Sessão mestra, narrates **A mestra está consultando seu iPhone.** The footer and the iOS permission prompts say that
the OpenCode agents read this data when Alexandre asks.

Requirements: `OpenCode/OpenCode.entitlements` (HealthKit, no clinical records), the usage descriptions
`NSHealthShareUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription` and
`NSPhotoLibraryUsageDescription`, and an explicit-App-ID profile: automatic signing (`-allowProvisioningUpdates`)
enables HealthKit on `br.com.alexandrem.opencode`; the team wildcard profile cannot sign the app anymore.

Verification: `swift test --filter DeviceDataTests` (contract, dispatch, ranges, sleep/motion aggregation, cache
filter, conversation labels), and against an isolated sandbox with location granted and set on the simulator
(`simctl privacy <udid> grant location br.com.alexandrem.opencode`, and `simctl location <udid> set …` right before each
run: a simulated position set long before may yield no fix within the 3-second limit):
`test-isolated.py … OpenCodeUITests/DeviceDataTests` in both themes. The second case sends one real Mestra prompt and
checks that `iphone_query` for `device`, `network` and `location` completed with `status: "ok"`. HealthKit, CoreMotion
and Photos need the physical iPhone 14: a DEBUG launch with `-OpenCodeDeviceProbe` enables every source (answer the
iOS prompts), collects each once plus the locked-cache answer, and writes `Documents/device-probe.json`.

## Platform and distribution

- **Only the latest iOS.** The deployment target is always the current major version (iOS 27 today) and moves up with
  each new major release. There is no support for older versions: use the newest APIs directly, without
  `#available` branches or fallbacks.
- **Private TestFlight only.** Builds go to an internal testing group in App Store Connect with automatic
  distribution, so every processed build reaches the iPhone without Beta App Review. App Store requirements (review
  guidelines, public privacy disclosures, screenshots) do not apply.
- **Signing:** Alexandre's personal Apple Developer team (`ERRYZ68LX5`), with automatic signing. The app carries
  the HealthKit entitlement (`OpenCode/OpenCode.entitlements`), so device builds need `-allowProvisioningUpdates` with
  the App Store Connect API key (Xcode has no signed-in account) to obtain the explicit App ID profile.
- **Identifiers:** bundle ID `br.com.alexandrem.opencode`, following the `alexandrem.com.br` domain already used by
  the Cloudflare One hostnames. Extensions use `br.com.alexandrem.opencode.<extension>`, and data shared between the
  app and its extensions uses the App Group `group.br.com.alexandrem.opencode`.
- **Upload:** a local script in this package, with no CI and nothing outside the Mac:
  1. `xcodebuild archive` for `generic/platform=iOS`;
  2. `xcodebuild -exportArchive` with an `ExportOptions.plist` containing `method = app-store-connect` and
      `destination = upload`, plus `-allowProvisioningUpdates`. Use the existing Xcode account, or an App Store
      Connect API key passed through `-authenticationKeyPath`, `-authenticationKeyID`, and
      `-authenticationKeyIssuerID`. The key stays outside the repository, in `~/.appstoreconnect/private_keys/`.
      `testFlightInternalTestingOnly = YES` prevents external TestFlight and App Store distribution.
- **Versions:** the build number (`CURRENT_PROJECT_VERSION`) is the UTC timestamp of the upload, so it always
  increases, and Info.plist carries the short commit SHA to identify the build. `ITSAppUsesNonExemptEncryption = NO`
  skips the export-compliance question on every build, since the app uses only the system's encryption.
- Because nothing goes through review, prefer the simplest correct configuration over App Store conventions, while
  keeping the security that matters: credentials in the Keychain and transport exceptions limited to the private
  hostname.

## Network access

The iPhone reaches the Mac's OpenCode through a **Cloudflare One route that already exists**. It is managed in the
`core-infra` repository (`cloudflare-one/`, section "Conector local do Mac e OpenCode"), not in this repository:

```text
iPhone (WARP, org alexandrerm, master@alexandrem.com.br)
  → Gateway private DNS: opencode2-mac.alexandrem.com.br → 10.203.96.2
  → private route on the macbook-pro-alexandre tunnel (cloudflared on OrbStack)
  → nginx on 10.203.96.2:80
  → loopback proxy on the Mac, 127.0.0.1:4096
  → custom OpenCode server, 127.0.0.1:4178
```

- **Address:** `http://opencode2-mac.alexandrem.com.br`, on port 80. Use the full name, not `opencode2-mac`: the ATS
  exception and DNS resolution depend on it. Port 4096 still works but exists only for compatibility.
- **Access:** there is no public DNS. Gateway allows only TCP 80 and 4096 to that IP, and only for the identity
  `master@alexandrem.com.br`. The iPhone must be enrolled in WARP (org `alexandrerm`) with that identity, and its
  device profile must include `10.203.96.2/32` in Split Tunnels.
- **Authentication:** the Mac's loopback proxy injects the server credentials, so on this route Cloudflare One is the
  only access control and the app sends no password. Basic authentication and pairing are still supported for other
  servers.
- **Preferences scope:** `custom.preferences` stores the selected repositories per server. The custom web app stores
  the server that serves it under the key `"local"`, and the app uses the same key for this route, so both share
  one selection. Pinned and muted sessions are global.
- **Transport:** plain HTTP inside the WARP tunnel. HTTP handles requests, and SSE (`/api/event`) handles live
  events. This is the server's native contract, and it already sends an SSE heartbeat every 15 seconds. The nginx on
  the route has buffering disabled, a one-hour read timeout, and WebSocket upgrades enabled. A WebSocket for events
  would require a new backend endpoint and bring no gain, so WebSocket is used only where the server already offers
  it (PTY, when terminals come into scope).
- **App Transport Security:** allow plain HTTP only for `opencode2-mac.alexandrem.com.br` and the private image-storage
  host `seaweedfs-svc`, through `NSExceptionDomains` with `NSExceptionAllowsInsecureHTTPLoads`. Do not use
  `NSAllowsArbitraryLoads`. Traffic is already encrypted by the WARP tunnel; storage has its own DNS/route policy.
- **Origin:** nginx rejects requests whose `Origin` is not on its list. `URLSession` sends no `Origin`, so do not
  add one.
- **Availability:** the route depends on the Mac being on and awake and on the OrbStack containers being healthy.
  The infrastructure manifest records that the end-to-end test over WARP had not been done yet. Before relying on the
  route, open `http://opencode2-mac.alexandrem.com.br/api/info` in the iPhone's Safari with WARP on, and confirm that
  it returns JSON.
- `https://mac.alexandrem.com.br` points to the same nginx, but it is public and protected by Cloudflare Access,
  which requires a browser login. The app does not use it.
- **Without Cloudflare One:** `opencode pair` (LAN, after `opencode service set hostname 0.0.0.0`) and
  `opencode pair --remote` (tunnel) still work and are useful for development. The Local Network permission
  (`NSLocalNetworkUsageDescription`) is needed only for direct connections over Wi-Fi.

## Backend contract

### Source of truth

- HTTP API: `packages/protocol/openapi.json`, generated from the protocol `ClientApi` by `bun run generate` in
  `packages/protocol`. Do not edit it by hand.
- TypeScript clients: `packages/client`. The Swift client is written by hand (see [API layer](#api-layer)).
- Custom plugin RPCs: `packages/plugin-app-custom/src/*/rpc.ts`, all exported from `src/rpc.ts`. **Their schemas
  are not in `openapi.json`**, so the Swift side must mirror them deliberately.
- Behavior reference: `packages/app-custom`. When in doubt about a flow (pairing, reconnecting, list refresh), copy
  the custom web app's behavior, not just its endpoints.

### Authentication

- Every route under `/api` uses HTTP Basic: username `opencode`, password = the server password **or** the session
  token obtained by pairing. Send the `Authorization` header on every request to servers that require it. On the
  Cloudflare One route, the Mac's proxy injects these credentials.
- `GET /api/info` returns `version`, `urls`, and `capabilities`. Use it as the health check and to detect an
  incompatible server.

### Pairing

`opencode pair` creates a single-use code that expires after a few minutes:

- it prints links in the form `<url>/auth/connect/<code>`;
- it shows a QR code containing `{"code": "...", "urls": ["..."]}`, with only addresses reachable from other devices
  (no loopback).

To redeem it, call `GET /auth/connect/{code}` with `Accept: application/json`. The response is `{ "token": "..." }`,
and the token becomes the Basic password. Since the code works only once, try all `urls` in parallel and keep the
first address on the list whenever it answers. This is the same strategy as `redeemPairingLink` in
`packages/app-custom/src/servers/connect/pairing.ts`.

### Location

Location-scoped endpoints receive the directory as the `location[directory]=<absolute path>` query parameter or the
`x-opencode-directory` header (URL-encoded). Without either, the server uses its own working directory.

### Events

`GET /api/event` is an SSE stream with events from **all** Locations, including `server.connected` and `rpc.*` events
from plugins. The server sends a `: heartbeat` comment every 15 seconds. The stream is volatile by contract:

- a slow consumer has its stream closed;
- events missed while disconnected are not replayed.

So:

- after every (re)connection, reload the visible state before applying incremental events;
- treat about 45 seconds without any byte (three missed heartbeats) as a dead connection and reconnect;
- on iOS the connection drops whenever the app goes to the background, so treat every return to the foreground as
  a reconnection.

### Plugin RPC

```http
POST /api/rpc/{rpcID}/{method}?location[directory]=/abs/path
Content-Type: application/json

{ "input": ... }
```

The response is `{ "output": ... }`. RPC IDs follow the `custom.<area>` pattern, for example `custom.worktrees`.

### Quick check with curl

```sh
curl http://opencode2-mac.alexandrem.com.br/api/info
curl -N http://opencode2-mac.alexandrem.com.br/api/event
curl -u "opencode:$PASSWORD" http://<host>:<port>/api/info   # servers that require a password
```

## API layer

`Codable` models and client in Swift, written by hand in `OpenCodeKit`, covering only what the app uses:

- organized by the same groups as the protocol (`session`, `message`, `permission`, `form`, `event`, and so on), and
  following the schemas in `packages/schema` and `packages/protocol`;
- tagged unions as Swift `enum`s that decode the discriminant (`type`, `_tag`) and have an `unknown` case, so a newer
  server does not break decoding;
- plugin RPCs follow the same pattern, each mirroring its `rpc.ts`;
- contract tests decode JSON fixtures captured from the real server. When the custom server is updated, capture the
  fixtures again and run the tests.

The OpenAPI generator (`swift-openapi-generator`) was ruled out. The document has about 375 `anyOf` without a
discriminator, it describes the event payload only as an opaque JSON string, and it does not include the plugin RPCs.
If manual maintenance becomes costly, the next step is to emit Swift from the same Effect contract that
`packages/httpapi-codegen` already reflects, which would also cover the RPCs.

### Opening a conversation

Health, Session metadata, execution activity and the unchanged 40-message tail load concurrently. The tail is published
before directory availability, catalogs and family reads; independent catalogs also load concurrently. Viewed
acknowledgement only needs Session metadata; sending and saved-position restoration wait for the stable runtime projection. Late runtime results never
overwrite history paged in meanwhile.
This applies equally to lean and native transport: there is no missing-RPC capability memory, special fallback policy,
smaller first page or new transcript cache.

For sandbox-only timing, build for **OpenCode Abertura** (`3CD95181-75A3-4225-B919-6B1C4DCFA77E`) with DerivedData
`$TMPDIR/opencode/ios-abertura-derived`, then run `python3 packages/ios-custom/script/test-session-opening.py after`.
The runner always supplies the explicit sandbox URL/password. DEBUG-only probes time route commitment → first transcript
frame; loopback-only delay/old-server emulation compares normal RPC, 400-ms/req RPC and 400-ms/req missing-RPC fallback.
It reads existing histories without prompts, seed changes or service operations. Detailed measurements are in the contract.

### Older custom servers

The lean `custom.transcript/list` RPC is optional. Conversation tails, older pages and Sessões previews fall back to
`GET /api/session/{id}/message` on a failed RPC read, retaining the same page size, order and opaque cursor. Cancellation
never starts a fallback, and a failed native read remains an error. Newer servers still use the lean RPC, avoiding inline
tool media. This supports the installed `custom.1de0005…` release, which predates that RPC; see the
[compatibility audit](docs/conversation-contract.md#production-compatibility-audit-2026-10-22).

That release also lacks the `sidebar.mute` preference intent. Its rejection gets an explicit pt-BR server-update notice;
no local-only mute or successful mutation is fabricated. Missing `mutedSessions` still decodes normally and is not treated
as a capability flag, since it is optional even in the newer contract.

Debug simulator builds accept `-OpenCodeNativeTranscript` to skip the optional RPC and exercise the **same native
reader used by fallback**, including Sessões previews and older pages. The switch and its state are excluded from
Release compilation. Always keep the explicit sandbox URL/password when using it. After `build-for-testing`, run
`python3 packages/ios-custom/script/test-transcript-compatibility.py` to compare both paths on existing seeded tools,
reasoning, child history, image attachment, compaction, older-page search and pending permission/question cards. The runner
does not answer requests, send prompts, reset seeds or change service lifecycle; it exports dark screenshots to a unique
`$TMPDIR/opencode/ios-native-transcript-*` directory and deletes its credential-bearing xctestrun file.

## Notifications

System/push notifications are not part of the MVP. Wave 7's in-app banners need no notification permission and work
only while the app receives live events. When push arrives, it will come from the OpenCode backend, through a new area in
`packages/plugin-app-custom` that follows the same pattern as the existing areas (an `index.ts` that registers the
behavior and an `rpc.ts` with the contract):

1. **Registration:** the app requests permission, obtains the APNs device token, and sends it to the plugin over RPC,
   together with the APNs environment.
2. **Triggers:** the plugin observes events with `ctx.event.subscribe` (as `chats` already does) and decides what
   deserves a notification. Candidates: a session finished or became idle, a permission or form is waiting for an
   answer, and a run failed.
3. **Delivery:** the plugin calls APNs over HTTP/2 with token-based authentication (a `.p8` key, its Key ID, and the
   Team ID). The key stays in the server configuration and is never committed to the repository.
4. **Opening:** the payload carries the server and the Session, so tapping the notification opens the right session.

TestFlight builds use the **production** APNs environment (`api.push.apple.com`), while builds installed from Xcode
use **sandbox** (`api.sandbox.push.apple.com`). Store the environment with each token. Live Activity updates can later
reuse the same delivery channel.

## Technical direction

- Swift 6 with strict concurrency, SwiftUI, Observation (`@Observable`), and `async`/`await`.
- Networking with `URLSession`, including SSE (`bytes(for:)`), with no third-party networking dependencies.
- Package dependencies are `swift-markdown` (response parsing), SwaTexRender (math), WebRTC (voice calls), and
  FluidAudio (local transcription). Rendering stays in the app; other dependencies need an explicit decision.
- Separate the client layer (models, HTTP, SSE, pairing, credentials) from the UI so it can be tested without the
  simulator and reused by extensions (notifications, widgets, Live Activities, share sheet).
- The server is the source of truth. The app keeps only cache and local preferences, and does not duplicate rules the
  backend already enforces.

### Project structure

A standard Xcode iOS project in Swift, committed to the repository, with no generator such as XcodeGen or Tuist. The
targets use synchronized folders (Xcode 16 and later): files added to a folder enter the target without editing
`project.pbxproj`, which avoids most merge conflicts. Code with no UI lives in a local Swift package.

```text
packages/ios-custom/
  README.md
  OpenCode.xcodeproj/
  OpenCode/              # app target: entry point, navigation, feature screens
  OpenCodeKit/           # local Swift package with no UI: API, models, SSE, pairing, Keychain
  OpenCodeUITests/       # sandbox-only native interaction/continuity tests
  OpenCodeTests/         # app-hosted UIKit key-command tests
```

## Development

- Requirements: Xcode 27.1 / Swift 6.4 and a reachable OpenCode server.
- **No CI.** Build, tests, and TestFlight uploads all run locally on this Mac.
- Development backend: an isolated custom instance created by `packages/cli/script/custom-sandbox.ts` (see
  "Isolated source development" in `docs/custom-macos.md`). `bun dev serve` is not enough, because it does not load
  the custom plugin whose RPCs the app uses. Never use ports 4096 or 4178, and **never restart an existing backend or
  proxy**, especially the one serving live sessions.
- The simulator shares the Mac's network and reaches `http://localhost:<port>` directly. A physical device uses the
  Cloudflare One route (see [Network access](#network-access)), the LAN address, or the tunnel.
- Push notifications require a physical device. Builds installed from Xcode receive notifications only through the
  APNs sandbox.
- The physical test devices are shared with other agents. Reserve one through the device lease before installing or
  driving the app, and release it when you are done.
- The committed `OpenCode.xcodeproj` has one iPhone app target (`OpenCode`), automatic signing for team
  `ERRYZ68LX5`, and a local `OpenCodeKit` package. The app uses synchronized folders; adding a Swift file does not
  require editing the project. [Private TestFlight uploads](#private-testflight-uploads) use the local script below.

### Parallel verification without shared-device races

Build once for an iOS 27 simulator with `build-for-testing`, `COPY_PHASE_STRIP=NO` and isolated DerivedData. Reuse its
`OpenCode_*.xctestrun` products on **three different simulators** (for example OpenCode Correcoes 1/2/3). Each worker
must have its own result bundle and credential-bearing configuration; never launch two runners on one simulator.
Keep Xcode's internal parallel testing **off** when assigning explicit workers. Alternatively, for fully independent
fixtures only, use `-parallel-testing-enabled YES -parallel-testing-worker-count 3` and let Xcode create clones.

Partition by mutable state, not just by test class:

1. **Shared sandbox worker:** serially run seeded reading, manual servers/pairing, new-session selectors/sends,
   Safari MCP toggles, agent selection, comments and alert/preferences scenarios. Keep tests sharing a fake repository,
   MCP intent or backend preferences in this worker. Use only `llm-proxy/gpt-6-luna` / `low` for live inference.
2. **Offline/hosted worker:** UIKit tests, composer/MCP fixtures, menus and follow fixtures; these never mutate the
   shared sandbox. Run the fixed MCP keyboard check in both themes.
3. **Owned-repository worker:** deletion/revert histories in separate fake repositories, then the master scenario on
   a separately owned sandbox. Do not overlap its pin/mute preference mutations with worker 1's preference mutations.
   A master test accepts `OPENCODE_TEST_SERVER_URL`; `OPENCODE_TEST_CHEAP_INFERENCE=1` explicitly selects Luna/low before send.
   First mark Luna visible in that sandbox's model preferences (`model.visibility`, `visibility: "show"`): a fresh
   profile intentionally lists no models until the user chooses which ones to show.

The settings runner accepts `OPENCODE_TEST_DEVICE`, `OPENCODE_TEST_DERIVED` and `OPENCODE_TEST_EVIDENCE`; the grouping
runner also accepts `OPENCODE_TEST_DESTINATION` / `OPENCODE_GROUP_EVIDENCE`, and the MCP runner accepts the same device,
DerivedData and evidence overrides. Other live runners still declare their fixture destinations: inspect/configure
them before running, rather than accidentally using a worker's simulator concurrently.

For already prepared tests, `script/test-isolated.py` supplies private launch arguments/password, serializes each
explicit device and records wall-clock timing plus attachments. For example, launch these **in separate terminals**:

```sh
python3 packages/ios-custom/script/test-isolated.py --device "$SIM2" --derived "$DERIVED" \
  --evidence "$EVIDENCE/worker2" --label hosted --dictation-fixture OpenCodeTests
python3 packages/ios-custom/script/test-isolated.py --device "$SIM3" --derived "$DERIVED" \
  --evidence "$EVIDENCE/worker3" --label composer OpenCodeUITests/ComposerEditingUITests
```

Include `OpenCodeUITests/DictationUITests` in an independent offline worker in each theme. Its own launches and
`--dictation-fixture` use the DEBUG fake engine/PCM, never the device mode or a real-model download.

An extra **physical iPhone 14** worker is restricted to server-free DEBUG fixtures. Reserve it through `device-lease`
before the signed device `build-for-testing` (`DEVELOPMENT_TEAM=ERRYZ68LX5`, explicit UDID, separate device DerivedData).
Then run:

```sh
python3 packages/ios-custom/script/test-isolated.py --physical --device 00008110-00065DA13A78401E \
  --derived "$DEVICE_DERIVED" --evidence "$EVIDENCE/iphone14" --label offline \
  OpenCodeUITests/MarkdownRenderingTests OpenCodeUITests/ScrollComparisonTests
```

The physical runner acquires a process lease, routes Xcode through `device-lease exec`, and releases in `finally`.
Its allowlist rejects live cases; even the hosted launch has explicit loopback sandbox arguments and an offline
fixture transport that rejects HTTP. Do not replace loopback with production/LAN to make live tests reach the phone.
No real voice or proxy-admin/reset actions belong in this run. Delete only owned Sessions/checkouts, verify the fake
repositories' worktree registrations and `~/Worktrees` inventory, stop only an owned sandbox, and shut down every
simulator booted for the run. Report total elapsed time and each worker's cases/results, including skips and reasons.
Before physical gesture checks, move any overlapping floating system control out of the test area and restore its
position afterwards; AssistiveTouch can intercept a valid app button while remaining absent from the app's AX tree.
Reading checks measure `conversation-pinned-user`, not a fixed header height, and drag in the transcript gutter outside
the edge-pop zone, holding briefly at the end to avoid deceleration overshooting a narrow viewport. Keyboard checks
resolve a visible keyboard afresh and wait for stable keyboard/composer geometry; MCP focus checks arrange the draft
before mounting and tap actual software keys instead of invoking XCTest's temporary hardware-keyboard injection.
Settings actions are found by identifier regardless of native List cell/button exposure; readiness waits use the
navigation screen, not an unmounted row.
Use separate `OPENCODE_TEST_THEME` invocations for the long live `NewMessagesTests` history. Each themed invocation
keeps the 300-second limit; the legacy combined two-theme run has a 600-second allowance for rendering and paging.

### Private TestFlight uploads

#### One-time setup

1. **Signing identity:** use the Apple ID already signed into Xcode for team `ERRYZ68LX5`. If its session has expired,
   Alexandre must renew it manually in **Xcode → Settings → Accounts**. The script never asks for an Apple ID
   password or a two-factor code. Automatic signing (`-allowProvisioningUpdates`) can register the bundle ID and
   create the necessary certificates and profiles; no physical device is needed.
2. **Optional API key instead of the Xcode account:** in App Store Connect **Users and Access → Integrations →
   App Store Connect API**, create a team key named `opencode-ios-testflight` with the **App Manager** role (not Admin),
   and download its `.p8` once. Put it at
   `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, outside the repository, with mode `600`. Keep the Key ID and
   Issuer ID private too. Export `ASC_KEY_ID` and `ASC_ISSUER_ID` in the shell, with optional `ASC_KEY_PATH` for a
   nonstandard absolute key path, or create this private file with mode `600`:

   ```text
   # ~/.appstoreconnect/opencode.env — literal, unquoted KEY=value entries; no shell expansion
   ASC_KEY_ID=YOUR_KEY_ID
   ASC_ISSUER_ID=YOUR_ISSUER_UUID
   ```

   Use mode `700` for `~/.appstoreconnect/private_keys/` and `600` for both the key and config. If API access must be
   requested or terms accepted, leave that to Alexandre. Environment values take precedence. `ASC_CONFIG_FILE` can
   select another config **outside the repository**.
   `--auth auto` (the default) uses a configured key, otherwise the Xcode account. A partially configured or unreadable
   key is an error, not a silent fallback. `--auth api-key` requires the key; `--auth xcode` explicitly ignores it.
3. **App record:** in App Store Connect **Apps → + → New App**, create an iOS app named `OpenCode Agente` (or
   `OpenCode Agente AR` if taken), primary language **Portuguese (Brazil)**, bundle ID and SKU both
   `br.com.alexandrem.opencode`, with access limited to Alexandre. If the bundle ID is not listed, first register it
   in the Developer portal or run a signed `--dry-run` so automatic signing registers it, then create the record.
   The device display name remains `OpenCode`. Do not submit an App Store version.
4. **Internal distribution:** in the app's **TestFlight → Internal Testing**, create a private group for Alexandre,
   enable **automatic distribution**, and add only his App Store Connect user as a tester. Builds are internal-only;
   no external group or Beta App Review is involved. Apple's processing, binary validation, encryption questions and
   current developer agreements still apply. Stop for Alexandre if any login, 2FA or agreement acceptance is required.
5. The future App Group is `group.br.com.alexandrem.opencode`; it is reserved in the design, not enabled as an
   entitlement until an extension actually needs it.

#### Commands (from the repository root)

```sh
# No credentials: validate the Release device archive and its resources; never uploads.
packages/ios-custom/script/testflight.sh --unsigned-check

# With the Xcode account or API key: signed archive and local IPA, never uploads.
packages/ios-custom/script/testflight.sh --dry-run

# Archive and upload to INTERNAL TestFlight only.
packages/ios-custom/script/testflight.sh

# Explicit authentication choices, if needed:
packages/ios-custom/script/testflight.sh --auth xcode
packages/ios-custom/script/testflight.sh --auth api-key
```

The script refuses uncommitted changes in `packages/ios-custom`, including untracked files and changes introduced
by asset regeneration. Commit before distributing; use `--allow-dirty` deliberately for a local rehearsal. It prints
the short commit and builds the current working tree (with `--allow-dirty`, the SHA identifies its base only).
It regenerates themes and the icon, archives for `generic/platform=iOS` in Release, then exports with
`method = app-store-connect`, automatic signing, symbol upload, and `manageAppVersionAndBuildNumber = NO`.

`MARKETING_VERSION` is `0.1.0`; each invocation sets `CURRENT_PROJECT_VERSION` to UTC `yyyyMMddHHmm` and injects the
short Git SHA into `OpenCodeCommit`. Ordinary Xcode builds use build `1` and an empty commit key. Wait until the next
UTC minute before re-uploading the same marketing version: two uploads within one minute have the same build number.
The script does not query App Store Connect or silently renumber a build.

Each run gets a unique directory under
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-archives/`, containing `OpenCode.xcarchive`,
private local logs, and, for signed runs, `ExportOptions.plist` and `export/`. DerivedData is shared at
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-sessoes-derived`; do not run two Xcode builds
against it simultaneously. Auth arguments and Xcode logs are not echoed, even on failure; redact credential
identifiers before sharing the logs. A successful upload still needs TestFlight processing; check App Store Connect.

#### Icon and launch assets

The original agent/AI icon source is committed at `script/icon-source.png`. Regenerate its 1024×1024 opaque PNG and
the themed `LaunchBackground` color set with:

```sh
swift packages/ios-custom/script/generate-icon.swift
sips -g pixelWidth -g pixelHeight -g hasAlpha packages/ios-custom/OpenCode/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

The script resizes the source, flattens any transparency onto the generated OpenChamber dark background, and writes
only changed assets. No dependencies, fonts, pre-rounded corners or drawn shadows are used. Only the default icon is
supplied; iOS handles its Home Screen appearance. Theme regeneration runs first during distribution. The chosen
generation prompt is also recorded in `script/icon-source.prompt.txt`; local concepts and small-size previews live in
`.agent-artifacts/testflight/icone/` (not versioned).

#### Troubleshooting

- **Signing/authentication:** inspect the private `Archive.log` or `Export.log`. Renew an expired Xcode session
  manually, or configure a valid team API key with access to Certificates, Identifiers & Profiles. Do not put any
  password, key or profile in this repository. Missing app records must be created with the exact bundle ID above.
- **Missing icon / ITMS-90704:** regenerate the icon, confirm `hasAlpha: no`, and verify that the archive app's
  Info.plist has `CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconName = AppIcon`. The target build setting must
  remain `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Commit the generated PNG and catalog JSON.
- **Private API / ITMS-90338:** `OpenCode/SoftwareKeyboardShift.swift` intentionally discovers `UIKeyboardImpl` and
  its `activeInstance`, `isShifted`, `isAutoShifted`, and `isShiftLocked` getters at runtime. The Release binary can
  expose these strings even without a linked private class symbol. Internal TestFlight does not bypass this scan.
  If processing rejects it, delete that file **and replace the body of `ComposerInputView.submitSoftwareReturn()`
  in `OpenCode/ComposerTextView.swift` with `return false`**. Leave the `UIKeyCommand`/`submitReturn(_:)` hardware
  Shift+Return implementation untouched: it still sends, while software Return inserts a newline (the send button
  still works). Rebuild and upload with a new build number; do not merely rename or obscure the selectors.
  With Xcode 27.1's current optimized Release build, `strings -a` finds none of those complete literals, and `nm -u`
  has no `UIKeyboardImpl` class import (it does import `NSClassFromString` and `NSSelectorFromString`). The dSYM still
  identifies `SoftwareKeyboardShift.state()`, and disassembly shows the names constructed as inline Swift small
  strings via ARM64 `mov`/`movk` immediates. This is compiler behavior, not an intentional hiding technique and not
  evidence that Apple's processing will accept it; the private API risk remains.
- **Export compliance:** `ITSAppUsesNonExemptEncryption = NO` is already embedded because the app uses only system
  encryption. If processing still shows **Missing Compliance**, inspect the uploaded build's plist and answer the
  encryption section consistently in App Store Connect; revisit the declaration if encryption behavior changes.
- **Duplicate build:** wait for the next UTC minute and run again. **Processing** is not an upload failure; wait for
  Apple's result before retrying or distributing. Do not submit to the App Store or create an external testing group.

Release keeps the explicit server/theme/session launch overrides for sandbox verification; without supplied
arguments or environment values the server restores the saved active entry, falling back to the single
`ServerConfiguration.defaultURL` constant, and no session
is opened automatically.
The scheme's sandbox arguments belong only to `TestAction`; neither they nor the UI-test targets enter an archive.
The private-host ATS exception is unchanged and does not allow arbitrary HTTP hosts.

### Generate themes, build, and test

Run from the repository root:

```sh
bun packages/ios-custom/script/generate-themes.ts
swift packages/ios-custom/script/generate-icon.swift
xcodebuild -list -project packages/ios-custom/OpenCode.xcodeproj
xcodebuild -project packages/ios-custom/OpenCode.xcodeproj -scheme OpenCode \
  -destination 'platform=iOS Simulator,name=OpenCode Sessoes' \
  -derivedDataPath /private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-sessoes-derived build
```

Run the Swift Testing suite from the package directory (no simulator required):

```sh
cd packages/ios-custom/OpenCodeKit
swift test
```

The theme script imports both custom web resolvers and generates all bundled light/dark variants under
`OpenCode/Resources/Themes`. Each file records its role-to-source-token mapping. Primary/status/accent colors use
the theme's semantic palette seeds through resolver overrides; surfaces, text, borders, icons, and filled buttons
use the resolved web tokens. Avatar hues come from the web's avatar tokens, with equal OKLCH lightness/chroma within
each mode so one repository never appears faded compared with another. There are no hard-coded colors in views.

### Dedicated simulator and isolated server

Create the simulator **once**; reuse it on subsequent runs. Do not use a physical device or an existing project's
simulator for this workflow.

```sh
xcrun simctl create "OpenCode Sessoes" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

Look up the dedicated simulator by name. Boot it if it is not already running, then install and launch:

```sh
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for group in json.load(sys.stdin)["devices"].values() for d in group if d["name"] == "OpenCode Sessoes"))')
DERIVED=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-sessoes-derived
SANDBOX=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/custom-sandbox-4177
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$DERIVED/Build/Products/Debug-iphonesimulator/OpenCode.app"
SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD="$(cat "$SANDBOX/password")" \
  xcrun simctl launch "$DEVICE" br.com.alexandrem.opencode \
  -OpenCodeServerURL http://127.0.0.1:4177 -OpenCodeTheme openchamber-dark
```

To change themes, terminate **only this simulator app**, then repeat the launch with `openchamber-light`:

```sh
xcrun simctl terminate "$DEVICE" br.com.alexandrem.opencode
SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD="$(cat "$SANDBOX/password")" \
  xcrun simctl launch "$DEVICE" br.com.alexandrem.opencode \
  -OpenCodeServerURL http://127.0.0.1:4177 -OpenCodeTheme openchamber-light
xcrun simctl io "$DEVICE" screenshot /path/to/light.png
```

`-OpenCodeServerPassword <password>` is also accepted, as are the `OpenCodeServerURL` / `OpenCodeServerPassword`
environment variables (uppercase `OPENCODE_SERVER_URL` / `OPENCODE_SERVER_PASSWORD` aliases are supported).
The default URL remains `http://opencode2-mac.alexandrem.com.br`. The launch theme wins over the local
saved family/appearance preferences; absent both, OpenChamber follows the system appearance. Loopback HTTP was verified in the iOS 27
simulator without an ATS exception; only the private Cloudflare hostname has an exception.

### Conversation reader verification

Append `-OpenCodeOpenSession <sessionID>` to the simulator launch to open a conversation directly. It is applied once
per app launch; Back returns to Sessões normally. Resolve current IDs from the seed manifest, not this README:

```sh
SESSION=$(jq -r '.sessions[] | select(.role == "working") | .id' "$SANDBOX/seed-conversation.json")
PRINTS=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda1
mkdir -p "$PRINTS"
xcrun simctl status_bar "$DEVICE" override --time '10:58' --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
xcrun simctl terminate "$DEVICE" br.com.alexandrem.opencode
SIMCTL_CHILD_OPENCODE_SERVER_PASSWORD="$(cat "$SANDBOX/password")" \
  xcrun simctl launch "$DEVICE" br.com.alexandrem.opencode \
  -OpenCodeServerURL http://127.0.0.1:4177 -OpenCodeTheme openchamber-dark \
  -OpenCodeOpenSession "$SESSION"
# Wait for the transcript, then scroll or expand the desired tool before capturing.
xcrun simctl io "$DEVICE" screenshot "$PRINTS/a-dark.png"
```

Repeat with `openchamber-light`; manifest roles `permission`, `history`, and `child-0` cover the other screens. For
history, capture the initial quote, scroll up to the image/unread boundary, expand the tools and the diff/error,
then scroll to the beginning to exercise all three pages. An already-viewed session correctly has no new-message
divider on the next launch; do not move its watermark backwards or consume the pending permission/question to
recreate a screenshot. The app acknowledges only observed idle watermarks, not wall-clock time.

Waves 1–7 are complete. Wave 6's physical-keyboard path still has the manual device check described below;
its command registration, dispatch and blocked states are covered by app-hosted tests.
Child sessions have the normal composer, with their own agent shown read-only, and a return-to-parent action.
Their permission/question cards remain actionable and their capsule counts the parent's other work. Colors follow the
generated web tokens, including the actual catalog's agent colors; the sandbox model is Luna 6 / low, not the
mockup's illustrative Opus model.

`ConversationStore` reads only `custom.transcript/list`, first 40 and then older 40-message pages. A recycling plain
`List` keeps native text views only for its current rows; off-screen rows release parsed Markdown and thumbnails,
retaining cheap wire values and measured heights. It preserves loaded history during tail merges, and re-reads
loaded coverage after an external revert. Paging automatically starts near the top, preserves an existing row's
screen coordinate while the new Markdown blocks are measured, and removes its small indicator after an empty page.
`EventHub` owns the one SSE connection shared
with Sessões. Screens receive decoded events with local sequence numbers: text/reasoning/tool changes batch at
32 ms; structural/terminal events and missing targets revalidate in 500 ms windows. A snapshot invalidates buffered
deltas that may already be included in it, preventing duplicate text during reconnect. Foreground returns reload.

Response text is parsed off the main actor by swift-markdown 0.7.3 into blocks and displayed by non-editable,
selectable TextKit 2 views. Each carries its message ID, type-specific part ID and rendered-to-source UTF-16 mapping.
`ResponseTextView` adds the native comment/side-question edit menu; source text remains the authority (especially for
selections spanning Markdown delimiters). The later [Markdown rendering](#markdown-rendering) work adds native table grids, highlighting and the extended formatting capabilities.
Images are decoded through `CGImageSourceCreateThumbnailAtIndex` at the displayed pixel size, never as full-size
bitmaps. Invalid images use a compact filename/“Imagem indisponível” placeholder. The seed image is now a valid
96×64 PNG; tests retain the old corrupt sample to verify rejection before painting.

The native pinned section header is the user bubble itself, not a duplicated overlay. Its optional two-line clamp
and manual expansion are independent of reaching the top. Auto-follow stops on user scrolling; the round glass button resumes following the tail.
Tests in `ConversationTests.swift` cover all 41 fixtures, paging, tool summaries/groups, model/context identity,
agent counts, replayed SSE, dates/unread/viewed decisions and Markdown source mapping. Frame-health sampling
is unavailable for iOS simulators in agent-device; do not report an inferred FPS figure.

### Conversation actions (wave 2)

- `ConversationDraft` keeps one attributed draft per session in `SessionStore.drafts`, including the pending queue
  edit and local model/agent choices. Wave 3 adds protected on-disk persistence, tokens, attachments and the `+` menu
  (details below). `ComposerTextView` is a TextKit 2 `UITextView`, growing to six lines before scrolling, with native
  selection. Dragging or tapping the transcript dismisses the keyboard; no accessory row consumes conversation
  space. Empty input shows the local-dictation microphone described above.
- `PromptRequest` and `PromptSubmission` own serialization and sending. New sends have a unique `msg_` ID,
  `metadata.displayText` and `comments:[]`. Admission gets one automatic transport/5xx retry with the exact same ID;
  a failed attempt keeps the text and request for a manual retry. Steer applies agent, then model, then prompt;
  queue applies neither selection endpoint. Busy sends read `followUpBehavior`; long-pressing Send offers its
  alternate. Idle sends always steer. Queued model/agent metadata is presentation, not a per-prompt execution
  override: later delivery uses the active session selection, just like the web.
- The model sheet shows explicit `visibility:"show"` entries only and excludes disabled models. Favorites remain in
  stored order at the top and in their provider groups. Provider order follows saved ranks, then the PWA's popular
  providers, then provider name; rows sort by model name. Search mirrors the PWA's Unicode letter/number normalization,
  substring and no-spaces matching across model name, ID and **provider name**. Effort uses the model's real variants.
  Stars mutate `model.favorite` without making hidden models visible. A row's swipe/context menu sets or clears
  `model.default` with its variant; a badge and a separate Clear action identify the default for new sessions.
  `Gerenciar modelos` lists every enabled model, including hidden search results. Model/provider switches send
  `model.visibility` intents; provider switches affect **all** enabled models of that provider, not only search matches.
  Mutations retain the newest acknowledged preference revision while SSE snapshots catch up. The agent menu lists
  non-hidden primary and `all` agents. A session without a selected model uses preferences/default-model discovery.
- The tray has Stop (`resume=true`), conditional Background and queued user items. Pending request cards take its
  running row's place while the session waits for you; queued items remain available. Editing submits a replacement
  ID before cancelling the original; no text PATCH or ID reuse is attempted. All inbox events revalidate the tray.
- Permission decisions are once, reject, and explicit always (the small `…` or long press), sent to the request's
  actual owner. Question cards use option values, support multiselect and custom text, omit hidden/inactive fields,
  and dismiss with DELETE. Sending a normal prompt never answers a form. Generic non-question forms and field types
  other than string/multiselect are not implemented by this wave and are identified as unsupported rather than
  silently interpreted. Pending tool lines show “Aguardando permissão/resposta” without a ticking elapsed timer.
  Questions use the info role for their icon/title/border and pending tool line; permissions retain the error role.
- The agents screen and header share one work projection (see [Agentes e tarefas](#agentes-e-tarefas)). It excludes
  foreground shells and the viewed child, opens real child IDs, reveals a background shell's tool (expanding its
  group), and confirms individual interruption, with a visible stop button as well as trailing swipe/context actions.
  It colors the agent name and keeps elapsed time on the row. Context details start at medium height and expand
  to large; they use the last measured assistant and its model, with token components, cache hit,
  session/descendant/total cost, model/provider, branch and directory. No extra child transcript is fetched for usage.
- The transcript is still a recycling `List`. An empty older-page response no longer keeps a top anchor during
  initial Markdown measurement; active tail-following does not acquire a history anchor. No off-screen parsed text,
  image or UIKit view cache was added by the action cards.
- `ToastCenter.show(_:kind:)` and `.toastOverlay(_:)` are the shared feedback API for later waves. The glass capsule
  sits below the conversation/sheet header, replaces the preceding toast, announces through VoiceOver and dismisses
  after four seconds (six for errors). Copy response/code/diff, sending failures, request replies, queue operations,
  interruption/background and model preference changes all use it. Failed drafts retain their persistent error too.

The Swift Testing suite includes `ConversationActionTests.swift`: wire bodies and HTTP methods/owners, admission
retry identity/order, queue replacement/failure, permission and form responses including dismissal, visibility and
favorites, running-work rules, context math and pending tool labels. The review adds the exact PWA search cases,
provider ordering and all three model preference intent encodings. There are 57 tests across the package.

Wave 2 was built without new warnings and exercised against port 4177: idle/busy and alternate submission, model and
effort selection, a primary-agent switch to `utra` on send, queue edit/promote/remove, Background, root/child/shell
interruption, once/reject/always permission decisions, question answer/dismissal, child navigation and context
details. Prompt executions used only `llm-proxy/gpt-6-luna` / `low`. The conversation seed was recreated with
`seed-conversation.ts --reset` after the action checks; no Sessões request was consumed. Simulator evidence for both
themes lives in `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda2/`:
`a-{dark,light}.png`, `b-{dark,light}.png`, `d-{dark,light}.png`, `models-{dark,light}.png`,
`effort-{dark,light}.png`, `agents-{dark,light}.png` and `context-{dark,light}.png`.
`context-info-{dark,light}.png` shows the lower cost/model/directory section. Review evidence adds
`models-search-{dark,light}.png`, `models-manage-{dark,light}.png`, and `toast-{dark,light}.png`.
The sandbox is deliberately left with Luna 6, Luna 6 - fast, Anthropic Haiku 5.5 and Opus 5.5 visible, Luna 6 favorited,
and Luna 6 / low the default for new sessions, all configured through the native UI. Other servers' preferences are
unchanged. The three obsolete debug captures were deleted. Error toasts were exercised with genuinely stale B/D
requests (only those owned seed sessions were deleted); `seed-conversation.ts --reset` now skips already absent
manifest members so this verification remains safely repeatable.

“Permitir sempre” persists a **project** permission, not a session-only choice. Before resetting its test, list
`/api/permission/saved?projectID=<conversation-project>` and remove only the exact newly created test rule via
`DELETE /api/permission/saved/<id>`; never clear shared rules indiscriminately. Otherwise a fresh B can finish
without asking and the seed's readiness wait times out. The wave-2 test's own rule was removed before the final
reset. During the first wave-2 capture, one restored Explore child finished with “Não encontrei uma ferramenta shell
disponível” after a tool-catalog rescan. The capsule always reflects actual runtime activity rather than fabricating
the intended two tasks. The root shell, queue, B's permission and D's question are restored for final captures.

### Advanced composer (wave 3)

- `ComposerDocument` / `ComposerSpan` model the plain display text plus typed token ranges in UTF-16. The TextKit 2
  editor retains encoded token attributes, snaps the caret out of tokens and deletes an intersected token as a unit.
  Raw trigger text remains plain text. `ComposerTrigger` recognizes word boundaries; `/` is only active at offset 0.
  Space, Escape and a tap in the transcript dismiss suggestions. Trigger queries disable autocorrection,
  autocapitalization and predictive suggestions; prose restores the keyboard defaults. Unselected correction
  ranges cannot replace a token.
- `ComposerSources` merges files, recent root sessions, mentionable agents and visible references for `@`; supported
  local commands plus backend commands and noncolliding slash skills for `/`; skills for `$`; project-over-global
  case-insensitive snippets (including aliases) for `#`. File/session searches debounce 180 ms and cancel stale reads.
  The glass panel highlights the first result, groups by source and has explicit empty/error states. Catalog
  descriptions retain their server-provided language; native labels are pt-BR. Apps and MCP resources are omitted.
  Across sources, name/ID/alias prefixes rank before name substrings, then description-only matches. File basenames
  participate in name ranking. Equal-ranked items retain their catalog order, and section headings never move
  description matches ahead of name matches.
- `PromptRequest(document:…)` normalizes newlines, expands snippets and adjusts later mention offsets, adds session
  reference instructions and `metadata.sessions`, and sends URI-only files, agents and skills. `displayText` remains
  the typed text, `comments:[]` is retained, and additive `metadata.composerTokens` restores native token styling in
  drafts/queued edits/sent bubbles. Directory references use file URIs. Backend command tokens dispatch to `/command`
  with argument-relative mentions, without an automatic retry (that endpoint has no idempotency key). Slash skills
  remain prompts. `/model` and `/agent` open local pickers; `/compact` admits manual compaction. Unsupported client
  commands and shell mode are not advertised. Ordinary prompt admission retains the wave-2 exact-ID retry, including
  when only the cursor moved after a failed send.
- The `+` menu lists **Expandir compositor** (only while compact), **Fotos** and **Arquivos** directly, in fixed
  order; the last two open the system multi-photo or document picker. Images are decoded off the main actor;
  HEIC/HEIF becomes JPEG and oversized supported images are scaled to a maximum side of 2048 px. Every blob is staged
  as raw bytes under the server's `paths.tmp/uploads/<uuid>/<name>`. PNG/JPEG/GIF/WebP/PDF additionally travel inline
  only up to 20 MiB and when the selected model advertises the matching input. Other files remain path references
  with `Attached file: …` and `metadata.attachments`. Chips show a bounded thumbnail or file icon, filename and remove
  action; preparation/upload progress and failures use the shared toast. No camera, paste or drag/drop was added.
- The small, muted in-card expand button (over three lines or with attachments), `+` menu and upward swipe open the same composer UI full screen, with the same draft,
  attachments and selection controls. Recollection preserves cursor and tokens. An explicit editor owner prevents
  the outgoing sheet and incoming compact editor from competing for first responder during the transition.
  The full-screen editor has one collapse control in its header; neither editor has a keyboard accessory row.
- `DraftPersistence` stores JSON and separate attachment files under Application Support, keyed by the server URL
  hash and session ID, using atomic writes and iOS file protection. Writes debounce 250 ms and flush on leaving or
  backgrounding. Model/effort/agent, cursor and pending queue replacement ID are retained. Attachments are capped at
  25 MiB total per draft; missing/oversized restored bytes are dropped with a toast. Removing/sending cleans bytes;
  launch cleanup deletes a session's draft only after an authoritative HTTP 404 (not a missing navigation row).
  Materialized inline files restored from the queue become local bytes again, never invalid prompt-input objects.
- The model picker uses only the “Padrão” badge (no extra pin icon), and the running-agents sheet followed its content (now a pushed screen).

`ComposerTests.swift` adds trigger, catalog filtering/precedence, UTF-16/emoji/accent/newline serialization, snippet
offset shifts, command/skill dispatch, session instructions, inline/staged attachment rules, real image downscaling,
raw upload/command HTTP bodies, materialized queue restoration, suggestion ranking and protected-draft round-trip/cleanup tests. The package has 76 tests.

Verification uses only the dedicated **OpenCode Sessoes** simulator and port 4177. A separate session in the fake
conversation repository sends the file, agent, session, skill, snippet and attachment probes, runs
`conversation-review` and `/compact`, and remains available for inspection. The Photos probe is a generated 600×400
PNG added with `simctl addmedia`; the text file is selected through the real document picker. The conversation seed
is reset with `seed-conversation.ts --reset` before final captures; no Sessões request is consumed. Evidence for both
themes is in `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda3/`:
`context-*`, `commands-*`, `skills-*`, `snippets-*`, `menu-*`, `attachments-*`, `fullscreen-*`, `restored-*`, `sent-*`.
`agents-fit-light.png` and `default-badge-light.png` cover the two wave-2 review fixes. The C draft is kept local and
unsent during review; the separate verification session is idle. The composer review adds `long-draft-*` and
`keyboard-*` and refreshes all four trigger panels and `fullscreen-*` without a keyboard accessory row.
Native keyboards and system picker presentation deliberately replace the mockup's illustrative keyboard.
Token backgrounds use attributed text highlights rather than a separately drawn rounded chip view.

### Selection (wave 4)

- Assistant text blocks use `UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)` to retain the system
  edit menu and add **Comentar** and **Pergunta paralela** after Copy. Code, tools and user bubbles do not get these
  actions. UIKit derives the translucent selection from the theme's primary tint. A `ChatQuote` maps the rendered
  range through `MarkdownBlock` to exact source UTF-16 offsets, with the stable message/part IDs and the exact source
  substring. Identity/content changes and dismantling clear selection, source and callbacks; no off-screen text cache
  or additional SSE stream was added. Selection is bounded to one rendered Markdown block, as in the wave-1 renderer.
  Both TextKit subclasses use the designated initializer: UIKit's `textViewUsingTextLayoutManager` factory bypasses
  Swift subclass property defaults. The designated initializer retains the platform's TextKit 2 default.
- **Comentar** presents a native sheet with a read-only passage, token-capable comment editor, Concluir and Remover.
  In comments, `@`, `$`, and `#` work as in the main composer; `/` does not, as in the web.
  A sandbox UI/server check selects a file, Explore, the fixture skill and `#resumo` in the real comment editor,
  concludes, relaunches, then sends with a short main text/file mention. The comment's file/agent/skill arrive in
  structured arrays without main-text ranges; the main file keeps UTF-16 range 33–47. The model-facing `User comment:`
  expands `#resumo`, while the sent bubble preserves the authored token text. Sessions/references and snippets in
  comments also have package tests. Evidence: `comment-tokens-panel-*`, `comment-sent-*` and the sanitized
  `comment-server-verification.json` in the wave-6 final screenshots directory.
  `Citações · N` is collapsed by default above the composer card and expands to edit/remove individual quotes.
  Quotes survive relaunch through `DraftSnapshot` (old wave-3 snapshots decode with an empty quote array), restore
  from queued messages, count as sendable content on their own, and clear only after successful submission.
  Comments support the existing `@`, `$` and `#` suggestions; there is no separate binary-attachment picker in a comment.
- `PromptRequest(document:…quotes:)` emits the web's `metadata.quotes` and `commentPrompt` ComposerPart shapes, keeps
  `displayText`/`comments:[]`, and appends `Comments on earlier assistant messages:` after the main text/context.
  Comment file/agent/skill tokens travel without `mention` ranges; main offsets remain untouched. Snippets expand
  only in the model-facing comment. Restored web quote attachments retain their quote ownership in the protected
  draft; inline files follow main files in quote/part order and staged files stay referenced inside their quote.
  The sent bubbles reuse the existing quote presentation with aligned side bars.
- **Pergunta paralela** is a medium/large sheet. Selection prefills the blockquote; `/btw` suggestions open the
  same sheet, and submitting `/btw <question>` sends the first local question immediately. It shows the committed
  session model, not an unsubmitted composer selection. Answers use the response Markdown renderer, with copy.
  `SideQuestionRequest` carries exactly the web instruction prefix and at most five completed local Q&As, capped at
  1,000/3,000 UTF-16 units (without splitting a surrogate). `POST /generate` is JSON, never a durable prompt or SSE.
  Parar cancels only its URLSession task and restores the question; closing discards the thread. Failure has both a
  retryable shared toast and a local retry button.
  **Alexandre, 25/10:** every entry point (the selection menu's **Pergunta paralela**, picking the `/btw` suggestion
  and sending `/btw <question>`) opens the sheet at the large detent, handle visible, with its field focused and the
  keyboard up, without another tap. The conversation's `…` menu and quote sheets have no side-question action. Focus
  uses the expanded composer's `ComposerCoverAppearance` (after the presentation transition) and `SideQuestionInput`
  changes first responder on the next main-queue turn, never inside `updateUIView` (the hang fixed in `d6b4bc502ee`).
  `/btw <question>` also focuses the field: its question is already sent, so the keyboard is ready for the follow-up.
  Closing discards the thread, so a sheet never reopens with an earlier answer. The sheet and the bar behind its
  composer use the opaque theme background, as in the conversation, with a 12 pt fade above it; it replaced the
  `.regularMaterial` sheet whose answer showed through the translucent card. The bar is a bottom safe-area inset, so
  the answer's last line and **Copiar resposta** end above it, also with the keyboard open.
  `OpenCodeTests/SideQuestionPresentationTests` checks the large detent and focus only after presenting.
  `OpenCodeUITests/SideQuestionTests` uses the offline conversation fixture plus `-OpenCodeSideQuestionFixture`
  (DEBUG; a local long answer and local `/` suggestions, no HTTP) and checks both selection and `/btw` entries, an
  unchanged composer card while the answer scrolls behind it, and the end of the answer above the composer with and
  without the keyboard. Run it with `script/test-isolated.py` against an unused loopback URL and a private `--home`
  holding any password; the simulator needs `AutomaticMinimizationEnabled` off in its `com.apple.keyboard.preferences`
  so the software keyboard appears. Captures: `$TMPDIR/opencode/ios-side-question/prints/`.
- A native `UIContextMenuInteraction` on the recycled header handles **Copiar** and **Copiar citação** even in List's sticky section
  headers, where SwiftUI's `contextMenu` does not install an interaction. It does not intercept buttons, attachments or
  internal prompt scrolling. Copiar uses only `displayText`; the quote
  action copies blockquoted passages and comments. Both confirm through the shared toast.

`SelectionTests.swift` covers plain/emphasis/code/link/list/accent/emoji source mapping, generated markers, quote
wire metadata and exact appended block, comment mentions without shifted main offsets, quote-only messages, snippet
comments, inline quote file order/staged delivery, protected-draft round trips and backwards compatibility,
`/btw` prefix/history/truncation/HTTP, and user copy. The package has **85 tests**, all passing. The simulator build
introduces no warnings.

Live checks used only the dedicated simulator and sandbox 4177. The separate session
`ses_e9f6a2ed3ffeA7XsEWNVj4NTVK` (Onda 4 — seleção e perguntas) contains the two-quote/text and quote-only sends,
both confirmed through `custom.transcript/list` with exact metadata/appendices and rendered bubbles. All calls used
Luna 6 / low. A B draft with one quote/comment and main text survived termination/relaunch and remains unsent locally.
The B and verification-session transcripts were compared before/after side questions and stayed identical (6 and
11 messages respectively); the stop check restored its unsent question with no answer. Clipboard contents were read
back for both user-copy actions. No seed prompt, inbox or request was changed, so no seed reset was needed; B's
permission and D's question remain pending. Screenshots in both themes:
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda4/`, files
`selection-*`, `comment-*`, `quotes-collapsed-*`, `quotes-expanded-*`, `sent-*`, `side-empty-*`, `side-loading-*`,
`side-answer-*`, `btw-suggestion-*`, `user-menu-*`; `side-stopped-dark.png` adds cancellation evidence.

For wave 7: preserve the quote array in `DraftSnapshot` and the exact-ID failed-send comparison, the rendered/source
mapping, recycling timeline and shared SSE hub. File
review comments are still separate from chat quotes and are not exposed by this screen. A failed backend command
cannot be retried exactly-once; do not imply otherwise in its UI. The microphone was visual-only in this wave;
local composer dictation is described above.

For memory checks, build with `-configuration Release`, install `Release-iphonesimulator/OpenCode.app`, and run
`vmmap -summary <app-pid>` after Sessões settles, after opening C's tail, at the first history page, and after returning
to the tail. The app PID is printed by `simctl launch`. Compare **physical footprint**, not just `ps` RSS, which
includes shared framework pages. On the dedicated simulator the review measured 45.3/64.0/66.2/73.7 MiB before
recycling and 45.8/62.1/61.6/62.9 MiB after it; another full round trip reached 63.5 MiB. No simulator FPS claim is
made. Scope includes only the 89-message seed; the native recycling container, not a guessed per-message slope, is
the protection for longer sessions.

### Session and reading (wave 5)

**Status: complete.** The native `…` menu offers search, rename, session details and,
only on roots, archive. Rename uses a native text-field alert, trims empty/unchanged values, optimistically updates
the header and rolls back on failure with the shared toast. `PATCH /api/session/{id}` emits the existing events that
refresh Sessões. Archive reuses `custom.archive/archive` and the Sessões confirmation, then returns with a toast;
the backend owns interruption and cascading to descendants. Neither action retries automatically.

- The medium/large details sheet joins the existing project catalog and `custom.worktrees/locate` checkout root.
  It reads `/api/vcs`, `/api/vcs/diff?mode=working` and `/api/plugin` with the session's Location. The +/− is
  **current working-copy changes**, as on the web, not a sum of historical tool edits. Built-in plugins are omitted.
  Independent read failures say **Indisponível**, never “none”. Usage links to wave 2. The current sections are
  described in [Session details sections](#session-details-sections).
- `ConversationSearch` searches raw user text and assistant text parts in loaded sequence/part/occurrence order,
  excluding reasoning and tools. Literal non-overlapping matching folds case and accents and retains original
  UTF-16 ranges, including emoji. Source ranges map onto visible Markdown runs for translucent primary highlights;
  Markdown punctuation remains part of the searched source, like the web. A `UISearchTextField` replaces the header,
  with Cancelar, a `3 de 12` counter and previous/next controls above the keyboard. Older search explicitly loads at
  most three pages per attempt, stops at the first page with new matches and can be cancelled. Navigation wraps the
  loaded matches. There is no server-side full-transcript search or off-screen parsed-text cache.
- Search reuses `revealMessage(_:offset:persist:)` with `persist: false`. A visible TextKit occurrence refines the
  message-relative offset after materialization. Explicit navigation still wins over restoration and tail-following;
  closing preserves the current screen position but leaves the saved bookmark unchanged until a real user scroll.
  Normal transcript/runtime publication stays atomic so restoration cannot lose concurrently prepended pages.
  Markdown parsing restarts explicitly when a recycled row reappears with unchanged text after releasing its blocks;
  the regression suite caught a blank-row case when returning from historical reading to the tail.
- V2 **removed `todowrite`**, with no replacement. No task-list feature or model probe was added. All its historical
  parts, including failures, are suppressed in rendering, step counts/kinds and final-answer activity projection.
- Missing/non-string `/api/info.version` produces the incompatible-server notice and retry, including on Sessões
  when a legacy server cannot open a conversation. No app/server semver equality is assumed. A missing directory is
  established only by `custom.worktrees/available == false` (queried in the default Location) or a matching typed
  `LocationNotFoundError`. Arbitrary 404s/network errors are not misclassified. History remains readable and the
  composer is replaced by an explanation; retry rechecks availability. Moving out of it is described under
  "Diretório indisponível: mover a sessão" below.

`SessionReadingTests.swift` in OpenCodeKit covers matching, source highlights, order/counter, the older-page budget,
rename/rollback, removed tools, HTTP methods/Location scoping, independent service errors and notice
classification. The package has **106 passing Swift tests**. The warning-free simulator build and four app-hosted
tests pass. The existing seven UI cases pass with the expected already-viewed unread skip; the four new Wave-5 UI
cases pass in both themes, including the Sessões rename event, root/child details, two-page older search, an unchanged
saved tail bookmark after closing search, archive and a real removed test directory. UIKit's Unicode `typeText` can
hide the Simulator keyboard: the rename test restores it before resolving the alert button's shifted frame.

Run `python3 packages/ios-custom/script/test-session-reading.py` after `xcodebuild … build-for-testing`; set
`OPENCODE_TEST_THEME=openchamber-light` for light. It uses only the dedicated Simulator and explicit sandbox-4177
arguments, imports its own disposable sessions, archives only its own root, renames/removes only its own empty
directory, and never calls a model or answers a seeded request. No conversation seed reset was needed: transcripts,
inboxes and pending requests were unchanged. Ordinary viewed acknowledgement is intentionally not rolled backwards.

Evidence: `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda5/`:
`menu-*`, `rename-*`, `renamed-list-*`, `archive-confirmation-*`, `archived-toast-*`, `details-*`,
`search-results-*`, `search-older-offer-*`, `search-older-result-*`, `search-closed-position-*`,
`missing-directory-*` and `verification-openchamber-{dark,light}.json`. Both themes use the 10:58 status bar.
`incompatible-component-{dark,light}.png` are app-hosted renders of the **real notice component**, driven by a
version-less info response in a test transport; they are not claimed as live incompatible-server screenshots.
The actual sandbox remains V2-compatible and was never modified/restarted to manufacture that condition.

For wave 7: retain the non-persisting search request, the Location notice's send guard, atomic initial publication,
recycled Markdown lifetime and the single shared SSE hub. Enabling the child composer must not enable archive on
children or bypass a server/directory notice. Reuse `SessionStore.toast` for feedback after returning to Sessões.

### Diretório indisponível: mover a sessão — 24 October

Like the web's location-missing dock, the notice offers **Mover para o repositório local** (the project's
`canonical` root checkout) and an **Escolher worktree** menu, then keeps **Tentar novamente**. Moving happens only on a
tap: `POST /api/session/:id/move` with `{ directory }`, which the server applies at once to an idle Session whose
directory vanished (`core/src/session/move.ts`). The menu first runs `POST /api/worktree/refresh` (pruning worktrees
removed outside OpenCode, as the web menu does), then lists `/api/worktree` with `custom.worktrees/branches` labels,
excluding the root and the vanished directory. When descendants (`custom.session-family/page`) still sit in the same
vanished directory, **Mover a subsessão junto** / **Mover as N subsessões junto** (on by default) moves each one after
the Session; a partial failure is reported in a toast. The actions are hidden for chats, projects without Git, unknown
projects and a vanished root itself, and disabled while the Session runs. After the move the conversation refreshes
in place: the server appends **Diretório de trabalho alterado**, wakes the Session (it idles without a model call)
and the composer returns.

Verification used **OpenCode Mover** (iPhone 18 Pro/iOS 27), `ios-mover-derived` and an isolated `custom-sandbox.ts`
home on port 4196. A private prepare step created a fake Git repository with worktrees, imported a parent and child
Session (no model calls) into a worktree and removed it with `git worktree remove`; `script/test-isolated.py
--environment` then ran `SessionReadingTests/testMoveToProjectRootRestoresComposerWithStrandedChild` and
`testMissingDirectoryKeepsHistoryAndBlocksComposer` (no actions for a non-Git Session) in both themes, and the server
confirmed both Sessions in the root checkout. `SessionRelocationTests` in OpenCodeKit cover the root rule, the move
request and its error, the refresh-then-list worktree menu and the paged stranded-descendant filter.

### Reading continuity (wave 6)

**Status: complete.** The package's 95 Swift tests, three app-hosted tests and simulator build pass without new
compiler warnings. The enabled `testHistoryNavigationAndRelaunch` checks five reopenings plus cold relaunch in each
theme, including an anchor outside the initial tail page. Every measured difference is 0 points (dark: floating-point
noise below `0.000001`), with 0 growth across cycles, inside the 24-point acceptance bound. The full native suite has
nine passing tests and one expected unread skip after its watermark has already been acknowledged.
App-hosted `OpenCodeTests/ComposerKeyCommandTests.swift` checks hardware Return registration and actual UIKit action
dispatch, including suppression during sending, marked text, suggestions and auxiliary editing. The physical-keyboard
path still needs a **manual check on a device**: XCUITest does not deliver hardware Return in this Simulator setup.
The shared Simulator keyboard settings are never changed. Actual software-keyboard taps verify the private path.
`OpenCodeTests/ReadingGeometryTests.swift` also checks the real native-cell/zero-size-probe boundary and correction
against a captured viewport origin.

- `ConversationProjection.finalAnswerDividers(_:)` is a pure projection across each user group. It considers only
  rendered activity, completed error/retry-free `stop` assistants, explicit `final_answer` phases and the legacy
  first-text-of-last-message fallback. Each eligible sequence can have its own divider, including in history.
  The 1-point full-width line uses `borderStrong` from `v2-border-border-strong`, has 12 points below it and is hidden
  from accessibility. Text/part IDs, selection and quote source mapping are unchanged.
- `SessionStore.reading` owns a separate `ReadingPositionStore`: the same URL hash as drafts, then session ID (no
  directory or credentials). Up to 200 LRU entries contain only follow-tail intent or a message ID/point offset and
  update time. Protected JSON in `Application Support/OpenCode/Reading` uses atomic writes. Scroll-idle capture
  debounces 250 ms; leaving, opening a child and backgrounding flush immediately. A weak map of **mounted** UIKit row
  probes measures partially visible responses and natural user bubbles below the actual sticky header.
  Probe views identify their current recycled cell, but geometry comes from the native cell's bounds: a SwiftUI
  background representable can be zero-sized or inset and must not stand in for the message rectangle. The position
  also records the captured usable-top edge (`viewportTop`) so natural/pinned header transitions do not redefine the
  coordinate origin when reopening; old JSON without that optional field still decodes. A prompt kept as the reading
  position (revealed by search or a comment's quote, or captured from it) is measured against every active header
  except its own: below its own header it would move down until inline, become pinned and move back, a loop that
  shook a conversation's first prompt by its day chip at about 27 corrections per second.
  Restoration and layout never recapture their own geometry: only real user scrolling or an explicit new target may
  change a bookmark. Negative offsets are real gaps before a message and are preserved, not clamped to an arbitrary
  negative limit. That former `-32` clamp caused a systematic upward shift when a captured gap was larger.
- Saved anchors suppress the initial tail jump and live following. Restoration loads at most five older pages per
  attempt, offers **Retomar leitura** beyond that budget, materializes the message and corrects its offset using real
  Markdown/image geometry. User interaction cancels it; a missing message after exhausting history falls back to the
  tail. Layout changes retain the anchor and clamp the offset to the measured message height. New messages do not
  steal a non-following position. The app's existing portrait-only orientation policy is unchanged.
- **Wave 5 API:** `ConversationStore.revealMessage(messageID, offset: 0)` requests explicit navigation through the
  same cancellable path, taking priority over saved position and tail. Search may page its own results before calling
  it. A new request has a fresh token even for the same message. Tool reveal also pauses following and expands the
  actual group. Do not overwrite the reading store or the viewed watermark to navigate.
- The entire composer/quotes/tray/queue region is a real sibling below the recycling List, not a bottom overlay.
  Its measured layout always reduces the transcript viewport, including while the keyboard is shown. A non-empty
  response selection pauses following; **Ir para a mais recente** or submission resumes it. The button is independent
  of viewed acknowledgement and only appears beyond the web's geometric threshold; there is no upward unread jump.
- Step/detail expansion is stored as IDs and explicit booleans in a separate 16-session memory LRU. Outputs, parsed
  Markdown, images and views are never cached there. The native edge-pop recognizer is enabled for the hidden-bar
  conversation, with root/transition guards and its previous delegate restored on departure.
  The pinned bubble's native background is opaque and full width, with only a 14-point bottom gradient; no inset
  material/rectangle is painted over the code block beneath it.
- Return inserts a newline; **Shift+Return sends** through the button's exact predicate/action in both main composer
  sizes. Hardware uses a priority `UIKeyCommand`; software consults the keyboard **before mutation**. Suggestions and
  marked text take precedence. The side-question editor has its own submit action; comment editors have no submit
  shortcut. `SoftwareKeyboardShift.swift` alone resolves private `UIKeyboardImpl` state at runtime, checks selectors
  and calls BOOL getters with their proper signature. Automatic Shift, Caps Lock and unavailable state all fall back
  to a newline. **Private API warning:** internal TestFlight still processes the binary and may reject this with
  `ITMS-90338`; remove that file/software path and retain hardware Shift+Return if that happens. Third-party keyboards
  and future UIKit versions have no guaranteed private-state contract.

Swift Testing adds divider sequences/eligibility/history/visibility, partial-row capture, restoration decisions,
protected serialization/server separation/LRU, expansion memory and all Shift-state/editor-state combinations
(`ReadingContinuityTests.swift`). Run `swift test` from `OpenCodeKit`. The `OpenCodeUITests` target drives
the actual software keyboard keys, five repeated navigation cycles plus cold relaunch, comment tokens and expanded
quote layout. Hardware actions are checked in the app-hosted `OpenCodeTests` target. After
`xcodebuild … build-for-testing`, run `python3 packages/ios-custom/script/test-reading.py [testMethod …]`. It only uses
the dedicated simulator and port 4177, creates/deletes isolated Luna 6 / low keyboard sessions, reads the sandbox password without
printing it and removes its protected temporary xctestrun configuration. Never launch the app without explicit
`-OpenCodeServerURL http://127.0.0.1:4177`, including in automation relaunches.
The scheme's test action also has the explicit sandbox URL, including the app-hosted target. The runner serializes
the dedicated Simulator and uses uniquely named, private xctestrun files. Select hosted tests with, for example,
`python3 packages/ios-custom/script/test-reading.py OpenCodeTests/ComposerKeyCommandTests`.

`testJumpToLatestWithoutUnreadStateInBothThemes` replaces the old watermark-dependent `testUnreadJump`: its own
offline state is repeatable and requires no seed reset or watermark rollback. The B seed includes
one imported read before its existing Markdown answer: the former simple reply correctly had no final divider and
could not exercise the requested after-tools screenshot. No web/backend implementation or Sessões request changes
are needed. Wave 7 should keep child navigation on this same reading/expansion store and reuse the optional editor
submit action instead of adding a second keyboard handler.

Verified on **OpenCode Sessoes / iOS 27.0** with the clean 10:58 status bar, against sandbox 4177 only:

| Input on the real software keyboard | Result |
| --- | --- |
| Return after prose | Newline; no send |
| Return with automatic sentence capitalization | Newline; no send |
| Caps Lock, then Return | Newline; no send |
| Manual Shift, then Return | One send; no newline |
| Hardware Return + Shift | App-hosted action test; physical keyboard remains a manual device check |

Live evidence is under
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda6/final/`:
`b-final-divider-*`, `c-original-*`, `c-cycle-{1…5}-*`, `c-after-relaunch-*`,
`c-sticky-code-*`, `c-reading-comparison-*`, `comment-tokens-panel-*`, `comment-sent-*`, `b-expanded-quotes-*`, `expanded-before-child-*`,
`expanded-after-child-*`, `expanded-reopened-*`, and `keyboard-*`. The history test compares the same anchor passage
within 24 points of the original and allows at most two points of range across five reopenings plus cold relaunch.
Both root and child edge swipes are
exercised. The conversation seed was reset before final captures; B's permission and D's question remain pending,
and keyboard-test sessions are deleted by the runner. The B quote remains an unsent local draft.
The side-by-side comparisons show the original, fifth visit and cold relaunch. Stale unthemed duplicates and the old
boxed-header captures were removed from `final/`. The conversation seed's transcript/requests were not changed by
this iteration; only separate disposable verification sessions received the tiny Luna 6 / low prompts.

### Subagents and alerts (wave 7)

**Status: complete.** Children use the same attributed composer, draft, quotes, side questions, tray, queue and
idempotent admission pipeline as roots. Delivery uses only the child's own execution state. The agent name comes
from its catalog and is read-only: the primary picker and `/agent` suggestion are absent, and neither ordinary nor
command sends call `/agent`. Model/effort selection still works. Background and archive remain root-only, and the
missing-directory/incompatible-server send guards remain in force. There is no read-only or first-send notice.
After the original subagent Job delivered, later replies stay in the child; the app never rewrites the parent's tool
result or secretly wakes the parent.

- `SessionStore`'s existing single `EventHub` listener feeds `SessionAlertCenter`. Only live root execution success,
  root execution failure, `permission.asked` and question `form.created` signals can produce a banner. Child terminal
  events, individual tool failures, retries and intentional interruption are not session-failure alerts. Requests
  resolve their actual owner and ancestors to the root; the open owner/root is suppressed. Current server preferences
  are read before delivery: muting either root or owner suppresses the banner, and auto-approved permissions are not
  announced. Muting does not remove requests from **Precisa de você**.
- `SessionAlertPolicy` claims server + actual owner + kind + watermark (terminal event timestamp or request ID), even
  when a signal is suppressed. The last 500 claims are persisted in server-scoped local preferences. Reconnection
  establishes a fresh live-time boundary; old signals and all reconciliation snapshots are silent. In-flight lookups
  cannot deliver after disconnection or into a new connection generation. No missed-event backfill is attempted.
- One replaceable glass banner shows the repository monogram, session title and **Concluída**, **Respondeu**,
  **Falhou** or **Precisa de você**. It dismisses after six seconds, has a close action and announces once to VoiceOver. A shared
  typed conversation path makes tapping push the target from Sessões, another conversation or another tab, without
  discarding the underlying reader. App-owned sheets also present the banner; only the top presentation draws it,
  and tapping closes the modal chain before exposing the destination. The central timer/listener is not duplicated
  by these presentation overlays. System dialogs and file/photo pickers retain control of their own UI.
- **Respondeu vs Concluída (Alexandre, 24/10).** A root execution success is not necessarily the end of the work: an
  orchestrator may answer while its subagents run in the background. On an admitted `session.execution.succeeded`,
  `SessionAlertCenter` reads, from the server at that instant, `custom.session-family/snapshot` (`active`: the
  native process-global active set restricted to the root's descendants) and `GET /api/shell` for the root's
  directory. `SessionAlertWork` counts as **agents** the active descendants whose parent is not itself active (a
  running child and its running grandchild count once, like the header's agents capsule; a still running grandchild
  of an idle child still counts) and as **tasks** the root's running shells (a finished root has no foreground
  tools, so they are background shells, again like the header). Anything running gives **Respondeu · 1 agente
  rodando**, **· 2 agentes**, **· 1 tarefa**, or **· 1 agente e 1 tarefa rodando**, with a speech-bubble icon in the
  neutral `textSecondary` role; nothing running gives **Concluída** with the ✓ in `success`. Reading after the
  event avoids the race between the root's event and its children's events: the server's state when the read
  runs is the label, never this device's possibly stale list (`store.active`) or another session's messages. If
  the family read fails or takes longer than **2 s**, the banner says only **Respondeu**: completion is only claimed
  when nothing is known to run. A failed shell read (for example, a missing directory) counts no tasks.
  **Falhou** and **Precisa de você** are unchanged and never wait.
- **Reply preview.** **Respondeu** and **Concluída** banners show one truncated line under the label: the first
  nonblank line of the latest assistant text, verbatim, from the same `client.preview(id)` (`custom.transcript/list`,
  three messages) and `SessionPreview` the Sessões rows use (`SessionPreview.reply`). It is absent when the user wrote
  last, when the response has no text, or when the read fails or exceeds **1.5 s**. The family, shell and preview
  reads run concurrently, so a completion banner appears at most about 2 s after the session/preference lookup;
  this lookup runs off the event loop and a newer alert, deletion or reconnection discards it. Its VoiceOver label
  and announcement include the label and preview. There are no system notifications, push or Live Activities for
  session alerts, so no other surface uses these labels.
- `Haptics` uses UIKit's system-respecting semantic generators: light on successful send/archive/pin/mute, success on
  permission allow/question answer, warning on denial/dismissal, selection on explicit copies, soft on banner arrival.
  Side-question submissions also give light feedback. Streaming and ordinary snapshot changes never trigger it.
- `ModelCatalogCache` is shared per server. Session catalogs win over cached/default-Location definitions, matched by
  provider **and** model ID. The footer remains **Luna 6 · low** when the session directory has disappeared, even on a
  cold launch; unknown pairs alone fall back to their ID. This does not enable sending from an unavailable Location.

`OpenCodeKit/Tests/OpenCodeKitTests/SubagentAlertTests.swift` covers terminal/request rules, current owner/root,
descendants, mute/auto-approve, suppression claims, reconnect/backfill/deduplication, server separation, child prompt
encoding/delivery without an agent switch and catalog fallback/default-Location HTTP scoping. Run `swift test` from
`OpenCodeKit`. After `xcodebuild … build-for-testing`, run:

```sh
python3 packages/ios-custom/script/test-subagents-alerts.py
OPENCODE_TEST_THEME=openchamber-light python3 packages/ios-custom/script/test-subagents-alerts.py
```

The runner accepts `--server-url`, `--home`, `--derived`, `--device` (simulator name or UUID) and `--evidence` for an
isolated worker (never 4096/4178), plus test identifiers. It also imports an orchestrator and a background-shell
root: `testRootReplyWhileWorkRunsSaysRepliedThenConcluded` has the orchestrator start one background General child
that runs `sleep 30`, expects **Respondeu · 1 agente rodando** with the reply line, then **Concluída** with the reply it
gives once notified of the child's completion; the other root starts one background `sleep 30` shell and expects
**Respondeu · 1 tarefa rodando**. Cleanup interrupts both roots' children too.

The sandbox-only runner creates its own Luna 6 / low parent and genuine General child in the fake conversation repo,
checks a native child send and exact preservation of the parent's completed subagent part, exercises all banner kinds
over conversations/Sessões plus navigation from another tab and a sheet, mute, background/foreground and the missing
directory footer. The current session stays silent even while its full-screen composer covers the transcript.
Failure is a deliberately nonexistent agent on an owned imported session, before any model call;
a failed shell or a user interrupt would not honestly exercise `execution.failed`. The runner never answers a seed
request. It interrupts its own executions, waits for their asynchronous removal from `/active`, and records final
outcomes and IDs. The owned missing-Location history never executes and cannot use the Location-scoped interrupt.

Final verification: **113 Swift Testing tests**, the warning-free simulator build/test build, **four app-hosted
tests**, **six Wave-7 UI cases in each theme**, and the four existing session/reading UI cases in each theme pass.
The existing continuity suite passes six cases with the expected already-viewed unread skip; five reopenings plus
cold relaunch again measure **0-point drift**. Its shared `SessionRowVisibility` helper now requires the whole row
to be above the floating tab bar/accessory: AX had reported an off-screen prefetched row as hittable behind that bar
once the sandbox contained many verification sessions. No assertion was removed and no seed request was consumed.

Both-theme screenshots and per-run verification JSON are under
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-conversa-prints/onda7/`:
`child-sent-*`, `banner-{success,failure,permission}-conversation-*`,
`banner-{success,failure,permission2,question}-sessions-*`, `banner-other-tab-*`, `banner-over-sheet-*`,
`banner-opened-from-sheet-*`, `banner-opened-question-*`, `reconnected-without-replay-*` and
`missing-directory-model-name-*`. All use the dedicated simulator, explicit sandbox URL/password and 10:58 status bar.
`verification-openchamber-{dark,light}.json` records the final runs' IDs and outcomes; `owned-sessions-final.json`
includes all 54 owned sessions from preparatory and final runs, with none active and no leftover owned mute keys.
The conversation seed's permission and question are still pending; no seed reset was needed.

Still out of scope: automatic redelivery of later child replies to the parent (requires a backend observation
contract), system notifications/APNs/background delivery, Changes/Files views,
fork/revert and offline editing. The earlier software-keyboard private-API/TestFlight caveat and physical-keyboard
manual check remain unchanged.

### Live data and contract fixtures

`SessionStore` is main-actor `@Observable` state. `OpenCodeKit` owns Codable wire models, HTTP/Basic authentication,
SSE framing, root-family rollup, attention, recent ordering, preview extraction, and pt-BR timestamps. The UI owns
only presentation and client-side filters.

- Navigation is paginated at 500. Pins/mutes match a session ID across all stored server keys, including legacy bare
  IDs. New entries use the Mac web app's `JSON.stringify(["http://localhost:4096", sessionID])` key; removing a pin or
  mute removes every matching entry. Repository selection remains under `projects["local"]`.
- Requests use the global `custom.requests/permissions` snapshot and `/api/form` only for directories with pending
  questions. This avoids loading every Location. `custom.session-family/snapshot` is mirrored in the client but is
  not required by this screen.
- Branches are loaded in one `custom.worktrees/locate` call, without booting each repository's Location.
- `custom.navigation` excludes archives by contract. The archived list pages root metadata from `/api/session` and
  retains only archived sessions; it never loads their transcripts.
- Previews use only `custom.transcript/list` (three messages, at most four concurrent reads), never the native message
  endpoint. Streaming text/tool events debounce preview refreshes; structural events invalidate the snapshots.
- Each SSE connection and foreground return reloads the snapshots. URLSession's 45-second no-data timeout includes
  heartbeat bytes; reconnects back off from one to fifteen seconds. SSE is framed from bytes because Foundation's
  `AsyncBytes.lines` drops the empty lines that delimit events. Full event-triggered reloads are coalesced into
  trailing 1.5-second windows; changes during a reload schedule another window. Preview refreshes retain their
  separate 250 ms debounce. Quota reads are limited to once per minute when refreshing. There is no offline editing
  or push notification handling yet.
- Theme roles are typed as `ThemeRole`; every role and avatar is validated when loading a generated theme. An
  incomplete or invalid theme falls back to bundled OpenChamber dark.

Capture sanitized fixtures from the running isolated server without logging its password:

```sh
OPENCODE_SERVER_PASSWORD_FILE="$SANDBOX/password" \
  bun packages/ios-custom/script/capture-contracts.ts http://127.0.0.1:4177
```

The fixtures cover navigation, preferences, projects, active sessions, permissions, forms, archived metadata,
subscriptions, and running/image/user transcript previews. Local paths and account addresses are scrubbed.
Re-run `swift test` after recapturing. The seed belongs to the backend development workflow; the app never starts,
stops, resets, or seeds a backend.

For the conversation waves, see [`docs/conversation-contract.md`](docs/conversation-contract.md). Create the separate
conversation seed with `bun packages/ios-custom/script/seed-conversation.ts`, then capture its contracts with
`bun packages/ios-custom/script/capture-conversation.ts`. Both verify sandbox ownership and reject production ports.
The seed manifest is `<sandbox-home>/seed-conversation.json`; `--stop` interrupts only its sessions and `--reset`
recreates only those sessions. The capture writes `Fixtures/Conversation/`, including one real short SSE execution;
`--snapshot-only` refreshes snapshots while reusing that recording, without calling a model. The existing Sessões
seed and its pending requests are not consumed.

### First-screen verification

The first implementation was built and exercised on the dedicated iOS 27 simulator in both OpenChamber modes.
Pin/unpin, mute/unmute, status/repository filtering, repository reordering, and mark-all-read were checked against
the live sandbox. Repository removal/addition and external preference changes over SSE were also verified. The
permission/question seed is not consumed by these checks. Native menus, swipe actions,
confirmation dialogs, archived navigation, and the native conversation reader are retained rather than drawing
mock replacements. New session, voice, selection, settings, the master-session accessory, and the other tabs remain
visual-only as specified, except settings in Você (implemented in wave 8).

## Open decisions

- **MVP scope after the first screen:** which of the other [Goals](#goals) go into the first TestFlight build.
  Notifications are already out.
