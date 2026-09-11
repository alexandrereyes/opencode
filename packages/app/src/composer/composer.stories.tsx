import { Show, createMemo, onMount, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import type { ModelSelection } from "@/providers/models/selection"
import { STORY_MODEL, emptySessionDocument, pendingAndQueuedDocument } from "@opencode/session-ui/storybook"
import { Composer } from "./composer"
import { ComposerEditor } from "./editor/editor"
import type { ComposerModel } from "./model"
import { createComposerEditor } from "./editor/interaction"
import type { ComposerPersistedState, ComposerSuggestion } from "./types"
import { buildPromptRequest } from "./request"
import { promptLength } from "./prompt-parts"
import { SessionPreview } from "@/session/story-model"
import { Skill } from "@opencode/schema/skill"
import { Session } from "@opencode/schema/session"
import { resolveSessionComposerSelection } from "@/session/composer/selection"
import { snippetSuggestions } from "@/settings/snippets/model"

const selectedModel = {
  id: STORY_MODEL.id,
  providerID: STORY_MODEL.providerID,
  api: { id: STORY_MODEL.id, url: "https://api.anthropic.com", npm: "@ai-sdk/anthropic" },
  name: "Claude Sonnet 4",
  family: "claude-sonnet",
  capabilities: {
    temperature: true,
    reasoning: true,
    attachment: true,
    toolcall: true,
    input: { text: true, audio: false, image: true, video: false, pdf: true },
    output: { text: true, audio: false, image: false, video: false, pdf: false },
    interleaved: true,
  },
  cost: { input: 3, output: 15, cache: { read: 0.3, write: 3.75 } },
  limit: { context: 200_000, output: 64_000 },
  status: "active",
  options: {},
  headers: {},
  release_date: "2025-05-22",
  variants: { balanced: {}, high: {} },
  provider: {
    id: STORY_MODEL.providerID,
    name: "Anthropic",
    source: "custom",
    env: [],
    options: {},
    models: {},
  },
  latest: true,
} satisfies NonNullable<ReturnType<ModelSelection["current"]>>

function ComposerStory(props: {
  prompt?: ComposerPersistedState["prompt"]
  comments?: ComposerPersistedState["context"]["items"]
  working?: boolean
  stopping?: boolean
  suggestions?: "command" | "context"
  failure?: boolean
  label?: string
  inspectRequest?: boolean
  continueOnStop?: boolean
  longLabels?: boolean
  alternate?: "queue" | "steer"
  externalDraft?: string
  includeSessions?: boolean
  accessControls?: boolean
}) {
  const [draft, setDraft] = createStore<ComposerPersistedState>({
    prompt: props.prompt ?? [{ type: "text", content: "", start: 0, end: 0 }],
    cursor: props.prompt ? promptLength(props.prompt) : 0,
    model: { providerID: STORY_MODEL.providerID, modelID: STORY_MODEL.id, variant: STORY_MODEL.variant },
    context: { items: props.comments ?? [] },
  })
  const [story, setStory] = createStore({
    activity: props.label ?? "Ready",
    variant: STORY_MODEL.variant,
    disabled: false,
    readOnly: false,
  })
  const modelOption = createMemo(() => ({
    ...selectedModel,
    name: props.longLabels ? "Claude Sonnet with an unusually long model name" : selectedModel.name,
  }))
  const modelSelection = {
    ready: Object.assign(() => true, { promise: undefined }),
    current: () => modelOption(),
    recent: () => [modelOption()],
    list: () => [modelOption()],
    cycle() {},
    set() {},
    visible: () => true,
    setVisibility() {},
    variant: {
      configured: () => STORY_MODEL.variant,
      selected: () => story.variant,
      current: () => story.variant,
      list: () => ["balanced", "high"],
      set: (variant: string | undefined) => setStory("variant", variant ?? "balanced"),
      cycle() {},
    },
  } satisfies ModelSelection
  const commands: ComposerSuggestion[] = [
    { id: "command.test", kind: "command", label: "/test", trigger: "test", title: "Run tests" },
    { id: "command.review", kind: "command", label: "/review", trigger: "review", title: "Review changes" },
  ]
  const context: ComposerSuggestion[] = [
    {
      id: "app:codex-computer-use:com.apple.Safari",
      kind: "app",
      label: "Safari",
      description: "Computer use",
      mention: {
        type: "app",
        content: "@Safari",
        start: 0,
        end: 0,
        app: {
          server: "codex-computer-use",
          name: "Safari",
          path: "/Applications/Safari.app/",
          bundleID: "com.apple.Safari",
          running: true,
        },
      },
    },
    {
      id: "file:src/app.tsx",
      kind: "file",
      label: "src/app.tsx",
      path: "src/app.tsx",
      mention: { type: "file", path: "src/app.tsx", content: "@src/app.tsx", start: 0, end: 0 },
    },
    {
      id: "agent:review",
      kind: "agent",
      label: "@review",
      mention: { type: "agent", name: "review", content: "@review", start: 0, end: 0 },
    },
    {
      id: "skill:effect",
      kind: "skill",
      label: "$effect",
      description: "Build Effect applications",
      mention: {
        type: "skill",
        id: Skill.ID.make("effect"),
        name: Skill.Name.make("Effect"),
        content: "$effect",
        start: 0,
        end: 0,
      },
    },
  ]
  const editor = createComposerEditor({
    store: [draft, setDraft],
    commands: () => commands,
    context: () => context,
    server: () => "http://localhost:4096",
    snippets: () =>
      snippetSuggestions([
        {
          id: "review",
          name: "code-review",
          description: "Review for correctness and clarity",
          aliases: ["audit", "quality"],
          content: "Review this code for correctness.\nSuggest concrete improvements.",
        },
        {
          id: "tests",
          name: "tests",
          description: "Run focused tests",
          aliases: ["verify"],
          content: "Run the focused tests and report the results.",
        },
      ]),
    searchContextFiles: () => [],
    view: {
      placeholder: () => "Ask anything, / for commands, @ for context, $ for skills...",
      agent: {
        options: () => [
          { id: "build", label: props.longLabels ? "Build agent with an unusually long name" : "build" },
          { id: "review", label: "review" },
        ],
        current: () => "build",
        onSelect: (agent) => setStory("activity", `Selected ${agent}`),
      },
      variant: {
        options: () => [
          { id: "default", label: "default" },
          { id: "balanced", label: props.longLabels ? "Balanced reasoning with an extended label" : "balanced" },
          { id: "high", label: "high" },
        ],
        current: () => story.variant,
        onSelect: (variant) => setStory("variant", variant),
      },
      submit: {
        stopping: () => !!props.stopping,
        working: () => !!props.working,
        queue: props.alternate
          ? {
              count: () => 0,
              delivery: () => (props.alternate === "queue" ? "steer" : "queue"),
              alternate: () => props.alternate,
              editing: () => undefined,
              confirmEdit() {},
              cancelEdit() {},
              editFirst: () => false,
            }
          : undefined,
        onSubmit: () => {
          const value = draft.prompt.map((part) => ("content" in part ? part.content : `[${part.filename}]`)).join("")
          const request = props.inspectRequest
            ? buildPromptRequest({
                prompt: draft.prompt,
                context: draft.context.items,
                images: [],
                text: value,
                sessionDirectory: "C:/repo",
              })
            : undefined
          setDraft("prompt", [{ type: "text", content: "", start: 0, end: 0 }])
          setDraft("cursor", 0)
          if (props.failure) {
            setDraft("prompt", props.prompt ?? [{ type: "text", content: "", start: 0, end: 0 }])
            setStory("activity", "Submission failed; draft restored")
            return
          }
          setStory(
            "activity",
            request
              ? JSON.stringify({
                  text: request.text,
                  files: request.files,
                  agents: request.agents,
                  skills: request.skills,
                  apps: request.apps,
                  ...(props.includeSessions ? { displayText: request.displayText, sessions: request.sessions } : {}),
                })
              : `Submitted: ${value}`,
          )
        },
        onStop: () =>
          setStory("activity", props.continueOnStop ? "POST /interrupt · continue: true" : "Stop requested"),
      },
    },
  })
  const model = {
    ...editor,
    model: { selection: modelSelection, paid: true, loading: false },
  } satisfies ComposerModel

  onMount(() => {
    if (props.suggestions === "command") model.openCommands()
    if (props.suggestions === "context") model.openContext()
  })

  return (
    <div class="mx-auto flex min-h-80 w-full max-w-200 flex-col justify-end gap-3 rounded-xl bg-v2-background-bg-deep p-6">
      <output class="text-12-regular text-text-weak" aria-live="polite">
        {story.activity}
      </output>
      <Show when={props.externalDraft}>
        {(value) => (
          <button
            type="button"
            data-action="restore-external-draft"
            onClick={() => {
              setDraft("prompt", text(value()))
              setDraft("cursor", value().length)
              editor.dispatch({ type: "mode.shell" })
            }}
          >
            Restore draft
          </button>
        )}
      </Show>
      <Show when={props.accessControls}>
        <div class="flex gap-2">
          <button
            type="button"
            data-action="toggle-composer-disabled"
            onClick={() => setStory("disabled", (value) => !value)}
          >
            Toggle disabled
          </button>
          <button
            type="button"
            data-action="toggle-composer-readonly"
            onClick={() => setStory("readOnly", (value) => !value)}
          >
            Toggle read only
          </button>
        </div>
      </Show>
      <Show when={props.accessControls} fallback={<Composer model={model} borderUnderlay />}>
        <ComposerEditor
          controller={model}
          disabled={story.disabled}
          readOnly={story.readOnly}
          borderUnderlay
          modelControlsVisible={false}
        />
      </Show>
    </div>
  )
}

const text = (content: string): ComposerPersistedState["prompt"] => [
  { type: "text", content, start: 0, end: content.length },
]

export default {
  title: "OpenCode/Composer/Flow",
  component: Composer,
  parameters: { layout: "centered" },
}

export const EmptyDraft = { render: () => <ComposerStory /> }

export const Snippets = {
  parameters: { layout: "fullscreen" },
  render: () => (
    <ComposerStory inspectRequest label="Type #audit, select a snippet, then send to inspect its expansion." />
  ),
}

export const TextDraft = { render: () => <ComposerStory prompt={text("Explain this change")} /> }

export const MultilineDraft = {
  render: () => <ComposerStory prompt={text("Review the implementation\nThen run the focused tests")} />,
}

export const MixedAttachments = {
  render: () => (
    <ComposerStory
      prompt={[
        { type: "text", content: "Review ", start: 0, end: 7 },
        { type: "file", path: "src/app.tsx", content: "@src/app.tsx", start: 7, end: 19 },
        { type: "text", content: " with ", start: 19, end: 25 },
        { type: "agent", name: "review", content: "@review", start: 25, end: 32 },
        { type: "text", content: " and ", start: 32, end: 37 },
        {
          type: "skill",
          id: Skill.ID.make("effect"),
          name: Skill.Name.make("Effect"),
          content: "$effect",
          start: 37,
          end: 44,
        },
        {
          type: "image",
          id: "image-story",
          filename: "layout.png",
          mime: "image/png",
          blob: { id: "image-story", url: "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==" },
        },
      ]}
      comments={[
        {
          type: "file",
          key: "comment:src/app.tsx",
          path: "src/app.tsx",
          selection: { startLine: 12, startChar: 0, endLine: 14, endChar: 0 },
          comment: "Keep the normal flow flat",
        },
      ]}
    />
  ),
}

export const CrLfReference = {
  render: () => (
    <ComposerStory
      inspectRequest
      prompt={[
        { type: "text", content: "before\r\n", start: 0, end: 8 },
        {
          type: "skill",
          id: Skill.ID.make("effect"),
          name: Skill.Name.make("Effect"),
          content: "$effect",
          start: 8,
          end: 15,
        },
        { type: "text", content: "\r\nafter", start: 15, end: 22 },
      ]}
    />
  ),
}

export const SessionReference = {
  render: () => (
    <ComposerStory
      inspectRequest
      includeSessions
      prompt={[
        {
          type: "session",
          session: {
            id: Session.ID.make("ses_reference_12345678901234567890"),
            server: "http://localhost:4096",
            title: "Shared",
            directory: "/repo/shared",
          },
          content: "@Shared",
          start: 0,
          end: 7,
        },
      ]}
    />
  ),
}

export const ExternalDraftDuringComposition = {
  render: () => <ComposerStory externalDraft={"restored\r\ndraft"} />,
}

export const MutableEditorAccess = {
  render: () => <ComposerStory prompt={text("abc")} accessControls />,
}

export const ModelAndVariant = { render: () => <ComposerStory prompt={text("Compare both variants")} /> }

export const SlashSuggestions = { render: () => <ComposerStory suggestions="command" /> }

export const ContextSuggestions = { render: () => <ComposerStory suggestions="context" /> }

export const ComputerUseApps = {
  parameters: { layout: "fullscreen" },
  render: () => <ComposerStory suggestions="context" inspectRequest label="Fixture: select Safari, then submit" />,
}

export const RunningAndStopping = { render: () => <ComposerStory working stopping label="Session is running" /> }

export const SteeringFollowUp = {
  render: () => <ComposerStory prompt={text("Use this correction at the next boundary")} working />,
}

export const FailedSubmissionRestoration = {
  render: () => <ComposerStory prompt={text("Preserve this draft on failure")} failure />,
}

export const NewSessionFirstPrompt = {
  render: () => (
    <ComposerStory prompt={text("Create the Session and implement the change")} label="New Session draft" />
  ),
}

export const ActiveSessionFollowUp = {
  render: () => <ComposerStory prompt={text("Now add focused coverage")} label="Active Session follow-up" />,
}

export const RightToLeft = {
  globals: { direction: "rtl" },
  render: () => <ComposerStory prompt={text("راجع src/app.tsx ثم شغّل bun test")} />,
}

export const NarrowLayout = {
  parameters: { viewport: { defaultViewport: "mobile1" } },
  render: () => (
    <div class="w-[340px]">
      <ComposerStory prompt={text("Verify the narrow Composer")} />
    </div>
  ),
}

export const ToolbarOverflow = {
  args: { alternate: "queue" },
  argTypes: { alternate: { control: "select", options: ["none", "queue", "steer"] } },
  render: (args: { alternate: "none" | "queue" | "steer" }) => (
    <div class="w-[min(420px,calc(100vw-80px))]">
      <ComposerStory
        longLabels
        working
        prompt={text("Keep all controls reachable when the toolbar overflows")}
        alternate={args.alternate === "none" ? undefined : args.alternate}
      />
    </div>
  ),
}

export const DemoFirstClassSkillIDs = {
  name: "Demo: First-class skill IDs",
  render: () => (
    <DemoFrame
      title="First-class skill IDs"
      description="Choose $effect, then Send. The output shows the durable skill ID sent to the prompt API."
    >
      <ComposerStory inspectRequest label="Type $effect to select the skill" />
    </DemoFrame>
  ),
}

export const DemoStructuredCustomCommand = {
  name: "Demo: Structured custom command",
  render: () => (
    <DemoFrame
      title="Structured custom-command input"
      description="Send the draft. Files, agents, and skills remain structured instead of becoming plain command text."
    >
      <ComposerStory
        inspectRequest
        prompt={[
          { type: "text", content: "/review ", start: 0, end: 8 },
          { type: "file", path: "src/app.tsx", content: "@src/app.tsx", start: 8, end: 20 },
          { type: "text", content: " ", start: 20, end: 21 },
          { type: "agent", name: "review", content: "@review", start: 21, end: 28 },
          { type: "text", content: " ", start: 28, end: 29 },
          {
            type: "skill",
            id: Skill.ID.make("effect"),
            name: Skill.Name.make("Effect"),
            content: "$effect",
            start: 29,
            end: 36,
          },
        ]}
      />
    </DemoFrame>
  ),
}

export const DemoPendingInboxHydration = {
  name: "Demo: Pending inbox hydration",
  render: () => <PendingInboxDemo />,
}

export const DemoServerOwnedExecutionStatus = {
  name: "Demo: Server-owned execution status",
  render: () => <ServerStatusDemo />,
}

export const DemoDurableSelectionPrecedence = {
  name: "Demo: Durable selection precedence",
  render: () => <SelectionPrecedenceDemo />,
}

export const DemoContinueOnStop = {
  name: "Demo: Continue on Stop",
  render: () => (
    <DemoFrame
      title="Continue admitted work after Stop"
      description="Press Stop. The output shows the interrupt request used by the active Session adapter."
    >
      <ComposerStory working stopping continueOnStop label="Session execution is running" />
    </DemoFrame>
  ),
}

function DemoFrame(props: { title: string; description: string; children: JSX.Element }) {
  return (
    <section class="flex w-[min(920px,calc(100vw-32px))] flex-col gap-3 rounded-xl bg-v2-background-bg-deep p-4">
      <div class="flex flex-col gap-1">
        <h2 class="text-16-medium text-text-strong">{props.title}</h2>
        <p class="text-13-regular text-text-weak">{props.description}</p>
      </div>
      {props.children}
    </section>
  )
}

function PendingInboxDemo() {
  const [store, setStore] = createStore({ hydrated: false })
  return (
    <DemoFrame
      title="Active pending-inbox hydration"
      description="Toggle hydration to simulate the active Session loading durable pending inbox rows with its messages."
    >
      <div class="flex flex-col gap-3">
        <button
          type="button"
          class="self-start rounded-md bg-background-base px-3 py-2 text-13-medium text-text-strong"
          onClick={() => setStore("hydrated", (value) => !value)}
        >
          {store.hydrated ? "Clear pending data" : "Hydrate pending data"}
        </button>
        <Show
          when={store.hydrated}
          fallback={<SessionPreview title="Pending inbox" description="Not hydrated" document={emptySessionDocument} />}
        >
          <SessionPreview
            title="Pending inbox"
            description="Hydrated from Client Data"
            document={pendingAndQueuedDocument}
          />
        </Show>
      </div>
    </DemoFrame>
  )
}

function ServerStatusDemo() {
  const [store, setStore] = createStore({ running: false, activity: "Idle from server projection" })
  const document = createMemo(() => ({
    ...emptySessionDocument,
    status: store.running ? ({ type: "busy" } as const) : ({ type: "idle" } as const),
  }))
  return (
    <DemoFrame
      title="Server-owned execution status"
      description="Submitting does not force running or idle. Only the simulated execution event changes status."
    >
      <div class="flex flex-col gap-3">
        <div class="flex gap-2">
          <button
            type="button"
            class="rounded-md bg-background-base px-3 py-2 text-13-medium text-text-strong"
            onClick={() => setStore("activity", "Prompt admitted; status unchanged")}
          >
            Admit prompt
          </button>
          <button
            type="button"
            class="rounded-md bg-background-base px-3 py-2 text-13-medium text-text-strong"
            onClick={() => {
              setStore("running", (value) => !value)
              setStore("activity", store.running ? "execution.started" : "execution.succeeded")
            }}
          >
            Toggle execution event
          </button>
        </div>
        <output class="text-12-regular text-text-weak">{store.activity}</output>
        <SessionPreview title="Execution status" description={store.activity} document={document()} />
      </div>
    </DemoFrame>
  )
}

function SelectionPrecedenceDemo() {
  const [store, setStore] = createStore({ durable: true })
  const selection = createMemo(() =>
    resolveSessionComposerSelection(
      store.durable ? { agent: "build", model: { id: "claude-sonnet-4", providerID: "anthropic" } } : undefined,
      { agent: "review", model: { modelID: "gpt-5", providerID: "openai" } },
    ),
  )
  return (
    <DemoFrame
      title="Durable Session selection precedence"
      description="The current Session model wins over historical message metadata. Clear it to see the history fallback."
    >
      <div class="flex flex-col gap-3">
        <div class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-13-regular">
          <span class="text-text-weak">SessionInfo.model</span>
          <strong class="text-text-strong">{store.durable ? "anthropic/claude-sonnet-4" : "Unavailable"}</strong>
          <span class="text-text-weak">Last message metadata</span>
          <strong class="text-text-strong">openai/gpt-5</strong>
          <span class="text-text-weak">Resolved selection</span>
          <strong class="text-text-strong">
            {selection().model ? `${selection().model?.providerID}/${selection().model?.modelID}` : "Unavailable"}
          </strong>
        </div>
        <button
          type="button"
          class="self-start rounded-md bg-background-base px-3 py-2 text-13-medium text-text-strong"
          onClick={() => setStore("durable", (value) => !value)}
        >
          {store.durable ? "Remove durable Session state" : "Restore durable Session state"}
        </button>
        <ComposerStory prompt={text("Continue with the resolved Session selection")} label="Composer is ready" />
      </div>
    </DemoFrame>
  )
}
