# O controller do Jenkins, pronto antes de subir.
#
# Duas regras moldam este arquivo:
#
#   1. Todo download acontece AQUI, em tempo de build. O `jenkins-plugin-cli`
#      fala com o update center; se ele rodasse no start do container, o
#      `make cicd-verify` passaria a depender de rede e do humor do upstream —
#      o oposto de um portão reprodutível.
#   2. Nada de assistente. `runSetupWizard=false` e a configuração inteira vem
#      do JCasC. Um controller que pede clique não é infraestrutura, é uma
#      máquina de estimação.
FROM jenkins/jenkins:lts-jdk21@sha256:c1e4c349365f6d16d88595b2c5f7e8ff39b8ae1d061f62420bac193b4b9616d0

# `--latest false` é o que faz o pin valer: sem ele a CLI sobe as dependências
# transitivas para a última versão do dia e o plugins.txt vira decoração.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --latest false

# A configuração fica FORA de /var/jenkins_home, e isso não é estilo.
#
# /var/jenkins_home é volume nomeado, e volume nomeado só é populado a partir
# da imagem quando está VAZIO — é a lição 6 deste repositório aplicada a nós
# mesmos. Com a configuração lá dentro, a primeira subida funciona e toda
# alteração posterior no Dockerfile é ignorada em silêncio: o volume já tem
# conteúdo, o Docker não copia nada, e você fica depurando um YAML que o
# Jenkins nunca leu.
#
# Em /opt a imagem manda. `make cicd-up` reconstrói, o container reinicia e a
# configuração nova entra.
COPY casc/ /opt/casc/
COPY jobs/ /opt/jobs-dsl/
ENV CASC_JENKINS_CONFIG=/opt/casc

# SECRETS é lido pelo SecretSource de arquivo do JCasC: `${chave}` no YAML vira
# o conteúdo de /run/secrets/chave. É a mesma convenção do config.go e do
# config.py desta stack — segredo é arquivo montado, nunca variável.
# O DL3064 dispara pelo NOME da variável, não pelo valor: aqui SECRETS é um
# CAMINHO, e o nome é exigido pelo SecretSource de arquivo do JCasC. Renomear
# quebraria a leitura; suprimir sem explicar seria a mesma coisa que ignorar o
# lint. Se algum dia o valor virar um segredo de verdade, esta exceção fica
# errada — e é por isso que ela está encostada na linha.
#
# A diretiva abaixo precisa ser a ÚLTIMA linha antes da instrução: com
# qualquer comentário entre ela e o ENV, o hadolint a ignora em silêncio.
# hadolint ignore=DL3064
ENV SECRETS=/run/secrets

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false \
-Dhudson.model.DownloadService.noSignatureCheck=true \
-Djava.awt.headless=true"

# 8080 é a UI. A porta 50000 (agente TCP) NÃO é exposta de propósito: o agente
# entra por WebSocket sobre a mesma 8080, e o casc desliga o listener TCP.
EXPOSE 8080
