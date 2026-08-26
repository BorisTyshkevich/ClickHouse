-- Pins that a non-recursive helper CTE declared `MATERIALIZED` inside a `WITH RECURSIVE`
-- clause is materialized once and every recursive iteration reads the same temporary
-- result, even when the helper is referenced only once syntactically inside the
-- recursive term. A CTE that actually refers to its own output still cannot be
-- `MATERIALIZED` and raises `UNSUPPORTED_METHOD`, regardless of `enable_materialized_cte`.
--
-- Temporary table names created for a materialized CTE are random, so raw `EXPLAIN`
-- output is never pinned directly; instead we count how many
-- `MaterializingCTE (Materializing CTE: <name>)` plan-step lines the query plan has.

SET enable_analyzer = 1;
SET enable_materialized_cte = 1;

-- A. Plain materialized helper referenced through an `IN` subquery from the recursive term.
WITH RECURSIVE evens AS MATERIALIZED (SELECT number * 2 AS n FROM numbers(10)),
search AS (SELECT 0 AS x UNION ALL SELECT x + 2 FROM search WHERE x < 8 AND (x + 2) IN (SELECT n FROM evens))
SELECT * FROM search ORDER BY x;

-- B. Plain materialized helper referenced through a `JOIN` from the recursive term.
WITH RECURSIVE seq AS MATERIALIZED (SELECT number AS n FROM numbers(1, 5)),
walk AS (SELECT 1 AS x UNION ALL SELECT x + 1 FROM walk INNER JOIN seq ON seq.n = walk.x WHERE x < 5)
SELECT * FROM walk ORDER BY x;

-- C1. Plan assertion: helper referenced exactly once, inside the recursive term only,
--     must still produce exactly one materialization step.
SELECT count() FROM (
    EXPLAIN
    WITH RECURSIVE helper AS MATERIALIZED (SELECT rand() AS r),
    walk AS (SELECT toUInt64(0) AS n, toUInt32(0) AS r UNION ALL SELECT n + 1, helper.r FROM walk CROSS JOIN helper WHERE n < 4)
    SELECT * FROM walk
) WHERE explain LIKE '%MaterializingCTE (Materializing CTE: helper)%';

-- C2. Functional nondeterminism assertion: since the helper is materialized once, every
--     recursive step observes the same random value.
WITH RECURSIVE helper AS MATERIALIZED (SELECT rand() AS r),
walk AS (SELECT toUInt64(0) AS n, toUInt32(0) AS r UNION ALL SELECT n + 1, helper.r FROM walk CROSS JOIN helper WHERE n < 4)
SELECT uniqExactIf(r, n > 0) FROM walk;

-- C3. A helper referenced only in the seed (non-recursive) term is still single-use
--     and stays inlined: zero materializations.
SELECT count() FROM (
    EXPLAIN
    WITH RECURSIVE helper AS MATERIALIZED (SELECT toUInt64(0) AS n),
    walk AS (SELECT n FROM helper UNION ALL SELECT n + 1 FROM walk WHERE n < 3)
    SELECT * FROM walk
) WHERE explain LIKE '%MaterializingCTE (Materializing CTE: helper)%';

-- D. Non-recursive UNION-shaped helper: `UNION DISTINCT` proves the recursive-only
--    `UNION ALL` validation is not applied to the helper's own body.
WITH RECURSIVE steps AS MATERIALIZED (SELECT toUInt64(1) AS step UNION DISTINCT SELECT toUInt64(1) AS step),
walk AS (SELECT toUInt64(0) AS x UNION ALL SELECT x + step FROM walk CROSS JOIN steps WHERE x < 3)
SELECT * FROM walk ORDER BY x;

-- D2. Same, but the helper's `UNION ALL` body actually contributes two distinct rows,
--     so each recursive step fans out over both.
WITH RECURSIVE steps AS MATERIALIZED (SELECT toUInt64(1) AS step UNION ALL SELECT toUInt64(2) AS step),
walk AS (SELECT toUInt64(0) AS x UNION ALL SELECT x + step FROM walk CROSS JOIN steps WHERE x < 2)
SELECT * FROM walk ORDER BY x;

-- E. Chained materialized helpers used from the recursive member.
WITH RECURSIVE
base AS MATERIALIZED (SELECT number AS n FROM numbers(5)),
filtered AS MATERIALIZED (SELECT n FROM base WHERE n % 2 = 0),
walk AS (SELECT toUInt64(0) AS x UNION ALL SELECT x + 2 FROM walk INNER JOIN filtered ON filtered.n = walk.x + 2 WHERE x < 4)
SELECT * FROM walk ORDER BY x;

-- F. Negative: a CTE that refers to its own output cannot be `MATERIALIZED`, regardless
--    of the `enable_materialized_cte` setting.
WITH RECURSIVE bad AS MATERIALIZED (SELECT 1 AS x UNION ALL SELECT x + 1 FROM bad WHERE x < 3) SELECT * FROM bad; -- { serverError UNSUPPORTED_METHOD }

SET enable_materialized_cte = 0;
WITH RECURSIVE bad AS MATERIALIZED (SELECT 1 AS x UNION ALL SELECT x + 1 FROM bad WHERE x < 3) SELECT * FROM bad; -- { serverError UNSUPPORTED_METHOD }
