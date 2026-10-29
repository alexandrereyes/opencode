# OpenCode iOS (custom)

**Mockups:** see the versioned [native screen references](docs/screens/README.md) and their offline regeneration script.

Native iOS client, written in Swift, for the OpenCode backend. It talks to the same server as the TUI and adds no
separate backend of its own.

The iOS and Mac apps replaced the custom web app, which was removed on 2026-10-29; the custom server now serves
upstream's standard web app for occasional browser access. References in this document and in `docs/` to
`packages/app-custom`, `packages/ui-custom` and `packages/session-ui-custom` (often shortened to `app-custom/…` or
`session-ui-custom/…`) point to the tag `web-custom-final`, for example
`git show web-custom-final:packages/app-custom/src/servers/connect/pairing.ts`.

This is a personal app. It is distributed only through a private TestFlight (internal testing) and will never be
submitted to the App Store.

> **Status:** "Sessões", "Nova sessão", the conversation screen and "Você" (settings) are implemented. All conversation waves (0–7) are complete
> (see [Second screen: Conversa](#second-screen-conversa)); the remaining exclusions are listed below.

## No tab bar (28 October, option A)

Sessões is the app's root (`AppShell` in `OpenCodeApp.swift`); there is no `TabView`. The removed Painel, Pedidos
and Projetos tabs were "Esta tela está em construção" placeholders: Pedidos only showed the request count as a badge,
which the Sessão mestra bar already shows ("N precisam de você"), and adding a repository stays in the chips' **+**
and Nova sessão.
- **Header:** "Sessões", then voice, **+** and the **AR** avatar with the former Você tab's ring (a neutral track and
  a green half, decorative: it never carried data). `SessionColumnHeader` takes it as the optional `account` slot
  (VoiceOver "Você", identifier `sessions-account`), so the Mac keeps its gear (`settings`) and its own title-bar
  avatar.
- **Você** opens from the avatar as a sheet over Sessões (`SessionStore.settingsOpen`), like Arquivadas, the quota
  detail and the session switcher: the Sessões stack keeps only conversations, and Você keeps its own navigation
  (themes, servers, pairing). **Fechar** (`settings-close`) or a swipe down closes it. Choosing another server
  rebuilds the store and reopens Você on the new one, as the tab did.
- **Sessão mestra bar:** a glass capsule in a bottom `safeAreaInset`, above the home indicator where the tab bar
  was; the list scrolls its last row (Arquivadas) above it and the floating voice bar stacks over it, at the same
  width (both inset 21 pt, like the former tab accessory). It hides
  while a conversation, the master or Nova sessão is on the stack, as the tab accessory did.
- **Navigation:** Live Activity links, session alerts and the master bar close Você and push onto the Sessões
  stack; voice, `opencode-file://` and folder links, the switcher and Nova sessão never depended on a tab.
  `currentSessionID` treats an open Você as no visible conversation, as the Você tab did.
- **Tests:** `AppNavigation.swift` replaces tab taps (`openYou()`, `showSessions()`, `bottomChromeTop`);
  `AppShellTests` checks there is no tab bar, the header order, Você opening and closing, the bar's place and that
  the list's last row stays above it.

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

Out of scope at first: iPad layouts, offline editing, and terminals (PTY). The Mac app started on 27 October (see
[Mac app](#mac-app-stage-1--27-october)).

## First screen: Sessões

The equivalent of WhatsApp's "Conversas": the same sessions, in the same order, as "Recentes" in the custom web
app's sidebar, with a different presentation. The web app is the behavior reference
(`packages/app-custom/src/shell/titlebar/sidebar-model.ts`, `sidebar-order.ts`, `sidebar-rows.ts`, and
`packages/app-custom/src/shell/notifications/session-attention.ts`) and is not changed by this work.

- **Rows:** only root sessions, without archived sessions or the Sessão mestra. Running state, permissions, and
  questions of subagents roll up into their root session. Managed chats (`custom.chats`) appear under **Todas** (and a
  state filter) mixed with repository sessions, in the same sections and rules, and alone under the **Chats** chip;
  a repository chip lists none. Their requests count in **Precisa de você** and the Sessão mestra bar. Pinned sessions come first, then the activity order. When a session has
  several states, the priority is permission > question > running > failed > unread > stopped. The rows are grouped
  into the sections described in [Layout D](#layout-d-precisa-de-você--27-october).
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
  "Avisar ao terminar" sessions), `custom.subscriptions` (usage strip), and `custom.transcript/list` for previews. Previews read the
  latest messages of each three-line row ("Precisa de você" and "Trabalhando"), as
  `packages/app-custom/src/agent-dashboard/preview.ts` does; compact rows show no preview and read no transcript.
- **Working:** list, status and repository filters (including removing, reordering, and adding repositories), opening
  a session (the native conversation reader), Permitir/Negar, archive, pin, "Avisar ao terminar", pull to refresh, deletion, and the
  list of archived sessions (open/delete; the backend has no unarchive).
- **Swipe actions:** trailing, from left to right, **Avisar ao terminar/Não avisar**, **Arquivar**, **Renomear** and
  **Excluir**; leading, **Marcar como lida** (unread only) and **Fixar/Desafixar**. There is no "Mais" action: the
  long-press menu keeps the full row action list (Abrir sessão, Renomear, Fixar, Avisar ao terminar, Marcar como lida,
  Excluir sessão). Pinning reuses `custom.preferences` (`sidebar.pin`), shared with the web, and the row moves into the pinned
  group as soon as the mutation returns. Renomear reuses the conversation menu's alert, validation (`SessionRename`),
  `PATCH /api/session/:id` and toasts, then reloads the list once the server confirms. After `build-for-testing`,
  `python3 packages/ios-custom/script/test-session-swipe.py --device … --derived … --server-url … --home …` imports two
  owned sessions (no model calls), runs `OpenCodeUITests/SessionSwipeTests` and deletes them with their pin keys.
- **Selection (27/10):** the long-press menu's **Selecionar** starts a selection mode with that row selected. Rows
  show a leading circle and taps toggle them; swipes, the long-press menu and Negar/Permitir are off. The header adds
  `N selecionadas`, **Selecionar todas** (rows of expanded sections) and **OK**, plus a `⋯` left of voice with
  **Arquivar (N)**, **Excluir (N)** and **Cancelar**. Like the web sidebar (`sidebar-selection.ts`,
  `lifecycle-actions.tsx`): changing the filter or chip ends the mode, hidden or removed rows leave it, requests are
  serial (one per root; the server cascades children), finished rows leave the selection, failures stay selected
  with one "N concluídas; M falharam" toast, and an empty selection ends the mode. Archive has no confirmation and no
  undo (the backend has no unarchive). Delete confirms with the count, the permanence warning, running sessions that
  will be interrupted, the web's Sessão mestra warning (agent `mestra`) and an **Arquivar** alternative. The current
  master never appears in the rows. `script/test-session-selection.py --device … --derived … --server-url …
  --home …` imports four owned sessions (no model calls) and runs `OpenCodeUITests/SessionSelectionTests`.
  Destructive UI tests call `requireSandbox()`, which reads the DEBUG `debug-server-url` marker and throws, without
  acting, unless the app is connected to the sandbox; recreate the simulator between themes, since a relaunch without
  test arguments would use the default server.
- **Unread:** a dot, with no count. Marking a session as unread is not offered, because the backend only moves the
  viewed watermark forward.
- **Filter chips:** "Todas" first, as a compact icon-only chip (`square.stack`, a stack of every session; at least
  44 pt wide, same height and selected styling; VoiceOver "Todas" with its selected state, identifier `filter-all`). A
  long-press state filter adds its name beside the icon. Then Chats and the selected repositories ordered
  lexicographically by `SessionList.chipGroups`: (1) chips with a running root session (green arc) first; (2) then chips with an unread
  root session (the rows' orange dot, as a small corner badge); (3) then the
  saved manual position, `projects["local"]` as reordered by "Mover para antes/depois"; (4) then the name (natural,
  case- and accent-insensitive, pt-BR). Running + unread precede running only. Chats is part of the saved order:
  `projects["local"].chatsIndex` (plugin `custom.preferences`) counts the repositories before it, absent (older servers
  or profiles) meaning Chats first. The plugin keeps it after the same repositories when one is opened (prepended) or
  closed, and the web ignores it. "Mover para antes/depois" on any chip swaps it with its neighbour in that combined
  order (`ChipManualOrder`): passing Chats sends `chats.move`, otherwise `project.move`; an older server rejects
  `chats.move` with "Atualize o servidor para mover o Chats". A chip lifted by running/unread may not visibly move
  until it returns to its block. VoiceOver
  appends "com não lidas". `chipGroups` derives running, requests and unread for every chip in one pass, inside its own
  `SessionChips` view, so preview/streaming updates never re-evaluate it. A new order is applied only while the strip is
  idle and after it has held for 1.5 s (immediately when only the saved order changed), animates briefly (none with
  Reduce Motion) and keeps the active filter visible. `SessionChipsTests` (via `script/test-session-chips.py`, which
  stops live work, reads every session and completes two Luna 6 / low prompts on an owned sandbox) checks unread, a
  short real run rising to the front and returning, that reading clears the badge, and moving Chats persists.
- **Project icons:** a repository chip shows the project's own icon left of its name, at text size (18 pt scaled
  with `.subheadline`, rounded corners), keeping the running arc, unread dot and compact width; without one it is
  unchanged. The source is the Core's `project.icon` (no app UI to change it; agents set it with `PATCH
  /api/project/{id}` `{"icon":{"override":"data:…"}}`, see the `opencode-custom` skill), picked like the web sidebar:
  `override`, else the discovered `url` unless a `color` was chosen. Only inline data URLs up to 256 KB count
  (`ProjectIcon`); nothing remote is fetched. PNG/JPEG decode with ImageIO; SVG is rasterized once per revision by
  `ProjectIconRenderer`, an `<img>` in a throwaway web view (no JavaScript, network or non-`data:` resources, like the
  Mermaid diagrams) snapshotted to 144 px PNG. `ProjectIconCache` keeps decoded icons in memory and SVG renders under
  `Caches/ProjectIcons-v2/<sha256 of the image>.png`, so a new icon gets a new file and scrolling never re-renders.
  `project.updated` reloads the projects, so a change shows without reopening the app. `test-session-chips.py
  --icon NAME=FILE=RRGGBB` sets icons (and clears the others) for `SessionChipsTests`, which checks each chip's pixels
  for the icon color, its absence elsewhere, and a live removal and restore through the API.
- **Avisar ao terminar (28/10, replaced "Silenciar"):** a per-session bell stored in `custom.preferences`
  (`notifySessions`, intent `sidebar.notify`), off for every session. A row with the bell shows a small `bell.fill`
  (VoiceOver ", avisa ao terminar"). When that session's whole family stops working, the server pushes an APNs alert
  (see [Notifications](#notifications)). Muting is gone: rows muted by older builds show the normal orange dot, light
  their chip, count everywhere and alert in the app; the "Silenciadas" filter was removed. `mutedSessions` is ignored
  (older builds may still write it) and never turns into a bell.
- **Avatar:** two-letter monogram of the repository (the first letters of the first two words, or the first two
  letters of a single word: `abacato-v2` → `AV`, `opencode2` → `OP`). The color comes from `project.icon.color`, or a
  stable choice from the project ID when the project has none, through the theme's avatar tokens. A project with its
  own icon (see Project icons) shows it instead, cropped to the circle over a neutral `surfaceRaised` disc with a
  hairline `border`, in the rows, the session switcher, the conversation header (inside the context ring) and the Nova
  sessão project selector (`ProjectAvatar`). The running arc, `+N` subagents, state badge and unread dot stay on top;
  Chats rows, the Sessão mestra and the in-app alert banner keep their current avatars. `ProjectIcon.of` resolves each
  icon source once, so row re-renders never decode it again.
- **Components:** native iOS components themed by tokens: no tab bar (see [No tab bar](#no-tab-bar-28-october-option-a)),
  a bottom glass bar for the "Sessão mestra" pill, `swipeActions`, `contextMenu` for long presses, and the shared column header in a
  `safeAreaBar` (the navigation bar is hidden on this screen only; pushed screens keep theirs).

### Layout D ("Precisa de você") — 27 October

Approved by Alexandre from the Mac app mocks (`.agent-artifacts/mac-app/sessoes-d/` of the `mac-app-mocks` worktree:
`BRIEFING.md`, `referencia-coluna-d.png`, `referencia-janela-d.png`). The same column will be reused by the future Mac
app, without the web's "Projetos" and "Worktrees" groups.

- **Header:** one shared row, **Sessões** at the left and voice, the optional Configurações and `+` at the right. The
  former `…` menu is gone: pull to refresh replaces "Atualizar"; "Marcar todas como lidas", "Selecionar sessões" and
  the disabled "Configurações" were dropped (selection now starts from the long-press menu, and a `⋯` with the batch
  actions appears only while selecting); archived sessions moved to the last row of the list. iOS passes no
  settings action (settings stay in Você), so the gear is hidden; the Mac passes one. A soft gradient below the
  header fades rows out as they scroll under the title. At accessibility sizes the title takes its own line below the
  buttons. `-OpenCodeCatalogSettingsButton` (DEBUG catalog only) renders the Mac variant, opening Você.
- **Quota rings:** one ring per `store.quota.providers` entry showing `summary.remaining` (the former bar's value),
  "Codex 42%" and "renova 5,9d" (`SubscriptionFormat.countdown`). The ring uses `primary`, or `warning` when the pool
  is not ready; it opens `SubscriptionDetailSheet`; rings stack at accessibility sizes; VoiceOver reads provider,
  percentage and renewal.
- **Chips:** unchanged. The state filter and the selected chip narrow the rows **before** grouping.
- **Sections** (`SessionSections.group` in OpenCodeKit), each with a dot, its name, its count and a chevron. Collapsed
  sections are saved on the device (`OpenCodeSessionSections`, only choices that differ from the default); empty
  sections are hidden.

  | Order | Section | Rows | Order inside |
  | --- | --- | --- | --- |
  | 1 | Precisa de você (`primary` dot) | permission, question or failure, chats included | permissions, questions, then failures by `time.idle` (newest first) |
  | 2 | Trabalhando (`success`) | running, nothing pending | `SessionList.rows` |
  | 3 | Fixadas (pin icon) | other pinned rows | pin order |
  | 4 | Hoje, Ontem, Esta semana (neutral) | the rest by local day of `interactionAt`; "Esta semana" is 2–6 days ago | `SessionList.rows` |
  | 5 | Anteriores (neutral, collapsed by default) | older than the seven local days (the web's `localDays`) | `SessionList.rows` |

  The discreet **Arquivadas N** row closes the list and opens the archived sheet. A filter (repository, Chats, state)
  or a server without sessions shows no placeholder (29/10): only "Arquivadas N", or nothing without archives. The
  former "Nenhuma sessão" view depended on `loading`, so every reload (one per server event) removed and restored it
  and moved "Arquivadas" with it; only the first load (before any preferences arrive) shows "Carregando sessões…". Since 28 October every section
  mixes chats with repository sessions under "Todas" (before, only "Precisa de você" did); the Chats chip still lists
  only chats.
- **Chat avatar when mixed:** wherever chats sit beside repository sessions ("Todas", a state filter, the session
  switcher) a chat row shows one shared avatar instead of its title monogram: `bubble.left.and.bubble.right.fill`
  (two speech bubbles, a conversation rather than a repository) on the theme role `chatAvatar`, with `chatAvatarSymbol`.
  `generate-themes.ts` derives `chatAvatar` from each theme's `accent` hue at the project avatars' lightness (oklch
  L 0.46 dark, 0.81 light) with more chroma (up to 0.1), so it follows every theme as a category color, and makes the
  symbol legible on it (`check-theme-contrast.ts`, at least 4.5:1). Its second line reads **Chats** where projects read
  `path · branch`. The running arc, `+N`, badges, unread dot and selection circle stay as on any row. Under the Chats
  chip each chat keeps its own avatar and has no second line (`SessionRow.sharesChatAvatar(mixed:)`, environment
  `sessionRowsMixChats`); it is a native symbol, with no generated image per row. The master stays out of the
  rows. The day sections follow the web only for the seven-day window; Alexandre chose four date sections instead
  of one per weekday.
- **Rows:** swipe, long press, avatar, running ring and `+N` are unchanged in every section. "Precisa de você" rows
  have a light tint of their state color and rounded corners, `path · branch`, then a colored state line:
  `pergunta · <question>` (`accent`), `permissão · <preview>` (`warning`, with the compact Negar/Permitir) or
  `erro · <message> · há 12 min` (`error`). Tapping opens the session; "Responder" is gone. The avatar badge uses the
  same colors (shield, question mark, exclamation mark). "Trabalhando" keeps the three-line row with
  `trabalhando · <activity or pensando>`. Pinned, day and older rows are compact: title and time, then
  `path · branch`; unread titles are bold `textStrong` with the orange dot, read titles use `text`.
- **Failure (new state):** a root is failed when `outcome == .failed` and `time.idle > (time.viewed ?? 0)`, while not
  running and with nothing pending; opening it (viewed) or running it again clears it, and a user interruption
  (`interrupted`) is not a failure — the Live Activity contract's "Failed" rule. The message comes from the preview:
  the app now decodes `idle` transcript messages (`TranscriptMessage.idle`), and `SessionPreview.failure` holds
  `error.message` when the latest message is a failed `idle`. Without it the line says `erro · parou com erro`; the
  elapsed time comes from `time.idle`. The "Precisa de você" filter includes failures; the tab badge and chip request
  counts still count only permissions and questions. No server change was needed.

**Reuse on the Mac.** Logic lives in OpenCodeKit (iOS 27 + macOS 15) with Swift Testing coverage
(`SessionSectionsTests`): `SessionList.rows` (failure state and precedence), `SessionSections` (grouping, order, days,
details, elapsed time), `SessionSectionCollapse` and `TranscriptMessage.idle`/`SessionPreview.failure`. The visual
files in `OpenCode/SessionColumn/` import only SwiftUI and OpenCodeKit and use no iOS-only modifier:

| File | Contents |
| --- | --- |
| `SessionColumnHeader.swift` | Title, voice, optional Configurações (`settings: (() -> Void)?`) and Nova sessão |
| `SessionQuotaRings.swift` | The provider rings |
| `SessionChips.swift` | Filter chips (moved unchanged from `SessionsView`) |
| `SessionColumnSections.swift` | Section headers, rows by section, Negar/Permitir, first-load progress and "Arquivadas N"; a `decorate` closure lets the host add platform actions |
| `SessionRowView.swift` | Three-line and compact rows, avatar and running arc |
| `SessionDirectoryLine.swift` | `path · branch` and the shared row clock |

`SessionsView` is the thin iOS host: `NavigationStack`, the header in a `safeAreaBar`, swipe and long-press actions
(through `decorate`), sheets, dialogs and destinations. The Mac host will place the same header in its column with a
settings action, pass its own `open` (selection instead of a push) and its own row actions. These files still depend
on app-target pieces the Mac target must also compile: `SessionStore`, `AppTheme`, `appFont`/`appSymbol`/`AppLayout`
(`AppTypography.swift`, `Theme.swift`) and `ConversationRenameAlert`; `AppTypography.swift` and `Theme.swift` still
contain UIKit code that needs `#if os(iOS)` when the Mac target arrives. The glass header buttons need macOS 26.

Verification: `swift test` in OpenCodeKit; `ScreenCatalogTests/testSections`, `testTabs` and `testSettingsHeader`
(offline catalog, `-OpenCodeCatalogSections`); and, against an owned sandbox, `SessionRowsTests`, `SessionSwipeTests`,
`SessionChipsTests`, `SessionDeletionTests`, the Sessões cases of `SessionReadingTests` and
`MasterSessionTests/testEmptyFirstSendHiddenAndTrashStartsFresh` in both themes. `test-session-rows.py`,
`test-session-reading.py`, `test-session-deletion.py` and `test-master.py` accept `OPENCODE_TEST_SERVER_URL`,
`OPENCODE_TEST_HOME`, `OPENCODE_TEST_DERIVED`, `OPENCODE_TEST_DEVICE` and `OPENCODE_TEST_EVIDENCE` for an isolated
worker. `revealSessionRow` expands a collapsed
"Anteriores" when the row is not visible, and `app.sessionsTitle` replaces the old Sessões navigation bar in tests.

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

The conversation of one session, opened from "Sessões" (row tap). It replaces the provisional session
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
  Each group is a card (see [Shared chat layout](#shared-chat-layout-iphone-and-mac--27-october)) whose header counts
  tool calls, deduplicates titles in first-use order and uses native pt-BR copy:
  `Atividade · Patch, Shell, Ler e Grep · 33 ferramentas · 4m`, `Pensou 4s` for reasoning alone, `Atividade ·
  Raciocínio(s)` when that reasoning has no timestamps, and `Atividade · Atualizações`.
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
  the first step even when tools and subagents precede the final-answer divider, sits right below the bubble (the
  message's 10-point top padding included). `TranscriptViewController.revealTurn` lays that row out invisibly in the
  same pass, finds it by message identity on every pass, animates only the last viewport and saves the position; a
  drag stops it. A pinned bubble already at its
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
- **Tray above the composer:** one card with the running line (`Opus 5.5 · trabalhando · 2m14s`, `Background`,
  `■ Parar`) and one line per queued message (`Na fila: …`, `Editar`, `Enviar agora`, `×`).
- **Composer (V2):** one rounded card with the text at full width (`Pergunte qualquer coisa…` while empty) and, inside
  it below the text, a row with a small outlined `+` (attachments), the model (`Opus 5.5 · xhigh`) in the same subtle
  capsule as the compact `MCP · N/M` pill, a flexible space and a round button:
  microphone when the field is empty (WhatsApp style); with text, send plus a compact microphone at its left
  ([Microphone beside Send](#microphone-beside-send--25-october)). The agent (`build ⌄`) opens the line below the card.
- **Triggers:** `@` context (sessions, apps, agents, references), `&` files, `/` commands, `$` skills, and `#`
  snippets open a suggestion panel above the composer; the chosen item becomes a colored token in the field. Return
  picks the panel's first (highlighted) item (see [Quote comment composer](#quote-comment-composer--24-october) and
  [Files on `&`](#files-on---28-october)).
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
  The "Sessão mestra" bar is hidden inside the conversation.
- **Token colors** come from the theme, never from fixed values: dedicated semantic roles for context mentions,
  agent mentions, commands, skills, and snippets, generated by `script/generate-themes.ts` from the same web tokens the
  web composer uses where they exist (files: `syntax-property`; agents: `syntax-type`; snippets and sessions:
  `v2-text-text-accent`) and, for commands and skills, which the web leaves uncolored, from the theme's `info` and
  `accent` palette colors.

### Shared chat layout (iPhone and Mac) — 27 October

Approved by Alexandre as the chat column shared with the future Mac app, from the mocks in
`.agent-artifacts/mac-app/chat-comum/` of the `mac-app-mocks` worktree (`BRIEFING.md`, `referencia-ios.png`,
`referencia-mac-janela.png`). Only the activity groups, the tray and the composer's chips change; the iPhone header,
the response text, bubbles, footers and every behavior (scroll, reading, pinning, queue, requests, dictation) stay.

- **Activity card:** a rounded `surface` card with a thin `border`, full width, closed on open and while running.
  Its header is the chevron, then `Atividade · <titles> · N ferramentas · <duration>`, where the titles give way
  with an ellipsis so the count and duration stay on one line (accessibility sizes wrap instead). The duration runs
  from the first member's start (`time.ran ?? time.created`) to the last end, `now` while one runs; members
  without timestamps are ignored and, without any, it is omitted. A settled card never ticks; a pending one
  refreshes once a second. Its vertical padding draws into the transcript's row spacing (`padding(-inset)`), so a
  collapsed group is no taller than the old disclosure line: taller collapsed rows made `measure-scroll.py
  paged-up` show uncorrected prepends (below).
- **Timeline:** open, a thin vertical line joins small dots, `primary` when the item completed (a finished call
  without failure, or reasoning that stopped) and gray otherwise. Each item shows a line icon, the tool title, its
  target in monospace (`activityTarget`: command, file name with offset/limit, URL, query, iPhone source, or the
  error) and, at the right, its duration: the members' own run times added together, only when all have ended.
  Grouped reads, `+N −M` file accordions with their diffs, searches, skills, notices, failures (red triangle) and
  reasoning (`brain`, opening its text) keep their content; a subagent keeps its agent chip and the round
  pixel-grid button that opens the child.
- **Tray:** `ConversationRunTray`. The elapsed time is `ConversationProjection.executionStarted`: the first step
  after the latest `idle` boundary, or the first step of a fully loaded history; otherwise (a partial page without
  a boundary, or no step yet) it is omitted. The server has no execution start time; `session.execution.started`
  carries none in its payload and `/api/session/active` only says `running`.
- **Pendente and the queue:** different items. `PendingInputs.steers` lists undelivered `delivery: steer` inbox
  items (they deliver at the next step boundary), and the tray lists `delivery: queue` items; **Mover para a fila**
  turns a bubble into a tray line. The bubble therefore stays in the transcript, unchanged.
- **Composer:** the placeholder `Pergunte qualquer coisa…` (the comment editor keeps its own), and the model in the
  MCP pill's capsule (`composerCapsule()`); the 44-point tap height is unchanged.

**Reuse on the Mac.** Logic lives in OpenCodeKit with Swift Testing coverage (`ConversationActivityHeaderTests`):
`ConversationActivityHeader` (title, deduplicated titles, count, wall-clock span, `Pensou`), `ConversationActivityItem
.completed`/`.duration`, `ConversationPart.activityTarget` and `ConversationProjection.executionStarted`. It replaced
`ConversationProjection.stepLabel` and `ConversationPart.contextSummary`. The views in `OpenCode/ConversationColumn/`
import only SwiftUI and OpenCodeKit and use no iOS-only modifier:

| File | Contents |
| --- | --- |
| `ConversationActivityCard.swift` | The card and its header; the host owns expansion and draws the items |
| `ConversationTimeline.swift` | Line, dots (`ConversationTimelineRow`) and the item line (`ConversationTimelineLabel`) |
| `ConversationRunTray.swift` | Running line and queue lines, from plain values and closures |
| `ComposerChips.swift` | `composerCapsule()` and `ComposerModelChip` |
| `ConversationTitle.swift` | `ConversationAvatar` (context ring), `ConversationTitle` and the Mac's `ConversationTitleBar` |

The iPhone hosts stay where they were: `ConversationStep` (`ConversationComponents.swift`) maps the store's state
onto the card and items, `ConversationActivityItemView` draws reads/searches/skills/files, `ConversationTray`
(`ConversationRequests.swift`) adapts the store to the tray, and `ComposerEditor` keeps the editor. `ConversationView`'s
header now composes `ConversationAvatar` and `ConversationTitle`; captures before and after are pixel-identical apart
from the animated agents grid. The Mac title bar (avatar, title, `<worktree> · trabalhando…`, `…`, primary `+`) is
`ConversationTitleBar`, rendered by the DEBUG `-OpenCodeConversationTitleFixture` (`ScreenCatalogTests
/testConversationTitleBar`).

The Mac replaced the iOS-only parts (response text, composer editor, scroll owner and transcript list) with AppKit
counterparts on the same models; see [Chat (polish 1)](#chat-polish-1--27-october).

Verification: `swift test`; `ScreenCatalogTests/testActivity` (offline `-OpenCodeCatalogActivity`, both themes;
`OPENCODE_CATALOG_ACCESSIBILITY=1` adds a capture for accessibility sizes) and `testConversationTitleBar`; and, on an
owned sandbox, `test-groups.py` (which now accepts `OPENCODE_TEST_SERVER_URL`/`OPENCODE_TEST_HOME` and runs
`ToolGroupingTests` alone without the conversation seed), `test-pending.py`, `test-subagents-alerts.py`, and the
MCP, dictation and composer suites through `test-isolated.py`. `measure-scroll.py`, base `2fe84bbaa7` against this
change on an iPhone 17 Pro simulator (Debug `-O`, medians of three alternating runs; frames / p95 / main-thread CPU):

| Scenario | Before | After |
| --- | ---: | ---: |
| `read` | 707 / 16.7 ms / 2.08 s | 706 / 16.7 ms / 2.14 s |
| `history-up` | 703 / 16.7 ms / 2.40 s | 701 / 16.7 ms / 2.39 s |
| `stream-reading` | 704 / 16.7 ms / 4.61 s | 701 / 16.7 ms / 4.68 s |
| `stream-follow` | 622 / 36.3 ms / 6.49 s | 619 / 33.4 ms / 6.43 s |
| `paged-up` (replaced frames) | 694 / 16.7 ms / 1.60 s (0) | 695 / 16.7 ms / 1.55 s (0) |

With the card's 11-point header padding inside the row, `paged-up` had uncorrected prepends (replaced frames 1–4 and
2,100-point jumps in most runs); drawing the padding into the row spacing removed them (0 in 8 runs).

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

**Alexandre, 26/10: citações no servidor.** With `custom.quotes` (`packages/plugin-app-custom/docs/quotes.md`, the
contract the web follows too), the pending quotes of a Session and the hidden marks live on the server, shared with
the web. `QuoteSync` (one per conversation, `OpenCode/QuoteSync.swift`) probes `info` when a conversation opens,
after every SSE reconnect and on foreground: `rpc.unavailable`/`rpc.method_not_found` keep today's local storage
untouched; network, 401 and 5xx keep the current mode and delete nothing. In server mode `draft.quotes` mirrors
`list` (reloaded on `rpc.custom.quotes.updated` for this Session only and newer revision, never a transcript refresh),
`draft.json` keeps only the rest of the draft, and Concluir uploads new attachments (content-addressed IDs) before
`save`; an empty comment without attachments is removed, like the web. Trash calls `remove`; a send clears exactly
the sent IDs with `reason: "sent"` after admission (a failed clear is retried and hidden meanwhile). Comment bytes
are fetched with `attachment` before an editor or a send reads them and cached by ID. Listings older than this
device's last write, or arriving while a send or a write is in flight, wait for the next one. Undo restores quotes
as new quotes with new IDs that replace the pending ones (sent IDs are tombstoned); an edited queued prompt shows
its quotes as an unpublished local preview, as on the web. Each Session migrates once: local attachments are
uploaded, quotes imported with their IDs, `QuoteMarks` dismissed, and only then removed locally (idempotent).
Selections add `prefix`/`suffix` (64 characters of the block's rendered text); web `rendered` anchors whose offsets
fail resolve by whitespace-insensitive text search with that context, and older web anchors without it stay unmarked.
`script/test-quotes.py` covers both modes (`--quotes-unavailable` for a server without the RPC) and
`OpenCodeUITests/QuoteServerTests` the shared cases.

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
(label **Comentário**, identifier `comment-composer`), `@`/`&`/`$`/`#` suggestions and tokens, focus, dictation (hold, lock,
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
hardware keyboard picks the suggestion panel's first, highlighted item for `@`, `&`, `$`, `#` and `/` exactly as a tap
does, instead of a line break. `ComposerSuggestions` records that item in a non-observed `ComposerSuggestionReturn`
once its results for the current trigger have loaded, so typing still does not re-render the composer.
`ComposerReturn.selectsSuggestion` gates it: no marked text (composition keeps Return), panel open, and an item loaded
for the trigger still being typed. With no panel, or while it is loading (the 180 ms debounce plus the request) or empty,
Return keeps its previous meaning (line break; Shift+Return still sends). The web
(`app-custom/src/composer/suggestions/machine.ts`) selects its active item on Enter/Tab too, but swallows Enter while its
list is empty or loading; iOS deliberately keeps the line break there. Dictation inserts through the draft, not Return,
and is unaffected. Covered by the Kit truth table, `ComposerEditingUITests/testReturnPicksTheLoadedFirstSuggestionAndOtherwiseBreaksTheLine`
(`$` picked, line break without a panel, empty `#` list and an unloaded `&` query) and the comment/message checks in
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
diacritic-insensitive folding; files (`&`) come from `/api/fs/find`, whose fuzzy search ignores case too. Session titles
are searched by the server with SQLite `LIKE`, which ignores case only for ASCII letters, so a query with other
cased letters (Ã, Í, Ç…) is also sent lowered, uppercased and capitalized (`ComposerSources.caseVariants`) and the
results are merged by recency; accents are still matched as typed there ("sessao" does not find "Sessão"). The web
composer does the same in `composer/session-search.ts`.

After `build-for-testing`, `script/test-composer-case.py` (same environment variables as `test-app-mentions.py`)
creates a fake repository, two disposable Sessions and one snippet, runs `ComposerCaseUITests` (`&`, `@`, `$`, `#`,
`/` in several cases, then Return on `#COMMIT`) and removes them.

### Files on `&` — 28 October

**Alexandre, 26/10: arquivos saem do `@`; 28/10: o gatilho de arquivos passa de `!` para `&`.** `@` keeps sessions,
apps, agents and references and does not list files or call `/api/fs/find`. `&` lists only files, with the same
panel, icons, path styling, ranking and 20-result server search the `@` file section had. Choosing a file inserts the
same `@path` token as before (`ComposerTokenKind.file`, absolute `value`), so the sent prompt is unchanged: `@path` in
the text, and a `files:[{uri:"file:///…", mention}]` entry with the same UTF-16 range. `!` is plain text again.

`&` opens the panel only at the start of the text or right after whitespace or a line break (including a paste or a
restored draft that puts the caret there). Glued to a letter, digit, punctuation, a bracket or quote, an emoji or a
token, it is prose: `R&D`, `P&G`, `AT&T`, `?a=1&b=2`, `texto&amp;`, `👍&` and dictation never open anything. `&&` and
`&=` stay prose too, so `a && b` does not open a list. A lone `&` followed by a space (`Tom & Jerry`, `arroz & feijão`)
behaves like a lone `@`: the space ends the query, so the panel closes without inserting anything and the text stays
as typed. Typed continuously, the 180 ms debounce means the list never even appears; after a pause it shows briefly
and closes on the space. Space, Escape and a tap outside dismiss it as for `@`.

The iOS app has no shell mode, and `&` has no other meaning in the composer. The trigger lives in OpenCodeKit's
`ComposerTrigger`/`ComposerSources`, which only this app uses; the web, TUI and server are unchanged. A typed but
unchosen `&text` is sent as plain text.

`ComposerEditingUITests/testAmpersandListsFilesAndAtDoesNot` (fixture) and
`ComposerCaseUITests/testAmpersandSendsTheFileReferenceAtNoLongerLists` (live; `test-composer-case.py` then checks the
sent message's `file://…/README.md` reference, mention range and text on the server) cover it in both themes.

### Pasted images — 28 October

**Alexandre, 28/10: colar uma imagem no compositor vira anexo.** The keyboard's "Foto · Colar de …" suggestion,
**Colar** in the edit menu and ⌘V all call the editor's `paste(_:)`, which only read the composer's own token format
and plain text, so an image did nothing; the plain-text view also did not offer Colar for an image or accept a dropped
one. `ComposerInputView` now sends image items to `ConversationStore.importImages`, the "+" menu's
`importAttachment` path (25 MiB draft limit, HEIC/oversize conversion, thumbnail chip, removal, saved draft), named
`Imagem-XXXXXX.<ext>`. Several images become several attachments. Text and images together: each pasteboard item is
classified, image items are attached and the other items' text is inserted (undoable, and it still opens `&`/`@`
triggers). An image never enters the text: no `U+FFFC`/glyph from paste, `paste(itemProviders:)`, drops (the
`UITextPasteDelegate` answers `setNoResult()` for images) or `insertAttributedText` (image attachments are imported,
the text is kept). The paste configuration adds `public.image` to the defaults so Colar and drops accept images.

It applies to every `ComposerEditor`: the conversation (roots, children and chats), **Nova sessão**, the master
session and the quote comment sheet (whose attachments travel with the comment). Editors without attachments (the
`/btw` side question, the composer fixture) keep ignoring images.

`ComposerEditingTests` covers menu/⌘V paste with text and several images, undo, item providers, the drop delegate,
rich insertions and the import flow. After `build-for-testing`, `script/test-paste-image.py` (same environment as
`test-composer-case.py`) runs `ComposerPasteImageUITests` against an owned conversation: Colar with two images, ⌘V
with one more and a real send, the comment sheet, and the keyboard suggestion, which the simulator offers after the
test runner copies an image (its bar is outside the app's accessibility tree, so the test taps above the keys). The
script then checks the sent messages' image parts on the server.

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
jump. Without anything new below, ↓ follows `app-custom/src/session/timeline/interaction.ts`: it shows only at a
distance from the end **strictly greater than `max(400 pt, viewport height)`**, independent of author, tool-only
steps, watermark and parent/child status. **Since 27 October** it also shows as soon as content was added below the
end the reader last saw (an answer growing, messages arriving, even while the app was hidden), from 24 points:
growth never scrolls the transcript, so ↓ is how the reader learns of it. "Added" is judged by what the store
publishes (its revision and pending prompts), never by measured height.

Tapping **Ir para a mais recente** scrolls to the end once; nothing follows later growth. Sending a prompt moves the
prompt to the top of the transcript instead (see *Transcript architecture*). Dismissal is purely geometric, so
scrolling up can show the button again without new messages. Per-session native reading persistence and
parent/child return behavior remain independent of read receipts.

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
Hidden history starts at the boundary in server order (the loaded list), not by comparing message IDs:
builds before 26/10 sent `msg_` + uppercase UUID IDs, which sort after the reply, so the reply stayed visible.
New prompts use the server/web ascending `SessionMessage.ID` shape, and pending bubbles are never hidden by a
boundary (a reset cancels earlier pending input; a new prompt commits the boundary first). The progress row covers descendant planning, Session rollback and pending-inbox cleanup. A partial child failure is
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
The older working fixture expects `Atividade · Ler, Agente e Editar · 5 ferramentas` and a compact `Ler infra.md` row; continuity verifies
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
markers; disabled task checkboxes and nested quote borders retain their state/depth. Inline HTML pairs of `<sub>`
and `<small>` (smaller secondary text, like a sources note, not a tiny subscript), `<sup>`, `<kbd>`/`<code>` (inline
code), `<b>`/`<strong>`, `<i>`/`<em>`, `<u>`/`<ins>`, `<s>`/`<del>`/`<strike>` and `<br>` style their content without
showing the tags; copying, selection mapping and read-aloud see only the content. Other tags, a known tag without its
closing sibling, HTML blocks, emoji shortcodes, `==highlight==` and GitHub-alert markers remain literal, so no content
is hidden; the previously approved native HTML-image loader is preserved.

**Dollar math (Alexandre, 26/10):** `$…$` follows the custom web's Pandoc boundaries
(`packages/ui-custom/src/context/marked-parser.tsx`): the opening `$` is followed by a non-space, the closing `$`
follows a non-space and precedes no letter, digit or underscore, and the body has no unescaped `$`. In addition, a `$`
glued to a preceding Latin letter (`R$`, `US$`) never opens a formula. Inline math never spans a line break or a table
cell (unescaped `|` outside code); `$$…$$` inside a cell stays inline so the table remains one block. `\$` is a literal
`$`, and the existing currency guard (`$100$`) still applies. So `R$ 30.982,69 | **Prejuízo de R$ 28.534,69**`,
`$5 e $10` and `$HOME/$USER` stay text, while `$x^2$`, `$$…$$`, `\(…\)` and `\[…\]` still render.

Tables are native, horizontally scrollable grids with header styling, column alignment, wrapping, per-cell selection,
CSV/TSV/Markdown copy and CSV/Markdown export through Files. With wrapping on, `MarkdownTable.columnWidths` gives each
column at least its longest word (up to 240 pt, so a URL may still break) and water-fills the remaining width: words
and numbers break only between words, and when the minimums exceed the screen the table scrolls horizontally from its
leading edge. The grid lines are layers of a content subview, so they scroll with the cells; the rounded outer border
belongs to the viewport and stays fixed. Short inline code in prose (up to half a line) never breaks inside, so `/proventos` or `--all-pages`
moves to the next line whole; table cells and longer spans wrap as before. Code cards retain one selectable TextKit 2 text view,
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
transport refuses every HTTP request. `-OpenCodeMarkdownFixtureDocument markdown-currency-fixture` swaps in a
synthetic financial answer (`R$` values in center/right-aligned columns, bold results, inline and display math, a
`<sub>` sources note and the inline tags), checked by `OpenCodeUITests/MarkdownRenderingTests/testCurrencyTableAndInlineHTML{Dark,Light}`.
Release excludes both the fixture mode and its Markdown resources.
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

#### Folder links — 26 October

- Inline code and explicit Markdown links naming a **local folder** (relative to the Session directory, absolute or
  `~`, with or without a trailing `/`) open the file explorer listing it, with `../`, search, working-copy markers
  and files opening in the viewer over it. `fileLinkTarget` lists the parent to confirm the exact folder, then, for
  relative paths, accepts one unique folder ending with the path (as files are matched); ambiguous or missing
  folders stay plain text, files keep opening the viewer. The result is cached for 60 s like file existence.
- GitHub links keep their web destination even when their label is a local path; nothing is opened locally from them.

#### HTML preview — 26 October

- `.html`/`.htm` (`FileViewerKind.html`) open in a `WKWebView` preview like the web app's sandboxed iframe: scripts
  and the network work, files next to the page do not load (no base URL). The `</>` button switches to the code
  (plain text up to 2 MiB, Quick Look above). Downloads over **25 MB** ask first. Read-aloud stays Markdown-only.
- Isolation: a non-persistent data store, no script message handlers or user scripts, `loadHTMLString(_, baseURL:
  nil)` (never `loadFileURL`, so other previews in the temporary folder are unreachable), every HTTP authentication
  challenge refused, link previews off. `HTMLPreviewPolicy` allows only the document itself (and its anchors);
  a link opens in Safari only when the person touched the page in the last 1.5 s, so `location =`, script clicks,
  form posts and `window.open` go nowhere. A crashed web content process shows **Tentar novamente**.
- The app's server credential is an `Authorization` header on its own `URLSession`, never in shared credential
  storage, so WebKit has nothing to send; the UI test's local probe answers 401 Basic and records no credential.

#### HTML with local files — 27 October

- Every opened HTML file starts in **local files** mode: it is served as `opencode-preview://<token>/<path>` by
  `HTMLAssetHandler`, so images (also `srcset` and lazy ones), stylesheets with `url()` and fonts, classic scripts
  and ES modules next to it load. `HTMLPreviewScope` allows the page's folder and subfolders, plus the Session
  directory when the page is inside it; each read uses that root as Location, so the server also refuses `..` and
  symlinks leaving it. Resources are read whole (25 MB each), cached while the page is open and cancelled with
  it. Video and audio with byte ranges are not served.
- The network is blocked twice: a content rule list (`http(s)`, `ws(s)`, `ftp`) and a response CSP (`connect-src`
  and frames on the page's own origin, `form-action 'none'`); WebRTC constructors are removed. A tapped link to
  another HTML page of the scope opens inside the preview with a back button; script navigation, frames from
  elsewhere and pages outside the scope are refused; links to the web still open in Safari after a touch.
- **Permitir internet** in the mode bar reloads the page alone with the network (the previous mode, without local
  files); **Usar arquivos locais** returns. The choice is not remembered between files.

#### Links after navigating — 29 October

- The transcript view is retained with the conversation, but the conversation screen and its `FileViewerHost`
  are rebuilt after navigating (Sessões, another session, Você). `FileOpenAction`/`ImageOpenAction` compared equal
  for every value, so the retained cells kept the previous host's action, whose viewer state no longer existed:
  links stopped opening until a relaunch. The actions now compare by their host (`owner`), and native text cells
  call the action through the transcript context at tap time. `testLinksKeepOpeningAfterLeavingAndReturning`
  covers file, folder and image links after a round trip through Sessões, another session and Você.

#### Viewer arrows and video audio — 29 October

- Paging is the horizontal swipe. A 20-pt translucent chevron in a lower corner (`FileSiblings.arrows`) only hints
  that a sibling exists on that side, for every file kind; it takes no touches. It sits above each kind's bottom
  controls (the player's timeline, the HTML mode bar, the read-aloud controls), since AVKit has no public signal
  to hide it with its controls. VoiceOver can activate it, and the viewer has "Arquivo anterior/Próximo arquivo"
  actions.
- A video **without an audio track** (`VideoAudioPolicy`) sets the session to `.ambient` + `.mixWithOthers` before
  AVPlayer activates it, so other apps keep playing; leaving restores the previous category and deactivates with
  `.notifyOthersOnDeactivation`. A video with an audio track, even a silent one, keeps the normal player
  behaviour. During a voice call or a reading the session is not touched.

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

**Alexandre, 28/10: arrastar o microfone dentro da folha.** A touch that begins on either microphone belongs to it:
`VoiceRecordingTouchTarget` adds a recognizer that recognizes at touch down, ends with the touch, never cancels or
delays the view's own touches, and every other recognizer must wait for it to fail. The comment sheet's presentation
pan and its scroll view therefore can no longer take the upward lock drag (which moved the sheet and cancelled the
touch, leaving a paused draft); away from the microphone the sheet drags and closes as before. The comment sheet is
the only sheet with this microphone (Nova sessão and the master are pushed, the fullscreen composer is a cover and
the side question has none); the conversation composer behaves as before.
`DictationUITests/testCommentSheetMicrophoneDragUpLocksWithoutMovingTheSheet` covers both microphones and a drag
elsewhere; the offline dictation fixture now accepts any isolated loopback sandbox port.

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
master during physical audio checks. Both require an explicit loopback sandbox URL (any port but 4096/4178).
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

On Sessões the voice surface stacks above the master accessory (**Alexandre, 25/10**): voice bar, then the still
tappable "Sessão mestra" bar above the home indicator (the tab bar is gone since 28/10; Você, a sheet, keeps the
voice bar). The accessory keeps its
place when a call starts or ends. The voice bar's safe-area inset sits inside the accessory's own inset and
reserves the whole expanded height, so the last list row remains reachable above both. In a conversation it is
a sibling immediately above the composer, including with the keyboard open. It starts compact; tap the
summary to expand, tap again or swipe down inside the bar to collapse. The microphone and end controls
stay in the same header row. VoiceOver exposes one element with its state/duration and named actions.
Reduce Motion stops the waveform; long lines truncate and large Dynamic Type keeps the controls reachable.

The independent DEBUG-only `-OpenCodeVoiceBarFixture <state>` requires explicit
`-OpenCodeServerURL` on a loopback sandbox (any port but 4096/4178, `ServerConfiguration.isolatedTestSandbox`; the old
4177/4180/4183 allowlist hid the bar on agents' own sandbox ports, so `FloatingVoiceBarTests` never saw it). States: `listening`, `speaking`, `thinking`, `connecting`,
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
`ConversationProjection.work` lists **every** direct subagent of the owner, running or finished, plus background
shells. **Order (27 October):** running and starting work first, by its latest start (a child continued through a
`subagent` call with its `sessionID` counts from that call), then finished work by the last time it ran (`idle`),
newest first, ties by ID. The first version (`303d929b27a`) ordered everything by first start with running work not
promoted, as then requested; a background subagent started an hour earlier and still running sat below ~30 newer,
finished ones (session "Live activity"). Scripts follow the same rule (running first, then by completion). A running
row's elapsed time counts from its latest call, so a long background child no longer shows the age of the shell it
happens to run. The screen applies a new order only while the list is idle (`onScrollPhaseChange`), with a 0.25 s
snappy animation (none with Reduzir Movimento), so a row never moves under a finger; the header count is unchanged. Each
row has the same layout: agent, task title, state (Em execução with elapsed time, Concluído, Erro, Interrompido or
Encerrado with duration), chevron and child context/cache line. Only running rows show the stop button (and swipe/menu
stop); the column stays reserved so rows line up. State comes from `/session/active` first, then the child's
`outcome`, then its `subagent` tool status. The header button appears whenever the list has an entry: green with the
running count while something runs, neutral without a number otherwise.

**Agent and model (28 October).** Each subagent row shows its agent and, beside it, the model and effort it runs
with (`Luna 6 · low`). Both follow the child session, not the first call: a continuation (same `sessionID`) that
changes `agent` or `model` makes the server switch the child (`switchAgent`/`switchModel`) before prompting it, and
the family page carries `Session.agent`/`Session.model`. `ConversationProjection.effectiveModel` shows that selection;
the last measured step (`context.model`, what really ran) only differs until the continuation's first answer, when
the selection is exactly what that answer uses, so the row shows the requested model during the interval and the one
that ran afterwards. The call's own `model` input fills in for a child without a selection, and a call the model is
still writing shows the `model` already complete in its partial input. The family page reloads on the child's
structural events, not on streaming deltas, so the row updates live while the screen is open. Verify with
`script/test-agents-screen.py --scenario model` (`testContinuedSubagentShowsItsLatestModelLive`): a General child runs
once with Luna 6 / low, then the parent continues it with Luna 6 - fast / low while the screen is open.

One row is one child session. A `subagent` call's child ID reaches its part only through ephemeral
`session.tool.progress` and the final result, so a reloaded **running** call has `metadata: {}`. Production showed
such a call as a second "Em execução" row without context that opened the root. `ConversationProjection.subagentLinks`
now links calls to children: the part's `sessionID`, a continuation's `input.sessionID`, or else the first unclaimed
child of the owner with the same agent created within 5 s before to 60 s after the call ran. A linked call only feeds
its child's row (the running call's start is that row's elapsed time); the transcript's subagent card opens the same
child. A running call with no child yet is shown as **Iniciando**, without chevron, stop or navigation, and only while
the owner is active; stale running parts and failed calls without a child stay in the transcript only. The header
count uses the same deduplicated rows; the "Respondeu · N agentes rodando" banner already counts active sessions.

**Tabs (26 October).** A native segmented `Picker` below the title splits the screen into **Agentes (N)** and
**Scripts (N)**; it always opens on Agentes (not remembered). `SessionWork.kind` separates them in
`ConversationProjection.work`, keeping the newest-start-first order in each tab. **Agentes** lists every subagent
session, including `background=true` ones, with resources nested per agent and **Esta sessão** above, as before.
**Scripts** lists background shells: every completed `shell` call whose result moved it to the background
(`metadata.status == "running"` with a `shellID`, from `background: true` or the Background action), plus any running
shell of the owner no foreground call waits on. Their state comes from `/api/shell` (running, exited 0 → Concluído,
non-zero exit or timeout → Erro, killed → Interrompido, unknown → Encerrado) with duration; rows show the command,
stop while running and reveal the tool when tapped. An empty tab says so. A subagent call the model is still writing
(`streaming`, partial JSON input) is an agent **Iniciando** row: its already complete `agent`/`description` fields are
read from the partial JSON, otherwise "Subagente · Preparando subagente…". Before, such a row had no agent and the
view rendered agent-less rows as "Shell em background", which is what production showed. The header pill keeps one
running number for agents plus scripts (both are work still running that this screen lists and can stop), the
devices count beside it, and an accessibility label such as "3 agentes e 1 script em execução".

Opening a child pushes it above the list, so Back returns to the list and then to the conversation; **Voltar à sessão
principal** returns straight to the parent conversation, skipping its agents screen. A shell row without a child pops
back and reveals its tool. No other screen had an agent list (Detalhes da sessão shows only the descendants' cost),
so there is a single list component. Verify after `build-for-testing` with
`python3 packages/ios-custom/script/test-agents-screen.py --device … --derived … --home <sandbox> --server-url … --evidence …`
(optionally `--theme openchamber-light`): it imports a parent with succeeded, failed and interrupted children plus one
child made running by a Luna 6 / low `sleep`, has the parent start a background subagent, a background `sleep 301`
script and a foreground delegation, runs `OpenCodeUITests/ConversationAgentsTests`, then interrupts, stops the script
and deletes the family.

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
used) above **Subagentes**, where each subagent row carries its resources on a tree line; a subagent without resources shows nothing below
its row (the former **Sem recursos** line was removed on 26 October), and **Esta sessão** only appears with resources. Rows
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
written by hand: `script/generate-themes.ts` runs the resolver in `script/theme` (moved there from the former custom
web app's `packages/ui-custom/src/theme`) over the theme JSON files in `script/theme/themes` and writes the resolved
tokens, which the app bundles. Adding a theme means running the script. Você → Aparência lists the 38 generated families with previews,
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

## Troca rápida de sessão

In a root conversation, the header's avatar and title (with a small `⌄`) open **Sessões**, a native large sheet
(VoiceOver: **Trocar de sessão**, a clear button over the avatar and title so their readouts stay). The large height
leaves room for the same `SessionColumnHeader`, `SessionChips`, `SessionColumnSections` and rows as the main tab:
attention, running, pinned and local date sections, their counts, project icons and inline permission actions. The
Arquivadas link appears only outside search when there are archived sessions. The sheet starts on **Todas**, or
**Chats** for a chat. As on the tab, Todas mixes chats and repository sessions in the same groups; a repository
chip excludes chats and the Chats chip keeps only chats. Mixed lists use the shared chat avatar and the "Chats"
second line, while the Chats filter retains each chat's own avatar. The bell means **Avisar ao terminar**.

Filters and section collapse are local to each presentation: choosing a chip never changes the tab behind the
conversation. Project order, badges and preference edits are shared. The current session stays marked with ✓ but
is not a scroll destination: the sheet always opens at the top, including after closing it while scrolled or
filtered. The header, chips, search and first section are immediately visible; background updates never recenter
it. Search is local over title, project, branch and path and combines
with the selected chip; a filter change starts its results at the top without recreating the List.

The orange **+** stays in the header. It opens Nova sessão using the sheet's chip through the existing
`NewSessionProjection.start` rules (including restored work), without changing the tab's filter or inheriting the
current conversation's checkout. The conversation's … menu still inherits its origin as before. Choosing a session
replaces the route only after the sheet dismisses (Back still returns to Sessões, and both transcripts retain their
passages); choosing the current one only closes.

Both vertical Lists use `SessionListPresentation` and the Kit's `SessionListOrder`: only row IDs and section placement
wait during dragging/deceleration, then apply on `.idle` without a structural animation. Data, badges, counts and
actions remain live; actual removals are discarded immediately. The main tab's "Selecionar todas" uses exactly
these presented, expanded groups. No custom layout, scroll correction loop or retained list controller is used.
Only visible running/failed rows request transcript previews. Permission/question descriptions come from their
existing request data, and queued/dirty preview work is dropped when a row leaves the screen.
Before, tapping the avatar opened Detalhes da sessão; on root conversations Detalhes stays in the … menu and the
context footer (the avatar's VoiceOver element still opens it). Children and the master keep the avatar's Detalhes and
have no switcher: a child returns to its parent, and the master is reached only through its accessory.
`SessionSwitcherTests` cover opening/reopening at the top, chips, grouping, combined search, creation, switching and a completion during a held
gesture; `SessionListsTests` cover the same transition on Sessões and the return and Você open/close check. The offline
catalog with `-OpenCodeSessionListUpdates` completes one running session 350 ms into a drag and samples row positions
once before/after that update. Kit tests cover deferred placement, live data, deletion and displayed selection IDs.
Returning from a conversation previously shifted the bottom-aligned List by 105 pt, also reproduced on `fc6c27d`: hiding the tab
bar/accessory expanded the covered List and clamped its position. Sessões now remembers the tapped row's identity
and relative alignment, then makes one native `ScrollViewReader` request once the normal viewport returns; it is
kept now that the tab bar is gone (28 October), since any covered viewport change would clamp the same way. The
return and Você open/close assertions are ordinary passing tests. No device performance matrix was needed.

## Nova sessão (wave 9)

The orange **+** in Sessões pushes a local draft, not a server Session. The "Sessão mestra" bar is
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

- **Project:** `NewSessionProjection.start` decides. The conversation menu's Nova sessão inherits its origin (Chats
  for a chat). From Sessões, a selected repository chip preselects that project, with its last-used destination
  category (root, or Nova worktree when that project's last send used a worktree), even over a restored draft of
  another project; this preselection updates the remembered `lastProject` only when the session is sent (an explicit
  Projeto choice still touches it immediately). The Chats chip preselects Chats. With "Todas", the `+` starts in
  **Chats** unless the restored new-session draft is project work in progress (text or attachments); a restored chat
  stays a chat. Without the `+` (fixtures), the restored draft keeps its project, then
  `custom.preferences.data.projects["local"].lastProject`, then the first selected project. The Projeto sheet lists **Chats** first (when the server
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
"chat"), sends a Luna 6/low prompt, checks "Todas" lists a chat row (its second line reads "Chats") and the Chats chip lists
the new row and preselects Chats. Its second case checks the `+` per chip (repository → that project, Chats → Chats, Todas → Chats or restored
project work), switching projects and Chats in the selector, and an emptied draft. Run it against an isolated sandbox
with two selected projects (`OPENCODE_TEST_CHATS_PROJECT`, default `demo`, and `OPENCODE_TEST_CHATS_OTHER_PROJECT`)
and an empty or chat new-session draft; it creates one real chat per run. `script/test-new-session.py` accepts
`OPENCODE_TEST_SERVER_URL`, `OPENCODE_TEST_HOME`, `OPENCODE_TEST_DERIVED`, `OPENCODE_TEST_SIMULATOR` and
`OPENCODE_TEST_EVIDENCE` to run `NewSessionTests` against another isolated sandbox and simulator (`OPENCODE_TEST_SIMULATOR`
takes a name or a UDID; a fresh simulator without the app has no draft to clear).

`NewSessionView`/`NewSessionStore` own presentation and navigation; selectors live in `NewSessionSelectors.swift`.
`OpenCodeKit/NewSession.swift` owns projections and the narrow typed HTTP contracts, and
`NewSessionSubmission.swift` owns the fake-client-testable ordered pipeline and phase-specific failures. The existing
`ConversationStore` exposes a draft-only Location mode for the shared composer; no provisional server Session or
separate composer copy is created.

### Sandbox verification

After the simulator `build-for-testing`, run `python3 packages/ios-custom/script/test-new-session.py` and repeat with
`OPENCODE_TEST_THEME=openchamber-light`. Every app launch/relaunch supplies the explicit sandbox URL/password. The
runner checks entry with/without a repository filter, project/add-picker switching, root/existing/new directories,
live/preview toggles of only one MCP, base-branch selection, keyboard/layout, route replacement and persistent
draft restoration. An invalid base is injected **only into the stopped simulator app's own draft**, without changing
Git refs or adding a production test hook. Root/existing/new sends use Luna 6/low/build and tiny no-tool prompts.
That MCP is `OPENCODE_TEST_NEW_SESSION_MCP` (default `codex-computer-use`; `safari-devtools` left the configuration on
19 October): the live toggle goes there and back from whatever state it starts in, and the runner restores it on the
root checkout if a case fails midway. Screenshots and JSON evidence go to
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

**Trajectories (27 October).** Those scenarios measured where scrolling ended, not what the reader saw on the way.
`-OpenCodeTrajectory` records the rows on screen (pinned prompts excluded) once per displayed frame, from an event until
the transcript has been still for 1.5 s: the cold opening, `-OpenCodeFixtureReentry pop` (leave the conversation and
open it again, three times), `-OpenCodeFixtureReentry child` (cover it with another screen and come back) and a return
from the background, during which `-OpenCodeFixtureBackgroundArrivals` delivers a prompt and its answer. Each episode
reports `wrongFrames` (frames with content showing another passage than the final one), `exitWrongFrames` (than the
passage shown when leaving), `firstExitDeviation`/`finalExitDeviation` (points; −1 when no row is shared, that is,
another passage), `blankFrames` and the settle time, in `Documents/transcript-trajectory.json`. `measure-scroll.py`
runs them as `open-middle`, `open-tail`, `reentry-middle`, `reentry-tail`, `child-middle`, `background-middle` and
`background-tail` (the app is hidden behind Settings for three seconds, with `simctl` or `devicectl`). The driver no
longer excludes the row whose height changed, the response the reader watches grow: `growingShiftMaxPoints` is that
row's largest per-frame movement, and `textViewsCreated`/`textViewsDestroyed`/`textReplacements` count response text
views and whole-text replacements in the measured window. `stream-still` streams while the reader holds still mid-history.

### Transcript architecture — 27 October

The transcript is a UIKit `UICollectionView` (`OpenCode/Transcript/`), not inverted, with its own layout. Header,
composer, sheets and overlays stay SwiftUI; `TranscriptHost` mounts the view controller.

- **Items.** `TranscriptProjection` splits each message at semantic blocks: a run of prose is one native
  `ResponseTextView` (selection crosses its paragraphs), while code, tables, media, formulas, activity steps, notices,
  footers, day chips, prompts and request cards are separate items hosted with `UIHostingConfiguration`. An item's kind
  carries everything its height depends on (expansion included), so equal kinds share a cached height
  (`TranscriptHeights`, by item, content, width and text size).
  A rebuilt native table restores its `TranscriptMemory.tableOffset` only after its content width is measured;
  the grid is part of that same scrolling content, so separators stay aligned with cells.
- **Shared conversation chrome.** Activity cells render `ConversationStep` through the shared
  `ConversationActivityCard` and `ConversationTimeline`; the run tray, composer chips and header use the same
  `ConversationColumn` components as `custom`. Output remains in per-key `TranscriptMemory`, and the height key
  includes group, tool detail, filename and file-diff disclosures so returning to an expanded card stays correct.
- **Layout.** `TranscriptLayout` positions items from cached or estimated heights (`TranscriptGeometry` in the Kit,
  unit-tested) and pins the current turn's prompt under the header, with a fade once content passes under it.
- **Anchoring, in the same pass.** The reader's place is an item under the reading line (below the pinned prompt) and
  its screen position. A cell that self-sizes above it moves the content offset by the same amount through its
  invalidation context; an unmeasured cell entering above everything on screen keeps what follows it still; data
  updates restore the anchor from `targetContentOffset` (an item replaced, say a placeholder by its parsed blocks,
  continues in what replaced it). Nothing corrects the offset afterwards: no display links, no timers, no loops.
- **Growth never scrolls.** Not even at the end. When content shrinks below what the reader last saw, the content
  size keeps that bottom scrollable until the next drag, so the offset is never clamped.
- **Sending works like ChatGPT and Claude.** The sent prompt rises to the top of the transcript (a short animation,
  instant with Reduce Motion); a trailing space lets it get there and shrinks as the answer grows below it.
- **Explicit navigation** (↓, search, quotes, tools, a pinned prompt's tap, read aloud) lays the destination out
  invisibly in the same pass, parsing its Markdown on the spot, and animates only the last viewport, so it lands
  exactly. Targets are resolved by message and prompt identity on every pass.
- **Retention.** The view controller is kept with its conversation (`TranscriptMemory.controller`): returning
  remounts the very view that was left, so its first frame is the last one shown. The same conversation mounted twice
  (a parent reopened from its child) gets a second view from the same store and memory.
- **Header switcher.** Choosing a session captures the source passage after dismissing the sheet and replaces the
  route. The destination uses its registry entry and retained controller, or its normal positioned opening on first
  visit. Switching A → B → A preserves both passages; Back still returns to Sessões. Successful archive (single or
  bulk) and deletion evict the affected retained family, while failed operations keep it. Archive preserves disk
  reading positions and drafts.
- **Opening.** The view stays hidden until it is laid out at the saved place, so the first visible frame is the final
  one; Markdown near the place is parsed synchronously first. A failed load or an empty transcript shows at once;
  otherwise it shows after at most 400 ms at the best place it can resolve, or 2.5 s with a "Restaurando leitura…"
  indicator while history is paging toward a saved place (then "Retomar leitura" if it is still not loaded).
- **Background.** Hiding the app keeps the exact passage; arrivals land below and ↓ appears. Returning merges the tail
  (`ConversationStore.revalidate`) without restarting the event loop or moving anything visible.
- **Streaming.** Streamed prose edits its text storage from the changed paragraph and is measured in its own
  unbounded TextKit container, so only invalidated fragments are laid out again; rebuilds are coalesced to one per
  frame. `ConversationStreamLog` records text and reasoning deltas as they arrive: a read of a running message (the
  server keeps a part's text only when it ends) or deltas dropped while a read was in flight never open a gap.
  Retained conversations keep recording while off screen (`SessionStore`'s event loop feeds their logs from the same
  hub; frames both loops see are recorded once, by sequence; nothing is published or laid out), so leaving mid-answer
  and coming back shows everything streamed meanwhile and continues live. A part whose beginning streamed before
  any log saw it (a working session opened from the list, a store that was released) shows live from what arrives:
  a `…` marker, then the text from its first whole line; its end event brings the whole text, growing above the reader's place without moving it. After
  a real disconnection (the app suspended), a part that lost deltas keeps its text until its end event instead of
  continuing past a hole.
- **History.** Only the reader's own scrolling pages history in near the top (not a search or a resume offer); a
  transcript shorter than its viewport pages in until it fills it or an empty page ends the history. Prepends keep
  the screen still (with room below a short transcript until the next drag).

**Verifying.** `measure-scroll.py` (below) runs the reading, history, streaming and trajectory scenarios; the Checkpoint
B/C targets are zero wrong frames and zero first-frame deviation for `reentry-*`, `child-middle` and `background-*`,
no intermediate frames for `open-*`, at most 0.5 pt for `paged-up`'s largest unrequested step, and `stream-follow` CPU
at or below the `List` baseline. `-OpenCodeMeasureCheck` (DEBUG) compares every incremental prose measurement with
`sizeThatFits` and logs differences. UI coverage: `ConversationFollowTests` (growth keeps the screen still, ↓, the last
footer whole at the end), `PinnedPromptJumpTests`, `ReadingContinuityTests` (history and relaunch, parent/child, the
sent prompt rising and its answer growing in place, an answer streaming across a refresh without a gap — both call
the sandbox model once — and a shell message arriving while the app is hidden for more than 30 seconds, which keeps
the passage and offers ↓), and app-hosted `ConversationRetentionTests` (registry, double mount, reveal deadlines,
slow history toward a saved place).

Runners (`test-isolated.py`, `test-quotes.py`) leave the theme to each test. The first launch of an `xcodebuild` run
sometimes ignores its arguments and opens the app's saved server (also on the `List` baseline); a failure at the
first `waitForExistence` of a run's first test is that, not the transcript. Seeds whose permission or question was consumed by a resumed sandbox need
`seed-conversation.ts --reset` before the card tests.
`test-isolated.py --attempts 2` enables XCTest retries; `OPENCODE_TEST_ATTEMPTS=2` also works through runners that
delegate to it. Merge verification pairs `SessionSwitcherTests` (including both retained passages),
`SessionSelectionTests`, `ProjectAvatarTests`, and the affected activity/header catalog cases with the Kit and
app-hosted tests. Device reentry and streaming scenarios cover changes to registry integration and activity cells.

### Returning to a conversation — 27 October

A conversation is no longer rebuilt from nothing each time it is opened. `SessionStore.conversations`
(`ConversationRegistry`) keeps the five most recently opened conversations of the server plus every one on the
navigation stack, and a memory warning keeps only the stack. Each `ConversationStore` keeps its loaded pages and
cursor, projections, a `TranscriptMemory` with prompt-bubble and `<details>` expansion, fetched shell output and table
offsets (all previously view state, lost with the row), and the exact passage last shown, even at the end. Returning
opens at that passage at once, without waiting for the network, catalogs or `ready`: restoration needs only the
transcript, and no history page is fetched for it. The screen's event loop starts once per appearance, not per scene
phase; the tail read behind it merges and publishes nothing when unchanged (see the contract's *Retained
conversations*). Covering the conversation with another screen and coming back no longer restores it again.

Hiding the app keeps the exact passage: if it was following the end, following stops there, so messages that arrive
meanwhile land below and ↓ appears; returning to the foreground restarts nothing. Following resumes only when the
reader's own scroll ends at the end (a shrinking area or growing viewport no longer starts it). Disk persistence is
unchanged: the end is still saved as `followTail`, so a relaunch opens at the end. Response Markdown is parsed
latest-wins: a newer text no longer cancels the parse in flight (which, in a fast stream, could cancel every parse
until the stream paused); intermediate results publish at most every 100 ms.

That table measured the `List` transcript, which rebuilt its rows on return; the UIKit transcript (*Transcript
architecture* above) replaced it. On the iPhone 14 every `reentry-*`, `child-middle`, `open-*` and `background-*`
episode now shows 0 wrong frames and 0 pt first-frame deviation, `paged-up`'s largest unrequested step is 0.2 pt,
`read` costs 2.0 s of main-thread CPU (was 4.5 s) and `stream-follow` 6.2 s (was 6.4 s) with no row movement and no
whole-text replacement.

`measure-scroll.py`, alternating the two Debug `-O` builds (`a16c80c972` with only the instrumentation, then this
change), medians; trajectory counts sum the three returns of a run. iPhone 14: two iterations; simulator (iPhone 17
Pro, iOS 27.0): three, on a heavily loaded host, so its frame times are directional only.

| Scenario | iPhone 14 before | iPhone 14 after | Simulator before | Simulator after |
| --- | ---: | ---: | ---: | ---: |
| `background-tail`: frames showing another passage after returning | 146.5 (another passage) | 0 (0 pt) | 143 | 0 |
| `background-middle`: same | 73 (271 pt below the top row, 1 of 2 runs) | 73.5 (same) | 0 | 0 |
| `reentry-tail`: wrong frames / first-frame deviation | 30 / another passage | 9 / 1,942 pt | 30 / another passage | 9 / 1,882 pt |
| `reentry-middle`: same | 13 / 2,360 pt | 6 / 68 pt | 7 / 68 pt | 6 / 68 pt |
| `child-middle`: same | 0 | 0 | 0 | 0 |
| `open-middle`: wrong frames / first content | 2.5 / 507 ms | 7.5 / 117 ms | 5 / 305 ms | 3 / 615 ms |
| `stream-follow`: main-thread CPU, 12 s | 6.45 s | 6.37 s | 8.06 s | 7.56 s |
| `stream-follow`: growing row's largest step / text replacements | 36.7 pt / 288 | 36.7 pt / 288 | 36.7 pt / 292 | 36.7 pt / 299 |
| `read`: main-thread CPU | 4.24 s | 3.55 s | 2.09 s | 1.90 s |
| `paged-up`: largest unrequested step | 86.7 pt | 44.3 pt | 406.7 pt | 44.3 pt |

The remaining `background-middle` movement happens on the device in both builds whenever the opening restoration lands
on `msg_scroll_0153` (one run in two): the top row stays put while rows below it move 271 pt, a re-measurement the
`List` performs while the app is hidden. Every response still replaces its whole text on each streamed batch.

### Returning to a conversation — 27 October

A conversation is no longer rebuilt from nothing each time it is opened. `SessionStore.conversations`
(`ConversationRegistry`) keeps the five most recently opened conversations of the server plus every one on the
navigation stack, and a memory warning keeps only the stack. Each `ConversationStore` keeps its loaded pages and
cursor, projections, a `TranscriptMemory` with prompt-bubble and `<details>` expansion, fetched shell output and table
offsets (all previously view state, lost with the row), and the exact passage last shown, even at the end. Returning
opens at that passage at once, without waiting for the network, catalogs or `ready`: restoration needs only the
transcript, and no history page is fetched for it. The screen's event loop starts once per appearance, not per scene
phase; the tail read behind it merges and publishes nothing when unchanged (see the contract's *Retained
conversations*). Covering the conversation with another screen and coming back no longer restores it again.

Hiding the app keeps the exact passage: if it was following the end, following stops there, so messages that arrive
meanwhile land below and ↓ appears; returning to the foreground restarts nothing. Following resumes only when the
reader's own scroll ends at the end (a shrinking area or growing viewport no longer starts it). Disk persistence is
unchanged: the end is still saved as `followTail`, so a relaunch opens at the end. Response Markdown is parsed
latest-wins: a newer text no longer cancels the parse in flight (which, in a fast stream, could cancel every parse
until the stream paused); intermediate results publish at most every 100 ms.

The SwiftUI `List` still rebuilds its rows on return and restores the passage with `scrollTo` and corrections, so the
first frames of a return can still show another passage; the UIKit transcript replaces that path.

`measure-scroll.py`, alternating the two Debug `-O` builds (`a16c80c972` with only the instrumentation, then this
change), medians; trajectory counts sum the three returns of a run. iPhone 14: two iterations; simulator (iPhone 17
Pro, iOS 27.0): three, on a heavily loaded host, so its frame times are directional only.

| Scenario | iPhone 14 before | iPhone 14 after | Simulator before | Simulator after |
| --- | ---: | ---: | ---: | ---: |
| `background-tail`: frames showing another passage after returning | 146.5 (another passage) | 0 (0 pt) | 143 | 0 |
| `background-middle`: same | 73 (271 pt below the top row, 1 of 2 runs) | 73.5 (same) | 0 | 0 |
| `reentry-tail`: wrong frames / first-frame deviation | 30 / another passage | 9 / 1,942 pt | 30 / another passage | 9 / 1,882 pt |
| `reentry-middle`: same | 13 / 2,360 pt | 6 / 68 pt | 7 / 68 pt | 6 / 68 pt |
| `child-middle`: same | 0 | 0 | 0 | 0 |
| `open-middle`: wrong frames / first content | 2.5 / 507 ms | 7.5 / 117 ms | 5 / 305 ms | 3 / 615 ms |
| `stream-follow`: main-thread CPU, 12 s | 6.45 s | 6.37 s | 8.06 s | 7.56 s |
| `stream-follow`: growing row's largest step / text replacements | 36.7 pt / 288 | 36.7 pt / 288 | 36.7 pt / 292 | 36.7 pt / 299 |
| `read`: main-thread CPU | 4.24 s | 3.55 s | 2.09 s | 1.90 s |
| `paged-up`: largest unrequested step | 86.7 pt | 44.3 pt | 406.7 pt | 44.3 pt |

The remaining `background-middle` movement happens on the device in both builds whenever the opening restoration lands
on `msg_scroll_0153` (one run in two): the top row stays put while rows below it move 271 pt, a re-measurement the
`List` performs while the app is hidden. Every response still replaces its whole text on each streamed batch.

### Transcript update and history paging cost

*Historical: this section describes the `List` transcript, replaced on 27 October.*

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
in both themes, now requiring that growth never moves the offset and that ↓ appears (`ConversationScrollPlan` and
its follow owner were removed with the `List`). Empty-tail restoration and offline jump-to-latest navigation are also checked without
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
allocated until the first send, which calls `custom.master/ensure` with the picked model: the plugin creates the
session (or returns one that voice or another client created meanwhile) and attachments go to its directory. The
plugin's preferred model wins over personal new-session defaults; when unavailable, the server's default model is used.
The existing model/effort picker remains available; the agent stays Mestra.

Opening the master screen verifies the stored pointer (`GET /api/session/:id`, also after a `session.deleted` for it).
A 404 or an archived session (for example deleted or archived on the web) calls `custom.master/ensure`, which creates a
fresh master and moves the pointer; the old history is gone, since native delete is permanent. Voice does the same on
its first delegation and retries once with the replacement if the master disappears during a call.

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

Verification is isolated to **OpenCode Mestra** (`EC672074-0EF6-47AB-9299-8AF7FE2658C1`), iOS 27, an owned sandbox, and
`$TMPDIR/opencode/ios-mestra-derived`. After `build-for-testing`, run `python3 packages/ios-custom/script/test-master.py`
and repeat with `OPENCODE_TEST_THEME=openchamber-light`. Every launch explicitly supplies the sandbox URL/password;
private xctestrun credentials are removed afterwards. The old-server UI scenario is a DEBUG-only, loopback-sandbox-gated
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

`test-master.py` now defaults to sandbox 4177 (4179 is production's resources hub) and runs on its own: the target of
`testTargetUserMessageShowsMasterOrigin` is a synthetic import whose user message carries the `custom.master` metadata
the master's tools write, instead of a recorded `live-transcript.json`. `testEmptyFirstSendHiddenAndTrashStartsFresh`
archives and clears any current master first, since `testDeletedMasterIsRecreatedWhenOpened` runs before it and leaves
one.

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
Sessão mestra, shows **A mestra está consultando seu iPhone.** in its progress indicator without automatically
narrating the tool activity. The footer and the iOS permission prompts say that
the OpenCode agents read this data when Alexandre asks.

Requirements: `OpenCode/OpenCode.entitlements` (HealthKit, no clinical records), the usage descriptions
`NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription` (App Store Connect rejects a HealthKit upload
without it, even though the app never writes), `NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription` and
`NSPhotoLibraryUsageDescription`, and an explicit-App-ID profile: automatic signing (`-allowProvisioningUpdates`)
enables HealthKit on `br.com.alexandrem.opencode`; the team wildcard profile cannot sign the app anymore.

Verification: `swift test --filter DeviceDataTests` (contract, dispatch, ranges, sleep/motion aggregation, cache
filter, conversation labels), and against an isolated sandbox with location granted and set on the simulator:
`test-isolated.py … --location LAT,LON OpenCodeUITests/DeviceDataTests` in both themes. `--location` installs the
build, runs `simctl privacy <udid> grant location br.com.alexandrem.opencode` and sets the position right before the
run (a simulated position set long before may yield no fix within the 3-second limit), so a fresh simulator works. The second case sends one real Mestra prompt and
checks that `iphone_query` for `device`, `network` and `location` completed with `status: "ok"`. HealthKit, CoreMotion
and Photos need the physical iPhone 14: a DEBUG launch with `-OpenCodeDeviceProbe` enables every source (answer the
iOS prompts), collects each once plus the locked-cache answer, and writes `Documents/device-probe.json`.

## Mac app (stages 1–4) — 27 October

A native macOS client of the same server, built from this project with the iPhone code it can reuse. Briefing and
approved mocks: `.agent-artifacts/mac-app/coluna3/` (`BRIEFING.md`, `final/contexto.png`, `final/arquivos.png`,
`final/janela-mac.png`) of the `mac-app` worktree. Stage 1 delivered the three-column window and the real third
column; stage 2 the LLM proxy window; stage 3 the layout parity with the approved mocks and the shared chat (see
[The window](#the-window)); stage 4 the iPhone's features outside the chat (see [Parity outside the chat](#parity-outside-the-chat-stage-4)).

### Target and folders

- Target **OpenCodeMac** (scheme `OpenCodeMac`) in `OpenCode.xcodeproj`: SwiftUI app, macOS 15+, bundle
  `br.com.alexandrem.opencode.mac` (Release; Debug is `br.com.alexandrem.opencode.mac.debug`, so a development or
  fixture run never shares window frames, defaults or saved state with the installed app), team `ERRYZ68LX5`,
  automatic signing,
  hardened runtime, no App Sandbox (it reads checkouts, runs `git` and `opendiff`). No App Store or TestFlight.
- `OpenCodeMac/` is a synchronized folder with the Mac-only code: `OpenCodeMacApp.swift` (scenes: main window,
  one window per resource, one per background task's output, the LLM proxy window, `Settings`; the menu bar),
  `MacRuntime.swift`, `MacWindow.swift`, `MacToolbar.swift`, `MacSessionColumn.swift`, `MacChatColumn.swift`
  (column and conversation), the transcript (`MacTranscriptController.swift`, `MacTranscriptCells.swift`,
  `MacTranscriptItemViews.swift`, `MacTranscriptText.swift`, `MacTranscriptContext.swift`, `MacTranscriptHost.swift`),
  the composer (`MacComposer.swift`, `MacComposerText.swift`), `MacConversationSupport.swift`, `MacNewSession.swift`,
  `ContextColumnStore.swift`, `MacContextColumn.swift`, `MacFilesView.swift` + `MacFilePane.swift` +
  `MacCodeView.swift`, `MacResourceWindow.swift`, `MacShellOutput.swift`, `MacNotifications.swift`,
  `MacProxyWindow.swift`, `MacSettingsView.swift`, `MacDataAgent.swift` + `MacDataCollectors.swift` +
  `MacDataSettings.swift` (see [Dados do Mac](#dados-do-mac--29-october)), `MacSpinner.swift`, `MacAssets.xcassets` (the app icon and
  `OpenCodeMascot`, the icon beside answers), and the DEBUG-only
  `MacFixture.swift`, `MacFixtureProxy.swift`, `MacCapture.swift`, `MacStress.swift`, `MacPerf.swift`,
  `MacScrollFixture.swift` and `MacScrollDriver.swift`.
- iPhone files enter the Mac target through the `OpenCode` folder's membership exceptions for `OpenCodeMac`
  (`PBXFileSystemSynchronizedBuildFileExceptionSet` `D…024`), never by copying. To share another file, add it to that
  list, keeping it in alphabetical order. The themes (`Resources/Themes/*.json`),
  `Resources/Markdown/dist/markdown-engines.js` and `Assets.xcassets` (the LLM proxy logos) are shared the same way.
- The app icon is `MacAppIcon` in `OpenCodeMac/MacAssets.xcassets` (`ASSETCATALOG_COMPILER_APPICON_NAME`), drawn by
  `swift script/generate-mac-icon.swift` from the iPhone's `script/icon-source.png` on the macOS grid (an 824-pt
  rounded rectangle with a shadow in 1024: macOS does not mask a square icon).

### What is shared with the iPhone

| Shared file | Change for the Mac |
| --- | --- |
| `SessionColumn/*` (rings, chips, sections, rows, path line; the header is no longer shown on the Mac) | Glass through `adaptiveGlass`; the header gained `voiceDisabled` (unused since stage 3); chips use `.never` scroll indicators on macOS; the ring drawing is `QuotaRing`, also used by the LLM proxy sidebar |
| `SessionStore.swift` | `#if os(iOS)` around drafts, quote modes, reverts and the live-conversation registry; DEBUG fixtures are iOS-only |
| `Theme.swift` | `uiColor`/`ThemeChrome` in `#if os(iOS)`; `nsColor` on macOS |
| `AppTypography.swift` | UIKit metrics in `#if os(iOS)`; the Mac uses desktop sizes (about 2 pt smaller) for the same roles |
| `Haptics.swift`, `EventHub.swift` | UIKit feedback and the iPhone device/Live Activity agents in `#if os(iOS)` |
| `SessionAlertCenter.swift`, `Toast.swift` | `adaptiveGlass`/`adaptiveGlassButtonStyle`; the floating voice inset is iOS-only |
| `SubscriptionViews.swift` | The sheet's parts became shared views (see [LLM proxy window](#llm-proxy-window-stage-2)); the nav-bar hiding is iOS-only |
| `ConversationRenameAlert.swift`, `ContextUsageViews.swift` | The UIKit alert and `SessionUsageSection` (needs `ConversationStore`) in `#if os(iOS)` |
| `SessionResources/ResourceList.swift` | `ResourceImage` (`UIImage`/`NSImage`), wider snapshots on request, `frames` (capture time) |
| `AgentPixels.swift` (new) | `AgentPixels` and `AppTheme.agentRole`, moved unchanged out of `ConversationComponents.swift` |
| `PlatformGlass.swift` (new) | Liquid Glass on iOS and macOS 26; material/bordered fallback on macOS 15 |
| `ConversationColumn/*` | The chat pieces (see [Shared chat layout](#shared-chat-layout-iphone-and-mac--27-october)). For the Mac: `ConversationAvatar.size` (44 by default), the activity card's title/detail sizes at desktop density (13/12 pt) in `#if os(macOS)`, and `composerCapsule()` through `adaptiveGlass` (the same glass on iOS; macOS 15 has no `glassEffect`) |
| `SessionColumn/ProjectIconImage.swift` | `ProjectIconRenderer` on macOS rasterizes the SVG with `NSImage` (AppKit reads SVG data); the iOS web-view renderer is unchanged inside `#if os(iOS)` |
| `ModelCatalogCache`, `VoiceMemoryStore`, `SubscriptionTestClient`, `ResponseEngines`, `ArchivedSessionsView`, `SessionDeleteConfirmation` | Unchanged |
| `SessionStore.swift` (stage 4) | `shownSessionID` on macOS: the session the window shows (while the app is in front) is `currentSessionID`, so its alerts stay silent |
| `SessionColumn/SessionChips.swift` | `ChipMenu`: the iPhone's `Menu(primaryAction:)`; on the Mac a click runs the action and a right click opens the same items (state filters, remove, move) |
| `SessionColumn/SessionColumnHeader.swift` | The selection bar became `SessionSelectionBar`, also shown by the Mac above its rows |
| `SessionSwitcherSheet.swift` | The iPhone sheet; still in the Mac target, but no longer presented there since the title's popover was removed (⌘K covers it) |
| `AppTypography.swift` (`AppLayout.margin`) | 6 pt on macOS (16 on iOS; the Mac list adds about 8 pt): Sessões uses its width for titles and paths |
| `ConversationReadAloud.swift` | `ConversationBottomControls(showsJump:)`, `true` by default: the Mac draws ↓ beside the reading column itself |
| `ConversationRequests.swift` | On macOS the question's own answer is `MacReplyField` (Return sends, Shift+Return breaks the line, Esc leaves); iOS keeps its `TextField` |
| `ArchivedSessionsView.swift` | On macOS a search field at the top (⌘F); iOS lists every archived session as before |
| `AddProjectPicker.swift` | iOS-only field and title modifiers behind `pathInput()` and `inlineNavigationTitle()` |
| `NewSessionComponents.swift` (new) | `ProjectAvatar`, `ChatsAvatar`, `GitBranchIcon`, `MCPChip`, `MCPFlowLayout`, moved unchanged out of `NewSessionView.swift` |
| `ModelVisibilityView.swift` | Generic over `ModelVisibilitySource` (the conversation's `ConversationStore` on iOS, `MacModelCatalog` on the Mac); macOS shows a search field instead of `.searchable` |
| `ThemePicker.swift` (new) | `ThemePicker` and its preview, moved unchanged out of `SettingsView.swift`; plain buttons on macOS |
| `SessionColumn/SessionRowView.swift` (`RunningArc`) | On macOS the turning arc is `MacSpinningArc` (Core Animation); iOS keeps the SwiftUI rotation |
| `SessionResources/ResourceViewer*.swift`, `ResourceSurface.swift`, the three kind views | `ResourceImage` frames (CGImage decoded off the main actor on macOS); on macOS `ResourceTouchOverlay` is a pointer and keyboard surface and `ResourceKeyboard` is empty; the on-screen keyboard buttons and the share sheet are iOS-only (the Mac saves the simulator capture with `NSSavePanel`); a DEBUG `fixtureFrame` hook for offline captures |

The iPhone target keeps its behavior: every change is either a no-op on iOS (`#if`) or a move. OpenCodeKit gained
`ContextColumn` (all the column's logic), `MarkdownSyntax.role`, `ServerStore(builtinURL:)` and the DEBUG
`OpenCodeClient.inMemory` transport.

### The window

Stage 3 (27 October) brought the window to the approved mocks: option B of the title bar, the "Máximo" level of
Contexto and the chat shared with the iPhone. Briefing, mocks and the parity images:
`.agent-artifacts/mac-app/paridade/` of the `mac-app` worktree (`BRIEFING.md`, `1-janela-contexto.png` … and
`paridade-*.png`).

- **Columns**: `NavigationSplitView` (Sessões | detail). The detail is an `HStack` of the chat and Contexto with a
  draggable hairline between them (`MacColumnDivider`, from 400 pt to 60% of the window and never squeezing the
  chat below its minimum, restored per window and remembered as the default for new windows);
  `MacSidebarDivider` draws the same 1-pt theme `border` between Sessões and the chat, including the unified
  title bar. It follows the real sidebar geometry and hides with it, without changing native divider hit testing.
  Contexto is offered the room first (`layoutPriority(1)`, `minWidth: 400`), so a narrower window shrinks it before
  the chat goes below 460 pt and the window's minimum is the sum of the minimums (1191 pt with Sessões at its 330-pt
  ideal). Contexto is no longer an `.inspector`: an inspector gets its own, empty part of the title bar, so `…` and
  Nova sessão could not sit over it. It hides with ⌥⌘I, Visualizar ▸ Ocultar contexto or the `…` menu. Do not add a
  `minWidth` on the root: the stage-1 crash (a root minimum below the columns' made AppKit loop on "more Update
  Constraints in Window passes than there are views") came from it. `script/test-mac-window.sh` guards it.
- **Title bar (option B)**: one `unified` strip (the regular height since the adjustment round), no title. Every
  item is a `MacPlainToolbarItem`, which on macOS 26 hides the shared Liquid Glass capsule (`sharedBackgroundVisibility(.hidden)`): plain 15-pt icons with a
  hover highlight (`MacToolbarIcon`). Over Sessões, at its right edge: voice (GPT Live; see below),
  Configurações and Nova sessão. Over the chat: `MacChatTitle`, the shared `ConversationAvatar` (now with a `size`,
  30 pt here) and `ConversationTitle` (`App Mac`, `<worktree> · trabalhando…`), a label (the quick switcher
  popover is gone: ⌘K replaces it). The native **Buscar projetos e sessões · ⌘K** field centers over chat + Contexto (see below).
  Right, after a `ToolbarSpacer(.flexible)`: `…` (rename, pin, mute, delete, Arquivos,
  Mostrar/Ocultar contexto) and Nova sessão (`MacSessionActions`). The system sidebar button is removed
  (`.toolbar(removing: .sidebarToggle)`; ⌃⌘S and Visualizar still collapse Sessões), and so is the old
  `sidebar.right` button. The same holds for the LLM proxy window.
- **Sessões**: the shared column without its big title: it starts under the bar with the quota rings and the chips;
  sections and rows are unchanged. Selecting a row selects the session; the iPhone's swipe and long-press actions are
  one right-click menu (stage 4 adds the selection mode and the Sessão mestra accessory). A quota ring opens the LLM
  proxy window on its provider.
- **Chat**: the iPhone's conversation (`ConversationStore`, `ConversationDraft`) on an AppKit transcript and a native
  composer; see [Chat (polish 1)](#chat-polish-1--27-october).
- **Settings**: see [Ajustes](#ajustes). `-OpenCodeServerURL`/`OPENCODE_SERVER_URL` and
  `-OpenCodeServerPassword`/`OPENCODE_SERVER_PASSWORD` override the server for a launch, as on the iPhone.

### Approved Mac choices — 28 October

The approved palette C, project rail C and subagent banner A + tree C are implemented independently of the
general-polish and ⌘K fixes. Their contract and reference images are `.agent-artifacts/mac-app/ESCOLHAS.md` and
`escolhas/` in the `mac-escolhas` worktree.

- **Model palette** (`OpenCodeMac/MacModelPalette.swift`): the composer capsule, `/model` (including Nova sessão)
  and **⌥⌘M** open a centered, dark-material AppKit child panel with a dimmed background. ⇧⌘M keeps its existing
  Sessão mestra action. ↑↓ select; ←→ choose supported effort; Return applies; ⌘Return applies and writes the
  existing `model.default` preference through `SessionStore.rememberNewSessionModel`; Esc or outside click closes
  and restores editor focus. Clicking an effort applies immediately. **Padrão** keeps the server's default effort,
  distinct from **none**; other supported levels use L/M/H/XH/MAX (unknown variants retain their names).
  Nova sessão follows the same explicit ⌘Return rule; merely applying a model there does not overwrite the default
  on Send. iPhone's existing new-session rule is unchanged. Model choices are cached: opening makes no request.
  The Kit's `ModelPalette` owns visible-model ranking, accent-preserving highlights, groups and efforts;
  `ModelPaletteMemory` owns the existing per-server bounded recent list. Favorites reuse `Preferences.Models`
  and `modelFavorite`, including ⌘D; no competing local favorite store was introduced. Empty search is favorites,
  recent choices, then providers. The shared `ModelCatalogCache.committed` calls the same recent-list projection.
- **Project rail** (`OpenCodeMac/MacProjectRail.swift`, Kit `ProjectRail`): 52 pt wide, full-height and independently
  scrollable. Todas, fixed Chats, then the saved repository chips and Add. Repositories retain `SessionList.chipGroups`
  ordering (working/unread before manual order) and its 1.5 s settling behavior; manual changes apply immediately.
  The sidebar's width range grows by 52 pt to preserve the rows' usable width. Project icons/monograms are 32 pt;
  counts include root sessions, with separate working, pending and unread dots. Click uses the chip semantics,
  including state filters; right click offers filters/removal/moves. Dragging a repository onto another saves its
  target position using the existing `project.move`. Chats stays pinned on Mac, while its saved iPhone position is
  preserved. No iPhone chip view changed. ⌘K and the rail observe the same `selectedProject`/`filter`.
- **Open subagent** (`OpenCodeMac/MacSubagentNavigation.swift`, Kit `SubagentNavigation`): a full-width 8%-tint
  lilac banner inside the chat, pixel-grid icon, SUBAGENTE, title, latest transcript agent/model/effort (session
  fallback), and a parent-title Back button (⌘[). The composer keeps its child placeholder and gains a lilac border.
  Sessões keeps the root selected and adds only the open ancestry underneath, indented once per generation; Back
  removes the departed branch. Metadata is read from the existing live conversation/family, without another poller.
  `MacSubagentIdentity` is the integration point for the general-polish agent's column-3 metadata. Response mascots
  remain that agent's responsibility.

**Checks and captures:** `swift test` in OpenCodeKit covers ranking, visibility, favorites, effort, persisted recents,
rail order/counts/indicators/drop intents and nested ancestry. `script/test-mac-window.sh` now also runs
`MacChoicesChecks` against the closed in-memory fixture, exercising the real palette's keys, persisted preferences,
zero catalog reads on opening, rail filters, child navigation and Nova sessão. Set `OPENCODE_MAC_DERIVED`,
`OPENCODE_MAC_TEST_DOMAIN` and `OPENCODE_MAC_CAPTURES` to isolated values. Its explicit launch URL defaults to
`http://127.0.0.1:4213` (`OPENCODE_MAC_TEST_SERVER_URL` overrides it); no fixture request leaves the process.
`-OpenCodeMacChoicesFixture` provides a richer visible catalog and in-memory favorite/default mutations;
`-OpenCodeMacModelPalette empty|<query>` opens it for the normal capture pipeline. Evidence for this change goes
to `$TMPDIR/opencode/mac-escolhas-prints/`, including the production views drawn by AppKit when locked.
`OPENCODE_MAC_CHOICES_ONLY=1` runs those focused checks without the broader window/search stress suite.

Verification on this worktree: **598 Kit tests passed**, warning-free macOS Debug build, successful iOS/Watch
Simulator build with no new warnings (the 13 existing source warning sites in `ResponseText.swift` and vendored
WatchRTC are unchanged), and the focused window script passed. It checks native text-field focus and typing,
↑↓/←→, ⌘D, Return versus ⌘Return, Esc, the independent Nova sessão selection, rail filters and child/back.
Palette construction plus first layout/draw in the four-model fixture measured **40.7 ms cold, 16.9–19.2 ms warm**,
with zero additional catalog reads. The full window script reached the existing window-search `MacSearchChecks.layout`
stage, then failed its panel-anchoring assertion while moving to the built-in display at 1500×940; rerun that suite
after integrating the parallel search fix. The exact trace is `mac-escolhas-prints/validacao-completa-busca.log`.
Comparisons are `comparacao-paleta.png`, `comparacao-trilho.png` and `comparacao-subagente.png`; the latter compares
the combined banner/tree against both approved subagent references. `nova-sessao-paleta.png` captures the second host.

### Chat (polish 1) — 27 October

Briefing: `.agent-artifacts/mac-app/POLIMENTO-CHAT.md` of the `mac-polish-chat` worktree. The chat column is the
iPhone's conversation, with the platform parts parametrized.

**One conversation model.** The Mac uses the iPhone's `ConversationStore` (shared file): the event loop applies
deltas through `ConversationReducer` every 32 ms (120 ms while the reader scrolls) and reads the tail only for
structural events; it pages history with the cursor, keeps the inbox (steer and queue, optimistic bubbles), the
family's permissions and questions, the execution state, reverts, context and cache. `SessionStore` now keeps the
conversation registry, drafts, quote modes and reversions on macOS too; `shownConversations` (the root and the
subagent over it) plays the iPhone stack's part. A conversation's event loop runs while its view is shown
(`.task { await conversation.run() }`), and the shared event stream (`SessionStore.run`) now runs whenever the
window is not hidden, the app frontmost or not.

**Why a subagent "barely opened and did not update" (before).** The stage-3 `MacTranscriptStore` reread the
latest page (`custom.transcript/list`) 250–600 ms after any event and ignored the deltas. That page carries a
streaming part only when it ends, so a subagent writing its answer showed nothing until the step finished: in the
owned sandbox (`script/test-mac-live.py --long-answer`), the old build's trace stayed at `text=0` for the whole
stream while the new one showed 372 → 910 → 4,233 characters as they arrived. It also opened only that last page
(no paging), showed the raw `You are a subagent…` preamble, and drew every message as SwiftUI blocks reparsed on
each reload, in one `ScrollView` reused from the previous session.

**Subagents.** The activity card's agent chip (and its pixel button), Contexto's rows and the session alerts open the
child in the middle column over its root (`MacSelection.childID`). The child is a full conversation (its own live
store from the registry); a header with `‹ <root title> › <child title>`, the agent and `trabalhando…` leads back,
and so does ⌘[ (Ir ▸ Voltar à sessão principal, `MacWindowRuntime.backToParent`: a nested subagent goes back to its
parent subagent). A notification or banner about a subagent opens it the same way (`MacWindowRuntime.select`: its root in
Sessões, the child in the middle column). Returning shows the root exactly where it was left (the retained
transcript view). The prompt bubble follows Ajustes ▸ Leitura (`OpenCodeCollapsibleUserMessages`, like the
iPhone's Você ▸ Leitura): on, long prompts and prompts with quotes fold to two lines; off, every prompt shows whole,
and changing it measures the prompts again in place.

**Transcript.** `MacTranscriptController` is an `NSScrollView` with a flipped document of its own, on the iPhone
rewrite's model: `TranscriptProjection.items` (the shared `Transcript/TranscriptItems.swift`, unchanged), the Kit's
`TranscriptGeometry` (positions, the pinned prompt, the reading anchor, the trailing space under a sent prompt),
`ReadingPositionStore`, the conversation's `TranscriptMemory` (`ConversationRegistry.swift`, unchanged; the Mac
supplies `TranscriptState`, `TranscriptHeights` and its controller as `TranscriptViewController`) and the shared
reading rules in OpenCodeKit's `TranscriptNavigation` (`latestOffset`, `stableAnchor`, `continued`, `owners`,
`TranscriptFollow`, `TranscriptScrollKey`). Only the items within a viewport of the visible area have views; each is
measured at the column's width when it appears (prose with TextKit 2, hosted SwiftUI through
`NSHostingController.sizeThatFits`), heights are cached per item, content and width, and a height that changes
above the reader's place moves the offset in the same pass. Hosted items report later size changes themselves
(an expansion, an image that loaded). It opens hidden until laid out at its place (at most 400 ms), restores the
saved passage per session, pages older history from the top without moving what is on screen, keeps the
current prompt pinned (a click on it brings its turn's first row under it), raises a sent prompt to the top,
shows ↓ **Ir para a mais recente** and **Continuar de onde parou**, and keeps the end through window resizes.

Platform parameters: the wheel and trackpad (no pull to refresh; a gesture owns the offset until it settles);
the keyboard (Page Up/Down, space and Shift-space, ⌘↑/⌘↓, Home/End, the arrows) in the transcript or in a text
inside it; the centered reading column (960 pt at most, with the message icons; see
[Adjustment round](#adjustment-round--28-october)); and **following the end** while an answer arrives: the end stays in view
while the reader is there, scrolling up stops it at once and scrolling (or ↓) back resumes it. The iPhone rewrite
never scrolls on growth; the briefing asked the Mac to follow.

**Response text.** Prose runs (paragraphs, headings, lists, quotes, rules) are one `NSTextView` per run on TextKit 2,
with native selection across them, ⌘C as Markdown (one list item per line) and a context menu with **Comentar…**
(a quote with its comment attached to the next prompt, `Citações · N` above the composer). Its attributes follow the
iPhone's `ResponseTextStyle` at desktop sizes (`MacResponseTextStyle`); quote borders and rules are drawn by the
view; a streamed answer replaces only its last paragraph. Code blocks use the highlight.js colors with Copiar;
tables are grids; formulas use the shared SwaTeX rasters (`ResponseFormula.swift`, SwaTexRender now linked to the
Mac); Mermaid diagrams use the shared JS engine's SVG; images load through `FeedImageLoader` and open at full size.
File names open Arquivos at their folder. Search (⌘F, or the conversation's `…`) is the shared
`ConversationSearchState`, with highlights in the text, ↑/↓, Return/Shift-Return and older pages.

**Composer.** `ConversationDraft` (persistent draft, attachments, quotes, the queued prompt being edited) on
`ComposerInputView`, an `NSTextView` with the iPhone's atomic tokens (`ComposerTokenAttachment` drawn with AppKit).
`@` (sessions, apps, agents, references), `!` (files), `/` (commands), `$` (skills) and `#` (snippets) open the shared
`ComposerSuggestions` panel; Return picks its first item, Esc closes it. **Return sends and Shift+Return (or
⌥Return) breaks the line**, the Mac chat convention, unlike the iPhone's software keyboard. Attachments come from
`+` (Arquivos…, Imagens…), a drop on the conversation or a pasted image, through `ConversationStore.importAttachment`.
The model capsule and `/model` open the model and effort picker, the agent capsule beside it (and `/agent`) its
picker, the MCP capsule a popover with each server's switch; `/btw` asks a side question in a sheet. Sending is
`ConversationStore.send`, so the delivery follows the server's preference while the agent works (steer or queue)
and right-clicking Enviar offers the other one (Enviar agora / Adicionar à fila); the tray (`ConversationTray`)
  lists the queue with Editar, Enviar agora and ×. The microphone now uses the shared on-device recorder and
  Parakeet Ultra; see [Voice on Mac](#voice-on-mac--28-october).

**Requests in the chat.** The iPhone's permission and question cards (`ConversationRequests.swift`, shared) are
transcript items.

**Shared with the iPhone in this stage** (membership exceptions, no copies): `ConversationStore`,
`ConversationActivityStore`, `ConversationUsage`, `ConversationRegistry`, `ConversationDraft`, `QuoteSync`,
`ConversationMCPStore`, `ConversationRevert`, `ConversationReadingRequest`, `ConversationQuotes`,
`ConversationSearchState`, `ConversationRequests`, `ComposerSuggestions`, `ComposerAppMentions`, `ResponseFormula`,
`ResponseMarkdownCache`, `SideQuestionFixture`, `Transcript/TranscriptItems.swift` and `Fixtures/scroll-fixture.json`
(excluded from Release). Edits in iPhone files, all no-ops there: `SessionStore` (the registry, drafts, quote modes
and reversions leave `#if os(iOS)`; `shownConversations`), `ConversationStore` (`#if os(iOS)` around the screen
catalog fixture), `ConversationDraft` (imports AppKit on macOS), `ComposerSuggestions` (its DEBUG fixtures are
iOS-only), `ConversationQuotes` (`QuoteDetailsSheet` is iOS-only), `ConversationRequests` (the permission card's
`…` menu calls `plainMenuOnMac()`, new in `PlatformGlass.swift`, a no-op on iOS) and `MCPUIError` moved from
  `NewSessionStore` to `ConversationMCPStore`. Since the voice port the Mac shares `ConversationReadAloud` and
  `VoiceRecordingComposer` too; it supplies `SideQuestionLaunch`, `ScrollFixtures` and `ConversationOpeningMetrics` (DEBUG).

**Checks.** `swift test` (`TranscriptNavigationTests` for the reading rules); the macOS Debug build without warnings;
the iOS Debug build with the same 13 warnings as before; `script/test-mac-window.sh`;
`script/measure-mac-scroll.py --app <OpenCodeMac.app> --output <jsonl>` runs the iPhone's fixture scenarios
(`read`, `history-up`, `stream-reading`, `stream-still`, `stream-follow`, `paged-up`) on the 300-message
`-OpenCodeScrollFixture conversation` through `MacScrollDriver` (frame intervals, main-thread CPU, unrequested
movement, replaced frames; while the screen is locked a 60 Hz timer that draws the window replaces the display
link); `script/test-mac-live.py --app … --home <sandbox> --server-url http://127.0.0.1:4199 --evidence <dir>
[--long-answer] [--child-after 5] [--history 40]` imports a parent, makes it call a Luna 6 / low subagent, opens the
child and traces once a second what it shows (`-OpenCodeMacLiveTrace`). Capture sequences:
`-OpenCodeMacCaptureEvery <s> -OpenCodeMacCaptureCount <n> [-OpenCodeMacCaptureDelay <s>]`; DEBUG launch options
`-OpenCodeMacChild <id> [-OpenCodeMacChildAfter <s>]`, `-OpenCodeMacDraft <text> [-OpenCodeMacPickSuggestion <s>]`.

### Coluna 3 — Contexto ("Máximo")

`ContextColumnStore` reads, for the selected root, the same sources as the iPhone's conversation and "Agentes e
tarefas": `GET /api/session/:id`, `custom.session-family/snapshot` and `/page`, the root's transcript page (links
`subagent` calls), `/api/shell`, `/api/model`, `/api/agent`, `/api/vcs/diff`, `custom.worktrees/locate` and
`custom.resources/list`, and reloads on the shared event stream. `ContextColumn` (OpenCodeKit) does the math.

Only neutral grays and hairlines, no cards and no colored icons. The only colors: `+N` green and `−N` coral, a cache
hit below 80% amber, and the amber `?` of a subagent asking for permission. Top to bottom:

1. `mac-app · +128 −14 · Arquivos ›`: the branch (its right-click menu copies it or the path, or shows it in the
   Finder; the path is its tooltip), the working diff and a plain link to Arquivos.
2. Three figures (22 pt semibold over an 11-pt gray caption, hairlines between them): the context ring and `28%`
   "contexto · 278,6k / 1M" (latest measured step, transcript fallback), `99,5%` "cache hit" of the session, then
   `US$ 78,25` "custo total".
3. `Sessão US$ … · Subagentes US$ …` (the family snapshot's descendant cost, else the sum of loaded descendants).
4. `SUBAGENTES active/total` with the `contexto · cache · custo` headings. Rows keep `ConversationProjection.work`'s
   order (live first, then the newest finished up to five, the rest behind `+N concluídos ›`): a 13-pt medium title,
   the three metrics in fixed right-aligned 11-pt columns with tabular digits (cost brighter, whole or
   `US$ 2,7 mil`), then `agente · Modelo · esforço` with the elapsed time, then
   `agora: <tool> · <resource it drives>`. The state is a glyph in a small gutter: a gray
   spinning ring while running, an amber `?` while asking (with `Permitir · Negar` links), nothing once ended
   (finished rows dimmed). Clicking opens the child in the middle column (`‹` returns); right-click has Parar.
5. `TAREFAS N`: background shells, 12-pt lines with a monochrome icon (a hammer for builds and tests, play
   otherwise), the command without its port option plus `· :port`, the elapsed time; right-click Parar and Copiar
   comando.
6. `RECURSOS N`: live thumbnails for the resources in use and compact rows with a small thumbnail for the
   others, with the state in gray (`Agente usando`, `Você no controle`, `Livre`, `Parado há N min`); clicking opens
   the resource's window (see [Adjustment round](#adjustment-round--28-october)).

**Arquivos** (over the column; `Arquivos ›`, ⇧⌘F, or a file named in the chat), at the same level: `‹ Contexto`
(Esc), the centered title and the search (`/api/fs/find`); the folder's absolute path as a gray clickable
breadcrumb, truncated in the middle, with a copy button; `PASTA` with
`Todos · Alterados` as text; a Finder-like list with monochrome `doc`/`folder` icons, `+N −N` in color, a gray dot
for folders holding changes (date and size, read from this Mac, in the tooltip); then
`ARQUIVO · N LINHAS` with the links `Abrir no Xcode · Finder · Ver diff` (only when the path exists on this Mac; Ver
diff also needs `/usr/bin/opendiff` and FileMerge and writes `git show HEAD:<file>`, or an empty file for a new one,
next to the working copy) and the code in SF Mono with line numbers and the highlight.js colors blended halfway to
the plain code color, or Quick Look.

**Not provided by the server (shown as `—`, no backend change):** a subagent's context before its first measured
step; per-subagent cache when the child has no `tokens`; the resource ↔ subagent link is inferred from
`resource.owner.sessionID` walked up to the direct subagent, so a resource registered without an owner shows
`Agente usando · —`; file dates and sizes for checkouts that are not on this Mac (`/api/fs/list` returns names only).

### LLM proxy window (stage 2)

Approved option 4 (briefing and mock: `.agent-artifacts/mac-app/llm-proxy/` — `BRIEFING.md`,
`referencia-janela.png`, `ios-hoje.png`). The content and actions are the iPhone's "LLM proxy" sheet; only the
layout is the Mac's.

- **Scene**: a single `Window` "LLM proxy" (⌘⇧L, listed in the Window menu), about 1000×640 at first; AppKit keeps
  its frame between openings. The quota rings in Sessões set `MacRuntime.proxyPane` to their provider and open it.
  It reads `SessionStore.quota`, the same `SubscriptionStore` as the rings (no second poller); opening it runs
  `refresh(ifDue:)`.
- **Toolbar**: refresh, and **Buscar conta** (`searchable`), which filters the tables by account name (case- and
  accent-insensitive). The pool card and the `N/M disponíveis` headings keep counting the whole pool.
- **Sidebar** (System Settings style): Codex and Claude (only the providers the server offers) with logo, percent
  and a small `QuotaRing` showing what the Sessões ring shows (the "Mostrar no resumo" account, else the pool);
  a separate section with **Redefinições**. There is no "Histórico": the server has no data for it. Rows are
  buttons with a theme-colored highlight, because a List selection uses the system accent, not the theme.
- **Provider**: `ProxyPoolHeader(wide: true)` (logo, `0,80 Pro 20x`, "Cota semanal combinada", bar with the pace
  marker and `N% restantes` on one line, plans · accounts, paid credits; on the right the 5-hour badge for
  Claude, `N de M contas disponíveis`, "Próxima renovação" `date · countdown`). Then, per plan, the heading and a
  native `Table` in the `SubscriptionProjection.sorted` order: the "Mostrar no resumo" radio, Conta, Plano,
  5 horas and Semana (thin bar + percent in the iPhone's tone colors, `—` when unknown or, for 5 horas, once the
  week is exhausted), Renova (two lines), Status (dot + `SubscriptionAccountState` title and tone), Redefinições
  and **Usar** (only with banked resets; "Usar redefinição" in its help and accessibility label; a spinner while it
  runs). Every column but the radio and the action sorts from its header; the default order is the iPhone's.
  The clicked row (else the "Mostrar no resumo" account, else the first visible) shows the iPhone's
  `ProxyAccountCard` under its table. "Outros planos · fora do saldo acima" opens the first group outside the
  pool. A footer card holds a **Redefinições** shortcut, the provider's **Redefinição automática** switch, the
  note "A seleção altera só o resumo, não a conta usada pelo modelo." and the measurements' freshness.
- **Redefinições**: per provider, the iPhone's inventory card (`N redefinições disponíveis`, first and last
  expiry, how many never expire) with its automation switch.
- **Actions and states**: both actions keep the iPhone flow through the shared `proxyActions` modifier
  (confirmation dialog, `Aplicando…`, "Aguardando o proxy · pode levar cerca de 90 segundos" in the account card,
  toast with the result). Unlike the iPhone, choosing "Mostrar no resumo" does not close the window. Loading,
  unavailable/unconfigured with "Tentar novamente", no accounts ("Nenhuma assinatura foi informada pelo LLM
  proxy.") and a search without matches (`ContentUnavailableView.search`) are the iPhone's `ProxyPoolState`.
- **Not used from the mock**: the Codex | Claude segmented control (the sidebar already selects the provider) and
  "Histórico".

What is shared with the iPhone sheet, with no visible change there (the iPhone's `you-subscriptions-default`
catalog capture was regenerated and compared):

| Piece | Where |
| --- | --- |
| `SubscriptionGroup` (plan groups, "Outros planos", search, focus), `SubscriptionAccountRow` (row values, sort keys, `renewalLabel`), `SubscriptionPane` + `SubscriptionStore.sidebar`/`pane(_:)`, `SubscriptionProjection.freshness(now:)`, `SubscriptionStore.Confirmation.title/action/message` | OpenCodeKit `SubscriptionTable.swift`, covered by `SubscriptionTableTests` |
| `ProxyPoolHeader` (with `wide`), `ProxyPoolState`, `ProxyResetsCard`, `ProxyAutomationToggle`, `proxyActions`, `ProxyAccountCard`, `ProxyQuotaBar`, `ProxyProviderIcon`, `proxyCard`/`proxyBadge`/`proxyRole` | `OpenCode/SubscriptionViews.swift`, extracted from `SubscriptionDetailSheet` (which now composes them) |
| `QuotaRing` | `OpenCode/SessionColumn/SessionQuotaRings.swift` |

### Parity outside the chat (stage 4)

Stage 4 brought the iPhone's features outside the chat to the Mac, with the iPhone's components where they can be
shared (see the table above) and Mac interactions: right click instead of swipes and long presses, menus, keyboard
shortcuts, sheets, popovers and windows. Contract and audit: `.agent-artifacts/mac-app/POLIMENTO-APP.md` and
`AUDITORIA.md` of the `mac-polish-app` worktree. The chat itself (transcript, composer, live conversation) is a
separate track.

- **Sessões**: every row action of the iPhone in the right-click menu (open, Selecionar, Nova sessão a partir desta,
  rename, pin, mute, mark read, archive, delete). The **selection mode** starts with ⌘-click or Selecionar: rows show
  the iPhone's circles, the column shows `SessionSelectionBar` with **Arquivar (N)** and **Excluir (N)**, and the
  iPhone's rules apply (a filter or chip change ends it, hidden rows leave it, serial requests, failures stay selected,
  the delete confirmation with the count, running sessions, the master warning and an Arquivar alternative). The
  Sessão menu repeats them (⌥⌘A selects all). Chips open their menu on a right click (state filters on "Todas",
  remove, move before/after); Visualizar ▸ Filtrar sessões also picks the state. **Adicionar repositório** is the
  iPhone's `AddProjectPicker` (the server's folders, `..`, hidden folders, create and add). The iPhone's
  **Sessão mestra** accessory sits at the column's foot (`N precisam de você` / `Tudo em dia`, ⇧⌘M): it opens the
  current master in the middle column or, without one, Nova sessão in its master mode, whose first message calls
  `custom.master/ensure`.
- **Busca da janela (⌘K)**: see [Window search](#window-search--28-october). The shortcut focuses the title-bar
  field. The title's quick-switcher popover was removed in the adjustment round: the title is a label.
- **Nova sessão** (⌘N, the toolbar, the switcher; ⇧⌘N from a session): a sheet with the iPhone's decisions
  (`NewSessionProjection.start/model/agent/remembered`, `NewSessionSubmission`): Chats or a project (or
  Adicionar projeto…), the main checkout, an existing worktree or **Nova worktree** with its base branch (a
  searchable popover over `/api/vcs/branch`), the shared MCP chips (live on an existing checkout, intents for Chats
  and a new worktree), the visible models with their effort ("Padrão" included) and the agent. A model chosen here
  becomes the default for new sessions, as on the iPhone; one inherited from the origin session does not. The
  prompt is the chat's composer embedded (`MacComposer(embedded:)`: tokens and the suggestion panel over a
  composer `ConversationStore` in its new-session mode, whose `loadNewSession` reads the directory's catalog;
  attachments; the persistent `new-session` draft, `new-session-master` for the master), without its model, MCP and
  agent controls, which the sheet shows. Return sends, as in the chat, and so does ⌘Return; a leading `/command`
  runs on the new session (`newSessionDocument`), and the attachments are delivered to its directory.
- **Contexto**: a question asked by a subagent shows its text and **Responder ›** (opens the subagent); Tarefas open
  the task's live output in its own window (`MacShellOutput.swift`: `/api/shell/:id/output` by cursor from the last
  256 KB, `ShellOutputLog`; Parar and Copiar), also from Ver saída in the right-click menu. **Detalhes** at the
  column's foot (closed by default) is the iPhone's Detalhes da sessão: model, agent, the directory (opens Arquivos),
  the MCPs with their switches (`toggleMCP`, for every session of the directory), the loaded skills and the plugins.
- **Recursos**: the resource window is the iPhone's `ResourceViewerScreen` (one view per kind, the status pill with
  its measurements, Assumir controle / Devolver, the kind's tools, Chrome's address bar). In control a click is a
  touch and a drag moves it; the trackpad scrolls Chrome's page (`scroll`) and drags on a simulator or emulator; the
  Mac's keyboard types into the resource (`ResourceKeyMapping`: DOM key names, Control shortcuts, text) and ⌘V pastes
  the Mac's clipboard. The simulator's Captura de tela is saved with a save panel. Closing the window gives control
  back.
- **Arquivos**: Markdown files open rendered with the chat's renderer (soft line breaks joined,
  `MarkdownSoftBreaks`, lazily in pieces) and HTML with Quick Look; `</>` shows their source. ‹ › (⌥⌘← ⌥⌘→) page
  through the folder's files, like the iPhone viewer's siblings. Images, PDF, audio and video stay in Quick Look.
- **Alerts and notifications**: the in-app banner (`SessionAlertCenter`) stays silent for the session on screen
  while the app is in front. While the app is not in front, each banner (answered or finished, failed, permission,
  question; mutes and deduplication included) also becomes a macOS notification (`MacNotifications`), and clicking
  it opens that session. The Dock icon shows `requestCount` (permissions and questions), like the iPhone's tab badge.
  The fixture never asks for the notification permission nor posts anything.
- **Bell (`MacNotificationBell`, rev. 29/10)**: no state of its own. Its count and **Não lidas** are the rows with
  Sessões' orange dot (`SessionRow.unread`, the server's `viewed`) or a pending permission or question, one line per
  session, so reading a conversation on any device clears its line. **Anteriores** are recent answers already read,
  dimmed; Limpar hides only them. A new line (a dot or a request appears, never for the conversation on screen)
  bounces the bell, fills it orange until read and, in the key window with no sheet, search or palette over it,
  opens the list for 4.5 s (longer under the pointer) with the line highlighted. The list is a nonactivating child
  panel that cannot become key, so the composer keeps typing; opening it never marks anything read. Check:
  `-OpenCodeMacFixture contexto -OpenCodeMacFixtureBell 12 [-OpenCodeMacBellShot <png>]` (`MacBellChecks`, in the
  background and off-screen) prints `MacBellChecks ok|FAIL …` and exits 0 or 1.
- **Menus and shortcuts**: Arquivo (Nova sessão ⌘N, Nova janela ⌥⌘N, Atualizar ⌘R), Visualizar (Contexto ⌥⌘I,
  Arquivos ⇧⌘F, Filtrar sessões), Sessão (Nova sessão a partir desta ⇧⌘N, Renomear ⇧⌘R, Fixar ⇧⌘P, Silenciar,
  Marcar como lida, Arquivar ⌥⌘⌫, Excluir ⌘⌫, both confirmed and acting on the selection while there is one, Reiniciar Sessão mestra), Editar (Buscar
  na conversa ⌘F), Ir (Buscar projetos e sessões ⌘K, Voltar à sessão principal ⌘[, previous/next session ⌥⌘↑ ⌥⌘↓,
  Sessão mestra ⇧⌘M, Conversar por voz, the first nine sessions of the list, ⌘1…⌘9, and Todas then the project rail's chips in the order it shows them, ⌥1…⌥9) and Janela (LLM proxy ⇧⌘L). ⌘[ is the Mac's Back (Finder, Safari, Xcode), so it leaves a subagent; the neighbors moved
  to ⌥⌘↑/⌥⌘↓, up and down Sessões. The title bar's `…` shows the same session actions and Buscar na conversa.
  Shortcuts avoid the text editing keys (⌘A, bare arrows) and the transcript's (Page Up/Down, space, ⌘↑/⌘↓); ⌘⌫ typed
  in an editable field (`MacTextKeys`) still deletes to the start of the line there instead of excluding the session.
- **Restoration**: each window has a stable scene UUID and restores its own session, subagent, Arquivos folder/file,
  sidebar visibility, Contexto visibility and width, per server (`OpenCodeMacWindow.<uuid>.<server>`); a window
  without saved state opens Contexto at the last width dragged in any window (`OpenCodeMacContextWidth`). A deleted or
  archived selection falls back to the first row. Right-click **Abrir em nova janela** and Option-click a session
  open an independent window, as does Arquivo ▸ Nova janela (⌥⌘N).
- **Voice**: GPT Live, the floating bar, Parakeet dictation and server read-aloud now share the iPhone implementation;
  see [Voice on Mac](#voice-on-mac--28-october).

### Window search — 28 October

The approved **centered search** presentation is `OpenCodeMac/MacSearchPresentation.swift`: an `NSSearchField`
in the title bar, with a same-width nonactivating suggestions panel 4 pt below it. Clicking the field or ⌘K
(from anywhere in the window, the composer included) focuses it and opens the list; ⌘K selects the previous text.
Typing stays in the field and refilters on each key. ↑/↓ (and ⌃N/⌃P) traverse results across groups (including
**Mostrar mais**), scrolling to keep the selection visible; Return or a click chooses, closes and focuses the
composer. Esc clears a non-empty field; on an empty one it closes and returns focus to the composer. Clicking
outside dismisses and lets go of the field; losing the key window closes its list. While the field has focus
the composer receives none of these keys. Each window has its own field, list and state; ⌘K acts on the front
one. Each result's VoiceOver label includes its group. Matched title spans are bold, preserving the original
accents.

- **Placement:** `MacSearchPlacement.swift` measures the actual detail area (chat + Contexto) in the window's
  frame view, and centers at `(detail.minX + detail.maxX) / 2`. The field is at most 520 pt; its half-width is
  limited by the measured title and action bounds, with 12 pt of clearance on each side. Resizing either divider,
  hiding either column and resizing the window all remeasure the field and its panel. The title truncates inside
  a 100–230 pt allocation on narrow windows so it cannot cover the search. When Sessões is hidden, that allocation
  also reserves 180 pt for the traffic lights/sidebar toolbar. With both side columns hidden, the chat's minimum
  becomes 840 pt: the old 460 pt cannot fit those controls, the title and a centered search. No root minimum is added.
  The field sits directly in the unified bar, outside the macOS 26 shared glass wrappers, like the other plain
  toolbar content.
- **Appearance:** native search and clear buttons, the full placeholder and a persistent trailing ⌘K hint;
  a rounded translucent material panel with a hairline and native shadow. Uppercase PROJETOS, SESSÕES and
  ARQUIVADAS; project avatars (grid for Todas, bubble for Chats), loaded root-session counts, path · branch,
  the list's compact elapsed times and a green working marker. The first result is selected neutrally. A fixed
  `↑↓ navegar · ↩ abrir · esc fechar` footer stays visible when the results scroll (panel capped at 560 pt and
  the remaining window height). Below 320 pt the working marker keeps its green dot and accessible label while
  omitting the word, leaving more room for the title. Colors follow the selected theme, including light themes.
- **Order:** Projetos, Sessões, Sessões arquivadas. Project candidates are only the saved chips, plus **Todas**
  and **Chats**. Choosing one repeats the chip's exact `selectedProject`/`filter` semantics: Todas clears both;
  a repository or Chats toggles its selection while preserving the state filter. No shared preference is mutated.
- **Sessions:** root sessions and chats, excluding archived roots, then archived roots in their own group.
  Selecting a session opens it in that window; if the current filter hides its row, it resets to Todas.
  Archived results open through the same conversation path as Arquivadas, without unarchiving them.
- **Matching:** case/diacritic insensitive; title prefix, word start, then substring, ties by recent activity.
  Sessions also match project name, branch and full path; projects match only their name. Default limits are
  5/8/5, with a per-group Mostrar mais. An empty query starts with Todas, Chats, saved projects and recent sessions.
- **Data:** `SessionStore` already exhausts the cursors in `OpenCodeClient.navigation()` and `archivedSessions()`.
  Its loaded history covers the search; the current iPhone title switcher is also local. No extra server search,
  debounce or RPC is needed. If that loading contract later becomes partial, reuse `composerSessions(_:)` with
  debounce rather than adding an RPC.
- **Separation:** pure ranking, groups, limits, highlights and chip semantics are in OpenCodeKit's
  `WindowSearch.swift` (`WindowSearch.Index` folds titles and metadata once); `MacSearch.swift` owns query,
  keyboard selection, actions and the per-opening `Catalog`, one instance per
  `MacWindowRuntime`. Presentation is isolated in `MacSearchPresentation.swift` / `MacSearchPlacement.swift`,
  mounted behind `MacWindow.swift`'s detail with title/action geometry markers in `MacToolbar.swift` and
  `MacChatColumn.swift`.
  Neither the ranking nor the ⌘K menu action depends on that placement.

Validation: `WindowSearchTests` covers groups, ranking, accents, metadata, limits, expansion, roots, empty query
and Todas/Chats. `script/test-mac-window.sh` also exercises the native field, cross-group arrows, Return,
hidden-session filters, archived navigation, Esc, outside clicks and isolation between two windows (`MacSearchChecks`). It also
asserts centering, title/action clearance and panel anchoring at minimum/maximum widths with each combination
of visible/hidden Contexto and Sessões, and with the Contexto divider at both extremes.
Search captures use `-OpenCodeMacSearchFixture -OpenCodeMacSearch empty|live` with the normal capture flags;
the dedicated fixture adds a saved `ios-live-activity` chip and one archived Live Activity root. Captures for this
centered presentation live at `$TMPDIR/opencode/mac-busca-prints/centralizada/` (idle, `live`, hidden Contexto,
narrow window and `comparacao.png` beside both approved mocks). `-OpenCodeMacHideContext` and
`-OpenCodeMacHideSessions` select collapsed-column captures.
The checks use a closed in-memory fixture and the explicit launch URL `http://127.0.0.1:4207`.
The centered-search verification ran all 590 Kit tests, a warning-free Mac build and an iOS/Watch Simulator build
with the same 13 source warnings (the warning sites are byte-identical to `ba2a22276c`). The captures were drawn
through AppKit with the screen locked; each open-search capture also asserts the real field/panel geometry.

#### Search fix — 28 October

In the installed app the field took no click, ⌘K opened the list without keyboard focus, no key reached the
field (↓, ↑, Return and Esc did nothing) and the list was slow. Reproduced with real events against the fixture
and against a 4211 sandbox with 600 root sessions; the causes were:

- **No focus at all (click, ⌘K, typing and every key).** `MacSearchPlacement` replaced the field's cell with
  `field.cell = MacSearchCell(textCell: "")`. A cell created that way is not editable nor selectable, so the
  `NSSearchField` refused first responder (Accessibility even reported it as `AXStaticText`): the click was
  ignored, ⌘K's `makeFirstResponder` failed silently while `visible = true` still opened the list, and with no
  field editor `control(_:textView:doCommandBy:)` was never called. `MacSearchField` now supplies the cell
  through `cellClass`, so NSTextField configures it as editable.
- **A click would not have opened the list.** It relied on `controlTextDidBeginEditing`, which AppKit sends on
  the first edit, not on focus; `MacSearchField.becomeFirstResponder` opens it now.
- **Slow list.** `updateNSView` computed the groups on every SwiftUI update, visible or not, from
  `SessionStore.rows` (derived again on each access), so every store change re-ran it; each update then built a
  new `NSHostingView` for the panel; each rendered row derived `store.rows` three or four more times (count,
  running, avatar, session), about 50 derivations per render; selection and arrows recomputed the groups two or
  three times; and the ranking ran locale-aware case/diacritic-insensitive `range(of:)` on every candidate.
  Now `MacSearch.Catalog` derives the rows once per opening (dictionaries for rows, archives, projects, labels,
  counts and running) and is rebuilt only when the store changed (`withObservationTracking`, lazily while the
  list is hidden); `WindowSearch.Index` keeps titles and metadata folded, so a key only compares folded strings
  and highlights only the visible rows; the groups are cached per query; the panel and its hosting view are
  created once per window (and drawn once, transparent, two seconds after the window appears) and the results
  observe the search themselves, so `updateNSView` only places the panel.
- **Why the earlier checks passed:** `MacSearchChecks` called the delegate's `doCommandBy` with a detached
  `NSTextView` and set the state directly; AppKit never had to make the field first responder or deliver an event.

Esc now clears a non-empty field before closing, ⌃N/⌃P move like ↓/↑, and an outside click also releases the
field. `MacWindowRuntime` passes its store to `MacSearch`; `MacToolbar.swift` and `MacWindow.swift` are unchanged.

Measured with `-OpenCodeMacSearchTrace` (DEBUG: from the key event's timestamp to the end of the main-thread pass
that first renders the results or shows the panel), 600 sessions, sandbox 4211:

| | before (focus fixed only) | after |
| --- | --- | --- |
| ⌘K → list, first | 403–416 ms | 81–97 ms (≈48 ms is AppKit's first ⌘K menu dispatch, 14 ms the catalog) |
| ⌘K → list, again | 320–366 ms | 24–52 ms (the search's own work ≈ 2 ms) |
| key → filtered list | 320–860 ms (one 2.6 s) | 14–49 ms, median 16–22 ms per run (a run's first key up to 88 ms) |

`script/test-mac-search-keyboard.sh [captures]` is the real-event check: it builds, runs a fixture copy under its
own bundle identifier and `script/mac-search-keyboard.swift` posts HID `CGEvent`s (mouse clicks, ⌘K, typing,
↓/↑, ⌃N/⌃P, Return, Esc, ⌥⌘N, ⌘W), checking focus, the field's value, the selected row's visibility and the
panel's window through Accessibility, and the opened session and timings through the trace. It covers click and
focus, ⌘K from the composer and typing over the selected text, cross-group arrows and scrolling, Return opening
the selected session and focusing the composer, Esc clearing then closing, a click on a result, outside clicks,
and ⌘K in the front one of two windows. With the old cell it fails 16 of its checks. It needs an unlocked screen
and Accessibility for the terminal, waits until the keyboard and mouse have been idle for `OPENCODE_MAC_IDLE`
seconds (default 5) and gives the front back to the previous app. Captures (focus after a click, typing,
selection moved by the arrows, scrolled selection) go to `$TMPDIR/opencode/mac-busca-fix-prints/` by default.

#### Ajustes

The `Settings` scene (⌘,) is the iPhone's Você in tabs, remembering the last one: **Servidores** (the active server
and its state, saved servers with Usar, Editar… and Remover…, Adicionar servidor… with "Testar conexão" over
`/api/info`, and Parear com código…: the `opencode pair` link or JSON pasted and redeemed like the iPhone does,
since the Mac has no scanner), **Aparência** (Sistema/Claro/Escuro and the shared `ThemePicker` with its previews),
**Leitura** (the same `OpenCodeCollapsibleUserMessages` switch), **Modelos** (the shared "Gerenciar modelos" over the
server's catalog and `model.visibility`), **Assinaturas** (the LLM proxy summary rows, opening the LLM proxy window)
and **Sobre** (version, commit, server). **Voz** adds the same next-call voice and rolling transcript; **Transcrição**
adds the same model download, progress, retry, deletion and licenses. **Dados do Mac** is described below. Dados do
iPhone and Apple Watch stay on iPhone.

### Dados do Mac — 29 October

The Mac app reads Calendar, Reminders and Contacts for the agents' `mac_query`, the way the iPhone answers
`iphone_query` (contract: [`plugin-app-custom/docs/mac-data.md`](../plugin-app-custom/docs/mac-data.md)). It replaced
the `OpenCode Mac Data` helper nested in the server's bundle, whose grants macOS attributed to the server and therefore
never applied. `MacDataAgent` keeps a presence lease through `custom.mac/attach` while the `EventHub` is connected
(every 30 s), detaches when the stream stops for good and on quit, and answers `rpc.custom.mac.request` events, which
never reach screen subscribers (iOS drops them too). `MacDataCollectors` (an actor) reads EventKit and Contacts off
the main actor and shows a macOS prompt the first time a source is read; the query waits for the answer within its
60-second deadline. With the app closed the tool reports `offline` immediately.

Only the installed app (`br.com.alexandrem.opencode.mac`) answers; Debug and fixture runs stay silent unless launched
with `-OpenCodeMacData`. **Ajustes → Dados do Mac** has one switch per source (all on by default), its permission
(Permitido, Permissão não pedida, Negado nos Ajustes do Sistema, Restrito) with the last answered query, **Pedir
permissão** while undetermined and **Abrir Ajustes do Sistema** when denied. Requirements: the Calendars, Reminders
(normal and Full Access) and Contacts usage descriptions in `OpenCodeMac/Info.plist`, and, because of the hardened
runtime, the `com.apple.security.personal-information.calendars` and `.addressbook` entitlements. Development
signing keeps the designated requirement across builds, so a grant survives updates.

Verification: `swift test --filter MacData` (request decoding, disabled sources, deadline, dates, preferences), the
plugin's `test/mac-data.test.ts`, and against a sandbox (`custom-sandbox.ts up --port 4199`) with a Debug build
launched with `-OpenCodeMacData`: one real prompt each for `status`, a switched-off source and, after quitting the
app, the immediate `offline`.

### Voice on Mac — 28 October

- **GPT Live:** the toolbar waveform starts the iPhone's `VoiceController`, `VoiceTransport`, lease/signaling,
  `VoiceMaster` and `VoiceMemoryStore`, using the same private `llm-proxy-svc:8080` origin and saved voice catalog.
  `FloatingVoiceHost` sits above the composer, so it remains visible when Sessões is collapsed and when changing
  conversations. The same compact/expanded bar has time, mute/end, retry/resume, spoken text, master progress and
  the rolling transcript. The empty chat and Nova sessão host it too.
- **Audio/lifetime:** macOS WebRTC owns the default Core Audio devices and its AEC; it does not configure an
  `AVAudioSession` or recreate the call when headphones change. `VoiceCuePlayer` uses `AVAudioEngine` for connection,
  end and recovery cues. `MacRuntime` owns the one event stream and `MacVoiceSession` the one call,
  including minimized/closed windows. Quit and server changes close local audio and release the lease. A failed
  background call posts a macOS notification, subject to the system's notification permission.
- **Permissions:** the first recording/call asks for the microphone; refusal explains the setting and offers a
  direct System Settings link. Debug/Release have `com.apple.security.device.audio-input` and the pt-BR usage text.
  ActivityKit and App Intents remain iOS-only.
- **Dictation:** FluidAudio 0.17.7 supports macOS 14+, so the Mac uses the exact Parakeet Ultra downloader, checksums,
  model, queue, PCM capture and insertion path. Click for hands-free recording, hold/release to transcribe, drag up
  to lock or left to discard; **⌃⌥Space in the editor** starts/stops. The fn key stays with macOS. Pause/preview/seek,
  retry, local pending audio and model management match iOS. The transcript lands in the composer itself, at the
  caret, which takes the focus to review and send it; there is no review sheet and it never sends automatically.
  The **right Option key** dictates too (see [Adjustment round](#adjustment-round--28-october)). Device changes and app deactivation pause recording.
- **Dictation microphone and music:** the Mac records with `AVAudioEngine` (`OpenCodeMac/MacMicrophone.swift`), the
  input chosen in Ajustes → Voz → **Microfone** set on the input node (`kAudioOutputUnitProperty_CurrentDevice`); the
  system default input never changes. **Automático** follows the default input unless it is Bluetooth, whose
  microphone forces the headset into the call profile (HFP, phone-quality music); then the built-in microphone
  records. **Padrão do sistema** always follows the default; a device saved by UID that disappears falls back to
  Automático. The file stays 48 kHz mono Float32 CAF, appended across pause/resume. **Pausar a música ao ditar**
  (on by default) pauses the now-playing media while recording and plays it again on stop or pause, only if this
  app paused it and it is still the paused now-playing player. MediaRemote answers only Apple-signed processes
  since macOS 15.4, so `osascript` (JXA) loads it and sends explicit pause/play commands, never a toggle (VoiceInk
  uses a Perl-hosted adapter framework for the same reason).
- **GPT Live microphone:** when the input chosen in Ajustes → Voz is not the default one (Automático with a Bluetooth
  default), the call's `RTCPeerConnectionFactory` gets `MacVoiceAudioDevice`, an `RTCAudioDevice` (the ObjC ADM bridge
  the macOS binary already contains; `prepare-mac-webrtc.py` now also exposes `RTCAudioDevice.h`). One
  `AVAudioEngine` records that input through an `AVAudioSinkNode` and another plays to the default output through an
  `AVAudioSourceNode`, as 16-bit mono PCM; an engine stopped by a device change is rebuilt on WebRTC's audio thread.
  WebRTC's AEC3 keeps cancelling echo with this playout as reference; Apple's voice processing is not used, since it
  drives the default devices and ducks other audio. Otherwise WebRTC's own Mac ADM follows the default devices.
- **Read aloud:** response footers and Markdown files use `custom.speech`, the same `ReadAloudPlayer`, pill/full
  controls, seeking, speed and server bookmarks. The voice comes from the speech server (separate from GPT Live's
  voice choice). Starting a call or dictation pauses it; reading cannot start while either owns the microphone.
- **WebRTC package repair:** the pinned M147 macOS binary exists, but its archive omits the public ObjC headers.
  `script/prepare-mac-webrtc.py`, a Mac-only build phase, restores the audio/data headers from the **same archive's**
  iOS slice to the processed build product. It changes no binary, package-manager artifact or iOS slice, and exposes
  no UIKit API. No new binary dependency or version was introduced.

Verification: `swift test` in OpenCodeKit, the Mac/iOS builds (including Watch), existing hosted iOS voice, dictation
and read-aloud tests, and `script/test-mac-window.sh`. The new `script/test-mac-voice.py --app <Debug/OpenCodeMac.app>`
uses an isolated `.debug.voice-tests` copy, the closed in-memory server and the iOS fixtures, with the explicit
4203 launch URL. It captures all bar states in both themes and exercises AppKit hold/lock, PCM preview, insertion
and the read-aloud RPC/player. `--parakeet` additionally downloads the pinned model into the evidence folder and
transcribes the recorded Portuguese fixture with the real local model. Evidence defaults to
`$TMPDIR/opencode/mac-voz-prints/`. A real microphone, echo and physical headset switching require a hands-on check.

### Running against a sandbox

```sh
bun install --frozen-lockfile   # once per worktree
bun packages/cli/script/custom-sandbox.ts up --port 4199 --home "$TMPDIR/opencode/mac-app-sandbox"
xcodebuild -project packages/ios-custom/OpenCode.xcodeproj -scheme OpenCodeMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$TMPDIR/opencode/mac-app-work/mac-derived" build
OPENCODE_SERVER_PASSWORD="$(cat "$TMPDIR/opencode/mac-app-sandbox/password")" \
  "$TMPDIR/opencode/mac-app-work/mac-derived/Build/Products/Debug/OpenCodeMac.app/Contents/MacOS/OpenCodeMac" \
  -OpenCodeServerURL http://127.0.0.1:4199 [-OpenCodeMacSession <ses_…>] [-OpenCodeMacFiles <folder>]
bun packages/cli/script/custom-sandbox.ts down --port 4199 --home "$TMPDIR/opencode/mac-app-sandbox"
```

Never use 4096, 4177 or 4178 for development. Families with subagents can be imported without model calls through
`POST /api/experimental/session/import` (as `script/test-agents-screen.py` does) and background tasks with
`POST /api/shell`; delete them afterwards.

### Captures

The agent process has no Screen Recording permission, so the app captures itself (DEBUG):

```sh
OpenCodeMac -OpenCodeMacFixture contexto -OpenCodeMacFixtureRoot <checkout> -OpenCodeTheme openchamber-dark \
  [-OpenCodeMacFiles packages/ios-custom/OpenCode/SessionColumn -OpenCodeMacFile SessionColumnSections.swift] \
  -OpenCodeMacCapture <folder> -OpenCodeMacCaptureName <name> -OpenCodeMacCaptureQuit
swift packages/ios-custom/script/mac-prints.swift crop <in> <out> x y w h          # fractions
swift packages/ios-custom/script/mac-prints.swift compare <out> <mock> <app> [<mock> <app>…]
```

`-OpenCodeMacFixture` swaps the server for a closed in-memory one (`MacFixture`, the cases of the stage-3 mocks: 7
roots in Trabalhando, Hoje and Ontem with nothing pending; 46 subagents with 4 live, one asking permission with a
60,6% cache; 2 tasks; 3 resources with drawn pictures; 6 changed files, `+128 −14`; a root transcript with an ended
turn (answer, a 15-call activity card, footer) and a running one (the live subagents), one queued prompt, four MCP
servers with one connected; folders and files come from the given checkout). Its LLM proxy (`MacFixtureProxy`) has Codex with seven accounts (Disponível, Cota semanal esgotada,
Limite de 5 horas, Em espera, Desativada, and a stale Plus account under "Outros planos" with paid credits) and
Claude with four (one needing reauthentication, one Max 5x outside the pool), banked resets with and without
expiry, and automation off for Codex and on for Claude. Its actions change only that memory, after 2 s
(automation) or 6 s (a reset, `-OpenCodeMacProxyResetSeconds`). `-OpenCodeMacProxyScenario loading|error|empty`
holds the read forever, fails it, or returns no accounts. `MacCapture` moves the window off-screen at 1600×1000
(`-OpenCodeMacCaptureSize 1269x794` matches the stage-3 mocks, a 1269×794-pt window drawn at 1.25×; add
`-OpenCodeMacContextWidth 427` for their Contexto width), writes `<name>.png` from the window server's
picture of this app's own window (`CGWindowListCreateImage`, needs no permission for the app's own windows;
`cacheDisplay` is the fallback while the screen is locked; it cannot draw the Liquid Glass sidebar, so the capture
first gives the sidebar's list views an AppKit background of the theme's color) and `<name>-coluna.png` with the
whole column through `ImageRenderer`. `-OpenCodeMacOpenActivity 1` opens the first activity card, like the chat
mock. The stage-3 parity images (mock × app) are rebuilt by running the captures at the mocks' size and
`mac-prints.swift compare`; `script/test-mac-window.sh` takes `OPENCODE_MAC_DERIVED` for another DerivedData. The stage-1 captures are in
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/mac-app-prints/`.

Stage 4 adds launch options (put them before `-OpenCodeMacCaptureQuit`): `-OpenCodeMacFixtureAttention` (one root
asking permission, one asking a question, one failed), `-OpenCodeMacSelect id,id` (selection mode),
`-OpenCodeMacNewSession sessoes|origem|mestra`, `-OpenCodeMacDetails`, and, each written to
its own picture, `-OpenCodeMacOpenResource <id>` (`<name>-recurso.png`), `-OpenCodeMacShellOutput <shell>`
(`<name>-saida.png`) and `-OpenCodeMacSettings servidores|aparencia|leitura|modelos|assinaturas|sobre`
(`<name>-ajustes.png`). Sheets are drawn where they sit; a popover, which AppKit keeps on a screen while the window is
off-screen, is drawn under the title. While no window is open (a locked screen), captures open one through Arquivo ▸
Nova janela, like the stress run. The fixture answers Nova sessão's reads (worktrees, branches, VCS, configuration),
plugins, skills, a task's output and resource control; its resource viewer shows the drawn snapshot as its frame.
Stage-4 captures: `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/mac-polish-app-prints/`.

The LLM proxy window is captured with `-OpenCodeMacProxy codex|anthropic|resets` (put these options **before**
`-OpenCodeMacCaptureQuit`: a value after a valueless option is taken as a document to open, and then no window
opens), optionally `-OpenCodeMacProxySearch <text>`, `-OpenCodeMacProxyAccount <id>`,
`-OpenCodeMacProxyAction confirm|applying` (asks to use that account's reset; `confirm` keeps the dialog,
drawn over the window, and `applying` confirms it against the fixture) and `-OpenCodeMacCaptureSize WxH`
(1200×800 by default; AppKit clamps the height to the screen). While the screen is locked the window server
returns blank pictures, so `MacCapture` draws the window with `cacheDisplay` (the window looks inactive) and,
since that leaves the Liquid Glass sidebar blank, renders `MacProxySidebar`'s rows over that column. Stage-2
captures, including the iPhone sheet before/after (`ios-you-subscriptions-*`):
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/mac-app-prints/llm-proxy/`.

### Verification

`swift test` in OpenCodeKit (`ContextColumnTests`: costs, subagent order/collapse/permission, resource split and
owner, ports, ages, "Só alterados", breadcrumb, highlighter fence, FileMerge plan; `SettingsTests` for the Mac's
default server), the iOS Debug build and `build-for-testing` with no new warnings, and the warning-free macOS Debug
build. The FileMerge button was not clicked in automation (it would open FileMerge on Alexandre's screen); its plan
is unit-tested.

Stage 2 adds `SubscriptionTableTests` (groups and "Outros planos", search, table focus, row values and every sort
key, sidebar rows and the Codex fallback, confirmation texts, freshness). "Usar redefinição" and the automation
switch were exercised only against `MacFixtureProxy`, never against a server: they spend the proxy's real resets.

Stage 4 adds `DesktopSupportTests` (session navigation, notification text and Dock badge, `ShellOutputLog`,
`ResourceKeyMapping`, `MarkdownSoftBreaks`). Notifications, the Dock badge and a resource in control were not
exercised against a server (the fixture posts no notification; driving a real resource would take Alexandre's
simulator or browser).

**Window stability** (`script/test-mac-window.sh [runs] [idle seconds]`): builds OpenCodeMac and runs the DEBUG
`MacStress` against the fixture, starting from the default size without saved window frames: it runs a copy of
the build with its own bundle identifier, `br.com.alexandrem.opencode.mac.debug.tests` (ad-hoc signed), and clears
only that domain and its saved state, so the Debug app's preferences (servers, the restored selection, Ajustes,
Contexto's width) that development and the other checks use stay as they were. It resizes the main
window to its minimum, intermediate sizes and each screen's maximum on every connected screen, collapses and
reopens Sessões and Contexto twice, opens and closes Arquivos and the LLM proxy window, then stays idle (30 s by
default). Since stage 4 it also opens and closes Nova sessão, the selection mode and a
resource window. A layout loop aborts the app (the old crash, exit 134); a minimum width wider than a screen fails
the run.
Run it after any change to the window's columns, widths or toolbar. It moves the window over the connected
screens while it runs. Launched from a shell while the screen is locked, SwiftUI opens no window until the app is
activated, so `MacStress` opens one through File ▸ New Window.

### Next stages

- Menu bar extra and widgets stay out.

### Chat details and independent windows — 28 October

- **Quotes:** AppKit renders raised 12-point inline numbers using `QuoteTextMap` (UTF-16 decoration mapping); copy,
  selection and new quote anchors exclude the numbers. Prose, code and table cells use the same native text view.
  Clicking a passage or its number opens the shared iPhone `QuoteDetailsSheet` as a native Mac sheet; existing
  links and text selections keep their actions. `QuotedPassage` and `DraftQuotesCard` moved unchanged into
  `ConversationQuotes.swift`, shared by both targets. The tray supports editing, removal and source navigation;
  the Mac comment editor uses the token/attachment composer and the existing `lend`/`commit` flow. Sent marks use
  the existing dismissal/sync policy and offer navigation to the carrying message. Source navigation validates
  the anchor, loads at most five older pages per request and briefly highlights hidden marks.
- **Long prompts:** `MacCappedScroll` measures the full text/context at its actual width and puts it in an
  `NSScrollView` capped at 40% of the transcript viewport. Attachments, expansion controls, time and copy remain
  outside. Folding and pinned-prompt navigation retain their existing behavior.
- **Shell:** an expanded shell tool polls `ConversationStore.shellOutput` once a second while running and once
  after completion. The result is stored in the per-key observable output box, updating only its hosted row;
  hiding/collapsing the row cancels its task. No transcript reload or second event subscription is needed.
- **Windows:** `MacRuntime` owns the server, SessionStore, event consumer, alert delivery, badge and subscriptions.
  `MacWindowRuntime` owns presentation and a separate transcript memory/reading store for every window/session.
  Two windows sharing a conversation still have only one live conversation consumer, reference-counted by the app.
  Menu commands resolve `focusedSceneValue`; search and file navigation target that window. A notification selects
  its session in the front conversation window (or opens a window when none remains).
- **Voice integration:** `MacWindow` installs the window environment at the integration point; the chat's bottom
  `safeAreaInset` places its voice bar above its composer. Every window shows the same app-wide call through
  `runtime.app.audio.voice`, with its own expansion/transcript-sheet state. `MacRuntime.front` routes the microphone
  permission/failure alerts and the notification click (restoring a minimized window or opening one if none remains).
- **Window-local audio:** `MacConversationInput` keeps the draft, dictation job/review and read-aloud controls per
  window and Session, even when two windows show the same Session. `MacWindowRuntime.drafts` also scopes Nova sessão.
  A new window copies a legacy saved draft (including local attachments/pending audio) without altering its source.
  Quotes still synchronize through the Session-scoped RPCs and the existing EventHub; the live conversation consumer
  remains shared. The front editor handles ⌃⌥Space. Starting another reading stops the previous audio, as on iPhone,
  but closing/navigating an unrelated window never stops it. Starting the single GPT Live call pauses local audio.

Verification helpers: `DesktopWindowStateTests` covers restoration across windows/servers and Unicode/overlapping
quote marker offsets. `script/test-mac-window.sh` now asserts two actual windows on different sessions, independent
columns/files/child state and transcript memories, and closes one without changing the other. It accepts
`OPENCODE_MAC_TEST_DOMAIN` and `OPENCODE_MAC_CAPTURES` for isolated parallel workers. `zsh script/test-mac-details.sh`
checks real native quote copying, internal prompt scrolling and changing shell output without a conversation
revision; it captures each case through AppKit, including on a locked desktop. Both use their own app copies.
The closed in-memory fixture includes the bundle identifier in its persistence namespace, so parallel copies
also have independent synthetic drafts and reading positions.
The dedicated validation environment uses sandbox **4205**, DerivedData `mac-detalhes-derived` and
`mac-detalhes-ios-derived`, and captures under `$TMPDIR/opencode/mac-detalhes-prints/`.

Validation on this change: **572 Kit tests**, the repository `bun run check`, the two-window stability run and
all four native details checks pass. The final Mac build has no warnings. The iOS test build has the same **17
unique warnings** as a baseline build, with no new ones. `QuoteHighlightTests` passes 7/9 in dark and 6/9 in light;
`PinnedPromptJumpTests` passes the distant-jump case (both themes), while its initial-position case fails.
The four failing checks (missing-source notice, sent-mark restoration, multiple marks, initial pinned position)
also fail at the same assertions in the light baseline: a VFS overlay substitutes the three shared Swift files
with their exact `HEAD` contents, using separate DerivedData and fresh imported sessions. The evidence is in
`mac-detalhes-prints/ios-baseline/`; these pre-existing iPhone regressions remain a separate follow-up.
The additional `SessionReadingTests/testSearchLoadedAndOlderPages` run fails in both themes on the synthetic
history (counter starts at `3 de 80`, then no older-page offer); the original-files baseline reproduces the same
assertions. Search does highlight the requested text. Evidence: `reading/` and `reading-baseline/` in that folder.

**Voice + details integration (`mac-app`).** The merge preserves `MacWindowRuntime`, native quote details,
long-prompt scrolling and row-local shell updates. Its checks use `mac-merge-derived` / `mac-merge-ios-derived`:
573 Kit tests, Debug/Release Mac builds with zero warnings, the iOS + Watch build with the 13 existing app/vendor
warnings, root `bun run check`, `test-mac-window.sh` and `test-mac-details.sh`. `test-mac-voice.py` now opens two
windows on the same Session for every scenario and checks separate drafts/players, the front editor's shortcut,
shared mute/call identity and independent expansion. Its 40 scenarios produce both `<name>.png` and
`<name>-second.png` under `$TMPDIR/opencode/mac-merge-voice-prints/`; details and window captures are in
`mac-merge-details-prints/` and `mac-merge-window-prints/`. No live model call is needed.

### Adjustment round — 28 October

Alexandre's list from daily use (A1–A20; contract and his pictures: `.agent-artifacts/mac-app/AJUSTES.md` and
`ajustes/` of the `mac-ajustes` worktree). Out of this round, waiting for mocks: the model window's redesign, the
project filter replacing the chips and the highlight of the open subagent.

- **Composer lines (A1).** The editor's lines are exactly the message role's reading line height (20 pt at 14 pt,
  `minimumLineHeight == maximumLineHeight`, no baseline offset); the field is a whole number of lines, grows to eight
  and then scrolls. The cut first line came from measuring: SwiftUI asks the editor's height at several widths, and
  each answer resized the field's own text container, so the text could stay wrapped narrower than the field, taller
  than measured, and scrolled to the caret. `NSTextView.textHeight(width:lineHeight:)` now measures other widths on
  a copy, `ComposerInputView.tile()` returns to the top once everything fits, and the placeholder is drawn by the
  text view on its first line with the same font and line height. No automatic content insets.
- **Reading column (A2).** At most 960 pt including the message icons, centered, at least 28 pt from each side:
  about 125 characters per line at 14 pt, past which the eye loses the next line, while a large window gives the
  chat far more than the old 760 pt. The composer follows the same column. Answers start after a 34-pt gutter
  whose first item carries the OpenCode mascot (`OpenCodeMascot`, the app icon's artwork, still, 24 pt, top
  aligned); prompts end before it, with the session's project avatar of Sessões (`MacPromptAvatar`, its icon or
  monogram). `MacTranscriptContext.responseStarts` marks the first answer item after each prompt.
- **Contexto's width (A2).** The divider goes from 400 pt to 60% of the window, never squeezing the chat below its
  minimum (`DesktopWindowState.contextWidthRange`). Each window saves its width as before; the end of a drag also
  stores it as the default for windows without saved state, which covers macOS closing the windows on quit
  ("Fechar janelas ao encerrar um app").
- **Questions (A3).** The question card's own answer is a native text view on the Mac (`MacReplyField`): a click
  focuses it, Return sends (like Enviar, when the answer is complete), Shift+Return or Option+Return break the line,
  Esc leaves the field. A multiple choice's own answer adds with Return.
- **Title (A4, A9).** No popover and no `⌄`: the title is a label. The bar is the regular unified height, so the
  avatar and the two title lines center on the window buttons with room around them.
- **Sessões (A5, A7).** Voice, Ajustes and Nova sessão sit at the column's right edge (a flexible space in the
  sidebar's toolbar, like Mail's); collapsing the column hides them with it, as Mail and Notes do: Nova sessão stays
  at the bar's end (and ⌘N), Ajustes is ⌘, and Ir ▸ Conversar por voz starts the call. Rows start 14 pt from the
  column's edges instead of 24 (`AppLayout.margin` is 6 pt on the Mac, plus the list's own 8 pt).
- **Scroll bars (A7).** `MacThinScroller` (`MacScrollers.swift`) draws every scroll bar of the app (transcript,
  composer, Sessões, Contexto, Arquivos and its files, prompts, the question field): half the system's thickness, no
  track, a `labelColor` knob at 22% (38% while dragged). AppKit still picks the style from Ajustes do Sistema ▸
  Aparência ▸ "Mostrar barras de rolagem": overlay bars appear while scrolling and fade, "Sempre" keeps them (thin).
  SwiftUI scroll views get it through `.macThinScrollers()`, which finds the enclosing `NSScrollView`; the
  transcript no longer forces the overlay style.
- **Subagents (A6).** Each row's second line is `agent · Modelo · esforço` (`ContextColumn.runLabel`, from the
  child's latest agent and model, as the iPhone shows since `f6f8892302`), then `agora: …`. The cost column is 80 pt
  and shows the whole value; when it does not fit, `US$ 2,7 mil` (`ContextUsage.compactMoney`), never an ellipsis.
- **Dictation (A8).** No review sheet: the transcript lands in the composer at the caret and the editor takes the
  focus; recording, locked, paused and preview stay in the card. The **right Option key** (keyCode 61 only) dictates
  into the front window's conversation composer (`MacDictationKey`, a local event monitor, so only while the app is
  in front; the rules are `DictationKeyGesture`): a tap starts hands-free recording and the next tap stops; held
  past 250 ms it records until release (a hold shorter than one second keeps recording hands-free, like the
  microphone button). Pressed with ⌘, ⌃, ⇧ or the left Option, or followed by another key or a click while down, it
  is a modifier and does nothing (a recording its hold had started is discarded). Not while a sheet covers the
  window or a GPT Live call holds the microphone. ⌃⌥Espaço in the editor still works.
- **Quotes (A10).** A quote still in the draft opens as `Citação · N` already editing its comment, with the focus in
  it; Ir ao trecho citado and Remover citação stay. Return or ⌘Return concludes, Esc closes. Sent marks keep the
  details sheet.
- **Arquivos (A11).** It replaces Contexto with no animation. The path is absolute from `/`, every part clickable;
  one that does not fit loses its middle parts (`/ › … › OpenCode › SessionColumn`), with the whole path as tooltip
  and a copy button.
- **Resources (A12).** In use (an agent or you in control): large thumbnails with a thin outline, one on the whole
  width, more in two columns, `Simulador iOS · iPhone 17 Pro` and `Agente usando · <subagent>` in small gray. Free
  and stopped: compact rows with a small thumbnail. A click opens the resource's window; hovering shows Abrir,
  Captura (the current frame at full size, saved with a panel) and Encerrar. The server has no way to stop a
  resource, so Encerrar takes it off the lists (`custom.resources/dismiss`; it returns when an agent uses it again).
  Snapshots follow the iPhone's `ResourceThumbnails`, about every 5 s for resources in use; free and stopped ones keep
  their first picture. They stop while the section is off screen (Contexto hidden, Arquivos over it) and while the
  window is minimized or fully covered. Measured in the fixture (two resources in use, 60 s, the app copy's process
  CPU, two runs each): about 22–24 snapshots a minute, and 10.2 / 13.3 s of CPU against 9.2 / 13.3 s with the
  first pictures only, a difference inside the run-to-run noise; Arquivos over the column and a minimized window
  took 0 snapshots. The fixture's idle CPU (spinners and live rows) is the same as before this round (15.1 s on the
  base build in the same minute).
- **↓ (A13).** In the empty margin right of the reading column, just above the composer, when it is at least 50 pt;
  otherwise on the composer card's top right corner, mostly above its edge. It shows only when the iPhone's rules say
  so (`TranscriptState.jumpToLatest`).
- **Images (A14).** The viewer has Copiar imagem (⌘C, PNG and TIFF on the clipboard) and shows the original file;
  an image in the chat and in the viewer has Copiar imagem in its right-click menu and drags out as a PNG file.
- **Image viewer (29 October).** `MacImageScrollView` puts the original in one layer of a magnifying `NSScrollView`:
  100% is one image pixel per screen pixel, from 10% (or the fit) to 1600%, mipmapped when reduced and with hard
  pixels from 200%. A mouse's wheel and ⌘ + scroll zoom smoothly around the pointer; the trackpad's and Magic
  Mouse's scroll pans with inertia and their pinch zooms; dragging pans (open/closed hand); a double click or a
  two-finger double tap switches fit ↔ 100% at that point; ⌘+/⌘=, ⌘−, ⌘0 (fit), ⌘1 (100%, ahead of Ir's ⌘1 in this
  window), the arrows (⌥ pages) and Esc, listed under Imagem in ⌘/. The bar: − % + (the percentage fits), Ajustar,
  Tamanho real, Copiar imagem, Fechar; the right-click menu repeats the zoom. A resize keeps the fit, or the middle
  of a manual zoom. Dragging out moved to the title bar's icon (the window's represented PNG, always copied) and ⌥ +
  drag. A click outside still closes it, but not during a pan, a drag out or with the menu open. The glass
  "Copiar imagem" pill seen over the image was that menu with its only item: macOS 27 hides menu images, so a
  one-item menu is a pill. `-OpenCodeMacAjustes viewer` checks it on a 4800×3600 board. Arquivos still shows images
  with Quick Look.
- **Contexto's figures (A15).** Context first, with its ring before the number (centered on the number and its
  caption), then cache hit, then cost.
- **Composer row (A16).** The usage line under the composer is gone (context and cache are in Contexto and the
  title's ring); the agent is a capsule beside the model's, in the same style (fixed for a subagent and the master).
- **Sessão mestra (A17).** The iPhone's trash on the master conversation, in place of `…` (and Sessão ▸ Reiniciar
  Sessão mestra): the same `resetMaster` (archive and clear, no confirmation, the toast "Sessão mestra arquivada"),
  then Nova sessão in its master mode, like the iPhone's empty master screen.
- **⌘1…⌘9 (A18).** Ir lists the first nine rows of Sessões in the front window, with its filter, chip and collapsed
  sections (`SessionNavigation.numbered`).
- **Arquivadas (A19).** A search field at the top (focused on open, ⌘F) filters by title, project and path, ignoring
  case and accents (`ArchivedSessionSearch`, with the app's `TextFolding`, also used by the composer's suggestions).
- **Modelo e esforço (A20).** It was slow because every model of the catalog was built at once (an eager `VStack`
  of rows and effort capsules) and each row looked up its provider by a search. `ModelChoices` now builds the rows
  once per opening (provider names from one dictionary) and the list is lazy; the picker's look is unchanged, and
  the same source is ready for the redesign. With `-OpenCodeMacLargeCatalog 300|600 -OpenCodeMacModelPicker`
  (`MacPickerTiming`): request → sheet appeared went from 367–398 ms (300 models) and 728–763 ms (600) to 23–28 ms;
  request → first idle main-thread turn from 1.06–1.08 s and 1.65–2.09 s to 0.34–0.36 s, mostly the sheet's own
  animation. The Mac still lists every enabled model (the iPhone lists the visible ones); that is the redesign's call.

**Checks.** `MacAdjustmentsTests` (cost format, ⌘1–⌘9 order, archived search, remembered width and its range,
absolute breadcrumb, run label, model rows, the right Option key's rules). `script/test-mac-ajustes.sh` runs
`MacAjustesChecks` (`-OpenCodeMacAjustes composer|question|quote|image|archived|numbers|width|dictation|jump|master|divider`)
in the fixture through real AppKit events: line heights, wrapping width and scroll position with one line, three,
tokens and twelve; a click, Shift+Return, Return and Esc in a question; a pending quote opening focused, Return and
Esc; ⌘C in the viewer (the clipboard is restored afterwards) and the drag provider; the archived search; the Ir
menu's ⌘1–⌘9 and ⌘2; Contexto at 60% of a 2400-pt window; the right Option key's tap, hold, left Option and
modifier cases with the fake recorder (no microphone); ↓ in both places; the master's trash. Each writes captures.
`MacStress` now activates the app first (the search panel hides while another app is in front) and drags Contexto
to 1400 pt as well; `-OpenCodeMacResourceProfile visible|frozen|minimized` and the fixture's `MacResourceSnapshot`
lines measure the previews. While someone uses the Mac, macOS may refuse to bring a test copy to the front: then
the search panel check of `test-mac-window.sh` and the ⌘1–⌘9 check (menu commands follow the key window) can fail
with the right geometry; failures now print whether the app and the window were in front. The base build
(`fadcd1420a`) failed the same way in 2 of 3 runs under those conditions.

### Pergunta paralela — 29 October

- **Entry points:** the selected text's right-click menu in an answer (**Pergunta paralela…** right after Comentar…,
  wherever Comentar is offered), the title bar's `…`, Sessão ▸ Pergunta paralela… and **⌥⌘B** (`MacShortcut.sideQuestion`,
  listed in ⌘/). They all call `MacWindowRuntime.askSideQuestion(quote:text:submit:)`, which presents over that window
  only and never over another sheet. `/btw` still sets the shared `ConversationStore.sideQuestion`; the key window
  showing that conversation moves it into its runtime, so a second window on the same Session does not open it too.
- **Sheet** (`OpenCodeMac/MacSideQuestionSheet.swift`): the iPhone's `SideQuestionState` and `SideQuestionBubble`
  (`SideQuestionSheet.swift`, now shared; its iPhone view stays in `#if os(iOS)`), so the request, history, Parar,
  retry and toast are the iPhone's. A selection prefills the field with its blockquote, shown as a `QuotedPassage` in
  the sent bubble; answers use the chat's Markdown (`MacMarkdownText`) with Copiar resposta. The field is
  `MacReplyField` (Return asks, Shift+Return breaks the line, Esc closes); Fechar, Esc and a click outside discard
  the thread. Like the iPhone, `POST /generate` answers at once (no stream) and nothing reaches the conversation.
- **Fixture:** `/generate` returns a local Markdown answer; `-OpenCodeMacSideQuestion <question>` opens the sheet
  about a sample passage for the capture pipeline.

### Main-thread cost with sessions streaming — 29 October

Typing lagged slightly with many agents streaming; a 3-s `sample` of the installed app showed its main thread busy
about 70% of the time, mostly laying the window out and updating SwiftUI, with `SessionStore.rows` rebuilt by every
reader (`MacChatTitle` alone read it eight times per update). What it did:

- **Repeating SwiftUI animations** re-rendered the whole window's hosting view every frame, even idle: the running
  rows' and chips' `RunningArc` and Contexto's subagent spinner. They are now `MacSpinningArc`, a layer animation the
  render server runs (`MacSpinner.swift`).
- **Every key re-laid the window out:** `textDidChange` invalidated the composer's size on each key. It now does so
  only when the height SwiftUI was given for the field's width (`ComposerInputView.measuredHeight`) changes.
- **List reloads re-evaluated too much:** `SessionStore.rows` and `filtered` are built once per change of their inputs
  (each input's `didSet` drops them; every read still touches the inputs, so observation is unchanged); the window
  reads the rows only in `MacSelectionKeeper`; the chat column no longer builds its title's values (`MacChatTitle` reads
  them, and only `MacChatAvatar` reads the usage, which every delta changes); the LLM proxy rings sit in a view without
  closures, so a list change does not rebuild their projections; each Sessões row is a `MacSessionRowCell`, whose body
  (highlight, menu, subagent tree) runs only for rows on screen; equal previews are not rewritten, and
  `SessionDirectoryCache`/`LocatedDirectory` are `Equatable`, so an unchanged reload publishes nothing.
- **Each streamed delta re-evaluated the conversation view**, which read `revision` for the search; that is now the
  background `MacSearchFollower`.
- `ContextColumn.subagents` indexed the family's parents for every member it checked (cubic in the family's size);
  it indexes them once (same results).

`-OpenCodeMacPerf` (DEBUG, with the fixture) measures it: 207 sessions, then six sessions (three roots, three subagents
of the shown root; `-OpenCodeMacPerfShown` adds the shown root) streaming text at 25 Hz each through
`EventHub.inject`, with one structural event per session a second. Phases: quiet, streaming, 50 keys through
`window.sendEvent`, and 50 keys while streaming. Each prints the main thread's CPU share (`thread_info`), the lateness
of a 10-ms main-queue ping, the `body` evaluations per second (or per key) of the main views, and per key the CPU and
wall time of `sendEvent` plus the layout and display it leaves; `-OpenCodeMacPerfHold <s>` lengthens the phases for a
`sample`, `-OpenCodeMacPerfKeys <n>` the typing. Medians of three interleaved Debug runs per side on the shared Mac
(load 9–190), before → after:

| Phase | Main-thread CPU | Ping p95 | Per key (CPU p50/p95) |
| --- | --- | --- | --- |
| Quiet | 24% → 1% | 1.7 → 0.1 ms | |
| Streaming | 34% → 10% | 36 → 2.3 ms | |
| Typing | 33% → 5% | 7.3 → 0.7 ms | 8.1/9.7 → 1.3/1.8 ms |
| Typing while streaming | 41% → 13% | 276 → 15 ms | 5.9/10.9 → 1.4/1.9 ms |
| Shown root streaming too | 50% → 41% | 28 → 8 ms | |

A key re-evaluates no `body` of `MacWindow`, `MacChatColumn`, `MacConversationView`, Sessões or Contexto, before or
after. While streaming, `MacWindow` went from 0.3 evaluations a second to none and, with the shown root streaming,
`MacConversationView` from 23 to 1.5 and the transcript host's update from 23 to 2; what remains there is the
transcript's own rebuild of the growing answer. These are shared-machine Debug samples, comparable with each other only.

**Round 2: the open conversation streaming.** With the shown root answering, the window was laid out and the
transcript rebuilt on every delta, and the transcript grew with the conversation's length. What changed:

- **Secondary information is sampled** (`MacSampled`, in `MacConversationInput.swift`): the title ring's context share
  and the tray's execution start read the transcript, which every delta changes; they are republished at most every
  200 ms and only when they change (the last change always lands). The tray takes the sampled start through
  `ConversationTray(started:)` (iOS still reads it from the messages). The search follows the revision only while it
  is open.
- **Transcript** (`MacTranscriptController.swift`): at most 30 rebuilds a second (was 60; the last change always
  rebuilds); `TranscriptProjection.Cache` reuses each response's items while its inputs (activity entry, marks, gap,
  each text's completion, divider and parse, disclosures) are unchanged; items are compared once, index by index, and
  unchanged unmeasured items keep their estimate instead of being estimated again; the reading identities are built
  once per change. `-OpenCodeMacPerfVerify` checks every cached projection against a full one. The growing block's
  `fittingHeight` no longer resets the text container's size (which laid the whole text out again); off screen it was
  already neither configured nor measured.
- `TranscriptMarks` finds each calendar day once instead of asking the calendar about every message, and counts texts
  without building arrays (same marks; OpenCodeKit's 616 tests pass). The composer keeps its heights per width until
  its text changes, so a window layout no longer lays out a copy of the draft for every width SwiftUI asks about.
  `ContextColumnStore` matches events against a set kept with its members.

`-OpenCodeMacPerfLong <n>` adds `n` earlier turns to the root, served in pages of the requested size; the run loads
them all (`older()`) before measuring. `-OpenCodeMacPerfScrolledUp` measures with the reader away from the end.
Medians of two interleaved runs per side, before → after (main-thread CPU, the shown root streaming):

| Scenario | Debug | Debug `-O` |
| --- | --- | --- |
| Short conversation, streaming | 39.5% → 36% | 39% → 34% |
| Short conversation, typing while streaming | 43% → 38.5% | (noisy) |
| 300 turns (905 messages), streaming | 89.5% → 74% | 62.5% → 46.5% |
| 300 turns, typing while streaming | 86.5% → 52.5% | 64% → 24.5% |

Rebuilds went from 45 to 29 a second; `MacChatAvatar` from 23 evaluations a second to none. Still open: the
growing block's TextKit 2 view replaces its layout fragment views on every update, and since the transcript sits in
SwiftUI's constraint-based host, each change invalidates the window's root layout (`constraintsDidChangeInEngine` in
`AppKitPlatformViewHost`); `ConversationActivity.project` and the Markdown parse of a long answer remain whole-history.

## Platform and distribution

- **Only the latest iOS.** The deployment target is always the current major version (iOS 27 today) and moves up with
  each new major release. There is no support for older versions: use the newest APIs directly, without
  `#available` branches or fallbacks.
- **Private TestFlight only.** Builds go to an internal testing group in App Store Connect with automatic
  distribution, so every processed build reaches the iPhone without Beta App Review. App Store requirements (review
  guidelines, public privacy disclosures, screenshots) do not apply.
- **Signing:** Alexandre's personal Apple Developer team (`ERRYZ68LX5`), with automatic signing. The app carries
  the HealthKit and Push Notifications (`aps-environment`) entitlements (`OpenCode/OpenCode.entitlements`), so device
  builds need `-allowProvisioningUpdates` with the App Store Connect API key (Xcode has no signed-in account) to obtain
  the explicit App ID profile.
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
  one selection. Pinned and "Avisar ao terminar" sessions are global.
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

Servers before "Avisar ao terminar" lack the `sidebar.notify` preference intent. Its rejection gets an explicit pt-BR
"Atualize o servidor para usar o aviso ao terminar." notice; no local-only bell or successful mutation is fabricated.
Missing `notifySessions` still decodes normally and is not treated as a capability flag, since it is optional even in
the newer contract.

Debug simulator builds accept `-OpenCodeNativeTranscript` to skip the optional RPC and exercise the **same native
reader used by fallback**, including Sessões previews and older pages. The switch and its state are excluded from
Release compilation. Always keep the explicit sandbox URL/password when using it. After `build-for-testing`, run
`python3 packages/ios-custom/script/test-transcript-compatibility.py` to compare both paths on existing seeded tools,
reasoning, child history, image attachment, compaction, older-page search and pending permission/question cards. The runner
does not answer requests, send prompts, reset seeds or change service lifecycle; it exports dark screenshots to a unique
`$TMPDIR/opencode/ios-native-transcript-*` directory and deletes its credential-bearing xctestrun file.

## Notifications

**Session alerts (rev. 29/10).** The server pushes, with no switches besides the bell: questions (at once) and
permissions (still pending after 3 s, auto-approval off) of any session, one per request; a failure that stops a
session (provider retries do not count); a success only with "Avisar ao terminar"; never a user interruption. All
`interruption-level: active`, so the Focus decides. Contract:
[`plugin-app-custom/docs/session-notifications.md`](../plugin-app-custom/docs/session-notifications.md).

1. **Permission:** never at launch. Asked the first time a bell is turned on (`SessionNotificationAgent.authorize()`),
   or once, the first time a question or permission waits while notifications were never asked: an alert "Avisar
   quando precisarem de você?" with a one-line explanation, "Agora não" or "Ativar" (answered once, `shouldOffer()`;
   off in sandbox runs unless `-OpenCodeNotificationOffer`). That is the moment the alerts are useful, and it costs
   one tap only when he is already looking at a request.
2. **Registration:** with permission, `registerForRemoteNotifications`; the hex token, the device ID, the server key
   and the APNs environment go to `custom.notifications/register` on every event-stream connection (several devices
   are supported; APNs-invalid tokens are dropped by the server).
3. **Delivery (plugin):** through the Live Activity APNs client and credentials, `thread-id` = session,
   `apns-collapse-id` = `attention:<session>` for attention alerts. The Agentes Live Activity update for a device
   registered here carries no `alert`, so nothing buzzes twice; unregistered devices keep it as the fallback.
4. **Presentation (`willPresent`):** hidden only with the app in the foreground and that session open on the same
   server (`SessionPushAlert.presents`); otherwise banner, list and sound. While the server pushes, the in-app banner
   skips what arrives by push (questions, permissions, failures, bell finishes).
5. **Opening:** a tap follows the alert's `AgentsDeepLink` (server key, session, directory), the Live Activity route;
   with a `requestID` (also `request=` in the URL) the conversation opens at its end, where pending requests sit,
   even if it was left scrolled up.

Verification: `swift test` (`SessionNotificationTests`, `SubagentAlertTests`), `script/test-session-notify.py`
(fresh simulator, both themes: rows, swipe, menu, bell off, the deep link a tap follows, and a real pending permission
opened from the link at the request) and, for the server half, `plugin-app-custom/script/e2e-session-notifications.ts`
against a sandbox with `OPENCODE_APNS_ORIGIN` pointing at `script/fake-apns.ts` (real Luna 6/low runs: success with and
without the bell, a question, permissions, failures with and without retries, the Live Activity without an alert).
Fresh iOS 27.0 simulators on this Mac never start SpringBoard's `com.apple.usernotifications.usernotificationservice`:
there `getNotificationSettings`, `requestAuthorization` and `simctl push` hang, so the permission prompts, `willPresent`
and a real banner tap are verified by unit tests and on a device only.

TestFlight builds use the **production** APNs environment (`api.push.apple.com`), while builds installed from Xcode
use **sandbox** (`api.sandbox.push.apple.com`). Store the environment with each token. The Agentes Live Activity below
already uses this channel.

### Live Activity "Agentes" — 27 October

One informative Live Activity per server (Lock Screen and Dynamic Island) summarizes its agent sessions: the focus
session with a system timer, its activity and subagent progress, the pending questions/permissions, and the counts.
There are **no buttons and no Live Activity intents**; tapping opens the app. The contract, fixtures and rendering
rules are in [`plugin-app-custom/docs/live-activity.md`](../plugin-app-custom/docs/live-activity.md); the backend owns
which sessions count and every push decision, the app owns the UI, tokens and local updates.

- **Types:** `AgentsState` (OpenCodeKit, `AgentsActivity.swift`) mirrors the content state with epoch-millisecond
  numbers (ActivityKit decodes push `Date`s with its own reference date) and computed `Date`s, tolerating omitted or
  `null` optionals and unknown `unit`/`status`/`kind`. Its presentation helpers (minimal priority, compact
  `attentionTotal/activeTotal`, the expanded header with `precisa`/`precisam`, the footer plurals, pending titles,
  row labels) are pure and tested. `AgentsActivityAttributes` (`VoiceShared/`, shared with the widget extension) is the
  APNs `attributes-type`; its `theme` carries `ThemeRole` names → `#RRGGBBAA` (the 12 required roles plus `info`).
- **Widget:** `AgentsActivityWidget` in `VoiceActivityBundle`. Heights are deterministic: the expanded Dynamic
  Island proposes an unbounded height and clips on device (the first `ViewThatFits` version cut a row on the iPhone
  17 Pro Max), so every block has a fixed frame from `AgentsLayout` (OpenCodeKit). A ruler measured 110 points for
  the island's bottom region on iPhone 17 Pro and Pro Max, with the rounded corners biting from about 95; the island
  uses a 96-point ceiling: an 18-point header and up to three single-line 20-point rows (avatar, truncating title,
  project, status), plus a `+N` line only when it fits.
- **Lock Screen, "ring and counters" (rev. 27/10, mock `v3-opcao-3-anel-contadores.png`):** the card summarizes every
  session and no longer singles out the focus session. Below the unchanged header, a closed 72-point ring (7-point
  stroke) splits into arcs proportional to working, question, permission, failed and recently finished (dimmed)
  counts, with `activeTotal`/`ativas` in the centre; to its right one 18-point line per non-zero count (at most 4,
  `concluídas há pouco` dropped first). A 16-point attention line (kind dot, first title, `há N min.`, `+K`) follows
  only when a request is pending. Totals: 121 points, or 150 with the attention line (Apple: may truncate above 160).
  The arcs, counters, plurals and `+K` are pure `AgentsState` functions (`gauge`, `counters`, `attentionLine`).
  The system-updated `há N min.` keeps a fixed 64-point width and no `fixedSize`: grouped under one, the Lock Screen
  failed to archive the card and showed it empty. `AgentsActivityRenderTests` checks rendered heights equal the
  computed ones.
- **Não lidas (rev. 28/10):** with `counts.unread` (newer backends), the ring's fifth arc is orange (`primary`) for
  unread sessions, the counter reads `N não lida(s)` (orange dot) and `idle` rows read `Não lida` in the expanded
  island, the Smart Stack card and the watch Painel; the watch complication and Painel ring use the same orange arc.
  Without `unread` (older backends) everything keeps `idle`: gray arc, `concluídas há pouco`, `Concluída`
  (`AgentsState.Counts.finished`, `AgentsState.statusLabel(_:)`).
- **Apple Watch:** the Lock Screen closure branches on `activityFamily`; `.supplementalActivityFamilies([.small])`
  shows the mascot inside a segmented subagent ring (up to 8 segments, a continuous arc above), the minimal island's
  `!N`/`?N`/hand badge and the first two sessions, in fixed metrics for the smallest Smart Stack (152 × 69.5 points).
  The mascot is drawn as a vector shape in theme colors, so the extension needs no image asset.
- **Driver:** `OpenCode/LiveActivity/AgentsActivityAgent.swift`. The main-actor agent forwards each event-stream
  connection (launch and every foreground) and `rpc.custom.live-activity.changed` (routed by `EventHub` like
  `custom.device`, never to screens) to the `AgentsActivityDriver` actor, which does all ActivityKit and RPC work. On
  each connection: `register` (`deviceID` from `custom.device`, `serverKey`, `environment`, `theme`,
  `pushToStartToken`), then `snapshot`. It watches `pushToStartTokenUpdates` (re-registering on change),
  `activityUpdates` (activities started by push), each activity's `pushTokenUpdates` (`activity`) and
  `activityStateUpdates` (`ended` with `ended`/`dismissed`). Tokens and endings of another server wait until it is the
  active one.
- **Local updates:** with the app running, a non-null state starts the activity (`pushType: .token`, falling back to
  a local-only activity) or updates it; a null state ends it at once with `.immediate` dismissal, never leaving an
  idle-only card (the backend's `end` push also dismisses immediately). A swiped-away activity is
  not restarted locally until `activeTotal` returns to 0. While APNs is `unconfigured` this is the only update path.
- **Duplicates (rev. 27/10):** at most one activity per `serverKey` on screen, in any state. At launch (also the
  background launch after a push-to-start, `AgentsActivityAgent.watch()`), on every connection, on each
  `activityUpdates` element and before a local start, `AgentsDuplicates.toEnd` keeps the newest live activity; the
  others, including ended cards still visible, end with `.immediate` dismissal and are reported as `ended`.
- **Server key:** the saved server's ID (`builtin` for the Mac); with a launch override (sandbox runs) the built-in
  entry becomes `launch-<host>-<port>`, so a sandbox never adopts the real server's activity.
- **Environment:** the simulator is `sandbox`; on a device the app reads its `embedded.mobileprovision`:
  `aps-environment` `development` (or `get-task-allow` without it) is `sandbox`; App Store Connect builds
  (TestFlight) carry no embedded profile and are `production`. This follows the signing that actually happened,
  unlike a `DEBUG` flag (a Release build installed from Xcode still uses the sandbox).
- **Older servers:** `rpc.method_not_found`, `rpc.unavailable` or 404 make the driver silent until the next
  connection; no error reaches the UI. Other failures retry on the next connection.
- **Deep links:** `br.com.alexandrem.opencode://session?server=<serverKey>&id=<sessionID>&directory=<dir>` and
  `…://sessions?server=<serverKey>`. The card opens the first attention session, else the focus, else Sessões; pending
  rows and expanded-island rows link to their own session. Opening switches to that saved server when needed, selects
  Sessões and pushes the conversation (which resolves its Location from the Session; `directory` is informative).
- **Configuration:** `aps-environment` in `OpenCode/OpenCode.entitlements` (automatic signing adds Push Notifications to
  the App ID; export for TestFlight switches it to `production`), `NSSupportsLiveActivitiesFrequentUpdates` and the
  URL scheme in `Info.plist`. The APNs key, its ID and the backend configuration are not part of the app; until they
  exist the backend answers `push: "unconfigured"`.

Verification uses only the **OpenCode LiveActivity** simulator (iPhone 17 Pro, iOS 27) and
`$TMPDIR/opencode/ios-liveactivity-derived`, with no server. `swift test --filter AgentsActivityTests` decodes every
contract fixture (including the `push-*.json` content states and attributes, read from the plugin docs) and checks
the presentation rules. The hosted `OpenCodeTests/AgentsActivityRenderTests` renders the production views with
`ImageRenderer`, checks that a density fits 160 points and the island rows fit, and renders the minimal island, which
the simulator never shows for a single app. The DEBUG-only `-OpenCodeAgentsActivityFixture <names>` (comma-separated
`state-*` names of the contract, embedded verbatim and shifted to the current time; not compiled in Release) starts
local activities and keeps the app off every server. `OpenCodeUITests/AgentsActivityCaptureTests`, with
`TEST_RUNNER_OPENCODE_AGENTS_FIXTURE=<names>` and `TEST_RUNNER_OPENCODE_CAPTURE_DIR=<dir>`, captures the compact and
expanded island and the Lock Screen (`ios-<state>-<variant>.png`). `xcrun simctl push` only delivers user
notifications, so APNs Live Activity pushes (start/update/end) need a physical device and the backend's APNs key.

## Apple Watch — 27 October

A native watchOS app, `OpenCodeWatch` (`br.com.alexandrem.opencode.watchkitapp`, watchOS 27), embedded in the iPhone
app and shipped by the same TestFlight upload, with the complication extension `OpenCodeWatchWidgets`
(`….watchkitapp.widgets`). It runs **without the iPhone nearby** (`WKRunsIndependentlyOfCompanionApp`), over the
watch's own Wi-Fi or cellular. The contract with the backend is
[`plugin-app-custom/docs/watch.md`](../plugin-app-custom/docs/watch.md); the approved references are in
`.agent-artifacts/watch/` (not versioned).

- **Pairing:** Você → Apple Watch → **Parear Apple Watch** calls `custom.watch` → `pair`, replaces the voice with the
  local preference and sends the result over WatchConnectivity (`transferUserInfo` + `updateApplicationContext`).
  The iPhone keeps nothing. The same screen lists `devices` and removes one (`revoke`, plus a WatchConnectivity
  notice so that watch clears itself). The watch stores the pairing in its Keychain, in the access group
  `ERRYZ68LX5.br.com.alexandrem.opencode.watch` (`keychain-access-groups`) so the complication reads it too.
- **Gateway client:** `WatchGatewayClient` (OpenCodeKit) sends the device token, the Cloudflare Access service-token
  headers and `User-Agent: OpenCodeWatch/<version>` on every request, and classifies failures (401 → pair again,
  404/409 → already answered, 429, HTML or no answer → "Mac indisponível"). OpenCodeKit compiles for watchOS; the
  contract types, ring, row priority, captions and storage live there and are tested with `swift test`, including a
  real local HTTP server (`WatchTests`).
- **Screens** (`OpenCodeWatch/`): Painel (ring, counts, pending requests first, sessions, Liquid Glass microphone,
  refresh every 10 s while visible and on pull), Responder (options with the recommended one first, dictation through
  `TextFieldLink`, permission decisions), Voz (CallKit call, live levels around the mascot, Sessão mestra line, last
  two captions, mute and end), plus "Sem pareamento" and "Mac indisponível". Below the ring, `Atualizado agora` /
  `Atualizado há N min.` says how old the state is (rev. 29/10). Colors are `openchamber-dark` (`WatchPalette`, checked
  against the theme JSON by `WatchPaletteTests`).
- **Complications** (`WatchShared/`, `OpenCodeWatchWidgets/`): `accessoryCircular` (proportional ring with the
  mascot), `accessoryCorner` and `accessoryRectangular`. The timeline fetches `/watch/v1/state`, caches the last good
  state in the same Keychain group and reloads on WidgetKit push, when the app updates it, and otherwise every hour.
- **Sync within the WidgetKit budget (rev. 29/10).** WidgetKit counts every complication reload outside the app in
  front (push, timeline or background request) against one daily budget, 40 to 70 for a widget looked at often; the
  server's 150 pushes a day plus a 15-minute timeline exhausted it, so only opening the app updated the complication.
  Now `WatchStateSync` (OpenCodeKit) is the one read for the app, the background refresh and the complication: it
  writes the shared cache and says whether anything changed and whether what the complication draws changed
  (`WatchComplicationKey`: the ring's counts and the two totals). The app in front reloads on any change (not
  budgeted); the **background app refresh** (`BackgroundRefresh` and `WatchAppDelegate` in `OpenCodeWatchApp.swift`,
  `WatchBackgroundRefresh`: about every 30 minutes, an 8 s read, rescheduled after each run and whenever the app leaves
  the screen) reloads only when the drawing changed; the timeline policy is 60 minutes. watchOS crashes the app on
  `scheduleBackgroundRefresh` unless the application delegate implements `handle(_:)` (seen in the simulator: SwiftUI's
  `.backgroundTask` alone is not enough), so a `WKApplicationDelegateAdaptor` receives every background task, completing
  WatchConnectivity's only once nothing is pending. Every read sends `X-Watch-Client: app|background|widget`, which the gateway counts (`custom.watch` →
  `stats`) and uses to skip pushes for a state the watch already read; the server pushes at once only for a new
  question, permission or failure or for the active total reaching or leaving zero, folds the rest into one push per
  30 minutes, and caps pushes at 40 a day ([`watch.md`](../plugin-app-custom/docs/watch.md), "Budget"). The
  rectangular complication shows the age of the state next to `OpenCode` (`agora`, then `há N min.`; a second timeline
  entry makes the switch without a reload); the circular and corner families have no room. DEBUG builds accept
  `-OpenCodeWatchRefreshSeconds N` (a shorter refresh) and the `OpenCodeWatchPairing` default (base64 JSON pairing,
  written with `simctl spawn … defaults write`) to watch a background refresh happen in the simulator; it needs a build
  signed to run locally (`CODE_SIGN_IDENTITY=-`), since an unsigned one has no keychain entitlement. The
  push token comes only to an extension with `aps-environment` (rev. 28/10: it was missing, so WidgetKit never issued
  a token and no watch registered one). `WatchWidgetToken` saves it in the shared Keychain first, then posts it to
  `/watch/v1/widget-token` when paired; the extension's `WidgetPushHandler` and every app refresh call it, so a token
  that arrived before pairing or failed to send is delivered later, and a new token, environment or pairing sends
  again. The environment follows each bundle's own signing profile (`WatchShared/WatchEnvironment.swift`).
- **Voice** follows the proven path of the 27 October spike: CallKit outgoing call (no `contactIdentifier`), audio
  and UDP only after `didActivate`, one UDP flow per remote with system-chosen interface and port, ICE seeing the
  original IPv4 pair while the sockets carry the bytes (NAT64/CLAT on cellular). The gateway creates the call,
  owns the sideband and delegation; the watch sends a heartbeat every 5 s and long-polls caption, status and master
  events. Failures post transport diagnostics to `/watch/v1/diagnostics`.
- **WebRTC engine:** `Vendor/OpenClawWatchRTC/` holds OpenClaw's `OpenClawWatchRTC` (Rust, `str0m` 0.24.1, commit
  `e5cc2d9`) and its watch transport/audio Swift with the spike's fixes, under their MIT notices (`Licenses/`, also
  bundled in the watch app). `script/setup-watch-rust.sh` installs the pinned nightly into
  `~/.local/share/opencode-ios/rust` (no global Rust, no shell profile changes). The `Build Watch WebRTC` phase runs
  `script/build-watch-rtc.sh`, which builds the current platform's slices in a clean environment and reuses finished
  archives from `~/.local/share/opencode-ios/watch-rtc-cache` by content fingerprint.
- **Simulator:** `script/capture-watch.sh <udid> <dir>` builds for the watchOS simulator and captures the DEBUG
  fixtures (`-OpenCodeWatchFixture dashboard|question|permission|voice|complications|offline|unpaired`), which never
  touch the network, Keychain or cache. The simulator has no CallKit and always allows UDP, so it proves neither the
  call nor the TN3135 policy; voice needs the physical watch.

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
  VoiceActivity/         # widget extension: voice and Agentes Live Activities
  VoiceShared/           # code shared by the app and VoiceActivity
  SharedUI/              # SwiftUI shared by the iPhone and Apple Watch targets (mascot)
  OpenCodeWatch/         # Apple Watch app
  OpenCodeWatchWidgets/  # Apple Watch complications
  WatchShared/           # code shared by the watch app and its complications
  Vendor/OpenClawWatchRTC/  # vendored watch WebRTC engine (Rust + Swift, MIT)
  OpenCodeMac/           # Mac app target: Mac-only code; shares OpenCode/ files by membership
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
- Push notifications and Live Activity pushes require a physical device. Builds installed from Xcode receive them
  only through the APNs sandbox.
- The physical test devices are shared with other agents. Reserve one through the device lease before installing or
  driving the app, and release it when you are done.
- The committed `OpenCode.xcodeproj` has one iPhone app target (`OpenCode`) with its `VoiceActivity` extension and
  the embedded Apple Watch app (`OpenCodeWatch` + `OpenCodeWatchWidgets`), the Mac app target (`OpenCodeMac`, see
  [Mac app](#mac-app-stage-1--27-october)), automatic signing for team `ERRYZ68LX5`, and a local `OpenCodeKit`
  package. Targets use synchronized folders; adding a Swift file does not require editing the project. Building the
  watch app needs the private Rust toolchain once: `packages/ios-custom/script/setup-watch-rust.sh`.
  [Private TestFlight uploads](#private-testflight-uploads) use the local script below.

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
5. The App Group `group.br.com.alexandrem.opencode` remains reserved and is not enabled: automatic signing with
   the API key cannot create or attach App Groups (Xcode reports "Authentication failed" for those targets), and
   Xcode has no signed-in account. The Apple Watch app and its complication share data through the Keychain access
   group `ERRYZ68LX5.br.com.alexandrem.opencode.watch` instead, which needs no portal capability.

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
  Raw trigger text remains plain text. `ComposerTrigger` recognizes word boundaries; `/` is only active at offset 0,
  and `&` only at offset 0 or after whitespace.
  Space, Escape and a tap in the transcript dismiss suggestions. Trigger queries disable autocorrection,
  autocapitalization and predictive suggestions; prose restores the keyboard defaults. Unselected correction
  ranges cannot replace a token.
- `ComposerSources` merges recent root sessions, mentionable agents and visible references for `@` (files moved to
  `&` on 26–28/10); supported
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
  In comments, `@`, `&`, `$`, and `#` work as in the main composer; `/` does not, as in the web.
  A sandbox UI/server check selects a file, Explore, the fixture skill and `#resumo` in the real comment editor,
  concludes, relaunches, then sends with a short main text/file mention. The comment's file/agent/skill arrive in
  structured arrays without main-text ranges; the main file keeps UTF-16 range 33–47. The model-facing `User comment:`
  expands `#resumo`, while the sent bubble preserves the authored token text. Sessions/references and snippets in
  comments also have package tests. Evidence: `comment-tokens-panel-*`, `comment-sent-*` and the sanitized
  `comment-server-verification.json` in the wave-6 final screenshots directory.
  `Citações · N` is collapsed by default above the composer card and expands to edit/remove individual quotes.
  Quotes survive relaunch through `DraftSnapshot` (old wave-3 snapshots decode with an empty quote array), restore
  from queued messages, count as sendable content on their own, and clear only after successful submission.
  Comments support the existing `@`, `&`, `$` and `#` suggestions; there is no separate binary-attachment picker in a comment.
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
`test-session-reading.py` now prepares that case itself (a fake repository with worktrees `outro` and a removed `sumiu`
holding a parent and child, deleted afterwards) and puts the non-Git missing directory outside any repository, so the
whole `SessionReadingTests` class runs from the script.

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
  are read before delivery: auto-approved permissions are not announced, and a finish of a root with "Avisar ao
  terminar" is left to the system notification while the server pushes (muting no longer exists).
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
