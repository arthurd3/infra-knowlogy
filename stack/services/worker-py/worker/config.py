"""Configuração vinda do ambiente — Fator III do 12-Factor.

Espelha de propósito o config.go da API: mesma convenção `<VAR>_FILE` para
segredos, mesmos nomes de variável. Dois serviços em linguagens diferentes que
se configuram de formas diferentes é uma fonte silenciosa de bug em produção.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def getenv(key: str, fallback: str) -> str:
    return os.environ.get(key) or fallback


def read_secret(name: str) -> str:
    """Lê um segredo preferindo o arquivo montado em /run/secrets/<nome>.

    Variável de ambiente aparece em `docker inspect`, é herdada por todo
    processo filho e costuma vazar em stack trace. Arquivo montado, não.
    """
    path = os.environ.get(f"{name}_FILE")
    if path:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    value = os.environ.get(name)
    if value:
        return value
    raise RuntimeError(f"segredo ausente: defina {name}_FILE ou {name}")


@dataclass(frozen=True, slots=True)
class Config:
    dsn: str
    redis_host: str
    redis_port: int
    queue: str
    metrics_port: int
    fetch_timeout: float
    max_bytes: int
    user_agent: str
    max_attempts: int
    block_seconds: int

    @classmethod
    def from_env(cls) -> "Config":
        password = read_secret("POSTGRES_PASSWORD")
        return cls(
            dsn=(
                f"host={getenv('POSTGRES_HOST', 'db')} "
                f"port={getenv('POSTGRES_PORT', '5432')} "
                f"dbname={getenv('POSTGRES_DB', 'links')} "
                f"user={getenv('POSTGRES_USER', 'links')} "
                f"password={password}"
            ),
            redis_host=getenv("REDIS_HOST", "cache"),
            redis_port=int(getenv("REDIS_PORT", "6379")),
            queue=getenv("REDIS_QUEUE", "links:enrich"),
            metrics_port=int(getenv("METRICS_PORT", "9100")),
            fetch_timeout=float(getenv("FETCH_TIMEOUT", "8")),
            # Limite rígido de download: sem isto, uma URL apontando para uma ISO
            # de 4 GB derruba o worker por consumo de memória. É o mesmo raciocínio
            # do `deploy.resources.limits` no Compose, só que na camada da aplicação.
            max_bytes=int(getenv("FETCH_MAX_BYTES", str(512 * 1024))),
            user_agent=getenv("USER_AGENT", "infra-knowlogy-worker/0.1 (+https://github.com/infra-knowlogy)"),
            max_attempts=int(getenv("MAX_ATTEMPTS", "3")),
            # BRPOP com timeout curto: é o que permite ao loop reparar que
            # chegou um SIGTERM em vez de ficar bloqueado para sempre no Redis.
            block_seconds=int(getenv("BLOCK_SECONDS", "1")),
        )
