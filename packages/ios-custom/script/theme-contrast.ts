import { hexToOklch, oklchToHex } from "./theme/color"
import type { HexColor } from "./theme/types"

export function luminance(hex: string) {
  const components = [1, 3, 5].map((offset) => Number.parseInt(hex.slice(offset, offset + 2), 16) / 255)
  return components
    .map((value) => (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4))
    .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index]!, 0)
}

export function contrast(foreground: string, background: string) {
  const lightness = [luminance(foreground), luminance(background)].sort((a, b) => a - b)
  return (lightness[1]! + 0.05) / (lightness[0]! + 0.05)
}

export function mix(foreground: string, target: string, fraction: number): HexColor {
  return ("#" + [1, 3, 5].map((offset) => {
    const start = Number.parseInt(foreground.slice(offset, offset + 2), 16)
    const end = Number.parseInt(target.slice(offset, offset + 2), 16)
    return Math.round(start + (end - start) * fraction).toString(16).padStart(2, "0")
  }).join("")) as HexColor
}

export function composite(foreground: string, background: string): HexColor {
  const alpha = foreground.length === 9 ? Number.parseInt(foreground.slice(7, 9), 16) / 255 : 1
  return mix(background, foreground, alpha)
}

// Preserve each palette's hue; only move perceptual lightness as far as legibility requires.
export function legible(foreground: string, backgrounds: string[], minimum: number, light: boolean): HexColor {
  const opaque = foreground.slice(0, 7) as HexColor
  const passes = (candidate: string) => backgrounds.every((background) => contrast(candidate, background) >= minimum)
  if (passes(opaque)) return opaque
  const color = hexToOklch(opaque)
  const endpoint = oklchToHex({ ...color, l: light ? 1 : 0, c: 0 })
  if (!passes(endpoint)) throw new Error(`No contrast solution for ${foreground} on ${backgrounds}`)
  let low = 0
  let high = 1
  for (let step = 0; step < 24; step++) {
    const fraction = (low + high) / 2
    const candidate = oklchToHex({
      ...color, l: color.l + ((light ? 1 : 0) - color.l) * fraction, c: color.c * (1 - fraction),
    })
    if (passes(candidate)) high = fraction
    else low = fraction
  }
  return oklchToHex({ ...color, l: color.l + ((light ? 1 : 0) - color.l) * high, c: color.c * (1 - high) })
}
