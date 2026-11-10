<#
.SYNOPSIS
    Rollt eine neue Konfiguration via CLI per SSH auf mehrere Switches aus.

.DESCRIPTION
    Liest die IP-Adressen aus einer Textdatei "switches.txt" (eine IP pro Zeile) oder CSV (Spalte "IP") aus,
    verbindet sich mit jedem Switch per SSH (Posh-SSH) und führt die Befehle aus.
    Ausgaben und Fehler werden, pro Switch, in die Logdatei "switch-config-DATUM.log" geschrieben.

.EXAMPLE
    .\Set-SwitchSyslog.ps1 -IpListPath .\switches.txt

.NOTES
    Voraussetzung: Install-Module Posh-SSH -Scope CurrentUser
#>

param(
    [string]$IpListPath     = ".\switches.txt",
    [int]$SeverityLevel     = 5,        # 0-7, 5 = Warning
    [int]$CommandDelayMs    = 300,      # Wartezeit nach jedem Befehl
    [int]$SaveWaitSeconds   = 5,       # Wartezeit für "write memory"
    [string]$LogPath        = ".\switch-config-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

# --- POSH Modul prüfen ------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host "Posh-SSH fehlt. Installation mit: Install-Module Posh-SSH -Scope CurrentUser" -ForegroundColor Red
    return
}
Import-Module Posh-SSH

# --- Befehle ----------------------------------------------------------------
$Commands = @(
    "configure"
    "show running configuration"
    "end"
)
$SaveCommand = "write memory"

# --- IP-Liste einlesen ------------------------------------------------------
# --- TXT
if (-not (Test-Path $IpListPath)) {
    Write-Host "IP-Liste nicht gefunden: $IpListPath" -ForegroundColor Red
    return
}

# --- CSV
if ($IpListPath -like "*.csv") {
    $Switches = (Import-Csv $IpListPath).IP
} else {
    $Switches = Get-Content $IpListPath
}
$Switches = $Switches | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' }

# --- Credentials holen ------------------------------------------------------
$Cred = Get-Credential -Message "SSH-Zugangsdaten für die Switches"

# --- Functions --------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogPath -Value $line
}

function Send-Command {
    param($Stream, [string]$Command, [int]$DelayMs)
    $Stream.WriteLine($Command)
    Start-Sleep -Milliseconds $DelayMs
    $Stream.Read()
}

# --- Hauptschleife ----------------------------------------------------------
$Results = foreach ($ip in $Switches) {
    Write-Host "👽 [$ip] Verbinde ..." -ForegroundColor Cyan
    Write-Log "🔌 $ip"
    $status  = "OK"
    $session = $null

    try {
        $session = New-SSHSession -ComputerName $ip -Credential $Cred -AcceptKey -ConnectionTimeout 15 -ErrorAction Stop
        $stream  = New-SSHShellStream -SessionId $session.SessionId -TerminalName "vt100"
        Start-Sleep -Seconds 2
        Write-Log ($stream.Read())   # Banner

        # Wenn noch das "enable" nötig ist,  einkommentieren (Cisco, HP, etc.)
        # Write-Log (Send-Command $stream "enable" $CommandDelayMs)

        foreach ($cmd in $Commands) {
            $out = Send-Command -Stream $stream -Command $cmd -DelayMs $CommandDelayMs
            Write-Log "> $cmd`n$out"
        }

        # Speichern (manche Switches fragen nach einer Bestätigung)
        $out = Send-Command -Stream $stream -Command $SaveCommand -DelayMs 1000
        if ($out -match '\[?[yY]/[nN]\]?|\(y/n\)|overwrite|confirm') {
            $out += Send-Command -Stream $stream -Command "Y" -DelayMs 1000
        }
        Start-Sleep -Seconds $SaveWaitSeconds
        $out += $stream.Read()
        Write-Log "> $SaveCommand`n$out"

        Write-Host "👽 [$ip] Fertig." -ForegroundColor Green
    }
    catch {
        $status = "FEHLER: $($_.Exception.Message)"
        Write-Host "🛸 [$ip] $status" -ForegroundColor Red
        Write-Log $status
    }
    finally {
        if ($session) { Remove-SSHSession -SessionId $session.SessionId | Out-Null }
    }

    [PSCustomObject]@{ IP = $ip; Status = $status; Log = $LogPath }
}

# --- Zusammenfassung --------------------------------------------------------
Write-Host "`n`n 👻 Zusammenfassung" -ForegroundColor Yellow
$Results | Format-Table -AutoSize
# Write-Host "Log: $LogPath"
