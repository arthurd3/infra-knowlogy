# infra-knowlogy — Module 1: Docker

> **A production Docker stack that actually runs — and the lessons that explain
> every decision in it.**

The principle tying the whole repository together: **the lessons teach exactly
the code that is here, with numbers measured on this machine.** No generic blog
examples. When the base-image lesson shows a size table, those bytes came from
`docker image inspect` run against these Dockerfiles by `tools/scripts/sizes.sh`.

And the site that teaches multi-stage builds is served by the very multi-stage
Dockerfile it explains.

> A note on languages, so nothing surprises you: the **lessons are bilingual** —
> every one exists in English and Portuguese. This README is English. The **code
> comments and the ADRs are written in Portuguese**: they are the author's
> internal engineering notes, not teaching material. Identifiers, file names and
> URL slugs are always English.

## Start here

```bash
make            # list everything you can do
make up         # bring up the hardened stack and wait for every healthcheck
make site-dev   # open the lessons at http://localhost:4321
make verify     # the quality gate: build, boot, test, and prove the hardening
```

Requirements: Docker 25+ with BuildKit, Docker Compose v2+, Node 22+ (site only),
and `uv` (for `make index` only). Developed and tested on Fedora with SELinux
enforcing.

## The stack

A link shortener with asynchronous enrichment. Small enough to read end to end,
complete enough to exercise everything the lessons need to teach.

```
                    127.0.0.1:8080
                          │
                    ┌─────▼─────┐
                    │   edge    │  Caddy · automatic TLS · never touches the socket
                    └──┬─────┬──┘
              edge net  │     │
                 ┌──────▼─┐ ┌─▼──────┐
                 │  web   │ │  api   │  Go · distroless · 5.7 MB
                 └────────┘ └───┬────┘
                                │  data net (internal: true — NO egress)
                      ┌─────────┼─────────┐
                 ┌────▼───┐ ┌───▼────┐ ┌──▼─────┐
                 │   db   │ │ cache  │ │ worker │  Python · uv · 49.9 MB
                 └────────┘ └────────┘ └───┬────┘
                  Postgres    Redis        │ egress net
                                           ▼ fetches URLs (with an SSRF guard)
```

Look at the network layout: `db` and `cache` sit **only** on the `data` network,
which is `internal: true` — they have no route to the internet, and the proxy
literally cannot reach them. It is an absence of route, not a firewall rule.
`worker` is the studied exception, because it must fetch user-submitted URLs;
that is why its code carries an SSRF guard.

| Service | Language | Final image | What it teaches |
|---|---|---|---|
| `api-go` | Go | 5.7 MB (distroless) | static binary, `scratch`, CA certs, graceful shutdown |
| `worker-py` | Python | 49.9 MB (slim + venv) | multi-stage with `uv`, SIGTERM in a work loop, SSRF |
| `web` | Node → static | 26.2 MB (Caddy) | a build that discards its own runtime |
| `edge` | — | Caddy | reverse proxy without touching the Docker socket |
| `db` / `cache` | — | Postgres 17 / Redis 7 | volumes, healthchecks, `service_healthy` |

`make obs` adds Prometheus, Grafana, Loki, Alloy, cAdvisor, node-exporter and two
exporters — behind the `obs` profile, so day-to-day work still comes up in
seconds instead of paying for fifteen containers.

## The lessons

16 lessons — 8 topics, in English and Portuguese — under
`site/src/content/lessons/`, with three interactive widgets that run entirely in
the browser (the site stays 100% static and deployable anywhere).

**Fundamentals track:** what a container actually is · images, layers and digests
· the Dockerfile instruction by instruction · the build cache · lifecycle and
exit codes · volumes, bind mounts and tmpfs · networks and internal DNS · Compose
and healthchecks.

Every lesson ends with a **"Run it yourself"** block — real commands against this
repository's stack, not pseudocode.

Some claims were **measured, and corrected the common wisdom**. For example: the
widespread explanation that `CMD`'s shell form breaks `docker stop` is
incomplete — BusyBox `exec`s a simple command, so `sleep` becomes PID 1 either
way, and *both* forms burn the full ten seconds. The real cause is that **the
kernel applies no default signal dispositions to PID 1**. Lesson 3 carries all
four cases, timed.

## Verification

`make verify` runs nine stages and fails loudly. It does not merely check that
the code compiles — it **proves the lessons' claims**:

- `hadolint` on every Dockerfile, and `config -q` on all three Compose combinations;
- build everything, and rewrite the measured sizes into `measured.json`;
- `up --wait`, which only passes when every healthcheck passes;
- smoke test of the real flow: create a link → 302 redirect → the worker enriches
  it → **an internal URL is rejected by the SSRF guard**;
- hardening proofs: writing to `/` **fails**, the declared `/tmp` works, the uid
  is 65532, no port is bound to `0.0.0.0`, the secret appears in neither
  `docker history` nor `env`, and `edge` **cannot reach** `db`;
- graceful shutdown — fails if any service takes longer than 3 s to stop;
- Trivy failing on HIGH/CRITICAL, with a CycloneDX SBOM per image;
- site build and **EN/PT parity** (no lesson may exist in only one language);
- with the `obs` profile, every Prometheus target must be `up`.

Current state: **30 passed · 0 failed**.

For faster local iteration: `SKIP_SCAN=1 SKIP_OBS=1 make verify`.

## Layout

```
stack/          production code: compose + services/{api-go,worker-py,edge,db,observability}
site/           the bilingual lessons site (Astro + MDX + React islands)
tools/scripts/  verify · sizes · scan · shutdown-test · update-pins · index-qdrant
docs/adr/       why Compose and not k8s, why Caddy and not Traefik, and the rest
```

Decisions and the alternatives that were **rejected** live in
[`docs/adr/`](docs/adr/) — six records, written in Portuguese. `CLAUDE.md`
records the conventions and the traps
already hit — SELinux and Compose secrets, `cap_drop` breaking `exec()` on a
binary with file capabilities, `build:` without `target:` shipping the wrong
stage — so they are not rediscovered the hard way.

## License

MIT.
