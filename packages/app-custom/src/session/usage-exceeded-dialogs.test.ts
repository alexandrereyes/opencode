import { describe, expect, test } from "bun:test"
import { Schema } from "effect"
import { GoUpsellState, isChatGPTUsageLimit } from "./usage-exceeded-dialogs"
import { Persistence } from "@/runtime/persistence/schema"

const decode = Schema.decodeUnknownSync(
  Persistence.withInitial(GoUpsellState, {
    go_upsell_last_seen_at: null,
    go_upsell_dont_show: null,
    go_upsell_account_rate_limit_last_seen_at: null,
    go_upsell_account_rate_limit_dont_show: null,
  }),
)

describe("usage exceeded preferences", () => {
  test("defaults unseen prompts", () => {
    expect(decode({})).toEqual({
      go_upsell_last_seen_at: null,
      go_upsell_dont_show: null,
      go_upsell_account_rate_limit_last_seen_at: null,
      go_upsell_account_rate_limit_dont_show: null,
    })
  })

  test("preserves timestamps while recovering malformed siblings", () => {
    expect(
      decode({
        go_upsell_last_seen_at: 123,
        go_upsell_dont_show: "true",
        go_upsell_account_rate_limit_last_seen_at: Infinity,
        go_upsell_account_rate_limit_dont_show: 456,
      }),
    ).toEqual({
      go_upsell_last_seen_at: 123,
      go_upsell_dont_show: null,
      go_upsell_account_rate_limit_last_seen_at: null,
      go_upsell_account_rate_limit_dont_show: 456,
    })
  })
})

describe("ChatGPT usage limit", () => {
  test("detects the current and previous server messages regardless of failure type", () => {
    expect(
      isChatGPTUsageLimit({
        type: "provider.rate-limit",
        message: "ChatGPT usage limit reached. Check ChatGPT Settings → Usage for details.",
        status: 429,
      }),
    ).toBe(true)
    expect(
      isChatGPTUsageLimit({
        type: "provider.unknown",
        message:
          "ChatGPT usage limit reached. Try again after your allowance resets; check ChatGPT Settings → Usage for details.",
      }),
    ).toBe(true)
  })

  test("detects the token-sharing error code in the provider response", () => {
    expect(
      isChatGPTUsageLimit({
        type: "provider.rate-limit",
        message: "Usage limit",
        status: 429,
        response: { body: '{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}' },
      }),
    ).toBe(true)
  })

  test("ignores other rate limits and similar messages", () => {
    expect(isChatGPTUsageLimit({ type: "provider.rate-limit", message: "Rate limit exceeded", status: 429 })).toBe(
      false,
    )
    expect(isChatGPTUsageLimit({ type: "provider.rate-limit", message: "ChatGPT usage limit reached" })).toBe(false)
    expect(
      isChatGPTUsageLimit({
        type: "provider.rate-limit",
        message: "Rate limit exceeded",
        response: { body: '{"error":{"code":"rate_limit_exceeded"}}' },
      }),
    ).toBe(false)
  })
})
