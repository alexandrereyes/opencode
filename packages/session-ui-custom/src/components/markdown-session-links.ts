// Generated session IDs have a 26-character alphanumeric suffix. Require a complete token
// so a partially streamed ID, an identifier suffix, or a path does not become a link.
const sessionID = /(?<![A-Za-z0-9_])ses_[A-Za-z0-9]{26}(?![A-Za-z0-9_])/g
const exactSessionID = /^ses_[A-Za-z0-9]{26}$/

/** Session IDs that could become links: complete IDs in prose and whole inline code, outside fenced code and links. */
export function sessionLinkCandidates(root: HTMLElement) {
  if (!linkable(root)) return []
  return [
    ...new Set([
      ...[...root.querySelectorAll("code")].flatMap((code) => (sessionCode(code) ? [code.textContent!] : [])),
      ...sessionTextNodes(root).flatMap((node) => [...node.data.matchAll(sessionID)].map((match) => match[0])),
    ]),
  ]
}

/** Turns the candidates `linked` accepts into buttons and returns their IDs. */
export function markSessionLinks(root: HTMLElement, linked: (id: string) => boolean) {
  if (!linkable(root)) return []
  const ids = new Set<string>()
  root.querySelectorAll("code").forEach((code) => {
    if (!sessionCode(code) || !linked(code.textContent!)) return
    ids.add(code.textContent!)
    const link = sessionButton(code.textContent!)
    code.replaceWith(link)
    link.replaceChildren(code)
  })
  sessionTextNodes(root).forEach((node) => {
    const matches = [...node.data.matchAll(sessionID)].filter((match) => linked(match[0]))
    if (!matches.length) return
    const fragment = document.createDocumentFragment()
    let start = 0
    matches.forEach((match) => {
      ids.add(match[0])
      fragment.append(node.data.slice(start, match.index), sessionButton(match[0]))
      start = match.index + match[0].length
    })
    fragment.append(node.data.slice(start))
    node.replaceWith(fragment)
  })
  return [...ids]
}

export function setupSessionLinks(root: HTMLElement, open: () => ((id: string) => void) | undefined) {
  const click = (event: MouseEvent) => {
    if (event.defaultPrevented || !(event.target instanceof Element)) return
    const button = event.target.closest("button[data-session-id]")
    if (!(button instanceof HTMLButtonElement) || !root.contains(button)) return
    const handler = open()
    if (!handler) return
    event.stopPropagation()
    handler(button.dataset.sessionId!)
  }
  root.addEventListener("click", click)
  return () => root.removeEventListener("click", click)
}

// The worker's escaped-raw fallback has no markdown elements; linking its text
// would turn IDs inside still-unparsed fenced code into buttons.
function linkable(root: HTMLElement) {
  return (
    !!root.textContent?.includes("ses_") && !!root.querySelector("p, li, blockquote, td, th, h1, h2, h3, h4, h5, h6")
  )
}

function sessionCode(code: Element) {
  return !code.closest("pre, a, button") && exactSessionID.test(code.textContent ?? "")
}

function sessionTextNodes(root: HTMLElement) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  const nodes: Text[] = []
  while (walker.nextNode()) {
    const node = walker.currentNode as Text
    if (node.parentElement?.closest("a, button, code, pre")) continue
    if (node.data.includes("ses_")) nodes.push(node)
  }
  return nodes
}

function sessionButton(id: string) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = "markdown-session-link"
  button.dataset.sessionId = id
  button.textContent = id
  return button
}
