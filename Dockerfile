FROM alpine:3.23.8

RUN apk add --no-cache bash ca-certificates flock inotify-tools rclone
COPY LICENSE /usr/share/licenses/rclone-watch/LICENSE
COPY --chmod=755 rclone-watch.sh /usr/local/bin/rclone-watch

ENV WATCH_DIR=/watch
WORKDIR /watch

ENTRYPOINT ["/usr/local/bin/rclone-watch"]
