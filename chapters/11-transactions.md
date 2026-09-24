# Chapter 11 — Transactions & ACID

> Part IV — Advanced SQL & Database Engineering
> Database used throughout: **`banking_db`** (`customers`, `accounts`, `transactions`, `loans`, `audit_log`)
> Prerequisite: run `psql -f databases/banking_db.sql` before working through this chapter.

---

## 11.1 Why This Chapter Exists

Every query you've written so far — `SELECT`, `INSERT`, `UPDATE`, `DELETE`, joins, subqueries, CTEs, window
functions — has been about **reading or writing data correctly in isolation**. This chapter is about something
different: what happens when a single unit of business work requires *multiple* statements to succeed or fail
**together**.

The canonical example, and the reason `banking_db` exists in this course, is a **money transfer**. Moving ₹10,000
from Ravi Shankar's savings account (`account_id = 1`) to Neha Agarwal's savings account (`account_id = 3`) is not
one operation. It's at least four:

1. Check that account 1 has sufficient balance.
2. Subtract ₹10,000 from account 1's balance.
3. Add ₹10,000 to account 3's balance.
4. Record both movements in `transactions` (a `TRANSFER_OUT` row and a `TRANSFER_IN` row).

If step 2 succeeds and the application crashes before step 3 runs, ₹10,000 has evaporated from the bank. If step 3
runs twice due to a retry, ₹10,000 has been created from nothing. Neither is a hypothetical — this is precisely the
class of bug that transactions were invented to make impossible.

A **transaction** is a sequence of one or more SQL statements that the database treats as a single, indivisible
unit of work. Either every statement in it takes effect, or none do. This chapter builds that idea up from first
principles: the statements that control transactions (`BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`), the four
guarantees a transactional database makes (ACID), the isolation levels that trade correctness for concurrency, and
the classic anomalies that isolation levels exist to prevent.

---

## 11.2 Transaction Control Statements

### 11.2.1 Simple Explanation

Think of a transaction like editing a document with "track changes" and a single **Save** button. You can make as
many edits as you like — they're provisional. If you're happy with all of them, you hit **Save** (`COMMIT`) and
they become permanent. If you change your mind, or something goes wrong, you hit **Undo All** (`ROLLBACK`) and the
document reverts to exactly how it looked before you started editing — as if none of your edits ever happened.

`SAVEPOINT` is a checkpoint *within* that editing session — an "undo to here" marker that lets you discard just
the last few edits without throwing away everything.

### 11.2.2 Technical Explanation

A transaction begins either explicitly (`BEGIN` / `START TRANSACTION`) or implicitly (the first statement executed
under **autocommit**, discussed in §11.9). While a transaction is open, all changes it makes are visible to that
session immediately, but invisible to other sessions until the transaction commits (the exact visibility rules
depend on the isolation level — §11.5). `COMMIT` makes the changes permanent and durable (written to disk in a way
that survives a crash — §11.4.4). `ROLLBACK` discards every change made since the transaction began, returning the
database to its pre-transaction state. `SAVEPOINT name` marks a point inside the current transaction that a later
`ROLLBACK TO SAVEPOINT name` can revert to without ending the whole transaction. `RELEASE SAVEPOINT name` forgets a
savepoint you no longer need (without undoing anything).

### 11.2.3 Why This Exists

Without transaction control, every statement would commit the instant it ran (this is exactly what **autocommit**
mode does, and it's the default in almost every client). That's fine for a single, self-contained `UPDATE`. It is
not fine for a multi-statement operation where an in-between failure would leave the data in a state that never
should have existed — like money debited from one account with no corresponding credit anywhere. Transactions give
you a boundary you draw around related statements and a guarantee from the database: "I will make all of this true,
or none of it."

### 11.2.4 Full Syntax Breakdown

**Starting a transaction**

```sql
-- [PostgreSQL] both are equivalent; BEGIN is the common idiom
BEGIN;
START TRANSACTION;

-- [MySQL]
START TRANSACTION;
BEGIN;                 -- also accepted

-- [SQL Server]
BEGIN TRANSACTION;      -- BEGIN TRAN is a common abbreviation

-- [Oracle]
-- Oracle has no explicit BEGIN statement. A transaction starts implicitly
-- with the first DML statement after connecting or after the previous
-- COMMIT/ROLLBACK.
```

**Ending a transaction**

```sql
COMMIT;                 -- make all changes permanent [all dialects]
COMMIT WORK;             -- ANSI-standard synonym, accepted by most dialects

ROLLBACK;                -- discard all changes since BEGIN [all dialects]
ROLLBACK WORK;
```

**Savepoints**

```sql
SAVEPOINT sp_name;                  -- mark a point inside the transaction
ROLLBACK TO SAVEPOINT sp_name;      -- [PostgreSQL/Oracle] undo back to that point, keep the transaction open
ROLLBACK TO sp_name;                -- [MySQL] the SAVEPOINT keyword is optional here
RELEASE SAVEPOINT sp_name;          -- forget the savepoint (does not undo anything)

-- [SQL Server] uses different keywords for the same idea
SAVE TRANSACTION sp_name;
ROLLBACK TRANSACTION sp_name;       -- note: no explicit "release" statement in T-SQL
```

> **Important Notes**
> - `ROLLBACK TO SAVEPOINT` does **not** end the transaction — it rewinds to the savepoint and lets you keep
>   working, then still requires an eventual `COMMIT` or `ROLLBACK`.
> - A plain `ROLLBACK` (no savepoint) always ends the entire transaction, undoing everything back to `BEGIN`,
>   regardless of how many savepoints exist.
> - Rolling back to a savepoint automatically releases (destroys) any savepoints created *after* it.

### 11.2.5 – 11.2.7 Examples, Expected Output, and Line-by-Line Explanation

**Example 1 — the simplest possible transaction (deposit)**

```sql
BEGIN;

UPDATE banking_db.accounts
SET    balance = balance + 5000.00
WHERE  account_id = 6;                 -- Kavita Desai's savings account

INSERT INTO banking_db.transactions (account_id, transaction_type, amount, description)
VALUES (6, 'DEPOSIT', 5000.00, 'Cash deposit at branch');

COMMIT;
```

*Line by line:*
1. `BEGIN;` — opens a transaction. Nothing is visible outside this session yet.
2. `UPDATE ... accounts` — account 6's balance moves from `20000.00` to `25000.00`, but only inside this
   transaction's view of the data.
3. `INSERT INTO ... transactions` — logs the deposit. Also only visible inside this transaction so far.
4. `COMMIT;` — both changes become permanent and simultaneously visible to every other session. Before this line
   runs, another session querying `accounts` still sees `20000.00`.

**Expected state:**

| Step | account 6 balance (this session) | account 6 balance (other sessions) |
|---|---|---|
| Before `BEGIN` | 20000.00 | 20000.00 |
| After `UPDATE`, before `COMMIT` | 25000.00 | 20000.00 |
| After `COMMIT` | 25000.00 | 25000.00 |

**Example 2 — rollback on a mistake**

```sql
BEGIN;

UPDATE banking_db.accounts SET balance = balance - 100000.00 WHERE account_id = 4;
-- Oops — wrong account, this was meant to be a 1000.00 withdrawal from account 6.

ROLLBACK;

SELECT balance FROM banking_db.accounts WHERE account_id = 4;  -- still 300000.00, untouched
```

**Example 3 — SAVEPOINT for partial undo**

Suppose you're processing a batch of three small fee debits in one transaction, and the second one should be
skipped because the account is frozen (`account_id = 7`, status `FROZEN`), but you still want the first and third
to go through:

```sql
BEGIN;

UPDATE banking_db.accounts SET balance = balance - 50 WHERE account_id = 1;   -- fee 1: OK

SAVEPOINT before_fee_2;
UPDATE banking_db.accounts SET balance = balance - 50 WHERE account_id = 7;   -- fee 2: account is FROZEN
ROLLBACK TO SAVEPOINT before_fee_2;                                          -- undo just fee 2

UPDATE banking_db.accounts SET balance = balance - 50 WHERE account_id = 3;   -- fee 3: OK

COMMIT;
```

*Line by line:* the fee-1 debit and fee-3 debit persist because they were never rolled back. The fee-2 debit is
undone by `ROLLBACK TO SAVEPOINT before_fee_2`, but the transaction itself stays open — the final `COMMIT` commits
fee 1 and fee 3 only. Without the savepoint, the only way to "skip" fee 2 after already applying it would be to
roll back the *entire* transaction and start over, losing fee 1 as well.

### 11.2.8 Internal Behavior (Conceptual — Full Depth in Chapter 29)

- **PostgreSQL** implements rollback using **MVCC** (multi-version concurrency control): every row version written
  by a transaction is tagged with that transaction's ID. A rollback simply means the transaction's ID is marked as
  aborted; those row versions become invisible to everyone and are later cleaned up by `VACUUM`. Nothing is
  "undone" byte-by-byte — the old version was never overwritten.
- **MySQL (InnoDB)** uses an **undo log**: changes are applied in place, and the pre-change value is stashed in
  the undo log. Rollback replays the undo log backwards to restore prior values.
- **SAVEPOINT** in both engines is implemented by recording a marker in that same undo/version chain; rolling back
  to it discards only the changes recorded after the marker.
- **Locks** (row locks, in most cases) acquired by statements inside a transaction are held until `COMMIT` or
  `ROLLBACK` — this is the seed of Chapter 12.

---

## 11.3 The Full Worked Example: A Safe Money Transfer

This is the pattern you'll reuse for the rest of the chapter and again as a stored procedure in Chapter 19.

**Goal:** transfer ₹10,000 from account 1 (Ravi's savings, balance ₹150,000) to account 3 (Neha's savings, balance
₹80,000), refusing the transfer if account 1 doesn't have enough money, and recording both legs in `transactions`.

```sql
BEGIN;

-- Step 1: lock and read the source account's current balance
SELECT balance FROM banking_db.accounts
WHERE  account_id = 1
FOR UPDATE;                                   -- see Ch12: prevents a concurrent transfer from racing us
-- Suppose this returns 150000.00

-- Step 2: application-level (or SQL-level) check — do we have enough?
-- If balance < 10000.00, the client should ROLLBACK here instead of continuing.

-- Step 3: debit the source account
UPDATE banking_db.accounts
SET    balance = balance - 10000.00
WHERE  account_id = 1
AND    balance >= 10000.00;                   -- belt-and-braces: re-check atomically

-- Step 4: verify exactly one row was actually debited
-- (in psql: \gset or check "UPDATE 1"; in application code: check affected-row count)
-- If 0 rows were updated, the balance was insufficient — ROLLBACK and stop.

-- Step 5: credit the destination account
UPDATE banking_db.accounts
SET    balance = balance + 10000.00
WHERE  account_id = 3;

-- Step 6: record both legs of the transfer
INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
VALUES (1, 'TRANSFER_OUT', 10000.00, 3, 'Transfer to Neha Agarwal');

INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
VALUES (3, 'TRANSFER_IN', 10000.00, 1, 'Transfer from Ravi Shankar');

COMMIT;
```

**Expected state (before → after):**

| account_id | owner | balance before | balance after |
|---|---|---|---|
| 1 | Ravi Shankar | 150000.00 | 140000.00 |
| 3 | Neha Agarwal | 80000.00 | 90000.00 |

Two new rows appear in `transactions`: a `TRANSFER_OUT` of 10000.00 on account 1 referencing `related_account_id =
3`, and a `TRANSFER_IN` of 10000.00 on account 3 referencing `related_account_id = 1`.

**The insufficient-funds path** — attempting to move ₹1,000,000 out of account 6 (Kavita, balance ₹20,000):

```sql
BEGIN;

UPDATE banking_db.accounts
SET    balance = balance - 1000000.00
WHERE  account_id = 6
AND    balance >= 1000000.00;
-- Result: UPDATE 0  (the WHERE clause matched no row because 20000.00 < 1000000.00)

-- The application checks the affected-row count, sees 0, and knows the debit did not happen.
ROLLBACK;
-- Nothing changed. Account 6 is still 20000.00. No stray transactions row was ever inserted,
-- because the credit and inserts in Step 5/6 are never reached.
```

> **⚠️ Warning**
> The `CHECK (balance >= 0)` constraint on `accounts` (see `databases/banking_db.sql`) is your **last line of
> defense**, not your primary safeguard. If you skip the `AND balance >= 10000.00` guard and just run
> `UPDATE ... SET balance = balance - 10000.00`, PostgreSQL will still refuse a debit that would push the balance
> negative — but it does so by **raising an error and aborting the transaction**, which is a much worse user
> experience than a clean, checked "insufficient funds" path. Design your transaction logic so the constraint is a
> safety net, never the intended control-flow mechanism.

---

## 11.4 ACID, Explained Individually and Deeply

ACID is an acronym for the four guarantees a transactional database makes about every committed transaction:
**Atomicity, Consistency, Isolation, Durability**. Each one exists to prevent a specific, concrete class of
corruption. We'll take them one at a time, each with a `banking_db` failure scenario showing exactly what breaks
without the guarantee.

### 11.4.1 Atomicity — "All or Nothing"

**Simple explanation:** A transaction is one indivisible move. You can't do half of it.

**Technical explanation:** Every statement inside a transaction either all take effect (on `COMMIT`) or none do
(on `ROLLBACK`, or if the connection/process dies before committing). There is no state in which some statements
from the transaction are visible and others aren't.

**What breaks without it:** Take the transfer from §11.3, but imagine the database (or the application process
running it) crashes *after* Step 3 (the debit to account 1 succeeds and is written) but *before* Step 5 (the credit
to account 3). Without atomicity:

```
Before crash:  account 1 = 150000.00, account 3 = 80000.00
After Step 3:  account 1 = 140000.00   (debited)
[[ CRASH ]]
account 3 is never credited: account 3 = 80000.00   (unchanged)

Result: ₹10,000 has vanished from the bank. It is not in account 1, not in account 3,
and no transactions row records where it went.
```

With atomicity, this cannot happen: because Step 3's debit was never committed (the transaction never reached
`COMMIT`), it is automatically rolled back — the database engine detects the uncommitted transaction on recovery
and discards its effects. Account 1 goes back to `150000.00`. The transfer simply never happened, which is the
only acceptable outcome of a crash mid-transfer.

### 11.4.2 Consistency — "Never a state that violates the rules"

**Simple explanation:** A transaction can only take the database from one valid state to another valid state. It
can never leave data that breaks a defined rule.

**Technical explanation:** Consistency in ACID refers to database-enforced invariants — `CHECK` constraints,
`FOREIGN KEY` constraints, `NOT NULL` constraints, `UNIQUE` constraints — being upheld at transaction boundaries.
(This is distinct from, and narrower than, the everyday English sense of "consistent" — it does not mean "your
business logic is bug-free," only that declared database rules are never violated by a committed transaction.)

**What breaks without it:** `banking_db.accounts` has `CHECK (balance >= 0)`. Imagine that constraint didn't
exist, and a bug in application logic tried to withdraw ₹300,000 from account 6 (Kavita, balance ₹20,000) without
a balance check:

```sql
BEGIN;
UPDATE banking_db.accounts SET balance = balance - 300000.00 WHERE account_id = 6;
COMMIT;
-- Without the CHECK constraint, this commits successfully, leaving:
-- account 6 balance = -280000.00
```

A negative balance is a state the business rules say must never exist. **With** the `CHECK (balance >= 0)`
constraint actually in place (as it is in the real schema), PostgreSQL rejects the `UPDATE` outright:

```
ERROR:  new row for relation "accounts" violates check constraint "accounts_balance_check"
DETAIL:  Failing row contains (6, 4, SAVINGS, -280000.00, 2022-05-10, ACTIVE).
```

Consistency is the guarantee that the database itself refuses to commit a transaction that would produce a row
violating a declared constraint — it enforces the rule even if the application forgot to check it.

### 11.4.3 Isolation — "Concurrent transactions don't see each other's half-finished work"

**Simple explanation:** Even if a hundred transactions run at the same time, each one should behave as if it had
the database to itself.

**Technical explanation:** Isolation controls what a transaction is allowed to see of *other, concurrent*
transactions' uncommitted or newly-committed changes. This is graduated — full isolation (`SERIALIZABLE`) is
expensive; weaker levels allow more concurrency at the cost of specific anomalies (the entire subject of §11.5 and
§11.6).

**What breaks without it:** Two concurrent transfers **out of the same account** (account 1, balance ₹150,000),
each reading the balance, deciding it's sufficient, then writing — without any isolation protecting the read:

```
Session A                                   Session B
--------------------------------------      --------------------------------------
BEGIN;
SELECT balance FROM accounts
  WHERE account_id = 1;  -- reads 150000.00
                                             BEGIN;
                                             SELECT balance FROM accounts
                                               WHERE account_id = 1; -- also reads 150000.00
-- app checks: 150000 >= 100000 OK
UPDATE accounts SET balance = balance - 100000.00
  WHERE account_id = 1;   -- writes 50000.00
                                             -- app checks: 150000 >= 100000 OK (stale read!)
                                             UPDATE accounts SET balance = balance - 100000.00
                                               WHERE account_id = 1;  -- writes 50000.00
COMMIT;
                                             COMMIT;

Final balance: 50000.00
```

Two withdrawals of ₹100,000 each were approved against a ₹150,000 balance, and the final balance (`50000.00`)
reflects only *one* of them — ₹100,000 has effectively been created (the account should be at `-50000.00` if both
truly went through, or one should have been rejected). This is the **lost update** anomaly, explored in full in
§11.6.4, and it is exactly what isolation (implemented via locking or MVCC conflict detection) prevents.

### 11.4.4 Durability — "Once committed, it survives anything"

**Simple explanation:** Once the database tells you "committed," that data is safe — even if the power goes out
one millisecond later.

**Technical explanation:** After `COMMIT` returns successfully, the transaction's effects are guaranteed to
survive a server crash, OS crash, or power loss. This is achieved via **write-ahead logging (WAL)**: before a
transaction is allowed to report success, its changes are first flushed to a durable, append-only log on disk. If
the server crashes right after, the WAL is replayed on restart to reconstruct any committed changes that hadn't
yet been written to the main data files. (Chapter 29 covers WAL mechanics, checkpoints, and crash recovery in
full; Chapter 28 covers backup/recovery.)

**What breaks without it:** Suppose the transfer from §11.3 commits successfully — the client receives
`COMMIT` confirmation — and one second later the database server loses power before the changed pages are written
from memory to the data files on disk. Without durability (i.e., without WAL or an equivalent), the in-memory
changes are gone: on restart, account 1 shows `150000.00` and account 3 shows `80000.00` again, even though the
bank already told the customer the transfer succeeded and the customer may have acted on that (e.g., spent the
money). **With** WAL, PostgreSQL had already flushed the transaction's WAL record to disk *before* confirming the
commit; on restart, WAL replay reapplies the debit and credit, and both balances are correct — `140000.00` and
`90000.00` — exactly as if the crash never happened.

> **Important Notes — ACID at a glance**
>
> | Property | Guarantees | Enforced by |
> |---|---|---|
> | Atomicity | All statements in a transaction commit, or none do | Transaction manager, undo/MVCC on rollback |
> | Consistency | Committed data never violates declared constraints | `CHECK`, `FOREIGN KEY`, `NOT NULL`, `UNIQUE` |
> | Isolation | Concurrent transactions don't observe each other's incomplete work | Locking and/or MVCC snapshots, governed by isolation level |
> | Durability | Committed data survives a crash | Write-ahead log (WAL), fsync to disk |

---

## 11.5 Transaction Isolation Levels

Isolation levels are a dial between **correctness** and **concurrency**. The stricter the level, the fewer
anomalies are possible, but the more transactions block each other (or abort due to conflicts) and the lower your
throughput. The ANSI SQL standard defines four levels.

### 11.5.1 Read Uncommitted

**Definition:** A transaction can see changes made by other transactions **even before they commit** — including
changes that are later rolled back.

**Prevents:** Nothing (weakest level).
**Allows:** Dirty reads, non-repeatable reads, phantom reads, lost updates, write skew.

> **⚠️ Warning — Dialect Accuracy**
> **[PostgreSQL]** You can `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED`, and PostgreSQL will accept the
> command without error — but it does **not** actually implement Read Uncommitted. Internally, PostgreSQL silently
> upgrades it to **Read Committed** behavior. PostgreSQL's MVCC design makes true dirty reads (seeing another
> transaction's *uncommitted* row versions) structurally impossible — every reader always sees only committed row
> versions, as of some snapshot. This is a frequently misunderstood point even among experienced engineers.
> **[MySQL]** InnoDB *does* genuinely implement Read Uncommitted — dirty reads are really possible.
> **[SQL Server]** Genuinely implements Read Uncommitted (equivalent to the `NOLOCK` table hint) — dirty reads
> really happen.
> **[Oracle]** Does not offer Read Uncommitted at all — see §11.5.5.

### 11.5.2 Read Committed

**Definition:** A transaction only ever sees data that has been committed by other transactions. It never sees
uncommitted (dirty) data. However, each individual statement gets its own fresh read — if you run the same
`SELECT` twice in the same transaction, and another transaction committed a change in between, you can see
different results the second time.

**Prevents:** Dirty reads.
**Allows:** Non-repeatable reads, phantom reads, lost updates, write skew.

> **[PostgreSQL]** This is the **default** isolation level. Each statement (not the whole transaction) sees a
> snapshot of the data as of the moment that statement began.
> **[MySQL]** Supported, but **not** the default (see §11.5.3).
> **[SQL Server]** This is the **default** isolation level.
> **[Oracle]** This is the **default**, and one of only two levels Oracle supports at all (see §11.5.5).

### 11.5.3 Repeatable Read

**Definition:** A transaction sees a single consistent snapshot of the database for its **entire duration** —
every statement inside it sees data as of the moment the transaction (not the statement) began. Re-running the
same query later in the same transaction returns the same rows and same values for existing rows.

**Prevents:** Dirty reads, non-repeatable reads.
**Allows (standard-defined):** Phantom reads — though see the dialect note below, this is where standards and
real engines diverge sharply.

> **⚠️ Warning — Dialect Accuracy**
> **[MySQL]** InnoDB's **default** isolation level is Repeatable Read. Unusually, InnoDB's implementation of
> Repeatable Read *does* prevent most phantom reads for plain reads, using **gap locks** / next-key locking on
> indexed ranges accessed by locking reads (`SELECT ... FOR UPDATE`) — this goes beyond the ANSI standard's
> guarantee for this level.
> **[PostgreSQL]** Repeatable Read is implemented via a single MVCC snapshot taken at the start of the
> transaction. It prevents dirty reads, non-repeatable reads, **and** phantom reads (PostgreSQL's Repeatable Read
> is actually stricter than the ANSI minimum) — but it does **not** prevent write skew (§11.6.5). Instead of
> silently allowing a conflicting concurrent write to succeed, PostgreSQL detects the conflict and raises a
> serialization error, forcing the application to retry.
> **[Oracle]** Does not have a level literally named "Repeatable Read," but its **Serializable** level (per-
> transaction snapshot) is close in spirit; Oracle also offers a snapshot-based read-consistency model at the
> statement level even under Read Committed. See §11.5.5.
> **[SQL Server]** Supports Repeatable Read as a locking isolation level (holds shared locks on read rows until
> the transaction ends), distinct from its optional MVCC-based `SNAPSHOT` isolation (§11.5.6).

### 11.5.4 Serializable

**Definition:** The strongest level. Transactions behave as if they ran one at a time, in some serial order — even
though they're actually executing concurrently. Nothing about the outcome can reveal that they overlapped in time.

**Prevents:** Dirty reads, non-repeatable reads, phantom reads, lost updates, write skew — all of the classic
anomalies.
**Allows:** Nothing from the classic anomaly list, but transactions may fail with a **serialization failure**
error and require the application to retry.

> **[PostgreSQL]** Implements Serializable using **Serializable Snapshot Isolation (SSI)** — each transaction
> gets an MVCC snapshot like Repeatable Read, but the engine additionally tracks read/write dependencies between
> concurrent transactions and aborts one of them with `ERROR: could not serialize access due to read/write
> dependencies among transactions` if committing both would be impossible in any serial order. This is what
> correctly prevents write skew.
> **[MySQL]** InnoDB's Serializable converts plain `SELECT` statements into `SELECT ... LOCK IN SHARE MODE`
> equivalents implicitly, relying on locking rather than snapshot-conflict detection.
> **[Oracle]** Supports Serializable as one of its two isolation levels, implemented via multiversioning similar
> in spirit to PostgreSQL's snapshot approach, but Oracle detects conflicts and raises `ORA-08177: can't serialize
> access` on conflicting writes rather than blocking.
> **[SQL Server]** Supports Serializable as a locking level (range locks to block phantom inserts) as well as the
> separate `SNAPSHOT` isolation level below.

### 11.5.5 Oracle's Special Case

> **⚠️ Warning**
> **[Oracle]** Supports **only two** isolation levels: **Read Committed** (the default) and **Serializable**.
> There is no Repeatable Read and no Read Uncommitted in Oracle. Oracle also offers a non-standard
> **READ ONLY** transaction mode (a consistent snapshot for the whole transaction, but no writes allowed), which
> is often used where other databases might reach for Repeatable Read.

### 11.5.6 SQL Server's SNAPSHOT Isolation

> **[SQL Server]** In addition to the four standard levels, SQL Server offers **`SNAPSHOT`** isolation — an
> MVCC-style level (must be enabled at the database level with `ALTER DATABASE ... SET ALLOW_SNAPSHOT_ISOLATION
> ON`) where each transaction sees a consistent snapshot as of its start, and conflicting concurrent writes to the
> same row cause one transaction to fail at commit time with error 3960, rather than blocking on locks. This is
> conceptually the closest SQL Server analog to how PostgreSQL's Repeatable Read/Serializable behave by default.

### 11.5.7 Default and Supported Levels — Summary Table

| Dialect | Default level | Levels supported | Notes |
|---|---|---|---|
| **PostgreSQL** | Read Committed | Read Uncommitted *(aliased to Read Committed)*, Read Committed, Repeatable Read, Serializable | True Read Uncommitted does not exist; MVCC makes dirty reads impossible regardless of setting |
| **MySQL (InnoDB)** | Repeatable Read | Read Uncommitted, Read Committed, Repeatable Read, Serializable | Only engine here with a genuine, distinct Read Uncommitted |
| **SQL Server** | Read Committed | Read Uncommitted, Read Committed, Repeatable Read, Serializable, plus non-standard `SNAPSHOT` and `READ COMMITTED SNAPSHOT` | Locking-based by default; `SNAPSHOT` variants are MVCC-based |
| **Oracle** | Read Committed | Read Committed, Serializable (+ non-standard Read Only) | No Repeatable Read, no Read Uncommitted |

**Setting the isolation level:**

```sql
-- [PostgreSQL / SQL Server / Oracle / MySQL — ANSI standard form]
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN;
-- ...
COMMIT;

-- [PostgreSQL] can also be set per-transaction in one line
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- [MySQL] session-wide or next-transaction-only
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- applies to the next transaction only
```

---

## 11.6 Concurrency Anomalies, Precisely, With Two-Session Timelines

Each anomaly below is shown as two concurrent sessions against `banking_db.accounts`, followed by which isolation
level prevents it and *how* (locking vs. MVCC snapshot/conflict detection).

### 11.6.1 Dirty Read

**Definition:** Transaction B reads a row that Transaction A has modified but not yet committed. If A rolls back,
B has now acted on data that never officially existed.

```
Session A                                        Session B
------------------------------------------       ------------------------------------------
BEGIN;
UPDATE accounts SET balance = balance - 200000
  WHERE account_id = 4;    -- balance now 100000
                                                  BEGIN;  -- ISOLATION LEVEL READ UNCOMMITTED
                                                  SELECT balance FROM accounts
                                                    WHERE account_id = 4;
                                                  -- reads 100000.00 (uncommitted!)
ROLLBACK;    -- balance reverts to 300000.00
                                                  -- Session B already used/displayed 100000.00,
                                                  -- a value that never actually existed.
```

**Prevented by:** Read Committed and above.
**Mechanism:** Under Read Committed, a reader only ever sees row versions with a commit timestamp/transaction ID
earlier than its own statement's snapshot (MVCC), or (in a purely lock-based engine) a reader would need a shared
lock that conflicts with A's exclusive lock on the uncommitted row, and would block until A finishes. Either way,
B cannot observe A's in-flight, uncommitted change.

**[PostgreSQL] note:** As covered in §11.5.1, this anomaly is not reproducible in PostgreSQL at all, even if you
explicitly `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED` — MVCC visibility rules always hide uncommitted
data from other sessions.

### 11.6.2 Non-Repeatable Read

**Definition:** Transaction B reads the same row twice within one transaction and gets two different values,
because Transaction A committed a change to that row in between.

```
Session A                                        Session B
------------------------------------------       ------------------------------------------
                                                  BEGIN;  -- ISOLATION LEVEL READ COMMITTED
                                                  SELECT balance FROM accounts
                                                    WHERE account_id = 1;
                                                  -- reads 150000.00
BEGIN;
UPDATE accounts SET balance = balance + 20000
  WHERE account_id = 1;
COMMIT;    -- balance is now 170000.00, committed
                                                  SELECT balance FROM accounts
                                                    WHERE account_id = 1;
                                                  -- reads 170000.00 -- different result, same txn!
                                                  COMMIT;
```

**Prevented by:** Repeatable Read and above.
**Mechanism:** Under Repeatable Read, B's transaction takes a single MVCC snapshot at `BEGIN` and every statement
in it reads from that same snapshot, regardless of what commits elsewhere afterward. B's second `SELECT` re-reads
the *same* snapshot version (`150000.00`) instead of picking up A's committed change. In a lock-based
implementation, B would instead hold a shared lock on the row from its first read until B's transaction ends,
blocking A's `UPDATE` until B finishes.

### 11.6.3 Phantom Read

**Definition:** Transaction B runs the same *range query* (a `WHERE` matching a set of rows, not one fixed row)
twice, and gets a different **set of rows** the second time because Transaction A inserted (or deleted) a row that
matches the condition, in between.

```
Session A                                        Session B
------------------------------------------       ------------------------------------------
                                                  BEGIN;  -- ISOLATION LEVEL REPEATABLE READ
                                                  SELECT COUNT(*) FROM accounts
                                                    WHERE customer_id = 3;
                                                  -- reads 2 (accounts 4 and 5)
BEGIN;
INSERT INTO accounts (customer_id, account_type, balance, opened_date)
  VALUES (3, 'SAVINGS', 1000.00, CURRENT_DATE);
COMMIT;    -- Suresh Menon now has a 3rd account
                                                  SELECT COUNT(*) FROM accounts
                                                    WHERE customer_id = 3;
                                                  -- standard-defined risk: could read 3 (a "phantom" row)
                                                  COMMIT;
```

**Prevented by:** Serializable always. **[PostgreSQL]** and **[MySQL/InnoDB]** Repeatable Read also prevent this
in practice (stricter than the ANSI minimum for this level), via the whole-transaction MVCC snapshot
(PostgreSQL) or gap locks on the indexed range (InnoDB). **[SQL Server]** and standard-conformant engines using
lock-based Repeatable Read still allow phantoms at that level — full range locking to block phantom inserts is a
Serializable-level guarantee there.
**Mechanism:** PostgreSQL's transaction-wide snapshot means the newly inserted row (committed by A after B's
snapshot was taken) simply doesn't exist as far as B's snapshot is concerned — B's second count still returns `2`.
InnoDB uses **next-key locks** (a row lock plus a lock on the gap before it) so that A's `INSERT` targeting that
range is blocked until B commits. A pure row-level lock (with no gap/range locking) cannot prevent this, because
there is no existing row to lock — the danger is a *new* row appearing, which is why phantom prevention requires
either range locking or a whole-transaction snapshot.

### 11.6.4 Lost Update

**Definition:** Two transactions each read the same row, each compute a new value based on what they read, and
each write it back — the second write silently overwrites the first, "losing" the first transaction's update.

This is precisely the double-withdrawal scenario from §11.4.3:

```
Session A                                        Session B
------------------------------------------       ------------------------------------------
BEGIN;                                           BEGIN;
SELECT balance FROM accounts
  WHERE account_id = 1;   -- reads 150000.00
                                                  SELECT balance FROM accounts
                                                    WHERE account_id = 1;  -- also reads 150000.00
-- app computes 150000 - 100000 = 50000
UPDATE accounts SET balance = 50000.00
  WHERE account_id = 1;
COMMIT;
                                                  -- app computes 150000 - 100000 = 50000 (stale!)
                                                  UPDATE accounts SET balance = 50000.00
                                                    WHERE account_id = 1;
                                                  COMMIT;

Final balance: 50000.00 -- should reflect BOTH withdrawals (i.e. -50000, or one should be rejected)
```

**Prevented by:** Repeatable Read and above in PostgreSQL (via write-write conflict detection); requires row
locking (`SELECT ... FOR UPDATE`) under Read Committed in any dialect.
**Mechanism:** Under PostgreSQL's Repeatable Read/Serializable, when B's transaction tries to `UPDATE` a row that
A has already modified and committed since B's snapshot began, PostgreSQL detects the conflict and raises
`ERROR: could not serialize access due to concurrent update` — B must retry, reading the *new* balance
(`50000.00`) rather than blindly overwriting it. Alternatively, at any isolation level, explicitly taking a lock
with `SELECT balance FROM accounts WHERE account_id = 1 FOR UPDATE` forces B's read to block until A's transaction
commits or rolls back, so B's subsequent read reflects A's committed change rather than the stale value — this is
exactly the pattern used in the worked transfer example in §11.3.

### 11.6.5 Write Skew

**Definition:** The subtlest anomaly. Two transactions each read overlapping data, each independently verify a
constraint that depends on that overlapping data, and each commit a write — but the constraint only held because
each transaction failed to account for the other's *concurrent, not-yet-visible* write. Individually each
transaction's check was valid at the moment it ran; together, they violate the invariant.

**Banking example:** Suresh Menon holds two accounts, account 4 (SAVINGS, ₹300,000) and account 5
(FIXED_DEPOSIT, ₹500,000). Imagine a business rule (enforced by application logic, not a single-row `CHECK`
constraint, since it spans two rows): *"Suresh must keep a combined balance of at least ₹700,000 across his two
accounts."* Two concurrent withdrawal requests arrive — one against each account — each checking the combined
balance before proceeding:

```
Session A (withdraw 150000 from acct 4)          Session B (withdraw 150000 from acct 5)
------------------------------------------       ------------------------------------------
BEGIN;  -- ISOLATION LEVEL REPEATABLE READ        BEGIN;  -- ISOLATION LEVEL REPEATABLE READ
SELECT SUM(balance) FROM accounts
  WHERE customer_id = 3;  -- reads 800000.00
                                                  SELECT SUM(balance) FROM accounts
                                                    WHERE customer_id = 3;  -- also reads 800000.00
-- check: 800000 - 150000 = 650000 >= 700000? NO... wait:
-- check: withdrawing 150000 leaves combined 650000, which is BELOW 700000
-- (for this example, assume the rule allows down to 650000, i.e. the check passes)
-- assume the check passes: proceed
UPDATE accounts SET balance = balance - 150000
  WHERE account_id = 4;
COMMIT;   -- account 4 now 150000; combined = 650000
                                                  -- check also passes independently: 800000-150000=650000 >= floor
                                                  UPDATE accounts SET balance = balance - 150000
                                                    WHERE account_id = 5;
                                                  COMMIT;   -- account 5 now 350000

Actual combined balance after both commits: 150000 + 350000 = 500000.00
-- Both transactions individually verified the rule against a stale 800000.00 combined balance.
-- Neither ever saw the other's withdrawal. The invariant (combined >= 700000) is now violated,
-- yet neither transaction's own read/write set looks individually invalid.
```

This is exactly the classic "two on-call doctors" problem, restated in banking terms: each transaction reads a
shared aggregate, validates against it, and writes to a *different* row than the one it read — so **row-level**
lost-update detection (which watches for two transactions writing the *same* row) never triggers. Each write
touches a disjoint row (`account_id = 4` vs. `account_id = 5`); the conflict is only visible at the level of the
`SUM()` both transactions read.

**Prevented by:** Only true **Serializable** isolation.
**Mechanism:** PostgreSQL's Serializable Snapshot Isolation (SSI) tracks read/write dependencies, not just
row-level write/write conflicts. It notices that Session A's transaction *read* a set of rows (both of Suresh's
accounts, via the `SUM`) that Session B's transaction later *wrote* to (account 5), and vice versa — a
read-write dependency cycle between concurrently-running transactions — and aborts one of them with a
serialization failure at commit time, forcing a retry with fresh data. Repeatable Read, in every dialect, is
**not sufficient** here, because Repeatable Read's conflict detection (in PostgreSQL) or locking (in InnoDB) only
protects individual rows each transaction writes — it has no mechanism to notice that a *read* in one transaction
conflicts with a *write* in another when they touch different rows.

---

## 11.7 Anomaly × Isolation Level Matrix

`✗` = anomaly is possible at this level. `✓` = anomaly is prevented at this level. Values follow the ANSI SQL
standard's definitions; dialect-specific deviations are called out below the table (and in §11.5/§11.6 above).

| Anomaly | Read Uncommitted | Read Committed | Repeatable Read | Serializable |
|---|---|---|---|---|
| Dirty read | ✗ possible | ✓ prevented | ✓ prevented | ✓ prevented |
| Non-repeatable read | ✗ possible | ✗ possible | ✓ prevented | ✓ prevented |
| Phantom read | ✗ possible | ✗ possible | ✗ possible (standard) | ✓ prevented |
| Lost update | ✗ possible | ✗ possible | ✓ prevented* | ✓ prevented |
| Write skew | ✗ possible | ✗ possible | ✗ possible | ✓ prevented |

\* Lost-update prevention at Repeatable Read depends on the engine's conflict-detection granularity; PostgreSQL's
Repeatable Read detects the write-write conflict shown in §11.6.4 and aborts one transaction. Relying on this
instead of explicit `SELECT ... FOR UPDATE` locking is still discouraged — see Chapter 12.

> **⚠️ Warning**
> This table states the **ANSI standard's** guarantees. As detailed in §11.5–11.6, real engines diverge:
> PostgreSQL's Repeatable Read additionally prevents phantom reads (stricter than standard); MySQL's InnoDB
> Repeatable Read also prevents most phantoms via gap locking; SQL Server's lock-based Repeatable Read does not.
> Always verify behavior against your actual database version — do not assume the standard table describes your
> engine's real behavior.

---

## 11.8 Common Mistakes

> **⚠️ Warning — Forgetting to COMMIT**
> ```sql
> BEGIN;
> UPDATE banking_db.accounts SET balance = balance - 500 WHERE account_id = 2;
> -- ... developer gets distracted, switches terminal tabs, goes to lunch ...
> ```
> This transaction is now **open indefinitely**. Any row locks it acquired (on account 2, and potentially
> on rows it merely read under stricter isolation levels) are held for as long as the session stays open. Other
> sessions trying to update — or in some cases even read, depending on isolation level and lock type — account 2
> will **block**, appearing to hang with no obvious cause. This is one of the most common sources of mysterious
> "the database is frozen" incidents in production. Always pair every `BEGIN` with a guaranteed `COMMIT` or
> `ROLLBACK`, typically via `try/finally` in application code.

> **⚠️ Warning — Assuming autocommit is off**
> Every major SQL client (`psql`, most GUI tools, most application database drivers) runs in **autocommit mode by
> default**: each individual statement is automatically wrapped in and committed as its own transaction unless you
> explicitly start one with `BEGIN`. Developers coming from a mental model of "nothing is saved until I say so"
> are frequently surprised that a stray `UPDATE` or `DELETE` run outside an explicit `BEGIN...COMMIT` block takes
> effect **immediately and irreversibly** — there is no implicit transaction wrapping your session as a whole.

> **⚠️ Warning — PostgreSQL aborts the entire transaction on ANY error**
> This one specifically surprises people coming from MySQL or SQL Server. In PostgreSQL, if **any** statement
> inside an open transaction raises an error — a constraint violation, a syntax error, a division by zero, a
> reference to a nonexistent column — the **entire transaction is immediately marked as aborted**, and every
> subsequent statement (other than `ROLLBACK`) fails with:
> ```
> ERROR:  current transaction is aborted, commands ignored until end of transaction block
> ```
> even statements that have nothing to do with the original error. You **must** issue `ROLLBACK` (or
> `ROLLBACK TO SAVEPOINT`, if you had one set before the failing statement) before the session can do anything
> else. Example:
> ```sql
> BEGIN;
> UPDATE banking_db.accounts SET balance = balance - 50 WHERE account_id = 1;   -- succeeds
> UPDATE banking_db.accounts SET balance = balance - 50 WHERE account_id = 999; -- 0 rows, no error, but suppose
> INSERT INTO banking_db.accounts (customer_id, account_type, balance, opened_date)
>   VALUES (1, 'INVALID_TYPE', 100, CURRENT_DATE);   -- ERROR: violates check constraint
> -- transaction is now aborted
> SELECT 1;   -- ERROR: current transaction is aborted, commands ignored until end of transaction block
> ROLLBACK;   -- required before you can do anything else, including the FIRST UPDATE which is now undone too
> ```
> MySQL (InnoDB) and SQL Server, by contrast, generally only roll back the *single failing statement* by default,
> leaving the rest of the transaction's changes intact and the transaction still open — a fundamentally different
> error-handling model. If you're writing cross-dialect application code, never assume one behavior applies to
> the other; always issue an explicit `ROLLBACK` (or `ROLLBACK TO SAVEPOINT` set immediately before any
> statement that might fail) as part of your error-handling path in PostgreSQL.

---

## 11.9 Edge Cases

### 11.9.1 "Nested Transactions" Don't Really Exist

> **Important Notes**
> Most relational databases, including PostgreSQL and MySQL, do **not** support true nested transactions. Issuing
> a second `BEGIN` inside an already-open transaction does not create an independent inner transaction:
> - **[PostgreSQL]** raises a warning (`WARNING: there is already a transaction in progress`) and simply ignores
>   the nested `BEGIN` — you're still in the original, outer transaction.
> - **[MySQL]** implicitly commits the outer transaction before starting what looks like a new one (because
>   `BEGIN`/`START TRANSACTION` in MySQL causes an implicit commit of any open transaction) — a behavior that can
>   silently commit work you didn't intend to commit yet.
>
> **`SAVEPOINT` is the real mechanism for partial nesting.** It lets you roll back an inner portion of work
> without discarding the whole transaction (as shown in §11.2, Example 3), but it is not true nesting — a
> `COMMIT` always commits the *entire* outer transaction, including everything since the very first `BEGIN`, all
> at once. There is no way to "commit" just an inner savepoint independently of the outer transaction.

### 11.9.2 DDL Inside a Transaction

> **⚠️ Warning — Dialect Accuracy**
> **[PostgreSQL]** Supports **fully transactional DDL**. You can run `CREATE TABLE`, `ALTER TABLE`,
> `DROP TABLE`, and similar statements inside a `BEGIN...COMMIT` block, and roll the whole thing back as if it
> never happened:
> ```sql
> BEGIN;
> ALTER TABLE banking_db.accounts ADD COLUMN notes TEXT;
> -- realize this was a mistake
> ROLLBACK;
> -- the notes column does not exist -- the ALTER TABLE was fully undone
> ```
> **[MySQL]** Historically does **not** support transactional DDL for most statements. Many DDL statements
> (`CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`, etc.) cause an **implicit commit** of the current transaction
> before they run, and cannot themselves be rolled back — once executed, they take effect immediately and
> permanently, transaction or not.
> **[SQL Server]** Supports transactional DDL (most DDL can be rolled back within a `BEGIN TRANSACTION` block),
> similar to PostgreSQL.
> **[Oracle]** DDL implicitly issues a `COMMIT` both before and after execution — DDL is effectively never
> transactional in Oracle, and cannot be rolled back once run.

### 11.9.3 Empty Transactions and Read-Only Transactions

A transaction that only performs `SELECT`s still acquires a snapshot and, at higher isolation levels, may still
hold resources or be a candidate for a serialization failure if it later needs to be rolled back due to a
conflict with data it read. Marking it explicitly can help the engine optimize:

```sql
-- [PostgreSQL]
BEGIN TRANSACTION READ ONLY;
SELECT balance FROM banking_db.accounts WHERE customer_id = 3;
COMMIT;
```

---

## 11.10 Explicit Transactions vs. Relying on Autocommit

| Use explicit `BEGIN...COMMIT` when... | Rely on autocommit when... |
|---|---|
| The operation spans more than one statement that must succeed or fail together (a transfer, an order + inventory decrement) | You're running a single, self-contained statement |
| You need to check a condition (balance, stock) and act on it atomically | You're doing ad-hoc, exploratory querying (read-only `SELECT`s) |
| You need `SAVEPOINT`s to recover from a partial failure without discarding everything | The statement is already atomic on its own (a single `UPDATE` that sets one row) |
| You're calling multiple related statements from application code and a network blip or bug between them must not leave partial state | Simplicity matters more than atomicity — e.g., logging, non-critical writes |

> **Important Notes**
> Autocommit is not "unsafe" — a single autocommitted `UPDATE` is itself fully atomic (it either commits or it
> doesn't). The danger is exclusively when **multiple** statements that depend on each other are left to
> autocommit *individually*, because then there's a window between them where a crash or concurrent transaction
> can observe or create an inconsistent in-between state.

---

## 11.11 Comparisons

**SAVEPOINT vs. (pseudo-)nested transaction**

| | `SAVEPOINT` | "Nested" `BEGIN` |
|---|---|---|
| Actually supported by PostgreSQL/MySQL? | Yes | No — ignored (PG) or implicit-commits the outer one (MySQL) |
| Can undo just the inner portion? | Yes, via `ROLLBACK TO SAVEPOINT` | N/A |
| Can commit just the inner portion independently? | No — only the outer `COMMIT` exists | N/A |
| Standard, portable syntax? | Mostly (keyword differs slightly, e.g. SQL Server's `SAVE TRANSACTION`) | Not applicable |

**Isolation levels, side by side** — see the full matrix in §11.7.

---

## 11.12 Real-World Use Cases

- **Financial transfers** (§11.3) — the debit and credit must be atomic; this is the textbook case and exactly why
  `banking_db` models it.
- **Order placement with inventory decrement** — inserting an order row and decrementing a `products.stock_qty`
  column must happen together; if the decrement fails (insufficient stock), the order insert must not persist
  either. (Modeled in `ecommerce_db` in later chapters.)
- **Loan disbursement** — creating a `loans` row and crediting the corresponding `accounts.balance` for the
  disbursed amount must be atomic; a crash between them would create a loan record with no money ever transferred,
  or money transferred with no loan on record.
- **Batch corrections** — reversing a mis-posted transaction (inserting a compensating `transactions` row and
  adjusting `accounts.balance`) needs the same all-or-nothing guarantee.
- **Any multi-table write where a foreign key or business invariant spans more than one row** — the general
  pattern behind all of the above.

---

## 11.13 Practice Questions

1. Explain, in your own words, the difference between what Atomicity guarantees and what Consistency guarantees.
   Use a `banking_db` example for each that is *not* the money-transfer example from this chapter.
2. Why does PostgreSQL not truly implement Read Uncommitted, and what property of its storage engine makes dirty
   reads structurally impossible regardless of isolation level setting?
3. A transaction runs `SELECT balance FROM accounts WHERE account_id = 4` twice, five seconds apart, and gets two
   different answers both times, with no error. What is the minimum isolation level under which this is possible,
   and what is the minimum level that would prevent it?
4. Write the two-session timeline for a **phantom read** anomaly using `banking_db.transactions` instead of
   `accounts` — for example, one session counting transactions for `account_id = 1` twice while another session
   inserts a new transaction row for that account in between.
5. Explain why write skew is not caught by ordinary row-level lost-update detection. What specifically makes it
   different from a lost update?
6. A junior developer writes: `BEGIN; UPDATE accounts SET balance = balance - 500 WHERE account_id = 3; COMMIT;`
   and separately, in another script, `BEGIN; UPDATE accounts SET balance = balance + 500 WHERE account_id = 3;
   COMMIT;` — running them as two separate transactions instead of one. What could go wrong if the second script
   never runs due to a crash, and why does this violate the spirit of atomicity even though each statement
   individually "succeeded"?
7. What is the practical difference, in PostgreSQL, between `ROLLBACK` and `ROLLBACK TO SAVEPOINT sp1`? Under what
   circumstances would you need the latter instead of the former?
8. In MySQL, what happens if you run `SAVEPOINT sp1;` followed later by `CREATE TABLE tmp_test (id INT);` inside
   the same transaction? Is the `CREATE TABLE` affected by a later `ROLLBACK TO SAVEPOINT sp1`? Why or why not?
9. A PostgreSQL transaction fails partway through with a constraint violation, and the developer, unaware of
   PostgreSQL's error-abort behavior, runs three more `SELECT` statements hoping to inspect the data before
   deciding what to do. What will happen, and what should they have done instead?
10. Design (in words, then in SQL) a transaction against `banking_db` that opens a new `SAVINGS` account for
    customer_id 5 and, in the same transaction, records an initial `DEPOSIT` transaction row — but ensure that if
    the account insert fails (e.g., an invalid `account_type`), no orphaned transaction row is ever created.

---

## 11.14 Chapter-Ending Challenge

**Write a complete, plain-SQL (no stored procedure yet — that's Chapter 19) transactional script that transfers
₹25,000 from account 4 (Suresh Menon, SAVINGS, balance ₹300,000) to account 7 (Manoj Tiwari, CURRENT, balance
₹5,000, status `FROZEN`).**

Your script must:

1. Open an explicit transaction.
2. Verify the source account (4) has sufficient balance for the debit.
3. Verify the destination account (7) is `ACTIVE` (not `FROZEN` or `CLOSED`) before crediting it — this transfer
   should be **rejected** because account 7 is frozen, and your script should demonstrate the **rollback path**.
4. If both checks pass: debit the source, credit the destination, and insert matching `TRANSFER_OUT` /
   `TRANSFER_IN` rows into `transactions`, then commit.
5. If either check fails: roll back cleanly, leaving both accounts and `transactions` completely untouched.
6. Include comments explaining each decision point, and show what the final state of both accounts and the
   `transactions` table should look like given that account 7 is frozen (i.e., the transfer must **not** go
   through).

A reference solution outline (try writing your own first):

```sql
BEGIN;

-- Step 1: check destination account status BEFORE touching any balances
DO $$
DECLARE
    dest_status TEXT;
    src_balance NUMERIC;
BEGIN
    SELECT status  INTO dest_status FROM banking_db.accounts WHERE account_id = 7;
    SELECT balance INTO src_balance FROM banking_db.accounts WHERE account_id = 4;

    IF dest_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Destination account % is not ACTIVE (status: %)', 7, dest_status;
    END IF;

    IF src_balance < 25000.00 THEN
        RAISE EXCEPTION 'Source account % has insufficient balance (% < 25000.00)', 4, src_balance;
    END IF;
END $$;

-- If we reach here, both checks passed. (In this scenario, they will NOT pass —
-- account 7 is FROZEN — so the DO block above raises an exception, which in
-- PostgreSQL aborts the transaction automatically per §11.8.)

UPDATE banking_db.accounts SET balance = balance - 25000.00 WHERE account_id = 4;
UPDATE banking_db.accounts SET balance = balance + 25000.00 WHERE account_id = 7;

INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
VALUES (4, 'TRANSFER_OUT', 25000.00, 7, 'Transfer to Manoj Tiwari');

INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
VALUES (7, 'TRANSFER_IN', 25000.00, 4, 'Transfer from Suresh Menon');

COMMIT;
-- Expected outcome for THIS scenario: the DO block's RAISE EXCEPTION fires
-- ("Destination account 7 is not ACTIVE (status: FROZEN)"), which aborts the
-- transaction. The COMMIT is never reached in a successful state — you must
-- issue ROLLBACK; explicitly to clear the aborted transaction:
ROLLBACK;

-- Final verification: nothing changed.
SELECT account_id, balance, status FROM banking_db.accounts WHERE account_id IN (4, 7);
--  account_id | balance   | status
--  4          | 300000.00 | ACTIVE     (unchanged)
--  7          | 5000.00   | FROZEN     (unchanged)
SELECT COUNT(*) FROM banking_db.transactions WHERE related_account_id IN (4, 7) AND description LIKE '%Manoj%';
--  0  (no transaction rows were ever inserted)
```

As an extension, modify the script to transfer instead to account 3 (Neha Agarwal, `ACTIVE`), and confirm both
checks pass, both balances update correctly, and exactly two new `transactions` rows appear.

---

## Key Takeaways

- A **transaction** groups statements into a single all-or-nothing unit, controlled with `BEGIN`, `COMMIT`,
  `ROLLBACK`, and partially undone with `SAVEPOINT` / `ROLLBACK TO SAVEPOINT` / `RELEASE SAVEPOINT`.
- **ACID** — Atomicity (all-or-nothing), Consistency (constraints always hold), Isolation (concurrent transactions
  don't see each other's half-finished work), Durability (committed data survives a crash, via WAL) — are four
  independent guarantees, each preventing a specific, concrete failure mode, not vague buzzwords.
- **Isolation levels** trade correctness for concurrency: Read Uncommitted (weakest, and not truly implemented by
  PostgreSQL) → Read Committed (PostgreSQL's and SQL Server's and Oracle's default) → Repeatable Read (MySQL
  InnoDB's default) → Serializable (strongest, only level that prevents write skew).
- **Anomalies** — dirty reads, non-repeatable reads, phantom reads, lost updates, write skew — are precise,
  reproducible phenomena, each prevented starting at a specific isolation level, via either locking (blocking
  conflicting transactions) or MVCC (snapshot isolation plus conflict detection at commit time).
- Dialect differences are not trivia — they're production risk: PostgreSQL aborts an entire transaction on any
  error until `ROLLBACK`; MySQL's DDL implicitly commits; Oracle only offers two isolation levels; SQL Server adds
  a non-standard `SNAPSHOT` level. Assuming one dialect's behavior in another is a common source of real bugs.

## What's Next

Chapter 11 established *what* a transaction guarantees and *how much* isolation you can ask for. It deliberately
stopped short of explaining the actual **locks** that make blocking, waiting, and deadlocks happen underneath
those guarantees — that mechanism is the subject of **Chapter 12 — Locks & Concurrency**, where you'll see row
locks, table locks, `FOR UPDATE` / `FOR SHARE`, deadlock detection, and how to diagnose a blocked query in
`banking_db` in practice.
