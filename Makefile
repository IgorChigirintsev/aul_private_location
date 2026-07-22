# Aul — top-level tasks. The one that matters for most people is `make selfhost`:
# build the whole stack from source and run your own server. No downloaded
# binary, so no OS code-signing certificate is needed — you build it yourself.
#
# Prerequisites: Go (https://go.dev/dl/) and Node/npm (https://nodejs.org/).
# Everything else (the SQLite database, the session secret) is provisioned on
# first run. See SELFHOST.md for the full guide.

.PHONY: selfhost selfhost-build selfhost-doctor

## selfhost: build the web + the pure-Go server & launcher, then run your own server
selfhost: selfhost-build
	@echo ""
	@echo ">> Starting your Aul server — the dashboard will open in your browser."
	@echo ">> To let remote family reach it (phones on cellular), in another"
	@echo ">> terminal run:  make selfhost-doctor   (it guides the Tailscale setup)."
	@echo ""
	./bin/aul-launcher

## selfhost-build: build everything without starting it (CI / packaging)
selfhost-build:
	@command -v go  >/dev/null || { echo "!! Go is required — https://go.dev/dl/"; exit 1; }
	@command -v npm >/dev/null || { echo "!! Node/npm is required — https://nodejs.org/"; exit 1; }
	$(MAKE) -C server web            # npm build → embed the web bundle into the server
	@mkdir -p bin
	cd server && CGO_ENABLED=0 go build -trimpath -o ../bin/aul          ./cmd/aul
	cd server && CGO_ENABLED=0 go build -trimpath -o ../bin/aul-launcher ./cmd/aul-launcher
	@echo ">> built bin/aul + bin/aul-launcher"

## selfhost-doctor: check Tailscale/Funnel reachability and print the exact next steps
selfhost-doctor:
	cd server && CGO_ENABLED=0 go run ./cmd/aul-launcher doctor
