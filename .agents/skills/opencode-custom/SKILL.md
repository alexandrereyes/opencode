---
name: opencode-custom
description: Desenvolve e publica customizações pessoais do OpenCode V2 no fork de Alexandre, usando branches de feature a partir de custom e worktrees isoladas.
slash: true
metadata:
  opencode/autoinvoke: true
---

# OpenCode Custom

Use quando o pedido envolver desenvolver ou publicar customizações pessoais do OpenCode V2 no fork de Alexandre, ou quando ele pedir explicitamente por `opencode-custom`.

## Objetivo

Transformar o pedido em uma feature do fork pessoal, validar e publicar seguindo o fluxo abaixo. Se a invocação não contiver uma mudança concreta, pergunte qual feature deseja; não invente trabalho. Respeite pedidos de somente investigar, prototipar ou não publicar.

## Mapa do ambiente

| Recurso | Local |
| --- | --- |
| Fork (`origin`) | `https://github.com/alexandrereyes/opencode.git` |
| Oficial (`upstream`) | `https://github.com/anomalyco/opencode.git` |
| Base das features e destino de integração | `origin/custom` |
| Linha upstream integrada | `upstream/v2` (fonte do canal `latest`; `beta` parou na 2.0.6) |
| Checkout principal conhecido | `/Users/alexandremartins/Dev/opencode` |
| Worktree da feature inicial de apps | `/Users/alexandremartins/Dev/opencode2` |
| Worktree do updater | `/Users/alexandremartins/Dev/opencode-updater` |
| Configuração operacional versionada | `/Users/alexandremartins/Dev/my-env` (não `myenv`) |
| Instalação custom | `~/.local/share/opencode-custom` |
| Comando operacional | `~/.local/share/opencode-custom/bin/opencode-custom` |
| UI principal/produção | `http://127.0.0.1:4096` |
| Dev efêmero, sob demanda | `http://127.0.0.1:4177` — nunca serviço permanente |
| Jobs | `com.alexandrereyes.opencode-custom.server` e `.daily` |

Esses caminhos são pontos de partida, não garantias de estado. Confira Git, manifests, documentação e serviços antes de agir. Não copie SHAs ou nomes de modelos de sessões antigas.

## 1. Entender o pedido e o estado atual

1. Carregue a skill `opencode` e consulte a documentação **V2** pertinente em `https://opencode.ai/v2/docs/`.
2. Leia `AGENTS.md` da raiz e dos pacotes envolvidos. Para UI web use as skills de interface pertinentes; para código Effect, `effect`; para execução/debug do servidor, `opencode-dev`.
3. Inspecione `git status`, `git remote -v` e `git worktree list` no checkout existente. Preserve alterações e arquivos não rastreados de outras tarefas.
4. Leia a versão atual de `docs/custom-macos.md` no fork e a documentação operacional em `my-env`. O updater pode evoluir: confirme seus comandos por código/documentação antes de executá-los.
5. Diferencie **app web**, desktop e TUI. Para menções de apps Mac, consulte o MCP realmente configurado, seus métodos e retornos atuais; não presuma o antigo `codex-computer-use` ou formato de `list_apps`.
6. Se o trabalho integrar uma revisão upstream em `custom`, aplicar um PR/commit upstream antes da baseline integrada ou adaptar/portar uma mudança upstream, leia `docs/upstream-overrides.md` na base usada antes de alterar código. Ele diz o que `custom` já carrega de upstream e quando reconciliar.

## 2. Criar a feature

Todas as features pessoais partem de **`origin/custom`**, não de `beta`, `dev`, `main` ou `v2`. Essa escolha é específica deste fluxo de customização.

- Escolha nome curto, de até três palavras separadas por hífen, sem `/` ou prefixo `feat/`.
- Verifique previamente se a branch ou uma worktree da feature já existe. Para retomar uma feature, use a worktree dela. Use o caminho retornado pela criação, sem deduzir ou fixar um caminho em `~/Dev`.
- Se houver ferramenta de movimentação de sessão, mova a sessão para a nova worktree.
- Registre o SHA de `origin/custom` usado como base.
- Não use o checkout de release instalado nem o controlador em execução como área de edição.

## 3. Implementar

- Prefira pontos de extensão existentes quando reduzirem o trabalho de manutenção. Alterações diretas no backend e app web são permitidas quando necessárias.
- Preserve a estrutura do monorepo. Backend: `packages/core`, `server`, `protocol`, `schema`; frontend web custom: `packages/app-custom`, `ui-custom`, `session-ui-custom` (`packages/app`, `ui` e `session-ui` permanecem idênticos à baseline upstream); cliente: `packages/client`.
- Mudou Protocol ou Server HttpApi público? Execute `bun run generate` em `packages/client`; nunca edite arquivos gerados manualmente.
- Faça mudanças focadas, sem refatorações extensas não necessárias à feature.
- Para mudanças no updater, versionar código runtime no fork e os arquivos operacionais declarativos em `my-env`, conforme a organização vigente. Não duplique fontes que deveriam ser únicas.
- Credenciais, tokens, banco, logs, backups e releases ficam fora do Git. Não exiba segredos ao consultar configuração. Use arquivos locais privados ou referências a variáveis.
- Ao aplicar um PR/commit upstream antecipadamente ou adaptá-lo, registre a entrada em `docs/upstream-overrides.md` na mesma mudança, seguindo o template do arquivo: link, SHA da revisão upstream revisada, mudança local e diferenças, testes, status, condição para reconciliar/remover e instalação (`none` salvo ação operacional explícita). Mudança de UI upstream não entra antecipada em `packages/app`, `ui` ou `session-ui`: porte-a deliberadamente para `packages/app-custom`, `ui-custom` ou `session-ui-custom`. Apenas acompanhar um PR aberto, sem incorporá-lo, não gera entrada. O registro começou sem auditoria retroativa: ao identificar um caso antigo, registre-o também.

## 4. Validar

1. Use o Bun exigido pelo `packageManager` atual. A instalação custom tem runtime privado; não substitua o Bun global para satisfazer o projeto.
2. Rode `bun typecheck` a partir dos pacotes afetados e testes relevantes nos diretórios de pacote, nunca testes na raiz.
3. Para UI web, use `playwright-cli` para validar a interface real. Verifique filtro, seleção por clique/teclado, payload e viewports relevantes. Distinga claramente fixture de integração real.
4. Use `opencode-custom dev <worktree-da-feature>` para validação isolada em 4177 e encerre o processo ao terminar. Nunca teste em 4096. Não pare nem reinicie o serviço que hospeda a conversa.
5. Para updater/manutenção, teste lock, atividade em andamento, lease, falhas, concorrência com publicação e retomada. Não use sessões reais como alvo de testes destrutivos.
6. Execute `git diff --check` e revise o diff. Não contorne hooks de publicação. Falhas preexistentes exigem evidência na base, não mera suposição.

### Ambiente pronto para testar

- Antes de convidar Alexandre a testar, prepare a 4177 com os mesmos providers, modelos, MCPs e configurações efetivas da instalação principal. O usuário não deve precisar configurar tudo novamente a cada teste.
- Descubra as fontes atuais, respeitando overrides de ambiente e JSON/JSONC. O caminho global usual é `~/.config/opencode/opencode.json` (ou `.jsonc`). Preserve os ajustes da worktree da feature e aplique apenas as diferenças necessárias ao isolamento do teste.
- Configuração e autenticação são distintas. Na V2, credenciais/conexões são persistidas no banco; `~/.local/share/opencode/auth.json` é uma fonte legada e não garante autenticação atual. Inspecione o mecanismo vigente antes de transportar credenciais.
- Prepare uma cópia local privada da configuração e das credenciais necessárias em persistência exclusiva do teste, com permissões restritas (0600 para arquivos de segredos). Use exportação/importação suportada ou snapshot consistente para extrair os registros necessários; nunca copie diretamente o SQLite vivo, aponte o dev para o banco principal ou copie todo o histórico só para obter autenticação. Não exponha tokens em logs, comandos exibidos ou Git, nem permita que alterações do dev sejam gravadas na configuração principal.
- Referências a variáveis de ambiente, arquivos e plugins precisam continuar resolvendo no dev. Confirme no ambiente de teste os providers/modelos disponíveis e a autenticação/conectividade das integrações relevantes, sem revelar segredos. Não afirme equivalência apenas porque copiou o JSON.
- Confira a implementação atual de `opencode-custom dev`: o comando pode copiar apenas `opencode.json`, sem credenciais. Estas instruções são requisitos de preparação, não prova de que o comando já os automatiza. Se faltar suporte, implemente o ajuste mínimo no comando operacional e valide, ou reporte precisamente o bloqueio antes de entregar um ambiente incompleto.

### Correções sucessivas e cache da UI

- O ambiente 4177 deve servir a versão recém-construída sem service worker/PWA ativo. Um build de produção pode registrar SW mesmo quando usado para teste; confirme o comportamento real e use uma opção de desenvolvimento específica para impedir esse registro. Não altere a política de cache da produção 4096 para resolver um problema do dev.
- Para um navegador que já acessou a 4177, remova registros antigos de service worker e caches da aplicação somente na origem exata de teste. `localhost:4177` e `127.0.0.1:4177` são origens diferentes: use uma URL consistente e confira a origem antes de limpar. Preserve cookies, localStorage, IndexedDB e autenticação; não use limpeza global de dados do navegador.
- Impedir registros novos não desativa um SW que já controla a aba. Após remover o registro, faça a navegação/reabertura necessária e confirme que `navigator.serviceWorker.controller` é nulo e que nenhum registro da aplicação voltou. Headers `no-cache` ou um simples reload não bastam como evidência.
- Após cada correção solicitada, reconstrua/atualize o bundle servido a partir da worktree correta, atualize o processo dev quando necessário e valide novamente pelo Playwright antes de pedir novo teste. Respeite as instruções do repositório sobre ciclo de vida dos processos; nunca reinicie o servidor que hospeda a conversa.
- Disponibilize identificação visível do build no ambiente de teste (commit e identificador de build que também diferencie alterações ainda não commitadas), usando mecanismo existente ou um indicador restrito ao dev. Confira que o navegador mostra esse build e execute o comportamento corrigido; o SHA sozinho não distingue duas correções não commitadas.
- Ao entregar para teste, informe URL, build e resultado da checagem de configuração/cache. Não diga que esses mecanismos já estão implementados sem verificar o comando e o navegador reais.

## 5. Publicar e integrar

Para uma feature normal pedida por esta skill, implemente, valide, faça commit convencional e publique a branch no fork. Se Alexandre pedir só investigação, não faça commit. Se pedir revisão visual antes, aguarde essa aprovação antes de integrar.

```sh
git add <arquivos-da-feature>
git commit -m "feat(app): descrição objetiva"
git push -u origin <feature-curta>
```

- Faça stage apenas do trabalho desta feature.
- A integração é em **`custom` do fork**, nunca na branch oficial nem em `main` por hábito.
- Depois da aprovação da feature, prepare a integração em worktree limpa baseada no **`origin/custom` atualizado**, incorporando a feature e validando a combinação. Prefira squash para uma feature nova de vários commits; preserve histórico existente quando um merge for mais adequado.
- Imediatamente antes de publicar a integração, confirme que `origin/custom` não avançou. Se avançou, refaça a integração sobre a base nova e valide novamente.
- Publique por push normal fast-forward, sem `--force`. Não tente atualizar uma branch local `custom` que esteja em uso em outra worktree.
- Não misture sync do upstream com a feature. Esse é um processo independente do updater.

### Integrar upstream em `custom`

Integre de `upstream/v2`, que gera o canal oficial `latest`. Prefira o commit de origem do release publicado (`metadata.github.sha` em `https://opencode.ai/update/api/latest/cli/npm`); a tag de release só acrescenta o bump de versão. Registre baseline, pontos de integração e validação em `docs/upstream-beta-merge.md`.

Antes de integrar uma revisão upstream, reconcilie cada entrada aberta (`active` ou `reconcile`) de `docs/upstream-overrides.md` com essa revisão e atualize o registro na própria integração:

- Merge sem conflito ou ancestralidade não provam equivalência. O Git pode manter a cópia local e a versão upstream lado a lado; cherry-pick, patch e squash geram SHAs diferentes; o PR pode ter mudado depois da revisão registrada. Compare a mudança upstream final com o código local em comportamento, API, schema/migrations e testes.
- Decida explicitamente: remover o override que ficou redundante no mesmo caminho/serviço em que upstream agora fornece a mudança, manter só a adaptação mínima documentada, reescrever ou descartar quando upstream fechou ou divergiu.
- Na UI web, integrar upstream atualiza apenas `packages/app`, `ui` e `session-ui`. Um equivalente ali não torna redundante o porte em `app-custom`, `ui-custom` ou `session-ui-custom`, que é o que a web custom usa: preserve o porte necessário e compare-o manualmente com a versão upstream final, atualizando-o quando útil.
- Marque a entrada como `resolved` e mova-a para as resolvidas, com o resultado, somente quando a decisão estiver aplicada e não restar acompanhamento upstream. Adaptação que ainda depende de upstream continua `active` ou `reconcile`, com os campos atualizados; isso não bloqueia a integração nem updates.

## 6. Entrega e instalação

**Publicar em `custom` não significa que a versão já esteja ativa no Mac.**

- Confira `opencode-custom status` e a documentação operacional para solicitar preparação/ativação por meio do controlador existente.
- O modelo operacional é backend source em checkout fixo e UI de produção do mesmo commit.
- A publicação atualiza a experiência principal em **4096**, preservando o banco, sessões e providers principais. **4177 serve apenas para validar features em worktrees**, nunca é o destino permanente do updater.
- Confira `primaryAdopted` no status. Na instalação antiga, 4096 é um proxy para o backend oficial 4097, sem manutenção atômica. A primeira adoção requer janela explícita, clientes fechados e processo antigo parado fora da sessão do agente. `adopt-primary` recusa PID vivo e faz backup a frio; não invente transição segura baseada em active/pgrep, nem agende shutdown automático do backend que hospeda a conversa.
- Após adoção, o proxy 4096 aponta para o backend custom privado 4178, e o wrapper de `opencode2` usa endpoint explícito, sem alterar o binário oficial. O supervisor reserva 4097 para evitar respawn legado. Não altere o registro oficial enquanto seu processo estiver vivo.
- A preparação pode ocorrer durante uso. A ativação deve passar pela barreira de manutenção e esperar idle, tentando novamente a cada 120 segundos. Não substitua isso por `pgrep`, checagem isolada de `/api/session/active` ou leitura do SQLite.
- Não mate um processo ocupado para acelerar instalação. Um processo vivo pode estar idle; a API de manutenção é a autoridade para a troca coordenada.
- Não há sync automático: o updater periódico foi aposentado (veja `docs/custom-macos.md`). A integração upstream é manual, seguindo [Integrar upstream em `custom`](#integrar-upstream-em-custom), e a instalação usa `bun run custom:update` (skill `update-custom-app`).
- Se a mudança afetar o próprio controlador, siga seu procedimento documentado de atualização e retomada; não suponha que sair da sessão de agente reinicia o launchd ou instala código novo.
- Preserve a instalação e os dados oficiais durante a preparação. A adoção principal deve manter os caminhos de persistência e fazer backup antes de migrations. Se a primeira troca está bloqueada pela sessão atual, informe **preparada/pendente**, nunca **ativada**.

## Resposta de conclusão

Informe de forma curta:

- Feature implementada e comportamentos relevantes.
- Branch, worktree, commit e link do fork.
- Checks executados e limitações verificadas.
- Se foi **apenas publicada**, **integrada em custom**, **preparada** ou **ativada** — não confunda esses estados.
- Se a ativação está esperando idle, diga isso e forneça o comando de status.

## Escopo e acionamento

Configuração V2 oficial: `https://opencode.ai/v2/docs/skills/`.

Esta skill é versionada em `.agents/skills/opencode-custom/SKILL.md` na branch `custom` do fork. Deve acompanhar as worktrees baseadas nessa branch, sem uma cópia em diretórios globais de skills.

`metadata.opencode/autoinvoke: true` permite descoberta automática no contexto do projeto. `slash: true` mantém sua disponibilidade no catálogo interativo e ela também pode ser solicitada explicitamente pelo ID `opencode-custom`.
