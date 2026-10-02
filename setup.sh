#!/usr/bin/env bash
# =============================================================================
#  NDP Endpoint installer
# =============================================================================
#  The installer itself lives in the Endpoint's own repository, beside the
#  example.env it renders a deployment .env from. That is the point: a setting
#  added to example.env reaches new installations on its own, which a script
#  keeping its own list of variables cannot do. The script this replaces had
#  fallen 23 variables behind, among them PRE_CKAN_ORGANIZATION, the three
#  NETBIRD_* settings and every PELICAN_EVENT_* one.
#
#  This file only fetches that installer, so the URL the platform's
#  create-endpoint page points at keeps working and never needs changing
#  again. Every argument is passed through untouched.
#
#  The script this replaces is kept beside it as setup.sh.old.1.
#
#  --------------------------------------------------------------------------
#  Pinned to a release tag, not to a branch. Pointing at main would make every
#  merge into ep-api a deployment to every new installation, with nothing in
#  between to catch a mistake. Raise EP_VERSION when a release is ready to be
#  installed from; the tags are at
#  https://github.com/national-data-platform/ep-api/releases
#  --------------------------------------------------------------------------
set -euo pipefail

EP_VERSION="v0.34.30"
INSTALLER="https://raw.githubusercontent.com/national-data-platform/ep-api/${EP_VERSION}/install/install.sh"

# The installer needs the rest of the repository beside it -- example.env
# above all -- and clones it when run from a downloaded file like this one.
# Without this it would clone main and re-exec from there, which would make
# the pin above decorative: the script fetched would be the release and the
# one that actually ran would be the branch tip.
export EP_REPO_REF="$EP_VERSION"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Downloaded to a file rather than piped straight into bash: with process
# substitution a failed download is an empty script, which bash runs happily
# and exits 0 from, so a network problem would look like a silent success.
if ! curl -fsSL "$INSTALLER" -o "$tmp"; then
  echo "Could not download the NDP Endpoint installer from:" >&2
  echo "  $INSTALLER" >&2
  exit 1
fi

if [[ ! -s "$tmp" ]]; then
  echo "The installer downloaded from $INSTALLER is empty." >&2
  exit 1
fi

status=0
bash "$tmp" "$@" || status=$?
exit "$status"
