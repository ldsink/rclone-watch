<h1 align="center">📦 rclone-watch</h1>

<p align="center"><strong>文件写入完成后，自动通过 rclone 上传到云存储。</strong></p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#环境变量">配置</a> ·
  <a href="#文件过滤">文件过滤</a> ·
  <a href="#工作原理">工作原理</a> ·
  <a href="README.md">English</a>
</p>

## ✨ 功能

- **递归监听** — 在 Linux 上通过 inotify 捕捉文件写入完成和移入事件。
- **按规则上传** — 按相对路径筛选文件，并在目标端保留目录结构。
- **上传控制** — 支持上传延时、并发上限、失败重试和模拟运行。
- **多种存储后端** — 通过 rclone 上传到 S3、Backblaze B2、Google Drive 等目标。

## 快速开始

### 1. 配置 Docker Compose

将 [compose.yaml](compose.yaml) 保存到部署目录，并在同一目录创建 `.env`。以下是 Amazon S3 示例，将镜像地址、宿主机目录、存储桶和凭据替换为实际值。宿主机目录需事先创建。

```dotenv
# 选择镜像版本和要监听的宿主机目录。
RCLONE_WATCH_IMAGE=ghcr.io/ldsink/rclone-watch:v0.0.1
WATCH_PATH=/mnt/nas/uploads

# 配置上传目标。下方变量中的 MYREMOTE 对应 RCLONE_REMOTE 中的 myremote。
# S3_PREFIX 在文件的相对路径前加一层目录。
RCLONE_REMOTE=myremote:my-bucket/
S3_PREFIX=backup

# 配置 myremote 的存储后端、AWS 区域和凭据。
RCLONE_CONFIG_MYREMOTE_TYPE=s3
RCLONE_CONFIG_MYREMOTE_PROVIDER=AWS
RCLONE_CONFIG_MYREMOTE_ACCESS_KEY_ID=your-key
RCLONE_CONFIG_MYREMOTE_SECRET_ACCESS_KEY=your-secret
RCLONE_CONFIG_MYREMOTE_REGION=us-east-1

# 可选的上传过滤规则，每行一条。
WATCH_INCLUDE='*.txt
*.csv'
WATCH_EXCLUDE='archive/*
*.tmp.txt'

# 设置上传延时和并发上限。
UPLOAD_DELAY=5
MAX_PARALLEL=5

# 设为 true 时，只记录计划上传的文件。
DRY_RUN=false
```

### 2. 启动并查看日志

```sh
docker compose pull
docker compose up -d
docker compose logs -f
```

监听建立后，在宿主机目录中写入文件。例如 `/mnt/nas/uploads/2026/report.txt` 会上传到 `myremote:my-bucket/backup/2026/report.txt`。将 `DRY_RUN` 设为 `true` 可以只验证监听和目标路径，测试时可以省略远端配置。

## 环境变量

`RCLONE_WATCH_IMAGE` 和 `WATCH_PATH` 用于配置 Compose。服务从 `.env` 加载运行参数，并显式设置 `WATCH_DIR=/watch`，优先于 `.env` 中的同名变量。直接运行镜像时，可以通过 `-e` 或 `--env-file` 传入运行参数。

| 变量                            | 默认值                     | 用途                                                                                                                        |
| ------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `RCLONE_WATCH_IMAGE`            | 必填（Compose）            | 要部署的 GHCR 镜像，包含标签                                                                                                |
| `WATCH_PATH`                    | 必填（Compose）            | 宿主机监听目录，以只读方式挂载到容器                                                                                        |
| `WATCH_DIR`                     | `/watch`                   | 容器内已存在的监听目录。直接运行镜像且挂载到其他路径时可覆盖                                                                |
| `WATCH_INCLUDE`                 | 空                         | 设置后，只上传命中至少一条包含规则的文件                                                                                    |
| `WATCH_EXCLUDE`                 | 空                         | 跳过命中任意一条排除规则的文件                                                                                              |
| `RCLONE_REMOTE`                 | 上传模式必填               | 目标路径的起点，例如 `myremote:` 或 `myremote:my-bucket/subfolder/`。模拟模式下未设置或为空时使用 `cloud/`                  |
| `RCLONE_CONFIG_<NAME>_TYPE`     | 通过环境变量定义远端时必填 | 远端类型，例如 `s3`、`b2` 或 `drive`                                                                                        |
| `RCLONE_CONFIG_<NAME>_<OPTION>` | 由后端决定                 | 后端配置，例如 S3 的 `PROVIDER`、`ENV_AUTH`、`ACCESS_KEY_ID`、`SECRET_ACCESS_KEY`、`REGION` 和兼容 S3 服务常用的 `ENDPOINT` |
| `S3_PREFIX`                     | 空                         | 可选的相对目录前缀，插在文件相对路径之前，适用于所有后端                                                                    |
| `UPLOAD_DELAY`                  | `5`                        | 每个文件事件在安排上传前等待的秒数。接受 `0` 或无前导零的正整数，留空使用默认值                                             |
| `MAX_PARALLEL`                  | `5`                        | 并发上传任务上限。接受无前导零的正整数，留空使用默认值                                                                      |
| `DRY_RUN`                       | `false`                    | 仅字面值 `true` 启用模拟。记录目标路径和文件大小，不调用 rclone                                                             |

## 文件过滤

每个变量每行填写一条规则，空行忽略。规则使用区分大小写的 Bash 通配模式，匹配相对于 `WATCH_DIR` 的路径。`*` 可以跨目录分隔符，因此 `*.txt` 也能匹配子目录里的文件。两项同时设置时，文件必须命中至少一条包含规则，且未命中任何排除规则。失败重试和 `DRY_RUN` 也使用相同规则。

使用快速开始中的配置时，结果如下。

| 相对路径             | 结果                 |
| -------------------- | -------------------- |
| `2026/report.txt`    | 上传                 |
| `2026/data.csv`      | 上传                 |
| `archive/report.txt` | 命中目录排除规则     |
| `report.tmp.txt`     | 命中临时文件排除规则 |
| `photo.jpg`          | 未命中包含规则       |

## 存储目标

指定目标目录时，路径应以 `/` 结尾。对于含冒号的 rclone 目标，脚本会直接拼接可选的 `S3_PREFIX` 和文件相对路径。例如，目标为 `myremote:my-bucket/subfolder/` 且设置 `S3_PREFIX=backup` 时，`report.txt` 会上传到 `myremote:my-bucket/subfolder/backup/report.txt`。远端根目录（如 `myremote:`）已有分隔符。

`<NAME>` 是 `RCLONE_REMOTE` 冒号前的远端名转为大写，例如 `myremote` 对应 `RCLONE_CONFIG_MYREMOTE_*`。容器内的 rclone 也会读取自己的环境变量，例如限速用的 `RCLONE_BWLIMIT`、控制日志级别的 `RCLONE_LOG_LEVEL`，以及 HTTPS 请求使用的 `HTTPS_PROXY`。完整选项和各后端认证配置请查阅 [rclone 文档](https://rclone.org/docs/#environment-variables)。

- Backblaze B2 使用 `TYPE=b2`，后端参数包括 `ACCOUNT` 和 `KEY`。
- Google Drive 使用 `TYPE=drive`，后端参数包括 `CLIENT_ID`、`CLIENT_SECRET` 和 `TOKEN`。各参数均使用相同的 `RCLONE_CONFIG_<NAME>_` 前缀。

## 工作原理

```mermaid
flowchart TD
    Event(["文件写入完成或移入"]) --> Watch["inotify 捕捉事件"]
    Watch --> Filters{"通过路径筛选？"}
    Filters -->|否| Skip(["跳过文件"])
    Filters -->|是| Wait["等待上传延时和并发槽"]
    Wait --> Upload["rclone 复制文件"]
    Upload -->|成功| Cloud[("云存储")]
    Upload -->|失败| Queue[("失败队列")]
    Cloud -.->|新文件上传成功| Retry["重新筛选队列文件"]
    Queue -.->|读取队列| Retry
    Retry -.->|重试符合规则的文件| Upload

    classDef input fill:#dbeafe,stroke:#2563eb,color:#172554
    classDef decision fill:#ede9fe,stroke:#7c3aed,color:#2e1065
    classDef success fill:#dcfce7,stroke:#16a34a,color:#14532d
    classDef retry fill:#fef3c7,stroke:#d97706,color:#451a03
    class Event,Watch,Wait,Upload input
    class Filters decision
    class Cloud success
    class Queue,Retry retry
```

启动时跳过已有文件，本地文件始终保留。失败队列保存在容器的 `/tmp`，重建容器会清空队列。

网络挂载或 Docker Desktop 的宿主机共享目录可能无法传递 inotify 事件。文件名需避免换行。

## 容器镜像

本仓库交付基于 **Alpine Linux 3.23.8** 的 `linux/amd64` 容器镜像。镜像地址为 `ghcr.io/<owner>/<repo>`，仓库所有者和仓库名均为小写。首次发布后，可在 GitHub Packages 中将包设为公开以允许匿名拉取。私有包需要先登录 GHCR。

## 许可证

采用 [MIT 许可证](LICENSE)。监听脚本参考了 [dx8ug/rclone-watch](https://github.com/dx8ug/rclone-watch)。
