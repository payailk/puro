# Installing and releasing this fork

This fork installs precompiled binaries from `payailk/puro` GitHub Releases.
No Dart SDK is needed on the user's machine.

## macOS and Linux

After the first release has been published, install the latest release:

```bash
curl -fsSL https://github.com/payailk/puro/releases/latest/download/install.sh | bash
```

Install a specific release (the script and binary are both pinned):

```bash
curl -fsSL https://github.com/payailk/puro/releases/download/v1.5.0-ohos.1/install.sh \
  | PURO_VERSION="1.5.0-ohos.1" bash
```

The installer supports macOS arm64, macOS x64, and Linux x64. It follows GitHub
download redirects, verifies the selected binary against the release's
`SHA256SUMS`, and then runs `install-puro --promote`. Download or checksum failures
leave the existing executable untouched. Existing environments and configuration
are retained; environment launchers are refreshed by `install-puro`.

`PURO_VERSION` defaults to `latest` and accepts versions with or without `v`.
`PURO_ROOT` defaults to `~/.puro`. Other forks can set `PURO_REPOSITORY=owner/repo`
on the `bash` side of the pipe and change the script URL to their own repository.

Reopen the terminal if the installer updates PATH, then verify and use OHOS:

```bash
puro version
puro create harmony --ohos
puro use -g harmony
```

To select the environment for one Flutter project, run `puro use harmony` in that
project instead of setting the global default.

## Windows

Download `puro-windows-x64.exe` from the desired GitHub Release. In PowerShell,
run the following from the download directory:

```powershell
.\puro-windows-x64.exe install-puro --promote
```

The Bash installer does not support Windows. The Windows build is a standalone
executable, not a signed installer.

## Publishing a release

The repository must be accessible to users downloading without authentication,
and GitHub Actions must be enabled. The workflow uses the built-in `GITHUB_TOKEN`
with `contents: write` for publishing; no personal access token is required.

Commit and push the workflow, installer, tests, and documentation to `master`.
Then create and push a new version tag on that commit:

```bash
git push origin master
git tag v1.5.0-ohos.1
git push origin v1.5.0-ohos.1
```

Tags must use `v` followed by a semantic version. Each subsequent release needs
a new tag, for example `v1.5.0-ohos.2`. The `Release` workflow:

1. Resolves dependencies with Dart 3.11.5 and runs analysis, Dart tests, and
   installer tests on Linux, without formatting source files.
2. Builds native executables on Linux x64, macOS x64, macOS arm64, and Windows x64.
3. Embeds the tag's version without `v` and checks the compiled program's version
   on each platform.
4. Collects the four executables, generates `SHA256SUMS`, and includes `install.sh`.
5. Uploads all assets to a draft GitHub Release, then publishes it as the latest
   release. A failed draft upload can be retried. Already published releases are
   not overwritten.

The `-ohos.1` suffix identifies this fork's version; the workflow publishes it as
a regular GitHub Release so that `latest/download` works. Every successfully
published tag becomes the latest release, so publish tags in the intended order.
The installation commands become usable only after the workflow succeeds.

Puro's `upgrade-puro` command and update notifications still use the upstream
server by default. Use this installer again to update this fork. If desired,
disable upstream update notifications by merging `"enableUpdateCheck": false`
into `~/.puro/prefs.json` (or the corresponding file under `PURO_ROOT`).

## Local installer checks

```bash
bash -n installer/install.sh
python3 installer/test_install.py
```

Tests use local fake release assets and isolated roots; they do not download
software or change the user's Puro installation.
