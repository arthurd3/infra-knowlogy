# Módulo 2: Kubernetes

A stack do módulo Docker — encurtador Go, worker Python, site Astro, Caddy,
Postgres, Redis — portada para um cluster **kind**, como o ADR 0001 prescreveu:
a mesma aplicação, as mesmas imagens, o mesmo Caddyfile. As decisões do porte
(kind, sem ingress controller, YAML puro, portão separado) estão no
[ADR 0007](../docs/adr/0007-kind-e-o-porte-para-kubernetes.md).

```bash
make k8s-prereqs   # checa kind (>= 0.23!) e kubectl; diz como instalar
make k8s-up        # cluster + imagens + manifests -> http://127.0.0.1:8081
make k8s-verify    # o portão: 33 checagens, do zero, e destrói o cluster
make k8s-down      # apaga o cluster
```

A porta é **8081** de propósito: a stack Compose continua dona da 8080, e as
lições comparam as duas rodando ao mesmo tempo.

## Layout

```
kind/kind-config.yaml   # nó pinado por digest; NodePort 30080 -> 127.0.0.1:8081
base/
├── kustomization.yaml  # kubectl apply -k aplica tudo
├── <serviço>/          # deployment/statefulset + service por serviço
└── network-policies/   # o espelho das redes edge/data/egress do Compose
```

O Secret do Postgres e os ConfigMaps (Caddyfile, SQL de init) **não são
versionados**: o `k8s-up.sh` os gera a partir dos arquivos de `stack/` — fonte
única, zero drift. O kubeconfig vai para `k8s/.kubeconfig` (ignorado pelo git);
nada aqui toca o `~/.kube/config`.

## O que o k8s-verify prova

O mesmo contrato do `verify.sh`: cada afirmação das lições da trilha
`kubernetes` é uma checagem que falha alto. Além do espelho do módulo 1 (smoke
test completo com SSRF, segmentação de rede, hardening, segredo fora do env,
desligamento gracioso), o portão mede o que o Compose não faz — auto-cura,
restart contado, readiness sem restart e rolling update com zero requisições
derrubadas — e grava os números em `site/src/data/k8s-measured.json`, que as
lições citam. Estado bom conhecido: **33 passaram · 0 falharam**.

Para iterar sem recriar o cluster: `KEEP_CLUSTER=1 make k8s-verify`.
