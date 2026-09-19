// Os jobs deste controller, em código.
//
// Rodado pelo bloco `jobs:` do JCasC a cada boot e a cada reload. É por isso
// que o portão consegue exigir que o conjunto de jobs seja EXATAMENTE este:
// um job criado à mão na UI sobrevive ao reload e aparece na diferença.
//
// O `scriptPath` aponta para o Jenkinsfile do próprio repositório, servido
// pelo `git daemon` do serviço scm. O pipeline não vive aqui — vive versionado
// ao lado do código que ele constrói, que é o ponto de "pipeline como código".
//
// O remote é git:// e não um caminho local de propósito: o plugin git recusa
// diretório local por segurança, e a resposta certa é um remote de verdade,
// não desligar o controle.

pipelineJob('stack-pipeline') {
    description('Constroi as imagens da stack deste repositorio. Criado pelo seed em cicd/controller/jobs/seed.groovy — nao edite pela UI.')
    definition {
        cpsScm {
            scm {
                git {
                    remote { url('git://scm/repo') }
                    // O CI testa o que está COMMITADO, não o working tree. Uma
                    // alteração não commitada não é construída — comportamento
                    // correto, e surpresa garantida na primeira hora.
                    branch('*/main')
                    extensions {}
                }
            }
            scriptPath('cicd/Jenkinsfile')
            lightweight(false)
        }
    }
}

// O job negativo. Ele constrói uma fixture com violações de hadolint
// deliberadas, e o portão exige que ele REPROVE. Um portão que só conhece o
// caminho feliz passaria com o lint desligado.
pipelineJob('stack-negative-lint') {
    description('Tem que FALHAR. Prova que o estagio de lint recusa de verdade. Criado pelo seed.')
    definition {
        cpsScm {
            scm {
                git {
                    remote { url('git://scm/repo') }
                    branch('*/main')
                    extensions {}
                }
            }
            scriptPath('cicd/Jenkinsfile.negative')
            lightweight(false)
        }
    }
}
