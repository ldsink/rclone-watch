.PHONY: fmt

fmt:
	@go run mvdan.cc/sh/v3/cmd/shfmt@v3.12.0 -i 4 -w rclone-watch.sh tests
	@npx --yes prettier@3.6.2 --write --print-width 150 "*.md" "*.{yml,yaml}" ".github/workflows/*.{yml,yaml}"
