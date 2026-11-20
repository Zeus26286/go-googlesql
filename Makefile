GOOGLESQL_WASM_REPO     ?= goccy/googlesql-wasm
GOOGLESQL_WASM_VERSION  ?= v0.3.1
GOOGLESQL_WASM_WORKFLOW ?= goccy/googlesql-wasm/.github/workflows/build.yml

BRIDGE_ASSET     := googlesql_wasm2go.go
BRIDGE_FILE      := googlesql.go
RELEASE_URL       = https://github.com/$(GOOGLESQL_WASM_REPO)/releases/download/$(GOOGLESQL_WASM_VERSION)
ATTESTATION_API   = https://api.github.com/repos/$(GOOGLESQL_WASM_REPO)/attestations

.PHONY: googlesql download verify patch verify-patched test

## googlesql: refresh the wasm2go bridge from the upstream release,
## verify its GitHub artifact attestation, then apply this fork's
## local patches. Default to running this whenever
## GOOGLESQL_WASM_VERSION bumps.
googlesql: download verify patch

## download: fetch the wasm2go-runtime bridge from the upstream
## release and drop it in place at $(BRIDGE_FILE). The release
## publishes it as $(BRIDGE_ASSET); the rename is purely cosmetic
## (gh attestation verify matches by content digest).
download:
	curl -fSL --proto '=https' --tlsv1.2 -o $(BRIDGE_FILE) $(RELEASE_URL)/$(BRIDGE_ASSET)

## verify: confirm $(BRIDGE_FILE) carries a valid GitHub artifact
## attestation signed by the upstream build.yml workflow. The
## attestation bundle is fetched anonymously from the public
## attestation API and verified offline via
## `gh attestation verify --bundle`. No GH access token is required.
verify:
	@set -eu; \
	tmpdir=$$(mktemp -d); \
	bundle=$$tmpdir/bundle.jsonl; \
	trap 'rm -rf $$tmpdir' EXIT; \
	digest=$$(shasum -a 256 $(BRIDGE_FILE) | awk '{print $$1}'); \
	echo "==> fetching attestation bundle for $(BRIDGE_FILE) (sha256:$$digest)"; \
	curl -fsSL --proto '=https' --tlsv1.2 \
	  "$(ATTESTATION_API)/sha256:$$digest" \
	  | jq -c '.attestations[].bundle' > $$bundle; \
	echo "==> verifying $(BRIDGE_FILE)"; \
	GH_TOKEN= GITHUB_TOKEN= gh attestation verify "$(BRIDGE_FILE)" \
	  -R $(GOOGLESQL_WASM_REPO) \
	  --bundle $$bundle \
	  --signer-workflow $(GOOGLESQL_WASM_WORKFLOW)

## patch: apply this fork's local patches (patches/*.patch) to the
## verified upstream $(BRIDGE_FILE). Fails if a patch no longer applies
## to a new upstream release.
patch:
	@set -eu; \
	for p in patches/*.patch; do \
	  echo "==> applying $$p"; \
	  patch --forward --batch $(BRIDGE_FILE) < "$$p"; \
	done

## verify-patched: verify the committed, patched $(BRIDGE_FILE) by
## reverting patches/*.patch on a copy and checking the copy's upstream
## attestation. This keeps the provenance check meaningful while the
## fork carries local changes.
verify-patched:
	@set -eu; \
	tmpdir=$$(mktemp -d); \
	copy=$$tmpdir/$(BRIDGE_FILE); \
	trap 'rm -f "$$copy" "$$copy.orig" "$$copy.rej"; rmdir "$$tmpdir"' EXIT; \
	cp $(BRIDGE_FILE) "$$copy"; \
	for p in $$(ls -r patches/*.patch); do \
	  echo "==> reverting $$p"; \
	  patch --reverse --batch "$$copy" < "$$p"; \
	done; \
	$(MAKE) --no-print-directory verify BRIDGE_FILE="$$copy"

## test: run the Go test suite.
test:
	go test ./...
