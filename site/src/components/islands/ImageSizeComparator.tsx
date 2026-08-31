import { useMemo, useState } from "react";
import measured from "../../data/measured.json";

/**
 * Comparador de tamanho de imagem.
 *
 * Todo número aqui sai de `docker image inspect` rodado nesta máquina, sobre
 * ESTE código, por tools/scripts/sizes.sh. Nada foi copiado de blog — que é
 * justamente o problema de quase toda tabela "alpine vs distroless" na internet:
 * elas medem a imagem base vazia, não a sua aplicação dentro dela.
 */

interface Row {
  service: string;
  language: string;
  target: string;
  base: string;
  bytes: number;
  layers: number;
  note_pt: string;
  note_en: string;
}

const COPY = {
  pt: {
    chart: "Gráfico", table: "Tabela",
    image: "Imagem", base: "Base", size: "Tamanho", layers: "Camadas", note: "Observação",
    measured: "Medido em", with: "com Docker",
    vs: "menor que o maior desta linguagem",
    caption: "Tamanho da imagem final por serviço e alvo de build — menor é melhor.",
  },
  en: {
    chart: "Chart", table: "Table",
    image: "Image", base: "Base", size: "Size", layers: "Layers", note: "Note",
    measured: "Measured on", with: "with Docker",
    vs: "smaller than the largest for this language",
    caption: "Final image size by service and build target — smaller is better.",
  },
} as const;

// Slots 1–3 da paleta categórica (blue, orange, aqua). Estes três validam
// all-pairs em ambos os modos; a cor identifica a LINGUAGEM, não o tamanho —
// o tamanho já está codificado no comprimento da barra.
const SERIES: Record<string, string> = {
  Go: "var(--viz-1)",
  Python: "var(--viz-2)",
  Node: "var(--viz-3)",
};

function mb(bytes: number) {
  return bytes / 1_048_576;
}

export default function ImageSizeComparator({ lang = "pt" }: { lang?: "pt" | "en" }) {
  const t = COPY[lang];
  const [view, setView] = useState<"chart" | "table">("chart");
  const rows = measured.images as Row[];

  const max = useMemo(() => Math.max(...rows.map((r) => r.bytes)), [rows]);
  const languages = useMemo(
    () => [...new Set(rows.map((r) => r.language))],
    [rows],
  );
  // Maior imagem por linguagem, para a redução relativa fazer sentido
  // (comparar um binário Go com um runtime Python não diria nada).
  const maxByLang = useMemo(() => {
    const m: Record<string, number> = {};
    for (const r of rows) m[r.language] = Math.max(m[r.language] ?? 0, r.bytes);
    return m;
  }, [rows]);

  return (
    <figure className="viz-root viz">
      <div className="viz__head">
        <div className="viz__legend" role="list">
          {languages.map((l) => (
            <span className="viz__legend-item" role="listitem" key={l}>
              <span className="viz__swatch" style={{ background: SERIES[l] }} aria-hidden="true" />
              {l}
            </span>
          ))}
        </div>
        <button type="button" className="btn-ghost" onClick={() => setView(view === "chart" ? "table" : "chart")}>
          {view === "chart" ? t.table : t.chart}
        </button>
      </div>

      {view === "chart" ? (
        <div className="viz__bars">
          {rows.map((r) => {
            const pct = (r.bytes / max) * 100;
            const saved = 1 - r.bytes / maxByLang[r.language];
            return (
              <div className="viz__row" key={`${r.service}-${r.target}`}>
                <div className="viz__label">
                  <strong>{r.service}</strong>
                  <span className="viz__target">{r.target}</span>
                  <span className="viz__base">{r.base}</span>
                </div>
                <div
                  className="viz__track"
                  title={`${r.base} · ${r.layers} ${t.layers.toLowerCase()} · ${r[`note_${lang}`]}`}
                >
                  <div
                    className="viz__bar"
                    style={{ width: `${pct}%`, background: SERIES[r.language] }}
                  />
                  {/* Rótulo direto em TODA barra: a regra de alívio exige isto
                      porque o aqua fica abaixo de 3:1 na superfície clara. */}
                  <span className="viz__value">
                    {mb(r.bytes).toFixed(1)} MB
                    {saved > 0.01 && (
                      <span className="viz__delta"> −{Math.round(saved * 100)}%</span>
                    )}
                  </span>
                </div>
              </div>
            );
          })}
        </div>
      ) : (
        <div className="scroll-x">
          <table className="viz__table">
            <thead>
              <tr>
                <th>{t.image}</th><th>{t.base}</th>
                <th style={{ textAlign: "right" }}>{t.size}</th>
                <th style={{ textAlign: "right" }}>{t.layers}</th>
                <th>{t.note}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={`${r.service}-${r.target}`}>
                  <td><strong>{r.service}</strong> <code>{r.target}</code></td>
                  <td><code>{r.base}</code></td>
                  <td style={{ textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
                    {mb(r.bytes).toFixed(1)} MB
                  </td>
                  <td style={{ textAlign: "right", fontVariantNumeric: "tabular-nums" }}>{r.layers}</td>
                  <td style={{ fontSize: "0.8125rem", color: "var(--text-muted)" }}>{r[`note_${lang}`]}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <figcaption className="viz__caption">
        {t.caption} {t.measured}{" "}
        <time dateTime={measured.generatedAt}>{measured.generatedAt.slice(0, 10)}</time>{" "}
        {t.with} {measured.dockerVersion} ({measured.platform}).
      </figcaption>
    </figure>
  );
}
