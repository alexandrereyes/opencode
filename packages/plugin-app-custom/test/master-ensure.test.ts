import { expect } from "bun:test"
import type { Plugin } from "@opencode/plugin/effect"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Effect, Schema } from "effect"
import { it } from "../../core/test/lib/effect"
import { Chats } from "../src/chats/rpc"
import { clearVoiceNote, ensureMaster, voiceNote, type EnsureContext } from "../src/master"
import { applyIntent } from "../src/preferences"
import { Preferences } from "../src/preferences/rpc"

// The plugin loader evaluates the plugin module again for every Location; two query strings give two evaluations.
const evaluate = (instance: string): Promise<{ readonly ensureMaster: typeof ensureMaster }> =>
  import(`../src/master/index.ts?${instance}`)

const directory = AbsolutePath.make("/chats/master")

function fixture() {
  const state = {
    profile: {
      version: 1,
      revision: 0,
      imported: false,
      data: {
        projects: {},
        sidebarOrder: [],
        pinnedSessions: [],
        models: { user: [], variant: {} },
        settings: {
          followUpBehavior: "steer",
          autoApprove: false,
          autoSave: true,
          notifications: { agent: true, permissions: true, errors: false },
        },
      },
    } satisfies Preferences.Profile as Preferences.Profile,
    sessions: [] as Session.Info[],
    notes: new Map<string, Schema.Json>(),
    failNotes: false,
  }
  const note = (sessionID: string, key: string) => `${sessionID}/${key}`
  const clients: Record<string, unknown> = {
    [Preferences.Definition.id]: {
      get: () => Effect.sync(() => state.profile),
      mutate: (intent: Preferences.Intent) => Effect.sync(() => (state.profile = applyIntent(state.profile, intent))),
    },
    [Chats.Definition.id]: {
      // Allocation waits like the real one, so callers that are not serialized interleave here.
      allocate: () => Effect.sleep("5 millis").pipe(Effect.as({ id: `chat-${state.sessions.length}`, directory })),
      claim: () => Effect.succeed({}),
      confirm: () => Effect.succeed({}),
    },
  }
  const ctx: EnsureContext = {
    storage: { get: () => Effect.succeed(undefined), set: () => Effect.void },
    model: { list: () => Effect.succeed({ location: { directory }, data: [] }) },
    session: {
      scan: (input) =>
        Effect.succeed({
          data: state.sessions.filter((item) => item.id === input?.sessionID).map((session) => ({ session })),
        }),
      create: (input) =>
        Effect.sync(() => {
          const session = Schema.decodeUnknownSync(Session.Info)({
            id: input?.id,
            projectID: "prj_chats",
            location: { directory },
            title: input?.title,
            cost: 0,
            tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
            time: { created: 1, updated: 1 },
          })
          state.sessions.push(session)
          return session
        }),
      instructions: {
        entry: {
          list: () => Effect.succeed([]),
          put: (input) =>
            state.failNotes
              ? Effect.die(new Error("instructions unavailable"))
              : Effect.sync(() => void state.notes.set(note(input.sessionID, input.key), input.value)),
          remove: (input) => Effect.sync(() => void state.notes.delete(note(input.sessionID, input.key))),
        },
      },
    },
    // SAFETY: ensureMaster only calls the two RPC clients defined above.
    rpc: ((definition: { readonly id: string }) => clients[definition.id]) as unknown as Plugin.Context["rpc"],
  }
  return { ctx, state, note }
}

it.live("a voice ensure gives the Mestra the voice-call note, and the end of the call takes it away", () =>
  Effect.gen(function* () {
    const { ctx, state, note } = fixture()
    const typed = yield* ensureMaster(ctx, {})
    expect(state.notes.size).toBe(0)
    const voice = yield* ensureMaster(ctx, { voice: true })
    expect(voice.sessionID).toBe(typed.sessionID)
    expect(state.notes.get(note(voice.sessionID, voiceNote.key))).toBe(voiceNote.text)
    yield* clearVoiceNote(ctx)
    expect(state.notes.size).toBe(0)
    // The note only shapes the answer: a failure to set it never blocks the delegation.
    state.failNotes = true
    expect((yield* ensureMaster(ctx, { voice: true })).sessionID).toBe(voice.sessionID)
  }),
)

it.live("concurrent ensures from two plugin instances create one Mestra session", () =>
  Effect.gen(function* () {
    const [first, second] = yield* Effect.promise(() => Promise.all([evaluate("first"), evaluate("second")]))
    expect(first.ensureMaster).not.toBe(second.ensureMaster)
    const { ctx, state } = fixture()
    const results = yield* Effect.all([first.ensureMaster(ctx, {}), second.ensureMaster(ctx, {})], {
      concurrency: "unbounded",
    })
    expect(state.sessions).toHaveLength(1)
    expect(results.map((result) => result.sessionID)).toEqual([state.sessions[0].id, state.sessions[0].id])
    expect(results.filter((result) => result.created)).toHaveLength(1)
    expect(state.profile.data.masterSessions?.local).toBe(state.sessions[0].id)
  }),
)
