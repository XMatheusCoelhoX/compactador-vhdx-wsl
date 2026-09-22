#requires -Version 5.1
<#
    Compactar-VHDX-WSL.ps1
    Automatiza a compactacao do(s) disco(s) virtual (.vhdx) das distros WSL instaladas.
    Funciona em qualquer PC: descobre o caminho do vhdx via registro (Lxss), sem caminho fixo.
#>

$Host.UI.RawUI.WindowTitle = "COMPACTADOR VHDX // WSL [PS1]"
# Stop-Service/Restart-Service emitem um Write-Progress nativo enquanto esperam
# o servico parar; em muitos consoles isso aparece como linhas repetidas de
# "AVISO: Aguardando...". Isso desliga soh essa barra nativa (nao afeta a
# barra de progresso propria do script, que usa Write-Host).
$ProgressPreference = "SilentlyContinue"

# Deteccao de suporte a ANSI true-color (Windows 10 1909+). Em versoes mais
# antigas do Windows a barra de progresso cai para uma cor solida via
# -ForegroundColor em vez de imprimir sequencias de escape cruas na tela.
$script:SupportsAnsi = [Environment]::OSVersion.Version.Major -ge 10 -and [Environment]::OSVersion.Version.Build -ge 15063

# ============================================================================
#  PAINEL VISUAL
# ============================================================================
$C = @{
    Accent  = "Cyan"
    Accent2 = "Magenta"
    Ok      = "Green"
    Warn    = "Yellow"
    Err     = "Red"
    Dim     = "DarkGray"
    Text    = "White"
}

function Write-Line($Text = "", $Color = $C.Text) { Write-Host $Text -ForegroundColor $Color }

function Draw-Banner {
    Clear-Host
    $w = 74
    $top = "╔" + ("═" * $w) + "╗"
    $bot = "╚" + ("═" * $w) + "╝"
    $mid = "║" + (" " * $w) + "║"
    Write-Line $top $C.Accent
    Write-Line $mid $C.Accent
    Write-Line ("║" + " COMPACTADOR DE DISCO VIRTUAL — WSL / VHDX".PadRight($w) + "║") $C.Accent2
    Write-Line ("║" + " diskpart · autodescoberta de distro · execucao automatizada".PadRight($w) + "║") $C.Dim
    Write-Line $mid $C.Accent
    Write-Line $bot $C.Accent
    Write-Line ""
}

$script:StepCount = 0
function Write-StepBanner($Title) {
    $script:StepCount++
    $label = "  [{0:D2}] {1}" -f $script:StepCount, $Title
    Write-Line ""
    Write-Line ("┌" + ("─" * 74) + "┐") $C.Accent
    Write-Line $label $C.Accent
    Write-Line ("└" + ("─" * 74) + "┘") $C.Accent
}

function Write-Info($msg)    { Write-Line ("   › " + $msg) $C.Text }
function Write-Ok($msg)      { Write-Line ("   ✔ " + $msg) $C.Ok }
function Write-Warn($msg)    { Write-Line ("   ⚠ " + $msg) $C.Warn }
function Write-ErrLine($msg) { Write-Line ("   ✖ " + $msg) $C.Err }

function Draw-ProgressBar {
    param([int]$Percent, [string]$Label = "")
    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $width = 40
    $filled = [int]([Math]::Round($width * ($Percent / 100)))
    $bar = ("█" * $filled) + ("░" * ($width - $filled))
    if ($script:SupportsAnsi) {
        $neon = "$([char]27)[38;2;57;255;20m"
        $reset = "$([char]27)[0m"
        Write-Host ("`r   {0}[{1}] {2,3}%  {3}{4}" -f $neon, $bar, $Percent, $Label, $reset) -NoNewline
    } else {
        Write-Host ("`r   [{0}] {1,3}%  {2}" -f $bar, $Percent, $Label) -ForegroundColor Green -NoNewline
    }
    if ($Percent -ge 100) { Write-Host "" }
}

function Show-Spinner {
    param([scriptblock]$Action, [string]$Label)
    $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $job = Start-Job -ScriptBlock $Action
    $i = 0
    while ($job.State -eq 'Running') {
        Write-Host ("`r   {0} {1}" -f $frames[$i % $frames.Length], $Label) -ForegroundColor $C.Accent -NoNewline
        Start-Sleep -Milliseconds 90
        $i++
    }
    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    Write-Host ("`r   ✔ {0}" -f $Label).PadRight(60) -ForegroundColor $C.Ok
    return $result
}

function Format-Bytes($bytes) {
    if ($bytes -ge 1GB) { return ("{0:N2} GB" -f ($bytes / 1GB)) }
    return ("{0:N1} MB" -f ($bytes / 1MB))
}

# ============================================================================
#  1. AUTOELEVACAO
# ============================================================================
Draw-Banner
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn "Privilegios de Administrador necessarios. Reiniciando elevado..."
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"
Write-Ok "Executando com privilegios de Administrador"

# ============================================================================
#  2. DESCOBERTA DE DISTROS WSL (qualquer PC/usuario, sem caminho fixo)
# ============================================================================
function Get-WslVhdxPaths {
    $found = New-Object System.Collections.Generic.List[string]

    $lxssRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"
    if (Test-Path $lxssRoot) {
        Get-ChildItem $lxssRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $basePath = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).BasePath
            if ($basePath) {
                $basePath = $basePath -replace '^\\\\\?\\', ''
                if (Test-Path $basePath) {
                    Get-ChildItem -Path $basePath -Filter "*.vhdx" -File -ErrorAction SilentlyContinue |
                        ForEach-Object { $found.Add($_.FullName) }
                }
            }
        }
    }

    $defaultWslDir = Join-Path $env:LOCALAPPDATA "wsl"
    if (Test-Path $defaultWslDir) {
        Get-ChildItem -Path $defaultWslDir -Filter "*.vhdx" -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $found.Add($_.FullName) }
    }

    return $found | Select-Object -Unique
}

# ============================================================================
#  3. ENCERRAR WSL
# ============================================================================
function Release-WslDiskHandles {
    # WSLService fica "Running" mesmo depois do wsl --shutdown e segura um
    # handle no vhdx (causa o erro "arquivo ja esta sendo usado"). O vds
    # (Virtual Disk Service) e quem o diskpart usa por baixo dos panos: se
    # uma tentativa anterior for interrompida no meio, ele fica com um
    # estado interno preso (causa o erro "nao pode ser executada enquanto
    # o disco virtual estiver sendo compactado"). Os dois precisam ser
    # liberados antes de cada tentativa.
    param([int]$WaitSeconds = 3)
    wsl --shutdown | Out-Null
    Start-Sleep -Seconds $WaitSeconds
    Get-Process -Name "vmmem", "vmmemWSL" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-Service -Name WSLService -Force -ErrorAction SilentlyContinue
    Restart-Service -Name vds -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Restore-WslService {
    Start-Service -Name WSLService -ErrorAction SilentlyContinue
}

function Invoke-DiskpartCleanup {
    # Se uma tentativa anterior falhou no meio do script, o diskpart aborta antes
    # do "detach vdisk", deixando o disco anexado. Isso faz a proxima tentativa
    # falhar com "nao pode ser executada enquanto o disco virtual estiver sendo
    # compactado". Este cleanup forca o detach antes de tentar de novo.
    param([string]$VhdxPath)
    $cleanupScript = @"
select vdisk file="$VhdxPath"
detach vdisk
exit
"@
    $f = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $f -Value $cleanupScript -Encoding ASCII
    diskpart /s $f *> $null
    Remove-Item $f -Force -ErrorAction SilentlyContinue
}

Write-StepBanner "Encerrando o WSL e liberando os discos virtuais"
Write-Info "Executando 'wsl --shutdown'..."
Release-WslDiskHandles -WaitSeconds 5
Write-Ok "WSL encerrado e handles de arquivo liberados"

# ============================================================================
#  4. LOCALIZAR DISCOS
# ============================================================================
Write-StepBanner "Procurando arquivos .vhdx de distros WSL"
$vhdxPaths = Get-WslVhdxPaths

if (-not $vhdxPaths -or $vhdxPaths.Count -eq 0) {
    Write-ErrLine "Nenhum arquivo .vhdx de WSL foi encontrado neste computador."
    Restore-WslService
    Write-Line ""
    Read-Host "Pressione Enter para sair"
    exit 1
}

Write-Ok ("{0} disco(s) encontrado(s):" -f $vhdxPaths.Count)
$vhdxPaths | ForEach-Object { Write-Info $_ }

# ============================================================================
#  5. COMPACTACAO (progresso real lido diretamente do diskpart)
# ============================================================================
$results = New-Object System.Collections.Generic.List[object]

foreach ($vhdxPath in $vhdxPaths) {
    Write-StepBanner ("Compactando: " + (Split-Path $vhdxPath -Leaf))
    Write-Info $vhdxPath

    $sizeBefore = (Get-Item -LiteralPath $vhdxPath -ErrorAction Stop).Length
    Write-Info ("Tamanho atual: " + (Format-Bytes $sizeBefore))
    Invoke-DiskpartCleanup -VhdxPath $vhdxPath

    $diskpartScript = @"
select vdisk file="$vhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
    $tempScriptFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tempScriptFile -Value $diskpartScript -Encoding ASCII

    $maxTentativas = 3
    $exitCode = -1
    $falhouComErro = $false

    try {
        for ($tentativa = 1; $tentativa -le $maxTentativas; $tentativa++) {
            if ($tentativa -gt 1) {
                Write-Warn ("Tentativa {0}/{1} falhou. Liberando o disco e tentando novamente..." -f ($tentativa - 1), $maxTentativas)
                Release-WslDiskHandles -WaitSeconds (3 * $tentativa)
                Invoke-DiskpartCleanup -VhdxPath $vhdxPath
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "diskpart.exe"
            $psi.Arguments = "/s `"$tempScriptFile`""
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            $outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            $eventJob = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
                if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
            } -MessageData $outputQueue

            $falhouComErro = $false
            $travou = $false
            [void]$proc.Start()
            $proc.BeginOutputReadLine()

            # Watchdog independente: roda num processo separado, fora do loop
            # principal. Se o loop de leitura ficar preso por qualquer motivo
            # (ex.: o proprio Windows/vds emperrado impedindo o polling de
            # reagir), este processo mata o diskpart de fora mesmo assim.
            $killerPsi = New-Object System.Diagnostics.ProcessStartInfo
            $killerPsi.FileName = "powershell.exe"
            # Este killer NAO deve usar o mesmo prazo do watchdog de atividade
            # (5 min): uma compactacao grande pode legitimamente ficar mais
            # tempo reportando o mesmo percentual (ainda esta vivo, so lento).
            # Este e um teto absoluto de ultimo recurso, bem mais generoso,
            # para o caso do watchdog principal nao conseguir reagir.
            $killerPsi.Arguments = "-NoProfile -WindowStyle Hidden -Command `"Start-Sleep -Seconds 1800; try { Stop-Process -Id $($proc.Id) -Force -ErrorAction SilentlyContinue } catch {}`""
            $killerPsi.CreateNoWindow = $true
            $killerPsi.UseShellExecute = $false
            $killerProc = [System.Diagnostics.Process]::Start($killerPsi)

            Draw-ProgressBar -Percent 0 -Label "iniciando diskpart..."
            $lastActivity = Get-Date
            $hangLimit = [TimeSpan]::FromMinutes(5)
            $line = $null
            while (-not $proc.HasExited -or $outputQueue.Count -gt 0) {
                if ($outputQueue.TryDequeue([ref]$line)) {
                    $lastActivity = Get-Date
                    if ($line -match '(\d+)\s*(?:percent|por\s*cento)') {
                        Draw-ProgressBar -Percent ([int]$matches[1]) -Label "compactando..."
                    } elseif ($line.Trim()) {
                        Write-Host ""
                        Write-Info $line.Trim()
                        if ($line -match '(?i)erro|error') { $falhouComErro = $true }
                    }
                } else {
                    Start-Sleep -Milliseconds 150
                    if (-not $proc.HasExited -and ((Get-Date) - $lastActivity) -gt $hangLimit) {
                        Write-Host ""
                        Write-ErrLine "diskpart sem atividade ha 5 minutos - considerado travado. Encerrando o processo..."
                        try { $proc.Kill() } catch {}
                        $falhouComErro = $true
                        $travou = $true
                        break
                    }
                }
            }
            $proc.WaitForExit(5000) | Out-Null
            try { if (-not $killerProc.HasExited) { $killerProc.Kill() } } catch {}
            if (-not $proc.HasExited) {
                # ultima rede de seguranca: nem o loop principal nem o watchdog
                # independente conseguiram terminar o processo a tempo
                try { $proc.Kill() } catch {}
                $travou = $true
                $falhouComErro = $true
                Start-Sleep -Milliseconds 500
            }
            Draw-ProgressBar -Percent 100 -Label "concluido"
            $exitCode = if ($travou) { -1 } else { $proc.ExitCode }
            Unregister-Event -SourceIdentifier $eventJob.Name -ErrorAction SilentlyContinue
            Remove-Job -Job $eventJob -Force -ErrorAction SilentlyContinue

            if ($exitCode -eq 0 -and -not $falhouComErro) { break }
        }
    }
    finally {
        Remove-Item $tempScriptFile -Force -ErrorAction SilentlyContinue
    }

    $sizeAfter = (Get-Item -LiteralPath $vhdxPath).Length
    $savedBytes = $sizeBefore - $sizeAfter
    $results.Add([pscustomobject]@{
        Arquivo = (Split-Path $vhdxPath -Leaf)
        Antes   = $sizeBefore
        Depois  = $sizeAfter
        Salvo   = $savedBytes
    })

    if ($exitCode -ne 0 -or $falhouComErro) {
        Write-ErrLine "O diskpart nao concluiu a compactacao (o disco pode estar em uso por outro processo)."
        Write-Info "Feche o Docker Desktop / outras VMs, aguarde alguns segundos e rode o script novamente."
    } elseif ($savedBytes -gt 0) {
        Write-Ok ("Economizado: " + (Format-Bytes $savedBytes))
    } else {
        Write-Info "Nenhum espaco adicional foi recuperado (disco ja estava compacto)."
    }
}

Restore-WslService

# ============================================================================
#  6. RESUMO FINAL
# ============================================================================
Write-StepBanner "Resumo da compactacao"
$totalSaved = ($results | Measure-Object -Property Salvo -Sum).Sum
foreach ($r in $results) {
    Write-Line ("   {0,-28} {1,10} -> {2,-10}  ({3})" -f $r.Arquivo, (Format-Bytes $r.Antes), (Format-Bytes $r.Depois), (Format-Bytes $r.Salvo)) $C.Text
}
Write-Line ""
Write-Ok ("Espaco total recuperado: " + (Format-Bytes $totalSaved))
Write-Line ""
Write-Line ("═" * 74) $C.Accent
Read-Host "Pressione Enter para sair"
