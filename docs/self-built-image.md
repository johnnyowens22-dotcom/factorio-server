# F26: build the game image here, from factorio.com's stable release

**Status:** plan + review 2026-11-25, approved by the user the same day ("do the whole thing"); **built and tested
2026-11-25**, waiting for `sudo ./install.sh update` (plan.md build order 13). Replaces F5's image source; F5's rule
(follow Steam's default branch, restart only with nobody online) stays.

## Why

F5 follows `factoriotools/factorio:stable-rootless`. That tag only moves when the image project's scheduled
GitHub job runs, and GitHub keeps suspending it (the project is a fork with thousands of workflow runs):

- [#635](https://github.com/factoriotools/factorio-docker/issues/635): the job stopped 2026-11-02; 2.1.25 was
  only built after someone pinged a maintainer (2026-11-16), and then as `latest` only (still experimental).
- [#636](https://github.com/factoriotools/factorio-docker/issues/636): Wube made 2.1.25 stable a few days later;
  on 2026-11-25 `stable` still pointed at 2.1.24, the job suspended again. Friends on Steam's 2.1.25 can't join.
- [#638](https://github.com/factoriotools/factorio-docker/issues/638): the images are never rebuilt for Debian
  security fixes either.

Wube says 2.1 is the last major version, so from here on releases are bug fixes on the same recipe: building it
ourselves is a small, stable job.

## What gets built

- **Recipe:** upstream's `docker/` folder (MIT), copied into `files/home/image/` at commit `446f2553`
  (2026-11-16, the recipe their own 2.1.25 image was built from). Only `Dockerfile.rootless`, `files/`, `rcon/`
  and the licence. **One local change:** both `FROM debian:stable-slim` become `FROM ${BASE}` with
  `ARG BASE=debian:trixie-slim`, so a Debian major upgrade is our choice, not a surprise in a weekly build, and the
  exact base (by digest) is recorded. `image/UPSTREAM.md` records the commit and the change. Upstream's later
  changes are **not** followed; we copy one in by hand if it's ever needed.
- **Server:** `https://www.factorio.com/get-download/<version>/headless/linux64`, public, no login. The recipe
  checks it against the SHA-256 from `https://factorio.com/download/sha256sums/` (same value upstream uses: 2.1.25
  = `78da2f5a…`).
- **Which version:** `stable.headless` from `https://factorio.com/api/latest-releases` = Steam's default branch.
  Never experimental.
- **Image names** (local only, `pull_policy: never`): `factorio-local:<version>` per build;
  `factorio-local:current` = what compose runs; `factorio-local:previous` = the one before, for rollback.
  Labels: `factorio.version` (unchanged: `factorio-report` and the dashboard read it), `factorio-server.base`
  (Debian digest), `factorio-server.recipe` (upstream commit).

## How it runs

`factorio-update` (user timer, every 15 min, as now):

1. Pull the DNS updater only (`dc pull ddns`). *(Pulling everything would fail on the local image and end the run
   every time, so neither would ever update.)*
2. Ask factorio.com for stable + its checksum (30 s timeouts; a version must look like `N.N.N`, a checksum 64 hex).
   Can't → state `check-failed`, nothing changes.
3. Decide:
   - stable **newer** than `current` → build it.
   - stable **older** than `current` → do nothing, state `stable-older` (a save from a newer game won't load in an
     older one, so never downgrade by itself).
   - same, and Debian's `trixie-slim` changed since the image was built (checked once a day) → rebuild the same
     version (security fixes). No change → nothing.
   - a **hold** file exists (`~/.config/factorio/hold`, written by `factorio-rollback`) → do nothing, state `held`.
4. **Build only while nobody plays** (or the server is stopped): a few CPU-heavy minutes would stutter the game.
   Needs 3 GB free on the NVMe. `flock` so `factorio-apply` / `factorio-rollback` never build at the same time.
   A failed build changes nothing (state `build-failed` + the last log lines), retried next run.
5. **Switch** (unchanged from F5): nobody online → `factorio-backup pre-update` → `previous` ← `current` ←
   new → `dc up -d factorio`.
6. Tidy: `docker builder prune -af`; remove `factorio-local:<v>` tags other than current/previous, and the old
   `factoriotools/factorio` images.
7. Write **`/run/factorio/update.json`** (world-readable, like `players.json`):
   `{"at", "stable", "running", "ok_at", "state", "detail"}`; `ok_at` = the last time the server ran stable
   (kept in `~/.local/state/factorio/ok_at` so a reboot doesn't reset it).

The service gets `TimeoutStartSec=45min`: a `oneshot` has no timeout by default, and a hung build would stop the
timer from ever firing again.

`factorio-apply`: if `factorio-local:current` doesn't exist (fresh install, rebuilt box), build stable first
(prints "building the game image, a few minutes"), then start as before.

`factorio-rollback`: `current` ↔ `previous`, write the hold file, restart (backup first). If the versions
differ it prints the newest **pre-update** save to import: the autosaves since were written by the newer game
and the older one refuses them. `factorio-rollback --release` deletes the hold; the next run updates again.

## The media server's side (streambox D183)

- Dashboard reads `/run/factorio/update.json` (already mounted, `/data/factorio`).
- **Push "Factorio server is behind"** (category Factorio, once, with a *resolved* message) when the server
  hasn't run stable for 24 h (`now − ok_at`), or the file is 3 h old (updater not running); not while `held`.
  The body says why (`state` + `detail`): waiting for players, build failed, factorio.com unreachable, stable
  older. This catches every way the update path can break, including ones nobody's thought of.
- Card: one warning line while it's behind, an info line while held.

## Review: the usual checks

| Check | Finding | Handling |
|---|---|---|
| **Isolation** (F2) | Builds run on the factorio account's own rootless daemon; build steps run as a subuid, like the game. Nothing is installed on the host, nothing new is shared with the media server (`update.json` is one more one-way file in `/run/factorio`). | ✅ |
| **Firewall / false alarms** | Build steps reach `deb.debian.org` (apt) and `factorio.com`. `from_factorio` allows the internet and DNS to the router only; any lookup elsewhere would be rejected and raise "Factorio server tried to reach your LAN". Host and build containers use the router (`/etc/resolv.conf` = `192.168.1.1`), same as the DDNS updater today. | Watch on the first build: `sudo factorio-report` → firewall counters 0; else point the build's DNS at the router. |
| **Set-and-forget / reboot** | Images live in the account's Docker data on the NVMe: a reboot needs nothing. `/run/factorio/update.json` is gone until the first run 10 min after boot; `ok_at` persists. | ✅ the dashboard's 3 h staleness covers a dead timer. |
| **Rebuild from the repo** (streambox D47) | A fresh install has no image. | `factorio-apply` builds it first. Tested by building from a clean state. |
| **Failure modes** | factorio.com down / API changed / login required; checksum missing; Debian mirror down; Debian 14; disk full; hung build. | Each → state + no change; push after 24 h behind; 45-min timeout; 3 GB check; base pinned to trixie. |
| **Downgrades** | Wube pulling a stable back would make us load a newer save on an older game → crash loop. | Never downgrade automatically (`stable-older`, pushes after 24 h). |
| **Mods** (FG22) | Same entrypoint as upstream's 2.1.25. Upstream changed mod picking since the 2.1.24 image we run: a mod release must be made for the game's exact major.minor (was ≥). Right for 2.1 (the game refuses 2.0 mods anyway). | Same risk as any update today; pre-update backup. |
| **Players** | Builds and restarts only with 0 players; RCON not answering (crash loop) → wait, like today. | A crash-looping server never gets a fix automatically; the 24 h push says *waiting: server not answering*. |
| **Performance** | A build: ~2–4 min of 1–2 cores, ~250 MB download (Debian build tools + 100 MB server). Few times a month. Media server unaffected beyond that. | ✅ |
| **Capacity** | Two images ~1.1 GB, build cache cleared each time. NVMe 343 GB free. | ✅ |
| **Supply chain** | Trust: Wube (download + checksum from the same site: catches corruption, not a hacked factorio.com, same trust as Steam), Debian, and upstream's recipe as of `446f2553`, which I read (no downloads outside factorio.com/mods.factorio.com, no `curl | sh`). Docker Hub only for `debian:trixie-slim` and the DDNS updater. | Better than today (no third-party CI). |
| **Docker Hub limits** | Anonymous pulls are rate-limited. | `trixie-slim` checked once a day; DDNS pull as today. |
| **Rollback** | Today the old image is deleted right after an update. | `previous` kept; `factorio-rollback` + hold. |
| **Observability** | Today a stuck update was found by the user 9 days later. | `update.json` + the 24 h push; `factorio-report` shows the version; journal lines per run. |
| **Operability** (D110) | | Operator steps in streambox `docs/ops/factorio.md` (check, force, rollback, release) and the plan's commands. |
| **Media-side jobs** | Reboot guard, torrent throttle and backups read `/run/factorio/online` / the backups: unchanged. Dashboard memory rules: a new container resets the cgroup counters (already handled: "a drop = a new container"). | ✅ |
| **Weekly restarts** | A Debian refresh restarts the empty server for ~1 min. Only when the base actually changed (roughly monthly). | Accepted (same as an update). |

## Tests (before handing over)

1. Build the recipe on the media server's Docker (throwaway tag, removed after): 2.1.25 with Wube's checksum;
   compare with upstream's published `2.1.25-rootless` (scripts, env, entrypoint, user, healthcheck, label).
2. A wrong checksum fails the build.
3. The updater's decisions (newer / same / older / base changed / held / players online / RCON silent / check
   failed / disk low) as a shell test with stubbed `docker` and `curl`.
4. `install.sh --check` and `shellcheck` on the scripts.
5. Dashboard: alert scenarios in `dashboard/test/alerts.test.ts`.
6. On the box (by the user, `sudo ./install.sh update`): the first run builds 2.1.25 and switches with nobody
   online; `update.json` says `ok`; firewall counters stay 0; `factorio-report` shows 2.1.25.

### Results (2026-11-25)

1. ✅ Built on the media server's Docker in 25 s (throwaway tag, removed). Against upstream's `2.1.25-rootless`:
   environment, user, entrypoint, healthcheck, ports, volumes identical; every script, `config.ini`, the `rcon`
   binary and `factorio --version` identical; only `/etc/debian_version` differs (13.8 here, 13.7 theirs).
2. ✅ A wrong checksum fails the build; no image is tagged.
3. ✅ `tests/test-update.sh`: 17 checks (migration, same release, players online, RCON silent, build failed, new
   release, stable older, factorio.com down, Debian base changed, recipe changed, Docker Hub down, rollback, held,
   release, bad checksum line, fresh install through `factorio-apply`).
4. ✅ `shellcheck` clean (apart from the lib's existing style notes); `install.sh --check` runs.
5. ✅ streambox dashboard scenarios pass; deployed (quiet until `update.json` exists).
6. ⏳ On the box after the install.

**Known gaps, accepted:** `/run/factorio/update.json` is gone after a reboot until the first run (10 min); if the
timer never ran after a reboot, the dashboard would not notice (it treats a missing file as "not installed").
Upstream's code reviewed once; later upstream fixes need someone to look.
