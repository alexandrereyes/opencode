import type { NativeApps } from "@opencode/plugin-app-custom/native-apps/rpc"
import { createMemo, createResource } from "solid-js"
import type { Platform } from "@/runtime/platform/platform"
import type { ServerConnectionStatus } from "@/runtime/server/client"

export function createNativeAppAvailability(input: {
  platform: () => Platform["platform"]
  local: () => boolean
  server: () => string
  location: () => string
  status: () => ServerConnectionStatus
  list: (location: string) => Promise<NativeApps.Availability>
}) {
  const source = createMemo(
    () =>
      input.platform() === "web" && input.local() && input.status() === "connected"
        ? { server: input.server(), location: input.location() }
        : false,
    false,
    {
      equals: (previous, next) =>
        previous === next ||
        (!!previous && !!next && previous.server === next.server && previous.location === next.location),
    },
  )
  const [apps] = createResource(source, (request) =>
    input
      .list(request.location)
      .then((data) => ({ request, data }))
      .catch(() => ({ request, data: undefined })),
  )
  return {
    value: () => {
      const request = source()
      const result = apps()
      if (!request || !result || result.request !== request) return undefined
      return result.data
    },
    loading: () => apps.loading,
  }
}
