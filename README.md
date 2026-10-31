# Hesper Remote — auto-update manifests

Latest: **1.5.32**

Each `<os>-<arch>.json` is `{"url":"<latest release asset>"}`, fetched by the
in-app updater (`hbb_common::version_check_request`) for the running platform.

Regenerate with `scripts/publish-update-manifest.sh <version>` from the repo.
