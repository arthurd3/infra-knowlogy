import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * As invariantes do cartaz de portas.
 *
 * `ports.json` é o conteúdo da trilha de Segurança em forma de dado: o widget
 * `PortExplorer` só o apresenta. Isso é bom — o mesmo arquivo alimenta o site e
 * o índice do Qdrant — e traz o risco de sempre: conteúdo bilíngue erra calado.
 * A versão inglesa fica com um ataque a menos, a defesa entra sem o custo, e o
 * build passa feliz.
 *
 * Duas regras aqui não são formais, são editoriais, e são o motivo de o arquivo
 * existir em vez de uma tabela copiada do cartaz:
 *
 *   1. Todo ataque explica o MECANISMO (`how`). "Força bruta" sem o como é um
 *      rótulo; o leigo que ler só o rótulo continua sem saber o que acontece.
 *   2. Toda defesa declara o CUSTO (`cost`). Defesa sem preço é conselho de
 *      quem nunca operou nada — e é o que faz uma lista de boas práticas ser
 *      ignorada em bloco pela primeira pessoa que tenta aplicá-la.
 */

interface Attack { name: string; how: string; tell?: string }
interface Defense { name: string; how: string; cost: string }
interface Myth { claim: string; why: string }
interface Side { use: string; stackNote: string; attacks: Attack[]; defenses: Defense[]; myths?: Myth[] }
interface Port {
  port: number; service: string; transport: string;
  group: "poster" | "database"; inThisStack: string;
  pt: Side; en: Side;
  sources: Array<{ label: string; url: string }>;
}

const doc = JSON.parse(
  readFileSync(join(import.meta.dirname, "../src/data/ports.json"), "utf8"),
) as { legend: { inThisStack: Record<string, unknown> }; ports: Port[] };

const ports = doc.ports;
const LANGS = ["pt", "en"] as const;

/** As oito do cartaz que originou a trilha. Se uma sumir, a trilha mente. */
const DO_CARTAZ = [22, 23, 25, 53, 80, 443, 445, 3389];

describe("cobertura", () => {
  it("as oito portas do cartaz estão todas aqui", () => {
    const presentes = new Set(ports.filter((p) => p.group === "poster").map((p) => p.port));
    expect(DO_CARTAZ.filter((n) => !presentes.has(n))).toEqual([]);
  });

  it("as portas de banco que o cartaz não tem também estão", () => {
    // É a ponte entre as duas metades da trilha: o cartaz fala de portas e não
    // fala de banco, e a resposta para "como se ataca um banco" começa aqui.
    const bancos = ports.filter((p) => p.group === "database").map((p) => p.port);
    expect(bancos).toContain(5432);
    expect(bancos.length).toBeGreaterThanOrEqual(4);
  });

  it("nenhum número de porta se repete", () => {
    const nums = ports.map((p) => p.port);
    expect(nums.length).toBe(new Set(nums).size);
  });

  it("toda porta declara o que acontece com ela NESTA stack", () => {
    // A coluna que o cartaz não tem, e a que torna o widget verificável: o
    // leitor pode conferir cada resposta com um comando.
    const valores = Object.keys(doc.legend.inThisStack);
    for (const p of ports) {
      expect(valores, `porta ${p.port}: inThisStack inválido`).toContain(p.inThisStack);
      for (const lang of LANGS) {
        expect(p[lang].stackNote.length, `porta ${p.port} [${lang}]: sem stackNote`).toBeGreaterThan(30);
      }
    }
  });
});

describe("estrutura de cada porta", () => {
  it("tem os dois idiomas, com a mesma contagem de tudo", () => {
    const erros: string[] = [];
    for (const p of ports) {
      if (p.pt.attacks.length !== p.en.attacks.length) erros.push(`${p.port}: ataques em número diferente`);
      if (p.pt.defenses.length !== p.en.defenses.length) erros.push(`${p.port}: defesas em número diferente`);
      if ((p.pt.myths ?? []).length !== (p.en.myths ?? []).length) erros.push(`${p.port}: mitos em número diferente`);
    }
    expect(erros).toEqual([]);
  });

  it("tem pelo menos dois ataques e duas defesas", () => {
    for (const p of ports) {
      for (const lang of LANGS) {
        expect(p[lang].attacks.length, `${p.port} [${lang}]`).toBeGreaterThanOrEqual(2);
        expect(p[lang].defenses.length, `${p.port} [${lang}]`).toBeGreaterThanOrEqual(2);
      }
    }
  });

  it("TODO ataque explica o mecanismo, não só o nome", () => {
    const erros: string[] = [];
    for (const p of ports) {
      for (const lang of LANGS) {
        p[lang].attacks.forEach((a, i) => {
          if (!a.name?.trim()) erros.push(`${p.port}.${lang}.ataque[${i}]: sem nome`);
          if (!a.how || a.how.trim().length < 120) {
            erros.push(`${p.port}.${lang}.ataque[${i}] (${a.name}): mecanismo ausente ou curto demais`);
          }
        });
      }
    }
    expect(erros).toEqual([]);
  });

  it("TODA defesa declara o custo", () => {
    const erros: string[] = [];
    for (const p of ports) {
      for (const lang of LANGS) {
        p[lang].defenses.forEach((d, i) => {
          if (!d.how || d.how.trim().length < 60) erros.push(`${p.port}.${lang}.defesa[${i}] (${d.name}): sem como`);
          if (!d.cost?.trim()) erros.push(`${p.port}.${lang}.defesa[${i}] (${d.name}): sem custo`);
        });
      }
    }
    expect(erros).toEqual([]);
  });

  it("todo mito explica por que não funciona", () => {
    const erros: string[] = [];
    for (const p of ports) {
      for (const lang of LANGS) {
        (p[lang].myths ?? []).forEach((m, i) => {
          if (!m.claim?.trim()) erros.push(`${p.port}.${lang}.mito[${i}]: sem afirmação`);
          if (!m.why || m.why.trim().length < 80) erros.push(`${p.port}.${lang}.mito[${i}]: refutação curta demais`);
        });
      }
    }
    expect(erros).toEqual([]);
  });

  it("toda porta cita ao menos uma fonte, com URL válida", () => {
    for (const p of ports) {
      expect(p.sources.length, `porta ${p.port}: sem fonte`).toBeGreaterThan(0);
      for (const s of p.sources) {
        expect(s.label?.trim(), `porta ${p.port}: fonte sem rótulo`).toBeTruthy();
        expect(s.url, `porta ${p.port}: URL suspeita (${s.url})`).toMatch(/^https:\/\/[\w.-]+\/\S*$/);
      }
    }
  });
});

describe("o inglês não é o português copiado", () => {
  it("nenhum texto é idêntico entre os idiomas", () => {
    // Mesma defesa do quiz.test.ts e do i18n.test.ts: traduzir pela metade
    // passa calado, e o leitor do outro idioma é quem descobre.
    const iguais: string[] = [];
    for (const p of ports) {
      if (p.pt.use === p.en.use) iguais.push(`${p.port}: "use" idêntico`);
      if (p.pt.stackNote === p.en.stackNote) iguais.push(`${p.port}: "stackNote" idêntico`);
      p.pt.attacks.forEach((a, i) => {
        if (a.how === p.en.attacks[i]?.how) iguais.push(`${p.port}: ataque[${i}] idêntico`);
      });
      p.pt.defenses.forEach((d, i) => {
        if (d.how === p.en.defenses[i]?.how) iguais.push(`${p.port}: defesa[${i}] idêntica`);
      });
    }
    expect(iguais).toEqual([]);
  });
});
