#!/usr/bin/env bash

#==============================================================================
#
#          FILE:  sshm
#
#         USAGE:  sshm [alias | ID] [ssh options...]
#
#   DESCRIPTION:  一个简洁的 SSH 主机管理器。
#                 - sshm                 进入交互管理界面
#                 - sshm <alias | ID>    直接连接主机
#                 - sshm --list          查看主机列表
#                 - sshm --ping          健康检查所有主机
#                 - sshm --exec <目标> <命令>  批量执行命令
#
#      VERSION:  3.0.0
#
#==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.0.0"
CONFIG_FILE="${SSHM_CONFIG_FILE:-$HOME/.sshm_hosts}"

# 配置格式（后向兼容）：
#   旧格式（6 字段）: alias,user,host,port,identity,note
#   新格式（8 字段）: alias,user,host,port,identity,note,group,tags
# 为了保持纯 Bash 实现简洁可靠，字段中不允许出现英文逗号。

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
else
    C_RESET=""
    C_BOLD=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_CYAN=""
fi

ok() { printf "%s>>%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
info() { printf "%s>>%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf "%s!!%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf "%sError:%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
}

expand_path() {
    case "$1" in
        ~) printf "%s" "$HOME" ;;
        ~/*) printf "%s/%s" "$HOME" "${1#~/}" ;;
        *) printf "%s" "$1" ;;
    esac
}

initialize() {
    local dir
    dir=$(dirname "$CONFIG_FILE")

    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || {
            err "无法创建配置目录：$dir"
            exit 1
        }
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE" || {
            err "无法创建配置文件：$CONFIG_FILE"
            exit 1
        }
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        ok "已创建配置文件：$CONFIG_FILE"
        return
    fi

    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# ---------- 配置解析（后向兼容 6/8 字段）----------

parse_record() {
    # 将一行配置拆分到全局变量。支持旧 6 字段和新 8 字段格式。
    IFS=',' read -r REC_ALIAS REC_USER REC_HOST REC_PORT REC_IDENTITY REC_NOTE REC_GROUP REC_TAGS _REC_EXTRA <<EOF
$1
EOF
    REC_GROUP="${REC_GROUP:-}"
    REC_TAGS="${REC_TAGS:-}"
}

# ---------- 验证函数 ----------

validate_no_comma() {
    case "$1" in
        *,*)
            err "字段中不能包含英文逗号。"
            return 1
            ;;
    esac
}

validate_alias() {
    [ -n "$1" ] || {
        err "别名不能为空。"
        return 1
    }

    validate_no_comma "$1" || return 1

    if [[ "$1" =~ ^[0-9]+$ ]]; then
        err "别名不能是纯数字，避免和 ID 混淆。"
        return 1
    fi

    if ! [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; then
        err "别名只能包含字母、数字、点、下划线和短横线。"
        return 1
    fi
}

validate_required() {
    [ -n "$1" ] || {
        err "该字段不能为空。"
        return 1
    }

    validate_no_comma "$1"
}

validate_optional() {
    validate_no_comma "$1"
}

validate_port() {
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        err "端口必须是数字。"
        return 1
    fi

    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        err "端口范围必须是 1-65535。"
        return 1
    fi
}

alias_exists() {
    local alias="$1"
    local skip_line="${2:-0}"

    awk -F',' -v alias="$alias" -v skip="$skip_line" '
        $1 == alias && NR != skip { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$CONFIG_FILE"
}

find_line_number() {
    local identifier="$1"

    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        awk -v id="$identifier" 'NR == id { print NR; exit }' "$CONFIG_FILE"
    else
        awk -F',' -v alias="$identifier" '$1 == alias { print NR; exit }' "$CONFIG_FILE"
    fi
}

get_record() {
    local identifier="$1"

    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        awk -v id="$identifier" 'NR == id { print; exit }' "$CONFIG_FILE"
    else
        awk -F',' -v alias="$identifier" '$1 == alias { print; exit }' "$CONFIG_FILE"
    fi
}

get_records_by_group() {
    local group="$1"
    awk -F',' -v g="$group" '$7 == g' "$CONFIG_FILE"
}

get_records_by_tag() {
    local tag="$1"
    awk -F',' -v t="$tag" '
        NF >= 8 {
            split($8, tags, ":")
            for (i in tags) if (tags[i] == t) { print; next }
        }
    ' "$CONFIG_FILE"
}

require_target() {
    local identifier="$1"
    local label="${2:-请输入主机 ID 或别名}"

    if [ -n "$identifier" ]; then
        printf "%s" "$identifier"
        return
    fi

    read -r -p "$label: " identifier
    trim "$identifier"
}

prompt_field() {
    local label="$1"
    local default_value="$2"
    local validator="$3"
    local value
    local prompt_label="$label"

    while true; do
        if [ -n "$default_value" ]; then
            if [ "$validator" = "validate_optional" ]; then
                prompt_label="$label，输入 - 清空"
            fi

            read -r -p "$prompt_label [$default_value]: " value
            value=$(trim "$value")
            if [ "$validator" = "validate_optional" ] && [ "$value" = "-" ]; then
                printf "%s" ""
                return
            fi
            [ -z "$value" ] && value="$default_value"
        else
            read -r -p "$label: " value
            value=$(trim "$value")
        fi

        "$validator" "$value" && {
            printf "%s" "$value"
            return
        }
    done
}

# ---------- 显示/搜索 ----------

format_hosts() {
    local keyword="${1:-}"
    local group="${2:-}"
    local tag="${3:-}"

    awk -F',' -v keyword="$keyword" -v group="$group" -v tag="$tag" '
        BEGIN {
            q = tolower(keyword)
            printf "%-4s %-18s %-26s %-6s %-10s %-18s %-16s %s\n", "ID", "别名", "用户@主机", "端口", "分组", "标签", "密钥", "备注"
            printf "%-4s %-18s %-26s %-6s %-10s %-18s %-16s %s\n", "--", "----", "---------", "----", "----", "----", "----", "----"
        }
        {
            line = tolower($0)
            if (q != "" && index(line, q) == 0) next
            if (group != "" && $7 != group) next
            if (tag != "") {
                split($8, tags, ":")
                found = 0
                for (i in tags) if (tags[i] == tag) { found = 1; break }
                if (!found) next
            }

            identity = ($5 == "") ? "默认" : $5
            note = ($6 == "") ? "-" : $6
            grp = ($7 == "") ? "-" : $7
            tgs = ($8 == "") ? "-" : $8
            printf "%-4s %-18s %-26s %-6s %-10s %-18s %-16s %s\n", NR, $1, $2 "@" $3, $4, grp, tgs, identity, note
            count++
        }
        END {
            if (count == 0) {
                if (group != "") print "分组 " group " 中暂无主机。"
                else if (tag != "") print "标签 " tag " 暂无主机。"
                else print "暂无匹配主机。"
            }
        }
    ' "$CONFIG_FILE"
}

list_hosts() {
    print_header

    if [ ! -s "$CONFIG_FILE" ]; then
        info "还没有保存任何主机，使用 add 添加第一台。"
        return
    fi

    format_hosts
}

search_hosts() {
    local keyword="$1"

    if [ -z "$keyword" ]; then
        read -r -p "搜索关键词: " keyword
        keyword=$(trim "$keyword")
    fi

    if [ -z "$keyword" ]; then
        warn "搜索关键词为空。"
        return 1
    fi

    print_header
    format_hosts "$keyword"
}

list_by_group() {
    local group="$1"

    if [ -z "$group" ]; then
        # 列出所有分组
        print_header
        info "所有分组："
        awk -F',' 'NF >= 7 && $7 != "" { groups[$7]++ } END { for (g in groups) printf "  %s (%d 台)\n", g, groups[g] }' "$CONFIG_FILE" 2>/dev/null || echo "  暂无分组。"
        echo
        info "使用 --group <分组名> 查看分组内的主机。"
        return
    fi

    print_header
    format_hosts "" "$group"
}

show_host() {
    local identifier
    local line_no
    local record

    identifier=$(require_target "$1")
    [ -n "$identifier" ] || return 1

    line_no=$(find_line_number "$identifier")
    record=$(get_record "$identifier")

    if [ -z "$record" ]; then
        err "未找到主机：$identifier"
        return 1
    fi

    parse_record "$record"

    print_header
    printf "ID:       %s\n" "$line_no"
    printf "别名:     %s\n" "$REC_ALIAS"
    printf "用户:     %s\n" "$REC_USER"
    printf "主机:     %s\n" "$REC_HOST"
    printf "端口:     %s\n" "$REC_PORT"
    printf "密钥:     %s\n" "${REC_IDENTITY:-默认}"
    printf "备注:     %s\n" "${REC_NOTE:-无}"
    printf "分组:     %s\n" "${REC_GROUP:-无}"
    printf "标签:     %s\n" "${REC_TAGS:-无}"
}

# ---------- 增删改 ----------

append_record() {
    printf "%s,%s,%s,%s,%s,%s,%s,%s\n" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$CONFIG_FILE"
}

replace_record() {
    local line_no="$1"
    local record="$2"
    local temp_file

    temp_file=$(mktemp "${CONFIG_FILE}.XXXXXX") || {
        err "无法创建临时文件。"
        return 1
    }

    awk -v line_no="$line_no" -v record="$record" '
        NR == line_no { print record; next }
        { print }
    ' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

remove_record() {
    local line_no="$1"
    local temp_file

    temp_file=$(mktemp "${CONFIG_FILE}.XXXXXX") || {
        err "无法创建临时文件。"
        return 1
    }

    awk -v line_no="$line_no" 'NR != line_no' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

add_host() {
    local alias user host port identity note group tags

    info "添加新的 SSH 主机"

    while true; do
        alias=$(prompt_field "别名" "" validate_alias)
        if alias_exists "$alias"; then
            err "别名已存在：$alias"
            continue
        fi
        break
    done

    user=$(prompt_field "用户" "${USER:-root}" validate_required)
    host=$(prompt_field "主机/IP" "" validate_required)
    port=$(prompt_field "端口" "22" validate_port)
    identity=$(prompt_field "密钥路径，可留空" "" validate_optional)
    note=$(prompt_field "备注，可留空" "" validate_optional)
    group=$(prompt_field "分组，可留空" "" validate_optional)
    tags=$(prompt_field "标签（多个用:分隔），可留空" "" validate_optional)

    append_record "$alias" "$user" "$host" "$port" "$identity" "$note" "$group" "$tags"
    ok "已添加主机：$alias"
}

edit_host() {
    local identifier line_no record alias user host port identity note group tags new_record

    identifier=$(require_target "$1")
    [ -n "$identifier" ] || return 1

    line_no=$(find_line_number "$identifier")
    record=$(get_record "$identifier")

    if [ -z "$record" ]; then
        err "未找到主机：$identifier"
        return 1
    fi

    parse_record "$record"
    info "编辑主机：$REC_ALIAS (直接回车保留原值)"

    while true; do
        alias=$(prompt_field "别名" "$REC_ALIAS" validate_alias)
        if alias_exists "$alias" "$line_no"; then
            err "别名已存在：$alias"
            continue
        fi
        break
    done

    user=$(prompt_field "用户" "$REC_USER" validate_required)
    host=$(prompt_field "主机/IP" "$REC_HOST" validate_required)
    port=$(prompt_field "端口" "${REC_PORT:-22}" validate_port)
    identity=$(prompt_field "密钥路径，可留空" "$REC_IDENTITY" validate_optional)
    note=$(prompt_field "备注，可留空" "$REC_NOTE" validate_optional)
    group=$(prompt_field "分组，可留空" "$REC_GROUP" validate_optional)
    tags=$(prompt_field "标签（多个用:分隔），可留空" "$REC_TAGS" validate_optional)

    new_record="${alias},${user},${host},${port},${identity},${note},${group},${tags}"
    replace_record "$line_no" "$new_record" && ok "已更新主机：$alias"
}

delete_host() {
    local identifier line_no record confirm

    if [ -z "$1" ]; then
        list_hosts
    fi

    identifier=$(require_target "$1")
    [ -n "$identifier" ] || return 1

    line_no=$(find_line_number "$identifier")
    record=$(get_record "$identifier")

    if [ -z "$record" ]; then
        err "未找到主机：$identifier"
        return 1
    fi

    parse_record "$record"
    read -r -p "确认删除 ${REC_ALIAS} (${REC_USER}@${REC_HOST})？[y/N]: " confirm

    case "$confirm" in
        y|Y|yes|YES)
            remove_record "$line_no" && ok "已删除主机：$REC_ALIAS"
            ;;
        *)
            info "已取消删除。"
            ;;
    esac
}

copy_host() {
    local identifier line_no record alias user host port identity note group tags

    identifier=$(require_target "$1")
    [ -n "$identifier" ] || return 1

    line_no=$(find_line_number "$identifier")
    record=$(get_record "$identifier")

    if [ -z "$record" ]; then
        err "未找到主机：$identifier"
        return 1
    fi

    parse_record "$record"
    info "复制主机：$REC_ALIAS"

    while true; do
        alias=$(prompt_field "新别名" "" validate_alias)
        if alias_exists "$alias"; then
            err "别名已存在：$alias"
            continue
        fi
        break
    done

    user=$(prompt_field "用户" "$REC_USER" validate_required)
    host=$(prompt_field "主机/IP" "$REC_HOST" validate_required)
    port=$(prompt_field "端口" "${REC_PORT:-22}" validate_port)
    identity=$(prompt_field "密钥路径，可留空" "$REC_IDENTITY" validate_optional)
    note=$(prompt_field "备注，可留空" "$REC_NOTE" validate_optional)
    group=$(prompt_field "分组，可留空" "$REC_GROUP" validate_optional)
    tags=$(prompt_field "标签（多个用:分隔），可留空" "$REC_TAGS" validate_optional)

    append_record "$alias" "$user" "$host" "$port" "$identity" "$note" "$group" "$tags"
    ok "已复制主机：$REC_ALIAS -> $alias"
}

# ---------- SSH 操作 ----------

print_ssh_command() {
    local arg
    printf "ssh"
    for arg in "$@"; do
        printf " %q" "$arg"
    done
    printf "\n"
}

connect_to_host() {
    local identifier="$1"
    local record identity_expanded
    local ssh_args=()

    if [ -z "$identifier" ]; then
        err "缺少主机别名或 ID。"
        return 1
    fi

    shift || true
    record=$(get_record "$identifier")

    if [ -z "$record" ]; then
        err "未找到主机：$identifier"
        return 1
    fi

    parse_record "$record"

    ssh_args=("-p" "${REC_PORT:-22}")

    if [ -n "$REC_IDENTITY" ]; then
        identity_expanded=$(expand_path "$REC_IDENTITY")
        ssh_args+=("-i" "$identity_expanded")

        if [ ! -f "$identity_expanded" ]; then
            warn "密钥文件不存在：$identity_expanded"
        fi
    fi

    # 用户额外传入的 SSH 选项放在目标主机前，避免被 SSH 当作远端命令。
    ssh_args+=("$@" "${REC_USER}@${REC_HOST}")

    ok "正在连接：${REC_ALIAS} (${REC_USER}@${REC_HOST}:${REC_PORT:-22})"
    printf "%s" "$C_CYAN"
    print_ssh_command "${ssh_args[@]}"
    printf "%s" "$C_RESET"

    command ssh "${ssh_args[@]}"
}

# ---------- 批量执行 ----------

exec_on_host() {
    local identifier="$1"
    local cmd="$2"
    local record identity_expanded
    local ssh_args=()

    record=$(get_record "$identifier")
    [ -z "$record" ] && { err "未找到主机：$identifier"; return 1; }

    parse_record "$record"

    ssh_args=("-p" "${REC_PORT:-22}" "-o" "ConnectTimeout=10" "-o" "BatchMode=yes")

    if [ -n "$REC_IDENTITY" ]; then
        identity_expanded=$(expand_path "$REC_IDENTITY")
        ssh_args+=("-i" "$identity_expanded")
    fi

    ssh_args+=("${REC_USER}@${REC_HOST}" "$cmd")

    printf "%s[%s]%s %s\n" "$C_BOLD" "$REC_ALIAS" "$C_RESET" "$cmd"
    command ssh "${ssh_args[@]}" 2>&1 || true
    echo
}

exec_on_group() {
    local group="$1"
    local cmd="$2"
    local records
    

    records=$(get_records_by_group "$group")
    if [ -z "$records" ]; then
        err "分组 $group 中没有主机。"
        return 1
    fi

    echo "$records" | while IFS= read -r line; do
        parse_record "$line"
        exec_on_host "$REC_ALIAS" "$cmd"
    done
}

exec_on_all() {
    local cmd="$1"
    [ -f "$CONFIG_FILE" ] || { err "配置文件不存在。"; return 1; }

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        parse_record "$line"
        exec_on_host "$REC_ALIAS" "$cmd"
    done < "$CONFIG_FILE"
}

# ---------- 健康检查 ----------

ping_host() {
    local record identity_expanded
    local ssh_args=()

    record=$(get_record "$1")
    [ -z "$record" ] && { printf "%s 未找到\n" "$1"; return; }

    parse_record "$record"

    ssh_args=("-p" "${REC_PORT:-22}" "-o" "ConnectTimeout=5" "-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=accept-new")

    if [ -n "$REC_IDENTITY" ]; then
        identity_expanded=$(expand_path "$REC_IDENTITY")
        ssh_args+=("-i" "$identity_expanded")
    fi

    ssh_args+=("${REC_USER}@${REC_HOST}" "echo ok")

    if command ssh "${ssh_args[@]}" 2>&1; then
        printf "  %s%-18s%s %-25s %s%s%s\n" "$C_GREEN" "$REC_ALIAS" "$C_RESET" "$REC_USER@$REC_HOST:$REC_PORT" "$C_GREEN" "✓ 可达" "$C_RESET"
    else
        printf "  %s%-18s%s %-25s %s%s%s\n" "$C_RED" "$REC_ALIAS" "$C_RESET" "$REC_USER@$REC_HOST:$REC_PORT" "$C_RED" "✗ 不可达" "$C_RESET"
    fi
}

ping_all() {
    print_header
    info "SSH 主机可达性检查..."

    if [ ! -s "$CONFIG_FILE" ]; then
        info "还没有保存任何主机。"
        return
    fi

    printf "\n  %-18s %-30s %s\n" "别名" "地址" "状态"
    printf "  %-18s %-30s %s\n" "----" "----" "----"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        parse_record "$line"
        ping_host "$REC_ALIAS"
    done < "$CONFIG_FILE"

    echo
}

# ---------- SSH Config 集成 ----------

export_ssh_config() {
    local output="${1:-$HOME/.ssh/sshm_config}"

    if [ ! -s "$CONFIG_FILE" ]; then
        err "没有可导出的主机配置。"
        return 1
    fi

    print_header
    info "导出 SSH 配置到：$output"

    {
        printf "# Generated by sshm v%s on %s\n" "$VERSION" "$(date)"
        printf "# Source: %s\n" "$CONFIG_FILE"
        echo

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            parse_record "$line"

            printf "Host %s\n" "$REC_ALIAS"
            printf "    HostName %s\n" "$REC_HOST"
            printf "    User %s\n" "$REC_USER"
            printf "    Port %s\n" "${REC_PORT:-22}"
            [ -n "$REC_IDENTITY" ] && printf "    IdentityFile %s\n" "$(expand_path "$REC_IDENTITY")"
            echo
        done < "$CONFIG_FILE"
    } > "$output"

    chmod 600 "$output" 2>/dev/null || true
    ok "SSH 配置已导出到 $output"
    info "使用方法：在 ~/.ssh/config 中添加: Include $output"
}

import_ssh_config() {
    local input="${1:-$HOME/.ssh/config}"
    local count=0

    if [ ! -f "$input" ]; then
        err "SSH 配置文件不存在：$input"
        return 1
    fi

    print_header
    info "从 $input 导入 SSH 配置..."

    awk '
        /^[Hh]ost[[:space:]]/ {
            if (hostname != "" && user != "" && alias != "*") {
                printf "%s,%s,%s,%s,%s,%s,%s,%s\n", alias, user, hostname, port, identity, note, group, tags
                count++
            }
            alias = $2
            hostname = ""
            user = ""
            port = "22"
            identity = ""
            note = ""
            group = ""
            tags = ""
            next
        }
        /^[[:space:]]+HostName[[:space:]]/ { hostname = $2 }
        /^[[:space:]]+User[[:space:]]/ { user = $2 }
        /^[[:space:]]+Port[[:space:]]/ { port = $2 }
        /^[[:space:]]+IdentityFile[[:space:]]/ { identity = $2 }
        END {
            if (hostname != "" && user != "" && alias != "*") {
                printf "%s,%s,%s,%s,%s,%s,%s,%s\n", alias, user, hostname, port, identity, note, group, tags
                count++
            }
        }
    ' "$input" | while IFS= read -r record; do
        parse_record "$record"
        if ! alias_exists "$REC_ALIAS"; then
            append_record "$REC_ALIAS" "$REC_USER" "$REC_HOST" "$REC_PORT" "$REC_IDENTITY" "$REC_NOTE" "$REC_GROUP" "$REC_TAGS"
            count=$((count + 1))
            ok "导入：$REC_ALIAS"
        else
            info "跳过已存在：$REC_ALIAS"
        fi
    done

    ok "SSH 配置导入完成。"
}

# ---------- 升级旧配置 ----------

migrate_config() {
    # 将旧 6 字段配置升级为 8 字段格式
    local temp_file count=0

    temp_file=$(mktemp "${CONFIG_FILE}.XXXXXX") || {
        err "无法创建临时文件。"
        return 1
    }

    if awk -F',' '
        NF == 6 { printf "%s,%s,%s,%s,%s,%s,%s,%s\n", $1, $2, $3, $4, $5, $6, "", ""; count++; next }
        { print }
        END { exit count > 0 ? 0 : 1 }
    ' "$CONFIG_FILE" > "$temp_file"; then
        mv "$temp_file" "$CONFIG_FILE"
        ok "配置文件已升级到新格式。"
    else
        rm -f "$temp_file"
        info "配置文件已是最新格式，无需升级。"
    fi
}

# ---------- UI ----------

print_header() {
    printf "%s\n" "============================================================"
    printf "  %sSSH Host Manager%s  v%s\n" "$C_BOLD" "$C_RESET" "$VERSION"
    printf "%s\n" "============================================================"
}

show_usage() {
    print_header
    cat <<EOF
用法:
  sshm                              进入交互管理界面
  sshm <别名|ID> [SSH参数...]         直接连接主机
  sshm --list [-g <分组>]            列出主机
  sshm --add                         添加主机
  sshm --edit <别名|ID>               编辑主机
  sshm --delete <别名|ID>             删除主机
  sshm --copy <别名|ID>               复制主机
  sshm --show <别名|ID>               查看详情
  sshm --search <关键词>              搜索主机
  sshm --group [<分组名>]             列出分组/按分组筛选
  sshm --ping                        健康检查所有主机
  sshm --exec <目标> <命令>           在目标主机上执行命令
  sshm --export-ssh-config [文件]     导出为 SSH config 格式
  sshm --import-ssh-config [文件]     从 SSH config 导入
  sshm --migrate                     升级旧配置文件

环境变量:
  SSHM_CONFIG_FILE                   自定义配置文件路径
  NO_COLOR=1                         关闭彩色输出
EOF
}

show_help() {
    print_header
    cat <<EOF
命令:
  list, ls, l  [分组]              列出主机
  add, a                            添加主机
  edit, e <别名|ID>                  编辑主机
  del, rm, d <别名|ID>               删除主机
  copy, cp <别名|ID>                 复制主机
  conn, c <别名|ID>                  连接主机
  show, info <别名|ID>               查看详情
  search, find, s <关键词>           搜索主机
  group, g [分组名]                  列出分组
  ping, p                           健康检查
  exec, x <别名> <命令>              单机执行命令
  exec-group, xg <分组> <命令>        分组批量执行
  exec-all, xa <命令>                全量批量执行
  ssh-config, sc                    导出 SSH config
  help, h                           显示帮助
  exit, quit, q                     退出

提示:
  在交互界面中直接输入别名或 ID，也可以快速连接。
EOF
}

management_interface() {
    local line cmd args target group_name exec_cmd

    show_help

    while true; do
        read -r -p "sshm> " line || {
            printf "\n"
            break
        }

        line=$(trim "$line")
        [ -z "$line" ] && continue

        cmd="${line%%[[:space:]]*}"
        if [ "$cmd" = "$line" ]; then
            args=""
        else
            args=$(trim "${line#"$cmd"}")
        fi

        case "$cmd" in
            list|ls|l)
                if [ -n "$args" ]; then
                    format_hosts "" "$args"
                else
                    list_hosts
                fi
                ;;
            add|a)
                add_host
                ;;
            edit|e)
                edit_host "$args"
                ;;
            del|delete|rm|d)
                delete_host "$args"
                ;;
            copy|cp)
                copy_host "$args"
                ;;
            conn|connect|c)
                target=$(require_target "$args")
                [ -n "$target" ] && connect_to_host "$target"
                ;;
            show|info)
                show_host "$args"
                ;;
            search|find|s)
                search_hosts "$args"
                ;;
            group|g)
                list_by_group "$args"
                ;;
            ping|p)
                ping_all
                ;;
            exec|x)
                target="${args%%[[:space:]]*}"
                exec_cmd="${args#"$target"}"
                exec_cmd=$(trim "$exec_cmd")
                [ -z "$target" ] && { err "用法: exec <别名> <命令>"; continue; }
                exec_on_host "$target" "$exec_cmd"
                ;;
            exec-group|xg)
                group_name="${args%%[[:space:]]*}"
                exec_cmd="${args#"$group_name"}"
                exec_cmd=$(trim "$exec_cmd")
                [ -z "$group_name" ] && { err "用法: exec-group <分组> <命令>"; continue; }
                exec_on_group "$group_name" "$exec_cmd"
                ;;
            exec-all|xa)
                [ -z "$args" ] && { err "用法: exec-all <命令>"; continue; }
                exec_on_all "$args"
                ;;
            ssh-config|sc)
                export_ssh_config
                ;;
            help|h|\?)
                show_help
                ;;
            exit|quit|q)
                ok "Bye!"
                break
                ;;
            *)
                if [ -n "$(get_record "$cmd")" ]; then
                    connect_to_host "$cmd"
                else
                    err "未知命令：$cmd。输入 help 查看可用命令。"
                fi
                ;;
        esac
    done
}

# ---------- 入口 ----------

main() {
    case "${1:-}" in
        -h|--help|help)
            show_usage
            ;;
        -v|--version|version)
            printf "sshm %s\n" "$VERSION"
            ;;
        *)
            initialize
            case "${1:-}" in
                "")
                    management_interface
                    ;;
                --migrate|migrate)
                    migrate_config
                    ;;
                -l|--list|list|ls)
                    shift
                    if [ "${1:-}" = "-g" ] || [ "${1:-}" = "--group" ]; then
                        shift
                        format_hosts "" "${1:-}"
                    else
                        list_hosts
                    fi
                    ;;
                -a|--add|add)
                    add_host
                    ;;
                -e|--edit|edit)
                    shift
                    edit_host "${1:-}"
                    ;;
                -d|--delete|delete|del|rm)
                    shift
                    delete_host "${1:-}"
                    ;;
                --copy|copy|cp)
                    shift
                    copy_host "${1:-}"
                    ;;
                --show|show|info)
                    shift
                    show_host "${1:-}"
                    ;;
                -s|--search|search|find)
                    shift
                    search_hosts "$*"
                    ;;
                -g|--group|group)
                    shift
                    list_by_group "${1:-}"
                    ;;
                --ping|ping)
                    ping_all
                    ;;
                --exec|exec)
                    shift
                    local target="$1"
                    shift
                    exec_on_host "$target" "$*"
                    ;;
                --exec-group)
                    shift
                    local grp="$1"
                    shift
                    exec_on_group "$grp" "$*"
                    ;;
                --exec-all)
                    shift
                    exec_on_all "$*"
                    ;;
                --export-ssh-config)
                    shift
                    export_ssh_config "${1:-}"
                    ;;
                --import-ssh-config)
                    shift
                    import_ssh_config "${1:-}"
                    ;;
                conn|connect)
                    shift
                    connect_to_host "${1:-}" "${@:2}"
                    ;;
                *)
                    connect_to_host "$1" "${@:2}"
                    ;;
            esac
            ;;
    esac
}

main "$@"
