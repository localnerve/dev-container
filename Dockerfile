FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock

RUN apt-get update && apt-get install -y \
    curl git libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Official nvm (v0.40.1)
ENV NVM_DIR=/root/.nvm
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

# Official goenv
ENV GOENV_ROOT=/root/.goenv
ENV PATH="${GOENV_ROOT}/bin:${PATH}"
RUN git clone https://github.com/go-nv/goenv.git $GOENV_ROOT

# Pre-install Runtimes
# Note: We must source the profiles within the RUN command for the tools to be 'found'
RUN bash -c "source $NVM_DIR/nvm.sh && nvm install 22 && nvm install 24 && nvm alias default 24"
RUN bash -c "eval \"\$(goenv init -)\" && goenv install 1.26.0 && goenv global 1.26.0"

# Setup shell profiles for ergonomics
RUN echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ~/.bashrc \
    && echo 'eval "$(goenv init -)"' >> ~/.bashrc \
    && echo 'export PATH="$GOROOT/bin:$PATH"' >> ~/.bashrc \
    && echo 'export PATH="$PATH:$GOPATH/bin"' >> ~/.bashrc \
    && echo 'cdnvm() { command cd "$@" || return; if [[ -f .nvmrc && -r .nvmrc ]]; then nvm use; elif [[ -f .node-version && -r .node-version ]]; then nvm use; fi; }' >> ~/.bashrc \
    && echo 'alias cd="cdnvm"' >> ~/.bashrc

WORKDIR /workspace
CMD ["sleep", "infinity"]
