package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

// runHealthcheck faz o próprio binário virar o cliente do health check.
//
// Por que isso existe: a imagem final é `distroless`/`scratch` — não há shell,
// não há curl, não há wget. A instrução HEALTHCHECK do Docker precisa executar
// ALGO dentro do container, e a única coisa executável ali é este binário.
// Então ele ganha um segundo modo: `api-go healthcheck`.
//
// A alternativa comum — instalar curl só para o health check — anexaria um
// gerenciador de pacotes e dezenas de bibliotecas à imagem de produção,
// desfazendo exatamente o que a base mínima conquistou.
func runHealthcheck() int {
	addr := getenv("LISTEN_ADDR", ":8080")
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "LISTEN_ADDR inválido %q: %v\n", addr, err)
		return 1
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}

	client := &http.Client{Timeout: 2 * time.Second}
	url := fmt.Sprintf("http://%s/readyz", net.JoinHostPort(host, port))

	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "healthcheck: status %d\n", resp.StatusCode)
		return 1
	}
	return 0
}
