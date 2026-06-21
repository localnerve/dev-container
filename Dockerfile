# =============================================================================
# Version pins — update here only
# =============================================================================
ARG GCM_VERSION=2.8.0

ARG NODE_VERSIONS="22 24"
ARG NODE_DEFAULT=24

ARG GO_VERSIONS="1.25.5 1.26.0"
ARG GO_DEFAULT=1.26.0

# GCM cache timeout in seconds (default: 30 days)
ARG GCM_CACHE_TIMEOUT=2592000

# =============================================================================
# Base image + system packages — single RUN to minimise layers
# =============================================================================
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG GCM_VERSION
ARG NODE_VERSIONS
ARG NODE_DEFAULT
ARG GO_VERSIONS
ARG GO_DEFAULT
ARG GCM_CACHE_TIMEOUT
ARG DOCKER_GID=0

ARG USERNAME=vscode
ARG USER_HOME=/home/${USERNAME}

ENV DEBIAN_FRONTEND=noninteractive

# Collapse all apt work into one layer: update, install prereqs, add PPA,
# update again, install chromium + GCM, then wipe lists and caches.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        pass gpg git libssl-dev pkg-config ca-certificates curl \
        software-properties-common \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    \
    # --- Temporary Node + Playwright, used only to resolve system deps ---
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g playwright \
    && npx playwright install-deps chromium \
    && npx playwright install-deps firefox \
    && npx playwright install-deps webkit \
    \
    # --- Extras not covered by Playwright's installer ---
    && apt-get install -y --no-install-recommends \
       xvfb \
       x11-utils \
       x11vnc \
    \
    # --- GCM ---
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL \
       "https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux-${ARCH}-${GCM_VERSION}.deb" \
       -o /tmp/gcm.deb \
    && apt-get install -y /tmp/gcm.deb \
    && rm /tmp/gcm.deb \
    \
    # --- docker-ce-cli ---
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    \
    # --- Teardown: remove the bootstrap Node/Playwright, keep only system libs ---
    && npm uninstall -g playwright \
    && apt-get remove -y --purge nodejs \
    && apt-get autoremove -y --purge \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* ~/.npm /usr/lib/node_modules

# =============================================================================
# nvm + Node
# =============================================================================
ENV NVM_DIR=${USER_HOME}/.nvm

USER ${USERNAME}

# Install nvm and all Node versions in one layer, then strip:
#   - npm caches
#   - node_modules of nvm itself
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
# goenv + Go
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
# DOCKER — configure
# =============================================================================
RUN if getent group ${DOCKER_GID} > /dev/null; then \
        EXISTING_GROUP=$(getent group ${DOCKER_GID} | cut -d: -f1); \
        usermod -aG ${EXISTING_GROUP} ${USERNAME}; \
    else \
        groupadd -g ${DOCKER_GID} docker-host \
        && usermod -aG docker-host ${USERNAME}; \
    fi

# =============================================================================
# Shell profiles
# =============================================================================
USER ${USERNAME}

RUN <<'EOF' tee -a ${USER_HOME}/.bashrc
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

# Xvfb helper — start on demand for headful debugging
export DISPLAY=:99

xvfb-start() {
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
    pkill -f "x11vnc.*:99"
    pkill -f "Xvfb :99"
    echo "Xvfb and x11vnc stopped"
}

# auto-switch on directory change
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
EOF

RUN <<'EOF' tee -a ${USER_HOME}/.zshrc
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

# Xvfb helper — start on demand for headful debugging
export DISPLAY=:99

xvfb-start() {
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
    pkill -f "x11vnc.*:99"
    pkill -f "Xvfb :99"
    echo "Xvfb and x11vnc stopped"
}

# auto-switch on any directory change
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
_load_versions
EOF

# =============================================================================
# Final
# =============================================================================
WORKDIR /workspace
RUN mkdir -p /home/${USERNAME}/.cache/ms-playwright \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.cache/ms-playwright
CMD ["sleep", "infinity"]