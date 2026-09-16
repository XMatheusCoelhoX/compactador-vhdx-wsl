@echo off
setlocal EnableDelayedExpansion
title COMPACTADOR VHDX // WSL [BAT]
color 0A

rem ---- cores ANSI (so em Windows 10 1511+/11, que tem suporte nativo a VT;
rem      em versoes mais antigas os codigos ficam vazios para nao aparecer
rem      texto de escape quebrado na tela) ----
set "ANSI_OK=0"
for /f "tokens=3" %%b in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| findstr /i "CurrentBuildNumber"') do (
    if %%b GEQ 10586 set "ANSI_OK=1"
)
if "%ANSI_OK%"=="1" (
    for /F %%a in ('echo prompt $E^|cmd') do set "ESC=%%a"
    set "CY=!ESC![96m"
    set "MG=!ESC![95m"
    set "GR=!ESC![92m"
    set "YL=!ESC![93m"
    set "RD=!ESC![91m"
    set "DM=!ESC![90m"
    set "WT=!ESC![97m"
    set "RS=!ESC![0m"
) else (
    set "CY=" & set "MG=" & set "GR=" & set "YL=" & set "RD=" & set "DM=" & set "WT=" & set "RS="
)

set "STEP=0"

rem ============================================================
rem  1. AUTOELEVACAO
rem ============================================================
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    call :Banner
    echo    %YL%[AVISO] Privilegios de Administrador necessarios. Reiniciando elevado...%RS%
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

call :Banner
echo    %GR%[OK] Executando com privilegios de Administrador%RS%

rem ============================================================
rem  2. GERAR HELPER DE CALCULO DE TAMANHO (evita estouro de
rem     inteiro de 32 bits do "set /a" em discos grandes)
rem ============================================================
set "HELPER=%TEMP%\wsl_size_helper_%RANDOM%.ps1"
if exist "%HELPER%" del "%HELPER%" >nul 2>&1
echo param( >"%HELPER%"
echo     [string]$Path, >>"%HELPER%"
echo     [long]$Before = -1, >>"%HELPER%"
echo     [switch]$Summarize, >>"%HELPER%"
echo     [string]$ResultsFile >>"%HELPER%"
echo ) >>"%HELPER%"
echo function Format-Size([long]$bytes) { >>"%HELPER%"
echo     if ([math]::Abs($bytes) -ge 1GB) { return ("{0:N2} GB" -f ($bytes / 1GB)) } >>"%HELPER%"
echo     return ("{0:N1} MB" -f ($bytes / 1MB)) >>"%HELPER%"
echo } >>"%HELPER%"
echo if ($Summarize) { >>"%HELPER%"
echo     $lines = Get-Content -LiteralPath $ResultsFile >>"%HELPER%"
echo     $total = 0 >>"%HELPER%"
echo     foreach ($line in $lines) { >>"%HELPER%"
echo         if ($line.Trim() -eq "") { continue } >>"%HELPER%"
echo         $p = $line.Split("|") >>"%HELPER%"
echo         $nome = Split-Path $p[0] -Leaf >>"%HELPER%"
echo         $antes = [int64]$p[1] >>"%HELPER%"
echo         $depois = [int64]$p[2] >>"%HELPER%"
echo         $saved = $antes - $depois >>"%HELPER%"
echo         $total = $total + $saved >>"%HELPER%"
echo         $texto = "{0,-30} {1,12} para {2,-12} (economizou {3})" -f $nome, (Format-Size $antes), (Format-Size $depois), (Format-Size $saved) >>"%HELPER%"
echo         Write-Output $texto >>"%HELPER%"
echo     } >>"%HELPER%"
echo     Write-Output "" >>"%HELPER%"
echo     Write-Output ("Espaco total recuperado: " + (Format-Size $total)) >>"%HELPER%"
echo     exit 0 >>"%HELPER%"
echo } >>"%HELPER%"
echo $len = (Get-Item -LiteralPath $Path).Length >>"%HELPER%"
echo if ($Before -ge 0) { >>"%HELPER%"
echo     $saved = $Before - $len >>"%HELPER%"
echo     Write-Output ("$len|" + (Format-Size $len) + "|" + (Format-Size $saved)) >>"%HELPER%"
echo } else { >>"%HELPER%"
echo     Write-Output ("$len|" + (Format-Size $len)) >>"%HELPER%"
echo } >>"%HELPER%"

rem ============================================================
rem  2b. GERAR HELPER QUE RODA O DISKPART COM WATCHDOG (mata o
rem      processo se ele ficar mais de N minutos sem imprimir nada,
rem      em vez de travar o script para sempre)
rem ============================================================
set "DPHELPER=%TEMP%\wsl_diskpart_runner_%RANDOM%.ps1"
if exist "%DPHELPER%" del "%DPHELPER%" >nul 2>&1
echo param([string]$Script, [int]$TimeoutMin = 5) >"%DPHELPER%"
echo $psi = New-Object System.Diagnostics.ProcessStartInfo >>"%DPHELPER%"
echo $psi.FileName = 'diskpart.exe' >>"%DPHELPER%"
echo $psi.Arguments = '/s "' + $Script + '"' >>"%DPHELPER%"
echo $psi.RedirectStandardOutput = $true >>"%DPHELPER%"
echo $psi.UseShellExecute = $false >>"%DPHELPER%"
echo $psi.CreateNoWindow = $true >>"%DPHELPER%"
echo $proc = New-Object System.Diagnostics.Process >>"%DPHELPER%"
echo $proc.StartInfo = $psi >>"%DPHELPER%"
echo $q = [System.Collections.Concurrent.ConcurrentQueue[string]]::new() >>"%DPHELPER%"
echo $job = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action { if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) } } -MessageData $q >>"%DPHELPER%"
echo [void]$proc.Start() >>"%DPHELPER%"
echo $proc.BeginOutputReadLine() >>"%DPHELPER%"
echo $last = Get-Date >>"%DPHELPER%"
echo $limit = New-TimeSpan -Minutes $TimeoutMin >>"%DPHELPER%"
echo $hang = $false >>"%DPHELPER%"
echo $line = $null >>"%DPHELPER%"
echo while ((-not $proc.HasExited) -or ($q.Count -gt 0)) { >>"%DPHELPER%"
echo     if ($q.TryDequeue([ref]$line)) { >>"%DPHELPER%"
echo         $last = Get-Date >>"%DPHELPER%"
echo         Write-Output $line >>"%DPHELPER%"
echo     } else { >>"%DPHELPER%"
echo         Start-Sleep -Milliseconds 150 >>"%DPHELPER%"
echo         if ((-not $proc.HasExited) -and (((Get-Date) - $last) -gt $limit)) { >>"%DPHELPER%"
echo             Write-Output 'HANGED_TIMEOUT' >>"%DPHELPER%"
echo             try { $proc.Kill() } catch {} >>"%DPHELPER%"
echo             $hang = $true >>"%DPHELPER%"
echo             break >>"%DPHELPER%"
echo         } >>"%DPHELPER%"
echo     } >>"%DPHELPER%"
echo } >>"%DPHELPER%"
echo $proc.WaitForExit(5000) ^| Out-Null >>"%DPHELPER%"
echo Unregister-Event -SourceIdentifier $job.Name -ErrorAction SilentlyContinue >>"%DPHELPER%"
echo Remove-Job -Job $job -Force -ErrorAction SilentlyContinue >>"%DPHELPER%"
echo if ($hang) { Write-Output 'EXITCODE:-1' } else { Write-Output ('EXITCODE:' + $proc.ExitCode) } >>"%DPHELPER%"

rem ============================================================
rem  3. ENCERRAR O WSL
rem ============================================================
call :StepBanner "Encerrando o WSL e liberando os discos virtuais"
echo    %CY%^>%RS% Executando 'wsl --shutdown'...
call :ReleaseWslDisk 5
echo    %GR%[OK] WSL encerrado e handles de arquivo liberados%RS%

rem ============================================================
rem  4. LOCALIZAR OS DISCOS (.vhdx) DE QUALQUER DISTRO, EM QUALQUER PC
rem ============================================================
call :StepBanner "Procurando arquivos .vhdx de distros WSL"

set "RAWLIST=%TEMP%\wsl_vhdx_raw_%RANDOM%.txt"
set "SORTED=%TEMP%\wsl_vhdx_sorted_%RANDOM%.txt"
type nul > "%RAWLIST%"

set "LXROOT=HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss"
for /f "skip=1 tokens=*" %%K in ('reg query "%LXROOT%" 2^>nul') do (
    set "SUBKEY=%%K"
    set "BP="
    for /f "tokens=2,*" %%A in ('reg query "!SUBKEY!" /v BasePath 2^>nul ^| findstr /i "BasePath"') do set "BP=%%B"
    if defined BP (
        set "BP=!BP:\\?\=!"
        if exist "!BP!" (
            for /f "delims=" %%F in ('dir /s /b /a-d "!BP!\*.vhdx" 2^>nul') do echo %%F>>"%RAWLIST%"
        )
    )
)

if exist "%LOCALAPPDATA%\wsl" (
    for /f "delims=" %%F in ('dir /s /b /a-d "%LOCALAPPDATA%\wsl\*.vhdx" 2^>nul') do echo %%F>>"%RAWLIST%"
)

rem ---- remover duplicados (sort + comparacao com a linha anterior) ----
sort "%RAWLIST%" > "%SORTED%.s" 2>nul
set "PREV="
type nul > "%SORTED%"
for /f "usebackq delims=" %%F in ("%SORTED%.s") do (
    if /i not "%%F"=="!PREV!" (
        echo %%F>>"%SORTED%"
        set "PREV=%%F"
    )
)
del "%RAWLIST%" >nul 2>&1
del "%SORTED%.s" >nul 2>&1

set /a COUNT=0
for /f "usebackq delims=" %%F in ("%SORTED%") do (
    if not "%%F"=="" set /a COUNT+=1
)

if !COUNT! EQU 0 (
    echo    %RD%[ERRO] Nenhum arquivo .vhdx de WSL foi encontrado neste computador.%RS%
    net start WSLService >nul 2>&1
    echo.
    del "%SORTED%" >nul 2>&1
    del "%HELPER%" >nul 2>&1
    del "%DPHELPER%" >nul 2>&1
    pause
    exit /b 1
)

echo    %GR%[OK] !COUNT! disco(s) encontrado(s):%RS%
for /f "usebackq delims=" %%F in ("%SORTED%") do (
    if not "%%F"=="" echo       %DM%-%RS% %%F
)

rem ============================================================
rem  5. COMPACTAR CADA DISCO ENCONTRADO
rem ============================================================
set "RESULTS=%TEMP%\wsl_vhdx_results_%RANDOM%.txt"
type nul > "%RESULTS%"

for /f "usebackq delims=" %%F in ("%SORTED%") do (
    if not "%%F"=="" call :Compact "%%F"
)

rem ============================================================
rem  6. RESUMO FINAL
rem ============================================================
call :StepBanner "Resumo da compactacao"
powershell -NoProfile -File "%HELPER%" -Summarize -ResultsFile "%RESULTS%"

net start WSLService >nul 2>&1

del "%SORTED%" >nul 2>&1
del "%RESULTS%" >nul 2>&1
del "%HELPER%" >nul 2>&1
del "%DPHELPER%" >nul 2>&1

echo.
echo %CY%==========================================================================%RS%
pause
exit /b 0

rem ============================================================
rem  SUBROTINAS
rem ============================================================

:ReleaseWslDisk
rem WSLService fica "Running" mesmo depois do wsl --shutdown e segura um
rem handle no vhdx (causa "arquivo ja esta sendo usado"). O vds e quem o
rem diskpart usa por baixo dos panos: se uma tentativa anterior for
rem interrompida no meio, ele fica com um estado interno preso (causa o
rem erro "nao pode ser executada enquanto o disco virtual estiver sendo
rem compactado"). Os dois precisam ser liberados antes de cada tentativa.
wsl --shutdown >nul 2>&1
set /p "=   %DM%Aguardando liberacao dos arquivos %RS%" <nul
for /l %%i in (1,1,%~1) do (
    timeout /t 1 /nobreak >nul
    set /p "=.%RS%" <nul
)
echo.
taskkill /IM vmmem.exe /F >nul 2>&1
taskkill /IM vmmemWSL.exe /F >nul 2>&1
net stop WSLService /y >nul 2>&1
net stop vds /y >nul 2>&1
net start vds >nul 2>&1
timeout /t 2 /nobreak >nul
exit /b 0

:Banner
cls
echo %CY%============================================================================%RS%
echo %CY%##  %MG%COMPACTADOR DE DISCO VIRTUAL - WSL / VHDX%RS%
echo %CY%##  %DM%diskpart - autodescoberta de distro - execucao automatizada%RS%
echo %CY%============================================================================%RS%
echo.
exit /b 0

:StepBanner
set /a STEP+=1
echo.
echo %CY%----------------------------------------------------------------------%RS%
echo %WT%  [!STEP!] %~1%RS%
echo %CY%----------------------------------------------------------------------%RS%
exit /b 0

:Compact
set "VHDX=%~1"
call :StepBanner "Compactando: %~nx1"
echo    %DM%%VHDX%%RS%

for /f "usebackq tokens=1,2 delims=|" %%A in (`powershell -NoProfile -File "%HELPER%" -Path "!VHDX!"`) do (
    set "SIZEBEFORE=%%A"
    set "SIZEBEFORE_FMT=%%B"
)
echo    Tamanho atual: %YL%!SIZEBEFORE_FMT!%RS%

set "DPSCRIPT=%TEMP%\diskpart_%RANDOM%.txt"
echo select vdisk file="!VHDX!">"%DPSCRIPT%"
echo attach vdisk readonly>>"%DPSCRIPT%"
echo compact vdisk>>"%DPSCRIPT%"
echo detach vdisk>>"%DPSCRIPT%"
echo exit>>"%DPSCRIPT%"

set "CLEANSCRIPT=%TEMP%\diskpart_clean_%RANDOM%.txt"
echo select vdisk file="!VHDX!">"%CLEANSCRIPT%"
echo detach vdisk>>"%CLEANSCRIPT%"
echo exit>>"%CLEANSCRIPT%"

rem se uma tentativa anterior falhou no meio do script, o diskpart aborta antes
rem do "detach vdisk" e deixa o disco anexado, causando erro na proxima tentativa.
diskpart /s "%CLEANSCRIPT%" >nul 2>&1

set "TENTATIVA=0"

:CompactAttempt
set /a TENTATIVA+=1
if !TENTATIVA! GTR 1 (
    echo    %YL%[AVISO] Tentativa anterior falhou. Liberando o disco e tentando novamente...%RS%
    call :ReleaseWslDisk 4
    diskpart /s "%CLEANSCRIPT%" >nul 2>&1
)

echo    %MG%^> executando diskpart (tentativa !TENTATIVA!/3)...%RS%
set "FALHOU=0"
for /f "usebackq delims=" %%L in (`powershell -NoProfile -File "%DPHELPER%" -Script "%DPSCRIPT%" -TimeoutMin 5`) do (
    if "%%L"=="HANGED_TIMEOUT" (
        echo    %RD%[ERRO] diskpart sem atividade ha 5 minutos - considerado travado. Encerrado.%RS%
        set "FALHOU=1"
    ) else (
        echo "%%L" | findstr /b "EXITCODE:" >nul 2>&1
        if errorlevel 1 (
            echo "%%L" | findstr /i "percent cento" >nul 2>&1
            if not errorlevel 1 (
                echo    %GR%^>^>%RS% %%L
            ) else (
                echo    %DM%..%RS% %%L
            )
            echo "%%L" | findstr /i "erro error" >nul 2>&1
            if not errorlevel 1 set "FALHOU=1"
        )
    )
)

if "!FALHOU!"=="1" if !TENTATIVA! LSS 3 goto :CompactAttempt

if "!FALHOU!"=="1" diskpart /s "%CLEANSCRIPT%" >nul 2>&1
del "%DPSCRIPT%" >nul 2>&1
del "%CLEANSCRIPT%" >nul 2>&1

for /f "usebackq tokens=1,2,3 delims=|" %%A in (`powershell -NoProfile -File "%HELPER%" -Path "!VHDX!" -Before !SIZEBEFORE!`) do (
    set "SIZEAFTER=%%A"
    set "SIZEAFTER_FMT=%%B"
    set "SIZESAVED_FMT=%%C"
)

if "!FALHOU!"=="1" (
    echo    %RD%[ERRO] O diskpart nao concluiu a compactacao ^(disco pode estar em uso por outro processo^).%RS%
    echo    %DM%Feche o Docker Desktop / outras VMs, aguarde alguns segundos e rode o script novamente.%RS%
) else (
    echo    Depois: %YL%!SIZEAFTER_FMT!%RS%   Economizado: %GR%!SIZESAVED_FMT!%RS%
)
echo !VHDX!^|!SIZEBEFORE!^|!SIZEAFTER!>>"%RESULTS%"
exit /b 0
