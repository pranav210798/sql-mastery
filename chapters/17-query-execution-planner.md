# Chapter 17 — Query Execution & the Query Planner

> **Where this fits:** Chapter 16 taught you the index *structures* (B-tree,
> hash, composite, covering, partial) and the basic scan types they enable
> (index scan, seq scan, index-only scan, bitmap scan). This chapter assumes
> that vocabulary and answers the next question: **how does PostgreSQL decide
> which of those structures to actually use for a given query, and how do you
> read its mind?** Chapter 18 (Performance Optimization) then builds on both
> chapters to give you a systematic tuning workflow. Read them in order —
> 16 → 17 → 18 is a deliberate progression, not three independent topics.

Every query you have written in this course — from `SELECT * FROM users` in
Chapter 3 to the window functions in Chapter 10 — went through the exact same
internal pipeline before a single row came back to you. Understanding that
pipeline, and learning to read the tool that exposes it (`EXPLAIN`), is what
separates someone who writes *correct* SQL from someone who writes SQL that
survives contact with 5 million rows.

We will use two of the course's canonical databases throughout:

- **`ecommerce_db`** — small, hand-seeded (8 users, 10 orders). We'll use it
  for syntax you can run yourself and get the *exact* output shown, and for
  one case study where we explicitly scale it up to production volume
  (clearly labeled).
- **`analytics_db`** — the 5-million-row, range-partitioned `sales_fact`
  table described in its header comment. This is where "the planner's
  decision actually matters" becomes visible, and where most of our
  case studies live.

---

## 1. The Life of a SQL Statement

### 1.1 Simple explanation

When you hit "run" on a query, PostgreSQL doesn't just start reading rows. It
first has to figure out *what you meant*, *whether it's even valid*, and
*the cheapest way to get the answer*. Only after all of that does it start
touching data. Think of it like a GPS: before showing you turn-by-turn
directions, it parses your destination text, checks the address exists,
consults traffic data, and compares several candidate routes by estimated
cost (time/distance) before picking one.

### 1.2 Technical explanation — the five stages

```text
SQL text
   │
   ▼
┌─────────────┐   Is the grammar valid? Build a parse tree.
│   PARSER    │
└─────────────┘
   │
   ▼
┌─────────────┐   Do these tables/columns exist? Are types compatible?
│ VALIDATION  │   (a.k.a. "semantic analysis" / analyzer)
└─────────────┘
   │
   ▼
┌─────────────┐   Expand views, apply rewrite rules, inline RLS policies.
│  REWRITER   │
└─────────────┘
   │
   ▼
┌─────────────┐   Enumerate candidate plans, estimate their cost,
│  PLANNER /  │   pick the cheapest one.
│  OPTIMIZER  │
└─────────────┘
   │
   ▼
┌─────────────┐   Walk the chosen plan tree, node by node, and
│  EXECUTOR   │   produce the result rows.
└─────────────┘
```

**Stage 1 — Parsing.** The parser is a pure grammar check. It tokenizes your
SQL text and builds a **parse tree** that represents the statement's
structure — a `SELECT` node with a target list, a `FROM` clause, a `WHERE`
clause, and so on. At this stage PostgreSQL has **no idea** whether the
tables or columns you named exist. `SELECT * FROM nonexistent_table` and
`SELECT * FROM orders` parse identically well — the parser only cares that
the *shape* of the statement is grammatically legal SQL.

```text
SELECT * FROM orders WHERE staus = 'PAID';   -- typo in column name
```

This fails at the *next* stage (validation), not here. A genuinely malformed
statement — mismatched parentheses, a stray comma, `SELCT` instead of
`SELECT` — fails right here, at parse time, with a `syntax error at or near`
message.

**Stage 2 — Validation (semantic analysis).** Now PostgreSQL consults the
**system catalogs** (`pg_class`, `pg_attribute`, `pg_type`, etc. — see
Chapter 29 for the full catalog tour) to check that every table, column, and
function you referenced actually exists, that you have privileges to use it,
and that the data types involved are compatible (or can be implicitly cast).
The typo above — `staus` instead of `status` — is caught here:

```text
ERROR:  column "staus" does not exist
LINE 1: SELECT * FROM orders WHERE staus = 'PAID';
                                    ^
HINT:  Perhaps you meant to reference the column "orders.status".
```

The output of this stage is a fully resolved **query tree**: every table
reference is now an OID, every column reference is now an attribute number,
every ambiguous name has been resolved.

**Stage 3 — Query rewriting.** This is the stage most people skip past, but
it's where a surprising amount of "magic" happens. PostgreSQL's **rewrite
system** (built on its general-purpose *rule* system) rewrites the query
tree before it ever reaches the planner:

- **View expansion.** A view (Chapter 15) has no data of its own — it's
  stored as a rule (`_RETURN`) that says "when someone selects from this
  view, substitute this query instead." When you run
  `SELECT * FROM active_users_view`, the rewriter literally splices the
  view's defining query into yours, producing a new query tree against the
  *base* tables. The planner never even sees "a view" — by the time it runs,
  the view has vanished, replaced by its definition.
- **Rule application. `[PostgreSQL rewrite rules]`** Beyond views,
  PostgreSQL lets you attach arbitrary `CREATE RULE ... DO INSTEAD` rules to
  a table (a legacy, low-level mechanism now mostly superseded by triggers
  for row-level logic — see Chapter 22 — but still what powers views
  internally, and occasionally used directly for things like redirecting
  `INSERT`s into a partitioned table on very old PostgreSQL versions before
  declarative partitioning existed). If a matching rule exists, the rewriter
  can replace, augment, or entirely cancel your statement.
- **Row-Level Security.** If RLS policies are enabled on a table
  (Chapter 27), the rewriter is also where the policy's `USING`/`WITH CHECK`
  expressions get folded into your query's `WHERE` clause, invisibly.

The output of rewriting is a (possibly very different, possibly much larger)
query tree that is 100% expressed in terms of real base tables — no views,
no rules left to apply.

**Stage 4 — Planning / Optimization.** This is the heart of this chapter and
gets its own major section below (§2–§4): the planner enumerates plausible
**execution strategies** for the rewritten query tree, assigns each one an
estimated **cost**, and picks the cheapest. The output is a **plan tree** —
a tree of physical operators (Seq Scan, Index Scan, Hash Join, Sort, …) that
says exactly how to compute the answer.

**Stage 5 — Execution.** The **executor** walks the plan tree and produces
rows. Crucially, PostgreSQL's executor is *pull-based* (a "Volcano" /
iterator model): the top node calls `next()` on its child, which calls
`next()` on its children, and so on down to the leaves (the scan nodes that
actually touch storage). Rows flow **up** the tree one at a time (or in
small batches), which is exactly why `EXPLAIN ANALYZE`'s node-by-node timing
(§6) reflects real, physical work — each node genuinely pulled rows from
below and did something with them.

### 1.3 Why it matters

If you only ever think of a query as "the thing that returns rows," you
have no vocabulary for *why* two queries that look equally reasonable can
have wildly different performance. Once you internalize that a query
becomes a **tree of physical operators chosen by cost comparison**, an
entire category of "why is this slow?" questions becomes answerable: because
the wrong operator was chosen, and the wrong operator was chosen because
the cost estimate was wrong, and the cost estimate was wrong because the
**statistics** feeding it were wrong or the query prevented the planner from
even considering a cheaper option (Chapter 18 builds directly on this
diagnostic chain).

> **Important Notes**
> - Rewriting happens **before** planning and is purely structural — it does
>   not know or care about data volume or cost.
> - Planning happens **every time** you submit a fresh query text (unless
>   you're using a **prepared statement**, in which case see the "plan
>   caching" edge case in §6.9 — this is a common source of "the exact same
>   query is fast for me but slow in production").
> - None of these stages read a single data row until the executor starts.
>   `EXPLAIN` (without `ANALYZE`) stops right before execution — it shows you
>   the *planner's* output only.

---

## 2. Statistics: What the Planner Knows About Your Data

### 2.1 Simple explanation

The planner can't afford to actually count rows every time it needs to
estimate how selective a `WHERE` clause is — that would mean scanning the
table just to decide *whether* to scan the table. Instead, PostgreSQL keeps
a running summary of each table's data — like a census — and the planner
consults that summary instead of the real data.

### 2.2 Technical explanation

That summary lives in the system catalog **`pg_statistic`** (queried in
practice through the friendlier view **`pg_stats`**), and is built by the
**`ANALYZE`** command — either run manually, or automatically by
**autovacuum**'s analyze worker once enough rows in a table have changed
(governed by `autovacuum_analyze_scale_factor` / `autovacuum_analyze_threshold`).

For each column, `ANALYZE` takes a random sample of rows (sample size driven
by `default_statistics_target`, default `100`, overridable per column with
`ALTER TABLE ... ALTER COLUMN ... SET STATISTICS n`) and records:

| `pg_stats` column | What it means |
|---|---|
| `null_frac` | Fraction of rows where this column is `NULL` |
| `avg_width` | Average stored width in bytes (feeds the `width=` field in `EXPLAIN`) |
| `n_distinct` | Estimated number of distinct values (positive = absolute count, negative = ratio of table size, e.g. `-0.5` means "half the rows are distinct") |
| `most_common_vals` (MCV) | The most frequently occurring values, sampled |
| `most_common_freqs` | The frequency of each value in `most_common_vals` |
| `histogram_bounds` | Boundaries of equal-population buckets over the *remaining* (non-MCV) values, used to estimate range/inequality selectivity |
| `correlation` | -1 to 1: how well the column's logical order matches its physical on-disk order (huge factor in Index Scan vs Bitmap Scan choice, see §7.3) |

```sql
-- [PostgreSQL] Inspect what the planner actually knows about a column
SELECT attname, null_frac, n_distinct, correlation,
       most_common_vals, most_common_freqs
FROM pg_stats
WHERE schemaname = 'analytics_db' AND tablename = 'sales_fact'
  AND attname = 'customer_key';
```

**Illustrative output** (analytics_db, after `ANALYZE`, uniform random data):

```text
   attname    | null_frac | n_distinct | correlation | most_common_vals | most_common_freqs
--------------+-----------+------------+-------------+-------------------+-------------------
 customer_key |         0 |       5000 |      0.0021 | {2381,919,...}    | {0.00028,0.00026,...}
```

`n_distinct = 5000` matches the real cardinality of `dim_customer` — the
planner therefore estimates `1 / 5000` selectivity for an equality filter
like `customer_key = 4821`, i.e. `5,000,000 / 5000 = 1000` rows. Note the
`correlation` near zero: because `sales_fact` was populated with `random()`
dates rather than in chronological insertion order, a row's logical
`sale_date` value has almost no relationship to its physical position in
the table. Keep that fact in mind — it resurfaces in §7.3 and Case Study 1.

### 2.3 Why it matters

Every cost and row estimate the planner ever produces traces back to these
numbers. **If the statistics are stale or too coarse, every downstream
decision — scan choice, join order, join algorithm, memory allocation — can
be wrong**, even though the planner's *logic* is functioning perfectly. This
is the single most common root cause of "the query used to be fast" reports,
and it's the subject of Case Study 3 (§9.3).

### 2.4 Syntax

```sql
-- Manually refresh statistics for one table
ANALYZE ecommerce_db.orders;

-- Refresh statistics for the whole database
ANALYZE;

-- Verbose (shows per-table row/page counts as it works)
ANALYZE VERBOSE analytics_db.sales_fact;

-- Increase sampling detail for one skewed column (default target: 100)
ALTER TABLE analytics_db.sales_fact ALTER COLUMN customer_key SET STATISTICS 500;
ANALYZE analytics_db.sales_fact;
```

> **Important Notes**
> - `VACUUM ANALYZE` does both jobs in one pass (reclaims dead tuple space
>   *and* refreshes statistics) — commonly run together after a bulk load.
> - `EXPLAIN` output has an entire failure mode dedicated to this topic
>   (row-estimate mismatch, §6.8) — this is not academic.
> - **`[PostgreSQL]`** For columns whose values are *correlated with each
>   other* (e.g. `city` and `zip_code`), the default per-column statistics
>   assume independence and can badly mis-estimate combined filters. Extended
>   statistics — `CREATE STATISTICS stats_name (dependencies, ndistinct) ON col1, col2 FROM table;`
>   followed by `ANALYZE` — let the planner model that correlation. This is
>   an expert-level escape hatch worth knowing exists, even if you rarely
>   need it.

---

## 3. Cardinality Estimation

### 3.1 Simple explanation

Cardinality estimation is the planner's answer to: *"if I apply this filter,
roughly how many rows will survive?"* Every other decision downstream —
which scan to use, which join algorithm, how much memory to reserve — is
built on top of that one number.

### 3.2 Technical explanation

For a simple equality predicate `col = value`, the planner:

1. Checks whether `value` appears in the column's **MCV list**. If so, it
   uses the recorded frequency directly — this is the most accurate case.
2. If not, it assumes the remaining ("non-MCV") rows are uniformly spread
   over the remaining distinct values, and estimates
   `(1 - sum of MCV freqs) / (n_distinct - number of MCVs)`.

For a range predicate (`col > value`, `BETWEEN`, etc.), it uses the
**histogram bounds** to interpolate what fraction of rows fall in that
range.

For **combined predicates** (`WHERE a = 1 AND b = 2`), unless extended
statistics exist for the pair, PostgreSQL assumes **statistical
independence** and simply **multiplies** the individual selectivities:

```text
selectivity(a=1 AND b=2) ≈ selectivity(a=1) × selectivity(b=2)
```

This independence assumption is a well-known, deliberate simplification —
and a well-known source of misestimation when the columns are *not*
actually independent (e.g. `country = 'USA' AND currency = 'USD'` are
strongly correlated; multiplying their individual selectivities badly
*under*-estimates how many rows actually match together).

Joins compound this: the estimated row count out of a join node is derived
from the estimated cardinalities of its two inputs and the estimated
selectivity of the join condition — so an error at the base-table level
doesn't stay contained, it **propagates and often compounds** as it moves
up through every join above it.

### 3.3 Why it matters

Cost estimates are a function of row-count estimates. Get the row count
wrong, and even a mathematically perfect cost formula will recommend the
wrong plan — not because the planner is "bad at math," but because you fed
it a wrong premise. This is why experienced engineers, when diagnosing a
slow query, look at **estimated rows vs. actual rows** in `EXPLAIN ANALYZE`
before anything else (§6.8). A plan built on a 1000-row estimate that
actually produces 46,000 rows didn't fail because PostgreSQL is bad at
planning — it failed because the planner was lied to by stale statistics
(Case Study 3 is exactly this).

### 3.4 Common causes of bad cardinality estimates

| Cause | Example |
|---|---|
| Stale statistics after bulk load/delete | `COPY` 500K new skewed rows in, no `ANALYZE` run |
| Function wrapped around a column | `WHERE UPPER(email) = 'X'` — planner can't use column stats for `UPPER(email)` |
| Correlated predicates, independence assumption | `WHERE category = 'Electronics' AND unit_cost > 2000` when expensive items cluster in Electronics |
| Highly skewed distribution with a coarse MCV list | One customer with 9% of all rows, but `default_statistics_target` sampled too few rows to notice |
| Parameters unknown at plan time (generic plans) | Prepared statement planned once for "the average case," executed later with an outlier value — §6.9 |
| Multi-table join chains | Each join's estimate compounds the last one's error |

---

## 4. Cost Estimation

### 4.1 Simple explanation

For every candidate way of running your query, PostgreSQL computes a single
number — **cost** — that represents "roughly how much work is this." It is
an arbitrary unit (calibrated so that reading one sequential 8&nbsp;KB disk
page costs `1.0`), not milliseconds. The planner then simply picks the
candidate with the lowest total cost.

### 4.2 Technical explanation

Cost is built from a handful of tunable constants (`postgresql.conf`
defaults shown):

| Constant | Default | Meaning |
|---|---|---|
| `seq_page_cost` | 1.0 | Cost of reading one page sequentially |
| `random_page_cost` | 4.0 | Cost of reading one page via random I/O (index lookups) — deliberately higher than `seq_page_cost` because a spinning disk (or even an SSD, to a lesser degree) pays a penalty for non-sequential access |
| `cpu_tuple_cost` | 0.01 | Cost of processing one row in memory |
| `cpu_index_tuple_cost` | 0.005 | Cost of processing one index entry |
| `cpu_operator_cost` | 0.0025 | Cost of evaluating one operator/function call |

> **`[PostgreSQL]`** On modern all-SSD infrastructure, many teams tune
> `random_page_cost` down to `1.1`–`1.5` (closer to `seq_page_cost`), because
> SSDs don't pay nearly the same random-access penalty spinning disks do.
> This single setting can flip many plans from Seq Scan to Index Scan
> without touching a single query. We revisit this as a tuning lever in
> Chapter 18.

Every plan node has a **startup cost** and a **total cost**, shown as
`cost=startup..total`:

- **Startup cost** — the estimated cost incurred *before the first row can
  be returned* (e.g., a `Sort` node must consume and sort its *entire*
  input before it can emit row #1 — high startup cost; a `Seq Scan` can
  emit its first row almost immediately — near-zero startup cost).
- **Total cost** — the estimated cost to fully exhaust the node, i.e.,
  produce *every* row it will ever produce.

For a plain sequential scan:

```text
total_cost ≈ (pages × seq_page_cost) + (rows × cpu_tuple_cost)
```

For an index scan (simplified — the real formula also factors in the
column's `correlation` statistic, since a well-correlated index requires far
fewer random heap page visits):

```text
total_cost ≈ startup (index descent)
           + (matching_index_pages × random_page_cost)
           + (matching_rows × (cpu_index_tuple_cost + cpu_tuple_cost))
```

The planner computes both formulas (and several others — bitmap scan,
different join orders, different join algorithms) for the *same* logical
query, and picks whichever complete plan tree has the lowest total cost at
the root. For queries with more than a handful of joins, the number of
possible join orders explodes combinatorially; above `join_collapse_limit`
(default 8) / `geqo_threshold` (default 12) tables in a single query,
PostgreSQL switches from exhaustive dynamic-programming search to the
**GEQO** (Genetic Query Optimizer), which uses a randomized heuristic search
instead of guaranteeing the true optimum — a reasonable trade-off, since
exhaustively comparing every join order for a 20-table query would itself
take longer than just running a decent plan.

### 4.3 Why it matters

Cost is an *estimate*, calibrated on assumptions (disk vs SSD speed,
memory pressure, cache residency) that may or may not match your real
hardware. Two databases with identical schemas and identical row counts can
get different plans for the identical query if their `postgresql.conf`
cost constants, statistics, or cached-data state differ. This is exactly
why `EXPLAIN ANALYZE`'s **actual timing** (§6) is the ground truth you
reconcile the cost model's *predictions* against.

---

## 5. EXPLAIN and EXPLAIN ANALYZE

### 5.1 Simple explanation

`EXPLAIN` asks PostgreSQL: *"What would you do with this query, and what do
you think it will cost?"* — without running it. `EXPLAIN ANALYZE` asks the
stronger question: *"Actually run it, and tell me the plan **and** what
really happened — real timings, real row counts."*

### 5.2 Technical explanation

- **`EXPLAIN`** runs the query through parsing → validation → rewriting →
  planning, and stops. It prints the chosen plan tree with the planner's
  cost and row **estimates**. No data is touched, no side effects occur.
- **`EXPLAIN ANALYZE`** does everything `EXPLAIN` does, and then *executes*
  the plan for real, instrumenting every node with a timer and a row
  counter. It prints both the original estimates **and** the actual
  measured values side by side.

> **⚠️ Warning**
> `EXPLAIN ANALYZE` **actually executes the query**. If the statement is
> `INSERT`, `UPDATE`, `DELETE`, or anything else that modifies data,
> `EXPLAIN ANALYZE` performs that modification for real — it is not a dry
> run. Running `EXPLAIN ANALYZE DELETE FROM orders WHERE status = 'CANCELLED';`
> directly against production will genuinely delete those rows.
>
> **Always wrap a data-modifying `EXPLAIN ANALYZE` in a transaction you roll
> back:**
> ```sql
> BEGIN;
> EXPLAIN ANALYZE
> DELETE FROM ecommerce_db.orders WHERE status = 'CANCELLED';
> ROLLBACK;   -- the DELETE never becomes visible to anyone else
> ```
> The plan and real timings are still reported — only the visible effect is
> undone. (See Chapter 11 for exactly why `ROLLBACK` inside an open
> transaction makes this safe: nothing was ever committed.)

### 5.3 Why it matters

`EXPLAIN` alone tells you what the planner *believes*. `EXPLAIN ANALYZE`
tells you what actually *happened*. The gap between the two — estimated
rows vs. actual rows, estimated relative cost vs. actual measured time — is
the single most valuable diagnostic signal in all of query tuning (§6.8).
Reading `EXPLAIN` output without ever cross-checking it against
`EXPLAIN ANALYZE` means trusting the planner's assumptions blindly, which is
listed below as mistake #1 for a reason.

### 5.4 Syntax

```sql
-- [PostgreSQL] Plain estimated plan
EXPLAIN SELECT * FROM ecommerce_db.orders WHERE status = 'DELIVERED';

-- Execute for real, show actual timing/rows alongside estimates
EXPLAIN ANALYZE SELECT * FROM ecommerce_db.orders WHERE status = 'DELIVERED';

-- Include actual buffer (I/O) usage — shared hit/read block counts
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;

-- Suppress cost/row estimate numbers (useful for diffing plans in docs/tests,
-- since cost numbers change slightly between runs/versions)
EXPLAIN (COSTS OFF) SELECT ...;

-- Machine-readable output for tooling (JSON/XML/YAML also supported)
EXPLAIN (ANALYZE, FORMAT JSON) SELECT ...;

-- Everything at once — the "give me all the detail" combination
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT) SELECT ...;

-- Also show WAL generation (useful for data-modifying statements) and
-- the non-default planner/runtime settings in effect (PostgreSQL 13+/12+)
EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS) UPDATE ...;
```

| Option | Effect |
|---|---|
| `ANALYZE` | Executes the query; adds actual time/rows/loops |
| `BUFFERS` | Adds shared/local buffer hit, read, dirtied, written counts per node |
| `VERBOSE` | Adds output column lists, schema-qualifies names, shows per-node `Output:` |
| `COSTS OFF` | Hides cost/row/width estimates (plan shape only) |
| `FORMAT` | `TEXT` (default, human-readable) / `JSON` / `XML` / `YAML` (machine-readable) |
| `SETTINGS` | Shows non-default configuration parameters that affected planning |
| `WAL` | Shows WAL (write-ahead log) record/byte generation — data-modifying statements only |
| `TIMING` | Defaults to `ON` with `ANALYZE`; set `OFF` to reduce per-node timer overhead on very hot-path measurements |

### 5.5 Examples and expected output (against real `ecommerce_db` seed data)

```sql
EXPLAIN SELECT * FROM ecommerce_db.orders WHERE status = 'DELIVERED';
```

```text
                          QUERY PLAN
------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..1.12 rows=5 width=95)
   Filter: ((status)::text = 'DELIVERED'::text)
```

With only 10 rows in `orders`, PostgreSQL correctly decides a sequential
scan is the cheapest possible option — there is no index in the world that
beats reading one 8&nbsp;KB page holding all 10 rows. This is expected and
correct; do not be alarmed that a tiny table never uses an index (§8.1
revisits this explicitly).

```sql
EXPLAIN ANALYZE SELECT * FROM ecommerce_db.orders WHERE status = 'DELIVERED';
```

```text
                                                     QUERY PLAN
--------------------------------------------------------------------------------------------------------------
 Seq Scan on orders  (cost=0.00..1.12 rows=5 width=95) (actual time=0.011..0.014 rows=5 loops=1)
   Filter: ((status)::text = 'DELIVERED'::text)
   Rows Removed by Filter: 5
 Planning Time: 0.088 ms
 Execution Time: 0.032 ms
```

### 5.6 Line-by-line plan reading

```text
 Seq Scan on orders  (cost=0.00..1.12 rows=5 width=95) (actual time=0.011..0.014 rows=5 loops=1)
   Filter: ((status)::text = 'DELIVERED'::text)
   Rows Removed by Filter: 5
```

| Element | Meaning |
|---|---|
| `Seq Scan on orders` | The **operator** (physical algorithm) and the table it scans |
| `cost=0.00..1.12` | **Estimated** startup cost `0.00` .. total cost `1.12`, in the abstract cost unit from §4 |
| `rows=5` | **Estimated** number of rows this node will output |
| `width=95` | **Estimated** average row width in bytes, from `pg_stats.avg_width` |
| `actual time=0.011..0.014` | **Measured** milliseconds until first row .. until all rows produced |
| `rows=5` (in `actual`) | **Measured** number of rows actually output — compare this to the estimated `rows=5` above it |
| `loops=1` | How many times this node was executed. **If `loops > 1`** (common under a Nested Loop's inner side), the `actual time` shown is the **average per loop** — multiply `actual time × loops` to get the node's true total contribution |
| `Filter: ...` | A row-by-row condition applied *after* fetching, that did **not** reduce the number of pages read (contrast with an `Index Cond`, which narrows what's fetched in the first place) |
| `Rows Removed by Filter: 5` | How many rows were fetched and then discarded by the filter — a high number here relative to rows kept is itself a signal that an index on the filtered column could help |

**Indentation is nesting.** Every plan is a tree, printed top-down with
child nodes indented under their parent and marked with `->`. The
**innermost, most-indented nodes execute first**; their output rows feed
upward into their parent, and so on until the outermost (least indented)
node — which is what ultimately returns to you. Read the *innermost* lines
first when tracing "what happens first," but read the *outermost* line
first when tracing "what is fundamentally being computed."

```text
 Hash Join  (cost=1.34..2.61 rows=8 width=110)          ← executes LAST, produces final rows
   Hash Cond: (oi.order_id = o.order_id)
   ->  Seq Scan on order_items oi  (cost=0.00..1.15 rows=15 width=14)   ← probe side, runs per Hash Join iteration
   ->  Hash  (cost=1.10..1.10 rows=10 width=100)         ← builds the hash table
         ->  Seq Scan on orders o  (cost=0.00..1.10 rows=10 width=100)  ← executes FIRST (feeds Hash)
```

### 5.7 Internal mechanics

`EXPLAIN ANALYZE` works by wrapping every node in the executor with a timer
(via `gettimeofday()`/high-resolution clock calls) that starts on entry to
the node's "get next row" function and accumulates until execution
finishes, plus a counter incremented on every row produced. This
instrumentation itself has measurable overhead — timing many small, fast
nodes (like a Nested Loop with a million inner-loop iterations) can add
meaningfully to the reported total time. This is expected: `EXPLAIN ANALYZE`
overhead is usually small relative to overall runtime, but on very hot,
very fast queries, the reported `Execution Time` can be noticeably higher
than the query's normal (un-instrumented) runtime.

### 5.8 Common mistakes

> **⚠️ Warnings**
> 1. **Reading `EXPLAIN` (no `ANALYZE`) and trusting the estimates
>    blindly.** Estimated costs and rows are only as good as the statistics
>    behind them (§2–§3). A plan can look "obviously fine" on paper and
>    still be catastrophically slow in reality if the estimates are wrong.
>    Always confirm with `EXPLAIN ANALYZE` (inside a transaction with
>    `ROLLBACK` for anything that writes) before declaring a query fixed.
> 2. **Running `EXPLAIN ANALYZE` on an `UPDATE`/`DELETE`/`INSERT` directly
>    against production without a transaction wrapper.** Covered above —
>    it is not a simulation. Wrap it in `BEGIN; ... ROLLBACK;` every time,
>    without exception, unless you genuinely intend to commit the change.
> 3. **Ignoring the estimated-vs-actual row gap.** Seeing
>    `rows=1000` (estimated) next to `rows=46000` (actual) and moving on
>    without investigating is the single most common way an obvious
>    statistics problem goes unfixed for months.
> 4. **Comparing costs across differently-configured servers or after
>    partial cache warm-up.** Cost is a unitless estimate calibrated to
>    *your* `postgresql.conf` settings; actual time is affected by whether
>    the needed pages were already in the buffer cache (`shared_buffers`) or
>    the OS page cache. Run `EXPLAIN (ANALYZE, BUFFERS)` and look at
>    `shared hit` vs. `shared read` to tell the difference between "fast
>    because well-indexed" and "fast because it happened to be cached from
>    the previous run."
> 5. **Reading only the top line.** The most expensive individual node is
>    frequently buried several levels deep, not at the root. Scan every
>    node's cost and actual time, not just the outermost one.

### 5.9 Edge cases

**Parallel query plans. `[PostgreSQL]`** For large scans/aggregates,
PostgreSQL can split work across multiple background worker processes. You
will see this as `Gather` or `Gather Merge` nodes:

```text
 Finalize Aggregate  (cost=52341.23..52341.24 rows=1 width=8)
   ->  Gather  (cost=52341.02..52341.23 rows=2 width=8)
         Workers Planned: 2
         ->  Partial Aggregate  (cost=51341.02..51341.03 rows=1 width=8)
               ->  Parallel Seq Scan on sales_fact_2024  (cost=0.00..48214.00 rows=833334 width=0)
```

- `Gather` collects rows from N parallel workers, each running an identical
  copy of the sub-plan under it on a slice of the data, and (for unordered
  paths) concatenates their output with no guaranteed order.
- `Gather Merge` is the ordered variant — used when each worker's output is
  already sorted and the parent needs a single sorted stream, so it does a
  merge (see §8.6 for the Merge Join's identical merging idea) rather than a
  simple concatenation.
- Parallelism is only *considered* above `min_parallel_table_scan_size`
  (default 8 MB) and is capped by `max_parallel_workers_per_gather`
  (default 2). Not every operator has a parallel-safe implementation
  (window functions with certain frame types, for instance, historically
  forced serial execution) — this is a brief introduction; parallel query
  tuning in depth belongs to Chapter 18.

**Prepared statement plan caching. `[PostgreSQL]`** A `PREPARE`d statement
(or a parameterized query issued repeatedly via a driver, e.g. JDBC/psycopg2
`extended query protocol`) can be planned two ways: a **custom plan**,
re-planned fresh for the *actual* parameter values on every execution, or a
**generic plan**, planned once assuming "an average parameter" and reused
thereafter. PostgreSQL executes the first five calls with custom plans,
compares their average cost to what a generic plan would have cost, and
switches to the generic plan if it looks cheap enough on average
(`plan_cache_mode` can force this behavior: `auto` (default) / `force_custom_plan`
/ `force_generic_plan`).

> **⚠️ Warning**
> A generic plan is optimized for the *typical* parameter value, not the
> value in front of it right now. A customer-support lookup planned
> generically for "a typical customer with 6 orders" — landing on a Nested
> Loop with an index probe — can become disastrous the moment it's executed
> for an outlier VIP customer with 40,000 orders, where a Hash Join would
> have been far cheaper. If a parameterized query is fast for most inputs
> but occasionally catastrophic, plan caching for skewed parameter values is
> a prime suspect — force a custom plan (`SET plan_cache_mode = force_custom_plan;`
> for the session, or structure the query/ORM to avoid over-eager plan
> reuse) and re-test.

### 5.10 When to reach for EXPLAIN

- Before adding an index "because it seems like it should help" — confirm
  the planner would actually *use* it (`EXPLAIN` on the query with the
  index added in a scratch/staging environment, or check the estimated plan
  after creating it).
- Any time a query's runtime is worse than the data volume seems to justify.
- After a large data change (bulk load, mass delete, migration) — to catch
  statistics drift before it becomes an incident (§9.3).
- When comparing two candidate rewrites of the same query — `EXPLAIN` both
  and compare estimated cost *and* `EXPLAIN ANALYZE` both and compare actual
  time; never trust one without the other.
- Before shipping a query that will run frequently or against a large,
  growing table — cheap now with 10,000 rows is not evidence it will stay
  cheap at 10,000,000.

### 5.11 Real-world use cases

- Diagnosing a support ticket: "the customer dashboard is slow" →
  `EXPLAIN ANALYZE` the dashboard's underlying query, find the expensive
  node, fix it.
- Code review: a pull request adds a new reporting query against a large
  table — reviewers ask for the `EXPLAIN ANALYZE` output as evidence it
  won't regress production.
- Capacity planning: comparing `EXPLAIN (ANALYZE, BUFFERS)` before and after
  a schema change (new index, denormalization, partitioning) to quantify
  the actual I/O reduction, not just a "feels faster" impression.
- Post-incident review: attaching a saved `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`
  plan to an incident report as evidence of root cause (bad estimate → bad
  plan → timeout).

### 5.12 Dialect comparison — reading query plans across engines

| Engine | Estimated plan | Plan + actual execution | Notes |
|---|---|---|---|
| **PostgreSQL** | `EXPLAIN` | `EXPLAIN ANALYZE` | `FORMAT {TEXT\|JSON\|XML\|YAML}`, `BUFFERS`, `COSTS OFF`, `SETTINGS`, `WAL` |
| **MySQL / MariaDB** `[MySQL]` | `EXPLAIN` | `EXPLAIN ANALYZE` (**MySQL 8.0.18+ only**; returns a text tree with actual timing, unlike `EXPLAIN`'s tabular output) | Use `EXPLAIN FORMAT=JSON` for the richest estimated-plan detail (cost, filtered %) before 8.0.18 |
| **Oracle** `[Oracle]` | `EXPLAIN PLAN FOR <query>;` then `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);` | `DBMS_XPLAN.DISPLAY_CURSOR` (after actually running the query, with `gather_plan_statistics` hint or `STATISTICS_LEVEL=ALL`) to see actual vs. estimated rows (`A-Rows` vs `E-Rows` columns) | Oracle's optimizer is cost-based (CBO) with a broadly analogous statistics/histogram model |
| **SQL Server** `[SQL Server]` | *Estimated Execution Plan* (Ctrl+L in SSMS) or `SET SHOWPLAN_ALL ON` | *Actual Execution Plan* (Ctrl+M) or `SET STATISTICS IO, TIME ON` for text I/O and CPU time | SSMS's graphical plan is the primary interface; thicker arrows indicate more rows flowing between operators, directly analogous to reading `rows=` in PostgreSQL's text plan |

> **Important Notes**
> - The *concepts* — cost-based optimization, statistics-driven cardinality
>   estimation, a tree of physical operators, estimated vs. actual
>   comparison — are near-universal across every mainstream RDBMS. Only the
>   command syntax and presentation format differ. Everything you learn in
>   this chapter about *how to think about a plan* transfers directly.
> - MySQL's optimizer historically used a simpler cost model than
>   PostgreSQL/Oracle/SQL Server and, until relatively recently, lacked true
>   histograms (added in MySQL 8.0) — cardinality misestimation on skewed
>   data was historically a sharper edge in MySQL than in the other three.

---

## 6. Reading the Plan Tree — a Worked Example

Let's connect §5.6's rules to a slightly richer, real, reproducible
`ecommerce_db` query.

```sql
EXPLAIN ANALYZE
SELECT u.username, o.order_id, o.order_date, oi.quantity, p.product_name
FROM ecommerce_db.users u
JOIN ecommerce_db.orders o      ON o.user_id = u.user_id
JOIN ecommerce_db.order_items oi ON oi.order_id = o.order_id
JOIN ecommerce_db.products p     ON p.product_id = oi.product_id
WHERE u.username = 'arjun_k';
```

```text
                                                    QUERY PLAN
-------------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=0.30..8.52 rows=3 width=140) (actual time=0.045..0.089 rows=3 loops=1)
   ->  Nested Loop  (cost=0.15..7.06 rows=2 width=112) (actual time=0.030..0.050 rows=2 loops=1)
         ->  Nested Loop  (cost=0.00..2.32 rows=2 width=76) (actual time=0.018..0.026 rows=2 loops=1)
               ->  Seq Scan on users u  (cost=0.00..1.10 rows=1 width=17) (actual time=0.010..0.011 rows=1 loops=1)
                     Filter: ((username)::text = 'arjun_k'::text)
                     Rows Removed by Filter: 7
               ->  Seq Scan on orders o  (cost=0.00..1.20 rows=2 width=63) (actual time=0.005..0.007 rows=2 loops=1)
                     Filter: (user_id = u.user_id)
                     Rows Removed by Filter: 8
         ->  Seq Scan on order_items oi  (cost=0.00..1.15 rows=1 width=45) (actual time=0.004..0.005 rows=1 loops=2)
               Filter: (order_id = o.order_id)
               Rows Removed by Filter: 14
   ->  Seq Scan on products p  (cost=0.00..1.10 rows=1 width=91) (actual time=0.003..0.004 rows=1 loops=3)
         Filter: (product_id = oi.product_id)
         Rows Removed by Filter: 9
 Planning Time: 0.210 ms
 Execution Time: 0.132 ms
```

**Reading it, innermost-first:**

1. `Seq Scan on users` filters to `username = 'arjun_k'` — 1 row found (out
   of 8), matching the estimate exactly.
2. That single user row feeds the next `Nested Loop`, which scans `orders`
   **once** (`loops=1`) filtering `user_id = u.user_id` — finds 2 matching
   orders (Arjun has orders #1 and #3 in the seed data).
3. For **each** of those 2 orders, `order_items` is scanned again — note
   `loops=2` — once per outer row, and `Rows Removed by Filter: 14` is the
   average *per loop*.
4. For **each** matching order item (2 orders → 1 item each here, hence
   `loops=3` overall by the time we reach `products`... actually 3 total
   invocations across both outer order rows), `products` is looked up once
   per item.

Even though every join here is a **Nested Loop**, this is entirely
appropriate: every table is tiny (single-digit to low-teens rows), so
`loops` stays tiny and the total cost is negligible — this is precisely
the "small outer, cheap-to-rescan inner" situation where Nested Loop wins
(§8.4). At `analytics_db` scale, the *identical query shape* joining
million-row tables without any index would be catastrophic — which is
exactly Case Study 2 (§9.2).

> **Important Notes**
> - `width` is shown *per node*, and grows as more columns get added going
>   up the tree (e.g. `width=76` → `width=112` → `width=140` above) — each
>   join widens the row by however many bytes the newly joined columns add.
> - `Planning Time` and `Execution Time` are reported once, at the very
>   bottom, and are wall-clock — not part of any individual node's
>   `cost=`/`actual time=` figures.

---

## 7. Execution Plan Operators, In Depth

Chapter 16 introduced the *concept* of each scan type. Here we cover the
**decision logic** — when the planner reaches for each operator, and its
cost profile — plus the join and processing operators Chapter 16 didn't
touch.

### 7.1 Sequential Scan

**What it is.** Reads every page of a table, top to bottom, evaluating any
filter row-by-row as it goes (Chapter 16, §"scan basics").

**When the planner chooses it.**
- The table is small enough that a full read is barely more expensive than
  an index lookup (as with every `ecommerce_db` example above).
- No index exists on the filtered/joined column at all.
- The filter is **unselective** — matches a large fraction of rows — so
  reading the whole table sequentially is actually *cheaper* than paying
  random-I/O costs to look up a majority of rows via an index anyway.
- The query has no `WHERE` clause at all — every row must be visited
  regardless.

**Cost profile.** Linear in table size:
`pages × seq_page_cost + rows × cpu_tuple_cost`. Cheap *per page*, but
scales with the *entire* table regardless of how selective the filter is —
this is exactly why it becomes the wrong choice as a table grows and a
filter stays selective (Case Study 1).

### 7.2 Index Scan

**What it is.** Walks a B-tree (or other index) to find matching entries,
then fetches each matching row from the heap individually (one random page
access per row, in the worst case). Chapter 16 covers the B-tree structure
itself in depth.

**When the planner chooses it.** The filter is selective (matches a small
fraction of rows) **and** the matching rows are either few enough, or
well-correlated enough with physical storage order, that the random-access
cost stays low. An `Index Only Scan` variant (Chapter 16) additionally
avoids the heap fetch entirely when every needed column is present in the
index itself and the visibility map confirms the pages are all-visible.

**Cost profile.** Roughly `startup (tree descent, ~O(log n)) + matching_rows × random_page_cost adjusted by correlation`.
Cheap when selective; the per-row random-access cost means it does **not**
scale gracefully once the number of matching rows grows large — which is
exactly the gap Bitmap Scan fills.

### 7.3 Bitmap Scan (Bitmap Index Scan + Bitmap Heap Scan)

**What it is.** A **two-phase** operation, always shown as a pair of nodes
working together:

```text
 Bitmap Heap Scan on sales_fact_2023  (cost=852.30..14203.11 rows=4566 width=36)
   Recheck Cond: (sale_date = '2023-06-15'::date)
   ->  Bitmap Index Scan on idx_sales_fact_2023_sale_date  (cost=0.00..851.15 rows=4566 width=0)
         Index Cond: (sale_date = '2023-06-15'::date)
```

1. **Bitmap Index Scan** walks the index, but instead of fetching rows
   immediately, it builds an in-memory **bitmap** marking which heap
   pages contain at least one matching row (or, for small result sets, a
   bitmap of exact matching row locations).
2. **Bitmap Heap Scan** then visits only the *flagged* heap pages, **in
   physical page order** — sorting the access pattern turns what would
   have been scattered random I/O into a single sequential-ish sweep — and
   rechecks the actual condition on each candidate row (the `Recheck Cond`;
   necessary because for very large bitmaps PostgreSQL "loses" bits and
   falls back to page-level granularity to save memory, so not every
   flagged row is guaranteed to actually match).

**Why this exists — the middle ground.** A plain Index Scan pays a random
page access *per matching row*. A Seq Scan pays a sequential page access
*per table row*, matching or not. When a *moderate* number of rows match —
too many for random per-row access to stay cheap, but too few to justify
reading the entire table — Bitmap Scan wins by paying for **exactly the
pages that contain matches**, read in an I/O-friendly sorted order, with no
wasted reads of guaranteed-non-matching pages. This is also precisely the
scenario where a column's low `correlation` statistic (§2.2) matters: with
scattered matching rows (low correlation), a plain Index Scan's per-row
random fetches get expensive fast, while Bitmap Heap Scan's page-sorted
sweep tolerates scatter far better — which is exactly why the planner
favors Bitmap Scan for `sales_fact.sale_date` in Case Study 1, once an
index exists.

**Cost profile.** Between Index Scan and Seq Scan: pays for index descent
plus one I/O per *distinct matching page* (not per matching row), plus a
CPU cost to build/consult the bitmap.

### 7.4 Nested Loop Join

**What it is.** For every row produced by the **outer** input, scan the
**inner** input looking for matches — literally two nested loops:

```text
for each outer_row in outer_input:
    for each inner_row in inner_input:
        if join_condition(outer_row, inner_row): emit(outer_row, inner_row)
```

**When the planner chooses it.** The outer input is small, and the inner
input can be probed **cheaply and repeatedly** — almost always because an
index exists on the inner side's join column, turning the inner "loop" into
an `O(log n)` index lookup per outer row rather than a full re-scan.

**Why it's disastrous without an index on the inner side.** If the inner
side has no usable index, each pass through the inner loop degrades to a
full **sequential scan** of the inner table, repeated once per outer row.
For `n` outer rows and an inner table of `m` rows, that's `O(n × m)` total
row comparisons — for `n = 12` and `m = 1,450,000`, roughly 17.4 million row
comparisons for a query that should have touched barely more than `12 +
1,450,000` rows total. This is precisely Case Study 2 (§9.2), and it is the
textbook example every experienced engineer immediately checks for the
moment they see a Nested Loop with a **Seq Scan** as its inner child and
`loops` in the double digits or higher.

**Cost profile.** `outer_rows × (inner_startup_cost + inner_total_cost)`
— cheap when the inner side is O(log n) per probe (indexed), catastrophic
when it's O(m) per probe (un-indexed).

### 7.5 Hash Join

**What it is.** A two-phase algorithm for equality joins:

1. **Build phase.** Scan the smaller input (by estimated size) once, and
   build an in-memory **hash table** keyed on the join column.
2. **Probe phase.** Scan the larger input once, hashing each row's join
   key and looking it up in the hash table, emitting matches.

```text
 Hash Join  (cost=145.00..98234.55 rows=1200000 width=48)
   Hash Cond: (sf.customer_key = dc.customer_key)
   ->  Seq Scan on sales_fact sf  (cost=0.00..73520.00 rows=5000000 width=28)
   ->  Hash  (cost=82.00..82.00 rows=5000 width=24)
         ->  Seq Scan on dim_customer dc  (cost=0.00..82.00 rows=5000 width=24)
```

**When the planner chooses it.** Both inputs are relatively large, the
join condition is **equality** (hash joins cannot handle inequality/range
join conditions — that's Merge Join or Nested Loop territory), and there's
no advantageous index to exploit instead. This is the default "large
join, no better option" workhorse — notice it is also what turns a
would-be Nested Loop disaster (§7.4) into an efficient `O(n + m)` operation
whenever the planner's row estimates are accurate enough to recognize a
Hash Join is available and cheaper.

**Memory considerations.** The hash table is built in `work_mem` (default
4 MB — commonly tuned much higher, e.g. 64 MB+, for analytical workloads).
If the build-side input is larger than the planner expected and the hash
table would exceed `work_mem`, PostgreSQL **spills to disk**, partitioning
both the build and probe sides into batches written to temp files —
functionally correct, but far slower than a fully in-memory hash join.
`EXPLAIN ANALYZE` surfaces this directly:

```text
 Hash Join  (cost=... rows=... width=...) (actual time=... rows=... loops=1)
   ->  Hash  (cost=... rows=... width=...) (actual time=... rows=... loops=1)
         Buckets: 65536  Batches: 4  Memory Usage: 4096kB
```

`Batches: 4` means the build side didn't fit in one `work_mem`-sized batch
and had to spill — `Batches: 1` is the fully-in-memory, ideal case.

### 7.6 Merge Join

**What it is.** Requires **both** inputs sorted on the join key (either
because they're already stored/indexed that way, or because the planner
adds explicit `Sort` nodes beneath them). With both streams sorted, the
join proceeds as a single synchronized pass — advancing whichever side has
the smaller current key, exactly like the merge step of merge-sort:

```text
 Merge Join  (cost=145234.00..298310.55 rows=5000000 width=48)
   Merge Cond: (sf.customer_key = dc.customer_key)
   ->  Index Scan using idx_sales_fact_customer on sales_fact sf  (cost=0.43..210000.00 rows=5000000 width=28)
   ->  Sort  (cost=430.11..442.61 rows=5000 width=24)
         Sort Key: dc.customer_key
         ->  Seq Scan on dim_customer dc  (cost=0.00..82.00 rows=5000 width=24)
```

**When the planner chooses it.** Both inputs are already sorted (e.g., via
an index that naturally produces sorted output) or cheap to sort, and — in
particular — for **very large** join inputs where a Hash Join's hash table
would be expensive to build/spill, a single sequential merge pass over
pre-sorted data can win. It's also the natural choice when the query has an
`ORDER BY` on the join key anyway, since the sort is "free" (already
required for other reasons) rather than an extra cost charged only to
enable the join.

**Cost profile.** `O(n + m)` for the merge itself, **plus** the cost of
getting both sides sorted if they weren't already — which is why Merge
Join is most attractive when at least one side is sorted "for free" (via an
existing index) rather than requiring an explicit, expensive `Sort` node.

### 7.7 Sort

**What it is.** Orders its input according to a sort key. Needed for:

- An explicit `ORDER BY` that has no supporting index to satisfy it "for
  free."
- Preparing input for a **Merge Join** (§7.6) when the chosen inputs
  aren't already ordered by the join key.
- Some `GROUP BY` plans (specifically `GroupAggregate`, §7.8), which
  require sorted input.
- `DISTINCT` implemented via sort-then-dedupe (an alternative to
  `HashAggregate`-based `DISTINCT`).

**Cost profile.** `O(n log n)` CPU cost, and — critically — a **memory
ceiling**: sorting happens in `work_mem`; if the input to sort exceeds it,
PostgreSQL spills to a disk-based external merge sort. `EXPLAIN ANALYZE`
reports which happened:

```text
 Sort  (cost=... rows=... width=...) (actual time=... rows=... loops=1)
   Sort Key: sf.sale_date DESC
   Sort Method: quicksort  Memory: 4098kB      -- fit entirely in work_mem
```

vs.

```text
   Sort Method: external merge  Disk: 128344kB  -- spilled to disk — much slower
```

Seeing `external merge` on a hot query path is a strong, specific signal
that raising `work_mem` (globally or for that session/query) is worth
testing (Chapter 18 covers this tuning decision in detail).

### 7.8 Aggregate, HashAggregate, and GroupAggregate

Three related but distinct operators, all computing aggregate functions
(`COUNT`, `SUM`, `AVG`, etc. — Chapter 6):

| Operator | Used for | Requires sorted input? | Mechanism |
|---|---|---|---|
| **Aggregate** (plain) | A single aggregate with **no `GROUP BY`** (one output row total) | No | Streams every input row through the aggregate's running-state function once; trivial memory footprint |
| **HashAggregate** | `GROUP BY` with **no useful pre-existing order** | No | Builds an in-memory hash table keyed on the group-by column(s), one running aggregate state per distinct key — conceptually the aggregate analogue of a Hash Join build phase |
| **GroupAggregate** | `GROUP BY` when the input **is already sorted** by the group key (from an index, or a `Sort` node just beneath it) | Yes | Streams through sorted input, closing out and emitting one group's aggregate the moment the key value changes — never needs to hold more than the current group in memory |

```sql
EXPLAIN SELECT customer_key, SUM(amount) FROM analytics_db.sales_fact GROUP BY customer_key;
```

```text
 HashAggregate  (cost=123521.00..123571.00 rows=5000 width=12)
   Group Key: customer_key
   ->  Seq Scan on sales_fact  (cost=0.00..73520.00 rows=5000000 width=8)
```

Here, `sales_fact` isn't sorted by `customer_key`, and there are only 5,000
distinct groups — small enough to hash comfortably — so `HashAggregate` beats
paying for an explicit `Sort` of 5 million rows just to enable a
`GroupAggregate`. Compare against a query where the input already arrives
sorted (e.g., feeding off an index on `customer_key`):

```text
 GroupAggregate  (cost=0.43..185000.00 rows=5000 width=12)
   Group Key: customer_key
   ->  Index Scan using idx_sales_fact_customer on sales_fact  (cost=0.43..160000.00 rows=5000000 width=8)
```

**Memory consideration for `HashAggregate`.** Like `Hash Join`, its hash
table lives in `work_mem`. With a *very* high-cardinality `GROUP BY` (many
more distinct groups than the planner estimated — another cardinality
estimation failure mode), the hash table can outgrow memory; modern
PostgreSQL versions (13+) will spill excess groups to disk rather than
erroring out or ballooning memory unboundedly, but this is slower than an
in-memory hash aggregate — worth knowing exists even though it's a version-
dependent internal detail.

### 7.9 Join algorithm comparison

| | **Nested Loop** | **Hash Join** | **Merge Join** |
|---|---|---|---|
| **Best for** | Small outer input, indexed inner | Large inputs, equality condition, no useful index | Both inputs already sorted (or cheap to sort), especially very large inputs |
| **Join condition** | Any (`=`, `<`, `BETWEEN`, etc.) | Equality only | Any (equality most common; supports inequality with care) |
| **Memory needs** | Minimal | `work_mem` for hash table (can spill) | `work_mem` for sort if a `Sort` is needed (can spill) |
| **Big-O** | `O(n × m)` unindexed inner; `O(n log m)` indexed inner | `O(n + m)` | `O(n + m)` once sorted; `O(n log n + m log m)` if sorting required |
| **Catastrophic failure mode** | Un-indexed inner side at scale (§7.4, Case Study 2) | Hash table far bigger than estimated → disk spill, many batches | Both sides need expensive sorting the planner didn't anticipate |
| **Typical trigger** | Point lookups, small parameter-driven queries (`WHERE customer_id = ?`) | Ad hoc large joins, reporting queries, no supporting index | Large sorted joins, or joins that also need `ORDER BY` on the same key |

---

## 8. Case Studies: Diagnosing and Fixing Slow Queries

> **Important Notes**
> All `EXPLAIN (ANALYZE)` output in this section is **illustrative** — cost,
> row, and timing numbers are constructed to be internally consistent and
> realistic for the data volumes described (5,000,000-row partitioned
> `sales_fact`, or `ecommerce_db` conceptually scaled to production
> volume as explicitly noted), not captured from an actual run. Run these
> queries yourself against your own instance of `analytics_db` to see your
> real numbers — they'll be in the same ballpark but won't match exactly,
> since exact costs depend on your hardware's cost constants, cache state,
> and the specific random values `analytics_db.sql` generated for you.

### 8.1 Case Study 1 — Missing index forces a Seq Scan across a 5-million-row partitioned fact table

**Scenario.** An analyst needs every sale from a single day:

```sql
SELECT sale_id, customer_key, product_key, amount
FROM analytics_db.sales_fact
WHERE sale_date = '2023-06-15';
```

Recall from `analytics_db.sql`'s header that `sales_fact` is `RANGE
PARTITION`ed by `sale_date` into yearly partitions (`sales_fact_2022/2023/2024`,
~1.67 million rows each) and — per the file's own index list — indexes exist
on `customer_key` and `product_key`, but **not** on `sale_date` itself.
Partition pruning correctly narrows the query to just `sales_fact_2023`,
but *within* that partition, there is no way to avoid reading every row.

**Original plan:**

```text
 Seq Scan on sales_fact_2023 sf  (cost=0.00..39814.67 rows=4566 width=36) (actual time=0.031..612.489 rows=4566 loops=1)
   Filter: (sale_date = '2023-06-15'::date)
   Rows Removed by Filter: 1662101
 Planning Time: 0.312 ms
 Execution Time: 613.204 ms
```

**Diagnosis.** Look at the row estimate first, per §6.8's discipline: `rows=4566`
estimated vs. `rows=4566` actual — a **perfect** match. This immediately
rules out "bad statistics" as the culprit (histogram-based range/equality
estimation on `sale_date` is working correctly here). The real problem is
structural: there is **no index at all** on `sale_date` (only on
`customer_key` and `product_key`, per the schema), so even though the
planner correctly knows only 4,566 of 1,666,667 rows in this partition will
match (a highly selective 0.27%), it has **no cheaper access path available**
than reading the entire partition — this is Chapter 16's core lesson
applied directly: *the planner can only pick from paths that exist*. 613 ms
to fetch 4,566 rows out of 5 million total is the visible symptom.

**Fix — add a B-tree index on the partitioned column** (Chapter 16 §composite
& partial indexes covers index creation on partitioned tables in detail;
in PostgreSQL 11+, an index created on the parent automatically propagates
to every partition):

```sql
CREATE INDEX idx_sales_fact_sale_date ON analytics_db.sales_fact (sale_date);
```

**Improved plan:**

```text
 Bitmap Heap Scan on sales_fact_2023 sf  (cost=45.32..1720.55 rows=4566 width=36) (actual time=0.512..14.223 rows=4566 loops=1)
   Recheck Cond: (sale_date = '2023-06-15'::date)
   Heap Blocks: exact=4102
   ->  Bitmap Index Scan on sales_fact_2023_sale_date_idx  (cost=0.00..44.18 rows=4566 width=0) (actual time=0.398..0.398 rows=4566 loops=1)
         Index Cond: (sale_date = '2023-06-15'::date)
 Planning Time: 0.298 ms
 Execution Time: 14.891 ms
```

Note the planner chose **Bitmap Heap Scan**, not a plain Index Scan, per
§7.3's exact reasoning: `sale_date`'s `correlation` statistic is near zero
(rows were inserted via `random()` dates, so logical date order bears no
relation to physical storage order — confirmed back in §2.2), so the
4,566 matching rows are scattered across most of the partition's pages; the
bitmap's page-sorted heap sweep tolerates that scatter far better than
per-row random access would. **Result: 613 ms → 14.9 ms, roughly 41×
faster**, using the exact same query text — the entire fix was DDL.

### 8.2 Case Study 2 — Nested Loop over a large, unindexed join

> Foreign-key columns are **not** automatically indexed by PostgreSQL — only
> primary-key and explicitly unique columns get an automatic index. Every
> `REFERENCES` column in `ecommerce_db.sql` (`orders.user_id`,
> `order_items.order_id`, `payments.order_id`, `reviews.product_id`, …) is a
> candidate for exactly this problem the moment the table grows past
> "toy demo" size. **This is precisely why Chapter 16 stresses indexing
> your FK/join columns explicitly** — PostgreSQL will not do it for you.

**Scenario — illustrative, `ecommerce_db` scaled to production volume**
(1,200,000 `orders`, 1,450,000 `payments`; an index on `orders.user_id` was
already added for a customer-lookup feature, but nobody thought to index
`payments.order_id`, since it "worked fine" in testing against the 10-row
seed data). A customer-support tool loads a single customer's order and
payment history:

```sql
SELECT o.order_id, o.order_date, o.status, p.amount, p.status AS payment_status
FROM ecommerce_db.orders o
JOIN ecommerce_db.payments p ON p.order_id = o.order_id
WHERE o.user_id = 48219
ORDER BY o.order_date DESC;
```

**Original plan:**

```text
 Nested Loop  (cost=0.43..40850.22 rows=12 width=58) (actual time=2.104..1432.607 rows=12 loops=1)
   ->  Index Scan using idx_orders_user_id on orders o  (cost=0.43..8.45 rows=12 width=42) (actual time=0.021..0.058 rows=12 loops=1)
         Index Cond: (user_id = 48219)
   ->  Seq Scan on payments p  (cost=0.00..3402.50 rows=1 width=24) (actual time=59.271..119.375 rows=1 loops=12)
         Filter: (order_id = o.order_id)
         Rows Removed by Filter: 1449999
 Planning Time: 0.415 ms
 Execution Time: 1432.891 ms
```

**Diagnosis.** The outer side is exactly right: an `Index Scan` finds the
12 matching orders cheaply (`8.45` cost, sub-millisecond). But look at the
inner side: `Seq Scan on payments`, with `loops=12` — for **each** of the
12 orders, PostgreSQL scans **all 1.45 million** payment rows looking for
the one that matches, because `payments.order_id` has no index at all. The
per-loop `actual time=59.271..119.375` (≈119 ms **per loop**) multiplied by
12 loops accounts for nearly the entire 1,432 ms runtime. This is the exact
`O(n × m)` failure mode described in §7.4 — the planner had no cheaper
option to offer, because none existed. (Note also that the row estimate
here, `rows=1` per loop, is entirely correct — this is not a statistics
problem; it's a missing-index problem, just like Case Study 1, but showing
up as a join operator's inner side rather than a base-table scan.)

**Fix:**

```sql
CREATE INDEX idx_payments_order_id ON ecommerce_db.payments (order_id);
```

**Improved plan:**

```text
 Nested Loop  (cost=0.86..58.61 rows=12 width=58) (actual time=0.034..0.398 rows=12 loops=1)
   ->  Index Scan using idx_orders_user_id on orders o  (cost=0.43..8.45 rows=12 width=42) (actual time=0.019..0.052 rows=12 loops=1)
         Index Cond: (user_id = 48219)
   ->  Index Scan using idx_payments_order_id on payments p  (cost=0.43..4.18 rows=1 width=24) (actual time=0.021..0.023 rows=1 loops=12)
         Index Cond: (order_id = o.order_id)
 Planning Time: 0.288 ms
 Execution Time: 0.441 ms
```

The plan **shape** didn't change — it's still a Nested Loop, which is
entirely appropriate for 12 outer rows — but the inner side flipped from a
1.45-million-row Seq Scan to a sub-millisecond Index Scan. **Result: 1,432.9
ms → 0.44 ms, roughly 3,250× faster.** This is the textbook illustration of
§7.4's claim: Nested Loop itself was never the problem; an un-indexed inner
side was.

### 8.3 Case Study 3 — Stale statistics after a bulk load cause a row-estimate mismatch

**Scenario.** A marketing team runs a flash-sale campaign and bulk-loads
45,000 new `sales_fact` rows via `COPY`, all misattributed by a referral-
code bug to a single test account, `customer_key = 4821` (previously an
unremarkable customer averaging the table's typical ~1,000 rows). The
`COPY` completes, but nobody runs `ANALYZE` afterward, and autovacuum's
analyze threshold hasn't triggered yet. `pg_stats` for `customer_key` still
reflects the *pre-bulk-load* distribution recorded in §2.2, unaware that
customer 4821 now accounts for 46,000 rows, not ~1,000.

```sql
SELECT sale_id, sale_date, product_key, amount
FROM analytics_db.sales_fact
WHERE customer_key = 4821
ORDER BY sale_date DESC
LIMIT 100;
```

**Original plan (statistics stale):**

```text
 Limit  (cost=0.43..3521.18 rows=100 width=28) (actual time=8.211..2984.520 rows=100 loops=1)
   ->  Index Scan Backward using sales_fact_sale_date_idx on sales_fact sf  (cost=0.43..161245.90 rows=1000 width=28)
                                                                            (actual time=8.204..2984.301 rows=100 loops=1)
         Filter: (customer_key = 4821)
         Rows Removed by Filter: 892114
 Planning Time: 0.267 ms
 Execution Time: 2984.699 ms
```

**Diagnosis.** The planner, believing `customer_key = 4821` matches only
~1,000 rows (the old, pre-campaign estimate), chose a plan optimized for
"walk the `sale_date` index backward, and stop as soon as 100 matching rows
turn up — surely that will happen almost immediately." In reality, because
the *distribution itself* changed (not the total row count, but its
skew), the planner's mental model of the data is simply wrong. Confirming
this is exactly the §3.3/§6.8 discipline: **the estimated `rows=1000` next
to the eventual reality of scanning 892,214 rows before finding 100
matches is the smoking gun.** Notice this plan isn't even "wrong" in
structure — `Index Scan Backward` + `Limit` is a perfectly reasonable
strategy *if* the estimate were correct; it's a good plan built on a false
premise, which is functionally indistinguishable from a bad plan once it's
running.

**Fix — refresh statistics:**

```sql
ANALYZE analytics_db.sales_fact;
```

`ANALYZE` re-samples the table, and this time customer 4821's true weight
is large enough to be captured directly in the **MCV list** (§2.2) rather
than smoothed into the uniform "average customer" assumption.

**Improved plan (statistics current):**

```text
 Limit  (cost=1847.30..1847.55 rows=100 width=28) (actual time=18.442..18.501 rows=100 loops=1)
   ->  Sort  (cost=1847.30..1962.30 rows=46000 width=28) (actual time=18.438..18.470 rows=100 loops=1)
         Sort Key: sale_date DESC
         Sort Method: top-N heapsort  Memory: 32kB
         ->  Bitmap Heap Scan on sales_fact sf  (cost=402.11..1621.44 rows=46000 width=28) (actual time=1.204..12.882 rows=46000 loops=1)
               Recheck Cond: (customer_key = 4821)
               ->  Bitmap Index Scan on idx_sales_fact_customer  (cost=0.00..390.61 rows=46000 width=0) (actual time=0.988..0.988 rows=46000 loops=1)
                     Index Cond: (customer_key = 4821)
 Planning Time: 0.301 ms
 Execution Time: 18.699 ms
```

With an accurate `rows=46000` estimate, the planner correctly abandons the
"walk the date index and hope 100 rows turn up soon" strategy (a bet that
only pays off when matches are rare) in favor of: fetch all 46,000 matching
rows via `Bitmap Heap Scan` on the *customer* index (now cheap, since the
estimate correctly reflects how many rows that is), then sort and take the
top 100. **Result: 2,984.7 ms → 18.7 ms, roughly 160× faster** — achieved
without touching a single index or rewriting the query; the fix was purely
`ANALYZE`. This case study is the direct, concrete illustration of §2.3's
claim: stale statistics can sabotage an otherwise well-indexed, well-
written query.

> **Important Notes — what all three case studies have in common**
> In every case, the diagnostic sequence was identical: **read the plan
> tree bottom-up, compare estimated rows to actual rows at every node, and
> identify whether the gap (if any) is a missing access path (Case Studies
> 1 and 2) or a wrong cardinality estimate (Case Study 3).** That single
> habit — estimate vs. actual, at every node — resolves the overwhelming
> majority of real-world "why is this slow" investigations.

---

## 9. Practice Questions

No answers are provided — work through each by applying this chapter's
concepts, and check your reasoning by actually running the query (with
`EXPLAIN ANALYZE`, inside a transaction with `ROLLBACK` for anything that
writes) against your own `ecommerce_db` / `analytics_db`.

1. Given `EXPLAIN` output showing `Seq Scan on reviews (cost=0.00..1.09 rows=6 width=...)`
   against `ecommerce_db.reviews`, explain why a Seq Scan is the *correct*
   choice here rather than evidence of a missing index.

2. You run `EXPLAIN ANALYZE` on a query and see
   `rows=50` (estimated) vs. `rows=48000` (actual) at a `Seq Scan` node
   directly beneath a `Nested Loop`. Predict what effect this misestimate
   likely had on the join algorithm the planner chose, and why.

3. A query filters `analytics_db.sales_fact` on `product_key = 117`. An
   index exists on `product_key`. Would you expect an `Index Scan` or a
   `Bitmap Heap Scan`? What single statistic from `pg_stats` would you check
   to decide, and why?

4. Write (don't run) the `EXPLAIN`-syntax invocation you'd use to see actual
   buffer hit/read counts for a query, in JSON format, without executing
   any data-modifying side effects.

5. A `Hash Join` node's `Hash` child reports `Batches: 8`. What does this
   tell you, and what configuration parameter would you investigate raising
   first?

6. Given two tables of 10 rows and 2,000,000 rows respectively, joined on
   equality with no supporting index on either side, which join algorithm
   would you expect PostgreSQL to choose, and why not Nested Loop?

7. Given two tables where both sides are already sorted by the join key
   (e.g., both scanned via an index on that column), which join algorithm
   becomes newly attractive, and what specifically makes it cheap in this
   situation?

8. You see `Sort Method: external merge Disk: 340211kB` in an
   `EXPLAIN ANALYZE` plan. What happened, and what's the first thing you'd
   try to fix it?

9. A `GROUP BY` query on a table with only 4 distinct group values shows a
   `HashAggregate`. A near-identical query, `GROUP BY`-ing a column with
   3 million distinct values, might instead show something different in
   modern PostgreSQL if the estimate is very wrong — what, and why?

10. Explain, in your own words, why `EXPLAIN` (without `ANALYZE`) can never
    by itself tell you that a query's statistics are stale — what would
    you need to add to find out?

11. A prepared statement generic plan chooses `Nested Loop` with an indexed
    inner side, tuned for "a typical customer with a handful of orders."
    Describe a realistic parameter value for which this generic plan would
    perform badly, and explain the mechanism (not just "it would be slow").

12. You're asked to review a pull request that adds a new reporting query
    joining four tables in `analytics_db`. What specific things would you
    ask to see in the PR description or a comment before approving it,
    based on this chapter?

---

## 10. Chapter-Ending Challenge

You're handed the following slow query against `analytics_db`, reported by
a stakeholder as "the regional sales report, which used to take a couple of
seconds, now takes over a minute":

```sql
SELECT
    ds.region,
    dp.category,
    dc.segment,
    SUM(sf.amount)      AS total_revenue,
    COUNT(*)            AS num_sales
FROM analytics_db.sales_fact sf
JOIN analytics_db.dim_store    ds ON ds.store_key = sf.store_key
JOIN analytics_db.dim_product  dp ON dp.product_key = sf.product_key
JOIN analytics_db.dim_customer dc ON dc.customer_key = sf.customer_key
WHERE EXTRACT(YEAR FROM sf.sale_date) = 2024
  AND dc.segment = 'ENTERPRISE'
GROUP BY ds.region, dp.category, dc.segment
ORDER BY total_revenue DESC;
```

You're also told: `dim_customer` was reloaded three weeks ago as part of a
segmentation refresh (dropped and re-populated with new segment
assignments), and nobody has mentioned running `ANALYZE` since.

**Produce a full diagnosis-and-fix writeup**, in the style of §8's case
studies:

1. Run (or reason through) `EXPLAIN ANALYZE` on this query. Which specific
   part of the `WHERE` clause do you expect prevents partition pruning
   and/or defeats any index that might otherwise exist on `sale_date`, and
   why? (Hint: think about what a function wrapped around a column does to
   the planner's ability to use that column's statistics or an index on
   it, per §3.4's table.)
2. Identify at least one additional structural or statistics issue beyond
   the one in step 1 — consider what you were told about `dim_customer`'s
   recent reload, and connect it to the concepts in §2 and §3.
3. Propose a concrete fix for each problem you found — this may include a
   query rewrite, a new index, an `ANALYZE`, or some combination. Justify
   each fix by naming which operator/estimate it's meant to change.
4. Describe, in plan-tree terms, what you'd expect the **improved** plan
   to look like — which operators, roughly which order — and what you'd
   check in `EXPLAIN ANALYZE`'s output to confirm the fix actually worked
   rather than just assuming it did.

There is no answer key. Defend your writeup the way you would in an actual
code review or incident postmortem — the goal is the reasoning, not a
specific magic query.

---

## Key Takeaways

- A SQL statement passes through five stages before returning a single
  row: **parse → validate → rewrite → plan/optimize → execute**. Only the
  last stage touches real data.
- The **planner** chooses among candidate plans by comparing estimated
  **cost**, which is built from table/index statistics (`pg_statistic` /
  `pg_stats`, refreshed by `ANALYZE`) fed into a **cardinality estimate**
  for every step.
- **`EXPLAIN`** shows the planner's estimate without running anything;
  **`EXPLAIN ANALYZE`** actually executes the query and reports real timing
  and row counts alongside the original estimates — and for data-modifying
  statements, it performs the modification for real, so always wrap it in
  `BEGIN; ... ROLLBACK;` unless you mean to commit.
- The single most valuable diagnostic habit in this chapter: **compare
  estimated rows to actual rows at every node.** A large gap points
  directly at stale/insufficient statistics; an accurate estimate paired
  with a slow plan points at a missing access path (index) instead.
- **Seq Scan**, **Index Scan**, and **Bitmap Scan** (Bitmap Index + Bitmap
  Heap working together) form a spectrum from "read everything" to "read
  exactly the matching rows," with Bitmap Scan as the I/O-friendly middle
  ground for moderately selective filters, especially on poorly-correlated
  columns.
- **Nested Loop**, **Hash Join**, and **Merge Join** are chosen based on
  input sizes, available indexes, and whether inputs are already sorted.
  Nested Loop is excellent with a small outer and an indexed inner, and
  catastrophic (`O(n × m)`) without one.
- **Sort** and the three aggregate operators (**Aggregate**,
  **HashAggregate**, **GroupAggregate**) all have memory ceilings
  (`work_mem`) beyond which they spill to disk — visible directly in
  `EXPLAIN ANALYZE`'s `Sort Method` / `Batches` output.
- Parallel plans (`Gather` / `Gather Merge`) and prepared-statement plan
  caching are both edge cases where "the plan you'd expect" and "the plan
  you actually get" can diverge — know they exist before they surprise you
  in production.
- Every case study in this chapter resolved to one of exactly three root
  causes: a **missing index** (Case Studies 1 and 2) or **stale statistics**
  (Case Study 3) — the two failure modes you will encounter, by far, most
  often in real systems.

## What's Next

Chapter 18 — **SQL Performance Optimization** — takes everything from
Chapters 16 and 17 (index structures, planner internals, `EXPLAIN` fluency)
and turns it into a repeatable tuning **workflow**: how to systematically
find your slowest queries in the first place, a structured checklist for
diagnosing them, configuration-level levers (`work_mem`,
`random_page_cost`, `effective_cache_size`, and more) beyond query- and
index-level fixes, and how to verify a fix actually held up under
production load rather than just in a single `EXPLAIN ANALYZE` run.
