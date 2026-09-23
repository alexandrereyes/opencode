export type ReadingAnchor = { rowKey: string; messageID: string; offset: number }
export type ReadingPosition = { pinned: boolean; anchor?: ReadingAnchor }

export function createReadingPositions(limit = 200) {
  const entries = new Map<string, ReadingPosition>()
  const get = (key: string) => {
    const entry = entries.get(key)
    if (!entry) return
    entries.delete(key)
    entries.set(key, entry)
    return entry
  }
  const update = (key: string, value: Partial<ReadingPosition>) => {
    const entry = { pinned: true, ...get(key), ...value }
    entries.set(key, entry)
    while (entries.size > limit) entries.delete(entries.keys().next().value!)
  }
  return {
    get,
    follow: (key: string, pinned: boolean) => update(key, { pinned }),
    anchor: (key: string, anchor: ReadingAnchor) => update(key, { anchor }),
  }
}

export const readingPositions = createReadingPositions()
