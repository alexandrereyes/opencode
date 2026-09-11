import type { NativeApp } from "@opencode/schema/native-app"
import { createResource } from "solid-js"
import type { Platform } from "@/runtime/platform/platform"
import type { ServerConnectionStatus } from "@/runtime/server/client"

export function createNativeAppAvailability(input: {
  platform: () => Platform["platform"]
  local: () => boolean
  status: () => ServerConnectionStatus
  list: () => Promise<NativeApp.Availability>
}) {
  const [apps] = createResource(
    () => input.platform() === "web" && input.local() && input.status() === "connected",
    () => input.list().catch(() => undefined),
  )
  return apps
}
