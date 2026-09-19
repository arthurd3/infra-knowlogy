// Os jobs deste controller, em código.
//
// Rodado pelo bloco `jobs:` do JCasC a cada boot e a cada reload. É por isso
// que o portão consegue exigir que o conjunto de jobs seja EXATAMENTE este:
// um job criado à mão na UI sobrevive ao reload e aparece na diferença.
//
// O `scriptPath` aponta para o Jenkinsfile do próprio repositório, montado em
// /repo. O pipeline não vive aqui — vive versionado ao lado do código que ele
// constrói, que é o ponto de "pipeline como código".

pipelineJob('stack-pipeline') {
    description('Constroi as imagens da stack deste repositorio. Criado pelo seed em cicd/controller/jobs/seed.groovy — nao edite pela UI.')
    definition {
        cpsScm {
            scm {
                git {
                    remote { url('/repo') }
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
