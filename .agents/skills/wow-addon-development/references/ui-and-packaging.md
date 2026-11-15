# UI, diagnostics and packaging

Read [UI behavior and acceptance](../../../../docs/addon/ui.md),
[diagnostics](../../../../docs/addon/diagnostics.md),
[public Lua API](../../../../docs/addon/lua-api.md), and
[deployment and flavor restrictions](../../../../docs/addon/deployment.md).
UI consumes Core projections; Tracer is optional and usable independently.
Do not introduce a second ledger or infer unavailable measurements for display.

Use existing TOCs, `.flavors.yml`, packaging and deployment scripts. Flavor
archives and automated Lua tests validate their stated contracts, not actual
game API delivery or UI appearance. Use isolated fixtures and never test with
real user SavedVariables or settings. Live client and visual acceptance must be
reported separately.
