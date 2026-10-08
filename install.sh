#!/bin/bash
# Sets up the isolated Factorio server (docs/plan.md). Run by the user, as root, from a clone of this repo:
#   sudo ./install.sh                  install or update (idempotent; safe to re-run)
#   sudo ./install.sh import DIR       copy a save (DIR/*.zip) and mods (DIR/mods/*) into the server
#   sudo ./install.sh host             only the /etc + /usr/local/sbin parts (firewall, report): no game restart
#   sudo ./install.sh update           scripts, user services (incl. factorio-status) + host parts: no Docker or game restart
#   ./install.sh --check               show what install would change (/etc only without sudo)
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
U=factorio
H=/home/$U
LAN=${FACTORIO_LAN:-192.168.1.0/24}
ROUTER=${FACTORIO_ROUTER:-192.168.1.1}
CONTAINER_UID=1000                    # the uid the factorio rootless image runs as, inside the container

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Files that go to /etc, with @VARS@ filled in. Prints the rendered content of $1.
render() {
  local uid; uid=$(id -u "$U" 2>/dev/null || echo UNKNOWN)
  sed -e "s|@LAN@|$LAN|g" -e "s|@ROUTER@|$ROUTER|g" -e "s|@FACTORIO_UID@|$uid|g" "$REPO/files/etc/$1"
}
ETC_FILES="factorio/firewall.nft systemd/system/factorio-firewall.service tmpfiles.d/factorio-status.conf"
SBIN_FILES="factorio-report"           # files/usr/local/sbin/ -> /usr/local/sbin/ (root, 755)
USER_UNITS="factorio-update.timer factorio-backup.timer factorio-status.service"   # enabled in the user session

# The host uid that container uid $CONTAINER_UID maps to: the account's first subuid + $CONTAINER_UID - 1.
mapped_id() {  # $1 = /etc/subuid or /etc/subgid
  local start; start=$(awk -F: -v u="$U" '$1==u {print $2; exit}' "$1")
  [ -n "$start" ] || die "$U has no entry in $1"
  echo $((start + CONTAINER_UID - 1))
}

as_user() {  # run a command as the factorio account, inside its systemd user session
  local uid; uid=$(id -u "$U")
  runuser -u "$U" -- env HOME="$H" XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@"
}

check() {
  local f diffs=0
  for f in $ETC_FILES; do
    if [ ! -e "/etc/$f" ]; then echo "NEW      /etc/$f"; diffs=1
    elif render "$f" | cmp -s - "/etc/$f"; then echo "same     /etc/$f"
    else echo "CHANGED  /etc/$f"; render "$f" | diff -u "/etc/$f" - | sed 's/^/    /' || true; diffs=1; fi
  done
  for f in $SBIN_FILES; do
    if [ ! -e "/usr/local/sbin/$f" ]; then echo "NEW      /usr/local/sbin/$f"; diffs=1
    elif cmp -s "$REPO/files/usr/local/sbin/$f" "/usr/local/sbin/$f"; then echo "same     /usr/local/sbin/$f"
    else echo "CHANGED  /usr/local/sbin/$f"; diffs=1; fi
  done
  if [ "$(id -u)" -ne 0 ]; then echo "(files in $H need sudo to compare)"; return 0; fi
  while IFS= read -r f; do
    rel=${f#"$REPO/files/home/"}; rel=${rel/#config\//.config/}
    if [ ! -e "$H/$rel" ]; then echo "NEW      $H/$rel"; diffs=1
    elif cmp -s "$f" "$H/$rel"; then echo "same     $H/$rel"
    else echo "CHANGED  $H/$rel"; diffs=1; fi
  done < <(find "$REPO/files/home" -type f | sort)
  [ $diffs = 0 ] && echo "Everything matches the repo." || true
}

import_save() {
  local src=$1 saves mods uid gid
  [ -d "$src" ] || die "$src is not a folder"
  saves=$(find "$src" -maxdepth 1 -name '*.zip' | wc -l)
  [ "$saves" -ge 1 ] || die "no save (.zip) directly in $src; mods go in $src/mods/"
  [ "$saves" -eq 1 ] || warn "$saves saves found; the newest one is loaded"
  uid=$(mapped_id /etc/subuid); gid=$(mapped_id /etc/subgid)
  as_user "$H/bin/factorio-docker" stop factorio >/dev/null 2>&1 || true
  install -d -o "$uid" -g "$gid" -m 755 "$H/data/saves" "$H/data/mods"
  install -o "$uid" -g "$gid" -m 644 "$src"/*.zip "$H/data/saves/"
  touch "$H/data/saves/$(basename "$(ls -1t "$src"/*.zip | head -1)")"   # newest = the one that loads
  if [ -d "$src/mods" ]; then
    find "$src/mods" -maxdepth 1 -type f \( -name '*.zip' -o -name 'mod-list.json' -o -name 'mod-settings.dat' \) \
      -exec install -o "$uid" -g "$gid" -m 644 {} "$H/data/mods/" \;
  else warn "no $src/mods folder: the server starts with Space Age only (no other mods)"; fi
  say "Imported. Start it with: sudo -u $U $H/bin/factorio-apply"
}

install_home_files() {  # scripts, compose file, user units -> $H (never secrets.env, never the game data)
  say "Files in $H"
  install -d -o "$U" -g "$U" -m 700 "$H/.config" "$H/.config/factorio" "$H/backups"
  install -d -o "$U" -g "$U" -m 755 "$H/bin" "$H/generated"
  while IFS= read -r f; do
    rel=${f#"$REPO/files/home/"}; rel=${rel/#config\//.config/}; mode=644; [ "${rel%%/*}" = bin ] && mode=755
    install -D -o "$U" -g "$U" -m "$mode" "$f" "$H/$rel"
  done < <(find "$REPO/files/home" -type f)
}

install_host() {
  say "Firewall (own nftables table; Docker's rules untouched)"
  install -d -m 755 /etc/factorio
  for f in $ETC_FILES; do
    render "$f" > "/etc/$f.new"
    chmod 644 "/etc/$f.new"; mv "/etc/$f.new" "/etc/$f"
  done
  nft -c -f /etc/factorio/firewall.nft || die "firewall rules don't parse; nothing loaded"
  systemctl daemon-reload
  systemctl enable factorio-firewall.service >/dev/null 2>&1
  systemctl restart factorio-firewall.service
  systemctl is-enabled --quiet nftables.service 2>/dev/null && \
    warn "nftables.service is enabled: its /etc/nftables.conf runs 'flush ruleset' at boot and wipes Docker's rules. Disable it."

  say "/run/factorio for the player-count file (F13)"
  systemd-tmpfiles --create /etc/tmpfiles.d/factorio-status.conf

  say "Root tools in /usr/local/sbin"
  for f in $SBIN_FILES; do install -o root -g root -m 755 "$REPO/files/usr/local/sbin/$f" "/usr/local/sbin/$f"; done
}

case "${1:-}" in
  --check) check; exit 0 ;;
  import)  [ "$(id -u)" -eq 0 ] || die "run with sudo"; [ -n "${2:-}" ] || die "usage: sudo $0 import DIR"
           id "$U" >/dev/null 2>&1 || die "run 'sudo $0' first"; import_save "$2"; exit 0 ;;
  host)    [ "$(id -u)" -eq 0 ] || die "run with sudo"; id "$U" >/dev/null 2>&1 || die "run 'sudo $0' first"
           install_host; say "Done (game server not restarted)."; exit 0 ;;
  update)  [ "$(id -u)" -eq 0 ] || die "run with sudo"; id "$U" >/dev/null 2>&1 || die "run 'sudo $0' first"
           install_home_files; install_host
           as_user systemctl --user daemon-reload
           as_user systemctl --user enable --now $USER_UNITS
           as_user systemctl --user restart factorio-status.service
           say "Done: scripts, user services, firewall updated (Docker and the game server not restarted)."; exit 0 ;;
  "")      ;;
  *)       die "unknown argument: $1" ;;
esac
[ "$(id -u)" -eq 0 ] || die "run with sudo (or use --check)"

say "Packages"
missing=""
for p in slirp4netns uidmap dbus-user-session docker-ce-rootless-extras; do
  dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
done
[ -z "$missing" ] || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing; }

say "Account '$U' (no sudo, no docker group, no login shell, no SSH)"
if ! id "$U" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$H" --shell /usr/sbin/nologin --user-group \
    --comment "Factorio server (isolated; github factorio-server repo)" "$U"
fi
passwd -l "$U" >/dev/null
chmod 700 "$H"
for g in sudo docker; do
  if id -nG "$U" | tr ' ' '\n' | grep -qx "$g"; then die "$U is in group $g: remove it (gpasswd -d $U $g)"; fi
done
grep -q "^$U:" /etc/subuid && grep -q "^$U:" /etc/subgid || die "$U has no /etc/subuid or /etc/subgid range"
uid=$(id -u "$U")

say "Systemd user session (linger: starts at boot without anyone logging in)"
loginctl enable-linger "$U"
for _ in $(seq 30); do [ -S "/run/user/$uid/bus" ] && break; sleep 1; done
[ -S "/run/user/$uid/bus" ] || die "the user session for $U didn't start"

install_home_files
chown -R "$U:$U" "$H/.config"
if [ ! -f "$H/.config/factorio/secrets.env" ]; then
  install -o "$U" -g "$U" -m 600 "$REPO/secrets.env.example" "$H/.config/factorio/secrets.env"
  warn "fill in $H/.config/factorio/secrets.env (see the next steps below)"
fi
chmod 600 "$H/.config/factorio/secrets.env"
# Rebuild the game's settings from secrets.env + factorio-settings, so the Docker restart below picks up any
# change to either (a fresh install has empty secrets: skipped until factorio-apply).
as_user python3 -I "$H/bin/factorio-settings" "$H/.config/factorio/secrets.env" "$H/generated" 2>/dev/null \
  || warn "settings not rebuilt (secrets.env incomplete?); factorio-apply will do it"
# The game's own folder belongs to the container's user (a subuid): even the factorio account can't edit it.
data_uid=$(mapped_id /etc/subuid); data_gid=$(mapped_id /etc/subgid)
install -d -o "$data_uid" -g "$data_gid" -m 755 "$H/data" "$H/data/config" "$H/data/saves" "$H/data/mods" \
  "$H/data/scenarios" "$H/data/script-output"

say "Rootless Docker for $U"
if [ ! -f "$H/.config/systemd/user/docker.service" ]; then
  as_user dockerd-rootless-setuptool.sh install
fi
as_user systemctl --user daemon-reload
as_user systemctl --user enable docker.service >/dev/null 2>&1
as_user systemctl --user restart docker.service
as_user systemctl --user enable --now $USER_UNITS

install_host

say "Done. Next steps:"
cat <<EOF
  1. Fill in the secrets:   sudo -u $U nano $H/.config/factorio/secrets.env
  2. Import the save:       sudo $REPO/install.sh import /home/streambox/factorio-staging
  3. Start:                 sudo -u $U $H/bin/factorio-apply
  Security/health report:   sudo factorio-report
EOF
