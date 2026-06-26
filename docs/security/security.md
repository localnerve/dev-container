# Dev Container Security Issues

A qwen 3.6 (and some claude sonnet 4.7) review of a previous version of the dev-container `seccomp` profile in the context of the overall dev-container architecture. This explores potential dev-container security issues.

This assessment resulted in the tightening the seccomp profile to latest docker defaults with the few chromium exceptions required for sandbox management merged in, left as DooD, documented risks.

---

> This analysis is against a previous, more permissible seccomp profile.

## `chrome.json` Seccomp Profile Custom Syscall Allow List 
> seccomp profile vs 'unconfined'

Your custom profile is **marginally better** than `unconfined`, but not by a practically meaningful amount. The real security concern isn't the seccomp profile—it's the bind-mounted Docker socket.

## Detailed Analysis

### What Your Profile Blocks (The Good)

Compared to `seccomp: unconfined`, your profile explicitly denies these categories of syscalls:

| Category | Blocked Syscalls | Why It Matters |
|----------|------------------|----------------|
| **Kernel modules** | `init_module`, `finit_module`, `delete_module` | Prevents loading arbitrary kernel code |
| **Process tracing** | `ptrace` | Prevents reading/writing other processes' memory |
| **Mount operations** | `mount`, `umount2`, `pivot_root`, `swapon`, `swapoff` | Prevents remounting filesystems with dangerous options |
| **Kernel reloading** | `kexec_load`, `kexec_file_load` | Prevents replacing the running kernel |
| **BPF** | `bpf` | Prevents arbitrary eBPF program loading |
| **Keyring** | `keyctl`, `add_key`, `request_key` | Limits kernel key manipulation |
| **Time setting** | `settimeofday`, `adjtimex`, `clock_settime` | Prevents tampering with system time (read-only allowed) |
| **Accounting** | `acct` | Minor, but prevents process accounting changes |

That's ~250+ syscalls allowed vs. the full kernel set of ~370+. You're blocking roughly 120 syscalls, most of which are genuinely dangerous.

### What Your Profile Allows (The Bad)

Your allowlist includes essentially every syscall a normal application needs:
- Full filesystem access (`open`, `openat`, `unlink`, `rename`, `mknod`, etc.)
- Full network stack (`socket`, `bind`, `connect`, `sendto`, `recvfrom`, etc.)
- Process creation and control (`clone`, `fork`, `execve`, `kill`, `wait4`)
- Memory manipulation (`mmap`, `mprotect`, `munmap`, `mremap`)
- IPC primitives (shared memory, semaphores, message queues)

For any attacker who already has code execution inside your container, this is functionally equivalent to unconfined for application-level attacks.

### The Real Problem: Docker Socket Bind-Mount

This is the critical insight: **your seccomp profile is largely irrelevant because of `${DOCKER_SOCK}:/var/run/docker.sock`**.

```yaml
volumes:
  - ${DOCKER_SOCK}:/var/run/docker.sock   # ← This is your actual attack surface
```

With Docker socket access, any process in the container can:

1. **Create a new privileged container** with `--privileged` and `security_opt: seccomp:unconfined`, completely bypassing your profile
2. **Mount the host filesystem** via `-v /:/host` to read/write arbitrary files on macOS's VM layer
3. **Escape namespace isolation** by creating containers with custom network/user namespaces
4. **Read all other containers' data**, environment variables, and secrets

On Docker Desktop for Mac specifically, the Docker daemon runs inside a lightweight Linux VM. The socket gives you root-equivalent access to that VM. While this doesn't give direct access to your macOS host filesystem (Docker Desktop uses gRPC/Virtualization.Framework boundaries), it does give full control over:
- All containers and their data
- The Docker VM's entire filesystem
- Network configuration for all containers

### More On MacOS Docker Desktop With Regard to Potential docker.sock Attack Enabled by DooD

On Docker Desktop for Mac, every container — including your devcontainer and anything spawned via the docker.sock — runs inside Docker Desktop's Linux VM, which is isolated from macOS by Apple's `Virtualization.framework`. This means:

- **No shared host kernel.** On bare Linux, a privileged container escape reaches the actual host kernel. On macOS, it reaches the VM's throwaway Linux kernel — a second isolation boundary sits between that and your real Mac.
- **No host filesystem access.** A container that escapes to the VM root can only see what the VM has access to — which is limited to what you explicitly shared via Docker Desktop's file sharing settings, your bind-mounted volumes, and the VM's own ephemeral filesystem. Your Mac's actual filesystem (`/Users`, `/System`, etc.) is not visible from the VM unless you explicitly shared it.
- **The attack surface is bounded.** The worst realistic outcome of a docker.sock exploit in this setup is root access inside the Docker Desktop Linux VM — which does have access to your bind-mounted project files, your SSH agent socket, and environment variables in running containers. That's a meaningful but bounded blast radius, not full macOS compromise.

So the tradeoff is: you accept that a compromised dependency with docker.sock access could reach VM root and access your mounted files and credentials, in exchange for the practical ability to run Testcontainers and sibling service containers the same way GHA runners do. The VM layer means this doesn't translate to macOS host compromise without a separate hypervisor-level exploit, which is a substantially higher bar.

### Defense-in-Depth Assessment

| Layer | Your Setup | Effectiveness |
|-------|-----------|---------------|
| Seccomp profile | Custom allowlist | Low — easily bypassed via Docker API |
| User namespace | Not used (root in container) | None |
| Read-only rootfs | No (`/workspace` is writable) | None |
| Capabilities | Default set + `IPC_LOCK` for OpenBao | Moderate — but irrelevant with socket access |
| AppArmor/SELinux | Not configured | None |

## Recommendations

### If You Want Meaningful Security Improvement

**Option A: Use Docker-in-Docker (DinD) instead of DooD**

Run an isolated Docker daemon inside the container rather than mounting the host socket. This is slower but actually isolates testcontainers from your main Docker environment:

```yaml
services:
  dev-workstation:
    # Remove the docker.sock bind-mount entirely
    
  docker-proxy:
    image: docker:dind
    privileged: true
    environment:
      DOCKER_TLS_CERTDIR: ""
    volumes:
      - docker-graph:/var/lib/docker
    networks:
      default:
        ipv4_address: 172.19.0.10

volumes:
  docker-graph:
```

Then set `DOCKER_HOST=tcp://docker-proxy:2375` in your devcontainer. Testcontainers will use this isolated daemon instead of the host's.

**Option B: Accept the risk and document it**

If DinD is too slow for your workflow, acknowledge that the Docker socket mount makes seccomp largely moot and focus on other mitigations:
- Only run trusted code in this environment
- Don't store secrets in the container (use OpenBao correctly)
- Keep the image updated to patch kernel/container runtime vulnerabilities

**Option C: Use Docker's default profile instead of custom or unconfined**

If you want a middle ground with minimal effort, just remove `security_opt` entirely. Docker's built-in default seccomp profile is well-maintained and blocks the truly dangerous syscalls while allowing most application functionality. Chromium may need a few exceptions (like `clone3`, `memfd_create`, `pidfd_open`) which you can add via a small override rather than building an allowlist from scratch:

```yaml
security_opt:
  - seccomp:chrome-default-override.json
```

Where `chrome-default-override.json` starts with Docker's default and only adds the ~10-15 syscalls Chromium specifically needs beyond it. This is far more maintainable than your current ~250-entry allowlist, which will silently stop working when a new syscall is needed by an updated dependency.

### Bottom Line

Your `chrome.json` profile blocks many syscalls. Against a determined attacker with Docker socket access, it provides **no meaningful protection**. Against accidental misbehavior or untrusted code that doesn't know to use the Docker API, it's better than `unconfined` but worse than Docker's default profile in terms of maintainability and coverage.

The most impactful change you could make is switching from DooD to DinD if isolation matters to you. If convenience matters more, just use Docker's default seccomp profile and accept the socket-mount risk as a known tradeoff.

### Action

* Created `update-chrome-seccomp.sh` to download the latest docker seccomp defaults and merge in the few chromium required syscall allowances.

## More Information

* [An analysis of DinD vs DooD](dind-dood-security.md). A discussion of the costs associated with running DinD in a devcontainer.

* Verify the root permissions in the container:
  `find / -xdev -group root -perm -020 -type f 2>/dev/null | grep -v '^/proc'` 