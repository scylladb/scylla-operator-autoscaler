all: build

SHELL := /bin/bash -euEo pipefail

IMAGE_TAG ?= latest
IMAGE_REPO ?= scyllazimnx
IMAGE_PREFIX ?= scylla-operator-autoscaler-

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS         ?= "crd:allowDangerousTypes=true"

GIT_TAG ?=$(shell git describe --long --tags --abbrev=7 --match 'v[0-9]*' || echo 'v0.0.0-unknown')
GIT_COMMIT ?=$(shell git rev-parse --short "HEAD^{commit}" 2>/dev/null)
GIT_TREE_STATE ?=$(shell ( ( [ ! -d ".git/" ] || git diff --quiet ) && echo 'clean' ) || echo 'dirty')

GO ?=go
GOPATH ?=$(shell $(GO) env GOPATH)
GOOS ?=$(shell $(GO) env GOOS)
GOEXE ?=$(shell $(GO) env GOEXE)
GOFMT ?=gofmt
GOFMT_FLAGS ?=-s -l

GO_PACKAGE ?=$(shell $(GO) list -m -f '{{ .Path }}' || echo 'no_package_detected')
GO_PACKAGES ?=./...
GO_MOD_FLAGS ?=

go_packages_dirs :=$(shell $(GO) list -f '{{ .Dir }}' $(GO_PACKAGES) || echo 'no_package_dir_detected')
GO_BUILD_PACKAGES ?=./cmd/...
GO_BUILD_PACKAGES_EXPANDED ?=$(shell $(GO) list $(GO_BUILD_PACKAGES))
go_build_binaries =$(notdir $(GO_BUILD_PACKAGES_EXPANDED))
GO_BUILD_FLAGS ?=-trimpath
GO_BUILD_BINDIR ?= bin
GO_LD_EXTRA_FLAGS ?=
GO_TEST_PACKAGES :=./pkg/... # ./cmd/...
GO_TEST_FLAGS ?=-race
GO_TEST_COUNT ?=
GO_TEST_EXTRA_FLAGS ?=
GO_TEST_ARGS ?=
GO_TEST_EXTRA_ARGS ?=

define version-ldflags
-X $(1).versionFromGit="$(GIT_TAG)" \
-X $(1).commitFromGit="$(GIT_COMMIT)" \
-X $(1).gitTreeState="$(GIT_TREE_STATE)" \
-X $(1).buildDate="$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')"
endef
GO_LD_FLAGS ?=-ldflags "$(call version-ldflags,$(GO_PACKAGE)/pkg/version) $(GO_LD_EXTRA_FLAGS)"

export GOVERSION :=$(shell go version)
export KUBEBUILDER_ASSETS :=$(GOPATH)/bin
export PATH :=$(GOPATH)/bin:$(PATH):

# $1 - package name
define build-package
	$(if $(GO_BUILD_BINDIR),mkdir -p '$(GO_BUILD_BINDIR)',)
	$(strip CGO_ENABLED=0 $(GO) build $(GO_BUILD_FLAGS) $(GO_LD_FLAGS) \
		$(if $(GO_BUILD_BINDIR),-o '$(GO_BUILD_BINDIR)/$(notdir $(1))$(GOEXE)',) \
	$(1))

endef

# We need to build each package separately so go build creates appropriate binaries
build:
	$(if $(strip $(GO_BUILD_PACKAGES_EXPANDED)),,$(error no packages to build: GO_BUILD_PACKAGES_EXPANDED var is empty))
	$(foreach package,$(GO_BUILD_PACKAGES_EXPANDED),$(call build-package,$(package)))
.PHONY: build

clean:
	$(foreach bin,$(go_build_binaries),$(RM) $(GO_BUILD_BINDIR)/$(bin))
.PHONY: clean

verify-govet:
	$(GO) vet $(GO_MOD_FLAGS) $(GO_PACKAGES)
.PHONY: verify-govet

verify-gofmt:
	$(info Running $(GOFMT) $(GOFMT_FLAGS))
	@output=$$( $(GOFMT) $(GOFMT_FLAGS) $(go_packages_dirs) ); \
	if [ -n "$${output}" ]; then \
		echo "$@ failed - please run \`make update-gofmt\` to fix following files:"; \
		echo "$${output}"; \
		exit 1; \
	fi;
.PHONY: verify-gofmt

update-gofmt:
	$(info Running $(GOFMT) $(GOFMT_FLAGS) -w)
	@$(GOFMT) $(GOFMT_FLAGS) -w $(go_packages_dirs)
.PHONY: update-gofmt

# We need to force localle so different envs sort files the same way for recursive traversals
deps_diff :=LC_COLLATE=C diff --no-dereference -N

# $1 - temporary directory
define restore-deps
	ln -s $(abspath ./) "$(1)"/current
	cp -R -H ./ "$(1)"/updated
	$(RM) -r "$(1)"/updated/vendor
	cd "$(1)"/updated && $(GO) mod tidy && $(GO) mod vendor && $(GO) mod verify
	cd "$(1)" && $(deps_diff) -r {current,updated}/vendor/ > updated/deps.diff || true
endef

verify-deps: tmp_dir:=$(shell mktemp -d)
verify-deps:
	$(call restore-deps,$(tmp_dir))
	@echo $(deps_diff) "$(tmp_dir)"/{current,updated}/go.mod
	@     $(deps_diff) "$(tmp_dir)"/{current,updated}/go.mod || ( echo '`go.mod` content is incorrect - did you run `go mod tidy`?' && false )
	@echo $(deps_diff) "$(tmp_dir)"/{current,updated}/go.sum
	@     $(deps_diff) "$(tmp_dir)"/{current,updated}/go.sum || ( echo '`go.sum` content is incorrect - did you run `go mod tidy`?' && false )
	@echo $(deps_diff) '$(tmp_dir)'/{current,updated}/deps.diff
	@     $(deps_diff) '$(tmp_dir)'/{current,updated}/deps.diff || ( \
		echo "ERROR: Content of 'vendor/' directory doesn't match 'go.mod' configuration and the overrides in 'deps.diff'!" && \
		echo 'Did you run `go mod vendor`?' && \
		echo "If this is an intentional change (a carry patch) please update the 'deps.diff' using 'make update-deps-overrides'." && \
		false \
	)
.PHONY: verify-deps

update-deps-overrides: tmp_dir:=$(shell mktemp -d)
update-deps-overrides:
	$(call restore-deps,$(tmp_dir))
	cp "$(tmp_dir)"/{updated,current}/deps.diff
.PHONY: update-deps-overrides

verify: verify-govet verify-gofmt
.PHONY: verify

update: update-gofmt
.PHONY: update

test-unit:
	$(GO) test $(GO_TEST_COUNT) $(GO_TEST_FLAGS) $(GO_TEST_EXTRA_FLAGS) $(GO_TEST_PACKAGES) $(if $(GO_TEST_ARGS)$(GO_TEST_EXTRA_ARGS),-args $(GO_TEST_ARGS) $(GO_TEST_EXTRA_ARGS))
.PHONY: test-unit

test: test-unit
.PHONY: test

# Install CRDs into a cluster
install: manifests
	kustomize build config/crd | kubectl apply -f -
.PHONY: install

# Uninstall CRDs from a cluster
uninstall: manifests
	kustomize build config/crd | kubectl delete -f -
.PHONY: uninstall

# Deploy operator_autoscaler in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests
	kustomize build config/default | kubectl apply -f -
.PHONY: deploy

# $1 - binary name
define kustomize-subst
	cd config/$(1) && kustomize edit set image $(1)=$(IMAGE_REPO)/$(IMAGE_PREFIX)$(1):$(IMAGE_TAG)

endef

# Generate manifests e.g. CRD, RBAC etc.
manifests:
	$(foreach bin,$(go_build_binaries),$(call kustomize-subst,$(bin)))
	controller-gen $(CRD_OPTIONS) paths="$(GO_PACKAGES)" output:crd:artifacts:config=config/crd/bases
.PHONY: manifests

define image-ref

endef

# $1 - binary name
define build-image
	docker build -t $(IMAGE_REPO)/$(IMAGE_PREFIX)$(1):$(IMAGE_TAG) --build-arg EXEC_ARG=$(1) .

endef

images:
	$(foreach bin,$(go_build_binaries),$(call build-image,$(bin)))
.PHONY: images

# $1 - binary name
define docker-push
	docker push $(IMAGE_REPO)/$(IMAGE_PREFIX)$(1):$(IMAGE_TAG)

endef

push-images:
	$(foreach bin,$(go_build_binaries),$(call docker-push,$(bin)))
.PHONY: push-images
