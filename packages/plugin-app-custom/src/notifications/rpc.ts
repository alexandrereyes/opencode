export * as Notifications from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"
import { LiveActivity } from "../live-activity/rpc.js"

/** Contract: `packages/plugin-app-custom/docs/session-notifications.md`. */

export interface RegisterInput extends Schema.Schema.Type<typeof RegisterInput> {}
export const RegisterInput = Schema.Struct({
  deviceID: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100)),
  /** The app's key for this server, echoed in every alert so a tap opens the session on the right server. */
  serverKey: LiveActivity.Attributes.fields.serverKey,
  environment: LiveActivity.Environment,
  /** The app's APNs device token (`registerForRemoteNotifications`), hex. */
  token: LiveActivity.Token.check(Schema.isMinLength(1)),
}).annotate({ identifier: "Notifications.RegisterInput" })

export const Definition = Rpc.define({
  id: "custom.notifications",
  methods: {
    register: {
      input: Schema.toStandardSchemaV1(RegisterInput),
      output: Schema.toStandardSchemaV1(Schema.Struct({ push: LiveActivity.Push })),
    },
    unregister: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ deviceID: RegisterInput.fields.deviceID })),
      output: Schema.toStandardSchemaV1(Schema.Struct({})),
    },
  },
  events: {},
})
