# Referências visuais do OpenCode iOS

Capturas **do app nativo**, para usar como base de mockups — não são propostas de design.
Use a imagem da tela mais próxima como referência e preserve seus controles e hierarquia,
salvo quando a proposta pedir uma mudança explícita. Os PNGs ficam versionados junto ao índice.

## Origem e privacidade

- iPhone 17 Pro, iOS 27.0, Dynamic Type **Large** (padrão), retrato.
- OpenChamber escuro e claro; barra de status em **9:41**, bateria e sinal cheios.
  Todos os estados do índice têm versão escura; abas, conversa e nova sessão também têm versão clara.
- Dados sintéticos: projetos, mensagens, modelos, contas de assinatura e recursos. Nenhuma sessão,
  credencial, foto, arquivo ou dado de saúde pessoal foi consultado.
- `ScreenCatalogFixture` reutiliza `ScrollFixtures`, os componentes de produção e as fixtures
  de assinaturas/voz. O transporte é fechado em memória: requisições desconhecidas falham;
  não existe fallback para rede. A URL de lançamento é apenas um identificador de isolamento.
- Os recursos são exemplos da **lista**, não streams ativos. As três abas em construção são
  os placeholders reais do app, não funcionalidades simuladas.
- Os PNGs são reduzidos de 3× para 2× (804 × 1748) pelo `sips` do macOS e recomprimidos
  sem perda adicional com zlib, sem recortar a interface ou remover o perfil de cor.
  Metadados de screenshot/EXIF são removidos, inclusive as dimensões antigas deixadas pelo `sips`.
  Datas relativas, animações nativas e versão do iOS podem mudar alguns pixels entre execuções.

## Regenerar

Requer macOS, Xcode com o runtime **iOS 27.0**, Python 3 e os pacotes Swift resolvíveis pelo Xcode.
Da raiz do repositório:

```sh
python3 packages/ios-custom/script/capture-screens.py
```

O script cria seu próprio simulador, compila em Debug, executa apenas `ScreenCatalogTests`,
exporta os anexos do xcresult e limpa simulador, build e temporários mesmo em caso de erro.
Não usa aparelhos físicos, sandbox de backend, modelos pagos, `custom:update` ou TestFlight.
Não usa as portas 4096/4177/4178.

Para iterar, `--themes dark`, `--only testTabs` e `--output /caminho/temporario` limitam a execução.
`--derived /caminho/build` reaproveita um `build-for-testing`; `--simulator UDID` reaproveita um
simulador **que pertença à tarefa**. Esses dois recursos fornecidos explicitamente não são apagados
pelo script. Não use simuladores compartilhados. Novas telas devem ganhar uma captura nomeada
em `OpenCodeUITests/ScreenCatalogTests.swift` e uma linha no índice abaixo.

As antigas rotinas `capture-polish.py`, `capture-markdown.py` e `test-*.py` continuam destinadas
a evidências temporárias de testes; este é o catálogo estável para mockups.

## Índice

<!-- A tabela abaixo acompanha os PNGs efetivamente capturados. -->

| Tela / estado | O que mostra e como chegar | Escuro | Claro |
| --- | --- | --- | --- |
| Painel | Aba Painel; placeholder real | [PNG](dashboard-tab-default-dark.png) | [PNG](dashboard-tab-default-light.png) |
| Pedidos | Aba Pedidos; placeholder real | [PNG](requests-tab-default-dark.png) | [PNG](requests-tab-default-light.png) |
| Projetos | Aba Projetos; placeholder real | [PNG](projects-tab-default-dark.png) | [PNG](projects-tab-default-light.png) |
| Sessões · Todas | Aba Sessões, filtro Todas; inclui a faixa da mestra | [PNG](sessions-list-all-dark.png) | [PNG](sessions-list-all-light.png) |
| Sessões · Chats | Sessões → Chats | [PNG](sessions-list-chats-dark.png) | [PNG](sessions-list-chats-light.png) |
| Sessões · repositório | Sessões → Projeto Exemplo 0 | [PNG](sessions-list-repository-dark.png) | [PNG](sessions-list-repository-light.png) |
| Chips · não lida | Sessões; Projeto Exemplo 3 com ponto laranja, antes de Chats e dos projetos lidos | [PNG](sessions-chips-unread-dark.png) | [PNG](sessions-chips-unread-light.png) |
| Você / Ajustes | Aba Você, assinaturas e aparência | [PNG](you-settings-default-dark.png) | [PNG](you-settings-default-light.png) |
| Temas | Você → Tema | [PNG](you-themes-default-dark.png) | — |
| Dados do iPhone | Você → Dados do iPhone; fontes e permissões do simulador | [PNG](you-iphone-data-default-dark.png) | — |
| LLM proxy | Você → Codex; contas e cotas sintéticas | [PNG](you-subscriptions-default-dark.png) | — |
| Nova sessão · Chats | Sessões → +; destino inicial Chats | [PNG](new-session-chats-empty-dark.png) | [PNG](new-session-chats-empty-light.png) |
| Nova sessão · projeto | Nova sessão → Projeto → Projeto Exemplo 0 | [PNG](new-session-project-empty-dark.png) | [PNG](new-session-project-empty-light.png) |
| Folha Projeto | Nova sessão → nome do destino | [PNG](new-session-project-sheet-dark.png) | [PNG](new-session-project-sheet-light.png) |
| Folha Diretório | Nova sessão de projeto → main | [PNG](new-session-directory-sheet-dark.png) | [PNG](new-session-directory-sheet-light.png) |
| Adicionar repositório | Folha Projeto → +; explorador do servidor sintético | [PNG](projects-add-repository-dark.png) | — |
| Conversa · mensagem normal | Sessões → primeira conversa; prompt curto | [PNG](conversation-user-normal-dark.png) | [PNG](conversation-user-normal-light.png) |
| Conversa · mensagem recolhida | Primeira conversa; prompt longo com expansão disponível | [PNG](conversation-user-collapsed-dark.png) | [PNG](conversation-user-collapsed-light.png) |
| Conversa · mensagem expandida | Mensagem recolhida → Mostrar mensagem completa | [PNG](conversation-user-expanded-dark.png) | [PNG](conversation-user-expanded-light.png) |
| Conversa · resposta e rodapé | Rolar a conversa; copiar/play, contexto/cache e prompt fixo | [PNG](conversation-answer-footer-dark.png) | [PNG](conversation-answer-footer-light.png) |
| Conversa · pendente | Primeira conversa com admissão sintética ainda não entregue | [PNG](conversation-user-pending-dark.png) | — |
| Composer com texto | Conversa → campo de mensagem; teclado e microfone compacto | [PNG](conversation-composer-text-dark.png) | [PNG](conversation-composer-text-light.png) |
| Menu + | Conversa → + do composer vazio | [PNG](conversation-add-menu-dark.png) | [PNG](conversation-add-menu-light.png) |
| Modelos | Conversa → Modelo Exemplo | [PNG](conversation-model-picker-dark.png) | [PNG](conversation-model-picker-light.png) |
| Agente | Conversa → build, abaixo do composer | [PNG](conversation-agent-picker-dark.png) | — |
| MCPs | Conversa → pílula de MCPs, ao lado do modelo | [PNG](conversation-mcp-picker-dark.png) | — |
| Detalhes da sessão | Conversa → contexto/cache; uso, projeto e diretório | [PNG](session-details-default-dark.png) | [PNG](session-details-default-light.png) |
| Agentes e recursos | Conversa → pílula no cabeçalho → Agentes (1); iOS, Android e agente com Chrome aninhado | [PNG](session-agents-resources-dark.png) | — |
| Scripts · em execução | Agentes e tarefas → Scripts (1); comando sintético e ação Parar | [PNG](session-agents-scripts-dark.png) | — |
| Scripts · vazio | Agentes e tarefas → Scripts (0); “Nenhum script em segundo plano.” | [PNG](session-agents-scripts-empty-dark.png) | — |
| Explorador de arquivos | Detalhes → Diretório de trabalho | [PNG](files-explorer-default-dark.png) | — |
| Arquivo Markdown | Explorador → README.md; renderização e player de leitura | [PNG](files-markdown-default-dark.png) | — |
| Arquivo de imagem | Explorador → preview.png; imagem sintética | [PNG](files-image-default-dark.png) | — |
| Sessão mestra | Faixa Sessão mestra; estado antes da primeira mensagem | [PNG](master-session-empty-dark.png) | — |
| Voz | Faixa de voz falando, acima da faixa da mestra | [PNG](sessions-voice-speaking-dark.png) | — |
| Citação no rascunho | Conversa com citação sintética → Citações · 1 | [PNG](conversation-quote-draft-dark.png) | — |
| Comentário | Citação no rascunho → Editar citação | [PNG](conversation-quote-comment-dark.png) | — |
| Citação · 1 | Citação → Ir ao trecho citado → marcador | [PNG](conversation-quote-details-dark.png) | — |
| Pergunta paralela | Conversa → enviar `/btw Qual deve ser o primeiro passo?` | [PNG](conversation-side-question-dark.png) | — |

## Revisão da navegação

Atualizado para os chips com não lidas (`27c3f84534c`) e as abas Agentes/Scripts (`6387448303a`).
O script de exemplo é apenas um registro em memória: nenhum comando é executado. As conversas
mostram o contador de um agente e um script; a fixture vazia usa `-OpenCodeCatalogNoScripts`.
`-OpenCodeCatalogUnread` deixa somente o Projeto Exemplo 3 não lido para evidenciar ponto e ordenação.
A pergunta paralela é preparada por `-OpenCodeCatalogSideQuestion`, sem digitar `/btw` no XCTest
(essa digitação pode travar a consulta de acessibilidade). A folha respondida fica com o teclado fechado,
evitando o onboarding do teclado num simulador novo; folha e resposta usam os componentes reais.
Nas capturas que incluem teclado, o aviso inicial do QuickPath é dispensado antes de salvar o PNG.

## Limites

- **Ajustes** corresponde à própria aba **Você** nesta versão; não há uma segunda tela com esse título.
- Streams ao vivo de iOS, Android e Chrome não são iniciados: o catálogo cobre a lista de recursos
  sintéticos, evitando máquinas adicionais, permissões e serviços externos.
- A sessão mestra é mostrada antes da primeira mensagem; o catálogo não cria uma sessão mestra
  persistida. O Markdown mostra o controle de leitura, sem gerar voz nem simular áudio em reprodução.
- Diálogos de autenticação, permissões do sistema, download de modelos de voz, falhas de rede,
  pareamento e telas de envio real não fazem parte da referência principal.
- Os testes de comportamento existentes continuam sendo a fonte de cobertura de estados extremos;
  este catálogo não pretende substituir a suíte de regressão.
