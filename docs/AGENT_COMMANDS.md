# AgentDeck terminal guide

AgentDeck Companion owns the agent process and PTY. The same session can then
stream to the local terminal and paired iPhones without creating a duplicate
provider session.

## Install

### Homebrew (recommended)

```bash
brew install --cask mesutcydev/agentdeck/agentdeck
```

This installs **AgentDeck Companion.app** and exposes the bundled `agentdeck`
command on `PATH`.

Upgrade or remove it with:

```bash
brew upgrade --cask agentdeck
brew uninstall --cask agentdeck
```

### Verified installer fallback

Download the installer from the latest GitHub release, inspect it, then run it:

```bash
curl --fail --location --proto '=https' --tlsv1.2 \
  https://github.com/Mesutcydev/AgentDeck/releases/latest/download/install.sh \
  --output /tmp/install-agentdeck.sh
less /tmp/install-agentdeck.sh
bash /tmp/install-agentdeck.sh
```

The installer downloads the Companion DMG and refuses installation if its
SHA-256 checksum, bundle identifier, Developer ID signature, notarization
ticket, or Gatekeeper assessment is invalid.

If the fallback install reports that `~/.local/bin` is not on `PATH`, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## First check

```bash
agentdeck open
agentdeck doctor
agentdeck status
```

- `open` starts or focuses the Companion.
- `doctor` reports which supported provider CLIs are installed and usable.
- `status` confirms that the local AgentDeck control service is available.

## Start an agent

Use `agentdeck run` instead of starting the provider directly. AgentDeck owns
the session from launch, so it immediately appears in the Companion and iOS
apps with streaming output, approvals, history, and reconnection.

```bash
agentdeck run claude
agentdeck run codex
agentdeck run grok
agentdeck run kimi
agentdeck run opencode
```

The current directory is used as the project by default. Choose another folder
with `--project`:

```bash
agentdeck run claude --project ~/Developer/MyApp
agentdeck run codex --project ~/Developer/API
```

Pass provider-specific arguments after `--`:

```bash
agentdeck run claude --project ~/Developer/MyApp -- --model sonnet
agentdeck run codex --project ~/Developer/MyApp -- --full-auto
```

Arguments are transferred directly to the provider adapter; AgentDeck does not
construct or evaluate a shell command.

## List and reattach sessions

```bash
agentdeck sessions
agentdeck attach SESSION_ID
```

`sessions` prints the AgentDeck session ID, provider, state, origin, and project.
While attached, press **Control-]** to detach the local terminal. Detaching does
not stop the agent; the session keeps running in the Companion and remains
available on iOS.

## Import a session started outside AgentDeck

Interactive discovery:

```bash
agentdeck import
```

Limit the resumed session to a project:

```bash
agentdeck import --project ~/Developer/MyApp
```

Or import a known provider-native session explicitly:

```bash
agentdeck import claude EXTERNAL_SESSION_ID --project ~/Developer/MyApp
agentdeck import codex EXTERNAL_SESSION_ID --project ~/Developer/MyApp
```

AgentDeck never steals or kills an active Terminal PTY. If the original process
is still active, finish or exit it first. Claude Code and Codex use verified
provider-native resume support. Providers without verified resume support offer
a related new AgentDeck session instead of claiming that the old PTY was
attached.

## Command reference

| Command | Purpose |
| --- | --- |
| `agentdeck status` | Show Companion/local-control status. |
| `agentdeck open` | Launch or focus AgentDeck Companion. |
| `agentdeck doctor` | Check Companion and installed provider CLIs. |
| `agentdeck run PROVIDER` | Start a provider session owned by AgentDeck. |
| `agentdeck sessions` | List remembered and active sessions. |
| `agentdeck attach ID` | Attach the current terminal to an AgentDeck session. |
| `agentdeck import` | Discover and safely resume external provider sessions. |
| `agentdeck help` | Print the concise command summary. |

## Recommended daily workflow

```bash
cd ~/Developer/MyApp
agentdeck doctor
agentdeck run claude
```

Continue the session from iPhone when needed. Later, from any local terminal:

```bash
agentdeck sessions
agentdeck attach SESSION_ID
```

## Troubleshooting

**`command not found: agentdeck`**

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Homebrew installs should already expose the binary through Homebrew's prefix.

**Companion is not running**

```bash
open -a "AgentDeck Companion"
agentdeck status
```

**A provider is missing**

```bash
agentdeck doctor
which claude codex grok kimi opencode
```

Install the missing provider through its official distribution channel, then
restart or refresh AgentDeck Companion.

**An external session cannot be imported**

Exit the original provider process first. If the installed provider version
does not expose a compatible native resume identifier, start a related session:

```bash
agentdeck run PROVIDER --project /path/to/project
```
