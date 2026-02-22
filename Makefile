AWS_PROFILE ?= default

build:
	container build -t anthropic-proxy -f ./Containerfile .

test:
	swift test

coverage:
	swift test --enable-code-coverage

coverage-report: coverage
	@CODECOV=$$(swift test --enable-code-coverage --show-codecov-path 2>/dev/null) && \
	swift scripts/coverage-report.swift "$$CODECOV"

run:
	@eval "$$(aws configure export-credentials --profile $(AWS_PROFILE) --format env)" && \
	container run --rm -it \
		-p 8080:8080 \
		-e PROXY_API_KEY \
		-e AWS_ACCESS_KEY_ID \
		-e AWS_SECRET_ACCESS_KEY \
		-e AWS_SESSION_TOKEN \
		-e AWS_REGION="$$(aws configure get region --profile $(AWS_PROFILE) 2>/dev/null || echo us-east-1)" \
		anthropic-proxy

.PHONY: build test coverage coverage-report run
