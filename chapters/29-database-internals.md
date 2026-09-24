# Chapter 29 — Database Internals (Storage, MVCC, WAL, Vacuum)

> Part VI — Database Internals & Production Engineering
> Database used throughout: **`banking_db`** (`customers`, `accounts`, `transactions`, `loans`, `audit_log`)
> Prerequisite: run `psql -f databases/banking_db.sql` before working through this chapter.
> Builds directly on: **Chapter 11** (ACID, isolation levels), **Chapter 12** (locks), **Chapter 28** (WAL's role in
> backup/recovery). This chapter is **PostgreSQL-primary** — internals content is where dialects diverge most, and
> PostgreSQL's architecture (heap storage + MVCC via multiple tuple versions) is the concrete model used throughout,
> with `[MySQL]`, `[Oracle]`, and `[SQL Server]` called out wherever their internal mechanisms genuinely differ.

---

## 29.1 Why This Chapter Exists

Every earlier chapter treated the database as a black box that honors a contract: run a query, get correct rows;
run a transaction, get ACID guarantees. That contract is real, but it is not magic — it is implemented by specific,
inspectable machinery: fixed-size pages on disk, an in-memory cache of those pages, a append-only log that is
written before anything else, and a scheme for keeping multiple versions of the same row around so that readers and
writers never have to wait on each other.

Chapter 11 told you that PostgreSQL implements rollback "using MVCC" and Durability "using WAL," and left the
mechanics for here. Chapter 12 told you which locks block which operations, but not why PostgreSQL's `SELECT`
statements almost never need a lock at all. This chapter closes both loops. By the end of it, you should be able to
explain, precisely and without hand-waving:

- Why an `UPDATE` in PostgreSQL never actually overwrites a row in place, and what happens to the old version.
- Why a `SELECT` never blocks behind a concurrent `UPDATE` on the same row.
- Why a table can grow physically larger than its data "should" require, and what to do about it.
- Why a crash one millisecond after `COMMIT` returns still cannot lose that transaction's data.
- Why a single long-idle transaction can quietly degrade an entire production database.

This is the difference between *using* a database and *operating* one — the skill this course's roadmap calls
"Database Internals & Production Engineering."

---

## 29.2 Storage Engines

### 29.2.1 The Concept

**Simple explanation:** a storage engine is the part of the database software responsible for the physical
questions: how is a row actually laid out as bytes, how are those bytes grouped into files, and how does the engine
find a given row again quickly on disk. Everything above the storage engine — the SQL parser, the query planner,
the executor — treats storage as a service it calls; the storage engine is the thing that actually touches disk.

**Technical explanation:** in PostgreSQL, there is exactly **one** built-in storage engine, referred to as **heap
storage**. Every ordinary table (`accounts`, `transactions`, `customers`, and so on) is stored as a *heap* — an
unordered collection of fixed-size pages containing tuples, with row order determined by insertion and update
history, not by any key. Indexes are separate structures (B-trees, etc., covered in Chapter 16) that point back
into the heap by physical location. There is no notion, built into PostgreSQL itself, of choosing a different
physical storage format per table the way you might choose a different file format for different data.

**Why it exists this way:** PostgreSQL's architecture couples the storage layer tightly to its MVCC implementation
(§29.6) — tuple visibility is decided by inspecting header fields (`xmin`/`xmax`) stored directly in the heap tuple
itself. Because MVCC is baked into the one storage format, there has historically been little architectural need
(or an enormous amount of engineering cost) to support genuinely swappable, alternative on-disk row formats — the
visibility machinery, WAL format, and heap layout are one coherent design, not a pluggable interface. (PostgreSQL
does support pluggable **table access methods** as an extension point since v12 — e.g., columnar storage extensions
exist — but this is a narrower, less commonly used mechanism than MySQL's storage engine pluggability below, and the
built-in, default, and overwhelmingly common case remains the single heap engine.)

### 29.2.2 [MySQL] Genuinely Pluggable Storage Engines

MySQL's architecture is different at a fundamental level: the SQL layer (parser, optimizer, replication) is
decoupled from the storage layer via a real internal API, and different tables in the *same* database can use
different storage engines simultaneously, declared with `ENGINE=...` on `CREATE TABLE`.

| Engine | Transactions | Row-level locking | Foreign keys | Crash recovery | Typical use today |
|---|---|---|---|---|---|
| **InnoDB** (default since MySQL 5.5) | Yes (full ACID) | Yes | Yes | Yes, via its own redo/undo logs | Default for essentially everything |
| **MyISAM** (legacy default) | No | No — table-level locking only | No | No (no crash-safe redo log) | Legacy tables, some read-mostly/full-text-search-only workloads |

**Why InnoDB replaced MyISAM as the default:** MyISAM predates MySQL's transactional ambitions. It locks the
**entire table** for writes (a single writer blocks every other reader and writer on that table), has no undo/redo
log so a crash mid-write can leave a table corrupted and require repair, and supports neither transactions nor
foreign key constraints — meaning MyISAM cannot give any of the ACID guarantees from Chapter 11 at all. InnoDB
provides row-level locking (so unrelated rows in the same table can be written concurrently), full transactional
support with commit/rollback, crash recovery via redo logs, and referential integrity via foreign keys. As
applications increasingly needed correctness guarantees rather than just raw single-writer throughput, InnoDB
became the sensible universal default, and MySQL made it the default engine starting with version 5.5 (2010).

**InnoDB's internal design, for later comparison in §29.7:** InnoDB tables are stored as a **clustered index** —
the table's primary key *is* the physical row storage order (rows are physically sorted by primary key), and
secondary indexes store the primary key value rather than a physical row pointer. InnoDB implements MVCC not by
keeping multiple full row versions in the table itself (as PostgreSQL does) but via **undo logs**: the table stores
only the current version of each row, and older versions needed by concurrent readers are reconstructed on demand
by applying undo-log records backward. This distinction matters and is revisited in the MVCC comparison table in
§29.7.6.

### 29.2.3 [Oracle] and [SQL Server]

> **[Oracle]** Has one primary storage engine architecture, built around **tablespaces**, **data files**, and
> **undo segments** (used for its own MVCC-style read consistency, and for rollback). Oracle does not expose a
> MySQL-style "choose your storage engine per table" concept — physical storage options (compression, partitioning
> schemes) are configured *within* the one engine, not by swapping engines entirely.
>
> **[SQL Server]** Similarly has one primary storage engine (the relational "Storage Engine" component of the
> Database Engine), with row-store and columnstore as *index/table organization options* within that engine (much
> like PostgreSQL's pluggable table access method extension point), rather than fundamentally different, swappable
> engines with different transactional semantics the way MyISAM and InnoDB differ from each other.

> **Important Notes**
> "Pluggable storage engines" is a MySQL-specific architectural feature, not a general RDBMS concept. When someone
> says "which storage engine does PostgreSQL use," the honest answer is "heap storage — there isn't a choice to
> make," which is a legitimately different answer than the equivalent MySQL question.

---

## 29.3 Pages / Blocks

### 29.3.1 Simple Explanation

A table's data isn't stored as one continuous stream of rows. It's chopped up into fixed-size chunks — like a book
divided into pages of a fixed length rather than one unbroken scroll of text. The database always reads and writes
in whole-page units, never in units smaller than a page, even if you only asked for one column of one row.

### 29.3.2 Technical Explanation

**[PostgreSQL]** organizes every table and index into **pages** (also called **blocks**), each **8 KB by default**
(`BLCKSZ`, set at compile time — changing it requires recompiling PostgreSQL, so in practice 8 KB is what you get).
A table's on-disk file is simply a sequence of these 8 KB pages, numbered from 0. Each page has:

```
┌─────────────────────────────── 8 KB page ───────────────────────────────┐
│ PageHeaderData (24 bytes: checksum, free-space pointers, page version)  │
├───────────────────────────────────────────────────────────────────────┤
│ Item Pointers ("line pointers") — array grows downward, one per tuple  │
│   [1] → offset 8100   [2] → offset 8020   [3] → offset 7950  ...       │
├───────────────────────────────────────────────────────────────────────┤
│                         (free space, shrinks as tuples are added)      │
├───────────────────────────────────────────────────────────────────────┤
│ Tuple data — grows upward from the bottom of the page                  │
│   [Tuple 3 bytes] [Tuple 2 bytes] [Tuple 1 bytes]                      │
└───────────────────────────────────────────────────────────────────────┘
```

The **line pointer** array is the layer of indirection that makes MVCC and `VACUUM` possible without rewriting
every reference to a row every time it moves: an index entry points to a `(page_number, line_pointer_index)` pair
— called a **CTID** in PostgreSQL — not directly to a byte offset, so the tuple bytes can shift around within the
page (or be marked dead and reused) without invalidating anything that points at the line pointer.

### 29.3.3 Why Fixed-Size Pages Exist

Two independent forces both point to the same design:

1. **Amortizing I/O cost.** Reading from disk (even fast SSDs) has a fixed per-operation overhead in addition to a
   per-byte cost. Reading one page's worth of data costs barely more than reading a handful of bytes, so the engine
   always reads/writes in page-sized units and caches whole pages, giving you "the next 20 rows on this page" for
   free once you've paid for the first row's I/O.
2. **Aligning with OS and filesystem block sizes.** Operating systems and filesystems also manage disk I/O in fixed
   blocks (commonly 4 KB). PostgreSQL's 8 KB page is a clean multiple of the OS's block size, so a single page read
   or write maps cleanly onto whole underlying OS-level I/O operations instead of straddling boundaries awkwardly.

### 29.3.4 Example — `banking_db.accounts` in Pages

`accounts` has 7 seed rows, each easily under 100 bytes. All 7 comfortably fit on a single 8 KB page — a `SELECT *
FROM banking_db.accounts` in this course reads exactly **one page** from disk (or from cache). As the table grows
to millions of rows (imagine `banking_db` at production scale), it spans thousands of pages, and this is precisely
why indexes (Chapter 16) exist: they let the engine jump straight to the few relevant pages instead of scanning all
of them.

```sql
-- [PostgreSQL] see exactly how many pages a table currently occupies
SELECT relname, relpages, reltuples
FROM   pg_class
WHERE  relname = 'accounts';
--  relname  | relpages | reltuples
--  accounts |        1 |         7
```

> **Important Notes**
> A row that is too wide to fit on a page at all (very large `TEXT`, `JSONB`, or `BYTEA` values) is not force-fit
> in place. PostgreSQL transparently moves oversized column values out-of-line into a side table via **TOAST** (The
> Oversized-Attribute Storage Technique), storing only a small pointer in the main tuple. This is outside this
> chapter's scope in depth (see Chapter 25, Advanced Data Types) but explains why a table with a handful of huge
> `JSONB` columns can have far more physical storage behind it than `relpages` on the main table alone suggests.

---

## 29.4 Rows / Tuples

### 29.4.1 Simple Explanation

What you think of as "a row" — `account_id = 1, balance = 150000.00` — and what PostgreSQL physically stores are
not the same thing. Physically, PostgreSQL stores **tuples**: one tuple is one *version* of a row's data at a point
in time, tagged with bookkeeping about which transaction created it and (if applicable) which transaction replaced
it. A single logical row can have several tuple versions coexisting on disk simultaneously.

### 29.4.2 Technical Explanation — Tuple Structure

Every heap tuple consists of a fixed **tuple header** followed by the actual column data:

```
┌──────────────────────── HeapTupleHeaderData ────────────────────────┐
│ t_xmin      (4 bytes) — transaction ID that CREATED this version    │
│ t_xmax      (4 bytes) — transaction ID that DELETED/SUPERSEDED it,  │
│                          or 0 / invalid if this version is current  │
│ t_cid       (cmin/cmax) — command ID within the creating/deleting   │
│                          transaction (distinguishes statements       │
│                          within the same multi-statement txn)        │
│ t_ctid      (6 bytes) — pointer to the NEXT version of this row      │
│                          (itself, if this is the current version)    │
│ infomask flags — committed/aborted hint bits, "is this a HOT         │
│                          (heap-only tuple) update", null bitmap, etc.│
├───────────────────────────────────────────────────────────────────┤
│                     actual column data (account_id, balance, ...)   │
└───────────────────────────────────────────────────────────────────┘
```

`xmin` and `xmax` are the two fields that make MVCC possible (§29.7) — they turn "is this row visible to me" into a
comparison of transaction ID numbers rather than a question of locking.

### 29.4.3 Why It's Built This Way

Storing visibility metadata *inside every tuple*, rather than in a separate central lock table, means visibility
can be determined by reading the tuple itself plus a small, cheap snapshot structure — no shared lock table needs
to be consulted or contended for on every single row read. This is the structural reason PostgreSQL's `SELECT`
statements can proceed without taking row locks: visibility is a self-contained computation over data already in
hand.

### 29.4.4 Multiple Versions, One Logical Row

Because an `UPDATE` never overwrites a tuple's bytes in place, a single logical row (`account_id = 1`) can have
several tuple versions physically present in the heap at once — some visible to some transactions, some not,
some entirely dead and awaiting cleanup. This is the on-ramp to MVCC, covered next in full depth.

```
Page 0 of banking_db.accounts, after several UPDATEs to account_id = 1:

Line Ptr 1 → Tuple A: xmin=100 (committed long ago), xmax=502 (committed) → SUPERSEDED, dead once nobody needs it
Line Ptr 2 → Tuple B: xmin=502 (committed), xmax=NULL                     → CURRENT version, balance = 140000.00
```

---

## 29.5 Buffer / Cache

### 29.5.1 Simple Explanation

Reading from disk is slow compared to reading from RAM. So the database keeps a big chunk of memory set aside as a
cache of recently and frequently used pages, and only goes to disk when a page it needs isn't already sitting in
that cache.

### 29.5.2 Technical Explanation

**[PostgreSQL]** calls this the **shared buffer pool**, sized by the `shared_buffers` configuration parameter. It
is memory shared across *all* backend processes (every connection), holding whole 8 KB pages. When a query needs a
page, PostgreSQL first checks whether that page is already resident in `shared_buffers`; only on a **cache miss**
does it issue an actual disk read. Pages that have been modified in the buffer but not yet written back to the data
file are called **dirty buffers** — writing them back to disk is handled by the background writer and checkpointer
(§29.11), not synchronously on every write.

Beneath `shared_buffers` sits a second, larger cache layer: the **OS page cache**, maintained by the operating
system itself, independent of PostgreSQL. A page evicted from `shared_buffers` due to memory pressure is often
still sitting in the OS page cache, so even a "miss" in PostgreSQL's own buffer pool frequently resolves without a
real physical disk read.

```
Query needs page 42 of accounts
        │
        ▼
  shared_buffers (PostgreSQL) ── HIT?  → return page, no disk I/O
        │ MISS
        ▼
  OS page cache ──────────────── HIT?  → fast copy from RAM, no physical disk I/O
        │ MISS
        ▼
  Physical disk/SSD read (slowest path)
```

### 29.5.3 Why This Exists

Without a buffer cache, every single row read would require a physical disk operation, even for data queried a
thousand times a second (like `banking_db.accounts`, checked on every deposit/withdrawal). Caching frequently
accessed pages in RAM is the single highest-leverage performance mechanism in the entire database — it's why a
well-tuned OLTP database serving a busy `accounts` table can answer most reads in microseconds rather than
milliseconds.

> **Common Mistake**
> Setting `shared_buffers` far too large (e.g., most of system RAM) is a frequent misconfiguration. Because the OS
> page cache is a second, independent caching layer beneath PostgreSQL's own, an oversized `shared_buffers` starves
> the OS cache and can cause **double buffering** — the same page cached redundantly in both layers — wasting
> memory rather than using it efficiently. A commonly cited starting point is roughly 25% of system RAM, tuned from
> there based on measured workload behavior, not set to the largest number available.

---

## 29.6 Write-Ahead Logging (WAL) — In Depth

Chapter 28 introduced WAL as the mechanism behind durability and crash recovery at a conceptual level. This section
goes further: the exact rule WAL enforces, why checkpoints exist, and what recovery actually replays.

### 29.6.1 The Fundamental Rule

**Simple explanation:** before the database makes any real change to its data files, it first writes down, in an
append-only log, exactly what it's about to do. Only after that log entry is safely on disk does it dare to
actually touch the data files — and even then, it can take its time.

**Technical explanation, precisely stated:**

> **A change is never considered durable until its WAL record has been flushed to disk.** The corresponding data
> file page can be written back to disk **lazily, at any later time** — because if the server crashes before that
> lazy write happens, the already-durable WAL record can simply be replayed on restart to reconstruct the change.

This inverts the naive intuition that "the data file is the truth and the log is just a backup of it." In
PostgreSQL, for any change that hasn't yet been checkpointed, **the WAL is the more current, more trustworthy
record** — the data file may still reflect an old, pre-update state, entirely by design.

### 29.6.2 Why This Design Exists

The alternative — flushing every changed data page to disk synchronously before acknowledging a commit — would be
disastrous for performance: a single `UPDATE` to one row in `banking_db.accounts` might dirty a page containing
dozens of unrelated rows, and flushing whole 8 KB random-access pages to disk on every commit is far slower than
appending a small, sequential WAL record. WAL converts durability into a **sequential-write** problem (fast, even
on spinning disks, since the log is appended to, never randomly seeked) instead of a **random-write** problem
(slow), while still making a rock-solid crash-recovery guarantee.

### 29.6.3 Worked Example — `banking_db` Transfer

```
Session A: BEGIN; UPDATE accounts SET balance = balance - 10000 WHERE account_id = 1; COMMIT;
```

```
Time →

  [1] UPDATE runs.  New tuple version built in shared_buffers (page still "dirty" — not on disk yet).
  [2] WAL record describing this change is appended to the WAL buffer.
  [3] COMMIT requested. PostgreSQL flushes the WAL record (and a commit record) to disk — fsync().
  [4] COMMIT returns "success" to the client.  ← durability is now guaranteed, from this instant.
  [5] ... arbitrary time passes ...
  [6] Later: the background writer or checkpointer flushes the dirty accounts page to the actual
      data file on disk.  This can happen seconds, or in some configurations, much longer after [4].
```

If the server crashes at any point between **[4]** and **[6]**, the change to account 1's balance is **not yet** in
the data file — but it doesn't need to be. On restart, PostgreSQL's recovery process replays WAL starting from the
last checkpoint, re-applies the change described by the WAL record from step [2]/[3], and account 1's balance is
correctly `140000.00` again, exactly as promised at commit time. This is precisely the mechanism Chapter 11 §11.4.4
referenced without detail.

### 29.6.4 Checkpoints

**Simple explanation:** a checkpoint is a promise, written down and dated, that says "everything committed before
this point is now safely and completely reflected in the actual data files, not just the log." Once that promise
is made, older WAL doesn't need to be kept around (or replayed) anymore.

**Technical explanation:** a **checkpoint** is a point in the WAL stream at which PostgreSQL guarantees that *all*
data file changes described by WAL up to that position have actually been flushed to disk. Reaching a checkpoint
involves the checkpointer process writing out every dirty buffer that corresponds to WAL up to that point, then
recording the checkpoint's WAL position (an LSN — Log Sequence Number) in a control file.

```
WAL Timeline
────●────────────●────────────●────────────●─────────►  time
  CKPT₁         CKPT₂        CKPT₃        [CRASH]
    │             │            │              │
    │             │            └─ all data files durable up to here
    │             │                                    │
    │             └── WAL before CKPT₂ can be recycled/archived
    │                                                   │
    └── WAL this old is long gone                       │
                                                          ▼
                                          Recovery only needs to replay
                                          WAL from CKPT₃ forward — not
                                          from the beginning of time.
```

**Why checkpoints matter, precisely:** they **bound crash-recovery time**. Without checkpoints, recovering from a
crash would require replaying every WAL record ever generated since the database was created. With checkpoints,
recovery only needs to replay WAL generated *since the last checkpoint* — everything before it is already
guaranteed present in the data files. Checkpoint frequency is therefore a direct trade-off: frequent checkpoints
mean fast recovery but more overhead (constant background I/O flushing dirty pages); infrequent checkpoints mean
less overhead day-to-day but a longer WAL replay window (and thus longer recovery time) after a crash. This is
tuned via `checkpoint_timeout` (time-based) and `max_wal_size` (volume-based — whichever limit is hit first
triggers a checkpoint).

> **Important Notes**
> This section deliberately goes deeper than Chapter 28's treatment. Chapter 28 frames WAL primarily as the
> mechanism that makes **point-in-time recovery** and **continuous archiving** possible for backup/restore
> purposes. This chapter frames the *identical* mechanism from the angle of **every single transaction's crash
> durability**, which is the more fundamental, always-on reason WAL exists at all — backup/PITR is a valuable
> secondary use of the same log, not WAL's original purpose.

### 29.6.5 Cross-Dialect Note

> **[MySQL]** InnoDB has an equivalent **redo log** with the same fundamental rule (log flushed before commit
> acknowledged; data pages flushed lazily) and its own separate **undo log** for MVCC/rollback (§29.7.6).
> **[Oracle]** Uses **redo log files**, functionally analogous to WAL, plus separate **undo segments**, similar in
> spirit to PostgreSQL combining both roles differently across WAL and heap tuple versions.
> **[SQL Server]** Uses a **transaction log** (the `.ldf` file) enforcing the identical write-ahead rule; its
> recovery model (`SIMPLE`, `FULL`, `BULK_LOGGED`) controls how aggressively that log can be truncated, conceptually
> similar to PostgreSQL's `wal_level` and archiving settings from Chapter 28.

---

## 29.7 MVCC — Multi-Version Concurrency Control

This is the deepest section in the chapter, because MVCC is the single idea that most changes how you should think
about a PostgreSQL database compared to a naive "rows are just overwritten" mental model.

### 29.7.1 Simple Explanation

Instead of overwriting a row's data in place when it changes, keep **both** the old version and the new version
around for a while, and let each transaction see whichever version was current *when that transaction's view of the
database began*. Once nobody could possibly still need an old version, throw it away. The payoff: **readers never
have to wait for writers, and writers never have to wait for readers**, because they're never actually looking at
or fighting over the same physical bytes — a reader holding an old snapshot and a writer creating a new version are
simply working with two different tuples.

### 29.7.2 Technical Explanation

Every tuple carries `xmin` (the ID of the transaction that created it) and `xmax` (the ID of the transaction that
deleted or superseded it, or nothing if it's still current — see §29.4.2). Every transaction that reads data
acquires a **snapshot**: a description of "which transactions' effects should I consider to have already happened."
A snapshot is captured as roughly three pieces of information:

- **xmin** — the smallest transaction ID that was *still in progress* when the snapshot was taken. Anything older
  than this is guaranteed already finished (committed or aborted) as far as this snapshot cares.
- **xmax** — one past the highest transaction ID that had been *assigned* when the snapshot was taken. Any
  transaction ID at or above this didn't exist yet when the snapshot was taken, so its effects are always invisible
  to this snapshot, no matter what happens later.
- **xip list** — the specific set of transaction IDs that were in progress (started but not yet committed/aborted)
  at snapshot time, between `xmin` and `xmax`.

*When* the snapshot is taken is exactly what differs between isolation levels, and it's the mechanical explanation
behind behavior Chapter 11 described only observationally.

### 29.7.3 Why This Exists

The alternative to MVCC is a purely **locking-based** concurrency model: a reader takes a shared lock, a writer
needs an exclusive lock, and shared/exclusive locks conflict — meaning a long-running writer blocks every reader of
that row, and a long-running reader blocks every writer. This is exactly the "readers block writers, writers block
readers" behavior Chapter 12 discusses for explicit locks. MVCC sidesteps the conflict entirely for ordinary reads
and writes: because a writer creates a *new* tuple version rather than modifying the one a reader is looking at, the
reader's snapshot continues to see its own consistent version undisturbed, and the writer never has to wait for a
reader to finish looking at the old one either.

### 29.7.4 Concrete Walkthrough — `banking_db.accounts`, Transaction A and B

Setup: `account_id = 1` currently has `balance = 150000.00`, stored as tuple **T0** (`xmin = 100`, already
committed long ago; `xmax = NULL`).

```
Session A (txid 501)                          Session B (txid 502)
────────────────────────────────────────      ────────────────────────────────────────
BEGIN;
SELECT balance FROM accounts
  WHERE account_id = 1;
-- snapshot taken; sees T0 → reads 150000.00
                                               BEGIN;
                                               UPDATE accounts
                                                 SET balance = balance - 10000
                                                 WHERE account_id = 1;
                                               -- T0.xmax is set to 502 (superseded, NOT deleted)
                                               -- new tuple T1 created: xmin=502, xmax=NULL, balance=140000.00
                                               COMMIT;
                                               -- txid 502 recorded as committed in the commit log
SELECT balance FROM accounts
  WHERE account_id = 1;
-- second statement, same transaction -- what does A see now?
```

**Under READ COMMITTED** (PostgreSQL's default): each **statement** gets its own fresh snapshot at the moment that
statement begins. A's second `SELECT` takes a *new* snapshot — one in which txid 502 is now safely committed and
below the new snapshot's `xmax`. Under the visibility rule (§29.7.5), T0 is now invisible (its `xmax = 502` is a
committed transaction visible to this new snapshot, meaning T0 has been superseded as far as this snapshot is
concerned) and T1 is visible (its `xmin = 502` is committed and visible). **A's second SELECT returns `140000.00`**
— it sees B's committed change on its very next statement.

**Under REPEATABLE READ:** A's snapshot is taken **once, at `BEGIN`**, and reused for every statement in the
transaction. That original snapshot's `xmax` was set *before* txid 502 was even assigned, so txid 502 is treated as
"didn't exist yet" for the entire lifetime of A's transaction, regardless of when it actually commits. **A's second
SELECT still returns `150000.00`** — A continues to see the entire consistent world as it existed at the moment A's
transaction began, for as long as A's transaction remains open, even though T0 has been physically superseded on
disk in the meantime.

```
Tuple state in the page, immediately after B commits:

  Line Ptr 1 → T0: xmin=100 (committed), xmax=502 (committed)  ── still holds balance=150000.00 bytes
  Line Ptr 2 → T1: xmin=502 (committed), xmax=NULL              ── holds balance=140000.00 bytes

  A's REPEATABLE READ snapshot (xmax below 502) → sees T0, not T1 → reads 150000.00
  A fresh READ COMMITTED snapshot (xmax above 502) → sees T1, not T0 → reads 140000.00
```

This is the exact mechanism behind Chapter 11 §11.5.2/§11.5.3: "Read Committed re-reads per statement" and
"Repeatable Read holds one snapshot for the whole transaction" are not arbitrary rules — they are two different
policies for *when the xmin/xmax/xip snapshot triple gets captured*, applied to the identical underlying tuple
versioning mechanism.

### 29.7.5 Visibility — the Precise Rule

A transaction determines whether a given tuple version is visible to it by comparing that tuple's `xmin`/`xmax`
against its own snapshot, roughly as follows:

1. **Check the creating transaction (`xmin`):**
   - If `xmin` is aborted, or still in progress (in the snapshot's xip list), or was assigned *after* the
     snapshot's `xmax` (didn't exist yet) → the tuple **does not exist yet** as far as this snapshot is concerned.
     Not visible.
   - If `xmin` is committed, is below the snapshot's `xmax`, and is not in the xip list → the tuple **does exist**
     as far as this snapshot is concerned. Proceed to step 2.
2. **Check the deleting/superseding transaction (`xmax`):**
   - If there is no `xmax` (still `NULL`/invalid) → the tuple is current and undeleted. **Visible.**
   - If `xmax` is aborted, or still in progress, or was assigned after the snapshot's `xmax` → the deletion/update
     "hasn't happened yet" as far as this snapshot is concerned. **Visible.**
   - If `xmax` is committed, below the snapshot's `xmax`, and not in the xip list → the tuple **has been
     superseded** as far as this snapshot is concerned. **Not visible.**

This is, in effect, "was this row created before my view of time began, and — if it was later changed — did that
change also happen before my view of time began?" Every ordinary `SELECT` answers this question per-tuple using
only in-memory metadata (the tuple header plus the transaction commit log), never a shared lock.

### 29.7.6 Comparison — MVCC Across Dialects

| Dialect | MVCC mechanism | Where old versions live | Reader/writer blocking? |
|---|---|---|---|
| **[PostgreSQL]** | Multiple full **heap tuple versions**, each tagged `xmin`/`xmax`, coexisting in the table itself | In the same heap pages as the current version, until `VACUUM` reclaims them | Readers never block writers; writers never block readers (only writer-vs-writer on the same row blocks) |
| **[MySQL] (InnoDB)** | One current physical row per primary key (clustered index), older versions reconstructed on demand from **undo logs** | In a separate undo tablespace, applied backward to rebuild old versions | Readers (in Repeatable Read) don't block writers; consistent reads are built from undo, not from a second live row copy |
| **[Oracle]** | Similar in spirit to InnoDB: one current row, prior versions reconstructed from **undo segments** ("read consistency") | In dedicated undo segments/tablespaces | Readers do not block writers ("writers don't block readers, readers don't block writers" is an Oracle marketing point going back decades) |
| **[SQL Server]** | **Pessimistic locking by default** (no MVCC unless explicitly enabled) — readers take shared locks that genuinely conflict with writers' exclusive locks. Optional `READ_COMMITTED_SNAPSHOT` or `SNAPSHOT` isolation enables row versioning, storing prior versions in `tempdb` | `tempdb` version store, only when snapshot/RCSI is enabled | By default, readers **do** block writers and vice versa; only with versioning enabled does it behave like the others |

> **Important Notes**
> SQL Server is the outlier here: unlike PostgreSQL, MySQL/InnoDB, and Oracle — all of which are MVCC-native by
> default — SQL Server's out-of-the-box behavior is genuinely lock-based, and you must **opt in**
> (`ALTER DATABASE ... SET READ_COMMITTED_SNAPSHOT ON`, or enable `SNAPSHOT` isolation) to get MVCC-style behavior.
> This is a real, practical migration gotcha for teams moving between these engines.

### 29.7.7 Expected Behavior — What Actually Happens to the Old Tuple

To state it with no ambiguity: after `UPDATE accounts SET balance = balance - 10000 WHERE account_id = 1`,

- The **old tuple (T0)** is **not deleted, not overwritten, and not moved**. Its bytes remain exactly where they
  were, with `xmax` now set to the updating transaction's ID.
- A **brand-new tuple (T1)** is inserted (usually into the same page if there's room, otherwise a different page in
  the same table) with the new column values and `xmin` set to the updating transaction's ID.
- Any index on `accounts` gets a **new index entry** pointing at T1's physical location — the old index entry
  pointing at T0 is *not* immediately removed either.
- Both T0 and T1 physically exist on disk simultaneously until `VACUUM` determines T0 can never be visible to any
  present or future transaction and reclaims its space.

> **Common Mistake**
> Assuming `UPDATE` modifies a row "in place" the way it would in a simple in-memory data structure. This
> assumption leads directly to two downstream misunderstandings: surprise at table **bloat** (§29.9) when a
> high-`UPDATE` table grows far larger on disk than its live row count would suggest, and confusion about why a
> `SELECT` never seems to block behind concurrent updates — both are direct, mechanical consequences of the fact
> that `UPDATE` is really "insert a new version, mark the old one superseded," not "overwrite."

### 29.7.8 When This Knowledge Matters Practically

- **Diagnosing why `SELECT` never blocks:** you can now answer this precisely — a reader's snapshot simply refers
  to a different, already-existing tuple version than whatever a concurrent writer is creating, so there is no
  shared resource to contend over.
- **Understanding isolation levels as mechanism, not folklore:** Chapter 11's isolation-level behavior table is a
  direct consequence of *when* a snapshot's `xmin`/`xmax`/xip triple is captured — per-statement (Read Committed)
  vs. once per transaction (Repeatable Read/Serializable).
- **Capacity planning:** every `UPDATE`/`DELETE` is, physically, additional space consumption until vacuumed —
  this directly motivates the vacuum and bloat sections that follow.

---

## 29.8 Vacuum

### 29.8.1 Why It's Needed — A Direct Consequence of MVCC

**Simple explanation:** because `UPDATE` and `DELETE` never actually erase old data immediately (§29.7.7), old
("dead") tuple versions just pile up on disk. Something has to come along later and clean them up, or the database
would grow forever even if the live row count stayed constant.

**Technical explanation:** a `DELETE` in PostgreSQL does not remove a tuple's bytes — it simply sets that tuple's
`xmax` to the deleting transaction's ID, exactly like an `UPDATE` does to the version it supersedes. A tuple becomes
**dead** once its `xmax` is committed and older than every currently-active snapshot's horizon (i.e., no
transaction, present or future-at-current-moment, could ever legitimately need to see it). Dead tuples are inert
disk space until reclaimed.

### 29.8.2 What `VACUUM` Does

`VACUUM` scans a table's pages, identifies tuples that are dead (per the rule above), and:

1. Marks the space those dead tuples occupied as **reusable** within the page (via the Free Space Map), so future
   `INSERT`/`UPDATE` operations on that table can reuse the space without growing the file.
2. Removes the corresponding dead entries from the table's indexes.
3. Updates statistics used by the planner (when run as `VACUUM ANALYZE` or via autovacuum, which does both).
4. Advances the table's (and database's) "frozen" transaction ID horizon where possible — directly relevant to
   wraparound, §29.9.4.

Crucially, plain `VACUUM` **does not shrink the file on disk** in the common case — it makes space *inside* the
existing file reusable, but does not return that space to the operating system, because doing so safely while other
transactions might be reading the table requires far more disruptive work (below).

```sql
-- [PostgreSQL]
VACUUM banking_db.accounts;              -- reclaim space within the table for reuse
VACUUM ANALYZE banking_db.accounts;      -- also refresh planner statistics
VACUUM VERBOSE banking_db.accounts;      -- see exactly how many dead tuples were found/removed
```

### 29.8.3 `VACUUM` vs. `VACUUM FULL`

| | `VACUUM` | `VACUUM FULL` |
|---|---|---|
| Reclaims space for reuse **within** the table's existing file | Yes | Yes |
| Returns reclaimed space **to the operating system** (shrinks the file) | No | Yes |
| Lock required | None that blocks reads/writes (a lightweight lock that allows concurrent access) | **`ACCESS EXCLUSIVE`** — blocks all reads and writes on the table |
| Mechanism | In-place scan and mark | Rewrites the **entire table** into a new file, copying only live tuples, then swaps the new file in and drops the old one |
| Safe to run routinely in production | Yes — this is what autovacuum does continuously | Rarely appropriate without a maintenance window |

> **⚠️ Warning — `VACUUM FULL`'s exclusive lock**
> `VACUUM FULL` takes an `ACCESS EXCLUSIVE` lock on the table for its *entire* duration — every `SELECT`,
> `INSERT`, `UPDATE`, and `DELETE` against that table blocks until it finishes. On a large, actively used table like
> a production `accounts` table, this can mean minutes or hours of complete unavailability for that table. Running
> `VACUUM FULL` casually on a live production table is one of the most common self-inflicted outages in PostgreSQL
> operations — it is explicitly a maintenance-window operation, not a routine housekeeping command. This is why
> plain `VACUUM` (non-blocking) plus autovacuum is the standard ongoing strategy, and `VACUUM FULL` (or an
> online-rebuild tool such as `pg_repack`, which achieves a similar result without the long exclusive lock by
> building a copy and swapping it in with only a brief final lock) is reserved for cases where bloat has become
> severe enough that reclaiming disk space back to the OS is worth the disruption.

### 29.8.4 Autovacuum

**[PostgreSQL]** ships with a background process — the **autovacuum launcher**, which spawns **autovacuum
worker** processes — that runs `VACUUM` (and `ANALYZE`) automatically, per table, once the number of dead tuples
crosses a threshold, so that in normal operation nobody needs to run `VACUUM` by hand at all.

The key thresholds (configurable globally and per-table):

```sql
-- default-ish values, illustrative
autovacuum_vacuum_threshold      = 50     -- minimum dead tuples before considering a vacuum
autovacuum_vacuum_scale_factor   = 0.2    -- PLUS 20% of the table's live row estimate
-- a table is eligible for autovacuum once:
--   dead_tuples > autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * n_live_tup
```

For `banking_db.accounts` with 7 rows, that threshold is trivially low (~51 dead tuples). For a production accounts
table with 10 million live rows, the default scale factor means roughly **2 million dead tuples** must accumulate
before autovacuum triggers — a setting that is very frequently tuned down (a lower `autovacuum_vacuum_scale_factor`,
or a per-table override) on large, high-churn tables specifically to avoid the bloat scenario in §29.9.

```sql
-- [PostgreSQL] check current dead-tuple counts directly
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum
FROM   pg_stat_user_tables
WHERE  schemaname = 'banking_db';

-- [PostgreSQL] tune autovacuum aggressiveness for one high-churn table
ALTER TABLE banking_db.accounts
  SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_cost_delay = 2);
```

---

## 29.9 Dead Tuples and Bloat

### 29.9.1 Precisely What "Bloat" Means

**Bloat** is the condition where a table (or index) occupies **more disk space than its live data would require**,
because dead tuples (and their corresponding dead index entries) are accumulating faster than vacuum is reclaiming
them. Bloat is not a bug — it is the visible, physical residue of MVCC doing its job, when cleanup falls behind
creation.

### 29.9.2 How It Happens

- **A very high-`UPDATE`-frequency table.** Picture `banking_db.accounts.balance` in a production bank processing
  thousands of debits/credits per second. Every single balance update creates a brand-new tuple version and leaves
  the old one dead. If autovacuum's thresholds are too conservative for that update rate, dead tuples pile up faster
  than they're reclaimed, and the table's page count grows well beyond what 7 (or even 7 million) *live* rows
  should occupy.
- **A long-running transaction preventing cleanup.** Recall §29.7.5: a tuple is only truly dead once **no current
  or future transaction's snapshot could possibly need it**. If some other session opened a transaction hours ago
  and is still sitting open (an "idle in transaction" session, or a long analytical query), its old snapshot may
  still, technically, be entitled to see tuples that every other transaction considers long dead. Vacuum cannot
  reclaim those tuples — they are dead to everyone *except* that one ancient transaction — so cleanup for the
  *entire table*, or in the worst cases the entire database, stalls until that transaction finally ends.

### 29.9.3 Consequences

1. **Wasted disk space** — the table and its indexes consume more storage than the live data justifies, sometimes
   dramatically more (a bloated table can be several times its "should be" size).
2. **Slower scans** — every sequential scan, and even index-assisted lookups that must revisit heap pages, now has
   to read through pages full of dead tuples to find the live ones, directly increasing I/O and query latency (this
   connects directly to Chapter 17's planner cost model and Chapter 18's performance tuning — a bloated table skews
   both actual performance and the planner's row-count estimates if `ANALYZE` also falls behind).
3. **Degraded index efficiency** — indexes accumulate dead entries pointing at now-reclaimable heap tuples,
   growing the index itself and reducing the fraction of each index page occupied by entries that matter, which
   increases the number of index pages a lookup must traverse (Chapter 16).

### 29.9.4 Edge Case — Transaction ID Wraparound

> **⚠️ Warning — Transaction ID Wraparound**
> PostgreSQL transaction IDs (`xid`) are a **32-bit counter** — about 4.2 billion possible values, compared
> circularly (half "in the past," half "in the future" relative to any given point, much like clock arithmetic).
> If a table (or the whole database) is never vacuumed for long enough that more than roughly 2 billion
> transactions elapse without its oldest tuples being **frozen** (a special marker meaning "always in the past, no
> matter how far the counter advances"), the transaction ID counter can wrap around — and old, perfectly valid
> committed data can suddenly and catastrophically appear to be **from the future**, making it invisible to every
> snapshot. This is a real, historically documented cause of PostgreSQL databases appearing to "lose" data that was
> never actually deleted.
>
> Because this is too dangerous to leave to chance, PostgreSQL runs a more aggressive **anti-wraparound
> autovacuum** mode automatically as any table's oldest unfrozen transaction ID (tracked as `relfrozenxid`)
> approaches `autovacuum_freeze_max_age` (default around 200 million transactions) — this mode cannot be
> deferred or skipped and will consume I/O resources even during otherwise-quiet maintenance windows if left
> untuned. If wraparound risk is ignored entirely, PostgreSQL will, at roughly 1 billion transactions remaining
> before actual wraparound, refuse further writes to the affected database entirely ("database is not accepting
> commands to avoid wraparound data loss") until an administrator manually intervenes with a vacuum — a severe,
> self-inflicted, but entirely preventable outage.

### 29.9.5 Diagnosing Bloat

```sql
-- [PostgreSQL] quick dead-tuple ratio check
SELECT relname,
       n_live_tup,
       n_dead_tup,
       ROUND(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1) AS pct_dead,
       last_vacuum, last_autovacuum
FROM   pg_stat_user_tables
WHERE  schemaname = 'banking_db'
ORDER  BY n_dead_tup DESC;

-- [PostgreSQL] find sessions that might be blocking vacuum progress
SELECT pid, state, xact_start, now() - xact_start AS txn_age, query
FROM   pg_stat_activity
WHERE  state = 'idle in transaction'
   OR  (state <> 'idle' AND xact_start < now() - interval '10 minutes')
ORDER  BY xact_start;
```

> **Common Mistake**
> A long-idle-in-transaction session (an application connection that opened a transaction, ran one query, and
> then never committed or rolled back — often due to a connection pool bug or a forgotten interactive `psql`
> session) is treated as "harmless because it's not doing anything." In fact it is actively harmful: as shown in
> §29.9.2, its old snapshot prevents vacuum from reclaiming any tuple that transaction could still theoretically
> see, anywhere in the database, for as long as it stays open — a single forgotten session can quietly cause
> bloat across many unrelated tables.

---

## 29.10 Checkpoints, Revisited

Checkpoints were covered in full mechanical depth in §29.6.4 as part of WAL — a checkpoint is the point up to which
all data-file changes are guaranteed durably on disk, bounding how much WAL a crash recovery must replay. The only
addition worth making here is the connection to vacuum: checkpoint activity and vacuum activity are both forms of
background I/O competing for the same disk bandwidth, which is why the background processes managing both
(§29.11) are tuned together in a production system, not independently.

---

## 29.11 Background Processes [PostgreSQL]

A running PostgreSQL server is never just "waiting for queries" — several dedicated background processes are
continuously doing maintenance work. Knowing their names and jobs gives you a mental map for reading `ps aux | grep
postgres` output or diagnosing where background I/O and CPU are going.

| Process | Job |
|---|---|
| **checkpointer** | Periodically performs checkpoints (§29.6.4): flushes all dirty buffers needed to guarantee durability up to a WAL position, then records that position so older WAL can be recycled/archived. |
| **background writer (bgwriter)** | Incrementally writes out some dirty shared-buffer pages to disk *between* checkpoints, in small amounts, specifically so a checkpoint doesn't have to flush a huge backlog of dirty pages all at once (which would cause a sudden I/O spike). |
| **autovacuum launcher / workers** | The launcher periodically wakes up and decides which tables need vacuuming based on dead-tuple thresholds (§29.8.4); it spawns short-lived **autovacuum worker** processes to actually run `VACUUM`/`ANALYZE` against those tables. |
| **WAL writer** | Periodically flushes WAL buffer contents to disk even between transaction commits, reducing the amount of WAL that would need to be written all at once at commit time and smoothing out WAL I/O. |
| **stats collector** *(historical)* | In PostgreSQL versions before 15, a separate **statistics collector** process aggregated per-table/per-index activity counters (feeding views like `pg_stat_user_tables`) from messages sent by every other backend. As of **PostgreSQL 15**, this was replaced by a shared-memory-based statistics system, eliminating the separate process — but the functional role (powering the monitoring views used throughout this chapter, and the counters autovacuum decisions depend on) is unchanged. |

> **Important Notes**
> This is a genuinely useful mental model: "what is Postgres always doing in the background" = checkpointer
> (durability bookkeeping) + bgwriter (smoothing dirty-page writes) + autovacuum (MVCC cleanup) + WAL writer
> (smoothing log writes) + the statistics subsystem (feeding both autovacuum's decisions and your own monitoring
> queries). Every one of these exists because of something explained earlier in this chapter — none of them is
> incidental machinery.

---

## 29.12 Common Mistakes — Consolidated

> **⚠️ Warning — "UPDATE is in-place"**
> Covered in depth in §29.7.7. This single wrong assumption is the root cause of most bloat-related surprise —
> if you expect `UPDATE` to overwrite bytes, a table growing many times larger than its live row count looks like a
> bug rather than an expected, explainable consequence of MVCC.

> **⚠️ Warning — Running `VACUUM FULL` casually in production**
> Covered in depth in §29.8.3. The `ACCESS EXCLUSIVE` lock it takes makes it one of the few genuinely dangerous
> maintenance commands in PostgreSQL if run against a live, actively queried table without a planned window.

> **⚠️ Warning — A forgotten long-running transaction blocking vacuum database-wide**
> Covered in depth in §29.9.2 and §29.9.5. The danger is precisely that it doesn't look dangerous — the session
> appears idle, but its old snapshot silently prevents cleanup everywhere.

---

## 29.13 Real-World Use Cases

- **Diagnosing a bloated table** — using `pg_stat_user_tables.n_dead_tup`/`n_live_tup` and `pg_stat_activity` to
  find both the symptom (dead tuple ratio) and the likely cause (an autovacuum tuned too conservatively for the
  table's update rate, or a long-idle transaction), as walked through in §29.9.5.
- **Explaining "why does `SELECT` never block" to a teammate coming from a lock-based mental model** — pointing at
  the exact mechanism in §29.7: readers and writers operate on distinct tuple versions, so there's no shared
  resource to contend over for ordinary reads.
- **Capacity planning around vacuum** — sizing `autovacuum_vacuum_scale_factor` and worker cost-based delay
  settings for a table with a known, high `UPDATE` rate (like a payments/ledger table) *before* it goes into
  production, instead of discovering the default thresholds are too loose only after the table has already bloated.
- **Preventing a wraparound outage** — proactively monitoring `age(relfrozenxid)` on the largest, oldest tables in
  a fleet, and making sure autovacuum's anti-wraparound thresholds are never disabled or starved of I/O budget.
- **Post-incident review of a "database frozen" report** — checking `pg_stat_activity` for `idle in transaction`
  sessions as a first step, since a stuck application connection holding an old snapshot open is one of the most
  common real-world causes of both lock contention (Chapter 12) and vacuum starvation (this chapter).

---

## 29.14 Comparisons — Storage & MVCC at a Glance

| Aspect | **[PostgreSQL]** | **[MySQL] (InnoDB)** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Storage engine choice | One built-in (heap) | Genuinely pluggable per table (InnoDB default, MyISAM legacy) | One primary engine | One primary engine |
| Row organization | Heap (unordered by any key) | Clustered index (physically ordered by primary key) | Heap-organized tables (or optional index-organized tables) | Heap or clustered index, per table |
| MVCC old versions stored | In the table itself, as extra tuple versions | In separate undo logs, applied on demand | In undo segments | Only if `SNAPSHOT`/RCSI enabled; stored in `tempdb` |
| Concurrency default | MVCC-native (readers/writers never block each other) | MVCC-native | MVCC-native | Locking by default; MVCC is opt-in |
| Cleanup mechanism | `VACUUM` / autovacuum | Purge thread cleans undo logs automatically | Automatic undo segment reuse (space-managed automatically) | Version store cleanup automatic once enabled |

---

## 29.15 Practice Questions

1. Explain the difference between a **page** and a **tuple**. Which one is the unit of disk I/O, and which one is
   the unit of MVCC versioning?
2. Why does PostgreSQL use a fixed 8 KB page size instead of reading/writing exactly as many bytes as a query
   needs?
3. Walk through, in your own words, exactly what happens physically — at the tuple level — when you run
   `UPDATE banking_db.accounts SET balance = balance + 500 WHERE account_id = 2`.
4. A transaction under **Repeatable Read** reads `accounts.balance` for account 1, then another transaction updates
   and commits a change to that same row, then the first transaction reads it again. What does it see, and why,
   in terms of `xmin`/`xmax` and snapshots?
5. Now repeat question 4 under **Read Committed**. What's different, and precisely why?
6. Why can plain `VACUUM` proceed without blocking concurrent reads and writes, while `VACUUM FULL` requires an
   exclusive lock on the whole table?
7. What specific condition must be true about a dead tuple before `VACUUM` is allowed to reclaim its space? Why
   can't vacuum simply reclaim any tuple whose `xmax` is committed?
8. Explain, mechanically, why a session that has been sitting "idle in transaction" for six hours can cause bloat
   on tables it never even queried.
9. What is transaction ID wraparound, and why is it a 32-bit-counter problem rather than a disk-space problem?
10. Compare how PostgreSQL and InnoDB each implement MVCC. Which one stores old row versions in the table itself,
    and which one reconstructs them on demand? What's one practical consequence of that difference for table size?
11. Explain the relationship between WAL and checkpoints in your own words: why does a checkpoint let PostgreSQL
    discard old WAL, and what would happen to crash recovery time if checkpoints never occurred?
12. SQL Server, by default, is not MVCC-native the way PostgreSQL is. What has to be explicitly enabled to get
    MVCC-like behavior in SQL Server, and what does that setting change about where old row versions are stored?

---

## 29.16 Chapter-Ending Challenge

**Scenario:** `banking_db.accounts` in a (hypothetical) production deployment is processing a very high volume of
balance updates — thousands of debit/credit `UPDATE`s per minute against a relatively small number of rows (a
handful of hot accounts, much like a payments ledger). The team has noticed the `accounts` table is now several
times larger on disk than the row count would suggest, and sequential scans against it have visibly slowed down.

**Your task:** write a diagnosis-and-remediation plan. It should cover:

1. **What to check first**, and the exact queries you'd run — at minimum: dead-tuple ratio and last-(auto)vacuum
   timestamps (`pg_stat_user_tables`), whether any session is `idle in transaction` or otherwise holding an old
   snapshot open (`pg_stat_activity`), and the table's actual on-disk size versus its estimated live-data size.
2. **What autovacuum settings are likely misconfigured** given the described workload — reason specifically about
   why the *default* `autovacuum_vacuum_scale_factor` (a percentage of table size) is a poor fit for a table with a
   small, fixed row count but a very high per-row update rate, and what a better-tuned per-table setting would look
   like (hint: for a small table with extreme churn, a low **absolute** threshold matters more than a percentage).
3. **Whether `VACUUM FULL` or an online rebuild (e.g., `pg_repack`-style) is the more appropriate remediation**,
   and why — weigh the exclusive-lock disruption of `VACUUM FULL` against the near-zero-downtime tradeoff of an
   online rebuild tool, given that this is a production table that cannot tolerate extended unavailability.
4. **What ongoing change prevents recurrence** — not just a one-time fix, since re-bloating a few weeks later means
   the underlying tuning was never actually corrected.

There is no single graded answer key for this challenge — write it as you would present it to a team lead who
needs to approve a maintenance action, citing the specific mechanisms (dead tuples, autovacuum thresholds, lock
types) rather than vague generalities like "the database is slow."

---

## Key Takeaways

- PostgreSQL has **one** built-in storage engine (heap storage), unlike MySQL's genuinely pluggable engines
  (InnoDB default, MyISAM legacy) — this is a real architectural difference, not just terminology.
- Data is organized into fixed-size **pages** (8 KB in PostgreSQL) to amortize I/O cost and align with OS block
  sizes; a **tuple** is one physical version of a row, carrying `xmin`/`xmax` visibility metadata in its header.
- The **shared buffer pool** (`shared_buffers`) caches pages in memory above the OS page cache, avoiding disk I/O
  on repeated access.
- **WAL's fundamental rule**: a change is durable only once its WAL record is flushed to disk; data pages can be
  written back lazily afterward, because WAL replay reconstructs anything not yet on disk. **Checkpoints** bound
  how much WAL a crash recovery must replay by guaranteeing all changes before that point are durably in the data
  files.
- **MVCC** keeps multiple tagged tuple versions of the same row so readers and writers never block each other;
  visibility is decided by comparing a tuple's `xmin`/`xmax` against a transaction's snapshot, captured per-statement
  (Read Committed) or once per transaction (Repeatable Read/Serializable) — the exact mechanism behind Chapter 11's
  isolation-level behavior.
- MVCC's cost is that old versions don't disappear on their own — **`VACUUM`** (and **autovacuum**) reclaims dead
  tuples; **`VACUUM FULL`** additionally shrinks the file but takes a disruptive exclusive lock.
- **Bloat** is dead tuples and dead index entries outpacing vacuum's reclamation — caused by high-update workloads
  or long-running transactions holding old snapshots open — and it degrades scan and index performance directly.
- **Transaction ID wraparound** is a real, serious operational risk from PostgreSQL's 32-bit transaction counter,
  which is why anti-wraparound autovacuum cannot be indefinitely deferred.
- Background processes (checkpointer, bgwriter, autovacuum launcher/workers, WAL writer, and the stats subsystem)
  are continuously doing this maintenance work so that, most of the time, you never have to think about it.

## What's Next

This chapter explained how a single PostgreSQL instance keeps itself correct, durable, and clean over time.
**Chapter 30 — Replication & High Availability** takes the next step: how the *same* WAL stream this chapter built
up in depth is shipped to other servers to create standby replicas, how failover works when a primary goes down,
and the trade-offs between synchronous and asynchronous replication for a system — like a bank's core ledger — that
cannot afford to lose committed transactions.
