# Version derivation.
#
# Tag format: v<MAJOR>.<MINOR>.<PATCH> with an optional pre-release
# suffix, e.g. v1.1.0 or v1.1.0-rc1.
#
# The policy version is the single source of truth: the tag, the RPM
# Version field and policy_module(rancher, X) in policy/rancher.te all
# carry the same value. This mirrors container-selinux and the SUSE
# selinux-policy packaging scheme.
#
#   v1.1.0      -> RPM 1.1.0-1.<disttag>
#   v1.1.0-rc1  -> RPM 1.1.0~rc1-1.<disttag>   (sorts before 1.1.0)
#   untagged    -> RPM 0.0.0-0.<date>git<sha>  (sorts below any release)
#
# The release channel is NOT encoded in the tag. It is a distribution
# concern (which bucket / signing key) and is set by CI: `production'
# on a tag push, `testing' otherwise.

COMMIT := $(shell git rev-parse --short=8 HEAD)
DIRTY  := $(shell test -n "$$(git status --porcelain --untracked-files=no)" && echo .dirty)
DATE   := $(shell date -u +%Y%m%d)

TAG ?= $(GITHUB_TAG)
ifeq ($(strip $(TAG)),)
	TAG := $(shell git tag -l --points-at HEAD | head -n 1)
endif

VERSION_REGEX := ^v([0-9]+\.[0-9]+\.[0-9]+)(-(alpha|beta|rc)[0-9]+)?$$
TAG_MATCHES   := $(shell echo "$(TAG)" | grep -Eq '$(VERSION_REGEX)' && echo yes)

ifeq ($(TAG_MATCHES)$(DIRTY),yes)
	# Clean worktree on a well-formed tag: a real release.
	RPM_VERSION := $(shell echo "$(TAG)" | sed -E 's/^v//; s/-/~/')
	RPM_RELEASE ?= 1
	RPM_CHANNEL ?= production
	VERSION     := $(TAG)
else
	# Untagged, malformed tag, or dirty worktree: a snapshot.
	RPM_VERSION := 0.0.0
	RPM_RELEASE := 0.$(DATE)git$(COMMIT)$(subst .,,$(DIRTY))
	RPM_CHANNEL := testing
	VERSION     := v0.0.0-$(DATE)git$(COMMIT)$(DIRTY)
endif

# Strip any ~rc suffix: policy_module() only accepts a numeric version.
POLICY_VERSION := $(firstword $(subst ~, ,$(RPM_VERSION)))

# Version declared inside the single policy source.
TE_VERSION := $(shell sed -nE 's/^policy_module\(rancher, *([0-9.]+)\).*/\1/p' policy/rancher.te)
