import { useLanguage } from "@/runtime/i18n/language"
import { usePlatform } from "@/runtime/platform/platform"
import { isMixedContent } from "./browser"
import { redeemPairingLink, type Pairing, type PairingLink } from "./pairing"

type Redemption = { readonly pairing: Pairing } | { readonly error: string }

// Pasted and scanned links share one redeem path so every surface explains a failure the same way.
export function useRedeemPairing() {
  const language = useLanguage()
  const platform = usePlatform()

  return async (link: PairingLink): Promise<Redemption> => {
    const result = await redeemPairingLink(link, platform.fetch)
    if (result.type === "paired") return { pairing: result.pairing }
    if (result.type === "expired") return { error: language.t("server.connect.link.expired") }
    // A QR code can carry several addresses; the HTTPS page can reach none of them only when every one is plain HTTP.
    if (platform.platform === "web" && link.urls.every((url) => isMixedContent(location.href, url)))
      return { error: language.t("server.connect.mixedContent") }
    return { error: language.t("server.connect.link.unreachable", { url: link.urls.join(", ") }) }
  }
}
