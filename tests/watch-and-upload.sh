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
printf '%s\n' 'existing payload' >"$watch_dir/nested/existing file.txt"
touch "$watch_dir/nested/existing.tmp.txt" "$watch_dir/nested/existing.log"
docker run --detach --init --name "$container" \
    --mount "type=bind,src=$watch_dir,dst=/watch,readonly" \
    -e RCLONE_REMOTE=:local:/out -e S3_PREFIX=backup -e UPLOAD_DELAY=0 -e MAX_PARALLEL=1 \
    -e UPLOAD_EXISTING_FILES=true -e WATCH_INCLUDE=$'*.txt\n*.csv' -e WATCH_EXCLUDE='*.tmp.txt' \
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
    "/watch/nested/file name.csv" "/out/backup/nested/file name.csv" &&
    docker exec "$1" cmp -s \
    "/watch/nested/existing file.txt" "/out/backup/nested/existing file.txt"; do
    sleep 0.5
  done
' _ "$container"
docker exec "$container" test ! -e /out/backup/nested/existing.tmp.txt
docker exec "$container" test ! -e /out/backup/nested/existing.log
docker exec "$container" test ! -e /out/backup/nested/excluded.tmp.txt
docker exec "$container" test ! -e /out/backup/nested/unmatched.log

docker rm -f "$container" >/dev/null
# Hold the scan open while a live write is processed.
mkdir "$watch_dir/test-bin"
cat >"$watch_dir/test-bin/find" <<'WRAPPER'
#!/bin/sh
printf '%s\n' 'changed during scan' >/watch/during-scan.txt
while [ ! -e /watch/release-scan ]; do
    sleep 0.1
done
printf '%s\0' /watch/during-scan.txt
exit 1
WRAPPER
chmod +x "$watch_dir/test-bin/find"
printf '%s\n' 'initial contents' >"$watch_dir/during-scan.txt"
docker run --detach --init --name "$container" \
    --mount "type=bind,src=$watch_dir,dst=/watch" \
    -e PATH=/watch/test-bin:/usr/local/bin:/usr/bin:/bin \
    -e DRY_RUN=true -e UPLOAD_EXISTING_FILES=true -e UPLOAD_DELAY=1 -e MAX_PARALLEL=1 \
    -e WATCH_INCLUDE='*.txt' \
    "$image"

await_log() {
    timeout 20 bash -c '
      until docker logs "$1" 2>&1 | grep -F "$2" >/dev/null; do
        sleep 0.2
      done
    ' _ "$container" "$1"
}

await_log 'Simulation completed for: during-scan.txt'
touch "$watch_dir/release-scan"
await_log 'ERROR: Startup scan failed for /watch'
printf '%s\n' barrier >"$watch_dir/barrier.txt"
await_log 'Simulation completed for: barrier.txt'
test "$(docker logs "$container" 2>&1 | grep -cF 'Will be uploaded: during-scan.txt')" -eq 1

printf '%s\n' 'changed after scan' >"$watch_dir/during-scan.txt"
printf '%s\n' barrier >"$watch_dir/final-barrier.txt"
await_log 'Simulation completed for: final-barrier.txt'
test "$(docker logs "$container" 2>&1 | grep -cF 'Will be uploaded: during-scan.txt')" -eq 2
