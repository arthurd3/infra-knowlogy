import { useCallback, useEffect, useRef, useState } from "react";
import { probe } from "../../lib/gate";
import { shorten, validate, type LabState } from "../../lib/lab";
import { recorded, recordedFetch } from "../../lib/recorded";

/**
 * O encurtador, de dentro da lição.
 *
 * O leitor digita uma URL e vê o caminho inteiro acontecer: a api grava, o
 * redirect responde, o worker vai buscar o título — e, se a URL apontar para
 * dentro da rede, a defesa contra SSRF recusa e diz por quê.
 *
 * Os presets não são decorativos: `169.254.169.254` é o endereço de metadados
 * das nuvens, o alvo clássico de SSRF, e é o mesmo que o portão testa.
 */

const COPY = {
  pt: {
    title: "Encurte um link agora",
    label: "URL para encurtar",
    submit: "Encurtar",
    working: "Rodando…",
    presets: "Ou experimente:",
    presetOk: "um site normal",
    presetSsrf: "metadados da nuvem (SSRF)",
    presetLocal: "um serviço interno",
    code: "código", short: "link curto", redirect: "redirect", title2: "título",
    blocked: "recusado pelo worker", raw: "resposta da api",
    yes: "3xx confirmado", no: "nenhum redirect",
    phase: {
      creating: "gravando no Postgres…",
      redirecting: "seguindo /r/{code}…",
      enriching: "esperando o worker buscar o título…",
    } as Record<string, string>,
    tries: "na {n}ª leitura",
    none: "o worker não retornou nada a tempo",
    demo:
      "Sem stack no ar: o que segue é a resposta <b>gravada</b> em {date}. Rode <code>make up</code> e abra <code>http://127.0.0.1:8080</code> para valer de verdade.",
    live: "Requisições reais contra a stack em <code>{base}</code>.",
    errInvalid: "não parece uma URL",
    errScheme: "a api só aceita http:// ou https:// — e recusa com 422",
    errHost: "falta o host",
    err: "a api recusou",
    note:
      "O SSRF é recusado pelo <b>worker</b>, não pela api: a criação responde 201 do mesmo jeito, e o motivo aparece depois em <code>enrich_error</code>. Bloquear na escrita esconderia do leitor que a checagem é de rede, feita na hora de sair.",
  },
  en: {
    title: "Shorten a link right now",
    label: "URL to shorten",
    submit: "Shorten",
    working: "Running…",
    presets: "Or try:",
    presetOk: "an ordinary site",
    presetSsrf: "cloud metadata (SSRF)",
    presetLocal: "an internal service",
    code: "code", short: "short link", redirect: "redirect", title2: "title",
    blocked: "refused by the worker", raw: "api response",
    yes: "3xx confirmed", no: "no redirect",
    phase: {
      creating: "writing to Postgres…",
      redirecting: "following /r/{code}…",
      enriching: "waiting for the worker to fetch the title…",
    } as Record<string, string>,
    tries: "on read #{n}",
    none: "the worker returned nothing in time",
    demo:
      "No stack up: what follows is the response <b>recorded</b> on {date}. Run <code>make up</code> and open <code>http://127.0.0.1:8080</code> for the real thing.",
    live: "Real requests against the stack at <code>{base}</code>.",
    errInvalid: "that does not look like a URL",
    errScheme: "the api only accepts http:// or https:// — and refuses with 422",
    errHost: "the host is missing",
    err: "the api refused",
    note:
      "SSRF is refused by the <b>worker</b>, not the api: creation still answers 201, and the reason shows up later in <code>enrich_error</code>. Blocking on write would hide from the reader that the check is a network one, made at the moment of leaving.",
  },
} as const;

const PRESETS = [
  { url: "https://example.com/", key: "presetOk" },
  { url: "http://169.254.169.254/latest/meta-data/", key: "presetSsrf" },
  { url: "http://db:5432/", key: "presetLocal" },
] as const;

function format(template: string, values: Record<string, string | number>) {
  return template.replace(/\{(\w+)\}/g, (_, k) => String(values[k] ?? ""));
}

export default function LinkLab({ lang = "pt" }: { lang?: "pt" | "en" }) {
  const t = COPY[lang];
  const [url, setUrl] = useState("https://example.com/");
  const [state, setState] = useState<LabState | null>(null);
  const [live, setLive] = useState<boolean | null>(null);
  const [invalid, setInvalid] = useState<string | null>(null);
  const alive = useRef(true);

  useEffect(() => {
    alive.current = true;
    probe("", fetch).then((r) => alive.current && setLive(r === "online"));
    return () => { alive.current = false; };
  }, []);

  const busy = state !== null && state.phase !== "done" && state.phase !== "error";

  const submit = useCallback(async (value: string) => {
    const problem = validate(value);
    if (problem) {
      setInvalid(problem === "invalid" ? t.errInvalid : problem === "scheme" ? t.errScheme : t.errHost);
      return;
    }
    setInvalid(null);
    const isLive = live === true;
    await shorten(
      "",
      value,
      {
        fetch: isLive ? fetch : recordedFetch(),
        sleep: (ms) => new Promise((r) => setTimeout(r, isLive ? ms : Math.min(ms, 300))),
      },
      (s) => alive.current && setState(s),
      { attempts: isLive ? 12 : 3, interval: isLive ? 1000 : 300 },
    );
  }, [live, t]);

  const banner = live === null ? "" :
    live ? format(t.live, { base: typeof location === "undefined" ? "" : location.host })
         : format(t.demo, { date: recorded.recordedAt.slice(0, 10) });

  return (
    <div className="lab">
      <form
        className="lab__form"
        onSubmit={(e) => { e.preventDefault(); void submit(url); }}
      >
        <span className="lab__field">
          <label htmlFor="lab-url">{t.label}</label>
          <input
            id="lab-url" className="lab__input" type="text" value={url} spellCheck={false}
            onChange={(e) => { setUrl(e.target.value); setInvalid(null); }}
          />
        </span>
        <button type="submit" className="btn btn--primary" disabled={busy || live === null}>
          {busy ? t.working : t.submit}
        </button>
      </form>

      <div className="lab__presets">
        <span style={{ fontSize: "0.75rem", color: "var(--text-faint)", alignSelf: "center" }}>{t.presets}</span>
        {PRESETS.map((p) => (
          <button
            key={p.url} type="button" className={`btn btn-ghost ${url === p.url ? "is-active" : ""}`}
            onClick={() => { setUrl(p.url); setInvalid(null); }}
          >
            {t[p.key]}
          </button>
        ))}
      </div>

      {invalid && <p className="lab__error">{invalid}</p>}
      {banner && <p className="lab__hint" dangerouslySetInnerHTML={{ __html: banner }} />}

      {state && state.phase !== "error" && (
        <div className="lab__result">
          {busy && (
            <p className="lab__hint">
              {format(t.phase[state.phase] ?? "", { code: state.code ?? "" })}
            </p>
          )}

          {state.code && (
            <div className="lab__card">
              <span className="lab__label">{t.code}</span>
              <span className="lab__value">{state.code}</span>
            </div>
          )}

          {state.shortUrl && (
            <div className="lab__card">
              <span className="lab__label">{t.short}</span>
              <span className="lab__value">
                {live ? <a href={`/r/${state.code}`} rel="noopener noreferrer" target="_blank">/r/{state.code}</a>
                      : `/r/${state.code}`}
                {state.redirected !== undefined && (
                  <span style={{ color: "var(--text-faint)", marginLeft: "0.6rem" }}>
                    {state.redirected ? t.yes : t.no}
                  </span>
                )}
              </span>
            </div>
          )}

          {state.phase === "done" && state.title && (
            <div className="lab__card lab__card--accent">
              <span className="lab__label">{t.title2}</span>
              <span className="lab__value">
                {state.title}
                <span style={{ color: "var(--text-faint)", marginLeft: "0.6rem" }}>
                  {format(t.tries, { n: state.tries ?? 0 })}
                </span>
              </span>
            </div>
          )}

          {state.phase === "done" && state.enrichError && (
            <div className="lab__card lab__card--danger">
              <span className="lab__label">{t.blocked}</span>
              <span className="lab__value">{state.enrichError}</span>
            </div>
          )}

          {state.phase === "done" && !state.title && !state.enrichError && (
            <p className="lab__hint">{t.none}</p>
          )}

          {state.raw && (
            <details>
              <summary style={{ fontSize: "0.8125rem", color: "var(--text-muted)", cursor: "pointer" }}>
                {t.raw}
              </summary>
              <pre className="gx__body" style={{ paddingLeft: 0 }}>{state.raw}</pre>
            </details>
          )}
        </div>
      )}

      {state?.phase === "error" && (
        <p className="lab__error">{t.err}: {state.error}</p>
      )}

      <p className="lab__hint" dangerouslySetInnerHTML={{ __html: t.note }} />
    </div>
  );
}
