#!/usr/bin/env bash
# 离线二进制安装 Docker Engine + Docker Compose
# 支持：麒麟/Kylin、Arch Linux 系列、Debian/Ubuntu 系列及大多数 systemd Linux
# 功能：下载资源、离线安装、重复安装/升级、卸载、打包离线包、可配置下载地址

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="/var/lib/docker-offline-installer"
MANIFEST_FILE="$STATE_DIR/manifest"
BACKUP_MANIFEST_FILE="$STATE_DIR/backup-manifest"
DEFAULT_RESOURCE_DIR="./resources"

# 默认值：version=latest 会在 download 时尝试解析最新版本；离线安装时会从资源目录选择最高版本。
ACTION="install"
RESOURCE_DIR="$DEFAULT_RESOURCE_DIR"
DOCKER_VERSION="latest"
COMPOSE_VERSION="latest"
DOCKER_CHANNEL="stable"
ARCH_OVERRIDE=""
DOWNLOAD_IF_MISSING="false"
START_SERVICE="true"
ENABLE_SERVICE="true"
SKIP_DOCKER="false"
SKIP_COMPOSE="false"
PURGE_DATA="false"
PACKAGE_FILE=""
DRY_RUN="false"
YES="false"
DATA_ROOT=""
REGISTRY_MIRROR=""

# 可通过参数覆盖。支持占位符：{channel} {arch} {version}
DOCKER_URL_TEMPLATE="https://download.docker.com/linux/static/{channel}/{arch}/docker-{version}.tgz"
COMPOSE_URL_TEMPLATE="https://github.com/docker/compose/releases/download/v{version}/docker-compose-linux-{arch}"
COMPOSE_LATEST_URL_TEMPLATE="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-{arch}"

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'USAGE'
用法：
  ./install-docker-offline.sh install   [选项]   # 安装/重复安装/升级
  ./install-docker-offline.sh download  [选项]   # 只下载 Docker/Compose 二进制资源到 resources 目录
  ./install-docker-offline.sh package   [选项]   # 下载资源并打包成离线包 tar.gz
  ./install-docker-offline.sh uninstall [选项]   # 卸载本脚本安装的文件
  ./install-docker-offline.sh status              # 查看状态

常用选项：
  --resource-dir DIR             资源目录，默认 ./resources
  --docker-version VERSION       Docker Engine 版本，例如 28.5.1；默认 latest
  --compose-version VERSION      Docker Compose 版本，例如 2.40.3；默认 latest
  --arch ARCH                    指定架构：x86_64 / aarch64；默认自动识别
  --download-if-missing          install 时如果资源不存在，自动下载
  --skip-docker                  不处理 Docker Engine
  --skip-compose                 不处理 Docker Compose
  --no-start                     安装后不启动 docker 服务
  --no-enable                    安装后不设置开机自启
  --data-root DIR                首次创建 /etc/docker/daemon.json 时写入 data-root
  --registry-mirror URL          首次创建 /etc/docker/daemon.json 时写入 registry-mirrors
  --docker-channel CHANNEL       Docker 下载通道：stable/test/nightly，默认 stable
  --docker-url-template URL      Docker 下载 URL 模板，支持 {channel}/{arch}/{version}
  --compose-url-template URL     Compose 指定版本下载 URL 模板，支持 {arch}/{version}
  --compose-latest-url-template URL Compose latest 下载 URL 模板，支持 {arch}
  --package-file FILE            package 输出文件名
  --purge-data                   uninstall 时同时删除 /var/lib/docker、/var/lib/containerd、/etc/docker
  -y, --yes                      非交互确认
  -h, --help                     帮助

示例：
  # 1）联网机器下载指定版本资源
  ./install-docker-offline.sh download --docker-version 28.5.1 --compose-version 2.40.3

  # 2）联网机器直接制作离线包
  ./install-docker-offline.sh package --docker-version 28.5.1 --compose-version 2.40.3 \
    --package-file docker-offline-28.5.1-compose-2.40.3.tar.gz

  # 3）离线机器解压后安装
  tar -xzf docker-offline-28.5.1-compose-2.40.3.tar.gz
  cd docker-offline-28.5.1-compose-2.40.3
  sudo ./install-docker-offline.sh install --resource-dir ./resources

  # 4）安装时本地缺资源则自动下载
  sudo ./install-docker-offline.sh install --download-if-missing --docker-version 28.5.1 --compose-version 2.40.3

  # 5）卸载，但保留容器/镜像/卷数据
  sudo ./install-docker-offline.sh uninstall

  # 6）彻底卸载，同时删除 Docker 数据，危险
  sudo ./install-docker-offline.sh uninstall --purge-data -y
USAGE
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "此操作需要 root 权限，请使用 sudo 运行。"
  fi
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY-RUN] %q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

confirm_or_die() {
  local msg="$1"
  if [[ "$YES" == "true" ]]; then return 0; fi
  read -r -p "$msg [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "用户取消。"
}

detect_os() {
  local id="unknown" like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}"
    like="${ID_LIKE:-}"
  fi

  case " $id $like " in
    *kylin*|*Kylin*|*ubuntu*|*debian*|*uos*|*deepin*|*arch*)
      log "检测到系统：ID=$id ID_LIKE=${like:-无}"
      ;;
    *)
      warn "未明确识别为麒麟/Arch/Debian/Ubuntu，但二进制安装通常仍可继续：ID=$id ID_LIKE=${like:-无}"
      ;;
  esac
}

detect_arch() {
  local raw="${ARCH_OVERRIDE:-$(uname -m)}"
  case "$raw" in
    x86_64|amd64)
      DOCKER_ARCH="x86_64"
      COMPOSE_ARCH="x86_64"
      ;;
    aarch64|arm64)
      DOCKER_ARCH="aarch64"
      COMPOSE_ARCH="aarch64"
      ;;
    *)
      die "暂不支持架构：$raw。建议使用 x86_64 或 aarch64。"
      ;;
  esac
  log "使用架构：Docker=$DOCKER_ARCH Compose=$COMPOSE_ARCH"
}

replace_placeholders() {
  local s="$1"
  s="${s//\{channel\}/$DOCKER_CHANNEL}"
  s="${s//\{arch\}/$DOCKER_ARCH}"
  s="${s//\{version\}/$DOCKER_VERSION}"
  printf '%s' "$s"
}

replace_compose_placeholders() {
  local s="$1"
  s="${s//\{arch\}/$COMPOSE_ARCH}"
  s="${s//\{version\}/$COMPOSE_VERSION}"
  printf '%s' "$s"
}

download_file() {
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  log "下载：$url"
  log "保存：$out"
  if has_cmd curl; then
    run curl -fL --retry 3 --connect-timeout 20 -o "$out.tmp" "$url"
  elif has_cmd wget; then
    run wget -O "$out.tmp" "$url"
  else
    die "缺少 curl 或 wget，无法下载。请先安装 curl/wget，或手工放入资源目录。"
  fi
  run mv -f "$out.tmp" "$out"
}

fetch_text() {
  local url="$1"
  if has_cmd curl; then
    curl -fsL --connect-timeout 20 "$url"
  elif has_cmd wget; then
    wget -qO- "$url"
  else
    return 1
  fi
}

resolve_latest_docker_online() {
  local index_url="https://download.docker.com/linux/static/${DOCKER_CHANNEL}/${DOCKER_ARCH}/"
  local latest
  latest="$(fetch_text "$index_url" \
    | grep -oE 'docker-[0-9]+(\.[0-9]+)+(-ce)?\.tgz' \
    | sed -E 's/^docker-//; s/\.tgz$//; s/-ce$//' \
    | sort -Vu \
    | tail -n 1 || true)"
  [[ -n "$latest" ]] || die "无法解析 Docker latest，请显式指定 --docker-version。"
  DOCKER_VERSION="$latest"
  log "解析到 Docker latest：$DOCKER_VERSION"
}

resolve_latest_docker_local() {
  local latest=""
  if [[ -d "$RESOURCE_DIR" ]]; then
    latest="$(find "$RESOURCE_DIR" -maxdepth 1 -type f -name 'docker-*.tgz' -printf '%f\n' 2>/dev/null \
      | sed -E 's/^docker-//; s/\.tgz$//; s/-x86_64$//; s/-aarch64$//; s/-ce$//' \
      | grep -E '^[0-9]+(\.[0-9]+)+' \
      | sort -Vu \
      | tail -n 1 || true)"
  fi
  [[ -n "$latest" ]] || return 1
  DOCKER_VERSION="$latest"
  log "从本地资源解析到 Docker 最高版本：$DOCKER_VERSION"
}

resolve_latest_compose_online() {
  # latest 下载地址不需要提前知道版本；安装后用 docker compose version 确认。
  COMPOSE_VERSION="latest"
}

resolve_latest_compose_local() {
  local latest=""
  if [[ -d "$RESOURCE_DIR" ]]; then
    latest="$(find "$RESOURCE_DIR" -maxdepth 1 -type f \( -name 'docker-compose-*-linux-*' -o -name 'docker-compose-linux-*' \) -printf '%f\n' 2>/dev/null \
      | sed -E 's/^docker-compose-//; s/-linux-(x86_64|aarch64)$//; s/^linux-(x86_64|aarch64)$/latest/' \
      | grep -E '^latest$|^[0-9]+(\.[0-9]+)+' \
      | sort -Vu \
      | tail -n 1 || true)"
  fi
  [[ -n "$latest" ]] || return 1
  COMPOSE_VERSION="$latest"
  log "从本地资源解析到 Compose 版本：$COMPOSE_VERSION"
}

docker_url() {
  replace_placeholders "$DOCKER_URL_TEMPLATE"
}

compose_url() {
  if [[ "$COMPOSE_VERSION" == "latest" ]]; then
    replace_compose_placeholders "$COMPOSE_LATEST_URL_TEMPLATE"
  else
    replace_compose_placeholders "$COMPOSE_URL_TEMPLATE"
  fi
}

docker_resource_path() {
  printf '%s/docker-%s-%s.tgz' "$RESOURCE_DIR" "$DOCKER_VERSION" "$DOCKER_ARCH"
}

compose_resource_path() {
  if [[ "$COMPOSE_VERSION" == "latest" ]]; then
    printf '%s/docker-compose-linux-%s' "$RESOURCE_DIR" "$COMPOSE_ARCH"
  else
    printf '%s/docker-compose-%s-linux-%s' "$RESOURCE_DIR" "$COMPOSE_VERSION" "$COMPOSE_ARCH"
  fi
}

find_docker_resource() {
  local p
  if [[ "$DOCKER_VERSION" == "latest" ]]; then
    resolve_latest_docker_local || true
  fi
  local candidates=(
    "$RESOURCE_DIR/docker-${DOCKER_VERSION}-${DOCKER_ARCH}.tgz"
    "$RESOURCE_DIR/docker-${DOCKER_VERSION}.tgz"
    "$RESOURCE_DIR/docker-${DOCKER_VERSION}-ce-${DOCKER_ARCH}.tgz"
    "$RESOURCE_DIR/docker-${DOCKER_VERSION}-ce.tgz"
  )
  for p in "${candidates[@]}"; do
    [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

find_compose_resource() {
  local p
  if [[ "$COMPOSE_VERSION" == "latest" ]]; then
    resolve_latest_compose_local || true
  fi
  local candidates=(
    "$RESOURCE_DIR/docker-compose-${COMPOSE_VERSION}-linux-${COMPOSE_ARCH}"
    "$RESOURCE_DIR/docker-compose-linux-${COMPOSE_ARCH}"
    "$RESOURCE_DIR/docker-compose"
  )
  for p in "${candidates[@]}"; do
    [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

action_download() {
  detect_arch
  mkdir -p "$RESOURCE_DIR"

  if [[ "$SKIP_DOCKER" != "true" ]]; then
    if [[ "$DOCKER_VERSION" == "latest" ]]; then
      resolve_latest_docker_online
    fi
    local docker_out
    docker_out="$(docker_resource_path)"
    if [[ -f "$docker_out" ]]; then
      log "Docker 资源已存在，跳过：$docker_out"
    else
      download_file "$(docker_url)" "$docker_out"
    fi
  fi

  if [[ "$SKIP_COMPOSE" != "true" ]]; then
    if [[ "$COMPOSE_VERSION" == "latest" ]]; then
      resolve_latest_compose_online
    fi
    local compose_out
    compose_out="$(compose_resource_path)"
    if [[ -f "$compose_out" ]]; then
      log "Compose 资源已存在，跳过：$compose_out"
    else
      download_file "$(compose_url)" "$compose_out"
      run chmod +x "$compose_out"
    fi
  fi

  log "资源准备完成：$RESOURCE_DIR"
}

ensure_resource_or_download() {
  local kind="$1"
  if [[ "$kind" == "docker" ]]; then
    if find_docker_resource >/dev/null; then return 0; fi
  else
    if find_compose_resource >/dev/null; then return 0; fi
  fi

  if [[ "$DOWNLOAD_IF_MISSING" == "true" ]]; then
    log "$kind 资源不存在，按要求自动下载。"
    if [[ "$kind" == "docker" ]]; then
      local old_skip_compose="$SKIP_COMPOSE"
      SKIP_COMPOSE="true"; action_download; SKIP_COMPOSE="$old_skip_compose"
    else
      local old_skip_docker="$SKIP_DOCKER"
      SKIP_DOCKER="true"; action_download; SKIP_DOCKER="$old_skip_docker"
    fi
    return 0
  fi

  die "$kind 资源不存在。请先执行 download/package，或 install 时加 --download-if-missing。资源目录：$RESOURCE_DIR"
}

ensure_state() {
  mkdir -p "$STATE_DIR"
  touch "$MANIFEST_FILE" "$BACKUP_MANIFEST_FILE"
}

path_in_manifest() {
  local path="$1"
  [[ -f "$MANIFEST_FILE" ]] && grep -Fxq "$path" "$MANIFEST_FILE"
}

add_manifest() {
  local path="$1"
  grep -Fxq "$path" "$MANIFEST_FILE" 2>/dev/null || printf '%s\n' "$path" >> "$MANIFEST_FILE"
}

backup_existing_if_needed() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  path_in_manifest "$target" && return 0

  local encoded backup_path
  encoded="$(printf '%s' "$target" | sed 's#/#__#g')"
  backup_path="$STATE_DIR/backups/$encoded"
  mkdir -p "$(dirname "$backup_path")"

  if [[ -L "$target" ]]; then
    cp -P "$target" "$backup_path"
  elif [[ -d "$target" ]]; then
    cp -a "$target" "$backup_path"
  else
    cp -a "$target" "$backup_path"
  fi
  printf '%s|%s\n' "$target" "$backup_path" >> "$BACKUP_MANIFEST_FILE"
  warn "发现已有文件，已备份：$target -> $backup_path"
}

install_file_managed() {
  local src="$1" target="$2" mode="${3:-0755}"
  ensure_state
  backup_existing_if_needed "$target"
  mkdir -p "$(dirname "$target")"
  install -m "$mode" "$src" "$target"
  add_manifest "$target"
}

install_symlink_managed() {
  local link_target="$1" link_path="$2"
  ensure_state
  backup_existing_if_needed "$link_path"
  mkdir -p "$(dirname "$link_path")"
  ln -sfn "$link_target" "$link_path"
  add_manifest "$link_path"
}

write_text_managed() {
  local target="$1" mode="$2"
  ensure_state
  backup_existing_if_needed "$target"
  mkdir -p "$(dirname "$target")"
  cat > "$target"
  chmod "$mode" "$target"
  add_manifest "$target"
}

preflight_install() {
  need_root
  detect_os
  detect_arch

  if ! has_cmd tar; then die "缺少 tar，无法解压 Docker 二进制包。"; fi
  if ! has_cmd systemctl; then
    warn "当前系统未检测到 systemctl。脚本仍会安装二进制，但不能自动创建/启动 systemd 服务。"
  fi

  local missing=()
  for c in iptables modprobe; do
    has_cmd "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    warn "缺少可能影响 Docker 运行的系统命令：${missing[*]}。离线脚本不会自动安装系统依赖。"
  fi
}

create_daemon_json_if_missing() {
  local target="/etc/docker/daemon.json"
  if [[ -f "$target" ]]; then
    log "已存在 $target，保持不覆盖。"
    return 0
  fi

  mkdir -p /etc/docker
  local tmp
  tmp="$(mktemp)"
  {
    printf '{\n'
    printf '  "log-driver": "json-file",\n'
    printf '  "log-opts": {"max-size": "100m", "max-file": "3"}'
    if [[ -n "$DATA_ROOT" ]]; then
      printf ',\n  "data-root": "%s"' "$DATA_ROOT"
    fi
    if [[ -n "$REGISTRY_MIRROR" ]]; then
      printf ',\n  "registry-mirrors": ["%s"]' "$REGISTRY_MIRROR"
    fi
    printf '\n}\n'
  } > "$tmp"
  install_file_managed "$tmp" "$target" 0644
  rm -f "$tmp"
  log "已创建默认 Docker 配置：$target"
}

create_systemd_service() {
  if ! has_cmd systemctl; then return 0; fi

  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'SERVICE'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd --host=unix:///var/run/docker.sock
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
Restart=always
RestartSec=2
Delegate=yes
KillMode=process
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
SERVICE
  install_file_managed "$tmp" "/etc/systemd/system/docker.service" 0644
  rm -f "$tmp"
  systemctl daemon-reload
}

install_docker() {
  ensure_resource_or_download docker
  local tgz tmpdir
  tgz="$(find_docker_resource)"
  log "安装 Docker Engine：$tgz"

  tmpdir="$(mktemp -d)"
  tar -xzf "$tgz" -C "$tmpdir"
  [[ -d "$tmpdir/docker" ]] || die "Docker 压缩包格式异常，未找到 docker/ 目录。"

  local f base
  for f in "$tmpdir/docker"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    install_file_managed "$f" "/usr/local/bin/$base" 0755
  done
  rm -rf "$tmpdir"

  if has_cmd groupadd; then
    groupadd -f docker || warn "创建 docker 用户组失败，可手工检查。"
  fi

  create_daemon_json_if_missing
  create_systemd_service

  if has_cmd systemctl; then
    if [[ "$ENABLE_SERVICE" == "true" ]]; then
      systemctl enable docker.service >/dev/null || warn "设置 docker 开机自启失败。"
    fi
    if [[ "$START_SERVICE" == "true" ]]; then
      systemctl restart docker.service || warn "docker 服务启动失败，请执行：journalctl -u docker -xe 查看原因。"
    fi
  fi
}

install_compose() {
  ensure_resource_or_download compose
  local src plugin_dir plugin_path
  src="$(find_compose_resource)"
  plugin_dir="/usr/local/lib/docker/cli-plugins"
  plugin_path="$plugin_dir/docker-compose"

  log "安装 Docker Compose：$src"
  install_file_managed "$src" "$plugin_path" 0755
  install_symlink_managed "$plugin_path" "/usr/local/bin/docker-compose"
}

action_install() {
  preflight_install
  [[ "$SKIP_DOCKER" == "true" ]] || install_docker
  [[ "$SKIP_COMPOSE" == "true" ]] || install_compose
  log "安装完成。"
  action_status || true
  cat <<'TIP'
提示：
  - Docker Compose v2 推荐命令：docker compose version
  - 兼容老习惯命令：docker-compose version
  - 非 root 用户使用 docker：sudo usermod -aG docker <用户名>，然后重新登录
TIP
}

restore_backups() {
  [[ -f "$BACKUP_MANIFEST_FILE" ]] || return 0
  tac "$BACKUP_MANIFEST_FILE" 2>/dev/null | while IFS='|' read -r target backup_path; do
    [[ -n "${target:-}" && -n "${backup_path:-}" ]] || continue
    [[ -e "$backup_path" || -L "$backup_path" ]] || continue
    mkdir -p "$(dirname "$target")"
    rm -rf "$target"
    if [[ -L "$backup_path" ]]; then
      cp -P "$backup_path" "$target"
    else
      cp -a "$backup_path" "$target"
    fi
    log "已恢复原有文件：$target"
  done
}

action_uninstall() {
  need_root
  if [[ "$PURGE_DATA" == "true" ]]; then
    confirm_or_die "即将删除 Docker 程序和数据目录 /var/lib/docker /var/lib/containerd /etc/docker，确认继续？"
  fi

  if has_cmd systemctl; then
    systemctl stop docker.service 2>/dev/null || true
    systemctl disable docker.service >/dev/null 2>&1 || true
  fi

  if [[ -f "$MANIFEST_FILE" ]]; then
    tac "$MANIFEST_FILE" 2>/dev/null | while read -r path; do
      [[ -n "$path" ]] || continue
      if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path"
        log "已删除：$path"
      fi
    done
  else
    warn "未找到安装清单：$MANIFEST_FILE。为安全起见，不盲目删除系统文件。"
  fi

  restore_backups

  if has_cmd systemctl; then
    systemctl daemon-reload || true
  fi

  if [[ "$PURGE_DATA" == "true" ]]; then
    rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    log "已删除 Docker 数据和配置目录。"
  else
    log "已保留 Docker 数据目录。如需删除数据，请重新执行 uninstall --purge-data。"
  fi

  rm -rf "$STATE_DIR"
  log "卸载完成。"
}

action_status() {
  printf '\n==== Docker 状态 ====\n'
  if has_cmd docker; then
    docker --version || true
  else
    echo "docker 命令：未安装或不在 PATH"
  fi

  if has_cmd docker; then
    docker compose version 2>/dev/null || true
  fi
  if has_cmd docker-compose; then
    docker-compose version 2>/dev/null || true
  fi

  if has_cmd systemctl; then
    systemctl --no-pager --full status docker.service 2>/dev/null | sed -n '1,12p' || true
  fi
  printf '=====================\n\n'
}

write_package_readme() {
  local dir="$1"
  cat > "$dir/README.txt" <<EOF_README
Docker 离线二进制安装包

目录：
  install-docker-offline.sh  安装脚本
  resources/                  Docker/Compose 二进制资源

离线安装：
  sudo ./install-docker-offline.sh install --resource-dir ./resources

卸载：
  sudo ./install-docker-offline.sh uninstall

彻底卸载，删除镜像/容器/卷数据：
  sudo ./install-docker-offline.sh uninstall --purge-data -y

版本：
  Docker Engine:  $DOCKER_VERSION
  Docker Compose: $COMPOSE_VERSION
  架构:            ${DOCKER_ARCH:-unknown}
EOF_README
}

action_package() {
  detect_arch
  action_download

  local self pkg_base staging out
  self="$(readlink -f "$0" 2>/dev/null || true)"
  [[ -f "$self" ]] || die "无法定位当前脚本文件。请将脚本保存为文件后再执行 package。"

  pkg_base="docker-offline-${DOCKER_VERSION}-compose-${COMPOSE_VERSION}-${DOCKER_ARCH}"
  out="${PACKAGE_FILE:-${pkg_base}.tar.gz}"
  staging="$(mktemp -d)"
  mkdir -p "$staging/$pkg_base/resources"

  cp "$self" "$staging/$pkg_base/install-docker-offline.sh"
  chmod +x "$staging/$pkg_base/install-docker-offline.sh"

  if [[ "$SKIP_DOCKER" != "true" ]]; then
    cp "$(find_docker_resource)" "$staging/$pkg_base/resources/"
  fi
  if [[ "$SKIP_COMPOSE" != "true" ]]; then
    cp "$(find_compose_resource)" "$staging/$pkg_base/resources/"
  fi

  write_package_readme "$staging/$pkg_base"
  tar -czf "$out" -C "$staging" "$pkg_base"
  rm -rf "$staging"
  log "离线包已生成：$out"
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|download|package|uninstall|status|help)
        ACTION="$1"; shift || true ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resource-dir) RESOURCE_DIR="$2"; shift 2 ;;
      --docker-version) DOCKER_VERSION="${2#v}"; shift 2 ;;
      --compose-version) COMPOSE_VERSION="${2#v}"; shift 2 ;;
      --arch) ARCH_OVERRIDE="$2"; shift 2 ;;
      --download-if-missing) DOWNLOAD_IF_MISSING="true"; shift ;;
      --skip-docker) SKIP_DOCKER="true"; shift ;;
      --skip-compose) SKIP_COMPOSE="true"; shift ;;
      --no-start) START_SERVICE="false"; shift ;;
      --no-enable) ENABLE_SERVICE="false"; shift ;;
      --data-root) DATA_ROOT="$2"; shift 2 ;;
      --registry-mirror) REGISTRY_MIRROR="$2"; shift 2 ;;
      --docker-channel) DOCKER_CHANNEL="$2"; shift 2 ;;
      --docker-url-template) DOCKER_URL_TEMPLATE="$2"; shift 2 ;;
      --compose-url-template) COMPOSE_URL_TEMPLATE="$2"; shift 2 ;;
      --compose-latest-url-template) COMPOSE_LATEST_URL_TEMPLATE="$2"; shift 2 ;;
      --package-file) PACKAGE_FILE="$2"; shift 2 ;;
      --purge-data) PURGE_DATA="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      -y|--yes) YES="true"; shift ;;
      -h|--help) ACTION="help"; shift ;;
      *) die "未知参数：$1。执行 --help 查看帮助。" ;;
    esac
  done

  RESOURCE_DIR="$(mkdir -p "$RESOURCE_DIR" 2>/dev/null && cd "$RESOURCE_DIR" && pwd || printf '%s' "$RESOURCE_DIR")"
}

main() {
  parse_args "$@"
  case "$ACTION" in
    install) action_install ;;
    download) action_download ;;
    package) action_package ;;
    uninstall) action_uninstall ;;
    status) action_status ;;
    help) usage ;;
    *) usage; die "未知动作：$ACTION" ;;
  esac
}

main "$@"
