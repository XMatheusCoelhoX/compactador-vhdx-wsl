<!--
  ATENÇÃO: este documento e o projeto associado foram criados por Matheus Coelho.
  Qualquer cópia, redistribuição, fork ou reuso deste material — total ou parcial —
  deve manter esta atribuição de autoria intacta e visível. Removê-la não retira
  a autoria original, apenas torna a cópia não íntegra em relação ao projeto fonte.
-->

# 🗜️ Compactador de Disco Virtual WSL/VHDX

**Criado por: Matheus Coelho**

> Automatiza por completo a compactação do arquivo `ext4.vhdx` de qualquer distro WSL2 instalada, sem precisar descobrir o caminho manualmente, sem editar comandos, e resolvendo sozinho os travamentos mais comuns do Windows nesse processo.

---

## 1. O problema que este projeto resolve

O WSL2 guarda o sistema de arquivos Linux dentro de um disco virtual dinâmico (`ext4.vhdx`). Esse arquivo **só cresce** com o uso normal — mesmo depois de você apagar arquivos grandes dentro do Linux, o `.vhdx` no Windows não encolhe sozinho. Com o tempo ele pode ocupar dezenas de GB de espaço "fantasma" no disco.

A forma oficial de resolver isso é um procedimento manual no `diskpart`:

```
diskpart
select vdisk file="C:\Users\<usuario>\AppData\Local\wsl\{GUID}\ext4.vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
exit
```

O problema é que:
- O caminho do arquivo tem um **GUID único por instalação** — muda de PC para PC.
- O processo falha silenciosamente ou trava se o Windows ainda tiver qualquer handle aberto no arquivo.
- Não existe feedback visual do progresso real.

Este projeto automatiza tudo isso, com descoberta automática do caminho, tratamento dos erros mais comuns do Windows e um painel visual mostrando cada etapa.

---

## 2. O que tem na pasta

| Arquivo | Descrição |
|---|---|
| `Compactar-VHDX-WSL.ps1` | Versão PowerShell (painel visual mais rico, barra de progresso animada). |
| `Compactar-VHDX-WSL.bat` | Versão Batch/CMD (mesma lógica, para quem prefere não lidar com política de execução do PowerShell). |
| `LEIA-ME.md` | Este documento. |
| `CHECKLIST.md` | Checklist técnico detalhado de tudo que o projeto cobre. |

As duas versões são **funcionalmente equivalentes** — mesma lógica de descoberta, mesmos serviços tratados, mesmo retry, mesmo watchdog. A diferença é só o motor de execução (PowerShell vs. CMD puro) e o refinamento visual.

---

## 3. Como usar

1. Dê duplo clique em `Compactar-VHDX-WSL.ps1` **ou** `Compactar-VHDX-WSL.bat` (qualquer um dos dois).
2. Aceite o prompt de UAC (Controle de Conta de Usuário) — é necessário rodar como Administrador para o `diskpart` funcionar.
3. Acompanhe o painel: ele mostra cada etapa numerada, o progresso real do `diskpart`, e um resumo final com o espaço recuperado.
4. No final, pressione Enter (PS1) ou qualquer tecla (BAT) para fechar.

Não é preciso informar caminho nenhum — o script descobre sozinho **todas** as distros WSL instaladas no PC e compacta uma por uma.

---

## 4. Como funciona por dentro (arquitetura)

### 4.1 Autoelevação
O script detecta se já está rodando como Administrador (`net session` no BAT, `WindowsPrincipal` no PS1). Se não estiver, ele se relança sozinho com `-Verb RunAs`, disparando o prompt de UAC.

### 4.2 Descoberta automática do(s) disco(s)
Em vez de um caminho fixo, o script lê o Registro do Windows:

```
HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Lxss\{GUID-da-distro}
    BasePath = \\?\C:\Users\<usuario>\AppData\Local\wsl\{GUID}
```

Cada subchave dentro de `Lxss` representa uma distro instalada. O script lê o `BasePath` de **cada uma** e procura arquivos `*.vhdx` dentro dela — funcionando para qualquer distro (Ubuntu, Debian, etc.), qualquer usuário e qualquer PC, com fallback adicional varrendo `%LOCALAPPDATA%\wsl`.

### 4.3 Liberação do disco antes de compactar
Esta foi a parte mais delicada do projeto, descoberta através de depuração extensiva num caso real. Três coisas precisam ser liberadas, nesta ordem, ou o `diskpart` falha:

1. **`wsl --shutdown`** — encerra a distro em execução.
2. **Serviço `WSLService`** — fica `Running` mesmo depois do `wsl --shutdown` e mantém um handle aberto no `.vhdx`. Isso causa o erro *"O arquivo já está sendo usado por outro processo"*. O script para esse serviço antes de compactar e **restaura ele no final** (ou em qualquer caminho de saída antecipada).
3. **Serviço `vds` (Virtual Disk Service)** — é o serviço que o `diskpart` usa internamente. Se uma tentativa anterior for interrompida no meio (erro, travamento, fechamento forçado da janela), ele fica com um estado interno "preso", causando o erro *"A operação solicitada não pode ser executada enquanto o disco virtual estiver sendo compactado"* mesmo em uma tentativa nova e limpa. O script reinicia esse serviço antes de cada tentativa.

### 4.4 Limpeza defensiva (detach)
Se uma tentativa anterior falhar no meio do script do `diskpart`, ele **aborta o restante do script automaticamente** — inclusive o `detach vdisk` final — deixando o disco "anexado". Antes de cada tentativa, o script roda um mini-script de limpeza (`select vdisk` + `detach vdisk`) para garantir que o disco não fique preso de uma tentativa anterior.

### 4.5 Execução do `diskpart` com progresso em tempo real
O `diskpart` é executado com a saída padrão redirecionada e lida linha a linha, **enquanto está rodando** (não só no final). Cada linha é analisada:
- Se contém um percentual (`"NN percent completed"` em inglês **ou** `"NN por cento concluído"` em português), atualiza uma barra de progresso visual em uma única linha (sem gerar quebras de linha novas a cada atualização).
- Se contém a palavra "erro"/"error", marca a tentativa como falha.
- Qualquer outra linha é exibida como informação, para transparência total do que está acontecendo.

### 4.6 Watchdog anti-travamento (duas camadas)
Se o `diskpart` ficar **5 minutos sem imprimir nada** (nem progresso, nem erro), ele é considerado travado e é morto automaticamente, contando como uma tentativa falha para o retry — em vez de deixar o script parado para sempre.

Isso é feito em **duas camadas independentes**, porque em depuração real a primeira camada, por si só, não foi suficiente:

1. **Camada interna**: o próprio loop que lê a saída do `diskpart` mede o tempo desde a última linha recebida e mata o processo se passar do limite.
2. **Camada externa**: em paralelo, um segundo processo `powershell.exe` completamente separado é lançado junto com o `diskpart`. Ele só dorme pelo tempo limite e mata o processo **por PID, de fora** — sem depender do mesmo loop de leitura, que em um caso real ficou preso por mais de 11 minutos sem a camada interna reagir (a causa exata desse comportamento não foi totalmente isolada, possivelmente ligada ao mesmo estado do `vds` afetando o próprio mecanismo de leitura assíncrona do PowerShell).

Com as duas camadas, mesmo que uma falhe, a outra garante que o `diskpart` não fique rodando indefinidamente.

### 4.7 Retry automático
Cada disco tem até **3 tentativas**. Entre uma tentativa e outra, o script libera o disco de novo (passo 4.3) antes de tentar.

### 4.8 Cálculo de tamanho sem estouro de inteiro
O `.bat` usa um pequeno helper em PowerShell gerado dinamicamente (arquivo temporário) para calcular os tamanhos antes/depois. Isso existe porque o comando nativo `set /a` do CMD usa inteiros de 32 bits (limite ~2.1 GB) — insuficiente para arquivos `.vhdx` de dezenas de GB, que facilmente estourariam esse limite e dariam resultados errados.

### 4.9 Compatibilidade com versões antigas do Windows
Antes de usar cores ANSI (sequências de escape para cores vibrantes no console), o script verifica a build do Windows via Registro. Em builds anteriores à 10586 (Windows 10 versão 1511), que não suportam essas sequências nativamente, as cores são desativadas para não exibir texto de escape quebrado na tela.

### 4.10 Resumo final
Ao terminar, mostra uma tabela com tamanho antes/depois de cada disco e o espaço total recuperado.

---

## 5. Segurança dos seus dados

Este processo **não apaga, não move e não altera dados dentro do Linux**. O `diskpart compact` apenas reorganiza os blocos livres do arquivo de disco virtual no nível do Windows — o mesmo tipo de operação que um "desfragmentador"/"otimizador" de disco faz. A pior consequência possível de uma falha é a compactação **não acontecer** (o disco continua do tamanho que estava); não há risco de perda de arquivos dentro da distro.

---

## 6. Solução de problemas

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| "Nenhum arquivo .vhdx encontrado" | WSL não está instalado, ou nenhuma distro foi inicializada ainda | Rode `wsl --install` ou inicie a distro pelo menos uma vez |
| Erro "arquivo já está sendo usado" mesmo após todas as tentativas | Outro programa (Docker Desktop, outra VM Hyper-V) está usando o disco | Feche esses programas e rode de novo |
| "diskpart sem atividade há 5 minutos" | O subsistema de disco virtual do Windows (`vds`) ficou num estado preso, geralmente após vários testes/tentativas seguidas no mesmo disco | **Reinicie o Windows.** Isso limpa o estado interno do `vds` que nenhum comando consegue limpar sozinho |
| A janela fica parada logo em `Executando 'wsl --shutdown'...`, sem nunca chegar a mostrar o `diskpart` | O subsistema WSL/Hyper-V do Windows como um todo travou — não é mais só o `vds`, é o próprio `wsl.exe`. Isso foi observado em depuração real após dezenas de tentativas forçadas seguidas no mesmo PC | **Reinicie o Windows.** Nenhum watchdog de aplicação protege contra um comando do próprio Windows travando; isso é o sinal mais claro de que só o reboot resolve |
| Cores aparecem como texto estranho (`←[96m` etc.) | Windows muito antigo sem suporte a ANSI | Já tratado automaticamente a partir da versão atual do script — atualize os arquivos |

---

## 7. Requisitos

- Windows 10 (qualquer build) ou Windows 11.
- WSL2 instalado com pelo menos uma distro.
- Privilégios de Administrador (o script pede sozinho).
- PowerShell 5.1 (já vem com o Windows) para a versão `.ps1`.

---

## 8. Autoria e licença de uso

**Este projeto foi criado por Matheus Coelho.**

Esta atribuição faz parte integrante do projeto e deve ser mantida em qualquer cópia, fork, redistribuição ou uso derivado deste material, no todo ou em parte. Isso vale tanto para este documento quanto para os scripts `.ps1` e `.bat` que o acompanham.

---

<!-- Criado por: Matheus Coelho — esta linha faz parte do controle de autoria do projeto. -->
