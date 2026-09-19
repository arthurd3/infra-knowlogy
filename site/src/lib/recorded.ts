/**
 * O transporte do modo demonstração.
 *
 * A ideia é não ter dois caminhos de código. O `runGate` é o mesmo nos dois
 * modos; o que muda é só o `fetch` que ele recebe — ao vivo, o do navegador;
 * sem stack, este aqui, que devolve as respostas REAIS gravadas em
 * src/data/recorded-gate.json contra a stack deste repositório.
 *
 * Um "modo demo" escrito à parte mente cedo ou tarde, porque ninguém o
 * reexecuta. Este reencena uma execução que aconteceu — e o arquivo diz
 * quando aconteceu.
 */
import fixture from "../data/recorded-gate.json";

export type Fixture = typeof fixture;
export const recorded: Fixture = fixture;

const json = (body: string, status: number) =>
  new Response(body, { status, headers: { "content-type": "application/json" } });

/**
 * Um `fetch` que responde como a stack respondeu.
 *
 * Guarda estado entre chamadas porque o enriquecimento é assíncrono de
 * verdade: a primeira leitura vem sem título, como veio na gravação. Reproduzir
 * o "ainda não" é parte do que a lição está ensinando.
 */
export function recordedFetch(f: Fixture = fixture): typeof globalThis.fetch {
  const s = f.steps;
  let enrichReads = 0;

  return async function recordedFetchImpl(input, init) {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const path = url.replace(/^https?:\/\/[^/]+/, "");
    const method = (init?.method ?? "GET").toUpperCase();

    if (path.startsWith("/edge-health")) return new Response(null, { status: s.edge.status });

    if (method === "POST" && path.startsWith("/api/links")) {
      const body = String(init?.body ?? "");
      // O alvo interno é recusado pelo worker, não pela api: a criação
      // responde 201 igual, e o motivo aparece depois no enrich_error.
      return body.includes("169.254.169.254")
        ? json(s.ssrf.body, s.ssrf.status)
        : json(s.create.body, s.create.status);
    }

    if (path.startsWith("/api/links?") || path === "/api/links") return json(s.list.body, s.list.status);

    if (path.startsWith(`/api/links/${s.create.code}`)) {
      enrichReads += 1;
      if (enrichReads < s.enrich.tries) {
        return json(s.enrich.body.replace(/"title":"[^"]*"/, '"title":null'), 200);
      }
      return json(s.enrich.body, s.enrich.status);
    }

    if (path.startsWith("/api/links/")) return json(s.ssrf.body, 200);

    if (path.startsWith(`/r/`)) {
      return new Response(null, {
        status: s.redirect.status,
        headers: { location: s.redirect.location },
      });
    }

    if (path === "/" || path === "") {
      return new Response("<!doctype html><title>infra-knowlogy</title>", {
        status: s.site.status,
        headers: { "content-type": s.site.contentType },
      });
    }

    return new Response("not found", { status: 404 });
  };
}
