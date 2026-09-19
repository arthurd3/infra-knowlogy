import { describe, expect, it } from "vitest";
import { defaultLang, languages, repoFile, repoUrl, trackLabel, ui } from "../src/i18n/ui";

/**
 * A moldura do site é bilíngue tanto quanto as lições.
 *
 * Uma chave que existe só em português não quebra o build: o `t()` cai no
 * idioma padrão e a página inglesa ganha uma frase em português, calada. Este
 * teste é o que torna esse descuido barulhento.
 */
describe("dicionário de interface", () => {
  it("tem exatamente as mesmas chaves nos dois idiomas", () => {
    const pt = Object.keys(ui.pt).sort();
    const en = Object.keys(ui.en).sort();
    expect(en.filter((k) => !pt.includes(k))).toEqual([]);
    expect(pt.filter((k) => !en.includes(k))).toEqual([]);
  });

  it("não tem tradução vazia", () => {
    for (const [lang, dict] of Object.entries(ui)) {
      for (const [key, value] of Object.entries(dict)) {
        expect(value.trim(), `${lang}.${key} está vazia`).not.toBe("");
      }
    }
  });

  it("traduz de verdade em vez de repetir o português", () => {
    // Nomes próprios e termos técnicos podem coincidir; o resto, não.
    const mesmos = Object.keys(ui.pt).filter(
      (k) => ui.pt[k as keyof typeof ui.pt] === ui.en[k as keyof typeof ui.en],
    );
    expect(mesmos.sort()).toEqual([
      "site.title", "track.kubernetes",
    ]);
  });

  it("cobre as três trilhas com rótulo e descrição", () => {
    for (const track of ["fundamentos", "producao", "kubernetes"] as const) {
      for (const lang of Object.keys(languages) as Array<keyof typeof ui>) {
        expect(trackLabel(lang, track).length).toBeGreaterThan(0);
        expect(ui[lang][`track.${track}.desc` as keyof typeof ui.pt].length).toBeGreaterThan(20);
      }
    }
  });

  it("aponta para o repositório certo", () => {
    expect(repoUrl).toMatch(/^https:\/\/github\.com\/[\w.-]+\/[\w.-]+$/);
    expect(repoFile("stack/compose.yaml")).toBe(`${repoUrl}/blob/main/stack/compose.yaml`);
  });

  it("tem um idioma padrão que existe", () => {
    expect(Object.keys(ui)).toContain(defaultLang);
  });
});
