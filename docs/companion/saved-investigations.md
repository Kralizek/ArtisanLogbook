# Saved investigation definition v1

The REST envelope (`id`, `name`, `context`, `definitionVersion`, `revision`,
timestamps) owns identity and context. `definitionVersion: 1` denotes the
executable C12 document below; do not put `context` inside `definition`.
Older or unknown versions and unknown fields must be rejected before
navigation, not silently discarded.

```json
{
  "destination": "recipe",
  "entity": "opaque-api-recipe-id",
  "scope": {
    "period": "90",
    "character": "opaque-api-character-id",
    "input": "opaque-api-item-id",
    "buff": "12345",
    "finishing": "opaque-api-finishing-item-id"
  },
  "query": {
    "granularity": "week",
    "compare": {
      "period": "fixed",
      "from": "2025-01-01",
      "to": "2025-01-31",
      "character": "another-opaque-api-character-id"
    }
  }
}
```

`destination` is `activity`, `recipe`, `item` or `crafts`. Recipe/item require
`entity`, the opaque GraphQL API identity; the other destinations forbid it.
`scope.period` is required: `"30"` and `"90"` are rolling days, `"all"` is
unbounded and `"fixed"` requires valid ordered ISO calendar dates (`from`,
`to`). Dates on other periods are invalid. `query.compare` is optional and is
an **independent** scope, never an implicit copy of the primary scope.
`query.granularity`, if present, is `day`, `week` or `month`. Supported scope
filters are `character`, `profession`, `expansion`, `recipe`, `input`, `output`,
`returned`, `item` and `configuration`, all non-empty opaque API identities
or recorded configuration tokens. `buff` and `absentBuff` are positive
safe-integer spell IDs encoded as decimal strings; `finishing` and
`absentFinishing` are non-empty opaque item IDs. These recorded setup filters
may appear independently in either scope, using `bbuff`, `babsentBuff`,
`bfinishing` and `babsentFinishing` for population B. An absent filter means no
restriction, not unknown evidence.

Execution URLs use `/:alias/activity`, `/:alias/recipes/:id`,
`/:alias/items/:id` and `/:alias/crafts`. The scope fields map to same-named
query parameters, and a comparison maps to `compare=1` plus `bperiod`,
`bfrom`, `bto`, `bcharacter`, `bconfiguration`, `binput`, etc. Only the
granularity is shared. URLs may carry `saved=<uuid>&revision=<positive integer>`
as origin metadata; neither becomes an analytical filter or part of the stored
document. A live URL without `period` defaults to the workspace's 90-day
period; a persisted document always records its period explicitly. Opening
`/saved/:id` loads the envelope, validates the definition,
resolves the envelope's canonical context through REST and replaces navigation
with the executable URL. Update uses the opened revision, not a silently
refreshed revision; a conflict leaves tab edits untouched and offers a copy.
Renaming updates the fetched full definition verbatim at its fetched revision.
Relative periods stay relative, while fixed dates stay fixed.
