# Conversa por voz

O botão de onda em **Sessões** inicia uma chamada GPT Live. Nas abas, `FloatingVoiceBar` fica
empilhada logo acima do acessório da Sessão mestra, que continua visível e tocável entre ela e a
barra de abas (Alexandre, 25/10); na conversa, ocupa espaço acima do composer. Não há mais janela provisória no topo. A apresentação compartilhada continua durante a
navegação, e os sheets usam um inset inferior. Encerrar voz não interrompe tarefas já admitidas
pela Sessão mestra. Transporte, delegação e Live Activity são independentes dessa view.

A ponte de apresentação observa `state`, `elapsed`/`connectedAt`, `currentSpokenLine`,
`masterProgressLine` e `busy`; chama `mute()`, `end()`, `retry(sessions:)` e `resume()`.
O relógio é lido pela view, sem publicar ticks no controlador nem reconstruir toda a aplicação.
`VoiceBarState` mantém o contrato de apresentação puro. Compacta por padrão, a faixa expande por
toque e recolhe por toque/deslize para baixo; VoiceOver reúne estado, tempo e ações num elemento.
O modo de demonstração do layout é separado do motor falso, conforme
[`voice-bar-integration.md`](voice-bar-integration.md).

## macOS

O target `OpenCodeMac` compila os mesmos arquivos de voz, ditado e leitura do iPhone por membership do
projeto, sem cópias. O botão de onda inicia o mesmo controlador: origem privada, reserva, SDP WebRTC,
renovação/DELETE, recuperação, delegação e memória KV são os contratos abaixo. A voz é a mesma preferência
local `OpenCodeVoice`, com Rio como padrão e o mesmo fallback; Ajustes → Voz também abre a memória.

A `FloatingVoiceBar` fica **acima do compositor**. Isso mantém a chamada visível com Sessões recolhida,
durante navegação e junto ao texto; a lista e a barra da mestra mantêm seu espaço. Nova sessão e a revisão
do ditado têm seu próprio host da mesma faixa. Os controles e o leitor de transcrição são compartilhados.

Diferenças de plataforma:

- O WebRTC usa seu módulo Core Audio e AEC nativos, com entrada/saída padrão do sistema. Não há
  `AVAudioSession` nem reconstrução do peer ao trocar dispositivos; a seleção padrão é acompanhada pelo
  próprio WebRTC. Os sinais sonoros usam `AVAudioEngine`, inclusive início/fim no Mac.
- `MacRuntime` mantém um único `SessionStore.run()` para as janelas; `MacVoiceSession` guarda a chamada. Minimizar ou fechar
  todas as janelas durante uma chamada preserva áudio e progresso da mestra; encerrar o app ou trocar de
  servidor fecha a chamada.
- ActivityKit, vibração de telefone e App Intents continuam exclusivos do iOS. Uma falha com o Mac fora
  de foco gera uma notificação, se autorizada, sem incluir transcrição. O estado também fica na faixa.
- A permissão usa `AVCaptureDevice` no primeiro uso, com `NSMicrophoneUsageDescription` em pt-BR e
  `com.apple.security.device.audio-input` no hardened runtime. Negada, a UI explica e abre Ajustes do Sistema
  → Privacidade e Segurança → Microfone.
- FluidAudio **0.17.7 suporta macOS 14+**. O Mac usa o mesmo Parakeet Ultra local, download verificado,
  gravação PCM, pausa/pré-escuta, rascunhos pendentes e inserção sem sobrescrever a seleção. Clicar inicia
  mãos livres; segurar e soltar transcreve, arrastar para cima trava, para a esquerda descarta.
  **⌃⌥Espaço no editor** inicia/para; fn fica com o sistema. A revisão usa um sheet nativo com o editor real,
  em vez do fullscreen do telefone. Nada é enviado automaticamente. Mudança de dispositivo ou perda de foco
  pausa o ditado; isso não pausa uma chamada GPT Live.
- Respostas e arquivos Markdown usam `ConversationReadAloud`/`ReadAloudPlayer` e a voz de `custom.speech`,
  com os mesmos controles, velocidades, pré-carregamento limitado e posição no servidor. Essa voz de leitura
  é independente da escolha de GPT Live. Ditado/chamada pausam a leitura.

O arquivo M147 fixado pelo projeto tem um defeito de empacotamento: a slice macOS inclui o binário e o
umbrella, mas omite os headers públicos. O build do Mac executa `script/prepare-mac-webrtc.py`: recupera
apenas os headers comuns de áudio/dados da slice iOS **do mesmo arquivo verificado**, no produto de build.
Não altera o artefato SPM, o binário nem o build do iPhone; não precisa de outra versão ou servidor.

`script/test-mac-voice.py --app <OpenCodeMac.app> [--parakeet]` verifica/captura os componentes nativos
com a tela bloqueada, por desenho AppKit quando necessário. Usa o motor falso, os onze `VoiceBarFixtures`,
PCM gravado e um RPC de fala em memória; a opção Parakeet baixa os pesos para um diretório privado e testa
inferência local real. O runner usa uma cópia `.debug.voice-tests`, URL explícita **4203**, e encerra cada
processo; capturas e manifesto em `$TMPDIR/opencode/mac-voz-prints/`. Não faz chamada paga. Para o teste
de estabilidade paralelo, `OPENCODE_MAC_TEST_DOMAIN` separa os defaults do runner de outras frentes.

Áudio real, AEC perceptivo, troca física de fone e os diálogos de permissão precisam da conferência do
Alexandre. A resolução/rede do proxy não é substituída por uma origem pública se o WARP não permitir acesso.

### Integração com várias janelas

A chamada GPT Live e a Sessão mestra são únicas no app (`runtime.app`). A faixa aparece em **todas as
janelas**, com expansão e apresentação do leitor independentes. `MacWindow` fornece o ambiente da janela
no ponto de integração; o `safeAreaInset` do chat reserva o rodapé com a faixa acima de seu compositor.
`MacRuntime.front` identifica o destino do atalho e dos alertas; clicar na notificação restaura essa janela,
inclusive minimizada, ou abre uma nova quando todas foram fechadas.

`MacConversationInput` e `MacWindowRuntime.drafts` isolam rascunho, gravação, revisão e player por janela e
Sessão. Os RPCs de citações continuam compartilhados por Sessão, observados no mesmo EventHub; nenhuma
nova conexão SSE é criada. Um rascunho anterior é copiado na primeira abertura, com seus anexos/áudio local,
sem modificar o original. A seleção, o caret e o destino da transcrição pertencem à janela de origem.
⌃⌥Espaço é tratado pelo editor da janela da frente. Há um áudio de leitura por vez, como no iOS, mas a
navegação/fechamento da outra janela não interfere no player. O runner `test-mac-voice.py` abre duas janelas
na mesma Sessão em cada cenário e gera `<nome>.png` e `<nome>-second.png`, verificando isolamento dos
rascunhos, controles e atalho, expansão independente, mudo compartilhado e ausência de segunda chamada.

### Resultados da porta inicial

- **571 testes Kit** passaram. Os testes hospedados existentes de `VoiceController`, `VoiceMaster`,
  `VoiceActivity`, `DictationPipeline` e `ReadAloudPlayer`: **45 aprovados, três probes opt-in pulados**.
  Destino exclusivo: `OpenCode Mac Voz Regression` (`9F27B228-5A90-4051-84D2-40879C80D16A`). O host de
  testes abriu o fixture offline com URL explícita 4203. Nenhuma chamada a um modelo.
- O build de macOS Debug e Release passou sem warnings. O build iOS com Watch passou; seus avisos
  preexistentes estão em `ResponseText`, testes e `Vendor/OpenClawWatchRTC`, fora dos arquivos de voz
  alterados. O teste de estabilidade da janela também passou.
- **40 cenários de captura/checks** passaram nos dois temas, incluindo os onze estados da faixa,
  compacto, motor falso, leitura, gravação/pausa/revisão e Ajustes. Os checks de ditado verificam também
  token preservado, cancelamento ao perder a janela e novo clique após cancelar. Rascunhos de cada
  cenário usam diretórios temporários separados. Logs e `verification*.json` acompanham as imagens.
- Download real dos **632.162.964 bytes**, validação e inferência Parakeet no Mac: **7,957 s** de PCM,
  **9,220 s** para carregar/preparar e **0,084 s** para transcrever. Texto reconhecido preservou a frase,
  com um “o” extra em “Não o envie”, como no teste anterior do iPhone: a revisão permanece necessária.
- O proxy respondeu **HTTP 403** na raiz (sonda GET, sem criar chamada). O microfone do bundle de teste
  estava **não determinado**. Não foi aberta chamada GPT Live real nem apresentado diálogo para alguém
  aceitar com a tela bloqueada; entrada/saída real e AEC continuam como verificação manual.
- O comando de raiz `bun run check` não conseguiu iniciar o lint: `oxlint` ausente nesta worktree.
  O pacote nativo não pertence ao Turbo; os builds e testes acima são sua validação efetiva.

## Contrato privado do llm-proxy

Origem fixa: `http://llm-proxy-svc:8080`. O aplicativo não contém tokens ChatGPT nem usa o backend
Abacato. A exceção ATS é restrita a esse hostname. A infraestrutura privada precisa estar acessível
pelo WARP; não se publica essa origem na Internet.

1. `POST /_gpt-live/sessions/{UUID}` com `{"generation":"UUID"}` reserva a geração.
   A resposta 200 fornece `sessionId`, `generation`, `serverTime`, `leaseExpiresAt`; identidade e
   prazo são validados antes da negociação.
2. `POST /backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas`, JSON com `sdp`
   completo e `session`: modelo `gpt-live-1-codex`, `audio.output.voice` escolhido em Você (Rio por padrão), instruções pt-BR e
   `delegation.type=client` e, quando disponível, `initial_items` com a memória: os turnos como `user` e
   `assistant`, e o que o app informa (resumo, estado da mestra, pedidos em andamento) como `developer` (02/11).
   As instructions continuam curtas, somente com regras de comportamento. Headers: `OpenAI-Alpha: quicksilver=v2`, `originator: a2a-chat`,
   `session-id`, `thread-id`, `x-session-id` e `x-gpt-live-generation`. O proxy escolhe a conta e
   injeta credenciais. Só 201 com SDP e Location é aceito; criação ambígua não é repetida.
3. `PUT /_gpt-live/sessions/{UUID}`, mesmo body, a cada cinco segundos. Timeout HTTP de oito
   segundos e margem fixa de dez segundos no prazo retornado, medida desde o início da requisição
   que o confirmou. Rede inalcançável ou serviço sobrecarregado (erro de URL, HTTP 408, 429 ou qualquer
   5xx; o proxy responde 503 quando o Redis das leases cai ou falta capacidade) é repetida a cada
   segundo enquanto essa lease confirmada cobrir a chamada; ao fim dela o áudio fecha e a chamada é
   refeita, mesmo com uma renovação ainda em voo. Recusa explícita (outro HTTP: 404 lease ausente, 409
   conflito de geração, 410 expirada; lease malformada, de outra chamada ou já dentro da margem) encerra
   na hora, sem reconexão. A lease padrão no deploy é de 60 segundos.
4. Encerramento (02/11): com a sessão iniciada (`session.started`), o app silencia o microfone, manda
   `session.close` e espera `session.closed` ou o fechamento do canal por até 2 s
   (`VoiceRecoveryPolicy.closeWait`); a sondagem de 02/11 mediu 0,55 s e 1,1 s, sem nenhum outro evento no
   meio. Esse fechamento não reconecta, não registra perda nem passa pela moderação. Depois fecha
   mídia/canal/áudio local e envia `DELETE` com `generation` na query. Sem sessão iniciada ou sem canal
   aberto, encerra sem esperar. Perdas, tentativas falhas e falhas mandam `session.close` só como melhor
   esforço, sem esperar. Se a rede estiver indisponível, a lease do proxy expira; não há retry de criação.

O protocolo é o privado GPT Live/Codex, **não** `/v1/realtime` público. O canal `oai-events` transporta
`session.started`, `input_transcript.added`, `output_transcript.added`, `turn.done`,
`delegation.created`, `delegation.context.append`, `session.close` e `session.closed` (com `reason`, por exemplo
`client_request`, e `usage.audio_duration_ms`). Appends usam `channel=speakable` para o que deve ser falado e
`channel=commentary` para o estado quieto da mestra (`VoiceChannel`, 02/11; a rota recusa os
`session.commentary.append`/`session.thinking.append` oficiais), até 500 bytes UTF-8 por parte. Eventos e texto têm
limites locais. Erros remotos não são despejados em logs.

Desde 02/11 (quarta onda) o fio fica num lugar só por plataforma: no iPhone e no Mac, `VoiceProtocol` (Kit,
`VoiceProtocol.swift`) tem os eventos, os comandos, os nomes de campo e o corpo da criação, e `VoiceSignaling` fica com
o transporte HTTP (URL, query, cabeçalhos, lease); no Watch, `packages/plugin-app-custom/src/watch/protocol.ts` tem
tudo isso, e `voice.ts` a orquestração. Todo comando leva um `event_id` gerado pelo app (`oc_` e 16 dígitos
hexadecimais); a rota o aceita e o devolve só nos erros, em `error.event_id` (o `event_id` do topo do `error` é do
servidor; sem um nosso, `error.event_id` vem `null`). As confirmações (`session.context.appended`,
`delegation.context.appended`) não trazem ID: valem pela ordem, a de uma delegação pela ordem do seu item
(`VoiceCommandLog`). Numa chamada real de 02/11 (8,5 s, sem fala nem delegação), os bytes montados pelo Kit e pelo
`protocol.ts` foram aceitos como estão: `session.context.append` confirmado em 0,15 s; dois
`delegation.context.append` para itens inexistentes (um do Kit, um do Watch) voltaram como `error` com o nosso
`oc_…` em `error.event_id` em 0,12–0,14 s; `session.close` com `event_id` teve `session.closed` (`client_request`) em
0,56 s e o canal fechou em 0,98 s; `session.started` trouxe o mesmo `rtc_…` do `Location`.

### Rota do Codex e API oficial

O que muda numa troca futura para a API oficial (`/v1/live/sessions`, guias de conversas ao vivo e de delegação da
OpenAI). Comportamento segue a doc oficial; nomes e formatos, a rota. O `openai/codex` tem um TODO para alinhar a rota à
API oficial.

| Tema | Rota do Codex (o que os apps usam) | API oficial | iPhone/Mac | Watch (gateway) |
|---|---|---|---|---|
| Criação | `POST /backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas` com `OpenAI-Alpha: quicksilver=v2`; corpo `{sdp, session}` (`model: gpt-live-1-codex`, `instructions`, `audio.output.voice`, `delegation.type: client`); 201 com SDP e `Location` `…/rtc_…`; `session.started` traz `session.id` (o do `Location`) e `expires_at` (+2 h) | `POST /v1/live/sessions` com `transport.sdp`; resposta e `session.started` com `session.id` | `VoiceSignaling` + `VoiceProtocol.creation`; canal `oai-events`; ID da chamada nos diagnósticos (`remoteCall`) | `createPath`, `creation`; sideband `/v1/live/<id>` (WebSocket); ID e `expires_at` no log |
| Histórico | `session.initial_items` (`message` `developer`/`user`/`assistant`) | `session.input` (mesmas mensagens) | `VoiceProtocol.message` | `message` |
| Transcrições | `input_transcript.added`/`output_transcript.added` (`item.text`) | `session.input_transcript.delta`/`session.output_transcript.delta` (`delta`) | legenda, fala recente, fala parcial | legendas |
| Fim de turno | `turn.done` (`turn.role`, `turn.transcript`); o do usuário só com o turno seguinte do assistente | não há: o app agrupa os deltas | memória e contexto do pedido | idem |
| Delegação | `delegation.created` (`item.id`, texto = transcrição do turno, `user_bidi_turn_id`, `offset_ms`) | `session.delegation.created` (`delegation.id`, sem texto) | `delegate` | `receive` |
| Fala | `delegation.context.append` `channel: speakable`; confirmação `delegation.context.appended` (`delegation_item_id`, por ordem) | `session.commentary.append` (`delegation_id`, `content` texto); `session.commentary.appended` com `client_event_id` | resultado ouvido só com todas as confirmações | confirmações ignoradas |
| Contexto quieto | `delegation.context.append` `channel: commentary` (sem garantia de silêncio) | `session.thinking.append` / `.appended` | `VoiceMasterStatus` | `note` |
| Contexto da sessão | `session.context.append` (canal omitido = `speakable`); `session.context.appended` só por ordem | `session.commentary.append` ou `session.thinking.append` com `delegation_id: null` | resultado depois de uma reconstrução | não usa |
| Fechamento e motivo | `session.close` → `session.closed` (`reason: client_request`, `usage.audio_duration_ms`) | `session.close` → `session.closed` (`reason: close_requested`, `expired`, `content`, `remote_hangup`, `connection_lost`; `usage.seconds`) | `VoiceProtocol.close()`, espera até 2 s; `closedByModeration` | `close()`, espera o socket até 4 s; `closedByModeration` |
| Correlação de erros | `event_id` nosso em todo comando, de volta só em `error.event_id`; o do topo é do servidor | `event_id`; `client_event_id` no `error` e nas confirmações | `VoiceEvent.failure(command:)`, `VoiceCommandLog`; `failedCommand` nos diagnósticos | `clientEventID`/`serverEventID`; `failedCommand` no log |
| Mute | `input_audio.pause`/`input_audio.resume` (confirmados; não usados) | `session.input_audio.mute`/`unmute` | trilha local desligada | no relógio; o gateway não participa |

### Escolha da voz

**Você → Conversa por voz → Voz** apresenta Rio e Viola em **Brasileiras**, antes das demais vozes.
`GPTLiveVoice`, no Kit, é o catálogo único de IDs e nomes. `VoicePreferences` segue o padrão local
de UserDefaults, na chave `OpenCodeVoice`, independente do servidor. Sem escolha anterior, usa Rio
sem gravar uma preferência artificial; um ID local desconhecido também resolve para Rio sem apagar
o valor salvo. A escolha explícita persiste imediatamente. Não há prévia de áudio.

Catálogo entregue (25 vozes), baseado no enum v3 de `openai/codex`,
`codex-rs/protocol/src/protocol.rs` L261–409, revisão `f970f4be6783428af0d39527102917a5305c71d7`:

- **Aceitas pelo proxy:** Rio, Viola e Cove (verificação anterior), mais Porto, Selva, Tinta, Sol,
  Maple e Juniper (seis probes desta frente: todos HTTP 201 e DELETE 204, em 23/10/2026).
- **Ainda não verificadas ao vivo:** Spruce, Ember, Vale, Breeze, Arbor, Aube, Bubbie, Haetsal,
  Hanul, Himari, Leher, Miko, Neer, Rindo, Rivage e Sonna.
- Nenhum ID rejeitado/removido. Aceitação não comprova identidade ou qualidade perceptiva da voz.

O controlador captura a escolha no início da chamada. Alterar a preferência não renegocia nem
reinicia áudio; com a faixa visível, a tela informa **Vale a partir da próxima chamada**.

`VoiceSignaling.createCall` só tenta outra voz após HTTP 400/422 com rejeição estruturada do campo
`session.audio.output.voice` (ou código explícito `invalid_voice`/`unsupported_voice`). A ordem é a
escolhida → Rio → Cove, sem repetir um ID já rejeitado. Mantém a mesma oferta, memória e lease;
uma resposta válida usa a voz alternativa apenas nessa chamada. O toast informa a voz escolhida
indisponível e a alternativa realmente aceita, por exemplo **A voz Viola não está disponível; usando Rio**.
**A preferência salva nunca é alterada pelo fallback.** Se todas falharem, mostra o erro normal da
chamada. Timeout, erro de rede, HTTP não relacionado e criação 201 malformada nunca repetem a criação.

Verificação isolada: **OpenCode Voz Escolha** (`B0E8F258-19F2-42E8-B149-FFA462C7BD24`, iPhone 18 Pro/iOS 27),
`ios-vozescolha-derived`. Após `build-for-testing COPY_PHASE_STRIP=NO`, rode
`python3 packages/ios-custom/script/test-voice-picker.py` e repita com `OPENCODE_TEST_THEME=openchamber-light`.
O runner passa URL/senha explícitas do sandbox 4177 em todos os launches e não cria sessões nem muda
o serviço. A UI usa somente o fixture visual da faixa para o aviso de chamada ativa. Os testes Kit
cobrem catálogo, padrão, persistência, payload, ordem/limite de fallback e erros sem retry; os hospedados
cobrem captura por chamada, próxima chamada e toast sem sobrescrever a preferência.
Para regressões de Você no mesmo destino, `script/test-settings.py` aceita
`OPENCODE_SETTINGS_SIMULATOR`, `OPENCODE_SETTINGS_DERIVED` e `OPENCODE_SETTINGS_EVIDENCE`;
os padrões existentes permanecem intactos. Execute os runners sequencialmente nesse simulador.

O probe opcional exige `OPENCODE_TEST_LIVE_VOICE_CATALOG=1` e seleção exclusiva de
`OpenCodeTests/VoiceControllerTests/testExplicitSilentVoiceCatalogSample`. Faz no máximo seis criações
com Porto, Selva, Tinta, Sol, Maple e Juniper: oferta WebRTC nativa com trilha silenciada **antes** do POST,
sem aplicar resposta/abrir mídia e DELETE imediato após fechar o transporte local. Não envia fala nem
delega à mestra; verifica aceitação do ID, não qualidade. Não é executado pelas suítes normais.
Capturas/xcresults: `/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-vozescolha-prints/`.

Resultado desta frente: **309 testes Kit Debug / 308 Release**, builds do app Debug/test e Release sem
warnings, 13 testes de voz/seletor por tema (dois probes opt-in pulados) e os três casos existentes de
Você aprovados em ambos os temas. Os casos de servidores/pareamento foram repetidos separadamente,
com código novo, para não expirar durante o teste longo de temas. Os helpers de UI dispensam o alerta
local que cobria Voltar, usam **Agora Não** do AutoFill e revelam a linha de servidor após a reconstrução,
em vez de presumir que ela já está montada na primeira viewport. Não se alterou o comportamento do app
para contornar esses testes. `verification.json` no diretório de evidências registra resultados e capturas.

## Transporte e áudio

`VoiceTransport` mantém WebRTC em uma fila serial: factory, peer, oferta/resposta, observadores e
créditos de ativação de `RTCAudioSession`. As callbacks para a UI carregam somente valores. Ofertas
aguardam gathering completo por callback, sem polling. `maxBundle`, audio-only `sendRecv`, canal
ordenado antes da oferta, TCP candidates desabilitados e exclusão de link-local evitam trabalho
desnecessário. A reserva HTTP ocorre em paralelo à preparação nativa. A prontidão exige tanto
mídia/canal conectados quanto `session.started`; há deadline absoluto de 45 segundos.

O contrato direto não possui a negociação incremental v3 do Abacato. Não foram copiados endpoints,
bootstrap, long-poll ou trickle-ICE específicos daquele backend. Também não se presumiu suporte a
`response.cancel`/VAD da API pública: o microfone permanece ativo durante saída de áudio e o GPT
Live faz o barge-in. Transcrição de entrada suspende a narração local; a nova fala pode delegar
outro pedido sem esperar o trabalho anterior terminar.

Áudio: `playAndRecord`, `voiceChat`, 48 kHz preferidos, buffer de 10 ms, Bluetooth HFP/AirPods e
alto-falante padrão. Mudanças de rota revalidam ativação; iOS 27 usa `didBecomeInactiveNotification`
e `resumptionRecommendationNotification`. Sem recomendação de retomada, o controle **Retomar
áudio** é explícito. Media-services reset exige nova conexão. Quedas de rede seguem a seção abaixo.

## Moderação: limpar o contexto (01/11, rev. 02/11)

O GPT Live manda `error` com `type` ou `code` `content_filter` (o `VoiceProtocol.isModeration`, nunca pelo texto da
mensagem). Segundo o guia de conversas ao vivo da OpenAI, algumas moderações encerram a sessão e outras só cortam a
fala atual. Por isso o erro só marca uma **moderação pendente** (horário e código) e gera um diagnóstico
`tolerated` `moderation_pending`; a chamada e a memória seguem. Ela vira limpeza só se a sessão terminar em até 5 s
(`VoiceRecoveryPolicy.moderationWindow`): `session.closed` (qualquer motivo), canal fechado, transporte caído ou
qualquer outra perda dentro da janela. Também limpa um `session.closed` cujo `reason` cite conteúdo ou moderação
(`VoiceProtocol.closedByModeration`: a OpenAI documenta `content`; a rota só mostrou `client_request`). Se a janela
passa com a sessão viva, a chamada segue com a memória e um `tolerated` `moderation_nonfatal` registra o caso; uma
perda depois disso é uma perda comum, com reconstrução e memória. Uma resposta normal da assistente entre o erro e o
fim da sessão não conta para permitir outra limpeza. Na limpeza, o app:

1. descarta a chamada moderada (o link muda antes de tudo, então eventos, falas e áudio dela são ignorados), fecha o
   transporte e libera a lease; o que foi dito desde o último `turn.done` não vai para a memória;
2. limpa a memória de voz: no aparelho, `VoiceMemoryBuffer.reset` tira os turnos ainda não enviados e o contexto em
   cache e enfileira `custom.voice` → `reset` depois do que já foi enviado; enquanto ele não chega ao servidor, a
   memória do servidor não é lida de volta;
3. esquece os pedidos que a chamada reconstruída levaria (`VoiceContinuity`), os pedidos ainda não entregues à mestra
   e os resultados não ouvidos; atualizações da mestra sobre pedidos anteriores deixam de ser narradas até um pedido
   novo. O trabalho que a mestra já tem continua;
4. abre uma chamada nova com as mesmas instruções e janela vazia (sem resumo, turnos, pedidos ou resultados), sem
   criar sessão OpenCode.

Uma vez por reset toca um som curto do sistema (iPhone: som do sistema 1052 e vibração de aviso, silenciados pela
chave de silêncio e pelo volume; Mac: `NSSound` "Funk", no volume de alertas) e, durante a reconstrução, o tique de
espera de sempre. A faixa mostra "Limpou o contexto" com um ícone de atenção, em todas as fases e na falha, até a
chamada terminar; o VoiceOver lê o mesmo no rótulo da faixa. Se a chamada vazia for moderada antes de responder
normalmente, ou se a chamada não tinha memória, ela falha com uma mensagem clara: sem segundo reset nem laço. Depois
de uma resposta normal, uma nova moderação pode limpar de novo. Recomeçar sem histórico não garante que o serviço
aceite a próxima fala.

## Recuperação de rede

Uma conversa já conectada sobrevive a túnel, elevador, troca de antena, Wi-Fi→5G e falhas passageiras do
serviço. `VoiceController` separa a **conversa** (`sessionID`, mestra, fila de delegações, memória, mute,
Live Activity) do **link** (uma chamada GPT Live: transporte, `VoiceSignaling`, lease). Callbacks de um link
antigo são descartados pelo token do link. Limites em `VoiceRecoveryPolicy` (Kit); a margem da lease não é
configurável. Até 30/10, qualquer `error` do GPT Live, evento ilegível ou falha de envio encerrava a chamada
na hora (a queda de 31/10, 08:48); agora cada caso tem uma regra:

| Situação | O que acontece |
|---|---|
| `error` do GPT Live | Registrado (`tolerated`, `service_error` com `type/code`) e a chamada segue. A referência do Realtime da OpenAI diz "Most errors are recoverable and the session will stay open", e o `openai/codex`, que usa este mesmo protocolo (`frameless bidi`), nunca encerra por um `error`: só quando o transporte fecha. Exceção: `session_expired` (a sessão chegou à duração máxima) refaz a chamada na hora (`VoiceProtocol.endsSession`) |
| `error` de moderação (`content_filter`) | Moderação pendente (`tolerated`, `moderation_pending`); só limpa o contexto se a sessão terminar em até 5 s (seção anterior) |
| `session.closed` | Refaz a chamada, qualquer que seja o `reason` (expirado, desconhecido ou ausente), registrado como `code` de `session_closed`. Limpa o contexto se o `reason` citar moderação ou se vier logo depois de um erro de moderação. Durante o próprio encerramento, só conclui o fechamento |
| Evento ilegível (JSON inválido, sem `type`, campo obrigatório ausente, acima de 256 KB) | Ignorado e registrado (`invalid_event` com o tipo) |
| `delegation.created` com ID mas sem texto legível | A própria delegação recebe "Não consegui ler esse pedido…", para o GPT Live pedir de novo (como o Abacato) |
| Mais de 8 pedidos na fila | A delegação nova recebe uma recusa; a chamada e a fila seguem |
| Falha de envio no canal (`send`) | Refaz a chamada (`lose`); um resultado que não foi ouvido vai para a nova |
| ICE `disconnected` | 15 s para o WebRTC se recuperar sozinho; desconexões repetidas não renovam o prazo (como o Abacato). Se a rede volta ou muda de interface nesse meio, restam no máximo 3 s |
| ICE `failed`, canal fechado, media services reset | Refaz a chamada na hora |
| Renovação da lease: rede, 408, 429 ou qualquer 5xx | Tentada de novo a cada 1 s enquanto a lease confirmada (menos 10 s) cobre a chamada; um registro por sequência de falhas. Ao fim dela, refaz a chamada |
| Renovação recusada (outro 4xx: 404 lease ausente, 409 conflito, 410 expirada; lease malformada ou de outra chamada) | Encerra |
| Interrupção de áudio | Pausa com **Toque em retomar**, como antes |

- **WebRTC e a troca de rede:** o transporte liga o field trial `kRTCFieldTrialUseNWPathMonitor` do M147
  (o mesmo do Abacato), para o WebRTC acompanhar as interfaces e passar sozinho ao par de candidatos do
  celular quando o Wi-Fi cai. ICE restart de verdade não existe neste protocolo: a chamada nasce de um
  único `POST /calls`, sem renegociação, e o `gatherOnce` não pode virar contínuo depois (o
  `setConfiguration` do libwebrtc recusa). Sem recuperação dentro do prazo, a chamada é refeita.
- **Reconstrução:** pede `session.close` à sessão antiga sem esperar, fecha mídia e lease antiga (DELETE sem
  bloquear) e abre uma chamada nova, com novos UUIDs e a memória como `initial_items`; antes, grava como turno
  interrompido o que cada papel disse desde o próprio último `turn.done` e aguarda a gravação local. Mute, a voz
  aceita e o prompt da conversa continuam (a reconstrução não busca o prompt de novo nem depende do servidor
  do OpenCode). Por último nos `initial_items` vai um item de dados com os pedidos já entregues à mestra (ou
  na fila para ela) e ainda em andamento (`VoiceContinuity`, até 6).
- **Sem repetir pedidos:** a fila de delegações e a mestra pertencem à conversa, então o que já foi entregue
  continua lá. Se a chamada nova delegar de novo, com as mesmas palavras (ignorando maiúsculas, acentos e
  pontuação), um pedido que a anterior já entregou, ele não vai à mestra: a delegação nova ouve "Esse pedido
  já está com o agente…" e passa a receber o andamento e o resultado. A admissão na mestra também tolera a
  rede: cada passo (info, ensure, sessão, anexo, prompt) é repetido em erro passageiro por até cerca de
  15 s (1, 2, 4 e 8 s), e o prompt leva o mesmo ID nas tentativas; o servidor admite um ID uma vez só.
- **Resultado durante a queda:** os itens de delegação ficam na chamada antiga, então o progresso pendente
  é descartado, mas um resultado (ou falha) ainda não ouvido é guardado: o que ainda esperava na caixa e, desde a
  quarta onda (02/11), o que já saiu mas não teve todas as partes confirmadas pelo GPT Live
  (`delegation.context.appended`/`session.context.appended`, que dizem que o contexto chegou ao modelo, não que foi
  falado, em 0,12–0,25 s). Um resultado todo confirmado não é reenviado. Na chamada nova, ele vai para a
  próxima delegação; se nenhuma vier, vai logo como contexto da chamada (`session.context.append`, que o
  serviço aceita com texto, conferido em 29/10; sem canal ele é `speakable`, e em 02/11 um fato assim foi falado em
  menos de um segundo). Um `error` cujo `error.event_id` é de uma parte desse append devolve o texto para a próxima
  delegação; um erro sem um ID nosso não conta (até a quarta onda, contava qualquer `error` nos 3 s seguintes).
- **Limites:** janela de **2 minutos** desde a primeira perda, até **6 tentativas** com espera de 1, 2, 4,
  8, 15 e 15 s, cada uma com **20 s** para ficar pronta. Sem rede, nenhuma tentativa é gasta: o estado é
  **Sem conexão** e a rede é conferida a cada 250 ms até voltar ou a janela acabar. Esgotado, a faixa
  mostra a falha e um alerta **Voz sem conexão** oferece **Tentar de novo** ou **Encerrar**. Até lá, faixa e
  Live Activity mostram **Reconectando…** ou **Sem conexão**, nunca a falha.
- **Diagnóstico:** cada falha tolerada e cada reconexão vão ao servidor (`Voice diagnostics`, seção
  "Motivo da queda"): `tolerated` com `service_error`, `invalid_event`, `ice_disconnected`,
  `ice_recovered`, `network_changed`, `lease_retry`, `reconnect_failed`, `delegation_overflow`,
  `delegation_repeat`, `context_append` (quando o GPT Live confirmou todas as partes), `call_mismatch`
  (`session.started` com outro ID que o do `Location`, que vai como `code`), `moderation_pending`,
  `moderation_nonfatal` e `reconnected` (`code=attempts_N`); `lost` em cada perda (`session_closed` leva o `reason` do
  serviço como `code` e `audio_duration_ms=…` como `detail`).
- **Falhas antes da primeira conexão** continuam encerrando com erro, sem retry (deadline de 45 s).
- **Feedback:** faixa e Live Activity mostram **Reconectando…** ou **Sem conexão**. `VoiceCuePlayer`
  toca dois tons descendentes na perda, um tique suave a cada 3 s durante a recuperação, dois tons
  ascendentes ao voltar e dois graves ao desistir. As vibrações vêm de `VoiceFeedback` (abaixo):
  `warning` na perda e `success` na volta; ao desistir só o `fail()` vibra, uma vez. O tique é áudio real que segura um crédito do `RTCAudioSession` enquanto não há
  WebRTC, para o modo de áudio em background continuar legítimo e o app não ser suspenso no bolso;
  termina na reconexão, na desistência ou no encerramento.
- **Estados para superfícies compactas:** `VoiceIndicator` (Kit) resume `VoiceState` em conectando,
  ouvindo, falando, mestra trabalhando, interrompido, reconectando, sem conexão e falha, com título,
  título curto, SF Symbol e animação. A Live Activity já usa o símbolo; a futura cena CarPlay mapeia
  esses casos para `CPVoiceControlState`.

## Memória da conversa (KV, sem Session de voz)

`VoiceMemoryService` reconhece apenas `custom.voice` versão 2, `storage=kv` e
`contextFormat=initial_items`. Sem essas capacidades, em falha de rede ou durante
ativação do plugin, a chamada segue sem memória inicial. Os pedidos de info/context
têm deadline de dois segundos por RPC (não somente timeout ocioso); não mudam
lease, áudio ou delegação da mestra.

Cada `turn.done` preserva o texto canônico completo (não a soma de deltas), role,
timestamp, IDs nativos do turno/item e interrupção. Barge-in também marca a resposta
interrompida, pois seu final pode não ter sido ouvido. Os IDs enviados ao servidor
são qualificados pelo UUID da chamada. Deltas servem à apresentação e a uma exceção (02/11): nada chega
depois de `session.close` e o `turn.done` do usuário só vem quando a assistente começa o turno seguinte, então,
ao encerrar ou perder a chamada, o texto acumulado de `input_transcript.added`/`output_transcript.added` desde o
último `turn.done` de cada papel vira um turno interrompido (`<chamada>:<link>:partial-assistant`/`-user`, a
assistente primeiro). O `turn.done` de um papel zera o acumulado dele, então nada se duplica; numa limpeza por
moderação, o acumulado é descartado.

Antes de qualquer append HTTP, `VoiceMemoryBuffer` grava um arquivo JSON atômico
por servidor em Application Support, com proteção até a primeira autenticação no
iOS. O arquivo não contém senha. Mantém operações ordenadas, IDs já vistos, um
cache de leitura e marcadores de fim. Só remove operações depois de confirmação;
um crash entre aceitação remota e confirmação local repete os mesmos IDs.
Buffer inválido não é sobrescrito silenciosamente. Erro de gravação aparece no leitor.

O `SessionStore` retoma pendências no próximo lançamento/conexão; capturas e fim
também iniciam sincronização. Falhas transitórias usam retry limitado a 3–30 s;
servidor sem suporte só é sondado novamente ao preparar uma chamada/leitura. A fila
envia lotes de turnos antes de seu marcador `end`, sem reordená-los. Encerrar fecha
a sessão (`session.close`, até 2 s), grava a fala parcial, fecha a mídia e libera a lease, aguarda as
gravações locais e enfileira o check de compactação. Não fica com áudio aberto esperando o servidor de
memória. Não se promete execução após force-quit; o arquivo fica para o próximo lançamento.

No início, contexto do servidor e pendências locais viram `session.initial_items`:
user/`input_text`, assistant/`output_text`, resumo anterior como item `developer`/`input_text` claramente
rotulado como dado (conforme o contrato), e, só enquanto a mestra trabalha, o estado dela como
outro item `developer` (o servidor omite a mestra parada desde 30/10: a última resposta dela era de
outra conversa, e uma chamada nova começou repetindo-a). Os pedidos que uma chamada reconstruída leva
(`VoiceContinuity`) também vão como `developer`. A sondagem de 02/11 confirmou que a rota aceita e usa itens
`developer`; o formato da memória no servidor não muda (os turnos continuam `user`/`assistant`).
O cliente reaplica o teto de **128 itens / 8.192 tokens estimados**, incluindo labels
e interrupções, usando `ceil(bytes UTF-8 / 3) + 8` por item. Não envia transcrição nas
instructions, não usa `session.input` e não envia falas recentes à Sessão mestra.

**Ver transcrição**, na faixa expandida e nas ações do VoiceOver, abre um leitor
somente leitura com resumo, ambas as roles, interrupções e aviso de contexto
limitado. Ele observa o mesmo buffer: falas locais finalizadas aparecem durante a
chamada, mesmo offline, sem polling de UI nem outra subscrição SSE. Dismiss não
encerra a chamada. Não há composer, Session de voz, filtro de listas ou botão de
apagar. A memória do servidor é rolante: resumo e turnos recentes, não arquivo
verbatim ilimitado. O contrato está em `packages/plugin-app-custom/docs/voice-session.md`.

Uma resposta da mestra que chega depois do fim da chamada (ou da queda) entra na memória pelo servidor, no
`end` da chamada, como dado rotulado com o pedido e a resposta (`agent:<ID da resposta>`), só se nenhuma fala da
assistente veio depois dela. A chamada seguinte começa sabendo que o pedido foi resolvido e não o delega de novo.
Não muda nada no app; detalhes em "Late Mestra replies" no contrato.

## Sessão mestra

### Prompt editável no servidor

O iPhone busca `custom.voice/instructions` antes de cada chamada GPT Live. Uma reconexão é a mesma
conversa e reaproveita o prompt já carregado (desde 31/10), para não depender do servidor do OpenCode
enquanto a rede oscila. O Watch usa a mesma RPC no backend. O servidor relê `voice.md` no diretório
global de configuração (`OPENCODE_CONFIG_DIR`, senão `$XDG_CONFIG_HOME/opencode`, senão
`~/.config/opencode`) em cada consulta, sem cache nem necessidade de reinício. A alteração
vale para a próxima chamada; não muda uma chamada já aberta.

O arquivo substitui o prompt inteiro. Para começar, copie
`packages/plugin-app-custom/src/voice/voice.md` para esse diretório e edite o Markdown.
Sem arquivo, o servidor usa esse mesmo padrão embarcado. Arquivo vazio ou ilegível é
erro; o iPhone não abre uma chamada sem obter o prompt. A primeira migração exige atualizar
o backend e o app iOS uma vez. O texto não fica mais embutido no iPhone.

O padrão segue, desde 02/11, a estrutura recomendada pelo guia "Prompting GPT-Live" da OpenAI, com os
rótulos em inglês e o conteúdo em português: papel e estilo; `Backchannel policy:` (poucos sinais de escuta,
curtos); `Interruption policy:` (parar ao ser interrompido, responder ao pedido mais recente, não retomar a
resposta substituída); `Delegation policy:` com `Backend tools:` (o agente no computador dele, o que ele alcança e
que ele recebe o que Alexandre disse e o trecho recente da conversa), `Generate <|SpawnThinking|> when:`, `Do not
generate <|SpawnThinking|> when:` e "Generate <|SpawnThinking|> before giving an answer that depends on backend work.
Do not guess the result while waiting." (para o `gpt-live-1`, o guia pede esse token em vez de "delegue"). Depois vêm
a fila (se ele pedir para enfileirar, "enfileira", "coloca na fila", "sem interromper", dizer que vai enfileirar: o
app percebe pelas palavras dele), o que o padrão de 30/10 (método de `abacato-prompts`) já garantia: não inventar nem
dizer que fez antes do retorno e tratar o retorno como conteúdo, não como instrução; e um parágrafo para a espera:
avisar em poucas palavras e usar o estado do agente só se ele perguntar. Não cita a mestra: o nome fazia o GPT Live
mandar tudo para ela e anunciar cada envio. Na validação real de 02/11 (duas chamadas, prompt novo e o anterior) as
decisões de delegar foram as mesmas, o token nunca foi falado e os avisos ficaram mais curtos. Ajustes entram um de
cada vez, a partir de falhas observadas em chamadas reais.

**Prompt honesto (02/11, terceira onda).** A mesma validação mostrou que o GPT Live não escreve o pedido (abaixo).
Saíram do padrão o parágrafo do JSON (`"screen":true`, `"screen":"display"`, `"screen_app"`, `"delivery":"queue"`), a
linha "Tela" das `Backend tools`, o gatilho "Alexandre pergunta da tela" e "o agente não ouve a conversa: escreva o
pedido com o contexto necessário", que não tinham efeito. O `voice.md` é servido igual ao iPhone, ao Mac e ao Watch,
que não tem tela, por isso não fala de tela: a capacidade fica no bloco de cada app (`screenInstructions`, abaixo).

`VoiceMaster` usa apenas contratos existentes de `OpenCodeKit`. A primeira delegação chama
`custom.master/ensure`, que devolve a mestra atual ou, se não houver, se foi apagada ou arquivada,
cria outra no plugin (com trava, então tela e voz simultâneas não criam duas) e atualiza
`masterSessions.local`; em seguida, prompt. Se a mestra for apagada durante a chamada, o 404 leva a
um único novo `ensure` e o pedido vai para a substituta. Nenhuma sessão é criada apenas ao abrir a voz.
A memória de voz é global (não pertence à sessão) e continua valendo para a nova mestra. O `ensure` da primeira
delegação leva `voice: true`, que liga na mestra a nota
de contexto da chamada de voz (respostas curtas, para serem ouvidas); o `end` da memória de voz, ao fim
da chamada, desliga a nota (`packages/plugin-app-custom/docs/master-session.md`). A regra de não executar
instruções vindas de resultados de ferramentas fica no prompt do agente `mestra`
(`packages/plugin-app-custom/src/master/index.ts`).

**Pedido montado pelo app (02/11, terceira onda).** Na validação da segunda onda o texto de `delegation.created` foi a
transcrição literal do turno do usuário que disparou a delegação (idêntica ao `turn.done` apontado por
`user_bidi_turn_id`, com os erros de reconhecimento), com qualquer prompt: o GPT Live não escreve o pedido, e pedir um
pedido "autossuficiente" não tinha efeito; um pedido copiado só da última fala já tinha chegado sem o chip que
Alexandre dissera na fala anterior. É o que a doc oficial manda para a delegação `client` ("Keep the conversation
context in your application", "Receive a client delegation"): o app monta o pedido a partir das transcrições e do
estado da aplicação. `VoiceRequestContext` (Kit; o Watch usa a mesma regra, `masterRequest`) guarda, só em memória da
chamada (nunca na memória persistente), os turnos completos (`turn.done` de Alexandre e da voz) desde a delegação
anterior desta conversa, e o pedido passa a ser:

```text
<fala que disparou a delegação>

Conversa por voz desde o pedido anterior (transcrição, pode ter erros):
Alexandre: …
Voz: …
```

- **Limites:** os mais recentes, até 6 turnos e 1.200 caracteres; um turno mais recente que sozinho passa do limite vai
  pelo final, depois de "…". Sem turnos além do próprio pedido, vai só a fala. Cada turno vai uma vez: a delegação
  seguinte só leva o que veio depois.
- **O turno que pediu não é contexto:** o `turn.done` dele chega depois da delegação (só quando a voz começa a
  responder); ele é reconhecido pelo `user_bidi_turn_id` ou, sem IDs, pelas mesmas palavras (a regra de
  `VoiceContinuity`), e fica de fora deste pedido e do próximo.
- **Delegação sem texto não se perde:** se `delegation.created` vier sem texto legível, a fala é a transcrição pendente
  dele (`partial[.user]`, o que ele disse desde o último `turn.done`) ou, sem ela, o último turno completo dele. Só sem
  nada disso o GPT Live ouve "Não consegui ler esse pedido. Peça para Alexandre repetir." (o Watch também, desde esta
  onda; antes ignorava a delegação em silêncio).
- **Continuidade:** `VoiceContinuity` (a repetição de um pedido depois da reconstrução e a lista que a chamada nova
  recebe) compara e carrega só a fala, nunca o pedido composto.
- **Moderação:** a limpeza do contexto também descarta os turnos que o próximo pedido levaria.
- A nota de voz da mestra diz que a conversa depois do pedido é contexto para entendê-lo, não um pedido novo.

O retorno do prompt é **admissão**, não conclusão. A subscrição ao `EventHub` começa antes do envio;
ferramentas alimentam o indicador visual, sem gerar falas automáticas. Isso inclui os `toolCalls`
estruturados de progresso do Code Mode; sessões conhecidas são identificadas pelo título.
A confirmação de envio ("Pedido enviado à Sessão mestra."), as ferramentas e as falhas de ferramenta ou etapa,
de que a mestra se recupera sozinha, não são faladas: o GPT Live já reconhece o pedido ao delegar e, com a
confirmação, dizia "já encaminhei" a cada pedido. Desde 02/11 elas chegam ao GPT Live como **estado quieto**
(`VoiceMasterUpdate.activity`), o equivalente do `session.thinking.append` oficial: `delegation.context.append` com
`channel=commentary` na delegação atual do link atual (sem delegação atual, nada vai), redigido como fato e não
como novidade (`VoiceMasterProgress.note`: "Estado do agente (para consulta; não é novidade para anunciar):
consultando os arquivos. Pedido em andamento, ainda sem resultado."), porque na sondagem de 02/11 fatos neutros
ficaram quietos em `commentary` e frases de "terminou/atualização" foram faladas. O GPT Live o usa se Alexandre
perguntar. Vão para ser falados só os textos da mestra (`Atualização: …`), pedidos de resposta, falhas da execução e
o resultado (`Resultado: …`).
Raciocínio, argumentos de ferramentas,
tokens e credenciais não são narrados. Reconexão/lacuna do stream revalida transcript, atividade e
inbox em `session.execution.succeeded`; falha/interrupção usam os eventos terminais próprios.
O resultado só é final quando não há execução nem mensagens pendentes. A recuperação encontra o
ID durável do prompt (até 200 mensagens), sem comparar relógios do iPhone e do servidor. Não há um segundo
stream SSE em paralelo ao da aplicação.

`VoiceNarration` é uma caixa de último progresso, não uma fila de falas antigas: agrupa/coalesce,
limita atualizações a uma a cada cinco segundos e cede ao usuário e à fala em andamento. O resultado
tem prioridade sobre progresso pendente. O estado quieto tem a sua própria caixa, `VoiceMasterStatus`: só o último
estado, só quando muda (voltar ao último enviado descarta o que esperava), no máximo um a cada 10 s
(`VoiceMasterStatus.interval`), nunca enquanto Alexandre fala, enquanto o GPT Live fala ou tem fala esperando, nem
nos 3 s depois de um append falado (`afterSpeech`, para não ser dito junto). Uma delegação nova, o resultado, uma
falha e a reconstrução da chamada zeram a caixa.

**Resultado para a fala (02/11).** O guia de delegação da OpenAI pede que o GPT Live receba os fatos e o status, com
texto longo e Markdown de exibição no backend. `VoiceResult.spoken` (Kit; o Watch usa a mesma regra) tira o Markdown
que não deve ser lido (título, marcador de lista e de tarefa, `**`/`__`, crases, citação, régua; link vira o texto;
tabela vira linhas "a, b"; bloco de código cercado vira "(há código na resposta; veja na conversa)", uma vez por
sequência) e limita o texto a 1.500 caracteres, cortando no último fim de frase ou de linha da segunda metade (senão
no último espaço), seguido de "O restante da resposta está na conversa.". Fica o **trecho inicial**: a nota de voz
pede à mestra que comece pelo resultado, o status e o próximo passo; até 01/11 iam até 5.000 caracteres do trecho
final, em até dez appends.
Pedidos seguintes são admitidos serialmente, mas não aguardam conclusão do modelo. O pedido usa `steer`, salvo
quando Alexandre pede para enfileirar: desde 02/11 (terceira onda) quem decide é o app, pelas palavras dele desde a
delegação anterior (`VoiceQueueIntent`, Kit; o Watch usa a mesma regra, `queues`), numa rede estreita, sem importar
caixa nem acento: "enfileira"/"enfileirar"/"enfileire", "coloca … na fila"/"põe … na fila" (até duas palavras entre o
verbo e "na fila") e "sem interromper" dão `queue`. O JSON `{"text":"…","delivery":"queue"}` que o prompt descrevia
nunca chegou nesta rota; continua aceito se um dia vier. ID repetido da mesma delegação não é reenviado.

### Tela para a mestra ("dá uma olhada nessa tela")

O GPT Live privado (`architecture=avas`, delegação `client`) não aceita ferramentas próprias nem
imagem: a sessão só tem a delegação embutida e o canal só transporta `input_text`
(`delegation.created`, `delegation.context.append`, `initial_items`); `conversation.item.create`
e `tools` existem apenas nos protocolos Realtime v1/v2, que esta chamada não usa (conferido em
`openai/codex`, `codex-api/src/endpoint/realtime_websocket`). Por isso a tela vai **com o pedido à
mestra**, e **o GPT Live não recebe a imagem**; só a mestra a vê. Até 02/11 o prompt pedia um parâmetro da
delegação, no mesmo JSON de `delivery` (`{"text":"pedido","screen":true}`); nesta rota ele nunca chega (abaixo), e
desde a terceira onda quem decide é o app, pelas palavras de Alexandre. O probe opt-in `testExplicitSilentLiveImageInput`
(`TEST_RUNNER_OPENCODE_TEST_LIVE_VOICE_IMAGE=1`, simulador, uma chamada muda) confirmou em 29/10/2026:
`conversation.item.create` é rejeitado (`invalid_value`, eventos aceitos: `session.update`,
`session.context.append`, `response.item.create`, `response.create`, `delegation.context.append`,
`delegation.function_call_output.create` e outros de áudio/sessão) e `session.context.append` com
`input_image` falha com `missing_required_parameter: content[0].text`.

- **Decisão do app (02/11, terceira onda):** a captura vai quando a fala de Alexandre desde a delegação anterior (até
  45 s, pelos trechos de transcrição de entrada) ou o texto delegado nomeia a tela ou um print
  (`VoiceScreenIntent.target`: tela, print, screenshot, captura de tela). O alvo é `front`; no Mac, "tela toda" ou
  "tela inteira" dão `display`. App pelo nome ("olha o simulador") **não é suportado**: nenhuma frase o nomeia com
  segurança, e a rota não envia `screen_app`. O iPhone sempre captura só o OpenCode, qualquer que seja o alvo.
- **JSON antigo:** `"screen": true | "front" | "app" | "display"` e `"screen_app": "Simulator"`
  (`VoiceScreenTarget`) continuam aceitos se um dia vierem: `true` equivale a `"front"`; um `screen_app` não vazio
  implica `"app"`; `false` desliga; um `screen` explícito vence a inferência.
- **Descrição fixa:** a delegação embutida não tem descrição editável. Cada app põe a sua
  (`VoiceProtocol.screenInstructions(.iPhone | .mac)`, via `withScreen(_:for:)`) antes do prompt devolvido pelo
  servidor, que desde a terceira onda não fala de tela (é o mesmo do Watch). O bloco diz o que a rota faz, sem JSON:
  quando Alexandre falar da tela ou de um print, gerar `<|SpawnThinking|>`; o app anexa a captura quando a fala dele
  cita a tela ou um print; quando ele aponta para algo sem citar a tela ou um print ("olha isso aqui"), a captura não
  vai, e se o retorno do agente mostrar que ele não viu nada, dizer em poucas palavras que, para ver, ele pode pedir
  "olha minha tela"; não descrever nem adivinhar; nunca dizer que não vê sem antes delegar. O do Mac cita "a tela
  toda" para a tela inteira e não cita app pelo nome. Sem "acima de qualquer outra instrução" e sem a mestra: em
  30/10, com essas palavras na frente do prompt, o GPT Live passou a abrir a conversa falando da tela. Um `voice.md`
  editado a partir do padrão até 02/11, que descreve o JSON (`"screen":true` no iPhone, `"screen_app"` no Mac), é
  usado como está, sem um segundo bloco que o contradiga; um prompt que já contenha o bloco também.
- **O texto da delegação é a transcrição (02/11):** nas duas chamadas da validação da Onda 2, com o prompt novo e com
  o anterior, o texto de `delegation.created` foi idêntico ao `turn.done` do usuário apontado por `user_bidi_turn_id`
  ("Olha a minha tela, o que tem aí"), sem JSON. Nesta rota o modelo não escreve o pedido; o `screen` explícito não
  veio, e quem anexou a captura seria a inferência ("tela"). A doc oficial da delegação `client` diz o mesmo: o evento
  traz metadados, e o app monta o pedido a partir das transcrições.
- **Captura:** `VoiceScreenCapture` começa no próprio evento da delegação (`Task.immediate`), antes de
  esperar pedidos anteriores. Exige o app ativo na frente e dados protegidos disponíveis (iPhone
  desbloqueado); renderiza só a janela principal do OpenCode (`drawHierarchy`), a no máximo 2×, JPEG
  0,72. Nada de ReplayKit, tela inteira ou galeria. Durante ~80 ms a faixa de voz e os toasts ficam
  com opacidade 0 (`voiceCaptureHidden`), sem mudar o layout; status bar, Live Activity e banners
  do sistema não fazem parte da janela.
- **Envio:** mesmo formato do composer: `deliver` grava `tela-opencode.jpg` em `uploads/` do servidor e,
  se o modelo da mestra lê imagem, o prompt leva o `data:image/jpeg` inline. O texto é o pedido mais
  uma linha mínima com o que a imagem não mostra:
  `[Captura da tela do app OpenCode anexada. Sessão aberta no app: ses_…]` (sem sessão aberta, só a
  primeira parte). Não há descrição da tela.
- **Recusa:** com outro app na frente, a chamada em segundo plano ou o iPhone bloqueado, nada é
  capturado nem enviado à mestra. O motivo vai ao GPT Live por `delegation.context.append` (por
  exemplo “Não consigo ver a tela: o OpenCode não está aberto na frente. Só vejo a tela do próprio
  OpenCode, nunca a de outros apps. Nada foi enviado à Sessão mestra.”) e aparece num toast do app.

#### Quando o GPT Live não marca `screen` (29/10)

Nos testes de 29/10 o GPT Live respondeu "não tô vendo" a "Você está vendo a minha tela aí?" sem delegar e,
depois, delegou "Não, vai lá na Mestra que você consegue" como texto simples. Duas defesas:

- **Instruções na frente:** o bloco fixo de cada app agora vem **antes** do prompt do servidor (que é editável
  e longo), afirma que ele consegue ver a tela, lista perguntas ("tá vendo minha tela?", "consegue ver isso?",
  "o que você acha disso aqui?"…), manda usar `screen` na dúvida e proíbe dizer que não vê sem delegar.
- **Rede de segurança no app:** uma delegação sem `screen` ganha a captura (alvo `front`) quando o texto
  delegado ou o que Alexandre falou desde a delegação anterior (até 45 s, pelos trechos de transcrição de
  entrada) fala da tela (`VoiceScreenIntent`: tela, print, captura, janela, página, "isso aqui", "olha
  aqui", "vê isso", "o que acha disso", "que erro é esse"…). Se essa captura inferida falhar, o texto vai
  como foi delegado, sem aviso; só o `screen` explícito continua bloqueando o envio. Até 30/10 ia com
  `[O app tentou anexar a tela, mas não conseguiu: motivo]`, mas a inferência erra: "ó isso aqui é uma
  anomalia", sobre memória do Mac, com o iPhone bloqueado, fez a mestra responder sobre a captura.
- **Só quando ele nomeia a tela (31/10):** a rede passou a reconhecer só menções à própria tela (tela, print,
  screenshot, captura de tela). Expressões que apontam sem nomear ("isso aqui", "olha aqui", "vê o que cê
  acha", "o que acha disso", "janela", "página", "que erro é esse") saíram: são fala comum, e "dá uma
  pesquisada na web… vê o que cê acha" tentou capturar a tela com o iPhone bloqueado. É a escada da skill
  `abacato-prompts` (abacato-v2): regra presa a frases é enxugar gelo. Até 02/11 decidir olhar era do GPT Live, pelo
  campo estrutural `screen`; como esse campo nunca chega nesta rota, desde a terceira onda a rede estreita é a
  decisão, e ela não se amplia (nem pela fala da voz). Para quem aponta sem nomear a tela, a primeira versão do bloco
  mandava o GPT Live perguntar se ele queria que olhasse a tela; na validação real de 02/11
  (`gpt-live-probe/VALIDATION-onda3.md`) ele **não perguntou**: delegou "Olha isso aqui" e "O que você acha disso"
  nas três tentativas, com essa linha e com uma variante mais forte ("não gere <|SpawnThinking|> ainda"), logo
  depois de um resultado de tela e no começo da chamada. Por isso o bloco descreve o que acontece em vez de pedir o
  que o modelo não faz: a captura não vai, e se o retorno do agente mostrar que ele não viu nada, a voz diz em poucas
  palavras que, para ver, ele pode pedir "olha minha tela". O pedido vai sem captura, com a conversa recente no
  contexto, e a mestra, sem imagem, diz que a captura não veio. Uma falha nisso se corrige nessa linha geral do
  bloco, não com mais frases aqui.
- **iPhone bloqueado:** nada é capturado nem tentado. Com `screen` explícito, o GPT Live ouve
  `VoiceScreenRefusal.locked` (desbloquear e abrir o OpenCode) e nada vai à mestra; a inferência pelas falas
  nem é avaliada, e o pedido segue como foi delegado.
- **Mestra:** o prompt dela manda usar a imagem para responder ao pedido, ignorá-la quando o pedido não
  for sobre ela e nunca dizer que não vê telas; se ele pediu para ver e a imagem não veio, diz que a
  captura não veio e pede "olha a tela".
- Alternativa avaliada e não feita: uma ferramenta da mestra que pede a captura ao aparelho da ligação
  pelo canal de dados do iPhone/Mac. Resolveria também pedidos sem nenhuma palavra de tela, mas exige
  RPC nova no plugin, fonte nova nos dois apps, tempo limite e app em primeiro plano; a heurística cobre
  os dois casos relatados só no app.

#### No Mac (outros apps também)

`MacVoiceScreen` decide com `VoiceScreenPlanner` (Kit, puro e testado) a partir do app da frente
(`NSWorkspace`), das janelas na tela (`CGWindowListCopyWindowInfo`, da frente para trás) e dos monitores:

- **`front`** (padrão): a janela comum (camada 0) da frente do app em primeiro plano. O OpenCode só
  entra quando **ele** é o app da frente; aí é a sua janela da frente (`MacRuntime.front`). Faixa de voz,
  sino, paleta e outros painéis do OpenCode nunca cobrem o app que Alexandre está olhando.
- **`app`** + `screen_app`: a janela da frente do app pelo nome, sem diferenciar caixa e acentos, exato,
  depois prefixo, depois contido ("chrome" → Google Chrome). "OpenCode" é a própria janela. Só pelo JSON antigo,
  que esta rota não envia: por voz, app pelo nome não é suportado (o bloco do Mac não o cita).
- **`display`**: o monitor da janela da frente (senão o principal), sem as janelas do OpenCode, a menos
  que ele esteja na frente. Por voz, quando ele diz "a tela toda" ou "a tela inteira".
- **Permissão:** a janela do próprio OpenCode sai do window server (`CGWindowListCreateImage`, lido em
  tempo de execução) e não precisa de permissão. Outros apps usam ScreenCaptureKit
  (`SCShareableContent` + `SCScreenshotManager`, um quadro, sem stream) e precisam de **Gravação de
  Tela**. Sem ela (`CGPreflightScreenCaptureAccess`, que não pergunta nada), a mestra recebe só a janela
  do OpenCode e o GPT Live ouve um aviso, também num toast com **Abrir Ajustes**. Na primeira vez o app
  chama `CGRequestScreenCaptureAccess` (pedido do macOS) e grava `OpenCodeVoiceScreenPermissionAsked`;
  depois não pede de novo. Ajustes da voz no Mac tem o atalho **Abrir permissão de Gravação de Tela**.
  O macOS exige reabrir o app depois de liberar e, desde o Sequoia, pede de tempos em tempos para
  "continuar permitindo" apps que capturam a tela; isso é do sistema e não se evita com ScreenCaptureKit.
  `SCContentSharingPicker` dispensaria a permissão, mas obriga escolher a janela à mão a cada captura,
  o que não serve a um pedido falado.
- **Assinatura:** o TCC guarda a permissão pela regra de assinatura designada do app instalado
  (`identifier "br.com.alexandrem.opencode.mac" and anchor apple generic and certificate leaf[subject.CN]
  = "Apple Development: …"`), não pelo hash do binário. Builds novos assinados pelo mesmo certificado de
  desenvolvimento do time mantêm a permissão; um build ad-hoc ou outro certificado pediria de novo.
- **Faixa de voz:** como no iPhone, a faixa e os toasts do OpenCode ficam invisíveis (~80 ms) no quadro
  capturado; o layout não muda.
- **Linha para a mestra:** só identificadores: `[Captura da janela de Google Chrome (“Título”) anexada.]`,
  `[Captura da janela do OpenCode anexada. Sessão aberta no app: ses_…]` ou
  `[Captura da tela inteira do Mac (Simulator na frente) anexada.]`. JPEG 0,72 com no máximo 2000 px no lado maior, o limite de imagem do servidor
  (acima dele o servidor reduz e regrava como PNG, maior).
- **Falhas** (nada é enviado; o GPT Live repete o motivo): app pedido não está aberto, app sem janela
  visível, nenhuma janela na frente, janela que o sistema não compartilha (ausente do conteúdo
  compartilhável ou erro do ScreenCaptureKit), sem permissão e sem janela do OpenCode para mandar.
- **Verificação:** `script/test-mac-voice-screen.py` roda uma cópia Debug (bundle próprio, assinatura
  ad-hoc, `open -g`, sem ativar o app) contra um sandbox isolado, com `-OpenCodeMacVoiceScreenCheck
  own|first|denied|granted|display|missing` (os cenários de JSON) e as frases em texto simples, como a rota delega
  (`question`, `follow` e, desde a terceira onda, `whole`: "Olha minha tela toda" captura a tela inteira): um sistema
  falso faz o papel do app da frente, da lista de
  janelas e da permissão (nada pede permissão ao macOS nem lê as janelas de Alexandre); a janela do
  OpenCode é capturada de verdade, fora da tela. A mestra real do sandbox recebe o prompt e é
  interrompida assim que ele chega.

## Background e Live Activity

`UIBackgroundModes=audio` preserva a mídia autorizada quando o usuário bloqueia o telefone ou troca
de aplicativo. O `EventHub` permanece ativo durante a chamada para acompanhar a mestra. Não há
background task fictícia nem loop de áudio silencioso; durante uma recuperação de rede o tique
audível descrito acima substitui o WebRTC por no máximo 2 minutos. O sistema ainda pode suspender/encerrar o
app; isso não garante execução depois de force-quit.

O target `VoiceActivity` (`br.com.alexandrem.opencode.VoiceActivity`, time `ERRYZ68LX5`) é embarcado
no app. `VoiceShared` contém atributos e `LiveActivityIntent`s. A Live Activity e Dynamic Island
exibem ouvindo/falando/trabalho da mestra, reconectando e sem conexão (rótulo e ícone de
`VoiceIndicator`); mute/end são validados pelo UUID da chamada no processo
do app. Tema é um snapshot de roles tipados. O driver mantém instâncias ActivityKit fora da MainActor
durante chamadas assíncronas e limpa apenas atividades desse tipo deixadas por uma execução anterior.
Live Activity negada pelo sistema não derruba áudio. Ela não contém transcrição pessoal.

**Prioridade entre atividades:** voz usa `relevanceScore = 100` em todo início/atualização,
inclusive mute, interrupção e recuperação de rede; agentes usa `50`, tanto no app quanto no
`aps.relevance-score` dos pushes start/update/end do plugin. A Apple usa a maior relevância para
a Dynamic Island e o topo da tela bloqueada; em empate, vence a primeira atividade iniciada.
Ao encerrar voz, agentes volta naturalmente, com o mesmo ID, progresso e token. Não é preciso
encerrar/recriar agentes, nem gerar outro alerta de início. Fontes: [ActivityContent.relevanceScore](https://developer.apple.com/documentation/activitykit/activitycontent/relevancescore)
e [pushes ActivityKit](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).
O Smart Stack recebe as atividades espelhadas; a ordenação final no Watch depende do watchOS
e das preferências do usuário (a documentação de relevância garante explicitamente iPhone,
não prioridade absoluta no Watch). O card suplementar, o widget e o app Watch são preservados.

Teste isolado: `-OpenCodeAgentsActivityFixture state-working -OpenCodeActivityPriorityFixture`
com URL de sandbox explícita usa os drivers reais e transporte fechado, sem áudio/APNs/rede.
`ActivityPriorityTests` captura a ilha/tela bloqueada e lê a relevância efetiva do ActivityKit,
incluindo atualização de agentes, recuperação de voz e encerramento com o mesmo ID de agentes.

## Início pelo Botão de Ação, Controles e Atalhos

`StartVoiceIntent` (`VoiceShared`) inicia a mesma chamada do botão de onda sem trazer o app para a
frente: aparece só a Live Activity existente, com tempo, estado, silenciar e encerrar. Ele é exposto
como Control `VoiceStartControl` (extensão `VoiceActivity`: Botão de Ação, Central de Controle e Tela
Bloqueada) e como App Shortcut **Falar com a mestra** (`OpenCodeShortcuts`: Atalhos, Spotlight, Siri
e Botão de Ação → Atalho). Configurar o Botão de Ação: **Ajustes → Botão de Ação → Controles →
Falar com a mestra**.

- **Conformidades:** `AudioRecordingIntent` + `LiveActivityIntent`, `supportedModes =
  [.background, .foreground(.dynamic)]` e `allowedExecutionTargets = .main`: o intent roda sempre no
  processo do app (nunca na extensão), que pode iniciar Live Activity e microfone. "Target is not
  foreground" aparece quando a atividade é pedida fora desse contexto; aqui `Activity.request` acontece
  de forma síncrona dentro do `perform()`, antes de qualquer ativação de áudio (`VoiceController.start`
  publica antes de a conexão pedir permissão e montar o WebRTC).
- **Desbloqueio:** `authenticationPolicy = .requiresAuthentication`. Com o iPhone bloqueado o sistema
  pede Face ID/código antes de rodar; cancelado, nada acontece. Uma chamada já ativa continua com o
  telefone bloqueado (silenciar/encerrar pela Live Activity), como antes.
- **Estado do app:** `AppRuntime.shared` guarda servidores, `SessionStore` e `VoiceController` fora da
  cena. `AppVoiceLauncher` (registrado em `OpenCodeApp.init`) constrói o store com `prepare()` — o mesmo
  que a cena usa, sem trocar um store já válido nem derrubar a chamada — e, sem cena, mantém o
  `SessionStore.run()` (eventos da mestra) até a chamada acabar. O `perform()` aguarda até 30 s pela
  chamada ficar pronta ou falhar, para o processo não ser suspenso antes do áudio.
- **Decisão (`VoiceLaunch.plan`, Kit):** chamada já ativa, conectando ou encerrando → só vibra
  (`warning`), sem segunda chamada; falha anterior → nova chamada. O app vem para a frente
  (`continueInForeground`, sem confirmação) quando o microfone ainda não foi autorizado ou foi negado
  (o pedido/explicação só aparece com o app visível), quando Atividades ao Vivo estão desligadas, quando
  o sistema recusa a Live Activity em segundo plano (a chamada iniciada é desfeita e recomeça em primeiro
  plano) ou quando não há servidor/credenciais. Se o contexto não puder abrir o app, o intent falha com
  uma mensagem pedindo para abrir o OpenCode.
- **Feedback:** `VoiceFeedback` vibra `success` quando a chamada fica pronta pela primeira vez e
  `error` na falha. Em primeiro plano usa `UINotificationFeedbackGenerator`; em segundo plano (onde os
  geradores do UIKit não tocam) usa a vibração do sistema. O transporte ativa
  `allowHapticsAndSystemSoundsDuringRecording` para a vibração não ser suprimida pelo microfone.
- **Diagnóstico:** `VoiceLaunchLog` registra fases sem conteúdo (`launch-request`, `launch-background`,
  `launch-foreground reason=…`, `launch-acknowledged`, `start`, `ready`, `failed`, `end`) no os_log
  `VoiceStartup`; builds DEBUG também as gravam em `Library/Caches/voice-launch.log`, lido do container
  do app no aparelho com `xcrun devicectl device copy from`.
- **Motivo da queda (31/10):** toda falha (`fail`), perda com reconexão (`lose`), interrupção de áudio e fim
  pelo usuário vira um relatório `VoiceDiagnostic` (OpenCodeKit) com a categoria (`service_error` com o
  `type/code` do `error` do GPT Live, `invalid_event` com o tipo do evento, `lease_refused`, `send_failed`,
  `ice_failed`, `data_channel_closed`, `audio_interrupted`, `user_end`, `session_closed` com o `reason` do serviço
  como `code`…), os últimos 24 nomes de evento
  (tipos do canal e estados do transporte), a fase, o estado do app (frente/fundo, bloqueado), a sessão de
  áudio e a rota (iPhone) e a rede. Desde 31/10, um `service_error` leva também `detail`, a mensagem e o `param`
  do erro sanitizados por `VoiceDiagnosticText` (sem caracteres de controle, trechos entre aspas com mais de 32
  caracteres viram `"…"`, até 300 caracteres; o servidor aplica as mesmas regras de novo), e todo relatório leva o
  tipo do último comando enviado no canal (`lastSent`, `delegation.context.append` ou `session.context.append`) e há
  quantos segundos. Desde 02/11 (quarta onda) leva também o ID da chamada no GPT Live (`remoteCall`, o último trecho
  do `Location` da criação, limitado como os nomes) e, num erro do GPT Live que nomeia um comando nosso pelo
  `event_id`, o tipo dele e há quantos segundos saiu (`failedCommand`, `failedCommandSeconds`); `session.started`
  traz o mesmo ID e o fim da sessão (`expires_at`, registrado no os_log como `expires_in`). Nada de fala ou
  transcrição. Vai a `custom.voice` →
  `diagnostics`; o servidor grava `Voice diagnostics` em `~/.local/share/opencode/log/opencode.log`. Sem
  servidor ou sem essa RPC, o app guarda até 20 em `Application Support/voice-diagnostics.json` e manda na
  próxima conexão do fluxo de eventos (`EventHub`). Em todo build, o os_log `VoiceStartup` registra
  `phase=failed reason=<categoria> code=…` e `phase=lost reason=…` como públicos; o texto mostrado continua só
  no arquivo DEBUG.

### Verificação — 24/10

Simulador **OpenCode Botao Acao** (`E834089D-E702-428E-B778-FDB9073EB9A3`, iPhone 18 Pro/iOS 27),
servidor e llm-proxy alcançáveis: em todos os casos o app ficou atrás, só a Live Activity apareceu e a
chamada ficou **pronta** (de `launch-request` a `ready`):

| Gatilho | App | Resultado | Até pronto |
| --- | --- | --- | --- |
| Botão de Ação (`agent-device action-button`) → Control | encerrado | segundo plano, Live Activity | 2,3 s |
| Botão de Ação de novo, com chamada ativa | — | só vibra (`launch-acknowledged`) | — |
| Central de Controle → Control | suspenso | segundo plano | 2,0 s |
| Central de Controle sobre o app aberto | aberto | chamada no app, sem segunda tela | 1,5 s |
| Atalhos → **Falar com a mestra** | encerrado | segundo plano | 1,9–2,5 s |
| Atalhos | suspenso | segundo plano | 1,5 s |
| Atalhos, microfone não decidido | encerrado | app vem para a frente e pede o microfone | — |

Encerrar pelo X da Live Activity e pela faixa funcionou. iPhone 14 físico (sem Botão de Ação),
sem resolver `llm-proxy-svc` (o mesmo limite de rede descrito abaixo): Central de Controle com o app
encerrado, suspenso e aberto, e Atalhos com o app encerrado, iniciaram em segundo plano — a Live
Activity foi aceita, a sessão `playAndRecord` e a trilha do microfone abriram (`offer-start` em
~0,1 s, `offer-ready` em ~0,2 s) — e falharam honestamente no DNS do proxy, com vibração de erro e a
faixa **Falha na conexão** ao abrir o app. Não houve conversa real nem delegação à mestra. Bloqueio e
Face ID não foram exercitados remotamente; a política fica no metadata do intent
(`authenticationPolicy` explícito).

## Referências e limites

- Abacato iOS `06a77dd`/`99e2be7`: envelope direto GPT Live, oferta completa, canal de delegação e
  áudio; essas revisões na verdade chamavam `chatgpt.com` com credencial local. Aqui a adaptação
  usa as leases obrigatórias do proxy, sem login OAuth no iPhone.
- `3418039`/`b2457d7`: separação executor/UI, limites e invalidação de callbacks; não o transporte
  incremental, que depende do backend Abacato.
- `3c7fff2`: preparação local sobreposta ao bootstrap/reserva; `5f46c6c`: logs fechados por fase,
  sem SDP, endereços, sessões, transcrições ou tokens. `2ff77f9`: ownership explícito de fechamento;
  o proxy direto exige teardown local antes do DELETE.
- Docs `Voice-Barge-In`, `Voice-ICE-Timeout`, `Voice-Response-Latency`, `Voice-Polish`: full-duplex,
  não confundir admissão com conclusão, progresso sem esperar resposta completa, sem polling visual
  de alta frequência na raiz.
- Binário WebRTC 147.0.0, wrapper imutável `e8b5efb9d921a7d3044d3928ae235b8846436e41` no
  `Package.resolved`. É o mesmo pacote comunitário auditado no Abacato; integridade do checksum não
  é atestação independente de origem do binário. Não foi substituído por um artefato supostamente próprio.

## Verificação

O handoff da faixa A passou com o motor falso nas duas variantes: 20 testes por tema no recorte de
UI/controlador/mestra/Activity/composer, oito casos de layout por tema e 289 testes Kit na rodada final. Builds Debug/test
e Release sem warnings. O manifesto final da faixa está em
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-faixavoz-prints/verification.json`.

`swift test` em `OpenCodeKit` cobre contrato, leases, estado, interrupções, UTF-8 e narração, inclusive o estado
quieto da mestra (`VoiceMasterStatus`) e o resultado para a fala (`VoiceResultTests`, com os mesmos casos do Watch).
Os testes hospedados `VoiceControllerTests` e `VoiceMasterTests` usam transporte/HTTP/mestra falsos.
`script/test-voice.py` importa e remove apenas seu histórico no sandbox explícito, sem inferência da mestra, e roda
`VoiceUITests` com `-OpenCodeVoiceFixture`, nas duas variantes OpenChamber. Esse modo não abre o
microfone nem o proxy. `-OpenCodeVoiceFakeMaster`, também DEBUG-only e restrito ao sandbox explícito,
permite testar áudio real no iPhone sem alcançar o OpenCode de produção.
O motor falso também passa turnos canônicos pelo buffer e pelos RPCs KV, quando
disponíveis; muitas repetições podem alcançar o gatilho de resumo do plugin.
O fixture puramente visual da faixa usa somente memória sintética local.

Para esta frente, use somente **OpenCode Voz Memoria** (`31CE4E76-2902-4D64-A9C3-F069593B454F`),
`OPENCODE_VOICE_SERVER_URL=http://127.0.0.1:4180`, `OPENCODE_VOICE_DERIVED=…/opencode/ios-vozmem-derived`
e `OPENCODE_VOICE_EVIDENCE=…/opencode/ios-vozmem-prints`. Ambos os runners aceitam
essas variáveis, mais `OPENCODE_VOICE_DEVICE`; não reutilize simuladores/DerivedData de outra frente.

### Verificação da memória iOS — 23/10

`swift test`: **299 testes** passaram. O recorte hospedado de voz/mestra/Activity e
motor falso passou em ambos os temas: **11 passaram, um probe real foi pulado por
padrão**, por tema. Quatro casos da faixa/leitor por tema cobrem abrir/atualizar/
fechar sem encerrar voz, ambas as roles, interrupção, Dynamic Type máximo e os
controles/insets existentes. Não foi rodada a suíte completa do app nesta frente.

No sandbox 4180, o motor falso gravou texto canônico completo e IDs qualificados;
contexto relido confirmou ambas as roles e interrupção. Os seeds temporários dos
runners são removidos; o KV de teste sintético permanece no home privado do sandbox.

Um único probe real no simulador passou pelo `VoiceController`/`VoiceSignaling`
de produção: **20 initial_items**, roles user/assistant, **648 tokens estimados**,
HTTP **201**, mídia/canal conectados e **session.started**, seguido de DELETE
da lease **204**. O wrapper de teste desabilitou a trilha do microfone depois da
oferta local e **antes** de sinalizar ao proxy; nenhuma fala humana foi enviada.
Não se verificou recordação semântica nessa rodada, apenas transporte inicial e
prontidão nativa. Não houve delegação à mestra. O teste fica desativado, exige
simulador, sandbox 4180 e `OPENCODE_TEST_LIVE_VOICE=1` explícitos.

Capturas/logs/xcresults:
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-vozmem-prints/`.
`verification.json` registra os resultados finais e caminhos absolutos. Warnings
do toolchain de teste sobre metadata de debugger/SDK não são warnings de compilação;
os builds Debug e Release são checados separadamente.

Para usar o simulador da faixa com a regressão do motor, configure
`OPENCODE_VOICE_DEVICE=41015785-0AB5-413B-8CEC-8C986E83BC1E`,
`OPENCODE_VOICE_DERIVED=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-faixavoz-derived`
e `OPENCODE_VOICE_EVIDENCE=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-faixavoz-prints`.
Selecione `OpenCodeUITests/VoiceUITests`, `OpenCodeTests/VoiceControllerTests`,
`OpenCodeTests/VoiceMasterTests` e `OpenCodeTests/VoiceActivityTests`; repita em `openchamber-light`.
`script/test-voice-bar.py` verifica separadamente os onze estados de apresentação (inclui **Sem conexão**) e seus dois tamanhos
sobre Sessões e conversa, sem iniciar o motor. Ambos deixam os seeds e o serviço sandbox intactos.

Build: `xcodebuild … -derivedDataPath "$TMPDIR/opencode/ios-voz-derived" build-for-testing
COPY_PHASE_STRIP=NO`. Assinatura/export local: `OPENCODE_DERIVED_DATA=… script/testflight.sh --dry-run
--allow-dirty --auth api-key`; sem upload. A variável opcional preserva o DerivedData padrão do script
para os demais fluxos. Evidências e resultados da rodada ficam em
`/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-voz-prints/`.

### Alcance observado no iPhone 14

Em 23/10/2026, Safari não resolveu `llm-proxy-svc`; o acesso direto à VIP `10.0.2.123:8080`
também expirou. Cloudflare One abriu uma solicitação de login para `alexandrerm.cloudflareaccess.com`;
ela foi cancelada e a tela principal declarou **Conectado**. Isso não comprova identidade Gateway
válida nem aplicação do perfil correto. Não foi alterado login, DNS, VPN, Gateway, túnel ou serviço.
As capturas `iphone-proxy-dns.png`, `iphone-proxy-route.png` e `iphone-warp-login.png` registram o limite.

Os documentos de infraestrutura já preveem o override DNS para `10.0.2.123`, o include `/32` pelo
túnel `docker-swarm` e a regra Gateway restrita ao proprietário. Antes de pedir nova infraestrutura,
Alexandre deve verificar a identidade/sessão WARP desse aparelho e se esse perfil recebe aquelas
três regras existentes. Não se demonstrou que uma nova exposição pública ou alteração do proxy
seja necessária. Nenhuma chamada GPT Live paga foi executada nessa verificação de alcance.

A extensão foi instalada e renderizou sua Live Activity no iPhone 14 com o motor DEBUG falso.
Depois de ir à tela inicial, o painel de notificações exibiu o estado; os controles de silenciar e
encerrar executaram no app e a atividade desapareceu ao encerrar. Isso valida UI/Intents em background,
não áudio real nem continuidade com o aparelho bloqueado. O iPhone 14 não possui Dynamic Island;
essa apresentação exige um modelo Pro compatível ou o simulador dedicado.

### Resultados desta rodada

- `swift-verified.log`: 290 testes Swift passaram (incluindo as fixtures de voz e apresentação
  presentes no checkout compartilhado).
- `regressions-final.log`: sete testes hospedados de controlador/mestra/Activity e a regressão de
  permissões/perguntas por transporte nativo/RPC passaram. O build limpo desse recorte excluiu
  temporariamente o teste de tipografia de outra frente ainda em edição; ele não é validação da
  suíte completa do aplicativo.
- `tests-dark-final.log` e `tests-light-final.log`: navegação, mute/end e progresso no motor falso
  passaram nas duas variantes com a barra provisória. O layout A definitivo tem verificação própria.
- `signing-summary.json` e `testflight-verified.log`: archive e export IPA assinados, sem upload;
  `codesign --verify --strict` passou para o app e para `VoiceActivity.appex`, build `202610231026`.
- Consumo de modelos desta rodada: **zero**. Nenhum prompt foi enviado ao llm-proxy ou à mestra real.

### Verificação da tela para a mestra — 29/10

Sandbox próprio na porta 4214, simulador **OpenCode Voz Tela** recriado a cada execução.
`swift test` (Kit) cobre a decisão de captura × recusa, a linha de contexto, o parse de `screen` e a
descrição fixa; os hospedados cobrem a captura real sem faixa e sem toast (`VoiceScreenCaptureTests`),
o anexo no formato do composer (`VoiceMasterTests`) e captura no evento, delegação sem tela e recusa
só para o GPT Live (`VoiceControllerTests`). `script/test-voice-screen.py` (variáveis
`OPENCODE_VOICE_SERVER_URL`, `_HOME`, `_DERIVED`, `_EVIDENCE`, `_DEVICE`) roda `VoiceScreenUITests`
com `-OpenCodeVoiceScreenFixture`: GPT Live simulado, mestra real do sandbox. Ele interrompe a mestra
assim que o prompt chega, confere a parte `image/jpeg` inline e salva a JPEG recebida; com o app em
segundo plano, nada é enviado (`refused:background`). Nos dois temas.

### Verificação da recuperação de rede — 24/10

Simulador exclusivo **OpenCode Voz Resiliencia** (iPhone 18 Pro/iOS 27), DerivedData
`$TMPDIR/opencode/ios-vozres-derived`. `swift test`: **348 testes** Debug e **347** Release. Os testes
hospedados de `VoiceControllerTests` usam transporte, rede, sons e proxy falsos com limites curtos:
renovação que falha uma vez não encerra; falhas até o fim da lease fecham o áudio no prazo e, com o
proxy inalcançável, esgotam a recuperação com alerta; recusa 403 encerra na hora sem reconexão; queda
de rede passa a **Sem conexão** e, com a rede de volta, abre um segundo link com nova lease, DELETE do
anterior, mute preservado e o turno ouvido antes da queda em `initial_items`; sem rede, nenhuma
tentativa é feita até a janela esgotar; falha antes da primeira conexão não entra em recuperação.
Dez iterações seguidas passaram. Toda a suíte `OpenCodeTests` passou (98, três probes opt-in pulados).

O probe opt-in `testExplicitSilentLiveRecovery` (`TEST_RUNNER_OPENCODE_TEST_LIVE_VOICE_RECOVERY=1`,
somente simulador) usa o proxy real com WebRTC mudo antes da oferta: bloqueia renovações por uma
rodada (a chamada continua), injeta perda de mídia e confirma a segunda chamada real pronta em cerca
de 2,3 s (1 s de espera + negociação). Resultado: criações `[201, 201]`, liberações `[204, 204]`.
Duas chamadas silenciosas, sem fala humana e sem delegação à mestra.

Ressalvas: o simulador compartilha a rede do Mac, então a perda de rede real foi simulada no proxy e
no transporte, não com o rádio. O tique em background e a troca Wi-Fi→celular com o iPhone bloqueado
ainda precisam de um aparelho que alcance o `llm-proxy-svc`. A faixa **Sem conexão** foi conferida
pelo fixture `-OpenCodeVoiceBarFixture offline`; o alerta de esgotamento é coberto pelo teste do
controlador, não por captura.
