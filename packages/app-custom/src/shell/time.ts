type TimeKey =
  | "common.time.justNow"
  | "common.time.minutesAgo.short"
  | "common.time.hoursAgo.short"
  | "common.time.daysAgo.short"

type Translate = (key: TimeKey, params?: Record<string, string | number>) => string

export function getRelativeTime(dateString: string | number, t: Translate, now = Date.now()): string {
  const elapsed = elapsedTime(dateString, now)
  if (!elapsed) return ""
  if (elapsed.unit === "seconds") return t("common.time.justNow")
  return t(`common.time.${elapsed.unit}Ago.short`, { count: elapsed.count })
}

type CompactTimeKey = `common.time.${"seconds" | "minutes" | "hours" | "days"}.compact`

export function getCompactRelativeTime(
  date: string | number,
  plural: (key: CompactTimeKey, count: number) => string,
  now = Date.now(),
): string {
  const elapsed = elapsedTime(date, now)
  if (!elapsed) return ""
  return plural(`common.time.${elapsed.unit}.compact`, elapsed.count)
}

function elapsedTime(date: string | number, now: number) {
  const seconds = Math.max(0, Math.floor((now - new Date(date).getTime()) / 1000))
  if (!Number.isFinite(seconds)) return
  if (seconds < 60) return { unit: "seconds" as const, count: seconds }
  if (seconds < 3600) return { unit: "minutes" as const, count: Math.floor(seconds / 60) }
  if (seconds < 86400) return { unit: "hours" as const, count: Math.floor(seconds / 3600) }
  return { unit: "days" as const, count: Math.floor(seconds / 86400) }
}
