#!/usr/bin/env bash
#
# lvm-manager.sh — LVM 管理工具 (增 / 删 / 查 / 扩容 / 磁盘信息)
#
# 用法:
#   ./lvm-manager.sh                                  # 交互式菜单
#   ./lvm-manager.sh create -d /dev/sdb -v vg_data -l lv_data -s 100G -f xfs -m /data
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
#   -y             跳过所有确认 (危险操作请谨慎)

set -uo pipefail

# ---------------- 全局变量 ----------------
ASSUME_YES=0
DISK=""; VG=""; LV=""; SIZE=""; FS=""; MOUNT=""
POS=()

# ---------------- 颜色 ----------------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

log_info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET} $*"; }

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
  local cmds=(pvcreate pvremove vgcreate vgextend vgremove
              lvcreate lvextend lvremove
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

fs_tools_check() {
  local fs=$1
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
      log_error "不支持的文件系统: $fs (仅支持 xfs / ext4)"
      return 1 ;;
  esac
}

# ---------------- 确认 ----------------
confirm() {
  local msg=$1 ans
  if [[ $ASSUME_YES -eq 1 ]]; then log_warn "$msg [自动确认 -y]"; return 0; fi
  echo -n "$msg [y/N]: "; read -r ans
  [[ $ans =~ ^[Yy](es)?$ ]]
}

confirm_danger() {
  local msg=$1 ans
  if [[ $ASSUME_YES -eq 1 ]]; then log_warn "$msg [自动确认 -y]"; return 0; fi
  echo -n "${RED}⚠ $msg${RESET} 危险操作，请输入 yes 确认: "; read -r ans
  [[ $ans == "yes" ]]
}

# ---------------- 状态判断 ----------------
pv_exists()  { pvs "$1" >/dev/null 2>&1; }
vg_exists()  { vgs "$1" >/dev/null 2>&1; }
lv_exists()  { lvs "/dev/$1/$2" >/dev/null 2>&1; }

pv_in_vg() {
  local vgname
  vgname=$(pvs --noheadings -o vg_name "$1" 2>/dev/null | awk '{print $1}')
  [[ $vgname == "$2" ]]
}

vg_free_mb() {
  vgs --noheadings --nosuffix --units m -o vg_free "$1" 2>/dev/null | awk '{printf "%d", $1}'
}

lv_size_mb() {
  lvs --noheadings --nosuffix --units m -o lv_size "/dev/$1/$2" 2>/dev/null | awk '{printf "%d", $1}'
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
  [[ $1 =~ ^\+?[0-9.]+[kKmMgGtTpP]?$ || $1 =~ ^\+?[0-9]+%[A-Z]+$ ]]
}

# 方便写法归一化: max/all → 100%FREE (最大化使用卷组剩余空间)
normalize_size() {
  case $1 in
    max|MAX|all|ALL) echo "100%FREE" ;;
    *) echo "$1" ;;
  esac
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
  $0 extend -v vg_data -l lv_data -s max
  $0 extend -v vg_data -l lv_data -s +50G
EOF
}

# ---------------- 安全校验 ----------------
disk_is_empty() {
  local dev=$1 devtype
  [[ -b $dev ]] || { log_error "$dev 不是块设备"; return 1; }
  findmnt "$dev" >/dev/null 2>&1 && { log_error "$dev 已挂载，拒绝操作"; return 1; }
  pv_exists "$dev" && { log_error "$dev 已是 PV"; return 1; }
  devtype=$(lsblk -nro TYPE "$dev" 2>/dev/null | head -1)
  if [[ $devtype == disk ]]; then
    if lsblk -nro TYPE "$dev" 2>/dev/null | tail -n +2 | grep -q '^part$'; then
      log_error "$dev 包含分区，不是空盘。如需整盘使用请先: wipefs -a $dev"
      return 1
    fi
  fi
  if blkid "$dev" >/dev/null 2>&1; then
    log_error "$dev 存在文件系统/分区表签名，不是空盘。如需清空请先: wipefs -a $dev"
    return 1
  fi
  return 0
}

# ---------------- fstab ----------------
fstab_has_uuid() { awk -v u="UUID=$1" '$1==u {found=1} END{exit !found}' /etc/fstab; }
fstab_has_mp()   { awk -v mp="$1" '$2==mp {found=1} END{exit !found}' /etc/fstab; }

add_fstab() {
  local vg=$1 lv=$2 fs=$3 mp=$4 uuid pass
  uuid=$(blkid -s UUID -o value "/dev/$vg/$lv" 2>/dev/null) || { log_warn "无法获取 UUID，跳过 fstab 写入"; return 1; }
  if fstab_has_uuid "$uuid"; then log_warn "fstab 已存在该 UUID，跳过"; return 0; fi
  if fstab_has_mp "$mp"; then log_warn "fstab 已存在挂载点 $mp，跳过"; return 0; fi
  [[ $fs == xfs ]] && pass=0 || pass=2
  printf 'UUID=%s  %s  %s  defaults  0  %d  # lvm-manager\n' "$uuid" "$mp" "$fs" "$pass" >> /etc/fstab
  log_ok "已写入 /etc/fstab: UUID=$uuid → $mp"
}

rm_fstab_by_uuid() {
  local uuid=$1
  [[ -n $uuid ]] && sed -i "\|UUID=$uuid|d" /etc/fstab
}

# ---------------- 增: 创建 ----------------
cmd_create() {
  if [[ -z $DISK || -z $VG || -z $LV || -z $SIZE || -z $FS || -z $MOUNT ]]; then
    log_error "create 参数不完整: 需要 -d -v -l -s -f -m"; return 1
  fi
  fs_tools_check "$FS" || return 1
  SIZE=$(normalize_size "$SIZE")
  valid_size "$SIZE" || { log_error "大小格式不合法: $SIZE"; size_help; return 1; }
  [[ $SIZE != +* ]] || { log_error "create 不支持相对大小 (如 +50G)，请用绝对值 50G 或 max"; return 1; }
  [[ $MOUNT == /* ]] || { log_error "挂载点必须是绝对路径: $MOUNT"; return 1; }
  [[ $MOUNT != "/" ]] || { log_error "禁止挂载到根目录 /"; return 1; }
  findmnt "$MOUNT" >/dev/null 2>&1 && { log_error "挂载点 $MOUNT 已被占用"; return 1; }
  if [[ -d $MOUNT ]] && [[ -n $(ls -A "$MOUNT" 2>/dev/null) ]]; then
    log_warn "挂载点 $MOUNT 已存在且非空，挂载后原内容将被暂时隐藏"
    confirm "继续挂载到非空目录 $MOUNT ?" || return 1
  fi

  # 1) PV + VG
  if ! vg_exists "$VG"; then
    disk_is_empty "$DISK" || return 1
    confirm "将 $DISK 创建为 PV 并加入新卷组 $VG ?" || return 1
    pvcreate -y "$DISK" || return 1
    if ! vgcreate "$VG" "$DISK"; then
      log_warn "卷组创建失败，回滚: pvremove $DISK"
      pvremove -y "$DISK" >/dev/null 2>&1 || true
      return 1
    fi
  else
    if pv_in_vg "$DISK" "$VG"; then
      log_info "$DISK 已在卷组 $VG 中"
    else
      disk_is_empty "$DISK" || return 1
      confirm "卷组 $VG 已存在，将 $DISK 加入 ?" || return 1
      pvcreate -y "$DISK" || return 1
      vgextend -y "$VG" "$DISK" || { pvremove -y "$DISK" >/dev/null 2>&1 || true; return 1; }
    fi
  fi

  # 2) LV 空间预检
  lv_exists "$VG" "$LV" && { log_error "逻辑卷 $VG/$LV 已存在"; return 1; }
  if [[ $SIZE != *%* && $SIZE != +* ]]; then
    local need free
    need=$(to_mb "$SIZE"); free=$(vg_free_mb "$VG")
    if (( need > free )); then
      log_error "卷组 $VG 剩余空间不足: 需要 ${need}MB, 剩余 ${free}MB"; return 1
    fi
    if [[ $FS == xfs && need -lt 300 ]]; then
      log_error "xfs 文件系统最小需要 300MB，当前仅 ${need}MB。请加大大小，或改用 ext4 (输入 sizes 查看格式)"
      return 1
    fi
  fi

  confirm "创建逻辑卷 $VG/$LV (${SIZE})，格式化为 $FS 并挂载到 $MOUNT ?" || return 1

  # 3) LV (含 % 的写法用 -l 透传, 如 100%FREE)
  if [[ $SIZE == *%* ]]; then
    lvcreate -y -l "$SIZE" -n "$LV" "$VG" || { log_warn "LV 创建失败。若卷组 $VG 为本次新建且为空，可用 delete -v $VG 清理"; return 1; }
  else
    lvcreate -y -L "$SIZE" -n "$LV" "$VG" || { log_warn "LV 创建失败。若卷组 $VG 为本次新建且为空，可用 delete -v $VG 清理"; return 1; }
  fi

  # 4) 格式化
  if [[ $FS == xfs ]]; then
    mkfs.xfs -f "/dev/$VG/$LV" || { lvremove -y "/dev/$VG/$LV" >/dev/null 2>&1 || true; log_error "格式化失败，已删除 LV"; return 1; }
  else
    mkfs.ext4 -F "/dev/$VG/$LV" || { lvremove -y "/dev/$VG/$LV" >/dev/null 2>&1 || true; log_error "格式化失败，已删除 LV"; return 1; }
  fi

  # 5) 挂载 + fstab
  mkdir -p "$MOUNT" || { log_error "创建挂载点 $MOUNT 失败"; return 1; }
  mount "/dev/$VG/$LV" "$MOUNT" || { log_error "挂载失败，请手动检查"; return 1; }
  add_fstab "$VG" "$LV" "$FS" "$MOUNT" || true

  log_ok "创建完成: $DISK → VG=$VG / LV=$LV($SIZE) / FS=$FS / 挂载点=$MOUNT"
}

# ---------------- 扩容 ----------------
grow_fs() {
  local vg=$1 lv=$2 fstype mp
  local dev="/dev/$vg/$lv"
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

  # 大小格式预校验 (若提供了 -s)，格式错误最先提示
  if [[ -n $SIZE ]]; then
    SIZE=$(normalize_size "$SIZE")
    valid_size "$SIZE" || { log_error "大小格式不合法: $SIZE"; size_help; return 1; }
  fi

  vg_exists "$VG" || { log_error "卷组 $VG 不存在"; return 1; }

  # 模式1: VG 加盘
  if [[ -n $DISK ]]; then
    if pv_exists "$DISK"; then
      if pv_in_vg "$DISK" "$VG"; then
        log_info "$DISK 已在卷组 $VG 中，跳过加盘"
      else
        confirm "将已存在的 PV $DISK 加入卷组 $VG ?" || return 1
        vgextend -y "$VG" "$DISK" || return 1
        log_ok "已将 $DISK 加入卷组 $VG"
      fi
    else
      disk_is_empty "$DISK" || return 1
      confirm "创建 PV 并把 $DISK 加入卷组 $VG ?" || return 1
      pvcreate -y "$DISK" || return 1
      vgextend -y "$VG" "$DISK" || { pvremove -y "$DISK" >/dev/null 2>&1 || true; return 1; }
      log_ok "已将 $DISK 加入卷组 $VG"
    fi
  fi

  # 模式2: LV + 文件系统扩容
  if [[ -n $LV ]]; then
    [[ -n $SIZE ]] || { log_error "扩容 LV 需要 -s 指定大小"; size_help; return 1; }
    lv_exists "$VG" "$LV" || { log_error "逻辑卷 $VG/$LV 不存在"; return 1; }

    local fstype
    fstype=$(blkid -s TYPE -o value "/dev/$VG/$LV" 2>/dev/null)
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
      need=$(( target - cur )); free=$(vg_free_mb "$VG")
      if (( need > free )); then
        log_error "卷组 $VG 剩余空间不足: 需要 ${need}MB, 剩余 ${free}MB"
        return 1
      fi
    fi

    confirm "扩容逻辑卷 $VG/$LV → ${SIZE}，并同步扩容文件系统 ?" || return 1
    if [[ $SIZE == *%* ]]; then
      lvextend -y -l "$SIZE" "/dev/$VG/$LV" || return 1
    else
      lvextend -y -L "$SIZE" "/dev/$VG/$LV" || return 1
    fi
    grow_fs "$VG" "$LV" || return 1
    log_ok "扩容完成: $VG/$LV → ${SIZE} (文件系统: ${fstype:-未知})"
  fi
}

# ---------------- 删除 ----------------
delete_lv() {
  local vg=$1 lv=$2 mp uuid
  local dev="/dev/$vg/$lv"
  lv_exists "$vg" "$lv" || { log_error "逻辑卷 $dev 不存在"; return 1; }

  mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null || true)
  if [[ -n $mp ]]; then
    confirm "卸载 $dev (挂载点 $mp) ?" || return 1
    umount "$mp" || { log_error "卸载 $mp 失败"; return 1; }
  fi

  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
  if [[ -n $uuid ]] && fstab_has_uuid "$uuid"; then
    confirm "从 /etc/fstab 删除对应条目 ?" || return 1
    rm_fstab_by_uuid "$uuid"
    log_info "已从 fstab 移除挂载条目"
  fi

  confirm_danger "确认删除逻辑卷 $dev 及其所有数据?" || return 1
  lvremove -y "$dev" || return 1
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
  vgremove -y "$vg" || return 1
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
    vgreduce -y "$vgname" "$dev" || { log_error "移除失败: 若 PV 上仍有数据，请先 pvmove 迁移数据"; return 1; }
  fi

  confirm_danger "确认删除 PV $dev ?" || return 1
  pvremove -y "$dev" || return 1
  log_ok "已删除 PV $dev"
}

cmd_delete() {
  if [[ -n $LV ]]; then
    [[ -n $VG ]] || { log_error "删除 LV 需要 -v 指定卷组"; return 1; }
    delete_lv "$VG" "$LV"
  elif [[ -n $DISK ]]; then
    delete_pv "$DISK"
  elif [[ -n $VG ]]; then
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

# ---------------- 参数解析 ----------------
parse_opts() {
  while getopts ":d:v:l:s:f:m:yh" opt; do
    case $opt in
      d) DISK=$OPTARG ;;
      v) VG=$OPTARG ;;
      l) LV=$OPTARG ;;
      s) SIZE=$OPTARG ;;
      f) FS=$OPTARG ;;
      m) MOUNT=$OPTARG ;;
      y) ASSUME_YES=1 ;;
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
  $0 create -d <磁盘> -v <卷组> -l <逻辑卷> -s <大小> -f <xfs|ext4> -m <挂载点> [-y]
  $0 extend -v <卷组> [-d <磁盘>] [-l <逻辑卷> -s <大小>] [-y]
  $0 delete -v <卷组> [-l <逻辑卷>]        # 删 LV；只给 -v 则删整个 VG
  $0 delete -d <磁盘>                      # 删 PV
  $0 list [pvs|vgs|lvs|disk|all]           # 查询
  $0 info -d <磁盘>                        # 查看单块磁盘
  $0 sizes                                # 查看大小参数格式说明
  $0 -h, --help

示例:
  $0 create -d /dev/sdb -v vg_data -l lv_data -s 100G -f xfs -m /data
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
  -y             跳过所有确认 (危险操作请谨慎)

说明:
  - 创建/加盘前会自动校验磁盘为空盘 (无分区/无文件系统/未挂载/非PV)
  - 危险操作需要输入 yes 确认; -y 可跳过全部确认
  - 支持文件系统: xfs (xfs_growfs 扩容) / ext4 (resize2fs 扩容)
  - 缺失命令时会提示对应发行版的安装命令
EOF
}

# ---------------- 交互式菜单 ----------------
menu_create() {
  echo -n "磁盘设备 (如 /dev/sdb): "; read -r DISK
  echo -n "卷组名 (默认 vg_data): "; read -r VG;  VG=${VG:-vg_data}
  echo -n "逻辑卷名 (默认 lv_data): "; read -r LV; LV=${LV:-lv_data}
  echo "大小可选: 100G / 500M / 100%FREE / max (输入 ? 查看全部格式)"
  echo -n "逻辑卷大小 (如 100G, 100%FREE, max): "; read -r SIZE
  if [[ $SIZE == "?" ]]; then size_help; echo -n "逻辑卷大小: "; read -r SIZE; fi
  echo -n "文件系统 (xfs/ext4, 默认 xfs): "; read -r FS; FS=${FS:-xfs}
  echo -n "挂载点 (如 /data): "; read -r MOUNT
  cmd_create
}

menu_extend() {
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
  echo "  可选: pvs=物理卷  vgs=卷组  lvs=逻辑卷  disk=磁盘  all=全部"
  echo -n "选择 (默认 all): "; read -r w
  cmd_list "${w:-all}"
}

menu_info() {
  echo -n "磁盘设备 (如 /dev/sdb): "; read -r DISK
  cmd_info
}

interactive() {
  local choice
  while true; do
    echo
    echo "============ ${BOLD}LVM 管理工具${RESET} ============"
    echo "  1) 创建   (空盘 → PV/VG/LV/格式化/挂载)"
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
  local cmd=${1:-}
  if [[ $cmd == "-h" || $cmd == "--help" || $cmd == "help" ]]; then
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
    create) shift; OPTIND=1; parse_opts "$@"; cmd_create ;;
    extend) shift; OPTIND=1; parse_opts "$@"; cmd_extend ;;
    delete) shift; OPTIND=1; parse_opts "$@"; cmd_delete ;;
    info)   shift; OPTIND=1; parse_opts "$@"; cmd_info ;;
    list)   shift; OPTIND=1; parse_opts "$@"; cmd_list "${POS[0]:-all}" ;;
    *) log_error "未知命令: $cmd"; usage; return 1 ;;
  esac
}

main "$@"
