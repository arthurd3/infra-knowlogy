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
17. **`deps.fetch(...)` quebra o `fetch` do navegador.** Chamado como método de
    um objeto, ele recebe `this === deps` e lança
    `Illegal invocation` — o `fetch` exige que o `this` seja a Window. Um fetch
    falso (teste, modo gravado) não se importa com o `this`, então o erro só
    aparece contra a stack de verdade. `gate.ts` e `lab.ts` guardam um alias
    local (`const call = deps.fetch`) por causa disso.
18. **Servidor de arquivos estático responde 404 com status 200.** O
    `try_files … /404.html` do Caddy devolve a página de erro com 200, então
    `res.ok` é verdadeiro para QUALQUER caminho. Por isso o probe do site exige
    `204` exato em `/edge-health` e JSON com `count` em `/api/links` — aceitar
    2xx anunciava "stack no ar" em cima de um site sem stack nenhuma.
19. **Ordem importa entre classes CSS de mesma especificidade.** `.btn-ghost` e
    `.btn--icon` mexem as duas em `padding`; com a ghost depois, o ícone do
    botão quadrado era espremido para 3px e sumia. A regra de tamanho da
    variante discreta fica ANTES de `.btn--icon` de propósito.
20. **Aba sem pintura não hidrata ilha `client:visible`.** Numa aba oculta
    (automação, aba em segundo plano) o `IntersectionObserver` não dispara e o
    widget fica no HTML servidor, inerte. Não é bug do site: ao tirar um
    screenshot — que força a pintura — a hidratação completa. Vale lembrar
    antes de sair caçando bug de hidratação que não existe.
21. **SVG do draw.io rasteriza o texto quando servido por `<img>`.** O export
    do draw.io — formato da maioria dos diagramas de documentação, o do
    Kubernetes incluído — não usa `<text>`: cada rótulo é um `<switch>` com um
    `<foreignObject>` de HTML e um `<image>` com um **PNG em base64** do rótulo.
    Inline no HTML o navegador usa o HTML; dentro de `<img src="…svg">` ele cai
    no PNG. Medido no diagrama de componentes do k8s: **254 KB, sendo 176 KB de
    PNG**, texto borrado e o renderizador do Chrome congelando ao pintar.
    `tools/scripts/flatten-drawio-svg.py` converte para `<text>` de verdade
    (80 KB, vetor). Ver ADR 0010.
22. **`label=disable` não é o único jeito de rodar engine de container
    aninhada sob SELinux** — e é o pior. O BuildKit rootless precisa dos três
    `unconfined` da documentação (`seccomp`, `apparmor`, `systempaths`) e,
    ainda assim, o `RUN` morre com `error mounting "proc" to rootfs ...
    permission denied`. O workaround colado de todo tutorial é
    `--security-opt label=disable`, que **desliga o confinamento**. O Fedora
    tem um tipo feito para isto: `--security-opt label=type:container_engine_t`
    mantém o SELinux enforcing E o processo confinado (o rótulo sai com
    categorias MCS, o que prova que não houve fallback). Medido:
    `make cicd-prereqs`. Ver ADR 0011.

## Ao mexer na stack

- Rode `make verify` antes de considerar qualquer coisa pronta. Para iterar
  rápido: `SKIP_SCAN=1 SKIP_OBS=1 make verify`. O estado bom conhecido é
  **32 passaram · 0 falharam** (25 + as 4 checagens do site + scan + obs; com
  os dois SKIP, **27 passaram**).
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
- Adicionou uma lição? Escreva **as duas** versões, ou o build reprova. E ela
  precisa de **pelo menos um diagrama ou widget** e de **pelo menos um
  exercício** (`Quiz` ou `LabExercise`): dois testes reprovam lição que nasce
  só com texto ou que não pergunta nada ao leitor.
- Mexeu no site? `make site-verify` é o ciclo rápido (tipos, testes, build,
  HTML) e não precisa de Docker. Ele é a etapa 8 do `verify`, sem o resto.
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

Trilha nova no site exige editar **3 pontos**, e não 5 como esta seção dizia
antes: `TRACKS` em `i18n/ui.ts` (que é a fonte única da lista e da ordem), o
enum em `content.config.ts` e a cor em `global.css` (três blocos de tema mais
`.badge--<trilha>`). A home, a página da lição e os testes derivam de `TRACKS`
— antes cada um repetia a lista à mão, e acrescentar uma trilha era caçar
literais. A trilha `cicd` serve de gabarito.

## O que ainda não existe

A **Trilha Produção** (12 lições: multi-stage nos três idiomas, BuildKit, escolha
de imagem base, PID 1 e sinais, hardening OWASP, segredos, rootless e Podman,
observabilidade, cadeia de suprimentos, CI/CD, limites do Compose, 12-Factor)
está planejada e não escrita. O código que ela vai explicar **já existe** na
stack — as lições é que faltam.

Na trilha Kubernetes, só as 3 primeiras lições existem; ficaram para depois:
Ingress de verdade (ingress-nginx), StatefulSets a fundo, HPA e o job de kind
no CI. Os dois widgets pendentes saíram: a topologia do Compose virou o
diagrama `StackTopology.astro` (lições 7 e 8) e a demo de vazamento de segredo
via `docker history` virou o `<LabExercise>` da lição 3.

A trilha `cicd` está cadastrada e **vazia**. A sonda do BuildKit rootless sob
SELinux — que era o risco número um do módulo 3 — **passou**: `make cicd-prereqs`
constrói sem daemon, sem privilégio e com o SELinux confinado, e o binário sai
byte a byte igual ao do `docker build` (ADR 0011). O que falta do módulo é o
Jenkins em si: `cicd/compose.yaml`, controller com JCasC e plugins pinados,
agente sem socket, `Jenkinsfile`, o portão `make cicd-verify` e as 8 lições.

## O site

A moldura visual tem convenções próprias, e todas elas têm teste.

**Botões.** Uma base `.btn` e três variantes (`--primary`, `--secondary`,
`--danger`), mais tamanhos (`--sm`, `--lg`, `--icon`). `.btn-ghost` é a variante
discreta e continua valendo como nome antigo. Não crie uma classe de botão nova:
o ponto do sistema é que a variante diz a **importância** da ação.

**Diagramas** (`site/src/components/diagrams/`, 15 deles). São SVG escritos à
mão, envolvidos por `Figure.astro`, que pintam **por classe** (`.dg-box`,
`.dg-line`, `.dg-fill-accent`…) e nunca por hex — é o que faz eles seguirem o
tema claro/escuro. O `site-check.mjs` reprova qualquer `fill="#…"` num SVG
publicado. O texto é bilíngue pelo mesmo padrão das ilhas (um objeto `C` com
`pt` e `en`), e o idioma sai da URL, não de uma prop.

**Ações ao vivo** (ADR 0008). `GateRunner` roda as 7 checagens do
`lib/smoke.sh` do próprio navegador; `LinkLab` encurta um link de verdade e
mostra o SSRF sendo recusado. Com `make up` eles falam com a stack (mesmo-origem
pelo edge); sem stack, reencenam `site/src/data/recorded-gate.json`, gravado por
`make record-gate`. A lógica mora em `site/src/lib/` — sem React, sem texto e
com o `fetch` entrando por parâmetro, que é o que a torna testável.

**Os primitivos didáticos** (ADR 0009). Além de `Callout`, `Figure` e `RunIt`,
a página da lição injeta quatro componentes — nenhum precisa de `import` no MDX,
e todos pegam o idioma da URL:

- **`Tradeoff`** — opção A × opção B, e o **critério** de quando cada uma ganha.
  `whenA`/`whenB` são obrigatórios: sem eles é tabela comparativa, não tradeoff.
- **`FieldNote`** — a afirmação **citada, não medida aqui**: postmortem, thread,
  blog de engenharia, palestra, escala. Borda tracejada (a contínua é do que foi
  medido), `source` e `url` obrigatórios, e o rodapé sempre diz "não medido
  aqui". A URL também tem que estar em `sources:`.
- **`Quiz`** — múltipla escolha. As perguntas ficam em
  `site/src/data/quizzes/<key>.json`, com `pt` e `en` no mesmo arquivo;
  `Quiz.astro` resolve o conjunto em tempo de build e só as perguntas daquele
  idioma atravessam para o cliente. **Toda alternativa explica por que está
  certa ou errada**, inclusive as erradas — é ali que está o ensino.
- **`LabExercise`** — a pergunta cuja resposta é um comando, com o gabarito num
  `<details>` e o nome da checagem do portão que a prova.

**Imagens** (ADR 0010). `Figure` aceita `src`/`credit`/`creditUrl`/`license` e
a prop `plate="light"` para diagrama de terceiro desenhado para fundo branco.
Sem licença apurada, redesenhe em SVG e use `redrawnFrom`. O slot `legend` é o
formato "figura anotada": lista numerada amarrando cada peça do desenho a algo
que este repositório mede.

**Testes** (`site/tests/`, 59 casos, `make site-test`). Cobrem a lógica do
portão, o fluxo do laboratório, a fidelidade da gravação, a paridade das chaves
de i18n e as invariantes do conteúdo bilíngue — inclusive a que os diagramas
tornaram necessária: **as duas versões de uma lição usam os mesmos
componentes**. Uma âncora de inserção escrita errado deixa a lição inglesa sem o
desenho e o build passa igual; só o teste reprova. Também reprovam: lição sem
exercício, `FieldNote` sem fonte, `Tradeoff` sem critério, e quiz cujo gabarito
está em posições diferentes nos dois idiomas.
