# Chapter 22 — Triggers

> **Part VI — Database Internals & Production Engineering**
> Previous: [Chapter 21 — Cursors](21-cursors.md) · Next: [Chapter 23 — Dynamic SQL & Injection Safety](23-dynamic-sql.md)

This chapter runs against `company_db`, `ecommerce_db`, and `banking_db`. If you haven't loaded them yet:

```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
psql -f databases/banking_db.sql
```

---

## 22.0 What This Chapter Is Really About

Chapter 19 taught you to write stored procedures — reusable, explicitly *called* blocks of logic living in the database. Chapter 22 introduces something structurally different: code that runs **without being called at all**. You write it once, bind it to a table, and from that moment on, every matching `INSERT`, `UPDATE`, `DELETE` (or `TRUNCATE`) against that table silently invokes it — whether the write came from your application, a teammate's migration script, a bulk import, or a DBA poking around in `psql`.

`banking_db.sql` already ships with an `audit_log` table (`audit_id`, `table_name`, `operation`, `row_pk`, `changed_by`, `changed_at`, `old_data JSONB`, `new_data JSONB`) built specifically for this chapter — it has existed, unused, since Chapter 13. This is where it finally gets populated, automatically, by a trigger.

Triggers are one of the most powerful tools in this course, and also one of the most commonly misused. They let you guarantee invariants that hold no matter who writes to the table — but that same "no matter who" property is exactly what makes them dangerous when overused: a simple `UPDATE` can silently cascade into audit writes, history writes, and validation logic invisible at the call site. This chapter builds five complete, real worked examples against the course schemas, and then spends serious time on *why experienced engineers reach for triggers sparingly* — because that judgment is worth more than the syntax.

---

## 22.1 What Is a Trigger?

### Simple explanation
A trigger is code that automatically runs when something happens to a table — insert a row, and the trigger fires; update a row, and the trigger fires; delete a row, and the trigger fires. Nobody has to call it. It just happens.

### Technical explanation
A **trigger** is a database object bound to a table (or, for `INSTEAD OF` triggers, a view) that automatically executes a **trigger function** in response to a specified data-modification event — `INSERT`, `UPDATE`, `DELETE`, or `TRUNCATE` — on that table. The trigger itself is just a binding: *"when event X happens on table Y, run function Z."* All the actual logic lives in the function, not the trigger declaration.

### Why it exists
Some rules need to hold true regardless of *what* is writing to the table — not just your application's code path, but every code path, forever, including ones that don't exist yet. `CHECK` constraints (Chapter 13) can express row-local rules, but they cannot query other rows, other tables, or run arbitrary procedural logic. Triggers exist to fill exactly that gap: **enforcing or reacting to a rule that requires more than a pure, row-local boolean expression**, without asking every caller to remember to do it themselves.

---

## 22.2 Trigger Timing: BEFORE, AFTER, INSTEAD OF

| Timing | When it fires | Can it change the row? | Can it cancel the operation? | Typical use |
|---|---|---|---|---|
| `BEFORE` | Before the row is written to the table | Yes — modify `NEW` before it's stored | Yes — `RETURN NULL` cancels the operation for that row | Validation, defaulting/normalizing values, setting `updated_at` |
| `AFTER` | After the row has been written and is visible within the transaction | No — the write already happened | No — but raising an exception still rolls back the whole statement/transaction | Side effects: audit logging, denormalized aggregate maintenance, notifications |
| `INSTEAD OF` | Replaces the operation entirely — used only on **views** | N/A — you write whatever logic you want instead | Implicitly — if you don't perform the underlying write yourself, nothing happens | Making a non-updatable view (Chapter 15) accept `INSERT`/`UPDATE`/`DELETE` |

### BEFORE triggers — inspect, modify, or cancel

**[PostgreSQL row-level BEFORE]** A `BEFORE` row-level trigger function receives `NEW` (and `OLD`, for `UPDATE`/`DELETE`) *before* PostgreSQL commits that row to the table's storage. Whatever the function returns as `NEW` is what actually gets written — so a `BEFORE` trigger can silently rewrite values (Worked Example 2 sets `NEW.updated_at`), or it can cancel the write for that row entirely by returning `NULL`.

```sql
-- Skeleton: a BEFORE trigger that can veto the write
CREATE TRIGGER trg_example
BEFORE INSERT ON some_table
FOR EACH ROW
EXECUTE FUNCTION fn_example();
```
```plpgsql
CREATE OR REPLACE FUNCTION fn_example()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.some_column < 0 THEN
        RETURN NULL;  -- cancels this row's INSERT/UPDATE silently, no error raised
    END IF;
    RETURN NEW;       -- proceeds with (possibly modified) NEW
END;
$$ LANGUAGE plpgsql;
```

> **Important Note**
> Returning `NULL` from a `BEFORE` row-level trigger silently skips the operation for that row — **no error is raised**, and the caller has no idea anything was blocked unless you explicitly `RAISE EXCEPTION` instead. In almost every real validation scenario (see Worked Example 4), you want `RAISE EXCEPTION`, not a silent `RETURN NULL`, precisely so the caller finds out their write was rejected.

### AFTER triggers — side effects that shouldn't block or alter the write

An `AFTER` trigger fires once the row change has already been applied (within the same transaction — see §22.13). Its return value is essentially ignored for row-level `AFTER` triggers (by convention, `AFTER` trigger functions return `NEW` for `INSERT`/`UPDATE` or `OLD` for `DELETE`, but PostgreSQL does not act on it). This is the correct home for **side effects that should observe, not interfere with, the original operation** — audit logging is the textbook case: you never want an audit-log failure to silently change what got stored in `accounts`, only to record what happened (or, if the audit write itself fails, to roll back the whole transaction — see §22.13).

### INSTEAD OF triggers — making views updatable

Chapter 15 established that a view is only automatically updatable if it satisfies strict conditions: single base table, no aggregates, no `DISTINCT`, no `GROUP BY`, no set operations, and so on. A view joining two tables, or aggregating rows, fails those conditions — plain `INSERT`/`UPDATE`/`DELETE` against it raises an error. An `INSTEAD OF` trigger is PostgreSQL's answer: it intercepts the DML statement issued against the view and lets you write **arbitrary logic that does something else entirely** — typically, translating the view-level operation into one or more operations against the real base tables.

```sql
CREATE OR REPLACE VIEW ecommerce_db.v_order_summary AS
SELECT o.order_id, o.user_id, o.status, o.order_date, o.shipping_address,
       u.username, u.email
FROM ecommerce_db.orders o
JOIN ecommerce_db.users u ON u.user_id = o.user_id;
```

This view joins two tables, so it is **not** automatically updatable per Chapter 15's rules:

```sql
UPDATE ecommerce_db.v_order_summary SET status = 'SHIPPED' WHERE order_id = 9;
```
```
ERROR:  cannot update view "v_order_summary"
DETAIL:  Views that return columns from multiple relations are not automatically updatable.
HINT:  To enable updating the view, provide an INSTEAD OF UPDATE trigger or an unconditional ON UPDATE DO INSTEAD rule.
```

An `INSTEAD OF UPDATE` trigger fixes exactly this:

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.fn_v_order_summary_update()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE ecommerce_db.orders
       SET status           = NEW.status,
           shipping_address = NEW.shipping_address
     WHERE order_id = OLD.order_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_v_order_summary_instead_of_update
INSTEAD OF UPDATE ON ecommerce_db.v_order_summary
FOR EACH ROW
EXECUTE FUNCTION ecommerce_db.fn_v_order_summary_update();
```

Now the exact same statement PostgreSQL previously rejected succeeds — it never actually touches the view's storage (views have none); the trigger redirects the write into `orders`:

```sql
UPDATE ecommerce_db.v_order_summary SET status = 'SHIPPED' WHERE order_id = 9;
SELECT order_id, status FROM ecommerce_db.orders WHERE order_id = 9;
```
```
 order_id | status
----------+---------
        9 | SHIPPED
```

> **Important Note**
> `INSTEAD OF` triggers in PostgreSQL are **row-level only** — `FOR EACH ROW` is required, `FOR EACH STATEMENT` is not permitted for `INSTEAD OF`, and they can only be defined on **views**, never on ordinary tables.

---

## 22.3 Trigger Events: INSERT, UPDATE, DELETE, TRUNCATE

A single `CREATE TRIGGER` can fire on more than one event using `OR`:

```sql
CREATE TRIGGER trg_accounts_audit
AFTER INSERT OR UPDATE OR DELETE ON banking_db.accounts
FOR EACH ROW
EXECUTE FUNCTION banking_db.fn_accounts_audit();
```

`UPDATE` can additionally be scoped to specific columns — the trigger only fires when at least one of the listed columns is actually part of the `SET` clause (not merely unchanged in value, but *named* in the statement):

```sql
CREATE TRIGGER trg_accounts_balance_watch
AFTER UPDATE OF balance ON banking_db.accounts
FOR EACH ROW
EXECUTE FUNCTION banking_db.fn_balance_watch();
```

`TRUNCATE` is its own event, fundamentally different from `DELETE` (see §22.16 for why).

---

## 22.4 Row-Level vs Statement-Level Triggers

### The precise distinction
- **Row-level** (`FOR EACH ROW`) — the trigger function runs **once per affected row**. `OLD`/`NEW` refer to that single row. Ten rows updated in one `UPDATE` statement means ten separate firings.
- **Statement-level** (`FOR EACH STATEMENT`, the default if you omit the clause) — the trigger function runs **exactly once per statement**, regardless of whether the statement touched 0 rows or 10 million rows. `OLD`/`NEW` do **not** exist at statement level in the classic sense — there is no single row to refer to.

This distinction is easy to underestimate. A row-level `AFTER INSERT` trigger on a table that receives a 500,000-row bulk load fires 500,000 times — once per row, each one a full function invocation. A statement-level trigger on the same load fires once, total.

### Transition tables — set-based access to ALL changed rows **[PostgreSQL 10+]**

Before PostgreSQL 10, statement-level triggers had no way to see *which* rows were actually affected — you knew "an `UPDATE` happened" but not what changed. **Transition tables** solve this: a statement-level trigger can request `REFERENCING OLD TABLE AS ... NEW TABLE AS ...`, which exposes all the affected rows as if they were two ordinary (read-only, in-memory) tables you can `SELECT`, `JOIN`, and aggregate over — in one set-based operation, instead of one row at a time.

```plpgsql
CREATE OR REPLACE FUNCTION banking_db.fn_accounts_audit_statement()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO banking_db.audit_log (table_name, operation, row_pk, old_data, new_data)
    SELECT 'accounts', 'UPDATE', n.account_id::TEXT, to_jsonb(o), to_jsonb(n)
    FROM old_table o
    JOIN new_table n ON o.account_id = n.account_id;
    RETURN NULL;  -- return value ignored for AFTER STATEMENT triggers
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_accounts_audit_statement
AFTER UPDATE ON banking_db.accounts
REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
FOR EACH STATEMENT
EXECUTE FUNCTION banking_db.fn_accounts_audit_statement();
```

A single `UPDATE banking_db.accounts SET status = 'FROZEN' WHERE customer_id = 3;` (which touches two rows — accounts 4 and 5 both belong to Suresh Menon) fires this trigger **once**, and `old_table`/`new_table` each contain both changed rows inside that one invocation — a genuine set-based operation, done with a single `INSERT ... SELECT ... JOIN`, instead of two separate row-level trigger firings each doing its own single-row `INSERT`.

> **Important Note**
> This is a genuinely underused feature. Most engineers only ever reach for `FOR EACH ROW`, and pay a per-row function-call cost on every bulk operation as a result. When a trigger's logic is naturally set-based (audit logging, aggregate recomputation across a batch), a statement-level trigger with transition tables can be dramatically faster than the row-level equivalent on large batch operations — because it's one function call and one `INSERT ... SELECT`, not thousands of each.

---

## 22.5 Trigger Functions: the RETURNS TRIGGER Architecture

**[PostgreSQL]** Unlike MySQL, a PostgreSQL trigger does not contain logic directly. A trigger is only a *binding*: `CREATE TRIGGER` names an event, a table, a timing, and a **function** to call. All logic lives in a separate object — a function declared `RETURNS TRIGGER`, written in a procedural language (almost always PL/pgSQL, though any supported PL works).

```plpgsql
CREATE OR REPLACE FUNCTION schema_name.fn_name()
RETURNS TRIGGER AS $$
BEGIN
    -- trigger logic here, using OLD / NEW / TG_OP / TG_TABLE_NAME / etc.
    RETURN NEW;   -- or OLD, or NULL, depending on context — see §22.7 and §22.2
END;
$$ LANGUAGE plpgsql;
```

```sql
CREATE TRIGGER trigger_name
{BEFORE | AFTER | INSTEAD OF} {INSERT | UPDATE | DELETE | TRUNCATE}
ON schema_name.table_name
FOR EACH ROW
EXECUTE FUNCTION schema_name.fn_name();
```

A `RETURNS TRIGGER` function takes **no explicit arguments** in its signature (it can still receive fixed text arguments via `CREATE TRIGGER ... EXECUTE FUNCTION fn_name(arg1, arg2)`, retrievable inside via `TG_ARGV[]`) and returns the pseudo-type `TRIGGER`, which is only legal for functions bound to triggers — you cannot `SELECT fn_name()` directly.

### Special variables available inside a trigger function

| Variable | Meaning |
|---|---|
| `NEW` | The new row (`INSERT`/`UPDATE`) — a record matching the table's row type |
| `OLD` | The old row (`UPDATE`/`DELETE`) |
| `TG_OP` | Text: `'INSERT'`, `'UPDATE'`, `'DELETE'`, or `'TRUNCATE'` |
| `TG_TABLE_NAME` | Name of the table the trigger fired on |
| `TG_TABLE_SCHEMA` | Schema of that table |
| `TG_WHEN` | `'BEFORE'`, `'AFTER'`, or `'INSTEAD OF'` |
| `TG_LEVEL` | `'ROW'` or `'STATEMENT'` |
| `TG_NARGS` / `TG_ARGV[]` | Number and values of fixed arguments passed in `CREATE TRIGGER` |

`TG_OP` is what makes it possible for a single trigger function to correctly handle `INSERT`, `UPDATE`, and `DELETE` at once — exactly what Worked Example 1 does.

**Why this architecture exists:** separating the function from the binding lets one function be reused by multiple triggers (on different tables, or the same table under different conditions), lets the function be tested and version-controlled like any other database object, and matches PostgreSQL's general philosophy that "logic lives in functions; triggers, rules, and other objects merely invoke functions."

---

## 22.6 CREATE TRIGGER — Full Syntax Anatomy

```sql
CREATE [ OR REPLACE ] TRIGGER trigger_name
    { BEFORE | AFTER | INSTEAD OF } { event [ OR ... ] }
    ON table_name
    [ REFERENCING { { OLD | NEW } TABLE [ AS ] transition_name } [ ... ] ]
    [ FOR [ EACH ] { ROW | STATEMENT } ]
    [ WHEN ( condition ) ]
    EXECUTE { FUNCTION | PROCEDURE } function_name ( arguments )
```

| Clause | Meaning | Notes |
|---|---|---|
| `CREATE OR REPLACE TRIGGER` | Redefine an existing trigger without dropping it first | **[PostgreSQL 14+]**; earlier versions require `DROP TRIGGER ... ; CREATE TRIGGER ...` |
| `{BEFORE\|AFTER\|INSTEAD OF}` | Timing — see §22.2 | `INSTEAD OF` only valid on views |
| `event` | `INSERT`, `UPDATE [OF column, ...]`, `DELETE`, `TRUNCATE` — combine with `OR` | `TRUNCATE` only fires statement-level triggers, never row-level (§22.16) |
| `ON table_name` | The table or view the trigger is bound to | |
| `REFERENCING ... TABLE` | Names transition tables for statement-level triggers | **[PostgreSQL 10+]**, statement-level only, `AFTER` triggers only |
| `FOR EACH {ROW\|STATEMENT}` | Row-level vs statement-level — see §22.4 | Defaults to `STATEMENT` if omitted |
| `WHEN (condition)` | Only fire the trigger when this boolean expression (can reference `OLD`/`NEW` for row-level) is true | Evaluated *before* the function call — cheaper than checking inside the function body every time |
| `EXECUTE FUNCTION` | The function to invoke | **[PostgreSQL 11+]**; `EXECUTE PROCEDURE` is the pre-11 spelling, still accepted as a legacy alias, but means the same thing here (nothing to do with `CREATE PROCEDURE`) |

A `WHEN` clause example — only recompute `updated_at`-style bookkeeping if something actually changed, not on every no-op `UPDATE`:

```sql
CREATE TRIGGER trg_employees_set_updated_at
BEFORE UPDATE ON company_db.employees
FOR EACH ROW
WHEN (OLD.* IS DISTINCT FROM NEW.*)
EXECUTE FUNCTION company_db.fn_set_updated_at();
```

---

## 22.7 OLD and NEW: Availability by Operation

| Operation | `OLD` available? | `NEW` available? |
|---|---|---|
| `INSERT` | No | Yes — the row being inserted |
| `UPDATE` | Yes — the row's prior values | Yes — the row's incoming values |
| `DELETE` | Yes — the row being removed | No |
| `TRUNCATE` | No (statement-level only; no per-row `OLD`/`NEW` at all) | No |

Referencing `OLD` in an `INSERT`-only trigger, or `NEW` in a `DELETE`-only trigger, raises a runtime error the first time the function executes — this is why Worked Example 1's function branches on `TG_OP` before touching either.

---

## 22.8 Worked Example 1 — Audit Logging

**Goal:** every `INSERT`, `UPDATE`, and `DELETE` on `banking_db.accounts` writes a full old/new snapshot into the pre-existing `banking_db.audit_log` table, as JSONB.

```plpgsql
CREATE OR REPLACE FUNCTION banking_db.fn_accounts_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO banking_db.audit_log (table_name, operation, row_pk, old_data, new_data)
        VALUES ('accounts', 'INSERT', NEW.account_id::TEXT, NULL, to_jsonb(NEW));
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO banking_db.audit_log (table_name, operation, row_pk, old_data, new_data)
        VALUES ('accounts', 'UPDATE', NEW.account_id::TEXT, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO banking_db.audit_log (table_name, operation, row_pk, old_data, new_data)
        VALUES ('accounts', 'DELETE', OLD.account_id::TEXT, to_jsonb(OLD), NULL);
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_accounts_audit
AFTER INSERT OR UPDATE OR DELETE ON banking_db.accounts
FOR EACH ROW
EXECUTE FUNCTION banking_db.fn_accounts_audit();
```

### Line-by-line
- `IF TG_OP = 'INSERT' THEN ... to_jsonb(NEW)` — on `INSERT`, `OLD` doesn't exist (§22.7), so `old_data` is explicitly `NULL` and `new_data` captures the entire freshly-inserted row as JSONB in one call: `to_jsonb(NEW)` serializes *every column* of the row automatically — you never have to name columns individually, and the audit trigger keeps working even if `accounts` later gains new columns.
- `ELSIF TG_OP = 'UPDATE' THEN ... to_jsonb(OLD), to_jsonb(NEW)` — both pseudo-records exist for `UPDATE`, so both snapshots are captured, giving a complete before/after diff.
- `ELSIF TG_OP = 'DELETE' THEN ... to_jsonb(OLD), NULL` — `NEW` doesn't exist on `DELETE`, so `new_data` is `NULL` and only the row's last-known state (`OLD`) is preserved — this is often the *only* surviving record of a deleted row's contents.
- `row_pk` is always cast `::TEXT` — `audit_log.row_pk` is declared `TEXT` specifically so one audit table can serve *any* source table regardless of that table's primary key type (integer, UUID, composite string, etc.).
- `RETURN NEW` / `RETURN OLD` — for `AFTER` row-level triggers PostgreSQL ignores the return value entirely, but returning the conventional value (`NEW` for `INSERT`/`UPDATE`, `OLD` for `DELETE`) is the idiomatic, self-documenting style, and matters if the same function is ever reused on a `BEFORE` trigger.

### Demonstration

```sql
-- 1. INSERT a new account for Neha Agarwal (customer_id 2)
INSERT INTO banking_db.accounts (customer_id, account_type, balance, opened_date, status)
VALUES (2, 'SAVINGS', 25000.00, '2024-03-01', 'ACTIVE');
-- account_id = 8 (sequence was last set to 7)

-- 2. UPDATE that account's balance... actually, update an existing one:
UPDATE banking_db.accounts SET balance = balance + 5000 WHERE account_id = 3;

-- 3. DELETE the account created in step 1
DELETE FROM banking_db.accounts WHERE account_id = 8;
```

`audit_log` now contains (abbreviated for readability):

| audit_id | table_name | operation | row_pk | old_data | new_data |
|---|---|---|---|---|---|
| 1 | accounts | INSERT | 8 | *(null)* | `{"account_id":8,"customer_id":2,"account_type":"SAVINGS","balance":25000.00,"opened_date":"2024-03-01","status":"ACTIVE"}` |
| 2 | accounts | UPDATE | 3 | `{"account_id":3,...,"balance":80000.00,...}` | `{"account_id":3,...,"balance":85000.00,...}` |
| 3 | accounts | DELETE | 8 | `{"account_id":8,...,"balance":25000.00,...}` | *(null)* |

Every column that changed (or existed at all, for insert/delete) is fully captured — no manual column-by-column bookkeeping was needed anywhere in the trigger.

---

## 22.9 Worked Example 2 — Automatic updated_at Timestamps

**Goal:** guarantee `company_db.employees` always reflects when a row was last modified, regardless of which client performed the update.

```sql
ALTER TABLE company_db.employees
    ADD COLUMN updated_at TIMESTAMP NOT NULL DEFAULT now();
```

```plpgsql
CREATE OR REPLACE FUNCTION company_db.fn_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_employees_set_updated_at
BEFORE UPDATE ON company_db.employees
FOR EACH ROW
EXECUTE FUNCTION company_db.fn_set_updated_at();
```

### Why a trigger, not "remembering to set it in application code"
The tempting alternative is: `UPDATE employees SET job_title = 'Staff Engineer', updated_at = now() WHERE employee_id = 4;` in application code. This works — **until it doesn't**. Every single code path that ever updates `employees` — the main API, an internal admin tool, a one-off data-fix script, a future engineer's bulk migration, a direct `psql` session during an incident — has to remember to append `updated_at = now()` every single time. Miss it once, anywhere, and that row's `updated_at` silently lies. A `BEFORE UPDATE` trigger makes this **structurally impossible to forget**: `NEW.updated_at := now()` runs on *every* `UPDATE` to this table, unconditionally, no matter what wrote it. This is one of the single most common trigger patterns in production applications for exactly this reason.

### Demonstration

```sql
UPDATE company_db.employees SET job_title = 'Staff Engineer' WHERE employee_id = 4;
SELECT employee_id, job_title, updated_at FROM company_db.employees WHERE employee_id = 4;
```
```
 employee_id |   job_title    |         updated_at
-------------+----------------+----------------------------
           4 | Staff Engineer | 2026-09-24 10:15:32.881204
```

Notice the statement never mentioned `updated_at` at all — it was overwritten by the trigger before the row was ever written to disk. Even `UPDATE company_db.employees SET updated_at = '2000-01-01' WHERE employee_id = 4;` would **not** succeed in setting that value — the `BEFORE` trigger runs after the `SET` clause is evaluated but before the row is stored, overwriting whatever the caller supplied.

---

## 22.10 Worked Example 3 — Maintaining a History Table

**Goal:** every time a `company_db.salaries` row is updated, preserve the *prior* value in a shadow history table before the update is allowed — a foundational pattern for temporal / slowly-changing data, which Chapter 31 (Advanced Patterns) revisits formally under Slowly Changing Dimensions (SCD).

```sql
CREATE TABLE company_db.salaries_history (
    history_id      BIGSERIAL PRIMARY KEY,
    salary_id       INT NOT NULL,
    employee_id     INT NOT NULL,
    base_salary     NUMERIC(10,2) NOT NULL,
    bonus           NUMERIC(10,2) NOT NULL,
    currency        CHAR(3) NOT NULL,
    effective_date  DATE NOT NULL,
    archived_at     TIMESTAMP NOT NULL DEFAULT now()
);
```

```plpgsql
CREATE OR REPLACE FUNCTION company_db.fn_salaries_archive()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO company_db.salaries_history
        (salary_id, employee_id, base_salary, bonus, currency, effective_date)
    VALUES
        (OLD.salary_id, OLD.employee_id, OLD.base_salary, OLD.bonus, OLD.currency, OLD.effective_date);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_salaries_archive_before_update
BEFORE UPDATE ON company_db.salaries
FOR EACH ROW
EXECUTE FUNCTION company_db.fn_salaries_archive();
```

### Line-by-line
- The trigger is `BEFORE UPDATE`, but it doesn't modify `NEW` at all — it uses the "before" timing purely to guarantee the archive write happens as part of the *same* atomic operation as the update, inside the same transaction (see §22.13): if the archive `INSERT` fails for any reason, the whole `UPDATE` rolls back too, so you can never end up with a salary changed but *not* archived.
- Only `OLD` is referenced — the row's values *before* this update — which is precisely the snapshot worth preserving; `NEW` will become the new "current" row in `salaries` itself, so there's no need to also copy it into history.

### Demonstration

Sneha Kulkarni (`employee_id = 3`) has a current salary row (`salary_id = 6`): `base_salary = 210000.00`, `bonus = 25000.00`, `effective_date = '2022-01-01'`. She receives a raise:

```sql
UPDATE company_db.salaries
   SET base_salary = 230000.00, bonus = 45000.00
 WHERE employee_id = 3 AND effective_date = '2022-01-01';
```

`salaries_history` now contains:

| history_id | salary_id | employee_id | base_salary | bonus | currency | effective_date | archived_at |
|---|---|---|---|---|---|---|---|
| 1 | 6 | 3 | 210000.00 | 25000.00 | USD | 2022-01-01 | 2026-09-24 10:20:11 |

...while `company_db.salaries` itself now shows the *new* figures for that row — the old value is never lost, it just moved to the history table automatically, with zero extra application logic.

> **Foreshadowing — Chapter 31**
> This pattern — "archive the old row before overwriting it" — is a manual, hand-rolled version of what's formally called a **Type 2 Slowly Changing Dimension**: instead of overwriting history, every change becomes a new, timestamped row, and nothing is ever truly lost. Chapter 31 builds this out fully, including effective-dating (`valid_from`/`valid_to`) and querying "what was true as of date X."

---

## 22.11 Worked Example 4 — Validation Beyond What CHECK Can Express

**Goal:** enforce a business rule that requires looking at *other rows*, which a `CHECK` constraint — by design, row-local only, no subqueries (Chapter 13, §13.5.9) — simply cannot do: no single `banking_db.accounts` withdrawal-type transaction should push that account's total withdrawals/transfers-out **for the current calendar day** above ₹50,000.

```plpgsql
CREATE OR REPLACE FUNCTION banking_db.fn_enforce_daily_withdrawal_limit()
RETURNS TRIGGER AS $$
DECLARE
    v_daily_limit       NUMERIC(14,2) := 50000.00;
    v_already_withdrawn NUMERIC(14,2);
BEGIN
    IF NEW.transaction_type IN ('WITHDRAWAL', 'TRANSFER_OUT') THEN
        SELECT COALESCE(SUM(amount), 0)
          INTO v_already_withdrawn
          FROM banking_db.transactions
         WHERE account_id = NEW.account_id
           AND transaction_type IN ('WITHDRAWAL', 'TRANSFER_OUT')
           AND transaction_date::date = NEW.transaction_date::date;

        IF v_already_withdrawn + NEW.amount > v_daily_limit THEN
            RAISE EXCEPTION
                'Daily withdrawal limit of % exceeded for account %: already withdrawn % today, attempted additional %',
                v_daily_limit, NEW.account_id, v_already_withdrawn, NEW.amount;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_transactions_daily_limit
BEFORE INSERT ON banking_db.transactions
FOR EACH ROW
EXECUTE FUNCTION banking_db.fn_enforce_daily_withdrawal_limit();
```

### Why this cannot be a CHECK constraint
`CHECK` evaluates a boolean expression against **only the columns of the row currently being written** — it has no ability to run a `SELECT` against other rows of the same table (or any other table). "Is the sum of *other* rows plus this one over a limit" is inherently a cross-row aggregate question, which places it firmly outside `CHECK`'s row-local, subquery-free design (Chapter 13, §13.12) and squarely inside trigger territory.

### Demonstration

The seed data already has account 4 (Suresh Menon's savings account) withdrawing ₹25,000 on `2024-01-20`. A second same-day withdrawal that would push the day's total past ₹50,000:

```sql
INSERT INTO banking_db.transactions (account_id, transaction_type, amount, transaction_date, description)
VALUES (4, 'WITHDRAWAL', 30000.00, '2024-01-20 16:00', 'Second withdrawal same day');
```
```
ERROR:  Daily withdrawal limit of 50000.00 exceeded for account 4: already withdrawn 25000.00 today, attempted additional 30000.00
CONTEXT:  PL/pgSQL function banking_db.fn_enforce_daily_withdrawal_limit() line 11 at RAISE
```

A same-day withdrawal that stays within the limit (₹25,000 already + ₹20,000 more = ₹45,000, under ₹50,000) succeeds normally:

```sql
INSERT INTO banking_db.transactions (account_id, transaction_type, amount, transaction_date, description)
VALUES (4, 'WITHDRAWAL', 20000.00, '2024-01-20 17:00', 'Second withdrawal, within limit');
-- INSERT 0 1
```

---

## 22.12 Worked Example 5 — Automatic Calculation of a Denormalized Aggregate

**Goal:** keep `ecommerce_db.orders.total_amount` continuously in sync with the sum of its `order_items`, without any application code ever computing or writing that total itself — directly extending the denormalization trade-off discussion from Chapter 14 (store a derived value redundantly, in exchange for cheap reads, and accept the obligation to keep it consistent).

```sql
ALTER TABLE ecommerce_db.orders
    ADD COLUMN total_amount NUMERIC(12,2) NOT NULL DEFAULT 0;

-- backfill existing orders once, before the trigger takes over going forward
UPDATE ecommerce_db.orders o
   SET total_amount = COALESCE(sub.total, 0)
  FROM (SELECT order_id, SUM(quantity * unit_price) AS total
          FROM ecommerce_db.order_items GROUP BY order_id) sub
 WHERE o.order_id = sub.order_id;
```

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.fn_recalc_order_total()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        UPDATE ecommerce_db.orders
           SET total_amount = COALESCE(
               (SELECT SUM(quantity * unit_price) FROM ecommerce_db.order_items WHERE order_id = OLD.order_id), 0)
         WHERE order_id = OLD.order_id;
        RETURN OLD;
    ELSE
        UPDATE ecommerce_db.orders
           SET total_amount = COALESCE(
               (SELECT SUM(quantity * unit_price) FROM ecommerce_db.order_items WHERE order_id = NEW.order_id), 0)
         WHERE order_id = NEW.order_id;

        -- an UPDATE could, in principle, move a line item to a different order_id;
        -- recompute the OLD order's total too in that case
        IF TG_OP = 'UPDATE' AND OLD.order_id <> NEW.order_id THEN
            UPDATE ecommerce_db.orders
               SET total_amount = COALESCE(
                   (SELECT SUM(quantity * unit_price) FROM ecommerce_db.order_items WHERE order_id = OLD.order_id), 0)
             WHERE order_id = OLD.order_id;
        END IF;
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_order_items_recalc_total
AFTER INSERT OR UPDATE OR DELETE ON ecommerce_db.order_items
FOR EACH ROW
EXECUTE FUNCTION ecommerce_db.fn_recalc_order_total();
```

### Line-by-line
- The function **recomputes the full sum from scratch** on every firing (`SELECT SUM(...) WHERE order_id = ...`), rather than incrementing/decrementing `total_amount` by the changed row's delta. This is deliberately more robust: an increment-based approach (`total_amount = total_amount + NEW.quantity*NEW.unit_price`) would drift permanently out of sync if any single event were ever missed (e.g., a bulk load with the trigger temporarily disabled — see §22.16) or double-counted; a full recompute is always self-correcting.
- The `TG_OP = 'UPDATE' AND OLD.order_id <> NEW.order_id` branch handles a genuinely easy-to-miss edge case: `UPDATE` gives you both `OLD` and `NEW`, and nothing stops a caller from changing `order_id` itself, effectively moving a line item between orders. Both the old and new parent orders' totals need recomputing in that case.

### Demonstration

Order 1 already has two line items in the seed data — `(product 1, qty 1, ₹45,999.00)` and `(product 9, qty 1, ₹3,499.00)` — summing to `₹49,498.00`, which matches `payments.amount` for order 1 exactly (`49498.00`), confirming the backfill above is correct. Now add a line item to order 7 (currently just one item, `product 9, qty 2, ₹3,499.00` = `₹6,998.00`):

```sql
INSERT INTO ecommerce_db.order_items (order_id, product_id, quantity, unit_price)
VALUES (7, 5, 1, 1299.00);

SELECT order_id, total_amount FROM ecommerce_db.orders WHERE order_id = 7;
```
```
 order_id | total_amount
----------+--------------
        7 |      8297.00
```

`total_amount` updated automatically — `6998.00 + 1299.00 = 8297.00` — without a single line of application code recomputing anything.

### A concurrency caveat worth naming explicitly
Because the recompute is a full `SELECT SUM(...)`, two concurrent transactions inserting different line items into the *same* order and racing to update `orders.total_amount` are still serialized correctly by PostgreSQL's row-level locking on the `orders` row itself (the second `UPDATE` blocks until the first commits, then recomputes from the now-current state) — this particular pattern is safe under ordinary `READ COMMITTED`. Contrast this with Chapter 12's warning about increment-style updates and lost updates: a recompute-from-source trigger like this one is structurally safer than a "read current total, add delta, write back" pattern would be.

### Bonus example — preventing inventory oversell

`ecommerce_db.inventory.quantity_on_hand` already carries `CHECK (quantity_on_hand >= 0)` (Chapter 13) — so a trigger that merely re-checks "is it negative" would be redundant. What `CHECK` (and a naive trigger) genuinely **cannot** solve on their own is the classic *oversell race*: application code reads `quantity_on_hand`, decides in its own logic that enough stock exists, and only then issues the decrementing `UPDATE` — with no lock held between the read and the write. Two concurrent checkouts can both read "5 in stock, order for 5 is fine," both pass their own in-application check, and both proceed, because neither transaction's read blocked the other's.

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.fn_prevent_oversell()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity_on_hand < 0 THEN
        RAISE EXCEPTION 'Oversell detected: product % at % would go to % units',
            NEW.product_id, NEW.warehouse_location, NEW.quantity_on_hand;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_inventory_no_oversell
BEFORE UPDATE ON ecommerce_db.inventory
FOR EACH ROW
EXECUTE FUNCTION ecommerce_db.fn_prevent_oversell();
```

This trigger *will* correctly reject any single `UPDATE` statement that computes a negative value directly (`UPDATE inventory SET quantity_on_hand = quantity_on_hand - 5 ...`, because PostgreSQL's row-level lock forces the second of two concurrent such `UPDATE`s to wait for the first to commit and then recompute from the *already-decremented* value — this specific pattern is actually safe by default). The failure mode this trigger does **not** protect against is the check-then-act race described above, where the application reads the quantity in a separate, earlier statement with no lock held. **Cross-reference Chapter 12:** solving that race requires `SELECT quantity_on_hand FROM inventory WHERE product_id = ... FOR UPDATE` to explicitly lock the row before deciding whether to proceed — a trigger alone, no matter how carefully written, cannot substitute for taking that lock at the right point in the application's transaction.

---

## 22.13 Internal Behavior: Triggers and Transactions

A trigger's execution is part of the very same statement (and the very same transaction) that fired it — not a separate, detached operation. This has two precise, load-bearing consequences:

1. **If a trigger raises an exception, the entire statement (and, absent a `SAVEPOINT`, the entire transaction) rolls back** — including the original `INSERT`/`UPDATE`/`DELETE` that fired the trigger in the first place. In Worked Example 4, when the daily-limit trigger raises an exception, the `INSERT` into `transactions` that triggered it is rolled back too — the offending transaction row never exists, even transiently.
2. **A trigger's own writes (e.g., the `INSERT INTO audit_log` in Worked Example 1) are visible within the same transaction**, and are committed or rolled back atomically together with everything else in that transaction. There is no scenario where `accounts.balance` changes but `audit_log` does not, or vice versa, as long as both live in the same trigger-driven transaction — this atomicity is precisely *why* triggers are the standard tool for audit logging, not an optional nice-to-have.

```sql
BEGIN;
UPDATE banking_db.accounts SET balance = balance - 1000000 WHERE account_id = 6;
-- balance CHECK (balance >= 0) fails here -> statement rolls back
-- ...and so does the audit_log INSERT the AFTER trigger had already performed
ROLLBACK;
```

---

## 22.14 Trigger Execution Order

**[PostgreSQL]** When multiple triggers of the *same timing and event* exist on the same table, PostgreSQL fires them in **alphabetical order by trigger name** — not creation order, not any declared priority. This is a real, frequently-missed gotcha:

```sql
CREATE TRIGGER trg_accounts_zzz_notify   AFTER UPDATE ON banking_db.accounts FOR EACH ROW EXECUTE FUNCTION fn_notify();
CREATE TRIGGER trg_accounts_audit        AFTER UPDATE ON banking_db.accounts FOR EACH ROW EXECUTE FUNCTION fn_accounts_audit();
```

Even though `trg_accounts_zzz_notify` was created *first*, `trg_accounts_audit` fires *before* it on every matching `UPDATE`, purely because `"trg_accounts_audit"` sorts before `"trg_accounts_zzz_notify"` alphabetically.

> **Important Note**
> If execution order among several triggers on the same table/event genuinely matters, do not rely on creation order — **name your triggers with an explicit ordering prefix** (`trg_01_validate`, `trg_02_audit`, `trg_03_notify`), or better, consolidate the logic into a single trigger function so ordering is controlled by your own code, not by string sort order.

`BEFORE` triggers (in their alphabetical order) always run before the actual row modification, which always runs before `AFTER` triggers (in their alphabetical order) — that outer ordering (`BEFORE` → write → `AFTER`) is fixed; only the ordering *within* a timing group is name-dependent.

---

## 22.15 Common Mistakes

### Infinite trigger recursion

An `AFTER UPDATE` trigger that itself issues an `UPDATE` on the *same table*, with no guard, re-fires itself:

```plpgsql
-- DO NOT DO THIS
CREATE OR REPLACE FUNCTION company_db.fn_bad_recursive_trigger()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE company_db.employees SET updated_at = now() WHERE employee_id = NEW.employee_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_bad_recursive
AFTER UPDATE ON company_db.employees
FOR EACH ROW
EXECUTE FUNCTION company_db.fn_bad_recursive_trigger();
```

Every `UPDATE` on `employees` fires this trigger, which issues *another* `UPDATE` on `employees`, which fires the trigger again, forever — until PostgreSQL hits its internal call-stack limit:

```
ERROR:  stack depth limit exceeded
HINT:  Increase the configuration parameter "max_stack_depth"...
```

> **⚠️ Warning — Infinite recursion and hidden control flow**
> This is the single most dangerous trigger mistake in this chapter, and it is deceptively easy to write by accident: any `AFTER` trigger that performs a fresh `UPDATE`/`INSERT`/`DELETE` against the *same table it's attached to*, with no guard, risks firing itself indefinitely. Contrast this with Worked Example 2's correct pattern — a `BEFORE` trigger that modifies `NEW.updated_at` directly, in place, **never issues a second statement at all**, so there is nothing for it to recursively re-trigger. Prefer modifying `NEW` in a `BEFORE` trigger over issuing a fresh statement in an `AFTER` trigger whenever the goal is "change a column on the row currently being written."

Two ways to guard against genuine cases where a fresh statement against the same table is unavoidable:

**`pg_trigger_depth()`** — returns how many trigger levels deep the current execution already is (`0` outside any trigger):

```plpgsql
BEGIN
    IF pg_trigger_depth() < 1 THEN
        UPDATE company_db.employees SET updated_at = now() WHERE employee_id = NEW.employee_id;
    END IF;
    RETURN NEW;
END;
```

**A `WHEN` guard at the trigger definition** — cheaper, since it's checked before the function is even invoked:

```sql
CREATE TRIGGER trg_bad_recursive
AFTER UPDATE ON company_db.employees
FOR EACH ROW
WHEN (pg_trigger_depth() = 0)
EXECUTE FUNCTION company_db.fn_bad_recursive_trigger();
```

### Other common mistakes
- **Forgetting `RETURN NEW`/`RETURN OLD` in a `BEFORE` trigger.** A `BEFORE` row-level trigger function that returns `NULL` (or forgets a `RETURN` entirely, which is equivalent) silently **cancels the write** — this is the intended mechanism for a deliberate veto, but an accidental omission looks identical to "the row silently vanished," with no error to explain why.
- **Assuming `CHECK`-style rejection.** Unlike a `CHECK` constraint's automatic, standard error message, a trigger that wants to reject a write **must explicitly `RAISE EXCEPTION`** — simply detecting a problem and doing nothing about it (or `RETURN NULL`-ing silently) does not communicate failure to the caller the way a constraint violation does.
- **Writing `to_jsonb(NEW)` inside a `DELETE`-only branch, or `to_jsonb(OLD)` inside an `INSERT`-only branch** — both raise a runtime error, since the referenced pseudo-record simply does not exist for that operation (§22.7).

---

## 22.16 Edge Cases

### TRUNCATE does not fire row-level triggers
`TRUNCATE` (Chapter 3) does not process rows individually at all — it deallocates the table's storage pages wholesale, which is exactly why it's so much faster than `DELETE` for clearing an entire table. Because there is no per-row processing, **row-level triggers (`FOR EACH ROW`) never fire on `TRUNCATE`, under any circumstances** — only `TRUNCATE`-specific **statement-level** triggers can observe it:

```sql
TRUNCATE TABLE ecommerce_db.order_items;
-- trg_order_items_recalc_total (FOR EACH ROW) does NOT fire here at all
-- orders.total_amount values are now silently stale/wrong for every order
```

The fix is a dedicated statement-level `AFTER TRUNCATE` trigger:

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.fn_reset_totals_on_truncate()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE ecommerce_db.orders SET total_amount = 0;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
```
```sql
CREATE TRIGGER trg_order_items_truncate_reset
AFTER TRUNCATE ON ecommerce_db.order_items
FOR EACH STATEMENT
EXECUTE FUNCTION ecommerce_db.fn_reset_totals_on_truncate();
```

> **⚠️ Warning**
> Anyone maintaining a denormalized aggregate via a row-level trigger must remember this gap explicitly. If `order_items` can ever legitimately be truncated (bulk reload scenarios, test fixtures), the row-level maintenance trigger alone is **not** sufficient — a statement-level `TRUNCATE` trigger (or a documented manual recompute step) is required too.

### Bulk operations fire row-level triggers once per row
A `COPY` or a multi-row `INSERT ... SELECT` of 200,000 rows into `order_items` fires a `FOR EACH ROW` trigger 200,000 times — each one its own full function invocation, each one (in Worked Example 5's case) running its own `SELECT SUM(...)` and `UPDATE orders`. This can turn a bulk load that should take seconds into one that takes minutes or hours.

The standard real-world workaround is to **temporarily disable the trigger during a bulk load**, perform the load, then recompute the aggregate in one set-based statement, then re-enable:

```sql
ALTER TABLE ecommerce_db.order_items DISABLE TRIGGER trg_order_items_recalc_total;

-- ... bulk COPY / INSERT here, at full speed, no per-row trigger overhead ...

UPDATE ecommerce_db.orders o
   SET total_amount = COALESCE(sub.total, 0)
  FROM (SELECT order_id, SUM(quantity * unit_price) AS total
          FROM ecommerce_db.order_items GROUP BY order_id) sub
 WHERE o.order_id = sub.order_id;

ALTER TABLE ecommerce_db.order_items ENABLE TRIGGER trg_order_items_recalc_total;
```

---

## 22.17 Why Triggers Become Dangerous and Hard to Maintain

This is the section worth reading twice. Triggers are powerful precisely because they're invisible — and that invisibility is a genuine, recurring source of production incidents.

> **⚠️ Warning — Hidden control flow ("spooky action at a distance")**
> A plain-looking statement:
> ```sql
> UPDATE banking_db.accounts SET balance = balance - 500 WHERE account_id = 3;
> ```
> ...gives no hint, at the call site, that it also: writes a row to `audit_log` (Example 1), potentially recomputes something else entirely if other triggers exist, and could be silently rejected or rewritten by a `BEFORE` trigger before it even lands. An engineer reading this line of application code — or debugging a production incident at 2 a.m. — has no way to know any of that happened without separately knowing to check `\d+ accounts` for attached triggers. This is the core reason triggers earn a reputation for being dangerous: **the code that actually runs is not the code you're looking at.**

- **Debugging difficulty.** An exception raised deep inside a trigger function surfaces as an error on the *original* statement — a developer investigating "why does inserting a transaction sometimes fail?" may spend a long time before discovering the real cause lives in a trigger function three files (and one `\df` lookup) away from the `INSERT` they're staring at.
- **Performance overhead on every row, forever.** A trigger with a slow query inside it (an unindexed `SELECT SUM(...)`, for instance) doesn't just slow down one query once — it silently slows down **every single future `INSERT`/`UPDATE`** against that table, for as long as the trigger exists, often invisibly, because nobody profiles "why did this simple insert take 40ms" until it's already a widespread problem.
- **Execution order gotchas.** As shown in §22.14, multiple triggers on the same table/event fire in alphabetical-by-name order — a genuine, easy-to-overlook production surprise when two triggers' logic depends on running in a particular sequence.
- **Cascading trigger chains.** A trigger on table A updates table B; table B has its own trigger that updates table C; table C's trigger updates table A again. Each individual trigger looks simple and correct in isolation — the danger is entirely in the *composition*, which is hard to see by reading any single trigger's source, and which risks genuine infinite loops across tables (a multi-table version of §22.15's single-table recursion problem, and correspondingly harder to detect and debug).

### Recommendation
**Use triggers sparingly, and specifically for cross-cutting concerns that must hold true regardless of the caller** — audit logging (Example 1) and denormalized-aggregate maintenance (Example 5) are the textbook legitimate uses, because by nature they need to apply universally and are not really "business logic" a human reasons about at the call site anyway. **Prefer explicit application code or an explicitly-called stored procedure (Chapter 19) for business logic that a developer needs to see, test, step through a debugger on, and reason about directly** — anything that materially affects *what the business does*, as opposed to bookkeeping *about* what the business does, belongs in visible, traceable code.

---

## 22.18 When to Use / Not Use Triggers

| Use a trigger when... | Prefer application code / an explicit procedure when... |
|---|---|
| The rule must hold for *every* writer, with no exceptions, including writers you don't control (migrations, admin tools, other teams) | The logic is core business behavior that developers need to read, test, and reason about directly |
| The concern is genuinely cross-cutting and orthogonal to business logic (audit trail, timestamp bookkeeping, denormalized aggregate sync) | The logic changes frequently and benefits from being in version-controlled, unit-tested application code |
| A `CHECK` constraint is provably insufficient (needs to query other rows/tables) but the rule is still a hard invariant, not a judgment call | The rule involves external systems (sending an email, calling an API) — triggers cannot safely do this inside a transaction |
| You need `INSTEAD OF` semantics to make a non-updatable view usable (Chapter 15) | You want the operation's full side effects visible and debuggable at the call site |

---

## 22.19 Comparisons: Trigger vs Application Code vs Stored Procedure

| Aspect | Trigger | Application code | Stored procedure (explicitly called) |
|---|---|---|---|
| Visible at the call site? | No — fires automatically, invisibly | Yes | Yes — an explicit `CALL`/invocation |
| Guaranteed for every writer? | Yes, unconditionally | No — only the code paths that include it | Only if every writer remembers to call it |
| Testability | Harder — requires performing real DML to exercise it | Easiest — standard unit/integration tests | Easy — call it directly and assert |
| Runs inside the writer's transaction? | Always | Depends on how it's written | Yes, if called within one |
| Performance cost | Paid on every affected row of every matching statement, forever, invisibly | Paid only when that code path executes | Paid only when explicitly invoked |
| Best for | Cross-cutting invariants: audit trails, denormalized aggregates, hard validation `CHECK` can't express | Business logic needing visibility, fast iteration, easy testing | Business logic that must live in the database but should remain traceable and intentional |

---

## 22.20 Dialect Comparison: Trigger Syntax Across Engines

### **[MySQL]** — trigger body inline, no separate function

MySQL has no `RETURNS TRIGGER` function architecture — the trigger's logic is written **directly inside `CREATE TRIGGER`**, and a separate trigger must be declared per event (MySQL does not support `AFTER INSERT OR UPDATE OR DELETE` combined in one trigger the way PostgreSQL does):

```sql
DELIMITER $$
CREATE TRIGGER trg_accounts_audit_insert
AFTER INSERT ON accounts
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, operation, row_pk, new_data)
    VALUES ('accounts', 'INSERT', NEW.account_id,
            JSON_OBJECT('account_id', NEW.account_id, 'balance', NEW.balance));
END$$
DELIMITER ;
```

MySQL also does not support statement-level triggers at all — every MySQL trigger is implicitly row-level; there is no `FOR EACH STATEMENT` option and no transition-table equivalent.

### **[SQL Server]** — `inserted`/`deleted`, statement-level by nature

SQL Server triggers operate on two virtual tables, `inserted` and `deleted`, that represent **all** rows affected by the statement — SQL Server triggers are statement-level by nature, even when the logic "feels" row-level:

```sql
CREATE TRIGGER trg_accounts_audit
ON accounts
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    INSERT INTO audit_log (table_name, operation, row_pk, new_data)
    SELECT 'accounts', 'INSERT_OR_UPDATE', i.account_id, NULL
    FROM inserted i;
END;
```

> **Important Note — a real and important distinction from PostgreSQL**
> A SQL Server trigger body that assumes exactly one row is in `inserted`/`deleted` (e.g., `SELECT @id = account_id FROM inserted`) will silently misbehave the moment a multi-row `UPDATE`/`INSERT` fires it — because `inserted` may legitimately contain many rows at once. SQL Server trigger logic must always be written **set-based**, using `JOIN`s against `inserted`/`deleted`, precisely because there is no per-row `OLD`/`NEW` the way PostgreSQL's `FOR EACH ROW` provides. This is the single most common porting mistake when translating a PostgreSQL row-level trigger to SQL Server.

### **[Oracle]** — `:OLD`/`:NEW` with a colon, `FOR EACH ROW` required for row-level

```sql
CREATE OR REPLACE TRIGGER trg_accounts_audit
AFTER INSERT OR UPDATE OR DELETE ON accounts
FOR EACH ROW
BEGIN
    IF INSERTING THEN
        INSERT INTO audit_log (table_name, operation, row_pk, new_data)
        VALUES ('accounts', 'INSERT', :NEW.account_id, NULL);
    ELSIF UPDATING THEN
        INSERT INTO audit_log (table_name, operation, row_pk, old_data, new_data)
        VALUES ('accounts', 'UPDATE', :NEW.account_id, NULL, NULL);
    ELSIF DELETING THEN
        INSERT INTO audit_log (table_name, operation, row_pk, old_data)
        VALUES ('accounts', 'DELETE', :OLD.account_id, NULL);
    END IF;
END;
/
```

Oracle's pseudo-records are prefixed with a colon (`:OLD`, `:NEW`) — a syntax quirk unique to Oracle among the four dialects — and `FOR EACH ROW` is **mandatory** to get row-level behavior; omitting it produces a statement-level trigger by default, the opposite of PostgreSQL's default. Oracle also provides `INSERTING`/`UPDATING`/`DELETING` boolean conditional predicates as a direct alternative to checking `TG_OP`-style values.

### Summary table

| Dialect | Logic location | Row-level available? | Statement-level available? | OLD/NEW syntax |
|---|---|---|---|---|
| PostgreSQL | Separate `RETURNS TRIGGER` function | Yes (`FOR EACH ROW`) | Yes, incl. transition tables (10+) | `OLD` / `NEW` |
| MySQL | Inline in `CREATE TRIGGER` | Yes (only option) | No | `OLD` / `NEW` |
| SQL Server | Inline in `CREATE TRIGGER` | No true per-row — `inserted`/`deleted` hold all affected rows | Yes (the only real mode) | `inserted` / `deleted` virtual tables |
| Oracle | Inline in `CREATE OR REPLACE TRIGGER` | Yes, but requires explicit `FOR EACH ROW` | Yes (default if `FOR EACH ROW` omitted) | `:OLD` / `:NEW` |

---

## 22.21 Real-World Use Cases

- **Regulatory audit trails** — financial and healthcare systems are frequently required (SOX, HIPAA, and similar regimes) to prove exactly what changed, when, and by whom; a trigger-backed `audit_log` like Example 1 is the standard mechanism, because it cannot be bypassed by any application code path.
- **Denormalized read-optimized columns** — `orders.total_amount` (Example 5), running balances, cached counts (`product.review_count`) — anywhere Chapter 14's normalization/denormalization trade-off is deliberately made, a trigger is what keeps the redundant copy honest.
- **Enforcing invariants CHECK cannot express** — daily/rolling limits (Example 4), cross-table consistency, anything requiring a query against other rows.
- **Slowly changing dimensions and temporal history** — Example 3's shadow-table pattern is the manual precursor to formal SCD modeling (Chapter 31) and to full temporal-table features in some engines.
- **Legacy change-data-capture** — before dedicated logical replication/CDC tooling (Chapter 30) became mainstream, triggers writing to a queue/staging table were the standard way to propagate changes to downstream systems.
- **Making complex views usable** — `INSTEAD OF` triggers are the standard way production systems expose a friendly, joined/aggregated view to application code while keeping the underlying normalized schema intact underneath.

---

## 22.22 Practice Questions

1. Explain, precisely, why `banking_db.audit_log.old_data` is `NULL` for an `INSERT` operation and `new_data` is `NULL` for a `DELETE` operation, in terms of `OLD`/`NEW` availability.
2. Rewrite Worked Example 1's trigger function so it also fires on `TRUNCATE`, correctly noting what changes about how you'd have to write it (hint: revisit §22.16).
3. A colleague writes a `BEFORE INSERT` trigger that ends with `RETURN NULL;` unconditionally, intending only to log something as a side effect first. What actually happens to every `INSERT` on that table, and why?
4. Explain the exact difference between a row-level and a statement-level trigger in terms of how many times the trigger function executes for a 10,000-row `UPDATE`.
5. What are transition tables, what PostgreSQL version introduced them, and what specific problem do they solve that row-level triggers cannot solve efficiently?
6. Why can't the daily-withdrawal-limit rule in Worked Example 4 be expressed as a plain `CHECK` constraint on `banking_db.transactions`?
7. Two triggers, `trg_b_check` and `trg_a_notify`, are both `AFTER UPDATE, FOR EACH ROW` on the same table. In what order do they fire, and how would you guarantee a different order if it mattered?
8. Describe, step by step, how an `AFTER UPDATE` trigger that issues an unguarded `UPDATE` on its own table causes infinite recursion, and give two distinct ways to prevent it.
9. Why does a row-level `AFTER INSERT` trigger not fire at all when a table is truncated, and what kind of trigger would you need instead to keep a denormalized aggregate correct across a `TRUNCATE`?
10. In SQL Server, why is it incorrect to assume `inserted` contains exactly one row inside a trigger body, even for what looks like a single-row `UPDATE` statement from the application's perspective?
11. Give a concrete example of a rule that is better implemented as an explicitly-called stored procedure than as a trigger, and explain your reasoning in terms of visibility and testability, not just performance.
12. Explain why Worked Example 5's aggregate-recompute trigger recomputes the full `SUM(...)` from scratch on every firing instead of incrementing/decrementing `total_amount` directly, and what failure mode this design avoids.

---

## 22.23 Chapter Challenge — Audit-Logging Order Status Changes

**Task:** Design a complete audit-logging solution for `ecommerce_db.orders` that records every status change (`PENDING` → `PAID` → `SHIPPED` → `DELIVERED`, or → `CANCELLED`), while correctly ignoring updates that touch *other* columns (like `shipping_address`) without changing `status` at all.

**Requirements:**
- A dedicated audit table for order status history (not the banking `audit_log` — this is a different schema).
- The trigger must fire on `INSERT` (recording the order's initial status) and `UPDATE` — but for `UPDATE`, it must only insert an audit row when `status` actually changed, using `IF OLD.status IS DISTINCT FROM NEW.status THEN ... END IF;` (`IS DISTINCT FROM` is required here, not `<>`, specifically because a plain `<>` comparison against a `NULL` would evaluate to `UNKNOWN` and silently skip the row — Chapter 13's `UNKNOWN`-passes lesson applies here just as much as it does to `CHECK` constraints).

**Reference solution:**

```sql
CREATE TABLE ecommerce_db.order_status_audit (
    audit_id    BIGSERIAL PRIMARY KEY,
    order_id    INT NOT NULL REFERENCES ecommerce_db.orders(order_id),
    old_status  VARCHAR(20),
    new_status  VARCHAR(20) NOT NULL,
    changed_by  VARCHAR(100) NOT NULL DEFAULT current_user,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
```

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.fn_orders_status_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO ecommerce_db.order_status_audit (order_id, old_status, new_status)
        VALUES (NEW.order_id, NULL, NEW.status);

    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status IS DISTINCT FROM NEW.status THEN
            INSERT INTO ecommerce_db.order_status_audit (order_id, old_status, new_status)
            VALUES (NEW.order_id, OLD.status, NEW.status);
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

```sql
CREATE TRIGGER trg_orders_status_audit
AFTER INSERT OR UPDATE ON ecommerce_db.orders
FOR EACH ROW
EXECUTE FUNCTION ecommerce_db.fn_orders_status_audit();
```

**Verification:**

```sql
-- A status change: order 9 currently PAID -> SHIPPED
UPDATE ecommerce_db.orders SET status = 'SHIPPED' WHERE order_id = 9;

-- NOT a status change: only the shipping address changes
UPDATE ecommerce_db.orders SET shipping_address = '10 New Colony Rd, Delhi' WHERE order_id = 9;

SELECT * FROM ecommerce_db.order_status_audit WHERE order_id = 9;
```
```
 audit_id | order_id | old_status | new_status | changed_by |         changed_at
----------+----------+------------+------------+------------+----------------------------
        1 |        9 | PAID       | SHIPPED    | postgres   | 2026-09-24 10:45:02.117003
```

Only **one** audit row exists for order 9, even though two `UPDATE` statements ran against it — the second one changed `shipping_address` only, so `OLD.status IS DISTINCT FROM NEW.status` evaluated to `FALSE` and the `IF` block was skipped entirely, exactly as required.

**Extension exercise:** Add a `CHECK`-style guard *inside the trigger* (not a table `CHECK` constraint, since it needs to reference `OLD`) that raises an exception if someone attempts an invalid status transition — e.g., jumping straight from `PENDING` to `DELIVERED`, or moving *out of* `CANCELLED` or `DELIVERED` at all (treat both as terminal states). This combines Worked Example 4's validation pattern with this challenge's change-detection pattern in a single trigger function.

---

## Key Takeaways

- A trigger is a binding — `CREATE TRIGGER` names a timing, an event, a table, and a function; all real logic lives in a separate `RETURNS TRIGGER` function, almost always written in PL/pgSQL.
- `BEFORE` triggers can inspect and modify `NEW`, or cancel the write by returning `NULL`; `AFTER` triggers observe a write that already happened and are the right home for side effects like audit logging; `INSTEAD OF` triggers (views only, row-level only) intercept DML entirely, making otherwise non-updatable views (Chapter 15) writable.
- Row-level triggers fire once per affected row; statement-level triggers fire once per statement — and PostgreSQL 10+'s transition tables (`REFERENCING OLD TABLE/NEW TABLE`) give statement-level triggers genuine set-based access to every changed row in one shot, a powerful and underused feature.
- `OLD` and `NEW` availability depends on the operation: `INSERT` has only `NEW`, `DELETE` has only `OLD`, `UPDATE` has both — referencing the wrong one raises a runtime error.
- The five worked patterns — audit logging via `to_jsonb(OLD)`/`to_jsonb(NEW)`, `updated_at` maintenance, history/shadow tables, cross-row validation `CHECK` cannot express, and denormalized aggregate maintenance — cover the overwhelming majority of legitimate real-world trigger use.
- A trigger's writes and the statement that fired it are one atomic unit: an exception anywhere inside a trigger rolls back the entire statement/transaction, not just the trigger's own work.
- Multiple triggers of the same timing/event on one table fire in alphabetical order by trigger name — a real gotcha with no other implicit ordering guarantee.
- Row-level triggers never fire on `TRUNCATE`; only statement-level `TRUNCATE` triggers can observe it — a direct consequence of `TRUNCATE` not processing rows individually (Chapter 3).
- Unguarded `AFTER` triggers that re-issue statements against their own table risk infinite recursion; `pg_trigger_depth()` and `WHEN` guards prevent it, but the safest fix is usually to modify `NEW` in a `BEFORE` trigger instead of issuing a fresh statement in an `AFTER` trigger.
- Triggers trade visibility for universality: use them sparingly, for genuine cross-cutting concerns (audit trails, denormalized aggregates, hard cross-row validation) — keep core business logic in application code or explicitly-called stored procedures, where it stays visible, testable, and debuggable.

## What's Next

Triggers let the database react automatically to changes — but everything you've written so far has had its table and column names fixed at the moment you wrote the SQL. [Chapter 23 — Dynamic SQL & Injection Safety](23-dynamic-sql.md) covers the opposite problem: building and executing SQL statements whose structure isn't known until runtime — table names computed from a parameter, a `WHERE` clause assembled conditionally, a report generator that queries whichever table a caller names — and, critically, how to do all of that without opening the exact same SQL-injection vulnerabilities that untrusted string concatenation creates in application code.
