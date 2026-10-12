import { GlobalRegistrator } from "@happy-dom/global-registrator"
import { afterAll, beforeAll, expect, test } from "bun:test"
import { inlineCodeKind } from "./markdown-inline-code-kind"
import { markSessionLinks, sessionLinkCandidates, setupSessionLinks } from "./markdown-session-links"

const first = "ses_0123456789abcdefghijklmnop"
const second = "ses_abcdefghijklmnopqrstuvwxyz"
const all = () => true

beforeAll(() => GlobalRegistrator.register())
afterAll(() => GlobalRegistrator.unregister())

test("links complete IDs in prose and inline code without changing fenced code or existing links", () => {
  const root = document.createElement("div")
  root.innerHTML = `<p>Open ${first}, then <code>${second}</code>. See <a href="/docs">${first}</a>.</p><pre><code>${first}</code></pre>`
  expect(sessionLinkCandidates(root).toSorted()).toEqual([first, second])
  expect(markSessionLinks(root, all).toSorted()).toEqual([first, second])

  const links = root.querySelectorAll<HTMLButtonElement>("button[data-session-id]")
  expect([...links].map((button) => button.dataset.sessionId)).toEqual([first, second])
  expect(links[0]?.textContent).toBe(first)
  expect(links[1]?.innerHTML).toBe(`<code>${second}</code>`)
  expect(root.querySelector("pre button")).toBeNull()
  expect(root.querySelector("a button")).toBeNull()
  expect(root.textContent).toBe(`Open ${first}, then ${second}. See ${first}.${first}`)
})

test("leaves IDs inside rendered math as text", () => {
  const root = document.createElement("div")
  root.innerHTML = `<p>See ${first} and <span class="katex"><annotation encoding="application/x-tex">\\text{${second}}</annotation><span>${second}</span></span>.</p>`
  expect(sessionLinkCandidates(root)).toEqual([first])
  expect(markSessionLinks(root, all)).toEqual([first])
  expect(root.querySelector(".katex button")).toBeNull()
})

test("links only the IDs the host confirmed", () => {
  const root = document.createElement("div")
  root.innerHTML = `<p>${first} and ${second}, <code>${second}</code></p>`
  expect(markSessionLinks(root, (id) => id === first)).toEqual([first])
  expect([...root.querySelectorAll<HTMLButtonElement>("button")].map((button) => button.dataset.sessionId)).toEqual([
    first,
  ])
  expect(root.textContent).toBe(`${first} and ${second}, ${second}`)
})

test("ignores incomplete IDs, identifiers, code snippets and IDs in URLs", () => {
  const root = document.createElement("div")
  root.innerHTML = `<p>ses_123 and x${first} and ${first}more and <code>${first}extra</code> and <a href="https://example.com/${first}">${first}</a></p>`
  expect(sessionLinkCandidates(root)).toEqual([])
  markSessionLinks(root, all)
  expect(root.querySelector("button")).toBeNull()
})

test("does not link an unparsed fenced block while the markdown worker is pending", () => {
  const root = document.createElement("div")
  root.innerHTML = `\`\`\`text<br>${first}<br>\`\`\``
  expect(sessionLinkCandidates(root)).toEqual([])
  markSessionLinks(root, all)
  expect(root.querySelector("button")).toBeNull()
})

test("a session ID in inline code is never a file path candidate", () => {
  expect(inlineCodeKind(first)).toBeUndefined()
})

test("delegates keyboard-activated clicks to the latest rendered ID", () => {
  const root = document.createElement("div")
  const opened: string[] = []
  const dispose = setupSessionLinks(root, () => (id) => opened.push(id))
  root.innerHTML = `<p>${first}</p>`
  markSessionLinks(root, all)
  root.querySelector("button")?.click()
  root.innerHTML = `<p><code>${second}</code></p>`
  markSessionLinks(root, all)
  root.querySelector("button")?.click()
  expect(opened).toEqual([first, second])
  expect(root.querySelector("button")?.getAttribute("type")).toBe("button")
  dispose()
  root.querySelector("button")?.click()
  expect(opened).toEqual([first, second])
})
