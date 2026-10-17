import argparse
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


API_ROOT = "https://gitee.com/api/v5"
PLATFORMS = {
    "puro-darwin-arm64": "macOS arm64",
    "puro-darwin-x64": "macOS x64",
    "puro-windows-x64.exe": "Windows x64",
    "puro-windows-arm64.exe": "Windows arm64",
    "puro-linux-x64": "Linux x64",
    "puro-linux-arm64": "Linux arm64",
}


class PublishError(Exception):
    pass


class GiteeHTTPError(PublishError):
    def __init__(self, method, path, status):
        self.status = status
        super().__init__(f"Gitee {method} {path} returned HTTP {status}")


class DownloadRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, target):
        redirected = super().redirect_request(request, response, code, message, headers, target)
        if redirected is not None and urlsplit(request.full_url).netloc != urlsplit(target).netloc:
            redirected.remove_header("Authorization")
        return redirected


class Gitee:
    def __init__(self, repository, token):
        self.path = f"/repos/{repository}/releases"
        self.token = token
        self.opener = build_opener(DownloadRedirectHandler())

    def request(self, method, path, payload=None, content_type="application/json"):
        if payload is not None and content_type == "application/json":
            payload = json.dumps(payload).encode("utf-8")
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": "puro-gitee-publisher",
        }
        if payload is not None:
            headers["Content-Type"] = content_type
        request = Request(API_ROOT + path, data=payload, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=120) as response:
                content = response.read()
        except HTTPError as error:
            raise GiteeHTTPError(method, path, error.code) from None
        except (URLError, TimeoutError, OSError):
            raise PublishError(f"Gitee {method} {path} failed; rerun to resume this release") from None
        try:
            return json.loads(content) if content else None
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise PublishError(f"Gitee {method} {path} returned invalid JSON") from None

    def release(self, tag):
        try:
            release = self.request("GET", f"{self.path}/tags/{quote(tag, safe='')}")
        except GiteeHTTPError as error:
            if error.status == 404:
                return None
            raise
        if not isinstance(release, dict) or release.get("tag_name") != tag or not release.get("id"):
            raise PublishError("Gitee returned an unexpected release")
        return release

    def upload(self, release_id, path):
        boundary = "puro-" + secrets.token_hex(16)
        prefix = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
        ).encode("ascii")
        payload = prefix + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode("ascii")
        self.request(
            "POST",
            f"{self.path}/{release_id}/attach_files",
            payload,
            f"multipart/form-data; boundary={boundary}",
        )

    def digest(self, asset):
        url = asset.get("browser_download_url", "")
        if urlsplit(url).scheme != "https":
            raise PublishError(f"Missing HTTPS download URL for {asset['name']}")
        headers = {"User-Agent": "puro-gitee-publisher"}
        if urlsplit(url).hostname == "gitee.com":
            headers["Authorization"] = f"Bearer {self.token}"
        checksum = hashlib.sha256()
        try:
            with self.opener.open(Request(url, headers=headers), timeout=120) as response:
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    checksum.update(chunk)
        except (HTTPError, URLError, TimeoutError, OSError):
            raise PublishError(f"Could not verify remote asset {asset['name']}; rerun to resume") from None
        return checksum.hexdigest()


def sha256(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def release_files(directory):
    binaries = [directory / name for name in sorted(PLATFORMS) if (directory / name).is_file()]
    if not binaries:
        raise PublishError("The release directory must contain at least one supported Puro binary")
    paths = binaries + [directory / "install.sh", directory / "SHA256SUMS"]
    for path in paths:
        if not path.is_file() or path.stat().st_size == 0:
            raise PublishError(f"Missing or empty release file: {path.name}")
        if path.stat().st_size > 100_000_000:
            raise PublishError(f"Release file exceeds the standard Gitee 100 MB attachment limit: {path.name}")
    entries = {}
    for line in (directory / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *]([^/\\]+)", line)
        if match is None or match[2] in entries:
            raise PublishError("SHA256SUMS must contain unique flat filenames in sha256sum format")
        entries[match[2]] = match[1].lower()
    checksums = {path.name: sha256(path) for path in paths}
    for binary in binaries:
        if entries.get(binary.name) != checksums[binary.name]:
            raise PublishError(f"Missing or mismatched SHA256SUMS entry: {binary.name}")
    for name, expected in entries.items():
        if name not in checksums or checksums[name] != expected:
            raise PublishError(f"SHA256SUMS entry has no matching release file: {name}")
    return paths, checksums


def remote_tag(repository, tag):
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        result = subprocess.run(
            [
                "git", "-c", "credential.helper=", "ls-remote", "--exit-code", "--tags",
                f"https://gitee.com/{repository}.git",
                f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}",
            ],
            capture_output=True,
            text=True,
            timeout=45,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise PublishError("Could not check the remote tag; verify Git and public Gitee HTTPS access") from None
    refs = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2:
            refs[fields[1]] = fields[0]
    commit = refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")
    if result.returncode != 0 or commit is None:
        raise PublishError(f"Remote tag {tag} is missing or public HTTPS access failed; push and verify it first")
    return commit


def asset_map(release):
    assets = release.get("assets", [])
    if not isinstance(assets, list):
        raise PublishError("Gitee returned an unexpected assets list")
    result = {}
    for asset in assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            raise PublishError("Gitee returned an unexpected asset")
        if asset["name"] in result:
            raise PublishError(f"Duplicate remote asset: {asset['name']}")
        result[asset["name"]] = asset
    return result


def release_body(tag, commit, names):
    platforms = [PLATFORMS[name] for name in sorted(names) if name in PLATFORMS]
    return (
        f"Puro {tag}\n\n"
        f"Source commit: `{commit}`\n\n"
        "Published binary platforms:\n" + "\n".join(f"- {platform}" for platform in platforms) +
        "\n\nOnly the platforms listed above have binary assets in this release. "
        "Other platforms require a separate release with matching binaries and checksums.\n\n"
        "Downloads are verified against SHA256SUMS. Existing assets are retained unchanged."
    )


def publish(arguments):
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments.repository) is None:
        raise PublishError("--repository must be an owner/repository path")
    version = arguments.version[1:] if arguments.version.startswith("v") else arguments.version
    if re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version) is None:
        raise PublishError("--version must be a semantic version, optionally prefixed with v")
    tag = "v" + version
    paths, checksums = release_files(arguments.directory)
    token = (
        arguments.token_file.read_text(encoding="utf-8").strip()
        if arguments.token_file is not None
        else (os.environ.get("GITEE_ACCESS_TOKEN") or os.environ.get("GITEE_TOKEN") or "").strip()
    )
    if not token:
        raise PublishError("Provide GITEE_ACCESS_TOKEN, GITEE_TOKEN, or --token-file")
    if any(ord(character) < 33 or ord(character) > 126 for character in token):
        raise PublishError("The Gitee token must contain only visible ASCII characters")
    commit = remote_tag(arguments.repository, tag)
    gitee = Gitee(arguments.repository, token)
    release = gitee.release(tag)
    assets = asset_map(release) if release is not None else {}
    for path in paths:
        if path.name in assets:
            if gitee.digest(assets[path.name]) != checksums[path.name]:
                raise PublishError(f"Remote checksum conflict for {path.name}; publish a new version tag")
            print(f"Verified existing {path.name}")
    missing = [path for path in paths if path.name not in assets]
    body = release_body(tag, commit, set(assets) | set(checksums))
    if release is None:
        try:
            release = gitee.request("POST", gitee.path, {
                "tag_name": tag, "target_commitish": commit, "name": f"Puro {tag}",
                "body": body, "prerelease": True,
            })
        except GiteeHTTPError as error:
            if error.status in (409, 422):
                raise PublishError("Release creation raced with another publisher; rerun to verify and resume") from None
            raise
        if not isinstance(release, dict) or not release.get("id"):
            raise PublishError("Gitee returned an unexpected new release")
    elif not missing and release.get("prerelease") is False:
        print(f"Release is already complete: https://gitee.com/{arguments.repository}/releases/tag/{tag}")
        return
    else:
        gitee.request("PATCH", f"{gitee.path}/{release['id']}", {
            "tag_name": tag, "name": f"Puro {tag}", "body": body, "prerelease": True,
        })
    for path in missing:
        print(f"Uploading {path.name}")
        gitee.upload(release["id"], path)
    refreshed = gitee.release(tag)
    if refreshed is None:
        raise PublishError("Release disappeared; rerun after checking Gitee")
    uploaded = asset_map(refreshed)
    for path in paths:
        if path.name not in uploaded or gitee.digest(uploaded[path.name]) != checksums[path.name]:
            raise PublishError(f"Uploaded asset verification failed for {path.name}; release remains a preview")
        print(f"Verified uploaded {path.name}")
    gitee.request("PATCH", f"{gitee.path}/{release['id']}", {
        "tag_name": tag, "name": f"Puro {tag}", "body": body, "prerelease": False,
    })
    completed = gitee.release(tag)
    if completed is None or completed.get("prerelease") is not False:
        raise PublishError("Could not confirm final release status; rerun to resume")
    print(f"Published: https://gitee.com/{arguments.repository}/releases/tag/{tag}")


def main():
    parser = argparse.ArgumentParser(description="Publish verified Puro binaries to Gitee Releases without overwriting assets")
    parser.add_argument("--repository", default="robinzzz1/puro")
    parser.add_argument("--version", required=True)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--token-file", type=Path)
    arguments = parser.parse_args()
    try:
        publish(arguments)
    except (PublishError, OSError, UnicodeDecodeError) as error:
        print(f"Publish failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
