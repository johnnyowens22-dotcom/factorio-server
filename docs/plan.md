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
| F7 | 2026-10-07 | **Rootless networking: slirp4netns + slirp4netns port driver.** `userland-proxy` stays at Docker's default. | The slirp4netns port driver passes players' real IP addresses through (verify on the first outside join; if not, only the log loses real IPs, bans are by name). `userland-proxy: false` was tried first and broke the daemon: it needs the `br_netfilter` kernel module, which is host-wide and would also change the media server's Docker networking, so it was dropped (FG11). |
| F8 | 2026-10-07 | **Resource caps**: game container `mem_limit 6g`, `pids_limit 512`; DNS updater 128 MB. | The media server (Jellyfin transcodes) keeps the rest of the box's 16 GB. |
| F9 | 2026-10-07 | `stop_grace_period: 120s`. | Docker's default 10 s can kill the server while it writes a big Space Age save. |
| F10 | 2026-10-07 | **Backups**: `factorio-backup` daily at 03:30 and before every update; newest 30 kept in `/home/factorio/backups` (NVMe). Not in the media server's 04:00 backup. | Isolation. Residual risk: an NVMe failure loses both the server and its backups. Open question O1. |
| F11 | 2026-10-07 | **`sudo factorio-report`** (`/usr/local/sbin`, installed by `install.sh`): server status, everyone who has ever joined (`/players`), refused connections grouped by IP/name/reason (container log, since its last start), the firewall counters with a verdict (output counter > 0 = ALERT), DNS record vs home IP, newest backup. On demand only. | User asked how to spot unwanted traffic. On demand, not pushed (streambox D15). Firewall drop logging was offered and not taken. |
| F12 | 2026-10-07 | **`non_blocking_saving: true`.** The server forks to write autosaves, so players don't freeze while it saves. Takes effect at the next restart (the settings file is read at startup); `install.sh` now rebuilds the settings before it restarts the account's Docker. | User's choice. Server-side only: with `autosave_only_on_server` the players' PCs (one is Windows) don't save anyway, and Wube's own note says Windows clients' autosaving is disabled with it on. Wube still calls it highly experimental; the daily + pre-update backups are the fallback. Saves were ~1 MB when enabled, so the gain grows with the base. |

## Open questions

- **O1**: Off-NVMe copy of the saves? Options: a one-way root job copying `/home/factorio/backups` to `/mnt/storage/backups/factorio` (one deliberate link to the media server), or you copying a save to your gaming PC now and then.
- ~~**O3**~~ Resolved 2026-10-07: UPnP turned **off**. The router log had shown internet scanners reaching 192.168.1.19 (probably the user's Steam Deck) on Steam ports 27015/27032 through UPnP; with UPnP off those openings are gone. If a game ever needs a port, add one targeted forward instead.
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
| FG5 | Joining by hostname from inside the home needs NAT loopback on the router. | **Works** on the R8000 (2026-10-07: a home join via `factorio.howoldismoose.com` arrived from the public IP). `192.168.1.33` also works at home. |
| FG6 | `qBittorrent` saturating the Comcast upload causes lag in the game (measured 2026-10-07: jitter 33 ms, spikes to 141 ms at its 2.5 MiB/s cap). | **Done:** streambox D58 caps torrent upload at 1 MiB/s (jitter 1.7 ms, worst 20 ms). If lag returns, check the upload first. |
| FG7 | Re-running `install.sh` restarts the account's Docker daemon, which restarts the server. | Run it when nobody is playing. |
| FG8 | The game folder belongs to the container's subuid, so the `factorio` account can read but not edit it. | Saves/mods go in through `install.sh import`. |
| FG9 | `secrets.env` is a plain env file: no quotes, no comments after a value, password letters/digits only. | `factorio-settings` refuses a weak or symbol-containing password. |
| FG10 | Claude runs as `streambox` without sudo, so it can't operate this server. | Every command below is run by the user. |
| FG11 | Rootless Docker with `userland-proxy: false` won't start without `br_netfilter` (`stat /proc/sys/net/bridge/bridge-nf-call-iptables: no such file`). | Don't load `br_netfilter` (host-wide, touches the media server's Docker). Keep the default userland proxy (F7). |
| FG12 | `sudo -u factorio …` from your home folder fails (`stat .: permission denied`): sudo keeps the current folder, which `factorio` may not enter. | Fixed in `factorio-lib` (scripts `cd` to the account's home). Before that fix is installed, prefix commands with `cd / &&`. |
| FG13 | Netgear refused the forward ("port(s) are being used by other configurations") because an old **port triggering** rule covered 34197. UPnP had no mappings (queried 2026-10-07). | Removed the old triggering rule. The router checks forwarding, triggering, UPnP, ReadySHARE and remote management for overlaps. |
| FG14 | A friend's first join is refused in steps, shown in the log as `Refusing connection … UserVerificationMissing` (not logged into factorio.com in the game), `PasswordMissing`, then `ModsMismatch`. | Expected. Friend: Settings → Other → log in with the factorio.com account (Steam owners: Steam login links it); enter the password; accept *sync mods with server*, then rejoin. |
| FG15 | The firewall's "new traffic from outside" counter also caught harmless stray packets (late replies after a connection closed), so the report warned on 1 packet. | `ct state invalid` packets now have their own counter, shown as harmless. Firewall/report changes install with `sudo ./install.sh host`, which doesn't restart the game. |
| FG16 | After FG15 the "new from outside" counter still caught 1 packet within minutes of a reload. Likely a Wi-Fi device asking for an address (DHCP broadcast from `0.0.0.0`), which isn't "outside". | Broadcast/multicast (never forwarded from the internet) now accepted before the drop. Remaining drops are logged, rate-limited (6/min), prefix `factorio_guard drop:` (`ALERT:` for the factorio account reaching the LAN); `factorio-report` shows the last 8 since boot. |

## Build order

1. ✅ Router hardening (DMZ off, no remote management on this firmware, IPv6 disabled), Cloudflare zone active, this repo + deploy key.
2. ✅ 2026-10-07 `sudo ~/factorio-server/install.sh` (account uid 1001, rootless Docker, firewall, timers). First run failed on `userland-proxy: false` (FG11).
3. ✅ 2026-10-07 Fill in `secrets.env`; copy the save to `~/factorio-staging/` and mods to `~/factorio-staging/mods/`; `sudo ~/factorio-server/install.sh import ~/factorio-staging`; `sudo -u factorio /home/factorio/bin/factorio-apply`. Save (map 2.0.77) and mods loaded; first apply hit FG12.
4. ✅ 2026-10-07 LAN tests passed: joined `192.168.1.33` from the gaming PC; `factorio_guard` loaded; the `factorio` account gets *connection refused* to Sonarr `:8989` and 200 from factorio.com; from inside the game container Sonarr times out (slirp4netns turns the reject into a drop); `factorio.howoldismoose.com` = the public IP; both timers scheduled.
5. ✅ 2026-10-07 UDP 34197 forward added (an old port-triggering rule on 34197 had to go first, FG13). ShieldsUP *All Service Ports*: all stealth. ✅ 2026-10-07 first outside join by a friend; the log shows their real public IP (F7 confirmed).
6. ✅ 2026-10-07 Streambox repo: D19 amended ("except UDP 34197 for Factorio").
7. ⏳ Reboot test while watching: firewall, rootless Docker (linger) and both containers come back by themselves. Check the first 03:30 backup exists in `/home/factorio/backups`.

## Operating it (all as you, with sudo)

```sh
sudo factorio-report                                                      # security + health summary
sudo ~/factorio-server/install.sh host                                    # firewall/report changes only (no game restart)
sudo -u factorio /home/factorio/bin/factorio-docker ps                    # status
sudo -u factorio /home/factorio/bin/factorio-docker logs -f factorio      # live log
sudo -u factorio /home/factorio/bin/factorio-docker exec factorio rcon '/players online'
sudo -u factorio nano /home/factorio/.config/factorio/secrets.env         # change password etc.
sudo -u factorio /home/factorio/bin/factorio-apply                        # apply secrets / start
sudo -u factorio /home/factorio/bin/factorio-backup manual                # back up now
sudo journalctl _UID=$(id -u factorio) -n 50                                   # update/backup timer output
```
