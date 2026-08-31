# 0004 — Pinar imagens base por digest

**Estado:** aceita · **Data:** 2026-08-31

## Contexto

`FROM python:3.13-slim` referencia uma tag, e tag é um ponteiro mutável: o
publicador a reaponta a cada patch. Consequência: o mesmo Dockerfile produz
imagens diferentes em dias diferentes, e o build deixa de ser reprodutível.

## Decisão

Todo `FROM` e toda `image:` do Compose carregam `@sha256:…` além da tag.

A tag fica no arquivo **junto** com o digest, de propósito. O digest é o que vale
para o build; a tag é o que um humano lê para saber do que se trata.
`sha256:c45a22ea…` sozinho não diz que aquilo é um Python 3.13.

## Consequências

- **Builds reprodutíveis.** O mesmo commit produz a mesma imagem, hoje e daqui a
  um ano.
- **Correções de segurança também congelam.** Este é o custo real, e ele não é
  pequeno: um digest de seis meses atrás é reprodutível *e* vulnerável.

O pin só é defensável junto de um processo de atualização. Por isso existem:

- `make pins` (`tools/scripts/update-pins.sh`) — reresolve todos os digests e
  reescreve os arquivos, produzindo um diff revisável;
- o job semanal do CI com `pull: true`, que rebaixa a base e reescaneia;
- `make scan` falhando em HIGH/CRITICAL, que transforma um pin velho demais em
  build vermelho em vez de risco silencioso.

## Alternativas consideradas

- **Só a tag.** Recusada: reprodutibilidade zero, e o clássico "funciona na minha
  máquina" reaparece entre laptop e CI.
- **Renovate/Dependabot.** Não recusada — é complementar, e seria a evolução
  natural do `make pins` num repositório com mais gente. Ficou de fora agora
  porque uma automação de PR não ensina nada; um script de 30 linhas que você lê
  ensina.
