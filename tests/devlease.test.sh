#!/bin/bash
# Tests for the devlease hook. Run: bash tests/devlease.test.sh
DEVLEASE="$(dirname "$0")/../bin/devlease"
DEVLEASE_DIR="$(mktemp -d)"
export DEVLEASE_DIR
export DEVLEASE_WAIT=0
export DEVLEASE_DEVICES="emulator-5554 emulator-5556 R58MSAMPLE01"
# Without this the suite picks up the personal config of whoever runs it and fails
# against their rules. Tests that need a personal config set HOME themselves.
HOME="$(mktemp -d)"
export HOME
trap 'rm -rf "$DEVLEASE_DIR" "$HOME"' EXIT

pass=0; fail=0

# Without this, every `allow` assertion passes vacuously on a missing script.
[ -x "$DEVLEASE" ] || { echo "FATAL: $DEVLEASE missing or not executable"; exit 1; }

# hook <session> <command> [env assignments...]
hook() {
  local sess="$1" cmd="$2"; shift 2
  env "$@" python3 -c '
import json,sys
print(json.dumps({"session_id":sys.argv[1],"cwd":"/tmp/wt","tool_name":"Bash",
                  "tool_input":{"command":sys.argv[2]}}))' "$sess" "$cmd" \
    | env "$@" "$DEVLEASE" hook
}

# hook_cwd <session> <cwd> <command> [env assignments...]
hook_cwd() {
  local sess="$1" wd="$2" cmd="$3"; shift 3
  env "$@" python3 -c '
import json,sys
print(json.dumps({"session_id":sys.argv[1],"cwd":sys.argv[2],"tool_name":"Bash",
                  "tool_input":{"command":sys.argv[3]}}))' "$sess" "$wd" "$cmd" \
    | env "$@" "$DEVLEASE" hook
}

check() { # check <desc> <output> <grep-mode: deny|allow|warn> [substring]
  local desc="$1" out="$2" mode="$3" sub="${4:-}" ok=1
  case "$mode" in
    deny)  echo "$out" | grep -q '"permissionDecision": *"deny"' || ok=0 ;;
    allow) echo "$out" | grep -q '"permissionDecision": *"deny"' && ok=0 ;;
    warn)  echo "$out" | grep -q 'additionalContext' || ok=0 ;;
  esac
  [ -n "$sub" ] && { echo "$out" | grep -qi -- "$sub" || ok=0; }
  if [ $ok -eq 1 ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: $desc"; echo "  got: $out"
  fi
}

reset() { rm -rf "${DEVLEASE_DIR:?}"/*; }

# --- gating: what is and is not a device command ---
reset
check "assemble is ungated" "$(hook A './gradlew assembleMaestroDebug')" allow
check "unit tests ungated" "$(hook A './gradlew testDebugUnitTest')" allow
check "yaml generation ungated" "$(hook A './gradlew :maestro:generateYamls')" allow
check "adb devices ungated" "$(hook A 'adb devices -l')" allow
check "building the test apk is ungated" \
  "$(hook A './gradlew assembleDebugAndroidTest')" allow
check "lint on a maestro variant is ungated" \
  "$(hook A './gradlew lintVitalMaestroRelease')" allow
check "maestro start-device ungated" "$(hook A 'maestro start-device --platform android')" allow

# --- always-denied globals ---
reset
check "kill-server denied" "$(hook A 'adb kill-server')" deny "other agents"
check "adb root denied" "$(hook A 'adb -s emulator-5554 root')" deny "other agents"
check "adb -d denied" "$(hook A 'adb -d shell ls')" deny "other agents"
# -d/-e mean "any device"/"any emulator" only in the subcommand position; elsewhere
# they are ordinary flags (allow-downgrade, string extra) on a device-scoped command.
check "install -d is not a global op" \
  "$(hook A 'adb -s emulator-5554 install -d app.apk')" allow
check "am start -e extra is not a global op" \
  "$(hook A 'adb -s emulator-5554 shell am start -n com.x/.M -e key val')" allow
check "dumpsys usb is not a global op" \
  "$(hook A 'adb -s emulator-5554 shell dumpsys usb')" allow

# --- serial resolution ---
reset
check "adb -s acquires" "$(hook A 'adb -s emulator-5554 shell ls')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: lease dir not created"; }

reset
check "ambiguous target denied" "$(hook A './gradlew installMaestroDebug')" deny "ANDROID_SERIAL"
reset
check "ANDROID_SERIAL resolves" \
  "$(hook A './gradlew installMaestroDebug' ANDROID_SERIAL=emulator-5554)" allow
reset
check "inline ANDROID_SERIAL resolves" \
  "$(hook A 'ANDROID_SERIAL=emulator-5554 ./gradlew installMaestroDebug')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: inline ANDROID_SERIAL not read"; }
reset
check "maestro --device space form resolves" \
  "$(hook A "\$HOME/.maestro/bin/maestro --device emulator-5554 test /tmp/f.yaml")" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: maestro --device serial not used"; }
reset
check "android --device= resolves" \
  "$(hook A 'android install --device=emulator-5554 --apks=app.apk')" allow

# --- the holder is told how to give the device back ---
reset
check "fresh acquire tells holder to release" \
  "$(hook A 'adb -s emulator-5554 shell ls')" warn "devlease release"
echo "$(hook A 'adb -s emulator-5554 shell ls')" | grep -qi "devlease release" \
  && { fail=$((fail+1)); echo "FAIL: release reminder repeated on renewal"; } || pass=$((pass+1))

# --- mutual exclusion ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
check "other session denied" "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"
check "owner re-entry allowed" "$(hook A 'adb -s emulator-5554 shell ls')" allow
check "other device still free" "$(hook B 'adb -s emulator-5556 shell ls')" allow

# --- release and steal ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DEVLEASE" release emulator-5554 >/dev/null 2>&1
check "non-owner release is a no-op" "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"
CLAUDE_CODE_SESSION_ID=A "$DEVLEASE" release emulator-5554 >/dev/null
check "owner release frees it" "$(hook B 'adb -s emulator-5554 shell ls')" allow
"$DEVLEASE" steal emulator-5554 >/dev/null
check "steal frees it" "$(hook A 'adb -s emulator-5554 shell ls')" allow

# --- the hook releases, for a shell that has no session id (Codex) ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
hook A 'adb -s emulator-5556 shell ls' >/dev/null
check "the hook says what it released" \
  "$(hook A 'devlease release emulator-5554')" warn "Released emulator-5554"
check "the hook releases the named lease" "$(hook B 'adb -s emulator-5554 shell ls')" allow
check "the hook keeps the session's other leases" \
  "$(hook B 'adb -s emulator-5556 shell ls')" deny "held by"
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
hook A 'adb -s emulator-5556 shell ls' >/dev/null
hook B 'devlease release emulator-5554' >/dev/null
check "a release through the hook leaves other sessions' leases" \
  "$(hook C 'adb -s emulator-5554 shell ls')" deny "held by"
hook A '"$HOME/bin/devlease" release' >/dev/null
check "a release with no serial frees all of the session's leases" \
  "$(hook C 'adb -s emulator-5556 shell ls')" allow

reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
check "a release chained after device work is refused" \
  "$(hook A 'adb -s emulator-5554 install a.apk && devlease release emulator-5554')" deny "own"
check "the refused chain keeps the lease" "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"
check "a release fed through xargs is refused" \
  "$(hook A 'echo emulator-5554 | xargs devlease release')" deny "own"
check "the refused xargs release keeps the lease" \
  "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"
batch() { # batch <session> <command>...
  python3 -c '
import json,sys
print(json.dumps({"session_id":sys.argv[1],"cwd":"/tmp/wt","tool_name":"mcp__context_mode__ctx_batch",
                  "tool_input":{"commands":sys.argv[2:]}}))' "$@" | "$DEVLEASE" hook
}
check "a release batched after device work is refused" \
  "$(batch A 'adb -s emulator-5554 install a.apk' 'devlease release emulator-5554')" deny "own"
check "the refused batch keeps the lease" "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"

# The hook reads release's arguments the way the CLI does.
check "release --help releases nothing" "$(hook A 'devlease release --help')" warn "no lease on --help"
check "the lease survives release --help" "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"
hook A 'devlease -v release emulator-5554' >/dev/null
check "a flag before release is not a release" \
  "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"

# The shell strips redirections before the CLI runs, so the hook ignores them too.
for form in 'devlease release >/dev/null' 'devlease release 2>&1' 'devlease release > /dev/null' 'devlease release &>/dev/null'; do
  reset
  hook A 'adb -s emulator-5554 shell ls' >/dev/null
  hook A "$form" >/dev/null
  check "$form releases" "$(hook B 'adb -s emulator-5554 shell ls')" allow
done
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
hook A 'adb -s emulator-5556 shell ls' >/dev/null
hook A 'devlease release emulator-5554 >/dev/null 2>&1' >/dev/null
check "a redirected release with a serial frees only that one" \
  "$(hook B 'adb -s emulator-5556 shell ls')" deny "held by"

# --- session end releases the ending session's leases ---
session_end() {
  python3 -c '
import json,sys
print(json.dumps({"session_id":sys.argv[1],"cwd":"/tmp/wt","hook_event_name":"SessionEnd",
                  "reason":"other"}))' "$1" | "$DEVLEASE" hook
}
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
hook A 'adb -s emulator-5556 shell ls' >/dev/null
hook B 'adb -s R58MSAMPLE01 shell ls' >/dev/null
[ -z "$(session_end A)" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: session end printed output"; }
check "session end frees the session's leases" "$(hook C 'adb -s emulator-5554 shell ls')" allow
check "session end frees every lease it held" "$(hook C 'adb -s emulator-5556 shell ls')" allow
check "session end leaves other sessions' leases" \
  "$(hook C 'adb -s R58MSAMPLE01 shell ls')" deny "held by"

# --- idle TTL reap ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
touch -t 200001010000 "$DEVLEASE_DIR/emulator-5554"
check "expired lease is reaped" "$(hook B 'adb -s emulator-5554 shell ls')" allow

# --- last-writer stamp ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
CLAUDE_CODE_SESSION_ID=A "$DEVLEASE" release emulator-5554 >/dev/null
hook B 'adb -s emulator-5554 shell ls' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DEVLEASE" release emulator-5554 >/dev/null
check "returning agent warned of state change" \
  "$(hook A 'adb -s emulator-5554 shell ls')" warn "state changed"
check "renewal does not re-warn" \
  "$(hook A 'adb -s emulator-5554 shell ls')" allow
echo "$(hook A 'adb -s emulator-5554 shell ls')" | grep -qi "state changed" \
  && { fail=$((fail+1)); echo "FAIL: re-warned on renewal"; } || pass=$((pass+1))

# --- core takes a lease but never dictates which device is appropriate ---
reset
check "maestro on a physical device is allowed by default" \
  "$(hook A 'maestro --device R58MSAMPLE01 test /tmp/f.yaml')" allow
[ -d "$DEVLEASE_DIR/R58MSAMPLE01" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: maestro took no lease"; }
reset
check "a project's own gradle task is not core-gated" \
  "$(hook A './gradlew :maestro:runSelectedTests -Pdevice=emulator-5554')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && { fail=$((fail+1)); echo "FAIL: core gated a project-specific task"; } || pass=$((pass+1))
check "adb on physical is fine" "$(hook A 'adb -s R58MSAMPLE01 shell ls')" allow

# --- shell-aware parsing: a quoted argument is not a command ---
reset
check "a device command quoted inside grep is not gated" \
  "$(hook A 'grep -rn "adb kill-server" docs/')" allow
check "a device command inside echo is not gated" \
  "$(hook A "echo 'run adb -s emulator-5554 shell ls' >> notes.md")" allow
check "sed editing a file whose name mentions adb is not gated" \
  "$(hook A "sed -i '' 's/x/y/' scripts/adb-helper.sh")" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && { fail=$((fail+1)); echo "FAIL: quoted text took a lease"; } || pass=$((pass+1))

reset
check "timeout wrapper is still gated" \
  "$(hook A 'timeout 30 adb -s emulator-5554 shell ls')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: timeout wrapper not gated"; }
reset
check "bash -c is still gated" \
  "$(hook A "bash -c 'adb -s emulator-5554 shell ls'")" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: bash -c not gated"; }
reset
check "a later pipeline segment is still gated" \
  "$(hook A 'cd app && adb -s emulator-5554 shell ls')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: second segment not gated"; }
reset
check "global op inside bash -c is still refused" \
  "$(hook A "bash -c 'adb kill-server'")" deny "other agents"
reset
check "an unparseable command naming a device tool is refused" \
  "$(hook A "adb -s emulator-5554 shell echo it's")" deny "parse"
check "an unparseable command with a tool right after ( is refused" \
  "$(hook A $'X=$(adb -s emulator-5554 shell echo it\'s)')" deny "parse"
check "an unparseable command with a tool right after ; is refused" \
  "$(hook A $'true;adb shell echo it\'s')" deny "parse"

# --- separators without spaces, newlines and substitutions still end a command ---
leased() { # leased <desc>: the last hook call took the emulator-5554 lease
  [ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: $1"; }
}
unleased() { # unleased <desc>: no hook call took the emulator-5554 lease
  [ -d "$DEVLEASE_DIR/emulator-5554" ] && { fail=$((fail+1)); echo "FAIL: $1"; } || pass=$((pass+1))
}
reset; hook A $'cd app\nadb -s emulator-5554 shell ls' >/dev/null
leased "a device command on the next line is gated"
reset; hook A 'cd app&&adb -s emulator-5554 shell ls' >/dev/null
leased "a device command after && without spaces is gated"
check "a global op after ; without a space is refused" "$(hook A 'true;adb kill-server')" deny "other agents"
reset; hook A 'echo $(adb -s emulator-5554 shell ls)' >/dev/null
leased "a device command in \$( ) is gated"
reset; hook A 'diff <(adb -s emulator-5554 shell ls) expected.txt' >/dev/null
leased "a device command in <( ) is gated"
reset
check "a continued line keeps its arguments" \
  "$(hook A $'./gradlew installDebug \\\n  -Pdevice=emulator-5554')" allow
leased "a continued line keeps its arguments"
reset; hook A '>log 2>&1 adb -s emulator-5554 shell ls' >/dev/null
leased "a device command after leading redirections is gated"
reset
check "a redirection target named like a tool is not a command" "$(hook A 'echo hi > adb')" allow
reset
check "a quoted word starting with < is not a redirection" \
  "$(hook A './gradlew installDebug "<x>" -Pdevice=emulator-5554')" allow
leased "a quoted word starting with < kept the device argument after it"
check "a global op after do is refused" "$(hook A 'while true; do adb kill-server; done')" deny "other agents"
reset; hook A 'if adb -s emulator-5554 shell true; then echo ok; fi' >/dev/null
leased "a device command after if is gated"

# --- heredoc bodies are data, not commands ---
reset
check "a heredoc body is not gated" \
  "$(hook A $'cat > run.sh <<\'EOF\'\nadb kill-server\nadb -s emulator-5554 install app.apk\nEOF')" allow
unleased "a heredoc body took a lease"
check "an apostrophe in a heredoc body does not make the command unparseable" \
  "$(hook A $'git commit -F - <<EOF\nDon\'t race adb kill-server\nEOF')" allow
check "the command after a heredoc is gated" \
  "$(hook A $'cat <<EOF\nnotes\nEOF\nadb kill-server')" deny "other agents"
reset
check "a <<- heredoc ends at a tab-indented terminator" \
  "$(hook A $'cat <<-EOF\n\tadb kill-server\n\tEOF\nadb -s emulator-5554 shell ls')" allow
leased "the command after a <<- heredoc is gated"
check "a here-string is not a heredoc" \
  "$(hook A $'cat <<<"adb kill-server"\nadb kill-server')" deny "other agents"
check "a <<WORD that no WORD line closes is not a heredoc" \
  "$(hook A $'grep -n \'<<EOF\' x.sh\ntrue && adb kill-server')" deny "other agents"
check "an arithmetic shift is not a heredoc" \
  "$(hook A $'echo $((1<<n))\nadb kill-server')" deny "other agents"
check "a <<WORD in a comment is not a heredoc" \
  "$(hook A $'# feed it via <<EOF\nadb kill-server')" deny "other agents"
reset
check "an apostrophe in a comment line does not make the command unparseable" \
  "$(hook A $'# Don\'t reinstall\nadb -s emulator-5554 shell ls')" allow
leased "the command after a comment line is gated"
check "a <<\\EOF heredoc body is not gated" \
  "$(hook A $'cat <<\\EOF > s.sh\nadb kill-server\nEOF')" allow
check "a heredoc with a numeric delimiter is not gated" \
  "$(hook A $'cat <<123 > s.sh\nadb kill-server\n123')" allow
check "a continuation in a quoted heredoc does not swallow its terminator" \
  "$(hook A $'cat > x.sh <<\'EOF\'\necho a \\\nEOF\nadb kill-server')" deny "other agents"
check "a word continued across lines is joined" \
  "$(hook A $'ad\\\nb kill-server')" deny "other agents"

# --- quoted substitutions, time, joined operators, numeric serials, keyword-named paths ---
reset; hook A 'PID="$(adb -s emulator-5554 shell pidof x)"' >/dev/null
leased "a device command in a quoted \$( ) is gated"
check "a device command in backticks is gated" "$(hook A 'echo `adb kill-server`')" deny "other agents"
reset; hook A 'time ./gradlew connectedDebugAndroidTest -Pdevice=emulator-5554' >/dev/null
leased "a device command after time is gated"
check "a device command after time -p is gated" "$(hook A 'time -p adb kill-server')" deny "other agents"
check "a separator joined to a redirection still ends the command" \
  "$(hook A 'true;>log adb kill-server')" deny "other agents"
check "a process substitution joined to another is still gated" \
  "$(hook A 'diff <(true)<(adb kill-server)')" deny "other agents"
reset; hook A 'adb -s 12345 >log shell ls' >/dev/null
[ -d "$DEVLEASE_DIR/12345" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: a numeric serial before a redirection was lost"; }
check "a script named like a keyword is not a keyword" "$(hook A './scripts/do adb kill-server')" allow
reset; hook A $'X=$(adb -s emulator-5554 shell getprop)  # don\'t cache' >/dev/null
leased "an apostrophe in a trailing comment does not hide the command"
check "a ; in a trailing comment is not a separator" "$(hook A 'echo hello # example; adb kill-server')" allow
check "a # inside a word is not a comment" "$(hook A 'curl http://x/#/a;adb kill-server')" deny "other agents"
check "an escaped \$( ) in double quotes is text" "$(hook A 'echo "\$(adb kill-server)"')" allow
check "an escaped backslash before \$( ) still runs it" "$(hook A 'echo "\\\\$(adb kill-server)"')" deny "other agents"
reset
check "a backtick span in single quotes is text" \
  "$(hook A "gh pr comment 2 --body 'Run \`adb -s emulator-5554 install x.apk\` first'")" allow
unleased "a backtick span in single quotes took a lease"
check "a \$( ) in single quotes is text" "$(hook A "echo '\$(adb kill-server)'")" allow
check "apostrophes in nested quotes do not hide a \$( ) between them" \
  "$(hook A $'echo "$(echo "it\'s")" "$(adb kill-server)" "$(echo "can\'t")"')" deny "other agents"
reset; hook A $'PID="$(adb -s emulator-5554 shell ps | grep -E \'(foo|bar)\')"' >/dev/null
leased "a quoted \$( ) with parentheses inside is gated"
check "a comment line after a continuation still ends the command" \
  "$(hook A $'echo a \\\n# note\nadb kill-server')" deny "other agents"

# --- ctx_execute code: only shell code is read as shell ---
ctx() { # ctx <language> <code>
  python3 -c '
import json,sys
print(json.dumps({"session_id":"A","cwd":"/tmp/wt",
  "tool_name":"mcp__plugin_context-mode_context-mode__ctx_execute",
  "tool_input":{"language":sys.argv[1],"code":sys.argv[2]}}))' "$1" "$2" | "$DEVLEASE" hook
}
reset; ctx shell 'adb -s emulator-5554 shell ls' >/dev/null
leased "ctx_execute shell code is gated"
reset
check "ctx_execute python code is not read as shell" \
  "$(ctx python $'import shutil\nadb = shutil.which("adb")\nprint(adb)')" allow
unleased "ctx_execute python code took a lease"

# --- batch tool input shape ---
reset
out=$(python3 -c '
import json
print(json.dumps({"session_id":"A","cwd":"/tmp/wt",
  "tool_name":"mcp__plugin_context-mode_context-mode__ctx_batch_execute",
  "tool_input":{"commands":[{"label":"x","command":"adb -s emulator-5554 shell ls"}]}}))' \
  | "$DEVLEASE" hook)
check "batch_execute is gated too" "$out" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: batch command not gated"; }
reset
out=$(python3 -c '
import json
print(json.dumps({"session_id":"A","cwd":"/tmp/wt",
  "tool_name":"mcp__context_mode__ctx_batch",
  "tool_input":{"commands":["git status","adb -s emulator-5554 shell ls"],"queries":["q"]}}))' \
  | "$DEVLEASE" hook)
check "context-mode 2.x ctx_batch string commands are gated" "$out" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: ctx_batch string command not gated"; }

# --- project and home config ---
PROJ="$(mktemp -d)"; FAKEHOME="$(mktemp -d)"
cat > "$PROJ/.devlease.json" <<'JSON'
{"denied": ["^\\./?scripts/ci-only\\.sh"],
 "gated": ["flutter\\s+run"],
 "emulator_only": ["flutter\\s+drive"]}
JSON
mkdir -p "$FAKEHOME/.config/devlease"
echo '{"denied": ["wipe-the-fleet"]}' > "$FAKEHOME/.config/devlease/config.json"
XDGDIR="$(mktemp -d)"; mkdir -p "$XDGDIR/devlease"
echo '{"denied": ["scuttle-the-fleet"]}' > "$XDGDIR/devlease/config.json"

reset
check "config denied pattern is refused" \
  "$(hook_cwd A "$PROJ" './scripts/ci-only.sh')" deny
check "config gated pattern takes a lease" \
  "$(hook_cwd A "$PROJ" 'flutter run --device emulator-5554')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: config gated pattern took no lease"; }
reset
check "config emulator_only rejects a physical serial" \
  "$(hook_cwd A "$PROJ" 'flutter drive --device R58MSAMPLE01')" deny "physical"
check "config emulator_only accepts an emulator" \
  "$(hook_cwd A "$PROJ" 'flutter drive --device emulator-5554')" allow
check "an anchored config rule ignores the same path as an argument" \
  "$(hook_cwd A "$PROJ" "sed -i '' 's/a/b/' ./scripts/ci-only.sh")" allow

reset
check "a project without config is unaffected" \
  "$(hook_cwd A /tmp 'flutter run --device emulator-5554')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && { fail=$((fail+1)); echo "FAIL: gated an unconfigured project"; } || pass=$((pass+1))

reset
check "personal config in ~/.config applies anywhere" \
  "$(hook_cwd A /tmp 'wipe-the-fleet --yes' HOME="$FAKEHOME")" deny
check "the refusal names the file the rule came from" \
  "$(hook_cwd A /tmp 'wipe-the-fleet --yes' HOME="$FAKEHOME")" deny "config/devlease/config.json"
check "a project rule names the project file, not the personal one" \
  "$(hook_cwd A "$PROJ" './scripts/ci-only.sh' HOME="$FAKEHOME")" deny "$PROJ/.devlease.json"
check "project and personal rules both apply" \
  "$(hook_cwd A "$PROJ" './scripts/ci-only.sh' HOME="$FAKEHOME")" deny
check "XDG_CONFIG_HOME is honoured over ~/.config" \
  "$(hook_cwd A /tmp 'scuttle-the-fleet --yes' HOME="$FAKEHOME" XDG_CONFIG_HOME="$XDGDIR")" deny
check "XDG_CONFIG_HOME replaces ~/.config rather than adding to it" \
  "$(hook_cwd A /tmp 'wipe-the-fleet --yes' HOME="$FAKEHOME" XDG_CONFIG_HOME="$XDGDIR")" allow

# A project-specific Gradle task, gated and emulator-restricted by config alone.
cat > "$PROJ/.devlease.json" <<'JSON'
{"emulator_only": ["gradlew\\b[^|;&]*?:?maestro:run(?:All|Selected)Tests\\b"]}
JSON
reset
check "config reaches -Pdevice for a project gradle task" \
  "$(hook_cwd A "$PROJ" './gradlew :maestro:runSelectedTests -Pdevice=emulator-5554')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: -Pdevice serial not used"; }
reset
check "config blocks that task on a physical device" \
  "$(hook_cwd A "$PROJ" './gradlew :maestro:runSelectedTests -Pdevice=R58MSAMPLE01')" deny "physical"

echo 'not json {{{' > "$PROJ/.devlease.json"
check "malformed config does not break the gate" \
  "$(hook_cwd A "$PROJ" 'adb -s emulator-5554 shell ls')" allow
rm -rf "$PROJ" "$FAKEHOME" "$XDGDIR"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
