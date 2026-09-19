/**
 * O fluxo do encurtador, passo a passo, para o widget interativo.
 *
 * Mesma disciplina do gate.ts: nenhuma dependência de React, de texto ou do
 * `fetch` global. Quem chama injeta o transporte — o do navegador ao vivo, o
 * gravado sem stack, um falso nos testes.
 */
import { readJson, snippet } from "./gate";

export interface LabDeps {
  fetch: typeof globalThis.fetch;
  sleep: (ms: number) => Promise<void>;
}

export interface LabState {
  /** Onde o fluxo está agora — a interface mostra isto enquanto roda. */
  phase: "idle" | "creating" | "redirecting" | "enriching" | "done" | "error";
  url: string;
  code?: string;
  shortUrl?: string;
  /** Houve 3xx? O navegador esconde o número; ver o comentário em gate.ts. */
  redirected?: boolean;
  title?: string | null;
  enrichError?: string | null;
  tries?: number;
  raw?: string;
  error?: string;
}

/** Recusa cedo o que a api recusaria com 422, para o erro chegar mais rápido. */
export function validate(url: string): string | null {
  let parsed: URL;
  try {
    parsed = new URL(url.trim());
  } catch {
    return "invalid";
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return "scheme";
  if (!parsed.host) return "host";
  return null;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}

/**
 * Cria o link, confirma o redirect e espera o worker — avisando a cada etapa.
 *
 * O enriquecimento é assíncrono de propósito na aplicação: a api responde
 * assim que grava, e o worker busca o título depois. O widget mostra isso
 * como é, com as tentativas contadas, em vez de fingir que foi instantâneo.
 */
export async function shorten(
  base: string,
  url: string,
  deps: LabDeps,
  onState: (s: LabState) => void,
  opts: { attempts?: number; interval?: number } = {},
): Promise<LabState> {
  // Ver o comentário em gate.ts: `call(...)` passa o objeto deps como
  // `this` e o fetch do navegador recusa com "Illegal invocation".
  const call = deps.fetch;
  const attempts = opts.attempts ?? 12;
  const interval = opts.interval ?? 1000;
  let state: LabState = { phase: "creating", url };
  const emit = (patch: Partial<LabState>) => {
    state = { ...state, ...patch };
    onState(state);
    return state;
  };
  emit({});

  try {
    const res = await call(`${base}/api/links`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ url }),
    });
    const { json, raw } = await readJson(res);
    if (res.status !== 201 || !isRecord(json) || typeof json.code !== "string") {
      const reason = isRecord(json) && typeof json.error === "string" ? json.error : `HTTP ${res.status}`;
      return emit({ phase: "error", error: reason, raw: snippet(raw) });
    }

    emit({
      phase: "redirecting",
      code: json.code,
      shortUrl: typeof json.short_url === "string" ? json.short_url : `${base}/r/${json.code}`,
      raw: snippet(raw),
    });

    const hop = await call(`${base}/r/${json.code}`, { redirect: "manual" });
    emit({
      phase: "enriching",
      redirected: hop.type === "opaqueredirect" || (hop.status >= 300 && hop.status < 400),
    });

    for (let i = 1; i <= attempts; i++) {
      const look = await call(`${base}/api/links/${json.code}`);
      const { json: got, raw: gotRaw } = await readJson(look);
      if (isRecord(got)) {
        const title = typeof got.title === "string" ? got.title : null;
        const enrichError = typeof got.enrich_error === "string" ? got.enrich_error : null;
        if (title || enrichError) {
          return emit({ phase: "done", title, enrichError, tries: i, raw: snippet(gotRaw) });
        }
      }
      await deps.sleep(interval);
    }
    return emit({ phase: "done", title: null, enrichError: null, tries: attempts });
  } catch (err) {
    return emit({ phase: "error", error: err instanceof Error ? err.message : String(err) });
  }
}
