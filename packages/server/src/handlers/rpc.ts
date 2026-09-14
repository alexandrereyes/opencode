import { Rpc } from "@opencode/core/rpc"
import { Plugin } from "@opencode/core/plugin"
import { RpcError, RpcInternalError } from "@opencode/protocol/errors"
import { Effect, Option } from "effect"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { Api } from "../api"
import { AfterResponse } from "../after-response"

export const RpcHandler = HttpApiBuilder.group(Api, "server.rpc", (handlers) =>
  handlers.handle("rpc.call", ({ params, payload }) =>
    Effect.gen(function* () {
      yield* Plugin.awaitActivation
      const rpc = yield* Rpc.Service
      const response = yield* Effect.serviceOption(AfterResponse)
      const callbacks: Array<() => void> = []
      const output = yield* rpc.call(
        params.rpcID,
        params.method,
        payload.input,
        Option.isSome(response) ? { afterResponse: (callback) => callbacks.push(callback) } : undefined,
      )
      // Only arm callbacks after Core has validated the handler's output.
      if (Option.isSome(response)) callbacks.forEach(response.value)
      return output === undefined ? {} : { output }
    }).pipe(
      Effect.mapError((error) =>
        error.type === "rpc.invalid_output" || error.type === "rpc.internal"
          ? new RpcInternalError({ type: error.type, message: error.message })
          : new RpcError({
              type: error.type,
              message: error.message,
              ...(error.data === undefined ? {} : { data: error.data }),
            }),
      ),
      // Defects outside handler execution are still logged, never echoed to the client.
      Effect.catchDefect((defect) =>
        Effect.logError("rpc call failed", { rpc: params.rpcID, method: params.method, defect }).pipe(
          Effect.andThen(Effect.fail(new RpcInternalError({ type: "rpc.internal", message: "RPC call failed" }))),
        ),
      ),
    ),
  ),
)
