import { useMemo, useState } from "react";

/**
 * Simulador de cache de build.
 *
 * A regra "coloque o que muda menos primeiro" é fácil de recitar e difícil de
 * sentir. Aqui você reordena as instruções, marca o que mudou e vê quais
 * camadas realmente reconstroem — e quanto isso custa em segundos.
 *
 * O modelo é o do BuildKit, simplificado a duas regras que explicam quase tudo:
 *   1. uma camada invalida se alguma entrada dela mudou;
 *   2. invalidou uma, invalidam TODAS as seguintes (efeito cascata).
 */

type InputKey = "dockerfile" | "manifest" | "source";

interface Instruction {
  id: string;
  text: string;
  /** Segundos que a instrução leva quando executa de verdade. */
  cost: number;
  /** O que faz esta camada invalidar. Vazio = só invalida por cascata. */
  inputs: InputKey[];
}

const GOOD: Instruction[] = [
  { id: "from", text: "FROM node:22-alpine", cost: 0.4, inputs: ["dockerfile"] },
  { id: "workdir", text: "WORKDIR /app", cost: 0.1, inputs: ["dockerfile"] },
  { id: "copy-manifest", text: "COPY package.json package-lock.json ./", cost: 0.2, inputs: ["manifest"] },
  { id: "install", text: "RUN npm ci", cost: 42, inputs: [] },
  { id: "copy-src", text: "COPY . .", cost: 0.6, inputs: ["source"] },
  { id: "build", text: "RUN npm run build", cost: 11, inputs: [] },
];

/** A mesma imagem, com COPY . . antes do npm ci — o erro mais comum que existe. */
const BAD: Instruction[] = [
  { id: "from", text: "FROM node:22-alpine", cost: 0.4, inputs: ["dockerfile"] },
  { id: "workdir", text: "WORKDIR /app", cost: 0.1, inputs: ["dockerfile"] },
  { id: "copy-src", text: "COPY . .", cost: 0.6, inputs: ["source", "manifest"] },
  { id: "install", text: "RUN npm ci", cost: 42, inputs: [] },
  { id: "build", text: "RUN npm run build", cost: 11, inputs: [] },
];

const COPY = {
  pt: {
    changed: "O que você mudou desde o último build?",
    dockerfile: "o Dockerfile",
    manifest: "as dependências (package.json / lock)",
    source: "o código-fonte",
    order: "Ordem das instruções",
    up: "Subir",
    down: "Descer",
    cached: "CACHE",
    rebuilt: "REBUILD",
    total: "Tempo do rebuild",
    seconds: "s",
    presetGood: "Ordem boa",
    presetBad: "Ordem ruim",
    nothing: "Nada mudou: o build inteiro vem do cache.",
    hint: "Marque “o código-fonte” nas duas ordens e compare o total.",
    reason: {
      changed: "entrada alterada",
      cascade: "camada anterior invalidou",
      cache: "sem alteração",
    },
  },
  en: {
    changed: "What did you change since the last build?",
    dockerfile: "the Dockerfile",
    manifest: "the dependencies (package.json / lock)",
    source: "the source code",
    order: "Instruction order",
    up: "Move up",
    down: "Move down",
    cached: "CACHED",
    rebuilt: "REBUILD",
    total: "Rebuild time",
    seconds: "s",
    presetGood: "Good order",
    presetBad: "Bad order",
    nothing: "Nothing changed: the whole build comes from cache.",
    hint: "Tick “the source code” in both orders and compare the totals.",
    reason: {
      changed: "input changed",
      cascade: "a previous layer invalidated",
      cache: "unchanged",
    },
  },
} as const;

export default function BuildCacheSimulator({ lang = "pt" }: { lang?: "pt" | "en" }) {
  const t = COPY[lang];
  const [instructions, setInstructions] = useState<Instruction[]>(GOOD);
  const [changed, setChanged] = useState<Set<InputKey>>(new Set(["source"]));

  const result = useMemo(() => {
    let invalidated = false;
    const rows = instructions.map((instr) => {
      const ownChange = instr.inputs.some((i) => changed.has(i));
      // Cascata: uma vez invalidado, tudo abaixo reconstrói — mesmo que a
      // instrução em si não tenha nada a ver com o arquivo que você editou.
      const wasCascade = invalidated && !ownChange;
      const rebuild = ownChange || invalidated;
      if (rebuild) invalidated = true;
      return {
        ...instr,
        rebuild,
        reason: ownChange ? t.reason.changed : wasCascade ? t.reason.cascade : t.reason.cache,
      };
    });
    const total = rows.reduce((sum, r) => sum + (r.rebuild ? r.cost : 0), 0);
    return { rows, total };
  }, [instructions, changed, t]);

  const toggle = (key: InputKey) =>
    setChanged((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });

  const move = (index: number, delta: number) =>
    setInstructions((prev) => {
      const next = [...prev];
      const target = index + delta;
      if (target < 0 || target >= next.length) return prev;
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });

  const isGood = instructions.map((i) => i.id).join() === GOOD.map((i) => i.id).join();
  const isBad = instructions.map((i) => i.id).join() === BAD.map((i) => i.id).join();

  return (
    <div className="wx">
      <div className="wx__controls">
        <fieldset className="wx__fieldset">
          <legend>{t.changed}</legend>
          {(["dockerfile", "manifest", "source"] as InputKey[]).map((key) => (
            <label key={key} className="wx__check">
              <input type="checkbox" checked={changed.has(key)} onChange={() => toggle(key)} />
              <span>{t[key]}</span>
            </label>
          ))}
        </fieldset>

        <div className="wx__presets">
          <button
            type="button"
            className={`wx__preset ${isGood ? "is-active" : ""}`}
            onClick={() => setInstructions(GOOD)}
          >
            {t.presetGood}
          </button>
          <button
            type="button"
            className={`wx__preset ${isBad ? "is-active" : ""}`}
            onClick={() => setInstructions(BAD)}
          >
            {t.presetBad}
          </button>
        </div>
      </div>

      <ol className="wx__list" aria-label={t.order}>
        {result.rows.map((row, i) => (
          <li key={row.id} className={`wx__row ${row.rebuild ? "is-rebuild" : "is-cached"}`}>
            <span className={`wx__tag ${row.rebuild ? "is-rebuild" : "is-cached"}`}>
              {row.rebuild ? t.rebuilt : t.cached}
            </span>
            <code className="wx__code">{row.text}</code>
            <span className="wx__reason">{row.reason}</span>
            <span className="wx__cost">{row.rebuild ? `${row.cost}${t.seconds}` : "—"}</span>
            <span className="wx__move">
              <button type="button" onClick={() => move(i, -1)} disabled={i === 0} aria-label={`${t.up}: ${row.text}`}>↑</button>
              <button type="button" onClick={() => move(i, 1)} disabled={i === result.rows.length - 1} aria-label={`${t.down}: ${row.text}`}>↓</button>
            </span>
          </li>
        ))}
      </ol>

      <div className="wx__total">
        <span>{t.total}</span>
        <strong className={result.total > 20 ? "is-slow" : "is-fast"}>
          {result.total.toFixed(1)}{t.seconds}
        </strong>
      </div>
      <p className="wx__hint">{changed.size === 0 ? t.nothing : t.hint}</p>
    </div>
  );
}
