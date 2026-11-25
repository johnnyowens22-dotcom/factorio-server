# Image recipe: copied from factoriotools/factorio-docker

- Source: https://github.com/factoriotools/factorio-docker, folder `docker/`, commit
  `446f2553eedb142eb6a25c670af7def2647ba24c` (2026-11-16; the recipe their own `2.1.25-rootless` was built from).
- Licence: MIT (`LICENSE`, kept as the licence asks).
- Copied: `Dockerfile.rootless`, `files/`, `rcon/`. Not copied: the root `Dockerfile`, their compose file, build
  scripts and CI.
- **Local change (F26):** both `FROM debian:stable-slim` → `FROM ${BASE}`, with `ARG BASE=debian:trixie-slim` at
  the top. `factorio-update` passes the exact digest it checked, so the base is recorded and a Debian major
  upgrade is a deliberate edit here, not a surprise in a routine rebuild.
- Upstream's later changes are **not** followed. To take one: read it, copy the file(s) here, update this note,
  commit, `sudo ./install.sh update`. The image is labelled with a hash of this folder, so the next
  `factorio-update` run with nobody online rebuilds and switches by itself (docs/self-built-image.md).
