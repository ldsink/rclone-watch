#!/usr/bin/env bash
set -euo pipefail

image="${1:-rclone-watch:ci}"
watch_dir=$(mktemp -d)
container="rclone-watch-upload-test-$$"

cleanup() {
    docker logs "$container" || true
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$watch_dir"
}
trap cleanup EXIT

mkdir "$watch_dir/nested"
docker run --detach --init --name "$container" \
    --mount "type=bind,src=$watch_dir,dst=/watch,readonly" \
    -e RCLONE_REMOTE=:local:/out -e S3_PREFIX=backup -e UPLOAD_DELAY=0 -e MAX_PARALLEL=1 \
    -e WATCH_INCLUDE=$'*.txt\n*.csv' -e WATCH_EXCLUDE='*.tmp.txt' \
    "$image"

timeout 20 bash -c '
  until docker logs "$1" 2>&1 | grep -q "Watches established"; do
    sleep 0.5
  done
' _ "$container"
test "$(docker exec "$container" cat /etc/alpine-release)" = 3.23.8
touch "$watch_dir/nested/excluded.tmp.txt" "$watch_dir/nested/unmatched.log"
printf '%s\n' 'test payload' >"$watch_dir/nested/file name.csv"
timeout 30 bash -c '
  until docker exec "$1" cmp -s \
    "/watch/nested/file name.csv" "/out/backup/nested/file name.csv"; do
    sleep 0.5
  done
' _ "$container"
docker exec "$container" test ! -e /out/backup/nested/excluded.tmp.txt
docker exec "$container" test ! -e /out/backup/nested/unmatched.log
