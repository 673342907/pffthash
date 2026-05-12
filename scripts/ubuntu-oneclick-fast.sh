#!/usr/bin/env bash
# Hashish PoW — Ubuntu 省时一键：环境 + PoW-Miners + GPU 编译 + 可选直接开挖
# 在 ubuntu-gpu-miner.sh 基础上：浅克隆、合并 apt、npm/cargo 加速、智能跳过、可选自动 Node/Rust
#
#   export WALLET_PATH="$HOME/.config/solana/id.json"
#   export RPC_URL="https://mainnet.helius-rpc.com/?api-key=KEY"
#   chmod +x ubuntu-oneclick-fast.sh
#   ./ubuntu-oneclick-fast.sh --install-apt          # 首次：装系统包 + 全流程
#   ./ubuntu-oneclick-fast.sh --install-apt --setup-only
#   ./ubuntu-oneclick-fast.sh --mine-only
#
# 环境变量（可选）：
#   AUTO_NODE=0          关闭自动安装 Node（默认 1：无 Node 或 <18 时装到 ~/.local/pow-miners-node）
#   AUTO_RUST=0          关闭自动 rustup（默认 1：无 cargo 时 minimal profile）
#   GIT_DEPTH=1          浅克隆深度（默认 1；设为 0 则完整克隆）
#   SKIP_IDL_FETCH=1     若已有 target/idl/pow_protocol.json 则跳过 anchor fetch
#   FORCE_NPM=1          强制 npm install
#   FORCE_REBUILD=1      强制重新 cargo build

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Hashishdotfun/PoW-Miners.git}"
WORKDIR="${WORKDIR:-$HOME/PoW-Miners}"
GIT_DEPTH="${GIT_DEPTH:-1}"

RPC_URL="${RPC_URL:-https://api.mainnet-beta.solana.com}"
WALLET_PATH="${WALLET_PATH:-}"
RELAYER_WALLET_PATH="${RELAYER_WALLET_PATH:-}"

GPU_BACKEND="${GPU_BACKEND:-cuda}"
GPU_DEVICE="${GPU_DEVICE:-0}"
PROGRAM_ID="${PROGRAM_ID:-PoWQ79wY7LXrKaU8vZBoFb4JgSytENSdpAQAPJaZiSh}"
MINT="${MINT:-HASHcf66ffcWdGvswuuu8ssLWSeXpto6QaeG32AktiSh}"
POOL_ID="${POOL_ID:-0}"

CUDA_THREADS="${CUDA_THREADS:-256}"
CUDA_BLOCKS="${CUDA_BLOCKS:-1024}"
POLL_MS="${POLL_MS:-1500}"

AUTO_NODE="${AUTO_NODE:-1}"
AUTO_RUST="${AUTO_RUST:-1}"
SKIP_IDL_FETCH="${SKIP_IDL_FETCH:-0}"

NODE_TOOLCHAIN_VER="${NODE_TOOLCHAIN_VER:-20.18.1}"
# linux-x64 | linux-arm64
NODE_PLATFORM="${NODE_PLATFORM:-}"

SETUP_ONLY=0
MINE_ONLY=0
INSTALL_APT=0

export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
export NPM_CONFIG_UPDATE_NOTIFIER=false
export DEBIAN_FRONTEND=noninteractive

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup-only) SETUP_ONLY=1 ;;
    --mine-only)  MINE_ONLY=1 ;;
    --install-apt) INSTALL_APT=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

die() { echo "错误: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "未找到命令「$1」"; }
log() { echo "[oneclick-fast] $*"; }

if [[ -z "$WALLET_PATH" ]]; then
  die "请设置 WALLET_PATH，例如: export WALLET_PATH=\$HOME/.config/solana/id.json"
fi
[[ -f "$WALLET_PATH" ]] || die "钱包文件不存在: $WALLET_PATH"

RELAYER_WALLET_PATH="${RELAYER_WALLET_PATH:-$WALLET_PATH}"

if [[ "$INSTALL_APT" -eq 1 ]]; then
  log "apt 一次装齐（非交互）…"
  sudo apt-get update -qq
  APT_PKGS=(build-essential pkg-config libssl-dev curl git ca-certificates python3 xz-utils)
  [[ "$GPU_BACKEND" == "opencl" ]] && APT_PKGS+=(opencl-headers ocl-icd-opencl-dev clinfo)
  sudo apt-get install -y -qq "${APT_PKGS[@]}" || die "apt 安装失败"
fi

need_cmd git
need_cmd curl
need_cmd python3

ensure_node() {
  if command -v node >/dev/null 2>&1; then
    local mj
    mj="$(node -p 'parseInt(process.versions.node,10)')"
    [[ "$mj" -ge 18 ]] && return 0
  fi
  [[ "$AUTO_NODE" == "1" ]] || die "需要 Node.js 18+，或设置 AUTO_NODE=1 自动安装"
  local ndir="$HOME/.local/pow-miners-node"
  local ver="$NODE_TOOLCHAIN_VER"
  local plat="${NODE_PLATFORM:-}"
  if [[ -z "$plat" ]]; then
    case "$(uname -m)" in
      aarch64|arm64) plat="linux-arm64" ;;
      x86_64|amd64) plat="linux-x64" ;;
      *) die "不支持的架构 $(uname -m)，请手动安装 Node 18+ 并设置 AUTO_NODE=0" ;;
    esac
  fi
  local base="node-v${ver}-${plat}"
  local url="https://nodejs.org/dist/v${ver}/${base}.tar.xz"
  if [[ -x "$ndir/$base/bin/node" ]]; then
    export PATH="$ndir/$base/bin:$PATH"
    return 0
  fi
  log "下载 Node ${ver} 到 ${ndir}（免 apt 旧版）…"
  mkdir -p "$ndir"
  curl -fsSL "$url" -o "/tmp/${base}.tar.xz"
  tar -xJf "/tmp/${base}.tar.xz" -C "$ndir"
  export PATH="$ndir/$base/bin:$PATH"
  need_cmd node
  local mj
  mj="$(node -p 'parseInt(process.versions.node,10)')"
  [[ "$mj" -ge 18 ]] || die "Node 版本仍不足 18"
}

ensure_rust() {
  if command -v cargo >/dev/null 2>&1; then
    return 0
  fi
  [[ "$AUTO_RUST" == "1" ]] || die "需要 cargo，或设置 AUTO_RUST=1 自动安装 rustup"
  log "安装 Rust（minimal profile，非交互）…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
  need_cmd cargo
}

ensure_node
ensure_rust
need_cmd npm

if [[ "$GPU_BACKEND" != "cuda" && "$GPU_BACKEND" != "opencl" ]]; then
  die "GPU_BACKEND 必须是 cuda 或 opencl"
fi

if [[ "$GPU_BACKEND" == "cuda" ]]; then
  command -v nvcc >/dev/null 2>&1 || die "未找到 nvcc，请安装 CUDA 12+ 并配置 PATH"
  need_cmd nvidia-smi
fi

MINER_BIN="$WORKDIR/gpu-miner/target/release/miner"

gpu_sources_newer_than_bin() {
  [[ -x "$MINER_BIN" ]] || return 0
  local root="$WORKDIR/gpu-miner"
  [[ "$root/Cargo.toml" -nt "$MINER_BIN" ]] && return 0
  [[ -d "$root/src" ]] || return 1
  find "$root/src" -type f \( -name '*.rs' -o -name '*.cl' -o -name '*.cu' \) -newer "$MINER_BIN" -print -quit | grep -q .
}

need_npm_install() {
  [[ "${FORCE_NPM:-0}" == "1" ]] && return 0
  [[ ! -d "$WORKDIR/node_modules" ]] && return 0
  [[ "$WORKDIR/package.json" -nt "$WORKDIR/node_modules" ]] && return 0
  return 1
}

if [[ "$MINE_ONLY" -eq 0 ]]; then
  if [[ ! -d "$WORKDIR/.git" ]]; then
    log "浅克隆 PoW-Miners → $WORKDIR"
    if [[ "$GIT_DEPTH" != "0" ]]; then
      git clone --depth "$GIT_DEPTH" "$REPO_URL" "$WORKDIR"
    else
      git clone "$REPO_URL" "$WORKDIR"
    fi
  else
    log "尝试 git pull $WORKDIR …"
    git -C "$WORKDIR" pull --ff-only || true
  fi

  cd "$WORKDIR"

  if need_npm_install; then
    log "npm install（无 audit/fund，减少输出）…"
    npm install --no-audit --no-fund --loglevel=error
    log "补装 @types/bs58（上游 PoW-Miners 可能未声明，避免 TS7016）…"
    npm install --no-save --no-audit --no-fund --loglevel=error @types/bs58 2>/dev/null || true
  else
    log "跳过 npm install（node_modules 已就绪，设 FORCE_NPM=1 可强制）"
  fi

  mkdir -p target/idl
  IDL_PATH="target/idl/pow_protocol.json"

  if [[ -f "$IDL_PATH" && "$SKIP_IDL_FETCH" == "1" ]]; then
    log "跳过 IDL 拉取（SKIP_IDL_FETCH=1 且文件已存在）"
  elif command -v anchor >/dev/null 2>&1; then
    log "拉取 pow_protocol IDL…"
    anchor idl fetch "$PROGRAM_ID" --provider.cluster mainnet -o "$IDL_PATH" \
      || die "anchor idl fetch 失败；可手动放置 pow_protocol.json 后 export SKIP_IDL_FETCH=1"
  else
    [[ -f "$IDL_PATH" ]] || die "无 anchor：请将 pow_protocol.json 放到 $WORKDIR/$IDL_PATH 或安装 Anchor"
  fi

  [[ -f "$IDL_PATH" ]] || die "缺少 $IDL_PATH"

  WALLET_ABS="$(readlink -f "$WALLET_PATH")"
  RELAYER_ABS="$(readlink -f "$RELAYER_WALLET_PATH")"

  log "写入 miner-config.json"
  export _MG_RPC="$RPC_URL" _MG_PID="$PROGRAM_ID" _MG_MINT="$MINT" \
    _MG_WALLET="$WALLET_ABS" _MG_GPU_BACKEND="$GPU_BACKEND" _MG_GPU_DEV="$GPU_DEVICE" \
    _MG_CTHR="$CUDA_THREADS" _MG_CBLK="$CUDA_BLOCKS" _MG_POLL="$POLL_MS" \
    _MG_RELAYER="$RELAYER_ABS" _MG_POOL="$POOL_ID"
  python3 <<'PY' > miner-config.json
import json, os
cfg = {
    "rpc_url": os.environ["_MG_RPC"],
    "program_id": os.environ["_MG_PID"],
    "mint": os.environ["_MG_MINT"],
    "wallet_path": os.environ["_MG_WALLET"],
    "gpu_backend": os.environ["_MG_GPU_BACKEND"],
    "gpu_device": int(os.environ["_MG_GPU_DEV"]),
    "cuda_threads_per_block": int(os.environ["_MG_CTHR"]),
    "cuda_num_blocks": int(os.environ["_MG_CBLK"]),
    "challenge_poll_interval_ms": int(os.environ["_MG_POLL"]),
    "relayer_wallet_path": os.environ["_MG_RELAYER"],
    "pool_id": os.environ["_MG_POOL"],
}
print(json.dumps(cfg, indent=2))
PY
  unset _MG_RPC _MG_PID _MG_MINT _MG_WALLET _MG_GPU_BACKEND _MG_GPU_DEV \
    _MG_CTHR _MG_CBLK _MG_POLL _MG_RELAYER _MG_POOL || true

  if [[ ! -x "$MINER_BIN" ]] || [[ "${FORCE_REBUILD:-0}" == "1" ]] || gpu_sources_newer_than_bin; then
    log "cargo build -j$CARGO_BUILD_JOBS --release ($GPU_BACKEND)…"
    cd "$WORKDIR/gpu-miner"
    if [[ "$GPU_BACKEND" == "cuda" ]]; then
      cargo build --release --features cuda
    else
      cargo build --release --features opencl
    fi
    cd "$WORKDIR"
  else
    log "跳过 cargo build（二进制已是最新，设 FORCE_REBUILD=1 可强制）"
  fi

  [[ -x "$MINER_BIN" ]] || die "缺少 GPU 二进制: $MINER_BIN"
  log "环境就绪。"
else
  [[ -d "$WORKDIR" ]] || die "--mine-only 需要已有 $WORKDIR"
  cd "$WORKDIR"
  [[ -f miner-config.json ]] || die "缺少 miner-config.json"
  [[ -f target/idl/pow_protocol.json ]] || die "缺少 target/idl/pow_protocol.json"
  [[ -x "$MINER_BIN" ]] || die "缺少 $MINER_BIN"
fi

if [[ "$SETUP_ONLY" -eq 1 ]]; then
  log "--setup-only：结束。"
  exit 0
fi

cd "$WORKDIR"
need_cmd npx
log "启动 GPU 矿工… RPC=$RPC_URL"
# 上游可能缺少 @types/bs58，跳过仅类型检查（TS7016）
export TS_NODE_TRANSPILE_ONLY=1
exec npx ts-node --transpile-only standard-miner/continuous-gpu-miner.ts
