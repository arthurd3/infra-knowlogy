# Fixture NEGATIVA: este arquivo existe para o pipeline REPROVAR.
#
# Um portão que só prova o caminho feliz não prova nada — ele passaria com o
# lint desligado. É o mesmo raciocínio da armadilha 12 do CLAUDE.md, onde o
# kind aceitava NetworkPolicy e não aplicava: a única forma de saber que a
# regra vale é ver uma violação ser recusada.
#
# As violações aqui são deliberadas e deterministas (não dependem de CVE nova
# nem de rede):
#   DL3006  tag ausente — `FROM alpine` sem versão
#   DL3009  apt-get sem limpar a lista de pacotes
#   DL3015  apt-get install sem --no-install-recommends
FROM debian:stable-slim
RUN apt-get update && apt-get install -y curl
