import { useState } from "react";

/**
 * O tabuleiro do quiz. Só apresentação e estado — as perguntas chegam prontas
 * de Quiz.astro, que as resolve em tempo de build.
 *
 * A regra que define este widget: ao conferir, ele explica TODAS as
 * alternativas, não só a certa. Saber por que a errada está errada é onde o
 * entendimento acontece; um widget que só pinta de verde a resposta certa
 * ensina a reconhecer o gabarito, não o assunto.
 *
 * Ele não guarda progresso em lugar nenhum. O site é estático e sem conta de
 * usuário; um placar persistido seria uma promessa que ele não pode cumprir.
 */

export interface Option { text: string; correct?: boolean; why: string }
export interface Question { q: string; options: Option[] }

/**
 * Markdown inline mínimo: `código` e **forte**.
 *
 * O texto das perguntas vive em JSON, que não passa pelo MDX e portanto não
 * ganha formatação de graça. Sem isto, uma pergunta sobre `docker stop` sai com
 * as crases na cara do leitor. Um parser de markdown inteiro seria uma
 * dependência nova para resolver dois casos.
 *
 * O escape vem ANTES da conversão: o conteúdo é nosso, mas `dangerouslySet`
 * merece o cuidado de sempre — e uma pergunta sobre `<script>` ou sobre
 * `docker run -p 80:80` não pode virar markup por acidente.
 */
export function inline(text: string): string {
  return text
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
}

const COPY = {
  pt: {
    title: "Checagem rápida",
    question: "Pergunta",
    check: "Conferir",
    retry: "Tentar de novo",
    next: "Próxima pergunta",
    restart: "Recomeçar",
    correct: "Isso mesmo",
    wrong: "Ainda não",
    done: "Fim da checagem",
    score: "acertos de",
    empty: "Este conjunto de perguntas está vazio.",
  },
  en: {
    title: "Quick check",
    question: "Question",
    check: "Check answer",
    retry: "Try again",
    next: "Next question",
    restart: "Start over",
    correct: "That is it",
    wrong: "Not quite",
    done: "Check complete",
    score: "right out of",
    empty: "This question set is empty.",
  },
} as const;

export default function QuizBoard({
  lang = "pt",
  questions = [],
}: {
  lang?: "pt" | "en";
  questions?: Question[];
}) {
  const t = COPY[lang];
  const [idx, setIdx] = useState(0);
  const [picked, setPicked] = useState<number | null>(null);
  const [revealed, setRevealed] = useState(false);
  const [score, setScore] = useState(0);
  const [finished, setFinished] = useState(false);

  if (questions.length === 0) return <div className="qz qz--empty">{t.empty}</div>;

  const q = questions[idx];
  const isRight = picked !== null && Boolean(q.options[picked]?.correct);
  const last = idx === questions.length - 1;

  function reveal() {
    if (picked === null || revealed) return;
    setRevealed(true);
    if (q.options[picked]?.correct) setScore((s) => s + 1);
  }

  function advance() {
    if (last) { setFinished(true); return; }
    setIdx((i) => i + 1);
    setPicked(null);
    setRevealed(false);
  }

  function restart() {
    setIdx(0); setPicked(null); setRevealed(false); setScore(0); setFinished(false);
  }

  if (finished) {
    return (
      <section className="qz qz--done">
        <div className="qz__head">
          <span className="qz__title">{t.title}</span>
        </div>
        <p className="qz__result">
          <strong>{t.done}</strong> — {score} {t.score} {questions.length}.
        </p>
        <button type="button" className="btn btn--secondary btn--sm" onClick={restart}>
          {t.restart}
        </button>
      </section>
    );
  }

  return (
    <section className="qz">
      <div className="qz__head">
        <span className="qz__title">{t.title}</span>
        <span className="qz__counter">
          {t.question} {idx + 1}/{questions.length}
        </span>
      </div>

      <fieldset className="qz__fieldset" disabled={revealed}>
        <legend className="qz__q" dangerouslySetInnerHTML={{ __html: inline(q.q) }} />
        {q.options.map((o, i) => {
          const state = !revealed ? "" : o.correct ? " is-correct" : i === picked ? " is-wrong" : " is-dim";
          return (
            <label key={i} className={`qz__opt${state}${picked === i ? " is-picked" : ""}`}>
              <input
                type="radio"
                name={`qz-${idx}`}
                checked={picked === i}
                onChange={() => setPicked(i)}
              />
              <span className="qz__opt-text" dangerouslySetInnerHTML={{ __html: inline(o.text) }} />
              {revealed && (
                <span className="qz__why" dangerouslySetInnerHTML={{ __html: inline(o.why) }} />
              )}
            </label>
          );
        })}
      </fieldset>

      <div className="qz__foot">
        {revealed ? (
          <>
            <span className={`qz__verdict ${isRight ? "is-correct" : "is-wrong"}`}>
              {isRight ? t.correct : t.wrong}
            </span>
            <button type="button" className="btn btn--primary btn--sm" onClick={advance}>
              {last ? t.done : t.next}
            </button>
          </>
        ) : (
          <button
            type="button"
            className="btn btn--primary btn--sm"
            onClick={reveal}
            disabled={picked === null}
          >
            {t.check}
          </button>
        )}
      </div>
    </section>
  );
}
