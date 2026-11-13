SHELL := /bin/bash
IMAGE ?= sb-manager-test:local
PLATFORM ?= linux/arm64

.PHONY: test test-image test-docker test-interactive test-e2e test-core-update test-core-update-live test-systemd test-install test-bootstrap test-acme-local test-acme-staging assets
assets:
	bash scripts/prepare-test-assets
test-image: assets
	docker build --platform $(PLATFORM) -f tests/docker/Dockerfile -t $(IMAGE) .
test:
	docker run --rm --init --network bridge -v "$(CURDIR):/workspace:ro" $(IMAGE) bash tests/unit.sh
	docker run --rm --init --network none -v "$(CURDIR):/workspace:ro" $(IMAGE) bash tests/bootstrap.sh
test-interactive:
	docker run --rm --init --network none -v "$(CURDIR):/workspace:ro" $(IMAGE) python3 tests/interactive.py
test-core-update:
	docker run --rm --init --network none -v "$(CURDIR):/workspace:ro" $(IMAGE) bash tests/core-update.sh
test-core-update-live:
	docker run --rm --init -v "$(CURDIR):/workspace:ro" $(IMAGE) bash tests/core-update-live.sh
test-docker:
	bash tests/docker/matrix.sh
test-e2e:
	SB_TEST_IMAGE=$(IMAGE) python3 tests/e2e.py
	docker run --rm --init --network none -v "$(CURDIR):/workspace:ro" $(IMAGE) bash tests/routes.sh
	docker run --rm --init --network none -v "$(CURDIR):/workspace:ro" $(IMAGE) bash tests/transaction-recovery.sh
test-systemd:
	SB_TEST_IMAGE=$(IMAGE) bash tests/systemd.sh
test-install:
	SB_TEST_INSTALLER=1 SB_TEST_IMAGE=$(IMAGE) bash tests/systemd.sh
test-bootstrap:
	SB_TEST_INSTALLER=1 SB_TEST_BOOTSTRAP=1 SB_TEST_IMAGE=$(IMAGE) bash tests/systemd.sh
test-acme-local:
	SB_TEST_IMAGE=$(IMAGE) bash tests/acme-local.sh
test-acme-staging:
	bash tests/acme-staging.sh
