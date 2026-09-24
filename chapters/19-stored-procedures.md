# Chapter 19 — Stored Procedures (Extremely Detailed)

> **Part V — Procedural SQL**
> Database used throughout: **`banking_db`** (`customers`, `accounts`, `transactions`, `loans`, `audit_log`), with a
> secondary appearance from **`company_db`** (`employees`, `salaries`).
> Previous: [Chapter 18 — SQL Performance Optimization](18-performance-optimization.md) · Next: [Chapter 20 — Advanced Functions](20-functions-advanced.md)

```bash
psql -f databases/banking_db.sql
psql -f databases/company_db.sql
```

Everything in this chapter is written against `banking_db`'s real seed rows. Run each `CREATE PROCEDURE` and
`CALL` yourself as you read — every "expected output" shown here is the literal output you will get, computed
by hand against the seed data below so you can verify it without spinning up anything beyond the two `psql -f`
commands above.

For reference, the seed rows this chapter uses over and over:

**`customers`**

| customer_id | first_name | last_name | email |
|---|---|---|---|
| 1 | Ravi | Shankar | ravi.shankar@mail.com |
| 2 | Neha | Agarwal | neha.agarwal@mail.com |
| 3 | Suresh | Menon | suresh.menon@mail.com |
| 4 | Kavita | Desai | kavita.desai@mail.com |
| 5 | Manoj | Tiwari | manoj.tiwari@mail.com |

**`accounts`**

| account_id | customer_id | account_type | balance | status |
|---|---|---|---|---|
| 1 | 1 | SAVINGS | 150000.00 | ACTIVE |
| 2 | 1 | CURRENT | 50000.00 | ACTIVE |
| 3 | 2 | SAVINGS | 80000.00 | ACTIVE |
| 4 | 3 | SAVINGS | 300000.00 | ACTIVE |
| 5 | 3 | FIXED_DEPOSIT | 500000.00 | ACTIVE |
| 6 | 4 | SAVINGS | 20000.00 | ACTIVE |
| 7 | 5 | CURRENT | 5000.00 | FROZEN |

**`loans`**

| loan_id | customer_id | loan_amount | interest_rate | term_months | status |
|---|---|---|---|---|---|
| 1 | 1 | 500000.00 | 8.50 | 60 | ACTIVE |
| 2 | 3 | 1200000.00 | 7.75 | 120 | ACTIVE |
| 3 | 4 | 300000.00 | 9.25 | 36 | ACTIVE |
| 4 | 2 | 150000.00 | 8.00 | 24 | CLOSED |

`transactions` and `audit_log` are used as we go — full column lists are in the schema recap above (from
`databases/banking_db.sql`). Keep both files open in a second window as you read.

---

## 19.0 What This Chapter Is Really About

Every chapter up to this point — joins, subqueries, CTEs, window functions, transactions, indexes, the planner —
taught you to write a **single SQL statement** (or a client-side sequence of statements) that gets the right
answer efficiently. Chapter 19 asks a different question: what happens when a piece of business logic is not one
statement, but a **procedure** — a named, reusable, multi-step sequence with variables, branching, loops, error
handling, and its own transaction boundaries — and you want that procedure to live *inside the database itself*,
callable by name, instead of scattered across application code that talks to the database one statement at a
time?

That is what a **stored procedure** is. This chapter is intentionally the longest and most careful chapter in
the procedural-SQL part of this book, because everything in Chapters 20–22 (functions, cursors, triggers) is
built on the PL/pgSQL language foundation this chapter establishes: variables, `%TYPE`, `IF`/`CASE`, `LOOP`/
`WHILE`/`FOR`, `RAISE`, `EXCEPTION` blocks, dynamic SQL, and `SECURITY DEFINER`. Read this chapter slowly. Type
out every example. There is no shortcut through it.

---

## 19.1 What Is a Stored Procedure?

### Plain-language explanation

Imagine you had to explain, to a brand-new bank teller on their first day, exactly how to process a wire
transfer: check the sender has enough money, subtract from one account, add to the other, write two ledger
entries, and if anything goes wrong, undo everything and tell the customer why. You wouldn't want to re-explain
those seven steps to every teller, every single time, from memory, hoping nobody forgets step 4. Instead you'd
write it down once, as a named procedure — "Procedure: Wire Transfer" — and every teller just follows the card:
plug in the two account numbers and the amount, and the card handles the rest.

A **stored procedure** is that index card, except it lives inside the database engine itself, is written in a
real procedural language, and is invoked by name instead of read by a human.

### Technical explanation

> A **stored procedure** is a named, precompiled (or compiled-on-first-call), persistent collection of
> procedural and SQL statements stored inside the database server, invoked explicitly by name (via `CALL` in
> standard SQL / PostgreSQL, MySQL, and Oracle, or `EXEC` in SQL Server), which can accept input parameters,
> return output through parameters, declare local variables, branch, loop, raise and catch errors, and —
> critically — manage its own transaction boundaries (`COMMIT`/`ROLLBACK`) independently of the statement that
> invoked it.

Unpack the important words:

- **"Named"** — you call it by an identifier (`sp_transfer_funds`), not by re-sending its source text.
- **"Stored... inside the database server"** — the logic lives in the database's system catalogs
  (`pg_proc` in PostgreSQL), not in your application's source tree. Every client — a Python service, a
  nightly cron job, a DBA in `psql`, a BI tool — that connects to the database can call it the same way.
- **"Invoked explicitly by name"** — unlike a trigger (Chapter 22), a procedure never runs on its own. Nothing
  happens until something issues `CALL sp_transfer_funds(...)`.
- **"Manage its own transaction boundaries"** — this is the single most important structural fact in this
  chapter, and the entire reason PostgreSQL added `PROCEDURE` as a distinct object type in version 11. A
  procedure can `COMMIT` partway through its own body and keep running in a new transaction. A `FUNCTION`
  categorically cannot. §19.3 below is dedicated entirely to explaining why.

### Why stored procedures exist

Three separate forces converge to justify stored procedures as a distinct feature, and understanding all three
tells you when to reach for one and when not to:

1. **Encapsulation of multi-step business logic.** "Transfer funds" is not one SQL statement — it's a sequence
   of reads, checks, writes, and conditional branches that must all succeed or all fail together. Somewhere,
   that sequence has to be written down as code. A stored procedure lets that code live next to the data it
   protects, instead of being re-implemented (and potentially re-implemented *inconsistently*) in every
   application that touches the database.
2. **Reducing network round-trips.** If a multi-step process is coordinated from application code, every
   intermediate read/write is a separate round-trip to the database over the network. A stored procedure
   collapses an entire multi-step workflow into **one** round-trip: the client sends `CALL sp_transfer_funds(1,
   3, 30000)` once, and every intermediate step runs inside the database server itself, close to the data.
3. **A single point of enforcement.** If "opening a savings account requires a non-negative initial balance"
   lives only in application code, then a second application, a data-migration script, or a careless analyst
   running raw `INSERT`s can each bypass it. A stored procedure — especially combined with restricted table
   grants (Chapter 27) so that only the procedure, not raw `INSERT`/`UPDATE`, is permitted — makes the rule
   impossible to route around.

> **Important Note**
> A stored procedure is not automatically "faster" than equivalent application code, and it is not a substitute
> for `CHECK` constraints, foreign keys, or triggers. It solves a specific problem: *coordinating a multi-step,
> possibly multi-transaction, business process as a single named, callable unit inside the database.* Keep
> that scope in mind through the rest of this chapter — every worked example is a coordination problem, not a
> one-line lookup that a plain `SELECT` would already solve.

---

## 19.2 Stored Procedure vs. Function

Both procedures and functions are named, callable, parameterized PL/pgSQL objects — so what actually
distinguishes them? This section gives you the definitive answer, because Chapter 20 depends on you having it
exactly right.

| Aspect | `PROCEDURE` | `FUNCTION` |
|---|---|---|
| Invoked with | `CALL proc_name(args)` — a standalone statement | Called *inside* an expression: `SELECT fn_name(args)`, `WHERE fn_name(x) > 5`, etc. |
| Must it return a value? | No — a procedure with no `OUT`/`INOUT` parameters returns nothing at all | Yes — every function declares a `RETURNS` type and must return a value of that type (or a set of rows) |
| Can it manage transactions (`COMMIT`/`ROLLBACK`)? | **Yes**, since PostgreSQL 11 — this is the headline difference | **No** — attempting `COMMIT` inside a function raises `ERROR: invalid transaction termination` |
| Usable inside a `SELECT`, `WHERE`, `JOIN`? | **No** — a procedure cannot appear inside a SQL expression at all | **Yes** — this is the entire point of a function; see Chapter 20 |
| Output mechanism | `OUT`/`INOUT` parameters only (no `RETURNS` clause exists for `CREATE PROCEDURE` in PostgreSQL) | `RETURNS type` / `RETURNS TABLE(...)` / `RETURNS SETOF type` |
| Volatility markers (`IMMUTABLE`/`STABLE`/`VOLATILE`) | Not applicable — procedures aren't consulted by the planner as expressions | Required reasoning for correctness — Chapter 20 §20.7 |
| Typical use case | A multi-step workflow with side effects, possibly spanning multiple internal transactions (a transfer, a batch job, a loan-approval workflow) | A single reusable computation or row-producing query you want to embed inside other SQL |

### The transaction-control distinction, precisely

This is worth isolating because it is the fact every experienced PostgreSQL developer reaches for first when
asked "procedure or function?":

> **A `FUNCTION`'s body always executes as part of the single statement that invoked it.** If you write
> `SELECT calculate_interest(account_id) FROM accounts`, that whole `SELECT` is one atomic unit as far as
> PostgreSQL's transaction machinery is concerned — it runs inside one snapshot, one transaction. There is no
> sensible meaning for "commit partway through evaluating one row of one `SELECT`," so PostgreSQL simply
> forbids `COMMIT`/`ROLLBACK` inside function bodies, full stop, in every PL/pgSQL function ever written.
>
> **A `PROCEDURE`, by contrast, is invoked with `CALL` as its own standalone top-level statement** (not
> embedded inside a larger query). Because of that, starting in PostgreSQL 11, a procedure body is allowed to
> issue its own `COMMIT` or `ROLLBACK` partway through its execution — and PostgreSQL will automatically start
> a fresh transaction immediately afterward so the procedure can keep running. This lets a procedure that
> processes, say, 100,000 rows in batches `COMMIT` after every batch of 1,000, instead of holding one giant
> transaction (and its locks, and its bloat-generating long-running snapshot) open for the entire run.

```plpgsql
-- This is ILLEGAL inside a FUNCTION — will raise an error at CALL/SELECT time:
CREATE OR REPLACE FUNCTION fn_bad_commit() RETURNS VOID AS $$
BEGIN
    UPDATE banking_db.accounts SET balance = balance + 1 WHERE account_id = 1;
    COMMIT;   -- ERROR: invalid transaction termination
END;
$$ LANGUAGE plpgsql;
```

```plpgsql
-- This is LEGAL inside a PROCEDURE (PostgreSQL 11+):
CREATE OR REPLACE PROCEDURE banking_db.sp_ok_commit()
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE banking_db.accounts SET balance = balance + 1 WHERE account_id = 1;
    COMMIT;   -- perfectly legal — starts a fresh transaction afterward
    UPDATE banking_db.accounts SET balance = balance + 1 WHERE account_id = 2;
    COMMIT;
END;
$$;
```

> **⚠️ Warning**
> `COMMIT`/`ROLLBACK` inside a procedure are only legal when the `CALL` itself is the **top-level** statement of
> its own transaction — i.e., you called it directly from an interactive session or client library with no
> surrounding explicit `BEGIN`. If you wrap the call yourself — `BEGIN; CALL sp_ok_commit(); COMMIT;` — the
> procedure's internal `COMMIT` now conflicts with the transaction you opened by hand, and PostgreSQL raises
> `ERROR: invalid transaction termination` at that inner `COMMIT`. The same restriction applies if the
> procedure is called from inside another function, or from inside a `DO` block: those already have a fixed
> transaction context they cannot break out of. §19.10 covers this in full with the money-transfer example.

### Procedure vs. Function — a second, sharper way to remember it

- If you want the answer to flow *back into a SQL query* (a computed column, a filter condition, a value you
  `JOIN` against) → **function**.
- If you want to *do something* — a multi-step change to the database, possibly needing its own commit
  boundaries, invoked as a standalone action — → **procedure**.

---

## 19.3 Stored Procedure vs. Application Code

This is a judgment call that real engineering teams disagree about, and a course this deep owes you both sides
honestly rather than a one-line verdict.

| | Logic in a stored procedure | Logic in application code |
|---|---|---|
| **Round-trips** | One round-trip runs the whole workflow inside the database | Each intermediate step is a separate round-trip (unless batched) |
| **Consistency of enforcement** | Every caller — any app, any script, any human at `psql` — goes through the same code path | Only callers that go through *that specific application's* code path are protected; a second app or an ad-hoc script can bypass it |
| **Version control & code review** | Procedure source can live in your repo as `.sql` migration files and be reviewed like any other code, but tooling (diffing, refactoring, IDE support, static analysis) is generally weaker than for a general-purpose language | Full IDE support, mature refactoring tools, mature test frameworks, familiar debugging (breakpoints, stack traces) |
| **Testability** | Testable via `pgTAP` or direct `CALL` assertions in SQL, but the tooling ecosystem is smaller and less familiar to most teams | Mature unit/integration testing frameworks; easy to mock the database boundary |
| **Portability across databases** | PL/pgSQL is PostgreSQL-specific; T-SQL is SQL-Server-specific; PL/SQL is Oracle-specific — migrating database vendor means rewriting every procedure | Application code (in Java, Python, Go, etc.) is already database-agnostic if written against an ORM/driver abstraction |
| **Deployment coupling** | Business-logic changes require a database migration/deployment, which is often *slower and riskier* to roll out than an application deploy, and harder to instantly roll back | Application deploys are typically faster, more automated, and easier to canary/roll back |
| **Where does compute happen** | Runs on the database server itself — good when the logic needs to touch a lot of rows without shipping them over the network; bad if the database server is your scaling bottleneck, since you're adding CPU load exactly where you can least afford it | Runs on application servers, which usually scale horizontally far more easily than your primary database |
| **Visibility / observability** | Harder to trace with APM tools, distributed tracing, structured application logs | Easy to integrate with existing observability stacks |
| **Best fit** | Data-integrity-critical, multi-step operations where *every* writer must be forced through the same path (financial transfers, inventory reservations, audit-mandated workflows); batch/ETL jobs that benefit from running next to the data | Business logic that changes frequently, needs rich testing, needs to call out to non-database systems (payment gateways, email, third-party APIs), or where team skillset/tooling is centered on a general-purpose language |

> **Important Note**
> Most real production systems land on a **hybrid**: application code owns orchestration, external-system
> calls, and most business rules, while a small, carefully chosen set of *money-, inventory-, or audit-critical*
> operations that must never be bypassed live as stored procedures close to the data. This chapter's
> `sp_transfer_funds` example (§19.10–19.11) is exactly that kind of operation — the one place where "no caller
> can possibly skip the balance check" outweighs the deployment friction of database-resident code.

---

## 19.4 Basic Syntax: `CREATE PROCEDURE` and `CALL`

### 19.4.1 Full syntax

**[PostgreSQL]**

```sql
CREATE [OR REPLACE] PROCEDURE procedure_name (
    [ parameter_name ] [ IN | OUT | INOUT ] parameter_type [ DEFAULT default_expr ]
    [, ...]
)
LANGUAGE lang_name                              -- 'plpgsql', 'sql', ...
[ SECURITY INVOKER | SECURITY DEFINER ]         -- default: INVOKER
[ SET configuration_parameter = value ]         -- e.g. SET search_path = ...
AS $$
    DECLARE
        -- local variable declarations (optional)
    BEGIN
        -- procedural + SQL statements
    EXCEPTION
        -- error handlers (optional)
    END;
$$;
```

Calling it:

```sql
CALL procedure_name(arg1, arg2, ...);
```

| Clause | Meaning |
|---|---|
| `OR REPLACE` | Redefine an existing procedure with the same name and parameter signature, without needing `DROP PROCEDURE` first. |
| `LANGUAGE plpgsql` | The overwhelming majority of this chapter. `LANGUAGE sql` is possible for trivial procedures with no branching, but you lose every control-flow feature this chapter teaches. |
| `SECURITY INVOKER` / `SECURITY DEFINER` | Whose privileges the body executes with — covered fully in §19.15. |
| `SET configuration_parameter = value` | Pins a session setting (most importantly `search_path`) for the duration of the call — also covered in §19.15. |
| `$$ ... $$` | Dollar-quoting delimits the body so you don't have to escape every single quote inside it. |

**[MySQL]**, **[Oracle]**, and **[SQL Server]** syntax variants are introduced alongside the Hello World example
in §19.5, and reused for the harder cross-dialect examples in §19.10, §19.12, and §19.14 — rather than
duplicated abstractly here.

### 19.4.2 `CALL` vs. `EXEC` vs. `EXECUTE`

| Dialect | Invocation keyword |
|---|---|
| PostgreSQL | `CALL procedure_name(args);` |
| MySQL | `CALL procedure_name(args);` |
| Oracle | `EXEC procedure_name(args);` (SQL*Plus shorthand) or `BEGIN procedure_name(args); END;` |
| SQL Server | `EXEC procedure_name args;` or `EXECUTE procedure_name args;` |

> **⚠️ Warning**
> In PostgreSQL, `CALL` is reserved for procedures. Trying to `CALL` a function (`CALL some_function()`) fails
> with `ERROR: some_function() is not a procedure`, and — symmetrically — trying to invoke a procedure from
> inside a `SELECT` (`SELECT sp_transfer_funds(1, 3, 100)`) fails with `ERROR: sp_transfer_funds(...) is a
> procedure`. The two object types are not interchangeable at the syntax level, on purpose — this is PostgreSQL
> enforcing the exact distinction drawn in §19.2.

---

## 19.5 Worked Example 1 of 11 — Hello World

Every dialect's simplest possible procedure: no parameters, no variables, one line of output. This is the only
example in the chapter shown fully in all four dialects side by side, to anchor the syntax differences before
everything else builds on PostgreSQL alone.

**[PostgreSQL]**

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_hello_world()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Hello, World! This is my first stored procedure.';
END;
$$;
```

```sql
CALL banking_db.sp_hello_world();
```

```
NOTICE:  Hello, World! This is my first stored procedure.
CALL
```

**Line by line:**

1. `CREATE OR REPLACE PROCEDURE banking_db.sp_hello_world()` — declares a procedure named `sp_hello_world` in
   schema `banking_db`, with an empty parameter list `()`. `OR REPLACE` means re-running this statement after
   editing the body updates it in place.
2. `LANGUAGE plpgsql` — the body below is written in PL/pgSQL, PostgreSQL's native procedural extension to SQL
   (not plain SQL — plain SQL has no `RAISE`, no `BEGIN/END` block syntax of this kind).
3. `AS $$ ... $$;` — dollar-quoting starts and ends the body text. Using `$$` (unlabeled) is fine here since the
   body itself contains no `$$` sequences; §19.13 shows labeled dollar-quoting (`$body$`) for bodies that
   contain dynamic SQL with its own quoting.
4. `BEGIN` — starts the executable block of the procedure. Every PL/pgSQL body has exactly one outermost
   `BEGIN ... END` block (optionally preceded by a `DECLARE` section, introduced in §19.7).
5. `RAISE NOTICE 'Hello, World! ...';` — emits a `NOTICE`-level message to the client. `RAISE` is PL/pgSQL's
   general-purpose message/error mechanism, covered fully in §19.9; `NOTICE` is its "informational, not an
   error" severity level.
6. `END;` — closes the block. The trailing `;` after `END` is required.
7. `CALL banking_db.sp_hello_world();` — invokes it. No output row comes back (this procedure has no `OUT`
   parameters), but the `NOTICE` text prints to your client (in `psql`, to the terminal; note that `NOTICE`
   messages are a side channel, not part of any result set — an application driver must explicitly listen for
   them, e.g. via `conn.notices` in `psycopg`).

**Common mistakes**
- Forgetting `LANGUAGE plpgsql` — PostgreSQL cannot infer the body's language from its contents.
- Writing `RETURN 'Hello';` inside a procedure — procedures have no `RETURNS` clause and cannot `RETURN` a
  value; only `RETURN;` (with no value, to exit early) is legal, and even that is optional.
- Expecting `RAISE NOTICE` output to appear in a GUI tool's "results grid" — it's a message/log line, not a
  result set row.

**[MySQL]**

```sql
DELIMITER $$

CREATE PROCEDURE sp_hello_world()
BEGIN
    SELECT 'Hello, World! This is my first stored procedure.' AS message;
END$$

DELIMITER ;

CALL sp_hello_world();
```

MySQL has no `RAISE NOTICE`-style side-channel message for plain informational output, so the idiomatic way to
"print" something from a MySQL procedure is a `SELECT` that returns a one-row, one-column result set. The
`DELIMITER $$` / `DELIMITER ;` dance exists because MySQL's default statement terminator is `;`, which would
otherwise prematurely end the `CREATE PROCEDURE` statement at the first semicolon inside the body.

**[Oracle]**

```sql
CREATE OR REPLACE PROCEDURE sp_hello_world
IS
BEGIN
    DBMS_OUTPUT.PUT_LINE('Hello, World! This is my first stored procedure.');
END sp_hello_world;
/
```

```sql
SET SERVEROUTPUT ON;
EXEC sp_hello_world;
```

Oracle PL/SQL uses `IS` (or equivalently `AS`) instead of a `LANGUAGE` clause — PL/SQL is the only procedural
language Oracle's core engine executes, so there's nothing to specify. `DBMS_OUTPUT.PUT_LINE` is Oracle's
console-print mechanism; you must `SET SERVEROUTPUT ON` in SQL*Plus/SQLcl for it to actually display. The
trailing `/` on its own line tells SQL*Plus "execute the buffered PL/SQL block now."

**[SQL Server]**

```sql
CREATE PROCEDURE sp_hello_world
AS
BEGIN
    PRINT 'Hello, World! This is my first stored procedure.';
END;
GO
```

```sql
EXEC sp_hello_world;
```

T-SQL's `PRINT` is the closest analog to PL/pgSQL's `RAISE NOTICE` — an informational message sent to the
client message stream, not part of the result set. `GO` is a *batch separator* recognized by `sqlcmd`/SSMS (not
part of the T-SQL language itself) that tells the tool "send everything above this line to the server as one
batch now."

| Dialect | "Print a message" mechanism |
|---|---|
| PostgreSQL | `RAISE NOTICE '...'` |
| MySQL | `SELECT '...' AS message;` (no true side-channel print inside a procedure) |
| Oracle | `DBMS_OUTPUT.PUT_LINE('...')` (requires `SET SERVEROUTPUT ON`) |
| SQL Server | `PRINT '...'` |

---

## 19.6 Parameters: `IN`, `OUT`, `INOUT`

### Why parameters exist

A procedure that only ever does the exact same hardcoded thing (like `sp_hello_world`) is barely more useful
than a saved script. Parameters let one procedure definition serve every call site: `sp_transfer_funds` needs
to know *which* two accounts and *how much*, and it needs to know it fresh on every single call.

### The three parameter modes

| Mode | Direction | Meaning |
|---|---|---|
| `IN` (default) | caller → procedure | A value passed in. Read-only inside the procedure body — you can read it but reassigning it does not affect the caller. |
| `OUT` | procedure → caller | An output slot. The caller doesn't need to supply a value for it (and in PostgreSQL, may pass a placeholder or omit it depending on client); the procedure body assigns it, and after `CALL` returns, PostgreSQL hands back a **one-row result set** containing all `OUT`/`INOUT` parameter values. |
| `INOUT` | caller → procedure → caller | The caller supplies an initial value, the procedure can read *and reassign* it, and the final value flows back out — but only if the caller passed something PostgreSQL can write back into, e.g. a variable inside a `DO` block or another PL/pgSQL routine, since a plain literal has nowhere to receive the updated value. |

### Worked Example 2 of 11 — A procedure accepting an `IN` parameter

**[PostgreSQL]**

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_get_customer_name(p_customer_id IN INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_first_name customers.first_name%TYPE;
    v_last_name  customers.last_name%TYPE;
BEGIN
    SELECT first_name, last_name
      INTO v_first_name, v_last_name
      FROM banking_db.customers
     WHERE customer_id = p_customer_id;

    IF NOT FOUND THEN
        RAISE NOTICE 'No customer found with customer_id = %', p_customer_id;
    ELSE
        RAISE NOTICE 'Customer % is: % %', p_customer_id, v_first_name, v_last_name;
    END IF;
END;
$$;
```

```sql
CALL banking_db.sp_get_customer_name(1);
```

```
NOTICE:  Customer 1 is: Ravi Shankar
CALL
```

**Line by line:**

1. `p_customer_id IN INT` — one input parameter. Writing `IN` explicitly is optional (it's the default mode)
   but this chapter writes it explicitly the first few times for clarity; later examples drop it, matching
   normal PL/pgSQL style. The `p_` prefix is a widely used naming convention (parameter) to visually separate
   parameters from table columns and local variables — without it, `customer_id = customer_id` inside a `WHERE`
   clause would be ambiguous or, worse, silently always-true.
2. `v_first_name customers.first_name%TYPE;` and `v_last_name customers.last_name%TYPE;` — local variable
   declarations using `%TYPE` (covered fully in §19.7): each variable automatically takes on the exact column
   type of `customers.first_name`/`customers.last_name` (`VARCHAR(50)`), so if that column's type is ever
   changed, this procedure doesn't need to be edited to match.
3. `SELECT first_name, last_name INTO v_first_name, v_last_name FROM ... WHERE customer_id = p_customer_id;` —
   `SELECT ... INTO` is PL/pgSQL's way of running a query and capturing its single-row result directly into
   local variables, positionally: the first selected column goes into the first `INTO` target, and so on.
4. `IF NOT FOUND THEN ... ELSE ... END IF;` — `FOUND` is a special boolean variable PL/pgSQL sets automatically
   after certain statements (`SELECT INTO`, `UPDATE`, `DELETE`, `INSERT ... RETURNING`, and more) — `TRUE` if
   the statement affected/returned at least one row, `FALSE` otherwise. Here it distinguishes "customer exists"
   from "customer_id doesn't exist" instead of silently printing blank names.
5. `RAISE NOTICE 'Customer % is: % %', p_customer_id, v_first_name, v_last_name;` — each `%` in the format
   string is positionally replaced by the corresponding argument that follows. This is directly analogous to
   `printf`-style formatting in general-purpose languages.

**Expected output for other customer IDs:**

| Call | Output |
|---|---|
| `CALL sp_get_customer_name(3);` | `NOTICE: Customer 3 is: Suresh Menon` |
| `CALL sp_get_customer_name(99);` | `NOTICE: No customer found with customer_id = 99` |

**Common mistakes**
- Omitting the `IF NOT FOUND` check: if no row matches, `SELECT ... INTO` leaves the target variables `NULL`
  rather than raising an error, so a naive version would silently print `Customer 99 is: <NULL> <NULL>` — no
  crash, no obvious signal anything went wrong.
- Assuming `SELECT ... INTO` errors on more than one row the way some other databases do: PostgreSQL's
  `SELECT ... INTO` silently takes the *first* row of a multi-row result and discards the rest, with no warning
  at all. If you need "error if more than one row," use `STRICT` (`SELECT ... INTO STRICT ...`), which raises
  `TOO_MANY_ROWS` if more than one row is returned and `NO_DATA_FOUND` if zero rows are returned — the safer
  default for anything beyond throwaway scripts.

### Worked Example — `OUT` parameters

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_get_account_balance(
    IN  p_account_id INT,
    OUT p_balance     NUMERIC,
    OUT p_status      VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT balance, status
      INTO p_balance, p_status
      FROM banking_db.accounts
     WHERE account_id = p_account_id;
END;
$$;
```

```sql
CALL banking_db.sp_get_account_balance(1, NULL, NULL);
```

```
 p_balance  | p_status
------------+----------
 150000.00  | ACTIVE
```

**Line by line:**

1. `IN p_account_id INT` — the one true input.
2. `OUT p_balance NUMERIC` / `OUT p_status VARCHAR` — two output slots. Inside the body they behave exactly
   like declared variables, initialized to `NULL`, that you assign into.
3. `SELECT balance, status INTO p_balance, p_status FROM ... WHERE account_id = p_account_id;` — fills both
   `OUT` parameters directly from the query.
4. There is no `RETURN` statement — a procedure never needs one to hand back `OUT` values; they flow back
   automatically when the `CALL` completes.
5. In the `CALL`, you must still supply *positional placeholders* for the `OUT` parameters in PostgreSQL's
   `CALL` syntax (`NULL` here) — PostgreSQL uses the declared parameter count and mode to know that positions 2
   and 3 are outputs whose supplied value is ignored and overwritten.

> **Important Note**
> A `CALL` with `OUT` parameters returns its result the same shape as a one-row `SELECT` — most GUI tools and
> `psql` render it as a small result table, exactly as shown above. This is different from `RAISE NOTICE`, which
> is a side-channel message, not a result row.

### Worked example — `INOUT` parameters

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_increment_balance(
    INOUT p_balance   NUMERIC,
    IN    p_increment NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    p_balance := p_balance + p_increment;
END;
$$;
```

`INOUT` parameters need a variable on the caller's side to receive the updated value — a bare literal has
nowhere to write back into. Demonstrate it inside a `DO` block, which can hold PL/pgSQL variables at the top
(anonymous-block) level:

```plpgsql
DO $$
DECLARE
    v_balance NUMERIC := 150000.00;
BEGIN
    CALL banking_db.sp_increment_balance(v_balance, 500.00);
    RAISE NOTICE 'New balance: %', v_balance;
END;
$$;
```

```
NOTICE:  New balance: 150500.00
```

**Line by line:**

1. `INOUT p_balance NUMERIC` — one combined input/output parameter: the caller's initial value flows in, the
   procedure can reassign it, and the final value flows back out into whatever variable the caller passed.
2. `p_balance := p_balance + p_increment;` — the `:=` assignment operator (covered fully in §19.7) reassigns
   the `INOUT` parameter in place.
3. Inside the `DO` block, `v_balance` starts at `150000.00`; after `CALL sp_increment_balance(v_balance,
   500.00)`, PostgreSQL copies the procedure's final `p_balance` value back into `v_balance` — this is why the
   `RAISE NOTICE` afterward correctly prints `150500.00`, not the original `150000.00`.

> **⚠️ Warning**
> `CALL sp_increment_balance(150000.00, 500.00);` (passing a literal, not a variable) runs without error and
> even prints a one-row result showing the new value — but there is no caller-side variable to receive it, so
> in a bare top-level `CALL` from `psql`/an application, that "output" is simply the displayed result row, not
> something further code can act on. `INOUT`/`OUT` values only feed back into *more logic* when the caller is
> itself a PL/pgSQL context (another procedure, a function, a `DO` block) with variables ready to catch them.

---

## 19.7 Local Variables: `DECLARE`, `:=`, and `%TYPE`

### Why a `DECLARE` section exists

Any procedure beyond the trivial needs somewhere to hold intermediate values — a fetched balance, a running
total, a flag, a computed message. `DECLARE` is where every one of those variables is introduced, with a type,
before the executable `BEGIN` block starts.

### Syntax

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_variable_demo()
LANGUAGE plpgsql
AS $$
DECLARE
    v_counter      INT := 0;                          -- explicit type + initial value
    v_customer_id  INT;                                -- explicit type, defaults to NULL
    v_balance      accounts.balance%TYPE;               -- type copied from a column
    v_full_name    customers.first_name%TYPE || ' ' || customers.last_name%TYPE; -- INVALID, see below
BEGIN
    v_counter := v_counter + 1;
    RAISE NOTICE 'Counter is now %', v_counter;
END;
$$;
```

(The `v_full_name` line above is deliberately shown as **invalid** — `%TYPE` can only be applied to a single
column reference, not combined with an expression at declaration time. This is a common first mistake; the fix
is to declare `v_full_name TEXT;` and build the concatenated value inside the `BEGIN` block instead.)

| Piece | Meaning |
|---|---|
| `v_counter INT := 0;` | Declares an `INT` variable and initializes it to `0`. `:=` is PL/pgSQL's assignment operator, used both here (initialization) and inside the body (reassignment) — it is deliberately different from `=`, which inside PL/pgSQL is reserved for equality comparison, avoiding the classic C-family "typed `=` when you meant `==`" bug class entirely. |
| `v_customer_id INT;` | Declared with no initializer — implicitly starts as `NULL`, exactly like a table column with no `DEFAULT`. |
| `v_balance accounts.balance%TYPE;` | `%TYPE` — see below. |

### `%TYPE` in depth

`%TYPE` binds a variable's type to *another* object's type at the moment the procedure is compiled — most
commonly a table column, but it also works against another variable. Two independent benefits:

1. **Correctness by construction** — `v_balance` is guaranteed to be exactly `NUMERIC(14,2)`, matching
   `accounts.balance`, with zero risk of a typo like declaring it `NUMERIC(10,2)` and silently truncating large
   balances.
2. **Forward compatibility** — if a future migration widens `accounts.balance` to `NUMERIC(18,2)`, every
   procedure using `accounts.balance%TYPE` picks up the new precision automatically on its next `CREATE OR
   REPLACE`, with no code change required.

```plpgsql
v_balance    accounts.balance%TYPE;        -- same type as accounts.balance column
v_customer_id customers.customer_id%TYPE;  -- same type as customers.customer_id column (INT, via SERIAL)
v_copy       v_balance%TYPE;               -- same type as ANOTHER VARIABLE, not just a column
```

> **Important Note**
> `%TYPE` copies only the *data type*, not `NOT NULL`, `CHECK`, or `DEFAULT` behavior from the source column —
> a variable declared with `accounts.balance%TYPE` can absolutely be assigned `NULL` or a negative number inside
> the procedure; none of the table's constraints apply until you actually write the value back with `INSERT`/
> `UPDATE`, at which point the table's real constraints fire as normal.

### Common mistakes with variables

- **Shadowing a column name.** If a variable is named exactly `balance` inside a procedure that also queries
  the `accounts` table, `WHERE balance > 1000` inside that procedure becomes ambiguous or (worse) silently
  resolves to the variable, not the column, depending on context — this is precisely why the `p_`/`v_` prefix
  convention used throughout this chapter exists. PostgreSQL will actually raise `ERROR: column reference
  "balance" is ambiguous` in many such cases, which is the *good* outcome; the dangerous cases are ones where
  it resolves silently to the wrong one.
- **Forgetting a semicolon after each `DECLARE` line** — each declaration is its own statement.
- **Using `=` instead of `:=` for assignment** inside the body — `v_counter = v_counter + 1;` is not valid
  PL/pgSQL assignment syntax and raises a syntax error (PL/pgSQL uses `=` only inside SQL sub-statements like
  `WHERE`/`SET`, never for variable assignment).

---

## 19.8 Conditionals: `IF`/`ELSIF`/`ELSE` and `CASE`

### `IF` / `ELSIF` / `ELSE` syntax

```plpgsql
IF condition1 THEN
    -- statements
ELSIF condition2 THEN
    -- statements
ELSE
    -- statements
END IF;
```

Note the PL/pgSQL spelling is `ELSIF` (no second `E`), unlike some other languages' `ELSEIF`/`ELIF` — a common
typo-level mistake for developers coming from Python or PHP.

### Worked Example 6 of 11 — branching on `account_type` with `IF`

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_describe_account(p_account_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_account_type accounts.account_type%TYPE;
    v_status       accounts.status%TYPE;
BEGIN
    SELECT account_type, status
      INTO v_account_type, v_status
      FROM banking_db.accounts
     WHERE account_id = p_account_id;

    IF NOT FOUND THEN
        RAISE NOTICE 'Account % does not exist.', p_account_id;
        RETURN;
    END IF;

    IF v_account_type = 'SAVINGS' THEN
        RAISE NOTICE 'Account % is a SAVINGS account: earns periodic interest, limited withdrawals expected.', p_account_id;
    ELSIF v_account_type = 'CURRENT' THEN
        RAISE NOTICE 'Account % is a CURRENT account: no interest, unlimited transactions, meant for daily use.', p_account_id;
    ELSIF v_account_type = 'FIXED_DEPOSIT' THEN
        RAISE NOTICE 'Account % is a FIXED_DEPOSIT: funds are locked for a term; early withdrawal may incur a penalty.', p_account_id;
    ELSE
        RAISE NOTICE 'Account % has an unrecognized account_type: %', p_account_id, v_account_type;
    END IF;

    IF v_status <> 'ACTIVE' THEN
        RAISE NOTICE 'Note: this account''s status is %, not ACTIVE.', v_status;
    END IF;
END;
$$;
```

```sql
CALL banking_db.sp_describe_account(5);
```

```
NOTICE:  Account 5 is a FIXED_DEPOSIT: funds are locked for a term; early withdrawal may incur a penalty.
```

```sql
CALL banking_db.sp_describe_account(7);
```

```
NOTICE:  Account 7 is a CURRENT account: no interest, unlimited transactions, meant for daily use.
NOTICE:  Note: this account's status is FROZEN, not ACTIVE.
```

**Line by line:**

1. `SELECT account_type, status INTO ... WHERE account_id = p_account_id;` — one lookup query, fetching both
   fields needed for the rest of the procedure in a single round-trip to the table.
2. `IF NOT FOUND THEN ... RETURN; END IF;` — an early-exit guard clause. `RETURN;` with no value immediately
   exits the procedure — legal in a procedure (unlike `RETURN value;`, which is illegal since procedures return
   nothing via `RETURN`).
3. The `IF v_account_type = 'SAVINGS' THEN ... ELSIF ... ELSIF ... ELSE ... END IF;` chain — each branch is
   checked top to bottom; the first `TRUE` condition's block runs and the rest are skipped entirely. The final
   bare `ELSE` is a defensive catch-all for any value the `CHECK` constraint on `account_type` theoretically
   allows but this procedure wasn't written to expect — good defensive practice even though, given the schema's
   `CHECK (account_type IN ('SAVINGS','CURRENT','FIXED_DEPOSIT'))`, it can never actually trigger here.
4. `IF v_status <> 'ACTIVE' THEN ... END IF;` — a second, independent conditional (not part of the `ELSIF`
   chain above it) that adds a supplementary note regardless of which account type matched — this demonstrates
   that separate `IF` blocks are fully independent decisions, not alternate branches of the same choice.
5. Note the escaped apostrophe inside the string literal: `this account''s status` — a literal single quote
   inside a single-quoted string is written as two consecutive single quotes.

### `CASE` — the expression-oriented alternative

`IF`/`ELSIF` is a *statement* (it runs blocks of code). `CASE` inside PL/pgSQL comes in two flavors: a
**`CASE` statement** (branches full code blocks, just like `IF`, useful when you want `CASE`'s exhaustive/
readable branch listing without collapsing to a single value) and a plain SQL **`CASE` expression** (returns a
single value, usable anywhere a value is expected — inside a `SELECT`, or on the right of `:=`). This chapter's
loan-risk snippet uses the expression form, since it's the one used constantly in ordinary SQL as well
(Chapter 6 introduced it for `SELECT` lists):

```plpgsql
DECLARE
    v_interest_rate loans.interest_rate%TYPE := 9.25;
    v_risk_category TEXT;
BEGIN
    v_risk_category := CASE
                            WHEN v_interest_rate < 8.0  THEN 'LOW_RISK'
                            WHEN v_interest_rate < 9.0  THEN 'MEDIUM_RISK'
                            ELSE 'HIGH_RISK'
                        END;
    RAISE NOTICE 'Risk category: %', v_risk_category;
END;
```

```
NOTICE:  Risk category: HIGH_RISK
```

**When to use `IF`/`ELSIF` vs. `CASE`:** reach for `CASE` when you're computing **one value** from a set of
mutually exclusive conditions (as above); reach for `IF`/`ELSIF` when each branch needs to run **multiple,
possibly unrelated statements** (as in `sp_describe_account`, where each branch is a whole `RAISE NOTICE` with
different formatting, not just a different value being assigned).

---

## 19.9 Loops: `WHILE`, `LOOP` + `EXIT WHEN`, and `FOR`

PL/pgSQL gives you four looping constructs. All four are shown here; Worked Example 7 (§19.11) is the
progressive series' dedicated loop example, built on the `FOR ... IN query` form.

### 19.9.1 `LOOP` + `EXIT WHEN` — the general-purpose loop

```plpgsql
DO $$
DECLARE
    v_n INT := 1;
BEGIN
    LOOP
        EXIT WHEN v_n > 5;
        RAISE NOTICE 'n = %', v_n;
        v_n := v_n + 1;
    END LOOP;
END;
$$;
```

```
NOTICE:  n = 1
NOTICE:  n = 2
NOTICE:  n = 3
NOTICE:  n = 4
NOTICE:  n = 5
```

`LOOP ... END LOOP;` on its own runs forever; `EXIT WHEN condition;` is what actually terminates it — checked
at the top of every iteration, before that iteration's body runs. Plain `EXIT;` (no `WHEN`) exits unconditionally
wherever it appears, and `CONTINUE;` / `CONTINUE WHEN condition;` skips the rest of the current iteration and
jumps back to the loop's top — both are legal inside any of the loop forms in this section.

### 19.9.2 `WHILE`

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_project_compound_growth(
    p_principal NUMERIC,
    p_rate      NUMERIC,   -- annual rate, e.g. 8.5 means 8.5%
    p_years     INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC := p_principal;
    v_year    INT := 1;
BEGIN
    WHILE v_year <= p_years LOOP
        v_balance := v_balance * (1 + p_rate / 100.0);
        RAISE NOTICE 'End of year %: balance = %', v_year, ROUND(v_balance, 2);
        v_year := v_year + 1;
    END LOOP;
END;
$$;
```

```sql
CALL banking_db.sp_project_compound_growth(500000.00, 8.50, 3);
```

```
NOTICE:  End of year 1: balance = 542500.00
NOTICE:  End of year 2: balance = 588612.50
NOTICE:  End of year 3: balance = 638644.56
```

**Line by line:**

1. `v_balance NUMERIC := p_principal;` — starts the running balance equal to the initial principal (loan 1's
   amount, ₹500,000, is used in the call above).
2. `WHILE v_year <= p_years LOOP` — the condition is checked *before* every iteration, including the first;
   if `p_years` were `0`, the loop body would never run at all.
3. `v_balance := v_balance * (1 + p_rate / 100.0);` — compounds once per iteration. `p_rate / 100.0` converts
   the percentage (`8.50`) to a decimal multiplier fraction (`0.085`); the `.0` on `100.0` forces floating/
   numeric division rather than any risk of integer truncation.
4. `ROUND(v_balance, 2)` — rounds for display to 2 decimal places, matching currency precision, without
   altering the actual stored precision of `v_balance` itself (only the printed value is rounded).
5. `v_year := v_year + 1;` — the manual increment `WHILE` always requires; forgetting this line is the single
   most common way to write an infinite loop with `WHILE`.

**`WHILE` vs. `LOOP`+`EXIT WHEN`:** functionally interchangeable — `WHILE cond LOOP ... END LOOP;` is exactly
equivalent to `LOOP EXIT WHEN NOT cond; ... END LOOP;`. Use `WHILE` when the exit condition is naturally checked
*before* any work happens (the common case); reach for bare `LOOP`+`EXIT WHEN` when the natural exit check
belongs somewhere in the *middle* of the loop body (e.g., after fetching a cursor row, per Chapter 21) rather
than cleanly at the top.

### 19.9.3 `FOR` — numeric range

```plpgsql
DO $$
BEGIN
    FOR i IN 1..5 LOOP
        RAISE NOTICE 'i = %', i;
    END LOOP;
    RAISE NOTICE '--- counting down, step 2 ---';
    FOR i IN REVERSE 10..0 BY 2 LOOP
        RAISE NOTICE 'i = %', i;
    END LOOP;
END;
$$;
```

```
NOTICE:  i = 1
NOTICE:  i = 2
NOTICE:  i = 3
NOTICE:  i = 4
NOTICE:  i = 5
NOTICE:  --- counting down, step 2 ---
NOTICE:  i = 10
NOTICE:  i = 8
NOTICE:  i = 6
NOTICE:  i = 4
NOTICE:  i = 2
NOTICE:  i = 0
```

`i` is implicitly declared by the `FOR` loop itself (do **not** also declare it in `DECLARE` — that raises an
error) and scoped only to the loop body; it does not exist before or after the loop. `REVERSE` counts down
instead of up, and `BY n` sets the step size (default `1`).

### 19.9.4 `FOR ... IN query` — iterating over a result set

This is the form used by Worked Example 7 in §19.11, since it's the one that matters most for real
data-processing procedures: instead of counting integers, you loop once per **row** returned by a query.

```plpgsql
DO $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT account_id, balance FROM banking_db.accounts WHERE account_type = 'SAVINGS'
    LOOP
        RAISE NOTICE 'Account %: balance %', rec.account_id, rec.balance;
    END LOOP;
END;
$$;
```

```
NOTICE:  Account 1: balance 150000.00
NOTICE:  Account 3: balance 80000.00
NOTICE:  Account 4: balance 300000.00
NOTICE:  Account 6: balance 20000.00
```

`rec RECORD` declares a generic row variable whose actual columns are determined fresh on each `FOR` iteration
by the query's result shape; `rec.account_id` and `rec.balance` access individual fields by the name they were
selected as. The query inside a `FOR ... IN` loop is planned and executed **once**, up front, as a cursor
internally — each loop iteration is a cheap "fetch next row" rather than a fresh query, which is exactly why
this form scales far better than issuing a new `SELECT` per iteration from inside a `WHILE` loop.

---

## 19.10 Worked Examples 3, 4, 5 of 11 — Insert, Update, and Validation

### Worked Example 3 of 11 — inserting data: open a new account

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_open_account(
    p_customer_id     INT,
    p_account_type    VARCHAR,
    p_initial_balance NUMERIC,
    OUT p_account_id  INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO banking_db.accounts (customer_id, account_type, balance, opened_date, status)
    VALUES (p_customer_id, p_account_type, p_initial_balance, CURRENT_DATE, 'ACTIVE')
    RETURNING account_id INTO p_account_id;

    RAISE NOTICE 'Opened account % for customer % (% , balance %)',
                 p_account_id, p_customer_id, p_account_type, p_initial_balance;
END;
$$;
```

```sql
CALL banking_db.sp_open_account(2, 'CURRENT', 25000.00, NULL);
```

```
NOTICE:  Opened account 8 for customer 2 (CURRENT , balance 25000.00)
 p_account_id
--------------
            8
```

**Line by line:**

1. Four parameters: three `IN` (`p_customer_id`, `p_account_type`, `p_initial_balance`) and one `OUT`
   (`p_account_id`) — the newly generated primary key handed back to the caller.
2. `INSERT INTO banking_db.accounts (customer_id, account_type, balance, opened_date, status) VALUES (...)` —
   `account_id` is omitted from the column list entirely, letting the table's `SERIAL` default generate it. The
   seed data's highest `account_id` is `7`, so — assuming no other inserts have happened yet in your session —
   the new row gets `account_id = 8`.
3. `RETURNING account_id INTO p_account_id;` — `RETURNING` (introduced for plain `INSERT`/`UPDATE`/`DELETE` in
   Chapter 3) combines directly with `INTO` inside PL/pgSQL to capture the newly generated key without a
   separate round-trip `SELECT currval(...)` afterward.
4. `RAISE NOTICE` — confirms the result, using the now-populated `p_account_id`.

**Common mistakes**
- Specifying `account_id` explicitly in the `INSERT` (e.g., hardcoding `8`) — this both defeats the purpose of
  `SERIAL` and, worse, can desynchronize the underlying sequence from the table's actual max ID, causing a
  future auto-generated insert to collide with a manually-specified one and fail with a unique-violation error.
- Not validating `p_account_type` before inserting — the table's own `CHECK (account_type IN
  ('SAVINGS','CURRENT','FIXED_DEPOSIT'))` constraint *will* catch an invalid value, but the error message a
  caller sees (`new row for relation "accounts" violates check constraint "accounts_account_type_check"`) is
  far less friendly than a procedure-level validation message — motivating Worked Example 5 next.

### Worked Example 4 of 11 — updating data: apply interest to one account

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_apply_interest_to_account(
    p_account_id INT,
    p_rate       NUMERIC   -- percentage, e.g. 1.00 means 1%
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_balance accounts.balance%TYPE;
    v_new_balance accounts.balance%TYPE;
BEGIN
    UPDATE banking_db.accounts
       SET balance = balance * (1 + p_rate / 100.0)
     WHERE account_id = p_account_id
    RETURNING balance INTO v_new_balance;

    IF NOT FOUND THEN
        RAISE NOTICE 'No account found with account_id = %', p_account_id;
        RETURN;
    END IF;

    RAISE NOTICE 'Applied %% interest to account %. New balance: %', p_rate, p_account_id, v_new_balance;
END;
$$;
```

```sql
CALL banking_db.sp_apply_interest_to_account(1, 1.00);
```

```
NOTICE:  Applied 1.00% interest to account 1. New balance: 151500.00
```

**Line by line:**

1. `UPDATE ... SET balance = balance * (1 + p_rate / 100.0) WHERE account_id = p_account_id RETURNING balance
   INTO v_new_balance;` — a single statement that both performs the update *and* captures the resulting value,
   with no second `SELECT` needed. Account 1 starts at `150000.00`; `150000.00 * 1.01 = 151500.00`.
2. `IF NOT FOUND THEN ... RETURN; END IF;` — `FOUND` after an `UPDATE` reflects whether any row was actually
   matched/updated — the same defensive pattern from Worked Example 2, now applied to a write instead of a read.
3. `RAISE NOTICE 'Applied %% interest ...'` — note the **doubled `%%`**: because `%` is `RAISE`'s placeholder
   character, a literal percent sign in the output text must be escaped as `%%`, exactly like `%%` in C's
   `printf`. Forgetting this either misaligns every subsequent `%` placeholder with the wrong argument or raises
   `ERROR: too few parameters specified for RAISE`.

**Edge case:** calling this with `p_account_id = 7` (the `FROZEN` account) still succeeds and applies interest
— this procedure does not check `status`, on purpose, to set up the natural next question: *should* a frozen
account earn interest? That question is exactly what Worked Example 5's validation pattern, and later
Example 7's `WHERE status = 'ACTIVE'` filter, address.

### Worked Example 5 of 11 — validation: reject a negative initial balance

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_open_account_validated(
    p_customer_id     INT,
    p_account_type    VARCHAR,
    p_initial_balance NUMERIC,
    OUT p_account_id  INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_initial_balance < 0 THEN
        RAISE EXCEPTION 'Initial balance cannot be negative (got %)', p_initial_balance
            USING ERRCODE = '22003', HINT = 'Pass a value of 0 or greater.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM banking_db.customers WHERE customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'Customer % does not exist', p_customer_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    INSERT INTO banking_db.accounts (customer_id, account_type, balance, opened_date, status)
    VALUES (p_customer_id, p_account_type, p_initial_balance, CURRENT_DATE, 'ACTIVE')
    RETURNING account_id INTO p_account_id;

    RAISE NOTICE 'Opened account % with validated initial balance %', p_account_id, p_initial_balance;
END;
$$;
```

```sql
CALL banking_db.sp_open_account_validated(4, 'SAVINGS', -500.00, NULL);
```

```
ERROR:  Initial balance cannot be negative (got -500.00)
HINT:  Pass a value of 0 or greater.
```

**Line by line:**

1. `IF p_initial_balance < 0 THEN RAISE EXCEPTION '...' USING ERRCODE = '22003', HINT = '...'; END IF;` — this
   is the chapter's first `RAISE EXCEPTION`: unlike `RAISE NOTICE`, `RAISE EXCEPTION` immediately **aborts** the
   procedure (and, unless caught by an `EXCEPTION` block per §19.12, aborts the entire enclosing transaction) —
   no `INSERT` below it ever runs. `USING ERRCODE = '22003'` assigns the standard SQLSTATE code for
   "numeric_value_out_of_range" (rather than the generic default `P0001`), and `HINT` attaches a second line of
   guidance that many clients display separately from the main error message.
2. The second guard, checking the customer exists via `NOT EXISTS (...)`, demonstrates that validation isn't
   limited to simple arithmetic comparisons — it's any boolean condition, including one that itself requires a
   subquery.
3. Because the exception is raised *before* the `INSERT`, no half-applied write occurs — the whole `CALL`
   either fully succeeds or has no effect on `accounts` at all.

**When to validate in the procedure vs. rely on table constraints:** table `CHECK`/`NOT NULL`/`FOREIGN KEY`
constraints (Chapter 13) are your last line of defense and can never be bypassed no matter what inserts the row
— keep them regardless. Procedure-level validation exists *in addition*, not instead, primarily to produce a
clear, business-meaningful error message and to fail *before* touching the table at all (useful when the
validation logic is more complex than a single-row boolean expression a `CHECK` constraint could express, e.g.
Example 5's cross-table `EXISTS` check, or Example 11's multi-table eligibility rule in §19.14).

---

## 19.11 Worked Example 7 of 11 — Loops in Practice: Monthly Interest on Every Active Savings Account

This is the payoff of §19.9's `FOR ... IN query` form: a single procedure call that walks every active savings
account and updates it, reporting per-row progress and a final summary.

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_apply_monthly_interest_all_savings(
    p_rate NUMERIC DEFAULT 0.5    -- monthly percentage, defaults to 0.5%
)
LANGUAGE plpgsql
AS $$
DECLARE
    rec               RECORD;
    v_accounts_updated INT := 0;
    v_total_interest   NUMERIC := 0;
    v_interest_amount   NUMERIC;
BEGIN
    FOR rec IN
        SELECT account_id, balance
          FROM banking_db.accounts
         WHERE account_type = 'SAVINGS'
           AND status = 'ACTIVE'
         ORDER BY account_id
    LOOP
        v_interest_amount := ROUND(rec.balance * p_rate / 100.0, 2);

        UPDATE banking_db.accounts
           SET balance = balance + v_interest_amount
         WHERE account_id = rec.account_id;

        RAISE NOTICE 'Account %: credited % interest (old balance %, new balance %)',
                     rec.account_id, v_interest_amount, rec.balance, rec.balance + v_interest_amount;

        v_accounts_updated := v_accounts_updated + 1;
        v_total_interest   := v_total_interest + v_interest_amount;
    END LOOP;

    RAISE NOTICE '--- Done: % account(s) updated, total interest credited: % ---',
                 v_accounts_updated, v_total_interest;
END;
$$;
```

```sql
CALL banking_db.sp_apply_monthly_interest_all_savings(0.5);
```

```
NOTICE:  Account 1: credited 750.00 interest (old balance 150000.00, new balance 150750.00)
NOTICE:  Account 3: credited 400.00 interest (old balance 80000.00, new balance 80400.00)
NOTICE:  Account 4: credited 1500.00 interest (old balance 300000.00, new balance 301500.00)
NOTICE:  Account 6: credited 100.00 interest (old balance 20000.00, new balance 20100.00)
NOTICE:  --- Done: 4 account(s) updated, total interest credited: 2750.00 ---
```

**Line by line:**

1. `p_rate NUMERIC DEFAULT 0.5` — a parameter default. `CALL sp_apply_monthly_interest_all_savings();` (no
   arguments at all) is legal and uses `0.5`; `CALL sp_apply_monthly_interest_all_savings(1.0);` overrides it.
2. Three accumulator variables: `v_accounts_updated` (a count), `v_total_interest` (a running sum), both
   initialized to `0` since they're accumulated into across iterations — forgetting to initialize an
   accumulator variable in PL/pgSQL leaves it `NULL`, and `NULL + anything` is `NULL`, silently poisoning every
   subsequent addition (a classic bug: the loop *looks* correct but the final total prints as nothing at all).
3. `FOR rec IN SELECT account_id, balance FROM accounts WHERE account_type = 'SAVINGS' AND status = 'ACTIVE'
   ORDER BY account_id LOOP` — filters to exactly the four qualifying rows from the seed data (accounts `1`,
   `3`, `4`, `6` — account `5` is excluded because it's a `FIXED_DEPOSIT`, not `SAVINGS`, and no active savings
   account is excluded by the `status` filter in this particular seed, though the filter matters in general
   since a hypothetically `FROZEN` savings account should not silently keep earning interest). `ORDER BY
   account_id` makes iteration order deterministic and the output reproducible.
4. `v_interest_amount := ROUND(rec.balance * p_rate / 100.0, 2);` — computed once per row, from that row's
   *pre-update* balance (`rec.balance`, captured when the row was fetched by the `FOR` loop, not re-read after
   the `UPDATE`).
5. `UPDATE banking_db.accounts SET balance = balance + v_interest_amount WHERE account_id = rec.account_id;` —
   one `UPDATE` per loop iteration, each an independent statement targeting exactly one row by primary key.
6. The `RAISE NOTICE` inside the loop reports per-account detail; the accumulators are incremented immediately
   after.
7. After the loop ends, the final `RAISE NOTICE` reports the summary — `4` accounts, `2750.00` total interest,
   matching `750 + 400 + 1500 + 100 = 2750`.

**Common mistakes**
- Reading `rec.balance` *after* the `UPDATE` inside the same iteration, expecting it to reflect the new value —
  it never does; `rec` is a snapshot captured once per row by the cursor underlying the `FOR` loop and is never
  refreshed by writes your own procedure makes.
- Missing `ORDER BY` in the driving query — without it, iteration order (and therefore the exact sequence of
  `NOTICE` lines) is not guaranteed to be stable across runs, which matters for reproducible logs/tests even
  though the final `UPDATE`s themselves are unaffected.
- **Row-by-row `UPDATE`s inside a loop, when a single set-based `UPDATE` would do.** This procedure could be
  rewritten as one statement: `UPDATE banking_db.accounts SET balance = ROUND(balance * (1 + p_rate/100.0), 2)
  WHERE account_type = 'SAVINGS' AND status = 'ACTIVE';` — and for *this specific* operation (a uniform
  percentage bump with no per-row side effect beyond the update itself), the set-based version is strictly
  better: one query plan, one pass over the table, far less overhead than four separate `UPDATE` statements.
  This procedure is written the loop way specifically to teach the `FOR ... IN query` construct — but see the
  "when to use loops at all" note below.

> **Important Note — when a loop over rows is actually justified**
> Reach for `FOR ... IN query` (as opposed to one set-based `UPDATE`/`INSERT ... SELECT`) only when each row
> needs **genuinely per-row procedural logic that a single SQL statement cannot express** — e.g., calling a
> different helper procedure per row (as Example 9 will do via `CALL`), applying business rules with
> early-exit branching that differs per row in a way a `CASE` expression can't cleanly capture, or needing a
> per-row `RAISE`/log line as this example does for observability. If the entire operation reduces to "the same
> single expression applied uniformly to every matching row," a plain `UPDATE ... WHERE ...` is simpler, faster,
> and less code — this is the same "prefer set-based SQL" lesson Chapter 21 (Cursors) drives home in full.

---

## 19.12 Error Handling: `RAISE`, `EXCEPTION` Blocks, `SQLSTATE`/`SQLERRM`

### 19.12.1 `RAISE` severity levels

| Level | Effect |
|---|---|
| `RAISE DEBUG '...'` | Lowest-visibility diagnostic message, normally invisible unless `client_min_messages`/`log_min_messages` is lowered. |
| `RAISE LOG '...'` | Always written to the server log, not sent to the client by default. |
| `RAISE NOTICE '...'` | Sent to the client as an informational message (used throughout this chapter so far). Execution continues normally afterward. |
| `RAISE WARNING '...'` | Also sent to the client, at a more urgent severity than `NOTICE` — clients/log configs commonly surface `WARNING` more prominently. Execution continues normally afterward. |
| `RAISE EXCEPTION '...'` | **Aborts** the current transaction (unless caught — see §19.12.3) and returns an error to the caller. Nothing after it in the procedure runs. |

```plpgsql
RAISE WARNING 'Account % balance is below the minimum threshold', p_account_id;
RAISE EXCEPTION 'Insufficient funds in account %: balance % < requested %',
                p_account_id, v_balance, p_amount;
```

### 19.12.2 `SQLSTATE` and `SQLERRM`

Every PostgreSQL error carries a five-character **SQLSTATE** code (an ANSI-standard cross-database error
classification, not PostgreSQL-specific) alongside its human-readable message. A handful you'll see constantly:

| SQLSTATE | Condition name | Meaning |
|---|---|---|
| `23505` | `unique_violation` | A unique/primary-key constraint was violated |
| `23503` | `foreign_key_violation` | A referenced row doesn't exist |
| `23514` | `check_violation` | A `CHECK` constraint failed |
| `P0002` | `no_data_found` | `SELECT ... INTO STRICT` matched zero rows |
| `P0003` | `too_many_rows` | `SELECT ... INTO STRICT` matched more than one row |
| `P0001` | `raise_exception` | The generic default code for a plain `RAISE EXCEPTION '...'` with no explicit `ERRCODE` |

Inside an `EXCEPTION` handler (next section), two special variables are available:

- `SQLSTATE` — the five-character code of the error just caught.
- `SQLERRM` — the error's human-readable message text.

### 19.12.3 `EXCEPTION` blocks

```plpgsql
BEGIN
    -- statements that might fail
EXCEPTION
    WHEN condition_name THEN
        -- handler statements
    WHEN OTHERS THEN
        -- catch-all handler
END;
```

`WHEN condition_name` can name a specific condition (`unique_violation`, `foreign_key_violation`,
`division_by_zero`, and dozens more built-in names — see the PostgreSQL documentation's "Errors and Messages"
appendix for the full list) or the special catch-all `WHEN OTHERS`, which matches any error not already
matched by an earlier `WHEN` in the same block.

```plpgsql
DO $$
DECLARE
    v_result NUMERIC;
BEGIN
    BEGIN
        v_result := 100 / 0;
    EXCEPTION
        WHEN division_by_zero THEN
            RAISE NOTICE 'Caught division by zero: SQLSTATE=%, message=%', SQLSTATE, SQLERRM;
        WHEN OTHERS THEN
            RAISE NOTICE 'Caught an unexpected error: %', SQLERRM;
    END;
    RAISE NOTICE 'Execution continues normally after the handled exception.';
END;
$$;
```

```
NOTICE:  Caught division by zero: SQLSTATE=22012, message=division by zero
NOTICE:  Execution continues normally after the handled exception.
```

> **Important Note — internal behavior**
> An `EXCEPTION` block establishes an internal **savepoint** before running its guarded statements. If an error
> occurs, PostgreSQL automatically rolls back to that savepoint (undoing any partial writes the guarded block
> made) before handing control to the matching `WHEN` clause — this is why code *after* the `EXCEPTION` block
> can keep running as if nothing happened at the surrounding transaction level, while whatever the failed inner
> block itself had done is cleanly undone. This is not free: each `BEGIN ... EXCEPTION ... END` block that
> actually catches an error costs a real subtransaction, which has non-trivial overhead if it happens inside a
> tight loop processing millions of rows — avoid wrapping trivial, rarely-failing statements in `EXCEPTION`
> blocks purely out of caution.

### 19.12.4 Custom exceptions

You can define your own named condition and raise it with a custom SQLSTATE, letting callers (or nested
`EXCEPTION` blocks) match on it specifically instead of falling through to `WHEN OTHERS`:

```plpgsql
RAISE EXCEPTION 'Insufficient funds in account %', p_account_id
    USING ERRCODE = 'BK001', HINT = 'Check the account balance before retrying.';
```

```plpgsql
EXCEPTION
    WHEN SQLSTATE 'BK001' THEN
        RAISE NOTICE 'Handled a custom insufficient-funds condition: %', SQLERRM;
```

Custom SQLSTATE codes are five characters and, by convention, should avoid colliding with the built-in ranges —
using a memorable application-specific prefix (`BK001`, `BK002`, ...) for "banking" errors, as this chapter
does starting in the next section, is a common pattern.

---

## 19.13 Transactions Inside Procedures: `COMMIT`/`ROLLBACK`

### Worked Example 8 of 11 — a full money transfer with `COMMIT`/`ROLLBACK`

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_transfer_funds(
    p_from_account INT,
    p_to_account   INT,
    p_amount       NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_from_balance accounts.balance%TYPE;
BEGIN
    SELECT balance INTO v_from_balance
      FROM banking_db.accounts
     WHERE account_id = p_from_account
       FOR UPDATE;                          -- row lock — see Chapter 12

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source account % does not exist', p_from_account;
    END IF;

    IF v_from_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds in account %: balance % < requested %',
                        p_from_account, v_from_balance, p_amount;
    END IF;

    UPDATE banking_db.accounts SET balance = balance - p_amount WHERE account_id = p_from_account;
    UPDATE banking_db.accounts SET balance = balance + p_amount WHERE account_id = p_to_account;

    INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_from_account, 'TRANSFER_OUT', p_amount, p_to_account, 'Procedure transfer');

    INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_to_account, 'TRANSFER_IN', p_amount, p_from_account, 'Procedure transfer');

    COMMIT;
    RAISE NOTICE 'Transferred % from account % to account %. Committed.', p_amount, p_from_account, p_to_account;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE NOTICE 'Transfer failed and rolled back: %', SQLERRM;
        RAISE;
END;
$$;
```

```sql
CALL banking_db.sp_transfer_funds(1, 3, 30000.00);
```

```
NOTICE:  Transferred 30000.00 from account 1 to account 3. Committed.
```

```sql
SELECT account_id, balance FROM banking_db.accounts WHERE account_id IN (1, 3);
```

```
 account_id | balance
------------+-----------
          1 | 120000.00
          3 | 110000.00
```

**Line by line:**

1. `SELECT balance INTO v_from_balance FROM accounts WHERE account_id = p_from_account FOR UPDATE;` — locks
   the source row for the remainder of this transaction (`FOR UPDATE`, fully explained in Chapter 12) so a
   concurrent transfer out of the same account can't read a stale balance and cause a lost update — a real
   concurrency hazard for anything touching money.
2. Two guard clauses, mirroring Example 5's validation pattern: account-not-found, then insufficient-funds —
   each a `RAISE EXCEPTION` that aborts everything below it.
3. `UPDATE ... SET balance = balance - p_amount ...` then `UPDATE ... SET balance = balance + p_amount ...` —
   the debit and credit, as two separate statements. Both run inside the same transaction as everything above,
   so if the second `UPDATE` somehow failed, PostgreSQL's normal atomic-transaction guarantee would already
   ensure the first one's effect is undone *before* we ever reach explicit `COMMIT`/`ROLLBACK` logic — the
   explicit exception handling in this procedure exists for the *business-level* failures (insufficient funds,
   missing account), not to protect against partial writes, which ordinary transaction atomicity already
   prevents.
4. Two `INSERT INTO transactions ...` — a `TRANSFER_OUT` row on the source account and a `TRANSFER_IN` row on
   the destination, each pointing at the other via `related_account_id`, matching the exact pattern already
   present in the seed data (see the `TRANSFER_OUT`/`TRANSFER_IN` pair for accounts 1 and 3 in
   `databases/banking_db.sql`).
5. `COMMIT;` — this is the line that could not exist in a `FUNCTION` (§19.3). It durably persists every write
   above, and PostgreSQL immediately opens a new transaction so the procedure could, in principle, keep going
   (it doesn't need to here, but Example 11 uses this property more directly).
6. `EXCEPTION WHEN OTHERS THEN ROLLBACK; RAISE NOTICE ...; RAISE;` — if *anything* above raised (insufficient
   funds, missing account, or even an unexpected constraint violation), this handler explicitly `ROLLBACK`s
   (undoing every write made so far in this call, since nothing was committed yet), logs a friendly notice, and
   then `RAISE;` with no arguments **re-raises the original error**, so the caller still sees the failure — the
   handler adds a log line without silently swallowing the problem.

**Try it and watch it roll back:**

```sql
CALL banking_db.sp_transfer_funds(6, 1, 999999.00);
```

```
NOTICE:  Transfer failed and rolled back: Insufficient funds in account 6: balance 20000.00 < requested 999999.00
ERROR:  Insufficient funds in account 6: balance 20000.00 < requested 999999.00
```

Account 6's balance is confirmed unchanged at `20000.00` afterward — nothing was partially applied.

> **⚠️ Warning — the restriction that trips people up**
> `COMMIT`/`ROLLBACK` inside a procedure are legal **only** when `CALL sp_transfer_funds(...)` is itself the
> top-level statement PostgreSQL is currently executing with no other open transaction wrapped around it. All
> three of the following break that assumption and raise `ERROR: invalid transaction termination`:
> 1. Explicitly wrapping the call yourself: `BEGIN; CALL sp_transfer_funds(1,3,100); COMMIT;`
> 2. Calling this procedure from inside another function.
> 3. Calling this procedure from inside a `DO $$ ... $$;` anonymous block.
>
> The only supported nesting is **procedure calling procedure** directly via `CALL` (§19.14) — that composition
> is explicitly allowed and is the intended way to build larger transactional workflows out of smaller ones.

---

## 19.14 Worked Example 9 of 11 — Error Handling in the Transfer Procedure, with Audit Logging

This example builds directly on Example 8, adding structured `EXCEPTION` handling that distinguishes
*insufficient funds* from *account not found* as separate, named conditions, and logs every failed attempt to
`audit_log` — while also demonstrating **calling another procedure via `CALL`** as required coverage for this
chapter.

First, a small reusable helper procedure — this is the "calling other procedures via `CALL`" requirement,
factored out so both this example and Example 11 (§19.16) can reuse it instead of duplicating raw `INSERT`
statements:

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_log_audit_event(
    p_table_name TEXT,
    p_operation  TEXT,
    p_row_pk     TEXT,
    p_new_data   JSONB
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO banking_db.audit_log (table_name, operation, row_pk, new_data)
    VALUES (p_table_name, p_operation, p_row_pk, p_new_data);
END;
$$;
```

Now the hardened transfer procedure:

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_transfer_funds_safe(
    p_from_account INT,
    p_to_account   INT,
    p_amount       NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_from_balance accounts.balance%TYPE;
    v_from_status  accounts.status%TYPE;
BEGIN
    BEGIN
        SELECT balance, status INTO STRICT v_from_balance, v_from_status
          FROM banking_db.accounts
         WHERE account_id = p_from_account
           FOR UPDATE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            CALL banking_db.sp_log_audit_event(
                'accounts', 'UPDATE', p_from_account::TEXT,
                jsonb_build_object('error', 'account_not_found', 'attempted_amount', p_amount)
            );
            RAISE EXCEPTION 'Transfer aborted: source account % does not exist', p_from_account
                USING ERRCODE = 'BK002';
    END;

    IF v_from_status <> 'ACTIVE' THEN
        CALL banking_db.sp_log_audit_event(
            'accounts', 'UPDATE', p_from_account::TEXT,
            jsonb_build_object('error', 'account_not_active', 'status', v_from_status, 'attempted_amount', p_amount)
        );
        RAISE EXCEPTION 'Transfer aborted: source account % is % (not ACTIVE)', p_from_account, v_from_status
            USING ERRCODE = 'BK003';
    END IF;

    IF v_from_balance < p_amount THEN
        CALL banking_db.sp_log_audit_event(
            'accounts', 'UPDATE', p_from_account::TEXT,
            jsonb_build_object('error', 'insufficient_funds', 'balance', v_from_balance, 'attempted_amount', p_amount)
        );
        RAISE EXCEPTION 'Transfer aborted: insufficient funds in account % (balance % < requested %)',
                        p_from_account, v_from_balance, p_amount
            USING ERRCODE = 'BK001';
    END IF;

    UPDATE banking_db.accounts SET balance = balance - p_amount WHERE account_id = p_from_account;
    UPDATE banking_db.accounts SET balance = balance + p_amount WHERE account_id = p_to_account;

    INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_from_account, 'TRANSFER_OUT', p_amount, p_to_account, 'Safe transfer');
    INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_to_account, 'TRANSFER_IN', p_amount, p_from_account, 'Safe transfer');

    CALL banking_db.sp_log_audit_event(
        'transactions', 'INSERT', p_from_account::TEXT,
        jsonb_build_object('transfer_amount', p_amount, 'to_account', p_to_account)
    );

    COMMIT;
    RAISE NOTICE 'Transfer of % from account % to account % completed successfully.',
                 p_amount, p_from_account, p_to_account;
END;
$$;
```

```sql
CALL banking_db.sp_transfer_funds_safe(7, 1, 1000.00);
```

```
ERROR:  Transfer aborted: source account 7 is FROZEN (not ACTIVE)
```

```sql
SELECT * FROM banking_db.audit_log ORDER BY audit_id DESC LIMIT 1;
```

```
 audit_id | table_name | operation | row_pk |          new_data
----------+------------+-----------+--------+------------------------------------------------
        1 | accounts   | UPDATE    | 7      | {"error": "account_not_active", "status": "FROZEN", "attempted_amount": 1000.00}
```

**Line by line (only what's new versus Example 8):**

1. `sp_log_audit_event(...)` — a standalone helper procedure with its own `INSERT`. Note it has **no**
   `COMMIT` of its own — since it's always invoked from inside another procedure's still-open transaction here,
   adding a `COMMIT` inside it would commit the *caller's* in-progress work prematurely (and, if the caller
   itself already committed and this is called again later in the same call, would otherwise work — but mixing
   "sometimes has its own commit, sometimes doesn't" makes a helper procedure's behavior depend on unpredictable
   context, which is bad practice). Keep single-responsibility helper procedures free of `COMMIT` unless they
   are explicitly designed to always run standalone.
2. `SELECT ... INTO STRICT v_from_balance, v_from_status ... FOR UPDATE;` wrapped in its own nested `BEGIN ...
   EXCEPTION WHEN NO_DATA_FOUND ... END;` — `INTO STRICT` (§19.6) raises the named condition `NO_DATA_FOUND`
   (SQLSTATE `P0002`) if the account doesn't exist at all, which this nested block catches specifically, logs,
   and re-raises as a friendlier, `BK002`-coded exception.
3. `CALL banking_db.sp_log_audit_event(...)` — this is the "calling other procedures via `CALL`" requirement in
   action: from *inside* one procedure's body, a plain `CALL` invokes another already-defined procedure. This
   is legal specifically because it is not attempting its own independent `COMMIT`/`ROLLBACK` — it just runs as
   ordinary statements inside the caller's transaction.
4. `jsonb_build_object('error', 'account_not_active', 'status', v_from_status, 'attempted_amount', p_amount)` —
   builds a `JSONB` value inline, matching the `audit_log.new_data JSONB` column's type, to capture structured
   failure context instead of a flat string — queryable later with `->>`/`->` operators (Chapter 25).
5. The `status <> 'ACTIVE'` guard is new versus Example 8, and this is exactly why: account 7 is `FROZEN` in
   the seed data with a `5000.00` balance — Example 8's procedure would have let a transfer *out* of a frozen
   account through as long as funds were sufficient (a real gap this hardened version closes), and this example
   deliberately calls it with account 7 as the source to demonstrate the new check actually firing.
6. Every failure path logs to `audit_log` *before* raising — since none of the failure branches have reached
   `COMMIT` yet, is the `INSERT INTO audit_log` (run via `sp_log_audit_event`) itself part of the transaction
   that then gets... **not rolled back**, because `RAISE EXCEPTION` immediately after it aborts the current
   transaction and nothing commits it. This is a genuine subtlety worth stopping on:

> **⚠️ Warning — a failed transfer's audit-log entry is lost too, unless you plan for it**
> In the version above, the `CALL sp_log_audit_event(...)` that logs a failure, and the `RAISE EXCEPTION`
> immediately after it, are in the **same transaction**. Since `RAISE EXCEPTION` aborts that whole transaction
> and nothing has `COMMIT`ted yet, PostgreSQL rolls back **everything**, including the audit-log insert you just
> made to record the failure — so, as written, the `SELECT * FROM audit_log` shown above would actually return
> **no rows** in a strict reading, not the row displayed. To genuinely persist a failure record that survives
> the surrounding rollback, you need one of: (a) log the failure from *outside* this procedure, in the caller's
> exception handler, in a transaction that itself still commits; (b) use `pg_background`/`dblink`-style
> autonomous-transaction workarounds (advanced, out of scope here); or (c) as the simplest fix within this
> chapter's toolset, restructure so the audit-log write happens and is explicitly `COMMIT`ted *before* the
> `RAISE EXCEPTION` — accepting that this now means the failure is durably recorded even though the whole
> transfer transaction concept has been split into two separate transactions. The version below applies fix
> (c), and is the version whose output is shown above:

```plpgsql
    IF v_from_status <> 'ACTIVE' THEN
        CALL banking_db.sp_log_audit_event(
            'accounts', 'UPDATE', p_from_account::TEXT,
            jsonb_build_object('error', 'account_not_active', 'status', v_from_status, 'attempted_amount', p_amount)
        );
        COMMIT;   -- <-- persist the audit record BEFORE raising, so it survives the abort below
        RAISE EXCEPTION 'Transfer aborted: source account % is % (not ACTIVE)', p_from_account, v_from_status
            USING ERRCODE = 'BK003';
    END IF;
```

This single detail — that an uncommitted audit write inside a transaction that then aborts *disappears along
with everything else* — is one of the most important, least obvious lessons in this entire chapter about
combining `EXCEPTION` handling with manual transaction control. Internalize it before writing Example 11.

---

## 19.15 Dynamic SQL: `EXECUTE` with `format()`/`USING`

> This section is intentionally brief — Chapter 23 (Dynamic SQL & Injection Safety) is where the full depth
> lives. What follows is exactly what you need to build Worked Example 10.

### Why dynamic SQL exists

Every statement in this chapter so far has a fixed table name and fixed column list known at the time the
procedure was written. Sometimes you genuinely don't know the table name (or column list, or `ORDER BY` target)
until the procedure actually runs — e.g., a generic reporting procedure that accepts *which* table to summarize
as a parameter. Plain PL/pgSQL statements can't parameterize an identifier (a table or column name) at all —
only *values* can be parameters (`WHERE account_id = p_account_id` works; `FROM p_table_name` does not, because
`p_table_name` there would need to be a literal string spliced into the SQL text, not bound as a value).
`EXECUTE` with dynamically constructed SQL text is how PL/pgSQL solves that.

### Worked Example 10 of 11 — a generic, injection-safe report procedure

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_table_status_report(
    p_table_name  TEXT,
    p_status_col  TEXT,
    p_status_val  TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_row_count INT;
    v_sql       TEXT;
BEGIN
    v_sql := format(
        'SELECT count(*) FROM banking_db.%I WHERE %I = $1',
        p_table_name, p_status_col
    );

    EXECUTE v_sql INTO v_row_count USING p_status_val;

    RAISE NOTICE 'Table "%": % row(s) where % = %', p_table_name, v_row_count, p_status_col, p_status_val;
END;
$$;
```

```sql
CALL banking_db.sp_table_status_report('accounts', 'status', 'ACTIVE');
```

```
NOTICE:  Table "accounts": 6 row(s) where status = ACTIVE
```

```sql
CALL banking_db.sp_table_status_report('loans', 'status', 'ACTIVE');
```

```
NOTICE:  Table "loans": 3 row(s) where status = ACTIVE
```

**Line by line:**

1. `v_sql := format('SELECT count(*) FROM banking_db.%I WHERE %I = $1', p_table_name, p_status_col);` —
   `format()` is PostgreSQL's safe string-templating function; `%I` is its "format as a quoted **identifier**"
   placeholder — it wraps `p_table_name`/`p_status_col` in double quotes and escapes any embedded double quote,
   which is exactly what a table/column name needs (identifiers cannot be bound as ordinary query parameters at
   all, so this is the *only* safe way to parameterize them). `$1` is left as a literal placeholder in the
   generated text — it is **not** substituted by `format()` — it's resolved later by `USING`.
2. `EXECUTE v_sql INTO v_row_count USING p_status_val;` — `EXECUTE` runs the dynamically built SQL text.
   `INTO v_row_count` captures the single returned value, exactly like static `SELECT ... INTO`. `USING
   p_status_val` binds `p_status_val` as an actual **query parameter** into the `$1` placeholder — this is the
   safe way to inject a *value* (as opposed to an identifier) into dynamic SQL: it goes through the same
   parameter-binding path as an ordinary prepared statement, so it can never be interpreted as SQL syntax no
   matter what characters it contains.
3. Row counts: seed data has 6 `ACTIVE` accounts (all except account 7, `FROZEN`) and 3 `ACTIVE` loans (loan 4
   is `CLOSED`) — matching the outputs shown.

> **⚠️ Warning — dynamic SQL injection risk**
> The version above is safe **because** it uses `%I` for identifiers and `USING`/parameter placeholders for
> values. The unsafe version many beginners write instead concatenates everything as text:
> ```plpgsql
> v_sql := 'SELECT count(*) FROM banking_db.' || p_table_name ||
>          ' WHERE ' || p_status_col || ' = ''' || p_status_val || '''';
> EXECUTE v_sql INTO v_row_count;
> ```
> This is a textbook SQL-injection vector: if `p_status_val` ever comes from an end user and equals something
> like `ACTIVE'; DROP TABLE banking_db.accounts; --`, the concatenated string splices that text directly into
> the executed statement. **Never concatenate raw parameter values into dynamic SQL text — always pass values
> through `USING`, and always pass identifiers through `format()`'s `%I` (or `quote_ident()` directly), never
> through plain string concatenation.** Chapter 23 covers every remaining nuance of this (including `%L` for
> safely quoting a *literal* value directly inside `format()` when `USING` isn't convenient, and the full
> injection-safety checklist) in depth — this section only establishes the pattern you need for Example 10 and
> Example 11.

---

## 19.16 Temporary Tables Inside Procedures (Brief)

A procedure can `CREATE TEMPORARY TABLE` to stage intermediate results for a complex multi-step computation,
exactly as you would in a plain session — the temp table is visible only to the current session and is dropped
automatically at the end of the session (or, if created `ON COMMIT DROP`, at the next `COMMIT`).

```plpgsql
CREATE TEMP TABLE tmp_high_balance_accounts ON COMMIT DROP AS
SELECT account_id, balance FROM banking_db.accounts WHERE balance > 100000;
```

This is useful inside a procedure when a computation needs several passes over an intermediate result set that
would be wasteful to recompute from scratch each time, or when you want to `JOIN` a computed intermediate result
against other tables using ordinary SQL rather than PL/pgSQL variables/loops. Full treatment — including
`ON COMMIT` behavior options, temp table naming/scoping rules, and performance characteristics versus CTEs — is
Chapter 24's subject; this chapter only flags that the feature composes naturally with everything you've learned
here (a temp table created inside a procedure behaves under that procedure's own `COMMIT`/`ROLLBACK` boundaries
exactly as described in §19.13).

> **Important Note**
> A temp table created with `ON COMMIT DROP` inside a procedure that later `COMMIT`s (§19.13) is dropped at
> that internal `COMMIT` — not just at session end — since each `COMMIT` inside a procedure really does end one
> transaction and start a new one. If you need a temp table's contents to survive an internal `COMMIT` for use
> later in the same procedure call, omit `ON COMMIT DROP` (the default persists it for the rest of the session).

---

## 19.17 Returning Result Sets: `OUT` Params, `RETURNS TABLE`/`SETOF`, and `INOUT refcursor`

Chapter scope explicitly asks how a procedure "returns a result set" — and the honest, precise answer requires
correcting a common assumption up front:

> **Important Note**
> `CREATE PROCEDURE` in PostgreSQL has **no `RETURNS` clause at all** — not `RETURNS TABLE`, not `RETURNS
> SETOF`, not even `RETURNS VOID`. `RETURNS TABLE(...)` and `RETURNS SETOF sometype` are **function** features
> (Chapter 20 §20.3) — if you need an object that a plain `SELECT * FROM my_object(...)` can consume as a table
> of rows, you must write a `FUNCTION`, not a `PROCEDURE`, full stop. A procedure's only channels back to a
> caller are:
> 1. **`OUT`/`INOUT` parameters** — but these only ever produce **one row** (the values current at the moment
>    the procedure finishes) — every worked example returning data so far in this chapter (Examples 3 and 11)
>    uses this channel.
> 2. **An `INOUT refcursor` parameter** — the one way a procedure *can* hand back a genuinely multi-row,
>    scrollable result to its caller, by opening a named cursor over a query and returning the cursor's *name*
>    rather than its rows; the caller then issues its own `FETCH`s against that name in the same transaction.

A minimal sketch (the full mechanics of cursors — `DECLARE`, `OPEN`, `FETCH`, `MOVE`, `CLOSE`, scrolling,
`FOR UPDATE` cursors — are Chapter 21's entire subject, not this chapter's):

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_active_savings_cursor(INOUT p_cursor REFCURSOR)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT account_id, balance FROM banking_db.accounts
         WHERE account_type = 'SAVINGS' AND status = 'ACTIVE';
END;
$$;
```

```sql
BEGIN;
CALL banking_db.sp_active_savings_cursor('my_cursor');
FETCH ALL FROM my_cursor;
COMMIT;
```

Note the `BEGIN;`/`COMMIT;` wrapping the whole exchange here: a cursor's result set stays valid only for the
lifetime of the transaction that opened it, so the client must keep the transaction open across the `CALL` and
every subsequent `FETCH` — which, per §19.13's warning, also means this specific procedure could never itself
issue an internal `COMMIT`, since it's now being called from inside a transaction the client opened by hand.
This tension — "cursors need an open transaction to survive across calls" vs. "internal `COMMIT` needs to be
top-level" — is exactly why Chapter 21 treats cursors as a topic of their own rather than folding them fully
into this chapter.

**Practical guidance for this course's schemas:** for genuinely multi-row reporting needs against
`banking_db`/`company_db`, reach for a `FUNCTION` with `RETURNS TABLE(...)` (Chapter 20) — it is simpler to
call (`SELECT * FROM fn_report(...)`), composes naturally with further `WHERE`/`ORDER BY`/`JOIN` on the caller's
side, and doesn't require the caller to manage an open transaction across a `CALL` plus multiple `FETCH`
round-trips the way a refcursor does. Reserve `INOUT refcursor` for the specific case where you need the
transactional/procedural guarantees of a `PROCEDURE` (e.g., internal `COMMIT`/`ROLLBACK` control, §19.13) *and*
a multi-row result — a genuinely narrow intersection.

---

## 19.18 Security: `SECURITY DEFINER` vs. `SECURITY INVOKER`, and Explicit `search_path`

### The two security contexts

| Mode | Whose privileges does the body run with? | Default? |
|---|---|---|
| `SECURITY INVOKER` | The **caller's** privileges — the procedure can only do what the calling role could already do directly | Yes, this is the default if unspecified |
| `SECURITY DEFINER` | The procedure **owner's** privileges — the procedure can do things the calling role could *not* do on its own | No — must be explicitly declared |

### Why `SECURITY DEFINER` exists

Consider a teller-facing application role that is intentionally granted `SELECT`/`INSERT`/`UPDATE` only on a
narrow set of tables — perhaps it has no direct `UPDATE` privilege on `accounts.balance` at all, to prevent any
raw, unaudited balance change. `sp_transfer_funds_safe` still needs to modify `accounts.balance`. Declaring the
procedure `SECURITY DEFINER`, owned by a more privileged role, lets the teller role successfully `CALL` it
(running with the *owner's* elevated privileges for the duration of that call) while still being unable to
`UPDATE accounts` directly — the procedure becomes the *only* sanctioned path to that change, which is precisely
the "single point of enforcement" argument from §19.1.

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.sp_transfer_funds_secure(
    p_from_account INT, p_to_account INT, p_amount NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = banking_db, pg_temp
AS $$
BEGIN
    -- identical body to sp_transfer_funds_safe
    NULL;
END;
$$;

REVOKE ALL ON banking_db.accounts FROM teller_role;
GRANT EXECUTE ON PROCEDURE banking_db.sp_transfer_funds_secure(INT, INT, NUMERIC) TO teller_role;
```

### Why explicit `search_path` is mandatory for `SECURITY DEFINER`

> **⚠️ Warning — search_path hijacking**
> A `SECURITY DEFINER` procedure that references unqualified table/function names (just `accounts`, not
> `banking_db.accounts`) resolves those names using **whatever `search_path` is in effect when it's called** —
> which is the *caller's* session setting, not necessarily the owner's, unless the procedure pins it explicitly.
> A malicious or careless caller who can create objects in a schema earlier in their own `search_path` (for
> example, a schema-per-user setup, or simply `CREATE TABLE public.accounts (...)` if `public` precedes
> `banking_db`) can get a `SECURITY DEFINER` procedure — running with elevated privileges — to silently operate
> against an attacker-controlled table or function instead of the real one. This is a well-known, real-world
> PostgreSQL privilege-escalation pattern, not a theoretical concern.
>
> The fix, shown above, is **`SET search_path = banking_db, pg_temp`** on the procedure definition itself: this
> pins name resolution for the entire duration of the call to exactly the schemas you intend, regardless of
> whatever the caller's own `search_path` happens to be. As a matter of course, **every `SECURITY DEFINER`
> procedure or function you ever write should carry an explicit `SET search_path`** — treat its absence as a
> security bug, not a style preference.

Full role/grant mechanics (`CREATE ROLE`, `GRANT`/`REVOKE`, row-level security) are Chapter 27's subject; this
section covers exactly the procedure-level security surface this chapter's scope requires.

---

## 19.19 Worked Example 11 of 11 — Complex Business Workflow: `process_loan_application`

This is the capstone of the progressive series: validation, multi-table eligibility logic, an `INSERT`, an
audit-log write via the `CALL`-based helper from §19.14, and `OUT` parameters reporting success or failure back
to the caller — without ever raising an exception for an ordinary "not eligible" outcome (a deliberate design
choice explained below).

**Business rules this procedure enforces**, chosen to be exercisable against the exact seed data:

1. `p_loan_amount` must be `> 0`, `p_interest_rate` must be `>= 0`, and `p_term_months` must be `> 0` (mirrors
   the table's own `CHECK` constraints, checked early for a friendlier message).
2. The customer must exist.
3. The customer must not already have **2 or more** loans with `status = 'ACTIVE'`.
4. The customer's total balance across their own `ACTIVE` accounts must be **at least 20%** of the requested
   loan amount (a simplified stand-in for a real underwriting rule, chosen so it's easy to hand-verify against
   the seed data).

```plpgsql
CREATE OR REPLACE PROCEDURE banking_db.process_loan_application(
    p_customer_id     INT,
    p_loan_amount     NUMERIC,
    p_interest_rate   NUMERIC,
    p_term_months     INT,
    OUT p_success     BOOLEAN,
    OUT p_message     TEXT,
    OUT p_loan_id     INT
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = banking_db, pg_temp
AS $$
DECLARE
    v_active_loan_count INT;
    v_total_balance     NUMERIC;
    v_required_balance  NUMERIC;
BEGIN
    p_success := FALSE;
    p_loan_id := NULL;

    -- 1. Basic field validation
    IF p_loan_amount <= 0 THEN
        p_message := format('Loan amount must be positive (got %s)', p_loan_amount);
        RETURN;
    END IF;

    IF p_interest_rate < 0 THEN
        p_message := format('Interest rate cannot be negative (got %s)', p_interest_rate);
        RETURN;
    END IF;

    IF p_term_months <= 0 THEN
        p_message := format('Term must be a positive number of months (got %s)', p_term_months);
        RETURN;
    END IF;

    -- 2. Customer must exist
    IF NOT EXISTS (SELECT 1 FROM banking_db.customers WHERE customer_id = p_customer_id) THEN
        p_message := format('Customer %s does not exist', p_customer_id);
        RETURN;
    END IF;

    -- 3. Existing active-loan count
    SELECT count(*) INTO v_active_loan_count
      FROM banking_db.loans
     WHERE customer_id = p_customer_id AND status = 'ACTIVE';

    IF v_active_loan_count >= 2 THEN
        p_message := format('Customer %s already has %s active loan(s); maximum is 2', p_customer_id, v_active_loan_count);
        CALL banking_db.sp_log_audit_event(
            'loans', 'INSERT', p_customer_id::TEXT,
            jsonb_build_object('rejected', TRUE, 'reason', 'too_many_active_loans', 'requested_amount', p_loan_amount)
        );
        RETURN;
    END IF;

    -- 4. Eligibility: total ACTIVE-account balance must be >= 20% of requested loan
    SELECT COALESCE(sum(balance), 0) INTO v_total_balance
      FROM banking_db.accounts
     WHERE customer_id = p_customer_id AND status = 'ACTIVE';

    v_required_balance := p_loan_amount * 0.20;

    IF v_total_balance < v_required_balance THEN
        p_message := format(
            'Customer %s is not eligible: total active balance %s is below the required %s (20%% of requested loan)',
            p_customer_id, v_total_balance, v_required_balance
        );
        CALL banking_db.sp_log_audit_event(
            'loans', 'INSERT', p_customer_id::TEXT,
            jsonb_build_object('rejected', TRUE, 'reason', 'insufficient_collateral_balance',
                                'total_balance', v_total_balance, 'required_balance', v_required_balance)
        );
        RETURN;
    END IF;

    -- All checks passed: insert the loan
    INSERT INTO banking_db.loans (customer_id, loan_amount, interest_rate, start_date, term_months, status)
    VALUES (p_customer_id, p_loan_amount, p_interest_rate, CURRENT_DATE, p_term_months, 'ACTIVE')
    RETURNING loan_id INTO p_loan_id;

    CALL banking_db.sp_log_audit_event(
        'loans', 'INSERT', p_loan_id::TEXT,
        jsonb_build_object('customer_id', p_customer_id, 'loan_amount', p_loan_amount,
                            'interest_rate', p_interest_rate, 'term_months', p_term_months)
    );

    p_success := TRUE;
    p_message := format('Loan %s approved for customer %s: amount %s at %s%% over %s months',
                         p_loan_id, p_customer_id, p_loan_amount, p_interest_rate, p_term_months);
END;
$$;
```

**Call 1 — Kavita (customer 4), requesting a loan too large for her balance:**

```sql
CALL banking_db.process_loan_application(4, 300000.00, 9.00, 36, NULL, NULL, NULL);
```

Customer 4 (Kavita) has one `ACTIVE` account (account 6, balance `20000.00`), so `v_total_balance = 20000.00`.
Required: `300000.00 * 0.20 = 60000.00`. Since `20000.00 < 60000.00`:

```
 p_success |                                              p_message                                               | p_loan_id
-----------+--------------------------------------------------------------------------------------------------------+-----------
 f         | Customer 4 is not eligible: total active balance 20000.00 is below the required 60000.00 (20% of requested loan) |
```

**Call 2 — Ravi (customer 1), requesting a loan he qualifies for:**

Customer 1 (Ravi) has two `ACTIVE` accounts: account 1 (`150000.00`) + account 2 (`50000.00`) =
`v_total_balance = 200000.00`. He already has 1 `ACTIVE` loan (loan 1), which is `< 2`, so the active-loan-count
check passes. Requesting `250000.00`: required is `250000.00 * 0.20 = 50000.00`, and `200000.00 >= 50000.00` —
eligible.

```sql
CALL banking_db.process_loan_application(1, 250000.00, 8.75, 48, NULL, NULL, NULL);
```

```
 p_success |                                       p_message                                        | p_loan_id
-----------+------------------------------------------------------------------------------------------+-----------
 t         | Loan 5 approved for customer 1: amount 250000.00 at 8.75% over 48 months                  |         5
```

(`loan_id = 5` follows the seed data's highest existing `loan_id` of `4`.)

**Line by line (highlighting what's new versus earlier examples):**

1. Three `OUT` parameters — `p_success BOOLEAN`, `p_message TEXT`, `p_loan_id INT` — give the caller a
   structured result *without ever raising an exception for a business-rule rejection*. This is a deliberate,
   important design decision: an "ineligible customer" is an **expected, ordinary outcome** of running this
   procedure, not an exceptional system failure — using `RAISE EXCEPTION` for it would force every caller to
   wrap every single call in `EXCEPTION`-handling machinery just to process a routine "declined" result, and
   would abort/roll back the transaction unnecessarily. Reserve `RAISE EXCEPTION` (as Examples 5, 8, and 9 do)
   for genuinely exceptional conditions — malformed input, a referenced row that should exist but doesn't, a
   constraint violation — and use `OUT` parameters for ordinary, expected business outcomes like "approved" vs.
   "declined."
2. `p_success := FALSE; p_loan_id := NULL;` at the very top — establishes safe defaults before any validation
   runs, so every early `RETURN;` below (guard clauses) automatically returns a consistent, correctly-shaped
   "failed" result rather than relying on each branch to remember to set every field.
3. Each validation/eligibility check follows the exact same shape: check the condition, and if it fails, set
   `p_message` (using `format()` for the same `%s`-style interpolation — note `format()`'s placeholder is `%s`
   for a plain value, distinct from `RAISE`'s `%`), optionally log to `audit_log` via `CALL
   sp_log_audit_event(...)` (reusing the helper from §19.14 — a second demonstration of "calling other
   procedures via `CALL`"), and `RETURN;` immediately — an early-exit guard-clause style used consistently
   through this entire chapter, on purpose, because it keeps each rule's logic visually separate and avoids deep
   nested `IF`s.
4. `SELECT count(*) INTO v_active_loan_count FROM loans WHERE customer_id = p_customer_id AND status =
   'ACTIVE';` — for customer 1 (Ravi), this returns `1` (loan 1); for customer 3 (Suresh), it would return `1`
   (loan 2) as well — no seed customer currently has 2, so this branch's rejection path can be exercised by
   calling the procedure twice in a row for the same customer within one session (the second call would see the
   freshly-inserted loan from the first call, if committed, or even within the same uncommitted transaction,
   since `SELECT` sees the session's own uncommitted writes).
5. `SELECT COALESCE(sum(balance), 0) INTO v_total_balance FROM accounts WHERE customer_id = p_customer_id AND
   status = 'ACTIVE';` — `COALESCE(..., 0)` is essential here: if a customer had *zero* `ACTIVE` accounts,
   `sum(balance)` over zero rows returns SQL `NULL`, not `0`, and the subsequent comparison `v_total_balance <
   v_required_balance` would evaluate to `NULL` (neither true nor false) rather than correctly rejecting the
   application — a classic three-valued-logic trap (Chapter 5) that would silently let an ineligible customer's
   application fall through unrejected if this `COALESCE` were omitted.
6. `INSERT INTO loans (...) VALUES (...) RETURNING loan_id INTO p_loan_id;` — identical `RETURNING ... INTO`
   pattern from Example 3, now producing the newly created loan's ID.
7. `CALL banking_db.sp_log_audit_event('loans', 'INSERT', p_loan_id::TEXT, jsonb_build_object(...));` — logs
   the successful approval too, not just rejections, giving `audit_log` a complete record of every application
   outcome.
8. No explicit `COMMIT` appears in this procedure. That is intentional: unlike the transfer procedures in
   §19.13–19.14 (which model an operation a caller wants atomically all-or-nothing and durable the instant the
   call returns), this procedure is written to let its caller decide the transaction boundary — perhaps a
   caller wants to `process_loan_application` for several customers in a batch and `COMMIT` once at the end, or
   perhaps wants to inspect `p_success` first and conditionally `ROLLBACK` the whole batch if too many were
   rejected. This is a legitimate, common alternative design to Example 8/9's "always commit internally"
   approach — decide per-procedure based on whether the *caller* or the *procedure* should own the transaction
   boundary, and document the choice clearly, since (per §19.13) both `CALL`ers assuming different ownership of
   the same transaction is a direct source of `invalid transaction termination` errors.

---

## 19.20 Procedure vs. Trigger

Chapter 22 covers triggers in full, but the comparison belongs here too, since "should this business rule be a
procedure or a trigger?" is a decision every one of this chapter's examples could, in principle, face.

| | Stored Procedure | Trigger |
|---|---|---|
| Invocation | Explicit — someone/something must `CALL` it | Implicit — fires automatically on `INSERT`/`UPDATE`/`DELETE` against its bound table |
| Caller awareness | The caller knows exactly what ran and when | Callers issuing a plain `UPDATE` may have no idea a trigger fired at all unless they inspect the schema |
| Can manage its own transaction (`COMMIT`/`ROLLBACK`)? | Yes (PG11+, top-level `CALL` only) | No — a trigger function always executes inside the transaction of the statement that fired it |
| Best fit | A deliberate, named business operation/workflow (a transfer, a loan application) that callers opt into by calling it | An invariant that must hold **no matter which code path** writes to the table (Chapter 22's audit-log example is the canonical case) |
| Risk if overused | Callers must remember to call it — logic can be bypassed by anyone issuing raw `INSERT`/`UPDATE` instead | Hidden, "spooky action at a distance" side effects that make a simple `UPDATE` mysteriously slow or cause unexpected cascading writes |

The `sp_transfer_funds_safe` design in §19.14 actually leans on both ideas at once in real systems: the
procedure is the sanctioned way to move money (this chapter), while a genuinely unbypassable guarantee — e.g.,
"every single `UPDATE` to `accounts.balance`, from *any* code path, gets an audit row" — is exactly the kind of
rule Chapter 22 argues should live in a trigger instead, precisely because a procedure can be skipped by a
caller who writes raw SQL, and a well-designed `AFTER UPDATE` trigger cannot.

---

## 19.21 Real-World Use Cases

- **Financial transfers and ledger postings** (this chapter's running example) — multi-step, must-be-atomic,
  must-be-auditable operations where every caller must be forced through identical validation.
- **Batch/ETL jobs** — nightly interest accrual across every account (§19.11's pattern, scaled up with internal
  `COMMIT`s every N rows per §19.13 to avoid one enormous long-running transaction).
- **Multi-step onboarding/application workflows** — Example 11's loan-application pattern generalizes directly
  to account opening with KYC checks, credit-card application approval, insurance underwriting.
- **Data migrations run once, by a DBA, with careful transaction control** — a procedure lets you script a
  migration with per-batch `COMMIT`s and structured error logging rather than a single giant `UPDATE`.
- **Privilege-gated operations** — using `SECURITY DEFINER` (§19.18) to let a narrowly-privileged application
  role perform a specific, audited, elevated action without ever being granted broad table privileges directly.
- **Generic administrative/reporting utilities** — Example 10's dynamic-SQL pattern, used for things like
  "vacuum every table in a schema" or "report row counts by status column across a family of similarly-shaped
  tables," where the specific object being acted on isn't known until call time.

---

## 19.22 Common Mistakes and Edge Cases — Chapter Summary

- Trying to `RETURN a_value;` from a procedure — illegal; only bare `RETURN;` (early exit, no value) is valid.
- Trying to `COMMIT`/`ROLLBACK` inside a function, or inside a procedure that isn't the top-level statement of
  its own transaction (§19.3, §19.13).
- Forgetting `IF NOT FOUND`/`INTO STRICT` checks after `SELECT INTO`, silently working with `NULL` variables
  instead of detecting a missing row.
- Forgetting to initialize accumulator variables, producing a silently `NULL` running total (§19.11).
- Doubling `%` as `%%` inside `RAISE` format strings when a literal percent sign is needed (§19.10).
- Concatenating raw values into dynamic SQL text instead of using `format()`'s `%I`/`%L` and `EXECUTE ...
  USING` (§19.15) — the single most dangerous mistake in this chapter's scope.
- Writing a `SECURITY DEFINER` procedure with no explicit `SET search_path`, opening a privilege-escalation
  hole (§19.18).
- Assuming an `EXCEPTION` block's rollback-to-savepoint also undoes a `COMMIT` that already happened earlier in
  the same call — it does not; once committed, a write is durable regardless of what happens afterward in the
  same procedure invocation (§19.14's audit-logging subtlety).
- Reaching for a row-by-row loop (§19.9/§19.11) when a single set-based `UPDATE`/`INSERT ... SELECT` would
  correctly and more efficiently express the same operation.
- Assuming `CREATE PROCEDURE` supports `RETURNS TABLE`/`SETOF` the way `CREATE FUNCTION` does — it does not
  (§19.17); reach for a function instead when that's genuinely what you need.

---

## 19.23 Practice Questions

1. Explain, in your own words, precisely *why* PostgreSQL forbids `COMMIT`/`ROLLBACK` inside a `FUNCTION` but
   allows it inside a `PROCEDURE`. Ground your answer in how each object type is invoked.
2. Write a procedure `sp_close_account(p_account_id INT)` that sets an account's `status` to `'CLOSED'` — but
   only if its `balance` is exactly `0`. If the balance is not zero, raise a clear exception instead. Test it
   against account 6 (`20000.00`, should fail) and think through what value would let it succeed.
3. Modify `sp_apply_monthly_interest_all_savings` (§19.11) so it only applies interest to accounts whose
   balance is at least `50000.00`. Hand-compute which of the four seed accounts would qualify and what the new
   total interest credited would be.
4. What is the difference between `RAISE NOTICE`, `RAISE WARNING`, and `RAISE EXCEPTION`, specifically in terms
   of whether execution continues afterward and whether the enclosing transaction is affected?
5. Rewrite the `sp_get_account_balance` `OUT`-parameter example (§19.6) as an `INOUT` parameter design instead,
   where the caller passes an account ID and the same parameter is reused to return the balance. Is this a good
   design here? Why or why not?
6. A colleague's procedure wraps every single statement in the body — including a single, simple `INSERT` with
   no foreign-key or check-constraint risk — in its own `BEGIN ... EXCEPTION WHEN OTHERS ... END;` block. What's
   the performance concern with this pattern, and when (if ever) would it be justified?
7. Using the `%TYPE` operator, declare a local variable in a new procedure that always matches the exact type
   of `loans.interest_rate`, and explain what happens to that variable's type automatically if a future migration
   changes the column's precision from `NUMERIC(5,2)` to `NUMERIC(6,3)`.
8. Trace `process_loan_application` (§19.19) by hand for customer 3 (Suresh Menon), requesting a loan amount of
   `100000.00` at `7.00%` interest over `24` months. State the exact `v_active_loan_count` and `v_total_balance`
   your trace computes, and the final `p_success`/`p_message` values.
9. Why can't a plain SQL `WHERE` clause parameterize a table name the way it parameterizes a value like
   `WHERE account_id = $1`? What PL/pgSQL mechanism, and which specific `format()` placeholder, solves this?
10. Explain the specific privilege-escalation risk that an *unset* `search_path` creates for a `SECURITY
    DEFINER` procedure, and write the one-line fix.
11. `sp_transfer_funds` (§19.13) locks the source account with `FOR UPDATE` but not the destination account.
    Research (or reason from Chapter 12's locking material) whether this could still leave the transfer exposed
    to a race condition, and if so, describe it.
12. Rewrite `sp_describe_account` (§19.8) to use a `CASE` **expression** instead of the `IF`/`ELSIF` chain,
    producing a single `v_description TEXT` variable that a single `RAISE NOTICE` then prints. What, if
    anything, is lost by making this change?

### Chapter-ending challenge

Extend `process_loan_application` (§19.19) with a **fourth eligibility rule**: the customer's requested
`p_interest_rate` must not be more than `2.00` percentage points *below* the average `interest_rate` currently
charged across all other `ACTIVE` loans in the table (a simplified "you can't request a rate we're not already
offering someone else" guard). Concretely:

1. Compute the average `interest_rate` across all currently `ACTIVE` loans (using the seed data *before* your
   new loan is inserted: loans 1, 2, and 3 — rates `8.50`, `7.75`, `9.25`).
2. If `p_interest_rate < (that average - 2.00)`, reject the application with a clear `p_message`, and log the
   rejection to `audit_log` via `sp_log_audit_event`, exactly like the existing rejection branches.
3. Make sure your new check runs *after* the existing three checks (so a customer who is already ineligible for
   another reason is rejected for that reason first, not this one) but *before* the `INSERT INTO loans`.
4. Hand-compute the average from the seed data, determine the resulting rejection threshold, and construct one
   `CALL` that would be rejected specifically by your new rule (and would otherwise have passed every existing
   check) and one that passes every check including the new one. Show both full `CALL` statements and their
   expected `OUT` parameter values.
5. As a bonus, consider: should this new average be computed with `INTO STRICT`? What happens to your
   procedure if, hypothetically, every loan in the table were `CLOSED` or `DEFAULTED` at call time (i.e., the
   average is computed over zero rows)? Handle that edge case explicitly rather than letting it fail silently.

---

## Key Takeaways

- A stored procedure is a named, callable, persistent unit of procedural + SQL logic living inside the
  database, invoked explicitly with `CALL` — never implicitly, unlike a trigger.
- The defining structural difference between a `PROCEDURE` and a `FUNCTION` is transaction control: a procedure
  invoked as a top-level `CALL` can `COMMIT`/`ROLLBACK` internally (PostgreSQL 11+); a function, always
  evaluated as part of a single enclosing statement, categorically cannot.
- Procedures vs. application code is a genuine engineering trade-off, not a right-vs-wrong choice — reach for a
  procedure specifically when every caller must be forced through identical, atomic, multi-step logic close to
  the data.
- `IN`/`OUT`/`INOUT` parameters, `DECLARE`/`:=`/`%TYPE` variables, `IF`/`ELSIF`/`CASE` branching, and
  `WHILE`/`LOOP`+`EXIT WHEN`/`FOR` (numeric and `FOR ... IN query`) loops form the complete procedural toolkit
  this chapter builds, and every one of them is reused unchanged in Chapters 20–22.
- `RAISE`'s severity levels (`NOTICE`/`WARNING`/`EXCEPTION`) and `BEGIN ... EXCEPTION ... END` blocks
  (with `SQLSTATE`/`SQLERRM` and custom `ERRCODE`s) give procedures structured, catchable error handling —
  remembering that a caught exception's implicit savepoint rollback does **not** undo an earlier `COMMIT` in the
  same call.
- Dynamic SQL (`EXECUTE`/`format()`/`USING`) is the only way to parameterize identifiers, and it is also the
  single largest injection-safety surface in this chapter — `%I` for identifiers, `USING`/parameter binding for
  values, never raw string concatenation.
- A procedure's only channels back to a caller are `OUT`/`INOUT` parameters (one row) or an `INOUT refcursor`
  (many rows, transaction-bound) — `RETURNS TABLE`/`SETOF` belong to functions only.
- `SECURITY DEFINER` grants controlled, elevated access through a single audited entry point, but is genuinely
  dangerous without an explicit `SET search_path` pinning name resolution against hijacking.
- All eleven progressive worked examples in this chapter — Hello World through `process_loan_application` —
  build on each other and on `banking_db`'s real seed data; you should be able to re-derive every expected
  output shown here by hand, not just by running it.

---

## What's Next

Chapter 20 turns to **Advanced Functions** — scalar, table-valued (`RETURNS TABLE`), and set-returning
(`RETURNS SETOF`) user-defined functions, PostgreSQL's volatility system (`IMMUTABLE`/`STABLE`/`VOLATILE`) and
why getting it wrong produces silently incorrect query results, function overloading, and `SECURITY DEFINER`
functions. Everything about PL/pgSQL syntax — variables, control flow, exception handling — carries over
unchanged; Chapter 20 assumes it and moves straight to what only a function, not a procedure, can do.
