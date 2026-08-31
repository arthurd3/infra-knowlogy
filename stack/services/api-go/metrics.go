package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Métricas no formato Prometheus, expostas em /metrics. O Prometheus faz PULL:
// ele descobre este container e raspa o endpoint. A aplicação não sabe (nem
// precisa saber) que o Prometheus existe.
var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "api_http_requests_total",
		Help: "Total de requisições HTTP por método, rota e status.",
	}, []string{"method", "route", "status"})

	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "api_http_request_duration_seconds",
		Help:    "Duração das requisições HTTP em segundos.",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "route"})

	linksCreated = promauto.NewCounter(prometheus.CounterOpts{
		Name: "api_links_created_total",
		Help: "Total de links encurtados criados.",
	})

	cacheHits = promauto.NewCounter(prometheus.CounterOpts{
		Name: "api_cache_hits_total",
		Help: "Redirects resolvidos pelo cache Redis, sem tocar o Postgres.",
	})

	cacheMisses = promauto.NewCounter(prometheus.CounterOpts{
		Name: "api_cache_misses_total",
		Help: "Redirects que precisaram consultar o Postgres.",
	})

	enqueueFailures = promauto.NewCounter(prometheus.CounterOpts{
		Name: "api_enqueue_failures_total",
		Help: "Falhas ao enfileirar enriquecimento no Redis (não falham a requisição).",
	})
)
