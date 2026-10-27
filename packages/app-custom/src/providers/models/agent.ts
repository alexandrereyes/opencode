export function hasCustomAgent(items: Array<{ native?: boolean }>) {
  return items.some((item) => item.native === false)
}

export function resolveAgent<T extends { name: string }>(items: T[], name?: string) {
  return items.find((item) => item.name === name) ?? items.find((item) => item.name === "build") ?? items[0]
}

// A session may run a hidden primary agent, such as one a plugin assigns; keep it instead of
// falling back to a visible agent, which would switch the session on the next prompt.
export function resolveCurrentAgent<T extends { name: string; hidden?: boolean }>(items: T[], name?: string) {
  return (
    items.find((item) => item.name === name) ??
    resolveAgent(
      items.filter((item) => !item.hidden),
      name,
    )
  )
}
