export * as Preferences from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

const Project = Schema.Struct({ worktree: Schema.String, expanded: Schema.Boolean })
const ProjectLibrary = Schema.Struct({
  projects: Schema.Array(Project),
  recentlyClosed: Schema.Array(Schema.String),
  lastProject: optional(Schema.String),
})
const Model = Schema.Struct({
  providerID: Schema.String,
  modelID: Schema.String,
  visibility: Schema.Literals(["show", "hide"]),
  favorite: optional(Schema.Boolean),
})
const Settings = Schema.Struct({
  followUpBehavior: Schema.Literals(["queue", "steer"]),
  autoApprove: Schema.Boolean,
  autoSave: Schema.Boolean,
  tabLayout: optional(Schema.Literals(["horizontal", "vertical"])),
  notifications: Schema.Struct({ agent: Schema.Boolean, permissions: Schema.Boolean, errors: Schema.Boolean }),
})

export const Data = Schema.Struct({
  projects: Schema.Record(Schema.String, Schema.mutableKey(ProjectLibrary)),
  sidebarOrder: Schema.Array(Schema.String),
  pinnedSessions: Schema.Array(Schema.String),
  models: Schema.Struct({
    user: Schema.Array(Model),
    variant: Schema.Record(Schema.String, Schema.mutableKey(Schema.String)),
  }),
  settings: Settings,
})
export type Data = typeof Data.Type

export const Profile = Schema.Struct({
  version: Schema.Literal(1),
  revision: Schema.Number,
  imported: Schema.Boolean,
  data: Data,
})
export type Profile = typeof Profile.Type

const ProjectTarget = { server: Schema.String, directory: Schema.String }
export const Intent = Schema.Union([
  Schema.Struct({ type: Schema.Literal("project.open"), ...ProjectTarget }),
  Schema.Struct({ type: Schema.Literal("project.close"), ...ProjectTarget }),
  Schema.Struct({ type: Schema.Literal("project.remove"), ...ProjectTarget }),
  Schema.Struct({ type: Schema.Literal("project.expand"), ...ProjectTarget }),
  Schema.Struct({ type: Schema.Literal("project.collapse"), ...ProjectTarget }),
  Schema.Struct({ type: Schema.Literal("project.touch"), ...ProjectTarget }),
  Schema.Struct({
    type: Schema.Literal("project.move"),
    ...ProjectTarget,
    toIndex: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  }),
  Schema.Struct({ type: Schema.Literal("sidebar.order"), order: Schema.Array(Schema.String) }),
  Schema.Struct({ type: Schema.Literal("sidebar.pin"), session: Schema.String, pinned: Schema.Boolean }),
  Schema.Struct({
    type: Schema.Literal("model.visibility"),
    providerID: Schema.String,
    modelID: Schema.String,
    visibility: Schema.Literals(["show", "hide"]),
  }),
  Schema.Struct({
    type: Schema.Literal("model.favorite"),
    providerID: Schema.String,
    modelID: Schema.String,
    favorite: Schema.Boolean,
  }),
  Schema.Struct({
    type: Schema.Literal("model.variant"),
    providerID: Schema.String,
    modelID: Schema.String,
    variant: Schema.String,
  }),
  Schema.Struct({ type: Schema.Literal("settings.followUpBehavior"), value: Schema.Literals(["queue", "steer"]) }),
  Schema.Struct({ type: Schema.Literal("settings.autoApprove"), value: Schema.Boolean }),
  Schema.Struct({ type: Schema.Literal("settings.autoSave"), value: Schema.Boolean }),
  Schema.Struct({ type: Schema.Literal("settings.tabLayout"), value: Schema.Literals(["horizontal", "vertical"]) }),
  Schema.Struct({
    type: Schema.Literal("settings.notification"),
    notification: Schema.Literals(["agent", "permissions", "errors"]),
    value: Schema.Boolean,
  }),
])
export type Intent = typeof Intent.Type

const Empty = Schema.Struct({})

export const Definition = Rpc.define({
  id: "custom.preferences",
  methods: {
    get: { input: Schema.toStandardSchemaV1(Empty), output: Schema.toStandardSchemaV1(Profile) },
    import: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ hasLegacyData: Schema.Boolean, data: Data })),
      output: Schema.toStandardSchemaV1(Profile),
    },
    mutate: { input: Schema.toStandardSchemaV1(Intent), output: Schema.toStandardSchemaV1(Profile) },
  },
  events: {
    updated: { schema: Schema.toStandardSchemaV1(Schema.Struct({ revision: Schema.Number })) },
  },
})
