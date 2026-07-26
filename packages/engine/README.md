# Daily Plan Engine

`@pet-companion/engine` is the pure Slice A daily-plan transformation:

```ts
const result = generatePlan(context);
```

The caller supplies the local date, current instant, household time zone,
capacity, already-materialized occurrences, events, profile state, history,
and versioned catalogue rows. The engine performs no I/O, reads no database,
and never calls `Date.now()`. Identical contexts produce byte-identical
results, including stable item keys, ordering, explanations, diagnostics,
input digest, and catalogue snapshots.

Server code should load SQL rows into the snake_case `GenerationContext`
shape, call `generatePlan`, then persist `result.plan` and `result.items` in
one transaction. The returned step-9 representation deliberately leaves
locking, the one-plan-per-pet/day upsert, and lifecycle jobs to the server.

Ordering is deterministic: section, priority tier, exact time, broad time
window, title, then `item_key`. Recommendation selection ties use total
score, category, title, then candidate key.

Run:

```sh
npm run typecheck
npm test
```

Scenario files use JSON syntax, which is valid YAML 1.2. The dependency-free
harness reads every `fixtures/scenarios/*.yaml` scenario, constructs the
catalogue-backed context, runs the engine, and checks its expectations.
