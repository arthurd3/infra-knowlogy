import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * As invariantes do mapa de mercado.
 *
 * `skills.json` cruza o que 40 vagas pediam com o que este repositório PROVA.
 * É um roadmap — e roadmap é o gênero de documento que envelhece mentindo:
 * alguém marca "coberto", a lição nunca é escrita, e seis meses depois o mapa
 * anuncia uma cobertura que não existe.
 *
 * O princípio inegociável do repositório é que toda afirmação técnica precisa
 * ser verificável por um comando. Este arquivo estende o princípio à afirmação
 * de COBERTURA: dizer "coberto" exige apontar para uma lição que existe nos
 * dois idiomas, e para uma checagem de portão ou um arquivo de medição que
 * existe de verdade. Item sem evidência não passa de "ausente".
 *
 * A regra mais importante é a última: **`ausente` e `parcial` têm que dizer o
 * que falta.** Um mapa que só se gaba do que tem não serve para planejar nada.
 */

const HERE = import.meta.dirname;
const DATA = join(HERE, "../src/data");
const LESSONS = join(HERE, "../src/content/lessons");
const SCRIPTS = join(HERE, "../../tools/scripts");

type Status = "coberto" | "citado" | "parcial" | "ausente";

interface Evidence { lessons: string[]; checks: string[]; measurements: string[] }
interface Side { label: string; gap: string }
interface Demand {
  id: string; demand: number; quadrant: string; status: Status;
  pt: Side; en: Side; evidence: Evidence;
}
interface Item { name: string; status: Status; lesson?: string; note_pt?: string; note_en?: string }
interface Quadrant { id: string; pt: string; en: string; items: Item[] }

const doc = JSON.parse(readFileSync(join(DATA, "skills.json"), "utf8")) as {
  poster: { author: string; sample: number; accessed: string; redrawn: boolean };
  legend: { status: Record<Status, { pt: string; en: string }> };
  demands: Demand[];
  quadrants: Quadrant[];
};

/**
 * Chaves de lição que existem, por idioma — e se cada uma carrega `FieldNote`.
 *
 * O FieldNote importa aqui por causa do estado `citado`: ele é a afirmação
 * CITADA e não medida (ADR 0009), e é o único jeito honesto de ensinar o que
 * esta máquina não consegue provar. Um item `citado` sem FieldNote seria
 * prosa sem procedência — exatamente o que o ADR 0009 existe para impedir.
 */
function scanOf(lang: "pt" | "en") {
  const dir = join(LESSONS, lang);
  const keys = new Set<string>();
  const comFieldNote = new Set<string>();
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".mdx"))) {
    const raw = readFileSync(join(dir, f), "utf8");
    const m = raw.match(/^key:\s*(\S+)\s*$/m);
    if (!m) continue;
    keys.add(m[1]);
    if (/<FieldNote[\s>]/.test(raw)) comFieldNote.add(m[1]);
  }
  return { keys, comFieldNote };
}
const PT = scanOf("pt");
const EN = scanOf("en");
const KEYS = { pt: PT.keys, en: EN.keys };

/** Todo o texto dos portões, concatenado. É onde uma checagem tem que existir. */
const GATES = readdirSync(SCRIPTS)
  .filter((n) => n.endsWith(".sh"))
  .map((n) => readFileSync(join(SCRIPTS, n), "utf8"))
  .join("\n");

const DATA_FILES = new Set(readdirSync(DATA).filter((n) => n.endsWith(".json")));

describe("procedência do cartaz", () => {
  it("credita a autoria da análise e diz quando foi consultada", () => {
    expect(doc.poster.author.length).toBeGreaterThan(0);
    expect(doc.poster.sample).toBeGreaterThan(0);
    expect(doc.poster.accessed).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it("o cartaz é REDESENHADO, nunca republicado", () => {
    // ADR 0010: imagem de terceiro sem licença apurada não entra. O diagrama
    // do site é SVG escrito aqui; o PNG original não está no repositório.
    expect(doc.poster.redrawn).toBe(true);
  });
});

describe("a evidência existe de verdade", () => {
  it("toda lição citada existe nos DOIS idiomas", () => {
    const erros: string[] = [];
    for (const d of doc.demands) {
      for (const key of d.evidence.lessons) {
        if (!KEYS.pt.has(key)) erros.push(`${d.id}: lição "${key}" não existe em pt`);
        if (!KEYS.en.has(key)) erros.push(`${d.id}: lição "${key}" não existe em en`);
      }
    }
    expect(erros).toEqual([]);
  });

  it("toda checagem citada aparece literalmente num portão", () => {
    // Frágil de propósito: renomear uma checagem quebra este teste, e quem
    // renomeou é obrigado a olhar o mapa. É melhor do que o mapa apontar para
    // uma checagem que deixou de existir sem ninguém notar.
    const erros = doc.demands.flatMap((d) =>
      d.evidence.checks.filter((c) => !GATES.includes(c)).map((c) => `${d.id}: "${c}"`),
    );
    expect(erros).toEqual([]);
  });

  it("todo arquivo de medição citado existe", () => {
    const erros = doc.demands.flatMap((d) =>
      d.evidence.measurements.filter((m) => !DATA_FILES.has(m)).map((m) => `${d.id}: ${m}`),
    );
    expect(erros).toEqual([]);
  });
});

describe("o status é honesto nos dois sentidos", () => {
  it("'coberto' exige lição E (checagem ou medição)", () => {
    const erros: string[] = [];
    for (const d of doc.demands.filter((x) => x.status === "coberto")) {
      if (d.evidence.lessons.length === 0) erros.push(`${d.id}: coberto sem lição nenhuma`);
      if (d.evidence.checks.length + d.evidence.measurements.length === 0) {
        erros.push(`${d.id}: coberto sem checagem nem medição`);
      }
    }
    expect(erros).toEqual([]);
  });

  it("'citado' exige lição bilíngue COM FieldNote, e proíbe checagem", () => {
    // As duas metades da regra fazem trabalhos diferentes.
    //
    // Exigir lição com FieldNote impede que `citado` vire um jeito elegante de
    // dizer "não fiz": para usá-lo, alguém precisa ter escrito a lição e
    // apurado a fonte.
    //
    // PROIBIR checagem é o que dá sentido ao estado. Se existe comando que
    // prova, o item é `coberto` — e deixar os dois conviverem transformaria
    // `citado` num refúgio para não escrever a checagem que daria trabalho.
    const erros: string[] = [];
    for (const d of doc.demands.filter((x) => x.status === "citado")) {
      if (d.evidence.lessons.length === 0) erros.push(`${d.id}: citado sem lição`);
      if (d.evidence.checks.length > 0) {
        erros.push(`${d.id}: citado COM checagem — se dá para checar, é coberto`);
      }
      for (const k of d.evidence.lessons) {
        if (!PT.comFieldNote.has(k) || !EN.comFieldNote.has(k)) {
          erros.push(`${d.id}: a lição "${k}" não tem FieldNote nos dois idiomas`);
        }
      }
    }
    expect(erros).toEqual([]);
  });

  it("todo chip 'citado' nomeia a lição que o ensina", () => {
    // O chip não tem bloco `evidence` como a demanda tem — ele ganha um campo
    // `lesson`. Sem ele, `citado` num chip seria uma afirmação sem endereço.
    const erros: string[] = [];
    for (const q of doc.quadrants) {
      for (const i of q.items.filter((x) => x.status === "citado")) {
        if (!i.lesson) { erros.push(`${q.id}/${i.name}: citado sem campo lesson`); continue; }
        if (!PT.keys.has(i.lesson) || !EN.keys.has(i.lesson)) {
          erros.push(`${q.id}/${i.name}: lição "${i.lesson}" não existe nos dois idiomas`);
        } else if (!PT.comFieldNote.has(i.lesson) || !EN.comFieldNote.has(i.lesson)) {
          erros.push(`${q.id}/${i.name}: a lição "${i.lesson}" não tem FieldNote`);
        }
      }
    }
    expect(erros).toEqual([]);
  });

  it("'ausente' não pode ter evidência — se tem, é pelo menos parcial", () => {
    const erros = doc.demands
      .filter((d) => d.status === "ausente")
      .filter((d) => d.evidence.lessons.length + d.evidence.checks.length + d.evidence.measurements.length > 0)
      .map((d) => d.id);
    expect(erros).toEqual([]);
  });

  it("'parcial' precisa de alguma evidência — senão é ausente", () => {
    const erros = doc.demands
      .filter((d) => d.status === "parcial")
      .filter((d) => d.evidence.lessons.length + d.evidence.checks.length + d.evidence.measurements.length === 0)
      .map((d) => d.id);
    expect(erros).toEqual([]);
  });

  it("todo status usado está na legenda", () => {
    const validos = new Set(Object.keys(doc.legend.status));
    const todos = [
      ...doc.demands.map((d) => d.status),
      ...doc.quadrants.flatMap((q) => q.items.map((i) => i.status)),
    ];
    expect([...new Set(todos)].filter((s) => !validos.has(s))).toEqual([]);
  });
});

describe("a regra editorial: o mapa tem que dizer o que falta", () => {
  it("toda demanda explica a lacuna, nos dois idiomas", () => {
    // 120 caracteres é o mesmo piso do `how` em ports.json, e pela mesma
    // razão: "falta observabilidade" é um rótulo, não uma informação. Quem lê
    // precisa saber O QUE falta para decidir se vale estudar.
    const erros: string[] = [];
    for (const d of doc.demands) {
      for (const lang of ["pt", "en"] as const) {
        const gap = d[lang].gap ?? "";
        if (gap.length < 120) erros.push(`${d.id}.${lang}: lacuna com ${gap.length} caracteres`);
        if (!d[lang].label) erros.push(`${d.id}.${lang}: sem rótulo`);
      }
    }
    expect(erros).toEqual([]);
  });

  it("as 7 demandas do cartaz estão todas aqui, com percentual plausível", () => {
    expect(doc.demands).toHaveLength(7);
    for (const d of doc.demands) {
      expect(d.demand).toBeGreaterThan(0);
      expect(d.demand).toBeLessThanOrEqual(100);
    }
  });

  it("toda demanda pertence a um quadrante que existe", () => {
    const ids = new Set(doc.quadrants.map((q) => q.id));
    expect(doc.demands.filter((d) => !ids.has(d.quadrant)).map((d) => d.id)).toEqual([]);
  });

  it("item de quadrante com nota traz as duas línguas", () => {
    const erros = doc.quadrants.flatMap((q) =>
      q.items
        .filter((i) => Boolean(i.note_pt) !== Boolean(i.note_en))
        .map((i) => `${q.id}/${i.name}`),
    );
    expect(erros).toEqual([]);
  });
});
