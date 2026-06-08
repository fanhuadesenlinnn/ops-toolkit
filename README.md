# ops-toolkit

`ops-toolkit` 是一组面向日常运维的 Bash 小工具，目标是把常见、重复、容易出错的服务器管理操作整理成可复用命令。

当前仓库包含 SSH 主机管理、Linux/macOS 基础运维、软件源、Docker、防火墙、Swap/LVM 和性能排查相关脚本。脚本默认尽量给出确认提示，也支持 `--dry-run` 预览高影响操作。

## 脚本清单

| 脚本 | 用途 | 状态 |
| --- | --- | --- |
| [`sshm.sh`](./sshm.sh) | SSH 主机管理脚本，支持保存主机、按别名或 ID 连接、增删改查、搜索和备注。 | 可用 |
| [`linux-admin-toolkit.sh`](./linux-admin-toolkit.sh) | Linux/macOS 运维工具箱，覆盖常用工具安装、软件源、Docker、防火墙、Swap/LVM 和性能排查。内含 `docker-offline` 模块支持离线二进制安装。 | 可用 |
| [`install-docker-offline.sh`](./install-docker-offline.sh) | Docker 离线二进制独立安装脚本（功能已合并到 toolkit）；支持下载/安装/卸载/打包。 | 可用 |

## 快速开始

```bash
git clone https://github.com/fanhuadesenlinnn/ops-toolkit.git
cd ops-toolkit
chmod +x sshm.sh linux-admin-toolkit.sh
```

查看帮助：

```bash
./sshm.sh --help
./linux-admin-toolkit.sh --help
```

建议首次执行系统配置类操作前先使用 `--dry-run`：

```bash
./linux-admin-toolkit.sh --dry-run tools install
./linux-admin-toolkit.sh --dry-run docker install --source official
```

## sshm.sh

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

配置文件权限会被设置为 `600`。如果需要使用自定义配置文件：

```bash
SSHM_CONFIG_FILE=/path/to/hosts ./sshm.sh --list
```

配置格式为：

```text
alias,user,host,port,identity,note
```

为保持纯 Bash 实现简单可靠，字段中暂不支持英文逗号。

## linux-admin-toolkit.sh

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

### Docker 离线安装模块

`docker-offline` 模块支持在无网络环境中安装 Docker（二进制部署，不依赖包管理器）：

```bash
# 联网机器：下载指定版本 Docker & Compose 二进制
./linux-admin-toolkit.sh docker-offline download --docker-version 28.5.1 --compose-version 2.40.3

# 联网机器：直接制作离线部署包
./linux-admin-toolkit.sh docker-offline package --docker-version 28.5.1 --compose-version 2.40.3

# 离线机器：从本地资源安装
./linux-admin-toolkit.sh docker-offline install --resource-dir ./resources

# 离线机器：卸载
./linux-admin-toolkit.sh docker-offline uninstall

# 彻底卸载（含数据）
./linux-admin-toolkit.sh docker-offline uninstall --purge-data -y

# 查看状态
./linux-admin-toolkit.sh docker-offline status
```

离线安装模块支持的选项：`--resource-dir`、`--docker-version`、`--compose-version`、`--arch`、`--download-if-missing`、`--skip-docker`、`--skip-compose`、`--no-start`、`--no-enable`、`--data-root`、`--registry-mirror`、`--docker-channel`、`--package-file`、`--purge-data`。

## 兼容性

`linux-admin-toolkit.sh` 面向以下环境设计：

- macOS：Homebrew、常用工具、Zsh/Oh My Zsh、Docker Desktop、基础性能排查。
- Debian/Ubuntu 及常见衍生系统：`apt`、软件源、Docker、防火墙、Swap/LVM。
- CentOS/CentOS Stream/RHEL/Rocky/AlmaLinux/Fedora/Kylin 等 RPM 系系统：`dnf`/`yum`、Docker、防火墙、Swap/LVM。

不同发行版的软件源格式和厂商仓库差异较大，公开环境使用前建议先在测试机器或容器中验证。

## 安全提示

这些脚本会执行系统配置、软件安装、服务启停、文件写入等操作。公开或生产环境使用时请注意：

- 先执行 `--dry-run` 查看将要运行的命令。
- 在修改软件源、Shell 配置或 Docker 配置前确认备份目录。
- 不要在配置文件或脚本中保存密码、Token、私钥内容等敏感信息。
- 不要直接运行来源不明的 fork 或第三方修改版本。
- `sshm.sh` 只保存 SSH 连接信息，不保存密码。