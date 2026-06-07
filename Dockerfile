# =============================================================================
# Version pins — update here only
# =============================================================================
ARG GCM_VERSION=2.8.0

ARG NODE_VERSIONS="22 24"
ARG NODE_DEFAULT=24

ARG GO_VERSIONS="1.23.5 1.25.5 1.26.0"
ARG GO_DEFAULT=1.26.0

# GCM cache timeout in seconds (default: 30 days)
ARG GCM_CACHE_TIMEOUT=2592000

# =============================================================================
# Base image + system packages
# =============================================================================
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG GCM_VERSION
ARG NODE_VERSIONS
ARG NODE_DEFAULT
ARG GO_VERSIONS
ARG GO_DEFAULT
ARG GCM_CACHE_TIMEOUT

# Non-root user provided by the base devcontainer image
ARG USERNAME=vscode
ARG USER_HOME=/home/${USERNAME}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    pass gpg git libssl-dev pkg-config ca-certificates curl \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL \
    "https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux-${ARCH}-${GCM_VERSION}.deb" \
    -o gcm.deb \
    && apt-get install -y ./gcm.deb \
    && rm gcm.deb \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# nvm + Node — installed as the non-root user
# =============================================================================
ENV NVM_DIR=${USER_HOME}/.nvm

USER ${USERNAME}

RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && bash -c " \
        source \${NVM_DIR}/nvm.sh \
        && for v in ${NODE_VERSIONS}; do nvm install \$v; done \
        && nvm alias default ${NODE_DEFAULT} \
    "

# =============================================================================
# goenv + Go — installed as the non-root user
# =============================================================================
ENV GOENV_ROOT=${USER_HOME}/.goenv
ENV GOPATH=${USER_HOME}/go
ENV PATH="${GOENV_ROOT}/bin:${PATH}"

RUN git clone --depth=1 https://github.com/go-nv/goenv.git ${GOENV_ROOT} \
    && bash -c " \
        eval \"\$(goenv init -)\" \
        && for v in ${GO_VERSIONS}; do goenv install \$v; done \
        && goenv global ${GO_DEFAULT} \
    "

# =============================================================================
# GCM — system-wide config as root, credential cache as non-root
# =============================================================================
USER root
RUN git-credential-manager configure \
    && git config --system credential.gitHubAuthModes devicecode \
    && git config --system credential.credentialStore cache \
    && git config --system credential.cacheOptions "--timeout ${GCM_CACHE_TIMEOUT}"

# Lock down the system gitconfig so it can't be overridden by a mounted
# ~/.gitconfig to use a less secure store
RUN chmod 644 /etc/gitconfig

USER ${USERNAME}

# =============================================================================
# Shell profiles
# =============================================================================

# --- bash ---
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
EOF

# --- zsh ---
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
EOF

# =============================================================================
# Final working directory
# =============================================================================
WORKDIR /workspace
CMD ["sleep", "infinity"]