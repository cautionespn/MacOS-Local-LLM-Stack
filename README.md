# llmstack-macos

A single shell script that turns a Mac into a private, self-hosted AI workstation.

Inference, a web front-end, and private web search — all running locally, all starting automatically at boot, without enabling auto-login.

```bash
./llmstack-macos.sh --recommend   # see what your Mac can run
./llmstack-macos.sh               # install it
```

---

## Contents

- [What it installs](#what-it-installs)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Modes](#modes)
- [Options](#options)
- [How models are chosen](#how-models-are-chosen)
- [The model catalogue](#the-model-catalogue)
- [Startup behaviour, and one real limitation](#startup-behaviour-and-one-real-limitation)
- [Remote SearXNG](#remote-searxng)
- [Shell commands](#shell-commands)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [File layout](#file-layout)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Design notes](#design-notes)
- [License](#license)

---

## What it installs

| Component | Role | Managed as |
|---|---|---|
| [Ollama](https://ollama.com) | Inference engine | System LaunchDaemon |
| [Open WebUI](https://github.com/open-webui/open-webui) | Web front-end | System LaunchDaemon |
| [SearXNG](https://github.com/searxng/searxng) | Private metasearch | Container (optional/remote) |
| [Draw Things](https://drawthings.ai) | Image & video generation | Mac App Store app (optional) |
| Homebrew, Python 3.11 | Dependencies | Installed if missing |
| Colima + docker CLI | Container runtime | Local SearXNG mode only |

Nothing leaves the machine except web searches, and those go through your own SearXNG instance rather than a commercial search API.

---

## Requirements

- **macOS on Apple Silicon** (M1 or later). Intel Macs are not supported.
- An **administrator account** — `sudo` is required to install system LaunchDaemons.
- **Xcode Command Line Tools** — the Homebrew installer prompts for these if missing.
- Signed in to the **Mac App Store**, if you want the Draw Things step.
- **Free disk space** for the model, typically 25–45 GB.

The script checks the first two itself and refuses to run on the wrong architecture rather than failing halfway through.

---

## Quick start

```bash
curl -O https://example.com/llmstack-macos.sh   # or clone the repo
chmod +x llmstack-macos.sh

# Inspect the machine first. Installs nothing, downloads nothing.
./llmstack-macos.sh --recommend

# Install.
./llmstack-macos.sh

# Load the shell commands.
exec zsh
```

Then open the URL the script prints — `http://<your-hostname>.local:8080` — and **create the admin account immediately**. Open WebUI grants owner rights to the first account created, so do this before anyone else on your network can.

Finally, turn on web search: **Admin → Settings → Web Search**, set *Enable* to on, choose `searxng` as the engine, and enter the SearXNG URL. The URL field only appears *after* you select the engine.

---

## Modes

| Mode | What it does |
|---|---|
| `--install` | Install or repair. Default when no mode is given. |
| `--update` | Update Ollama, Open WebUI, and the SearXNG image. Backs up data first, then reports how stale the model catalogue has become. `--upgrade` is a synonym. |
| `--status` | Print component health. Changes nothing. |
| `--recommend` | Print detected hardware and suitable models. Installs nothing. |
| `--uninstall` | Guided teardown, confirming every step. |
| `--help` | Full documentation. |

Every mode is safe to re-run. The installer checks state before acting and never overwrites existing data.

---

## Options

```
--searxng-url URL      Use an existing SearXNG instance instead of installing
                       one. Skips Colima and Docker entirely.

--searxng-port PORT    Host port for the local SearXNG container (default 8888).

--webui-port PORT      Port for Open WebUI (default 8080).

--model TAG            Install this model instead of the catalogue's pick.
                       Skips the fit check.

--no-model             Install the services without downloading a model.

--no-drawthings        Skip Draw Things.
```

Examples:

```bash
# Point at a SearXNG already running on a Linux box
./llmstack-macos.sh --searxng-url http://192.168.1.23:8899

# Services now, model later
./llmstack-macos.sh --no-model --no-drawthings

# Override the recommendation
./llmstack-macos.sh --model qwen3.6:27b
```

---

## How models are chosen

The script reads your chip, memory, and free disk, then picks the largest catalogue entry that genuinely suits the machine.

**Two gates, not one.** An entry must fit the memory budget *and* be sensible for the machine class:

- **Memory budget** — roughly 70% of unified memory is usable for model weights. The rest goes to macOS, the inference engine, and the KV cache. A 64 GB Mac has about a 44 GB budget.
- **Machine class** — each entry declares a minimum RAM tier. This exists because *fitting* and *running well* are different things. A 43 GB dense 70B model fits a 44 GB budget on paper, but on a Pro-tier chip it generates at reading speed at best. The gate keeps it off machines that can hold it but can't drive it.

**Why bandwidth matters more than you'd expect.** Token generation on Apple Silicon is memory-bandwidth-bound, not compute-bound. A dense model touches every parameter for every token. A mixture-of-experts (MoE) model activates only a fraction — `qwen3.6:35b-a3b` has 35B total parameters but roughly 3B active per token — so it generates far faster while still needing all 35B resident in memory. On base-tier chips this is decisive; the script's bandwidth note reflects your chip's tier.

Roughly what you can expect:

| Memory | Budget | Typical pick |
|---|---|---|
| 8–16 GB | 5–11 GB | small dense model |
| 24–32 GB | 16–22 GB | mid-size MoE |
| 48–64 GB | 33–44 GB | large MoE |
| 96 GB+ | 67 GB+ | dense 70B becomes viable |

---

## The model catalogue

Recommendations live in a plain text file you own:

```
~/.config/llmstack/models.catalog
```

It's written on first run and **never overwritten afterwards**, so your edits survive script upgrades. Format is pipe-delimited with `#` comments:

```
MIN_RAM_GB | TAG | SIZE_GB | ARCH | ROLE | VERIFIED | NOTES
```

```
48|qwen3.6:35b-a3b|24|moe|daily|yes|35B total, ~3B active per token.
```

### The date header

```
# Last-Updated: 2026-07-23
```

The script parses this and grades the file's age:

| Age | Reported as |
|---|---|
| under 90 days | recent enough, no action |
| 90–180 days | worth a look, newer models may fit better |
| over 180 days | very likely stale, review the library |

**Update the date when you edit the file.** That's the whole mechanism — it exists because local model releases move fast enough that a six-month-old recommendation is usually wrong.

### The VERIFIED column

`yes` means the tag was confirmed to exist in the Ollama registry. `no` means it's plausible but unconfirmed.

The script warns before pulling an unverified tag, and if the pull fails it points you at [ollama.com/library](https://ollama.com/library) and continues rather than aborting — everything else stays installed.

> **Be aware:** most entries in the shipped catalogue are marked `no`. Treat the file as a starting point to correct, not an authority. Fixing it for your own use is expected and takes about a minute.

---

## Startup behaviour, and one real limitation

**Ollama and Open WebUI survive reboots on a headless machine.** They're installed as *system* LaunchDaemons: they load in launchd's `system` domain at boot, require no console login, and are privilege-dropped via `UserName` so they run as you rather than as root. An SSH-only Mac comes back fully after a power cut, with no auto-login enabled.

**SearXNG in local mode cannot do this.** This is a macOS constraint, not a shortcoming of the script:

- **Docker Desktop** is a GUI application. Launching it over SSH fails — launchd rejects it with `Domain does not support specified action`.
- **Colima** manages a per-user virtual machine and socket, and is [not supported as a root or system-level daemon](https://github.com/abiosoft/colima). Running it as one starts the service but leaves it non-functional.

So in local mode, Colima and SearXNG start in the *user* domain and won't run after a reboot until someone logs in at the console. Ollama and Open WebUI will already be up; web search reports DOWN until then.

`llmstatus` shows Colima as its own line and explains this when it's down, so a dead search doesn't look like a broken container.

**If reboot-durable search matters, don't fight macOS — move SearXNG.** See below.

---

## Remote SearXNG

Run SearXNG on a Linux host, where Docker is a real systemd service that starts at boot with no session, and point this Mac at it:

```bash
./llmstack-macos.sh --searxng-url http://192.168.1.23:8899
```

This mode installs **no container runtime at all** on the Mac — no Colima, no docker CLI. The whole stack then survives reboots cleanly.

A minimal Compose definition for the Linux side:

```yaml
services:
  searxng:
    image: ghcr.io/searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "8899:8080"
    volumes:
      - ./settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - SEARXNG_BASE_URL=http://<host-ip>:8899/
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider",
             "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
```

With `settings.yml`:

```yaml
use_default_settings: true

server:
  secret_key: "generate-with-python3-secrets-token_hex-16"
  limiter: false
  image_proxy: true

search:
  formats:
    - html
    - json
```

The `json` format is **required** — Open WebUI parses results programmatically and gets nothing without it.

---

## Shell commands

Installed into `~/.zshrc` inside a marked block, so the uninstaller can remove them cleanly.

| Command | Does |
|---|---|
| `llmstatus` | Health of every component |
| `llmstart` | Start the stack |
| `llmstop` | Stop everything and reclaim memory |
| `llmupgrade` | Runs the script's `--update` mode |

```
$ llmstatus
Ollama      (:11434)   UP
Open WebUI  (:8080)    UP
SearXNG     (local)    UP
Colima      (runtime)  UP
```

`llmstop` is the point of the whole arrangement: a large model holds tens of gigabytes resident. When you need that memory for something else, stop the stack and start it again later.

Settings are read from `~/.config/llmstack/config` at call time, not baked into `.zshrc` — so changing the SearXNG URL means editing one line in one file.

The block is delimited by start and end markers. Re-running the installer **replaces** it rather than appending a second copy, backing up `.zshrc` first, and it recognises markers written by earlier versions of this tooling.

> **Use `exec zsh`, not `source ~/.zshrc`.** Sourcing cannot clear definitions already resident in a running shell. If an older install defined these as aliases, sourcing the new file mid-session produces `defining function based on alias` followed by a parse error. See [Troubleshooting](#defining-function-based-on-alias-llmstop--parse-error-in-zshrc).

---

## Updating

```bash
./llmstack-macos.sh --update
# or just:  llmupgrade
```

In order, it:

1. Backs up Open WebUI data to a timestamped directory
2. Stops both daemons
3. Upgrades Ollama via Homebrew
4. Upgrades Open WebUI via pip
5. Re-pulls and recreates the SearXNG container (local mode only)
6. Restarts everything
7. **Reports the catalogue's age** and whether a better-fitting model now exists for this machine

If the Open WebUI upgrade fails, the script restarts the existing version rather than leaving you with a dead stack, and tells you where the backup is.

> Backups are never auto-deleted. `--uninstall` offers to clear them; otherwise they accumulate, so prune them yourself occasionally.

---

## Uninstalling

```bash
./llmstack-macos.sh --uninstall
```

Walks every artifact one at a time. **Every prompt defaults to no** — pressing Enter skips the step. Deleting Open WebUI data requires two separate confirmations.

Never touched:

- **Homebrew, Python 3.11, and `mas`** — shared dependencies other software almost certainly uses
- **Remote SearXNG** — not this machine's to remove
- Anything you decline

Colima removal is its own prompt, since another project on the machine may want containers.

---

## File layout

```
~/.config/llmstack/config              installer settings
~/.config/llmstack/models.catalog      model catalogue (yours to edit)
~/.config/llmstack/openwebui-secret    persisted secret key, mode 0600
~/openwebui-venv/                      Open WebUI virtualenv
~/.local/share/open-webui/data/        accounts, chats, uploads, settings
~/.ollama/models/                      downloaded models
~/.searxng/settings.yml                SearXNG config (local mode)
/Library/LaunchDaemons/com.local.ollama.plist
/Library/LaunchDaemons/com.local.openwebui.plist
```

### Ports

| Service | Bind | Reachable from |
|---|---|---|
| Ollama | `127.0.0.1:11434` | this machine only |
| Open WebUI | `0.0.0.0:8080` | the LAN |
| SearXNG | `127.0.0.1:8888` | this machine only |

Open WebUI binds to all interfaces deliberately so phones and laptops can use it. **On a machine that joins untrusted networks, change this** — `--webui-port` doesn't alter the bind address, so edit the plist's `--host` argument to `127.0.0.1` and reload the daemon.

---

## Troubleshooting

Every item here is a failure that actually occurred during development, with the diagnosis that resolved it.

### `defining function based on alias 'llmstop'` / parse error in `.zshrc`

Older versions of this tooling defined `llmstop` and `llmstart` as **aliases**; current versions define them as **functions**. zsh expands a live alias while parsing a function of the same name, so the definition collapses into garbage and the parse fails.

Two separate causes, and they need different fixes.

**Stale definitions in the running shell.** Sourcing `.zshrc` cannot remove an alias that's already in memory — it persists until the shell is replaced. If the file is correct but the error persists:

```bash
alias llmstop        # prints something? it's stale session state
exec zsh             # replaces the shell; source is not enough
```

**A leftover block on disk.** Check for more than one:

```bash
grep -n 'LLM Stack Control\|alias llmstop\|^llmstop()' ~/.zshrc
```

Current versions of the script detect and remove blocks left by earlier versions, so re-running `--install` resolves this. Definitions found *outside* a marked block can't be removed automatically — the script reports them with line numbers for you to delete.

If nothing turns up in `.zshrc` itself, check what oh-my-zsh loads implicitly. With `ZSH_CUSTOM` unset it defaults to `$ZSH/custom`, and **every `.zsh` file there is sourced at startup**:

```bash
grep -rn "llmstop\|llmstart" ~/.oh-my-zsh/custom/ ~/.zshenv ~/.zprofile ~/.zlogin 2>/dev/null
```

### Open WebUI won't start: `Read-only file system: '/.webui_secret_key'`

Open WebUI is trying to write its session key to the filesystem root because `WEBUI_SECRET_KEY` isn't reaching the process. The script sets it in the daemon's `EnvironmentVariables`. Confirm it arrived:

```bash
sudo launchctl print system/com.local.openwebui | grep -A6 environment
```

If the key is absent, the value probably contained characters `launchctl` mishandled. Use hex only:

```bash
python3 -c "import secrets; print(secrets.token_hex(16))"
```

Base64 keys with `+` and `=` are silently dropped from the plist environment.

### Web search fails with `Too many open files`

macOS's default file-descriptor limit is too low for Open WebUI under search load. Both `SoftResourceLimits` and `HardResourceLimits` must be set to 65536 in the plist — the script does this. Verify:

```bash
sudo launchctl print system/com.local.openwebui | grep -A3 "resource limits"
```

### Your login stopped working after reinstalling

Almost certainly a `DATA_DIR` mismatch, not lost data. Open WebUI defaults to `~/.local/share/open-webui/data`, but an explicitly-set `DATA_DIR` elsewhere makes it create a *fresh, empty* database — your accounts are still in the original one. Find them:

```bash
find "$HOME" -name "webui.db" -exec ls -la {} \;
```

Point the daemon's `DATA_DIR` at the directory containing the *populated* database. Note that `webui.db-wal` must travel with `webui.db` — it holds recent writes not yet checkpointed, so copy the whole directory rather than the `.db` alone.

To check which account exists:

```bash
sqlite3 ~/.local/share/open-webui/data/webui.db "SELECT email FROM auth;"
```

To reset its password:

```bash
htpasswd -nBC 10 "" | tr -d ':\n'     # prompts, prints a bcrypt hash
sqlite3 ~/.local/share/open-webui/data/webui.db << 'EOF'
UPDATE auth SET password='<paste-hash>' WHERE email='<your-email>';
EOF
```

The quoted heredoc matters — it stops the shell from mangling the `$` characters in a bcrypt hash.

### `Bootstrap failed: 125: Domain does not support specified action`

You're in an SSH session and trying to load a *user* agent (`gui/$(id -u)/...`). Without a console login there's no GUI domain. Check:

```bash
launchctl print gui/$(id -u) >/dev/null 2>&1 && echo reachable || echo "NOT reachable"
```

This is exactly why the script uses system daemons. If you see this, you're targeting the wrong domain — use `sudo launchctl bootstrap system ...`.

### `Bootstrap failed: 5: Input/output error`

The service is already loaded. `bootout` first, wait, then `bootstrap`:

```bash
sudo launchctl bootout system/com.local.openwebui 2>/dev/null
sleep 2
sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.openwebui.plist
```

### SearXNG container restarts forever

Check whether `settings.yml` became a *directory*:

```bash
ls -ld ~/.searxng/settings.yml
```

Docker creates a directory at any bind-mount path that doesn't exist yet. If a container started before the config file was written, you get a directory that then blocks the file from being created. Remove it and re-run:

```bash
rmdir ~/.searxng/settings.yml
```

The script guards against this, but a manual `docker run` can still trigger it.

### SearXNG starts but nothing answers on the mapped port

The container listens on **8080** internally regardless of any `port:` setting in `settings.yml`. Map `8888:8080`, not `8888:8888`. Confirm with `docker logs searxng` — it prints the port it bound.

### `port is already allocated`

Something else holds it. Find what:

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | grep <port>
ss -tlnp | grep <port>          # Linux
lsof -nP -iTCP:<port> -sTCP:LISTEN   # macOS
```

Then re-run with `--searxng-port` or `--webui-port`.

### `open -a Docker` fails from SSH

Expected — see [the limitation section](#startup-behaviour-and-one-real-limitation). Docker Desktop can't launch into the Aqua session from SSH. Use Colima (which the script installs) or move SearXNG to a Linux host.

### Model pull fails

The tag is probably wrong or retired. Check [ollama.com/library](https://ollama.com/library), then correct `~/.config/llmstack/models.catalog` and bump its `Last-Updated` line. Everything else stays installed; just pull manually:

```bash
ollama pull <correct-tag>
```

---

## FAQ

**Does anything leave my machine?**
Only web searches, and only through your own SearXNG instance. Model inference is entirely local. No API keys, no telemetry, no per-token billing.

**Can I reach this from my phone?**
Yes. Open WebUI binds to `0.0.0.0`, so `http://<hostname>.local:8080` works from anything on the same network. Don't expose it to the internet without putting authentication in front of it.

**Why is it slow?**
Most likely a dense model on a bandwidth-limited chip. Try an MoE model, or check that you haven't overridden the catalogue with something too large. `--recommend` shows your chip's tier and what suits it.

**Can I run multiple models?**
Yes — `ollama pull` as many as you like and switch in Open WebUI's model picker. Ollama loads and unloads them on demand. Keeping two large models resident simultaneously needs the memory for both, so on tighter machines expect a reload pause when switching.

**Can I add more than one machine?**
Yes. In Open WebUI's **Connections** settings, add each machine's Ollama endpoint. You get their combined model list and can pick which backend serves a given chat.

**Can I pool memory across machines to run a bigger model?**
Technically yes, practically rarely worth it. Splitting a model across machines means every token's activations cross the network — even Thunderbolt bridging is an order of magnitude below on-package memory bandwidth. The result is usually *slower* than the same model on one machine. Only worth it when a model won't fit anywhere else.

**Why not Docker Desktop?**
It's a GUI app that can't be driven headlessly over SSH. Colima is CLI-native and much lighter. Neither can run as a system daemon on macOS.

**Why does it need sudo?**
To write to `/Library/LaunchDaemons/`. That's the only way to get services starting at boot without a login session. The daemons themselves drop privileges via `UserName` and don't run as root.

**Is it safe to re-run?**
Yes. Every step checks state first. Data, models, the secret key, and the catalogue are all preserved.

---

## Design notes

A few choices worth explaining, since they're the ones people tend to want to change first.

**System daemons over user agents, and no auto-login.** The straightforward way to get services running at boot on macOS is to enable auto-login so a user session exists. That means the machine boots to an unlocked desktop — unacceptable for a lot of people. System LaunchDaemons with `UserName` privilege-drop achieve the same durability without it. They're fiddlier to set up, which is much of what this script is for.

**pip over Docker for Open WebUI.** Docker on macOS runs inside a virtual machine. For a service that's just a Python web app, that's overhead with no isolation benefit worth paying for on a single-user machine.

**A catalogue file rather than hardcoded models.** Hardcoded recommendations rot silently. A dated file that the tooling reads and complains about makes the rot visible, and puts the fix in the hands of whoever is running it.

**Two gates on model selection.** Checking only "does it fit in memory" recommends dense 70B models to 64 GB machines that will run them at a crawl. The `MIN_RAM_GB` column encodes machine class separately from size.

---

## License

Public domain / CC0. Use it, fork it, sell it, no attribution required.

---

## Acknowledgements

Built on the work of the [Ollama](https://ollama.com), [Open WebUI](https://github.com/open-webui/open-webui), [SearXNG](https://github.com/searxng/searxng), and [Colima](https://github.com/abiosoft/colima) projects. This script only wires them together.
