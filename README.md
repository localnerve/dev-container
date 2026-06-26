# dev-container

> webdev container workstation

Creates a linux/arm64 web developer workstation with support for modern web development. Developed for Docker Desktop on MacOS.

## v1.5.1
### Features

* Multiple Node.js versions (nvm) + multiple Go versions (goenv)
* Chromium + GCM (git-credential-manager)
* DooD (Docker-outside-of-Docker) via host socket, GID group membership
* Docker Testcontainers support via DooD
* Playwright/Puppeteer system dependencies (via playwright install-deps, **all three engines**)
* Xvfb + x11vnc for headful browser debugging, with on-demand start/stop helpers
  - Commands: `xvfb-start`, `xvfb-stop`
* Named volume for shared Playwright browser-binary cache across rebuilds
* Caddy duckdns challenge build sidecar with reverse proxy for auth/app host cookie auth pattern with true SSL testing
* Shell bash and zsh profile auto-switching for Node/Go versions based on .nvmrc/.go-version
* seccomp profile generated from docker default source, merge Chromium zygote sandbox required syscalls
  - run `update-chrome-seccomp.sh` to update `chrome.json` seccomp profile
* Openbao secrets vault sidecar with workstation bao client
  - `bao kv {get,put,list}` command ready
  - Preconfigured `secret` and `apps` paths

## Usage

Build, run container
```bash
docker compose up -d
```

On the host, attach to running container `dev-env` from your development environment.

## Docs

* Qwen and Claude discussion on this dev-container's [security](docs/security/security.md) profile.