import { OpenCode, type SessionImportInput } from "@opencode/client"
import { Schema } from "effect"
import { UiUndoRpc } from "./rpc.js"

const url = process.argv[2]
if (!url) throw new Error("usage: bun upstream-smoke.ts <private-upstream-url> [password]")

const password = process.argv[3]
const headers = password ? { authorization: `Basic ${btoa(`opencode:${password}`)}` } : undefined
const client = OpenCode.make({ baseUrl: url, headers })
const prompt = async (sessionID: string, text: string) => {
  const response = await fetch(`${url}/api/session/${sessionID}/prompt`, {
    method: "POST",
    headers: { ...headers, "content-type": "application/json" },
    body: JSON.stringify({ text, resume: false }),
  })
  if (!response.ok) throw new Error(`prompt failed (${response.status}): ${await response.text()}`)
}
const openapi = (await fetch(`${url}/openapi.json`, { headers }).then((response) => response.json())) as {
  paths: Record<string, Record<string, { operationId?: string }>>
}
const operations = new Set(
  Object.values(openapi.paths).flatMap((item) =>
    Object.values(item).flatMap((operation) => operation.operationId ?? []),
  ),
)
for (const required of [
  "v2.session.list",
  "v2.message.list",
  "v2.session.revert.stage",
  "v2.session.revert.clear",
  "v2.session.revert.commit",
  "v2.session.interrupt",
  "v2.shell.list",
  "v2.shell.remove",
])
  if (!operations.has(required)) throw new Error(`upstream is missing ${required}`)

const template = await client.session.create({ title: "public-api-undo-template" })
await client.session.remove({ sessionID: template.id })
const nonce = crypto.randomUUID().replaceAll("-", "")
const rootID = `ses_root${nonce}`
const childID = `ses_child${nonce}`
const priorShell = await client.shell.create({
  location: { directory: template.location.directory },
  command: "while :; do sleep 60; done",
  timeout: 0,
  metadata: { sessionID: rootID },
})
const causalShell = await client.shell.create({
  location: { directory: template.location.directory },
  command: "while :; do sleep 60; done",
  timeout: 0,
  metadata: { sessionID: rootID },
})
const priorMessageID = `msg_prior${nonce}`
const boundaryID = `msg_boundary${nonce}`
const causalMessageID = `msg_causal${nonce}`
const childInputID = `msg_child${nonce}`
const time = Date.now()
const assistant = (id: string, shellID: string, created: number) => ({
  id,
  type: "assistant" as const,
  agent: "build",
  model: { providerID: "fixture", id: "fixture" },
  content: [
    {
      type: "tool" as const,
      id: `call_${id}`,
      name: "shell",
      state: {
        status: "completed" as const,
        input: {},
        content: [{ type: "text" as const, text: "background shell started" }],
        metadata: { shellID },
      },
      time: { created, completed: created },
    },
  ],
  finish: "tool-calls" as const,
  time: { created, streamed: created, completed: created },
})
const rootImport = {
  info: { ...template, id: rootID, title: "public-api-undo-root", time: { created: time, updated: time } },
  messages: [
    assistant(priorMessageID, priorShell.data.id, time),
    {
      id: boundaryID,
      type: "user" as const,
      text: "undo boundary",
      files: [],
      agents: [],
      skills: [],
      time: { created: time },
    },
    assistant(causalMessageID, causalShell.data.id, time),
  ],
  location: template.location,
} satisfies SessionImportInput
const childImport = {
  info: {
    ...template,
    id: childID,
    parentID: rootID,
    title: "public-api-undo-child",
    time: { created: time, updated: time },
  },
  messages: [
    {
      id: childInputID,
      type: "user" as const,
      text: "causal child input",
      files: [],
      agents: [],
      skills: [],
      time: { created: time },
    },
  ],
  location: template.location,
} satisfies SessionImportInput
const second = crypto.randomUUID().replaceAll("-", "")
const root2 = `ses_root${second}`
const child2 = `ses_child${second}`
const boundary2 = `msg_boundary${second}`
const origin2 = `msg_origin${second}`
const childInput2 = `msg_child${second}`
const third = crypto.randomUUID().replaceAll("-", "")
const root3 = `ses_root${third}`
const child3 = `ses_child${third}`
const boundary3 = `msg_boundary${third}`
const origin3 = `msg_origin${third}`
const childInput3 = `msg_child${third}`

try {
  await client.session.import(rootImport)
  await client.session.import(childImport)
  const importedRootMessages = await client.message.list({ sessionID: rootID, order: "asc", limit: 100 })
  const rpc = client.rpc(UiUndoRpc)
  const rpcOptions = { location: { directory: template.location.directory } }
  await client.plugin.awaitActivation(rpcOptions)
  await rpc.record(
    {
      childSessionID: childID,
      inputID: childInputID,
      assignedSeq: 0,
      origin: { parentSessionID: rootID, parentMessageID: causalMessageID, toolCallID: "call" },
    },
    rpcOptions,
  )
  const operation = await rpc.stage({ rootSessionID: rootID, rootMessageID: boundaryID }, rpcOptions)
  if (!Schema.is(Schema.Struct({ phase: Schema.Literal("staged") }))(operation))
    throw new Error("plugin returned invalid stage output")
  const running = await client.shell.list({ location: { directory: template.location.directory } })
  if (!running.data.some((shell) => shell.id === priorShell.data.id)) throw new Error("pre-cut shell was stopped")
  if (running.data.some((shell) => shell.id === causalShell.data.id))
    throw new Error(`post-cut shell is still running: ${JSON.stringify(importedRootMessages.data)}`)
  if ((await client.session.get({ sessionID: childID })).revert?.messageID !== childInputID)
    throw new Error("real child was not staged")
  await rpc.redo({ rootSessionID: rootID }, rpcOptions)
  await rpc.stage({ rootSessionID: rootID, rootMessageID: boundaryID }, rpcOptions)
  await prompt(rootID, "prompt from another client")
  const rootPromptFamilyCommit =
    (await client.session.get({ sessionID: rootID })).revert === undefined &&
    (await client.session.get({ sessionID: childID })).revert === undefined

  await client.session.import({
    info: { ...template, id: root2, title: "child prompt root", time: { created: time, updated: time } },
    messages: [
      {
        id: boundary2,
        type: "user",
        text: "undo boundary",
        files: [],
        agents: [],
        skills: [],
        time: { created: time },
      },
      {
        id: origin2,
        type: "assistant",
        agent: "build",
        model: { providerID: "fixture", id: "fixture" },
        content: [],
        finish: "stop",
        time: { created: time, completed: time },
      },
    ],
    location: template.location,
  })
  await client.session.import({
    info: {
      ...template,
      id: child2,
      parentID: root2,
      title: "child prompt child",
      time: { created: time, updated: time },
    },
    messages: [
      {
        id: childInput2,
        type: "user",
        text: "causal child input",
        files: [],
        agents: [],
        skills: [],
        time: { created: time },
      },
    ],
    location: template.location,
  })
  await rpc.record(
    {
      childSessionID: child2,
      inputID: childInput2,
      assignedSeq: 0,
      origin: { parentSessionID: root2, parentMessageID: origin2, toolCallID: "call" },
    },
    rpcOptions,
  )
  await rpc.stage({ rootSessionID: root2, rootMessageID: boundary2 }, rpcOptions)
  await prompt(child2, "prompt child from another client")
  const childPromptFamilyCommit =
    (await client.session.get({ sessionID: root2 })).revert === undefined &&
    (await client.session.get({ sessionID: child2 })).revert === undefined

  await client.session.import({
    info: { ...template, id: root3, title: "synthetic root", time: { created: time, updated: time } },
    messages: [
      {
        id: boundary3,
        type: "user",
        text: "undo boundary",
        files: [],
        agents: [],
        skills: [],
        time: { created: time },
      },
      {
        id: origin3,
        type: "assistant",
        agent: "build",
        model: { providerID: "fixture", id: "fixture" },
        content: [],
        finish: "stop",
        time: { created: time, completed: time },
      },
    ],
    location: template.location,
  })
  await client.session.import({
    info: {
      ...template,
      id: child3,
      parentID: root3,
      title: "synthetic child",
      time: { created: time, updated: time },
    },
    messages: [
      {
        id: childInput3,
        type: "user",
        text: "causal child input",
        files: [],
        agents: [],
        skills: [],
        time: { created: time },
      },
    ],
    location: template.location,
  })
  await rpc.record(
    {
      childSessionID: child3,
      inputID: childInput3,
      assignedSeq: 0,
      origin: { parentSessionID: root3, parentMessageID: origin3, toolCallID: "call" },
    },
    rpcOptions,
  )
  await rpc.stage({ rootSessionID: root3, rootMessageID: boundary3 }, rpcOptions)
  const eventController = new AbortController()
  const syntheticOrder: string[] = []
  const observed = (async () => {
    for await (const event of client.event.subscribe({ signal: eventController.signal })) {
      if (!("data" in event) || !("sessionID" in event.data) || event.data.sessionID !== root3) continue
      if (event.type !== "session.inbox.enqueued" && event.type !== "session.revert.committed") continue
      syntheticOrder.push(event.type)
      if (syntheticOrder.length === 2) {
        eventController.abort()
        return
      }
    }
  })()
  await Bun.sleep(25)
  await client.session.synthetic({ sessionID: root3, text: "external synthetic", resume: false })
  await Promise.race([observed, Bun.sleep(5_000).then(() => Promise.reject(new Error("synthetic events timed out")))])
  const syntheticFamilyCommit =
    (await client.session.get({ sessionID: root3 })).revert === undefined &&
    (await client.session.get({ sessionID: child3 })).revert === undefined
  console.log(
    JSON.stringify({
      ok: true,
      rootID,
      childID,
      preservedShellID: priorShell.data.id,
      removedShellID: causalShell.data.id,
      phase: operation.phase,
      rootPromptFamilyCommit,
      childPromptFamilyCommit,
      syntheticFamilyCommit,
      syntheticOrder,
      causalOrGroupOperations: [...operations].filter((id) => /causal|group|job/.test(id)),
    }),
  )
} finally {
  await client.shell
    .remove({ id: priorShell.data.id, location: { directory: template.location.directory } })
    .catch(() => {})
  await client.shell
    .remove({ id: causalShell.data.id, location: { directory: template.location.directory } })
    .catch(() => {})
  await client.session.remove({ sessionID: rootID }).catch(() => {})
  await client.session.remove({ sessionID: root2 }).catch(() => {})
  await client.session.remove({ sessionID: root3 }).catch(() => {})
}
