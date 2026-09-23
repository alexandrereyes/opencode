import { describe, expect, test } from "bun:test"
import { base64Encode } from "@opencode/util/encode"
import { decodePairingCode, decodePairingScan, decodePairingUrl } from "./pairing"

describe("pairing scan", () => {
  const info = {
    urls: ["http://192.168.1.2:49374", "http://127.0.0.1:49374"],
    username: "opencode",
    password: "a+b & café",
  }

  test("accepts raw JSON and legacy query and fragment codes", () => {
    const expected = { urls: info.urls, password: info.password }
    expect(decodePairingScan(JSON.stringify(info))).toEqual(expected)
    expect(
      decodePairingScan(`http://192.168.1.2:49374/connect?data=${encodeURIComponent(JSON.stringify(info))}`),
    ).toEqual(expected)
    expect(decodePairingUrl(`#${encodeURIComponent(JSON.stringify(info))}`)).toEqual(expected)
  })

  test("uses a direct link origin when the payload omits server URLs", () => {
    const origin = "https://opencode.example.com:49709"
    const payload = JSON.stringify({ username: info.username, password: info.password })
    expect(decodePairingScan(` ${origin}/connect#${base64Encode(payload)} `)).toEqual({
      urls: [origin],
      password: info.password,
    })
    expect(decodePairingCode(payload)).toBeUndefined()
  })

  test("rejects malformed codes, non-HTTP schemes, and invalid payload credentials", () => {
    for (const value of [
      "http://192.168.1.2:49374/connect",
      "https://example.com/?data=invalid",
      "opencode-ios://connect?password=secret",
      "https://example.com/connect#A",
      "not a code",
      JSON.stringify({ ...info, username: "other" }),
      JSON.stringify({ ...info, urls: ["file:///tmp"] }),
    ])
      expect(decodePairingScan(value)).toBeUndefined()
  })
})
