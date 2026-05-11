#!/usr/bin/env bash
# Linux/macOS Admin Toolkit
# Linux 与 macOS 软件安装、Shell 环境、Docker、防火墙、Swap/LVM、性能排查管理脚本。
# 默认使用官方源，也内置中国大陆常用镜像源，适合不同网络环境。
# Linux 支持：Kylin V10、CentOS/CentOS Stream、Ubuntu、Debian、Fedora 及常见衍生系统。
# macOS 支持：Homebrew、常用工具、Zsh/Oh My Zsh、rupa/z、Docker Desktop、基础性能排查。

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME="$(basename "$0")"
TOOL_VERSION="0.3.3"
ASSUME_YES=0
DRY_RUN=0
NO_COLOR=0
PKG_UPDATED=0
BACKUP_ROOT="/var/backups/linux-admin-toolkit"
CANCEL_RC=130
SKIP_RC=100
DEFAULT_SOURCE="${LINUX_ADMIN_SOURCE:-official}"
DEFAULT_DOCKER_SOURCE="${LINUX_ADMIN_DOCKER_SOURCE:-official}"
CHOSEN_MIRROR_SOURCE=""

OS_ID=""
OS_LIKE=""
OS_NAME=""
OS_VERSION_ID=""
OS_CODENAME=""
PKG_MANAGER=""
PLATFORM=""

# ---------- 基础输出 ----------
_color() {
  local code="$1"
  shift || true
  if [[ "$NO_COLOR" -eq 1 || ! -t 1 ]]; then
    printf '%s\n' "$*"
  else
    printf '\033[%sm%s\033[0m\n' "$code" "$*"
  fi
}
info() { _color "1;34" "[INFO] $*"; }
success() { _color "1;32" "[OK] $*"; }
warn() { _color "1;33" "[WARN] $*"; }
error() { _color "1;31" "[ERROR] $*" >&2; }
fatal() { error "$*"; exit 1; }

format_cmd() {
  local arg quoted out=""
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    out="${out}${out:+ }${quoted}"
  done
  printf '%s' "$out"
}

run() {
  info "+ $(format_cmd "$@")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

run_shell() {
  info "+ $*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    bash -Eeuo pipefail -c "$*"
  fi
}

cmd_path() {
  local cmd="${1:-}" d
  [[ -n "$cmd" ]] || return 1
  command -v "$cmd" 2>/dev/null && return 0
  for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin /usr/bin /bin /usr/sbin /sbin; do
    [[ -x "$d/$cmd" ]] && { printf '%s\n' "$d/$cmd"; return 0; }
  done
  return 1
}
has_cmd() { cmd_path "${1:-}" >/dev/null 2>&1; }

trim_string() {
  local s="${1:-}"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

has_unsafe_url_chars() {
  local value="${1:-}"
  [[ "$value" == *"'"* || "$value" == *\"* || "$value" == *"\`"* || "$value" == *"\\"* || "$value" == *";"* || "$value" == *"|"* || "$value" =~ [[:space:]] ]]
}

confirm() {
  local prompt="${1:-确认继续？}" ans
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  {
    echo
    echo "$prompt"
    echo "1) 是，继续"
    echo "2) 否，取消"
  } >&2
  read -r -p "请选择 [2]: " ans
  case "${ans:-}" in
    1|y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

cancelled() {
  warn "用户取消操作。"
  return "$CANCEL_RC"
}

skipped() {
  warn "$*"
  return "$SKIP_RC"
}

not_applicable() { skipped "$*"; }

pause() {
  if [[ -t 0 ]]; then
    read -r -p "按 Enter 继续..." _unused || true
  fi
}

run_privileged() {
  if [[ "${EUID}" -eq 0 ]]; then
    run "$@"
  else
    has_cmd sudo || fatal "需要管理员权限，但未找到 sudo。"
    run sudo "$@"
  fi
}

write_file() {
  local file="$1" dir
  dir="$(dirname "$file")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "+ write file $file"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$dir"
  cat > "$file"
}

append_file() {
  local file="$1" dir
  dir="$(dirname "$file")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "+ append file $file"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$dir"
  cat >> "$file"
}

append_line_if_missing() {
  local file="$1" line="$2" dir
  dir="$(dirname "$file")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "+ append line to $file if missing: $line"
    return 0
  fi
  mkdir -p "$dir"
  touch "$file"
  grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

remove_fstab_entry() {
  local path="$1" tmp
  [[ -f /etc/fstab ]] || return 0
  run cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "+ remove fstab entries for $path"
    return 0
  fi
  tmp="$(mktemp)"
  awk -v p="$path" 'NF == 0 || $1 != p {print}' /etc/fstab > "$tmp"
  cat "$tmp" > /etc/fstab
  rm -f "$tmp"
}

# ---------- 系统检测 ----------
detect_os() {
  local kernel
  kernel="$(uname -s 2>/dev/null || printf unknown)"
  case "$kernel" in
    Darwin)
      PLATFORM="macos"
      OS_ID="macos"
      OS_LIKE="darwin"
      OS_NAME="macOS"
      OS_VERSION_ID="$(sw_vers -productVersion 2>/dev/null || true)"
      OS_CODENAME=""
      PKG_MANAGER="brew"
      ;;
    Linux)
      PLATFORM="linux"
      if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
        OS_NAME="${NAME:-unknown}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_CODENAME="${VERSION_CODENAME:-}"
      else
        OS_ID="unknown"
        OS_NAME="unknown"
      fi
      if has_cmd apt-get; then
        PKG_MANAGER="apt"
      elif has_cmd dnf; then
        PKG_MANAGER="dnf"
      elif has_cmd yum; then
        PKG_MANAGER="yum"
      else
        PKG_MANAGER=""
      fi
      ;;
    *)
      PLATFORM="unknown"
      OS_ID="unknown"
      OS_NAME="$kernel"
      PKG_MANAGER=""
      ;;
  esac
}

is_macos() { [[ "$PLATFORM" == "macos" || "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; }
is_linux() { [[ "$PLATFORM" == "linux" || "$(uname -s 2>/dev/null || true)" == "Linux" ]]; }
is_fedora() { [[ "$OS_ID" == "fedora" ]]; }
is_kylin() { [[ "$OS_ID" == *kylin* || "$OS_NAME" == *麒麟* || "$OS_NAME" == *Kylin* ]]; }
is_debian_like() { [[ "$PKG_MANAGER" == "apt" || "$OS_ID" =~ ^(ubuntu|debian)$ || "$OS_LIKE" == *debian* || "$OS_LIKE" == *ubuntu* ]]; }
is_rpm_like() { [[ "$PKG_MANAGER" =~ ^(dnf|yum)$ || "$OS_LIKE" == *rhel* || "$OS_ID" =~ ^(centos|fedora|rhel|rocky|almalinux|kylin)$ ]]; }

require_root() {
  if is_macos; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    if has_cmd sudo; then
      warn "需要 root 权限，正在尝试 sudo 重新执行。"
      exec sudo -E bash "$0" "$@"
    fi
    fatal "请使用 root 用户运行，或先安装 sudo。"
  fi
}

get_codename() {
  if is_macos; then
    printf ''
    return
  fi
  if [[ -n "$OS_CODENAME" ]]; then
    printf '%s' "$OS_CODENAME"
    return
  fi
  if has_cmd lsb_release; then
    lsb_release -sc 2>/dev/null && return
  fi
  if [[ -r /etc/debian_version ]]; then
    case "$(cut -d. -f1 /etc/debian_version 2>/dev/null || true)" in
      13) printf 'trixie' ;;
      12) printf 'bookworm' ;;
      11) printf 'bullseye' ;;
      10) printf 'buster' ;;
      *) printf '' ;;
    esac
  fi
}

print_env() {
  cat <<EOF_ENV
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
  if is_macos; then
    if brew_bin >/dev/null 2>&1; then
      echo "Homebrew：$(brew_bin)"
    else
      echo "Homebrew：未安装"
    fi
  fi
}

# ---------- 用户/Homebrew 适配 ----------
target_user_name() {
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    printf '%s' "$SUDO_USER"
  else
    id -un 2>/dev/null || printf 'root'
  fi
}

target_user_home() {
  local user home
  user="$(target_user_name)"
  if has_cmd dscl && is_macos; then
    home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    [[ -n "$home" ]] && { printf '%s' "$home"; return; }
  fi
  home="$(eval printf '%s' "~$user" 2>/dev/null || true)"
  if [[ -z "$home" || "$home" == "~$user" ]]; then
    home="${HOME:-/root}"
  fi
  printf '%s' "$home"
}

ensure_target_home() {
  local home
  home="$(target_user_home)"
  [[ -d "$home" ]] || fatal "用户目录不存在：$home"
}

chown_target() {
  local user path
  user="$(target_user_name)"
  if [[ "${EUID}" -eq 0 ]]; then
    for path in "$@"; do
      [[ -e "$path" ]] && chown -R "$user" "$path" 2>/dev/null || true
    done
  fi
}

run_as_target_user() {
  local user
  user="$(target_user_name)"
  if [[ "${EUID}" -eq 0 && "$user" != "root" ]]; then
    run sudo -H -u "$user" "$@"
  else
    run "$@"
  fi
}

brew_bin() {
  local b
  for b in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    [[ -n "$b" && -x "$b" ]] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

ensure_brew() {
  if ! is_macos; then
    return 0
  fi
  if brew_bin >/dev/null 2>&1; then
    return 0
  fi
  warn "未检测到 Homebrew。macOS 软件安装依赖 Homebrew。"
  confirm "是否按 Homebrew 官方安装脚本安装？" || cancelled
  has_cmd curl || fatal "缺少 curl，无法安装 Homebrew。"
  run_shell "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash"
}

brew_run() {
  local brew
  ensure_brew
  brew="$(brew_bin)"
  if [[ "${EUID}" -eq 0 ]]; then
    fatal "Homebrew 不应以 root 运行。请在 macOS 上用普通用户执行本脚本。"
  fi
  run "$brew" "$@"
}

brew_install() {
  local pkg brew missing=0
  ensure_brew
  brew="$(brew_bin)"
  for pkg in "$@"; do
    if "$brew" list --formula "$pkg" >/dev/null 2>&1 || "$brew" list --cask "$pkg" >/dev/null 2>&1; then
      info "Homebrew 已安装：$pkg"
    else
      missing=1
      brew_run install "$pkg"
    fi
  done
  return 0
}

# ---------- 包管理 ----------
refresh_pkg_cache() {
  case "$PKG_MANAGER" in
    apt) run apt-get update ;;
    dnf) run dnf clean all; run dnf makecache ;;
    yum) run yum clean all; run yum makecache ;;
    brew) brew_run update ;;
    *) warn "未检测到支持的包管理器，跳过刷新缓存。" ;;
  esac
}

pkg_install() {
  [[ "$#" -gt 0 ]] || return 0
  case "$PKG_MANAGER" in
    apt)
      if [[ "$PKG_UPDATED" -eq 0 ]]; then
        run apt-get update
        PKG_UPDATED=1
      fi
      DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends "$@"
      ;;
    dnf) run dnf install -y "$@" ;;
    yum) run yum install -y "$@" ;;
    brew) brew_install "$@" ;;
    *) fatal "未检测到支持的包管理器，无法安装：$*" ;;
  esac
}

pkg_remove() {
  [[ "$#" -gt 0 ]] || return 0
  case "$PKG_MANAGER" in
    apt) DEBIAN_FRONTEND=noninteractive run apt-get remove -y "$@" ;;
    dnf) run dnf remove -y "$@" ;;
    yum) run yum remove -y "$@" ;;
    brew) brew_run uninstall "$@" ;;
    *) fatal "未检测到支持的包管理器，无法卸载：$*" ;;
  esac
}

# ---------- 文件配置工具 ----------
backup_file_if_exists() {
  local file="$1"
  if [[ -e "$file" ]]; then
    run cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

remove_managed_block() {
  local file="$1" name="$2" begin end tmp
  [[ -f "$file" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "+ remove managed block '$name' from $file"
    return 0
  fi
  begin="# >>> Linux Admin Toolkit: ${name} >>>"
  end="# <<< Linux Admin Toolkit: ${name} <<<"
  tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    skip != 1 {print}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

write_managed_block() {
  local file="$1" name="$2" content="$3" dir begin end
  dir="$(dirname "$file")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "+ write managed block '$name' to $file"
    return 0
  fi
  run mkdir -p "$dir"
  [[ -f "$file" ]] || run touch "$file"
  remove_managed_block "$file" "$name"
  begin="# >>> Linux Admin Toolkit: ${name} >>>"
  end="# <<< Linux Admin Toolkit: ${name} <<<"
  {
    printf '\n%s\n' "$begin"
    printf '%s\n' "$content"
    printf '%s\n' "$end"
  } | append_file "$file"
  chown_target "$file"
}

# ---------- 常用工具 ----------
common_tool_commands() {
  if is_macos; then
    cat <<'EOF_TOOLS'
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
  else
    cat <<'EOF_TOOLS'
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
  fi
}

install_common_tools() {
  if is_macos; then
    ensure_brew
    brew_install curl wget vim git htop tmux zsh unzip jq rsync netcat bind lsof iftop nload || return 1
    warn "macOS 的 ping/ifconfig 通常为系统自带；iotop/sysstat 在 macOS 上不可完全等价，脚本不会强制安装。"
    verify_common_tools
    return $?
  fi

  case "$PKG_MANAGER" in
    apt)
      pkg_install curl wget vim git htop tmux zsh unzip jq rsync netcat-openbsd dnsutils iputils-ping net-tools lsof iotop iftop nload sysstat
      ;;
    dnf|yum)
      pkg_install curl wget vim-enhanced git htop tmux zsh unzip jq rsync nc bind-utils iputils net-tools lsof iotop iftop nload sysstat
      ;;
    *) fatal "未检测到支持的包管理器。" ;;
  esac
  verify_common_tools
}

verify_common_tools() {
  local item name cmd missing=""
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    name="${item%%:*}"
    cmd="${item#*:}"
    [[ "$cmd" == "$item" ]] && cmd="$name"
    if ! has_cmd "$cmd"; then
      # macOS 上这两个没有稳定等价项，不作为失败条件。
      if is_macos && [[ "$name" == "iotop" || "$name" == "sysstat" ]]; then
        warn "macOS 暂不强制检查 ${name}，请使用 perf quick 查看替代命令。"
      else
        missing="${missing}
  - ${name}"
      fi
    fi
  done < <(common_tool_commands)

  if [[ -n "$missing" ]]; then
    warn "以下常用工具命令仍然缺失，不能标记为全部安装成功：${missing}"
    return 1
  fi
  success "常用工具安装并校验完成。"
}

tool_status() {
  local item name cmd missing=0 path
  echo "目标用户：$(target_user_name)"
  echo "用户目录：$(target_user_home)"
  echo
  printf '%-18s %s\n' "工具" "状态"
  printf '%-18s %s\n' "----" "----"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    name="${item%%:*}"
    cmd="${item#*:}"
    [[ "$cmd" == "$item" ]] && cmd="$name"
    if path="$(cmd_path "$cmd" 2>/dev/null)"; then
      printf '%-18s %s\n' "$name" "已安装 (${path})"
    else
      printf '%-18s %s\n' "$name" "缺失"
      missing=$((missing + 1))
    fi
  done < <(common_tool_commands)
  echo
  if [[ "$missing" -gt 0 ]]; then
    warn "缺少 ${missing} 个命令，可先执行“安装常用工具”。"
  else
    success "常用工具命令检测通过。"
  fi
}

configure_vim() {
  ensure_target_home
  local home file
  home="$(target_user_home)"
  file="$home/.vimrc"
  info "写入 Vim 基础配置：$file"
  backup_file_if_exists "$file"
  write_file "$file" <<'EOF_VIM'
set nocompatible
syntax on
filetype plugin indent on
set number
set ruler
set showcmd
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
set fileencodings=utf-8,gb18030,gbk,gb2312,ucs-bom,latin1
set backspace=indent,eol,start
EOF_VIM
  chown_target "$file"
  success "Vim 配置完成。"
}

configure_tmux() {
  ensure_target_home
  local home file
  home="$(target_user_home)"
  file="$home/.tmux.conf"
  info "写入 Tmux 基础配置：$file"
  backup_file_if_exists "$file"
  write_file "$file" <<'EOF_TMUX'
# ~/.tmux.conf
# Minimal, portable, keyboard-first tmux config.

##### Prefix

unbind-key C-b
set-option -g prefix C-h

# Keep Ctrl-b available for nested tmux sessions without stealing Ctrl-h resize.
bind-key C-b send-prefix


##### Keys

# Reload config.
bind-key r source-file ~/.tmux.conf \; display-message "tmux.conf reloaded"

# Split panes. New panes inherit the current pane path.
unbind-key '"'
unbind-key %
bind-key - split-window -v -c "#{pane_current_path}"
bind-key | split-window -h -c "#{pane_current_path}"

# Move between panes with vim-style keys.
bind-key h select-pane -L
bind-key j select-pane -D
bind-key k select-pane -U
bind-key l select-pane -R

# Resize panes with repeatable Ctrl + vim-style keys.
bind-key -r C-h resize-pane -L 5
bind-key -r C-j resize-pane -D 5
bind-key -r C-k resize-pane -U 5
bind-key -r C-l resize-pane -R 5

# Toggle synchronized input for the current window.
bind-key s set-window-option synchronize-panes \; display-message "synchronize-panes toggled"

# Copy scrollback with vi-style keys.
bind-key [ copy-mode
bind-key ] paste-buffer
bind-key -T copy-mode-vi v send-keys -X begin-selection
bind-key -T copy-mode-vi C-v send-keys -X rectangle-toggle
bind-key -T copy-mode-vi y send-keys -X copy-selection-and-cancel
bind-key -T copy-mode-vi Enter send-keys -X copy-selection-and-cancel
bind-key -T copy-mode-vi Escape send-keys -X cancel

# Prefer the system clipboard when a common clipboard tool is available.
# If none exists, y still copies to tmux's own buffer, so this stays portable.
if-shell -b 'command -v pbcopy >/dev/null 2>&1' 'bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "pbcopy"'
if-shell -b 'command -v wl-copy >/dev/null 2>&1' 'bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "wl-copy"'
if-shell -b 'command -v xclip >/dev/null 2>&1' 'bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -in"'


##### Behavior

set-option -g default-terminal "screen-256color"
set-option -g base-index 1
set-option -g pane-base-index 1
set-option -g renumber-windows on
set-option -g history-limit 500000
set-option -g escape-time 10
set-option -g repeat-time 500
set-option -g focus-events on

set-window-option -g mode-keys vi
set-window-option -g monitor-activity on
set-option -g visual-activity on


##### Status

set-option -g status on
set-option -g status-position bottom
set-option -g status-interval 5
set-option -g status-justify centre
set-option -g status-left-length 40
set-option -g status-right-length 80
set-option -g status-style fg=colour250,bg=colour234

set-option -g status-left "#[fg=colour13,bold] #S #[fg=colour240]#I:#P "
set-option -g status-right "#{?client_prefix,#[fg=colour16,bg=colour13,bold] PREFIX ,}#[fg=colour245]%Y-%m-%d #[fg=colour14]%H:%M "

set-window-option -g window-status-separator ""
set-window-option -g window-status-format "#[fg=colour244,bg=colour234] #I #W#F "
set-window-option -g window-status-current-format "#[fg=colour16,bg=colour14,bold] #I:#W#F "
set-window-option -g window-status-style fg=colour244,bg=colour234
set-window-option -g window-status-current-style fg=colour16,bg=colour14,bold


##### Colors

set-option -g pane-border-style fg=colour238
set-option -g pane-active-border-style fg=colour13
set-option -g message-style fg=colour230,bg=colour238
set-option -g mode-style fg=colour16,bg=colour14
EOF_TMUX
  chown_target "$file"
  success "Tmux 配置完成。"
}

configure_git() {
  ensure_target_home
  local home file block
  home="$(target_user_home)"
  file="$home/.gitconfig"
  block='[core]
    editor = vim
    autocrlf = input
[pull]
    rebase = false
[init]
    defaultBranch = main
[color]
    ui = auto'
  backup_file_if_exists "$file"
  write_file "$file" <<EOF_GIT
${block}
EOF_GIT
  chown_target "$file"
  success "Git 基础配置完成。"
}

configure_zsh_basic() {
  ensure_target_home
  local home zshrc block
  home="$(target_user_home)"
  zshrc="$home/.zshrc"
  block='export EDITOR=vim
export PAGER=less
setopt autocd 2>/dev/null || true
setopt correct 2>/dev/null || true
setopt share_history 2>/dev/null || true
HISTSIZE=10000
SAVEHIST=10000
alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"'
  write_managed_block "$zshrc" "zsh-basic" "$block"
  success "Zsh 基础配置完成。"
}

ask_github_proxy() {
  local input proxy
  proxy="${GITHUB_PROXY_PREFIX:-}"
  if [[ -t 0 ]]; then
    {
      echo "GitHub 访问慢时，可输入你信任的企业/自建 GitHub 加速前缀；留空表示直连。"
      echo "示例：https://proxy.example.com/  会拼接为  https://proxy.example.com/https://github.com/owner/repo.git"
    } >&2
    read -r -p "GitHub 加速前缀 [${proxy:-直连}]: " input || true
    input="$(trim_string "${input:-}")"
    [[ -n "$input" ]] && proxy="$input"
  fi
  proxy="$(trim_string "$proxy")"
  [[ -n "$proxy" ]] || { printf ''; return 0; }
  is_http_url "$proxy" || { warn "GitHub 加速前缀不是 http(s) URL，已改为直连。" >&2; printf ''; return 0; }
  printf '%s' "${proxy%/}/"
}

github_url() {
  local repo_url="$1" proxy="${2:-}"
  [[ -n "$proxy" ]] || { printf '%s' "$repo_url"; return 0; }
  printf '%s%s' "$proxy" "$repo_url"
}

clone_or_update_repo() {
  local repo_url="$1" dest="$2" proxy="${3:-}" final_url
  final_url="$(github_url "$repo_url" "$proxy")"
  if [[ -d "$dest/.git" ]]; then
    info "仓库已存在，尝试更新：$dest"
    run_as_target_user git -C "$dest" pull --ff-only
  else
    run_as_target_user git clone --depth=1 "$final_url" "$dest"
  fi
}

install_oh_my_zsh() {
  ensure_target_home
  has_cmd git || pkg_install git
  has_cmd zsh || pkg_install zsh
  local home zsh_dir zshrc proxy
  proxy="${1:-}"
  [[ -n "$proxy" ]] || proxy="$(ask_github_proxy)"
  home="$(target_user_home)"
  zsh_dir="$home/.oh-my-zsh"
  zshrc="$home/.zshrc"
  clone_or_update_repo "https://github.com/ohmyzsh/ohmyzsh.git" "$zsh_dir" "$proxy"
  [[ -f "$zsh_dir/oh-my-zsh.sh" ]] || fatal "Oh My Zsh 安装校验失败：缺少 $zsh_dir/oh-my-zsh.sh"
  if [[ ! -f "$zshrc" ]]; then
    write_file "$zshrc" <<'EOF_ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
EOF_ZSHRC
    chown_target "$zshrc"
  else
    if ! grep -q 'oh-my-zsh.sh' "$zshrc" 2>/dev/null; then
      write_managed_block "$zshrc" "oh-my-zsh" 'export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"'
    fi
  fi
  success "Oh My Zsh 安装完成。"
}

install_zsh_plugins() {
  ensure_target_home
  has_cmd git || pkg_install git
  local home custom proxy p1 p2 zshrc
  proxy="${1:-}"
  [[ -n "$proxy" ]] || proxy="$(ask_github_proxy)"
  home="$(target_user_home)"
  custom="$home/.oh-my-zsh/custom"
  zshrc="$home/.zshrc"
  [[ -d "$home/.oh-my-zsh" ]] || install_oh_my_zsh "$proxy"
  run mkdir -p "$custom/plugins"
  chown_target "$custom"
  p1="$custom/plugins/zsh-autosuggestions"
  p2="$custom/plugins/zsh-syntax-highlighting"
  clone_or_update_repo "https://github.com/zsh-users/zsh-autosuggestions.git" "$p1" "$proxy"
  clone_or_update_repo "https://github.com/zsh-users/zsh-syntax-highlighting.git" "$p2" "$proxy"
  [[ -f "$p1/zsh-autosuggestions.zsh" ]] || fatal "插件安装校验失败：$p1/zsh-autosuggestions.zsh 不存在"
  [[ -f "$p2/zsh-syntax-highlighting.zsh" ]] || fatal "插件安装校验失败：$p2/zsh-syntax-highlighting.zsh 不存在"
  if [[ -f "$zshrc" ]]; then
    if grep -q '^plugins=' "$zshrc" 2>/dev/null; then
      run sed -i.bak 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' "$zshrc"
    else
      write_managed_block "$zshrc" "zsh-plugins" 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)'
    fi
  fi
  chown_target "$p1" "$p2" "$zshrc"
  success "Oh My Zsh 插件安装并配置完成。"
}

install_rupa_z() {
  ensure_target_home
  has_cmd git || pkg_install git
  local home dest zshrc bashrc proxy block
  proxy="${1:-}"
  [[ -n "$proxy" ]] || proxy="$(ask_github_proxy)"
  home="$(target_user_home)"
  dest="$home/.local/share/z"
  zshrc="$home/.zshrc"
  bashrc="$home/.bashrc"
  run mkdir -p "$home/.local/share"
  chown_target "$home/.local" "$home/.local/share"
  clone_or_update_repo "https://github.com/rupa/z.git" "$dest" "$proxy"
  [[ -f "$dest/z.sh" ]] || fatal "rupa/z 安装校验失败：缺少 $dest/z.sh"
  block='if [ -f "$HOME/.local/share/z/z.sh" ]; then
  . "$HOME/.local/share/z/z.sh"
fi'
  write_managed_block "$zshrc" "rupa-z" "$block"
  write_managed_block "$bashrc" "rupa-z" "$block"
  success "rupa/z 安装完成，已写入 .zshrc 和 .bashrc。"
  warn "z 是 shell function，安装后请重新打开终端，或执行：source ~/.bashrc / source ~/.zshrc；检查用 type z，不要用 which z。"
}

configure_zsh_full() {
  local proxy
  proxy="$(ask_github_proxy)"
  install_oh_my_zsh "$proxy"
  install_zsh_plugins "$proxy"
  install_rupa_z "$proxy"
  configure_zsh_basic
  success "完整 Zsh 环境初始化完成。"
}

change_default_shell_to_zsh() {
  has_cmd zsh || pkg_install zsh
  local user zsh_path
  user="$(target_user_name)"
  zsh_path="$(cmd_path zsh | head -n1)"
  [[ -n "$zsh_path" ]] || fatal "未找到 zsh。"
  if ! grep -qx "$zsh_path" /etc/shells 2>/dev/null; then
    echo "$zsh_path" | run_privileged tee -a /etc/shells >/dev/null
  fi
  if is_macos; then
    run_privileged chsh -s "$zsh_path" "$user"
  else
    run chsh -s "$zsh_path" "$user"
  fi
  success "已将用户 ${user} 的默认 Shell 设置为 ${zsh_path}。重新登录后生效。"
}

configure_common_tools() {
  configure_vim
  configure_tmux
  configure_git
  configure_zsh_basic
  success "常用工具基础配置完成。"
}

# ---------- 镜像源管理 ----------
is_http_url() { [[ "${1:-}" =~ ^https?:// ]]; }

validate_url_value() {
  local url="${1:-}"
  is_http_url "$url" || fatal "URL 必须以 http:// 或 https:// 开头：$url"
  ! has_unsafe_url_chars "$url" || fatal "URL 含有空白、引号或 shell 特殊字符，已拒绝：$url"
}

registry_mirrors_json() {
  local input="$1" old_ifs item out="[" sep=""
  old_ifs="$IFS"
  IFS=','
  for item in $input; do
    item="$(trim_string "$item")"
    [[ -n "$item" ]] || continue
    validate_url_value "$item"
    out="${out}${sep}\"${item}\""
    sep=", "
  done
  IFS="$old_ifs"
  [[ "$out" != "[" ]] || fatal "未输入有效的 registry mirror URL。"
  printf '%s]' "$out"
}

source_base_url() {
  local source="${1:-$DEFAULT_SOURCE}" url
  case "$source" in
    official) printf '' ;;
    tuna) printf 'https://mirrors.tuna.tsinghua.edu.cn' ;;
    ustc) printf 'https://mirrors.ustc.edu.cn' ;;
    aliyun) printf 'https://mirrors.aliyun.com' ;;
    tencent) printf 'https://mirrors.cloud.tencent.com' ;;
    bfsu) printf 'https://mirrors.bfsu.edu.cn' ;;
    custom:*)
      url="${source#custom:}"
      url="$(trim_string "$url")"
      validate_url_value "$url"
      printf '%s' "${url%/}"
      ;;
    http://*|https://*) validate_url_value "$source"; printf '%s' "${source%/}" ;;
    *) fatal "未知镜像源：$source，可选：official/tuna/ustc/aliyun/tencent/bfsu/custom:<url>" ;;
  esac
}

backup_root() {
  if is_macos; then
    printf '%s/.local/state/linux-admin-toolkit/backups' "$(target_user_home)"
  else
    printf '%s' "$BACKUP_ROOT"
  fi
}

homebrew_mirror_block() {
  local source="${1:-official}" base
  case "$source" in
    official) return 1 ;;
    tuna)
      cat <<'EOF_HOMEBREW_MIRROR'
export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
EOF_HOMEBREW_MIRROR
      ;;
    ustc)
      cat <<'EOF_HOMEBREW_MIRROR'
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
EOF_HOMEBREW_MIRROR
      ;;
    aliyun)
      cat <<'EOF_HOMEBREW_MIRROR'
export HOMEBREW_API_DOMAIN="https://mirrors.aliyun.com/homebrew-bottles/api"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.aliyun.com/homebrew/homebrew-bottles"
EOF_HOMEBREW_MIRROR
      ;;
    tencent)
      cat <<'EOF_HOMEBREW_MIRROR'
export HOMEBREW_API_DOMAIN="https://mirrors.cloud.tencent.com/homebrew-bottles/api"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.cloud.tencent.com/homebrew-bottles"
EOF_HOMEBREW_MIRROR
      ;;
    bfsu)
      cat <<'EOF_HOMEBREW_MIRROR'
export HOMEBREW_API_DOMAIN="https://mirrors.bfsu.edu.cn/homebrew-bottles/api"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.bfsu.edu.cn/homebrew-bottles"
EOF_HOMEBREW_MIRROR
      ;;
    custom:*|http://*|https://*)
      base="$(source_base_url "$source")"
      cat <<EOF_HOMEBREW_MIRROR
export HOMEBREW_API_DOMAIN="${base%/}/homebrew-bottles/api"
export HOMEBREW_BOTTLE_DOMAIN="${base%/}/homebrew-bottles"
EOF_HOMEBREW_MIRROR
      ;;
    *) fatal "未知 Homebrew 镜像源：$source" ;;
  esac
}

set_homebrew_mirror() {
  local source="${1:-official}" home zprofile zshrc bashrc block
  ensure_target_home
  home="$(target_user_home)"
  zprofile="$home/.zprofile"
  zshrc="$home/.zshrc"
  bashrc="$home/.bashrc"
  backup_sources
  if [[ "$source" == "official" ]]; then
    remove_managed_block "$zprofile" "homebrew-mirror"
    remove_managed_block "$zshrc" "homebrew-mirror"
    remove_managed_block "$bashrc" "homebrew-mirror"
    success "已移除脚本管理的 Homebrew 镜像环境变量。重新打开终端后将回到 Homebrew 默认源。"
    return 0
  fi
  block="$(homebrew_mirror_block "$source")"
  write_managed_block "$zprofile" "homebrew-mirror" "$block"
  write_managed_block "$zshrc" "homebrew-mirror" "$block"
  write_managed_block "$bashrc" "homebrew-mirror" "$block"
  chown_target "$zprofile" "$zshrc" "$bashrc"
  success "Homebrew 镜像环境变量已写入 .zprofile/.zshrc/.bashrc。新开终端或 source 后生效。"
  warn "macOS 没有 Linux 发行版系统源；这里配置的是 Homebrew bottle/API 镜像。"
}

backup_sources() {
  local ts dir root home
  ts="$(date +%Y%m%d-%H%M%S)"
  root="$(backup_root)"
  dir="$root/$ts"
  if is_macos; then
    run mkdir -p "$dir"
    home="$(target_user_home)"
    run mkdir -p "$dir/home"
    run_shell "cp -a '$home/.zprofile' '$home/.zshrc' '$home/.bashrc' '$dir/home/' 2>/dev/null || true"
    success "macOS/Homebrew 相关配置已备份到：$dir"
    return 0
  fi
  run_privileged mkdir -p "$dir"
  if [[ -d /etc/apt ]]; then
    run mkdir -p "$dir/etc/apt"
    run_shell "cp -a /etc/apt/sources.list /etc/apt/sources.list.d '$dir/etc/apt/' 2>/dev/null || true"
  fi
  if [[ -d /etc/yum.repos.d ]]; then
    run mkdir -p "$dir/etc/yum.repos.d"
    run_shell "cp -a /etc/yum.repos.d/*.repo '$dir/etc/yum.repos.d/' 2>/dev/null || true"
  fi
  success "镜像源已备份到：$dir"
}

list_source_backups() {
  local root
  root="$(backup_root)"
  mkdir -p "$root" 2>/dev/null || run_privileged mkdir -p "$root"
  find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed "s#^$root/##" | sort || true
}

validate_backup_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || fatal "备份目录名不能为空。"
  [[ "$name" != */* && "$name" != *..* ]] || fatal "备份目录名不合法：$name"
}

restore_sources() {
  local name="${1:-}" dir home
  if [[ -z "$name" ]]; then
    echo "可用备份："
    list_source_backups
    read -r -p "输入要恢复的备份目录名：" name
  fi
  validate_backup_name "$name"
  dir="$(backup_root)/$name"
  [[ -d "$dir" ]] || fatal "备份不存在：$dir"
  confirm "确认恢复 ${dir} 到源/配置？" || cancelled
  if is_macos; then
    home="$(target_user_home)"
    [[ -d "$dir/home" ]] || fatal "该备份中没有 macOS shell 配置：$dir/home"
    run_shell "cp -a '$dir/home/'* '$home/' 2>/dev/null || true"
    chown_target "$home/.zprofile" "$home/.zshrc" "$home/.bashrc" 2>/dev/null || true
    success "macOS/Homebrew 相关配置恢复完成。"
    return 0
  fi
  if [[ -d "$dir/etc/apt" ]]; then
    run_shell "cp -a '$dir/etc/apt/'* /etc/apt/ 2>/dev/null || true"
  fi
  if [[ -d "$dir/etc/yum.repos.d" ]]; then
    run_shell "cp -a '$dir/etc/yum.repos.d/'*.repo /etc/yum.repos.d/ 2>/dev/null || true"
  fi
  refresh_pkg_cache
  success "恢复完成。"
}

debian_components() {
  local major="${OS_VERSION_ID%%.*}"
  if [[ "$major" =~ ^[0-9]+$ && "$major" -ge 12 ]]; then
    printf 'main contrib non-free non-free-firmware'
  else
    printf 'main contrib non-free'
  fi
}

apt_repo_path_for_ubuntu() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64|i386) printf 'ubuntu' ;;
    *) printf 'ubuntu-ports' ;;
  esac
}

set_apt_mirror() {
  local source="${1:-$DEFAULT_SOURCE}" base codename repo_path components signed_by target_file main_uri security_uri
  source_base_url "$source" >/dev/null || return 1
  codename="$(get_codename)"
  [[ -n "$codename" ]] || fatal "无法识别系统代号 codename，请手工指定源。"

  if is_kylin && [[ "$OS_LIKE" != *debian* && "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
    skipped "检测到麒麟系统。为避免破坏厂商源/授权源，脚本不会强制替换系统源。常用工具和 Docker 仍可按 yum/dnf/apt 逻辑使用。"
  fi

  backup_sources
  if [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" == *ubuntu* ]]; then
    repo_path="$(apt_repo_path_for_ubuntu)"
    components="main restricted universe multiverse"
    signed_by="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
    if [[ "$source" == "official" ]]; then
      if [[ "$repo_path" == "ubuntu-ports" ]]; then
        main_uri="http://ports.ubuntu.com/ubuntu-ports"
        security_uri="$main_uri"
      else
        main_uri="http://archive.ubuntu.com/ubuntu"
        security_uri="http://security.ubuntu.com/ubuntu"
      fi
    else
      base="$(source_base_url "$source")"
      main_uri="${base}/${repo_path}"
      security_uri="$main_uri"
    fi
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
      target_file="/etc/apt/sources.list.d/ubuntu.sources"
      write_file "$target_file" <<EOF_UBUNTU_DEB822
Types: deb
URIs: ${main_uri}
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: ${components}
Signed-By: ${signed_by}

Types: deb
URIs: ${security_uri}
Suites: ${codename}-security
Components: ${components}
Signed-By: ${signed_by}
EOF_UBUNTU_DEB822
    else
      target_file="/etc/apt/sources.list"
      write_file "$target_file" <<EOF_UBUNTU_LIST
deb ${main_uri} ${codename} ${components}
deb ${main_uri} ${codename}-updates ${components}
deb ${main_uri} ${codename}-backports ${components}
deb ${security_uri} ${codename}-security ${components}
EOF_UBUNTU_LIST
    fi
  else
    components="$(debian_components)"
    signed_by="/usr/share/keyrings/debian-archive-keyring.gpg"
    if [[ "$source" == "official" ]]; then
      main_uri="http://deb.debian.org/debian"
      security_uri="http://deb.debian.org/debian-security"
    else
      base="$(source_base_url "$source")"
      main_uri="${base}/debian"
      security_uri="${base}/debian-security"
    fi
    if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
      target_file="/etc/apt/sources.list.d/debian.sources"
      write_file "$target_file" <<EOF_DEBIAN_DEB822
Types: deb
URIs: ${main_uri}
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: ${components}
Signed-By: ${signed_by}

Types: deb
URIs: ${security_uri}
Suites: ${codename}-security
Components: ${components}
Signed-By: ${signed_by}
EOF_DEBIAN_DEB822
    else
      target_file="/etc/apt/sources.list"
      write_file "$target_file" <<EOF_DEBIAN_LIST
deb ${main_uri} ${codename} ${components}
deb ${main_uri} ${codename}-updates ${components}
deb ${main_uri} ${codename}-backports ${components}
deb ${security_uri} ${codename}-security ${components}
EOF_DEBIAN_LIST
    fi
  fi
  success "已写入 apt 源：${target_file}"
  refresh_pkg_cache
}

set_rpm_mirror() {
  local source="${1:-$DEFAULT_SOURCE}" base
  source_base_url "$source" >/dev/null || return 1
  if [[ "$source" == "official" ]]; then
    skipped "RPM 系发行版官方源格式差异较大，脚本不强制重写为官方源。海外环境通常保持默认源即可；如需回滚，请使用“恢复备份”。"
  fi
  base="$(source_base_url "$source")"
  backup_sources

  if is_kylin; then
    skipped "检测到麒麟系统。Kylin V10 的系统源和授权/厂商仓库相关，脚本只做备份，不自动替换。"
  fi

  if is_fedora; then
    run_shell "sed -i.linux-admin.bak -e 's|^metalink=|#metalink=|g' -e 's|^#baseurl=http://download.example/pub/fedora/linux|baseurl=${base}/fedora|g' -e 's|^#baseurl=https://download.example/pub/fedora/linux|baseurl=${base}/fedora|g' /etc/yum.repos.d/fedora*.repo"
  elif grep -qi 'stream' /etc/os-release 2>/dev/null; then
    warn "CentOS Stream 源格式随版本变化较大，优先执行通用替换。若 makecache 失败，请恢复备份后手工处理。"
    run_shell "sed -i.linux-admin.bak -e 's|^metalink=|#metalink=|g' -e 's|^mirrorlist=|#mirrorlist=|g' -e 's|^#baseurl=http://mirror.stream.centos.org|baseurl=${base}/centos-stream|g' -e 's|^#baseurl=https://mirror.stream.centos.org|baseurl=${base}/centos-stream|g' /etc/yum.repos.d/*.repo"
  else
    run_shell "sed -i.linux-admin.bak -e 's|^mirrorlist=|#mirrorlist=|g' -e 's|^#baseurl=http://mirror.centos.org/centos|baseurl=${base}/centos|g' -e 's|^#baseurl=http://mirror.centos.org/\$contentdir|baseurl=${base}/centos|g' -e 's|^#baseurl=https://mirror.centos.org/centos|baseurl=${base}/centos|g' /etc/yum.repos.d/*.repo"
  fi
  refresh_pkg_cache
  success "RPM 镜像源处理完成。"
}

set_system_mirror() {
  local source="${1:-$DEFAULT_SOURCE}"
  if is_macos; then
    set_homebrew_mirror "$source"
    return 0
  fi
  case "$PKG_MANAGER" in
    apt) set_apt_mirror "$source" ;;
    dnf|yum) set_rpm_mirror "$source" ;;
    *) fatal "未检测到支持的包管理器。" ;;
  esac
}

choose_mirror_source() {
  local c custom
  CHOSEN_MIRROR_SOURCE=""
  cat <<'EOF_SOURCE_MENU'

选择源：
1) 官方源 official（默认，适合海外/网络通畅环境）
2) 清华 TUNA tuna
3) 中科大 USTC ustc
4) 阿里云 aliyun
5) 腾讯云 tencent
6) BFSU bfsu
7) 自定义基础 URL
EOF_SOURCE_MENU
  read -r -p "请输入选项或源名称 [1]: " c
  c="$(trim_string "${c:-1}")"
  case "$c" in
    1|official|官方|官方源) CHOSEN_MIRROR_SOURCE="official" ;;
    2|tuna|TUNA|清华|清华源) CHOSEN_MIRROR_SOURCE="tuna" ;;
    3|ustc|USTC|中科大|中科大源) CHOSEN_MIRROR_SOURCE="ustc" ;;
    4|aliyun|ALIYUN|阿里|阿里云) CHOSEN_MIRROR_SOURCE="aliyun" ;;
    5|tencent|TENCENT|腾讯|腾讯云) CHOSEN_MIRROR_SOURCE="tencent" ;;
    6|bfsu|BFSU|北外) CHOSEN_MIRROR_SOURCE="bfsu" ;;
    7)
      read -r -p "输入基础 URL，如 https://mirrors.example.com: " custom
      custom="$(trim_string "$custom")"
      [[ -n "$custom" ]] || { warn "未输入自定义 URL，使用官方源。"; CHOSEN_MIRROR_SOURCE="official"; return 0; }
      if ! is_http_url "$custom"; then
        warn "URL 格式不正确，使用官方源。"
        CHOSEN_MIRROR_SOURCE="official"
        return 0
      fi
      CHOSEN_MIRROR_SOURCE="custom:${custom%/}"
      ;;
    http://*|https://*) CHOSEN_MIRROR_SOURCE="${c%/}" ;;
    custom:http://*|custom:https://*) CHOSEN_MIRROR_SOURCE="${c%/}" ;;
    *) warn "无效选择：${c}，使用官方源。"; CHOSEN_MIRROR_SOURCE="official" ;;
  esac
}

menu_set_system_mirror() {
  local s
  choose_mirror_source
  s="$CHOSEN_MIRROR_SOURCE"
  [[ -n "$s" ]] || cancelled
  info "已选择源：${s}"
  set_system_mirror "$s"
}

# ---------- Docker ----------
docker_repo_base() {
  local source="${1:-$DEFAULT_DOCKER_SOURCE}" url
  case "$source" in
    official) printf 'https://download.docker.com' ;;
    tuna) printf 'https://mirrors.tuna.tsinghua.edu.cn/docker-ce' ;;
    ustc) printf 'https://mirrors.ustc.edu.cn/docker-ce' ;;
    aliyun) printf 'https://mirrors.aliyun.com/docker-ce' ;;
    tencent) printf 'https://mirrors.cloud.tencent.com/docker-ce' ;;
    bfsu) printf 'https://mirrors.bfsu.edu.cn/docker-ce' ;;
    custom:*)
      url="${source#custom:}"
      url="$(trim_string "$url")"
      validate_url_value "$url"
      printf '%s' "${url%/}"
      ;;
    http://*|https://*) validate_url_value "$source"; printf '%s' "${source%/}" ;;
    *) fatal "未知 Docker 源：$source，可选：official/tuna/ustc/aliyun/tencent/bfsu/custom:<url>" ;;
  esac
}

docker_repo_os() {
  if [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" == *ubuntu* ]]; then
    printf 'ubuntu'
  elif [[ "$OS_ID" == "debian" || "$OS_LIKE" == *debian* ]]; then
    printf 'debian'
  elif is_fedora; then
    printf 'fedora'
  elif is_kylin; then
    if [[ "$PKG_MANAGER" == "apt" ]]; then printf 'debian'; else printf 'centos'; fi
  else
    printf 'centos'
  fi
}

remove_old_docker_conflicts() {
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    pkg_remove docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc || true
  else
    pkg_remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman-docker || true
  fi
}

install_docker_macos() {
  ensure_brew
  brew_run install --cask docker-desktop
  if [[ -d /Applications/Docker.app || -d "$(target_user_home)/Applications/Docker.app" ]]; then
    success "Docker Desktop 已安装。首次使用请从 Applications 启动 Docker。"
  else
    fatal "Docker Desktop 安装后未检测到 App。"
  fi
}

install_docker_apt() {
  local source="${1:-$DEFAULT_DOCKER_SOURCE}" base repo_os codename arch list_file
  base="$(docker_repo_base "$source")"
  repo_os="$(docker_repo_os)"
  codename="$(get_codename)"
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  [[ -n "$codename" ]] || fatal "无法识别 codename，无法配置 Docker apt 源。"
  remove_old_docker_conflicts
  pkg_install ca-certificates curl gnupg
  run install -m 0755 -d /etc/apt/keyrings
  run_shell "curl -fsSL '${base}/linux/${repo_os}/gpg' | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg"
  run chmod a+r /etc/apt/keyrings/docker.gpg
  list_file="/etc/apt/sources.list.d/docker.list"
  write_file "$list_file" <<EOF_DOCKER_APT
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] ${base}/linux/${repo_os} ${codename} stable
EOF_DOCKER_APT
  refresh_pkg_cache
  pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rpm() {
  local source="${1:-$DEFAULT_DOCKER_SOURCE}" base repo_os repo_url
  base="$(docker_repo_base "$source")"
  repo_os="$(docker_repo_os)"
  remove_old_docker_conflicts
  pkg_install yum-utils
  repo_url="${base}/linux/${repo_os}/docker-ce.repo"
  if has_cmd dnf; then
    run dnf config-manager --add-repo "$repo_url"
  else
    run yum-config-manager --add-repo "$repo_url"
  fi
  if [[ "$source" != "official" ]]; then
    run_shell "sed -i.bak 's#https://download.docker.com#${base}#g' /etc/yum.repos.d/docker-ce.repo"
  fi
  pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker() {
  local source="${1:-$DEFAULT_DOCKER_SOURCE}"
  if is_macos; then
    confirm "即将安装 Docker Desktop。是否继续？" || cancelled
    install_docker_macos
    return 0
  fi
  confirm "即将安装 Docker，并可能移除系统中冲突的旧 Docker/Podman 兼容包。是否继续？" || cancelled
  case "$PKG_MANAGER" in
    apt) install_docker_apt "$source" ;;
    dnf|yum) install_docker_rpm "$source" ;;
    *) fatal "未检测到支持的包管理器。" ;;
  esac
  has_cmd docker || fatal "Docker 安装后未检测到 docker 命令。"
  if has_cmd systemctl; then
    run systemctl enable --now docker
  fi
  success "Docker 安装完成。"
}

menu_install_docker() {
  local s
  if is_macos; then
    install_docker official
    return $?
  fi
  choose_mirror_source
  s="$CHOSEN_MIRROR_SOURCE"
  [[ -n "$s" ]] || cancelled
  info "已选择 Docker 源：${s}"
  install_docker "$s"
}

configure_docker_registry_mirror() {
  if is_macos; then
    warn "macOS Docker Desktop 的 registry mirror 建议在 Docker Desktop Settings 中配置；CLI 不强制改配置文件。"
    return 0
  fi
  local mirrors daemon_json content
  mirrors="${1:-}"
  if [[ -z "$mirrors" ]]; then
    echo "输入 Docker Registry mirrors，多个用逗号分隔；留空则清空脚本管理配置。"
    read -r -p "Registry mirrors: " mirrors
  fi
  confirm "即将写入 Docker daemon 配置并重启 Docker。是否继续？" || cancelled
  daemon_json="/etc/docker/daemon.json"
  run mkdir -p /etc/docker
  if [[ -z "$(trim_string "$mirrors")" ]]; then
    write_file "$daemon_json" <<'EOF_DOCKER_DAEMON'
{}
EOF_DOCKER_DAEMON
  else
    content="$(registry_mirrors_json "$mirrors")"
    write_file "$daemon_json" <<EOF_DOCKER_DAEMON
{
  "registry-mirrors": ${content}
}
EOF_DOCKER_DAEMON
  fi
  if has_cmd systemctl; then
    run systemctl daemon-reload
    run systemctl restart docker
  fi
  success "Docker Registry mirror 配置完成：${daemon_json}"
}

save_docker_images_one_by_one() {
  has_cmd docker || fatal "未检测到 docker 命令。"
  docker info >/dev/null 2>&1 || fatal "Docker daemon 不可用，请先启动 Docker。"
  local dir image safe out count=0
  dir="${1:-}"
  if [[ -z "$dir" ]]; then
    read -r -p "输入镜像导出目录 [${HOME:-/root}/docker-images]: " dir
    dir="${dir:-${HOME:-/root}/docker-images}"
  fi
  run mkdir -p "$dir"
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    safe="$(printf '%s' "$image" | tr '/:@' '___')"
    out="$dir/${safe}.tar.gz"
    info "导出镜像：${image} -> ${out}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "+ docker save $image | gzip > $out"
      count=$((count + 1))
      continue
    fi
    docker save "$image" | gzip > "$out"
    [[ -s "$out" ]] || fatal "导出失败或文件为空：$out"
    count=$((count + 1))
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true)
  [[ "$count" -gt 0 ]] || warn "没有可导出的本地镜像。"
  success "Docker 镜像导出完成，数量：${count}。"
}

uninstall_docker() {
  local remove_data="${1:-0}"
  confirm "即将卸载 Docker 相关软件包。是否继续？" || cancelled
  if is_macos; then
    ensure_brew
    brew_run uninstall --cask docker-desktop || true
    if [[ -d /Applications/Docker.app || -d "$(target_user_home)/Applications/Docker.app" ]]; then
      fatal "Docker Desktop App 仍存在，可能未完全卸载。"
    fi
    success "Docker Desktop 卸载完成。"
    return 0
  fi
  if has_cmd systemctl; then
    run systemctl stop docker || true
  fi
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    pkg_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
  else
    pkg_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
  fi
  if [[ "$remove_data" == "1" ]]; then
    confirm "确认删除 /var/lib/docker /var/lib/containerd？" && run rm -rf /var/lib/docker /var/lib/containerd
  fi
  if has_cmd docker; then
    fatal "docker 命令仍然存在，未能确认完全卸载。"
  fi
  success "Docker 卸载完成。"
}

menu_docker_status() {
  if is_macos; then
    if [[ -d /Applications/Docker.app || -d "$(target_user_home)/Applications/Docker.app" ]]; then
      success "Docker Desktop App 已安装。"
    else
      warn "未检测到 Docker Desktop App。"
    fi
    if has_cmd docker; then
      docker version || true
    else
      warn "当前 PATH 中未检测到 docker CLI。"
    fi
    return 0
  fi
  if has_cmd systemctl; then
    systemctl status docker --no-pager 2>/dev/null && return 0
  fi
  if has_cmd docker; then
    docker version || true
  else
    warn "未检测到 docker 命令。"
  fi
}

# ---------- 防火墙 ----------
is_firewalld_port_rule() {
  [[ "${1:-}" =~ ^[0-9]+(-[0-9]+)?/(tcp|udp|sctp|dccp)$ ]]
}

preferred_firewall() {
  if is_macos; then
    printf 'application-firewall'
  elif has_cmd ufw; then
    printf 'ufw'
  elif has_cmd firewall-cmd; then
    printf 'firewalld'
  elif [[ "$PKG_MANAGER" == "apt" ]]; then
    printf 'ufw'
  else
    printf 'firewalld'
  fi
}

install_firewall() {
  if is_macos; then
    success "macOS 自带 Application Firewall，无需安装。"
    return 0
  fi
  case "$(preferred_firewall)" in
    ufw) pkg_install ufw; has_cmd ufw || fatal "ufw 安装后未检测到命令。" ;;
    firewalld) pkg_install firewalld; has_cmd firewall-cmd || fatal "firewalld 安装后未检测到 firewall-cmd。" ;;
  esac
  success "防火墙安装完成。"
}

firewall_status() {
  if is_macos; then
    run_privileged /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
    return 0
  fi
  if has_cmd ufw; then
    run ufw status verbose
  elif has_cmd firewall-cmd; then
    run firewall-cmd --state
    run firewall-cmd --list-all
  else
    warn "未安装 ufw/firewalld。"
  fi
}

firewall_enable() {
  if is_macos; then
    confirm "即将启用 macOS Application Firewall。是否继续？" || cancelled
    run_privileged /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
    return 0
  fi
  confirm "即将启用防火墙。请确认 SSH 等远程管理端口已放行。是否继续？" || cancelled
  install_firewall
  if has_cmd ufw; then
    run ufw --force enable
  else
    run systemctl enable --now firewalld
  fi
}

firewall_disable() {
  if is_macos; then
    confirm "即将停用 macOS Application Firewall。是否继续？" || cancelled
    run_privileged /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
    return 0
  fi
  confirm "即将停用防火墙，系统暴露面可能扩大。是否继续？" || cancelled
  if has_cmd ufw; then
    run ufw disable
  elif has_cmd systemctl; then
    run systemctl disable --now firewalld
  else
    warn "未检测到防火墙命令。"
  fi
}

firewall_allow() {
  if is_macos; then
    not_applicable "macOS Application Firewall 不按 Linux 端口规则管理。"
    return $?
  fi
  local rule="${1:-}"
  [[ -n "$rule" ]] || { read -r -p "允许端口/服务，如 22/tcp 或 http: " rule; }
  [[ -n "$rule" ]] || cancelled
  confirm "即将放行 ${rule}。是否继续？" || cancelled
  if has_cmd ufw; then
    run ufw allow "$rule"
  elif has_cmd firewall-cmd; then
    if is_firewalld_port_rule "$rule"; then
      run firewall-cmd --permanent --add-port="$rule"
    else
      run firewall-cmd --permanent --add-service="$rule"
    fi
    run firewall-cmd --reload
  else
    fatal "未安装防火墙。"
  fi
}

firewall_deny() {
  if is_macos; then
    not_applicable "macOS Application Firewall 不按 Linux 端口规则管理。"
    return $?
  fi
  local rule="${1:-}"
  [[ -n "$rule" ]] || { read -r -p "拒绝或移除放行的端口/服务，如 22/tcp 或 http: " rule; }
  [[ -n "$rule" ]] || cancelled
  confirm "即将拒绝或移除 ${rule} 的放行规则。是否继续？" || cancelled
  if has_cmd ufw; then
    run ufw deny "$rule"
  elif has_cmd firewall-cmd; then
    if is_firewalld_port_rule "$rule"; then
      run firewall-cmd --permanent --remove-port="$rule"
    else
      run firewall-cmd --permanent --remove-service="$rule"
    fi
    run firewall-cmd --reload
  else
    fatal "未安装防火墙。"
  fi
}

uninstall_firewall() {
  if is_macos; then
    not_applicable "macOS Application Firewall 是系统组件，不支持卸载。"
    return $?
  fi
  confirm "即将卸载防火墙软件包，可能影响当前安全策略。是否继续？" || cancelled
  if has_cmd ufw; then
    pkg_remove ufw
  elif has_cmd firewall-cmd; then
    if has_cmd systemctl; then run systemctl disable --now firewalld || true; fi
    pkg_remove firewalld
  else
    warn "未检测到 ufw/firewalld。"
  fi
}

# ---------- Swap ----------
ensure_linux_only() {
  if is_macos; then
    not_applicable "$1"
    return $?
  fi
}

swap_list() {
  ensure_linux_only "macOS 的虚拟内存由系统自动管理，没有 Linux swapfile 管理逻辑。"
  swapon --show || true
  free -h || true
}

swap_add() {
  ensure_linux_only "macOS 不支持此 Linux swapfile 操作。"
  local size="${1:-}" path="${2:-/swapfile}" confirm_required="${3:-1}" input_path
  [[ -n "$size" ]] || { read -r -p "Swap 大小，如 2G/4096M: " size; }
  [[ -n "$size" ]] || cancelled
  if [[ "${2:-}" == "" ]]; then
    read -r -p "Swap 文件路径 [$path]: " input_path || true
    path="${input_path:-$path}"
  fi
  [[ ! -e "$path" ]] || fatal "文件已存在：$path"
  if [[ "$confirm_required" == "1" ]]; then
    confirm "即将创建 ${path}，大小 ${size}，并写入 /etc/fstab 开机启用。是否继续？" || cancelled
  fi
  if has_cmd fallocate; then
    run fallocate -l "$size" "$path"
  else
    local mb
    mb="$(printf '%s' "$size" | awk 'BEGIN{IGNORECASE=1} /G$/{print int($0)*1024; next} /M$/{print int($0); next} /^[0-9]+$/{print int($0); next}')"
    [[ -n "$mb" ]] || fatal "无法解析大小：$size"
    run dd if=/dev/zero of="$path" bs=1M count="$mb" status=progress
  fi
  run chmod 600 "$path"
  run mkswap "$path"
  run swapon "$path"
  append_line_if_missing /etc/fstab "$path none swap sw 0 0"
  success "Swap 已增加：${path} ${size}"
}

swap_delete() {
  ensure_linux_only "macOS 不支持此 Linux swapfile 操作。"
  local path="${1:-}" confirm_required="${2:-1}"
  [[ -n "$path" ]] || { swap_list; read -r -p "输入要删除的 swap 路径，如 /swapfile: " path; }
  [[ -n "$path" ]] || cancelled
  if [[ "$confirm_required" == "1" ]]; then
    confirm "即将停用并删除 swap 文件 ${path}，同时移除 /etc/fstab 中对应条目。是否继续？" || cancelled
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$path"; then
    run swapoff "$path"
  else
    warn "${path} 当前不是活动 swap，跳过 swapoff。"
  fi
  if [[ -f /etc/fstab ]]; then
    remove_fstab_entry "$path"
  fi
  [[ -e "$path" ]] && run rm -f "$path"
  success "Swap 已删除：${path}"
}

swap_resize() {
  ensure_linux_only "macOS 不支持此 Linux swapfile 操作。"
  local size="${1:-}" path="${2:-/swapfile}" input_path
  [[ -n "$size" ]] || { read -r -p "新的 swap 大小，如 4G: " size; }
  [[ -n "$size" ]] || cancelled
  if [[ "${2:-}" == "" ]]; then
    read -r -p "Swap 文件路径 [$path]: " input_path || true
    path="${input_path:-$path}"
  fi
  [[ -n "$path" ]] || cancelled
  if [[ -e "$path" ]]; then
    confirm "调整大小需要先删除现有 swap 文件 ${path}，再重建为 ${size}。是否继续？" || cancelled
    swap_delete "$path" 0
  fi
  swap_add "$size" "$path" 0
}

# ---------- LVM ----------
lvm_list() {
  ensure_linux_only "macOS 不支持 Linux LVM。"
  has_cmd lsblk && lsblk || true
  has_cmd pvs && pvs || warn "缺少 pvs，请先安装 lvm2。"
  has_cmd vgs && vgs || true
  has_cmd lvs && lvs || true
}

ensure_lvm() {
  ensure_linux_only "macOS 不支持 Linux LVM。"
  has_cmd lvm || pkg_install lvm2
  has_cmd lvm || fatal "lvm2 安装后仍未检测到 lvm 命令。"
}

lvm_create_pv() {
  ensure_lvm
  local dev="${1:-}"
  [[ -n "$dev" ]] || { lsblk; read -r -p "输入要初始化为 PV 的设备，如 /dev/sdb1: " dev; }
  [[ -b "$dev" ]] || fatal "不是块设备：$dev"
  confirm "确认对 ${dev} 执行 pvcreate？这可能破坏原数据。" || cancelled
  run pvcreate "$dev"
}

lvm_create_vg() {
  ensure_lvm
  local vg="${1:-}" line
  shift || true
  [[ -n "$vg" ]] || { read -r -p "VG 名称: " vg; }
  [[ -n "$vg" ]] || cancelled
  if [[ "$#" -eq 0 ]]; then
    read -r -p "输入 PV 设备，多个用空格分隔: " line
    # shellcheck disable=SC2086
    set -- $line
  fi
  [[ "$#" -gt 0 ]] || cancelled
  confirm "即将创建 VG ${vg}，使用 PV：$*。是否继续？" || cancelled
  run vgcreate "$vg" "$@"
}

lvm_create_lv() {
  ensure_lvm
  local vg="${1:-}" name="${2:-}" size="${3:-}" fs="${4:-ext4}" mount="${5:-}"
  [[ -n "$vg" ]] || { vgs; read -r -p "VG 名称: " vg; }
  [[ -n "$name" ]] || read -r -p "LV 名称: " name
  [[ -n "$size" ]] || read -r -p "LV 大小，如 20G 或 100%FREE: " size
  [[ -n "$vg" && -n "$name" && -n "$size" ]] || cancelled
  confirm "即将在 VG ${vg} 中创建 LV ${name}，大小 ${size}。是否继续？" || cancelled
  if [[ "$size" == *%* ]]; then
    run lvcreate -n "$name" -l "$size" "$vg"
  else
    run lvcreate -n "$name" -L "$size" "$vg"
  fi
  local lv="/dev/$vg/$name"
  if confirm "是否格式化 ${lv} 为 ${fs}？"; then
    run mkfs -t "$fs" "$lv"
    if [[ -z "$mount" ]]; then
      read -r -p "挂载目录，留空则不挂载: " mount
    fi
    if [[ -n "$mount" ]]; then
      run mkdir -p "$mount"
      run mount "$lv" "$mount"
      append_line_if_missing /etc/fstab "$lv $mount $fs defaults 0 0"
    fi
  fi
}

lvm_extend_lv() {
  ensure_lvm
  local lv="${1:-}" size="${2:-}"
  [[ -n "$lv" ]] || { lvs; read -r -p "LV 路径，如 /dev/vg0/data: " lv; }
  [[ -n "$size" ]] || read -r -p "扩容大小，如 +10G 或 +100%FREE: " size
  [[ -n "$lv" && -n "$size" ]] || cancelled
  confirm "即将扩容 ${lv}，扩容规格 ${size}，并自动调整文件系统。是否继续？" || cancelled
  if [[ "$size" == *%* ]]; then
    run lvextend -r -l "$size" "$lv"
  else
    run lvextend -r -L "$size" "$lv"
  fi
}

lvm_remove_lv() {
  ensure_lvm
  local lv="${1:-}"
  [[ -n "$lv" ]] || { lvs; read -r -p "要删除的 LV 路径，如 /dev/vg0/data: " lv; }
  [[ -n "$lv" ]] || cancelled
  confirm "确认删除 LV ${lv}？这会删除数据。" || cancelled
  run lvremove -y "$lv"
}

# ---------- 性能排查 ----------
ensure_perf_tools() {
  if is_macos; then
    has_cmd htop || brew_install htop || true
    return 0
  fi
  local missing=""
  for c in mpstat iostat sar htop lsof iotop iftop nload ss; do
    has_cmd "$c" || missing="$missing $c"
  done
  if [[ -n "$missing" ]]; then
    warn "缺少性能排查工具：${missing}，尝试安装。"
    case "$PKG_MANAGER" in
      apt) pkg_install sysstat htop lsof iotop iftop nload iproute2 procps ;;
      dnf|yum) pkg_install sysstat htop lsof iotop iftop nload iproute procps-ng ;;
      *) warn "无法自动安装性能工具。" ;;
    esac
  fi
}

perf_quick() {
  ensure_perf_tools
  echo "========== 系统信息 =========="
  print_env
  echo
  if is_macos; then
    echo "========== 负载 =========="
    uptime || true
    echo
    echo "========== CPU/进程 =========="
    top -l 1 -n 10 -stats pid,command,cpu,mem 2>/dev/null || ps aux | head -n 15
    echo
    echo "========== 内存 =========="
    vm_stat || true
    echo
    echo "========== 磁盘 =========="
    df -h || true
    echo
    echo "========== 网络 =========="
    netstat -ib 2>/dev/null | head -n 20 || true
    return 0
  fi
  echo "========== 负载 =========="
  uptime || true
  echo
  echo "========== CPU =========="
  has_cmd mpstat && mpstat 1 3 || true
  echo
  echo "========== 内存 =========="
  free -h || true
  vmstat 1 3 || true
  echo
  echo "========== 磁盘 =========="
  df -hT || true
  has_cmd iostat && iostat -xz 1 3 || true
  echo
  echo "========== 网络 =========="
  has_cmd ss && ss -s || true
  has_cmd nload && warn "实时网络可运行：nload"
  echo
  echo "========== Top 进程 =========="
  ps aux --sort=-%cpu 2>/dev/null | head -n 10 || true
  ps aux --sort=-%mem 2>/dev/null | head -n 10 || true
}

# ---------- 菜单 ----------
menu_clear() {
  if [[ -t 1 ]]; then
    clear || true
  fi
}

menu_pause() {
  if [[ -t 0 ]]; then
    read -r -p "按 Enter 返回当前菜单..." _unused || true
  fi
}

menu_invalid() {
  warn "无效选择，请重新输入。"
  sleep 1
}

menu_action() {
  local title="$1" rc
  shift
  echo
  info "开始执行：${title}"
  set +e
  ( set -Eeuo pipefail; "$@" )
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    success "操作完成：${title}"
  elif [[ "$rc" -eq "$SKIP_RC" ]]; then
    warn "操作已跳过：${title}"
  elif [[ "$rc" -eq "$CANCEL_RC" ]]; then
    warn "操作已取消：${title}"
  else
    warn "操作未完成或执行失败：${title}，退出码：${rc}"
  fi
  menu_pause
}

menu_tools_config() {
  local c
  while true; do
    menu_clear
    cat <<'EOF_MENU'
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
    read -r -p "选择: " c
    case "${c:-}" in
      1) menu_action "查看常用工具安装状态" tool_status ;;
      2) menu_action "配置 Vim" configure_vim ;;
      3) menu_action "配置 Tmux" configure_tmux ;;
      4) menu_action "配置 Git" configure_git ;;
      5) menu_action "配置基础 Zsh" configure_zsh_basic ;;
      6) menu_action "配置常用工具" configure_common_tools ;;
      7) menu_action "安装 Oh My Zsh" install_oh_my_zsh ;;
      8) menu_action "安装 Oh My Zsh 插件" install_zsh_plugins ;;
      9) menu_action "安装 rupa/z" install_rupa_z ;;
      10) menu_action "初始化完整 Zsh 环境" configure_zsh_full ;;
      11) menu_action "设置默认 Shell 为 zsh" change_default_shell_to_zsh ;;
      0) return ;;
      *) menu_invalid ;;
    esac
  done
}

menu_common_tools() {
  local c
  while true; do
    menu_clear
    cat <<'EOF_MENU'
[常用工具]
1) 安装常用工具
2) 常用工具配置子菜单
3) 安装并初始化完整 Zsh 环境
4) 查看常用工具安装状态
0) 返回上一级
EOF_MENU
    read -r -p "选择: " c
    case "${c:-}" in
      1) menu_action "安装常用工具" install_common_tools ;;
      2) menu_tools_config ;;
      3) menu_action "安装并初始化完整 Zsh 环境" configure_zsh_full ;;
      4) menu_action "查看常用工具安装状态" tool_status ;;
      0) return ;;
      *) menu_invalid ;;
    esac
  done
}

menu_mirror() {
  local c
  while true; do
    menu_clear
    cat <<'EOF_MENU'
[系统镜像源 / Homebrew 镜像]
1) 查看系统环境
2) 备份当前源
3) 切换系统源（官方/镜像/自定义）
4) 列出备份
5) 恢复备份
6) 刷新包缓存
0) 返回上一级
EOF_MENU
    read -r -p "选择: " c
    case "${c:-}" in
      1) menu_action "查看系统环境" print_env ;;
      2) menu_action "备份当前源" backup_sources ;;
      3) menu_action "切换系统源" menu_set_system_mirror ;;
      4) menu_action "列出源备份" list_source_backups ;;
      5) menu_action "恢复源备份" restore_sources ;;
      6) menu_action "刷新包缓存" refresh_pkg_cache ;;
      0) return ;;
      *) menu_invalid ;;
    esac
  done
}

menu_docker() {
  local c
  while true; do
    menu_clear
    cat <<'EOF_MENU'
[Docker]
1) 安装 Docker CE / Docker Desktop
2) 配置 Docker Registry mirror
3) 逐个导出本地镜像为 tar.gz
4) 查看 Docker 状态
5) 卸载 Docker
0) 返回上一级
EOF_MENU
    read -r -p "选择: " c
    case "${c:-}" in
      1) menu_action "安装 Docker" menu_install_docker ;;
      2) menu_action "配置 Docker Registry mirror" configure_docker_registry_mirror ;;
      3) menu_action "逐个导出本地镜像为 tar.gz" save_docker_images_one_by_one ;;
      4) menu_action "查看 Docker 状态" menu_docker_status ;;
      5) menu_action "卸载 Docker" uninstall_docker 0 ;;
      0) return ;;
      *) menu_invalid ;;
    esac
  done
}

menu_firewall() {
  local c
  while true; do
    menu_clear
    cat <<EOF_MENU
[防火墙] 当前优先：$(preferred_firewall)
1) 安装防火墙
2) 查看状态
3) 启用
4) 停用
5) 放行端口/服务
6) 拒绝端口/移除放行
7) 卸载防火墙
0) 返回上一级
EOF_MENU
    read -r -p "选择: " c
    case "${c:-}" in
      1) menu_action "安装防火墙" install_firewall ;;
      2) menu_action "查看防火墙状态" firewall_status ;;
      3) menu_action "启用防火墙" firewall_enable ;;
      4) menu_action "停用防火墙" firewall_disable ;;
      5) menu_action "放行端口/服务" firewall_allow ;;
      6) menu_action "拒绝端口/移除放行" firewall_deny ;;
      7) menu_action "卸载防火墙" uninstall_firewall ;;
      0) return ;;
      *) menu_invalid ;;
    esac
  done
}

menu_swap() {
  local c
  while true; do
    menu_clear
    cat <<'EOF_MENU'
[Swap]
1) 查看 Swap
2) 增加 Swap 文件
3) 调整 Swap 文件大小
4) 删除 Swap
0) 返回上一级
EOF_MENU
    read -r -p "选择: " c
    case "${c:-}" in
      1) menu_action "查看 Swap" swap_list ;;
      2) menu_action "增加 Swap 文件" swap_add ;;
      3) menu_action "调整 Swap 文件大小" swap_resize ;;
      4) menu_action "删除 Swap" swap_delete ;;
      0) return ;;
      *) menu_invalid ;;
    esac
  done
}

menu_lvm() {
  local c
  while true; do
    menu_clear
    cat <<'EOF_MENU'
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
    read -r -p "选择: " c
    case "${c:-}" in
      1) menu_action "查看 PV/VG/LV/块设备" lvm_list ;;
      2) menu_action "安装 lvm2" ensure_lvm ;;
      3) menu_action "创建 PV" lvm_create_pv ;;
      4) menu_action "创建 VG" lvm_create_vg ;;
      5) menu_action "创建 LV" lvm_create_lv ;;
      6) menu_action "扩容 LV" lvm_extend_lv ;;
      7) menu_action "删除 LV" lvm_remove_lv ;;
      0) return ;;
      *) menu_invalid ;;
    esac
  done
}

menu_perf() {
  local c
  while true; do
    menu_clear
    cat <<'EOF_MENU'
[Linux/macOS 性能瓶颈排查]
1) 快速巡检
2) 安装/检查性能工具
0) 返回上一级
EOF_MENU
    read -r -p "选择: " c
    case "${c:-}" in
      1) menu_action "快速性能巡检" perf_quick ;;
      2) menu_action "安装/检查性能工具" ensure_perf_tools ;;
      0) return ;;
      *) menu_invalid ;;
    esac
  done
}

main_menu() {
  local c
  while true; do
    menu_clear
    cat <<EOF_MENU
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
    read -r -p "请选择: " c
    case "${c:-}" in
      1) menu_common_tools ;;
      2) menu_mirror ;;
      3) menu_docker ;;
      4) menu_firewall ;;
      5) menu_swap ;;
      6) menu_lvm ;;
      7) menu_perf ;;
      8) menu_action "查看系统环境" print_env ;;
      0) exit 0 ;;
      *) menu_invalid ;;
    esac
  done
}

# ---------- CLI ----------
usage() {
  cat <<EOF_USAGE
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
  $PROGRAM_NAME tools config all
  $PROGRAM_NAME tools zsh-full
  $PROGRAM_NAME tools install-z
  $PROGRAM_NAME mirror set --source tuna
  $PROGRAM_NAME mirror set --source official
  $PROGRAM_NAME mirror set --source custom:https://mirrors.example.com
  $PROGRAM_NAME docker install --source tuna
  $PROGRAM_NAME docker mirror --registry https://registry.example.com
  $PROGRAM_NAME docker save-images --dir ./docker-images
  $PROGRAM_NAME firewall status
  $PROGRAM_NAME swap add --size 4G --path /swapfile
  $PROGRAM_NAME lvm list
  $PROGRAM_NAME perf quick
EOF_USAGE
}

get_opt_value() {
  local key="$1" arg next
  shift || true
  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      "$key")
        shift || true
        next="${1:-}"
        [[ -n "$next" ]] || return 1
        printf '%s' "$next"
        return 0
        ;;
      "$key"=*)
        printf '%s' "${arg#*=}"
        return 0
        ;;
    esac
    shift || true
  done
  return 1
}

main() {
  detect_os
  while [[ "$#" -gt 0 ]]; do
    case "${1:-}" in
      -y|--yes) ASSUME_YES=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) break ;;
    esac
  done
  local module="${1:-menu}" action="${2:-}"

  case "$module" in
    menu|"")
      require_root "$@"
      main_menu
      ;;
    env)
      print_env
      ;;
    tools)
      require_root "$@"
      case "${action:-}" in
        install) install_common_tools ;;
        status) tool_status ;;
        config)
          case "${3:-all}" in
            all) configure_common_tools ;;
            vim) configure_vim ;;
            tmux) configure_tmux ;;
            git) configure_git ;;
            zsh-basic) configure_zsh_basic ;;
            *) fatal "未知 tools config 动作：${3:-}" ;;
          esac
          ;;
        oh-my-zsh) install_oh_my_zsh "$(get_opt_value --github-proxy "$@" || true)" ;;
        zsh-plugins) install_zsh_plugins "$(get_opt_value --github-proxy "$@" || true)" ;;
        install-z) install_rupa_z "$(get_opt_value --github-proxy "$@" || true)" ;;
        zsh-full) configure_zsh_full ;;
        chsh-zsh) change_default_shell_to_zsh ;;
        *) fatal "未知 tools 动作：${action:-}" ;;
      esac
      ;;
    mirror)
      require_root "$@"
      case "${action:-}" in
        backup) backup_sources ;;
        set) set_system_mirror "$(get_opt_value --source "$@" || printf '%s' "$DEFAULT_SOURCE")" ;;
        list-backups) list_source_backups ;;
        restore) restore_sources "${3:-}" ;;
        refresh) refresh_pkg_cache ;;
        *) fatal "未知 mirror 动作：${action:-}" ;;
      esac
      ;;
    docker)
      require_root "$@"
      case "${action:-}" in
        install) install_docker "$(get_opt_value --source "$@" || printf '%s' "$DEFAULT_DOCKER_SOURCE")" ;;
        mirror) configure_docker_registry_mirror "$(get_opt_value --registry "$@" || true)" ;;
        save-images) save_docker_images_one_by_one "$(get_opt_value --dir "$@" || true)" ;;
        status) menu_docker_status ;;
        uninstall) uninstall_docker "$(get_opt_value --remove-data "$@" || printf '0')" ;;
        *) fatal "未知 docker 动作：${action:-}" ;;
      esac
      ;;
    firewall)
      require_root "$@"
      case "${action:-}" in
        install) install_firewall ;;
        status) firewall_status ;;
        enable) firewall_enable ;;
        disable) firewall_disable ;;
        allow) firewall_allow "${3:-}" ;;
        deny) firewall_deny "${3:-}" ;;
        uninstall) uninstall_firewall ;;
        *) fatal "未知 firewall 动作：${action:-}" ;;
      esac
      ;;
    swap)
      require_root "$@"
      case "${action:-}" in
        list) swap_list ;;
        add) swap_add "$(get_opt_value --size "$@" || true)" "$(get_opt_value --path "$@" || printf '/swapfile')" ;;
        resize) swap_resize "$(get_opt_value --size "$@" || true)" "$(get_opt_value --path "$@" || printf '/swapfile')" ;;
        delete) swap_delete "$(get_opt_value --path "$@" || true)" ;;
        *) fatal "未知 swap 动作：${action:-}" ;;
      esac
      ;;
    lvm)
      require_root "$@"
      case "${action:-}" in
        list) lvm_list ;;
        install) ensure_lvm ;;
        create-pv) lvm_create_pv "${3:-}" ;;
        create-vg) shift 2; lvm_create_vg "$@" ;;
        create-lv) lvm_create_lv "${3:-}" "${4:-}" "${5:-}" ;;
        extend-lv) lvm_extend_lv "${3:-}" "${4:-}" ;;
        remove-lv) lvm_remove_lv "${3:-}" ;;
        *) fatal "未知 lvm 动作：${action:-}" ;;
      esac
      ;;
    perf)
      case "${action:-quick}" in
        quick) perf_quick ;;
        install-tools) ensure_perf_tools ;;
        *) fatal "未知 perf 动作：${action:-}" ;;
      esac
      ;;
    *)
      usage
      fatal "未知模块：${module}"
      ;;
  esac
}

main "$@"
