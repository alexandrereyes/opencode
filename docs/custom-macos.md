# OpenCode Custom no macOS

Instalação independente para a branch `custom` do fork `alexandrereyes/opencode`.
O upstream é `anomalyco/opencode:beta`. A feature aprovada de menções `@` a apps Mac é a base de `custom`.

## Modelo operacional

- Backend Bun **1.4.2**, executando TypeScript em checkout destacado por SHA; UI Vite de produção do **mesmo SHA**.
- Endereço fixo: **http://127.0.0.1:4177**. Autenticação HTTP Basic: usuário `opencode`; senha local em `password`.
- Diretório independente: `~/.local/share/opencode-custom`. Configuração, banco, cache, estado e logs próprios.
- O controlador também usa checkout destacado. O Bun privado é copiado durante instalação; não substitui o Bun global.
- Agenda launchd diária às **04:15, horário local**. Em repouso/suspensão, aplica-se o comportamento normal de retomada do launchd.
- Preparação e sincronização não dependem de o backend estar ocioso. O supervisor tenta ativar uma release preparada a cada **300 segundos**, indefinidamente.
- `flock` do SO protege atualização e supervisor separadamente; crash libera o lock. launchd mantém uma única instância por label.
- O serviço oficial e o registro `~/.local/state/opencode/service.json` não são usados pelo controlador.

## Instalação e primeiro uso

Pré-requisitos: macOS, Git autenticado com permissão de push no fork, `gh` autenticado e Node/npm para obter o Bun fixado. Execute a partir de um checkout **commitado e publicado** contendo o controlador:

```sh
npx --yes --package=bun@1.4.2 -c 'bun packages/cli/script/custom/update.ts install'
export PATH="$HOME/.local/share/opencode-custom/bin:$PATH"
opencode-custom bootstrap
opencode-custom status
```

`install` grava os dois plists, mas **não carrega nenhum job**. `bootstrap` prepara a release inicial, testa UI/backend isolados e grava `current.json`; também não carrega jobs. Não execute uma segunda instalação sobre configuração existente.

Para iniciar explicitamente a instalação própria:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.alexandrereyes.opencode-custom.server.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.alexandrereyes.opencode-custom.daily.plist"
open http://127.0.0.1:4177
```

Faça login usando a senha do arquivo privado, sem copiá-la para logs, tickets ou Git. Configure providers e MCPs na instalação custom. O banco começa vazio: nenhuma sessão ou credencial da instalação oficial é migrada automaticamente. Para abrir o TUI oficial como cliente do servidor custom, use `--server` explícito e `OPENCODE_PASSWORD` fornecido localmente; nunca use descoberta implícita para esse fim.

## Atualizações

```sh
opencode-custom sync
opencode-custom status
launchctl print "gui/$(id -u)/com.alexandrereyes.opencode-custom.server"
launchctl print "gui/$(id -u)/com.alexandrereyes.opencode-custom.daily"
tail -f "$HOME/.local/share/opencode-custom/logs/daily.log"
```

1. Fetch de `origin/custom` e `upstream/beta`, com retry de operações de rede (5 e 10 segundos).
2. Branch `sync-<data>-<id>` em worktree separada baseada no SHA de `custom` observado.
3. Merge do SHA upstream observado; instalação com lockfile, typechecks Core/Protocol/Client/Server/CLI/App, suíte Core de manutenção/admissão/execução/geração/jobs/shells/terminais e suíte Server completa, build UI e smoke real.
4. Merge limpo validado: fetch novamente, comparação com base observada e push **fast-forward comum**, sem force. Concorrência aborta a integração.
5. Conflito ou erro de código: `opencode run --auto --server <custom>` resolve na worktree e valida novamente. O controlador publica branch e PR com destino **custom**, sem integração automática. O provider precisa estar configurado no servidor custom. Sem agente disponível, conserva a worktree para diagnóstico.
6. Falha transitória de dependências/rede não pede correção de código ao agente. Worktrees e logs de falha são preservados.
7. Release destacada é construída/testada em staging; só então publica `pending.json` atomicamente. Releases existentes podem ser reutilizadas.

O controlador não atualiza o próprio checkout automaticamente: novas versões do mecanismo operacional devem ser revisadas e instaladas explicitamente. Upgrades de Bun exigem essa revisão também.

## Manutenção atômica

`POST /api/server/maintenance` adquire uma barreira síncrona process-local somente sem atividade registrada. Durante a lease:

- Novos requests de trabalho recebem 503; novas admissões internas ficam suspensas até cancelamento/expiração.
- Sessões incluem filhos/background e permanecem ocupadas até settlement; shells/jobs retêm atividade até cleanup; gerações avulsas são rastreadas.
- Permissões e formulários pendentes bloqueiam ativação.
- **Todos os terminais ainda abertos são conservadoramente bloqueantes**, inclusive terminais persistentes. Feche/remova-os antes de esperar atualização.
- Inbox durável pendente e notificações background ainda não admitidas também bloqueiam.
- Estado desconhecido ou health diferente de **HTTP 200** adia ativação.
- A lease expira em 60 segundos ou pode ser cancelada. `commit` valida token + identidade de processo e fecha definitivamente a admissão antes de agendar shutdown. O supervisor verifica também o PID do filho que ele próprio criou; não sinaliza PIDs salvos em disco.
- O supervisor aguarda a confirmação do commit e a saída do filho. Falha/resultado desconhecido conserva o estado atual e tenta novamente depois.

O backend tem um pipe de vida ligado ao supervisor: se o supervisor morrer, EOF encerra seu backend privado. Isso evita órfãos após reinício do launchd.

## Backup e rollback

Após shutdown ocioso confirmado e **antes de iniciar o novo código**, o supervisor copia `data/` inteiro (SQLite, WAL e valores em arquivo) para `backups/<timestamp>-<sha>/`. Registra a release anterior em `previous.json` e publica a próxima em `current.json` antes de migrations.

Não há rollback automático de banco. Um binário anterior pode ser incompatível com schema já migrado. Falha de startup mantém `current.json` apontando para a nova release: launchd tenta essa mesma release, sem abrir o banco com código antigo.

Para manutenção manual sem interromper trabalho:

```sh
opencode-custom pause
# Espere status mostrar paused: true; tentativa a cada 300 s e somente idle.
opencode-custom status
```

Com `paused: true`, o supervisor não mantém backend ativo. Antes de restaurar, preserve uma cópia adicional do `data/` atual e dos manifests. Selecione o backup em `previous.json`, restaure **todo** seu `data/` e coloque o `release.json` desse backup em `current.json`. Remova/mova `pending.json` para não reaplicar imediatamente a release problemática. Restaurar backup descarta alterações posteriores ao backup; escolha explicitamente esse ponto de recuperação. Então:

```sh
opencode-custom resume
```

O supervisor lê novamente `current.json` antes de iniciar; retomada em até 300 segundos. Para apenas reverter código, primeiro confirme manualmente compatibilidade de schema; a existência de `previous.json` não é essa garantia.

Releases, backups e logs não são apagados automaticamente. Faça retenção manual após confirmar estabilidade; mantenha ao menos release atual, anterior e seu backup. Não remova worktrees em uso.

## Arquivos

| Caminho relativo ao home custom                 | Uso                                                     |
| ----------------------------------------------- | ------------------------------------------------------- |
| `bin/opencode-custom`, `bin/bun`                | Launcher e runtime fixado                               |
| `controller/`                                   | Checkout fixado do controlador                          |
| `repository/`                                   | Clone operacional com remotes origin/upstream           |
| `worktrees/`                                    | Merges, reparos e staging conservados                   |
| `releases/<sha>/`                               | Backend source e UI `packages/app/dist` do mesmo commit |
| `config.json`, `password`                       | Configuração operacional e credencial privada (0600)    |
| `config/opencode/`                              | Configuração OpenCode custom                            |
| `data/opencode/custom.db`                       | Banco independente                                      |
| `current.json`, `pending.json`, `previous.json` | Manifests atômicos                                      |
| `logs/`, `backups/`                             | Diagnóstico e recuperação                               |

Plists: `~/Library/LaunchAgents/com.alexandrereyes.opencode-custom.{server,daily}.plist`.

## Verificação de desenvolvimento

```sh
cd packages/core
npx --yes --package=bun@1.4.2 -c 'bun run test test/maintenance.test.ts test/job.test.ts test/session-run-coordinator.test.ts test/generate.test.ts'
cd ../cli
npx --yes --package=bun@1.4.2 -c 'bun test test/custom-update.test.ts'
npx --yes --package=bun@1.4.2 -c 'bun typecheck'
```

Os testes de sincronização usam repositórios Git temporários; ativação usa HTTP fake isolado. O smoke real usa porta efêmera, banco/config privados e encerra somente o próprio processo de teste.

Baseline macOS (2026-09-09): a suíte Core completa teve 5405 passes, 21 skips e 7 falhas de sintaxe/process substitution com `/bin/bash` 3.2.57. As mesmas 7 falhas foram reproduzidas na base `98d5fcd27`, nos arquivos `tool-shell.test.ts` e `shell-scan/compound-parity.test.ts`. Elas não são mascaradas nem corrigidas pelo updater; a validação diária usa a suíte operacional indicada acima. Server: 55 passes e 3 skips de persistent-PTY já condicionais na suíte.
