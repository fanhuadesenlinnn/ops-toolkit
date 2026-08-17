#!/usr/bin/env bash
# Linux/macOS Admin Toolkit
# Linux 与 macOS 软件安装、Shell 环境、Docker、防火墙、Swap/LVM、性能排查、主机巡检、用户/SSH、定时任务、日志、网络、系统配置、磁盘与进程管理脚本。
# 默认使用官方源，也内置中国大陆常用镜像源，适合不同网络环境。
# Linux 支持：Arch Linux、Kylin V10、CentOS/CentOS Stream、Ubuntu、Debian、Fedora 及常见衍生系统。
# macOS 支持：Homebrew、常用工具、Zsh/Oh My Zsh、rupa/z、Docker Desktop、基础性能排查。

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME="$(basename "$0")"
TOOL_VERSION="0.6.0"
ASSUME_YES=0
DRY_RUN=0
NO_COLOR=0
PKG_UPDATED=0
BACKUP_ROOT="/var/backups/linux-admin-toolkit"
AUDIT_LOG="${LINUX_ADMIN_AUDIT_LOG:-/var/log/linux-admin-toolkit.log}"
CONFIG_FILE="${LINUX_ADMIN_CONFIG:-$HOME/.config/ops-toolkit/config}"
CANCEL_RC=130
SKIP_RC=100
DEFAULT_SOURCE="${LINUX_ADMIN_SOURCE:-official}"
DEFAULT_DOCKER_SOURCE="${LINUX_ADMIN_DOCKER_SOURCE:-official}"
# ---------- Docker 离线安装变量 ----------
OFFLINE_STATE_DIR="/var/lib/docker-offline-installer"
OFFLINE_MANIFEST_FILE="$OFFLINE_STATE_DIR/manifest"
OFFLINE_BACKUP_MANIFEST_FILE="$OFFLINE_STATE_DIR/backup-manifest"
OFFLINE_RESOURCE_DIR="./resources"
OFFLINE_DOCKER_VERSION="latest"
OFFLINE_COMPOSE_VERSION="latest"
OFFLINE_DOCKER_CHANNEL="stable"
OFFLINE_ARCH_OVERRIDE=""
OFFLINE_DOWNLOAD_IF_MISSING=0
OFFLINE_SKIP_DOCKER=0
OFFLINE_SKIP_COMPOSE=0
OFFLINE_PURGE_DATA=0
OFFLINE_PACKAGE_FILE=""
OFFLINE_DATA_ROOT=""
OFFLINE_REGISTRY_MIRROR=""
OFFLINE_START_SERVICE=1
OFFLINE_ENABLE_SERVICE=1
OFFLINE_DOCKER_URL_TEMPLATE="https://download.docker.com/linux/static/{channel}/{arch}/docker-{version}.tgz"
OFFLINE_COMPOSE_URL_TEMPLATE="https://github.com/docker/compose/releases/download/v{version}/docker-compose-linux-{arch}"
OFFLINE_COMPOSE_LATEST_URL_TEMPLATE="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-{arch}"
OFFLINE_DOCKER_ARCH=""
OFFLINE_COMPOSE_ARCH=""
GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-}"
CHOSEN_MIRROR_SOURCE=""
OS_ID=""; OS_LIKE=""; OS_NAME=""; OS_VERSION_ID=""; OS_CODENAME=""; PKG_MANAGER=""; PLATFORM=""
# ---------- LVM 管理变量 (融合自 lvm-manager.sh) ----------
LVM_DISK=""; LVM_VG=""; LVM_LV=""; LVM_SIZE=""; LVM_FS=""; LVM_MOUNT=""
LVM_POS=()
LVM_FSTAB_BACKED_UP=0
LVM_PLANNED_VG=0
LVM_CREATED_PV=0
LVM_CREATED_VG=0
LVM_CREATED_LV=0
LVM_MOUNT_CONFIRMED=0

_color() { local code="$1"; shift || true; if [[ "$NO_COLOR" -eq 1 || ! -t 1 ]]; then printf '%s\n' "$*"; else printf '\033[%sm%s\033[0m\n' "$code" "$*"; fi; }
info() { _color "1;34" "[INFO] $*"; }
success() { _color "1;32" "[OK] $*"; }
warn() { _color "1;33" "[WARN] $*"; }
error() { _color "1;31" "[ERROR] $*" >&2; }
fatal() { error "$*"; exit 1; }

format_cmd() { local arg quoted out=""; for arg in "$@"; do printf -v quoted '%q' "$arg"; out="${out}${out:+ }${quoted}"; done; printf '%s' "$out"; }
audit_log() { local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"; { mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null && printf '[%s] %s\n' "$ts" "$*" >> "$AUDIT_LOG"; } 2>/dev/null || true; }
run() { info "+ $(format_cmd "$@")"; audit_log "RUN: $(format_cmd "$@")"; [[ "$DRY_RUN" -eq 1 ]] && return 0; "$@"; }
run_shell() { info "+ $*"; [[ "$DRY_RUN" -eq 1 ]] && return 0; bash -Eeuo pipefail -c "$*"; }
cmd_path() { local cmd="${1:-}" d; [[ -n "$cmd" ]] || return 1; command -v "$cmd" 2>/dev/null && return 0; for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin /usr/bin /bin /usr/sbin /sbin; do [[ -x "$d/$cmd" ]] && { printf '%s\n' "$d/$cmd"; return 0; }; done; return 1; }
has_cmd() { cmd_path "${1:-}" >/dev/null 2>&1; }
trim_string() { local s="${1:-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
has_unsafe_url_chars() { local v="${1:-}"; [[ "$v" == *"'"* || "$v" == *\"* || "$v" == *"\`"* || "$v" == *"\\"* || "$v" == *";"* || "$v" == *"|"* || "$v" =~ [[:space:]] ]]; }
confirm() { local prompt="${1:-确认继续？}" ans; [[ "$ASSUME_YES" -eq 1 ]] && return 0; [[ "$DRY_RUN" -eq 1 ]] && return 0; echo >&2; echo "$prompt" >&2; echo "1) 是，继续" >&2; echo "2) 否，取消" >&2; read -r -p "请选择 [2]: " ans; case "${ans:-}" in 1|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac; }
cancelled() { warn "用户取消操作。"; return "$CANCEL_RC"; }
skipped() { warn "$*"; return "$SKIP_RC"; }
not_applicable() { skipped "$*"; }
menu_pause() { [[ -t 0 ]] && read -r -p "按 Enter 返回当前菜单..." _ || true; }
run_privileged() { if [[ "${EUID}" -eq 0 ]]; then run "$@"; else has_cmd sudo || fatal "需要管理员权限，但未找到 sudo。"; run sudo "$@"; fi; }
write_file() { local file="$1" dir; dir="$(dirname "$file")"; if [[ "$DRY_RUN" -eq 1 ]]; then info "+ write file $file"; cat >/dev/null; return 0; fi; mkdir -p "$dir"; cat > "$file"; }
append_file() { local file="$1" dir; dir="$(dirname "$file")"; if [[ "$DRY_RUN" -eq 1 ]]; then info "+ append file $file"; cat >/dev/null; return 0; fi; mkdir -p "$dir"; cat >> "$file"; }
append_line_if_missing() { local file="$1" line="$2" dir; dir="$(dirname "$file")"; [[ "$DRY_RUN" -eq 1 ]] && { info "+ append line to $file if missing: $line"; return 0; }; mkdir -p "$dir"; touch "$file"; grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"; }
backup_file_if_exists() { local file="$1"; [[ -e "$file" ]] || return 0; run cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"; }

# ---------- 配置文件 ----------
load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    key="$(trim_string "${key:-}")"
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="$(trim_string "${value:-}")"
    case "$key" in
      DEFAULT_SOURCE) DEFAULT_SOURCE="$value" ;;
      DEFAULT_DOCKER_SOURCE) DEFAULT_DOCKER_SOURCE="$value" ;;
      GITHUB_PROXY_PREFIX) GITHUB_PROXY_PREFIX="$value" ;;
      AUDIT_LOG) AUDIT_LOG="$value" ;;
    esac
  done < "$CONFIG_FILE"
}

# ---------- 系统检测 ----------
detect_os() {
  local kernel; kernel="$(uname -s 2>/dev/null || printf unknown)"
  case "$kernel" in
    Darwin) PLATFORM="macos"; OS_ID="macos"; OS_LIKE="darwin"; OS_NAME="macOS"; OS_VERSION_ID="$(sw_vers -productVersion 2>/dev/null || true)"; PKG_MANAGER="brew" ;;
    Linux)
      PLATFORM="linux"
      if [[ -r /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"; OS_NAME="${NAME:-unknown}"; OS_VERSION_ID="${VERSION_ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"; else OS_ID="unknown"; OS_NAME="unknown"; fi
      if has_cmd apt-get; then PKG_MANAGER="apt"; elif has_cmd dnf; then PKG_MANAGER="dnf"; elif has_cmd yum; then PKG_MANAGER="yum"; elif has_cmd pacman; then PKG_MANAGER="pacman"; else PKG_MANAGER=""; fi
      ;;
    *) PLATFORM="unknown"; OS_ID="unknown"; OS_NAME="$kernel"; PKG_MANAGER="" ;;
  esac
}
is_macos() { [[ "$PLATFORM" == "macos" || "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; }
is_linux() { [[ "$PLATFORM" == "linux" || "$(uname -s 2>/dev/null || true)" == "Linux" ]]; }
is_arch() { [[ "$PKG_MANAGER" == "pacman" || "$OS_ID" == "arch" || "$OS_LIKE" == *arch* ]]; }
is_fedora() { [[ "$OS_ID" == "fedora" ]]; }
is_kylin() { [[ "$OS_ID" == *kylin* || "$OS_NAME" == *麒麟* || "$OS_NAME" == *Kylin* ]]; }
require_root() { is_macos && return 0; if [[ "${EUID}" -ne 0 ]]; then if has_cmd sudo; then warn "需要 root 权限，正在尝试 sudo 重新执行。"; exec sudo -E bash "$0" "$@"; fi; fatal "请使用 root 用户运行，或先安装 sudo。"; fi; }
get_codename() { is_macos || is_arch && { printf ''; return 0; }; [[ -n "$OS_CODENAME" ]] && { printf '%s' "$OS_CODENAME"; return 0; }; has_cmd lsb_release && { lsb_release -sc 2>/dev/null && return 0; }; if [[ -r /etc/debian_version ]]; then case "$(cut -d. -f1 /etc/debian_version 2>/dev/null || true)" in 13) printf trixie ;; 12) printf bookworm ;; 11) printf bullseye ;; 10) printf buster ;; *) printf '' ;; esac; fi; return 0; }
print_env() { cat <<EOF_ENV
脚本版本：${TOOL_VERSION}
平台：${PLATFORM:-unknown}
系统：${OS_NAME}
ID：${OS_ID}
LIKE：${OS_LIKE}
VERSION_ID：${OS_VERSION_ID}
CODENAME：$(get_codename)
包管理器：${PKG_MANAGER:-未检测到}
架构：$(uname -m)
内核：$(uname -r)
EOF_ENV
if is_macos; then local brew; brew="$(brew_bin 2>/dev/null || true)"; [[ -n "$brew" ]] && echo "Homebrew：$brew" || echo "Homebrew：未安装"; fi
return 0
}

target_user_name() { if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then printf '%s' "$SUDO_USER"; else id -un 2>/dev/null || printf root; fi; }
target_user_home() { local user home; user="$(target_user_name)"; if has_cmd dscl && is_macos; then home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"; [[ -n "$home" ]] && { printf '%s' "$home"; return; }; fi; home="$(eval printf '%s' "~$user" 2>/dev/null || true)"; [[ -z "$home" || "$home" == "~$user" ]] && home="${HOME:-/root}"; printf '%s' "$home"; }
ensure_target_home() { local home; home="$(target_user_home)"; [[ -d "$home" ]] || fatal "用户目录不存在：$home"; }
chown_target() { local user path; user="$(target_user_name)"; [[ "${EUID}" -eq 0 ]] || return 0; for path in "$@"; do [[ -e "$path" ]] && chown -R "$user" "$path" 2>/dev/null || true; done; }
run_as_target_user() { local user; user="$(target_user_name)"; if [[ "${EUID}" -eq 0 && "$user" != "root" ]]; then run sudo -H -u "$user" "$@"; else run "$@"; fi; }

# ---------- 包管理 ----------
brew_bin() { local b; for b in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do [[ -n "$b" && -x "$b" ]] && { printf '%s\n' "$b"; return 0; }; done; return 1; }
ensure_brew() { is_macos || return 0; brew_bin >/dev/null 2>&1 && return 0; warn "未检测到 Homebrew。macOS 软件安装依赖 Homebrew。"; confirm "是否按 Homebrew 官方安装脚本安装？" || cancelled; has_cmd curl || fatal "缺少 curl，无法安装 Homebrew。"; run_shell "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash"; }
brew_run() { local brew; ensure_brew; brew="$(brew_bin)"; [[ "${EUID}" -eq 0 ]] && fatal "Homebrew 不应以 root 运行。请在 macOS 上用普通用户执行本脚本。"; run "$brew" "$@"; }
brew_install() { local pkg brew; ensure_brew; brew="$(brew_bin)"; for pkg in "$@"; do "$brew" list --formula "$pkg" >/dev/null 2>&1 || "$brew" list --cask "$pkg" >/dev/null 2>&1 && info "Homebrew 已安装：$pkg" || brew_run install "$pkg"; done; }
refresh_pkg_cache() { case "$PKG_MANAGER" in apt) run apt-get update ;; dnf) run dnf clean all; run dnf makecache ;; yum) run yum clean all; run yum makecache ;; pacman) run pacman -Sy ;; brew) brew_run update ;; *) warn "未检测到支持的包管理器，跳过刷新缓存。" ;; esac; }
pkg_install() { [[ "$#" -gt 0 ]] || return 0; case "$PKG_MANAGER" in apt) [[ "$PKG_UPDATED" -eq 0 ]] && { run apt-get update; PKG_UPDATED=1; }; DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends "$@" ;; dnf) run dnf install -y "$@" ;; yum) run yum install -y "$@" ;; pacman) [[ "$PKG_UPDATED" -eq 0 ]] && { run pacman -Sy; PKG_UPDATED=1; }; run pacman -S --needed --noconfirm "$@" ;; brew) brew_install "$@" ;; *) fatal "未检测到支持的包管理器，无法安装：$*" ;; esac; }
pkg_remove() { [[ "$#" -gt 0 ]] || return 0; case "$PKG_MANAGER" in apt) DEBIAN_FRONTEND=noninteractive run apt-get remove -y "$@" ;; dnf) run dnf remove -y "$@" ;; yum) run yum remove -y "$@" ;; pacman) run pacman -Rns --noconfirm "$@" ;; brew) brew_run uninstall "$@" ;; *) fatal "未检测到支持的包管理器，无法卸载：$*" ;; esac; }

# ---------- 常用工具 ----------
common_tool_commands() { cat <<'EOF_TOOLS'
curl:curl
wget:wget
vim:vim
git:git
htop:htop
tmux:tmux
zsh:zsh
unzip:unzip
jq:jq
rsync:rsync
nc:nc
dig:dig
ping:ping
ifconfig:ifconfig
lsof:lsof
iotop:iotop
iftop:iftop
nload:nload
sysstat:sar
EOF_TOOLS
}
tools_install() { if is_macos; then ensure_brew; brew_install curl wget vim git htop tmux zsh unzip jq rsync netcat bind lsof iftop nload || return 1; warn "macOS 的 ping/ifconfig 通常为系统自带；iotop/sysstat 在 macOS 上不可完全等价，脚本不会强制安装。"; tools_verify; return $?; fi; case "$PKG_MANAGER" in apt) pkg_install curl wget vim git htop tmux zsh unzip jq rsync netcat-openbsd dnsutils iputils-ping net-tools lsof iotop iftop nload sysstat ;; dnf|yum) pkg_install curl wget vim-enhanced git htop tmux zsh unzip jq rsync nc bind-utils iputils net-tools lsof iotop iftop nload sysstat ;; pacman) pkg_install curl wget vim git htop tmux zsh unzip jq rsync openbsd-netcat bind iputils net-tools lsof iotop iftop nload sysstat ;; *) fatal "未检测到支持的包管理器。" ;; esac; tools_verify; }
tools_verify() { local item name cmd missing=""; while IFS= read -r item; do [[ -n "$item" ]] || continue; name="${item%%:*}"; cmd="${item#*:}"; [[ "$cmd" == "$item" ]] && cmd="$name"; if ! has_cmd "$cmd"; then if is_macos && [[ "$name" == "iotop" || "$name" == "sysstat" ]]; then warn "macOS 暂不强制检查 ${name}。"; else missing="${missing}\n  - ${name}"; fi; fi; done < <(common_tool_commands); [[ -n "$missing" ]] && { warn "以下常用工具命令仍然缺失：$(printf '%b' "$missing")"; return 1; }; success "常用工具安装并校验完成。"; }
tools_status() { local item name cmd missing=0 path; echo "目标用户：$(target_user_name)"; echo "用户目录：$(target_user_home)"; echo; printf '%-18s %s\n' "工具" "状态"; printf '%-18s %s\n' "----" "----"; while IFS= read -r item; do [[ -n "$item" ]] || continue; name="${item%%:*}"; cmd="${item#*:}"; [[ "$cmd" == "$item" ]] && cmd="$name"; if path="$(cmd_path "$cmd" 2>/dev/null)"; then printf '%-18s %s\n' "$name" "已安装 (${path})"; else printf '%-18s %s\n' "$name" "缺失"; missing=$((missing + 1)); fi; done < <(common_tool_commands); echo; [[ "$missing" -gt 0 ]] && warn "缺少 ${missing} 个命令，可先执行 '安装常用工具'。" || success "常用工具命令检测通过。"; }
tools_config_vim() { ensure_target_home; local home file; home="$(target_user_home)"; file="$home/.vimrc"; backup_file_if_exists "$file"; write_file "$file" <<'EOF_VIM'
set nocompatible
syntax on
filetype plugin indent on
set number
set tabstop=4
set shiftwidth=4
set expandtab
set autoindent
set smartindent
set hlsearch
set incsearch
set ignorecase
set smartcase
set encoding=utf-8
set backspace=indent,eol,start
EOF_VIM
chown_target "$file"; success "Vim 配置完成。"; }
tools_config_tmux() { ensure_target_home; local home file; home="$(target_user_home)"; file="$home/.tmux.conf"; backup_file_if_exists "$file"; write_file "$file" <<'EOF_TMUX'
unbind-key C-b
set-option -g prefix C-h
bind-key C-b send-prefix
bind-key r source-file ~/.tmux.conf \; display-message "tmux.conf reloaded"
unbind-key '"'
unbind-key %
bind-key - split-window -v -c "#{pane_current_path}"
bind-key | split-window -h -c "#{pane_current_path}"
bind-key h select-pane -L
bind-key j select-pane -D
bind-key k select-pane -U
bind-key l select-pane -R
set-option -g default-terminal "screen-256color"
set-option -g base-index 1
set-option -g pane-base-index 1
set-option -g renumber-windows on
set-option -g history-limit 500000
set-window-option -g mode-keys vi
EOF_TMUX
chown_target "$file"; success "Tmux 配置完成。"; }
tools_config_git() { ensure_target_home; local home file; home="$(target_user_home)"; file="$home/.gitconfig"; backup_file_if_exists "$file"; write_file "$file" <<'EOF_GIT'
[core]
    editor = vim
    autocrlf = input
[pull]
    rebase = false
[init]
    defaultBranch = main
[color]
    ui = auto
EOF_GIT
chown_target "$file"; success "Git 基础配置完成。"; }
tools_config_zsh_basic() { ensure_target_home; local home zshrc block; home="$(target_user_home)"; zshrc="$home/.zshrc"; block='export EDITOR=vim
export PAGER=less
setopt autocd 2>/dev/null || true
setopt share_history 2>/dev/null || true
HISTSIZE=10000
SAVEHIST=10000
alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"'; tools_write_managed_block "$zshrc" "zsh-basic" "$block"; success "Zsh 基础配置完成。"; }
tools_remove_managed_block() { local file="$1" name="$2" begin end tmp; [[ -f "$file" ]] || return 0; [[ "$DRY_RUN" -eq 1 ]] && { info "+ remove managed block '$name' from $file"; return 0; }; begin="# >>> Linux Admin Toolkit: ${name} >>>"; end="# <<< Linux Admin Toolkit: ${name} <<<"; tmp="$(mktemp)"; awk -v b="$begin" -v e="$end" '$0 == b {skip=1; next} $0 == e {skip=0; next} skip != 1 {print}' "$file" > "$tmp"; cat "$tmp" > "$file"; rm -f "$tmp"; }
tools_write_managed_block() { local file="$1" name="$2" content="$3" dir begin end; dir="$(dirname "$file")"; [[ "$DRY_RUN" -eq 1 ]] && { info "+ write managed block '$name' to $file"; return 0; }; run mkdir -p "$dir"; [[ -f "$file" ]] || run touch "$file"; tools_remove_managed_block "$file" "$name"; begin="# >>> Linux Admin Toolkit: ${name} >>>"; end="# <<< Linux Admin Toolkit: ${name} <<<"; { printf '\n%s\n' "$begin"; printf '%s\n' "$content"; printf '%s\n' "$end"; } | append_file "$file"; chown_target "$file"; }

# ---------- Zsh / GitHub ----------
tools_is_http_url() { [[ "${1:-}" =~ ^https?:// ]]; }
tools_validate_url() { local url="${1:-}"; tools_is_http_url "$url" || fatal "URL 必须以 http:// 或 https:// 开头：$url"; ! has_unsafe_url_chars "$url" || fatal "URL 含有空白、引号或 shell 特殊字符，已拒绝：$url"; }
tools_ask_github_proxy() { local input proxy; proxy="${GITHUB_PROXY_PREFIX:-}"; if [[ -t 0 ]]; then echo "GitHub 访问慢时，可输入你信任的企业/自建 GitHub 加速前缀；留空表示直连。" >&2; read -r -p "GitHub 加速前缀 [${proxy:-直连}]: " input || true; input="$(trim_string "${input:-}")"; [[ -n "$input" ]] && proxy="$input"; fi; proxy="$(trim_string "$proxy")"; [[ -n "$proxy" ]] || { printf ''; return 0; }; tools_is_http_url "$proxy" || { warn "GitHub 加速前缀不是 http(s) URL，已改为直连。" >&2; printf ''; return 0; }; printf '%s' "${proxy%/}/"; }
tools_github_url() { local repo_url="$1" proxy="${2:-}"; [[ -n "$proxy" ]] || { printf '%s' "$repo_url"; return 0; }; printf '%s%s' "$proxy" "$repo_url"; }
tools_clone_or_update_repo() { local repo_url="$1" dest="$2" proxy="${3:-}" final_url; final_url="$(tools_github_url "$repo_url" "$proxy")"; if [[ -d "$dest/.git" ]]; then info "仓库已存在，尝试更新：$dest"; run_as_target_user git -C "$dest" pull --ff-only; else run_as_target_user git clone --depth=1 "$final_url" "$dest"; fi; }
tools_install_oh_my_zsh() { ensure_target_home; has_cmd git || pkg_install git; has_cmd zsh || pkg_install zsh; local home zsh_dir zshrc proxy; proxy="${1:-}"; [[ -n "$proxy" ]] || proxy="$(tools_ask_github_proxy)"; home="$(target_user_home)"; zsh_dir="$home/.oh-my-zsh"; zshrc="$home/.zshrc"; tools_clone_or_update_repo "https://github.com/ohmyzsh/ohmyzsh.git" "$zsh_dir" "$proxy"; [[ -f "$zsh_dir/oh-my-zsh.sh" ]] || fatal "Oh My Zsh 安装校验失败"; [[ -f "$zshrc" ]] || write_file "$zshrc" <<'EOF_ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
EOF_ZSHRC
chown_target "$zshrc"; success "Oh My Zsh 安装完成。"; }
tools_install_zsh_plugins() { ensure_target_home; has_cmd git || pkg_install git; local home custom proxy p1 p2 zshrc; proxy="${1:-}"; [[ -n "$proxy" ]] || proxy="$(tools_ask_github_proxy)"; home="$(target_user_home)"; custom="$home/.oh-my-zsh/custom"; zshrc="$home/.zshrc"; [[ -d "$home/.oh-my-zsh" ]] || tools_install_oh_my_zsh "$proxy"; run mkdir -p "$custom/plugins"; p1="$custom/plugins/zsh-autosuggestions"; p2="$custom/plugins/zsh-syntax-highlighting"; tools_clone_or_update_repo "https://github.com/zsh-users/zsh-autosuggestions.git" "$p1" "$proxy"; tools_clone_or_update_repo "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$p2" "$proxy"; [[ -f "$zshrc" ]] && grep -q '^plugins=' "$zshrc" 2>/dev/null && run sed -i.bak 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$zshrc"; chown_target "$p1" "$p2" "$zshrc"; success "Oh My Zsh 插件安装并配置完成。"; }
tools_install_rupa_z() { ensure_target_home; has_cmd git || pkg_install git; local home dest zshrc bashrc proxy block; proxy="${1:-}"; [[ -n "$proxy" ]] || proxy="$(tools_ask_github_proxy)"; home="$(target_user_home)"; dest="$home/.local/share/z"; zshrc="$home/.zshrc"; bashrc="$home/.bashrc"; run mkdir -p "$home/.local/share"; tools_clone_or_update_repo "https://github.com/rupa/z.git" "$dest" "$proxy"; block='if [ -f "$HOME/.local/share/z/z.sh" ]; then
  . "$HOME/.local/share/z/z.sh"
fi'; tools_write_managed_block "$zshrc" "rupa-z" "$block"; tools_write_managed_block "$bashrc" "rupa-z" "$block"; success "rupa/z 安装完成。"; }
tools_config_zsh_full() { local proxy; proxy="$(tools_ask_github_proxy)"; tools_install_oh_my_zsh "$proxy"; tools_install_zsh_plugins "$proxy"; tools_install_rupa_z "$proxy"; tools_config_zsh_basic; success "完整 Zsh 环境初始化完成。"; }
tools_change_shell_to_zsh() { has_cmd zsh || pkg_install zsh; local user zsh_path; user="$(target_user_name)"; zsh_path="$(cmd_path zsh | head -n1)"; [[ -n "$zsh_path" ]] || fatal "未找到 zsh。"; grep -qx "$zsh_path" /etc/shells 2>/dev/null || echo "$zsh_path" | run_privileged tee -a /etc/shells >/dev/null; is_macos && run_privileged chsh -s "$zsh_path" "$user" || run chsh -s "$zsh_path" "$user"; success "已将用户 ${user} 的默认 Shell 设置为 ${zsh_path}。"; }
tools_config_all() { tools_config_vim; tools_config_tmux; tools_config_git; tools_config_zsh_basic; success "常用工具基础配置完成。"; }

# ---------- 镜像源 ----------
mirror_base_url() { local source="${1:-$DEFAULT_SOURCE}" url; case "$source" in official) printf '' ;; tuna) printf 'https://mirrors.tuna.tsinghua.edu.cn' ;; ustc) printf 'https://mirrors.ustc.edu.cn' ;; aliyun) printf 'https://mirrors.aliyun.com' ;; tencent) printf 'https://mirrors.cloud.tencent.com' ;; bfsu) printf 'https://mirrors.bfsu.edu.cn' ;; custom:*) url="${source#custom:}"; url="$(trim_string "$url")"; tools_validate_url "$url"; printf '%s' "${url%/}" ;; http://*|https://*) tools_validate_url "$source"; printf '%s' "${source%/}" ;; *) fatal "未知镜像源：$source" ;; esac; }
mirror_backup_root() { is_macos && printf '%s/.local/state/linux-admin-toolkit/backups' "$(target_user_home)" || printf '%s' "$BACKUP_ROOT"; }
mirror_backup() { local ts dir root home; ts="$(date +%Y%m%d-%H%M%S)"; root="$(mirror_backup_root)"; dir="$root/$ts"; if is_macos; then run mkdir -p "$dir"; home="$(target_user_home)"; run mkdir -p "$dir/home"; run_shell "cp -a '$home/.zprofile' '$home/.zshrc' '$home/.bashrc' '$dir/home/' 2>/dev/null || true"; success "macOS/Homebrew 配置已备份到：$dir"; return 0; fi; run_privileged mkdir -p "$dir"; [[ -d /etc/apt ]] && { run mkdir -p "$dir/etc/apt"; run_shell "cp -a /etc/apt/sources.list /etc/apt/sources.list.d '$dir/etc/apt/' 2>/dev/null || true"; }; [[ -d /etc/yum.repos.d ]] && { run mkdir -p "$dir/etc/yum.repos.d"; run_shell "cp -a /etc/yum.repos.d/*.repo '$dir/etc/yum.repos.d/' 2>/dev/null || true"; }; [[ -f /etc/pacman.conf || -d /etc/pacman.d ]] && { run mkdir -p "$dir/etc/pacman.d"; run_shell "cp -a /etc/pacman.conf '$dir/etc/' 2>/dev/null || true"; run_shell "cp -a /etc/pacman.d/mirrorlist '$dir/etc/pacman.d/' 2>/dev/null || true"; }; success "镜像源已备份到：$dir"; }
mirror_list_backups() { local root; root="$(mirror_backup_root)"; mkdir -p "$root" 2>/dev/null || run_privileged mkdir -p "$root"; find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed "s#^$root/##" | sort || true; }
mirror_restore() { local name="${1:-}" dir home; [[ -z "$name" ]] && { echo "可用备份："; mirror_list_backups; read -r -p "输入要恢复的备份目录名：" name; }; [[ -n "$name" && "$name" != */* && "$name" != *..* ]] || fatal "备份目录名不合法：$name"; dir="$(mirror_backup_root)/$name"; [[ -d "$dir" ]] || fatal "备份不存在：$dir"; confirm "确认恢复 ${dir} 到源/配置？" || cancelled; if is_macos; then home="$(target_user_home)"; run_shell "cp -a '$dir/home/'* '$home/' 2>/dev/null || true"; chown_target "$home/.zprofile" "$home/.zshrc" "$home/.bashrc" 2>/dev/null || true; success "macOS/Homebrew 配置恢复完成。"; return 0; fi; [[ -d "$dir/etc/apt" ]] && run_shell "cp -a '$dir/etc/apt/'* /etc/apt/ 2>/dev/null || true"; [[ -d "$dir/etc/yum.repos.d" ]] && run_shell "cp -a '$dir/etc/yum.repos.d/'*.repo /etc/yum.repos.d/ 2>/dev/null || true"; [[ -f "$dir/etc/pacman.conf" ]] && run_shell "cp -a '$dir/etc/pacman.conf' /etc/pacman.conf"; [[ -f "$dir/etc/pacman.d/mirrorlist" ]] && run_shell "cp -a '$dir/etc/pacman.d/mirrorlist' /etc/pacman.d/mirrorlist"; refresh_pkg_cache; success "恢复完成。"; }
mirror_set_homebrew() { local source="${1:-official}" home zprofile zshrc bashrc block base; ensure_target_home; home="$(target_user_home)"; zprofile="$home/.zprofile"; zshrc="$home/.zshrc"; bashrc="$home/.bashrc"; mirror_backup; [[ "$source" == official ]] && { tools_remove_managed_block "$zprofile" homebrew-mirror; tools_remove_managed_block "$zshrc" homebrew-mirror; tools_remove_managed_block "$bashrc" homebrew-mirror; success "已移除脚本管理的 Homebrew 镜像环境变量。"; return 0; }; base="$(mirror_base_url "$source")"; block="export HOMEBREW_API_DOMAIN=\"${base%/}/homebrew-bottles/api\"\nexport HOMEBREW_BOTTLE_DOMAIN=\"${base%/}/homebrew-bottles\""; tools_write_managed_block "$zprofile" homebrew-mirror "$block"; tools_write_managed_block "$zshrc" homebrew-mirror "$block"; tools_write_managed_block "$bashrc" homebrew-mirror "$block"; success "Homebrew 镜像变量已写入 shell 配置。"; }
mirror_set_apt() { local source="${1:-$DEFAULT_SOURCE}" base codename components target_file main_uri security_uri; codename="$(get_codename)"; [[ -n "$codename" ]] || fatal "无法识别 codename。"; mirror_backup; components="main contrib non-free non-free-firmware"; if [[ "$source" == official ]]; then main_uri="http://deb.debian.org/debian"; security_uri="http://deb.debian.org/debian-security"; elif [[ "$OS_ID" == ubuntu || "$OS_LIKE" == *ubuntu* ]]; then base="$(mirror_base_url "$source")"; main_uri="${base}/ubuntu"; security_uri="$main_uri"; components="main restricted universe multiverse"; else base="$(mirror_base_url "$source")"; main_uri="${base}/debian"; security_uri="${base}/debian-security"; fi; target_file="/etc/apt/sources.list"; write_file "$target_file" <<EOF_APT
deb ${main_uri} ${codename} ${components}
deb ${main_uri} ${codename}-updates ${components}
deb ${main_uri} ${codename}-backports ${components}
deb ${security_uri} ${codename}-security ${components}
EOF_APT
success "已写入 apt 源：${target_file}"; refresh_pkg_cache; }
mirror_set_rpm() { local source="${1:-$DEFAULT_SOURCE}" base; [[ "$source" == official ]] && skipped "RPM 系发行版官方源格式差异较大，脚本不强制重写为官方源。"; base="$(mirror_base_url "$source")"; mirror_backup; is_kylin && skipped "检测到麒麟系统，脚本只做备份，不自动替换。"; if is_fedora; then run_shell "sed -i.linux-admin.bak -e 's|^metalink=|#metalink=|g' -e 's|^#baseurl=http://download.example/pub/fedora/linux|baseurl=${base}/fedora|g' -e 's|^#baseurl=https://download.example/pub/fedora/linux|baseurl=${base}/fedora|g' /etc/yum.repos.d/fedora*.repo"; else run_shell "sed -i.linux-admin.bak -e 's|^mirrorlist=|#mirrorlist=|g' -e 's|^#baseurl=http://mirror.centos.org/centos|baseurl=${base}/centos|g' -e 's|^#baseurl=https://mirror.centos.org/centos|baseurl=${base}/centos|g' /etc/yum.repos.d/*.repo"; fi; refresh_pkg_cache; success "RPM 镜像源处理完成。"; }
mirror_set_pacman() { local source="${1:-$DEFAULT_SOURCE}" base mirror_url; mirror_backup; if [[ "$source" == official ]]; then mirror_url='https://geo.mirror.pkgbuild.com/$repo/os/$arch'; else base="$(mirror_base_url "$source")"; mirror_url="${base}/archlinux/\$repo/os/\$arch"; fi; write_file /etc/pacman.d/mirrorlist <<EOF_PACMAN
Server = ${mirror_url}
EOF_PACMAN
refresh_pkg_cache; success "Arch Linux pacman 镜像源已写入：/etc/pacman.d/mirrorlist"; }
mirror_set() { local source="${1:-$DEFAULT_SOURCE}"; if is_macos; then mirror_set_homebrew "$source"; return 0; fi; case "$PKG_MANAGER" in apt) mirror_set_apt "$source" ;; dnf|yum) mirror_set_rpm "$source" ;; pacman) mirror_set_pacman "$source" ;; *) fatal "未检测到支持的包管理器。" ;; esac; }
mirror_choose_source() { local c custom; CHOSEN_MIRROR_SOURCE=""; cat <<'EOF_SOURCE'

选择源：
1) 官方源 official（默认）
2) 清华 TUNA tuna
3) 中科大 USTC ustc
4) 阿里云 aliyun
5) 腾讯云 tencent
6) BFSU bfsu
7) 自定义基础 URL
EOF_SOURCE
read -r -p "请输入选项或源名称 [1]: " c; c="$(trim_string "${c:-1}")"; case "$c" in 1|official|官方|官方源) CHOSEN_MIRROR_SOURCE=official ;; 2|tuna|TUNA|清华|清华源) CHOSEN_MIRROR_SOURCE=tuna ;; 3|ustc|USTC|中科大|中科大源) CHOSEN_MIRROR_SOURCE=ustc ;; 4|aliyun|ALIYUN|阿里|阿里云) CHOSEN_MIRROR_SOURCE=aliyun ;; 5|tencent|TENCENT|腾讯|腾讯云) CHOSEN_MIRROR_SOURCE=tencent ;; 6|bfsu|BFSU|北外) CHOSEN_MIRROR_SOURCE=bfsu ;; 7) read -r -p "输入基础 URL，如 https://mirrors.example.com: " custom; custom="$(trim_string "$custom")"; [[ -n "$custom" ]] && CHOSEN_MIRROR_SOURCE="custom:${custom%/}" || CHOSEN_MIRROR_SOURCE=official ;; http://*|https://*|custom:http://*|custom:https://*) CHOSEN_MIRROR_SOURCE="${c%/}" ;; *) warn "无效选择：${c}，使用官方源。"; CHOSEN_MIRROR_SOURCE=official ;; esac; }
menu_mirror_set() { local s; mirror_choose_source; s="$CHOSEN_MIRROR_SOURCE"; [[ -n "$s" ]] || cancelled; info "已选择源：${s}"; mirror_set "$s"; }

# ---------- Docker ----------
docker_registry_mirrors_json() { local input="$1" old_ifs item out="[" sep=""; old_ifs="$IFS"; IFS=','; for item in $input; do item="$(trim_string "$item")"; [[ -n "$item" ]] || continue; tools_validate_url "$item"; out="${out}${sep}\"${item}\""; sep=", "; done; IFS="$old_ifs"; [[ "$out" != "[" ]] || fatal "未输入有效的 registry mirror URL。"; printf '%s]' "$out"; }
docker_repo_base() { local s="${1:-$DEFAULT_DOCKER_SOURCE}"; case "$s" in official) printf 'https://download.docker.com' ;; tuna) printf 'https://mirrors.tuna.tsinghua.edu.cn/docker-ce' ;; ustc) printf 'https://mirrors.ustc.edu.cn/docker-ce' ;; aliyun) printf 'https://mirrors.aliyun.com/docker-ce' ;; tencent) printf 'https://mirrors.cloud.tencent.com/docker-ce' ;; bfsu) printf 'https://mirrors.bfsu.edu.cn/docker-ce' ;; custom:*|http://*|https://*) mirror_base_url "$s" ;; *) fatal "未知 Docker 源：$s" ;; esac; }
docker_repo_os() { if [[ "$OS_ID" == ubuntu || "$OS_LIKE" == *ubuntu* ]]; then printf ubuntu; elif [[ "$OS_ID" == debian || "$OS_LIKE" == *debian* ]]; then printf debian; elif is_fedora; then printf fedora; else printf centos; fi; }
docker_remove_old_conflicts() { [[ "$PKG_MANAGER" == pacman ]] && return 0; [[ "$PKG_MANAGER" == apt ]] && pkg_remove docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc || pkg_remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman-docker || true; }
docker_install_macos() { ensure_brew; brew_run install --cask docker-desktop; success "Docker Desktop 已安装。首次使用请从 Applications 启动 Docker。"; }
docker_install_pacman() { pkg_install docker docker-compose; }
docker_install_apt() { local source="${1:-$DEFAULT_DOCKER_SOURCE}" base repo_os codename arch list_file; base="$(docker_repo_base "$source")"; repo_os="$(docker_repo_os)"; codename="$(get_codename)"; arch="$(dpkg --print-architecture 2>/dev/null || true)"; [[ -n "$codename" ]] || fatal "无法识别 codename。"; docker_remove_old_conflicts; pkg_install ca-certificates curl gnupg; run install -m 0755 -d /etc/apt/keyrings; run_shell "curl -fsSL '${base}/linux/${repo_os}/gpg' | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg"; run chmod a+r /etc/apt/keyrings/docker.gpg; list_file=/etc/apt/sources.list.d/docker.list; write_file "$list_file" <<EOF_DOCKER
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] ${base}/linux/${repo_os} ${codename} stable
EOF_DOCKER
refresh_pkg_cache; pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; }
docker_install_rpm() { local source="${1:-$DEFAULT_DOCKER_SOURCE}" base repo_os repo_url; base="$(docker_repo_base "$source")"; repo_os="$(docker_repo_os)"; docker_remove_old_conflicts; pkg_install yum-utils; repo_url="${base}/linux/${repo_os}/docker-ce.repo"; has_cmd dnf && run dnf config-manager --add-repo "$repo_url" || run yum-config-manager --add-repo "$repo_url"; [[ "$source" != official ]] && run_shell "sed -i.bak 's#https://download.docker.com#${base}#g' /etc/yum.repos.d/docker-ce.repo"; pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; }
docker_install() { local source="${1:-$DEFAULT_DOCKER_SOURCE}"; if is_macos; then confirm "即将安装 Docker Desktop。是否继续？" || cancelled; docker_install_macos; return 0; fi; confirm "即将安装 Docker，并可能移除系统中冲突的旧 Docker/Podman 兼容包。是否继续？" || cancelled; case "$PKG_MANAGER" in apt) docker_install_apt "$source" ;; dnf|yum) docker_install_rpm "$source" ;; pacman) docker_install_pacman ;; *) fatal "未检测到支持的包管理器。" ;; esac; has_cmd docker || fatal "Docker 安装后未检测到 docker 命令。"; has_cmd systemctl && run systemctl enable --now docker; success "Docker 安装完成。"; }
menu_docker_install() { local s; if is_macos || is_arch; then docker_install official; return $?; fi; mirror_choose_source; s="$CHOSEN_MIRROR_SOURCE"; [[ -n "$s" ]] || cancelled; info "已选择 Docker 源：${s}"; docker_install "$s"; }
docker_configure_registry_mirror() { is_macos && { warn "macOS Docker Desktop 的 registry mirror 建议在 Docker Desktop Settings 中配置。"; return 0; }; local mirrors="${1:-}" daemon_json content; [[ -z "$mirrors" ]] && { echo "输入 Docker Registry mirrors，多个用逗号分隔；留空则清空脚本管理配置。"; read -r -p "Registry mirrors: " mirrors; }; confirm "即将写入 Docker daemon 配置并重启 Docker。是否继续？" || cancelled; daemon_json=/etc/docker/daemon.json; run mkdir -p /etc/docker; if [[ -z "$(trim_string "$mirrors")" ]]; then write_file "$daemon_json" <<'EOF_DAEMON'
{}
EOF_DAEMON
else content="$(docker_registry_mirrors_json "$mirrors")"; write_file "$daemon_json" <<EOF_DAEMON
{
  "registry-mirrors": ${content}
}
EOF_DAEMON
fi; has_cmd systemctl && { run systemctl daemon-reload; run systemctl restart docker; }; success "Docker Registry mirror 配置完成：${daemon_json}"; }
docker_save_images() { has_cmd docker || fatal "未检测到 docker 命令。"; docker info >/dev/null 2>&1 || fatal "Docker daemon 不可用。"; local dir="${1:-}" image safe out count=0; [[ -z "$dir" ]] && { read -r -p "输入镜像导出目录 [${HOME:-/root}/docker-images]: " dir; dir="${dir:-${HOME:-/root}/docker-images}"; }; run mkdir -p "$dir"; while IFS= read -r image; do [[ -n "$image" ]] || continue; safe="$(printf '%s' "$image" | tr '/:@' '___')"; out="$dir/${safe}.tar.gz"; info "导出镜像：${image} -> ${out}"; if [[ "$DRY_RUN" -eq 1 ]]; then count=$((count + 1)); continue; fi; docker save "$image" | gzip > "$out"; [[ -s "$out" ]] || fatal "导出失败：$out"; count=$((count + 1)); done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true); success "Docker 镜像导出完成，数量：${count}。"; }
docker_uninstall() { local remove_data="${1:-0}"; confirm "即将卸载 Docker 相关软件包。是否继续？" || cancelled; if is_macos; then ensure_brew; brew_run uninstall --cask docker-desktop || true; success "Docker Desktop 卸载完成。"; return 0; fi; has_cmd systemctl && run systemctl stop docker || true; [[ "$PKG_MANAGER" == pacman ]] && pkg_remove docker docker-compose || pkg_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true; [[ "$remove_data" == 1 ]] && confirm "确认删除 /var/lib/docker /var/lib/containerd？" && run rm -rf /var/lib/docker /var/lib/containerd; success "Docker 卸载完成。"; }
menu_docker_status() { if is_macos; then [[ -d /Applications/Docker.app || -d "$(target_user_home)/Applications/Docker.app" ]] && success "Docker Desktop App 已安装。" || warn "未检测到 Docker Desktop App。"; has_cmd docker && docker version || warn "当前 PATH 中未检测到 docker CLI。"; return 0; fi; has_cmd systemctl && systemctl status docker --no-pager 2>/dev/null && return 0; has_cmd docker && docker version || warn "未检测到 docker 命令。"; }

# ---------- Docker 离线安装 ----------
offline_detect_arch() {
  local raw="${OFFLINE_ARCH_OVERRIDE:-$(uname -m)}"
  case "$raw" in
    x86_64|amd64) OFFLINE_DOCKER_ARCH="x86_64"; OFFLINE_COMPOSE_ARCH="x86_64" ;;
    aarch64|arm64) OFFLINE_DOCKER_ARCH="aarch64"; OFFLINE_COMPOSE_ARCH="aarch64" ;;
    *) fatal "暂不支持架构：$raw。建议使用 x86_64 或 aarch64。" ;;
  esac
  info "Docker 离线安装使用架构：Docker=$OFFLINE_DOCKER_ARCH Compose=$OFFLINE_COMPOSE_ARCH"
}
offline_replace_placeholders() {
  local s="$1"
  s="${s//\{channel\}/$OFFLINE_DOCKER_CHANNEL}"
  s="${s//\{arch\}/$OFFLINE_DOCKER_ARCH}"
  s="${s//\{version\}/$OFFLINE_DOCKER_VERSION}"
  printf '%s' "$s"
}
offline_replace_compose_placeholders() {
  local s="$1"
  s="${s//\{arch\}/$OFFLINE_COMPOSE_ARCH}"
  s="${s//\{version\}/$OFFLINE_COMPOSE_VERSION}"
  printf '%s' "$s"
}
offline_download_file() {
  local url="$1" out="$2"
  run mkdir -p "$(dirname "$out")"
  info "下载：$url"
  if has_cmd curl; then
    run curl -fL --retry 3 --connect-timeout 20 -o "$out.tmp" "$url"
  elif has_cmd wget; then
    run wget -O "$out.tmp" "$url"
  else
    fatal "缺少 curl 或 wget，无法下载。"
  fi
  run mv -f "$out.tmp" "$out"
}
offline_fetch_text() {
  local url="$1"
  if has_cmd curl; then curl -fsL --connect-timeout 20 "$url"; elif has_cmd wget; then wget -qO- "$url"; else return 1; fi
}
offline_resolve_latest_docker_online() {
  local index_url="https://download.docker.com/linux/static/${OFFLINE_DOCKER_CHANNEL}/${OFFLINE_DOCKER_ARCH}/"
  local latest
  latest="$(offline_fetch_text "$index_url" \
    | grep -oE 'docker-[0-9]+(\.[0-9]+)+(-ce)?\.tgz' \
    | sed -E 's/^docker-//; s/\.tgz$//; s/-ce$//' \
    | sort -Vu \
    | tail -n 1 || true)"
  [[ -n "$latest" ]] || fatal "无法解析 Docker latest 版本，请显式指定 --docker-version。"
  OFFLINE_DOCKER_VERSION="$latest"
  info "解析到 Docker latest：$OFFLINE_DOCKER_VERSION"
}
offline_resolve_latest_docker_local() {
  local latest=""
  if [[ -d "$OFFLINE_RESOURCE_DIR" ]]; then
    latest="$(find "$OFFLINE_RESOURCE_DIR" -maxdepth 1 -type f -name 'docker-*.tgz' -printf '%f\n' 2>/dev/null \
      | sed -E 's/^docker-//; s/\.tgz$//; s/-x86_64$//; s/-aarch64$//; s/-ce$//' \
      | grep -E '^[0-9]+(\.[0-9]+)+' \
      | sort -Vu \
      | tail -n 1 || true)"
  fi
  [[ -n "$latest" ]] || return 1
  OFFLINE_DOCKER_VERSION="$latest"
  info "从本地资源解析到 Docker 最高版本：$OFFLINE_DOCKER_VERSION"
}
offline_resolve_latest_compose_online() { OFFLINE_COMPOSE_VERSION="latest"; }
offline_resolve_latest_compose_local() {
  local latest=""
  if [[ -d "$OFFLINE_RESOURCE_DIR" ]]; then
    latest="$(find "$OFFLINE_RESOURCE_DIR" -maxdepth 1 -type f \( -name 'docker-compose-*-linux-*' -o -name 'docker-compose-linux-*' \) -printf '%f\n' 2>/dev/null \
      | sed -E 's/^docker-compose-//; s/-linux-(x86_64|aarch64)$//; s/^linux-(x86_64|aarch64)$/latest/' \
      | grep -E '^latest$|^[0-9]+(\.[0-9]+)+' \
      | sort -Vu \
      | tail -n 1 || true)"
  fi
  [[ -n "$latest" ]] || return 1
  OFFLINE_COMPOSE_VERSION="$latest"
  info "从本地资源解析到 Compose 版本：$OFFLINE_COMPOSE_VERSION"
}
offline_docker_url() { offline_replace_placeholders "$OFFLINE_DOCKER_URL_TEMPLATE"; }
offline_compose_url() {
  if [[ "$OFFLINE_COMPOSE_VERSION" == "latest" ]]; then
    offline_replace_compose_placeholders "$OFFLINE_COMPOSE_LATEST_URL_TEMPLATE"
  else
    offline_replace_compose_placeholders "$OFFLINE_COMPOSE_URL_TEMPLATE"
  fi
}
offline_docker_resource_path() { printf '%s/docker-%s-%s.tgz' "$OFFLINE_RESOURCE_DIR" "$OFFLINE_DOCKER_VERSION" "$OFFLINE_DOCKER_ARCH"; }
offline_compose_resource_path() {
  if [[ "$OFFLINE_COMPOSE_VERSION" == "latest" ]]; then
    printf '%s/docker-compose-linux-%s' "$OFFLINE_RESOURCE_DIR" "$OFFLINE_COMPOSE_ARCH"
  else
    printf '%s/docker-compose-%s-linux-%s' "$OFFLINE_RESOURCE_DIR" "$OFFLINE_COMPOSE_VERSION" "$OFFLINE_COMPOSE_ARCH"
  fi
}
offline_find_docker_resource() {
  local p
  if [[ "$OFFLINE_DOCKER_VERSION" == "latest" ]]; then offline_resolve_latest_docker_local || true; fi
  local candidates=(
    "$OFFLINE_RESOURCE_DIR/docker-${OFFLINE_DOCKER_VERSION}-${OFFLINE_DOCKER_ARCH}.tgz"
    "$OFFLINE_RESOURCE_DIR/docker-${OFFLINE_DOCKER_VERSION}.tgz"
    "$OFFLINE_RESOURCE_DIR/docker-${OFFLINE_DOCKER_VERSION}-ce-${OFFLINE_DOCKER_ARCH}.tgz"
    "$OFFLINE_RESOURCE_DIR/docker-${OFFLINE_DOCKER_VERSION}-ce.tgz"
  )
  for p in "${candidates[@]}"; do [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }; done
  return 1
}
offline_find_compose_resource() {
  local p
  if [[ "$OFFLINE_COMPOSE_VERSION" == "latest" ]]; then offline_resolve_latest_compose_local || true; fi
  local candidates=(
    "$OFFLINE_RESOURCE_DIR/docker-compose-${OFFLINE_COMPOSE_VERSION}-linux-${OFFLINE_COMPOSE_ARCH}"
    "$OFFLINE_RESOURCE_DIR/docker-compose-linux-${OFFLINE_COMPOSE_ARCH}"
    "$OFFLINE_RESOURCE_DIR/docker-compose"
  )
  for p in "${candidates[@]}"; do [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }; done
  return 1
}
offline_ensure_resource_or_download() {
  local kind="$1" found=0
  if [[ "$kind" == "docker" ]]; then offline_find_docker_resource >/dev/null && found=1; else offline_find_compose_resource >/dev/null && found=1; fi
  [[ "$found" -eq 1 ]] && return 0
  if [[ "$OFFLINE_DOWNLOAD_IF_MISSING" -eq 1 ]]; then
    info "$kind 资源不存在，自动下载。"
    if [[ "$kind" == "docker" ]]; then
      local old="$OFFLINE_SKIP_COMPOSE"; OFFLINE_SKIP_COMPOSE=1; offline_action_download; OFFLINE_SKIP_COMPOSE="$old"
    else
      local old="$OFFLINE_SKIP_DOCKER"; OFFLINE_SKIP_DOCKER=1; offline_action_download; OFFLINE_SKIP_DOCKER="$old"
    fi
    return 0
  fi
  fatal "$kind 资源不存在。请先执行 download 或添加 --download-if-missing。资源目录：$OFFLINE_RESOURCE_DIR"
}
offline_ensure_state() { run mkdir -p "$OFFLINE_STATE_DIR"; touch "$OFFLINE_MANIFEST_FILE" "$OFFLINE_BACKUP_MANIFEST_FILE"; }
offline_path_in_manifest() { local path="$1"; [[ -f "$OFFLINE_MANIFEST_FILE" ]] && grep -Fxq "$path" "$OFFLINE_MANIFEST_FILE"; }
offline_add_manifest() { local path="$1"; grep -Fxq "$path" "$OFFLINE_MANIFEST_FILE" 2>/dev/null || printf '%s\n' "$path" >> "$OFFLINE_MANIFEST_FILE"; }
offline_backup_existing_if_needed() {
  local target="$1" encoded backup_path
  [[ -e "$target" || -L "$target" ]] || return 0
  offline_path_in_manifest "$target" && return 0
  encoded="$(printf '%s' "$target" | sed 's#/#__#g')"
  backup_path="$OFFLINE_STATE_DIR/backups/$encoded"
  run mkdir -p "$(dirname "$backup_path")"
  if [[ -L "$target" ]]; then cp -P "$target" "$backup_path"; else cp -a "$target" "$backup_path"; fi
  printf '%s|%s\n' "$target" "$backup_path" >> "$OFFLINE_BACKUP_MANIFEST_FILE"
  warn "发现已有文件，已备份：$target -> $backup_path"
}
offline_install_file_managed() {
  local src="$1" target="$2" mode="${3:-0755}"
  offline_ensure_state
  offline_backup_existing_if_needed "$target"
  run mkdir -p "$(dirname "$target")"
  run install -m "$mode" "$src" "$target"
  offline_add_manifest "$target"
}
offline_install_symlink_managed() {
  local link_target="$1" link_path="$2"
  offline_ensure_state
  offline_backup_existing_if_needed "$link_path"
  run mkdir -p "$(dirname "$link_path")"
  run ln -sfn "$link_target" "$link_path"
  offline_add_manifest "$link_path"
}
offline_write_text_managed() {
  local target="$1" mode="$2"
  offline_ensure_state
  offline_backup_existing_if_needed "$target"
  run mkdir -p "$(dirname "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ write file $target"; cat >/dev/null; else cat > "$target"; fi
  [[ "$DRY_RUN" -eq 1 ]] || chmod "$mode" "$target"
  offline_add_manifest "$target"
}
offline_create_daemon_json_if_missing() {
  local target="/etc/docker/daemon.json"
  if [[ -f "$target" ]]; then info "已存在 $target，保持不覆盖。"; return 0; fi
  run mkdir -p /etc/docker
  local tmp; tmp="$(mktemp)"
  {
    printf '{\n'
    printf '  "log-driver": "json-file",\n'
    printf '  "log-opts": {"max-size": "100m", "max-file": "3"}'
    [[ -n "$OFFLINE_DATA_ROOT" ]] && printf ',\n  "data-root": "%s"' "$OFFLINE_DATA_ROOT"
    [[ -n "$OFFLINE_REGISTRY_MIRROR" ]] && printf ',\n  "registry-mirrors": ["%s"]' "$OFFLINE_REGISTRY_MIRROR"
    printf '\n}\n'
  } > "$tmp"
  offline_install_file_managed "$tmp" "$target" 0644
  run rm -f "$tmp"
  info "已创建默认 Docker 配置：$target"
}
offline_create_systemd_service() {
  if ! has_cmd systemctl; then return 0; fi
  local tmp; tmp="$(mktemp)"
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
  offline_install_file_managed "$tmp" "/etc/systemd/system/docker.service" 0644
  run rm -f "$tmp"
  has_cmd systemctl && run systemctl daemon-reload
}
offline_install_docker_binaries() {
  ensure_linux_only "macOS 不支持 Docker 离线二进制安装。"
  offline_ensure_resource_or_download docker
  local tgz tmpdir f base
  tgz="$(offline_find_docker_resource)"
  info "安装 Docker Engine：$tgz"
  tmpdir="$(mktemp -d)"
  run tar -xzf "$tgz" -C "$tmpdir"
  [[ -d "$tmpdir/docker" ]] || fatal "Docker 压缩包格式异常，未找到 docker/ 目录。"
  for f in "$tmpdir/docker"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    offline_install_file_managed "$f" "/usr/local/bin/$base" 0755
  done
  run rm -rf "$tmpdir"
  if has_cmd groupadd; then groupadd -f docker || warn "创建 docker 用户组失败，可手工检查。"; fi
  offline_create_daemon_json_if_missing
  offline_create_systemd_service
  if has_cmd systemctl; then
    [[ "$OFFLINE_ENABLE_SERVICE" -eq 0 ]] || { run systemctl enable docker.service || warn "设置 docker 开机自启失败。"; }
    [[ "$OFFLINE_START_SERVICE" -eq 0 ]] || { run systemctl restart docker.service || warn "docker 服务启动失败，请执行：journalctl -u docker -xe。"; }
  fi
}
offline_install_compose_binary() {
  ensure_linux_only "macOS 不支持 Compose 离线二进制安装。"
  offline_ensure_resource_or_download compose
  local src plugin_dir plugin_path
  src="$(offline_find_compose_resource)"
  plugin_dir="/usr/local/lib/docker/cli-plugins"
  plugin_path="$plugin_dir/docker-compose"
  info "安装 Docker Compose：$src"
  offline_install_file_managed "$src" "$plugin_path" 0755
  offline_install_symlink_managed "$plugin_path" "/usr/local/bin/docker-compose"
}
offline_action_download() {
  offline_detect_arch
  run mkdir -p "$OFFLINE_RESOURCE_DIR"
  if [[ "$OFFLINE_SKIP_DOCKER" -eq 0 ]]; then
    [[ "$OFFLINE_DOCKER_VERSION" == "latest" ]] && offline_resolve_latest_docker_online
    local docker_out; docker_out="$(offline_docker_resource_path)"
    if [[ -f "$docker_out" ]]; then info "Docker 资源已存在，跳过：$docker_out"
    else offline_download_file "$(offline_docker_url)" "$docker_out"; fi
  fi
  if [[ "$OFFLINE_SKIP_COMPOSE" -eq 0 ]]; then
    [[ "$OFFLINE_COMPOSE_VERSION" == "latest" ]] && offline_resolve_latest_compose_online
    local compose_out; compose_out="$(offline_compose_resource_path)"
    if [[ -f "$compose_out" ]]; then info "Compose 资源已存在，跳过：$compose_out"
    else offline_download_file "$(offline_compose_url)" "$compose_out"; run chmod +x "$compose_out"; fi
  fi
  info "资源准备完成：$OFFLINE_RESOURCE_DIR"
}
offline_action_install() {
  ensure_linux_only "macOS 不支持 Docker 离线二进制安装，请使用 docker install。"
  local missing=()
  for c in tar iptables modprobe; do has_cmd "$c" || missing+=("$c"); done
  if (( ${#missing[@]} > 0 )); then warn "缺少可能影响 Docker 运行的系统命令：${missing[*]}。"; fi
  if has_cmd systemctl; then :; else warn "当前系统未检测到 systemctl，不能自动创建/启动 systemd 服务。"; fi
  offline_detect_arch
  [[ "$OFFLINE_SKIP_DOCKER" -eq 1 ]] || offline_install_docker_binaries
  [[ "$OFFLINE_SKIP_COMPOSE" -eq 1 ]] || offline_install_compose_binary
  info "离线安装完成。"
  offline_action_status || true
  cat <<'TIP'
提示：
  - Docker Compose v2 推荐命令：docker compose version
  - 兼容老习惯命令：docker-compose version
  - 非 root 用户使用 docker：sudo usermod -aG docker <用户名>，然后重新登录
TIP
}
offline_restore_backups() {
  [[ -f "$OFFLINE_BACKUP_MANIFEST_FILE" ]] || return 0
  tac "$OFFLINE_BACKUP_MANIFEST_FILE" 2>/dev/null | while IFS='|' read -r target backup_path; do
    [[ -n "${target:-}" && -n "${backup_path:-}" ]] || continue
    [[ -e "$backup_path" || -L "$backup_path" ]] || continue
    run mkdir -p "$(dirname "$target")"
    run rm -rf "$target"
    if [[ -L "$backup_path" ]]; then cp -P "$backup_path" "$target"; else cp -a "$backup_path" "$target"; fi
    info "已恢复原有文件：$target"
  done
}
offline_action_uninstall() {
  if [[ "$OFFLINE_PURGE_DATA" -eq 1 ]]; then confirm "即将删除 Docker 程序和数据目录，确认继续？" || cancelled; fi
  has_cmd systemctl && { run systemctl stop docker.service 2>/dev/null || true; run systemctl disable docker.service 2>/dev/null || true; }
  if [[ -f "$OFFLINE_MANIFEST_FILE" ]]; then
    tac "$OFFLINE_MANIFEST_FILE" 2>/dev/null | while read -r path; do
      [[ -n "$path" ]] || continue
      [[ -e "$path" || -L "$path" ]] && { run rm -rf "$path"; info "已删除：$path"; }
    done
  else warn "未找到安装清单，不盲目删除系统文件。"; fi
  offline_restore_backups
  has_cmd systemctl && run systemctl daemon-reload || true
  if [[ "$OFFLINE_PURGE_DATA" -eq 1 ]]; then
    confirm "确认删除 /var/lib/docker /var/lib/containerd /etc/docker？" && run rm -rf /var/lib/docker /var/lib/containerd /etc/docker
  else info "已保留 Docker 数据目录。"; fi
  run rm -rf "$OFFLINE_STATE_DIR"
  info "卸载完成。"
}
offline_action_status() {
  echo; info "==== Docker 状态 ===="
  has_cmd docker && run docker --version || echo "docker 命令：未安装或不在 PATH"
  has_cmd docker && run docker compose version 2>/dev/null || true
  has_cmd docker-compose && run docker-compose version 2>/dev/null || true
  if has_cmd systemctl; then run systemctl --no-pager --full status docker.service 2>/dev/null | head -12 || true; fi
  echo
}
offline_action_package() {
  offline_detect_arch
  offline_action_download
  local pkg_base staging out
  pkg_base="docker-offline-${OFFLINE_DOCKER_VERSION}-compose-${OFFLINE_COMPOSE_VERSION}-${OFFLINE_DOCKER_ARCH}"
  out="${OFFLINE_PACKAGE_FILE:-${pkg_base}.tar.gz}"
  staging="$(mktemp -d)"
  run mkdir -p "$staging/$pkg_base/resources"
  # 生成独立离线安装脚本
  cat > "$staging/$pkg_base/install-docker-offline.sh" <<'OFFLINE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/var/lib/docker-offline-installer"
MANIFEST_FILE="$STATE_DIR/manifest"
BACKUP_MANIFEST_FILE="$STATE_DIR/backup-manifest"
RESOURCE_DIR="${1:-./resources}"
log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "需要 root 权限。"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
confirm_or_die() { local msg="$1" ans; read -r -p "$msg [y/N]: " ans; [[ "$ans" == "y" || "$ans" == "Y" ]] || die "用户取消。"; }
# 对离线包使用场景，运行时传入资源目录即可
if [[ "${1:-}" == "install" ]]; then
  need_root
  RESOURCE_DIR="${2:-./resources}"
  [[ -d "$RESOURCE_DIR" ]] || die "资源目录不存在：$RESOURCE_DIR"
  # 安装 Docker
  tgz="$(find "$RESOURCE_DIR" -maxdepth 1 -name 'docker-*.tgz' | head -1)"
  [[ -f "$tgz" ]] || die "未找到 Docker 资源包"
  log "安装 Docker Engine：$tgz"
  tmpdir="$(mktemp -d)"; tar -xzf "$tgz" -C "$tmpdir"
  for f in "$tmpdir/docker"/*; do [[ -f "$f" ]] && install -m 0755 "$f" "/usr/local/bin/$(basename "$f")"; done
  rm -rf "$tmpdir"
  # 安装 Compose
  src="$(find "$RESOURCE_DIR" -maxdepth 1 \( -name 'docker-compose-*' -o -name 'docker-compose-linux-*' \) | head -1)"
  if [[ -f "$src" ]]; then
    log "安装 Docker Compose：$src"
    mkdir -p /usr/local/lib/docker/cli-plugins
    install -m 0755 "$src" /usr/local/lib/docker/cli-plugins/docker-compose
    ln -sfn /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
  fi
  # systemd
  if has_cmd systemctl; then
    cat > /etc/systemd/system/docker.service <<'UNIT'
[Unit]
Description=Docker Application Container Engine
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
UNIT
    systemctl daemon-reload; systemctl enable --now docker.service
  fi
  log "安装完成。"
elif [[ "${1:-}" == "uninstall" ]]; then
  need_root
  has_cmd systemctl && { systemctl stop docker.service 2>/dev/null || true; systemctl disable docker.service 2>/dev/null || true; }
  rm -f /usr/local/bin/docker /usr/local/bin/dockerd /usr/local/bin/docker-init /usr/local/bin/docker-proxy /usr/local/bin/containerd /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/ctr /usr/local/bin/runc
  rm -f /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
  rm -f /etc/systemd/system/docker.service; has_cmd systemctl && systemctl daemon-reload || true
  [[ "${2:-}" == "--purge-data" ]] && { confirm_or_die "确认删除 /var/lib/docker /var/lib/containerd /etc/docker？"; rm -rf /var/lib/docker /var/lib/containerd /etc/docker; }
  log "卸载完成。"
else
  echo "用法：sudo ./install-docker-offline.sh install ./resources"
  echo "      sudo ./install-docker-offline.sh uninstall [--purge-data]"
fi
OFFLINE_SCRIPT
  run chmod +x "$staging/$pkg_base/install-docker-offline.sh"
  [[ "$OFFLINE_SKIP_DOCKER" -eq 1 ]] || run cp "$(offline_find_docker_resource)" "$staging/$pkg_base/resources/"
  [[ "$OFFLINE_SKIP_COMPOSE" -eq 1 ]] || run cp "$(offline_find_compose_resource)" "$staging/$pkg_base/resources/"
  cat > "$staging/$pkg_base/README.txt" <<EOF_README
Docker 离线二进制安装包
离线安装：sudo ./install-docker-offline.sh install ./resources
卸载：    sudo ./install-docker-offline.sh uninstall
彻底卸载：sudo ./install-docker-offline.sh uninstall --purge-data
版本：Docker Engine $OFFLINE_DOCKER_VERSION / Compose $OFFLINE_COMPOSE_VERSION / 架构 $OFFLINE_DOCKER_ARCH
EOF_README
  run tar -czf "$out" -C "$staging" "$pkg_base"
  run rm -rf "$staging"
  info "离线包已生成：$out"
}
offline_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resource-dir) OFFLINE_RESOURCE_DIR="$2"; shift 2 ;;
      --docker-version) OFFLINE_DOCKER_VERSION="${2#v}"; shift 2 ;;
      --compose-version) OFFLINE_COMPOSE_VERSION="${2#v}"; shift 2 ;;
      --arch) OFFLINE_ARCH_OVERRIDE="$2"; shift 2 ;;
      --download-if-missing) OFFLINE_DOWNLOAD_IF_MISSING=1; shift ;;
      --skip-docker) OFFLINE_SKIP_DOCKER=1; shift ;;
      --skip-compose) OFFLINE_SKIP_COMPOSE=1; shift ;;
      --no-start) OFFLINE_START_SERVICE=0; shift ;;
      --no-enable) OFFLINE_ENABLE_SERVICE=0; shift ;;
      --data-root) OFFLINE_DATA_ROOT="$2"; shift 2 ;;
      --registry-mirror) OFFLINE_REGISTRY_MIRROR="$2"; shift 2 ;;
      --docker-channel) OFFLINE_DOCKER_CHANNEL="$2"; shift 2 ;;
      --docker-url-template) OFFLINE_DOCKER_URL_TEMPLATE="$2"; shift 2 ;;
      --compose-url-template) OFFLINE_COMPOSE_URL_TEMPLATE="$2"; shift 2 ;;
      --compose-latest-url-template) OFFLINE_COMPOSE_LATEST_URL_TEMPLATE="$2"; shift 2 ;;
      --package-file) OFFLINE_PACKAGE_FILE="$2"; shift 2 ;;
      --purge-data) OFFLINE_PURGE_DATA=1; shift ;;
      *) fatal "docker-offline 未知参数：$1" ;;
    esac
  done
  run mkdir -p "$OFFLINE_RESOURCE_DIR" 2>/dev/null || true
  OFFLINE_RESOURCE_DIR="$(cd "$OFFLINE_RESOURCE_DIR" 2>/dev/null && pwd || printf '%s' "$OFFLINE_RESOURCE_DIR")"
}

# ---------- 防火墙 / Swap / LVM / 性能 ----------
is_firewalld_port_rule() { [[ "${1:-}" =~ ^[0-9]+(-[0-9]+)?/(tcp|udp|sctp|dccp)$ ]]; }
preferred_firewall() { if is_macos; then printf application-firewall; elif has_cmd ufw; then printf ufw; elif has_cmd firewall-cmd; then printf firewalld; elif [[ "$PKG_MANAGER" == apt || "$PKG_MANAGER" == pacman ]]; then printf ufw; else printf firewalld; fi; }
install_firewall() { if is_macos; then success "macOS 自带 Application Firewall，无需安装。"; return 0; fi; case "$(preferred_firewall)" in ufw) pkg_install ufw ;; firewalld) pkg_install firewalld ;; esac; success "防火墙安装完成。"; }
firewall_status() { if is_macos; then run_privileged /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate; return 0; fi; has_cmd ufw && run ufw status verbose || { has_cmd firewall-cmd && { run firewall-cmd --state; run firewall-cmd --list-all; } || warn "未安装 ufw/firewalld。"; }; }
firewall_enable() { if is_macos; then confirm "即将启用 macOS Application Firewall。是否继续？" || cancelled; run_privileged /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on; return 0; fi; confirm "即将启用防火墙。请确认 SSH 等远程管理端口已放行。是否继续？" || cancelled; install_firewall; has_cmd ufw && run ufw --force enable || run systemctl enable --now firewalld; }
firewall_disable() { if is_macos; then confirm "即将停用 macOS Application Firewall。是否继续？" || cancelled; run_privileged /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off; return 0; fi; confirm "即将停用防火墙，系统暴露面可能扩大。是否继续？" || cancelled; has_cmd ufw && run ufw disable || { has_cmd systemctl && run systemctl disable --now firewalld || warn "未检测到防火墙命令。"; }; }
firewall_allow() { is_macos && { not_applicable "macOS Application Firewall 不按 Linux 端口规则管理。"; return $?; }; local rule="${1:-}"; [[ -n "$rule" ]] || read -r -p "允许端口/服务，如 22/tcp 或 http: " rule; [[ -n "$rule" ]] || cancelled; confirm "即将放行 ${rule}。是否继续？" || cancelled; if has_cmd ufw; then run ufw allow "$rule"; elif has_cmd firewall-cmd; then is_firewalld_port_rule "$rule" && run firewall-cmd --permanent --add-port="$rule" || run firewall-cmd --permanent --add-service="$rule"; run firewall-cmd --reload; else fatal "未安装防火墙。"; fi; }
firewall_deny() { is_macos && { not_applicable "macOS Application Firewall 不按 Linux 端口规则管理。"; return $?; }; local rule="${1:-}"; [[ -n "$rule" ]] || read -r -p "拒绝或移除放行的端口/服务，如 22/tcp 或 http: " rule; [[ -n "$rule" ]] || cancelled; confirm "即将拒绝或移除 ${rule} 的放行规则。是否继续？" || cancelled; if has_cmd ufw; then run ufw deny "$rule"; elif has_cmd firewall-cmd; then is_firewalld_port_rule "$rule" && run firewall-cmd --permanent --remove-port="$rule" || run firewall-cmd --permanent --remove-service="$rule"; run firewall-cmd --reload; else fatal "未安装防火墙。"; fi; }
uninstall_firewall() { is_macos && { not_applicable "macOS Application Firewall 是系统组件，不支持卸载。"; return $?; }; confirm "即将卸载防火墙软件包，可能影响当前安全策略。是否继续？" || cancelled; has_cmd ufw && pkg_remove ufw || { has_cmd firewall-cmd && { has_cmd systemctl && run systemctl disable --now firewalld || true; pkg_remove firewalld; } || warn "未检测到 ufw/firewalld。"; }; }
ensure_linux_only() { if is_macos; then not_applicable "$1"; return $?; fi; }
swap_list() { ensure_linux_only "macOS 的虚拟内存由系统自动管理。"; swapon --show || true; free -h || true; }
swap_add() { ensure_linux_only "macOS 不支持此 Linux swapfile 操作。"; local size="${1:-}" path="${2:-/swapfile}" input_path; [[ -n "$size" ]] || read -r -p "Swap 大小，如 2G/4096M: " size; [[ -n "$size" ]] || cancelled; [[ "${2:-}" == "" ]] && { read -r -p "Swap 文件路径 [$path]: " input_path || true; path="${input_path:-$path}"; }; [[ ! -e "$path" ]] || fatal "文件已存在：$path"; confirm "即将创建 ${path}，大小 ${size}，并写入 /etc/fstab。是否继续？" || cancelled; has_cmd fallocate && run fallocate -l "$size" "$path" || fatal "缺少 fallocate，请手动创建 swap 文件。"; run chmod 600 "$path"; run mkswap "$path"; run swapon "$path"; append_line_if_missing /etc/fstab "$path none swap sw 0 0"; success "Swap 已增加。"; }
swap_delete() { ensure_linux_only "macOS 不支持此 Linux swapfile 操作。"; local path="${1:-}"; [[ -n "$path" ]] || { swap_list; read -r -p "输入要删除的 swap 路径，如 /swapfile: " path; }; [[ -n "$path" ]] || cancelled; confirm "即将停用并删除 ${path}。是否继续？" || cancelled; swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$path" && run swapoff "$path" || true; [[ -f /etc/fstab ]] && run sed -i.bak "\#^${path} #d" /etc/fstab; [[ -e "$path" ]] && run rm -f "$path"; success "Swap 已删除。"; }
swap_resize() { ensure_linux_only "macOS 的虚拟内存由系统自动管理。"; local size="${1:-}" path="${2:-/swapfile}"; [[ -n "$size" ]] || read -r -p "新的 swap 大小，如 4G: " size; [[ -e "$path" ]] && swap_delete "$path"; swap_add "$size" "$path"; }
# ---------- LVM 管理 (融合自 lvm-manager.sh: 创建/扩容/删除/查询, 自动挂载+fstab, dry-run) ----------
ensure_lvm() { ensure_linux_only "macOS 不支持 Linux LVM。"; has_cmd lvm || pkg_install lvm2; local missing=(); has_cmd pvcreate || missing+=(lvm2); has_cmd mkfs.xfs || missing+=(xfsprogs); has_cmd mkfs.ext4 || missing+=(e2fsprogs); (( ${#missing[@]} > 0 )) && pkg_install "${missing[@]}"; lvm_check_deps || fatal "LVM 依赖工具仍不完整，请执行: $(lvm_pkg_hint)"; }
lvm_pkg_hint() {
  local pkgs="lvm2 xfsprogs e2fsprogs"
  if   has_cmd pacman; then echo "sudo pacman -S $pkgs"
  elif has_cmd apt-get; then echo "sudo apt install $pkgs"
  elif has_cmd dnf;    then echo "sudo dnf install $pkgs"
  elif has_cmd yum;    then echo "sudo yum install $pkgs"
  elif has_cmd zypper; then echo "sudo zypper install $pkgs"
  else echo "$pkgs"
  fi
}
lvm_check_deps() {
  local cmds=(pvcreate pvremove vgcreate vgextend vgremove vgreduce
              lvcreate lvextend lvremove lvchange
              pvs vgs lvs blkid findmnt lsblk mount umount)
  local missing=() c
  for c in "${cmds[@]}"; do
    has_cmd "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    error "缺少必要命令: ${missing[*]}"
    warn "请先安装: $(lvm_pkg_hint)"
    return 1
  fi
}
lvm_normalize_fs() {
  local fs=${1,,}
  case $fs in
    xfs|ext4) printf '%s\n' "$fs" ;;
    *)        printf '%s\n' "$1" ;;
  esac
}
lvm_fs_tools_check() {
  local fs c
  fs=$(lvm_normalize_fs "$1")
  case $fs in
    xfs)
      for c in mkfs.xfs xfs_growfs; do
        has_cmd "$c" || { error "缺少 $c，请安装 xfsprogs ($(lvm_pkg_hint))"; return 1; }
      done ;;
    ext4)
      for c in mkfs.ext4 resize2fs; do
        has_cmd "$c" || { error "缺少 $c，请安装 e2fsprogs ($(lvm_pkg_hint))"; return 1; }
      done ;;
    *)
      error "不支持的文件系统: $1 (仅支持 xfs / ext4)"
      return 1 ;;
  esac
}
lvm_valid_name() {
  local name=$1 what=$2
  if [[ -z $name ]]; then error "$what 不能为空"; return 1; fi
  if (( ${#name} > 127 )); then error "$what 过长 (最多 127 字符): $name"; return 1; fi
  if [[ $name == -* || $name == .* ]]; then error "$what 不能以 '-' 或 '.' 开头: $name"; return 1; fi
  if [[ $name == */* ]]; then error "$what 不能包含 '/': $name"; return 1; fi
  if [[ ! $name =~ ^[A-Za-z0-9._+-]+$ ]]; then error "$what 只能包含字母、数字和 ._+- : $name"; return 1; fi
}
lvm_lv_dev() {
  local vg=$1 lv=$2 mapper
  if [[ -e "/dev/$vg/$lv" ]]; then printf '%s\n' "/dev/$vg/$lv"; return 0; fi
  mapper="/dev/mapper/${vg//-/--}-${lv//-/--}"
  if [[ -e $mapper ]]; then printf '%s\n' "$mapper"; return 0; fi
  printf '%s\n' "/dev/$vg/$lv"
}
lvm_confirm() { [[ "$DRY_RUN" -eq 1 ]] && return 0; confirm "$@"; }
lvm_confirm_danger() {
  local msg="$1" ans=""
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if [[ "$ASSUME_YES" -eq 1 ]]; then warn "$msg [自动确认 -y]"; return 0; fi
  printf '%s 危险操作，请输入 yes 确认: ' "$msg"
  read -r ans || true
  [[ "${ans:-}" == "yes" ]]
}
lvm_pv_exists() { pvs "$1" >/dev/null 2>&1; }
lvm_vg_exists() { vgs "$1" >/dev/null 2>&1; }
lvm_lv_exists() { lvs "$(lvm_lv_dev "$1" "$2")" >/dev/null 2>&1 || lvs "/dev/$1/$2" >/dev/null 2>&1; }
lvm_require_vg() {
  if lvm_vg_exists "$1"; then return 0; fi
  if [[ $DRY_RUN -eq 1 && $LVM_PLANNED_VG -eq 1 ]]; then return 0; fi
  error "卷组 $1 不存在"
  return 1
}
lvm_pv_in_vg() {
  local vgname
  vgname=$(pvs --noheadings -o vg_name "$1" 2>/dev/null | awk '{print $1}' || true)
  [[ $vgname == "$2" ]]
}
lvm_vg_free_mb() { vgs --noheadings --nosuffix --units m -o vg_free "$1" 2>/dev/null | awk '{printf "%d", $1}' || true; }
lvm_vg_free_mb_planned() {
  local vg=$1 free extra=0
  free=$(lvm_vg_free_mb "$vg")
  free=${free:-0}
  if [[ $DRY_RUN -eq 1 && -n ${LVM_DISK:-} ]] && ! lvm_pv_in_vg "$LVM_DISK" "$vg"; then
    extra=$(lvm_disk_size_mb "$LVM_DISK" || true)
    extra=${extra:-0}
    if (( extra > 0 )); then
      free=$((free + extra))
      printf '%s\n' "[dry-run] 加上将加入的磁盘 $LVM_DISK 估算可用空间: ${free}MB (未计入 LVM 元数据开销)" >&2
    fi
  fi
  printf '%d\n' "$free"
}
lvm_lv_size_mb() { lvs --noheadings --nosuffix --units m -o lv_size "$(lvm_lv_dev "$1" "$2")" 2>/dev/null | awk '{printf "%d", $1}' || true; }
lvm_disk_size_mb() {
  local bytes
  bytes=$(lsblk -bno SIZE -d "$1" 2>/dev/null | awk 'NR==1 {print $1}' || true)
  [[ -n $bytes ]] || { echo 0; return 1; }
  awk -v b="$bytes" 'BEGIN { printf "%d", b/1024/1024 }'
}
lvm_to_mb() {
  echo "$1" | awk '{
    v=$0; unit="";
    if (match(v,/[kKmMgGtTpPeE]$/)) { unit=substr(v,RSTART,1); v=substr(v,1,RSTART-1) }
    n=v+0; m=1;
    if (unit=="K"||unit=="k") m=1/1024;
    else if (unit=="G"||unit=="g") m=1024;
    else if (unit=="T"||unit=="t") m=1024*1024;
    else if (unit=="P"||unit=="p") m=1024*1024*1024;
    else if (unit=="E"||unit=="e") m=1024*1024*1024*1024;
    printf "%d", n*m
  }'
}
lvm_valid_size() { [[ $1 =~ ^\+?[0-9]+([.][0-9]+)?[kKmMgGtTpP]?$ || $1 =~ ^\+?[0-9]+%[A-Z]+$ ]]; }
lvm_normalize_size() {
  local s=$1
  case $s in
    max|MAX|all|ALL) printf '%s\n' "100%FREE"; return ;;
  esac
  if [[ $s =~ ^(\+?[0-9]+%)([A-Za-z]+)$ ]]; then
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]^^}"
    return
  fi
  printf '%s\n' "$s"
}
lvm_size_help() {
  cat <<EOF
大小参数格式 (-s)
  绝对值     100G / 500M / 2T        指定固定大小 (create/extend 均可用)
  相对扩容   +50G / +200M             在现有基础上增加 (仅 extend)
  百分比     100%FREE                 占满卷组剩余空间
             50%VG                    卷组总空间的 50%
             50%PVS                   卷组内单个 PV 空间的 50%
  便捷写法   max / all                = 100%FREE, 一键占满剩余空间

示例:
  $PROGRAM_NAME lvm create -d /dev/sdb -v vg_data -l lv_data -s 100G -f xfs -m /data
  $PROGRAM_NAME lvm extend -v vg_data -l lv_data -s max
  $PROGRAM_NAME lvm extend -v vg_data -l lv_data -s +50G
EOF
}
lvm_disk_is_empty() {
  local dev=$1 devtype base holders_dir holders sig
  [[ -b $dev ]] || { error "$dev 不是块设备"; return 1; }
  if findmnt "$dev" >/dev/null 2>&1; then error "$dev 已挂载，拒绝操作"; return 1; fi
  if lsblk -nro MOUNTPOINT "$dev" 2>/dev/null | grep -q '[^[:space:]]'; then
    error "$dev 或其分区已挂载，拒绝操作"; return 1
  fi
  lvm_pv_exists "$dev" && { error "$dev 已是 PV"; return 1; }
  base=$(basename "$(readlink -f "$dev" 2>/dev/null || echo "$dev")")
  holders_dir="/sys/class/block/$base/holders"
  if [[ -d $holders_dir ]]; then
    holders=$(ls -A "$holders_dir" 2>/dev/null || true)
    if [[ -n $holders ]]; then error "$dev 被占用 (holders: $holders)，可能属于 multipath/md/dm"; return 1; fi
  fi
  if [[ -r /proc/mdstat ]] && grep -Fq "$base" /proc/mdstat; then error "$dev 出现在 /proc/mdstat，可能属于 mdadm 阵列"; return 1; fi
  devtype=$(lsblk -nro TYPE "$dev" 2>/dev/null | head -1)
  if [[ $devtype == disk ]]; then
    if lsblk -nro TYPE "$dev" 2>/dev/null | tail -n +2 | grep -q '^part$'; then
      error "$dev 包含分区，不是空盘。如需整盘使用请先: wipefs -a $dev"; return 1
    fi
  fi
  if has_cmd wipefs; then
    if sig=$(wipefs -n -i "$dev" 2>/dev/null); then
      :
    elif sig=$(wipefs -n "$dev" 2>/dev/null); then
      sig=$(printf '%s\n' "$sig" | awk 'NR==1 && $1=="DEVICE" {next} {print}')
    else
      if blkid "$dev" >/dev/null 2>&1; then
        error "$dev 存在文件系统/分区表签名 (wipefs 探测失败，blkid 有结果)，不是空盘。如需清空请先: wipefs -a $dev"; return 1
      fi
      error "无法探测 $dev 的签名 (wipefs 失败)，拒绝当作空盘处理"; return 1
    fi
    sig=$(printf '%s\n' "$sig" | awk 'NF {print}')
    if [[ -n $sig ]]; then
      error "$dev 存在文件系统/分区表签名，不是空盘:"
      printf '%s\n' "$sig"
      error "如需清空请先: wipefs -a $dev"
      return 1
    fi
  elif blkid "$dev" >/dev/null 2>&1; then
    error "$dev 存在文件系统/分区表签名，不是空盘。如需清空请先: wipefs -a $dev"; return 1
  fi
  return 0
}
lvm_is_swap_dev() {
  local dev=$1 real n
  real=$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")
  while read -r n; do
    [[ -z $n ]] && continue
    if [[ $n == "$dev" || $n == "$real" ]]; then return 0; fi
    if [[ $(readlink -f "$n" 2>/dev/null || true) == "$real" ]]; then return 0; fi
  done < <(swapon --noheadings --show=NAME 2>/dev/null || true)
  return 1
}
lvm_swap_off_if_needed() {
  local dev=$1
  lvm_is_swap_dev "$dev" || return 0
  run swapoff "$dev" || { error "swapoff $dev 失败"; return 1; }
  info "已关闭 swap $dev"
}
lvm_fstab_has_uuid() { awk -v u="UUID=$1" '$1==u {found=1} END{exit !found}' /etc/fstab; }
lvm_fstab_has_mp()   { awk -v mp="$1" '$2==mp {found=1} END{exit !found}' /etc/fstab; }
lvm_backup_fstab() {
  local bak
  [[ $LVM_FSTAB_BACKED_UP -eq 1 ]] && return 0
  [[ -f /etc/fstab ]] || { error "/etc/fstab 不存在"; return 1; }
  bak="/etc/fstab.bak.lvm-manager.$(date +%Y%m%d-%H%M%S)"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 备份 /etc/fstab → $bak"
    LVM_FSTAB_BACKED_UP=1
    return 0
  fi
  cp -a /etc/fstab "$bak" || { error "备份 fstab 失败"; return 1; }
  info "已备份 fstab → $bak"
  LVM_FSTAB_BACKED_UP=1
}
lvm_add_fstab() {
  local vg=$1 lv=$2 fs=$3 mp=$4 uuid pass
  if [[ $DRY_RUN -eq 1 ]]; then
    [[ $fs == xfs ]] && pass=0 || pass=2
    info "[dry-run] 写入 /etc/fstab: UUID=<新建>  $mp  $fs  defaults  0  $pass  # lvm-manager"
    return 0
  fi
  uuid=$(blkid -s UUID -o value "$(lvm_lv_dev "$vg" "$lv")" 2>/dev/null) \
    || { warn "无法获取 UUID，跳过 fstab 写入"; return 1; }
  if lvm_fstab_has_uuid "$uuid"; then warn "fstab 已存在该 UUID，跳过"; return 0; fi
  if lvm_fstab_has_mp "$mp"; then warn "fstab 已存在挂载点 $mp，跳过"; return 0; fi
  [[ $fs == xfs ]] && pass=0 || pass=2
  lvm_backup_fstab || return 1
  printf 'UUID=%s  %s  %s  defaults  0  %d  # lvm-manager\n' "$uuid" "$mp" "$fs" "$pass" >> /etc/fstab
  success "已写入 /etc/fstab: UUID=$uuid → $mp"
}
lvm_rm_fstab_by_uuid() {
  local uuid=$1 tmp
  [[ -n $uuid ]] || return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 从 /etc/fstab 删除首字段为 UUID=$uuid 的行"
    return 0
  fi
  lvm_fstab_has_uuid "$uuid" || return 0
  lvm_backup_fstab || return 1
  tmp=$(mktemp /etc/fstab.lvm-manager.XXXXXX) || { error "无法创建临时文件"; return 1; }
  if ! awk -v u="UUID=$uuid" '$1==u {next} {print}' /etc/fstab > "$tmp"; then
    rm -f "$tmp"; error "生成新 fstab 失败，原文件未改动"; return 1
  fi
  if [[ ! -s $tmp ]]; then
    rm -f "$tmp"; error "生成的 fstab 为空，拒绝覆盖 /etc/fstab"; return 1
  fi
  chmod --reference=/etc/fstab "$tmp" 2>/dev/null || true
  chown --reference=/etc/fstab "$tmp" 2>/dev/null || true
  if has_cmd chcon; then chcon --reference=/etc/fstab "$tmp" 2>/dev/null || true; fi
  if [[ -L /etc/fstab ]]; then
    if ! cat "$tmp" > /etc/fstab; then
      error "写入 /etc/fstab 失败。备份: /etc/fstab.bak.lvm-manager.*  临时文件: $tmp"; return 1
    fi
    rm -f "$tmp"; return 0
  fi
  if ! mv -f "$tmp" /etc/fstab; then
    error "替换 /etc/fstab 失败，原文件未改动。临时文件: $tmp"; return 1
  fi
}
lvm_print_create_leftover() {
  local bits=() cmds=()
  [[ $DRY_RUN -eq 1 ]] && return 0
  [[ $LVM_CREATED_LV -eq 1 ]] && bits+=("LV $LVM_VG/$LVM_LV") && cmds+=("$PROGRAM_NAME lvm delete -v $LVM_VG -l $LVM_LV")
  [[ $LVM_CREATED_VG -eq 1 ]] && bits+=("空 VG $LVM_VG") && cmds+=("$PROGRAM_NAME lvm delete -v $LVM_VG")
  [[ $LVM_CREATED_PV -eq 1 ]] && bits+=("PV $LVM_DISK") && cmds+=("$PROGRAM_NAME lvm delete -d $LVM_DISK")
  (( ${#bits[@]} == 0 )) && return 0
  warn "本次已落地、需要手动清理: ${bits[*]}"
  warn "清理: ${cmds[*]}"
}
lvm_ensure_pv_in_vg() {
  if ! lvm_vg_exists "$LVM_VG"; then
    lvm_disk_is_empty "$LVM_DISK" || return 1
    lvm_confirm "将 $LVM_DISK 创建为 PV 并加入新卷组 $LVM_VG ?" || return 1
    run pvcreate -y "$LVM_DISK" || return 1
    [[ $DRY_RUN -eq 1 ]] || LVM_CREATED_PV=1
    if ! run vgcreate "$LVM_VG" "$LVM_DISK"; then
      warn "卷组创建失败，回滚: pvremove $LVM_DISK"
      run pvremove -y "$LVM_DISK" >/dev/null 2>&1 || true
      LVM_CREATED_PV=0
      return 1
    fi
    [[ $DRY_RUN -eq 1 ]] || LVM_CREATED_VG=1
    LVM_PLANNED_VG=1
    return 0
  fi
  if lvm_pv_in_vg "$LVM_DISK" "$LVM_VG"; then info "$LVM_DISK 已在卷组 $LVM_VG 中"; return 0; fi
  if lvm_pv_exists "$LVM_DISK"; then
    local othervg
    othervg=$(pvs --noheadings -o vg_name "$LVM_DISK" 2>/dev/null | awk '{print $1}' || true)
    if [[ -n $othervg && $othervg != " " ]]; then
      error "$LVM_DISK 属于卷组 $othervg，不能加入 $LVM_VG。请先: $PROGRAM_NAME lvm delete -d $LVM_DISK 释放该 PV"
    else
      error "$LVM_DISK 已是独立 PV，不能当作空盘创建。请用: $PROGRAM_NAME lvm extend -v $LVM_VG -d $LVM_DISK"
    fi
    return 1
  fi
  lvm_disk_is_empty "$LVM_DISK" || return 1
  lvm_confirm "卷组 $LVM_VG 已存在，将 $LVM_DISK 加入 ?" || return 1
  run pvcreate -y "$LVM_DISK" || return 1
  [[ $DRY_RUN -eq 1 ]] || LVM_CREATED_PV=1
  if ! run vgextend -y "$LVM_VG" "$LVM_DISK"; then
    run pvremove -y "$LVM_DISK" >/dev/null 2>&1 || true
    LVM_CREATED_PV=0
    return 1
  fi
}
lvm_check_lv_space() {
  local need free
  if [[ $LVM_SIZE == *%* || $LVM_SIZE == +* ]]; then return 0; fi
  need=$(lvm_to_mb "$LVM_SIZE")
  if lvm_vg_exists "$LVM_VG"; then
    free=$(lvm_vg_free_mb_planned "$LVM_VG")
  elif [[ $DRY_RUN -eq 1 && -n $LVM_DISK ]]; then
    free=$(lvm_disk_size_mb "$LVM_DISK" || true)
    info "[dry-run] 按磁盘容量估算可用空间: ${free}MB (未计入 LVM 元数据开销)"
  else
    free=$(lvm_vg_free_mb "$LVM_VG")
  fi
  if (( need > free )); then
    error "卷组 $LVM_VG 剩余空间不足: 需要 ${need}MB, 剩余 ${free}MB"; return 1
  fi
  if [[ $LVM_FS == xfs && need -lt 300 ]]; then
    error "xfs 文件系统最小需要 300MB，当前仅 ${need}MB。请加大大小，或改用 ext4 (输入 sizes 查看格式)"; return 1
  fi
}
lvm_check_mount_target() {
  [[ $LVM_MOUNT == /* ]] || { error "挂载点必须是绝对路径: $LVM_MOUNT"; return 1; }
  [[ $LVM_MOUNT != "/" ]] || { error "禁止挂载到根目录 /"; return 1; }
  if findmnt "$LVM_MOUNT" >/dev/null 2>&1; then error "挂载点 $LVM_MOUNT 已被占用"; return 1; fi
  if [[ -d $LVM_MOUNT ]] && [[ -n $(ls -A "$LVM_MOUNT" 2>/dev/null) ]]; then
    warn "挂载点 $LVM_MOUNT 已存在且非空，挂载后原内容将被暂时隐藏"
    if [[ $LVM_MOUNT_CONFIRMED -eq 0 ]]; then
      lvm_confirm "继续挂载到非空目录 $LVM_MOUNT ?" || return 1
      LVM_MOUNT_CONFIRMED=1
    fi
  fi
}
lvm_create_lv_on_vg() {
  local dev
  lvm_require_vg "$LVM_VG" || return 1
  lvm_lv_exists "$LVM_VG" "$LVM_LV" && { error "逻辑卷 $LVM_VG/$LVM_LV 已存在"; return 1; }
  lvm_check_lv_space || return 1
  lvm_check_mount_target || return 1
  lvm_confirm "创建逻辑卷 $LVM_VG/$LVM_LV (${LVM_SIZE})，格式化为 $LVM_FS 并挂载到 $LVM_MOUNT ?" || return 1
  if [[ $LVM_SIZE == *%* ]]; then
    run lvcreate -y -l "$LVM_SIZE" -n "$LVM_LV" "$LVM_VG" || { lvm_print_create_leftover; return 1; }
  else
    run lvcreate -y -L "$LVM_SIZE" -n "$LVM_LV" "$LVM_VG" || { lvm_print_create_leftover; return 1; }
  fi
  [[ $DRY_RUN -eq 1 ]] || LVM_CREATED_LV=1
  dev=$(lvm_lv_dev "$LVM_VG" "$LVM_LV")
  if [[ $LVM_FS == xfs ]]; then
    if ! run mkfs.xfs -f "$dev"; then
      if run lvremove -y "$dev" >/dev/null 2>&1; then LVM_CREATED_LV=0; error "格式化失败，已删除 LV"; else error "格式化失败，且回滚删除 LV 失败，请手动清理 $dev"; fi
      lvm_print_create_leftover
      return 1
    fi
  else
    if ! run mkfs.ext4 -F "$dev"; then
      if run lvremove -y "$dev" >/dev/null 2>&1; then LVM_CREATED_LV=0; error "格式化失败，已删除 LV"; else error "格式化失败，且回滚删除 LV 失败，请手动清理 $dev"; fi
      lvm_print_create_leftover
      return 1
    fi
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] mkdir -p $LVM_MOUNT"
    info "[dry-run] mount $dev $LVM_MOUNT"
  else
    mkdir -p "$LVM_MOUNT" || { error "创建挂载点 $LVM_MOUNT 失败"; lvm_print_create_leftover; return 1; }
    if ! mount "$dev" "$LVM_MOUNT"; then
      error "挂载失败。LV 已格式化但未写入 fstab。"
      warn "设备: $dev  挂载点: $LVM_MOUNT"
      lvm_print_create_leftover
      return 1
    fi
  fi
  lvm_add_fstab "$LVM_VG" "$LVM_LV" "$LVM_FS" "$LVM_MOUNT" || true
  success "创建完成: VG=$LVM_VG / LV=$LVM_LV($LVM_SIZE) / FS=$LVM_FS / 挂载点=$LVM_MOUNT"
}
lvm_cmd_create_vg() {
  if [[ -z $LVM_DISK || -z $LVM_VG ]]; then error "create-vg 参数不完整: 需要 -d -v"; lvm_usage; return 1; fi
  lvm_valid_name "$LVM_VG" "卷组名" || return 1
  if lvm_vg_exists "$LVM_VG"; then
    error "卷组 $LVM_VG 已存在。若要加盘请用: $PROGRAM_NAME lvm extend -v $LVM_VG -d $LVM_DISK"; return 1
  fi
  lvm_ensure_pv_in_vg || return 1
  success "卷组创建完成: $LVM_DISK → VG=$LVM_VG"
}
lvm_cmd_create_lv() {
  if [[ -z $LVM_VG || -z $LVM_LV || -z $LVM_SIZE || -z $LVM_FS || -z $LVM_MOUNT ]]; then
    error "create-lv 参数不完整: 需要 -v -l -s -f -m"; lvm_usage; return 1
  fi
  lvm_valid_name "$LVM_VG" "卷组名" || return 1
  lvm_valid_name "$LVM_LV" "逻辑卷名" || return 1
  LVM_FS=$(lvm_normalize_fs "$LVM_FS")
  lvm_fs_tools_check "$LVM_FS" || return 1
  LVM_SIZE=$(lvm_normalize_size "$LVM_SIZE")
  lvm_valid_size "$LVM_SIZE" || { error "大小格式不合法: $LVM_SIZE"; lvm_size_help; return 1; }
  [[ $LVM_SIZE != +* ]] || { error "create 不支持相对大小 (如 +50G)，请用绝对值 50G 或 max"; return 1; }
  if ! lvm_vg_exists "$LVM_VG"; then
    error "卷组 $LVM_VG 不存在。请先: $PROGRAM_NAME lvm create-vg -d <磁盘> -v $LVM_VG"; return 1
  fi
  lvm_create_lv_on_vg
}
lvm_cmd_create() {
  if [[ -z $LVM_DISK || -z $LVM_VG || -z $LVM_LV || -z $LVM_SIZE || -z $LVM_FS || -z $LVM_MOUNT ]]; then
    error "create 参数不完整: 需要 -d -v -l -s -f -m"
    info "只建卷组: $PROGRAM_NAME lvm create-vg -d <磁盘> -v <卷组>"
    info "已有卷组上建 LV: $PROGRAM_NAME lvm create-lv -v <卷组> -l <逻辑卷> -s <大小> -f <fs> -m <挂载点>"
    lvm_usage
    return 1
  fi
  lvm_valid_name "$LVM_VG" "卷组名" || return 1
  lvm_valid_name "$LVM_LV" "逻辑卷名" || return 1
  LVM_FS=$(lvm_normalize_fs "$LVM_FS")
  lvm_fs_tools_check "$LVM_FS" || return 1
  LVM_SIZE=$(lvm_normalize_size "$LVM_SIZE")
  lvm_valid_size "$LVM_SIZE" || { error "大小格式不合法: $LVM_SIZE"; lvm_size_help; return 1; }
  [[ $LVM_SIZE != +* ]] || { error "create 不支持相对大小 (如 +50G)，请用绝对值 50G 或 max"; return 1; }
  lvm_check_mount_target || return 1
  lvm_ensure_pv_in_vg || return 1
  lvm_create_lv_on_vg || return 1
}
lvm_cmd_create_pv() {
  [[ -n $LVM_DISK ]] || { error "create-pv 需要 -d 指定设备"; lvm_usage; return 1; }
  [[ -b $LVM_DISK ]] || { error "$LVM_DISK 不是块设备"; return 1; }
  lvm_disk_is_empty "$LVM_DISK" || return 1
  lvm_confirm "将 $LVM_DISK 初始化为 PV ?" || { warn "用户取消操作。"; return "$CANCEL_RC"; }
  run pvcreate -y "$LVM_DISK" || return 1
  success "已创建 PV: $LVM_DISK"
}
lvm_grow_fs() {
  local vg=$1 lv=$2 fstype mp
  local dev
  dev=$(lvm_lv_dev "$vg" "$lv")
  if [[ $DRY_RUN -eq 1 ]]; then
    fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || echo "${LVM_FS:-未知}")
    case $fstype in
      xfs)
        mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null || true)
        info "[dry-run] xfs_growfs ${mp:-(需在挂载状态下扩容)}" ;;
      ext4) info "[dry-run] resize2fs $dev" ;;
      *)    info "[dry-run] 扩容文件系统 ($fstype)" ;;
    esac
    return 0
  fi
  fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
  case $fstype in
    xfs)
      mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null || true)
      [[ -n $mp ]] || { error "xfs 扩容需在挂载状态进行，$dev 未挂载"; return 1; }
      xfs_growfs "$mp" || return 1 ;;
    ext4)
      resize2fs "$dev" || return 1 ;;
    *)
      warn "未知文件系统 '$fstype'，跳过文件系统扩容 (LV 已扩容)" ;;
  esac
}
lvm_cmd_extend() {
  [[ -n $LVM_VG ]] || { error "extend 需要 -v 指定卷组"; lvm_usage; return 1; }
  [[ -n $LVM_DISK || -n $LVM_LV ]] || { error "extend 需要 -d 加盘 或 -l/-s 扩容 LV"; lvm_usage; return 1; }
  lvm_valid_name "$LVM_VG" "卷组名" || return 1
  [[ -z $LVM_LV ]] || lvm_valid_name "$LVM_LV" "逻辑卷名" || return 1
  if [[ -n $LVM_SIZE ]]; then
    LVM_SIZE=$(lvm_normalize_size "$LVM_SIZE")
    lvm_valid_size "$LVM_SIZE" || { error "大小格式不合法: $LVM_SIZE"; lvm_size_help; return 1; }
  fi
  lvm_vg_exists "$LVM_VG" || { error "卷组 $LVM_VG 不存在"; return 1; }
  if [[ -n $LVM_DISK ]]; then
    if lvm_pv_exists "$LVM_DISK"; then
      if lvm_pv_in_vg "$LVM_DISK" "$LVM_VG"; then
        info "$LVM_DISK 已在卷组 $LVM_VG 中，跳过加盘"
      else
        local othervg
        othervg=$(pvs --noheadings -o vg_name "$LVM_DISK" 2>/dev/null | awk '{print $1}' || true)
        if [[ -n $othervg && $othervg != " " ]]; then
          error "$LVM_DISK 属于卷组 $othervg，不能加入 $LVM_VG。请先: $PROGRAM_NAME lvm delete -d $LVM_DISK 释放该 PV"
          return 1
        fi
        lvm_confirm "将已存在的 PV $LVM_DISK 加入卷组 $LVM_VG ?" || return 1
        run vgextend -y "$LVM_VG" "$LVM_DISK" || return 1
        success "已将 $LVM_DISK 加入卷组 $LVM_VG"
      fi
    else
      lvm_disk_is_empty "$LVM_DISK" || return 1
      lvm_confirm "创建 PV 并把 $LVM_DISK 加入卷组 $LVM_VG ?" || return 1
      run pvcreate -y "$LVM_DISK" || return 1
      if ! run vgextend -y "$LVM_VG" "$LVM_DISK"; then
        run pvremove -y "$LVM_DISK" >/dev/null 2>&1 || true
        return 1
      fi
      success "已将 $LVM_DISK 加入卷组 $LVM_VG"
    fi
  fi
  if [[ -n $LVM_LV ]]; then
    [[ -n $LVM_SIZE ]] || { error "扩容 LV 需要 -s 指定大小"; lvm_size_help; return 1; }
    lvm_lv_exists "$LVM_VG" "$LVM_LV" || { error "逻辑卷 $LVM_VG/$LVM_LV 不存在"; return 1; }
    local fstype dev
    dev=$(lvm_lv_dev "$LVM_VG" "$LVM_LV")
    fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
    case $fstype in
      xfs|ext4) lvm_fs_tools_check "$fstype" || return 1 ;;
      *) warn "文件系统 '$fstype' 非 xfs/ext4，将仅扩容 LV，不扩容文件系统" ;;
    esac
    if [[ $LVM_SIZE != +* && $LVM_SIZE != *%* ]]; then
      local cur target need free
      cur=$(lvm_lv_size_mb "$LVM_VG" "$LVM_LV"); target=$(lvm_to_mb "$LVM_SIZE")
      if (( target <= cur )); then error "目标大小 ${LVM_SIZE} 不大于当前大小，拒绝操作 (本工具不支持缩小)"; return 1; fi
      need=$(( target - cur )); free=$(lvm_vg_free_mb_planned "$LVM_VG")
      if (( need > free )); then error "卷组 $LVM_VG 剩余空间不足: 需要 ${need}MB, 剩余 ${free}MB"; return 1; fi
    fi
    lvm_confirm "扩容逻辑卷 $LVM_VG/$LVM_LV → ${LVM_SIZE}，并同步扩容文件系统 ?" || return 1
    if [[ $LVM_SIZE == *%* ]]; then
      run lvextend -y -l "$LVM_SIZE" "$dev" || return 1
    else
      run lvextend -y -L "$LVM_SIZE" "$dev" || return 1
    fi
    lvm_grow_fs "$LVM_VG" "$LVM_LV" || return 1
    success "扩容完成: $LVM_VG/$LVM_LV → ${LVM_SIZE} (文件系统: ${fstype:-未知})"
  fi
}
lvm_delete_lv() {
  local vg=$1 lv=$2 mp uuid is_swap=0
  local dev
  lvm_lv_exists "$vg" "$lv" || { error "逻辑卷 $vg/$lv 不存在"; return 1; }
  dev=$(lvm_lv_dev "$vg" "$lv")
  if [[ ! -e $dev ]]; then
    warn "$dev 设备节点不存在 (LV 未激活)，先激活以读取信息"
    run lvchange -ay "$vg/$lv" || { error "激活 $vg/$lv 失败"; return 1; }
    dev=$(lvm_lv_dev "$vg" "$lv")
  fi
  if lvm_is_swap_dev "$dev"; then is_swap=1; fi
  mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null || true)
  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
  [[ $is_swap -eq 1 ]] && info "检测到 $dev 正在作为 swap 使用，确认后将先关闭"
  [[ -n $mp ]] && info "检测到 $dev 已挂载到 $mp，确认后将先卸载"
  if [[ -n $uuid ]] && lvm_fstab_has_uuid "$uuid"; then
    info "确认后将同步删除 /etc/fstab 中 UUID=$uuid 的条目"
  elif [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] 若 fstab 中有该 LV 的 UUID 条目将一并删除"
  fi
  lvm_confirm_danger "确认删除逻辑卷 $dev 及其所有数据?" || return 1
  if [[ $is_swap -eq 1 ]]; then lvm_swap_off_if_needed "$dev" || return 1; fi
  if [[ -n $mp ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then info "[dry-run] umount $mp"; else umount "$mp" || { error "卸载 $mp 失败"; return 1; }; fi
  fi
  if [[ -n $uuid ]] && lvm_fstab_has_uuid "$uuid"; then lvm_rm_fstab_by_uuid "$uuid" || return 1; fi
  run lvremove -y "$dev" || return 1
  success "已删除逻辑卷 $dev"
}
lvm_delete_vg() {
  local vg=$1 lvs_list pvs_list l
  lvm_vg_exists "$vg" || { error "卷组 $vg 不存在"; return 1; }
  lvs_list=$(lvs --noheadings -o lv_name "$vg" 2>/dev/null | awk '{print $1}' || true)
  if [[ -n $lvs_list ]]; then
    warn "卷组 $vg 包含以下逻辑卷:"
    echo "$lvs_list" | sed 's/^/    - /'
    lvm_confirm "将删除卷组中所有逻辑卷及其数据，继续 ?" || return 1
    for l in $lvs_list; do lvm_delete_lv "$vg" "$l" || return 1; done
  fi
  pvs_list=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$vg" '$2==vg {print $1}' || true)
  lvm_confirm_danger "确认删除卷组 $vg ?" || return 1
  run vgremove -y "$vg" || return 1
  success "已删除卷组 $vg (PV: $pvs_list 仍保留为独立 PV)"
}
lvm_delete_pv() {
  local dev=$1 vgname
  [[ -b $dev ]] || { error "$dev 不是块设备"; return 1; }
  lvm_pv_exists "$dev" || { error "$dev 不是 PV"; return 1; }
  vgname=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | awk '{print $1}' || true)
  if [[ -n $vgname && $vgname != " " ]]; then
    warn "$dev 属于卷组 $vgname，将从卷组中移除"
    lvm_confirm_danger "确认将 $dev 从卷组 $vgname 移除 ?" || return 1
    if ! run vgreduce -y "$vgname" "$dev"; then
      error "移除失败: 若 PV 上仍有数据，请先 pvmove 迁移；若这是卷组最后一块盘，请先: $PROGRAM_NAME lvm delete -v $vgname"
      return 1
    fi
  fi
  lvm_confirm_danger "确认删除 PV $dev ?" || return 1
  run pvremove -y "$dev" || return 1
  success "已删除 PV $dev"
}
lvm_cmd_delete() {
  if [[ -n $LVM_LV ]]; then
    [[ -n $LVM_VG ]] || { error "删除 LV 需要 -v 指定卷组"; return 1; }
    lvm_valid_name "$LVM_VG" "卷组名" || return 1
    lvm_valid_name "$LVM_LV" "逻辑卷名" || return 1
    lvm_delete_lv "$LVM_VG" "$LVM_LV"
  elif [[ -n $LVM_DISK ]]; then
    lvm_delete_pv "$LVM_DISK"
  elif [[ -n $LVM_VG ]]; then
    lvm_valid_name "$LVM_VG" "卷组名" || return 1
    lvm_delete_vg "$LVM_VG"
  else
    error "delete 需要指定对象: -v 卷组 / -l 逻辑卷 / -d 磁盘"
    lvm_usage
    return 1
  fi
}
lvm_cmd_list() {
  local what=${1:-all}
  case $what in
    pvs) info "物理卷 (PV):"; pvs || true ;;
    vgs) info "卷组 (VG):"; vgs || true ;;
    lvs) info "逻辑卷 (LV):"; lvs || true ;;
    disk) info "磁盘视图:"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT || true ;;
    all)
      info "物理卷 (PV):"; pvs || true
      info "卷组 (VG):"; vgs || true
      info "逻辑卷 (LV):"; lvs || true
      info "磁盘视图:"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT || true ;;
    *) error "未知查询类型: $what (可选 pvs/vgs/lvs/disk/all)"; return 1 ;;
  esac
}
lvm_cmd_info() {
  [[ -n $LVM_DISK ]] || { error "info 需要 -d 指定设备"; lvm_usage; return 1; }
  [[ -b $LVM_DISK ]] || { error "$LVM_DISK 不是块设备"; return 1; }
  info "设备信息: $LVM_DISK"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$LVM_DISK" || true
  if lvm_pv_exists "$LVM_DISK"; then
    info "PV 状态:"; pvs "$LVM_DISK" || true
  else
    warn "$LVM_DISK 当前不是 PV (空盘可用于 create)"
  fi
}
lvm_print_brief_status() {
  local vgs_line lvs_line
  vgs_line=$(vgs --noheadings -o vg_name,vg_size,vg_free 2>/dev/null \
    | awk '{printf "%s(size %s, free %s)  ", $1,$2,$3}' || true)
  lvs_line=$(lvs --noheadings -o vg_name,lv_name,lv_size 2>/dev/null \
    | awk '{printf "%s/%s(%s)  ", $1,$2,$3}' || true)
  info "当前 VG: ${vgs_line:-无}"
  info "当前 LV: ${lvs_line:-无}"
}
lvm_parse_opts() {
  LVM_DISK=""; LVM_VG=""; LVM_LV=""; LVM_SIZE=""; LVM_FS=""; LVM_MOUNT=""
  LVM_POS=()
  LVM_FSTAB_BACKED_UP=0; LVM_PLANNED_VG=0; LVM_CREATED_PV=0; LVM_CREATED_VG=0; LVM_CREATED_LV=0; LVM_MOUNT_CONFIRMED=0
  local opt
  OPTIND=1
  while getopts ":d:v:l:s:f:m:ynh" opt; do
    case $opt in
      d) LVM_DISK=$OPTARG ;;
      v) LVM_VG=$OPTARG ;;
      l) LVM_LV=$OPTARG ;;
      s) LVM_SIZE=$OPTARG ;;
      f) LVM_FS=$OPTARG ;;
      m) LVM_MOUNT=$OPTARG ;;
      y) ASSUME_YES=1 ;;
      n) DRY_RUN=1 ;;
      h) lvm_usage; exit 0 ;;
      :) error "选项 -$OPTARG 缺少参数"; lvm_usage; return 1 ;;
      *) error "未知选项 -$OPTARG"; lvm_usage; return 1 ;;
    esac
  done
  shift $((OPTIND - 1))
  LVM_POS=("$@")
}
lvm_usage() { cat <<EOF
LVM 管理 (增 / 删 / 查 / 扩容) — 融合自 lvm-manager.sh

用法:
  $PROGRAM_NAME lvm create -d <磁盘> -v <卷组> -l <逻辑卷> -s <大小> -f <xfs|ext4> -m <挂载点>
  $PROGRAM_NAME lvm create-vg -d <磁盘> -v <卷组>          # 只建 PV + VG
  $PROGRAM_NAME lvm create-lv -v <卷组> -l <逻辑卷> -s <大小> -f <xfs|ext4> -m <挂载点>
  $PROGRAM_NAME lvm create-pv -d <磁盘>                   # 只建 PV
  $PROGRAM_NAME lvm extend -v <卷组> [-d <磁盘>] [-l <逻辑卷> -s <大小>]
  $PROGRAM_NAME lvm delete -v <卷组> [-l <逻辑卷>]        # 删 LV；只给 -v 则删整个 VG
  $PROGRAM_NAME lvm delete -d <磁盘>                      # 删 PV
  $PROGRAM_NAME lvm list [pvs|vgs|lvs|disk|all]           # 查询
  $PROGRAM_NAME lvm info -d <磁盘>                        # 查看单块磁盘
  $PROGRAM_NAME lvm sizes                                 # 大小格式说明

选项:
  -d <设备>      磁盘设备, 如 /dev/sdb
  -v <卷组>      卷组名, 如 vg_data
  -l <逻辑卷>    逻辑卷名, 如 lv_data
  -s <大小>      如 100G / +50G / 100%FREE / max(占满剩余空间)
  -f <文件系统>  xfs 或 ext4
  -m <挂载点>    如 /data
  -y, --yes      跳过所有确认 (危险操作请谨慎)
  -n, --dry-run  只打印将执行的操作，不改动系统

示例:
  $PROGRAM_NAME --dry-run lvm create -d /dev/sdb -v vg_data -l lv_data -s 100G -f xfs -m /data
  $PROGRAM_NAME lvm create-vg -d /dev/sdb -v vg_data
  $PROGRAM_NAME lvm create-lv -v vg_data -l lv_data -s 100G -f ext4 -m /data
  $PROGRAM_NAME lvm extend -v vg_data -d /dev/sdc
  $PROGRAM_NAME lvm extend -v vg_data -l lv_data -s +50G
  $PROGRAM_NAME lvm delete -v vg_data -l lv_data
  $PROGRAM_NAME lvm delete -v vg_data
  $PROGRAM_NAME lvm delete -d /dev/sdc
EOF
}
lvm_main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    ""|help|-h|--help) lvm_usage; return 0 ;;
    list|ls) lvm_parse_opts "$@"; lvm_cmd_list "${LVM_POS[0]:-all}" ;;
    info) lvm_parse_opts "$@"; lvm_cmd_info ;;
    install) ensure_lvm ;;
    sizes|size-help) lvm_size_help ;;
    create|create-vg|create-lv|create-pv|extend|delete|rm)
      lvm_parse_opts "$@"; lvm_check_deps || return 1
      case "$cmd" in
        create) lvm_cmd_create ;;
        create-vg) lvm_cmd_create_vg ;;
        create-lv) lvm_cmd_create_lv ;;
        create-pv) lvm_cmd_create_pv ;;
        extend) lvm_cmd_extend ;;
        delete|rm) lvm_cmd_delete ;;
      esac ;;
    *) error "未知 lvm 动作：${cmd}。支持：create/create-vg/create-lv/create-pv/extend/delete/list/info/sizes/install/help" ; lvm_usage; return 1 ;;
  esac
}
# ---- LVM 交互菜单 (菜单调用) ----
lvm_menu_create() {
  echo -n "磁盘设备 (如 /dev/sdb): "; read -r LVM_DISK
  echo -n "卷组名 (默认 vg_data): "; read -r LVM_VG; LVM_VG=${LVM_VG:-vg_data}
  echo -n "逻辑卷名 (默认 lv_data): "; read -r LVM_LV; LVM_LV=${LVM_LV:-lv_data}
  echo "大小可选: 100G / 500M / 100%FREE / max (输入 ? 查看全部格式)"
  echo -n "逻辑卷大小 (如 100G, 100%FREE, max): "; read -r LVM_SIZE
  if [[ $LVM_SIZE == "?" ]]; then lvm_size_help; echo -n "逻辑卷大小: "; read -r LVM_SIZE; fi
  echo -n "文件系统 (xfs/ext4, 默认 xfs): "; read -r LVM_FS; LVM_FS=${LVM_FS:-xfs}
  echo -n "挂载点 (如 /data): "; read -r LVM_MOUNT
  lvm_check_deps || return 1
  lvm_cmd_create
}
lvm_menu_create_vg() {
  echo -n "磁盘设备 (如 /dev/sdb): "; read -r LVM_DISK
  echo -n "卷组名 (默认 vg_data): "; read -r LVM_VG; LVM_VG=${LVM_VG:-vg_data}
  lvm_check_deps || return 1
  lvm_cmd_create_vg
}
lvm_menu_create_lv() {
  echo -n "卷组名: "; read -r LVM_VG
  echo -n "逻辑卷名 (默认 lv_data): "; read -r LVM_LV; LVM_LV=${LVM_LV:-lv_data}
  echo "大小可选: 100G / 500M / 100%FREE / max (输入 ? 查看全部格式)"
  echo -n "逻辑卷大小: "; read -r LVM_SIZE
  if [[ $LVM_SIZE == "?" ]]; then lvm_size_help; echo -n "逻辑卷大小: "; read -r LVM_SIZE; fi
  echo -n "文件系统 (xfs/ext4, 默认 xfs): "; read -r LVM_FS; LVM_FS=${LVM_FS:-xfs}
  echo -n "挂载点 (如 /data): "; read -r LVM_MOUNT
  lvm_check_deps || return 1
  lvm_cmd_create_lv
}
lvm_menu_extend() {
  lvm_print_brief_status
  echo -n "卷组名 (如 vg_data): "; read -r LVM_VG
  echo -n "要加入的磁盘 (如 /dev/sdc, 留空跳过): "; read -r LVM_DISK
  echo -n "要扩容的 LV 名 (如 lv_data, 留空跳过): "; read -r LVM_LV
  if [[ -n $LVM_LV ]]; then
    echo "大小可选: +50G / 100%FREE / max / 100G (输入 ? 查看全部格式)"
    echo -n "扩容大小 (如 +50G, 100%FREE, max): "; read -r LVM_SIZE
    if [[ $LVM_SIZE == "?" ]]; then lvm_size_help; echo -n "扩容大小: "; read -r LVM_SIZE; fi
  fi
  lvm_check_deps || return 1
  lvm_cmd_extend
}
lvm_menu_delete() {
  local t
  lvm_print_brief_status
  echo "  1) 删除逻辑卷 LV"
  echo "  2) 删除卷组 VG (含其中所有 LV)"
  echo "  3) 删除物理卷 PV"
  echo -n "选择: "; read -r t
  case $t in
    1) echo -n "卷组名: "; read -r LVM_VG; echo -n "逻辑卷名: "; read -r LVM_LV; lvm_cmd_delete ;;
    2) echo -n "卷组名: "; read -r LVM_VG; lvm_cmd_delete ;;
    3) echo -n "磁盘设备 (如 /dev/sdc): "; read -r LVM_DISK; lvm_cmd_delete ;;
    *) warn "无效选择" ;;
  esac
}
lvm_menu_list() {
  echo "  可选: pvs=物理卷  vgs=卷组  lvs=逻辑卷  disk=磁盘  all=全部"
  echo -n "选择 (默认 all): "; read -r w
  lvm_cmd_list "${w:-all}"
}
lvm_menu_info() {
  echo -n "磁盘设备 (如 /dev/sdb): "; read -r LVM_DISK
  lvm_cmd_info
}
ensure_perf_tools() { is_macos && { has_cmd htop || brew_install htop || true; return 0; }; case "$PKG_MANAGER" in apt) pkg_install sysstat htop lsof iotop iftop nload iproute2 procps ;; dnf|yum) pkg_install sysstat htop lsof iotop iftop nload iproute procps-ng ;; pacman) pkg_install sysstat htop lsof iotop iftop nload iproute2 procps-ng ;; *) warn "无法自动安装性能工具。" ;; esac; }
perf_quick() { ensure_perf_tools; echo "========== 系统信息 =========="; print_env; echo; echo "========== 负载 =========="; uptime || true; echo; echo "========== 内存 =========="; free -h 2>/dev/null || vm_stat 2>/dev/null || true; echo; echo "========== 磁盘 =========="; df -hT 2>/dev/null || df -h || true; echo; echo "========== 网络 =========="; has_cmd ss && ss -s || netstat -ib 2>/dev/null | head -n 20 || true; echo; echo "========== Top 进程 =========="; ps aux --sort=-%cpu 2>/dev/null | head -n 10 || ps aux | head -n 10 || true; }

# ---------- 服务管理 ----------
svc_list() { ensure_linux_only "macOS 使用 launchctl 管理服务。"; has_cmd systemctl && run systemctl list-units --type=service --state=running || warn "未检测到 systemctl。"; }
svc_status() { ensure_linux_only "macOS 使用 launchctl 管理服务。"; local svc="${1:-}"; [[ -n "$svc" ]] || read -r -p "服务名: " svc; has_cmd systemctl && run systemctl status "$svc" || warn "未检测到 systemctl。"; }
svc_restart() { ensure_linux_only "macOS 使用 launchctl 管理服务。"; local svc="${1:-}"; [[ -n "$svc" ]] || read -r -p "服务名: " svc; confirm "即将重启服务 ${svc}。是否继续？" || cancelled; has_cmd systemctl && run systemctl restart "$svc" || warn "未检测到 systemctl。"; }
svc_enable() { ensure_linux_only "macOS 使用 launchctl 管理服务。"; local svc="${1:-}"; [[ -n "$svc" ]] || read -r -p "服务名: " svc; has_cmd systemctl && run systemctl enable "$svc" || warn "未检测到 systemctl。"; }
svc_disable() { ensure_linux_only "macOS 使用 launchctl 管理服务。"; local svc="${1:-}"; [[ -n "$svc" ]] || read -r -p "服务名: " svc; confirm "即将禁用服务 ${svc}。是否继续？" || cancelled; has_cmd systemctl && run systemctl disable --now "$svc" || warn "未检测到 systemctl。"; }
svc_logs() { ensure_linux_only "macOS 使用 log 命令查看日志。"; local svc="${1:-}" lines="${2:-50}"; [[ -n "$svc" ]] || read -r -p "服务名: " svc; has_cmd journalctl && run journalctl -u "$svc" -n "$lines" --no-pager || warn "未检测到 journalctl。"; }

# ---------- 磁盘清理 ----------
disk_cleanup_journal() { ensure_linux_only "macOS 日志由系统自动管理。"; local days="${1:-7}"; confirm "即将清理 ${days} 天前的 systemd journal 日志。是否继续？" || cancelled; has_cmd journalctl && { run journalctl --vacuum-time="${days}d"; success "Journal 日志清理完成。"; } || warn "未检测到 journalctl。"; }
disk_cleanup_old_kernels() { ensure_linux_only "macOS 内核由系统更新管理。"; confirm "即将清理旧内核。是否继续？" || cancelled; case "$PKG_MANAGER" in apt) run apt-get autoremove --purge -y ;; dnf|yum) run dnf remove -y "$(rpm -q kernel | grep -v "$(uname -r)" 2>/dev/null || true)" 2>/dev/null || warn "未找到需清理的旧内核。";; pacman) run pacman -Rns "$(pacman -Qdtq 2>/dev/null || true)" 2>/dev/null || true ;; *) warn "未检测到支持的包管理器。";; esac; success "旧内核清理完成。"; }
disk_cleanup_packages() { confirm "即将清理包管理器缓存。是否继续？" || cancelled; case "$PKG_MANAGER" in apt) run apt-get clean; run apt-get autoclean ;; dnf|yum) run dnf clean all 2>/dev/null || run yum clean all ;; pacman) run pacman -Scc --noconfirm 2>/dev/null || run pacman -Sc --noconfirm ;; brew) brew_run cleanup -s ;; *) warn "未检测到支持的包管理器。";; esac; success "包缓存清理完成。"; }
disk_cleanup_docker() { has_cmd docker || fatal "未检测到 docker 命令。"; confirm "即将清理 Docker 未使用的镜像/容器/卷/网络。是否继续？" || cancelled; run docker system prune -af --volumes 2>/dev/null || run docker system prune -af; success "Docker 清理完成。"; }
disk_cleanup_summary() { echo "========== 磁盘使用概况 =========="; df -hT 2>/dev/null || df -h; echo; echo "========== 大目录 Top 10 =========="; has_cmd du && du -h --max-depth=3 / 2>/dev/null | sort -rh | head -10 || du -h -d 2 / 2>/dev/null | sort -rh | head -10 2>/dev/null || warn "无法扫描磁盘使用。"; }

# ---------- SSL 证书检查 ----------
ssl_check() { local host="${1:-}" port="${2:-443}"; [[ -n "$host" ]] || read -r -p "域名: " host; [[ -n "$host" ]] || cancelled; info "检查 SSL 证书：${host}:${port}"; echo | openssl s_client -servername "$host" -connect "${host}:${port}" 2>/dev/null | openssl x509 -noout -dates -subject -issuer 2>/dev/null || { has_cmd curl && curl -svI "https://${host}" 2>&1 | grep -E 'expire|subject|issuer|SSL' || true; }; }
ssl_check_batch() { local file="${1:-}" host port; [[ -n "$file" ]] || { echo "输入包含域名列表的文件（每行一个域名或 host:port）："; read -r file; }; [[ -f "$file" ]] || fatal "文件不存在：$file"; while IFS= read -r line; do [[ -z "$line" || "$line" == \#* ]] && continue; host="${line%%:*}"; port="${line##*:}"; [[ "$port" == "$host" ]] && port=443; printf '%-40s ' "$host"; echo | openssl s_client -servername "$host" -connect "${host}:${port}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=/到期: /' || echo "✗ 连接失败"; done < "$file"; }

# ---------- 系统更新 ----------
system_update_check() { case "$PKG_MANAGER" in apt) run apt-get update; run apt list --upgradable 2>/dev/null | head -30 ;; dnf) run dnf check-update 2>/dev/null | head -30 || true ;; yum) run yum check-update 2>/dev/null | head -30 || true ;; pacman) run pacman -Sy; run pacman -Qu 2>/dev/null | head -30 ;; brew) brew_run update; brew_run outdated ;; *) warn "未检测到支持的包管理器。";; esac; }
system_update_security() { ensure_linux_only "macOS 安全更新通过系统偏好设置安装。"; confirm "即将安装安全更新。是否继续？" || cancelled; case "$PKG_MANAGER" in apt) run apt-get update; run unattended-upgrade -d 2>/dev/null || run apt-get upgrade -y; success "安全更新完成。";; dnf) run dnf update --security -y 2>/dev/null || run dnf update-minimal --security -y 2>/dev/null || warn "dnf 安全更新不可用，请使用 system-update all。";; yum) run yum update --security -y 2>/dev/null || warn "yum 安全更新不可用，请使用 system-update all。";; *) warn "未检测到支持的包管理器。";; esac; }
system_update_all() { confirm "即将更新所有系统软件包。是否继续？" || cancelled; case "$PKG_MANAGER" in apt) run apt-get update; run apt-get upgrade -y; run apt-get dist-upgrade -y 2>/dev/null || true; success "系统更新完成。";; dnf|yum) run dnf update -y 2>/dev/null || run yum update -y; success "系统更新完成。";; pacman) run pacman -Syu --noconfirm; success "系统更新完成。";; brew) brew_run update; brew_run upgrade; success "Homebrew 更新完成。";; *) warn "未检测到支持的包管理器。";; esac; }

# ---------- 新模块公共辅助 ----------
valid_linux_user() { local u="${1:-}"; [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ || "$u" =~ ^[a-z_][a-z0-9_-]{0,30}[$]$ ]]; }
valid_hostname_label() { local h="${1:-}"; [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
valid_hostname() {
  local h="${1:-}" part IFS
  local -a parts=()
  [[ -n "$h" && ${#h} -le 253 ]] || return 1
  [[ "$h" != *..* ]] || return 1
  IFS='.'; read -ra parts <<< "$h"
  for part in "${parts[@]}"; do valid_hostname_label "$part" || return 1; done
  return 0
}
valid_host_or_ip() { [[ "${1:-}" =~ ^[A-Za-z0-9._:-]+$ ]]; }
valid_port() { [[ "${1:-}" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]; }
require_valid_user() { valid_linux_user "${1:-}" || fatal "非法用户名：${1:-}"; }
cpu_count() { local n; n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf 1)"; printf '%s' "${n:-1}"; }
section() { echo; echo "========== $* =========="; }
need_arg() { local name="$1" val="${2:-}" prompt="$3"; if [[ -z "$val" ]]; then read -r -p "$prompt" val || true; fi; printf '%s' "$val"; }

# ---------- 主机巡检 health ----------
HEALTH_OK=0; HEALTH_WARN=0; HEALTH_CRIT=0; HEALTH_ITEMS=()
health_reset() { HEALTH_OK=0; HEALTH_WARN=0; HEALTH_CRIT=0; HEALTH_ITEMS=(); }
health_item() {
  local level="$1" msg="$2"
  case "$level" in
    OK) HEALTH_OK=$((HEALTH_OK + 1)); printf '  [OK]   %s\n' "$msg" ;;
    WARN) HEALTH_WARN=$((HEALTH_WARN + 1)); printf '  [WARN] %s\n' "$msg" ;;
    CRIT) HEALTH_CRIT=$((HEALTH_CRIT + 1)); printf '  [CRIT] %s\n' "$msg" ;;
  esac
  HEALTH_ITEMS+=("$level|$msg")
}
health_check_load() {
  local load1 cpus
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || uptime | awk -F'load average[s]?: ' '{print $2}' | awk -F, '{print $1}' | tr -d ' ')"
  cpus="$(cpu_count)"
  local load_rc=0
  awk -v l="${load1:-0}" -v c="${cpus:-1}" 'BEGIN{
    if (c<=0) c=1;
    if (l >= c*2) exit 2;
    if (l >= c) exit 1;
    exit 0;
  }' || load_rc=$?
  case "$load_rc" in
    2) health_item CRIT "1 分钟负载 ${load1}，CPU ${cpus} 核（>= 2x）" ;;
    1) health_item WARN "1 分钟负载 ${load1}，CPU ${cpus} 核（>= 1x）" ;;
    *) health_item OK "1 分钟负载 ${load1}，CPU ${cpus} 核" ;;
  esac
}
health_check_memory() {
  if is_macos; then
    health_item OK "macOS 内存由系统统一管理（vm_stat 仅供参考）"
    vm_stat 2>/dev/null | head -n 8 || true
    return 0
  fi
  local avail_kb total_kb avail_pct swap_total swap_used swap_pct
  avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || printf 0)"
  total_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || printf 1)"
  swap_total="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || printf 0)"
  swap_used="$(awk '/SwapTotal:/ {t=$2} /SwapFree:/ {f=$2} END{print t-f}' /proc/meminfo 2>/dev/null || printf 0)"
  avail_pct="$(awk -v a="$avail_kb" -v t="$total_kb" 'BEGIN{ if(t<=0) t=1; printf "%.0f", a*100/t }')"
  avail_pct="${avail_pct:-100}"
  if [[ "$avail_pct" -le 5 ]]; then health_item CRIT "可用内存约 ${avail_pct}%（MemAvailable）"
  elif [[ "$avail_pct" -le 10 ]]; then health_item WARN "可用内存约 ${avail_pct}%（MemAvailable）"
  else health_item OK "可用内存约 ${avail_pct}%（MemAvailable）"; fi
  if [[ "${swap_total:-0}" -gt 0 ]]; then
    swap_pct="$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{ printf "%.0f", u*100/t }')"
    swap_pct="${swap_pct:-0}"
    if [[ "$swap_pct" -ge 80 ]]; then health_item WARN "Swap 使用 ${swap_pct}%"
    else health_item OK "Swap 使用 ${swap_pct}%"; fi
  else
    health_item OK "未配置 Swap"
  fi
}
health_check_disks() {
  local line usep ipct mp src
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    src="$(awk '{print $1}' <<< "$line")"
    mp="$(awk '{print $6}' <<< "$line")"
    usep="$(awk '{print $5}' <<< "$line" | tr -d '%')"
    [[ "$usep" =~ ^[0-9]+$ ]] || continue
    case "$src" in none|rootfs|drivers|overlay|tmpfs|devtmpfs) continue ;; esac
    case "$mp" in /init|/usr/lib/wsl/*|/mnt/wsl*|/mnt/wslg*) continue ;; esac
    if [[ "$usep" -ge 95 ]]; then health_item CRIT "磁盘 ${mp} 使用 ${usep}%（${src}）"
    elif [[ "$usep" -ge 85 ]]; then health_item WARN "磁盘 ${mp} 使用 ${usep}%（${src}）"
    else health_item OK "磁盘 ${mp} 使用 ${usep}%"; fi
  done < <(
    if df -P -x tmpfs >/dev/null 2>&1; then df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print}'
    else df -P 2>/dev/null | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs|overlay|map)$/ {print}'
    fi
  )
  if is_linux; then
    while IFS= read -r line; do
      mp="$(awk '{print $6}' <<< "$line")"
      ipct="$(awk '{print $5}' <<< "$line" | tr -d '%')"
      [[ "$ipct" =~ ^[0-9]+$ ]] || continue
      case "$mp" in /init|/mnt/wsl*|/usr/lib/wsl/*) continue ;; esac
      if [[ "$ipct" -ge 95 ]]; then health_item CRIT "inode ${mp} 使用 ${ipct}%"
      elif [[ "$ipct" -ge 85 ]]; then health_item WARN "inode ${mp} 使用 ${ipct}%"
      else health_item OK "inode ${mp} 使用 ${ipct}%"; fi
    done < <(df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print}' || true)
    local ro_fstype ro_mp
    while IFS= read -r line; do
      ro_fstype="$(awk '{print $3}' <<< "$line")"
      ro_mp="$(awk '{print $2}' <<< "$line")"
      [[ -n "$ro_mp" ]] || continue
      case "$ro_fstype" in proc|sysfs|devtmpfs|devpts|cgroup*|pstore|bpf|tracefs|debugfs|securityfs|fusectl|mqueue|hugetlbfs|overlay|squashfs|9p|autofs|rpc_pipefs|nsfs|binfmt_misc) continue ;; esac
      case "$ro_mp" in /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/snap|/snap/*|/tmp/.X11-unix|/mnt/wsl*|/usr/lib/wsl/*|/init|/usr/lib/modules/*) continue ;; esac
      health_item WARN "只读挂载：$ro_mp（$ro_fstype）"
    done < <(awk '$4 ~ /(^|,)ro($|,)/ {print}' /proc/mounts 2>/dev/null || true)
  fi
}
health_check_processes() {
  local zombies dstate oom
  zombies="$(ps -eo stat= 2>/dev/null | awk '$1 ~ /Z/ {c++} END{print c+0}')"
  dstate="$(ps -eo stat= 2>/dev/null | awk '$1 ~ /^D/ {c++} END{print c+0}')"
  zombies="${zombies:-0}"; dstate="${dstate:-0}"
  [[ "$zombies" -gt 0 ]] && health_item WARN "僵尸进程 ${zombies} 个" || health_item OK "无僵尸进程"
  [[ "$dstate" -gt 0 ]] && health_item WARN "不可中断睡眠(D) 进程 ${dstate} 个" || health_item OK "无 D 状态进程"
  if is_linux && has_cmd journalctl; then
    oom="$(journalctl -k --since '24 hours ago' --no-pager 2>/dev/null | grep -c -E 'Out of memory|Killed process' || true)"
    [[ "${oom:-0}" -gt 0 ]] && health_item CRIT "近 24 小时内核日志出现 ${oom} 条 OOM/杀进程记录" || health_item OK "近 24 小时未见 OOM"
  elif is_linux && [[ -r /var/log/kern.log ]]; then
    oom="$(grep -c -E 'Out of memory|Killed process' /var/log/kern.log 2>/dev/null || true)"
    [[ "${oom:-0}" -gt 0 ]] && health_item WARN "kern.log 中有 ${oom} 条历史 OOM 记录" || health_item OK "kern.log 未见 OOM"
  fi
}
health_check_services() {
  is_linux || return 0
  if has_cmd systemctl; then
    local failed n
    failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}' || true)"
    n="$(printf '%s\n' "$failed" | awk 'NF{c++} END{print c+0}')"
    if [[ "$n" -gt 0 ]]; then health_item WARN "失败的 systemd 单元 ${n} 个：$(printf '%s' "$failed" | tr '\n' ' ')"
    else health_item OK "无失败的 systemd 单元"; fi
  fi
}
health_check_time() {
  local synced="unknown"
  if has_cmd timedatectl; then
    timedatectl status 2>/dev/null | grep -E 'NTP|System clock|Time zone|synchronized' || true
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then synced=yes
    elif timedatectl status 2>/dev/null | grep -qi 'synchronized: yes'; then synced=yes
    else synced=no; fi
  elif has_cmd chronyc; then
    chronyc tracking 2>/dev/null | head -n 5 || true
    chronyc tracking 2>/dev/null | grep -qi 'Leap status.*Normal' && synced=yes || synced=no
  fi
  case "$synced" in
    yes) health_item OK "时间已同步" ;;
    no) health_item WARN "时间可能未同步" ;;
    *) health_item WARN "无法确认时间同步状态" ;;
  esac
}
health_check_network() {
  local gw iface state
  if is_linux; then
    gw="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
    [[ -n "$gw" ]] && health_item OK "默认网关 ${gw}" || health_item CRIT "无默认路由"
    while IFS= read -r iface; do
      [[ -n "$iface" && -r "/sys/class/net/$iface/operstate" ]] || continue
      state="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || true)"
      case "$iface" in lo|docker*|br-*|veth*|cni*|flannel*|virbr*) continue ;; esac
      [[ "$state" == "down" ]] && health_item WARN "网卡 ${iface} 状态 down"
    done < <(ls /sys/class/net 2>/dev/null || true)
  else
    netstat -rn 2>/dev/null | head -n 8 || true
    health_item OK "macOS 路由表已列出（请人工确认默认网关）"
  fi
  if has_cmd getent && getent hosts one.one.one.one >/dev/null 2>&1; then health_item OK "DNS 可解析外部域名"
  elif has_cmd nslookup && nslookup one.one.one.one >/dev/null 2>&1; then health_item OK "DNS 可解析外部域名"
  else health_item WARN "外部 DNS 解析失败或网络隔离"; fi
}
health_run_checks() {
  health_reset
  section "系统"
  print_env
  echo "主机名：$(hostname 2>/dev/null || true)"
  echo "时间：$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || true)"
  echo "运行时间：$(uptime -p 2>/dev/null || uptime || true)"
  section "巡检项"
  health_check_load
  health_check_memory
  health_check_disks
  health_check_processes
  health_check_services
  health_check_time
  health_check_network
  section "摘要"
  echo "正常 ${HEALTH_OK}    警告 ${HEALTH_WARN}    严重 ${HEALTH_CRIT}"
  if [[ "$HEALTH_CRIT" -gt 0 ]]; then error "存在严重项，请优先处理。"; return 2
  elif [[ "$HEALTH_WARN" -gt 0 ]]; then warn "存在警告项。"; return 1
  else success "巡检未发现明显异常。"; return 0; fi
}
health_check() { local rc=0; health_run_checks || rc=$?; [[ "$rc" -eq 0 || "$rc" -eq 1 || "$rc" -eq 2 ]] && return 0; return "$rc"; }
health_report() {
  local out="${1:-}" ts file rc=0
  ts="$(date +%Y%m%d-%H%M%S)"
  if [[ -z "$out" ]]; then
    if [[ -t 0 ]]; then read -r -p "报告输出路径 [/tmp/health-${ts}.txt]: " out || true; fi
    out="${out:-/tmp/health-${ts}.txt}"
  fi
  [[ "$out" != *..* ]] || fatal "非法输出路径：$out"
  info "生成巡检报告：$out"
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ write health report $out"; health_run_checks || true; return 0; fi
  mkdir -p "$(dirname "$out")"
  set +e
  health_run_checks > "$out" 2>&1
  rc=$?
  set -e
  cat "$out"
  success "报告已保存：$out"
  return 0
}

# ---------- 用户与 SSH user / ssh-harden ----------
user_home_of() { getent passwd "${1:-}" 2>/dev/null | awk -F: '{print $6}'; }
user_exists() { getent passwd "${1:-}" >/dev/null 2>&1; }
user_list() {
  section "登录用户 / 可交互用户"
  if is_macos; then dscl . -list /Users 2>/dev/null | head -n 50 || true; else
    awk -F: '($3>=1000 && $1!="nobody") || $1=="root" {printf "%-16s uid=%-6s gid=%-6s home=%-20s shell=%s\n",$1,$3,$4,$6,$7}' /etc/passwd
  fi
  section "sudo / wheel / admin 组成员"
  for g in sudo wheel admin; do
    if getent group "$g" >/dev/null 2>&1; then echo "$g: $(getent group "$g" | awk -F: '{print $4}')"; fi
  done
  section "锁定 / 空密码检查"
  if is_linux && [[ -r /etc/shadow ]]; then
    awk -F: '($2=="" || $2=="!" || $2=="*" || $2 ~ /^!/) {printf "%-16s hash=%s\n",$1,($2==""?"EMPTY":$2)}' /etc/shadow | head -n 40
    if awk -F: '$2=="" {found=1} END{exit !found}' /etc/shadow; then warn "存在空密码账号，请立即处理。"; fi
  else
    warn "无法读取 shadow，跳过空密码检查。"
  fi
  section "UID 0 账号"
  awk -F: '$3==0 {print $1}' /etc/passwd 2>/dev/null || true
}
user_info() {
  local u="${1:-}"
  [[ -n "$u" ]] || u="$(need_arg user "" "用户名: ")"
  [[ -n "$u" ]] || cancelled
  require_valid_user "$u"
  user_exists "$u" || fatal "用户不存在：$u"
  getent passwd "$u" || true
  id "$u" || true
  if is_linux && [[ -r /etc/shadow ]]; then
    awk -F: -v u="$u" '$1==u {printf "shadow: lastchg=%s min=%s max=%s warn=%s expire=%s\n",$3,$4,$5,$6,$8}' /etc/shadow
  fi
  echo "authorized_keys:"
  local home keys; home="$(user_home_of "$u")"; keys="$home/.ssh/authorized_keys"
  if [[ -f "$keys" ]]; then awk '{print NR, $1, $NF}' "$keys"; else echo "(无)"; fi
}
user_add() {
  ensure_linux_only "macOS 用户请用 dscl / 系统设置创建。"
  local u="${1:-}" groups="${2:-}" shell="${3:-/bin/bash}" create_home="${4:-1}"
  [[ -n "$u" ]] || u="$(need_arg user "" "新用户名: ")"
  [[ -n "$u" ]] || cancelled
  require_valid_user "$u"
  user_exists "$u" && fatal "用户已存在：$u"
  [[ -n "$groups" ]] || { read -r -p "附加组（逗号分隔，可空）: " groups || true; }
  [[ -n "${3:-}" ]] || { read -r -p "登录 Shell [$shell]: " _s || true; shell="${_s:-$shell}"; }
  [[ "$shell" =~ ^/[A-Za-z0-9/._+-]+$ ]] || fatal "非法 Shell 路径：$shell"
  confirm "即将创建用户 ${u}，组=${groups:-无}，shell=${shell}。是否继续？" || cancelled
  local args=("$u" -s "$shell")
  [[ "$create_home" == 1 ]] && args+=(-m)
  if [[ -n "$groups" ]]; then
    [[ "$groups" =~ ^[A-Za-z0-9_,-]+$ ]] || fatal "非法用户组列表：$groups"
    args+=(-G "$groups")
  fi
  if has_cmd useradd; then run useradd "${args[@]}"
  else fatal "未找到 useradd。"; fi
  success "用户 ${u} 已创建。请用 passwd ${u} 设置密码，或 user key-add 写入公钥。"
}
user_lock() {
  ensure_linux_only "macOS 不支持此 Linux 账户锁定操作。"
  local u="${1:-}"
  [[ -n "$u" ]] || u="$(need_arg user "" "要锁定的用户: ")"
  require_valid_user "$u"; user_exists "$u" || fatal "用户不存在：$u"
  [[ "$u" != root ]] || fatal "拒绝锁定 root。"
  confirm "即将锁定用户 ${u}（禁止登录）。是否继续？" || cancelled
  has_cmd usermod && run usermod -L "$u" || run passwd -l "$u"
  success "用户 ${u} 已锁定。"
}
user_unlock() {
  ensure_linux_only "macOS 不支持此 Linux 账户解锁操作。"
  local u="${1:-}"
  [[ -n "$u" ]] || u="$(need_arg user "" "要解锁的用户: ")"
  require_valid_user "$u"; user_exists "$u" || fatal "用户不存在：$u"
  confirm "即将解锁用户 ${u}。是否继续？" || cancelled
  has_cmd usermod && run usermod -U "$u" || run passwd -u "$u"
  success "用户 ${u} 已解锁。"
}
user_expire() {
  ensure_linux_only "macOS 不支持此 Linux 账户过期操作。"
  local u="${1:-}" day="${2:-}"
  [[ -n "$u" ]] || u="$(need_arg user "" "用户名: ")"
  require_valid_user "$u"; user_exists "$u" || fatal "用户不存在：$u"
  [[ -n "$day" ]] || { read -r -p "过期日期 YYYY-MM-DD（空=立即过期）: " day || true; }
  confirm "即将设置用户 ${u} 过期日期为 ${day:-立即}。是否继续？" || cancelled
  if [[ -n "$day" ]]; then
    [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fatal "日期格式应为 YYYY-MM-DD"
    run chage -E "$day" "$u"
  else
    run chage -E 0 "$u"
  fi
  success "用户 ${u} 过期设置已更新。"
}
user_sudo_add() {
  ensure_linux_only "macOS 请把用户加入 admin 组。"
  local u="${1:-}" file
  [[ -n "$u" ]] || u="$(need_arg user "" "授予 sudo 的用户: ")"
  require_valid_user "$u"; user_exists "$u" || fatal "用户不存在：$u"
  confirm "即将授予 ${u} 免密 sudo（写入 sudoers.d）。是否继续？" || cancelled
  run mkdir -p /etc/sudoers.d
  file="/etc/sudoers.d/99-toolkit-${u}"
  [[ "$file" =~ ^/etc/sudoers.d/99-toolkit-[a-z_][a-z0-9_-]*$ ]] || fatal "sudoers 路径非法"
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ write $file"; else
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" > "$file"
    chmod 440 "$file"
    visudo -cf "$file" >/dev/null || { rm -f "$file"; fatal "sudoers 语法校验失败，已撤回。"; }
  fi
  success "已授予 ${u} sudo。"
}
user_sudo_del() {
  ensure_linux_only "macOS 请从 admin 组移除用户。"
  local u="${1:-}" file
  [[ -n "$u" ]] || u="$(need_arg user "" "取消 sudo 的用户: ")"
  require_valid_user "$u"
  file="/etc/sudoers.d/99-toolkit-${u}"
  confirm "即将删除 ${file}。是否继续？" || cancelled
  [[ -f "$file" ]] && run rm -f "$file" || warn "文件不存在：$file"
  success "已尝试移除 ${u} 的 toolkit sudo 授权。"
}
user_keys() {
  local u="${1:-}" home keys
  [[ -n "$u" ]] || u="$(need_arg user "" "用户名: ")"
  require_valid_user "$u"; user_exists "$u" || fatal "用户不存在：$u"
  home="$(user_home_of "$u")"; keys="$home/.ssh/authorized_keys"
  [[ -f "$keys" ]] || { warn "无 authorized_keys：$keys"; return 0; }
  awk '{printf "%2d  %s  %s\n", NR, $1, $NF}' "$keys"
}
user_key_add() {
  local u="${1:-}" key="${2:-}" home sshdir keys line
  [[ -n "$u" ]] || u="$(need_arg user "" "用户名: ")"
  require_valid_user "$u"; user_exists "$u" || fatal "用户不存在：$u"
  [[ -n "$key" ]] || { echo "输入公钥内容，或公钥文件路径："; read -r key; }
  [[ -n "$key" ]] || cancelled
  if [[ -f "$key" ]]; then line="$(tr -d '\r' < "$key" | awk 'NF && $1 !~ /^#/{print; exit}')"
  else line="$key"; fi
  [[ "$line" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)\  ]] || fatal "不像是合法 SSH 公钥。"
  home="$(user_home_of "$u")"; sshdir="$home/.ssh"; keys="$sshdir/authorized_keys"
  confirm "即将把公钥写入 ${keys}。是否继续？" || cancelled
  run mkdir -p "$sshdir"
  run chmod 700 "$sshdir"
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ append key to $keys"; else
    touch "$keys"
    grep -qxF "$line" "$keys" 2>/dev/null || printf '%s\n' "$line" >> "$keys"
    chmod 600 "$keys"
    chown -R "$u:$(id -gn "$u")" "$sshdir" 2>/dev/null || true
  fi
  success "公钥已写入 ${u}。"
}
user_key_del() {
  local u="${1:-}" pat="${2:-}" home keys tmp
  [[ -n "$u" ]] || u="$(need_arg user "" "用户名: ")"
  require_valid_user "$u"; user_exists "$u" || fatal "用户不存在：$u"
  home="$(user_home_of "$u")"; keys="$home/.ssh/authorized_keys"
  [[ -f "$keys" ]] || fatal "无 authorized_keys"
  user_keys "$u"
  [[ -n "$pat" ]] || { read -r -p "要删除的行号或注释/指纹关键词: " pat; }
  [[ -n "$pat" ]] || cancelled
  confirm "即将从 ${keys} 删除匹配 ${pat} 的行。是否继续？" || cancelled
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ delete matching key from $keys"; return 0; fi
  tmp="$(mktemp)"
  if [[ "$pat" =~ ^[0-9]+$ ]]; then awk -v n="$pat" 'NR!=n' "$keys" > "$tmp"
  else grep -vF "$pat" "$keys" > "$tmp" || true; fi
  cat "$tmp" > "$keys"; rm -f "$tmp"; chmod 600 "$keys"
  success "已更新 ${keys}。"
}
ssh_config_path() { if [[ -f /etc/ssh/sshd_config ]]; then printf /etc/ssh/sshd_config; elif [[ -f /etc/sshd_config ]]; then printf /etc/sshd_config; else printf /etc/ssh/sshd_config; fi; }
ssh_get_cfg() {
  local key="$1" file; file="$(ssh_config_path)"
  [[ -f "$file" ]] || { printf 'unset'; return 0; }
  awk -v k="$key" 'BEGIN{IGNORECASE=1} $1 !~ /^#/ && $1==k {print $2; found=1} END{if(!found) print "unset"}' "$file" | tail -n1
}
ssh_harden_audit() {
  local file; file="$(ssh_config_path)"
  section "SSH 配置审计：${file}"
  [[ -f "$file" ]] || { warn "未找到 sshd_config"; return 0; }
  local port rootlogin passauth empty allowu maxtry x11
  port="$(ssh_get_cfg Port)"; rootlogin="$(ssh_get_cfg PermitRootLogin)"
  passauth="$(ssh_get_cfg PasswordAuthentication)"; empty="$(ssh_get_cfg PermitEmptyPasswords)"
  allowu="$(ssh_get_cfg AllowUsers)"; maxtry="$(ssh_get_cfg MaxAuthTries)"; x11="$(ssh_get_cfg X11Forwarding)"
  printf '%-28s %s\n' Port "$port"
  printf '%-28s %s\n' PermitRootLogin "$rootlogin"
  printf '%-28s %s\n' PasswordAuthentication "$passauth"
  printf '%-28s %s\n' PermitEmptyPasswords "$empty"
  printf '%-28s %s\n' AllowUsers "$allowu"
  printf '%-28s %s\n' MaxAuthTries "$maxtry"
  printf '%-28s %s\n' X11Forwarding "$x11"
  echo
  [[ "$empty" == yes ]] && warn "允许空密码登录" || info "空密码：${empty}"
  [[ "$rootlogin" == yes ]] && warn "允许 root 密码/登录：PermitRootLogin yes"
  [[ "$passauth" == yes || "$passauth" == unset ]] && warn "密码登录可能仍开启"
  [[ "$maxtry" == unset || ( "$maxtry" =~ ^[0-9]+$ && "$maxtry" -gt 6 ) ]] && warn "MaxAuthTries 偏大或未设置"
  if has_cmd sshd; then
    local sshd_err
    sshd_err="$(sshd -t 2>&1 || true)"
    if [[ -z "$sshd_err" ]]; then success "sshd_config 语法正常"
    elif printf '%s' "$sshd_err" | grep -qi 'no hostkeys'; then warn "sshd 未配置 host key（配置语法仍可能正常）"
    else error "sshd -t：${sshd_err}"; fi
  fi
  section "最近失败登录"
  if has_cmd lastb; then lastb -n 8 2>/dev/null || true
  elif has_cmd journalctl; then journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -iE 'fail|invalid' | tail -n 8 || true
  fi
}
ssh_set_kv() {
  local file="$1" key="$2" value="$3" tmp
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ set $key $value in $file"; return 0; fi
  tmp="$(mktemp)"
  awk -v k="$key" 'BEGIN{IGNORECASE=1} !(tolower($1)==tolower(k)) {print}' "$file" > "$tmp"
  printf '%s %s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
}
ssh_harden_apply() {
  ensure_linux_only "macOS sshd 配置路径与行为不同，请手工修改。"
  local file; file="$(ssh_config_path)"
  [[ -f "$file" ]] || fatal "未找到 sshd_config"
  local no_root=0 no_pass=0 port="" allow_users=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --no-root-login) no_root=1 ;;
      --no-password) no_pass=1 ;;
      --port) shift; port="${1:-}" ;;
      --port=*) port="${1#*=}" ;;
      --allow-users) shift; allow_users="${1:-}" ;;
      --allow-users=*) allow_users="${1#*=}" ;;
    esac
    shift || true
  done
  if [[ -t 0 && "$no_root" -eq 0 && "$no_pass" -eq 0 && -z "$port" && -z "$allow_users" ]]; then
    echo "可选加固项（默认只应用安全基线：禁空密码、MaxAuthTries 4）："
    read -r -p "禁止 root 登录？[y/N] " _a; [[ "${_a:-}" =~ ^[yY]$ ]] && no_root=1
    read -r -p "禁止密码登录（只留公钥）？[y/N] " _a; [[ "${_a:-}" =~ ^[yY]$ ]] && no_pass=1
    read -r -p "修改 SSH 端口（空=不改）: " port || true
    read -r -p "AllowUsers 白名单（逗号分隔，空=不设）: " allow_users || true
  fi
  [[ -z "$port" || "$port" =~ ^[0-9]+$ ]] || fatal "非法端口：$port"
  [[ -z "$port" || ( "$port" -ge 1 && "$port" -le 65535 ) ]] || fatal "端口越界：$port"
  echo "将应用："
  echo "  PermitEmptyPasswords no"
  echo "  MaxAuthTries 4"
  [[ "$no_root" -eq 1 ]] && echo "  PermitRootLogin no"
  [[ "$no_pass" -eq 1 ]] && echo "  PasswordAuthentication no" && echo "  KbdInteractiveAuthentication no" && echo "  ChallengeResponseAuthentication no"
  [[ -n "$port" ]] && echo "  Port $port"
  [[ -n "$allow_users" ]] && echo "  AllowUsers ${allow_users//,/ }"
  warn "请保持当前 SSH 会话不要断开；建议另开一个窗口先测新配置。"
  confirm "即将备份并修改 ${file}，校验通过后 reload sshd。是否继续？" || cancelled
  backup_file_if_exists "$file"
  ssh_set_kv "$file" PermitEmptyPasswords no
  ssh_set_kv "$file" MaxAuthTries 4
  [[ "$no_root" -eq 1 ]] && ssh_set_kv "$file" PermitRootLogin no
  if [[ "$no_pass" -eq 1 ]]; then
    ssh_set_kv "$file" PasswordAuthentication no
    ssh_set_kv "$file" KbdInteractiveAuthentication no
    ssh_set_kv "$file" ChallengeResponseAuthentication no
  fi
  [[ -n "$port" ]] && ssh_set_kv "$file" Port "$port"
  [[ -n "$allow_users" ]] && ssh_set_kv "$file" AllowUsers "${allow_users//,/ }"
  if [[ "$DRY_RUN" -eq 1 ]]; then success "dry-run：未真正改 sshd。"; return 0; fi
  if has_cmd sshd && ! sshd -t; then
    local latest
    latest="$(ls -t "$file".bak.* 2>/dev/null | head -n1 || true)"
    if [[ -n "$latest" && -f "$latest" ]]; then
      warn "sshd -t 失败，正在从备份回滚：$latest"
      run cp -a "$latest" "$file"
      fatal "sshd -t 失败，已回滚到 ${latest}。请检查配置后重试。"
    fi
    fatal "sshd -t 失败，且未找到备份，请手动修复：$file"
  fi
  if has_cmd systemctl; then run systemctl reload sshd 2>/dev/null || run systemctl reload ssh 2>/dev/null || run systemctl reload sshd.service || warn "reload 失败，请手动 systemctl reload sshd"
  elif has_cmd service; then run service ssh reload || run service sshd reload || true
  fi
  success "SSH 基线已应用。请立即用新窗口验证登录。"
}

# ---------- 定时任务 cron ----------
cron_user_or_ask() { local u="${1:-}"; if [[ -z "$u" ]]; then read -r -p "用户 [root]: " u || true; u="${u:-root}"; fi; require_valid_user "$u"; printf '%s' "$u"; }
cron_list() {
  local target="${1:-}"
  if [[ "$target" == timers || "$target" == timer ]]; then
    ensure_linux_only "macOS 无 systemd timer。"
    section "systemd timers"
    has_cmd systemctl && systemctl list-timers --all --no-pager || warn "未检测到 systemctl"
    return 0
  fi
  if [[ "$target" == system ]]; then
    section "/etc/crontab"
    [[ -f /etc/crontab ]] && grep -vE '^[[:space:]]*(#|$)' /etc/crontab || echo "(无)"
    section "/etc/cron.d"
    if [[ -d /etc/cron.d ]]; then
      local f; for f in /etc/cron.d/*; do [[ -f "$f" ]] || continue; echo "--- $f ---"; grep -vE '^[[:space:]]*(#|$)' "$f" || true; done
    fi
    section "cron.hourly/daily/weekly/monthly"
    ls -l /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null || true
    return 0
  fi
  if [[ "$target" == all ]]; then
    cron_list system
    if is_linux && [[ -d /var/spool/cron/crontabs ]]; then
      local u; for u in /var/spool/cron/crontabs/*; do [[ -f "$u" ]] || continue; section "crontab $(basename "$u")"; crontab -u "$(basename "$u")" -l 2>/dev/null || cat "$u"; done
    elif [[ -d /var/spool/cron ]]; then
      local u; for u in /var/spool/cron/*; do [[ -f "$u" ]] || continue; section "crontab $(basename "$u")"; crontab -u "$(basename "$u")" -l 2>/dev/null || cat "$u"; done
    fi
    cron_list timers || true
    return 0
  fi
  local u; u="$(cron_user_or_ask "$target")"
  section "crontab -u $u"
  crontab -u "$u" -l 2>/dev/null || crontab -l 2>/dev/null || warn "用户 ${u} 无 crontab 或无权读取"
}
cron_add() {
  local u="${1:-}" line="${2:-}"
  if [[ -n "$u" && -z "$line" ]] && ! valid_linux_user "$u"; then line="$u"; u="root"; fi
  u="$(cron_user_or_ask "$u")"
  [[ -n "$line" ]] || { echo "输入完整 crontab 行，例如：0 2 * * * /usr/local/bin/backup.sh"; read -r line; }
  [[ -n "$line" ]] || cancelled
  [[ "$line" != *$'\n'* ]] || fatal "crontab 行不能包含换行"
  confirm "即将向用户 ${u} 追加：${line}。是否继续？" || cancelled
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ crontab add for $u: $line"; return 0; fi
  local tmp; tmp="$(mktemp)"
  crontab -u "$u" -l 2>/dev/null | grep -vE '^[[:space:]]*$' > "$tmp" || true
  printf '%s\n' "$line" >> "$tmp"
  crontab -u "$u" "$tmp"
  rm -f "$tmp"
  success "已写入 ${u} 的 crontab。"
}
cron_remove() {
  local u="${1:-}" pat="${2:-}"
  if [[ -n "$u" && -z "$pat" ]] && ! valid_linux_user "$u"; then pat="$u"; u="root"; fi
  u="$(cron_user_or_ask "$u")"
  crontab -u "$u" -l 2>/dev/null || fatal "用户 ${u} 无 crontab"
  [[ -n "$pat" ]] || { read -r -p "要删除的行号或匹配关键词: " pat; }
  [[ -n "$pat" ]] || cancelled
  confirm "即将从 ${u} 的 crontab 删除匹配 ${pat} 的行。是否继续？" || cancelled
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ crontab remove for $u: $pat"; return 0; fi
  local tmp; tmp="$(mktemp)"
  if [[ "$pat" =~ ^[0-9]+$ ]]; then crontab -u "$u" -l 2>/dev/null | awk -v n="$pat" 'NR!=n' > "$tmp"
  else crontab -u "$u" -l 2>/dev/null | grep -vF "$pat" > "$tmp" || true; fi
  crontab -u "$u" "$tmp"
  rm -f "$tmp"
  success "已更新 ${u} 的 crontab。"
}
cron_backup() {
  local u="${1:-}" dest ts dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="${BACKUP_ROOT}/cron"
  [[ -n "$u" ]] || { read -r -p "备份哪个用户的 crontab（空=全部/system）: " u || true; }
  run mkdir -p "$dir"
  if [[ -z "$u" || "$u" == all ]]; then
    dest="$dir/all-${ts}"
    run mkdir -p "$dest"
    crontab -l > "$dest/root.crontab" 2>/dev/null || true
    [[ -f /etc/crontab ]] && run cp -a /etc/crontab "$dest/etc-crontab"
    [[ -d /etc/cron.d ]] && run cp -a /etc/cron.d "$dest/cron.d"
    success "cron 备份目录：$dest"
  else
    require_valid_user "$u"
    dest="$dir/${u}-${ts}.crontab"
    if [[ "$DRY_RUN" -eq 1 ]]; then info "+ backup crontab $u -> $dest"; return 0; fi
    crontab -u "$u" -l > "$dest"
    success "已备份到 $dest"
  fi
}
cron_restore() {
  local file="${1:-}" u="${2:-}"
  [[ -n "$file" ]] || { read -r -p "crontab 备份文件: " file; }
  [[ -f "$file" ]] || fatal "文件不存在：$file"
  u="$(cron_user_or_ask "$u")"
  confirm "即将用 ${file} 覆盖用户 ${u} 的 crontab。是否继续？" || cancelled
  run crontab -u "$u" "$file"
  success "已恢复 ${u} 的 crontab。"
}
cron_timers() { cron_list timers; }

# ---------- 日志与排障 log ----------
log_journal() {
  ensure_linux_only "macOS 请用 log show。"
  has_cmd journalctl || fatal "未检测到 journalctl"
  local unit="${1:-}" prio="${2:-}" since="${3:-}" lines="${4:-100}"
  [[ -n "$unit" ]] || { read -r -p "单元名（空=全部）: " unit || true; }
  [[ -n "$prio" ]] || { read -r -p "最低优先级 emerg|alert|crit|err|warning|notice|info|debug [warning]: " prio || true; prio="${prio:-warning}"; }
  [[ -n "$since" ]] || { read -r -p "起始时间，如 2 hours ago / today [2 hours ago]: " since || true; since="${since:-2 hours ago}"; }
  local args=(--no-pager -n "$lines" -p "$prio" --since "$since")
  [[ -n "$unit" ]] && args+=(-u "$unit")
  run journalctl "${args[@]}"
}
log_events() {
  local hours="${1:-24}"
  [[ "$hours" =~ ^[0-9]+$ ]] || fatal "小时数必须是数字：$hours"
  section "最近 ${hours} 小时关键事件"
  if is_linux && has_cmd journalctl; then
    echo "--- reboot / shutdown ---"
    journalctl --list-boots --no-pager 2>/dev/null | tail -n 8 || true
    echo "--- OOM / killed ---"
    journalctl -k --since "${hours} hours ago" --no-pager 2>/dev/null | grep -iE 'Out of memory|Killed process|oom-kill' | tail -n 20 || echo "(无)"
    echo "--- I/O / filesystem 错误 ---"
    journalctl -k --since "${hours} hours ago" --no-pager 2>/dev/null | grep -iE 'I/O error|Buffer I/O error|Read-only file system|blocked for more than|ext4_error|XFS:.*error' | tail -n 20 || echo "(无)"
    echo "--- segfault / panic ---"
    journalctl -k --since "${hours} hours ago" --no-pager 2>/dev/null | grep -iE 'segfault|Kernel panic|Oops:|BUG: |Call Trace:' | tail -n 20 || echo "(无)"
    echo "--- 认证失败 ---"
    journalctl --since "${hours} hours ago" --no-pager _COMM=sshd 2>/dev/null | grep -iE 'fail|invalid|refused' | tail -n 20 || true
  else
    last -x 2>/dev/null | head -n 15 || true
    warn "无 journalctl，仅列出最近登录/重启。"
  fi
}
log_search() {
  local kw="${1:-}" path="${2:-/var/log}"
  [[ -n "$kw" ]] || kw="$(need_arg kw "" "关键词: ")"
  [[ -n "$kw" ]] || cancelled
  [[ -d "$path" || -f "$path" ]] || fatal "路径不存在：$path"
  info "在 ${path} 搜索：${kw}"
  if has_cmd grep; then
    grep -R --binary-files=without-match -n -I -F -- "$kw" "$path" 2>/dev/null | tail -n 80 || true
  fi
}
log_collect() {
  local hours="${1:-2}" out="${2:-}" ts dest
  [[ "$hours" =~ ^[0-9]+$ ]] || fatal "小时数必须是数字：$hours"
  ts="$(date +%Y%m%d-%H%M%S)"
  [[ -n "$out" ]] || { read -r -p "输出包路径 [/tmp/incident-${ts}.tgz]: " out || true; out="${out:-/tmp/incident-${ts}.tgz}"; }
  info "采集近 ${hours} 小时现场 -> $out"
  if [[ "$DRY_RUN" -eq 1 ]]; then info "+ collect logs --hours $hours -> $out"; return 0; fi
  dest="$(mktemp -d /tmp/incident.XXXXXX)"
  {
    echo "time=$(date -Is 2>/dev/null || date)"
    echo "host=$(hostname)"
    print_env
    echo
    uptime || true
    echo
    df -hT 2>/dev/null || df -h || true
    echo
    free -h 2>/dev/null || true
    echo
    ip addr 2>/dev/null || ifconfig || true
    echo
    ps auxf 2>/dev/null || ps aux || true
  } > "$dest/summary.txt" 2>&1 || true
  dmesg -T 2>/dev/null | tail -n 400 > "$dest/dmesg.txt" || dmesg | tail -n 400 > "$dest/dmesg.txt" || true
  if has_cmd journalctl; then
    journalctl --since "${hours} hours ago" --no-pager > "$dest/journal.txt" 2>/dev/null || true
    journalctl -k --since "${hours} hours ago" --no-pager > "$dest/journal-kernel.txt" 2>/dev/null || true
  fi
  mkdir -p "$dest/var-log"
  local f; for f in /var/log/syslog /var/log/messages /var/log/auth.log /var/log/secure /var/log/kern.log /var/log/nginx/error.log /var/log/nginx/access.log /var/log/docker.log; do
    [[ -f "$f" ]] && cp -a "$f" "$dest/var-log/$(echo "$f" | tr '/' '_')" 2>/dev/null || true
  done
  if has_cmd tar; then
    tar -C "$(dirname "$dest")" -czf "$out" "$(basename "$dest")"
    rm -rf "$dest"
    success "现场包：$out"
  else
    warn "未找到 tar，现场目录保留在 $dest"
  fi
}

# ---------- 网络诊断 net ----------
net_info() {
  section "主机名 / DNS"
  echo "hostname: $(hostname 2>/dev/null || true)"
  [[ -f /etc/resolv.conf ]] && grep -vE '^[[:space:]]*(#|$)' /etc/resolv.conf || true
  if has_cmd resolvectl; then echo; resolvectl status 2>/dev/null | head -n 40 || true; fi
  section "地址"
  if has_cmd ip; then ip -br addr; echo; ip route; else ifconfig; netstat -rn 2>/dev/null || true; fi
  section "默认网关探测"
  local gw=""
  gw="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
  if [[ -n "$gw" ]] && has_cmd ping; then ping -c 2 -W 2 "$gw" || warn "网关 ${gw} ping 失败"; elif [[ -z "$gw" ]]; then warn "无默认网关"; fi
}
net_listen() {
  local port="${1:-}"
  section "监听端口"
  if has_cmd ss; then
    if [[ -n "$port" ]]; then ss -lntup 2>/dev/null | grep -E ":${port}[[:space:]]|: ${port} " || ss -lntup | grep ":$port" || warn "未找到端口 $port"
    else ss -lntup 2>/dev/null || ss -lntu; fi
  elif has_cmd netstat; then
    netstat -lntup 2>/dev/null || netstat -anv 2>/dev/null | head -n 40
  else warn "未找到 ss/netstat"; fi
}
net_who() {
  local port="${1:-}"
  [[ -n "$port" ]] || port="$(need_arg port "" "端口: ")"
  [[ "$port" =~ ^[0-9]+$ ]] || fatal "非法端口：$port"
  net_listen "$port"
  if has_cmd lsof; then section "lsof"; lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || lsof -nP -i:":$port" 2>/dev/null || true; fi
}
net_dns() {
  local name="${1:-}"
  [[ -n "$name" ]] || { read -r -p "要解析的域名 [one.one.one.one]: " name || true; name="${name:-one.one.one.one}"; }
  section "resolv.conf"
  [[ -f /etc/resolv.conf ]] && cat /etc/resolv.conf || true
  if has_cmd dig; then section "dig"; dig +time=2 +tries=1 "$name" || true
  elif has_cmd nslookup; then section "nslookup"; nslookup "$name" || true
  elif has_cmd getent; then section "getent"; getent hosts "$name" || warn "解析失败"
  else warn "无 dig/nslookup/getent"; fi
}
net_ping() {
  local host="${1:-}"
  [[ -n "$host" ]] || host="$(need_arg host "" "主机/IP: ")"
  [[ -n "$host" ]] || cancelled
  valid_host_or_ip "$host" || fatal "非法主机：$host"
  has_cmd ping || fatal "未找到 ping"
  if is_macos; then run ping -c 4 "$host"; else run ping -c 4 -W 2 "$host"; fi
}
net_probe() {
  local target="${1:-}" host port
  [[ -n "$target" ]] || target="$(need_arg target "" "目标 host:port : ")"
  [[ -n "$target" ]] || cancelled
  host="${target%%:*}"; port="${target##*:}"
  [[ "$host" != "$port" ]] || fatal "格式应为 host:port，例如 1.1.1.1:443"
  valid_host_or_ip "$host" || fatal "非法主机：$host"
  valid_port "$port" || fatal "非法端口：$port"
  info "探测 ${host}:${port}"
  if has_cmd timeout; then
    if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" >/dev/null 2>&1; then success "TCP ${host}:${port} 可连通"; return 0; fi
  elif bash -c "echo >/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
    success "TCP ${host}:${port} 可连通"; return 0
  fi
  if has_cmd nc; then nc -z -w 3 "$host" "$port" >/dev/null 2>&1 && { success "nc 探测成功"; return 0; }; fi
  warn "无法连通 ${host}:${port}"
  return 1
}
net_route() {
  section "路由表"
  if has_cmd ip; then ip route show; echo; ip -6 route show 2>/dev/null || true
  else netstat -rn || true; fi
  if has_cmd traceroute; then
    local dest="${1:-}"
    [[ -n "$dest" ]] || { read -r -p "traceroute 目标（空=跳过）: " dest || true; }
    [[ -n "$dest" ]] && traceroute -m 15 -w 2 "$dest" || true
  elif has_cmd mtr; then
    local dest="${1:-}"
    [[ -n "$dest" ]] || { read -r -p "mtr 目标（空=跳过）: " dest || true; }
    [[ -n "$dest" ]] && mtr -r -c 5 "$dest" || true
  fi
}

# ---------- 系统配置 sysconf ----------
sysconf_hostname() {
  local name="${1:-}"
  echo "当前主机名：$(hostname)"
  [[ -n "$name" ]] || { read -r -p "新主机名（空=只查看）: " name || true; }
  [[ -n "$name" ]] || return 0
  valid_hostname "$name" || fatal "非法主机名：$name"
  confirm "即将设置主机名为 ${name}。是否继续？" || cancelled
  if has_cmd hostnamectl; then run hostnamectl set-hostname "$name"
  else run hostname "$name"; [[ -w /etc/hostname ]] && write_file /etc/hostname <<< "$name" || true; fi
  if [[ -f /etc/hosts ]]; then
    backup_file_if_exists /etc/hosts
    if [[ "$DRY_RUN" -eq 0 ]]; then
      if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i.bak.hostname "s/^127\.0\.1\.1.*/127.0.1.1\t${name}/" /etc/hosts
      else
        append_line_if_missing /etc/hosts $'127.0.1.1\t'"$name"
      fi
    fi
  fi
  success "主机名已设置为 ${name}。"
}
sysconf_timezone() {
  local tz="${1:-}"
  if has_cmd timedatectl; then timedatectl | grep -E 'Time zone|Local time|Universal' || timedatectl; else date; [[ -L /etc/localtime ]] && readlink /etc/localtime || true; fi
  [[ -n "$tz" ]] || { read -r -p "时区（如 Asia/Shanghai，空=只查看）: " tz || true; }
  [[ -n "$tz" ]] || return 0
  [[ "$tz" =~ ^[A-Za-z0-9/_+-]+$ ]] || fatal "非法时区：$tz"
  [[ -e "/usr/share/zoneinfo/$tz" ]] || warn "未找到 /usr/share/zoneinfo/${tz}，仍尝试设置。"
  confirm "即将设置时区为 ${tz}。是否继续？" || cancelled
  if has_cmd timedatectl; then run timedatectl set-timezone "$tz"
  else run ln -sfn "/usr/share/zoneinfo/$tz" /etc/localtime; fi
  success "时区已设置为 ${tz}。"
}
sysconf_time() {
  section "当前时间"
  date
  has_cmd timedatectl && timedatectl || true
  if has_cmd chronyc; then section "chrony"; chronyc tracking 2>/dev/null || true; chronyc sources 2>/dev/null | head -n 10 || true; fi
  if has_cmd ntpq; then section "ntpd"; ntpq -p 2>/dev/null || true; fi
}
sysconf_ntp() {
  local action="${1:-status}"
  case "$action" in
    status|"") sysconf_time ;;
    enable)
      ensure_linux_only "macOS 时间同步由系统设置管理。"
      confirm "即将启用时间同步（优先 chrony / systemd-timesyncd）。是否继续？" || cancelled
      if has_cmd chronyd || pkg_install chrony; then
        has_cmd systemctl && run systemctl enable --now chronyd 2>/dev/null || run systemctl enable --now chrony 2>/dev/null || true
      elif has_cmd timedatectl; then
        run timedatectl set-ntp true
      fi
      success "已尝试启用时间同步。"
      sysconf_time
      ;;
    *) fatal "未知 ntp 动作：$action（status|enable）" ;;
  esac
}
sysconf_hosts() {
  local action="${1:-list}" ip="${2:-}" name="${3:-}"
  case "$action" in
    list|"") section "/etc/hosts"; cat /etc/hosts 2>/dev/null || true ;;
    add)
      [[ -n "$ip" ]] || ip="$(need_arg ip "" "IP: ")"
      [[ -n "$name" ]] || name="$(need_arg name "" "主机名: ")"
      [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || fatal "非法 IP：$ip"
      valid_hostname "$name" || fatal "非法主机名：$name"
      confirm "即将追加：${ip} ${name}。是否继续？" || cancelled
      backup_file_if_exists /etc/hosts
      append_line_if_missing /etc/hosts "${ip} ${name}"
      success "已写入 /etc/hosts。"
      ;;
    del)
      name="${2:-}"
      [[ -n "$name" ]] || name="$(need_arg name "" "要删除的主机名或 IP: ")"
      [[ "$name" =~ ^[A-Za-z0-9._:-]+$ ]] || fatal "非法匹配串：$name"
      confirm "即将从 /etc/hosts 删除包含 ${name} 的行。是否继续？" || cancelled
      backup_file_if_exists /etc/hosts
      [[ -f /etc/hosts ]] && run sed -i.bak.hosts "/${name}/d" /etc/hosts
      success "已更新 /etc/hosts。"
      ;;
    *) fatal "未知 hosts 动作：$action（list|add|del）" ;;
  esac
}
sysconf_sysctl() {
  ensure_linux_only "macOS sysctl 持久化方式不同。"
  local action="${1:-list}" kv="${2:-}" key value file
  file="/etc/sysctl.d/99-linux-admin-toolkit.conf"
  case "$action" in
    list|"")
      section "常用内核参数"
      for key in fs.file-max vm.swappiness net.core.somaxconn fs.inotify.max_user_watches net.ipv4.ip_forward; do
        printf '%-36s %s\n' "$key" "$(sysctl -n "$key" 2>/dev/null || echo unset)"
      done
      [[ -f "$file" ]] && { section "脚本持久化文件 $file"; cat "$file"; }
      ;;
    set|persist)
      [[ -n "$kv" ]] || kv="$(need_arg kv "" "参数，如 vm.swappiness=10: ")"
      [[ "$kv" == *=* ]] || fatal "格式应为 key=value"
      key="${kv%%=*}"; value="${kv#*=}"
      [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || fatal "非法 sysctl 键：$key"
      [[ "$value" =~ ^[A-Za-z0-9._:/-]+$ ]] || fatal "非法 sysctl 值：$value"
      confirm "即将设置 ${key}=${value}${action:+（$action）}。是否继续？" || cancelled
      run sysctl -w "${key}=${value}"
      if [[ "$action" == persist ]]; then
        run mkdir -p /etc/sysctl.d
        if [[ "$DRY_RUN" -eq 1 ]]; then info "+ persist $key=$value -> $file"
        else
          touch "$file"
          if grep -qE "^${key}[[:space:]]*=" "$file"; then sed -i.bak.sysctl "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
          else printf '%s = %s\n' "$key" "$value" >> "$file"; fi
        fi
        success "已写入 $file"
      fi
      ;;
    *) fatal "未知 sysctl 动作：$action（list|set|persist）" ;;
  esac
}
sysconf_limits() {
  ensure_linux_only "macOS 资源限制请用 launchctl limit。"
  local action="${1:-show}" item="${2:-}" value="${3:-}" file domain
  file="/etc/security/limits.d/99-linux-admin-toolkit.conf"
  case "$action" in
    show|"")
      section "当前 shell 限制"; ulimit -a 2>/dev/null || true
      [[ -f /etc/security/limits.conf ]] && { section "limits.conf 非注释行"; grep -vE '^[[:space:]]*(#|$)' /etc/security/limits.conf || true; }
      [[ -f "$file" ]] && { section "$file"; cat "$file"; }
      ;;
    set)
      [[ -n "$item" ]] || item="$(need_arg item "" "项目 nofile|nproc: ")"
      [[ -n "$value" ]] || value="$(need_arg value "" "值，如 65535: ")"
      [[ "$item" =~ ^[a-z]+$ ]] || fatal "非法 limits 项：$item"
      [[ "$value" =~ ^[0-9]+$ ]] || fatal "值必须是数字：$value"
      domain="${4:-*}"
      confirm "即将持久化 ${domain} ${item}=${value} 到 ${file}。是否继续？" || cancelled
      run mkdir -p /etc/security/limits.d
      if [[ "$DRY_RUN" -eq 1 ]]; then info "+ limits $domain $item $value"
      else
        touch "$file"
        # limits 格式: domain type item value；用 awk 精确匹配 domain+item 去重，避免正则转义问题
        awk -v d="$domain" -v it="$item" '$1==d && $3==it {next} {print}' "$file" > "${file}.tmp"
        printf '%s soft %s %s\n%s hard %s %s\n' "$domain" "$item" "$value" "$domain" "$item" "$value" >> "${file}.tmp"
        cat "${file}.tmp" > "$file"; rm -f "${file}.tmp"
      fi
      success "已写入 $file（新登录会话生效）。"
      ;;
    *) fatal "未知 limits 动作：$action（show|set）" ;;
  esac
}

# ---------- 磁盘与文件系统 disk（非 LVM） ----------
disk_list() {
  section "块设备"
  if has_cmd lsblk; then lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINT,RO,MODEL
  else df -h; fi
  section "挂载"
  findmnt -A 2>/dev/null || mount | head -n 40 || true
  section "磁盘使用"
  df -hT 2>/dev/null || df -h
  if is_linux; then section "inode"; df -hi -x tmpfs -x devtmpfs 2>/dev/null || true; fi
}
disk_smart() {
  local dev="${1:-}"
  if ! has_cmd smartctl; then
    warn "未安装 smartctl，尝试安装 smartmontools。"
    is_macos && brew_install smartmontools || pkg_install smartmontools || true
  fi
  has_cmd smartctl || fatal "未找到 smartctl"
  if [[ -z "$dev" ]]; then
    section "磁盘一览"
    has_cmd lsblk && lsblk -d -o NAME,SIZE,MODEL,ROTA || true
    read -r -p "设备路径（空=检查所有磁盘）: " dev || true
  fi
  if [[ -n "$dev" ]]; then
    [[ -b "$dev" || -c "$dev" ]] || fatal "不是块设备：$dev"
    run smartctl -H "$dev" || true
    run smartctl -A "$dev" || true
  else
    local d
    for d in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z] /dev/xvd[a-z]; do
      [[ -b "$d" ]] || continue
      section "SMART $d"
      smartctl -H "$d" 2>/dev/null || true
    done
  fi
}
disk_fstab() {
  section "/etc/fstab"
  [[ -f /etc/fstab ]] && grep -vE '^[[:space:]]*(#|$)' /etc/fstab || { warn "无 /etc/fstab"; return 0; }
  echo
  local src mp typ opts dump pass uuid dev found
  while read -r src mp typ opts dump pass; do
    [[ -n "$src" ]] || continue
    found=0
    case "$src" in
      UUID=*|uuid=*)
        uuid="${src#*=}"
        if [[ -e "/dev/disk/by-uuid/$uuid" ]]; then found=1; dev="$(readlink -f "/dev/disk/by-uuid/$uuid" 2>/dev/null || true)"
        elif has_cmd blkid && blkid | grep -q "UUID=\"$uuid\""; then found=1; fi
        ;;
      LABEL=*|label=*)
        if [[ -e "/dev/disk/by-label/${src#*=}" ]]; then found=1; fi
        ;;
      /*)
        [[ -e "$src" ]] && found=1
        ;;
      *)
        found=1
        ;;
    esac
    if [[ "$found" -eq 1 ]]; then printf '  [OK]   %-30s -> %s\n' "$src" "$mp"
    else printf '  [MISS] %-30s -> %s  （设备不存在，开机可能失败）\n' "$src" "$mp"; fi
    if [[ "$mp" != none && "$mp" != swap && ! -d "$mp" ]]; then warn "挂载点目录不存在：$mp"; fi
  done < <(awk '$1 !~ /^#/ && NF>=2 {print $1,$2,$3,$4,$5,$6}' /etc/fstab)
  section "重复挂载点"
  awk '$1 !~ /^#/ && NF>=2 && $2!="none" {print $2}' /etc/fstab | sort | uniq -d | grep -n . && warn "存在重复挂载点" || echo "(无)"
}
disk_grow() {
  ensure_linux_only "macOS 不支持此 Linux 文件系统扩容。"
  local target="${1:-}" src fstype mp dev
  [[ -n "$target" ]] || target="$(need_arg target "" "挂载点或设备，如 /data 或 /dev/sdb1: ")"
  [[ -n "$target" ]] || cancelled
  if [[ -d "$target" ]]; then
    mp="$target"
    src="$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null || true)"
    fstype="$(findmnt -n -o FSTYPE --target "$mp" 2>/dev/null || true)"
  elif [[ -b "$target" ]]; then
    src="$target"
    mp="$(findmnt -n -o TARGET "$src" 2>/dev/null || true)"
    fstype="$(findmnt -n -o FSTYPE "$src" 2>/dev/null || blkid -o value -s TYPE "$src" 2>/dev/null || true)"
  else
    fatal "不是挂载点或块设备：$target"
  fi
  [[ -n "$src" ]] || fatal "无法解析设备"
  [[ -n "$fstype" ]] || fatal "无法识别文件系统类型"
  info "设备=$src  挂载点=${mp:-未挂载}  类型=$fstype"
  warn "本操作只把文件系统扩到当前分区/LV 已有容量，不会改分区表。"
  confirm "即将扩容文件系统 ${src}（${fstype}）。是否继续？" || cancelled
  case "$fstype" in
    xfs) has_cmd xfs_growfs || pkg_install xfsprogs; [[ -n "$mp" ]] || fatal "xfs_growfs 需要挂载点"; run xfs_growfs "$mp" ;;
    ext2|ext3|ext4) has_cmd resize2fs || pkg_install e2fsprogs; run resize2fs "$src" ;;
    btrfs) has_cmd btrfs || fatal "缺少 btrfs 工具"; [[ -n "$mp" ]] || fatal "btrfs 需要挂载点"; run btrfs filesystem resize max "$mp" ;;
    *) fatal "暂不支持的文件系统：$fstype" ;;
  esac
  df -hT "${mp:-$src}" 2>/dev/null || df -h "$src" || true
  success "文件系统扩容完成。"
}
disk_large() {
  local path="${1:-/}" n="${2:-15}"
  [[ -d "$path" ]] || fatal "目录不存在：$path"
  [[ "$n" =~ ^[0-9]+$ ]] || n=15
  section "${path} 下较大目录 / 文件 Top ${n}"
  if has_cmd du; then
    du -x -h --max-depth=2 "$path" 2>/dev/null | sort -hr | head -n "$n" || du -h -d 2 "$path" 2>/dev/null | sort -hr | head -n "$n" || true
  fi
  if has_cmd find; then
    section "大文件（>200M）"
    find "$path" -xdev -type f -size +200M -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n "$n" | awk '{printf "%.1fG\t%s\n", $1/1024/1024/1024, $2}' || true
  fi
}
disk_deleted() {
  ensure_linux_only "macOS 请用 lsof 手工排查已删占用。"
  section "已删除但仍被进程占用的文件"
  if has_cmd lsof; then
    lsof +L1 2>/dev/null | head -n 40 || lsof 2>/dev/null | grep -i deleted | head -n 40 || echo "(无或无权)"
  else
    warn "未安装 lsof"
  fi
}
disk_inode() {
  section "inode 使用"
  df -hi -x tmpfs -x devtmpfs 2>/dev/null || df -i
}

# ---------- 进程与资源 proc ----------
proc_top() {
  local sort="${1:-cpu}" n=15
  case "$sort" in
    cpu|"") section "CPU Top ${n}"; ps aux --sort=-%cpu 2>/dev/null | head -n $((n+1)) || ps aux | head -n $((n+1)) ;;
    mem) section "内存 Top ${n}"; ps aux --sort=-%mem 2>/dev/null | head -n $((n+1)) || ps aux | head -n $((n+1)) ;;
    fd)
      section "打开文件数 Top ${n}"
      if [[ -d /proc ]]; then
        local d pid cnt comm
        for d in /proc/[0-9]*; do
          pid="${d#/proc/}"
          cnt="$(ls "$d/fd" 2>/dev/null | wc -l | tr -d ' ')"
          comm="$(cat "$d/comm" 2>/dev/null || echo '?')"
          printf '%6s %6s %s\n' "$cnt" "$pid" "$comm"
        done | sort -nr | head -n "$n" | awk '{printf "fd=%-6s pid=%-6s %s\n", $1,$2,$3}'
      else warn "无 /proc，无法统计 fd"; fi
      ;;
    io)
      section "磁盘 IO 粗览"
      if has_cmd iotop; then warn "交互 iotop 请直接运行 iotop；下面是 pidstat/iotop 快照（若可用）。"; fi
      has_cmd pidstat && pidstat -d 1 1 2>/dev/null | head -n 20 || true
      if [[ -r /proc/diskstats ]]; then awk '{printf "%s r=%s w=%s\n", $3,$6,$10}' /proc/diskstats | head -n 20; fi
      ;;
    *) fatal "未知排序：$sort（cpu|mem|fd|io）" ;;
  esac
}
proc_port() {
  local port="${1:-}"
  [[ -n "$port" ]] || port="$(need_arg port "" "端口: ")"
  net_who "$port"
}
proc_files() {
  local target="${1:-}"
  [[ -n "$target" ]] || target="$(need_arg target "" "PID 或文件/目录路径: ")"
  [[ -n "$target" ]] || cancelled
  has_cmd lsof || { pkg_install lsof || true; }
  has_cmd lsof || fatal "未找到 lsof"
  if [[ "$target" =~ ^[0-9]+$ ]]; then run lsof -nP -p "$target" | head -n 60
  else run lsof -nP "$target" | head -n 60; fi
}
proc_kill() {
  local pid="${1:-}" sig="${2:-TERM}"
  [[ -n "$pid" ]] || pid="$(need_arg pid "" "PID: ")"
  [[ "$pid" =~ ^[0-9]+$ ]] || fatal "非法 PID：$pid"
  [[ "$sig" =~ ^[A-Z0-9]+$ ]] || fatal "非法信号：$sig"
  [[ "$pid" != "1" ]] || fatal "拒绝向 PID 1 发信号。"
  [[ "$pid" != "$$" ]] || fatal "拒绝向脚本自身进程发信号。"
  ps -p "$pid" -o pid,user,stat,etime,cmd || fatal "进程不存在：$pid"
  confirm "即将向 PID ${pid} 发送 SIG${sig}。是否继续？" || cancelled
  run kill -s "$sig" "$pid"
  success "已向 ${pid} 发送 SIG${sig}。"
}
proc_cgroup() {
  local pid="${1:-}"
  if [[ -z "$pid" ]]; then
    section "本机 cgroup / 容器线索"
    [[ -f /proc/1/cgroup ]] && { echo "PID1 cgroup:"; tail -n 5 /proc/1/cgroup; } || true
    if has_cmd systemd-cgls; then systemd-cgls --no-pager 2>/dev/null | head -n 40 || true; fi
    return 0
  fi
  [[ "$pid" =~ ^[0-9]+$ ]] || fatal "非法 PID：$pid"
  [[ -d "/proc/$pid" ]] || fatal "进程不存在：$pid"
  section "PID $pid"
  ps -p "$pid" -o pid,ppid,user,stat,etime,%cpu,%mem,cmd || true
  echo "cgroup:"; cat "/proc/$pid/cgroup" 2>/dev/null || true
  echo "ns:"; ls -l "/proc/$pid/ns" 2>/dev/null || true
}
proc_report() {
  section "为什么可能慢 / 资源简报"
  echo "负载：$(uptime)"
  echo "CPU：$(cpu_count) 核"
  if is_linux && [[ -r /proc/stat ]]; then
    awk '/^cpu /{u=$2+$4; t=$2+$3+$4+$5+$6+$7+$8; i=$5; w=$6; s=$7; printf "粗算 idle 字段=%s iowait=%s steal=%s（单次采样，仅供参考）\n", i,w,s}' /proc/stat
  fi
  echo
  free -h 2>/dev/null || true
  echo
  df -hT 2>/dev/null | head -n 15 || true
  echo
  proc_top cpu
  echo
  proc_top mem
  if is_linux; then
    echo
    section "最近 OOM"
    journalctl -k --since '7 days ago' --no-pager 2>/dev/null | grep -iE 'Out of memory|Killed process' | tail -n 10 || echo "(无)"
    echo
    section "D 状态 / 僵尸"
    ps -eo pid,stat,wchan:16,cmd | awk 'NR==1 || $2 ~ /Z/ || $2 ~ /^D/' | head -n 20
  fi
}

# ---------- 菜单 ----------
menu_clear() { [[ -t 1 ]] && clear || true; }
menu_invalid() { warn "无效选择，请重新输入。"; sleep 1; }
menu_action() { local title="$1" rc; shift; echo; info "开始执行：${title}"; set +Eeuo pipefail; ( set -Eeuo pipefail; "$@" ); rc=$?; set -Eeuo pipefail; if [[ "$rc" -eq 0 ]]; then success "操作完成：${title}"; elif [[ "$rc" -eq "$SKIP_RC" ]]; then warn "操作已跳过：${title}"; elif [[ "$rc" -eq "$CANCEL_RC" ]]; then warn "操作已取消：${title}"; else warn "操作未完成或执行失败：${title}，退出码：${rc}"; fi; menu_pause; }
menu_tools_config() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[常用工具配置]
1) 查看常用工具安装状态
2) 配置 Vim
3) 配置 Tmux
4) 配置 Git
5) 配置基础 Zsh
6) 配置 Vim + Tmux + Git + 基础 Zsh
7) 安装 Oh My Zsh
8) 安装 Oh My Zsh 插件
9) 安装 rupa/z
10) 初始化完整 Zsh 环境
11) 设置默认 Shell 为 zsh
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "查看常用工具安装状态" tools_status ;; 2) menu_action "配置 Vim" tools_config_vim ;; 3) menu_action "配置 Tmux" tools_config_tmux ;; 4) menu_action "配置 Git" tools_config_git ;; 5) menu_action "配置基础 Zsh" tools_config_zsh_basic ;; 6) menu_action "配置常用工具" tools_config_all ;; 7) menu_action "安装 Oh My Zsh" tools_install_oh_my_zsh ;; 8) menu_action "安装 Oh My Zsh 插件" tools_install_zsh_plugins ;; 9) menu_action "安装 rupa/z" tools_install_rupa_z ;; 10) menu_action "初始化完整 Zsh 环境" tools_config_zsh_full ;; 11) menu_action "设置默认 Shell 为 zsh" tools_change_shell_to_zsh ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_common_tools() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[常用工具]
1) 安装常用工具
2) 常用工具配置子菜单
3) 安装并初始化完整 Zsh 环境
4) 查看常用工具安装状态
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "安装常用工具" tools_install ;; 2) menu_tools_config ;; 3) menu_action "安装并初始化完整 Zsh 环境" tools_config_zsh_full ;; 4) menu_action "查看常用工具安装状态" tools_status ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_mirror() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[系统镜像源 / Homebrew 镜像]
1) 查看系统环境
2) 备份当前源
3) 切换系统源（官方/镜像/自定义）
4) 列出备份
5) 恢复备份
6) 刷新包缓存
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "查看系统环境" print_env ;; 2) menu_action "备份当前源" mirror_backup ;; 3) menu_action "切换系统源" menu_mirror_set ;; 4) menu_action "列出源备份" mirror_list_backups ;; 5) menu_action "恢复源备份" mirror_restore ;; 6) menu_action "刷新包缓存" refresh_pkg_cache ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_docker() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[Docker]
1) 安装 Docker CE / Docker Desktop
2) 配置 Docker Registry mirror
3) 逐个导出本地镜像为 tar.gz
4) 查看 Docker 状态
5) 卸载 Docker
6) 离线安装子菜单（下载/安装/打包/卸载）
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "安装 Docker" menu_docker_install ;; 2) menu_action "配置 Docker Registry mirror" docker_configure_registry_mirror ;; 3) menu_action "逐个导出本地镜像为 tar.gz" docker_save_images ;; 4) menu_action "查看 Docker 状态" menu_docker_status ;; 5) menu_action "卸载 Docker" docker_uninstall 0 ;; 6) menu_docker_offline ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_docker_offline() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[Docker 离线安装 - 二进制部署，无需网络/包管理器]
1) 下载 Docker & Compose 二进制资源
2) 从本地资源离线安装
3) 打包成离线部署包（自包含 .tar.gz）
4) 卸载（从离线安装的 Docker）
5) 查看状态
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "下载离线资源" offline_action_download ;; 2) menu_action "离线安装 Docker" offline_action_install ;; 3) menu_action "打包离线部署包" offline_action_package ;; 4) menu_action "卸载离线安装的 Docker" offline_action_uninstall ;; 5) menu_action "查看 Docker 状态" offline_action_status ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_firewall() { local c; while true; do menu_clear; echo "[防火墙] 当前优先：$(preferred_firewall)"; cat <<'EOF_MENU'
1) 安装防火墙
2) 查看状态
3) 启用
4) 停用
5) 放行端口/服务
6) 拒绝端口/移除放行
7) 卸载防火墙
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "安装防火墙" install_firewall ;; 2) menu_action "查看防火墙状态" firewall_status ;; 3) menu_action "启用防火墙" firewall_enable ;; 4) menu_action "停用防火墙" firewall_disable ;; 5) menu_action "放行端口/服务" firewall_allow ;; 6) menu_action "拒绝端口/移除放行" firewall_deny ;; 7) menu_action "卸载防火墙" uninstall_firewall ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_swap() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[Swap]
1) 查看 Swap
2) 增加 Swap 文件
3) 调整 Swap 文件大小
4) 删除 Swap
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "查看 Swap" swap_list ;; 2) menu_action "增加 Swap 文件" swap_add ;; 3) menu_action "调整 Swap 文件大小" swap_resize ;; 4) menu_action "删除 Swap" swap_delete ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_lvm() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[LVM]
1) 完整创建（空盘 → PV/VG/LV → 格式化/挂载/fstab）
2) 仅创建卷组 VG
3) 仅创建逻辑卷 LV
4) 扩容（VG 加盘 / LV + 文件系统扩容）
5) 删除（LV / VG / PV）
6) 查询（PV / VG / LV / 磁盘）
7) 磁盘信息
8) 大小格式帮助
9) 安装 lvm2
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "LVM 完整创建" lvm_menu_create ;; 2) menu_action "创建卷组 VG" lvm_menu_create_vg ;; 3) menu_action "创建逻辑卷 LV" lvm_menu_create_lv ;; 4) menu_action "LVM 扩容" lvm_menu_extend ;; 5) menu_action "LVM 删除" lvm_menu_delete ;; 6) menu_action "LVM 查询" lvm_menu_list ;; 7) menu_action "磁盘信息" lvm_menu_info ;; 8) lvm_size_help; menu_pause ;; 9) menu_action "安装 lvm2" ensure_lvm ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_perf() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[Linux/macOS 性能瓶颈排查]
1) 快速巡检
2) 安装/检查性能工具
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "快速性能巡检" perf_quick ;; 2) menu_action "安装/检查性能工具" ensure_perf_tools ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_service() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[服务管理 - systemd]
1) 列出运行中的服务
2) 查看服务状态
3) 重启服务
4) 启用服务（开机自启）
5) 禁用服务
6) 查看服务日志
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "列出服务" svc_list ;; 2) menu_action "查看服务状态" svc_status ;; 3) menu_action "重启服务" svc_restart ;; 4) menu_action "启用服务" svc_enable ;; 5) menu_action "禁用服务" svc_disable ;; 6) menu_action "查看服务日志" svc_logs ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_disk_cleanup() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[磁盘清理]
1) 查看磁盘使用概况
2) 清理 systemd journal 日志
3) 清理旧内核
4) 清理包管理器缓存
5) 清理 Docker 未使用资源
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "磁盘概况" disk_cleanup_summary ;; 2) menu_action "清理 Journal" disk_cleanup_journal ;; 3) menu_action "清理旧内核" disk_cleanup_old_kernels ;; 4) menu_action "清理包缓存" disk_cleanup_packages ;; 5) menu_action "清理 Docker" disk_cleanup_docker ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_ssl() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[SSL 证书检查]
1) 检查单个域名证书
2) 批量检查证书（从文件读取域名列表）
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "检查 SSL 证书" ssl_check ;; 2) menu_action "批量检查 SSL" ssl_check_batch ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_system_update() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[系统更新]
1) 检查可用更新
2) 仅安装安全更新
3) 更新所有软件包
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "检查更新" system_update_check ;; 2) menu_action "安装安全更新" system_update_security ;; 3) menu_action "更新所有包" system_update_all ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_health() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[主机巡检]
1) 执行巡检
2) 生成巡检报告并保存
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "主机巡检" health_check ;; 2) menu_action "生成巡检报告" health_report ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_user() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[用户与 SSH]
1) 列出用户 / sudo / 空密码 / UID 0
2) 查看用户详情
3) 创建用户
4) 锁定用户
5) 解锁用户
6) 设置账号过期
7) 授予 sudo
8) 取消 toolkit sudo
9) 列出公钥
10) 添加公钥
11) 删除公钥
12) SSH 配置审计
13) 应用 SSH 安全基线
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "列出用户" user_list ;; 2) menu_action "用户详情" user_info ;; 3) menu_action "创建用户" user_add ;; 4) menu_action "锁定用户" user_lock ;; 5) menu_action "解锁用户" user_unlock ;; 6) menu_action "设置过期" user_expire ;; 7) menu_action "授予 sudo" user_sudo_add ;; 8) menu_action "取消 sudo" user_sudo_del ;; 9) menu_action "列出公钥" user_keys ;; 10) menu_action "添加公钥" user_key_add ;; 11) menu_action "删除公钥" user_key_del ;; 12) menu_action "SSH 审计" ssh_harden_audit ;; 13) menu_action "SSH 加固" ssh_harden_apply ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_cron() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[定时任务]
1) 查看某用户 crontab
2) 查看系统 cron（/etc/cron*）
3) 查看 systemd timers
4) 查看全部
5) 追加 crontab 行
6) 删除 crontab 行
7) 备份 crontab
8) 恢复 crontab
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "用户 crontab" cron_list ;; 2) menu_action "系统 cron" cron_list system ;; 3) menu_action "systemd timers" cron_timers ;; 4) menu_action "全部定时任务" cron_list all ;; 5) menu_action "追加 crontab" cron_add ;; 6) menu_action "删除 crontab" cron_remove ;; 7) menu_action "备份 crontab" cron_backup ;; 8) menu_action "恢复 crontab" cron_restore ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_log() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[日志与排障]
1) 查看 journal（按单元/优先级/时间）
2) 最近关键事件（OOM/IO/重启/登录失败）
3) 在 /var/log 搜索关键词
4) 打包故障现场
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "查看 journal" log_journal ;; 2) menu_action "关键事件" log_events ;; 3) menu_action "日志搜索" log_search ;; 4) menu_action "打包现场" log_collect ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_net() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[网络诊断]
1) 本机地址 / 路由 / DNS
2) 监听端口
3) 查看端口占用
4) DNS 解析
5) ping
6) TCP 端口探测
7) 路由 / traceroute
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "网络信息" net_info ;; 2) menu_action "监听端口" net_listen ;; 3) menu_action "端口占用" net_who ;; 4) menu_action "DNS 解析" net_dns ;; 5) menu_action "ping" net_ping ;; 6) menu_action "TCP 探测" net_probe ;; 7) menu_action "路由" net_route ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_sysconf() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[系统配置]
1) 主机名
2) 时区
3) 查看时间 / 同步状态
4) 启用时间同步
5) 查看 /etc/hosts
6) 添加 hosts 记录
7) 删除 hosts 记录
8) 查看常用 sysctl
9) 临时设置 sysctl
10) 持久化 sysctl
11) 查看 limits
12) 设置 limits
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "主机名" sysconf_hostname ;; 2) menu_action "时区" sysconf_timezone ;; 3) menu_action "时间状态" sysconf_time ;; 4) menu_action "启用 NTP" sysconf_ntp enable ;; 5) menu_action "查看 hosts" sysconf_hosts list ;; 6) menu_action "添加 hosts" sysconf_hosts add ;; 7) menu_action "删除 hosts" sysconf_hosts del ;; 8) menu_action "sysctl 列表" sysconf_sysctl list ;; 9) menu_action "临时 sysctl" sysconf_sysctl set ;; 10) menu_action "持久化 sysctl" sysconf_sysctl persist ;; 11) menu_action "查看 limits" sysconf_limits show ;; 12) menu_action "设置 limits" sysconf_limits set ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_disk() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[磁盘与文件系统]
1) 磁盘 / 挂载一览
2) SMART 健康
3) 检查 fstab
4) 扩容文件系统（非 LVM）
5) 大目录 / 大文件
6) 已删除但仍占用空间
7) inode 使用
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "磁盘一览" disk_list ;; 2) menu_action "SMART" disk_smart ;; 3) menu_action "检查 fstab" disk_fstab ;; 4) menu_action "扩容文件系统" disk_grow ;; 5) menu_action "大文件" disk_large ;; 6) menu_action "已删占用" disk_deleted ;; 7) menu_action "inode" disk_inode ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_proc() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[进程与资源]
1) CPU Top
2) 内存 Top
3) 打开文件数 Top
4) IO 粗览
5) 端口对应进程
6) 文件/PID 占用
7) 向进程发信号
8) 查看 cgroup / 容器归属
9) 资源简报（为什么可能慢）
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "CPU Top" proc_top cpu ;; 2) menu_action "内存 Top" proc_top mem ;; 3) menu_action "fd Top" proc_top fd ;; 4) menu_action "IO" proc_top io ;; 5) menu_action "端口进程" proc_port ;; 6) menu_action "文件占用" proc_files ;; 7) menu_action "kill" proc_kill ;; 8) menu_action "cgroup" proc_cgroup ;; 9) menu_action "资源简报" proc_report ;; 0) return ;; *) menu_invalid ;; esac; done; }
main_menu() { local c; while true; do menu_clear; cat <<EOF_MENU
Linux/macOS Admin Toolkit v${TOOL_VERSION}
系统：${OS_NAME} (${PLATFORM:-unknown})    包管理器：${PKG_MANAGER:-unknown}$( [[ "$DRY_RUN" -eq 1 ]] && printf '    [dry-run 模式：只打印不执行]' )

1) 常用工具安装/配置
2) 系统镜像源 / Homebrew 镜像
3) Docker
4) 防火墙 ufw/firewalld/macOS Application Firewall
5) Swap 管理
6) LVM 管理
7) 性能瓶颈排查
8) 服务管理 (systemd)
9) 磁盘清理
10) SSL 证书检查
11) 系统更新
12) 查看系统环境
13) 主机巡检
14) 用户与 SSH
15) 定时任务
16) 日志与排障
17) 网络诊断
18) 系统配置（主机名/时区/hosts/sysctl）
19) 磁盘与文件系统
20) 进程与资源
0) 退出
EOF_MENU
read -r -p "请选择: " c; case "${c:-}" in 1) menu_common_tools ;; 2) menu_mirror ;; 3) menu_docker ;; 4) menu_firewall ;; 5) menu_swap ;; 6) menu_lvm ;; 7) menu_perf ;; 8) menu_service ;; 9) menu_disk_cleanup ;; 10) menu_ssl ;; 11) menu_system_update ;; 12) menu_action "查看系统环境" print_env ;; 13) menu_health ;; 14) menu_user ;; 15) menu_cron ;; 16) menu_log ;; 17) menu_net ;; 18) menu_sysconf ;; 19) menu_disk ;; 20) menu_proc ;; 0) exit 0 ;; *) menu_invalid ;; esac; done; }

# ---------- CLI ----------
usage() { cat <<EOF_USAGE
用法：
  $PROGRAM_NAME [全局选项] [模块] [动作] [参数]

全局选项（可放在命令行任意位置）：
  -y, --yes       默认确认
  -n, --dry-run   只打印不执行
  --no-color      禁用颜色
  -h, --help      查看帮助（仅开头位置）

模块与动作：
  tools        install | status | config [all|vim|tmux|git|zsh-basic] | oh-my-zsh | zsh-plugins | install-z | zsh-full | chsh-zsh
  mirror       backup | set [--source 源] | list-backups | restore [名称] | refresh
  docker       install [--source 源] | mirror [--registry URL] | save-images [--dir 目录] | status | uninstall [--remove-data 1]
  docker-offline  download | install | package | uninstall | status | help（选项见 help）
  firewall     install | status | enable | disable | allow <规则> | deny <规则> | uninstall
  swap         list | add [--size N] [--path 路径] | resize [--size N] [--path 路径] | delete [--path 路径]
  lvm          create | create-vg | create-lv | create-pv | extend | delete | list | info | sizes | install | help
  perf         quick | install-tools
  service      list | status <服务> | restart <服务> | enable <服务> | disable <服务> | logs <服务> [行数]
  disk-cleanup summary | journal [--days N] | old-kernels | packages | docker
  ssl-check    <域名> [端口]（默认 443）
  ssl-check-batch <文件>
  system-update check | security | all
  health       check | report [--out 文件]
  user         list | info <用户> | add <用户> [--groups g] [--shell /bin/bash] | lock | unlock | expire <用户> [YYYY-MM-DD]
               sudo-add | sudo-del | keys | key-add <用户> [公钥|文件] | key-del <用户> <行号|关键词>
  ssh-harden   audit | apply [--no-root-login] [--no-password] [--port N] [--allow-users u1,u2]
  cron         list [用户|system|timers|all] | add [用户] [行] | remove [用户] [行号|关键词] | backup [用户|all] | restore <文件> [用户] | timers
  log          journal [单元] [优先级] [since] [行数] | events [小时] | search <关键词> [路径] | collect [--hours N] [--out 文件]
  net          info | listen [端口] | who <端口> | dns [域名] | ping <主机> | probe <host:port> | route [目标]
  sysconf      hostname [名称] | timezone [区] | time | ntp [status|enable] | hosts [list|add <ip> <名>|del <名>]
               sysctl [list|set key=val|persist key=val] | limits [show|set <项> <值>]
  disk         list | smart [设备] | fstab | grow <挂载点|设备> | large [路径] [条数] | deleted | inode
  proc         top [cpu|mem|fd|io] | port <端口> | files <PID|路径> | kill <PID> [信号] | cgroup [PID] | report

模块示例：
  $PROGRAM_NAME menu
  $PROGRAM_NAME env
  $PROGRAM_NAME tools install
  $PROGRAM_NAME mirror set --source tuna
  $PROGRAM_NAME docker install --source tuna
  $PROGRAM_NAME docker mirror --registry https://registry.example.com
  $PROGRAM_NAME docker-offline download --docker-version 28.5.1
  $PROGRAM_NAME docker-offline install --resource-dir ./resources
  $PROGRAM_NAME docker-offline package --package-file docker-offline.tar.gz
  $PROGRAM_NAME docker-offline uninstall
  $PROGRAM_NAME firewall status
  $PROGRAM_NAME swap add --size 4G --path /swapfile
  $PROGRAM_NAME lvm list [pvs|vgs|lvs|disk|all]
  $PROGRAM_NAME lvm info -d /dev/sdb
  $PROGRAM_NAME lvm create -d /dev/sdb -v vg_data -l lv_data -s 100G -f xfs -m /data
  $PROGRAM_NAME lvm create-vg -d /dev/sdb -v vg_data
  $PROGRAM_NAME lvm create-lv -v vg_data -l lv_data -s 100G -f ext4 -m /data
  $PROGRAM_NAME lvm extend -v vg_data -d /dev/sdc
  $PROGRAM_NAME lvm extend -v vg_data -l lv_data -s +50G
  $PROGRAM_NAME lvm delete -v vg_data -l lv_data
  $PROGRAM_NAME lvm delete -v vg_data
  $PROGRAM_NAME lvm delete -d /dev/sdc
  $PROGRAM_NAME lvm sizes
  $PROGRAM_NAME perf quick
  $PROGRAM_NAME service list
  $PROGRAM_NAME service status <服务名>
  $PROGRAM_NAME service restart <服务名>
  $PROGRAM_NAME disk-cleanup summary
  $PROGRAM_NAME disk-cleanup journal --days 7
  $PROGRAM_NAME disk-cleanup old-kernels
  $PROGRAM_NAME disk-cleanup packages
  $PROGRAM_NAME disk-cleanup docker
  $PROGRAM_NAME ssl-check example.com
  $PROGRAM_NAME ssl-check example.com:8443
  $PROGRAM_NAME ssl-check-batch domains.txt
  $PROGRAM_NAME system-update check
  $PROGRAM_NAME system-update security
  $PROGRAM_NAME system-update all
  $PROGRAM_NAME health check
  $PROGRAM_NAME health report --out /tmp/health.txt
  $PROGRAM_NAME user list
  $PROGRAM_NAME user add deploy --groups docker,sudo
  $PROGRAM_NAME user key-add deploy ~/.ssh/id_ed25519.pub
  $PROGRAM_NAME ssh-harden audit
  $PROGRAM_NAME ssh-harden apply --no-root-login --no-password
  $PROGRAM_NAME cron list all
  $PROGRAM_NAME cron add root '0 3 * * * /usr/local/bin/backup.sh'
  $PROGRAM_NAME log events 24
  $PROGRAM_NAME log collect --hours 2 --out /tmp/incident.tgz
  $PROGRAM_NAME net info
  $PROGRAM_NAME net probe 1.1.1.1:443
  $PROGRAM_NAME sysconf hostname web-01
  $PROGRAM_NAME sysconf timezone Asia/Shanghai
  $PROGRAM_NAME sysconf sysctl persist vm.swappiness=10
  $PROGRAM_NAME disk list
  $PROGRAM_NAME disk fstab
  $PROGRAM_NAME disk grow /data
  $PROGRAM_NAME proc top mem
  $PROGRAM_NAME proc report
EOF_USAGE
}
get_opt_value() { local key="$1" arg next; shift || true; while [[ "$#" -gt 0 ]]; do arg="$1"; case "$arg" in "$key") shift || true; next="${1:-}"; [[ -n "$next" && "$next" != -* ]] || return 1; printf '%s' "$next"; return 0 ;; "$key"=*) printf '%s' "${arg#*=}"; return 0 ;; esac; shift || true; done; return 1; }
# ---------- CLI 分发 ----------
cmd_tools() {
  local action="${2:-}"
  case "$action" in
    install) tools_install ;;
    status) tools_status ;;
    config) case "${3:-all}" in all) tools_config_all ;; vim) tools_config_vim ;; tmux) tools_config_tmux ;; git) tools_config_git ;; zsh-basic) tools_config_zsh_basic ;; *) fatal "未知 tools config 动作：${3:-}" ;; esac ;;
    oh-my-zsh) tools_install_oh_my_zsh "$(get_opt_value --github-proxy "$@" || true)" ;;
    zsh-plugins) tools_install_zsh_plugins "$(get_opt_value --github-proxy "$@" || true)" ;;
    install-z) tools_install_rupa_z "$(get_opt_value --github-proxy "$@" || true)" ;;
    zsh-full) tools_config_zsh_full ;;
    chsh-zsh) tools_change_shell_to_zsh ;;
    *) fatal "未知 tools 动作：${action:-}" ;;
  esac
}
cmd_mirror() {
  local action="${2:-}"
  case "$action" in
    backup) mirror_backup ;;
    set) mirror_set "$(get_opt_value --source "$@" || printf '%s' "$DEFAULT_SOURCE")" ;;
    list-backups) mirror_list_backups ;;
    restore) mirror_restore "${3:-}" ;;
    refresh) refresh_pkg_cache ;;
    *) fatal "未知 mirror 动作：${action:-}" ;;
  esac
}
cmd_docker() {
  local action="${2:-}"
  case "$action" in
    install) docker_install "$(get_opt_value --source "$@" || printf '%s' "$DEFAULT_DOCKER_SOURCE")" ;;
    mirror) docker_configure_registry_mirror "$(get_opt_value --registry "$@" || true)" ;;
    save-images) docker_save_images "$(get_opt_value --dir "$@" || true)" ;;
    status) menu_docker_status ;;
    uninstall) docker_uninstall "$(get_opt_value --remove-data "$@" || printf '0')" ;;
    *) fatal "未知 docker 动作：${action:-}" ;;
  esac
}
cmd_firewall() {
  local action="${2:-}"
  case "$action" in
    install) install_firewall ;;
    status) firewall_status ;;
    enable) firewall_enable ;;
    disable) firewall_disable ;;
    allow) firewall_allow "${3:-}" ;;
    deny) firewall_deny "${3:-}" ;;
    uninstall) uninstall_firewall ;;
    *) fatal "未知 firewall 动作：${action:-}" ;;
  esac
}
cmd_swap() {
  local action="${2:-}"
  case "$action" in
    list) swap_list ;;
    add) swap_add "$(get_opt_value --size "$@" || true)" "$(get_opt_value --path "$@" || printf '/swapfile')" ;;
    resize) swap_resize "$(get_opt_value --size "$@" || true)" "$(get_opt_value --path "$@" || printf '/swapfile')" ;;
    delete) swap_delete "$(get_opt_value --path "$@" || true)" ;;
    *) fatal "未知 swap 动作：${action:-}" ;;
  esac
}
cmd_docker_offline() {
  local action="${2:-}"
  case "$action" in
    help) cat <<'EOF_OFFLINE_HELP'
docker-offline 模块：离线二进制安装 Docker Engine + Docker Compose

动作：
  download   下载 Docker/Compose 二进制到资源目录
  install    从本地资源离线安装
  package    下载并打包成自包含 .tar.gz 离线部署包
  uninstall  卸载通过离线方式安装的 Docker
  status     查看当前 Docker 运行状态

选项：
  --resource-dir DIR       资源目录，默认 ./resources
  --docker-version VER     Docker 版本，默认 latest
  --compose-version VER    Compose 版本，默认 latest
  --arch ARCH              架构：x86_64 / aarch64
  --download-if-missing    install 时资源缺失则自动下载
  --skip-docker / --skip-compose  跳过 Docker/Compose
  --no-start / --no-enable  不启动/不开机自启
  --data-root DIR          设置 Docker data-root
  --registry-mirror URL    设置 registry mirror
  --package-file FILE      package 输出文件名
  --purge-data             uninstall 时同时删除数据
EOF_OFFLINE_HELP
    ;;
    status) offline_action_status ;;
    *)
      shift 2
      offline_parse_args "$@"
      case "$action" in
        download) offline_action_download ;;
        install) offline_action_install ;;
        package) offline_action_package ;;
        uninstall) offline_action_uninstall ;;
        *) fatal "未知 docker-offline 动作：${action:-}。支持：download/install/package/uninstall/status/help" ;;
      esac
      ;;
  esac
}
cmd_service() {
  local action="${2:-}"
  case "$action" in
    list) svc_list ;;
    status) svc_status "${3:-}" ;;
    restart) svc_restart "${3:-}" ;;
    enable) svc_enable "${3:-}" ;;
    disable) svc_disable "${3:-}" ;;
    logs) svc_logs "${3:-}" "${4:-50}" ;;
    *) fatal "未知 service 动作：${action:-}。支持：list/status/restart/enable/disable/logs" ;;
  esac
}
cmd_disk_cleanup() {
  local action="${2:-}"
  case "$action" in
    summary) disk_cleanup_summary ;;
    journal) disk_cleanup_journal "$(get_opt_value --days "$@" || printf '7')" ;;
    old-kernels) disk_cleanup_old_kernels ;;
    packages) disk_cleanup_packages ;;
    docker) disk_cleanup_docker ;;
    *) fatal "未知 disk-cleanup 动作：${action:-}。支持：summary/journal/old-kernels/packages/docker" ;;
  esac
}
cmd_perf() {
  local action="${2:-quick}"
  case "$action" in
    quick) perf_quick ;;
    install-tools) ensure_perf_tools ;;
    *) fatal "未知 perf 动作：${action:-}" ;;
  esac
}
cmd_system_update() {
  local action="${2:-}"
  case "$action" in
    check) system_update_check ;;
    security) system_update_security ;;
    all) system_update_all ;;
    *) fatal "未知 system-update 动作：${action:-}。支持：check/security/all" ;;
  esac
}
cmd_health() {
  local action="${2:-check}"
  case "$action" in
    check) health_run_checks ;;
    report) health_report "$(get_opt_value --out "$@" || true)" ;;
    *) fatal "未知 health 动作：${action:-}。支持：check/report" ;;
  esac
}
cmd_user() {
  local action="${2:-list}"
  case "$action" in
    list) user_list ;;
    info) user_info "${3:-}" ;;
    add) user_add "${3:-}" "$(get_opt_value --groups "$@" || true)" "$(get_opt_value --shell "$@" || printf /bin/bash)" ;;
    lock) user_lock "${3:-}" ;;
    unlock) user_unlock "${3:-}" ;;
    expire) user_expire "${3:-}" "${4:-}" ;;
    sudo-add) user_sudo_add "${3:-}" ;;
    sudo-del) user_sudo_del "${3:-}" ;;
    keys) user_keys "${3:-}" ;;
    key-add) user_key_add "${3:-}" "${4:-}" ;;
    key-del) user_key_del "${3:-}" "${4:-}" ;;
    *) fatal "未知 user 动作：${action:-}。支持：list/info/add/lock/unlock/expire/sudo-add/sudo-del/keys/key-add/key-del" ;;
  esac
}
cmd_ssh_harden() {
  local action="${2:-audit}"
  case "$action" in
    audit) ssh_harden_audit ;;
    apply) shift 2 || true; ssh_harden_apply "$@" ;;
    *) fatal "未知 ssh-harden 动作：${action:-}。支持：audit/apply" ;;
  esac
}
cmd_cron() {
  local action="${2:-list}"
  case "$action" in
    list) cron_list "${3:-}" ;;
    add) cron_add "${3:-}" "${4:-}" ;;
    remove|del|rm) cron_remove "${3:-}" "${4:-}" ;;
    backup) cron_backup "${3:-}" ;;
    restore) cron_restore "${3:-}" "${4:-}" ;;
    timers|timer) cron_timers ;;
    *) fatal "未知 cron 动作：${action:-}。支持：list/add/remove/backup/restore/timers" ;;
  esac
}
cmd_log() {
  local action="${2:-events}"
  case "$action" in
    journal) log_journal "${3:-}" "${4:-}" "${5:-}" "${6:-100}" ;;
    events) log_events "${3:-24}" ;;
    search) log_search "${3:-}" "${4:-/var/log}" ;;
    collect) log_collect "$(get_opt_value --hours "$@" || printf 2)" "$(get_opt_value --out "$@" || true)" ;;
    *) fatal "未知 log 动作：${action:-}。支持：journal/events/search/collect" ;;
  esac
}
cmd_net() {
  local action="${2:-info}"
  case "$action" in
    info) net_info ;;
    listen) net_listen "${3:-}" ;;
    who) net_who "${3:-}" ;;
    dns) net_dns "${3:-}" ;;
    ping) net_ping "${3:-}" ;;
    probe) net_probe "${3:-}" ;;
    route) net_route "${3:-}" ;;
    *) fatal "未知 net 动作：${action:-}。支持：info/listen/who/dns/ping/probe/route" ;;
  esac
}
cmd_sysconf() {
  local action="${2:-}"
  case "$action" in
    hostname) sysconf_hostname "${3:-}" ;;
    timezone|tz) sysconf_timezone "${3:-}" ;;
    time) sysconf_time ;;
    ntp) sysconf_ntp "${3:-status}" ;;
    hosts) sysconf_hosts "${3:-list}" "${4:-}" "${5:-}" ;;
    sysctl) sysconf_sysctl "${3:-list}" "${4:-}" ;;
    limits) sysconf_limits "${3:-show}" "${4:-}" "${5:-}" ;;
    *) fatal "未知 sysconf 动作：${action:-}。支持：hostname/timezone/time/ntp/hosts/sysctl/limits" ;;
  esac
}
cmd_disk() {
  local action="${2:-list}"
  case "$action" in
    list) disk_list ;;
    smart) disk_smart "${3:-}" ;;
    fstab) disk_fstab ;;
    grow) disk_grow "${3:-}" ;;
    large) disk_large "${3:-/}" "${4:-15}" ;;
    deleted) disk_deleted ;;
    inode) disk_inode ;;
    *) fatal "未知 disk 动作：${action:-}。支持：list/smart/fstab/grow/large/deleted/inode" ;;
  esac
}
cmd_proc() {
  local action="${2:-report}"
  case "$action" in
    top) proc_top "${3:-cpu}" ;;
    port) proc_port "${3:-}" ;;
    files) proc_files "${3:-}" ;;
    kill) proc_kill "${3:-}" "${4:-TERM}" ;;
    cgroup) proc_cgroup "${3:-}" ;;
    report) proc_report ;;
    *) fatal "未知 proc 动作：${action:-}。支持：top/port/files/kill/cgroup/report" ;;
  esac
}
main() {
  detect_os; load_config; audit_log "START: $0 $*"
  local module="${1:-menu}" rest=()
  # 全局选项任意位置：-y/--yes、-n/--dry-run、--no-color；-h/--help 仅在开头
  while [[ "$#" -gt 0 ]]; do
    case "${1:-}" in
      -y|--yes) ASSUME_YES=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) break ;;
    esac
  done
  module="${1:-menu}"; shift || true
  while [[ "$#" -gt 0 ]]; do
    case "${1:-}" in
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      --no-color) NO_COLOR=1 ;;
      *) rest+=("$1") ;;
    esac
    shift
  done
  set -- "${rest[@]}"
  # 权限统一：纯查询类无需 root，变更类需要
  case "$module" in
    env|perf|ssl-check|ssl-check-batch|health|net) : ;;
    log)
      case "${1:-}" in collect) require_root "$@" ;; *) : ;; esac
      ;;
    proc)
      case "${1:-}" in kill) require_root "$@" ;; *) : ;; esac
      ;;
    disk)
      case "${1:-}" in grow|smart) require_root "$@" ;; *) : ;; esac
      ;;
    user)
      case "${1:-}" in list|info|keys) : ;; *) require_root "$@" ;; esac
      ;;
    *) require_root "$@" ;;
  esac
  case "$module" in
    menu|"") main_menu ;;
    env) print_env ;;
    tools) cmd_tools "$module" "$@" ;;
    mirror) cmd_mirror "$module" "$@" ;;
    docker) cmd_docker "$module" "$@" ;;
    docker-offline) cmd_docker_offline "$module" "$@" ;;
    firewall) cmd_firewall "$module" "$@" ;;
    swap) cmd_swap "$module" "$@" ;;
    lvm) lvm_main "$@" ;;
    perf) cmd_perf "$module" "$@" ;;
    service) cmd_service "$module" "$@" ;;
    disk-cleanup) cmd_disk_cleanup "$module" "$@" ;;
    ssl-check) ssl_check "${1:-}" "${2:-443}" ;;
    ssl-check-batch) ssl_check_batch "${1:-}" ;;
    system-update) cmd_system_update "$module" "$@" ;;
    health) cmd_health "$module" "$@" ;;
    user) cmd_user "$module" "$@" ;;
    ssh-harden) cmd_ssh_harden "$module" "$@" ;;
    cron) cmd_cron "$module" "$@" ;;
    log) cmd_log "$module" "$@" ;;
    net) cmd_net "$module" "$@" ;;
    sysconf) cmd_sysconf "$module" "$@" ;;
    disk) cmd_disk "$module" "$@" ;;
    proc) cmd_proc "$module" "$@" ;;
    *) usage; fatal "未知模块：${module}" ;;
  esac
}
main "$@"
