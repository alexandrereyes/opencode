import { afterEach, describe, expect, test } from "bun:test"
import http2 from "node:http2"
import { connect } from "../src/resources/adapters/android-grpc"
import type { Adapter, StreamSink } from "../src/resources/adapters/types"
import { createHub } from "../src/resources/hub/hub"
import { makeInputQueue } from "../src/resources/hub/input-queue"
import { ResourceProtocol } from "../src/resources/protocol"

const udid = "4D3C2B1A-0000-4000-8000-00000000D311"
const closers: (() => unknown)[] = []
afterEach(() => closers.splice(0).forEach((close) => close()))

/** A hub whose adapter hands its sink to the test, so the test decides when frames appear. */
function serve() {
  const sinks: StreamSink[] = []
  const started = { count: 0 }
  const inputs: ResourceProtocol.Input[] = []
  const gate = { open: Promise.resolve() }
  const adapter: Adapter = {
    kind: "ios-simulator",
    probe: async (entries) => new Map(entries.map((entry) => [entry.id, { status: "running" as const }])),
    snapshot: async () => ({ mime: "image/jpeg", data: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]) }),
    stream: async (_entry, sink, signal) => {
      started.count++
      sinks.push(sink)
      sink.hello({ format: "jpeg", width: 2, height: 2 })
      await new Promise((resolve) => signal.addEventListener("abort", resolve))
    },
    input: async (_entry, event) => {
      await gate.open
      inputs.push(event)
    },
  }
  const hub = createHub({
    adapters: { "ios-simulator": adapter, "android-emulator": adapter, chrome: adapter },
    secret: "delivery-secret",
  })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: hub.fetch, websocket: hub.websocket })
  closers.push(() => server.stop(true), hub.close)
  const resource = hub.upsert({ kind: "ios-simulator", meta: { kind: "ios-simulator", udid } })
  const url = (capability: "view" | "control", action = "stream", scheme = "ws") =>
    `${scheme}://127.0.0.1:${server.port}/resources/${encodeURIComponent(resource.id)}/${action}?ticket=${hub.ticket(resource.id, capability)?.ticket}`
  const admin = (route: string) =>
    fetch(`http://127.0.0.1:${server.port}${route}`, { headers: { authorization: "Bearer delivery-secret" } }).then(
      (response) => response.json(),
    )
  return { hub, resource, sinks, started, inputs, gate, url, admin }
}

/** A JPEG-shaped payload whose first bytes number it, `size` bytes long. */
function payload(index: number, size = 1_000) {
  const data = new Uint8Array(size)
  new DataView(data.buffer).setUint32(0, index)
  return data
}
const number = (frame: Uint8Array) =>
  new DataView(frame.buffer, frame.byteOffset).getUint32(ResourceProtocol.frameHeaderBytes)

function client(url: string, options: { acknowledge?: boolean } = {}) {
  const ws = new WebSocket(url)
  ws.binaryType = "arraybuffer"
  const frames: Uint8Array[] = []
  const texts: { type: string; [key: string]: unknown }[] = []
  ws.onmessage = (event) => {
    if (typeof event.data === "string") return void texts.push(JSON.parse(event.data))
    frames.push(new Uint8Array(event.data))
  }
  const until = async (predicate: () => boolean, ms = 3_000) => {
    const deadline = Date.now() + ms
    while (!predicate()) {
      if (Date.now() > deadline) throw new Error("condition not reached")
      await Bun.sleep(5)
    }
  }
  const ack = () => ws.send(JSON.stringify({ type: "ack", n: frames.length }))
  return {
    ws,
    frames,
    texts,
    until,
    ack,
    opened: new Promise((resolve) => (ws.onopen = resolve)).then(() => {
      if (options.acknowledge) ws.send(JSON.stringify({ type: "ack", n: 0 }))
    }),
  }
}

describe("frame delivery", () => {
  test("an acknowledging viewer gets at most three frames in flight, then the newest one", async () => {
    const hub = serve()
    const slow = client(hub.url("view"), { acknowledge: true })
    const fast = client(hub.url("view"))
    await Promise.all([slow.opened, fast.opened])
    await slow.until(() => hub.sinks.length === 1 && slow.texts.some((text) => text.type === "hello"))
    await Bun.sleep(20)
    const sink = hub.sinks[0]!
    Array.from({ length: 20 }, (_, index) => sink.frame(payload(index + 1)))
    await fast.until(() => fast.frames.length === 20)
    await Bun.sleep(50)
    // The slow viewer never acknowledged: three frames went out, the rest wait as one (the newest).
    expect(slow.frames.map(number)).toEqual([1, 2, 3])
    expect(sink.ready?.()).toBe(true)
    slow.ack()
    await slow.until(() => slow.frames.length === 4)
    expect(number(slow.frames[3]!)).toBe(20)
    expect(fast.frames.map(number)).toEqual(Array.from({ length: 20 }, (_, index) => index + 1))
    const streams = await hub.admin("/admin/streams")
    expect(streams.streams[0].viewers).toContainEqual(expect.objectContaining({ acknowledging: true, replaced: 16 }))
    slow.ws.close()
    fast.ws.close()
  })

  test("the last frame after a burst still arrives when the viewer catches up", async () => {
    const hub = serve()
    const viewer = client(hub.url("view"), { acknowledge: true })
    await viewer.opened
    await viewer.until(() => hub.sinks.length === 1)
    await Bun.sleep(20)
    const sink = hub.sinks[0]!
    Array.from({ length: 8 }, (_, index) => sink.frame(payload(index + 1)))
    await viewer.until(() => viewer.frames.length === 3)
    // The screen stopped changing: no new frame will come, but acknowledging releases the held-back last one.
    const ready = sink.whenReady?.()
    viewer.ack()
    await viewer.until(() => viewer.frames.length === 4)
    expect(number(viewer.frames.at(-1)!)).toBe(8)
    await ready
    viewer.ws.close()
  })

  test("upgrading the socket to control keeps the stream, and the stream outlives a reconnect", async () => {
    const hub = serve()
    const viewer = client(hub.url("view"))
    await viewer.opened
    await viewer.until(() => hub.sinks.length === 1)
    hub.sinks[0]!.frame(payload(1))
    await viewer.until(() => viewer.frames.length === 1)
    expect(viewer.texts[0]).toMatchObject({ type: "features", ack: true, auth: true })
    const taken = await hub.hub.control(hub.resource.id, "take")
    viewer.ws.send(JSON.stringify({ type: "auth", ticket: hub.hub.ticket(hub.resource.id, "control")?.ticket }))
    await viewer.until(() => viewer.texts.some((text) => text.type === "control" && text.mine === true))
    expect(taken?.token).toBeDefined()
    viewer.ws.send(JSON.stringify({ type: "input", events: [{ type: "key", key: "Enter" }] }))
    await viewer.until(() => hub.inputs.length === 1)
    viewer.ws.close()
    // Reconnecting within the grace period finds the same capture and its last frame at once.
    const again = client(hub.url("view"))
    await again.opened
    await again.until(() => again.frames.length === 1)
    expect(number(again.frames[0]!)).toBe(1)
    expect(hub.started.count).toBe(1)
    again.ws.close()
  })

  test("MJPEG holds back by bytes and serves the newest part once the client reads", async () => {
    const hub = serve()
    // Bun sends the response head with the first part, so start the request before frames exist.
    const responding = fetch(hub.url("view", "stream", "http"))
    await new Promise<void>((resolve) => {
      const wait = () => (hub.sinks.length > 0 ? resolve() : setTimeout(wait, 5))
      wait()
    })
    const sink = hub.sinks[0]!
    // 1,500 frames of 100 KB nobody reads: only about the 512 KiB budget may queue.
    Array.from({ length: 1_500 }, (_, index) => sink.frame(payload(index + 1, 100_000)))
    const response = await responding
    expect(response.headers.get("cache-control")).toBe("no-store, no-transform")
    expect(response.headers.get("x-accel-buffering")).toBe("no")
    const streams = await hub.admin("/admin/streams")
    const viewer = streams.streams[0].viewers[0]
    expect(viewer.bytes).toBeLessThan(1_000_000)
    expect(viewer.replaced).toBeGreaterThan(1_400)
    const reader = response.body!.getReader()
    const received: number[] = []
    const state = { buffer: Buffer.alloc(0) }
    const deadline = Date.now() + 5_000
    while (!received.includes(1_500) && Date.now() < deadline) {
      const chunk = await reader.read()
      if (chunk.done) break
      state.buffer = Buffer.concat([state.buffer, chunk.value])
      const parse = (): void => {
        const end = state.buffer.indexOf("\r\n\r\n")
        if (end < 0) return
        const length = Number(/Content-Length: (\d+)/.exec(state.buffer.subarray(0, end).toString())?.[1])
        if (state.buffer.byteLength < end + 4 + length + 2) return
        received.push(state.buffer.readUInt32BE(end + 4))
        state.buffer = state.buffer.subarray(end + 4 + length + 2)
        parse()
      }
      parse()
    }
    expect(received).toContain(1_500)
    expect(received.length).toBeLessThan(20)
    await reader.cancel()
  })
})

describe("input queue", () => {
  test("coalesces a finger's moves and adjacent text, keeps order and limits the queue", async () => {
    const applied: ResourceProtocol.Input[] = []
    const gate = Promise.withResolvers<void>()
    const queue = makeInputQueue({
      apply: async (event) => {
        await gate.promise
        applied.push(event)
      },
      holds: () => true,
      failed: () => {},
      limit: 6,
    })
    const touch = (phase: "began" | "moved" | "ended", y: number, pointer?: number) => ({
      type: "touch" as const,
      phase,
      x: 0.5,
      y,
      ...(pointer ? { pointer } : {}),
    })
    queue.enqueue("t", [touch("began", 0.1)])
    const moves = Array.from({ length: 64 }, (_, index) => touch("moved", index / 100))
    expect(queue.enqueue("t", moves)).toBe(true)
    queue.enqueue("t", [touch("moved", 0.2, 1), touch("moved", 0.9), touch("moved", 0.3, 1)])
    queue.enqueue("t", [{ type: "text", text: "a" }, { type: "text", text: "ç" }, touch("ended", 0.9)])
    expect(queue.size).toBe(4)
    // Full: a key is refused, lifting a finger is not.
    queue.enqueue("t", [touch("began", 0.5, 2), { type: "key", key: "Enter" }])
    expect(queue.enqueue("t", [{ type: "key", key: "Tab" }])).toBe(false)
    expect(queue.enqueue("t", [touch("ended", 0.5, 2)])).toBe(true)
    gate.resolve()
    await queue.idle()
    expect(applied).toEqual([
      touch("began", 0.1),
      touch("moved", 0.9),
      touch("moved", 0.3, 1),
      { type: "text", text: "aç" },
      touch("ended", 0.9),
      touch("began", 0.5, 2),
      { type: "key", key: "Enter" },
      touch("ended", 0.5, 2),
    ])
  })

  test("nothing runs after control is given back, and fingers still down are lifted first", async () => {
    const hub = serve()
    const gate = Promise.withResolvers<void>()
    hub.gate.open = gate.promise
    const taken = await hub.hub.control(hub.resource.id, "take")
    const control = client(hub.url("control"))
    await control.opened
    control.ws.send(
      JSON.stringify({
        type: "input",
        events: [
          { type: "touch", phase: "began", x: 0.1, y: 0.2 },
          ...Array.from({ length: 60 }, (_, index) => ({ type: "touch", phase: "moved", x: 0.1, y: index / 60 })),
          { type: "text", text: "segredo" },
        ],
      }),
    )
    await control.until(() => hub.hub.locks.size === 1)
    await Bun.sleep(30)
    const released = hub.hub.control(hub.resource.id, "release")
    gate.resolve()
    await released
    expect(taken?.token).toBeDefined()
    // The `began` in flight finished, everything queued behind it was dropped, and the finger was lifted.
    expect(hub.inputs).toEqual([
      { type: "touch", phase: "began", x: 0.1, y: 0.2 },
      { type: "touch", phase: "cancelled", x: 0.1, y: 0.2 },
    ])
    await Bun.sleep(30)
    expect(hub.inputs).toHaveLength(2)
    control.ws.close()
  })
})

describe("emulator gRPC", () => {
  test("a unary call succeeds only on grpc-status 0 and fails on error trailers or HTTP errors", async () => {
    const server = http2.createServer()
    server.on("stream", (stream, headers) => {
      const method = String(headers[":path"]).split("/").at(-1)
      if (method === "http") return stream.respond({ ":status": 503 }, { endStream: true })
      stream.respond({ ":status": 200, "content-type": "application/grpc" }, { waitForTrailers: true })
      stream.on("wantTrailers", () =>
        stream.sendTrailers(
          method === "ok"
            ? { "grpc-status": "0" }
            : method === "silent"
              ? { "x-trailer": "1" }
              : { "grpc-status": "13", "grpc-message": "boom" },
        ),
      )
      stream.end(Uint8Array.from([0, 0, 0, 0, 2, 8, 7]))
    })
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
    closers.push(() => server.close())
    const port = (server.address() as { port: number }).port
    const connection = connect({ port })
    closers.push(connection.close)
    expect([...(await connection.unary("ok", new Uint8Array(0)))]).toEqual([8, 7])
    const failure = (method: string) => connection.unary(method, new Uint8Array(0)).then(() => "resolved", String)
    expect(await failure("fail")).toContain("status 13: boom")
    expect(await failure("http")).toContain("HTTP 503")
    expect(await failure("silent")).toContain("without a status")
  })
})
