# What a run publishes about itself to the terminal and the session
# registry: WezTerm user vars, the session state record and the window
# title. Interpolated into lib/mkBwrapRunner.nix (no Nix interpolation in
# here); reads the runner's TOOL_NAME, WORKSPACE_HOST, GIT_MODE, OVERLAY,
# RUNDIR, SYNC_MANIFEST, DOMAIN_REG, BROKER_DIR and REG_DIR at call time,
# and sets STATE_REG, USERVAR_SET, JAIL_MARK and USERVAR_ON.

# Publish per-run facts as WezTerm user vars, so the terminal config can
# act on them: llm_custody_sync carries this run's mid-session sync
# command (a keybinding can fire it via
# pane:get_user_vars().llm_custody_sync instead of the operator having
# to catch - and keep - the path printed at launch), llm_custody_jail
# carries the jail marker plus tool name for the tab title. Written
# straight to the terminal device so they never end up in a redirected
# stdout, and wrapped in tmux's DCS passthrough when there is a tmux
# between us and the terminal. Empty value = session gone.
#
# llm_custody_sync stays strictly "absolute path or empty": it is a
# command a binding execs, and a magic non-path value in it is one
# consumer that skips its own guard away from being spawned as one.
# Everything a consumer needs to *explain* a session instead of running
# it lives in llm_custody_state (see session_state below).
emit_uservar() {
  local var="$1" value="$2" b64 seq
  b64=$(printf '%s' "$value" | base64 -w0)
  seq=$(printf '\033]1337;SetUserVar=%s=%s\007' "$var" "$b64")
  if [ -n "${TMUX:-}" ]; then
    # DCS passthrough: ESC P tmux; <payload, every ESC doubled> ESC \.
    # The payload's only ESC is its leading one, hence the single extra
    # \033 ahead of %s. \134 is the closing backslash in octal - a
    # literal one right before the quote reads as a quote escape.
    seq=$(printf '\033Ptmux;\033%s\033\134' "$seq")
  fi
  printf '%s' "$seq" > /dev/tty 2>/dev/null || true
}

# Everything a consumer needs to *describe* this session, as a record of
# newline-separated key=value lines - first '=' splits, so values stay
# free-form and only a newline (which none of these fields can hold)
# would need escaping. Published as the llm_custody_state user var and
# as $REG_DIR/<pid>.state, both written once at setup.
#
# A record rather than more single-purpose variables, or magic values
# inside existing ones: the questions a consumer asks keep growing (is
# there anything to sync? if not, why not? which git mode, which
# workspace?), and every answer would otherwise cost another var that
# every emission site has to keep in step. An unknown key is ignorable,
# so a consumer written today keeps working when a key is added.
#
# $1 is the state: `sync` (isolated trees exist, `sync` names the
# command that folds them back) or `direct` (every tree is bound
# straight through, so the host already has whatever the agent wrote).
session_state() {
  printf 'state=%s\n' "$1"
  printf 'tool=%s\n' "$TOOL_NAME"
  printf 'pid=%s\n' "$$"
  printf 'workspace=%s\n' "$WORKSPACE_HOST"
  printf 'git=%s\n' "$GIT_MODE"
  printf 'overlay=%s\n' "$OVERLAY"
  # The launchers exist in every run, whatever the state: a session that
  # bound everything straight through can still gain a copy mount later,
  # and the sync command then has something to do.
  printf 'sync=%s\n' "$RUNDIR/sync"
  printf 'manifest=%s\n' "$SYNC_MANIFEST"
  printf 'mount=%s\n' "$RUNDIR/mount"
  # Only with the network filter on: without it there is no whitelist
  # to change, and the launcher is never written.
  if [ -n "$DOMAIN_REG" ]; then
    printf 'domain=%s\n' "$RUNDIR/domain"
  fi
  # Lets a consumer find this session's request queue and control socket
  # without knowing how broker ids are formed. Absent when the broker
  # failed to start, which is exactly when a consumer should not offer to
  # answer requests.
  if [ -n "$BROKER_DIR" ]; then
    printf 'broker=%s\n' "$BROKER_DIR"
  fi
}

# Writes the record to the registry and, where the terminal takes user
# vars, out to it. One caller per state, but both of them need both
# sinks and they must not drift.
publish_state() {
  mkdir -p "$REG_DIR"
  STATE_REG="$REG_DIR/$$.state"
  session_state "$1" > "$STATE_REG"
  if [ "$USERVAR_ON" = "1" ]; then
    emit_uservar llm_custody_state "$(session_state "$1")"
    USERVAR_SET=1
  fi
}

# ▥ marks the window as jailed at a glance. The jailed tool sets its own
# OSC 2 title during the session and will overwrite this one, which is
# why the same marker also goes out as a user var above - a terminal
# config can prepend it durably, where a title we set once cannot
# survive. Sent anyway for terminals with no such config: it is at least
# correct until the tool's first title update.
# One column wide (U+25A5 is East Asian Ambiguous, which terminals
# render narrow by default), so a consumer putting this in a tab bar
# pays one cell rather than the two a fullwidth glyph costs.
JAIL_MARK="▥"
set_title() {
  printf '\033]2;%s\007' "$1" > /dev/tty 2>/dev/null || true
}

# Whether this terminal gets user vars at all. Decided once, here,
# because three separate places emit them (the sync path at setup, the
# jail marker at launch, the dirty counter during the session) and they
# must agree. Automatic only when WezTerm is detected, since terminals
# that do not know the sequence may print it instead of consuming it;
# LLMCUSTODY_USERVAR=1/0 forces the decision either way.
USERVAR_ON=0
case "${LLMCUSTODY_USERVAR:-auto}" in
  0|off|no) ;;
  1|on|yes) USERVAR_ON=1 ;;
  *)
    if [ -n "${WEZTERM_PANE:-}" ] || [ "${TERM_PROGRAM:-}" = "WezTerm" ]; then
      USERVAR_ON=1
    fi ;;
esac
