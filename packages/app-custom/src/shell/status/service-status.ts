export function serviceStatus(statuses: readonly string[], error?: unknown) {
  if (error || statuses.includes("failed")) return "failed"
  if (statuses.includes("needs_auth")) return "needs_auth"
  if (statuses.includes("pending")) return "pending"
  if (statuses.some((status) => status === "connected" || status === "active")) return "active"
  return "disabled"
}
