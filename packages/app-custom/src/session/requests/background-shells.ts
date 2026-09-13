import type { LocationRef } from "@opencode/client/promise"
import type { ServerApi } from "@/runtime/server/api"

export async function syncSessionBackgroundShells(input: {
  sessionID: string
  current: LocationRef
  known: LocationRef[]
  message: Pick<ServerApi["message"], "list">
  sync: (location: LocationRef) => Promise<void>
}) {
  const page = async (cursor?: string): Promise<LocationRef[]> => {
    const response = await input.message.list({
      sessionID: input.sessionID,
      type: "location-switched",
      limit: 200,
      ...(cursor ? { cursor } : { order: "desc" }),
    })
    const locations = response.data.flatMap((message) => {
      if (message.type !== "location-switched") return []
      return [message.location, ...(message.previous ? [message.previous.location] : [])]
    })
    if (!response.cursor.next) return locations
    return [...locations, ...(await page(response.cursor.next))]
  }

  const history = await page().catch(() => [])
  const locations = [
    ...new Map(
      [input.current, ...input.known, ...history].map((location) => [
        JSON.stringify([location.directory, location.workspaceID]),
        location,
      ]),
    ).values(),
  ]
  await Promise.all(locations.map(input.sync))
}
