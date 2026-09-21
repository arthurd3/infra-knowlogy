#!/usr/bin/env python3
"""Prova que o chart Helm e o overlay Kustomize produzem o MESMO objeto.

A pergunta "Helm ou Kustomize?" costuma ser respondida com adjetivos. Este
script troca os adjetivos por um diff: renderiza os dois, isola o Deployment e
o Service do `web`, e mostra exatamente onde divergem — se divergirem.

Quando o diff é vazio, a frase "as duas ferramentas resolvem o mesmo problema"
deixa de ser opinião. E quando não é, a diferença fica com nome e caminho de
campo, que é onde a escolha entre as duas realmente mora.

Uso:  python3 tools/scripts/k8s-helm-vs-kustomize.py [--json]
"""
import json, os, subprocess, sys

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELM_IMG = "alpine/helm:3.19.0@sha256:aef9b56f64e866207d9591d0abd8f6d767b36aadd12edf68f8a719716d9d29c9"
INTERESSA = {("apps/v1", "Deployment", "web"), ("v1", "Service", "web")}


def render_helm():
    # `:ro,z` e não só `:ro` — sem o sufixo de relabel do SELinux o container
    # recebe permission denied e o helm reporta "Chart.yaml file is missing",
    # que manda você procurar o erro no lugar errado (armadilha 2).
    return subprocess.run(
        ["docker", "run", "--rm", "-v", f"{RAIZ}/k8s/charts:/charts:ro,z",
         # `--namespace` e não um valor fixo no chart: é assim que o Helm
         # expressa o que o `namespace:` do kustomization.yaml expressa. Sem
         # a flag, `helm template` renderiza com o namespace "default" e o
         # diff acusa uma diferença que é de invocação, não de conteúdo.
         HELM_IMG, "template", "web", "/charts/web",
         "--namespace", "infra-knowlogy"],
        capture_output=True, text=True, check=True).stdout


def render_kustomize():
    return subprocess.run(["kubectl", "kustomize", "k8s/base"],
                          capture_output=True, text=True, check=True, cwd=RAIZ).stdout


def objetos(texto):
    import yaml
    saida = {}
    for doc in yaml.safe_load_all(texto):
        if not doc:
            continue
        chave = (doc.get("apiVersion"), doc.get("kind"),
                 doc.get("metadata", {}).get("name"))
        if chave in INTERESSA:
            saida[chave] = doc
    return saida


def normalizar(doc):
    """Tira o que é ruído de FERRAMENTA, e só isso.

    O Helm carimba `app.kubernetes.io/managed-by: Helm` e anotações de release;
    o Kustomize pode carimbar rótulos comuns do overlay. Nada disso é o objeto
    — é a assinatura de quem o gerou. Comparar sem tirar seria comparar as
    ferramentas, não o resultado.

    Tudo o mais fica: se um dos dois muda uma probe ou uma capability, o diff
    tem que aparecer.
    """
    import copy
    d = copy.deepcopy(doc)
    meta = d.setdefault("metadata", {})
    for campo in ("annotations", "creationTimestamp"):
        meta.pop(campo, None)
    rot = meta.get("labels", {})
    for k in list(rot):
        if k.startswith("app.kubernetes.io/") or k.startswith("helm.sh/"):
            rot.pop(k)
    if not rot:
        meta.pop("labels", None)
    return d


def diferencas(a, b, caminho=""):
    if type(a) is not type(b):
        return [f"{caminho}: {type(a).__name__} vs {type(b).__name__}"]
    if isinstance(a, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"{caminho}.{k}: só no Kustomize ({b[k]!r})")
            elif k not in b:
                out.append(f"{caminho}.{k}: só no Helm ({a[k]!r})")
            else:
                out += diferencas(a[k], b[k], f"{caminho}.{k}")
        return out
    if isinstance(a, list):
        if len(a) != len(b):
            return [f"{caminho}: {len(a)} itens no Helm, {len(b)} no Kustomize"]
        return [d for i, (x, y) in enumerate(zip(a, b))
                for d in diferencas(x, y, f"{caminho}[{i}]")]
    return [] if a == b else [f"{caminho}: {a!r} (Helm) vs {b!r} (Kustomize)"]


def main():
    h, k = objetos(render_helm()), objetos(render_kustomize())
    faltando = [f"{c[1]}/{c[2]}" for c in INTERESSA if c not in h or c not in k]
    todas = []
    for chave in sorted(INTERESSA - set(faltando and INTERESSA or [])):
        if chave in h and chave in k:
            todas += diferencas(normalizar(h[chave]), normalizar(k[chave]),
                                f"{chave[1]}/{chave[2]}")

    res = {"objetosComparados": len([c for c in INTERESSA if c in h and c in k]),
           "faltando": faltando, "diferencas": todas, "identicos": not todas and not faltando}
    if "--json" in sys.argv:
        print(json.dumps(res, ensure_ascii=False))
    else:
        if res["identicos"]:
            print(f"   idênticos: {res['objetosComparados']} objetos, 0 diferenças")
        else:
            for f in faltando:
                print(f"   FALTANDO em um dos dois: {f}")
            for d in todas:
                print(f"   {d}")
    return 0 if res["identicos"] else 1


if __name__ == "__main__":
    sys.exit(main())
