# Production packaging

Read [production architecture and executable validation](../../../../docs/companion/web.md)
and [WebAssets targets](../../../../src/companion/src/WebAssets/WebAssets.csproj).
MSBuild owns production npm restore, offline generation, bundling and embedding;
the production stamp describes the current platform, runtime, manifests and
dependency tree. Development installation invalidates it. Preserve incremental
input/output tracking and recovery of deleted assets, including Windows resource
path handling.

Publish with production asset mode and a build, never `--no-build` or development
assets; both shortcuts are rejected. Assets stream from the embedded provider;
only explicitly supported SPA routes receive document fallback. A successful
Vite bundle alone does not establish a working single-executable distribution.
Use CONTRIBUTING's normal and extended checks according to the changed surface.
