# Integração da faixa de voz

## Superfície

- `OpenCode/Voice/FloatingVoiceBar.swift`: view pura. Recebe `VoiceBarState`, `mute`, `end`, `retry`,
  `resume`, `expand(Bool)` e `transcript`. Não abre áudio, rede, tarefas da mestra ou Live Activity.
- `OpenCodeKit/Sources/OpenCodeKit/VoiceBarState.swift`: valor `Equatable & Sendable`, projeção das
  fases do motor, relógio e textos acessíveis pt-BR. `VoiceState.masterWorking + listening` vira
  `thinking`; progresso ausente quando a mestra está ociosa; mute deixa a onda plana.
- `OpenCode/Voice/FloatingVoicePresentation.swift`: adaptação fina ao motor e expansão compartilhada
  entre navegações. Lê `state`, `connectedAt`, `currentSpokenLine`, `masterProgressLine`, `busy`.
  A mudança de `sessionID` recolhe a faixa; o relógio atualiza apenas a view visível a cada segundo.

## Encaixes já aplicados

- `OpenCodeApp.swift`: contexto raiz e estado de apresentação único em `AppTabs`; o acessório da mestra
  segue a regra de sempre (oculto só dentro da conversa); `floatingVoiceInset` nas abas e nas listas de Sessões/Você.
  Os insets ficam dentro do `NavigationStack`, junto à lista que precisa receber sua margem. Reservam a altura
  completa da faixa, inclusive expandida, em vez de sobrepor uma janela à lista.
- `SessionsView.swift`: botão de onda em `primary` durante a voz; fixture usa somente ações locais.
- `ConversationView.swift`: `FloatingVoiceHost` entre timeline e bottomArea. O layout naturalmente
  reduz a viewport sem cobrir composer, bandeja ou teclado.

## Handoff concluído

Após a liberação do dono do motor, a montagem de `VoiceOverlay` e os tipos provisórios foram removidos.
`VoiceContext.swift` preserva o ambiente do controlador e fornece o `SessionStore` aos hosts de sheets.
O adapter usa os campos reais novos sem alterar o controlador, o transporte, a mestra ou ActivityKit.

`NewSessionView` e `EmptyMasterView` reservam espaço acima de seu composer. O composer fullscreen
tem host próprio acima do editor. `sessionAlertOverlay` usa o inset inferior em sheets comuns; seu
parâmetro `voice: false` evita duplicá-lo no fullscreen composer. As apresentações fullscreen de
arquivo/imagem usam o mesmo inset, fora dos controles do visualizador.
`FloatingVoiceScope` dá a faixa somente à apresentação modal superior e remove a faixa subjacente
também da árvore acessível. Isso evita duplicar controles ao ampliar o composer ou abrir outro sheet.

Uma regressão de foco foi reproduzida apenas com a faixa: `resignFirstResponder()` dentro de
`ComposerTextView.updateUIView` fazia UIKit consultar o próximo responder enquanto o grafo SwiftUI
ainda atualizava. A ponte agora agenda somente a resignação no ciclo seguinte e confirma novamente
`requestFocus`; não altera draft, seleção, envio nem retomada de foco. Os testes com e sem faixa
guardam o caso real de tocar a conversa para dispensar o teclado.

## Diferenças deliberadas do desenho

- **Alexandre, 25/10: a faixa da mestra continua visível.** Antes a faixa de voz substituía o acessório
  da mestra; agora as duas ficam empilhadas: faixa de voz, acessório da mestra e barra de abas. A faixa
  de voz é um `safeAreaInset` do conteúdo de cada aba e o `tabViewBottomAccessory` já entra na área
  segura desse conteúdo, então ela assenta acima do acessório sem medir alturas, e a lista reserva as
  duas (a última linha fica acima da faixa de voz). O acessório não se move quando a voz começa ou
  termina, e não ganhou animação nova. Os papéis não se sobrepõem: o acessório é a entrada da mestra e
  mostra pedidos pendentes (**Tudo em dia**, **N precisam de você** ou a indisponibilidade); a linha
  **Sessão mestra · …** da faixa expandida mostra o progresso da tarefa delegada por voz. VoiceOver lê o
  conteúdo da aba (com a faixa de voz) antes do acessório e da barra de abas, de cima para baixo.
- Onda, rótulo de estado e botão de onda ativo usam `primary` de cada família (OpenChamber: laranja),
  conforme a correção da revisão A; progresso da mestra e ações de recuperação mantêm `accent`.
- Encerrar é tonal `error`, não preenchido sólido: o catálogo atual não oferece `onError`, e não se
  reutiliza uma role de texto semanticamente incompatível apenas para reproduzir a imagem.
- Erro e interrupção têm ação textual adicional, mantendo mute/end nos mesmos lugares.
- Não se rouba gesto da lista: o gesto de recolher existe apenas nos limites da faixa.

## Contraste do polimento

Relógio, progresso e ícone de mute usam `glassSecondary`, derivada de cada família para pelo menos 4,5:1
nas superfícies e num limite conservador de luminância do vidro. O cálculo mantém a matiz do tema e não muda
o material, o layout, a onda/estado `primary` nem a composição tonal de encerrar. O mapeamento e a auditoria
estão em `script/generate-themes.ts` e `script/check-theme-contrast.ts`; nenhum hexadecimal entrou na view.

## Leitor de memória KV

**Ver transcrição** aparece somente na expansão, com ação nomeada equivalente no
VoiceOver. `FloatingVoiceHost` apresenta `VoiceTranscriptView` fora do `TimelineView`,
sem registrar outro `FloatingVoiceScope`: abrir o sheet não remove seu próprio host.
O leitor usa o `VoiceMemoryStore` observável da conexão ativa, e não uma cópia do
array ao abrir. Mostra resumo, roles, interrupção, pendências/indisponibilidade e
recorte de contexto; não oferece envio nem exclusão. Fechar preserva voz e expansão.

O fixture visual fornece memória sintética e uma ação DEBUG de atualização local
para verificar o leitor aberto. O motor falso é separado e exercita buffer/RPCs
reais no sandbox 4180. Os runners agora aceitam `OPENCODE_VOICE_DEVICE`,
`OPENCODE_VOICE_DERIVED`, `OPENCODE_VOICE_EVIDENCE` e `OPENCODE_VOICE_SERVER_URL`.
Esta frente usa **OpenCode Voz Memoria**, `ios-vozmem-derived` e `ios-vozmem-prints`.
Quatro casos direcionados passaram por tema, incluindo leitor atualizado enquanto
aberto e fechamento preservando expansão/chamada. O recorte do motor falso também
passou nas duas variantes; a rodada não repetiu os 80 estados históricos nem a
suíte completa. O hit target da nova ação cobre a linha inteira, não só os glifos.

## Verificação final

- Debug/test e Release: builds sem warnings, sem excluir testes de outra frente.
- `swift test`: 289 testes passaram na última rodada do checkout compartilhado.
- Oito testes de apresentação passaram nas duas variantes OpenChamber (suíte principal com sete
  casos e teste separado de nova sessão/composer fullscreen). Incluem o gesto real da lista, última
  linha totalmente visível, mute/end/retry, navegação, fonte acessível máxima e teclado abrir/fechar.
- Por tema, 20 testes passaram no recorte do motor falso: controlador/mestra/Activity, editing/key
  commands hospedados e `VoiceUITests` adaptado à faixa final.
- 80 capturas cobrem dez estados × compacto/expandido × Sessões/conversa × claro/escuro. Capturas
  extras registram teclado, Dynamic Type, fim da lista, composer fullscreen, nova sessão e motor falso.
- Nenhum áudio, chamada GPT Live ou prompt de modelo real; os históricos próprios foram removidos.

Manifesto com caminhos absolutos e resultados:
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-faixavoz-prints/verification.json`.

## Arquivos desta entrega

- Novos: `OpenCode/Voice/FloatingVoiceBar.swift`, `OpenCode/Voice/FloatingVoicePresentation.swift`,
  `OpenCode/Voice/VoiceBarFixtures.swift`, `OpenCode/Voice/VoiceContext.swift`,
  `OpenCodeKit/Sources/OpenCodeKit/VoiceBarState.swift`.
- Removido: `OpenCode/Voice/VoiceBar.swift` (view e janela provisórias; ambiente preservado em `VoiceContext`).
- Encaixes localizados: `OpenCode/OpenCodeApp.swift`, `OpenCode/SessionsView.swift`,
  `OpenCode/ConversationView.swift`, `OpenCode/SettingsView.swift`, `OpenCode/NewSessionView.swift`,
  `OpenCode/MasterSessionView.swift`, `OpenCode/ConversationComposer.swift`,
  `OpenCode/SessionAlertCenter.swift`, `OpenCode/FileViewer.swift`, `OpenCode/AttachmentPreview.swift`.
- Ponte de foco: `OpenCode/ComposerTextView.swift`.
- Testes/runner: `OpenCodeKit/Tests/OpenCodeKitTests/VoiceBarStateTests.swift`,
  `OpenCodeUITests/FloatingVoiceBarTests.swift`, `OpenCodeUITests/VoiceRowVisibility.swift`,
  `OpenCodeUITests/VoiceTests.swift`, `script/test-voice-bar.py`, `script/test-voice.py`.
- Documentação: `README.md`, `docs/voice.md`, `docs/voice-bar-integration.md`.

Os arquivos compartilhados também contêm alterações dos demais agentes; não foram reformatados nem
revertidos. `VoiceController`, `VoiceTransport`, `VoiceMaster`, drivers e extensão ActivityKit não foram
alterados por esta entrega. Simulador dedicado desligado ao final; nenhum commit realizado.
