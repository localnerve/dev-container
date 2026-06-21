# dev-container

> webdev container workstation

Creates a linux/arm64 web developer workstation with support for modern web development.

## v1.3.0
### Features

* Go and Nodejs Multi-version Local Projects
* Ssh Auth Socket
* Github Credential Manager
* Bash and Zsh Interactive Shells
* Puppeteer and playwright support
  - xvfb headed visual browser debugging support
* Docker outside of docker support
* Docker Testcontainers support

* Multiple Node.js versions (nvm) + multiple Go versions (goenv)
* Chromium + GCM (git-credential-manager)
* DooD (Docker-outside-of-Docker) via host socket, GID-0 group membership
* Playwright/Puppeteer system dependencies (via playwright install-deps, all three engines or just chromium — your call)
* Xvfb + x11vnc for headful browser debugging, with on-demand start/stop helpers
* Named volume for shared Playwright browser-binary cache across rebuilds
* Shell bash and zsh profile auto-switching for Node/Go versions based on .nvmrc/.go-version
* seccomp=unconfined for Chromium zygote sandbox compatibility
* Image-size optimizations (single-layer apt, stripped nvm/goenv artifacts)

## Usage

Build, run container
```bash
docker compose up -d
```

On the host, attach to running container `dev-env` from your development environment.