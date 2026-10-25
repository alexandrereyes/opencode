import http2 from "node:http2"

/**
 * Minimal client for the Android Emulator's gRPC `EmulatorController` (`emulator/lib/emulator_controller.proto` in the
 * SDK). It speaks gRPC over `node:http2` and encodes only the few protobuf messages the adapter needs, so the plugin
 * carries no gRPC or protobuf dependency. The endpoint listens on loopback and needs the console's bearer token.
 */
export function connect(endpoint: { readonly port: number; readonly token?: string }) {
  // Frames are megabytes; the default 64 KiB flow-control window would add a round trip per 64 KiB.
  const session = http2.connect(`http://127.0.0.1:${endpoint.port}`, { settings: { initialWindowSize: windowBytes } })
  session.on("connect", () => session.setLocalWindowSize(windowBytes))
  session.on("error", () => {})
  const headers = (method: string) => ({
    ":method": "POST",
    ":path": `/android.emulation.control.EmulatorController/${method}`,
    "content-type": "application/grpc",
    te: "trailers",
    ...(endpoint.token ? { authorization: `Bearer ${endpoint.token}` } : {}),
  })

  /**
   * Calls a unary method. Resolves with the response message only once the call has ended with `grpc-status: 0`
   * (in the trailers, or in the headers of a trailers-only response); an HTTP error, a non-zero status or a missing
   * status rejects. A stuck emulator fails the call after 10 s.
   */
  const unary = (method: string, message: Uint8Array) =>
    new Promise<Uint8Array>((resolve, reject) => {
      const request = session.request(headers(method))
      const state = {
        payload: new Uint8Array(0) as Uint8Array,
        status: undefined as string | undefined,
        error: undefined as Error | undefined,
      }
      const fail = (error: Error) => (state.error ??= error)
      const check = (fields: http2.IncomingHttpHeaders) => {
        const status = fields["grpc-status"]
        if (typeof status === "string") state.status = status
        failure(fields, fail)
      }
      // A plain timer: the stream's own setTimeout leaves a listener on the shared session per call.
      const timer = setTimeout(() => {
        fail(new Error(`emulator gRPC ${method} timed out`))
        request.close(http2.constants.NGHTTP2_CANCEL)
      }, 10_000)
      request.on("response", (response) => {
        if (response[":status"] !== 200) fail(new Error(`emulator gRPC ${method}: HTTP ${response[":status"]}`))
        check(response)
      })
      request.on(
        "data",
        frames((payload) => (state.payload = payload)),
      )
      request.on("trailers", check)
      request.on("error", fail)
      request.on("close", () => {
        clearTimeout(timer)
        if (state.error) return reject(state.error)
        if (state.status !== "0") return reject(new Error(`emulator gRPC ${method} ended without a status`))
        resolve(state.payload)
      })
      request.end(frame(message))
    })

  /** Calls a server-streaming method until the stream ends or `signal` aborts; `onMessage` gets each message. */
  const stream = (method: string, message: Uint8Array, onMessage: (payload: Uint8Array) => void, signal: AbortSignal) =>
    new Promise<void>((resolve, reject) => {
      if (signal.aborted) return resolve()
      const request = session.request(headers(method))
      const abort = () => request.close(http2.constants.NGHTTP2_CANCEL)
      signal.addEventListener("abort", abort, { once: true })
      request.on("data", frames(onMessage))
      request.on("response", (response) => failure(response, reject))
      request.on("trailers", (trailers) => failure(trailers, reject))
      request.on("close", () => {
        signal.removeEventListener("abort", abort)
        resolve()
      })
      request.on("error", (error) => (signal.aborted ? resolve() : reject(error)))
      request.end(frame(message))
    })

  return {
    unary,
    stream,
    get closed() {
      return session.closed || session.destroyed
    },
    close: () => session.close(),
  }
}

export type Connection = ReturnType<typeof connect>

const windowBytes = 16 * 1024 * 1024

function failure(headers: http2.IncomingHttpHeaders, reject: (error: Error) => unknown) {
  const status = headers["grpc-status"]
  if (status === undefined || status === "0") return
  const message = headers["grpc-message"]
  reject(
    new Error(`emulator gRPC status ${status}${typeof message === "string" ? `: ${decodeURIComponent(message)}` : ""}`),
  )
}

function frame(message: Uint8Array) {
  const out = new Uint8Array(5 + message.byteLength)
  new DataView(out.buffer).setUint32(1, message.byteLength)
  out.set(message, 5)
  return out
}

/** Reassembles length-prefixed gRPC messages from HTTP/2 data chunks, copying each message once. */
export function frames(onMessage: (payload: Uint8Array) => void) {
  const chunks: Uint8Array[] = []
  const state = { have: 0, need: -1 }
  const take = (count: number) => {
    const out = new Uint8Array(count)
    const fill = (offset: number): void => {
      if (offset === count) return
      const chunk = chunks[0]!
      const used = Math.min(chunk.byteLength, count - offset)
      out.set(chunk.subarray(0, used), offset)
      if (used === chunk.byteLength) chunks.shift()
      if (used < chunk.byteLength) chunks[0] = chunk.subarray(used)
      fill(offset + used)
    }
    fill(0)
    state.have -= count
    return out
  }
  const drain = (): void => {
    if (state.need < 0) {
      if (state.have < 5) return
      state.need = new DataView(take(5).buffer).getUint32(1)
    }
    if (state.have < state.need) return
    const message = take(state.need)
    state.need = -1
    onMessage(message)
    drain()
  }
  return (chunk: Uint8Array) => {
    chunks.push(chunk)
    state.have += chunk.byteLength
    drain()
  }
}

/** Protobuf writer for the handful of scalar, string and nested fields the adapter sends. */
export const pb = {
  varint(field: number, value: number) {
    return value === 0 ? new Uint8Array(0) : Uint8Array.from([...varint(field << 3), ...varint(value)])
  },
  /** `int32` fields encode negative values as ten-byte two's complement varints. */
  int32(field: number, value: number) {
    if (value >= 0) return pb.varint(field, value)
    const bytes = new Uint8Array(10)
    const big = BigInt.asUintN(64, BigInt(value))
    bytes.forEach((_, index) => {
      const part = Number((big >> BigInt(7 * index)) & 0x7fn)
      bytes[index] = index === 9 ? part : part | 0x80
    })
    return Uint8Array.from([...varint(field << 3), ...bytes])
  },
  bytes(field: number, value: Uint8Array) {
    return Uint8Array.from([...varint((field << 3) | 2), ...varint(value.byteLength), ...value])
  },
  string(field: number, value: string) {
    return pb.bytes(field, new TextEncoder().encode(value))
  },
  message(...parts: Uint8Array[]) {
    const out = new Uint8Array(parts.reduce((total, part) => total + part.byteLength, 0))
    parts.reduce((offset, part) => {
      out.set(part, offset)
      return offset + part.byteLength
    }, 0)
    return out
  },
}

function varint(value: number) {
  const out: number[] = []
  const write = (rest: number): void => {
    if (rest < 0x80) return void out.push(rest)
    out.push(rest % 0x80 | 0x80)
    write(Math.floor(rest / 0x80))
  }
  write(value)
  return out
}

/** Decodes one protobuf message into its fields: varints as numbers, length-delimited fields as byte views. */
export function decode(buffer: Uint8Array) {
  const fields = new Map<number, (number | Uint8Array)[]>()
  const state = { offset: 0 }
  const read = () => {
    const step = (value: number, scale: number): number => {
      const byte = buffer[state.offset++]
      if (byte === undefined) throw new Error("truncated protobuf varint")
      const next = value + (byte & 0x7f) * scale
      return byte < 0x80 ? next : step(next, scale * 0x80)
    }
    return step(0, 1)
  }
  while (state.offset < buffer.byteLength) {
    const key = read()
    const wire = key % 8
    const field = Math.floor(key / 8)
    const value =
      wire === 0
        ? read()
        : wire === 2
          ? (() => {
              const length = read()
              const view = buffer.subarray(state.offset, state.offset + length)
              state.offset += length
              return view
            })()
          : wire === 1 || wire === 5
            ? (() => {
                state.offset += wire === 1 ? 8 : 4
                return 0
              })()
            : undefined
    if (value === undefined) throw new Error(`unsupported protobuf wire type ${wire}`)
    fields.set(field, [...(fields.get(field) ?? []), value])
  }
  return {
    number: (field: number) => {
      const value = fields.get(field)?.at(-1)
      return typeof value === "number" ? value : 0
    },
    bytes: (field: number) => {
      const value = fields.get(field)?.at(-1)
      return value instanceof Uint8Array ? value : undefined
    },
  }
}
