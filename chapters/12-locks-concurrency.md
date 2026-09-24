# Chapter 12 — Locks & Concurrency

> **Prerequisite:** This chapter assumes you've read [Chapter 11 — Transactions & ACID](11-transactions.md).
> Transactions tell the database *what must happen together and safely*; locks are the
> mechanism the database uses underneath to actually make that promise true when more
> than one connection touches the same rows at the same time. Every example below runs
> against `ecommerce_db` and `banking_db` from `databases/`. Dialect: **PostgreSQL**
> primary, with **[MySQL]**, **[Oracle]**, and **[SQL Server]** call-outs wherever
> behavior diverges.

## Learning Objectives

By the end of this chapter you will be able to:

- Explain shared vs. exclusive locks, and row-level vs. table-level locking
- Reproduce, diagnose, and fix the classic "two customers buy the last item" race condition
- Write `SELECT ... FOR UPDATE`, `FOR UPDATE NOWAIT`, `FOR UPDATE SKIP LOCKED`, and `FOR SHARE`
- Deliberately cause a deadlock, read the resulting error, and explain why the database chose a victim
- Apply deadlock prevention strategies, most importantly consistent lock ordering
- Compare pessimistic locking (`FOR UPDATE`) against optimistic concurrency (version columns)
- Recognize lock-related production incidents: contention, long transactions, lock escalation

---

## 12.1 Why Locks Exist

**Simple explanation:** Imagine two people trying to grab the same last umbrella from a
stand at the exact same moment. Without some kind of coordination rule ("whoever
touches it first holds it until they're done"), both people could walk away believing
they got the umbrella. A lock is that coordination rule, enforced by the database
instead of by politeness.

**Technical explanation:** A lock is a flag the database attaches to a piece of
data (a row, a page, a table) that says "a transaction is currently reading or
writing this — other transactions must wait, or be blocked, or fail, depending on
what kind of access they're requesting." Locks are the concurrency-control mechanism
that makes the **I** (Isolation) in ACID real. Without locks, two concurrent
transactions could interleave their reads and writes in ways that silently corrupt
data — the "lost update" and "dirty read" anomalies you saw in Chapter 11 are not
theoretical; they are exactly what happens when locking is absent or done wrong.

**Why locks exist:** Locks exist to prevent concurrent transactions from corrupting
each other's view of data or losing updates. A relational database is a shared,
multi-user system by design — dozens or thousands of connections read and write the
same tables simultaneously. Locks are the traffic-control layer that makes that safe
without requiring every transaction to run one-at-a-time.

> **Important Note:** Locks are not something you "turn on." Every `UPDATE`,
> `DELETE`, and `INSERT` in every relational database takes locks automatically,
> whether you think about it or not. This chapter is about *understanding* that
> automatic behavior and *taking explicit control* of it (`FOR UPDATE` and friends)
> when the automatic behavior isn't strict enough for your business logic.

---

## 12.2 Shared Locks vs. Exclusive Locks

### Simple explanation

A **shared lock** is like several people reading the same physical book at once —
nobody is changing it, so many readers can hold a shared lock on the same row
simultaneously. An **exclusive lock** is like someone taking the only copy of a
document to go edit it with a pen — while they hold it, nobody else can read a
consistent version *or* write to it.

### Technical explanation

| Lock type | Also called | Who else can acquire it while held? | Purpose |
|---|---|---|---|
| **Shared (S)** | Read lock | Other shared locks: yes. Exclusive locks: no. | Let many transactions read the same row/table safely without blocking each other |
| **Exclusive (X)** | Write lock | Nothing else — not shared, not exclusive. | Guarantee only one transaction can change a row at a time |

The compatibility rule is simple and universal across every mainstream RDBMS:

```
                Shared (S)   Exclusive (X)
Shared (S)         ✅              ❌
Exclusive (X)      ❌              ❌
```

### Why this exists

If two transactions could hold exclusive locks on the same row at once, they could
both write conflicting values and the last write would silently erase the other —
the "lost update" problem. If a shared lock didn't block exclusive locks, one
transaction could read a row while another is mid-write, seeing half-applied data —
a "dirty read." The S/X compatibility matrix above is precisely engineered to rule
out both.

### Syntax and examples

In PostgreSQL, plain `SELECT` does **not** take a row lock at all under the default
`READ COMMITTED` isolation level — it reads a consistent snapshot via MVCC (covered
in Chapter 29) rather than blocking writers. To explicitly request a shared lock on
rows you read, you use `FOR SHARE`:

```sql
-- [PostgreSQL] Explicit shared lock: "I'm about to make a decision based on this
-- row's current value; don't let anyone change it out from under me, but other
-- readers are fine."
BEGIN;
SELECT balance FROM banking_db.accounts
WHERE account_id = 4
FOR SHARE;
-- ... business logic that must see a stable balance ...
COMMIT;
```

`UPDATE`, `DELETE`, and `SELECT ... FOR UPDATE` all take an **exclusive** row lock
automatically:

```sql
-- This UPDATE automatically takes an exclusive lock on the matching row(s)
-- for the duration of the transaction. No other transaction can update or
-- exclusively lock account_id = 4 until this transaction commits or rolls back.
BEGIN;
UPDATE banking_db.accounts
SET balance = balance - 5000
WHERE account_id = 4;
COMMIT;
```

### Expected behavior

If Session A holds an exclusive lock on `account_id = 4` and Session B runs
`UPDATE accounts SET balance = balance + 100 WHERE account_id = 4;`, **Session B's
terminal simply hangs** — no error, no output, just a blinking cursor — until
Session A commits or rolls back. This "silent hang" *is* what a blocked session
looks like. We'll show it as a real timeline in §12.5.

---

## 12.3 Row-Level Locks vs. Table-Level Locks

### Simple explanation

A row-level lock only blocks other transactions from touching *that specific row*.
A table-level lock blocks other transactions from touching *any row in the whole
table* (or from certain operations on the table's structure). Row-level locking is
like reserving one seat on a train; table-level locking is like reserving the
entire train car.

### Technical explanation

PostgreSQL, MySQL (InnoDB), Oracle, and SQL Server are all capable of row-level
locking for normal DML (`UPDATE`/`DELETE`/`SELECT FOR UPDATE`). Table-level locks
are taken for schema changes (`ALTER TABLE`), and for some heavier statements, and
can also be requested explicitly.

```sql
-- [PostgreSQL] Row-level: only the row for product_id = 4 in Pune-WH1 is locked
BEGIN;
UPDATE ecommerce_db.inventory
SET quantity_on_hand = quantity_on_hand - 1
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1';
-- other inventory rows (product_id = 1, 9, etc.) remain fully usable by other sessions
COMMIT;
```

```sql
-- [PostgreSQL] Explicit table-level lock: blocks ALL writers (and some readers,
-- depending on the mode) to the entire products table. Rarely needed in normal
-- application code — mostly used for maintenance operations.
BEGIN;
LOCK TABLE ecommerce_db.products IN SHARE ROW EXCLUSIVE MODE;
-- e.g. running a bulk price recalculation across the whole catalog
COMMIT;
```

PostgreSQL actually exposes eight distinct table-level lock modes (`ACCESS SHARE`,
`ROW SHARE`, `ROW EXCLUSIVE`, `SHARE UPDATE EXCLUSIVE`, `SHARE`,
`SHARE ROW EXCLUSIVE`, `EXCLUSIVE`, `ACCESS EXCLUSIVE`) with a compatibility matrix
between them — full detail belongs in Chapter 29 (Database Internals); for this
chapter, the important fact is only: **normal DML takes lightweight, narrowly
scoped table locks automatically that coexist with other DML**, while things like
`ALTER TABLE ... DROP COLUMN` take `ACCESS EXCLUSIVE`, which blocks *everything*,
including plain `SELECT`.

### Why this exists

If every `UPDATE` locked the whole table, an e-commerce site with 10,000 concurrent
shoppers could only process one order at a time across the *entire* `orders` table
— unacceptable throughput. Row-level locking lets unrelated transactions (buying
product 1 vs. product 9) run fully in parallel, while still protecting against two
transactions colliding on the *same* row.

### Comparison table

| | Row-level lock | Table-level lock |
|---|---|---|
| Scope | One row (or a small set matched by `WHERE`) | Entire table |
| Concurrency | High — unrelated rows unaffected | Low — everyone waits |
| Typical trigger | `UPDATE`, `DELETE`, `SELECT FOR UPDATE` | `ALTER TABLE`, `TRUNCATE`, explicit `LOCK TABLE` |
| Overhead | Small per-row bookkeeping | Cheap to track (one flag) but blocks broadly |

> **Important Note:** MySQL's `MyISAM` storage engine (legacy, rarely used today)
> only supports table-level locking. **[MySQL]** Always use `InnoDB` (the default
> since MySQL 5.5) for row-level locking and transactional integrity.

---

## 12.4 Lock Contention

**Simple explanation:** Lock contention is what happens when many transactions want
the same lock at the same time and have to queue up for it — like a single checkout
counter with a long line.

**Technical explanation:** Contention is measured by how often, and how long,
transactions wait on locks held by others. High contention on a specific row (a
"hot row") — for example, a single inventory row for a viral flash-sale product, or
a single bank account used as a company's central settlement account — causes
transactions to serialize even though the database *could* otherwise run them in
parallel, because they all fight over the same lock.

```sql
-- A "hot row": every single order for this flash-sale product updates the SAME row
-- ecommerce_db.inventory, product_id = 9 ('Wireless Earbuds', Mumbai-WH1)
UPDATE ecommerce_db.inventory
SET quantity_on_hand = quantity_on_hand - 1
WHERE product_id = 9 AND warehouse_location = 'Mumbai-WH1';
```

If 500 checkout requests hit that row inside the same second, 499 of them queue up
waiting for the exclusive lock held by whichever transaction got there first. This
is not a bug — it's the database correctly protecting the row — but it does mean
throughput on that row is capped at "however fast one transaction can commit,"
which is a real capacity-planning concern for hot rows (see §12.11 and §12.14).

**Why it exists:** Contention itself isn't something the database "decides" to
create — it's the observable cost of correctness. The alternative (letting
transactions skip the queue) is exactly the data corruption locks exist to prevent.

> **⚠️ Warning:** High contention is often a **modeling** problem, not just a
> concurrency problem. If one row genuinely receives thousands of concurrent
> writes, consider sharding the counter (e.g., per-warehouse `inventory` rows,
> which `ecommerce_db` already does), batching updates, or using an
> append-only ledger table (like `banking_db.transactions`) and computing balances
> on read instead of mutating one row per operation.

---

## 12.5 Central Case Study: Two Users Buying the Last Item

This is the scenario that makes locking concrete: **two customers try to buy the
last units of the same product at the same instant.**

We'll use `ecommerce_db.inventory`:

```sql
SELECT product_id, warehouse_location, quantity_on_hand
FROM ecommerce_db.inventory
WHERE product_id = 4;
```

```
 product_id | warehouse_location | quantity_on_hand
------------+---------------------+------------------
          4 | Pune-WH1            |                3
```

Product 4 is **"GameBook 15"** (`ecommerce_db.products`, `SKU-LAP-002`), and there
are only **3 units left** in the Pune-WH1 warehouse. Two customers — Sara Patel
(`user_id = 2`) and Dev Malhotra (`user_id = 3`) — each add 2 units of the GameBook
15 to their cart and click "Buy Now" within the same second. Demand (2 + 2 = 4)
exceeds supply (3). A correct system must let exactly one of them succeed in full,
and the other must be told the truth ("only 1 left") rather than being oversold.

### 12.5.1 The BROKEN naive approach — "check, then act"

The intuitive but wrong way to write this logic is: **read the quantity, check it
in application code, then update it** — three separate steps, none of which locks
anything in between.

```sql
-- Step 1: read the current quantity (a plain SELECT takes no lock in PostgreSQL)
SELECT quantity_on_hand FROM ecommerce_db.inventory
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1';

-- Step 2 (application code, not SQL): "quantity_on_hand (3) >= requested (2)? Yes -> proceed"

-- Step 3: apply the decrement
UPDATE ecommerce_db.inventory
SET quantity_on_hand = quantity_on_hand - 2
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1';
```

#### Timeline: check-then-act race condition

| Time | Session A (Sara, buying 2) | Session B (Dev, buying 2) |
|---|---|---|
| t0 | `BEGIN;` | `BEGIN;` |
| t1 | `SELECT quantity_on_hand ...` → sees **3** | |
| t2 | | `SELECT quantity_on_hand ...` → sees **3** |
| t3 | App logic: "3 ≥ 2 ✅, proceed" | |
| t4 | | App logic: "3 ≥ 2 ✅, proceed" |
| t5 | `UPDATE ... SET quantity_on_hand = quantity_on_hand - 2 ...;` | |
| t6 | `COMMIT;` — row is now **1** | |
| t7 | | `UPDATE ... SET quantity_on_hand = quantity_on_hand - 2 ...;` |
| t8 | | This `UPDATE` was **blocked** at t7 waiting for A's exclusive lock. Once A commits, B's `UPDATE` proceeds against the *current* value (1), computing `1 - 2 = -1`. |
| t9 | | `ERROR: new row for relation "inventory" violates check constraint "inventory_quantity_on_hand_check"` |
| t10 | | `ROLLBACK;` (transaction is aborted) |

#### Step-by-step explanation

1. **t0–t2:** Both sessions open transactions and both run a plain `SELECT`. Neither
   takes a lock (PostgreSQL's default `READ COMMITTED` `SELECT` is lock-free), so
   both see the same pre-sale value: **3**.
2. **t3–t4:** Both sessions' *application code* — completely outside the database's
   view — independently concludes "there's enough stock, go ahead." Neither knows
   about the other.
3. **t5–t6:** Session A's `UPDATE` runs first. Because `UPDATE` **does** take an
   exclusive row lock, A safely decrements 3 → 1 and commits.
4. **t7:** Session B's `UPDATE` was issued but **could not run yet** — it needed the
   same row's exclusive lock, which A was holding. B's terminal just sits there
   (blocked) between t6 and t7/t8 — this is exactly the "silent hang" described in
   §12.2.
5. **t8:** The instant A commits and releases the lock, PostgreSQL's row-level
   locking guarantees B's `UPDATE` re-reads the **current committed value** (1, not
   the stale 3 that B's app logic decided on) before applying its own decrement.
   `1 - 2 = -1`.
6. **t9:** The table's `CHECK (quantity_on_hand >= 0)` constraint (defined in
   `databases/ecommerce_db.sql`) rejects the write. Session B gets a confusing,
   late-stage error — confusing because B's application already told the customer
   "processing your order" based on a stock check that said "yes, available."

> **⚠️ Warning — the naive "check, then act" pattern is a race condition.**
> The gap between reading a value and acting on it is a window where another
> transaction can change that value underneath you. This is one of the most common
> real-world sources of production data-integrity bugs, and it is *not* fixed just
> by wrapping the read and write in the same `BEGIN...COMMIT` transaction block —
> the transaction boundary alone doesn't lock anything until a write statement
> runs. You must **lock the row at read time** if your decision depends on it not
> changing (see §12.5.2).

An even worse variant of this bug happens when the application computes the new
value **in code** instead of using a relative `UPDATE`:

```sql
-- WORSE: sets an absolute value computed in application code from a stale read
UPDATE ecommerce_db.inventory
SET quantity_on_hand = 1   -- app computed "3 - 2 = 1" using its own stale read
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1';
```

Here, if both A and B each independently compute "3 - 2 = 1" from their own stale
reads and both `UPDATE ... SET quantity_on_hand = 1`, the **second write silently
overwrites the first with the same value**. No error is raised (1 is a valid,
non-negative number), both orders are marked `PAID`, both customers receive
confirmation emails — but only 3 physical units exist and 4 were promised. This is
the **lost update** anomaly from Chapter 11, and it is strictly worse than the
CHECK-constraint failure above because **nothing tells you it happened**. Silent
overselling is discovered days later when a warehouse worker can't find a unit to
ship.

### 12.5.2 The FIX — `SELECT ... FOR UPDATE`

**Simple explanation:** `SELECT ... FOR UPDATE` means "give me this row's current
value, *and* put an exclusive lock on it right now, before I even decide what to
do." Anyone else who wants to read-and-lock (or write) the same row has to wait
their turn.

**Technical explanation:** `FOR UPDATE` converts a read into a write-intent
operation from the lock manager's point of view. It acquires the same exclusive
row lock a real `UPDATE` would take, but lets you inspect the value first, inside
the same atomic unit of work, before deciding what to write.

**Full syntax:**

```sql
SELECT column_list
FROM table_name
WHERE condition
FOR UPDATE [OF table_name [, ...]] [NOWAIT | SKIP LOCKED];
```

- `FOR UPDATE` — take an exclusive lock on every row the query returns.
- `OF table_name` — **[PostgreSQL]** when joining multiple tables, restrict the
  lock to rows from a specific table only.
- `NOWAIT` — don't wait if the row is already locked; fail immediately (§12.5.3).
- `SKIP LOCKED` — don't wait; silently skip already-locked rows (§12.5.4).

```sql
-- [PostgreSQL / MySQL 8.0+ / Oracle] The corrected purchase flow
BEGIN;

SELECT quantity_on_hand
FROM ecommerce_db.inventory
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1'
FOR UPDATE;                       -- 🔒 exclusive lock taken HERE, before any decision

-- Application logic now runs against a value that CANNOT change underneath it:
-- "is quantity_on_hand (whatever it is right now) >= 2?"

UPDATE ecommerce_db.inventory
SET quantity_on_hand = quantity_on_hand - 2
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1';

COMMIT;
```

#### Timeline: the fixed flow

| Time | Session A (Sara, buying 2) | Session B (Dev, buying 2) |
|---|---|---|
| t0 | `BEGIN;` | `BEGIN;` |
| t1 | `SELECT ... FOR UPDATE;` → locks row, sees **3** | |
| t2 | | `SELECT ... FOR UPDATE;` issued — **blocks immediately** (row already locked by A). Session B's terminal hangs here, no output. |
| t3 | App logic: "3 ≥ 2 ✅" | *(still blocked)* |
| t4 | `UPDATE ... quantity_on_hand - 2 ...;` | *(still blocked)* |
| t5 | `COMMIT;` — row is now **1**, lock released | *(still blocked, about to wake up)* |
| t6 | | B's `FOR UPDATE` finally returns, locking the row and reading the **fresh, post-commit** value: **1** |
| t7 | | App logic: "1 ≥ 2? ❌ No — reject or offer to reduce quantity to 1" |
| t8 | | `ROLLBACK;` (or `UPDATE` for 1 unit instead, then `COMMIT;`) — cleanly, with **no error**, no oversell |

#### Step-by-step explanation

1. **t1:** Session A's `SELECT ... FOR UPDATE` does two things atomically: reads
   `quantity_on_hand` **and** locks the row exclusively. No one else can even
   *read-and-lock* it until A finishes.
2. **t2:** Session B issues the identical `FOR UPDATE` query. Because the row is
   already exclusively locked, B's query **does not return** — it blocks. This is
   the visible "hang" behavior: if you ran this by hand in `psql` in two terminals,
   Session B's terminal would show no prompt, no output, just a blinking cursor,
   until A releases the lock.
3. **t3–t5:** Session A proceeds with its business decision using a value it knows
   cannot be stale, updates, and commits — releasing the lock.
4. **t6:** The instant A's transaction ends, PostgreSQL wakes Session B's waiting
   query. Crucially, B's `FOR UPDATE` **re-reads the row from scratch** — it does
   not hand B the stale value of 3 that existed when B first asked. B correctly
   sees **1**.
5. **t7–t8:** B's application logic now makes the *correct* decision based on
   reality: only 1 unit remains, not 2. B can gracefully reject the order, offer a
   partial fulfillment, or show "only 1 left" — no CHECK-constraint error, no
   silent oversell, no confusing late failure.

> **Important Note:** The fix isn't "use a transaction" — Session A and B in the
> *broken* example were both already inside `BEGIN...COMMIT`. The fix is
> specifically **locking the row at the moment you read the value your decision
> depends on**, via `FOR UPDATE`, so the read and the eventual write are protected
> by the same lock.

### 12.5.3 `FOR UPDATE NOWAIT` — fail fast instead of waiting

**Simple explanation:** Normally, a blocked session just waits patiently, however
long that takes. `NOWAIT` says "if I can't get the lock **right now**, don't make
me wait at all — just tell me it's busy so I can react immediately."

**Technical explanation:** `NOWAIT` changes the lock-acquisition behavior from
"block until available" to "attempt to acquire; if unavailable, raise an error
immediately." This is useful when waiting has a real cost — e.g., a synchronous
web request holding an HTTP connection open, where you'd rather show the user
"someone else is checking out this item, try again" than freeze the page.

```sql
-- [PostgreSQL / Oracle / MySQL 8.0+]
BEGIN;
SELECT quantity_on_hand
FROM ecommerce_db.inventory
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1'
FOR UPDATE NOWAIT;
```

#### Timeline: NOWAIT

| Time | Session A | Session B |
|---|---|---|
| t0 | `BEGIN;` | `BEGIN;` |
| t1 | `SELECT ... FOR UPDATE;` → locks row, sees 3 | |
| t2 | | `SELECT ... FOR UPDATE NOWAIT;` |
| t3 | *(still holding the lock)* | **Immediately** returns an error — does not wait at all: |

```
ERROR:  could not obtain lock on row in relation "inventory"
```

**[Oracle]** the equivalent message is `ORA-00054: resource busy and acquire with
NOWAIT specified`. **[MySQL 8.0+]** it's `ERROR 3572 (HY000): Statement aborted
because lock(s) could not be acquired immediately`.

Session B's application catches this specific error and can immediately respond
"this item is being purchased by someone else right now, please retry" instead of
the user staring at a frozen page for however long Session A takes.

### 12.5.4 `FOR UPDATE SKIP LOCKED` — the job-queue pattern

**Simple explanation:** Imagine a shelf with several identical boxes, and several
warehouse workers who each just need to grab *any one* box, not a specific one.
`SKIP LOCKED` says "if a row I'd otherwise look at is already locked by someone
else, don't wait for it and don't error — just pretend it isn't there and move to
the next candidate."

**Technical explanation:** `SKIP LOCKED` filters out rows currently locked by other
transactions from the result set entirely, rather than blocking on them or
erroring. It's specifically designed for scenarios with a **pool of interchangeable
rows**, where any one of several currently-unlocked candidates will do.

Consider **Galaxy Phone X** (`product_id = 1`), which is stocked in two warehouses:

```sql
SELECT product_id, warehouse_location, quantity_on_hand
FROM ecommerce_db.inventory
WHERE product_id = 1;
```

```
 product_id | warehouse_location | quantity_on_hand
------------+---------------------+------------------
          1 | Mumbai-WH1          |               40
          1 | Delhi-WH2           |               15
```

Two fulfillment workers each need to claim *some* warehouse stock row for
product 1 to process a shipment — they don't care which specific warehouse, they
just need to lock one row, decrement it, and move on without stepping on each
other.

```sql
-- [PostgreSQL / MySQL 8.0+ / Oracle] Grab ANY one unlocked stock row for product 1
BEGIN;

SELECT inventory_id, warehouse_location, quantity_on_hand
FROM ecommerce_db.inventory
WHERE product_id = 1 AND quantity_on_hand > 0
ORDER BY inventory_id
FOR UPDATE SKIP LOCKED
LIMIT 1;

-- ... decrement whichever row was returned, ship from that warehouse, COMMIT ...
```

#### Timeline: SKIP LOCKED

| Time | Worker A | Worker B |
|---|---|---|
| t0 | `BEGIN;` | `BEGIN;` |
| t1 | `SELECT ... FOR UPDATE SKIP LOCKED LIMIT 1;` → candidate rows are Mumbai-WH1 and Delhi-WH2; A locks **Mumbai-WH1** (first in `inventory_id` order) | |
| t2 | | `SELECT ... FOR UPDATE SKIP LOCKED LIMIT 1;` → Mumbai-WH1 is locked by A, so it's **skipped**, not waited on; the query immediately returns **Delhi-WH2** instead, locking it |
| t3 | `UPDATE ... SET quantity_on_hand = quantity_on_hand - 1 WHERE warehouse_location='Mumbai-WH1'; COMMIT;` | `UPDATE ... SET quantity_on_hand = quantity_on_hand - 1 WHERE warehouse_location='Delhi-WH2'; COMMIT;` |

Both workers complete **in parallel, with zero blocking**, each processing a
different physical warehouse row.

#### Why `SKIP LOCKED` matters specifically for job-queue / worker patterns

If Worker B had used plain `FOR UPDATE` instead, it would have **blocked** waiting
for Mumbai-WH1 to free up, even though a perfectly good alternative row
(Delhi-WH2) was sitting right there, available. In a job-queue table with many
pending jobs and many worker processes polling it, plain `FOR UPDATE` would force
workers to serialize on whichever job happens to be listed first — defeating the
entire purpose of having multiple workers. `SKIP LOCKED` lets every worker
immediately grab a *different* available row and proceed in true parallel,
which is exactly the throughput job queues need. This is precisely the mechanism
behind production job-queue implementations (Postgres-backed queues like
`pgboss`, `graphile-worker`, and hand-rolled "claim a row" queues all use this
pattern) — see the chapter-ending challenge for a full job-queue design.

> **Important Note — `FOR SHARE`.** **[PostgreSQL]** `FOR SHARE` takes a shared
> lock instead of exclusive: multiple transactions can hold `FOR SHARE` on the same
> row simultaneously (blocking writers but not each other), which is useful when
> you need to *guarantee a row doesn't change* while you read it, but you're not
> planning to write it yourself. For example, before creating a `loans` record
> against a customer, you might `SELECT customer_id FROM banking_db.customers
> WHERE customer_id = 3 FOR SHARE` to ensure the customer record isn't deleted or
> altered mid-transaction, without blocking other read-only transactions that also
> just need to confirm the customer exists. `FOR SHARE` also supports `NOWAIT` and
> `SKIP LOCKED`. **[MySQL 8.0+]** supports `FOR SHARE` (the modern replacement for
> the older `LOCK IN SHARE MODE`). **[Oracle]** has no direct `FOR SHARE`
> equivalent; shared-mode table locking is done via `LOCK TABLE ... IN SHARE MODE`
> at the table level instead of per-row.

### 12.5.5 Dialect equivalents summary

| Dialect | Exclusive row lock on read | `NOWAIT` equivalent | `SKIP LOCKED` equivalent | Shared row lock |
|---|---|---|---|---|
| **[PostgreSQL]** | `SELECT ... FOR UPDATE` | `FOR UPDATE NOWAIT` | `FOR UPDATE SKIP LOCKED` | `SELECT ... FOR SHARE` |
| **[MySQL 8.0+]** | `SELECT ... FOR UPDATE` | `FOR UPDATE NOWAIT` | `FOR UPDATE SKIP LOCKED` | `SELECT ... FOR SHARE` |
| **[MySQL < 8.0]** | `SELECT ... FOR UPDATE` | not supported (must poll/retry) | not supported | `SELECT ... LOCK IN SHARE MODE` |
| **[Oracle]** | `SELECT ... FOR UPDATE` | `FOR UPDATE NOWAIT` (or `FOR UPDATE WAIT n`) | `FOR UPDATE SKIP LOCKED` | no direct row-level equivalent; use `LOCK TABLE ... IN SHARE MODE` |
| **[SQL Server]** | `SELECT ... WITH (UPDLOCK, ROWLOCK)` | `SET LOCK_TIMEOUT 0;` before the query (or `WITH (NOWAIT)` hint) | `WITH (UPDLOCK, ROWLOCK, READPAST)` | `SELECT ... WITH (HOLDLOCK, ROWLOCK)` |

**[SQL Server]** does not use `FOR UPDATE` syntax at all — it uses **table hints**
inside `WITH (...)` on the table reference:

```sql
-- [SQL Server] Equivalent of "SELECT ... FOR UPDATE" for the last-item scenario
BEGIN TRANSACTION;

SELECT quantity_on_hand
FROM ecommerce_db.inventory WITH (UPDLOCK, ROWLOCK)
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1';

UPDATE ecommerce_db.inventory
SET quantity_on_hand = quantity_on_hand - 2
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1';

COMMIT TRANSACTION;
```

- `UPDLOCK` — take an update lock (roughly equivalent to `FOR UPDATE`'s intent):
  blocks other writers, but allows plain reads to see the pre-write value under
  `READ COMMITTED`.
- `ROWLOCK` — hint the engine to lock at row granularity rather than letting it
  choose page/table granularity.
- `READPAST` — the `SKIP LOCKED` equivalent: skip rows currently locked by other
  transactions instead of blocking on them.

---

## 12.6 Deadlocks

### Simple explanation

A deadlock is what happens when two people each need something the other person is
holding, and neither will let go first. Session A is holding Lock 1 and wants
Lock 2. Session B is holding Lock 2 and wants Lock 1. Both wait forever — unless
something intervenes.

### Technical explanation

A deadlock is a cycle of transactions each waiting on a lock held by the next
transaction in the cycle, such that no transaction in the cycle can ever proceed.
Unlike ordinary lock contention (where waiting eventually ends when the lock
holder commits), a deadlock cannot resolve itself — every party is stuck waiting
on someone who is also stuck waiting.

### Why this exists (or rather, why the database must handle it)

Deadlocks aren't something the database "wants" — they are an emergent risk of
allowing transactions to acquire multiple locks over time. The database can't
prevent every possible deadlock (that would require predicting the future), so
instead it **detects** them and **breaks** the cycle by force, so that at least one
transaction can make progress instead of both hanging indefinitely.

### Concrete example: two account transfers

Consider a real transfer scenario on `banking_db.accounts`. Session A is
transferring money from account 1 (Ravi Shankar, SAVINGS, ₹150,000) to account 2
(Ravi Shankar, CURRENT). Session B, at the same moment, is transferring money the
*other direction* — from account 2 to account 1 (perhaps a scheduled sweep in the
opposite direction):

```sql
-- Session A: transfer 1000 from account 1 -> account 2
BEGIN;
UPDATE banking_db.accounts SET balance = balance - 1000 WHERE account_id = 1;
-- (locks account_id = 1)
-- ... A now needs to credit account 2 ...
UPDATE banking_db.accounts SET balance = balance + 1000 WHERE account_id = 2;
-- (blocked: waiting for account_id = 2's lock, held by Session B)
```

```sql
-- Session B: transfer 500 from account 2 -> account 1
BEGIN;
UPDATE banking_db.accounts SET balance = balance - 500 WHERE account_id = 2;
-- (locks account_id = 2)
-- ... B now needs to credit account 1 ...
UPDATE banking_db.accounts SET balance = balance + 500 WHERE account_id = 1;
-- (blocked: waiting for account_id = 1's lock, held by Session A)
```

#### Timeline: the deadlock

| Time | Session A | Session B |
|---|---|---|
| t0 | `BEGIN;` | `BEGIN;` |
| t1 | `UPDATE accounts SET balance = balance - 1000 WHERE account_id = 1;` → locks account 1 | |
| t2 | | `UPDATE accounts SET balance = balance - 500 WHERE account_id = 2;` → locks account 2 |
| t3 | `UPDATE accounts SET balance = balance + 1000 WHERE account_id = 2;` → **blocks**, waiting on account 2 (held by B) | |
| t4 | | `UPDATE accounts SET balance = balance + 500 WHERE account_id = 1;` → **blocks**, waiting on account 1 (held by A) |
| t5 | *(waiting on B, forever, unless something breaks the cycle)* | *(waiting on A, forever, unless something breaks the cycle)* |
| t6 | After PostgreSQL's `deadlock_timeout` (default **1 second**) elapses, the deadlock detector runs and finds the cycle. One transaction is picked as the **victim** and forcibly aborted: | |
| t7 | `ERROR:  deadlock detected` *(this example — A is the victim)* | *(B's blocked `UPDATE` immediately succeeds now that A's lock on account 1 was released by the forced rollback)* |

The actual PostgreSQL error looks like this:

```
ERROR:  deadlock detected
DETAIL:  Process 18421 waits for ShareLock on transaction 4821; blocked by process 18422.
Process 18422 waits for ShareLock on transaction 4820; blocked by process 18421.
HINT:  See server log for query details.
CONTEXT:  while updating tuple (0,7) in relation "accounts"
```

**[MySQL/InnoDB]** the equivalent is: `ERROR 1213 (40001): Deadlock found when
trying to get lock; try restarting transaction`.
**[SQL Server]** raises: `Msg 1205, Level 13, State 51, Transaction (Process ID
57) was deadlocked on lock resources with another process and has been chosen as
the deadlock victim. Rerun the transaction.`
**[Oracle]** raises: `ORA-00060: deadlock detected while waiting for resource`.

### Step-by-step explanation

1. **t1–t2:** Each session's first `UPDATE` succeeds and acquires an exclusive
   lock — A on account 1, B on account 2. No conflict yet; both statements
   completed normally.
2. **t3–t4:** Each session's *second* `UPDATE` needs the *other* account's lock.
   A wants account 2 (B has it); B wants account 1 (A has it). Both statements
   block — this looks identical to ordinary contention at this point; nothing
   distinguishes it yet from a session that's simply waiting its turn.
3. **t5–t6:** This is the key difference from ordinary contention: **neither
   session can ever unblock**, because each is waiting on the other, which is
   itself waiting. The database's deadlock detector (see §12.8 for the internal
   mechanism) discovers this cycle and intervenes.
4. **t7:** The database picks one transaction — the **victim** — and forcibly
   rolls it back with an error, releasing its locks. The *other* transaction's
   blocked statement can now proceed immediately, since the lock it was waiting
   for was just released by the victim's rollback.

> **⚠️ Warning — a deadlock is not a bug you can "catch and ignore."** The victim
> transaction's work is fully rolled back — none of its statements took effect,
> not even the ones that appeared to succeed earlier (A's debit of account 1 is
> undone too). Application code **must** be written to detect this specific error
> and retry the whole transaction from the beginning, not just resume from where
> it left off.

### 12.6.1 The fix — consistent lock ordering

**Simple explanation:** If everyone agrees to always pick up the smaller-numbered
item first, no two people can ever be stuck in a "you go first" standoff.

**Technical explanation:** The deadlock above only happened because Session A
locked accounts in order (1, then 2) while Session B locked them in the *opposite*
order (2, then 1). If **every transaction, regardless of which account is
logically "from" and which is "to," always locks the lower `account_id` first**,
the cycle becomes structurally impossible.

```sql
-- [PostgreSQL] Deadlock-proof transfer: ALWAYS touch the lower account_id first,
-- regardless of transfer direction
BEGIN;

-- Determine lock order once, in application code or via SQL:
-- LEAST(from_id, to_id) is locked first, GREATEST(from_id, to_id) second.

-- Session A transferring 1 -> 2:  LEAST(1,2)=1, GREATEST(1,2)=2  -> lock 1, then 2
SELECT balance FROM banking_db.accounts WHERE account_id = 1 FOR UPDATE;
SELECT balance FROM banking_db.accounts WHERE account_id = 2 FOR UPDATE;

UPDATE banking_db.accounts SET balance = balance - 1000 WHERE account_id = 1;
UPDATE banking_db.accounts SET balance = balance + 1000 WHERE account_id = 2;

COMMIT;
```

```sql
-- Session B transferring 2 -> 1: even though the transfer is "backwards,"
-- it STILL locks account_id = 1 before account_id = 2, matching Session A's order.
BEGIN;

SELECT balance FROM banking_db.accounts WHERE account_id = 1 FOR UPDATE; -- lock lower id FIRST
SELECT balance FROM banking_db.accounts WHERE account_id = 2 FOR UPDATE; -- then higher id

UPDATE banking_db.accounts SET balance = balance + 500 WHERE account_id = 1;
UPDATE banking_db.accounts SET balance = balance - 500 WHERE account_id = 2;

COMMIT;
```

With this rule in place, Session B now *waits* politely at its first `FOR UPDATE`
(on account 1) until Session A fully finishes — normal contention, resolved by
waiting, never a cycle. This is the single most effective and most commonly used
deadlock-prevention technique in real financial and inventory systems.

```sql
-- A reusable pattern: compute the lock order explicitly instead of relying on
-- callers to remember it
BEGIN;
SELECT account_id, balance
FROM banking_db.accounts
WHERE account_id IN (1, 2)
ORDER BY account_id        -- ascending order, always, regardless of from/to
FOR UPDATE;
-- ... now apply the debit/credit logic using the locked rows ...
COMMIT;
```

---

## 12.7 Deadlock Prevention Strategies

| Strategy | Simple explanation | Why it works |
|---|---|---|
| **Consistent lock ordering** | Always acquire locks on multiple rows/tables in the same, agreed-upon order everywhere in the codebase (e.g., always by ascending `account_id` or `product_id`) | Removes the possibility of a cycle — if everyone queues in the same direction, nobody can be waiting "behind" someone who is waiting behind them |
| **Keep transactions short** | Do the minimum work necessary between `BEGIN` and `COMMIT`; don't do unrelated work while holding locks | Shorter lock hold times mean smaller windows for two transactions' lock needs to overlap in the first place |
| **Avoid user interaction inside a transaction** | Never wait on user input, a slow API call, or an email send while a transaction is open | A transaction that pauses for a human (who might go get coffee) can hold locks for minutes, turning normal contention into a de facto system-wide freeze, and dramatically raising deadlock odds |
| **Acquire all locks up-front** | Where practical, lock every row you'll need in a single query (e.g., `SELECT ... WHERE id IN (...) ORDER BY id FOR UPDATE`) rather than locking incrementally | A single lock-acquisition step, ordered consistently, is much harder to deadlock against than several separate statements |
| **Use lower isolation only when safe** | Don't reach for `SERIALIZABLE` everywhere "just in case" — it increases contention and serialization-failure retries (Chapter 11) | Matches locking strictness to actual business need |

> **⚠️ Warning — the #1 real-world cause of deadlocks.** In production systems, the
> most common deadlock source is **not** exotic SQL — it's the *same* transfer/purchase
> logic being called from two different code paths (say, a nightly batch job and an
> API endpoint) that lock the *same* two rows in *inconsistent order*. Auditing "does
> every code path that touches two-or-more of the same rows always lock them in the
> same order?" is one of the highest-value reviews you can do on a codebase with
> financial or inventory logic.

---

## 12.8 Internal Behavior: How Locks and Deadlock Detection Actually Work

**Conceptual model — the lock manager.** Every mainstream RDBMS maintains an
in-memory structure often called the **lock manager** (PostgreSQL calls its
subsystem the "lock manager" explicitly). Conceptually, it's a big hash table
keyed by "what is being locked" (a specific tuple/row identifier, a table OID,
etc.), where each entry tracks:

- which transaction(s) currently hold a lock on this resource, and in what mode
  (shared, exclusive, etc.)
- which transaction(s) are queued up waiting for a lock on this resource, and in
  what mode they're requesting

When transaction T requests a lock, the lock manager checks the compatibility
matrix (§12.2) against everything already held. If compatible, T is granted the
lock immediately. If not, T is put to sleep on a wait queue for that resource,
which is exactly the "blocked / hanging" behavior you saw in the timelines above.

**The wait-for graph and deadlock detection.** To detect deadlocks, the database
conceptually builds a **wait-for graph**: a node per transaction, and a directed
edge "T1 → T2" meaning "T1 is waiting for a lock currently held by T2." A deadlock
exists exactly when this graph contains a **cycle** (T1 waits for T2, which waits
for T1 — or a longer cycle through three or more transactions).

PostgreSQL does not check for cycles on every single lock wait (that would be
wasteful, since the overwhelming majority of waits are resolved normally when the
lock holder commits). Instead:

1. When a transaction starts waiting on a lock, a timer starts.
2. If the wait exceeds `deadlock_timeout` (default **1 second**), that backend
   runs the deadlock detection algorithm: it builds the current wait-for graph and
   searches for a cycle involving itself.
3. If no cycle is found, it just keeps waiting normally (this was ordinary
   contention, not a deadlock — the lock holder is simply slow, not stuck).
4. If a cycle **is** found, the detecting process picks a **victim** — in
   PostgreSQL, this is generally the transaction that discovered the deadlock —
   and forcibly aborts it with the `ERROR: deadlock detected` message, releasing
   its locks so the rest of the cycle can proceed.

**[MySQL/InnoDB]** and **[SQL Server]** both use similar wait-for-graph cycle
detection, but check continuously/more eagerly rather than on a fixed timer, and
each has its own victim-selection heuristic (InnoDB tends to pick the transaction
with the smallest amount of undo work to roll back; SQL Server considers each
transaction's assigned "deadlock priority," configurable via
`SET DEADLOCK_PRIORITY`).

> **Important Note:** You cannot reliably predict *which* transaction will be
> chosen as the victim in the general case — application code must be written to
> handle **either** transaction being the one that gets the deadlock error, and
> must retry that transaction's logic from the start.

---

## 12.9 Common Mistakes

1. **Holding a transaction open across a slow external call.** Calling a payment
   gateway, sending an email, or waiting on a third-party API *while a database
   transaction is open and holding row locks* turns a normally-fast lock hold
   (milliseconds) into a multi-second (or multi-minute, if the external call
   hangs) lock hold — during which every other transaction wanting that row queues
   up behind it. Do the external call **before** `BEGIN` or **after** `COMMIT`,
   never in between.
2. **Locking rows in inconsistent order across different code paths.** As covered
   in §12.7 — if the nightly reconciliation job locks accounts in `account_id`
   order but the live transfer API locks them in "from, then to" order, deadlocks
   will occur under load even though each code path looks correct in isolation.
3. **Forgetting `FOR UPDATE` and getting a race condition.** As shown exhaustively
   in §12.5.1 — any time application logic makes a decision ("is there enough
   stock," "is this seat still free," "has this coupon already been used") based
   on a `SELECT` that isn't locked, and then acts on that decision with a later
   statement, there is a race condition window.
4. **Treating a deadlock error as a real business failure.** A deadlock is a
   *transient* condition — the transaction did nothing wrong, it was simply
   unlucky in timing. Surfacing "deadlock detected" as a user-facing error
   ("Your purchase failed") instead of silently retrying the transaction a few
   times is a poor user experience for a condition the system should self-heal.
5. **Using `SELECT` (without `FOR UPDATE`) when you actually need `FOR UPDATE`,
   because "it's inside a transaction so it must be safe."** Being inside
   `BEGIN...COMMIT` guarantees atomicity and (depending on isolation level) a
   consistent snapshot — it does **not** by itself lock rows you only read.
6. **Never testing under real concurrency.** Race conditions and deadlocks are
   often invisible in single-user development and testing, and only appear under
   production load. Load-testing checkout/transfer flows with genuinely
   concurrent requests is the only reliable way to catch these bugs before users
   do.

---

## 12.10 Edge Cases

### Lock escalation **[SQL Server]**

**[SQL Server]** SQL Server can automatically **escalate** a large number of
row-level or page-level locks held by a single transaction into a single
table-level lock, typically when a transaction is holding roughly 5,000+ locks on
one table, or under memory pressure on the server. This is a real,
dialect-specific behavior: it trades granularity for memory efficiency, but has a
serious side effect — a transaction that escalates to a table lock will suddenly
block *every other transaction* touching that table, not just the rows it
originally cared about. A bulk `UPDATE` that touches hundreds of thousands of
`accounts` rows in one statement can escalate to a table lock and freeze the
entire `accounts` table for other users until it commits. Escalation can be
controlled per-table with `ALTER TABLE ... SET (LOCK_ESCALATION = ...)`.
PostgreSQL, MySQL/InnoDB, and Oracle do **not** perform this kind of automatic
row-to-table lock escalation — this is specifically a SQL Server behavior worth
knowing if you work across engines.

### Long-running transactions blocking many others

A transaction that stays open for a long time (a report query wrapped in
`BEGIN`, a debugging session left at a breakpoint mid-transaction, a batch job
that processes a million rows in one transaction) doesn't just risk deadlocks —
it holds every lock it has acquired for its *entire* lifetime. In PostgreSQL
specifically, long-running transactions also block `VACUUM` from cleaning up dead
row versions (see Chapter 29, MVCC), causing table and index bloat on top of lock
contention. A single forgotten `BEGIN;` left open in a `psql` session overnight,
holding a lock on a frequently-updated row, is a common real-world cause of "the
whole app is frozen" incidents.

> **⚠️ Warning:** Always know exactly when your transactions start and end. Tools
> like PostgreSQL's `pg_stat_activity` (`state = 'idle in transaction'`) exist
> specifically to help operators find and kill exactly this kind of stuck,
> lock-holding session.

---

## 12.11 Pessimistic Locking vs. Optimistic Concurrency

Everything in this chapter so far — `FOR UPDATE`, `NOWAIT`, `SKIP LOCKED` — is
**pessimistic locking**: it assumes conflicts are likely, so it locks proactively
before anyone gets a chance to collide.

**Optimistic concurrency** takes the opposite assumption: conflicts are *rare*, so
don't lock anything up front — instead, add a version marker to the row, and when
you write, check that the version hasn't changed since you read it. If it has,
someone else beat you to it; reject the write and let the caller retry.

```sql
-- Requires a version (or updated_at) column. Imagine ecommerce_db.inventory had:
--   ALTER TABLE inventory ADD COLUMN row_version INT NOT NULL DEFAULT 1;

-- Step 1: read the row AND its current version, with no lock at all
SELECT quantity_on_hand, row_version
FROM ecommerce_db.inventory
WHERE product_id = 4 AND warehouse_location = 'Pune-WH1';
-- suppose this returns: quantity_on_hand = 3, row_version = 7

-- Step 2: application decides to decrement, then writes conditionally:
UPDATE ecommerce_db.inventory
SET quantity_on_hand = quantity_on_hand - 2,
    row_version = row_version + 1
WHERE product_id = 4
  AND warehouse_location = 'Pune-WH1'
  AND row_version = 7;               -- <-- optimistic check

-- If another transaction already updated this row (bumping row_version to 8),
-- this UPDATE affects 0 rows. The application checks the row count:
-- 0 rows updated -> "someone else changed this first" -> re-read and retry.
```

A version column doesn't have to be an integer — `updated_at` timestamps are
commonly used the same way: `WHERE updated_at = '2024-06-01 10:15:32'`.

### Comparison: pessimistic vs. optimistic

| | Pessimistic (`FOR UPDATE`) | Optimistic (version/`updated_at` column) |
|---|---|---|
| When conflict is detected | Immediately, by blocking the second transaction until the first is done | Only at write time, via a failed `WHERE row_version = ...` match |
| Cost when conflicts are rare | Wasted — you pay for locking overhead and blocking even though collisions almost never happen | Cheap — no locking overhead at all in the common case |
| Cost when conflicts are frequent | Efficient — waiting transactions proceed in an orderly queue | Expensive — many wasted round trips as transactions repeatedly retry after losing the race |
| User experience on conflict | Waits (or errors with `NOWAIT`) | Write silently fails (0 rows affected); app must detect and retry |
| Needs schema change | No | Yes — requires a version/timestamp column |
| Best fit | High-contention "hot rows" (flash-sale inventory, shared counters), financial transfers | Low-contention data users rarely edit simultaneously (a user's own profile, a document draft) |

> **When to use which:** reach for `FOR UPDATE` when you *expect* concurrent
> writers to the same row regularly (checkout on a limited-stock item, account
> balance transfers) — the guaranteed correctness and predictable queuing are
> worth the blocking cost. Reach for optimistic concurrency when conflicts are
> genuinely rare and you'd rather pay an occasional cheap retry than pay locking
> overhead on every single read, such as a CMS where two editors *could* in theory
> edit the same article at once but almost never actually do.

---

## 12.12 Comparisons at a Glance

| Locking behavior | What happens if the row is already locked | Best for |
|---|---|---|
| **Default blocking (`FOR UPDATE`)** | Wait until the lock is released | Sequential fairness — every request eventually gets served, in the order they arrived |
| **`NOWAIT`** | Fail immediately with an error | User-facing flows where waiting has a real cost (don't freeze a web request) |
| **`SKIP LOCKED`** | Silently skip and try the next candidate row | Pools of interchangeable resources — job queues, "any available seat/warehouse slot" |
| **Optimistic (version column)** | No lock taken at all; conflict discovered only at write time | Low-contention data, or when you want zero locking overhead in the common case |

---

## 12.13 Real-World Use Cases

- **Inventory / ticket-booking systems:** exactly the `ecommerce_db.inventory`
  scenario in §12.5 — airline seats, concert tickets, and flash-sale products all
  need `SELECT ... FOR UPDATE` (or a carefully designed optimistic scheme) to
  prevent overselling the last unit.
- **Job queues / background workers:** `FOR UPDATE SKIP LOCKED` against a
  `job_queue` table lets any number of worker processes pull distinct jobs off the
  same table without colliding or blocking each other (full design in the chapter
  challenge below).
- **Financial transfers:** `banking_db.accounts` transfer logic, as in §12.6,
  needs both row locking (to prevent lost-update balance corruption) *and*
  consistent lock ordering (to prevent deadlocks) — this is the textbook example
  every banking system must get right.
- **Seat/slot reservation systems:** meeting room booking, hotel room
  availability, or appointment scheduling all face the identical "two people
  grab the last slot" problem as §12.5, solved the identical way.
- **Rate limiters and counters:** a single hot counter row (e.g., "API calls used
  this minute") is a textbook hot-row contention case (§12.4) — often better
  solved with sharded counters or an append-only log than with heavier locking.

---

## 12.14 Practice Questions

1. Explain, in your own words, why a plain `SELECT` in PostgreSQL under
   `READ COMMITTED` does not block a concurrent `UPDATE` on the same row, but
   `SELECT ... FOR UPDATE` does.
2. Two sessions both run `SELECT balance FROM banking_db.accounts WHERE
   account_id = 4 FOR SHARE;` at the same time. Does either one block? Why or
   why not?
3. Using `ecommerce_db.inventory`, write the broken "check, then act" version of
   a purchase for `product_id = 9` ('Wireless Earbuds', currently `quantity_on_hand
   = 0`). What specifically goes wrong if two customers attempt this
   simultaneously, given that its stock is already zero?
4. What is the practical difference between `FOR UPDATE NOWAIT` and
   `FOR UPDATE SKIP LOCKED` when both are used against a multi-row candidate set
   (e.g., `WHERE quantity_on_hand > 0 LIMIT 1`)?
5. Describe, step by step, how PostgreSQL's deadlock detector decides a deadlock
   has occurred, including what triggers the check and how long it waits before
   checking.
6. Why does locking `account_id = LEAST(from_id, to_id)` before
   `GREATEST(from_id, to_id)` prevent the classic two-session transfer deadlock,
   even when Session A and Session B are transferring money in opposite
   directions?
7. A developer wraps a transaction around a database update **and** a call to an
   external shipping-label API inside the same `BEGIN...COMMIT` block. Identify
   two distinct problems this causes.
8. Compare pessimistic locking and optimistic concurrency for a "user edits their
   own profile" feature versus a "flash-sale checkout" feature. Which would you
   choose for each, and why?
9. **[SQL Server]** What is lock escalation, what typically triggers it, and why
   can it cause unrelated queries to suddenly slow down or block?
10. A transaction receives `ERROR: deadlock detected`. What should the
    application code do next, and why is it incorrect to simply show the user an
    error message and stop?

---

## 12.15 Chapter Challenge

### Challenge 1 — Design the complete concurrency-safe "purchase last item" flow

Using `ecommerce_db` (`products`, `inventory`, `orders`, `order_items`,
`payments`), design and write the **complete** SQL flow for a checkout endpoint
that:

1. Opens a transaction.
2. Locks the relevant `inventory` row for the product/warehouse being purchased
   using the correct locking clause from this chapter.
3. Verifies enough stock exists for the requested quantity; if not, cleanly aborts
   with no partial writes.
4. Decrements `quantity_on_hand`.
5. Inserts the `orders` and `order_items` rows.
6. Inserts a `payments` row.
7. Commits.

Then answer: what would you add to make this robust against a customer's browser
closing mid-checkout (i.e., a transaction that never receives a `COMMIT` or
`ROLLBACK` from the client)? Consider statement/idle-in-transaction timeouts.

### Challenge 2 — Design a job-queue table and a `SKIP LOCKED` worker query

Design a `job_queue` table (columns of your choice, but at minimum: an id, a
status, a payload, and a claimed-by/worker identifier) intended to be polled by
multiple concurrent worker processes. Then write:

1. The `CREATE TABLE` statement.
2. A single atomic "claim the next available job" query using
   `FOR UPDATE SKIP LOCKED` that a worker can run in a loop, such that any number
   of worker processes running this same query concurrently will each claim a
   **different** job with no blocking and no double-processing.
3. The follow-up statement a worker runs after finishing a job, to mark it
   complete.

Explain, in one paragraph, what would go wrong (in terms of both correctness and
throughput) if `SKIP LOCKED` were replaced with plain `FOR UPDATE` in this design.

---

## Key Takeaways

- Locks exist to prevent concurrent transactions from corrupting each other's view
  of data or losing updates — they are what makes transaction isolation real.
- **Shared locks** allow multiple concurrent readers; **exclusive locks** allow
  exactly one writer and block everyone else.
- **Row-level locks** protect a single row and maximize concurrency; **table-level
  locks** protect an entire table and are reserved mostly for schema changes.
- The "check, then act" pattern (`SELECT`, decide in app code, then `UPDATE`) is a
  **race condition** unless the initial read locks the row — use
  `SELECT ... FOR UPDATE`.
- `FOR UPDATE` blocks; `FOR UPDATE NOWAIT` fails immediately instead of blocking;
  `FOR UPDATE SKIP LOCKED` silently skips locked rows — ideal for job-queue/pool
  patterns where any available row will do.
- A **deadlock** is a cycle of transactions waiting on each other; the database
  detects it via a wait-for graph and forcibly rolls back one **victim**
  transaction with a `deadlock detected` error.
- The most reliable deadlock prevention technique is **consistent lock ordering**
  across every code path that touches the same set of rows.
- **Optimistic concurrency** (a version/`updated_at` column checked in the
  `WHERE` clause) is a lock-free alternative to `FOR UPDATE`, best suited to
  low-contention data.
- **[SQL Server]**-specific: row locks can automatically escalate to table locks
  under volume or memory pressure — a behavior not present in PostgreSQL, MySQL,
  or Oracle.

## What's Next

Chapter 13 moves from *concurrency safety* to *data correctness at the schema
level*: **Constraints** — `PRIMARY KEY`, `FOREIGN KEY`, `UNIQUE`, `CHECK`,
`NOT NULL`, and how the database enforces business rules even when application
code (or a careless script) tries to violate them. You've already seen constraints
appear as a side character in this chapter — the `CHECK (quantity_on_hand >= 0)`
constraint on `ecommerce_db.inventory` was exactly what turned a silent race
condition into a loud, catchable error in §12.5.1. Chapter 13 covers how to design
and use constraints like that one deliberately, as your last line of defense.

**Next:** [Chapter 13 — Constraints](13-constraints.md)
