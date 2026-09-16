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
