# Chapter 21 — Cursors (Extremely Detailed)

> Part V — Procedural SQL
> Database used throughout: **`banking_db`** (`customers`, `accounts`, `transactions`, `loans`, `audit_log`), with a
> secondary appearance from **`company_db`** (`employees`, `salaries`, `attendance`)
> Prerequisite: run `psql -f databases/banking_db.sql` and `psql -f databases/company_db.sql` before working
> through this chapter. You should already be comfortable with Chapter 19 (Stored Procedures) and Chapter 20
> (Advanced Functions) — cursors live almost exclusively inside PL/pgSQL blocks, procedures, and functions.

---

## The Mental Model Chain (read this first — it recurs all chapter)

Every section of this chapter, and every one of the eight worked examples, walks through the same six questions
in the same order. Internalize this chain now, because it is the single most important teaching device in the
chapter:

```
1. WHY does this feature exist?          — what problem is unsolvable without it?
2. HOW does it move through data?        — row by row, in what order?
3. WHAT STATE does it maintain?          — a position/pointer, open/closed, transaction binding
4. HOW does FETCH work, mechanically?    — advance position, copy current row into variables
5. WHAT happens INTERNALLY?              — one query plan, then N cheap "give me the next tuple" calls
6. WHY is set-based SQL usually better?  — could the same job be one statement instead of N?
```

Question 6 is not an afterthought. It is the point of the chapter. Cursors are a real, necessary tool — but they
are also the single most over-used anti-pattern that developers who come from procedural/imperative languages
(Java, Python, C#) bring into SQL. This chapter teaches you cursors *and* teaches you to recognize the 95% of
cases where you should reach for a `JOIN`, `UPDATE ... WHERE`, window function, or CTE instead.

---

## 21.1 What Is a Cursor? (Plain-Language Explanation)

Imagine a huge printed ledger book — hundreds of pages, one row of numbers per line. You want to go through it
and do something with every single line: read the balance, decide something about it, maybe cross out a number
and write a new one next to it.

You don't rip out every page and hold the whole ledger in your two hands at once. Instead, you put your **finger**
on the first line. You read it. You slide your finger down to the next line. You read that one. And so on, one
line at a time, until your finger falls off the bottom of the last page.

That finger — a bookmark that remembers *exactly which row you're on* as you move through a list one row at a
time — is a **cursor**. It is not the data itself. It is a *position* inside a stream of rows, plus the mechanism
for asking "give me the next one."

Everything else in this chapter is that idea, formalized.

---

## 21.2 Technical Explanation

> A **cursor** is a database object that encapsulates the result set of a query and maintains a **position (state)**
> within that result set, allowing the calling program to retrieve and process the result **row by row** rather
> than as a single set.

Unpack that sentence:

- **"Encapsulates the result set of a query"** — a cursor is *bound* to a `SELECT` statement. That statement is
  parsed and planned once, up front.
- **"Maintains a position"** — after you fetch row 3, the cursor remembers that you're at row 3. The next `FETCH`
  gives you row 4. This is state that a plain `SELECT` does not have — a plain `SELECT` returns everything at once
  with no concept of "where you are."
- **"Row by row rather than as a single set"** — this is the defining contrast with ordinary SQL. SQL is
  fundamentally a **set-based** language: a `SELECT` describes *what* rows you want, and the engine decides how to
  produce all of them together. A cursor deliberately steps outside that model and gives you **procedural,
  imperative** control: get one row, do something, get the next row, do something, repeat.

Cursors exist inside procedural extensions to SQL — PL/pgSQL (PostgreSQL), PL/SQL (Oracle), T-SQL (SQL Server),
and MySQL's stored-procedure `DECLARE ... CURSOR` syntax. You will almost never see a cursor in plain, top-level
SQL, because plain SQL has no loop construct to drive one.

---

## 21.3 Why Cursors Exist

If SQL is fundamentally set-based, and set-based operations are (as this chapter will prove in detail) almost
always faster and shorter, why does *every* major RDBMS ship a cursor mechanism?

Because a small, genuine class of problems **cannot** be expressed as a single set-based SQL statement:

1. **Per-row calls to external, non-SQL logic.** You need to invoke a stored procedure once *per row*, and that
   procedure does something a plain `UPDATE` can't express — e.g., call a payment gateway, write to a different
   table based on row-specific logic, or apply a multi-step business rule that branches differently for every row.
2. **Per-row side effects that must happen in row order.** E.g., generating a sequence number that depends on the
   previous row's outcome, or writing one file/log entry per row via dynamic SQL that targets a *different* table
   name for each row (`EXECUTE format('INSERT INTO archive_%s ...', v_year)`).
3. **Procedural ETL steps that genuinely branch per row** in ways a `CASE` expression cannot capture — for
   example, when the *next data source to query* depends on a value read from the current row.
4. **Interactive/administrative tooling** — scripts that need to show progress, prompt, or checkpoint between rows.

Cursors are the bridge between SQL's declarative, set-based world and PL/pgSQL's procedural, imperative world.
They let you say "give me one row of this result at a time, into these variables, so I can run arbitrary
procedural code against it." That bridge is legitimate and necessary — the mistake (covered in depth in §21.9 and
§21.8) is reaching for it when a single `UPDATE`, `JOIN`, or window function would do the same job in one
statement.

---

## 21.4 The Cursor Lifecycle

A cursor moves through five well-defined states. Think of it as a small state machine:

```
                 DECLARE
          (define the cursor + its query;
           no query execution happens yet)
                     │
                     ▼
              ┌─────────────┐
              │   DECLARED   │  (cursor exists as a named object, unopened)
              └──────┬───────┘
                     │ OPEN
                     │ (the query is EXECUTED; the cursor is
                     │  positioned BEFORE the first row)
                     ▼
              ┌─────────────┐
        ┌────▶│    OPEN      │◀────┐
        │     │ (positioned  │     │
        │     │  on a row,   │     │
        │     │  or past the │     │
        │     │  end)        │     │
        │     └──────┬───────┘     │
        │            │             │
   FETCH/MOVE        │        FETCH/MOVE
   (advances or      │        (advances or
   repositions;      │        repositions;
   copies current    │        no copy for MOVE)
   row into vars      │
   for FETCH)         │
        │            │             │
        └────────────┘             │
                     │             │
                     │ more FETCH/MOVE
                     └─────────────┘
                     │
                     │ CLOSE
                     │ (releases the server-side resources:
                     │  the query plan, any held locks/snapshot,
                     │  the position)
                     ▼
              ┌─────────────┐
              │    CLOSED    │
              └─────────────┘
```

Walking through each transition:

| Step | What happens | Analogy |
|---|---|---|
| **DECLARE** | You name the cursor and attach a `SELECT` query to it. **Nothing executes yet.** This is just a definition, like declaring a variable. | Writing "I will read this book" on a sticky note — you haven't opened the book. |
| **OPEN** | The database **executes** the query (or at least begins executing it / builds the query plan and starts producing rows) and positions the cursor **before the first row**. Server-side resources (a snapshot of the data, a query plan, possibly locks) are now allocated. | Opening the book to page 1, finger hovering above the first line. |
| **FETCH** | Retrieves the **next** row (or next *N* rows) from the current position **into variables**, then **advances** the position past what was fetched. If there is no next row, `FETCH` returns nothing and sets a "not found" indicator (`FOUND` in PL/pgSQL). | Sliding your finger down to the next line and reading it aloud. |
| **MOVE** | Repositions the cursor **without retrieving data** — skip forward N rows, jump to the last row, or (if the cursor is declared `SCROLL`, i.e., scrollable) move backward. | Sliding your finger down (or up) the page without reading anything out loud. |
| **CLOSE** | Releases all server-side resources associated with the cursor: the query plan, the snapshot, any locks it held open, the position itself. After `CLOSE`, the cursor cannot be fetched from again (unless re-`OPEN`ed). | Closing the book and putting it back on the shelf. |

> **Important Notes**
> - `DECLARE` never touches the data. Query execution begins at `OPEN`.
> - A freshly opened cursor is positioned **before** row 1 — the first `FETCH` retrieves row 1, not some
>   "current" row. There is no current row until the first successful `FETCH`.
> - `MOVE` is rare in application code but useful for skipping a known number of header/junk rows, or (with a
>   `SCROLL` cursor) implementing "page back" logic.
> - Forgetting `CLOSE` doesn't corrupt data, but it **leaks server-side resources** for the lifetime of the
>   session or transaction — see the Common Mistakes section (§21.9).

---

## 21.5 Cursor Variables, Explicit vs. Implicit Cursors, and Related Concepts

### 21.5.1 The `refcursor` Type

PostgreSQL's PL/pgSQL represents a cursor, when you need to pass it around as a value (into a variable, as a
function parameter, as a function's return type), using the built-in type `refcursor`. A `refcursor` value is
essentially **a name pointing at a server-side portal** (the internal object that holds the cursor's execution
state). You can:

- Assign a cursor a name explicitly (`OPEN cur FOR SELECT ...;` where `cur` is a `refcursor` variable already
  holding a name, or let PostgreSQL auto-generate one).
- Pass a `refcursor` as an `OUT` parameter from a function, so that the **caller** can `FETCH` from it after the
  function returns (§21.5.6 — this is one of the most distinctive PostgreSQL cursor patterns).

```plpgsql
DECLARE
    my_cursor refcursor;   -- a variable that will HOLD a reference to a cursor/portal
```

### 21.5.2 Explicit Cursors vs. Implicit Cursors

**Explicit cursors** are the ones you declare, open, fetch from, and close yourself, with full control over every
step:

```plpgsql
DECLARE
    cur_accounts CURSOR FOR SELECT account_id, balance FROM accounts;
BEGIN
    OPEN cur_accounts;
    FETCH cur_accounts INTO v_id, v_balance;
    CLOSE cur_accounts;
END;
```

**Implicit cursors** are cursors PL/pgSQL creates and manages *for you*, behind the scenes, in two situations you
have already been using since Chapter 19 without necessarily calling them "cursors":

1. **Every `FOR record IN (SELECT ...) LOOP ... END LOOP`** — PL/pgSQL implicitly declares a cursor for the
   query, opens it, fetches one row per iteration into `record`, and closes it automatically when the loop ends
   (whether it ends normally or via `EXIT`/`RETURN`/an exception). You never see `OPEN`/`FETCH`/`CLOSE` because
   the language is doing it for you.
2. **Every plain `SELECT ... INTO variable` (single-row select)** — internally, PL/pgSQL opens a cursor for the
   query, fetches exactly one row, and closes it. This is why `SELECT INTO` sets the special boolean variable
   `FOUND`: `FOUND` is `TRUE` if the implicit fetch retrieved a row, `FALSE` if it didn't (zero rows matched).
   `FOUND` is also set after `FETCH` from an explicit cursor, after `UPDATE`/`DELETE`/`INSERT ... RETURNING`
   (`TRUE` if at least one row was affected), and after a completed `FOR` loop (`TRUE` if the loop body executed
   at least once).

```plpgsql
DO $$
DECLARE
    v_balance NUMERIC(14,2);
BEGIN
    SELECT balance INTO v_balance FROM accounts WHERE account_id = 999; -- doesn't exist
    IF NOT FOUND THEN
        RAISE NOTICE 'No account with that id — implicit cursor found zero rows';
    END IF;
END $$;
```

> **Important Notes**
> - `FOUND` is a **single global-per-block** flag — it gets overwritten by the *next* implicit or explicit cursor
>   operation. Check it immediately after the operation you care about.
> - Prefer the **cursor `FOR` loop** (`FOR rec IN cur LOOP ... END LOOP` or `FOR rec IN SELECT ... LOOP ... END LOOP`)
>   over manual `OPEN`/`FETCH`/`EXIT WHEN NOT FOUND`/`CLOSE` whenever you don't need mid-loop control (like
>   `WHERE CURRENT OF`, parameterization decided at runtime, or holding the cursor open across calls). It is
>   shorter, and it is **impossible to forget to close** — PL/pgSQL closes it for you even if the loop exits via
>   `RETURN` or an exception.

### 21.5.3 Parameterized Cursors

A cursor's query can depend on a value supplied when you `OPEN` it — a **parameterized cursor**:

```plpgsql
DECLARE
    cur_customer_accounts CURSOR (p_customer_id INT) FOR
        SELECT account_id, account_type, balance
        FROM accounts
        WHERE customer_id = p_customer_id;
...
OPEN cur_customer_accounts(3);   -- bind p_customer_id = 3 at OPEN time
```

The parameter list appears after the cursor name, like a tiny function signature. The query plan is built using
that bound value the moment you `OPEN`. This is different from writing the literal value directly into the query
text (which would require redeclaring the cursor for every customer) — a parameterized cursor is declared **once**
and reused with different arguments.

### 21.5.4 Cursor `FOR` Loops (the idiomatic, safest pattern)

```plpgsql
FOR v_rec IN cur_accounts LOOP
    RAISE NOTICE 'account % balance %', v_rec.account_id, v_rec.balance;
END LOOP;
```

or, even more common, skip the explicit `DECLARE` entirely and hand the query straight to the loop:

```plpgsql
FOR v_rec IN SELECT account_id, balance FROM accounts LOOP
    RAISE NOTICE 'account % balance %', v_rec.account_id, v_rec.balance;
END LOOP;
```

This single construct **opens** the cursor, **fetches** every row one at a time into `v_rec` (a row-type variable
you don't have to pre-declare fields for — PL/pgSQL infers them from the query), and **closes** the cursor when
the loop finishes — including if you `RETURN` or `RAISE` out of the middle of it. This is why it's the
recommended default: it is impossible to leak the cursor.

### 21.5.5 Cursors With Procedures

A common legitimate cursor use case: a procedure that must invoke **another** procedure once per row, because the
per-row action is itself multi-statement procedural logic that can't be inlined into a single `UPDATE`.

```plpgsql
CREATE OR REPLACE PROCEDURE apply_late_fee(p_loan_id INT, p_fee NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (table_name, operation, row_pk, new_data)
    VALUES ('loans', 'UPDATE', p_loan_id::TEXT,
            jsonb_build_object('late_fee_applied', p_fee, 'reason', 'overdue processing'));
    -- in a real system this would also debit an account, notify the customer, etc.
END $$;

CREATE OR REPLACE PROCEDURE process_defaulted_loans()
LANGUAGE plpgsql AS $$
DECLARE
    cur_defaulted CURSOR FOR
        SELECT loan_id, loan_amount FROM loans WHERE status = 'DEFAULTED';
    v_loan_id RECORD;
BEGIN
    FOR v_loan_id IN cur_defaulted LOOP
        CALL apply_late_fee(v_loan_id.loan_id, v_loan_id.loan_amount * 0.02);
    END LOOP;
END $$;
```

This is exactly the "why cursors exist" reason #1 from §21.3: `apply_late_fee` is a full procedure call per row,
not an expression a set-based `UPDATE` could inline.

### 21.5.6 Cursors With Functions — the `refcursor` OUT-Parameter Pattern

PostgreSQL has a specific, precise pattern for **returning a cursor from a function so the caller can fetch from
it afterward**:

```plpgsql
CREATE OR REPLACE FUNCTION open_customer_accounts(p_customer_id INT)
RETURNS refcursor
LANGUAGE plpgsql AS $$
DECLARE
    ref refcursor;
BEGIN
    OPEN ref FOR
        SELECT account_id, account_type, balance
        FROM accounts
        WHERE customer_id = p_customer_id;
    RETURN ref;
END $$;
```

Using it from a client session:

```sql
BEGIN;                                    -- must be inside a transaction
SELECT open_customer_accounts(3);         -- returns a cursor name, e.g. <unnamed portal 1>
-- the value returned above is the cursor's name; use it (or capture it) to FETCH:
FETCH ALL FROM "<unnamed portal 1>";
COMMIT;                                    -- closes the cursor (unless declared WITH HOLD)
```

More typically you assign the returned name so it's usable:

```sql
BEGIN;
SELECT open_customer_accounts(3) AS cur;
\gset
FETCH ALL FROM :"cur";
COMMIT;
```

> **Important Notes**
> - **The function opens the cursor but does not fetch from it.** Opening a cursor executes the query and creates
>   a *portal* — a server-side handle — but doesn't materialize all the rows or hand them back yet. The caller
>   fetches afterward.
> - **This only works within the same transaction.** A cursor/portal, by default, lives and dies with the
>   transaction that opened it. If the function's `OPEN` and the caller's `FETCH` are not in the same transaction
>   (e.g., the function ran under autocommit and implicitly committed), the cursor no longer exists by the time
>   you try to fetch — you'll get an error like `cursor "..." does not exist`. This is precisely why the example
>   above wraps everything in an explicit `BEGIN ... COMMIT`.
> - This pattern is how PostgreSQL functions return "table-like" results without using `RETURNS TABLE` /
>   `RETURNS SETOF` (covered in Chapter 20) — it's more flexible when the caller wants to control fetch timing or
>   fetch in batches, but it demands the same-transaction discipline above.

### 21.5.7 Cursors and Transactions: Lifetime and `WITH HOLD`

By default, a cursor's lifetime is bound to the transaction that opened it: **`COMMIT` or `ROLLBACK` closes every
ordinary cursor** open in that transaction. If your application tries to `FETCH` from a cursor after committing,
it fails.

**`WITH HOLD`** *(PostgreSQL)* changes this: a cursor declared `WITH HOLD` survives a `COMMIT` — its result set is
materialized (copied into a temporary area) at commit time so it can still be fetched afterward, in later
transactions, until it's explicitly `CLOSE`d or the session ends.

```plpgsql
-- Ordinary cursor: dies at COMMIT
BEGIN;
DECLARE cur_a CURSOR FOR SELECT * FROM accounts;
FETCH cur_a;
COMMIT;
FETCH cur_a;   -- ERROR: cursor "cur_a" does not exist

-- WITH HOLD cursor: survives COMMIT
BEGIN;
DECLARE cur_b CURSOR WITH HOLD FOR SELECT * FROM accounts;
FETCH cur_b;
COMMIT;
FETCH cur_b;   -- works fine — the result set was held past the commit
CLOSE cur_b;   -- must still close it manually eventually
```

> **⚠️ Warnings**
> - `WITH HOLD` cursors consume server-side storage for as long as they're open, because the whole result set (or
>   the remaining portion) must be preserved independent of any one transaction's snapshot. Leaving them open is a
>   classic resource leak in long-running application sessions.
> - In plain PL/pgSQL blocks (`DO $$ ... $$`), a cursor's natural scope is the block/transaction it runs in — the
>   `WITH HOLD` pattern matters mainly for cursors opened by top-level SQL clients (`psql`, application drivers)
>   that need a cursor to outlive one transaction.

---

## 21.6 The Progressive Example Series

All eight examples run against `banking_db`. Run `SET search_path TO banking_db;` first (the seed script already
does this within its own session, but reconnect and re-set it if you're in a fresh `psql` session). Recall the
seed data relevant to accounts:

| account_id | customer_id | account_type | balance | status |
|---|---|---|---|---|
| 1 | 1 (Ravi Shankar) | SAVINGS | 150000.00 | ACTIVE |
| 2 | 1 (Ravi Shankar) | CURRENT | 50000.00 | ACTIVE |
| 3 | 2 (Neha Agarwal) | SAVINGS | 80000.00 | ACTIVE |
| 4 | 3 (Suresh Menon) | SAVINGS | 300000.00 | ACTIVE |
| 5 | 3 (Suresh Menon) | FIXED_DEPOSIT | 500000.00 | ACTIVE |
| 6 | 4 (Kavita Desai) | SAVINGS | 20000.00 | ACTIVE |
| 7 | 5 (Manoj Tiwari) | CURRENT | 5000.00 | FROZEN |

### Example 1 — The Simplest Possible Cursor (declare, open, fetch one row, close)

```plpgsql
DO $$
DECLARE
    cur_accounts CURSOR FOR
        SELECT account_id, account_type, balance
        FROM accounts
        ORDER BY account_id;
    v_account_id   accounts.account_id%TYPE;
    v_account_type accounts.account_type%TYPE;
    v_balance      accounts.balance%TYPE;
BEGIN
    OPEN cur_accounts;                                    -- (1)
    FETCH cur_accounts INTO v_account_id, v_account_type, v_balance;  -- (2)
    RAISE NOTICE 'First account: id=%, type=%, balance=%',
                 v_account_id, v_account_type, v_balance;  -- (3)
    CLOSE cur_accounts;                                    -- (4)
END $$;
```

**Line by line:**

- `DECLARE cur_accounts CURSOR FOR SELECT ... ORDER BY account_id;` — defines a cursor named `cur_accounts` bound
  to a query. Nothing executes here; this is a declaration, like declaring a variable's type.
- `v_account_id accounts.account_id%TYPE;` (and the two lines after it) — declare variables whose types are
  pinned to the actual column types (`%TYPE` — covered in Chapter 19) so they always match the table, even if the
  column's type changes later.
- `OPEN cur_accounts;` **(1)** — this is where the query actually runs. PostgreSQL plans and begins executing
  `SELECT account_id, account_type, balance FROM accounts ORDER BY account_id`, and positions the cursor
  **before** the first row (`account_id = 1`).
- `FETCH cur_accounts INTO v_account_id, v_account_type, v_balance;` **(2)** — retrieves the **next** row (the
  first row, since we just opened) and copies its three columns into the three variables, in order. The cursor's
  position now advances to point at row 2 (`account_id = 2`).
- `RAISE NOTICE ...;` **(3)** — prints the values we just fetched. Output: `First account: id=1, type=SAVINGS,
  balance=150000.00`.
- `CLOSE cur_accounts;` **(4)** — releases the cursor's resources. We never looked at rows 2–7; that's fine, this
  example is deliberately about fetching exactly one row.

This example demonstrates the full lifecycle (DECLARE → OPEN → FETCH → CLOSE) with the loop step skipped
entirely — the minimum viable cursor.

### Example 2 — Reading Every Row in a Loop

```plpgsql
DO $$
DECLARE
    cur_accounts CURSOR FOR
        SELECT account_id, account_type, balance
        FROM accounts
        ORDER BY account_id;
    v_account_id   INT;
    v_account_type VARCHAR(20);
    v_balance      NUMERIC(14,2);
BEGIN
    OPEN cur_accounts;                                            -- (1)
    LOOP
        FETCH cur_accounts INTO v_account_id, v_account_type, v_balance;  -- (2)
        EXIT WHEN NOT FOUND;                                       -- (3)
        RAISE NOTICE 'Account % (%): balance = %',
                     v_account_id, v_account_type, v_balance;      -- (4)
    END LOOP;
    CLOSE cur_accounts;                                            -- (5)
END $$;
```

**Line by line:**

- `OPEN cur_accounts;` **(1)** — same as before: executes the query, positions before row 1.
- `LOOP ... END LOOP;` — a bare, unconditional loop. Something inside it must `EXIT`, or it runs forever.
- `FETCH cur_accounts INTO ...;` **(2)** — retrieves the next row each time through the loop. The *first* time,
  that's `account_id = 1`; the *seventh* time, that's `account_id = 7`; the *eighth* time, there is no row left.
- `EXIT WHEN NOT FOUND;` **(3)** — this is the critical guard. After each `FETCH`, PL/pgSQL sets the special
  `FOUND` boolean: `TRUE` if a row was retrieved, `FALSE` if the cursor was already past the last row. On the
  eighth iteration, `FETCH` returns nothing, `FOUND` becomes `FALSE`, and `EXIT WHEN NOT FOUND` breaks out of the
  loop *before* the `RAISE NOTICE` runs with stale/garbage variable values.
- `RAISE NOTICE ...;` **(4)** — runs once per real row, seven times total, printing each account.
- `CLOSE cur_accounts;` **(5)** — releases the cursor after all rows are consumed.

> **⚠️ Warnings** — this is the manual pattern that Example 3 onward will mostly replace with the cursor `FOR`
> loop. It's shown here explicitly once so you understand *exactly* what a `FOR` loop is doing for you
> automatically. If you ever omit `EXIT WHEN NOT FOUND` (or check the wrong condition), this becomes an
> **infinite loop** — see §21.9.

### Example 3 — Processing Rows: Classifying Balance Into a Tier

```plpgsql
DO $$
DECLARE
    cur_tier CURSOR FOR
        SELECT account_id, balance FROM accounts ORDER BY account_id;
    v_tier TEXT;
BEGIN
    FOR v_rec IN cur_tier LOOP                                     -- (1)
        v_tier := CASE                                             -- (2)
                      WHEN v_rec.balance < 20000  THEN 'LOW'
                      WHEN v_rec.balance < 100000 THEN 'MEDIUM'
                      ELSE 'HIGH'
                  END;
        RAISE NOTICE 'Account % balance % -> tier %',
                     v_rec.account_id, v_rec.balance, v_tier;       -- (3)
    END LOOP;
END $$;
```

**Line by line:**

- `FOR v_rec IN cur_tier LOOP` **(1)** — this is the idiomatic **cursor `FOR` loop**. PL/pgSQL implicitly does the
  `OPEN`, `FETCH` (once per iteration, into the automatically-typed record variable `v_rec`), and `CLOSE` (when
  the loop ends) for you. `v_rec` is a row-type value with fields `v_rec.account_id` and `v_rec.balance` matching
  the cursor's `SELECT` list — you never declared those fields; PL/pgSQL inferred them.
- `v_tier := CASE ... END;` **(2)** — this is the actual **row processing**: a computed classification derived
  from the fetched value, something a plain `SELECT` *could* also compute (with a `CASE` expression directly in
  the query) — the cursor here is doing nothing that set-based SQL couldn't; it's shown as a teaching step before
  §21.8 makes that point explicit and rigorous.
- `RAISE NOTICE ...;` **(3)** — prints, per account: `Account 6 balance 20000.00 -> tier MEDIUM`, etc.

Expected tiers for the seed data: account 6 (20000) → `MEDIUM` (boundary is inclusive of 20000 falling into the
"not < 20000" branch), account 7 (5000) → `LOW`, account 3 (80000) → `MEDIUM`, accounts 1/4/5 (150000/300000/500000)
→ `HIGH`, account 2 (50000) → `MEDIUM`.

### Example 4 — Cursor With a Condition Checked Inside the Loop

```plpgsql
DO $$
BEGIN
    FOR v_rec IN
        SELECT account_id, account_type, status, balance
        FROM accounts
        ORDER BY account_id
    LOOP                                                          -- (1)
        IF v_rec.status = 'FROZEN' THEN                           -- (2)
            RAISE NOTICE 'ALERT: account % is FROZEN (balance %) — review required',
                         v_rec.account_id, v_rec.balance;          -- (3)
        END IF;
    END LOOP;
END $$;
```

**Line by line:**

- `FOR v_rec IN SELECT ... LOOP` **(1)** — this time the query is written directly in the `FOR` clause instead of
  a separately `DECLARE`d cursor — a shorthand PL/pgSQL allows for one-off implicit cursors. It still opens,
  fetches every row, and closes automatically; it still walks **all 7** accounts.
- `IF v_rec.status = 'FROZEN' THEN ... END IF;` **(2)** — the condition is evaluated **per fetched row, inside the
  loop body** — this is the "cursor with conditions" pattern: the cursor fetches everything, and procedural logic
  decides what to *do* with each row. Six of the seven rows fall through this `IF` doing nothing.
- `RAISE NOTICE ...;` **(3)** — fires exactly once, for `account_id = 7` (Manoj Tiwari's `CURRENT` account,
  balance 5000.00, `status = 'FROZEN'`), producing: `ALERT: account 7 is FROZEN (balance 5000.00) — review
  required`.

> **Important Notes** — notice this cursor still visits every row even though it only *acts* on one. A set-based
> equivalent (`SELECT * FROM accounts WHERE status = 'FROZEN'`) would let the engine skip straight to matching
> rows using an index, if one existed on `status`. Filtering inside the loop, instead of in the `WHERE` clause, is
> a common and costly cursor mistake — flagged again in §21.9.

### Example 5 — Cursor Updating Records With `WHERE CURRENT OF`

```plpgsql
DO $$
DECLARE
    cur_savings CURSOR FOR
        SELECT account_id, balance
        FROM accounts
        WHERE account_type = 'SAVINGS' AND status = 'ACTIVE'
        FOR UPDATE;                                                -- (1)
    v_account_id INT;
    v_balance    NUMERIC(14,2);
BEGIN
    OPEN cur_savings;                                              -- (2)
    LOOP
        FETCH cur_savings INTO v_account_id, v_balance;            -- (3)
        EXIT WHEN NOT FOUND;
        UPDATE accounts
        SET balance = ROUND(balance * 1.01, 2)
        WHERE CURRENT OF cur_savings;                              -- (4)
        RAISE NOTICE 'Account %: % -> %',
                     v_account_id, v_balance, ROUND(v_balance * 1.01, 2);
    END LOOP;
    CLOSE cur_savings;                                             -- (5)
END $$;
```

**Line by line:**

- `... FOR UPDATE;` **(1)** — this clause on the cursor's query is **mandatory** for `WHERE CURRENT OF` to work.
  It tells PostgreSQL to lock each row as it's fetched, so that a subsequent `UPDATE`/`DELETE ... WHERE CURRENT OF`
  is guaranteed to target the exact physical row the cursor is sitting on, with no risk that another session
  changed or removed it in between.
- `OPEN cur_savings;` **(2)** — executes the query: active `SAVINGS` accounts are `account_id` 1, 3, 4, 6.
- `FETCH cur_savings INTO v_account_id, v_balance;` **(3)** — pulls the next matching row into the variables.
- `UPDATE accounts SET balance = ROUND(balance * 1.01, 2) WHERE CURRENT OF cur_savings;` **(4)** — this is the
  distinctive syntax: instead of `WHERE account_id = v_account_id`, `WHERE CURRENT OF cur_savings` tells the
  engine "update whichever row the cursor `cur_savings` is *currently positioned on*." It updates exactly one row
  — the one just fetched — without needing to know or repeat its primary key.
- `CLOSE cur_savings;` **(5)** — releases the cursor (and its row locks) once every matching account has been
  processed.

This applies a 1% top-up to accounts 1, 3, 4, and 6 in turn: 150000.00→151500.00, 80000.00→80800.00,
300000.00→303000.00, 20000.00→20200.00.

> **⚠️ Warnings — dialect gap: `WHERE CURRENT OF` support**
> - **[PostgreSQL]** and **[Oracle]** both support `UPDATE ... WHERE CURRENT OF cursor_name` /
>   `DELETE ... WHERE CURRENT OF cursor_name`, provided the cursor's query is declared `FOR UPDATE` (Oracle
>   requires it too, via the cursor's `FOR UPDATE` clause).
> - **[MySQL] does NOT support `WHERE CURRENT OF` at all.** There is no equivalent syntax. If you need to update
>   the row a MySQL cursor is currently on, you must **capture its primary key into a variable during `FETCH`,
>   then issue a normal `UPDATE ... WHERE account_id = v_account_id`** after the fetch, e.g.:
>   ```sql
>   -- [MySQL] — no WHERE CURRENT OF; update by primary key instead
>   FETCH cur INTO v_account_id, v_balance;
>   UPDATE accounts SET balance = ROUND(v_balance * 1.01, 2) WHERE account_id = v_account_id;
>   ```
>   This is functionally equivalent as long as the primary key was fetched, but it does not get the same
>   "positioned on this exact physical row" locking guarantee that `WHERE CURRENT OF` gives — a plain `WHERE`
>   clause re-evaluates against the current table state and could, in principle, match zero or a different row if
>   the schema allowed the key to be non-unique (it won't for a real primary key, but the semantics differ).
> - **[SQL Server]** also supports `WHERE CURRENT OF cursor_name`, but only for cursors declared without certain
>   restrictions (they must be updatable — not `FAST_FORWARD`/read-only; see §21.7).

### Example 6 — Cursor With Per-Row Exception Handling

```plpgsql
DO $$
DECLARE
    cur_loans CURSOR FOR
        SELECT loan_id, customer_id, interest_rate FROM loans ORDER BY loan_id;
BEGIN
    FOR v_loan IN cur_loans LOOP                                   -- (1)
        BEGIN                                                      -- (2)
            IF v_loan.interest_rate > 9.00 THEN                    -- (3)
                RAISE EXCEPTION 'interest rate % too high for loan % (limit 9.00%%)',
                                v_loan.interest_rate, v_loan.loan_id;
            END IF;
            RAISE NOTICE 'Loan % OK (rate %)', v_loan.loan_id, v_loan.interest_rate;
        EXCEPTION                                                  -- (4)
            WHEN OTHERS THEN
                RAISE NOTICE 'Skipping loan % — validation failed: %',
                             v_loan.loan_id, SQLERRM;               -- (5)
                INSERT INTO audit_log (table_name, operation, row_pk, new_data)
                VALUES ('loans', 'UPDATE', v_loan.loan_id::TEXT,
                        jsonb_build_object('validation_error', SQLERRM));
        END;                                                       -- (6)
    END LOOP;
END $$;
```

**Line by line:**

- `FOR v_loan IN cur_loans LOOP` **(1)** — the outer cursor `FOR` loop, iterating all four loans.
- `BEGIN ... EXCEPTION ... END;` **(2)**/**(6)** — a **nested block** placed *inside* the loop body. This is the
  key structural idea: in PL/pgSQL, `EXCEPTION` handlers attach to a `BEGIN ... END` block, and a raised error
  unwinds only up to the nearest enclosing block that has a matching handler. By putting the `BEGIN/EXCEPTION/END`
  **inside** the loop instead of around it, an exception on one row is caught and handled **without terminating
  the loop** — the next iteration still runs.
- `IF v_loan.interest_rate > 9.00 THEN RAISE EXCEPTION ...; END IF;` **(3)** — a deliberately raised business-rule
  violation: "this bank does not allow active loans above 9.00% without manual review." Loan 3 (Kavita Desai,
  `interest_rate = 9.25`) will trigger this.
- `EXCEPTION WHEN OTHERS THEN` **(4)** — catches the exception raised in step 3 (and would also catch any *other*
  unexpected runtime error inside this row's processing, such as a type-conversion failure).
- `SQLERRM` **(5)** — a built-in variable available inside an exception handler holding the error message text of
  the exception just caught — here, `interest rate 9.25 too high for loan 3 (limit 9.00%)`.
- The handler logs the failure to `audit_log` and continues; when the `BEGIN/EXCEPTION/END` block finishes (either
  normally or via the handler), control returns to the top of the `LOOP`, and `FOR v_loan IN cur_loans` fetches
  the **next** loan — loan 4 is still processed even though loan 3 failed.

Result for the seed data: loans 1, 2, 4 (rates 8.50, 7.75, 8.00) print `Loan N OK`; loan 3 (rate 9.25) prints a
skip message and gets an `audit_log` row recording the validation error — and the loop still completes all four
rows.

> **Important Notes** — without the nested `BEGIN/EXCEPTION/END`, a `RAISE EXCEPTION` on loan 3 would propagate
> up out of the `FOR` loop and out of the entire `DO` block, aborting the whole batch (and, inside a transaction,
> potentially rolling back everything already done in that transaction) — loans 1 and 2's "OK" processing would
> never have been considered final. Catching **inside** the loop body is what makes per-row error isolation work.

### Example 7 — Parameterized Cursor (accounts for one specific customer)

```plpgsql
DO $$
DECLARE
    cur_customer_accounts CURSOR (p_customer_id INT) FOR         -- (1)
        SELECT account_id, account_type, balance
        FROM accounts
        WHERE customer_id = p_customer_id
        ORDER BY account_id;
    v_target_customer INT := 3;                                  -- (2)
BEGIN
    FOR v_rec IN cur_customer_accounts(v_target_customer) LOOP   -- (3)
        RAISE NOTICE 'Customer % — account % (%): balance %',
                     v_target_customer, v_rec.account_id, v_rec.account_type, v_rec.balance;
    END LOOP;
END $$;
```

**Line by line:**

- `CURSOR (p_customer_id INT) FOR SELECT ... WHERE customer_id = p_customer_id ...;` **(1)** — declares the
  cursor with a formal parameter, `p_customer_id`, used inside the query's `WHERE` clause. The cursor is defined
  **once**, generically, without committing to any particular customer.
- `v_target_customer INT := 3;` **(2)** — the value we'll run it for: customer 3 is Suresh Menon.
- `FOR v_rec IN cur_customer_accounts(v_target_customer) LOOP` **(3)** — this is where the parameter is **bound**:
  calling the cursor like a function, supplying the argument. PL/pgSQL substitutes `p_customer_id := 3` and opens
  the query `SELECT ... WHERE customer_id = 3 ...` at this point.

Output for the seed data (Suresh Menon, customer 3, owns accounts 4 and 5):
```
Customer 3 — account 4 (SAVINGS): balance 300000.00
Customer 3 — account 5 (FIXED_DEPOSIT): balance 500000.00
```

Change `v_target_customer := 1;` and rerun, and the same cursor definition now returns Ravi Shankar's two
accounts (1 and 2) instead — that's the entire point of parameterizing rather than hardcoding the filter.

### Example 8 — Cursor Over a Multi-Table Join: Generating a Per-Account Statement

This is the "control-break" pattern: a cursor joins three tables and the procedural code detects when the
`account_id` changes to print a new statement header, something a single flat `SELECT` cannot format as
human-readable grouped text on its own (only a procedural pass, or heavier string aggregation, can).

```plpgsql
DO $$
DECLARE
    cur_statement CURSOR FOR
        SELECT a.account_id, a.account_type, a.balance,
               c.first_name, c.last_name,
               t.transaction_id, t.transaction_type, t.amount, t.transaction_date
        FROM accounts a
        JOIN customers c ON c.customer_id = a.customer_id           -- (1)
        LEFT JOIN transactions t ON t.account_id = a.account_id      -- (2)
        WHERE a.customer_id = 1
        ORDER BY a.account_id, t.transaction_date;
    v_last_account INT := NULL;                                      -- (3)
BEGIN
    FOR v_rec IN cur_statement LOOP                                  -- (4)
        IF v_rec.account_id IS DISTINCT FROM v_last_account THEN     -- (5)
            RAISE NOTICE '--- Statement for % % — account % (%), balance % ---',
                         v_rec.first_name, v_rec.last_name,
                         v_rec.account_id, v_rec.account_type, v_rec.balance;
            v_last_account := v_rec.account_id;                      -- (6)
        END IF;

        IF v_rec.transaction_id IS NOT NULL THEN                     -- (7)
            RAISE NOTICE '   [%] % of % on %',
                         v_rec.transaction_id, v_rec.transaction_type,
                         v_rec.amount, v_rec.transaction_date;
        ELSE
            RAISE NOTICE '   (no transactions on this account)';
        END IF;
    END LOOP;
END $$;
```

**Line by line:**

- `JOIN customers c ON c.customer_id = a.customer_id` **(1)** — pulls in the customer's name for the header.
- `LEFT JOIN transactions t ON t.account_id = a.account_id` **(2)** — a **`LEFT JOIN`**, deliberately, so that an
  account with zero transactions still produces one row (with `t.*` columns `NULL`) instead of vanishing from the
  result — important so every account still gets a statement header even if it's transaction-free.
- `v_last_account INT := NULL;` **(3)** — the "control-break" variable: it remembers the account we last printed a
  header for.
- `FOR v_rec IN cur_statement LOOP` **(4)** — iterates every joined row (one row per transaction, or one row per
  account with no transactions), in `account_id, transaction_date` order — order matters here because the
  control-break logic depends on rows for the same account arriving consecutively.
- `IF v_rec.account_id IS DISTINCT FROM v_last_account THEN` **(5)** — `IS DISTINCT FROM` is a NULL-safe
  inequality check (true on the very first row, when `v_last_account` is still `NULL`, and true again every time
  the account changes). This is the moment we print a **new header** — once per account, not once per row.
- `v_last_account := v_rec.account_id;` **(6)** — updates the tracking variable so the next rows for the *same*
  account don't re-trigger the header.
- `IF v_rec.transaction_id IS NOT NULL THEN ... ELSE ... END IF;` **(7)** — because of the `LEFT JOIN`, a row with
  no matching transaction has `transaction_id IS NULL`; we print a friendly placeholder line instead of
  `[NULL] NULL of NULL on NULL`.

For customer 1 (Ravi Shankar, accounts 1 and 2), the output walks account 1's four transactions (salary credit,
ATM withdrawal, transfer out, and the earlier-listed rows in date order), prints one header line for account 1,
then switches to a new header for account 2 when the `account_id` changes, followed by account 2's single
deposit transaction.

> **Important Notes** — this exact "one header per group, then group's detail rows" output *could* also be built
> set-based with `string_agg()` and `GROUP BY`, producing one row per account with all its transactions
> concatenated into a single text column. The cursor version is shown here because real per-row **procedural**
> statement generation — e.g., writing each statement to a separate file, or emailing it — genuinely needs
> row-by-row iteration; producing a single combined report string does not, and should usually prefer the
> set-based `string_agg()` approach instead.

---

## 21.7 Dialect Comparison: Explicit Cursor Syntax

The cursor *concept* (declare/open/fetch/close, a `FOUND`-style flag, cursor loops) is universal, but every
dialect spells it differently.

### **[MySQL]**

MySQL cursors only exist inside stored programs (procedures/functions/triggers), must be declared **after**
regular variables but **before** handlers in the `DECLARE` section, and MySQL has no `%NOTFOUND`-style attribute —
instead you declare a `CONTINUE HANDLER FOR NOT FOUND` that sets a flag variable when a `FETCH` runs out of rows:

```sql
DELIMITER $$

CREATE PROCEDURE list_active_accounts()
BEGIN
    DECLARE v_done       INT DEFAULT FALSE;
    DECLARE v_account_id INT;
    DECLARE v_balance    DECIMAL(14,2);

    DECLARE cur CURSOR FOR
        SELECT account_id, balance FROM accounts WHERE status = 'ACTIVE';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;   -- MySQL's substitute for %NOTFOUND

    OPEN cur;

    read_loop: LOOP
        FETCH cur INTO v_account_id, v_balance;
        IF v_done THEN
            LEAVE read_loop;
        END IF;

        SELECT CONCAT('Account ', v_account_id, ': ', v_balance) AS msg;
    END LOOP read_loop;

    CLOSE cur;
END$$

DELIMITER ;
```

Key differences from PL/pgSQL: declaration **order is strict** (variables → cursors → handlers), the loop needs a
label (`read_loop:`) to `LEAVE`, and the "no more rows" signal is a handler-set flag checked manually, not an
automatic `FOUND`/`NOT FOUND` you can inline into `EXIT WHEN`.

### **[Oracle]**

Oracle's PL/SQL is the most cursor-rich dialect — the original design cursors above were modeled after. It offers
`%ROWTYPE`, and per-cursor attributes `%FOUND`, `%NOTFOUND`, `%ROWCOUNT`, and `%ISOPEN`:

```sql
DECLARE
    CURSOR cur_accounts IS
        SELECT account_id, balance FROM accounts WHERE status = 'ACTIVE';
    v_account cur_accounts%ROWTYPE;      -- row type matching the cursor's SELECT list
BEGIN
    OPEN cur_accounts;
    LOOP
        FETCH cur_accounts INTO v_account;
        EXIT WHEN cur_accounts%NOTFOUND;               -- Oracle's cursor-attribute NOT FOUND check
        DBMS_OUTPUT.PUT_LINE('Account ' || v_account.account_id || ': ' || v_account.balance);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Rows processed: ' || cur_accounts%ROWCOUNT);
    CLOSE cur_accounts;
END;
/
```

The idiomatic Oracle **cursor `FOR` loop** (equivalent to PL/pgSQL's) hides open/fetch/close entirely:

```sql
BEGIN
    FOR v_account IN (SELECT account_id, balance FROM accounts WHERE status = 'ACTIVE') LOOP
        DBMS_OUTPUT.PUT_LINE(v_account.account_id || ': ' || v_account.balance);
    END LOOP;
END;
/
```

Oracle's **REF CURSOR** (the ancestor of PostgreSQL's `refcursor`) is used to return a result set from a
procedure to a caller (or to a client application via JDBC/OCI):

```sql
CREATE OR REPLACE PROCEDURE get_customer_accounts(
    p_customer_id IN NUMBER,
    p_cursor      OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_cursor FOR
        SELECT account_id, account_type, balance
        FROM accounts
        WHERE customer_id = p_customer_id;
END;
/
```

| Oracle cursor attribute | Meaning |
|---|---|
| `%FOUND` | `TRUE` if the last `FETCH` returned a row |
| `%NOTFOUND` | `TRUE` if the last `FETCH` did **not** return a row (used to `EXIT`) |
| `%ROWCOUNT` | number of rows fetched **so far** |
| `%ISOPEN` | `TRUE` if the cursor is currently open |

### **[SQL Server]**

T-SQL uses `DECLARE ... CURSOR FOR`, `FETCH NEXT FROM`, and the global status variable `@@FETCH_STATUS`
(`0` = success, non-zero = no more rows / error):

```sql
DECLARE @account_id INT, @balance DECIMAL(14,2);

DECLARE cur CURSOR LOCAL FORWARD_ONLY STATIC FOR
    SELECT account_id, balance FROM accounts WHERE status = 'ACTIVE';

OPEN cur;
FETCH NEXT FROM cur INTO @account_id, @balance;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT 'Account ' + CAST(@account_id AS VARCHAR) + ': ' + CAST(@balance AS VARCHAR);
    FETCH NEXT FROM cur INTO @account_id, @balance;
END

CLOSE cur;
DEALLOCATE cur;      -- T-SQL requires this extra step to free the cursor's memory structure
```

T-SQL cursor declaration options (placed between `CURSOR` and `FOR`) control scope and behavior:

| Option | Meaning |
|---|---|
| `LOCAL` | cursor is visible only in the batch/procedure/trigger that created it (default in most contexts) |
| `GLOBAL` | cursor is visible to the whole connection, until explicitly deallocated or the connection closes |
| `FORWARD_ONLY` | can only `FETCH NEXT` — no scrolling backward (fastest, most common) |
| `SCROLL` | supports `FETCH FIRST/LAST/PRIOR/NEXT/ABSOLUTE n/RELATIVE n` — scrollable in both directions |
| `STATIC` | result set is materialized into `tempdb` at `OPEN` time — insensitive to later data changes |
| `KEYSET` | membership fixed at open, but non-key column values reflect later updates |
| `DYNAMIC` | fully reflects all data changes made by any session while the cursor is open (most expensive) |
| `FAST_FORWARD` | shorthand for `FORWARD_ONLY` + read-only, optimized — the recommended default for read-only scans |

> **Important Notes** — `DEALLOCATE` is a T-SQL-only extra step beyond `CLOSE`: `CLOSE` releases the current
> result set/locks; `DEALLOCATE` frees the cursor definition itself. Forgetting `DEALLOCATE` is SQL Server's
> specific variant of the "forgot to release cursor resources" mistake covered next.

---

## 21.8 The Centerpiece: Why Set-Based SQL Is Usually Preferred Over Cursors

> This is the single most important lesson in this chapter. Every dialect gives you cursors; almost every
> experienced SQL developer will tell you to avoid them whenever a set-based alternative exists. This section
> proves *why*, using one concrete, representative problem solved four different ways.

**The problem:** *Apply 2% monthly interest to every currently active savings account in `banking_db`.*

Active `SAVINGS` accounts in the seed data: `account_id` 1 (150000.00), 3 (80000.00), 4 (300000.00), 6 (20000.00).
Account 5 is `FIXED_DEPOSIT` (excluded by type), account 7 is `FROZEN` (excluded by status) — the problem is
small in this seed data, but reason about it as if `accounts` held ten million rows, because the performance
argument below only becomes visible at scale.

### Solution 1 — Cursor (row-by-row `UPDATE` inside a `FETCH` loop)

```plpgsql
DO $$
DECLARE
    cur_savings CURSOR FOR
        SELECT account_id, balance
        FROM accounts
        WHERE account_type = 'SAVINGS' AND status = 'ACTIVE'
        FOR UPDATE;
    v_account_id INT;
    v_balance    NUMERIC(14,2);
BEGIN
    OPEN cur_savings;
    LOOP
        FETCH cur_savings INTO v_account_id, v_balance;
        EXIT WHEN NOT FOUND;
        UPDATE accounts
        SET balance = ROUND(balance * 1.02, 2)
        WHERE CURRENT OF cur_savings;
    END LOOP;
    CLOSE cur_savings;
END $$;
```

**Mechanism, walking the mental-model chain:** `OPEN` plans and begins executing the `SELECT` once. Then, for
**every matching row**, the loop performs a `FETCH` (advance the cursor, copy one row into variables) followed by
a **completely separate `UPDATE` statement** — its own parse, its own plan, its own executor start-up, its own
lock acquisition on that one row, its own WAL (write-ahead log) record, its own trigger firing (if `accounts` had
`UPDATE` triggers). For 4 rows that's negligible. For 10,000,000 rows, that's 10,000,000 individually planned and
executed `UPDATE` statements.

### Solution 2 — Set-Based SQL (a single `UPDATE ... WHERE`)

```sql
UPDATE accounts
SET balance = ROUND(balance * 1.02, 2)
WHERE account_type = 'SAVINGS' AND status = 'ACTIVE';
```

That's the entire solution. One statement. The planner builds **one** query plan (e.g., an index scan on
`status`/`account_type` if such an index exists, or a single sequential scan), and the executor applies the
change to every matching row within that one plan's execution — one WAL-batched operation, one set of trigger
firings processed as part of a single statement's execution, one round trip if issued from an application.

### Solution 3 — Window Function (tiered interest, computed inline)

Suppose the real business rule is more nuanced: *the two highest-balance active savings accounts get the
standard 2%; the rest get a reduced 1.5%, as a retention incentive for large balances.* A window function
computes each row's **rank relative to the others in the same query**, without needing a loop or a second pass:

```sql
UPDATE accounts a
SET balance = ROUND(a.balance * t.rate, 2)
FROM (
    SELECT
        account_id,
        CASE
            WHEN RANK() OVER (ORDER BY balance DESC) <= 2 THEN 1.02   -- top 2 balances: standard rate
            ELSE 1.015                                                 -- everyone else: reduced rate
        END AS rate
    FROM accounts
    WHERE account_type = 'SAVINGS' AND status = 'ACTIVE'
) t
WHERE a.account_id = t.account_id;
```

`RANK() OVER (ORDER BY balance DESC)` (Chapter 10) computes, for every qualifying row **in a single pass over the
data**, its position relative to every other qualifying row — something a plain `WHERE` clause cannot express
(it needs to compare each row against *all the others*, not against a fixed constant). This is still one
statement: the window function does the "which tier is this row in" computation set-based, and the outer `UPDATE
... FROM` applies it to every row at once.

### Solution 4 — CTE (structuring the set-based solution for readability)

```sql
WITH eligible_accounts AS (
    SELECT account_id
    FROM accounts
    WHERE account_type = 'SAVINGS' AND status = 'ACTIVE'
)
UPDATE accounts a
SET balance = ROUND(a.balance * 1.02, 2)
FROM eligible_accounts e
WHERE a.account_id = e.account_id;
```

Functionally identical to Solution 2 for this problem (a CTE doesn't change what work happens, only how it's
expressed), but the `WITH eligible_accounts AS (...)` step names the "who qualifies" logic separately from the
"what happens to them" logic — valuable once the eligibility rule grows more complex (e.g., joining `loans` to
also exclude customers in default, or aggregating recent `transactions`) and you want that complexity isolated
and named rather than buried inside one long `WHERE` clause.

### Comparison Table

| Approach | SQL statements executed | Lines of code | Who computes per-row logic | Genuinely needs a cursor? |
|---|---|---|---|---|
| **1. Cursor** | 1 (`SELECT`) + **N** (`UPDATE`, one per row) | ~14 | Procedural loop, one iteration per row | This problem: **no** |
| **2. Set-based `UPDATE`** | **1** | 3 | The optimizer's single execution plan | — |
| **3. Window function** | **1** | ~10 (readability cost of the tiering rule, not looping) | The window function, in one pass | — |
| **4. CTE** | **1** | ~7 | Same as #2, restructured for readability | — |

### The Performance Reasoning (mechanism, not assertion)

It is not enough to say "cursors are slower." Here is *why*, mechanically:

1. **Per-statement fixed overhead is paid once vs. N times.** Every SQL statement — even a trivial one — pays a
   fixed cost before it touches a single row: parsing the SQL text, looking up object metadata, building or
   fetching a cached query plan, acquiring the executor's initial resources, and checking permissions. The
   set-based `UPDATE` pays this cost **exactly once**, no matter how many rows it ultimately touches. The cursor
   version pays it **once for the `SELECT`, and then again for every single `UPDATE`** — that fixed overhead
   is now multiplied by the row count, turning what was `O(1)` planning cost into `O(N)` planning cost.
2. **Per-row lock acquisition and release happens N times either way, but the cursor also serializes it with
   round trips.** Even the set-based `UPDATE` must lock each row it changes — that part isn't free in either
   approach. The difference is that the set-based version acquires and manages those locks **inside one
   executor run**, back-to-back, with no intervening work; the cursor version interleaves each row's lock with a
   full `FETCH`/`EXIT WHEN`/`UPDATE` control-flow cycle, and if the cursor is being driven from application code
   rather than a single PL/pgSQL block, each `FETCH` and each `UPDATE` is a **separate network round trip** —
   for a remote client, network latency alone (even 1ms per round trip) turns into seconds of added wall-clock
   time at a few million rows.
3. **The optimizer can't optimize what it can't see as one operation.** Given a single `UPDATE ... WHERE`
   statement, the planner can choose the single best strategy for the *whole* operation — e.g., a bulk index scan
   feeding a batched update — and can apply engine-level optimizations, like extending the same page's write
   buffer across many rows in the same block, that only make sense when the engine knows up front it's doing bulk
   work. A cursor issuing N independent `UPDATE`s gives the optimizer N independent, tiny problems to solve one
   at a time; it can never make a global decision.
4. **Triggers and constraint checks are typically evaluated per-statement AND per-row already** (see Chapter 22),
   so a cursor issuing N statements often means N *statement-level* trigger firings on top of the row-level ones,
   where the set-based version fires the statement-level trigger just once.

**The conclusion, stated precisely:** the cursor doesn't do more row-level work than the set-based query — both
ultimately touch the same rows. The cursor does more **statement-level** work, N times over, and (when driven
from outside the database) more **round-trip** work, N times over. That multiplication is what makes cursors slow
at scale, not any inherent slowness in "looping" itself.

> **Important Notes** — none of this means window functions or CTEs are *inherently* faster than a plain
> `UPDATE`. Solutions 2, 3, and 4 above all execute as **one** statement; the meaningful gap in this comparison is
> "one statement" (2/3/4) vs. "N statements" (1), not "which set-based technique is fastest." Reach for a window
> function specifically when the per-row decision genuinely depends on comparing rows to each other (ranking,
> running totals, "top N per group"); reach for a CTE purely for readability/structure, not performance.

---

## 21.9 Common Mistakes

- **Forgetting to `CLOSE` a cursor.** Every open cursor holds server-side resources (a query plan, a snapshot,
  possibly locks) for as long as it stays open. In a long-running procedure or an application that opens cursors
  in a loop without closing each one, this leaks resources across the session/transaction and can eventually
  exhaust available cursor/portal slots. Prefer cursor `FOR` loops (§21.5.4) — they close automatically even on
  early exit or exception.
- **Using a cursor for something that's actually a simple `UPDATE`/`JOIN`.** This is the anti-pattern the whole
  of §21.8 is devoted to. If you find yourself writing `FETCH ... UPDATE ... FETCH ... UPDATE` and the update
  logic doesn't depend on calling external procedures or genuinely row-order-dependent state, stop and ask: "is
  this just `UPDATE ... WHERE`, or a `JOIN`, in disguise?"
- **Infinite loop from forgetting to check `FOUND`/`NOT FOUND`.** If you write a manual `FETCH`/`LOOP` (Example 2's
  pattern) and omit `EXIT WHEN NOT FOUND` — or check the wrong variable, or check it before the first `FETCH`
  instead of after — the loop never terminates once the cursor runs out of rows, because `FETCH` on an exhausted
  cursor simply returns nothing (it does not raise an error you'd otherwise notice). The loop body then keeps
  running against stale variable values from the last successful fetch, forever.
- **Filtering inside the loop instead of in the cursor's `WHERE` clause** (Example 4's pattern, if it were the
  final form of real production code rather than a teaching example): fetching every row and then `IF`-checking a
  condition wastes the ability of the query planner to use an index to skip non-matching rows entirely. Push
  filters into the cursor's query whenever the condition doesn't depend on something only knowable during
  iteration.
- **Using `WHERE CURRENT OF` without `FOR UPDATE` on the cursor's query** (PostgreSQL/Oracle) — this raises an
  error at execution time; the cursor must be declared updatable.
- **Assuming `WHERE CURRENT OF` works in MySQL.** It doesn't (§Example 5's warning) — update by primary key
  instead.
- **Opening a `refcursor` from a function and trying to fetch from it in a *new* transaction/connection.** The
  portal only survives as long as the transaction that opened it, unless declared `WITH HOLD` (§21.5.7).

## 21.10 Edge Cases

- **Empty result set.** If a cursor's query matches zero rows, `OPEN` still succeeds — it just means the very
  first `FETCH` immediately reports "not found." A cursor `FOR` loop over an empty result simply **does not
  execute its body at all**; this is exactly analogous to a `FOR` loop in any language iterating over an empty
  list — no error, no iterations, execution continues after the loop.
- **Underlying data changing during iteration.** What a cursor "sees" while it's open depends on the isolation
  level and cursor type. Under PostgreSQL's default `READ COMMITTED`, a plain cursor's snapshot is generally
  taken per-query at `OPEN` time — rows deleted by another committed transaction *after* your cursor opened may
  or may not still be visible to later `FETCH`es, and this is exactly why `FOR UPDATE` (locking each row as
  fetched) matters when you intend to modify what you fetch: without it, another session could delete or change a
  row between your `FETCH` and your subsequent `UPDATE ... WHERE CURRENT OF`. (Chapter 12 covers isolation levels
  and this class of anomaly — read/write skew — in full depth.)
- **Modifying the very table a cursor is scanning, from inside that cursor's own loop, without `FOR UPDATE`/
  `WHERE CURRENT OF`.** If your loop body issues an ordinary `UPDATE`/`DELETE` against the same table the cursor
  is reading — matched by some condition other than the cursor's own position — you can, depending on isolation
  level and how the underlying scan re-reads pages, see rows you already processed again, or fail to see rows you
  haven't gotten to yet. This is a subtle, dialect- and isolation-level-dependent hazard; the safe pattern is
  always `WHERE CURRENT OF` (or capturing the primary key and updating by it) rather than a broader condition.

## 21.11 When Cursors Are Genuinely the Right Tool

Despite everything above, there are real cases where a cursor is the correct choice — not a shortcut, the correct
architecture:

- **Row-by-row calls into other procedures or external logic** that cannot be expressed as SQL at all (Example
  in §21.5.5): each row must trigger a call to a payment gateway, an email service, or another stored procedure
  with its own multi-statement logic and error handling.
- **Complex procedural ETL steps** where the transformation for row *N* genuinely depends on the *outcome* of
  processing row *N-1* (a running, mutually-dependent calculation that isn't a simple window function), or where
  intermediate results must be checkpointed row by row for auditability/recoverability.
- **Generating per-row dynamic DDL/DML that targets different objects per row** — e.g., `EXECUTE format('CREATE
  TABLE archive_%s (...)', v_year)` inside a loop that partitions historical data by year, where the *target
  table name itself* varies per row and can't be parameterized inside one static statement.
- **Administrative/maintenance scripts** that must show incremental progress, support cancellation between rows,
  or process rows in small controlled batches to avoid holding one enormous lock/transaction (though for pure
  batching, `LIMIT`-based batched `UPDATE`s are usually still preferable to a full cursor — see Chapter 18).

## 21.12 Comparison Summary: Cursor vs. Set-Based SQL vs. Window Function vs. CTE

| Dimension | Cursor | Set-based `UPDATE`/`JOIN` | Window function | CTE |
|---|---|---|---|---|
| **Statements executed for N rows** | 1 (query) + N (per-row action) | 1 | 1 | 1 (same plan as underlying query, just named) |
| **Where per-row logic lives** | Procedural code, explicit loop | Expression inside `SET`/`WHERE`/`CASE` | Computed across rows in one pass (`OVER (...)`) | Same as set-based; CTE only affects structure/naming |
| **Can call external procedures per row** | Yes — its main legitimate use case | No | No | No |
| **Can compare a row to *other* rows (ranking, running totals)** | Yes, but manually (slow, error-prone) | Only with subqueries/aggregates | Yes — this is its purpose | Yes, if it wraps a window function |
| **Optimizer visibility** | None across the N per-row statements | Full — one plan for the whole operation | Full | Full |
| **Typical performance at scale** | Poor — overhead multiplies by N (§21.8) | Good | Good | Good (identical to the equivalent non-CTE query) |
| **Readability for simple cases** | Verbose | Concise | Moderate (needs `OVER` fluency) | Very readable for multi-step logic |
| **Correct default choice** | Only for the cases in §21.11 | **Yes, by default** | When row-vs-row comparison is required | When set-based logic has multiple named steps |

## 21.13 Real-World Use Cases

- **Batch payment processing** where each transaction must call an external payment gateway API via a stored
  procedure wrapper, with per-row retry/error logic (cursor with per-row exception handling, §Example 6).
- **Nightly interest/fee posting jobs** in core banking systems — though, per §21.8, the *actual balance update*
  should be set-based; a cursor is legitimate only for the parts of the job that call external notification
  services per account afterward.
- **Data migration scripts** that must transform and insert rows into differently-shaped destination tables one
  at a time because the transformation branches on values only knowable per-row (e.g., choosing which of several
  target tables/partitions a row belongs in, and building dynamic SQL accordingly).
- **Generating and emailing/exporting individualized documents** — bank statements, payslips, invoices — where
  each row (or group of rows, as in Example 8's control-break pattern) becomes a separate document/file, a
  fundamentally per-row side effect.
- **Administrative maintenance tooling**, e.g., a script that walks every table in a schema (from
  `information_schema`) and runs `VACUUM`/`ANALYZE`/`REINDEX` on each one by name, via dynamic SQL — table names
  can't be parameterized inside a single static statement.

---

## 21.14 Practice Questions

No solutions are provided — work these against `banking_db` and `company_db` after loading both seed scripts.

1. Write a simple cursor over `company_db.employees` that fetches and prints (via `RAISE NOTICE`) only the
   **first** employee ordered by `hire_date` (earliest hire). Use `DECLARE`/`OPEN`/`FETCH`/`CLOSE` explicitly.
2. Write a cursor `FOR` loop that prints every row of `company_db.attendance` where `status = 'ABSENT'`, showing
   the employee's `employee_id` and `work_date`.
3. Using a cursor, loop over `banking_db.accounts` and classify each account into `'DORMANT'` (opened before
   2015-01-01) vs `'RECENT'` (opened on or after 2015-01-01), printing the classification per row.
4. Write a cursor that loops over `company_db.employees` and, only for employees whose `status = 'ON_LEAVE'`,
   prints an alert message. Confirm the loop still visits every employee even though only some trigger the alert.
5. Explain, in your own words, why `WHERE CURRENT OF` requires the cursor's query to include `FOR UPDATE` in
   PostgreSQL and Oracle. What could go wrong if it didn't?
6. Write a cursor over `company_db.salaries` that raises a custom exception for any row where `bonus > base_salary`
   (an implausible/invalid data condition), catches it inside the loop with a nested `BEGIN/EXCEPTION` block, logs
   the offending `employee_id` via `RAISE NOTICE`, and continues processing the remaining rows.
7. Write a parameterized cursor `cur_employee_attendance(p_employee_id INT)` that returns all `attendance` rows
   for a given employee, then call it once for `employee_id = 3` and once for `employee_id = 7`.
8. Write a cursor over a three-table join of `banking_db.customers`, `accounts`, and `loans` that, for each
   customer with at least one `ACTIVE` loan, prints a one-line summary: customer name, number of active loans,
   and their total `loan_amount`. (Hint: you may need a control-break variable, or consider whether this is
   actually better solved with `GROUP BY` — which one did you pick, and why?)
9. Rewrite Practice Question 3 (the dormant/recent classification) as a single set-based `SELECT` using `CASE`.
   Compare the line count and reasoning effort against the cursor version.
10. In MySQL syntax, write the `DECLARE CONTINUE HANDLER FOR NOT FOUND` pattern for a cursor over
    `company_db.employees` filtered to `department_id = 1`, and print each employee's `job_title`.
11. In Oracle syntax, write a `REF CURSOR`-returning procedure `get_active_loans(p_customer_id, p_cursor OUT
    SYS_REFCURSOR)` and describe (in a comment) how a Java/JDBC caller would consume it.
12. A colleague wrote a cursor that loops over all 50,000 rows of a `transactions`-like table and runs a separate
    `UPDATE` per row to set a `reviewed` flag to `TRUE` for every `WITHDRAWAL` over 10,000. Identify, specifically,
    which of the mistakes in §21.9 this is, and rewrite it as one statement.

---

## 21.15 Main Challenge & Harder Challenge

### Main Challenge — Solve It Four Ways

Re-implement §21.8's problem yourself, from scratch, without looking back at the solutions:

> Apply **2% monthly interest** to every `ACTIVE` `SAVINGS` account in `banking_db`.

Produce all four solutions independently:
1. A cursor-based PL/pgSQL block.
2. A single set-based `UPDATE`.
3. A version using a window function to apply a **3-tier** rate instead of a flat rate — e.g., top third of
   qualifying balances get 2%, middle third get 1.75%, bottom third get 1.5% (hint: `NTILE(3)`).
4. A CTE-structured version that first computes the eligible accounts *and* excludes any customer who also has a
   `DEFAULTED` loan (join to `banking_db.loans`), named as a separate step from the update itself.

For each, note (in your own words, matching §21.8's reasoning): how many statements it issues, and — if this ran
against ten million rows instead of four — where exactly the extra cost of the cursor version would come from.

### Harder Challenge — Loan Risk Flagging With a Cursor, Then Set-Based

**Part A (cursor, do this one).** Write a PL/pgSQL block that opens a cursor over `banking_db.loans` for every row
where `status = 'ACTIVE'`, and for each loan, flags it as **overdue-risk** if either:

- the number of whole months elapsed since `start_date` (`age(CURRENT_DATE, start_date)` gives you the pieces you
  need) is **greater than or equal to** `term_months` (i.e., the loan should have already been fully repaid by
  its own term, but is still marked `ACTIVE`), **or**
- `interest_rate > 9.00`.

For every loan that matches either condition, `INSERT` one row into `banking_db.audit_log` with `table_name =
'loans'`, `operation = 'UPDATE'`, `row_pk` set to the loan's id, and `new_data` a `jsonb` object recording which
condition(s) triggered the flag and the loan's current values. Use a nested `BEGIN/EXCEPTION` block per row so
that a malformed row (simulate one, e.g., by testing what happens if `term_months` were somehow `0`) cannot abort
the whole scan.

**Part B (set-based, no solution given — this is the actual exercise).** Once Part A works, do **not** look at it
again — instead, write the equivalent logic as a **single set-based statement** (or a CTE-structured pair of
statements: one to identify at-risk loans, one `INSERT ... SELECT` into `audit_log`) that produces the same
`audit_log` rows without any cursor, loop, or per-row `FETCH`. Compare: how many lines did it take? How many
statements executed? Would you still need the nested exception handler, and if not, why not (hint: think about
*what* the exception handler in Part A was actually protecting against, and whether a single set-based `INSERT
... SELECT` can even encounter that failure mode row-by-row in the first place)?

---

## Key Takeaways

- A cursor is a **bookmark with state** — a position inside a result set that lets you retrieve rows **one at a
  time**, procedurally, instead of getting the whole set at once.
- The lifecycle is always **DECLARE → OPEN → FETCH (repeat) → CLOSE**, with optional `MOVE` to reposition without
  fetching. `DECLARE` defines; `OPEN` executes the query and positions before row 1; `FETCH` retrieves and
  advances; `CLOSE` releases resources.
- **Implicit cursors** already exist behind every `FOR ... IN (SELECT ...) LOOP` and every single-row `SELECT
  INTO` — and both set the special `FOUND` variable. **Explicit cursors** give you full manual control, needed for
  `WHERE CURRENT OF`, parameterization, and cursors that outlive a single loop.
- **Parameterized cursors** let one cursor definition serve many different filter values, bound at `OPEN` time.
- **`WHERE CURRENT OF`** updates/deletes exactly the row the cursor is positioned on, but requires `FOR UPDATE`
  on the cursor's query, is supported in **[PostgreSQL]** and **[Oracle]**, and is **not supported at all in
  [MySQL]** (update by primary key instead there).
- **`refcursor` OUT parameters** let a PostgreSQL function open a cursor that the *caller* fetches from
  afterward — but only within the same transaction, unless the cursor is declared `WITH HOLD`.
- **Every dialect spells cursors differently**: MySQL's `DECLARE CONTINUE HANDLER FOR NOT FOUND`, Oracle's
  `%FOUND`/`%NOTFOUND`/`%ROWCOUNT` and `REF CURSOR`, SQL Server's `@@FETCH_STATUS` and cursor options
  (`LOCAL`/`GLOBAL`, `FORWARD_ONLY`/`SCROLL`, `STATIC`/`DYNAMIC`).
- **The centerpiece lesson**: a cursor-driven row-by-row `UPDATE` pays SQL's fixed per-statement overhead once
  *per row* instead of once *total*, and (when driven from application code) adds a network round trip per row.
  A single set-based `UPDATE`, window function, or CTE lets the optimizer plan and execute the entire operation
  as one unit — this is *why* cursors are slow at scale, not just an assertion that they are.
- Reach for a cursor only when the per-row action genuinely can't be expressed as one SQL statement — calling
  external procedures per row, row-order-dependent procedural ETL, or per-row dynamic DDL/DML targeting different
  objects. For everything else — filtering, updating, joining, ranking, aggregating — prefer set-based SQL, window
  functions, or CTEs.

## What's Next

**Chapter 22 — Triggers** moves from cursors' *explicit*, on-demand row-by-row processing to a different kind of
row-by-row execution: code that the database runs **automatically**, per row or per statement, in response to
`INSERT`/`UPDATE`/`DELETE` events — no `CALL`, no cursor, no loop needed from the caller at all. You already have
the `audit_log` table from this chapter's harder challenge; Chapter 22 shows you how to populate it automatically,
on every write, without remembering to call anything.
