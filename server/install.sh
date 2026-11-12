#!/usr/bin/env bash
# Sets up Sonar's server side on macOS or Linux: Navidrome, and optionally
# Sonar Connect and Get music, in Docker, reachable over https with Tailscale.
#
#   bash install.sh            (asks a few questions; Enter takes the default)
#   bash install.sh --defaults (takes every default; answers from variables)
#
# Run it again any time to add Get music, change folders or repair things: it
# remembers your answers and keeps the keys it generated.
#
# Unattended answers (all optional): SONAR_INSTALL_DIR, SONAR_MUSIC_DIR,
# SONAR_EXISTING_NAVIDROME=yes|no, SONAR_NAVIDROME_URL, SONAR_ADMIN_USER,
# SONAR_APP_USER, SONAR_CONNECT=yes|no, SONAR_GETMUSIC=yes|no,
# SONAR_SOULSEEK_USER, SONAR_VPN_COUNTRIES, SONAR_DOWNLOADS_DIR,
# SONAR_SHARE_DIR, SONAR_TAILSCALE=yes|no, SONAR_PROJECT_NAME, and the ports
# SONAR_NAVIDROME_PORT / _CONNECT_PORT / _SOULBEET_PORT / _SLSKD_PORT.
# Secrets: SONAR_ADMIN_PASSWORD, SONAR_USER_PASSWORD, WIREGUARD_PRIVATE_KEY,
# SOULSEEK_PASSWORD.
#
# Works with the bash 3.2 that macOS ships (no associative arrays).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARTS="docker-compose.yml setup sonar_connect port-sync beets navidrome"
DEFAULTS=no
[ "${1:-}" = "--defaults" ] && DEFAULTS=yes

# ---- Small helpers -----------------------------------------------------------

if [ -t 1 ]; then C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else C_CYAN=; C_GREEN=; C_YELLOW=; C_RED=; C_BOLD=; C_OFF=; fi

say() { printf '%s\n' "$*"; }
good() { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF"; }
step() { printf '\n%s== %s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
fail() { printf '\n%sStopped: %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

# ask "Question" "default" -> prints the answer
ask() {
  local answer
  if [ "$DEFAULTS" = yes ]; then printf '%s' "$2"; return; fi
  if [ -n "$2" ]; then read -r -p "$1 [$2]: " answer </dev/tty; else read -r -p "$1: " answer </dev/tty; fi
  [ -z "$answer" ] && answer="$2"
  printf '%s' "$answer"
}

# ask_yes "Question" yes|no -> exit status 0 for yes
ask_yes() {
  local answer hint
  if [ "$DEFAULTS" = yes ]; then [ "$2" = yes ]; return; fi
  if [ "$2" = yes ]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    read -r -p "$1 ($hint): " answer </dev/tty
    [ -z "$answer" ] && answer="$2"
    case "$answer" in
      y|Y|yes|Yes|YES) return 0 ;;
      n|N|no|No|NO) return 1 ;;
    esac
  done
}

# yesno VALUE_FROM_VARIABLE "Question" default -> exit status 0 for yes
yesno() {
  case "$1" in
    yes) return 0 ;;
    no) return 1 ;;
    *) ask_yes "$2" "$3" ;;
  esac
}

# ask_secret "Question" ENV_NAME EXISTING confirm(yes|no) -> prints the secret
ask_secret() {
  local from_env="${!2:-}" first second
  if [ -n "$from_env" ]; then printf '%s' "$from_env"; return; fi
  if [ -n "$3" ]; then
    if [ "$DEFAULTS" = yes ] || ! ask_yes "$1 is already set. Change it?" no >&2; then printf '%s' "$3"; return; fi
  fi
  [ "$DEFAULTS" = yes ] && fail "$1 is needed: set $2 or run without --defaults."
  while true; do
    read -r -s -p "$1: " first </dev/tty; printf '\n' >&2
    if [ "${#first}" -lt 8 ]; then warn "  At least 8 characters, please." >&2; continue; fi
    if [ "$4" != yes ]; then printf '%s' "$first"; return; fi
    read -r -s -p "Type it again: " second </dev/tty; printf '\n' >&2
    [ "$first" = "$second" ] && { printf '%s' "$first"; return; }
    warn "  They don't match. Try again." >&2
  done
}

new_key() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0; fi
  if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -q "[:.]$1 " && return 0; fi
  return 1
}

# free_port START CURRENT -> CURRENT if set, else the first free port from START
free_port() {
  if [ -n "$2" ]; then printf '%s' "$2"; return; fi
  local p="$1"
  while port_in_use "$p"; do p=$((p + 1)); done
  printf '%s' "$p"
}

# An absolute path Docker understands (on Git Bash for Windows: C:/...).
abs_dir() {
  (cd "$1" && { pwd -W 2>/dev/null || pwd; })
}

# Earlier answers: every KEY=value of an existing .env becomes OLD_KEY.
load_old() {
  local key value
  [ -f "$1" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in ''|\#*) continue ;; esac
    case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
    printf -v "OLD_$key" '%s' "$value"
  done <"$1"
}
old() { local v="OLD_$1"; printf '%s' "${!v:-}"; }
first_of() { for v in "$@"; do [ -n "$v" ] && { printf '%s' "$v"; return 0; }; done; return 0; }

ENV_KEYS=""
set_cfg() {
  case "$2" in *$'\n'*) fail "$1 has a line break in it." ;; esac
  printf -v "CFG_$1" '%s' "$2"
  case " $ENV_KEYS " in *" $1 "*) ;; *) ENV_KEYS="$ENV_KEYS $1" ;; esac
}
cfg() { local v="CFG_$1"; printf '%s' "${!v:-}"; }

# ---- Docker -----------------------------------------------------------------

printf '\n%sSonar server setup%s\n' "$C_BOLD" "$C_OFF"
say "Every question has a default in [brackets]: press Enter to take it."

step "Checking Docker"
command -v docker >/dev/null 2>&1 || fail "Docker is not installed. Get Docker Desktop (Mac) from https://www.docker.com/products/docker-desktop/ or Docker Engine (Linux) from https://docs.docker.com/engine/install/, then run this again."
if ! docker info >/dev/null 2>&1; then
  if [ "$(uname)" = Darwin ] && [ -d /Applications/Docker.app ]; then
    say "Docker Desktop is not running; starting it (this can take a minute)..."
    open -a Docker
    for _ in $(seq 1 60); do sleep 3; docker info >/dev/null 2>&1 && break; done
  fi
  docker info >/dev/null 2>&1 || fail "Docker is installed but not running (or you need sudo / the docker group). Start it, then run this again."
fi
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is missing. Update Docker, then run this again."
good "Docker is ready."

# ---- Where ------------------------------------------------------------------

step "Install folder"
if [ -f "$HERE/.env" ]; then default_dir="$HERE"; else default_dir="$HOME/sonar-server"; fi
INSTALL_DIR="${SONAR_INSTALL_DIR:-$(ask "Where should the server files live?" "$default_dir")}"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
ENV_PATH="$INSTALL_DIR/.env"
load_old "$ENV_PATH"
[ -n "$(old COMPOSE_PROJECT_NAME)" ] && good "Found an earlier install here: your answers are the defaults."

if [ "$HERE" != "$INSTALL_DIR" ]; then
  for p in $PARTS; do
    [ -e "$HERE/$p" ] || fail "$HERE/$p is missing: run install.sh from Sonar's server folder."
    cp -R "$HERE/$p" "$INSTALL_DIR/"
  done
fi

# ---- Navidrome --------------------------------------------------------------

step "Music server (Navidrome)"
had_existing=no
if [ -n "$(old COMPOSE_PROFILES)" ]; then case ",$(old COMPOSE_PROFILES)," in *,navidrome,*) ;; *) had_existing=yes ;; esac; fi
USE_EXISTING=no
yesno "${SONAR_EXISTING_NAVIDROME:-}" "Do you already run Navidrome yourself (and want to keep it)?" "$had_existing" && USE_EXISTING=yes

set_cfg COMPOSE_PROJECT_NAME "$(first_of "${SONAR_PROJECT_NAME:-}" "$(old COMPOSE_PROJECT_NAME)" sonar)"
if [ "$USE_EXISTING" = yes ]; then
  url="$(first_of "${SONAR_NAVIDROME_URL:-}" "$(old NAVIDROME_INTERNAL_URL)" http://host.docker.internal:4533)"
  [ -z "${SONAR_NAVIDROME_URL:-}" ] && url="$(ask "Its address as seen from Docker (on this computer: http://host.docker.internal:<port>)" "$url")"
  set_cfg NAVIDROME_INTERNAL_URL "${url%/}"
  say "Get music needs to write into your library, so it still asks for your music folder below."
else
  set_cfg NAVIDROME_INTERNAL_URL "http://navidrome:4533"
fi
while true; do
  music="${SONAR_MUSIC_DIR:-$(ask "Your music folder (Navidrome reads it, never changes it)" "$(first_of "$(old MUSIC_DIR)" "$HOME/Music")")}"
  [ -d "$music" ] && break
  { [ -n "${SONAR_MUSIC_DIR:-}" ] || [ "$DEFAULTS" = yes ]; } && fail "Music folder not found: $music"
  warn "  Can't find $music. Check the path."
done
set_cfg MUSIC_DIR "$(abs_dir "$music")"
set_cfg NAVIDROME_PORT "$(first_of "${SONAR_NAVIDROME_PORT:-}" "$(free_port 4533 "$(old NAVIDROME_PORT)")")"

say ""
if [ "$USE_EXISTING" = yes ]; then say "An admin login of your Navidrome (used to start scans and set up Get music):"
else say "Navidrome needs an admin login. This installer makes it for you:"; fi
admin="$(first_of "${SONAR_ADMIN_USER:-}" "$(old NAVIDROME_ADMIN_USER)" admin)"
[ -z "${SONAR_ADMIN_USER:-}" ] && admin="$(ask "  Admin username" "$admin")"
set_cfg NAVIDROME_ADMIN_USER "$admin"
confirm=yes; [ "$USE_EXISTING" = yes ] && confirm=no
set_cfg NAVIDROME_ADMIN_PASSWORD "$(ask_secret "  Admin password" SONAR_ADMIN_PASSWORD "$(old NAVIDROME_ADMIN_PASSWORD)" "$confirm")"

say ""
say "Sonar should log in with an everyday (non-admin) account. Leave the name empty to skip."
APP_USER="${SONAR_APP_USER:-}"
[ -z "$APP_USER" ] && [ "$DEFAULTS" != yes ] && APP_USER="$(ask "  App username" "")"
APP_PASSWORD=""
[ -n "$APP_USER" ] && APP_PASSWORD="$(ask_secret "  Password for $APP_USER" SONAR_USER_PASSWORD "" yes)"

# ---- Optional parts ----------------------------------------------------------

step "Optional parts"
profiles=""
add_profile() { if [ -z "$profiles" ]; then profiles="$1"; else profiles="$profiles,$1"; fi; }
[ "$USE_EXISTING" = no ] && add_profile navidrome

had_connect=yes
if [ -n "$(old COMPOSE_PROFILES)" ]; then case ",$(old COMPOSE_PROFILES)," in *,connect,*) ;; *) had_connect=no ;; esac; fi
[ -z "${SONAR_CONNECT:-}" ] && say "Sonar Connect lets your phone and PC see what each other is playing and control each other."
WANT_CONNECT=no
yesno "${SONAR_CONNECT:-}" "Add Sonar Connect?" "$had_connect" && WANT_CONNECT=yes
if [ "$WANT_CONNECT" = yes ]; then
  add_profile connect
  set_cfg CONNECT_PORT "$(first_of "${SONAR_CONNECT_PORT:-}" "$(free_port 4534 "$(old CONNECT_PORT)")")"
fi

had_getmusic=no
case ",$(old COMPOSE_PROFILES)," in *,getmusic,*) had_getmusic=yes ;; esac
if [ -z "${SONAR_GETMUSIC:-}" ]; then
  say ""
  say "Get music lets Sonar find and download albums you don't have, over Soulseek."
  say "It needs: a VPN with port forwarding (Proton VPN Plus works out of the box), and a Soulseek"
  say "account (just pick a name nobody has: Soulseek creates it the first time you log in)."
  warn "You are responsible for what you download and share."
fi
WANT_GETMUSIC=no
yesno "${SONAR_GETMUSIC:-}" "Add Get music?" "$had_getmusic" && WANT_GETMUSIC=yes
if [ "$WANT_GETMUSIC" = yes ]; then
  add_profile getmusic
  say ""
  say "VPN: Proton VPN. On account.proton.me > VPN > WireGuard, create a config with"
  say "\"NAT-PMP (Port Forwarding)\" ON, then copy the PrivateKey line from it."
  set_cfg VPN_SERVICE_PROVIDER "$(first_of "$(old VPN_SERVICE_PROVIDER)" protonvpn)"
  set_cfg WIREGUARD_PRIVATE_KEY "$(ask_secret "  WireGuard PrivateKey" WIREGUARD_PRIVATE_KEY "$(old WIREGUARD_PRIVATE_KEY)" no)"
  set_cfg VPN_COUNTRIES "${SONAR_VPN_COUNTRIES:-$(ask "  VPN server country (empty = any)" "$(old VPN_COUNTRIES)")}"
  slsk="${SONAR_SOULSEEK_USER:-$(ask "  Soulseek username" "$(old SOULSEEK_USERNAME)")}"
  [ -z "$slsk" ] && fail "Get music needs a Soulseek username."
  set_cfg SOULSEEK_USERNAME "$slsk"
  set_cfg SOULSEEK_PASSWORD "$(ask_secret "  Soulseek password" SOULSEEK_PASSWORD "$(old SOULSEEK_PASSWORD)" no)"
  dl="${SONAR_DOWNLOADS_DIR:-$(ask "  Folder for downloads in progress" "$(first_of "$(old DOWNLOADS_DIR)" "$INSTALL_DIR/downloads")")}"
  say "  Many Soulseek users only send to people who share something back. Put music you"
  say "  are happy to share (and allowed to) in the share folder; it can stay empty."
  sh="${SONAR_SHARE_DIR:-$(ask "  Folder you share on Soulseek" "$(first_of "$(old SHARE_DIR)" "$INSTALL_DIR/share")")}"
  mkdir -p "$dl" "$sh"
  set_cfg DOWNLOADS_DIR "$(abs_dir "$dl")"
  set_cfg SHARE_DIR "$(abs_dir "$sh")"
  # New albums are filed into a folder inside your library, so Navidrome sees them.
  mkdir -p "$music/Soulbeet"
  set_cfg GETMUSIC_DIR "$(abs_dir "$music/Soulbeet")"
  set_cfg SOULBEET_PORT "$(first_of "${SONAR_SOULBEET_PORT:-}" "$(free_port 9765 "$(old SOULBEET_PORT)")")"
  set_cfg SLSKD_PORT "$(first_of "${SONAR_SLSKD_PORT:-}" "$(free_port 5030 "$(old SLSKD_PORT)")")"
fi
set_cfg COMPOSE_PROFILES "$profiles"

# Generated once, kept on every later run.
for k in SLSKD_API_KEY GLUETUN_API_KEY SOULBEET_SECRET_KEY SLSKD_WEB_PASSWORD; do
  set_cfg "$k" "$(first_of "$(old "$k")" "$(new_key)")"
done
set_cfg SLSKD_WEB_USERNAME "$(first_of "$(old SLSKD_WEB_USERNAME)" slskd)"

# ---- Write .env and start ----------------------------------------------------

step "Starting"
umask 077 # .env holds passwords: readable by you only.
{
  echo "# Written by install.sh. Holds passwords and keys: never share or commit it."
  echo "# Run the installer again to change things."
  for k in $ENV_KEYS; do printf '%s=%s\n' "$k" "$(cfg "$k")"; done
} >"$ENV_PATH"
umask 022
say "Settings saved to $ENV_PATH"

cd "$INSTALL_DIR"
say "Downloading and starting the containers (the first time takes a few minutes)..."
docker compose up -d --build --remove-orphans || fail "docker compose up failed (see above)."
say "Making logins and connecting the parts..."
SONAR_USER="$APP_USER" SONAR_USER_PASSWORD="$APP_PASSWORD" docker compose --profile setup run --rm setup ||
  fail "setup failed (see above). Fix it, then run this again."

# ---- https with Tailscale ----------------------------------------------------

step "Reaching it from your phone (https)"
TS=""
if command -v tailscale >/dev/null 2>&1; then TS="tailscale"
elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"; fi
SERVER_URL=""
USE_TS=no
if [ "${SONAR_TAILSCALE:-}" = no ]; then :
elif [ -z "$TS" ]; then
  say "Tailscale is not installed. Sonar needs an https address for your server; the easy way is"
  say "Tailscale (free): install it from https://tailscale.com/download on this computer and your"
  warn "phone, sign in on both, then run this installer again. (Or use your own reverse proxy.)"
else
  yesno "${SONAR_TAILSCALE:-}" "Serve it over https with Tailscale?" yes && USE_TS=yes
fi
if [ "$USE_TS" = yes ]; then
  status="$("$TS" status --json 2>/dev/null)" || fail "Tailscale is installed but not signed in. Sign in, then run this again."
  # Self comes before Peer in the JSON, so the first DNSName is this machine's.
  dns="$(printf '%s' "$status" | sed -n 's/.*"DNSName": *"\([^"]*\)".*/\1/p' | head -n1)"
  dns="${dns%.}"
  served=yes
  sudo_ts() { "$TS" "$@" >/dev/null 2>&1 || sudo "$TS" "$@" >/dev/null 2>&1; }
  [ "$USE_EXISTING" = no ] && { sudo_ts serve --bg "http://127.0.0.1:$(cfg NAVIDROME_PORT)" || served=no; }
  [ "$WANT_CONNECT" = yes ] && { sudo_ts serve --bg --set-path /sonar-connect "http://127.0.0.1:$(cfg CONNECT_PORT)" || served=no; }
  [ "$WANT_GETMUSIC" = yes ] && { sudo_ts serve --bg --https=8443 "http://127.0.0.1:$(cfg SOULBEET_PORT)" || served=no; }
  if [ "$served" = no ]; then
    warn "Tailscale would not serve it. You may need to turn on HTTPS for your tailnet once:"
    warn "https://login.tailscale.com/admin/dns > HTTPS Certificates > Enable, then run this again."
  else
    SERVER_URL="https://$dns"
    good "Serving at $SERVER_URL (only devices signed in to your Tailscale can reach it)."
  fi
fi

# ---- Done ---------------------------------------------------------------------

step "Done"
if [ -n "$SERVER_URL" ]; then say "${C_BOLD}Server address for Sonar:  $SERVER_URL${C_OFF}"
else say "Navidrome on this computer: http://127.0.0.1:$(cfg NAVIDROME_PORT) (Sonar on other devices needs an https address)"; fi
[ -n "$APP_USER" ] && say "${C_BOLD}Log in to Sonar as:        $APP_USER${C_OFF}"
say "Navidrome's web page:      http://127.0.0.1:$(cfg NAVIDROME_PORT) (admin: $(cfg NAVIDROME_ADMIN_USER))"
if [ "$WANT_GETMUSIC" = yes ]; then
  say "slskd's web page:          http://127.0.0.1:$(cfg SLSKD_PORT) (user slskd, password SLSKD_WEB_PASSWORD in .env)"
  say "Get music shows up in Sonar once the VPN has connected (a minute or two)."
fi
say ""
say "Get the app: https://github.com/Zombins2/sonar/releases"
say "Run this installer again to add Get music, change folders, or repair the setup."
