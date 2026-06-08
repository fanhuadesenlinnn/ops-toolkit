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
#
#      VERSION:  2.0.0
#
#==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
CONFIG_FILE="${SSHM_CONFIG_FILE:-$HOME/.sshm_hosts}"

# 配置格式：alias,user,host,port,identity,note
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

print_header() {
    printf "%s\n" "============================================================"
    printf "  %sSSH Host Manager%s  v%s\n" "$C_BOLD" "$C_RESET" "$VERSION"
    printf "%s\n" "============================================================"
}

show_usage() {
    print_header
    cat <<EOF
用法:
  sshm                         进入交互管理界面
  sshm <别名|ID> [SSH参数...]   直接连接主机
  sshm --list                  列出主机
  sshm --add                   添加主机
  sshm --edit <别名|ID>         编辑主机
  sshm --delete <别名|ID>       删除主机
  sshm --show <别名|ID>         查看详情
  sshm --search <关键词>        搜索主机

环境变量:
  SSHM_CONFIG_FILE             自定义配置文件路径
  NO_COLOR=1                   关闭彩色输出
EOF
}

show_help() {
    print_header
    cat <<EOF
命令:
  list, ls, l                  列出主机
  add, a                       添加主机
  edit, e <别名|ID>             编辑主机
  del, rm, d <别名|ID>          删除主机
  conn, c <别名|ID>             连接主机
  show, info <别名|ID>          查看详情
  search, find, s <关键词>      搜索主机
  help, h                      显示帮助
  exit, quit, q                退出

提示:
  在交互界面中直接输入别名或 ID，也可以快速连接。
EOF
}

parse_record() {
    # 将一行配置拆到全局变量，便于多个函数复用。
    IFS=',' read -r REC_ALIAS REC_USER REC_HOST REC_PORT REC_IDENTITY REC_NOTE _REC_EXTRA <<EOF
$1
EOF
}

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

format_hosts() {
    local keyword="${1:-}"

    awk -F',' -v keyword="$keyword" '
        BEGIN {
            q = tolower(keyword)
            printf "%-4s %-18s %-26s %-6s %-28s %s\n", "ID", "别名", "用户@主机", "端口", "密钥", "备注"
            printf "%-4s %-18s %-26s %-6s %-28s %s\n", "--", "----", "---------", "----", "----", "----"
        }
        {
            line = tolower($0)
            if (q != "" && index(line, q) == 0) {
                next
            }

            identity = ($5 == "") ? "默认" : $5
            note = ($6 == "") ? "-" : $6
            printf "%-4s %-18s %-26s %-6s %-28s %s\n", NR, $1, $2 "@" $3, $4, identity, note
            count++
        }
        END {
            if (count == 0) {
                print "暂无匹配主机。"
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
}

append_record() {
    printf "%s,%s,%s,%s,%s,%s\n" "$1" "$2" "$3" "$4" "$5" "$6" >> "$CONFIG_FILE"
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
    local alias user host port identity note

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

    append_record "$alias" "$user" "$host" "$port" "$identity" "$note"
    ok "已添加主机：$alias"
}

edit_host() {
    local identifier line_no record alias user host port identity note new_record

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

    new_record="${alias},${user},${host},${port},${identity},${note}"
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

management_interface() {
    local line cmd args target

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
                list_hosts
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
                -l|--list|list|ls)
                    list_hosts
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
                --show|show|info)
                    shift
                    show_host "${1:-}"
                    ;;
                -s|--search|search|find)
                    shift
                    search_hosts "$*"
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
