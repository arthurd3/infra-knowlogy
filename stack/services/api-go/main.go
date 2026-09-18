// Command api-go é a API do encurtador de links da stack de referência.
//
// Ele existe para ser lido: cada decisão aqui tem uma lição correspondente no
// site. Os pontos didáticos principais são o desligamento gracioso (SIGTERM),
// a separação entre liveness e readiness, e o fato de que este binário é
// estático — ele roda numa imagem `scratch` sem nenhuma biblioteca do sistema.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	// Segundo modo de operação: `api-go healthcheck`. Ver healthcheck.go para o
	// porquê — resumindo, numa imagem distroless não existe curl para chamar.
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(runHealthcheck())
	}

	// Logs estruturados em JSON direto no stdout. Fator XI do 12-Factor: a
	// aplicação nunca escreve em arquivo, nunca rotaciona nada. Quem coleta,
	// roteia e retém é a plataforma (aqui, o log driver do Docker + Alloy).
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: parseLevel(getenv("LOG_LEVEL", "info")),
	}))
	slog.SetDefault(logger)

	cfg, err := loadConfig()
	if err != nil {
		logger.Error("configuração inválida", "err", err)
		os.Exit(1)
	}

	// signal.NotifyContext cancela o ctx no primeiro SIGTERM/SIGINT. É isso que
	// transforma o `docker stop` num desligamento de ~0.1s em vez dos 10s que o
	// Docker espera antes de mandar SIGKILL.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	app, err := newApp(ctx, cfg)
	if err != nil {
		logger.Error("falha ao inicializar a aplicação", "err", err)
		os.Exit(1)
	}
	defer app.Close()

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           app.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		logger.Info("api ouvindo", "addr", cfg.Addr, "base_url", cfg.BaseURL)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		logger.Error("servidor morreu", "err", err)
		os.Exit(1)
	case <-ctx.Done():
		logger.Info("sinal recebido, desligando graciosamente")
	}

	// No Kubernetes, SIGTERM chega ANTES de o endpoint ser removido de todos os
	// kube-proxies: fechar o listener imediatamente derruba as conexões que
	// ainda chegam nessa janela de propagação. A pausa mantém o pod servindo
	// enquanto o cluster para de mandar tráfego novo. Zero-downtime não é um
	// dom do orquestrador — é uma cooperação da aplicação (ver a lição 1 da
	// trilha kubernetes). No Compose o delay é 0 e nada muda.
	if cfg.ShutdownDelay > 0 {
		logger.Info("esperando a remoção do endpoint propagar", "delay", cfg.ShutdownDelay)
		time.Sleep(cfg.ShutdownDelay)
	}

	// Drena as requisições em voo antes de sair. O timeout precisa ser MENOR do
	// que o stop_grace_period do Compose, senão o SIGKILL chega no meio do drain.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("desligamento forçado", "err", err)
		os.Exit(1)
	}
	logger.Info("desligado limpo")
}
