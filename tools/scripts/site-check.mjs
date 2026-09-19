#!/usr/bin/env node
/**
 * Checagem do HTML que o site realmente gera.
 *
 * Os testes unitários (`site/tests/`) provam a lógica; o `astro check` prova os
 * tipos. Nenhum dos dois olha o produto final — e é no produto final que mora
 * a classe de defeito mais chata do site estático: o link interno que aponta
 * para uma página que não existe. Ele não quebra build nenhum. Só quebra para
 * o leitor.
 *
 * Sem dependências de propósito: roda com o Node que já está ali para o Astro.
 *
 *   node tools/scripts/site-check.mjs [caminho-do-dist]
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve, posix } from "node:path";

const DIST = resolve(process.argv[2] ?? "site/dist");

let pass = 0;
const failures = [];
const ok = (msg) => { pass += 1; console.log(`   \x1b[32m✓\x1b[0m ${msg}`); };
const bad = (msg, detail = []) => {
  failures.push(msg);
  console.log(`   \x1b[31m✗\x1b[0m ${msg}`);
  for (const d of detail.slice(0, 8)) console.log(`       ${d}`);
  if (detail.length > 8) console.log(`       … e mais ${detail.length - 8}`);
};

/** Todo arquivo sob `dir`, recursivo. */
function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

let files;
try {
  files = walk(DIST);
} catch {
  console.error(`dist não encontrado em ${DIST} — rode o build antes.`);
  process.exit(2);
}

const pages = files.filter((f) => f.endsWith(".html"));
const urls = new Set();
for (const f of files) {
  const rel = `/${relative(DIST, f).split(/[/\\]/).join("/")}`;
  urls.add(rel);
  // build.format "directory" gera /a/b/index.html, servido como /a/b/
  if (rel.endsWith("/index.html")) {
    urls.add(rel.slice(0, -"index.html".length));
    urls.add(rel.slice(0, -"/index.html".length));
  }
}

const read = (f) => readFileSync(f, "utf8");
const page = (f) => `/${relative(DIST, f).split(/[/\\]/).join("/")}`;

console.log(`\n\x1b[1m── HTML gerado (${pages.length} páginas em ${relative(process.cwd(), DIST)})\x1b[0m`);

// ─── 1. Links internos ───────────────────────────────────────────────────────
{
  const broken = [];
  for (const f of pages) {
    const html = read(f);
    const here = page(f);
    const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
    for (const m of html.matchAll(/\shref="([^"]+)"/g)) {
      const href = m[1];
      if (/^(https?:|mailto:|tel:|data:|#|\/\/)/.test(href)) {
        // Âncora na própria página: o id precisa existir.
        if (href.startsWith("#") && href !== "#" && !ids.has(decodeURIComponent(href.slice(1)))) {
          broken.push(`${here} -> ${href} (âncora inexistente)`);
        }
        continue;
      }
      if (!href.startsWith("/")) continue; // relativo: o site não usa
      const [path, hash] = href.split("#");
      if (!urls.has(path) && !urls.has(`${path}index.html`) && !urls.has(path.replace(/\/$/, ""))) {
        broken.push(`${here} -> ${href}`);
        continue;
      }
      if (hash) {
        const target = urls.has(`${path}index.html`) ? join(DIST, path, "index.html") : join(DIST, path);
        try {
          const targetIds = new Set([...read(target).matchAll(/\sid="([^"]+)"/g)].map((x) => x[1]));
          if (!targetIds.has(decodeURIComponent(hash))) broken.push(`${here} -> ${href} (âncora inexistente)`);
        } catch { /* já reportado acima */ }
      }
    }
  }
  if (broken.length === 0) ok("todo link interno resolve (incluindo as âncoras)");
  else bad(`${broken.length} link(s) interno(s) quebrado(s)`, broken);
}

// ─── 2. Cabeça de cada página ────────────────────────────────────────────────
{
  const required = [
    ["<title>", /<title>[^<]+<\/title>/],
    ["canonical", /rel="canonical"/],
    ["hreflang pt e en", /hreflang="pt-BR"[\s\S]*hreflang="en"|hreflang="en"[\s\S]*hreflang="pt-BR"/],
    ["og:title", /property="og:title"/],
    ["viewport", /name="viewport"/],
  ];
  const problems = [];
  // A raiz é um redirect deliberado, sem moldura; ela tem regra própria abaixo.
  for (const f of pages.filter((p) => page(p) !== "/index.html")) {
    const html = read(f);
    for (const [name, re] of required) if (!re.test(html)) problems.push(`${page(f)}: sem ${name}`);
  }
  if (problems.length === 0) ok("toda página tem título, canonical, hreflang e og:title");
  else bad("páginas com a cabeça incompleta", problems);
}

// ─── 3. Acessibilidade da moldura ────────────────────────────────────────────
{
  const problems = [];
  for (const f of pages.filter((p) => page(p) !== "/index.html")) {
    const html = read(f);
    // O skip-link precisa existir E ter a classe que o revela no foco; como
    // .visually-hidden ele era invisível também para quem navega por Tab.
    if (!/class="skip-link"/.test(html)) problems.push(`${page(f)}: sem skip-link`);
    if (!/id="main"/.test(html)) problems.push(`${page(f)}: sem <main id="main">`);
    if (!/aria-label="[^"]+"[^>]*id="theme-toggle"|id="theme-toggle"[^>]*aria-label="[^"]+"/.test(html)) {
      problems.push(`${page(f)}: toggle de tema sem aria-label`);
    }
    if (/<html(?![^>]*\slang=)/.test(html)) problems.push(`${page(f)}: <html> sem lang`);
  }
  if (problems.length === 0) ok("skip-link, main, lang e rótulo do toggle presentes");
  else bad("problemas de acessibilidade na moldura", problems);
}

// ─── 4. Simetria entre os idiomas ────────────────────────────────────────────
{
  const pt = pages.filter((p) => page(p).startsWith("/pt/")).map((p) => page(p).replace("/pt/", ""));
  const en = pages.filter((p) => page(p).startsWith("/en/")).map((p) => page(p).replace("/en/", ""));
  const soloPt = pt.filter((p) => !en.includes(p));
  const soloEn = en.filter((p) => !pt.includes(p));
  if (soloPt.length === 0 && soloEn.length === 0 && pt.length > 0) {
    ok(`${pt.length} páginas em cada idioma, com os mesmos caminhos`);
  } else {
    bad("as duas árvores de idioma divergem", [...soloPt.map((p) => `só pt: ${p}`), ...soloEn.map((p) => `só en: ${p}`)]);
  }
}

// ─── 5. Conteúdo visual das lições ───────────────────────────────────────────
{
  const lessons = pages.filter((p) => /\/(pt|en)\/lessons\//.test(page(p)));
  const semVisual = lessons
    .filter((f) => { const h = read(f); return !/class="figure/.test(h) && !/<astro-island/.test(h); })
    .map((f) => page(f));
  if (lessons.length === 0) bad("nenhuma página de lição foi gerada");
  else if (semVisual.length === 0) ok(`as ${lessons.length} lições saem com diagrama ou widget`);
  else bad("lições que saíram só com texto", semVisual);
}

// ─── 6. Diagramas que herdam o tema ──────────────────────────────────────────
{
  // Um SVG com cor fixa fica ilegível em um dos dois temas. O acordo é que
  // todo diagrama pinta por classe (.dg-*) ou por var(--…), nunca por hex.
  const offenders = [];
  for (const f of pages) {
    for (const svg of read(f).matchAll(/<svg[\s\S]*?<\/svg>/g)) {
      const hexes = [...svg[0].matchAll(/(?:fill|stroke)="(#[0-9a-fA-F]{3,8})"/g)].map((m) => m[1]);
      if (hexes.length) offenders.push(`${page(f)}: ${[...new Set(hexes)].join(", ")}`);
    }
  }
  if (offenders.length === 0) ok("nenhum SVG com cor fixa: todos herdam o tema");
  else bad("SVG com cor fixa (ilegível em um dos temas)", [...new Set(offenders)]);
}

// ─── 7. Nada de sobra do desenvolvimento ─────────────────────────────────────
{
  const leaks = [];
  for (const f of pages) {
    const html = read(f);
    for (const needle of ["__dbg", "DIAGNÓSTICO", "console.debug(", "TODO:", "FIXME"]) {
      if (html.includes(needle)) leaks.push(`${page(f)}: ${needle}`);
    }
    if (/localhost:4321/.test(html)) leaks.push(`${page(f)}: endereço do servidor de desenvolvimento`);
  }
  if (leaks.length === 0) ok("nenhum resto de depuração no HTML publicado");
  else bad("sobras de desenvolvimento no HTML", leaks);
}

// ─── 8. A raiz redireciona ───────────────────────────────────────────────────
{
  const root = pages.find((p) => page(p) === "/index.html");
  const html = root ? read(root) : "";
  if (root && /http-equiv="refresh"/.test(html) && /\/pt\//.test(html)) ok("a raiz / redireciona para /pt/");
  else bad("a raiz não redireciona para um idioma");
}

// ─── 9. Toda lição pergunta alguma coisa ao leitor ───────────────────────────
{
  // A contraparte, no produto final, do teste de cobertura de exercício. O
  // teste unitário olha a tag no MDX; aqui a pergunta é se ela sobreviveu à
  // renderização — uma ilha que falha em hidratar ainda deixa o HTML servidor,
  // e é esse HTML que prova que o widget chegou na página.
  const lessons = pages.filter((p) => /\/(pt|en)\/lessons\//.test(page(p)));
  const semExercicio = lessons
    .filter((f) => { const h = read(f); return !/class="qz/.test(h) && !/class="lab/.test(h); })
    .map((f) => page(f));
  if (semExercicio.length === 0) ok(`as ${lessons.length} lições saem com quiz ou exercício`);
  else bad("lições sem nenhum exercício no HTML gerado", semExercicio);
}

// ─── 10. Imagem de terceiro sai com procedência ──────────────────────────────
{
  // Um SVG daqui pinta por classe e segue o tema; uma imagem de fora não faz
  // nem uma coisa nem outra, e por isso ela paga um pedágio: alt de verdade,
  // crédito visível e um arquivo que existe no dist. Sem isso, o leitor recebe
  // uma figura de origem desconhecida — e este repositório não publica isso.
  const problemas = [];
  for (const f of pages) {
    const html = read(f);
    for (const fig of html.matchAll(/<figure class="figure[\s\S]*?<\/figure>/g)) {
      const bloco = fig[0];
      const img = bloco.match(/<img\b[^>]*>/);
      if (!img) continue;                       // figura de SVG: não se aplica
      const alt = img[0].match(/\salt="([^"]*)"/);
      if (!alt || !alt[1].trim()) problemas.push(`${page(f)}: <img> sem alt`);
      if (!/class="figure__credit"/.test(bloco)) problemas.push(`${page(f)}: <img> sem crédito`);
      const src = img[0].match(/\ssrc="([^"]+)"/)?.[1] ?? "";
      if (src.startsWith("/") && !urls.has(src)) problemas.push(`${page(f)}: src inexistente ${src}`);
      if (/^https?:/.test(src)) problemas.push(`${page(f)}: imagem carregada de fora (${src})`);
    }
  }
  const comImagem = pages.filter((f) => /<figure class="figure[\s\S]*?<img/.test(read(f))).length;
  if (problemas.length === 0) ok(`imagens com procedência (${comImagem} página(s) com figura raster)`);
  else bad("imagem sem procedência ou quebrada", [...new Set(problemas)]);
}

console.log(`\n   \x1b[32m${pass} passaram\x1b[0m · \x1b[31m${failures.length} falharam\x1b[0m`);
process.exit(failures.length > 0 ? 1 : 0);
