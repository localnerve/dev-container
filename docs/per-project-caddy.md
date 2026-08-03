# Project Caddy Setup

Projects bring their own configuration additions to the [base Caddyfile](/conf/Caddyfile). Typically, these are named RP hosts brought in for duckdns let's encrypt support for TLS. The duckdns hostnames are defined and their RP definitions use project defined docker name aliases.

Here is an example of a project's caddyfile that is imported from conf.d in the base Caddyfile:

```Caddyfile
# RP configs use project alias names
# ducktls snippet defined in root Caddyfile
rp-localnerve.duckdns.org {
	import ducktls
	reverse_proxy jam-build-authorizer:9011
}
ln.rp-localnerve.duckdns.org {
	import ducktls
	reverse_proxy jam-build-app:5000
}
```

> It defines the TLS supported hostnames and proxies them to the named aliases defined in the projects testcontainers

Here is a project setup script to use the Caddy admin interface to update and reload the aggregate Caddy config (base + conf.d) in the dev-container:

```javascript
import fs from 'node:fs';
import path from 'node:path';

if (process.env.DEVCONTAINER !== 'true') {
  console.log('Not in devcontainer — skipping Caddy registration.');
  process.exit(0);
}

// Copy this project's caddyfile config to dev-container conf.d:
const src = path.resolve('./devcontainer/jam-build.Caddyfile');
const dest = '/etc/caddy/conf.d/jam-build.Caddyfile';

fs.copyFileSync(src, dest);
console.log(`Installed ${dest}`);

// Trigger a reload — Caddy's admin API is reachable directly since
// dev-workstation and caddy share the devcontainer network.
const resp = await fetch('http://172.19.0.2:2019/load', {
  method: 'POST',
  headers: { 'Content-Type': 'text/caddyfile' },
  body: fs.readFileSync('/etc/caddy/Caddyfile', 'utf8')
});

if (!resp.ok) {
  throw new Error(`Caddy reload failed: ${resp.status} ${await resp.text()}`);
}
console.log('Caddy reloaded.');
```