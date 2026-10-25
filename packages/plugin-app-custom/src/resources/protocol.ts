export * as ResourceProtocol from "./protocol.js"

import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

/**
 * Wire protocol between clients (the iOS viewer) and the resources hub. See `docs/resources.md`.
 *
 * Coordinates are normalized to the streamed frame: `x` and `y` in [0, 1], origin at the top left.
 */
const Unit = Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 1 }))

export const Touch = Schema.Struct({
  type: Schema.Literal("touch"),
  phase: Schema.Literals(["began", "moved", "ended", "cancelled"]),
  x: Unit,
  y: Unit,
  /** Finger index for multi-touch; 0 for the first finger. */
  pointer: optional(Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 9 }))),
})

/** Wheel or two-finger scroll at a point; deltas are fractions of the frame size (positive = content moves up/left). */
export const Scroll = Schema.Struct({
  type: Schema.Literal("scroll"),
  x: Unit,
  y: Unit,
  dx: Schema.Number.check(Schema.isBetween({ minimum: -10, maximum: 10 })),
  dy: Schema.Number.check(Schema.isBetween({ minimum: -10, maximum: 10 })),
})

/** A named key (`Enter`, `Backspace`, `Tab`, `Escape`, `ArrowUp`…, DOM `KeyboardEvent.key` names) or one character. */
export const Key = Schema.Struct({
  type: Schema.Literal("key"),
  key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(32)),
  modifiers: optional(Schema.Array(Schema.Literals(["shift", "control", "alt", "meta"]))),
})

/** Text inserted at the focus. Adapters must never log it: it may be a password. */
export const Text = Schema.Struct({
  type: Schema.Literal("text"),
  text: Schema.String.check(Schema.isMaxLength(10_000)),
})

/** Hardware or system buttons; adapters ignore the ones their kind does not have. */
export const Button = Schema.Struct({
  type: Schema.Literal("button"),
  button: Schema.Literals([
    "home",
    "back",
    "recents",
    "lock",
    "volume-up",
    "volume-down",
    "rotate-left",
    "rotate-right",
    "app-switcher",
  ]),
})

/** Browser navigation (Chrome). */
export const Navigate = Schema.Struct({
  type: Schema.Literal("navigate"),
  action: Schema.Literals(["url", "back", "forward", "reload"]),
  url: optional(Schema.String.check(Schema.isMaxLength(4_000))),
})

export const Input = Schema.Union([Touch, Scroll, Key, Text, Button, Navigate]).annotate({
  identifier: "ResourceProtocol.Input",
})
export type Input = typeof Input.Type

/** Client → hub text messages on `/stream`. Inputs need a control ticket. */
export const ClientMessage = Schema.Union([
  Schema.Struct({ type: Schema.Literal("ping"), t: Schema.Number }),
  Schema.Struct({ type: Schema.Literal("input"), events: Schema.Array(Input).check(Schema.isMaxLength(64)) }),
])
export type ClientMessage = typeof ClientMessage.Type

export const FrameFormat = Schema.Literals(["jpeg", "png", "h264"])
export type FrameFormat = typeof FrameFormat.Type

export interface Hello {
  readonly type: "hello"
  readonly format: FrameFormat
  /** Source pixel size of the frames. */
  readonly width: number
  readonly height: number
  /** Points per pixel hint for the viewer (for example 1/3 for a 3x simulator). */
  readonly scale?: number
  /** H.264 only: codec configuration, base64 (avcC or Annex-B SPS/PPS), when the adapter knows it up front. */
  readonly codec?: string
}

/** Hub → client text messages on `/stream`. Binary messages are frames (see `encodeFrame`). */
export type ServerMessage =
  | Hello
  | { readonly type: "pong"; readonly t: number; readonly hub: number }
  | { readonly type: "control"; readonly holder: "user" | null; readonly expiresAt?: number; readonly mine: boolean }
  | { readonly type: "meta"; readonly value: Record<string, unknown> }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "end"; readonly reason: string }

export const frameHeaderBytes = 10
export const frameVersion = 1

/** Binary frame: u8 version (1), u8 flags (bit 0 = keyframe), f64 big-endian capture time (epoch ms), payload. */
export function encodeFrame(payload: Uint8Array, capturedAt: number, keyframe: boolean) {
  const frame = new Uint8Array(frameHeaderBytes + payload.byteLength)
  const view = new DataView(frame.buffer)
  view.setUint8(0, frameVersion)
  view.setUint8(1, keyframe ? 1 : 0)
  view.setFloat64(2, capturedAt)
  frame.set(payload, frameHeaderBytes)
  return frame
}

export function decodeFrame(frame: Uint8Array) {
  if (frame.byteLength < frameHeaderBytes) return undefined
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength)
  if (view.getUint8(0) !== frameVersion) return undefined
  return {
    keyframe: (view.getUint8(1) & 1) === 1,
    capturedAt: view.getFloat64(2),
    payload: frame.subarray(frameHeaderBytes),
  }
}
