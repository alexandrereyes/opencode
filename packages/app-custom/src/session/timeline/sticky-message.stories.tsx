import type { SessionMessageInfo } from "@opencode/client/promise"
import { CurrentSessionProviders } from "@opencode/session-ui-custom/storybook"
import { createReactiveTimelineProjection } from "@opencode/session-ui-custom/timeline/projection"
import { createSessionTimelineRowRenderer } from "@opencode/session-ui-custom/timeline/row"
import { createStore } from "solid-js/store"
import { Show } from "solid-js"
import { SessionUserMessage } from "@opencode/session-ui-custom/message"
import { createTimelineVirtualizer } from "./virtualizer"

export default {
  title: "OpenCode/Conversation/Sticky message",
  id: "sticky-message",
  parameters: { layout: "fullscreen" },
}

export const Reading = { render: () => <Fixture /> }
export const WithoutHeader = { render: () => <Fixture header={false} /> }
export const Context = { render: () => <Fixture context /> }
export const AttachmentsOnly = { render: () => <Fixture context empty /> }
export const CommentsOnly = { render: () => <Fixture commentsOnly /> }
export const TextLifecycle = { render: () => <TextFixture /> }

function TextFixture() {
  const [state, setState] = createStore({ text: "", mounted: true })
  const message = () => ({
    type: "user" as const,
    id: "text-lifecycle",
    text: state.text,
    time: { created: 1_750_000_000_000 },
  })
  return (
    <div style={{ "max-width": "800px", padding: "16px" }}>
      <button
        onClick={() =>
          setState(
            "text",
            "A request that fits within two lines on a wide screen, but wraps further on a narrow screen.",
          )
        }
      >
        Set text
      </button>
      <button onClick={() => setState("text", "")}>Clear text</button>
      <button onClick={() => setState("mounted", (value) => !value)}>Toggle message</button>
      <CurrentSessionProviders
        document={{ sessionID: "lifecycle", messages: [message()], status: { type: "idle" }, diffs: [] }}
      >
        <Show when={state.mounted}>
          <SessionUserMessage
            sessionID="lifecycle"
            message={message()}
            historicalAgent="build"
            historicalModel={{ providerID: "anthropic", id: "claude-sonnet-4" }}
          />
        </Show>
      </CurrentSessionProviders>
    </div>
  )
}

function Fixture(props: { header?: boolean; context?: boolean; empty?: boolean; commentsOnly?: boolean }) {
  const [state, setState] = createStore({
    pinned: true,
    action: "No action",
    messages: Array.from({ length: 12 }, (_, index): SessionMessageInfo[] => [
      {
        type: "user",
        id: `sticky-user-${index}`,
        text:
          props.empty || props.commentsOnly
            ? ""
            : props.context
              ? "Review the attached context."
              : index === 1
                ? "A short request."
                : `Request ${index + 1}.\n${"Please keep this context available while I read the response. مرحبا — src/example.ts\n".repeat(35)}`,
        time: { created: 1_750_000_000_000 + index * 60_000 },
        files: props.context
          ? Array.from({ length: 6 }, (_, image) => ({
              data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
              mime: "image/png",
              name: `layout-${image}.png`,
              source: { type: "inline" as const },
            }))
          : undefined,
      },
      {
        type: "assistant",
        id: `sticky-assistant-${index}`,
        agent: "build",
        model: { providerID: "anthropic", id: "claude-sonnet-4" },
        time: { created: 1_750_000_010_000 + index * 60_000, completed: 1_750_000_020_000 + index * 60_000 },
        tokens: { input: 100, output: 100, reasoning: 0, cache: { read: 0, write: 0 } },
        content: Array.from({ length: 8 }, (_, part) => ({
          type: "text" as const,
          text: `### Response ${index + 1}, section ${part + 1}\n\n${"Reading content that should remain anchored during expansion and streaming.\n\n".repeat(5)}`,
        })),
      },
    ]).flat(),
  })
  const document = () => ({
    sessionID: "sticky-fixture",
    messages: state.messages,
    status: { type: "idle" as const },
    diffs: [],
  })
  let reveal: (id: string) => void = () => {}
  let end: () => void = () => {}

  function Timeline() {
    const projection = createReactiveTimelineProjection({
      sessionMessages: () => state.messages,
      status: () => ({ type: "idle" }),
      reasoningMode: () => "full",
    })
    const timeline = createTimelineVirtualizer({
      sessionKey: () => "sticky-fixture",
      projection,
      showHeader: () => props.header !== false,
      pinned: () => state.pinned,
      scroll: () => ({ overflow: true, jump: !state.pinned }),
      onResumeScroll: () => end(),
      setScrollRef: () => {},
      setContentRef: () => {},
      onScheduleScrollState: () => {},
      onPin: () => setState("pinned", true),
      onUnpin: () => setState("pinned", false),
      onSelectionInteraction: () => {},
      onUserScroll: () => {},
      onHistoryScroll: () => {},
      setRevealMessage: (fn) => {
        reveal = fn
      },
      setScrollToEnd: (fn) => {
        end = fn
      },
    })
    const renderer = createSessionTimelineRowRenderer({
      sessionID: () => "sticky-fixture",
      status: () => ({ type: "idle" }),
      projection,
      presentation: () =>
        props.commentsOnly
          ? {
              comments: [
                {
                  path: "src/tables.ts",
                  comment:
                    "Essas tabelas seguem o padrão de @review. Confira os relacionamentos e mantenha as menções visíveis ao ler a resposta.",
                },
              ],
              quotes: [
                {
                  id: "quote-only",
                  text: "As tabelas atuais usam @database e precisam manter compatibilidade.",
                  comment: "Preserve o contexto de @database.",
                },
              ],
              references: [
                { name: "tables.ts", path: "/fixture/tables.ts", mime: "text/plain" },
                { name: "schema.ts", path: "/fixture/schema.ts", mime: "text/plain" },
              ],
            }
          : props.context
            ? {
                references: Array.from({ length: 8 }, (_, index) => ({
                  name: `context-${index}.ts`,
                  path: `/fixture/context-${index}.ts`,
                  mime: "text/plain",
                })),
                quotes: props.empty
                  ? undefined
                  : [
                      {
                        id: "fixture-quote",
                        text: "Quoted context.\n".repeat(20),
                        comment: "Quote comment remains available.",
                      },
                    ],
                comments: props.empty
                  ? undefined
                  : [{ path: "src/context.ts", comment: "Review this context. ".repeat(40) }],
              }
            : undefined,
      actions: {
        revert: ({ messageID }) => {
          setState("action", `Revert ${messageID}`)
        },
        fork: ({ messageID }) => {
          setState("action", `Fork ${messageID}`)
        },
      },
      reasoningMode: () => "full",
      shellToolDefaultOpen: () => false,
      editToolDefaultOpen: () => false,
      disclosure: timeline.disclosure,
    })
    return (
      <timeline.View
        header={
          <div
            class="sticky top-0 z-30 h-16"
            style={{ background: "linear-gradient(to bottom, var(--v2-background-bg-base) 48px, transparent 48px)" }}
          >
            <div class="h-12">Session tabs — sticky fixture</div>
          </div>
        }
        workspaceSession={() => false}
        deferred={() => false}
        renderRow={(row, onSizeChange) => <renderer.Row row={row} onSizeChange={onSizeChange} />}
      />
    )
  }

  return (
    <main
      data-testid="sticky-fixture"
      data-pinned={state.pinned}
      style={{ height: "100dvh", display: "flex", "flex-direction": "column" }}
    >
      <div style={{ "flex-shrink": 0 }}>
        <strong>message-bubble / c8ef3c099 / review build 1</strong>
        <button
          onClick={() => {
            setState("pinned", false)
            reveal("sticky-user-0")
          }}
        >
          First request
        </button>
        <button
          onClick={() => {
            setState("pinned", false)
            reveal("sticky-user-1")
          }}
        >
          Short request
        </button>
        <button onClick={() => end()}>Latest</button>
        <button
          onClick={() => {
            if (state.messages[0].id === "sticky-older") return
            setState("messages", [
              {
                type: "user",
                id: "sticky-older",
                text: "Earlier loaded history",
                time: { created: 1_749_000_000_000 },
              },
              ...state.messages,
            ])
          }}
        >
          Load history
        </button>
        <button
          onClick={() => {
            const last = state.messages.at(-1)
            if (last?.type !== "assistant") return
            setState("messages", state.messages.length - 1, {
              ...last,
              content: [...last.content, { type: "text", text: "New streamed section.\n\n".repeat(20) }],
            })
          }}
        >
          Append response
        </button>
        <output>{state.action}</output>
      </div>
      <div style={{ "min-height": 0, flex: 1 }}>
        <CurrentSessionProviders document={document()}>
          <Timeline />
        </CurrentSessionProviders>
      </div>
    </main>
  )
}
