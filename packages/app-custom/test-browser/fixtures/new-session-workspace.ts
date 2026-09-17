import { expect, mock, test } from "bun:test"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"

const inventory = Promise.withResolvers<void>()
const [state, setState] = createStore({
  selected: "/trees/chosen" as string | undefined,
  defaultDestination: "local" as "local" | "new",
  locationReady: false,
  projectReady: false,
  gitReady: false,
})
const project = {
  id: "repo",
  worktree: "/repo",
  vcs: "git",
  worktrees: [{ directory: "/repo" }],
  sandboxes: [] as string[],
  time: { created: 1, updated: 1 },
}
const location = { directory: "/repo", project: { id: "repo", canonical: "/repo", directory: "/repo" } }
const serverClient = await import("@/runtime/server/client")

mock.module("@/workspaces/location", () => ({
  useWorkspaceLocation: () => () => ({ directory: "/repo", ref: { directory: "/repo" }, current: undefined }),
}))
mock.module("@/runtime/server/current", () => ({
  useServer: () => ({ ctx: { sync: { data: { project: [project], path: { home: "/home/test" } } } } }),
  useData: () => ({
    location: {
      info: () => (state.locationReady ? location : undefined),
      syncInfo: async () => {},
      vcs: {
        info: () => (state.gitReady ? { branch: { current: "main" } } : undefined),
        sync: async () => {},
      },
    },
    project: {
      get: () => (state.projectReady ? project : undefined),
      sync: async () => {},
    },
  }),
}))
mock.module("@/runtime/server/client", () => ({
  ...serverClient,
  useServerSDK: () => ({
    server: { type: "http", http: { url: "http://localhost:1234" } },
    scope: "test",
    api: {
      worktree: {
        list: async () => {
          await inventory.promise
          return [{ directory: "/repo" }]
        },
      },
      vcs: { branch: { list: async () => ({ data: [] }) } },
    },
    event: { listen: () => () => {} },
  }),
}))
mock.module("@/settings/model", () => ({
  useSettings: () => ({
    workspaces: {
      defaultDestination: () => state.defaultDestination,
      lastUsed: () => undefined,
      setLastUsed: () => {},
    },
  }),
}))
mock.module("@/shell/tabs/tabs", () => ({
  useTabs: () => ({ initializeDraftWorktrees: () => {} }),
}))

const { createNewSessionWorkspaceController } = await import("@/new-session/workspace/controller")

test("explicit destination survives cold metadata, incomplete inventory and default changes", async () => {
  const root = createRoot((dispose) => ({
    dispose,
    controller: createNewSessionWorkspaceController({
      selectedWorktree: () => state.selected,
      selectedBranch: () => undefined,
      setSelectedWorktree: (worktree) => setState("selected", worktree),
      setSelectedBranch: () => {},
      onViewAll: () => {},
    }),
  }))
  try {
    expect(root.controller.selection.value()).toBe("/trees/chosen")
    expect(root.controller.bar.visible()).toBe(false)

    setState({ locationReady: true, projectReady: true, gitReady: true })
    await Promise.resolve()
    expect(root.controller.selection.value()).toBe("/trees/chosen")

    inventory.resolve()
    await inventory.promise
    await Promise.resolve()
    expect(root.controller.project.workspaces()).not.toContain("/trees/chosen")
    expect(root.controller.selection.value()).toBe("/trees/chosen")

    setState("defaultDestination", "new")
    expect(root.controller.selection.value()).toBe("/trees/chosen")

    root.controller.selection.set("main")
    expect(root.controller.selection.value()).toBe("main")

    root.controller.selection.reset()
    expect(root.controller.selection.value()).toBe("create")
  } finally {
    root.dispose()
  }
})
