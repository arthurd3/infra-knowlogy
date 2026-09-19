import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { inline } from "../src/components/islands/QuizBoard";

/**
 * As invariantes das perguntas.
 *
 * Um quiz é conteúdo, e conteúdo bilíngue erra do mesmo jeito que as lições:
 * a versão inglesa fica com uma pergunta a menos, ou com a explicação copiada
 * do português, e nada reprova — o widget renderiza feliz. Estes testes são o
 * que torna esses descuidos barulhentos.
 *
 * A regra mais importante aqui é a do `why` em TODA alternativa. É ela que
 * separa "checagem de entendimento" de "jogo de adivinhar o gabarito": saber
 * por que a errada está errada é onde o aprendizado acontece, e uma alternativa
 * sem explicação é uma alternativa que não ensina nada a quem a escolheu.
 */

const QUIZZES = join(import.meta.dirname, "../src/data/quizzes");
const LESSONS = join(import.meta.dirname, "../src/content/lessons");

interface Option { text: string; correct?: boolean; why: string }
interface Question { q: string; options: Option[] }
interface QuizFile { pt: Question[]; en: Question[] }

const files = readdirSync(QUIZZES).filter((f) => f.endsWith(".json"));
const sets = new Map<string, QuizFile>(
  files.map((f) => [f.replace(/\.json$/, ""), JSON.parse(readFileSync(join(QUIZZES, f), "utf8"))]),
);

/** Todo `set="…"` citado por uma lição, com o arquivo que o cita. */
const referenced: Array<{ file: string; set: string }> = [];
for (const lang of readdirSync(LESSONS)) {
  for (const file of readdirSync(join(LESSONS, lang))) {
    if (!file.endsWith(".mdx")) continue;
    const body = readFileSync(join(LESSONS, lang, file), "utf8");
    for (const m of body.matchAll(/<Quiz[^>]*\sset="([^"]+)"/g)) {
      referenced.push({ file: `${lang}/${file}`, set: m[1] });
    }
  }
}

describe("conjuntos de perguntas", () => {
  it("existe pelo menos um", () => {
    expect(sets.size).toBeGreaterThan(0);
  });

  it("todo conjunto citado por uma lição existe em disco", () => {
    // Um `set` escrito errado derruba o build (Quiz.astro lança), mas só
    // quando aquela página é gerada. Aqui a falha é imediata e nomeia o arquivo.
    const faltando = referenced.filter((r) => !sets.has(r.set)).map((r) => `${r.file}: ${r.set}`);
    expect(faltando).toEqual([]);
  });

  it("todo conjunto em disco é citado por alguma lição", () => {
    const citados = new Set(referenced.map((r) => r.set));
    expect([...sets.keys()].filter((s) => !citados.has(s))).toEqual([]);
  });

  it("todo conjunto tem os dois idiomas, com o mesmo número de perguntas", () => {
    for (const [name, q] of sets) {
      expect(Array.isArray(q.pt), `${name}: sem pt`).toBe(true);
      expect(Array.isArray(q.en), `${name}: sem en`).toBe(true);
      expect(q.en.length, `${name}: pt e en discordam na contagem`).toBe(q.pt.length);
      expect(q.pt.length, `${name}: conjunto vazio`).toBeGreaterThan(0);
    }
  });

  it("o par de idiomas mantém o número de alternativas e qual delas é a certa", () => {
    // Se a alternativa correta estiver em posições diferentes, uma das duas
    // versões está com o gabarito trocado — e o leitor daquele idioma aprende
    // o contrário do que a lição ensina.
    const erros: string[] = [];
    for (const [name, quiz] of sets) {
      quiz.pt.forEach((q, i) => {
        const en = quiz.en[i];
        if (!en) return;
        if (q.options.length !== en.options.length) {
          erros.push(`${name}[${i}]: ${q.options.length} alternativas em pt, ${en.options.length} em en`);
        }
        const at = (qq: Question) => qq.options.findIndex((o) => o.correct);
        if (at(q) !== at(en)) erros.push(`${name}[${i}]: gabarito em posições diferentes`);
      });
    }
    expect(erros).toEqual([]);
  });
});

describe("estrutura de cada pergunta", () => {
  it("tem exatamente uma alternativa correta", () => {
    const erros: string[] = [];
    for (const [name, quiz] of sets) {
      for (const lang of ["pt", "en"] as const) {
        quiz[lang].forEach((q, i) => {
          const n = q.options.filter((o) => o.correct).length;
          if (n !== 1) erros.push(`${name}.${lang}[${i}]: ${n} alternativas corretas`);
        });
      }
    }
    expect(erros).toEqual([]);
  });

  it("tem pelo menos duas alternativas", () => {
    const erros: string[] = [];
    for (const [name, quiz] of sets) {
      for (const lang of ["pt", "en"] as const) {
        quiz[lang].forEach((q, i) => {
          if (q.options.length < 2) erros.push(`${name}.${lang}[${i}]`);
        });
      }
    }
    expect(erros).toEqual([]);
  });

  it("TODA alternativa explica por que está certa ou errada", () => {
    const erros: string[] = [];
    for (const [name, quiz] of sets) {
      for (const lang of ["pt", "en"] as const) {
        quiz[lang].forEach((q, i) => {
          q.options.forEach((o, j) => {
            if (!o.why || o.why.trim().length < 20) {
              erros.push(`${name}.${lang}[${i}].${j}: explicação ausente ou curta demais`);
            }
            if (!o.text?.trim()) erros.push(`${name}.${lang}[${i}].${j}: alternativa sem texto`);
          });
          if (!q.q?.trim()) erros.push(`${name}.${lang}[${i}]: pergunta sem texto`);
        });
      }
    }
    expect(erros).toEqual([]);
  });

  it("o inglês não é o português copiado", () => {
    // Mesma defesa de i18n.test.ts: copiar e esquecer de traduzir passa calado.
    const iguais: string[] = [];
    for (const [name, quiz] of sets) {
      quiz.pt.forEach((q, i) => {
        const en = quiz.en[i];
        if (en && q.q === en.q) iguais.push(`${name}[${i}]: pergunta idêntica`);
        q.options.forEach((o, j) => {
          if (en?.options[j] && o.why === en.options[j].why) {
            iguais.push(`${name}[${i}].${j}: explicação idêntica`);
          }
        });
      });
    }
    expect(iguais).toEqual([]);
  });
});

describe("markdown inline das perguntas", () => {
  it("vira código e negrito", () => {
    expect(inline("roda `docker stop` agora")).toBe("roda <code>docker stop</code> agora");
    expect(inline("é **sempre** assim")).toBe("é <strong>sempre</strong> assim");
  });

  it("escapa markup antes de converter", () => {
    // O conteúdo é nosso, mas ele vai para dentro de dangerouslySetInnerHTML.
    // Uma pergunta que cite `<script>` ou uma porta `-p 80:80` não pode virar
    // markup — e o escape precisa acontecer ANTES da conversão, ou o <code>
    // recém-criado seria escapado junto.
    expect(inline("<script>alert(1)</script>")).not.toContain("<script>");
    expect(inline("use `<Callout>`")).toBe("use <code>&lt;Callout&gt;</code>");
    expect(inline("a & b")).toBe("a &amp; b");
  });
});
