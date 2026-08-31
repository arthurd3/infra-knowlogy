#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["qdrant-client>=1.12", "fastembed>=0.5"]
# ///
"""Indexa TODO o conhecimento do repositório na coleção Qdrant `infra-knowlogy`.

Por que isto existe: sessões futuras — suas ou de um agente — precisam recuperar
"o que este repositório já decidiu sobre X" sem reler dezenas de arquivos. Não
basta indexar as lições: a decisão de usar Caddy em vez de Traefik está num ADR,
a armadilha do SELinux está no CLAUDE.md, e o tamanho medido de cada imagem está
num JSON gerado. Tudo isso vira busca semântica aqui.

O que é indexado:

  lesson       site/src/content/lessons/**/*.mdx   (bilíngue, por seção)
  adr          docs/adr/*.md                        (decisões e alternativas recusadas)
  convention   CLAUDE.md                            (armadilhas e convenções)
  overview     README.md                            (arquitetura e verificação)
  measurement  site/src/data/measured.json          (números medidos, virados em prosa)

O formato do ponto imita o do mcp-server-qdrant de propósito — vetor nomeado
`fast-all-minilm-l6-v2` e payload `{document, metadata}` — para que o MCP
configurado em .mcp.json leia o que este script escreve.

Idempotente: antes de gravar, apaga os pontos cuja metadata.source é
`infra-knowlogy`. Assim, seção renomeada ou arquivo removido não deixa órfão —
e nada que tenha sido guardado na coleção por outra via é tocado.
"""

from __future__ import annotations

import json
import os
import re
import sys
import uuid
from pathlib import Path

from fastembed import TextEmbedding
from qdrant_client import QdrantClient, models

QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
COLLECTION = os.environ.get("COLLECTION_NAME", "infra-knowlogy")
MODEL = "sentence-transformers/all-MiniLM-L6-v2"
VECTOR_NAME = "fast-all-minilm-l6-v2"
SOURCE = "infra-knowlogy"
NAMESPACE = uuid.UUID("6f1a1d3e-1f2b-4c8a-9a5b-3e7d2c4f8a10")
MIN_CHARS = 120

ROOT = Path(__file__).resolve().parents[2]


def parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---"):
        return {}, text
    _, fm, body = text.split("---", 2)
    data = {}
    for line in fm.splitlines():
        if m := re.match(r"^(\w+):\s*(.+)$", line):
            data[m.group(1)] = m.group(2).strip().strip("\"'")
    return data, body


def clean(body: str) -> str:
    """Tira ruído de MDX que não ajuda a busca semântica."""
    body = re.sub(r"^import .+$", "", body, flags=re.M)
    body = re.sub(r"^<[A-Z]\w*[^>]*/>$", "", body, flags=re.M)
    body = re.sub(r"^</?(Callout|RunIt)[^>]*>$", "", body, flags=re.M)
    return body


def point(kind: str, path: Path, heading: str, text: str, extra: dict) -> models.PointStruct | None:
    text = text.strip()
    if len(text) < MIN_CHARS:
        return None
    rel = str(path.relative_to(ROOT)) if path else kind
    title = extra.get("title", rel)
    # O documento carrega o próprio contexto: sem o título, um chunk sobre "a
    # terceira condição" recuperado sozinho não diz nada.
    document = f"[{extra.get('lang', 'pt')}] {title} — {heading}\n\n{text}"
    return models.PointStruct(
        id=str(uuid.uuid5(NAMESPACE, f"{kind}|{rel}|{heading}")),
        vector={},
        payload={
            "document": document,
            "metadata": {"source": SOURCE, "kind": kind, "path": rel,
                         "section": heading, **extra},
        },
    )


def chunk_markdown(path: Path, kind: str, extra: dict):
    """Fatia por seção de nível 2 — a unidade natural de um assunto."""
    meta, body = parse_frontmatter(path.read_text(encoding="utf-8"))
    body = clean(body)
    info = {**extra, **{k: meta[k] for k in ("title", "lang", "track") if k in meta}}
    if "order" in meta:
        info["order"] = int(meta["order"])
    if "key" in meta:
        info["key"] = meta["key"]
        info["url"] = f"/{meta.get('lang','pt')}/lessons/{meta['key']}/"

    # Título vindo do primeiro H1 quando não há frontmatter (ADRs, README).
    if "title" not in info:
        if m := re.search(r"^#\s+(.+)$", body, flags=re.M):
            info["title"] = m.group(1).strip()

    parts = re.split(r"^##\s+", body, flags=re.M)
    intro, sections = parts[0], parts[1:]

    if p := point(kind, path, info.get("title", path.stem), intro, info):
        yield p
    for section in sections:
        heading, _, text = section.partition("\n")
        if p := point(kind, path, heading.strip(), text, info):
            yield p


def measurement_points():
    """Transforma measured.json em prosa pesquisável.

    Sem isto, "qual o tamanho da imagem do worker" não tem resposta no índice:
    o número existe, mas só como JSON dentro de um widget.
    """
    f = ROOT / "site/src/data/measured.json"
    if not f.is_file():
        return
    d = json.loads(f.read_text())
    by_service: dict[str, list] = {}
    for i in d["images"]:
        by_service.setdefault(i["service"], []).append(i)

    for service, items in by_service.items():
        lines = [
            f"Tamanhos medidos da imagem `{service}` ({items[0]['language']}), "
            f"obtidos por tools/scripts/sizes.sh em {d['generatedAt'][:10]} "
            f"com Docker {d['dockerVersion']} ({d['platform']}). "
            "São medições reais desta stack, não números copiados de blog.",
            "",
        ]
        for i in sorted(items, key=lambda x: x["bytes"]):
            lines.append(
                f"- alvo `{i['target']}` sobre base `{i['base']}`: "
                f"{i['bytes'] / 1048576:.1f} MB em {i['layers']} camadas. {i['note_pt']}"
            )
        biggest, smallest = max(items, key=lambda x: x["bytes"]), min(items, key=lambda x: x["bytes"])
        if biggest is not smallest:
            delta = (biggest["bytes"] - smallest["bytes"]) / 1048576
            lines.append(
                f"\nDiferença entre o maior (`{biggest['target']}`) e o menor "
                f"(`{smallest['target']}`): {delta:.1f} MB."
            )
        yield point("measurement", f, f"tamanho da imagem {service}", "\n".join(lines),
                    {"title": f"Medições — {service}", "lang": "pt", "service": service})


def collect() -> list[models.PointStruct]:
    points: list[models.PointStruct] = []

    lessons = ROOT / "site/src/content/lessons"
    for f in sorted(lessons.rglob("*.mdx")):
        points += list(chunk_markdown(f, "lesson", {}))

    for f in sorted((ROOT / "docs/adr").glob("*.md")):
        kind = "adr-index" if f.name == "README.md" else "adr"
        points += list(chunk_markdown(f, kind, {"lang": "pt"}))

    # O README é o único documento de raiz em inglês (ver CLAUDE.md); o
    # CLAUDE.md e os ADRs são notas internas em português. O rótulo de idioma
    # precisa refletir isso, senão a busca em inglês perde o overview.
    for name, kind, lang in (("CLAUDE.md", "convention", "pt"),
                             ("README.md", "overview", "en")):
        f = ROOT / name
        if f.is_file():
            points += list(chunk_markdown(f, kind, {"lang": lang}))

    points += list(measurement_points())
    return points


def main() -> int:
    points = collect()
    if not points:
        print("nenhum chunk encontrado.", file=sys.stderr)
        return 1

    kinds: dict[str, int] = {}
    for p in points:
        kinds[p.payload["metadata"]["kind"]] = kinds.get(p.payload["metadata"]["kind"], 0) + 1
    print("  " + " · ".join(f"{k}: {n}" for k, n in sorted(kinds.items())))

    try:
        client = QdrantClient(url=QDRANT_URL, timeout=60)
        client.get_collections()
    except Exception as exc:
        # Best-effort de propósito: o Qdrant é conveniência para sessões futuras,
        # não dependência do build. Falhar aqui não deve quebrar `make verify`.
        print(f"  ⊘ Qdrant indisponível em {QDRANT_URL}: {exc}", file=sys.stderr)
        return 0

    print(f"  gerando embeddings com {MODEL}…")
    embedder = TextEmbedding(model_name=MODEL)
    for p, v in zip(points, embedder.embed(p.payload["document"] for p in points)):
        p.vector = {VECTOR_NAME: v.tolist()}

    if not client.collection_exists(COLLECTION):
        client.create_collection(
            COLLECTION,
            vectors_config={VECTOR_NAME: models.VectorParams(size=384, distance=models.Distance.COSINE)},
        )
        print(f"  coleção {COLLECTION} criada")

    # Apaga só o que ESTE script escreveu, para não deixar órfão de seção
    # renomeada — e para não tocar no que foi guardado por outra via.
    client.delete(
        collection_name=COLLECTION,
        points_selector=models.FilterSelector(filter=models.Filter(must=[
            models.FieldCondition(key="metadata.source", match=models.MatchValue(value=SOURCE))
        ])),
        wait=True,
    )
    client.upsert(collection_name=COLLECTION, points=points, wait=True)
    print(f"  ✓ {len(points)} chunks indexados. {COLLECTION} tem {client.count(COLLECTION, exact=True).count} pontos.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
