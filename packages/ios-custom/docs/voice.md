# Conversa por voz

O botão de onda em **Sessões** inicia uma chamada GPT Live. `FloatingVoiceBar` substitui o acessório
da Sessão mestra nas abas, sem uma segunda barra empilhada, e ocupa espaço acima do composer na
conversa. Não há mais janela provisória no topo. A apresentação compartilhada continua durante a
navegação, e os sheets usam um inset inferior. Encerrar voz não interrompe tarefas já admitidas
pela Sessão mestra. Transporte, delegação e Live Activity são independentes dessa view.

A ponte de apresentação observa `state`, `elapsed`/`connectedAt`, `currentSpokenLine`,
`masterProgressLine` e `busy`; chama `mute()`, `end()`, `retry(sessions:)` e `resume()`.
O relógio é lido pela view, sem publicar ticks no controlador nem reconstruir toda a aplicação.
`VoiceBarState` mantém o contrato de apresentação puro. Compacta por padrão, a faixa expande por
toque e recolhe por toque/deslize para baixo; VoiceOver reúne estado, tempo e ações num elemento.
O modo de demonstração do layout é separado do motor falso, conforme
[`voice-bar-integration.md`](voice-bar-integration.md).

## Contrato privado do llm-proxy

Origem fixa: `http://llm-proxy-svc:8080`. O aplicativo não contém tokens ChatGPT nem usa o backend
Abacato. A exceção ATS é restrita a esse hostname. A infraestrutura privada precisa estar acessível
pelo WARP; não se publica essa origem na Internet.

1. `POST /_gpt-live/sessions/{UUID}` com `{"generation":"UUID"}` reserva a geração.
   A resposta 200 fornece `sessionId`, `generation`, `serverTime`, `leaseExpiresAt`; identidade e
   prazo são validados antes da negociação.
2. `POST /backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas`, JSON com `sdp`
   completo e `session`: modelo `gpt-live-1-codex`, `audio.output.voice=cove`, instruções pt-BR e
   `delegation.type=client`. Headers: `OpenAI-Alpha: quicksilver=v2`, `originator: a2a-chat`,
   `session-id`, `thread-id`, `x-session-id` e `x-gpt-live-generation`. O proxy escolhe a conta e
   injeta credenciais. Só 201 com SDP e Location é aceito; criação ambígua não é repetida.
3. `PUT /_gpt-live/sessions/{UUID}`, mesmo body, a cada cinco segundos. Timeout HTTP de oito
   segundos e margem conservadora de dez segundos no prazo retornado. Falha de renovação encerra
   o áudio, em vez de continuar depois da autorização. A lease padrão no deploy é de 60 segundos.
4. Encerramento fecha primeiro mídia/canal/áudio local, depois envia `DELETE` com `generation` na
   query. Se a rede estiver indisponível, a lease do proxy expira; não há retry de criação.

O protocolo é o privado GPT Live/Codex, **não** `/v1/realtime` público. O canal `oai-events` transporta
`session.started`, `input_transcript.added`, `output_transcript.added`, `turn.done`,
`delegation.created` e `delegation.context.append`. Appends usam `channel=speakable`, até 500 bytes
UTF-8 por parte. Eventos e texto têm limites locais. Erros remotos não são despejados em logs.

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
áudio** é explícito. Media-services reset exige nova conexão. Uma troca de rede tem dez segundos
para recuperar o peer; depois há erro honesto e reconexão manual, com novos UUIDs.

## Sessão mestra

`VoiceMaster` usa apenas contratos existentes de `OpenCodeKit`. A primeira delegação relê
`custom.preferences`, usa o ponteiro `masterSessions.local` quando válido ou faz o mesmo fluxo do
composer: `custom.master/info`, allocate/claim de chat, create Session com agente `mestra`, confirm,
`master.set`, prompt. Nenhuma sessão é criada apenas ao abrir a voz.

O retorno do prompt é **admissão**, não conclusão. A subscrição ao `EventHub` começa antes do envio;
ferramentas e textos concluídos alimentam atualizações curtas. Isso inclui os `toolCalls` estruturados
de progresso do Code Mode; sessões conhecidas são identificadas pelo título, nunca por IDs falados.
Raciocínio, argumentos de ferramentas,
tokens e credenciais não são narrados. Reconexão/lacuna do stream revalida transcript, atividade e
inbox em `session.execution.succeeded`; falha/interrupção usam os eventos terminais próprios.
O resultado só é final quando não há execução nem mensagens pendentes. A recuperação encontra o
ID durável do prompt (até 200 mensagens), sem comparar relógios do iPhone e do servidor. Não há um segundo
stream SSE em paralelo ao da aplicação.

`VoiceNarration` é uma caixa de último progresso, não uma fila de falas antigas: agrupa/coalesce,
limita atualizações a uma a cada cinco segundos e cede ao usuário e à fala em andamento. O resultado
tem prioridade sobre progresso pendente. O prompt de voz pede resumo natural sem ler Markdown.
Pedidos seguintes são admitidos serialmente, mas não aguardam conclusão do modelo. Texto normal
usa `steer`; JSON `{"text":"…","delivery":"queue"}` só é pedido ao GPT Live quando Alexandre
explicitamente quer enfileirar. ID repetido da mesma delegação não é reenviado.

## Background e Live Activity

`UIBackgroundModes=audio` preserva a mídia autorizada quando o usuário bloqueia o telefone ou troca
de aplicativo. O `EventHub` permanece ativo durante a chamada para acompanhar a mestra. Não há
background task fictícia nem loop de áudio silencioso. O sistema ainda pode suspender/encerrar o
app; isso não garante execução depois de force-quit.

O target `VoiceActivity` (`br.com.alexandrem.opencode.VoiceActivity`, time `ERRYZ68LX5`) é embarcado
no app. `VoiceShared` contém atributos e `LiveActivityIntent`s. A Live Activity e Dynamic Island
exibem ouvindo/falando/trabalho da mestra; mute/end são validados pelo UUID da chamada no processo
do app. Tema é um snapshot de roles tipados. O driver mantém instâncias ActivityKit fora da MainActor
durante chamadas assíncronas e limpa apenas atividades desse tipo deixadas por uma execução anterior.
Live Activity negada pelo sistema não derruba áudio. Ela não contém transcrição pessoal.

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

`swift test` em `OpenCodeKit` cobre contrato, leases, estado, interrupções, UTF-8 e narração.
Os testes hospedados `VoiceControllerTests` e `VoiceMasterTests` usam transporte/HTTP/mestra falsos.
`script/test-voice.py` importa e remove apenas seu histórico no sandbox 4177, sem inferência, e roda
`VoiceUITests` com `-OpenCodeVoiceFixture`, nas duas variantes OpenChamber. Esse modo não abre o
microfone nem o proxy. `-OpenCodeVoiceFakeMaster`, também DEBUG-only e restrito ao sandbox explícito,
permite testar áudio real no iPhone sem alcançar o OpenCode de produção.

Para usar o simulador da faixa com a regressão do motor, configure
`OPENCODE_VOICE_DEVICE=41015785-0AB5-413B-8CEC-8C986E83BC1E`,
`OPENCODE_VOICE_DERIVED=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-faixavoz-derived`
e `OPENCODE_VOICE_EVIDENCE=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/ios-faixavoz-prints`.
Selecione `OpenCodeUITests/VoiceUITests`, `OpenCodeTests/VoiceControllerTests`,
`OpenCodeTests/VoiceMasterTests` e `OpenCodeTests/VoiceActivityTests`; repita em `openchamber-light`.
`script/test-voice-bar.py` verifica separadamente os dez estados de apresentação e seus dois tamanhos
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
