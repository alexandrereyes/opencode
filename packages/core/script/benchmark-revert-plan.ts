import { Effect } from "effect"
import { sql } from "drizzle-orm"
import { AppNodeBuilder } from "../src/effect/app-node-builder.js"
import { Database } from "../src/database/database.js"
import { Global } from "@opencode/util/global"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { tempGlobalLayer } from "../test/fixture/global.js"
import { SessionSchema } from "../src/session/schema.js"
import { SessionMessage } from "../src/session/message.js"
import { SessionRevertPlan } from "../src/session/revert-plan.js"
import { plan } from "../../plugin-app-custom/src/causal-undo/index.js"

const sessionIDs = {
  root: SessionSchema.ID.make("ses_benchmark_root"),
  affected: SessionSchema.ID.make("ses_benchmark_affected"),
  oldSibling: SessionSchema.ID.make("ses_benchmark_old_sibling"),
}
const messagesPerSession = 4_000
const payloadBytes = 8_192
const iterations = 7
const layer = AppNodeBuilder.build(LayerNode.group([Database.node]), [Global.node.replace(tempGlobalLayer)])

const result = await Effect.runPromise(
  Effect.gen(function* () {
    const database = yield* Database.Service
    yield* database.db.run(sql`
      INSERT INTO project (id, worktree, sandboxes, time_created, time_updated)
      VALUES ('global', '/workspace', '[]', 0, 0)
    `)
    yield* database.db.run(sql`
      INSERT INTO session_v2 (id, project_id, parent_id, slug, directory, version, time_created, time_updated)
      VALUES
        (${sessionIDs.root}, 'global', NULL, 'root', '/workspace', 'benchmark', 0, 0),
        (${sessionIDs.affected}, 'global', ${sessionIDs.root}, 'affected', '/workspace', 'benchmark', 0, 0),
        (${sessionIDs.oldSibling}, 'global', ${sessionIDs.root}, 'old-sibling', '/workspace', 'benchmark', 0, 0)
    `)
    const plain = JSON.stringify({
      agent: "build",
      model: { providerID: "benchmark", id: "benchmark" },
      content: [
        { type: "reasoning", text: "r".repeat(payloadBytes / 2) },
        { type: "text", text: "t".repeat(payloadBytes / 2) },
      ],
      time: { created: 0 },
    })
    const tool = JSON.stringify({
      agent: "build",
      model: { providerID: "benchmark", id: "benchmark" },
      content: [
        { type: "reasoning", text: "r".repeat(payloadBytes / 2) },
        { type: "text", text: "t".repeat(payloadBytes / 2) },
        {
          type: "tool",
          id: "tool",
          name: "fixture",
          state: { status: "streaming", input: "" },
          time: { created: 0 },
        },
      ],
      time: { created: 0 },
    })
    for (const [index, sessionID] of Object.values(sessionIDs).entries())
      yield* database.db.run(sql`
        WITH RECURSIVE sequence(value) AS (
          SELECT 0
          UNION ALL
          SELECT value + 1 FROM sequence WHERE value + 1 < ${messagesPerSession}
        )
        INSERT INTO session_message (id, session_id, type, seq, data, time_created, time_updated)
        SELECT
          'msg_${sql.raw(String(index))}_' || printf('%04d', value),
          ${sessionID},
          'assistant',
          value,
          CASE WHEN value % 20 = 0 THEN ${tool} ELSE ${plain} END,
          value,
          value
        FROM sequence
      `)
    yield* database.db.run(sql`
      INSERT INTO session_causal (input_id, parent_session_id, child_session_id, seq, message_id, tool_call_id)
      VALUES
        ('msg_1_3600', ${sessionIDs.root}, ${sessionIDs.affected}, 3600, 'msg_0_3600', 'tool'),
        ('msg_2_0040', ${sessionIDs.root}, ${sessionIDs.oldSibling}, 40, 'msg_0_0040', 'tool')
    `)

    const execute = (messageID: SessionMessage.ID) =>
      SessionRevertPlan.load(database.db, { sessionID: sessionIDs.root, messageID }).pipe(
        Effect.map((facts) => {
          const result = plan(facts)
          SessionRevertPlan.validate(facts, result)
          return {
            children: result.participants,
            origins: result.origins,
            pendingOrigins: result.pendingOrigins,
            sessionIDs: result.discardedSessionIDs,
          }
        }),
      )

    return yield* Effect.forEach(
      [
        { name: "near-end", messageID: SessionMessage.ID.make("msg_0_3500") },
        { name: "wide", messageID: SessionMessage.ID.make("msg_0_0000") },
      ],
      Effect.fnUntraced(function* (scenario) {
        yield* execute(scenario.messageID)
        const samples = yield* Effect.forEach(
          Array.from({ length: iterations }),
          () =>
            Effect.gen(function* () {
              Bun.gc(true)
              const heap = process.memoryUsage().heapUsed
              const started = performance.now()
              const plan = yield* execute(scenario.messageID)
              return {
                duration: performance.now() - started,
                heap: process.memoryUsage().heapUsed - heap,
                plan,
              }
            }),
          { concurrency: 1 },
        )
        return {
          name: scenario.name,
          medianMs: samples.map((sample) => sample.duration).toSorted((a, b) => a - b)[Math.floor(iterations / 2)],
          medianHeapBytes: samples.map((sample) => sample.heap).toSorted((a, b) => a - b)[Math.floor(iterations / 2)],
          planHash: new Bun.CryptoHasher("sha256").update(JSON.stringify(samples[0]?.plan)).digest("hex"),
          plan: {
            children: samples[0]?.plan.children.length,
            origins: samples[0]?.plan.origins.length,
            pendingOrigins: samples[0]?.plan.pendingOrigins.length,
            discardedSessions: samples[0]?.plan.sessionIDs.length,
          },
        }
      }),
    )
  }).pipe(Effect.provide(layer), Effect.scoped),
)

console.log(
  JSON.stringify({ fixture: { sessions: 3, messagesPerSession, payloadBytes }, iterations, scenarios: result }),
)
