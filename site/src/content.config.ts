import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

/**
 * Coleção de lições.
 *
 * Cada lição existe duas vezes — src/content/lessons/pt/… e …/en/… — com o
 * MESMO campo `key`. É essa chave compartilhada que faz o seletor de idioma
 * funcionar: trocar de idioma é trocar um segmento da URL, mantendo a chave.
 * O script de verificação falha o build se uma chave existir em só um idioma.
 */
const lessons = defineCollection({
  loader: glob({ pattern: "**/*.mdx", base: "./src/content/lessons" }),
  schema: z.object({
    // Identificador estável e compartilhado entre os idiomas. Em inglês de
    // propósito: é uma chave técnica, não texto para o leitor.
    //
    // O campo se chama `key` e NÃO `slug`: `slug` é nome reservado pelo glob
    // loader do Astro, que o usa como id da entrada. Duas lições com o mesmo
    // `slug` (que é justamente o que a paridade PT/EN exige) colidiriam e uma
    // delas seria descartada silenciosamente da coleção.
    key: z.string(),
    lang: z.enum(["pt", "en"]),
    track: z.enum(["fundamentos", "producao", "seguranca", "kubernetes", "cicd"]),
    order: z.number().int().positive(),

    title: z.string(),
    summary: z.string(),
    // Quanto tempo de leitura, em minutos. Escrito à mão porque o cálculo
    // automático por contagem de palavras erra feio em texto com muito código.
    minutes: z.number().int().positive().default(10),

    tags: z.array(z.string()).default([]),
    // Fontes usadas para escrever a lição. Uma afirmação técnica sem origem
    // verificável não deveria estar aqui.
    //
    // `kind` separa as duas naturezas de fonte, e a página as agrupa por ele
    // (ADR 0009). Documentação e especificação dizem como uma coisa DEVE se
    // comportar; um postmortem, uma thread ou um blog de engenharia dizem o
    // que aconteceu com alguém — é conhecimento valioso e de outra natureza,
    // e misturar os dois numa lista só é o que faz uma opinião envelhecer
    // dentro de uma lição parecendo um fato.
    //
    // `accessed` existe porque relato envelhece: uma thread de 2019 sobre
    // custo de control plane fala de preços que já mudaram duas vezes.
    sources: z
      .array(
        z.object({
          label: z.string(),
          url: z.string().url(),
          kind: z
            .enum(["spec", "docs", "blog", "thread", "postmortem", "talk", "book"])
            .default("docs"),
          accessed: z.string().optional(),
        }),
      )
      .default([]),
  }),
});

export const collections = { lessons };
