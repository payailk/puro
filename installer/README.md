# Installing and releasing this fork

This fork installs and updates precompiled binaries from
[`robinzzz1/puro` Gitee Releases](https://gitee.com/robinzzz1/puro/releases).
The user's machine can start with the executable alone. Flutter SDK mirrors are
configured separately with the existing `puro config` commands.

## macOS

Use the versioned installer to install the latest published release:

```bash
curl -fsSL https://gitee.com/robinzzz1/puro/releases/download/v1.5.0-ohos.5/install.sh | bash
```

Pin both the installer and executable to this release:

```bash
curl -fsSL https://gitee.com/robinzzz1/puro/releases/download/v1.5.0-ohos.5/install.sh \
  | PURO_VERSION="1.5.0-ohos.5" bash
```

The installer supports macOS arm64 and x64 when the selected release contains
that platform's asset. It reads the Gitee Releases API, follows asset redirects,
verifies the binary against `SHA256SUMS`, and checks the executable's embedded
version before running `install-puro --promote`. Download and verification
failures leave the existing executable untouched. Existing SDK environments and
SDK mirror settings are retained.

`PURO_VERSION` defaults to `latest` and accepts versions with or without `v`.
`PURO_ROOT` defaults to `~/.puro`. Set `PURO_REPOSITORY=owner/repo` for another
Gitee fork, or `PURO_RELEASES_URL` for a custom Gitee Releases API endpoint.
The installer saves that endpoint as `puroBuildsUrl` for subsequent updates.

Reopen the terminal if PATH was updated, then verify:

```bash
puro version
puro --json config list
```

The existing SDK selection commands remain available:

```bash
puro create harmony --ohos
puro use harmony
```

Run `puro use harmony` in the project directory for project-local selection,
or `puro use -g harmony` for the global selection.

## Windows

Select a release containing `puro-windows-x64.exe` and `SHA256SUMS` on the
[Gitee Releases page](https://gitee.com/robinzzz1/puro/releases). Download both,
then run these commands from their directory in PowerShell:

```powershell
$entry = Select-String -Path .\SHA256SUMS -Pattern '^[0-9a-fA-F]{64}\s+\*?puro-windows-x64\.exe$'
if (@($entry).Count -ne 1) { throw 'Expected one Windows checksum' }
$expected = ($entry.Line -split '\s+')[0]
$actual = (Get-FileHash .\puro-windows-x64.exe -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'Puro checksum mismatch' }
.\puro-windows-x64.exe --no-install --no-update-check version --plain
.\puro-windows-x64.exe install-puro --promote
puro --json config set puroBuildsUrl https://gitee.com/api/v5/repos/robinzzz1/puro/releases
```

The Windows build is a standalone executable. Available platforms are listed in
each release body. A release containing only a macOS arm64 binary serves that
platform; Windows and macOS x64 use their corresponding native build outputs.

## Updating Puro

```bash
puro upgrade-puro
puro upgrade-puro 1.5.0-ohos.5
```

Update discovery, notifications, and explicit upgrades share the same Gitee
release resolver. Automatic discovery selects the highest stable release that
contains the current platform binary and its checksum. The `master` argument
selects an explicitly published `master` development release. The existing
`update-puro` alias and pub-installed command path remain available.

The `puroBuildsUrl` preference now means a Gitee Releases API endpoint. Existing
custom directory-style update sources should be changed to that API format:

```bash
puro --json config set puroBuildsUrl https://gitee.com/api/v5/repos/robinzzz1/puro/releases
```

The seven existing Flutter, Dart, engine, and OHOS mirror keys keep their SDK
responsibilities. This preference controls Puro's own release source.

## Building and publishing

Use Dart 3.11.5 and build each binary on its corresponding operating system and
architecture. The local macOS arm64 build used for this version is:

```bash
cd puro
puro -e harmony dart pub get
mkdir -p ../dist
puro -e harmony dart compile exe bin/puro.dart \
  -o ../dist/puro-darwin-arm64 --define=puro_version=1.5.0-ohos.5
cd ../dist
shasum -a 256 puro-darwin-arm64 > SHA256SUMS
cp ../installer/install.sh .
cd ..
```

For a combined release, collect `puro-darwin-arm64`, `puro-darwin-x64`, and
`puro-windows-x64.exe` in `dist/`, then generate a checksum entry for each binary.
The version is embedded explicitly through `--define=puro_version`.

Commit the source, push it, and create the matching Gitee tag before publishing:

```bash
git push origin master
git tag v1.5.0-ohos.5
git push origin v1.5.0-ohos.5
python3 installer/publish_gitee.py \
  --version 1.5.0-ohos.5 \
  --directory dist \
  --token-file ~/.config/puro/gitee-release-token
```

The token file should be readable only by its owner (`chmod 600`). The publisher
also accepts `GITEE_ACCESS_TOKEN` or `GITEE_TOKEN` for CI. Use a token with write
access to the target repository; keep it outside the source and release assets.

The publisher validates the checksum manifest and remote tag, creates a
prerelease while uploading, verifies uploaded assets, and marks the release
stable when complete. Re-running the same command resumes matching uploads;
conflicting content stops publication. Release notes list the included platforms.
Retain published version assets for fixed-version installs and rollback.

The existing GitHub Actions build matrix can build all three native targets
from a GitHub mirror. Its publish job uploads to Gitee with the
`GITEE_ACCESS_TOKEN` Actions secret. Pushing a tag to Gitee alone publishes the
source tag; local publication uses the Python command above.

## Local installer checks

```bash
bash -n installer/install.sh
python3 installer/test_install.py
```

These checks use local fake release assets and isolated roots, leaving the user's
Puro installation and SDK environments unchanged.
