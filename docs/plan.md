# Factorio server on StreamBox: plan, decisions, gotchas

A Factorio (Space Age + mods) server for 3 friends, on the StreamBox media server (Debian 13,
192.168.1.33), **kept as separate from the media server as one machine allows**. The media server's own
repo is `johnnyowens22-dotcom/streambox`; it only records that this exists (its D57) and the D19 exception.

## Decisions

| ID | Date | Decision | Why |
|---|---|---|---|
| F1 | 2026-10-05 | **Router port forward, UDP 34197 only**, to 192.168.1.33 (reserved by MAC, same on Wi-Fi and Ethernet). Hostname **factorio.howoldismoose.com**, Cloudflare DNS (free), DNS-only record kept current by `favonia/cloudflare-ddns`. | Friends must not install anything (rules out Tailscale/playit). CGNAT check passed: the Nighthawk's WAN IP is the public Comcast IP. Squarespace (registrar) has no DDNS. Cloudflare's free proxy can't carry game UDP, so the record is grey-cloud. |
| F2 | 2026-10-07 | **Isolation: own account + rootless Docker.** Account `factorio`: no sudo, no `docker` group, no login shell, not in sshd `AllowUsers`, home `700`. It runs its **own** rootless Docker daemon (systemd user service, linger), so it shares no daemon, images, networks, iptables rules or maintenance jobs with the media server. Own repo (this one), own secrets, own backups. | User's requirement: "completely isolated … connected in as few ways as possible". The system Docker is root: a container escape there would own the whole media server. Under rootless Docker an escape lands as the game container's user, a subuid that owns nothing outside the game's own data. Podman was considered and rejected: the user knows Docker, and rootless Docker isolates the same way. |
| F3 | 2026-10-07 | **Access: game password only, no whitelist.** `require_user_verification` on (players have real factorio.com names, so bans and the admin list work), hidden (not public, not LAN), RCON never published, admins only for commands and pausing. Password: 20+ random letters/digits, enforced by `factorio-settings`. | User's choice: the password is enough. It's the only gate, so it must be strong. If it leaks: change it in `secrets.env`, run `factorio-apply`, ban by name. |
| F4 | 2026-10-07 | **Media side locked away from other accounts** (streambox D56): `/opt/mediaserver` `750`, `/mnt/diskN/pool` `2770`. | The *arr configs (API keys) were world-readable, and the `factorio` account would have been able to read them. |
| F5 | 2026-10-05 | **Follows Steam automatically.** Image `factoriotools/factorio:stable-rootless` (factorio.com "stable" = Steam's default branch). `factorio-update` (every 15 min) pulls; on a new image it backs up and restarts **only when 0 players are online** (asked over RCON from inside the container). | User's choice, an exception to the media server's "pin and update by hand" rule. Never `latest`: that's the experimental branch (2.1.x as of 2026-10-07, while stable is 2.0.77). |
| F6 | 2026-10-07 | **Host firewall: own nftables table `factorio_guard`** (`/etc/factorio/firewall.nft`, `factorio-firewall.service`). In: nothing new from outside the LAN except UDP 34197 (input and forward hooks; system Docker bridges and the LAN allowed). Out: the `factorio` account may reach the internet but **not** the LAN, the box itself (127/8, Docker networks) or link-local, except DNS on the router. | Today the router's NAT is the only barrier, and every media app listens on 0.0.0.0. The outbound rule stops a compromised game server from reaching the *arr APIs or other home devices. It works because rootless Docker's networking (slirp4netns) runs as the `factorio` uid. |
| F7 | 2026-10-07 | **Rootless networking: slirp4netns + slirp4netns port driver, `userland-proxy: false`.** | The documented combination that passes players' real IP addresses to the server (logs, bans). |
| F8 | 2026-10-07 | **Resource caps**: game container `mem_limit 6g`, `pids_limit 512`; DNS updater 128 MB. | The media server (Jellyfin transcodes) keeps the rest of the box's 16 GB. |
| F9 | 2026-10-07 | `stop_grace_period: 120s`. | Docker's default 10 s can kill the server while it writes a big Space Age save. |
| F10 | 2026-10-07 | **Backups**: `factorio-backup` daily at 03:30 and before every update; newest 30 kept in `/home/factorio/backups` (NVMe). Not in the media server's 04:00 backup. | Isolation. Residual risk: an NVMe failure loses both the server and its backups. Open question O1. |

## Open questions

- **O1**: Off-NVMe copy of the saves? Options: a one-way root job copying `/home/factorio/backups` to `/mnt/storage/backups/factorio` (one deliberate link to the media server), or you copying a save to your gaming PC now and then.
- **O2**: `howoldismoose.com` (apex) is proxied (orange cloud) in Cloudflare and its AWS origin `18.218.225.5` didn't answer on 80/443 on 2026-10-07, even directly. Unrelated to this server; check whether the site is meant to be up.

## How it fits together

```
friend ──UDP 34197──► Nighthawk (one forward) ──► box: factorio_guard (input: allow 34197)
                                                   └► slirp4netns (uid factorio) ─► container "factorio"
                                                        (rootless dockerd of account factorio; container uid 1000 = a subuid)
factorio-ddns ─HTTPS─► Cloudflare API (updates factorio.howoldismoose.com A record every 5 min)
```

| Where | What |
|---|---|
| `/home/factorio/compose.yml` | the two containers |
| `/home/factorio/.config/factorio/secrets.env` (600) | factorio.com username/token, game password, Cloudflare token |
| `/home/factorio/generated/` | `server-settings.json`, `server-adminlist.json`, built from secrets by `factorio-settings` |
| `/home/factorio/data/` | the game's folder (`saves`, `mods`, `config`), owned by the container's subuid |
| `/home/factorio/backups/` | save copies |
| `/home/factorio/bin/` | `factorio-apply`, `-update`, `-backup`, `-docker`, `-settings`, `-lib` |
| `~/.config/systemd/user/` | `docker.service` (rootless daemon), `factorio-update.timer`, `factorio-backup.timer` |
| `/etc/factorio/firewall.nft`, `factorio-firewall.service` | host firewall |

**Shared with the media server, unavoidably:** the kernel (only a VM avoids this), CPU/RAM/disk (capped, F8),
NVMe space, the home upload link, the LAN IP and router, the journal, and unattended-upgrades' 04:30 reboots (D14).

## Gotchas

| # | Gotcha | Handling |
|---|---|---|
| FG1 | Debian's `/etc/nftables.conf` starts with `flush ruleset`, which also wipes Docker's rules. | `nftables.service` stays disabled (install.sh warns if not); our table loads from its own unit. |
| FG2 | The new image appears hours after a release; friends whose Steam updated first can't join until then. | Wait (the server updates within 15 min of the image), or Steam → Factorio → Properties → Betas → previous version. |
| FG3 | The server won't restart for an update while anyone is online. | By design. It updates on the first check with 0 players. |
| FG4 | 04:30 auto-reboots (only when an update needs one) drop players for a few minutes. | Accepted. The server returns on its own with the last autosave (every 10 min). |
| FG5 | At home, the public hostname may not work (NAT loopback on the R8000 is untested). | At home, connect to `192.168.1.33`. |
| FG6 | `qBittorrent` saturating the Comcast upload causes lag in the game. | If it happens, cap qBittorrent's upload (media-server change, by agreement). |
| FG7 | Re-running `install.sh` restarts the account's Docker daemon, which restarts the server. | Run it when nobody is playing. |
| FG8 | The game folder belongs to the container's subuid, so the `factorio` account can read but not edit it. | Saves/mods go in through `install.sh import`. |
| FG9 | `secrets.env` is a plain env file: no quotes, no comments after a value, password letters/digits only. | `factorio-settings` refuses a weak or symbol-containing password. |
| FG10 | Claude runs as `streambox` without sudo, so it can't operate this server. | Every command below is run by the user. |

## Build order

1. ✅ Router hardening (DMZ off, no remote management on this firmware, IPv6 disabled), Cloudflare zone active, this repo + deploy key.
2. You: `sudo ~/factorio-server/install.sh` (account, rootless Docker, firewall, timers).
3. You: fill in `secrets.env`; copy the save to `~/factorio-staging/` and mods to `~/factorio-staging/mods/`; `sudo ~/factorio-server/install.sh import ~/factorio-staging`; `sudo -u factorio /home/factorio/bin/factorio-apply`.
4. Test on the LAN: join `192.168.1.33` from the gaming PC. Check: the firewall table is loaded, the `factorio` account can't reach `192.168.1.33:8989` (Sonarr), `factorio.howoldismoose.com` resolves to the home IP.
5. Router: add the UDP 34197 forward. Then from outside (phone on cellular / a friend): join test, and a port scan showing nothing else open.
6. Streambox repo: D19 amended ("except UDP 34197 for Factorio").

## Operating it (all as you, with sudo)

```sh
sudo -u factorio /home/factorio/bin/factorio-docker ps                    # status
sudo -u factorio /home/factorio/bin/factorio-docker logs -f factorio      # live log
sudo -u factorio /home/factorio/bin/factorio-docker exec factorio rcon '/players online'
sudo -u factorio nano /home/factorio/.config/factorio/secrets.env         # change password etc.
sudo -u factorio /home/factorio/bin/factorio-apply                        # apply secrets / start
sudo -u factorio /home/factorio/bin/factorio-backup manual                # back up now
sudo journalctl _UID=$(id -u factorio) -n 50                                   # update/backup timer output
```
