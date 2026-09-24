# Project 4 — Large-Scale Analytics & Performance Engineering

> **Part VII — Applied Mastery** · [Chapter 32 — Real-World Projects](README.md) ·
> Project 4 of 4 · Previous: [Project 3 — E-Commerce Database](03-ecommerce.md)

> **Where this project fits.** Projects 1–3 built and queried
> hand-seeded, human-scale schemas (16 employees, a few hundred orders).
> This project does the opposite: it takes a schema you cannot eyeball your
> way through — **`analytics_db`**, with a `sales_fact` table holding roughly
> **five million rows**, RANGE-partitioned by `sale_date`, plus a 200,000-row
> `events` table — and asks the question every production analytics team
> eventually asks: *"why is this dashboard slow, and what do I actually do
> about it?"* Every technique here was taught earlier in the course
> (Chapters 4, 10, 15, 16, 17, 18, 26, and 31); this project is where they
> stop being separate topics and become one integrated skill: **performance
> engineering**.

> **⚠️ Warning — read this before anything else.** `analytics_db` is
> **programmatically generated** using `generate_series()` and `random()`
> (see the file header of `databases/analytics_db.sql`). That means every
> aggregate value, every "top product," every specific row count you get
> when you actually run these queries **will differ from the numbers printed
> in this document, and will even differ between two runs of the seed script
> on two different machines.** This document is scrupulous about labeling
> every concrete number as one of two kinds:
>
> - **REAL** — the schema, the DDL, the query logic, the index definitions,
>   the *mechanism* by which a fix works, and the *relative* direction of an
>   improvement (e.g., "an index scan touching 30,000 rows is faster than a
>   sequential scan touching 1.6 million rows" is real and always true,
>   regardless of which 30,000 rows they happen to be).
> - **ILLUSTRATIVE** — specific `EXPLAIN ANALYZE` costs, timings, row counts,
>   and specific aggregate dollar values. These are plausible, internally
>   consistent numbers *at the stated scale*, shown so you can see the
>   *shape* of a real plan and a real performance win — not numbers you
>   should expect to reproduce exactly.
>
> Every `EXPLAIN ANALYZE` block below is labeled `-- ILLUSTRATIVE` in its
> heading. Everything else — the CREATE INDEX statements, the CREATE
> MATERIALIZED VIEW statement, the partition DDL, the rewritten queries — is
> real, runnable SQL against the real `analytics_db` schema.

---

## 0. Setup — this project builds *on top of* the existing schema

This project does **not** redefine `dim_date`, `dim_customer`, `dim_product`,
`dim_store`, `sales_fact`, or `events`. It uses them exactly as created by
`databases/analytics_db.sql`. Load it first if you haven't already:

```bash
psql -f databases/analytics_db.sql
```

```sql
SET search_path TO analytics_db;
```

> **⚠️ Warning.** The seed script inserts **5,000,000** rows into
> `sales_fact` using `generate_series`. On modest hardware this can take
> several minutes and a few GB of disk. The file header itself suggests
> shrinking `generate_series(1, 5000000)` to `generate_series(1, 200000)`
> for local experimentation. All of the *query logic and index/partition
> reasoning* in this project is scale-independent — reduce the row count
> freely for a faster local loop, but keep the illustrative `EXPLAIN`
> numbers in mind as describing the **full 5-million-row** scale, which is
> the scale this project is designed to reason about.

### 0.1 Schema recap (verbatim from `analytics_db.sql` — not redefined here)

For reference, the objects this project builds on:

| Table | Rows (approx., illustrative) | Key columns | Notes |
|---|---|---|---|
| `dim_date` | 1,461 | `date_key` (PK), `year`, `quarter`, `month`, `day`, `day_of_week`, `is_weekend` | 2022-01-01 → 2025-12-31 |
| `dim_customer` | 5,000 | `customer_key` (PK), `segment` (`CONSUMER`/`BUSINESS`/`ENTERPRISE`), `signup_date`, `country` | |
| `dim_product` | 200 | `product_key` (PK), `category` (10 values), `unit_cost` | |
| `dim_store` | 25 | `store_key` (PK), `region` (`North`/`South`/`East`/`West`/`Central`) | |
| `sales_fact` | ~5,000,000 | `sale_id` + `sale_date` (composite PK), `customer_key`, `product_key`, `store_key`, `quantity`, `amount` | **RANGE partitioned by `sale_date`** into `sales_fact_2022`, `sales_fact_2023`, `sales_fact_2024` — see Chapter 26 |
| `events` | ~200,000 | `event_id` (PK), `user_id`, `event_type` (`SIGNUP`/`LOGIN`/`PURCHASE`), `event_time`, `payload jsonb` | Existing composite index `idx_events_user_time (user_id, event_time)` |

> **Important Note.** The `events` seed data only ever generates
> `SIGNUP`, `LOGIN`, and `PURCHASE` rows (look closely at the `VALUES`
> list in the seed script's `LATERAL` join — `CHURN` is mentioned in the
> column comment as a *possible* value the column is designed to hold, but
> the generator never actually inserts one). The cohort/retention report in
> §4.5 is written around that reality: it infers "did this user come back"
> from the *presence or absence* of later activity rows, not from an
> explicit `CHURN` event — which, incidentally, is exactly how most
> real-world retention analysis works, since "the user left" is almost
> always an absence, not an event.

Existing indexes already created by the seed script (do not recreate them):

```sql
-- already exist — from analytics_db.sql
CREATE INDEX idx_sales_fact_customer ON sales_fact (customer_key);
CREATE INDEX idx_sales_fact_product  ON sales_fact (product_key);
CREATE INDEX idx_events_user_time    ON events (user_id, event_time);
```

Notice what's conspicuously **missing**: there is no index on `sale_date`
alone (the partition key), no index on `store_key`, and the fact table's
primary key is the composite `(sale_id, sale_date)` — keyed first by
`sale_id`, which is useless for range-scanning on date. This gap is not an
oversight to fix immediately; it's the starting point for §2–§3, where we
diagnose exactly which of these gaps matter and add only the indexes that
earn their keep.

---

## 1. Project Brief

**Client:** Meridian Retail Group, a mid-size multi-region retail chain.

**Situation.** Meridian's BI team has just finished migrating three years of
point-of-sale history and a year of app/web event logs into a single
PostgreSQL analytics database (the schema above). Store managers, regional
VPs, and the marketing team all want dashboards and reports built directly
on top of it. The first prototype dashboard — built by an analyst who is
excellent at SQL correctness but has never had to think about scale —
technically returns correct numbers, but several of its queries take
30–90 seconds against production data, and one "recent orders" admin screen
gets *slower every time the support team pages further into it*. Your job,
as the engineer taking this to production, is to keep every query
**correct** while making the whole system **fast enough for interactive
dashboards** — and to leave behind a maintenance plan so it *stays* fast as
data keeps arriving.

### 1.1 Functional requirements

| # | Requirement | Cross-reference |
|---|---|---|
| FR-1 | Monthly and quarterly revenue trend dashboard, including year-over-year (YoY) and month-over-month (MoM) growth | Ch. 10 (Window Functions) |
| FR-2 | "Top N" leaderboards — top products, top stores, top customers by revenue, with explicit rank | Ch. 10 |
| FR-3 | Customer segmentation report: revenue and share-of-revenue broken down by `dim_customer.segment` | Ch. 6, 10 |
| FR-4 | Regional performance comparison across `dim_store.region`, including top products *per* region | Ch. 7, 10 |
| FR-5 | Retention / cohort-style analysis of user activity from the `events` table | Ch. 31 (Advanced Patterns — cohort analysis) |
| FR-6 | A "recent activity" feed over `sales_fact` that supports paging arbitrarily deep (page 1 through page 10,000+) **without** getting slower as the user pages further | Ch. 4 (keyset pagination) |
| FR-7 | An existing slow ad-hoc regional/YoY report must be diagnosed with `EXPLAIN ANALYZE` and fixed — not rewritten from scratch, *fixed*, so the diagnostic process itself is reusable | Ch. 17 (Query Planner) |
| FR-8 | A data retention policy: sales history older than a configurable number of years is dropped on a schedule, without a multi-hour `DELETE` | Ch. 26 (Partitioning) |
| FR-9 | Dashboard queries must not re-scan the 5-million-row fact table on every page load; pre-aggregated summaries must be available and kept reasonably fresh | Ch. 15 (Materialized Views) |
| FR-10 | The system must be ready to accept 2025 sales data on day one of 2025 — partition maintenance must happen *ahead of* need, not reactively after inserts start failing | Ch. 26 |

### 1.2 Non-functional requirements

- **NFR-1 (latency):** Interactive dashboard queries (FR-1 through FR-4)
  should target well under one second once indexes/materialized views are in
  place, regardless of the fact table's total size.
- **NFR-2 (pagination flatness):** The "recent activity" feed (FR-6) must
  have **flat** latency — page 50 must not be meaningfully slower than
  page 5,000.
- **NFR-3 (write availability):** None of the read-side fixes in this
  project (indexes, materialized views, partition maintenance) may require
  taking `sales_fact` offline for writes for an extended period.
- **NFR-4 (data growth):** All designs must assume `sales_fact` keeps
  growing — a fix that works at 5 million rows but degrades linearly with
  table size is not an acceptable fix.

---

## 2. Baseline Queries and the Performance Problem

This section presents four real report queries as Meridian's analyst first
wrote them. All four are logically correct — they return the right answer —
and all four have a specific, diagnosable performance defect. We look at
each one's (illustrative) `EXPLAIN ANALYZE` output before touching anything.

> **Important Note.** In every plan below, `sales_fact` is queried through
> the **parent (partitioned) table**. PostgreSQL always shows an `Append`
> (or `Merge Append`) node over the child partitions for a partitioned
> table scan — that Append node, and which of the three partitions appear
> underneath it, is precisely what we're inspecting in each case.

### 2.1 Query A — the weekly flash-sale performance report

Regional managers want revenue by region for a specific promotional week —
a narrow date filter, but currently written to filter and aggregate however
the analyst first thought of it:

```sql
-- Query A (baseline) — revenue by region for a single promotional week
SELECT ds.region,
       SUM(sf.amount) AS week_revenue,
       COUNT(*)       AS transactions
FROM sales_fact sf
JOIN dim_store ds ON ds.store_key = sf.store_key
WHERE sf.sale_date BETWEEN DATE '2024-06-10' AND DATE '2024-06-16'
GROUP BY ds.region
ORDER BY week_revenue DESC;
```

A 7-day window is roughly 7/365 ≈ **1.9%** of one partition's rows. This
*should* be a query that touches a few tens of thousands of rows and
returns in milliseconds. Because there is no index on `sale_date`, it
doesn't.

```text
-- ILLUSTRATIVE EXPLAIN ANALYZE — Query A, BEFORE any fix
HashAggregate  (cost=48213.40..48213.47 rows=5 width=48) (actual time=812.940..812.945 rows=5 loops=1)
  Group Key: ds.region
  ->  Hash Join  (cost=1.60..48117.85 rows=19110 width=40) (actual time=0.061..803.221 rows=30821 loops=1)
        Hash Cond: (sf.store_key = ds.store_key)
        ->  Append  (cost=0.00..47983.00 rows=19110 width=12) (actual time=0.030..789.664 rows=30821 loops=1)
              ->  Seq Scan on sales_fact_2024 sf  (cost=0.00..47892.50 rows=19108 width=12)
                                                    (actual time=0.029..782.110 rows=30821 loops=1)
                    Filter: ((sale_date >= '2024-06-10') AND (sale_date <= '2024-06-16'))
                    Rows Removed by Filter: 1636512
        ->  Hash  (cost=1.25..1.25 rows=25 width=36) (actual time=0.018..0.019 rows=25 loops=1)
              ->  Seq Scan on dim_store ds  (cost=0.00..1.25 rows=25 width=36) (actual time=0.005..0.009 rows=25 loops=1)
Planning Time: 0.412 ms
Execution Time: 813.109 ms
```

**What this shows (real mechanism, illustrative numbers):** the planner
correctly recognized that only the `sales_fact_2024` partition can possibly
contain rows in that date range (2024-06-10 is within `sales_fact_2024`'s
bounds; `sales_fact_2022` and `sales_fact_2023` are already excluded, so
you don't even see them in the plan — that part of partition pruning is
already working). But *within* that one ~1.67-million-row partition,
there is no way to jump directly to the matching rows, so PostgreSQL
performs a **Seq Scan**: it reads every single row in the partition and
throws away everything that doesn't match (`Rows Removed by Filter:
1636512`, illustrative). Reading and filtering 1.67 million rows to keep
30,000 is the entire cost of this query.

### 2.2 Query B — "customers earning above their segment's average revenue"

Marketing wants a list of over-performing customers within each segment,
and the analyst wrote it the way the English sentence reads — as a nested
correlated subquery:

```sql
-- Query B (baseline) — correlated subquery, evaluated once per customer
SELECT
    c.customer_key,
    c.customer_name,
    c.segment,
    (SELECT SUM(sf.amount)
     FROM sales_fact sf
     WHERE sf.customer_key = c.customer_key)                 AS customer_revenue
FROM dim_customer c
WHERE
    (SELECT SUM(sf.amount)
     FROM sales_fact sf
     WHERE sf.customer_key = c.customer_key)
    >
    (SELECT AVG(seg_total.seg_revenue)
     FROM (
         SELECT c2.customer_key, SUM(sf2.amount) AS seg_revenue
         FROM dim_customer c2
         JOIN sales_fact sf2 ON sf2.customer_key = c2.customer_key
         WHERE c2.segment = c.segment
         GROUP BY c2.customer_key
     ) AS seg_total)
ORDER BY c.segment, customer_revenue DESC;
```

This is logically correct, and it's exactly how a lot of people first learn
to express "compared to the group average." The problem is *how many times*
each subquery runs.

```text
-- ILLUSTRATIVE EXPLAIN ANALYZE — Query B, BEFORE any fix
Sort  (cost=9871442.10..9871454.60 rows=5000 width=76) (actual time=46201.552..46202.010 rows=1701 loops=1)
  Sort Key: c.segment, ((SubPlan 1))
  ->  Seq Scan on dim_customer c  (cost=0.00..9871123.50 rows=5000 width=76)
                                    (actual time=1.204..46188.903 rows=1701 loops=1)
        Filter: ((SubPlan 1) > (SubPlan 3))
        Rows Removed by Filter: 3299
        SubPlan 1
          ->  Aggregate  (cost=44.02..44.03 rows=1 width=32) (actual time=1.130..1.131 rows=1 loops=5000)
                ->  Index Scan using idx_sales_fact_customer on sales_fact sf
                      (cost=0.43..43.61 rows=1000 width=6) (actual time=0.020..0.812 rows=1000 loops=5000)
                      Index Cond: (customer_key = c.customer_key)
        SubPlan 3
          ->  Aggregate  (cost=1972.68..1972.69 rows=1 width=32) (actual time=7.930..7.931 rows=1 loops=5000)
                ->  HashAggregate  (cost=1958.35..1966.68 rows=1667 width=36)
                                     (actual time=7.201..7.658 rows=1667 loops=5000)
                      Group Key: c2.customer_key
                      ->  Hash Join  (cost=45.00..1841.68 rows=333333 width=10)
                                       (actual time=0.312..5.887 rows=333400 loops=5000)
                            Hash Cond: (sf2.customer_key = c2.customer_key)
                            ->  Seq Scan on sales_fact sf2 ...
                            ->  Hash ...  Seq Scan on dim_customer c2 ... Filter: (segment = c.segment)
Planning Time: 0.588 ms
Execution Time: 46203.771 ms
```

**What this shows (real mechanism, illustrative numbers):** look at
`loops=5000` on both `SubPlan 1` and `SubPlan 3`. `dim_customer` has 5,000
rows, and PostgreSQL is executing **both subqueries once per outer row** —
this is a *correlated* subquery, so it cannot be evaluated once and reused.
`SubPlan 1` is comparatively cheap (it can use `idx_sales_fact_customer`).
`SubPlan 3` is the real disaster: for **every one of the 5,000 customers**,
it re-aggregates the revenue of every customer *in that customer's
segment* — roughly 1,667 customers' worth of `sales_fact` rows, re-joined
and re-grouped from scratch, 5,000 separate times. The total work is
proportional to `customers × segment_size`, not `customers +
segment_size`, and it shows: an illustrative **46 seconds** for a report
that should be near-instant.

### 2.3 Query C — the "recent activity" admin feed, page 10,001

The support team's admin screen shows the most recent sales transactions,
newest first, with a "Next Page" button using classic `LIMIT`/`OFFSET`:

```sql
-- Query C (baseline) — OFFSET pagination, deep page
SELECT sale_id, sale_date, customer_key, product_key, store_key, amount
FROM sales_fact
ORDER BY sale_date DESC, sale_id DESC
LIMIT 50 OFFSET 500000;
```

Page 1 (`OFFSET 0`) of this query is fast. Page 10,001 (`OFFSET 500000`) —
which support agents reach constantly when investigating an old ticket — is
not.

```text
-- ILLUSTRATIVE EXPLAIN ANALYZE — Query C, BEFORE any fix (deep page)
Limit  (cost=612340.10..612340.16 rows=50 width=40) (actual time=1428.204..1428.221 rows=50 loops=1)
  ->  Sort  (cost=598840.10..611090.35 rows=4900100 width=40) (actual time=1180.552..1417.866 rows=500050 loops=1)
        Sort Key: sales_fact.sale_date DESC, sales_fact.sale_id DESC
        Sort Method: top-N heapsort  Memory: 32104kB
        ->  Append  (cost=0.00..142983.00 rows=4900100 width=40) (actual time=0.018..612.401 rows=4900100 loops=1)
              ->  Seq Scan on sales_fact_2022  (actual time=0.017..185.220 rows=1633400 loops=1)
              ->  Seq Scan on sales_fact_2023  (actual time=0.011..189.740 rows=1633400 loops=1)
              ->  Seq Scan on sales_fact_2024  (actual time=0.010..184.902 rows=1633300 loops=1)
Planning Time: 0.203 ms
Execution Time: 1428.401 ms
```

**What this shows (real mechanism, illustrative numbers):** to hand back
rows 500,001–500,050, PostgreSQL has to first produce (or at least
partially materialize, via the top-N heapsort optimization) a sorted stream
of the **first 500,050 rows** across all three partitions and then discard
the first 500,000 of them. `OFFSET` is not a seek — it is "count and
throw away." The `LIMIT` never changes (always 50 rows out), but the work
done *before* the `LIMIT` kicks in grows linearly with the offset. Page
10,001 does roughly 10,000× the discarded work of page 1, and it will only
get worse as more sales data accumulates.

### 2.4 Query D — the slow ad-hoc regional year-over-year report

This is the query that triggered the original support ticket: "the
regional YoY report used to be fine and now it times out." The analyst
wrote a very natural-looking filter:

```sql
-- Query D (baseline) — the "slow ad-hoc report" from FR-7
SELECT ds.region,
       EXTRACT(YEAR FROM sf.sale_date)::int AS sale_year,
       SUM(sf.amount) AS total_revenue
FROM sales_fact sf
JOIN dim_store ds ON ds.store_key = sf.store_key
WHERE EXTRACT(YEAR FROM sf.sale_date) = 2024
GROUP BY ds.region, sale_year
ORDER BY ds.region;
```

```text
-- ILLUSTRATIVE EXPLAIN ANALYZE — Query D, BEFORE any fix
HashAggregate  (cost=168453.20..168453.30 rows=5 width=44) (actual time=3184.660..3184.667 rows=5 loops=1)
  Group Key: ds.region, (EXTRACT(year FROM sf.sale_date))
  ->  Hash Join  (cost=1.60..162740.60 rows=1633367 width=16) (actual time=0.055..3021.408 rows=1633300 loops=1)
        Hash Cond: (sf.store_key = ds.store_key)
        ->  Append  (cost=0.00..142983.00 rows=4900100 width=12) (actual time=0.021..2604.117 rows=1633300 loops=1)
              ->  Seq Scan on sales_fact_2022 sf  (actual time=0.019..812.334 rows=0 loops=1)
                    Filter: (EXTRACT(year FROM sale_date) = '2024'::numeric)
                    Rows Removed by Filter: 1633400
              ->  Seq Scan on sales_fact_2023 sf  (actual time=0.014..798.520 rows=0 loops=1)
                    Filter: (EXTRACT(year FROM sale_date) = '2024'::numeric)
                    Rows Removed by Filter: 1633400
              ->  Seq Scan on sales_fact_2024 sf  (actual time=0.016..789.902 rows=1633300 loops=1)
                    Filter: (EXTRACT(year FROM sale_date) = '2024'::numeric)
                    Rows Removed by Filter: 0
        ->  Hash  (cost=1.25..1.25 rows=25 width=36) (actual time=0.017..0.018 rows=25 loops=1)
Planning Time: 0.180 ms
Execution Time: 3184.902 ms
```

**What this shows (real mechanism, illustrative numbers):** every one of
the three partitions is scanned — `sales_fact_2022 sf` and
`sales_fact_2023 sf` are right there in the plan, each doing a full
sequential scan and finding **zero** matching rows (`Rows Removed by
Filter: 1633400` on each). **This is a partition pruning failure.**
PostgreSQL's partition pruning works by comparing the literal in your
`WHERE` clause directly against each partition's declared bounds — but
that only works when the predicate is written *directly against the
partition key column*, in a form the planner can range-compare. The moment
you wrap `sale_date` in `EXTRACT(YEAR FROM ...)`, the predicate becomes
an opaque function call from the planner's point of view: it cannot prove
"this expression can't possibly be true for any row in `sales_fact_2022`"
without actually evaluating the function against actual rows, so it plays
it safe and scans everything. This is exactly the 2022/2023 partitions'
data that Query A's pruning correctly skipped — the *only* difference is
how the predicate on `sale_date` was written.

---

## 3. The Fix — Indexing, Partitioning, and Rewriting

Each fix below targets the *specific mechanism* diagnosed in §2 — not a
generic "add more indexes" reflex. Two of the four queries need a new
index; one needs a query rewrite with no new index at all; one needs
*only* a change in how the existing partition key is filtered.

### 3.1 Fixing Query A — add the missing index on the partition key

**Diagnosis recap:** partition pruning already worked (only
`sales_fact_2024` was scanned); the remaining cost was a Seq Scan
*within* that partition because nothing lets PostgreSQL jump straight to
the June 10–16 rows.

```sql
-- REAL, runnable fix
CREATE INDEX idx_sales_fact_sale_date ON sales_fact (sale_date);
```

**Why this column, why a plain B-tree, why no other columns in it (Ch.
16):** `sale_date` is filtered by nearly every report in this project — the
monthly dashboard (FR-1), the regional report (FR-4), the ad-hoc report
(FR-7), and the retention policy (FR-8) all slice on it. It's a classic
high-cardinality, range-queried column, which is precisely what a B-tree
excels at (equality *and* range predicates, `BETWEEN`, `<`, `>=`, ordered
scans for `ORDER BY sale_date`). We deliberately do **not** bundle
`store_key` or `amount` into this index: doing so would make it wider and
more expensive to maintain on every one of the ~5,000-row/day inserts,
for a benefit (avoiding one small `dim_store`/aggregate step) that's
already cheap. Keep indexes narrow unless a specific query proves it needs
to be wider — see §3.3 for a case where a wider composite index *is* the
right call.

> **Important Note — this is one index definition, and PostgreSQL creates
> it on every existing partition automatically.** Because `sales_fact` is
> declared with `PARTITION BY RANGE`, `CREATE INDEX ... ON sales_fact` (the
> parent) creates a matching index on `sales_fact_2022`,
> `sales_fact_2023`, and `sales_fact_2024`, and registers a single
> **partitioned index** at the parent level tying them together (Ch. 26).
> Any partition attached *later* (see §6.1's `sales_fact_2025`) will
> automatically get a matching child index created for it too — you never
> have to remember to index a new partition by hand.

```text
-- ILLUSTRATIVE EXPLAIN ANALYZE — Query A, AFTER adding idx_sales_fact_sale_date
HashAggregate  (cost=1584.60..1584.67 rows=5 width=48) (actual time=17.402..17.408 rows=5 loops=1)
  Group Key: ds.region
  ->  Hash Join  (cost=1.60..1520.11 rows=19110 width=40) (actual time=0.051..14.288 rows=30821 loops=1)
        Hash Cond: (sf.store_key = ds.store_key)
        ->  Append  (cost=0.29..1395.02 rows=19110 width=12) (actual time=0.021..9.940 rows=30821 loops=1)
              ->  Index Scan using sales_fact_2024_sale_date_idx on sales_fact_2024 sf
                    (cost=0.29..1360.55 rows=19108 width=12) (actual time=0.020..9.201 rows=30821 loops=1)
                    Index Cond: ((sale_date >= '2024-06-10') AND (sale_date <= '2024-06-16'))
        ->  Hash  (cost=1.25..1.25 rows=25 width=36) (actual time=0.014..0.015 rows=25 loops=1)
Planning Time: 0.298 ms
Execution Time: 17.601 ms
```

**Why it's faster (real mechanism):** the plan now uses an **Index Scan**
(`Index Cond`, not `Filter`) directly on `sales_fact_2024`'s new index.
Instead of reading and testing all 1.67 million rows in the partition, the
executor walks the B-tree straight to the first row with
`sale_date >= '2024-06-10'` and reads forward until it passes
`'2024-06-16'` — touching only the ~30,000 rows that can possibly match.
Illustrative execution time drops from ~813 ms to ~18 ms: roughly
**45× faster**, and the ratio only gets better as the fact table grows,
since the Seq Scan cost was tied to partition size while the Index Scan
cost is tied to *result* size.

### 3.2 Fixing Query B — replace the correlated subquery with one pass + a window function

**Diagnosis recap:** two correlated subqueries were each re-executed 5,000
times (`loops=5000`), one of them re-aggregating an entire segment's worth
of `sales_fact` rows on every iteration.

```sql
-- REAL, runnable fix — single aggregation pass + window function comparison
WITH customer_revenue AS (
    SELECT
        c.customer_key,
        c.customer_name,
        c.segment,
        SUM(sf.amount) AS customer_revenue
    FROM dim_customer c
    JOIN sales_fact sf ON sf.customer_key = c.customer_key
    GROUP BY c.customer_key, c.customer_name, c.segment
),
with_segment_avg AS (
    SELECT
        cr.*,
        AVG(cr.customer_revenue) OVER (PARTITION BY cr.segment) AS segment_avg_revenue
    FROM customer_revenue cr
)
SELECT customer_key, customer_name, segment, customer_revenue, segment_avg_revenue
FROM with_segment_avg
WHERE customer_revenue > segment_avg_revenue
ORDER BY segment, customer_revenue DESC;
```

**Why this rewrite works (Ch. 10 / Ch. 18 — window function instead of
correlated re-execution):** `customer_revenue` computes every customer's
total revenue with a **single** `GROUP BY` pass over `sales_fact` — the
fact table is scanned once, not 5,000 times. `with_segment_avg` then
computes each segment's average using `AVG(...) OVER (PARTITION BY
segment)` — a window function evaluated over the *already-aggregated*
5,000-row `customer_revenue` result, not over `sales_fact` again. The
segment average for every `ENTERPRISE` customer is computed as one
partition of that window in one pass, instead of being recomputed from
scratch once per customer.

```text
-- ILLUSTRATIVE EXPLAIN ANALYZE — Query B, AFTER the rewrite
Sort  (cost=98452.10..98456.35 rows=1700 width=76) (actual time=1189.204..1189.550 rows=1701 loops=1)
  Sort Key: customer_revenue.segment, customer_revenue.customer_revenue DESC
  ->  Subquery Scan on with_segment_avg  (cost=97981.20..98362.70 rows=1700 width=76)
                                          (actual time=1176.902..1188.220 rows=1701 loops=1)
        Filter: (with_segment_avg.customer_revenue > with_segment_avg.segment_avg_revenue)
        Rows Removed by Filter: 3299
        ->  WindowAgg  (cost=97981.20..98150.70 rows=5000 width=68) (actual time=1176.880..1186.410 rows=5000 loops=1)
              ->  Sort  (cost=97981.20..97993.70 rows=5000 width=44) (actual time=1176.410..1177.802 rows=5000 loops=1)
                    Sort Key: c.segment
                    ->  HashAggregate  (cost=97562.00..97612.00 rows=5000 width=44)
                                         (actual time=1120.204..1160.552 rows=5000 loops=1)
                          Group Key: c.customer_key, c.customer_name, c.segment
                          ->  Hash Join  (cost=133.00..85062.00 rows=5000000 width=14)
                                           (actual time=1.202..812.440 rows=5000000 loops=1)
                                Hash Cond: (sf.customer_key = c.customer_key)
                                ->  Append (Seq Scan sales_fact_2022 + _2023 + _2024)
                                            (actual time=0.020..612.301 rows=5000000 loops=1)
                                ->  Hash  (cost=87.00..87.00 rows=5000 width=32) (actual time=1.140..1.141 rows=5000 loops=1)
                                      ->  Seq Scan on dim_customer c
Planning Time: 0.301 ms
Execution Time: 1189.720 ms
```

**Why it's faster (real mechanism):** notice every node above has
`loops=1`. The fact table is read exactly once (the `Append` over all
three partitions, ~5,000,000 rows, is unavoidable here since this
particular report needs *every* customer's all-time revenue — there's no
date filter to prune on). The `HashAggregate` collapses that into 5,000
per-customer rows in one pass, and the `WindowAgg` computes every
segment's average in one more pass over those 5,000 rows. Illustrative
execution time drops from ~46,200 ms to ~1,190 ms — roughly **39× faster**
— and, critically, this version's cost scales as *one* scan of
`sales_fact` (`O(n)`), where the original scaled as `customers × average
segment size` (effectively `O(n × k)`). That difference gets *worse*, not
better, as Meridian's customer base grows — the rewrite is not just faster
today, it's asymptotically the right shape.

### 3.3 Fixing Query C — replace OFFSET pagination with keyset pagination

**Diagnosis recap:** `OFFSET` forces PostgreSQL to produce and discard
every row before the requested page, so cost grows linearly with how deep
the user pages — no index can fix that, because the problem isn't *finding*
rows, it's *counting past* them.

First, add a composite index that matches the feed's sort order:

```sql
-- REAL, runnable fix (part 1) — an index matching the ORDER BY exactly
CREATE INDEX idx_sales_fact_date_id ON sales_fact (sale_date DESC, sale_id DESC);
```

Then replace `OFFSET` with a **keyset (seek) predicate** carried forward
from the last row of the previous page (Ch. 4):

```sql
-- REAL, runnable fix (part 2) — keyset pagination
-- The caller stores (sale_date, sale_id) of the LAST row of the page they
-- just saw, and sends it back as the cursor for the next page.
SELECT sale_id, sale_date, customer_key, product_key, store_key, amount
FROM sales_fact
WHERE (sale_date, sale_id) < ('2023-08-14', 3245001)   -- cursor from previous page's last row
ORDER BY sale_date DESC, sale_id DESC
LIMIT 50;
```

**Why this rewrite works (Ch. 4 — keyset vs. offset pagination):** the
row-value predicate `(sale_date, sale_id) < (...)` is directly satisfiable
by a single ordered traversal of `idx_sales_fact_date_id`: the executor
seeks to the cursor position in the B-tree — an `O(log n)` descent — and
then reads the next 50 entries forward. It never has to touch, count, or
discard any row from "pages" the user already saw. Page 2 and page 20,000
do **the same amount of work**, because the cursor already encodes
"where the last page ended" — there is no offset to walk past.

```text
-- ILLUSTRATIVE EXPLAIN ANALYZE — Query C, AFTER the rewrite (an equally "deep" page)
Limit  (cost=0.56..8.94 rows=50 width=40) (actual time=0.041..0.612 rows=50 loops=1)
  ->  Merge Append  (cost=0.56..492810.20 rows=2941478 width=40) (actual time=0.040..0.589 rows=50 loops=1)
        Sort Key: sales_fact.sale_date DESC, sales_fact.sale_id DESC
        ->  Index Scan Backward using sales_fact_2022_date_id_idx on sales_fact_2022
              (actual time=0.015..0.015 rows=1 loops=1)
              Index Cond: (ROW(sale_date, sale_id) < ROW('2023-08-14'::date, 3245001))
        ->  Index Scan Backward using sales_fact_2023_date_id_idx on sales_fact_2023
              (actual time=0.018..0.402 rows=50 loops=1)
              Index Cond: (ROW(sale_date, sale_id) < ROW('2023-08-14'::date, 3245001))
        ->  Index Scan Backward using sales_fact_2024_date_id_idx on sales_fact_2024
              (actual time=0.006..0.006 rows=0 loops=1)
              Index Cond: (ROW(sale_date, sale_id) < ROW('2023-08-14'::date, 3245001))
Planning Time: 0.244 ms
Execution Time: 0.681 ms
```

**Why it's faster (real mechanism):** illustrative execution time drops
from ~1,428 ms to **under 1 ms** — a difference so large it would round
away if it were a percentage. The mechanism is qualitative, not just
quantitative: the "before" plan's cost was `O(offset)` — proportional to
how deep the page was, meaning it would keep getting slower as support
agents paged deeper into history. The "after" plan's cost is `O(page
size)` — a small constant, independent of depth, because a B-tree seek
followed by reading 50 sequential entries costs the same whether the
cursor points to row #51 or row #5,000,051. This is precisely NFR-2
("page 50 must not be meaningfully slower than page 5,000") satisfied by
construction, not by luck.

> **⚠️ Warning.** Keyset pagination changes the *contract* your API
> exposes: callers can no longer jump to "page 743" arbitrarily; they can
> only ask for "the next 50 after this cursor." For a "recent activity"
> feed (FR-6) that's exactly the UX you want (infinite scroll / "load
> more"). It's the wrong choice for a UI that needs numbered page links or
> "jump to page 200" — that use case is rare enough in practice, and
> expensive enough to support with `OFFSET` at this scale, that it's worth
> pushing back on the requirement rather than paying the `O(offset)` cost.

### 3.4 Fixing Query D — make the partition-key predicate sargable again

**Diagnosis recap:** wrapping `sale_date` in `EXTRACT(YEAR FROM ...)`
made the predicate opaque to partition pruning, so all three partitions
were scanned even though only one could ever match.

```sql
-- REAL, runnable fix — no new index needed, just a sargable predicate
SELECT ds.region,
       2024 AS sale_year,
       SUM(sf.amount) AS total_revenue
FROM sales_fact sf
JOIN dim_store ds ON ds.store_key = sf.store_key
WHERE sf.sale_date >= DATE '2024-01-01'
  AND sf.sale_date <  DATE '2025-01-01'
GROUP BY ds.region
ORDER BY ds.region;
```

**Why this rewrite works (Ch. 26 — partition pruning is a planner-time
comparison against literal bounds):** `sf.sale_date >= DATE '2024-01-01'
AND sf.sale_date < DATE '2025-01-01'` is a **sargable** range predicate
directly on the partition key, with plain literal bounds. At planning
time, PostgreSQL can compare `['2024-01-01', '2025-01-01')` against each
partition's declared range (`sales_fact_2022`: `['2022-01-01',
'2023-01-01')`, `sales_fact_2023`: `['2023-01-01', '2024-01-01')`,
`sales_fact_2024`: `['2024-01-01', '2025-01-01')`) and mathematically
prove that the first two ranges cannot overlap the predicate — no row in
them needs to be examined at all, and those partitions never even become
subplans in the executed plan.

```text
-- ILLUSTRATIVE EXPLAIN ANALYZE — Query D, AFTER the sargable rewrite
HashAggregate  (cost=44230.10..44230.20 rows=5 width=44) (actual time=1104.302..1104.309 rows=5 loops=1)
  Group Key: ds.region
  ->  Hash Join  (cost=1.60..40940.25 rows=1633300 width=12) (actual time=0.048..980.115 rows=1633300 loops=1)
        Hash Cond: (sf.store_key = ds.store_key)
        ->  Seq Scan on sales_fact_2024 sf  (cost=0.00..35892.00 rows=1633300 width=12)
                                              (actual time=0.021..612.402 rows=1633300 loops=1)
              Filter: ((sale_date >= '2024-01-01') AND (sale_date < '2025-01-01'))
        ->  Hash  (cost=1.25..1.25 rows=25 width=36) (actual time=0.015..0.016 rows=25 loops=1)
Planning Time: 0.096 ms
Subplans Removed: 2
Execution Time: 1104.512 ms
```

**Why it's faster (real mechanism):** the line `Subplans Removed: 2` is
PostgreSQL's own confirmation that partition pruning eliminated
`sales_fact_2022` and `sales_fact_2023` *before* execution even started —
they're not scanned, filtered, and found empty (as in §2.4); they're
simply never touched. Illustrative execution time drops from ~3,185 ms to
~1,105 ms — roughly **3× faster**, which lines up almost exactly with
"we used to scan 3 partitions worth of data, now we scan 1." Note this
query still does a full `Seq Scan` on the remaining partition (it needs
essentially all of that partition's rows, so a Seq Scan is actually the
*right* plan for that part) — layering on `idx_sales_fact_sale_date` from
§3.1 would shave a little more off the scan itself, but the 3× win here
came entirely from pruning, not indexing. Fixing the *sargability* of a
predicate on the partition key is a distinct lever from indexing, and this
query needed only the former.

### 3.5 Summary of fixes

| Query | Root cause | Fix | Mechanism |
|---|---|---|---|
| A — weekly regional revenue | No index on `sale_date`; Seq Scan within already-pruned partition | `CREATE INDEX idx_sales_fact_sale_date ON sales_fact (sale_date)` | Seq Scan → Index Scan: touch only matching rows, not the whole partition |
| B — customers above segment average | Correlated subquery re-executed 5,000×, one level nested | Rewrite as single `GROUP BY` + `AVG(...) OVER (PARTITION BY segment)` | `loops=5000` re-execution → `loops=1` single-pass aggregation + window function |
| C — deep-page admin feed | `OFFSET` discards all prior rows every request; cost grows with page depth | `idx_sales_fact_date_id (sale_date DESC, sale_id DESC)` + keyset `WHERE (sale_date, sale_id) < (cursor)` | `O(offset)` scan-and-discard → `O(page size)` B-tree seek, flat regardless of depth |
| D — regional YoY report | `EXTRACT(YEAR FROM sale_date)` defeats partition pruning | Rewrite as `sale_date >= ... AND sale_date < ...` (sargable) | All 3 partitions scanned → 2 of 3 pruned at plan time (`Subplans Removed: 2`) |

---

## 4. Window-Function-Heavy Analytical Report Suite

The queries in this section are the "correct, real" reports FR-1 through
FR-4 ask for. As stated up top: **the query logic below is correct and
real; the specific numbers it would return are not shown**, because
`sales_fact`, `dim_customer`, `dim_product`, and `dim_store` are all
randomly generated. What's described instead is the *shape* of the result
— column list, ordering, and roughly how many rows come back — which is
fully determined by the schema and does not depend on the random seed.

### 4.1 Running monthly revenue total (FR-1)

```sql
WITH monthly AS (
    SELECT date_trunc('month', sf.sale_date)::date AS sales_month,
           SUM(sf.amount) AS monthly_revenue
    FROM sales_fact sf
    GROUP BY 1
)
SELECT
    sales_month,
    monthly_revenue,
    SUM(monthly_revenue) OVER (
        ORDER BY sales_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_revenue
FROM monthly
ORDER BY sales_month;
```

**Shape of the result:** exactly **36 rows** (one per calendar month from
2022-01 through 2024-12 — `sale_date` only spans those three years per the
seed script). Columns: `sales_month` (date, first of each month, strictly
increasing), `monthly_revenue` (numeric, one month's total), and
`running_total_revenue` (numeric, monotonically non-decreasing, and equal
to `monthly_revenue` cumulatively summed — the final row's
`running_total_revenue` equals the grand total of all of `sales_fact.amount`).
Exact dollar figures will differ every time the seed script runs, since
`amount` is generated with `random()`; the monotonic, cumulative shape of
the last column will not.

### 4.2 Month-over-month and year-over-year growth via `LAG` (FR-1)

```sql
WITH monthly AS (
    SELECT date_trunc('month', sf.sale_date)::date AS sales_month,
           SUM(sf.amount) AS monthly_revenue
    FROM sales_fact sf
    GROUP BY 1
)
SELECT
    sales_month,
    monthly_revenue,
    LAG(monthly_revenue, 1)  OVER (ORDER BY sales_month) AS prev_month_revenue,
    ROUND(
        100.0 * (monthly_revenue - LAG(monthly_revenue, 1) OVER (ORDER BY sales_month))
        / NULLIF(LAG(monthly_revenue, 1) OVER (ORDER BY sales_month), 0)
    , 2) AS mom_growth_pct,
    LAG(monthly_revenue, 12) OVER (ORDER BY sales_month) AS same_month_last_year_revenue,
    ROUND(
        100.0 * (monthly_revenue - LAG(monthly_revenue, 12) OVER (ORDER BY sales_month))
        / NULLIF(LAG(monthly_revenue, 12) OVER (ORDER BY sales_month), 0)
    , 2) AS yoy_growth_pct
FROM monthly
ORDER BY sales_month;
```

**Shape of the result:** 36 rows, same grain as §4.1. `prev_month_revenue`
and `mom_growth_pct` are `NULL` only for the very first row (January 2022 —
there's no prior month to compare to). `same_month_last_year_revenue` and
`yoy_growth_pct` are `NULL` for the first 12 rows (2022, which has no prior
year in this dataset) and populated from row 13 onward (January 2023
onward), each compared against the same calendar month 12 rows back —
exactly what `LAG(..., 12)` gives you on a strictly monthly, gap-free
series. `NULLIF(...,0)` guards the division in case any month randomly
ends up with zero revenue (astronomically unlikely at this scale, but
correct defensive SQL regardless).

### 4.3 Top-3 products per region via `ROW_NUMBER()` (FR-2 / FR-4)

```sql
WITH product_region_revenue AS (
    SELECT
        ds.region,
        dp.product_key,
        dp.product_name,
        dp.category,
        SUM(sf.amount) AS revenue
    FROM sales_fact sf
    JOIN dim_store   ds ON ds.store_key   = sf.store_key
    JOIN dim_product dp ON dp.product_key = sf.product_key
    GROUP BY ds.region, dp.product_key, dp.product_name, dp.category
),
ranked AS (
    SELECT
        prr.*,
        ROW_NUMBER() OVER (PARTITION BY prr.region ORDER BY prr.revenue DESC) AS region_rank
    FROM product_region_revenue prr
)
SELECT region, region_rank, product_name, category, revenue
FROM ranked
WHERE region_rank <= 3
ORDER BY region, region_rank;
```

**Shape of the result:** exactly **15 rows** — 5 regions
(`North`/`South`/`East`/`West`/`Central`) × top 3 products each. Within
each region, `region_rank` runs 1, 2, 3 with `revenue` strictly descending
(ties are broken arbitrarily by `ROW_NUMBER()`'s definition — if a
guaranteed tiebreak matters, add a deterministic secondary `ORDER BY
prr.revenue DESC, prr.product_key` inside the `OVER` clause). Which 15
specific products appear, and in what order, depends entirely on the
random `amount` values generated by the seed script — the shape (15 rows,
grouped by region, ranked 1–3 within each) does not.

> **Important Note.** `ROW_NUMBER()` was deliberately chosen over `RANK()`
> or `DENSE_RANK()` here because the requirement is "give me exactly 3 rows
> per region" — `ROW_NUMBER()` guarantees exactly one row per rank even
> under ties, where `RANK()` could return more than 3 rows for a region if
> two products tied for 3rd place. If the actual business requirement were
> "show me everyone tied for a top-3 spot," `RANK()` would be the correct
> choice instead — see Chapter 10's treatment of the three ranking
> functions' differences.

### 4.4 Percentage of total revenue by segment via `SUM() OVER ()` (FR-3)

```sql
WITH segment_revenue AS (
    SELECT c.segment, SUM(sf.amount) AS segment_revenue
    FROM sales_fact sf
    JOIN dim_customer c ON c.customer_key = sf.customer_key
    GROUP BY c.segment
)
SELECT
    segment,
    segment_revenue,
    ROUND(100.0 * segment_revenue / SUM(segment_revenue) OVER (), 2) AS pct_of_total_revenue
FROM segment_revenue
ORDER BY pct_of_total_revenue DESC;
```

**Shape of the result:** exactly **3 rows** — one per value of
`dim_customer.segment` (`CONSUMER`, `BUSINESS`, `ENTERPRISE`). The
`SUM(segment_revenue) OVER ()` — an empty `OVER ()`, meaning "one window
containing every row in the result set" — computes the grand total once
and divides every row's segment total by it, so `pct_of_total_revenue`
across the 3 rows always sums to **100.00** (modulo rounding), regardless
of what the random data actually produced for each segment's dollar
total. Since customer segment is assigned uniformly at random
(`1 + floor(random()*3)` over 3 options) across 5,000 customers, the three
percentages will typically land loosely near each other rather than
showing one segment dominating — but this is a statistical tendency of
the seed data, not something the query guarantees.

### 4.5 Bonus: cohort / retention analysis from `events` (FR-5, cross-ref Ch. 31)

Since `events` only ever generates `SIGNUP`, `LOGIN`, and `PURCHASE` rows
(see §0.1's note — no `CHURN` rows exist in the seed data), retention here
is measured the standard way: **whether a user has any activity at all in
a later month**, not by looking for an explicit churn marker.

```sql
WITH first_seen AS (
    SELECT user_id,
           date_trunc('month', MIN(event_time))::date AS cohort_month
    FROM events
    WHERE event_type = 'SIGNUP'
    GROUP BY user_id
),
activity AS (
    SELECT DISTINCT user_id,
           date_trunc('month', event_time)::date AS activity_month
    FROM events
),
cohort_activity AS (
    SELECT
        f.cohort_month,
        (EXTRACT(YEAR  FROM age(a.activity_month, f.cohort_month)) * 12
       + EXTRACT(MONTH FROM age(a.activity_month, f.cohort_month)))::int AS months_since_signup,
        COUNT(DISTINCT a.user_id) AS active_users
    FROM first_seen f
    JOIN activity a
      ON a.user_id = f.user_id
     AND a.activity_month >= f.cohort_month
    GROUP BY f.cohort_month, months_since_signup
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS cohort_users
    FROM first_seen
    GROUP BY cohort_month
)
SELECT
    ca.cohort_month,
    ca.months_since_signup,
    ca.active_users,
    cs.cohort_users,
    ROUND(100.0 * ca.active_users / cs.cohort_users, 2) AS retention_pct
FROM cohort_activity ca
JOIN cohort_size cs ON cs.cohort_month = ca.cohort_month
ORDER BY ca.cohort_month, ca.months_since_signup;
```

**Shape of the result:** one row per `(cohort_month, months_since_signup)`
combination that actually has activity — since `events` covers signups
throughout 2023 with a handful of months of follow-on activity per user
(the seed script offsets `LOGIN`/`PURCHASE` events by up to 60–120 days
from signup), expect on the order of a few dozen rows, with
`months_since_signup = 0` always present (a cohort is always "active" the
month it signs up) and `retention_pct` generally trending downward as
`months_since_signup` increases — the classic cohort retention "staircase"
shape, even though the exact percentages are a function of the random
`floor(random()*N)` offsets in the seed script. This report reuses the
gaps-and-islands / cohort pattern taught in Chapter 31 against this
project's own `events` table rather than a hypothetical one.

---

## 5. Materialized View for Dashboard Performance

Every dashboard query in §4 re-scans up to 5,000,000 rows of `sales_fact`
on every page load. For an interactive dashboard hit by many concurrent
users, that's unacceptable even once each individual query is well-indexed
— NFR-1 wants sub-second *dashboard* latency, not just sub-second *query*
latency under isolated testing. The fix is to pre-aggregate to the grain
dashboards actually need and let them query a small materialized view
instead (Ch. 15).

```sql
-- REAL, runnable — pre-aggregated to (month × product × region)
CREATE MATERIALIZED VIEW mv_monthly_sales_summary AS
SELECT
    date_trunc('month', sf.sale_date)::date AS sales_month,
    dp.product_key,
    dp.product_name,
    dp.category,
    ds.region,
    SUM(sf.amount)                    AS total_revenue,
    SUM(sf.quantity)                  AS total_quantity,
    COUNT(*)                          AS transaction_count,
    COUNT(DISTINCT sf.customer_key)   AS distinct_customers
FROM sales_fact sf
JOIN dim_product dp ON dp.product_key = sf.product_key
JOIN dim_store   ds ON ds.store_key   = sf.store_key
GROUP BY 1, dp.product_key, dp.product_name, dp.category, ds.region
WITH DATA;

-- REQUIRED for REFRESH ... CONCURRENTLY (Ch. 15): a unique index on the grain
CREATE UNIQUE INDEX idx_mv_monthly_sales_summary_pk
    ON mv_monthly_sales_summary (sales_month, product_key, region);

-- Supporting index for the common "give me a month + region" dashboard filter
CREATE INDEX idx_mv_monthly_sales_summary_month_region
    ON mv_monthly_sales_summary (sales_month, region);
```

**Why this grain:** `sales_month × product_key × region` is fine enough to
answer every report in §4 (monthly trends, top products per region,
segment breakdowns need `dim_customer` too — see the note below) by
re-aggregating a *small* result set instead of the full fact table, but
coarse enough to actually be small: illustratively, at most
`36 months × 200 products × 5 regions` = **36,000 rows**, roughly 140×
smaller than `sales_fact`, small enough to comfortably fit in memory and
be scanned in full if needed with no partitioning or special indexing at
all.

> **Important Note.** This materialized view does **not** cover the
> segment-based reports (§4.4) or the customer-level report (§3.2), because
> `dim_customer.segment` and `dim_customer.customer_key` aren't part of its
> grain. That's a deliberate design choice, not an oversight: adding
> `customer_key` to the grouping would balloon the view back up toward
> `sales_fact`'s own row count (5,000 customers × 36 months × ... quickly
> approaches millions of rows again), defeating the point. A second,
> separate materialized view — `mv_monthly_sales_by_segment`, grouped by
> `(sales_month, segment)` only, with no product/store dimension — is the
> right complementary object if the segment report also needs to be fast;
> it's a two-line variation on the DDL above and is left as an exercise
> (see §7).

### 5.1 Refresh strategy (Ch. 15)

```sql
-- REAL, runnable — run this on a nightly schedule (cron, pg_cron, Airflow, etc.)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_sales_summary;
```

- **Why `CONCURRENTLY`:** a plain `REFRESH MATERIALIZED VIEW` takes an
  `ACCESS EXCLUSIVE` lock on the view for the duration of the refresh —
  every dashboard query hitting it blocks until the refresh finishes.
  `REFRESH MATERIALIZED VIEW CONCURRENTLY` instead builds a new version of
  the data alongside the old one and swaps them with only a brief lock,
  so dashboard reads continue against the *old* (slightly stale) data
  until the swap — satisfying NFR-3 (no read/write downtime). It requires
  the unique index created above; without one, `CONCURRENTLY` fails with
  an explicit error telling you so.
- **Why nightly, not real-time:** dashboards in this project (monthly
  trends, top products, regional comparisons) are inherently about
  *historical* patterns, not this-second activity — a few hours of
  staleness is invisible to the business use case, and refreshing nightly
  (e.g., 2 AM local, after the day's batch loads land) keeps the refresh
  cost off of peak dashboard-usage hours. If a genuinely near-real-time
  view is needed for some other report, that's a different (smaller,
  cheaper) materialized view refreshed far more often — see §7.
- **Staleness is visible, not hidden:** expose a `last_refreshed_at`
  timestamp to dashboard consumers (e.g., by also storing
  `SELECT now()` into a tiny sidecar table at refresh time, since
  materialized views don't track this themselves) so users know exactly
  how fresh the numbers they're looking at are — silently stale
  dashboards erode trust faster than openly-labeled ones.

---

## 6. Partition Maintenance Plan (Ch. 26)

### 6.1 Add next year's partition ahead of time (FR-10)

Never wait for an `INSERT` into 2025 data to fail with "no partition of
relation sales_fact found for row" before creating the partition. Create
it in advance, as part of a scheduled job:

```sql
-- REAL, runnable — create 2025's partition well before 2025 data arrives
CREATE TABLE sales_fact_2025 PARTITION OF sales_fact
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
```

Because §3.1 and §3.3 created `idx_sales_fact_sale_date` and
`idx_sales_fact_date_id` on the *parent* `sales_fact` table, this new
partition automatically receives matching child indexes the moment it's
attached — no follow-up `CREATE INDEX` step required (see the note in
§3.1).

To make this genuinely "ahead of schedule" rather than a one-time manual
step, wrap it in an idempotent procedure and schedule it (e.g., via
`pg_cron`, which many managed PostgreSQL providers support natively):

```sql
-- REAL, runnable — idempotent "ensure next year's partition exists" procedure
CREATE OR REPLACE PROCEDURE ensure_next_year_partition()
LANGUAGE plpgsql
AS $$
DECLARE
    v_next_year   int := EXTRACT(YEAR FROM now())::int + 1;
    v_table_name  text := format('sales_fact_%s', v_next_year);
    v_from        date := make_date(v_next_year, 1, 1);
    v_to          date := make_date(v_next_year + 1, 1, 1);
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_class WHERE relname = v_table_name
    ) THEN
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF sales_fact FOR VALUES FROM (%L) TO (%L)',
            v_table_name, v_from, v_to
        );
        RAISE NOTICE 'Created partition %', v_table_name;
    ELSE
        RAISE NOTICE 'Partition % already exists, nothing to do', v_table_name;
    END IF;
END;
$$;

-- Schedule it well ahead of the new year, e.g. every December 1st (requires pg_cron):
-- SELECT cron.schedule('ensure-next-year-partition', '0 3 1 12 *',
--                       'CALL analytics_db.ensure_next_year_partition();');
```

This uses `EXECUTE format(...)` for the dynamic table/date names (Ch. 23 —
dynamic SQL), with `%I`/`%L` identifier/literal quoting to stay injection-safe
even though the inputs here are computed, not user-supplied.

### 6.2 Retention policy — drop the oldest partition on a schedule (FR-8)

```sql
-- REAL, runnable — configurable retention window
CREATE OR REPLACE PROCEDURE retire_old_sales_partitions(p_retention_years int)
LANGUAGE plpgsql
AS $$
DECLARE
    v_cutoff_year int := EXTRACT(YEAR FROM now())::int - p_retention_years;
    v_partition   record;
BEGIN
    FOR v_partition IN
        SELECT c.relname
        FROM pg_inherits i
        JOIN pg_class c       ON c.oid = i.inhrelid
        JOIN pg_class parent  ON parent.oid = i.inhparent
        WHERE parent.relname = 'sales_fact'
          AND c.relname ~ '^sales_fact_[0-9]{4}$'
          AND substring(c.relname FROM '[0-9]{4}$')::int < v_cutoff_year
    LOOP
        EXECUTE format('ALTER TABLE sales_fact DETACH PARTITION %I CONCURRENTLY',
                        v_partition.relname);
        EXECUTE format('DROP TABLE %I', v_partition.relname);
        RAISE NOTICE 'Retired partition %', v_partition.relname;
    END LOOP;
END;
$$;

-- Example: keep a rolling 3 years of sales history, run monthly
-- SELECT cron.schedule('retire-old-sales-partitions', '0 4 1 * *',
--                       'CALL analytics_db.retire_old_sales_partitions(3);');
```

**Why `DETACH ... CONCURRENTLY` then `DROP`, not `DELETE` (Ch. 26 / Ch. 29
— MVCC and bloat):** `DELETE FROM sales_fact WHERE sale_date < ...` would
have to visit and mark every one of ~1.67 million rows as dead, generate
that many WAL records, and leave the reclaimed space to be cleaned up by
`VACUUM` later — a multi-hour, I/O-heavy operation on a live table, and it
would still leave dead tuples for autovacuum to deal with under production
write load. Dropping a **partition** is a metadata operation: PostgreSQL
simply unlinks and removes an entire physical table (its file on disk),
which is near-instant regardless of how many rows it holds. `DETACH
PARTITION ... CONCURRENTLY` (available since PostgreSQL 14) additionally
avoids taking a long-lived `ACCESS EXCLUSIVE` lock on the parent
`sales_fact` table during the detach step, so ongoing reads and writes to
the *other* partitions are not blocked while old data is retired — directly
satisfying NFR-3.

> **⚠️ Warning.** `DROP TABLE` is irreversible without a prior backup. In a
> real production system, the retention job in §6.2 should archive the
> detached partition (e.g., `pg_dump` it, or move it to cold storage) before
> dropping it, or simply rename it out of the partition hierarchy and leave
> it as an ordinary standalone table for some grace period instead of
> dropping immediately. Chapter 28 (Backup & Recovery) covers the archival
> half of this policy in depth; this project focuses on the partitioning
> mechanics.

---

## 7. Things to Extend

No solutions here — these are follow-on problems worth solving yourself
once the above feels solid.

1. **Add a BRIN index on `sale_date` as an alternative to the B-tree from
   §3.1.** `sales_fact` is append-mostly and naturally date-ordered — new
   rows arrive with dates close to "now," and (once ingestion is a real
   pipeline rather than a random backfill) rows are typically inserted in
   roughly chronological order. A **BRIN (Block Range Index)** stores only
   the min/max `sale_date` for each physical block range instead of an
   entry per row, making it dramatically smaller than a B-tree (often
   under 1% of the size) at the cost of being effective only when the
   indexed column correlates with physical row order. Try:
   `CREATE INDEX idx_sales_fact_sale_date_brin ON sales_fact USING BRIN
   (sale_date);` alongside (or instead of) the B-tree, and compare index
   size (`pg_relation_size`) and `EXPLAIN ANALYZE` behavior on a
   full-partition range query versus a narrow one.
2. **Build `mv_monthly_sales_by_segment`,** the complementary materialized
   view hinted at in §5's note, so the segment report in §4.4 also gets
   the "don't touch 5 million rows per dashboard load" treatment.
3. **Add a `mv_daily_region_sales` rollup** at daily × region grain for a
   "yesterday vs. today" near-real-time operations view, refreshed far
   more frequently (e.g., every 15 minutes) than the nightly monthly
   summary — think through why a *smaller, more frequently refreshed* view
   at a finer grain doesn't contradict the "don't overload the refresh
   schedule" reasoning in §5.1.
4. **Partition the `events` table** the same way `sales_fact` is
   partitioned (by month or quarter of `event_time`), and re-run the
   cohort query from §4.5 with `EXPLAIN ANALYZE` before and after — decide
   whether pruning actually helps here given how the cohort query joins
   across the whole history, or whether partitioning `events` mainly pays
   off for a *different* class of query (e.g., "last 30 days of events"
   operational lookups).
5. **Automate partition management with `pg_partman`** instead of the
   hand-rolled procedures in §6, and compare its default behavior
   (pre-creation lookahead, retention, detach-and-archive options) against
   what was built here by hand.
6. **Investigate read replicas for dashboard traffic.** Once dashboards are
   fast in isolation, the next bottleneck at real concurrency is often
   contention with OLTP-style writes on the primary. Sketch how you'd route
   the reporting queries in this project to a streaming replica (Ch. 30)
   and what staleness guarantees you'd need to give dashboard users as a
   result.

---

## What You Practiced

This project deliberately forced multiple course chapters to work together
rather than in isolation:

- **Chapter 4 (Sorting, Pagination):** diagnosed why `OFFSET` pagination
  degrades with depth and replaced it with keyset (seek) pagination backed
  by a matching composite index (§2.3, §3.3).
- **Chapter 6 (Aggregates) / Chapter 7 (Joins):** every report in this
  project joins the fact table to one or more dimension tables and
  aggregates the result — the star-schema query pattern at real scale.
- **Chapter 8 (Subqueries) / Chapter 10 (Window Functions):** diagnosed a
  correlated subquery's per-row re-execution cost and replaced it with a
  single-pass `GROUP BY` plus a window function (§2.2, §3.2); built running
  totals, `LAG`-based growth metrics, `ROW_NUMBER()` leaderboards, and
  `SUM() OVER ()` percentage-of-total reports (§4).
- **Chapter 9 (CTEs):** structured every multi-step report as readable
  `WITH` clauses rather than deeply nested subqueries.
- **Chapter 15 (Views & Materialized Views):** designed
  `mv_monthly_sales_summary` for dashboard performance and reasoned through
  a `REFRESH ... CONCURRENTLY` strategy and its locking implications (§5).
- **Chapter 16 (Indexes):** chose specific index column sets
  (`sale_date` alone vs. the composite `(sale_date DESC, sale_id DESC)`)
  and justified each choice against the query it serves, deliberately
  avoiding over-wide indexes (§3.1, §3.3).
- **Chapter 17 (Query Execution & Planner):** read and interpreted
  `EXPLAIN ANALYZE` output — Seq Scan vs. Index Scan, `Rows Removed by
  Filter`, `loops=N` on correlated subplans, `Subplans Removed` — as
  evidence for a specific root cause, not just "the query is slow" (§2, §3).
- **Chapter 18 (Performance Optimization):** applied a full
  diagnose-then-fix workflow to four distinct classes of performance
  problem (missing index, correlated subquery, offset pagination,
  non-sargable predicate) rather than one generic technique repeated four
  times.
- **Chapter 23 (Dynamic SQL):** used `EXECUTE format(...)` with `%I`/`%L`
  quoting inside the partition-maintenance procedures (§6).
- **Chapter 26 (Partitioning):** relied on and demonstrated partition
  pruning (including a failure mode — a non-sargable predicate defeating
  it), and wrote partition-add and partition-retire procedures using
  `DETACH ... CONCURRENTLY` (§3.4, §6).
- **Chapter 29 (Database Internals — MVCC/VACUUM):** reasoned about why
  dropping a partition beats a bulk `DELETE` for retention (§6.2).
- **Chapter 30 (Replication & HA):** referenced (as a suggested extension,
  §7) for routing read-heavy dashboard traffic off the primary.
- **Chapter 31 (Advanced Patterns — cohort analysis):** built a genuine
  cohort/retention report against the `events` table, reasoning correctly
  about what the seed data does and does not contain (§4.5).
