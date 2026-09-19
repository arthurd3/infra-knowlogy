import measured from "../../data/k8s-measured.json";

/**
 * As medições do módulo Kubernetes.
 *
 * Todo número aqui foi escrito por tools/scripts/k8s-verify.sh durante uma
 * execução real do portão: cluster criado do zero, stack aplicada, pod morto
 * de propósito, banco derrubado, rolling update disparado com um gerador de
 * carga em cima. O arquivo existia desde o porte e nenhuma tela o mostrava —
 * os números estavam transcritos à mão na prosa das lições, que é exatamente
 * o jeito de eles ficarem desatualizados sem ninguém perceber.
 */

const COPY = {
  pt: {
    title: "O que o portão do módulo mediu",
    caption:
      "Gravado por <code>tools/scripts/k8s-verify.sh</code> em {date}, com kind {kind} e Kubernetes {k8s}. Rodar <code>make k8s-verify</code> regrava este arquivo.",
    items: {
      clusterCreateSeconds: ["criar o cluster", "do zero, com kind", "s"],
      stackReadySeconds: ["stack pronta", "todos os pods Ready", "s"],
      selfHealSeconds: ["auto-cura", "pod morto → pod novo no ar", "s"],
      readinessReactSeconds: ["reagir ao banco cair", "readiness esvazia os endpoints", "s"],
      rollingRequestsTotal: ["requisições no rolling", "disparadas durante o update", ""],
      rollingRequestsFailed: ["falharam", "com SHUTDOWN_DELAY antes de fechar", ""],
      shutdownMaxMs: ["pior desligamento", "limite do portão: 3000 ms", "ms"],
    } as Record<string, [string, string, string]>,
  },
  en: {
    title: "What the module's gate measured",
    caption:
      "Written by <code>tools/scripts/k8s-verify.sh</code> on {date}, with kind {kind} and Kubernetes {k8s}. Running <code>make k8s-verify</code> rewrites this file.",
    items: {
      clusterCreateSeconds: ["create the cluster", "from scratch, with kind", "s"],
      stackReadySeconds: ["stack ready", "every pod Ready", "s"],
      selfHealSeconds: ["self-healing", "pod killed → new pod serving", "s"],
      readinessReactSeconds: ["react to the database dropping", "readiness empties the endpoints", "s"],
      rollingRequestsTotal: ["requests during the rolling update", "fired while it ran", ""],
      rollingRequestsFailed: ["failed", "with SHUTDOWN_DELAY before closing", ""],
      shutdownMaxMs: ["worst shutdown", "gate limit: 3000 ms", "ms"],
    } as Record<string, [string, string, string]>,
  },
} as const;

/** Zero falhas é a boa notícia da tabela; destacar isso não é enfeite. */
const GOOD = new Set(["selfHealSeconds", "rollingRequestsFailed"]);

export default function K8sMeasurements({ lang = "pt" }: { lang?: "pt" | "en" }) {
  const t = COPY[lang];
  const m = measured.measurements as Record<string, number>;

  return (
    <figure className="km">
      <div className="lx__title" style={{ marginBottom: "0.85rem" }}>{t.title}</div>
      <div className="km__grid">
        {Object.entries(t.items).map(([key, [name, note, unit]]) => (
          <div key={key} className={`km__cell ${GOOD.has(key) ? "km__cell--good" : ""}`}>
            <span className="km__value">
              {m[key]}
              {unit && <span className="km__unit">{unit}</span>}
            </span>
            <span className="km__name">{name}</span>
            <span className="km__note">{note}</span>
          </div>
        ))}
      </div>
      <figcaption
        className="km__caption"
        dangerouslySetInnerHTML={{
          __html: t.caption
            .replace("{date}", measured.generatedAt.slice(0, 10))
            .replace("{kind}", measured.kindVersion)
            .replace("{k8s}", measured.kubernetesVersion),
        }}
      />
    </figure>
  );
}
