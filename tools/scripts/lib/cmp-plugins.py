#!/usr/bin/env python3
# Compara os plugins ATIVOS no controller com o que plugins.txt pina.
#
# Sai não-zero em qualquer divergência: plugin com falha, inativo, em versão
# diferente, pinado e ausente, ou instalado sem estar no pin. O último caso é
# o que pega dependência transitiva escapando do fecho.
#
#   curl .../pluginManager/api/json?depth=1 | cmp-plugins.py cicd/controller/plugins.txt
import json, pathlib, sys

inst = {p["shortName"]: p for p in json.load(sys.stdin)["plugins"]}
pin = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        n, _, v = line.partition(":")
        pin[n] = v

falhou = sorted(n for n, p in inst.items() if p.get("failed"))
inativo = sorted(n for n, p in inst.items() if not p.get("active"))
diverg = sorted(f"{n} pinado={v} instalado={inst[n]['version']}"
                for n, v in pin.items() if n in inst and inst[n]["version"] != v)
faltando = sorted(set(pin) - set(inst))
extra = sorted(set(inst) - set(pin))

print(f"  instalados={len(inst)}  pinados={len(pin)}")
for rotulo, lista in (("com falha", falhou), ("inativos", inativo),
                      ("divergentes", diverg), ("pinado e ausente", faltando),
                      ("instalado fora do pin", extra)):
    print(f"  {rotulo:24} {lista or 'nenhum'}")
sys.exit(1 if (falhou or diverg or faltando or extra) else 0)
