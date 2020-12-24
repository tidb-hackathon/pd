PD_PKG := github.com/tikv/pd

TEST_PKGS := $(shell find . -iname "*_test.go" -exec dirname {} \; | \
                     sort -u | sed -e "s/^\./github.com\/tikv\/pd/")
INTEGRATION_TEST_PKGS := $(shell find . -iname "*_test.go" -exec dirname {} \; | \
                     sort -u | sed -e "s/^\./github.com\/tikv\/pd/" | grep -E "tests")
BASIC_TEST_PKGS := $(filter-out $(INTEGRATION_TEST_PKGS),$(TEST_PKGS))

PACKAGES := go list ./...
PACKAGE_DIRECTORIES := $(PACKAGES) | sed 's|$(PD_PKG)/||'
GOCHECKER := awk '{ print } END { if (NR > 0) { exit 1 } }'
OVERALLS := overalls

GO_TOOLS_BIN_PATH := $(shell pwd)/.tools/bin
PATH := $(GO_TOOLS_BIN_PATH):$(PATH)
SHELL := env PATH='$(PATH)' GOBIN='$(GO_TOOLS_BIN_PATH)' /bin/bash

FAILPOINT_ENABLE  := $$(find $$PWD/ -type d | grep -vE "\.git" | xargs failpoint-ctl enable)
FAILPOINT_DISABLE := $$(find $$PWD/ -type d | grep -vE "\.git" | xargs failpoint-ctl disable)

DEADLOCK_ENABLE := $$(\
						find . -name "*.go" \
						| xargs -n 1 sed -i.bak 's/sync\.RWMutex/deadlock.RWMutex/;s/sync\.Mutex/deadlock.Mutex/' && \
						find . -name "*.go" | xargs grep -lE "(deadlock\.RWMutex|deadlock\.Mutex)" \
						| xargs goimports -w)
DEADLOCK_DISABLE := $$(\
						find . -name "*.go" \
						| xargs -n 1 sed -i.bak 's/deadlock\.RWMutex/sync.RWMutex/;s/deadlock\.Mutex/sync.Mutex/' && \
						find . -name "*.go" | xargs grep -lE "(sync\.RWMutex|sync\.Mutex)" \
						| xargs goimports -w && \
						find . -name "*.bak" | xargs rm && \
						go mod tidy)

BUILD_FLAGS ?=
BUILD_TAGS ?=
BUILD_CGO_ENABLED := 0
PD_EDITION ?= Community

# Ensure PD_EDITION is set to Community or Enterprise before running build process.
ifneq "$(PD_EDITION)" "Community"
ifneq "$(PD_EDITION)" "Enterprise"
  $(error Please set the correct environment variable PD_EDITION before running `make`)
endif
endif

ifneq ($(SWAGGER), 0)
	BUILD_TAGS += swagger_server
endif

ifeq ($(DASHBOARD), 0)
	BUILD_TAGS += without_dashboard
else
	BUILD_CGO_ENABLED := 1
endif

ifeq ("$(WITH_RACE)", "1")
	BUILD_FLAGS += -race
	BUILD_CGO_ENABLED := 1
endif

LDFLAGS += -X "$(PD_PKG)/server/versioninfo.PDReleaseVersion=$(shell git describe --tags --dirty --always)"
LDFLAGS += -X "$(PD_PKG)/server/versioninfo.PDBuildTS=$(shell date -u '+%Y-%m-%d %I:%M:%S')"
LDFLAGS += -X "$(PD_PKG)/server/versioninfo.PDGitHash=$(shell git rev-parse HEAD)"
LDFLAGS += -X "$(PD_PKG)/server/versioninfo.PDGitBranch=$(shell git rev-parse --abbrev-ref HEAD)"
LDFLAGS += -X "$(PD_PKG)/server/versioninfo.PDEdition=$(PD_EDITION)"

ifneq ($(DASHBOARD), 0)
	# Note: LDFLAGS must be evaluated lazily for these scripts to work correctly
	LDFLAGS += -X "github.com/pingcap-incubator/tidb-dashboard/pkg/utils/version.InternalVersion=$(shell scripts/describe-dashboard.sh internal-version)"
	LDFLAGS += -X "github.com/pingcap-incubator/tidb-dashboard/pkg/utils/version.Standalone=No"
	LDFLAGS += -X "github.com/pingcap-incubator/tidb-dashboard/pkg/utils/version.PDVersion=$(shell git describe --tags --dirty --always)"
	LDFLAGS += -X "github.com/pingcap-incubator/tidb-dashboard/pkg/utils/version.BuildTime=$(shell date -u '+%Y-%m-%d %I:%M:%S')"
	LDFLAGS += -X "github.com/pingcap-incubator/tidb-dashboard/pkg/utils/version.BuildGitHash=$(shell scripts/describe-dashboard.sh git-hash)"
endif

GOVER_MAJOR := $(shell go version | sed -E -e "s/.*go([0-9]+)[.]([0-9]+).*/\1/")
GOVER_MINOR := $(shell go version | sed -E -e "s/.*go([0-9]+)[.]([0-9]+).*/\2/")
GO111 := $(shell [ $(GOVER_MAJOR) -gt 1 ] || [ $(GOVER_MAJOR) -eq 1 ] && [ $(GOVER_MINOR) -ge 11 ]; echo $$?)
ifeq ($(GO111), 1)
  $(error "go below 1.11 does not support modules")
endif

default: build

all: dev

dev: build check tools test

ci: build check basic-test

build: pd-server pd-ctl pd-recover

tools: pd-tso-bench pd-analysis pd-heartbeat-bench

PD_SERVER_DEP :=
ifneq ($(SWAGGER), 0)
	PD_SERVER_DEP += swagger-spec
endif
PD_SERVER_DEP += dashboard-ui

pd-server: export GO111MODULE=on
pd-server: export GOPRIVATE=github.com/tidb-hackathon/*
pd-server: ${PD_SERVER_DEP}
	CGO_ENABLED=$(BUILD_CGO_ENABLED) go build $(BUILD_FLAGS) -gcflags '$(GCFLAGS)' -ldflags '$(LDFLAGS)' -tags "$(BUILD_TAGS)" -o bin/pd-server cmd/pd-server/main.go

pd-server-basic: export GO111MODULE=on
pd-server-basic: export GOPRIVATE=github.com/tidb-hackathon/*
pd-server-basic:
	SWAGGER=0 DASHBOARD=0 make pd-server

# dependent
install-go-tools: export GO111MODULE=on
install-go-tools:
	@mkdir -p $(GO_TOOLS_BIN_PATH)
	@which golangci-lint >/dev/null 2>&1 || curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(GO_TOOLS_BIN_PATH) v1.27.0
	@grep '_' tools.go | sed 's/"//g' | awk '{print $$2}' | xargs go install

swagger-spec: export GO111MODULE=on
swagger-spec: install-go-tools
	go mod vendor
	swag init --parseVendor -generalInfo server/api/router.go --exclude vendor/github.com/pingcap-incubator/tidb-dashboard --output docs/swagger
	go mod tidy
	rm -rf vendor

dashboard-ui: export GO111MODULE=on
dashboard-ui:
	./scripts/embed-dashboard-ui.sh

# Tools
pd-ctl: export GO111MODULE=on
pd-ctl:
	CGO_ENABLED=0 go build -gcflags '$(GCFLAGS)' -ldflags '$(LDFLAGS)' -o bin/pd-ctl tools/pd-ctl/main.go
pd-tso-bench: export GO111MODULE=on
pd-tso-bench:
	CGO_ENABLED=0 go build -o bin/pd-tso-bench tools/pd-tso-bench/main.go
pd-recover: export GO111MODULE=on
pd-recover:
	CGO_ENABLED=0 go build -gcflags '$(GCFLAGS)' -ldflags '$(LDFLAGS)' -o bin/pd-recover tools/pd-recover/main.go
pd-analysis: export GO111MODULE=on
pd-analysis:
	CGO_ENABLED=0 go build -gcflags '$(GCFLAGS)' -ldflags '$(LDFLAGS)' -o bin/pd-analysis tools/pd-analysis/main.go
pd-heartbeat-bench: export GO111MODULE=on
pd-heartbeat-bench:
	CGO_ENABLED=0 go build -gcflags '$(GCFLAGS)' -ldflags '$(LDFLAGS)' -o bin/pd-heartbeat-bench tools/pd-heartbeat-bench/main.go

test: install-go-tools
	# testing...
	@$(DEADLOCK_ENABLE)
	@$(FAILPOINT_ENABLE)
	CGO_ENABLED=1 GO111MODULE=on go test -race -cover $(TEST_PKGS) || { $(FAILPOINT_DISABLE); $(DEADLOCK_DISABLE); exit 1; }
	@$(FAILPOINT_DISABLE)
	@$(DEADLOCK_DISABLE)

basic-test:
	@$(FAILPOINT_ENABLE)
	GO111MODULE=on go test $(BASIC_TEST_PKGS) || { $(FAILPOINT_DISABLE); exit 1; }
	@$(FAILPOINT_DISABLE)

check: install-go-tools check-all check-plugin errdoc

check-all: static lint tidy
	@echo "checking"

check-plugin:
	@echo "checking plugin"
	cd ./plugin/scheduler_example && make evictLeaderPlugin.so && rm evictLeaderPlugin.so

static: export GO111MODULE=on
static:
	@ # Not running vet and fmt through metalinter becauase it ends up looking at vendor
	gofmt -s -l -d $$($(PACKAGE_DIRECTORIES)) 2>&1 | $(GOCHECKER)
	golangci-lint run $$($(PACKAGE_DIRECTORIES))

lint:
	@echo "linting"
	revive -formatter friendly -config revive.toml $$($(PACKAGES))

tidy:
	@echo "go mod tidy"
	GO111MODULE=on go mod tidy
	git diff --quiet go.mod go.sum

errdoc: install-go-tools
	@echo "generator errors.toml"
	./scripts/check-errdoc.sh

travis_coverage: export GO111MODULE=on
travis_coverage:
ifeq ("$(TRAVIS_COVERAGE)", "1")
	@$(FAILPOINT_ENABLE)
	CGO_ENABLED=1 $(OVERALLS) -concurrency=8 -project=github.com/tikv/pd -covermode=count -ignore='.git,vendor' -- -coverpkg=./... || { $(FAILPOINT_DISABLE); exit 1; }
	@$(FAILPOINT_DISABLE)
else
	@echo "coverage only runs in travis."
endif

simulator: export GO111MODULE=on
simulator:
	CGO_ENABLED=0 go build -o bin/pd-simulator tools/pd-simulator/main.go

regions-dump: export GO111MODULE=on
regions-dump:
	CGO_ENABLED=0 go build -o bin/regions-dump tools/regions-dump/main.go

clean-test:
	rm -rf /tmp/test_pd*
	rm -rf /tmp/pd-tests*
	rm -rf /tmp/test_etcd*

deadlock-enable: install-go-tools
	@$(DEADLOCK_ENABLE)

deadlock-disable:
	@$(DEADLOCK_DISABLE)

failpoint-enable: install-go-tools
	# Converting failpoints...
	@$(FAILPOINT_ENABLE)

failpoint-disable:
	# Restoring failpoints...
	@$(FAILPOINT_DISABLE)

.PHONY: all ci vendor clean-test tidy
