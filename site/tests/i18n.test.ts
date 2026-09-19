import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { defaultLang, languages, repoFile, repoUrl, TRACKS, trackBadge, trackLabel, ui } from "../src/i18n/ui";

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
      "site.title", "track.cicd", "track.kubernetes",
    ]);
  });

  it("cobre TODA trilha com rótulo, descrição e cor", () => {
    // Itera TRACKS em vez de uma lista literal: acrescentar uma trilha e
    // esquecer de traduzi-la passava calado aqui, porque o teste só conhecia
    // as três que existiam quando ele foi escrito.
    for (const track of TRACKS) {
      expect(trackBadge(track), `${track}: sem classe de cor`).toMatch(/^badge--/);
      for (const lang of Object.keys(languages) as Array<keyof typeof ui>) {
        expect(trackLabel(lang, track).length, `${lang}/${track}: sem rótulo`).toBeGreaterThan(0);
        expect(
          ui[lang][`track.${track}.desc` as keyof typeof ui.pt].length,
          `${lang}/${track}: descrição curta demais`,
        ).toBeGreaterThan(20);
      }
    }
  });

  it("toda classe de badge existe no CSS", () => {
    // A trilha pode ter rótulo e descrição e mesmo assim sair sem cor: a
    // classe é escrita num arquivo e definida em outro, e nada os liga.
    const css = readFileSync(join(import.meta.dirname, "../src/styles/global.css"), "utf8");
    for (const track of TRACKS) {
      expect(css, `${track}: .${trackBadge(track)} não existe em global.css`)
        .toContain(`.${trackBadge(track)} {`);
    }
    expect(css, "--track-cicd sem valor no tema claro e nos dois escuros")
      .toMatch(/--track-cicd/);
  });

  it("aponta para o repositório certo", () => {
    expect(repoUrl).toMatch(/^https:\/\/github\.com\/[\w.-]+\/[\w.-]+$/);
    expect(repoFile("stack/compose.yaml")).toBe(`${repoUrl}/blob/main/stack/compose.yaml`);
  });

  it("tem um idioma padrão que existe", () => {
    expect(Object.keys(ui)).toContain(defaultLang);
  });
});
