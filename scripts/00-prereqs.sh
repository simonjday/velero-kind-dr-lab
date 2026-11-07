#!/usr/bin/env bash
# Checks Docker Desktop / kind / kubectl / jq and installs a pinned Velero CLI into ./bin
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

banner "Prerequisites"

[ "$(uname -s)" = "Darwin" ] || warn "not macOS - scripts are written for Apple Silicon macOS but should work on Linux"
[ "$(uname -m)" = "arm64" ]  || warn "not arm64 - adjust VELERO CLI arch below"

for bin in docker kind kubectl jq curl; do
  command -v "$bin" >/dev/null || die "$bin not found (brew install $bin)"
  ok "$bin: $(command -v "$bin")"
done

# Make sure 'docker' is talking to Docker Desktop, not a Podman socket
docker info >/dev/null 2>&1 || die "docker daemon not reachable - start Docker Desktop"
os="$(docker info --format '{{.OperatingSystem}}')"
case "$os" in
  *"Docker Desktop"*) ok "docker engine: ${os} (context: $(docker context show))" ;;
  *) die "docker CLI points at '${os}' - run: docker context use desktop-linux ; unset DOCKER_HOST" ;;
esac

mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
cpus="$(docker info --format '{{.NCPU}}')"
[ "${mem_gb}" -ge 7 ] || warn "Docker Desktop has ${mem_gb}GiB RAM - allocate >= 8GiB for two clusters"
ok "Docker Desktop resources: ${cpus} CPU / ${mem_gb} GiB"

ok "kind $(kind version | awk '{print $2}')"
ok "kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"

# --- Velero CLI (pinned, checksum verified) ---
os_l="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"; [ "$arch" = "x86_64" ] && arch=amd64; [ "$arch" = "aarch64" ] && arch=arm64
want="${VELERO_VERSION}"
have="$(velero version --client-only 2>/dev/null | awk '/Version:/{print $2; exit}' || true)"

if [ "${have}" = "${want}" ]; then
  ok "velero CLI ${have} already installed"
else
  log "installing velero CLI ${want} (${os_l}-${arch}) into ${BIN_DIR}"
  mkdir -p "${BIN_DIR}"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  base="https://github.com/velero-io/velero/releases/download/${want}"
  tgz="velero-${want}-${os_l}-${arch}.tar.gz"
  curl -fsSL -o "${tmp}/${tgz}"   "${base}/${tgz}"
  curl -fsSL -o "${tmp}/CHECKSUM" "${base}/CHECKSUM"
  expected="$(grep " ${tgz}\$" "${tmp}/CHECKSUM" | awk '{print $1}')"
  actual="$(shasum -a 256 "${tmp}/${tgz}" | awk '{print $1}')"
  [ -n "${expected}" ] && [ "${expected}" = "${actual}" ] || die "checksum mismatch for ${tgz}"
  ok "sha256 verified (${actual:0:16}...)"
  tar -xzf "${tmp}/${tgz}" -C "${tmp}"
  install -m 0755 "${tmp}/velero-${want}-${os_l}-${arch}/velero" "${BIN_DIR}/velero"
  # Gatekeeper quarantine is not set by curl, but be safe
  xattr -d com.apple.quarantine "${BIN_DIR}/velero" 2>/dev/null || true
  ok "velero CLI: $("${BIN_DIR}/velero" version --client-only | awk '/Version:/{print $2}')"
fi

echo
ok "prereqs done - add ${BIN_DIR} to PATH or: source scripts/env.sh"
