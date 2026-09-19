#!/usr/bin/env python3
"""Converte os rótulos de um SVG exportado do draw.io em <text> de verdade.

Por que isto existe: o export SVG do draw.io não desenha texto com `<text>`.
Ele emite, para CADA rótulo, um `<switch>` com dois ramos:

  1. um `<foreignObject>` com HTML, atrás de `requiredFeatures=…Extensibility`;
  2. um `<image>` com um **PNG em base64 do rótulo rasterizado**.

Num navegador, inline no HTML, o ramo 1 vence e tudo parece bem. Dentro de uma
`<img src="…svg">` — que é o modo restrito do SVG — o `foreignObject` não
renderiza, e o navegador cai no ramo 2. O resultado medido no diagrama de
componentes do Kubernetes: **254 KB, sendo 176 KB de PNG**, texto borrado ao
ampliar, e o renderizador do Chrome congelando ao pintar os 14 rasters.

A conversão usa a geometria do próprio `<image>` (que é a caixa do texto já
renderizado) e os estilos do `<div>` interno. O resultado é vetor de verdade:
menor, nítido em qualquer zoom e legível no `git diff`.

    python3 tools/scripts/flatten-drawio-svg.py arquivo.svg

Reescreve o arquivo no lugar. Licença do original se mantém — a CC BY 4.0 pede
que a modificação seja indicada, e o `credit` da figura no site diz isso.
"""
import re
import sys
from pathlib import Path

SWITCH = re.compile(r"<switch>(.*?)</switch>", re.S)


def style(blob: str, prop: str) -> str | None:
    m = re.search(rf"{prop}\s*:\s*([^;\"]+)", blob)
    return m.group(1).strip() if m else None


def label_lines(switch_body: str) -> list[str]:
    """As linhas do rótulo, como texto puro.

    O HTML do draw.io envolve o rótulo em quantidades variáveis de <font>, <b>
    e <div> aninhados, e usa <div> (não <br>) para quebrar linha. Pegar o texto
    com uma regex rígida funciona para metade dos rótulos e falha calada na
    outra metade — foi o que aconteceu na primeira versão deste script.
    """
    start = switch_body.rfind("display: inline-block")
    if start < 0:
        return []
    start = switch_body.find(">", start)
    end = switch_body.find("</foreignObject>", start)
    if start < 0 or end < 0:
        return []
    html = switch_body[start + 1 : end]

    # Quebra de linha = abertura de <div> ou <br>; o resto das tags some.
    html = re.sub(r"<(div|br)\b[^>]*>", "\n", html, flags=re.I)
    html = re.sub(r"<[^>]+>", "", html)
    html = html.replace("&nbsp;", " ")
    return [ln.strip() for ln in html.split("\n") if ln.strip()]


def convert(switch_body: str) -> str | None:
    """Um <switch> do draw.io vira um <text>, ou None se não for reconhecido."""
    img = re.search(r'<image\s+([^>]*?)/>', switch_body)
    if not img:
        return None
    attrs = img.group(1)

    def num(name: str) -> float | None:
        m = re.search(rf'{name}="([-\d.]+)"', attrs)
        return float(m.group(1)) if m else None

    x, y, w, h = num("x"), num("y"), num("width"), num("height")
    if None in (x, y, w, h):
        return None

    lines = label_lines(switch_body)
    if not lines:
        return None

    divs = re.findall(r"<div[^>]*style=\"([^\"]*)\"[^>]*>", switch_body)
    outer = divs[0] if divs else ""
    inner = divs[-1] if divs else ""

    size = (style(inner, "font-size") or "12px").replace("px", "").strip()
    color = style(inner, "color") or "#333333"
    family = (style(inner, "font-family") or "Helvetica").split(",")[0].strip()
    # O negrito pode vir como estilo do div OU como <b>/<strong> no conteúdo.
    weight = style(inner, "font-weight") or ("bold" if re.search(r"<(b|strong)\b", switch_body) else "normal")

    # `text-align` do div de fora dá o alinhamento; a caixa do <image> é a do
    # texto já renderizado, então âncora e caixa concordam.
    align = (style(outer, "text-align") or "left").strip()
    if align == "center":
        anchor, tx = "middle", x + w / 2
    elif align == "right":
        anchor, tx = "end", x + w
    else:
        anchor, tx = "start", x

    def esc(t: str) -> str:
        return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    n = len(lines)
    spans = "".join(
        f'<tspan x="{tx:.1f}" y="{y + h * (i + 0.78) / n:.1f}">{esc(ln)}</tspan>'
        for i, ln in enumerate(lines)
    )
    return (
        f'<text fill="{color}" font-family="{family}" font-size="{size}" '
        f'font-weight="{weight}" text-anchor="{anchor}">{spans}</text>'
    )


def main() -> int:
    path = Path(sys.argv[1])
    src = path.read_text()
    before = len(src)

    converted = failed = 0

    def repl(m: re.Match) -> str:
        nonlocal converted, failed
        out = convert(m.group(1))
        if out is None:
            failed += 1
            return m.group(0)
        converted += 1
        return out

    out = SWITCH.sub(repl, src)
    path.write_text(out)

    print(f"  {converted} rótulos viraram <text>, {failed} não reconhecidos")
    print(f"  {before:,} -> {len(out):,} bytes ({100 - 100 * len(out) // before}% menor)")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
