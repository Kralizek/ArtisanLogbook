# Local security

Read [local HTTP security](../../../../docs/companion/api.md) and the
[web development guide](../../../../docs/companion/web.md#tooling-and-local-development).
Endpoints and forwards are private loopback only. AppHost passes its actual
required backend port to Vite; frontend code uses relative URLs. In the
devcontainer the API forward is 48722 and production defaults to 48721; use the
actual endpoints/Ports view elsewhere. Resolve port conflicts rather than
exposing a public bind.

Container certificate initialization does not trust the dashboard certificate
in the host browser. Follow the documented host-trust procedure; do not disable
verification. The HTTP web endpoint does not need dashboard certificate trust.

[dev-proxy.ts](../../../../src/companion/web/dev-proxy.ts) checks loopback Host,
exact Origin and Fetch Metadata before rewriting validated API Origins.
Preserve headers, bodies, disabled CORS and backend protections. Never strip
untrusted Origins or allow wildcard hosts. The dashboard exception permits
only user-initiated top-level GET document navigation to `/`, `/history` or
`/history/`; it does not permit cross-origin API, assets or background fetches.
