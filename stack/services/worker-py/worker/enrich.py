"""Busca uma URL e extrai título e favicon.

O parsing usa html.parser da biblioteca padrão. Poderia usar beautifulsoup4,
mas para "achar o <title> e o <link rel=icon>" o ganho não paga duas
dependências a mais na imagem de produção.
"""

from __future__ import annotations

import ipaddress
import socket
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

import httpx


class SSRFBlocked(Exception):
    """A URL resolve para um endereço interno e foi recusada."""


@dataclass(slots=True)
class Metadata:
    title: str | None = None
    favicon: str | None = None


class _HeadParser(HTMLParser):
    """Extrai <title> e <link rel="icon">, parando ao fim do <head>.

    Parar cedo importa: sem isso, uma página de 500 KB é percorrida inteira
    para achar dois campos que estão nos primeiros 2 KB.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title: str | None = None
        self.icon: str | None = None
        self._in_title = False
        self._title_parts: list[str] = []
        self.done = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "title" and self.title is None:
            self._in_title = True
        elif tag == "link":
            a = {k.lower(): (v or "") for k, v in attrs}
            rels = a.get("rel", "").lower().split()
            if self.icon is None and any(r in ("icon", "shortcut", "apple-touch-icon") for r in rels):
                self.icon = a.get("href") or None

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False
            if self._title_parts:
                self.title = " ".join("".join(self._title_parts).split())[:300]
        elif tag == "head":
            self.done = True

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._title_parts.append(data)


def assert_public(url: str) -> None:
    """Recusa URLs que resolvem para endereços internos.

    Este worker busca URLs enviadas por qualquer usuário da API — é o clássico
    SSRF. Sem esta checagem, alguém posta `http://169.254.169.254/latest/meta-data/`
    e o worker, que roda DENTRO da rede privada da stack, busca as credenciais
    da instância e as guarda no banco como "título" do link.

    A segmentação de rede do Compose reduz o alcance, mas não substitui isto:
    o worker precisa mesmo falar com o Postgres e o Redis, então a rede interna
    é alcançável por construção.
    """
    host = urlsplit(url).hostname
    if not host:
        raise SSRFBlocked("URL sem host")

    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as exc:
        raise SSRFBlocked(f"DNS falhou para {host}") from exc

    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_multicast
            or ip.is_unspecified
        ):
            raise SSRFBlocked(f"{host} resolve para endereço interno {ip}")


def fetch_metadata(client: httpx.Client, url: str, *, max_bytes: int) -> Metadata:
    """Baixa a URL e devolve os metadados, nunca lendo mais que max_bytes."""
    assert_public(url)

    with client.stream("GET", url) as response:
        response.raise_for_status()

        ctype = response.headers.get("content-type", "")
        if "html" not in ctype.lower():
            # Não é HTML (PDF, imagem, JSON…). Não há título para extrair.
            return Metadata()

        parser = _HeadParser()
        total = 0
        # Streaming com corte: nunca materializamos a resposta inteira na memória.
        for chunk in response.iter_text(chunk_size=8192):
            total += len(chunk)
            parser.feed(chunk)
            if parser.done or total >= max_bytes:
                break

        favicon = parser.icon
        if favicon:
            favicon = urljoin(str(response.url), favicon)
        elif parser.title:
            # Fallback para a convenção /favicon.ico na raiz do site.
            parts = urlsplit(str(response.url))
            favicon = f"{parts.scheme}://{parts.netloc}/favicon.ico"

        return Metadata(title=parser.title, favicon=favicon)
