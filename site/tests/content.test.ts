import { readFileSync, readdirSync } from "node:fs";
import { basename, join } from "node:path";
import { describe, expect, it } from "vitest";
import { TRACKS } from "../src/i18n/ui";

/**
 * As invariantes do conteúdo bilíngue.
 *
 * A paridade de lições já era checada por um heredoc Python dentro do
 * verify.sh. Aqui ela fica junto das outras — e ganha as duas checagens que
 * faltavam e que os diagramas tornaram necessárias:
 *
 *   1. as duas versões de uma lição usam os MESMOS componentes. Os diagramas
 *      foram inseridos por âncora de texto; uma âncora escrita errado deixa a
 *      lição inglesa sem o desenho e NADA reprova — o build passa igual.
 *   2. todo componente citado num MDX existe em disco. Um import quebrado
 *      derruba o build, mas um componente citado e não importado não.
 */

const LESSONS = join(import.meta.dirname, "../src/content/lessons");
const COMPONENTS = join(import.meta.dirname, "../src/components");

interface Lesson {
  file: string;
  lang: string;
  key: string;
  track: string;
  order: number;
  minutes: number;
  tags: string[];
  /** O bloco YAML entre os dois `---`. */
  frontmatter: string;
  body: string;
  components: string[];
}

/** O corpo sem blocos cercados nem código em linha. */
function prose(body: string): string {
  return body.replace(/```[\s\S]*?```/g, "").replace(/`[^`\n]*`/g, "");
}

function field(fm: string, name: string): string | undefined {
  return fm.match(new RegExp(`^${name}:\\s*(.+)$`, "m"))?.[1].trim();
}

function load(): Lesson[] {
  const out: Lesson[] = [];
  for (const lang of readdirSync(LESSONS)) {
    for (const file of readdirSync(join(LESSONS, lang))) {
      if (!file.endsWith(".mdx")) continue;
      const raw = readFileSync(join(LESSONS, lang, file), "utf8");
      const fm = raw.split("---")[1];
      const body = raw.slice(raw.indexOf("---", 3) + 3);
      out.push({
        file: `${lang}/${file}`,
        lang: field(fm, "lang")!,
        key: field(fm, "key")!,
        track: field(fm, "track")!,
        order: Number(field(fm, "order")),
        minutes: Number(field(fm, "minutes") ?? 10),
        tags: (field(fm, "tags") ?? "[]").replace(/[[\]]/g, "").split(",").map((t) => t.trim()).filter(Boolean),
        frontmatter: fm,
        body,
        // Componentes de fato usados no corpo, não só importados. O texto
        // passa antes por um filtro que apaga blocos e trechos de código:
        // sem ele, o `<<EOF` de um heredoc e o `${VAR}` de um Compose viram
        // "componentes" inexistentes.
        components: [...new Set(
          [...prose(body).matchAll(/<([A-Z]\w+)[\s/>]/g)].map((m) => m[1]),
        )].sort(),
      });
    }
  }
  return out;
}

const lessons = load();
const byKey = new Map<string, Lesson[]>();
for (const l of lessons) byKey.set(l.key, [...(byKey.get(l.key) ?? []), l]);

/** Todo componente disponível em disco, pelo nome do arquivo. */
const available = new Set<string>();
for (const dir of ["", "diagrams", "islands"]) {
  for (const f of readdirSync(join(COMPONENTS, dir))) {
    if (/\.(astro|tsx)$/.test(f)) available.add(basename(f).replace(/\.(astro|tsx)$/, ""));
  }
}
// Injetados pela página da lição ([slug].astro), sem import no MDX. Eles
// pegam o idioma da URL; passá-los como prop em cada arquivo era o que fazia
// a lição inglesa herdar rótulo em português quando alguém esquecia.
const INJETADOS = ["Callout", "RunIt", "Tradeoff", "FieldNote", "LabExercise", "Quiz", "Figure"];
for (const c of INJETADOS) available.add(c);
// `Fragment` é do próprio Astro e é como o MDX preenche um slot nomeado.
available.add("Fragment");

describe("paridade entre os idiomas", () => {
  it("toda lição existe em pt e en, com a mesma chave", () => {
    const solo = [...byKey.entries()]
      .filter(([, v]) => new Set(v.map((l) => l.lang)).size !== 2)
      .map(([k, v]) => `${k} (só em ${v.map((l) => l.lang).join(", ")})`);
    expect(solo).toEqual([]);
    expect(byKey.size).toBeGreaterThan(0);
  });

  it("o par mantém trilha e ordem", () => {
    for (const [key, pair] of byKey) {
      const [a, b] = pair;
      expect(b.track, `trilha diferente em ${key}`).toBe(a.track);
      expect(b.order, `ordem diferente em ${key}`).toBe(a.order);
    }
  });

  it("o par usa os mesmos componentes", () => {
    const diffs: string[] = [];
    for (const [key, pair] of byKey) {
      const [a, b] = pair;
      const only = (x: Lesson, y: Lesson) => x.components.filter((c) => !y.components.includes(c));
      const missingInB = only(a, b);
      const missingInA = only(b, a);
      if (missingInB.length || missingInA.length) {
        diffs.push(`${key}: ${a.lang} tem [${missingInB}] a mais, ${b.lang} tem [${missingInA}] a mais`);
      }
    }
    expect(diffs).toEqual([]);
  });

  it("o par tem o mesmo número de blocos de código e de callouts", () => {
    const count = (s: string, re: RegExp) => (s.match(re) ?? []).length;
    const diffs: string[] = [];
    for (const [key, pair] of byKey) {
      const [a, b] = pair;
      const PARES = [
        ["```", /```/g], ["<Callout", /<Callout/g], ["<RunIt", /<RunIt/g],
        ["<Tradeoff", /<Tradeoff/g], ["<FieldNote", /<FieldNote/g],
        ["<LabExercise", /<LabExercise/g], ["<Quiz", /<Quiz/g],
      ] as const;
      for (const [label, re] of PARES) {
        if (count(a.body, re) !== count(b.body, re)) {
          diffs.push(`${key}: ${label} ${count(a.body, re)} em ${a.lang} vs ${count(b.body, re)} em ${b.lang}`);
        }
      }
    }
    expect(diffs).toEqual([]);
  });
});

describe("integridade do frontmatter", () => {
  it("a ordem é única dentro de cada trilha e idioma", () => {
    const seen = new Map<string, string>();
    for (const l of lessons) {
      const slot = `${l.lang}/${l.track}/${l.order}`;
      expect(seen.get(slot), `ordem repetida: ${slot}`).toBeUndefined();
      seen.set(slot, l.file);
    }
  });

  it("trilha, minutos e tags estão preenchidos e plausíveis", () => {
    for (const l of lessons) {
      expect(TRACKS as readonly string[], l.file).toContain(l.track);
      expect(l.order, l.file).toBeGreaterThan(0);
      expect(l.minutes, l.file).toBeGreaterThan(0);
      expect(l.minutes, `${l.file}: tempo de leitura implausível`).toBeLessThan(60);
      expect(l.tags.length, `${l.file}: sem tags`).toBeGreaterThan(0);
    }
  });

  it("o idioma do frontmatter bate com a pasta", () => {
    for (const l of lessons) expect(l.file.startsWith(`${l.lang}/`), l.file).toBe(true);
  });
});

describe("componentes citados nas lições", () => {
  it("todos existem em src/components", () => {
    const faltando = new Set<string>();
    for (const l of lessons) {
      for (const c of l.components) if (!available.has(c)) faltando.add(`${l.file}: <${c}>`);
    }
    expect([...faltando]).toEqual([]);
  });

  it("todo componente usado está importado (fora os injetados pela página)", () => {
    const injetados = new Set([...INJETADOS, "Fragment"]);
    const faltando: string[] = [];
    for (const l of lessons) {
      for (const c of l.components) {
        if (injetados.has(c)) continue;
        if (!new RegExp(`^import ${c} from`, "m").test(l.body)) faltando.push(`${l.file}: <${c}>`);
      }
    }
    expect(faltando).toEqual([]);
  });

  it("as ilhas React recebem client: e lang do idioma da lição", () => {
    // Uma ilha sem diretiva client: vira HTML morto — renderiza e não reage.
    // Já com o lang errado, a lição inglesa ganha um widget em português.
    const erros: string[] = [];
    for (const l of lessons) {
      for (const m of prose(l.body).matchAll(/<([A-Z]\w+)([^>]*)\/>/g)) {
        const [, name, attrs] = m;
        const isIsland = /\.tsx/.test(l.body.match(new RegExp(`^import ${name} from "(.+)"`, "m"))?.[1] ?? "");
        if (!isIsland) continue;
        if (!/client:/.test(attrs)) erros.push(`${l.file}: <${name}> sem client:`);
        if (!new RegExp(`lang="${l.lang}"`).test(attrs)) erros.push(`${l.file}: <${name}> sem lang="${l.lang}"`);
      }
    }
    expect(erros).toEqual([]);
  });
});

describe("cobertura visual", () => {
  it("toda lição tem ao menos um diagrama ou widget", () => {
    // O déficit que motivou este trabalho: 22 lições, zero imagens. Se uma
    // lição nova nascer só com texto, este teste avisa.
    //
    // Componentes de moldura não contam: uma lição feita só de Callout e Quiz
    // continua sendo uma lição sem desenho nenhum.
    const MOLDURA = new Set(["Callout", "RunIt", "Tradeoff", "FieldNote", "LabExercise", "Quiz", "Fragment"]);
    const semNada = lessons
      .filter((l) => !l.components.some((c) => !MOLDURA.has(c)))
      .map((l) => l.file);
    expect(semNada).toEqual([]);
  });
});

describe("cobertura de exercício", () => {
  it("toda lição pergunta alguma coisa ao leitor", () => {
    // O irmão do teste acima. Uma lição pode estar impecável e ainda deixar o
    // leitor sem nenhum jeito de saber se entendeu — ler não é o mesmo que
    // aprender. `Quiz` checa o entendimento; `LabExercise` manda provar no
    // terminal. Uma das duas, no mínimo.
    const semExercicio = lessons
      .filter((l) => !l.components.includes("Quiz") && !l.components.includes("LabExercise"))
      .map((l) => l.file);
    expect(semExercicio).toEqual([]);
  });
});

describe("procedência do que não foi medido aqui", () => {
  it("todo FieldNote nomeia a fonte e linka para ela", () => {
    // O componente inteiro existe para marcar a fronteira entre o que esta
    // máquina mediu e o que alguém relatou (ADR 0009). Um FieldNote sem `url`
    // é exatamente o que ele foi criado para impedir: uma afirmação sem origem
    // com a aparência de uma afirmação verificada.
    const erros: string[] = [];
    for (const l of lessons) {
      for (const m of prose(l.body).matchAll(/<FieldNote([^>]*)>/g)) {
        const attrs = m[1];
        if (!/\ssource="[^"]+"/.test(attrs)) erros.push(`${l.file}: <FieldNote> sem source`);
        if (!/\surl="https?:\/\/[^"]+"/.test(attrs)) erros.push(`${l.file}: <FieldNote> sem url`);
      }
    }
    expect(erros).toEqual([]);
  });

  it("todo Tradeoff diz quando cada lado ganha", () => {
    // Sem `whenA`/`whenB` isto é uma tabela comparativa, e tabela comparativa
    // devolve a decisão para quem não tem repertório de tomá-la. O critério é
    // o conteúdo; as duas colunas são só a moldura dele.
    const erros: string[] = [];
    for (const l of lessons) {
      for (const m of prose(l.body).matchAll(/<Tradeoff([\s\S]*?)\/>/g)) {
        const attrs = m[1];
        for (const req of ["a", "b", "whenA", "whenB"]) {
          if (!new RegExp(`\\s${req}="[^"]+"`).test(attrs)) {
            erros.push(`${l.file}: <Tradeoff> sem ${req}`);
          }
        }
      }
    }
    expect(erros).toEqual([]);
  });

  it("toda lição com FieldNote cita a fonte no frontmatter também", () => {
    // O relato precisa sobreviver ao fim da leitura: a seção "Fontes" é o que
    // o leitor revisita, e ela é montada só a partir do frontmatter.
    const erros: string[] = [];
    for (const l of lessons) {
      const urls = [...prose(l.body).matchAll(/<FieldNote[^>]*\surl="([^"]+)"/g)].map((m) => m[1]);
      for (const url of urls) {
        if (!l.frontmatter.includes(url)) erros.push(`${l.file}: ${url} não está em sources:`);
      }
    }
    expect(erros).toEqual([]);
  });
});
