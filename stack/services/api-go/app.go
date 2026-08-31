package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

var errNotFound = errors.New("link não encontrado")

// Link é uma linha da tabela `links`. Os campos de enriquecimento (Title,
// Favicon, EnrichedAt) começam vazios e são preenchidos pelo worker-py depois,
// de forma assíncrona.
type Link struct {
	Code       string     `json:"code"`
	URL        string     `json:"url"`
	Title      *string    `json:"title"`
	Favicon    *string    `json:"favicon"`
	Clicks     int64      `json:"clicks"`
	CreatedAt  time.Time  `json:"created_at"`
	EnrichedAt *time.Time `json:"enriched_at"`
	// EnrichError guarda por que o worker desistiu (SSRF bloqueado, 404, timeout).
	// Expor a falha é melhor que fingir que o link só "ainda não foi processado".
	EnrichError *string `json:"enrich_error"`
}

type app struct {
	cfg   Config
	db    *pgxpool.Pool
	redis *redis.Client
}

func newApp(ctx context.Context, cfg Config) (*app, error) {
	poolCfg, err := pgxpool.ParseConfig(cfg.PostgresDSN)
	if err != nil {
		return nil, fmt.Errorf("dsn do postgres: %w", err)
	}
	// Um container é descartável e pode ser replicado. Um pool pequeno por
	// réplica evita estourar o max_connections do Postgres quando você escala.
	poolCfg.MaxConns = 10
	poolCfg.MinConns = 2
	poolCfg.MaxConnLifetime = 30 * time.Minute

	dialCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	db, err := pgxpool.NewWithConfig(dialCtx, poolCfg)
	if err != nil {
		return nil, fmt.Errorf("conectando no postgres: %w", err)
	}

	rdb := redis.NewClient(&redis.Options{
		Addr:         cfg.RedisAddr,
		DialTimeout:  5 * time.Second,
		ReadTimeout:  3 * time.Second,
		WriteTimeout: 3 * time.Second,
	})

	return &app{cfg: cfg, db: db, redis: rdb}, nil
}

func (a *app) Close() {
	if a.db != nil {
		a.db.Close()
	}
	if a.redis != nil {
		_ = a.redis.Close()
	}
}

// ─── Persistência ────────────────────────────────────────────────────────────

func (a *app) createLink(ctx context.Context, rawURL string) (Link, error) {
	code, err := newCode(7)
	if err != nil {
		return Link{}, err
	}

	var l Link
	err = a.db.QueryRow(ctx, `
		INSERT INTO links (code, url)
		VALUES ($1, $2)
		RETURNING code, url, title, favicon, clicks, created_at, enriched_at, enrich_error
	`, code, rawURL).Scan(&l.Code, &l.URL, &l.Title, &l.Favicon, &l.Clicks, &l.CreatedAt, &l.EnrichedAt, &l.EnrichError)
	if err != nil {
		return Link{}, fmt.Errorf("inserindo link: %w", err)
	}

	// Enfileira o enriquecimento. Falhar aqui NÃO falha a requisição: o link já
	// funciona sem título. Fatiar o trabalho entre "o que o usuário precisa
	// agora" e "o que pode acontecer depois" é o que mantém a API rápida.
	if err := a.redis.LPush(ctx, a.cfg.RedisQueue, l.Code).Err(); err != nil {
		enqueueFailures.Inc()
	}
	linksCreated.Inc()
	return l, nil
}

func (a *app) lookup(ctx context.Context, code string) (string, error) {
	cacheKey := "link:" + code

	// Caminho quente: Redis. Um redirect não deveria tocar o banco.
	if url, err := a.redis.Get(ctx, cacheKey).Result(); err == nil && url != "" {
		cacheHits.Inc()
		return url, nil
	}
	cacheMisses.Inc()

	var url string
	err := a.db.QueryRow(ctx, `SELECT url FROM links WHERE code = $1`, code).Scan(&url)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", errNotFound
	}
	if err != nil {
		return "", fmt.Errorf("buscando link: %w", err)
	}

	a.redis.Set(ctx, cacheKey, url, a.cfg.CacheTTL)
	return url, nil
}

func (a *app) getLink(ctx context.Context, code string) (Link, error) {
	var l Link
	err := a.db.QueryRow(ctx, `
		SELECT code, url, title, favicon, clicks, created_at, enriched_at, enrich_error
		FROM links WHERE code = $1
	`, code).Scan(&l.Code, &l.URL, &l.Title, &l.Favicon, &l.Clicks, &l.CreatedAt, &l.EnrichedAt, &l.EnrichError)
	if errors.Is(err, pgx.ErrNoRows) {
		return Link{}, errNotFound
	}
	if err != nil {
		return Link{}, fmt.Errorf("buscando link: %w", err)
	}
	return l, nil
}

func (a *app) listLinks(ctx context.Context, limit int) ([]Link, error) {
	rows, err := a.db.Query(ctx, `
		SELECT code, url, title, favicon, clicks, created_at, enriched_at, enrich_error
		FROM links ORDER BY created_at DESC LIMIT $1
	`, limit)
	if err != nil {
		return nil, fmt.Errorf("listando links: %w", err)
	}
	defer rows.Close()

	links := make([]Link, 0, limit)
	for rows.Next() {
		var l Link
		if err := rows.Scan(&l.Code, &l.URL, &l.Title, &l.Favicon, &l.Clicks, &l.CreatedAt, &l.EnrichedAt, &l.EnrichError); err != nil {
			return nil, err
		}
		links = append(links, l)
	}
	return links, rows.Err()
}

// countClick é disparado em goroutine para não somar latência ao redirect.
func (a *app) countClick(code string) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, _ = a.db.Exec(ctx, `UPDATE links SET clicks = clicks + 1 WHERE code = $1`, code)
}

// ─── Saúde ───────────────────────────────────────────────────────────────────

// ready checa as dependências. É o que /readyz responde — e é diferente de
// /healthz de propósito: ver o comentário em server.go.
func (a *app) ready(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	if err := a.db.Ping(ctx); err != nil {
		return fmt.Errorf("postgres: %w", err)
	}
	if err := a.redis.Ping(ctx).Err(); err != nil {
		return fmt.Errorf("redis: %w", err)
	}
	return nil
}

// ─── Utilidades ──────────────────────────────────────────────────────────────

const alphabet = "23456789abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ"

// newCode gera um código curto com crypto/rand. O alfabeto omite os caracteres
// ambíguos (0/O, 1/l/I) para que o código sobreviva a ser ditado por telefone.
func newCode(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("gerando código: %w", err)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return string(b), nil
}
