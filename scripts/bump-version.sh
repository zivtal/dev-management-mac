#!/bin/bash
# Bumps 1.0.0 -> 1.0.1 -> ... -> 1.0.9 -> 1.1.0 and increments the build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/project.yml"

current="$(grep -m1 'MARKETING_VERSION:' "$PROJECT" | sed 's/.*"\(.*\)".*/\1/')"
build="$(grep -m1 'CURRENT_PROJECT_VERSION:' "$PROJECT" | sed 's/.*"\(.*\)".*/\1/')"

if [[ -z "$current" || -z "$build" ]]; then
  echo "error: version settings were not found in $PROJECT" >&2
  exit 1
fi

IFS='.' read -r major minor patch <<< "$current"
patch="${patch:-0}"
patch=$((patch + 1))
if [[ "$patch" -gt 9 ]]; then
  patch=0
  minor=$((minor + 1))
  if [[ "$minor" -gt 9 ]]; then
    minor=0
    major=$((major + 1))
  fi
fi

next="$major.$minor.$patch"
next_build=$((build + 1))

if [[ "${1:-}" == "--print" ]]; then
  echo "$next"
  exit 0
fi

sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$next\"/" "$PROJECT"
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$next_build\"/" "$PROJECT"

echo "version: $current -> $next (build $next_build)"

