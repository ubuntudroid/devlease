# devlease

Leases each Android device and emulator to one coding agent at a time.

Run two or three agents on one Android codebase and they will eventually reach for
the same device. One installs a build while another is mid-instrumentation-run; one
resets app state under another's UI test; one runs `adb kill-server` and every other
agent's session dies. The failures are intermittent and read like flaky tests.

devlease is a `PreToolUse` hook. Before any command that touches a device, it works
out which device that is and takes an exclusive lease on it. A second agent asking
for the same device waits briefly, then gets told who holds it and to do something
else. Nothing else about how agents work changes.

## Install

**As a Claude Code plugin**

```
/plugin marketplace add ubuntudroid/devlease
/plugin install devlease
```

That wires the hooks. Plugin hooks load when a session starts, so open a new
session before expecting the gate to fire.

To put the CLI on your `PATH`, point at the installed version explicitly:

```
ln -sf "$(ls -d ~/.claude/plugins/cache/devlease/devlease/*/ | tail -1)bin/devlease" ~/bin/devlease
```

Re-run that after upgrading, or clone the repo and symlink `bin/devlease` from
the clone instead, which survives version changes.

**Standalone**

Clone anywhere, then add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/src/devlease/bin/devlease\" hook",
            "timeout": 120
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/src/devlease/bin/devlease\" hook",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Edits to `settings.json` take effect immediately, with no restart — unlike the
plugin route, where hooks load at session start.

The `matcher` above covers the `Bash` tool. If you use a plugin that runs shell
commands through its own MCP tool, add those tool names to the alternation; the
shipped `hooks/hooks.json` does this for context-mode's sandbox tools.

**Codex**

Codex sends its hooks the same payload, so the same script works. Add this to
`~/.codex/config.toml`, with the path pointing at your `devlease`:

```toml
[[hooks.PreToolUse]]
matcher = "^Bash$"
[[hooks.PreToolUse.hooks]]
type = "command"
command = '"$HOME/src/devlease/bin/devlease" hook'
timeout = 120

[[hooks.SessionEnd]]
[[hooks.SessionEnd.hooks]]
type = "command"
command = '"$HOME/src/devlease/bin/devlease" hook'
```

Then start `codex`, run `/hooks` and trust both hooks: Codex skips a hook until
you trust it. Install them for your user, not in a project's `.codex/`: Codex
also skips project hooks in a project you have not trusted, and every new
worktree is a new project. A tool that starts Codex with its own `CODEX_HOME`
reads that directory's `config.toml` instead.

Requires `python3` (standard library only) and `adb` on `PATH`.

## What it gates

| Command | How the target is resolved |
|---|---|
| `adb …` (except `devices`, `version`, `help`) | `-s <serial>` |
| `gradlew install*` / `uninstall*` / `connected*` | `ANDROID_SERIAL` (AGP has no serial flag) |
| `maestro … test` / `record` / `studio` / `hierarchy` | `--device <serial>` |
| `android install` / `run` / `screen` / `layout` | `--device=<serial>` |

Falling back, in order: `-Pdevice=<serial>`, `ANDROID_SERIAL` (env or inline on the
command), then the only attached device. If none of those resolve and more than one
device is attached, the command is refused rather than guessed at — the same mistake
`./gradlew installDebug` makes on its own.

Build-only work is never gated: `assembleDebugAndroidTest` and
`compileDebugAndroidTestKotlin` build the test APK without touching a device, and
`maestro start-device` is what creates an emulator in the first place.

The command is split the way a shell would split it, and only words in command
position are considered. `grep -rn "adb kill-server" docs/` runs `grep`, not
`adb`, and is left alone; so is a `sed` that edits a script whose name mentions
adb. Wrappers are followed through — `timeout 30 adb …`, `env FOO=bar adb …`,
`bash -c "adb …"`, and the far side of `&&` or `|` all resolve to the real
command. So do a new line, `;` or `&&` without spaces, `$( … )` and backticks
(in double quotes or unquoted), `<( … )`, `time`, and the command after `if`,
`then` or `do`. An escaped `\$( … )` is text.
A heredoc's body and a comment are data, so they are not checked, though
the shell does run a `$( … )` in a heredoc whose delimiter is unquoted.
Redirections such as `>log` or `2>&1` are ignored.

**Always refused, no lease possible:** `adb kill-server`, `start-server`, `root`,
`unroot`, `reboot`, `usb`, `tcpip`, `disconnect`, and `adb -d` / `adb -e`. These
reconfigure the shared adb server or reboot a device out from under whoever holds
it. A human can still run them in their own terminal.

## Using it

Agents are told what to do by the hook itself — a holder is told to release, a
blocked agent is told who holds the device. You need three commands:

```
devlease list              # who holds what
devlease release [serial]  # give back the leases you hold
devlease steal <serial>    # break a stuck lease
```

## Project rules

Some rules only make sense in one repo: a script that must never run locally, a
custom Gradle task that drives a device, a test suite that must stay off physical
hardware. Those go in `<repo>/.devlease.json`, so they travel with the checkout
and apply to everyone working in it.

Rules that are yours rather than the project's go in
`~/.config/devlease/config.json` (or `$XDG_CONFIG_HOME/devlease/config.json`,
which replaces that location rather than adding to it).

Both files are read and their rules concatenated.

```json
{
  "denied": ["scripts/reset-device-farm\\.sh"],
  "gated": ["gradlew\\b[^|;&]*?:?e2e:run\\w*Tests\\b"],
  "emulator_only": ["gradlew\\b[^|;&]*?:?e2e:run\\w*Tests\\b"]
}
```

| key | effect |
|---|---|
| `denied` | always refused, no lease possible |
| `gated` | requires a lease |
| `emulator_only` | requires a lease **and** an `emulator-*` serial |

Values are Python regexes, matched against one parsed command segment at a time
rather than the raw command line. A segment starts with the command word, so `^`
anchors to command position — `^(?:\./)?scripts/reset-device-farm\.sh` refuses
that script when it runs, and ignores it when it is merely an argument to `sed`
or `git`. Leave the anchor off when you mean to match an argument, such as a
Gradle task name.

A missing or malformed file costs you those rules and nothing else; the built-in
gating still applies.

## How leases behave

A lease is a directory under `~/.android-devlease/<serial>`, created with `mkdir`,
which is atomic. It is held until the agent runs `devlease release` or its
session ends, and reaped after 60 minutes idle. Every gated command renews it.

The hook does the release when it sees `devlease release` in a command, because
it gets the session id from the agent. The CLI on its own knows the session only
from `CLAUDE_CODE_SESSION_ID`, which a Codex shell does not set. The hook runs
before the command does, so it refuses a `devlease release` chained with other
commands: run it on its own. A release you then reject at the permission prompt
has still happened.

The TTL is deliberately longer than any single command, because nothing renews a
lease while a 20-minute test suite is running. `PostToolUse` cannot help — it fires
when the tool call returns, which for a backgrounded Gradle run is long before the
suite ends. So an abandoned lease is cleared by `devlease steal`, not by a short
timeout.

Each device also records its last holder. When an agent takes a device that someone
else has held since it last did, it is told so, because whatever it installed or set
up there is probably gone. This is what makes both the TTL and `steal` safe: losing a
lease is survivable as long as you find out.

Environment overrides, mostly for testing: `DEVLEASE_DIR`, `DEVLEASE_TTL`,
`DEVLEASE_WAIT`, `DEVLEASE_DEVICES`.

## Known limits

- **A shell script argument is not followed.** `bash deploy.sh` is treated as a
  `bash` invocation; whatever `deploy.sh` does to a device is invisible until the
  script's own commands reach the hook, which they never do. `bash -c "adb …"` is
  followed, because the command is right there in the argument.
- **Unparseable commands are refused** if they name a device tool. Unbalanced
  quotes mean the gate cannot tell what would run, and guessing in either
  direction is worse than asking you to rewrite it.
- **Fails open.** A bug in the hook prints to stderr and allows the command, rather
  than blocking all Android work.
- **Subagents are untested.** Whether a subagent's hook `session_id` matches its
  parent's has not been verified. If it differs, a parent and its subagent will
  block each other on one device.
- **One machine.** Leases are local directories; this does not coordinate across
  hosts or a device farm.

## Working on devlease

```
bash tests/devlease.test.sh
```

No framework, no fixtures — it drives the hook over stdin the way Claude Code
does.

Installing a plugin *copies* it into `~/.claude/plugins/cache/`, so editing this
repo does not change what the hook runs, and `claude plugin marketplace update`
will tell you it succeeded while leaving the old copy in place. Replace the copy
with a symlink once and the problem goes away:

```
cd ~/.claude/plugins/cache/devlease/devlease
rm -rf <version> && ln -s /path/to/your/devlease <version>
```

The hook then runs your working tree, and a `devlease` on your `PATH` that points
into the same checkout cannot disagree with it. `claude plugin uninstall` +
`install` replaces the symlink with a copy again, so re-create it afterwards.
Hooks load at session start either way, so changes appear in the next session.

## License

MIT
