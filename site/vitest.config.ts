import { defineConfig } from "vitest/config";

/**
 * Testes do site.
 *
 * O que estes testes cobrem é a LÓGICA — o portão que roda no navegador, o
 * fluxo do encurtador, a paridade entre os idiomas. Nada aqui sobe navegador
 * nem Docker: `src/lib/` foi escrito recebendo o `fetch` por parâmetro
 * justamente para caber num teste de milissegundos.
 *
 * O que eles NÃO cobrem, e é honesto dizer: a stack de verdade. Quem prova
 * isso é o `make verify` (e, do navegador, o próprio widget GateRunner).
 */
export default defineConfig({
  test: {
    environment: "node",
    include: ["tests/**/*.test.ts"],
    // O build do Astro é lento e não é assunto dos testes unitários.
    exclude: ["dist/**", "node_modules/**"],
  },
});
