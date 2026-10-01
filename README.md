# Artisan Logbook

The Dev Container requires PowerShell 7 (`pwsh`) and an authenticated GitHub
CLI (`gh auth login`) on the host. During startup,
`.devcontainer/initialize-host.ps1` runs on the host and provides `gh auth token`
to the container as `GH_TOKEN`. The generated `.devcontainer/gh-token.env` file
is ignored by Git and created with owner-only permissions. Processes in the
container can read `GH_TOKEN`, so use this only with trusted workspaces.
