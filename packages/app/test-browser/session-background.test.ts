import { describe, expect, test } from "bun:test"
import type { SessionInfo, SessionMessageAssistantTool, ShellInfo } from "@opencode/client/promise"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import { createSessionBackground } from "@/session/requests/background"

const tool = (
  id: string,
  name: string,
  metadata: Record<string, string>,
  input: Record<string, string> = {},
  status: "completed" | "running" = "completed",
): SessionMessageAssistantTool => ({
  id,
  name,
  type: "tool",
  state:
    status === "running"
      ? { status, input, metadata }
      : { status, input, metadata, content: [{ type: "text", text: "backgrounded" }] },
  time: { created: 0 },
})

const assistant = (id: string, content: SessionMessageAssistantTool[], completed?: number) => ({
  id,
  type: "assistant" as const,
  agent: "build",
  model: { id: "model", providerID: "provider" },
  content,
  time: { created: 0, completed },
})

const session = (id: string, parentID = "root"): SessionInfo => ({
  id,
  title: id,
  parentID,
  projectID: "project",
  location: { directory: "/project" },
  cost: 0,
  tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  time: { created: 0, updated: 0 },
})

const shell = (id: string, command: string): ShellInfo => ({
  id,
  command,
  status: "running",
  cwd: "/project",
  shell: "sh",
  file: "output",
  metadata: { sessionID: "root" },
  time: { started: 0 },
})

const notification = (id: string, metadata: Record<string, string>) => ({
  id,
  type: "synthetic" as const,
  text: "complete",
  metadata,
  time: { created: 0 },
})

describe("createSessionBackground", () => {
  test("shows historical launches only while their runtime is active", () => {
    createRoot((dispose) => {
      const background = createSessionBackground({
        sessionID: () => "root",
        messages: () => [
          notification("before", { source: "subagent", childID: "before-child" }),
          assistant("assistant", [
            tool("before-part", "subagent", { status: "running", sessionID: "before-child" }),
            tool("shell-part", "shell", { status: "running", shellID: "process" }),
            tool("shell-call", "shell", { status: "running", shellID: "shell-id" }),
            tool("legacy-call", "shell", { status: "running", shellID: "legacy-shell" }),
            tool("child-part", "subagent", { status: "running", sessionID: "child" }, { agent: "explore" }),
          ]),
          notification("shell-done", { source: "shell", jobID: "shell-part" }),
          notification("shell-id-done", { source: "shell", shellID: "shell-id" }),
          notification("legacy-done", { source: "shell", jobID: "legacy-shell" }),
        ],
        sessions: () => [session("child")],
        status: (id) => (id === "child" ? "running" : "idle"),
        shells: () => [],
      })
      expect(background.tasks()).toEqual([{ id: "child", type: "subagent", label: "child" }])
      dispose()
    })
  })

  test("uses labels only when a blocking shell has no runtime ID", () => {
    createRoot((dispose) => {
      const background = createSessionBackground({
        sessionID: () => "root",
        messages: () => [
          assistant("current", [tool("foreground", "shell", { shellID: "foreground" }, { command: "bun test" }, "running")]),
        ],
        sessions: () => [],
        status: () => "idle",
        shells: () => [shell("background", "bun test")],
      })

      expect(background.tasks()).toEqual([{ id: "background", type: "shell", label: "bun test" }])
      dispose()
    })
  })

  test("keeps an origin shell visible after its session moves until the shell exits", () => {
    createRoot((dispose) => {
      const [store, setStore] = createStore({
        shells: [{ ...shell("origin-shell", "bun dev"), location: { directory: "/origin" } }],
      })
      const background = createSessionBackground({
        sessionID: () => "root",
        messages: () => [],
        sessions: () => [],
        status: () => "idle",
        shells: () => store.shells,
      })

      expect(background.tasks()).toEqual([{ id: "origin-shell", type: "shell", label: "bun dev" }])
      setStore("shells", 0, "status", "exited")
      expect(background.tasks()).toEqual([])
      dispose()
    })
  })

  test("does not resurrect a background child reused by a blocking call", () => {
    createRoot((dispose) => {
      const [store, setStore] = createStore({
        current: tool("foreground", "subagent", { sessionID: "child" }, { description: "reuse" }, "running"),
      })
      const background = createSessionBackground({
        sessionID: () => "root",
        messages: () => [
          assistant("backgrounded", [
            tool("backgrounded-child", "subagent", { status: "running", sessionID: "child" }, { description: "reuse" }),
          ], 1),
          notification("finished", { source: "subagent", childID: "child" }),
          assistant("current", [store.current]),
        ],
        sessions: () => [session("child")],
        status: () => "running",
        shells: () => [],
      })

      expect(background.tasks()).toEqual([])
      setStore("current", "state", {
        status: "completed",
        input: { description: "reuse" },
        metadata: { status: "running", sessionID: "child" },
        content: [{ type: "text", text: "backgrounded" }],
      })
      expect(background.tasks()).toEqual([{ id: "child", type: "subagent", label: "child" }])
      dispose()
    })
  })

  test("requires hydrated ownership for copied historical launches", () => {
    createRoot((dispose) => {
      const [store, setStore] = createStore({ sessions: [] as SessionInfo[] })
      const background = createSessionBackground({
        sessionID: () => "fork",
        messages: () => [
          assistant("copied", [
            tool("child-part", "subagent", { status: "running", sessionID: "child" }, { description: "child" }),
          ]),
        ],
        sessions: () => store.sessions,
        status: () => "running",
        shells: () => [],
      })

      expect(background.tasks()).toEqual([])
      expect(background.unresolved()).toEqual(["child"])
      setStore("sessions", [session("child", "root")])
      expect(background.unresolved()).toEqual([])
      expect(background.tasks()).toEqual([])
      dispose()
    })
  })

  test("joins live tasks while idle without rescanning history, then switches sessions", () => {
    createRoot((dispose) => {
      const [store, setStore] = createStore({
        id: "root" as string | undefined,
        messages: [
          assistant("assistant", [
            tool("shell-part", "shell", { status: "running", shellID: "shell" }, { command: "old command" }),
            tool("child-part", "subagent", { status: "running", sessionID: "child" }),
          ]),
        ],
        sessions: [session("live-child"), session("child"), session("unknown-child")],
        status: { root: "idle", child: "idle", "live-child": "idle" } as Record<string, "idle" | "running">,
        shells: [{ ...shell("shell", "command"), status: "exited" as ShellInfo["status"] }],
      })
      let scans = 0
      const background = createSessionBackground({
        sessionID: () => store.id,
        messages: (id) => {
          scans += 1
          return id === "root" ? store.messages : []
        },
        sessions: () => store.sessions,
        status: (id) => store.status[id],
        shells: () => store.shells,
      })
      const blocking = background.blocking()
      const initial = background.tasks()
      expect(initial).toEqual([])

      setStore("status", { child: "running", "live-child": "running" })
      expect(background.tasks().map((task) => task.id)).toEqual(["child", "live-child"])
      setStore("shells", 0, "status", "running")
      expect(background.tasks().at(-1)?.label).toBe("command")
      setStore("sessions", 1, "title", "renamed")
      expect(background.tasks()[0]?.label).toBe("renamed")
      setStore("shells", 0, "command", "updated command")
      const live = background.tasks()
      expect(live).toEqual([
        { id: "child", type: "subagent", label: "renamed" },
        { id: "live-child", type: "subagent", label: "live-child" },
        { id: "shell", type: "shell", label: "updated command" },
      ])
      expect(background.blocking()).toBe(blocking)
      expect(scans).toBe(1)

      setStore("id", "other")
      expect(background.tasks()).toEqual([])
      setStore("id", "root")
      expect(background.tasks()).toEqual(live)
      setStore("status", { child: "idle", "live-child": "idle" })
      setStore("shells", 0, "status", "exited")
      expect(background.tasks()).toEqual(initial)
      expect(scans).toBe(3)
      setStore("id", undefined)
      expect(background.tasks()).toEqual([])
      dispose()
    })
  })

  test("tracks blocking, backgrounding, and completion through nested store updates", () => {
    createRoot((dispose) => {
      const [store, setStore] = createStore({
        messages: [
          assistant("earlier", [tool("old-part", "subagent", { sessionID: "old-child" }, {}, "running")]),
          assistant("current", [
            tool("child-part", "subagent", { sessionID: "child" }, {}, "running"),
            tool("shell-part", "shell", {}, { command: "build" }, "running"),
          ]),
          assistant("completed", [], 0),
        ],
        notification: notification("notice", { source: "subagent", childID: "other-child" }),
        status: { child: "running", "old-child": "running" } as Record<string, "idle" | "running">,
      })
      const messages = store.messages
      const background = createSessionBackground({
        sessionID: () => "root",
        messages: () => [...store.messages, store.notification],
        sessions: () => [session("child"), session("old-child")],
        status: (id) => store.status[id],
        shells: () => [shell("shell", "build")],
      })
      expect(background.blocking()).toEqual([
        { type: "subagent", partID: "child-part", id: "child", label: undefined },
        { type: "shell", partID: "shell-part", id: undefined, label: "build" },
      ])
      expect(background.tasks().map((task) => task.id)).toEqual(["old-child"])

      setStore("messages", 1, "content", 0, "state", {
        status: "completed",
        input: { description: "background child" },
        metadata: { status: "running", sessionID: "child" },
        content: [{ type: "text", text: "backgrounded" }],
      })
      expect(store.messages).toBe(messages)
      expect(background.blocking().map((task) => task.partID)).toEqual(["shell-part"])
      expect(background.tasks().map((task) => task.id)).toEqual(["child", "old-child"])
      setStore("status", "child", "idle")
      expect(background.tasks().map((task) => task.id)).toEqual(["old-child"])
      setStore("notification", "metadata", "childID", "child")
      expect(background.tasks().map((task) => task.id)).toEqual(["old-child"])
      setStore("messages", [0, 1], "time", "completed", 1)
      expect(background.blocking()).toEqual([])
      expect(background.tasks().map((task) => task.id)).toEqual(["old-child", "shell"])
      dispose()
    })
  })
})
