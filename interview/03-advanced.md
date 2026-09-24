# Advanced SQL Interview Questions

This is the Advanced tier of the SQL Mastery interview question bank. It assumes
comfort with joins, subqueries, aggregation, and window functions (covered in the
Beginner and Intermediate tiers) and moves into the machinery that separates
someone who can *write* SQL from someone who can operate a production database:
views, indexing, the query planner, stored procedures and functions, triggers,
cursors, dynamic SQL, temporary tables, richer data types, and partitioning.

All examples run against the three course databases:

- **company_db** — `departments`, `employees`, `managers`, `salaries`, `attendance`, `projects`, `employee_projects`
- **ecommerce_db** — `users`, `categories`, `products`, `inventory`, `orders`, `order_items`, `payments`, `reviews`
- **banking_db** — `customers`, `accounts`, `transactions`, `loans`, `audit_log`

Dialect is **[PostgreSQL]** unless a code block is explicitly labeled otherwise.
Where another RDBMS (MySQL, SQL Server, Oracle) behaves meaningfully
differently, a dialect note is called out.

> **How to use this bank**: Each question is answered in full — don't just read
> the code, read the "Why it works" and "Common mistakes" sections. At this
> tier, interviewers usually care more about your reasoning under a slow-query
> or production-incident scenario than about syntax recall.

---

## 1. Views & Materialized Views

A view is a stored query — a saved `SELECT` that behaves like a virtual table.
A materialized view goes further: it physically stores the result set, trading
freshness for read speed. Interviewers probe this section to see whether you
understand *when* to reach for each, and what you give up in return
(updatability, staleness, storage, refresh cost).

### Q1. What is a view, and what problem does it solve?

**Answer**: A view is a named, stored `SELECT` statement that PostgreSQL
re-executes (fully or partially, depending on how it's used) every time it is
queried. It doesn't store data itself — it stores a query definition in the
system catalog (`pg_views` / `information_schema.views`).

```sql
CREATE VIEW ecommerce_db.v_order_summary AS
SELECT
    o.order_id,
    o.user_id,
    u.username,
    o.order_date,
    o.status,
    SUM(oi.quantity * oi.unit_price) AS order_total
FROM orders o
JOIN users u        ON u.user_id = o.user_id
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY o.order_id, o.user_id, u.username, o.order_date, o.status;
```

Querying `SELECT * FROM v_order_summary WHERE status = 'DELIVERED'` behaves
exactly as if you'd written the join + filter inline.

**Why it works**: A view is essentially a macro at the SQL level. The planner
substitutes the view's defining query wherever the view is referenced, then
optimizes the *combined* query (this is called "view expansion" or "inlining").
That's why a filter applied outside the view can often be pushed down into it.

**Alternative approaches**: A materialized view (`CREATE MATERIALIZED VIEW`)
stores the result physically — much faster to read, but stale until refreshed.
A plain application-layer query (no view) avoids catalog objects entirely but
loses the encapsulation and reuse benefit.

**Performance considerations**: A view adds zero storage and zero staleness,
but every query against it re-does the underlying work — including joins and
aggregation — every single time. Views are a *readability/security/reuse*
tool, not a *performance* tool.

**Common mistakes**:
> - Assuming a view caches results (it doesn't — that's a materialized view).
> - Stacking views on views many levels deep, producing a query plan that's
>   miserable to read in `EXPLAIN` and hard for the planner to optimize well.
> - Forgetting that permissions can be granted on a view without granting the
>   underlying tables — a security use case interviewers like to probe.

---

### Q2. How would you use a view to restrict column/row access without granting table permissions?

**Answer**: Create a view that exposes only permitted columns/rows, then
`GRANT` on the view instead of the base table.

```sql
CREATE VIEW company_db.v_employee_directory AS
SELECT employee_id, first_name, last_name, job_title, department_id
FROM employees
WHERE status = 'ACTIVE';

REVOKE ALL ON employees FROM hr_readonly;
GRANT SELECT ON v_employee_directory TO hr_readonly;
```

The `hr_readonly` role can now see active employees' names and titles but has
no access to `salaries`, `email`, `manager_id`, or terminated employees, even
though it never has a `GRANT` on the `employees` table itself.

**Why it works**: PostgreSQL evaluates view privileges independently of the
underlying tables *as long as the view owner* has the necessary rights on the
base tables. The view runs with the privileges of its owner (like a security
definer), so a caller only needs `SELECT` on the view.

**Alternative approaches**: Row-Level Security (`CREATE POLICY`) achieves
similar row filtering without a separate object and applies even to direct
table access — more robust but more complex to reason about. Column-level
`GRANT` (`GRANT SELECT (col1, col2) ON employees TO role`) restricts columns
without a view but doesn't let you filter rows.

**Performance considerations**: Negligible overhead versus direct table
access, since the view is inlined into the plan. RLS policies, by contrast,
add a filter predicate to every query and can defeat certain index-only scans.

**Common mistakes**:
> - Forgetting `WHERE status = 'ACTIVE'` in the view and only relying on
>   column restriction — row-level leakage is a common oversight.
> - Not realizing the view owner needs full underlying access even when
>   callers don't.

---

### Q3. What is a materialized view, and when would you choose it over a regular view?

**Answer**: A materialized view stores the query's result set on disk like a
table, and only refreshes when told to.

```sql
CREATE MATERIALIZED VIEW ecommerce_db.mv_product_sales_summary AS
SELECT
    p.product_id,
    p.product_name,
    COUNT(DISTINCT oi.order_id) AS orders_count,
    SUM(oi.quantity)            AS units_sold,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM products p
JOIN order_items oi ON oi.product_id = p.product_id
GROUP BY p.product_id, p.product_name
WITH DATA;

CREATE UNIQUE INDEX ON mv_product_sales_summary (product_id);
```

You'd choose this over a plain view when the underlying query is expensive
(multi-table joins with aggregation over large tables) and is read far more
often than the underlying data changes — e.g., a daily sales dashboard.

**Why it works**: The `SELECT` runs once at creation/refresh time and the
result is written to a heap just like a table, so subsequent reads are plain
table scans/index scans with no join or aggregation cost.

**Alternative approaches**: A regular view is always fresh but always pays
the full query cost. A summary table maintained by triggers gives real-time
freshness with write-time cost instead of read-time cost — more code to
maintain, but no staleness window at all.

**Performance considerations**: `REFRESH MATERIALIZED VIEW` rewrites the
whole result by default and takes an `ACCESS EXCLUSIVE` lock, blocking reads
during refresh unless you use `CONCURRENTLY` (which requires a unique index,
as created above, and is slower because it diffs old vs. new rows).

**Common mistakes**:
> - Forgetting `WITH DATA` (without it, the MV is created empty and unusable
>   until first refresh).
> - Refreshing without `CONCURRENTLY` on a materialized view that's read
>   continuously, causing reader blocking.
> - Treating an MV as always current — dashboards built on it need a visible
>   "as of" timestamp.

---

### Q4. Write a query to refresh a materialized view without blocking concurrent reads, and explain the trade-off.

**Answer**:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY ecommerce_db.mv_product_sales_summary;
```

**Why it works**: `CONCURRENTLY` builds the new result set into a temporary
object, then diffs it against the existing materialized view row-by-row using
the required unique index, applying only the changed rows via `UPDATE`/`INSERT`/
`DELETE` inside a transaction — so existing readers keep seeing the old
(consistent) data until the swap commits, and only a brief lock is needed at
the end rather than a full-table exclusive lock for the duration.

**Alternative approaches**: Plain `REFRESH MATERIALIZED VIEW` (no
`CONCURRENTLY`) is simpler and faster in raw wall-clock time (a straight
rebuild rather than a diff) but takes `ACCESS EXCLUSIVE` and blocks all reads
for the duration — acceptable for an MV refreshed in a maintenance window,
unacceptable for one queried by a live dashboard.

**Performance considerations**: `CONCURRENTLY` requires computing a full diff,
which costs more CPU/IO than a straight rebuild, and it requires at least one
unique index on the MV or PostgreSQL will refuse it. On very large MVs the
diff step can itself run long.

**Common mistakes**:
> - Trying `REFRESH ... CONCURRENTLY` without a unique index — PostgreSQL
>   raises `ERROR: cannot refresh materialized view "x" concurrently — no
>   unique index on materialized view`.
> - Assuming concurrent refresh is "free" — it still costs I/O and can bloat
>   the MV's underlying table if run very frequently without vacuuming.

---

### Q5. Can you `UPDATE` through a view? What makes a view updatable?

**Answer**: Yes, but only if the view is "simply updatable": it must be based
on exactly one base relation (no joins, no `UNION`, no `DISTINCT`, no
aggregate/window functions, no `GROUP BY`), and every column of the view must
map directly to a column of the underlying table (not an expression).

```sql
CREATE VIEW company_db.v_active_employees AS
SELECT employee_id, first_name, last_name, email, department_id, status
FROM employees
WHERE status = 'ACTIVE';

UPDATE v_active_employees
SET department_id = 5
WHERE employee_id = 6;
```

This works and updates the underlying `employees` row directly, because the
view is a simple filtered projection of one table.

**Why it works**: PostgreSQL can unambiguously translate `UPDATE view SET col
= val WHERE ...` into `UPDATE base_table SET col = val WHERE <view's filter>
AND <caller's filter>` only when there's a 1:1 column and row mapping. Once
you add a join or aggregate, that mapping becomes ambiguous (which underlying
row does a `SUM()` column belong to?).

**Alternative approaches**: For views that aren't automatically updatable
(joins, aggregates), use `INSTEAD OF` triggers to define custom
insert/update/delete logic (see the Triggers section), or expose a stored
procedure as the write path instead of the view.

**Performance considerations**: Automatically-updatable views add no overhead
— they compile down to a plain `UPDATE`/`DELETE` on the base table. `INSTEAD
OF` triggers add per-row trigger invocation overhead, which matters for
bulk writes.

**Common mistakes**:
> - Trying to `INSERT` into a view built with `WHERE status = 'ACTIVE'`
>   without `WITH CHECK OPTION`, silently inserting a row that then
>   disappears from the view because it doesn't satisfy the filter.
> - Assuming any view spanning one table is updatable even if it uses
>   `DISTINCT` or a window function — it isn't.

---

### Q6. What does `WITH CHECK OPTION` do on a view, and why does it matter?

**Answer**: It prevents `INSERT`/`UPDATE` through the view from creating or
leaving a row that wouldn't satisfy the view's own `WHERE` clause.

```sql
CREATE VIEW company_db.v_active_employees AS
SELECT employee_id, first_name, last_name, email, department_id, status
FROM employees
WHERE status = 'ACTIVE'
WITH CHECK OPTION;

-- This now fails instead of silently succeeding-and-vanishing:
UPDATE v_active_employees
SET status = 'TERMINATED'
WHERE employee_id = 6;
-- ERROR: new row violates check option for view "v_active_employees"
```

**Why it works**: Without `WITH CHECK OPTION`, the `UPDATE` above would
succeed (Karan Verma's `status` becomes `'TERMINATED'`), and the row would
simply vanish from subsequent queries against `v_active_employees` — visible
data corruption from the caller's point of view since they can no longer see
what they just wrote. `WITH CHECK OPTION` forces PostgreSQL to re-check the
view's predicate against the resulting row and roll back if it fails.

**Alternative approaches**: `LOCAL` vs. `CASCADED` check options matter for
views stacked on other views — `CASCADED` (the default) checks predicates of
*all* views in the stack, `LOCAL` only checks the immediate view's own
predicate.

**Performance considerations**: Negligible — one extra predicate evaluation
per modified row.

**Common mistakes**:
> - Not using `WITH CHECK OPTION` on any view exposed as a write path to
>   external callers, leading to "vanishing row" bug reports.
> - Confusing `WITH CHECK OPTION` with a `CHECK` constraint — they're
>   unrelated mechanisms.

---

### Q7. A dashboard query re-runs this view 200 times a minute and it's slow. How do you decide between optimizing the view's query, adding indexes, or converting it to a materialized view?

**Answer**: Work through it in order of increasing intrusiveness:

1. **`EXPLAIN (ANALYZE, BUFFERS)`** the view's expanded query to see where
   time actually goes (sequential scans, sort spills, nested-loop blowups).
2. **Index first** if the plan shows sequential scans on selective filters —
   indexes fix the underlying query for *every* consumer, not just this
   dashboard, and keep the data live.
3. **Rewrite the query** if the join order or aggregation strategy is
   suboptimal (e.g., aggregating before joining instead of after).
4. **Only then** consider a materialized view — this is justified when (a)
   the query is aggregate-heavy across large tables even after indexing and
   rewriting, and (b) the dashboard can tolerate the staleness window (e.g.,
   refreshed every 5 minutes via `pg_cron`), because 200 reads/minute against
   an expensive live aggregation is exactly the workload MVs are built for.

**Why it works**: Indexing and rewriting are "free" in that they don't
introduce a staleness contract; they should always be exhausted first because
a materialized view is a commitment (you now own a refresh schedule and a
"how stale can this be" conversation with the business).

**Alternative approaches**: If true real-time freshness is required *and*
performance is required, the remaining option is a maintained summary table
updated incrementally by triggers on write — more implementation work, but no
staleness and no refresh storm.

**Performance considerations**: 200 QPS against a raw aggregate join can
mean thousands of buffer reads per second; converting to an MV backed by a
`UNIQUE` index for `CONCURRENTLY` refresh turns each dashboard read into a
simple indexed lookup, typically sub-millisecond.

**Common mistakes**:
> - Jumping straight to a materialized view without checking `EXPLAIN` first
>   — you might just be missing one index.
> - Refreshing an MV on every write to its source tables ("just to be safe"),
>   which recreates the same performance problem you were trying to solve.

---

## 2. Indexes

Indexes are the single highest-leverage performance tool in SQL, and the one
most commonly misunderstood. This section drills into B-tree internals,
selectivity, composite index column order, covering indexes, and the index
types beyond B-tree (GIN, GiST, BRIN, hash, partial).

### Q8. Explain how a B-tree index actually works, structurally.

**Answer**: A B-tree (specifically, in PostgreSQL, a B+tree variant) is a
balanced, sorted tree structure. Leaf nodes hold indexed key values in sorted
order plus a pointer (a "tuple ID" / TID: page number + offset) to the actual
row in the heap (or, in an index-only scan, enough visibility info to avoid
the heap entirely). Internal nodes hold routing keys that let a lookup
descend from the root to the correct leaf in O(log n) page reads.

For `CREATE INDEX idx_employees_department ON employees(department_id);`,
looking up `department_id = 2` means: read the root page, compare `2` against
the routing keys, follow the correct child pointer, repeat until a leaf page
is reached, then scan the leaf (and possibly sibling leaves, since leaves are
linked) for all matching entries.

**Why it works**: Because the tree is balanced and keys are sorted, both
equality and range lookups (`department_id BETWEEN 1 AND 3`) are efficient —
range scans just walk sideways along the linked leaf pages after descending
once.

**Alternative approaches**: A hash index gives O(1) equality lookups but no
range support and (historically) no WAL-logging guarantees before PG10 — it's
rarely the right default. GiST/GIN suit non-scalar data (see Q16).

**Performance considerations**: Tree depth grows logarithmically, so even a
100-million row table typically has a B-tree depth of only 3-4, meaning 3-4
page reads (often cached) per lookup — this is why indexed lookups feel
"constant time" in practice even as tables grow.

**Common mistakes**:
> - Believing an index makes *every* query on that column fast — it helps
>   selective lookups, not queries that must return most of the table (see
>   Q10, selectivity).
> - Not knowing that B-trees support `<`, `<=`, `=`, `>=`, `>`, `BETWEEN`,
>   and `IN`, but not arbitrary functions of the column unless a matching
>   expression index exists.

---

### Q9. What is index selectivity, and why does it determine whether the planner uses an index?

**Answer**: Selectivity is the fraction of rows a predicate is expected to
match. A highly selective predicate matches few rows (`employee_id = 5` on
`employees` — 1 row out of 16, selectivity ~6%); a low-selectivity predicate
matches many (`status = 'ACTIVE'` — 14 out of 16 rows, ~87%).

```sql
EXPLAIN SELECT * FROM company_db.employees WHERE status = 'ACTIVE';
-- likely a Seq Scan even with an index on status, because ~87% of rows qualify

EXPLAIN SELECT * FROM company_db.employees WHERE employee_id = 5;
-- Index Scan (or even better, uses the PK's unique B-tree directly)
```

**Why it works**: An index scan costs roughly `(matching rows × random I/O)`
plus tree traversal, while a sequential scan costs `(all rows × sequential
I/O)`. Sequential I/O is far cheaper per page than random I/O. When a
predicate matches a large share of the table, reading the whole table in
sequential order and filtering in memory beats jumping all over the heap via
random-access index lookups — so the *cost-based* planner rationally
chooses a seq scan even with a usable index sitting right there.

**Alternative approaches**: A partial index restricted to the rare status
value can restore selectivity for narrow use cases (e.g., `WHERE status =
'TERMINATED'`), since the partial index only needs to cover the sparse
subset.

**Performance considerations**: Rule of thumb (not gospel): once a predicate
matches roughly more than 5-15% of a table, sequential scans tend to win;
below that, indexed access tends to win. The actual crossover depends on row
width, `random_page_cost`, `seq_page_cost`, and caching.

**Common mistakes**:
> - Filing a bug report that "the index isn't being used" without checking
>   selectivity — the planner is very likely making the right call.
> - Forcing index usage with `SET enable_seqscan = off` in production instead
>   of understanding why the planner disagreed with you.

---

### Q10. Design an index for this query and explain your column ordering: `SELECT * FROM ecommerce_db.orders WHERE user_id = 1 AND status = 'DELIVERED' ORDER BY order_date DESC;`

**Answer**:

```sql
CREATE INDEX idx_orders_user_status_date
    ON ecommerce_db.orders (user_id, status, order_date DESC);
```

**Why it works**: Composite B-tree indexes are usable left-to-right. Put the
equality columns first (`user_id`, `status`) so the tree can descend directly
to the matching range; put the `ORDER BY` column last so that, once the
engine has narrowed to the `(user_id=1, status='DELIVERED')` slice, the
matching leaf entries are *already* in `order_date DESC` order — the sort in
the query is satisfied for free by index order, avoiding a separate sort
node. Declaring `order_date DESC` in the index definition matches the query's
`DESC` requirement exactly (PostgreSQL can also scan a plain ascending index
backwards, but matching direction is the clean, unambiguous choice for a
mixed multi-column case with equality + range/order columns).

**Alternative approaches**: `(user_id, order_date DESC)` alone, with `status`
left for a heap-level filter, would also use the index for the first column
and the sort, but would still need to fetch and filter rows that don't match
`status`. `(status, user_id, order_date DESC)` would work equally well here
because both `status` and `user_id` are equality predicates — order between
equality columns matters less than equality-columns-before-range/sort-column,
but leading with the more selective column (likely `user_id`, since `status`
has only 5 distinct values) reduces the leaf-scan work for other queries that
might use a prefix of this index.

**Performance considerations**: This index turns a full scan + filter + sort
into a single `Index Scan` with `Index Cond: (user_id = 1 AND status =
'DELIVERED')` and no `Sort` node in `EXPLAIN` at all.

**Common mistakes**:
> - Putting the sort column *before* the equality columns (`order_date,
>   user_id, status`) — this defeats the equality lookup because the tree
>   would have to scan by date across all users first.
> - Creating three separate single-column indexes instead of one composite —
>   PostgreSQL *can* combine them via a `BitmapAnd`, but a purpose-built
>   composite index is almost always cheaper and skips the sort entirely.

---

### Q11. What is a covering index / index-only scan, and how do you build one?

**Answer**: An index-only scan answers a query entirely from the index
without touching the heap at all, because every column the query needs is
present in the index. You achieve this either by including the needed
columns in the index key itself, or via the `INCLUDE` clause (PostgreSQL 11+)
for columns you want stored in the index but not used for searching/sorting.

```sql
CREATE INDEX idx_orders_covering
    ON ecommerce_db.orders (user_id, status)
    INCLUDE (order_id, order_date);

EXPLAIN SELECT order_id, order_date
FROM orders
WHERE user_id = 1 AND status = 'DELIVERED';
```

```text
Index Only Scan using idx_orders_covering on orders
  Index Cond: (user_id = 1 AND status = 'DELIVERED')
  Heap Fetches: 0
```

**Why it works**: `Heap Fetches: 0` means PostgreSQL never had to visit the
table's heap pages at all — every column the `SELECT` list needs
(`order_id`, `order_date`) plus the filter columns (`user_id`, `status`) live
directly in the index leaf pages, and the visibility map confirms all
relevant pages are all-visible so no heap check is even needed for MVCC
visibility.

**Alternative approaches**: Including columns in the index key (rather than
`INCLUDE`) also enables index-only scans but bloats the tree with data that's
never used for searching/sorting, slowing down inserts/updates and wasting
space in internal nodes; `INCLUDE` avoids that by keeping extra columns only
at the leaf level.

**Performance considerations**: Index-only scans still require the
visibility map to be up to date (run by `VACUUM`); on a heavily-written table
with a stale visibility map, PostgreSQL falls back to heap fetches even
though the query plan says "Index Only Scan" — watch `Heap Fetches` in
`EXPLAIN ANALYZE`, not just the node type.

**Common mistakes**:
> - Adding every conceivably-useful column to `INCLUDE`, bloating the index
>   and slowing writes for marginal benefit.
> - Expecting "Index Only Scan" in the plan to guarantee zero heap access —
>   check `Heap Fetches` to confirm.

---

### Q12. Here is `EXPLAIN` output for a query joining `employees` to `departments`. Diagnose the problem.

```text
Nested Loop  (cost=0.00..1284.55 rows=16 width=120) (actual time=0.05..842.11 rows=16 loops=1)
  ->  Seq Scan on employees e  (cost=0.00..1.16 rows=16 width=80) (actual time=0.01..0.02 rows=16 loops=1)
  ->  Seq Scan on departments d  (cost=0.00..1.06 rows=1 width=40) (actual time=52.50..52.51 rows=1 loops=16)
        Filter: (department_id = e.department_id)
        Rows Removed by Filter: 4
```

**Answer**: This plan is inefficient because the inner side of the nested
loop (`departments`) is being sequentially scanned *once per outer row* — 16
loops, each rescanning all 5 departments and filtering — instead of using an
index to jump straight to the matching row. On a 5-row table this is
harmless (as the low absolute costs here confirm), but the *pattern* — Seq
Scan as the inner side of a Nested Loop, re-executed per outer row — is the
single most common cause of runaway query time once the inner table grows
from 5 rows to 5 million.

**Why it works (the fix)**: Ensure `departments.department_id` (its primary
key) has an index — it does by default as the `PRIMARY KEY`, so this
specific toy example is actually fine; the diagnostic skill being tested is
recognizing that `loops=16` combined with `Seq Scan ... Filter:
(department_id = e.department_id)` on the inner side means "for every outer
row, we rescanned the whole inner table," and that this only stays cheap
because the inner table is tiny (`rows=1... width=40`, 5 total rows).

**Alternative approaches**: If `departments` had no PK/index and were large,
forcing a `Hash Join` (`SET enable_nestloop = off;` for diagnosis only,
never in production) would confirm the nested loop is the bottleneck; the
real fix is adding an index on the join column or letting the planner choose
a hash join once table statistics show the inner table is no longer trivial.

**Performance considerations**: `loops=16` multiplies the inner cost by 16 —
on a 5-row inner table this is 80 comparisons, trivial; on a 5-million-row
un-indexed inner table it's 80 million comparisons, catastrophic. Always read
the loop count together with the inner scan type.

**Common mistakes**:
> - Reading only the top-level `cost=0.00..1284.55` without checking
>   `loops=16` on the inner node, which is where the real multiplier hides.
> - Assuming Nested Loop is always bad — it's the *right* choice when the
>   inner side is small or indexed; it's only a problem combined with an
>   unindexed, large inner Seq Scan.

---

### Q13. What's the difference between a unique index and a `UNIQUE` constraint?

**Answer**: In PostgreSQL, a `UNIQUE` constraint is implemented *using* a
unique index under the hood — there's no separate enforcement mechanism.
`ALTER TABLE accounts ADD CONSTRAINT uq_x UNIQUE (col);` and `CREATE UNIQUE
INDEX uq_x ON accounts(col);` produce functionally near-identical results.
The difference is metadata and intent: a constraint shows up in
`information_schema.table_constraints`, participates in `ON CONFLICT ON
CONSTRAINT`, and can back a foreign key; a bare unique index is more flexible
(it can be partial, or use a non-default operator class) but can't be
referenced by `ON CONFLICT ON CONSTRAINT name` (though `ON CONFLICT (columns)`
still works against it) and isn't listed as a formal constraint.

```sql
-- Constraint form
ALTER TABLE banking_db.customers ADD CONSTRAINT uq_customers_email UNIQUE (email);

-- Equivalent unique index, but partial (only enforces uniqueness among active rows)
CREATE UNIQUE INDEX uq_customers_email_active
    ON banking_db.customers (email)
    WHERE deleted_at IS NULL;
```

**Why it works**: PostgreSQL's unique index enforcement walks the B-tree on
insert/update and rejects a duplicate key before the row is committed — the
constraint is just a catalog-level label wrapped around this same mechanism.

**Alternative approaches**: A partial unique index (like the second example)
can express "unique among active rows" — something a plain `UNIQUE`
constraint cannot do, since constraints don't support `WHERE`.

**Performance considerations**: Identical write/read cost either way — the
choice is about which catalog/constraint features you need, not speed.

**Common mistakes**:
> - Believing `UNIQUE` constraints and unique indexes are different
>   mechanisms under the hood.
> - Trying to add a `WHERE` clause to a `UNIQUE` constraint definition — not
>   supported; you must use a partial unique index instead.

---

### Q14. When would you use a partial index? Give a concrete example from `ecommerce_db`.

**Answer**: A partial index only indexes rows matching a `WHERE` clause,
making it smaller and faster to maintain when queries only ever care about a
subset of rows.

```sql
CREATE INDEX idx_orders_pending
    ON ecommerce_db.orders (order_date)
    WHERE status = 'PENDING';
```

Given that most orders end up `DELIVERED`/`CANCELLED` and only a small number
sit `PENDING` at any time, a query like `SELECT * FROM orders WHERE status =
'PENDING' ORDER BY order_date;` (e.g., an "orders to process" queue) benefits
from an index containing *only* the sparse, operationally-relevant rows.

**Why it works**: The index only ever contains entries for rows where
`status = 'PENDING'`, so it stays tiny regardless of how large the `orders`
table grows, and the planner can prove (via the `WHERE` clause matching the
query's predicate) that it's safe to use for that specific filter.

**Alternative approaches**: A full index on `(status, order_date)` also
serves this query but grows proportionally with the whole table and carries
maintenance overhead for status values the queue never touches; a partial
index is strictly the better fit for a well-known, stable "hot" subset.

**Performance considerations**: Smaller index = fewer pages to traverse and
cache, faster inserts for rows *outside* the partial predicate (they don't
touch this index at all), but the index is unusable for any query whose
`WHERE` clause doesn't provably imply the index's predicate.

**Common mistakes**:
> - Writing a query with a slightly different condition (`status IN
>   ('PENDING', 'PAID')`) and being confused why the partial index (`WHERE
>   status = 'PENDING'`) isn't used — the planner can't always prove
>   implication across differing predicates.
> - Using a partial index for a subset that isn't actually stable/sparse
>   over time, losing the size benefit as data grows.

---

### Q15. What's the difference between an expression index and a regular index? Show one that fixes a `LOWER()` query.

**Answer**: A regular index stores raw column values; an expression
(functional) index stores the *result of an expression* applied to columns,
letting the planner use an index even when the query filters on a
transformed value.

```sql
-- Without this index, WHERE LOWER(email) = ... forces a Seq Scan
-- even though email has a unique index, because the index stores
-- raw email values, not lowercased ones.
CREATE INDEX idx_customers_email_lower
    ON banking_db.customers (LOWER(email));

EXPLAIN SELECT * FROM banking_db.customers
WHERE LOWER(email) = 'ravi.shankar@mail.com';
-- Index Scan using idx_customers_email_lower
```

**Why it works**: PostgreSQL indexes the *output* of `LOWER(email)` for every
row, so a query whose `WHERE` clause contains the *syntactically identical*
expression `LOWER(email)` can match against the index directly instead of
computing `LOWER()` on every row during a sequential scan.

**Alternative approaches**: Normalize at write time instead — store a
generated column `email_lower text GENERATED ALWAYS AS (LOWER(email))
STORED` with a plain index on it; this is more transparent in `EXPLAIN` plans
and reusable by ORMs that don't naturally emit `LOWER(email)` in predicates.
A `citext` column type (see Advanced Data Types) solves case-insensitive
email comparison at the type level, sidestepping expression indexes
altogether.

**Performance considerations**: The expression is recomputed at index
maintenance time on every insert/update (cheap for `LOWER()`, potentially
expensive for costly expressions), and the query's `WHERE` clause must match
the indexed expression *exactly* (`WHERE lower(email) = ...`, not `WHERE
UPPER(email) = ...` or `WHERE email ILIKE ...`) for the index to be used.

**Common mistakes**:
> - Writing the expression index on `LOWER(email)` but querying with
>   `ILIKE` — `ILIKE` isn't the same expression and won't automatically use
>   this index (though a trigram index would help there instead).
> - Forgetting expression indexes recompute on every write, making them a
>   poor fit for volatile, expensive expressions.

---

### Q16. Beyond B-tree, what are GIN, GiST, and BRIN indexes for? Give one example use case each.

**Answer**:

- **GIN** (Generalized Inverted Index): built for values containing multiple
  "elements" you search inside of — arrays, `jsonb`, full-text `tsvector`.
  ```sql
  -- Search reviews' full text quickly
  CREATE INDEX idx_reviews_text_fts
      ON ecommerce_db.reviews USING GIN (to_tsvector('english', review_text));
  ```
- **GiST** (Generalized Search Tree): built for data with overlap/containment/
  nearest-neighbor semantics — ranges, geometric types, or trigram similarity
  search on text.
  ```sql
  -- If loans stored a date range for a promotional rate period
  CREATE INDEX idx_loan_period ON banking_db.loans
      USING GIST (daterange(start_date, start_date + (term_months || ' months')::interval));
  ```
- **BRIN** (Block Range Index): built for very large tables physically
  correlated with insertion order (e.g., a timestamp that increases as rows
  are appended) — stores only min/max per block range, so it's tiny.
  ```sql
  CREATE INDEX idx_transactions_date_brin
      ON banking_db.transactions USING BRIN (transaction_date);
  ```

**Why it works**: Each index type matches its data structure to the query
pattern it accelerates — GIN builds a posting list per distinct element for
"does this array/document contain X" queries; GiST supports arbitrary
containment/distance predicates via a tree of bounding regions; BRIN skips
whole block ranges outright when a range's min/max can't possibly satisfy the
predicate, at the cost of much coarser precision.

**Alternative approaches**: A B-tree on `jsonb` only supports equality on the
whole document; GIN is required for `@>`, `?`, `?|` containment operators. A
B-tree on `transaction_date` on a huge, append-only table would work but
costs far more storage than BRIN for a workload that mostly filters coarse
date ranges.

**Performance considerations**: GIN indexes are large and slow to update
(good for read-heavy, write-light `jsonb`/array columns; consider
`FASTUPDATE` or batching for write-heavy ones). BRIN indexes are extremely
small (megabytes for a table with a billion rows) but only useful when
physical row order correlates with the indexed column — a `transactions`
table loaded out of date order gets little benefit from BRIN.

**Common mistakes**:
> - Using GIN on a rapidly-changing `jsonb` column without considering the
>   write amplification cost.
> - Using BRIN on a column with no physical correlation to insert order (e.g.,
>   a randomly-assigned UUID), which makes every block's min/max range span
>   the whole table and defeats the point.

---

## 3. Query Planner & EXPLAIN

The planner is a cost-based optimizer: it estimates the cost of many possible
execution strategies (scan types, join orders, join algorithms) using table
statistics, and picks the cheapest one it can find. Reading `EXPLAIN` output
fluently — telling estimated from actual, spotting misestimates, recognizing
which node types signal trouble — is one of the highest-value skills tested
at this tier.

### Q17. Walk through how the PostgreSQL planner decides on a query plan.

**Answer**: For a given query, the planner: (1) parses and rewrites the query
(expanding views, applying rules); (2) generates candidate access paths for
each table (sequential scan, index scan, index-only scan, bitmap scan) using
statistics from `pg_statistic` (row counts, most-common values, histograms,
correlation) gathered by `ANALYZE`; (3) generates candidate join orders and
join algorithms (nested loop, hash join, merge join) for multi-table queries,
pruning the search space with dynamic programming for small numbers of
tables and a genetic algorithm above `join_collapse_limit`/`geqo_threshold`
(default 12 tables); (4) assigns each candidate plan an estimated cost
(startup cost + total cost, in arbitrary units driven by `seq_page_cost`,
`random_page_cost`, `cpu_tuple_cost`, etc.); (5) picks the cheapest total plan.

**Why it works**: This is why *statistics accuracy* matters more than almost
anything else for plan quality — the planner never looks at your actual data
at plan time, only at the statistical summary `ANALYZE` produced. Stale
statistics (after a bulk load, mass delete, or before autovacuum's analyze
threshold is hit) are the single most common cause of a "sudden" bad plan.

**Alternative approaches**: A rule-based optimizer (older Oracle style) picks
plans from fixed heuristics regardless of data distribution — PostgreSQL
abandoned this model because it doesn't adapt to skewed data.

**Performance considerations**: `default_statistics_target` (default 100)
controls histogram/MCV granularity; bumping it for specific skewed columns
(`ALTER TABLE ... ALTER COLUMN ... SET STATISTICS 500;`) can meaningfully
improve plan quality for columns with unusual distributions, at the cost of
slower `ANALYZE` and slightly larger catalog storage.

**Common mistakes**:
> - Tuning a query without first running `ANALYZE` on the table — you might
>   be chasing a plan problem that stale statistics caused, not a genuine
>   bad-decision by the planner.
> - Assuming cost units correspond to actual milliseconds — they're relative,
>   dimensionless numbers tuned to reflect I/O and CPU *ratios*, not wall time.

---

### Q18. What's the difference between `EXPLAIN` and `EXPLAIN ANALYZE`, and why is that difference dangerous on a write query?

**Answer**: `EXPLAIN` alone shows the planner's *estimated* plan and costs
without running the query. `EXPLAIN ANALYZE` actually *executes* the query
(and, for `INSERT`/`UPDATE`/`DELETE`, actually performs the write) and reports
real timings and row counts alongside the estimates.

```sql
EXPLAIN ANALYZE
DELETE FROM ecommerce_db.order_items WHERE order_id = 5;
```

This genuinely deletes the row(s) — `EXPLAIN ANALYZE` is not a dry run.

**Why it works**: To report *actual* rows/time per node, PostgreSQL has to
run the real executor, which performs real heap writes/deletes/updates and
fires real triggers, not a simulation.

**Alternative approaches**: Wrap the statement in a transaction you intend to
roll back:
```sql
BEGIN;
EXPLAIN ANALYZE DELETE FROM ecommerce_db.order_items WHERE order_id = 5;
ROLLBACK;
```
This gets you real timing without a permanent write. `EXPLAIN (ANALYZE,
BUFFERS, VERBOSE)` on a `SELECT` is always safe since selects don't mutate
data (aside from side effects like advancing sequences via functions used in
the select list).

**Performance considerations**: `EXPLAIN ANALYZE` itself adds instrumentation
overhead (timing calls per row/node), so the reported total time is usually
somewhat *higher* than the query's real unobserved runtime — for very
fast, high-frequency queries this overhead can be a meaningful fraction of
the reported time. Use `EXPLAIN (ANALYZE, TIMING OFF)` to reduce this if only
row counts matter.

**Common mistakes**:
> - Running `EXPLAIN ANALYZE` on an untested `DELETE`/`UPDATE` directly
>   against production without a transaction wrapper — a career-defining
>   mistake if the `WHERE` clause is wrong.
> - Trusting `EXPLAIN` (without `ANALYZE`) numbers as ground truth when
>   debugging a slow query — they're estimates and can be badly wrong when
>   statistics are stale or correlated columns confuse the planner.

---

### Q19. Diagnose this plan for a report query joining `orders`, `order_items`, and `products`.

```text
Hash Join  (cost=1.11..3.45 rows=1 width=64) (actual time=0.045..210.882 rows=8500 loops=1)
  Hash Cond: (oi.product_id = p.product_id)
  ->  Seq Scan on order_items oi  (cost=0.00..1.15 rows=15 width=24) (actual time=0.01..0.02 rows=15 loops=1)
  ->  Hash  (cost=1.10..1.10 rows=1 width=48) (actual time=0.02..0.02 rows=10 loops=1)
        ->  Seq Scan on products p  (cost=0.00..1.10 rows=10 width=48) (actual time=0.01..0.01 rows=10 loops=1)
Planning Time: 0.180 ms
Execution Time: 211.010 ms
```

**Answer**: The planner estimated `rows=1` for the join but actually got
`rows=8500` — a massive misestimate (~8500x). This means the planner's row
estimate for the *combined* predicate on `product_id` badly underestimated
match count, likely because statistics are stale (`ANALYZE` hasn't run since
a bulk load added far more `order_items` rows than the 15 seed rows the
planner still believes exist) or because the join condition correlates with
another filtered column the planner can't account for. Even though the
chosen algorithm (Hash Join) is reasonable, the wildly wrong cardinality
estimate means the planner may be under-provisioning `work_mem` for the hash
table, and worse, if this join feeds into an outer node, the outer node's own
plan choice (e.g., choosing Nested Loop expecting only 1 row) could be
catastrophically wrong.

**Why it works (fix)**: `ANALYZE ecommerce_db.order_items;
ANALYZE ecommerce_db.products;` refreshes statistics so the planner's
cardinality estimates reflect current data volume, which lets it choose
`work_mem` sizing and outer join strategies correctly.

**Alternative approaches**: If the misestimate persists after `ANALYZE`
because of genuinely correlated columns the planner's single-column
statistics can't capture, `CREATE STATISTICS` (extended statistics, PG10+)
on the correlated column combination can improve estimates further.

**Performance considerations**: A 211ms execution time for a hash join over
what the planner thought was a 1-row result is itself a smell — real query
time far exceeding what a "cost=3.45" plan implies is a classic statistics
red flag, worth checking before assuming the query itself needs rewriting.

**Common mistakes**:
> - Rewriting the SQL to try to "help" the planner before checking whether
>   `ANALYZE` alone fixes the misestimate.
> - Only looking at `Execution Time` and ignoring the estimated-vs-actual
>   `rows=` gap, which is the actual diagnostic signal here.

---

### Q20. Diagnose this plan — a lookup by `email` on `banking_db.customers` that's supposed to be instant but takes 40ms.

```text
Seq Scan on customers  (cost=0.00..1.06 rows=1 width=64) (actual time=0.015..0.021 rows=1 loops=1)
  Filter: ((email)::text = 'ravi.shankar@mail.com'::text)
Planning Time: 0.09 ms
Execution Time: 40.05 ms
```

**Answer**: The scan itself is fast (0.021ms) — the query plan is *not* the
problem here. Nearly all of the 40ms is happening *outside* the reported
node timings: `Planning Time` + `Execution Time` sum to ~40.1ms, but the
actual node timing (`actual time=0.015..0.021`) accounts for only a fraction
of a millisecond. This mismatch points to overhead outside the executor
proper — connection setup/teardown per request, network round-trip latency,
lock waiting before the statement even started executing, or client-side
overhead (e.g., ORM query construction, ping to a remote DB host) being
misattributed to "the query." The fix is not indexing; it's investigating
connection pooling, network latency between app and database, or whether
this specific timing was captured client-side rather than from `EXPLAIN
ANALYZE` itself.

**Why it works**: `EXPLAIN ANALYZE`'s own `Execution Time` measures only
server-side executor time for that statement — if the 40ms was actually
observed by the *application*, not by `EXPLAIN ANALYZE`, then the gap between
"query itself: <1ms" and "app sees 40ms" is round-trip/connection overhead,
not something an index can fix.

**Alternative approaches**: Use `pg_stat_statements` to see aggregate,
server-side timing across many executions of this exact query shape,
cross-referenced with connection pool metrics (e.g., PgBouncer wait time) to
isolate where the 40ms actually goes.

**Performance considerations**: This is a reminder that "the database is
slow" reports need to specify *where* the timing was measured — a single
un-pooled connection opening a fresh TCP + TLS + auth handshake per query can
easily add tens of milliseconds having nothing to do with the SQL at all.

**Common mistakes**:
> - Adding an index in response to a "slow query" complaint without first
>   confirming the slowness is actually inside the database engine.
> - Not distinguishing `Planning Time` / `Execution Time` (server-side) from
>   application-observed latency (network + connection + serialization).

---

### Q21. What does `Rows Removed by Filter` in an `EXPLAIN ANALYZE` plan tell you, and why should it worry you?

**Answer**: It shows how many rows a node read and then discarded because
they failed a `WHERE`/`ON` condition that could *not* be pushed into an index
condition — meaning the engine did the I/O and CPU work of reading and
evaluating those rows for nothing.

```text
Seq Scan on attendance  (cost=0.00..1.13 rows=2 width=24) (actual time=0.02..0.03 rows=2 loops=1)
  Filter: (status = 'LATE'::text)
  Rows Removed by Filter: 8
```

Here, 8 of 10 rows were read and discarded — on a 10-row table this is
trivial, but the same pattern on a 50-million-row table (reading 45 million
rows just to keep 5 million) is a strong signal that an index on `status`
(or a composite index including it) would let the engine avoid reading the
discarded rows at all.

**Why it works**: `Rows Removed by Filter` appears specifically when a
condition is evaluated as a post-scan *filter* rather than baked into an
*index condition* (`Index Cond`) or handled by the storage layer — it's the
executor's way of surfacing "I did more work than the output size suggests."

**Alternative approaches**: If the filtered column is low-cardinality and
frequently queried this way, a partial index restricted to that value (see
Q14) eliminates the wasted reads entirely rather than merely relocating them
into an index condition.

**Performance considerations**: A high `Rows Removed by Filter` relative to
returned rows, combined with a large total row count in the underlying scan,
is one of the clearest "add an index here" signals `EXPLAIN ANALYZE` gives
you — much clearer than the cost estimate alone.

**Common mistakes**:
> - Ignoring `Rows Removed by Filter` because the query "returns the right
>   answer" — correctness and efficiency are separate concerns, and this line
>   is purely about efficiency.
> - Confusing filter-level row removal with join-level row removal — check
>   which node the line appears under.

---

### Q22. What is a "bitmap heap scan," and when does the planner choose it over a plain index scan?

**Answer**: A Bitmap Index Scan first builds an in-memory bitmap of heap page
locations matching an index condition (possibly combining multiple indexes
with `BitmapAnd`/`BitmapOr`), then a Bitmap Heap Scan visits those heap pages
*in physical page order* (not index order) to fetch the actual rows.

```text
Bitmap Heap Scan on orders  (cost=4.20..12.55 rows=6 width=48) (actual time=0.05..0.09 rows=6 loops=1)
  Recheck Cond: (status = 'DELIVERED'::text)
  ->  Bitmap Index Scan on idx_orders_status  (cost=0.00..4.20 rows=6 width=0) (actual time=0.03..0.03 rows=6 loops=1)
        Index Cond: (status = 'DELIVERED'::text)
```

The planner picks this over a plain `Index Scan` when a predicate matches
*enough* rows that random-order heap fetches (one per index entry, as a plain
Index Scan does) would be more expensive than sorting matches by physical
page order first and reading each needed page once — a middle ground between
"too many rows for an index scan" and "too few for a worthwhile seq scan."

**Why it works**: Deduplicating heap-page visits (a single page might contain
several matching rows) and visiting pages in physical order converts what
would be scattered random I/O into a more sequential-ish access pattern,
without paying the cost of reading the *entire* table like a Seq Scan would.

**Alternative approaches**: `BitmapAnd`/`BitmapOr` combine bitmaps from
multiple single-column indexes to serve a multi-predicate query without
needing a purpose-built composite index — useful, but a well-designed
composite index (Q10) is usually still faster since it avoids building and
intersecting bitmaps at all.

**Performance considerations**: Bitmap scans use `work_mem` to hold the
bitmap; if the bitmap would exceed `work_mem`, PostgreSQL "loses fidelity"
and switches to a page-level-only bitmap (visible as `Lossy: N` — meaning it
recheck-filters more than strictly needed), a bit more work but still far
short of a seq scan.

**Common mistakes**:
> - Interpreting `Recheck Cond` as evidence of an error — it's normal and
>   expected in bitmap scans (needed because the bitmap can be lossy at the
>   page level and to reverify visibility for MVCC).
> - Assuming Bitmap Heap Scan is strictly worse than Index Scan — for
>   medium-selectivity predicates it's often the *fastest* available option.

---

### Q23. What is `work_mem` and how does misconfiguring it show up in `EXPLAIN ANALYZE`?

**Answer**: `work_mem` bounds the memory a single sort, hash join, or hash
aggregate operation may use *per node, per execution* before spilling
intermediate data to temporary disk files. A query with several such
operations (or run by many concurrent connections) can use several multiples
of `work_mem` simultaneously — it is not a total server-wide cap.

```text
Sort  (cost=458.87..462.87 rows=1600 width=64) (actual time=12.410..38.220 rows=1600 loops=1)
  Sort Key: order_date DESC
  Sort Method: external merge  Disk: 3096kB
```

`Sort Method: external merge  Disk: 3096kB` means the sort didn't fit in
`work_mem` and spilled to temp files on disk — much slower than an in-memory
`quicksort`.

**Why it works (fix)**: Either raise `work_mem` (session-level via `SET
work_mem = '64MB';` for this connection/query, or in `postgresql.conf` for a
global default) so the sort fits in memory, or reduce the amount of data
being sorted (push filters earlier, add a covering index that provides the
data pre-sorted, as in Q10).

**Alternative approaches**: Raising `work_mem` globally is risky because it
multiplies across concurrent connections and concurrent sort/hash nodes
within a single query — better to raise it per-session or per-role for
known-heavy reporting workloads (`ALTER ROLE reporting_user SET work_mem =
'256MB';`) rather than server-wide.

**Performance considerations**: `external merge` sorts are often 5-20x
slower than in-memory `quicksort`/`top-N heapsort` for the same row count,
since they involve writing and re-reading temp files; watch `Sort Method` and
`Disk: NkB` on every sort node in `EXPLAIN ANALYZE`.

**Common mistakes**:
> - Blanket-raising `work_mem` server-wide without accounting for
>   `max_connections × (work_mem × operations per query)` total worst-case
>   memory, causing OOM under concurrent load.
> - Not checking `Sort Method`/`Disk` at all and assuming a `Sort` node is
>   always cheap.

---

### Q24. What is partition pruning, and what does it look like — or fail to look like — in `EXPLAIN`?

**Answer**: Partition pruning is the planner's ability to skip scanning
partitions that provably cannot contain rows matching the query's `WHERE`
clause, based on each partition's bounds. On a range-partitioned
`transactions` table partitioned by `transaction_date`, a query filtering to
a single month should only touch that month's partition.

```text
-- Good: pruning worked
Append  (cost=0.00..8.50 rows=50 width=64)
  ->  Seq Scan on transactions_2024_01 t  (cost=0.00..8.50 rows=50 width=64)
        Filter: (transaction_date >= '2024-01-01' AND transaction_date < '2024-02-01')

-- Bad: pruning failed — every partition still appears under the Append
Append  (cost=0.00..40.00 rows=250 width=64)
  ->  Seq Scan on transactions_2024_01 t
  ->  Seq Scan on transactions_2024_02 t
  ->  Seq Scan on transactions_2024_03 t
  ...
```

If every child partition shows up under the `Append` node regardless of the
filter, pruning didn't happen — the planner couldn't prove which partitions
are excluded, and it will scan all of them.

**Why it works**: Pruning requires the `WHERE` clause to directly constrain
the partition key using a form the planner can statically (or, for
`enable_partition_pruning` at execution time, dynamically for parameterized
values) match against each partition's bounds — a literal or a
simply-comparable expression, not something wrapped in an opaque function
call or joined in from another table without a matching value at plan time
for static pruning.

**Alternative approaches**: If the filter value is only known at runtime
(e.g., bound via a prepared statement parameter or a subquery), PostgreSQL
11+ supports *runtime* partition pruning during execution, visible as
`Subplans Removed: N` in `EXPLAIN ANALYZE` rather than at plan time.

**Performance considerations**: Failed pruning on a table with dozens of
partitions means dozens of child scans instead of one — a common regression
after wrapping the partition key in a function (`WHERE
date_trunc('month', transaction_date) = ...`) that the planner can't map back
to partition bounds.

**Common mistakes**:
> - Filtering on an expression derived from the partition key instead of the
>   raw column, silently defeating static pruning.
> - Not testing with `EXPLAIN` after adding a new partitioning scheme —
>   pruning failures are invisible unless you actually check the plan.

---

## 4. Performance Optimization

This section is about the broader toolbox beyond indexing alone: rewriting
queries to avoid unnecessary work, understanding `SARG`-ability, batching
writes, avoiding N+1 patterns, and knowing what `VACUUM`/`ANALYZE` actually
do for you.

### Q25. What does it mean for a predicate to be "sargable," and rewrite a non-sargable predicate on `banking_db.transactions`.

**Answer**: "Sargable" (Search ARGument-able) means a predicate is written in
a form the planner can satisfy using an index directly, without wrapping the
indexed column in a function or expression that hides its raw value.

```sql
-- Not sargable: EXTRACT() wraps the column, so an index on
-- transaction_date can't be used for this comparison
SELECT * FROM banking_db.transactions
WHERE EXTRACT(YEAR FROM transaction_date) = 2024;

-- Sargable rewrite: raw column compared to literal bounds
SELECT * FROM banking_db.transactions
WHERE transaction_date >= '2024-01-01' AND transaction_date < '2025-01-01';
```

**Why it works**: A B-tree index stores raw `transaction_date` values in
sorted order. `EXTRACT(YEAR FROM transaction_date) = 2024` requires computing
`EXTRACT()` for *every row* before comparison — there's no way to seek
directly into the tree for "all rows whose year-extract equals 2024" without
an expression index built specifically on `EXTRACT(YEAR FROM ...)`. Rewriting
as a range on the raw column lets a normal B-tree index be walked directly.

**Alternative approaches**: If you can't avoid the functional form (e.g.,
it's generated by an ORM), an expression index on `EXTRACT(YEAR FROM
transaction_date)` restores index usability without touching application
code — but the range rewrite is simpler and works with a plain index you
likely already have.

**Performance considerations**: Non-sargable predicates force full sequential
scans (or full index scans without a usable `Index Cond`) even when a perfect
index exists on the raw column — one of the most common "why isn't my index
being used" causes.

**Common mistakes**:
> - Wrapping indexed columns in `EXTRACT()`, `LOWER()` (without a matching
>   expression index), `col + 1 = x`, `CAST(col AS text) = ...`, or
>   concatenation — all defeat sargability.
> - Wrapping the *literal* instead avoids the problem: `col = literal_expr`
>   is fine because the function runs once on the constant, not once per row.

---

### Q26. What is the N+1 query problem, and how would you fix it for loading each order's line items in `ecommerce_db`?

**Answer**: N+1 happens when code fetches a list of N parent rows, then loops
over them issuing one additional query per row to fetch related child rows —
1 query becomes 1 + N queries.

```sql
-- The N+1 anti-pattern (pseudocode issuing one query per order):
-- SELECT * FROM orders WHERE user_id = 1;                 -- 1 query
-- for each order: SELECT * FROM order_items WHERE order_id = ?;  -- N queries

-- Fixed: one query using a join or IN
SELECT o.order_id, oi.product_id, oi.quantity, oi.unit_price
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.user_id = 1;
```

**Why it works**: A single joined query lets the database do one pass over
the relevant index/heap pages and return everything at once, instead of
paying a full network round-trip + planning + execution overhead per parent
row — the fixed cost of "talking to the database" is incurred once instead
of N+1 times.

**Alternative approaches**: If the application needs results grouped by
parent (rather than flattened rows), use `json_agg`/`array_agg` to nest
children per order in a single query, avoiding both N+1 *and*
application-side result reassembly:
```sql
SELECT o.order_id,
       json_agg(json_build_object('product_id', oi.product_id, 'quantity', oi.quantity)) AS items
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.user_id = 1
GROUP BY o.order_id;
```

**Performance considerations**: Network round-trip latency (often 0.5-5ms
even on a fast local network) dominates N+1 cost far more than the actual
query execution time — 100 orders means 100 extra round trips, easily adding
hundreds of milliseconds regardless of how well-indexed each individual
child query is.

**Common mistakes**:
> - Blaming "slow SQL" for what's actually an application/ORM pattern issue
>   (lazy-loading associations in a loop) — the fix is architectural, not
>   an index.
> - Over-correcting into one giant query that joins far more than needed and
>   returns a huge duplicated result set instead of using aggregation or
>   batched `IN (...)` fetches.

---

### Q27. What's the difference between `VACUUM`, `VACUUM FULL`, and `ANALYZE`, and why does routine `VACUUM` matter for performance?

**Answer**: `VACUUM` reclaims space occupied by dead tuples (rows made
obsolete by `UPDATE`/`DELETE` under MVCC) so it can be reused by future
inserts/updates, and updates the visibility map (enabling index-only scans);
it does this *without* holding an exclusive lock, so normal reads/writes
continue. `VACUUM FULL` rewrites the entire table into a new, compact file
(actually shrinking on-disk size back to the OS), but takes an `ACCESS
EXCLUSIVE` lock for the duration — blocking all access. `ANALYZE` refreshes
planner statistics (row counts, most-common values, histograms) without
touching dead tuples at all.

```sql
VACUUM (VERBOSE, ANALYZE) banking_db.transactions;
```

**Why it works**: PostgreSQL's MVCC never overwrites a row in place on
update — it writes a new tuple version and marks the old one dead once no
transaction can still see it. Without `VACUUM`, dead tuples accumulate
("bloat"), tables grow larger than their live data warrants, sequential scans
read more pages than necessary, and indexes reference dead entries until
cleaned up.

**Alternative approaches**: `autovacuum` (enabled by default) runs `VACUUM`
and `ANALYZE` automatically based on dead-tuple/insert thresholds — for most
workloads, tuning autovacuum's thresholds/cost limits per table (`ALTER TABLE
... SET (autovacuum_vacuum_scale_factor = 0.05);`) is preferable to relying
on manual `VACUUM`.

**Performance considerations**: Table bloat from insufficient vacuuming
degrades sequential scan time, index scan time (dead index entries still get
traversed and rechecked), and eventually forces `VACUUM FULL` or `pg_repack`
to reclaim disk — much more disruptive than keeping up with routine vacuum.

**Common mistakes**:
> - Running `VACUUM FULL` on a large, live production table during business
>   hours, causing an extended full-table lock.
> - Disabling autovacuum "because it causes I/O spikes" instead of tuning its
>   cost-based throttling parameters — this trades a manageable ongoing cost
>   for a much larger unmanaged one later.

---

### Q28. A report query filters on both `department_id` and `hire_date` on `employees`. You have separate single-column indexes on each. Why might the planner still choose a sequential scan, and what would you do about it?

**Answer**: Two single-column indexes force the planner to choose between
using just one of them (and filtering the rest of the predicate on the heap)
or combining both via a `BitmapAnd` of two separate bitmap index scans. If
the table is small (as `employees` is, 16 rows) or if combining bitmaps costs
more than just reading the whole tiny table sequentially, the planner
rationally picks a sequential scan — this is expected and correct behavior on
small tables regardless of indexing, and no index change is "wrong" here.
On a *large* table exhibiting the same pattern, the fix is a composite index
matching both predicates together:

```sql
CREATE INDEX idx_employees_dept_hire
    ON company_db.employees (department_id, hire_date);
```

**Why it works**: A composite index lets the planner satisfy both predicates
in a single index descent (`Index Cond: (department_id = X AND hire_date >=
Y)`) instead of intersecting two separate bitmaps or scanning one index and
filtering the rest — cheaper in both I/O and CPU once row counts are large
enough to matter.

**Alternative approaches**: Leaving the two single-column indexes in place
still lets the planner use `BitmapAnd` when beneficial, and each single-
column index remains independently useful for other queries filtering on
just one of those columns — a composite index only helps queries that use
its columns as a matching left-to-right prefix.

**Performance considerations**: Don't over-index a small dimension table
(like `employees` with 16 rows) purely to chase a plan you *expect* to see —
verify the table's actual row count and selectivity before concluding an
index is "wrong."

**Common mistakes**:
> - Forcing index usage on a tiny table with `SET enable_seqscan = off`
>   during testing, then being surprised the "fix" doesn't matter at
>   production scale where the table is genuinely large.
> - Adding a composite index without checking whether existing single-column
>   indexes already serve other important query shapes — dropping them
>   prematurely can regress those other queries.

---

### Q29. What is a correlated subquery, and how would you rewrite this one as a join for performance? `SELECT * FROM employees e WHERE salary_id IN (SELECT salary_id FROM salaries s WHERE s.employee_id = e.employee_id AND s.effective_date = (SELECT MAX(effective_date) FROM salaries s2 WHERE s2.employee_id = e.employee_id));`

**Answer**: A correlated subquery references a column from the outer query
inside its own `WHERE` clause, forcing (conceptually) re-execution once per
outer row.

```sql
-- Rewrite using a window function, evaluated once over the whole set
SELECT e.*, s.base_salary, s.bonus, s.effective_date
FROM company_db.employees e
JOIN (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM company_db.salaries
) s ON s.employee_id = e.employee_id AND s.rn = 1;
```

**Why it works**: The window-function rewrite computes each employee's latest
salary row in a single pass over `salaries`, sorted and partitioned once,
rather than re-scanning `salaries` twice per outer employee row (once for the
inner `MAX`, once for the outer `IN`) as the correlated version conceptually
requires. The planner *can* sometimes optimize a correlated subquery into a
semi-join execution strategy automatically, but the explicit window-function
rewrite is easier to reason about and reliably avoids repeated inner scans.

**Alternative approaches**: `DISTINCT ON` is a PostgreSQL-specific,
often-fastest way to get "latest row per group":
```sql
SELECT DISTINCT ON (employee_id) *
FROM company_db.salaries
ORDER BY employee_id, effective_date DESC;
```
This is idiomatic PostgreSQL but not portable to other databases, unlike the
window-function version.

**Performance considerations**: On small tables the planner often flattens
the correlated subquery into a semi-join automatically and performance
differs little; on large tables, verify with `EXPLAIN` that the correlated
form isn't compiling into a literal nested-loop-per-outer-row plan — if it
is, the window-function/`DISTINCT ON` rewrite is a straightforward, reliable
fix rather than hoping the planner optimizes it away.

**Common mistakes**:
> - Assuming all correlated subqueries are automatically slow — modern
>   planners often rewrite simple ones into efficient joins; check `EXPLAIN`
>   rather than reflexively banning the pattern.
> - Using `DISTINCT ON` without a matching `ORDER BY` on the same leading
>   columns, which produces a non-deterministic "first" row.

---

### Q30. What's the difference between `LIMIT`/`OFFSET` pagination and keyset (seek) pagination, and why does the former get slow?

**Answer**: `LIMIT n OFFSET m` pagination still must count/skip past `m` rows
before returning the next `n`, even though it discards them — cost grows
linearly with the offset.

```sql
-- Slow at high offsets: page 500 of orders means scanning/discarding 5000 rows
SELECT * FROM ecommerce_db.orders ORDER BY order_id LIMIT 10 OFFSET 5000;

-- Keyset pagination: carry the last-seen key forward, no offset needed
SELECT * FROM ecommerce_db.orders
WHERE order_id > 5010          -- last order_id seen on the previous page
ORDER BY order_id
LIMIT 10;
```

**Why it works**: Keyset pagination turns "skip 5000 rows" into "seek
directly to the row just past order_id 5010" using an index on `order_id` —
an O(log n) index descent regardless of how deep into the result set you are,
instead of an O(offset) scan-and-discard.

**Alternative approaches**: `LIMIT`/`OFFSET` is simpler to implement
(supports "jump to page 47" directly) and fine for shallow pagination (first
few pages) or small tables; keyset pagination requires a stable, indexed sort
key and doesn't support arbitrary random-access page jumps, only "next"/
"previous" from a known cursor position.

**Performance considerations**: `OFFSET 100000` on a large table can mean
reading and discarding 100,000 rows on every single request — this cost is
paid on *every page load*, making deep pagination on a growing table
progressively slower over the table's lifetime even if nothing else changes.

**Common mistakes**:
> - Building "infinite scroll" UI with `OFFSET`-based pagination — exactly
>   the use case where keyset pagination should be used instead, since users
>   never need arbitrary page jumps in that UI pattern.
> - Using keyset pagination on a non-unique sort key without a tiebreaker
>   column, causing rows to be skipped or duplicated across pages when
>   multiple rows share the same key value.

---

### Q31. Why can adding an index ever make write performance noticeably worse, and how would you decide how many indexes is "too many" on `ecommerce_db.order_items`?

**Answer**: Every index on a table must be updated on every `INSERT`, most
`UPDATE`s (any touching an indexed column, or with `HOT` updates disabled by
row movement), and every `DELETE` — so each additional index adds write
amplification: one extra B-tree (or GIN/GiST) maintenance operation per
write, plus additional WAL volume.

```sql
-- Before adding another index, check what's already there and how heavily
-- the table is written to.
SELECT indexrelname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
WHERE relname = 'order_items';
```

**Why it works (deciding "too many")**: Query `pg_stat_user_indexes` for
existing indexes' usage (`idx_scan`) — an index with `idx_scan = 0` after a
representative production period is a candidate for removal, since it's pure
write overhead with no read benefit. Weigh the read frequency and
selectivity benefit of a *new* index against `order_items`'s write rate
(every order places rows here) — a table that's written far more often than
it's read via a specific access pattern should be indexed conservatively.

**Alternative approaches**: A partial index (Q14) or a narrower composite
index that serves multiple query shapes via column-prefix matching reduces
the *number* of indexes needed without sacrificing coverage, versus adding a
new single-purpose index for every query variant.

**Performance considerations**: On a heavy-write table like `order_items`,
five to seven indexes is already a meaningful tax on `INSERT` throughput;
each index roughly adds one more random-I/O B-tree insertion per row
written, so write latency scales roughly linearly with index count.

**Common mistakes**:
> - Adding an index per new query without ever auditing `pg_stat_user_indexes`
>   for unused ones, letting index count grow unboundedly over the project's
>   life.
> - Assuming indexes are "free" because reads got faster, ignoring the
>   corresponding write-side cost that shows up later as the table grows.

---

### Q32. What is `pg_stat_statements`, and how would you use it to find the queries actually worth optimizing?

**Answer**: `pg_stat_statements` is an extension that tracks execution
statistics (call count, total/mean/max time, rows, shared buffer hits) for
every distinct normalized query shape the server has run, persisted across
executions (not per-session like `EXPLAIN`).

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT query, calls, total_exec_time, mean_exec_time,
       total_exec_time / NULLIF(calls, 0) AS avg_ms
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

**Why it works**: Sorting by `total_exec_time` (not `mean_exec_time`) surfaces
the queries costing the *most aggregate database time* — a query that's fast
per call but run 10 million times a day can dominate total load far more than
a rare query that's slow per call, and that's the one worth optimizing first
from a whole-system-throughput perspective.

**Alternative approaches**: `EXPLAIN ANALYZE` on a single query gives deep
insight into *one* query's plan but no sense of *frequency*; sorting
`pg_stat_statements` by `calls` instead of `total_exec_time` finds the
highest-frequency queries, useful for connection/latency-sensitive workloads
even if each call is individually cheap.

**Performance considerations**: `pg_stat_statements` normalizes literals
(`WHERE id = 5` and `WHERE id = 9` collapse into one entry with `id = $1`),
so it shows you query *shapes*, not individual slow executions — pair it
with `auto_explain` (logging actual plans for queries exceeding a duration
threshold) to catch specific pathological executions of an otherwise
well-behaved query shape.

**Common mistakes**:
> - Optimizing based on `mean_exec_time` alone without considering `calls`,
>   potentially spending effort on a rarely-run query while a high-frequency
>   query goes unnoticed.
> - Forgetting to `SELECT pg_stat_statements_reset();` after a schema change
>   or index addition, making before/after comparisons meaningless.

---

## 5. Stored Procedures

PostgreSQL distinguishes **procedures** (`CREATE PROCEDURE`, invoked with
`CALL`, can manage transactions internally) from **functions** (`CREATE
FUNCTION`, invoked in expression context, cannot commit/rollback). This
section focuses on procedures: transaction control, error handling, and
multi-step business logic like a bank transfer.

### Q33. What's the fundamental difference between a stored procedure and a function in PostgreSQL?

**Answer**: A procedure (`CREATE PROCEDURE`, PostgreSQL 11+) is invoked with
`CALL proc_name(...)`, cannot be used inside a `SELECT` expression, cannot
return a value via `RETURN <value>` (though it can have `INOUT` parameters),
but — critically — *can* execute `COMMIT`/`ROLLBACK` internally, controlling
its own transaction boundaries. A function (`CREATE FUNCTION`) is invoked
inside expressions (`SELECT my_func(x)`), must return a value (even `void`),
and always runs inside the transaction of its caller — it cannot commit or
roll back on its own.

```sql
CREATE PROCEDURE banking_db.close_stale_pending_orders()
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE ecommerce_db.orders SET status = 'CANCELLED'
    WHERE status = 'PENDING' AND order_date < now() - INTERVAL '30 days';
    COMMIT;  -- allowed in a procedure, not in a function
END;
$$;

CALL banking_db.close_stale_pending_orders();
```

**Why it works**: Procedures were introduced specifically to support
multi-step batch/ETL-style operations that need to commit partial progress
(e.g., commit every N rows in a loop) — something a function's
single-transaction constraint can't express.

**Alternative approaches**: If you don't need internal transaction control, a
`void`-returning function achieves nearly the same encapsulation and *can*
still be called from a function/trigger context, which a procedure cannot
(procedures can only be invoked via `CALL`, not from inside another
function/query).

**Performance considerations**: Committing mid-procedure in a large batch
loop reduces the duration any single transaction holds locks/keeps dead
tuples pinned, improving concurrency and reducing bloat versus one giant
transaction — a genuine architectural benefit for large batch jobs.

**Common mistakes**:
> - Trying to `SELECT my_procedure();` — procedures must be invoked with
>   `CALL`, not embedded in a query.
> - Adding `COMMIT`/`ROLLBACK` inside a function definition — PostgreSQL
>   rejects this outright; that control is procedure-only.

---

### Q34. Write a stored procedure that transfers money between two `banking_db.accounts`, with correct error handling and rollback.

**Answer**:

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.transfer_funds(
    p_from_account INT,
    p_to_account   INT,
    p_amount       NUMERIC(14,2)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_from_balance NUMERIC(14,2);
    v_from_status  VARCHAR(20);
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive, got %', p_amount
            USING ERRCODE = '22003';
    END IF;

    -- Lock the source row to prevent a concurrent transfer from
    -- overdrawing the account (see Transactions/Locking chapter).
    SELECT balance, status INTO v_from_balance, v_from_status
    FROM banking_db.accounts
    WHERE account_id = p_from_account
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source account % does not exist', p_from_account;
    END IF;

    IF v_from_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Source account % is not active (status=%)', p_from_account, v_from_status;
    END IF;

    IF v_from_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds in account %: balance % < amount %',
            p_from_account, v_from_balance, p_amount;
    END IF;

    UPDATE banking_db.accounts SET balance = balance - p_amount WHERE account_id = p_from_account;
    UPDATE banking_db.accounts SET balance = balance + p_amount WHERE account_id = p_to_account;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Destination account % does not exist', p_to_account;
    END IF;

    INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_from_account, 'TRANSFER_OUT', p_amount, p_to_account, 'Procedure transfer'),
           (p_to_account,   'TRANSFER_IN',  p_amount, p_from_account, 'Procedure transfer');

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE NOTICE 'Transfer failed: % (SQLSTATE %)', SQLERRM, SQLSTATE;
        RAISE;
END;
$$;

CALL banking_db.transfer_funds(1, 3, 10000.00);
```

**Why it works**: `SELECT ... FOR UPDATE` locks the source row for the
duration of the transaction so a concurrent transfer can't read a stale
balance and cause a lost update (a classic race condition in transfer logic).
Explicit checks (`FOUND`, status, balance) fail fast with clear messages
before any mutation happens. The `EXCEPTION WHEN OTHERS` block logs context
and re-raises (`RAISE;` with no arguments re-raises the caught exception)
rather than swallowing the error silently, and the surrounding `COMMIT`/
implicit rollback-on-exception in a procedure lets each call be its own
atomic unit of work.

**Why it works (transaction semantics)**: Since this is a `PROCEDURE`, an
unhandled exception automatically rolls back everything since the last
commit within this `CALL`; the explicit `EXCEPTION` block here exists purely
to add logging before that rollback happens (PostgreSQL still rolls back
even without an exception handler — the handler only lets you observe and
customize the failure).

**Alternative approaches**: Application-layer transfer logic (read balance
in app code, check, then issue two updates) duplicates this logic outside the
database and is far more prone to race conditions unless the application also
uses row locking correctly — encapsulating it in one procedure guarantees the
same locking discipline every time it's called, from any client.

**Performance considerations**: `FOR UPDATE` briefly blocks other
transactions trying to lock the same account row — acceptable for a
per-account bottleneck, but under very high contention on a small number of
"hot" accounts, consider `FOR UPDATE ... NOWAIT` or `SKIP LOCKED` semantics
if the business logic allows deferring rather than blocking.

**Common mistakes**:
> - Reading the balance without `FOR UPDATE`, allowing two concurrent
>   transfers to both read the same starting balance and overdraw the
>   account (a lost-update race condition).
> - Swallowing the exception (`WHEN OTHERS THEN NULL;`) instead of
>   re-raising — this hides real failures from the caller, who thinks the
>   transfer succeeded.

---

### Q35. How do you handle a *specific* error condition (e.g., a check constraint violation) differently from a generic error in PL/pgSQL?

**Answer**: Catch specific exception classes by name rather than a blanket
`WHEN OTHERS`.

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.open_account(
    p_customer_id INT, p_account_type VARCHAR, p_initial_balance NUMERIC
)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO banking_db.accounts (customer_id, account_type, balance, opened_date)
    VALUES (p_customer_id, p_account_type, p_initial_balance, CURRENT_DATE);
    COMMIT;
EXCEPTION
    WHEN check_violation THEN
        RAISE EXCEPTION 'Invalid account data: % (check constraint failed)', SQLERRM;
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Customer % does not exist', p_customer_id;
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Duplicate account entry: %', SQLERRM;
    WHEN OTHERS THEN
        RAISE NOTICE 'Unexpected error opening account: % (%)', SQLERRM, SQLSTATE;
        RAISE;
END;
$$;
```

**Why it works**: PostgreSQL exposes named exception conditions
(`check_violation`, `unique_violation`, `foreign_key_violation`,
`not_null_violation`, etc.) mapped to specific SQLSTATE codes
(`23514`, `23505`, `23503`, `23502`); catching the specific condition lets you
give the caller a precise, actionable message instead of a generic failure,
while still falling through to `WHEN OTHERS` as a catch-all safety net for
anything unanticipated.

**Alternative approaches**: Catching by raw `SQLSTATE` code
(`WHEN SQLSTATE '23505' THEN ...`) is equivalent and useful when there's no
named condition alias for a code you care about (e.g., certain
extension-specific error codes).

**Performance considerations**: Exception handling blocks in PL/pgSQL create
an implicit subtransaction (savepoint) — cheap for occasional error paths,
but wrapping a *tight loop's body* in its own exception handler per iteration
adds meaningful overhead; prefer catching around the loop rather than inside
it when the exception is rare.

**Common mistakes**:
> - Using only `WHEN OTHERS` everywhere, discarding the ability to give
>   callers specific, useful error messages.
> - Wrapping every single statement in its own `BEGIN...EXCEPTION...END`
>   block "just in case," creating excessive subtransaction overhead.

---

### Q36. Write a procedure that processes a batch of pending `ecommerce_db.orders`, committing progress every 100 rows, and explain why that matters.

**Answer**:

```plpgsql
CREATE OR REPLACE PROCEDURE ecommerce_db.mark_shipped_batch()
LANGUAGE plpgsql AS $$
DECLARE
    v_order_id INT;
    v_count    INT := 0;
BEGIN
    FOR v_order_id IN
        SELECT order_id FROM ecommerce_db.orders WHERE status = 'PAID'
    LOOP
        UPDATE ecommerce_db.orders SET status = 'SHIPPED' WHERE order_id = v_order_id;
        v_count := v_count + 1;

        IF v_count % 100 = 0 THEN
            COMMIT;
            RAISE NOTICE 'Committed % rows so far', v_count;
        END IF;
    END LOOP;

    COMMIT; -- final partial batch
    RAISE NOTICE 'Done. % orders marked shipped.', v_count;
END;
$$;

CALL ecommerce_db.mark_shipped_batch();
```

**Why it works**: Committing every 100 rows bounds the size of any single
transaction's lock footprint and undo/WAL volume — if the process is killed
partway through a run of 10 million rows, only the current uncommitted batch
is lost/rolled back, not the entire multi-hour job. A `CALL`-invoked
procedure is the only place `COMMIT` inside a loop is legal in PL/pgSQL.

**Alternative approaches**: A single-transaction `UPDATE ... WHERE status =
'PAID'` (set-based, no loop) is *far* more efficient for this specific case
since there's no per-row dependency — the batched-commit loop only becomes
necessary when each row requires independent, non-batchable logic (e.g.,
calling an external API per row, or when you deliberately want incremental
visibility/resumability for a very large, long-running job).

**Performance considerations**: Row-by-row procedural loops are dramatically
slower than an equivalent set-based `UPDATE` for anything that *can* be
expressed set-based — this batching pattern is a tool for genuinely
row-dependent or extremely large jobs, not a default habit for bulk updates.

**Common mistakes**:
> - Reaching for a row-by-row loop with periodic commits when a plain
>   set-based `UPDATE` would do the same job in one statement, orders of
>   magnitude faster.
> - Not handling a crash mid-batch — since committed batches are permanent,
>   the procedure should be idempotent/resumable (e.g., re-querying `WHERE
>   status = 'PAID'` naturally skips already-updated rows on retry, as
>   written above).

---

### Q37. What's the difference between `RAISE EXCEPTION`, `RAISE WARNING`, and `RAISE NOTICE` in PL/pgSQL?

**Answer**: They differ in severity and whether they abort execution.
`RAISE EXCEPTION` raises an error, aborts the current
transaction/subtransaction, and propagates to the caller unless caught.
`RAISE WARNING` logs a warning message to the client/log but execution
continues normally. `RAISE NOTICE` is purely informational, typically
suppressed at higher log levels in production, and also does not stop
execution.

```plpgsql
DO $$
BEGIN
    RAISE NOTICE 'Starting reconciliation for %', CURRENT_DATE;
    IF (SELECT COUNT(*) FROM banking_db.accounts WHERE balance < 0) > 0 THEN
        RAISE WARNING 'Found accounts with negative balance — check constraint bypass?';
    END IF;
    RAISE EXCEPTION 'Reconciliation aborted: manual example';
END;
$$;
```

**Why it works**: Each severity level maps to a distinct PostgreSQL log
level (`NOTICE`, `WARNING`, `ERROR`) with different default visibility
(`client_min_messages`) and different transactional consequences — only
`EXCEPTION` triggers PL/pgSQL's error/rollback machinery.

**Alternative approaches**: `RAISE LOG` and `RAISE DEBUG` exist too, aimed at
server-log-only diagnostics rather than client visibility, useful for tracing
procedure internals without cluttering client output.

**Performance considerations**: `RAISE NOTICE`/`DEBUG` calls inside a
hot, tight loop (millions of iterations) add measurable overhead purely from
message formatting/log routing — strip or guard them behind a debug flag in
production batch procedures.

**Common mistakes**:
> - Using `RAISE NOTICE` where an actual error should stop execution — the
>   caller won't know anything went wrong.
> - Forgetting that `RAISE EXCEPTION` rolls back the *entire* transaction
>   (not just the current statement) unless caught inside a subtransaction
>   (a `BEGIN...EXCEPTION...END` block, which PL/pgSQL implements via
>   savepoints).

---

### Q38. What is `SECURITY DEFINER` on a function/procedure, and what risk does it introduce?

**Answer**: `SECURITY DEFINER` makes a function/procedure execute with the
*privileges of the user who defined it*, rather than the caller's privileges
(`SECURITY INVOKER`, the default). This is how you let a low-privilege role
perform a narrowly-scoped elevated action without granting broad table
access.

```sql
CREATE OR REPLACE FUNCTION company_db.promote_employee(p_emp_id INT, p_new_title VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = company_db, pg_temp
AS $$
BEGIN
    UPDATE employees SET job_title = p_new_title WHERE employee_id = p_emp_id;
END;
$$;

REVOKE ALL ON FUNCTION company_db.promote_employee FROM PUBLIC;
GRANT EXECUTE ON FUNCTION company_db.promote_employee TO hr_app_role;
```

`hr_app_role` can execute this specific, narrow update without ever holding
`UPDATE` privilege on `employees` directly.

**Why it works**: The function runs as its *owner* (presumably a role with
full rights on `employees`), so the caller only needs `EXECUTE` on the
function itself — this is the standard pattern for exposing a controlled,
auditable write path.

**Alternative approaches**: `SECURITY INVOKER` (default) requires the caller
to already have the needed table privileges directly — simpler to reason
about but doesn't support this "narrow elevated capability" pattern.

**Performance considerations**: No runtime cost difference — this is purely
a privilege-model decision.

**Common mistakes**:
> - **⚠️ Warning**: Omitting `SET search_path = ...` on a `SECURITY
>   DEFINER` function is a classic privilege-escalation vector — a malicious
>   caller could create an object (e.g., a function or table) earlier in
>   their own search path that shadows an unqualified name the definer
>   function references, causing it to execute attacker-controlled code with
>   the definer's elevated privileges. Always pin `search_path` explicitly on
>   `SECURITY DEFINER` routines.
> - Granting `EXECUTE` to `PUBLIC` by default (PostgreSQL does this
>   automatically for new functions) without explicitly `REVOKE`-ing it
>   first on sensitive `SECURITY DEFINER` routines.

---

### Q39. How do `OUT` and `INOUT` parameters work in a procedure, and when would you use them instead of a return value?

**Answer**: `OUT` parameters let a procedure/function return multiple named
values without an explicit `RETURN`; `INOUT` parameters both accept an input
and are overwritten with an output value, letting `CALL` report results back
into session variables/host variables.

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.apply_interest(
    INOUT p_account_id INT,
    OUT   p_old_balance NUMERIC,
    OUT   p_new_balance NUMERIC,
    IN    p_rate NUMERIC DEFAULT 0.03
)
LANGUAGE plpgsql AS $$
BEGIN
    SELECT balance INTO p_old_balance FROM banking_db.accounts WHERE account_id = p_account_id;
    UPDATE banking_db.accounts
    SET balance = balance * (1 + p_rate)
    WHERE account_id = p_account_id
    RETURNING balance INTO p_new_balance;
    COMMIT;
END;
$$;

CALL banking_db.apply_interest(4, NULL, NULL, 0.05);
-- returns a result row: p_account_id | p_old_balance | p_new_balance
```

**Why it works**: `CALL` returns a result set containing the final values of
all `OUT`/`INOUT` parameters after execution — this is how a `CALL`
statement (which isn't a `SELECT`) can still hand data back to the client.

**Alternative approaches**: A function returning a composite type or `TABLE
(...)` achieves a similar "multiple named outputs" result and can be
embedded in a `SELECT`, which a procedure cannot — prefer a function unless
you specifically need transaction control inside the routine.

**Performance considerations**: Negligible difference; this is purely an API
ergonomics decision (multiple named outputs vs. a single composite/record
return).

**Common mistakes**:
> - Forgetting that `CALL`'s `OUT`/`INOUT` arguments must be passed
>   positionally as placeholders (`NULL` in the example) from most client
>   drivers/plain SQL — trying to read them as if `CALL` were a function call
>   inside a `SELECT` doesn't work the same way across all clients.
> - Not realizing `INOUT` parameters can't be reused to "communicate" a value
>   back into a variable in every client interface uniformly — check your
>   specific driver's `CALL` support.

---

### Q40. **[MySQL note]** How does MySQL's stored procedure error handling (`DECLARE ... HANDLER`) differ from PostgreSQL's `EXCEPTION` blocks?

**Answer**: MySQL uses `DECLARE handler_type HANDLER FOR condition_value
statement;` declared up front in the procedure body, where `handler_type` is
`CONTINUE` (resume after the handler) or `EXIT` (leave the current block).
PostgreSQL uses a `BEGIN ... EXCEPTION WHEN condition THEN ... END;` block
structured around the code that might fail, always behaving like an "exit"
handler for that block (there's no PostgreSQL equivalent of a bare `CONTINUE`
handler that lets you resume the exact next statement after the failing one).

```sql
-- MySQL
DELIMITER //
CREATE PROCEDURE safe_insert_customer(IN p_email VARCHAR(150))
BEGIN
    DECLARE EXIT HANDLER FOR 1062  -- duplicate key
        BEGIN
            SELECT 'Duplicate email, skipping' AS message;
        END;
    INSERT INTO customers (email) VALUES (p_email);
END //
DELIMITER ;
```

```plpgsql
-- PostgreSQL equivalent
CREATE OR REPLACE PROCEDURE safe_insert_customer(p_email VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO banking_db.customers (first_name, last_name, email, dob)
    VALUES ('Unknown', 'Unknown', p_email, '2000-01-01');
EXCEPTION
    WHEN unique_violation THEN
        RAISE NOTICE 'Duplicate email, skipping';
END;
$$;
```

**Why it works**: Both mechanisms map a specific error class (duplicate key
in both examples) to explicit recovery logic rather than letting the whole
procedure abort, but MySQL's handler-declaration model is more flexible about
*resuming* execution (`CONTINUE`) at the statement after the one that failed,
while PostgreSQL's block-scoped model always unwinds to the enclosing
`BEGIN...EXCEPTION` boundary.

**Alternative approaches**: In PostgreSQL, to approximate "continue after a
specific failing statement," wrap just that one statement in its own nested
`BEGIN...EXCEPTION...END` block so control returns to the code immediately
following it.

**Performance considerations**: Equivalent in practice — both mechanisms use
similar underlying savepoint/rollback machinery.

**Common mistakes**:
> - Assuming PostgreSQL's `WHEN OTHERS` behaves like a MySQL `CONTINUE
>   HANDLER FOR SQLEXCEPTION` that resumes at the very next statement outside
>   any block — it doesn't; it resumes at the code following the
>   `EXCEPTION` block's enclosing `BEGIN`.
> - Porting MySQL error-code numbers (`1062`) directly into PostgreSQL code
>   expecting them to mean the same thing — PostgreSQL uses SQLSTATE strings
>   and named conditions instead.

---

## 6. Functions & Volatility

PostgreSQL classifies every function by *volatility* — `IMMUTABLE`,
`STABLE`, or `VOLATILE` — and the planner uses that classification to decide
whether a function's result can be cached, reused across rows, or used in an
index expression. Getting volatility wrong is a common source of subtle bugs
and missed optimizations.

### Q41. Explain the three volatility categories and give one example function in each.

**Answer**:
- **`IMMUTABLE`**: guaranteed to return the same output for the same input
  arguments, forever, with no dependency on database state (e.g., `LOWER(text)`,
  simple arithmetic). Safe to precompute, cache, or use in an expression index.
- **`STABLE`**: returns the same output for the same input *within a single
  scan/statement*, but can depend on database state that varies between
  statements (e.g., `now()` returns a constant value throughout one
  transaction/statement but differs between statements; most `SELECT`-only
  functions reading table data are `STABLE`).
- **`VOLATILE`** (the default if unspecified): may return a different result
  even for identical arguments within the same statement, or has side
  effects (e.g., `random()`, `nextval()`, any function performing
  `INSERT`/`UPDATE`/`DELETE`).

```sql
CREATE FUNCTION company_db.full_name(first VARCHAR, last VARCHAR)
RETURNS VARCHAR LANGUAGE sql IMMUTABLE AS $$
    SELECT first || ' ' || last;
$$;

CREATE FUNCTION company_db.current_employee_count()
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT COUNT(*) FROM company_db.employees WHERE status = 'ACTIVE';
$$;

CREATE FUNCTION company_db.log_login(p_emp_id INT)
RETURNS VOID LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    INSERT INTO company_db.attendance (employee_id, work_date, status)
    VALUES (p_emp_id, CURRENT_DATE, 'PRESENT')
    ON CONFLICT (employee_id, work_date) DO NOTHING;
END;
$$;
```

**Why it works**: The planner uses volatility to decide how many times it's
safe to *call* a function while evaluating a query — an `IMMUTABLE` function
call on a constant argument can be folded to a constant at plan time; a
`STABLE` function can be called once per statement and its result reused
across rows in the same scan; a `VOLATILE` function must be called
separately for every single row, since its result might differ each time.

**Alternative approaches**: When in doubt, `VOLATILE` (the default) is always
*safe* — it just forgoes optimization opportunities. Never mark something
`IMMUTABLE` "to make it faster" if it isn't actually deterministic — this
causes correctness bugs, not just missed optimizations (see Q43).

**Performance considerations**: Marking a genuinely deterministic function
`IMMUTABLE` lets it participate in expression indexes (Q15) and lets the
planner constant-fold or hoist it out of a loop — a real, sometimes large,
performance win for expensive pure functions called repeatedly with the same
arguments.

**Common mistakes**:
> - Leaving every function at the `VOLATILE` default out of habit, missing
>   real optimization opportunities for genuinely pure functions.
> - Confusing "the function only ever reads data" with "immutable" — reading
>   table data that can change between calls makes a function `STABLE` at
>   best, never `IMMUTABLE`.

---

### Q42. Why is marking a function `IMMUTABLE` when it isn't actually deterministic dangerous — specifically for indexing?

**Answer**: If you build an expression index on an `IMMUTABLE` function and
the function's output for a given input later changes (because it wasn't
really immutable — e.g., it depended on a timezone setting, locale, or a
lookup table), the index silently becomes wrong: it still contains the *old*
computed values, but new rows are indexed with a (possibly different)
"immutable" result, and old rows never get their index entries refreshed
because the planner assumes the mapping can never change.

```sql
-- WRONG: this depends on the session's timezone setting, so it isn't
-- actually immutable across different timezone configurations.
CREATE FUNCTION bad_local_date(ts TIMESTAMPTZ)
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$
    SELECT ts::date;  -- ::date cast is timezone-dependent!
$$;

CREATE INDEX idx_bad ON banking_db.transactions (bad_local_date(transaction_date));
-- Correct results only as long as every session's timezone matches
-- whatever timezone was active when each row was indexed.
```

**Why it works (the danger)**: PostgreSQL trusts your `IMMUTABLE` label
without verifying it — there's no runtime check. Once the index is built
using that trust, query results silently diverge from what a fresh,
non-indexed evaluation of the same expression would produce, and this kind of
bug can go unnoticed for a long time because it looks like correct data most
of the time (only edge cases at timezone/locale boundaries misbehave).

**Alternative approaches**: Mark the function `STABLE` (correct, since it
depends on session configuration, not just its arguments) and accept that it
can't be used in an expression index; if you need indexed date-bucketing,
convert timestamps to a fixed timezone explicitly and deterministically
(`ts AT TIME ZONE 'UTC'`) before treating the result as immutable.

**Performance considerations**: The (illegitimate) performance gain from a
mislabeled `IMMUTABLE` function is not worth the correctness risk — data
corruption discovered later is far more expensive to fix than accepting a
slower, correct `STABLE` function.

**Common mistakes**:
> - Marking any function touching `now()`, `CURRENT_DATE`, session settings
>   (`timezone`, locale collation), or table lookups as `IMMUTABLE`.
> - Assuming PostgreSQL will catch a mislabeled volatility category —
>   it explicitly does not validate this; it's an unenforced contract you
>   are making with the planner.

---

### Q43. Write a `STABLE` SQL function that returns a customer's total loan exposure from `banking_db`, and explain why `STABLE` (not `VOLATILE`) is correct here.

**Answer**:

```sql
CREATE OR REPLACE FUNCTION banking_db.total_loan_exposure(p_customer_id INT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(loan_amount), 0)
    FROM banking_db.loans
    WHERE customer_id = p_customer_id AND status = 'ACTIVE';
$$;

SELECT customer_id, banking_db.total_loan_exposure(customer_id) AS exposure
FROM banking_db.customers;
```

For `customer_id = 3` (Suresh Menon), this returns `1200000.00` (his one
active loan; `customer_id = 2`'s loan is `'CLOSED'` and excluded).

**Why it works**: The function only reads data via `SELECT` and never
modifies anything, and for a fixed argument its result cannot change *within*
a single statement/scan (even though it could change *between* separate
statements, if a loan's status is updated concurrently) — that's exactly the
definition of `STABLE`. Declaring it `STABLE` lets the planner call it once
per row rather than being forced to treat it with the extra caution
`VOLATILE` implies (e.g., it can be safely used in a `WHERE` clause and
evaluated only as many times as necessary, and it's eligible to be used in
generated columns and certain index-related contexts `VOLATILE` functions
cannot participate in).

**Alternative approaches**: Marking it `VOLATILE` would still produce correct
results — it's a strictly more conservative label — but forgoes the
optimizer's ability to treat repeated calls with the same argument within one
query as consistent, and disallows using it in contexts that require at
least `STABLE` (e.g., some index-related and generated-column usages).

**Performance considerations**: A `STABLE` label is a real signal to the
planner but not a magic cache — repeated calls with different `customer_id`
arguments across different rows are still evaluated separately; `STABLE`
mainly matters for **the same call with the same arguments appearing multiple
times within one query plan** and for eligibility in generated-column/
index-adjacent contexts.

**Common mistakes**:
> - Marking it `IMMUTABLE` because "the SQL never changes" — the *result*
>   changes over time as loan data changes, so `IMMUTABLE` would be
>   incorrect even though the function body is static.
> - Forgetting `COALESCE(..., 0)` and returning `NULL` for customers with no
>   active loans, which then breaks arithmetic/sorting on the result
>   elsewhere.

---

### Q44. Write a set-returning function (`RETURNS TABLE`) that lists all direct reports of a given manager in `company_db`.

**Answer**:

```sql
CREATE OR REPLACE FUNCTION company_db.direct_reports(p_manager_id INT)
RETURNS TABLE (employee_id INT, full_name TEXT, job_title VARCHAR)
LANGUAGE sql
STABLE
AS $$
    SELECT employee_id, first_name || ' ' || last_name, job_title
    FROM company_db.employees
    WHERE manager_id = p_manager_id
    ORDER BY employee_id;
$$;

SELECT * FROM company_db.direct_reports(2);
```

For `p_manager_id = 2` (Rahul Mehta), this returns the four employees whose
`manager_id = 2`: Sneha Kulkarni (3), Vikram Joshi (4), Ananya Singh (5), and
Aman Chawla (16). (Karan Verma, employee 6, reports to Sneha — `manager_id =
3` — not directly to Rahul, so he's correctly excluded.)

**Why it works**: `RETURNS TABLE (...)` lets a function be queried exactly
like a table/view in the `FROM` clause (`SELECT * FROM
direct_reports(2)`), supporting further filtering, joining, and column
selection by the caller — unlike a scalar function, it can return an
arbitrary number of rows with a named, typed column set.

**Alternative approaches**: `RETURNS SETOF employees` returns the full row
shape of the `employees` table directly, useful when you want all columns
without redefining a custom output shape; `RETURNS TABLE` is preferable when
you want a curated, function-specific projection (as done here, computing
`full_name`).

**Performance considerations**: `LANGUAGE sql` set-returning functions can be
inlined by the planner when used simply (a real performance advantage over
`LANGUAGE plpgsql`, which is always executed as an opaque black box the
planner can't see inside or optimize jointly with the surrounding query).

**Common mistakes**:
> - Reflexively using `plpgsql` for a simple single-`SELECT` function, losing
>   the inlining opportunity `LANGUAGE sql` provides for trivial cases.
> - Not adding `ORDER BY` inside the function and assuming row order is
>   stable across calls.

---

### Q45. What is function overloading in PostgreSQL, and what ambiguity risk does it introduce?

**Answer**: PostgreSQL allows multiple functions with the same name but
different parameter types/counts (overloads), resolved at call time by
matching argument types.

```sql
CREATE FUNCTION company_db.bonus_pct(p_salary NUMERIC) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$ SELECT p_salary * 0.10; $$;

CREATE FUNCTION company_db.bonus_pct(p_salary NUMERIC, p_pct NUMERIC) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$ SELECT p_salary * p_pct; $$;

SELECT company_db.bonus_pct(500000);        -- resolves to the 1-arg version
SELECT company_db.bonus_pct(500000, 0.15);  -- resolves to the 2-arg version
```

**Why it works**: PostgreSQL's function resolution algorithm matches the
number and types of arguments provided against all functions sharing that
name, preferring exact type matches, then implicit-cast-compatible matches;
when a call is genuinely ambiguous (e.g., two overloads both reachable via
equally-plausible implicit casts, such as passing an untyped `NULL` or a
numeric literal that could bind to more than one candidate), PostgreSQL
raises `ERROR: function ... is not unique` rather than guessing.

**Alternative approaches**: Named/default parameters (`CREATE FUNCTION
bonus_pct(p_salary NUMERIC, p_pct NUMERIC DEFAULT 0.10)`) achieve the same
"optional second argument" convenience as two separate overloads, without
introducing multiple catalog entries to keep in sync.

**Performance considerations**: Overload resolution happens once at parse
time per call site, not per row — no runtime cost difference versus a single
function.

**Common mistakes**:
> - Passing an untyped `NULL` literal to an overloaded function and getting
>   an "ambiguous function call" error, because PostgreSQL can't determine
>   which overload's parameter type the `NULL` should bind to — fix by
>   casting (`NULL::numeric`).
> - Maintaining near-duplicate logic across overloads instead of using
>   `DEFAULT` parameters, causing drift when one copy is updated and the
>   other isn't.

---

### Q46. What is the difference between `LANGUAGE sql` and `LANGUAGE plpgsql` functions, and when would you choose each?

**Answer**: `LANGUAGE sql` functions contain one or more plain SQL statements
with no procedural control flow (no `IF`, loops, or local variables) — the
last statement's result becomes the return value. `LANGUAGE plpgsql`
functions support full procedural logic: variables, conditionals, loops,
exception handling, dynamic SQL.

```sql
-- LANGUAGE sql: simple, single-expression, inlinable
CREATE FUNCTION ecommerce_db.order_total(p_order_id INT) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT SUM(quantity * unit_price) FROM ecommerce_db.order_items WHERE order_id = p_order_id;
$$;

-- LANGUAGE plpgsql: needs branching logic
CREATE FUNCTION ecommerce_db.order_status_label(p_order_id INT) RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_status VARCHAR;
BEGIN
    SELECT status INTO v_status FROM ecommerce_db.orders WHERE order_id = p_order_id;
    IF v_status IS NULL THEN
        RETURN 'UNKNOWN ORDER';
    ELSIF v_status = 'DELIVERED' THEN
        RETURN 'Complete';
    ELSE
        RETURN 'In progress: ' || v_status;
    END IF;
END;
$$;
```

**Why it works**: `LANGUAGE sql` functions map directly onto SQL's
expression-oriented model, which is why simple ones are eligible for planner
inlining (the function body gets substituted directly into the calling
query, as if you'd written the subquery yourself — see Q44); `plpgsql` gives
up inlining in exchange for full procedural expressiveness.

**Alternative approaches**: For anything requiring conditional logic, loops,
exception handling, or multiple statements with intermediate variables,
`plpgsql` is required — `sql` functions cannot express branching.

**Performance considerations**: Prefer `LANGUAGE sql` whenever the logic is a
single query — it can be inlined and jointly optimized with the caller's
query (better plans, e.g., predicate pushdown into the function body);
`plpgsql` functions are opaque to the planner and always execute as a
separate, uninlined call per invocation.

**Common mistakes**:
> - Defaulting to `plpgsql` for everything out of familiarity, even for
>   simple single-statement functions that would benefit from `sql`
>   inlining.
> - Forgetting `STABLE`/`IMMUTABLE` on `LANGUAGE sql` functions — inlining
>   eligibility and volatility are separate settings that both need to be
>   set correctly.

---

### Q47. What's a trade-off of using `PARALLEL SAFE` on a function, and how do you know if your function qualifies?

**Answer**: `PARALLEL SAFE` tells the planner this function can be safely
executed by parallel worker processes (each with their own independent
backend state) as part of a parallel query plan. A function qualifies only if
it doesn't access changing session/transaction state in a way that breaks
under multiple concurrent workers, doesn't write to the database, and doesn't
use certain unsafe constructs (e.g., sequences via `nextval()` in a way that
depends on order, temp tables tied to backend-local state in a conflicting
way, cursors shared across workers).

```sql
CREATE OR REPLACE FUNCTION company_db.tax_bracket(p_salary NUMERIC)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN p_salary < 200000 THEN 'LOW'
        WHEN p_salary < 400000 THEN 'MID'
        ELSE 'HIGH'
    END;
$$;
```

**Why it works**: Pure computation with no database access and no shared
mutable state is trivially safe to run concurrently across parallel workers
each evaluating it for a different row subset — marking it `PARALLEL SAFE`
lets the planner include this function in a parallel sequential/aggregate
scan plan instead of forcing a serial (single-worker) plan just because an
unsafe function might be present somewhere in the query.

**Alternative approaches**: The conservative default is `PARALLEL UNSAFE`
(forces serial execution of any plan node calling this function) —
appropriate for functions with side effects or session-state dependencies
that would misbehave if run by multiple workers concurrently. `PARALLEL
RESTRICTED` sits in between: safe in parallel workers, but not safe to run in
the *leader* process during parallel execution — mainly relevant for
functions using certain shared, non-reentrant resources.

**Performance considerations**: On large aggregate queries over big tables,
`PARALLEL SAFE` on functions used in the `WHERE`/`SELECT` list can be the
difference between a single-worker sequential scan and an 4-8x-faster
parallel sequential scan, if `max_parallel_workers_per_gather` allows it.

**Common mistakes**:
> - Marking a function `PARALLEL SAFE` when it writes data or reads
>   backend-local session state incorrectly assumed to be shared — this can
>   cause subtle, hard-to-reproduce bugs only under parallel execution.
> - Not marking genuinely safe, expensive functions as `PARALLEL SAFE`,
>   leaving easy parallel-query performance on the table.

---

## 7. Cursors

A cursor lets you fetch a result set one row (or one chunk) at a time inside
procedural code, instead of receiving the whole result set at once. They're
occasionally necessary, but interviewers at this tier are really testing
whether you know *why* they're usually the wrong first choice.

### Q48. What is a cursor, and why do experienced engineers avoid them by default?

**Answer**: A cursor is a server-side pointer into a query's result set that
lets procedural code (PL/pgSQL, application code via a client-side cursor, or
interactive `psql`) fetch rows incrementally rather than materializing the
entire result at once.

```plpgsql
DO $$
DECLARE
    cur CURSOR FOR SELECT employee_id, base_salary FROM company_db.salaries WHERE effective_date = '2022-01-01';
    r RECORD;
BEGIN
    OPEN cur;
    LOOP
        FETCH cur INTO r;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Employee % salary %', r.employee_id, r.base_salary;
    END LOOP;
    CLOSE cur;
END;
$$;
```

They're avoided by default because row-by-row procedural iteration in
PL/pgSQL is dramatically slower than an equivalent set-based query — each
`FETCH` is effectively a function call with its own overhead, and the
database's whole optimizer (join reordering, indexing strategy, parallelism)
is designed around processing *sets* of rows at once, not one row per
round-trip through procedural code.

**Why it works (when they're actually needed)**: Cursors earn their keep when
per-row logic genuinely can't be expressed set-based — e.g., calling an
external API per row, generating documents/files per row, or streaming a
huge result set to a client without loading it all into memory at once
(`DECLARE ... CURSOR` combined with repeated `FETCH n`).

**Alternative approaches**: For nearly everything that looks like "loop over
rows and do X," a set-based `UPDATE`/`INSERT ... SELECT`/window function
rewrite is faster and simpler (see Q49, Q50 for concrete side-by-side
comparisons).

**Performance considerations**: A cursor-driven loop over 10,000 rows in
PL/pgSQL can easily take 10-100x longer than the equivalent single
set-based statement, because each iteration pays PL/pgSQL interpreter
overhead and (for explicit cursors) a fetch round-trip, instead of the
engine processing the whole batch internally in compiled executor code.

**Common mistakes**:
> - Reaching for a cursor as the "obvious" way to process rows because
>   it mirrors imperative programming habits from application languages,
>   without first asking whether a set-based statement can do the same job.
> - Not closing cursors explicitly, leaking server-side resources in
>   long-running sessions (implicit cursors opened by `FOR ... IN SELECT
>   ... LOOP` in PL/pgSQL are auto-closed, but explicitly `OPEN`ed cursors
>   are not).

---

### Q49. Cursor vs. set-based: rewrite this cursor-based salary raise loop as a single set-based statement.

```plpgsql
-- Cursor-based (slow) version
DO $$
DECLARE
    cur CURSOR FOR SELECT employee_id FROM company_db.employees WHERE department_id = 1 AND status = 'ACTIVE';
    v_emp_id INT;
BEGIN
    OPEN cur;
    LOOP
        FETCH cur INTO v_emp_id;
        EXIT WHEN NOT FOUND;
        UPDATE company_db.salaries
        SET base_salary = base_salary * 1.10
        WHERE employee_id = v_emp_id AND effective_date = (
            SELECT MAX(effective_date) FROM company_db.salaries s2 WHERE s2.employee_id = v_emp_id
        );
    END LOOP;
    CLOSE cur;
END;
$$;
```

**Answer**:

```sql
UPDATE company_db.salaries s
SET base_salary = base_salary * 1.10
FROM (
    SELECT DISTINCT ON (employee_id) employee_id, effective_date
    FROM company_db.salaries
    ORDER BY employee_id, effective_date DESC
) latest
WHERE s.employee_id = latest.employee_id
  AND s.effective_date = latest.effective_date
  AND s.employee_id IN (
      SELECT employee_id FROM company_db.employees
      WHERE department_id = 1 AND status = 'ACTIVE'
  );
```

**Why it works**: The set-based version computes "latest salary row per
employee" once (via `DISTINCT ON`), joins it against the target employee set
once, and applies the raise to all qualifying rows in a single statement —
the engine handles the whole batch in one optimized pass instead of one
`UPDATE` execution per employee, each separately re-running its own
correlated `MAX(effective_date)` subquery.

**Alternative approaches**: A window-function CTE achieves the same "latest
row per employee" logic and may be more readable to engineers unfamiliar with
`DISTINCT ON`:
```sql
WITH latest AS (
    SELECT employee_id, effective_date,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) rn
    FROM company_db.salaries
)
UPDATE company_db.salaries s
SET base_salary = base_salary * 1.10
FROM latest
WHERE s.employee_id = latest.employee_id AND s.effective_date = latest.effective_date
  AND latest.rn = 1
  AND s.employee_id IN (SELECT employee_id FROM company_db.employees WHERE department_id = 1 AND status = 'ACTIVE');
```

**Performance considerations**: For Engineering's ~6 active employees this
difference is invisible; for a 500,000-employee table, the cursor version
issues 500,000 separate `UPDATE` statements each re-scanning `salaries` for
its own `MAX(effective_date)`, while the set-based version does one indexed
pass — a difference of minutes versus milliseconds.

**Common mistakes**:
> - Believing procedural per-row logic is "more correct" or "safer" than a
>   set-based statement — a well-constructed set-based `UPDATE` is equally
>   correct and, being one statement, is also easier to wrap in a single
>   transaction with clear atomicity.
> - Forgetting `DISTINCT ON` requires an `ORDER BY` starting with the same
>   columns as the `DISTINCT ON` list.

---

### Q50. Cursor vs. set-based: rewrite this per-row inventory reorder check as a set-based query.

```plpgsql
-- Cursor-based
DO $$
DECLARE
    cur CURSOR FOR SELECT product_id, warehouse_location, quantity_on_hand, reorder_level FROM ecommerce_db.inventory;
    r RECORD;
BEGIN
    OPEN cur;
    LOOP
        FETCH cur INTO r;
        EXIT WHEN NOT FOUND;
        IF r.quantity_on_hand < r.reorder_level THEN
            RAISE NOTICE 'Reorder needed: product % at %', r.product_id, r.warehouse_location;
        END IF;
    END LOOP;
    CLOSE cur;
END;
$$;
```

**Answer**:

```sql
SELECT product_id, warehouse_location, quantity_on_hand, reorder_level
FROM ecommerce_db.inventory
WHERE quantity_on_hand < reorder_level;
```

Against the seed data, this returns product 4 (`GameBook 15`, Pune-WH1, 3 on
hand vs. reorder level 5) and product 9 (`Wireless Earbuds`, Mumbai-WH1, 0 on
hand vs. reorder level 25).

**Why it works**: The condition being checked (`quantity_on_hand <
reorder_level`) is a pure per-row predicate with no cross-row dependency —
exactly the case a plain `WHERE` clause is built for. There is no reason to
materialize a cursor, fetch rows one at a time, and evaluate the condition in
procedural code when the relational engine can evaluate the same predicate
against every row directly, using an index if one exists.

**Alternative approaches**: If the goal is actually to *act* on each
low-stock row (e.g., insert a reorder request per row), an `INSERT INTO
reorder_requests (...) SELECT ... FROM inventory WHERE quantity_on_hand <
reorder_level` remains fully set-based — still no cursor needed, since
"insert one row per matching row" is exactly what `INSERT ... SELECT` does
natively.

**Performance considerations**: On a 10-row table the difference is
unmeasurable; on a 10-million-row inventory table, the set-based `WHERE`
clause can use an index on `(warehouse_location)` or a computed comparison
efficiently, while the cursor version pays PL/pgSQL loop overhead for every
single row scanned, whether or not it matches.

**Common mistakes**:
> - Using a cursor merely to *evaluate a condition per row and print/log it*
>   — this is precisely what `WHERE` plus a reporting query (or an
>   `INSERT ... SELECT` for follow-on action) already does, with the engine
>   doing the iteration internally and efficiently.
> - Assuming a cursor is required whenever the phrase "for each row" appears
>   in a requirement — most "for each row" requirements translate directly
>   to a `WHERE`/`JOIN`/`INSERT...SELECT`, not procedural iteration.

---

### Q51. Write a PL/pgSQL cursor that legitimately needs row-by-row processing: generating a formatted statement string per customer account.

**Answer**:

```plpgsql
CREATE OR REPLACE FUNCTION banking_db.generate_statements()
RETURNS TABLE(account_id INT, statement_text TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    cur CURSOR FOR
        SELECT a.account_id, a.account_type, a.balance, c.first_name, c.last_name
        FROM banking_db.accounts a
        JOIN banking_db.customers c ON c.customer_id = a.customer_id
        WHERE a.status = 'ACTIVE'
        ORDER BY a.account_id;
    r RECORD;
    v_txn_count INT;
BEGIN
    OPEN cur;
    LOOP
        FETCH cur INTO r;
        EXIT WHEN NOT FOUND;

        SELECT COUNT(*) INTO v_txn_count
        FROM banking_db.transactions
        WHERE account_id = r.account_id
          AND transaction_date >= date_trunc('month', CURRENT_DATE);

        account_id := r.account_id;
        statement_text := format(
            'Statement for %s %s — Account #%s (%s): Balance ₹%s, %s transaction(s) this month.',
            r.first_name, r.last_name, r.account_id, r.account_type, r.balance, v_txn_count
        );
        RETURN NEXT;
    END LOOP;
    CLOSE cur;
END;
$$;

SELECT * FROM banking_db.generate_statements();
```

**Why it works**: Each row requires an *independent*, differently-parameterized
follow-up query (this month's transaction count for *that specific*
account) combined with per-row string formatting — while this particular
example could actually still be set-based (see below), it illustrates the
legitimate cursor pattern of "fetch a row, do meaningfully distinct
procedural work with it, emit a result, repeat," useful as a stepping stone
toward cases with true row-dependent branching or external-system calls that
truly cannot be expressed in one SQL statement.

**Alternative approaches**: This specific case actually can be flattened to a
set-based join with a correlated subquery or `LEFT JOIN LATERAL` for the
transaction count, keeping formatting in a single `SELECT` with `format()`
applied per row without a cursor at all — worth pointing out in an interview
that even "row-by-row string building" is often expressible set-based, and
cursors are best reserved for cases with genuine external side effects (API
calls, file generation) per row.

**Performance considerations**: If the true business need scales to
thousands of accounts, prefer the set-based `LATERAL` rewrite; reserve the
cursor pattern for when per-row work involves something SQL fundamentally
cannot do (calling an external service, writing to the filesystem).

**Common mistakes**:
> - Writing a "legitimate-looking" cursor example that is, on inspection,
>   still fully expressible set-based — always sanity-check whether the
>   per-row logic could be a `LATERAL` join or window function before
>   committing to procedural iteration.
> - Not closing the cursor (`CLOSE cur;`) before an early `RETURN`, leaking
>   the cursor for the remainder of the session.

---

### Q52. What does `FETCH ... FOR UPDATE` combined with `WHERE CURRENT OF` let you do, and what's the MySQL caveat?

**Answer**: `WHERE CURRENT OF cursor_name` lets you `UPDATE`/`DELETE` the
exact row the cursor is currently positioned on, without needing to
re-specify a `WHERE` clause matching that row by key.

```plpgsql
DO $$
DECLARE
    cur CURSOR FOR SELECT account_id, balance FROM banking_db.accounts WHERE status = 'ACTIVE' FOR UPDATE;
    r RECORD;
BEGIN
    OPEN cur;
    LOOP
        FETCH cur INTO r;
        EXIT WHEN NOT FOUND;
        IF r.balance > 100000 THEN
            UPDATE banking_db.accounts SET account_type = 'CURRENT'
            WHERE CURRENT OF cur;
        END IF;
    END LOOP;
    CLOSE cur;
END;
$$;
```

**Why it works**: The cursor was declared `FOR UPDATE`, which locks each
fetched row and lets PostgreSQL track exactly which physical row version the
cursor is positioned on; `WHERE CURRENT OF cur` then targets that exact row
directly rather than requiring you to re-express its primary key.

**⚠️ [MySQL dialect note]**: MySQL does **not** support `WHERE CURRENT OF`
at all — MySQL cursors are read-only positioning constructs used inside
stored procedures/functions purely for `FETCH`-based iteration; to update the
"current" row in MySQL you must issue a normal `UPDATE ... WHERE
<primary_key> = fetched_value` using values fetched from the cursor.

**Alternative approaches**: In both dialects, a set-based `UPDATE ... WHERE
balance > 100000 AND status = 'ACTIVE'` avoids the cursor and
`WHERE CURRENT OF` mechanism entirely, and is almost always preferable unless
per-row branching logic beyond a simple predicate is required.

**Performance considerations**: `WHERE CURRENT OF` avoids re-executing a
`WHERE`-clause key lookup per row (a minor optimization over re-specifying
the primary key), but the overall cursor-loop overhead versus a set-based
statement (Q48-50) still dominates for any non-trivial row count.

**Common mistakes**:
> - Writing `WHERE CURRENT OF` code intended to run on MySQL — it will fail
>   to parse; this pattern is PostgreSQL/Oracle/SQL Server-specific.
> - Forgetting `FOR UPDATE` on the cursor declaration — `WHERE CURRENT OF`
>   requires the cursor to be updatable, which requires row locking to be
>   requested up front.

---

### Q53. What is a `REFCURSOR`, and how does it differ from a plain cursor declared inside a PL/pgSQL block?

**Answer**: A `REFCURSOR` is a cursor *handle* (a name/reference) that can be
returned from a function or passed between transactions/calls, letting a
client application `FETCH` from a cursor opened on the server across separate
round trips, rather than the cursor being confined entirely to one PL/pgSQL
block's internal loop.

```sql
CREATE OR REPLACE FUNCTION ecommerce_db.get_orders_cursor(p_user_id INT)
RETURNS REFCURSOR
LANGUAGE plpgsql
AS $$
DECLARE
    ref REFCURSOR := 'orders_cursor';
BEGIN
    OPEN ref FOR
        SELECT order_id, order_date, status FROM ecommerce_db.orders WHERE user_id = p_user_id;
    RETURN ref;
END;
$$;

BEGIN;
SELECT ecommerce_db.get_orders_cursor(1);
FETCH 5 FROM orders_cursor;
FETCH 5 FROM orders_cursor;
COMMIT;
```

**Why it works**: `REFCURSOR` is just the `cursor` data type — the function
opens a portal on the server and hands back its name; the client can then
issue `FETCH` commands against that named portal directly, which is how many
client libraries/ORMs implement server-side streaming of large result sets
without loading everything into client memory at once.

**Alternative approaches**: A plain cursor declared and fully consumed
*within* a single PL/pgSQL block (as in Q48-51) never needs to be exposed to
the client — use `REFCURSOR` specifically when the *caller*, not the
function itself, needs to control the fetch pace/size across multiple round
trips.

**Performance considerations**: Server-side cursors (via `REFCURSOR` or a
client library's native cursor support) must stay open within a transaction
— a long-lived open cursor holds a snapshot and, in some isolation levels,
can prevent `VACUUM` from cleaning up dead tuples visible to that snapshot,
so streaming very large result sets this way trades memory savings for
extended transaction lifetime.

**Common mistakes**:
> - Trying to `FETCH` from a `REFCURSOR` outside the transaction in which it
>   was opened — cursors (other than `WITH HOLD` cursors) don't survive past
>   `COMMIT`.
> - Leaving a `REFCURSOR`-based transaction open indefinitely on the client
>   side, holding locks/snapshots far longer than intended.

---

## 8. Triggers

Triggers attach procedural logic to `INSERT`/`UPDATE`/`DELETE` events. They're
powerful for auditing, enforcing invariants a `CHECK` constraint can't
express, and denormalized-column maintenance — and easy to misuse into
invisible, hard-to-debug side effects.

### Q54. Write an audit trigger on `banking_db.accounts` that logs every `UPDATE` into `audit_log`.

**Answer**:

```plpgsql
CREATE OR REPLACE FUNCTION banking_db.fn_audit_accounts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO banking_db.audit_log (table_name, operation, row_pk, old_data, new_data)
    VALUES (
        'accounts',
        TG_OP,
        OLD.account_id::TEXT,
        to_jsonb(OLD),
        to_jsonb(NEW)
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_accounts
AFTER UPDATE ON banking_db.accounts
FOR EACH ROW
EXECUTE FUNCTION banking_db.fn_audit_accounts();
```

Running `UPDATE banking_db.accounts SET balance = balance - 5000 WHERE
account_id = 1;` now automatically inserts a row into `audit_log` capturing
the full before/after JSON of account 1.

**Why it works**: `AFTER UPDATE ... FOR EACH ROW` fires the trigger function
once per modified row, with `OLD` and `NEW` populated with the pre- and
post-update row images; `to_jsonb()` serializes the entire row into the
`jsonb` columns on `audit_log` without needing to enumerate columns by name,
so the audit trigger doesn't need to change when `accounts`' schema evolves
(mostly — see "Common mistakes").

**Alternative approaches**: A `BEFORE UPDATE` trigger could do the same
logging and additionally *modify* `NEW` before it's written (e.g., stamping a
`last_modified` column) — choose `AFTER` when you only need to observe/log,
`BEFORE` when you need to alter or validate the incoming row.

**Performance considerations**: Every `UPDATE` on `accounts` now does an
extra `INSERT` into `audit_log` — for a high-throughput table, this roughly
doubles write volume and WAL generation; consider whether column-level
change detection (only logging when specific columns actually changed, via
`IF OLD.balance IS DISTINCT FROM NEW.balance THEN ...`) would reduce
unnecessary audit rows.

**Common mistakes**:
> - Forgetting `RETURN NEW;` in an `AFTER` trigger function — while the
>   return value of an `AFTER` trigger is actually ignored by PostgreSQL, it's
>   still good practice to return consistently, and it's a **required**,
>   not optional, `RETURN NEW;` for `BEFORE`/`INSTEAD OF` triggers, where
>   omitting it (or returning `NULL`) silently cancels the operation.
> - Assuming `to_jsonb(OLD)` automatically tracks future column additions
>   perfectly for all downstream consumers — the *audit row* does, but any
>   code that later reads specific keys out of that `jsonb` blob still needs
>   to handle missing keys for older audit rows predating a schema change.

---

### Q55. Write a `BEFORE INSERT` trigger that prevents an `ecommerce_db.order_items` row from being inserted if it would oversell inventory.

**Answer**:

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.fn_check_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_available INT;
BEGIN
    SELECT COALESCE(SUM(quantity_on_hand), 0) INTO v_available
    FROM ecommerce_db.inventory
    WHERE product_id = NEW.product_id;

    IF v_available < NEW.quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product %: requested %, available %',
            NEW.product_id, NEW.quantity, v_available
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_inventory
BEFORE INSERT ON ecommerce_db.order_items
FOR EACH ROW
EXECUTE FUNCTION ecommerce_db.fn_check_inventory();
```

Attempting `INSERT INTO order_items (order_id, product_id, quantity,
unit_price) VALUES (7, 9, 100, 3499.00);` now fails, since `Wireless
Earbuds` (product 9) has `0` on hand.

**Why it works**: A `BEFORE INSERT` trigger runs before the row is written,
so raising an exception here aborts the insert entirely (and, being inside a
larger transaction, rolls back everything since the last savepoint/commit) —
this enforces an invariant (`sum of ordered quantity <= available inventory`)
that a simple `CHECK` constraint cannot express, because `CHECK` constraints
can't reference other tables.

**Alternative approaches**: A `CONSTRAINT TRIGGER` (deferrable) would let
this check run at the end of the transaction rather than immediately,
useful if inventory is decremented by a separate statement within the same
transaction and you don't want a false failure mid-transaction before the
decrement happens; alternatively, enforce this at the application layer with
optimistic locking — simpler to implement, but loses the guarantee that *no*
code path can bypass it.

**Performance considerations**: This adds a `SELECT SUM(...)` per inserted
row — fine for typical order volumes, but a high-throughput checkout system
inserting thousands of order_items per second would want this backed by an
index on `inventory.product_id` (already implied by its `UNIQUE
(product_id, warehouse_location)` constraint) and ideally batched validation
rather than strictly per-row triggers.

**Common mistakes**:
> - Forgetting `RETURN NEW;` for the success path — a `BEFORE` trigger that
>   falls through without an explicit `RETURN` for some code path silently
>   cancels the insert.
> - Not considering concurrent inserts racing on the same product's
>   inventory — the trigger's read-then-decide isn't itself safe against
>   concurrent overselling without additional locking (e.g., locking the
>   relevant `inventory` rows via `SELECT ... FOR UPDATE` inside the trigger).

---

### Q56. What's the difference between `BEFORE`, `AFTER`, and `INSTEAD OF` triggers, and when is each appropriate?

**Answer**: `BEFORE` triggers fire before the row is written and can modify
`NEW` or cancel the operation by returning `NULL`; `AFTER` triggers fire once
the row is already durably part of the operation (though still inside the
same transaction, so still rollback-able) and cannot alter what was written,
only react to it; `INSTEAD OF` triggers (view-only) replace the operation
entirely — the underlying `INSERT`/`UPDATE`/`DELETE` never happens unless the
trigger function itself performs it.

```sql
-- BEFORE: validate/modify incoming data
CREATE TRIGGER trg_validate_salary
BEFORE INSERT OR UPDATE ON company_db.salaries
FOR EACH ROW EXECUTE FUNCTION company_db.fn_validate_salary();

-- AFTER: react/log, can't change what was written
CREATE TRIGGER trg_audit_salary
AFTER INSERT OR UPDATE ON company_db.salaries
FOR EACH ROW EXECUTE FUNCTION company_db.fn_audit_salary();

-- INSTEAD OF: required for writes through a non-simply-updatable view
CREATE TRIGGER trg_insert_via_view
INSTEAD OF INSERT ON ecommerce_db.v_order_summary
FOR EACH ROW EXECUTE FUNCTION ecommerce_db.fn_insert_order_via_view();
```

**Why it works**: The three timings map directly onto three distinct needs:
mutate-or-reject before commit (`BEFORE`), observe-after-the-fact for
side effects like auditing or cache invalidation (`AFTER`), and
redirect-entirely for views that aren't automatically updatable
(`INSTEAD OF`, which only applies to views, not base tables).

**Alternative approaches**: Application-layer validation before issuing the
`INSERT`/`UPDATE` achieves similar protection to a `BEFORE` trigger but can be
bypassed by any code path that talks to the database directly (a script, a
different service, a manual `psql` session) — a `BEFORE` trigger enforces the
rule at the database boundary regardless of caller.

**Performance considerations**: `FOR EACH ROW` triggers add per-row overhead;
`FOR EACH STATEMENT` triggers (with `REFERENCING OLD TABLE/NEW TABLE AS ...`
for transition tables in PostgreSQL 10+) fire once per statement regardless
of row count, which is far cheaper for bulk operations that need aggregate,
not per-row, logic.

**Common mistakes**:
> - Using `AFTER` when you actually need to modify the incoming row —
>   `AFTER` triggers cannot change `NEW`'s effect on what was already
>   written.
> - Forgetting `INSTEAD OF` only applies to views — attempting it on a base
>   table raises an error.

---

### Q57. What is a mutating-table-style problem in PostgreSQL triggers, and how do you avoid infinite recursion when a trigger updates its own table?

**Answer**: If a trigger on table `T` performs an `UPDATE` on `T` itself
(directly, or indirectly via another trigger), it can re-fire the same
trigger, potentially recursing indefinitely (Oracle calls the direct version
of this restriction the "mutating table" error; PostgreSQL doesn't forbid it
outright but you must guard against runaway recursion yourself).

```plpgsql
CREATE OR REPLACE FUNCTION company_db.fn_stamp_updated()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Guard: only stamp if this column isn't already being set by this
    -- very trigger invocation, preventing a self-re-trigger loop.
    IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stamp_updated
BEFORE UPDATE ON company_db.employees
FOR EACH ROW
EXECUTE FUNCTION company_db.fn_stamp_updated();
```

**Why it works**: Because this modifies `NEW` directly inside a `BEFORE`
trigger rather than issuing a separate `UPDATE` statement against
`employees`, it never re-fires the trigger at all — `BEFORE` triggers
altering `NEW` is the standard, recursion-free way to "update the row being
written." The recursion risk specifically arises when a trigger function
issues its *own* `UPDATE`/`INSERT` statement against the same table (or a
table with a trigger that loops back), which *does* re-invoke triggers.

**Alternative approaches**: If a trigger genuinely must issue a separate
`UPDATE` against its own table (rather than modifying `NEW`), guard against
recursion with a session variable/flag (`pg_temp` table or
`current_setting`/`set_config` sentinel) checked at the top of the trigger
function, or ensure the `UPDATE`'s `WHERE` clause structurally cannot match
the row currently being processed again.

**Performance considerations**: Modifying `NEW` in a `BEFORE` trigger is
essentially free (no extra statement, no extra trigger firing); issuing a
genuine follow-up `UPDATE` statement doubles the write and risks
lock/deadlock complexity on top of the recursion risk.

**Common mistakes**:
> - Writing `UPDATE employees SET ... WHERE employee_id = NEW.employee_id;`
>   inside a `BEFORE UPDATE` trigger on `employees` instead of just setting
>   `NEW.column := value` — this both re-fires the trigger unnecessarily and
>   is redundant with the row already being written.
> - Not testing multi-row `UPDATE` statements against a recursive trigger
>   setup — recursion bugs often only surface under specific row-count/order
>   conditions.

---

### Q58. How would you use a trigger to maintain a denormalized `order_total` column on `ecommerce_db.orders` whenever `order_items` changes?

**Answer**:

```plpgsql
-- Add the denormalized column first (not in the original schema)
ALTER TABLE ecommerce_db.orders ADD COLUMN order_total NUMERIC(12,2) NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION ecommerce_db.fn_sync_order_total()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_id INT := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    UPDATE ecommerce_db.orders
    SET order_total = (
        SELECT COALESCE(SUM(quantity * unit_price), 0)
        FROM ecommerce_db.order_items
        WHERE order_id = v_order_id
    )
    WHERE order_id = v_order_id;
    RETURN NULL; -- AFTER trigger return value is ignored, NULL is conventional
END;
$$;

CREATE TRIGGER trg_sync_order_total
AFTER INSERT OR UPDATE OR DELETE ON ecommerce_db.order_items
FOR EACH ROW
EXECUTE FUNCTION ecommerce_db.fn_sync_order_total();
```

**Why it works**: `COALESCE(NEW.order_id, OLD.order_id)` handles all three
trigger events uniformly — `NEW` is populated for `INSERT`/`UPDATE`, `OLD` for
`DELETE`/`UPDATE`, so this expression always resolves to the affected
`order_id` regardless of operation. The trigger recomputes the total from
scratch on every affected row change, guaranteeing `order_total` can never
drift from the true sum of `order_items`, at the cost of recomputing the full
sum rather than incrementally adjusting it.

**Alternative approaches**: An incremental version (`order_total = order_total
+ NEW.quantity*NEW.unit_price - OLD.quantity*OLD.unit_price` per case) avoids
the re-aggregation `SELECT SUM(...)` per trigger firing, trading a small risk
of drift-under-bugs for better performance on orders with many line items;
alternatively, skip the denormalized column entirely and compute the total
on read via a view (Q1) — simpler, always consistent, but recomputed on every
read instead of maintained on every write.

**Performance considerations**: Every `order_items` write now does an extra
`UPDATE` + aggregate subquery against `orders` — for orders with few line
items (typical here) this is cheap; for a workload with very high
`order_items` write frequency, prefer the incremental-update variant or
batch synchronization to avoid the added write amplification.

**Common mistakes**:
> - Only handling `INSERT`, forgetting `UPDATE`/`DELETE` on `order_items`
>   also need to keep `order_total` in sync.
> - Not using `COALESCE(NEW.order_id, OLD.order_id)`, causing a `NULL`
>   reference error on `DELETE` (where `NEW` doesn't exist).

---

### Q59. What are transition tables (`REFERENCING NEW TABLE AS ...`) and why are they better than row-level triggers for bulk operations?

**Answer**: Transition tables let a `FOR EACH STATEMENT` trigger see *all*
rows affected by a single statement as a temporary, queryable table-like
relation, instead of firing once per row.

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.fn_bulk_low_stock_alert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO ecommerce_db.reorder_alerts (product_id, warehouse_location, quantity_on_hand)
    SELECT nt.product_id, nt.warehouse_location, nt.quantity_on_hand
    FROM new_table nt
    WHERE nt.quantity_on_hand < nt.reorder_level;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_bulk_low_stock
AFTER UPDATE ON ecommerce_db.inventory
REFERENCING NEW TABLE AS new_table
FOR EACH STATEMENT
EXECUTE FUNCTION ecommerce_db.fn_bulk_low_stock_alert();
```

A single `UPDATE inventory SET quantity_on_hand = quantity_on_hand - 5 WHERE
warehouse_location = 'Mumbai-WH1';` affecting many rows fires this trigger
**once**, with `new_table` containing every updated row.

**Why it works**: Instead of the trigger function being invoked N times (once
per row) and doing N separate small pieces of work (N inserts, N scalar
checks), it's invoked once and does one set-based `INSERT ... SELECT` against
all N rows together — the aggregate/bulk logic is expressed the way SQL is
best at expressing it.

**Alternative approaches**: A `FOR EACH ROW` trigger achieves the same
end result (an alert row per qualifying product) but at N times the
function-call and small-statement overhead for a bulk `UPDATE` affecting many
rows at once.

**Performance considerations**: For single-row `UPDATE`s, `FOR EACH ROW` vs.
`FOR EACH STATEMENT` with transition tables perform similarly; for bulk
operations affecting thousands of rows, `FOR EACH STATEMENT` with transition
tables can be an order of magnitude faster because it avoids per-row
PL/pgSQL function-call overhead entirely.

**Common mistakes**:
> - Defaulting to `FOR EACH ROW` for logic that's naturally aggregate/bulk in
>   nature (like this reorder alert scan), missing an easy performance win
>   available since PostgreSQL 10.
> - Forgetting transition tables are only visible within the specific
>   trigger they're declared for — you can't reference `new_table` from an
>   unrelated trigger on the same table.

---

### Q60. How do you prevent a `DELETE` trigger from firing during a specific maintenance script, without dropping and recreating the trigger?

**Answer**: Use `ALTER TABLE ... DISABLE TRIGGER` / `ENABLE TRIGGER`, scoped
tightly around the maintenance operation, and re-enable it immediately after
— ideally inside the same transaction so a failure can't leave the trigger
permanently disabled.

```sql
BEGIN;
ALTER TABLE banking_db.accounts DISABLE TRIGGER trg_audit_accounts;

-- bulk maintenance operation that shouldn't generate audit noise
DELETE FROM banking_db.accounts WHERE status = 'CLOSED' AND opened_date < '2010-01-01';

ALTER TABLE banking_db.accounts ENABLE TRIGGER trg_audit_accounts;
COMMIT;
```

**Why it works**: `DISABLE TRIGGER` marks the specific named trigger as
inactive at the catalog level for the duration until re-enabled; wrapping
both statements in one transaction guarantees that if the `DELETE` fails
and the transaction rolls back, the trigger's enabled/disabled state also
rolls back with it (trigger enable/disable state changes are transactional
DDL in PostgreSQL), so you never accidentally leave auditing permanently off.

**Alternative approaches**: `ALTER TABLE ... DISABLE TRIGGER ALL` disables
every trigger (including foreign-key-enforcement triggers!) on the table —
almost always too broad; disable specific named triggers instead. A
session-local guard variable checked inside the trigger function itself
(`IF current_setting('myapp.skip_audit', true) = 'on' THEN RETURN NEW; END
IF;`) is a more surgical alternative that doesn't require superuser/owner
DDL privileges and can be toggled per-session rather than table-wide.

**Performance considerations**: Disabling a trigger for a large bulk
operation avoids the (potentially significant) cumulative cost of firing it
for every affected row — appropriate when the audit/side-effect isn't needed
for a specific known maintenance operation, but be deliberate: this is also
how audit gaps happen if used carelessly.

**Common mistakes**:
> - Using `DISABLE TRIGGER ALL`, inadvertently disabling foreign-key
>   constraint triggers and allowing referential-integrity violations during
>   the "maintenance window."
> - Disabling a trigger outside a transaction and forgetting to re-enable it
>   if the script errors out partway — leaving production auditing silently
>   off until someone notices.

---

## 9. Dynamic SQL & Injection Safety

Dynamic SQL — building a query string at runtime and executing it — is
sometimes unavoidable (variable table/column names, optional filter
combinations), but it's also the single most common source of SQL injection
vulnerabilities. This section covers `EXECUTE`/`format()` in PL/pgSQL, safe
parameterization, and two "spot the vulnerability" exercises.

### Q61. What is SQL injection, mechanically, and construct a minimal example against `ecommerce_db.users`?

**Answer**: SQL injection happens when untrusted input is concatenated
directly into a SQL string that's then executed, letting the input escape
its intended role as a literal value and instead be interpreted as SQL
syntax/control structure.

```plpgsql
-- VULNERABLE: string concatenation of raw user input
CREATE OR REPLACE FUNCTION ecommerce_db.find_user_bad(p_username TEXT)
RETURNS SETOF ecommerce_db.users
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT * FROM ecommerce_db.users WHERE username = ''' || p_username || '''';
END;
$$;

-- Attacker calls it with:
SELECT * FROM ecommerce_db.find_user_bad(
    ''' OR ''1''=''1'' --'
);
```

The resulting executed string becomes:
```sql
SELECT * FROM ecommerce_db.users WHERE username = '' OR '1'='1' --'
```
The `OR '1'='1'` clause is always true, so this returns **every row in
`users`**, not just a specific username's row — the attacker has bypassed
the intended single-user lookup entirely using nothing but crafted input.

**Why it works**: The single quote in the attacker's input closes the string
literal the developer intended to contain the *whole* username, and
everything after it is parsed as SQL syntax rather than data — the `--`
comments out the trailing quote so the statement remains syntactically valid.

**Alternative approaches**: See Q62 for the parameterized fix — the only
robust defense is never building executable SQL by concatenating untrusted
input as anything other than a bound parameter.

**Performance considerations**: Not a performance issue, but note that once
exploited, an injected `OR '1'='1'` clause can also *defeat indexing*
(returning the whole table) — a security bug that simultaneously becomes a
performance incident.

**Common mistakes**:
> - Believing "escaping quotes" (doubling `'` to `''`) manually is a
>   sufficient defense — it's fragile and easy to get wrong across encodings/
>   contexts; use parameterized execution instead (Q62).
> - Assuming injection only matters for user-facing web forms — internal
>   admin tools and batch scripts that build dynamic SQL from any external
>   input (file contents, API responses, even other database rows) are
>   equally vulnerable.

---

### Q62. Fix the injection vulnerability from Q61 using safe parameterized dynamic SQL.

**Answer**:

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.find_user_safe(p_username TEXT)
RETURNS SETOF ecommerce_db.users
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT * FROM ecommerce_db.users WHERE username = $1'
        USING p_username;
END;
$$;

SELECT * FROM ecommerce_db.find_user_safe(''' OR ''1''=''1'' --');
-- Returns zero rows: the entire malicious string is treated as a literal
-- username value to search for, which doesn't exist — no injection occurs.
```

Even simpler, since this particular query has no genuinely dynamic
structure (no variable table/column names), skip `EXECUTE` altogether:

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.find_user_safer(p_username TEXT)
RETURNS SETOF ecommerce_db.users
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM ecommerce_db.users WHERE username = p_username;
END;
$$;
```

**Why it works**: `USING p_username` binds the value as a genuine query
parameter (like a prepared statement placeholder), never as SQL text — the
database driver sends the value out-of-band from the query structure, so
there is no string to "escape out of." No matter what characters
`p_username` contains, it can only ever be compared as a literal value, never
parsed as SQL syntax.

**Alternative approaches**: The static (non-`EXECUTE`) version is strictly
better whenever the query's *structure* (table name, column list, filter
shape) doesn't need to vary at runtime — reserve `EXECUTE ... USING` for
cases where the SQL structure itself genuinely must be built dynamically
(see Q63, Q64).

**Performance considerations**: Parameterized `EXECUTE` also enables plan
caching benefits when the same query shape (with different parameter values)
runs repeatedly — string-concatenated dynamic SQL produces a different query
text every time, defeating PostgreSQL's statement-level plan caching
opportunities.

**Common mistakes**:
> - Using `EXECUTE` with `USING` for the *filter values* but still
>   concatenating untrusted input for structural parts (table/column names)
>   without validating them against an allowlist — see Q64.
> - Reaching for `EXECUTE` reflexively even when a plain static query would
>   do — adding needless complexity and losing plan-caching benefits.

---

### Q63. Write a safe dynamic-SQL procedure that filters `company_db.employees` by an arbitrary, caller-chosen combination of optional filters (department, status, hire date range).

**Answer**:

```plpgsql
CREATE OR REPLACE FUNCTION company_db.search_employees(
    p_department_id INT DEFAULT NULL,
    p_status        VARCHAR DEFAULT NULL,
    p_hired_after   DATE DEFAULT NULL
)
RETURNS SETOF company_db.employees
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql TEXT := 'SELECT * FROM company_db.employees WHERE 1=1';
    v_params TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF p_department_id IS NOT NULL THEN
        v_sql := v_sql || ' AND department_id = $' || (array_length(v_params, 1) + 1);
        v_params := v_params || p_department_id::TEXT;
    END IF;
    IF p_status IS NOT NULL THEN
        v_sql := v_sql || ' AND status = $' || (array_length(v_params, 1) + 1);
        v_params := v_params || p_status;
    END IF;
    IF p_hired_after IS NOT NULL THEN
        v_sql := v_sql || ' AND hire_date >= $' || (array_length(v_params, 1) + 1);
        v_params := v_params || p_hired_after::TEXT;
    END IF;

    RETURN QUERY EXECUTE v_sql USING VARIADIC v_params;
END;
$$;
```

A simpler, more idiomatic PostgreSQL approach avoids the positional-parameter
bookkeeping entirely by leaning on `IS NULL OR`:

```plpgsql
CREATE OR REPLACE FUNCTION company_db.search_employees_v2(
    p_department_id INT DEFAULT NULL,
    p_status        VARCHAR DEFAULT NULL,
    p_hired_after   DATE DEFAULT NULL
)
RETURNS SETOF company_db.employees
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM company_db.employees
    WHERE (p_department_id IS NULL OR department_id = p_department_id)
      AND (p_status IS NULL OR status = p_status)
      AND (p_hired_after IS NULL OR hire_date >= p_hired_after);
$$;
```

**Why it works**: All caller-supplied *values* flow through bound parameters
(`USING v_params` / plain function arguments) in both versions — never
concatenated into the SQL text — so no combination of filter values can
escape into SQL syntax. Only the *presence or absence* of a clause (a
boolean decision the code controls, not the attacker) affects the generated
SQL shape.

**Alternative approaches**: The `v2` static version is preferable whenever
performance of the planner reasoning about `(param IS NULL OR col = param)`
is acceptable — the planner can sometimes produce less precise plans for this
pattern than a true dynamically-omitted clause would, since it must plan for
both the "NULL" and "non-NULL" cases generically; the dynamic version (`v1`)
produces a tighter, filter-specific plan per call at the cost of losing some
prepared-statement plan reuse across different filter combinations.

**Performance considerations**: The `IS NULL OR` static pattern can defeat
index usage in some cases because the planner must produce a single plan
valid for all parameter value combinations; if this matters, the dynamic
`EXECUTE` version (still fully parameterized and safe) lets each distinct
filter combination get its own optimally-targeted plan.

**Common mistakes**:
> - Concatenating `p_status` directly into `v_sql` instead of pushing it
>   through `v_params`/`USING` — reintroducing the exact vulnerability from
>   Q61 while still technically "using dynamic SQL."
> - Building the parameter array with mismatched types/order relative to the
>   `$1, $2, ...` placeholders generated in `v_sql`.

---

### Q64. Spot the vulnerability: a report generator lets an admin choose which column to sort by.

```plpgsql
CREATE OR REPLACE FUNCTION company_db.list_employees_sorted(p_sort_column TEXT)
RETURNS SETOF company_db.employees
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT * FROM company_db.employees ORDER BY ' || p_sort_column;
END;
$$;
```

**Answer**: This is vulnerable, and it's a *different flavor* of injection
than Q61: `p_sort_column` is a **structural** element (a column/expression
name), which cannot be passed as a bound parameter at all — `ORDER BY $1`
would bind `$1` as a *string literal value* to sort by, not as a column
reference, so parameterization (Q62's fix) doesn't apply here. An attacker
can pass something like `'employee_id; DROP TABLE employees; --'` or,
without needing a stackable statement at all, `'(SELECT CASE WHEN
(SELECT COUNT(*) FROM salaries WHERE base_salary > 1000000) > 0 THEN
employee_id ELSE last_name END)'` to perform blind boolean-based data
exfiltration through timing/ordering side effects, all without ever
supplying a literal value.

**Why it works (the fix)**: Validate the input against an **explicit
allowlist** of legitimate column names before use — never attempt to sanitize
or blacklist structural SQL identifiers, since the space of malicious
identifier-position payloads is unbounded.

```plpgsql
CREATE OR REPLACE FUNCTION company_db.list_employees_sorted_safe(p_sort_column TEXT)
RETURNS SETOF company_db.employees
LANGUAGE plpgsql
AS $$
DECLARE
    v_column TEXT;
BEGIN
    v_column := CASE p_sort_column
        WHEN 'employee_id' THEN 'employee_id'
        WHEN 'last_name'   THEN 'last_name'
        WHEN 'hire_date'   THEN 'hire_date'
        ELSE NULL
    END;

    IF v_column IS NULL THEN
        RAISE EXCEPTION 'Invalid sort column: %', p_sort_column;
    END IF;

    RETURN QUERY EXECUTE format(
        'SELECT * FROM company_db.employees ORDER BY %I', v_column
    );
END;
$$;
```

**Alternative approaches**: `format('... ORDER BY %I', p_sort_column)` alone
(using `%I` to safely quote an identifier) prevents *syntax breakout* — `%I`
double-quotes and escapes the identifier so it can't inject arbitrary SQL —
but it does **not** prevent referencing a column that exists but shouldn't be
exposed (e.g., sorting by a sensitive column an unauthorized caller
shouldn't even know exists); the allowlist `CASE` is strictly safer because
it also constrains *which* columns are acceptable, not just that the
identifier is syntactically well-formed.

**Performance considerations**: An allowlist lookup is a constant-time
`CASE`/lookup-table check — negligible overhead — and lets each generated
query use a normal index on the chosen sort column, exactly as if it had been
hardcoded.

**Common mistakes**:
> - Believing `format('%I', p_sort_column)` alone is a complete fix — it
>   prevents SQL syntax injection through the identifier but still allows
>   sorting (and, in richer variants, potentially inferring data from) any
>   column that syntactically parses as a valid identifier, including ones
>   never intended to be exposed.
> - Trying to blacklist dangerous keywords (`DROP`, `;`, `--`) instead of
>   allowlisting valid values — blacklists are always incomplete against a
>   sufficiently motivated attacker.

---

### Q65. What is `format()` with `%I` and `%L`, and why are they essential building blocks for safe dynamic SQL?

**Answer**: `format()` is PL/pgSQL's `sprintf`-style string templating
function; `%I` formats its argument as a properly double-quoted and
escaped **identifier** (table/column/schema name), and `%L` formats its
argument as a properly single-quoted and escaped **literal** value — both
handle embedded quotes/special characters correctly, unlike manual string
concatenation.

```plpgsql
CREATE OR REPLACE PROCEDURE company_db.archive_department(p_dept_name TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name TEXT := 'archive_' || lower(regexp_replace(p_dept_name, '[^a-zA-Z0-9]', '_', 'g'));
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS company_db.%I AS
         SELECT * FROM company_db.employees WHERE department_id = (
             SELECT department_id FROM company_db.departments WHERE department_name = %L
         )',
        v_table_name, p_dept_name
    );
    COMMIT;
END;
$$;

CALL company_db.archive_department('Engineering');
-- safely builds: CREATE TABLE IF NOT EXISTS company_db.archive_engineering AS
--                SELECT * FROM company_db.employees WHERE department_id = (
--                    SELECT department_id FROM company_db.departments WHERE department_name = 'Engineering'
--                )
```

Note even the identifier `v_table_name` is *derived* from user input, so it's
sanitized via `regexp_replace` *and* still passed through `%I` — defense in
depth, since `%I` alone only prevents syntax breakout, not semantic misuse
(e.g., an attacker choosing a department name that collides with an existing
critical table name).

**Why it works**: `%I` wraps the value in double quotes and doubles any
embedded double quotes, guaranteeing whatever string it's given is
interpreted purely as a single identifier token, never as multiple tokens or
injected syntax; `%L` similarly quotes/escapes for safe use as a string
literal (equivalent to `quote_literal()`), handling embedded single quotes,
backslashes, and NULL correctly (formatting SQL `NULL` for an actual `NULL`
argument, rather than the literal text `"NULL"`).

**Alternative approaches**: `quote_ident()` and `quote_literal()` are the
underlying functions `%I`/`%L` wrap — using them directly is equivalent but
more verbose for multi-argument templates; `format()` is generally preferred
for readability when building longer dynamic statements.

**Performance considerations**: Negligible — string formatting cost is
insignificant relative to query execution; the benefit here is purely
correctness/safety, not speed.

**Common mistakes**:
> - Using `%s` (plain substitution, no quoting/escaping) instead of `%I`/`%L`
>   for identifiers/literals — `%s` provides zero injection protection and
>   is only appropriate for values you've already fully validated/quoted
>   yourself, or truly static SQL fragments.
> - Regex-sanitizing an identifier and assuming that alone is sufficient
>   without *also* passing it through `%I` — belt-and-suspenders is the
>   correct posture for anything deriving a structural SQL element from user
>   input.

---

### Q66. When is dynamic SQL (`EXECUTE`) actually necessary in PL/pgSQL, versus just a bad habit?

**Answer**: `EXECUTE` is genuinely necessary when the *structure* of the
query — not just its parameter values — must vary at runtime and cannot be
expressed as a static query with conditional expressions: dynamic table/
schema names (e.g., a multi-tenant system with one table per tenant),
dynamic column lists (e.g., a generic "pivot" or CSV-export utility),
dynamically-chosen sort/filter columns validated via allowlist (Q64), or
executing DDL (`CREATE TABLE`, `ALTER TABLE`) from within a function, since
DDL statement targets can't be parameterized at all in static PL/pgSQL.

```plpgsql
-- Genuinely needs EXECUTE: table name is a runtime variable, and DDL
-- can never be written as a static parameterized PL/pgSQL statement.
CREATE OR REPLACE PROCEDURE ecommerce_db.create_monthly_partition(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_partition_name TEXT := 'orders_' || to_char(p_month, 'YYYY_MM');
BEGIN
    EXECUTE format(
        'CREATE TABLE ecommerce_db.%I PARTITION OF ecommerce_db.orders
         FOR VALUES FROM (%L) TO (%L)',
        v_partition_name, p_month, p_month + INTERVAL '1 month'
    );
END;
$$;
```

It's a bad habit — not a necessity — when it's used for ordinary filtering by
value (Q61-62's fix shows the static alternative) or when a developer reaches
for string-building out of unfamiliarity with `CASE`/`COALESCE`-based
conditional-filter patterns (Q63's `v2`).

**Why it works**: DDL statement targets (table/column/constraint names in
`CREATE`/`ALTER`) are lexical/syntactic parts of the statement, not bind-
able runtime values in any SQL dialect — there is no `CREATE TABLE $1`. Once
a table name genuinely isn't known until runtime, dynamic SQL is the only
mechanism PL/pgSQL offers.

**Alternative approaches**: For the multi-tenant "one table per tenant"
pattern specifically, a single shared table with a `tenant_id` column plus
Row-Level Security policies is usually a better architecture than dynamic
per-tenant DDL — worth raising in an interview as evidence you understand
dynamic SQL is a tool of last resort, not a design pattern to reach for by
default.

**Performance considerations**: Dynamic SQL statements are re-planned on
every `EXECUTE` (no prepared-statement plan caching across different
generated SQL text) — a static query executed frequently benefits from
PostgreSQL's plan caching in ways a differently-shaped dynamic string each
time cannot.

**Common mistakes**:
> - Using dynamic SQL for ordinary value filtering "just in case" future
>   flexibility is needed — YAGNI applies; add dynamic SQL when a genuine
>   structural requirement appears, not preemptively.
> - Forgetting that even "necessary" dynamic SQL for DDL still requires
>   `%I`/`%L` quoting for any user-influenced component (as shown above with
>   `v_partition_name` and the date bounds).

---

### Q67. What's the difference between a client-side parameterized query (e.g., `$1` placeholders sent by a driver) and PL/pgSQL's `EXECUTE ... USING`, in terms of injection safety?

**Answer**: Both achieve the same safety guarantee — values are transmitted
and bound separately from SQL text — but at different layers. A client-side
parameterized query (e.g., using `psycopg2`'s `cursor.execute(sql, params)`
or a prepared statement via `PREPARE`/`EXECUTE` at the wire-protocol level)
protects the boundary between *application code* and the database. PL/pgSQL's
`EXECUTE ... USING` protects the boundary *inside* a stored function/procedure
when it needs to build a query string from a variable but still bind actual
values safely.

```plpgsql
-- Safe at the PL/pgSQL layer even though the surrounding SQL is dynamically built
EXECUTE format('SELECT * FROM %I WHERE customer_id = $1', v_table_name)
    USING p_customer_id;
```

```python
# Safe at the application layer — psycopg2 sends the value out-of-band
cur.execute("SELECT * FROM customers WHERE customer_id = %s", (customer_id,))
```

**Why it works**: In both cases, the underlying wire protocol (or PL/pgSQL's
internal `EXECUTE` machinery) transmits parameter values through a distinct
channel from the query text, so the database never has to *parse* the value
as part of the SQL grammar — it's bound directly to a typed slot after
parsing is already complete.

**Alternative approaches**: Building the full query string in the
application layer (string formatting/f-strings/`.format()`) and sending it
as one opaque string to the database — even if it "looks like" it's using
placeholders syntactically — is **not** the same thing and remains fully
vulnerable if the value is interpolated into the Python/Java/etc. string
*before* it reaches the driver's `execute()` call.

**Performance considerations**: True parameterized queries additionally
enable server-side prepared-statement plan caching across repeated calls
with different parameter values — another reason to prefer them over string-
built queries even where injection isn't a concern.

**Common mistakes**:
> - Using an application language's f-string/string-concatenation to build
>   the SQL text, then handing the driver a single already-interpolated
>   string — this defeats the entire purpose of parameterization even if a
>   `%s`/`$1`-looking placeholder appears somewhere in the code nearby.
> - Assuming an ORM automatically makes all queries safe — raw/`.extra()`/
>   string-built fragments inside otherwise-safe ORM code re-introduce the
>   exact same vulnerability.

---

## 10. Temporary Tables

Temporary tables provide session-scoped (or transaction-scoped) storage for
intermediate results — useful for staging data during ETL, breaking a
complex multi-step transformation into named stages, or avoiding
re-computation of an expensive intermediate result within one session.

### Q68. What is a temporary table, and how does its lifecycle differ from a regular table?

**Answer**: A `TEMPORARY` (or `TEMP`) table is automatically dropped at the
end of the session that created it (default `ON COMMIT PRESERVE ROWS`), or
optionally at the end of the current transaction (`ON COMMIT DROP`) or
truncated at each commit (`ON COMMIT DELETE ROWS`). It's visible only to the
session that created it — other concurrent sessions can create their own
identically-named temp table without conflict.

```sql
CREATE TEMPORARY TABLE temp_high_value_customers (
    customer_id INT,
    total_loan_exposure NUMERIC
) ON COMMIT PRESERVE ROWS;

INSERT INTO temp_high_value_customers
SELECT customer_id, SUM(loan_amount)
FROM banking_db.loans
WHERE status = 'ACTIVE'
GROUP BY customer_id
HAVING SUM(loan_amount) > 500000;
```

**Why it works**: PostgreSQL implements each session's temp tables in a
private schema (`pg_temp_N`) that only that session's search path resolves
into — this is why two different sessions can both `CREATE TEMP TABLE staging
(...)` simultaneously without a naming collision, and why the data is
automatically cleaned up (the whole `pg_temp_N` schema is dropped) when the
session disconnects.

**Alternative approaches**: A CTE (`WITH ... AS (...)`) achieves similar
"named intermediate result" ergonomics for a single query without persisting
anything beyond that one statement, and avoids catalog overhead — prefer a
CTE when the intermediate result is only needed within one query; use a temp
table when you need to reference the intermediate result across *multiple*
separate statements, or need to build an index on it, or need to run
`ANALYZE` on it for the planner to reason well about subsequent joins.

**Performance considerations**: Temp tables generate real catalog entries
(creating/dropping them repeatedly in a busy connection-pooled environment
can bloat `pg_catalog` and slow down catalog lookups); connection poolers
that reuse physical connections across logical sessions can also leak temp
tables between "sessions" if not explicitly cleaned up.

**Common mistakes**:
> - Assuming a temp table is visible to other sessions/connections for
>   sharing intermediate results — it is strictly private to the creating
>   session.
> - Not accounting for `ON COMMIT DROP` behavior when running inside a
>   framework that manages transactions automatically per request — the temp
>   table can vanish sooner than expected if a commit happens mid-workflow.

---

### Q69. Write a staging workflow using a temp table to reconcile `banking_db.accounts` balances against a recomputed sum of `transactions`.

**Answer**:

```sql
CREATE TEMPORARY TABLE temp_balance_check ON COMMIT DROP AS
SELECT
    a.account_id,
    a.balance AS recorded_balance,
    COALESCE(SUM(
        CASE
            WHEN t.transaction_type IN ('DEPOSIT', 'TRANSFER_IN')  THEN t.amount
            WHEN t.transaction_type IN ('WITHDRAWAL', 'TRANSFER_OUT') THEN -t.amount
        END
    ), 0) AS computed_net_movement
FROM banking_db.accounts a
LEFT JOIN banking_db.transactions t ON t.account_id = a.account_id
GROUP BY a.account_id, a.balance;

CREATE INDEX ON temp_balance_check (account_id);

SELECT * FROM temp_balance_check
WHERE recorded_balance <> computed_net_movement;  -- flags accounts whose
                                                    -- opening balance + movements
                                                    -- don't foot cleanly, since
                                                    -- opening balances predate
                                                    -- the transaction log here
```

**Why it works**: `CREATE TEMPORARY TABLE ... AS SELECT` materializes the
join+aggregate result once into a real (if session-scoped) table, letting
subsequent queries (the final `SELECT`, or further joins) run against
already-computed, indexable data instead of repeating the aggregation join
each time — useful for a multi-step reconciliation process that inspects the
same intermediate result from several angles.

**Alternative approaches**: A CTE could express the same aggregation for a
single follow-up query, but temp tables let you `CREATE INDEX` on the
intermediate result and run `ANALYZE` on it, both of which matter once the
reconciliation involves several subsequent large joins/filters rather than
one simple follow-up `SELECT`.

**Performance considerations**: For large `transactions` tables, materializing
the aggregate once into a temp table (rather than recomputing it in every
downstream query referencing it) avoids redundant scan/aggregate work across
a multi-step reconciliation script.

**Common mistakes**:
> - Forgetting `ANALYZE temp_balance_check;` before running further complex
>   joins against it — temp tables don't automatically get statistics the
>   way autovacuum eventually provides for permanent tables, so the planner
>   may have very poor row estimates for a freshly-populated temp table
>   unless explicitly analyzed.
> - Not choosing `ON COMMIT DROP` for an intentionally single-use staging
>   table, leaving it to accumulate for the rest of a long-lived session.

---

### Q70. Why might the planner produce a bad plan for a query against a freshly-created temp table, and how do you fix it?

**Answer**: PostgreSQL's planner relies on `pg_statistic` entries produced by
`ANALYZE` (run automatically by autovacuum on ordinary tables over time) to
estimate row counts and value distributions. A temp table is often created,
populated, and queried all within the same short script/transaction —
autovacuum never gets a chance to analyze it (and, notably, autovacuum does
not process temporary tables at all, since they're private to a session it
can't safely access), so the planner is working from default, often wildly
inaccurate, guesses about the temp table's size and distribution.

```sql
CREATE TEMPORARY TABLE temp_orders_subset AS
SELECT * FROM ecommerce_db.orders WHERE status = 'DELIVERED';

-- Without an explicit ANALYZE, the planner may still believe this table
-- has the default assumed row count/statistics, potentially choosing a
-- poor join strategy against it in a subsequent query.
ANALYZE temp_orders_subset;

SELECT o.order_id, oi.product_id
FROM temp_orders_subset o
JOIN ecommerce_db.order_items oi ON oi.order_id = o.order_id;
```

**Why it works**: Explicitly running `ANALYZE` immediately after populating
the temp table gives the planner accurate, current statistics before the
next query executes, since there's no autovacuum daemon that will ever do
this for you on a temp table.

**Alternative approaches**: For very small staging tables where a suboptimal
join strategy costs microseconds regardless, skipping `ANALYZE` is harmless;
for any temp table feeding into a nontrivial join or aggregate, always
`ANALYZE` immediately after bulk-populating it as standard practice.

**Performance considerations**: This is a very common "why did my batch
script suddenly get slow after I added a temp table" root cause — always
budget the (usually small) cost of an explicit `ANALYZE` into ETL/staging
scripts using temp tables.

**Common mistakes**:
> - Assuming temp tables get the same automatic statistics maintenance as
>   permanent tables — they don't, because autovacuum skips them entirely.
> - Running `ANALYZE` before populating the table (on an empty table),
>   which produces meaningless statistics — always analyze *after*
>   populating.

---

### Q71. What's the difference between a temporary table and an "unlogged" table, and when would you use each?

**Answer**: A `TEMPORARY` table is session-scoped and invisible to other
sessions, dropped automatically per its `ON COMMIT` behavior or at session
end. An `UNLOGGED` table is a regular, permanently-named, shared table
visible to all sessions/roles with appropriate privileges — its only special
property is that PostgreSQL skips writing WAL (write-ahead log) records for
it, making writes faster but meaning its contents are **truncated
automatically on crash recovery** (since WAL is what guarantees durability
and crash-consistency, and unlogged tables opt out of that guarantee).

```sql
CREATE UNLOGGED TABLE ecommerce_db.session_cart_staging (
    session_id TEXT,
    product_id INT,
    quantity INT
);
```

**Why it works**: Skipping WAL writes removes a major source of write
overhead (no need to flush WAL records to disk before acknowledging the
write), appropriate for data that's either fully reproducible from another
source or genuinely disposable (caches, scratch/staging data, session
tracking that isn't business-critical).

**Alternative approaches**: Use `TEMPORARY` when the data should be private
to one session and short-lived by definition; use `UNLOGGED` when multiple
sessions need to share the same scratch table concurrently and you're
willing to accept data loss on crash in exchange for write speed; use a
normal (logged) table whenever durability actually matters.

**Performance considerations**: `UNLOGGED` tables can see meaningfully faster
write throughput than logged tables (no WAL flush overhead per commit) — a
real option for staging/cache tables under heavy write load, at the explicit
cost of losing all data in that table on an unclean shutdown/crash.

**Common mistakes**:
> - Using `UNLOGGED` for data you actually need to survive a crash — this is
>   an explicit, documented trade-off, not a bug, and will surprise anyone
>   who doesn't know about it.
> - Confusing `UNLOGGED` with `TEMPORARY` — an unlogged table is permanent
>   and shared across sessions; only its durability guarantee differs from a
>   normal table.

---

### Q72. **[MySQL dialect note]** How does MySQL's `CREATE TEMPORARY TABLE` differ meaningfully from PostgreSQL's?

**Answer**: Both support session-scoped temporary tables with similar basic
syntax, but two differences matter in practice: (1) MySQL's temporary tables
cannot be referenced twice in the same query in older MySQL versions (a
long-standing MySQL-specific restriction around self-joining a temp table,
largely because of how MySQL historically implemented temp tables via the
storage engine layer — this restriction has been relaxed in some contexts in
modern MySQL but is worth knowing as a historical/portability gotcha) — in
PostgreSQL there's no such restriction; a temp table can be joined to itself
freely, like any other table. (2) MySQL has no per-table `ON COMMIT` clause
equivalent — a MySQL temporary table always survives until the session ends
or is explicitly dropped, whereas PostgreSQL supports `ON COMMIT PRESERVE
ROWS` (default), `ON COMMIT DELETE ROWS`, and `ON COMMIT DROP` for
transaction-scoped lifecycle control.

```sql
-- PostgreSQL: transaction-scoped temp table, auto-dropped at commit
CREATE TEMPORARY TABLE temp_batch (id INT) ON COMMIT DROP;

-- MySQL: no ON COMMIT option; table persists for the whole session
CREATE TEMPORARY TABLE temp_batch (id INT);
```

**Why it works**: PostgreSQL's temp table implementation is integrated with
its transaction/MVCC system deeply enough to support commit-time behaviors;
MySQL's (historically, in MyISAM/older InnoDB temp table handling)
implementation is comparatively simpler, session-lifetime-only.

**Alternative approaches**: In MySQL, achieving "drop after this
transaction" behavior requires an explicit `DROP TEMPORARY TABLE` statement
issued by application code at the appropriate point, since the database
won't do it automatically at commit.

**Performance considerations**: Neither is inherently faster; behavior
divergence chiefly affects the code you need to write for lifecycle
management when porting scripts between the two engines.

**Common mistakes**:
> - Porting a PostgreSQL `ON COMMIT DROP` staging-table pattern to MySQL
>   assuming automatic cleanup — it will not happen; explicit cleanup code
>   is required.
> - Assuming self-joins on temporary tables behave identically across
>   MySQL versions — check the specific version's documentation if
>   targeting MySQL for this pattern.

---

### Q73. Design a temp-table-based approach to bulk-upsert a CSV of new `ecommerce_db.products` price updates, with correct handling for products that don't yet exist.

**Answer**:

```sql
CREATE TEMPORARY TABLE temp_price_updates (
    sku   VARCHAR(30),
    price NUMERIC(10,2)
) ON COMMIT DROP;

-- (Application loads CSV rows via COPY, e.g.:)
-- COPY temp_price_updates FROM '/tmp/price_updates.csv' WITH (FORMAT csv, HEADER true);

INSERT INTO temp_price_updates (sku, price) VALUES
    ('SKU-MOB-001', 43999.00),
    ('SKU-LAP-999', 55999.00);  -- SKU-LAP-999 doesn't exist yet in products

ANALYZE temp_price_updates;

-- Update existing products
UPDATE ecommerce_db.products p
SET price = t.price
FROM temp_price_updates t
WHERE p.sku = t.sku;

-- Report SKUs that had no matching product (can't blindly insert —
-- a real product needs a category_id and product_name we don't have here)
SELECT t.sku, t.price
FROM temp_price_updates t
LEFT JOIN ecommerce_db.products p ON p.sku = t.sku
WHERE p.sku IS NULL;
```

**Why it works**: Loading the raw CSV into an unconstrained staging table
first (via fast bulk `COPY`) decouples "getting the data into the database
quickly" from "validating and applying it correctly" — the `UPDATE ... FROM`
join applies the bulk price change in one set-based statement, and the
`LEFT JOIN ... WHERE p.sku IS NULL` anti-join cleanly identifies exception
rows (new SKUs unknown to `products`) for separate handling, rather than
trying to interleave validation logic with row-by-row processing of the raw
CSV.

**Alternative approaches**: `INSERT ... ON CONFLICT (sku) DO UPDATE` could
merge update-or-insert into one statement *if* every column required by
`products` (`product_name`, `category_id`, etc.) were present in the staging
data — since the CSV here only supplies `sku`/`price`, a genuine "upsert" for
brand-new products isn't safely automatable without that missing information,
which is why this design deliberately separates "update known products" from
"flag unknown SKUs for manual review" rather than forcing an incomplete
insert.

**Performance considerations**: Bulk `COPY` into a temp table is dramatically
faster than issuing one `INSERT`/`UPDATE` per CSV row from application code
(avoids per-row round trips entirely); the subsequent set-based `UPDATE ...
FROM` also scales far better than looping through CSV rows and issuing
per-row `UPDATE` statements.

**Common mistakes**:
> - Attempting a naive `INSERT ... ON CONFLICT DO UPDATE` straight from
>   partial CSV data, which either fails (missing `NOT NULL` columns like
>   `product_name`) or inserts garbage placeholder values for columns the
>   CSV never supplied.
> - Not deduplicating the staging table before use if the CSV can contain
>   duplicate SKUs — a plain `UPDATE ... FROM` against a table with duplicate
>   join keys can produce unpredictable/non-deterministic results, depending
>   on this SQL engine's row-selection behavior for the join.

---

## 11. Advanced Data Types

Beyond the basic scalar types used in the Beginner/Intermediate tiers,
PostgreSQL offers `jsonb`, arrays, ranges, `citext`, and enum types that let
you model semi-structured or specialized data natively, often replacing what
would otherwise require extra tables or application-layer logic.

### Q74. Model each `banking_db.audit_log` row's `old_data`/`new_data` as `jsonb`, and write a query extracting a specific changed field.

**Answer**: The schema already defines `old_data JSONB` and `new_data
JSONB` on `audit_log` (populated by triggers like Q54's). To query changes
to a specific field (e.g., find every audit row where an account's `balance`
changed):

```sql
SELECT
    audit_id,
    row_pk,
    old_data ->> 'balance' AS old_balance,
    new_data ->> 'balance' AS new_balance,
    changed_at
FROM banking_db.audit_log
WHERE table_name = 'accounts'
  AND old_data ->> 'balance' IS DISTINCT FROM new_data ->> 'balance';
```

**Why it works**: `->>` extracts a JSON field as `text` directly (`->` would
return `jsonb`, useful for further nested traversal instead of final
extraction); comparing the extracted text values with `IS DISTINCT FROM`
correctly treats `NULL` values as comparable (unlike plain `<>`, which
returns `NULL`, not `TRUE`, when either side is `NULL`), catching cases like
a field just added or just removed.

**Alternative approaches**: The containment operator `@>` (`WHERE new_data @>
'{"status": "FROZEN"}'::jsonb`) is faster for *equality-style* containment
checks against a GIN index (Q16) but doesn't help for "did this field
change" comparisons between two documents on the same row, which inherently
need field-by-field extraction.

**Performance considerations**: `->>`-based filtering on unindexed `jsonb`
columns forces a sequential scan evaluating the JSON path per row; a GIN
index on `jsonb` accelerates containment (`@>`) and existence (`?`) operators
specifically, not arbitrary field extraction/comparison — for very
frequently-queried specific fields, consider a generated column extracting
that field into a plain indexed `text`/`numeric` column instead.

**Common mistakes**:
> - Using `<>` instead of `IS DISTINCT FROM` when comparing potentially-NULL
>   extracted JSON fields, silently missing rows where a field appeared or
>   disappeared entirely.
> - Assuming a GIN index on `jsonb` accelerates every kind of query against
>   it — it specifically helps containment/existence operators, not
>   arbitrary `->>'field' = value` comparisons (those need a B-tree
>   expression index on the specific extraction instead).

---

### Q75. Write a query using PostgreSQL arrays to find every product that appears in more than one category tag, assuming `products` had an added `tags TEXT[]` column.

**Answer**:

```sql
ALTER TABLE ecommerce_db.products ADD COLUMN tags TEXT[] DEFAULT '{}';

UPDATE ecommerce_db.products SET tags = ARRAY['bestseller', 'featured'] WHERE product_id = 1;
UPDATE ecommerce_db.products SET tags = ARRAY['clearance'] WHERE product_id = 4;
UPDATE ecommerce_db.products SET tags = ARRAY['bestseller'] WHERE product_id = 9;

-- Products tagged 'bestseller'
SELECT product_id, product_name, tags
FROM ecommerce_db.products
WHERE 'bestseller' = ANY(tags);

-- Products with more than one tag
SELECT product_id, product_name, tags
FROM ecommerce_db.products
WHERE array_length(tags, 1) > 1;

-- Expand tags into rows (one row per product/tag pair) for aggregation
SELECT tag, COUNT(*) AS product_count
FROM ecommerce_db.products, unnest(tags) AS tag
GROUP BY tag
ORDER BY product_count DESC;
```

**Why it works**: `= ANY(tags)` checks membership within the array without
needing a join to a separate tags table; `unnest()` flattens an array column
into one row per element, letting you apply normal relational
grouping/aggregation to what's stored as a single denormalized array value.

**Alternative approaches**: A proper `product_tags` junction table
(`product_id`, `tag`) is the normalized alternative — better for
referential integrity (can't have a "tag" typo diverge across products,
easier to rename a tag everywhere) and better indexing options (a plain
B-tree on the join table's `tag` column), whereas the array approach is more
compact and convenient when tags are simple, low-cardinality, and rarely
need relational integrity guarantees.

**Performance considerations**: A GIN index on `tags` (`CREATE INDEX ON
products USING GIN (tags);`) accelerates `= ANY(tags)`/`@>` array containment
queries; without it, every array-membership query requires a sequential scan
evaluating the array for every row.

**Common mistakes**:
> - Using an array column for what's really a many-to-many relationship
>   needing referential integrity (e.g., linking to a real `tags` table with
>   its own attributes) — arrays can't enforce foreign-key constraints on
>   their elements.
> - Forgetting `unnest()` when you need to aggregate/group by individual
>   array elements rather than by the whole array as a unit.

---

### Q76. What is the `citext` type, and how does it solve the case-insensitive-email problem more cleanly than an expression index?

**Answer**: `citext` (case-insensitive text, provided by the `citext`
extension) is a text-like type that performs all comparisons
(`=`, `<`, `ORDER BY`, uniqueness constraints) case-insensitively at the type
level, rather than requiring every query to remember to wrap columns in
`LOWER()`.

```sql
CREATE EXTENSION IF NOT EXISTS citext;

ALTER TABLE banking_db.customers ALTER COLUMN email TYPE CITEXT;

-- Now this Just Works without LOWER() anywhere, and the existing
-- UNIQUE constraint on email is automatically case-insensitive too:
SELECT * FROM banking_db.customers WHERE email = 'RAVI.SHANKAR@MAIL.COM';
```

**Why it works**: Because case-insensitivity is baked into the type's
comparison operators themselves, *every* query, join, `ORDER BY`, `GROUP BY`,
and `UNIQUE`/`PRIMARY KEY` constraint against a `citext` column automatically
behaves case-insensitively — there's no way for a developer to "forget" to
apply `LOWER()` in some query and introduce an inconsistency, which is a real
risk with the expression-index approach from Q15 (only queries that
explicitly write `LOWER(email)` benefit from that index; a query written as
`WHERE email = 'X'` would still be case-sensitive and could return the wrong
result).

**Alternative approaches**: The `LOWER(email)` expression-index approach
(Q15) requires no extension and works on any PostgreSQL install, but pushes
the burden of writing `LOWER()` everywhere onto every developer touching the
codebase — `citext` centralizes that correctness guarantee in the schema
instead of application/query discipline.

**Performance considerations**: A regular B-tree index on a `citext` column
works and is used automatically for equality/ordering comparisons —
performance is comparable to the expression-index approach once indexed,
without requiring queries to match a specific `LOWER()` expression exactly.

**Common mistakes**:
> - Forgetting `citext` is a separate extension that must be explicitly
>   created (`CREATE EXTENSION citext;`) before the type is available.
> - Mixing `citext` and plain `text` columns in a join/comparison without
>   realizing the comparison semantics differ between the two sides.

---

### Q77. Write a query using PostgreSQL range types to find overlapping loan terms for the same customer, assuming a `daterange` column existed.

**Answer**:

```sql
ALTER TABLE banking_db.loans ADD COLUMN term_range DATERANGE
    GENERATED ALWAYS AS (daterange(start_date, start_date + (term_months || ' months')::interval)) STORED;
```

(Note: `GENERATED ALWAYS AS` requires an immutable expression, and casting a
computed interval this way is a slight simplification for illustration —
in production you'd typically compute `term_range` via a trigger instead,
since the cast chain here may not qualify as strictly immutable in all
PostgreSQL versions.)

```sql
-- Simpler, portable version: compute the range inline per query instead
SELECT
    l1.loan_id AS loan_a, l2.loan_id AS loan_b, l1.customer_id
FROM banking_db.loans l1
JOIN banking_db.loans l2
    ON l1.customer_id = l2.customer_id
   AND l1.loan_id < l2.loan_id
   AND daterange(l1.start_date, l1.start_date + (l1.term_months || ' months')::interval)
       && daterange(l2.start_date, l2.start_date + (l2.term_months || ' months')::interval);
```

Against the seed data, no customer currently holds two overlapping loans
(each customer in `loans` has at most one row per `customer_id` except none
overlap in this seed set), so this returns zero rows — but the query
correctly expresses "find pairs of loans for the same customer whose date
ranges overlap."

**Why it works**: The `&&` operator is the range-overlap operator — it
returns true if two ranges share any point in common, expressing "do these
two loan terms overlap in time" far more directly and correctly than manual
`start_date`/`end_date` comparison logic (`(a.start <= b.end AND b.start <=
a.end)`), which is easy to get subtly wrong with off-by-one/boundary
inclusivity errors that range types handle correctly by construction.

**Alternative approaches**: Manual boundary-comparison predicates
(`l1.start_date <= l2.end_date AND l2.start_date <= l1.end_date`) work
without needing range types at all, and are necessary in databases lacking
native range support (e.g., MySQL), but are more error-prone to write
correctly, especially around inclusive/exclusive boundary semantics.

**Performance considerations**: A GiST index on a range column
(`CREATE INDEX ON loans USING GIST (term_range);`) accelerates `&&` overlap
queries directly — critical for any table where overlap-detection queries
run frequently against a large row count, since the naive boundary-
comparison form can't use a simple B-tree efficiently for a self-join overlap
check.

**Common mistakes**:
> - Writing manual overlap logic with `<` instead of `<=` (or vice versa) at
>   a boundary, silently missing edge-touching ranges — range types and `&&`
>   avoid this class of bug entirely.
> - Forgetting `l1.loan_id < l2.loan_id` in a self-join overlap check,
>   producing duplicate pairs (A,B) and (B,A), plus spurious (A,A)
>   self-matches.

---

### Q78. What is a native `ENUM` type in PostgreSQL, and how does it compare to a `VARCHAR` + `CHECK` constraint (as used for `accounts.status`)?

**Answer**: `banking_db.accounts.status` is currently modeled as `VARCHAR(20)
NOT NULL CHECK (status IN ('ACTIVE','FROZEN','CLOSED'))`. A native `ENUM`
type expresses the same constraint at the type-system level:

```sql
CREATE TYPE banking_db.account_status AS ENUM ('ACTIVE', 'FROZEN', 'CLOSED');

ALTER TABLE banking_db.accounts
    ALTER COLUMN status TYPE banking_db.account_status
    USING status::banking_db.account_status;

ALTER TABLE banking_db.accounts DROP CONSTRAINT accounts_status_check;
```

**Why it works**: An `ENUM` column stores each value as a small fixed-width
internal representation (an ordinal) rather than variable-length text,
compares faster than string comparison, and — critically — sorts by
*declaration order*, not alphabetically, so `ORDER BY status` naturally
produces `ACTIVE, FROZEN, CLOSED` (whatever order you declared) rather than
requiring a `CASE` expression to impose a custom sort order the way a
`VARCHAR` column would.

**Alternative approaches**: The `VARCHAR` + `CHECK` approach (the schema's
actual choice) is easier to evolve — adding a new valid status value is a
simple `DROP CONSTRAINT` / `ADD CONSTRAINT` with the new list, while adding a
value to an `ENUM` (`ALTER TYPE ... ADD VALUE`) has historically had
restrictions (can't run inside the same transaction as using the new value in
some PostgreSQL versions) and, more importantly, `ENUM` values can't be
easily removed or reordered once created without recreating the type
entirely — a real operational cost if the set of valid statuses changes
often.

**Performance considerations**: `ENUM` comparisons and storage are slightly
more compact/faster than `VARCHAR` + `CHECK`, but the difference is marginal
for a low-cardinality status column on a table this size — the bigger
practical trade-off is schema evolution flexibility, not raw performance.

**Common mistakes**:
> - Choosing `ENUM` for a status/category set that's expected to change
>   frequently (e.g., a business-configurable list) — the schema-migration
>   friction of altering an `ENUM` type outweighs its storage/sort benefits
>   in that scenario.
> - Forgetting `ENUM` values are case-sensitive and exact-match only — no
>   implicit case folding, unlike `citext`.

---

### Q79. Write a query using `jsonb` containment and existence operators to find every `audit_log` row where a `FROZEN` status was ever set, and explain index support.

**Answer**:

```sql
-- Containment: new_data includes {"status": "FROZEN"} exactly
SELECT * FROM banking_db.audit_log
WHERE new_data @> '{"status": "FROZEN"}'::jsonb;

-- Existence: new_data has a top-level "status" key at all (any value)
SELECT * FROM banking_db.audit_log
WHERE new_data ? 'status';

CREATE INDEX idx_audit_new_data_gin ON banking_db.audit_log USING GIN (new_data);
```

**Why it works**: `@>` (containment) checks whether the left `jsonb`
document contains the right document as a subset of key/value pairs — this
is exactly the operator a GIN index on a `jsonb` column is built to
accelerate, using a posting-list structure keyed by each distinct
path/value pair inside the documents. `?` (existence) checks whether a given
top-level key exists regardless of its value, also GIN-accelerated by the
default `jsonb_ops` operator class.

**Alternative approaches**: `jsonb_path_ops` is an alternative GIN operator
class (`USING GIN (new_data jsonb_path_ops)`) that produces a smaller,
faster index specifically for `@>` containment queries, at the cost of not
supporting the `?`/`?|`/`?&` existence operators at all — choose it if your
workload is exclusively containment-based.

**Performance considerations**: The default `jsonb_ops` GIN index supports
both containment and existence operators but is larger; `jsonb_path_ops` is
roughly half the size and faster for `@>` specifically — pick based on which
operators your actual queries use.

**Common mistakes**:
> - Using `->>'status' = 'FROZEN'` (text extraction + equality) instead of
>   `@> '{"status": "FROZEN"}'` and then being confused why the GIN index
>   isn't used — the default GIN operator class doesn't accelerate `->>`-based
>   extraction/comparison, only containment/existence operators.
> - Choosing `jsonb_path_ops` and then trying to use `?`/`?|`/`?&` — these
>   operators simply aren't supported by that operator class and will fail to
>   use the index (or error, depending on operator availability).

---

## 12. Partitioning

Partitioning splits one logical table into multiple physical child tables,
each holding a distinct subset of rows, transparently to most queries. It's
a scaling technique for very large tables — not a default choice — and this
section covers range/list/hash partitioning DDL, partition pruning revisited
in a design context, and partition maintenance.

### Q80. Design a range-partitioned version of `banking_db.transactions`, partitioned by month, and explain why this table is a good partitioning candidate.

**Answer**:

```sql
CREATE TABLE banking_db.transactions_p (
    transaction_id     BIGSERIAL,
    account_id         INT NOT NULL REFERENCES banking_db.accounts(account_id),
    transaction_type   VARCHAR(20) NOT NULL CHECK (transaction_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT')),
    amount             NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    transaction_date   TIMESTAMP NOT NULL DEFAULT now(),
    related_account_id INT REFERENCES banking_db.accounts(account_id),
    description        VARCHAR(250),
    PRIMARY KEY (transaction_id, transaction_date)
) PARTITION BY RANGE (transaction_date);

CREATE TABLE banking_db.transactions_2024_01 PARTITION OF banking_db.transactions_p
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE banking_db.transactions_2024_02 PARTITION OF banking_db.transactions_p
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- Catch-all for anything outside defined ranges (safety net, not a habit)
CREATE TABLE banking_db.transactions_default PARTITION OF banking_db.transactions_p DEFAULT;
```

`transactions` is a strong partitioning candidate because it's append-mostly
(rows are rarely updated after creation), naturally time-ordered
(`transaction_date`), and in a real production bank would grow unboundedly —
exactly the profile (large, time-ordered, append-heavy) where partitioning
pays off most.

**Why it works**: Each monthly partition is a physically separate table;
queries filtering on `transaction_date` (Q24) can prune to just the relevant
partition(s) instead of scanning the whole logical table, and maintenance
operations (archiving/dropping old data) become instant metadata operations
(`DROP TABLE transactions_2020_01;`) instead of slow, WAL-heavy `DELETE`
statements.

**Alternative approaches**: List partitioning (by `transaction_type`) would
suit a workload that mostly filters by type rather than date; hash
partitioning would suit a workload with no natural range/list key but needing
to spread write load evenly — range-by-date is the right choice here because
the dominant query and maintenance patterns (recent-data lookups, aging out
old data) are both date-driven.

**Performance considerations**: Note the primary key had to include the
partition key (`transaction_date`) alongside `transaction_id` — PostgreSQL
requires any unique/primary key on a partitioned table to include all
partitioning columns, since uniqueness can't be enforced globally across
partitions by a single index the way it can on a normal table.

**Common mistakes**:
> - Forgetting the partition key must be part of any unique/primary key
>   constraint — `PRIMARY KEY (transaction_id)` alone is rejected on a
>   `PARTITION BY RANGE (transaction_date)` table.
> - Relying on the `DEFAULT` partition as an ongoing catch-all rather than a
>   safety net — rows silently accumulating there because a new partition
>   wasn't created in time is a common operational failure mode (see Q84).

---

### Q81. What's the difference between range, list, and hash partitioning? Give one `ecommerce_db`/`banking_db` example of each.

**Answer**:

- **Range**: partitions hold a contiguous range of values — ideal for dates/
  sequential IDs. Example: `banking_db.transactions` by month (Q80).
- **List**: partitions hold an explicit, enumerated set of discrete values —
  ideal for a small, known, stable set of categories.
  ```sql
  CREATE TABLE ecommerce_db.orders_by_status (
      order_id INT, user_id INT, status VARCHAR(20), order_date TIMESTAMP
  ) PARTITION BY LIST (status);

  CREATE TABLE orders_active    PARTITION OF orders_by_status FOR VALUES IN ('PENDING','PAID','SHIPPED');
  CREATE TABLE orders_completed PARTITION OF orders_by_status FOR VALUES IN ('DELIVERED');
  CREATE TABLE orders_cancelled PARTITION OF orders_by_status FOR VALUES IN ('CANCELLED');
  ```
- **Hash**: partitions hold an evenly-distributed, arbitrary hash bucket of
  values — ideal when there's no natural range/list key but you want to
  spread rows (and write load) evenly across N partitions of similar size.
  ```sql
  CREATE TABLE ecommerce_db.reviews_by_hash (
      review_id INT, product_id INT, user_id INT, rating SMALLINT
  ) PARTITION BY HASH (product_id);

  CREATE TABLE reviews_h0 PARTITION OF reviews_by_hash FOR VALUES WITH (MODULUS 4, REMAINDER 0);
  CREATE TABLE reviews_h1 PARTITION OF reviews_by_hash FOR VALUES WITH (MODULUS 4, REMAINDER 1);
  CREATE TABLE reviews_h2 PARTITION OF reviews_by_hash FOR VALUES WITH (MODULUS 4, REMAINDER 2);
  CREATE TABLE reviews_h3 PARTITION OF reviews_by_hash FOR VALUES WITH (MODULUS 4, REMAINDER 3);
  ```

**Why it works**: Each strategy matches partition boundaries to the shape of
the query/maintenance workload — range partitioning enables pruning for
range-filtered queries and trivial "drop old data" maintenance; list
partitioning enables pruning for equality-filtered categorical queries and
lets you give each category its own storage/retention policy; hash
partitioning provides no pruning benefit for arbitrary-value lookups but
distributes write/storage load evenly when no meaningful range/list key
exists.

**Alternative approaches**: Sub-partitioning (partition-of-a-partition, e.g.,
range by month *and then* list by status within each month) combines
strategies for workloads with two independent access patterns, at the cost
of significantly more complex DDL and maintenance.

**Performance considerations**: Hash partitioning provides no query-time
pruning benefit unless the query filters by exact value on the hash key
(since bucket boundaries have no meaningful relationship to value ranges) —
its benefit is purely about spreading storage/vacuum/write load, not
accelerating reads.

**Common mistakes**:
> - Choosing hash partitioning expecting range-query pruning benefits — it
>   only prunes for equality lookups on the exact hashed column value.
> - Choosing list partitioning for a column whose value set changes often
>   (e.g., needing a new partition added for every new status value ever
>   introduced) — range or hash is more maintenance-friendly for evolving
>   category sets.

---

### Q82. What are the trade-offs of partitioning versus just adding better indexes on one large table?

**Answer**: Partitioning and indexing solve overlapping but distinct
problems. An index speeds up *finding* specific rows within a table
regardless of size; partitioning speeds up (and simplifies) operations that
naturally align with a *subset* of the table — pruning entire partitions from
a scan, and turning "delete 5 years of old data" into "drop a partition"
instead of a slow row-by-row `DELETE`. Indexing alone continues to work fine
on very large tables for point lookups; partitioning mainly pays off for
range-scoped queries, bulk retention/archival, and reducing the size (and
therefore vacuum/maintenance cost) of the "working set" of frequently-touched
data.

```sql
-- Without partitioning: index alone still finds January 2024 rows fine
CREATE INDEX idx_transactions_date ON banking_db.transactions (transaction_date);

-- But deleting 3-year-old data means a slow, WAL-heavy row-by-row DELETE:
DELETE FROM banking_db.transactions WHERE transaction_date < '2021-01-01';

-- With partitioning, the same retention operation is instant metadata:
DROP TABLE banking_db.transactions_2020_12;
```

**Why it works**: An index descent cost grows logarithmically with table
size regardless of partitioning, so for pure point-lookup workloads,
partitioning adds complexity without a proportional benefit; the real payoff
is for range-scan-heavy or retention-heavy workloads, where fewer/smaller
partitions to scan (or one partition to drop entirely) beats indexing alone.

**Alternative approaches**: For tables under a few tens of millions of rows
without an aggressive retention/archival requirement, a well-indexed
single table is usually simpler to operate and just as fast — partitioning
introduces real operational overhead (partition creation automation,
constraint/PK restrictions from Q80, cross-partition query planning
complexity) that isn't worth paying until table size or maintenance pain
actually justifies it.

**Performance considerations**: Partitioning can *hurt* performance if
overused — too many partitions increase planning time (the planner must
consider every partition unless pruning kicks in) and can fragment what would
otherwise be efficient single-table index scans; a rule of thumb is to
partition when a single table's vacuum/index-maintenance/backup time has
become a genuine operational problem, not preemptively.

**Common mistakes**:
> - Partitioning a modestly-sized table "because big tables should be
>   partitioned," adding complexity without addressing an actual bottleneck.
> - Assuming partitioning is a substitute for indexing — most partitioned
>   tables still need indexes *within* each partition for efficient lookups.

---

### Q83. Write a query against a partitioned `transactions_p` table and show, conceptually, what `EXPLAIN` looks like with and without effective pruning.

**Answer**:

```sql
EXPLAIN SELECT * FROM banking_db.transactions_p
WHERE transaction_date >= '2024-01-01' AND transaction_date < '2024-02-01';
```

```text
-- With pruning (query has a literal, sargable range on the partition key):
Append  (cost=0.00..8.51 rows=50 width=64)
  ->  Seq Scan on transactions_2024_01  (cost=0.00..8.51 rows=50 width=64)
        Filter: (transaction_date >= '2024-01-01' AND transaction_date < '2024-02-01')
```

```text
-- Without pruning (e.g., filtering on an opaque expression of the key,
-- or joining the partition-key value in from another table without a
-- constant the planner can statically evaluate):
Append  (cost=0.00..40.20 rows=250 width=64)
  ->  Seq Scan on transactions_2024_01
  ->  Seq Scan on transactions_2024_02
  ->  Seq Scan on transactions_2024_03
        ...  (every partition scanned)
```

**Why it works**: Pruning depends on the planner being able to statically
(or, for parameterized values, at execution time) prove which partitions'
bound ranges the `WHERE` clause could possibly match; a literal, unwrapped
comparison against the raw partition key column is the most reliable form
for static pruning.

**Alternative approaches**: If the filter value truly can't be known until
execution (bound via `$1` in a prepared statement, or from a join), runtime
partition pruning (PostgreSQL 11+) still eliminates non-matching partitions
during execution rather than planning — visible as `Subplans Removed: N`
rather than a shorter static `Append` list in the plan output.

**Performance considerations**: The "without pruning" case degrades roughly
linearly with partition count — a table split into 60 monthly partitions
that fails to prune scans all 60, potentially far worse than not
partitioning at all for that specific query shape.

**Common mistakes**:
> - Not verifying pruning behavior with `EXPLAIN` after introducing
>   partitioning — assuming it "just works" for every query shape without
>   checking.
> - Filtering on a derived/cast form of the partition key
>   (`transaction_date::date`, `EXTRACT(...)`) that defeats static pruning,
>   as covered in Q24/Q25.

---

### Q84. What operational problem does the `DEFAULT` partition solve, and what risk does relying on it introduce?

**Answer**: A `DEFAULT` partition (Q80) catches any row that doesn't match
any explicitly-defined partition's bounds, preventing `INSERT`/`COPY`
failures for rows that would otherwise have nowhere to go (e.g., a
transaction dated in a future month for which no partition has been created
yet).

```sql
-- Without a DEFAULT partition, this fails outright if no 2025-03
-- partition exists yet:
INSERT INTO banking_db.transactions_p (account_id, transaction_type, amount, transaction_date)
VALUES (1, 'DEPOSIT', 500, '2025-03-15');
-- ERROR: no partition of relation "transactions_p" found for row
```

**Why it works (the risk)**: Once a `DEFAULT` partition exists, that same
`INSERT` *succeeds silently* by landing in the catch-all partition instead of
failing loudly — which sounds convenient, but means out-of-range data can
accumulate unnoticed in an unpartitioned, unpruned catch-all table, defeating
the entire performance/maintenance rationale for partitioning in the first
place; worse, PostgreSQL will *refuse* to let you later create a proper
partition for a range that overlaps with rows already sitting in `DEFAULT` —
you must first move those rows out.

**Alternative approaches**: Instead of relying on `DEFAULT` as an ongoing
safety net, use a scheduled job (via `pg_cron` or an external scheduler) that
proactively creates the next period's partition well ahead of time (e.g.,
create next month's partition on the 25th of the current month), and treat
any row ever landing in `DEFAULT` as a monitoring alert to investigate rather
than a normal steady-state occurrence.

**Performance considerations**: Every insert failing to match a specific
partition falls into the (typically unindexed-for-pruning-purposes,
unbounded) `DEFAULT` partition — if this becomes large, queries that scan
`DEFAULT` (which the planner generally cannot prune, since its bounds are
"everything else") pay full-scan costs regardless of the query's own date
filter.

**Common mistakes**:
> - Treating the `DEFAULT` partition as a permanent, load-bearing part of the
>   design rather than an emergency safety net for partition-creation
>   automation failures.
> - Not monitoring `DEFAULT` partition row counts, allowing it to silently
>   grow into a large, unpruned table that undermines the whole partitioning
>   scheme.

---

### Q85. How would you migrate the existing, non-partitioned `ecommerce_db.orders` table to a partitioned scheme with minimal downtime?

**Answer**: Direct in-place conversion (`ALTER TABLE ... PARTITION BY`) isn't
supported by PostgreSQL — partitioning must be established at table creation.
The standard low-downtime approach is: create the new partitioned table
alongside the old one, backfill historical data in batches, then swap names
inside a short transaction.

```sql
-- 1. Create the new partitioned table with a temporary name
CREATE TABLE ecommerce_db.orders_new (
    order_id         INT NOT NULL,
    user_id          INT NOT NULL REFERENCES ecommerce_db.users(user_id),
    order_date       TIMESTAMP NOT NULL DEFAULT now(),
    status           VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    shipping_address VARCHAR(250),
    PRIMARY KEY (order_id, order_date)
) PARTITION BY RANGE (order_date);

CREATE TABLE ecommerce_db.orders_2024_01 PARTITION OF ecommerce_db.orders_new
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE ecommerce_db.orders_2024_02 PARTITION OF ecommerce_db.orders_new
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE ecommerce_db.orders_default PARTITION OF ecommerce_db.orders_new DEFAULT;

-- 2. Backfill in batches (avoid one giant long-running transaction)
INSERT INTO ecommerce_db.orders_new
SELECT * FROM ecommerce_db.orders WHERE order_date < '2024-01-15';
INSERT INTO ecommerce_db.orders_new
SELECT * FROM ecommerce_db.orders WHERE order_date >= '2024-01-15';

-- 3. Short-downtime swap inside one transaction
BEGIN;
LOCK TABLE ecommerce_db.orders IN ACCESS EXCLUSIVE MODE;
-- catch any rows written between the last backfill batch and the lock
INSERT INTO ecommerce_db.orders_new
SELECT * FROM ecommerce_db.orders o
WHERE NOT EXISTS (SELECT 1 FROM ecommerce_db.orders_new n WHERE n.order_id = o.order_id);
ALTER TABLE ecommerce_db.orders RENAME TO orders_old;
ALTER TABLE ecommerce_db.orders_new RENAME TO orders;
COMMIT;
```

**Why it works**: Bulk-copying historical data happens *before* the lock is
taken, while the application continues reading/writing the original table
normally — only a brief final catch-up copy plus the rename itself needs the
exclusive lock, minimizing the actual downtime window to seconds rather than
however long the full backfill takes.

**Alternative approaches**: Logical replication or a trigger-based dual-write
approach (writing to both old and new tables during a transition window)
avoids even the brief exclusive lock, at the cost of meaningfully more
implementation complexity — justified for tables where even a few seconds of
downtime is unacceptable.

**Performance considerations**: Batch the historical backfill (as shown, by
date range) rather than one giant `INSERT ... SELECT`, to avoid a single
long-running transaction that bloats WAL and holds resources; index creation
on the new partitions should also happen before the swap, not after, so
the new table isn't briefly unindexed under live load.

**Common mistakes**:
> - Attempting `ALTER TABLE orders PARTITION BY RANGE (...)` directly —
>   PostgreSQL does not support converting an existing table to partitioned
>   in place; a new table must be created and data migrated.
> - Forgetting the final catch-up `INSERT` for rows written during the
>   backfill window, silently losing orders placed between the last batch
>   and the lock/rename.

---

## Summary

This tier covered the operational core of running SQL in production: reading
and querying through views without duplicating logic, indexing correctly
based on real selectivity rather than guesswork, reading `EXPLAIN` plans to
diagnose (not guess at) performance problems, encapsulating business logic
safely in procedures and functions with correct volatility and error
handling, knowing when triggers and cursors are the right tool versus a
crutch for procedural habits, writing dynamic SQL that cannot be injected,
and scaling very large tables through partitioning without over-engineering
tables that don't need it.

The Expert tier builds on this foundation with replication, distributed
query patterns, deep concurrency/isolation-level behavior, query plan
hinting alternatives, and database internals.


