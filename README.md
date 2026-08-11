# Home Media Server — Setup Guide

This README summarizes the complete setup performed for the Docker-based home media server.

## 1. Server structure

The main directory is:

```bash
~/server
```

Suggested structure:

```text
~/server/
├── docker-compose.yml
├── .env
├── gluetun/
│   ├── pt134.nordvpn.com.udp_2.6.ovpn
│   └── scripts/
├── jellyfin/
│   ├── config/
│   └── cache/
├── qbittorrent/
│   └── config/
├── prowlarr/
│   └── config/
├── sonarr/
│   └── config/
├── radarr/
│   └── config/
├── bazarr/
│   └── config/
├── seerr/
│   └── config/
├── heimdall/
│   └── config/
└── media/
    └── drive/
        ├── torrents/
        └── media/
            ├── movies/
            └── tv/
```

Using `~` makes the configuration independent of the Linux username.

---

## 2. External NTFS drive

The external drive is mounted at:

```text
~/server/media/drive
```

Check the filesystem:

```bash
lsblk -f
```

Check the active mount:

```bash
findmnt -T ~/server/media/drive
```

The `/etc/fstab` entry should use the drive UUID rather than `/dev/sda1`, for example:

```fstab
UUID=YOUR-UUID-HERE ~/server/media/drive ntfs3 defaults,uid=1000,gid=1000,umask=022,nofail,x-systemd.device-timeout=10 0 0
```

After changing `fstab`:

```bash
sudo systemctl daemon-reload
sudo mount -a
```

Verify:

```bash
findmnt -T ~/server/media/drive
```

---

## 3. NTFS hardlinks

Hardlinks are required so Sonarr/Radarr can import torrents without unnecessarily duplicating the files.

Test them:

```bash
touch ~/server/media/drive/torrents/test-hardlink

ln ~/server/media/drive/torrents/test-hardlink    ~/server/media/drive/media/test-hardlink

ls -li   ~/server/media/drive/torrents/test-hardlink   ~/server/media/drive/media/test-hardlink
```

Both files must show the same inode number.

Example:

```text
2358 ... media/test-hardlink
2358 ... torrents/test-hardlink
```

This confirms that hardlinks work on the mounted filesystem.

Remove the test:

```bash
rm ~/server/media/drive/torrents/test-hardlink
rm ~/server/media/drive/media/test-hardlink
```

---

## 4. Environment variables

Keep sensitive NordVPN credentials out of `docker-compose.yml`.

Create:

```bash
nano ~/server/.env
```

Example:

```env
NORDVPN_USERNAME=your_nordvpn_service_username
NORDVPN_PASSWORD=your_nordvpn_service_password
TZ=Europe/Lisbon
```

The NordVPN username/password used here should be the credentials supplied for OpenVPN, not necessarily the normal Nord Account login.

Protect the file:

```bash
chmod 600 ~/server/.env
```

Do not commit `.env` to Git.

---

## 5. Gluetun + NordVPN

Gluetun provides the VPN network namespace for qBittorrent.

The NordVPN OpenVPN configuration is stored under:

```text
~/server/gluetun/
```

Example:

```text
~/server/gluetun/pt134.nordvpn.com.udp_2.6.ovpn
```

The OpenVPN configuration contains settings such as:

```text
proto udp
remote ...
remote-cert-tls server
tls-version-min 1.2
auth-user-pass
```

The compose configuration uses:

```yaml
VPN_SERVICE_PROVIDER: custom
VPN_TYPE: openvpn
OPENVPN_CUSTOM_CONFIG: /gluetun/custom.conf
```

qBittorrent uses:

```yaml
network_mode: service:gluetun
```

This means qBittorrent shares Gluetun's network namespace and cannot bypass the VPN.

---

## 6. Verify the VPN

Check Gluetun:

```bash
docker compose ps
```

It should show:

```text
gluetun ... Up ... (healthy)
```

Check the public IP from inside the Gluetun network:

```bash
docker run --rm   --network container:gluetun   curlimages/curl:latest   https://ifconfig.me
```

The returned IP must be the VPN IP, not the normal ISP IP.

You can also check:

```bash
docker logs gluetun --tail=50
```

Look for:

```text
Initialization Sequence Completed
Public IP address is ...
```

---

## 7. Gluetun firewall

The torrent port is:

```text
6881
```

Gluetun must allow both TCP and UDP:

```env
FIREWALL_VPN_INPUT_PORTS=6881
```

Verify:

```bash
docker exec gluetun sh -c 'env | grep FIREWALL_VPN_INPUT_PORTS'
```

Expected:

```text
FIREWALL_VPN_INPUT_PORTS=6881
```

Check the firewall:

```bash
docker exec gluetun iptables -S
```

You should see rules similar to:

```text
-A INPUT -i tun0 -p tcp --dport 6881 -j ACCEPT
-A INPUT -i tun0 -p udp --dport 6881 -j ACCEPT
```

---

## 8. qBittorrent UDP tracker fix

During troubleshooting, UDP trackers were failing even though general VPN connectivity worked.

The additional iptables rule that solved the issue was:

```bash
iptables -A OUTPUT -p udp --sport 6881 -j ACCEPT
```

Because manually executing this inside the container is not persistent, it was moved into a Gluetun startup script.

Create:

```bash
mkdir -p ~/server/gluetun/scripts
nano ~/server/gluetun/scripts/custom.sh
```

Example script:

```sh
#!/bin/sh

iptables -A OUTPUT -p udp --sport 6881 -j ACCEPT
```

Make it executable:

```bash
chmod +x ~/server/gluetun/scripts/custom.sh
```

Important: do not use the script as the Gluetun Docker `command` in a way that replaces the Gluetun executable. The script should be executed as part of the container startup mechanism supported by the installed Gluetun version.

If the container reports:

```text
ERROR command is unknown: /gluetun/scripts/custom.sh
```

the script was incorrectly supplied as the main Gluetun command.

After changing the startup configuration:

```bash
docker compose down
docker compose up -d
```

Verify:

```bash
docker exec gluetun iptables -S OUTPUT
```

The UDP source-port rule should be present.

---

## 9. qBittorrent

qBittorrent uses:

```text
Web UI: http://SERVER-IP:8080
Torrent port: 6881
```

The Docker setup exposes:

```yaml
ports:
  - "8080:8080"
  - "6881:6881"
  - "6881:6881/udp"
```

qBittorrent is attached to Gluetun:

```yaml
network_mode: service:gluetun
```

Verify:

```bash
docker inspect qbittorrent   --format 'Status={{.State.Status}} RestartCount={{.RestartCount}} NetworkMode={{.HostConfig.NetworkMode}}'
```

Expected:

```text
NetworkMode=container:<gluetun-container-id>
```

The qBittorrent configuration should use:

```text
Port = 6881
UPnP = disabled
NAT-PMP = disabled
```

The configuration can be checked with:

```bash
docker exec qbittorrent grep -iE 'port|upnp|nat' /config/qBittorrent/qBittorrent.conf
```

---

## 10. qBittorrent Web UI authentication

The qBittorrent API can return:

```text
403 Forbidden
```

after too many failed authentication attempts.

Example:

```text
Your IP address has been banned after too many failed authentication attempts.
```

If this happens, wait for the temporary ban to expire and make sure Sonarr/Radarr are using the correct qBittorrent credentials.

Avoid repeatedly testing incorrect credentials.

---

## 11. Prowlarr

Prowlarr runs on:

```text
http://SERVER-IP:9696
```

Prowlarr is used to manage indexers and synchronize them with Sonarr and Radarr.

Basic workflow:

```text
Prowlarr
   ↓
Indexers
   ↓
Sonarr / Radarr
   ↓
qBittorrent
```

---

## 12. Sonarr

Sonarr runs on:

```text
http://SERVER-IP:8989
```

Recommended root directory:

```text
/data/media/tv
```

qBittorrent download directory:

```text
/data/torrents
```

Sonarr and qBittorrent must see the same underlying filesystem structure so hardlinks work correctly.

---

## 13. Radarr

Radarr runs on:

```text
http://SERVER-IP:7878
```

Recommended root directory:

```text
/data/media/movies
```

qBittorrent download directory:

```text
/data/torrents
```

Like Sonarr, Radarr should use the same filesystem namespace as qBittorrent.

---

## 14. Docker path mapping

The host directory:

```text
~/server/media/drive
```

is mounted into the media-management containers as:

```text
/data
```

Therefore:

```text
Host:
~/server/media/drive/torrents
        ↓
Container:
/data/torrents
```

and:

```text
Host:
~/server/media/drive/media/movies
        ↓
Container:
/data/media/movies
```

```text
Host:
~/server/media/drive/media/tv
        ↓
Container:
/data/media/tv
```

This common `/data` mapping is important for hardlinks.

---

## 15. Bazarr

Bazarr runs on:

```text
http://SERVER-IP:6767
```

Bazarr uses the same media paths:

```text
/data/media/tv
/data/media/movies
```

If Bazarr reports:

```text
This Sonarr root directory does not seem to be accessible by Bazarr
```

or:

```text
This Radarr root directory does not seem to be accessible by Bazarr
```

verify that Bazarr has the same `/data` bind mount as Sonarr/Radarr.

For Brazilian Portuguese subtitles, configure subtitle providers in Bazarr and enable:

```text
Portuguese (Brazil)
```

as the desired subtitle language.

---

## 16. Jellyfin

Jellyfin runs in host network mode:

```yaml
network_mode: host
```

Media is mounted read-only:

```text
/data/media
```

Jellyfin is available at:

```text
http://SERVER-IP:8096
```

---

## 17. Jellyfin hardware transcoding

The host must expose `/dev/dri` to the Jellyfin container.

Check:

```bash
docker exec jellyfin ls -lah /dev/dri
```

Expected devices include:

```text
card0
card1
renderD128
```

Check:

```bash
docker exec jellyfin ls -l /dev/dri/renderD128
```

The container must have access to the appropriate GPU device/group.

Inside the container:

```bash
docker exec jellyfin id
docker exec jellyfin getent group video
```

Then enable hardware acceleration in:

```text
Jellyfin
→ Dashboard
→ Playback
→ Transcoding
```

Select the hardware acceleration method appropriate for the host GPU.

---

## 18. Seerr

Seerr runs on:

```text
http://SERVER-IP:5055
```

It integrates with:

```text
Jellyfin
Sonarr
Radarr
```

Typical request flow:

```text
User
 ↓
Seerr
 ↓
Sonarr / Radarr
 ↓
Prowlarr
 ↓
qBittorrent
 ↓
Media library
 ↓
Jellyfin
```

---

## 19. Heimdall

Heimdall is used as the dashboard for all services.

The server IP used during setup was:

```text
192.168.1.64
```

Typical links:

```text
Heimdall:
http://192.168.1.64/

Jellyfin:
http://192.168.1.64:8096

qBittorrent:
http://192.168.1.64:8080

Prowlarr:
http://192.168.1.64:9696

Sonarr:
http://192.168.1.64:8989

Radarr:
http://192.168.1.64:7878

Bazarr:
http://192.168.1.64:6767

Seerr:
http://192.168.1.64:5055
```

If the server receives a different LAN IP in the future, update these links.

---

## 20. Useful diagnostics

### Check all containers

```bash
docker compose ps
```

### Follow Gluetun logs

```bash
docker logs -f gluetun
```

### Check qBittorrent logs

```bash
docker logs qbittorrent --tail=50
```

### Check Gluetun health

```bash
docker inspect gluetun --format '{{json .State.Health}}'
```

### Check VPN IP

```bash
docker run --rm   --network container:gluetun   curlimages/curl:latest   https://ifconfig.me
```

### Check mounted drive

```bash
findmnt -T ~/server/media/drive
```

### Check Docker mounts

```bash
docker inspect jellyfin
docker inspect sonarr
docker inspect radarr
docker inspect bazarr
```

### Check GPU devices

```bash
docker exec jellyfin ls -lah /dev/dri
```

### Check Gluetun firewall

```bash
docker exec gluetun iptables -S
```

### Check UDP port rule

```bash
docker exec gluetun iptables -S OUTPUT
```

---

## 21. Restart procedure

After changing `docker-compose.yml`:

```bash
cd ~/server
docker compose down
docker compose up -d
```

Then check:

```bash
docker compose ps
```

If something is restarting:

```bash
docker logs <container-name> --tail=100
```

For example:

```bash
docker logs gluetun --tail=100
docker logs qbittorrent --tail=100
```

---

## 22. Final architecture

```text
                         Internet
                            │
                            ▼
                     ┌─────────────┐
                     │   Router    │
                     └──────┬──────┘
                            │
                     ┌──────▼──────┐
                     │ Docker Host │
                     └──────┬──────┘
                            │
             ┌──────────────┴──────────────┐
             │                             │
             ▼                             ▼
       ┌───────────┐                 ┌───────────┐
       │  Gluetun  │                 │  Jellyfin │
       │ NordVPN   │                 │           │
       └─────┬─────┘                 └─────┬─────┘
             │                             │
             ▼                             │
       ┌───────────┐                        │
       │qBittorrent│                        │
       └─────┬─────┘                        │
             │                              │
             ▼                              │
       ~/server/media/drive                 │
             │                              │
       ┌─────┴─────┐                        │
       │           │                        │
       ▼           ▼                        ▼
   torrents      media                  Playback
                 │
          ┌──────┴──────┐
          │             │
          ▼             ▼
       movies          tv
          │             │
          └──────┬──────┘
                 │
        ┌────────┴────────┐
        │                 │
      Radarr            Sonarr
        │                 │
        └────────┬────────┘
                 │
              Prowlarr
                 │
              Indexers

       Bazarr → subtitles
       Seerr  → requests
       Heimdall → dashboard
```

---

## 23. Final checklist

Before considering the server complete:

- [ ] External drive mounts automatically through `/etc/fstab`
- [ ] NTFS hardlinks work
- [ ] Gluetun is healthy
- [ ] Public IP is the VPN IP
- [ ] qBittorrent uses Gluetun's network namespace
- [ ] TCP 6881 is allowed
- [ ] UDP 6881 is allowed
- [ ] UDP source-port rule is persistent
- [ ] qBittorrent Web UI works
- [ ] qBittorrent is not firewalled
- [ ] Prowlarr is connected to Sonarr
- [ ] Prowlarr is connected to Radarr
- [ ] Sonarr is connected to qBittorrent
- [ ] Radarr is connected to qBittorrent
- [ ] Sonarr root path is `/data/media/tv`
- [ ] Radarr root path is `/data/media/movies`
- [ ] qBittorrent downloads to `/data/torrents`
- [ ] Bazarr can access both media directories
- [ ] Bazarr has Portuguese (Brazil) enabled
- [ ] Jellyfin can access `/data/media`
- [ ] `/dev/dri/renderD128` is available to Jellyfin
- [ ] Jellyfin hardware transcoding is configured
- [ ] Seerr is connected to Jellyfin
- [ ] Seerr is connected to Sonarr/Radarr
- [ ] Heimdall contains links to all services

---

## 24. Important security notes

Do not publish these files or credentials:

```text
.env
*.ovpn
qBittorrent configuration files
```

The `.env` file contains VPN credentials and should remain private.

If VPN credentials are ever exposed publicly, regenerate/revoke them immediately.

Keep the media-server interfaces restricted to your LAN unless there is a specific reason to expose them externally.
