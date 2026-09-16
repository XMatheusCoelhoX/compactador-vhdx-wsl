<!--
  ATENÇÃO: este documento e o projeto associado foram criados por Matheus Coelho.
  Qualquer cópia, redistribuição, fork ou reuso deste material — total ou parcial —
  deve manter esta atribuição de autoria intacta e visível.
-->

# ✅ Checklist Técnico — Compactador de Disco Virtual WSL/VHDX

**Criado por: Matheus Coelho**

Checklist completo de tudo que o projeto implementa, cobre e garante, nas duas versões (`Compactar-VHDX-WSL.ps1` e `Compactar-VHDX-WSL.bat`), que são funcionalmente equivalentes.

---

## 1. Elevação e ambiente

- [x] Detecta se já está rodando como Administrador antes de fazer qualquer coisa.
- [x] Se não estiver, se relança sozinho elevado (`-Verb RunAs`) e encerra a instância não elevada.
- [x] Define título de janela identificando qual versão está rodando (`[PS1]` / `[BAT]`).
- [x] Detecta a build do Windows via Registro (`CurrentBuildNumber`) e desativa cores ANSI em builds anteriores à 10586 (Windows 10 1511), evitando texto de escape quebrado em sistemas antigos.

## 2. Descoberta automática de disco(s) — sem caminho fixo

- [x] Lê `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` e itera **todas** as subchaves (uma por distro instalada).
- [x] Extrai o valor `BasePath` de cada subchave e remove o prefixo `\\?\`.
- [x] Procura arquivos `*.vhdx` dentro de cada `BasePath` encontrado.
- [x] Fallback adicional: varre recursivamente `%LOCALAPPDATA%\wsl` em busca de qualquer `*.vhdx` não capturado pelo passo anterior.
- [x] Remove duplicados entre as duas fontes de busca.
- [x] Funciona com **múltiplas distros instaladas simultaneamente** — compacta uma por uma, em sequência.
- [x] Se nenhum disco for encontrado, informa claramente e encerra sem erro genérico.

## 3. Liberação do disco (causas reais de falha identificadas em depuração)

- [x] Executa `wsl --shutdown` antes de qualquer tentativa.
- [x] Aguarda um tempo configurável (5s na primeira tentativa, escalando nas seguintes) para o Windows liberar handles.
- [x] Mata processos residuais `vmmem` / `vmmemWSL` se ainda existirem.
- [x] **Para o serviço `WSLService`** — identificado como responsável pelo erro "arquivo já está sendo usado por outro processo", mesmo com o WSL já desligado.
- [x] **Reinicia o serviço `vds` (Virtual Disk Service)** — identificado como responsável pelo erro "não pode ser executada enquanto o disco virtual estiver sendo compactado", que ocorre quando uma tentativa anterior deixa esse serviço com estado interno preso.
- [x] Repete essa liberação **antes de cada nova tentativa**, não só uma vez no início.

## 4. Limpeza defensiva de estado anexado (attach/detach)

- [x] Gera um mini-script de `diskpart` só com `select vdisk` + `detach vdisk` e executa antes de cada tentativa.
- [x] Justificativa técnica: o `diskpart /s` aborta o restante do script assim que um comando falha — se `attach` ou `compact` falhar, o `detach vdisk` final nunca roda, deixando o disco anexado e quebrando a tentativa seguinte. Esse cleanup evita esse acúmulo de estado.

## 5. Execução do `diskpart` e feedback em tempo real

- [x] Gera o script de `diskpart` (`select` → `attach vdisk readonly` → `compact vdisk` → `detach vdisk` → `exit`) em um arquivo temporário.
- [x] Executa com saída padrão redirecionada e **lida de forma assíncrona/streaming**, não só capturada no final.
- [x] Reconhece linhas de progresso em **inglês** (`"NN percent completed"`) **e português** (`"NN por cento concluído"`).
- [x] Atualiza uma barra de progresso visual em uma única linha (sem gerar quebras de linha a cada atualização de percentual).
- [x] Exibe todas as demais linhas de saída do `diskpart` (transparência total do processamento, não só o percentual).
- [x] Detecta a palavra "erro"/"error" em qualquer linha e marca a tentativa como falha, mesmo que o código de saída do processo seja 0.
- [x] Verifica também o código de saída (`ExitCode`) do processo `diskpart.exe`.

## 6. Watchdog anti-travamento

- [x] Monitora o tempo desde a última linha de saída recebida do `diskpart`.
- [x] Se passarem **5 minutos sem nenhuma atividade**, mata o processo (`Kill()`) automaticamente.
- [x] Trata esse caso como falha de tentativa (entra no fluxo de retry normalmente), em vez de travar o script indefinidamente.
- [x] Implementado via leitura assíncrona de saída (`OutputDataReceived` + fila concorrente) tanto no `.ps1` quanto no helper PowerShell gerado pelo `.bat`.

## 7. Retry automático

- [x] Até **3 tentativas** por disco.
- [x] Libera o disco (seção 3) e limpa o attach (seção 4) entre tentativas.
- [x] Se todas as tentativas falharem, informa claramente o motivo provável e sugere fechar outros programas que usem WSL2/Hyper-V (Docker Desktop, outras VMs).

## 8. Precisão numérica

- [x] No `.bat`: usa um helper em PowerShell gerado dinamicamente para todo cálculo de tamanho de arquivo, evitando o limite de inteiro de 32 bits do `set /a` nativo do CMD (que quebraria em arquivos maiores que ~2.1 GB).
- [x] No `.ps1`: usa tipos nativos `[long]`/`Int64` do .NET, sem limitação prática de tamanho.
- [x] Formatação de tamanho em MB ou GB conforme a magnitude do valor.

## 9. Restauração de estado (nenhum efeito colateral permanente)

- [x] Restaura o serviço `WSLService` ao final da execução normal.
- [x] Restaura o serviço `WSLService` também no caminho de saída antecipada (nenhum disco encontrado) — **não deixa o serviço parado se o script terminar mais cedo**.
- [x] Remove todos os arquivos temporários gerados (`diskpart` scripts, helpers PowerShell, listas de descoberta, resultados) em todos os caminhos de saída.

## 10. Painel visual

- [x] Banner de abertura com identificação do projeto.
- [x] Cada etapa numerada em um card visual delimitado.
- [x] Cores semânticas: informação, sucesso, aviso e erro em cores distintas.
- [x] Barra de progresso em verde neon (RGB verdadeiro via ANSI truecolor, com fallback de cor sólida em sistemas sem suporte).
- [x] Supressão de saída nativa ruidosa do PowerShell (`Write-Progress` do `Restart-Service`) que apareceria como linhas repetidas de "Aguardando...".
- [x] Resumo final em tabela: nome do arquivo, tamanho antes, tamanho depois, espaço economizado por disco e total geral.

## 11. Robustez / tratamento de erro

- [x] Todas as chamadas a serviços do Windows usam tratamento de erro silencioso (não interrompem o script se um serviço não existir ou já estiver no estado esperado).
- [x] Leitura de arquivos com `-LiteralPath` (PS1) para lidar corretamente com caminhos contendo caracteres especiais como `{` e `}` (comuns em GUIDs de distros WSL).
- [x] Arquivos temporários usam nomes com sufixo aleatório (`%RANDOM%` / `GetTempFileName()`) para evitar colisão entre execuções simultâneas.

## 12. Limitações conhecidas (documentadas, não escondidas)

- [ ] Se o subsistema `vds` do Windows ficar genuinamente "emperrado" no nível do driver/kernel (situação observada após múltiplas tentativas de compactação forçadas seguidas no mesmo disco durante testes), nenhum comando de software resolve — é necessário reiniciar o Windows. O script não tenta forçar um reboot automaticamente (isso seria uma ação disruptiva demais para ser automática).
- [ ] O `diskpart compact` só recupera espaço que o Linux já marcou como livre via TRIM/discard. Se o filesystem `ext4` dentro da distro nunca rodou `fstrim`, o disco pode não encolher mesmo sem erros — rodar `sudo fstrim -av` dentro do WSL antes de compactar maximiza o resultado.
- [ ] Cores ANSI truecolor (verde neon) precisam de Windows 10 1909+ ou Windows Terminal para aparecer exatamente na cor especificada; em versões mais antigas com suporte básico a VT, cai para uma cor sólida de fallback.

---

## Autoria

**Criado por: Matheus Coelho**

Esta atribuição é parte integrante da documentação técnica deste projeto e deve ser preservada em qualquer cópia, fork ou redistribuição.

<!-- Criado por: Matheus Coelho — controle de autoria do projeto. -->
