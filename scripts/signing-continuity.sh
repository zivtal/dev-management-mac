#!/usr/bin/env bash
# Sourced by the deployment script. These checks inspect signatures and identity
# names only; they never read a Keychain password or alter an item's access rules.

capture_installed_signing_identity() {
  local installed_app="$1"
  local requirement_file="$2"
  local signing_details signing_requirement signing_authority identity_line
  local identity_pattern='[[:space:]]([[:xdigit:]]{40})[[:space:]]+"([^"]+)"'
  PRESERVED_SIGNING_IDENTITY=""
  [[ -d "$installed_app" ]] || return 0

  signing_details="$(codesign --display --verbose=2 --requirements - "$installed_app" 2>&1)" || {
    echo "error: cannot inspect the installed app's signing identity; leaving it installed" >&2
    return 1
  }
  signing_requirement="$(sed -n 's/^designated => //p' <<< "$signing_details")"
  signing_authority="$(sed -n 's/^Authority=//p' <<< "$signing_details" | head -n 1)"
  if [[ -z "$signing_requirement" || -z "$signing_authority" || "$signing_requirement" == *cdhash* ]]; then
    echo "error: installed app has no reusable certificate-backed trust rule; leaving it installed" >&2
    return 1
  fi

  local valid_identities
  valid_identities="$(security find-identity -v -p codesigning)" || return 1
  while IFS= read -r identity_line; do
    if [[ "$identity_line" =~ $identity_pattern && "${BASH_REMATCH[2]}" == "$signing_authority" ]]; then
      PRESERVED_SIGNING_IDENTITY="${BASH_REMATCH[1]}"
      break
    fi
  done <<< "$valid_identities"
  if [[ -z "$PRESERVED_SIGNING_IDENTITY" ]]; then
    echo "error: the installed app's signer ($signing_authority) has no valid local identity" >&2
    echo "Restore or renew that identity before deploying. Refusing to silently change Keychain trust." >&2
    return 1
  fi

  printf '%s\n' "$signing_requirement" > "$requirement_file"
  echo "==> Preserving installed signing identity: $signing_authority"
}

verify_signing_continuity() {
  local candidate_app="$1"
  local requirement_file="$2"
  codesign --verify --deep --strict "$candidate_app" || return 1
  if [[ -f "$requirement_file" ]]; then
    # Evaluate the old requirement against the new binary, rather than comparing
    # requirement strings or assuming that the same team is sufficient.
    codesign --verify --strict --test-requirement "$requirement_file" "$candidate_app" || {
      echo "error: the update changes the installed app's Keychain identity; deployment stopped" >&2
      return 1
    }
    echo "==> Verified compatibility with the installed app's Keychain identity"
  fi
}
