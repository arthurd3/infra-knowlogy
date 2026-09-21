import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * As invariantes da trilha de estudo.
 *
 * `library.json` é a camada que o `sources:` de cada lição NÃO é. As fontes no
 * rodapé de uma lição são o que foi usado para escrevê-la; a biblioteca é o
 * caminho para ir além, indexado por CONCEITO — porque conceito atravessa
 * lição, e "namespaces" aparece na 1 e reaparece na 7.
 *
 * Misturar as duas seria repetir o erro que o ADR 0009 corrigiu para afirmação
 * medida × citada: um livro que eu não li para escrever a lição não é fonte
 * dela, e fingir que é corrói a única coisa que dá valor à bibliografia daqui.
 *
 * Três regras aqui são editoriais, e são a razão de o arquivo existir em vez
 * de uma lista de links no fim de cada página:
 *
 *   1. **Toda referência diz por que ELA.** Lista sem justificativa é lista
 *      que ninguém segue — e é o que faz "leitura recomendada" ser a seção
 *      que todo leitor pula.
 *   2. **Todo conceito tem ao menos uma opção gratuita.** Uma trilha feita só
 *      de livro pago exclui exatamente quem mais precisa dela.
 *   3. **Todo conceito tem ao menos uma indicação audiovisual.** Texto não é
 *      o único jeito de entrar num assunto, e para vários conceitos daqui a
 *      demonstração ao vivo ensina mais rápido que o capítulo.
 */

const HERE = import.meta.dirname;
const LESSONS = join(HERE, "../src/content/lessons");

type Kind = "book" | "zine" | "talk" | "video" | "article" | "spec" | "docs";

interface Ref {
  kind: Kind; title: string; author: string; where: string; year: number;
  lang: "pt" | "en"; url: string; free: boolean; accessed: string;
  why_pt: string; why_en: string; isbn?: string; minutes?: number;
}
interface Side { label: string; what: string }
interface Concept { id: string; lessons: string[]; pt: Side; en: Side; refs: Ref[] }

const doc = JSON.parse(readFileSync(join(HERE, "../src/data/library.json"), "utf8")) as {
  kinds: Record<Kind, { pt: string; en: string }>;
  concepts: Concept[];
};

/** Chaves de lição existentes, por idioma, e a que trilha cada uma pertence. */
function scan(lang: "pt" | "en") {
  const keys = new Map<string, string>();
  for (const f of readdirSync(join(LESSONS, lang)).filter((n) => n.endsWith(".mdx"))) {
    const raw = readFileSync(join(LESSONS, lang, f), "utf8");
    const key = raw.match(/^key:\s*(\S+)\s*$/m)?.[1];
    const track = raw.match(/^track:\s*(\S+)\s*$/m)?.[1];
    if (key && track) keys.set(key, track);
  }
  return keys;
}
const PT = scan("pt");
const EN = scan("en");

const ALL_REFS = doc.concepts.flatMap((c) => c.refs.map((r) => ({ c, r })));
const AUDIOVISUAL = new Set<Kind>(["talk", "video"]);

describe("a referência é real e está descrita", () => {
  it("toda referência declara autor, veículo, ano, idioma e data de consulta", () => {
    const erros: string[] = [];
    for (const { c, r } of ALL_REFS) {
      const onde = `${c.id}/${r.title}`;
      if (!r.author?.trim()) erros.push(`${onde}: sem autor`);
      if (!r.where?.trim()) erros.push(`${onde}: sem veículo`);
      if (!(r.year >= 1980 && r.year <= 2100)) erros.push(`${onde}: ano implausível (${r.year})`);
      if (!["pt", "en"].includes(r.lang)) erros.push(`${onde}: idioma inválido`);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(r.accessed)) erros.push(`${onde}: sem accessed`);
      if (typeof r.free !== "boolean") erros.push(`${onde}: não diz se é gratuita`);
      if (!/^https:\/\//.test(r.url)) erros.push(`${onde}: url não é https`);
    }
    expect(erros).toEqual([]);
  });

  it("todo tipo usado está na legenda", () => {
    const validos = new Set(Object.keys(doc.kinds));
    expect([...new Set(ALL_REFS.map(({ r }) => r.kind))].filter((k) => !validos.has(k))).toEqual([]);
  });

  it("livro traz ISBN ou link de editora — nunca só um título", () => {
    // Título de livro é a coisa mais fácil de errar de memória: ano, edição e
    // até autor saem trocados. ISBN ou página da editora é o que deixa o
    // leitor conferir que o livro que ele comprou é o que está escrito aqui.
    const erros = ALL_REFS
      .filter(({ r }) => r.kind === "book")
      .filter(({ r }) => !r.isbn && !/^https:\/\/(www\.)?(nostarch|oreilly|informit|leanpub|man7|ostep|brendangregg|sre\.google|itrevolution|livro\.descomplicando)/.test(r.url))
      .map(({ c, r }) => `${c.id}/${r.title}`);
    expect(erros).toEqual([]);
  });

  it("vídeo e palestra apontam para o YouTube, com link de vídeo ou playlist", () => {
    const erros = ALL_REFS
      .filter(({ r }) => AUDIOVISUAL.has(r.kind))
      .filter(({ r }) => !/^https:\/\/www\.youtube\.com\/(watch\?v=|playlist\?list=)/.test(r.url))
      .map(({ c, r }) => `${c.id}/${r.title}: ${r.url}`);
    expect(erros).toEqual([]);
  });

  it("a mesma referência não aparece duas vezes no mesmo conceito", () => {
    const erros: string[] = [];
    for (const c of doc.concepts) {
      const urls = c.refs.map((r) => r.url);
      const dup = urls.filter((u, i) => urls.indexOf(u) !== i);
      for (const d of new Set(dup)) erros.push(`${c.id}: ${d}`);
    }
    expect(erros).toEqual([]);
  });
});

describe("as três regras editoriais", () => {
  it("toda referência explica por que ELA, nos dois idiomas", () => {
    // 120 caracteres é o mesmo piso do `how` em ports.json e da lacuna em
    // skills.json, e pela mesma razão: "ótimo livro" não é informação. O
    // leitor precisa saber o que ESTA referência entrega que as outras não.
    const erros: string[] = [];
    for (const { c, r } of ALL_REFS) {
      for (const lang of ["pt", "en"] as const) {
        const why = r[`why_${lang}`] ?? "";
        if (why.length < 120) erros.push(`${c.id}/${r.title} [${lang}]: ${why.length} caracteres`);
      }
    }
    expect(erros).toEqual([]);
  });

  it("todo conceito oferece ao menos um caminho GRATUITO", () => {
    const erros = doc.concepts.filter((c) => !c.refs.some((r) => r.free)).map((c) => c.id);
    expect(erros).toEqual([]);
  });

  it("todo conceito oferece ao menos uma indicação audiovisual", () => {
    const erros = doc.concepts.filter((c) => !c.refs.some((r) => AUDIOVISUAL.has(r.kind))).map((c) => c.id);
    expect(erros).toEqual([]);
  });

  it("todo conceito explica o que é, nos dois idiomas", () => {
    const erros: string[] = [];
    for (const c of doc.concepts) {
      for (const lang of ["pt", "en"] as const) {
        if (!c[lang]?.label) erros.push(`${c.id}.${lang}: sem rótulo`);
        if ((c[lang]?.what ?? "").length < 80) erros.push(`${c.id}.${lang}: 'what' curto demais`);
      }
    }
    expect(erros).toEqual([]);
  });
});

describe("a ligação com as lições", () => {
  it("toda lição citada existe nos dois idiomas", () => {
    const erros: string[] = [];
    for (const c of doc.concepts) {
      for (const k of c.lessons) {
        if (!PT.has(k)) erros.push(`${c.id}: "${k}" não existe em pt`);
        if (!EN.has(k)) erros.push(`${c.id}: "${k}" não existe em en`);
      }
    }
    expect(erros).toEqual([]);
  });

  it("toda lição de Fundamentos tem ao menos um conceito ligado a ela", () => {
    // A regra de cobertura, e a razão de este teste existir: a trilha de
    // entrada é a que mais precisa de caminho para ir além, e é justamente a
    // que ficaria sem se ninguém contasse.
    const cobertas = new Set(doc.concepts.flatMap((c) => c.lessons));
    const descobertas = [...PT.entries()]
      .filter(([, track]) => track === "fundamentos")
      .map(([key]) => key)
      .filter((key) => !cobertas.has(key));
    expect(descobertas).toEqual([]);
  });
});
