# Fixture mínima da sonda de pré-requisitos do módulo CI/CD.
#
# Ela existe para uma pergunta só: este host consegue construir uma imagem
# SEM daemon e SEM privilégio? O `RUN` é obrigatório — é ele que exige montar
# /proc dentro do namespace, que é exatamente onde o SELinux barra.
FROM alpine:3.22
RUN echo "construido sem daemon e sem privilegio" > /prova.txt
CMD ["cat", "/prova.txt"]
