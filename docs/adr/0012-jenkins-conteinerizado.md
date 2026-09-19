# 0012 — Jenkins conteinerizado, ao lado do GitHub Actions

**Estado:** aceita · **Data:** 2026-09-19

## Contexto

O repositório já tinha CI: `.github/workflows/ci.yml` faz lint → build
multi-arquitetura → SBOM e provenance pelo buildx → Trivy → assinatura keyless
do cosign via OIDC. Não é CI de brinquedo.

A pergunta do módulo 3 não é "como fazer CI" — é **o que muda quando o CI é
seu**. E essa pergunta só tem resposta honesta com os dois lados rodando: a
comparação entre CI gerenciado e CI self-hosted é feita aos montes na internet
com adjetivos, e quase nunca com números.

Vale o mesmo princípio dos módulos 1 e 2 (ADR 0001, ADR 0007): **a aplicação é
a mesma**. O Jenkins constrói exatamente os mesmos três Dockerfiles, com os
mesmos `target`, que o GitHub Actions constrói.

## Decisão

### Jenkins, e não GitLab CI, Drone ou Woodpecker

Jenkins é o que existe em quantidade nas empresas que ainda rodam CI próprio —
ele ancora pipeline em banco, telco e fabricante de chip, e boa parte da
Fortune 500. Ensinar o que o leitor vai encontrar vale mais que ensinar o que
seria mais bonito. Ele também é o caso mais difícil: estado em disco,
plugins, um modelo de segurança com décadas de história. Um CI que só funciona
quando é fácil não ensina.

**Recusados:** GitLab CI exigiria subir um GitLab inteiro para ensinar o
runner. Drone e Woodpecker são mais agradáveis e quase não aparecem em
migração real — e o módulo existe para preparar o leitor para o que ele vai
encontrar.

### Projeto Compose próprio, em `cicd/`

O Jenkins **não é a aplicação**; ele constrói a aplicação. Misturar os dois
faria `make up` subir um CI e obrigaria o `verify.sh` a ignorar containers que
não são dele. Portas 8090 e 5001, no loopback, ao lado da stack em 8080 e do
kind em 8081 — de propósito: as lições comparam os três rodando ao mesmo tempo.

### Tudo declarado: JCasC + Job DSL, e nenhum clique

O controller nasce de `cicd/controller/casc/`, com o assistente de instalação
desligado, e os jobs nascem de `jobs/seed.groovy`. O portão prova os dois: não
existe `initialAdminPassword`, e o conjunto de jobs é **exatamente** o que o
seed declara — um job criado à mão na UI aparece na diferença.

Duas armadilhas grandes moram aqui:

- **Chave errada no JCasC é ignorada em silêncio.** `numExecutor` sem o "s"
  deixa dois executores no built-in e o YAML fica com cara de certo. É o primo
  do kind < 0.23 aceitando NetworkPolicy sem aplicar (armadilha 12). O portão
  lê o log procurando `Unknown key`.
- **A configuração NÃO pode morar em `/var/jenkins_home`.** É volume nomeado,
  e volume nomeado só é populado a partir da imagem quando está **vazio** — a
  lição 6 deste repositório aplicada a nós mesmos. A primeira subida funciona,
  e toda alteração posterior é ignorada calada. A configuração fica em `/opt`.

### O repositório é servido por `git daemon`, não por bind mount

O plugin git do Jenkins **recusa** remote que seja diretório local, com
`references a local directory, which may be insecure`. Ele está certo: um job
capaz de escolher um caminho local lê qualquer coisa que o controller enxergue.

A saída óbvia seria ligar `hudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT`.
**Recusada:** este módulo ensina segurança de CI; desligar um controle para
destravar o próprio tutorial é o pior começo possível. Em vez disso o
repositório é servido por um `git daemon` somente-leitura — que também é o que
acontece em produção, onde o CI puxa de um remote.

Efeito colateral bem-vindo: o pipeline passa a construir o que está
**commitado**, não o working tree. Comportamento correto de CI, e surpresa
garantida na primeira hora.

### Plugins pinados por versão, e o fecho transitivo inteiro

67 linhas em `plugins.txt`, não 7. Pinar os de primeiro nível e deixar as
dependências soltas é pin decorativo: o `jenkins-plugin-cli` resolveria a
dependência para a última versão do dia, e o mesmo Dockerfile produziria
controllers diferentes em dias diferentes. Mesma doutrina do pin por digest
(ADR 0004), com um script próprio para mover o pin de propósito
(`make cicd-plugins`).

Todo download acontece em tempo de **build da imagem**. Depois que ela existe,
`make cicd-verify` roda sem rede.

### Portão independente

`make cicd-verify`, 32 checagens, separado do `verify` e do `k8s-verify`
(ADR 0007). Quem estuda só Docker não instala Jenkins.

## Consequências

**A favor:**

- A comparação com o GitHub Actions vira número: pipeline frio em 21 s, quente
  em 7 s, contra um runner que é descartado a cada job e por isso é sempre
  frio. Os dois lados constroem as mesmas imagens.
- O módulo prova o isolamento em vez de afirmá-lo: 0 executores, agente sem
  socket e sem docker CLI, nada privilegiado, SELinux ainda confinando.
- O binário Go do artefato do Jenkins é byte a byte igual ao do `docker build`
  local — o caminho sem daemon não é uma aproximação do build de verdade.

**Contra, e assumido:**

- **Disco.** `jenkins_home` + cache do buildkit + registry chegam a vários GB.
  Por isso existe `make cicd-nuke`.
- **A assinatura keyless não vem de graça.** No GitHub Actions o cosign usa o
  token OIDC do próprio workflow; num Jenkins self-hosted isso custa uma chave
  gerenciada ou um provedor de identidade próprio. É uma das assimetrias que a
  lição 7 do módulo mede em vez de opinar.
- **Multi-arquitetura fica para trás.** O `ci.yml` constrói amd64 e arm64 com
  QEMU; aqui é amd64 nativo. arm64 exigiria um segundo agente.
- **O portão não roda no GitHub Actions.** Precisaria de user namespaces
  aninhados no runner. O que cabe lá é um `cicd-lint` barato — e isso, de
  forma conveniente, é a tese do módulo.
