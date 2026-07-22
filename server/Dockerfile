# syntax=docker/dockerfile:1

# ---- build ----
FROM golang:1.25-alpine AS build
WORKDIR /src
# Cache modules first.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
# Static, stripped binary. Migrations and web assets are embedded via embed.FS.
#
# The BuildKit cache mounts below are what keep this affordable on a tiny host
# (the free GCP e2-micro has 1 GB RAM). `COPY . .` is invalidated by ANY change —
# most often just the embedded web bundle — which without a persistent GOCACHE
# forces a cold recompile of the whole module every deploy. On the micro that
# thrashes swap for 20+ minutes and risks an OOM on the linker. With the build
# cache reused, a web-only change recompiles nothing Go and links in seconds.
# (For an even faster path that skips the host compile entirely, see
# deploy/push-prebuilt.sh — build the binary where there's RAM, ship it.)
ARG VERSION=dev
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOFLAGS=-mod=mod go build -trimpath \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o /out/aul ./cmd/aul

# ---- runtime ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/aul /aul
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/aul"]
