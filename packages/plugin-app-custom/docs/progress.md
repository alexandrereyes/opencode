# Progresso (rev. 2026-10-30)

**Progresso** is the agent's own list of steps for the work in hand: the Core `todowrite` tool, offered only while
`experimental.todo` is on (upstream PR #56947; `https://opencode.ai/v2/docs/config#todos`). Core keeps no state of its
own: the model sends the whole list on every call, and the current list is the **input of the session's latest
completed `todowrite` call before its revert boundary**. Every agent that may use tools has it, Mestra and the
subagents included; each session (each subagent too) has its own list, and a subagent's list never changes its
parent's.

The apps show it as a pill above the composer (`◔ 3/7 · current item`, Mac popover, iPhone sheet), in the Sessões
row (`trabalhando · ◔ 3/7 item…`), in the Live Activity and on the watch; Mestra reads it through `sessions.list` and
`sessions.status`. Its name in the interface is **Progresso**.

## Rules (copied from upstream's web)

Source: `packages/app/src/session/composer/todos.ts`, `todo-pill.tsx` and `region.tsx` at the integrated baseline.
`src/progress/todos.ts` (plugin) and `OpenCodeKit/SessionProgress.swift` (apps) implement the same rules and are
tested against the same cases.

| Rule           | Behavior                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Current list   | Input `todos` of the latest `todowrite` part whose state is `completed`, among the messages **before** the revert boundary (the boundary message and everything after it are ignored). A failed or running call changes nothing. A boundary that is not among the messages hides none of them.                                                                                                                                                                      |
| Items          | Entries whose `content` is a non-empty string; an unknown `status` reads as `pending`.                                                                                                                                                                                                                                                                                                                                                                              |
| Number (`3/7`) | `done` = items `completed`; `total` = every item, **cancelled ones included**.                                                                                                                                                                                                                                                                                                                                                                                      |
| Ring           | Fills `finished / total`, where `finished` = `completed` + `cancelled`.                                                                                                                                                                                                                                                                                                                                                                                             |
| Current item   | The first `in_progress` item, else the first `pending` one, else the last `completed` one, else the first item.                                                                                                                                                                                                                                                                                                                                                     |
| Visibility     | `experimental.todo` is on for the session's Location, **the work the session started goes on** (rev. 2026-11-02): it executes, or a descendant at any depth executes, or a background shell of it or of a descendant still runs; the list is not empty and at least one item is neither `completed` nor `cancelled`. So it disappears when the whole family stops. Upstream's web shows it only while the session itself executes; this is the apps' one departure. |
| Config         | The highest-priority config document that sets `experimental` decides (`Config.latest`); off hides every list, so the plans of migrated V1 sessions never come back.                                                                                                                                                                                                                                                                                                |

## Backend

"Works" is Sessões' own rule for a working family (`custom.navigation` rows, iOS `SessionList`/`FamilyWork`, the Live
Activity's `family`), taken below the session: the plugin's hub uses its running sessions and unfinished shells, the
apps their running set, the family snapshot's active descendants, each row's `backgroundCount` and the conversation's
own agents and shells. A list stays the viewed session's own: nothing is summed from its subagents' lists.

The Live Activity hub (`src/live-activity/tracker.ts`) folds the events once for every Location:
`session.tool.input.started` names the call, `session.tool.called` holds its input and `session.tool.success` makes it
the session's list. A top-level session that starts executing without a known list (resumed, or after a restart), a
rebuild, and every `session.revert.*` read the transcript newest first (up to 5 pages of 100 messages) instead. So
does a top-level session whose list is unknown when its family starts working without it: a rebuild that finds it
idle with a running subagent or an unfinished background shell, a descendant that starts executing, a shell it or a
descendant starts.

`experimental.todo` is asked of the session's own Location: each Location's plugin instance reports whether
`todowrite` is in its tool list (`ctx.tool.list()`), which is exactly the server's rule; the answer is refreshed on
every execution start and list update.

## Contracts

All additions are optional fields: older apps ignore them.

**`custom.navigation/list`** (Sessões): each row gets, while it shows,

```ts
progress?: {
  done: number        // completed items
  finished: number    // completed + cancelled (the ring)
  total: number
  current: string     // the item in hand
  todos: { content: string; status: "pending" | "in_progress" | "completed" | "cancelled" }[]
}
```

The apps take it on (re)load; with the app open they also fold the same three tool events themselves, so a row moves
without waiting for a navigation reload. The list lets a conversation whose loaded tail does not reach the latest
`todowrite` still show the whole Progresso.

**`custom.session-family/snapshot`** (rev. 2026-10-30): `progress?: Record<sessionID, Progress>`, the same shape as
the Sessões row's, for every active descendant (any depth) that shows one, for the subagent lists. A descendant that
only waits on its own subagents keeps its list in its own conversation and Sessões row. The hub folds a subagent's list from the events it saw, so after a
server restart a subagent that was already running shows its list from its next `todowrite` call (only top-level
sessions read their transcript on a rebuild or an execution start). Absent when no descendant shows one.

**Mestra (`tools.sessions.*`)**: `list` rows get `progress?: { done, total, current }`; `status` gets
`progress?: { done, total, current, items }` with every item and its status. Mestra's prompt says how to speak it
("concluiu 3 de 7; agora: …") when asked and in the running summary.

**Live Activity and watch** ([live-activity.md](live-activity.md), [watch.md](watch.md)): a session with a Progresso
sends `progress: { done, total, unit: "todos", current }` instead of the subagent count. The watch reads the same
state from `/watch/v1/state`; the complication's key is unchanged.

## Apps

- The `todowrite` calls themselves stay out of the conversation's Atividade (and of the final-answer boundary): the
  pill is their representation, and a dozen list updates per task would only split the activity groups. A failed call
  stays visible, like any failed tool.
- The subagent lists (the iPhone's "Agentes e tarefas" and the Mac's Contexto) show each subagent's `☑ 2/4` from
  the family snapshot, with the list the app folded from live events winning, as it is newer; before, a list written
  before the app opened (or, on the iPhone, while it was suspended) showed only from the subagent's next call.
- Builds without the feature keep hiding the calls and show `Trabalhando · 3/7` on the Live Activity (an unknown unit
  is a bare `done/total`), with no `Agora: …`.

## Tests

Plugin: `test/progress.test.ts` (rules, tracker, revert, rebuild, Location gate, push size and grouping),
`test/navigation.test.ts`, `test/sessions.test.ts`, `test/session-family.test.ts`, the normative `live-activity/state-progress.json`. Apps:
`OpenCodeKitTests/SessionProgressTests.swift` and the Live Activity and UI tests listed in the iOS README.
