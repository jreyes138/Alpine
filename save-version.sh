#!/bin/sh
# save-version.sh - snapshot setup-cosmic-alpine.sh with a date-stamped tag
# Usage:
#   save-version.sh                       # uses default message
#   save-version.sh "fix seatd detection"  # custom changelog message
#
# Tags: vYYYY-MM-DD-rN where N increments if the same day has multiple saves.
# Files written:
#   versions/setup-cosmic-alpine.vYYYY-MM-DD-rN.sh
#   CHANGELOG.md  (appended)
#
# The "current" version always stays at setup-cosmic-alpine.sh (live file).
set -eu

cd "$(dirname "$0")"
LIVE="setup-cosmic-alpine.sh"
DATE=$(date '+%Y-%m-%d')
MSG="${1:-update}"

# Find the next rN for today
N=1
while [ -e "versions/setup-cosmic-alpine.v${DATE}-r${N}.sh" ]; do
    N=$((N + 1))
done
TAG="v${DATE}-r${N}"
SNAP="versions/setup-cosmic-alpine.${TAG}.sh"

# Skip if the live file is byte-identical to the latest existing snapshot
LATEST=$(ls -1 versions/setup-cosmic-alpine.v${DATE}-r*.sh 2>/dev/null | sort -V | tail -1)
if [ -n "$LATEST" ] && cmp -s "$LIVE" "$LATEST"; then
    # Reuse the existing tag; just update the changelog
    TAG="v${DATE}-r$((N-1))"
    SNAP="$LATEST"
    NEW_SNAPSHOT=0
else
    NEW_SNAPSHOT=1
    cp -p "$LIVE" "$SNAP"
    chmod 0755 "$SNAP"
fi

# Compute simple stats
LOC=$(wc -l < "$LIVE")
SHA=$(sha256sum "$LIVE" | cut -c1-12)

# Append to CHANGELOG.md (create if missing)
if [ ! -e CHANGELOG.md ]; then
    cat > CHANGELOG.md <<EOF
# Changelog

All notable changes to \`setup-cosmic-alpine.sh\` are recorded here.
Versions are date-stamped (\`vYYYY-MM-DD-rN\`); the live file
\`setup-cosmic-alpine.sh\` is always the latest.

EOF
fi

cat >> CHANGELOG.md <<EOF
## ${TAG}  ($(date '+%Y-%m-%d %H:%M:%S'))

- $MSG
- snapshot: \`${SNAP}\`$( [ "$NEW_SNAPSHOT" = "0" ] && echo ' (unchanged from previous)' || true )
- sha256: \`${SHA}\`
- lines: ${LOC}

EOF

if [ "$NEW_SNAPSHOT" = "1" ]; then
    printf 'saved %s  (sha256 %s, %d lines)\n' "$SNAP" "$SHA" "$LOC"
else
    printf 'no changes since %s; appended to CHANGELOG.md only\n' "$SNAP"
fi
