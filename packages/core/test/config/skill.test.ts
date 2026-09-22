import fs from "fs/promises"
import path from "path"
import { describe, expect, test } from "bun:test"
import { Deferred, Effect, Fiber, Layer, Queue, Schedule, Schema, Stream } from "effect"
import { Event } from "@opencode/schema/event"
import { Config } from "@opencode/core/config"
import { Directory, Document, type Entry, Info } from "@opencode/schema/config"
import { ConfigSkillPlugin } from "@opencode/core/config/plugin/skill"
import { SkillFile } from "@opencode/core/config/plugin/skill-file"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { Watcher } from "@opencode/core/filesystem/watcher"
import { Bus } from "@opencode/core/bus"
import { Credential } from "@opencode/core/credential"
import { FSUtil } from "@opencode/util/fs-util"
import { Global } from "@opencode/util/global"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Location } from "@opencode/core/location"
import { AbsolutePath } from "@opencode/core/schema"
import { Skill } from "@opencode/core/skill"
import { SkillDiscovery } from "@opencode/core/skill/discovery"
import { WellKnown } from "@opencode/core/wellknown"
import { emptyCredentialNode, emptyWellknownNode } from "../fixture/config-nodes"
import { tmpdir } from "../fixture/tmpdir"
import { location } from "../fixture/location"
import { testEffect } from "../lib/effect"
import { host } from "../plugin/host"

const emptyDiscovery = SkillDiscovery.Service.of({ pull: () => Effect.succeed([]) })
const watcherLayer = Watcher.testLayer
const it = testEffect(
  Layer.merge(AppNodeBuilder.build(LayerNode.group([Skill.node, Bus.node, FSUtil.node])), watcherLayer),
)
const decode = Schema.decodeUnknownSync(Info)

function write(directory: string, name: string, description: string) {
  return fs.writeFile(
    path.join(directory, name, "SKILL.md"),
    `---
name: ${name}
description: ${description}
---
# ${name}`,
  )
}

const startEntries = Effect.fnUntraced(function* (
  entries: Entry[],
  directory: string,
  home = directory,
  discovery = emptyDiscovery,
  compatibility: { readonly claude: readonly AbsolutePath[]; readonly agents: readonly AbsolutePath[] } = {
    claude: [],
    agents: [],
  },
) {
  const service = yield* Skill.Service
  const pluginHost = host({
    skill: {
      list: () => Effect.die("unused skill.list"),
      transform: service.transform,
      reload: service.reload,
    },
  })
  yield* ConfigSkillPlugin.Plugin.effect(pluginHost).pipe(
    Effect.provide(Config.testLayer(entries, compatibility)),
    Effect.provideService(SkillDiscovery.Service, discovery),
    Effect.provideService(Global.Service, Global.Service.of({ ...Global.make(), home })),
    Effect.provideService(Location.Service, Location.Service.of(location({ directory: AbsolutePath.make(directory) }))),
  )
  return service
})

const start = (skills: string[], directory: string, discovery = emptyDiscovery) =>
  startEntries(
    [
      new Document({
        type: "document",
        info: decode({ skills }),
      }),
    ],
    directory,
    directory,
    discovery,
  )

/** Starts the plugin for one Location and counts the source scans and catalog reloads it performs. */
const startCounted = Effect.fnUntraced(function* (input: {
  directory: string
  skills?: string[]
  compatibility?: { readonly claude: readonly AbsolutePath[]; readonly agents: readonly AbsolutePath[] }
}) {
  const skill = yield* Skill.Service
  const filesystem = yield* FSUtil.Service
  const counts = { scans: 0, reloads: 0 }
  yield* ConfigSkillPlugin.Plugin.effect(
    host({
      skill: {
        list: () => Effect.die("unused skill.list"),
        transform: skill.transform,
        reload: () => Effect.sync(() => counts.reloads++).pipe(Effect.andThen(skill.reload())),
      },
    }),
  ).pipe(
    Effect.provide(
      Config.testLayer(
        input.skills ? [new Document({ type: "document", info: decode({ skills: input.skills }) })] : [],
        input.compatibility,
      ),
    ),
    Effect.provideService(
      FSUtil.Service,
      FSUtil.Service.of({
        ...filesystem,
        scan: (pattern, options) =>
          Effect.sync(() => counts.scans++).pipe(Effect.andThen(filesystem.scan(pattern, options))),
      }),
    ),
    Effect.provideService(SkillDiscovery.Service, emptyDiscovery),
    Effect.provideService(Global.Service, Global.Service.of({ ...Global.make(), home: input.directory })),
    Effect.provideService(
      Location.Service,
      Location.Service.of(location({ directory: AbsolutePath.make(input.directory) })),
    ),
  )
  return counts
})

// Ignored events leave nothing to await, so wait past the plugin's 100ms rescan debounce.
const settle = Effect.sleep("300 millis")

const waitFor = (condition: () => boolean) =>
  Effect.suspend(() => (condition() ? Effect.void : Effect.fail("pending" as const))).pipe(
    Effect.retry({ schedule: Schedule.spaced("10 millis") }),
    Effect.timeout("2 seconds"),
  )

const discover = (directory: string, global: string) =>
  Effect.gen(function* () {
    const config = yield* Config.Service
    return { entries: yield* config.entries(), compatibility: yield* config.compatibility!() }
  }).pipe(
    Effect.provide(
      AppNodeBuilder.build(LayerNode.group([Config.node, Bus.node]), [
        Location.node.replace(
          Layer.succeed(Location.Service, Location.Service.of(location({ directory: AbsolutePath.make(directory) }))),
        ),
        Global.node.replace(Global.layerWith({ config: global, home: path.join(global, "home") })),
        Credential.node.replace(emptyCredentialNode),
        WellKnown.node.replace(emptyWellknownNode),
        Watcher.node.replace(Watcher.testLayer),
      ]),
    ),
  )

function emitAndWait(update: Watcher.Update) {
  return Effect.gen(function* () {
    const watcher = yield* Watcher.Test
    const bus = yield* Bus.Service
    const deferred = yield* Deferred.make<void>()
    const fiber = yield* bus.subscribe(Skill.Event.Updated).pipe(
      Stream.runForEach(() => Deferred.succeed(deferred, undefined).pipe(Effect.asVoid)),
      Effect.forkScoped,
    )
    yield* Effect.yieldNow
    yield* watcher.emit(update)
    yield* Deferred.await(deferred).pipe(Effect.timeout("2 seconds"))
    yield* Fiber.interrupt(fiber)
  })
}

describe("SkillFile.parse", () => {
  test("parses root and nested skill ids and metadata flags", () => {
    const directory = "/repo/skills"
    expect(
      SkillFile.parse(
        directory,
        "/repo/skills/manual/SKILL.md",
        `---
name: Manual
description: Manual only
metadata:
  opencode/autoinvoke: false
---
# manual`,
      ),
    ).toEqual({
      _tag: "Parsed",
      skill: {
        id: Skill.ID.make("manual"),
        name: Skill.Name.make("Manual"),
        description: "Manual only",
        autoinvoke: false,
        path: AbsolutePath.make("/repo/skills/manual/SKILL.md"),
        content: "# manual",
      },
    })
    expect(SkillFile.parse(directory, "/repo/skills/foo.md", "# foo")).toMatchObject({
      _tag: "Parsed",
      skill: { id: Skill.ID.make("foo") },
    })
    expect(SkillFile.parse("/repo/skills/manual", "/repo/skills/manual/SKILL.md", "# manual")).toMatchObject({
      _tag: "Parsed",
      skill: { id: Skill.ID.make("manual"), name: Skill.Name.make("manual") },
    })
    expect(
      SkillFile.parse(directory, "/repo/skills/broken.md", "---\ndescription: foo: bar\nmetadata: [\n---\n# broken"),
    ).toEqual({ _tag: "Skipped", reason: "markdown" })
  })
})

describe("ConfigSkillPlugin.Plugin", () => {
  it.live("maps config entry types to skill directories", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const claude = path.join(tmp.path, "claude")
          const agents = path.join(tmp.path, "agents")
          const opencode = path.join(tmp.path, "opencode")
          const home = path.join(tmp.path, "home")
          const directory = path.join(tmp.path, "project")
          const expected = [
            path.join(claude, "skills"),
            path.join(agents, "skills"),
            path.join(opencode, "skill"),
            path.join(opencode, "skills"),
            path.join(home, "shared"),
            path.join(directory, "relative"),
          ]
          yield* Effect.promise(() => Promise.all(expected.map((item) => fs.mkdir(item, { recursive: true }))))

          yield* startEntries(
            [
              new Directory({ type: "directory", path: AbsolutePath.make(opencode) }),
              new Document({ type: "document", info: decode({ skills: ["~/shared", "./relative"] }) }),
            ],
            directory,
            home,
            emptyDiscovery,
            { claude: [AbsolutePath.make(claude)], agents: [AbsolutePath.make(agents)] },
          )
          const watcher = yield* Watcher.Test
          expect(yield* watcher.subscriptions()).toEqual(expected.map((item) => ({ path: item, type: "directory" })))
        }),
      ),
    ),
  )

  it.live("loads directory and individual downloaded skill roots with later-source precedence", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const first = path.join(tmp.path, "first")
          const second = path.join(tmp.path, "second")
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(first, "review"), { recursive: true })
            await fs.mkdir(path.join(second, "deploy"), { recursive: true })
            await fs.mkdir(path.join(second, "review"), { recursive: true })
            await write(first, "review", "First")
            await write(second, "deploy", "Deploy")
            await write(second, "review", "Second")
          })
          const pulls: string[] = []
          const discovery = SkillDiscovery.Service.of({
            pull: (url) => {
              pulls.push(url)
              return Effect.succeed([
                AbsolutePath.make(path.join(second, "deploy")),
                AbsolutePath.make(path.join(second, "review")),
              ])
            },
          })

          const skill = yield* start([first, "https://example.test/skills/"], tmp.path, discovery)
          expect((yield* skill.list()).map((item) => item.id).toSorted()).toEqual([
            Skill.ID.make("deploy"),
            Skill.ID.make("review"),
          ])
          expect((yield* skill.list()).find((item) => item.id === "deploy")?.description).toBe("Deploy")
          expect((yield* skill.list()).find((item) => item.id === "review")?.description).toBe("Second")
          expect(pulls).toEqual(["https://example.test/skills/"])
        }),
      ),
    ),
  )

  it.live("prefers a worktree skill over the parent checkout copy", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const checkout = path.join(tmp.path, "repo")
          const worktree = path.join(checkout, ".worktrees", "feature")
          const parentSkills = path.join(checkout, ".agents", "skills")
          const worktreeSkills = path.join(worktree, ".agents", "skills")
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(checkout, ".git"), { recursive: true })
            await fs.mkdir(path.join(parentSkills, "review"), { recursive: true })
            await fs.mkdir(path.join(worktreeSkills, "review"), { recursive: true })
            await fs.writeFile(path.join(worktree, ".git"), "gitdir: ../../../.git/worktrees/feature\n")
            await write(parentSkills, "review", "Parent checkout")
            await write(worktreeSkills, "review", "Worktree")
          })

          const discovered = yield* discover(worktree, path.join(tmp.path, "global"))
          const skill = yield* startEntries(
            discovered.entries,
            worktree,
            worktree,
            emptyDiscovery,
            discovered.compatibility,
          )
          const review = (yield* skill.list()).find((item) => item.id === "review")

          expect(review?.description).toBe("Worktree")
          expect(review?.path).toBe(AbsolutePath.make(path.join(worktreeSkills, "review", "SKILL.md")))
        }),
      ),
    ),
  )

  it.live("keeps directory skills when a URL source fails", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(tmp.path, "review"), { recursive: true })
            await write(tmp.path, "review", "Available")
          })
          const url = "https://unreachable.example.test/skills/"
          const discovery = SkillDiscovery.Service.of({ pull: () => Effect.die(`failed to pull ${url}`) })

          const skill = yield* start([tmp.path, url], tmp.path, discovery)
          expect((yield* skill.list()).find((item) => item.id === "review")?.description).toBe("Available")
        }),
      ),
    ),
  )

  it.live("skips unchanged config sources but refreshes ordered sources and watched files", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const first = path.join(tmp.path, "first")
          const second = path.join(tmp.path, "second")
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(first, "review"), { recursive: true })
            await fs.mkdir(path.join(second, "review"), { recursive: true })
            await write(first, "review", "First")
            await write(second, "review", "Second")
          })
          const config = yield* Config.Test
          const skill = yield* Skill.Service
          const filesystem = yield* FSUtil.Service
          const watcher = yield* Watcher.Test
          const counts = { scans: 0, reloads: 0, pulls: 0 }
          const updates = yield* Queue.unbounded<Deferred.Deferred<void>>()
          const url = "https://example.test/skills/"
          const entries = (skills: string[], shell = "/bin/sh") => [
            new Document({ type: "document", info: decode({ skills, shell }) }),
          ]
          yield* config.setEntries(entries(["./first", url]))
          yield* ConfigSkillPlugin.Plugin.effect(
            host({
              event: {
                subscribe: () =>
                  Stream.fromQueue(updates).pipe(
                    Stream.flatMap((done) =>
                      Stream.succeed({
                        id: Event.ID.create(),
                        created: Date.now(),
                        type: "config.updated" as const,
                        data: {},
                      }).pipe(Stream.concat(Stream.fromEffect(Deferred.succeed(done, undefined)).pipe(Stream.drain))),
                    ),
                  ),
              },
              skill: {
                list: () => Effect.die("unused skill.list"),
                transform: skill.transform,
                reload: () => Effect.sync(() => counts.reloads++).pipe(Effect.andThen(skill.reload())),
              },
            }),
          ).pipe(
            Effect.provideService(
              FSUtil.Service,
              FSUtil.Service.of({
                ...filesystem,
                scan: (pattern, options) =>
                  Effect.sync(() => counts.scans++).pipe(Effect.andThen(filesystem.scan(pattern, options))),
              }),
            ),
            Effect.provideService(
              SkillDiscovery.Service,
              SkillDiscovery.Service.of({
                pull: () =>
                  Effect.sync(() => {
                    counts.pulls++
                    return []
                  }),
              }),
            ),
            Effect.provideService(Global.Service, Global.Service.of({ ...Global.make(), home: tmp.path })),
            Effect.provideService(
              Location.Service,
              Location.Service.of(location({ directory: AbsolutePath.make(tmp.path) })),
            ),
          )
          const update = Effect.fnUntraced(function* (skills: string[], shell = "/bin/sh") {
            yield* config.setEntries(entries(skills, shell))
            const done = yield* Deferred.make<void>()
            yield* Queue.offer(updates, done)
            // The stream acknowledges only after the plugin has consumed this event.
            yield* Deferred.await(done).pipe(Effect.timeout("2 seconds"))
          })
          expect(counts).toEqual({ scans: 1, reloads: 0, pulls: 1 })
          yield* update(["./first", url], "/bin/zsh")
          expect(counts).toEqual({ scans: 1, reloads: 0, pulls: 1 })
          yield* update([first, first, url])
          expect(counts).toEqual({ scans: 1, reloads: 0, pulls: 1 })
          expect(yield* watcher.subscriptions()).toEqual([{ path: first, type: "directory" }])

          yield* update([first, second, url])
          expect(counts).toEqual({ scans: 3, reloads: 1, pulls: 2 })
          expect((yield* skill.list())[0]?.description).toBe("Second")
          yield* update([second, first, url])
          expect(counts).toEqual({ scans: 5, reloads: 2, pulls: 3 })
          expect((yield* skill.list())[0]?.description).toBe("First")
          yield* update([second, "https://example.test/other/"])
          expect(counts).toEqual({ scans: 6, reloads: 3, pulls: 4 })
          expect((yield* skill.list())[0]?.description).toBe("Second")

          yield* Effect.promise(() => write(second, "review", "Edited"))
          yield* emitAndWait({ type: "update", path: path.join(second, "review", "SKILL.md") })
          expect(counts).toEqual({ scans: 7, reloads: 4, pulls: 5 })
          expect((yield* skill.list())[0]?.description).toBe("Edited")
          yield* update([])
          expect(yield* skill.list()).toEqual([])
          expect(counts).toEqual({ scans: 7, reloads: 5, pulls: 5 })
        }).pipe(Effect.provide(Config.testLayer())),
      ),
    ),
  )

  it.live("ignores unrelated files in watched sources but reloads skill changes", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const root = path.join(tmp.path, "agents")
          const skills = path.join(root, "skills")
          const bucket = path.join(skills, "synced", "bucket")
          const outside = path.join(tmp.path, "outside")
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(bucket, "pdf", "scripts"), { recursive: true })
            await fs.mkdir(path.join(outside, "moved"), { recursive: true })
            await write(bucket, "pdf", "Pdf")
            await write(outside, "moved", "Moved")
            await fs.writeFile(path.join(bucket, "manifest.json"), "{}")
            await fs.writeFile(path.join(bucket, "pdf", "scripts", "notes.md"), "# notes")
          })
          const skill = yield* Skill.Service
          const watcher = yield* Watcher.Test
          const counts = yield* startCounted({
            directory: tmp.path,
            compatibility: { claude: [], agents: [AbsolutePath.make(root)] },
          })
          const ids = () => skill.list().pipe(Effect.map((items) => items.map((item) => item.id).toSorted()))
          expect(yield* ids()).toEqual([Skill.ID.make("pdf")])
          expect(counts).toEqual({ scans: 1, reloads: 0 })

          yield* Effect.promise(() => fs.writeFile(path.join(bucket, "manifest.json"), '{"synced":1}'))
          yield* watcher.emit({ type: "create", path: path.join(bucket, "manifest.json") })
          yield* watcher.emit({ type: "update", path: path.join(bucket, "manifest.json") })
          yield* watcher.emit({ type: "delete", path: path.join(bucket, ".manifest.tmp") })
          yield* watcher.emit({ type: "update", path: path.join(bucket, "pdf", "scripts", "notes.md") })
          yield* watcher.emit({ type: "delete", path: path.join(bucket, "pdf", "scripts", "gone") })
          yield* settle
          expect(counts).toEqual({ scans: 1, reloads: 0 })

          yield* Effect.promise(() => write(bucket, "pdf", "Edited"))
          yield* emitAndWait({ type: "update", path: path.join(bucket, "pdf", "SKILL.md") })
          expect(counts).toEqual({ scans: 2, reloads: 1 })
          expect((yield* skill.list())[0]?.description).toBe("Edited")

          // Directory moves only report the moved directory, not the skill files inside it.
          yield* Effect.promise(() => fs.rename(path.join(outside, "moved"), path.join(skills, "moved")))
          yield* emitAndWait({ type: "create", path: path.join(skills, "moved") })
          expect(yield* ids()).toEqual([Skill.ID.make("moved"), Skill.ID.make("pdf")])

          yield* Effect.promise(() => fs.rename(path.join(skills, "moved"), path.join(skills, "renamed")))
          yield* watcher.emit({ type: "delete", path: path.join(skills, "moved") })
          yield* emitAndWait({ type: "create", path: path.join(skills, "renamed") })
          expect(yield* ids()).toEqual([Skill.ID.make("pdf"), Skill.ID.make("renamed")])

          yield* Effect.promise(() => fs.rename(path.join(skills, "renamed"), path.join(outside, "renamed")))
          yield* emitAndWait({ type: "delete", path: path.join(skills, "renamed") })
          expect(yield* ids()).toEqual([Skill.ID.make("pdf")])

          yield* Effect.promise(() => fs.rm(path.join(bucket, "pdf"), { recursive: true }))
          yield* emitAndWait({ type: "delete", path: path.join(bucket, "pdf") })
          expect(yield* ids()).toEqual([])

          yield* Effect.promise(() => fs.writeFile(path.join(skills, "root.md"), "---\ndescription: Root\n---\n# root"))
          yield* emitAndWait({ type: "create", path: path.join(skills, "root.md") })
          expect(yield* ids()).toEqual([Skill.ID.make("root")])
          const reloads = counts.reloads
          yield* watcher.emit({ type: "update", path: path.join(bucket, "manifest.json") })
          yield* settle
          expect(counts.reloads).toBe(reloads)
        }),
      ),
    ),
  )

  it.live("reloads when a symlinked skill inside a source is created or retargeted", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const skills = path.join(tmp.path, "skills")
          const first = path.join(tmp.path, "first", "linked")
          const second = path.join(tmp.path, "second", "linked")
          const link = path.join(skills, "linked")
          yield* Effect.promise(async () => {
            await fs.mkdir(skills, { recursive: true })
            await fs.mkdir(first, { recursive: true })
            await fs.mkdir(second, { recursive: true })
            await fs.writeFile(path.join(first, "SKILL.md"), "---\ndescription: First\n---\n# linked")
            await fs.writeFile(path.join(second, "SKILL.md"), "---\ndescription: Second\n---\n# linked")
          })
          const skill = yield* Skill.Service
          const counts = yield* startCounted({ directory: tmp.path, skills: [skills] })
          expect(yield* skill.list()).toEqual([])

          yield* Effect.promise(() => fs.symlink(first, link, process.platform === "win32" ? "junction" : undefined))
          yield* emitAndWait({ type: "create", path: link })
          expect((yield* skill.list())[0]?.description).toBe("First")

          // Replacing a symlink is coalesced into one update of the link path.
          yield* Effect.promise(async () => {
            await fs.unlink(link)
            await fs.symlink(second, link, process.platform === "win32" ? "junction" : undefined)
          })
          yield* emitAndWait({ type: "update", path: link })
          expect((yield* skill.list())[0]?.description).toBe("Second")
          expect(counts).toEqual({ scans: 3, reloads: 2 })
        }),
      ),
    ),
  )

  it.live("keeps Locations sharing a source idle for unrelated files", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const root = path.join(tmp.path, "agents")
          const skills = path.join(root, "skills")
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(skills, "deploy"), { recursive: true })
            await write(skills, "deploy", "Deploy")
            await fs.writeFile(path.join(skills, "manifest.json"), "{}")
          })
          const watcher = yield* Watcher.Test
          const compatibility = { claude: [], agents: [AbsolutePath.make(root)] }
          const locations = yield* Effect.forEach(["one", "two", "three"], (name) =>
            startCounted({ directory: path.join(tmp.path, name), compatibility }),
          )
          expect(locations).toEqual(Array.from({ length: 3 }, () => ({ scans: 1, reloads: 0 })))
          const subscribed = (yield* watcher.subscriptions()).length

          yield* watcher.emit({ type: "update", path: path.join(skills, "manifest.json") })
          yield* settle
          expect(locations).toEqual(Array.from({ length: 3 }, () => ({ scans: 1, reloads: 0 })))
          expect((yield* watcher.subscriptions()).length).toBe(subscribed)

          yield* Effect.promise(() => write(skills, "deploy", "Edited"))
          yield* watcher.emit({ type: "update", path: path.join(skills, "deploy", "SKILL.md") })
          yield* waitFor(() => locations.every((counts) => counts.reloads === 1))
          expect(locations).toEqual(Array.from({ length: 3 }, () => ({ scans: 2, reloads: 1 })))
        }),
      ),
    ),
  )

  it.live("rescans directory sources when watched files change", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(tmp.path, "deploy"), { recursive: true })
            await write(tmp.path, "deploy", "Initial")
          })
          const skill = yield* start([tmp.path], tmp.path)
          expect((yield* skill.list()).find((item) => item.id === "deploy")?.description).toBe("Initial")

          const deploy = path.join(tmp.path, "deploy", "SKILL.md")
          yield* Effect.promise(() => write(tmp.path, "deploy", "Updated"))
          yield* emitAndWait({ type: "update", path: deploy })
          expect((yield* skill.list()).find((item) => item.id === "deploy")?.description).toBe("Updated")

          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(tmp.path, "review"), { recursive: true })
            await write(tmp.path, "review", "Review")
          })
          yield* emitAndWait({ type: "create", path: path.join(tmp.path, "review", "SKILL.md") })
          expect((yield* skill.list()).map((item) => item.id)).toEqual([
            Skill.ID.make("deploy"),
            Skill.ID.make("review"),
          ])

          yield* Effect.promise(() => fs.rm(path.join(tmp.path, "review"), { recursive: true }))
          yield* emitAndWait({ type: "delete", path: path.join(tmp.path, "review", "SKILL.md") })
          expect((yield* skill.list()).map((item) => item.id)).toEqual([Skill.ID.make("deploy")])
        }),
      ),
    ),
  )

  it.live("watches canonical directories behind symlinked skills", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const source = path.join(tmp.path, "source")
          const target = path.join(tmp.path, "target", "bro")
          const file = path.join(target, "SKILL.md")
          yield* Effect.promise(async () => {
            await fs.mkdir(source, { recursive: true })
            await fs.mkdir(target, { recursive: true })
            await fs.writeFile(file, "---\nname: bro\ndescription: Initial\n---\n# bro")
            await fs.symlink(target, path.join(source, "bro"), process.platform === "win32" ? "junction" : undefined)
          })

          const skill = yield* start([source], tmp.path)
          const watcher = yield* Watcher.Test
          expect((yield* skill.list()).find((item) => item.id === "bro")?.description).toBe("Initial")
          expect(yield* watcher.subscriptions()).toContainEqual({ path: target, type: "directory" })

          yield* Effect.promise(() => fs.writeFile(file, "---\nname: bro\ndescription: Updated\n---\n# bro"))
          yield* emitAndWait({ type: "update", path: file })
          expect((yield* skill.list()).find((item) => item.id === "bro")?.description).toBe("Updated")
        }),
      ),
    ),
  )

  it.live("reloads symlinked sources when their target changes", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const source = path.join(tmp.path, "source")
          const first = path.join(tmp.path, "first")
          const second = path.join(tmp.path, "second")
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(first, "bro"), { recursive: true })
            await fs.mkdir(path.join(second, "bro"), { recursive: true })
            await write(first, "bro", "First")
            await write(second, "bro", "Second")
            await fs.symlink(first, source, process.platform === "win32" ? "junction" : undefined)
          })

          const skill = yield* start([source], tmp.path)
          const watcher = yield* Watcher.Test
          expect((yield* skill.list()).find((item) => item.id === "bro")?.description).toBe("First")
          expect(yield* watcher.subscriptions()).toEqual([
            { path: first, type: "directory" },
            { path: source, type: "file" },
          ])

          yield* Effect.promise(async () => {
            await fs.unlink(source)
            await fs.symlink(second, source, process.platform === "win32" ? "junction" : undefined)
          })
          yield* emitAndWait({ type: "update", path: source })

          expect((yield* skill.list()).find((item) => item.id === "bro")?.description).toBe("Second")
          expect(yield* watcher.subscriptions()).toEqual([
            { path: first, type: "directory" },
            { path: source, type: "file" },
            { path: second, type: "directory" },
            { path: source, type: "file" },
          ])
        }),
      ),
    ),
  )

  it.live("follows missing compatibility skill directories as their parents appear", () =>
    Effect.acquireDisposable(Effect.promise(() => tmpdir())).pipe(
      Effect.flatMap((tmp) =>
        Effect.gen(function* () {
          const root = path.join(tmp.path, "generated")
          const source = path.join(root, "skills")
          const skill = yield* startEntries([], tmp.path, tmp.path, emptyDiscovery, {
            claude: [AbsolutePath.make(root)],
            agents: [],
          })
          const watcher = yield* Watcher.Test
          expect(yield* skill.list()).toEqual([])
          expect(yield* watcher.subscriptions()).toEqual([{ path: root, type: "file" }])

          yield* Effect.promise(() => fs.mkdir(root))
          yield* emitAndWait({ type: "create", path: root })
          yield* Effect.promise(async () => {
            await fs.mkdir(path.join(source, "deploy"), { recursive: true })
            await write(source, "deploy", "Deploy")
          })
          yield* emitAndWait({ type: "create", path: source })
          expect((yield* skill.list()).map((item) => item.id)).toEqual([Skill.ID.make("deploy")])
        }),
      ),
    ),
  )
})
