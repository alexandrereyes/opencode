# OpenCode V2 Promise Plugin API

The Promise plugin API at `@opencode/plugin` is the async/await equivalent of `@opencode/plugin/effect`. It grants plugins the same two in-process capabilities:

- `hook` installs behavior at an OpenCode extension point.
- `reload` reruns every transform hook for a stateful domain.

The Promise API uses Promises instead of Effects for setup, runtime hook
callbacks, hook registration, `reload`, and `Registration.dispose`. Transform
editor callbacks remain synchronous.

## Defining A Plugin

```ts
import { Plugin } from "@opencode/plugin"

export default Plugin.define({
  id: "example",
  setup: async (ctx) => {
    await ctx.catalog.transform((catalog) => {
      catalog.provider.update("example", (provider) => {
        provider.name = "Example"
      })
    })
  },
})
```

Plugin setup registers hooks imperatively through each domain's `hook` method.
It may return a synchronous or asynchronous cleanup function. OpenCode awaits
the cleanup when the plugin is unloaded or replaced:

```ts
setup: async (ctx) => {
  const timer = setInterval(refresh, 60_000)
  return () => clearInterval(timer)
}
```

Configuration supplied for the plugin is available as `ctx.options`.

A registration may be removed early through `dispose`:

```ts
const registration = await ctx.catalog.transform(applyCatalog)
await registration.dispose()
```

## Transform Hooks

Transform hooks contribute to stateful domains. The editor is synchronous,
so load asynchronous data before registering a transform or reloading its domain:

```ts
const description = await loadReviewerDescription()

await ctx.agent.transform((agent) => {
  agent.update("reviewer", (item) => {
    item.description = description
    item.mode = "subagent"
  })
})
```

Available transform hooks are namespaced by domain:

```ts
ctx.agent.transform
ctx.catalog.transform
ctx.command.transform
ctx.integration.transform
ctx.mcp.transform
ctx.reference.transform
ctx.skill.transform
ctx.tool.transform
ctx.vcs.transform
ctx.websearch.transform
```

## Runtime Hooks

Runtime hooks intercept live operations:

```ts
await ctx.aisdk.hook("sdk", async (event) => {
  if (event.package !== "@ai-sdk/xai") return
  const mod = await import("@ai-sdk/xai")
  event.sdk = mod.createXai(event.options)
})

await ctx.aisdk.hook("language", (event) => {
  if (event.model.providerID !== "xai") return
  event.language = event.sdk.responses(event.model.modelID)
})
```

Session context is mutable immediately before provider dispatch:

```ts
await ctx.session.hook("context", (event) => {
  event.tools.read.description = "Read a file using narrow line ranges."
  delete event.tools.write
})

await ctx.session.hook("retry", (event) => {
  if (event.attempt >= 3) event.decision = { retry: false }
})
```

Promise tools use complete executable tool values with async executors:

```ts
import { Schema } from "effect"

await ctx.tool.transform((tools) => {
  tools.add({
    name: "echo",
    options: { codemode: false },
    description: "Echo text",
    input: Schema.Struct({ text: Schema.String }),
    output: Schema.Struct({ text: Schema.String }),
    execute: async ({ text }) => ({ output: { text }, content: text }),
  })
})
```

## Reading Messages

`ctx.message.list` uses the same newest-first default, filters, limits, and opaque
cursors as the public message API. Plugins that need to start at a known message
boundary can construct a compatible cursor without depending on server internals:

```ts
import { MessagePage } from "@opencode/plugin/message"

const page = await ctx.message.list({
  sessionID,
  cursor: MessagePage.Cursor.make({ id: messageID, order: "desc", direction: "next" }),
})
```

## Scanning Sessions

Use `ctx.session.scan` for bounded session metadata without loading transcripts. Results are ordered by session ID, with
a default limit of 200 and a maximum of 1000; `after` continues that stable ordering, `sessionID` selects one session,
and `parentID` selects direct children. Pass `parentID: null` to select roots.

```ts
const page = await ctx.session.scan({
  limit: 500,
  archived: false,
})

for (const item of page.data) {
  console.log(item.session.id, item.messageAt, item.completionAt)
}
```

Omit `archived` to include all sessions, pass `false` for active history, or `true` for archived sessions. `messageAt` is
the latest user or assistant message timestamp, while `completionAt` is the latest durable succeeded or failed execution
timestamp. Promise-plugin session values use their browser-safe encoded form, including millisecond timestamps.

`ctx.session.archive({ sessionID })` archives exactly one session. It interrupts active execution, waits for idle, closes
the model transport, and records the native archive event without deleting history. It does not archive descendants;
plugins implementing tree policy must scan and archive those descendants explicitly.

```ts
await ctx.session.archive({ sessionID })
```

## Reading Live Pending Requests

`ctx.request.pending()` returns raw permission and form snapshots grouped by Location. It samples only Locations that are
already live and never starts historical Locations; the result is best-effort and is not atomic across Locations.

```ts
const snapshots = await ctx.request.pending()
const permissions = snapshots.flatMap((snapshot) => snapshot.permissions)
const forms = snapshots.flatMap((snapshot) => snapshot.forms)
```

## Reloading A Domain

When data captured by a transform changes, reload the affected domain:

```ts
let data = await loadCatalog()

await ctx.catalog.transform((catalog) => {
  applyCatalog(data, catalog)
})

data = await loadCatalog()
await ctx.catalog.reload()
```

Available reload operations are:

```ts
ctx.agent.reload()
ctx.catalog.reload()
ctx.command.reload()
ctx.integration.reload()
ctx.mcp.reload()
ctx.reference.reload()
ctx.skill.reload()
ctx.tool.reload()
ctx.vcs.reload()
ctx.websearch.reload()
```
