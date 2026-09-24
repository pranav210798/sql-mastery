# Expert Interview Questions (Chapters 27–31 + Cross-Cutting Synthesis)

This is the fourth and final tier in the SQL Mastery interview bank (Beginner
→ Intermediate → Advanced → **Expert**). It assumes everything from the
first three tiers — joins, subqueries, CTEs, window functions, transactions,
locking, indexing, the planner, stored procedures — is already solid, and
targets what a **senior / staff / principal engineer** or a **database
reliability engineer** is actually asked to reason about: how PostgreSQL
behaves *underneath* the SQL you write (Chapter 29 — MVCC, WAL, vacuum),
how to secure and recover a production system (Chapters 27–28), how to keep
one alive across failures (Chapter 30), how to recognize and implement the
handful of patterns that recur in every serious schema (Chapter 31), and —
because this is genuinely how staff-level interviews are run — how to
**design a schema from a one-line prompt** and **diagnose a production
incident from a vague symptom**.

These questions are deliberately harder and more open-ended than the
Advanced tier. Several have more than one legitimate answer; where that's
true, the **Alternative approaches** section says so honestly rather than
pretending there's a single canonical solution. Coding questions that use
`company_db`, `ecommerce_db`, or `banking_db` are checked against the real
seed data in `databases/`. Questions that use `analytics_db` are explicitly
labeled **illustrative**, because that database is populated with
`random()` (see the header comment in `databases/analytics_db.sql`) and its
exact row counts differ every time it's regenerated. Primary dialect is
**[PostgreSQL]**; this tier discusses cross-dialect trade-offs freely
whenever the trade-off itself is the point of the question (e.g., "would
you even use RLS on a dialect that doesn't have it?").

Every question follows the same five-part structure: **Answer**, **Why it
works**, **Alternative approaches**, **Performance considerations**, and
**Common mistakes**.

---

## A. Database Internals & MVCC (Chapter 29)

These questions test whether a candidate's mental model of PostgreSQL goes
past "the query planner picks an index" — into how rows are actually
versioned, how crash recovery works, and how the system quietly protects
itself from its own bookkeeping (transaction ID wraparound). This is the
single most differentiating area between "advanced" and "expert" SQL
engineers: almost nobody outside of DBA/SRE roles has had to reason about it
directly, and almost every serious production incident in a busy OLTP
system eventually traces back to it.

### Q1. Walk through exactly what happens, tuple-by-tuple, when one transaction updates a row another transaction is reading — why doesn't the reader block?

**Answer:**
Take `banking_db.accounts`, `account_id = 1`, currently `balance = 150000.00`
stored as tuple **T0** (`xmin = 100`, committed long ago, `xmax` empty).

```
Session A (txid 501)                        Session B (txid 502)
BEGIN;
SELECT balance FROM accounts
  WHERE account_id = 1;    -- sees T0, reads 150000.00
                                             BEGIN;
                                             UPDATE accounts
                                               SET balance = balance - 10000
                                               WHERE account_id = 1;
                                             -- T0.xmax set to 502 (superseded, not deleted)
                                             -- new tuple T1 created: xmin=502, balance=140000.00
                                             COMMIT;
SELECT balance FROM accounts
  WHERE account_id = 1;    -- new statement -> new snapshot
```

`UPDATE` in PostgreSQL never overwrites a tuple's data in place. It marks
the old tuple's `xmax` with the updating transaction's ID and inserts a
brand-new tuple version with a fresh `xmin`. Both physical tuples exist on
the heap page simultaneously (linked by `ctid` chaining, or by the index if
it's not a HOT update — see Q4). Session A's first `SELECT` already has a
snapshot that says "only transactions below txid 502 are visible," so it
keeps seeing T0 (150000.00) regardless of what B does — A is reading a
*version*, not a *lock target*. Under **READ COMMITTED** (PostgreSQL's
default), A's second `SELECT` takes a brand-new snapshot for that statement,
which now considers txid 502 committed and visible, so T0 is filtered out
(its `xmax` is a committed, visible transaction) and T1 is returned instead
— A sees `140000.00` on its very next statement without ever having
blocked.

**Why it works:**
Because the reader and writer are never touching the *same* physical bytes
at the same time — the writer creates a new version, the reader's snapshot
pins it to whichever version existed when its snapshot was taken. Visibility
is decided by comparing a tuple's `xmin`/`xmax` against the reading
transaction's snapshot (`xmin`, `xmax`, and the in-progress `xip` list from
Chapter 29 §29.7.2), not by acquiring a lock on the row for the read.

**Alternative approaches:**
A purely lock-based engine (older MyISAM-style, or explicit `SELECT ... FOR
SHARE` in any MVCC engine) requires the reader to hold a shared lock and the
writer to wait for an exclusive lock — correct, but it means a slow reader
can stall every writer of that row, and vice versa. MVCC trades that
blocking for extra storage (multiple tuple versions) and the need for
vacuum to clean them up later.

**Performance considerations:**
This is "free" concurrency (no blocking) at the cost of write amplification
— every `UPDATE` is really an `INSERT` + a tombstone-marking of the old
row, and every *index* on any column touched by the update potentially
needs a new entry too (unless HOT applies — Q4). A table with a very high
update rate accumulates dead tuples fast; that's Q3.

> **Common mistakes:**
> - Assuming `UPDATE` modifies bytes in place, and therefore that a
>   long-running read on the same row will see a "torn" or partially
>   updated value — it can't; it sees a complete, consistent old version or
>   a complete, consistent new one, never a mix.
> - Confusing snapshot-based read consistency with the guarantee that a
>   *transaction* (not just a *statement*) sees a stable view — that
>   depends on isolation level (Q6/Q7), not on MVCC's existence.

---

### Q2. What is transaction ID wraparound, and precisely why can it "delete" data that was never deleted?

**Answer:**
PostgreSQL's transaction ID (`xid`) is a 32-bit counter — about 4.2 billion
values, compared circularly (like a clock: half "before," half "after" any
reference point). Visibility comparisons (`xmin`/`xmax` vs. a snapshot) rely
on being able to tell which of two `xid`s happened first — an operation
that only makes sense within roughly half the `xid` space at a time. If a
table's oldest live tuple is never **frozen** (marked with a special
sentinel meaning "always in the past, regardless of counter position") and
more than ~2 billion transactions elapse, the counter can wrap past that
tuple's `xmin`, and the comparison logic can conclude the tuple was created
*in the future* relative to the current snapshot — making perfectly valid,
committed data silently invisible. This is not a delete, and not
corruption of the bytes on disk — it's a corruption of the *comparison*
that decides visibility, which for query purposes is indistinguishable from
data loss.

**Why it works (i.e., why the safeguard exists):**
`autovacuum` runs in an aggressive, non-deferrable **anti-wraparound**
mode as any table's `relfrozenxid` (its oldest unfrozen transaction ID)
approaches `autovacuum_freeze_max_age` (default ~200 million transactions).
This mode rewrites tuple headers so old `xmin`s are replaced with the
frozen sentinel, permanently resolving them as "always visible" and
detaching them from the wraparound comparison. If this is starved for long
enough (see Q1's "idle in transaction" note and Q3), PostgreSQL will, at
roughly 1 billion transactions remaining before actual wraparound, refuse
to assign new transaction IDs at all ("database is not accepting commands
to avoid wraparound data loss") — a deliberately ugly, forced outage that
is far preferable to silent data loss.

**Alternative approaches:**
There is no real alternative to freezing in PostgreSQL's MVCC design — some
engines (e.g., Oracle's undo-segment based MVCC) don't have this exact
failure mode because they don't use a wrapping 32-bit comparison the same
way, but they have their own analogous bounded resources (undo retention).
The only "alternative" inside PostgreSQL is tuning *when* freezing happens
(`autovacuum_freeze_max_age`, `vacuum_freeze_min_age`) — not whether it
happens.

**Performance considerations:**
Anti-wraparound vacuums cannot be cancelled by a normal `pg_cancel_backend`
the way ordinary autovacuum workers can, and they compete for I/O exactly
when you can least afford it (a large, ancient table finally crossing the
threshold during business hours). The fix is proactive: monitor `age(
relfrozenxid)` continuously, not just react to it.

```sql
-- [PostgreSQL] transaction age per table — the wraparound early-warning query
SELECT relname,
       age(relfrozenxid) AS xid_age,
       2000000000 - age(relfrozenxid) AS xids_remaining
FROM pg_class
WHERE relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 10;
```

> **Common mistakes:**
> - Disabling or heavily throttling autovacuum "because it was causing I/O
>   spikes" without addressing *why* it needed to run that hard (usually a
>   high write rate or a blocking long transaction) — this defers the
>   problem and makes the eventual anti-wraparound vacuum larger and more
>   disruptive, not smaller.
> - Believing wraparound is only a "huge database" problem — a small,
>   extremely high-write table (a queue table, a session table) can burn
>   through 200 million transaction IDs surprisingly fast.

---

### Q3. Define bloat precisely, and explain the mechanism that most commonly causes it in production even with autovacuum running normally.

**Answer:**
**Bloat** is table or index storage that exceeds what the *live* row data
would require, because dead tuples (and dead index entries pointing at
them) accumulate faster than vacuum reclaims them. The single most common
production cause, even with autovacuum correctly configured, is a
**long-running or "idle in transaction" session**. Vacuum can only reclaim
a dead tuple once *no* current or future transaction's snapshot could
possibly still need it (Q1's visibility rule, run in reverse). A session
that opened a transaction, ran one query, and then never committed or
rolled back — a connection-pool bug, a forgotten interactive session, an
application holding a transaction open across a slow external API call —
freezes vacuum's "oldest transaction that might still need old data"
horizon at whatever it was when that transaction began. Every table in the
database can bloat while that one connection sits idle, because vacuum
literally cannot tell that data is dead to *everyone* until it's dead to
*that* transaction too.

**Why it works:**
This is the direct consequence of MVCC's visibility rule (Q1): a dead
tuple is defined as "a tuple whose `xmax` is older than every currently
open snapshot." One ancient snapshot is enough to keep arbitrarily many
tuples across arbitrarily many tables "not yet dead" from vacuum's
perspective.

**Alternative approaches:**
Some teams mitigate this at the infrastructure layer rather than relying on
discipline: set `idle_in_transaction_session_timeout` so PostgreSQL itself
kills a session that has held an open transaction beyond a threshold, and
`statement_timeout` for the underlying queries. This is a blunt instrument
(it will forcibly abort genuinely slow-but-legitimate transactions too) but
is far safer than an unbounded default in a busy OLTP system.

**Performance considerations:**
Bloat cascades: a bloated table means sequential scans (and even
index-assisted scans, which must still visit heap pages) read more pages
for the same live data, which increases I/O and degrades cache
hit ratio (more of `shared_buffers` is spent holding dead weight), which
increases latency, which increases how long transactions stay open, which
worsens the very problem causing the bloat.

```sql
-- [PostgreSQL] dead-tuple ratio per table, and any session blocking cleanup
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1) AS pct_dead
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;

SELECT pid, state, now() - xact_start AS txn_age, query
FROM pg_stat_activity
WHERE state = 'idle in transaction' OR (state <> 'idle' AND xact_start < now() - interval '10 minutes')
ORDER BY xact_start;
```

> **Common mistakes:**
> - Treating an idle-in-transaction connection as harmless "because it's
>   not running a query." It is one of the single most damaging things a
>   PostgreSQL connection can do while appearing completely quiet.
> - Reaching for `VACUUM FULL` as a first response to bloat — it takes an
>   `ACCESS EXCLUSIVE` lock and rewrites the entire table, which is often a
>   worse outage than the bloat itself on a live production table (see Q8).

---

### Q4. What is a HOT (Heap-Only Tuple) update, and why does an index on the wrong column silently make updates more expensive?

**Answer:**
A **HOT update** is an optimization where, if (a) the new tuple version
fits on the *same heap page* as the old one, and (b) **none of the columns
being updated are indexed**, PostgreSQL can avoid inserting a new entry
into every index on the table — the old index entry is left pointing at the
old tuple's page, and a page-internal chain (via `t_ctid`) leads from the
old tuple to the new one, resolved at read time. If, for example, an
`UPDATE ecommerce_db.inventory SET quantity_on_hand = quantity_on_hand - 1
WHERE product_id = 9 AND warehouse_location = 'Mumbai-WH1'` only touches
`quantity_on_hand`, and no index covers that column, this can be a HOT
update. If instead the same statement also touched `warehouse_location`
(part of the `UNIQUE (product_id, warehouse_location)` index), every index
on the table needs a new entry — HOT cannot apply, no matter how much free
space is on the page.

**Why it works:**
Index maintenance is often the *dominant* cost of an `UPDATE` on a
heavily-indexed table, not the heap write itself. HOT sidesteps it entirely
for the common case of "just changing a non-indexed value" (a counter, a
status column, a timestamp) by keeping the index pointing at a stable
location and resolving the "which version is current" question via the
in-page chain plus the same MVCC visibility rule from Q1.

**Alternative approaches:**
Lowering a table's `fillfactor` (e.g., `ALTER TABLE inventory SET
(fillfactor = 80)`) deliberately leaves free space on each heap page
specifically to make HOT updates more likely over the table's lifetime, at
the cost of the table using more disk pages per row up front. This is a
worthwhile trade for tables with a known, frequent non-indexed-column
update pattern (a `last_seen_at` column, a running counter) and pure
overhead for insert-mostly tables.

**Performance considerations:**
HOT also enables `HOT pruning` (opportunistic in-page cleanup of dead
tuples during normal reads, without a full vacuum pass) and reduces index
bloat, not just heap bloat — a table with a high HOT-update rate stays
healthier under lighter vacuum pressure than an equivalent table where
every update touches an indexed column.

```sql
-- [PostgreSQL] measure HOT update effectiveness
SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(n_tup_hot_upd::numeric / NULLIF(n_tup_upd, 0) * 100, 1) AS pct_hot
FROM pg_stat_user_tables ORDER BY n_tup_upd DESC LIMIT 10;
```

> **Common mistakes:**
> - Adding an index on a column "just in case," not realizing it silently
>   disables HOT updates for every statement that touches that column,
>   inflating write amplification across every index on the table.
> - Assuming HOT applies whenever the updated column is unindexed, forgetting
>   the *other* precondition — enough free space on the same page. A table
>   packed at `fillfactor = 100` with no headroom gets no HOT updates even
>   if every update only touches non-indexed columns.

---

### Q5. Explain the mechanics of WAL and checkpoints well enough to say exactly what is replayed after a crash, and why `full_page_writes` exists.

**Answer:**
Every change to a data page is first written, sequentially, as a record in
the **Write-Ahead Log** (WAL) — and only *then* is the change allowed to be
applied to the actual data file page in the buffer cache (which may sit
dirty in memory for a while before being flushed to disk). "Write-ahead"
is the entire guarantee: by the time a transaction is told `COMMIT`
succeeded, its WAL record is durably on disk (`fsync`'d), even if the
corresponding data-file page isn't yet. A **checkpoint** periodically
forces every currently-dirty data page to be flushed to disk and records
the WAL position at that moment; after a crash, recovery only needs to
replay WAL **from the last checkpoint's WAL position forward** — everything
before that is guaranteed already durably on disk in the data files
themselves, so replaying it again would be both unnecessary and (without
`full_page_writes`) unsafe.

**Why it works:**
This bounds crash-recovery time (you only ever replay "since the last
checkpoint," not the entire WAL history) while giving a hard durability
guarantee for every committed transaction, no matter when the crash
happens relative to the next checkpoint. `full_page_writes` protects
against a subtler failure: if the OS/disk crashes *while* writing a data
page (a "torn page" — only part of an 8KB page physically written), a WAL
record that stores only the *diff* to that page cannot repair it, because
the diff assumes an intact starting page. With `full_page_writes` on
(the default, and it should almost never be turned off), the **first**
change to any page after each checkpoint is logged as a **complete copy**
of the page, so recovery can always reconstruct a known-good starting
point before applying subsequent diffs.

**Alternative approaches:**
`full_page_writes = off` is technically available and reduces WAL volume,
but is only safe on storage that itself guarantees atomic page writes
(some enterprise SANs, or filesystems/hardware with battery-backed write
caches that guarantee no torn pages) — it is not a general-purpose
optimization and is rarely the right call on commodity cloud block storage.

**Performance considerations:**
`checkpoint_timeout` and `max_wal_size` control checkpoint frequency —
too-frequent checkpoints waste I/O (repeatedly re-flushing pages, and
repeatedly re-triggering `full_page_writes` for the first touch after each
one); too-infrequent checkpoints lengthen crash-recovery time and can cause
I/O spikes when a checkpoint finally does happen (a large burst of dirty
pages to flush at once). Spreading checkpoint I/O out (
`checkpoint_completion_target`) smooths this at the cost of a slightly
longer window where the checkpoint is "in progress."

> **Common mistakes:**
> - Believing WAL exists primarily for replication — it exists primarily
>   for crash recovery and durability; streaming replication (Chapter 30)
>   is built *on top of* the same log, not the other way around.
> - Turning off `full_page_writes` on ordinary cloud block storage to save
>   on WAL volume, trading a real (if rare) silent-corruption risk for a
>   modest and usually unnecessary I/O saving.

---

### Q6. Using `banking_db.accounts`, construct a concrete write-skew anomaly that PostgreSQL's `REPEATABLE READ` does **not** prevent, and explain the exact mechanism that allows it.

**Answer:**
Suppose a business rule: a customer may not withdraw from an account if
doing so would take the customer's *combined* balance across all their
accounts below zero — enforced only in application logic (not a `CHECK`
constraint spanning rows). Ravi Shankar (`customer_id = 1`) holds
`account_id = 1` (`150000.00`) and `account_id = 2` (`50000.00`) —
combined `200000.00`. Two concurrent withdrawal requests for `120000.00`
each arrive, one against each account:

```
Txn A (REPEATABLE READ)                     Txn B (REPEATABLE READ)
BEGIN;
SELECT SUM(balance) FROM accounts
  WHERE customer_id = 1;    -- sees 200000, snapshot taken
-- 200000 - 120000 = 80000 >= 0, OK to proceed
                                             BEGIN;
                                             SELECT SUM(balance) FROM accounts
                                               WHERE customer_id = 1; -- also sees 200000
                                             -- also computes OK to proceed
UPDATE accounts SET balance = balance - 120000
  WHERE account_id = 1;
COMMIT;
                                             UPDATE accounts SET balance = balance - 120000
                                               WHERE account_id = 2;
                                             COMMIT;
```

Both transactions read the *same* snapshot total (`200000`), both
independently conclude the withdrawal is safe, and both commit — because
they update **different rows** (`account_id = 1` vs. `account_id = 2`),
neither one's `UPDATE` conflicts with or blocks the other. The combined
balance ends at `-40000`, violating an invariant that was never visibly
violated from either transaction's own point of view. This is **write
skew**: each transaction's individual write is consistent with what *it*
read, but the two together violate a constraint that spans both rows.

**Why it works (i.e., why REPEATABLE READ allows it):**
PostgreSQL's `REPEATABLE READ` is **snapshot isolation** — every statement
in the transaction sees one fixed, consistent snapshot taken at the
transaction's start, and it prevents dirty reads, non-repeatable reads, and
phantoms *for a single row or row-set being both read and written by the
same transaction*. It only aborts a transaction (`ERROR: could not
serialize access due to concurrent update`) when two transactions'
snapshots disagree about the *same row's* current value at commit time.
Write skew involves each transaction writing a *different* row based on a
shared read, which snapshot isolation's row-level conflict check simply
never examines.

**Alternative approaches:**
`SERIALIZABLE` (PostgreSQL implements true serializability via **SSI —
Serializable Snapshot Isolation**, predicate-lock tracking of the *read
patterns*, not just written rows) detects this exact anomaly and aborts one
of the two transactions with a serialization failure, forcing a retry. The
alternative that doesn't require `SERIALIZABLE` at all is to make the
invariant explicit at the row/constraint level — e.g., `SELECT ... FOR
UPDATE` on both accounts before computing the combined total (turns the
read into a write-intent lock, so the second transaction blocks instead of
proceeding on stale information), or restructure the schema so the
invariant is a single-row `CHECK` (a `customer_balance_total` column
maintained transactionally) rather than a cross-row aggregate.

**Performance considerations:**
`SERIALIZABLE` is not free — SSI's predicate-lock bookkeeping adds
overhead, and, more importantly, it means the *application* must be
written to retry on serialization failure (`SQLSTATE 40001`), which is a
real code-complexity cost many teams underestimate. `SELECT ... FOR UPDATE`
is cheaper per-transaction but only works if every code path that reads the
invariant remembers to lock; `SERIALIZABLE` protects every code path
automatically, which is exactly why it exists.

> **Common mistakes:**
> - Assuming `REPEATABLE READ` in PostgreSQL is "safe from all concurrency
>   anomalies" because the name sounds strict — it prevents the anomalies
>   the SQL standard names after it, but write skew is a standard, textbook
>   anomaly it explicitly does *not* prevent.
> - Reaching for `SERIALIZABLE` everywhere as a blanket fix without adding
>   retry logic for serialization failures — a `SERIALIZABLE` transaction
>   that isn't retried on `40001` just replaces silent data corruption with
>   a user-facing error, which is better but still not a complete fix.

---

### Q7. What, mechanically, is the difference between PostgreSQL's snapshot-isolation `REPEATABLE READ` and the SQL-standard definition of `REPEATABLE READ`, and how does `SERIALIZABLE` close the gap?

**Answer:**
The SQL standard defines isolation levels purely by which **anomalies**
they must prevent (dirty read, non-repeatable read, phantom read) —
it says nothing about the mechanism. Many databases implement standard
`REPEATABLE READ` with **row-level locking**: every row read is locked
(shared) until the transaction ends, which prevents phantoms as a side
effect of preventing new rows from being insertable into the locked range
in some engines, though the standard technically still permits phantoms at
this level. PostgreSQL instead implements `REPEATABLE READ` as **snapshot
isolation**: no read locks are taken at all; consistency comes from
everyone reading a fixed, private snapshot. The practical, testable
consequence: PostgreSQL's `REPEATABLE READ` prevents phantom reads too (a
strictly *stronger* guarantee than the SQL standard requires at that
level), but — as Q6 shows — it does not prevent write skew, an anomaly
that lock-based `REPEATABLE READ` implementations in some other engines
can happen to prevent as an accidental side effect of their locking
strategy, even though the standard doesn't require them to.

**Why it works:**
Snapshot isolation and true serializability are both about consistency,
but they answer different questions. Snapshot isolation guarantees "every
statement sees a single consistent point in time." Serializability
guarantees "the outcome is equivalent to *some* serial (one-at-a-time)
ordering of the transactions" — a strictly stronger property that snapshot
isolation does not provide, precisely because write skew is a case where
no serial ordering of A-then-B or B-then-A produces the actual (broken)
outcome that ran.

**Alternative approaches:**
Two-phase locking (2PL) is the classical mechanism for achieving true
serializability without snapshots — acquire all locks before releasing any,
guaranteeing a valid serial order exists. PostgreSQL's `SERIALIZABLE`
instead uses **SSI**: run everything under ordinary MVCC snapshot
isolation (no extra blocking for ordinary reads), but track read/write
*dependencies* between concurrent transactions, and abort one transaction
if the tracked pattern proves no serial order could have produced this
outcome. This gets serializability's guarantee with much of snapshot
isolation's concurrency, at the cost of occasional false-positive aborts
(SSI can abort a transaction that, it turns out, wasn't actually part of a
genuine cycle, because it tracks a conservative approximation).

**Performance considerations:**
`SERIALIZABLE` throughput degrades under heavy contention on the same
data because of overlapping predicate tracking (more concurrent
transactions touching related rows means the dependency graph SSI tracks
gets more expensive to maintain and more likely to force an abort) — it is
usually applied selectively, to the specific transactions where the
invariant genuinely spans rows (Q6's example), not blanket-applied to an
entire application.

> **Common mistakes:**
> - Treating "REPEATABLE READ" as a single, portable guarantee across
>   database engines — the *name* is standardized, the *mechanism and exact
>   anomaly coverage* are not, and code that's "safe" under one engine's
>   `REPEATABLE READ` can be unsafe under another's.
> - Assuming `SERIALIZABLE` means "transactions run one at a time" — they
>   still run fully concurrently; `SERIALIZABLE` only guarantees the
>   *result* is equivalent to some serial order, aborting whichever
>   transaction would break that guarantee.

---

### Q8. `VACUUM`, `autovacuum`, and `VACUUM FULL` all "clean up" a table — what does each actually do at the page level, and when (rarely) is `VACUUM FULL` the right call in production?

**Answer:**
Plain `VACUUM` (whether run manually or by `autovacuum`) scans a table's
pages, marks dead tuples' space as reusable **within the existing pages**,
updates the **visibility map** (marking pages where every tuple is known
visible to everyone, enabling index-only scans) and the **free space map**
(so future inserts can reuse the reclaimed space), and — if a table's
oldest transaction age warrants it — freezes old tuples (Q2). It does
**not** shrink the file on disk; reclaimed space becomes available for
future rows in the same table, not returned to the filesystem. `VACUUM
FULL` instead rewrites the *entire table* into a brand-new, compact file
(no dead tuples, no wasted space) and swaps it in, which does shrink disk
usage — but requires an `ACCESS EXCLUSIVE` lock for the full duration,
blocking all reads and writes to that table.

**Why it works:**
Plain vacuum's design deliberately favors *never blocking concurrent
traffic* over minimizing disk footprint, because in almost every OLTP
workload, "the table stays a bit larger than the absolute minimum" is a
far smaller problem than "the table becomes briefly unavailable." `VACUUM
FULL`'s design is the opposite trade — it prioritizes reclaiming every byte
over availability, which is only acceptable when the table can tolerate
being fully locked.

**Alternative approaches:**
`pg_repack` (an extension, not built into core) achieves the same physical
compaction as `VACUUM FULL` without a long exclusive lock — it builds a new
copy of the table in the background using triggers to capture concurrent
changes, then does a brief exclusive-lock swap at the very end. This is the
standard production answer to "the table is badly bloated and we need the
space back without an outage," and is almost always preferred over
`VACUUM FULL` on a live table.

**Performance considerations:**
`VACUUM FULL` is appropriate essentially only for: a table nobody is
actively querying (an offline maintenance window, or a decommissioned/rarely-
touched table), or a genuinely tiny table where the exclusive lock's
duration is negligible. On a large, actively-used table, reaching for
`VACUUM FULL` to fix bloat is a common way to turn a performance problem
into an availability incident.

```sql
-- [PostgreSQL] estimate bloat before deciding whether it's even worth compacting
SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
       n_dead_tup, n_live_tup
FROM pg_stat_user_tables JOIN pg_class ON pg_class.relname = pg_stat_user_tables.relname
ORDER BY n_dead_tup DESC LIMIT 10;
```

> **Common mistakes:**
> - Running `VACUUM FULL` on a large production table during business
>   hours as a first response to "the table is bloated," without
>   considering `pg_repack` or simply waiting for normal vacuum plus
>   better autovacuum tuning to keep bloat in check going forward.
> - Assuming plain `VACUUM` will shrink `pg_total_relation_size` — it
>   almost never does; a table that grew to 10 GB under heavy churn and
>   then quiets down will typically **stay** at roughly that size under
>   plain vacuum, holding reusable-but-not-returned free space.

---

### Q9. Explain the relationship between `shared_buffers`, the background writer, and checkpoints — specifically, why can a checkpoint still cause an I/O spike even with a background writer running continuously?

**Answer:**
`shared_buffers` is PostgreSQL's own page cache, sitting in front of the
OS page cache — every read and write to a data page goes through a buffer
in `shared_buffers` first. When a backend modifies a page, that buffer is
marked **dirty**; it is not immediately written to disk (that would defeat
the purpose of caching). The **background writer** continuously scans for
dirty buffers that haven't been touched recently and opportunistically
writes them out at a gentle, throttled pace, specifically to keep the
*number* of dirty buffers from building up to a dangerous level. A
**checkpoint**, however, has a stricter job: guarantee that *every* buffer
dirty as of the checkpoint's start is flushed to disk by the time the
checkpoint completes — the background writer's opportunistic trickle
doesn't have that deadline, so a checkpoint can still find a large backlog
of dirty pages it must force out within its completion window
(`checkpoint_completion_target` spreads this out but doesn't eliminate it),
producing a real I/O burst relative to the quiet background-writer baseline.

**Why it works:**
The background writer and checkpointer solve different problems: the
background writer optimizes for "keep buffer eviction cheap for backends
that need a free buffer for a new page" (avoiding a backend having to
synchronously write out a dirty victim buffer itself); the checkpointer
exists purely to bound crash-recovery time (Q5) by guaranteeing a known
"everything before this WAL position is on disk" point.

**Alternative approaches:**
Increasing checkpoint frequency (lower `max_wal_size`/`checkpoint_timeout`)
reduces the size of each spike at the cost of more frequent, smaller ones
and more total WAL overhead from repeated `full_page_writes`; decreasing
frequency does the reverse. There's no way to eliminate the trade-off
entirely — only to tune where you sit on it, and to smooth each individual
checkpoint's I/O curve via `checkpoint_completion_target`.

**Performance considerations:**
Monitor `pg_stat_bgwriter` (`buffers_checkpoint` vs. `buffers_clean` vs.
`buffers_backend`) — a high `buffers_backend` count means backends are
frequently being forced to write out dirty pages themselves to get a free
buffer (worse for latency than either the background writer or checkpointer
doing it), usually indicating `shared_buffers` is undersized or the
background writer isn't keeping up with the write rate.

> **Common mistakes:**
> - Assuming a bigger `shared_buffers` always helps — beyond a certain
>   point (commonly cited around 25–40% of system RAM) the OS page cache
>   underneath it is doing useful double-duty work, and an oversized
>   `shared_buffers` can starve the OS cache without a proportional benefit.
> - Diagnosing a checkpoint I/O spike as "a query got slow" without
>   checking `pg_stat_bgwriter`/checkpoint logs first — see Q51.

---

### Q10. What is TOAST, when does it activate, and how does it change the I/O cost of a query that never even references the large column?

**Answer:**
**TOAST** (The Oversized-Attribute Storage Technique) is PostgreSQL's
mechanism for storing values too large to fit comfortably in a normal 8KB
heap page — a long `TEXT`, a large `JSONB` document, a sizeable `BYTEA`.
Depending on the column's storage strategy, a large value is compressed
in place, or moved entirely out of the main heap into a separate,
paired **TOAST table**, leaving only a small pointer in the row's main
tuple. `ecommerce_db.reviews.review_text` (`TEXT`) is a candidate for this
the moment any review is long enough to exceed roughly 2KB (PostgreSQL
targets keeping at least 4 tuples per page, so any single column value
much bigger than ~2KB triggers TOASTing to keep rows page-sized).

**Why it works:**
Keeping the main heap's rows small and uniform-ish matters because the
planner and executor constantly scan/copy tuples in bulk — a table where a
handful of rows carry a 500KB `JSONB` blob inline would bloat *every*
sequential scan of that table, even for queries that only need small
columns like `product_id` and `rating`. By moving the oversized value out
to a side table (only fetched when actually needed), a `SELECT product_id,
rating FROM reviews` never has to read the large `review_text` bytes off
disk at all — the query only pays TOAST's cost when a query's `SELECT`
list or `WHERE` clause actually touches the toasted column.

**Alternative approaches:**
`ALTER TABLE ... ALTER COLUMN col SET STORAGE {PLAIN | EXTENDED | EXTERNAL
| MAIN}` controls compression/out-of-line behavior per column — e.g.,
`EXTERNAL` disables compression but keeps out-of-line storage, useful for
already-compressed binary blobs (compressing them again wastes CPU for no
size benefit); `PLAIN` disables TOASTing entirely and is appropriate only
for columns guaranteed to stay small.

**Performance considerations:**
A query that filters or sorts on a large `TEXT`/`JSONB` column forces
TOAST detoasting for every matching row, which is a real, often
underestimated I/O and CPU cost — this is exactly why full-text search
(Chapter 25) builds a separate `tsvector` column/index rather than scanning
raw `TEXT` directly, and why `JSONB` queries benefit heavily from a `GIN`
index rather than relying on sequential detoasting.

> **Common mistakes:**
> - Assuming `SELECT *` and `SELECT <small_columns>` cost the same on a
>   table with a large TOASTed column — they don't; `SELECT *` forces
>   detoasting for every row, `SELECT <small_columns>` doesn't touch the
>   TOAST table at all.
> - Storing large binary blobs (images, files) directly in a `BYTEA`
>   column "because Postgres can handle it" without considering that this
>   forces every backup, replication stream, and `VACUUM` pass to also
>   carry that weight — a pointer to object storage (S3, etc.) is very
>   often the better design once blobs get large or numerous.

## B. Security & Access Control (Chapter 27)

Chapter 27 builds a concrete role model against these databases —
`app_service_role`, `reporting_role`, `hr_full_access_role`, and
`customer_role` (used for row-level security on `banking_db.accounts`).
These questions build on that foundation rather than repeating it: full
production role graphs, RLS performance and bypass vectors, multi-tenant
patterns, and SQL injection at the mechanism level rather than the
"remember to escape quotes" level.

### Q11. Design the complete production role graph for `banking_db` — not just "an app role and a reporting role," but every role a real deployment needs, including the ones nobody thinks of until an audit asks for them.

**Answer:**
Extending Chapter 27's `app_service_role`/`reporting_role` pair into a full
graph:

```sql
-- Tier 1: pure privilege bundles (NOLOGIN) — never connected to directly
CREATE ROLE app_service_role   NOLOGIN;  -- runtime app: DML only, no DDL
CREATE ROLE reporting_role     NOLOGIN;  -- read-only, all tables
CREATE ROLE migration_role     NOLOGIN;  -- DDL rights, used only by CI/CD
CREATE ROLE customer_role      NOLOGIN;  -- RLS-scoped end-customer access
CREATE ROLE audit_reader_role  NOLOGIN;  -- SELECT-only on audit_log, nothing else
CREATE ROLE breakglass_role    NOLOGIN;  -- emergency full access, tightly gated

GRANT USAGE ON SCHEMA banking_db TO app_service_role, reporting_role,
      migration_role, customer_role, audit_reader_role, breakglass_role;

GRANT SELECT, INSERT, UPDATE ON banking_db.accounts, banking_db.transactions
  TO app_service_role;                              -- no DELETE: money movements are never deleted
GRANT SELECT ON ALL TABLES IN SCHEMA banking_db TO reporting_role;
GRANT SELECT ON banking_db.audit_log TO audit_reader_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking_db TO migration_role; -- plus CREATE on the schema
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking_db TO breakglass_role;

-- Tier 2: actual login roles, each a MEMBER of exactly the bundle(s) it needs
CREATE ROLE svc_banking_api LOGIN PASSWORD '...' ;  GRANT app_service_role  TO svc_banking_api;
CREATE ROLE ci_migrator     LOGIN PASSWORD '...' ;  GRANT migration_role    TO ci_migrator;
CREATE ROLE analyst_priya   LOGIN PASSWORD '...' ;  GRANT reporting_role    TO analyst_priya;
CREATE ROLE auditor_external LOGIN PASSWORD '...';  GRANT audit_reader_role TO auditor_external;
-- breakglass_role is granted to a *personal* on-call account only at incident time,
-- via a time-boxed GRANT ... VALID UNTIL, then revoked — never a standing membership.
```

**Why it works:**
The design separates **privilege bundles** (what a job function needs,
defined once) from **login identities** (who/what connects), exactly as
Chapter 27 §27.3 establishes — but a real audit checklist adds three
bundles most textbook examples skip: a **migration role** so the account
running `CREATE TABLE`/`ALTER TABLE` in CI/CD is never the same credential
the running application uses day-to-day (least privilege: the app never
needs `CREATE`); an **audit-reader role** scoped to *only* `audit_log`, so
a compliance auditor can be granted access without also seeing live
customer balances; and a **breakglass role** that exists but is normally
granted to *nobody* — it's activated deliberately, time-boxed, and its use
is itself logged, precisely because "the DBA just uses their personal
superuser account during an incident" is how untracked, unaudited access
creeps into a system.

**Alternative approaches:**
Some organizations skip a separate `migration_role` and instead run
migrations as the schema *owner* directly (since object owners bypass RLS
and hold implicit `ALL` rights on what they own) — this is simpler to set
up but conflates "owns the schema" with "runs the pipeline," making it
harder to rotate/scope CI credentials independently of who created the
tables in the first place; a dedicated `migration_role` with explicit
grants (rather than ownership) is more auditable at a small operational
cost.

**Performance considerations:**
Role graphs have no runtime performance cost themselves (privilege checks
are cheap catalog lookups), but a large graph with many overlapping
memberships can become slow to *administer* — `pg_catalog` introspection
queries (`\du+`, `information_schema.role_table_grants`) become essential
for actually answering "what can `analyst_priya` do" as the graph grows,
rather than tracing `GRANT` statements by hand.

> **Common mistakes:**
> - Granting `reporting_role` (or any broad read role) `SELECT` on
>   `banking_db.customers` and `banking_db.accounts` without a second
>   thought — a "read-only" role that can see raw PII/balances is not
>   automatically a *safe* role; least privilege applies to `SELECT` just
>   as much as to `INSERT`/`UPDATE`/`DELETE`. Column-level grants or masked
>   views are often the right answer for reporting roles touching PII.
> - Letting `migration_role`'s credential live in the same secrets store
>   with the same rotation cadence as `app_service_role`'s — a DDL-capable
>   credential compromised is a far worse incident than a DML-only one, and
>   deserves tighter rotation and access logging.

---

### Q12. A `CREATE POLICY` predicate that "looks fine" is causing every query against a 50-million-row table to run a full sequential scan. What's happening, and how do you fix it?

**Answer:**
RLS policies are implemented by the planner **appending the policy's
`USING` expression to the query's `WHERE` clause** (conceptually — the
actual mechanism folds it into the query tree before planning), and then
planning the *combined* predicate normally. If the policy predicate can't
be satisfied by an index the way the application's own filter can, the
combined predicate as a whole may no longer be sargable, and the planner
falls back to a sequential scan even though the application's own `WHERE
account_id = $1` looks perfectly indexable in isolation. The classic
culprit: a policy like

```sql
CREATE POLICY customer_select_own_accounts
    ON banking_db.accounts FOR SELECT TO customer_role
    USING (customer_id = current_setting('app.current_customer_id')::int);
```

is fine on its own (equality on an indexed `customer_id`), but a policy
written instead as `USING (customer_id::text = current_setting(
'app.current_customer_id'))` (a type cast wrapping the *column*, not the
setting) defeats a plain B-tree index on `customer_id`, because the index
is built on the `int` values, not on a per-row computed `text` cast —
every row must be fetched and cast before the comparison can even be
attempted.

**Why it works (the fix):**
Keep the policy predicate in the same form and type as the indexed column
— cast the *session setting* (evaluated once per query) rather than the
*column* (evaluated once per row): `customer_id = current_setting(...)::int`.
This is a plain sargable equality the planner can push into an index scan
exactly as if the application had written that `WHERE` clause itself.

**Alternative approaches:**
For policies with more complex predicates (a join to a `tenant_users`
membership table rather than a simple session-variable comparison), ensure
the referenced columns are indexed on *both* sides of the implicit join the
policy introduces, and check `EXPLAIN (ANALYZE, COSTS)` with `SET ROLE
customer_role` active — the plan you see as a superuser querying the table
directly does **not** reflect what a role actually bound by the policy
experiences, because RLS is simply not applied to a role that owns the
table or bypasses RLS (Q13).

**Performance considerations:**
Multiple policies on the same table for the same command are combined with
`OR` by default (any matching policy grants access) unless declared
`AS RESTRICTIVE` (combined with `AND`) — a table with several permissive
policies stacked over time can end up with a combined predicate far more
expensive than any single policy's author intended; periodically auditing
`pg_policies` for a given table is worthwhile as policies accumulate.

```sql
-- [PostgreSQL] see every policy applied to a table
SELECT policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies WHERE schemaname = 'banking_db' AND tablename = 'accounts';
```

> **Common mistakes:**
> - Testing RLS performance while connected as the table owner or a
>   superuser — RLS (by default) doesn't even apply to them, so the
>   `EXPLAIN` plan you're looking at is not the plan the actual restricted
>   role will get.
> - Writing a policy predicate that references a *function call* per row
>   (e.g., a `SECURITY DEFINER` lookup function) without that function
>   being cheap and/or the underlying data indexed — a policy is
>   effectively evaluated per candidate row, so an expensive predicate here
>   is an expensive predicate on every single row scan.

---

### Q13. Name every way row-level security can be silently bypassed in PostgreSQL, and how you'd audit a database to make sure none of them are happening by accident.

**Answer:**
Four distinct bypass paths, all legitimate features that become security
holes if forgotten about:

1. **Superusers** bypass RLS (and every ACL check) unconditionally, on
   every table, always — `CREATE POLICY` is simply irrelevant to a
   superuser connection.
2. **Table owners** bypass RLS by default, *even without superuser* —
   unless the table has `FORCE ROW LEVEL SECURITY` set, the owner's own
   queries skip every policy on their own table.
3. Roles with the `BYPASSRLS` attribute (`ALTER ROLE x BYPASSRLS`) skip
   RLS on every table, regardless of ownership — a role attribute that's
   easy to grant during debugging and easy to forget to revoke.
4. A `SECURITY DEFINER` function owned by a role that bypasses RLS (points
   1–3) executes with *that owner's* privileges for the duration of the
   function call — a seemingly innocent helper function can become a
   full RLS bypass if it's owned by a superuser or an owner role and
   doesn't itself re-check the calling context.

**Why it works (why the design is this way):**
RLS is meant to constrain *application-level* roles reading data through
normal application privilege, not to be an unconditional, unbypassable
kernel-level guarantee — the object owner and superuser retain
administrative access by design, because otherwise routine administrative
tasks (schema migrations, backups, support debugging) would be blocked by
the very policies meant to protect end-user data from *other end users*.

**Alternative approaches:**
For a table where you genuinely want RLS enforced even against the owner
(e.g., a shared multi-tenant table administered by a role that should still
be tenant-scoped for its own queries), `ALTER TABLE ... FORCE ROW LEVEL
SECURITY` closes bypass path #2 specifically — but does nothing about
superuser or `BYPASSRLS` bypasses, which are the more dangerous ones in
practice because they're invisible in `pg_policies` entirely.

**Performance considerations:**
None of these bypasses have a performance dimension — this is purely an
audit/security-hygiene concern, but it's one that's easy to get
operationally wrong: a role created with `BYPASSRLS` "temporarily, to debug
a policy issue" and never revoked is a realistic, common finding in
security reviews.

```sql
-- [PostgreSQL] audit query: every role that can bypass RLS somewhere
SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolsuper OR rolbypassrls;

-- every table where FORCE ROW LEVEL SECURITY is NOT set (owner bypass still possible)
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class WHERE relrowsecurity AND NOT relforcerowsecurity;
```

> **Common mistakes:**
> - Assuming "RLS is enabled on this table" means it's enforced for
>   *everyone* — it's enforced only for roles that (a) aren't superusers,
>   (b) don't have `BYPASSRLS`, and (c) either aren't the owner or the
>   table has `FORCE ROW LEVEL SECURITY`.
> - Writing a `SECURITY DEFINER` convenience function ("just returns
>   account balance") owned by a privileged role, without adding the same
>   tenant/customer check inside the function body that RLS would have
>   provided — the function itself becomes an unguarded side door.

---

### Q14. Design a multi-tenant RLS scheme for a SaaS product where every table carries a `tenant_id`, and explain why this breaks under a naive PgBouncer transaction-pooling setup.

**Answer:**

```sql
ALTER TABLE saas.invoices ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON saas.invoices
    USING (tenant_id = current_setting('app.tenant_id', true)::int);

-- The application, per request:
SET LOCAL app.tenant_id = '4821';
SELECT * FROM saas.invoices;   -- policy transparently scopes this
```

`SET LOCAL` scopes the setting to the current **transaction** — it resets
automatically at `COMMIT`/`ROLLBACK`, which matters enormously in a pooled
environment. The break: under **PgBouncer in transaction pooling mode**
(the mode almost everyone uses for high-connection-count web apps), a
*physical* server connection is only bound to a client for the duration of
one transaction — it's returned to the pool and can be handed to a
*completely different client* immediately after `COMMIT`. If tenant scoping
used `SET` (session-scoped, not `SET LOCAL`/transaction-scoped) instead,
the setting would persist on that physical connection into the next
transaction, potentially exposing tenant A's `app.tenant_id` setting to
tenant B's next request on the same reused connection — a catastrophic
cross-tenant data leak, and one that would work fine in every test that
happens to run single-connection.

**Why it works:**
`SET LOCAL` ties the setting's lifetime to the *transaction*, which is
exactly the unit of work PgBouncer's transaction-pooling mode preserves —
a transaction is never split across two different physical connections
mid-flight, so a `SET LOCAL` made at the top of the transaction is
guaranteed still in effect for every statement inside it, and guaranteed
gone before the connection can be reused for anyone else's transaction.

**Alternative approaches:**
An alternative that avoids session-variable RLS entirely: give every
tenant a genuinely separate PostgreSQL **role**, and scope policies to
`current_user` directly (`USING (tenant_id = current_tenant_id_for(
current_user))`) — this sidesteps the `SET`/`SET LOCAL` pooling hazard
completely, at the cost of needing one role per tenant (fine for hundreds
of tenants, unwieldy for hundreds of thousands) and losing the simplicity
of a single, shared `app_service_role` connection pool. A third option,
common at very large multi-tenant scale, skips RLS altogether and relies
on the application layer plus **schema-per-tenant** or **database-per-
tenant** physical isolation — stronger isolation guarantees, much higher
operational overhead (migrations must run N times).

**Performance considerations:**
`current_setting()` evaluated per row (rather than once per query, though
PostgreSQL's planner typically treats it as a stable expression evaluated
once) and the underlying `tenant_id` equality both need `tenant_id` to be
the *leading* column of relevant indexes in a multi-tenant schema — every
index effectively becomes `(tenant_id, ...)` if RLS-scoped queries are to
stay index-friendly at any scale.

> **Common mistakes:**
> - Using `SET` instead of `SET LOCAL` for any per-request/per-tenant
>   session variable when the application sits behind PgBouncer (or any
>   connection pooler) in transaction-pooling mode — this is one of the
>   most dangerous, easy-to-miss multi-tenant RLS bugs in production
>   PostgreSQL systems.
> - Forgetting to set a **default-deny fallback** for `current_setting(
>   'app.tenant_id', true)` (the `true` second argument makes it return
>   `NULL` instead of erroring if unset) — if a code path forgets to set
>   the tenant context at all, `tenant_id = NULL` is never true, so the
>   policy correctly returns zero rows rather than leaking data, but only
>   if the predicate is written to rely on that `NULL`-never-matches
>   behavior rather than, e.g., defaulting to a permissive value.

---

### Q15. Explain, at the parser/protocol level, exactly why a parameterized query prevents SQL injection — not "it escapes quotes," the actual mechanism.

**Answer:**
A parameterized query (e.g., using `$1` placeholders via the extended
query protocol, or an ORM's bind-parameter API) is sent to PostgreSQL as
**two separate messages**: a `Parse` message containing the SQL text with
placeholders (`SELECT * FROM company_db.employees WHERE job_title = $1`),
and a `Bind` message containing the actual parameter *values*, sent as
typed data, entirely separate from the SQL text. The server **parses and
plans the query once**, using only the placeholder positions and their
declared types — the parameter values are never lexed, tokenized, or
parsed as SQL syntax at all; they're substituted as literal *data* into an
already-fixed execution plan at bind time. Contrast the vulnerable
string-concatenation version: `"SELECT * FROM employees WHERE job_title = '"
+ userInput + "'"` — here the "parameter" is concatenated *before* the SQL
text ever reaches the parser, so if `userInput` is `x' OR '1'='1`, the
parser sees and executes an entirely different, attacker-controlled
statement, because there was never a boundary between "code" and "data" in
the first place.

**Why it works:**
Injection is fundamentally a **confusion between the code channel and the
data channel** — the vulnerable version has exactly one channel (a single
string that's part code, part attacker data, concatenated together and
handed to a parser that can't tell which parts are which). Parameterized
queries maintain two channels (`Parse` message = code, `Bind` message =
data) all the way to the server, so there is no point in the pipeline
where attacker-supplied bytes are ever interpreted as SQL grammar — no
amount of quotes, semicolons, or comment sequences in the parameter value
can change the statement's structure, because the structure was already
fixed by the `Parse` step before the value even arrives.

**Alternative approaches:**
Where parameterization genuinely isn't available (dynamic table/column
names, which — as Q16 covers — can never be bound parameters at all),
PostgreSQL's `format('%I', identifier)` and `quote_ident()`/
`quote_literal()` are the correct escaping primitives for building dynamic
SQL text safely, used inside `EXECUTE` in PL/pgSQL (Chapter 23). These are
a legitimate, narrower alternative for the specific case parameterization
structurally cannot cover — not a general substitute for it.

**Performance considerations:**
Parameterized queries carry a genuine performance benefit beyond security:
the same `Parse`d query plan can be reused across executions with
different parameter values (a **prepared statement**), avoiding
re-parsing and, if the planner is told to, re-planning identical query
shapes repeatedly — though PostgreSQL's `generic vs. custom plan` heuristic
means a plan optimized for one parameter value's selectivity isn't always
optimal for another, a real and separate trade-off from the security one.

> **Common mistakes:**
> - Believing "we use an ORM, so we're safe from injection" — an ORM that
>   still exposes a raw-SQL/raw-`WHERE`-fragment escape hatch (most do) is
>   only as safe as every call site that avoids using it with untrusted
>   input.
> - Thinking input *validation* (e.g., regex-checking that a string
>   "looks like a name") is a substitute for parameterization — validation
>   can reduce the attack surface but is not the actual mechanism that
>   prevents injection, and is far easier to get subtly wrong than "never
>   concatenate untrusted input into SQL text" is to get right.

---

### Q16. What kind of SQL injection can happen *even with fully parameterized query values*, and how do you defend against it?

**Answer:**
Parameters can only ever stand in for **literal values** — never for
identifiers (table names, column names, schema names) or SQL keywords
(`ASC`/`DESC`, an operator). A common real pattern: a reporting endpoint
lets the caller choose which column to sort `ecommerce_db.orders` by, and
the backend builds `ORDER BY <column>` dynamically:

```sql
-- VULNERABLE even though it "uses parameters" for everything else
EXECUTE format('SELECT * FROM ecommerce_db.orders ORDER BY %s', sort_column);
```

If `sort_column` is naively concatenated (not passed through `format('%I',
...)`, PostgreSQL's identifier-quoting format specifier), an attacker who
controls `sort_column` can supply `order_id; DROP TABLE orders; --` or,
more realistically in a web context, a subquery/expression that exfiltrates
data the endpoint was never meant to expose. This is injection through the
**identifier/structure** channel, which parameterization never covers at
all, because the wire protocol has no concept of a "bound parameter" for
"which column" — only for "what value."

**Why it works (the defense):**
`format('%I', sort_column)` (or `quote_ident()`) — the `%I` specifier
double-quotes the identifier and escapes any embedded double-quotes,
guaranteeing the result can only ever be parsed as a single identifier
token, never as multiple statements or extra SQL grammar, regardless of
what bytes `sort_column` contains. Critically, this must be paired with an
**allowlist** check (`sort_column IN ('order_date', 'status', 'user_id')`)
before even reaching `format()` — `%I` guarantees the *syntax* is safe (no
injection), but doesn't guarantee the *semantics* are appropriate (an
attacker who can't inject SQL syntax can still ask you to sort by, say, a
column that leaks something unintended, or force an expensive sort on an
unindexed column as a denial-of-service vector).

**Alternative approaches:**
The safer default, avoided only when genuinely necessary, is to not accept
free-form column names from the client at all — expose a small fixed set
of named "sort modes" (`?sort=newest`, `?sort=price_desc`) that the backend
maps to a hardcoded `ORDER BY` clause server-side, eliminating the dynamic-
identifier problem entirely rather than defending against it.

**Performance considerations:**
Dynamic SQL built via `EXECUTE format(...)` inside PL/pgSQL bypasses plan
caching for that statement shape entirely (Chapter 20/23) — each distinct
generated SQL text is planned fresh — which is a real cost on a
high-traffic endpoint even once the injection risk is handled correctly.

> **Common mistakes:**
> - Believing "I used `format()` so it's safe" without checking whether
>   `%I`/`%L` were actually used for the identifier/literal positions
>   respectively — `format('%s', sort_column)` (plain string substitution,
>   the `%s` specifier) provides **no** protection at all; it's exactly as
>   vulnerable as raw concatenation.
> - Allowlisting column *names* but forgetting that sort *direction*
>   (`ASC`/`DESC`) is exactly the same class of problem if it's also taken
>   from user input and concatenated rather than mapped through a small
>   fixed set of accepted values.

---

### Q17. A compliance requirement says customer PII in `banking_db.customers` must be encrypted "at rest." Design the actual encryption strategy — and explain what full-disk/TDE-style encryption alone does *not* protect against.

**Answer:**
A layered strategy, because "encrypted at rest" means different things at
different layers and no single layer covers every threat:

1. **Storage-level (disk/volume) encryption** — cloud-provider disk
   encryption or PostgreSQL TDE-equivalent (native transparent data
   encryption isn't built into core PostgreSQL; it's provided by some
   forks/extensions or handled at the filesystem/cloud-volume layer).
   Protects against: a stolen physical disk, an improperly decommissioned
   backup tape, someone reading raw files off a snapshot without
   credentials. Does **not** protect against: anyone with valid database
   credentials (including an attacker who compromised the app's DB
   credentials, or a malicious insider with `SELECT` access) — to a live,
   running, authenticated connection, disk encryption is completely
   transparent; the data comes back in plaintext.
2. **Column-level encryption (`pgcrypto`)** for the most sensitive fields
   specifically — e.g., encrypting `customers.dob` or a hypothetical SSN
   column with `pgp_sym_encrypt()`, keyed by an application-managed key
   never stored in the database itself:

```sql
-- [PostgreSQL, pgcrypto extension]
UPDATE banking_db.customers
SET dob = pgp_sym_encrypt(dob::text, :encryption_key)::text
WHERE customer_id = 1;
```

   This protects against exactly the case disk encryption doesn't: someone
   with `SELECT` on the table (a compromised app credential, an over-broad
   `reporting_role` grant, a raw `pg_dump` of the table) still only sees
   ciphertext without the key, which is held and rotated *outside* the
   database.
3. **In transit** — `sslmode=require` (or stricter, `verify-full`) on
   every client connection, non-negotiable for any connection carrying PII
   over a network that isn't provably fully private.

**Why it works:**
Each layer defends against a *different* attacker position: disk
encryption defends against physical/media theft; column-level encryption
defends against a compromised or over-privileged *application-level*
credential; TLS defends against network interception. Compliance
frameworks that say "encrypt PII at rest" are usually satisfied by layer 1
alone on paper, but layer 1 alone leaves the single most likely real-world
breach vector (a compromised application credential or an over-broad
internal `SELECT` grant) completely unprotected.

**Alternative approaches:**
**Application-level encryption** (encrypt before the value ever reaches
the database, decrypt only in the application) gives the strongest
guarantee — the database never sees plaintext at all, even a full
superuser compromise can't read it without the app's key — at the cost of
losing the ability to index, sort, or query on that column at the database
level entirely (you can look up by an encrypted value's exact ciphertext
match at best, never a range or `LIKE` query).

**Performance considerations:**
Column-level (`pgcrypto`) encryption/decryption is CPU work performed
per-row, per-access — a `WHERE dob = ...` predicate on an encrypted column
cannot use a normal B-tree index at all (the stored bytes are ciphertext,
unrelated in sort order to the plaintext), forcing a sequential scan plus
per-row decryption for any such lookup; encrypted columns should be
reserved for fields that are *read whole*, not filtered/sorted on, or
require a separate deterministic-hash lookup column alongside the
encrypted value for equality lookups.

> **Common mistakes:**
> - Treating "the cloud provider encrypts the disk" as satisfying a PII
>   protection requirement on its own — it satisfies a *media theft*
>   threat model, not a *credential compromise* threat model, which is the
>   far more common real-world breach.
> - Storing the `pgcrypto` decryption key in the same database (a config
>   table, an environment variable readable by the same process that has
>   `SELECT` on the encrypted column) — this makes column-level encryption
>   almost entirely theatrical, since anything that can read the encrypted
>   column can also read the key sitting next to it.

---

### Q18. Design least-privilege access for the CI/CD pipeline that runs schema migrations against `ecommerce_db` — what goes wrong with "just use the same admin credential the DBA uses"?

**Answer:**
A dedicated, narrowly-scoped migration identity, separate from every human
and every runtime credential:

```sql
CREATE ROLE migration_role NOLOGIN;
GRANT CREATE, USAGE ON SCHEMA ecommerce_db TO migration_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ecommerce_db TO migration_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA ecommerce_db GRANT ALL ON TABLES TO migration_role;

CREATE ROLE ci_pipeline_ecommerce LOGIN PASSWORD :'rotated_secret' VALID UNTIL '2026-12-31';
GRANT migration_role TO ci_pipeline_ecommerce;
-- Connection limited to the CI network range at the pg_hba.conf / cloud firewall layer,
-- never reachable from application servers or developer laptops.
```

The failure mode of "just use the DBA's admin credential in CI": that
credential is now (a) stored in a secrets manager accessible to every
pipeline job and every engineer who can trigger a build, wildly expanding
its exposure surface versus a human typing a password interactively; (b)
shared across *every* purpose the DBA account is used for, so rotating it
after a leak means coordinating downtime across everything that account
touches, not just CI; and (c) indistinguishable in `audit_log`/connection
logs from genuine interactive DBA activity, destroying the audit trail's
ability to answer "was this schema change made by the pipeline or by a
person at a terminal."

**Why it works:**
A scoped `migration_role`, bound to a CI-only login identity with its own
rotation schedule and its own audit trail (`current_user` in every
DDL-triggering session is unambiguously the pipeline, never a person), is
what makes "who/what changed this schema and when" answerable after the
fact — the entire point of least privilege for automation is not just
limiting blast radius, but preserving *attribution*.

**Alternative approaches:**
Some teams go further and require migrations to be applied via a
**short-lived, dynamically issued credential** (e.g., HashiCorp Vault's
PostgreSQL secrets engine, which creates a temporary role with a TTL for
each pipeline run and drops it afterward) rather than a long-lived
`ci_pipeline_ecommerce` login at all — this eliminates the "stored secret
that could leak and remain valid for months" risk entirely, at the cost of
needing that secrets infrastructure to exist and be reliable (a Vault
outage now blocks deployments).

**Performance considerations:**
None directly — this is a security/operational-hygiene question, though a
short-lived-credential approach adds a small amount of pipeline latency
(issuing and later revoking the temporary role) that's normally negligible
next to the migration itself.

> **Common mistakes:**
> - Granting the CI role broad privileges "to avoid migration failures
>   from missing grants" instead of granting exactly what schema changes
>   require — `CREATE`/`ALTER`/`DROP` on the target schema's objects, not
>   blanket superuser.
> - Never rotating the CI credential because "it's not a human password, so
>   it doesn't expire like one" — machine credentials leak too (committed
>   to a repo by accident, exposed in a misconfigured log), and deserve the
>   same rotation discipline as human ones, arguably more given how widely
>   accessible CI secrets stores tend to be.

## C. Backup, Recovery & Disaster Recovery (Chapter 28)

Chapter 28 covers `pg_dump` vs. `pg_basebackup`, the logical-vs-physical
decision framework, and PITR mechanics. These questions push into the part
of the job that's actually hard: turning RPO/RTO numbers into a concrete
strategy, proving a backup is actually restorable, and making the right
call under real incident pressure with imperfect backups.

### Q19. A stakeholder says "our RPO for `banking_db` must be under 5 minutes and RTO under 30 minutes." Translate those numbers into an actual backup architecture, and show why a nightly `pg_dump` alone cannot meet them.

**Answer:**
**RPO (Recovery Point Objective)** — how much data you can afford to lose,
measured as time — is satisfied by how *frequently* durable copies of
changes are captured. **RTO (Recovery Time Objective)** — how long you can
afford to be down — is satisfied by how *fast* a full working system can be
reconstructed from those copies. A nightly `pg_dump` gives an RPO of up to
**24 hours** (anything written since last night's dump is gone if the
primary is lost) and an RTO that scales with database size (a full logical
restore replays every `INSERT` and rebuilds every index from scratch — slow
for anything beyond a small database) — both numbers are off by more than
an order of magnitude from the stated targets.

The architecture that actually meets a 5-minute RPO / 30-minute RTO:

```
┌─────────────────────────────────────────────────────────────────┐
│  PRIMARY (banking_db)                                            │
│    - continuous WAL archiving to object storage (every WAL       │
│      segment shipped as it fills, or archive_timeout=60s so a    │
│      partially-full segment is still forced out at least every   │
│      60 seconds — this is what bounds RPO)                       │
│    - synchronous or tightly-lagged streaming replica (Chapter 30)│
│      as the fast-failover target for most outages                │
└───────────────────────────┬───────────────────────────────────────┘
                             │ WAL stream
                 ┌───────────▼────────────┐
                 │  STANDBY (hot, streaming)│  <- primary failover target, RTO ~seconds via promotion
                 └────────────────────────┘
        +  daily pg_basebackup (physical) retained 7 days
        +  continuous WAL archive retained 35 days (enables PITR to ANY point, not just backup times)
        +  weekly pg_dump (logical) retained 90 days, for schema-level/table-level recovery
           and as an engine-version-independent long-term artifact
```

**Why it works:**
The streaming replica satisfies the *common* failure case (primary host
dies) with an RTO of seconds to low minutes via promotion (Chapter 30),
comfortably inside the 30-minute target. WAL archiving with a short
`archive_timeout` bounds the *worst-case* RPO for the rarer case where even
the replica is unusable (e.g., a logical data-corruption bug replicated to
the standby too) — PITR can replay a physical base backup plus archived WAL
forward to any point within seconds of the last archived segment, meeting
the 5-minute RPO even in that scenario. The weekly `pg_dump` isn't part of
meeting RPO/RTO at all — it exists for a different failure mode entirely
(recovering one accidentally-dropped table without restoring the whole
cluster, or migrating to a different major version).

**Alternative approaches:**
A tighter RPO target (seconds, not minutes) would require **synchronous
replication** to at least one standby (Chapter 30 §30.5) so no
acknowledged commit can ever be lost even if the primary disappears
instantly — at the direct cost of every commit's latency now including a
round-trip to the standby, a trade-off only justified when the business
truly cannot tolerate the stated RPO.

**Performance considerations:**
`archive_timeout` set aggressively low (e.g., 60s) forces WAL segment
switches even during quiet periods, generating archive traffic (and
storage) even with no real writes — a real, if usually small, cost of a
tight RPO target; balance the setting against actual write volume rather
than defaulting to the tightest possible value everywhere.

> **Common mistakes:**
> - Quoting an RPO/RTO target and then implementing only `pg_dump` because
>   it's the simplest tool covered first in most PostgreSQL tutorials —
>   `pg_dump` alone structurally cannot meet a sub-hour RPO or a fast RTO
>   on anything but a small database.
> - Confusing "we have a standby replica" with "we have a backup" — a
>   replica protects against hardware failure, not against a bad
>   `DELETE`/`DROP TABLE`/logical corruption, which streams to the replica
>   just as faithfully as any legitimate write. PITR/WAL archiving (or a
>   delayed replica) is what protects against *that* failure mode.

---

### Q20. Design the full backup retention and testing policy for `banking_db` — not just "what backups exist," but the schedule, retention, and — critically — how you *prove* they work.

**Answer:**

| Artifact | Frequency | Retention | Purpose |
|---|---|---|---|
| WAL archive | Continuous (every segment / ≤60s) | 35 days | PITR to any second within the window |
| `pg_basebackup` (physical) | Daily | 7 days | Fast PITR base; recent full-cluster restore |
| `pg_basebackup` (physical) | Weekly | 8 weeks | Medium-term full-cluster restore without replaying 35 days of WAL |
| `pg_dump` (logical, per-schema) | Weekly | 90 days | Table/schema-level restore; cross-version migration artifact |
| **Automated restore test** | Weekly (against latest daily base backup + WAL) | N/A — a process, not a stored artifact | Proves the chain above actually restores, not just exists |

The automated restore test is the part most real incidents reveal was
missing: spin up an ephemeral instance, restore the latest physical base
backup plus WAL forward to a fixed recent target time, run a small
verification suite (row counts on `customers`/`accounts`/`transactions`
against known checksums or a reference snapshot, confirm no
`FATAL`/`PANIC` in the recovery log, confirm the instance reaches a
consistent, queryable state), then tear it down — and alert loudly if any
step fails.

**Why it works:**
A backup that has never been restored is a *hope*, not a backup — the
single most common real-world DR failure is discovering, mid-incident,
that the WAL archive has a silent gap, the base backup was taken while
`archive_command` was misconfigured, or the restore process itself
depends on a script/credential that no longer works. A weekly automated
restore drill converts that discovery from "during the worst possible
moment" to "during a scheduled, low-stakes test," and it's the only way to
have actual confidence in the stated RTO, since RTO includes *finding out
the restore process works* — which shouldn't happen for the first time
during a real outage.

**Alternative approaches:**
Smaller teams without the infrastructure budget for a full weekly restore
drill sometimes settle for a lighter check — verifying `pg_dump`
completes without error and a `pg_restore --list` against the dump file
succeeds — which catches "the backup file is corrupt/truncated" but does
**not** catch "the WAL archive has a gap" or "the physical backup plus WAL
chain doesn't actually reach a consistent state," which is a materially
weaker guarantee for a 5-minute-RPO system like this one.

**Performance considerations:**
Restore drills against a production-sized copy consume real compute/storage
— for a large database this cost is a legitimate reason teams under-invest
in drilling frequency; a reasonable middle ground is drilling against a
recent, smaller subset (e.g., the most recent 90 days of `transactions`
restored into a scaled-down instance) often, and a true full-scale drill
quarterly.

> **Common mistakes:**
> - "We have backups" as an answer to a DR audit, without ever having
>   completed a real restore end-to-end — this is the single most common
>   gap security/compliance reviews find.
> - Retaining WAL archives but rotating out the physical base backups they
>   depend on before the WAL retention window expires — PITR needs *both*
>   a base backup old enough to still be covered by *available* WAL and the
>   WAL segments themselves; deleting base backups on a schedule
>   independent of WAL retention can leave you with WAL you can no longer
>   apply to anything.

---

### Q21. Walk through, mechanically, what PostgreSQL actually does during a `recovery_target_time` PITR restore — and why recovery can "overshoot" if you're not careful.

**Answer:**
Given a physical base backup and an archived WAL stream, PITR proceeds in
three phases: (1) the base backup's data files are restored as-is — this
is a **fuzzy, internally inconsistent** snapshot (files were copied while
the database was actively being written to, so different files/pages
reflect slightly different points in time); (2) PostgreSQL enters
**recovery mode** and begins replaying WAL records starting from the
`backup_label`'s recorded starting position, applying each change in order
— this replay is what makes the fuzzy snapshot from step 1 internally
consistent, exactly the same replay mechanism used for ordinary crash
recovery (Q5), just starting from an older point and replaying much
further forward; (3) replay continues until it reaches the configured
**recovery target** — a specific LSN, a named restore point, or (most
commonly) `recovery_target_time`, a timestamp — at which point PostgreSQL
stops applying further WAL and, depending on `recovery_target_action`,
either promotes to a normal read-write primary or pauses for inspection.

**Why it works (why "overshoot" happens):**
A common mistake is assuming `recovery_target_time` stops replay at
*exactly* that instant with surgical precision — in reality, WAL records
are replayed **transaction by transaction**, and by default PostgreSQL
replays up to and including the first transaction whose commit timestamp
is *after* the target (then stops), because a target time that falls
*inside* an in-progress transaction has no single well-defined "correct"
stopping point mid-transaction — the whole transaction is atomic, so
either you replay all of it or none of it. If a large transaction
committed just after your target time, recovery inherently includes or
excludes that transaction as one indivisible unit, not a partial replay of
it — this is why the *intended* recovery point and the *actual* database
state after PITR can differ by however long the straddling transaction
took to run, and why choosing `recovery_target_inclusive = false` and
picking a target time with a comfortable safety margin *before* the
suspected bad event matters more than picking the exact second.

**Alternative approaches:**
`recovery_target_xid` (stop right after/before a specific transaction ID)
or `recovery_target_lsn` (stop at a specific WAL position) give more
surgical precision than a timestamp when you know exactly which
transaction caused the problem (e.g., identified from `audit_log` or
application logs) — genuinely more accurate than a time-based target when
that information is available, at the cost of needing to have identified
the exact transaction first.

**Performance considerations:**
Replay speed during PITR is bounded by how fast WAL can be read and
applied sequentially — for a database with 35 days of WAL retention, a
restore targeting "34 days ago" from only a weekly base backup means
replaying up to 6+ days of WAL, which can itself take hours; this is
precisely why the retention table in Q20 keeps *daily* (not just weekly)
base backups — minimizing the WAL replay distance directly minimizes RTO.

> **Common mistakes:**
> - Picking a `recovery_target_time` of the *exact* moment a bad
>   `DELETE` ran, rather than a moment safely *before* it — if the target
>   time is even one second too late, the bad transaction is replayed
>   right along with everything legitimate before it.
> - Forgetting that a database recovered via PITR to an old point and then
>   promoted **diverges** from the original timeline from that point
>   forward — any WAL generated by the *original* primary after the
>   recovery target must never be applied to the restored copy once it's
>   promoted, or the two timelines' histories will conflict (this is
>   exactly what PostgreSQL's **timeline IDs** exist to track and prevent).

---

### Q22. "We have backups" vs. "we can recover" — design the actual proof. What specific, automatable checks distinguish a backup that exists from a backup that works?

**Answer:**
Four escalating levels of proof, each catching a different failure the
level below it misses:

1. **File-level integrity** — the backup artifact isn't truncated or
   corrupted (`pg_dump`'s custom format is internally checksummed;
   `pg_basebackup` supports `--checksum-algorithm` verification during
   the backup itself). Catches: storage-layer corruption, an interrupted
   backup job.
2. **Restorability** — the artifact can actually be loaded into a fresh
   instance without error (`pg_restore --list` for a quick structural
   check; a full `pg_restore`/PITR replay for the real test). Catches: a
   `pg_dump` taken against an inconsistent snapshot, a missing WAL segment
   breaking the PITR chain, permission/role objects the dump references
   but that don't exist on the restore target.
3. **Data correctness** — after restoring, run a verification query set
   against known invariants (row counts per table compared to a recorded
   baseline at backup time; a checksum/hash of a stable subset of rows;
   `SUM(balance)` reconciliation against a separately-recorded ledger
   total for `banking_db.accounts`). Catches: a backup that restores
   cleanly but is missing rows due to a bug earlier in the pipeline (a
   schema filter that silently excluded a table, a WAL gap that dropped
   transactions without erroring).
4. **Time-to-recover measurement** — record how long each drill actually
   took, end-to-end, and compare against the stated RTO. Catches: a
   restore process that *works* but is far slower than believed once run
   against production-scale data, which is only discoverable by actually
   timing it, not by inspecting the process on paper.

**Why it works:**
Each level answers a genuinely different question ("is the file intact,"
"does the restore process succeed," "is the restored data actually
correct," "is it fast enough") — a backup strategy that only checks level
1 (the most common real-world gap) can pass every automated health check
while still being useless in an actual incident.

**Alternative approaches:**
Some organizations run level 2–3 checks *continuously* against a
permanently-running "restore replica" fed purely from the backup/WAL
pipeline (distinct from the HA standby, which is fed via live streaming
replication) — this catches a broken backup chain within minutes of it
breaking rather than waiting for the next scheduled drill, at the cost of
running and monitoring an entire extra always-on instance purely for
verification.

**Performance considerations:**
Level 3's correctness checks (full row-count/checksum comparisons) can
themselves be expensive on a large table — sampling-based verification
(checksum a deterministic, indexed subset rather than the whole table
every time) is a reasonable compromise for very large tables, reserving a
full comparison for periodic, less-frequent deep audits.

> **Common mistakes:**
> - Stopping at level 1 (the backup job "succeeded," no errors in the log)
>   and treating that as proof of recoverability — a successful backup
>   *job* and a *usable* backup are different claims, and the gap between
>   them is exactly where real incidents find out the hard way.
> - Running restore drills against a non-production-representative dataset
>   (a small dev sample) and extrapolating RTO from it — restore time for
>   index rebuilds and WAL replay does not scale linearly in ways that are
>   safe to guess at; measure against production-scale data.

---

### Q23. Incident: the primary database is corrupted beyond repair. You have a physical base backup from 6 hours ago and a continuous WAL archive that stopped updating 2 hours ago (the archiving process silently failed). Walk through the actual recovery decision.

**Answer:**
First, establish the real recovery point available: the base backup (6h
old) plus WAL archive up to the point archiving stopped (2h ago) means the
furthest you can PITR to is **4 hours of replayable history past the base
backup, ending 2 hours ago** — not "6 hours ago," and not "now." Anything
written in the last 2 hours (the archiving-failure window) is only
recoverable if it exists somewhere *other* than the broken primary and the
stale archive — check, in order: (a) is there a streaming replica that was
still receiving WAL over the replication connection *independently* of
the broken `archive_command` (streaming replication and WAL archiving are
separate delivery paths for the same WAL stream — a replica can be fully
caught up even while file-based archiving to object storage was silently
broken)? If yes, that replica is your actual best recovery point, not the
base-backup-plus-archive chain. (b) If no viable replica exists, restore
the base backup, replay WAL to the last archived segment (2 hours ago),
and communicate clearly and immediately that the last 2 hours of
transactions are unrecoverable from the database itself — then check
whether any of that gap can be reconstructed from *outside* the database
(application-level logs, a message queue that received events before
writing them, upstream systems that can be safely replayed/reconciled).

**Why it works:**
This is the practical reality PITR math doesn't advertise: your recovery
point is bounded by the **weakest link** in the base-backup-plus-WAL
chain, not by the most recent artifact alone — a stale archive silently
caps your RPO at whenever it stopped, regardless of how recent your base
backup is. Checking for an independently-current replica first is
critical because streaming replication and archive-command-based WAL
shipping are genuinely separate mechanisms reading the same WAL stream;
one failing silently doesn't imply the other did.

**Alternative approaches:**
If a replica *was* current and is promotable, the entire PITR-from-backup
path may be unnecessary — promote the replica, treat the corrupted
primary as the thing being replaced (rebuild it later as a *new* replica
of the newly-promoted node), and only fall back to the base-backup/WAL
restore if no replica was viable. This is exactly why Q19's architecture
layers a hot standby *and* WAL archiving rather than relying on either
alone — they cover each other's independent failure modes.

**Performance considerations:**
Under real incident pressure, restoring from a 6-hour-old base backup and
replaying 4 hours of WAL takes real, non-negotiable time (Q21) — this is
the moment the "did we ever time a real restore drill" answer from Q20/Q22
either gives you a credible ETA to tell stakeholders or leaves you
guessing live during the outage.

> **Common mistakes:**
> - Discovering the archiving failure *during* the incident rather than
>   from monitoring — `archive_command` failures should page someone the
>   moment they start failing, not be discovered only when a restore is
>   attempted; a silently-broken backup pipeline is arguably worse than no
>   backup pipeline, because it creates false confidence.
> - Attempting to "fix forward" on the corrupted primary under pressure
>   before securing a known-good recovery path — always protect/copy the
>   corrupted primary's current state (even if unusable) before touching
>   it further, in case a next-level recovery approach (e.g., page-level
>   corruption repair) is possible and would otherwise be foreclosed.

---

### Q24. `analytics_db.sales_fact` is already RANGE-partitioned by year (Chapter 26) and has grown to hundreds of millions of rows. How does partitioning change your backup strategy versus treating it as one monolithic table?

**Answer:**
Partition-aware backup exploits the fact that older partitions
(`sales_fact_2022`, `sales_fact_2023`) are **immutable** once their year has
closed — no new rows are ever written into `sales_fact_2022` after 2023
begins — while the current year's partition (`sales_fact_2024`, or
whichever is active) is under continuous write load. This asymmetry means
a full, uniform nightly backup of the entire fact table is wasted work:
you're re-backing-up hundreds of millions of rows that are provably
identical to last night's backup, every single night.

```sql
-- [PostgreSQL] confirm which partitions are still receiving writes
SELECT tableoid::regclass AS partition, count(*), max(sale_date)
FROM analytics_db.sales_fact
GROUP BY tableoid ORDER BY partition;
```

The strategy: back up **closed partitions once**, after they close, and
mark them effectively read-only/archival (a one-time `pg_dump -t
sales_fact_2022` or a physical copy immediately after the partition's
final row is written, verified once, then retained indefinitely without
being touched again); back up the **current, still-growing partition**
frequently (nightly incremental or covered continuously by the normal
WAL-archiving/PITR mechanism from Q19, since that's the only partition PITR
actually needs to reach fine-grained recovery for — nobody needs
second-level PITR precision into 2022's frozen data).

**Why it works:**
This turns an O(total table size) nightly backup cost into an O(current
partition size) nightly cost plus a one-time O(partition size) cost per
partition as each one closes — for a table growing by one year-partition
at a time, the recurring backup cost stays roughly constant instead of
growing without bound as history accumulates.

**Alternative approaches:**
For genuinely enormous fact tables, some teams skip re-backing-up closed
partitions via `pg_dump`/`pg_basebackup` entirely and instead treat them as
covered by the underlying storage layer's own snapshotting (e.g., a cloud
block-storage snapshot taken once, retained forever, restorable
independently of the live database) — cheaper and faster for pure archival
partitions, at the cost of restoring via a different, less
PostgreSQL-native mechanism than the rest of the DR plan.

**Performance considerations:**
This is also exactly where the "no partition for 2025" gap noted in
`analytics_db.sql` (only `sales_fact_2022`/`_2023`/`_2024` partitions
exist) becomes a *backup*-relevant risk, not just an insert-failure risk
(Q52): a backup strategy keyed off "back up the currently-open partition
frequently" implicitly assumes a current partition always exists to
receive writes — if partition creation lags behind the calendar, writes
either fail loudly (no partition, no default) or, in a schema *with* a
`DEFAULT` partition, silently land in an unbounded, un-backed-up-on-its-own-
schedule catch-all, which is worse.

> **Common mistakes:**
> - Continuing to run one undifferentiated `pg_dump`/`pg_basebackup` job
>   against the whole partitioned table indefinitely as it grows, paying
>   an ever-increasing backup window and storage cost for data that stopped
>   changing years ago.
> - Assuming partitioning itself is a backup strategy — it isn't; it's a
>   storage/query-performance technique (Chapter 26) that happens to create
>   a natural, exploitable boundary for backup *tiering*, but someone still
>   has to design and implement the tiered backup policy on top of it.

## D. Replication & High Availability (Chapter 30)

Chapter 30 covers primary/replica architecture, sync vs. async replication,
lag, and split-brain/fencing in depth (including a full split-brain
walkthrough against `banking_db`). These questions go one layer deeper:
the actual mechanisms behind logical vs. physical replication, replication
slots as a real operational hazard, read-your-writes consistency, and
active-active trade-offs the chapter's primary/replica model doesn't cover.

### Q25. Give a concrete numeric example of how synchronous vs. asynchronous replication changes the actual RPO for `banking_db.transactions`, including what "synchronous" does and doesn't guarantee.

**Answer:**
**Asynchronous replication:** the primary commits a transaction (durable in
its own WAL, `COMMIT` returned to the client) *before* confirming the
standby has received it. If the primary's storage is destroyed 200ms
later, any transaction whose WAL hadn't yet reached the standby in that
window is lost — for a `banking_db.transactions` row recording a ₹10,000
withdrawal, the client received a success response, but the standby (now
promoted to primary) never saw it. RPO here is bounded by replication lag,
not zero — typically milliseconds under normal conditions, but with no
hard guarantee.

**Synchronous replication** (`synchronous_commit = on` plus
`synchronous_standby_names` naming at least one standby): the primary does
**not** return `COMMIT` to the client until the named standby confirms it
has *received* (or, with `remote_apply`, actually *applied*) the WAL for
that transaction. If the primary dies immediately after, the standby is
guaranteed to already have that transaction's WAL — promoting it loses
nothing. This gives a **true RPO of zero** for acknowledged transactions,
at the direct cost of every commit's latency now including a full
network round-trip to the standby (and, if the standby is unreachable,
every commit blocking indefinitely by default — a real availability
trade-off, not just a latency one).

**Why it works:**
Synchronous replication's guarantee is specifically about **acknowledged**
transactions — a client that received a successful `COMMIT` can trust the
data survived, because "confirmed by the standby" happened *before*
"confirmed to the client," making the two facts inseparable. Async
replication reverses that ordering, which is exactly the gap that creates
non-zero RPO.

**Alternative approaches:**
`synchronous_commit = remote_write` sits between the two: the primary
waits for the standby to have *written* the WAL to its OS (not
necessarily `fsync`'d to disk), a middle-ground RPO guarantee (survives a
standby process crash, not necessarily a standby OS crash) with lower
latency than full `remote_apply`. Many production banking-grade systems
use synchronous replication to **one nearby standby** (bounding latency
impact) while keeping additional, farther standbys (e.g., a
cross-region DR copy) asynchronous — trading a true zero-RPO guarantee
only against the nearby failure modes that are both most likely and
cheapest to protect against synchronously.

**Performance considerations:**
Every synchronous commit's latency is now floor-bounded by the
round-trip time to the standby — for a same-datacenter standby this might
add sub-millisecond overhead, but for a cross-region standby it can add
tens of milliseconds *to every single transaction*, which is often the
deciding factor in choosing async for geographically distant replicas
regardless of the RPO trade-off.

> **Common mistakes:**
> - Assuming `synchronous_standby_names` alone makes the whole cluster
>   synchronous — it only guarantees the *named* standby(s) acknowledge
>   before commit; any *other* replica in the cluster can still be fully
>   asynchronous and lag arbitrarily.
> - Not planning for the availability side effect: if the only synchronous
>   standby becomes unreachable, by default every write on the primary
>   blocks waiting for an acknowledgment that will never come — a
>   synchronous-replication outage can turn a replica problem into a
>   primary-write outage unless `synchronous_standby_names` lists multiple
>   candidates with `ANY n (...)` quorum syntax.

---

### Q26. Chapter 30 shows fencing and quorum preventing split-brain. Explain, with actual numbers, why quorum requires an odd-sized majority set and why 2 nodes (or 4) is a materially worse choice than 3 (or 5).

**Answer:**
Quorum-based promotion requires a **strict majority** of a fixed set of
independent voting members (an etcd/Consul cluster backing Patroni, for
example) to agree before a promotion proceeds — the point being that two
disjoint majorities can never both exist simultaneously after a network
partition, so at most one side of any partition can ever gather enough
votes to promote. With **3** nodes, a majority is 2 — a partition can only
ever split 3 nodes into a 2-1 or 1-1-1 shape; only the side with 2 can
reach quorum, so promotion is safely exclusive to at most one side. With
**5** nodes, a majority is 3, and the same logic holds for any partition
shape. With **2** nodes, a majority is *also* 2 (you need both) — meaning
a partition that splits them 1-1 leaves **neither** side able to reach
quorum at all, so the cluster correctly refuses to promote anyone, but
also cannot make progress on a legitimate primary failure either (the
surviving node can't prove it's not merely partitioned from a
still-healthy partner). With **4** nodes, majority is 3 — a 2-2 partition
split leaves neither side able to reach quorum, the exact same
"safely stuck" failure as the 2-node case, for the added cost of running a
4th node that bought you nothing over 3.

**Why it works:**
An odd-sized set guarantees that **any** way of splitting it via a network
partition produces one side strictly larger than half and one side
strictly smaller — there is never a tie. An even-sized set can always be
split exactly in half, and a tied split means quorum logic (correctly)
refuses to let *either* side promote, since neither can prove the other
side isn't equally healthy and equally convinced it should be the one to
act — which is safe (no split-brain) but means an even-sized cluster gains
no availability benefit over the next-smaller odd size while costing more
to run.

**Alternative approaches:**
Some deployments intentionally run an *even* number of full database
replicas for read-scaling/cost reasons, while keeping the **voting/quorum
layer** (etcd/Consul) at an odd size independently (e.g., 5 read replicas,
but only 3 lightweight etcd nodes actually deciding quorum) — the voting
set doesn't need to be the same size as, or even collocated with, the set
of nodes holding data, which decouples "how many copies of data do we
want" from "how many votes do we need for safe promotion."

**Performance considerations:**
Larger quorum sets (5, 7) tolerate more simultaneous node failures before
losing the ability to reach quorum at all, but every additional voting
member adds a small amount of latency/overhead to consensus operations
(leader election, configuration changes) — 3 is the practical default for
most deployments; 5 is chosen specifically when tolerating 2 simultaneous
failures (rather than 1) is a real requirement.

> **Common mistakes:**
> - Running a 2-node "HA" PostgreSQL pair with no third independent
>   arbiter and assuming automatic failover is safe — a 2-node quorum
>   without a tiebreaker is a textbook split-brain setup the moment the
>   link between them fails while both nodes are otherwise healthy.
> - Adding a 4th node "for extra redundancy" to a 3-node quorum set without
>   realizing it doesn't improve fault tolerance (still only tolerates 1
>   failure before losing quorum, same as 3) and can make a partition
>   *more* likely to result in a stuck (though safe) cluster.

---

### Q27. What's the actual mechanical difference between PostgreSQL physical (streaming) replication and logical replication — not "one replicates everything, one replicates specific tables," the underlying WAL-processing difference?

**Answer:**
**Physical replication** ships raw WAL records byte-for-byte and applies
them directly to an identical copy of the data files at the *page* level —
the standby has no independent understanding of "this is a row in
`banking_db.transactions`"; it's replaying low-level "write these bytes to
this file offset" instructions. This is why a physical standby must be
running the **same major PostgreSQL version** and the **same
architecture/OS byte-order** as the primary, and why it replicates the
*entire* cluster — WAL doesn't have a concept of "skip this table."

**Logical replication** runs a **decoding** process (`pgoutput`, or
historically `wal2json`/`test_decoding`) that reads the same underlying WAL
stream but reconstructs it into a sequence of **logical row-level changes**
(`INSERT`/`UPDATE`/`DELETE` on specific tables, with actual column values)
— it requires tables to have a `REPLICA IDENTITY` (a primary key, by
default) so `UPDATE`/`DELETE` records can identify *which* row changed
independent of physical page layout. This logical change stream is then
applied by executing equivalent `INSERT`/`UPDATE`/`DELETE` statements on
the subscriber — meaning the subscriber can be a **different major
version**, can have additional/fewer columns, and can subscribe to a
**subset** of tables (a `PUBLICATION` naming specific tables), none of
which physical replication can do.

**Why it works:**
Physical replication's page-level fidelity gives it very low overhead
(no per-row interpretation, just byte-for-byte application) and a strict
guarantee of being an identical copy — ideal for HA/failover, where you
want an indistinguishable twin. Logical replication trades that raw
efficiency and full-cluster fidelity for flexibility (selective tables,
cross-version, transformable), which is exactly what's needed for the use
cases physical replication structurally cannot serve: zero-downtime major
version upgrades (Q31), feeding a subset of tables to a separate analytics
system without exposing the whole cluster, or multi-directional sync
between independently-writable nodes.

**Alternative approaches:**
For "just get read-scaling and failover," physical replication remains the
simpler, lower-overhead default (Chapter 30's primary/replica model).
Logical replication is reached for specifically when one of physical
replication's hard constraints (same version, whole-cluster, one-directional
from a single primary) is the actual blocker.

**Performance considerations:**
Logical replication's decode-and-reapply model has materially higher CPU
overhead per change than physical replication's byte-copy model, and large
transactions can cause a proportionally large logical-decoding memory
footprint on the publisher (`logical_decoding_work_mem`) — it is not a
drop-in performance-equivalent substitute for physical replication even
when its flexibility is otherwise the right fit.

> **Common mistakes:**
> - Assuming logical replication is simply "physical replication but
>   configurable" rather than a structurally different mechanism —
>   sequences, DDL, and large objects are notable examples that do **not**
>   automatically replicate logically (sequence values must be
>   synced separately; DDL requires an explicit strategy) but replicate
>   transparently under physical replication, since physical replication
>   doesn't distinguish object types at all.
> - Trying to use physical replication to selectively replicate a handful
>   of tables to a reporting system — architecturally impossible; that's
>   precisely the use case logical replication (or a separate ETL/CDC
>   pipeline) exists for.

---

### Q28. What is a replication slot, and how does a disconnected replica turn a routine failover safeguard into a primary-disk-exhaustion incident?

**Answer:**
A **replication slot** is a marker on the primary that tracks exactly how
much WAL a specific replica (or logical subscriber) still needs — its
entire purpose is to tell the primary "do not recycle/delete this WAL
segment yet, this consumer hasn't confirmed receiving it." Without slots,
a temporarily slow or disconnected replica could find that the WAL it
needs to catch up on has already been recycled by the primary (governed by
`wal_keep_size`/checkpoint activity), forcing a full re-sync from scratch
— slots exist specifically to prevent that by making WAL retention
*follow the neediest consumer* rather than a fixed size/time window.

The failure mode: if a replica holding a slot **disconnects and is never
reconnected or the slot is never dropped** (a decommissioned standby whose
slot nobody cleaned up, a logical subscriber that crashed permanently), the
primary keeps retaining WAL *indefinitely*, on the reasonable assumption
that consumer might come back — WAL accumulates on the primary's disk
without bound, because the retention logic has no way to know the
consumer is gone forever rather than just slow. This is a well-documented,
recurring real-world PostgreSQL incident: disk fills up on the *primary*,
seemingly out of nowhere, hours or days after a replica was quietly
decommissioned without its slot being dropped.

**Why it works (the underlying trade-off):**
The slot mechanism has to choose between two failure modes and picks the
safer-by-default one: either risk a slow replica falling permanently
behind and needing a full re-sync (the pre-slot behavior), or risk
unbounded WAL retention if a slot is abandoned. PostgreSQL chooses to
protect the replica's ability to catch up by default, which shifts the
operational burden onto *monitoring and cleaning up abandoned slots*
rather than risking silent replica breakage.

**Alternative approaches:**
`max_slot_wal_keep_size` (PostgreSQL 13+) caps how much WAL a slot can
force the primary to retain — once exceeded, the primary is permitted to
recycle WAL anyway, at the cost of the lagging replica/subscriber becoming
permanently unable to catch up (it must be fully re-synced). This converts
an unbounded-disk-growth risk into a bounded-but-still-real
replica-breakage risk — a deliberate, configurable trade-off rather than
an unconditional safety net.

**Performance considerations:**
None directly on query performance, but disk exhaustion on the primary
from an abandoned slot is a full outage, not a degradation — WAL cannot be
written once the disk is full, and the primary stops accepting writes
entirely, making this one of the more severe "silent, invisible until it's
catastrophic" replication hazards.

```sql
-- [PostgreSQL] find slots that are inactive and how much WAL they're forcing the primary to retain
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

> **Common mistakes:**
> - Decommissioning a replica (or a logical subscriber) without explicitly
>   running `SELECT pg_drop_replication_slot('slot_name')` on the primary
>   — the slot silently outlives the replica it was created for.
> - Not alerting on `pg_replication_slots.active = false` combined with a
>   growing `retained_wal` — an inactive slot with growing retained WAL is
>   an unambiguous, early, and easily automatable warning sign, well before
>   disk usage becomes critical.

---

### Q29. A user updates their profile, and the very next page load — routed to a read replica — shows the *old* value. Diagnose this precisely and design a fix that doesn't throw away read-scaling.

**Answer:**
This is **read-your-writes inconsistency**, a direct and expected
consequence of asynchronous replication lag (Q25/Chapter 30 §30.6) — the
write committed on the primary, the read landed on a replica whose WAL
replay hadn't yet caught up to that specific transaction, so the replica
correctly (from its own point of view) returns the last value it actually
has. This is not a bug in replication; it's the fundamental trade-off of
async read-scaling made visible to an end user.

Fixes, from simplest to most robust:

1. **Session stickiness after a write** — after any write from a given
   user/session, route that session's *subsequent* reads to the primary
   for a short window (or permanently for the rest of the session),
   falling back to replicas afterward. Simple, works everywhere, doesn't
   require the replica to expose lag information.
2. **Lag-aware routing** — have the read router check the replica's
   current replay position (`pg_last_wal_replay_lsn()`) against the LSN
   the just-completed write produced (returned to the client via
   `pg_current_wal_lsn()` at commit time), and only route to a replica
   that has caught up *past* that specific LSN; otherwise fall back to the
   primary or wait briefly. More precise than blanket stickiness (doesn't
   pin unrelated reads to the primary unnecessarily) but requires plumbing
   LSN tracking through the application/routing layer.
3. **Synchronous replication for the specific replica serving
   read-after-write paths** — guarantees the replica is never behind for
   an acknowledged write, at the general synchronous-commit latency cost
   from Q25, applied selectively rather than cluster-wide.

**Why it works:**
Each approach closes the same gap — "make sure the read sees a WAL
position at least as new as the write it should be consistent with" —
using a different point of enforcement: client/session behavior (1),
explicit LSN comparison (2), or the replication protocol itself (3).

**Alternative approaches:**
Some applications sidestep the problem at the UI layer instead of the data
layer: after a write, don't re-fetch from the database at all — optimistically
render the just-submitted value directly from the client's own request
payload, and only fall back to a fresh read on a subsequent, unrelated page
load. This avoids the consistency problem for the specific "did my own
edit show up" case without touching routing infrastructure at all, though
it doesn't help a *different* user immediately viewing content just
written by someone else.

**Performance considerations:**
Blanket post-write stickiness to the primary (option 1) is simplest but,
overused (e.g., "always read this user from the primary for the rest of
their session" after any write), quietly erodes the read-scaling benefit
replicas exist to provide — the narrower the stickiness window, the more
of the read-scaling benefit is preserved.

> **Common mistakes:**
> - Treating this as "the replication is broken" and investigating lag as
>   if it were an incident, when sub-second lag under normal load
>   producing this symptom is expected behavior for async replication, not
>   a fault.
> - Implementing session stickiness keyed on session ID without an
>   expiration, so a session that wrote once early on stays pinned to the
>   primary for its entire lifetime, defeating the purpose of read
>   replicas for that user permanently rather than for a brief window.

---

### Q30. Design a multi-region topology for a global consumer application — walk through active-passive vs. active-active, and explain precisely what active-active costs you that a single-writer design doesn't.

**Answer:**
**Active-passive (single-writer, multi-region):** one region holds the
sole read-write primary; other regions hold asynchronous (or, for a
nearby region, synchronous) read replicas serving local reads, with
cross-region failover promoting a replica only during a regional outage.
All writes, from every region, cross the network to the primary's region
— acceptable latency for a region near the primary, a real user-facing
latency cost for a region far from it (a user in Singapore writing to a
primary in Virginia pays that round trip on every write).

**Active-active (multi-writer):** each region has its own writable
primary, accepting local writes with local latency — but now the same
logical row can be modified **concurrently and independently** in two
regions before either write has propagated to the other, and there is no
single database-level serialization point to prevent it (that's precisely
what a single primary provided, and multi-writer gives up). This
reintroduces, at the *application data* level, the exact conflict problem
CAP theorem describes: under a network partition between regions, you
must choose between refusing writes in the disconnected region
(sacrificing availability, effectively falling back to single-writer
behavior for that region) or accepting writes in both and **reconciling
conflicts later** (sacrificing strict consistency).

**Why it works (why active-active needs conflict resolution machinery
active-passive never does):**
With one writer, "what's the correct current value of this row" has a
single, unambiguous answer, always. With two independent writers, two
regions can *both* legitimately update the same row before either knows
about the other's update — resolving that requires an explicit strategy:
**last-write-wins** (simplest, but silently discards one region's write
with no reconciliation — dangerous for anything like `banking_db.accounts.
balance`, where "silently discard a withdrawal" is unacceptable), **CRDTs**
(data types mathematically designed so concurrent updates merge
deterministically without conflict — well-suited to counters/sets, poorly
suited to arbitrary relational schemas with foreign keys and constraints),
or **application-level arbitration** (detect the conflict, queue it for
business-logic resolution — the correct but most expensive option for
financial data).

**Alternative approaches:**
A middle ground many systems actually use: active-active **only for
genuinely partition-tolerant data** (user preferences, shopping cart
contents, presence/session data — where last-write-wins or CRDT merging is
an acceptable business trade-off) while keeping strictly consistent data
(account balances, inventory counts, anything with a hard invariant) on a
single-writer topology, accepting the cross-region write latency for that
subset only. This avoids applying active-active's conflict-resolution
burden uniformly across data that doesn't tolerate it.

**Performance considerations:**
Active-active's headline benefit — local write latency everywhere — is
real and significant for a genuinely global user base, but it's bought
with conflict-detection/resolution machinery that adds its own latency
and complexity to every write path, and with an entire class of bugs
(lost updates, resurrected deleted rows, constraint violations across
regions) that a single-writer system structurally cannot produce.

> **Common mistakes:**
> - Reaching for active-active because "global users deserve low write
>   latency everywhere" without first checking whether the *actual*
>   write volume/latency sensitivity justifies the conflict-resolution
>   complexity — many "global" applications have write patterns
>   concentrated enough (or tolerant enough of a few hundred milliseconds)
>   that active-passive with a well-placed primary is simpler and safer.
> - Applying active-active uniformly across an entire schema instead of
>   selectively to the subset of tables that can actually tolerate
>   eventual-consistency/conflict semantics — `banking_db.accounts.balance`
>   is exactly the kind of column that should never be on the losing end
>   of a silent last-write-wins conflict.

---

### Q31. Design a zero-downtime PostgreSQL major-version upgrade for a live, high-traffic system, using logical replication rather than the standard offline `pg_upgrade` path.

**Answer:**

```
Step 1: stand up a NEW cluster on the target major version, empty schema
         migrated over (pg_dump --schema-only from OLD, restored to NEW)

Step 2: create a PUBLICATION on OLD for the tables to migrate:
         CREATE PUBLICATION upgrade_pub FOR ALL TABLES;

Step 3: on NEW, create a SUBSCRIPTION pointing at OLD:
         CREATE SUBSCRIPTION upgrade_sub
           CONNECTION 'host=old_primary dbname=banking_db'
           PUBLICATION upgrade_pub;
         -- this performs an initial data COPY of every existing row,
         -- then streams ongoing changes continuously — NEW is now a
         -- live, continuously-catching-up logical replica of OLD,
         -- running the NEW major version already

Step 4: let NEW catch up fully (monitor replication lag via
         pg_stat_subscription until it's near-zero); validate NEW's
         data against OLD (row counts, checksums) while OLD keeps
         serving all production traffic, completely undisturbed

Step 5: at a chosen low-traffic moment, briefly pause writes on OLD
         (or fail fast-and-queue at the app layer for seconds),
         confirm NEW's subscription has drained to zero lag,
         cut the application's connection string over to NEW,
         resume traffic — NEW is now primary

Step 6: decommission OLD once NEW has run cleanly for a validation window
```

**Why it works:**
Logical replication's ability to run **cross-major-version** (Q27) is
exactly what makes this possible — the new cluster is fully built,
populated, and continuously kept current on the new version *while the old
version keeps serving all live traffic unmodified*, collapsing the
actual downtime window from "however long a full `pg_dump`/restore or
`pg_upgrade` of the whole dataset takes" (potentially hours for a large
database) down to "however long it takes to flip a connection string and
confirm zero lag" (typically seconds).

**Alternative approaches:**
`pg_upgrade --link` performs an in-place major version upgrade by
hard-linking data files rather than copying them, avoiding a full data
copy and completing in minutes rather than hours for large databases — but
it still requires the database to be **fully stopped** for the duration of
the upgrade, making it unsuitable for a true zero-downtime requirement,
though it remains the simpler, lower-operational-complexity choice when a
short, scheduled maintenance window is acceptable.

**Performance considerations:**
Logical replication's initial `COPY` phase (Step 3) places real read load
on the old primary for a large database — timing it during a lower-traffic
period, and being mindful of `logical_decoding_work_mem`/WAL retention
on OLD while the subscription catches up (Q28's slot-retention hazard
applies directly here: the publication's replication slot on OLD retains
WAL for the entire migration window), are both real operational concerns,
not just theoretical ones.

> **Common mistakes:**
> - Forgetting that logical replication does **not** automatically carry
>   over sequences (Q27) — `SELECT setval(...)` for every sequence must be
>   run against NEW immediately before cutover, or the first inserts after
>   cutover can collide with primary key values already replicated from
>   OLD.
> - Cutting traffic over before confirming replication lag is truly zero
>   and *staying* zero for a stable window — cutting over while the
>   subscription is still catching up means the application's first
>   post-cutover reads on NEW can miss the very last writes made to OLD.

## E. Advanced Patterns — Synthesis Beyond Chapter 31

Chapter 31 already builds cohort analysis, retention analysis,
deduplication, SCD, upserts, and idempotency in full depth against
`ecommerce_db`/`analytics_db`/`banking_db`. Rather than re-deriving those
same queries, this section pushes into what Chapter 31 leaves as practice
variations or doesn't cover at all: SCD applied to `salaries` (a chapter
practice exercise, worked fully here), gaps-and-islands against real
`attendance`/`transactions` data, and the production-scale/failure-mode
questions — dedup at hundreds of millions of rows, upsert hot-row
contention, temporal overlap constraints, tamper-evident audit logs, and
soft-delete vs. legal erasure under partitioning.

### Q32. `company_db.salaries` already stores multiple `effective_date` rows per employee — Chapter 31 notes this is "a natural, pre-existing Type-2-style table once you add an explicit `valid_until`/`is_current` pair." Build that transformation for real, against the seed data.

**Answer:**

```sql
CREATE VIEW company_db.salary_history_scd2 AS
SELECT
    employee_id,
    base_salary,
    bonus,
    effective_date AS valid_from,
    LEAD(effective_date) OVER (PARTITION BY employee_id ORDER BY effective_date) - 1 AS valid_until,
    (LEAD(effective_date) OVER (PARTITION BY employee_id ORDER BY effective_date) IS NULL) AS is_current
FROM company_db.salaries;
```

`LEAD(effective_date) OVER (PARTITION BY employee_id ORDER BY effective_date)`
looks ahead to each employee's *next* salary row; subtracting one day gives
the closing bound of the *current* row's validity window, and a `NULL`
lead value (no next row exists yet) marks the row as still current. Run
against the real seed data, `employee_id = 1` (Aditi Rao) and `employee_id
= 2` (Rahul Mehta) — the two employees with actual multi-row salary
history — produce:

| employee_id | base_salary | bonus | valid_from | valid_until | is_current |
|---|---|---|---|---|---|
| 1 | 450000 | 90000 | 2015-03-01 | 2019-12-31 | false |
| 1 | 520000 | 100000 | 2020-01-01 | (NULL) | true |
| 2 | 280000 | 40000 | 2016-05-12 | 2020-12-31 | false |
| 2 | 320000 | 50000 | 2021-01-01 | (NULL) | true |

Every other employee (3 through 16) has exactly one salary row, so
`valid_until` is `NULL` and `is_current = true` for their single row —
correct, since a Type 2 table with only one version per entity is simply
"the current version, with no history yet."

**Why it works:**
This is a **derived, read-only view** of an SCD Type 2 structure computed
entirely from data that's already correct and already there — `salaries`
was designed with `UNIQUE (employee_id, effective_date)` from the start
(Chapter 13), which is precisely the constraint an SCD2 table needs; the
only thing missing was materializing `valid_until`/`is_current`
explicitly, which `LEAD()` computes without needing to store or maintain
them at all.

**Alternative approaches:**
A **materialized** version (an actual table with stored `valid_until`/
`is_current` columns, refreshed by a trigger on `salaries` insert, or a
scheduled job) trades the view's zero-storage/always-consistent property
for faster reads at scale — appropriate once `salaries` grows large enough
that recomputing `LEAD()` over the full table on every query becomes a
measurable cost; the view form here is the right default until that's
actually true.

**Performance considerations:**
The view's `LEAD()` computation requires a sort within each
`employee_id` partition — with an index on `(employee_id, effective_date)`
(implied by the existing `UNIQUE` constraint), PostgreSQL can satisfy this
via an index scan feeding the window function without a separate sort step
for reasonably sized partitions, but a query filtering to `is_current =
true` across *all* employees still has to materialize the full window
computation first (a view is not indexable), unlike a materialized table
where `WHERE is_current = true` could use a partial index directly.

> **Common mistakes:**
> - Computing `valid_until` as `effective_date - 1` from the row's *own*
>   next salary change without partitioning by `employee_id` — this
>   would leak one employee's next raise date into an entirely different
>   employee's `valid_until`, since `LEAD()` without `PARTITION BY`
>   operates across the whole result set in `ORDER BY` order.
> - Treating this view as sufficient for "as of a point in time, what did
>   *everyone* earn" queries without also handling employees hired *after*
>   the query's target date (they should be excluded entirely, not
>   returned with a misleadingly "current" `NULL`-valid_until row) —
>   exactly the trap Chapter 31's own practice variation calls out.

---

### Q33. Using `company_db.attendance` and `banking_db.transactions`, build one real gaps-and-islands example and one real "dormancy gap" example — actual seed data, actual results.

**Answer:**

**Islands (attendance):** `employee_id = 4` (Vikram Joshi) has three
consecutive calendar dates of attendance rows (2024-01-01 PRESENT,
2024-01-02 ABSENT, 2024-01-03 PRESENT). Finding "islands" of consecutive
*present* days (excluding the absence) uses the classic date-minus-row-
number trick, applied only to the filtered `PRESENT` rows:

```sql
WITH present_days AS (
    SELECT employee_id, work_date,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY work_date) AS rn
    FROM company_db.attendance
    WHERE employee_id = 4 AND status = 'PRESENT'
)
SELECT employee_id, MIN(work_date) AS island_start, MAX(work_date) AS island_end
FROM present_days
GROUP BY employee_id, work_date - (rn || ' days')::interval
ORDER BY island_start;
```

Result: **two separate one-day islands** — `2024-01-01` to `2024-01-01`,
and `2024-01-03` to `2024-01-03` — correctly identified as distinct
islands (not one continuous run) precisely because `work_date - rn` is
`2023-12-31` for the first row but `2024-01-01` for the second (the
excluded `01-02` absence breaks the arithmetic sequence even though the
calendar dates on either side are adjacent). Contrast `employee_id = 3`
(Sneha Kulkarni), whose 3 rows are `PRESENT, PRESENT, LATE` with no
excluded day in between — grouping "attended" (`PRESENT` or `LATE`) days
the same way produces **one island**, `2024-01-01` to `2024-01-03`.

**Gaps (transaction dormancy):** `account_id = 1` has three transactions,
on `2024-01-02`, `2024-01-05`, and `2024-01-15`. Flagging any gap between
consecutive transactions wider than, say, 7 days:

```sql
WITH ordered_txns AS (
    SELECT account_id, transaction_date,
           LAG(transaction_date) OVER (PARTITION BY account_id ORDER BY transaction_date) AS prev_txn
    FROM banking_db.transactions
)
SELECT account_id, prev_txn, transaction_date,
       transaction_date - prev_txn AS gap
FROM ordered_txns
WHERE transaction_date - prev_txn > INTERVAL '7 days';
```

Result: exactly **one flagged gap** — `account_id = 1`, `2024-01-05 →
2024-01-15`, a **10-day gap** (the `01-02 → 01-05` gap is only 3 days,
under the threshold). No other account in the seed data has more than one
qualifying consecutive pair to compare, so this is the only row returned.

**Why it works:**
Both patterns turn "find sequences/breaks" into arithmetic on an ordered,
partitioned window: islands subtract a per-partition row number from a
date to produce a constant for every row in a truly consecutive run
(`LEAD`/`LAG` and the row-number trick are two faces of the same
technique — Chapter 10); gaps directly compare each row against its
immediate predecessor via `LAG()` and threshold the difference.

**Alternative approaches:**
For gaps specifically, `LEAD()` (looking forward) and `LAG()` (looking
backward) are interchangeable with a sign/reference flip — `LAG()` is used
here because "the gap *before* this transaction" reads more naturally than
"the gap *after* the previous one," but both produce identical results.

**Performance considerations:**
Both patterns require a full partition scan/sort to establish row order —
an index on `(employee_id, work_date)` or `(account_id, transaction_date)`
(both already implied by existing `UNIQUE` constraints in these tables)
lets the window function consume pre-sorted input instead of requiring a
separate sort step, which matters once these tables grow far beyond the
seed data's handful of rows.

> **Common mistakes:**
> - Applying the date-minus-row-number island trick to *unfiltered* status
>   rows when the actual business question is about a specific status
>   subset (e.g., "present" streaks) — forgetting to filter first silently
>   answers a different question ("consecutive calendar attendance
>   records regardless of status," which is almost never what's actually
>   asked).
> - Choosing a gap threshold without stating the business justification for
>   it — "10 days" being flagged as dormant only means something once
>   someone has decided what "too long without activity" means for this
>   specific account type/business context.

---

### Q34. `ecommerce_db.reviews` demonstrates `ROW_NUMBER()`-based deduplication on a small illustrative dataset (Chapter 31 §31.6). How do you deduplicate the *same* logical problem on a 500-million-row table without a multi-hour exclusive lock?

**Answer:**
The direct translation of the small-scale technique —
`DELETE FROM t WHERE id IN (SELECT id FROM ranked WHERE rnum > 1)` — becomes
dangerous at scale for two compounding reasons: a single `DELETE` touching
millions of rows holds row locks on all of them for the duration of one
long transaction (blocking concurrent writers to those rows, and risking
a very long-running transaction that itself causes bloat elsewhere per
Q3), and the transaction log/WAL volume from one giant `DELETE` can itself
saturate replication and disk I/O. The production-safe approach:

1. **Identify duplicates once, cheaply, into a side table** —
   `CREATE TABLE dupes_to_remove AS SELECT id FROM ranked WHERE rnum > 1;`
   — a read-only pass, no locks held on the target table beyond normal
   `SELECT` snapshot isolation.
2. **Delete in small, committed batches**, not one statement:

```sql
-- [PostgreSQL] batched delete loop (run repeatedly, e.g., from a script or DO block with a loop)
DELETE FROM reviews
WHERE review_id IN (
    SELECT review_id FROM dupes_to_remove LIMIT 10000
);
-- remove the just-deleted ids from dupes_to_remove, or track a high-water mark, and repeat
```

Each batch is its own short transaction — locks are held briefly, other
traffic against the table interleaves normally between batches, and if the
job is interrupted partway, work already committed doesn't need to be
redone.

**Why it works:**
Breaking one enormous transaction into many small, independently-committed
ones bounds the *duration* any lock is held and the *size* of any single
transaction's undo/WAL footprint, at the cost of the overall cleanup job
taking longer in wall-clock time — a deliberate trade of total job runtime
for concurrency-friendliness, which is almost always the right trade for a
maintenance operation running against a live production table.

**Alternative approaches:**
For an even larger cleanup, a **CTAS-and-swap** avoids `DELETE` entirely:
build a new table containing only the deduplicated rows (`CREATE TABLE
reviews_clean AS SELECT DISTINCT ON (...) ...`), then swap it in with a
brief `ALTER TABLE ... RENAME` inside a short transaction. This avoids
generating any dead tuples/bloat at all (a `DELETE` leaves dead tuples
behind for vacuum to clean up later; a rebuild-and-swap doesn't), at the
cost of needing roughly double the disk space during the rebuild and a
brief window where writes to the original table must be paused, queued, or
replayed onto the new table before/during the swap.

**Performance considerations:**
Batched deletes should include a short `pg_sleep()` or at least yield
between batches on a genuinely hot table, both to let autovacuum keep pace
with the dead tuples each batch creates and to avoid the batches
themselves saturating I/O back-to-back; monitoring `n_dead_tup` (Q3) during
the job confirms vacuum is keeping up rather than falling further behind
as the cleanup proceeds.

> **Common mistakes:**
> - Running the "textbook" single-statement `DELETE ... WHERE id IN
>   (ranked subquery)` unmodified against a genuinely large production
>   table — correct at seed-data scale, a potential multi-hour
>   lock-holding outage at hundreds of millions of rows.
> - Forgetting that batched deletes still need a **stable, deterministic**
>   way to select "the next batch" — `LIMIT 10000` without an `ORDER BY`
>   and a tracked high-water mark can repeatedly select overlapping or
>   already-processed rows depending on plan/physical storage changes
>   between batches.

---

### Q35. Extend the idempotency-key pattern from Chapter 31 §31.14 with the two things it doesn't cover: key expiry, and what happens when a retry arrives with the same key but genuinely different payload.

**Answer:**
Chapter 31's `banking_db.transactions.idempotency_key UUID UNIQUE` plus
`ON CONFLICT (idempotency_key) DO NOTHING` correctly handles "the exact
same retry, indefinitely" — but two real gaps remain. First, an
**unbounded-lifetime unique key column grows forever** and (worse) means a
client bug that accidentally reuses a UUID months later gets silently
swallowed as "a duplicate," rather than processed as the new, distinct
request it actually is. Second, the naive `DO NOTHING` treats *any* retry
with a matching key as identical, without checking the payload actually
matches — a client bug that reuses a key with a *different* amount is a
real error condition, not a safe no-op.

```sql
CREATE TABLE banking_db.idempotency_keys (
    idempotency_key   UUID PRIMARY KEY,
    request_hash      TEXT NOT NULL,       -- hash of the logical request payload
    transaction_id    BIGINT REFERENCES banking_db.transactions(transaction_id),
    created_at        TIMESTAMP NOT NULL DEFAULT now()
);
-- TTL enforcement: a scheduled job (or partitioning by created_at, Chapter 26)
-- purges rows older than the business-defined replay window (e.g., 24-48 hours)
DELETE FROM banking_db.idempotency_keys WHERE created_at < now() - INTERVAL '48 hours';
```

```sql
-- Application-level check before the atomic insert:
-- 1. Look up idempotency_key. Not found -> proceed to atomic insert (below).
-- 2. Found, request_hash MATCHES -> return the existing transaction_id, no-op. Safe retry.
-- 3. Found, request_hash DIFFERS -> reject with a 409 Conflict. This is a client bug, not a retry.

INSERT INTO banking_db.idempotency_keys (idempotency_key, request_hash, transaction_id)
VALUES (:key, :request_hash, :new_transaction_id)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING transaction_id;
```

**Why it works:**
Bounding the key's lifetime to a defined replay window (matching how long
a client could plausibly still be retrying the *same* logical request —
typically hours, not months) keeps the table's size proportional to
recent traffic rather than growing forever, and makes "this key was reused
long after it should have expired" a detectable, alertable anomaly instead
of silent, indefinite deduplication. Hashing and comparing the request
payload turns "same key, different content" from a silent correctness bug
into an explicit, surfaced error.

**Alternative approaches:**
Rather than a separate table, some designs keep the idempotency key
directly on the business table (as Chapter 31 does) and add a
`request_hash` column alongside it there — simpler (no extra table/join)
but couples the idempotency window's lifetime to the business row's
lifetime, which is often wrong (you may want to purge idempotency
tracking after 48 hours while keeping the transaction record itself
forever).

**Performance considerations:**
A dedicated, frequently-purged `idempotency_keys` table (or one
partitioned by `created_at`, Chapter 26, with old partitions simply
dropped instead of row-by-row `DELETE`d) stays small and fast to check
against, versus letting a uniqueness check scale with the ever-growing
full history of a permanent business table.

> **Common mistakes:**
> - Never expiring idempotency keys at all, "to be safe" — this doesn't
>   add safety, it just means a key collision (accidental UUID reuse, a
>   buggy client-side ID generator) years later can silently and
>   incorrectly suppress a legitimate new request indefinitely.
> - Comparing only the idempotency key and never the request content —
>   without the `request_hash` check, "same key, different amount" (a real
>   bug, possibly a serious one for `banking_db.transactions`) is
>   indistinguishable from a legitimate retry and gets silently dropped.

---

### Q36. `ecommerce_db.inventory` upserts (Chapter 31 §31.13) are safe from lost updates — but under very high concurrent write volume to the *same* `(product_id, warehouse_location)` row, the upserts start serializing into a slow queue. Diagnose and design around the contention.

**Answer:**
`ON CONFLICT ... DO UPDATE` is atomic and correct, but atomicity doesn't
mean *free concurrency* — every concurrent upsert targeting the exact same
row (a single hot SKU at a single warehouse, hammered by a flash sale) must
acquire that row's lock one at a time; the rest queue behind it. This is
not a bug in the upsert pattern — it's the fundamental limit of modeling a
frequently-mutated aggregate as **one physical row**: correctness requires
serialization at some point, and pointing every writer at literally the
same row makes that serialization point maximally contended.

Two genuinely different mitigations, with real trade-offs:

**1. Sharded counters (write amplification, read aggregation):** instead
of one `quantity_on_hand` row per `(product_id, warehouse_location)`,
maintain several (e.g., a `shard_id 0..15` dimension), and route each
incoming update to a *random* shard rather than always the same row —
spreading contention across 16 independently-lockable rows. Reading the
"true" quantity requires summing across shards:

```sql
SELECT product_id, warehouse_location, SUM(quantity_on_hand) AS total_on_hand
FROM ecommerce_db.inventory_sharded
WHERE product_id = 9 AND warehouse_location = 'Mumbai-WH1'
GROUP BY product_id, warehouse_location;
```

This trades read simplicity (now requires an aggregation) for dramatically
reduced write contention — the standard technique for "hot counter" problems
(the same idea behind Cassandra/DynamoDB's sharded-counter patterns,
implemented here in plain relational rows).

**2. Append-only delta log plus periodic reconciliation:** instead of
updating `quantity_on_hand` in place at all, `INSERT` an immutable delta
row per stock movement (`INSERT INTO inventory_movements (product_id,
warehouse_location, delta, recorded_at) VALUES (9, 'Mumbai-WH1', -1,
now())`) — inserts to a table are far cheaper to parallelize than updates
to the same row, since each insert is a brand-new tuple with no shared
lock target. The "current quantity" becomes a `SUM(delta)` (potentially
maintained incrementally by a background job or materialized view rather
than computed live on every read).

**Why it works:**
Both approaches attack the same root cause — many concurrent writers
contending for one lockable target — by turning the hot spot into either
*multiple* lockable targets (sharding) or *no shared mutable target at all*
(append-only), at the cost of moving complexity from the write path to the
read/aggregation path in both cases.

**Alternative approaches:**
For contention that's severe but not sustained (a short flash-sale spike
rather than constant high volume), simply **queueing writes through a
single-consumer worker** (an application-level or message-queue-based
serialization point) ahead of the database can smooth the spike without
any schema change — the database sees a steady, moderate `UPDATE` rate
instead of a burst of directly-contending concurrent transactions,
trading queue latency for reduced database lock contention.

**Performance considerations:**
Sharded counters add a fixed multiplier to storage and to the cost of
*reads* (an aggregation instead of a point lookup) in exchange for removing
write contention; the append-only log defers cost to whatever process
computes current state, and needs its own retention/compaction strategy
(Q33's batching lessons apply directly) so the delta log itself doesn't
grow unbounded.

> **Common mistakes:**
> - Concluding "the upsert pattern doesn't scale" and reaching for an
>   entirely different database technology, when the actual problem is
>   modeling a hot aggregate as a single row — the fix is a data-modeling
>   change within SQL, not a platform change.
> - Sharding a counter that isn't actually contended (most rows in
>   `inventory` are not flash-sale hot) — applying sharding/append-only
>   complexity uniformly, rather than only to the specific rows that
>   demonstrably need it, adds real complexity for no benefit on the vast
>   majority of the table.

---

### Q37. Design a database-enforced guarantee (not an application-level hope) that an employee can never be assigned to two overlapping projects at more than their available capacity — using `company_db.employee_projects`.

**Answer:**
PostgreSQL's `EXCLUDE` constraint, backed by a GiST index, generalizes
`UNIQUE` from "no two rows can have equal values" to "no two rows can have
*overlapping* values" — exactly the primitive needed for any
"no double-booking" invariant. Extending `employee_projects` with explicit
assignment periods:

```sql
ALTER TABLE company_db.employee_projects
    ADD COLUMN assignment_period daterange;

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- required to mix scalar equality with range overlap in one EXCLUDE

ALTER TABLE company_db.employee_projects
    ADD CONSTRAINT no_overlapping_assignments
    EXCLUDE USING gist (
        employee_id WITH =,
        assignment_period WITH &&
    );
```

`EXCLUDE USING gist (employee_id WITH =, assignment_period WITH &&)` reads
as: reject any new/updated row if there exists *another* row with the
*same* `employee_id` (`=`) **and** an `assignment_period` that *overlaps*
(`&&`) this one's. Attempting to assign Vikram Joshi (`employee_id = 4`)
to a second project for a date range overlapping his existing Platform
Migration assignment is rejected by the constraint itself — `ERROR:
conflicting key value violates exclusion constraint` — with no possibility
of the check being skipped, forgotten, or raced past by concurrent
application code, unlike an equivalent "check for overlap, then insert" in
application logic.

**Why it works:**
A GiST index can efficiently answer "does anything overlap with this
range" (unlike a B-tree, which is built for equality/ordering, not
interval overlap), which is what makes enforcing this as a *constraint* —
checked atomically by the database on every insert/update, exactly like
any other constraint — practical rather than requiring an expensive table
scan per check. `btree_gist` extends GiST support to plain equality
comparisons (`employee_id WITH =`) so it can be combined with the range
operator in a single index/constraint.

**Alternative approaches:**
Without `EXCLUDE`, the same invariant can only be enforced via
application-level "check then insert" logic (racy — the exact same class
of bug Chapter 12 and Chapter 31 §31.13 warn against for upserts) or a
`SELECT ... FOR UPDATE` plus manual overlap check wrapped in a transaction
(safe, but requires every code path that creates an assignment to
remember to do it correctly, forever) — `EXCLUDE` is strictly superior
whenever the target dialect supports it (this is a PostgreSQL-specific,
GiST-based feature; MySQL/SQL Server/Oracle have no direct equivalent and
require the application-level or trigger-based approach instead).

**Performance considerations:**
GiST index maintenance on insert/update is more expensive than a B-tree's,
and the exclusion check itself requires the database to search for
*any* overlapping row rather than a single exact match — for a table with
extremely high insert volume, this constraint check is a real, measurable
cost per write, though almost always worth it versus the cost of a
double-booking bug reaching production.

> **Common mistakes:**
> - Modeling the date range as two plain columns (`start_date`, `end_date`)
>   and trying to enforce non-overlap with a `CHECK` constraint — `CHECK`
>   constraints can only validate a *single row* against a fixed
>   condition; they cannot compare a row against *other rows* in the
>   table, which is exactly what an overlap check requires.
> - Forgetting `btree_gist` when the `EXCLUDE` constraint needs to combine
>   an equality column (`employee_id`) with a range column in one index —
>   without it, PostgreSQL has no way to build a single GiST index
>   supporting both operator types together.

---

### Q38. `banking_db.audit_log` (Chapter 22's trigger-based audit table) records every change — but a privileged insider with write access to the database could edit or delete audit rows to cover their tracks. Design a tamper-evident version.

**Answer:**
The core technique is a **hash chain**: each audit row's hash is computed
over its own content **plus the previous row's hash**, so altering (or
deleting) any single historical row breaks the chain for every row after
it — detectable, even by someone who can't otherwise tell which row was
tampered with.

```sql
ALTER TABLE banking_db.audit_log
    ADD COLUMN row_hash    TEXT,
    ADD COLUMN prev_hash   TEXT;

-- Populated at insert time (e.g., inside the existing audit trigger from Chapter 22):
--   prev_hash := (SELECT row_hash FROM audit_log ORDER BY audit_id DESC LIMIT 1);
--   row_hash  := encode(digest(
--       audit_id || table_name || operation || row_pk || changed_by
--       || changed_at::text || old_data::text || new_data::text || prev_hash,
--       'sha256'), 'hex');
```

Verification is a single query that recomputes the chain and compares:

```sql
-- [PostgreSQL, pgcrypto] verify no row's hash has been altered and the chain is unbroken
WITH recomputed AS (
    SELECT audit_id, row_hash,
           LAG(row_hash) OVER (ORDER BY audit_id) AS expected_prev_hash,
           encode(digest(audit_id || table_name || operation || row_pk || changed_by
               || changed_at::text || old_data::text || new_data::text
               || COALESCE(LAG(row_hash) OVER (ORDER BY audit_id), ''), 'sha256'), 'hex') AS recomputed_hash
    FROM banking_db.audit_log
)
SELECT * FROM recomputed WHERE row_hash <> recomputed_hash OR prev_hash IS DISTINCT FROM expected_prev_hash;
-- any row returned here is either altered or has had a neighbor altered/deleted around it
```

**Why it works:**
Because each row's hash depends on the *previous* row's hash, changing any
historical row's content changes that row's own hash — which no longer
matches what the *next* row recorded as `prev_hash`, and that mismatch
propagates forward through every subsequent row's hash as well. An
attacker would have to recompute and rewrite the hash of every single row
from the tampered point forward to hide the change — and even then, doing
so requires write access sufficient to rewrite `audit_log` itself, which is
exactly the access this design assumes is the threat.

**Alternative approaches:**
A materially stronger guarantee — protecting against exactly that "rewrite
the whole chain" attacker — periodically ships the **latest hash** to a
system the database administrator cannot alter: an external, append-only
log (a separate service, a write-once object storage bucket, or even a
public/immutable ledger for extreme cases), so that even a full
`audit_log` rewrite can be detected by comparing against an externally
anchored checkpoint. This is a real, meaningfully different security
property (tamper-*evident* even against a fully compromised database
administrator, not just against someone lacking the skill/access to
recompute the whole chain) at the cost of an external dependency and
process.

**Performance considerations:**
Computing `digest()` on insert is cheap per row, but requires reading the
single most recent row's hash first — under very high concurrent insert
volume into `audit_log`, this creates a natural serialization point (every
insert needs to know the immediately preceding hash), similar in kind to
Q36's hot-row contention, though typically at a scale audit logging rarely
approaches.

> **Common mistakes:**
> - Storing the hash chain in the *same* table with no additional
>   protection and believing this alone stops a determined attacker with
>   full database access — it raises the bar (any tampering is
>   *detectable* after the fact) but does not make tampering
>   *impossible* without an external, independently-controlled anchor
>   point.
> - Granting `audit_reader_role` (or any role) `UPDATE`/`DELETE` on
>   `audit_log` at all — the hash chain is a detection mechanism, not a
>   substitute for the basic least-privilege control (Q11) of simply never
>   granting write access to an append-only log in the first place.

---

### Q39. Chapter 31 notes soft deletes (`is_discontinued`-style flags) are "explicitly not sufficient for legal right-to-be-forgotten obligations." Design the actual hard-delete path for `ecommerce_db.users`, and explain why it's harder than `DELETE FROM users WHERE user_id = ...`.

**Answer:**
A genuine "erase this person" request can't be satisfied by a single
`DELETE` on `users` for two structural reasons: **foreign keys** (
`orders.user_id`, `reviews.user_id` both reference `users.user_id`; a
naive `DELETE` either fails outright or, if `ON DELETE CASCADE` were
configured, destroys business records — order history — that the business
may be legally *required* to retain for tax/audit purposes even after the
person's personal data must be erased), and **replicated/backed-up
copies** (the row exists on every streaming replica, in every WAL archive
segment within the retention window, and in every `pg_dump`/physical
backup taken before the deletion — "erased" from the live primary is not
the same as "erased everywhere").

```sql
-- Step 1: anonymize rather than delete the person's identifying data,
-- while preserving referential integrity and business-record retention
UPDATE ecommerce_db.users
SET username  = 'deleted_user_' || user_id,
    email     = 'deleted_' || user_id || '@erased.invalid',
    full_name = 'Erased User',
    is_active = FALSE
WHERE user_id = 4;   -- Nita Rao, is_active already FALSE in the seed data

-- Step 2: anonymize free-text fields elsewhere that could re-identify the person
UPDATE ecommerce_db.reviews SET review_text = NULL WHERE user_id = 4;

-- orders/order_items/payments rows are RETAINED as business/financial records —
-- they no longer carry personally-identifying content once users.full_name/email
-- are overwritten, satisfying "erase personal data" without destroying
-- financial history the business is separately obligated to keep.
```

**Why it works:**
This distinguishes **personal data** (name, email, free-text content —
the actual target of an erasure obligation) from **business/transaction
records** (the fact that order #5 happened, for how much, and when — which
a retention/tax obligation may separately require keeping). Overwriting
the former while leaving the latter's *structure* intact satisfies the
privacy requirement without violating a different legal obligation or
breaking referential integrity.

**Alternative approaches:**
For data where even a *pseudonymized* row is unacceptable, some
jurisdictions/policies require the row to actually disappear — in that
case, `orders.user_id`/`reviews.user_id` are made nullable (or repointed
to a single shared "erased user" placeholder row) and the original `users`
row is genuinely deleted, at the cost of losing the ability to
distinguish "which specific erased user" placed a given historical order,
which may itself be an unacceptable loss of business analytics/fraud-
detection capability — this is a genuine policy trade-off, not a purely
technical one.

**Performance considerations:**
The backup/WAL/replica retention problem (Q20's retention windows) means a
truly complete erasure isn't instantaneous — the anonymized state
propagates to replicas immediately (it's a normal write), but any backup
taken *before* the anonymization still contains the original data until it
ages out of the retention window, which is why erasure policies typically
document a defined maximum time-to-full-erasure (e.g., "within 30 days,
accounting for backup retention") rather than promising instantaneous
disappearance everywhere.

> **Common mistakes:**
> - Treating `is_active = FALSE` (already present on `ecommerce_db.users`)
>   as satisfying an erasure request — a soft-delete/deactivation flag
>   leaves every identifying column fully intact and queryable; it
>   addresses "stop showing this account as active," not "erase this
>   person's data," which are entirely different obligations.
> - Forgetting that backups and replicas hold copies of the pre-erasure
>   data and either promising instantaneous complete erasure (a promise the
>   backup retention window makes untrue) or, worse, never accounting for
>   backup retention in the erasure policy at all.

---

### Q40. Synthesis: design an idempotent, deduplicated, SCD2-tracked ingestion pipeline for a nightly HR feed that updates `company_db.employees.job_title`/`department_id` — combining four patterns from this section into one production job.

**Answer:**
The feed arrives as a `hr_feed_staging` table shaped like `(employee_id,
job_title, department_id, source_system, received_at)`, potentially
containing duplicate submissions from more than one upstream HR system for
the same logical change (Q34's dedup problem) and needing to be safely
re-runnable if the job fails partway (Q35's idempotency problem), while
feeding an SCD2 history table (Q32's pattern) without ever leaving two
rows simultaneously marked current.

```sql
-- Step 1 — Dedup: one row per (employee_id, job_title, department_id) change,
-- keeping the earliest report across upstream systems as authoritative
CREATE TEMP TABLE hr_feed_deduped AS
SELECT DISTINCT ON (employee_id, job_title, department_id)
       employee_id, job_title, department_id, received_at
FROM hr_feed_staging
ORDER BY employee_id, job_title, department_id, received_at ASC;

-- Step 2 — Idempotent, per-employee, per-change processing marker
CREATE TABLE IF NOT EXISTS company_db.hr_feed_processed (
    employee_id INT NOT NULL,
    job_title   VARCHAR(100) NOT NULL,
    department_id INT,
    processed_at TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (employee_id, job_title, department_id)
);

-- Step 3 — For each deduped change not already processed, atomically
-- close the current history row and open a new one (SCD2), then mark processed
INSERT INTO company_db.hr_feed_processed (employee_id, job_title, department_id)
SELECT d.employee_id, d.job_title, d.department_id
FROM hr_feed_deduped d
ON CONFLICT (employee_id, job_title, department_id) DO NOTHING
RETURNING employee_id, job_title, department_id;
-- Application/procedure logic: for every row actually RETURNED (i.e., genuinely
-- new, not a re-run of an already-applied change), run the Chapter 31 §31.7
-- two-step "close old row, insert new row" transaction against
-- employee_job_history, then UPDATE employees.job_title/department_id directly.
```

**Why it works:**
Step 1 collapses upstream duplicate reports before anything else happens —
downstream logic never has to reason about the same logical change
arriving twice from *different* source systems. Step 2's `ON CONFLICT ...
DO NOTHING ... RETURNING` is the idempotency gate: if the job crashes after
Step 3 partially completes and is re-run from scratch, every change already
recorded in `hr_feed_processed` is silently skipped (no rows `RETURNING`
for it), so only genuinely unprocessed changes reach the SCD2 write —
re-running the whole pipeline is always safe. The SCD2 write itself reuses
Chapter 31's proven atomic two-step pattern unchanged, applied only to the
genuinely-new subset of changes.

**Alternative approaches:**
A simpler design that skips the separate `hr_feed_processed` marker table
entirely is possible if the SCD2 history table's own `UNIQUE
(employee_id, valid_from)` constraint is relied upon as the sole
idempotency gate (an `INSERT ... ON CONFLICT DO NOTHING` directly into
`employee_job_history`) — fewer moving parts, but conflates "have I
already recorded this history row" with "have I already processed this
staging feed row," which can differ if a later step in a multi-step
pipeline (e.g., also updating a downstream payroll system) needs its own
independent processed-marker regardless of whether the history write
succeeded.

**Performance considerations:**
`DISTINCT ON` (Step 1) requires sorting the staging batch — for a nightly
feed sized to "one company's HR changes," this is trivial; the same
technique applied to a much larger, continuously-streaming feed would need
the batched-processing discipline from Q34 rather than one unbounded
`DISTINCT ON` pass.

> **Common mistakes:**
> - Making the SCD2 write itself the only idempotency check, without a
>   marker that's independent of it — if the pipeline needs to trigger a
>   *second* side effect (e.g., notifying payroll) per processed change,
>   relying solely on "was this history row already inserted" doesn't tell
>   you whether the *notification* step already ran too.
> - Deduplicating only within a single run of the staging table, without
>   considering that a previous run's already-applied change could
>   reappear in a *later* day's feed (e.g., an upstream system resending
>   old data) — the `hr_feed_processed` marker table's role is precisely
>   to catch that cross-run case, which a dedup pass scoped to a single
>   batch cannot.

## F. System Design & Schema Design

This is how staff-level SQL interviews are actually run: a one-line prompt,
and the expectation of a schema sketch plus the reasoning behind every
non-obvious decision, out loud, on a whiteboard. There is rarely a single
correct answer — the **Alternative approaches** section for each of these
is doing real work, not filling a template. Several questions deliberately
extend the course's own databases (`ecommerce_db.inventory`,
`banking_db.audit_log`/`transactions`, `analytics_db.sales_fact`'s
existing year-partitioning) rather than starting from a blank page, because
that's the more common real interview shape: "here's what we have, now
scale/secure/extend it."

### Q41. Design a schema for a ride-sharing app (riders, drivers, trips, pricing, real-time location).

**Answer:**

```
users (rider or driver, or both — a role table, not a type column)
  user_id PK, full_name, email, phone, created_at

driver_profiles
  user_id PK/FK -> users, license_number, vehicle_id FK, rating, status (ONLINE/OFFLINE/ON_TRIP)

vehicles
  vehicle_id PK, driver_user_id FK, make, model, plate_number, capacity

trips
  trip_id PK, rider_user_id FK, driver_user_id FK NULL until matched,
  status (REQUESTED/MATCHED/EN_ROUTE/IN_PROGRESS/COMPLETED/CANCELLED),
  requested_at, matched_at, started_at, completed_at,
  pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
  fare_amount NUMERIC, surge_multiplier NUMERIC DEFAULT 1.0

trip_location_pings   -- high-volume, append-only, time-series
  ping_id PK, trip_id FK, driver_user_id FK, recorded_at, lat, lng
  -- PARTITION BY RANGE (recorded_at), e.g. daily/hourly partitions

fare_ledger
  ledger_id PK, trip_id FK, component (BASE_FARE/DISTANCE/TIME/SURGE/TIP/PROMO),
  amount NUMERIC, currency
```

**Why it works:**
`trips` is the central fact — a rider requests, the system matches a
driver, state transitions are tracked with explicit timestamps for each
milestone (this alone answers most analytics questions: average
time-to-match, average trip duration, cancellation rate before vs. after
matching). `trip_location_pings` is deliberately a **separate,
partitioned, append-only** table rather than columns on `trips` — location
updates arrive continuously and in huge volume during an active trip
(every few seconds), while `trips` itself is a slowly-changing row updated
only at state transitions; mixing the two would make `trips` — the table
every other query joins against — needlessly wide and high-churn.
`fare_ledger` breaks the fare into components rather than one flat
`fare_amount`, because "why was I charged this much" (surge, promo, tip)
is both a support and a compliance question that a single opaque total
cannot answer.

**Alternative approaches:**
Storing live driver location as **one current row per driver** (`UPDATE
driver_profiles SET current_lat=..., current_lng=... WHERE user_id=...`,
overwritten in place) rather than an append-only ping log serves
"find nearby drivers for matching" far more cheaply (one indexed row per
driver, no history to scan) — a real system typically needs **both**: the
current-location table for matching (hot path, needs to be fast), and the
ping log for trip replay/dispute resolution/ETA-accuracy analytics (cold
path, can be append-only and partitioned). Geospatial matching itself is
usually delegated to PostGIS's spatial indexes (`GIST` over a
`geography` column) rather than naive lat/lng range queries.

**Performance considerations:**
`trip_location_pings` at even a modest scale (10,000 concurrent trips,
one ping every 5 seconds) is ~2,000 writes/second sustained — this table
absolutely needs time-based partitioning (Chapter 26) with old partitions
dropped or archived to cold storage after the dispute-resolution window
closes (days, not years), or it becomes the single largest, fastest-
growing table in the system with no query needing most of its history.
`trips` needs indexes on `(driver_user_id, status)` and `(rider_user_id,
requested_at)` for the two most common access patterns (a driver's current
trip, a rider's trip history).

> **Common mistakes:**
> - Storing live location as a growing table of rows per driver without
>   partitioning or an aggressive retention/archival policy — this is the
>   single fastest-growing table in the entire schema and is usually the
>   first thing to cause production pain if treated like an ordinary table.
> - Using a single `users` table with a `role` column and no separate
>   `driver_profiles`/`vehicles` tables — driver-specific attributes
>   (license, vehicle, rating) don't apply to riders, and cramming them
>   into `users` as nullable columns is a normalization violation (Chapter
>   14) that gets worse as driver-specific fields accumulate.

---

### Q42. Design a schema for a multi-tenant SaaS billing system (plans, subscriptions, usage-based metering, invoices).

**Answer:**

```
tenants
  tenant_id PK, company_name, created_at, billing_email

plans
  plan_id PK, plan_name, billing_model (FLAT/PER_SEAT/USAGE_BASED), base_price, currency

subscriptions
  subscription_id PK, tenant_id FK, plan_id FK,
  status (TRIALING/ACTIVE/PAST_DUE/CANCELLED),
  current_period_start, current_period_end,
  seats INT NULL   -- only meaningful for PER_SEAT plans

usage_events            -- append-only, high volume, per-tenant metering
  event_id PK, tenant_id FK, subscription_id FK, metric_name, quantity,
  event_time, idempotency_key UNIQUE   -- see Q35 pattern; billing MUST be idempotent
  -- PARTITION BY RANGE (event_time)

invoices
  invoice_id PK, tenant_id FK, subscription_id FK,
  period_start, period_end, status (DRAFT/ISSUED/PAID/VOID), total_amount, issued_at

invoice_line_items
  line_item_id PK, invoice_id FK, description, quantity, unit_price, amount
```

**Why it works:**
`usage_events` is append-only and idempotency-keyed for the same reason
Chapter 31 §31.14 insists on it for `banking_db.transactions`: a metering
event (an API call, a GB processed) reported twice due to a network retry
must never be billed twice — this is the single most consequential
correctness requirement in a usage-based billing system, and it's cheaper
to build in from day one than retrofit after a customer disputes a
doubled invoice. `invoices` are **immutable once issued** (a `VOID` status
plus a new corrected invoice, never an in-place edit of an issued invoice)
because financial documents that changed after being sent create exactly
the audit/compliance problems Chapter 31's SCD-Type-1-vs-2 distinction
warns about — an issued invoice is a historical fact, not a mutable
current-state row. `invoice_line_items` breaks the total into components
for the same "why was I charged this" transparency reason as Q41's
`fare_ledger`.

**Alternative approaches:**
For pure usage-based billing at very high event volume, aggregating
`usage_events` into hourly/daily rollup tables (a materialized view or
scheduled job producing `usage_daily_rollup(tenant_id, metric_name, day,
total_quantity)`) before invoice generation avoids re-scanning the entire
raw event stream at billing time — a genuine performance-vs-freshness
trade-off (rollups introduce a small lag before usage is "billing-ready")
that's almost always worth making once event volume is large.

**Performance considerations:**
`usage_events` needs the same partition-and-archive discipline as Q41's
location pings — it's the highest-volume table by a wide margin, and once
an invoice period closes, the raw events behind it rarely need to be
queried again (the invoice itself is the durable summary); partitions can
be dropped or moved to cold storage well before the raw event table grows
unbounded. `tenant_id` should be the **leading column** of every index on
every multi-tenant table (Q14) since essentially every query is scoped to
one tenant.

> **Common mistakes:**
> - Allowing issued invoices to be edited in place instead of voided and
>   reissued — this destroys the audit trail a billing system is legally
>   and practically required to maintain, and makes "what did we actually
>   bill this customer on this date" unanswerable.
> - Metering usage without an idempotency key, assuming "the message queue
>   guarantees exactly-once delivery" — most queue systems guarantee
>   *at-least-once* delivery in practice; billing logic must be idempotent
>   regardless of what the transport layer claims.

---

### Q43. `analytics_db.sales_fact` is already RANGE-partitioned by year and sits at ~5 million rows in this course's seed data. Design how this evolves at 100 million+ rows/day (not total — per day).

**Answer:**
At 100M rows/day, yearly partitions (~36 billion rows/partition/year) are
far too coarse — every query, even one scoped to a single day, would need
to scan a fraction of a partition containing a year's worth of data with
no finer-grained pruning. The redesign:

```sql
-- Partition by DAY (or hour, if per-day is still too coarse for the workload),
-- not year — matching Chapter 26's guidance that partition granularity
-- should match the size and query pattern of the data, not an arbitrary calendar unit
CREATE TABLE sales_fact (
    sale_id BIGSERIAL, sale_date DATE NOT NULL, customer_key INT NOT NULL,
    product_key INT NOT NULL, store_key INT NOT NULL, quantity INT, amount NUMERIC,
    PRIMARY KEY (sale_id, sale_date)
) PARTITION BY RANGE (sale_date);

-- Automate partition creation well AHEAD of need (this course's own analytics_db.sql
-- only defines partitions through 2024-12-31 — see Q52 for exactly what happens
-- when this automation is missing) using pg_partman or a scheduled job:
-- pg_partman maintains a rolling window of future-created and past-retired partitions automatically.
```

Beyond finer partitioning, at this volume **sharding** (splitting across
multiple *physical database instances*, not just partitions within one)
becomes a real consideration — partitioning solves "one table is too big
for one set of indexes/vacuum cycles to handle gracefully," sharding solves
"one machine's CPU/disk/memory is no longer enough regardless of table
layout." A natural shard key here is `store_key` or `customer_key`'s
geographic region — co-locating a region's stores/customers on one shard
keeps most queries (regional sales reports) shard-local, while
cross-shard aggregate queries (global totals) require a fan-out/scatter-
gather layer (Citus, or an application-level aggregation across shards) on
top of plain PostgreSQL.

**Why it works:**
Daily (or hourly) partitions bound the amount of data any single-day query
touches to roughly a constant size regardless of total history, keep each
partition's indexes and vacuum cycles independently manageable (Chapter 26
— a single 36-billion-row partition would itself have all of Q3/Q8's
bloat and maintenance problems at a scale no single `VACUUM` pass handles
gracefully), and let old partitions be dropped or moved to cheaper cold
storage in O(1) time (a `DROP TABLE` on a partition, versus a `DELETE`
scanning and generating dead tuples across a monolithic table). Sharding
additionally distributes the *write* load itself across machines, which
partitioning alone — still one PostgreSQL instance — cannot do.

**Alternative approaches:**
Rather than (or in addition to) sharding a single logical fact table, many
analytics systems at this volume move the raw event stream into a
purpose-built column-store/OLAP engine (ClickHouse, BigQuery, Snowflake,
Redshift) fed by CDC/logical replication (Q27) from the OLTP-ish
PostgreSQL layer, keeping PostgreSQL for what it's structurally best at
(transactional consistency, moderate-volume reporting) rather than
stretching a single relational engine to serve a genuinely
big-data-scale analytical workload — a real, common, and often correct
"the right tool" answer that a purely PostgreSQL-native design (however
well partitioned/sharded) eventually runs up against.

**Performance considerations:**
Automated partition management is not optional at this scale — the
biggest operational risk isn't the query performance of well-designed
partitions, it's **partition creation falling behind the calendar**
(exactly the gap already present in this course's own `analytics_db.sql`,
which only defines partitions through the end of 2024) causing inserts to
fail outright the moment a new day/hour arrives with no corresponding
partition and no `DEFAULT` partition as a safety net.

> **Common mistakes:**
> - Choosing partition granularity based on how the data is conceptually
>   organized (calendar years, matching `dim_date`) rather than on actual
>   per-partition row counts and query patterns — the "right" granularity
>   is whatever keeps individual partitions comfortably sized for
>   vacuum/index maintenance and matches how queries actually filter
>   (daily dashboards should hit daily-or-finer partitions).
> - Treating sharding as a partitioning problem solvable entirely within
>   one PostgreSQL instance — sharding is fundamentally a *distributed
>   systems* problem (cross-shard joins/aggregations, rebalancing,
>   distributed transactions) that partitioning within a single instance
>   does not address at all.

---

### Q44. Design a complete HA/DR architecture for an OLTP system with a hard requirement of RPO ≤ 1 minute and RTO ≤ 5 minutes.

**Answer:**

```
┌───────────────────────────────────────────────────────────────────────┐
│ REGION A (primary)                                                     │
│  PRIMARY  ──sync──▶  STANDBY-A2 (same region, synchronous_commit=on)   │
│     │                 quorum: Patroni + 3-node etcd (Q26)              │
│     └──async──▶ cross-region                                          │
└───────────────────────────┬─────────────────────────────────────────┘
                             │ async streaming + continuous WAL archive to
                             │ object storage (cross-region, immutable)
┌───────────────────────────▼─────────────────────────────────────────┐
│ REGION B (DR)                                                          │
│  STANDBY-B1 (async streaming replica, promotable)                      │
└─────────────────────────────────────────────────────────────────────┘
Connection routing: Patroni-managed virtual IP / DNS + PgBouncer,
automatic promotion on primary failure with fencing (Q26), health-checked
every few seconds.
```

**Why it works, mapped directly to the two numbers:**
**RPO ≤ 1 minute** is met two ways depending on *which* failure occurs:
for the common case (primary host/process failure within Region A), the
**synchronous** same-region standby (STANDBY-A2) guarantees zero data loss
for any acknowledged commit (Q25) — better than the 1-minute requirement,
not just meeting it. For the rarer case of losing all of Region A, the
**async** cross-region standby (STANDBY-B1) bounds RPO by replication lag
plus WAL archive frequency — sized to comfortably clear 1 minute under
normal network conditions between regions, with continuous monitoring
(Chapter 30 §30.6) alerting well before lag approaches that threshold.
**RTO ≤ 5 minutes** is met by automated, quorum-based failover (Patroni +
etcd, Q26) detecting the primary's failure and promoting a standby within
seconds to low minutes — well inside the 5-minute budget — with fencing
guaranteeing no split-brain (Q26/Chapter 30) during the transition, and
connection routing (DNS/VIP failover via the same orchestration tooling)
redirecting application traffic to the new primary automatically rather
than requiring a manual runbook step.

**Alternative approaches:**
A cheaper architecture that relaxes the *same-region* synchronous standby
(keeping only the cross-region async one) saves the latency cost of
synchronous commits entirely, at the cost of RPO for the *common* failure
case now depending on async replication lag rather than being
mathematically zero — for many businesses, the common-case failure
(a single host dying) tolerating a few seconds of lag-bounded RPO is an
acceptable trade against the latency savings; this is a legitimate,
cheaper alternative when the 1-minute RPO target has real margin.

**Performance considerations:**
The synchronous same-region standby adds a network round-trip to every
committed write (Q25) — kept low-latency specifically by being
**same-region** (sub-millisecond to low-single-digit-millisecond RTT)
rather than cross-region, which is precisely why the architecture splits
the roles this way: synchronous where latency cost is negligible (same
region), asynchronous where it would otherwise be prohibitive
(cross-region).

> **Common mistakes:**
> - Making the cross-region standby synchronous "to be extra safe" —
>   cross-region round-trip latency (tens to hundreds of milliseconds)
>   applied to *every* commit is a severe, usually unacceptable throughput
>   and latency cost, for a safety margin the same-region synchronous
>   standby already provides for the common failure case.
> - Building automated failover without the fencing/quorum machinery from
>   Q26 "because it's simpler" — a naive health-check-and-promote design
>   is a split-brain generator under the exact network-partition scenario
>   that automated failover exists to survive, and would violate the RPO
>   guarantee the moment it produces two diverging primaries.

---

### Q45. Design a schema for a social media news feed with a follow graph, optimized for reading a user's home timeline.

**Answer:**

```
users
  user_id PK, username, created_at

follows
  follower_id FK -> users, followee_id FK -> users, followed_at
  PRIMARY KEY (follower_id, followee_id)   -- prevents duplicate follows, indexes both directions' lookups

posts
  post_id PK, author_id FK -> users, content, created_at

-- Fan-out-on-write: precomputed per-follower feed entries
feed_entries
  user_id FK,        -- whose home timeline this entry belongs to
  post_id FK, author_id FK, created_at,
  PRIMARY KEY (user_id, post_id)
```

**Why it works:**
The `follows` table with a composite `(follower_id, followee_id)` primary
key answers both "who does X follow" and, via a second index on
`(followee_id, follower_id)`, "who follows X" efficiently — this is the
same self-referential many-to-many bridge pattern as
`company_db.employee_projects`, just between `users` and itself. The core
design decision is **fan-out-on-write**: when a user posts, a
`feed_entries` row is inserted for **every one of their followers**
immediately (via a trigger, or an async worker consuming a "post created"
event) — so reading a home timeline is a single, fast, already-materialized
query: `SELECT * FROM feed_entries WHERE user_id = :me ORDER BY created_at
DESC LIMIT 20`, no joins or fan-in computation at read time.

**Alternative approaches:**
**Fan-out-on-read** (the opposite trade) skips `feed_entries` entirely and
computes a user's timeline at *read* time: `SELECT p.* FROM posts p JOIN
follows f ON f.followee_id = p.author_id WHERE f.follower_id = :me ORDER
BY p.created_at DESC LIMIT 20`. This makes writes trivially cheap (just
insert the post, nothing fans out) but makes *reads* expensive
proportional to how many people the user follows — the classic trade-off
is which side of the read/write ratio dominates: fan-out-on-write is
correct for the typical social feed (read far more often than posted to,
and most users follow a bounded number of people), but breaks down badly
for **celebrity accounts** with millions of followers, where a single post
would need millions of `feed_entries` inserts. Production systems (Twitter
being the most famous public example) handle this with a **hybrid**:
fan-out-on-write for ordinary accounts, fan-out-on-read (merged into the
timeline query only for the handful of celebrity accounts a user follows)
for accounts above a follower-count threshold.

**Performance considerations:**
`feed_entries` is a very high write-amplification table under pure
fan-out-on-write (one post from a user with 10,000 followers is 10,000
inserts) — this is exactly the trade being made deliberately, and is
almost always implemented as an **asynchronous** fan-out (a queue/worker
processing the fan-out after the post itself is durably saved), not a
synchronous part of the post-creation transaction, so a slow fan-out never
makes posting itself feel slow to the author.

> **Common mistakes:**
> - Implementing fan-out-on-write synchronously inside the same
>   transaction that creates the post — for any account with a
>   non-trivial follower count, this makes posting latency scale with
>   follower count, exactly the opposite of the intended user experience.
> - Applying pure fan-out-on-write uniformly with no celebrity-account
>   exception, which turns a single popular post into a write storm
>   proportional to follower count — a real, well-documented scaling
>   failure mode in naively-designed feed systems.

---

### Q46. Extend `ecommerce_db.inventory` into a full warehouse/inventory management design that supports multi-warehouse stock, reservations (items in a cart shouldn't be sellable to two customers), and an auditable stock-movement history.

**Answer:**

```
inventory                          -- current on-hand snapshot per warehouse (already exists)
  product_id, warehouse_location, quantity_on_hand, reorder_level

inventory_reservations             -- soft-hold during checkout, expires if not converted to a sale
  reservation_id PK, product_id FK, warehouse_location, order_id FK NULL,
  quantity, reserved_at, expires_at, status (ACTIVE/CONVERTED/EXPIRED/CANCELLED)

stock_movements                    -- append-only ledger; the source of truth
  movement_id PK, product_id FK, warehouse_location, movement_type
    (RECEIPT/SALE/RESERVATION/RESERVATION_RELEASE/ADJUSTMENT/TRANSFER_OUT/TRANSFER_IN),
  quantity_delta INT,              -- signed: +50 receipt, -1 sale
  reference_id,                    -- order_id, transfer_id, etc.
  recorded_at
```

**Why it works:**
`quantity_on_hand` on `inventory` remains a fast, directly-queryable
current snapshot (exactly as it exists today — "is this in stock" must be
a cheap point lookup, not an aggregation over history on every product
page view), but it is now **derived and reconciled from** `stock_movements`
rather than being the sole source of truth updated ad hoc — every change
to it is required to correspond to an appended movement row, giving a full
audit trail ("why does this warehouse show 12 units") that a bare
snapshot column can never answer on its own. `inventory_reservations`
solves the "two customers, one last item" race precisely the way Chapter
12/31's `SELECT ... FOR UPDATE`/atomic-upsert guidance prescribes: adding
an item to a cart creates a **time-boxed** reservation (decrementing
*available* stock — `quantity_on_hand - SUM(active reservations)` — without
yet decrementing the physical on-hand count), which either converts to a
real `SALE` movement at checkout or **expires** automatically (a scheduled
job releasing reservations past `expires_at`), preventing carts from
holding stock hostage indefinitely.

**Alternative approaches:**
A simpler design skips `stock_movements` and treats `inventory.
quantity_on_hand` as the sole source of truth, updated directly by every
operation (Chapter 31 §31.13's upsert pattern, exactly as it exists in
this course today) — this is genuinely sufficient for a small-to-medium
catalog with low audit/compliance requirements, and adding the full
movement ledger is a deliberate complexity trade made specifically because
"why does the count not match a physical audit" becomes an operationally
important question at larger scale (loss, theft, miscounted receipts,
multi-warehouse transfers all need to be individually attributable).

**Performance considerations:**
Computing "available to sell" as `quantity_on_hand - SUM(active
reservations)` on every product-page read is expensive if reservations
accumulate — maintaining an `available_quantity` column on `inventory`
itself, updated transactionally alongside each reservation
insert/expiry/conversion (via a trigger or application transaction), turns
the hot read path back into a cheap point lookup at the cost of one more
value to keep consistent with the reservation table (a materialized
denormalization, justified specifically because "is this in stock" is
read vastly more often than reservations change).

> **Common mistakes:**
> - Decrementing `quantity_on_hand` directly the moment an item is added
>   to a cart, with no separate reservation/expiry mechanism — an
>   abandoned cart then permanently (or until some ad hoc cleanup script
>   runs) removes real stock from being sellable to anyone else.
> - Building the movement ledger but never reconciling it against
>   `quantity_on_hand` — a ledger that can silently drift from the
>   snapshot it's supposed to explain provides false confidence; a
>   periodic reconciliation job (`SUM(quantity_delta)` per product/
>   warehouse, compared against the live snapshot) is what actually makes
>   the audit trail trustworthy.

---

### Q47. Extend `banking_db.audit_log` into a full tamper-evident, compliance-grade audit architecture — beyond the hash-chain mechanism from Q38, what does the *system design* around it need?

**Answer:**

```
┌──────────────────────────────────────────────────────────────────────┐
│  banking_db (primary transactional database)                          │
│    - triggers write audit rows into audit_log (Chapter 22)            │
│    - audit_log has NO update/delete GRANT to any role except a         │
│      dedicated, tightly-restricted archival process                    │
└───────────────────────────┬─────────────────────────────────────────┘
                             │ near-real-time logical replication (Q27) —
                             │ publishes ONLY audit_log, one-directional
┌───────────────────────────▼─────────────────────────────────────────┐
│  audit_archive_db (separate physical database/instance)                │
│    - append-only; different credentials, different infrastructure       │
│      team's control, ideally different cloud account/region             │
│    - hash-chained (Q38) AND periodically checkpointed to WORM            │
│      (write-once-read-many) object storage                              │
│    - audit_reader_role (Chapter 27) and compliance auditors query HERE, │
│      never against production banking_db directly                       │
└─────────────────────────────────────────────────────────────────────┘
```

**Why it works:**
This addresses the gap Q38 explicitly leaves open: a hash chain living in
the *same* database an attacker with sufficient access could tamper with
is detectable-but-not-prevented tampering. Replicating `audit_log` to a
**separate database, under separate administrative control**, means an
attacker (even a fully compromised production DBA credential) would need
to *also* compromise the archive system — a different set of credentials,
potentially a different team, ideally a different cloud account — to
erase their tracks completely, meaningfully raising the bar versus a
single-system hash chain alone. Periodic checkpointing of the archive's
hash-chain head to WORM storage anchors it against even a full archive-
database compromise, for the same reason external anchoring was flagged as
the stronger alternative in Q38.

**Alternative approaches:**
For compliance regimes requiring even stronger guarantees, some
organizations checkpoint the hash-chain head to a public, third-party-
verifiable ledger (a public blockchain, or a trusted timestamping
authority) rather than just internal WORM storage — this proves "this hash
existed at this time" to an *external* party with no access to (and no
motive to protect) the organization's own infrastructure, which internal
WORM storage alone cannot prove as convincingly to an outside auditor.

**Performance considerations:**
Logical replication of `audit_log` alone (not the whole database) keeps
the archive pipeline's overhead proportional to audit volume, not total
transaction volume — a `PUBLICATION` scoped to exactly one table (Q27)
is precisely the tool this architecture needs and physical replication
could not provide (physical replication would require shipping the entire
production database to the archive system).

> **Common mistakes:**
> - Treating "we have an audit_log table" as compliance-complete without
>   ever addressing who can write to it, who can delete from it, and
>   whether it lives anywhere an attacker with production access can't
>   reach — the table's existence and its tamper-*resistance* are
>   different claims.
> - Granting the archival replication process itself broad privileges on
>   production `banking_db` beyond exactly `SELECT` on `audit_log` — the
>   pipeline moving audit data to safety should not itself become a new,
>   broad access point into the production system (Q11's least-privilege
>   principle applies to the audit pipeline's own credentials too).

---

### Q48. Design a multi-currency, double-entry ledger extending `banking_db.transactions`, where "debits equal credits" is a database-enforced invariant, not an application hope.

**Answer:**
The current `transactions` table records each movement as a single signed
row against one account — sufficient for simple deposit/withdrawal
history, but it cannot *enforce* that a transfer's outflow and inflow are
both recorded together, nor represent a transaction touching accounts in
different currencies. A double-entry redesign:

```sql
CREATE TABLE ledger_transactions (          -- one row per business event (a transfer, a fee, a trade)
    ledger_txn_id BIGSERIAL PRIMARY KEY,
    description   VARCHAR(250),
    recorded_at   TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE ledger_entries (                -- two (or more) rows per ledger_transactions row
    entry_id       BIGSERIAL PRIMARY KEY,
    ledger_txn_id  BIGINT NOT NULL REFERENCES ledger_transactions(ledger_txn_id),
    account_id     INT NOT NULL REFERENCES banking_db.accounts(account_id),
    currency       CHAR(3) NOT NULL,
    amount         NUMERIC(14,2) NOT NULL,   -- signed: positive = debit, negative = credit (a fixed convention)
    exchange_rate_to_base NUMERIC(12,6) NOT NULL DEFAULT 1.0
);

-- The core invariant, enforced with a trigger (a cross-row SUM cannot be a plain CHECK constraint —
-- exactly the same limitation Q37 notes for overlap checks):
CREATE OR REPLACE FUNCTION enforce_balanced_ledger() RETURNS TRIGGER AS $$
BEGIN
    IF (SELECT SUM(amount * exchange_rate_to_base) FROM ledger_entries
        WHERE ledger_txn_id = NEW.ledger_txn_id) <> 0 THEN
        -- checked via a DEFERRED CONSTRAINT TRIGGER (fires at COMMIT, not per-row insert),
        -- since a balanced transaction's entries are necessarily inserted one at a time
        RAISE EXCEPTION 'ledger_txn_id % does not balance to zero', NEW.ledger_txn_id;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER check_balance
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_balanced_ledger();
```

A transfer of ₹10,000 from Ravi's account (1) to Neha's account (3)
becomes two `ledger_entries` rows under one `ledger_transactions` row:
`(account_id=1, currency='INR', amount=+10000)` and `(account_id=3,
currency='INR', amount=-10000)` — summing to zero, enforced at commit.

**Why it works:**
This is the actual accounting invariant (`debits = credits`, i.e., every
transaction's entries sum to zero) made **structurally impossible to
violate**, rather than an application convention that a bug or a partial
failure could break (crediting one account without debiting the matching
one — exactly the kind of partial-write bug Chapter 11's ACID guarantees
protect against *within* one statement, but not across a multi-step
application flow unless the schema itself enforces it). Using a **deferred
constraint trigger** (checked at `COMMIT`, not after each individual row
insert) is essential — the two (or more) entries of a balanced transaction
are necessarily inserted one row at a time, and checking the balance
immediately after the *first* row would always fail (it alone never sums
to zero).

**Alternative approaches:**
For genuinely high-throughput ledgers, some systems relax the real-time
enforced-at-commit check in favor of a periodic reconciliation job (`SUM
(amount) GROUP BY ledger_txn_id HAVING SUM(amount) <> 0` run continuously
or on a schedule) that *detects* imbalance after the fact rather than
*preventing* it at commit time — trading the strongest possible guarantee
for lower per-transaction overhead, a trade-off only acceptable when the
business can tolerate detecting (and manually correcting) a rare imbalance
rather than requiring it be structurally impossible.

**Performance considerations:**
The deferred trigger's `SUM()` over `ledger_entries` for a given
`ledger_txn_id` is cheap only if `ledger_txn_id` is indexed (it is, via
the foreign key) and each transaction has few entries (true for simple
transfers, less true for a complex multi-leg trade) — at very high
transaction volume, this per-commit aggregation is a real, measurable
cost weighed against the correctness guarantee it buys.

> **Common mistakes:**
> - Enforcing "debits equal credits" only in application code (compute
>   both entries, insert both, hope nothing fails in between) — this is
>   exactly the class of invariant that survives every test until a
>   partial failure (a crash between the two inserts, a bug in a rarely-
>   exercised code path) violates it in production, at which point the
>   ledger itself — the system of record — is silently wrong.
> - Using an ordinary (non-deferred) `CHECK`/trigger that fires per-row
>   instead of per-transaction — this cannot work at all for a
>   double-entry design, since no single row in a balanced pair sums to
>   zero on its own.

---

### Q49. Design a rate-limiter / idempotency-key store backed entirely by SQL — and give an honest answer about when SQL is *not* the right tool for this.

**Answer:**

```sql
CREATE TABLE rate_limit_buckets (
    client_id     TEXT NOT NULL,
    window_start  TIMESTAMP NOT NULL,     -- truncated to the bucket size, e.g. per-minute
    request_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (client_id, window_start)
);

-- Atomic "increment and check" — single statement, race-free (Q37/Chapter 12's lesson applied here)
INSERT INTO rate_limit_buckets (client_id, window_start, request_count)
VALUES (:client_id, date_trunc('minute', now()), 1)
ON CONFLICT (client_id, window_start)
DO UPDATE SET request_count = rate_limit_buckets.request_count + 1
RETURNING request_count;
-- Application: if request_count > limit, reject this request.

-- Cleanup: old buckets are simply irrelevant after their window passes —
-- partition by window_start (Chapter 26) and drop old partitions, or a periodic DELETE.
```

The idempotency-key half reuses exactly the design from Q35
(`idempotency_keys` table, TTL-purged, `ON CONFLICT DO NOTHING`).

**Why it works:**
`ON CONFLICT ... DO UPDATE SET request_count = ... + 1` performs the
increment-and-read atomically in one statement, closing the same
check-then-act race window Chapter 12/31 warn about repeatedly throughout
this course — two concurrent requests from the same client in the same
window cannot both read "0, under limit" and both proceed; the second
one's atomic increment sees the first one's already-applied result.

**Alternative approaches — and the honest answer about tooling:**
This works correctly at moderate request volumes, but a SQL table is
**not the right tool** once rate-limiting needs to happen at very high
frequency (thousands of checks per second per client, checked on
essentially every API call across a large fleet) — an in-memory store
(Redis, with `INCR`/`EXPIRE` or a Lua-scripted token-bucket) is
purpose-built for exactly this: sub-millisecond latency, no disk I/O, no
MVCC/vacuum overhead (Q3) from an extremely high-churn table whose rows
are, by design, thrown away within minutes of being written. The honest
engineering answer to "should this be in Postgres" is: **use Postgres if
rate-limiting state needs to be transactionally consistent with other data
you're already writing in the same transaction** (e.g., rejecting a
request and recording a business event atomically together) — use Redis
or a dedicated rate-limiting service if the limiter is a pure, isolated,
extremely high-frequency check with no other transactional coupling,
which describes most rate-limiters.

**Performance considerations:**
`rate_limit_buckets` is a textbook **hot-row/high-churn** table (Q3, Q36)
— every request against the same client hits the same row within a
window, and rows become garbage the instant their window closes. Without
aggressive autovacuum tuning (lower `autovacuum_vacuum_scale_factor`
specifically for this table) or time-based partitioning with partition
drops instead of row deletes, this table bloats disproportionately fast
relative to its useful data volume even by this course's own standards.

> **Common mistakes:**
> - Implementing rate limiting as "SELECT current count, check in
>   application code, then UPDATE if under limit" — the exact
>   check-then-act race this course warns about repeatedly (Chapter 12,
>   Chapter 31 §31.13), and it's just as real for a rate limiter as for an
>   inventory upsert.
> - Choosing PostgreSQL for a pure, high-frequency, no-other-transactional-
>   coupling rate limiter purely because "we already have Postgres" —
>   a legitimate operational simplicity argument at low-to-moderate scale,
>   but one that should be named as a deliberate trade-off, not assumed to
>   be free.

---

### Q50. Design a hotel/room booking system that structurally prevents double-booking the same room for overlapping date ranges — full schema, using the mechanism from Q37.

**Answer:**

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE hotels ( hotel_id SERIAL PRIMARY KEY, hotel_name VARCHAR(150), city VARCHAR(100) );

CREATE TABLE rooms (
    room_id    SERIAL PRIMARY KEY,
    hotel_id   INT NOT NULL REFERENCES hotels(hotel_id),
    room_number VARCHAR(20) NOT NULL,
    room_type  VARCHAR(50),
    UNIQUE (hotel_id, room_number)
);

CREATE TABLE guests ( guest_id SERIAL PRIMARY KEY, full_name VARCHAR(150), email VARCHAR(150) UNIQUE );

CREATE TABLE bookings (
    booking_id    SERIAL PRIMARY KEY,
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    guest_id      INT NOT NULL REFERENCES guests(guest_id),
    stay_period   daterange NOT NULL,   -- e.g. '[2026-03-10, 2026-03-14)' — half-open, so a checkout day can be a new checkin day
    status        VARCHAR(20) NOT NULL DEFAULT 'CONFIRMED' CHECK (status IN ('CONFIRMED','CANCELLED')),
    booked_at     TIMESTAMP NOT NULL DEFAULT now(),

    -- The core guarantee: no two CONFIRMED bookings for the same room can have overlapping stay periods
    EXCLUDE USING gist (room_id WITH =, stay_period WITH &&) WHERE (status = 'CONFIRMED')
);
```

**Why it works:**
This is Q37's overlap-prevention `EXCLUDE` constraint applied to the
canonical use case it's designed for. `daterange` with the default
half-open `[)` bound means a guest checking out on March 14th and a
different guest checking in the same March 14th do **not** count as
overlapping (`[10,14) && [14,18)` is false) — exactly matching how hotel
bookings actually work (a room can be turned over same-day). The `WHERE
(status = 'CONFIRMED')` clause on the exclusion constraint (a **partial**
exclusion constraint) means a `CANCELLED` booking's date range no longer
blocks new bookings for that room — without it, cancelling a booking would
permanently "reserve" that room/date combination against the exclusion
check forever, which is clearly wrong.

**Alternative approaches:**
An alternative to a hard database constraint is application-level
`SELECT ... FOR UPDATE` locking on the room plus a manual overlap query
before inserting a booking — this works, but (as Q37 notes generally)
requires every single code path that creates a booking, forever, to
remember to do the check-and-lock correctly; the `EXCLUDE` constraint
makes correctness a property of the schema rather than of every caller's
discipline, which is a strictly stronger guarantee for the small added
write-time cost of GiST maintenance (Q37).

**Performance considerations:**
The `WHERE (status = 'CONFIRMED')` partial constraint also keeps the GiST
index smaller and the constraint check cheaper over time (it never has to
consider historical cancelled bookings at all) — a booking system that
instead tried to enforce this with a full, non-partial exclusion
constraint would pay overlap-checking cost against an ever-growing set of
irrelevant cancelled rows.

> **Common mistakes:**
> - Using closed date ranges (`'[2026-03-10,2026-03-14]'`, inclusive on
>   both ends) instead of half-open — this makes a checkout day and the
>   next guest's checkin day count as an overlap, incorrectly rejecting
>   legitimate same-day turnover bookings that every real hotel needs to
>   support.
> - Forgetting the partial `WHERE (status = 'CONFIRMED')` clause — without
>   it, a cancelled booking's date range permanently blocks that room for
>   those dates, which silently makes cancelled inventory unbookable
>   forever.

## G. Production Incident Diagnosis

The final skill this tier tests is one no amount of syntax knowledge
substitutes for: reasoning from a vague symptom ("it's slow," "disk is
filling up," "errors started at 2 AM") to a short list of candidate causes,
in the right order, under time pressure. Each answer here models the
actual diagnostic sequence — what you check first, second, third — not
just the eventual root cause.

### Q51. "The database suddenly became extremely slow, and disk usage is climbing steadily with no obvious cause." What do you check, in order, and why that order?

**Answer:**
This is deliberately a symptom with several plausible causes from earlier
sections in this tier — the skill being tested is triage order, not just
knowing the list.

1. **Long-running or idle-in-transaction sessions first** (Q3) — because
   this is both the most common real-world cause and the one that, left
   unaddressed, makes every subsequent check look worse than it is (bloat
   accumulating, vacuum stalled). `SELECT pid, state, now() - xact_start,
   query FROM pg_stat_activity WHERE state = 'idle in transaction' OR
   xact_start < now() - interval '10 minutes' ORDER BY xact_start;` — a
   single ancient transaction found here often *is* the whole incident.
2. **Bloat and vacuum health** (Q3, Q8) — `pg_stat_user_tables` for
   `n_dead_tup`/`n_live_tup` ratios and `last_autovacuum` timestamps.
   Rapidly climbing disk with a normal write rate strongly suggests bloat
   outpacing cleanup — check whether #1 revealed the cause, or whether
   autovacuum itself is misconfigured/starved.
3. **Lock contention** — `SELECT * FROM pg_locks WHERE NOT granted;` and
   `pg_stat_activity.wait_event_type = 'Lock'` — a pile of queries waiting
   on locks presents as "everything is slow" even when no individual
   query is inherently expensive; often caused by the same long
   transaction from #1 holding locks the waiting queries need.
4. **Replication lag** (Chapter 30 §30.6, Q29) — if reads are routed to
   replicas, check `pg_stat_replication`/`pg_last_wal_replay_lsn()` on
   affected replicas; a lagging replica under heavy load can itself be
   the "slow" symptom users are experiencing, distinct from a primary
   problem.
5. **Checkpoint/I/O activity** (Q9) — `pg_stat_bgwriter` and the
   PostgreSQL log for checkpoint frequency/duration; an oversized,
   infrequent checkpoint colliding with the observed slowness window can
   explain a transient I/O-driven slowdown unrelated to bloat or locks.
6. **Transaction ID age** (Q2) — `age(relfrozenxid)` across large tables;
   if none of the above explain it and disk keeps climbing, check whether
   an anti-wraparound autovacuum is running (uncancellable, I/O-heavy, and
   easy to mistake for "the database is just broken").

**Why it works (this diagnostic order):**
Idle-in-transaction sessions and lock contention are checked first because
they're both the most common *and* the fastest to confirm/rule out (a
single query each), and because an ancient transaction is frequently the
underlying cause of #2 and #3 simultaneously — fixing it (or killing the
offending session) can resolve the incident before deeper investigation
into vacuum tuning or checkpoint settings is even needed.

**Alternative approaches:**
Some teams prefer starting from `EXPLAIN (ANALYZE, BUFFERS)` on the
specific slow query users are reporting, rather than a system-wide sweep —
valid when the complaint is scoped to one query/endpoint rather than
"everything," but the system-wide checklist above is the right first move
when the symptom is genuinely global ("the whole database," not "this one
report").

**Performance considerations:**
This entire diagnostic sequence is designed to be **cheap to run under
pressure** — every query listed reads from catalog/stats views, none of
them scan user data or add load to an already-struggling system, which
matters enormously when the system you're investigating is the one that's
currently in trouble.

> **Common mistakes:**
> - Jumping straight to `VACUUM FULL` (Q8) as a response to "disk is
>   filling up" without first checking for a blocking long transaction —
>   if one exists, `VACUUM FULL` can't reclaim anything it's blocked from
>   touching either, and now you've also taken an exclusive lock on
>   something during an active incident.
> - Restarting the database as a first response to "it's slow" — this
>   destroys the in-memory diagnostic state (`pg_stat_activity`'s current
>   picture, buffer cache contents) needed to actually diagnose the cause,
>   and, worse, can trigger an even slower crash-recovery WAL replay (Q5)
>   on top of whatever the original problem was.

---

### Q52. Nightly batch loads into `analytics_db.sales_fact` ran fine for years and started failing on January 1, 2025 with `ERROR: no partition of relation "sales_fact" found for row`. Diagnose and fix.

**Answer:**
This is a real, verifiable property of this course's own schema, not a
hypothetical: `databases/analytics_db.sql` defines `sales_fact` as `RANGE
(sale_date)` partitioned with exactly three partitions —
`sales_fact_2022` (`2022-01-01` to `2023-01-01`), `sales_fact_2023`, and
`sales_fact_2024` (`2024-01-01` to `2025-01-01`) — and **no partition
covering 2025 onward, and no `DEFAULT` partition** as a catch-all. The
instant a row with `sale_date >= '2025-01-01'` is inserted, PostgreSQL has
no partition to route it into and rejects the insert outright. This is not
corruption or a performance problem — it's a straightforward, entirely
predictable consequence of partition definitions being a fixed, static
list that nobody extended before the calendar caught up to them.

```sql
-- Immediate fix: create the missing partition
CREATE TABLE analytics_db.sales_fact_2025 PARTITION OF analytics_db.sales_fact
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
-- Retry the failed batch load — it now has somewhere to go.
```

**Why it works:**
RANGE partitioning requires every possible value of the partition key to
map to *some* partition at insert time — creating the 2025 partition
simply extends that mapping to cover the range that was missing, with no
effect on existing partitions/data.

**Alternative approaches — and why prevention matters more than the fix:**
The one-line fix above resolves the immediate outage, but the real fix is
**preventing recurrence**: either (a) add a `DEFAULT` partition
(`CREATE TABLE sales_fact_default PARTITION OF sales_fact DEFAULT;`) as a
safety net so future out-of-range inserts land somewhere queryable instead
of failing outright — though this trades a loud failure for a silent one
if nobody monitors the default partition's row count, which can itself
become a problem (Chapter 26 notes a populated default partition
complicates later splitting it into proper partitions); or (b), the more
robust production answer, automate partition creation well ahead of need
using `pg_partman` or a scheduled job that always maintains N periods of
future partitions, so this class of failure becomes structurally
impossible rather than something a human has to remember every December.

**Performance considerations:**
This is precisely the risk flagged in Q24 (backup strategy) and Q43
(scaling `sales_fact` further) — partition-boundary maintenance is an
operational responsibility that doesn't announce itself as a performance
problem in advance; it manifests as a sudden, total insert failure with
zero warning, which is exactly why it needs proactive automation/alerting
rather than reactive fixing after the first failed batch job.

> **Common mistakes:**
> - Treating this as a one-time fix ("create 2025, done") without also
>   creating 2026 in advance or setting up automated partition maintenance
>   — the identical failure recurs on schedule, one year later, unless the
>   root cause (manual, un-automated partition creation) is addressed.
> - Adding a `DEFAULT` partition as the *only* fix and considering the
>   problem solved — rows silently accumulating in a default partition
>   with no per-range index/constraint benefits defeats much of the
>   purpose of partitioning in the first place, and migrating rows out of
>   a populated default partition later is more work than just creating
>   partitions ahead of time would have been.

---

### Q53. A read replica's lag jumps from single-digit milliseconds to over 10 minutes immediately after a marketing campaign drives a traffic spike — but the primary looks completely healthy. Diagnose.

**Answer:**
Because the primary is healthy, the cause is specific to the **replica's**
capacity to *apply* WAL, not to how much WAL the primary is generating in
absolute terms (Chapter 30 §30.6's three causes, applied in order):

1. **Replica read load competing with WAL apply** — if this replica also
   serves read-scaling traffic (Chapter 30 §30.4) and the campaign
   drove a surge in read queries routed to it, the CPU/I/O that traffic
   consumes directly competes with the WAL-replay process's own CPU/I/O
   needs — check the replica's own CPU/IO utilization and active query
   count during the lag window, independent of the primary.
2. **A single large transaction on the primary** — a campaign-related
   bulk operation (a large `UPDATE`/`INSERT` from an analytics or
   promotions job kicked off alongside the campaign) generates a
   correspondingly large burst of WAL that must be replayed serially on
   the replica before replay can catch up to more recent, smaller
   transactions — check the primary's recent transaction sizes/WAL
   generation rate around the lag's onset, not just its current health.
3. **Network saturation between primary and replica** — a traffic spike
   that also increases *inter-region* bandwidth usage (if application
   traffic and replication share network capacity) can starve the
   replication stream specifically, even while the primary's own query
   performance looks unaffected.

**Why it works (as a diagnostic principle):**
"The primary looks healthy" is the key clue that rules out an entire class
of causes (primary overload, primary-side lock contention) and correctly
focuses attention on the replica's *own* resource contention or the
*shape* (not just volume) of recent write traffic — lag is fundamentally
about whether the replica can keep pace with applying a given WAL volume,
which depends on the replica's own capacity, not solely the primary's.

**Alternative approaches:**
If the replica is confirmed CPU/IO-saturated by read traffic (#1), the
structural fix isn't a one-time investigation but a capacity/routing
change: either provision the replica with more resources, add another
replica to spread read load across more machines, or (if this replica is
specifically designated for low-lag failover purposes) stop routing
read-scaling traffic to it at all and dedicate a *separate* replica pool
for reporting/analytics reads — separating the "must stay caught-up"
replica's role from the "absorbs arbitrary read load" role.

**Performance considerations:**
This is exactly why Chapter 30 stresses that lag must be **alerted on
continuously**, not glanced at occasionally — a replica silently absorbing
increasing read load over weeks as traffic grows can cross from
"comfortably keeping up" to "suddenly can't keep up under a spike" with no
single obvious trigger event unless lag trends were being tracked
beforehand.

> **Common mistakes:**
> - Assuming replica lag always means "something is wrong with
>   replication" and investigating network/WAL-shipping configuration
>   first, when the more common cause is simply the replica running out
>   of its own spare CPU/IO capacity under increased read load.
> - Permanently over-provisioning every replica "just in case" instead of
>   identifying which replicas are read-scaling targets (need spare
>   capacity headroom) versus dedicated low-lag failover candidates (need
>   to be protected from arbitrary read load) and provisioning/routing
>   each role differently.

---

### Q54. Deadlock errors spike sharply right after a routine deploy, on a code path that hasn't logically changed. Diagnose.

**Answer:**
Since the *business logic* didn't change, the most likely cause is an
incidental change to **lock acquisition order** introduced by something
that looks unrelated: a reordered set of `UPDATE` statements in the same
transaction, a new ORM version that changed the order in which related
rows are fetched/locked, or a newly-added index/trigger that causes a
statement to now touch (and lock) an additional row or table it didn't
touch before. The classic textbook shape: Transaction A updates
`banking_db.accounts` row 1 then row 3; Transaction B (a *different* code
path, or the same one hitting rows in a different natural order due to
input ordering) updates row 3 then row 1 — each holds a lock the other
needs, and PostgreSQL's deadlock detector kills one after
`deadlock_timeout`. A recent deploy that changed *which order* a batch
operation iterates over multiple rows (e.g., switched from
`ORDER BY account_id` to no explicit order, now relying on
insertion/physical order which can differ between environments or after
an index rebuild) is a very common, subtle root cause.

**Why it works (as a diagnostic principle):**
Deadlocks are fundamentally about **inconsistent lock acquisition order
across concurrent transactions**, not about any single transaction being
"wrong" in isolation — a code change that's functionally correct on its
own can still introduce a deadlock purely by changing the *sequence* in
which rows are touched relative to another, unrelated code path that
touches the same rows in the opposite order. `SELECT * FROM pg_locks`
during an active deadlock, and PostgreSQL's log (`log_lock_waits = on`
plus the deadlock detector's own log entries, which include both
transactions' queries and the exact rows/locks involved) are the direct
evidence — comparing the two transactions' row-touch order in that log
output against the pre-deploy code's behavior usually reveals the change
immediately.

**Alternative approaches:**
The durable fix, once the inconsistent ordering is identified, is to
enforce a **consistent lock acquisition order** across every code path
that can touch the same set of rows concurrently — e.g., always
`ORDER BY account_id` before iterating and updating multiple accounts in
one transaction, regardless of the order the business logic naturally
produces them in. An alternative, lower-effort mitigation (not a fix)
is enabling automatic retry-on-deadlock at the application layer
(`SQLSTATE 40P01`) — deadlocks can never be fully eliminated in a
system with any concurrent multi-row transactions, so a retry path is
good practice regardless, but it papers over rather than resolves an
avoidable ordering inconsistency.

**Performance considerations:**
Deadlock detection itself has a cost (`deadlock_timeout`, default 1
second, is how long a waiting transaction sits before PostgreSQL runs its
deadlock-graph check) — a sudden spike in deadlocks means a spike in
transactions sitting blocked for a full second-plus before being killed
and retried, which is a real latency and throughput cost distinct from
the eventual error itself.

> **Common mistakes:**
> - Treating each deadlock as an isolated, tolerable "sometimes this
>   happens" event without correlating the *timing* of a spike against
>   recent deploys — a sudden rate change, as described here, is a strong
>   signal pointing at a specific recent code change rather than random
>   background noise.
> - Fixing a deadlock by adding `NOWAIT` or a shorter lock timeout to make
>   the symptom "go away" faster, without addressing the underlying
>   inconsistent lock ordering — this converts a deadlock (both
>   transactions eventually resolve, one via rollback) into a
>   `lock_timeout` error under slightly different timing conditions, the
>   same root cause wearing a different error message.

---

### Q55. "Too many connections" errors start appearing under completely normal traffic levels — nothing has scaled up. Diagnose.

**Answer:**
Since traffic is normal, the cause is a change in how connections are
being **held**, not a change in how many requests are arriving. Checked in
order:

1. **A connection leak** — application code (often after a recent deploy,
   or an error-handling path that doesn't reach a `connection.close()`/
   pool-return call on an exception) opening connections faster than it
   releases them. `SELECT count(*), state FROM pg_stat_activity GROUP BY
   state;` — a large and *growing* count of `idle` (not `idle in
   transaction`, just plain `idle`) connections over time, with no
   corresponding drop, points here directly.
2. **Idle-in-transaction connections holding pool slots** (Q3's
   pathology, viewed from the connection-count angle rather than the
   vacuum angle) — the same forgotten-transaction problem that causes
   bloat also occupies a connection slot for its entire (potentially
   unbounded) duration; a pool sized for "normal traffic × normal
   connection hold time" is exhausted quickly if hold time silently grows.
3. **PgBouncer (or equivalent pooler) misconfiguration** — if the
   application connects through a pooler in what's *supposed* to be
   transaction-pooling mode but a driver/ORM feature (a session-level
   `SET`, a prepared statement, an advisory lock) forces it into
   session-pinning behavior, the effective number of pooled connections
   collapses toward one-per-client-connection, defeating the pooler's
   entire purpose without any error being raised about it.
4. **`max_connections` itself lowered or a competing workload added** —
   confirm nothing changed on the configuration side (a resize, a config
   management change) or that a new, unrelated service didn't start
   connecting to the same database and consuming from the same
   connection budget.

**Why it works (as a diagnostic principle):**
"Normal traffic, connection exhaustion anyway" isolates the problem to
*connection lifecycle*, not *request volume* — the fix is never "add more
`max_connections`" as a first response (that just delays the same leak
from exhausting a larger ceiling) but finding what's holding connections
open longer than intended.

**Alternative approaches:**
`idle_in_transaction_session_timeout` and a client-side connection-pool
`max_lifetime`/leak-detection setting (many connection pool libraries,
e.g., HikariCP-style pools, log a warning when a connection is checked out
longer than a configured threshold) are blunt-but-effective safety nets
that bound the *damage* of a leak while the actual leaking code path is
found and fixed — genuinely complementary to, not a substitute for, fixing
the root cause.

**Performance considerations:**
Simply raising `max_connections` as a quick fix has a real, often
overlooked cost: each PostgreSQL backend process has its own memory
overhead, and a much higher `max_connections` under a genuine leak just
means the leak takes longer to become visible while consuming
proportionally more server memory in the meantime — treating the symptom
this way frequently converts a fast, obvious failure into a slower,
harder-to-diagnose one.

> **Common mistakes:**
> - Raising `max_connections` as the first response without checking
>   `pg_stat_activity` for what's actually holding connections — this
>   masks a leak rather than fixing it, and the incident recurs at a
>   higher connection count later.
> - Not distinguishing `idle` from `idle in transaction` when reading
>   `pg_stat_activity` — the two point at different root causes (a
>   connection-pool/application leak vs. an abandoned transaction) and
>   the fix for one does nothing for the other.

---

## Summary

This tier contains **55 fully-answered expert-level questions** across
seven areas: Database Internals & MVCC (10), Security & Access Control
(8), Backup/Recovery & Disaster Recovery (6), Replication & High
Availability (7), Advanced Patterns synthesis (9), System Design & Schema
Design (10 open-ended design questions with full model answers), and
Production Incident Diagnosis (5). Together with the Beginner,
Intermediate, and Advanced tiers, this closes the 250+-question interview
bank referenced in the README's roadmap. A candidate comfortable
explaining every "Why it works" and "Alternative approaches" section in
this file — not just the "Answer" — is operating at the level this course
set out to reach: someone who can build, secure, scale, and defend a
production-grade relational schema, not just write correct queries against
one.






