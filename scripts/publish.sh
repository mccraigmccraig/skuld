#!/usr/bin/env bash
#
# Publish Skuld umbrella packages to hex.pm.
#
# Reads each package's local VERSION, compares against the latest version on
# hex.pm via the public API, and runs `mix hex.publish` interactively for any
# package where the local version is strictly greater than the hex version.
#
# Packages are published in dependency order:
#   skuld (no sibling deps)
#   skuld_concurrency, skuld_port, skuld_process (depend on skuld)
#   skuld_durable (depends on skuld + skuld_concurrency)
#   skuld_query (depends on skuld + skuld_concurrency)
#   skuld_repo (depends on skuld + skuld_port)
#
# Usage:
#   scripts/publish.sh                 # publish all interactively
#   scripts/publish.sh --check         # dry-run: show what would be published
#   scripts/publish.sh --docs          # publish documentation only
#   scripts/publish.sh --docs --check  # dry-run for docs-only
#   scripts/publish.sh skuld_port              # publish only skuld_port
#   scripts/publish.sh --docs skuld_port,skuld_concurrency  # docs for selected pkgs
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Packages in dependency order
declare -a ALL_PACKAGES=(
  "skuld"
  "skuld_concurrency"
  "skuld_port"
  "skuld_process"
  "skuld_durable"
  "skuld_query"
  "skuld_repo"
)

CHECK_ONLY=false
DOCS_ONLY=false
SELECTED_PKGS=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    --docs)  DOCS_ONLY=true ;;
    *)       SELECTED_PKGS="$arg" ;;
  esac
done

# Build the filtered package list (maintains dependency order)
declare -a PACKAGES=()
if [[ -n "$SELECTED_PKGS" ]]; then
  IFS=',' read -ra REQUESTED <<< "$SELECTED_PKGS"
  for pkg in "${ALL_PACKAGES[@]}"; do
    for req in "${REQUESTED[@]}"; do
      req="$(echo "$req" | xargs)"  # trim whitespace
      if [[ "$pkg" == "$req" ]]; then
        PACKAGES+=("$pkg")
        break
      fi
    done
  done
  if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    echo "Error: no matching packages found for filter: $SELECTED_PKGS"
    echo "Valid packages: ${ALL_PACKAGES[*]}"
    exit 1
  fi
else
  PACKAGES=("${ALL_PACKAGES[@]}")
fi

if $CHECK_ONLY && $DOCS_ONLY; then
  echo "=== DRY RUN (docs only) — no packages will be published ==="
elif $CHECK_ONLY; then
  echo "=== DRY RUN — no packages will be published ==="
elif $DOCS_ONLY; then
  echo "=== DOCS ONLY — publishing documentation updates ==="
fi

# Resolve version via local file
get_local_version() {
  local pkg="$1"
  cat "$ROOT/apps/$pkg/VERSION" | tr -d '\n\r'
}

# Resolve latest hex.pm version via the public API
# Returns "0.0.0" if not yet published or API fetch fails
get_hex_version() {
  local pkg="$1"
  local url="https://hex.pm/api/packages/$pkg"

  local version
  version=$(curl -fsS "$url" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    releases = data.get('releases', [])
    if releases:
        print(releases[0]['version'])
    else:
        print('0.0.0')
except:
    print('0.0.0')
" 2>/dev/null)

  echo "${version:-0.0.0}"
}

# Compare semver strings using sort -V (version sort)
is_newer() {
  local local_ver="$1"
  local hex_ver="$2"
  local sorted
  sorted=$(printf '%s\n%s\n' "$local_ver" "$hex_ver" | sort -V | tail -1)
  [[ "$sorted" == "$local_ver" && "$local_ver" != "$hex_ver" ]]
}

main() {
  local published_count=0
  local skipped_count=0

  for pkg in "${PACKAGES[@]}"; do
    local local_ver hex_ver
    local_ver=$(get_local_version "$pkg")
    hex_ver=$(get_hex_version "$pkg")

    if $DOCS_ONLY; then
      if [[ "$hex_ver" != "0.0.0" ]]; then
        if $CHECK_ONLY; then
          echo "  $pkg  docs (would publish)"
        else
          echo "=== Publishing docs for $pkg ==="
          (cd "$ROOT/apps/$pkg" && HEX_PUBLISH=true mix deps.get && HEX_PUBLISH=true mix hex.publish docs)
        fi
        published_count=$((published_count + 1))
      else
        echo "  $pkg  (not yet published, skip)"
        skipped_count=$((skipped_count + 1))
      fi
    elif is_newer "$local_ver" "$hex_ver"; then
      if $CHECK_ONLY; then
        echo "  $pkg  $hex_ver -> $local_ver  (would publish)"
      else
        echo "=== Publishing $pkg $local_ver (hex: $hex_ver) ==="
          (cd "$ROOT/apps/$pkg" && HEX_PUBLISH=true mix deps.get && HEX_PUBLISH=true mix hex.publish)
        published_count=$((published_count + 1))
      fi
    else
      echo "  $pkg  $local_ver  (up to date, hex: $hex_ver)"
      skipped_count=$((skipped_count + 1))
    fi
  done

  echo ""
  if $CHECK_ONLY; then
    echo "Dry run complete. $published_count package(s) would be published, $skipped_count skipped."
  else
    echo "Done. $published_count package(s) published, $skipped_count skipped."
    # Restore mix.lock — sibling deps resolved as hex packages during publish
    # pollute the umbrella mix.lock with hex entries that don't belong there.
    git -C "$ROOT" checkout mix.lock 2>/dev/null || true
  fi
}

main
