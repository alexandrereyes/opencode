import { describe, expect, test } from "bun:test"
import { bmp, parseRunning, plan, toPanel } from "../src/resources/adapters/android-emulator"
import { decode, frames, pb } from "../src/resources/adapters/android-grpc"

const portrait = { rotation: 0, panel: { width: 720, height: 1600 } }

describe("android emulator input", () => {
  test("touch phases press and lift one contact per pointer, in panel pixels", () => {
    expect(plan({ type: "touch", phase: "began", x: 0.5, y: 0.25, pointer: 1 }, portrait)).toEqual([
      { type: "touch", touches: [{ x: 360, y: 400, id: 1, pressure: 1024 }] },
    ])
    expect(plan({ type: "touch", phase: "moved", x: 1, y: 1 }, portrait)).toEqual([
      { type: "touch", touches: [{ x: 719, y: 1599, id: 0, pressure: 1024 }] },
    ])
    expect(plan({ type: "touch", phase: "cancelled", x: 0, y: 0 }, portrait)).toEqual([
      { type: "touch", touches: [{ x: 0, y: 0, id: 0, pressure: 0 }] },
    ])
  })

  test("points on a rotated frame map back to the portrait panel", () => {
    // The status bar sits at the panel's right edge when the display turns a quarter.
    expect(toPanel(0.5, 0, 1)).toEqual([1, 0.5])
    expect(toPanel(0, 0, 1)).toEqual([1, 0])
    expect(toPanel(0, 0, 3)).toEqual([0, 1])
    expect(toPanel(0.25, 0.75, 2)).toEqual([0.75, 0.25])
    expect(
      plan({ type: "touch", phase: "began", x: 0, y: 0 }, { rotation: 1, panel: { width: 720, height: 1600 } }),
    ).toEqual([{ type: "touch", touches: [{ x: 719, y: 0, id: 0, pressure: 1024 }] }])
  })

  test("scroll becomes a drag with its own pointer that ends lifted", () => {
    const steps = plan({ type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 0.3 }, portrait)
    expect(steps).toHaveLength(7)
    expect(steps[0]).toEqual({ type: "touch", touches: [{ x: 360, y: 800, id: 9, pressure: 1024 }] })
    expect(steps.at(-1)).toEqual({ type: "touch", touches: [{ x: 360, y: 320, id: 9, pressure: 0 }] })
  })

  test("Android buttons and rotation", () => {
    expect(plan({ type: "button", button: "back" }, portrait)).toEqual([
      { type: "shell", command: "input keyevent KEYCODE_BACK" },
    ])
    expect(plan({ type: "button", button: "home" }, portrait)).toEqual([
      { type: "shell", command: "input keyevent KEYCODE_HOME" },
    ])
    expect(plan({ type: "button", button: "recents" }, portrait)).toEqual([
      { type: "shell", command: "input keyevent KEYCODE_APP_SWITCH" },
    ])
    expect(plan({ type: "button", button: "rotate-left" }, portrait)).toEqual([{ type: "rotate", rotation: 1 }])
    expect(plan({ type: "button", button: "rotate-right" }, portrait)).toEqual([{ type: "rotate", rotation: 3 }])
  })

  test("named keys, shortcuts and characters", () => {
    expect(plan({ type: "key", key: "Backspace" }, portrait)).toEqual([
      { type: "shell", command: "input keyevent KEYCODE_DEL" },
    ])
    expect(plan({ type: "key", key: "Enter", modifiers: ["shift"] }, portrait)).toEqual([
      { type: "shell", command: "input keycombination KEYCODE_SHIFT_LEFT KEYCODE_ENTER" },
    ])
    expect(plan({ type: "key", key: "a", modifiers: ["control"] }, portrait)).toEqual([
      { type: "shell", command: "input keycombination KEYCODE_CTRL_LEFT KEYCODE_A" },
    ])
    expect(plan({ type: "key", key: "x" }, portrait)).toEqual([{ type: "shell", command: "input text 'x'" }])
    expect(plan({ type: "key", key: "F13" }, portrait)).toEqual([])
  })

  test("ASCII text is typed with shell quoting, the rest is pasted, line breaks press Enter", () => {
    expect(plan({ type: "text", text: `it's "a b" $HOME;` }, portrait)).toEqual([
      { type: "shell", command: `input text 'it'\\''s%s"a%sb"%s$HOME;'` },
    ])
    expect(plan({ type: "text", text: "Ação 😀\nok\n" }, portrait)).toEqual([
      { type: "paste", text: "Ação 😀" },
      { type: "shell", command: "input keyevent KEYCODE_ENTER" },
      { type: "shell", command: "input text 'ok'" },
      { type: "shell", command: "input keyevent KEYCODE_ENTER" },
    ])
    expect(plan({ type: "text", text: "100%" }, portrait)).toEqual([{ type: "paste", text: "100%" }])
  })

  test("browser navigation does nothing", () => {
    expect(plan({ type: "navigate", action: "back" }, portrait)).toEqual([])
  })
})

describe("android emulator discovery", () => {
  test("reads the gRPC endpoint and keeps the PID from the file name", () => {
    const content = [
      "emulator.build=15917651",
      "avd.id=Pixel_9",
      "port.serial=5590",
      "port.adb=5591",
      "avd.name=Pixel_9",
      "grpc.token=secret-token",
      "grpc.port=8590",
    ].join("\n")
    expect(parseRunning(content, 4321)).toEqual({
      pid: 4321,
      serial: "emulator-5590",
      consolePort: 5590,
      grpcPort: 8590,
      grpcToken: "secret-token",
      avd: "Pixel_9",
    })
    expect(parseRunning("avd.name=x")).toBeUndefined()
  })
})

describe("android emulator frames", () => {
  test("RGBA pixels wrapped as BMP decode with their colors and size", async () => {
    const width = 4
    const height = 2
    // Top row red, bottom row blue.
    const rgba = Uint8Array.from({ length: width * height * 4 }, (_, index) => {
      const channel = index % 4
      const bottom = index >= width * 4
      if (channel === 3) return 255
      if (channel === 0) return bottom ? 0 : 255
      if (channel === 2) return bottom ? 255 : 0
      return 0
    })
    const png = await new Bun.Image(bmp(rgba, width, height)).png({ palette: true, colors: 2 }).bytes()
    expect(await new Bun.Image(png).metadata()).toMatchObject({ width, height, format: "png" })
    // An indexed PNG lists its colors in the PLTE chunk: red and blue, not swapped channels.
    const plte = Buffer.from(png).indexOf("PLTE")
    const length = new DataView(png.buffer, png.byteOffset).getUint32(plte - 4)
    const colors = Array.from({ length: length / 3 }, (_, index) =>
      [...png.subarray(plte + 4 + index * 3, plte + 7 + index * 3)].join(","),
    )
    expect(colors.sort()).toEqual(["0,0,255", "255,0,0"])
  })

  test("protobuf fields round-trip, including negative int32", () => {
    const message = pb.message(pb.varint(1, 300), pb.int32(2, -1), pb.string(3, "ação"), pb.varint(4, 0))
    const fields = decode(message)
    expect(fields.number(1)).toBe(300)
    expect(fields.number(2)).toBe(2 ** 64 - 1)
    expect(new TextDecoder().decode(fields.bytes(3))).toBe("ação")
    expect(fields.number(4)).toBe(0)
  })

  test("gRPC messages split across chunks are reassembled", () => {
    const received: string[] = []
    const reader = frames((payload) => received.push(new TextDecoder().decode(payload)))
    const framed = (text: string) => {
      const body = new TextEncoder().encode(text)
      const out = new Uint8Array(5 + body.byteLength)
      new DataView(out.buffer).setUint32(1, body.byteLength)
      out.set(body, 5)
      return out
    }
    const stream = pb.message(framed("first"), framed(""), framed("second message"))
    reader(stream.subarray(0, 3))
    reader(stream.subarray(3, 12))
    reader(stream.subarray(12))
    expect(received).toEqual(["first", "", "second message"])
  })
})
