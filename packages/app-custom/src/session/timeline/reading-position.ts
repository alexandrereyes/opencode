export type ReadingAnchor = {
  key: string
  messageID: string
  offset: number
  scrollTop: number
}

// Small bookmarks outlive the bounded DOM/measurement caches, but not an app reload.
const positions = new Map<string, { pinned: boolean; anchor?: ReadingAnchor }>()

export const readingPosition = {
  get: (key: string) => positions.get(key),
  follow(key: string, pinned: boolean) {
    positions.set(key, { ...positions.get(key), pinned })
  },
  save(key: string, anchor: ReadingAnchor) {
    positions.set(key, { pinned: positions.get(key)?.pinned ?? false, anchor })
  },
}
