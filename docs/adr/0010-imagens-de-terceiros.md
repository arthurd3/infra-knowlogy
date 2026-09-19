# 0010 — Imagens de terceiros no site

**Estado:** aceita · **Data:** 2026-09-19

## Contexto

Até aqui, o site tinha **zero imagens**. Os 15 diagramas são SVG escritos à mão,
e o comentário no topo do `Figure.astro` explica por quê:

> Os diagramas são SVG escritos à mão, não imagens: eles herdam as cores do tema
> pelas custom properties, continuam legíveis em qualquer zoom, entram no
> `git diff` como texto e pesam alguns kilobytes. Uma captura de tela não faz
> nada disso.

Tudo verdade. E havia uma perda: certos desenhos são **canônicos**. O diagrama de
componentes do Kubernetes é o mesmo em toda a literatura; o leitor vai
reencontrá-lo na documentação oficial, num livro e num slide de conferência.
Redesenhá-lo em outro estilo obriga o leitor a traduzir duas vezes.

A pergunta: dá para publicar a imagem de outra pessoa sem quebrar o tema, sem
inchar a página e sem problema de licença?

## Decisão

Dá, com procedência obrigatória e um custo declarado.

### 1. `Figure` aceita `src`, e cobra por isso

`src`, `credit`, `creditUrl`, `license`. Sem `src`, o componente é exatamente o
que sempre foi — os 15 diagramas não mudaram uma linha. Com `src`, a checagem 10
do `site-check.mjs` exige, **no HTML gerado**: `alt` não-vazio, crédito visível
e um arquivo que existe no `dist/`. Imagem carregada de host externo é reprovada
— ela vazaria o leitor para um terceiro e quebraria o site quando o host sumisse.

### 2. A licença é a fronteira, e ela foi apurada

| Fonte | Licença | Pode embutir? |
|---|---|---|
| Documentação do Kubernetes | **CC BY 4.0** | sim, com atribuição |
| Especificação do SLSA | Community Specification License 1.0 | sim, atribuindo nome, versão e origem |
| AWS Architecture Icons | proprietária da AWS, **modificação proibida** | não |
| Post de blog qualquer | todos os direitos reservados | **não** |

Quando o campo `license` não pode ser preenchido, a saída é **redesenhar em SVG
e citar o original** — para isso existe a prop `redrawnFrom`, que troca o rótulo
do crédito de "Fonte" para "Redesenhado a partir de".

### 3. A imagem de fora não acompanha o tema, então ganha o tema dela

Quase todo diagrama publicado na internet foi desenhado para fundo branco e tem
texto preto sobre fundo transparente. Servido cru no tema escuro, vira texto
preto sobre quase-preto. A prop `plate="light"` põe uma placa branca atrás dele.

Isso é feio de admitir e é a admissão honesta do custo: o SVG daqui segue o
leitor; a imagem de fora não. A placa é o preço, não uma solução.

### 4. A figura anotada é o formato preferido

O slot `legend` do `Figure` já existia, com CSS e sem nenhum consumidor. Ele
passa a ser o mecanismo de **explicar** a imagem: uma lista numerada onde cada
item amarra uma peça do desenho a algo que este repositório mede. O item do
`kube-controller-manager` cita os **2 s** de auto-cura que o portão cronometrou;
o do `kubelet` explica por que o `HEALTHCHECK` do Dockerfile não vale nada aqui.

Pegar uma imagem pronta e explicá-la peça por peça ensina mais que redesenhá-la
e dizer menos.

## A armadilha que isto descobriu

O export SVG do draw.io — que é o formato da maioria dos diagramas de
documentação, o do Kubernetes incluído — **não desenha texto com `<text>`**. Para
cada rótulo ele emite um `<switch>` com dois ramos: um `<foreignObject>` com HTML
e um `<image>` com um **PNG em base64 do rótulo rasterizado**.

Inline no HTML, o navegador usa o `foreignObject` e tudo parece bem. Dentro de
uma `<img src="…svg">` — o modo restrito do SVG — o `foreignObject` não
renderiza, e o navegador cai no PNG. Medido no diagrama de componentes do
Kubernetes:

| | antes | depois |
|---|---|---|
| Tamanho | **254 KB** (176 KB só de PNG em base64) | **80 KB** |
| Texto | rasterizado, borrado ao ampliar | vetor, nítido em qualquer zoom |
| Pintura | congelou o renderizador do Chrome ao capturar a tela | instantânea |

`tools/scripts/flatten-drawio-svg.py` converte os 14 `<switch>` em `<text>` de
verdade, usando a geometria do próprio `<image>` e os estilos do `<div>` interno.
A CC BY 4.0 permite adaptação e pede que a modificação seja indicada — o crédito
da figura diz de onde ela veio e sob que licença.

## Alternativas recusadas

**Só SVG redesenhado, sem imagem nenhuma.** Foi a regra até aqui. Recusada
porque tira do leitor o desenho que ele vai reencontrar em todo lugar, e porque
"nunca use imagem" é uma regra mais forte do que o problema exige.

**Embutir a imagem inline no HTML em vez de `<img>`.** Resolveria o
`foreignObject` e traria dois problemas piores: os hex do SVG de terceiro
reprovam a checagem 6 do `site-check.mjs`, e 254 KB de markup entrariam em toda
página que usasse a figura.

**Servir direto de `kubernetes.io`.** Zero bytes no repositório, e recusado: o
leitor passa a ser rastreado por um terceiro, a página quebra quando a URL mudar,
e o site deixa de poder ser publicado offline.

**Converter para PNG e pronto.** Resolve o `foreignObject` e joga fora o vetor —
pior em tela de alta densidade e pior no `git diff`, onde um PNG é um blob opaco.

## Consequências

**A favor:**

- O material didático pode usar o desenho canônico, explicado peça por peça.
- Procedência é obrigatória e checada no HTML gerado, não confiada à revisão.
- O script de achatamento resolve de uma vez um problema que vai reaparecer em
  todo diagrama de documentação exportado do draw.io.

**Contra, e assumido:**

- **A imagem de fora não segue o tema.** A placa branca fica visível no tema
  escuro. Quem quiser tema completo redesenha em SVG — e `redrawnFrom` existe
  exatamente para isso.
- **Peso.** 80 KB é muito mais que os ~4 KB de um diagrama escrito à mão. Vale a
  pena para um desenho canônico e não vale para um desenho comum.
- **`alt` não substitui a figura anotada.** Para quem usa leitor de tela, a lista
  numerada do slot `legend` é que carrega o conteúdo — por isso ela é prosa de
  verdade, e não rótulos soltos.
