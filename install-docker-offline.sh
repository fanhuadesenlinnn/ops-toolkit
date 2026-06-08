#!/usr/bin/env bash
#==============================================================================
#
#          FILE:  install-docker-offline.sh
#
#   DESCRIPTION:  Docker 离线二进制安装独立脚本（thin wrapper）。
#                 功能已合并到 linux-admin-toolkit.sh 的 docker-offline 模块。
#                 本脚本保持后向兼容：直接转发参数到 toolkit 的 docker-offline 命令。
#
#      VERSION:  2.0.0（thin wrapper）
#
#==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLKIT="${SCRIPT_DIR}/linux-admin-toolkit.sh"

if [[ ! -f "$TOOLKIT" ]]; then
  printf '\033[1;31m[ERR ]\033[0m 未找到 linux-admin-toolkit.sh。请将本脚本放在 ops-toolkit 仓库根目录下运行。\n' >&2
  exit 1
fi

if [[ ! -x "$TOOLKIT" ]]; then
  chmod +x "$TOOLKIT" 2>/dev/null || true
fi

exec bash "$TOOLKIT" docker-offline "$@"
