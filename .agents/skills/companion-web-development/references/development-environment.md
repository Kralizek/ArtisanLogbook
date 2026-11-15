# Development environment

Read [daily development and troubleshooting](../../../../docs/companion/web.md#daily-development-vs-code-dev-containers),
[AppHost](../../../../src/companion/tools/AppHost/AppHost.cs) and
[devcontainer configuration](../../../../.devcontainer/devcontainer.json).
Use the provisioned toolchain and rebuild the container after provisioning
changes. The container defaults to `CompanionWebDevelopment=true`; outside it
set the property for development. Restore and `--no-restore` build in the same
asset mode.

Aspire uses a checkout-specific `node_modules` volume, incremental
`npm install --no-save --include=dev --no-audit --no-fund`, isolated history,
and monitoring disabled. Windows host dependencies stay in the checkout; .NET
outputs are partitioned by platform and asset mode. Stop Aspire before host
deployment and do not run concurrent builds/restores: generated sources and
`dist` remain shared.

The web resource waits for the installer and Companion health. Dashboard
**Start** bypasses dependency waiting. Inspect installer, web and Companion
logs for installation, dependency wait, codegen and Vite readiness; a running
installer is not a ready frontend. Codegen can be slow on mounted checkouts.
After a premature start, wait for installation before restarting web.
For missing `graphql-codegen`, inspect local `node_modules/.bin` and installer
logs, not the global shell PATH; do not install frontend tools globally.
If installation was interrupted, stop Aspire and follow the documented clean
restore. `Development__InstallFrontend=false` is not a missing-tool fix.

Startup codegen fingerprints committed contracts, operations, configuration
and generated outputs. React/CSS changes use polling and Fast Refresh; inspect
the browser WebSocket and resource environment if HMR fails. Operation edits
require explicit codegen and typechecking; there is no contract watcher.
C# changes require Companion **Rebuild**, not Restart; AppHost changes require
stopping and restarting Aspire. Do not promise backend hot reload.
