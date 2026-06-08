#!/usr/bin/env bash
# Linux/macOS Admin Toolkit
# Linux 与 macOS 软件安装、Shell 环境、Docker、防火墙、Swap/LVM、性能排查管理脚本。
# 默认使用官方源，也内置中国大陆常用镜像源，适合不同网络环境。
# Linux 支持：Arch Linux、Kylin V10、CentOS/CentOS Stream、Ubuntu、Debian、Fedora 及常见衍生系统。
# macOS 支持：Homebrew、常用工具、Zsh/Oh My Zsh、rupa/z、Docker Desktop、基础性能排查。

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME="$(basename "$0")"
TOOL_VERSION="0.3.4"
ASSUME_YES=0
DRY_RUN=0
NO_COLOR=0
PKG_UPDATED=0
BACKUP_ROOT="/var/backups/linux-admin-toolkit"
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
OFFLINE_DOCKER_URL_TEMPLATE="https://download.docker.com/linux/static/{channel}/{arch}/docker-{version}.tgz"
OFFLINE_COMPOSE_URL_TEMPLATE="https://github.com/docker/compose/releases/download/v{version}/docker-compose-linux-{arch}"
OFFLINE_COMPOSE_LATEST_URL_TEMPLATE="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-{arch}"
OFFLINE_DOCKER_ARCH=""
OFFLINE_COMPOSE_ARCH=""
GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-}"
CHOSEN_MIRROR_SOURCE=""
OS_ID=""; OS_LIKE=""; OS_NAME=""; OS_VERSION_ID=""; OS_CODENAME=""; PKG_MANAGER=""; PLATFORM=""

_color() { local code="$1"; shift || true; if [[ "$NO_COLOR" -eq 1 || ! -t 1 ]]; then printf '%s\n' "$*"; else printf '\033[%sm%s\033[0m\n' "$code" "$*"; fi; }
info() { _color "1;34" "[INFO] $*"; }
success() { _color "1;32" "[OK] $*"; }
warn() { _color "1;33" "[WARN] $*"; }
error() { _color "1;31" "[ERROR] $*" >&2; }
fatal() { error "$*"; exit 1; }

format_cmd() { local arg quoted out=""; for arg in "$@"; do printf -v quoted '%q' "$arg"; out="${out}${out:+ }${quoted}"; done; printf '%s' "$out"; }
run() { info "+ $(format_cmd "$@")"; [[ "$DRY_RUN" -eq 1 ]] && return 0; "$@"; }
run_shell() { info "+ $*"; [[ "$DRY_RUN" -eq 1 ]] && return 0; bash -Eeuo pipefail -c "$*"; }
cmd_path() { local cmd="${1:-}" d; [[ -n "$cmd" ]] || return 1; command -v "$cmd" 2>/dev/null && return 0; for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin /usr/bin /bin /usr/sbin /sbin; do [[ -x "$d/$cmd" ]] && { printf '%s\n' "$d/$cmd"; return 0; }; done; return 1; }
has_cmd() { cmd_path "${1:-}" >/dev/null 2>&1; }
trim_string() { local s="${1:-}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
has_unsafe_url_chars() { local v="${1:-}"; [[ "$v" == *"'"* || "$v" == *\"* || "$v" == *"\`"* || "$v" == *"\\"* || "$v" == *";"* || "$v" == *"|"* || "$v" =~ [[:space:]] ]]; }
confirm() { local prompt="${1:-确认继续？}" ans; [[ "$ASSUME_YES" -eq 1 ]] && return 0; echo >&2; echo "$prompt" >&2; echo "1) 是，继续" >&2; echo "2) 否，取消" >&2; read -r -p "请选择 [2]: " ans; case "${ans:-}" in 1|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac; }
cancelled() { warn "用户取消操作。"; return "$CANCEL_RC"; }
skipped() { warn "$*"; return "$SKIP_RC"; }
not_applicable() { skipped "$*"; }
menu_pause() { [[ -t 0 ]] && read -r -p "按 Enter 返回当前菜单..." _ || true; }
run_privileged() { if [[ "${EUID}" -eq 0 ]]; then run "$@"; else has_cmd sudo || fatal "需要管理员权限，但未找到 sudo。"; run sudo "$@"; fi; }
write_file() { local file="$1" dir; dir="$(dirname "$file")"; if [[ "$DRY_RUN" -eq 1 ]]; then info "+ write file $file"; cat >/dev/null; return 0; fi; mkdir -p "$dir"; cat > "$file"; }
append_file() { local file="$1" dir; dir="$(dirname "$file")"; if [[ "$DRY_RUN" -eq 1 ]]; then info "+ append file $file"; cat >/dev/null; return 0; fi; mkdir -p "$dir"; cat >> "$file"; }
append_line_if_missing() { local file="$1" line="$2" dir; dir="$(dirname "$file")"; [[ "$DRY_RUN" -eq 1 ]] && { info "+ append line to $file if missing: $line"; return 0; }; mkdir -p "$dir"; touch "$file"; grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"; }
backup_file_if_exists() { local file="$1"; [[ -e "$file" ]] || return 0; run cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"; }

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
is_macos && { brew_bin >/dev/null 2>&1 && echo "Homebrew：$(brew_bin)" || echo "Homebrew：未安装"; }
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
install_common_tools() { if is_macos; then ensure_brew; brew_install curl wget vim git htop tmux zsh unzip jq rsync netcat bind lsof iftop nload || return 1; warn "macOS 的 ping/ifconfig 通常为系统自带；iotop/sysstat 在 macOS 上不可完全等价，脚本不会强制安装。"; verify_common_tools; return $?; fi; case "$PKG_MANAGER" in apt) pkg_install curl wget vim git htop tmux zsh unzip jq rsync netcat-openbsd dnsutils iputils-ping net-tools lsof iotop iftop nload sysstat ;; dnf|yum) pkg_install curl wget vim-enhanced git htop tmux zsh unzip jq rsync nc bind-utils iputils net-tools lsof iotop iftop nload sysstat ;; pacman) pkg_install curl wget vim git htop tmux zsh unzip jq rsync openbsd-netcat bind iputils net-tools lsof iotop iftop nload sysstat ;; *) fatal "未检测到支持的包管理器。" ;; esac; verify_common_tools; }
verify_common_tools() { local item name cmd missing=""; while IFS= read -r item; do [[ -n "$item" ]] || continue; name="${item%%:*}"; cmd="${item#*:}"; [[ "$cmd" == "$item" ]] && cmd="$name"; if ! has_cmd "$cmd"; then if is_macos && [[ "$name" == "iotop" || "$name" == "sysstat" ]]; then warn "macOS 暂不强制检查 ${name}。"; else missing="${missing}\n  - ${name}"; fi; fi; done < <(common_tool_commands); [[ -n "$missing" ]] && { warn "以下常用工具命令仍然缺失：$(printf '%b' "$missing")"; return 1; }; success "常用工具安装并校验完成。"; }
tool_status() { local item name cmd missing=0 path; echo "目标用户：$(target_user_name)"; echo "用户目录：$(target_user_home)"; echo; printf '%-18s %s\n' "工具" "状态"; printf '%-18s %s\n' "----" "----"; while IFS= read -r item; do [[ -n "$item" ]] || continue; name="${item%%:*}"; cmd="${item#*:}"; [[ "$cmd" == "$item" ]] && cmd="$name"; if path="$(cmd_path "$cmd" 2>/dev/null)"; then printf '%-18s %s\n' "$name" "已安装 (${path})"; else printf '%-18s %s\n' "$name" "缺失"; missing=$((missing + 1)); fi; done < <(common_tool_commands); echo; [[ "$missing" -gt 0 ]] && warn "缺少 ${missing} 个命令，可先执行 '安装常用工具'。" || success "常用工具命令检测通过。"; }
configure_vim() { ensure_target_home; local home file; home="$(target_user_home)"; file="$home/.vimrc"; backup_file_if_exists "$file"; write_file "$file" <<'EOF_VIM'
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
configure_tmux() { ensure_target_home; local home file; home="$(target_user_home)"; file="$home/.tmux.conf"; backup_file_if_exists "$file"; write_file "$file" <<'EOF_TMUX'
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
configure_git() { ensure_target_home; local home file; home="$(target_user_home)"; file="$home/.gitconfig"; backup_file_if_exists "$file"; write_file "$file" <<'EOF_GIT'
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
configure_zsh_basic() { ensure_target_home; local home zshrc block; home="$(target_user_home)"; zshrc="$home/.zshrc"; block='export EDITOR=vim
export PAGER=less
setopt autocd 2>/dev/null || true
setopt share_history 2>/dev/null || true
HISTSIZE=10000
SAVEHIST=10000
alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"'; write_managed_block "$zshrc" "zsh-basic" "$block"; success "Zsh 基础配置完成。"; }
remove_managed_block() { local file="$1" name="$2" begin end tmp; [[ -f "$file" ]] || return 0; [[ "$DRY_RUN" -eq 1 ]] && { info "+ remove managed block '$name' from $file"; return 0; }; begin="# >>> Linux Admin Toolkit: ${name} >>>"; end="# <<< Linux Admin Toolkit: ${name} <<<"; tmp="$(mktemp)"; awk -v b="$begin" -v e="$end" '$0 == b {skip=1; next} $0 == e {skip=0; next} skip != 1 {print}' "$file" > "$tmp"; cat "$tmp" > "$file"; rm -f "$tmp"; }
write_managed_block() { local file="$1" name="$2" content="$3" dir begin end; dir="$(dirname "$file")"; [[ "$DRY_RUN" -eq 1 ]] && { info "+ write managed block '$name' to $file"; return 0; }; run mkdir -p "$dir"; [[ -f "$file" ]] || run touch "$file"; remove_managed_block "$file" "$name"; begin="# >>> Linux Admin Toolkit: ${name} >>>"; end="# <<< Linux Admin Toolkit: ${name} <<<"; { printf '\n%s\n' "$begin"; printf '%s\n' "$content"; printf '%s\n' "$end"; } | append_file "$file"; chown_target "$file"; }

# ---------- Zsh / GitHub ----------
is_http_url() { [[ "${1:-}" =~ ^https?:// ]]; }
validate_url_value() { local url="${1:-}"; is_http_url "$url" || fatal "URL 必须以 http:// 或 https:// 开头：$url"; ! has_unsafe_url_chars "$url" || fatal "URL 含有空白、引号或 shell 特殊字符，已拒绝：$url"; }
ask_github_proxy() { local input proxy; proxy="${GITHUB_PROXY_PREFIX:-}"; if [[ -t 0 ]]; then echo "GitHub 访问慢时，可输入你信任的企业/自建 GitHub 加速前缀；留空表示直连。" >&2; read -r -p "GitHub 加速前缀 [${proxy:-直连}]: " input || true; input="$(trim_string "${input:-}")"; [[ -n "$input" ]] && proxy="$input"; fi; proxy="$(trim_string "$proxy")"; [[ -n "$proxy" ]] || { printf ''; return 0; }; is_http_url "$proxy" || { warn "GitHub 加速前缀不是 http(s) URL，已改为直连。" >&2; printf ''; return 0; }; printf '%s' "${proxy%/}/"; }
github_url() { local repo_url="$1" proxy="${2:-}"; [[ -n "$proxy" ]] || { printf '%s' "$repo_url"; return 0; }; printf '%s%s' "$proxy" "$repo_url"; }
clone_or_update_repo() { local repo_url="$1" dest="$2" proxy="${3:-}" final_url; final_url="$(github_url "$repo_url" "$proxy")"; if [[ -d "$dest/.git" ]]; then info "仓库已存在，尝试更新：$dest"; run_as_target_user git -C "$dest" pull --ff-only; else run_as_target_user git clone --depth=1 "$final_url" "$dest"; fi; }
install_oh_my_zsh() { ensure_target_home; has_cmd git || pkg_install git; has_cmd zsh || pkg_install zsh; local home zsh_dir zshrc proxy; proxy="${1:-}"; [[ -n "$proxy" ]] || proxy="$(ask_github_proxy)"; home="$(target_user_home)"; zsh_dir="$home/.oh-my-zsh"; zshrc="$home/.zshrc"; clone_or_update_repo "https://github.com/ohmyzsh/ohmyzsh.git" "$zsh_dir" "$proxy"; [[ -f "$zsh_dir/oh-my-zsh.sh" ]] || fatal "Oh My Zsh 安装校验失败"; [[ -f "$zshrc" ]] || write_file "$zshrc" <<'EOF_ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
EOF_ZSHRC
chown_target "$zshrc"; success "Oh My Zsh 安装完成。"; }
install_zsh_plugins() { ensure_target_home; has_cmd git || pkg_install git; local home custom proxy p1 p2 zshrc; proxy="${1:-}"; [[ -n "$proxy" ]] || proxy="$(ask_github_proxy)"; home="$(target_user_home)"; custom="$home/.oh-my-zsh/custom"; zshrc="$home/.zshrc"; [[ -d "$home/.oh-my-zsh" ]] || install_oh_my_zsh "$proxy"; run mkdir -p "$custom/plugins"; p1="$custom/plugins/zsh-autosuggestions"; p2="$custom/plugins/zsh-syntax-highlighting"; clone_or_update_repo "https://github.com/zsh-users/zsh-autosuggestions.git" "$p1" "$proxy"; clone_or_update_repo "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$p2" "$proxy"; [[ -f "$zshrc" ]] && grep -q '^plugins=' "$zshrc" 2>/dev/null && run sed -i.bak 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$zshrc"; chown_target "$p1" "$p2" "$zshrc"; success "Oh My Zsh 插件安装并配置完成。"; }
install_rupa_z() { ensure_target_home; has_cmd git || pkg_install git; local home dest zshrc bashrc proxy block; proxy="${1:-}"; [[ -n "$proxy" ]] || proxy="$(ask_github_proxy)"; home="$(target_user_home)"; dest="$home/.local/share/z"; zshrc="$home/.zshrc"; bashrc="$home/.bashrc"; run mkdir -p "$home/.local/share"; clone_or_update_repo "https://github.com/rupa/z.git" "$dest" "$proxy"; block='if [ -f "$HOME/.local/share/z/z.sh" ]; then
  . "$HOME/.local/share/z/z.sh"
fi'; write_managed_block "$zshrc" "rupa-z" "$block"; write_managed_block "$bashrc" "rupa-z" "$block"; success "rupa/z 安装完成。"; }
configure_zsh_full() { local proxy; proxy="$(ask_github_proxy)"; install_oh_my_zsh "$proxy"; install_zsh_plugins "$proxy"; install_rupa_z "$proxy"; configure_zsh_basic; success "完整 Zsh 环境初始化完成。"; }
change_default_shell_to_zsh() { has_cmd zsh || pkg_install zsh; local user zsh_path; user="$(target_user_name)"; zsh_path="$(cmd_path zsh | head -n1)"; [[ -n "$zsh_path" ]] || fatal "未找到 zsh。"; grep -qx "$zsh_path" /etc/shells 2>/dev/null || echo "$zsh_path" | run_privileged tee -a /etc/shells >/dev/null; is_macos && run_privileged chsh -s "$zsh_path" "$user" || run chsh -s "$zsh_path" "$user"; success "已将用户 ${user} 的默认 Shell 设置为 ${zsh_path}。"; }
configure_common_tools() { configure_vim; configure_tmux; configure_git; configure_zsh_basic; success "常用工具基础配置完成。"; }

# ---------- 镜像源 ----------
source_base_url() { local source="${1:-$DEFAULT_SOURCE}" url; case "$source" in official) printf '' ;; tuna) printf 'https://mirrors.tuna.tsinghua.edu.cn' ;; ustc) printf 'https://mirrors.ustc.edu.cn' ;; aliyun) printf 'https://mirrors.aliyun.com' ;; tencent) printf 'https://mirrors.cloud.tencent.com' ;; bfsu) printf 'https://mirrors.bfsu.edu.cn' ;; custom:*) url="${source#custom:}"; url="$(trim_string "$url")"; validate_url_value "$url"; printf '%s' "${url%/}" ;; http://*|https://*) validate_url_value "$source"; printf '%s' "${source%/}" ;; *) fatal "未知镜像源：$source" ;; esac; }
backup_root() { is_macos && printf '%s/.local/state/linux-admin-toolkit/backups' "$(target_user_home)" || printf '%s' "$BACKUP_ROOT"; }
backup_sources() { local ts dir root home; ts="$(date +%Y%m%d-%H%M%S)"; root="$(backup_root)"; dir="$root/$ts"; if is_macos; then run mkdir -p "$dir"; home="$(target_user_home)"; run mkdir -p "$dir/home"; run_shell "cp -a '$home/.zprofile' '$home/.zshrc' '$home/.bashrc' '$dir/home/' 2>/dev/null || true"; success "macOS/Homebrew 配置已备份到：$dir"; return 0; fi; run_privileged mkdir -p "$dir"; [[ -d /etc/apt ]] && { run mkdir -p "$dir/etc/apt"; run_shell "cp -a /etc/apt/sources.list /etc/apt/sources.list.d '$dir/etc/apt/' 2>/dev/null || true"; }; [[ -d /etc/yum.repos.d ]] && { run mkdir -p "$dir/etc/yum.repos.d"; run_shell "cp -a /etc/yum.repos.d/*.repo '$dir/etc/yum.repos.d/' 2>/dev/null || true"; }; [[ -f /etc/pacman.conf || -d /etc/pacman.d ]] && { run mkdir -p "$dir/etc/pacman.d"; run_shell "cp -a /etc/pacman.conf '$dir/etc/' 2>/dev/null || true"; run_shell "cp -a /etc/pacman.d/mirrorlist '$dir/etc/pacman.d/' 2>/dev/null || true"; }; success "镜像源已备份到：$dir"; }
list_source_backups() { local root; root="$(backup_root)"; mkdir -p "$root" 2>/dev/null || run_privileged mkdir -p "$root"; find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed "s#^$root/##" | sort || true; }
restore_sources() { local name="${1:-}" dir home; [[ -z "$name" ]] && { echo "可用备份："; list_source_backups; read -r -p "输入要恢复的备份目录名：" name; }; [[ -n "$name" && "$name" != */* && "$name" != *..* ]] || fatal "备份目录名不合法：$name"; dir="$(backup_root)/$name"; [[ -d "$dir" ]] || fatal "备份不存在：$dir"; confirm "确认恢复 ${dir} 到源/配置？" || cancelled; if is_macos; then home="$(target_user_home)"; run_shell "cp -a '$dir/home/'* '$home/' 2>/dev/null || true"; chown_target "$home/.zprofile" "$home/.zshrc" "$home/.bashrc" 2>/dev/null || true; success "macOS/Homebrew 配置恢复完成。"; return 0; fi; [[ -d "$dir/etc/apt" ]] && run_shell "cp -a '$dir/etc/apt/'* /etc/apt/ 2>/dev/null || true"; [[ -d "$dir/etc/yum.repos.d" ]] && run_shell "cp -a '$dir/etc/yum.repos.d/'*.repo /etc/yum.repos.d/ 2>/dev/null || true"; [[ -f "$dir/etc/pacman.conf" ]] && run_shell "cp -a '$dir/etc/pacman.conf' /etc/pacman.conf"; [[ -f "$dir/etc/pacman.d/mirrorlist" ]] && run_shell "cp -a '$dir/etc/pacman.d/mirrorlist' /etc/pacman.d/mirrorlist"; refresh_pkg_cache; success "恢复完成。"; }
set_homebrew_mirror() { local source="${1:-official}" home zprofile zshrc bashrc block base; ensure_target_home; home="$(target_user_home)"; zprofile="$home/.zprofile"; zshrc="$home/.zshrc"; bashrc="$home/.bashrc"; backup_sources; [[ "$source" == official ]] && { remove_managed_block "$zprofile" homebrew-mirror; remove_managed_block "$zshrc" homebrew-mirror; remove_managed_block "$bashrc" homebrew-mirror; success "已移除脚本管理的 Homebrew 镜像环境变量。"; return 0; }; base="$(source_base_url "$source")"; block="export HOMEBREW_API_DOMAIN=\"${base%/}/homebrew-bottles/api\"\nexport HOMEBREW_BOTTLE_DOMAIN=\"${base%/}/homebrew-bottles\""; write_managed_block "$zprofile" homebrew-mirror "$block"; write_managed_block "$zshrc" homebrew-mirror "$block"; write_managed_block "$bashrc" homebrew-mirror "$block"; success "Homebrew 镜像变量已写入 shell 配置。"; }
set_apt_mirror() { local source="${1:-$DEFAULT_SOURCE}" base codename components target_file main_uri security_uri; codename="$(get_codename)"; [[ -n "$codename" ]] || fatal "无法识别 codename。"; backup_sources; components="main contrib non-free non-free-firmware"; if [[ "$source" == official ]]; then main_uri="http://deb.debian.org/debian"; security_uri="http://deb.debian.org/debian-security"; elif [[ "$OS_ID" == ubuntu || "$OS_LIKE" == *ubuntu* ]]; then base="$(source_base_url "$source")"; main_uri="${base}/ubuntu"; security_uri="$main_uri"; components="main restricted universe multiverse"; else base="$(source_base_url "$source")"; main_uri="${base}/debian"; security_uri="${base}/debian-security"; fi; target_file="/etc/apt/sources.list"; write_file "$target_file" <<EOF_APT
deb ${main_uri} ${codename} ${components}
deb ${main_uri} ${codename}-updates ${components}
deb ${main_uri} ${codename}-backports ${components}
deb ${security_uri} ${codename}-security ${components}
EOF_APT
success "已写入 apt 源：${target_file}"; refresh_pkg_cache; }
set_rpm_mirror() { local source="${1:-$DEFAULT_SOURCE}" base; [[ "$source" == official ]] && skipped "RPM 系发行版官方源格式差异较大，脚本不强制重写为官方源。"; base="$(source_base_url "$source")"; backup_sources; is_kylin && skipped "检测到麒麟系统，脚本只做备份，不自动替换。"; if is_fedora; then run_shell "sed -i.linux-admin.bak -e 's|^metalink=|#metalink=|g' -e 's|^#baseurl=http://download.example/pub/fedora/linux|baseurl=${base}/fedora|g' -e 's|^#baseurl=https://download.example/pub/fedora/linux|baseurl=${base}/fedora|g' /etc/yum.repos.d/fedora*.repo"; else run_shell "sed -i.linux-admin.bak -e 's|^mirrorlist=|#mirrorlist=|g' -e 's|^#baseurl=http://mirror.centos.org/centos|baseurl=${base}/centos|g' -e 's|^#baseurl=https://mirror.centos.org/centos|baseurl=${base}/centos|g' /etc/yum.repos.d/*.repo"; fi; refresh_pkg_cache; success "RPM 镜像源处理完成。"; }
set_pacman_mirror() { local source="${1:-$DEFAULT_SOURCE}" base mirror_url; backup_sources; if [[ "$source" == official ]]; then mirror_url='https://geo.mirror.pkgbuild.com/$repo/os/$arch'; else base="$(source_base_url "$source")"; mirror_url="${base}/archlinux/\$repo/os/\$arch"; fi; write_file /etc/pacman.d/mirrorlist <<EOF_PACMAN
Server = ${mirror_url}
EOF_PACMAN
refresh_pkg_cache; success "Arch Linux pacman 镜像源已写入：/etc/pacman.d/mirrorlist"; }
set_system_mirror() { local source="${1:-$DEFAULT_SOURCE}"; if is_macos; then set_homebrew_mirror "$source"; return 0; fi; case "$PKG_MANAGER" in apt) set_apt_mirror "$source" ;; dnf|yum) set_rpm_mirror "$source" ;; pacman) set_pacman_mirror "$source" ;; *) fatal "未检测到支持的包管理器。" ;; esac; }
choose_mirror_source() { local c custom; CHOSEN_MIRROR_SOURCE=""; cat <<'EOF_SOURCE'

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
menu_set_system_mirror() { local s; choose_mirror_source; s="$CHOSEN_MIRROR_SOURCE"; [[ -n "$s" ]] || cancelled; info "已选择源：${s}"; set_system_mirror "$s"; }

# ---------- Docker ----------
registry_mirrors_json() { local input="$1" old_ifs item out="[" sep=""; old_ifs="$IFS"; IFS=','; for item in $input; do item="$(trim_string "$item")"; [[ -n "$item" ]] || continue; validate_url_value "$item"; out="${out}${sep}\"${item}\""; sep=", "; done; IFS="$old_ifs"; [[ "$out" != "[" ]] || fatal "未输入有效的 registry mirror URL。"; printf '%s]' "$out"; }
docker_repo_base() { local s="${1:-$DEFAULT_DOCKER_SOURCE}"; case "$s" in official) printf 'https://download.docker.com' ;; tuna) printf 'https://mirrors.tuna.tsinghua.edu.cn/docker-ce' ;; ustc) printf 'https://mirrors.ustc.edu.cn/docker-ce' ;; aliyun) printf 'https://mirrors.aliyun.com/docker-ce' ;; tencent) printf 'https://mirrors.cloud.tencent.com/docker-ce' ;; bfsu) printf 'https://mirrors.bfsu.edu.cn/docker-ce' ;; custom:*|http://*|https://*) source_base_url "$s" ;; *) fatal "未知 Docker 源：$s" ;; esac; }
docker_repo_os() { if [[ "$OS_ID" == ubuntu || "$OS_LIKE" == *ubuntu* ]]; then printf ubuntu; elif [[ "$OS_ID" == debian || "$OS_LIKE" == *debian* ]]; then printf debian; elif is_fedora; then printf fedora; else printf centos; fi; }
remove_old_docker_conflicts() { [[ "$PKG_MANAGER" == pacman ]] && return 0; [[ "$PKG_MANAGER" == apt ]] && pkg_remove docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc || pkg_remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman-docker || true; }
install_docker_macos() { ensure_brew; brew_run install --cask docker-desktop; success "Docker Desktop 已安装。首次使用请从 Applications 启动 Docker。"; }
install_docker_pacman() { pkg_install docker docker-compose; }
install_docker_apt() { local source="${1:-$DEFAULT_DOCKER_SOURCE}" base repo_os codename arch list_file; base="$(docker_repo_base "$source")"; repo_os="$(docker_repo_os)"; codename="$(get_codename)"; arch="$(dpkg --print-architecture 2>/dev/null || true)"; [[ -n "$codename" ]] || fatal "无法识别 codename。"; remove_old_docker_conflicts; pkg_install ca-certificates curl gnupg; run install -m 0755 -d /etc/apt/keyrings; run_shell "curl -fsSL '${base}/linux/${repo_os}/gpg' | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg"; run chmod a+r /etc/apt/keyrings/docker.gpg; list_file=/etc/apt/sources.list.d/docker.list; write_file "$list_file" <<EOF_DOCKER
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] ${base}/linux/${repo_os} ${codename} stable
EOF_DOCKER
refresh_pkg_cache; pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; }
install_docker_rpm() { local source="${1:-$DEFAULT_DOCKER_SOURCE}" base repo_os repo_url; base="$(docker_repo_base "$source")"; repo_os="$(docker_repo_os)"; remove_old_docker_conflicts; pkg_install yum-utils; repo_url="${base}/linux/${repo_os}/docker-ce.repo"; has_cmd dnf && run dnf config-manager --add-repo "$repo_url" || run yum-config-manager --add-repo "$repo_url"; [[ "$source" != official ]] && run_shell "sed -i.bak 's#https://download.docker.com#${base}#g' /etc/yum.repos.d/docker-ce.repo"; pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; }
install_docker() { local source="${1:-$DEFAULT_DOCKER_SOURCE}"; if is_macos; then confirm "即将安装 Docker Desktop。是否继续？" || cancelled; install_docker_macos; return 0; fi; confirm "即将安装 Docker，并可能移除系统中冲突的旧 Docker/Podman 兼容包。是否继续？" || cancelled; case "$PKG_MANAGER" in apt) install_docker_apt "$source" ;; dnf|yum) install_docker_rpm "$source" ;; pacman) install_docker_pacman ;; *) fatal "未检测到支持的包管理器。" ;; esac; has_cmd docker || fatal "Docker 安装后未检测到 docker 命令。"; has_cmd systemctl && run systemctl enable --now docker; success "Docker 安装完成。"; }
menu_install_docker() { local s; if is_macos || is_arch; then install_docker official; return $?; fi; choose_mirror_source; s="$CHOSEN_MIRROR_SOURCE"; [[ -n "$s" ]] || cancelled; info "已选择 Docker 源：${s}"; install_docker "$s"; }
configure_docker_registry_mirror() { is_macos && { warn "macOS Docker Desktop 的 registry mirror 建议在 Docker Desktop Settings 中配置。"; return 0; }; local mirrors="${1:-}" daemon_json content; [[ -z "$mirrors" ]] && { echo "输入 Docker Registry mirrors，多个用逗号分隔；留空则清空脚本管理配置。"; read -r -p "Registry mirrors: " mirrors; }; confirm "即将写入 Docker daemon 配置并重启 Docker。是否继续？" || cancelled; daemon_json=/etc/docker/daemon.json; run mkdir -p /etc/docker; if [[ -z "$(trim_string "$mirrors")" ]]; then write_file "$daemon_json" <<'EOF_DAEMON'
{}
EOF_DAEMON
else content="$(registry_mirrors_json "$mirrors")"; write_file "$daemon_json" <<EOF_DAEMON
{
  "registry-mirrors": ${content}
}
EOF_DAEMON
fi; has_cmd systemctl && { run systemctl daemon-reload; run systemctl restart docker; }; success "Docker Registry mirror 配置完成：${daemon_json}"; }
save_docker_images_one_by_one() { has_cmd docker || fatal "未检测到 docker 命令。"; docker info >/dev/null 2>&1 || fatal "Docker daemon 不可用。"; local dir="${1:-}" image safe out count=0; [[ -z "$dir" ]] && { read -r -p "输入镜像导出目录 [${HOME:-/root}/docker-images]: " dir; dir="${dir:-${HOME:-/root}/docker-images}"; }; run mkdir -p "$dir"; while IFS= read -r image; do [[ -n "$image" ]] || continue; safe="$(printf '%s' "$image" | tr '/:@' '___')"; out="$dir/${safe}.tar.gz"; info "导出镜像：${image} -> ${out}"; if [[ "$DRY_RUN" -eq 1 ]]; then count=$((count + 1)); continue; fi; docker save "$image" | gzip > "$out"; [[ -s "$out" ]] || fatal "导出失败：$out"; count=$((count + 1)); done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true); success "Docker 镜像导出完成，数量：${count}。"; }
uninstall_docker() { local remove_data="${1:-0}"; confirm "即将卸载 Docker 相关软件包。是否继续？" || cancelled; if is_macos; then ensure_brew; brew_run uninstall --cask docker-desktop || true; success "Docker Desktop 卸载完成。"; return 0; fi; has_cmd systemctl && run systemctl stop docker || true; [[ "$PKG_MANAGER" == pacman ]] && pkg_remove docker docker-compose || pkg_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true; [[ "$remove_data" == 1 ]] && confirm "确认删除 /var/lib/docker /var/lib/containerd？" && run rm -rf /var/lib/docker /var/lib/containerd; success "Docker 卸载完成。"; }
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
  local tgz tmpdir f base
  tgz="$(find "$RESOURCE_DIR" -maxdepth 1 -name 'docker-*.tgz' | head -1)"
  [[ -f "$tgz" ]] || die "未找到 Docker 资源包"
  log "安装 Docker Engine：$tgz"
  tmpdir="$(mktemp -d)"; tar -xzf "$tgz" -C "$tmpdir"
  for f in "$tmpdir/docker"/*; do [[ -f "$f" ]] && install -m 0755 "$f" "/usr/local/bin/$(basename "$f")"; done
  rm -rf "$tmpdir"
  # 安装 Compose
  local src="$(find "$RESOURCE_DIR" -maxdepth 1 \( -name 'docker-compose-*' -o -name 'docker-compose-linux-*' \) | head -1)"
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
swap_resize() { local size="${1:-}" path="${2:-/swapfile}"; [[ -n "$size" ]] || read -r -p "新的 swap 大小，如 4G: " size; [[ -e "$path" ]] && swap_delete "$path"; swap_add "$size" "$path"; }
ensure_lvm() { ensure_linux_only "macOS 不支持 Linux LVM。"; has_cmd lvm || pkg_install lvm2; has_cmd lvm || fatal "lvm2 安装后仍未检测到 lvm 命令。"; }
lvm_list() { ensure_linux_only "macOS 不支持 Linux LVM。"; has_cmd lsblk && lsblk || true; has_cmd pvs && pvs || warn "缺少 pvs，请先安装 lvm2。"; has_cmd vgs && vgs || true; has_cmd lvs && lvs || true; }
lvm_create_pv() { ensure_lvm; local dev="${1:-}"; [[ -n "$dev" ]] || { lsblk; read -r -p "输入要初始化为 PV 的设备，如 /dev/sdb1: " dev; }; [[ -b "$dev" ]] || fatal "不是块设备：$dev"; confirm "确认对 ${dev} 执行 pvcreate？这可能破坏原数据。" || cancelled; run pvcreate "$dev"; }
lvm_create_vg() { ensure_lvm; local vg="${1:-}" line; shift || true; [[ -n "$vg" ]] || read -r -p "VG 名称: " vg; [[ "$#" -eq 0 ]] && { read -r -p "输入 PV 设备，多个用空格分隔: " line; set -- $line; }; confirm "即将创建 VG ${vg}，使用 PV：$*。是否继续？" || cancelled; run vgcreate "$vg" "$@"; }
lvm_create_lv() { ensure_lvm; local vg="${1:-}" name="${2:-}" size="${3:-}"; [[ -n "$vg" ]] || { vgs; read -r -p "VG 名称: " vg; }; [[ -n "$name" ]] || read -r -p "LV 名称: " name; [[ -n "$size" ]] || read -r -p "LV 大小，如 20G 或 100%FREE: " size; confirm "即将在 VG ${vg} 中创建 LV ${name}，大小 ${size}。是否继续？" || cancelled; [[ "$size" == *%* ]] && run lvcreate -n "$name" -l "$size" "$vg" || run lvcreate -n "$name" -L "$size" "$vg"; }
lvm_extend_lv() { ensure_lvm; local lv="${1:-}" size="${2:-}"; [[ -n "$lv" ]] || { lvs; read -r -p "LV 路径，如 /dev/vg0/data: " lv; }; [[ -n "$size" ]] || read -r -p "扩容大小，如 +10G 或 +100%FREE: " size; confirm "即将扩容 ${lv}，规格 ${size}。是否继续？" || cancelled; [[ "$size" == *%* ]] && run lvextend -r -l "$size" "$lv" || run lvextend -r -L "$size" "$lv"; }
lvm_remove_lv() { ensure_lvm; local lv="${1:-}"; [[ -n "$lv" ]] || { lvs; read -r -p "要删除的 LV 路径: " lv; }; confirm "确认删除 LV ${lv}？这会删除数据。" || cancelled; run lvremove -y "$lv"; }
ensure_perf_tools() { is_macos && { has_cmd htop || brew_install htop || true; return 0; }; case "$PKG_MANAGER" in apt) pkg_install sysstat htop lsof iotop iftop nload iproute2 procps ;; dnf|yum) pkg_install sysstat htop lsof iotop iftop nload iproute procps-ng ;; pacman) pkg_install sysstat htop lsof iotop iftop nload iproute2 procps-ng ;; *) warn "无法自动安装性能工具。" ;; esac; }
perf_quick() { ensure_perf_tools; echo "========== 系统信息 =========="; print_env; echo; echo "========== 负载 =========="; uptime || true; echo; echo "========== 内存 =========="; free -h 2>/dev/null || vm_stat 2>/dev/null || true; echo; echo "========== 磁盘 =========="; df -hT 2>/dev/null || df -h || true; echo; echo "========== 网络 =========="; has_cmd ss && ss -s || netstat -ib 2>/dev/null | head -n 20 || true; echo; echo "========== Top 进程 =========="; ps aux --sort=-%cpu 2>/dev/null | head -n 10 || ps aux | head -n 10 || true; }

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
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "查看常用工具安装状态" tool_status ;; 2) menu_action "配置 Vim" configure_vim ;; 3) menu_action "配置 Tmux" configure_tmux ;; 4) menu_action "配置 Git" configure_git ;; 5) menu_action "配置基础 Zsh" configure_zsh_basic ;; 6) menu_action "配置常用工具" configure_common_tools ;; 7) menu_action "安装 Oh My Zsh" install_oh_my_zsh ;; 8) menu_action "安装 Oh My Zsh 插件" install_zsh_plugins ;; 9) menu_action "安装 rupa/z" install_rupa_z ;; 10) menu_action "初始化完整 Zsh 环境" configure_zsh_full ;; 11) menu_action "设置默认 Shell 为 zsh" change_default_shell_to_zsh ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_common_tools() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[常用工具]
1) 安装常用工具
2) 常用工具配置子菜单
3) 安装并初始化完整 Zsh 环境
4) 查看常用工具安装状态
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "安装常用工具" install_common_tools ;; 2) menu_tools_config ;; 3) menu_action "安装并初始化完整 Zsh 环境" configure_zsh_full ;; 4) menu_action "查看常用工具安装状态" tool_status ;; 0) return ;; *) menu_invalid ;; esac; done; }
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
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "查看系统环境" print_env ;; 2) menu_action "备份当前源" backup_sources ;; 3) menu_action "切换系统源" menu_set_system_mirror ;; 4) menu_action "列出源备份" list_source_backups ;; 5) menu_action "恢复源备份" restore_sources ;; 6) menu_action "刷新包缓存" refresh_pkg_cache ;; 0) return ;; *) menu_invalid ;; esac; done; }
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
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "安装 Docker" menu_install_docker ;; 2) menu_action "配置 Docker Registry mirror" configure_docker_registry_mirror ;; 3) menu_action "逐个导出本地镜像为 tar.gz" save_docker_images_one_by_one ;; 4) menu_action "查看 Docker 状态" menu_docker_status ;; 5) menu_action "卸载 Docker" uninstall_docker 0 ;; 6) menu_docker_offline ;; 0) return ;; *) menu_invalid ;; esac; done; }
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
1) 查看 PV/VG/LV/块设备
2) 安装 lvm2
3) 创建 PV
4) 创建 VG
5) 创建 LV
6) 扩容 LV
7) 删除 LV
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "查看 PV/VG/LV/块设备" lvm_list ;; 2) menu_action "安装 lvm2" ensure_lvm ;; 3) menu_action "创建 PV" lvm_create_pv ;; 4) menu_action "创建 VG" lvm_create_vg ;; 5) menu_action "创建 LV" lvm_create_lv ;; 6) menu_action "扩容 LV" lvm_extend_lv ;; 7) menu_action "删除 LV" lvm_remove_lv ;; 0) return ;; *) menu_invalid ;; esac; done; }
menu_perf() { local c; while true; do menu_clear; cat <<'EOF_MENU'
[Linux/macOS 性能瓶颈排查]
1) 快速巡检
2) 安装/检查性能工具
0) 返回上一级
EOF_MENU
read -r -p "选择: " c; case "${c:-}" in 1) menu_action "快速性能巡检" perf_quick ;; 2) menu_action "安装/检查性能工具" ensure_perf_tools ;; 0) return ;; *) menu_invalid ;; esac; done; }
main_menu() { local c; while true; do menu_clear; cat <<EOF_MENU
Linux/macOS Admin Toolkit v${TOOL_VERSION}
系统：${OS_NAME} (${PLATFORM:-unknown})    包管理器：${PKG_MANAGER:-unknown}

1) 常用工具安装/配置
2) 系统镜像源 / Homebrew 镜像
3) Docker
4) 防火墙 ufw/firewalld/macOS Application Firewall
5) Swap 管理
6) LVM 管理
7) 性能瓶颈排查
8) 查看系统环境
0) 退出
EOF_MENU
read -r -p "请选择: " c; case "${c:-}" in 1) menu_common_tools ;; 2) menu_mirror ;; 3) menu_docker ;; 4) menu_firewall ;; 5) menu_swap ;; 6) menu_lvm ;; 7) menu_perf ;; 8) menu_action "查看系统环境" print_env ;; 0) exit 0 ;; *) menu_invalid ;; esac; done; }

# ---------- CLI ----------
usage() { cat <<EOF_USAGE
用法：
  $PROGRAM_NAME [全局选项] [模块] [动作] [参数]

全局选项：
  -y, --yes       默认确认
  -n, --dry-run   只打印不执行
  --no-color      禁用颜色
  -h, --help      查看帮助

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
  $PROGRAM_NAME lvm list
  $PROGRAM_NAME perf quick
EOF_USAGE
}
get_opt_value() { local key="$1" arg next; shift || true; while [[ "$#" -gt 0 ]]; do arg="$1"; case "$arg" in "$key") shift || true; next="${1:-}"; [[ -n "$next" ]] || return 1; printf '%s' "$next"; return 0 ;; "$key"=*) printf '%s' "${arg#*=}"; return 0 ;; esac; shift || true; done; return 1; }
main() { detect_os; while [[ "$#" -gt 0 ]]; do case "${1:-}" in -y|--yes) ASSUME_YES=1; shift ;; -n|--dry-run) DRY_RUN=1; shift ;; --no-color) NO_COLOR=1; shift ;; -h|--help) usage; exit 0 ;; *) break ;; esac; done; local module="${1:-menu}" action="${2:-}"; case "$module" in menu|"") require_root "$@"; main_menu ;; env) print_env ;; tools) require_root "$@"; case "${action:-}" in install) install_common_tools ;; status) tool_status ;; config) case "${3:-all}" in all) configure_common_tools ;; vim) configure_vim ;; tmux) configure_tmux ;; git) configure_git ;; zsh-basic) configure_zsh_basic ;; *) fatal "未知 tools config 动作：${3:-}" ;; esac ;; oh-my-zsh) install_oh_my_zsh "$(get_opt_value --github-proxy "$@" || true)" ;; zsh-plugins) install_zsh_plugins "$(get_opt_value --github-proxy "$@" || true)" ;; install-z) install_rupa_z "$(get_opt_value --github-proxy "$@" || true)" ;; zsh-full) configure_zsh_full ;; chsh-zsh) change_default_shell_to_zsh ;; *) fatal "未知 tools 动作：${action:-}" ;; esac ;; mirror) require_root "$@"; case "${action:-}" in backup) backup_sources ;; set) set_system_mirror "$(get_opt_value --source "$@" || printf '%s' "$DEFAULT_SOURCE")" ;; list-backups) list_source_backups ;; restore) restore_sources "${3:-}" ;; refresh) refresh_pkg_cache ;; *) fatal "未知 mirror 动作：${action:-}" ;; esac ;; docker) require_root "$@"; case "${action:-}" in install) install_docker "$(get_opt_value --source "$@" || printf '%s' "$DEFAULT_DOCKER_SOURCE")" ;; mirror) configure_docker_registry_mirror "$(get_opt_value --registry "$@" || true)" ;; save-images) save_docker_images_one_by_one "$(get_opt_value --dir "$@" || true)" ;; status) menu_docker_status ;; uninstall) uninstall_docker "$(get_opt_value --remove-data "$@" || printf '0')" ;; *) fatal "未知 docker 动作：${action:-}" ;; esac ;; firewall) require_root "$@"; case "${action:-}" in install) install_firewall ;; status) firewall_status ;; enable) firewall_enable ;; disable) firewall_disable ;; allow) firewall_allow "${3:-}" ;; deny) firewall_deny "${3:-}" ;; uninstall) uninstall_firewall ;; *) fatal "未知 firewall 动作：${action:-}" ;; esac ;; swap) require_root "$@"; case "${action:-}" in list) swap_list ;; add) swap_add "$(get_opt_value --size "$@" || true)" "$(get_opt_value --path "$@" || printf '/swapfile')" ;; resize) swap_resize "$(get_opt_value --size "$@" || true)" "$(get_opt_value --path "$@" || printf '/swapfile')" ;; delete) swap_delete "$(get_opt_value --path "$@" || true)" ;; *) fatal "未知 swap 动作：${action:-}" ;; esac ;; lvm) require_root "$@"; case "${action:-}" in list) lvm_list ;; install) ensure_lvm ;; create-pv) lvm_create_pv "${3:-}" ;; create-vg) shift 2; lvm_create_vg "$@" ;; create-lv) lvm_create_lv "${3:-}" "${4:-}" "${5:-}" ;; extend-lv) lvm_extend_lv "${3:-}" "${4:-}" ;; remove-lv) lvm_remove_lv "${3:-}" ;; *) fatal "未知 lvm 动作：${action:-}" ;; esac ;; perf) case "${action:-quick}" in quick) perf_quick ;; install-tools) ensure_perf_tools ;; *) fatal "未知 perf 动作：${action:-}" ;; esac ;; docker-offline) require_root "$@"; shift 2; case "${action:-}" in help) cat <<'EOF_OFFLINE_HELP'
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
;; status) offline_action_status ;; *) offline_parse_args "$@"; case "${action:-}" in download) offline_action_download ;; install) offline_action_install ;; package) offline_action_package ;; uninstall) offline_action_uninstall ;; *) fatal "未知 docker-offline 动作：${action:-}。支持：download/install/package/uninstall/status/help" ;; esac ;; esac ;; *) usage; fatal "未知模块：${module}" ;; esac; }
main "$@"
