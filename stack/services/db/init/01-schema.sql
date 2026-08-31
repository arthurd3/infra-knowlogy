-- Executado UMA VEZ, na primeira inicialização do volume de dados.
--
-- A imagem oficial do Postgres roda tudo em /docker-entrypoint-initdb.d/ em
-- ordem alfabética, e SOMENTE se o diretório de dados estiver vazio. Isso
-- significa que editar este arquivo não afeta um volume que já existe — é a
-- pegadinha nº 1 de quem usa o Postgres em Docker. Para reaplicar: `make nuke`.
--
-- Em produção de verdade, isto aqui vira uma ferramenta de migração
-- (Flyway, Liquibase, golang-migrate, Alembic). Um script de init só funciona
-- para o primeiro dia de vida do banco.

CREATE TABLE IF NOT EXISTS links (
    code         TEXT PRIMARY KEY,
    url          TEXT        NOT NULL,

    -- Preenchidos de forma assíncrona pelo worker-py.
    title        TEXT,
    favicon      TEXT,
    enriched_at  TIMESTAMPTZ,
    enrich_error TEXT,
    attempts     INTEGER     NOT NULL DEFAULT 0,

    clicks       BIGINT      NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT links_url_not_blank CHECK (length(trim(url)) > 0)
);

-- A listagem da API ordena por created_at DESC. Sem este índice ela vira um
-- seq scan + sort assim que a tabela passa de algumas milhares de linhas.
CREATE INDEX IF NOT EXISTS links_created_at_idx ON links (created_at DESC);

-- Índice parcial: só indexa as linhas que ainda não foram enriquecidas, que é
-- exatamente o conjunto que interessa consultar. Um índice parcial ocupa uma
-- fração do espaço de um índice completo sobre a mesma coluna.
CREATE INDEX IF NOT EXISTS links_pending_enrichment_idx
    ON links (created_at) WHERE enriched_at IS NULL;
