# ops-toolkit

`ops-toolkit` 用于沉淀日常运维中可复用的小脚本和工具。目标是把常见、重复、容易出错的操作整理成简单可靠的命令，方便在服务器管理、环境排查、存储维护和性能测试等场景中快速使用。

## 脚本清单

建议为每个脚本保留一条用途说明。这样仓库脚本变多后，README 仍然可以作为快速索引，而不需要打开每个文件逐个确认功能。

| 脚本 | 用途 | 状态 |
| --- | --- | --- |
| [`sshm.sh`](./sshm.sh) | SSH 主机管理脚本，支持保存主机、按别名或 ID 连接、增删改查、搜索和备注。 | 可用 |
| [`linux-admin-toolkit.sh`](./linux-admin-toolkit.sh) | Linux/macOS 运维工具箱，覆盖常用工具安装、软件源、Docker、防火墙、Swap/LVM 和性能排查。 | 可用 |

## 当前工具

### sshm.sh

`sshm.sh` 是一个轻量的 SSH 主机管理器，适合管理多台服务器连接信息。

主要功能：

- 保存 SSH 主机信息，包括别名、用户、地址、端口、密钥和备注。
- 支持交互式管理界面。
- 支持通过别名或 ID 直接连接服务器。
- 支持主机列表、搜索、查看详情、编辑和删除。
- 支持自定义配置文件路径，便于在不同环境中隔离配置。

常用命令：

```bash
./sshm.sh
./sshm.sh --list
./sshm.sh --add
./sshm.sh --edit <别名或ID>
./sshm.sh --delete <别名或ID>
./sshm.sh --search <关键词>
./sshm.sh <别名或ID>
```

配置文件默认保存在：

```bash
~/.sshm_hosts
```

如果需要使用自定义配置文件：

```bash
SSHM_CONFIG_FILE=/path/to/hosts ./sshm.sh --list
```

### linux-admin-toolkit.sh

`linux-admin-toolkit.sh` 是一个面向 Linux/macOS 的综合运维脚本，适合初始化环境、调整基础配置和做常见排查。

主要功能：

- 安装和配置常用工具、Shell 环境、Zsh/Oh My Zsh、rupa/z 等。
- 管理系统软件源，支持官方源和常见镜像源。
- 安装 Docker、配置镜像加速、导出镜像和查看 Docker 状态。
- 管理防火墙、Swap 和 LVM。
- 快速查看系统环境并执行基础性能瓶颈排查。
- 支持 `--dry-run` 预览命令，适合在生产环境执行前确认影响。

常用命令：

```bash
./linux-admin-toolkit.sh --help
./linux-admin-toolkit.sh menu
./linux-admin-toolkit.sh env
./linux-admin-toolkit.sh tools install
./linux-admin-toolkit.sh mirror set --source tuna
./linux-admin-toolkit.sh docker install --source tuna
./linux-admin-toolkit.sh firewall status
./linux-admin-toolkit.sh swap add --size 4G --path /swapfile
./linux-admin-toolkit.sh lvm list
./linux-admin-toolkit.sh perf quick
```

全局选项：

```bash
-y, --yes       默认确认
-n, --dry-run   只打印不执行
--no-color      禁用颜色
```

多数系统配置类操作需要管理员权限，执行前建议先使用 `--dry-run` 观察将要执行的命令。

## 计划收录方向

后续可以继续补充以下类型的工具：

- SSH、跳板机、批量登录和连接管理脚本。
- LVM、磁盘、文件系统和挂载管理脚本。
- Linux CPU、内存、磁盘、网络性能测试脚本。
- 服务巡检、日志分析、端口检查和进程排查脚本。
- 备份、同步、压缩、清理和部署辅助脚本。

## 维护约定

新增脚本时建议同步补充：

- 在“脚本清单”中增加用途说明。
- 在脚本头部写明用途、用法和版本。
- 对关键逻辑添加中文注释。
- 保持脚本参数简洁，输出清晰，失败时给出明确错误信息。
- 避免在脚本中写死敏感信息，例如密码、Token、私钥路径等。

## 使用提示

下载脚本后，如需直接执行，请先添加执行权限：

```bash
chmod +x <script-name>
```

执行前建议先查看帮助或源码，确认脚本行为符合当前环境需求。
