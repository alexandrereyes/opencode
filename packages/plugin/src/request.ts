import type { Form } from "@opencode/schema/form"
import type { Location } from "@opencode/schema/location"
import type { Permission } from "@opencode/schema/permission"

export interface PendingSnapshot {
  readonly location: Location.Ref
  readonly permissions: ReadonlyArray<Permission.Request>
  readonly forms: ReadonlyArray<Form.Info>
}
