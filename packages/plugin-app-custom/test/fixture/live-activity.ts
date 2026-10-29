import { Effect, Schema } from "effect"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { makeTracker, type Event, type TrackerContext } from "../../src/live-activity/tracker"

/** Fixture clock: 2026-10-27 09:41 BRT, the `updatedAt` of the contract fixtures. */
export const T = 1793104860000
/** `focus.startedAt` of the fixtures. */
export const T0 = 1793104136000
export const minute = 60_000

export const ids = {
  live: "ses_01JZLIVEACTIVITY0000000001",
  cache: "ses_01JZCACHEDATABASE000000002",
  oauth: "ses_01JZOAUTHLOGIN000000000003",
  nav: "ses_01JZNAVIGATIONREVIEW000004",
  deploy: "ses_01JZDEPLOYSWARM00000000005",
  idleA: "ses_01JZIDLEA0000000000000006",
  idleB: "ses_01JZIDLEB0000000000000007",
}

const meta: Record<string, { title: string; directory: string; subpath?: string }> = {
  [ids.live]: {
    title: "Live Activity no iOS",
    directory: "/Users/alexandremartins/Worktrees/opencode2-live-activity",
    subpath: "packages/ios-custom",
  },
  [ids.cache]: {
    title: "Escolher banco do cache",
    directory: "/Users/alexandremartins/Dev/opencode2",
    subpath: "packages/core",
  },
  [ids.oauth]: {
    title: "Corrigir login OAuth",
    directory: "/Users/alexandremartins/Worktrees/opencode2-oauth-login",
    subpath: "packages/app-custom",
  },
  [ids.nav]: {
    title: "Revisar navegação",
    directory: "/Users/alexandremartins/Dev/opencode2",
    subpath: "packages/app",
  },
  [ids.deploy]: { title: "Deploy no Swarm", directory: "/Users/alexandremartins/Dev/core-infra" },
  [ids.idleA]: { title: "Atualizar dependências", directory: "/Users/alexandremartins/Dev/opencode2" },
  [ids.idleB]: { title: "Limpar worktrees", directory: "/Users/alexandremartins/Dev/opencode2" },
}

export async function fixture(name: string) {
  return JSON.parse(await Bun.file(new URL(`../../docs/live-activity/${name}.json`, import.meta.url)).text())
}

export function created(sessionID: string, at: number, parentID?: string): Event {
  const info = meta[sessionID] ?? { title: `Subagente ${sessionID}`, directory: meta[ids.live].directory }
  return {
    type: "session.created",
    created: at,
    data: {
      sessionID,
      ...(parentID ? { parentID } : {}),
      title: info.title,
      location: { directory: info.directory },
      ...(info.subpath ? { subpath: info.subpath } : {}),
    },
  }
}

export function execution(outcome: "started" | "succeeded" | "failed", sessionID: string, at: number): Event {
  return { type: `session.execution.${outcome}`, created: at, data: { sessionID } }
}

export function interrupted(sessionID: string, at: number): Event {
  return { type: "session.execution.interrupted", created: at, data: { sessionID, reason: "user" } }
}

export function tool(sessionID: string, at: number, call: string, name: string, input: Record<string, unknown>) {
  return [
    { type: "session.tool.input.started", created: at, data: { sessionID, id: call, name } },
    { type: "session.tool.called", created: at + 1, data: { sessionID, id: call, input } },
  ] satisfies Event[]
}

export function session(sessionID: string, extra: Record<string, unknown> = {}) {
  const info = meta[sessionID] ?? { title: sessionID, directory: "/repo" }
  return Schema.decodeUnknownSync(Session.Info)({
    id: sessionID,
    projectID: "prj_global",
    location: { directory: info.directory },
    ...(info.subpath ? { subpath: info.subpath } : {}),
    title: info.title,
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    time: { created: T - 3 * 3_600_000, updated: T - 3 * 3_600_000 },
    ...extra,
  })
}

export function question(id: string, sessionID: string, at: number, text: string): Form.Info {
  return Schema.decodeUnknownSync(Form.Info)({
    id,
    sessionID,
    title: "Questions",
    created: at,
    metadata: { kind: "question", tool: { messageID: "msg_1", id: "call_q" } },
    fields: [{ key: "q0", type: "string", title: "Pergunta", description: text, options: [], custom: true }],
  })
}

export function permission(id: string, sessionID: string, at: number, action: string, resources: string[]) {
  return Schema.decodeUnknownSync(Permission.Request)({ id, sessionID, created: at, action, resources })
}

/** An in-memory server: sessions, the running set, pending requests and latest user messages. */
export function world() {
  const infos = new Map<string, Session.Info>()
  const active = new Set<string>()
  const forms: Form.Info[] = []
  const permissions: Permission.Request[] = []
  const prompts = new Map<string, number>()
  const transcripts = new Map<string, SessionMessage.Info[]>()
  const watched = new Set<string>()
  const settings: { autoApprove: boolean; master?: string } = { autoApprove: false }
  const reads: string[] = []
  const ctx: TrackerContext = {
    session: {
      get: ({ sessionID }) => {
        reads.push(sessionID)
        const found = infos.get(sessionID)
        return found ? Effect.succeed(found) : Effect.fail(new Error("missing"))
      },
      scan: (input) =>
        Effect.sync(() => ({
          data: [...infos.values()]
            .filter((info) => (input?.parentID === null ? !info.parentID : true))
            .filter((info) => (input?.archived === false ? !info.time.archived : true))
            .map((info) => ({ session: info })),
        })),
      active: () => Effect.sync(() => Object.fromEntries([...active].map((id) => [id, { type: "running" as const }]))),
      family: ({ sessionID }) =>
        Effect.sync(() => {
          const data = [...infos.values()].filter((info) => info.parentID === sessionID)
          return {
            count: data.length,
            cost: 0,
            data,
            active: data.filter((info) => active.has(info.id)),
          }
        }),
    },
    marks: () =>
      Effect.sync(() => ({ notify: [...watched], autoApprove: settings.autoApprove, master: settings.master })),
    message: {
      list: ({ sessionID, type }) =>
        Effect.sync(() => {
          if (type !== "user") return { data: transcripts.get(sessionID) ?? [], cursor: {} }
          const at = prompts.get(sessionID)
          return {
            data:
              at === undefined
                ? []
                : [
                    Schema.decodeUnknownSync(SessionMessage.User)({
                      id: "msg_prompt",
                      type: "user",
                      text: "Faça a tarefa",
                      time: { created: at },
                    }),
                  ],
            cursor: {},
          }
        }),
    },
    request: {
      pending: () =>
        Effect.sync(() => [
          { location: { directory: AbsolutePath.make("/repo") }, forms: [...forms], permissions: [...permissions] },
        ]),
    },
  }
  const add = (info: Session.Info) => infos.set(info.id, info)
  return { ctx, infos, active, forms, permissions, prompts, reads, add, transcripts, watched, settings }
}

export type Scene = "working" | "one-question" | "two-questions" | "mixed" | "failed-only" | "calm"

/**
 * Builds the fixture situations from live events only. `pending` requests live in the world and reach the tracker
 * when a `form.*`/`permission.*` event arrives, as on the server.
 */
export function scene(name: Scene, server = world()) {
  const tracker = makeTracker(server.ctx)
  const events: Event[] = []
  const at = (event: Event) => events.push(event)
  const live = name !== "failed-only"
  // Deploy no Swarm works since before the focus started.
  at(created(ids.deploy, T0 - 10 * minute))
  at(execution("started", ids.deploy, T0 - minute))
  // Revisar navegação ran earlier and is idle (or failed in the mixed scene).
  at(created(ids.nav, T - 60 * minute))
  at(execution("started", ids.nav, T - 20 * minute))
  at(execution(name === "mixed" ? "failed" : "succeeded", ids.nav, T - 5 * minute))
  // The focus: Live Activity no iOS, three subagents of which two finished.
  at(created(ids.live, T0 - 1000))
  at(execution("started", ids.live, T0))
  if (live) {
    at(created("ses_child_1", T0 + 1 * minute, ids.live))
    at(execution("started", "ses_child_1", T0 + 1 * minute + 1))
    at(execution("succeeded", "ses_child_1", T0 + 5 * minute))
    at(created("ses_child_2", T0 + 2 * minute, ids.live))
    at(execution("started", "ses_child_2", T0 + 2 * minute + 1))
    at(execution("failed", "ses_child_2", T0 + 6 * minute))
    at(created("ses_child_3", T0 + 8 * minute, ids.live))
    at(execution("started", "ses_child_3", T0 + 8 * minute + 1))
    tool(ids.live, T - minute, "call_edit", "edit", {
      path: "packages/ios-custom/OpenCode/LiveActivity/ConversationStore.swift",
    }).forEach(at)
  }
  if (name === "failed-only") at(execution("succeeded", ids.live, T - 8 * minute))
  if (name === "failed-only" || name === "mixed") at(execution("failed", ids.deploy, T - 2 * minute))
  if (name === "one-question" || name === "two-questions" || name === "mixed" || name === "calm") {
    at(created(ids.cache, T - 3 * 60 * minute))
    at(execution("started", ids.cache, T - 10 * minute))
    at(created(ids.oauth, T - 2 * 60 * minute))
    at(execution("started", ids.oauth, T0 - 30_000))
    at({ type: "session.reasoning.started", created: T - 30_000, data: { sessionID: ids.oauth } })
  }
  if (name === "one-question" || name === "two-questions" || name === "mixed") {
    at(created(ids.idleA, T - 4 * 60 * minute))
    at(execution("started", ids.idleA, T - 30 * minute))
    at(execution("succeeded", ids.idleA, T - 10 * minute))
  }
  if (name === "one-question" || name === "two-questions") {
    at(created(ids.idleB, T - 4 * 60 * minute))
    at(execution("started", ids.idleB, T - 40 * minute))
    at(execution("succeeded", ids.idleB, T - 15 * minute))
  }
  if (name !== "working" && name !== "failed-only" && name !== "calm") {
    const form = question("frm_cache", ids.cache, 1793104680000, "Qual banco usar no cache?")
    server.forms.push(form)
    at({ type: "form.created", data: { form } })
  }
  if (name === "two-questions") {
    const form = question("frm_oauth", ids.oauth, 1793104800000, "Manter o refresh token no Keychain?")
    server.forms.push(form)
    at({ type: "form.created", data: { form } })
  }
  if (name === "mixed") {
    const request = permission("per_oauth", ids.oauth, 1793104800000, "bash", ["bun test --filter oauth"])
    server.permissions.push(request)
    at({ type: "permission.asked", data: request })
  }
  if (name === "calm") {
    at(execution("succeeded", "ses_child_3", T - 4 * minute))
    at(execution("succeeded", ids.oauth, T - 3 * minute))
    at(execution("succeeded", ids.cache, T - 2 * minute))
    at(execution("succeeded", ids.live, T - minute))
    at(interrupted(ids.deploy, T - 30_000))
  }
  return Effect.gen(function* () {
    for (const event of events) yield* tracker.apply(event, "created" in event ? event.created : T)
    return tracker
  })
}

/** A shell the session started, as `shell.created` publishes it (the shell tool tags it with the session ID). */
export function shellStarted(sessionID: string, shellID: string, at: number, command: string): Event {
  return {
    type: "shell.created",
    created: at,
    data: { info: { id: shellID, status: "running", command, metadata: { sessionID }, time: { started: at } } },
  }
}

export function shellExited(shellID: string, at: number): Event {
  return { type: "shell.exited", created: at, data: { id: shellID } }
}

/** The completion notice Core admits for a background shell. */
export function shellNotice(sessionID: string, shellID: string, at: number): Event {
  return { type: "session.synthetic", created: at, data: { sessionID, metadata: { source: "shell", shellID } } }
}

/** A shell tool call answered with "moved to the background", as stored in the transcript. */
export function backgroundShellMessage(id: string, shellID: string, at: number, command: string) {
  return Schema.decodeUnknownSync(SessionMessage.Assistant)({
    id,
    type: "assistant",
    agent: "build",
    model: { providerID: "llm-proxy", id: "gpt-6.1-sol-ultrafast" },
    time: { created: at, completed: at },
    content: [
      {
        type: "tool",
        id: `call_${shellID}`,
        name: "shell",
        state: {
          status: "completed",
          input: { command, background: true },
          content: [{ type: "text", text: `Command moved to the background (shell ID: ${shellID}).` }],
          metadata: { status: "running", shellID },
        },
        time: { created: at, ran: at, completed: at },
      },
    ],
  })
}

export function shellNoticeMessage(id: string, shellID: string, at: number) {
  return Schema.decodeUnknownSync(SessionMessage.Synthetic)({
    id,
    type: "synthetic",
    text: `<shell id="${shellID}" state="completed">ok</shell>`,
    metadata: { source: "shell", shellID, state: "completed" },
    time: { created: at },
  })
}
