import fs from "node:fs/promises"
import path from "node:path"
import { $ } from "bun"
import { expect } from "bun:test"
import { Effect } from "effect"
import { tmpdir } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { startServer } from "./fixture/server"
import { OpenCode } from "@opencode/client"
import { initRepo } from "../../core/test/fixture/git"

it.live(
  "lists, creates, and removes worktrees through the same location",
  () =>
    Effect.gen(function* () {
      const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-worktree-endpoint-")))
      const project = path.join(tmp.path, "project")
      const destination = path.join(tmp.path, "worktrees")
      yield* Effect.promise(() => fs.mkdir(project, { recursive: true }))
      yield* Effect.promise(() => $`git init`.cwd(project).quiet())
      yield* Effect.promise(() => $`git config user.email test@opencode.test`.cwd(project).quiet())
      yield* Effect.promise(() => $`git config user.name Test`.cwd(project).quiet())
      yield* Effect.promise(() => $`git commit --allow-empty -m root`.cwd(project).quiet())
      const server = yield* startServer(path.join(tmp.path, "config"))
      const url = new URL("/api/worktree", server.base)
      url.searchParams.set("location[directory]", project)

      const initial = yield* Effect.promise(() =>
        fetch(url, { headers: server.headers }).then((response) => response.json()),
      )
      expect(initial).toEqual([{ directory: project }])

      const created = yield* Effect.promise(() =>
        fetch(url, {
          method: "POST",
          headers: { ...server.headers, "content-type": "application/json" },
          body: JSON.stringify({ strategy: "git", directory: destination, name: "api" }),
        }).then((response) => response.json()),
      )
      expect(created).toEqual({ directory: path.join(destination, "api") })

      const listed = yield* Effect.promise(() =>
        fetch(url, { headers: server.headers }).then((response) => response.json()),
      )
      expect(listed).toContainEqual({
        directory: path.join(destination, "api"),
        strategy: "git",
      })

      const removed = yield* Effect.promise(() =>
        fetch(url, {
          method: "DELETE",
          headers: { ...server.headers, "content-type": "application/json" },
          body: JSON.stringify({ directory: path.join(destination, "api"), force: false }),
        }),
      )
      expect(removed.status).toBe(204)
    }),
  30_000,
)

it.live(
  "inspects and safely removes linked Git branches",
  () =>
    Effect.gen(function* () {
      const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-worktree-branches-")))
      const project = path.join(tmp.path, "project")
      const remote = path.join(tmp.path, "remote.git")
      const linked = path.join(tmp.path, "linked")
      yield* Effect.promise(async () => {
        await fs.mkdir(project)
        await initRepo(project)
        await $`git branch -M main`.cwd(project).quiet()
        await $`git init --bare ${remote}`.quiet()
        await $`git remote add fork+team ${remote}`.cwd(project).quiet()
        await $`git push -u fork+team main`.cwd(project).quiet()
        await $`git --git-dir ${remote} symbolic-ref HEAD refs/heads/main`.quiet()
        await $`git remote set-head fork+team -a`.cwd(project).quiet()
        await $`git branch feature main`.cwd(project).quiet()
        await $`git push -u fork+team feature`.cwd(project).quiet()
        await $`git worktree add ${linked} feature`.cwd(project).quiet()
      })
      const server = yield* startServer(path.join(tmp.path, "config"))
      const api = OpenCode.make({ baseUrl: server.base, headers: server.headers })

      yield* Effect.promise(async () => {
        expect(await api.worktree.list({ location: { directory: project } })).toContainEqual({
          directory: linked,
          strategy: "git",
        })
        const inspection = await api.worktree.inspect({ location: { directory: project }, directory: linked })
        expect(inspection).toMatchObject({
          directory: linked,
          branch: "feature",
          dirty: false,
          localBranch: { name: "feature" },
          remoteBranch: { name: "fork+team", branch: "feature" },
        })
        expect(inspection.identity).toBeString()
        await expect(
          api.worktree.delete({
            location: { directory: project },
            directory: linked,
            force: false,
            identity: inspection.identity,
            branch: "changed",
            deleteLocalBranch: true,
          }),
        ).rejects.toMatchObject({ data: { message: "The worktree branch changed" } })
        expect(await fs.stat(linked).then((item) => item.isDirectory())).toBe(true)
        await Bun.write(path.join(linked, "dirty.txt"), "dirty")
        expect((await api.worktree.inspect({ location: { directory: project }, directory: linked })).dirty).toBe(true)
        await expect(
          api.worktree.remove({ location: { directory: project }, directory: linked, force: false }),
        ).rejects.toMatchObject({ data: { forceRequired: true } })

        const result = await api.worktree.delete({
          location: { directory: project },
          directory: linked,
          force: true,
          identity: inspection.identity,
          branch: "feature",
          remote: { name: "fork+team", branch: "feature" },
          deleteLocalBranch: true,
          deleteRemoteBranch: true,
        })
        expect(result).toEqual({
          directory: linked,
          localBranch: { name: "feature", deleted: true },
          remoteBranch: { name: "feature", remote: "fork+team", deleted: true },
        })
        expect((await $`git branch --list feature`.cwd(project).text()).trim()).toBe("")
        expect((await $`git --git-dir ${remote} branch --list feature`.text()).trim()).toBe("")
      })
    }),
  30_000,
)

it.live(
  "protects the default branch and reports partial branch cleanup",
  () =>
    Effect.gen(function* () {
      const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-worktree-partial-")))
      const project = path.join(tmp.path, "project")
      const remote = path.join(tmp.path, "remote.git")
      const defaultTree = path.join(tmp.path, "default")
      const featureTree = path.join(tmp.path, "feature")
      yield* Effect.promise(async () => {
        await fs.mkdir(project)
        await initRepo(project)
        await $`git branch -M main`.cwd(project).quiet()
        await $`git init --bare ${remote}`.quiet()
        await $`git remote add fork+team ${remote}`.cwd(project).quiet()
        await $`git push -u fork+team main`.cwd(project).quiet()
        await $`git --git-dir ${remote} symbolic-ref HEAD refs/heads/main`.quiet()
        await $`git remote set-head fork+team -a`.cwd(project).quiet()
        await $`git checkout --detach`.cwd(project).quiet()
        await $`git worktree add ${defaultTree} main`.cwd(project).quiet()
      })
      const server = yield* startServer(path.join(tmp.path, "config"))
      const api = OpenCode.make({ baseUrl: server.base, headers: server.headers })

      yield* Effect.promise(async () => {
        await api.worktree.list({ location: { directory: project } })
        await fs.mkdir(path.join(defaultTree, "nested"))
        await expect(
          api.worktree.inspect({ location: { directory: project }, directory: project }),
        ).rejects.toMatchObject({ data: { message: `Invalid worktree directory: ${project}` } })
        await expect(
          api.worktree.inspect({ location: { directory: project }, directory: path.join(defaultTree, "nested") }),
        ).rejects.toMatchObject({ data: { message: `Invalid worktree directory: ${path.join(defaultTree, "nested")}` } })
        const defaultInspection = await api.worktree.inspect({ location: { directory: project }, directory: defaultTree })
        expect(defaultInspection).toMatchObject({
          directory: defaultTree,
          branch: "main",
          dirty: false,
        })
        expect(defaultInspection).not.toHaveProperty("localBranch")
        expect(defaultInspection).not.toHaveProperty("remoteBranch")
        await api.worktree.remove({ location: { directory: project }, directory: defaultTree, force: false })
        await $`git checkout main`.cwd(project).quiet()
        await $`git branch v2`.cwd(project).quiet()
        await $`git remote add origin ${remote}`.cwd(project).quiet()
        await $`git push origin v2`.cwd(project).quiet()
        await $`git --git-dir ${remote} symbolic-ref HEAD refs/heads/v2`.quiet()
        await $`git remote set-head origin -a`.cwd(project).quiet()
        await $`git checkout --detach`.cwd(project).quiet()
        await $`git worktree add ${defaultTree} v2`.cwd(project).quiet()
        await api.worktree.refresh({ location: { directory: project } })
        const untrackedDefault = await api.worktree.inspect({
          location: { directory: project },
          directory: defaultTree,
        })
        expect(untrackedDefault.branch).toBe("v2")
        expect(untrackedDefault).not.toHaveProperty("localBranch")
        expect(untrackedDefault).not.toHaveProperty("remoteBranch")
        await api.worktree.remove({ location: { directory: project }, directory: defaultTree, force: false })
        await $`git checkout main`.cwd(project).quiet()
        await $`git branch feature`.cwd(project).quiet()
        await $`git worktree add ${featureTree} feature`.cwd(project).quiet()
        await Bun.write(path.join(featureTree, "feature.txt"), "feature")
        await $`git add feature.txt`.cwd(featureTree).quiet()
        await $`git commit -m feature`.cwd(featureTree).quiet()
        await api.worktree.refresh({ location: { directory: project } })
        const featureInspection = await api.worktree.inspect({ location: { directory: project }, directory: featureTree })
        const result = await api.worktree.delete({
          location: { directory: project },
          directory: featureTree,
          force: false,
          identity: featureInspection.identity,
          branch: "feature",
          deleteLocalBranch: true,
        })
        expect(result.localBranch).toMatchObject({ name: "feature", deleted: false })
        expect(result.localBranch?.error).toContain("not fully merged")
        expect(await Bun.file(featureTree).exists()).toBe(false)
        expect(await api.worktree.list({ location: { directory: project } })).not.toContainEqual({
          directory: featureTree,
          strategy: "git",
        })
      })
    }),
  30_000,
)

it.live(
  "rejects a worktree recreated at the same path or replaced from another repository",
  () =>
    Effect.gen(function* () {
      const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-worktree-identity-")))
      const project = path.join(tmp.path, "project-a")
      const replacement = path.join(tmp.path, "project-b")
      const linked = path.join(tmp.path, "linked")
      const sibling = path.join(tmp.path, "sibling")
      yield* Effect.promise(async () => {
        await fs.mkdir(project)
        await initRepo(project)
        await $`git branch -M main`.cwd(project).quiet()
        await $`git branch feature`.cwd(project).quiet()
        await $`git branch sibling`.cwd(project).quiet()
        await $`git worktree add ${linked} feature`.cwd(project).quiet()
        await $`git worktree add ${sibling} sibling`.cwd(project).quiet()
      })
      const server = yield* startServer(path.join(tmp.path, "config"))
      const api = OpenCode.make({ baseUrl: server.base, headers: server.headers })

      yield* Effect.promise(async () => {
        await api.worktree.list({ location: { directory: project } })
        const inspection = await api.worktree.inspect({ location: { directory: project }, directory: linked })
        await $`git worktree remove ${linked}`.cwd(project).quiet()
        await $`git worktree add ${linked} feature`.cwd(project).quiet()
        await expect(
          api.worktree.delete({
            location: { directory: project },
            directory: linked,
            force: false,
            identity: inspection.identity,
            branch: inspection.branch ?? null,
          }),
        ).rejects.toMatchObject({ data: { message: "The worktree identity changed" } })
        expect(await fs.stat(linked).then((item) => item.isDirectory())).toBe(true)
        await $`git worktree remove ${linked}`.cwd(project).quiet()
        await $`git worktree remove ${sibling}`.cwd(project).quiet()
        await fs.mkdir(replacement)
        await initRepo(replacement)
        await Bun.write(path.join(replacement, "replacement.txt"), "different repository")
        await $`git add replacement.txt`.cwd(replacement).quiet()
        await $`git commit -m replacement`.cwd(replacement).quiet()
        await $`git branch -M main`.cwd(replacement).quiet()
        await $`git branch feature`.cwd(replacement).quiet()
        await $`git branch sibling`.cwd(replacement).quiet()
        await $`git worktree add ${linked} feature`.cwd(replacement).quiet()
        await $`git worktree add ${sibling} sibling`.cwd(replacement).quiet()

        await expect(
          api.worktree.inspect({ location: { directory: project }, directory: linked }),
        ).rejects.toMatchObject({ data: { message: `Directory is not a worktree of the requested project: ${linked}` } })

        await expect(
          api.worktree.delete({
            location: { directory: project },
            directory: linked,
            force: false,
            identity: inspection.identity,
            branch: inspection.branch ?? null,
          }),
        ).rejects.toMatchObject({ data: { message: `Directory is not a worktree of the requested project: ${linked}` } })
        expect(await Bun.file(path.join(linked, "replacement.txt")).text()).toBe("different repository")
        expect(await Bun.file(path.join(sibling, "replacement.txt")).text()).toBe("different repository")
      })
    }),
  30_000,
)

it.live(
  "rejects a registered root path replaced by another project",
  () =>
    Effect.gen(function* () {
      const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-worktree-root-owner-")))
      const project = path.join(tmp.path, "project")
      const remote = path.join(tmp.path, "remote.git")
      const context = path.join(tmp.path, "context")
      const linked = path.join(tmp.path, "linked")
      yield* Effect.promise(async () => {
        await fs.mkdir(project)
        await initRepo(project)
        await Bun.write(path.join(project, "owner.txt"), "project a")
        await $`git add owner.txt`.cwd(project).quiet()
        await $`git commit --amend --no-edit`.cwd(project).quiet()
        await $`git branch -M main`.cwd(project).quiet()
        await $`git init --bare ${remote}`.quiet()
        await $`git remote add origin ${remote}`.cwd(project).quiet()
        await $`git push -u origin main`.cwd(project).quiet()
        await $`git --git-dir ${remote} symbolic-ref HEAD refs/heads/main`.quiet()
        await $`git clone ${remote} ${context}`.quiet()
        await $`git branch feature`.cwd(project).quiet()
        await $`git worktree add ${linked} feature`.cwd(project).quiet()
      })
      const server = yield* startServer(path.join(tmp.path, "config"))
      const api = OpenCode.make({ baseUrl: server.base, headers: server.headers })

      yield* Effect.promise(async () => {
        const owner = await api.location.get({ location: { directory: project } })
        const clone = await api.location.get({ location: { directory: context } })
        expect(clone.project.id).toBe(owner.project.id)
        await api.worktree.list({ location: { directory: project } })
        await api.worktree.list({ location: { directory: context } })
        await $`git worktree remove ${linked}`.cwd(project).quiet()
        await fs.rm(project, { recursive: true })
        await fs.mkdir(project)
        await initRepo(project)
        await Bun.write(path.join(project, "replacement.txt"), "project b")
        await $`git add replacement.txt`.cwd(project).quiet()
        await $`git commit --amend --no-edit`.cwd(project).quiet()
        await $`git branch feature`.cwd(project).quiet()
        await $`git worktree add ${linked} feature`.cwd(project).quiet()

        await expect(
          api.worktree.inspect({ location: { directory: context }, directory: linked }),
        ).rejects.toMatchObject({ data: { message: `Directory is not a worktree of the requested project: ${linked}` } })
        await expect(
          api.worktree.remove({ location: { directory: context }, directory: linked, force: true }),
        ).rejects.toMatchObject({ data: { message: `Directory is not a worktree of the requested project: ${linked}` } })
        expect(await Bun.file(path.join(linked, "replacement.txt")).text()).toBe("project b")
      })
    }),
  30_000,
)

it.live(
  "derives the project and creation defaults when the SDK omits its input",
  () =>
    Effect.gen(function* () {
      const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-worktree-default-location-")))
      const project = path.join(tmp.path, "project")
      const config = path.join(tmp.path, "config")
      const destination = path.join(tmp.path, "copies")
      yield* Effect.promise(async () => {
        await fs.mkdir(project)
        await initRepo(project)
        await fs.mkdir(config)
        await Bun.write(path.join(config, "opencode.json"), JSON.stringify({ worktree: { directory: destination } }))
      })
      const server = yield* startServer(config)
      const api = OpenCode.make({
        baseUrl: server.base,
        headers: { ...server.headers, "x-opencode-directory": encodeURIComponent(project) },
      })
      yield* Effect.promise(async () => {
        const created = await api.worktree.create()
        expect(path.dirname(created.directory)).toBe(destination)
        await api.worktree.refresh()
        expect(await api.worktree.list()).toContainEqual({
          directory: created.directory,
          strategy: "git",
        })
        await api.worktree.remove({ directory: created.directory, force: false })
        expect(await api.worktree.list()).toEqual([{ directory: project }])
      })
    }),
  30_000,
)

it.live(
  "uses checkout-local plugins and configuration for clones sharing a project",
  () =>
    Effect.gen(function* () {
      const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-worktree-plugins-")))
      const first = path.join(tmp.path, "first")
      const second = path.join(tmp.path, "second")
      const nested = path.join(first, "nested")
      const config = path.join(tmp.path, "config")
      const destination = path.join(tmp.path, "worktrees")
      yield* Effect.promise(async () => {
        await fs.mkdir(first)
        await initRepo(first)
        await $`git remote add origin git@github.com:example/worktree-fixture.git`.cwd(first).quiet()
        await $`git clone --no-hardlinks ${first} ${second}`.quiet()
        await $`git remote set-url origin https://github.com/example/worktree-fixture.git`.cwd(second).quiet()
        await fs.mkdir(nested)
        await fs.mkdir(config)
        await Bun.write(path.join(config, "opencode.json"), JSON.stringify({ worktree: { directory: destination } }))
        await Bun.write(
          path.join(nested, "opencode.json"),
          JSON.stringify({
            plugins: [
              { package: path.join(import.meta.dir, "fixture/worktree-plugin"), options: { strategy: "test-copy" } },
            ],
          }),
        )
      })
      const server = yield* startServer(config)
      const api = OpenCode.make({ baseUrl: server.base, headers: server.headers })
      yield* Effect.promise(async () => {
        const a = await api.location.get({ location: { directory: nested } })
        const b = await api.location.get({ location: { directory: second } })
        expect(a.project.id).toBe(b.project.id)
        const custom = await api.worktree.create({ location: { directory: nested }, name: "custom" })
        const builtin = await api.worktree.create({ location: { directory: second }, name: "builtin" })
        const legacy = await api.worktree.create({ location: { directory: second }, name: "legacy" })
        expect(custom.directory).toBe(path.join(destination, "custom"))
        expect(builtin.directory).toBe(path.join(destination, "builtin"))
        const otherRows = await api.worktree.list({ location: { directory: second } })
        expect(otherRows).toContainEqual({ directory: custom.directory, strategy: "test-copy" })
        const rows = await api.worktree.list({ location: { directory: nested } })
        expect(rows).toContainEqual({
          directory: custom.directory,
          strategy: "test-copy",
        })
        expect(rows).toContainEqual({ directory: builtin.directory, strategy: "git" })
        expect(rows).toContainEqual({ directory: legacy.directory, strategy: "git" })

        const inspection = await api.worktree.inspect({
          location: { directory: nested },
          directory: builtin.directory,
        })
        await api.worktree.delete({
          location: { directory: nested },
          directory: builtin.directory,
          force: false,
          identity: inspection.identity,
          branch: inspection.branch ?? null,
        })
        await api.worktree.remove({
          location: { directory: nested },
          directory: legacy.directory,
          force: false,
        })
        await expect(fs.stat(builtin.directory)).rejects.toThrow()
        await expect(fs.stat(legacy.directory)).rejects.toThrow()

        await Bun.write(path.join(custom.directory, "dirty.txt"), "keep me")
        const remove = new URL("/api/worktree", server.base)
        remove.searchParams.set("location[directory]", second)
        const unavailable = await fetch(remove, {
          method: "DELETE",
          headers: { ...server.headers, "content-type": "application/json" },
          body: JSON.stringify({ directory: custom.directory, force: true }),
        })
        expect(unavailable.status).toBe(400)
        expect(await unavailable.json()).toMatchObject({
          data: { message: "Worktree strategy unavailable: test-copy" },
        })
        expect(await Bun.file(path.join(custom.directory, "dirty.txt")).text()).toBe("keep me")
        remove.searchParams.set("location[directory]", nested)
        const failure = await fetch(remove, {
          method: "DELETE",
          headers: { ...server.headers, "content-type": "application/json" },
          body: JSON.stringify({ directory: custom.directory, force: false }),
        })
        expect(failure.status).toBe(400)
        expect(await failure.json()).toMatchObject({ data: { forceRequired: true } })
        expect(await Bun.file(path.join(custom.directory, "dirty.txt")).text()).toBe("keep me")

        await api.worktree.remove({
          location: { directory: nested },
          directory: custom.directory,
          force: true,
        })
        expect((await api.worktree.list({ location: { directory: nested } })).filter((row) => row.strategy)).toEqual([])
      })
    }),
  30_000,
)

it.live(
  "plugin calls await a different location's strategy and directory configuration",
  () =>
    Effect.gen(function* () {
      const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-worktree-delegate-")))
      const source = path.join(tmp.path, "source")
      const target = path.join(tmp.path, "target")
      const destination = path.join(tmp.path, "copies")
      yield* Effect.promise(async () => {
        for (const directory of [source, target]) {
          await fs.mkdir(directory)
          await initRepo(directory)
          await $`git remote add origin git@github.com:example/delegate-fixture.git`.cwd(directory).quiet()
        }
        await Bun.write(
          path.join(source, "opencode.json"),
          JSON.stringify({
            plugins: [
              { package: path.join(import.meta.dir, "fixture/worktree-delegate"), options: { directory: target } },
            ],
          }),
        )
        await Bun.write(
          path.join(target, "opencode.json"),
          JSON.stringify({
            worktree: { directory: destination },
            plugins: [
              { package: path.join(import.meta.dir, "fixture/worktree-plugin"), options: { strategy: "target-copy" } },
            ],
          }),
        )
      })
      const server = yield* startServer(path.join(tmp.path, "config"))
      const api = OpenCode.make({ baseUrl: server.base, headers: server.headers })
      yield* Effect.promise(async () => {
        await api.location.get({ location: { directory: source } })
        const url = new URL("/api/plugin/await-activation", server.base)
        url.searchParams.set("location[directory]", source)
        expect((await fetch(url, { method: "POST", headers: server.headers })).status).toBe(204)
        expect(await api.worktree.list({ location: { directory: target } })).toContainEqual({
          directory: path.join(destination, "delegated"),
          strategy: "target-copy",
        })
      })
    }),
  30_000,
)
