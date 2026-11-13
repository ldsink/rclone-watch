<h1 align="center">📦 rclone-watch</h1>

<p align="center"><strong>Automatically upload files to cloud storage with rclone as they arrive.</strong></p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#environment-variables">Configuration</a> ·
  <a href="#file-filters">File filters</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#troubleshooting">Troubleshooting</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

## ✨ Features

- **Recursive watching** captures Linux inotify events when files are closed after writing or moved into the watched directory.
- **Relative paths** preserve the watched directory structure at the destination.
- **Upload controls** include a delay, a concurrency limit, retries, and dry-run mode.
- **Storage backends** include S3, Backblaze B2, and Google Drive through rclone.

<a name="quick-start"></a>

## 🚀 Quick start

This example uses the public `ghcr.io/ldsink/rclone-watch:v0.0.3` image. You need a `linux/amd64` host with Docker Compose. To limit which files are uploaded, configure [file filters](#file-filters) before starting.

### 1. Configure the watched directory and Amazon S3

Download [compose.yaml](compose.yaml) and create an `.env` file beside it. Create the host directory specified by `WATCH_PATH` and replace the bucket, region, and credentials with your own values.

```dotenv
RCLONE_WATCH_IMAGE=ghcr.io/ldsink/rclone-watch:v0.0.3
WATCH_PATH=/mnt/nas/uploads

RCLONE_REMOTE=myremote:my-bucket/
RCLONE_CONFIG_MYREMOTE_TYPE=s3
RCLONE_CONFIG_MYREMOTE_PROVIDER=AWS
RCLONE_CONFIG_MYREMOTE_ACCESS_KEY_ID=your-key
RCLONE_CONFIG_MYREMOTE_SECRET_ACCESS_KEY=your-secret
RCLONE_CONFIG_MYREMOTE_REGION=us-east-1
```

### 2. Start the watcher and upload a test file

Run these commands from the directory containing `compose.yaml`.

```sh
docker compose up -d
docker compose logs -f
```

Once the logs show `Watches established`, open another terminal on the host and write a new file. Adjust the path below to match `WATCH_PATH`.

```sh
printf '%s\n' 'rclone-watch test' > "/mnt/nas/uploads/rclone-watch-test-$(date +%s).txt"
```

The default delay before scheduling the upload is 5 seconds. When the logs show `Uploaded successfully`, look for the test file in the bucket. Subdirectories are preserved, so `2026/report.txt` goes to `myremote:my-bucket/2026/report.txt`.

### 3. Optional dry run

To check the watcher and destination path first, add `DRY_RUN=true` to `.env` before starting, then write a test file as above. Look for `[DRY-RUN] Will be uploaded` in the logs. You can leave out credentials for a dry run. If you also omit `RCLONE_REMOTE`, the logged destination starts with `cloud/`.

When ready to upload, set `DRY_RUN=false`, fill in the remote settings, run `docker compose up -d` again, and write a fresh test file.

<a name="environment-variables"></a>

## ⚙️ Environment variables

`RCLONE_WATCH_IMAGE` and `WATCH_PATH` configure Compose. The service loads runtime settings from `.env` and explicitly sets `WATCH_DIR=/watch`, which takes precedence over any `WATCH_DIR` in `.env`. When running the image directly, pass runtime settings with `-e` or `--env-file`.

| Variable                        | Default                                          | Purpose                                                                                                                                         |
| ------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `RCLONE_WATCH_IMAGE`            | Required by Compose                              | Image and tag to run, from GHCR or a local build                                                                                                |
| `WATCH_PATH`                    | Required by Compose                              | Host directory to watch, mounted read-write in the container                                                                                    |
| `WATCH_DIR`                     | `/watch`                                         | Existing directory to watch inside the container. Override it when running the image directly if the directory is mounted elsewhere             |
| `WATCH_INCLUDE`                 | Empty                                            | Require an include match when set. See [File filters](#file-filters).                                                                           |
| `WATCH_EXCLUDE`                 | Empty                                            | Skip any exclude match. See [File filters](#file-filters).                                                                                      |
| `RCLONE_REMOTE`                 | Required for uploads                             | Destination base, such as `myremote:` or `myremote:my-bucket/subfolder/`. Dry runs use `cloud/` if unset or empty                               |
| `RCLONE_CONFIG_<NAME>_TYPE`     | Required for a remote defined in the environment | Remote type, such as `s3`, `b2`, or `drive`                                                                                                     |
| `RCLONE_CONFIG_<NAME>_<OPTION>` | Depends on the backend                           | Backend options, such as S3's `PROVIDER`, `ENV_AUTH`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `REGION`, and `ENDPOINT` for S3-compatible services |
| `S3_PREFIX`                     | Empty                                            | Optional relative directory prefix placed before the file path. Applies to any backend                                                          |
| `UPLOAD_DELAY`                  | `5`                                              | Seconds to wait after each file event before scheduling an upload. Use `0` or a positive integer without leading zeros. Empty uses the default  |
| `MAX_PARALLEL`                  | `5`                                              | Maximum concurrent uploads. Use a positive integer without leading zeros. Empty uses the default                                                |
| `DRY_RUN`                       | `false`                                          | Accepts `true` or `false`. Set to `true` to log destination paths and file sizes without calling rclone.                                        |
| `DELETE_AFTER_UPLOAD`           | `false`                                          | Supported since `v0.0.3`. Accepts `true` or `false`. Set to `true` to delete an unchanged local file after a verified upload.                   |

Unset or empty boolean settings default to `false`. Other values must be `true` or `false`.

<a name="file-filters"></a>

## 🎯 File filters

Starting with `v0.0.2`, you can add `WATCH_INCLUDE` and `WATCH_EXCLUDE` to the deployment `.env`. Run `docker compose up -d` to apply the rules.

Use one case-sensitive Bash glob per line. Rules match paths relative to `WATCH_DIR`, empty lines are ignored, and `*` can span directory separators. If include rules are set, a file must match at least one. Any exclude match skips the file. The same rules apply to retries and `DRY_RUN`. With `DRY_RUN=true`, the watcher preserves local files regardless of `DELETE_AFTER_UPLOAD` and leaves the retry queue untouched.

```dotenv
WATCH_INCLUDE='*.txt
*.csv'
WATCH_EXCLUDE='archive/*
*.tmp.txt'
```

| Relative path        | Result                              |
| -------------------- | ----------------------------------- |
| `2026/report.txt`    | Upload                              |
| `2026/data.csv`      | Upload                              |
| `archive/report.txt` | Excluded by the directory rule      |
| `report.tmp.txt`     | Excluded by the temporary-file rule |
| `photo.jpg`          | Outside the include patterns        |

<a name="storage-destinations"></a>

## ☁️ Storage destinations

End a destination that includes a path with `/`. The watcher appends the optional `S3_PREFIX` and the relative file path directly to an rclone destination containing a colon. For example, `myremote:my-bucket/subfolder/` with `S3_PREFIX=backup` writes `report.txt` to `myremote:my-bucket/subfolder/backup/report.txt`. A remote root such as `myremote:` already has the required separator.

`<NAME>` is the uppercase remote name before the colon in `RCLONE_REMOTE`. For example, `myremote` uses `RCLONE_CONFIG_MYREMOTE_*`. The bundled rclone also reads its own environment variables, such as `RCLONE_BWLIMIT` for bandwidth limits, `RCLONE_LOG_LEVEL` for logging, and `HTTPS_PROXY` for HTTPS requests. For the full set of options and backend-specific authentication settings, see the [rclone documentation](https://rclone.org/docs/#environment-variables).

<a name="how-it-works"></a>

## 🔄 How it works

```mermaid
flowchart TD
    Event(["File write or move"]) --> Watch["inotify detects the event"]
    Watch --> Filters{"Passes the path filters?"}
    Filters -->|No| Skip(["Skip file"])
    Filters -->|Yes| Wait["Wait for the delay and an upload slot"]
    Wait --> Upload["rclone copies the file"]
    Upload -->|Success| Cloud[("Cloud storage")]
    Upload -->|Failure| Queue[("Retry queue")]
    Cloud -.->|New upload succeeds| Retry["Recheck queued paths"]
    Queue -.->|Read queue| Retry
    Retry -.->|Retry eligible files| Upload

    classDef input fill:#dbeafe,stroke:#2563eb,color:#172554
    classDef decision fill:#ede9fe,stroke:#7c3aed,color:#2e1065
    classDef success fill:#dcfce7,stroke:#16a34a,color:#14532d
    classDef retry fill:#fef3c7,stroke:#d97706,color:#451a03
    class Event,Watch,Wait,Upload input
    class Filters decision
    class Cloud success
    class Queue,Retry retry
```

Existing files are skipped at startup. Local files stay in place by default. Use filenames without newlines.

<a name="troubleshooting"></a>

## 🛠️ Troubleshooting

- **The container fails to start.** Check `docker compose logs --tail=100 rclone-watch`. Make sure `.env` is beside `compose.yaml` and the host directory in `WATCH_PATH` exists.
- **Writing a file produces no log entry.** Wait for `Watches established`, write a new file on the host, and allow for `UPLOAD_DELAY`. If filters are enabled, check whether the relative path matches. Network mounts and Docker Desktop shares may fail to propagate inotify events. Test with a local Linux directory.
- **The logs show `Upload failed`.** Check the rclone error, destination path, credentials, and write permissions. Inspect the queue with `docker compose exec rclone-watch cat /tmp/upload_queue.txt`. After fixing the error, write a new file. A successful upload triggers retries. Recreating the container clears the queue.
- **The source stays in place with `DELETE_AFTER_UPLOAD=true`.** Check the logs for a skipped transfer, a changed source, or a verification or deletion failure. An already up-to-date destination can cause rclone to skip the transfer, leaving the local file in place. Verification reads back the destination object and needs remote read access. Deletion needs write access to the source directory. Finish writing files before handing them to the watcher and avoid reusing their paths during upload and verification.
- **You edited `.env`.** Run `docker compose up -d` to apply the settings, then verify with a new file.

<a name="container-image"></a>

## 🐳 Container image

The public image `ghcr.io/ldsink/rclone-watch` supports `linux/amd64`. [See published tags](https://github.com/ldsink/rclone-watch/pkgs/container/rclone-watch).

```sh
docker pull ghcr.io/ldsink/rclone-watch:v0.0.3
```

<a name="license"></a>

## 📄 License

Released under the [MIT License](LICENSE). The watcher script draws on [dx8ug/rclone-watch](https://github.com/dx8ug/rclone-watch).
