<#
.SYNOPSIS
  Sets up Sonar's server side on Windows: Navidrome, and optionally Sonar
  Connect and Get music, in Docker, reachable over https with Tailscale.

.DESCRIPTION
  Asks a few questions (every one has a default), writes .env next to
  docker-compose.yml in the install folder, starts the containers, makes the
  Navidrome logins, and sets up Tailscale. Run it again any time to add Get
  music, change folders or repair things: it remembers your answers and keeps
  the keys it generated.

  Double-click install.cmd, or:
    powershell -ExecutionPolicy Bypass -File install.ps1

  Every question can also be answered with a parameter, and passwords with
  environment variables (SONAR_ADMIN_PASSWORD, SONAR_USER_PASSWORD,
  WIREGUARD_PRIVATE_KEY, SOULSEEK_PASSWORD), for unattended installs.
#>
[CmdletBinding()]
param(
  [string]$InstallDir,
  [string]$MusicDir,
  [ValidateSet('', 'yes', 'no')][string]$ExistingNavidrome = '',
  [string]$NavidromeUrl,
  [string]$AdminUser,
  [string]$AppUser,
  [ValidateSet('', 'yes', 'no')][string]$Connect = '',
  [ValidateSet('', 'yes', 'no')][string]$GetMusic = '',
  [string]$SoulseekUser,
  [string]$VpnCountries,
  [string]$DownloadsDir,
  [string]$ShareDir,
  [ValidateSet('', 'yes', 'no')][string]$Tailscale = '',
  [string]$ProjectName,
  [int]$NavidromePort,
  [int]$ConnectPort,
  [int]$SoulbeetPort,
  [int]$SlskdPort,
  # Take the default for every question not answered by a parameter.
  [switch]$Defaults
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$parts = @('docker-compose.yml', 'setup', 'sonar_connect', 'port-sync', 'beets', 'navidrome')

# ---- Small helpers -----------------------------------------------------------

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Step([string]$text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Fail([string]$text) {
  Write-Host ''
  Write-Host "Stopped: $text" -ForegroundColor Red
  exit 1
}

function Ask([string]$question, [string]$default) {
  if ($Defaults) { return $default }
  $shown = if ($default) { " [$default]" } else { '' }
  $answer = Read-Host "$question$shown"
  if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
  return $answer.Trim()
}

function AskYes([string]$question, [bool]$default) {
  if ($Defaults) { return $default }
  $hint = if ($default) { 'Y/n' } else { 'y/N' }
  while ($true) {
    $answer = Read-Host "$question ($hint)"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    switch -Regex ($answer.Trim()) {
      '^(y|yes)$' { return $true }
      '^(n|no)$' { return $false }
    }
  }
}

function Plain([Security.SecureString]$secure) {
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# A secret from an environment variable, the existing .env, or typed (hidden).
function AskSecret([string]$question, [string]$envName, [string]$existing, [bool]$confirm) {
  $fromEnv = [Environment]::GetEnvironmentVariable($envName)
  if ($fromEnv) { return $fromEnv }
  if ($existing) {
    if ($Defaults -or -not (AskYes "$question is already set. Change it?" $false)) { return $existing }
  }
  if ($Defaults) { Fail "$question is needed: set $envName or run without -Defaults." }
  while ($true) {
    $first = Plain (Read-Host "$question" -AsSecureString)
    if ($first.Length -lt 8) { Say '  At least 8 characters, please.' Yellow; continue }
    if (-not $confirm) { return $first }
    $second = Plain (Read-Host 'Type it again' -AsSecureString)
    if ($first -ceq $second) { return $first }
    Say "  They don't match. Try again." Yellow
  }
}

function NewKey([int]$bytes = 24) {
  $buf = New-Object byte[] $bytes
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
  return -join ($buf | ForEach-Object { $_.ToString('x2') })
}

function PortInUse([int]$port) {
  return [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
}

# The first free port from $start up, unless the port is already ours. Ports
# handed out earlier in this run count as taken: nothing listens on them yet.
$script:handedOut = @()
function FreePort([int]$start, [string]$current) {
  if ($current) { $p = [int]$current }
  else {
    $p = $start
    while ((PortInUse $p) -or ($script:handedOut -contains $p)) { $p++ }
  }
  $script:handedOut += $p
  return $p
}

function ForwardSlashes([string]$path) { return $path.Replace('\', '/') }

function ReadEnv([string]$path) {
  $values = @{}
  if (Test-Path $path) {
    foreach ($line in Get-Content $path -Encoding UTF8) {
      if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
  }
  return $values
}

function Pick([string]$param, [string]$fromEnv, [string]$fallback) {
  if ($param) { return $param }
  if ($fromEnv) { return $fromEnv }
  return $fallback
}

function RunDocker {
  # Runs docker, failing loudly. Arguments are passed as-is.
  & docker @args
  if ($LASTEXITCODE -ne 0) { Fail "docker $($args -join ' ') failed (exit $LASTEXITCODE)." }
}

# ---- Docker -----------------------------------------------------------------

Write-Host ''
Write-Host 'Sonar server setup' -ForegroundColor White
Say 'Every question has a default in [brackets]: press Enter to take it.'

Step 'Checking Docker'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Fail ('Docker is not installed. Install Docker Desktop from https://www.docker.com/products/docker-desktop/ ' +
    '(or: winget install Docker.DockerDesktop), start it once, then run this again.')
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
  $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (Test-Path $desktop) {
    Say 'Docker Desktop is not running; starting it (this can take a minute)...'
    Start-Process $desktop
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 3
      & docker info *> $null
      if ($LASTEXITCODE -eq 0) { break }
    }
  }
  & docker info *> $null
  if ($LASTEXITCODE -ne 0) { Fail 'Docker is installed but not running. Start Docker Desktop, then run this again.' }
}
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Docker Compose is missing. Update Docker Desktop, then run this again.' }
Say 'Docker is ready.' Green

# ---- Where ------------------------------------------------------------------

Step 'Install folder'
$defaultDir = if (Test-Path (Join-Path $here '.env')) { $here } else { Join-Path $HOME 'sonar-server' }
$InstallDir = if ($InstallDir) { $InstallDir } else { Ask 'Where should the server files live?' $defaultDir }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$envPath = Join-Path $InstallDir '.env'
$old = ReadEnv $envPath
if ($old.Count -gt 0) { Say "Found an earlier install here: your answers are the defaults." Green }

if ([IO.Path]::GetFullPath($here) -ne $InstallDir) {
  foreach ($p in $parts) {
    $src = Join-Path $here $p
    if (-not (Test-Path $src)) { Fail "$src is missing: run install.ps1 from Sonar's server folder." }
    Copy-Item -Recurse -Force $src $InstallDir
  }
}

# ---- Navidrome --------------------------------------------------------------

Step 'Music server (Navidrome)'
$hadNavidrome = ($old['COMPOSE_PROFILES'] -and ($old['COMPOSE_PROFILES'] -notmatch 'navidrome'))
$useExisting = if ($ExistingNavidrome) { $ExistingNavidrome -eq 'yes' } else {
  AskYes 'Do you already run Navidrome yourself (and want to keep it)?' $hadNavidrome
}
$cfg = [ordered]@{}
$cfg['COMPOSE_PROJECT_NAME'] = Pick $ProjectName $old['COMPOSE_PROJECT_NAME'] 'sonar'

if ($useExisting) {
  $NavidromeUrl = Pick $NavidromeUrl $old['NAVIDROME_INTERNAL_URL'] ''
  $NavidromeUrl = Ask 'Its address as seen from Docker (on this PC: http://host.docker.internal:<port>)' `
  $(if ($NavidromeUrl) { $NavidromeUrl } else { 'http://host.docker.internal:4533' })
  $cfg['NAVIDROME_INTERNAL_URL'] = $NavidromeUrl.TrimEnd('/')
  $musicDefault = $old['MUSIC_DIR']
  Say 'Get music needs to write into your library, so it still asks for your music folder below.'
} else {
  $cfg['NAVIDROME_INTERNAL_URL'] = 'http://navidrome:4533'
  $musicDefault = $old['MUSIC_DIR']
}
while ($true) {
  $m = if ($MusicDir) { $MusicDir } else {
    Ask 'Your music folder (Navidrome reads it, never changes it)' $(if ($musicDefault) { $musicDefault.Replace('/', '\') } else { Join-Path $HOME 'Music' })
  }
  if (Test-Path -PathType Container $m) { break }
  if ($MusicDir -or $Defaults) { Fail "Music folder not found: $m" }
  Say "  Can't find $m. Check the path." Yellow
}
$cfg['MUSIC_DIR'] = ForwardSlashes ([IO.Path]::GetFullPath($m))
$cfg['NAVIDROME_PORT'] = if ($NavidromePort) { $NavidromePort } else { FreePort 4533 $old['NAVIDROME_PORT'] }

Say ''
Say $(if ($useExisting) { 'An admin login of your Navidrome (used to start scans and set up Get music):' }
  else { 'Navidrome needs an admin login. This installer creates it for you:' })
$cfg['NAVIDROME_ADMIN_USER'] = Pick $AdminUser $old['NAVIDROME_ADMIN_USER'] ''
if (-not $AdminUser) { $cfg['NAVIDROME_ADMIN_USER'] = Ask '  Admin username' $(if ($cfg['NAVIDROME_ADMIN_USER']) { $cfg['NAVIDROME_ADMIN_USER'] } else { 'admin' }) }
$cfg['NAVIDROME_ADMIN_PASSWORD'] = AskSecret '  Admin password' 'SONAR_ADMIN_PASSWORD' $old['NAVIDROME_ADMIN_PASSWORD'] (-not $useExisting)

Say ''
Say 'Sonar should log in with an everyday (non-admin) account. Leave the name empty to skip.'
$appName = if ($AppUser) { $AppUser } elseif ($Defaults) { '' } else { Ask '  App username' '' }
$appPassword = ''
if ($appName) { $appPassword = AskSecret "  Password for $appName" 'SONAR_USER_PASSWORD' '' $true }

# ---- Optional parts ----------------------------------------------------------

Step 'Optional parts'
$profiles = @()
if (-not $useExisting) { $profiles += 'navidrome' }
$hadConnect = (-not $old['COMPOSE_PROFILES']) -or ($old['COMPOSE_PROFILES'] -match 'connect')
$wantConnect = if ($Connect) { $Connect -eq 'yes' } else {
  Say 'Sonar Connect lets your phone and PC see what each other is playing and control each other.'
  AskYes 'Add Sonar Connect?' $hadConnect
}
if ($wantConnect) {
  $profiles += 'connect'
  $cfg['CONNECT_PORT'] = if ($ConnectPort) { $ConnectPort } else { FreePort 4534 $old['CONNECT_PORT'] }
}

$hadGetMusic = $old['COMPOSE_PROFILES'] -match 'getmusic'
$wantGetMusic = if ($GetMusic) { $GetMusic -eq 'yes' } else {
  Say ''
  Say 'Get music lets Sonar find and download albums you do not have, over Soulseek.'
  Say 'It needs: a VPN with port forwarding (Proton VPN Plus works out of the box), and a Soulseek'
  Say 'account (just pick a name nobody has: Soulseek creates it the first time you log in).'
  Say 'You are responsible for what you download and share.' Yellow
  AskYes 'Add Get music?' $hadGetMusic
}
if ($wantGetMusic) {
  $profiles += 'getmusic'
  Say ''
  Say 'VPN: Proton VPN. On account.proton.me > VPN > WireGuard, create a config with'
  Say '"NAT-PMP (Port Forwarding)" ON, then copy the PrivateKey line from it.'
  $cfg['VPN_SERVICE_PROVIDER'] = Pick '' $old['VPN_SERVICE_PROVIDER'] 'protonvpn'
  $cfg['WIREGUARD_PRIVATE_KEY'] = AskSecret '  WireGuard PrivateKey' 'WIREGUARD_PRIVATE_KEY' $old['WIREGUARD_PRIVATE_KEY'] $false
  $cfg['VPN_COUNTRIES'] = if ($VpnCountries) { $VpnCountries } else { Ask '  VPN server country (empty = any)' $old['VPN_COUNTRIES'] }
  $cfg['SOULSEEK_USERNAME'] = if ($SoulseekUser) { $SoulseekUser } else { Ask '  Soulseek username' $old['SOULSEEK_USERNAME'] }
  if (-not $cfg['SOULSEEK_USERNAME']) { Fail 'Get music needs a Soulseek username.' }
  $cfg['SOULSEEK_PASSWORD'] = AskSecret '  Soulseek password' 'SOULSEEK_PASSWORD' $old['SOULSEEK_PASSWORD'] $false

  $dl = if ($DownloadsDir) { $DownloadsDir } else { Ask '  Folder for downloads in progress' $(if ($old['DOWNLOADS_DIR']) { $old['DOWNLOADS_DIR'].Replace('/', '\') } else { Join-Path $InstallDir 'downloads' }) }
  Say '  Many Soulseek users only send to people who share something back. Put music you'
  Say '  are happy to share (and allowed to) in the share folder; it can stay empty.'
  $sh = if ($ShareDir) { $ShareDir } else { Ask '  Folder you share on Soulseek' $(if ($old['SHARE_DIR']) { $old['SHARE_DIR'].Replace('/', '\') } else { Join-Path $InstallDir 'share' }) }
  foreach ($d in @($dl, $sh)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  $cfg['DOWNLOADS_DIR'] = ForwardSlashes ([IO.Path]::GetFullPath($dl))
  $cfg['SHARE_DIR'] = ForwardSlashes ([IO.Path]::GetFullPath($sh))
  # New albums are filed into a folder inside your library, so Navidrome sees them.
  $getDir = Join-Path $cfg['MUSIC_DIR'] 'Soulbeet'
  New-Item -ItemType Directory -Force -Path $getDir | Out-Null
  $cfg['GETMUSIC_DIR'] = ForwardSlashes $getDir
  $cfg['SOULBEET_PORT'] = if ($SoulbeetPort) { $SoulbeetPort } else { FreePort 9765 $old['SOULBEET_PORT'] }
  $cfg['SLSKD_PORT'] = if ($SlskdPort) { $SlskdPort } else { FreePort 5030 $old['SLSKD_PORT'] }
}
$cfg['COMPOSE_PROFILES'] = $profiles -join ','

# Generated once, kept on every later run.
foreach ($k in @('SLSKD_API_KEY', 'GLUETUN_API_KEY', 'SOULBEET_SECRET_KEY', 'SLSKD_WEB_PASSWORD')) {
  $cfg[$k] = if ($old[$k]) { $old[$k] } else { NewKey }
}
$cfg['SLSKD_WEB_USERNAME'] = Pick '' $old['SLSKD_WEB_USERNAME'] 'slskd'

# ---- Write .env and start ----------------------------------------------------

Step 'Starting'
$lines = @(
  '# Written by install.ps1. Holds passwords and keys: never share or commit it.',
  '# Run the installer again to change things.'
)
foreach ($k in $cfg.Keys) {
  $v = [string]$cfg[$k]
  if ($v -match '[\r\n]') { Fail "$k has a line break in it." }
  $lines += "$k=$v"
}
[IO.File]::WriteAllText($envPath, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
Say "Settings saved to $envPath"

Push-Location $InstallDir
try {
  Say 'Downloading and starting the containers (the first time takes a few minutes)...'
  RunDocker compose up -d --build --remove-orphans
  Say 'Creating logins and connecting the parts...'
  $env:SONAR_USER = $appName
  $env:SONAR_USER_PASSWORD = $appPassword
  try { RunDocker compose --profile setup run --rm setup }
  finally { Remove-Item Env:SONAR_USER, Env:SONAR_USER_PASSWORD -ErrorAction SilentlyContinue }
} finally { Pop-Location }

# ---- https with Tailscale ----------------------------------------------------

Step 'Reaching it from your phone (https)'
$ts = Get-Command tailscale -ErrorAction SilentlyContinue
if (-not $ts) {
  $guess = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  if (Test-Path $guess) { $ts = Get-Item $guess }
}
$serverUrl = ''
$useTs = $false
if ($Tailscale -eq 'no') { $useTs = $false }
elseif (-not $ts) {
  Say 'Tailscale is not installed. Sonar needs an https address for your server; the easy way is'
  Say 'Tailscale (free): install it from https://tailscale.com/download on this PC and your phone,'
  Say 'sign in on both, then run this installer again. (Or put your own reverse proxy in front.)' Yellow
} else {
  $useTs = if ($Tailscale -eq 'yes') { $true } else { AskYes 'Serve it over https with Tailscale?' $true }
}
if ($useTs) {
  $tsExe = if ($ts.Source) { $ts.Source } else { $ts.FullName }
  $status = & $tsExe status --json 2>$null | Out-String
  if ($LASTEXITCODE -ne 0 -or -not $status) { Fail 'Tailscale is installed but not signed in. Open Tailscale, sign in, then run this again.' }
  $dns = (($status | ConvertFrom-Json).Self.DNSName).TrimEnd('.')
  $served = $true
  $routes = @()
  if (-not $useExisting) { $routes += , @('--bg', "http://127.0.0.1:$($cfg['NAVIDROME_PORT'])") }
  if ($wantConnect) { $routes += , @('--bg', '--set-path', '/sonar-connect', "http://127.0.0.1:$($cfg['CONNECT_PORT'])") }
  if ($wantGetMusic) { $routes += , @('--bg', '--https=8443', "http://127.0.0.1:$($cfg['SOULBEET_PORT'])") }
  foreach ($r in $routes) {
    & $tsExe serve @r | Out-Null
    if ($LASTEXITCODE -ne 0) { $served = $false }
  }
  if (-not $served) {
    Say 'Tailscale would not serve it. You may need to turn on HTTPS for your tailnet once:' Yellow
    Say 'https://login.tailscale.com/admin/dns > HTTPS Certificates > Enable, then run this again.' Yellow
  } else {
    $serverUrl = "https://$dns"
    Say "Serving at $serverUrl (only devices signed in to your Tailscale can reach it)." Green
  }
}

# ---- Done ---------------------------------------------------------------------

Step 'Done'
if ($serverUrl) { Say "Server address for Sonar:  $serverUrl" White }
else { Say "Navidrome on this PC: http://127.0.0.1:$($cfg['NAVIDROME_PORT']) (Sonar on other devices needs an https address)" White }
if ($appName) { Say "Log in to Sonar as:        $appName" White }
Say "Navidrome's web page:      http://127.0.0.1:$($cfg['NAVIDROME_PORT']) (admin: $($cfg['NAVIDROME_ADMIN_USER']))"
if ($wantGetMusic) {
  Say "slskd's web page:          http://127.0.0.1:$($cfg['SLSKD_PORT']) (user slskd, password SLSKD_WEB_PASSWORD in .env)"
  Say 'Get music shows up in Sonar once the VPN has connected (a minute or two).'
}
Say ''
Say 'Get the app: https://github.com/Zombins2/sonar/releases'
Say "Run this installer again to add Get music, change folders, or repair the setup."
