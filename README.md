# rclone-watch

用 inotify 递归监听 Linux 目录。文件写入关闭或移动到监听目录后，rclone 将文件复制到配置的目标，并保留相对目录结构。已有文件不会在启动时扫描，本地文件不会被删除。

本仓库交付基于 **Alpine Linux 3.23.8** 的 `linux/amd64` 容器镜像。镜像地址为 `ghcr.io/<owner>/<repo>`，仓库所有者和仓库名均为小写。首次发布后，可在 GitHub Packages 中将包设为公开以允许匿名拉取。私有包需要先登录 GHCR。

## 发布版本

Git 标签是版本来源，格式为 `vMAJOR.MINOR.PATCH`。按语义化版本管理，破坏兼容性时递增主版本，新增兼容功能时递增次版本，兼容的修复递增补丁版本。

将发布流程合入 `main` 后，可在 GitHub Releases 中选择发布提交并创建正式 Release，也可以从本仓库运行以下命令发布 `v1.0.0`：

```sh
gh release create v1.0.0 --target main --title v1.0.0 --generate-notes
```

GitHub Actions 仅在正式 Release 发布后构建并测试镜像。测试通过后，工作流推送与 Git 标签同名的镜像，并更新 `latest`。部署时可固定到已发布的版本标签。

## Docker Compose 部署

将 [compose.yaml](compose.yaml) 保存到部署目录，并在同一目录创建 `.env`。以下是 Amazon S3 示例，将镜像地址、宿主机目录、存储桶和凭据替换为实际值。宿主机目录需事先创建。

```dotenv
RCLONE_WATCH_IMAGE=ghcr.io/ldsink/rclone-watch:v1.0.0
WATCH_PATH=/mnt/nas/uploads
RCLONE_REMOTE=myremote:my-bucket
RCLONE_CONFIG_MYREMOTE_TYPE=s3
RCLONE_CONFIG_MYREMOTE_PROVIDER=AWS
RCLONE_CONFIG_MYREMOTE_ACCESS_KEY_ID=your-key
RCLONE_CONFIG_MYREMOTE_SECRET_ACCESS_KEY=your-secret
RCLONE_CONFIG_MYREMOTE_REGION=us-east-1
S3_PREFIX=backup
UPLOAD_DELAY=5
MAX_PARALLEL=5
DRY_RUN=false
```

```sh
docker compose pull
docker compose up -d
docker compose logs -f
```

监听建立后，在宿主机目录中写入文件。例如 `/mnt/nas/uploads/2026/report.txt` 会上传到 `myremote:my-bucket/backup/2026/report.txt`。将 `DRY_RUN` 设为 `true` 可以只验证监听和目标路径，测试时可以省略远端配置。

## 环境变量

| 变量                            | 默认值          | 用途                                                                                                                        |
| ------------------------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `RCLONE_WATCH_IMAGE`            | 必填（Compose） | 要部署的 GHCR 镜像，包含标签                                                                                                |
| `WATCH_PATH`                    | 必填（Compose） | 宿主机监听目录，以只读方式挂载到容器                                                                                        |
| `WATCH_DIR`                     | `/watch`        | 容器内监听目录，直接运行镜像时可覆盖                                                                                        |
| `RCLONE_REMOTE`                 | 上传模式必填    | 远端及目标路径，例如 `myremote:my-bucket/subfolder`                                                                         |
| `RCLONE_CONFIG_<NAME>_TYPE`     | 由远端决定      | 远端类型，例如 `s3`、`b2` 或 `drive`                                                                                        |
| `RCLONE_CONFIG_<NAME>_<OPTION>` | 由后端决定      | 后端配置，例如 S3 的 `PROVIDER`、`ENV_AUTH`、`ACCESS_KEY_ID`、`SECRET_ACCESS_KEY`、`REGION` 和兼容 S3 服务常用的 `ENDPOINT` |
| `S3_PREFIX`                     | 空              | 附加在目标路径下的目录前缀，适用于所有远端                                                                                  |
| `UPLOAD_DELAY`                  | `5`             | 每个文件事件在安排上传前等待的秒数，非负整数                                                                                |
| `MAX_PARALLEL`                  | `5`             | 并发上传任务上限，正整数                                                                                                    |
| `DRY_RUN`                       | `false`         | 设为 `true` 仅记录预计上传路径                                                                                              |

`<NAME>` 是 `RCLONE_REMOTE` 冒号前的远端名转为大写，例如 `myremote` 对应 `RCLONE_CONFIG_MYREMOTE_*`。不同存储后端的认证和配置请查阅 [rclone 文档](https://rclone.org/docs/#environment-variables)。

- Backblaze B2 使用 `TYPE=b2`，后端参数包括 `ACCOUNT` 和 `KEY`。
- Google Drive 使用 `TYPE=drive`，后端参数包括 `CLIENT_ID`、`CLIENT_SECRET` 和 `TOKEN`。各参数均使用相同的 `RCLONE_CONFIG_<NAME>_` 前缀。

上传失败时，文件路径进入容器内的队列，后续有新文件上传成功时会重试。队列保存在容器的 `/tmp`，重建容器会清空队列。监听依赖 Linux 文件系统的 inotify 事件，网络挂载或 Docker Desktop 的宿主机共享目录可能无法传递这些事件。文件名需避免换行。

## 许可证

采用 [MIT 许可证](LICENSE)，监听脚本源自 [dx8ug/rclone-watch](https://github.com/dx8ug/rclone-watch)。
