/**
 * O portão, rodando no navegador.
 *
 * Estas checagens são as MESMAS de tools/scripts/lib/smoke.sh — criar link,
 * 302, worker enriquece, SSRF recusado — só que disparadas pelo `fetch` da
 * página em vez de pelo `curl` do terminal. Dá para fazer isso sem nenhuma
 * mudança de infraestrutura porque o edge (Caddy) serve o site e a api na
 * MESMA origem: `/api/*` e `/r/*` vão para a api, o resto para o site. Sem
 * CORS, sem servidor novo.
 *
 * O módulo é de propósito sem React, sem texto e sem `fetch` global: tudo que
 * ele toca entra por parâmetro. É o que torna cada passo testável com um fetch
 * falso, sem subir a stack (ver tests/gate.test.ts).
 */

export type Status = "idle" | "running" | "pass" | "fail";

/** Um passo do portão, do jeito que a interface precisa mostrar. */
export interface Step {
  id: StepId;
  /** O que a checagem fez, em forma de requisição HTTP. */
  request: string;
  status: Status;
  /** Chave de mensagem — quem traduz é a ilha, não este módulo. */
  messageKey: string;
  /** Valores para interpolar na mensagem. */
  values: Record<string, string | number>;
  /** Trecho cru da resposta, para o leitor ver o que voltou de verdade. */
  body?: string;
  ms?: number;
}

/**
 * O que a função de um passo devolve.
 *
 * O tipo é explícito, e cada callback abaixo o anota no retorno, porque sem
 * isso o TypeScript une os literais de sucesso e de falha e inventa
 * propriedades `count?: undefined` — que não cabem em
 * Record<string, string | number>. Anotar força a checagem literal a literal.
 */
export interface StepOutcome {
  status: "pass" | "fail";
  messageKey: string;
  values: Record<string, string | number>;
  body?: string;
}

export type StepId = "edge" | "list" | "create" | "redirect" | "enrich" | "ssrf" | "site";

export const STEP_IDS: StepId[] = ["edge", "list", "create", "redirect", "enrich", "ssrf", "site"];

export interface Deps {
  fetch: typeof globalThis.fetch;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
  /** Chamado a cada mudança de estado de um passo. */
  onStep: (step: Step) => void;
}

export interface GateOptions {
  /** URL a encurtar no teste. Precisa ser http(s) absoluta. */
  target?: string;
  /** Quantas tentativas de poll antes de desistir do worker. */
  attempts?: number;
  /** Intervalo entre tentativas, em ms. */
  interval?: number;
}

/** O endereço interno que a defesa contra SSRF precisa recusar. */
export const SSRF_TARGET = "http://169.254.169.254/latest/meta-data/";

const DEFAULTS = { target: "https://example.com/", attempts: 15, interval: 1000 };

/** Corta a resposta para caber na tela sem esconder que foi cortada. */
export function snippet(text: string, max = 220): string {
  const clean = text.trim();
  return clean.length <= max ? clean : `${clean.slice(0, max)}…`;
}

/**
 * Lê o corpo como JSON, mas só aceita se for JSON mesmo.
 *
 * Isto não é preciosismo: servido pelo container `web` sozinho, um GET em
 * /api/links cai no `try_files … /404.html` do Caddy do site e volta HTML com
 * status 200. Confiar em `res.ok` daria "stack no ar" numa página estática.
 */
export async function readJson(res: Response): Promise<{ json: unknown; raw: string }> {
  const raw = await res.text();
  try {
    return { json: JSON.parse(raw), raw };
  } catch {
    return { json: null, raw };
  }
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}

/**
 * A stack está atrás desta origem?
 *
 *   online    — o edge responde E a api devolve JSON: dá para rodar tudo.
 *   edge-only — o proxy está de pé mas a api não responde. É o estado que a
 *               lição de readiness descreve: o /readyz da api diria
 *               "degraded" — só que o edge NÃO publica /readyz, de propósito
 *               (rota de saúde não é superfície pública). Daqui só dá para
 *               observar o sintoma, que é a api não responder.
 *   offline   — nada de stack: página estática servida de qualquer lugar.
 *
 * O teste usa `/api/links?limit=1` e não uma rota de saúde porque é o que o
 * edge expõe — e, de quebra, ele exercita o caminho api → Postgres, que é o
 * que realmente importa saber antes de oferecer um botão que escreve.
 */
export async function probe(
  base: string,
  fetchFn: typeof globalThis.fetch,
): Promise<"online" | "edge-only" | "offline"> {
  let edge = false;
  try {
    const res = await fetchFn(`${base}/edge-health`);
    // 204 EXATO, e não `res.ok`. O Caddyfile do edge responde `respond 204`
    // nesta rota; um host estático qualquer responde a página de 404 com
    // status 200 (try_files … /404.html), e aceitar qualquer 2xx faria o
    // widget anunciar "o proxy está de pé" em cima de um site sem proxy
    // nenhum. Um teste pegou exatamente isso.
    edge = res.status === 204;
  } catch {
    return "offline";
  }
  try {
    const res = await fetchFn(`${base}/api/links?limit=1`, { headers: { accept: "application/json" } });
    const { json } = await readJson(res);
    if (isRecord(json) && typeof json.count === "number") return "online";
  } catch {
    /* cai para o veredito do edge */
  }
  return edge ? "edge-only" : "offline";
}

/** Passo pendente, antes de rodar. */
export function idleStep(id: StepId, target = DEFAULTS.target): Step {
  const requests: Record<StepId, string> = {
    edge: "GET /edge-health",
    list: "GET /api/links?limit=1",
    create: `POST /api/links  {"url":"${target}"}`,
    redirect: "GET /r/{code}",
    enrich: "GET /api/links/{code}",
    ssrf: `POST /api/links  {"url":"${SSRF_TARGET}"}`,
    site: "GET /",
  };
  return { id, request: requests[id], status: "idle", messageKey: `${id}.idle`, values: {} };
}

export function idleSteps(target = DEFAULTS.target): Step[] {
  return STEP_IDS.map((id) => idleStep(id, target));
}

/**
 * Roda o portão inteiro, em ordem, avisando a cada transição.
 *
 * Os passos que dependem do `code` são pulados quando a criação falha — sem
 * isso o relatório encheria de falhas derivadas de UMA causa, que é o mesmo
 * erro de um portão que reporta "scanner quebrou" como "achou CVE".
 */
export async function runGate(
  base: string,
  deps: Deps,
  options: GateOptions = {},
): Promise<{ pass: number; fail: number; steps: Step[] }> {
  const { target, attempts, interval } = { ...DEFAULTS, ...options };
  // Alias local, e não `call(...)`: chamado como MÉTODO do objeto deps,
  // o `fetch` do navegador recebe `this === deps` e lança
  // "Illegal invocation" — ele exige que o `this` seja a Window. Um fetch
  // falso (nos testes, no modo gravado) não se importa com o `this`, então o
  // erro só aparece contra a stack de verdade. Foi assim que apareceu.
  const call = deps.fetch;
  const steps = new Map<StepId, Step>(idleSteps(target).map((s) => [s.id, s]));

  const emit = (id: StepId, patch: Partial<Step>) => {
    const next = { ...steps.get(id)!, ...patch };
    steps.set(id, next);
    deps.onStep(next);
    return next;
  };

  /** Envolve um passo com cronômetro e captura de erro de rede. */
  const run = async (id: StepId, fn: () => Promise<StepOutcome>): Promise<Step> => {
    emit(id, { status: "running", messageKey: `${id}.running`, values: {} });
    const started = deps.now();
    try {
      const out = await fn();
      return emit(id, { ...out, ms: deps.now() - started });
    } catch (err) {
      return emit(id, {
        status: "fail",
        messageKey: "net.error",
        values: { error: err instanceof Error ? err.message : String(err) },
        ms: deps.now() - started,
      });
    }
  };

  // 1. O edge responde? É a rota de saúde do próprio Caddy, sem tocar na api.
  await run("edge", async (): Promise<StepOutcome> => {
    const res = await call(`${base}/edge-health`);
    // Ver o comentário em probe(): 204 exato, porque 200 com corpo HTML é a
    // página de erro de um servidor de arquivos, não o edge.
    return res.status === 204
      ? { status: "pass", messageKey: "edge.ok", values: { status: res.status } }
      : { status: "fail", messageKey: "edge.fail", values: { status: res.status } };
  });

  // 2. A api responde e alcança o Postgres? Uma leitura já prova as duas
  //    coisas. O /readyz seria mais direto, mas o edge não o publica — e essa
  //    ausência é deliberada, não um esquecimento.
  await run("list", async (): Promise<StepOutcome> => {
    const res = await call(`${base}/api/links?limit=1`, { headers: { accept: "application/json" } });
    const { json, raw } = await readJson(res);
    if (!isRecord(json) || typeof json.count !== "number") {
      return { status: "fail", messageKey: "list.notJson", values: { status: res.status }, body: snippet(raw) };
    }
    return { status: "pass", messageKey: "list.ok", values: { count: json.count }, body: snippet(raw) };
  });

  // 3. Criar um link de verdade. Daqui sai o `code` que os próximos usam.
  let code = "";
  await run("create", async (): Promise<StepOutcome> => {
    const res = await call(`${base}/api/links`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ url: target }),
    });
    const { json, raw } = await readJson(res);
    if (res.status !== 201 || !isRecord(json) || typeof json.code !== "string") {
      return { status: "fail", messageKey: "create.fail", values: { status: res.status }, body: snippet(raw) };
    }
    code = json.code;
    return { status: "pass", messageKey: "create.ok", values: { code }, body: snippet(raw) };
  });

  if (!code) {
    for (const id of ["redirect", "enrich", "ssrf"] as StepId[]) {
      emit(id, { status: "fail", messageKey: "skipped.noCode", values: {} });
    }
  } else {
    // 4. O redirect. O navegador ESCONDE o 302: com redirect "manual" a
    //    resposta vira opaca (type "opaqueredirect", status 0). Essa opacidade
    //    é justamente a prova de que veio um 3xx — uma resposta normal teria
    //    type "basic". O curl vê o 302; o fetch vê que houve um.
    await run("redirect", async (): Promise<StepOutcome> => {
      const res = await call(`${base}/r/${code}`, { redirect: "manual" });
      if (res.type === "opaqueredirect" || (res.status >= 300 && res.status < 400)) {
        return { status: "pass", messageKey: "redirect.ok", values: { code } };
      }
      return { status: "fail", messageKey: "redirect.no", values: { status: res.status } };
    });

    // 5. O worker é assíncrono: damos alguns segundos para ele enriquecer.
    await run("enrich", async (): Promise<StepOutcome> => {
      for (let i = 0; i < attempts; i++) {
        const res = await call(`${base}/api/links/${code}`);
        const { json, raw } = await readJson(res);
        if (isRecord(json) && typeof json.title === "string" && json.title) {
          return { status: "pass", messageKey: "enrich.ok", values: { title: json.title, tries: i + 1 }, body: snippet(raw) };
        }
        await deps.sleep(interval);
      }
      return { status: "fail", messageKey: "enrich.timeout", values: { seconds: (attempts * interval) / 1000 } };
    });

    // 6. A defesa contra SSRF: o endereço de metadados da nuvem tem que ser
    //    recusado pelo worker, e o motivo tem que aparecer na resposta.
    await run("ssrf", async (): Promise<StepOutcome> => {
      const res = await call(`${base}/api/links`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ url: SSRF_TARGET }),
      });
      const { json } = await readJson(res);
      if (!isRecord(json) || typeof json.code !== "string") {
        return { status: "fail", messageKey: "ssrf.notCreated", values: { status: res.status } };
      }
      const ssrfCode = json.code;
      for (let i = 0; i < attempts; i++) {
        const check = await call(`${base}/api/links/${ssrfCode}`);
        const { json: got, raw } = await readJson(check);
        const reason = isRecord(got) && typeof got.enrich_error === "string" ? got.enrich_error : "";
        if (reason) {
          return /bloqueado|blocked/i.test(reason)
            ? { status: "pass", messageKey: "ssrf.blocked", values: { reason }, body: snippet(raw) }
            : { status: "fail", messageKey: "ssrf.other", values: { reason }, body: snippet(raw) };
        }
        await deps.sleep(interval);
      }
      return { status: "fail", messageKey: "ssrf.timeout", values: { seconds: (attempts * interval) / 1000 } };
    });
  }

  // 7. O site é servido pelo mesmo edge. Esta é a página em que você está.
  await run("site", async (): Promise<StepOutcome> => {
    const res = await call(`${base}/`, { headers: { accept: "text/html" } });
    const type = res.headers.get("content-type") ?? "";
    return res.ok && type.includes("html")
      ? { status: "pass", messageKey: "site.ok", values: {} }
      : { status: "fail", messageKey: "site.fail", values: { status: res.status } };
  });

  const all = [...steps.values()];
  return {
    pass: all.filter((s) => s.status === "pass").length,
    fail: all.filter((s) => s.status === "fail").length,
    steps: all,
  };
}
