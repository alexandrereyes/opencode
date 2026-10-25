/**
 * Local login page for the Chrome resource checks: a form with e-mail and password, a long scrollable area, and a
 * second page for back/forward, and `/animacao` (a spinner that repaints continuously). `POST /login` answers with the e-mail and the password length only; `GET /last`
 * returns the last login (e-mail and password length, never the password) and the deepest scroll reported by the page.
 *
 *   bun packages/plugin-app-custom/script/chrome-login-fixture.ts --port 5173
 */
import { parseArgs } from "node:util"

const args = parseArgs({ options: { port: { type: "string", default: "0" } } }).values

const last = { email: "", passwordLength: 0, maxScroll: 0 }

const page = (title: string, body: string) => `<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<script>addEventListener("scroll", () => { if (scrollY > 0) navigator.sendBeacon("/scrolled?y=" + Math.round(scrollY)) })</script>
<style>
  body { font: 17px -apple-system, system-ui, sans-serif; margin: 0; background: #f7f8fb; color: #111; }
  main { max-width: 420px; margin: 0 auto; padding: 32px 20px; }
  h1 { text-align: center; } label { display: block; margin: 16px 0 6px; }
  input { width: 100%; box-sizing: border-box; font: inherit; padding: 12px; border: 1px solid #ccd; border-radius: 10px; }
  input:focus { outline: 2px solid #2f6fe4; }
  button { width: 100%; margin-top: 20px; padding: 14px; font: inherit; color: #fff; background: #1f6feb; border: 0; border-radius: 10px; }
  .row { padding: 18px 0; border-bottom: 1px solid #dde; } a { color: #1f6feb; }
</style></head><body><main>${body}</main></body></html>`

const login = page(
  "Entrar · Abacato",
  `<h1>Abacato</h1><h2 style="text-align:center">Entrar</h2>
  <form method="post" action="/login">
    <label for="email">E-mail</label><input id="email" name="email" type="email" autocomplete="username" placeholder="voce@exemplo.com">
    <label for="password">Senha</label><input id="password" name="password" type="password" autocomplete="current-password" placeholder="Sua senha">
    <button id="submit" type="submit">Entrar</button>
  </form>
  <p style="text-align:center"><a id="help" href="/ajuda">Esqueci minha senha</a></p>
  ${Array.from({ length: 40 }, (_, index) => `<div class="row" id="row-${index + 1}">Linha ${index + 1}</div>`).join("")}`,
)

const server = Bun.serve({
  port: Number(args.port),
  hostname: "127.0.0.1",
  async fetch(request) {
    const url = new URL(request.url)
    const html = (body: string) => new Response(body, { headers: { "content-type": "text/html; charset=utf-8" } })
    if (url.pathname === "/last") return Response.json(last)
    if (url.pathname === "/scrolled") {
      last.maxScroll = Math.max(last.maxScroll, Number(url.searchParams.get("y")) || 0)
      return new Response(null, { status: 204 })
    }
    if (url.pathname === "/reset") {
      Object.assign(last, { email: "", passwordLength: 0, maxScroll: 0 })
      return new Response(null, { status: 204 })
    }
    if (url.pathname === "/" || url.pathname === "/login") {
      if (request.method !== "POST") return html(login)
      const form = await request.formData()
      const email = String(form.get("email") ?? "")
      const length = String(form.get("password") ?? "").length
      Object.assign(last, { email, passwordLength: length })
      return html(
        page(
          "Bem-vindo · Abacato",
          `<h1 id="welcome">Bem-vindo</h1><p id="who">${Bun.escapeHTML(email)}</p><p id="length">Senha com ${length} caracteres</p><p><a href="/login">Sair</a></p>`,
        ),
      )
    }
    if (url.pathname === "/animacao")
      return html(
        page(
          "Animação · Abacato",
          `<style>@keyframes spin { to { transform: rotate(360deg) } }</style><h1>Animação</h1><div id="spinner" style="width:120px;height:120px;margin:40px auto;border:12px solid #ccd;border-top-color:#1f6feb;border-radius:50%;animation:spin 1s linear infinite"></div>`,
        ),
      )
    if (url.pathname === "/ajuda")
      return html(page("Ajuda · Abacato", `<h1 id="help-title">Ajuda</h1><p><a href="/login">Voltar ao login</a></p>`))
    return new Response("Not found", { status: 404 })
  },
})

console.log(`chrome login fixture on http://127.0.0.1:${server.port}`)
