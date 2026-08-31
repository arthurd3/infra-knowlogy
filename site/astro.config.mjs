// @ts-check
import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import react from "@astrojs/react";

// O site é 100% ESTÁTICO. Nenhum widget precisa de servidor: os simuladores
// rodam inteiramente no navegador, com dados medidos gravados em build time.
// Isso significa que ele pode ser publicado em qualquer lugar — e que o
// container que o serve é só um servidor de arquivos, sem runtime nenhum.
export default defineConfig({
  site: "https://infra-knowlogy.local",
  output: "static",

  i18n: {
    defaultLocale: "pt",
    locales: ["pt", "en"],
    routing: {
      // Prefixa TAMBÉM o idioma padrão: /pt/... e /en/..., nunca /... solto.
      // Com URLs simétricas, o seletor de idioma é uma troca de segmento e
      // pronto — sem casos especiais para o idioma padrão.
      prefixDefaultLocale: true,
      // Desligado porque src/pages/index.astro já faz esse trabalho de forma
      // explícita e visível. Deixar ligado cria uma segunda rota para `/`, e o
      // Astro avisa sobre o conflito a cada build.
      redirectToDefaultLocale: false,
    },
  },

  integrations: [
    mdx(),
    // Os componentes React são ILHAS: só hidratam os que têm client:*.
    // O texto das lições continua sendo HTML estático, sem JavaScript.
    react(),
  ],

  markdown: {
    shikiConfig: {
      themes: { light: "github-light", dark: "github-dark" },
      wrap: false,
    },
  },

  build: {
    // Gera /pt/lessons/foo.html em vez de /pt/lessons/foo/index.html: um
    // servidor de arquivos estáticos simples serve isso sem configuração extra.
    format: "directory",
  },
});
