#!/usr/bin/env bash
# 停止由 ubuntu-oneclick-fast.sh --background 启动的后台矿工及其子进程
set -euo pipefail

PID_FILE="${MINER_PID_FILE:-$HOME/.local/share/pffthash/hashish-miner.pid}"

recursive_kill() {
  local parent=$1
  local sig=$2
  local c
  for c in $(pgrep -P "$parent" 2>/dev/null || true); do
    recursive_kill "$c" "$sig"
  done
  kill -s "$sig" "$parent" 2>/dev/null || true
}

if [[ ! -f "$PID_FILE" ]]; then
  echo "未找到 PID 文件: $PID_FILE" >&2
  exit 1
fi

pid="$(tr -d ' \n' < "$PID_FILE" || true)"
if [[ -z "${pid:-}" ]]; then
  rm -f "$PID_FILE"
  exit 1
fi

if kill -0 "$pid" 2>/dev/null; then
  echo "正在停止矿工 (root pid=$pid)…"
  recursive_kill "$pid" TERM
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    echo "强制结束…"
    recursive_kill "$pid" KILL
  fi
  echo "已停止。"
else
  echo "进程 $pid 已不存在，清理 PID 文件。"
fi

rm -f "$PID_FILE"
