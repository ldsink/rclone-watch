# rclone-watch

[English](README.md)

用 inotify 递归监听 Linux 目录。文件写入关闭或移动到监听目录后，rclone 将文件复制到配置的目标，并保留相对目录结构。已有文件不会在启动时扫描，本地文件不会被删除。

本仓库交付基于 **Alpine Linux 3.23.8** 的 `linux/amd64` 容器镜像。镜像地址为 `ghcr.io/<owner>/<repo>`，仓库所有者和仓库名均为小写。首次发布后，可在 GitHub Packages 中将包设为公开以允许匿名拉取。私有包需要先登录 GHCR。

## Docker Compose 部署

将 [compose.yaml](compose.yaml) 保存到部署目录，并在同一目录创建 `.env`。以下是 Amazon S3 示例，将镜像地址、宿主机目录、存储桶和凭据替换为实际值。宿主机目录需事先创建。

```dotenv
# Docker Compose: select the image version and the host directory to watch.
RCLONE_WATCH_IMAGE=ghcr.io/ldsink/rclone-watch:v0.0.1
WATCH_PATH=/mnt/nas/uploads

# Upload destination: MYREMOTE in the settings below matches myremote in RCLONE_REMOTE.
# S3_PREFIX adds a directory under the bucket before the file's relative path.
RCLONE_REMOTE=myremote:my-bucket/
S3_PREFIX=backup

# Amazon S3 remote: set the backend, AWS region, and credentials for myremote.
RCLONE_CONFIG_MYREMOTE_TYPE=s3
RCLONE_CONFIG_MYREMOTE_PROVIDER=AWS
RCLONE_CONFIG_MYREMOTE_ACCESS_KEY_ID=your-key
RCLONE_CONFIG_MYREMOTE_SECRET_ACCESS_KEY=your-secret
RCLONE_CONFIG_MYREMOTE_REGION=us-east-1

# Upload scheduling: wait after each file event and cap concurrent uploads.
UPLOAD_DELAY=5
MAX_PARALLEL=5

# Set to true to log planned uploads without sending files.
DRY_RUN=false
```

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
| `RCLONE_REMOTE`                 | 上传模式必填               | 目标路径的起点，例如 `myremote:` 或 `myremote:my-bucket/subfolder/`。模拟模式下未设置或为空时使用 `cloud/`                  |
| `RCLONE_CONFIG_<NAME>_TYPE`     | 通过环境变量定义远端时必填 | 远端类型，例如 `s3`、`b2` 或 `drive`                                                                                        |
| `RCLONE_CONFIG_<NAME>_<OPTION>` | 由后端决定                 | 后端配置，例如 S3 的 `PROVIDER`、`ENV_AUTH`、`ACCESS_KEY_ID`、`SECRET_ACCESS_KEY`、`REGION` 和兼容 S3 服务常用的 `ENDPOINT` |
| `S3_PREFIX`                     | 空                         | 可选的相对目录前缀，插在文件相对路径之前，适用于所有后端                                                                    |
| `UPLOAD_DELAY`                  | `5`                        | 每个文件事件在安排上传前等待的秒数。接受 `0` 或无前导零的正整数，留空使用默认值                                             |
| `MAX_PARALLEL`                  | `5`                        | 并发上传任务上限。接受无前导零的正整数，留空使用默认值                                                                      |
| `DRY_RUN`                       | `false`                    | 仅字面值 `true` 启用模拟。记录目标路径和文件大小，不调用 rclone                                                             |

指定目标目录时，路径应以 `/` 结尾。对于含冒号的 rclone 目标，脚本会直接拼接可选的 `S3_PREFIX` 和文件相对路径。例如，目标为 `myremote:my-bucket/subfolder/` 且设置 `S3_PREFIX=backup` 时，`report.txt` 会上传到 `myremote:my-bucket/subfolder/backup/report.txt`。远端根目录（如 `myremote:`）已有分隔符。

`<NAME>` 是 `RCLONE_REMOTE` 冒号前的远端名转为大写，例如 `myremote` 对应 `RCLONE_CONFIG_MYREMOTE_*`。容器内的 rclone 也会读取自己的环境变量，例如限速用的 `RCLONE_BWLIMIT`、控制日志级别的 `RCLONE_LOG_LEVEL`，以及 HTTPS 请求使用的 `HTTPS_PROXY`。完整选项和各后端认证配置请查阅 [rclone 文档](https://rclone.org/docs/#environment-variables)。

- Backblaze B2 使用 `TYPE=b2`，后端参数包括 `ACCOUNT` 和 `KEY`。
- Google Drive 使用 `TYPE=drive`，后端参数包括 `CLIENT_ID`、`CLIENT_SECRET` 和 `TOKEN`。各参数均使用相同的 `RCLONE_CONFIG_<NAME>_` 前缀。

上传失败时，文件路径进入容器内的队列，后续有新文件上传成功时会重试。队列保存在容器的 `/tmp`，重建容器会清空队列。监听依赖 Linux 文件系统的 inotify 事件，网络挂载或 Docker Desktop 的宿主机共享目录可能无法传递这些事件。文件名需避免换行。

## 许可证

采用 [MIT 许可证](LICENSE)，监听脚本源自 [dx8ug/rclone-watch](https://github.com/dx8ug/rclone-watch)。
