SHELL := /bin/bash
IMAGE ?= sb-manager-test:local
PLATFORM ?= linux/arm64

.PHONY: test test-image test-docker test-e2e test-systemd test-acme-local test-acme-staging assets
assets:
	bash scripts/prepare-test-assets
test-image: assets
	docker build --platform $(PLATFORM) -f tests/docker/Dockerfile -t $(IMAGE) .
test:
	docker run --rm --init --network bridge -v "$(CURDIR):/workspace:ro" $(IMAGE) bash tests/unit.sh
test-docker:
	bash tests/docker/matrix.sh
test-e2e:
	SB_TEST_IMAGE=$(IMAGE) python3 tests/e2e.py
	docker run --rm --init --network none -v "$(CURDIR):/workspace:ro" $(IMAGE) bash tests/routes.sh
test-systemd:
	SB_TEST_IMAGE=$(IMAGE) bash tests/systemd.sh
test-acme-local:
	SB_TEST_IMAGE=$(IMAGE) bash tests/acme-local.sh
test-acme-staging:
	bash tests/acme-staging.sh
