#!/usr/bin/env bash
#
# lvm-manager.sh — LVM 管理工具 (增 / 删 / 查 / 扩容 / 磁盘信息)
#
# 用法:
#   ./lvm-manager.sh                                  # 交互式菜单
#   ./lvm-manager.sh create -d /dev/sdb -v vg_data -l lv_data -s 100G -f xfs -m /data
#   ./lvm-manager.sh create-vg -d /dev/sdb -v vg_data
#   ./lvm-manager.sh create-lv -v vg_data -l lv_data -s 100G -f xfs -m /data
#   ./lvm-manager.sh extend -v vg_data -d /dev/sdc                    # VG 加盘
#   ./lvm-manager.sh extend -v vg_data -l lv_data -s +50G             # LV + FS 扩容
#   ./lvm-manager.sh delete -v vg_data -l lv_data                     # 删 LV
#   ./lvm-manager.sh delete -v vg_data                                 # 删整个 VG
#   ./lvm-manager.sh delete -d /dev/sdc                                # 删 PV
#   ./lvm-manager.sh list [pvs|vgs|lvs|disk|all]
#   ./lvm-manager.sh info -d /dev/sdb
#
# 选项:
#   -d <设备>      磁盘设备, 如 /dev/sdb
#   -v <卷组>      卷组名, 如 vg_data
#   -l <逻辑卷>    逻辑卷名, 如 lv_data
#   -s <大小>      如 100G / +50G / 100%FREE
#   -f <文件系统>  xfs 或 ext4
#   -m <挂载点>    如 /data
#   -y, --yes      跳过所有确认 (危险操作请谨慎)
#   -n, --dry-run  只打印将执行的操作，不改动系统

set -uo pipefail

# ---------------- 全局变量 ----------------
ASSUME_YES=0
DRY_RUN=0
DISK=""; VG=""; LV=""; SIZE=""; FS=""; MOUNT=""
POS=()
ARGS=()
FSTAB_BACKED_UP=0
PLANNED_VG=0
CREATED_PV=0
CREATED_VG=0
CREATED_LV=0
MOUNT_CONFIRMED=0

# ---------------- 颜色 ----------------
init_color() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
  else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
  fi
}
init_color

disable_color() {
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
}

log_info()  { printf '%s[INFO]%s %s\n' "$GREEN" "$RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*"; }
log_ok()    { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }

reset_opts() {
  DISK=""; VG=""; LV=""; SIZE=""; FS=""; MOUNT=""
  POS=()
  FSTAB_BACKED_UP=0
  PLANNED_VG=0
  CREATED_PV=0
  CREATED_VG=0
  CREATED_LV=0
  MOUNT_CONFIRMED=0
}

# ---------------- 基础检查 ----------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "需要 root 权限，请使用 sudo 运行: sudo $0 $*"
    exit 1
  fi
}

pkg_hint() {
  local pkgs="lvm2 xfsprogs e2fsprogs"
  if   command -v pacman >/dev/null 2>&1; then echo "sudo pacman -S $pkgs"
  elif command -v apt-get >/dev/null 2>&1; then echo "sudo apt install $pkgs"
  elif command -v dnf    >/dev/null 2>&1; then echo "sudo dnf install $pkgs"
  elif command -v yum    >/dev/null 2>&1; then echo "sudo yum install $pkgs"
  elif command -v zypper >/dev/null 2>&1; then echo "sudo zypper install $pkgs"
  else echo "$pkgs"
  fi
}

check_deps() {
  local cmds=(pvcreate pvremove vgcreate vgextend vgremove vgreduce
              lvcreate lvextend lvremove lvchange
              pvs vgs lvs blkid findmnt lsblk mount umount)
  local missing=() c
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    log_error "缺少必要命令: ${missing[*]}"
    log_warn  "请先安装: $(pkg_hint)"
    exit 1
  fi
}

normalize_fs() {
  local fs=${1,,}
  case $fs in
    xfs|ext4) printf '%s\n' "$fs" ;;
    *)        printf '%s\n' "$1" ;;
  esac
}

fs_tools_check() {
  local fs
  fs=$(normalize_fs "$1")
  case $fs in
    xfs)
      for c in mkfs.xfs xfs_growfs; do
        command -v "$c" >/dev/null 2>&1 || { log_error "缺少 $c，请安装 xfsprogs ($(pkg_hint))"; return 1; }
      done ;;
    ext4)
      for c in mkfs.ext4 resize2fs; do
        command -v "$c" >/dev/null 2>&1 || { log_error "缺少 $c，请安装 e2fsprogs ($(pkg_hint))"; return 1; }
      done ;;
    *)
      log_error "不支持的文件系统: $1 (仅支持 xfs / ext4)"
      return 1 ;;
  esac
}

# LVM 名称: 字母数字 . _ + - ，不以 - 或 . 开头，最长 127
valid_lvm_name() {
  local name=$1 what=$2
  if [[ -z $name ]]; then
    log_error "$what 不能为空"
    return 1
  fi
  if (( ${#name} > 127 )); then
    log_error "$what 过长 (最多 127 字符): $name"
    return 1
  fi
  if [[ $name == -* || $name == .* ]]; then
    log_error "$what 不能以 '-' 或 '.' 开头: $name"
    return 1
  fi
  if [[ $name == */* ]]; then
    log_error "$what 不能包含 '/': $name"
    return 1
  fi
  if [[ ! $name =~ ^[A-Za-z0-9._+-]+$ ]]; then
    log_error "$what 只能包含字母、数字和 ._+- : $name"
    return 1
  fi
}

# /dev/VG/LV ，不存在时回退到 mapper 转义名 ( '-' → '--' )
lv_dev() {
  local vg=$1 lv=$2 mapper
  if [[ -e "/dev/$vg/$lv" ]]; then
    printf '%s\n' "/dev/$vg/$lv"
    return 0
  fi
  mapper="/dev/mapper/${vg//-/--}-${lv//-/--}"
  if [[ -e $mapper ]]; then
    printf '%s\n' "$mapper"
    return 0
  fi
  printf '%s\n' "/dev/$vg/$lv"
}

# ---------------- 确认 / 执行 ----------------
confirm() {
  local msg=$1 ans=""
  if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
  if [[ $ASSUME_YES -eq 1 ]]; then log_warn "$msg [自动确认 -y]"; return 0; fi
  printf '%s [y/N]: ' "$msg"
  read -r ans || true
  [[ ${ans:-} =~ ^[Yy](es)?$ ]]
}

confirm_danger() {
  local msg=$1 ans=""
  if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
  if [[ $ASSUME_YES -eq 1 ]]; then log_warn "$msg [自动确认 -y]"; return 0; fi
  printf '%s⚠ %s%s 危险操作，请输入 yes 确认: ' "$RED" "$msg" "$RESET"
  read -r ans || true
  [[ ${ans:-} == "yes" ]]
}

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ---------------- 状态判断 ----------------
pv_exists()  { pvs "$1" >/dev/null 2>&1; }
vg_exists()  { vgs "$1" >/dev/null 2>&1; }
lv_exists()  { lvs "$(lv_dev "$1" "$2")" >/dev/null 2>&1 || lvs "/dev/$1/$2" >/dev/null 2>&1; }

require_vg() {
  if vg_exists "$1"; then return 0; fi
  if [[ $DRY_RUN -eq 1 && $PLANNED_VG -eq 1 ]]; then return 0; fi
  log_error "卷组 $1 不存在"
  return 1
}

pv_in_vg() {
  local vgname
  vgname=$(pvs --noheadings -o vg_name "$1" 2>/dev/null | awk '{print $1}')
  [[ $vgname == "$2" ]]
}

vg_free_mb() {
  vgs --noheadings --nosuffix --units m -o vg_free "$1" 2>/dev/null | awk '{printf "%d", $1}'
}

# dry-run 时把尚未真正加入的磁盘容量计入估算
vg_free_mb_planned() {
  local vg=$1 free extra=0
  free=$(vg_free_mb "$vg")
  free=${free:-0}
  if [[ $DRY_RUN -eq 1 && -n ${DISK:-} ]] && ! pv_in_vg "$DISK" "$vg"; then
    extra=$(disk_size_mb "$DISK" || true)
    extra=${extra:-0}
    if (( extra > 0 )); then
      free=$((free + extra))
      log_info "[dry-run] 加上将加入的磁盘 $DISK 估算可用空间: ${free}MB (未计入 LVM 元数据开销)"
    fi
  fi
  printf '%d\n' "$free"
}

lv_size_mb() {
  lvs --noheadings --nosuffix --units m -o lv_size "$(lv_dev "$1" "$2")" 2>/dev/null \
    | awk '{printf "%d", $1}'
}

disk_size_mb() {
  local bytes
  bytes=$(lsblk -bno SIZE -d "$1" 2>/dev/null | awk 'NR==1 {print $1}')
  [[ -n $bytes ]] || { echo 0; return 1; }
  awk -v b="$bytes" 'BEGIN { printf "%d", b/1024/1024 }'
}

# 大小转 MB，如 100G -> 102400, +50G -> 51200
to_mb() {
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

valid_size() {
  [[ $1 =~ ^\+?[0-9]+([.][0-9]+)?[kKmMgGtTpP]?$ || $1 =~ ^\+?[0-9]+%[A-Z]+$ ]]
}

# 方便写法归一化: max/all → 100%FREE ；百分比后缀转大写
normalize_size() {
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

# 大小参数格式提示 (-s)
size_help() {
  cat <<EOF
${BOLD}大小参数格式 (-s)${RESET}
  绝对值     100G / 500M / 2T        指定固定大小 (create/extend 均可用)
  相对扩容   +50G / +200M             在现有基础上增加 (仅 extend)
  百分比     100%FREE                 占满卷组剩余空间
             50%VG                    卷组总空间的 50%
             50%PVS                   卷组内单个 PV 空间的 50%
  便捷写法   max / all                = 100%FREE, 一键占满剩余空间

示例:
  $0 create -d /dev/sdb -v vg_data -l lv_data -s 100G -f xfs -m /data
  $0 create-vg -d /dev/sdb -v vg_data
  $0 create-lv -v vg_data -l lv_data -s 100G -f ext4 -m /data
  $0 extend -v vg_data -l lv_data -s max
  $0 extend -v vg_data -l lv_data -s +50G
EOF
}

# ---------------- 安全校验 ----------------
disk_is_empty() {
  local dev=$1 devtype base holders_dir holders sig
  [[ -b $dev ]] || { log_error "$dev 不是块设备"; return 1; }

  if findmnt "$dev" >/dev/null 2>&1; then
    log_error "$dev 已挂载，拒绝操作"
    return 1
  fi
  if lsblk -nro MOUNTPOINT "$dev" 2>/dev/null | grep -q '[^[:space:]]'; then
    log_error "$dev 或其分区已挂载，拒绝操作"
    return 1
  fi

  pv_exists "$dev" && { log_error "$dev 已是 PV"; return 1; }

  base=$(basename "$(readlink -f "$dev" 2>/dev/null || echo "$dev")")
  holders_dir="/sys/class/block/$base/holders"
  if [[ -d $holders_dir ]]; then
    holders=$(ls -A "$holders_dir" 2>/dev/null || true)
    if [[ -n $holders ]]; then
      log_error "$dev 被占用 (holders: $holders)，可能属于 multipath/md/dm"
      return 1
    fi
  fi

  if [[ -r /proc/mdstat ]] && grep -Fq "$base" /proc/mdstat; then
    log_error "$dev 出现在 /proc/mdstat，可能属于 mdadm 阵列"
    return 1
  fi

  devtype=$(lsblk -nro TYPE "$dev" 2>/dev/null | head -1)
  if [[ $devtype == disk ]]; then
    if lsblk -nro TYPE "$dev" 2>/dev/null | tail -n +2 | grep -q '^part$'; then
      log_error "$dev 包含分区，不是空盘。如需整盘使用请先: wipefs -a $dev"
      return 1
    fi
  fi

  if command -v wipefs >/dev/null 2>&1; then
    # 优先 -i 去掉表头；老版本没有 -i 时回退，并丢掉 DEVICE 表头行
    if sig=$(wipefs -n -i "$dev" 2>/dev/null); then
      :
    elif sig=$(wipefs -n "$dev" 2>/dev/null); then
      sig=$(printf '%s\n' "$sig" | awk 'NR==1 && $1=="DEVICE" {next} {print}')
    else
      if blkid "$dev" >/dev/null 2>&1; then
        log_error "$dev 存在文件系统/分区表签名 (wipefs 探测失败，blkid 有结果)，不是空盘。如需清空请先: wipefs -a $dev"
        return 1
      fi
      log_error "无法探测 $dev 的签名 (wipefs 失败)，拒绝当作空盘处理"
      return 1
    fi
    sig=$(printf '%s\n' "$sig" | awk 'NF {print}')
    if [[ -n $sig ]]; then
      log_error "$dev 存在文件系统/分区表签名，不是空盘:"
      printf '%s\n' "$sig"
      log_error "如需清空请先: wipefs -a $dev"
      return 1
    fi
  elif blkid "$dev" >/dev/null 2>&1; then
    log_error "$dev 存在文件系统/分区表签名，不是空盘。如需清空请先: wipefs -a $dev"
    return 1
  fi
  return 0
}

is_swap_dev() {
  local dev=$1 real n
  real=$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")
  while read -r n; do
    [[ -z $n ]] && continue
    if [[ $n == "$dev" || $n == "$real" ]]; then return 0; fi
    if [[ $(readlink -f "$n" 2>/dev/null || true) == "$real" ]]; then return 0; fi
  done < <(swapon --noheadings --show=NAME 2>/dev/null || true)
  return 1
}

swap_off_if_needed() {
  local dev=$1
  is_swap_dev "$dev" || return 0
  run swapoff "$dev" || { log_error "swapoff $dev 失败"; return 1; }
  log_info "已关闭 swap $dev"
}

# ---------------- fstab ----------------
fstab_has_uuid() { awk -v u="UUID=$1" '$1==u {found=1} END{exit !found}' /etc/fstab; }
fstab_has_mp()   { awk -v mp="$1" '$2==mp {found=1} END{exit !found}' /etc/fstab; }

backup_fstab() {
  local bak
  [[ $FSTAB_BACKED_UP -eq 1 ]] && return 0
  [[ -f /etc/fstab ]] || { log_error "/etc/fstab 不存在"; return 1; }
  bak="/etc/fstab.bak.lvm-manager.$(date +%Y%m%d-%H%M%S)"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] 备份 /etc/fstab → $bak"
    FSTAB_BACKED_UP=1
    return 0
  fi
  cp -a /etc/fstab "$bak" || { log_error "备份 fstab 失败"; return 1; }
  log_info "已备份 fstab → $bak"
  FSTAB_BACKED_UP=1
}

add_fstab() {
  local vg=$1 lv=$2 fs=$3 mp=$4 uuid pass
  if [[ $DRY_RUN -eq 1 ]]; then
    [[ $fs == xfs ]] && pass=0 || pass=2
    log_info "[dry-run] 写入 /etc/fstab: UUID=<新建>  $mp  $fs  defaults  0  $pass  # lvm-manager"
    return 0
  fi
  uuid=$(blkid -s UUID -o value "$(lv_dev "$vg" "$lv")" 2>/dev/null) \
    || { log_warn "无法获取 UUID，跳过 fstab 写入"; return 1; }
  if fstab_has_uuid "$uuid"; then log_warn "fstab 已存在该 UUID，跳过"; return 0; fi
  if fstab_has_mp "$mp"; then log_warn "fstab 已存在挂载点 $mp，跳过"; return 0; fi
  [[ $fs == xfs ]] && pass=0 || pass=2
  backup_fstab || return 1
  printf 'UUID=%s  %s  %s  defaults  0  %d  # lvm-manager\n' "$uuid" "$mp" "$fs" "$pass" >> /etc/fstab
  log_ok "已写入 /etc/fstab: UUID=$uuid → $mp"
}

rm_fstab_by_uuid() {
  local uuid=$1 tmp
  [[ -n $uuid ]] || return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] 从 /etc/fstab 删除首字段为 UUID=$uuid 的行"
    return 0
  fi
  fstab_has_uuid "$uuid" || return 0
  backup_fstab || return 1
  tmp=$(mktemp /etc/fstab.lvm-manager.XXXXXX) || { log_error "无法创建临时文件"; return 1; }
  if ! awk -v u="UUID=$uuid" '$1==u {next} {print}' /etc/fstab > "$tmp"; then
    rm -f "$tmp"
    log_error "生成新 fstab 失败，原文件未改动"
    return 1
  fi
  if [[ ! -s $tmp ]]; then
    rm -f "$tmp"
    log_error "生成的 fstab 为空，拒绝覆盖 /etc/fstab"
    return 1
  fi
  chmod --reference=/etc/fstab "$tmp" 2>/dev/null || true
  chown --reference=/etc/fstab "$tmp" 2>/dev/null || true
  if command -v chcon >/dev/null 2>&1; then
    chcon --reference=/etc/fstab "$tmp" 2>/dev/null || true
  fi
  # 符号链接不能 mv 覆盖，否则会把链接换成普通文件
  if [[ -L /etc/fstab ]]; then
    if ! cat "$tmp" > /etc/fstab; then
      log_error "写入 /etc/fstab 失败。备份: /etc/fstab.bak.lvm-manager.*  临时文件: $tmp"
      return 1
    fi
    rm -f "$tmp"
    return 0
  fi
  if ! mv -f "$tmp" /etc/fstab; then
    log_error "替换 /etc/fstab 失败，原文件未改动。临时文件: $tmp"
    return 1
  fi
}

print_create_leftover() {
  local bits=() cmds=()
  [[ $DRY_RUN -eq 1 ]] && return 0
  [[ $CREATED_LV -eq 1 ]] && bits+=("LV $VG/$LV") && cmds+=("$0 delete -v $VG -l $LV")
  [[ $CREATED_VG -eq 1 ]] && bits+=("空 VG $VG") && cmds+=("$0 delete -v $VG")
  [[ $CREATED_PV -eq 1 ]] && bits+=("PV $DISK") && cmds+=("$0 delete -d $DISK")
  (( ${#bits[@]} == 0 )) && return 0
  log_warn "本次已落地、需要手动清理: ${bits[*]}"
  log_warn "清理: ${cmds[*]}"
}

# ---------------- 增: 创建 ----------------
# 确保 DISK 作为 PV 属于 VG；VG 不存在则新建。
ensure_pv_in_vg() {
  if ! vg_exists "$VG"; then
    disk_is_empty "$DISK" || return 1
    confirm "将 $DISK 创建为 PV 并加入新卷组 $VG ?" || return 1
    run pvcreate -y "$DISK" || return 1
    [[ $DRY_RUN -eq 1 ]] || CREATED_PV=1
    if ! run vgcreate "$VG" "$DISK"; then
      log_warn "卷组创建失败，回滚: pvremove $DISK"
      run pvremove -y "$DISK" >/dev/null 2>&1 || true
      CREATED_PV=0
      return 1
    fi
    [[ $DRY_RUN -eq 1 ]] || CREATED_VG=1
    PLANNED_VG=1
    return 0
  fi

  if pv_in_vg "$DISK" "$VG"; then
    log_info "$DISK 已在卷组 $VG 中"
    return 0
  fi
  if pv_exists "$DISK"; then
    local othervg
    othervg=$(pvs --noheadings -o vg_name "$DISK" 2>/dev/null | awk '{print $1}')
    if [[ -n $othervg && $othervg != " " ]]; then
      log_error "$DISK 属于卷组 $othervg，不能加入 $VG。请先: $0 delete -d $DISK 释放该 PV"
    else
      log_error "$DISK 已是独立 PV，不能当作空盘创建。请用: $0 extend -v $VG -d $DISK"
    fi
    return 1
  fi
  disk_is_empty "$DISK" || return 1
  confirm "卷组 $VG 已存在，将 $DISK 加入 ?" || return 1
  run pvcreate -y "$DISK" || return 1
  [[ $DRY_RUN -eq 1 ]] || CREATED_PV=1
  if ! run vgextend -y "$VG" "$DISK"; then
    run pvremove -y "$DISK" >/dev/null 2>&1 || true
    CREATED_PV=0
    return 1
  fi
}

check_lv_space() {
  local need free
  if [[ $SIZE == *%* || $SIZE == +* ]]; then
    return 0
  fi
  need=$(to_mb "$SIZE")
  if vg_exists "$VG"; then
    free=$(vg_free_mb_planned "$VG")
  elif [[ $DRY_RUN -eq 1 && -n $DISK ]]; then
    free=$(disk_size_mb "$DISK")
    log_info "[dry-run] 按磁盘容量估算可用空间: ${free}MB (未计入 LVM 元数据开销)"
  else
    free=$(vg_free_mb "$VG")
  fi
  if (( need > free )); then
    log_error "卷组 $VG 剩余空间不足: 需要 ${need}MB, 剩余 ${free}MB"
    return 1
  fi
  if [[ $FS == xfs && need -lt 300 ]]; then
    log_error "xfs 文件系统最小需要 300MB，当前仅 ${need}MB。请加大大小，或改用 ext4 (输入 sizes 查看格式)"
    return 1
  fi
}

check_mount_target() {
  [[ $MOUNT == /* ]] || { log_error "挂载点必须是绝对路径: $MOUNT"; return 1; }
  [[ $MOUNT != "/" ]] || { log_error "禁止挂载到根目录 /"; return 1; }
  if findmnt "$MOUNT" >/dev/null 2>&1; then
    log_error "挂载点 $MOUNT 已被占用"
    return 1
  fi
  if [[ -d $MOUNT ]] && [[ -n $(ls -A "$MOUNT" 2>/dev/null) ]]; then
    log_warn "挂载点 $MOUNT 已存在且非空，挂载后原内容将被暂时隐藏"
    if [[ $MOUNT_CONFIRMED -eq 0 ]]; then
      confirm "继续挂载到非空目录 $MOUNT ?" || return 1
      MOUNT_CONFIRMED=1
    fi
  fi
}

# 在已有 VG 上创建 LV + 文件系统 + 挂载 + fstab
create_lv_on_vg() {
  local dev
  require_vg "$VG" || return 1
  lv_exists "$VG" "$LV" && { log_error "逻辑卷 $VG/$LV 已存在"; return 1; }
  check_lv_space || return 1
  check_mount_target || return 1

  confirm "创建逻辑卷 $VG/$LV (${SIZE})，格式化为 $FS 并挂载到 $MOUNT ?" || return 1

  if [[ $SIZE == *%* ]]; then
    run lvcreate -y -l "$SIZE" -n "$LV" "$VG" || { print_create_leftover; return 1; }
  else
    run lvcreate -y -L "$SIZE" -n "$LV" "$VG" || { print_create_leftover; return 1; }
  fi
  [[ $DRY_RUN -eq 1 ]] || CREATED_LV=1
  dev=$(lv_dev "$VG" "$LV")

  if [[ $FS == xfs ]]; then
    if ! run mkfs.xfs -f "$dev"; then
      if run lvremove -y "$dev" >/dev/null 2>&1; then
        CREATED_LV=0
        log_error "格式化失败，已删除 LV"
      else
        log_error "格式化失败，且回滚删除 LV 失败，请手动清理 $dev"
      fi
      print_create_leftover
      return 1
    fi
  else
    if ! run mkfs.ext4 -F "$dev"; then
      if run lvremove -y "$dev" >/dev/null 2>&1; then
        CREATED_LV=0
        log_error "格式化失败，已删除 LV"
      else
        log_error "格式化失败，且回滚删除 LV 失败，请手动清理 $dev"
      fi
      print_create_leftover
      return 1
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] mkdir -p $MOUNT"
    log_info "[dry-run] mount $dev $MOUNT"
  else
    mkdir -p "$MOUNT" || { log_error "创建挂载点 $MOUNT 失败"; print_create_leftover; return 1; }
    if ! mount "$dev" "$MOUNT"; then
      log_error "挂载失败。LV 已格式化但未写入 fstab。"
      log_warn "设备: $dev  挂载点: $MOUNT"
      print_create_leftover
      return 1
    fi
  fi
  add_fstab "$VG" "$LV" "$FS" "$MOUNT" || true
  log_ok "创建完成: VG=$VG / LV=$LV($SIZE) / FS=$FS / 挂载点=$MOUNT"
}

cmd_create_vg() {
  if [[ -z $DISK || -z $VG ]]; then
    log_error "create-vg 参数不完整: 需要 -d -v"
    return 1
  fi
  valid_lvm_name "$VG" "卷组名" || return 1
  if vg_exists "$VG"; then
    log_error "卷组 $VG 已存在。若要加盘请用: $0 extend -v $VG -d $DISK"
    return 1
  fi
  ensure_pv_in_vg || return 1
  log_ok "卷组创建完成: $DISK → VG=$VG"
}

cmd_create_lv() {
  if [[ -z $VG || -z $LV || -z $SIZE || -z $FS || -z $MOUNT ]]; then
    log_error "create-lv 参数不完整: 需要 -v -l -s -f -m"
    return 1
  fi
  valid_lvm_name "$VG" "卷组名" || return 1
  valid_lvm_name "$LV" "逻辑卷名" || return 1
  FS=$(normalize_fs "$FS")
  fs_tools_check "$FS" || return 1
  SIZE=$(normalize_size "$SIZE")
  valid_size "$SIZE" || { log_error "大小格式不合法: $SIZE"; size_help; return 1; }
  [[ $SIZE != +* ]] || { log_error "create 不支持相对大小 (如 +50G)，请用绝对值 50G 或 max"; return 1; }
  if ! vg_exists "$VG"; then
    log_error "卷组 $VG 不存在。请先: $0 create-vg -d <磁盘> -v $VG"
    return 1
  fi
  create_lv_on_vg
}

cmd_create() {
  if [[ -z $DISK || -z $VG || -z $LV || -z $SIZE || -z $FS || -z $MOUNT ]]; then
    log_error "create 参数不完整: 需要 -d -v -l -s -f -m"
    log_info "只建卷组: $0 create-vg -d <磁盘> -v <卷组>"
    log_info "已有卷组上建 LV: $0 create-lv -v <卷组> -l <逻辑卷> -s <大小> -f <fs> -m <挂载点>"
    return 1
  fi
  valid_lvm_name "$VG" "卷组名" || return 1
  valid_lvm_name "$LV" "逻辑卷名" || return 1
  FS=$(normalize_fs "$FS")
  fs_tools_check "$FS" || return 1
  SIZE=$(normalize_size "$SIZE")
  valid_size "$SIZE" || { log_error "大小格式不合法: $SIZE"; size_help; return 1; }
  [[ $SIZE != +* ]] || { log_error "create 不支持相对大小 (如 +50G)，请用绝对值 50G 或 max"; return 1; }
  check_mount_target || return 1

  ensure_pv_in_vg || return 1
  create_lv_on_vg || return 1
}

# ---------------- 扩容 ----------------
grow_fs() {
  local vg=$1 lv=$2 fstype mp
  local dev
  dev=$(lv_dev "$vg" "$lv")
  if [[ $DRY_RUN -eq 1 ]]; then
    fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || echo "${FS:-未知}")
    case $fstype in
      xfs)
        mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null || true)
        log_info "[dry-run] xfs_growfs ${mp:-(需在挂载状态下扩容)}" ;;
      ext4) log_info "[dry-run] resize2fs $dev" ;;
      *)    log_info "[dry-run] 扩容文件系统 ($fstype)" ;;
    esac
    return 0
  fi
  fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
  case $fstype in
    xfs)
      mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null)
      [[ -n $mp ]] || { log_error "xfs 扩容需在挂载状态进行，$dev 未挂载"; return 1; }
      xfs_growfs "$mp" || return 1 ;;
    ext4)
      resize2fs "$dev" || return 1 ;;
    *)
      log_warn "未知文件系统 '$fstype'，跳过文件系统扩容 (LV 已扩容)" ;;
  esac
}

cmd_extend() {
  [[ -n $VG ]] || { log_error "extend 需要 -v 指定卷组"; return 1; }
  [[ -n $DISK || -n $LV ]] || { log_error "extend 需要 -d 加盘 或 -l/-s 扩容 LV"; return 1; }
  valid_lvm_name "$VG" "卷组名" || return 1
  [[ -z $LV ]] || valid_lvm_name "$LV" "逻辑卷名" || return 1

  if [[ -n $SIZE ]]; then
    SIZE=$(normalize_size "$SIZE")
    valid_size "$SIZE" || { log_error "大小格式不合法: $SIZE"; size_help; return 1; }
  fi

  vg_exists "$VG" || { log_error "卷组 $VG 不存在"; return 1; }

  if [[ -n $DISK ]]; then
    if pv_exists "$DISK"; then
      if pv_in_vg "$DISK" "$VG"; then
        log_info "$DISK 已在卷组 $VG 中，跳过加盘"
      else
        local othervg
        othervg=$(pvs --noheadings -o vg_name "$DISK" 2>/dev/null | awk '{print $1}')
        if [[ -n $othervg && $othervg != " " ]]; then
          log_error "$DISK 属于卷组 $othervg，不能加入 $VG。请先: $0 delete -d $DISK 释放该 PV"
          return 1
        fi
        confirm "将已存在的 PV $DISK 加入卷组 $VG ?" || return 1
        run vgextend -y "$VG" "$DISK" || return 1
        log_ok "已将 $DISK 加入卷组 $VG"
      fi
    else
      disk_is_empty "$DISK" || return 1
      confirm "创建 PV 并把 $DISK 加入卷组 $VG ?" || return 1
      run pvcreate -y "$DISK" || return 1
      if ! run vgextend -y "$VG" "$DISK"; then
        run pvremove -y "$DISK" >/dev/null 2>&1 || true
        return 1
      fi
      log_ok "已将 $DISK 加入卷组 $VG"
    fi
  fi

  if [[ -n $LV ]]; then
    [[ -n $SIZE ]] || { log_error "扩容 LV 需要 -s 指定大小"; size_help; return 1; }
    lv_exists "$VG" "$LV" || { log_error "逻辑卷 $VG/$LV 不存在"; return 1; }

    local fstype dev
    dev=$(lv_dev "$VG" "$LV")
    fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
    case $fstype in
      xfs|ext4) fs_tools_check "$fstype" || return 1 ;;
      *) log_warn "文件系统 '$fstype' 非 xfs/ext4，将仅扩容 LV，不扩容文件系统" ;;
    esac

    if [[ $SIZE != +* && $SIZE != *%* ]]; then
      local cur target need free
      cur=$(lv_size_mb "$VG" "$LV"); target=$(to_mb "$SIZE")
      if (( target <= cur )); then
        log_error "目标大小 ${SIZE} 不大于当前大小，拒绝操作 (本工具不支持缩小)"
        return 1
      fi
      need=$(( target - cur )); free=$(vg_free_mb_planned "$VG")
      if (( need > free )); then
        log_error "卷组 $VG 剩余空间不足: 需要 ${need}MB, 剩余 ${free}MB"
        return 1
      fi
    fi

    confirm "扩容逻辑卷 $VG/$LV → ${SIZE}，并同步扩容文件系统 ?" || return 1
    if [[ $SIZE == *%* ]]; then
      run lvextend -y -l "$SIZE" "$dev" || return 1
    else
      run lvextend -y -L "$SIZE" "$dev" || return 1
    fi
    grow_fs "$VG" "$LV" || return 1
    log_ok "扩容完成: $VG/$LV → ${SIZE} (文件系统: ${fstype:-未知})"
  fi
}

# ---------------- 删除 ----------------
delete_lv() {
  local vg=$1 lv=$2 mp uuid is_swap=0
  local dev
  lv_exists "$vg" "$lv" || { log_error "逻辑卷 $vg/$lv 不存在"; return 1; }
  dev=$(lv_dev "$vg" "$lv")

  # LV 未激活时设备节点缺失，先激活以便读取 UUID / 挂载 / swap 信息
  # (否则删除后 fstab 会残留悬空条目)
  if [[ ! -e $dev ]]; then
    log_warn "$dev 设备节点不存在 (LV 未激活)，先激活以读取信息"
    run lvchange -ay "$vg/$lv" || { log_error "激活 $vg/$lv 失败"; return 1; }
    dev=$(lv_dev "$vg" "$lv")
  fi

  if is_swap_dev "$dev"; then is_swap=1; fi
  mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null || true)
  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)

  [[ $is_swap -eq 1 ]] && log_info "检测到 $dev 正在作为 swap 使用，确认后将先关闭"
  [[ -n $mp ]] && log_info "检测到 $dev 已挂载到 $mp，确认后将先卸载"
  if [[ -n $uuid ]] && fstab_has_uuid "$uuid"; then
    log_info "确认后将同步删除 /etc/fstab 中 UUID=$uuid 的条目"
  elif [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] 若 fstab 中有该 LV 的 UUID 条目将一并删除"
  fi

  confirm_danger "确认删除逻辑卷 $dev 及其所有数据?" || return 1

  if [[ $is_swap -eq 1 ]]; then
    swap_off_if_needed "$dev" || return 1
  fi

  if [[ -n $mp ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] umount $mp"
    else
      umount "$mp" || { log_error "卸载 $mp 失败"; return 1; }
    fi
  fi

  if [[ -n $uuid ]] && fstab_has_uuid "$uuid"; then
    rm_fstab_by_uuid "$uuid" || return 1
  fi

  run lvremove -y "$dev" || return 1
  log_ok "已删除逻辑卷 $dev"
}

delete_vg() {
  local vg=$1 lvs_list pvs_list l
  vg_exists "$vg" || { log_error "卷组 $vg 不存在"; return 1; }

  lvs_list=$(lvs --noheadings -o lv_name "$vg" 2>/dev/null | awk '{print $1}')
  if [[ -n $lvs_list ]]; then
    log_warn "卷组 $vg 包含以下逻辑卷:"
    echo "$lvs_list" | sed 's/^/    - /'
    confirm "将删除卷组中所有逻辑卷及其数据，继续 ?" || return 1
    for l in $lvs_list; do
      delete_lv "$vg" "$l" || return 1
    done
  fi

  pvs_list=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$vg" '$2==vg {print $1}')
  confirm_danger "确认删除卷组 $vg ?" || return 1
  run vgremove -y "$vg" || return 1
  log_ok "已删除卷组 $vg (PV: $pvs_list 仍保留为独立 PV)"
}

delete_pv() {
  local dev=$1 vgname
  [[ -b $dev ]] || { log_error "$dev 不是块设备"; return 1; }
  pv_exists "$dev" || { log_error "$dev 不是 PV"; return 1; }

  vgname=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | awk '{print $1}')
  if [[ -n $vgname && $vgname != " " ]]; then
    log_warn "$dev 属于卷组 $vgname，将从卷组中移除"
    confirm_danger "确认将 $dev 从卷组 $vgname 移除 ?" || return 1
    if ! run vgreduce -y "$vgname" "$dev"; then
      log_error "移除失败: 若 PV 上仍有数据，请先 pvmove 迁移；若这是卷组最后一块盘，请先: $0 delete -v $vgname"
      return 1
    fi
  fi

  confirm_danger "确认删除 PV $dev ?" || return 1
  run pvremove -y "$dev" || return 1
  log_ok "已删除 PV $dev"
}

cmd_delete() {
  if [[ -n $LV ]]; then
    [[ -n $VG ]] || { log_error "删除 LV 需要 -v 指定卷组"; return 1; }
    valid_lvm_name "$VG" "卷组名" || return 1
    valid_lvm_name "$LV" "逻辑卷名" || return 1
    delete_lv "$VG" "$LV"
  elif [[ -n $DISK ]]; then
    delete_pv "$DISK"
  elif [[ -n $VG ]]; then
    valid_lvm_name "$VG" "卷组名" || return 1
    delete_vg "$VG"
  else
    log_error "delete 需要指定对象: -v 卷组 / -l 逻辑卷 / -d 磁盘"
    return 1
  fi
}

# ---------------- 查询 ----------------
cmd_list() {
  local what=${1:-all}
  case $what in
    pvs) log_info "物理卷 (PV):"; pvs ;;
    vgs) log_info "卷组 (VG):"; vgs ;;
    lvs) log_info "逻辑卷 (LV):"; lvs ;;
    disk) log_info "磁盘视图:"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT ;;
    all)
      log_info "物理卷 (PV):"; pvs
      log_info "卷组 (VG):"; vgs
      log_info "逻辑卷 (LV):"; lvs
      log_info "磁盘视图:"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT ;;
    *) log_error "未知查询类型: $what (可选 pvs/vgs/lvs/disk/all)"; return 1 ;;
  esac
}

cmd_info() {
  [[ -n $DISK ]] || { log_error "info 需要 -d 指定设备"; return 1; }
  [[ -b $DISK ]] || { log_error "$DISK 不是块设备"; return 1; }
  log_info "设备信息: $DISK"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK"
  if pv_exists "$DISK"; then
    log_info "PV 状态:"; pvs "$DISK"
  else
    log_warn "$DISK 当前不是 PV (空盘可用于 create)"
  fi
}

print_brief_status() {
  local vgs_line lvs_line
  vgs_line=$(vgs --noheadings -o vg_name,vg_size,vg_free 2>/dev/null \
    | awk '{printf "%s(size %s, free %s)  ", $1,$2,$3}')
  lvs_line=$(lvs --noheadings -o vg_name,lv_name,lv_size 2>/dev/null \
    | awk '{printf "%s/%s(%s)  ", $1,$2,$3}')
  printf '%s当前 VG:%s %s\n' "$BLUE" "$RESET" "${vgs_line:-无}"
  printf '%s当前 LV:%s %s\n' "$BLUE" "$RESET" "${lvs_line:-无}"
}

# ---------------- 参数解析 ----------------
# 抽出任意位置的长选项，剩余参数放回 ARGS
strip_long_opts() {
  local out=()
  ARGS=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-color) disable_color ;;
      --help) usage; exit 0 ;;
      *) out+=("$1") ;;
    esac
    shift
  done
  if (( ${#out[@]} > 0 )); then
    ARGS=("${out[@]}")
  fi
}

parse_opts() {
  reset_opts
  OPTIND=1
  while getopts ":d:v:l:s:f:m:ynh" opt; do
    case $opt in
      d) DISK=$OPTARG ;;
      v) VG=$OPTARG ;;
      l) LV=$OPTARG ;;
      s) SIZE=$OPTARG ;;
      f) FS=$OPTARG ;;
      m) MOUNT=$OPTARG ;;
      y) ASSUME_YES=1 ;;
      n) DRY_RUN=1 ;;
      h) usage; exit 0 ;;
      :) log_error "选项 -$OPTARG 缺少参数"; usage; exit 1 ;;
      *) usage; exit 1 ;;
    esac
  done
  shift $((OPTIND - 1))
  POS=("$@")
}

usage() {
  cat <<EOF
${BOLD}LVM 管理工具 — 增 / 删 / 查 / 扩容${RESET}

用法:
  $0                                    交互式菜单
  $0 create -d <磁盘> -v <卷组> -l <逻辑卷> -s <大小> -f <xfs|ext4> -m <挂载点>
  $0 create-vg -d <磁盘> -v <卷组>         # 只建 PV + VG
  $0 create-lv -v <卷组> -l <逻辑卷> -s <大小> -f <xfs|ext4> -m <挂载点>
  $0 extend -v <卷组> [-d <磁盘>] [-l <逻辑卷> -s <大小>]
  $0 delete -v <卷组> [-l <逻辑卷>]        # 删 LV；只给 -v 则删整个 VG
  $0 delete -d <磁盘>                      # 删 PV
  $0 list [pvs|vgs|lvs|disk|all]           # 查询
  $0 info -d <磁盘>                        # 查看单块磁盘
  $0 sizes                                # 查看大小参数格式说明
  $0 -h, --help

示例:
  $0 --dry-run create -d /dev/sdb -v vg_data -l lv_data -s 100G -f xfs -m /data
  $0 create-vg -d /dev/sdb -v vg_data
  $0 create-lv -v vg_data -l lv_data -s 100G -f ext4 -m /data
  $0 extend -v vg_data -d /dev/sdc
  $0 extend -v vg_data -l lv_data -s +50G
  $0 delete -v vg_data -l lv_data
  $0 list all

选项:
  -d <磁盘>      磁盘设备, 如 /dev/sdb
  -v <卷组>      卷组名, 如 vg_data
  -l <逻辑卷>    逻辑卷名, 如 lv_data
  -s <大小>      如 100G / +50G / 100%FREE / max(占满剩余空间)
  -f <文件系统>  xfs 或 ext4
  -m <挂载点>    如 /data
  -y, --yes      跳过所有确认 (危险操作请谨慎)
  -n, --dry-run  只打印将执行的操作，不改动系统
  --no-color     禁用颜色

说明:
  - 创建/加盘前会自动校验磁盘为空盘 (无分区/无签名/未挂载/非 PV/无 holders)
  - 危险操作需要输入 yes 确认; -y 可跳过全部确认
  - 修改 /etc/fstab 前会先备份; 删除 LV 时默认同步删除对应 fstab 条目
  - 支持文件系统: xfs (xfs_growfs 扩容) / ext4 (resize2fs 扩容)
  - 缺失命令时会提示对应发行版的安装命令
EOF
}

# ---------------- 交互式菜单 ----------------
menu_create() {
  local t
  reset_opts
  echo "  1) 完整创建 (空盘 → PV/VG/LV/格式化/挂载)"
  echo "  2) 仅创建卷组 VG"
  echo "  3) 仅创建逻辑卷 LV (VG 需已存在)"
  echo -n "选择: "; read -r t
  case $t in
    1)
      echo -n "磁盘设备 (如 /dev/sdb): "; read -r DISK
      echo -n "卷组名 (默认 vg_data): "; read -r VG;  VG=${VG:-vg_data}
      echo -n "逻辑卷名 (默认 lv_data): "; read -r LV; LV=${LV:-lv_data}
      echo "大小可选: 100G / 500M / 100%FREE / max (输入 ? 查看全部格式)"
      echo -n "逻辑卷大小 (如 100G, 100%FREE, max): "; read -r SIZE
      if [[ $SIZE == "?" ]]; then size_help; echo -n "逻辑卷大小: "; read -r SIZE; fi
      echo -n "文件系统 (xfs/ext4, 默认 xfs): "; read -r FS; FS=${FS:-xfs}
      echo -n "挂载点 (如 /data): "; read -r MOUNT
      cmd_create
      ;;
    2)
      echo -n "磁盘设备 (如 /dev/sdb): "; read -r DISK
      echo -n "卷组名 (默认 vg_data): "; read -r VG; VG=${VG:-vg_data}
      cmd_create_vg
      ;;
    3)
      echo -n "卷组名: "; read -r VG
      echo -n "逻辑卷名 (默认 lv_data): "; read -r LV; LV=${LV:-lv_data}
      echo "大小可选: 100G / 500M / 100%FREE / max (输入 ? 查看全部格式)"
      echo -n "逻辑卷大小: "; read -r SIZE
      if [[ $SIZE == "?" ]]; then size_help; echo -n "逻辑卷大小: "; read -r SIZE; fi
      echo -n "文件系统 (xfs/ext4, 默认 xfs): "; read -r FS; FS=${FS:-xfs}
      echo -n "挂载点 (如 /data): "; read -r MOUNT
      cmd_create_lv
      ;;
    *) log_warn "无效选择" ;;
  esac
}

menu_extend() {
  reset_opts
  print_brief_status
  echo -n "卷组名 (如 vg_data): "; read -r VG
  echo -n "要加入的磁盘 (如 /dev/sdc, 留空跳过): "; read -r DISK
  echo -n "要扩容的 LV 名 (如 lv_data, 留空跳过): "; read -r LV
  if [[ -n $LV ]]; then
    echo "大小可选: +50G / 100%FREE / max / 100G (输入 ? 查看全部格式)"
    echo -n "扩容大小 (如 +50G, 100%FREE, max): "; read -r SIZE
    if [[ $SIZE == "?" ]]; then size_help; echo -n "扩容大小: "; read -r SIZE; fi
  fi
  cmd_extend
}

menu_delete() {
  local t
  reset_opts
  print_brief_status
  echo "  1) 删除逻辑卷 LV"
  echo "  2) 删除卷组 VG (含其中所有 LV)"
  echo "  3) 删除物理卷 PV"
  echo -n "选择: "; read -r t
  case $t in
    1) echo -n "卷组名: "; read -r VG; echo -n "逻辑卷名: "; read -r LV; cmd_delete ;;
    2) echo -n "卷组名: "; read -r VG; cmd_delete ;;
    3) echo -n "磁盘设备 (如 /dev/sdc): "; read -r DISK; cmd_delete ;;
    *) log_warn "无效选择" ;;
  esac
}

menu_list() {
  reset_opts
  echo "  可选: pvs=物理卷  vgs=卷组  lvs=逻辑卷  disk=磁盘  all=全部"
  echo -n "选择 (默认 all): "; read -r w
  cmd_list "${w:-all}"
}

menu_info() {
  reset_opts
  echo -n "磁盘设备 (如 /dev/sdb): "; read -r DISK
  cmd_info
}

interactive() {
  local choice
  while true; do
    echo
    echo "============ ${BOLD}LVM 管理工具${RESET} ============"
    [[ $DRY_RUN -eq 1 ]] && echo "${YELLOW}  (dry-run 模式，不会改动系统)${RESET}"
    print_brief_status
    echo "  1) 创建   (完整 / 仅 VG / 仅 LV)"
    echo "  2) 扩容   (VG 加盘 / LV + 文件系统扩容)"
    echo "  3) 删除   (LV / VG / PV)"
    echo "  4) 查询   (PV / VG / LV / 磁盘)"
    echo "  5) 磁盘信息"
    echo "  0) 退出"
    echo "==========================================="
    echo -n "请选择: "; read -r choice
    case $choice in
      1) menu_create ;;
      2) menu_extend ;;
      3) menu_delete ;;
      4) menu_list ;;
      5) menu_info ;;
      0) log_info "再见"; exit 0 ;;
      *) log_warn "无效选择: $choice" ;;
    esac
  done
}

# ---------------- 入口 ----------------
main() {
  local cmd
  while [[ $# -gt 0 ]]; do
    case $1 in
      -y|--yes) ASSUME_YES=1; shift ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      --no-color) disable_color; shift ;;
      -h|--help) usage; exit 0 ;;
      *) break ;;
    esac
  done
  strip_long_opts "$@"
  if (( ${#ARGS[@]} > 0 )); then
    set -- "${ARGS[@]}"
  else
    set --
  fi

  cmd=${1:-}
  if [[ $cmd == "-h" || $cmd == "help" ]]; then
    usage; exit 0
  fi
  if [[ $cmd == "sizes" || $cmd == "size-help" ]]; then
    size_help; exit 0
  fi
  if [[ -z $cmd ]]; then
    require_root "$@"; check_deps; interactive
    return
  fi

  require_root "$@"
  check_deps

  case $cmd in
    create)    shift; parse_opts "$@"; cmd_create ;;
    create-vg) shift; parse_opts "$@"; cmd_create_vg ;;
    create-lv) shift; parse_opts "$@"; cmd_create_lv ;;
    extend)    shift; parse_opts "$@"; cmd_extend ;;
    delete)    shift; parse_opts "$@"; cmd_delete ;;
    info)      shift; parse_opts "$@"; cmd_info ;;
    list)      shift; parse_opts "$@"; cmd_list "${POS[0]:-all}" ;;
    *) log_error "未知命令: $cmd"; usage; return 1 ;;
  esac
}

main "$@"
