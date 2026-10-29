# Referências visuais do OpenCode iOS

Capturas **do app nativo**, para usar como base de mockups — não são propostas de design.
Use a imagem da tela mais próxima como referência e preserve seus controles e hierarquia,
salvo quando a proposta pedir uma mudança explícita. Os PNGs ficam versionados junto ao índice.

## Origem e privacidade

- iPhone 17 Pro, iOS 27.0, Dynamic Type **Large** (padrão), retrato.
- OpenChamber escuro e claro; barra de status em **9:41**, bateria e sinal cheios.
  Todos os estados do índice têm versão escura; Sessões, Você, conversa e nova sessão também têm versão clara.
- Dados sintéticos: projetos, mensagens, modelos, contas de assinatura e recursos. Nenhuma sessão,
  credencial, foto, arquivo ou dado de saúde pessoal foi consultado.
- `ScreenCatalogFixture` reutiliza `ScrollFixtures`, os componentes de produção e as fixtures
  de assinaturas/voz. O transporte é fechado em memória: requisições desconhecidas falham;
  não existe fallback para rede. A URL de lançamento é apenas um identificador de isolamento.
- Os recursos são exemplos da **lista**, não streams ativos. Sessões é a raiz do app, sem barra
  de abas. Você abre como folha pelo avatar AR no cabeçalho.
- Os PNGs são reduzidos de 3× para 2× (804 × 1748) pelo `sips` do macOS, quantizados com
  `pngquant --quality=85-95 --speed 3 --strip --skip-if-larger` e recomprimidos com zlib.
  A resolução continua 2×; apenas a paleta tem perdas controladas. PNGs que não atingem a qualidade
  mínima ou não ficam menores são mantidos sem quantização. Textos e ícones são conferidos visualmente.
  Metadados de screenshot/EXIF são removidos, inclusive as dimensões antigas deixadas pelo `sips`.
  Datas relativas, animações nativas e versão do iOS podem mudar alguns pixels entre execuções.

## Regenerar

Requer macOS, Xcode com o runtime **iOS 27.0**, Python 3, `pngquant` (`brew install pngquant`)
e os pacotes Swift resolvíveis pelo Xcode.
Da raiz do repositório:

```sh
python3 packages/ios-custom/script/capture-screens.py
```

O script cria **um simulador novo por tema**, compila em Debug, executa apenas `ScreenCatalogTests`,
exporta os anexos do xcresult e limpa cada simulador, build e temporários mesmo em caso de erro.
Não usa aparelhos físicos, sandbox de backend, modelos pagos, `custom:update` ou TestFlight.
Não usa as portas 4096/4177/4178.

Para iterar, `--themes dark`, `--only testTabs` e `--output /caminho/temporario` limitam a execução.
`--derived /caminho/build` reaproveita somente um `build-for-testing` (não é apagado pelo script).
Não existe mais `--simulator`: **cada execução, inclusive parcial, cria e apaga seu próprio simulador**.
Não use simuladores compartilhados nem reutilize um dispositivo entre execuções: desinstalar o app
não limpa o Keychain. A separação por dispositivo é obrigatória e automática.
Cada lançamento verifica a presença da sessão sintética `ses_scroll_0000`, a URL isolada
`http://127.0.0.1:4183` e a ausência de barra de abas antes de qualquer interação.
Novas telas devem ganhar uma captura nomeada
em `OpenCodeUITests/ScreenCatalogTests.swift` e uma linha no índice abaixo.

As antigas rotinas `capture-polish.py`, `capture-markdown.py` e `test-*.py` continuam destinadas
a evidências temporárias de testes; este é o catálogo estável para mockups.

## Índice

<!-- A tabela abaixo acompanha os PNGs efetivamente capturados. -->

| Tela / estado | O que mostra e como chegar | Escuro | Claro |
| --- | --- | --- | --- |
| Sessões · Todas | Raiz: voz, +, avatar AR, faixa da mestra; projetos e chats misturados, cota e atenção | [PNG](sessions-list-all-dark.png) | [PNG](sessions-list-all-light.png) |
| Sessões · seções | Rolar até o fim: Trabalhando, Fixadas, Hoje, Ontem, Esta semana, Anteriores expandida e Arquivadas | [PNG](sessions-sections-history-dark.png) | [PNG](sessions-sections-history-light.png) |
| Cabeçalho com Configurações | Variante do Mac do cabeçalho compartilhado (engrenagem entre voz e +) | [PNG](sessions-header-settings-dark.png) | — |
| Sessões · Chats | Sessões → Chats | [PNG](sessions-list-chats-dark.png) | [PNG](sessions-list-chats-light.png) |
| Sessões · chats em Todas | Filtro Todas; chat e projeto na mesma lista, com avatares distintos | [PNG](sessions-chats-mixed-dark.png) | [PNG](sessions-chats-mixed-light.png) |
| Sessões · repositório | Sessões → Projeto Exemplo 0 | [PNG](sessions-list-repository-dark.png) | [PNG](sessions-list-repository-light.png) |
| Chips · não lida | Sessões; Projeto Exemplo 3 com ponto laranja, antes de Chats e dos projetos lidos | [PNG](sessions-chips-unread-dark.png) | [PNG](sessions-chips-unread-light.png) |
| Chips · em execução | Todas → Projeto Exemplo 0 rodando → Projeto Exemplo 3 não lido → ordem manual | [PNG](sessions-chips-running-dark.png) | [PNG](sessions-chips-running-light.png) |
| Chats · ordem manual | Manter pressionado Chats; primeiro por padrão, com Mover para depois disponível | [PNG](sessions-chats-order-menu-dark.png) | — |
| Seleção · toque longo | Sessões → manter pressionada a sessão sintética; Selecionar e aviso ao terminar | [PNG](sessions-select-context-menu-dark.png) | — |
| Seleção · modo ativo | Menu da sessão → Selecionar; círculos, 1 selecionada, Selecionar todas, OK e ⋯ | [PNG](sessions-select-mode-dark.png) | [PNG](sessions-select-mode-light.png) |
| Seleção · ações | Modo de seleção → ⋯; Arquivar/Excluir/Cancelar, sem executar mutações | [PNG](sessions-select-actions-dark.png) | — |
| Seleção · confirmação | ⋯ → Excluir (1); somente capturar e Cancelar, sem confirmar exclusão ou arquivamento | [PNG](sessions-select-delete-confirmation-dark.png) | — |
| Aviso ligado | Raiz; projeto sintético com sininho, sem alterar preferências no servidor | [PNG](sessions-notify-enabled-dark.png) | — |
| Deslizar · aviso | Deslizar a linha para a esquerda; ação Avisar ao terminar com sino (não acionada) | [PNG](sessions-swipe-notify-dark.png) | — |
| Você / Ajustes | Avatar AR → folha Você, assinaturas e aparência | [PNG](you-settings-default-dark.png) | [PNG](you-settings-default-light.png) |
| Temas | Folha Você → Tema | [PNG](you-themes-default-dark.png) | [PNG](you-themes-default-light.png) |
| Dados do iPhone | Folha Você → Dados do iPhone; fontes e permissões do simulador | [PNG](you-iphone-data-default-dark.png) | [PNG](you-iphone-data-default-light.png) |
| LLM proxy | Folha Você → Codex; contas e cotas sintéticas | [PNG](you-subscriptions-default-dark.png) | [PNG](you-subscriptions-default-light.png) |
| Nova sessão · Chats | Sessões → +; destino inicial Chats | [PNG](new-session-chats-empty-dark.png) | [PNG](new-session-chats-empty-light.png) |
| Nova sessão · projeto | Nova sessão → Projeto → Projeto Exemplo 0 | [PNG](new-session-project-empty-dark.png) | [PNG](new-session-project-empty-light.png) |
| Nova sessão pelo chip | Sessões → chip Projeto Exemplo 0 → +; projeto herdado sem abrir a folha Projeto | [PNG](new-session-from-repository-chip-dark.png) | [PNG](new-session-from-repository-chip-light.png) |
| Folha Projeto | Nova sessão → nome do destino; PNG no Projeto 0, SVG no Projeto 2 e iniciais nos demais | [PNG](new-session-project-sheet-dark.png) | [PNG](new-session-project-sheet-light.png) |
| Folha Diretório | Nova sessão de projeto → main | [PNG](new-session-directory-sheet-dark.png) | [PNG](new-session-directory-sheet-light.png) |
| Adicionar repositório | Folha Projeto → +; explorador do servidor sintético | [PNG](projects-add-repository-dark.png) | — |
| Conversa · mensagem normal | Sessões → primeira conversa; prompt curto | [PNG](conversation-user-normal-dark.png) | [PNG](conversation-user-normal-light.png) |
| Conversa · mensagem recolhida | Primeira conversa; prompt longo com expansão disponível | [PNG](conversation-user-collapsed-dark.png) | [PNG](conversation-user-collapsed-light.png) |
| Conversa · mensagem expandida | Mensagem recolhida → Mostrar mensagem completa | [PNG](conversation-user-expanded-dark.png) | [PNG](conversation-user-expanded-light.png) |
| Conversa · resposta e rodapé | Rolar a conversa; copiar/play, contexto/cache e prompt fixo | [PNG](conversation-answer-footer-dark.png) | [PNG](conversation-answer-footer-light.png) |
| Conversa · pendente | Primeira conversa com admissão sintética ainda não entregue | [PNG](conversation-user-pending-dark.png) | — |
| Troca rápida · folha | Conversa → avatar/título com ⌄; mesmos chips, grupos e linhas da raiz, atual com ✓ e Nova sessão no cabeçalho | [PNG](session-switcher-open-dark.png) | [PNG](session-switcher-open-light.png) |
| Troca rápida · busca | Folha Sessões → buscar “contraste”; busca combinada com o chip e resultado agrupado | [PNG](session-switcher-search-dark.png) | [PNG](session-switcher-search-light.png) |
| Conversa · atividade e fila | Conversa em execução: cartão Atividade aberto (Ler, Shell, Agente, Editar), bandeja trabalhando + duas mensagens na fila e composer vazio | [PNG](conversation-activity-open-dark.png) | [PNG](conversation-activity-open-light.png) |
| Cabeçalho do chat no Mac | Variante do Mac do avatar com anel, título e subtítulo compartilhados, com `…` e + | [PNG](conversation-title-bar-mac-dark.png) | — |
| Composer com texto | Conversa → campo de mensagem; teclado e microfone compacto | [PNG](conversation-composer-text-dark.png) | [PNG](conversation-composer-text-light.png) |
| Menu + | Conversa → + do composer vazio | [PNG](conversation-add-menu-dark.png) | [PNG](conversation-add-menu-light.png) |
| Modelos | Conversa → Modelo Exemplo | [PNG](conversation-model-picker-dark.png) | [PNG](conversation-model-picker-light.png) |
| Agente | Conversa → build, abaixo do composer | [PNG](conversation-agent-picker-dark.png) | — |
| MCPs | Conversa → pílula de MCPs, ao lado do modelo | [PNG](conversation-mcp-picker-dark.png) | — |
| Detalhes da sessão | Conversa → ⋯ → Detalhes da sessão (também acessível pelo contexto/cache); uso, projeto e diretório | [PNG](session-details-default-dark.png) | [PNG](session-details-default-light.png) |
| Agentes e recursos | Conversa → pílula no cabeçalho → Agentes (3); ativo antes dos encerrados, iOS/Android e Chrome aninhado | [PNG](session-agents-resources-dark.png) | — |
| Agentes encerrados | Agentes (3) → rolar; encerrados pela última execução, não pela criação | [PNG](session-agents-finished-dark.png) | — |
| Scripts · em execução | Agentes e tarefas → Scripts (1); comando sintético e ação Parar | [PNG](session-agents-scripts-dark.png) | — |
| Scripts · vazio | Agentes e tarefas → Scripts (0); “Nenhum script em segundo plano.” | [PNG](session-agents-scripts-empty-dark.png) | — |
| Explorador de arquivos | Detalhes → Diretório de trabalho | [PNG](files-explorer-default-dark.png) | — |
| Arquivo Markdown | Explorador → README.md; renderização e player de leitura | [PNG](files-markdown-default-dark.png) | — |
| Arquivo de imagem | Explorador → preview.png; imagem sintética | [PNG](files-image-default-dark.png) | — |
| Prévia HTML offline | Explorador → index.html; página e theme.css sintéticos no modo Arquivos locais, sem internet | [PNG](files-html-preview-dark.png) | — |
| Sessão mestra | Faixa Sessão mestra; estado antes da primeira mensagem | [PNG](master-session-empty-dark.png) | — |
| Voz | Faixa de voz falando, acima da faixa da mestra | [PNG](sessions-voice-speaking-dark.png) | — |
| Citação no rascunho | Conversa com citação sintética → Citações · 1 | [PNG](conversation-quote-draft-dark.png) | — |
| Comentário | Citação no rascunho → Editar citação | [PNG](conversation-quote-comment-dark.png) | — |
| Citação · 1 | Citação → Ir ao trecho citado → marcador | [PNG](conversation-quote-details-dark.png) | — |
| Pergunta paralela | Conversa → enviar `/btw Qual deve ser o primeiro passo?` | [PNG](conversation-side-question-dark.png) | — |

## Revisão da navegação

Revisão da margem da mestra e do transcript (base `eb29f1f92c`): a faixa usa **21 pt** de
margem horizontal, alinhada à faixa de voz (`eb29f1f92c`). As referências de Sessões, conversa
e troca rápida foram regeneradas após a reescrita do transcript e a estabilização das listas
(`affa405fd9`), com as mesmas fixtures sintéticas e sem executar ações destrutivas. A captura
usa sempre um simulador novo por execução; a porta de loopback é apenas identidade da fixture offline.
As imagens de troca rápida dessa revisão voltam ao padrão 2× e à mesma compressão do catálogo.

Revisão sem abas (base `b304370d13`): Sessões passa a ser a raiz, com voz, + e avatar AR que abre
Você como folha. Foram removidos os seis PNGs `dashboard-tab-*`, `requests-tab-*` e `projects-tab-*`.
Os helpers `openYou()`/`showSessions()` fazem a navegação das capturas. Todas inclui chats
(`3d9f2629ea`), com o mesmo avatar de duas bolhas e cor `chatAvatar` na raiz e na troca rápida;
a fixture mantém `/Chats/roteiro` e os projetos com PNG/SVG/iniciais.

O Projeto Exemplo 0 tem `notifySessions` ligado na fixture para mostrar o sino (`197395a2bd`): o menu
de toque longo e o deslizar mostram as ações atuais de aviso, sem acioná-las. Agentes e tarefas
usa agente, modelo e esforço atuais (`f6f8892302`). Os PNGs de conversa, arquivos, atividade, mestra
e folhas também são regenerados para retirar barras antigas quando apareciam sob as apresentações.
As mudanças de grade de tabelas (`34cc92a58d`) e colagem (`cccef4a7f8`) não alteram o conteúdo desses
cenários: não há tabela rolando nem colagem de imagem no catálogo principal.

Revisão dos ícones (base `9ff33a3ce8`): Projeto Exemplo 0 recebe um PNG 128×128 verde/azul;
Projeto Exemplo 2 recebe um SVG quadrado roxo autocontido. São desenhos genéricos produzidos em
`ScreenCatalogFixture.projectIcons`, colocados em `project.icon.override` como data URLs inline —
o mesmo campo usado pelo PATCH do projeto, **sem enviar PATCH a servidor algum**. Os demais projetos
(por exemplo Projeto Exemplo 3) não têm ícone e preservam as iniciais. Chips, linhas, troca rápida,
cabeçalho e seletor de projeto mostram os dois comportamentos no app real (`37e021a87b`/`9ff33a3ce8`).

`cbc9c169df` já atualizava referências após o layout compartilhado de chat (`aff7111287`): cartão de
atividade, bandeja de execução, chips e barra de título Mac continuam no índice e são recapturados.
`3fbe859a42` altera as ferramentas/prompt da mestra no backend, sem mudar o layout nativo do estado
vazio capturado; a referência da mestra é regenerada, sem executar prompts ou controles reais.

Antes desta revisão, o catálogo na base ocupava **21.771.431 bytes (20,76 MiB)**, incluindo README e 81 PNGs.
A nova versão ocupa aproximadamente **6,30 MiB**, redução de **69,6%**, mantendo os **81 PNGs em 2×**.
A compressão controlada acima faz parte da regeneração, não de um passo manual oculto.

Revisão da troca rápida e seleção em lote (base `cf17e904d67`): `sessions-*` agora mostra o chip Todas
apenas com `square.stack`/`filter-all` (`b2ce2d9a4ed`); cabeçalhos de conversa têm ⌄ e abrem a folha
de troca (`3c1abf05f6d`). A seleção em lote (`cf17e904d67`) foi capturada **sem confirmar Arquivar ou Excluir**:
o diálogo de exclusão é cancelado. As folhas de troca usam somente busca local sobre o catálogo sintético.
Para evitar retorno involuntário a uma conexão salva no Keychain, nenhum simulador é compartilhado
entre os temas; as imagens mostram exclusivamente Projeto Exemplo e sessões sintéticas. O transporte
continua fechado em memória, sem servidor, credencial pessoal ou chamadas pagas.
Após o rebase sobre `2fe84bbaa7`, o catálogo também impede `AgentsActivityAgent.watch()` em Debug:
o observador de push recém-adicionado à inicialização não acessa conexões salvas durante a captura.

Revisão dos agrupamentos e chips (base `0d717fc1dbd`): `sessions-*` recapturadas após `d6db386fe2a`,
`3ddf8f6b01e` e `0d717fc1dbd`. A ordenação dos chips é Todas, em execução, não lidas, posição manual
(incluindo Chats, primeiro por padrão), nome. A captura de não lidas desliga apenas os estados ativos
da fixture com `-OpenCodeCatalogNoRunning`; a de execução mantém o Projeto Exemplo 0 ativo antes do
Projeto Exemplo 3 não lido. O menu do Chats é mostrado sem confirmar uma alteração de preferência.
As seções de atenção, atividade e datas, os anéis de cota, o cabeçalho e o histórico continuam cobertos.

Live Activity (`002107761f3`/`128d59e1838`) acrescenta o widget do sistema e o driver, não uma tela das
abas já catalogadas. O catálogo usa `ScrollFixtureRoot`, que não inicia o driver de Live Activity de
`AppRoot`: nenhum registro APNs, notificação ou atividade real é criado. As demais telas capturadas
não tiveram alteração visual nesses commits; permanecem as referências da revisão anterior.

Revisão de 27/10/2026 (base `19025d2c22a`): catálogo regenerado após a ordenação por execução
(`19025d2c22a`) e herança do chip (`af7afcc7dae`). A fixture possui um agente ativo mais antigo que
dois encerrados; entre os encerrados, a última execução inverte a ordem de criação. O tempo do ativo
usa sua atualização mais recente, sem uma chamada real a modelo. A aba Scripts mantém um registro ativo e o estado vazio.

Também foram conferidos contexto pós-compactação (`0f765c8f026`), sugestões em `!` (`3818eb6c825`),
Markdown (`de10f5133b9`), citações (`0fee486030d`), HTML (`c2bb792fbba`/`eeccf4c8ac2`) e mestra
(`ea4a54f3317`). As capturas comuns não têm compactação, sugestões de arquivos nem mestra persistida;
esses estados específicos continuam fora do índice. As referências de contexto, Markdown, citações e mestra
são renderizadas novamente no app atual. As citações da fixture continuam locais: não há serviço de quotes real.
O HTML usa o visualizador real e seu handler de arquivos locais, com CSS entregue pelo transporte em memória;
a internet permanece bloqueada. Nenhum sandbox de backend ou servidor de arquivos é necessário.

Atualizado para os chips com não lidas (`27c3f84534c`) e as abas Agentes/Scripts (`6387448303a`).
O script de exemplo é apenas um registro em memória: nenhum comando é executado. As conversas
mostram o contador de um agente e um script; a fixture vazia usa `-OpenCodeCatalogNoScripts`.
`-OpenCodeCatalogUnread` deixa somente o Projeto Exemplo 3 não lido para evidenciar ponto e ordenação.
`-OpenCodeCatalogSections` preenche todas as seções da coluna de Sessões (pergunta, permissão e erro sintéticos,
uma fixada e dias relativos ao lançamento); sem ela, a primeira conversa continua logo abaixo dos filtros.
`-OpenCodeCatalogSettingsButton` mostra a engrenagem de Configurações que só o Mac usa.
A pergunta paralela é preparada por `-OpenCodeCatalogSideQuestion`, sem digitar `/btw` no XCTest
(essa digitação pode travar a consulta de acessibilidade). A folha respondida fica com o teclado fechado,
evitando o onboarding do teclado num simulador novo; folha e resposta usam os componentes reais.
Nas capturas que incluem teclado, o aviso inicial do QuickPath é dispensado antes de salvar o PNG.

## Limites

- **Ajustes** corresponde à folha **Você** nesta versão; não há uma segunda tela com esse título.
- Streams ao vivo de iOS, Android e Chrome não são iniciados: o catálogo cobre a lista de recursos
  sintéticos, evitando máquinas adicionais, permissões e serviços externos.
- A sessão mestra é mostrada antes da primeira mensagem; o catálogo não cria uma sessão mestra
  persistida. O Markdown mostra o controle de leitura, sem gerar voz nem simular áudio em reprodução.
- Diálogos de autenticação, permissões do sistema, download de modelos de voz, falhas de rede,
  pareamento e telas de envio real não fazem parte da referência principal.
- Os testes de comportamento existentes continuam sendo a fonte de cobertura de estados extremos;
  este catálogo não pretende substituir a suíte de regressão.
