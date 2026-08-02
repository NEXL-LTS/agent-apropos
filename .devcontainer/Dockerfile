FROM ubuntu:24.04

ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

# Use bash with pipefail so failures in piped RUN commands (e.g. `curl … | bash`)
# propagate instead of being masked by the last command's exit status.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# GitHub CLI keyring fetched via ADD instead of curl; the apt install below
# references it. It is already dearmored, so no processing is needed.
ADD https://cli.github.com/packages/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg

# System packages: base tooling, the GitHub CLI, and the native libraries
# Crystal shards commonly link against (openssl, libxml2, libyaml, gmp,
# pcre2, libevent). Merged into a single layer; apt package lists are
# dropped after each apt step to keep the image small.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        fd-find \
        git \
        gnupg \
        jq \
        libevent-dev \
        libgmp-dev \
        libpcre2-dev \
        libssl-dev \
        libxml2-dev \
        libyaml-dev \
        libz-dev \
        lsb-release \
        openssh-client \
        pkg-config \
        ripgrep \
        sudo \
        unzip \
        vim \
        wget \
        zip && \
    rm -rf /var/lib/apt/lists/* && \
    # GitHub CLI (gh); keyring added above
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/* && \
    # Crystal — official install script adds the openSUSE Build Service apt
    # repo and installs the latest stable `crystal` package (bundles shards).
    curl -fsSL https://crystal-lang.org/install.sh | bash && \
    rm -rf /var/lib/apt/lists/*

# Node.js — runtime for the npm-distributed CLI agents below (Gemini CLI,
# Codex CLI, GitHub Copilot CLI all require Node 20+; NodeSource is used
# since Ubuntu 24.04's apt-provided nodejs is too old).
ARG NODE_MAJOR=24
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*
ARG NPM_VERSION=12.0.1
RUN npm install -g npm@"${NPM_VERSION}"

# jscpd — the code-duplication gate for src/**/*.cr (see .jscpd.json and
# `make dup`). Pinned to the same version as package.json's devDependency;
# bump both together.
ARG JSCPD_VERSION=5.0.14
RUN npm install -g jscpd@"${JSCPD_VERSION}"

# kcov — the coverage gate. Ubuntu 24.04 dropped the `kcov` package,
# so it is built from a pinned release rather than installed from apt. python3
# is needed only by kcov's build-time code generation; libdw/libcurl/binutils/elf
# are its link- and run-time dependencies (kept so the built binary runs).
#
# Runtime note: kcov drives the target under ptrace and calls personality() to
# disable ASLR, both of which the default container sandbox blocks. The
# devcontainer therefore runs with cap_add SYS_PTRACE and seccomp:unconfined —
# see .devcontainer/docker-compose.yml. Without those flags kcov fails with
# "Can't set personality: Operation not permitted".
ARG KCOV_VERSION=v43
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        binutils-dev \
        cmake \
        libcurl4-openssl-dev \
        libdw-dev \
        libelf-dev \
        libiberty-dev \
        python3 && \
    rm -rf /var/lib/apt/lists/* && \
    git clone --depth 1 --branch "${KCOV_VERSION}" \
        https://github.com/SimonKagstrom/kcov.git /tmp/kcov && \
    cmake -S /tmp/kcov -B /tmp/kcov/build \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build /tmp/kcov/build --parallel "$(nproc)" && \
    cmake --install /tmp/kcov/build && \
    rm -rf /tmp/kcov

# bats-core — the shell test framework used by the end-to-end suite
# (e2e/tests/*.bats). Installed from pinned releases: bats-core provides the
# `bats` runner; the bats-support + bats-assert helper libraries are cloned into
# the standard library dir and resolved at load time via BATS_LIB_PATH
# (bats_load_library). Ubuntu ships an older bats without bats_load_library and
# no helper libs, so it is installed from source like kcov above.
ARG BATS_CORE_VERSION=v1.11.1
ARG BATS_SUPPORT_VERSION=v0.3.0
ARG BATS_ASSERT_VERSION=v2.1.0
RUN git clone --depth 1 --branch "${BATS_CORE_VERSION}" \
        https://github.com/bats-core/bats-core.git /tmp/bats-core && \
    /tmp/bats-core/install.sh /usr/local && \
    rm -rf /tmp/bats-core && \
    mkdir -p /usr/local/lib/bats && \
    git clone --depth 1 --branch "${BATS_SUPPORT_VERSION}" \
        https://github.com/bats-core/bats-support.git /usr/local/lib/bats/bats-support && \
    git clone --depth 1 --branch "${BATS_ASSERT_VERSION}" \
        https://github.com/bats-core/bats-assert.git /usr/local/lib/bats/bats-assert && \
    rm -rf /usr/local/lib/bats/*/.git
ENV BATS_LIB_PATH=/usr/local/lib/bats

WORKDIR /workspace

# Create user with matching UID/GID. Ubuntu 24.04 ships with a default
# `ubuntu` user at UID 1000, so we handle rename/renumber cases explicitly
# instead of assuming useradd will succeed.
RUN set -eux; \
    # 1. Handle the group for USER_GID
    if getent group "${USER_GID}" > /dev/null; then \
        # A group with this GID exists already; rename it to 'vscode' if needed
        existing_group="$(getent group "${USER_GID}" | cut -d: -f1)"; \
        if [ "${existing_group}" != "vscode" ]; then \
            groupmod -n vscode "${existing_group}"; \
        fi; \
    # No group with this GID yet; either rename existing 'vscode' group or create it
    elif getent group vscode > /dev/null; then \
        groupmod -g "${USER_GID}" vscode; \
    else \
        groupadd -g "${USER_GID}" vscode; \
    fi; \
    \
    # 2. Handle the user for USER_UID
    if getent passwd "${USER_UID}" > /dev/null; then \
        # A user with this UID exists; rename it to 'vscode' if needed
        existing_user="$(getent passwd "${USER_UID}" | cut -d: -f1)"; \
        if [ "${existing_user}" != "vscode" ]; then \
            usermod -l vscode "${existing_user}"; \
        fi; \
        # Ensure home dir is /home/vscode and move contents if necessary
        usermod -d /home/vscode -m vscode; \
        # Ensure primary group is our vscode group
        usermod -g "${USER_GID}" vscode; \
    # No user with this UID yet
    # 'vscode' exists but with a different UID; update it
    elif id -u vscode >/dev/null 2>&1; then \
        usermod -u "${USER_UID}" -g "${USER_GID}" -d /home/vscode -m vscode; \
    else \
        # Create new vscode user (-l: don't add a lastlog/faillog entry for the high UID)
        useradd -l -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" vscode; \
    fi; \
    \
    # 3. Sudoers
    echo 'vscode ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/vscode

USER vscode

RUN mkdir -p /home/vscode/.local
RUN mkdir -p /home/vscode/.cache

ENV PATH=/home/vscode/.local/bin:$PATH
