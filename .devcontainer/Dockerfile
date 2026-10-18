# Spec + design notes for this image live in .devcontainer/container-structure-test.yaml.
# Ubuntu LTS, matching the host OS. Most tools come from its archive; only gh and
# gitleaks and Crystal, whose archive versions are too old, are fetched as pinned binaries below.
FROM ubuntu:26.04

# pipefail so `curl | tar` and friends fail loudly on a broken download.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

ARG USER_UID=1000
ARG USER_GID=1000

# From the Ubuntu archive:
#   • nodejs/npm (Node 22): only needed to install and run Claude Code.
#   • python3: for the ad-hoc scripts Claude writes and runs.
#   • gosu: the entrypoint runs as root (for dockerd) and drops to vscode with it.
#   • docker.io & co.: for `start.sh --docker` only. dockerd is started by
#     /entrypoint.sh when ENABLE_DOCKER=1, which compose.docker.yml sets alongside
#     privileged mode; otherwise the binaries sit unused.
#   • No sudo, on purpose: root inside the container could undo the read-only
#     mounts and anything else meant to hold Claude in. Tools a project needs
#     go in here, at build time.
#   • build-essential, pkg-config and the lib*-dev packages: what compiled Crystal
#     programs link against (openssl, libxml2, libyaml, gmp, pcre2, libevent, gc).
#   • kcov, bats and its assert/support libs, make: the coverage gate, the bats
#     suites and the Makefile targets (`make coverage`, `make check`).
#   • bubblewrap/socat: what Claude Code's Linux sandbox (/sandbox) runs on.
#     They won't run on hosts that restrict unprivileged user namespaces (Ubuntu's
#     kernel.apparmor_restrict_unprivileged_userns=1), not even with --docker. The
#     container is the sandbox here; they're installed for hosts where that's lifted.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bats \
    bats-assert \
    bats-support \
    bubblewrap \
    build-essential \
    ca-certificates \
    curl \
    docker-buildx \
    docker-compose-v2 \
    docker.io \
    git \
    gosu \
    iptables \
    jq \
    kcov \
    less \
    libevent-dev \
    libgc-dev \
    libgmp-dev \
    libpcre2-dev \
    libssl-dev \
    libxml2-dev \
    libyaml-dev \
    nodejs \
    npm \
    openssh-client \
    pkg-config \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    socat \
    unzip \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI: authenticates from GH_TOKEN in the host's ~/.config/NEXL-LTS/agent-apropos/gh.env.
ARG GH_VERSION=2.102.0
ENV GH_SHA256_AMD64=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386
ENV GH_SHA256_ARM64=7862c86c72f43df3a2d93ddde6f473285b4e2af61b494849846827e513ef6484
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    case "${ARCH}" in \
      amd64) SHA256="${GH_SHA256_AMD64}" ;; \
      arm64) SHA256="${GH_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: ${ARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
      -o /tmp/gh.tar.gz; \
    echo "${SHA256}  /tmp/gh.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tar.gz -C /tmp "gh_${GH_VERSION}_linux_${ARCH}/bin/gh"; \
    install -m755 "/tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_${ARCH}"; \
    gh --version

# gitleaks: run by the lefthook pre-commit hook so secrets never reach a commit.
ARG GITLEAKS_VERSION=8.30.1
ENV GITLEAKS_SHA256_AMD64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
ENV GITLEAKS_SHA256_ARM64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) GITLEAKS_ARCH=x64;   SHA256="${GITLEAKS_SHA256_AMD64}" ;; \
      arm64) GITLEAKS_ARCH=arm64; SHA256="${GITLEAKS_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $(dpkg --print-architecture)"; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GITLEAKS_ARCH}.tar.gz" \
      -o /tmp/gitleaks.tar.gz; \
    echo "${SHA256}  /tmp/gitleaks.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks; \
    rm /tmp/gitleaks.tar.gz; \
    gitleaks version

# lefthook: git hook runner, configured by /lefthook.yml.
ARG LEFTHOOK_VERSION=2.1.15
ENV LEFTHOOK_SHA256_AMD64=df981b477c236546435047fb8c8ee1f6f902e17faebb1b07b6bf2165832e8fe3
ENV LEFTHOOK_SHA256_ARM64=f3c881e1b6aa7f0461970173b1d692e0eb026bddfcd051cc87f636bf9a9782e0
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) LEFTHOOK_ARCH=x86_64; SHA256="${LEFTHOOK_SHA256_AMD64}" ;; \
      arm64) LEFTHOOK_ARCH=arm64;  SHA256="${LEFTHOOK_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $(dpkg --print-architecture)"; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      "https://github.com/evilmartians/lefthook/releases/download/v${LEFTHOOK_VERSION}/lefthook_${LEFTHOOK_VERSION}_Linux_${LEFTHOOK_ARCH}" \
      -o /usr/local/bin/lefthook; \
    echo "${SHA256}  /usr/local/bin/lefthook" | sha256sum -c -; \
    chmod +x /usr/local/bin/lefthook; \
    lefthook version

# Crystal: the repo needs >= 1.20 (CI pins 1.20.3); the archive has 1.18. The
# official tarball bundles the compiler and shards.
ARG CRYSTAL_VERSION=1.20.3
ENV CRYSTAL_SHA256_AMD64=b62ea25b247713fb63dc992beb459bcad8955465dcc11a181fd224d4ec955a62
ENV CRYSTAL_SHA256_ARM64=7fe729a8721401f22d7b4c1342c7599e7754b494a9808d70a8df94bff3579e05
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) CRYSTAL_ARCH=x86_64;  SHA256="${CRYSTAL_SHA256_AMD64}" ;; \
      arm64) CRYSTAL_ARCH=aarch64; SHA256="${CRYSTAL_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch: $(dpkg --print-architecture)"; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      "https://github.com/crystal-lang/crystal/releases/download/${CRYSTAL_VERSION}/crystal-${CRYSTAL_VERSION}-1-linux-${CRYSTAL_ARCH}.tar.gz" \
      -o /tmp/crystal.tar.gz; \
    echo "${SHA256}  /tmp/crystal.tar.gz" | sha256sum -c -; \
    mkdir /opt/crystal; \
    tar -xzf /tmp/crystal.tar.gz -C /opt/crystal --strip-components=1; \
    rm /tmp/crystal.tar.gz; \
    ln -s /opt/crystal/bin/crystal /opt/crystal/bin/shards /usr/local/bin/; \
    crystal --version

# jscpd: the `make dup` gate. Pinned to package.json's devDependency; bump both together.
# Installed globally so the gate also runs where node_modules isn't populated.
ARG JSCPD_VERSION=5.0.14
RUN npm install -g jscpd@"${JSCPD_VERSION}" && npm cache clean --force

# universalmutator: the engine behind the mutation gate (scripts/mutate.sh).
# Ubuntu's python3 is externally managed (PEP 668), so it gets its own venv.
# Versions and hashes live in the requirements file; --no-deps because the regex
# rules path uses only tabulate.
COPY tool/mutate/requirements.txt /tmp/mutate-requirements.txt
RUN python3 -m venv /opt/mutate && \
    /opt/mutate/bin/pip install --no-cache-dir --require-hashes --no-deps \
        -r /tmp/mutate-requirements.txt && \
    ln -s /opt/mutate/bin/mutate /usr/local/bin/mutate && \
    rm /tmp/mutate-requirements.txt

# bats-support/bats-assert from the archive land here; the specs resolve them
# through bats_load_library.
ENV BATS_LIB_PATH=/usr/lib/bats

# `make install` drops agent-apropos in ~/.local/bin; the edit-time hooks call it by name.
ENV PATH=/home/vscode/.local/bin:${PATH}

# Claude Code floats to latest on purpose: a rebuild should give you the CLI
# Anthropic currently ships, not one frozen when the image was first built.
# Auto-update is off because the global npm prefix is root-owned; rebuild to upgrade.
# Ubuntu's npm 9 predates the package.json `libc` filter, so it also installs the
# musl (Alpine) build of the CLI alongside the glibc one; drop that dead weight.
# hadolint ignore=DL3016
RUN npm install -g @anthropic-ai/claude-code \
    && rm -rf /usr/local/lib/node_modules/@anthropic-ai/claude-code/node_modules/@anthropic-ai/claude-code-linux-*-musl \
    && npm cache clean --force
ENV DISABLE_AUTOUPDATER=1

# Git hooks live in the image, not in the checkout: .git/hooks is mounted
# read-only (see docker-compose.yml) so nothing in the container can plant a hook
# that later runs on the host. Root-owned, so Claude can't edit them either.
COPY .devcontainer/git-hooks/ /usr/local/share/git-hooks/
RUN chmod 755 /usr/local/share/git-hooks/* && \
    git config --system core.hooksPath /usr/local/share/git-hooks && \
    # .git/config is read-only too, so `git push -u` can't record an upstream;
    # pushing to the same-named branch makes a plain `git push` work without one.
    git config --system push.default current

# Pin GitHub's SSH host keys (from https://api.github.com/meta) so the first
# `git push` neither prompts nor trusts whatever answers on port 22.
COPY .devcontainer/ssh_known_hosts /etc/ssh/ssh_known_hosts

# Create the `vscode` user with the host's UID/GID so bind-mounted files and the
# forwarded ssh-agent socket are owned by the same user on both sides. The
# ubuntu base image ships an `ubuntu` user at 1000:1000, which is renamed rather than duplicated.
RUN set -eux; \
    if [ "${USER_UID}" -eq 0 ] || [ "${USER_GID}" -eq 0 ]; then \
        echo "ERROR: USER_UID and USER_GID must not be 0 (got UID=${USER_UID} GID=${USER_GID})" >&2; \
        exit 1; \
    fi; \
    if getent group "${USER_GID}" > /dev/null; then \
        groupmod -n vscode "$(getent group "${USER_GID}" | cut -d: -f1)"; \
    else \
        groupadd -g "${USER_GID}" vscode; \
    fi; \
    if getent passwd "${USER_UID}" > /dev/null; then \
        existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
        [ "${existing_user}" = vscode ] || usermod -l vscode "${existing_user}"; \
        usermod -d /home/vscode -m -s /bin/bash -g "${USER_GID}" vscode; \
    else \
        useradd -l -m -d /home/vscode -s /bin/bash -g "${USER_GID}" -u "${USER_UID}" vscode; \
    fi; \
    # docker group: only matters with start.sh --docker, where dockerd runs. Access
    # to it is root-equivalent, which is why that mode is not a boundary.
    usermod -aG docker vscode

# Claude's config dir is a named volume (see docker-compose.yml) so the login
# survives rebuilds. Creating it here, vscode-owned, means Docker seeds a fresh
# volume with that ownership instead of root's.
ENV CLAUDE_CONFIG_DIR=/home/vscode/.claude
RUN mkdir -p /workspace "${CLAUDE_CONFIG_DIR}" && \
    chown vscode:vscode /workspace "${CLAUDE_CONFIG_DIR}"
WORKDIR /workspace

COPY .devcontainer/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# The entrypoint starts as root (for optional dockerd) and gosu-drops to vscode itself.
# hadolint ignore=DL3002
USER root
ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
