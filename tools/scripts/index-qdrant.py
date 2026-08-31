#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["qdrant-client>=1.12", "fastembed>=0.5"]
# ///
"""Indexa as lições na coleção Qdrant `infra-knowlogy`.

Por que isto existe: sessões futuras (suas ou de um agente) precisam recuperar
"o que este repositório já diz sobre healthchecks" sem reler dezesseis arquivos
MDX. Indexado, isso vira uma busca semântica via `qdrant-find`.

O formato do ponto imita o do mcp-server-qdrant de propósito — vetor nomeado
`fast-all-minilm-l6-v2` e payload `{document, metadata}` — para que o MCP
configurado em .mcp.json leia o que este script escreve.

Idempotente: o ID de cada chunk é um uuid5 determinístico, então reindexar
atualiza os pontos em vez de duplicá-los.
"""

from __future__ import annotations

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
NAMESPACE = uuid.UUID("6f1a1d3e-1f2b-4c8a-9a5b-3e7d2c4f8a10")

ROOT = Path(__file__).resolve().parents[2]
LESSONS = ROOT / "site" / "src" / "content" / "lessons"


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
    """Remove ruído de MDX que não ajuda a busca semântica."""
    body = re.sub(r"^import .+$", "", body, flags=re.M)          # imports de ilha
    body = re.sub(r"^<[A-Z]\w*[^>]*/>$", "", body, flags=re.M)   # <Widget />
    body = re.sub(r"^</?(Callout|RunIt)[^>]*>$", "", body, flags=re.M)
    return body


def chunks(path: Path):
    """Fatia a lição por seção de nível 2 — a unidade natural de um assunto."""
    meta, body = parse_frontmatter(path.read_text(encoding="utf-8"))
    if not meta.get("key"):
        return

    body = clean(body)
    # split mantendo o cabeçalho junto do texto que ele introduz
    parts = re.split(r"^## ", body, flags=re.M)
    intro, sections = parts[0], parts[1:]

    def emit(heading: str, text: str):
        text = text.strip()
        if len(text) < 120:      # fragmentos curtos poluem o índice
            return
        yield_heading = heading or meta["title"]
        # O documento carrega o próprio contexto: sem o título da lição, um
        # chunk sobre "a terceira condição" recuperado sozinho não diz nada.
        document = (
            f"[{meta['lang']}] {meta['title']} — {yield_heading}\n\n{text}"
        )
        cid = uuid.uuid5(NAMESPACE, f"{meta['key']}|{meta['lang']}|{yield_heading}")
        return models.PointStruct(
            id=str(cid),
            vector={},  # preenchido depois, em lote
            payload={
                "document": document,
                "metadata": {
                    "source": "infra-knowlogy",
                    "kind": "lesson",
                    "key": meta["key"],
                    "lang": meta["lang"],
                    "track": meta.get("track", ""),
                    "order": int(meta.get("order", 0)),
                    "title": meta["title"],
                    "section": yield_heading,
                    "url": f"/{meta['lang']}/lessons/{meta['key']}/",
                    "path": str(path.relative_to(ROOT)),
                },
            },
        )

    if p := emit("", intro):
        yield p
    for section in sections:
        heading, _, text = section.partition("\n")
        if p := emit(heading.strip(), text):
            yield p


def main() -> int:
    if not LESSONS.is_dir():
        print(f"não achei as lições em {LESSONS}", file=sys.stderr)
        return 1

    points = [p for f in sorted(LESSONS.rglob("*.mdx")) for p in chunks(f)]
    if not points:
        print("nenhum chunk encontrado.", file=sys.stderr)
        return 1

    print(f"  {len(points)} chunks de {len(list(LESSONS.rglob('*.mdx')))} lições")

    try:
        client = QdrantClient(url=QDRANT_URL, timeout=30)
        client.get_collections()
    except Exception as exc:
        # Best-effort de propósito: o Qdrant é uma conveniência para sessões
        # futuras, não uma dependência do build. Falhar aqui não deve quebrar
        # `make verify`.
        print(f"  ⊘ Qdrant indisponível em {QDRANT_URL}: {exc}", file=sys.stderr)
        return 0

    print(f"  gerando embeddings com {MODEL} (primeira vez baixa o modelo)…")
    embedder = TextEmbedding(model_name=MODEL)
    vectors = list(embedder.embed(p.payload["document"] for p in points))

    for point, vector in zip(points, vectors):
        point.vector = {VECTOR_NAME: vector.tolist()}

    if not client.collection_exists(COLLECTION):
        client.create_collection(
            COLLECTION,
            vectors_config={
                VECTOR_NAME: models.VectorParams(size=384, distance=models.Distance.COSINE)
            },
        )
        print(f"  coleção {COLLECTION} criada")

    client.upsert(collection_name=COLLECTION, points=points, wait=True)
    total = client.count(COLLECTION, exact=True).count
    print(f"  ✓ indexado. {COLLECTION} tem agora {total} pontos.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
