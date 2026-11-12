# Project Guidelines

`rclone-watch` is a Bash file watcher distributed as a container image via GHCR.

## Formatting and commits

- Run `make fmt` before every commit and include the resulting formatting changes.
- The target uses shfmt for Bash and Prettier for Markdown and YAML. It requires Go and Node.js with npm.
- Keep the environment variable documentation and Compose example in `README.md` aligned with the implementation.
