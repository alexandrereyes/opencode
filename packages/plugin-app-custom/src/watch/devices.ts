import type { Plugin } from "@opencode/plugin/effect"
import { optional } from "@opencode/schema/schema"
import { Clock, Effect, Option, Schema } from "effect"
import { createHash, randomBytes } from "node:crypto"
import { LiveActivity } from "../live-activity/rpc.js"

export const devicesKey = "watch:devices"
/** `lastSeenAt` is written at most this often, so authenticated polling does not rewrite storage. */
export const seenWriteMs = 60_000

const Device = Schema.Struct({
  deviceID: Schema.String,
  name: Schema.String,
  /** SHA-256 (hex) of the device token; the token itself is never stored. */
  tokenHash: Schema.String,
  createdAt: Schema.Number,
  lastSeenAt: optional(Schema.Number),
  widget: optional(Schema.Struct({ token: Schema.String, environment: LiveActivity.Environment })),
})
export type Device = typeof Device.Type
const Devices = Schema.Array(Device)
const decode = (value: Schema.Json | undefined) =>
  Option.getOrElse(Schema.decodeUnknownOption(Devices)(value ?? []), () => [])
const encode = Schema.encodeSync(Devices)

export type Storage = Pick<Plugin.Context["storage"], "get" | "update">

export function hashToken(token: string) {
  return createHash("sha256").update(token).digest("hex")
}

/** Paired watches in plugin storage, shared by every Location's instance. */
export function makeDevices(storage: Storage) {
  const change = <A>(update: (devices: readonly Device[]) => readonly [readonly Device[], A]) =>
    storage.update(devicesKey, (current) => {
      const [next, result] = update(decode(current))
      return [encode(next), result]
    })
  const edit = (deviceID: string, update: (device: Device) => Device) =>
    change((devices) => [devices.map((device) => (device.deviceID === deviceID ? update(device) : device)), undefined])

  return {
    list: () => storage.get(devicesKey).pipe(Effect.map(decode)),
    pair: Effect.fn("Watch.pair")(function* (name: string) {
      const now = yield* Clock.currentTimeMillis
      const deviceToken = randomBytes(32).toString("base64url")
      const deviceID = `watch_${randomBytes(9).toString("base64url")}`
      yield* change((devices) => [
        [...devices, { deviceID, name, tokenHash: hashToken(deviceToken), createdAt: now }],
        undefined,
      ])
      return { deviceID, deviceToken }
    }),
    revoke: (deviceID: string) =>
      change((devices) => [devices.filter((device) => device.deviceID !== deviceID), undefined]),
    /** The device a bearer token belongs to; malformed, unknown and revoked tokens all yield `undefined`. */
    authenticate: Effect.fn("Watch.authenticate")(function* (authorization: string | null) {
      const token = authorization?.match(/^Bearer ([A-Za-z0-9_-]{43})$/)?.[1]
      if (!token) return undefined
      const hash = hashToken(token)
      const device = decode(yield* storage.get(devicesKey)).find((item) => item.tokenHash === hash)
      if (!device) return undefined
      const now = yield* Clock.currentTimeMillis
      if (device.lastSeenAt === undefined || now - device.lastSeenAt >= seenWriteMs)
        yield* edit(device.deviceID, (item) => ({ ...item, lastSeenAt: now }))
      return device
    }),
    widget: (deviceID: string, widget: Device["widget"]) =>
      edit(deviceID, (device) => {
        const { widget: _, ...rest } = device
        return widget ? { ...rest, widget } : rest
      }),
  }
}

export type Devices = ReturnType<typeof makeDevices>
