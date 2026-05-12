#!/usr/bin/env bash
# Hashish / pffthash PoW — Ubuntu GPU 挖矿脚本
# 流程对齐 https://github.com/Hashishdotfun/PoW-Miners
#
# 示例：
#   export WALLET_PATH="$HOME/.config/solana/id.json"
#   export RPC_URL="https://mainnet.helius-rpc.com/?api-key=YOUR_KEY"
#   chmod +x ubuntu-gpu-miner.sh
#   ./ubuntu-gpu-miner.sh
#
#   ./ubuntu-gpu-miner.sh --setup-only   # 只准备环境与编译
#   ./ubuntu-gpu-miner.sh --mine-only    # 已准备好则跳过克隆/编译，直接挖
#   ./ubuntu-gpu-miner.sh --install-apt  # sudo 安装常见编译依赖
#
# NVIDIA：驱动 + CUDA Toolkit 12+（nvcc 须在 PATH）
# AMD：OpenCL，构建前 export GPU_BACKEND=opencl
# OpenCL 可再配合：GPU_BACKEND=opencl ./ubuntu-gpu-miner.sh --install-apt
# 更省时流程见同目录 ubuntu-oneclick-fast.sh（浅克隆、智能跳过 npm/cargo 等）

set -euo pipefail

export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
export NPM_CONFIG_UPDATE_NOTIFIER=false

REPO_URL="${REPO_URL:-https://github.com/Hashishdotfun/PoW-Miners.git}"
WORKDIR="${WORKDIR:-$HOME/PoW-Miners}"

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

SETUP_ONLY=0
MINE_ONLY=0
INSTALL_APT=0

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \?//'
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
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "未找到命令「$1」，请先安装"; }
log() { echo "[ubuntu-gpu-miner] $*"; }

if [[ -z "$WALLET_PATH" ]]; then
  die "请设置 WALLET_PATH（Solana 密钥 JSON），例如: export WALLET_PATH=\$HOME/.config/solana/id.json"
fi
[[ -f "$WALLET_PATH" ]] || die "钱包文件不存在: $WALLET_PATH"

RELAYER_WALLET_PATH="${RELAYER_WALLET_PATH:-$WALLET_PATH}"

if [[ "$INSTALL_APT" -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  log "安装编译依赖（需要 sudo）…"
  sudo apt-get update -qq
  sudo apt-get install -y -qq build-essential pkg-config libssl-dev curl git ca-certificates python3
  if [[ "$GPU_BACKEND" == "opencl" ]]; then
    log "安装 OpenCL 头文件与 ICD 开发包（AMD/Intel 等）…"
    sudo apt-get install -y opencl-headers ocl-icd-opencl-dev clinfo || \
      log "部分 OpenCL 包不可用，请按显卡厂商文档手动安装 OpenCL SDK。"
  fi
fi

need_cmd git
need_cmd curl
need_cmd python3

if [[ "$GPU_BACKEND" != "cuda" && "$GPU_BACKEND" != "opencl" ]]; then
  die "GPU_BACKEND 必须是 cuda 或 opencl"
fi

if [[ "$GPU_BACKEND" == "cuda" ]]; then
  command -v nvcc >/dev/null 2>&1 || die "未找到 nvcc，请安装 CUDA Toolkit 12+ 并 export PATH（如 /usr/local/cuda/bin）"
  need_cmd nvidia-smi
fi

need_cmd node
NODE_MAJOR="$(node -p 'parseInt(process.versions.node,10)')"
[[ "$NODE_MAJOR" -ge 18 ]] || die "需要 Node.js 18+，当前: $(node -v)"

need_cmd npm
need_cmd rustc
need_cmd cargo

MINER_BIN="$WORKDIR/gpu-miner/target/release/miner"

if [[ "$MINE_ONLY" -eq 0 ]]; then
  if [[ ! -d "$WORKDIR/.git" ]]; then
    log "克隆仓库 → $WORKDIR（GIT_DEPTH=${GIT_DEPTH:-0}）"
    if [[ "${GIT_DEPTH:-0}" != "0" ]]; then
      git clone --depth "$GIT_DEPTH" "$REPO_URL" "$WORKDIR"
    else
      git clone "$REPO_URL" "$WORKDIR"
    fi
  else
    log "尝试更新 $WORKDIR"
    git -C "$WORKDIR" pull --ff-only || true
  fi

  cd "$WORKDIR"

  log "npm install"
  npm install --no-audit --no-fund --loglevel=error

  mkdir -p target/idl

  if command -v anchor >/dev/null 2>&1; then
    log "拉取 pow_protocol IDL…"
    anchor idl fetch "$PROGRAM_ID" --provider.cluster mainnet -o target/idl/pow_protocol.json \
      || die "anchor idl fetch 失败；请安装 Anchor 或手动拷贝 pow_protocol.json 到 target/idl/"
  else
    die "未检测到 anchor。请安装后重试，或将 PoW-Programs 的 target/idl/pow_protocol.json 拷到 $WORKDIR/target/idl/"
  fi

  [[ -f target/idl/pow_protocol.json ]] || die "缺少 target/idl/pow_protocol.json"

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

  if [[ ! -x "$MINER_BIN" ]] || [[ "${FORCE_REBUILD:-0}" == "1" ]]; then
    log "cargo build --release （gpu_backend=$GPU_BACKEND）…"
    cd "$WORKDIR/gpu-miner"
    if [[ "$GPU_BACKEND" == "cuda" ]]; then
      cargo build --release --features cuda
    else
      cargo build --release --features opencl
    fi
    cd "$WORKDIR"
  fi

  [[ -x "$MINER_BIN" ]] || die "未找到 GPU 二进制: $MINER_BIN ，请先成功编译 gpu-miner"
  log "环境就绪。"
else
  [[ -d "$WORKDIR" ]] || die "--mine-only 需要已有目录: $WORKDIR（先不带该参数运行一次）"
  cd "$WORKDIR"
  [[ -f miner-config.json ]] || die "缺少 miner-config.json"
  [[ -f target/idl/pow_protocol.json ]] || die "缺少 target/idl/pow_protocol.json"
  [[ -x "$MINER_BIN" ]] || die "缺少可执行 GPU 二进制: $MINER_BIN"
fi

if [[ "$SETUP_ONLY" -eq 1 ]]; then
  log "--setup-only：不启动挖矿。"
  exit 0
fi

cd "$WORKDIR"
need_cmd npx

log "启动 continuous-gpu-miner.ts"
log "RPC=$RPC_URL"
exec npx ts-node standard-miner/continuous-gpu-miner.ts
