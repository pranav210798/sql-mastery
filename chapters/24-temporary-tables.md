# Chapter 24 — Temporary Tables

> **Part VI — Database Internals & Production Engineering**
> Previous: [Chapter 23 — Dynamic SQL & Injection Safety](23-dynamic-sql.md) · Next: [Chapter 25 — Advanced Data Types](25-advanced-data-types.md)

This chapter runs against `company_db` and `ecommerce_db`. If you haven't loaded them yet:

```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
```

This is a shorter chapter than the ones around it, but the concept it teaches
is one you will use constantly the moment you start writing real stored
procedures (Chapter 19) or ETL-style batch jobs: a table that exists only for
as long as *you* need it, is invisible to everyone else, and cleans up after
itself.

---

## 24.0 Why This Chapter Exists

Chapter 9 ended with a promise: "if you need a large intermediate result
reused across multiple statements, use a temp table — Chapter 24." This is
that chapter.

A CTE (Chapter 9) is scoped to a single statement. A view (Chapter 15) is
permanent, schema-visible, shared by every session. Neither is the right tool
when you need to compute something expensive **once**, then run two or three
*different* follow-up queries against that exact result, inside a single
stored procedure or batch job, without leaving a permanent object behind for
the next person to trip over. Temporary tables fill exactly that gap.

---

## 24.1 What Is a Temporary Table?

### Simple Explanation

A temporary table is a table that exists only for your session (or, in some
modes, only for your current transaction) and disappears automatically when
that session or transaction ends. Nobody else can see it, and you don't have
to remember to clean it up.

### Technical Explanation

A temporary table is a table object created in a special, session-private
namespace. It has real columns, real rows, and (as you'll see in §24.7) can
have real indexes — but its catalog entry and its data both live in a
namespace scoped to the creating session (or, with certain `ON COMMIT`
options, scoped even more tightly to the current transaction). It is
automatically and unconditionally dropped when that scope ends, with no
`DROP TABLE` required from you.

### Why It Exists

1. **Staging for multi-step procedural work.** A stored procedure often needs
   several statements to build up a result — filter, aggregate, join,
   re-aggregate — before producing a final answer. Doing all of that in one
   giant nested query is often unreadable or impossible; a temp table lets
   the procedure "show its work" one step at a time, exactly like a
   spreadsheet with intermediate columns.
2. **Avoiding permanent schema clutter.** If every batch job or report needed
   a genuinely permanent table to stage its intermediate numbers, your schema
   would accumulate hundreds of `tmp_report_2024_01_15` tables that nobody
   remembers to drop. Temp tables make that cleanup automatic and mandatory.
3. **Free isolation between concurrent sessions.** Two users can each run a
   procedure that creates a temp table named `staging_orders` **at the same
   time**, with zero risk of collision or of seeing each other's data — each
   session's `staging_orders` is a completely separate physical object,
   invisible to the other session, even though the name is identical.

---

## 24.2 `CREATE TEMP` / `CREATE TEMPORARY TABLE` — PostgreSQL & MySQL

### Full Syntax — PostgreSQL

```sql
CREATE [ GLOBAL | LOCAL ] { TEMPORARY | TEMP } TABLE table_name (
    column_name data_type [ column_constraint ... ],
    ...
)
[ ON COMMIT { PRESERVE ROWS | DELETE ROWS | DROP } ];

-- Or, populate it directly from a query (CREATE TABLE ... AS SELECT, "CTAS"):
CREATE { TEMPORARY | TEMP } TABLE table_name
[ ON COMMIT { PRESERVE ROWS | DELETE ROWS | DROP } ]
AS
SELECT ...;
```

| Piece | Meaning |
|---|---|
| `TEMPORARY` / `TEMP` | Either spelling works identically — `TEMP` is just shorthand |
| `GLOBAL` / `LOCAL` | Accepted for standards compliance but **ignored** — PostgreSQL has only one kind of temp table (session-scoped by default); do not confuse this with SQL Server's or Oracle's very different "global" temp tables below |
| `ON COMMIT ...` | Controls what happens to the table at each `COMMIT` — covered fully in §24.6; if omitted, the table behaves as `PRESERVE ROWS` and simply lives until the session ends |
| `AS SELECT ...` | The CTAS form — creates the table's columns from the query's output and populates it in one statement, which is exactly what you want for a staging table computed from an aggregation |

**[PostgreSQL]** only — everything above.

### Example — Staging "Loyalty-Eligible Orders" for February 2024

**Goal (motivating scenario used throughout this chapter):** identify orders
that qualify for a loyalty bonus this month — delivered or paid orders placed
in February 2024 with a total above ₹40,000 — compute the bonus **once**,
then produce two unrelated reports from that same staged result.

```sql
CREATE TEMP TABLE loyalty_eligible_orders AS
SELECT
    o.order_id,
    o.user_id,
    SUM(oi.quantity * oi.unit_price)                    AS order_total,
    ROUND(SUM(oi.quantity * oi.unit_price) * 0.02, 2)   AS loyalty_bonus
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('DELIVERED', 'PAID')
  AND o.order_date >= '2024-02-01'
  AND o.order_date <  '2024-03-01'
GROUP BY o.order_id, o.user_id
HAVING SUM(oi.quantity * oi.unit_price) > 40000;
```

**Expected output** (querying it right after creation: `SELECT * FROM loyalty_eligible_orders ORDER BY order_id;`):

| order_id | user_id | order_total | loyalty_bonus |
|---|---|---|---|
| 6 | 5 | 75798.00 | 1515.96 |
| 8 | 1 | 45999.00 | 919.98 |
| 9 | 7 | 93498.00 | 1869.96 |

**Line-by-line explanation**

1. `CREATE TEMP TABLE loyalty_eligible_orders AS SELECT ...` — this is CTAS: no
   column list is written by hand, the table inherits `order_id`, `user_id`,
   `order_total`, `loyalty_bonus` directly from the query's output columns.
2. The join and `WHERE` narrow to February 2024 orders whose status shows real
   money changed hands or will (`DELIVERED`, `PAID`) — order 7 (`PENDING`) and
   order 10 (`DELIVERED` but only ₹3,897) are excluded by status and by the
   `HAVING` threshold respectively.
3. `HAVING SUM(...) > 40000` filters *after* aggregation, on the computed
   order total — exactly the same rule as an ordinary `GROUP BY` query
   (Chapter 6); nothing about `HAVING` changes when its result feeds a temp
   table instead of a plain `SELECT`.
4. The moment this statement commits (or, outside an explicit transaction,
   the moment it finishes — see §24.6), `loyalty_eligible_orders` exists as a
   real table you can `SELECT`, `JOIN`, `UPDATE`, or index, just like any
   permanent table, for the rest of this session.

You could instead declare the columns explicitly and `INSERT INTO ... SELECT`
in a separate statement — the two-statement form is what you'll typically see
inside an actual stored procedure, where the table needs to exist as a named
target *before* the row-producing logic runs:

```sql
CREATE TEMP TABLE loyalty_eligible_orders (
    order_id       INT PRIMARY KEY,
    user_id        INT NOT NULL,
    order_total    NUMERIC(12,2) NOT NULL,
    loyalty_bonus  NUMERIC(10,2) NOT NULL
);

INSERT INTO loyalty_eligible_orders
SELECT
    o.order_id,
    o.user_id,
    SUM(oi.quantity * oi.unit_price),
    ROUND(SUM(oi.quantity * oi.unit_price) * 0.02, 2)
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('DELIVERED', 'PAID')
  AND o.order_date >= '2024-02-01'
  AND o.order_date <  '2024-03-01'
GROUP BY o.order_id, o.user_id
HAVING SUM(oi.quantity * oi.unit_price) > 40000;
```

Now watch the isolation guarantee in action: open a **second** `psql`
connection and run `SELECT * FROM loyalty_eligible_orders;` there.

```
ERROR:  relation "loyalty_eligible_orders" does not exist
```

The table is not hidden by a permission check — it genuinely does not exist
from the other session's point of view. That other session could run the
exact same `CREATE TEMP TABLE loyalty_eligible_orders AS ...` statement
itself and get its own, completely separate copy with the identical name and
zero conflict.

### Full Syntax — MySQL

```sql
CREATE TEMPORARY TABLE table_name (
    column_name data_type [ column_constraint ... ],
    ...
) [ ENGINE = InnoDB | MEMORY | ... ];
```

**[MySQL]** notes:

- `TEMP` is **not** accepted as an abbreviation in MySQL — you must spell out
  `TEMPORARY`.
- MySQL temp tables are **always connection-scoped**; there is no `GLOBAL`
  option, and no `ON COMMIT` clause at all — a MySQL temp table simply lives
  until the connection closes or you `DROP TEMPORARY TABLE` it explicitly,
  regardless of how many transactions run in between.
- A temp table with the same name as a permanent table shadows the permanent
  one for the rest of the session — identical shadowing behavior to
  PostgreSQL (see §24.12).
- `SHOW TABLES` does **not** list temporary tables, and neither does
  `information_schema.tables` in most MySQL versions — reinforcing that they
  are genuinely invisible, not merely filtered from a UI.
- Historically (pre-8.0 in some contexts), MySQL disallowed referencing the
  same temporary table twice in one statement (e.g., a self-join); this was
  relaxed in modern versions, but it is a MySQL-specific quirk worth knowing
  if you hit `ERROR 1137 (HY000): Can't reopen table`.

```sql
CREATE TEMPORARY TABLE loyalty_eligible_orders (
    order_id      INT PRIMARY KEY,
    user_id       INT NOT NULL,
    order_total   DECIMAL(12,2) NOT NULL,
    loyalty_bonus DECIMAL(10,2) NOT NULL
);
```

> **Important Note:** In both PostgreSQL and MySQL, dropping a temp table
> early and on purpose is always allowed and often good practice inside a
> procedure that might be called repeatedly in the same session:
> `DROP TABLE IF EXISTS loyalty_eligible_orders;` — see the naming-collision
> mistake in §24.11 for why this matters.

---

## 24.3 SQL Server: `#table_name` and `##table_name`

### Simple Explanation

SQL Server doesn't use a `TEMP` keyword at all. Instead, **the name itself**
tells the engine what kind of table you're creating: one leading `#` means
"private to my session," two leading `#`s (`##`) mean "shared by every
session, until they've all disconnected."

### Technical Explanation

This is a genuinely different mechanism from PostgreSQL's explicit `TEMP`
keyword — SQL Server inspects the identifier's prefix at `CREATE TABLE` time
and routes the object into `tempdb` (a dedicated system database used for all
temporary storage) rather than the current database, choosing session-local
or instance-global visibility purely from how many `#` characters lead the
name.

| Prefix | Scope | Dropped when |
|---|---|---|
| `#table_name` (local temp table) | Visible only to the session that created it (and, if created inside a stored procedure, only within that procedure call — it disappears the moment the procedure returns unless a caller explicitly needs it passed along) | The creating session disconnects, or the creating procedure returns |
| `##table_name` (global temp table) | Visible to **every** session connected to the instance | The **last** session that referenced it disconnects (not necessarily the session that created it) |

### Full Syntax — SQL Server

```sql
CREATE TABLE #loyalty_eligible_orders (
    order_id      INT PRIMARY KEY,
    user_id       INT NOT NULL,
    order_total   DECIMAL(12,2) NOT NULL,
    loyalty_bonus DECIMAL(10,2) NOT NULL
);

INSERT INTO #loyalty_eligible_orders
SELECT o.order_id, o.user_id, SUM(oi.quantity * oi.unit_price),
       ROUND(SUM(oi.quantity * oi.unit_price) * 0.02, 2)
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('DELIVERED','PAID')
  AND o.order_date >= '2024-02-01' AND o.order_date < '2024-03-01'
GROUP BY o.order_id, o.user_id
HAVING SUM(oi.quantity * oi.unit_price) > 40000;

SELECT * FROM #loyalty_eligible_orders;
```

```sql
-- A GLOBAL temp table — any other connected session can see it too
CREATE TABLE ##shared_batch_staging (batch_id INT, status VARCHAR(20));
```

**[SQL Server]** only — everything above.

### Internal Behavior

All SQL Server temp tables — local and global — are physically created in
`tempdb`, not in the user database. Because two different sessions are both
allowed to create a local temp table named `#Orders` without conflicting,
SQL Server internally appends a unique numeric/hex suffix to the object name
it actually stores in `tempdb.sys.objects` (something like
`#Orders__________________________0000000000A1`) — you never see or type
this suffix, but it's the mechanism that lets identical `#` names coexist
across sessions, conceptually parallel to how PostgreSQL gives each session
its own `pg_temp_NNN` schema (§24.10).

> **⚠️ Warning:** A global temp table (`##name`) is a shared mutable object
> across every connected session on the instance — the same naming
> convenience that makes local temp tables safe (`#name` never collides
> across sessions) makes global temp tables the *opposite*: two unrelated
> processes using the same `##name` **will** collide and corrupt each
> other's data. Reach for `##` only when you deliberately want cross-session
> sharing (rare), never as a shortcut.

---

## 24.4 Oracle: Global Temporary Tables

### Simple Explanation

In Oracle, you create the temp table's *structure* once, like any permanent
table — everyone can see that a table named `gtt_loyalty_orders` exists. But
when different users insert rows into it, each user only ever sees their
**own** rows. The shape is shared; the data is private.

### Technical Explanation

This is the single biggest conceptual difference from PostgreSQL in this
whole chapter. In PostgreSQL, the *entire table object* — definition and
data both — is transient and session-private. In Oracle, `CREATE GLOBAL
TEMPORARY TABLE` creates a **permanent** entry in the data dictionary
(`USER_TABLES`/`ALL_TABLES`) that persists indefinitely, exactly like any
other table you `CREATE`, and remains until someone explicitly runs
`DROP TABLE`. Only the *rows* are session-private: Oracle allocates a
separate, private data segment (in the temporary tablespace) for each
session that inserts into the table, so `SELECT * FROM gtt_loyalty_orders`
run by session A and by session B against the very same table object return
completely different rows.

### Full Syntax

```sql
CREATE GLOBAL TEMPORARY TABLE gtt_loyalty_orders (
    order_id       NUMBER PRIMARY KEY,
    user_id        NUMBER NOT NULL,
    order_total    NUMBER(12,2) NOT NULL,
    loyalty_bonus  NUMBER(10,2) NOT NULL
)
ON COMMIT DELETE ROWS;   -- Oracle's default if omitted
-- or: ON COMMIT PRESERVE ROWS
```

| `ON COMMIT` option | Behavior |
|---|---|
| `DELETE ROWS` (Oracle's default) | Rows are automatically truncated for that session at every `COMMIT` — the table is **transaction-scoped** data-wise |
| `PRESERVE ROWS` | Rows survive commits and persist for the rest of the session — the table is **session-scoped** data-wise |

In both cases, the table **definition itself never disappears** — it sits in
the data dictionary permanently, visible to every user with the right
privileges, forever, until a DBA runs `DROP TABLE gtt_loyalty_orders`.

**[Oracle]** only — everything in this section.

> **Important Note:** This is why Oracle documentation and interview
> questions consistently phrase it as "the definition is permanent, the data
> is private" — don't let the word "Global" mislead you into thinking data is
> shared. *Only the structure is global.* This is a completely different
> tradeoff from PostgreSQL, where dropping the session also drops the
> structure.

---

## 24.5 Oracle 18c+: Private Temporary Tables

### Simple Explanation

Oracle added a second kind of temp table, starting in version 18c, that
behaves much more like PostgreSQL's: both the table's *shape* and its *data*
are private to your session, and nobody else — not even someone browsing the
data dictionary — can see that the table ever existed.

### Technical Explanation

`CREATE PRIVATE TEMPORARY TABLE` creates an object that never appears in
`USER_TABLES`/`ALL_TABLES` for any session but the one that created it —
unlike a Global Temporary Table, there is no shared, permanent dictionary
entry at all. The table name **must** begin with a reserved prefix
(`ORA$PTT_` by default, configurable via the `private_temp_table_prefix`
initialization parameter), which is how Oracle's parser recognizes and routes
these objects.

### Full Syntax

```sql
CREATE PRIVATE TEMPORARY TABLE ora$ptt_loyalty_orders (
    order_id       NUMBER,
    user_id        NUMBER,
    order_total    NUMBER(12,2),
    loyalty_bonus  NUMBER(10,2)
)
ON COMMIT DROP DEFINITION;      -- Oracle's default: the whole table vanishes at commit
-- or: ON COMMIT PRESERVE DEFINITION   -- table (and its data) survives commits, for the rest of the session
```

**[Oracle 18c+]** only.

| Feature | Global Temporary Table | Private Temporary Table (18c+) |
|---|---|---|
| Table *definition* visibility | Permanent, shared, in the data dictionary | Session-private, never in the data dictionary for other sessions |
| Naming | No special prefix required | Must start with `ORA$PTT_` (or the configured prefix) |
| Closest PostgreSQL equivalent | *No direct equivalent* — Postgres has nothing that keeps a shared permanent shape with private data | This one — an entire object, shape and data, invisible outside your session |
| Storage | Temporary tablespace segment per session | Typically memory-only for small tables, spilling to temp tablespace if needed |

---

## 24.6 Lifetime & Scope: `ON COMMIT` Behavior **[PostgreSQL]**

This is the one place PostgreSQL gives you fine-grained, explicit control
over lifetime, and it's worth internalizing precisely because getting it
wrong produces a very specific, confusing symptom: "my temp table is
mysteriously empty" or "mysteriously gone."

| Clause | What happens at each `COMMIT` | What happens at each `ROLLBACK` | Typical use |
|---|---|---|---|
| `ON COMMIT PRESERVE ROWS` (or no clause at all — this is the **default**) | Nothing — rows and the table both remain | Rows inserted since the last commit are rolled back, like any table; the table itself stays | A staging table you'll query across **multiple transactions** in the same session — e.g., stage once, then run several independent reporting transactions against it over the next few minutes |
| `ON COMMIT DELETE ROWS` | The table is automatically `TRUNCATE`d — structure survives, all rows are gone | Same as above (uncommitted rows vanish) | A scratch table reused **every transaction** in a loop — e.g., a batch job that, once per transaction, refills the same scratch table and processes it, then expects it empty again next time |
| `ON COMMIT DROP` | The entire table — structure and data — is dropped | The table was created inside the (now-aborted) transaction, so it never existed to begin with | A table that should be used and **fully discarded within a single transaction**, with zero manual cleanup |

### Example — `ON COMMIT PRESERVE ROWS` (default): survives across transactions

```sql
BEGIN;
CREATE TEMP TABLE staging_totals (order_id INT, order_total NUMERIC)
    ON COMMIT PRESERVE ROWS;
INSERT INTO staging_totals
SELECT order_id, SUM(quantity * unit_price)
FROM order_items GROUP BY order_id;
COMMIT;

-- Later — a brand new transaction, same session:
BEGIN;
SELECT COUNT(*) FROM staging_totals;   -- still there: 10 rows
COMMIT;
```

### Example — `ON COMMIT DELETE ROWS`: emptied at every commit

```sql
BEGIN;
CREATE TEMP TABLE batch_scratch (n INT) ON COMMIT DELETE ROWS;
INSERT INTO batch_scratch VALUES (1), (2), (3);
COMMIT;

SELECT * FROM batch_scratch;   -- table still exists, but returns 0 rows
```

### Example — `ON COMMIT DROP`: gone entirely at commit

```sql
BEGIN;
CREATE TEMP TABLE session_calc (val INT) ON COMMIT DROP;
INSERT INTO session_calc VALUES (1), (2), (3);
SELECT SUM(val) FROM session_calc;   -- 6, computed inside the same transaction
COMMIT;

SELECT * FROM session_calc;
```
```
ERROR:  relation "session_calc" does not exist
```

**Line-by-line explanation:** all three examples create the table inside an
explicit `BEGIN ... COMMIT` block on purpose — the `ON COMMIT` clause only has
something to "fire" when a real, explicit commit happens. In default
autocommit mode (no `BEGIN`), every statement is its own tiny transaction, so
a table created `ON COMMIT DROP` outside an explicit transaction block is
created and then immediately dropped by the very next implicit commit — often
before you get to run a second statement against it. This is exactly the
mistake covered in §24.11.

> **⚠️ Warning:** People frequently write `ON COMMIT DROP`, run it as a single
> statement with autocommit on, and then are baffled that the very next
> `SELECT * FROM their_table` says the relation doesn't exist. Nothing is
> broken — the table did exactly what you told it to do: drop itself the
> moment its creating statement committed.

---

## 24.7 Indexes on Temporary Tables

### Simple and Technical Explanation

You can index a temp table exactly the way you'd index a permanent one.
There is nothing special about the `CREATE INDEX` syntax — the index is a
completely real, functioning index: the query planner considers it, it has
real build cost, and `ANALYZE` gathers real statistics on it. The only
difference from a permanent index is that it disappears automatically the
moment the temp table itself is dropped — you never `DROP INDEX` it
separately.

### Example

```sql
CREATE INDEX idx_loyalty_user
    ON loyalty_eligible_orders (user_id);

ANALYZE loyalty_eligible_orders;

EXPLAIN
SELECT * FROM loyalty_eligible_orders WHERE user_id = 7;
```

For a 3-row staging table like this one, the planner will happily choose a
sequential scan anyway — the table is too small for the index to pay off, and
that's a correct, cost-based decision, not a bug. The index becomes worth its
build cost once the staged intermediate result is large (thousands to
millions of rows) and is queried or joined multiple times, which is exactly
the scenario the chapter challenge (§24.16) is built around: index a real
multi-hundred-row (or larger, in production) intermediate result once, then
reuse the index across two different reports.

> **Important Note:** Building an index costs real CPU and I/O even though
> the table (and the index) are temporary — "temporary" describes the
> object's *lifetime*, not its *cost to build or use*. Don't index a temp
> table reflexively; index it exactly when you would index a permanent table
> the same size and access pattern: multiple point lookups or joins on a
> column, over a large enough row count that a sequential scan would be
> noticeably slower.

---

## 24.8 Deep Dive: Temporary Tables vs. CTEs

This is the comparison you need to get right, because both tools solve
"name an intermediate result," and choosing wrong either adds needless
ceremony or silently recomputes an expensive result multiple times.

| | CTE | Temp table |
|---|---|---|
| Lifetime | One statement only | Session (default) or transaction (`ON COMMIT` options) |
| Reusable across separate statements? | **No** — re-run the whole `WITH` block and it recomputes from scratch | **Yes** — create once, query as many times, in as many separate statements, as you want |
| Can be indexed? | **No** — a CTE is never a standalone storage object you can attach an index to | **Yes** — full `CREATE INDEX` support (§24.7) |
| Can gather planner statistics (`ANALYZE`)? | **No** — there's no persistent object between statements for `ANALYZE` to describe | **Yes** — `ANALYZE` on a populated temp table gives the planner real row-count and distribution estimates for every subsequent query against it |
| Typical size it's good for | Small to moderate — the planner may inline it (Chapter 9 §9.10) or materialize it once, but always within one statement's execution | Large — the whole point is amortizing an expensive computation across multiple later reads |
| Ceremony | Zero — just a `WITH` clause on the query you're already writing | Real — a `CREATE`, possibly an `INSERT`, and (implicitly) cleanup semantics you must understand |

### Concrete Scenario Where a Temp Table Clearly Wins

A stored procedure needs to compute a company-wide department salary
aggregation (a `GROUP BY` over a join across `employees`, `salaries`, and
`departments` — not cheap at scale) and then produce **three** different
reports from it: a ranking by average salary, a pay-equity spread report, and
an export feed. Using a CTE here would mean either (a) writing the *identical*
`WITH` block three separate times — one per report statement, paying the full
aggregation cost three times — or (b) trying to cram three independent report
shapes into one giant statement with multiple `SELECT`s glued together in
ways that stop being readable. A temp table computed once, indexed once, and
queried three times is both cheaper and clearer. This exact scenario is the
chapter challenge in §24.16.

### Concrete Scenario Where a CTE Clearly Wins

You're writing a single ad-hoc report — "list this month's orders alongside
each customer's running lifetime total" — and you'll run it once, read the
output, and move on. Wrapping that in `CREATE TEMP TABLE ... ; SELECT ... ;
DROP TABLE ...` is three statements and a name to think up for a result you
never look at twice. A `WITH monthly_orders AS (...)  SELECT ...` is one
statement, self-contained, and exactly as fast — this is a pure readability
aid, not a performance concern, so reach for the lighter-weight tool.

> **Rule of thumb:** if you will run more than one statement against the
> intermediate result, or the result is large enough that indexing or
> `ANALYZE` would materially help, use a temp table. If it's read once, right
> after it's computed, in the very next `SELECT`, use a CTE.

---

## 24.9 SQL Server Table Variables vs. Temp Tables vs. CTEs **[SQL Server]**

SQL Server has a *third* construct that looks similar to both: the **table
variable**.

### Simple Explanation

A table variable looks like a regular variable that happens to hold rows
instead of a single value. You declare it, fill it, use it, and it
disappears when the batch or procedure it lives in finishes.

### Technical Explanation

```sql
DECLARE @loyalty_orders TABLE (
    order_id      INT PRIMARY KEY,
    user_id       INT NOT NULL,
    order_total   DECIMAL(12,2) NOT NULL,
    loyalty_bonus DECIMAL(10,2) NOT NULL
);

INSERT INTO @loyalty_orders
SELECT o.order_id, o.user_id, SUM(oi.quantity * oi.unit_price),
       ROUND(SUM(oi.quantity * oi.unit_price) * 0.02, 2)
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status IN ('DELIVERED','PAID')
GROUP BY o.order_id, o.user_id
HAVING SUM(oi.quantity * oi.unit_price) > 40000;

SELECT * FROM @loyalty_orders;
```

`@loyalty_orders` behaves partly like a temp table (you can join it, filter
it, index it with limited `PRIMARY KEY`/`UNIQUE` constraints declared inline)
and partly like a local variable — its scope is strictly the current batch,
stored procedure, or function, and it is never visible to a nested procedure
call the way a `#temp` table created by a caller can be.

### The Rollback Gotcha

This is the surprising, genuinely important difference, and it's the reason
table variables are their own category rather than "just a lightweight temp
table":

```sql
BEGIN TRANSACTION;

DECLARE @t TABLE (id INT);
INSERT INTO @t VALUES (1), (2), (3);

ROLLBACK TRANSACTION;

SELECT * FROM @t;   -- still returns 1, 2, 3 !
```

```sql
BEGIN TRANSACTION;

CREATE TABLE #t (id INT);
INSERT INTO #t VALUES (1), (2), (3);

ROLLBACK TRANSACTION;

SELECT * FROM #t;   -- Msg 208: Invalid object name '#t'
```

A real temp table (`#t`) participates fully in transaction semantics: both
its DDL (creation) and its DML (inserted rows) are rolled back along with
everything else in the aborted transaction — exactly as you'd expect. A
table variable's *contents* have **limited transactional context**: inserts
into `@t` are **not undone** by a `ROLLBACK`. This is a real, documented, and
frequently misunderstood SQL Server behavior — code that assumes "wrapping
everything in a transaction makes it all-or-nothing" will silently leak rows
into a table variable even when the surrounding transaction fails.

### No Statistics — the Other Gotcha

SQL Server's query optimizer does not maintain column statistics for table
variables the way it does for temp tables and permanent tables. Historically
(and still, in many supported versions) the optimizer simply assumes a table
variable holds a small, fixed number of rows regardless of how many rows are
actually in it. For a handful of rows this is harmless. For a table variable
loaded with tens of thousands of rows and then joined to something large,
this misestimate routinely produces a badly chosen join plan (e.g., a nested
loop join where a hash join would be far cheaper) — a classic, hard-to-spot
performance trap that a real `#temp` table (which *does* get statistics) does
not share.

| | Table variable (`@t`) | Local temp table (`#t`) | CTE |
|---|---|---|---|
| Scope | Current batch/procedure/function only | Session (or creating procedure) | Current statement only |
| Survives `ROLLBACK`? | **Yes** (DML is not undone) | No — full transactional semantics | N/A — never persists past the statement |
| Optimizer statistics gathered? | **No** — assumed small/fixed row count | Yes | N/A |
| Indexable? | Only via inline `PRIMARY KEY`/`UNIQUE` at declaration | Yes, fully (`CREATE INDEX` after the fact too) | No |
| Dialect | **[SQL Server only]** | PostgreSQL/MySQL/Oracle/SQL Server all have an equivalent | Standard SQL, all major dialects |

> **Important Note:** PostgreSQL, MySQL, and Oracle have **no direct
> equivalent** to the table variable. Their closest analogs are: a plain
> variable holding a single row/record inside PL/pgSQL or PL/SQL (Chapters
> 19–20), or simply a temp table when you need multiple rows. If you're
> porting T-SQL that uses `DECLARE @t TABLE`, the honest translation on
> PostgreSQL is a temp table — just be aware you're *gaining* real
> transactional rollback behavior and real statistics that the original code
> may never have been tested against.

---

## 24.10 Internal Behavior: Where Temp Tables Actually Live **[PostgreSQL]**

Temp tables are not a special in-memory trick — they are physically stored
exactly like regular tables (heap pages, TOAST for large values, the same
storage format), just inside a namespace that is private to one session.

- The first time a session creates a temporary object, PostgreSQL creates a
  schema named `pg_temp_NNN` (where `NNN` is an internal backend ID) for that
  session. Every subsequent temp table you create in that session lands in
  that same schema. `\dt pg_temp_*.*` from within the session shows it;
  another session cannot see into it at all, and cannot even reference it if
  it somehow knew the schema name — PostgreSQL explicitly blocks
  cross-session access to another backend's temp schema.
- When the session ends (normally or by crashing), the entire `pg_temp_NNN`
  schema and everything in it is dropped automatically.
- **Temporary table operations are not WAL-logged.** PostgreSQL's
  write-ahead log exists to make crash recovery possible — replaying WAL
  after a crash reconstructs every permanent table to a consistent state.
  Temp tables are meaningless after a crash anyway (the session that owned
  them is gone), so PostgreSQL skips WAL-logging all writes to them entirely.
  This is a genuine, measurable performance advantage: heavy INSERT/UPDATE
  activity into a temp table used for staging is meaningfully cheaper than
  the identical activity against a permanent table, purely because there's no
  WAL to write and flush.
- Temp table data is read and written through a separate, session-local
  buffer area sized by the `temp_buffers` setting, not through the shared
  buffer pool used by permanent tables — another reason temp table access
  doesn't contend with, or evict pages from, your normal working set.

---

## 24.11 Common Mistakes

1. **Assuming a temp table is visible to other sessions.** It never is, by
   design (§24.2's second-connection example). If you need cross-session
   sharing, you want a real permanent staging table, or (SQL Server only) a
   deliberate `##global` temp table.
2. **Forgetting `ON COMMIT` behavior and being surprised the table is empty
   or gone.** Creating a table `ON COMMIT DROP` or `ON COMMIT DELETE ROWS`
   outside an explicit transaction, under autocommit, means the very next
   statement already sees the post-commit effect — an empty or nonexistent
   table — because each autocommitted statement is its own transaction
   (§24.6).
3. **Naming collisions when nesting procedure calls.** If procedure `A` calls
   procedure `B`, and both try to `CREATE TEMP TABLE staging (...)` with the
   identical name in the same session, the second `CREATE` fails with
   `relation "staging" already exists` — unless the first one used
   `ON COMMIT DROP` and a commit already happened in between, or you
   defensively `DROP TABLE IF EXISTS staging;` at the top of each procedure
   before creating it. This is the single most common "works alone, fails
   when called from another procedure" bug with temp tables.
4. **Forgetting that CTAS infers column types and constraints loosely.**
   `CREATE TEMP TABLE x AS SELECT ...` gives you the *data types* the query
   produced, but **no** primary key, no `NOT NULL`, no indexes — those all
   need to be added explicitly afterward if the staging table's later use
   depends on them.
5. **Treating a temp table's default behavior as transaction-scoped.** With
   no `ON COMMIT` clause, a Postgres temp table survives commits by default
   (`PRESERVE ROWS` is the implicit default) — the opposite of what someone
   coming from Oracle's Global Temporary Tables (whose default is
   `ON COMMIT DELETE ROWS`) might expect.
6. **Not indexing a large staged intermediate result before running multiple
   reports against it**, then wondering why "using a temp table" didn't speed
   anything up — the temp table alone only saves you from recomputing the
   aggregation; the *reads* against it are only fast if you also index and
   `ANALYZE` it appropriately (§24.7).

---

## 24.12 Edge Cases

- **Name shadowing a permanent table.** If your session creates a temp table
  named `orders` — the same name as `ecommerce_db.orders` — then, for the
  rest of the session, an unqualified `SELECT * FROM orders` resolves to
  **the temp table**, not the permanent one. PostgreSQL always checks the
  session's temporary schema (`pg_temp_NNN`) **before** consulting the
  schemas listed in `search_path`, regardless of where (or whether) you've
  listed `pg_temp` in `search_path` explicitly. To reach the real table
  during that session, you must schema-qualify it: `SELECT * FROM
  ecommerce_db.orders;`. This is a legitimate technique (some testing setups
  deliberately shadow a table to redirect code without touching it) and also
  a legitimate trap (accidentally naming a staging table the same as a real
  one, then being confused why your changes to "orders" aren't visible
  elsewhere).
- **A crashed session's temp tables.** If a session terminates abnormally,
  PostgreSQL cleans up its `pg_temp_NNN` schema on the next connection/vacuum
  cycle rather than instantly — you may transiently see orphaned
  `pg_temp_NNN` schemas in catalog views immediately after a crash, but they
  are inert and get reclaimed automatically; you cannot query into them.
- **`TRUNCATE` vs `ON COMMIT DELETE ROWS`.** Both empty a table's data while
  keeping its structure, but `TRUNCATE` is something *you* run on demand at
  any point; `ON COMMIT DELETE ROWS` is something PostgreSQL runs
  *automatically*, exactly once, at each commit — don't confuse "I want to
  clear this table now" (write `TRUNCATE`) with "I want this table to always
  start each transaction empty" (declare `ON COMMIT DELETE ROWS`).
- **Oracle Global Temporary Table definitions outliving every session that
  ever used them.** Because the *definition* is permanent (§24.4), a `DROP
  TABLE` on a GTT is a real schema-migration event that a DBA must run
  deliberately — unlike PostgreSQL, where the "cleanup" is unconditional and
  automatic.

---

## 24.13 Temp Tables vs. CTEs vs. Permanent Staging Tables vs. Application-Side Processing

| Approach | Reach for it when |
|---|---|
| **CTE** | The intermediate result is read once, in the very next part of the same statement, and readability (not reuse or indexing) is the goal |
| **Temp table** | The intermediate result is large, is read by more than one statement in the same session/transaction, or benefits from its own index/statistics — the default choice inside stored procedures and multi-step batch jobs |
| **Permanent staging table** | The intermediate result needs to be inspected, audited, or reused **across sessions or across days** — e.g., an ETL pipeline's landing table that a separate validation job checks tomorrow morning, or a table other teams' reports are allowed to query directly |
| **Application-side processing** | The logic genuinely isn't relational (complex per-row business rules, calling external services per row, formatting for a UI) — pulling raw rows out and looping in application code is more appropriate than forcing procedural logic into SQL just because a temp table is available |

---

## 24.14 Real-World Use Cases

- **ETL staging.** A nightly load job copies raw rows from a source system
  into a temp table, applies cleansing/deduplication/type-conversion logic
  across a few statements, and only then `INSERT`s the cleaned rows into the
  real permanent target table — keeping the messy intermediate steps out of
  the production schema entirely.
- **Complex multi-step report generation inside a stored procedure.** Exactly
  the pattern built in §24.16: compute one expensive aggregation, stage it,
  index it, and generate several distinct final reports from the same staged
  numbers without recomputing.
- **Batch processing with checkpointing.** A long-running batch job processes
  rows in chunks, using a temp table to track "which rows in this run have
  been handled so far" so a failure partway through doesn't require
  re-deriving the whole work list from scratch within that session.
- **Ad-hoc investigation during an incident.** An engineer debugging a
  production issue stages a suspicious subset of rows into a temp table,
  then runs several different diagnostic queries against that frozen snapshot
  without repeatedly re-running (and re-paying for) the original expensive
  filter.

---

## 24.15 Practice Questions

No answers are provided — work through these against `company_db` and
`ecommerce_db` as seeded.

1. Create a temp table `active_user_orders` staging every order placed by
   currently active (`is_active = TRUE`) users, then write two different
   `SELECT`s against it: one summarizing order counts per user, one
   summarizing total revenue per month.
2. Explain, in your own words, the difference between what happens to a
   Postgres temp table's *data* under `ON COMMIT DELETE ROWS` versus what
   happens to an Oracle Global Temporary Table's *data* under its default
   `ON COMMIT DELETE ROWS` — and what stays fundamentally different between
   the two regardless of that shared default.
3. Write a script that deliberately creates a temp table named `employees`
   (shadowing `company_db.employees`) with only two columns, queries the
   unqualified name to see the shadow in effect, then queries the
   schema-qualified name to reach the real table.
4. Using `company_db`, create a temp table of each department's project
   budget total, add an index on `department_id`, run `ANALYZE`, and use
   `EXPLAIN` to confirm the index is available to the planner (even if not
   chosen, for this row count).
5. Rewrite Practice Question 1 as a single CTE-based query instead of a temp
   table. Which version would you actually ship in a real report, and why?
6. **[SQL Server]** Write a T-SQL script that proves the table-variable
   rollback gotcha for yourself: insert rows into a table variable inside a
   transaction, roll the transaction back, and show the rows are still
   there. Then repeat with a `#temp` table and show the opposite.
7. **[Oracle]** Write the `CREATE GLOBAL TEMPORARY TABLE` statement for a
   staging table equivalent to `loyalty_eligible_orders`, using
   `ON COMMIT PRESERVE ROWS`, and explain in a comment why two different
   Oracle sessions querying it afterward would see different rows despite
   querying the same table object.
8. Write a short procedure-style script (an explicit `BEGIN ... COMMIT`
   block) that creates a temp table `ON COMMIT DROP`, uses it for two
   separate `SELECT`s inside that same block, and confirms afterward (in a
   later statement) that the table no longer exists.
9. Describe a real scenario at a company you're familiar with (or invent one)
   where using a permanent staging table would be more appropriate than a
   temp table, and explain what would go wrong if temp tables were used
   instead.

---

## 24.16 Chapter Challenge

**Write a stored-procedure-style script** that stages an intermediate
"department salary summary" into an indexed temp table, then produces **two
different final reports** from it — a salary ranking and a pay-equity spread
check — **without recomputing the underlying aggregation twice**.

### Solution

```sql
BEGIN;

-- Step 1: compute the expensive aggregation exactly ONCE
CREATE TEMP TABLE dept_salary_summary
ON COMMIT DROP
AS
WITH latest_salary AS (
    SELECT DISTINCT ON (employee_id)
        employee_id, base_salary
    FROM salaries
    ORDER BY employee_id, effective_date DESC
)
SELECT
    d.department_id,
    d.department_name,
    COUNT(*)                      AS employee_count,
    SUM(ls.base_salary)           AS total_salary,
    ROUND(AVG(ls.base_salary), 2) AS avg_salary,
    MAX(ls.base_salary)           AS max_salary,
    MIN(ls.base_salary)           AS min_salary
FROM employees e
JOIN latest_salary ls ON ls.employee_id = e.employee_id
JOIN departments d    ON d.department_id = e.department_id
GROUP BY d.department_id, d.department_name;

-- Step 2: index the staged result before reading it repeatedly
CREATE INDEX idx_dept_salary_summary_dept
    ON dept_salary_summary (department_id);
ANALYZE dept_salary_summary;

-- Report A: departments ranked by average current salary
SELECT department_id, department_name, employee_count, avg_salary
FROM dept_salary_summary
ORDER BY avg_salary DESC;

-- Report B: pay-equity spread check (max - min per department)
SELECT department_id, department_name, max_salary, min_salary,
       (max_salary - min_salary) AS pay_spread
FROM dept_salary_summary
ORDER BY pay_spread DESC;

COMMIT;   -- dept_salary_summary is dropped automatically right here
```

### Expected Output

**Report A — ranked by average salary:**

| department_id | department_name | employee_count | avg_salary |
|---|---|---|---|
| 1 | Engineering | 7 | 212142.86 |
| 4 | Finance | 2 | 190000.00 |
| 3 | HR | 2 | 170000.00 |
| 2 | Sales | 3 | 168333.33 |
| 5 | Marketing | 2 | 167500.00 |

**Report B — pay-equity spread, largest first:**

| department_id | department_name | max_salary | min_salary | pay_spread |
|---|---|---|---|---|
| 1 | Engineering | 520000.00 | 80000.00 | 440000.00 |
| 2 | Sales | 300000.00 | 95000.00 | 205000.00 |
| 3 | HR | 240000.00 | 100000.00 | 140000.00 |
| 5 | Marketing | 230000.00 | 105000.00 | 125000.00 |
| 4 | Finance | 250000.00 | 130000.00 | 120000.00 |

**Why this satisfies the requirement:** the `latest_salary` / `GROUP BY`
aggregation — the expensive part, joining three tables and computing five
aggregates per department — runs exactly **once**, inside the `CREATE TEMP
TABLE ... AS` statement. Both Report A and Report B are plain `SELECT`s
against the already-materialized `dept_salary_summary`, re-sorted differently
but never re-aggregated. The two reports disagree on ranking entirely (Sales
edges out Finance and Marketing on pay spread despite ranking lowest-but-one
on average salary) — exactly the kind of "same staged numbers, different
lenses" result a single CTE reused twice would force you to either duplicate
or awkwardly interleave. Because the whole script runs inside one explicit
`BEGIN ... COMMIT` block with `ON COMMIT DROP`, there is nothing left to clean
up manually: `dept_salary_summary` vanishes the instant the transaction
commits, exactly as intended for a scratch object with no life beyond this
one run.

> **Note on real stored procedures:** this script is written as flat SQL so
> you can run and verify it directly in `psql`. In an actual PL/pgSQL
> procedure (Chapter 19), you would wrap Steps 1–2 in the procedure body, and
> return the two reports to the caller either as `REFCURSOR` `OUT`
> parameters or by having the caller run separate `SELECT`s against the
> temp table right after `CALL`ing the procedure (since a plain `PROCEDURE`,
> unlike a table-valued `FUNCTION`, does not return a result set on its own)
> — the temp-table staging pattern itself is identical either way.

---

## Key Takeaways

- A temporary table is created in a session-private (or transaction-private)
  namespace and is automatically dropped when that scope ends — no manual
  cleanup, no visibility to other sessions, by design.
- **[PostgreSQL/MySQL]** use `CREATE TEMP`/`CREATE TEMPORARY TABLE`;
  **[SQL Server]** uses the `#name`/`##name` naming convention instead of a
  keyword; **[Oracle]** Global Temporary Tables have a **permanent, shared
  definition but private, per-session data** — a fundamentally different
  model from Postgres's fully transient table object; Oracle 18c+ **Private
  Temporary Tables** (`ORA$PTT_` prefix) are the closer match to PostgreSQL's
  behavior.
- **[PostgreSQL]** `ON COMMIT PRESERVE ROWS` (the default) keeps data across
  commits, `ON COMMIT DELETE ROWS` empties the table at every commit, and
  `ON COMMIT DROP` removes the whole table at commit — pick based on whether
  your staged data needs to survive one transaction or many.
- Temp tables can be indexed exactly like permanent tables, with real
  planner benefit and real build cost, and the index disappears with the
  table automatically.
- Choose a **CTE** for single-statement readability; choose a **temp table**
  when an intermediate result is large, reused across multiple statements, or
  needs an index/statistics — this is the deciding factor, not personal
  preference.
- **[SQL Server]** table variables (`DECLARE @t TABLE (...)`) are a distinct
  third option: their DML survives a `ROLLBACK` (a genuine gotcha), the
  optimizer never gathers statistics for them, and they have no equivalent in
  PostgreSQL, MySQL, or Oracle.
- Watch for the two classic mistakes: assuming a temp table is visible
  elsewhere (it never is), and forgetting your chosen `ON COMMIT` behavior
  and being surprised the table is empty or gone.

## What's Next

Chapter 25 leaves procedural staging behind and goes into PostgreSQL's richer
column types: `JSON`/`JSONB` for semi-structured data, native arrays, `UUID`
as a primary key alternative, `ENUM` types for constrained value sets, and
full-text search — the tools you reach for when a plain `VARCHAR`/`NUMERIC`
schema can't cleanly model what you're storing.

**Next:** [Chapter 25 — Advanced Data Types](25-advanced-data-types.md)
