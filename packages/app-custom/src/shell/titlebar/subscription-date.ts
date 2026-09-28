export function formatSubscriptionCountdown(value: string | null, now: number) {
  if (value === null) return "—"
  const minutes = Math.max(0, (Date.parse(value) - now) / 60_000)
  if (!Number.isFinite(minutes)) return "—"
  if (minutes >= 1440) return `${Number((minutes / 1440).toFixed(1))}d`
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h`
  return `${Math.ceil(minutes)}m`
}

export function formatSubscriptionShortDate(value: number, locale: string) {
  const parts = new Intl.DateTimeFormat(locale, {
    weekday: "short",
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(value)
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((item) => item.type === type)?.value ?? ""
  return `${part("weekday")}, ${part("day")}/${part("month")} ${part("hour")}:${part("minute")}`
}

export function formatSubscriptionDate(value: number | string, locale: string, weekdayFirst = false) {
  const parts = new Intl.DateTimeFormat(locale, {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    weekday: "long",
    hourCycle: "h23",
  }).formatToParts(new Date(value))
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((item) => item.type === type)?.value ?? ""
  const date = `${part("day")}-${part("month").replace(/\.$/, "")} ${part("hour")}:${part("minute")}`
  const weekday = `(${part("weekday")})`
  return weekdayFirst ? `${weekday} ${date}` : `${date} ${weekday}`
}

export function formatSubscriptionExpiry(value: string, now: number) {
  const minutes = Math.max(0, Math.ceil((Date.parse(value) - now) / 60_000))
  const days = Math.floor(minutes / 1440)
  const hours = Math.floor((minutes % 1440) / 60)
  return (
    [days ? `${days}d` : "", hours ? `${hours}h` : "", !days && minutes % 60 ? `${minutes % 60}m` : ""]
      .filter(Boolean)
      .join(" ") || "0m"
  )
}
