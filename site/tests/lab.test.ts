import { describe, expect, it } from "vitest";
import { shorten, validate, type LabState } from "../src/lib/lab";

/** O fluxo do laboratório interativo das lições. */

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

function stackFetch(enrichment: Record<string, unknown>) {
  return async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if ((init?.method ?? "GET") === "POST") return json({ code: "K9x2", short_url: "http://h/r/K9x2" }, 201);
    if (url.includes("/r/")) return new Response(null, { status: 302, headers: { location: "https://example.com/" } });
    return json({ code: "K9x2", title: null, enrich_error: null, ...enrichment });
  };
}

const deps = (f: typeof globalThis.fetch) => ({ fetch: f, sleep: async () => {} });

describe("validate", () => {
  it("aceita http e https absolutos", () => {
    expect(validate("https://example.com/")).toBeNull();
    expect(validate("http://example.com/a?b=c")).toBeNull();
  });

  it("recusa o que a api recusaria com 422", () => {
    expect(validate("example.com")).toBe("invalid");
    expect(validate("ftp://example.com")).toBe("scheme");
    expect(validate("file:///etc/passwd")).toBe("scheme");
    // O leitor não deve descobrir que errou só depois de uma ida à rede.
    expect(validate("   ")).toBe("invalid");
  });
});

describe("shorten", () => {
  it("percorre criar -> redirect -> enriquecer e termina em done", async () => {
    const phases: LabState["phase"][] = [];
    const final = await shorten(
      "", "https://example.com/",
      deps(stackFetch({ title: "Example Domain" }) as typeof globalThis.fetch),
      (s) => phases.push(s.phase),
      { interval: 0 },
    );
    expect(phases).toContain("creating");
    expect(phases).toContain("redirecting");
    expect(phases).toContain("enriching");
    expect(final.phase).toBe("done");
    expect(final).toMatchObject({ code: "K9x2", redirected: true, title: "Example Domain", tries: 1 });
  });

  it("mostra o motivo do bloqueio em vez de um título vazio", async () => {
    const final = await shorten(
      "", "http://169.254.169.254/latest/meta-data/",
      deps(stackFetch({ enrich_error: "bloqueado: endereço interno" }) as typeof globalThis.fetch),
      () => {},
      { interval: 0 },
    );
    expect(final.phase).toBe("done");
    expect(final.title).toBeNull();
    expect(final.enrichError).toBe("bloqueado: endereço interno");
  });

  it("termina sem título quando o worker não responde a tempo", async () => {
    const final = await shorten(
      "", "https://example.com/",
      deps(stackFetch({}) as typeof globalThis.fetch),
      () => {},
      { attempts: 3, interval: 0 },
    );
    expect(final.phase).toBe("done");
    expect(final.title).toBeNull();
    expect(final.enrichError).toBeNull();
    expect(final.tries).toBe(3);
  });

  it("vira estado de erro, não exceção, quando a api recusa", async () => {
    const f = async () => json({ error: "url precisa ser http(s) absoluta" }, 422);
    const final = await shorten("", "https://x/", deps(f as typeof globalThis.fetch), () => {}, { interval: 0 });
    expect(final.phase).toBe("error");
    expect(final.error).toContain("http(s)");
  });

  it("vira estado de erro quando a rede cai no meio", async () => {
    const f = async () => { throw new TypeError("Failed to fetch"); };
    const final = await shorten("", "https://x/", deps(f as unknown as typeof globalThis.fetch), () => {}, { interval: 0 });
    expect(final.phase).toBe("error");
  });
});
