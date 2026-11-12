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

1. Check the existing release tags and choose the next unused version. Update the image tag in the deployment examples and pull commands in both READMEs, and document any configuration changes included in the release.
2. Run `make fmt`, commit the release changes, and push the intended release commit to `main`.
3. From the checkout of that commit, publish a stable GitHub Release. Replace `vX.Y.Z` with the chosen version.

   ```sh
   release_tag=vX.Y.Z
   gh release create "$release_tag" --target "$(git rev-parse HEAD)" --title "$release_tag" --generate-notes
   ```

4. Wait for the **Container image** workflow to pass. It builds and tests the image before publishing the versioned tag and updating `latest` in GHCR.
5. Verify that both GHCR tags resolve to the same digest. Pin deployments to the versioned tag.

   ```sh
   docker buildx imagetools inspect "ghcr.io/ldsink/rclone-watch:$release_tag"
   docker buildx imagetools inspect ghcr.io/ldsink/rclone-watch:latest
   ```
