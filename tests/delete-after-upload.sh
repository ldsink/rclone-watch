#!/usr/bin/env bash
set -euo pipefail

image="${1:-rclone-watch:ci}"
work=$(mktemp -d)
container="rclone-watch-delete-test-$$"

cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

await() {
    local attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        if "$@"; then
            return 0
        fi
        sleep 0.2
    done
    docker logs "$container" >&2
    return 1
}

logged() {
    docker logs "$container" 2>&1 | grep -F "$1" >/dev/null
}

start() {
    local mount_mode="$1"
    shift
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$work/watch" "$work/out"
    mkdir "$work/watch" "$work/out"
    printf '%s\n' payload >"$work/watch/existing.txt"
    docker run --detach --init --name "$container" \
        --user "$(id -u):$(id -g)" \
        -v "$work/watch:/watch:$mount_mode" -v "$work/out:/out" \
        -e RCLONE_REMOTE=:local:/out/target/ -e S3_PREFIX=backup \
        -e UPLOAD_DELAY=0 -e MAX_PARALLEL=1 "$@" "$image" >/dev/null
    await logged "Watches established"
}

write_file() {
    printf '%s\n' payload >"$work/watch/$1"
}

start rw -e IGNORE_EXISTING_FILES=true
write_file 'default.txt'
await logged 'Uploaded successfully: default.txt'
cmp "$work/watch/default.txt" "$work/out/target/backup/default.txt"
test ! -e "$work/out/target/backup/existing.txt"

start rw -e DRY_RUN= -e DELETE_AFTER_UPLOAD= -e IGNORE_EXISTING_FILES=
await logged 'Uploaded successfully: existing.txt'
write_file 'empty-settings.txt'
await logged 'Uploaded successfully: empty-settings.txt'
cmp "$work/watch/empty-settings.txt" "$work/out/target/backup/empty-settings.txt"

start rw -e DRY_RUN=false -e DELETE_AFTER_UPLOAD=true
await logged 'Deleted local file: /watch/existing.txt'
test ! -e "$work/watch/existing.txt"
test "$(cat "$work/out/target/backup/existing.txt")" = payload
printf '%s\n' payload >"$work/source"
mv "$work/source" "$work/watch/file name.txt"
await logged 'Deleted local file: /watch/file name.txt'
test ! -e "$work/watch/file name.txt"
test "$(cat "$work/out/target/backup/file name.txt")" = payload

# A failed transfer stays in the queue until a new upload succeeds.
rm -rf "$work/out/target"
touch "$work/out/target"
write_file 'retry.txt'
await logged 'File added to queue: retry.txt'
test -f "$work/watch/retry.txt"
rm "$work/out/target"
mkdir -p "$work/out/target/backup"
cp -p "$work/watch/retry.txt" "$work/out/target/backup/retry.txt"
write_file 'first-trigger.txt'
await logged 'Keeping local file because rclone transferred nothing: /watch/retry.txt'
docker exec "$container" grep -Fx /watch/retry.txt /tmp/upload_queue.txt
test "$(cat "$work/watch/retry.txt")" = payload
rm "$work/out/target/backup/retry.txt"
write_file 'trigger.txt'
await logged 'File from queue uploaded successfully: retry.txt'
test ! -e "$work/watch/retry.txt"
test "$(cat "$work/out/target/backup/retry.txt")" = payload

start ro -e DELETE_AFTER_UPLOAD=true -e IGNORE_EXISTING_FILES=true
touch "$work/out/target"
write_file 'readonly.txt'
await logged 'File added to queue: readonly.txt'
rm "$work/out/target"
# Rewriting the queued file uploads it directly. The read-only bind keeps it present.
write_file 'readonly.txt'
await logged 'Upload succeeded but local deletion failed: /watch/readonly.txt'
cmp "$work/watch/readonly.txt" "$work/out/target/backup/readonly.txt"
write_file 'queue-barrier.txt'
await logged 'Uploaded successfully: queue-barrier.txt'
docker exec "$container" test ! -s /tmp/upload_queue.txt

for delete in true false; do
    start rw -e "DELETE_AFTER_UPLOAD=$delete" -e DRY_RUN=true -e RCLONE_REMOTE=
    await logged '[DRY-RUN] Will be uploaded: existing.txt -> cloud/backup/existing.txt'
    write_file 'pending.tmp'
    await logged 'Simulation completed for: pending.tmp'
    docker exec "$container" sh -c 'printf "%s\n" /watch/pending.tmp >/tmp/upload_queue.txt'
    write_file 'dry.txt'
    await logged '[DRY-RUN] Will be uploaded: dry.txt -> cloud/backup/dry.txt'
    await logged 'Simulation completed for: dry.txt'
    write_file 'next-dry.txt'
    await logged 'Simulation completed for: next-dry.txt'
    docker exec "$container" grep -Fx /watch/pending.tmp /tmp/upload_queue.txt
    test -f "$work/watch/pending.tmp"
    test -f "$work/watch/dry.txt"
    test -z "$(ls -A "$work/out")"
done

# Hold the real copy's return long enough to replace the uploaded source.
mkdir "$work/bin"
cat >"$work/bin/rclone" <<'WRAPPER'
#!/bin/bash
set -e
if [[ "$1" == copyto && -f /out/resume ]]; then
    exit 1
fi
/usr/bin/rclone "$@"
if [[ "$1" == copyto ]]; then
    echo 'Waiting to finish copy'
    until [[ -f /out/resume ]]; do
        sleep 0.1
    done
fi
WRAPPER
chmod +x "$work/bin/rclone"
start rw -e DELETE_AFTER_UPLOAD=true -e IGNORE_EXISTING_FILES=true -e WATCH_EXCLUDE='*.tmp' \
    -e PATH=/test-bin:/usr/local/bin:/usr/bin:/bin -v "$work/bin:/test-bin:ro"
write_file 'replaced.txt'
await logged 'Waiting to finish copy'
printf '%s\n' replacement >"$work/watch/replacement.tmp"
# Keep the replacement in place while checking the first upload.
docker exec "$container" bash -c 'mv /watch/replacement.tmp /watch/replaced.txt; touch /out/resume'
await logged 'Keeping local file because the source changed or could not be checked: /watch/replaced.txt'
test "$(cat "$work/watch/replaced.txt")" = replacement

start rw -e DELETE_AFTER_UPLOAD=true -e IGNORE_EXISTING_FILES=true \
    -e PATH=/test-bin:/usr/local/bin:/usr/bin:/bin -v "$work/bin:/test-bin:ro"
write_file 'unverified.txt'
await logged 'Waiting to finish copy'
printf '%s\n' 'different remote contents' >"$work/out/target/backup/unverified.txt"
touch "$work/out/resume"
await logged 'Keeping local file because remote contents could not be verified: /watch/unverified.txt'
test "$(cat "$work/watch/unverified.txt")" = payload

docker rm -f "$container" >/dev/null
for setting in DRY_RUN DELETE_AFTER_UPLOAD IGNORE_EXISTING_FILES; do
    status=0
    timeout 10 docker run --rm --name "$container" -e "$setting=yes" "$image" >"$work/invalid.log" 2>&1 || status=$?
    test "$status" -eq 1
    grep -F "$setting must be true or false" "$work/invalid.log"
done
