package main

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func (a *app) routes() http.Handler {
	// ServeMux do Go 1.22+ já entende método e wildcard no padrão. Uma
	// dependência a menos é uma superfície de CVE a menos na imagem final.
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", a.handleHealthz)
	mux.HandleFunc("GET /readyz", a.handleReadyz)
	mux.Handle("GET /metrics", promhttp.Handler())

	mux.HandleFunc("POST /api/links", a.handleCreate)
	mux.HandleFunc("GET /api/links", a.handleList)
	mux.HandleFunc("GET /api/links/{code}", a.handleGet)
	mux.HandleFunc("GET /{code}", a.handleRedirect)

	return withMetrics(withRecover(mux))
}

// handleHealthz é LIVENESS: "o processo está vivo?". Nunca toca em dependência
// externa. Se ele checasse o Postgres, uma queda do banco faria o orquestrador
// matar e reiniciar todas as réplicas da API — que estão perfeitamente sadias e
// só precisam esperar o banco voltar. Reiniciar não conserta um banco fora do ar.
func (a *app) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReadyz é READINESS: "posso receber tráfego agora?". Aqui sim checamos
// as dependências, porque a resposta certa quando o banco caiu é tirar esta
// réplica do balanceador — não matá-la.
func (a *app) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if err := a.ready(r.Context()); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "degraded", "error": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (a *app) handleCreate(w http.ResponseWriter, r *http.Request) {
	var body struct {
		URL string `json:"url"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "corpo JSON inválido")
		return
	}

	target, err := url.Parse(strings.TrimSpace(body.URL))
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") || target.Host == "" {
		writeErr(w, http.StatusUnprocessableEntity, "url precisa ser http(s) absoluta")
		return
	}

	link, err := a.createLink(r.Context(), target.String())
	if err != nil {
		slog.Error("falha ao criar link", "err", err)
		writeErr(w, http.StatusInternalServerError, "não foi possível criar o link")
		return
	}

	w.Header().Set("Location", a.cfg.BaseURL+"/"+link.Code)
	writeJSON(w, http.StatusCreated, map[string]any{
		"code":      link.Code,
		"url":       link.URL,
		"short_url": a.cfg.BaseURL + "/" + link.Code,
	})
}

func (a *app) handleGet(w http.ResponseWriter, r *http.Request) {
	link, err := a.getLink(r.Context(), r.PathValue("code"))
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusNotFound, "link não encontrado")
		return
	}
	if err != nil {
		slog.Error("falha ao buscar link", "err", err)
		writeErr(w, http.StatusInternalServerError, "erro interno")
		return
	}
	writeJSON(w, http.StatusOK, link)
}

func (a *app) handleList(w http.ResponseWriter, r *http.Request) {
	limit := 20
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 100 {
			limit = n
		}
	}
	links, err := a.listLinks(r.Context(), limit)
	if err != nil {
		slog.Error("falha ao listar links", "err", err)
		writeErr(w, http.StatusInternalServerError, "erro interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"links": links, "count": len(links)})
}

func (a *app) handleRedirect(w http.ResponseWriter, r *http.Request) {
	code := r.PathValue("code")
	if code == "" || code == "favicon.ico" {
		http.NotFound(w, r)
		return
	}

	target, err := a.lookup(r.Context(), code)
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusNotFound, "link não encontrado")
		return
	}
	if err != nil {
		slog.Error("falha no redirect", "err", err, "code", code)
		writeErr(w, http.StatusInternalServerError, "erro interno")
		return
	}

	go a.countClick(code)
	http.Redirect(w, r, target, http.StatusFound)
}

// ─── Middleware ──────────────────────────────────────────────────────────────

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func withMetrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		// Rotulamos pelo PADRÃO da rota, não pelo caminho concreto. Usar o
		// caminho aqui criaria uma série temporal nova por código de link e
		// derrubaria o Prometheus — é a armadilha clássica de alta cardinalidade.
		route := routeLabel(r)
		status := strconv.Itoa(rec.status)
		httpRequests.WithLabelValues(r.Method, route, status).Inc()
		httpDuration.WithLabelValues(r.Method, route).Observe(time.Since(start).Seconds())
	})
}

func withRecover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				slog.Error("panic recuperado", "panic", rec, "path", r.URL.Path)
				writeErr(w, http.StatusInternalServerError, "erro interno")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func routeLabel(r *http.Request) string {
	if p := r.Pattern; p != "" {
		if i := strings.IndexByte(p, ' '); i >= 0 {
			return p[i+1:]
		}
		return p
	}
	return "unmatched"
}

// ─── Respostas ───────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		slog.Error("falha ao escrever resposta", "err", err)
	}
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
