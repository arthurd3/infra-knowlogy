# 0002 — Caddy em vez de Traefik

**Estado:** aceita · **Data:** 2026-08-31

## Contexto

A stack precisa de um proxy reverso: TLS, roteamento de `/api` e `/r` para a API,
e o restante para o site estático. Traefik é a escolha mais popular em ambientes
Docker por causa da descoberta automática de serviços via labels.

## Decisão

Usar **Caddy** com configuração estática (`services/edge/Caddyfile`).

A razão decisiva é de segurança e é específica deste repositório: **o mecanismo
que torna o Traefik conveniente é montar `/var/run/docker.sock`**. Quem alcança o
socket do Docker pode criar um container privilegiado montando `/` do host — ou
seja, o socket é equivalente a root no host. Isso é literalmente a Regra #1 do
OWASP Docker Security Cheat Sheet.

Um repositório cujo objetivo declarado é ensinar segurança de containers não pode
violar a primeira regra do checklist na porta de entrada da própria stack, e
depois pedir que o leitor faça diferente.

Como bônus, o Caddy emite e renova certificados ACME sozinho, com duas linhas de
configuração.

## Consequências

- Adicionar um serviço exige **editar o Caddyfile**. Com Traefik bastaria uma
  label. Isso é trabalho manual real, e nós o aceitamos.
- Em compensação, o roteamento fica legível num arquivo só, versionado, em vez de
  espalhado por labels de seis serviços.
- Nenhum container da stack padrão (`make up`) toca o socket do Docker.

## Alternativas consideradas

- **Traefik + docker-socket-proxy.** Seria defensável — e é exatamente o que
  fazemos para o Alloy no profile de observabilidade (ver
  [0003](0003-socket-do-docker-na-observabilidade.md)). Recusada para o proxy
  porque acrescenta um serviço permanente ao caminho crítico para resolver um
  problema (descoberta dinâmica) que uma stack de seis serviços não tem.
- **Nginx.** Recusada: TLS automático exigiria certbot e um cron, três peças
  móveis onde o Caddy tem zero.
