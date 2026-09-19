# Um `git daemon` somente-leitura servindo este repositório.
#
# Existe porque o plugin git do Jenkins recusa remote que seja diretório local
# — e ele está certo. A resposta é dar um remote de verdade ao pipeline, não
# desligar o controle. De quebra a topologia fica honesta: em produção o CI
# puxa de um remote, nunca de um bind mount.
#
# A imagem `alpine/git` NÃO serve: ela traz o git sem o subcomando `daemon`,
# que no Alpine é o pacote separado `git-daemon`.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce

RUN apk add --no-cache git git-daemon \
    # O repositório vem do host, dono uid 1000, e o daemon roda como `nobody`.
    # Sem esta linha o git para com `detected dubious ownership` — e o daemon
    # devolve isso ao cliente como "Could not read from remote repository",
    # que manda procurar em rede e permissão em vez de em propriedade.
    && git config --system --add safe.directory '*'

# O daemon não precisa de root para servir leitura.
USER nobody

EXPOSE 9418
ENTRYPOINT ["git", "daemon", "--reuseaddr", "--export-all", "--base-path=/srv", "--verbose"]
CMD ["/srv"]
