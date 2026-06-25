# =============================================================================
# Version pins — update here only
# =============================================================================
ARG GCM_VERSION=2.8.0
ARG BAO_VERSION=2.5.5

ARG NODE_VERSIONS="22 24"
ARG NODE_DEFAULT=24

ARG GO_VERSIONS="1.26.0"
ARG GO_DEFAULT=1.26.0

# GCM cache timeout in seconds (default: 30 days)
ARG GCM_CACHE_TIMEOUT=2592000

# =============================================================================
# Base image + system packages — single RUN to minimise layers
# =============================================================================
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG GCM_VERSION
ARG BAO_VERSION
ARG NODE_VERSIONS
ARG NODE_DEFAULT
ARG GO_VERSIONS
ARG GO_DEFAULT
ARG GCM_CACHE_TIMEOUT

# GID of the host's Docker socket (DooD). On Docker Desktop for Mac this is
# typically root-owned inside the VM regardless of host-side ownership —
# verify with `ls -la ~/.docker/run/docker.sock` on the host. Default 0 (root)
# matches the common Docker Desktop for Mac case.
ARG DOCKER_GID=0

ARG USERNAME=vscode
ARG USER_HOME=/home/${USERNAME}

ENV DEBIAN_FRONTEND=noninteractive

# Puppeteer/Playwright: use the system/Playwright-managed browser rather than
# triggering Puppeteer's own Chromium download.
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# =============================================================================
# System packages: build prereqs, chromium, Docker CLI (DooD), GCM,
# Xvfb/x11vnc for headful debugging.
# =============================================================================
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       pass gpg git libssl-dev pkg-config ca-certificates curl \
       software-properties-common \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    \
    # --- Chromium, chrome-driver (system browser, driver used by Puppeteer via PUPPETEER_EXECUTABLE_PATH) ---
    && add-apt-repository ppa:xtradeb/apps -y \
    && apt-get update \
    && apt-get install -y --no-install-recommends chromium chromium-driver \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    \
    # --- Xvfb + x11vnc for headful browser debugging ---
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       xvfb \
       x11-utils \
       x11vnc \
    && mkdir -p /tmp/.X11-unix \
    && chmod 1777 /tmp/.X11-unix \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    \
    # --- Docker CLI only (no daemon) — DooD talks to the host/Docker Desktop
    #     VM daemon via the bind-mounted socket; Testcontainers inside this
    #     devcontainer launches sibling service containers on that daemon,
    #     exactly as it would on a bare GHA runner. ---
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       docker-ce-cli \
       docker-buildx-plugin \
       docker-compose-plugin \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    \
    # --- Git Credential Manager ---
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL \
       "https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux-${ARCH}-${GCM_VERSION}.deb" \
       -o /tmp/gcm.deb \
    && apt-get install -y /tmp/gcm.deb \
    && rm /tmp/gcm.deb \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# =============================================================================
# Verify PUPPETEER_EXECUTABLE_PATH exists
# =============================================================================
RUN if [ ! -x "$PUPPETEER_EXECUTABLE_PATH" ]; then \
        echo "Error: Chromium not found at $PUPPETEER_EXECUTABLE_PATH"; \
        exit 1; \
    fi

# =============================================================================
# OpenBao CLI — secrets management
# =============================================================================
RUN BAO_ARCH=$(dpkg --print-architecture) \
    && case "${BAO_ARCH}" in \
         amd64) BAO_ARCH="x86_64" ;; \
         arm64) BAO_ARCH="arm64" ;; \
         *) echo "Unsupported arch: ${BAO_ARCH}"; exit 1 ;; \
       esac \
    && curl -fsSL \
       "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/bao_${BAO_VERSION}_Linux_${BAO_ARCH}.tar.gz" \
       -o /tmp/bao.tar.gz \
    && tar -xzf /tmp/bao.tar.gz -C /usr/local/bin bao \
    && rm /tmp/bao.tar.gz \
    && bao --version

# =============================================================================
# Playwright / Puppeteer system dependencies
#
# This installs the ~220 apt packages browsers need to render (codecs, font
# rendering, GTK, gstreamer, etc.) using Playwright's own OS-aware dependency
# resolver — far more reliable than hand-curating package names/versions,
# which drift between Ubuntu releases.
#
# IMPORTANT: this only installs *system libraries*. It does NOT install the
# playwright/puppeteer npm packages or browser binaries — those belong to
# each project's own node_modules and are installed by each project's own
# `npm install` + `npx playwright install`. This keeps the devcontainer a
# general-purpose web-dev base rather than coupled to one project's
# dependency versions.
#
# A throwaway system Node + global playwright package is used purely to
# invoke `install-deps`, then removed.
# =============================================================================
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g playwright \
    && npx playwright install-deps chromium \
    && npx playwright install-deps firefox \
    && npx playwright install-deps webkit \
    && npm uninstall -g playwright \
    && apt-get remove -y --purge nodejs \
    && apt-get autoremove -y --purge \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.npm /usr/lib/node_modules

# =============================================================================
# nvm + Node — installed as the non-root user
# =============================================================================
ENV NVM_DIR=${USER_HOME}/.nvm

USER ${USERNAME}
WORKDIR ${USER_HOME}

# Install nvm and all Node versions in one layer, then strip:
#   - npm caches
#   - unused man pages and docs bundled with each node install
RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && bash -c " \
        source \${NVM_DIR}/nvm.sh \
        && for v in ${NODE_VERSIONS}; do \
               nvm install \$v \
               && nvm exec \$v npm cache clean --force; \
           done \
        && nvm alias default ${NODE_DEFAULT} \
        && nvm cache clear \
    " \
    && find ${USER_HOME}/.nvm/versions -type d -name 'man' -exec rm -rf {} + 2>/dev/null || true \
    && find ${USER_HOME}/.nvm/versions -type d -name 'doc' -exec rm -rf {} + 2>/dev/null || true \
    && find ${USER_HOME}/.nvm/versions -type d -name 'include' -exec rm -rf {} + 2>/dev/null || true

# =============================================================================
# goenv + Go — installed as the non-root user
# =============================================================================
ENV GOENV_ROOT=${USER_HOME}/.goenv
ENV GOPATH=${USER_HOME}/go
ENV PATH="${GOENV_ROOT}/bin:${PATH}"

# Install goenv and all Go versions in one layer, then strip build artifacts,
# test files, and src trees (not needed at runtime in a devcontainer for
# running Go — only needed if you're building Go itself).
RUN git clone --depth=1 https://github.com/go-nv/goenv.git ${GOENV_ROOT} \
    && bash -c " \
        eval \"\$(goenv init -)\" \
        && for v in ${GO_VERSIONS}; do goenv install \$v; done \
        && goenv global ${GO_DEFAULT} \
    " \
    && find ${GOENV_ROOT}/versions -type d -name 'test' -exec rm -rf {} + 2>/dev/null || true \
    && find ${GOENV_ROOT}/versions -type d -name 'testdata' -exec rm -rf {} + 2>/dev/null || true \
    && find ${GOENV_ROOT}/versions -mindepth 3 -maxdepth 3 -name 'src' -type d -exec rm -rf {} + 2>/dev/null || true \
    && find ${GOENV_ROOT}/versions -name '*.a' -delete 2>/dev/null || true \
    && rm -rf ${GOENV_ROOT}/.git

# =============================================================================
# GCM — system config as root
# =============================================================================
USER root
RUN git-credential-manager configure \
    && git config --system credential.gitHubAuthModes devicecode \
    && git config --system credential.credentialStore cache \
    && git config --system credential.cacheOptions "--timeout ${GCM_CACHE_TIMEOUT}" \
    && chmod 644 /etc/gitconfig

# =============================================================================
# DooD — give vscode access to the bind-mounted host Docker socket.
#
# On Docker Desktop for Mac, the socket as seen *inside* this container is
# owned by root:root regardless of its apparent ownership on the macOS side
# (Docker Desktop's VM presents its own internal ownership, not a host
# UID/GID translation). DOCKER_GID therefore defaults to 0 (root) — joining
# vscode to GID 0 is the standard, narrow fix for this specific scenario.
# Verified safe: no unexpected group-writable files exist outside the
# intentionally-mounted sockets (checked via
# `find / -xdev -group root -perm -020 -type f`).
# =============================================================================
RUN if getent group ${DOCKER_GID} > /dev/null; then \
        EXISTING_GROUP=$(getent group ${DOCKER_GID} | cut -d: -f1); \
        usermod -aG ${EXISTING_GROUP} ${USERNAME}; \
    else \
        groupadd -g ${DOCKER_GID} docker-host \
        && usermod -aG docker-host ${USERNAME}; \
    fi

# Pre-create the Playwright cache dir with correct ownership so the named
# volume mounted here (see compose) comes up owned by vscode, not root.
RUN mkdir -p ${USER_HOME}/.cache \
    && chown ${USERNAME}:${USERNAME} ${USER_HOME}/.cache \
    && mkdir -p ${USER_HOME}/.cache/ms-playwright \
    && chown -R ${USERNAME}:${USERNAME} ${USER_HOME}/.cache/ms-playwright

# =============================================================================
# Shell profiles
# =============================================================================
USER ${USERNAME}

RUN <<'EOF' tee -a ${USER_HOME}/.bashrc
# chrome
export CHROME_BIN=/usr/bin/chromium
export CHROMEDRIVER_BIN=/usr/bin/chromedriver

# nvm
export NVM_DIR="${HOME}/.nvm"
[ -s "${NVM_DIR}/nvm.sh" ] && \. "${NVM_DIR}/nvm.sh"

# goenv
export GOENV_ROOT="${HOME}/.goenv"
export GOPATH="${HOME}/go"
export GOENV_DISABLE_GOPATH=1
export PATH="${GOENV_ROOT}/bin:${PATH}"
eval "$(goenv init -)"
export PATH="${PATH}:${GOPATH}/bin"

# auto-switch on directory change (bash: aliases cover interactive use)
_load_versions() {
    local node_version
    node_version="$(nvm version)"
    local nvmrc_path
    nvmrc_path="$(nvm_find_nvmrc)"

    if [[ -n "$nvmrc_path" ]]; then
        local nvmrc_node_version
        nvmrc_node_version="$(nvm version "$(cat "${nvmrc_path}")")"
        if [[ "$nvmrc_node_version" == "N/A" ]]; then
            nvm install
        elif [[ "$nvmrc_node_version" != "$node_version" ]]; then
            nvm use
        fi
    elif [[ "$node_version" != "$(nvm version default)" ]]; then
        echo "Reverting to nvm default version"
        nvm use default
    fi

    if [[ -f .go-version && -r .go-version ]]; then
        goenv local "$(cat .go-version)"
    fi
}
alias cd='_load_versions_cd() { command cd "$@" && _load_versions; }; _load_versions_cd'
alias pushd='_load_versions_pushd() { command pushd "$@" && _load_versions; }; _load_versions_pushd'
alias popd='_load_versions_popd() { command popd "$@" && _load_versions; }; _load_versions_popd'

# --- Xvfb + x11vnc on-demand helpers for headful browser debugging ---
# DISPLAY=:99 is set globally via ENV in the image. Headless test runs are
# unaffected; only headful runs (headless:false / page.pause()) need
# xvfb-start first. Connect a VNC client to localhost:5900 to watch live.
xvfb-start() {
    export DISPLAY=:99
    if ! pgrep -f "Xvfb :99" > /dev/null; then
        Xvfb :99 -screen 0 1920x1080x24 &
        sleep 1
        echo "Xvfb started on :99"
    else
        echo "Xvfb already running on :99"
    fi

    if ! pgrep -f "x11vnc.*:99" > /dev/null; then
        x11vnc -display :99 -forever -shared -nopw -quiet &
        echo "x11vnc started, connect on port 5900"
    else
        echo "x11vnc already running"
    fi
}

xvfb-stop() {
    unset DISPLAY
    pkill -f "x11vnc.*:99"
    pkill -f "Xvfb :99"
    echo "Xvfb and x11vnc stopped"
}
EOF

RUN <<'EOF' tee -a ${USER_HOME}/.zshrc
# chrome
export CHROME_BIN=/usr/bin/chromium
export CHROMEDRIVER_BIN=/usr/bin/chromedriver

# nvm
export NVM_DIR="${HOME}/.nvm"
[ -s "${NVM_DIR}/nvm.sh" ] && \. "${NVM_DIR}/nvm.sh"

# goenv
export GOENV_ROOT="${HOME}/.goenv"
export GOPATH="${HOME}/go"
export GOENV_DISABLE_GOPATH=1
export PATH="${GOENV_ROOT}/bin:${PATH}"
eval "$(goenv init -)"
export PATH="${PATH}:${GOPATH}/bin"

# auto-switch on any directory change (chpwd fires for cd, pushd, popd, and programmatic changes)
_load_versions() {
    local node_version
    node_version="$(nvm version)"
    local nvmrc_path
    nvmrc_path="$(nvm_find_nvmrc)"

    if [[ -n "$nvmrc_path" ]]; then
        local nvmrc_node_version
        nvmrc_node_version="$(nvm version "$(cat "${nvmrc_path}")")"
        if [[ "$nvmrc_node_version" == "N/A" ]]; then
            nvm install
        elif [[ "$nvmrc_node_version" != "$node_version" ]]; then
            nvm use
        fi
    elif [[ "$node_version" != "$(nvm version default)" ]]; then
        echo "Reverting to nvm default version"
        nvm use default
    fi

    if [[ -f .go-version && -r .go-version ]]; then
        goenv local "$(cat .go-version)"
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _load_versions

# Run once on shell startup to handle the initial working directory
_load_versions

# --- Xvfb + x11vnc on-demand helpers for headful browser debugging ---
xvfb-start() {
    export DISPLAY=:99
    if ! pgrep -f "Xvfb :99" > /dev/null; then
        Xvfb :99 -screen 0 1920x1080x24 &
        sleep 1
        echo "Xvfb started on :99"
    else
        echo "Xvfb already running on :99"
    fi

    if ! pgrep -f "x11vnc.*:99" > /dev/null; then
        x11vnc -display :99 -forever -shared -nopw -quiet &
        echo "x11vnc started, connect on port 5900"
    else
        echo "x11vnc already running"
    fi
}

xvfb-stop() {
    unset DISPLAY
    pkill -f "x11vnc.*:99"
    pkill -f "Xvfb :99"
    echo "Xvfb and x11vnc stopped"
}
EOF

# =============================================================================
# Final working directory
# =============================================================================
WORKDIR /workspace
CMD ["sleep", "infinity"]
