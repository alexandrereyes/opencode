import { expect, test } from "bun:test"
import { createServer, request } from "node:http"
import { afterResponse } from "../src/after-response"

test("callback observes a finished successful response, never handler return or an aborted response", async () => {
  const observations: string[] = []
  const closed = Promise.withResolvers<void>()
  const server = createServer((req, response) => {
    afterResponse(response)(() => {
      expect(response.writableFinished).toBe(true)
      observations.push(req.url ?? "")
    })
    expect(observations).not.toContain(req.url)
    if (req.url === "/abort") {
      response.once("close", () => closed.resolve())
      response.destroy()
      return
    }
    response.statusCode = req.url === "/error" ? 500 : 200
    response.end('{"output":{"version":"test"}}')
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  await using cleanup = {
    async [Symbol.asyncDispose]() {
      server.closeAllConnections()
      await new Promise<void>((resolve) => server.close(() => resolve()))
    },
  }
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("Expected a TCP address")
  const url = `http://127.0.0.1:${address.port}`
  expect(await (await fetch(`${url}/success`)).json()).toEqual({ output: { version: "test" } })
  expect((await fetch(`${url}/error`)).status).toBe(500)
  await new Promise<void>((resolve) =>
    request(`${url}/abort`)
      .on("error", () => resolve())
      .end(),
  )
  await closed.promise
  expect(observations).toEqual(["/success"])
})
