# factorio-server

Factorio (Space Age + mods) server for a few friends, on the StreamBox media server, isolated from it:
own account, own rootless Docker daemon, own firewall table, own secrets and backups.

**Status (2026-10-07):** running and reachable from the internet (UDP 34197). Left: first outside join (real-IP check), reboot test. See the build order in [docs/plan.md](docs/plan.md).

- Plan, decisions (F1…), open questions, gotchas, day-to-day commands: [docs/plan.md](docs/plan.md)
- Install / update: `sudo ./install.sh` · compare repo vs box: `./install.sh --check`
- Join: `factorio.howoldismoose.com` (port 34197, the default) with the game password. At home: `192.168.1.33`.

| Path in repo | Installed to |
|---|---|
| `files/home/` | `/home/factorio/` (owner `factorio`; `config/` → `.config/`) |
| `files/etc/` | `/etc/` (`@LAN@`, `@ROUTER@`, `@FACTORIO_UID@` filled in by `install.sh`) |
| `secrets.env.example` | first install only: `/home/factorio/.config/factorio/secrets.env` (600). Real secrets never go in git. |
