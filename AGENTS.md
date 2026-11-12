# Project Guidelines

`rclone-watch` is a Bash file watcher distributed as a container image via GHCR.

## Formatting and commits

- Put each independent change in its own self-contained commit, including any related documentation, configuration, and tests.
- Prefer English for code comments and commit messages.
- Run `make fmt` before every commit and include the resulting formatting changes.
- The target uses shfmt for Bash and Prettier for Markdown and YAML. It requires Go and Node.js with npm.
- Keep the environment variable documentation and Compose example in `README.md` and `README.zh-CN.md` aligned with the implementation.

## Releases

Git tags define the version and follow the `vMAJOR.MINOR.PATCH` format. Increment the major version for breaking changes, the minor version for backward-compatible features, and the patch version for backward-compatible fixes.

Once the release workflow is on `main`, select a commit and publish a stable release in GitHub Releases, or run the following command from this repository to publish `v0.0.1`.

```sh
gh release create v0.0.1 --target main --title v0.0.1 --generate-notes
```

GitHub Actions builds and tests the image only when a stable release is published. After the tests pass, the workflow pushes the image under the matching Git tag and updates `latest`. Pin deployments to a published version tag.
