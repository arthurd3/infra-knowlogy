# CLAUDE.md — convenções deste repositório

Contexto para sessões futuras. O que está aqui não é derivável do código.

## O princípio inegociável

**Toda afirmação técnica das lições precisa ser verificável por um comando.**

Se uma lição diz "isto leva 10 segundos", alguém rodou e cronometrou. Se diz
"5,5 MB", o número veio de `tools/scripts/sizes.sh`. Antes de escrever um número
ou uma afirmação de comportamento numa lição: **rode e confira**.

Isso já pegou erro real. A explicação difundida de que a shell form do `CMD`
quebra o `docker stop` está incompleta — medindo, descobriu-se que o BusyBox faz
`exec` de um comando simples e a causa verdadeira é o tratamento especial de
sinais no PID 1. A lição 3 documenta os quatro casos medidos, e é melhor material
justamente por isso.

## Idiomas

- **Lições** (`site/src/content/lessons/`): bilíngues, PT-BR **e** EN. Toda lição
  existe nos dois idiomas com o **mesmo campo `key`**; `make verify` reprova se
  faltar um par.
- **Comentários de código e ADRs**: português. São notas internas.
- **README.md**: **inglês, inteiro.** É a vitrine pública do repositório no
  GitHub; o alcance importa mais ali do que a consistência com o resto. Ele
  declara logo no topo que os ADRs e os comentários são em português, para o
  leitor anglófono não tropeçar nisso depois.
- **Identificadores, nomes de arquivo, slugs de URL**: inglês, sempre.

## Armadilhas já encontradas (não repita)

1. **`slug` é nome reservado** no glob loader do Astro — ele o usa como id da
   entrada, então duas lições com o mesmo `slug` colidem e uma é descartada
   *silenciosamente*. Por isso a chave compartilhada se chama `key`.
2. **SELinux exige `:z`** em bind mount. Sem o sufixo, o container recebe
   `permission denied` num arquivo com permissão 644. Este repositório foi escrito
   num Fedora e o primeiro `docker run -v` falhou exatamente assim.
3. **`pids_limit` e `deploy.resources.limits.pids` não convivem.** O Compose 5.x
   recusa o projeto. Use só a forma canônica, dentro de `deploy`.
4. **`npm ci` é estrito onde `npm install` não é.** O `@astrojs/check` aceita
   TypeScript `^5 || ^6`; o `npm install` tinha instalado o 7 calado, e só o
   `npm ci` dentro do Docker reprovou. O TypeScript está pinado em 6 por isso.
5. **Interpolação do Compose vs. do Caddy.** `${VAR:-padrão}` é Compose;
   `{$VAR:padrão}` é Caddy. Trocar os dois dá erro de interpolação.
6. **`cap_drop: [ALL]` quebra binário com file capability.** O binário do Caddy
   tem `cap_net_bind_service=+ep` gravado nele; o kernel se recusa a fazer
   `exec()` se essa capability não estiver no bounding set. Erro:
   `exec /usr/bin/caddy: operation not permitted` — sem nenhuma menção a
   capabilities. Vale mesmo publicando em porta alta.
7. **SELinux bloqueia os `secrets:` do Compose, e não existe `:z` para eles.**
   O `init-secrets.sh` aplica `chcon -Rt container_file_t` à mão. Sem isso o
   Postgres entra em loop com `Permission denied` em `/run/secrets/…`.
   O mesmo vale para `/var/run/docker.sock`: só `label=disable` resolve.
8. **Os segredos são 0444 de propósito.** Fora do Swarm, o Compose faz bind
   mount do arquivo COMO ELE ESTÁ — `uid`/`gid`/`mode` da spec são só do Swarm.
   Três serviços leem o mesmo arquivo com UIDs diferentes. A proteção real é o
   `chmod 700` no diretório.
9. **`build:` sem `target:` constrói a ÚLTIMA stage.** O serviço `web` subia com
   `astro dev` em produção porque a stage `dev` era a última do Dockerfile.
   Sempre declare o `target`.
10. **Volume nomeado herda dono do diretório que já existe na imagem.** Apontar
    para um subdiretório inexistente cria um volume vazio do root, e um serviço
    não-root não escreve nele (foi o caso do Alloy em `/var/lib/alloy/data`).
11. **O kubelet IGNORA o `HEALTHCHECK` do Dockerfile.** Sem probes declaradas
    no manifest, um pod com processo travado fica "Ready" recebendo tráfego.
    Toda saúde no k8s vem do `deployment.yaml`, sempre.
12. **kind < 0.23 ignora NetworkPolicy em silêncio** — a API aceita e nada
    aplica. O `k8s-prereqs.sh` recusa versões menores e o `k8s-verify` prova o
    enforcement de qualquer jeito (uma conexão proibida tem que falhar).
13. **Probe verde não prova alcançabilidade entre pods.** A probe parte do nó e
    não atravessa NetworkPolicy — o `web` ficou Ready respondendo 502 atrás do
    edge até ganhar a policy de ingress que faltava.
14. **PV novo nasce do root** (o primo k8s da armadilha 10). O entrypoint do
    Redis morria em `chown /data` sem a capability CHOWN. Correção:
    `runAsUser` + `fsGroup` no pod — e o cache ficou com `drop: [ALL]` sem
    devolver nenhuma capability.
15. **SIGKILL no PID 1 de dentro do namespace não funciona** (kernel ignora; é
    a física da lição 3 do módulo Docker). O teste de restart do `k8s-verify`
    usa SIGTERM, que o worker trata.
16. **Rolling update derruba requisição sem cooperação da aplicação**: SIGTERM
    chega antes de o kube-proxy parar de mandar conexões novas. A api espera
    `SHUTDOWN_DELAY` (0 por padrão; 2s no Deployment) antes de fechar o
    listener — o preStop com `sleep` não existe em imagem distroless.

## Ao mexer na stack

- Rode `make verify` antes de considerar qualquer coisa pronta. Para iterar
  rápido: `SKIP_SCAN=1 SKIP_OBS=1 make verify`. O estado bom conhecido é
  **30 passaram · 0 falharam**.
- O módulo Kubernetes tem portão próprio: `make k8s-verify` (estado bom:
  **33 passaram · 0 falharam**). Para iterar sem recriar o cluster:
  `KEEP_CLUSTER=1 make k8s-verify`. Os portões são independentes de propósito
  (ADR 0007) — mexeu em `k8s/`, rode os dois; o smoke test é compartilhado
  (`tools/scripts/lib/smoke.sh`), então mudanças nele afetam ambos.
- O `verify` separa "scanner quebrou" de "achou CVE" de propósito. Se você
  mexer no `scan.sh`, preserve essa distinção: reportar as duas coisas como a
  mesma falha faz o portão mentir (já aconteceu — o Trivy não alcançava o
  socket e o resultado saía como "vulnerabilidades encontradas").
- Mudou um Dockerfile? Os tamanhos em `site/src/data/measured.json` ficam
  desatualizados — o `verify` os regrava, mas o `sizes.sh` sozinho também.
- Adicionou uma lição? Escreva **as duas** versões, ou o build reprova.
- Toda imagem base é pinada por digest. Para atualizar: `make pins`, e depois
  `make verify`. Não edite digest à mão.
- Segredo **nunca** vai para `environment:`. A convenção é `<VAR>_FILE` apontando
  para `/run/secrets/`, implementada igual no `config.go` e no `config.py`.

## Qdrant

O `.mcp.json` **não é versionado** (aponta para um Qdrant em `localhost` e varia
por máquina). Num clone novo, recrie-o na raiz:

```json
{
  "mcpServers": {
    "qdrant-memory": {
      "type": "stdio",
      "command": "uvx",
      "args": ["mcp-server-qdrant"],
      "env": {
        "QDRANT_URL": "http://localhost:6333",
        "COLLECTION_NAME": "infra-knowlogy",
        "EMBEDDING_MODEL": "sentence-transformers/all-MiniLM-L6-v2"
      }
    }
  }
}
```

O
`make index` indexa **todo o conhecimento do repositório**, não só as lições:

| `kind` | Origem | Para quê |
|---|---|---|
| `lesson` | `site/src/content/lessons/**/*.mdx` | o material didático, nos dois idiomas |
| `adr` | `docs/adr/*.md` | decisões **e alternativas recusadas** |
| `convention` | `CLAUDE.md` | as armadilhas já encontradas |
| `overview` | `README.md` | arquitetura e o que o `verify` prova |
| `measurement` | `site/src/data/measured.json` | tamanhos medidos, virados em prosa |

O formato do ponto imita o do mcp-server-qdrant (vetor `fast-all-minilm-l6-v2`,
payload `{document, metadata}`) para que o MCP leia o que o script escreve.

Antes de gravar, o script apaga os pontos com `metadata.source == infra-knowlogy`
e regrava tudo. Assim, seção renomeada ou arquivo removido não deixa órfão — e
nada guardado na coleção por outra via é tocado.

**Use `qdrant-find` antes de reescrever qualquer coisa.** Perguntas como "por que
não usaram Traefik?" ou "qual o tamanho da imagem do worker?" já têm resposta
indexada, com o caminho do arquivo de origem no metadata.

## Os módulos e o roadmap

O repositório deixou de ser só o módulo Docker: `docs/ROADMAP.md` é a fonte de
verdade dos módulos (2 = Kubernetes em `k8s/`, feito nesta primeira versão;
3 = Jenkins/CI-CD em `cicd/`, reservado; depois IaC, Ansible, observabilidade
avançada). Regras para módulo novo estão lá — em resumo: mesma aplicação de
`stack/services/`, portão `make <módulo>-verify` próprio, lições bilíngues em
trilha nova, decisões em ADR, números medidos.

Trilha nova no site exige editar 5 pontos (enum em `content.config.ts`, labels
em `i18n/ui.ts`, array em `[lang]/index.astro`, mapa de badge em
`[slug].astro`, cor em `global.css`) — a trilha `kubernetes` serve de gabarito.

## O que ainda não existe

A **Trilha Produção** (12 lições: multi-stage nos três idiomas, BuildKit, escolha
de imagem base, PID 1 e sinais, hardening OWASP, segredos, rootless e Podman,
observabilidade, cadeia de suprimentos, CI/CD, limites do Compose, 12-Factor)
está planejada e não escrita. O código que ela vai explicar **já existe** na
stack — as lições é que faltam.

Na trilha Kubernetes, só as 3 primeiras lições existem; ficaram para depois:
Ingress de verdade (ingress-nginx), StatefulSets a fundo, HPA e o job de kind
no CI. Dois widgets também ficaram para depois: o grafo de topologia do Compose
e a demo de vazamento de segredo via `docker history`.
