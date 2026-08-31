import { useState } from "react";

/**
 * Explorador de camadas.
 *
 * Duas ideias que quase todo mundo entende errado no começo:
 *   1. a imagem é uma PILHA de camadas somente-leitura;
 *   2. o container só acrescenta UMA camada gravável no topo.
 *
 * Daí sai a consequência que o controle de containers abaixo demonstra:
 * dez containers da mesma imagem não ocupam dez vezes o disco.
 */

interface Layer {
  instruction: string;
  bytes: number;
  detail: { pt: string; en: string };
}

// Camadas do stack/services/worker-py/Dockerfile (alvo dist), com os tamanhos
// aproximados que o `docker history` reporta.
const LAYERS: Layer[] = [
  {
    instruction: "FROM python:3.13-slim-bookworm",
    bytes: 45_000_000,
    detail: {
      pt: "A base: Debian mínimo + o interpretador Python. É a maior camada, e é a que você quase nunca reconstrói.",
      en: "The base: minimal Debian + the Python interpreter. Biggest layer, and the one you almost never rebuild.",
    },
  },
  {
    instruction: "ENV PYTHONUNBUFFERED=1 …",
    bytes: 0,
    detail: {
      pt: "Camadas de metadado ocupam zero byte de sistema de arquivos — elas só alteram o manifesto da imagem.",
      en: "Metadata layers take zero filesystem bytes — they only change the image manifest.",
    },
  },
  {
    instruction: "RUN groupadd … && useradd …",
    bytes: 4_800,
    detail: {
      pt: "Alterou /etc/passwd, /etc/group e criou /home/app. Alguns kilobytes.",
      en: "Modified /etc/passwd, /etc/group and created /home/app. A few kilobytes.",
    },
  },
  {
    instruction: "COPY --from=build --chown=65532 /app /app",
    bytes: 4_900_000,
    detail: {
      pt: "A venv com as 12 dependências e o código do worker. É a camada que muda a cada deploy.",
      en: "The venv with all 12 dependencies plus the worker code. This is the layer that changes on every deploy.",
    },
  },
];

const WRITABLE = 120_000;

const COPY_UI = {
  pt: {
    title: "Pilha de camadas — worker-py (alvo dist)",
    writable: "camada gravável do container",
    readonly: "somente leitura · compartilhada",
    containers: "Containers rodando esta imagem",
    imageSize: "Imagem (compartilhada)",
    writableTotal: "Camadas graváveis",
    total: "Disco total",
    naive: "Se cada container copiasse a imagem inteira",
    saved: "economia",
    hint: "Aumente o número de containers: a parte compartilhada não cresce.",
    click: "Clique numa camada para ver o que ela contém.",
  },
  en: {
    title: "Layer stack — worker-py (dist target)",
    writable: "container writable layer",
    readonly: "read-only · shared",
    containers: "Containers running this image",
    imageSize: "Image (shared)",
    writableTotal: "Writable layers",
    total: "Total disk",
    naive: "If each container copied the whole image",
    saved: "saved",
    hint: "Raise the container count: the shared part does not grow.",
    click: "Click a layer to see what it holds.",
  },
} as const;

function fmt(bytes: number) {
  if (bytes === 0) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1_048_576) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / 1_048_576).toFixed(1)} MB`;
}

export default function LayerExplorer({ lang = "pt" }: { lang?: "pt" | "en" }) {
  const t = COPY_UI[lang];
  const [selected, setSelected] = useState<number | null>(null);
  const [containers, setContainers] = useState(1);

  const imageBytes = LAYERS.reduce((sum, l) => sum + l.bytes, 0);
  const writableBytes = WRITABLE * containers;
  const total = imageBytes + writableBytes;
  const naive = (imageBytes + WRITABLE) * containers;
  const saved = 1 - total / naive;
  const maxLayer = Math.max(...LAYERS.map((l) => l.bytes), WRITABLE);

  return (
    <div className="lx">
      <div className="lx__title">{t.title}</div>

      <div className="lx__stack">
        {/* Camada gravável, desenhada por cima porque é onde ela vive. */}
        {Array.from({ length: containers }, (_, i) => (
          <div className="lx__layer lx__layer--writable" key={`w${i}`}>
            <span className="lx__instr">{t.writable} #{i + 1}</span>
            <span
              className="lx__viz lx__viz--writable"
              style={{ width: `${Math.max((WRITABLE / maxLayer) * 100, 2)}%` }}
            />
            <span className="lx__size">{fmt(WRITABLE)}</span>
          </div>
        ))}

        {[...LAYERS].reverse().map((layer, revIndex) => {
          const index = LAYERS.length - 1 - revIndex;
          const active = selected === index;
          return (
            <button
              type="button"
              key={layer.instruction}
              className={`lx__layer lx__layer--ro ${active ? "is-active" : ""}`}
              onClick={() => setSelected(active ? null : index)}
              aria-expanded={active}
            >
              <span className="lx__instr"><code>{layer.instruction}</code></span>
              <span
                className="lx__viz"
                style={{ width: `${Math.max((layer.bytes / maxLayer) * 100, 1.5)}%` }}
              />
              <span className="lx__size">{fmt(layer.bytes)}</span>
            </button>
          );
        })}
      </div>

      {selected !== null ? (
        <p className="lx__detail">{LAYERS[selected].detail[lang]}</p>
      ) : (
        <p className="lx__detail lx__detail--muted">{t.click}</p>
      )}

      <div className="lx__controls">
        <label className="lx__slider">
          {t.containers}: <strong>{containers}</strong>
          <input
            type="range" min={1} max={10} value={containers}
            onChange={(e) => setContainers(Number(e.target.value))}
          />
        </label>
      </div>

      <dl className="lx__totals">
        <div><dt>{t.imageSize}</dt><dd>{fmt(imageBytes)}</dd></div>
        <div><dt>{t.writableTotal}</dt><dd>{containers} × {fmt(WRITABLE)} = {fmt(writableBytes)}</dd></div>
        <div className="is-total"><dt>{t.total}</dt><dd>{fmt(total)}</dd></div>
        <div className="is-naive">
          <dt>{t.naive}</dt>
          <dd>{fmt(naive)} <span className="lx__saved">−{Math.round(saved * 100)}% {t.saved}</span></dd>
        </div>
      </dl>

      <p className="lx__hint">{t.hint}</p>
    </div>
  );
}
