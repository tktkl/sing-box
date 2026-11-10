#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
mkdir -p .test-output
[[ -f tests/docker/images.lock.json ]] || { printf 'Resolve image digests first: python3 tests/docker/lock-images.py\n' >&2; exit 1; }
status=0
while IFS=$'\t' read -r name image; do
    for arch in ${SB_TEST_ARCHES:-arm64 amd64}; do
        tag="sb-manager-matrix:$name-$arch"
        log=".test-output/$name-$arch.log"
        printf 'Testing %s / %s\n' "$name" "$arch"
        if docker build --platform "linux/$arch" --build-arg "BASE=$image" -f tests/docker/matrix.Dockerfile -t "$tag" . >"$log" 2>&1 &&
           docker run --rm --init --platform "linux/$arch" -v "$PWD:/workspace:ro" "$tag" bash tests/unit.sh >>"$log" 2>&1; then
            printf 'PASS %s / %s\n' "$name" "$arch"
        else
            status=1; printf 'FAIL %s / %s (see %s)\n' "$name" "$arch" "$log" >&2
        fi
    done
done < <(jq -r 'to_entries[]|[.key,.value]|@tsv' tests/docker/images.lock.json)
exit "$status"
