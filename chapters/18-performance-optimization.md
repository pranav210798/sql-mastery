# Chapter 18 — SQL Performance Optimization

> *"The first rule of optimization is: don't. The second rule of optimization
> (for experts only) is: don't yet."* — a rule performance engineers relearn
> the hard way in every generation.

## 18.0 What this chapter is — and isn't

Chapter 16 (Indexes) explained *how* B-tree, hash, GIN, GiST, and BRIN indexes
are built and stored. Chapter 17 (Query Execution & the Query Planner)
explained *how to read* an execution plan — scan types, join algorithms, cost
estimates, `EXPLAIN (ANALYZE, BUFFERS)`. This chapter assumes you've read
both, and does not re-derive B-tree internals or re-teach `EXPLAIN` output.

Instead, Chapter 18 is the **playbook**: given a slow query in front of you,
what do you actually *do*? It ties indexing, planning, join strategy,
pagination, subqueries, CTEs, statistics, partitioning, connection handling,
and application-level query patterns together into one practical,
example-driven workflow — plus topics that genuinely belong here and nowhere
else in the book: the N+1 query problem, connection pooling, and
statistics/`ANALYZE` hygiene.

**Setup.** Examples below run against `ecommerce_db` and `analytics_db` from
`databases/`. Each section notes which schema it uses:

```sql
SET search_path TO ecommerce_db;   -- small, hand-authored seed data
SET search_path TO analytics_db;   -- star schema, ~5,000,000-row sales_fact
```

`ecommerce_db` has only a handful of rows per table — perfect for
understanding *correctness* of a rewrite, but too small to *feel* slow.
`analytics_db`'s `sales_fact` table (5,000,000 rows across `sales_fact_2022`,
`sales_fact_2023`, `sales_fact_2024` partitions) is where the performance
differences in this chapter become real and measurable. Where the seed data
itself is too small to produce a genuine timing difference, this chapter
says so explicitly and gives **illustrative** numbers — labeled as such —
extrapolated to a realistic production scale, so you understand the shape of
the problem even against a laptop-sized dataset.

> **⚠️ Warning — measure before you optimize.**
> Every technique in this chapter can make a query faster *or* can be
> irrelevant *or* can make things worse, depending on your actual data
> distribution, table size, and workload. Never apply a "fix" from a
> checklist blindly. Always establish a baseline with `EXPLAIN (ANALYZE,
> BUFFERS)` (Ch. 17) before changing anything, and re-measure after. Chasing
> a technique because it sounds authoritative — without profiling first — is
> how teams add ten unused indexes and make write performance worse while
> the actual bottleneck (a missing `WHERE` clause filter, an N+1 loop, a
> stale statistics table) goes untouched.

---

## 18.1 The optimization mindset

**Simple explanation.** A relational database is a cost-based row-processing
engine. Every technique in this chapter is a variation on one idea: **do
less work, on fewer rows, as early as possible, and only compute what the
caller actually needs.**

**Why it matters.** Query cost is dominated by rows touched and bytes moved
— from disk to buffer cache, from buffer cache to the executor, from the
executor to the client, from the client to the application. Every stage you
can shrink compounds with every other stage.

Four principles recur through the entire chapter:

1. **Filter early.** Push `WHERE` conditions as close to the data source as
   possible so downstream operators (joins, sorts, aggregates) work on the
   smallest possible row set.
2. **Reduce rows as soon as possible.** Prefer semi-joins (`EXISTS`,
   `IN`) over full joins when you only need to test existence. Prefer
   aggregating before joining when the aggregate doesn't need post-join
   columns.
3. **Avoid computing more than needed.** Don't select columns you don't
   display, don't sort results nobody will see in order, don't fetch rows
   you'll discard with `OFFSET`.
4. **Let the index do the work the executor would otherwise do at runtime.**
   An index can pre-sort, pre-filter, and sometimes pre-answer a query
   without ever touching the table (Ch. 16's index-only scan).

Here is the master reference table this chapter builds out in detail —
common performance "smells," why they're slow, and the standard fix:

| Smell | Why it's slow | Fix |
|---|---|---|
| `SELECT *` in application code or reports | Extra I/O, extra network bytes, defeats index-only scans, breaks on schema changes | Select only the columns you use (§18.2) |
| No index on `WHERE`/`JOIN`/`ORDER BY` columns | Sequential scan of the whole table | Add a targeted index; see the checklist in §18.3 |
| Wrong composite index column order | Index can't be used for the leading filter, or scans more of the index than needed | Equality columns first, then range, then sort columns (§18.3) |
| Function wrapped around an indexed column, e.g. `WHERE LOWER(email) = ...` | Planner can't use a plain B-tree index on `email` | Expression index on `LOWER(email)`, or rewrite the predicate (Ch. 16) |
| Correlated subquery re-executed per outer row | O(N × M) work instead of O(N + M) | Rewrite as `JOIN` or window function (§18.8) |
| Deep `OFFSET` pagination | Database must generate and discard all skipped rows | Keyset (seek) pagination (§18.7) |
| N+1 query pattern from application/ORM code | 1 query becomes N+1 round trips | Batch with `JOIN` or `WHERE id IN (...)` (§18.13) |
| Sorting on a column with no supporting index | Runtime `Sort` node, possibly spilling to disk | Composite index covering the sort order (§18.6) |
| Joining a table whose columns are never selected/filtered | Wasted join work, sometimes wasted row multiplication | Drop the join or convert to `EXISTS` (§18.4) |
| Stale table statistics after a bulk load | Planner misestimates row counts, picks a bad plan | Run `ANALYZE` (§18.10) |
| Opening a fresh DB connection per request | TCP handshake + auth + backend spawn on every request | Connection pooling (§18.12) |

The rest of the chapter expands each row into a full "diagnose → fix →
verify" workflow.

---

## 18.2 Filter early, reduce rows fast

**The anti-pattern.** Compute a wide result set, then filter or aggregate it
further downstream — in SQL or in application code — when the filter could
have been pushed to the very first operation that touches the table.

```sql
-- Anti-pattern: fetch every order, decide in the application which ones
-- are "recent" and "delivered"
SELECT order_id, user_id, order_date, status
FROM ecommerce_db.orders;
-- application code then does: rows.filter(r => r.status === 'DELIVERED'
--   && r.order_date > thirtyDaysAgo)
```

Every row that crosses the network just to be thrown away in application
code cost real I/O, real serialization, and real bandwidth for nothing.

**The fix.** Push the filter into the query:

```sql
SELECT order_id, user_id, order_date, status
FROM ecommerce_db.orders
WHERE status = 'DELIVERED'
  AND order_date > now() - INTERVAL '30 days';
```

**Aggregation ordering matters too.** If you're aggregating and then
filtering on a *non-aggregated* column, filter before you `GROUP BY`, not
after:

```sql
-- Slower: aggregates ALL orders across ALL time, then narrows with HAVING
-- on a column that didn't need aggregation to filter
SELECT user_id, COUNT(*) AS order_count
FROM ecommerce_db.orders
GROUP BY user_id
HAVING user_id IN (SELECT user_id FROM ecommerce_db.users WHERE is_active);

-- Faster: filter the driving rows first, then aggregate only what's left
SELECT o.user_id, COUNT(*) AS order_count
FROM ecommerce_db.orders o
JOIN ecommerce_db.users u ON u.user_id = o.user_id AND u.is_active
GROUP BY o.user_id;
```

`HAVING` is for filtering on the *result of aggregation* (e.g.
`HAVING COUNT(*) > 5`). Anything that could be a `WHERE` predicate on a
non-aggregated column belongs in `WHERE`, evaluated before grouping, because
`WHERE` shrinks the row set the aggregate has to churn through.

> **Important Note.** In PostgreSQL, the planner will often push predicates
> down through joins and views automatically (predicate pushdown, Ch. 17).
> Writing the filter "in the wrong place" syntactically doesn't always cost
> you at runtime — but relying on the optimizer to rescue a badly-shaped
> query is fragile: it works today, on this planner version, with today's
> statistics, and may not tomorrow. Write the filter where it logically
> belongs; don't count on inference to save a lazily-written query.

**When this is *not* the bottleneck.** If your table is small (hundreds to
low thousands of rows, like every table in `ecommerce_db`), filtering early
vs. late is immeasurable — the entire table fits in one disk page or the
buffer cache regardless. This principle earns its keep on tables with real
row counts (`analytics_db.sales_fact` at 5,000,000 rows, or any production
table past ~100K rows).

---

## 18.3 Index optimization — the practical checklist

Chapter 16 covered index *internals*. This is the *decision workflow* for
"what should I index, and in what order?" Run through it whenever you're
staring at a slow query.

**Step 1 — Identify candidate columns.** Look at the query's `WHERE`,
`JOIN ... ON`, and `ORDER BY` clauses. Those are your only candidates — an
index on a column that appears nowhere in a filter, join, or sort does
nothing for that query.

**Step 2 — Check selectivity.** An index only helps if it lets the
executor skip a meaningful fraction of rows. A column like `orders.status`
with 5 possible values across millions of rows (low selectivity) benefits
far less from a plain B-tree than `orders.order_id` (unique, maximum
selectivity) or `users.email` (near-unique). Check actual selectivity
before indexing:

```sql
SELECT status, COUNT(*), COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS pct
FROM ecommerce_db.orders
GROUP BY status
ORDER BY pct DESC;
```

If one value covers 90% of rows, an index on that column alone won't help
queries filtering for that common value (a sequential scan is often
cheaper) — but it will help queries filtering for a *rare* value. This is
exactly the row-count-driven decision the planner makes for you (Ch. 17);
checking selectivity yourself just tells you whether it's worth the index's
write-amplification cost in the first place.

**Step 3 — Composite index column order.** For a multi-column index,
order matters:

1. **Equality columns first** — columns compared with `=` in your `WHERE`.
2. **Range/inequality columns next** — `>`, `<`, `BETWEEN`.
3. **`ORDER BY` columns last** — so the index can also satisfy the sort
   (§18.6) without a separate `Sort` node.

```sql
-- Query: recent delivered orders for one user
SELECT order_id, order_date
FROM ecommerce_db.orders
WHERE user_id = 1 AND status = 'DELIVERED'
ORDER BY order_date DESC;

-- Composite index matching that shape:
CREATE INDEX idx_orders_user_status_date
ON ecommerce_db.orders (user_id, status, order_date DESC);
```

Reversing the order (`status, user_id, order_date`) would still work
correctness-wise, but if `status` is far less selective than `user_id`, the
index scan has to walk through more entries before narrowing down — put the
more selective equality column first among equality columns, generally.

**Step 4 — Avoid redundant indexes.** A single-column index on
`(user_id)` is redundant once you have a composite index on
`(user_id, status, order_date)` — the composite index already serves any
query that filters on `user_id` alone (a B-tree on `(a, b, c)` can be used
as if it were an index on `(a)` for leading-column lookups). Redundant
indexes cost write overhead and disk space with zero read benefit. Audit
for them:

```sql
-- PostgreSQL: list indexes per table to spot redundancy by eye
SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'ecommerce_db' AND tablename = 'orders';
```

**Step 5 — Find unused indexes.** Every index you keep is pure write-path
cost if nothing ever reads it. **[PostgreSQL]**

```sql
SELECT s.relname AS table_name, s.indexrelname AS index_name, s.idx_scan
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE NOT i.indisprimary
ORDER BY s.idx_scan ASC;
```

An index with `idx_scan = 0` after a representative period of production
traffic is a strong candidate for dropping — but confirm against a long
enough observation window; an index built for a monthly report will show
zero scans on any day but the report day.

> **Common mistakes**
> - Indexing every column "just in case." Each index slows down every
>   `INSERT`/`UPDATE`/`DELETE` that touches an indexed column, because the
>   index has to be maintained too.
> - Indexing a low-cardinality boolean/flag column alone and expecting a
>   big win — the planner will often ignore it in favor of a sequential
>   scan if the filtered value isn't rare (see Step 2).
> - Forgetting `ORDER BY ... DESC` needs a `DESC` (or reversed) index
>   definition to be scanned without a runtime re-sort in some cases —
>   Ch. 17 covers when the planner can walk a B-tree backwards for free vs.
>   when it can't.
> - Adding an index and never checking whether the planner actually chose
>   to use it (`EXPLAIN`, Ch. 17). An index that exists but isn't chosen
>   fixes nothing.

---

## 18.4 Join optimization

**Simple explanation.** A join's cost is driven by (a) how many rows from
each side make it into the join, and (b) whether the join columns are
indexed so the planner can choose a fast join algorithm (nested loop with
index lookup, hash join, merge join — Ch. 17).

**Principle 1 — join on indexed columns.** Foreign key columns should
almost always carry an index on the referencing side (PostgreSQL indexes
the *referenced* primary key automatically, but **not** the referencing
foreign key column — that's on you):

```sql
-- order_items.order_id is a foreign key but has NO index by default
-- in the ecommerce_db schema beyond the implicit index backing the
-- UNIQUE (order_id, product_id) constraint. That composite unique index
-- *does* cover order_id as its leading column, so joins on order_id alone
-- are still served. If it didn't, this join would sequential-scan
-- order_items for every order:
SELECT o.order_id, oi.product_id, oi.quantity
FROM ecommerce_db.orders o
JOIN ecommerce_db.order_items oi ON oi.order_id = o.order_id
WHERE o.user_id = 1;
```

**Principle 2 — filter before joining, where the filter doesn't depend on
the join.** If a predicate only touches one side of the join, apply it
before the join multiplies row counts:

```sql
-- Anti-pattern: join everything, then throw away non-matching rows
SELECT u.username, o.order_id, o.status
FROM ecommerce_db.users u
JOIN ecommerce_db.orders o ON o.user_id = u.user_id
WHERE u.is_active = TRUE AND o.status = 'DELIVERED';
```

The PostgreSQL planner will typically push both predicates down to their
respective table scans automatically — but understanding this yourself
matters because (a) it explains *why* certain plans look the way they do in
`EXPLAIN`, and (b) it stops you from writing filters in places (like a
post-join CTE with `OFFSET`/`LIMIT` that blocks pushdown) that accidentally
prevent the optimizer from doing this for you.

**Principle 3 — join order matters on large tables.** For small tables
like everything in `ecommerce_db`, join order is invisible — the whole
dataset fits in memory and any order finishes instantly. On large tables,
the planner chooses join order based on cardinality estimates (Ch. 17): it
generally wants to start from the most selective filtered table and grow
the row set from there, rather than starting from an unfiltered
multi-million-row table and joining outward. You don't usually need to
specify join order manually in PostgreSQL — the planner enumerates orders
itself for reasonably sized join graphs — but you *do* need accurate
statistics (§18.10) for it to estimate cardinalities correctly, and for
very large join graphs (`join_collapse_limit`) you may need to know the
planner switches to a greedy heuristic rather than exhaustive search.

**Principle 4 — don't join tables whose columns you don't use.** A join
you don't need is pure overhead, and worse, it can silently multiply or
drop rows if the cardinality isn't 1:1:

```sql
-- Anti-pattern: joining reviews when the query never uses any review column
SELECT o.order_id, o.order_date, u.username
FROM ecommerce_db.orders o
JOIN ecommerce_db.users u ON u.user_id = o.user_id
LEFT JOIN ecommerce_db.reviews r ON r.user_id = u.user_id
WHERE o.status = 'DELIVERED';
```

This join is not just wasted work — because a user can have multiple
reviews, the `LEFT JOIN` to `reviews` **duplicates each order row** once per
review the user has written, silently corrupting a report that expects one
row per order. Drop the join entirely:

```sql
SELECT o.order_id, o.order_date, u.username
FROM ecommerce_db.orders o
JOIN ecommerce_db.users u ON u.user_id = o.user_id
WHERE o.status = 'DELIVERED';
```

If you need to *test* related existence (e.g., "only users who have written
at least one review") without pulling in review columns or risking
duplication, use `EXISTS` instead of a join — it's a semi-join, and rows
from the outer table are never multiplied:

```sql
SELECT o.order_id, o.order_date, u.username
FROM ecommerce_db.orders o
JOIN ecommerce_db.users u ON u.user_id = o.user_id
WHERE o.status = 'DELIVERED'
  AND EXISTS (SELECT 1 FROM ecommerce_db.reviews r WHERE r.user_id = u.user_id);
```

> **When "fixing" a join is unnecessary.** If a join is on a properly
> indexed key, filters both sides down to a small row count, and the
> `EXPLAIN` plan already shows a cheap nested loop or hash join with an
> actual runtime in single-digit milliseconds — leave it alone. Rewriting a
> join that isn't the bottleneck (chasing a "best practice" instead of a
> measured cost) is premature optimization.

---

## 18.5 Avoiding unnecessary `SELECT *`

**Simple explanation.** `SELECT *` retrieves every column defined on the
table (or view), regardless of what the caller actually uses.

**Why it matters — the concrete costs:**

1. **More I/O.** The database must read every column's data off disk (or
   buffer cache) for every row, even columns like `review_text` or
   `shipping_address` that a report never displays.
2. **More network transfer.** Every extra byte serialized and sent to the
   client is bandwidth and client-side deserialization time you didn't
   need to pay for. This compounds badly over high row counts or when the
   client is on a slower network hop (mobile clients, cross-region calls).
3. **Breaks index-only scans.** As covered in Ch. 16, an index-only scan
   lets PostgreSQL answer a query entirely from the index's own leaf
   pages, skipping the heap (table) entirely — but only if *every* column
   the query needs is present in the index (either as a key column or via
   `INCLUDE`). `SELECT *` forces the planner to visit the heap for columns
   that were never part of the index, discarding that optimization even
   when the underlying index is perfectly suited to the filter and sort.
4. **Fragile to schema changes.** `SELECT *` silently starts returning a
   new column the moment someone adds one to the table — breaking
   assumptions like "column N is always the 5th column" in positional
   application code, ballooning payload size the day a `TEXT` column with
   large values is added, and quietly changing the shape of view results.
5. **Larger row transfer for ORMs.** ORMs frequently hydrate a full model
   object per row when you `SELECT *` (or use the ORM's unrestricted
   `.all()`/`.find()` equivalent) — instantiating and mapping fields you
   never read, multiplying both the query cost and the application-side
   object-construction cost.

**The anti-pattern:**

```sql
SELECT * FROM ecommerce_db.products
WHERE category_id = 2
ORDER BY created_at DESC;
```

**The fix** — select only what the report/page actually displays:

```sql
SELECT product_name, price, sku, created_at
FROM ecommerce_db.products
WHERE category_id = 2
ORDER BY created_at DESC;
```

Combine with a covering index (Ch. 16) so this becomes an index-only scan:

```sql
CREATE INDEX idx_products_category_created
ON ecommerce_db.products (category_id, created_at DESC)
INCLUDE (product_name, price, sku);
```

Now every column the query needs — the filter (`category_id`), the sort
(`created_at`), and the projection (`product_name`, `price`, `sku`) — lives
in the index itself. See Case Study 1 (§18.14) for the full before/after.

> **Edge case.** `SELECT *` is completely fine — and often preferable —
> in ad hoc exploration at a `psql` prompt, in `EXISTS (SELECT * FROM ...)`
> subqueries (the `*` there is never actually evaluated; convention is to
> write `SELECT 1` anyway for clarity), or when you genuinely need every
> column and the table has few columns to begin with. The problem is
> `SELECT *` **baked into application code, views, or reports** where the
> column set is unbounded, unreviewed, and grows silently over the table's
> lifetime.

---

## 18.6 Avoiding unnecessary sorting

**Simple explanation.** `ORDER BY` that the caller doesn't need, or that
could be satisfied by an index's natural key order instead of a runtime
`Sort` operator, is wasted work.

**Anti-pattern 1 — sorting that serves no purpose downstream:**

```sql
-- Sorting before an aggregate that doesn't care about row order
SELECT status, COUNT(*)
FROM (
    SELECT * FROM ecommerce_db.orders ORDER BY order_date DESC
) sub
GROUP BY status;
```

The inner `ORDER BY` does nothing here — `GROUP BY` doesn't preserve or
need input ordering, so this sort is pure overhead. Just remove it:

```sql
SELECT status, COUNT(*)
FROM ecommerce_db.orders
GROUP BY status;
```

**Anti-pattern 2 — a sort the planner has to do at runtime, when an index
could pre-sort instead.** As covered in Ch. 17, a plan with a `Sort` node
means PostgreSQL materialized the intermediate rows and sorted them in
memory (or spilled to disk for large sets — watch for `Sort Method:
external merge` in `EXPLAIN ANALYZE`). If there's a B-tree index whose key
order matches your `ORDER BY`, the planner can instead walk the index in
order and skip the `Sort` node entirely:

```sql
-- Without a supporting index: Sort node over all matching rows
SELECT sale_id, sale_date, amount
FROM analytics_db.sales_fact
WHERE customer_key = 42
ORDER BY sale_date DESC;
```

`idx_sales_fact_customer` (on `customer_key` alone) filters efficiently but
can't help with the sort — PostgreSQL still sorts the matching rows at
runtime. Extending the index to include the sort column lets a single
index scan serve both jobs:

```sql
CREATE INDEX idx_sales_fact_customer_date
ON analytics_db.sales_fact (customer_key, sale_date DESC);
```

Now the plan can become an `Index Scan` that returns rows already in
`sale_date DESC` order — no `Sort` node at all. Verify with `EXPLAIN
ANALYZE` (Ch. 17): the absence of a `Sort` operator, and a lower total
cost/runtime, confirms it worked.

> **When this is premature.** If the result set being sorted is small
> (a few thousand rows or fewer after filtering), an in-memory `Sort` node
> costs microseconds — not worth a dedicated index just to eliminate it.
> Reserve sort-avoidance indexing for sorts over large filtered row counts,
> or sorts that repeat on every page load of a high-traffic listing page.

---

## 18.7 Pagination optimization

Chapter 4 introduced `OFFSET`/`LIMIT` vs. keyset (seek) pagination as two
ways to page through results. This section is the *performance* case for
why that choice matters once your table is large — not just a syntax
comparison.

**The problem with `OFFSET` at depth.** `OFFSET n` doesn't skip rows for
free — the database must still *generate* (scan, filter, and often sort)
all `n` skipped rows before it can discard them and return the next page.
The deeper the page, the more work is thrown away.

```sql
-- Page 1: cheap. Page 80,000: the database has already produced and
-- discarded 4,000,000 rows before returning these 50.
SELECT sale_id, sale_date, customer_key, amount
FROM analytics_db.sales_fact
ORDER BY sale_date, sale_id
OFFSET 4000000 LIMIT 50;
```

**Illustrative benchmark-style numbers** (approximate, against
`analytics_db.sales_fact` at 5,000,000 rows, index on `(sale_date,
sale_id)`; actual numbers vary by hardware and cache state):

| Page depth (`OFFSET`) | Approx. latency |
|---|---|
| 0 (first page) | ~2 ms |
| 100,000 | ~60 ms |
| 1,000,000 | ~350 ms |
| 4,000,000 | ~1,200 ms |

Latency grows roughly linearly with offset depth — page 80,000 of a report
is dramatically slower than page 1, even though both return exactly 50
rows. This is the single most common "the report is fast until someone
clicks 'next' fifty times" bug in production reporting UIs.

**The fix — keyset (seek) pagination.** Instead of asking "skip N rows,"
ask "give me rows after the last one I saw":

```sql
-- First page
SELECT sale_id, sale_date, customer_key, amount
FROM analytics_db.sales_fact
ORDER BY sale_date, sale_id
LIMIT 50;

-- Next page: caller remembers (sale_date, sale_id) of the last row returned
SELECT sale_id, sale_date, customer_key, amount
FROM analytics_db.sales_fact
WHERE (sale_date, sale_id) > ('2023-06-15', 3182045)
ORDER BY sale_date, sale_id
LIMIT 50;
```

With a supporting composite index on `(sale_date, sale_id)`, this query
does an index range scan straight to the seek point and reads exactly 50
rows forward — **regardless of how deep into the dataset that seek point
is.** Illustrative latency: **~3–5 ms whether it's page 2 or page 80,000.**

| | `OFFSET`/`LIMIT` | Keyset (seek) |
|---|---|---|
| Cost at shallow depth | Cheap | Cheap |
| Cost at deep pages | Grows linearly with offset | Roughly constant |
| Supports "jump to page N" | Yes, natively | No — sequential only (or requires precomputed anchor points) |
| Stable under concurrent inserts | No — rows can shift between pages, causing skips/duplicates | Yes — seek key is stable |
| Implementation complexity | Trivial (`OFFSET`/`LIMIT`) | Slightly more (must track and pass the last-seen key) |

See Case Study 3 (§18.14) for the full rewrite against `sales_fact`.

> **Important Note.** Keyset pagination requires a stable, indexed,
> deterministic sort key (a unique column, or a tuple that's unique
> together, like `(sale_date, sale_id)` here since `sale_id` alone is
> unique). Paginating on a non-unique column without a tiebreaker can skip
> or duplicate rows across pages — always include a unique column as the
> final tiebreaker in both the `ORDER BY` and the seek predicate.

> **When `OFFSET` is fine.** Small tables, shallow pagination (most users
> never go past page 2 or 3 of a UI), or admin tools where "jump to page
> 500" genuinely needs to be supported and depth is bounded — `OFFSET` is
> simpler to implement and perfectly adequate. Don't rebuild every
> paginated endpoint in your codebase around keyset pagination preemptively;
> reserve it for pagination over large, deep, or high-traffic result sets.

**[MySQL] [Oracle] [SQL Server]** The `OFFSET` cost problem is universal —
every relational engine must generate and discard skipped rows the same
way. Syntax differs (`LIMIT ... OFFSET ...` in PostgreSQL/MySQL,
`OFFSET ... ROWS FETCH NEXT ... ROWS ONLY` in SQL Server and standard SQL,
`OFFSET`/`FETCH` or `ROWNUM`/`ROW_NUMBER()` tricks in older Oracle), but
the keyset rewrite pattern (`WHERE (sort_cols) > (last_seen_values)`)
applies identically everywhere.

---

## 18.8 Subquery optimization

**Simple explanation.** A **correlated** subquery references a column from
the outer query and, conceptually, re-runs once per outer row. An
**uncorrelated** subquery runs once, independent of the outer rows. The
performance risk lives almost entirely in the correlated case.

**The anti-pattern — a correlated subquery in `WHERE` that recomputes an
aggregate per row:**

```sql
-- Runs the inner AVG() subquery once per row of sales_fact
SELECT sf.sale_id, sf.customer_key, sf.amount
FROM analytics_db.sales_fact sf
WHERE sf.amount > (
    SELECT AVG(sf2.amount)
    FROM analytics_db.sales_fact sf2
    WHERE sf2.customer_key = sf.customer_key
);
```

Conceptually — and, absent a smart optimizer rewrite, often literally — the
inner query re-scans/re-aggregates `sales_fact` filtered to one customer,
once for **every one of the 5,000,000 outer rows**. Even though there are
only 5,000 distinct customers, nothing here tells the engine to compute
each customer's average just once.

**The fix — a window function**, computing the per-customer average in a
single pass over the data:

```sql
SELECT sale_id, customer_key, amount
FROM (
    SELECT sale_id, customer_key, amount,
           AVG(amount) OVER (PARTITION BY customer_key) AS customer_avg
    FROM analytics_db.sales_fact
) windowed
WHERE amount > customer_avg;
```

**Or, equivalently, a pre-aggregated join:**

```sql
WITH customer_avg AS (
    SELECT customer_key, AVG(amount) AS avg_amount
    FROM analytics_db.sales_fact
    GROUP BY customer_key
)
SELECT sf.sale_id, sf.customer_key, sf.amount
FROM analytics_db.sales_fact sf
JOIN customer_avg ca ON ca.customer_key = sf.customer_key
WHERE sf.amount > ca.avg_amount;
```

Both rewrites compute each customer's average exactly once (5,000
computations, not 5,000,000), then compare each row against its
already-computed average. See Case Study 4 (§18.14) for illustrative
timings.

> **⚠️ Warning — don't over-optimize blindly.** Modern PostgreSQL (9.5+ for
> `IN`, and increasingly capable in later versions) is often smart enough
> to automatically rewrite a correlated `EXISTS`/`IN`/`NOT EXISTS` subquery
> into a semi-join or anti-join internally — meaning the "obviously slow"
> shape:
> ```sql
> SELECT o.order_id
> FROM ecommerce_db.orders o
> WHERE EXISTS (
>     SELECT 1 FROM ecommerce_db.payments p
>     WHERE p.order_id = o.order_id AND p.status = 'SUCCESS'
> );
> ```
> frequently executes as an efficient semi-join in the actual plan, **not**
> as a naive per-row re-scan. Check `EXPLAIN` (Ch. 17) before assuming an
> `EXISTS` subquery needs rewriting — you may find the planner already
> produced a `Hash Semi Join` and a manual rewrite to `JOIN ... GROUP BY`
> would change nothing (or, if the join introduces duplicate rows that need
> a `DISTINCT` to correct, would actively make it *worse*). The subquery
> shapes that reliably benefit from manual rewriting are the ones like the
> `AVG()` example above, where the subquery computes a **per-group
> aggregate that isn't a simple existence test** — that pattern isn't
> eligible for the semi-join rewrite regardless of engine version.

**Comparison of subquery strategies:**

| Shape | Optimizer usually handles it well? | Manual rewrite worth it? |
|---|---|---|
| `WHERE EXISTS (correlated existence test)` | Often — auto semi-join | Usually not; verify with `EXPLAIN` first |
| `WHERE col IN (correlated subquery)` | Often — auto semi-join | Usually not; verify with `EXPLAIN` first |
| `WHERE col > (correlated aggregate subquery)` | Rarely rewritten automatically | Yes — window function or pre-aggregated join |
| Subquery in `SELECT` list, evaluated per row | Rarely rewritten automatically | Yes — `LEFT JOIN` to a pre-aggregated CTE, or window function |
| Uncorrelated subquery (`IN (SELECT ... static)`) | Runs once regardless | Rarely needs rewriting |

---

## 18.9 CTE considerations

Chapter 9 covered CTE mechanics and materialization behavior in depth. The
practical guidance for optimization purposes:

**Don't be afraid of CTEs for readability.** In PostgreSQL 12 and later,
a non-recursive CTE that's referenced exactly once is eligible for
**inlining** — the planner folds it into the surrounding query as if you'd
written a subquery or join directly, and optimizes it as one unit. This
reversed PostgreSQL's old pre-12 behavior (where every CTE was an opaque
"optimization fence"). Structuring a complex query as a sequence of clearly
named CTEs is good engineering practice and, on 12+, usually costs nothing
at runtime:

```sql
WITH recent_orders AS (
    SELECT order_id, user_id, order_date
    FROM ecommerce_db.orders
    WHERE order_date > now() - INTERVAL '90 days'
),
order_totals AS (
    SELECT ro.order_id, ro.user_id, SUM(oi.quantity * oi.unit_price) AS total
    FROM recent_orders ro
    JOIN ecommerce_db.order_items oi ON oi.order_id = ro.order_id
    GROUP BY ro.order_id, ro.user_id
)
SELECT user_id, SUM(total) AS spend_90d
FROM order_totals
GROUP BY user_id;
```

On PostgreSQL 12+, this typically plans identically to writing the whole
thing as nested subqueries — readability is free.

**When you want a materialization barrier on purpose — `MATERIALIZED`.**
Force a CTE to compute once and be reused as a physical intermediate
result when it's:

- **referenced multiple times**, and re-running its logic per reference
  would be wasteful, or
- **expensive** and you want to guarantee it's computed exactly once
  regardless of what the planner might otherwise choose, or
- built around a **volatile function** (e.g., something with side effects
  or non-deterministic output) where re-evaluation per reference would be
  outright incorrect, not just slow.

```sql
WITH MATERIALIZED customer_lifetime_value AS (
    SELECT customer_key, SUM(amount) AS ltv
    FROM analytics_db.sales_fact
    GROUP BY customer_key
)
SELECT c.segment, AVG(clv.ltv) AS avg_ltv, COUNT(*) AS n
FROM customer_lifetime_value clv
JOIN analytics_db.dim_customer c ON c.customer_key = clv.customer_key
GROUP BY c.segment
```

Here `customer_lifetime_value` scans all 5,000,000 fact rows once,
producing 5,000 aggregated rows, which are then joined and grouped
cheaply. Without `MATERIALIZED` this particular example would inline fine
too since it's referenced once — but if a second reference to
`customer_lifetime_value` were added later in the same query (e.g., a
second `SELECT` combined with `UNION ALL` also using it), `MATERIALIZED`
guarantees the expensive aggregation isn't repeated per reference.

**When you want to force inlining despite multiple references or
recursion boundaries — `NOT MATERIALIZED`.** Rare, but available when you
specifically want the planner's cross-boundary optimization (e.g.,
predicate pushdown into the CTE body) even though the CTE is referenced
more than once, and you've measured that recomputing it per reference (now
optimized in the context of each caller) is actually cheaper than
materializing an unfiltered intermediate result once.

```sql
WITH NOT MATERIALIZED base AS (
    SELECT * FROM analytics_db.sales_fact
)
SELECT * FROM base WHERE customer_key = 42
UNION ALL
SELECT * FROM base WHERE customer_key = 99;
```

Without `NOT MATERIALIZED`, PostgreSQL 12+ would already choose to inline
here by default only if `base` weren't referenced twice — with two
references it defaults toward materializing. `NOT MATERIALIZED` overrides
that default, letting the `customer_key = 42` and `= 99` filters push down
into two independent, cheap index scans instead of one giant materialized
5,000,000-row copy.

> **Common mistake.** Assuming *all* CTEs in *any* PostgreSQL version
> inline. Recursive CTEs (Ch. 9's recursive CTE chapter content) are never
> inlined — they're inherently iterative and must materialize each
> iteration. And on PostgreSQL versions before 12, every CTE was an
> optimization fence by default, so code written and tuned against an old
> Postgres, or ported from a codebase supporting 11 and earlier, may carry
> unnecessary `MATERIALIZED`-equivalent assumptions (or unnecessary
> subquery-flattening workarounds) baked in that no longer reflect current
> defaults.

---

## 18.10 Statistics and `ANALYZE`

**Simple explanation.** The planner's cost-based decisions (Ch. 17) —
which join algorithm, which index, which join order — depend entirely on
its *estimate* of how many rows each step will produce. Those estimates
come from statistics PostgreSQL keeps about each table: approximate row
counts, most-common values, histograms of value distribution, and
correlation between physical row order and column values. `ANALYZE`
recomputes those statistics.

**Why stale statistics cause bad plans.** If a table's actual data has
changed dramatically since the last `ANALYZE` — a bulk load 10x'd its row
count, a backfill skewed a column's value distribution, a large batch
delete emptied most of a partition — the planner is working from an
estimate that no longer matches reality. As covered in Ch. 17's
cardinality estimation discussion, a bad row-count estimate can flip the
planner from a cheap index scan to an expensive sequential scan (or the
reverse), or pick a nested loop join where a hash join was clearly better,
purely because the estimated row counts feeding that decision were wrong.

**When to run `ANALYZE` manually:**

- **After a bulk load.** `COPY`-ing millions of rows in, or running a
  large batch `INSERT`, changes the table's statistics profile
  dramatically and immediately — don't wait for autovacuum's schedule.
  ```sql
  COPY analytics_db.sales_fact FROM '/path/to/bulk_load.csv' WITH (FORMAT csv);
  ANALYZE analytics_db.sales_fact;
  ```
- **Before running a performance-critical query** against a table you
  know has recently changed a lot (post-migration, post-backfill,
  post-large-delete), especially before benchmarking or before a report
  that must run fast the first time.
- **After changing a column's data distribution** in a way that wouldn't
  necessarily trip autovacuum's row-count-based threshold — e.g., a batch
  `UPDATE` that doesn't change row *count* but does change value
  distribution (updating every `status` to a single new value, say).

**Autovacuum and auto-analyze. [PostgreSQL]** PostgreSQL runs autovacuum
workers that automatically trigger an `ANALYZE` (and `VACUUM`) once a
table's estimated number of changed rows crosses a threshold (by default,
roughly 10% of the table plus a base amount — governed by
`autovacuum_analyze_scale_factor` and `autovacuum_analyze_threshold`).
This is usually sufficient for steady, gradual write traffic. It is *not*
always fast enough to catch up immediately after a single enormous bulk
operation, and on very large tables the default scale factor means a huge
absolute number of rows must change before autovacuum reacts. Chapter 29
(Database Internals) covers autovacuum's full mechanics, tuning knobs, and
interaction with MVCC and dead tuple cleanup — the practical takeaway here
is: **know that autovacuum exists and usually has you covered, but run
`ANALYZE` by hand immediately after any bulk operation rather than trusting
autovacuum's timing for a query you're about to run right now.**

Check when a table was last analyzed:

```sql
SELECT relname, last_analyze, last_autoanalyze, n_mod_since_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'analytics_db'
ORDER BY n_mod_since_analyze DESC;
```

A large `n_mod_since_analyze` relative to the table's total row count, with
an old (or null) `last_analyze`/`last_autoanalyze`, is a signal the
planner may be working from outdated assumptions.

**[MySQL]** `ANALYZE TABLE table_name;` serves the same purpose, updating
index cardinality statistics used by the optimizer. **[Oracle]**
`DBMS_STATS.GATHER_TABLE_STATS` (often scheduled automatically, but run
manually after bulk loads). **[SQL Server]** `UPDATE STATISTICS
table_name;`, with auto-update statistics enabled by default but subject
to the same "large bulk change outruns the automatic threshold" caveat.

> **⚠️ Warning.** A query that "used to be fast and suddenly got slow"
> with no code change is one of the most common statistics-related support
> tickets. Before hypothesizing about the query itself, check
> `last_analyze`/`last_autoanalyze` and recent row-count changes on every
> table involved. Running `ANALYZE` and re-testing costs almost nothing and
> rules out (or fixes) an entire class of problem in seconds.

---

## 18.11 Partitioning as a performance lever

Chapter 26 covers partitioning in full — physical layout, partition types,
constraint exclusion, attaching/detaching partitions, and maintenance. Here
the connection to query optimization is narrow but important: **partition
pruning**.

`analytics_db.sales_fact` is already declared `PARTITION BY RANGE
(sale_date)` with three partitions (`sales_fact_2022`, `sales_fact_2023`,
`sales_fact_2024`). When a query's `WHERE` clause filters on the partition
key, the planner can prove entire partitions can't contain matching rows
and skip scanning them altogether — never opening those files, never
consulting their indexes, never touching their statistics:

```sql
EXPLAIN SELECT SUM(amount)
FROM analytics_db.sales_fact
WHERE sale_date >= '2024-01-01' AND sale_date < '2024-02-01';
```

The plan shows only `sales_fact_2024` scanned — `sales_fact_2022` and
`sales_fact_2023` are pruned out entirely before execution begins, because
their partition bounds provably can't overlap `[2024-01-01, 2024-02-01)`.
For a query touching one month out of three years of data, pruning is the
difference between scanning roughly 1/36th of the table and scanning all
of it.

**The performance lever, stated plainly:** if your queries consistently
filter on a natural range column (date being the overwhelmingly common
case), partitioning on that column turns "scan everything, then filter" —
even with an index, that's still a lot of index entries — into "only
consider the partitions that could possibly match, mostly skipping the
rest before an index is even consulted." It's a complementary technique to
indexing, not a replacement: you still want indexes *within* each
partition for anything partition pruning alone can't narrow down (like
`customer_key` filters that cross partition boundaries).

> **When partitioning is *not* the answer.** Partitioning adds real
> operational complexity (Ch. 26) — partition maintenance, constraints on
> what indexes/constraints are possible, more complex `EXPLAIN` output. It
> pays off at genuinely large table sizes (the rule of thumb is often
> tens of millions of rows and up, or a clear operational need like
> "drop last year's data by dropping a partition instead of a slow
> `DELETE`") and when queries reliably filter on the partition key. A table
> the size of anything in `ecommerce_db`, or a workload whose queries don't
> filter on the candidate partition column, gets none of partition
> pruning's benefit and all of its complexity cost.

---

## 18.12 Connection pooling

**Simple explanation.** Every new database connection is expensive to
establish — far more expensive than most application developers expect,
because it happens beneath the application's query logic entirely.

**Why opening a connection is expensive:**

1. **TCP handshake.** A new network connection requires the standard
   SYN/SYN-ACK/ACK round trip before any application bytes flow at all.
2. **Authentication.** The client and server must negotiate and verify
   credentials (e.g., PostgreSQL's SCRAM-SHA-256 challenge-response),
   another round trip (or more) before the connection is usable.
3. **Backend process/thread spawn.** **[PostgreSQL]** PostgreSQL's process
   model forks (or otherwise allocates) a dedicated backend *process* per
   connection — not a lightweight thread. That process initializes its own
   memory context, catalog caches, and per-connection state. This is
   meaningfully heavier than a thread spawn, and it's the specific reason
   PostgreSQL, more than most engines, benefits from external connection
   pooling rather than opening connections freely. **[MySQL] [SQL Server]**
   These engines use threads rather than a process-per-connection model,
   which is lighter weight per-connection but still non-trivial under high
   connection churn.

Multiply this by "a web application opens a fresh connection per incoming
HTTP request" and you're paying full connection setup cost on the hot path
of every single request — often costing more wall-clock time than the
query itself.

**What a connection pooler does.** A pool maintains a set of already-open,
already-authenticated connections and hands them out to callers on
request, returning them to the pool when the caller is done — paying the
handshake/auth/spawn cost once per pooled connection instead of once per
request.

- **[PostgreSQL]** **PgBouncer** is the standard external pooler, sitting
  between the application and PostgreSQL. It supports three pooling modes:
  *session* (a client keeps one backend connection for its whole session —
  safest, least reuse), *transaction* (a backend connection is only
  claimed for the duration of one transaction, then returned to the pool —
  the most common production choice, enabling far more application
  connections than backend processes), and *statement* (returned after
  each statement — most aggressive, incompatible with multi-statement
  transactions). `pgbouncer` and PostgreSQL's built-in
  `max_connections` work together: the pooler absorbs thousands of
  application-side connections into a much smaller number of real backend
  connections.
- **[MySQL]** ProxySQL or the MySQL thread pool plugin serve a similar
  role — decoupling client connection count from backend thread/connection
  count.
- **[Oracle]** Database Resident Connection Pooling (DRCP), or the Oracle
  Universal Connection Pool (UCP) at the application/driver layer.
- **[SQL Server]** Connection pooling is typically handled client-side, in
  ADO.NET/ODBC/JDBC driver layers, which maintain their own pools
  transparently.
- **Application-framework pools** (independent of the database engine):
  HikariCP (Java), SQLAlchemy's connection pool (Python), `node-postgres`'s
  `Pool`, Django's `CONN_MAX_AGE`/persistent connections. These sit inside
  the application process and often work *in front of* a database-side
  pooler like PgBouncer in a production topology (app pool → PgBouncer →
  PostgreSQL backends).

**Too many connections vs. too few — both hurt, differently:**

| Failure mode | What happens | Symptom |
|---|---|---|
| **Too many connections allowed / opened at once ("connection storm")** | Every connection consumes backend memory (each PostgreSQL backend process holds its own catalog caches, work_mem allocations, etc.) and competes for CPU/lock resources; a mass simultaneous reconnect (e.g., after an app deployment restarts every worker at once) can spike backend count far past what the database can serve concurrently | Database CPU/memory exhaustion, degraded latency for *every* connection, sometimes outright connection refusals once `max_connections` is hit |
| **Too few connections in the pool** | Application requests queue up waiting for a connection to free up, even though the database itself is idle and could serve more | Requests pile up and time out under load despite low database CPU usage — a queuing bottleneck entirely in front of the database |

Sizing a pool is a matter of matching the pool to what the *database* can
comfortably serve concurrently (informed by CPU core count, storage
throughput, and typical query duration) — not maximizing the application's
theoretical concurrency. A pool that's too large just moves the queue from
the application to the database's own internal contention; a pool that's
too small creates an artificial queue in front of a database with capacity
to spare.

> **Important Note.** Connection pooling is an infrastructure/architecture
> lever, not a query rewrite — but it belongs in this chapter because a
> perfectly optimized query still performs terribly if every invocation of
> it pays full connection-establishment cost first. For request-heavy
> applications making frequent, short-lived queries, pooling often yields
> a bigger end-to-end latency win than any single query rewrite in this
> chapter.

---

## 18.13 The N+1 query problem

**Simple explanation.** The N+1 problem happens when code fetches a list
of N parent rows with one query, then — in a loop, in application code —
issues one additional query *per parent row* to fetch related child data.
Total queries: 1 (the list) + N (one per parent) = **N+1**.

**Concrete ORM-style narrative.** An order-listing page for a user needs
to show each order along with its line items. A naive (and extremely
common) ORM-driven implementation does this:

```sql
-- Query 1: fetch the user's orders
SELECT order_id, order_date, status
FROM ecommerce_db.orders
WHERE user_id = 1;
```

The application then loops over the returned orders, and for **each one**,
the ORM lazily fires a fresh query to load that order's items:

```sql
-- Fired once per order, inside the loop — this is query 2, 3, 4, ... N+1
SELECT order_item_id, product_id, quantity, unit_price
FROM ecommerce_db.order_items
WHERE order_id = 1;   -- then WHERE order_id = 2; then = 3; ...
```

If the user has 3 orders (as `arjun_k`, `user_id = 1`, does in the seed
data), that's 1 + 3 = 4 queries for what should be a single trip to the
database. **At scale — a listing page showing 100 orders — that's 1 + 100
= 101 separate round trips to the database for one page load.** Every
round trip pays network latency (even on a fast local network, often
0.5–2 ms; across an availability zone or region, far more) *in addition to*
each query's own execution time. 101 round trips at even a conservative
1 ms network overhead each is 101 ms of pure network latency before any
actual query execution time is counted — often the dominant cost of the
whole page load.

**The fix — batch it into one query.** Either a direct `JOIN`:

```sql
SELECT o.order_id, o.order_date, o.status,
       oi.product_id, oi.quantity, oi.unit_price
FROM ecommerce_db.orders o
JOIN ecommerce_db.order_items oi ON oi.order_id = o.order_id
WHERE o.user_id = 1
ORDER BY o.order_id;
```

...with the application grouping the flat, joined rows back into a
nested `order → [items]` structure in memory — one query total, zero
round trips saved for later.

Or, if you'd rather keep the two result shapes separate (one row per order,
one row per item) — common with ORMs that prefer this over join-flattening
— batch the second query with `IN` instead of looping:

```sql
-- Query 1: the orders (same as before)
SELECT order_id, order_date, status FROM ecommerce_db.orders WHERE user_id = 1;

-- Query 2: ALL items for ALL those orders, in one round trip
SELECT order_item_id, order_id, product_id, quantity, unit_price
FROM ecommerce_db.order_items
WHERE order_id IN (1, 3, 8);   -- the order_ids returned by query 1
```

**Quantified impact:** 100 orders on a page = **101 round trips** (naive
loop) → **1–2 round trips** (batched join, or list query + one `IN`-batched
query). This is routinely one of the single highest-leverage fixes
available in a typical CRUD web application — most ORMs (Django, Rails
ActiveRecord, SQLAlchemy, Hibernate, Prisma) have a built-in "eager
loading" feature (`select_related`/`prefetch_related`,
`includes`/`eager_load`, `joinedload`/`selectinload`, `.include()`,
respectively) that performs exactly this batching automatically — the fix
is usually turning that feature on for the relationship in question, not
hand-writing the batched SQL yourself.

> **Common mistake.** Fixing N+1 by adding an index to the child table's
> foreign key column. That does make *each* of the N queries faster, but
> does nothing about the fact that there are still N+1 *round trips* —
> each one still pays full network latency. Indexing helps the symptom;
> batching removes the cause.

> **Edge case.** N+1 isn't exclusive to ORMs — it happens just as easily
> in hand-written application code with a loop around a query call, in
> report-generation scripts, and in poorly designed API gateways that fan
> out one downstream call per item in a list they just fetched.

---

## 18.14 Case studies: slow query → fast query

Each case study follows the same shape: the slow query, why it's slow
(diagnosis), the fix, and **illustrative** before/after timings. Timings
are labeled illustrative because they depend on hardware, cache state, and
concurrent load — the point is the *shape* of the improvement, which is
representative of what you'll see on real hardware at these row counts.

### Case Study 1 — `SELECT *` report query fixed by column selection + covering index

**Scenario.** A merchandising report lists products in a category, most
recently added first, showing only name, price, and SKU on screen.

```sql
-- SLOW
SELECT *
FROM ecommerce_db.products
WHERE category_id = 2
ORDER BY created_at DESC;
```

**Diagnosis.** `SELECT *` pulls every column — including ones the report
never displays — forcing a heap fetch for each matching row even if an
index exists on `category_id`. There is also no index supporting the
`ORDER BY`, so PostgreSQL sorts the filtered rows at runtime (Ch. 17's
`Sort` node). At `ecommerce_db`'s actual seed-data scale (10 products
total) this is unmeasurable; the diagnosis and fix below are illustrated as
if this `products` table had grown to a realistic **500,000-row** catalog,
which is the scale at which this exact query shape shows up as a slow
report in production.

**Fix.**

```sql
CREATE INDEX idx_products_category_created
ON ecommerce_db.products (category_id, created_at DESC)
INCLUDE (product_name, price, sku);

-- FAST
SELECT product_name, price, sku, created_at
FROM ecommerce_db.products
WHERE category_id = 2
ORDER BY created_at DESC;
```

**Illustrative before/after** (500,000-row `products`, ~50,000 rows in
`category_id = 2`):

| | Before | After |
|---|---|---|
| Plan shape | Index scan on `category_id` (or seq scan, depending on selectivity) + heap fetch per row + `Sort` node | Index-only scan on `idx_products_category_created`, pre-sorted, no heap fetch |
| Rows processed by heap | ~50,000 heap fetches | 0 (index-only, assuming an up-to-date visibility map) |
| Approx. latency | ~180 ms | ~8 ms |

**Common mistakes.** Adding the covering index but leaving `SELECT *` in
the query — this defeats the index-only scan entirely, since `*` includes
columns (`is_discontinued`, `sku` if forgotten from the index) not present
in the index, forcing a heap visit anyway.

**When this fix is unnecessary.** A report run once a month against a
10,000-row table, viewed by one internal user, doesn't need a dedicated
covering index — the sequential scan cost is trivial and the index's
write-path cost (maintained on every product insert/update) isn't worth
paying for negligible read benefit.

### Case Study 2 — N+1 order-listing page fixed with a batched join

**Scenario.** As detailed in §18.13: an order-history page for a user
loads orders, then loops to fetch each order's items separately.

```sql
-- SLOW: 1 + N round trips
SELECT order_id, order_date, status FROM ecommerce_db.orders WHERE user_id = 1;
-- ... then, per order returned, in a loop:
SELECT product_id, quantity, unit_price FROM ecommerce_db.order_items WHERE order_id = :id;
```

**Diagnosis.** With `arjun_k` (user_id 1) having 3 orders in the seed
data, this is 4 round trips instead of 1. At realistic e-commerce scale —
a "my orders" page showing a user's most recent 100 orders — this becomes
101 round trips.

**Fix.**

```sql
-- FAST: 1 round trip
SELECT o.order_id, o.order_date, o.status,
       oi.product_id, oi.quantity, oi.unit_price, p.product_name
FROM ecommerce_db.orders o
JOIN ecommerce_db.order_items oi ON oi.order_id = o.order_id
JOIN ecommerce_db.products p ON p.product_id = oi.product_id
WHERE o.user_id = 1
ORDER BY o.order_id;
```

**Illustrative before/after** (100-order page, ~2.5 items/order average,
1 ms average network round-trip overhead assumed):

| | Before (N+1) | After (batched join) |
|---|---|---|
| Round trips | 101 | 1 |
| Network latency overhead alone | ~101 ms | ~1 ms |
| Total query execution time | ~15 ms (sum of all 101 tiny queries) | ~6 ms (one join, indexed on `order_id`) |
| **Approx. total page load contribution** | **~116 ms** | **~7 ms** |

**Common mistakes.** "Fixing" this by adding a cache in front of the N
per-order queries — this reduces repeat-load cost but does nothing for the
very first load of the page, and adds cache-invalidation complexity that
the batched join sidesteps entirely.

### Case Study 3 — `OFFSET` pagination at scale fixed with keyset pagination

**Scenario.** A sales report paginates through `analytics_db.sales_fact`
(5,000,000 rows), 50 rows per page, sorted chronologically. A support
engineer needs to inspect a page deep into the dataset.

```sql
-- SLOW at depth
SELECT sale_id, sale_date, customer_key, amount
FROM analytics_db.sales_fact
ORDER BY sale_date, sale_id
OFFSET 4000000 LIMIT 50;
```

**Diagnosis.** As detailed in §18.7, PostgreSQL must generate (and
discard) 4,000,000 rows in sorted order before it can return the 50 the
caller actually wants. Cost grows linearly with page depth.

**Fix.**

```sql
CREATE INDEX idx_sales_fact_date_id ON analytics_db.sales_fact (sale_date, sale_id);

-- FAST, regardless of depth
SELECT sale_id, sale_date, customer_key, amount
FROM analytics_db.sales_fact
WHERE (sale_date, sale_id) > ('2023-06-15', 3182045)  -- last row seen on previous page
ORDER BY sale_date, sale_id
LIMIT 50;
```

**Illustrative before/after** (table shown in §18.7's table; repeated here
for this specific "deep page" scenario):

| | `OFFSET 4000000` | Keyset from equivalent depth |
|---|---|---|
| Rows generated internally | ~4,000,050 | 50 |
| Approx. latency | ~1,200 ms | ~4 ms |

**Common mistakes.** Forgetting the tiebreaker column (`sale_id`) in the
seek predicate and sort — pagination on `sale_date` alone, with many rows
sharing the same date, can skip or repeat rows across page boundaries.

**When `OFFSET` is fine here instead.** If the report UI never lets users
page past, say, page 10 (500 rows deep) — cap the paginator rather than
rewriting to keyset; the linear-growth cost is negligible that shallow.

### Case Study 4 — correlated subquery in `WHERE` fixed with a window function

**Scenario.** A finance analyst wants every sale that's "above average"
for that specific customer — i.e., `sales_fact` rows where `amount`
exceeds that customer's own historical average.

```sql
-- SLOW
SELECT sf.sale_id, sf.customer_key, sf.amount
FROM analytics_db.sales_fact sf
WHERE sf.amount > (
    SELECT AVG(sf2.amount)
    FROM analytics_db.sales_fact sf2
    WHERE sf2.customer_key = sf.customer_key
);
```

**Diagnosis.** This is exactly the shape flagged in §18.8 as *not*
eligible for the planner's automatic semi-join rewrite — it's a
per-row-correlated aggregate, not an existence test. Conceptually, the
average is recomputed by re-scanning the customer's rows once for each of
the 5,000,000 outer rows, rather than once per each of the 5,000 distinct
customers.

**Fix (window function):**

```sql
SELECT sale_id, customer_key, amount
FROM (
    SELECT sale_id, customer_key, amount,
           AVG(amount) OVER (PARTITION BY customer_key) AS customer_avg
    FROM analytics_db.sales_fact
) windowed
WHERE amount > customer_avg;
```

**Fix (pre-aggregated join) — equivalent result, sometimes preferred for
readability or when the aggregate is reused elsewhere in the same query:**

```sql
WITH customer_avg AS (
    SELECT customer_key, AVG(amount) AS avg_amount
    FROM analytics_db.sales_fact
    GROUP BY customer_key
)
SELECT sf.sale_id, sf.customer_key, sf.amount
FROM analytics_db.sales_fact sf
JOIN customer_avg ca ON ca.customer_key = sf.customer_key
WHERE sf.amount > ca.avg_amount;
```

**Illustrative before/after** (5,000,000-row `sales_fact`, 5,000 distinct
customers):

| | Correlated subquery | Window function / pre-aggregated join |
|---|---|---|
| Aggregate computations | Up to 5,000,000 (one per outer row, absent caching) | 5,000 (one per customer) |
| Approx. latency | ~42,000 ms (42 s) | ~1,800 ms |

**Common mistakes.** Rewriting *every* correlated subquery reflexively,
including `EXISTS`/`IN` existence checks that the planner already
semi-joins efficiently (§18.8's warning) — always confirm with `EXPLAIN`
which shape you're actually dealing with before assuming a rewrite is
needed.

---

## 18.15 Real-world use cases

- **E-commerce order-history and admin dashboards** — the N+1 fix
  (§18.13) and covering-index-plus-column-trim fix (Case Study 1) are the
  two most common wins in typical CRUD backends.
- **Analytics/BI dashboards with drill-down pagination** — keyset
  pagination (§18.7, Case Study 3) is standard in any product letting
  users page deep into a large event or transaction log.
- **Nightly batch/ETL jobs after bulk loads** — statistics hygiene
  (§18.10) directly determines whether the very next report run after a
  load picks a good plan or a catastrophically bad one.
- **High-throughput API backends** — connection pooling (§18.12) is
  standard infrastructure in virtually every production PostgreSQL
  deployment behind a web tier; running without a pooler is the exception,
  not the norm, once request volume is non-trivial.
- **Time-series and log-retention systems** — partition pruning (§18.11)
  combined with partition-drop-based retention (Ch. 26) is the standard
  architecture for "keep 2 years of data, query mostly the last 30 days."
- **Reporting layers built on top of complex multi-CTE queries** — the
  `MATERIALIZED`/`NOT MATERIALIZED` decision (§18.9) shows up whenever an
  expensive intermediate aggregate is reused by multiple branches of a
  larger analytical query.

---

## 18.16 Comparison: fix strategies at a glance

| Problem | Fix option A | Fix option B | When to prefer A vs. B |
|---|---|---|---|
| Slow filtered scan | Add a targeted B-tree index | Rewrite query to filter differently | Prefer the index unless the query shape itself is the problem (e.g., a function wrapped around the column) |
| Correlated aggregate subquery | Window function | Pre-aggregated CTE + join | Window function when you need the aggregate alongside detail rows in one pass; CTE+join when the aggregate is reused across multiple parts of the query |
| Deep pagination | Keyset pagination | Cap max page depth in the UI | Keyset when deep access is a real requirement; capping when it isn't |
| N+1 | Single `JOIN` | List query + batched `IN` query | `JOIN` when you want one flat result set; batched `IN` when the application/ORM prefers separate parent/child result shapes |
| Report over a huge time-ranged table | Partitioning + pruning | A well-chosen composite index alone | Partitioning once the table is large enough that whole-partition skipping meaningfully beats even a good index; index alone for moderate sizes |
| Repeated slow queries under load | Query/index optimization | Connection pooling | These aren't alternatives — pooling fixes round-trip/connection overhead, indexing fixes per-query execution cost; most production systems need both |

---

## 18.17 Common mistakes and edge cases (chapter-wide)

- **Optimizing without measuring first.** Covered in the warning at the
  top of this chapter — worth repeating as the single most common mistake
  in this entire domain.
- **Adding indexes that duplicate an existing composite index's leading
  columns** (§18.3) — pure write-path cost, zero benefit.
- **Confusing "the query got faster" with "the system got faster."** An
  index that speeds up one report query can slow down the write-heavy
  workload that maintains it. Always evaluate a fix against the
  *workload*, not just the one query you're staring at.
- **Rewriting `EXISTS`/`IN` subqueries the planner already optimizes**
  (§18.8) — wasted engineering effort, sometimes a regression if the
  rewrite introduces `DISTINCT`-requiring row duplication.
- **Deep `OFFSET` pagination in a "just ship it" admin tool that later
  becomes a public, high-traffic feature** — revisit pagination strategy
  when usage patterns change, not just at initial launch.
- **Ignoring statistics after a schema migration that includes a bulk
  backfill.** New column, defaulted and backfilled for millions of
  existing rows — `ANALYZE` afterward, always.
- **Treating partitioning as a default "big table" solution** rather than
  a targeted fix for queries that filter on the partition key — a large
  table whose queries mostly filter on a *non-partition-key* column gets
  little benefit and real added complexity (Ch. 26).
- **Sizing a connection pool to "as large as possible"** rather than to
  what the database backend can actually serve concurrently — this is the
  connection-storm failure mode from §18.12, self-inflicted.

---

## 18.18 Practice questions

For each scenario below, diagnose the likely cause of the slowness and
propose a specific fix using the techniques from this chapter. No answers
are provided — work through the diagnosis the way you would with a real
production incident, using `EXPLAIN (ANALYZE, BUFFERS)` (Ch. 17) as your
primary evidence source.

1. A product search page runs `SELECT * FROM ecommerce_db.products WHERE
   product_name ILIKE '%phone%'` and is slow on a catalog that has grown
   to 2 million rows. What's the likely `EXPLAIN` finding, and is a plain
   B-tree index the right fix here?

2. An admin report on `analytics_db` runs fine on page 1 but takes almost
   4 seconds by page 200 (50 rows per page, `OFFSET`-based). What do you
   expect to see in `EXPLAIN ANALYZE` for the page-200 query, and what's
   your fix?

3. A dashboard endpoint fetches a list of 50 customers, then, in
   application code, loops through them making a separate query per
   customer to fetch their most recent order. How many total queries does
   this endpoint issue, and how would you collapse it?

4. A query joins `orders`, `order_items`, `products`, `payments`, and
   `reviews` to display an order confirmation page that only shows order
   ID, date, status, and line items. What would you check first, and what
   would you likely remove?

5. A report was fast last week and is suddenly slow today, with no code
   changes deployed. The table it queries had 3 million rows bulk-loaded
   yesterday via `COPY`. What's your first diagnostic step?

6. A query filters `WHERE sale_date >= '2024-01-01'` against
   `analytics_db.sales_fact`. `EXPLAIN` shows all three partitions
   (`sales_fact_2022`, `sales_fact_2023`, `sales_fact_2024`) being
   scanned. Why might partition pruning have failed here, and what would
   you check?

7. A query uses `WHERE amount > (SELECT AVG(amount) FROM sales_fact)`
   (an *uncorrelated* subquery — no reference to the outer row). Does
   this need the same rewrite treatment as the correlated `AVG()` example
   in §18.8? Why or why not?

8. An application opens a new database connection for every incoming HTTP
   request and closes it when the response is sent. Under low traffic
   this is fine; under a traffic spike, response times degrade sharply
   and the database logs show connection errors. Diagnose, and propose an
   architectural fix.

9. A query sorts a 4-million-row filtered result set with `ORDER BY
   sale_date DESC` and `EXPLAIN ANALYZE` shows `Sort Method: external
   merge Disk`. What does that specific detail tell you, and what are two
   different ways you could address it?

10. A multi-CTE analytical query references an expensive aggregation CTE
    three separate times later in the query (once per branch of a
    `UNION ALL`). On PostgreSQL 12+, would you expect this CTE to inline
    or materialize by default, and would you override that default? In
    which direction?

11. A correlated `WHERE EXISTS (...)` subquery checking whether a customer
    has any successful payment is flagged by a teammate as "obviously
    slow because it's correlated" and rewritten into a `JOIN` with
    `DISTINCT`. What would you check before agreeing this rewrite is a
    net improvement?

12. A report query selects 40 columns from a wide table via `SELECT *`,
    but the underlying index the planner chose only includes 4 of them.
    What specific optimization does this prevent, and what's the fix?

---

## 18.19 Chapter-ending challenge

Below is a deliberately bad report query against `analytics_db`. It has
**at least four separate performance problems** covered in this chapter.
Rewrite it end-to-end, applying **at least four distinct techniques** from
this chapter. For each change you make, name the specific technique (by
section number or name) and explain, in one sentence, what problem it
fixes.

```sql
SELECT *
FROM analytics_db.sales_fact sf, analytics_db.dim_customer c,
     analytics_db.dim_product p, analytics_db.dim_store s
WHERE sf.customer_key = c.customer_key
  AND sf.product_key = p.product_key
  AND sf.store_key = s.store_key
  AND sf.amount > (
      SELECT AVG(sf2.amount)
      FROM analytics_db.sales_fact sf2
      WHERE sf2.product_key = sf.product_key
  )
ORDER BY sf.sale_date DESC
OFFSET 200000 LIMIT 100;
```

Things worth noticing as you diagnose it: what every joined table's
columns actually contribute to the final output; whether every joined
table is even needed for what gets displayed; what the correlated
subquery is really computing and how often; how deep the pagination goes
and whether a seek-based rewrite is possible here; and whether any of the
filter/sort columns you end up needing already have supporting indexes in
the schema as defined in `databases/analytics_db.sql`, or whether you'd
need to add one.

---

## Key Takeaways

- Query optimization is fundamentally about doing less work, on fewer
  rows, as early as possible — every technique in this chapter is a
  variation on that idea.
- **Always measure before and after** with `EXPLAIN (ANALYZE, BUFFERS)`
  (Ch. 17); never apply a fix from a checklist without confirming it
  addresses your actual bottleneck.
- Index selection is a workflow, not guesswork: identify candidate
  columns from `WHERE`/`JOIN`/`ORDER BY`, check selectivity, order
  composite columns as equality → range → sort, and audit for redundant
  or unused indexes (Ch. 16 for internals).
- `SELECT *` costs more than it looks like: I/O, network bytes,
  index-only-scan eligibility, and schema-change fragility all suffer.
- Deep `OFFSET` pagination degrades linearly with depth; keyset
  pagination stays roughly constant — pick based on how deep users
  actually page (Ch. 4 for the syntax, this chapter for the "why").
- Correlated subqueries computing per-row aggregates are a real
  bottleneck and should be rewritten as window functions or pre-aggregated
  joins — but correlated `EXISTS`/`IN` existence checks are often already
  optimized by the planner into semi-joins; verify before rewriting.
- Modern PostgreSQL (12+) inlines single-reference CTEs by default; use
  `MATERIALIZED` to force a barrier (multi-reference expensive
  aggregates) and `NOT MATERIALIZED` to force inlining when you want
  cross-boundary predicate pushdown despite multiple references.
- Stale statistics cause bad cardinality estimates and bad plans; run
  `ANALYZE` manually after bulk loads and before performance-critical
  runs, don't rely solely on autovacuum's timing.
- Partition pruning skips entire partitions when a query filters on the
  partition key — a genuine performance lever at large scale, not a
  general-purpose fix (Ch. 26 for full treatment).
- Connection setup (TCP handshake, auth, backend process spawn) is
  expensive; connection pooling amortizes that cost, but pools must be
  sized to what the database can serve, not to theoretical application
  concurrency.
- The N+1 query problem — one query becoming N+1 round trips through an
  application-code loop — is one of the highest-leverage fixes available
  in typical application backends; batch with a `JOIN` or a `WHERE id IN
  (...)` query instead.
- Every fix in this chapter has a "when this is unnecessary" edge —
  premature optimization on a small table, a shallow paginator, or a
  once-a-month report wastes engineering time on invisible gains.

---

## What's Next

Chapter 19 moves from *tuning* SQL to *encapsulating* it: **Stored
Procedures**. You'll write PL/pgSQL procedures with control flow, error
handling, and transaction management, and see the equivalent T-SQL
(SQL Server), PL/SQL (Oracle), and MySQL stored procedure syntax —
building the foundation for the procedural SQL techniques (functions,
cursors, triggers) covered through Chapter 22.
