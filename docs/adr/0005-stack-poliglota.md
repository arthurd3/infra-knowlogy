# 0005 — Stack poliglota (Go + Python + Node)

**Estado:** aceita · **Data:** 2026-08-31

## Contexto

A stack poderia ser escrita inteiramente numa linguagem. Isso reduziria o custo
de manutenção e a carga cognitiva de quem lê.

## Decisão

Três linguagens, escolhidas porque produzem **três idiomas de Dockerfile
genuinamente diferentes**:

| Serviço | Linguagem | O que o multi-stage ensina |
|---|---|---|
| `api-go` | Go | artefato = 1 binário estático → imagem final pode ser `scratch` |
| `worker-py` | Python | artefato = interpretador + venv → a imagem final ainda precisa de runtime |
| `web` | Node | artefato = HTML estático → a imagem final **não precisa de Node nenhum** |

Uma stack só de Node ensinaria um caso. Estes três, lado a lado, ensinam a
*pergunta* certa — "o que sobra depois do build?" — em vez de uma receita.

O ganho é medido, não teórico: a diferença entre `scratch` e `distroless` no Go é
de 0,6 MB, enquanto a diferença entre multi-stage e stage única no Python é de
21 MB. Sem os dois casos no mesmo repositório, a lição sobre imagem base tiraria
a conclusão errada.

## Consequências

- Três toolchains para manter (`go.mod`, `uv.lock`, `package-lock.json`).
- Três ecossistemas de CVE para acompanhar.
- Em troca: o `sizes.sh` produz uma tabela comparativa que nenhuma stack
  monolíngue produziria, e as decisões de segurança (não-root, read-only,
  cap_drop) aparecem resolvidas de três formas diferentes.

## Alternativas consideradas

- **Só Node/TypeScript.** Recusada: um único idioma de build, e nenhum caso de
  binário estático — o exemplo mais didático de todos.
- **Só Python.** Recusada pelo mesmo motivo, e Python é o caso *menos*
  interessante dos três porque a imagem final permanece grande de qualquer jeito.
