import { describe, expect, test } from "bun:test"
import {
  acquire,
  displayPoint,
  keyUsage,
  locate,
  makeTranslator,
  parseConfig,
  parts,
  rotation,
  stopAll,
  typeable,
  type Config,
} from "../src/resources/adapters/serve-sim"

const portrait: Config = { width: 1206, height: 2622, orientation: "portrait" }

const multipart = (frames: Uint8Array[], chunk: number) => {
  const encoder = new TextEncoder()
  const whole = frames.flatMap((frame) => [
    encoder.encode(`--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${frame.byteLength}\r\n\r\n`),
    frame,
    encoder.encode("\r\n"),
  ])
  const bytes = new Uint8Array(whole.reduce((total, part) => total + part.byteLength, 0))
  whole.reduce((offset, part) => (bytes.set(part, offset), offset + part.byteLength), 0)
  return new ReadableStream<Uint8Array>({
    start(controller) {
      for (let offset = 0; offset < bytes.byteLength; offset += chunk)
        controller.enqueue(bytes.slice(offset, offset + chunk))
      controller.close()
    },
  })
}

describe("serve-sim MJPEG", () => {
  test("splits parts by Content-Length across arbitrary chunk boundaries", async () => {
    const frames = [new Uint8Array([0xff, 0xd8, 1, 2, 0xff, 0xd9]), new Uint8Array(5000).fill(7), new Uint8Array([9])]
    for (const chunk of [1, 7, 4096]) {
      const received: Uint8Array[] = []
      for await (const frame of parts(multipart(frames, chunk))) received.push(frame)
      expect(received).toEqual(frames)
    }
  })
})

describe("serve-sim configuration", () => {
  test("accepts only complete configurations", () => {
    const encode = (value: unknown) => new TextEncoder().encode(JSON.stringify(value))
    expect(parseConfig(encode({ ...portrait, screenId: 1 }))).toEqual(portrait)
    expect(parseConfig(encode({ width: 0, height: 0, orientation: "portrait" }))).toBeUndefined()
    expect(parseConfig(encode({ ...portrait, orientation: "sideways" }))).toBeUndefined()
    expect(parseConfig(new TextEncoder().encode("not json"))).toBeUndefined()
  })

  test("rotates a portrait framebuffer for landscape and upside-down interfaces", () => {
    expect(rotation(portrait)).toBe(0)
    expect(rotation({ ...portrait, orientation: "landscape_left" })).toBe(90)
    expect(rotation({ ...portrait, orientation: "landscape_right" })).toBe(270)
    expect(rotation({ ...portrait, orientation: "portrait_upside_down" })).toBe(180)
    // A framebuffer that is already landscape needs no turn.
    expect(rotation({ width: 2622, height: 1206, orientation: "landscape_left" })).toBe(0)
  })

  test("display points invert serve-sim's raw mapping", () => {
    // serve-sim's rawPointForDisplayPoint, for landscape_left: raw = (y, 1 - x).
    const display = { x: 0.2, y: 0.7 }
    const raw = { x: display.y, y: 1 - display.x }
    const left = displayPoint(90, raw.x, raw.y)
    expect(left.x).toBeCloseTo(display.x)
    expect(left.y).toBeCloseTo(display.y)
    // landscape_right: raw = (1 - y, x).
    const right = displayPoint(270, 1 - display.y, display.x)
    expect(right.x).toBeCloseTo(display.x)
    expect(right.y).toBeCloseTo(display.y)
  })
})

describe("input translation", () => {
  test("a tap is one begin and one end at the raw point", () => {
    const translator = makeTranslator()
    expect(translator.translate({ type: "touch", phase: "began", x: 0.3, y: 0.4 }, portrait)).toEqual([
      [0x03, { type: "begin", x: 0.3, y: 0.4, edge: 0 }],
    ])
    expect(translator.translate({ type: "touch", phase: "ended", x: 0.3, y: 0.4 }, portrait)).toEqual([
      [0x03, { type: "end", x: 0.3, y: 0.4, edge: 0 }],
    ])
  })

  test("a drag from the home indicator carries the bottom edge until it ends", () => {
    const translator = makeTranslator()
    const edges = (["began", "moved", "ended"] as const).map((phase, index) => {
      const [[, body]] = translator.translate({ type: "touch", phase, x: 0.5, y: 0.97 - index * 0.3 }, portrait)
      return (body as { edge: number }).edge
    })
    expect(edges).toEqual([3, 3, 3])
    const [[, next]] = translator.translate({ type: "touch", phase: "began", x: 0.5, y: 0.5 }, portrait)
    expect((next as { edge: number }).edge).toBe(0)
  })

  test("in landscape the home indicator is the raw right edge", () => {
    const translator = makeTranslator()
    // Upright bottom center in landscape_left is raw (y = 0.97 → x = 0.97, x = 0.5 → y = 0.5).
    const [[, body]] = translator.translate(
      { type: "touch", phase: "began", x: 0.97, y: 0.5 },
      { ...portrait, orientation: "landscape_left" },
    )
    expect((body as { edge: number }).edge).toBe(4)
  })

  test("a second finger turns the touch into one two-finger gesture", () => {
    const translator = makeTranslator()
    translator.translate({ type: "touch", phase: "began", x: 0.4, y: 0.4, pointer: 0 }, portrait)
    expect(translator.translate({ type: "touch", phase: "began", x: 0.6, y: 0.6, pointer: 1 }, portrait)).toEqual([
      [0x03, { type: "end", x: 0.4, y: 0.4, edge: 0 }],
      [0x05, { type: "begin", x1: 0.4, y1: 0.4, x2: 0.6, y2: 0.6 }],
    ])
    expect(translator.translate({ type: "touch", phase: "moved", x: 0.7, y: 0.7, pointer: 1 }, portrait)).toEqual([
      [0x05, { type: "move", x1: 0.4, y1: 0.4, x2: 0.7, y2: 0.7 }],
    ])
    expect(translator.translate({ type: "touch", phase: "ended", x: 0.7, y: 0.7, pointer: 1 }, portrait)).toEqual([
      [0x05, { type: "end", x1: 0.4, y1: 0.4, x2: 0.7, y2: 0.7 }],
    ])
    // The finger left down is ignored until lifted; the next touch starts fresh.
    expect(translator.translate({ type: "touch", phase: "moved", x: 0.5, y: 0.5, pointer: 0 }, portrait)).toEqual([])
    expect(translator.translate({ type: "touch", phase: "ended", x: 0.5, y: 0.5, pointer: 0 }, portrait)).toEqual([])
    expect(translator.translate({ type: "touch", phase: "began", x: 0.2, y: 0.2, pointer: 0 }, portrait)).toEqual([
      [0x03, { type: "begin", x: 0.2, y: 0.2, edge: 0 }],
    ])
  })

  test("buttons, rotation and scroll", () => {
    const translator = makeTranslator()
    expect(translator.translate({ type: "button", button: "home" }, portrait)).toEqual([[0x04, { button: "home" }]])
    expect(translator.translate({ type: "button", button: "app-switcher" }, portrait)).toEqual([
      [0x04, { button: "app_switcher" }],
    ])
    expect(translator.translate({ type: "button", button: "back" }, portrait)).toEqual([])
    expect(translator.translate({ type: "button", button: "rotate-left" }, portrait)).toEqual([
      [0x07, { orientation: "landscape_left" }],
    ])
    expect(
      translator.translate({ type: "button", button: "rotate-right" }, { ...portrait, orientation: "landscape_left" }),
    ).toEqual([[0x07, { orientation: "portrait" }]])
    expect(translator.translate({ type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 0.1 }, portrait)).toEqual([
      [0x0b, { dx: 0, dy: 0.1, x: 0.5, y: 0.5 }],
    ])
  })

  test("keys press modifiers around the key", () => {
    expect(keyUsage("a")).toEqual({ usage: 0x04, shift: false })
    expect(keyUsage("Z")).toEqual({ usage: 0x1d, shift: true })
    expect(keyUsage("0")).toEqual({ usage: 0x27, shift: false })
    expect(keyUsage("?")).toEqual({ usage: 0x38, shift: true })
    expect(keyUsage("é")).toBeUndefined()
    const translator = makeTranslator()
    expect(translator.translate({ type: "key", key: "A", modifiers: ["meta"] }, portrait)).toEqual([
      [0x06, { type: "down", usage: 0xe3 }],
      [0x06, { type: "down", usage: 0xe1 }],
      [0x06, { type: "down", usage: 0x04 }],
      [0x06, { type: "up", usage: 0x04 }],
      [0x06, { type: "up", usage: 0xe1 }],
      [0x06, { type: "up", usage: 0xe3 }],
    ])
    expect(translator.translate({ type: "key", key: "Enter" }, portrait)).toEqual([
      [0x06, { type: "down", usage: 0x28 }],
      [0x06, { type: "up", usage: 0x28 }],
    ])
  })

  test("short US text is typed as keys; anything else is pasted", () => {
    expect(typeable("abc 1!")).toBe(true)
    expect(typeable("ação")).toBe(false)
    expect(typeable("x".repeat(33))).toBe(false)
    expect(typeable("")).toBe(false)
    expect(makeTranslator().translate({ type: "text", text: "a!" }, portrait)).toEqual([
      [0x06, { type: "down", usage: 0x04 }],
      [0x06, { type: "up", usage: 0x04 }],
      [0x06, { type: "down", usage: 0xe1 }],
      [0x06, { type: "down", usage: 0x1e }],
      [0x06, { type: "up", usage: 0x1e }],
      [0x06, { type: "up", usage: 0xe1 }],
    ])
  })

  test("the release copy of serve-sim is found from the plugin dependency in source", async () => {
    expect(await Bun.file(locate({})).exists()).toBe(true)
    expect(locate({ OPENCODE_SERVE_SIM: "/custom/serve-sim.js" })).toBe("/custom/serve-sim.js")
  })
})

// Opt-in: OPENCODE_TEST_SIMULATOR=<UDID of a booted simulator you own> streams and taps it for real.
test.skipIf(!process.env.OPENCODE_TEST_SIMULATOR)(
  "streams a booted simulator and reacts to a tap",
  async () => {
    const udid = process.env.OPENCODE_TEST_SIMULATOR!
    const lease = await acquire(udid)
    const controller = new AbortController()
    const frames = lease.helper.frames(controller.signal)
    const first = await frames.next()
    expect(first.done).toBe(false)
    expect(lease.helper.config()?.width).toBeGreaterThan(0)
    lease.helper.send(0x04, { button: "home" })
    await Bun.sleep(1500)
    lease.helper.send(0x03, { type: "begin", x: 0.17, y: 0.13, edge: 0 })
    expect((await frames.next()).done).toBe(false)
    lease.helper.send(0x03, { type: "move", x: 0.5, y: 0.5, edge: 0 })
    lease.helper.send(0x03, { type: "end", x: 0.5, y: 0.5, edge: 0 })
    controller.abort()
    lease.release()
    stopAll()
  },
  60_000,
)
