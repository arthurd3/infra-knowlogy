# Fixture do portão: o MESMO typo, no MESMO ramo morto, em duas linguagens.
# Este arquivo RODA até o fim e sai com 0 — é a metade Python da demonstração.
def enriquecer(codigo):
    return "ok:" + codigo


print("o serviço subiu")
if len("x") > 99:              # ramo que nunca executa
    print(enriquecerr("abc"))  # typo deliberado, idêntico ao do lado Go
print("atendendo")
