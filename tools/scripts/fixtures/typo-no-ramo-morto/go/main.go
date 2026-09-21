// Fixture do portão: o MESMO typo, no MESMO ramo morto, em duas linguagens.
// Este arquivo NÃO compila de propósito — é a metade Go da demonstração de
// quando o erro aparece. O par em Python está no diretório ao lado.
package main

import "fmt"

func enriquecer(codigo string) string { return "ok:" + codigo }

func main() {
	fmt.Println("o serviço subiu")
	if len("x") > 99 { // ramo que nunca executa
		fmt.Println(enriquecerr("abc")) // typo deliberado: falta um r… ou sobra
	}
	fmt.Println("atendendo")
}
