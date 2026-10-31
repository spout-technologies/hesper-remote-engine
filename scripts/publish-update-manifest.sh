#!/usr/bin/env bash
#
# Publish Hesper Remote's auto-update manifests to the repo's `updates` branch.
#
# The in-app updater (hbb_common::version_check_request) GETs
#   https://raw.githubusercontent.com/<repo>/updates/<os>-<arch>.json
# for the running platform, where each file is a tiny
#   {"url":"<latest GitHub release asset>"}.
# The client parses the version out of the asset filename and offers an update.
#
# raw.githubusercontent.com is CDN-served + unauthenticated (no API rate limit),
# and the asset it points at is a signed GitHub release download.
#
# Usage:  scripts/publish-update-manifest.sh <version>      # e.g. 1.5.32
# Auth:   uses your ambient git credentials (gh/credential helper) or, in CI,
#         GITHUB_TOKEN via the checked-out remote.
set -euo pipefail

V="${1:?usage: $(basename "$0") <version>   e.g. 1.5.32}"
REPO="${HESPER_REPO:-spout-technologies/hesper-remote-engine}"
BASE="https://github.com/${REPO}/releases/download"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Clone the `updates` branch; create it as a clean orphan the first time.
if git clone --quiet --depth 1 --branch updates "https://github.com/${REPO}.git" "$tmp/u" 2>/dev/null; then
  cd "$tmp/u"
else
  git clone --quiet --depth 1 "https://github.com/${REPO}.git" "$tmp/u"
  cd "$tmp/u"
  git checkout --quiet --orphan updates
  git rm -rqf . 2>/dev/null || true
fi

write() { printf '{"url":"%s"}\n' "$2" > "$1.json"; }
write linux-x86_64   "${BASE}/linux-v${V}/HesperRemote-${V}-x86_64.deb"
write macos-x86_64   "${BASE}/v${V}/HesperRemote-${V}-x86_64.dmg"
write macos-aarch64  "${BASE}/v${V}/HesperRemote-${V}-aarch64.dmg"
write windows-x86_64 "${BASE}/win-v${V}/HesperRemote-${V}-x86_64-windows-setup.exe"

cat > README.md <<EOF
# Hesper Remote — auto-update manifests

Latest: **${V}**

Each \`<os>-<arch>.json\` is \`{"url":"<latest release asset>"}\`, fetched by the
in-app updater (\`hbb_common::version_check_request\`) for the running platform.

Regenerate with \`scripts/publish-update-manifest.sh <version>\` from the repo.
EOF

git add -A
if git diff --cached --quiet; then
  echo "manifests already at ${V}; nothing to publish"
  exit 0
fi
git -c user.name="hesper-ci" -c user.email="support@hesperitsm.com" \
  commit -qm "chore(updates): manifests -> ${V}"
git push --quiet origin updates
echo "published manifests -> ${V} on the 'updates' branch"
