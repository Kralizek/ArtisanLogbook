# Fixtures and migration

Read [adapter source-format evidence and writer constraints](../../../../src/companion/src/SavedVariables/README.md)
and [ledger regression coverage](../../../../docs/addon/storage.md#regression-coverage-and-limits).
The schema-1 fixture generator records the historical Ledger revisions used.
The committed generated snapshots are sanitized, not exports from a user.
Keep actual trace-derived fixture provenance and synthetic substitutions
explicit; never claim a fixture proves unsupported runtime behavior.

When extending a ledger, follow the existing migration and validation sequence,
preserving supported old history, unrelated assignments and retained aggregates.
Verify both addon loading and Companion reading/writing where affected, including
round-trip evidence, identity collisions, pruning and aggregate-only coverage.
Use CONTRIBUTING's historical fixture regression when changing generator inputs
or provenance; this requires the historical Git objects and does not replace
product tests.
