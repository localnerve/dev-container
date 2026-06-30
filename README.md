# dev-container

> A webdev workstation for multiple projects

This project delivers a Linux/ARM64 web development workstation optimized for Docker Desktop on macOS, designed to streamline modern full-stack workflows with automatic Node.js and Go version switching. It provides comprehensive browser testing capabilities via Playwright and Puppeteer across all three engines—including headful debugging via VNC—while integrating essential sidecar services like Caddy for SSL authentication testing and OpenBao for secrets management. The environment also features Docker-outside-of-Docker (DooD) support for running Testcontainers against the host daemon, backed by a secure, auto-maintained seccomp profile.

## v1.6.4
### Features

* Multiple Node.js versions (nvm) + multiple Go versions \(goenv\)
* Base Chromium
* GCM \(git-credential-manager\) with an in-memory cache store \(that expires and requires re-login\)
  - May need to run `printf "protocol=https\nhost=github.com\n" | git credential-manager erase` in the container to force clear the cache and reauthenticate. Shell functions:
    - `git-check` - check GCM cache state for credential reauth
    - `git-check-remote` - check local/remote tracking state for repo
  - Run `git credential-manager diagnose` to check cache state
  - Run `printf "protocol=https\nhost=github.com\n" | git credential-manager get` to manually check cache credential state
  - Host projects directory is direct bind mounted to `/workspace`
* DooD \(Docker-outside-of-Docker\) via host socket, GID group membership
* Docker Testcontainers support via DooD
* Playwright/Puppeteer system dependencies \(via playwright install-deps, **all three engines**\)
* Xvfb + x11vnc for headful browser debugging, with on-demand start/stop helpers. Shell Functions:
    - `xvfb-start` - start xvfb and xvfb x11vnc for visual browser debugging \(attach with tigerVnc or client that allows nopw\)
    - `xvfb-stop` - stop xvfb and xvfb x1llvnc
* Named volume for shared Playwright browser-binary cache across rebuilds
* Caddy duckdns challenge build sidecar with reverse proxy for auth/app host cookie auth pattern with true SSL testing
* Shell bash and zsh profile auto-switching for Node/Go versions based on .nvmrc/.go-version
* seccomp profile generated from docker default source, merge Chromium zygote sandbox required syscalls
  - run `scripts/update-chrome-seccomp.sh` to update `chrome.json` seccomp profile [see below](#github-actions-and-seccomp-maintenance)
  - seccomp profile is automatically maintained from docker source through Github Actions Weekly job
* Openbao secrets vault sidecar with workstation bao client
  - `bao kv {get,put,list}` command ready
  - Preconfigured `secret` and `apps` paths

## Usage

Build, run container
```bash
docker compose up -d
```

> On the host, attach to running container `dev-env` from your development environment.

## Github Actions and Seccomp Maintenance

The custom seccomp profile for this dev-container, `chrome.json`, adds a few syscall allowances to the standard default docker seccomp profile to allow chromium to manage the sandbox and namespaces.

To get the latest verion of the standard default docker seccomp profile from source run:

```bash
curl -fsSL https://raw.githubusercontent.com/moby/profiles/refs/heads/main/seccomp/default.json -o ./seccomp/docker-default.json
```

To update the custom seccomp profile for this dev-container, `chrome.json`:

```bash
./scripts/update-chrome-seccomp.sh --input seccomp/docker-default.json --out chrome.json
```

The `update-seccomp-profile.yml` GitHub Action runs weekly to:
  * Detect upstream changes in Docker's default seccomp profile by comparing against our local baseline \(`./seccomp/docker-default.json`\).
  * Refresh the local copy if updates are found.
  * Regenerate the custom dev-container profile \(`chrome.json`\) with necessary Chromium exceptions.


## Security

> Document Links

* Full analysis on this dev-container's [security](docs/security/security.md) profile, and architecture decisions. Covers why DinD is not required on MacOS for a typical developer threat model.

* A discussion of the trade-offs between [DinD and DooD](docs/security/dind-dood-security.md).