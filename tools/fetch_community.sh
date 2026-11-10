#!/bin/bash
# The community base + our patches: clones myUdav4iik/nfsu2-ios (branch ios) at BASE into community/
# and applies patches/*.patch (git am). The base is not ours and is not copied into this repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL=https://github.com/myUdav4iik/nfsu2-ios.git
BASE=85d2cbf
D="$ROOT/community"
[[ -e "$D" ]] && { echo "community/ exists; remove it to fetch again"; exit 1; }
git clone -q -b ios "$URL" "$D"
git -C "$D" checkout -q -B deadware "$BASE"
git -C "$D" -c user.name=build -c user.email=build@localhost am -q "$ROOT"/patches/*.patch
echo "community/ = nfsu2-ios $BASE + $(ls "$ROOT"/patches/*.patch | wc -l | tr -d ' ') patches ($(git -C "$D" rev-parse --short HEAD))"
