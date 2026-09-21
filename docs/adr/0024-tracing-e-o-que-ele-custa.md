# 0024 — Tracing ponta a ponta, e o custo que ele cobra em bytes

**Estado:** aceita · **Data:** 2026-09-21

## Contexto

A primeira lição da trilha de Observabilidade declarava, em voz alta, que trace
era o sinal que esta stack **não** tinha. Era verdade e era honesto: as três
aplicações não propagavam contexto nenhum, e um diagrama de "três pilares"
sugerindo completude teria sido pior do que a lacuna.

Fechar a lacuna exige mexer em **código de produção** — a api em Go e o worker
em Python — o que nenhum módulo anterior tinha feito. E exige atravessar a fila
do Redis, que é onde a instrumentação da maioria dos sistemas se parte sem que
ninguém perceba: os spans de cada lado continuam corretos, em traces separados.

Há um conflito aberto com o resto do repositório. Uma trilha inteira aqui é
sobre imagem mínima, com `scratch` e `distroless` medidos lado a lado. O
OpenTelemetry é grande. Instrumentar sem dizer o preço contradiria o material
que já está publicado.

## Decisão

**Instrumentar as três aplicações, e medir o custo contra uma referência
provadamente não instrumentada.**

Três decisões dentro dessa:

1. **O span raiz nasce no edge**, não na api. O Caddy tem o módulo `tracing`, e
   sem ele o tempo gasto no proxy fica fora da conta. Custou pôr o coletor na
   rede `edge` — uma concessão real na segmentação, documentada no
   `compose.obs.yaml`: o coletor **recebe** e não inicia conexão, então
   acrescentá-lo à DMZ não dá ao proxy nenhum caminho novo; o contrário daria.

2. **O `traceparent` viaja no corpo da mensagem do Redis.** Fila não tem
   cabeçalho. A api passou a enfileirar JSON, e o worker aceita as duas formas
   (JSON e código cru) para que um rollout não descarte mensagens antigas em
   silêncio.

3. **A referência de custo precisa provar que não tem OTel.** O `sizes.sh`
   reconstrói as tags de referência; depois da instrumentação elas passariam a
   TER OTel, e o delta daria zero. O `tracing-measure.py` só aceita uma
   referência com **zero ocorrências de `go.opentelemetry.io`** no binário, e sem
   referência válida preserva o valor antigo marcando `referencia_valida: false`.

## Consequências

**Medido, e publicado.** A api vai de 6,0 MB para 9,8 MB (**+63%**) e o binário
de 14,8 MB para 27,8 MB (**+88%**), com 0 contra 2315 símbolos
`go.opentelemetry.io`. No worker, OTel, gRPC e protobuf somam **43,9% de todos
os bytes de pacote** instalados. A biblioteca de tracing é maior que a aplicação
que ela observa.

**O caminho de retentativa era o que faltava.** A primeira versão reenfileirava
o código cru e produzia traces **órfãos** — medido, três traces onde deveria
haver um. O tracing cobria o caminho rápido e se partia no lento, que é o único
que alguém investiga de madrugada.

**Falha de tracing não pode derrubar o serviço.** Uma versão intermediária
chamava `os.Exit(1)` quando o setup do exportador falhava, e a api entrou em
laço de reinício: a observabilidade derrubou a coisa que ela observa. Hoje o
erro é logado alto e o processo segue com tracing no-op.

**O que não foi feito.** Não há backend de trace com interface — nada de Tempo
ou Jaeger. O coletor exporta para arquivo, e o portão lê o arquivo. Isso prova a
propagação, que é o assunto da lição, e evita mais um serviço de UI no profile.
A consulta por trace_id numa interface fica de fora.
