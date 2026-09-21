package main

import (
	"context"
	"fmt"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

// tracerName identifica os spans criados à mão por este serviço. O nome vira
// o `scope` no backend, e é o que separa "span que a biblioteca criou" de
// "span que eu escrevi".
const tracerName = "github.com/infra-knowlogy/api-go"

// tracer é o ponto único de criação de span. Ele é válido mesmo sem tracing
// configurado: a API do OTel devolve um no-op, e o código de negócio não
// precisa de `if`.
func tracer() trace.Tracer { return otel.Tracer(tracerName) }

// setupTracing liga o OTel se OTEL_EXPORTER_OTLP_ENDPOINT estiver definido.
//
// ─── Por que ele pode não ligar, e por que isso é de propósito ──────────────
// A variável ausente significa "sem tracing", e o binário continua servindo
// normalmente com spans no-op. É o que permite a mesma imagem rodar no perfil
// `obs` e fora dele — e é o que impede um coletor indisponível de derrubar a
// API, que é o erro clássico de instrumentação.
//
// O `shutdown` devolvido PRECISA ser chamado: o exportador é em lote, e sem o
// flush final os spans da última requisição morrem no processo.
func setupTracing(ctx context.Context, servico, versao string) (func(context.Context) error, error) {
	endpoint := getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")
	if endpoint == "" {
		// Propagador mesmo assim: se um traceparent chegar de fora, ele ainda
		// atravessa este serviço e chega ao próximo. Um serviço sem tracing no
		// meio de uma cadeia não deveria QUEBRAR a cadeia.
		otel.SetTextMapPropagator(propagation.TraceContext{})
		return func(context.Context) error { return nil }, nil
	}

	exp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(endpoint),
		// Sem TLS: o coletor está na rede interna da stack, e exigir
		// certificado aqui seria teatro — a lição de malha mostra o que
		// custa fazer isso de verdade.
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithTimeout(5*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("exportador otlp: %w", err)
	}

	// `resource.Merge` RECUSA juntar dois resources com Schema URL diferente, e
	// o `resource.Default()` carrega a versão de semconv do SDK. Importar um
	// `semconv/vX` de outra versão dá:
	//
	//   resource: conflicting Schema URL: .../1.43.0 and .../1.26.0
	//
	// — uma mensagem clara sobre um acoplamento que ninguém avisa: atualizar o
	// SDK pode exigir atualizar o import do semconv junto.
	res, err := resource.Merge(resource.Default(), resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(servico),
		semconv.ServiceVersion(versao),
	))
	if err != nil {
		return nil, fmt.Errorf("resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		// Em lote, e não síncrono: exportar span a span acrescentaria uma
		// chamada de rede ao caminho de cada requisição.
		sdktrace.WithBatcher(exp, sdktrace.WithBatchTimeout(2*time.Second)),
		sdktrace.WithResource(res),
		// AlwaysSample porque esta stack tem tráfego de laboratório. Em
		// produção isto é uma decisão de custo: cada span amostrado é dado
		// ingerido, e a lição de observabilidade mostra o preço por GB.
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)

	// O propagador é o que escreve e lê o cabeçalho `traceparent` do W3C.
	// Sem esta linha o SDK funciona, gera spans bonitos — e cada serviço vira
	// um trace separado. É a linha mais esquecida de toda instrumentação.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	return tp.Shutdown, nil
}
