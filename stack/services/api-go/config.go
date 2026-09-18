package main

import (
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"strings"
	"time"
)

// Config vem inteiramente do ambiente — Fator III do 12-Factor. A mesma imagem
// roda em dev, staging e produção; só o ambiente muda. Não existe `if
// env == "production"` em lugar nenhum deste código.
type Config struct {
	Addr            string
	BaseURL         string
	PostgresDSN     string
	RedisAddr       string
	RedisQueue      string
	CacheTTL        time.Duration
	ShutdownTimeout time.Duration
	ShutdownDelay   time.Duration
}

func loadConfig() (Config, error) {
	cfg := Config{
		Addr:            getenv("LISTEN_ADDR", ":8080"),
		BaseURL:         strings.TrimRight(getenv("BASE_URL", "http://localhost:8080"), "/"),
		RedisQueue:      getenv("REDIS_QUEUE", "links:enrich"),
		CacheTTL:        getenvDuration("CACHE_TTL", 10*time.Minute),
		ShutdownTimeout: getenvDuration("SHUTDOWN_TIMEOUT", 10*time.Second),
		// Pausa entre receber SIGTERM e fechar o listener. Zero por padrão (o
		// Compose tira o container do DNS antes do stop, ninguém mais conecta).
		// No Kubernetes o pod recebe SIGTERM ANTES de o kube-proxy parar de
		// mandar conexões novas para ele; fechar o listener na hora derruba as
		// que chegam nessa janela. O Deployment define SHUTDOWN_DELAY=2s.
		ShutdownDelay: getenvDuration("SHUTDOWN_DELAY", 0),
	}

	// A senha nunca chega por variável de ambiente: ela é lida de um arquivo
	// montado pelo Compose em /run/secrets/<nome>. Variável de ambiente aparece
	// em `docker inspect`, em crash dumps e é herdada por todo processo filho —
	// arquivo montado, não.
	password, err := readSecret("POSTGRES_PASSWORD")
	if err != nil {
		return cfg, err
	}

	host := getenv("POSTGRES_HOST", "db")
	port := getenv("POSTGRES_PORT", "5432")
	user := getenv("POSTGRES_USER", "links")
	dbname := getenv("POSTGRES_DB", "links")
	sslmode := getenv("POSTGRES_SSLMODE", "disable")

	cfg.PostgresDSN = fmt.Sprintf(
		"postgres://%s:%s@%s:%s/%s?sslmode=%s",
		url.QueryEscape(user), url.QueryEscape(password), host, port, dbname, sslmode,
	)
	cfg.RedisAddr = fmt.Sprintf("%s:%s", getenv("REDIS_HOST", "cache"), getenv("REDIS_PORT", "6379"))

	return cfg, nil
}

// readSecret implementa a convenção `<VAR>_FILE` que as imagens oficiais
// (postgres, mysql, redis…) também seguem. Preferimos o arquivo; caímos para a
// variável de ambiente só para facilitar o `go run` local.
func readSecret(name string) (string, error) {
	if path := os.Getenv(name + "_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("lendo %s_FILE (%s): %w", name, path, err)
		}
		return strings.TrimSpace(string(b)), nil
	}
	if v := os.Getenv(name); v != "" {
		slog.Warn("segredo veio de variável de ambiente; prefira "+name+"_FILE", "var", name)
		return v, nil
	}
	return "", fmt.Errorf("segredo ausente: defina %s_FILE ou %s", name, name)
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getenvDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
		slog.Warn("duração inválida, usando o padrão", "key", key, "value", v, "default", fallback)
	}
	return fallback
}

func parseLevel(s string) slog.Level {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
