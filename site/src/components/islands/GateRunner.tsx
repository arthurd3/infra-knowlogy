import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  idleSteps, probe, runGate, STEP_IDS,
  type Step, type StepId,
} from "../../lib/gate";
import { recorded, recordedFetch } from "../../lib/recorded";

/**
 * O portão, rodando daqui.
 *
 * Estes são os mesmos passos de tools/scripts/lib/smoke.sh. Com a stack no ar
 * (`make up`), o botão dispara requisições de verdade contra ela: o site e a
 * api saem da MESMA origem pelo edge, então não há CORS nem servidor novo no
 * meio. Sem stack, o widget reencena as respostas gravadas — e diz que são
 * gravadas, com a data.
 *
 * A lógica inteira mora em ../../lib/gate.ts, sem React e sem texto: é o que
 * permite testá-la com um fetch falso (tests/gate.test.ts) em vez de precisar
 * de Docker para saber se o widget funciona.
 */

const COPY = {
  pt: {
    title: "O portão, rodando daqui",
    run: "Rodar as checagens",
    running: "Rodando…",
    again: "Rodar de novo",
    online: "stack no ar",
    partial: "só o edge responde",
    offline: "modo demonstração",
    probing: "procurando a stack…",
    bannerDemo:
      "Nenhuma stack respondeu nesta origem, então os passos abaixo reencenam as respostas <b>gravadas</b> em {date} contra a stack deste repositório. Para valer de verdade: rode <code>make up</code> e abra <code>http://127.0.0.1:8080</code>.",
    bannerPartial:
      "O proxy responde, mas a api não. É o sintoma que a lição de readiness descreve — e note que o <code>/readyz</code> não é alcançável daqui de propósito: o edge não publica rota de saúde.",
    bannerLive:
      "Requisições reais, contra a stack que está rodando em <code>{base}</code>. Os links criados ficam no Postgres.",
    pass: "passaram", fail: "falharam",
    recorded: "gravado",
    detail: "ver a resposta",
    steps: {
      edge: "o proxy está de pé",
      list: "a api responde e alcança o Postgres",
      create: "criar um link curto",
      redirect: "o código redireciona",
      enrich: "o worker busca o título",
      ssrf: "o endereço interno é recusado",
      site: "o edge serve este site",
    } as Record<StepId, string>,
    msg: {
      "edge.idle": "aguardando", "list.idle": "aguardando", "create.idle": "aguardando",
      "redirect.idle": "aguardando", "enrich.idle": "aguardando", "ssrf.idle": "aguardando",
      "site.idle": "aguardando",
      "edge.running": "chamando…", "list.running": "chamando…", "create.running": "chamando…",
      "redirect.running": "chamando…", "enrich.running": "esperando o worker…",
      "ssrf.running": "esperando o worker…", "site.running": "chamando…",
      "edge.ok": "204, sem corpo — o Caddy responde sem tocar na api",
      "edge.fail": "respondeu {status}; esperado 204",
      "list.ok": "JSON válido, {count} link(s) no banco",
      "list.notJson": "não veio JSON (status {status}) — isto aqui é site estático, não a api",
      "create.ok": "201 Created, código {code}",
      "create.fail": "respondeu {status}",
      "redirect.ok": "3xx confirmado para o código {code}",
      "redirect.no": "respondeu {status}, sem redirect",
      "enrich.ok": "título “{title}”, na {tries}ª leitura",
      "enrich.timeout": "nenhum título em {seconds}s",
      "ssrf.blocked": "recusado — {reason}",
      "ssrf.other": "falhou por outro motivo: {reason}",
      "ssrf.notCreated": "a api não criou o link (status {status})",
      "ssrf.timeout": "nenhum veredito em {seconds}s",
      "site.ok": "200 text/html — a página que você está lendo",
      "site.fail": "respondeu {status}",
      "skipped.noCode": "pulado: sem código para testar",
      "net.error": "erro de rede: {error}",
    } as Record<string, string>,
  },
  en: {
    title: "The gate, running from here",
    run: "Run the checks",
    running: "Running…",
    again: "Run again",
    online: "stack is up",
    partial: "only the edge answers",
    offline: "demo mode",
    probing: "looking for the stack…",
    bannerDemo:
      "No stack answered on this origin, so the steps below replay the responses <b>recorded</b> on {date} against this repository's stack. For the real thing: run <code>make up</code> and open <code>http://127.0.0.1:8080</code>.",
    bannerPartial:
      "The proxy answers, the api does not. That is the symptom the readiness lesson describes — and note that <code>/readyz</code> is deliberately unreachable from here: the edge publishes no health route.",
    bannerLive:
      "Real requests, against the stack running at <code>{base}</code>. The links you create land in Postgres.",
    pass: "passed", fail: "failed",
    recorded: "recorded",
    detail: "show the response",
    steps: {
      edge: "the proxy is up",
      list: "the api answers and reaches Postgres",
      create: "create a short link",
      redirect: "the code redirects",
      enrich: "the worker fetches the title",
      ssrf: "the internal address is refused",
      site: "the edge serves this site",
    } as Record<StepId, string>,
    msg: {
      "edge.idle": "waiting", "list.idle": "waiting", "create.idle": "waiting",
      "redirect.idle": "waiting", "enrich.idle": "waiting", "ssrf.idle": "waiting",
      "site.idle": "waiting",
      "edge.running": "calling…", "list.running": "calling…", "create.running": "calling…",
      "redirect.running": "calling…", "enrich.running": "waiting for the worker…",
      "ssrf.running": "waiting for the worker…", "site.running": "calling…",
      "edge.ok": "204, no body — Caddy answers without touching the api",
      "edge.fail": "answered {status}; expected 204",
      "list.ok": "valid JSON, {count} link(s) in the database",
      "list.notJson": "no JSON came back (status {status}) — this is the static site, not the api",
      "create.ok": "201 Created, code {code}",
      "create.fail": "answered {status}",
      "redirect.ok": "3xx confirmed for code {code}",
      "redirect.no": "answered {status}, no redirect",
      "enrich.ok": "title “{title}”, on read #{tries}",
      "enrich.timeout": "no title within {seconds}s",
      "ssrf.blocked": "refused — {reason}",
      "ssrf.other": "failed for another reason: {reason}",
      "ssrf.notCreated": "the api did not create the link (status {status})",
      "ssrf.timeout": "no verdict within {seconds}s",
      "site.ok": "200 text/html — the page you are reading",
      "site.fail": "answered {status}",
      "skipped.noCode": "skipped: no code to test",
      "net.error": "network error: {error}",
    } as Record<string, string>,
  },
} as const;

type Mode = "probing" | "online" | "edge-only" | "offline";

function format(template: string, values: Record<string, string | number>) {
  return template.replace(/\{(\w+)\}/g, (_, k) => String(values[k] ?? `{${k}}`));
}

const ICON = { idle: "○", running: "◍", pass: "✓", fail: "✗" } as const;

export default function GateRunner({ lang = "pt" }: { lang?: "pt" | "en" }) {
  const t = COPY[lang];
  const [mode, setMode] = useState<Mode>("probing");
  const [steps, setSteps] = useState<Step[]>(() => idleSteps());
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [open, setOpen] = useState<StepId | null>(null);
  const alive = useRef(true);

  // O probe roda só depois da hidratação: durante o build não existe origem.
  useEffect(() => {
    alive.current = true;
    probe("", fetch).then((r) => alive.current && setMode(r));
    return () => { alive.current = false; };
  }, []);

  const live = mode === "online";

  const start = useCallback(async () => {
    setBusy(true);
    setDone(false);
    setSteps(idleSteps());
    // Ao vivo, o transporte é o do navegador; sem stack, o gravado. O código
    // verificado é o mesmo nos dois casos — só o transporte muda.
    const transport = live ? fetch : recordedFetch();
    // A gravação pula a espera real de 1s por tentativa: reencenar 15 segundos
    // de poll não ensina nada que 250 ms não ensinem.
    const wait = live ? 1000 : 250;
    await runGate("", {
      fetch: transport,
      sleep: (ms) => new Promise((r) => setTimeout(r, Math.min(ms, wait))),
      now: () => performance.now(),
      onStep: (s) => alive.current && setSteps((prev) => prev.map((p) => (p.id === s.id ? s : p))),
    }, { attempts: live ? 15 : 3, interval: wait });
    if (!alive.current) return;
    setBusy(false);
    setDone(true);
  }, [live]);

  const score = useMemo(() => ({
    pass: steps.filter((s) => s.status === "pass").length,
    fail: steps.filter((s) => s.status === "fail").length,
  }), [steps]);

  const chip =
    mode === "probing" ? { cls: "", label: t.probing }
    : mode === "online" ? { cls: "gx__chip--online", label: t.online }
    : mode === "edge-only" ? { cls: "gx__chip--partial", label: t.partial }
    : { cls: "", label: t.offline };

  const banner =
    mode === "online" ? format(t.bannerLive, { base: typeof location === "undefined" ? "" : location.host })
    : mode === "edge-only" ? t.bannerPartial
    : mode === "offline" ? format(t.bannerDemo, { date: recorded.recordedAt.slice(0, 10) })
    : "";

  return (
    <section className="gx">
      <header className="gx__head">
        <span className="gx__title">{t.title}</span>
        <span className={`gx__chip ${chip.cls}`}>
          <span className="gx__dot" aria-hidden="true" />
          {chip.label}
        </span>
        <span className="gx__spacer" />
        <button type="button" className="btn btn--primary" onClick={start} disabled={busy || mode === "probing"}>
          {busy ? t.running : done ? t.again : t.run}
        </button>
      </header>

      {banner && <p className="gx__banner" dangerouslySetInnerHTML={{ __html: banner }} />}

      <ol className="gx__steps">
        {STEP_IDS.map((id) => {
          const step = steps.find((s) => s.id === id)!;
          const expandable = Boolean(step.body);
          const isOpen = open === id;
          const Row = expandable ? "button" : "div";
          return (
            <li key={id} className={`gx__step ${step.status === "running" ? "is-running" : ""} ${step.status === "fail" ? "is-fail" : ""}`}>
              <Row
                className={`gx__row ${expandable ? "gx__row--expandable" : ""}`}
                {...(expandable
                  ? { type: "button" as const, onClick: () => setOpen(isOpen ? null : id), "aria-expanded": isOpen }
                  : {})}
              >
                <span className={`gx__icon gx__icon--${step.status}`} aria-hidden="true">{ICON[step.status]}</span>
                <span className="gx__req">{step.request}</span>
                <span className="gx__msg">
                  <strong>{t.steps[id]}</strong>
                  {" — "}
                  {format(t.msg[step.messageKey] ?? step.messageKey, step.values)}
                </span>
                <span className="gx__ms">
                  {!live && step.status === "pass" ? `${t.recorded}` : step.ms ? `${Math.round(step.ms)} ms` : ""}
                </span>
              </Row>
              {isOpen && step.body && <pre className="gx__body">{step.body}</pre>}
            </li>
          );
        })}
      </ol>

      <footer className="gx__foot">
        <span className="gx__score">
          <strong className="is-pass">{score.pass}</strong> {t.pass}
          {" · "}
          <strong className={score.fail > 0 ? "is-fail" : ""}>{score.fail}</strong> {t.fail}
        </span>
        <span className="gx__spacer" />
        <code style={{ fontSize: "0.75rem" }}>tools/scripts/lib/smoke.sh</code>
      </footer>
    </section>
  );
}
