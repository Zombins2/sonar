# Sonar server

Everything Sonar talks to, in Docker, set up by one installer:

| Part | What it is | Default |
|---|---|---|
| **Navidrome** | The music server: reads your music folder, streams to Sonar. | on (skip it if you already run Navidrome) |
| **Sonar Connect** | A tiny relay so your phone and PC see and control each other. | on |
| **Get music** | Soulbeet + slskd behind a VPN: find and download albums you don't have. | off |

## Install

You need **Docker** ([Docker Desktop](https://www.docker.com/products/docker-desktop/)
on Windows and Mac, Docker Engine on Linux). For phones to reach the server,
install **[Tailscale](https://tailscale.com/download)** (free) on the server and
your phone and sign in on both; the installer does the rest.

Download this repository (green **Code** button > **Download ZIP**, or
`git clone`), then:

- **Windows:** double-click `server\install.cmd`.
- **Mac / Linux:** `bash server/install.sh`

It asks a few questions (each has a default: press Enter), then:

1. copies the server files to an install folder (default: `sonar-server` in
   your home folder) and writes your answers to `.env` there;
2. downloads and starts the containers;
3. makes Navidrome's admin login, and an everyday login for the app;
4. connects Get music's parts, if you chose it;
5. serves it all over https with Tailscale, and prints the address to type
   into Sonar.

Then install the app from the [Releases](../../../releases) page and log in.

**Add Get music later, change a folder, or repair something:** run the
installer again. It remembers your answers (they become the defaults) and
keeps the keys it generated.

### Get music needs

- **A VPN with port forwarding.** The installer sets up
  [Proton VPN](https://protonvpn.com/) (a paid plan; on account.proton.me >
  VPN > WireGuard, make a config with **NAT-PMP (Port Forwarding)** on and
  paste its PrivateKey). Soulseek traffic only ever leaves through the VPN;
  if the tunnel drops, slskd has no other way out. Other providers that
  [gluetun](https://github.com/qdm12/gluetun-wiki) supports with port
  forwarding work too: change `VPN_SERVICE_PROVIDER` and the VPN settings in
  `.env` and the `gluetun` section of `docker-compose.yml`.
- **A Soulseek account.** Pick a name nobody has; Soulseek creates it the
  first time it logs in.
- **Something to share (recommended).** Many Soulseek users only send to
  people who share back. Put music you're allowed to share in the share
  folder.

New albums are filed into a `Soulbeet` folder inside your music folder, so
Navidrome finds them. With Sonar Connect on, Navidrome rescans as soon as an
album lands.

> You are responsible for what you download and share. Respect the law where
> you live.

### Unattended install

Every question can be answered ahead of time, for scripts or reinstalls.
Windows: parameters (`Get-Help .\install.ps1 -Full`). Mac/Linux: variables
listed at the top of `install.sh`. Passwords always come from environment
variables (`SONAR_ADMIN_PASSWORD`, `SONAR_USER_PASSWORD`,
`WIREGUARD_PRIVATE_KEY`, `SOULSEEK_PASSWORD`), never from the command line.

## Day to day

In the install folder:

```
docker compose ps                     # what's running
docker compose logs -f soulbeet       # follow one part's log
docker compose pull && docker compose up -d   # update the images
```

- Navidrome's web page: `http://127.0.0.1:4533` on the server (your admin login).
- slskd's web page (Get music): `http://127.0.0.1:5030` (user `slskd`, password
  `SLSKD_WEB_PASSWORD` in `.env`).
- Ports are only open on the server itself; other devices go through
  Tailscale. The installer picks the next free port if one is taken.

## Uninstall

In the install folder:

```
docker compose --profile '*' down          # stop and remove the containers
docker compose --profile '*' down -v       # ...and Navidrome's and Soulbeet's databases
tailscale serve reset                      # stop serving over Tailscale
```

Then delete the install folder. Your music folder is never changed (Get music
only ever writes into its `Soulbeet` folder).

## What's in here

```
install.cmd / install.ps1   Windows installer
install.sh                  Mac / Linux installer
docker-compose.yml          every part, switched on by COMPOSE_PROFILES in .env
setup/configure.py          makes the logins and connects Get music (runs in Docker)
sonar_connect/              the Sonar Connect relay (Python, no dependencies)
port-sync/                  keeps slskd on the port the VPN forwards
beets/config.yaml           how beets tags and files new albums
navidrome/navidrome.toml    reads synced lyrics from SYNCEDLYRICS tags too
```
