import { describe, expect, it } from "vitest";
import { runGate, STEP_IDS } from "../src/lib/gate";
import { recorded, recordedFetch } from "../src/lib/recorded";

/**
 * O modo demonstração não pode mentir.
 *
 * Um "modo demo" escrito à parte envelhece calado: alguém muda o portão, e a
 * demonstração continua mostrando a versão antiga como se fosse verdade. Aqui
 * o mesmo `runGate` roda sobre o transporte gravado, então qualquer divergência
 * entre o que o portão checa e o que o arquivo gravou reprova este teste.
 */
describe("modo demonstração", () => {
  it("reencena um portão inteiro verde a partir do arquivo gravado", async () => {
    const result = await runGate("", {
      fetch: recordedFetch(),
      sleep: async () => {},
      now: () => 0,
      onStep: () => {},
    }, { attempts: 5, interval: 0 });

    const failures = result.steps.filter((s) => s.status === "fail");
    expect(failures.map((s) => `${s.id}: ${s.messageKey}`)).toEqual([]);
    expect(result.pass).toBe(STEP_IDS.length);
  });

  it("reproduz o “ainda não” do worker antes de reproduzir o título", async () => {
    // O enriquecimento é assíncrono na aplicação de verdade. Se a gravação
    // devolvesse o título já na primeira leitura, a demonstração ensinaria
    // errado justamente a parte que a lição quer mostrar.
    const f = recordedFetch();
    const first = await (await f(`/api/links/${recorded.steps.create.code}`)).json();
    const second = await (await f(`/api/links/${recorded.steps.create.code}`)).json();
    expect(recorded.steps.enrich.tries).toBeGreaterThan(1);
    expect(first.title).toBeNull();
    expect(second.title).toBe(recorded.steps.enrich.title);
  });

  it("recusa o endereço interno com o motivo que o worker deu de verdade", async () => {
    const f = recordedFetch();
    const created = await (await f("/api/links", {
      method: "POST",
      body: JSON.stringify({ url: "http://169.254.169.254/latest/meta-data/" }),
    })).json();
    const looked = await (await f(`/api/links/${created.code}`)).json();
    expect(looked.enrich_error).toMatch(/bloqueado|blocked/i);
    expect(looked.title).toBeNull();
  });

  it("o arquivo gravado diz quando e contra o quê foi gravado", () => {
    // Sem data e origem, uma gravação vira número de blog — exatamente o que
    // este repositório não aceita.
    expect(recorded.recordedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(recorded.baseUrl).toMatch(/^https?:\/\//);
    expect(Object.keys(recorded.steps).sort()).toEqual([...STEP_IDS].sort());
  });
});
