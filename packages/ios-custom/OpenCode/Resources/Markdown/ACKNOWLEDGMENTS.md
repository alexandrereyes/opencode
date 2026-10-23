# Motores de formatação

O app desenha texto e tabelas nativamente. Os motores locais abaixo não recebem rede, credenciais, ferramentas ou código executável do usuário.

- **highlight.js 11.11.1** — BSD-3-Clause, https://github.com/highlightjs/highlight.js. Gramáticas convertidas em runs de texto/estilo por JavaScriptCore, fora do ator principal.
- **beautiful-mermaid 1.1.3** — MIT, https://github.com/lukilabs/beautiful-mermaid. A mesma versão da referência OpenChamber gera SVG fora do ator principal. O WKWebView exibe somente o SVG, com JavaScript e navegação externa desabilitados.
- **ELK/elkjs 0.11.0** — EPL-2.0, https://github.com/kieler/elkjs/tree/0.11.0. Distribuído sem modificações como dependência do beautiful-mermaid. O código-fonte correspondente está disponível nesse endereço; a licença completa está em `Licenses/elkjs-LICENSE.md.txt`.
- **entities 7.0.1** — BSD-2-Clause, https://github.com/fb55/entities. Dependência do beautiful-mermaid.
- **SwaTex/SwaTexRender 0.5.0** — MIT, https://github.com/PhraseHQ/SwaTex/tree/0.5.0. Parser/layout e desenho CoreText/CoreGraphics de fórmulas. As fontes KaTeX e avisos OFL são incluídos pelo bundle SwiftPM; os avisos adicionais e a licença principal acompanham este recurso.

As licenças completas estão em `Licenses/`. O bundle gerado fica em `dist/markdown-engines.js`, seguindo a exclusão existente de artefatos `**/dist` no lint do repositório. É reproduzido por `bun script/build-markdown-engines.ts`; nenhuma dependência npm é necessária no dispositivo. A dependência SwiftPM está fixada no projeto e em `Package.resolved`.
