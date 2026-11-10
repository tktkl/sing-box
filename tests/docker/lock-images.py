"""Explicit maintainer operation: resolve and record official multiarch digests."""
import json
import pathlib
import subprocess

images = {}
for distro, version in [("debian", "12"), ("debian", "13"), ("ubuntu", "22.04"), ("ubuntu", "24.04"), ("ubuntu", "26.04")]:
    tag = f"mirror.gcr.io/library/{distro}:{version}"
    result = subprocess.run(["docker", "buildx", "imagetools", "inspect", tag, "--format", "{{json .Manifest}}"], text=True, capture_output=True, check=True)
    manifest = json.loads(result.stdout)
    images[f"{distro}-{version}"] = tag + "@" + manifest["digest"]
pathlib.Path(__file__).with_name("images.lock.json").write_text(json.dumps(images, indent=2) + "\n")
