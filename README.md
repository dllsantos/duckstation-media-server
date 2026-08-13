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
| qBittorrent | The download client that receives torrent downloads. By default, its traffic goes through the VPN. | `http://SERVER_IP:8080` | `/data` |
| Gluetun | The optional VPN connection and firewall that protects qBittorrent in the default setup; it has no normal web page. | — | — |
| Bazarr | Finds and downloads subtitles for the movies and episodes managed by Radarr and Sonarr. | `http://SERVER_IP:6767` | `/data` |

Jellyfin uses host networking. In the default VPN setup, qBittorrent shares
Gluetun's network namespace, so its Web UI and torrent ports are published by
**Gluetun**, not qBittorrent.

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

## Choose whether to use a VPN

The default setup uses NordVPN through Gluetun and is the recommended choice
when qBittorrent is used. It keeps qBittorrent's traffic in the VPN network
namespace and activates Gluetun's firewall. Follow the NordVPN instructions in
section 4, then use the normal `docker compose ...` commands in this guide.

If you deliberately do **not** want to use a VPN, use the included override
file whenever this guide says `docker compose`:

```bash
docker compose -f docker-compose.yml -f docker-compose.no-vpn.yml up -d
```

This starts qBittorrent directly on the server and does not start Gluetun. Its
torrent traffic will use your normal internet connection, so understand the
privacy and legal implications before choosing it. In this mode, use
`http://qbittorrent:8080` when Sonarr or Radarr asks for the qBittorrent
address; do not use `http://gluetun:8080`.

NordVPN is the documented default, but other VPN providers can also work when
they supply a compatible OpenVPN configuration file and manual-connection
credentials. This Compose file already uses Gluetun's `custom` OpenVPN mode:
replace the NordVPN `.ovpn` profile and credentials with your provider's
values, and check that provider's documentation before enabling it.

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

### Optional: use the setup script

For a new server, the included script automates the safe preparation work: it
creates these directories, creates `.env` with your user IDs and timezone, and
shows the server's IP address. It does **not** install Docker, mount a drive,
or handle VPN credentials, because those decisions need your review.

```bash
./setup.sh
```

After finishing the remaining manual steps, the script can validate and start
the default NordVPN setup:

```bash
./setup.sh --vpn --start
```

For the no-VPN option, use `--no-vpn` instead. At any time, run
`./setup.sh --vpn --doctor` or `./setup.sh --no-vpn --doctor` for a concise
checklist of common setup problems.

## 3. Create `.env`

Get the numeric owner IDs from the account that owns `~/server`:

```bash
id -u
id -g
```

Edit `.env` and replace every placeholder. `NORDVPN_USERNAME` and
`NORDVPN_PASSWORD` are NordVPN **manual/OpenVPN service credentials**, not
necessarily the normal Nord Account login. If you choose the no-VPN override,
you can leave those two values unused.

```env
NORDVPN_USERNAME=your_nordvpn_service_username
NORDVPN_PASSWORD=your_nordvpn_service_password
PUID=1000
PGID=1000
TZ=Europe/Lisbon
```

`PUID` and `PGID` are used by Prowlarr, Sonarr, Radarr, Bazarr, qBittorrent,
and Heimdall. `.env` is ignored by Git and must never be committed.

## 4. Install the NordVPN OpenVPN profile (default VPN setup)

Skip this section only if you chose the no-VPN override above.

You need an active NordVPN subscription. Sign in to your
[Nord Account manual-setup page](https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/),
then:

1. Open the **Service credentials** tab and copy the username and password
   shown there into `.env` as `NORDVPN_USERNAME` and `NORDVPN_PASSWORD`.
   These are special credentials for manual VPN connections—not necessarily
   the email address and password used to sign in to Nord Account.
2. Open the **OpenVPN configuration files** tab. Choose a recommended server
   (or a server in your preferred country) and download its **UDP**
   configuration file. UDP matches this project's expected OpenVPN profile.
3. Move the downloaded `.ovpn` file into the `gluetun` folder and rename it to
   the exact filename expected by Compose:

```bash
mv ~/Downloads/your-downloaded-server.udp.ovpn \
  ~/server/gluetun/pt134.nordvpn.com.udp_2.6.ovpn
```

If your project is not in `~/server`, replace that part of the command with
its actual location. NordVPN's [manual OpenVPN guide](https://support.nordvpn.com/hc/en-us/articles/20164827795345-How-to-set-up-a-manual-connection-on-Linux-using-OpenVPN)
also explains how to choose and download a server configuration.

After moving it, the profile must be at this exact project-relative path:

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

If you chose no-VPN mode, use this command instead:

```bash
docker compose -f docker-compose.yml -f docker-compose.no-vpn.yml config
docker compose -f docker-compose.yml -f docker-compose.no-vpn.yml up -d
docker compose -f docker-compose.yml -f docker-compose.no-vpn.yml ps
```

The remaining Gluetun checks apply only to the default VPN setup.

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

## 7. Gluetun and qBittorrent networking (default VPN setup)

Skip this section in no-VPN mode.

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
and use `/data/torrents` as the download directory. In the default VPN setup,
Sonarr and Radarr connect to it at `http://gluetun:8080`; in no-VPN mode, they
use `http://qbittorrent:8080`.

## 8. Initial application setup

Once `docker compose ps` shows the containers running, open the web pages from
a device on your home network. Use `http://SERVER_IP:PORT`, with the address
you found earlier. Most applications will show a first-run wizard. Create a
strong, unique administrator account in each one before continuing.

The order below matters: qBittorrent receives downloads; Sonarr and Radarr
manage them; Prowlarr supplies searches; then the remaining applications use
the resulting library. When an application asks for an address for another
application, use the Docker service address shown below (for example,
`http://sonarr:8989`), not `SERVER_IP`. These addresses work only between
containers, which is exactly what is needed here.

1. **Set up qBittorrent** — open `http://SERVER_IP:8080`.

   - Sign in using the credentials shown in qBittorrent's first-run screen or
     startup log, then immediately set your own Web UI username and strong
     password.
   - In *Settings/Options → Connection*, set the listening port to `6881`.
     Disable UPnP and NAT-PMP so qBittorrent does not ask your router to open
     ports outside the VPN configuration.
   - In *Settings/Options → Downloads*, set the default save path to
     `/data/torrents`. Leave completed downloads there; Sonarr and Radarr will
     import and rename copies into the media library.
   - Save the settings. The address other containers use depends on your
     choice: `http://gluetun:8080` in the default VPN setup, or
     `http://qbittorrent:8080` in no-VPN mode.

2. **Set up Sonarr for TV shows** — open `http://SERVER_IP:8989` and complete
   its first-run prompts.

   - Go to *Settings → Media Management → Root Folders* and add
     `/data/media/tv`. This is where finished episodes will be organised.
   - Go to *Settings → Download Clients*, add qBittorrent, and use
     `http://gluetun:8080` in the default VPN setup or
     `http://qbittorrent:8080` in no-VPN mode. Enter the Web UI username and
     password created in the previous step. Set the category to something
     memorable, such as `tv`, if you want Sonarr's downloads grouped
     separately.
   - Confirm the completed-download directory it sees is `/data/torrents`.
     It must match qBittorrent's path exactly because both containers mount
     the same drive as `/data`.
   - Copy the API key from *Settings → General*. Keep it available for
     Prowlarr, Bazarr, and Seerr; treat it like a password.

3. **Set up Radarr for movies** — open `http://SERVER_IP:7878`. Its setup is
   the same as Sonarr's, including the correct qBittorrent address for your
   VPN choice, but use `/data/media/movies` as the root folder and a category
   such as `movies`. Copy its API key from *Settings → General* as well.

4. **Set up Prowlarr for indexers** — open `http://SERVER_IP:9696`.

   - Add only indexers and accounts that you are permitted to use. Prowlarr
     keeps these search connections in one place instead of configuring each
     one separately in Sonarr and Radarr.
   - Open *Settings → Apps* and add Sonarr using `http://sonarr:8989` and the
     Sonarr API key. Add Radarr using `http://radarr:7878` and its API key.
   - Use Prowlarr's *Test* and *Save* controls, then sync the apps. New
     indexers added in Prowlarr should now appear in Sonarr and Radarr.

5. **Set up Bazarr for subtitles** — open `http://SERVER_IP:6767`.

   - Connect Sonarr at `http://sonarr:8989` and Radarr at
     `http://radarr:7878`, using the API keys you copied above.
   - Check that Bazarr sees `/data/media/tv` and `/data/media/movies` as the
     library locations. If it does not, stop and verify the drive mount before
     downloading anything.
   - Choose the subtitle languages you want—for example, Portuguese (Brazil)—
     then configure subtitle providers you have permission to use.

6. **Set up Jellyfin for watching** — open `http://SERVER_IP:8096` and create
   the first administrator account.

   - Create a *Movies* library that points to `/media/movies`, and a *Shows*
     or *TV* library that points to `/media/tv`. Jellyfin can read this media
     but cannot change it.
   - Let Jellyfin scan the folders, then create separate user accounts for
     people who will watch from the server.
   - The Compose file already provides the host's graphics devices. If the
     server has a compatible GPU, visit *Dashboard → Playback → Transcoding*
     and choose the acceleration method appropriate for it. Leave this off if
     you are unsure; streaming still works without hardware transcoding.

7. **Set up Seerr for requests** — open `http://SERVER_IP:5055` and follow the
   wizard. Connect it to Jellyfin, Sonarr, and Radarr using the addresses and
   API keys it requests. It is a good place to give friends their own accounts
   so they can request media without access to the admin tools.

8. **Set up Heimdall as the home page** — open `http://SERVER_IP/` and create
   its administrator account. Add tiles for Jellyfin, Seerr, Sonarr, Radarr,
   Prowlarr, qBittorrent, and Bazarr using the `SERVER_IP` addresses in the
   service table. Once this is done, Heimdall is the one bookmark most people
   will need.

Try a single movie or episode request from Seerr (or add one directly in
Sonarr/Radarr) before adding a large library. Check that it downloads to
`/data/torrents`, is imported into the right media folder, and appears in
Jellyfin. That confirms the whole chain is working.

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
