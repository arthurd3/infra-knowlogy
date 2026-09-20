import { useState } from "react";
import { inline } from "./QuizBoard";

/**
 * O mapa de mercado, navegável.
 *
 * O que ele apresenta é `site/src/data/skills.json`: as sete exigências que
 * apareceram em 40 vagas, cruzadas com o que este repositório PROVA. A ilha
 * não decide nada — quem guarda a honestidade do dado é `skills.test.ts`, que
 * reprova item marcado como coberto apontando para lição que não existe ou
 * para checagem de portão que ninguém escreveu.
 *
 * Como no PortExplorer, os dados chegam prontos num idioma só, resolvidos em
 * tempo de build: a ilha não tem como consultar a URL.
 */

export type Status = "coberto" | "parcial" | "ausente";

export interface Evidence {
  lessons: Array<{ key: string; title: string; href: string }>;
  checks: string[];
  measurements: string[];
}

export interface DemandView {
  id: string;
  label: string;
  demand: number;
  status: Status;
  gap: string;
  quadrant: string;
  evidence: Evidence;
}

export interface QuadrantView {
  id: string;
  label: string;
  items: Array<{ name: string; status: Status; note?: string }>;
}

const COPY = {
  pt: {
    demand: "das vagas pedem",
    gap: "O que falta",
    proves: "O que prova",
    lessons: "lições",
    checks: "checagens de portão",
    measurements: "medições",
    nothing: "nada ainda — é uma lacuna declarada",
    status: { coberto: "coberto", parcial: "parcial", ausente: "ausente" },
    expand: "ver detalhe",
    collapse: "fechar",
  },
  en: {
    demand: "of job posts ask for it",
    gap: "What is missing",
    proves: "What proves it",
    lessons: "lessons",
    checks: "gate checks",
    measurements: "measurements",
    nothing: "nothing yet — a declared gap",
    status: { coberto: "covered", parcial: "partial", ausente: "absent" },
    expand: "see detail",
    collapse: "close",
  },
} as const;

export default function SkillCoverage({
  lang,
  demands,
  quadrants,
}: {
  lang: "pt" | "en";
  demands: DemandView[];
  quadrants: QuadrantView[];
}) {
  const t = COPY[lang];
  const [open, setOpen] = useState<string | null>(null);

  return (
    <div className="skills">
      <ul className="skills__bars">
        {demands.map((d) => {
          const isOpen = open === d.id;
          const n =
            d.evidence.lessons.length + d.evidence.checks.length + d.evidence.measurements.length;
          return (
            <li className={`skills__row skills__row--${d.status}`} key={d.id}>
              <button
                className="skills__head"
                aria-expanded={isOpen}
                onClick={() => setOpen(isOpen ? null : d.id)}
              >
                <span className="skills__label">{d.label}</span>
                <span className={`badge skills__status skills__status--${d.status}`}>
                  {t.status[d.status]}
                </span>
                <span className="skills__pct" title={`${d.demand}% ${t.demand}`}>
                  {d.demand}%
                  <span className="visually-hidden"> {t.demand}</span>
                </span>
              </button>

              <div className="skills__track" aria-hidden="true">
                <span className="skills__fill" style={{ width: `${d.demand}%` }} />
              </div>

              {isOpen && (
                <div className="skills__detail">
                  <p className="skills__gap">
                    <strong>{t.gap}:</strong>{" "}
                    <span dangerouslySetInnerHTML={{ __html: inline(d.gap) }} />
                  </p>

                  <p className="skills__evidence-title">{t.proves}</p>
                  {n === 0 ? (
                    <p className="skills__none">{t.nothing}</p>
                  ) : (
                    <ul className="skills__evidence">
                      {d.evidence.lessons.map((l) => (
                        <li key={l.key}>
                          <a href={l.href}>{l.title}</a>
                        </li>
                      ))}
                      {d.evidence.checks.map((c) => (
                        <li key={c}>
                          <code>{c}</code>
                        </li>
                      ))}
                      {d.evidence.measurements.map((m) => (
                        <li key={m}>
                          <code>{m}</code>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              )}
            </li>
          );
        })}
      </ul>

      <div className="skills__quadrants">
        {quadrants.map((q) => (
          <section className="skills__quadrant" key={q.id}>
            <h3>{q.label}</h3>
            <ul>
              {q.items.map((i) => (
                <li className={`skills__chip skills__chip--${i.status}`} key={i.name} title={i.note}>
                  {i.name}
                  {i.note && <span className="skills__chip-note">{i.note}</span>}
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    </div>
  );
}
