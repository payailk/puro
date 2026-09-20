#!/usr/bin/env bash

# Run in a subshell so this also works when sourced without changing the caller.
puro_install() (
  set -eu

  PURO_ROOT="${PURO_ROOT:-$HOME/.puro}"
  export PURO_ROOT
  PURO_VERSION="${PURO_VERSION:-latest}"
  PURO_REPOSITORY="${PURO_REPOSITORY:-payailk/puro}"

  if [[ ! "$PURO_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    >&2 echo 'Error: PURO_REPOSITORY must be an owner/repository name.'
    exit 1
  fi

  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) target=darwin-arm64 ;;
    Darwin/x86_64) target=darwin-x64 ;;
    Linux/x86_64) target=linux-x64 ;;
    *)
      >&2 echo 'Error: Supported platforms are macOS arm64/x64 and Linux x64.'
      exit 1
      ;;
  esac

  if ! command -v curl > /dev/null 2>&1; then
    >&2 echo 'Error: Install curl before running this installer.'
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

  release_url="https://github.com/$PURO_REPOSITORY/releases"
  if [ "$PURO_VERSION" = latest ]; then
    release_url="$release_url/latest/download"
  else
    version="${PURO_VERSION#v}"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
      >&2 echo 'Error: PURO_VERSION must be latest or a version such as 1.5.0-ohos.1 (optional v prefix).'
      exit 1
    fi
    release_url="$release_url/download/v$version"
  fi

  mkdir -p "$PURO_ROOT/bin"
  download_dir="$(mktemp -d "$PURO_ROOT/bin/.puro-install.XXXXXX")"
  trap 'rm -rf "$download_dir"' EXIT
  asset="puro-$target"

  echo "Downloading $asset ($PURO_VERSION) from $PURO_REPOSITORY..."
  if ! curl -fL --retry 3 --output "$download_dir/$asset" "$release_url/$asset"; then
    >&2 echo 'Error: Could not download Puro. Check that the GitHub Release has been published.'
    exit 1
  fi
  curl -fL --retry 3 --output "$download_dir/SHA256SUMS" "$release_url/SHA256SUMS"

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
  "$download_dir/$asset" install-puro --promote
)

puro_install
