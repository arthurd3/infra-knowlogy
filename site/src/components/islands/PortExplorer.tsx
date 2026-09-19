import { useState } from "react";
import { inline } from "./QuizBoard";

/**
 * O cartaz das portas mais atacadas, corrigido e navegável.
 *
 * Ele nasceu de uma imagem: uma tabela bonita com oito portas, o serviço de
 * cada uma e uma lista de "ataques comuns". A tabela é um bom gancho e erra
 * em dois pontos que mudam o entendimento — ela atribui à PORTA ataques que
 * são da APLICAÇÃO (injeção de SQL na 80) e põe o SSL stripping na 443, que é
 * justamente a porta que ele impede a vítima de alcançar.
 *
 * Por isso este widget tem duas colunas que o cartaz não tem: a DEFESA de cada
 * ataque, com o custo dela, e o MITO — a coisa que parece defesa e não é.
 * E tem um sexto grupo de portas que o cartaz não traz: as de banco de dados,
 * que são a resposta da outra metade da trilha.
 *
 * Os dados chegam prontos de PortExplorer.astro, já num idioma só: o arquivo
 * completo tem os dois e passa de 100 KB. Resolver em tempo de build é o mesmo
 * padrão do Quiz — a ilha não tem como consultar a URL, e mandar o dobro do
 * conteúdo para o navegador para descartar metade seria desperdício puro.
 */

export interface Attack { name: string; how: string; tell?: string }
export interface Defense { name: string; how: string; cost: string }
export interface Myth { claim: string; why: string }
export interface PortView {
  port: number;
  service: string;
  transport: string;
  group: "poster" | "database";
  inThisStack: string;
  stackLabel: string;
  use: string;
  stackNote: string;
  attacks: Attack[];
  defenses: Defense[];
  myths: Myth[];
  sources: Array<{ label: string; url: string }>;
}

const COPY = {
  pt: {
    groups: { poster: "As oito do cartaz", database: "As de banco de dados, que o cartaz não tem" },
    groupNote: {
      poster: "Clique numa porta. O que o cartaz diz está aqui — e também o que ele confunde.",
      database: "O cartaz não cita nenhuma porta de banco. São exatamente estas que respondem a “como se ataca uma base de dados”.",
    },
    attacks: "Como atacam",
    defenses: "Como se defende",
    myth: "Parece defesa e não é",
    tell: "Como perceber",
    cost: "O que custa",
    sources: "Fontes",
    here: "Nesta stack",
  },
  en: {
    groups: { poster: "The poster's eight", database: "The database ports the poster leaves out" },
    groupNote: {
      poster: "Pick a port. What the poster says is here — and so is what it gets wrong.",
      database: "The poster names no database port. These are exactly the ones that answer “how is a database attacked”.",
    },
    attacks: "How it is attacked",
    defenses: "How it is defended",
    myth: "Looks like a defense, is not",
    tell: "How to spot it",
    cost: "What it costs",
    sources: "Sources",
    here: "In this stack",
  },
} as const;

const html = (s: string) => ({ __html: inline(s) });

export default function PortExplorer({
  lang = "pt",
  ports = [],
}: {
  lang?: "pt" | "en";
  ports?: PortView[];
}) {
  const t = COPY[lang];
  const [selected, setSelected] = useState(ports[0]?.port ?? 0);
  const port = ports.find((p) => p.port === selected) ?? ports[0];

  if (!port) return null;

  const groups: Array<"poster" | "database"> = ["poster", "database"];

  return (
    <div className="px">
      {groups.map((g) => {
        const ofGroup = ports.filter((p) => p.group === g);
        if (ofGroup.length === 0) return null;
        return (
          <div className="px__group" key={g}>
            <div className="px__grouphead">
              <span className="px__grouptitle">{t.groups[g]}</span>
              <span className="px__groupnote">{t.groupNote[g]}</span>
            </div>
            <div className="px__chips" role="tablist" aria-label={t.groups[g]}>
              {ofGroup.map((p) => (
                <button
                  key={p.port}
                  type="button"
                  role="tab"
                  aria-selected={p.port === selected}
                  className={`px__chip${p.port === selected ? " is-active" : ""}`}
                  onClick={() => setSelected(p.port)}
                >
                  <span className="px__chipnum">{p.port}</span>
                  <span className="px__chipsvc">{p.service}</span>
                </button>
              ))}
            </div>
          </div>
        );
      })}

      <article className="px__detail">
        <header className="px__head">
          <span className="px__port">{port.port}</span>
          <span className="px__svc">
            <strong>{port.service}</strong>
            <span className="px__proto">{port.transport}</span>
          </span>
          <span className={`px__here px__here--${port.inThisStack}`}>
            {t.here}: {port.stackLabel}
          </span>
        </header>

        <p className="px__use" dangerouslySetInnerHTML={html(port.use)} />
        <p className="px__stacknote" dangerouslySetInnerHTML={html(port.stackNote)} />

        <section className="px__section px__section--attack">
          <h4 className="px__sectitle">{t.attacks}</h4>
          {port.attacks.map((a) => (
            <div className="px__item" key={a.name}>
              <span className="px__itemname" dangerouslySetInnerHTML={html(a.name)} />
              <p className="px__itemhow" dangerouslySetInnerHTML={html(a.how)} />
              {a.tell && (
                <p className="px__itemmeta">
                  <span className="px__metalabel">{t.tell}:</span>{" "}
                  <span dangerouslySetInnerHTML={html(a.tell)} />
                </p>
              )}
            </div>
          ))}
        </section>

        <section className="px__section px__section--defense">
          <h4 className="px__sectitle">{t.defenses}</h4>
          {port.defenses.map((d) => (
            <div className="px__item" key={d.name}>
              <span className="px__itemname" dangerouslySetInnerHTML={html(d.name)} />
              <p className="px__itemhow" dangerouslySetInnerHTML={html(d.how)} />
              <p className="px__itemmeta">
                <span className="px__metalabel">{t.cost}:</span>{" "}
                <span dangerouslySetInnerHTML={html(d.cost)} />
              </p>
            </div>
          ))}
        </section>

        {port.myths.length > 0 && (
          <section className="px__section px__section--myth">
            <h4 className="px__sectitle">{t.myth}</h4>
            {port.myths.map((m) => (
              <div className="px__item" key={m.claim}>
                <span className="px__itemname px__itemname--struck" dangerouslySetInnerHTML={html(m.claim)} />
                <p className="px__itemhow" dangerouslySetInnerHTML={html(m.why)} />
              </div>
            ))}
          </section>
        )}

        <footer className="px__foot">
          <span className="px__metalabel">{t.sources}:</span>{" "}
          {port.sources.map((s, i) => (
            <span key={s.url}>
              {i > 0 && " · "}
              <a href={s.url} rel="noopener noreferrer" target="_blank">{s.label}</a>
            </span>
          ))}
        </footer>
      </article>
    </div>
  );
}
