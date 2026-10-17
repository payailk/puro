#!/usr/bin/env bash

# Run in a subshell so this also works when sourced without changing the caller.
puro_install() (
  set -eu

  PURO_ROOT="${PURO_ROOT:-$HOME/.puro}"
  export PURO_ROOT
  PURO_VERSION="${PURO_VERSION:-latest}"
  PURO_REPOSITORY="${PURO_REPOSITORY:-robinzzz1/puro}"

  if [[ ! "$PURO_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    >&2 echo 'Error: PURO_REPOSITORY must be an owner/repository name.'
    exit 1
  fi

  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) target=darwin-arm64 ;;
    Darwin/x86_64) target=darwin-x64 ;;
    *)
      >&2 echo 'Error: This installer supports macOS arm64/x64. Linux binaries are not published.'
      exit 1
      ;;
  esac

  if ! command -v curl > /dev/null 2>&1; then
    >&2 echo 'Error: Install curl before running this installer.'
    exit 1
  fi
  if ! command -v plutil > /dev/null 2>&1; then
    >&2 echo 'Error: The macOS plutil command is required to read Gitee releases.'
    exit 1
  fi
  if command -v sha256sum > /dev/null 2>&1; then
    checksum_command=(sha256sum)
  elif command -v shasum > /dev/null 2>&1; then
    checksum_command=(shasum -a 256)
  else
    >&2 echo 'Error: Install sha256sum or shasum before running this installer.'
    exit 1
  fi

  releases_url="${PURO_RELEASES_URL:-https://gitee.com/api/v5/repos/$PURO_REPOSITORY/releases}"
  releases_url="${releases_url%/}"
  case "$releases_url" in
    https://*|http://*) ;;
    *) >&2 echo 'Error: PURO_RELEASES_URL must be an HTTP(S) Gitee Releases API URL.'; exit 1 ;;
  esac
  if [ "$PURO_VERSION" = latest ]; then
    release_url="$releases_url/latest"
  else
    requested_version="${PURO_VERSION#v}"
    if [[ ! "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
      >&2 echo 'Error: PURO_VERSION must be latest or a version such as 1.5.0-ohos.1 (optional v prefix).'
      exit 1
    fi
    release_url="$releases_url/tags/v$requested_version"
  fi

  mkdir -p "$PURO_ROOT/bin"
  download_dir="$(mktemp -d "$PURO_ROOT/bin/.puro-install.XXXXXX")"
  trap 'rm -rf "$download_dir"' EXIT
  asset="puro-$target"

  echo "Downloading $asset ($PURO_VERSION) from $PURO_REPOSITORY..."
  if ! curl -fL --retry 3 --output "$download_dir/release.json" "$release_url"; then
    >&2 echo 'Error: Could not read the Gitee Release. Check that the release has been published.'
    exit 1
  fi
  release_tag="$(plutil -extract tag_name raw -o - "$download_dir/release.json")"
  release_version="${release_tag#v}"
  if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    >&2 echo 'Error: The Gitee Release must have a semantic version tag.'
    exit 1
  fi
  if [ "$PURO_VERSION" != latest ] && [ "$release_version" != "$requested_version" ]; then
    >&2 echo 'Error: The Gitee Release does not match the requested version.'
    exit 1
  fi
  if [ "$PURO_VERSION" = latest ] && [ "$(plutil -extract prerelease raw -o - "$download_dir/release.json")" = true ]; then
    >&2 echo 'Error: The latest Gitee Release is still being prepared. Select a published version.'
    exit 1
  fi

  release_asset_url() {
    asset_index=0
    while asset_name="$(plutil -extract "assets.$asset_index.name" raw -o - "$download_dir/release.json" 2>/dev/null)"; do
      if [ "$asset_name" = "$1" ]; then
        asset_url="$(plutil -extract "assets.$asset_index.browser_download_url" raw -o - "$download_dir/release.json")"
        case "$asset_url" in
          https://*|http://*) printf '%s\n' "$asset_url"; return 0 ;;
        esac
        break
      fi
      asset_index=$((asset_index + 1))
    done
    >&2 echo "Error: The Gitee Release has no downloadable $1 asset."
    return 1
  }

  binary_url="$(release_asset_url "$asset")"
  checksums_url="$(release_asset_url SHA256SUMS)"
  curl -fL --retry 3 --output "$download_dir/$asset" "$binary_url"
  curl -fL --retry 3 --output "$download_dir/SHA256SUMS" "$checksums_url"

  # Check only the selected platform, not the other files in the release.
  checksum="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$download_dir/SHA256SUMS")"
  if [[ ! "$checksum" =~ ^[0-9a-fA-F]{64}$ ]]; then
    >&2 echo "Error: Missing or invalid SHA-256 checksum for $asset."
    exit 1
  fi
  (
    cd "$download_dir"
    printf '%s  %s\n' "$checksum" "$asset" | "${checksum_command[@]}" -c -
  )

  chmod +x "$download_dir/$asset"
  unset PURO_FLUTTER_BIN
  actual_version="$("$download_dir/$asset" --no-install --no-update-check version --plain)"
  if [ "$actual_version" != "$release_version" ]; then
    >&2 echo "Error: Downloaded Puro reports $actual_version instead of $release_version."
    exit 1
  fi
  "$download_dir/$asset" install-puro --promote
  "$download_dir/$asset" --no-install --no-update-check --json config set puroBuildsUrl "$releases_url"
)

puro_install
