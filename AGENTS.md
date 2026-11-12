# Project Guidelines

`rclone-watch` is a Bash file watcher distributed as a container image via GHCR.

## Formatting and commits

- Put each independent change in its own self-contained commit, including any related documentation, configuration, and tests.
- Prefer English for code comments and commit messages.
- Run `make fmt` before every commit and include the resulting formatting changes.
- The target uses shfmt for Bash and Prettier for Markdown and YAML. It requires Go and Node.js with npm.
- Keep the environment variable documentation and Compose example in `README.md` and `README.zh-CN.md` aligned with the implementation.
