# Duckstation Media Server

A self-hosted media server you can run on a Linux computer at home. It keeps
your films and TV shows in one place, lets you watch them on devices on your
home network, and provides tools to request, find, download, organise, and add
subtitles to media automatically.

Everything runs in Docker containers, which are isolated applications managed
from the single `docker-compose.yml` file. You do not need to understand every
container before starting: follow this guide in order, then use the web pages
listed below to configure each application.

This repository deliberately contains no VPN credentials, OpenVPN profiles,
media, downloads, or application state. That makes it safe to copy as the
starting point for your own server.

## What each service does

Replace `SERVER_IP` below with the local IP address of **your** server. For
example, if your server's address is `192.168.1.50`, Jellyfin is available at
`http://192.168.1.50:8096`.

| Service | What it is for | Open it from another device | Media path |
| --- | --- | --- | --- |
| Heimdall | A start page/dashboard for links to the other services. | `http://SERVER_IP/` | — |
| Jellyfin | Your private Netflix-like player for streaming your movie and TV libraries. | `http://SERVER_IP:8096` | `/media` (read-only) |
| Seerr | A friendly request page where family and friends can ask for movies or TV shows. | `http://SERVER_IP:5055` | — |
| Sonarr | Watches for requested TV episodes, sends downloads to qBittorrent, then organises them. | `http://SERVER_IP:8989` | `/data` |
| Radarr | The equivalent of Sonarr for movies. | `http://SERVER_IP:7878` | `/data` |
| Prowlarr | Manages search/indexer connections once and shares them with Sonarr and Radarr. | `http://SERVER_IP:9696` | — |
| qBittorrent | The download client that receives torrent downloads. Its traffic goes through the VPN. | `http://SERVER_IP:8080` | `/data` |
| Gluetun | The VPN connection and firewall that protects qBittorrent; it has no normal web page. | — | — |
| Bazarr | Finds and downloads subtitles for the movies and episodes managed by Radarr and Sonarr. | `http://SERVER_IP:6767` | `/data` |

Jellyfin uses host networking. qBittorrent shares Gluetun's network namespace,
so its Web UI and torrent ports are published by **Gluetun**, not qBittorrent.

## Find your server's IP address

Run this on the new server after it is connected to your home network:

```bash
hostname -I
```

Use the private IPv4 address from the output—normally one beginning with
`192.168.`, `10.`, or `172.16.` through `172.31.`. If more than one address is
shown, choose the one for your home-network adapter; this command is useful for
checking it:

```bash
ip -4 addr show scope global
```

Then replace `SERVER_IP` in the addresses above with that value. You can open
them from a phone, TV, or computer connected to the same home network. The
address may change after a reboot unless you create a DHCP reservation (also
called an IP reservation) for the server in your router's settings.

## 1. Install Docker (Debian)

These are the current official Docker Engine apt-repository instructions for
Debian. See the [Docker Debian installation guide](https://docs.docker.com/engine/install/debian/)
for supported releases and updates.

```bash
sudo apt update
sudo apt install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

```bash
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

Optionally permit the current user to run Docker without `sudo`, then log out
and in again (or run `newgrp docker`). Membership of the `docker` group grants
root-equivalent access; see [Docker's post-install guidance](https://docs.docker.com/engine/install/linux-postinstall/).

```bash
sudo usermod -aG docker "$USER"
newgrp docker
docker run --rm hello-world
```

## 2. Clone and prepare the project

```bash
git clone https://github.com/dllsantos/duckstation-media-server.git ~/server
cd ~/server
cp .env.example .env
chmod 600 .env
```

The Compose file uses relative bind mounts, so `~/server` can be any user's
home-directory project path. Create the directories before starting containers:

```bash
mkdir -p \
  gluetun/iptables \
  jellyfin/config jellyfin/cache \
  qbittorrent/config prowlarr/config sonarr/config radarr/config \
  bazarr/config seerr/config heimdall/config \
  media/drive/torrents media/drive/media/movies media/drive/media/tv
```

## 3. Create `.env`

Get the numeric owner IDs from the account that owns `~/server`:

```bash
id -u
id -g
```

Edit `.env` and replace every placeholder. `NORDVPN_USERNAME` and
`NORDVPN_PASSWORD` are NordVPN **manual/OpenVPN service credentials**, not
necessarily the normal Nord Account login.

```env
NORDVPN_USERNAME=your_nordvpn_service_username
NORDVPN_PASSWORD=your_nordvpn_service_password
PUID=1000
PGID=1000
TZ=Europe/Lisbon
```

`PUID` and `PGID` are used by Prowlarr, Sonarr, Radarr, Bazarr, qBittorrent,
and Heimdall. `.env` is ignored by Git and must never be committed.

## 4. Install the NordVPN OpenVPN profile

Obtain an OpenVPN UDP configuration from NordVPN separately, then save it at
this exact project-relative path:

```text
~/server/gluetun/pt134.nordvpn.com.udp_2.6.ovpn
```

The `gluetun` service mounts that host file read-only as
`/gluetun/custom.conf`. The expected profile is not in Git because profiles
with `<tls-crypt>`, `<key>`, or other cryptographic material are secrets.

Confirm it will not be tracked:

```bash
git check-ignore -v gluetun/pt134.nordvpn.com.udp_2.6.ovpn
git status --short
```

Do not paste the profile, VPN credentials, databases, configs, media, or
downloads into commits.

## 5. Mount the external NTFS drive

The drive must be mounted at `~/server/media/drive`; it is exposed as `/data`
to qBittorrent, Sonarr, Radarr, and Bazarr, and as `/media` (read-only) to
Jellyfin. Identify its UUID and filesystem:

```bash
lsblk -f
```

Get the absolute mount-point path while in the project directory:

```bash
cd ~/server
pwd
```

Add an `/etc/fstab` line using the displayed absolute path, replacing all
placeholders. Do not put `~` in `fstab`, since it is not expanded there.

```fstab
UUID=YOUR-UUID-HERE /absolute/path/to/server/media/drive ntfs3 defaults,uid=YOUR_UID,gid=YOUR_GID,umask=022,nofail,x-systemd.device-timeout=10 0 0
```

Use the values from `id -u` and `id -g` for `YOUR_UID` and `YOUR_GID`. Then
reload mount units, mount, and verify:

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt -T ~/server/media/drive
```

The output must show the external drive, not the host filesystem. Create the
media folders after a successful mount if necessary:

```bash
mkdir -p ~/server/media/drive/torrents \
  ~/server/media/drive/media/movies \
  ~/server/media/drive/media/tv
```

The common `/data` mapping is intentional: qBittorrent downloads to
`/data/torrents`, while Sonarr and Radarr import into `/data/media/...` from
the same mounted filesystem.

## 6. Start and verify the stack

Validate interpolation first, then start it:

```bash
cd ~/server
docker compose config
docker compose up -d
docker compose ps
```

Gluetun must be running before qBittorrent can operate. Check its logs and
verify the public address from the shared network namespace:

```bash
docker logs gluetun --tail=50
docker run --rm --network container:gluetun curlimages/curl:latest https://ifconfig.me
```

The address returned by the second command must be the VPN address, not the
ISP address. qBittorrent should report that it uses Gluetun's namespace:

```bash
docker inspect qbittorrent --format 'Status={{.State.Status}} NetworkMode={{.HostConfig.NetworkMode}}'
```

## 7. Gluetun and qBittorrent networking

qBittorrent uses port `6881` for both TCP and UDP. Gluetun publishes:

```yaml
- "8080:8080"
- "6881:6881"
- "6881:6881/udp"
```

`FIREWALL_VPN_INPUT_PORTS=6881` allows inbound VPN traffic to that torrent
port. UDP trackers additionally require this OUTPUT rule:

```text
iptables -A OUTPUT -p udp --sport 6881 -j ACCEPT
```

The persistent, active mechanism is
[`gluetun/iptables/post-rules.txt`](gluetun/iptables/post-rules.txt), mounted
by Compose at `/iptables/post-rules.txt`. Do not replace it with a Compose
`command` that runs `custom.sh`: that replaces Gluetun's entrypoint and causes
`ERROR command is unknown: /gluetun/scripts/custom.sh`. The obsolete
`gluetun/scripts/custom.sh` has been removed.

After startup, confirm both the setting and source-port rule:

```bash
docker exec gluetun sh -c 'env | grep FIREWALL_VPN_INPUT_PORTS'
docker exec gluetun iptables -S OUTPUT
```

In qBittorrent (`http://SERVER_IP:8080`), configure and retain Web UI
credentials, set the listening port to `6881`, disable UPnP, disable NAT-PMP,
and use `/data/torrents` as the download directory. Sonarr and Radarr connect
to it at `http://gluetun:8080`, not `http://qbittorrent:8080`.

## 8. Initial application setup

Use the following order after all services are running.

1. **qBittorrent** — set Web UI authentication, port `6881`, UPnP off,
   NAT-PMP off, and download path `/data/torrents`.
2. **Prowlarr** (`:9696`) — add indexers, then add Sonarr and Radarr under
   *Settings → Apps* using their Compose service names (`http://sonarr:8989`
   and `http://radarr:7878`) and each application's API key.
3. **Sonarr** (`:8989`) — add root folder `/data/media/tv`; add qBittorrent at
   `http://gluetun:8080` with its Web UI credentials; choose
   `/data/torrents` for the completed-download path seen by the client.
4. **Radarr** (`:7878`) — add root folder `/data/media/movies`; configure the
   same qBittorrent endpoint and `/data/torrents` download path.
5. **Bazarr** (`:6767`) — connect Sonarr and Radarr, retaining their roots
   `/data/media/tv` and `/data/media/movies`; enable Portuguese (Brazil) and
   configure the preferred Brazilian Portuguese subtitle providers.
6. **Jellyfin** (`:8096`) — add `/media/movies` and `/media/tv` libraries.
   The Compose file already passes `/dev/dri:/dev/dri`; in Dashboard → Playback
   → Transcoding select the acceleration method suitable for the host GPU.
7. **Seerr** (`:5055`) — connect Jellyfin, Sonarr, and Radarr during its setup
   wizard, using the server addresses/API keys it requests.
8. **Heimdall** (`:80`) — add dashboard links for the service addresses listed
   at the top of this document.

For Jellyfin GPU troubleshooting, the expected devices include `card0`,
`card1`, and `renderD128` on this host:

```bash
docker exec jellyfin ls -lah /dev/dri
docker exec jellyfin id
```

## Verification and troubleshooting

```bash
# Containers and recent logs
docker compose ps
docker logs gluetun --tail=100
docker logs qbittorrent --tail=100

# Mounted drive and container mount paths
findmnt -T ~/server/media/drive
docker inspect sonarr radarr bazarr jellyfin

# Gluetun health and firewall
docker inspect gluetun --format '{{json .State.Health}}'
docker exec gluetun iptables -S

# qBittorrent network namespace and effective configuration
docker inspect qbittorrent --format '{{.HostConfig.NetworkMode}}'
docker exec qbittorrent grep -iE 'port|upnp|nat' /config/qBittorrent/qBittorrent.conf
```

If qBittorrent's UDP trackers fail, first verify that Gluetun is connected,
that port 6881 is configured, and that `iptables -S OUTPUT` includes the UDP
source-port `6881` rule. If Bazarr cannot see a Sonarr or Radarr root, verify
that all three services still mount `./media/drive` at `/data`. If Docker
reports missing `PUID` or `PGID`, re-check `.env`.

After changing Compose or `post-rules.txt`, recreate the stack:

```bash
cd ~/server
docker compose down
docker compose up -d
docker compose ps
```

## Security checklist

- Keep `.env` private (`chmod 600 .env`).
- Never commit `gluetun/*.ovpn`, especially profiles containing cryptographic
  blocks such as `<tls-crypt>` or `<key>`.
- Never commit application config directories, databases, media, downloads,
  or logs; `.gitignore` excludes these paths.
- Keep the service interfaces on the LAN unless you deliberately secure and
  expose them.
