/**
 * Strings da moldura do site (nav, rótulos, rodapé).
 *
 * O CONTEÚDO das lições não passa por aqui — ele vive em arquivos MDX
 * separados por idioma. Um dicionário de chaves serve para "Próxima lição";
 * não serve para três parágrafos explicando cgroups.
 */
export const languages = { pt: "Português", en: "English" } as const;
export type Lang = keyof typeof languages;

export const defaultLang: Lang = "pt";

/** Endereço do repositório. Usado pela nav e pelos links "ver o código". */
export const repoUrl = "https://github.com/arthurd3/infra-knowlogy";

/** Link direto para um arquivo do repositório, no branch principal. */
export function repoFile(path: string): string {
  return `${repoUrl}/blob/main/${path}`;
}

export const ui = {
  pt: {
    "site.title": "infra-knowlogy",
    "site.tagline": "Infraestrutura explicada com o código que roda de verdade",
    "site.description":
      "Uma stack Docker de produção — endurecida, medida e verificada — e as lições que explicam cada decisão dela.",
    "nav.home": "Início",
    "nav.repo": "Ver no GitHub",
    "nav.theme": "Alternar tema claro/escuro",
    "a11y.skip": "Pular para o conteúdo",
    "action.copy": "Copiar",
    "action.copied": "Copiado",
    "action.copyCode": "Copiar o bloco de código",
    "lesson.runItWhere": "no seu terminal, na raiz do repositório",
    "lesson.tags": "Assuntos",
    "lesson.backToTracks": "Todas as lições",
    "pager.otherTrack": "Começa a trilha",
    "home.verify.title": "Verifique você mesmo, daqui",
    "home.verify.desc":
      "As mesmas checagens que o make verify roda no terminal, disparadas pelo navegador contra a stack em execução. Sem a stack no ar, cada passo mostra a resposta gravada do último portão que passou.",
    "home.stats.images": "imagens medidas",
    "home.stats.checks": "checagens no portão",
    "home.stats.services": "serviços na stack",
    "home.stats.langs": "linguagens",
    "home.soon": "Trilha planejada: o código que ela explica já está no repositório, as lições é que faltam.",
    "nav.tracks": "Trilhas",
    "nav.stack": "A stack",
    "track.fundamentos": "Fundamentos",
    "track.producao": "Produção",
    "track.kubernetes": "Kubernetes",
    "track.fundamentos.desc":
      "O que um container realmente é, como uma imagem é montada e por que o cache de build se comporta assim.",
    "track.producao.desc":
      "O que muda quando a stack precisa sobreviver a usuários reais: multi-stage, segurança, segredos e cadeia de suprimentos.",
    "track.kubernetes.desc":
      "A mesma stack, portada para um cluster kind: o que um orquestrador acrescenta — auto-cura, probes, rolling — medido lado a lado com o Compose.",
    "lesson.minutes": "min de leitura",
    "lesson.sources": "Fontes",
    "lesson.next": "Próxima",
    "lesson.prev": "Anterior",
    "lesson.onThisPage": "Nesta página",
    "lesson.runIt": "Rode você mesmo",
    "callout.why": "Por quê",
    "callout.trap": "Pegadinha",
    "callout.danger": "Perigo",
    "lesson.lesson": "Lição",
    "lang.switch": "Ver em inglês",
    "footer.built":
      "Este site é servido pelo mesmo Dockerfile multi-stage que ele explica.",
    "home.start": "Começar pelo início",
    "home.lessons": "lições",
    "home.intro":
      "Todo exemplo aqui sai de uma stack que roda: seis serviços, três linguagens, endurecida segundo o OWASP e verificada por um script que falha se algo regredir. Os números de tamanho de imagem são medidos, não copiados de blog.",
  },
  en: {
    "site.title": "infra-knowlogy",
    "site.tagline": "Infrastructure explained through code that actually runs",
    "site.description":
      "A production Docker stack — hardened, measured and verified — and the lessons that explain every decision in it.",
    "nav.home": "Home",
    "nav.repo": "View on GitHub",
    "nav.theme": "Toggle light/dark theme",
    "a11y.skip": "Skip to content",
    "action.copy": "Copy",
    "action.copied": "Copied",
    "action.copyCode": "Copy the code block",
    "lesson.runItWhere": "in your terminal, at the repository root",
    "lesson.tags": "Topics",
    "lesson.backToTracks": "All lessons",
    "pager.otherTrack": "Starts the track",
    "home.verify.title": "Check it yourself, from here",
    "home.verify.desc":
      "The same checks make verify runs in the terminal, fired from the browser against the running stack. With no stack up, every step shows the recorded response from the last gate that passed.",
    "home.stats.images": "images measured",
    "home.stats.checks": "checks in the gate",
    "home.stats.services": "services in the stack",
    "home.stats.langs": "languages",
    "home.soon": "Planned track: the code it explains is already in the repository — the lessons are what is missing.",
    "nav.tracks": "Tracks",
    "nav.stack": "The stack",
    "track.fundamentos": "Fundamentals",
    "track.producao": "Production",
    "track.kubernetes": "Kubernetes",
    "track.fundamentos.desc":
      "What a container actually is, how an image is assembled, and why the build cache behaves the way it does.",
    "track.producao.desc":
      "What changes when the stack has to survive real users: multi-stage, security, secrets and supply chain.",
    "track.kubernetes.desc":
      "The same stack, ported to a kind cluster: what an orchestrator adds — self-healing, probes, rolling updates — measured side by side with Compose.",
    "lesson.minutes": "min read",
    "lesson.sources": "Sources",
    "lesson.next": "Next",
    "lesson.prev": "Previous",
    "lesson.onThisPage": "On this page",
    "lesson.runIt": "Run it yourself",
    "callout.why": "Why",
    "callout.trap": "Gotcha",
    "callout.danger": "Danger",
    "lesson.lesson": "Lesson",
    "lang.switch": "Ver em português",
    "footer.built":
      "This site is served by the very multi-stage Dockerfile it explains.",
    "home.start": "Start from the beginning",
    "home.lessons": "lessons",
    "home.intro":
      "Every example here comes from a stack that runs: six services, three languages, hardened against the OWASP rules and checked by a script that fails when something regresses. The image sizes are measured, not copied from a blog post.",
  },
} as const;

export type UIKey = keyof (typeof ui)["pt"];

export function useTranslations(lang: Lang) {
  return function t(key: UIKey): string {
    return ui[lang][key] ?? ui[defaultLang][key];
  };
}

export function otherLang(lang: Lang): Lang {
  return lang === "pt" ? "en" : "pt";
}

/** Rótulo localizado de uma trilha. */
export function trackLabel(
  lang: Lang,
  track: "fundamentos" | "producao" | "kubernetes",
): string {
  return ui[lang][`track.${track}` as UIKey];
}
