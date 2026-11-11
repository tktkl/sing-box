#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
mkdir -p .test-output
[[ -f tests/docker/images.lock.json ]] || { printf 'Resolve image digests first: python3 tests/docker/lock-images.py\n' >&2; exit 1; }
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
output=".test-output/matrix/$run_id"
mkdir -p "$output"
: > "$output/results.ndjson"
source_commit=$(git rev-parse HEAD)
source_dirty=false
[[ -z $(git status --porcelain) ]] || source_dirty=true
save_report() {
    jq -s --arg commit "$source_commit" --argjson dirty "$source_dirty" --arg run "$run_id" \
       '{run_id:$run,source_commit:$commit,source_dirty:$dirty,results:.,passed:([.[]|select(.status=="passed")]|length),failed:([.[]|select(.status!="passed")]|length)}' \
       "$output/results.ndjson" > "$output/report.json.tmp"
    mv -f "$output/report.json.tmp" "$output/report.json"
}
trap 'save_report' EXIT
trap 'exit 130' INT TERM
status=0
tested=0
while IFS=$'\t' read -r name image; do
    if [[ -n ${SB_TEST_DISTROS:-} && " $SB_TEST_DISTROS " != *" $name "* ]]; then continue; fi
    for arch in ${SB_TEST_ARCHES:-arm64 amd64}; do
        [[ $arch == arm64 || $arch == amd64 ]] || { printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 2; }
        tag="sb-manager-matrix:$name-$arch"
        log="$output/$name-$arch.log"
        stage=build
        result=passed
        image_id=''
        started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf 'Testing %s / %s\n' "$name" "$arch"
        if docker build --platform "linux/$arch" --build-arg "BASE=$image" -f tests/docker/matrix.Dockerfile -t "$tag" . >"$log" 2>&1; then
            image_id=$(docker image inspect --format '{{.Id}}' "$tag")
            stage='test'
            if docker run --rm --init --platform "linux/$arch" --network none -v "$PWD:/workspace:ro" "$tag" bash tests/unit.sh >>"$log" 2>&1; then
                printf 'PASS %s / %s\n' "$name" "$arch"
            else result=failed; fi
        else
            result=failed
        fi
        if [[ $result != passed ]]; then status=1; printf 'FAIL %s / %s during %s (see %s)\n' "$name" "$arch" "$stage" "$log" >&2; fi
        jq -cn --arg distro "$name" --arg arch "$arch" --arg base "$image" --arg image "$image_id" \
           --arg started "$started" --arg status "$result" --arg stage "$stage" --arg log "$log" \
           '{distro:$distro,architecture:$arch,base_image:$base,test_image:$image,started_at:$started,status:$status,stage:$stage,log:$log}' >> "$output/results.ndjson"
        (( tested+=1 ))
        save_report
    done
done < <(jq -r 'to_entries[]|[.key,.value]|@tsv' tests/docker/images.lock.json)
(( tested>0 )) || { printf 'No selected distro/architecture was tested\n' >&2; exit 2; }
printf 'Report: %s/report.json\n' "$output"
exit "$status"
