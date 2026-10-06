.PHONY: all lint test scan

all: lint test

# shellcheck, Python syntax, executable bits
lint:
	@ci/lint.sh

# every tool's test.sh (on macOS also under /bin/bash 3.2)
test:
	@ci/run-tests.sh

# pre-push gate: gitleaks + pattern grep over origin/master..HEAD
scan:
	@ci/scan.sh
