import { createReactiveTimelineProjection } from "@opencode/session-ui-custom/timeline/projection"

export { reuseTimelineRows } from "@opencode/session-ui-custom/timeline/projection"

export function createTimelineProjection(input: Parameters<typeof createReactiveTimelineProjection>[0]) {
  return createReactiveTimelineProjection(input)
}
