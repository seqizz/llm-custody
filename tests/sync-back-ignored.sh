#!/usr/bin/env bash
# Tests for the gitignored-file sync-back (lib/sync-back.sh, the baseline in
# lib/jail-tree.sh). Runs the same concatenation lib/sync-back.nix builds,
# against scratch trees, with the tools found on PATH: bash, git, rsync,
# GNU coreutils/findutils/diffutils and setsid.
#
#   tests/sync-back-ignored.sh        exit 0 when every check passes
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
ROOT=$(mktemp -d); [ -z "${KEEP:-}" ] || echo "$ROOT"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT"' EXIT

SYNC="$ROOT/sync-back"
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  cat "$LIB/log.sh" "$LIB/jail-tree.sh" "$LIB/sync-back.sh"
} >"$SYNC"
chmod +x "$SYNC"

# Read by the two sourced files.
# shellcheck disable=SC2034
VERBOSITY=0
# shellcheck disable=SC2034
MASK_PATTERNS=()
# shellcheck source=/dev/null
. "$LIB/log.sh"
# shellcheck source=/dev/null
. "$LIB/jail-tree.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null NO_COLOR=1 PAGER=cat

FAILED=0
CASE=""
ok() { printf 'ok    %s: %s\n' "$CASE" "$1"; }
fail() {
  printf 'FAIL  %s: %s\n' "$CASE" "$1"
  FAILED=$((FAILED + 1))
}
check() {
  local what="$1"
  shift
  if "$@"; then ok "$what"; else fail "$what"; fi
}
content_is() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
out_has() { grep -q -- "$1" "$OUT"; }
out_lacks() { ! grep -q -- "$1" "$OUT"; }

# A host tree with one tracked file and gitignored files under artifacts/
# and node_modules/,
# copied the way a limited mount copies it.
setup() {
  CASE="$1"
  T="$ROOT/$CASE"
  HOST="$T/host"
  COPY="$T/copy"
  TRACK="$T/track.git"
  OUT="$T/out"
  mkdir -p "$HOST/artifacts/sub" "$HOST/node_modules/pkg"
  printf 'artifacts/\nnode_modules/\n' >"$HOST/.gitignore"
  printf 'dep\n' >"$HOST/node_modules/pkg/index.js"
  printf 'dep\n' >"$HOST/node_modules/pkg/lib.js"
  printf 'tracked\n' >"$HOST/code.txt"
  printf 'one\n' >"$HOST/artifacts/a.yaml"
  printf 'two\n' >"$HOST/artifacts/sub/b.yaml"
  ln -s a.yaml "$HOST/artifacts/link"
  git -C "$HOST" init -q
  baseline
  printf 'copy\t%s\t%s\t%s\ttest tree\n' "$COPY" "$TRACK" "$HOST" >"$T/manifest"
}
baseline() {
  jail_copy_tree "$HOST" "$COPY"
  jail_init_repo "$COPY" "$HOST" "test"
  jail_track_init "$COPY" "$TRACK"
  settle
}
# A ctime taken in the same clock tick as the stamp does not count as newer.
settle() { sleep 0.05; }

# setsid drops the controlling terminal, so the prompts read the answers
# from stdin, one line each.
run_sync() {
  local answers="$1"
  shift
  printf '%b' "$answers" | setsid "$SYNC" "$@" "$T/manifest" >"$OUT" 2>&1 || true
}

# Prompt order per tree: the tracked changes (asked only when there are
# any, or as a reset offer under --live), then the gitignored rules.

setup select-rule
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'agent\n' >"$COPY/node_modules/pkg/index.js"
printf 'agent\n' >"$COPY/node_modules/pkg/lib.js"
run_sync '1\n' --prompt
check "rule line with its count" out_has '1) artifacts/  1 file(s)'
check "second rule grouped into one line" out_has '2) node_modules/  2 file(s)'
check "single paths not listed by default" out_lacks 'node_modules/pkg/index.js'
check "selected rule written over the host file" content_is "$HOST/artifacts/a.yaml" agent
check "unselected rule left alone" content_is "$HOST/node_modules/pkg/index.js" dep
check "no sidecar" absent "$HOST/artifacts/a.yaml.llm-custody"
run_sync '\n' --prompt
check "unselected rule is offered again" out_has '1) node_modules/  2 file(s)'
check "synced rule is not" out_lacks 'artifacts/'

setup default-none
printf 'agent\n' >"$COPY/artifacts/a.yaml"
run_sync '\n' --prompt
check "enter syncs nothing" content_is "$HOST/artifacts/a.yaml" one
run_sync 'bogus\n\n' --prompt
check "unknown answer syncs nothing" content_is "$HOST/artifacts/a.yaml" one
check "unknown answer is asked again" out_has 'not understood'

setup select-all
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'agent\n' >"$COPY/node_modules/pkg/index.js"
run_sync 'a\n' --prompt
check "a writes the first rule" content_is "$HOST/artifacts/a.yaml" agent
check "a writes the second rule" content_is "$HOST/node_modules/pkg/index.js" agent

setup select-two
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'agent\n' >"$COPY/node_modules/pkg/index.js"
run_sync '1,2\n' --prompt
check "comma list writes the first rule" content_is "$HOST/artifacts/a.yaml" agent
check "comma list writes the second rule" content_is "$HOST/node_modules/pkg/index.js" agent

setup drill-down
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'agent\n' >"$COPY/node_modules/pkg/index.js"
run_sync 'l 2\n\n' --prompt
check "l N lists the paths of that rule" out_has 'node_modules/pkg/index.js$'
check "l N lists no other rule" out_lacks 'artifacts/a.yaml$'
run_sync 'd 1\n\n' --prompt
check "d N shows the host version" out_has '^-one$'
check "d N shows the jail version" out_has '^+agent$'
check "drill-down alone syncs nothing" content_is "$HOST/artifacts/a.yaml" one

setup with-tracked
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'agent\n' >"$COPY/code.txt"
run_sync 'y\n\n' --prompt
check "tracked yes syncs the tracked file" content_is "$HOST/code.txt" agent
check "tracked yes does not cover gitignored files" content_is "$HOST/artifacts/a.yaml" one
check "tracked change list holds no gitignored path" out_lacks '^ .*artifacts/a.yaml'
run_sync '1\n' --prompt
check "gitignored rule still selectable afterwards" content_is "$HOST/artifacts/a.yaml" agent

setup tracked-declined
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'agent\n' >"$COPY/code.txt"
run_sync 'n\n1\n' --prompt
check "tracked no keeps the tracked file" content_is "$HOST/code.txt" tracked
check "gitignored rule asked all the same" content_is "$HOST/artifacts/a.yaml" agent

setup created
printf 'new\n' >"$COPY/artifacts/created.yaml"
run_sync 'a\n' --prompt
check "created gitignored file is not offered" out_lacks 'gitignored'
check "created gitignored file stays in the jail" absent "$HOST/artifacts/created.yaml"

setup deleted
rm "$COPY/artifacts/a.yaml"
rm -r "$COPY/artifacts/sub"
run_sync 'a\n' --prompt
check "host file survives a jail deletion" content_is "$HOST/artifacts/a.yaml" one
check "host dir survives a jail deletion" content_is "$HOST/artifacts/sub/b.yaml" two

setup same-content
printf 'one\n' >"$COPY/artifacts/a.yaml"
chmod 600 "$COPY/artifacts/sub/b.yaml"
run_sync 'a\n' --prompt
check "rewrite with equal content is no change" out_lacks 'gitignored'

setup headless
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'agent\n' >"$COPY/code.txt"
run_sync '' --auto
check "tracked file synced" content_is "$HOST/code.txt" agent
check "gitignored host file not overwritten" content_is "$HOST/artifacts/a.yaml" one
check "no sidecar" absent "$HOST/artifacts/a.yaml.llm-custody"
check "warning names the count" out_has '1 modified gitignored file(s) NOT synced'
check "warning names the rule" out_has 'artifacts/  1 file(s)'

setup later-edit
printf 'agent\n' >"$COPY/artifacts/a.yaml"
run_sync '1\n' --prompt
printf 'agent2\n' >"$COPY/artifacts/a.yaml"
run_sync '1\n' --prompt
check "a later edit is offered again" content_is "$HOST/artifacts/a.yaml" agent2

setup symlink
ln -sfn sub/b.yaml "$COPY/artifacts/link"
run_sync '1\n' --prompt
check "retargeted symlink synced" [ "$(readlink "$HOST/artifacts/link")" = sub/b.yaml ]

setup type-change
rm "$COPY/artifacts/link"
printf 'now a file\n' >"$COPY/artifacts/link"
rm "$COPY/artifacts/a.yaml"
mkdir "$COPY/artifacts/a.yaml"
run_sync 'a\n' --prompt
check "symlink on the host kept" [ -L "$HOST/artifacts/link" ]
check "file on the host kept" content_is "$HOST/artifacts/a.yaml" one
check "type change reported" out_has 'not synced'

setup symlinked-parent
mkdir "$T/elsewhere"
printf 'outside\n' >"$T/elsewhere/b.yaml"
rm -r "$COPY/artifacts/sub"
ln -s "$T/elsewhere" "$COPY/artifacts/sub"
run_sync 'a\n' --prompt
check "path behind a swapped-in symlink not synced" content_is "$HOST/artifacts/sub/b.yaml" two
check "swap reported" out_has 'reached through a symlink'

setup un-ignored
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'node_modules/\n' >"$COPY/.gitignore"
run_sync 'n\n' --prompt
check "un-ignored path moves to the tracked list" out_has '?? artifacts/a.yaml'
check "and leaves the gitignored prompt" out_lacks 'by ignore rule'

setup sync-exclude
printf 'agent\n' >"$COPY/artifacts/a.yaml"
run_sync 'a\n' --prompt --exclude 'artifacts/*'
check "--sync-exclude holds a gitignored file back" content_is "$HOST/artifacts/a.yaml" one

setup no-stamp
rm "$TRACK/llm-custody/stamp"
printf 'agent\n' >"$COPY/artifacts/a.yaml"
run_sync 'a\n' --prompt
check "no stamp, nothing synced" content_is "$HOST/artifacts/a.yaml" one

setup reset-baseline
printf 'late\n' >"$HOST/artifacts/late.yaml"
run_sync 'r\n' --prompt --live
check "reset brings the new host file in" content_is "$COPY/artifacts/late.yaml" late
check "reset lists it in the baseline" grep -qz '^artifacts/late.yaml$' "$TRACK/llm-custody/ignored.list"
settle
printf 'agent\n' >"$COPY/artifacts/late.yaml"
run_sync 'n\n1\n' --prompt --live
check "edit to a file that arrived by reset syncs back" content_is "$HOST/artifacts/late.yaml" agent

setup reset-confirm
printf 'agent\n' >"$COPY/artifacts/a.yaml"
run_sync 'r\nn\n\n' --prompt --live
check "reset offer names tracked changes only" out_has 'has no tracked changes'
check "reset asks before dropping a modified gitignored file" out_has '1 modified gitignored file(s)'
check "declined reset keeps the jail version" content_is "$COPY/artifacts/a.yaml" agent
run_sync 'r\ny\n' --prompt --live
check "confirmed reset restores the host version" content_is "$COPY/artifacts/a.yaml" one
check "nothing asked after the reset" out_lacks 'by ignore rule'

setup discard
printf 'agent\n' >"$COPY/artifacts/a.yaml"
printf 'agent\n' >"$COPY/code.txt"
run_sync 'x\ny\n1\n' --prompt --live
check "discard reverts the tracked file" content_is "$COPY/code.txt" tracked
check "discard leaves the gitignored file" content_is "$COPY/artifacts/a.yaml" agent
check "gitignored rule still selectable after a discard" content_is "$HOST/artifacts/a.yaml" agent

if [ "$FAILED" -gt 0 ]; then
  printf '%s check(s) failed\n' "$FAILED"
  exit 1
fi
printf 'all checks passed\n'
