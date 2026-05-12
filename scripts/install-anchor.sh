#!/usr/bin/env bash
# Ubuntu / Debian: Anchor CLI + optional Solana
#
# 预编译的 avm「latest」常依赖 GLIBC_2.39；vast 上多为 Ubuntu 22.04 (glibc 2.35)。
# 默认在 glibc < 2.39 时用 cargo 从源码安装 anchor-cli（与 PoW-Miners 常用 0.31.x 对齐）。
#
#   chmod +x scripts/install-anchor.sh
#   ./scripts/install-anchor.sh --install-apt
#   ./scripts/install-anchor.sh --install-apt --with-solana
#   ./scripts/install-anchor.sh --use-avm              # 强制用 avm（需本机 glibc 足够新）
#   ./scripts/install-anchor.sh --from-source          # 强制 cargo 安装 anchor-cli（忽略 glibc）
#   ANCHOR_CLI_VERSION=0.31.1 ./scripts/install-anchor.sh --install-apt
#
# 完成后: source "$HOME/.cargo/env"；PATH 建议含 ~/.cargo/bin（先于 ~/.avm/bin）

set -euo pipefail

INSTALL_APT=0
WITH_SOLANA=0
FORCE_AVM=0
FORCE_SOURCE=0

ANCHOR_CLI_VERSION="${ANCHOR_CLI_VERSION:-0.31.1}"

for arg in "$@"; do
  case "$arg" in
    --install-apt) INSTALL_APT=1 ;;
    --with-solana) WITH_SOLANA=1 ;;
    --use-avm)     FORCE_AVM=1 ;;
    --from-source) FORCE_SOURCE=1 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

log() { echo "[install-anchor] $*"; }
die() { echo "error: $*" >&2; exit 1; }

if [[ "${EUID:-0}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

# 返回如 2.35
glibc_version() {
  ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo "0.0"
}

# $1 < $2 时返回 0 (true)
ver_lt() {
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]] && [[ "$1" != "$2" ]]
}

if [[ "$INSTALL_APT" -eq 1 ]]; then
  log "apt: build tools, ssl, clang (anchor build), protobuf…"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq \
    build-essential pkg-config libssl-dev libudev-dev libclang-dev clang \
    protobuf-compiler git curl ca-certificates
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

need_cmd curl
need_cmd git

if ! command -v rustc >/dev/null 2>&1; then
  log "rustup (non-interactive)…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi

# shellcheck disable=SC1091
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
export PATH="$HOME/.cargo/bin:$PATH"
need_cmd cargo

GLIBC_NOW="$(glibc_version)"
USE_CARGO=1
if [[ "$FORCE_SOURCE" -eq 1 ]]; then
  log "--from-source: cargo install anchor-cli $ANCHOR_CLI_VERSION"
  USE_CARGO=1
elif [[ "$FORCE_AVM" -eq 1 ]]; then
  USE_CARGO=0
elif ver_lt "$GLIBC_NOW" "2.39"; then
  log "glibc is $GLIBC_NOW (<2.39): use cargo install anchor-cli $ANCHOR_CLI_VERSION (not avm binary)."
  USE_CARGO=1
else
  log "glibc is $GLIBC_NOW: use avm prebuilt (use --from-source for cargo install)."
  USE_CARGO=0
fi

if [[ "$USE_CARGO" -eq 1 ]]; then
  log "cargo install anchor-cli $ANCHOR_CLI_VERSION (may take several minutes)…"
  cargo install "anchor-cli" --version "$ANCHOR_CLI_VERSION" --locked
else
  if ! command -v avm >/dev/null 2>&1; then
    log "cargo install avm…"
    cargo install --git https://github.com/coral-xyz/anchor avm --locked --force
  fi
  need_cmd avm
  log "avm install latest + avm use latest…"
  avm install latest
  avm use latest
  export PATH="$HOME/.avm/bin:$PATH"
fi

# cargo bin first so anchor from cargo wins over broken avm symlink
if ! grep -q 'install-anchor PATH' "$HOME/.bashrc" 2>/dev/null; then
  log "append PATH hint to ~/.bashrc"
  {
    echo ""
    echo "# install-anchor PATH (cargo before avm)"
    echo 'export PATH="$HOME/.cargo/bin:$HOME/.avm/bin:$PATH"'
  } >> "$HOME/.bashrc"
fi
export PATH="$HOME/.cargo/bin:$HOME/.avm/bin:$PATH"

if [[ "$WITH_SOLANA" -eq 1 ]]; then
  if ! command -v solana >/dev/null 2>&1; then
    log "Solana CLI stable (retry curl)…"
    ok=0
    for i in 1 2 3 4 5; do
      if curl -fsSL --retry 3 --retry-delay 2 -o /tmp/solana-install.sh https://release.solana.com/stable/install; then
        ok=1
        break
      fi
      log "curl failed (try $i/5), sleep 5s…"
      sleep 5
    done
    [[ "$ok" -eq 1 ]] || die "download Solana install script failed. Try: apt install wget && wget -qO /tmp/solana-install.sh https://release.solana.com/stable/install && sh /tmp/solana-install.sh"
    sh /tmp/solana-install.sh
    if ! grep -q 'solana/install/active_release/bin' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
  else
    log "solana already present, skip."
  fi
fi

need_cmd anchor
anchor --version
log "OK: $(command -v anchor)"
log "this shell: source \"\$HOME/.cargo/env\"; export PATH=\"\$HOME/.cargo/bin:\$HOME/.avm/bin:\$PATH\""
