"""Configuração de tracing do worker.

O worker é a OUTRA ponta de um trace que começou na api. O que ele recebe não
é uma requisição HTTP com cabeçalho — é uma mensagem numa fila do Redis, e o
contexto do trace viaja dentro dela.

Se `OTEL_EXPORTER_OTLP_ENDPOINT` não estiver definido, tudo aqui vira no-op e
o worker roda normalmente: a mesma imagem serve com e sem o profile `obs`.
"""

from __future__ import annotations

import json
import os
from contextlib import contextmanager
from typing import Any, Iterator

from opentelemetry import trace
from opentelemetry.context import Context
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.propagators.textmap import Getter, Setter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

NOME = "infra-knowlogy/worker-py"
_propagador = TraceContextTextMapPropagator()


class _GetterDeDicionario(Getter):
    """O carrier aqui é um dict vindo de JSON, não um objeto de headers."""

    def get(self, carrier: dict[str, Any], key: str) -> list[str] | None:
        v = carrier.get(key)
        return [v] if isinstance(v, str) and v else None

    def keys(self, carrier: dict[str, Any]) -> list[str]:
        return list(carrier.keys())


_getter = _GetterDeDicionario()


def configurar(versao: str = "dev") -> Any:
    """Liga o SDK se houver endpoint. Devolve o provider (ou None)."""
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")
    if not endpoint:
        return None
    provider = TracerProvider(
        resource=Resource.create({"service.name": "worker-py", "service.version": versao})
    )
    # Em lote: exportar span a span poria uma chamada de rede no caminho de
    # cada mensagem processada.
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True))
    )
    trace.set_tracer_provider(provider)
    return provider


class _SetterDeDicionario(Setter):
    """O espelho do getter: escreve o `traceparent` no dicionário da mensagem."""

    def set(self, carrier: dict, chave: str, valor: str) -> None:
        carrier[chave] = valor


_setter = _SetterDeDicionario()


def desempacotar(bruto: str) -> tuple[str, Context | None]:
    """Lê a mensagem da fila e devolve (código, contexto do trace).

    ─── Por que aceita DUAS formas ─────────────────────────────────────────
    A api passou a enfileirar JSON com o `traceparent` dentro, porque uma fila
    não tem cabeçalho onde pôr o contexto. Mas a mensagem antiga era o código
    cru, e durante um rollout as duas convivem: mensagens enfileiradas pela
    versão anterior ainda estão lá quando a versão nova começa a consumir.

    Recusar a forma antiga faria o deploy perder trabalho em silêncio — o
    worker descartaria as mensagens e ninguém veria erro nenhum. É o mesmo
    princípio das migrações de banco compatíveis para os dois lados.
    """
    bruto = bruto.strip()
    if not bruto.startswith("{"):
        return bruto, None          # formato antigo: só o código
    try:
        msg = json.loads(bruto)
    except json.JSONDecodeError:
        return bruto, None
    codigo = msg.get("code", "")
    # `extract` devolve um Context com o span pai — o `cache.enqueue` da api.
    # Sem esta linha os spans do worker existiriam, seriam corretos, e
    # formariam um trace SEPARADO. É a falha mais comum e a mais difícil de
    # notar, porque cada metade parece certa.
    ctx = _propagador.extract(carrier=msg, getter=_getter)
    return codigo, ctx


def empacotar(codigo: str) -> str:
    """Devolve a mensagem de fila com o contexto do span ATUAL dentro.

    ─── Por que a retentativa precisa disto ────────────────────────────────
    O worker reenfileirava o código cru. Funcionava — o link era processado de
    novo — e destruía o trace em silêncio: cada tentativa virava um trace
    ÓRFÃO, de dois spans, sem nenhum vínculo com a requisição que a originou.

    Medido: uma URL que devolve 404 produziu **três** traces onde deveria haver
    um. O da api tinha o `http.fetch` da primeira tentativa; os outros dois
    boiavam soltos, e a pergunta que o tracing existe para responder — "por que
    este link demorou?" — ficava sem resposta justamente no caso lento.

    O caminho feliz é o que todo mundo instrumenta. O de retentativa é o que
    importa, porque é o que você vai investigar de madrugada.
    """
    msg = {"code": codigo}
    _propagador.inject(carrier=msg, setter=_setter)
    return json.dumps(msg, separators=(",", ":"))


@contextmanager
def span(nome: str, ctx: Context | None = None, **atributos: Any) -> Iterator[Any]:
    """Abre um span. Sem SDK configurado, o OTel devolve um no-op."""
    tracer = trace.get_tracer(NOME)
    with tracer.start_as_current_span(nome, context=ctx, attributes=atributos or None) as s:
        yield s
