#!/usr/bin/env bash
# Ubuntu / Debian 一键安装 Anchor（官方 AVM 流程）+ 可选 Solana CLI
#
#   chmod +x scripts/install-anchor.sh
#   ./scripts/install-anchor.sh              # 仅 Anchor（需已有 Rust 或自动装 rustup）
#   ./scripts/install-anchor.sh --install-apt   # 先 apt 装编译依赖（需 sudo，非 root）
#   ./scripts/install-anchor.sh --with-solana   # 额外安装 Solana CLI（anchor idl fetch 常用）
#
# 装完后新开终端，或: source ~/.cargo/env && export PATH="$HOME/.avm/bin:$PATH"
# 验证: anchor --version

set -euo pipefail

INSTALL_APT=0
WITH_SOLANA=0

for arg in "$@"; do
  case "$arg" in
    --install-apt) INSTALL_APT=1 ;;
    --with-solana) WITH_SOLANA=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

log() { echo "[install-anchor] $*"; }
die() { echo "错误: $*" >&2; exit 1; }

if [[ "${EUID:-0}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

if [[ "$INSTALL_APT" -eq 1 ]]; then
  log "安装系统依赖（build-essential / libssl / pkg-config / git / curl）…"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq \
    build-essential pkg-config libssl-dev libudev-dev git curl ca-certificates
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "未找到命令: $1"; }

need_cmd curl
need_cmd git

if ! command -v rustc >/dev/null 2>&1; then
  log "安装 Rust（rustup，非交互）…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi

# shellcheck disable=SC1091
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

need_cmd cargo

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v avm >/dev/null 2>&1; then
  log "安装 AVM（Anchor Version Manager）…"
  cargo install --git https://github.com/coral-xyz/anchor avm --locked --force
fi

need_cmd avm

log "安装最新 Anchor CLI…"
avm install latest
avm use latest

AVM_BIN="$HOME/.avm/bin"
mkdir -p "$AVM_BIN"
export PATH="$AVM_BIN:$PATH"

if ! grep -q '.avm/bin' "$HOME/.bashrc" 2>/dev/null; then
  log "将 AVM 写入 ~/.bashrc …"
  {
    echo ""
    echo "# Anchor (avm)"
    echo 'export PATH="$HOME/.avm/bin:$PATH"'
  } >> "$HOME/.bashrc"
fi

if [[ "$WITH_SOLANA" -eq 1 ]]; then
  if ! command -v solana >/dev/null 2>&1; then
    log "安装 Solana CLI（stable）…"
    sh -c "$(curl -sSfL https://release.solana.com/stable/install)"
    if ! grep -q '.local/share/solana/install' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
  else
    log "Solana CLI 已存在，跳过。"
  fi
fi

need_cmd anchor
log "完成: $(anchor --version)"
log "若当前 shell 仍找不到 anchor，请执行: export PATH=\"\$HOME/.avm/bin:\$PATH\" && source \"\$HOME/.cargo/env\""
