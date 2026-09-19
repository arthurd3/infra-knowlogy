import measured from "../../data/cicd-measured.json";

/**
 * As medições do módulo CI/CD.
 *
 * Todo número aqui foi escrito por tools/scripts/cicd-verify.sh durante uma
 * execução real do portão: controller do zero, pipeline completo duas vezes
 * (frio e quente), artefato comparado byte a byte com o build local.
 *
 * O par frio/quente é o que sustenta a comparação com o GitHub Actions, onde o
 * runner é descartado a cada job e por isso TODO build é frio.
 */

const COPY = {
  pt: {
    title: "O que o portão do módulo mediu",
    caption:
      "Gravado por <code>tools/scripts/cicd-verify.sh</code> em {date}, com Jenkins {jenkins} e {plugins} plugins pinados. Rodar <code>make cicd-verify</code> regrava este arquivo.",
    naoMedido: "não medido nesta execução",
    sim: "sim",
    nao: "não",
    items: {
      controllerBootSeconds: ["controller de pé", "do zero, já configurado", "s"],
      pipelineColdSeconds: ["pipeline frio", "cache do buildkit vazio", "s"],
      pipelineWarmSeconds: ["pipeline quente", "segunda execução seguida", "s"],
      lintStageSeconds: ["estágio lint", "hadolint em 8 Dockerfiles", "s"],
      buildStageSeconds: ["estágio build", "três imagens, sem daemon", "s"],
      scanStageSeconds: ["estágio scan", "Trivy sobre os três tarballs", "s"],
      signStageSeconds: ["estágio sign", "cosign, três digests", "s"],
    } as Record<string, [string, string, string]>,
    bools: {
      goBinaryIdentical: ["binário Go idêntico ao build local", "byte a byte"],
      imageDigestIdentical: ["digest da imagem inteira idêntico", "timestamps e ordem no tar divergem"],
    } as Record<string, [string, string]>,
  },
  en: {
    title: "What the module's gate measured",
    caption:
      "Written by <code>tools/scripts/cicd-verify.sh</code> on {date}, with Jenkins {jenkins} and {plugins} pinned plugins. Running <code>make cicd-verify</code> rewrites this file.",
    naoMedido: "not measured in this run",
    sim: "yes",
    nao: "no",
    items: {
      controllerBootSeconds: ["controller up", "from scratch, fully configured", "s"],
      pipelineColdSeconds: ["cold pipeline", "empty buildkit cache", "s"],
      pipelineWarmSeconds: ["warm pipeline", "second run back to back", "s"],
      lintStageSeconds: ["lint stage", "hadolint across 8 Dockerfiles", "s"],
      buildStageSeconds: ["build stage", "three images, no daemon", "s"],
      scanStageSeconds: ["scan stage", "Trivy over the three tarballs", "s"],
      signStageSeconds: ["sign stage", "cosign, three digests", "s"],
    } as Record<string, [string, string, string]>,
    bools: {
      goBinaryIdentical: ["Go binary identical to the local build", "byte for byte"],
      imageDigestIdentical: ["whole-image digest identical", "timestamps and tar ordering differ"],
    } as Record<string, [string, string]>,
  },
} as const;

export default function CicdMeasurements({ lang = "pt" }: { lang?: "pt" | "en" }) {
  const t = COPY[lang];
  const m = measured.measurements as Record<string, number | boolean | null>;

  return (
    <figure className="km">
      <div className="lx__title" style={{ marginBottom: "0.85rem" }}>{t.title}</div>
      <div className="km__grid">
        {Object.entries(t.items).map(([key, [name, note, unit]]) => {
          const v = m[key];
          return (
            <div key={key} className="km__cell">
              <span className="km__value">
                {v === null || v === undefined ? "—" : String(v)}
                {v !== null && v !== undefined && unit && <span className="km__unit">{unit}</span>}
              </span>
              <span className="km__name">{name}</span>
              <span className="km__note">{v === null || v === undefined ? t.naoMedido : note}</span>
            </div>
          );
        })}
      </div>
      <div className="km__grid" style={{ marginTop: "0.6rem" }}>
        {Object.entries(t.bools).map(([key, [name, note]]) => {
          const v = m[key];
          return (
            <div key={key} className={`km__cell ${v === true ? "km__cell--good" : ""}`}>
              <span className="km__value">{v === true ? t.sim : v === false ? t.nao : "—"}</span>
              <span className="km__name">{name}</span>
              <span className="km__note">{note}</span>
            </div>
          );
        })}
      </div>
      <figcaption
        className="km__caption"
        dangerouslySetInnerHTML={{
          __html: t.caption
            .replace("{date}", measured.generatedAt.slice(0, 10))
            .replace("{jenkins}", measured.jenkinsVersion ?? "?")
            .replace("{plugins}", String(measured.pluginsPinned ?? "?")),
        }}
      />
    </figure>
  );
}
