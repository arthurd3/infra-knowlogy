# O agente de build. O que ele NÃO tem é o ponto.
#
# Não tem docker CLI, não tem socket do Docker, não é privilegiado e não roda
# como root. Um `RUN` vindo de um pull request aberto executa aqui — e o que
# ele alcança é um container rootless, não a máquina (ADR 0011).
#
# A ausência do docker CLI não é economia de espaço: é uma checagem do portão.
# Se alguém montar o socket "só para destravar", o `docker` não existe para
# usá-lo, e um estágio que tente falha com "not found" em vez de funcionar em
# silêncio.
FROM jenkins/inbound-agent:latest@sha256:f049411749dda6fe6fb4693458f9da6fadc8dd54f9fd52afa687db28b14fe322

# UID numérico, como a lição 3 manda: sem o número, o usuário depende de
# quem a imagem base já tinha, e muda quando a base muda.
USER 0

# O cliente do BuildKit sai da própria imagem do buildkit — mesma versão dos
# dois lados, sem gerenciador de pacotes e sem um download a mais para
# escanear.
COPY --from=moby/buildkit:rootless@sha256:80b15f0735e87bab7bf59ec4d695dfb4a7cfb25521cf56dc75d6f256285b63ef \
     /usr/bin/buildctl /usr/local/bin/buildctl

# O repositório é montado do host e pertence ao uid 1000, que é o mesmo do
# agente. Quando não bate, o git para com "detected dubious ownership" — um
# erro que não parece de permissão e custa meia hora.
RUN git config --system --add safe.directory '*' \
    && buildctl --version

# O segredo entra por ARQUIVO, como em todo o resto do repositório. O
# entrypoint de cima só aceita a variável com o valor; este wrapper faz a
# ponte sem abrir exceção à convenção.
COPY entrypoint.sh /usr/local/bin/agent-entrypoint.sh
RUN chmod 755 /usr/local/bin/agent-entrypoint.sh

USER 1000:1000

# O agente fala com o buildkitd por socket Unix num volume compartilhado, e
# não por TCP: a documentação do buildx é explícita em dizer que BuildKit
# sobre TCP sem TLS dá acesso irrestrito ao builder. Volume remove o listener
# de rede inteiro.
ENV BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock
ENTRYPOINT ["/usr/local/bin/agent-entrypoint.sh"]
