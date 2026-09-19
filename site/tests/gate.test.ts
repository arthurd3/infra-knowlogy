import { describe, expect, it } from "vitest";
import {
  idleSteps, probe, runGate, snippet, STEP_IDS, type Step,
} from "../src/lib/gate";

/**
 * O portão do navegador, testado sem navegador e sem stack.
 *
 * Cada caso aqui corresponde a uma falha que já aconteceu ou que aconteceria
 * em produção: uma api que devolve HTML de 404 com status 200, um redirect
 * que sumiu, um SSRF que passou. O `fetch` entra por parâmetro, então dá para
 * encenar qualquer um deles em milissegundos.
 */

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const html = (status = 200) =>
  new Response("<!doctype html><title>404</title>", {
    status,
    headers: { "content-type": "text/html; charset=utf-8" },
  });

/** Um fetch falso que responde como a stack sadia responde. */
function healthyFetch(overrides: Record<string, () => Response> = {}) {
  let enrichReads = 0;
  return async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const method = (init?.method ?? "GET").toUpperCase();
    for (const [pattern, fn] of Object.entries(overrides)) {
      if (url.includes(pattern)) return fn();
    }
    if (url.includes("/edge-health")) return new Response(null, { status: 204 });
    if (method === "POST" && url.includes("/api/links")) {
      const body = String(init?.body ?? "");
      return body.includes("169.254.169.254")
        ? json({ code: "SSRF001", url: "http://169.254.169.254/latest/meta-data/" }, 201)
        : json({ code: "ABC1234", short_url: "http://localhost:8080/r/ABC1234" }, 201);
    }
    if (url.includes("/api/links?") || url.endsWith("/api/links")) return json({ links: [], count: 0 });
    if (url.includes("/api/links/SSRF001")) {
      return json({ code: "SSRF001", title: null, enrich_error: "bloqueado: endereço interno" });
    }
    if (url.includes("/api/links/ABC1234")) {
      enrichReads += 1;
      return json({ code: "ABC1234", title: enrichReads >= 2 ? "Example Domain" : null, enrich_error: null });
    }
    if (url.includes("/r/")) return new Response(null, { status: 302, headers: { location: "https://example.com/" } });
    return html();
  };
}

const deps = (fetchImpl: typeof globalThis.fetch, steps: Step[] = []) => ({
  fetch: fetchImpl,
  sleep: async () => {},
  now: () => 0,
  onStep: (s: Step) => { steps.push(s); },
});

describe("runGate", () => {
  it("aprova os sete passos contra uma stack sadia", async () => {
    const result = await runGate("", deps(healthyFetch() as typeof globalThis.fetch), { interval: 0 });
    expect(result.fail, JSON.stringify(result.steps.filter((s) => s.status === "fail"), null, 1)).toBe(0);
    expect(result.pass).toBe(STEP_IDS.length);
    expect(result.steps.map((s) => s.id)).toEqual(STEP_IDS);
  });

  it("conta o número de leituras até o worker enriquecer", async () => {
    const result = await runGate("", deps(healthyFetch() as typeof globalThis.fetch), { interval: 0 });
    const enrich = result.steps.find((s) => s.id === "enrich")!;
    expect(enrich.messageKey).toBe("enrich.ok");
    expect(enrich.values).toMatchObject({ title: "Example Domain", tries: 2 });
  });

  it("reprova quando a api devolve HTML com status 200", async () => {
    // O caso real: servido pelo container `web` sozinho, /api/links cai no
    // try_files do Caddy e volta a página de 404 — com status 200. Confiar em
    // res.ok daria "stack no ar" numa página estática qualquer.
    const f = healthyFetch({ "/api/links?": () => html(200) });
    const result = await runGate("", deps(f as typeof globalThis.fetch), { interval: 0 });
    const list = result.steps.find((s) => s.id === "list")!;
    expect(list.status).toBe("fail");
    expect(list.messageKey).toBe("list.notJson");
  });

  it("reprova, sem falsa aprovação, quando o redirect some", async () => {
    const f = healthyFetch({ "/r/": () => json({ error: "link não encontrado" }, 404) });
    const result = await runGate("", deps(f as typeof globalThis.fetch), { interval: 0 });
    const redirect = result.steps.find((s) => s.id === "redirect")!;
    expect(redirect.status).toBe("fail");
    expect(redirect.values.status).toBe(404);
  });

  it("reprova quando o SSRF NÃO é bloqueado", async () => {
    // O pior resultado possível: o link interno foi enriquecido com sucesso.
    const f = healthyFetch({
      "/api/links/SSRF001": () => json({ code: "SSRF001", title: "instance metadata", enrich_error: null }),
    });
    const result = await runGate("", deps(f as typeof globalThis.fetch), { attempts: 2, interval: 0 });
    const ssrf = result.steps.find((s) => s.id === "ssrf")!;
    expect(ssrf.status).toBe("fail");
    expect(ssrf.messageKey).toBe("ssrf.timeout");
  });

  it("aceita o bloqueio em inglês tanto quanto em português", async () => {
    const f = healthyFetch({
      "/api/links/SSRF001": () => json({ enrich_error: "blocked: internal address" }),
    });
    const result = await runGate("", deps(f as typeof globalThis.fetch), { interval: 0 });
    expect(result.steps.find((s) => s.id === "ssrf")!.status).toBe("pass");
  });

  it("pula os passos dependentes em vez de empilhar falhas derivadas", async () => {
    // Uma causa, uma falha. Reportar quatro falhas para um POST que não passou
    // é o mesmo erro de contar "scanner quebrou" como "achou CVE".
    const f = healthyFetch({ "/api/links": () => json({ error: "erro interno" }, 500) });
    const result = await runGate("", deps(f as typeof globalThis.fetch), { interval: 0 });
    for (const id of ["redirect", "enrich", "ssrf"] as const) {
      expect(result.steps.find((s) => s.id === id)!.messageKey).toBe("skipped.noCode");
    }
  });

  it("transforma erro de rede em falha, não em exceção", async () => {
    const boom = async () => { throw new TypeError("Failed to fetch"); };
    const result = await runGate("", deps(boom as unknown as typeof globalThis.fetch), { interval: 0 });
    expect(result.pass).toBe(0);
    expect(result.steps.find((s) => s.id === "edge")!.messageKey).toBe("net.error");
  });

  it("emite uma transição para cada passo, começando por running", async () => {
    const seen: Step[] = [];
    await runGate("", deps(healthyFetch() as typeof globalThis.fetch, seen), { interval: 0 });
    for (const id of STEP_IDS) {
      const forId = seen.filter((s) => s.id === id);
      expect(forId.length, `nenhuma transição para ${id}`).toBeGreaterThan(0);
      expect(forId[0].status).toBe("running");
      expect(["pass", "fail"]).toContain(forId.at(-1)!.status);
    }
  });
});

describe("probe", () => {
  it("diz online quando o edge responde e a api devolve JSON", async () => {
    expect(await probe("", healthyFetch() as typeof globalThis.fetch)).toBe("online");
  });

  it("diz edge-only quando o proxy está de pé mas a api não", async () => {
    const f = healthyFetch({ "/api/links": () => new Response("bad gateway", { status: 502 }) });
    expect(await probe("", f as typeof globalThis.fetch)).toBe("edge-only");
  });

  it("diz offline num site estático que devolve a página de 404 com 200", async () => {
    const f = async () => html(200);
    expect(await probe("", f as typeof globalThis.fetch)).toBe("offline");
  });

  it("diz offline quando a rede falha", async () => {
    const f = async () => { throw new TypeError("Failed to fetch"); };
    expect(await probe("", f as unknown as typeof globalThis.fetch)).toBe("offline");
  });
});

describe("apresentação", () => {
  it("idleSteps devolve um passo por id, em ordem e ocioso", () => {
    const steps = idleSteps();
    expect(steps.map((s) => s.id)).toEqual(STEP_IDS);
    expect(steps.every((s) => s.status === "idle")).toBe(true);
    expect(steps.every((s) => s.request.length > 0)).toBe(true);
  });

  it("snippet corta o texto longo e marca que cortou", () => {
    expect(snippet("curto")).toBe("curto");
    const long = "x".repeat(400);
    expect(snippet(long, 20)).toHaveLength(21);
    expect(snippet(long, 20).endsWith("…")).toBe(true);
  });
});
