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

export const ui = {
  pt: {
    "site.title": "infra-knowlogy",
    "site.tagline": "Infraestrutura explicada com o código que roda de verdade",
    "site.description":
      "Uma stack Docker de produção — endurecida, medida e verificada — e as lições que explicam cada decisão dela.",
    "nav.home": "Início",
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
