#!/bin/bash
# F26: factorio-update / factorio-rollback decisions against stub docker + curl (tests/stub). No root, no Docker,
# nothing on the real server is touched. Run: tests/test-update.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$T/home; mkdir -p "$H/data/saves" "$H/.config/factorio" "$T/run/factorio"
cp -r "$REPO/files/home/bin" "$REPO/files/home/image" "$REPO/files/home/compose.yml" "$H/"
touch "$H/.config/factorio/secrets.env" "$H/data/saves/world.zip"
export FACTORIO_TEST_HOME=$H FACTORIO_TEST_BIN=$REPO/tests/stub STUB_STATE=$T XDG_RUNTIME_DIR=$T/run
export FACTORIO_UPDATE_OUT=$T/run/factorio/update.json
cat > "$T/state.json" <<'EOF'
{"n": 0, "builds": [], "restarts": 0, "players": "0", "stable": "2.1.25",
 "sha": {"2.1.24": "1111111111111111111111111111111111111111111111111111111111111111",
         "2.1.25": "2222222222222222222222222222222222222222222222222222222222222222",
         "2.1.26": "3333333333333333333333333333333333333333333333333333333333333333"},
 "images": {"sha256:up": {"labels": {"factorio.version": "2.1.24"}}, "sha256:ddns": {},
            "sha256:deb1": {"digest": "debian@sha256:aaaa"}, "sha256:deb2": {"digest": "debian@sha256:bbbb"}},
 "tags": {"factoriotools/factorio:stable-rootless": "sha256:up", "favonia/cloudflare-ddns:1": "sha256:ddns"},
 "hub": {"debian:trixie-slim": "sha256:deb1", "favonia/cloudflare-ddns:1": "sha256:ddns"},
 "containers": {"factorio": {"image": "sha256:up", "running": true}, "factorio-ddns": {"image": "sha256:ddns", "running": true}}}
EOF
fails=0; n=0
set_() { python3 -I -c "import json,sys; p='$T/state.json'; s=json.load(open(p)); s.update(json.loads(sys.argv[1])); json.dump(s,open(p,'w'))" "$1"; }
run() { "$H/bin/$1" "${@:2}" >"$T/out" 2>&1 || echo "exit=$?" >>"$T/out"; }
# check "what" 'python expression over s (state), u (update.json), tag(t) -> version'
check() {
  n=$((n + 1))
  if python3 -I - "$T" "$2" <<'PY'
import json, sys
T, expr = sys.argv[1:]
s = json.load(open(f"{T}/state.json"))
u = json.load(open(f"{T}/run/factorio/update.json"))
tag = lambda t: s["images"].get(s["tags"].get(t), {}).get("labels", {}).get("factorio.version")
cur = lambda: s["containers"]["factorio"]["image"] == s["tags"].get("factorio-local:current")
sys.exit(0 if eval(expr) else 1)
PY
  then echo "ok   $1"; else echo "FAIL $1"; sed 's/^/     /' "$T/out"; cat "$T/run/factorio/update.json"; echo; fails=$((fails + 1)); fi
}

run factorio-update
check "migration: builds 2.1.25 from factorio.com, switches with nobody online" \
  's["builds"] == ["2.1.25"] and tag("factorio-local:current") == "2.1.25" and cur() and u["state"] == "ok" and u["running"] == u["stable"] == "2.1.25"'
check "migration: old upstream image removed, pre-update backup made" \
  '"factoriotools/factorio:stable-rootless" not in s["tags"]'
ls "$H/backups"/save-*-pre-update.zip >/dev/null || { echo "FAIL no pre-update backup"; fails=$((fails + 1)); }

run factorio-update
check "same release again: nothing built or restarted" 's["builds"] == ["2.1.25"] and s["restarts"] == 1 and u["state"] == "ok"'

set_ '{"stable": "2.1.26", "players": "2"}'; run factorio-update
check "new release, 2 players online: waits, builds nothing" \
  's["builds"] == ["2.1.25"] and u["state"] == "waiting" and "2 player(s)" in u["detail"] and u["running"] == "2.1.25"'

set_ '{"players": null}'; run factorio-update
check "server not answering RCON: waits" 'u["state"] == "waiting" and "RCON" in u["detail"] and len(s["builds"]) == 1'

set_ '{"players": "0", "build_fail": true}'; run factorio-update
check "build fails: state build-failed, server unchanged" \
  'u["state"] == "build-failed" and "checksum" in u["detail"] and tag("factorio-local:current") == "2.1.25" and cur()'

set_ '{"build_fail": false}'; run factorio-update
check "nobody online: builds 2.1.26, keeps 2.1.25 as previous" \
  'tag("factorio-local:current") == "2.1.26" and tag("factorio-local:previous") == "2.1.25" and cur() and u["state"] == "ok"'

set_ '{"stable": "2.1.24"}'; run factorio-update
check "stable went backwards: no downgrade" 'u["state"] == "stable-older" and tag("factorio-local:current") == "2.1.26" and len(s["builds"]) == 2'

set_ '{"stable": "2.1.26", "fz_down": true}'; run factorio-update
check "factorio.com unreachable: check-failed, nothing changes" 'u["state"] == "check-failed" and u["stable"] is None and cur()'

set_ '{"fz_down": false, "hub": {"debian:trixie-slim": "sha256:deb2", "favonia/cloudflare-ddns:1": "sha256:ddns"}}'
rm -f "$H/.local/state/factorio/base-checked"; run factorio-update
check "Debian base changed: same version rebuilt on the new digest and switched" \
  's["builds"][-1] == "2.1.26" and len(s["builds"]) == 3 and s["images"][s["tags"]["factorio-local:current"]]["labels"]["factorio-server.base"] == "debian@sha256:bbbb" and cur()'

echo "# changed" >> "$H/image/rcon/Makefile"; run factorio-update
check "recipe changed: rebuilt by itself" 'len(s["builds"]) == 4 and cur() and u["state"] == "ok"'

set_ '{"hub_down": true}'; rm -f "$H/.local/state/factorio/base-checked"; run factorio-update
check "Docker Hub down: uses the local base, no rebuild" 'len(s["builds"]) == 4 and u["state"] == "ok"'
set_ '{"hub_down": false}'

run factorio-rollback
check "rollback: previous becomes current, hold written" \
  'cur() and s["tags"]["factorio-local:current"] != s["tags"]["factorio-local:previous"]'
grep -q "held until" "$T/out" || { echo "FAIL rollback message"; cat "$T/out"; fails=$((fails + 1)); }
run factorio-update
check "held: the updater doesn't move" 'u["state"] == "held" and len(s["builds"]) == 4'
run factorio-rollback --release; run factorio-update
check "released: back on the newest build" 'u["state"] == "ok" and cur() and len(s["builds"]) == 4'

set_ '{"stable": "2.1.26"}'; ok_before=$(cat "$H/.local/state/factorio/ok_at")
set_ '{"stable": "2.1.27", "sha": {"2.1.27": "nothex"}}'; run factorio-update
check "bad checksum line from factorio.com: check-failed, ok_at not advanced" \
  'u["state"] == "check-failed" and u["ok_at"] == '"$ok_before"

# fresh box: no image at all, factorio-apply builds first
set_ '{"stable": "2.1.26", "sha": {"2.1.26": "3333333333333333333333333333333333333333333333333333333333333333"}}'
set_ '{"tags": {"favonia/cloudflare-ddns:1": "sha256:ddns", "debian:trixie-slim": "sha256:deb2"}, "containers": {}}'
sed -i 's|^python3 -I "$(dirname "$0")/factorio-settings".*|: settings skipped in the test|' "$H/bin/factorio-apply"
run factorio-apply
check "fresh install: factorio-apply builds stable, then starts it" 'tag("factorio-local:current") == "2.1.26" and cur()'

echo "$n checks, $fails failed"
[ "$fails" = 0 ]
