"""Loop principal do worker de enriquecimento.

Ciclo de vida: BRPOP na fila do Redis -> busca a URL -> grava título e favicon
no Postgres. O ponto didático central deste arquivo é o desligamento gracioso:
um worker que ignora SIGTERM é morto a SIGKILL no meio de uma transação.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time
from types import FrameType

import httpx
import psycopg
import redis
from prometheus_client import Counter, Histogram, start_http_server

from .config import Config
from .enrich import SSRFBlocked, fetch_metadata

log = logging.getLogger("worker")

JOBS = Counter("worker_jobs_total", "Jobs processados por resultado.", ["result"])
DURATION = Histogram("worker_job_duration_seconds", "Duração do enriquecimento de um link.")


class JSONFormatter(logging.Formatter):
    """Logs em JSON no stdout — mesmo contrato do slog da API em Go.

    Fator XI do 12-Factor: a aplicação emite um fluxo de eventos e não sabe
    onde ele é guardado. Quem coleta aqui é o Alloy, lendo o log driver do Docker.
    """

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "time": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname.lower(),
            "msg": record.getMessage(),
            "logger": record.name,
        }
        if record.exc_info:
            payload["error"] = self.formatException(record.exc_info)
        payload.update(getattr(record, "extra_fields", {}))
        return json.dumps(payload, ensure_ascii=False)


class Worker:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.running = True
        self.redis = redis.Redis(
            host=cfg.redis_host, port=cfg.redis_port, decode_responses=True,
            # Timeouts curtos e SEM retry interno do redis-py, de propósito.
            # Com os padrões, um Redis fora do ar faz cada brpop demorar ~8s
            # (resolução DNS + retentativas da biblioteca) — e durante esses 8s
            # o loop não consegue reparar que chegou um SIGTERM. O resultado é
            # um desligamento que estoura o grace period e termina em SIGKILL.
            # Quem decide a política de retentativa aqui é o nosso loop, não a
            # biblioteca: assim a espera é sempre interrompível.
            socket_connect_timeout=2,
            socket_timeout=cfg.block_seconds + 2,
            retry_on_timeout=False,
            retry=None,
        )
        self.http = httpx.Client(
            timeout=cfg.fetch_timeout,
            follow_redirects=True,
            max_redirects=5,
            headers={"User-Agent": cfg.user_agent},
        )

    # ─── Sinais ─────────────────────────────────────────────────────────────

    def install_signal_handlers(self) -> None:
        """SIGTERM apenas levanta uma flag; ele NÃO mata o processo no meio do job.

        É essa distinção que define "gracioso": o `docker stop` manda SIGTERM,
        nós terminamos o job em voo, fechamos as conexões e saímos por vontade
        própria. Se ignorássemos o sinal, o Docker esperaria o stop_grace_period
        inteiro e depois mandaria SIGKILL — que não dá para tratar.
        """

        def handle(signum: int, _frame: FrameType | None) -> None:
            log.info("sinal recebido, encerrando após o job atual", extra={"extra_fields": {"signal": signum}})
            self.running = False

        signal.signal(signal.SIGTERM, handle)
        signal.signal(signal.SIGINT, handle)

    # ─── Trabalho ───────────────────────────────────────────────────────────

    def run(self) -> None:
        log.info("worker iniciado", extra={"extra_fields": {"queue": self.cfg.queue}})
        while self.running:
            # Timeout curto no BRPOP: é o que dá ao loop a chance de reparar que
            # a flag mudou. Um BRPOP com timeout=0 bloquearia para sempre e o
            # container só sairia no SIGKILL.
            try:
                item = self.redis.brpop([self.cfg.queue], timeout=self.cfg.block_seconds)
            except redis.RedisError as exc:
                log.warning("redis indisponível, tentando de novo", extra={"extra_fields": {"error": str(exc)}})
                self._sleep_interruptible(1.0)
                continue

            if item is None:
                continue

            _, code = item
            with DURATION.time():
                self.process(code)

        self.close()
        log.info("worker desligado limpo")

    def _sleep_interruptible(self, seconds: float) -> None:
        """Dorme em fatias, conferindo a flag de parada entre elas.

        Um `time.sleep(1)` cru atrasaria o desligamento em até um segundo por
        iteração. Fatiado, o SIGTERM é observado em no máximo 100 ms.
        """
        deadline = time.monotonic() + seconds
        while self.running and time.monotonic() < deadline:
            time.sleep(0.1)

    def process(self, code: str) -> None:
        try:
            with psycopg.connect(self.cfg.dsn, connect_timeout=5) as conn:
                row = conn.execute("SELECT url, attempts FROM links WHERE code = %s", (code,)).fetchone()
                if row is None:
                    JOBS.labels(result="missing").inc()
                    return
                url, attempts = row

                try:
                    meta = fetch_metadata(self.http, url, max_bytes=self.cfg.max_bytes)
                except SSRFBlocked as exc:
                    # Não faz sentido tentar de novo: a URL nunca vai virar pública.
                    self._finish(conn, code, None, None, f"bloqueado: {exc}")
                    JOBS.labels(result="blocked").inc()
                    log.warning("url bloqueada", extra={"extra_fields": {"code": code, "reason": str(exc)}})
                    return
                except (httpx.HTTPError, UnicodeDecodeError) as exc:
                    self._retry_or_give_up(conn, code, attempts, str(exc))
                    return

                self._finish(conn, code, meta.title, meta.favicon, None)
                JOBS.labels(result="ok").inc()
                log.info("link enriquecido", extra={"extra_fields": {"code": code, "title": meta.title}})

        except psycopg.Error as exc:
            JOBS.labels(result="db_error").inc()
            log.error("erro de banco", extra={"extra_fields": {"code": code, "error": str(exc)}})

    def _retry_or_give_up(self, conn: psycopg.Connection, code: str, attempts: int, error: str) -> None:
        attempts += 1
        if attempts < self.cfg.max_attempts:
            conn.execute("UPDATE links SET attempts = %s WHERE code = %s", (attempts, code))
            # Volta para o começo da fila. Um backoff de verdade usaria um
            # sorted set com timestamp; aqui a simplicidade vale mais que a
            # precisão, e o comportamento fica visível na lição.
            self.redis.lpush(self.cfg.queue, code)
            JOBS.labels(result="retry").inc()
            log.info("reenfileirado", extra={"extra_fields": {"code": code, "attempt": attempts}})
        else:
            self._finish(conn, code, None, None, error[:500])
            JOBS.labels(result="failed").inc()
            log.warning("desisti do link", extra={"extra_fields": {"code": code, "error": error}})

    @staticmethod
    def _finish(
        conn: psycopg.Connection, code: str, title: str | None, favicon: str | None, error: str | None
    ) -> None:
        conn.execute(
            """
            UPDATE links
               SET title = %s, favicon = %s, enrich_error = %s, enriched_at = now()
             WHERE code = %s
            """,
            (title, favicon, error, code),
        )

    def close(self) -> None:
        self.http.close()
        try:
            self.redis.close()
        except redis.RedisError:
            pass


def main() -> int:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(), handlers=[handler])

    cfg = Config.from_env()
    # Servidor de métricas numa thread separada. O Prometheus faz PULL: ele
    # raspa este endpoint, o worker não empurra nada para lugar nenhum.
    start_http_server(cfg.metrics_port)

    worker = Worker(cfg)
    worker.install_signal_handlers()
    worker.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
