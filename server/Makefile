# Aul server developer tasks.
# Most targets assume a local Postgres; `make db` starts one on :5433.

SHELL := /bin/bash
# The database `make run`/`make migrate` use — your real dev data.
DATABASE_URL ?= postgres://aul:aul@localhost:5433/aul?sslmode=disable
export DATABASE_URL

# Integration tests TRUNCATE every table, so they get their OWN throwaway
# database on a DIFFERENT port (`make db-test`) — never the dev one above.
# testutil refuses to run against DATABASE_URL for exactly this reason.
TEST_DATABASE_URL ?= postgres://aul:aul@localhost:5434/aul?sslmode=disable
export TEST_DATABASE_URL

.PHONY: help build run test test-integration test-all vet fmt fmt-check lint \
        vuln gosec sqlc sqlc-check vectors db db-stop db-test db-test-stop \
        migrate acceptance tidy ci

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Build the server binary to ./bin/aul
	go build -o bin/aul ./cmd/aul

run: ## Run the server (uses your env; see deploy/.env.example)
	go run ./cmd/aul

test: ## Unit tests (no DB)
	go test -short ./...

test-integration: ## Integration tests (needs TEST_DATABASE_URL — a THROWAWAY db: they TRUNCATE it); serialized
	go test -p 1 -tags=integration ./...

test-all: test test-integration ## All tests

vet: ## go vet
	go vet ./...

fmt: ## Format code
	gofmt -w $(shell find . -name '*.go' -not -path './internal/store/*')

fmt-check: ## Fail if code is not gofmt-clean
	@out=$$(gofmt -l $(shell find . -name '*.go' -not -path './internal/store/*')); \
	  if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

lint: ## golangci-lint (installs on demand)
	@command -v golangci-lint >/dev/null || go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.64.5
	golangci-lint run ./...

vuln: ## govulncheck
	@command -v govulncheck >/dev/null || go install golang.org/x/vuln/cmd/govulncheck@latest
	govulncheck ./...

gosec: ## gosec static security scan
	@command -v gosec >/dev/null || go install github.com/securego/gosec/v2/cmd/gosec@latest
	gosec -exclude-generated ./...

sqlc: ## Regenerate typed queries
	sqlc generate

sqlc-check: sqlc ## Fail if generated sqlc code is stale
	@git diff --exit-code -- internal/store || (echo "sqlc code is stale; run 'make sqlc'"; exit 1)

vectors: ## Regenerate cross-language crypto test vectors
	go test ./internal/crypto -run Vectors -update

db: ## Start a local Postgres on :5433 (your DEV data)
	docker run -d --name aul-pg-dev -e POSTGRES_USER=aul -e POSTGRES_PASSWORD=aul \
	  -e POSTGRES_DB=aul -p 5433:5432 postgres:16

db-test: ## Start a THROWAWAY Postgres on :5434 for integration tests (they wipe it)
	docker run -d --name aul-pg-test -e POSTGRES_USER=aul -e POSTGRES_PASSWORD=aul \
	  -e POSTGRES_DB=aul -p 5434:5432 postgres:16

db-test-stop: ## Stop and remove the throwaway test Postgres
	docker rm -f aul-pg-test

db-stop: ## Stop and remove the local Postgres
	docker rm -f aul-pg-dev

migrate: ## Apply migrations to DATABASE_URL
	go run ./cmd/aul & sleep 1; kill %1 2>/dev/null || true

acceptance: ## Run the Phase-1 acceptance scenario against a running server
	BASE_URL=$${BASE_URL:-http://localhost:8080} ../scripts/acceptance.sh

tidy: ## go mod tidy
	go mod tidy

ci: fmt-check vet sqlc-check test-all ## What CI runs

web: ## Build the web dashboard into the server's embedded assets
	cd ../web && npm ci && npm run build
	rm -rf cmd/aul/webdist/* && cp -r ../web/dist/* cmd/aul/webdist/
