# Chapter 26 — Partitioning

> **Part VI — Database Internals & Production Engineering**
> Previous: [Chapter 25 — Advanced Data Types](25-advanced-data-types.md) · Next: [Chapter 27 — Security](27-security.md)

This chapter runs primarily against `analytics_db`, whose `sales_fact` table is **already partitioned** in the canonical seed script. If you haven't loaded it yet:

```bash
psql -f databases/analytics_db.sql   # large — see the file header for how to shrink it
```

We'll also borrow `ecommerce_db.orders` for a couple of illustrative (not-executed-against-the-real-seed) list-partitioning examples.

---

## 26.0 What This Chapter Is Really About

Open `databases/analytics_db.sql` and look at `sales_fact`:

```sql
CREATE TABLE sales_fact (
    sale_id      BIGSERIAL,
    sale_date    DATE NOT NULL,
    customer_key INT NOT NULL,
    product_key  INT NOT NULL,
    store_key    INT NOT NULL,
    quantity     INT NOT NULL CHECK (quantity > 0),
    amount       NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    PRIMARY KEY (sale_id, sale_date)
) PARTITION BY RANGE (sale_date);

CREATE TABLE sales_fact_2022 PARTITION OF sales_fact
    FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
CREATE TABLE sales_fact_2023 PARTITION OF sales_fact
    FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');
CREATE TABLE sales_fact_2024 PARTITION OF sales_fact
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
```

Then the generator loads **5,000,000 rows** into it, spread roughly evenly across those three years (~1.67 million rows per partition — the row generator picks a random offset of 0–1094 days from `2022-01-01`, which lands almost exactly one-third in each calendar year).

You have been querying this table since Chapter 10 (window functions) without necessarily noticing that `sales_fact` isn't one physical table at all — it's three. `sales_fact_2022`, `sales_fact_2023`, and `sales_fact_2024` are real, independent tables on disk, each with their own storage files, their own indexes, their own statistics. `sales_fact` itself is a thin routing shell: it holds no rows of its own and exists only so that `SELECT * FROM sales_fact` "just works" as if it really were one 5-million-row table.

That is the entire subject of this chapter: **how to split one enormous table into multiple physical pieces that are still queried — and mostly still written to — as if they were a single table**, and why doing that at the right table sizes turns hours-long operations into millisecond ones.

---

## 26.1 Why Partitioning Exists

### Simple explanation
Partitioning is splitting one huge table into smaller physical pieces ("partitions") that the database still lets you query and update as if it were one table. You get the mental model of a single `sales_fact` table with the operational benefits of many small tables.

### Technical explanation
**Declarative table partitioning** divides a logical table into multiple physical partition tables based on the value of one or more columns (the **partition key**), according to a partitioning **strategy** (range, list, or hash) and a set of **partition bounds** you declare. The parent table has no storage of its own (in PostgreSQL); every row physically lives in exactly one partition, chosen automatically at insert time by matching the row's partition-key value against each partition's bounds. Almost every SQL operation — `SELECT`, `INSERT`, `UPDATE`, `DELETE`, most constraints, and (since PostgreSQL 11) indexes — can be issued against the parent and is transparently routed to the correct partition(s) underneath.

### Why it exists — the problems it solves

| Problem with one giant table | What partitioning gives you |
|---|---|
| Every query, even one filtering to a single day, has to consider all 5,000,000 rows (or fall back entirely on one enormous index) | **Partition pruning** — the planner can prove whole partitions can't contain matching rows and skip them without reading a single block |
| Deleting old data (`DELETE FROM sales_fact WHERE sale_date < '2023-01-01'`) means scanning and row-by-row deleting ~1.67M rows, generating that many dead tuples, WAL records, and index updates, and running for a long time under lock pressure | **Dropping/detaching a partition** is a near-instant catalog operation — `DROP TABLE sales_fact_2022` removes 1.67M rows in milliseconds |
| One index over 5,000,000 rows is a deep B-tree that doesn't fit comfortably in cache | Each partition's index only covers its own slice (~1.67M rows here), so it's smaller, shallower, and far more cache-friendly |
| `VACUUM`, `ANALYZE`, and backups on a 5M-row table run as one long serial job | These maintenance operations can run **per partition**, in parallel, and skip partitions that haven't changed (e.g., no need to re-`VACUUM` a frozen 2022 partition that never receives new writes) |

> **Important Note**
> Partitioning is a *physical storage* decision. It changes nothing about the logical shape of your data model — `sales_fact` still has the same columns, the same conceptual rows, the same relationships to `dim_customer`/`dim_product`/`dim_store`. It only changes how those rows are stored and accessed underneath.

---

## 26.2 The Physical Model — What's Really There

Run this against `analytics_db` and look closely at the result:

```sql
SELECT relname, pg_size_pretty(pg_relation_size(oid))
FROM pg_class
WHERE relname LIKE 'sales_fact%'
ORDER BY relname;
```

```text
       relname       | pg_size_pretty
----------------------+----------------
 sales_fact           | 0 bytes
 sales_fact_2022      | 118 MB
 sales_fact_2023      | 118 MB
 sales_fact_2024      | 118 MB
(4 rows)
```

`sales_fact` — the table every chapter so far has queried by name — is **zero bytes**. It is a catalog entry only: a shell that declares the partitioning strategy and owns the partitioning-wide constraints, indexes-on-the-parent, and foreign keys. Every byte of actual data lives in `sales_fact_2022`, `sales_fact_2023`, and `sales_fact_2024`, which are ordinary tables you can `SELECT` from directly, `EXPLAIN` directly, and (with care) even `DROP` directly.

```sql
\d sales_fact
```
```text
Partitioned table "analytics_db.sales_fact"
   Column     |     Type      | Collation | Nullable | Default
--------------+---------------+-----------+----------+---------
 sale_id      | bigint        |           | not null | ...
 sale_date    | date          |           | not null |
 customer_key | integer       |           | not null |
 product_key  | integer       |           | not null |
 store_key    | integer       |           | not null |
 quantity     | integer       |           | not null |
 amount       | numeric(12,2) |           | not null |
Partition key: RANGE (sale_date)
Indexes:
    "sales_fact_pkey" PRIMARY KEY, btree (sale_id, sale_date)
Number of partitions: 3 (Use \d+ to list them.)
```

Internally, PostgreSQL implements this through the same catalog machinery that historically powered inheritance-based ("old-style") partitioning, but a **declarative partitioned table is not the same as inheritance** — you don't manually write `CHECK` constraints and `INSTEAD OF` triggers to route rows; `PARTITION BY` + `PARTITION OF` does it for you, and the planner has first-class knowledge of the partition structure (which is what makes pruning and parent-level index propagation possible).

**Rule to remember for this whole chapter:** *every partition is a real, independent physical table. The parent table is a routing façade that typically holds zero rows.*

---

## 26.3 Range Partitioning

### 1. Simple explanation
Range partitioning slices a table into partitions by a continuous range of values — most commonly dates. "2022 data goes here, 2023 data goes there, 2024 data goes over there." It's the natural choice whenever your data has a clear ordering and you tend to query/retain it by that ordering (time being the overwhelming majority case).

### 2. Technical explanation
`PARTITION BY RANGE (key_column[, ...])` declares that each partition owns a contiguous, non-overlapping sub-range of the partition key's domain. Each partition is created with `FOR VALUES FROM (lower_bound) TO (upper_bound)`, where the range is **half-open**: inclusive of `FROM`, exclusive of `TO`. On insert, PostgreSQL evaluates the partition key expression for the new row and routes it to the single partition whose range contains that value; if no partition's range contains it (and no `DEFAULT` partition exists), the insert is rejected outright.

### 3. Why it exists
Time-series and event-style data is the dominant real-world case: sales, orders, logs, sensor readings, audit trails — data that is written once, queried heavily near "now," queried rarely for older history, and eventually needs to be archived or purged wholesale by age. Range partitioning maps directly onto that access pattern: recent partitions stay hot and small, old partitions become cold and are dropped or archived as a unit instead of being trimmed row by row.

### 4. Full syntax breakdown

```sql
CREATE TABLE sales_fact (
    sale_id      BIGSERIAL,
    sale_date    DATE NOT NULL,
    customer_key INT NOT NULL,
    product_key  INT NOT NULL,
    store_key    INT NOT NULL,
    quantity     INT NOT NULL CHECK (quantity > 0),
    amount       NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    PRIMARY KEY (sale_id, sale_date)
) PARTITION BY RANGE (sale_date);
```

- `PARTITION BY RANGE (sale_date)` — declares the strategy and the **partition key**. The key can be a single column, multiple columns (range-of-tuples, compared lexicographically), or an expression.
- `PRIMARY KEY (sale_id, sale_date)` — **this is not optional styling.** PostgreSQL requires that any unique/primary-key constraint on a partitioned table include *all* columns of the partition key. `sale_id` alone can't be the primary key here, because uniqueness on a partitioned table can only be enforced per-partition (there's no cross-partition unique index) — including `sale_date` in the key guarantees each partition's own index can enforce true global uniqueness of `sale_id` in combination with a value it already owns exclusively.

```sql
CREATE TABLE sales_fact_2022 PARTITION OF sales_fact
    FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
```

- `PARTITION OF sales_fact` — declares this table as a partition of the parent, inheriting its column definitions, `CHECK` constraints, and (as of PG11) any indexes/constraints declared on the parent.
- `FOR VALUES FROM ('2022-01-01') TO ('2023-01-01')` — the partition bound. **Half-open**: `sale_date = '2022-01-01'` belongs here; `sale_date = '2023-01-01'` does **not** — it belongs to `sales_fact_2023`. This matters enormously: half-open intervals are the only way to tile a continuous domain with zero gaps and zero overlaps. If ranges were closed on both ends, `2023-01-01` would either belong to two partitions (ambiguous, and PostgreSQL would reject the overlapping bound at `CREATE TABLE` time) or you'd have to remember to write `'2022-12-31'` as the upper bound of 2022 — which silently creates a gap for any timestamp component or a different date resolution.

### 5. Examples grounded in `analytics_db`

**Adding a 2025 partition** (the seed data never generates 2025 rows, so this partition starts empty — exactly like adding next year's partition ahead of time in production):

```sql
CREATE TABLE sales_fact_2025 PARTITION OF sales_fact
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
```

```sql
\d+ sales_fact
```
```text
Number of partitions: 4 (Use \d+ to list them.)
Partitions: sales_fact_2022 FOR VALUES FROM ('2022-01-01') TO ('2023-01-01'),
            sales_fact_2023 FOR VALUES FROM ('2023-01-01') TO ('2024-01-01'),
            sales_fact_2024 FOR VALUES FROM ('2024-01-01') TO ('2025-01-01'),
            sales_fact_2025 FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')
```

A row for 2025 now inserts cleanly:

```sql
INSERT INTO sales_fact (sale_date, customer_key, product_key, store_key, quantity, amount)
VALUES ('2025-03-14', 1, 1, 1, 2, 99.99);
-- INSERT 0 1  → physically lands in sales_fact_2025
```

**What happens if you insert a date with no matching partition** (say, before creating `sales_fact_2025`):

```sql
INSERT INTO sales_fact (sale_date, customer_key, product_key, store_key, quantity, amount)
VALUES ('2025-03-14', 1, 1, 1, 2, 99.99);
```
```text
ERROR:  no partition of relation "sales_fact" found for row
DETAIL:  Partition key of the failing row contains (sale_date) = (2025-03-14).
```

This is the single most common way partitioned tables cause production incidents: nobody creates next year's partition in advance, and every insert for a date outside the declared ranges fails — loudly, but usually at the worst possible time (New Year's Eve).

**Using a `DEFAULT` partition to make that impossible:**

```sql
CREATE TABLE sales_fact_default PARTITION OF sales_fact DEFAULT;
```

A `DEFAULT` partition catches any row that doesn't match any other partition's range — rows before 2022, rows after whatever your last declared range is, or (typically) `NULL` in the partition key column, if the column is nullable. With a default partition in place, the same 2025 insert above would succeed even without a dedicated `sales_fact_2025` partition — the row simply lands in `sales_fact_default`.

> **⚠️ Warning**
> A `DEFAULT` partition is a safety net, not a substitute for planning. Once it accumulates rows, PostgreSQL will refuse to `ATTACH` a new range partition whose bounds would overlap any row already sitting in the default partition — it has to scan the default partition to verify no rows violate the new partition's implied "everything else" boundary, and if it finds any, the `ATTACH` fails until you move those rows out. In practice: keep the default partition empty or near-empty, and treat rows landing in it as a signal to create the missing dedicated partition promptly.

### 6. Expected behavior — illustrative EXPLAIN

```sql
EXPLAIN ANALYZE
SELECT store_key, SUM(amount) AS total_amount
FROM sales_fact
WHERE sale_date >= '2024-06-01'
GROUP BY store_key;
```

```text
-- Illustrative output. Exact costs/timings vary by hardware, PostgreSQL
-- version, and current statistics — but the SHAPE of the plan below is
-- exactly what you will see: only ONE child partition is scanned.

                                        QUERY PLAN
-------------------------------------------------------------------------------------
 HashAggregate  (cost=41230.14..41230.39 rows=25 width=12)
                (actual time=298.402..298.409 rows=25 loops=1)
   Group Key: store_key
   ->  Seq Scan on sales_fact_2024  (cost=0.00..33110.00 rows=971000 width=12)
                                    (actual time=0.028..201.114 rows=971667 loops=1)
         Filter: (sale_date >= '2024-06-01'::date)
         Rows Removed by Filter: 700000
 Planning Time: 0.512 ms
 Execution Time: 298.940 ms
(7 rows)
```

Notice: there is no `Append` node listing `sales_fact_2022` and `sales_fact_2023` at all — they were eliminated during **planning**, before execution even began, because `'2024-06-01'` is a constant the planner can compare against each partition's declared bounds up front. `sales_fact_2022` covers `[2022-01-01, 2023-01-01)` and `sales_fact_2023` covers `[2023-01-01, 2024-01-01)` — neither range can contain any value `>= '2024-06-01'`, so the planner drops them from the plan entirely. Only `sales_fact_2024` (~1.67 million rows) is scanned; within it, a residual filter narrows that down further to the ~971,667 rows from June onward.

Contrast with what the same query looks like against a **hypothetical unpartitioned** version of the same 5,000,000-row table:

```text
-- Illustrative: same query against an UNPARTITIONED sales_fact_flat holding
-- all 5,000,000 rows, with a b-tree index on sale_date.

                                        QUERY PLAN
-------------------------------------------------------------------------------------
 HashAggregate  (cost=96110.55..96110.80 rows=25 width=12)
                (actual time=1710.220..1710.228 rows=25 loops=1)
   Group Key: store_key
   ->  Index Scan using idx_sales_fact_flat_sale_date on sales_fact_flat
                                    (cost=0.57..89210.11 rows=971000 width=12)
                                    (actual time=0.061..1512.804 rows=971667 loops=1)
         Index Cond: (sale_date >= '2024-06-01'::date)
 Planning Time: 0.098 ms
 Execution Time: 1711.010 ms
(5 rows)
```

Same result set (~971,667 matching rows), but roughly **5-6x slower** in this illustrative comparison. Why, when both plans use an index/sequential filter and neither literally reads all 5,000,000 rows? Because the unpartitioned version has to walk one B-tree built over all 5,000,000 rows (deeper tree, more non-leaf pages, worse cache locality, more random heap fetches spread across a much larger table file), while the partitioned version does a compact sequential scan of one 118 MB partition that likely fits comfortably in shared_buffers/OS cache after the first pass. The gap widens further, not narrower, as the total table grows into tens or hundreds of millions of rows while individual partitions stay a fixed, manageable size.

### 7. Line-by-line
- `PARTITION BY RANGE (sale_date)` — one column, `sale_date`, is the partition key; comparisons are simple date ordering.
- `FOR VALUES FROM (...) TO (...)` — every range partition must specify both bounds explicitly, or use the special keywords `MINVALUE`/`MAXVALUE` for an open-ended bound (e.g., `FROM (MINVALUE) TO ('2022-01-01')` for "everything before 2022").
- The `CHECK` constraint PostgreSQL derives internally from each bound (visible via `\d+ sales_fact_2024`, shown as `Partition constraint`) is what the planner actually reasons about during pruning — it's logically `sale_date >= '2024-01-01' AND sale_date < '2025-01-01'`.

### 8. Internal behavior
Each range partition is a completely ordinary heap table with its own `CHECK`-constraint-equivalent partition bound stored in the catalog (`pg_class.relpartbound`), its own TOAST table if needed, its own free space map and visibility map, and its own statistics row in `pg_stats`/`pg_class.reltuples`. `INSERT INTO sales_fact ...` performs **tuple routing**: the executor evaluates the partition key expression for the new row, walks the partition bound structure (a binary-searchable range map for `RANGE`, a hash table for `LIST`/`HASH`) to find the single matching partition, and inserts directly into that partition's heap — the parent table's own storage is never touched, because it has none.

### 9. Common mistakes
- **Choosing a partition key that doesn't match actual query patterns.** If most of your dashboards filter by `customer_key` or `store_key` but the table is partitioned by `sale_date`, pruning almost never triggers for those queries — every partition still has to be scanned (or its index consulted), and you've paid the complexity cost of partitioning without the main performance benefit. Partition on the column your `WHERE` clauses actually filter on.
- **Over-partitioning.** Splitting `sales_fact` into 1,095 *daily* partitions instead of 3 yearly ones sounds like "even more pruning," but each partition is a separate catalog entry, a separate set of index catalog rows, a separate `pg_statistic` entry, and a separate file the planner has to consider (even those it eventually prunes still cost planning time to *evaluate*). Thousands of tiny partitions measurably slow down planning, `pg_dump`, and connection-time catalog cache warmup, often outweighing any query-time win. Match granularity to real query/retention needs (yearly, quarterly, or monthly — not daily, unless volumes truly justify it).
- **Forgetting to pre-create future partitions.** As shown above, an insert for a date with no matching partition simply fails. Production systems automate this — a scheduled job (cron, `pg_cron`, or an application-level maintenance task) that creates next month's or next year's partition well ahead of time, or a `DEFAULT` partition as a safety net (with the caveats noted above).

### 10. Edge cases
- A query that supplies **no value at all** for the partition key (e.g., `SELECT SUM(amount) FROM sales_fact`) still returns the fully correct answer — it just can't prune anything, and every partition is scanned (visible in `EXPLAIN` as an `Append` listing all children). Partitioning never changes correctness, only how much work is needed to get the correct answer.
- **`UPDATE`s that would move a row across a partition boundary** (e.g., `UPDATE sales_fact SET sale_date = '2025-01-15' WHERE sale_id = 123 AND sale_date = '2024-12-20'`) are supported since PostgreSQL 11: the engine transparently performs a delete from the old partition and an insert into the new one. This works, but it is measurably more expensive than a same-partition update (it can't use the fast in-place HOT update path), and if the row is referenced by a `BEFORE UPDATE ... FOR EACH ROW` trigger expecting a normal update, that trigger's semantics can be surprising — worth testing explicitly if your schema allows partition-key changes.
- A **unique or exclusion constraint on a partitioned table can only be enforced per-partition** — as explained above for the `sales_fact` primary key. Two rows in *different* partitions could theoretically share a `sale_id` if `sale_date` differed and you weren't careful about how you generate `sale_id` values; in practice `BIGSERIAL` sequences are shared and monotonically increasing across the whole partitioned table, so this doesn't occur in `analytics_db`, but it's a real constraint to understand when designing new partitioned tables from scratch.

---

## 26.4 List Partitioning

### 1. Simple explanation
List partitioning splits a table by a small, fixed set of discrete values instead of a continuous range — for example, one partition per region, or one partition per order status. "This partition holds exactly these values; that one holds exactly those."

### 2. Technical explanation
`PARTITION BY LIST (key_column)` declares that each partition owns an explicit, enumerated set of values for the partition key. Each partition is created with `FOR VALUES IN (value1, value2, ...)`. Unlike range partitioning, there's no notion of ordering or adjacency between partitions — each simply claims a literal list of values, and any value not claimed by any partition (and with no `DEFAULT` partition present) is rejected on insert, exactly like the range case.

### 3. Why it exists
Some data doesn't have a natural continuous order that matters for querying, but does have a small number of discrete categories that queries and retention policies both care about — geography, tenant tier, status codes, department. List partitioning lets you physically separate those categories (e.g., keep `region = 'North'` on fast local storage and `region = 'International'` on a cheaper tablespace) while still presenting one logical table.

### 4. Full syntax breakdown

Illustrative example built on the shape of `analytics_db.dim_store.region` (`North`, `South`, `East`, `West`, `Central`) — **not part of the canonical seed script**, shown here purely to teach the syntax:

```sql
CREATE TABLE sales_fact_by_region (
    sale_id      BIGSERIAL,
    sale_date    DATE NOT NULL,
    region       VARCHAR(50) NOT NULL,
    customer_key INT NOT NULL,
    amount       NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (sale_id, region)
) PARTITION BY LIST (region);

CREATE TABLE sales_fact_north   PARTITION OF sales_fact_by_region FOR VALUES IN ('North');
CREATE TABLE sales_fact_south   PARTITION OF sales_fact_by_region FOR VALUES IN ('South');
CREATE TABLE sales_fact_eastwest PARTITION OF sales_fact_by_region FOR VALUES IN ('East', 'West');
CREATE TABLE sales_fact_central PARTITION OF sales_fact_by_region FOR VALUES IN ('Central');
CREATE TABLE sales_fact_region_default PARTITION OF sales_fact_by_region DEFAULT;
```

- `PARTITION BY LIST (region)` — the partition key is a category column, not an orderable range.
- `FOR VALUES IN ('East', 'West')` — a single partition can claim **multiple discrete values**; this is the key structural difference from range partitioning, where each bound is a single contiguous span.
- `DEFAULT` — exactly as with range partitioning, catches any value (or `NULL`) not explicitly listed elsewhere; recommended unless you're certain the value set is closed and fully enumerated.

A second, equally realistic illustrative case adapted from `ecommerce_db.orders.status` (`PENDING`, `PAID`, `SHIPPED`, `DELIVERED`, `CANCELLED`):

```sql
CREATE TABLE orders_partitioned (
    order_id   BIGSERIAL,
    user_id    INT NOT NULL,
    order_date TIMESTAMP NOT NULL DEFAULT now(),
    status     VARCHAR(20) NOT NULL,
    PRIMARY KEY (order_id, status)
) PARTITION BY LIST (status);

CREATE TABLE orders_active    PARTITION OF orders_partitioned FOR VALUES IN ('PENDING', 'PAID', 'SHIPPED');
CREATE TABLE orders_delivered PARTITION OF orders_partitioned FOR VALUES IN ('DELIVERED');
CREATE TABLE orders_cancelled PARTITION OF orders_partitioned FOR VALUES IN ('CANCELLED');
```

This groups the "still in motion" statuses together (queried constantly by fulfillment dashboards), isolates `DELIVERED` (the largest, coldest bucket — most historical orders end here), and isolates `CANCELLED` (small, rarely queried, easy to purge on its own schedule).

> **⚠️ Warning**
> List-partitioning by a mutable column like `status` means an `UPDATE ... SET status = 'DELIVERED'` moves the row between partitions (delete + insert, as discussed for range partitioning). If a column changes value frequently, list partitioning on it can generate a steady stream of cross-partition row movement — usually range partitioning on an immutable or append-only column (like `order_date`) is the better real-world choice for `orders`, with `status` remaining an ordinary indexed column instead of a partition key.

### 5. Expected behavior / pruning
```sql
EXPLAIN
SELECT * FROM orders_partitioned WHERE status = 'CANCELLED';
```
```text
-- Illustrative
                       QUERY PLAN
---------------------------------------------------------
 Seq Scan on orders_cancelled orders_partitioned
   Filter: (status = 'CANCELLED'::text)
```

Only `orders_cancelled` appears — `orders_active` and `orders_delivered` are pruned because their declared value lists can't possibly satisfy `status = 'CANCELLED'`.

### 6. Common mistakes / edge cases
- Assuming list partitioning gives you range-style pruning for inequality queries. `WHERE status > 'PAID'` makes no sense for a list-partitioned string column the way `WHERE sale_date > '2024-01-01'` does for a range-partitioned date — list partitions have no ordering relationship to each other, so only equality (and `IN`) predicates on the partition key prune effectively.
- Forgetting a `DEFAULT` partition when the value set is genuinely open-ended (free-text categories, user-supplied tags) — any unanticipated value fails the insert.
- Choosing a list key with far more distinct values than practical partitions (e.g., partitioning by `customer_key` with 5,000 distinct values as 5,000 list partitions) — that's a sign you actually want hash partitioning instead, not an ever-growing list.

---

## 26.5 Hash Partitioning

### 1. Simple explanation
Hash partitioning doesn't try to give partitions business meaning at all — it runs the partition key through a hash function and uses the result purely to spread rows evenly across a fixed number of buckets. It's for when you want the *storage/write* benefits of partitioning (smaller pieces, parallel maintenance) but have no natural range or short list to partition by.

### 2. Technical explanation
`PARTITION BY HASH (key_column)` declares that PostgreSQL computes an internal hash of the partition key for each row and assigns it to a partition based on `MODULUS`/`REMAINDER` values declared on each partition — conceptually, `hash(key) % MODULUS = REMAINDER`. All partitions must share the same `MODULUS` (the total bucket count) and each must claim a distinct `REMAINDER` from `0` to `MODULUS - 1`.

### 3. Why it exists
Some very large tables have no column with a small natural value set (`LIST`) and no meaningful ordering that matches query patterns (`RANGE`) — a classic case is a multi-tenant table keyed by `tenant_id` with tens of thousands of tenants of wildly uneven size, where you just want roughly equal-sized partitions to bound each partition's disk footprint and to parallelize maintenance, without expressing any business rule about which tenants go where.

### 4. Full syntax breakdown

Illustrative example: distributing `sales_fact` writes evenly by `customer_key` purely for storage-balancing (not how the canonical seed data is actually organized — `analytics_db.sales_fact` uses range partitioning by design, since time-based retention is the real requirement here):

```sql
CREATE TABLE sales_fact_by_customer (
    sale_id      BIGSERIAL,
    sale_date    DATE NOT NULL,
    customer_key INT NOT NULL,
    amount       NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (sale_id, customer_key)
) PARTITION BY HASH (customer_key);

CREATE TABLE sales_fact_hash_0 PARTITION OF sales_fact_by_customer
    FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE sales_fact_hash_1 PARTITION OF sales_fact_by_customer
    FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE sales_fact_hash_2 PARTITION OF sales_fact_by_customer
    FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE sales_fact_hash_3 PARTITION OF sales_fact_by_customer
    FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

- `PARTITION BY HASH (customer_key)` — the partition key feeds an internal hash function; you never see or control the hash values directly.
- `FOR VALUES WITH (MODULUS 4, REMAINDER n)` — four partitions total, each owning one of the four possible remainders when the hash is divided by 4. `customer_key = 1732` always routes to the same partition (hashing is deterministic), but which one is not something you can predict or choose from the value alone.

### 5. Key limitation — why hash partitioning does not prune like range/list

```sql
EXPLAIN SELECT * FROM sales_fact_by_customer WHERE customer_key = 4821;
```
```text
-- Illustrative
                       QUERY PLAN
---------------------------------------------------------
 Seq Scan on sales_fact_hash_2 sales_fact_by_customer
   Filter: (customer_key = 4821)
```

An **exact-match** predicate on the hash key does prune to one partition, because PostgreSQL can compute the same hash and know exactly which partition would hold that value. But that's the *only* predicate shape that prunes:

```sql
EXPLAIN SELECT * FROM sales_fact_by_customer WHERE customer_key BETWEEN 4000 AND 5000;
```
```text
-- Illustrative — every partition is scanned
                       QUERY PLAN
---------------------------------------------------------
 Append
   ->  Seq Scan on sales_fact_hash_0 ... Filter: (customer_key BETWEEN 4000 AND 5000)
   ->  Seq Scan on sales_fact_hash_1 ... Filter: (customer_key BETWEEN 4000 AND 5000)
   ->  Seq Scan on sales_fact_hash_2 ... Filter: (customer_key BETWEEN 4000 AND 5000)
   ->  Seq Scan on sales_fact_hash_3 ... Filter: (customer_key BETWEEN 4000 AND 5000)
```

A range of `customer_key` values hashes to scattered, unpredictable partitions — there is no relationship between numeric or lexical closeness of keys and hash-bucket membership, by design (that's exactly what makes the distribution *even*). This is the central trade-off: **hash partitioning buys you even storage/write distribution across a fixed number of pieces, at the cost of pruning for any predicate other than an exact match on the partition key.** Use it only when your actual query pattern really is dominated by exact-match lookups on that key (or when the goal is purely operational — bounding partition size, parallelizing `VACUUM`/backup — and query pruning was never the point).

---

## 26.6 Partition Pruning — the Mechanism, Precisely

### Simple explanation
Pruning is the planner looking at your `WHERE` clause and each partition's declared boundaries, and refusing to even open the partitions that mathematically cannot contain a matching row.

### Technical explanation
PostgreSQL performs pruning at two possible stages:

- **Static (planning-time) pruning** — when the filter value is a constant known while building the plan (e.g., a literal `'2024-06-01'`, or a value substitutable before planning), the planner compares it directly against each partition's stored bound and drops non-matching partitions from the plan tree entirely. This is what you saw in the `sales_fact` `EXPLAIN` example above — no `Append` branch for `sales_fact_2022`/`sales_fact_2023` ever appeared in the plan.
- **Dynamic (runtime) pruning** — available since **PostgreSQL 11**, used when the filter value isn't known until execution: a bind parameter in a prepared statement, a value coming from a subquery, or a value supplied per-row from the outer side of a nested-loop join (e.g., joining `sales_fact` to a filtered `dim_date` and pushing each qualifying `date_key` down as a join condition). In these cases the `Append`/`Merge Append` node is still built with all partitions listed at plan time, but at execution time, before actually scanning each child, the executor re-checks whether the now-known value could match that child's bounds, and skips the scan node entirely if not.

Either way, the effect is the same: partitions outside the possible range are never opened, never have their buffers touched, and cost nothing beyond a cheap boundary comparison.

### Concrete before/after at `analytics_db` scale

| | Query: `WHERE sale_date >= '2024-06-01'` |
|---|---|
| **Partitioned `sales_fact`** | Planner statically eliminates `sales_fact_2022` and `sales_fact_2023` (~3.33M rows total, never touched). Scans only `sales_fact_2024` (~1.67M rows), applying the residual date filter within that one partition to reach the ~971,667 true matches. |
| **Unpartitioned equivalent (5M rows, one table)** | Must consult one B-tree index (or full scan) covering all 5,000,000 rows to find the same ~971,667 matches — deeper index, larger working set, worse cache locality, no way to skip any physical region of the table structurally. |

The relative gap (illustrative timings shown earlier: ~300 ms pruned vs. ~1.7 s unpartitioned) grows, not shrinks, as total data volume grows into tens of millions of rows while each yearly partition stays roughly the same manageable size.

> **Important Note**
> Pruning is a planner/executor optimization, not a correctness mechanism. A poorly chosen partition key, or a query that filters on a column other than the partition key, still returns the right answer — it simply gets none of the pruning benefit and degrades toward "scan every partition," which is roughly equivalent to (or, due to per-partition overhead, sometimes marginally worse than) querying one unpartitioned table.

---

## 26.7 Partition Maintenance

### Adding partitions ahead of time
The single most important operational habit with range-partitioned time-series tables: **never let "today" get ahead of your last declared partition.** A realistic scheduled job (via `pg_cron`, an external scheduler, or an application maintenance task) for `sales_fact`:

```sql
-- Run monthly (or yearly), well before the boundary is needed.
DO $$
DECLARE
    next_year INT := EXTRACT(YEAR FROM now())::INT + 1;
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS sales_fact_%s PARTITION OF sales_fact
             FOR VALUES FROM (%L) TO (%L)',
        next_year,
        (next_year || '-01-01')::date,
        ((next_year + 1) || '-01-01')::date
    );
END $$;
```

This guarantees a partition for next year always exists before any application code tries to insert into it.

### Detaching a partition (archiving)
```sql
ALTER TABLE sales_fact DETACH PARTITION sales_fact_2022;
```

`sales_fact_2022` is not destroyed — it becomes an ordinary, standalone table, completely independent of `sales_fact`, still holding all ~1.67 million of its rows. This is the archiving pattern: detach, then optionally move the now-standalone table to cheaper storage (`ALTER TABLE sales_fact_2022 SET TABLESPACE cold_storage;`), export it (`pg_dump -t sales_fact_2022`), or simply leave it queryable on its own for compliance/audit purposes without it costing the live `sales_fact` table anything.

> **[PostgreSQL]** Since **PostgreSQL 14**, `ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY` performs the detach without holding a long-lived `ACCESS EXCLUSIVE` lock on the parent, which matters on a busy production table receiving continuous writes.

### Attaching a partition
```sql
ALTER TABLE sales_fact ATTACH PARTITION sales_fact_2022
    FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
```

By default, PostgreSQL must **scan the entire table being attached** to verify every existing row actually satisfies the declared partition bound — it has no other way to be sure a "detached and now being reattached" (or manually created) table doesn't contain rows for `2021-12-31`. On a 1.67-million-row table, that's a real, measurable scan.

**Skipping the validation scan:** if the table already has a `CHECK` constraint that exactly implies the partition bound, PostgreSQL recognizes that the constraint already proves the invariant and skips the scan entirely:

```sql
ALTER TABLE sales_fact_2022
    ADD CONSTRAINT sales_fact_2022_date_check
    CHECK (sale_date >= '2022-01-01' AND sale_date < '2023-01-01');

ALTER TABLE sales_fact ATTACH PARTITION sales_fact_2022
    FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
-- No full-table scan: the CHECK constraint above already guarantees the bound.
```

This is standard practice for a zero-downtime "bulk load into a standalone table, validate with a matching `CHECK`, then attach" workflow — load and index a new partition's data at leisure with no locking pressure on the live parent, then attach it as a fast, scan-free metadata operation, and finally drop the now-redundant `CHECK` constraint if desired (the partition bound itself continues to enforce the same invariant).

### Dropping partitions for retention
```sql
DROP TABLE sales_fact_2022;
```

Concretely, at the end of 2025, a retention policy of "keep three years of sales history" means: drop the 2022 partition instantly to retire ~1.67 million rows, instead of running:

```sql
DELETE FROM sales_fact WHERE sale_date < '2023-01-01';
```

The `DELETE` version would scan and mark ~1.67 million rows dead, generate a proportional volume of WAL, update every index entry for every deleted row, leave behind bloat that `VACUUM` then has to reclaim over a separate, possibly long-running pass, and hold locks/consume I/O for the entire duration — realistically minutes to hours depending on hardware and concurrent load. `DROP TABLE sales_fact_2022` (or `DETACH` followed by `DROP TABLE` on the now-standalone table) is a catalog-level operation that completes in milliseconds regardless of how many rows the partition holds, because it never has to look at the rows individually — it just removes the file and the catalog entry.

---

## 26.8 Partition Indexes

### How indexes work on partitioned tables
Since **PostgreSQL 11**, you can run `CREATE INDEX` against the *parent* table:

```sql
CREATE INDEX idx_sales_fact_sale_date ON sales_fact (sale_date);
```

PostgreSQL automatically creates a matching index on every existing partition (`sales_fact_2022`, `sales_fact_2023`, `sales_fact_2024`) and records the definition against the parent so that **every future partition you attach or create gets the same index automatically**, with no extra step. `\d sales_fact` shows this as an index on the parent that is explicitly marked as covering all partitions; `\d sales_fact_2024` shows the concrete, real, individually-usable index that actually exists on that one partition's storage.

```sql
CREATE INDEX idx_sales_fact_customer2 ON sales_fact (customer_key);
```
```text
-- Under the hood, three (or however many exist) real indexes are created:
--   sales_fact_2022_customer_key2_idx
--   sales_fact_2023_customer_key2_idx
--   sales_fact_2024_customer_key2_idx
-- plus a catalog-only "partitioned index" entry tying them together.
```

### No true global index
This is a meaningful limitation to understand precisely: **PostgreSQL does not support a single index structure spanning rows from multiple partitions.** What you get from `CREATE INDEX ON sales_fact (...)` is convenient syntax for creating and managing *N* separate local indexes, one per partition — not one combined B-tree. A query that can prune to a single partition benefits fully (it just uses that partition's local index, exactly as if it were a normal indexed table). A query that *cannot* prune (no filter on the partition key) has to consult every partition's local index separately and merge/append the results — there is no shortcut single index the planner could use instead.

> **Important Note**
> This is precisely why choosing a partition key aligned with real query patterns matters so much: with local-only indexes, a query that can't prune pays the cost of N separate index probes instead of one, which is strictly worse than a single unpartitioned index for that particular access pattern.

### Cross-dialect comparison

| Dialect | Global partitioned index? | Notes |
|---|---|---|
| **[PostgreSQL]** | No — local indexes only, one real index per partition, managed collectively via parent-level `CREATE INDEX` syntax (PG11+) | Simple mental model, but any non-prunable query pays a per-partition index-probe cost |
| **[Oracle]** | Yes — Oracle has long supported both **global partitioned indexes** (one logical index structure spanning all partitions, itself independently partitioned or not) and **local partitioned indexes** (one index segment per table partition, Oracle's default recommendation for most cases) | Global indexes can serve non-prunable queries more efficiently than N local lookups, at the cost of extra maintenance complexity when partitions are dropped/exchanged (a global index typically needs a rebuild or `UPDATE GLOBAL INDEXES` after partition maintenance) |
| **[MySQL]** | No native global index either, and historically far more restrictive: **every unique key (including the primary key) on a partitioned table was required to include all columns of the partition key** — you could not freely define an independent unique constraint the way `sales_fact`'s `PRIMARY KEY (sale_id, sale_date)` pattern feels natural in PostgreSQL, without deliberately designing around it | This restriction has eased somewhat in newer MySQL/InnoDB versions for certain partition types, but the historical rule is a real, frequently-tested limitation worth knowing |
| **[SQL Server]** | Effectively local, via **partition functions** (define the boundary points) and **partition schemes** (map partitions to filegroups); indexes are "aligned" to the same partition scheme as the table by default, giving local-index-like behavior; genuinely global (non-aligned) indexes are possible but lose some partition-maintenance benefits (e.g., `SWITCH PARTITION` requires alignment) | The two-step partition function + partition scheme syntax is SQL Server's distinguishing feature versus PostgreSQL's single `PARTITION BY` clause |

---

## 26.9 Range vs. List vs. Hash — Choosing a Strategy

| | Range | List | Hash |
|---|---|---|---|
| **Partition key nature** | Continuous, orderable (dates, numeric sequences) | Small, discrete, enumerable set of values | Any value with no useful natural range or short enumerable list |
| **Typical use case** | Time-series retention (`sales_fact` by `sale_date`) | Region, status, category, tenant tier | Even write/storage distribution, e.g., high-cardinality `tenant_id` |
| **Pruning for inequality queries** (`>`, `<`, `BETWEEN`) | Yes, this is the primary benefit | No (values aren't ordered across partitions) | No |
| **Pruning for equality queries** (`=`) | Yes | Yes | Yes (exact match on the hash key only) |
| **Adding a new partition to catch new values** | Common and expected (next year, next month) | Common when new categories appear | Not meaningful — the bucket count (`MODULUS`) is fixed by design; changing it requires reorganizing all partitions |
| **Risk of insert failure for unhandled values** | Yes, unless a `DEFAULT` partition exists | Yes, unless a `DEFAULT` partition exists | No — every possible hash value always maps to exactly one of the fixed partitions |

---

## 26.10 Partitioning vs. Just Adding More Indexes

Partitioning is not a replacement for indexing — you still index within each partition, exactly as shown in Section 26.8. The real question is *when partitioning is worth adding on top of good indexing*.

| Signal | Lean toward... |
|---|---|
| Table has a few hundred thousand to a few million rows, a good index already makes queries fast, and there's no retention/archival requirement | **Just index well.** Partitioning adds real operational complexity (partition-aware DDL, maintenance jobs, careful key selection) that isn't justified yet. |
| Table is tens of millions of rows and growing, with clear time-based (or tenant-based) access patterns that align with a natural partition key | **Partition.** Indexes alone won't help you *drop* old data cheaply, and a single index over that many rows starts showing real depth/cache-locality costs. |
| Hard regulatory/business requirement to retain exactly N years/months of data and purge the rest | **Partition**, regardless of raw row count — `DROP TABLE`-speed retention is the deciding factor here even before performance becomes an issue. |
| Query patterns are unpredictable/ad hoc across many columns, with no dominant filter column | **Just index (with care) — and reconsider whether any single column is really the "natural" partition key.** A poorly matched partition key that never enables pruning is worse than no partitioning: extra planning overhead, extra DDL complexity, no upside. |

> **Important Note**
> A practical rule of thumb echoed across most production PostgreSQL guidance: partitioning tends to pay off once a table is in the **tens of millions of rows** range (or will predictably get there), or whenever retention-by-time-range is a hard requirement regardless of size. Below that, a well-designed index (Chapter 16) usually delivers most of the performance benefit with none of the operational overhead.

---

## 26.11 Real-World Use Cases

- **Time-series / transactional fact tables** — exactly `sales_fact`: partition by date, keep a rolling window (e.g., 3 years) hot, archive or drop older partitions on a schedule.
- **Event/log tables** — `analytics_db.events` (tackled in the chapter challenge below): high insert volume, queries almost always scoped to a recent time window, natural monthly/quarterly retention policy.
- **Multi-tenant SaaS data** — partitioning a shared table by `tenant_id` (list, if tenant count is small and stable; hash, if tenant count is large and you mainly want even storage distribution and per-tenant maintenance isolation rather than query pruning).
- **Audit/compliance tables** — range-partitioned by date specifically because regulations often specify an exact retention period, making "drop the whole partition on the exact day it ages out" the cleanest possible implementation of the legal requirement.

---

## 26.12 Practice Questions

1. Explain, in terms of half-open intervals, why `sales_fact_2023 FOR VALUES FROM ('2023-01-01') TO ('2024-01-01')` correctly excludes a row with `sale_date = '2024-01-01'`.
2. Write the `CREATE TABLE ... PARTITION OF` statement for a `sales_fact_2026` partition, assuming the table's current structure.
3. Without a `DEFAULT` partition, what error do you get inserting a `sales_fact` row with `sale_date = '2030-01-01'`? What changes if a `DEFAULT` partition exists?
4. Why must `sales_fact`'s primary key be `(sale_id, sale_date)` rather than just `(sale_id)`?
5. Given `WHERE sale_date >= '2023-06-01' AND sale_date < '2024-03-01'`, which of `sales_fact_2022`, `sales_fact_2023`, `sales_fact_2024` would a correctly functioning planner prune, and which would it still need to scan?
6. Explain the difference between static and dynamic (runtime) partition pruning, and give an example query against `sales_fact` joined to `dim_date` where dynamic pruning would matter.
7. Why doesn't `WHERE customer_key BETWEEN 100 AND 200` prune effectively against a table hash-partitioned on `customer_key`, even though it prunes fine against a range-partitioned table on an ordered key?
8. What is the practical difference between `DROP TABLE sales_fact_2022` and `ALTER TABLE sales_fact DETACH PARTITION sales_fact_2022`?
9. Why does attaching a partition normally trigger a full validation scan, and what specific step avoids that scan?
10. A colleague proposes partitioning `sales_fact` into 1,095 daily partitions "for maximum pruning." What are the downsides of this design compared to the existing 3 yearly partitions?
11. Describe a query against `sales_fact` that would receive **no** pruning benefit at all despite the table being range-partitioned by `sale_date`. Why not?
12. Compare `CREATE INDEX ON sales_fact (customer_key)` under PostgreSQL's local-index-only model to Oracle's global partitioned index — what specific capability does Oracle offer that PostgreSQL doesn't?
13. What real operational complication does an `UPDATE` that changes `sale_date` across a partition boundary introduce, beyond simply "the row moves"?

---

## 26.13 Chapter-Ending Challenge

`analytics_db.events` is currently **unpartitioned**:

```sql
CREATE TABLE events (
    event_id    BIGSERIAL PRIMARY KEY,
    user_id     INT NOT NULL,
    event_type  VARCHAR(30) NOT NULL,     -- 'SIGNUP','LOGIN','PURCHASE','CHURN'
    event_time  TIMESTAMP NOT NULL,
    payload     JSONB
);
```

It's seeded with 200,000 rows today, but in production an events table like this grows continuously and indefinitely — realistically toward hundreds of millions of rows over a couple of years, with almost every query scoped to a recent time window ("events in the last 7 days," "signups this month").

**Design a complete partitioning + retention strategy:**

1. **Choose a partition key and scheme**, and justify it against the access pattern above (compare range vs. list vs. hash for this specific table before settling on one).
2. **Write the DDL** to stand up a correctly partitioned replacement table — including why `event_id BIGSERIAL PRIMARY KEY` alone cannot remain the primary key once partitioned, what the corrected primary key must look like, and at least the first few concrete partitions (pick a granularity — monthly is a reasonable default for this challenge — and justify it against the "too many tiny partitions" mistake from Section 26.3).
3. Address the fact that **PostgreSQL cannot convert an existing plain table into a partitioned table in place** — describe (in DDL and/or precise steps) how you would actually perform this migration on a live table with zero acceptable data loss, ideally minimizing write downtime (hint: create the new partitioned table under a temporary name, backfill historical data partition by partition using the `CHECK`-constraint-skips-validation-scan trick from Section 26.7, then cut over).
4. **Describe a monthly maintenance job** (pseudocode or a `DO $$ ... $$` block is fine) that: (a) creates the partition for the month after next, so writes never fail; (b) drops (or detaches and archives) any partition older than 2 years, implementing the retention policy.
5. State explicitly what happens to a query like `SELECT * FROM events WHERE user_id = 4821` under your chosen scheme — does it prune, and if not, what would you add (an ordinary index, not a repartitioning) to keep that query fast anyway?

---

## Key Takeaways

- Partitioning splits one logical table into multiple real, independent physical tables (partitions), routed to transparently for almost all SQL operations; the parent table itself normally holds zero rows.
- **Range partitioning** (`sales_fact` by `sale_date`) is the workhorse for time-series data: half-open `FOR VALUES FROM ... TO ...` bounds tile the domain with no gaps or overlaps, enabling both query-time pruning and instant `DROP TABLE`-based retention.
- **List partitioning** groups a small, discrete set of known values per partition; it prunes well for equality/`IN` predicates but has no useful ordering between partitions.
- **Hash partitioning** spreads rows evenly across a fixed number of buckets purely for storage/write balance; it only prunes for exact-match predicates on the partition key, never for ranges.
- **Partition pruning** — static at planning time, dynamic at execution time (PG11+) — is the core performance payoff: partitions that structurally cannot match the `WHERE` clause are never opened.
- **Dropping/detaching a partition** turns a slow, resource-intensive `DELETE` of millions of rows into a near-instant catalog operation — the single biggest, most concrete operational win of partitioning.
- Indexes on a partitioned table (PostgreSQL) are local to each partition; `CREATE INDEX` on the parent is convenience syntax that creates and manages one real index per partition (current and future), not a true global index — unlike Oracle's global partitioned indexes.
- Partitioning pays off at real scale (tens of millions of rows and up) or under a hard time-based retention requirement; below that, a well-designed index usually wins on the complexity/benefit trade-off.
- The most common real-world partitioning mistake isn't choosing the wrong strategy — it's picking a partition key that doesn't match actual query filters, or forgetting to pre-create future partitions until an insert fails in production.

---

## What's Next

Chapter 27 moves from *how data is physically organized* to *who is allowed to touch it*: roles, privilege grants, row-level security policies, and the practical defenses against SQL injection — the security model that sits on top of every table (partitioned or not) you've built so far.

**Next: [Chapter 27 — Security (Roles, Grants, RLS, Injection)](27-security.md)**
