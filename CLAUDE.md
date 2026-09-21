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

23. **SELinux checa `connectto` de socket Unix contra o PROCESSO que escuta**,
    não contra o rótulo do arquivo. Por isso `ls -Z` mostra um
    `container_file_t:s0` perfeitamente acessível e o `connect()` falha com
    `permission denied` — que parece problema de dono e não é. Medido no
    agente falando com o buildkitd: `container_t` falha, `container_engine_t`
    passa. (Antes disso, cheque o óbvio: conectar num socket Unix exige
    permissão de ESCRITA, então `:ro` no volume também quebra.)
24. **`systempaths=unconfined` não aparece em `.HostConfig.SecurityOpt`.** O
    Docker o traduz em `MaskedPaths` e `ReadonlyPaths` vazios. Conferir pelo
    `SecurityOpt` faz parecer que o Compose engoliu a opção; a prova está nos
    outros dois campos.
25. **Prontidão de HTTP não é configuração aplicada.** O Jenkins responde
    `/login` com 200 e o header `X-Jenkins` ANTES de o JCasC terminar e de o
    seed do Job DSL rodar. Quem depende de job criado precisa esperar o job.
    A primeira versão do `cicd-verify` reprovava por corrida e parecia defeito.
26. **O `builtOn` de um build de Pipeline é string vazia** mesmo quando todos
    os estágios rodaram no agente — ele reporta o executor *flyweight*, que
    fica no controller. E flyweight NÃO conta para `numExecutors`: 0
    executores significa "nenhum BUILD roda aqui", não "nada roda aqui". Quem
    prova onde o trabalho aconteceu é a linha `Running on <nó>` do console.
27. **Prefira `[[:space:]]` a `\s` — mas pelo motivo certo.** Esta entrada dizia
    que "o ERE do `grep -E` não conhece `\s`, que casa a letra s", e que uma
    checagem de pin escrita assim reprovaria arquivos pinados. **Medido, não
    reproduz.** Contra os padrões reais do `cicd-verify` e do `iac-verify`, as
    duas formas dão resultado idêntico em GNU grep 3.12 (ERE **e** BRE), GNU
    awk, GNU sed e busybox awk — `\s` casa espaço em todos, e `FROMsss…` não
    casa em nenhum.
    O motivo real de preferir `[[:space:]]` é **portabilidade**: `\s` é extensão
    GNU/BusyBox e não está no ERE do POSIX. O conselho continua bom; a
    justificativa é que estava errada, e uma justificativa errada ensina a
    procurar o defeito no lugar errado.
28. **A diretiva `# hadolint ignore=` precisa ser a ÚLTIMA linha antes da
    instrução.** Com qualquer comentário entre as duas ela é ignorada em
    silêncio, e você acha que suprimiu.

29. **Com `pipefail`, `texto | grep -q PADRÃO` INVERTE o resultado quando o
    padrão aparece cedo.** O `grep -q` sai no primeiro acerto e fecha o pipe;
    quem escreve (`curl`, `printf`, `cat`) ainda tem dezenas de kB pela frente
    e morre de SIGPIPE; o `pipefail` propaga esse não-zero. **Achar vira "não
    achei".** O que esconde o defeito é que com entrada PEQUENA o escritor
    termina antes de o leitor sair, e o mesmo código funciona: no
    `cicd-verify` a checagem cujo padrão estava na linha 20 de 571 falhava, e a
    do padrão no fim do log passava. Use `case "$texto" in *PADRÃO*)` — sem
    pipe, sem sinal, sem depender de onde o padrão está.
30. **`: ` dentro de um escalar YAML não citado encerra o escalar.** Um
    `summary:` de lição com "demonstrada aqui: a mesma entrada" derruba a
    sincronização da coleção com `bad indentation of a mapping entry` e uma
    linha:coluna que aponta para o meio da frase, não para a causa. Vale para
    `title:` também. Cite a string, ou não use dois-pontos seguidos de espaço.
31. **`docker run` sem `-i` descarta o heredoc em silêncio.** O `psql` recebe
    EOF imediato, sai com 0 e não imprime nada — e a checagem que lê a saída
    vira "pulado" em vez de falhar. Só acontece com stdin; `docker run … psql
    -c 'SELECT 1'` funciona sem `-i`, o que esconde o problema. Foi o que fez
    a demonstração de injeção do `attack-lab` nascer muda.
32. **Uma porta ocupada no seu loopback pode não ser da stack que você está
    testando.** O passo 2 do `attack-lab` reprovou dizendo que a 5432 estava
    publicada; era um Postgres de OUTRO projeto, esquecido rodando na máquina.
    Portão que acusa sem **atribuir** o socket produz alarme falso e, pior,
    ensina a ignorar o alarme. O script cruza com `docker compose ps` antes de
    culpar a stack — e o nome do container alheio fica no terminal de quem
    roda, nunca no JSON versionado, que é público.

33. **`container_engine_t` NÃO resolve o socket do Docker** — só o do buildkitd.
    A armadilha 22 achou o tipo certo para engine aninhada e a conclusão
    natural ("use para qualquer socket de engine") está errada: pela armadilha
    23, o SELinux checa `connectto` contra o PROCESSO QUE ESCUTA, e o `dockerd`
    escuta como `container_runtime_t`, não como container. Medido:
    `container_t` ✗, `container_engine_t` ✗, `spc_t` ✓. A armadilha 7 continua
    de pé; ela só estava incompleta.
34. **`label=disable` não desliga o SELinux: ele entrega `spc_t` SEM MCS.** O
    workaround de todo tutorial e o pedido explícito `label=type:spc_t` dão o
    MESMO tipo — a diferença são as categorias. Medido:
    `label=disable` → `spc_t:s0`; `label=type:spc_t` → `spc_t:s0:c55,c466`.
    MCS é o que impede um container de tocar em arquivo rotulado de OUTRO
    container. Existe opção estritamente melhor que o `disable`, e ela custa
    digitar outra palavra. (O `compose.obs.yaml` ainda usa `label=disable` em
    dois serviços — vale medir se `spc_t` os atende.)
35. **`spc_t` lê `user_home_t`, e isso dispensa o `:z`.** Medido: `container_t`
    leva permission denied em `site/package.json`; `spc_t` lê. Montar o
    repositório inteiro com `:z` faria um `chcon -R` em `.git` e
    `node_modules` — desnecessário sob `spc_t`.
36. **Três camadas independentes para um container alcançar o socket do
    Docker**, e errar qualquer uma dá erro que aponta para as outras: tipo
    SELinux (`spc_t`), grupo Unix (`--group-add` com o gid LIDO do socket) e
    dono dos arquivos (`--user`, senão o `tfstate` nasce do root). E o buildx,
    que o provider chama, quer `$HOME/.docker`: sem `HOME`, o erro é
    `mkdir /.docker: permission denied`, que não menciona buildx.
37. **`command -v` acha FUNÇÃO de shell, não só binário.** O `lib/tofu.sh`
    define uma função `tofu` e usava `command -v tofu` para decidir se havia
    binário no host — respondendo "sim" numa máquina sem OpenTofu instalado.
    Use `type -P`, que só olha o PATH.
38. **O Docker 29 normaliza capability para `CAP_CHOWN`.** Escrita como
    `CHOWN` no HCL, o provider lê de volta um valor diferente do que escreveu e
    TODO `plan` seguinte pede `replace` — para sempre. Só os containers com
    `capabilities.add` entram na conta; os que só têm `drop: [ALL]` ficam
    estáveis, o que manda procurar no lugar errado. Da mesma família:
    `memory_swap`, que o daemon preenche com `2 × memory` se você não declarar.
    **Atributo não declarado não é atributo sem valor.**
39. **O `.terraform.lock.hcl` guarda DUAS famílias de hash e uma basta.**
    Adulterar todas as entradas `h1:` e rodar `tofu init`… passa, porque as
    `zh:` ainda batem. A primeira versão da prova negativa do `iac-verify`
    nasceu assim: anunciava "o pin protege" tendo testado metade. Teste
    negativo que passa sem provar nada é pior que teste nenhum.
40. **Caminho de bind mount é resolvido pelo DAEMON; contexto de build, pelo
    processo.** Com o `tofu` conteinerizado existem dois sistemas de arquivos
    na mesma configuração: `/repo/…` para o que o tofu lê, caminho do host para
    o que o daemon abre. Daí a variável `host_repo_root`. Rodando o `tofu` no
    host os dois coincidem — e é por isso que o erro só aparece na outra via.

41. **Prop errada num componente MDX não quebra nada — some calada.** O `Term`
    recebe `word`; escrever `term=` (que é o nome óbvio) faz o Astro aceitar a
    prop desconhecida, o componente receber `undefined` e o `<summary>` sair com
    o rótulo "conceito" e NENHUMA palavra. Aconteceu em **12 blocos** da trilha
    IaC e passou por `astro check` (prop de MDX não é tipada), pelos testes de
    conteúdo (que contavam o componente, não a prop) e pelo `site-check` (o
    elemento existe no HTML — só vazio). Hoje há guarda nos dois níveis: o teste
    olha a prop no MDX, o `site-check` olha se a palavra sobreviveu à
    renderização. Ao criar componente didático novo, pergunte o que acontece se
    a prop obrigatória faltar.

    **Aconteceu de novo, em escala.** O `LabExercise` recebe a pergunta pelo
    CORPO; 34 exercícios (17 lições ×2 idiomas — toda a trilha `operacao`, o
    módulo Kubernetes, `obs-08` e `cicd-09`) a passavam por uma prop
    `question=` que o componente não declara. Medido no HTML publicado:
    `lab__question` com **0 caracteres** de texto. Passou por tudo — inclusive
    pela checagem "as lições saem com quiz ou exercício", que via o elemento
    existir. Hoje o `site-check` exige **20 caracteres de texto renderizado**
    dentro do exercício. A lição da lição: quando uma prop sumir em silêncio
    uma vez, procure onde mais a mesma forma foi copiada.

42. **O denominador de um SLI tem um piso constante, e é aí que ele nasce
    errado.** A razão infraestrutura/usuário oscila com a carga e por isso é
    ruim como afirmação; o piso não oscila e é derivável: healthcheck a cada 10s
    em duas rotas (12/min) mais scrape a cada 15s (4/min) = **16 requisições por
    minuto com zero usuários**, medido. Serviço abaixo desse volume tem o SLI
    dominado pelo próprio monitoramento — uma queda TOTAL apareceria como 96% de
    sucesso. Daí o `route!~` no `slo.yml`. Ao citar número medido numa lição,
    prefira a grandeza ESTÁVEL: a que oscila envelhece a cada execução do portão.
43. **Alerta de burn rate não some quando você conserta.** Ele some quando a
    janela escoa. Com o banco de volta e a api respondendo 201, o alerta ficou
    `firing` até a janela de 5 min esvaziar. É correto, e é a informação que
    ninguém tem antes do primeiro incidente — alerta vermelho depois do conserto
    faz metade da sala achar que o problema voltou.
44. **`0/0` em PromQL é NaN, e série com NaN SOME.** Num painel é uma lacuna no
    gráfico; num alerta, a comparação com série ausente não é verdadeira nem
    falsa — o alerta deixa de existir, calado. Daí o `or vector(0)` em toda razão
    do `slo.yml`. Morde de madrugada, com pouco tráfego, que é exatamente quando
    ninguém está olhando o painel.
45. **O endpoint de valores de rótulo do Loki responde pelo período do ÍNDICE**
    (24h aqui), não pela janela que você pediu. Um rótulo que você parou de
    emitir continua listado pelo resto do dia — o que fez uma correção de
    normalização parecer não ter funcionado. Quem prova é consultar as LINHAS e
    olhar os rótulos delas.
46. **Rótulo de nível de log vira três grafias sem ninguém notar.** Medido:
    `ERROR INFO error info warn warning`, porque Go, Python e Caddy escrevem
    cada um do seu jeito e o `stage.labels` guarda o que vier. `{level="error"}`
    não casa `ERROR` — a consulta funciona, devolve resultado e o resultado está
    incompleto. Corrigido com `stage.template` + `ToLower`; `warn` × `warning`
    continua declarado como limite.

47. **`\"` NÃO é escape válido em atributo de componente MDX.** Ele funciona no
    frontmatter YAML e dentro de bloco de código, e por isso parece que
    funciona em todo lugar. Num `whenA="… \"assim\" …"` a string termina na
    primeira aspa e o build falha com *"Unexpected character after `<`, expected
    a valid JSX tag"* — apontando para a LINHA DO COMPONENTE, não para o escape.
    Use aspas tipográficas (`“ ”`) no texto do atributo.

48. **A NetworkPolicy NÃO vale no instante em que o pod nasce.** A
    `default-deny` seleciona todos os pods do namespace com
    `policyTypes: [Ingress, Egress]` e, ainda assim, um pod recém-criado
    alcança a internet por um átimo: as regras de dataplane são programadas
    DEPOIS de o container começar a rodar, porque o agente de rede reage a um
    evento que já aconteceu. Medido neste kind, em várias execuções: janelas
    de **33 ms a 479 ms**. Duas consequências, e as duas importam. Segurança:
    defesa em profundidade (o guard de SSRF na aplicação, segredo que não está
    na imagem) é o que cobre esse intervalo — policy não cobre. E portão: uma
    sonda rápida PASSA por causa da corrida e some numa máquina mais lenta;
    por isso o `rbac-probe` declara o egresso de que precisa em vez de
    depender da janela. O `k8s-verify` mede a janela e exige que ela exista
    **e** feche — as duas metades detectam regressões diferentes.
49. **HPA sem `requests.cpu` fica em `<unknown>` para sempre, e não reclama.**
    Utilização de HPA é percentual **do request**, nunca do limit. A api tinha
    `limits.cpu` e nenhum request — o objeto sobe, o `get hpa` mostra
    `cpu: <unknown>/60%`, nada escala e nenhum evento diz por quê. Foi preciso
    acrescentar `requests: {cpu: 50m}` ao Deployment para o HPA funcionar.
50. **`valor or ''` em Python engole o zero.** `0.0` é falsy, então
    `d.get('campo') or ''` devolve string vazia para uma medição perfeitamente
    válida de zero. No `k8s-verify` isso reprovou uma checagem que tinha o
    número CERTO na mão. Use `v = d.get(...); '' if v is None else v`.
51. **`.status.replicas` do Deployment ATRASA em relação ao pod existir**, e
    os carimbos do Kubernetes têm resolução de **1 segundo**. Medir "quanto o
    pod levou para subir" por diferença de dois instantes de um laço de
    polling deu `0.0s` — errado. O tempo honesto vem dos carimbos do próprio
    pod (`creationTimestamp` → condição `Ready`), e mesmo assim só distingue
    segundos inteiros: a api (Go, distroless, imagem já no nó) sobe em 1 s ou
    menos, que é o piso do que o Kubernetes consegue reportar.
52. **Uso de CPU é uma TAXA, e taxa não sai de uma amostra** — é o termo que
    falta na conta de quase todo mundo. O tempo de reação do HPA tem TRÊS
    parcelas, não duas: `2 × --metric-resolution` (o metrics-server calcula o
    valor pela diferença entre as duas últimas raspagens, então uma mudança
    degrau leva duas janelas para estar inteiramente refletida) mais
    `1 × sync-period do HPA`. Com os padrões de 15 s: **45 s**, não 30. A
    checagem do portão nasceu com 30 s, reprovou contra uma medição de
    **44,7 s**, e o errado era o limite. Medido também: a janela cega
    (12,8–44,7 s) domina o boot do pod (1 s) por mais de uma ordem de
    grandeza — otimizar a imagem não compra reação de autoscaling.
53. **Medição de HPA precisa de linha de base FRIA, não só de métrica
    disponível.** Rodadas seguidas começavam com 136% e 96% de utilização
    herdados da carga anterior, e o "t=0" deixava de ser o instante em que a
    carga chegou: o HPA já tinha visto CPU alta antes do teste. Isso produziu
    uma medição de 53 s, **acima do limite teórico** — número impossível que
    só existia por causa da contaminação. O `zerar()` apaga o HPA (com ele de
    pé, `scale --replicas=2` é desfeito no ciclo seguinte), volta à base e
    espera a utilização cair abaixo de 30%.

54. **`ReadWriteOnce` é por NÓ, não por pod** — e num cluster de um nó você
    nunca descobre. Medido aqui: o `cache` é um Deployment com PVC RWO;
    escalado para 2, os **dois pods subiram Running no mesmo nó montando o
    mesmo volume**, sem evento, sem aviso. O modo diz "um nó pode montar em
    escrita", e dois pods do mesmo nó compartilham essa montagem. Quem
    aprendeu "RWO = um pod só" descobre o contrário em produção, no dia em que
    o segundo pod cai noutro nó e fica `Pending` em
    `Multi-Attach error`. Existe `ReadWriteOncePod` desde o 1.27 para o que as
    pessoas achavam que o RWO fazia.
55. **`kubectl exec … psql -U <errado>` falha por SENHA e parece falta de
    dado.** O erro é `fe_sendauth: no password supplied` e a saída do `SELECT`
    vem vazia — então uma checagem que lê a saída conclui "o dado não
    sobreviveu" quando o que não aconteceu foi a conexão. O usuário deste
    Postgres é `links` (de `POSTGRES_USER`), não `app`, e a senha sai de
    `/run/secrets/postgres_password`. Primo da armadilha 31: comando que sai
    calado vira conclusão errada.

56. **O `k8s-verify` NÃO chama o `k8s-up.sh`** — ele cria o próprio cluster e
    aplica os manifests direto. Um addon ligado só ao `k8s-up.sh` (foi o caso
    do metrics-server) existe no seu cluster de trabalho e **não existe no
    portão**. O que esconde isso é o `KEEP_CLUSTER=1`: toda iteração rápida
    reaproveita o cluster que você montou à mão, e a falha só aparece na
    primeira execução do zero. Addon novo entra nos **dois**.
57. **`bad "falta A ou B"` é uma mensagem que manda o leitor investigar duas
    coisas.** A checagem do HPA dizia "falta metrics-server ou requests.cpu" e
    a causa real — a API de métricas nem estava servindo — só apareceu com um
    `kubectl top pod` à mão. Quando duas causas produzem o mesmo sintoma,
    **espere e reporte as duas separadamente**; o portão fica mais lento e para
    de fazer você adivinhar.
58. **`pkill -f <padrão>` mata o shell que o executa** se o padrão aparecer na
    própria linha de comando dele — e aparece, porque o comando que você
    escreveu contém o padrão. O shell morre com código 144 e a sessão perde o
    resto do script. Use `pgrep -af` para conferir antes, ou restrinja com
    `pkill -f -- "-x nome-exato"`.

59. **Substituição de texto que não casa falha em SILÊNCIO** — e num script de
    edição isso é pior do que um erro, porque o script segue e imprime
    "pronto". Aconteceu quatro vezes num dia só: um `replace` de bloco do
    `k8s-verify` que errou por um espaço deixou a checagem versionada sem o
    portão que a chama; outro deixou as medições novas fora do JSON com os
    valores certos na mão; um terceiro errou o recuo de um objeto de i18n por
    dois espaços. **Toda edição programática precisa de `assert` da âncora
    ANTES e de conferência do resultado DEPOIS.**

60. **O `kind:` de `sources:` numa lição e o `kind` da `library.json` são
    vocabulários DIFERENTES.** A lição aceita
    `spec|docs|blog|thread|postmortem|talk|book`; a biblioteca aceita esses
    mais `zine`, `video` e **`article`**. Escrever `kind: article` no
    frontmatter de uma lição derruba o build com
    `InvalidContentEntryDataError`, e a mensagem não diz qual campo. Para
    artigo de veículo editorial (LWN, por exemplo), use `blog` na lição.

61. **`volumeClaimTemplate` sem `apiVersion`/`kind` deixa o ArgoCD
    permanentemente OutOfSync.** O API server preenche
    `apiVersion: v1` e `kind: PersistentVolumeClaim` dentro de cada entrada ao
    aceitar o objeto; o manifesto não os tinha. O ArgoCD aplica, o servidor
    completa, e a diferença reaparece no ciclo seguinte — **duas linhas** que
    fazem um recurso nunca sincronizar, e recurso que nunca sincroniza treina
    a equipe a ignorar o painel inteiro. A correção é declarar os campos, não
    um `ignoreDifferences`: o manifesto passa a descrever o objeto como ele é.
    (E quando o diff não fecha, pergunte ao ArgoCD:
    `/api/v1/applications/<app>/managed-resources` traz `normalizedLiveState`
    e `predictedLiveState`, que é o que ele de fato compara. Duas tentativas de
    adivinhar aqui custaram meia hora.)
62. **O `selfHeal` do ArgoCD tem recuo exponencial, e ele contamina medição.**
    A primeira correção depois de uma sincronização limpa levou **0,34 s**;
    provocando de seguida, 11 s e 48 s; sob provocação contínua, um platô de
    **~96 s**; e uma pausa de 90 s NÃO zerou o contador (voltou em 26 s). O
    recuo é de propósito — um controlador em laço de briga martelaria o API
    server. Mesma família da armadilha 53: reconciliação se mede com linha de
    base FRIA, e o portão afirma que DESFAZ, nunca em quanto tempo.

63. **O Linkerd EXIGE os CRDs da Gateway API**, e a mensagem de erro fala de
    Gateway API — não de Linkerd. O `linkerd check --pre` reprova mandando
    aplicar `standard-install.yaml` do `gateway-api`, o que parece um problema
    de outro componente. Ele os usa para HTTPRoute. O `k8s-mesh-install.sh`
    instala o Envoy Gateway antes se os CRDs faltarem.
64. **`linkerd install` GERA uma PKI nova a cada execução.** Reaplicar num
    cluster que já tem o plano de controle troca a âncora de confiança, e todo
    proxy já injetado passa a apresentar certificado que o novo emissor não
    reconhece — a malha quebra **em silêncio, pod a pod**, conforme eles
    reiniciam. Um instalador idempotente precisa checar se o
    `linkerd-identity` existe antes. (E o `linkerd check --pre` é para cluster
    LIMPO: com o Linkerd instalado ele reprova dizendo que o namespace já
    existe, fazendo um script correto parecer quebrado.)

60. **O `.State.OOMKilled` do Docker diz `false` num OOM de verdade.** Medido
    neste host, com o alocador como PID 1: saída **137** (128+9, o SIGKILL que
    só o kernel manda) e `memory.events` do cgroup com `oom 1`, `oom_kill 1`,
    `max 324`. Três fontes concordam e só a flag discorda. O portão nasceu
    exigindo `OOMKilled=true` e **reprovou contra um OOM real**; a correção não
    foi afrouxar a checagem, foi trocar a fonte — hoje ele lê `memory.events`
    de DENTRO do cgroup (antes de o container sumir) e reporta a flag só como
    informação. A lição publicada também afirmava `true 137`: estava errada e
    foi corrigida, junto com o diagrama e dois quizzes. **Quando duas fontes
    discordam, prefira a que escreveu o fato, não a que o observou.**
61. **`OTEL_EXPORTER_OTLP_ENDPOINT` tem duas regras de parsing.** O SDK Go
    aceita `host:port`; o módulo do Caddy exige **URL com esquema** e, sem ele,
    monta `https:///v1/traces` e falha com `no Host in request URL`. O modo de
    falhar é o pior: **a instrumentação funciona** — o `traceID` aparece no
    access log, os spans nascem certos, e só a exportação morre. Quem olha o
    log vê tracing funcionando e nenhum span no coletor.
62. **OTLP/gRPC reenfileira; OTLP/HTTP descarta.** Com o coletor recém
    reiniciado, a api e o worker (gRPC) reenviam e o edge (HTTP) **perde o
    lote** — e só o edge some do trace, o que faz parecer erro de configuração
    dele. A medição parava o coletor para truncar o arquivo; hoje ela só
    **marca o deslocamento em bytes** e lê do ponto em diante. Não reiniciar
    saiu mais barato E mais correto.
63. **Esperar por um proxy do que se vai afirmar é corrida disfarçada.** A
    medição aguardava "dois traces existirem" e depois afirmava "três
    serviços" — coisas diferentes, porque os spans do edge chegam por outro
    caminho e atrasam. Passava na bancada e reprovava dentro do `make verify`.
    Primo da armadilha 48: **espere exatamente pela condição que a checagem
    declara.**
64. **`docker compose up` com um conjunto de arquivos DIFERENTE recria os
    serviços** — ele vê configuração diferente e desfaz o overlay que outro
    passo acabou de montar. O passo 10 do `verify` subia com `PROD` depois de o
    passo 9 ter subido com `OBS`, e o edge terminava todo `make verify` sem
    `OTEL_EXPORTER_OTLP_ENDPOINT`. Dentro do portão passava (a ordem salva);
    quem medisse à mão logo depois via o edge "mal configurado".
65. **Referência de comparação que se auto-invalida não falha: mente.** O custo
    do tracing é medido contra uma imagem sem OTel — e o `sizes.sh` reconstrói
    as tags de referência, que depois da instrumentação passam a TER OTel.
    Comparar instrumentado com instrumentado dá delta zero, e a lição anunciaria
    com número medido que observabilidade é de graça. Por isso a referência só
    vale com **zero ocorrências de `go.opentelemetry.io` no binário**; sem
    referência válida o script preserva o valor antigo e marca
    `referencia_valida: false`.

## Ao mexer na stack

- Rode `make verify` antes de considerar qualquer coisa pronta. Para iterar
  rápido: `SKIP_SCAN=1 SKIP_OBS=1 make verify`. O estado bom conhecido é
  **65 passaram · 0 falharam · 1 pulada** com `SKIP_SCAN=1`. O passo 7 (Trivy)
  continua com CVEs HIGH de `curl` no Alpine da imagem `web`, com correção
  disponível (`make pins`). O passo 9 cresceu três vezes: as regras de SLO
  (ADR 0018), o Alertmanager, e o **tracing ponta a ponta** — 6 checagens que
  provam um `trace_id` atravessando edge → api → fila do Redis → worker, mais o
  custo medido contra referência sem OTel. O passo 10 acrescentou 8 de operação
  (ADR 0022); `SKIP_OPS=1` pula estas, que precisam da stack no ar.
- O profile `obs` deixou de ser só infraestrutura: `rules/slo.yml` tem 7 regras
  de gravação e 3 de alerta que o Prometheus carrega de verdade, e o portão
  prova que elas avaliam, que o SLI tem valor e que o relabel do cAdvisor ainda
  corta. `python3 tools/scripts/obs-measure.py` regrava
  `site/src/data/obs-measured.json`, que as lições e os diagramas citam.
- As lições de **scripting** medem o próprio ferramental, e as duas medições não
  precisam da stack: `bash-traps-measure.py` regrava `bash-measured.json` (a
  corrida do SIGPIPE em 40 execuções por tamanho, o `local` mascarando o código
  de saída) e `languages-measure.py` regrava `languages-measured.json` (memória
  em repouso das três linguagens, os três locks, e a fixture do typo em ramo
  morto). As duas entram no **passo 1** do `verify`, de propósito: uma lição
  sobre escrever script não deveria depender da infraestrutura que o script
  gerencia.
- A fixture `tools/scripts/fixtures/typo-no-ramo-morto/` tem um `.go` que **não
  compila de propósito**. Ela está fora do módulo Go (`stack/services/api-go/`)
  e nenhum portão a varre — mas vale saber disso antes de rodar `go build ./...`
  na raiz e achar que quebrou alguma coisa.
- O tracing é a outra metade: `python3 tools/scripts/tracing-measure.py` regrava
  `site/src/data/tracing-measured.json`, e o diagrama `TraceAcrossQueue.astro`
  o lê **em tempo de build** — nenhum milissegundo da lição é escrito à mão. Ele
  não reinicia serviço nenhum (armadilha 62): marca o deslocamento do arquivo de
  traces e lê do ponto em diante.
- A trilha **Operação** é transversal como a de Segurança: ela não porta a stack
  para lugar nenhum, mede a que já existe. As checagens são o passo 10 do
  `verify`, e `python3 tools/scripts/ops-measure.py` regrava
  `site/src/data/ops-measured.json` (com `SKIP_PSI=1` para pular a carga de
  CPU, que leva ~1,5 min). O `db` ganhou `shared_preload_libraries` e
  `effective_cache_size` no `command:` do compose — mexer ali exige recriar
  o container, não só reiniciar.
- O módulo CI/CD também: `make cicd-verify` (estado bom: **35 passaram ·
  0 falharam**). Para iterar sem reconstruir tudo:
  `KEEP_JENKINS=1 SKIP_BUILD=1 SKIP_NEGATIVE=1 make cicd-verify`. Antes de
  qualquer coisa nele, `make cicd-prereqs` — a sonda que prova que este host
  constrói imagem sem daemon.
- A trilha de Segurança tem portão próprio e **invertido**: `make attack-lab`
  dispara 11 ataques contra a stack local e cada checagem passa quando o ataque
  FALHA (estado bom: **10 repelidos · 0 funcionaram**; o passo 6 vaza de
  propósito, é a demonstração de injeção de SQL da lição 5). Ele regrava
  `site/src/data/attack-lab.json`, que as lições citam — número de lição de
  segurança escrito à mão, nenhum. `KEEP_JSON=1` para não regravar. Ver ADR 0013.
- O módulo IaC também: `make iac-verify` (estado bom: **28 passaram ·
  0 falharam**). Para iterar sem destruir no fim: `KEEP_STACK=1 make iac-verify`;
  `SKIP_NEGATIVE=1` pula a prova do lock adulterado, que reinstala o provider.
  Antes de qualquer coisa nele, `make iac-prereqs` — a sonda que descobre como o
  `tofu` alcança o daemon sob SELinux (ver ADR 0016 e as armadilhas 33–36).
  A stack dele atende em **8082**, ao lado do Compose (8080) e do kind (8081).
- O módulo Kubernetes tem portão próprio: `make k8s-verify` (estado bom:
  **65 passaram · 0 falharam**). Para pular as partes caras:
  `SKIP_HPA=1` (a medição de carga real, ~6 min) e `SKIP_GATEWAY=1` (baixa
  ~4 MB de CRDs e sobe o Envoy Gateway). Para iterar sem recriar o cluster:
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
  `make verify`. Não edite digest à mão. **O `update-pins.sh` precisa conhecer
  todo arquivo que carrega digest** — hoje são 19, e o módulo 4 acrescentou
  dois (`iac/variables.tf`, porque o provider Docker quer a referência como
  string, e `tools/scripts/lib/tofu.sh`, pela imagem do OpenTofu). Esquecer de
  acrescentar um arquivo à lista não dá erro: o `make pins` atualiza o resto e
  deixa aquele para trás, em silêncio.
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
| `port` | `site/src/data/ports.json` | o mecanismo de cada ataque, por porta |
| `attack` | `site/src/data/attack-lab.json` | o resultado de cada ataque do portão |
| `skill` | `site/src/data/skills.json` | o que o mercado pede × o que daqui prova |

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
verdade dos módulos (2 = Kubernetes em `k8s/`; 3 = Jenkins/CI-CD em `cicd/`;
4 = IaC com OpenTofu em `iac/` — os três feitos em primeira versão; depois
Ansible e observabilidade avançada, reservados). Regras para módulo novo estão lá — em resumo: mesma aplicação de
`stack/services/`, portão `make <módulo>-verify` próprio, lições bilíngues em
trilha nova, decisões em ADR, números medidos.

O mapa de mercado (`site/src/data/skills.json`, ADR 0014) é o par medido do
roadmap: ele cruza o que 40 vagas pediam com o que este repositório prova, e
`site/tests/skills.test.ts` reprova quem se declarar coberto apontando para
lição inexistente ou checagem de portão que ninguém escreveu. **Se você
renomear uma checagem de um `*-verify.sh`, o teste quebra** — de propósito:
quem renomeou é obrigado a olhar o mapa.

Ele tem **quatro** estados, e o quarto é o que torna "100%" alcançável sem
mentir (ADR 0020). `citado` é para o que NÃO DÁ para medir aqui — EKS/GKE,
Datadog, New Relic, Dynatrace, FinOps exigem conta, licença ou fatura. Duas
regras o mantêm honesto: ele **exige** lição bilíngue com `FieldNote`, e
**proíbe** checagem de portão. Se dá para checar, é `coberto` — e deixar os dois
conviverem faria de `citado` um refúgio para não escrever a checagem difícil.

Os cinco itens continuam em `ausente` até a lição que os ensina existir. O
estado é mecanismo, não anistia.

Trilha nova no site exige editar **3 pontos**, e não 5 como esta seção dizia
antes: `TRACKS` em `i18n/ui.ts` (que é a fonte única da lista e da ordem), o
enum em `content.config.ts` e a cor em `global.css` (três blocos de tema mais
`.badge--<trilha>`). A home, a página da lição, a **nav do `Base.astro`** e os
testes derivam de `TRACKS` — antes cada um repetia a lista à mão, e acrescentar
uma trilha era caçar literais. A nav foi a última a ceder: ela tinha dois links
escritos à mão e a trilha de Segurança nasceu **invisível na barra** com seis
lições publicadas. Hoje ela lista as trilhas que TÊM lição naquele idioma —
trilha cadastrada e vazia continua fora, porque mandar o leitor para uma âncora
sem conteúdo é pior do que não oferecer o link. As trilhas `cicd` (vazia) e
`seguranca` (cheia) servem de gabarito para os dois casos.

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

A **Trilha Segurança** existe e está completa em primeira versão: 6 lições
bilíngues (`sec-01`…`sec-06`), 5 diagramas, o widget `PortExplorer` sobre
`site/src/data/ports.json` (14 portas — as 8 do cartaz que originou a trilha
mais as 6 de banco de dados que ele não tem) e o portão `make attack-lab`. Ela
é **transversal**, e não um módulo numerado: não porta a stack para lugar
nenhum, ataca a que já existe. Ficou para depois: força bruta com taxa medida
(hoje o passo 4 só prova a recusa) e o espelho do laboratório contra o cluster
kind — as NetworkPolicies dizem a mesma coisa que as redes do Compose e ninguém
tentou atravessá-las ainda.

O módulo 4 (`iac/`) está **de pé, verde e com as 8 lições escritas**: a mesma
stack em HCL, provisionada pelo OpenTofu 1.12.3 com o provider
`kreuzwerker/docker` 4.6.0 contra o daemon local, em **8082**. O portão prova
idempotência, drift, as duas arestas do grafo, o pin por hash (com prova
negativa) e a cifragem de estado. Faltam: backend remoto com lock de verdade, e
provisionar o cluster kind pelo próprio OpenTofu.

O módulo 3 (`cicd/`) está **de pé e verde**: controller com JCasC e 67 plugins
pinados, buildkitd rootless, agente sem socket, `git daemon` servindo o
repositório, registry local, pipeline lint → build → archive e o portão
`make cicd-verify` (**35 passaram · 0 falharam**). Faltam **as 8 lições** da
trilha `cicd`, que está cadastrada e vazia, e dois estágios no pipeline: `scan`
com Trivy e `sign` com cosign.

## O site

A moldura visual tem convenções próprias, e todas elas têm teste.

**Botões.** Uma base `.btn` e três variantes (`--primary`, `--secondary`,
`--danger`), mais tamanhos (`--sm`, `--lg`, `--icon`). `.btn-ghost` é a variante
discreta e continua valendo como nome antigo. Não crie uma classe de botão nova:
o ponto do sistema é que a variante diz a **importância** da ação.

**Diagramas** (`site/src/components/diagrams/`, 20 deles). São SVG escritos à
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
a página da lição injeta cinco componentes — nenhum precisa de `import` no MDX,
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
- **`Term`** — o conceito aberto ali mesmo, para quem não é da área. É um
  `<details>` de bloco (e não um balão em linha) porque a definição pode ter
  parágrafo, lista e código, e porque `<details>` funciona sem JavaScript — o
  que mantém a lição legível numa aba que nunca pintou (armadilha 20). A prop
  `alt` carrega o nome em inglês: traduzir "pass-the-hash" e esconder o
  original deixa o leitor sem o termo de busca. O teste conta `<Term>` nos dois
  idiomas: um a mais em pt é um conceito que o leitor inglês ficou sem.

**A trilha de estudo** (ADR 0017). `site/src/data/library.json` é a camada que
o `sources:` **não** é: as fontes de uma lição são o que foi usado para
escrevê-la; a biblioteca é para onde ir depois, indexada por **conceito**
(porque conceito atravessa lição). O `Deeper.astro` é injetado pela página e
resolve sozinho pela `key` — MDX nenhum importa nada, e lição sem conceito
mapeado não renderiza bloco algum.

Três regras editoriais, em `library.test.ts`: **toda referência diz por que ELA**
(mínimo de 120 caracteres, nos dois idiomas), **todo conceito tem ao menos uma
opção gratuita** (bibliografia só de livro pago exclui quem mais precisa) e
**todo conceito tem ao menos uma indicação audiovisual**. Mais: livro com ISBN
ou link de editora, vídeo apontando para o YouTube, e toda lição de Fundamentos
coberta por algum conceito.

Hoje são **36 conceitos** e **142 referências**, e **toda lição do repositório
tem trilha de estudo** — a checagem é um laço sobre as chaves das lições contra
`concepts[].lessons`. Os 43 links audiovisuais foram
conferidos pelo título que o YouTube devolve, não pelo status HTTP: id inventado
responde 200 com página de erro.

**Referência nunca entra sem ser conferida.** ISBN ou link de YouTube inventado
envenena a credibilidade que o resto do repositório constrói; o campo `accessed`
registra a data da checagem. Quando não achei vídeo confiável para um conceito,
reusei palestra verificada que de fato o cobre — e a justificativa diz o que ela
entrega ali.

**Imagens** (ADR 0010). `Figure` aceita `src`/`credit`/`creditUrl`/`license` e
a prop `plate="light"` para diagrama de terceiro desenhado para fundo branco.
Sem licença apurada, redesenhe em SVG e use `redrawnFrom`. O slot `legend` é o
formato "figura anotada": lista numerada amarrando cada peça do desenho a algo
que este repositório mede.

**Testes** (`site/tests/`, 97 casos, `make site-test`). Cobrem a lógica do
portão, o fluxo do laboratório, a fidelidade da gravação, a paridade das chaves
de i18n e as invariantes do conteúdo bilíngue — inclusive a que os diagramas
tornaram necessária: **as duas versões de uma lição usam os mesmos
componentes**. Uma âncora de inserção escrita errado deixa a lição inglesa sem o
desenho e o build passa igual; só o teste reprova. Também reprovam: lição sem
exercício, `FieldNote` sem fonte, `Tradeoff` sem critério, e quiz cujo gabarito
está em posições diferentes nos dois idiomas. O `ports.test.ts` guarda as duas
regras editoriais do cartaz de portas: **todo ataque explica o mecanismo**
(`how`, mínimo de 120 caracteres — rótulo sem o como não ensina nada a um
leigo) e **toda defesa declara o custo** (`cost` — defesa sem preço é conselho
de quem nunca operou nada, e é o que faz uma lista de boas práticas ser
ignorada em bloco). Os dois já reprovaram conteúdo meu enquanto eu escrevia.
