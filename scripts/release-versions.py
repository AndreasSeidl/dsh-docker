#!/usr/bin/env python3
"""Resolve supported release batches using all upstream tags and GHCR pages."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.error import HTTPError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen


VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


def version_key(version):
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError(f"not a release version: {version!r}")
    major, minor, patch, pre = match.groups()
    identifiers = []
    for part in pre.split(".") if pre else []:
        if part.isdigit() and len(part) > 1 and part.startswith("0"):
            raise ValueError(f"invalid numeric prerelease identifier: {version!r}")
        identifiers.append((0, int(part)) if part.isdigit() else (1, part))
    return (int(major), int(minor), int(patch), pre is None, tuple(identifiers))


def releases(tags, floor):
    return sorted({tag for tag in tags if VERSION.fullmatch(tag)
                   and version_key(tag) >= version_key(floor)}, key=version_key)


def pages(url, headers=None, missing_ok=False):
    """Follow registry/GitHub Link pagination, without leaking auth off-host."""
    origin = urlparse(url).netloc
    seen = set()
    while url:
        if url in seen or urlparse(url).netloc != origin or urlparse(url).scheme != "https":
            raise ValueError(f"unsafe or repeated pagination URL: {url}")
        seen.add(url)
        try:
            with urlopen(Request(url, headers=headers or {}), timeout=30) as response:
                data = json.load(response)
                link = response.headers.get("Link", "")
        except HTTPError as error:
            if missing_ok and error.code == 404 and len(seen) == 1:
                return
            raise
        yield data
        match = re.search(r'<([^>]+)>;\s*rel="?next"?', link)
        url = urljoin(url, match[1]) if match else None


def published_tags(repository):
    repository = repository.lower()
    auth = next(pages(f"https://ghcr.io/token?scope=repository:{repository}:pull"))
    headers = {"Authorization": f"Bearer {auth['token']}"}
    return {tag for page in pages(f"https://ghcr.io/v2/{repository}/tags/list?n=100",
                                 headers, missing_ok=True)
            for tag in page.get("tags", []) or []}


def upstream_tags():
    result = subprocess.run([
        "git", "ls-remote", "--refs", "--tags",
        "https://github.com/deepseek-ai/deepseek-harness.git", "refs/tags/dsh-v*",
    ], check=True, capture_output=True, text=True)
    return {line.split("refs/tags/dsh-v", 1)[1] for line in result.stdout.splitlines()}


def publish_active(repository):
    headers = {"Authorization": f"Bearer {os.environ['GH_TOKEN']}"}
    for status in ("in_progress", "queued", "waiting", "pending", "requested"):
        url = (f"https://api.github.com/repos/{repository}/actions/workflows/"
               f"docker-publish.yml/runs?status={status}&per_page=100")
        if any(page["workflow_runs"] for page in pages(url, headers)):
            return True
    return False


def select_versions(mode, upstream, published, floor):
    supported = releases(upstream, floor)
    # Only exact upstream release tags count: historical per-arch aliases can
    # themselves resemble valid prereleases (e.g. 0.1.5-alpha.1-amd64).
    existing = releases(set(published) & set(upstream), floor)
    if mode == "missing":
        selected = [version for version in supported if version not in published]
    elif mode == "all":
        selected = existing
    elif not mode:
        selected = supported[-1:]
    else:
        selected = mode.split()
        for version in selected:
            if version not in upstream or version_key(version) < version_key(floor):
                raise ValueError(f"not a supported upstream release: {version}")
        selected = sorted(set(selected), key=version_key)
    # Backfilling an older gap must never move :latest backwards.
    latest = max(existing + selected, key=version_key, default="")
    return selected, latest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    repository = os.environ["GITHUB_REPOSITORY"]
    floor = Path(".supported-version").read_text().strip()
    mode = args.version.lower() if args.version.lower() in ("all", "missing") else args.version
    published = published_tags(repository)
    upstream = upstream_tags()
    selected, latest = select_versions(mode, upstream, published, floor)
    if args.check and publish_active(repository):
        print("docker-publish is active or queued; defer until the next poll")
        selected = []
    if not selected and mode not in ("missing",):
        raise ValueError("no supported releases selected")
    # GitHub limits a matrix to 256 jobs (two architectures per release).
    if len(selected) > 128:
        if mode != "missing":
            raise ValueError("more than 128 releases; dispatch smaller explicit batches")
        selected = selected[:128]  # The next poll will pick up the remainder.
        latest = max(releases(published & upstream, floor) + selected, key=version_key)
    matrix = [{"version": version, "arch": arch, "runner": runner}
              for version in selected
              for arch, runner in (("amd64", "ubuntu-latest"), ("arm64", "ubuntu-24.04-arm"))]
    outputs = {"build_needed": str(bool(selected)).lower(), "versions": " ".join(selected),
               "latest": latest, "min_supported": floor, "matrix": json.dumps(matrix)}
    print(json.dumps(outputs, indent=2))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
