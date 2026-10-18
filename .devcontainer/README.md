# Dev container

A container for working on agent-apropos with Claude Code, permission prompts off,
without handing Claude the rest of the machine.

## Getting in

**Terminal:** `.devcontainer/start.sh` builds the image (first run only), starts
the container, and drops you into a shell. If the repo's `.git/config` has no
`user.name` or `user.email`, it asks for them first (defaulting to your global
git config), since the container can't see `~/.gitconfig`. Rerun it to get back in; the
container keeps running after you exit.

| Flag        | Effect |
|-------------|--------|
| `--rebuild` | Rebuild the image from scratch. This is also how Claude Code gets upgraded. |
| `--docker`  | Privileged mode with nested Docker. Read [Nested Docker](#nested-docker) first. |
| `-- CMD...` | Run `CMD` in the container instead of a shell, e.g. `start.sh --rebuild -- claude --resume`. Must come last. |

**VS Code:** *Dev Containers: Reopen in Container*. VS Code builds its own
container from the same `docker-compose.yml`, separate from the one
`start.sh` builds.

First time only: run `claude` inside and log in. The login lives in the
`agent-apropos-claude-config` volume, which every container for this repo
shares, so it survives rebuilds and covers both entry points.

## What the container can reach

| | |
|---|---|
| **Files** | Only this checkout, at `/workspace`, with the parts the host executes mounted read-only (see below). No host home directory, `~/.ssh` or `~/.claude`. |
| **SSH** | Your host ssh-agent, forwarded as a socket. `start.sh` starts an agent and runs `ssh-add` if it needs to. The container can use your key to sign, but it can't read or copy the key. GitHub's host keys are pinned in the image. |
| **GitHub API** | `GH_TOKEN=...` in `~/.config/NEXL-LTS/agent-apropos/gh.env` on the host, outside the checkout. A token exported in your shell isn't passed in. Use a fine-grained token scoped to this repo. The `env_file` entry needs Docker Compose 2.24 or later. |
| **Claude** | Its own config (the volume above), with `permissions.defaultMode = bypassPermissions`. Your host Claude settings are untouched. |
| **Network** | Unrestricted outbound. There's no egress firewall. |

There's no `sudo` in the container. Root could undo the read-only mounts, so
anything the project needs installed goes in the `Dockerfile`. For a one-off
root shell, use `docker compose exec --user root app bash` from the host, where
Claude can't.

## Read-only parts of the checkout

Claude runs with permission prompts off, so a prompt injection (in a web page,
an issue, a dependency's README) can run commands here. The container keeps
that away from your machine, except for files in the checkout that your host
later executes. Those are mounted read-only:

| Path | Why |
|---|---|
| `.git/hooks/` | Host git runs these on commit, checkout, merge and so on. |
| `.git/config` | Host git runs commands it names: `core.fsmonitor`, `core.sshCommand`, aliases, filters. |

Without `sudo`, not even root inside the container can remount them read-write.

What this costs:

- Anything that writes `.git/config` fails inside: `git push -u`, `git remote`,
  `git config`, branches that track a remote, `gh pr checkout`. Plain
  `git push` still works, because the image sets `push.default = current`. Do
  the rest on the host.
- After changing `.git/config` on the host, restart the container to pick it
  up: git replaces the file, and the mount keeps showing the old one.
- The checkout must be a regular clone. In a git worktree `.git` is a file,
  and the mounts fail.

Everything else in the checkout is still writable, and some of it can reach
your machine another way. `.devcontainer/` is the big one: it's writable so
agents can maintain it, but `start.sh` and the compose files run on the host,
so a prompt injection could plant code there that runs the next time you start
the container. Review changes to `.devcontainer/`, `.claude/`, `CLAUDE.md`,
`.vscode/` and CI workflows before you run `start.sh`, Claude, VS Code or a
build against them on the host.

## Project toolchain

Added for this repo (Crystal):

- **From the Ubuntu archive:** `build-essential`, `pkg-config`, the `lib*-dev` packages
  Crystal programs link against, `kcov`, `bats` with `bats-assert`/`bats-support`
  (`BATS_LIB_PATH=/usr/lib/bats`), and Node 22 for `jscpd`/`remark`.
- **Pinned and SHA-256 checked:** Crystal (`CRYSTAL_VERSION`, matching CI) and
  `jscpd` (`JSCPD_VERSION`, matching `package.json`). `universalmutator` is
  installed into `/opt/mutate` from `tool/mutate/requirements.txt` with hashes.
  Bumping a pin means changing the `Dockerfile` and `container-structure-test.yaml` together.
- **`cap_add: SYS_PTRACE` and `seccomp:unconfined`** in `docker-compose.yml`: `make coverage`
  (kcov) needs ptrace and `personality()`. The read-only mounts and the missing `sudo` are unaffected.
- **On every start** `postStartCommand.sh` runs `shards install`, `npm ci` and
  `make install` (agent-apropos into `~/.local/bin`), each only when its inputs changed.

## Commit checks

`lefthook.yml` runs `gitleaks` on staged changes before every commit made inside
the container. The hook is baked into the image (`.devcontainer/git-hooks/`,
enabled by `core.hooksPath` in `/etc/gitconfig`), because `.git/hooks` is
read-only. Commits made on the host aren't checked unless you install lefthook
there yourself. CI scans the full history on every push as a backstop.

## Nested Docker

`start.sh --docker` recreates the container as **privileged** and starts
`dockerd` inside it. A privileged container is not a security boundary: Claude
can use `dockerd` to become root, remount the read-only paths, and get root on
the host. Don't point Claude at untrusted content in this mode. Use it for the sessions
that need Docker, then run `start.sh` without the flag to go back to the
unprivileged container. VS Code never uses this mode.

## Changing the image

The image is `ubuntu:26.04`. Most tools come from Ubuntu's archive; `gh` and
`gitleaks` are too old there, so they're checksummed release binaries.

`container-structure-test.yaml` is the spec for the image. Each pinned tool has
a version test there, so when you bump a pin in the `Dockerfile` (version and
SHA-256), update its test in the same commit.

`smoke-test.sh` starts a real container the way `start.sh` does and checks it
end to end: SSH forwarding, the read-only mounts and missing `sudo`, Claude settings, the project toolchain, the commit hook,
nested Docker, and switching back to unprivileged. It runs in about 30 seconds
and cleans up after itself, using a throwaway Claude config volume so your login
is never touched.

CI (`.github/workflows/devcontainer-ci.yml`) runs both, plus a full-history
secret scan, on every push to `main` and every PR.
