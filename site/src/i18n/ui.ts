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
    "home.market.title": "O que o mercado pede, e o que aqui é provado",
    "home.market.desc":
      "As sete exigências que apareceram em 40 vagas de SRE, DevOps e Tech Lead, cruzadas com o que este repositório verifica por comando. Clique numa barra para ver a evidência — ou a lacuna, escrita com todas as letras.",
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
    "track.seguranca": "Segurança",
    "track.kubernetes": "Kubernetes",
    "track.cicd": "CI/CD",
    "track.iac": "IaC",
    "track.fundamentos.desc":
      "O que um container realmente é, como uma imagem é montada e por que o cache de build se comporta assim.",
    "track.producao.desc":
      "O que muda quando a stack precisa sobreviver a usuários reais: multi-stage, segurança, segredos e cadeia de suprimentos.",
    "track.seguranca.desc":
      "As portas que o mundo inteiro varre, como se ataca um banco de dados e o que de fato para cada ataque — com os ataques rodando contra esta stack, de mentira nenhuma.",
    "track.kubernetes.desc":
      "A mesma stack, portada para um cluster kind: o que um orquestrador acrescenta — auto-cura, probes, rolling — medido lado a lado com o Compose.",
    "track.cicd.desc":
      "O mesmo pipeline em dois mundos: o GitHub Actions que já existe e um Jenkins self-hosted construído do zero — comparados por medição, não por preferência.",
    "track.iac.desc":
      "A mesma stack declarada em HCL e provisionada por OpenTofu: estado, grafo de dependências, idempotência e drift — medidos aqui, sem conta em nuvem nenhuma.",
    "lesson.minutes": "min de leitura",
    "lesson.sources": "Fontes",
    "deeper.title": "Para ir mais fundo",
    "deeper.lead":
      "Não são as fontes desta lição — são o caminho para além dela, por conceito. Cada indicação diz por que ELA, e se custa dinheiro.",
    "deeper.free": "gratuito",
    "deeper.paid": "pago",
    "lesson.sources.docs": "Documentação e especificação",
    "lesson.sources.field": "Relatos de campo",
    "lesson.next": "Próxima",
    "lesson.prev": "Anterior",
    "lesson.onThisPage": "Nesta página",
    "lesson.runIt": "Rode você mesmo",
    "callout.why": "Por quê",
    "callout.trap": "Pegadinha",
    "callout.danger": "Perigo",

    // ── Tradeoff: a decisão com critério de quando aplicar ──────────────────
    "tradeoff.title": "A escolha",
    "tradeoff.when": "Quando vale a pena",
    "tradeoff.chose": "O que este repositório escolheu",
    "tradeoff.seeAdr": "Ver a decisão registrada",

    // ── FieldNote: o que foi CITADO, e não medido nesta máquina ─────────────
    "field.postmortem": "Relato de incidente",
    "field.thread": "Discussão pública",
    "field.blog": "Blog de engenharia",
    "field.talk": "Palestra",
    "field.scale": "Como se faz em escala",
    "field.spec": "Especificação",
    "field.notMeasured": "Não medido aqui",
    "field.reportedBy": "relatado por",

    // ── LabExercise: a pergunta cuja resposta é um comando ──────────────────
    "lab.title": "Exercício",
    "lab.hint": "Uma dica",
    "lab.answer": "Ver a resposta",
    "lab.provenBy": "O portão prova isto na checagem",

    // ── Term: o conceito aberto ali mesmo, para quem não é da área ─────────
    "term.label": "Conceito",

    // ── Quiz ────────────────────────────────────────────────────────────────
    "quiz.title": "Checagem rápida",
    "quiz.question": "Pergunta",
    "quiz.check": "Conferir",
    "quiz.retry": "Tentar de novo",
    "quiz.next": "Próxima pergunta",
    "quiz.restart": "Recomeçar",
    "quiz.correct": "Isso mesmo",
    "quiz.wrong": "Ainda não",
    "quiz.done": "Fim da checagem",
    "quiz.score": "acertos de",

    // ── Figura com imagem de terceiro ───────────────────────────────────────
    "figure.source": "Fonte",
    "figure.license": "Licença",
    "figure.redrawn": "Redesenhado a partir de",
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
    "home.market.title": "What the market asks for, and what is proven here",
    "home.market.desc":
      "The seven requirements that showed up across 40 SRE, DevOps and Tech Lead job posts, crossed with what this repository verifies by command. Click a bar to see the evidence — or the gap, spelled out.",
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
    "track.seguranca": "Security",
    "track.kubernetes": "Kubernetes",
    "track.cicd": "CI/CD",
    "track.iac": "IaC",
    "track.fundamentos.desc":
      "What a container actually is, how an image is assembled, and why the build cache behaves the way it does.",
    "track.producao.desc":
      "What changes when the stack has to survive real users: multi-stage, security, secrets and supply chain.",
    "track.seguranca.desc":
      "The ports the whole internet scans, how a database is actually attacked, and what really stops each attack — with the attacks fired at this very stack, nothing simulated.",
    "track.kubernetes.desc":
      "The same stack, ported to a kind cluster: what an orchestrator adds — self-healing, probes, rolling updates — measured side by side with Compose.",
    "track.cicd.desc":
      "The same pipeline in two worlds: the GitHub Actions one that already exists, and a self-hosted Jenkins built from scratch — compared by measurement, not by preference.",
    "track.iac.desc":
      "The same stack declared in HCL and provisioned by OpenTofu: state, dependency graph, idempotence and drift — all measured here, with no cloud account at all.",
    "lesson.minutes": "min read",
    "lesson.sources": "Sources",
    "deeper.title": "Going deeper",
    "deeper.lead":
      "These are not this lesson's sources — they are the path beyond it, by concept. Every entry says why THAT one, and whether it costs money.",
    "deeper.free": "free",
    "deeper.paid": "paid",
    "lesson.sources.docs": "Documentation and specification",
    "lesson.sources.field": "Field reports",
    "lesson.next": "Next",
    "lesson.prev": "Previous",
    "lesson.onThisPage": "On this page",
    "lesson.runIt": "Run it yourself",
    "callout.why": "Why",
    "callout.trap": "Gotcha",
    "callout.danger": "Danger",

    // ── Tradeoff: the decision, with a rule for when to apply it ───────────
    "tradeoff.title": "The trade-off",
    "tradeoff.when": "When it pays off",
    "tradeoff.chose": "What this repository chose",
    "tradeoff.seeAdr": "See the recorded decision",

    // ── FieldNote: what was CITED, not measured on this machine ────────────
    "field.postmortem": "Incident report",
    "field.thread": "Public thread",
    "field.blog": "Engineering blog",
    "field.talk": "Conference talk",
    "field.scale": "How it is done at scale",
    "field.spec": "Specification",
    "field.notMeasured": "Not measured here",
    "field.reportedBy": "reported by",

    // ── LabExercise: the question whose answer is a command ────────────────
    "lab.title": "Exercise",
    "lab.hint": "A hint",
    "lab.answer": "Show the answer",
    "lab.provenBy": "The gate proves this in check",

    // ── Term: the concept unpacked right there, for the non-specialist ─────
    "term.label": "Concept",

    // ── Quiz ───────────────────────────────────────────────────────────────
    "quiz.title": "Quick check",
    "quiz.question": "Question",
    "quiz.check": "Check answer",
    "quiz.retry": "Try again",
    "quiz.next": "Next question",
    "quiz.restart": "Start over",
    "quiz.correct": "That is it",
    "quiz.wrong": "Not quite",
    "quiz.done": "Check complete",
    "quiz.score": "right out of",

    // ── Figure carrying a third-party image ────────────────────────────────
    "figure.source": "Source",
    "figure.license": "License",
    "figure.redrawn": "Redrawn from",
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

/**
 * Toda trilha do site, na ordem em que a jornada acontece.
 *
 * Fonte única desta união: o enum de `content.config.ts`, o array da home, o
 * mapa de badge da página da lição e os testes todos derivam daqui. Antes,
 * cada um repetia a lista à mão e acrescentar uma trilha era caçar literais.
 */
export const TRACKS = ["fundamentos", "producao", "seguranca", "kubernetes", "cicd", "iac"] as const;
export type Track = (typeof TRACKS)[number];

/** Rótulo localizado de uma trilha. */
export function trackLabel(lang: Lang, track: Track): string {
  return ui[lang][`track.${track}` as UIKey];
}

/**
 * Classe de cor da trilha. Mora aqui, junto do rótulo, porque os dois eram
 * literais repetidos na home e na página da lição — e acrescentar uma trilha
 * significava lembrar dos dois lugares.
 */
export function trackBadge(track: Track): string {
  return {
    fundamentos: "badge--fund",
    producao: "badge--prod",
    seguranca: "badge--seg",
    kubernetes: "badge--k8s",
    cicd: "badge--cicd",
    iac: "badge--iac",
  }[track];
}
