# Persistence and queries

Consult [Core reconciliation](../../../../src/companion/src/Core/README.md#reconciliation),
[HistoryStore ownership and lifecycle](../../../../src/companion/src/HistoryStore/README.md)
and [GraphQL semantics](../../../../docs/companion/graphql.md).
`WriteBatch` validates/reconciles the complete batch in one transaction; failed
conflicts cannot persist partial enrichments. A read's multiple statements share
its transaction snapshot; separate reads and resolvers do not.

Follow existing `$Name`/`DynamicParameters` and typed Dapper mapping, passing
the transaction and cancellation through all layers. Quantity integers use
BIGINT; returned decimals use invariant text/decimal parsing. Maintain streamed
iteration and cancellation checks. Never interpolate user input into SQL.
Queries use stable context-qualified keys, bounded forward pages and canonical
tie-breaks; preserve 100 ns ordering precision. Reuse batched child/dimension
reads instead of a connection per row; do not claim all reverse queries are
batched.

Disposal closes admission, cancels reads/cooperative work, and waits for owned
operations within a bounded grace period. A timeout is not successful release;
never close a native connection under active work or hide disposal failures.
Historical schematic variants remain evidence, while explicit catalog
dimension contradictions still conflict.
