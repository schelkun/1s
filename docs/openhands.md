# OpenHands

## Users

`OPENHANDS_USERS=alice:443,bob:8444` creates one isolated Agent Canvas instance
per user at `https://OPENHANDS_DOMAIN:<port>/`. Each instance has its own API key:

```bash
scripts/macos/server.sh openhands key alice    # on your Mac
sudo 1s openhands key alice                    # on the server
```

The key is entered once on the first visit. Agent Canvas does not embed it in
the page, because `AGENT_CANVAS_ALLOW_LAN_SESSION_KEY=false`.

> **Upstream issue, worked around.** Agent Canvas 1.33.0 documents
> `LOCAL_BACKEND_API_KEY`, but when only that variable is set, the Agent Server
> API answers **without authentication** (verified while building this
> repository). 1s sets `OH_SESSION_API_KEYS_0` instead. Every deployment and
> health check fails if an unauthenticated API request does not get 401.

Each user also needs the port open in any cloud firewall in front of the server.
To add or remove a user, edit `OPENHANDS_USERS`, run `push-config.sh`, then
deploy `openhands`.

## Agent backends

Agent Canvas runs these agents through the Agent Client Protocol (ACP). Pick one
in the UI (Settings → Agent):

| Agent | Self-hosted Docker backend | Credential (Settings → Secrets, global secret name) |
|---|---|---|
| OpenHands (default) | yes | an LLM API key, configured in Settings → LLM |
| Claude Code | yes | `ANTHROPIC_API_KEY`, or `CLAUDE_CODE_OAUTH_TOKEN` (Pro/Max subscription token) |
| Codex | yes | `OPENAI_API_KEY`, or `CODEX_AUTH_JSON` (contents of `~/.codex/auth.json` after `codex login`) |
| Gemini CLI | yes | `GEMINI_API_KEY`, or `GOOGLE_APPLICATION_CREDENTIALS_JSON` + `GOOGLE_CLOUD_PROJECT` + `GOOGLE_CLOUD_LOCATION` + `GOOGLE_GENAI_USE_VERTEXAI` |
| OpenCode | yes | `OPENCODE_API_KEY` or `OPENCODE_AUTH_CONTENT` (works without credentials on free models) |
| Pi | yes | `ANTHROPIC_API_KEY` or `PI_AUTH_JSON` |
| Other ACP agents | yes | a custom ACP launch command, plus whatever that agent needs |

- Subscription logins from your Mac are not visible inside the container. Paste the exported token or JSON as a secret.
- The agent CLIs are started with `npx`, so the container needs outbound HTTPS to npm and to the provider API. The egress filter blocks only private, link-local and metadata ranges.
- Credentials are per user: they live in that user's instance, encrypted with that user's `OH_SECRET_KEY`.

## Isolation and its limits

- One hardened container per user:
  - unprivileged `openhands` user, `cap_drop: ALL`, `no-new-privileges` (so the image's passwordless sudo does not work)
  - no Docker socket and no host mounts
  - CPU, memory and PID limits
  - a private network, with egress to private ranges and host services blocked
- `OPENHANDS_AGENT_SUDO=true` lets agents use `sudo` (for example `apt-get install`) inside their own container. This weakens the boundary. Prefer `pip install --user`, `npm` prefixes or `uv` without root.
- The agent **cannot run Docker** in the default setup. Upstream only supports that with `--privileged`, which this repository does not do.
- A container is not a VM. For hostile users or code, run a separate VM per user with its own Agent Server, which Canvas supports as a remote backend. You can also try gVisor through `/etc/1s/overrides/openhands.yml`. Upstream tests neither.

## Gitea integration (optional)

By default agents **cannot** reach Gitea. To let them clone and push:

1. Set `OPENHANDS_ALLOW_GITEA=true` and deploy `openhands`, then `gitea`. The
   OpenHands address pool is added to the Gitea web allowlist and the
   Git-over-SSH firewall exception.
2. In Gitea, create a dedicated bot user per OpenHands user, with an access
   token scoped to `write:repository` on the repositories it needs.
3. In that user's Agent Canvas, add the token as a secret (for example
   `GITEA_TOKEN`). Tell the agent to use
   `https://<bot>:${GITEA_TOKEN}@git.example.com/owner/repo.git`.
4. Gitea Actions then runs CI on the pull requests the agent opens, as for any other user.

### Issue → Agent → Pull request → CI

Agent Canvas has an Automation Server for scheduled and event-triggered
runs. Gitea can send webhooks. Fully automated "issue label → agent run → pull
request" needs a small bridge service. It would receive Gitea webhooks, call the
Automation API with the user's key, and report back. That is a separate component
with its own security decisions: which user's agent runs, and on which
repositories. It is **not implemented** here. Ask for it explicitly if you want it.
