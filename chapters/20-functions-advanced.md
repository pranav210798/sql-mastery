# Chapter 20 — Advanced Functions (User-Defined Functions, Volatility & Security)

> **Part V — Procedural SQL** · Previous: [Chapter 19 — Stored Procedures](19-stored-procedures.md) · Next: [Chapter 21 — Cursors](21-cursors.md)

This chapter uses both `company_db` and `ecommerce_db`. Load them if you
haven't already:

```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
```

```sql
SET search_path TO company_db;    -- for employees/salaries/departments examples
-- and, in the ecommerce sections:
SET search_path TO ecommerce_db;  -- for products/orders/order_items examples
```

Every function in this chapter is built with `CREATE OR REPLACE FUNCTION` so
you can re-run examples safely as you experiment.

---

## 20.1 Why This Chapter Exists

Chapter 19 taught you `PL/pgSQL` as a *language*: variables, `IF`/`CASE`,
loops, exception handling, and how a `PROCEDURE` uses all of that to run a
multi-step business process invoked with `CALL`. This chapter assumes all of
that and does **not** re-teach it. Instead, it asks a narrower, sharper
question: *what can a `FUNCTION` do that a procedure can't, and what rules
does a function have to follow because of it?*

The answer, in one sentence: **a function returns a value (or a set of rows)
that SQL can consume as part of a larger expression** — in a `SELECT` list,
a `WHERE` clause, a `JOIN`, or even inside another function call. A
procedure cannot do this; it can only be `CALL`ed as a standalone statement.
That single capability — being usable *inside* SQL, not just alongside it —
is what forces PostgreSQL to formally reason about two things this chapter
covers in depth: **volatility** (can the planner cache, reorder, or skip
calls to this function?) and **return shape** (scalar value? a whole row? a
table of rows?).

By the end of this chapter you will be able to:

- Write scalar, table-valued, and set-returning user-defined functions, and
  know precisely when to reach for each.
- Explain the difference between `RETURNS TABLE (...)` and `RETURNS SETOF
  sometype`, not just recite that they're "similar."
- Correctly label a function `IMMUTABLE`, `STABLE`, or `VOLATILE` — and
  explain, mechanically, why getting this wrong produces silently wrong
  query results rather than an error.
- Use `SECURITY DEFINER` to give a function controlled access to data a
  caller isn't otherwise allowed to see.
- Overload functions by parameter signature, and know that MySQL flatly
  does not support this.
- State, precisely and from memory, every real difference between a
  `FUNCTION` and a `PROCEDURE` across PostgreSQL, MySQL, Oracle, and SQL
  Server.

---

## 20.2 Anatomy of `CREATE FUNCTION`

### 20.2.1 Simple Explanation

`CREATE FUNCTION` defines a named, reusable, parameterized piece of logic
that PostgreSQL treats as a first-class citizen of SQL expressions — you can
call it wherever you could put a value, a row, or a table.

### 20.2.2 Technical Explanation

A function definition bundles: a name, a parameter list (each parameter
optionally typed with a default), a return specification (what shape of
data comes back), the implementation language, an optional set of
**behavioral declarations** (volatility, strictness, security context,
parallel safety, planner cost hints), and a body.

### 20.2.3 Full Syntax Breakdown

**[PostgreSQL]**

```sql
CREATE [OR REPLACE] FUNCTION function_name (
    [ parameter_name ] [ IN | OUT | INOUT ] parameter_type [ DEFAULT default_expr ]
    [, ...]
)
RETURNS { return_type
        | TABLE (column_name column_type [, ...])
        | SETOF return_type }
LANGUAGE lang_name                                   -- 'sql', 'plpgsql', 'plpython3u', ...
[ IMMUTABLE | STABLE | VOLATILE ]                     -- default: VOLATILE
[ [ NOT ] LEAKPROOF ]
[ CALLED ON NULL INPUT | RETURNS NULL ON NULL INPUT | STRICT ]
[ SECURITY INVOKER | SECURITY DEFINER ]               -- default: INVOKER
[ PARALLEL { UNSAFE | RESTRICTED | SAFE } ]           -- default: UNSAFE
[ COST execution_cost ]
[ ROWS result_rows ]                                   -- only meaningful for set-returning functions
AS $$
    function_body
$$;
```

| Clause | Meaning |
|---|---|
| `OR REPLACE` | Redefine an existing function of the same name **and parameter signature** without dropping it first (dependent objects like views survive). Changing the return type requires `DROP FUNCTION` first. |
| Parameter mode (`IN`/`OUT`/`INOUT`) | `IN` (default) — value passed in, read-only. `OUT` — an additional output column; a function with one or more `OUT` parameters implicitly returns a row/record of those columns. `INOUT` — both. |
| `DEFAULT default_expr` | Lets callers omit trailing arguments; PostgreSQL fills in the default. Defaults must be supplied right-to-left (a parameter with a default can't precede one without, in the same call). |
| `RETURNS return_type` | A single scalar type (`INT`, `NUMERIC`, `TEXT`, `BOOLEAN`, ...), a composite/row type (a table's row type, e.g. `RETURNS employees`, or a custom `CREATE TYPE`), `TABLE(...)`, `SETOF sometype`, or `VOID`. Covered fully in §20.3. |
| `LANGUAGE` | `sql` and `plpgsql` are the two you'll use 99% of the time. PostgreSQL also ships (or can install as extensions) `plpython3u`, `plperl`, `pltcl`, and others — "untrusted" procedural-language wrappers that let you write function bodies in a general-purpose language. These are covered only in passing here; the course's procedural-logic depth lives entirely in `sql`/`plpgsql`. |
| Volatility (`IMMUTABLE`/`STABLE`/`VOLATILE`) | The formal promise about how the function's output relates to its input and the database state. This is the subject of the required deep dive in §20.7 — get this wrong and queries return *silently* incorrect results. |
| `STRICT` / `RETURNS NULL ON NULL INPUT` | If **any** argument is `NULL`, PostgreSQL skips executing the function body entirely and returns `NULL` immediately. `CALLED ON NULL INPUT` (the default) means the function body runs even with `NULL` arguments, and must handle that itself. |
| `SECURITY INVOKER` / `SECURITY DEFINER` | Whose privileges the function body runs with — the caller's (default) or the function owner's. Deep dive in §20.10. |
| `PARALLEL SAFE/RESTRICTED/UNSAFE`, `COST`, `ROWS` | Planner hints: whether the function can safely run inside a parallel worker, a relative CPU-cost estimate, and (for set-returning functions) an estimated row count. These affect plan *quality*, not correctness — noted here for completeness, not deep-dived in this chapter. |
| `AS $$ ... $$` | The function body, delimited by **dollar-quoting** (`$$...$$` or a tagged variant like `$body$...$body$` when the body itself contains `$$`, e.g. nested dynamic SQL). For `LANGUAGE sql`, the body is one or more plain SQL statements. For `LANGUAGE plpgsql`, the body is a `BEGIN ... END;` block exactly like a procedure's, per Chapter 19. |

> **Important Note.** Everything about variables, `IF`/`CASE`, loops
> (`LOOP`, `WHILE`, `FOR`), and `EXCEPTION` handling inside a `plpgsql`
> function body works **identically** to what you learned for procedures in
> Chapter 19 — PL/pgSQL is one language shared by both object types. Nothing
> in this chapter re-derives that syntax; it's assumed knowledge.

---

## 20.3 Return Types: Scalar, Composite, `TABLE`, `SETOF`, `VOID`

| Return type | Returns | Example declaration |
|---|---|---|
| Scalar | A single value of a single type | `RETURNS INT`, `RETURNS NUMERIC`, `RETURNS TEXT` |
| Composite / row type | A single row, with multiple named/typed columns | `RETURNS employees` (an existing table's row type), or `RETURNS my_custom_type` (from `CREATE TYPE`) |
| `TABLE (...)` | Zero or more rows, with an inline, ad hoc column list defined right in the function signature | `RETURNS TABLE (employee_id INT, full_name TEXT)` |
| `SETOF sometype` | Zero or more rows of an **already-existing** type — a scalar type, a table's row type, or a custom composite type | `RETURNS SETOF INT`, `RETURNS SETOF products` |
| `VOID` | Nothing — the function is called purely for its side effects | `RETURNS VOID` |

**Composite/row-type example** — return an entire matching row as a single
structured value:

```sql
CREATE OR REPLACE FUNCTION get_employee(p_employee_id INT)
RETURNS employees
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM employees WHERE employee_id = p_employee_id;
$$;
```

```sql
SELECT * FROM get_employee(4);
```

| employee_id | first_name | last_name | email | hire_date | job_title | department_id | manager_id | status | created_at |
|---|---|---|---|---|---|---|---|---|---|
| 4 | Vikram | Joshi | vikram.joshi@company.com | 2018-07-15 | Software Engineer | 1 | 2 | ACTIVE | *(seed timestamp)* |

`RETURNS employees` means the function's output type *is* the row type
PostgreSQL automatically defines for every table. You can also pull a
single field out of the composite result with parenthesized dot-notation:

```sql
SELECT (get_employee(4)).first_name, (get_employee(4)).job_title;
```

```
 first_name | job_title
------------+--------------------
 Vikram     | Software Engineer
```

*Line-by-line:* the parentheses around `get_employee(4)` are **required** —
without them, PostgreSQL parses `get_employee(4).first_name` as "a table
named `get_employee` with schema-qualification," a parse error. The
parentheses tell the parser "treat this whole call as one composite value,
then project a field from it."

`VOID` example (illustrative — assumes a `price_change_log` audit table
exists; a legacy pattern from before PostgreSQL 11 introduced real
procedures, kept here only so you recognize it in older codebases):

```sql
CREATE OR REPLACE FUNCTION log_price_change(p_product_id INT, p_old_price NUMERIC, p_new_price NUMERIC)
RETURNS VOID
LANGUAGE sql
VOLATILE
AS $$
    INSERT INTO price_change_log (product_id, old_price, new_price, changed_at)
    VALUES (p_product_id, p_old_price, p_new_price, now());
$$;
```

> **Important Note.** On PostgreSQL 11+, prefer a real `PROCEDURE` (Chapter
> 19) over a `VOID`-returning function for pure side-effect logic — a
> procedure can manage its own transaction, and its intent ("this does
> something, it doesn't compute a value") is unambiguous from the `CALL`
> syntax alone. `RETURNS VOID` functions still exist and are legal, but
> mostly persist in code written before PL/pgSQL procedures existed.

`TABLE` and `SETOF` get full treatment in §20.5–§20.6, since they're the
heart of this chapter's table-valued/set-returning coverage.

---

## 20.4 Scalar Functions

### 20.4.1 Simple Explanation

A scalar function takes some inputs and returns exactly one value — usable
anywhere a column value could go: in a `SELECT` list, a `WHERE` clause, an
`ORDER BY`, even nested inside another function call.

### 20.4.2 Technical Explanation

Scalar functions are the most common UDF shape. Their defining property is
that they participate in SQL expressions as a **first-class value producer**
— unlike a procedure, which can only be executed as a standalone `CALL`
statement, a scalar function's return value flows directly into the query
that invoked it, row by row.

### 20.4.3 Example — Simple: computing tenure

```sql
CREATE OR REPLACE FUNCTION calculate_tenure_years(p_hire_date DATE)
RETURNS INT
LANGUAGE sql
STABLE
AS $$
    SELECT EXTRACT(YEAR FROM AGE(CURRENT_DATE, p_hire_date))::INT;
$$;
```

```sql
SELECT employee_id, first_name, hire_date,
       calculate_tenure_years(hire_date) AS tenure_years
FROM employees
ORDER BY employee_id;
```

Output **as of the date this chapter was written (2026-09-24)** — run this
yourself and every value will have crept forward by however many
anniversaries have passed since:

| employee_id | first_name | hire_date  | tenure_years |
|---|---|---|---|
| 1  | Aditi  | 2015-03-01 | 11 |
| 2  | Rahul  | 2016-05-12 | 10 |
| 3  | Sneha  | 2017-01-20 | 9  |
| 4  | Vikram | 2018-07-15 | 8  |
| 5  | Ananya | 2019-09-01 | 7  |
| 6  | Karan  | 2020-02-10 | 6  |
| 7  | Priya  | 2015-11-05 | 10 |
| 8  | Arjun  | 2017-04-18 | 9  |
| 9  | Meera  | 2021-03-22 | 5  |
| 10 | Rohan  | 2016-08-09 | 10 |
| 11 | Isha   | 2019-01-14 | 7  |
| 12 | Nikhil | 2016-12-01 | 9  |
| 13 | Divya  | 2018-06-25 | 8  |
| 14 | Rajesh | 2017-09-30 | 8  |
| 15 | Pooja  | 2020-10-05 | 5  |
| 16 | Aman   | 2022-01-10 | 4  |

*Line-by-line:* `AGE(CURRENT_DATE, p_hire_date)` returns an `interval`
expressed in whole years/months/days (e.g., `11 years 6 mons 23 days`);
`EXTRACT(YEAR FROM ...)` pulls just the year component, and the cast to
`::INT` matches the declared `RETURNS INT`. Notice employee 14 (Rajesh,
hired `2017-09-30`) shows tenure `8`, not `9` — his anniversary hasn't
happened yet as of `2026-09-24` (six days short), which is exactly the kind
of boundary case `AGE()` handles correctly and a naive
`EXTRACT(YEAR FROM CURRENT_DATE) - EXTRACT(YEAR FROM hire_date)` would get
wrong.

**Why `STABLE` and not `IMMUTABLE`?** This function's output depends on
`CURRENT_DATE`, which changes daily — calling it with the *same*
`p_hire_date` today versus a year from now gives *different* results. That
disqualifies it from `IMMUTABLE`. But within a single statement (indeed,
within a whole transaction — `CURRENT_DATE` is fixed for the duration of a
transaction in PostgreSQL), it's perfectly consistent, and it never reads or
writes a table — that's exactly the `STABLE` contract. This exact example
is revisited as the running case for volatility in §20.7.

### 20.4.4 Example — Parameters with Defaults

```sql
CREATE OR REPLACE FUNCTION calculate_order_tax(p_amount NUMERIC, p_tax_rate NUMERIC DEFAULT 0.18)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT ROUND(p_amount * p_tax_rate, 2);
$$;
```

```sql
SELECT calculate_order_tax(49498.00);          -- uses default 0.18
SELECT calculate_order_tax(49498.00, 0.05);    -- explicit override
```

| Call | Result |
|---|---|
| `calculate_order_tax(49498.00)` | `8909.64` |
| `calculate_order_tax(49498.00, 0.05)` | `2474.90` |

This function is a legitimate `IMMUTABLE` — it touches no table, and the
same two numeric inputs will *always* produce the same output, forever, on
any server, in any timezone, under any transaction. This is the textbook
"pure math" `IMMUTABLE` case referenced throughout §20.7.

### 20.4.5 Common Mistakes — Missing `RETURN` in Every Code Path

**[PostgreSQL]** Unlike some languages, PL/pgSQL does **not** statically
verify at `CREATE FUNCTION` time that every branch of your logic ends in a
`RETURN`. The error only surfaces **at runtime**, the first time execution
actually falls off the end of the function body without hitting a `RETURN`:

```sql
CREATE OR REPLACE FUNCTION classify_order_size(p_quantity INT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_quantity > 10 THEN
        RETURN 'BULK';
    ELSIF p_quantity > 1 THEN
        RETURN 'MULTI';
    END IF;
    -- BUG: no branch handles p_quantity <= 1 — falls through with no RETURN
END;
$$;
```

```sql
SELECT classify_order_size(15);  -- 'BULK'  — fine
SELECT classify_order_size(5);   -- 'MULTI' — fine
SELECT classify_order_size(1);   -- ERROR:  control reached end of function without RETURN
```

> **⚠️ Warning.** `CREATE FUNCTION` succeeds without complaint for the code
> above — PostgreSQL parses and stores it happily. The bug is invisible
> until a caller passes an argument that hits the un-covered branch, which
> can be days or months after deployment, and often in production first.
> Always give plpgsql functions an unconditional final `RETURN` (or an
> `ELSE` branch that returns something, even an explicit error via
> `RAISE EXCEPTION`) so every path is covered. Setting
> `plpgsql.extra_warnings = 'all'` (or installing the `plpgsql_check`
> extension) surfaces some of these gaps earlier, at function-creation or
> lint time, instead of waiting for a bad runtime input.

### 20.4.6 When to Use a Scalar Function

Use a scalar function when you have a small, reusable **computation** —
tenure, tax, a formatted label, a validation check — that you want to call
inline inside ordinary `SELECT`/`WHERE`/`ORDER BY` clauses, the same way you
call a built-in like `UPPER()` or `COALESCE()`. If the logic needs to run
several DML statements, manage its own transaction boundary, or doesn't
produce a value at all, that's a procedure's job (§20.12).

---

## 20.5 Table-Valued Functions — `RETURNS TABLE`

### 20.5.1 Simple Explanation

A table-valued function doesn't return one value — it returns a whole table
of rows, which you query with `SELECT * FROM function_name(...)` exactly as
if it were a real table or view, except it takes parameters.

### 20.5.2 Technical Explanation

`RETURNS TABLE (column_name column_type, ...)` declares an **anonymous,
inline composite type** as part of the function's own signature — you don't
need a pre-existing table or `CREATE TYPE` to back it. Inside the function
body, those column names become available like `OUT` parameters, and you
populate them with `RETURN QUERY` (run a query and stream all of its rows
out) or `RETURN NEXT` (build up one row at a time, useful inside a loop).

### 20.5.3 Full Syntax Breakdown

```sql
CREATE OR REPLACE FUNCTION function_name(param1 type1, ...)
RETURNS TABLE (col1 type1, col2 type2, ...)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT ...
    FROM ...
    WHERE ...;
END;
$$;
```

### 20.5.4 Example — Simple: a department roster

```sql
CREATE OR REPLACE FUNCTION get_department_roster(p_dept_id INT)
RETURNS TABLE (
    employee_id INT,
    full_name   TEXT,
    job_title   TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT e.employee_id,
           e.first_name || ' ' || e.last_name,
           e.job_title::TEXT
    FROM employees e
    WHERE e.department_id = p_dept_id
    ORDER BY e.employee_id;
END;
$$;
```

```sql
SELECT * FROM get_department_roster(1);   -- Engineering
```

| employee_id | full_name | job_title |
|---|---|---|
| 1  | Aditi Rao      | CTO |
| 2  | Rahul Mehta    | Engineering Manager |
| 3  | Sneha Kulkarni | Senior Engineer |
| 4  | Vikram Joshi   | Software Engineer |
| 5  | Ananya Singh   | Software Engineer |
| 6  | Karan Verma    | Junior Engineer |
| 16 | Aman Chawla    | Software Engineer |

*Line-by-line:* Because this function is called with `FROM`, PostgreSQL
treats its output exactly like a table for the rest of the query — you can
add a `WHERE` clause on top of the call, join it to another table, alias it,
or wrap it in a CTE. `RETURN QUERY` executes the inner `SELECT` and streams
every row it produces straight out as the function's result set — there's
no intermediate materialization step you have to manage yourself.

**Calling it with a default and combining it with more SQL:**

```sql
SELECT roster.full_name, roster.job_title
FROM get_department_roster(3) AS roster    -- HR
WHERE roster.job_title LIKE '%Manager%';
```

```
 full_name    | job_title
--------------+-------------
 Rohan Kapoor | HR Manager
```

### 20.5.5 Internal Behavior

`RETURNS TABLE` is, under the hood, syntactic sugar: PostgreSQL implements
it as a set of `OUT` parameters (one per declared column) combined with an
implicit `RETURNS SETOF record`. This is exactly why the next section's
distinction between `TABLE` and `SETOF` matters — they are two different
*syntaxes* for a very similar underlying mechanism, not two unrelated
features.

### 20.5.6 Common Mistakes

- Forgetting `RETURN QUERY` and instead writing a bare `SELECT` inside a
  `plpgsql` table function body — a bare `SELECT` without `INTO` or `RETURN
  QUERY` is invalid inside `plpgsql` and raises a syntax/runtime error, not
  a silent no-op.
- Mismatched column types between the `TABLE(...)` declaration and what the
  inner query actually produces — PostgreSQL applies an assignment cast
  where possible (as it did above, casting `job_title` from `VARCHAR(100)`
  to the declared `TEXT`), but an incompatible mismatch (e.g., declaring
  `INT` but selecting a `TEXT` column with letters in it) fails at call
  time, not creation time.

---

## 20.6 Set-Returning Functions — `RETURNS SETOF`, and `TABLE` vs. `SETOF` Precisely

### 20.6.1 Simple Explanation

`SETOF` is PostgreSQL's more general mechanism for "this function returns
many rows, not one." `RETURNS TABLE(...)` (§20.5) is really just a
convenient way to write `RETURNS SETOF` for an ad hoc, inline row shape.
Nearly every set-returning built-in you've already used — including
`unnest()` — is a `SETOF`-returning function under the hood.

### 20.6.2 `TABLE` vs. `SETOF` — the Precise Distinction

| | `RETURNS TABLE (col1 t1, col2 t2, ...)` | `RETURNS SETOF sometype` |
|---|---|---|
| What `sometype` must be | N/A — the column list *is* the type, defined inline, on the spot | Must already exist: a scalar type (`SETOF INT`), an existing table's row type (`SETOF employees`), or a previously `CREATE TYPE`'d composite type |
| Where you define the output shape | Right there in the function signature, once, only for this function | Reuses a type that may be shared by other functions, tables, or casts |
| Typical use | Ad hoc query results that don't correspond to any single real table (e.g., a join/aggregation shaped for one purpose) | Returning full rows *from* (or shaped exactly like) an existing table, or returning a set of plain scalars |
| Underlying mechanism | Implemented as `OUT` parameters + implicit `SETOF record` | Direct |
| Populate with | `RETURN QUERY`, `RETURN NEXT` | `RETURN QUERY`, `RETURN NEXT` — identical mechanics |

**`SETOF` returning an existing table's row type** — no need to invent a
column list, because `products` already has one:

```sql
CREATE OR REPLACE FUNCTION get_active_products()
RETURNS SETOF products
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM products WHERE is_discontinued = FALSE ORDER BY product_id;
$$;
```

```sql
SELECT product_id, product_name, price FROM get_active_products();
```

| product_id | product_name | price |
|---|---|---|
| 1  | Galaxy Phone X    | 45999.00 |
| 2  | Pixel Lite        | 29999.00 |
| 3  | UltraBook Pro 14  | 89999.00 |
| 4  | GameBook 15       | 74999.00 |
| 5  | Men Cotton Shirt  | 1299.00  |
| 6  | Women Kurta Set   | 1799.00  |
| 7  | Non-stick Pan Set | 2499.00  |
| 8  | Electric Kettle   | 1499.00  |
| 9  | Wireless Earbuds  | 3499.00  |
| 10 | Laptop Sleeve 14" | 799.00   |

All 10 seeded products come back, because none of them have
`is_discontinued = TRUE` in the seed data.

**`SETOF` returning a plain scalar type** — a set of bare values, no row
structure at all:

```sql
CREATE OR REPLACE FUNCTION get_valid_ratings()
RETURNS SETOF SMALLINT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT generate_series(1, 5)::SMALLINT;
$$;
```

```sql
SELECT * FROM get_valid_ratings();
```

```
 get_valid_ratings
--------------------
 1
 2
 3
 4
 5
```

This mirrors the `reviews.rating` `CHECK (rating BETWEEN 1 AND 5)`
constraint — a genuinely `IMMUTABLE` function, since `generate_series` over
two hard-coded constants always produces the same five rows, forever, with
no table access at all.

### 20.6.3 `unnest()` — a Built-In Set-Returning Function You Already Use

`unnest()` is a PostgreSQL built-in with exactly the shape described above
— it takes an array and returns `SETOF anyelement`, one row per array
element:

```sql
SELECT unnest(ARRAY['CARD', 'UPI', 'NETBANKING', 'COD', 'WALLET']) AS payment_method;
```

```
 payment_method
----------------
 CARD
 UPI
 NETBANKING
 COD
 WALLET
```

*Line-by-line:* this is functionally identical to writing your own
`RETURNS SETOF TEXT` function that loops over an array and `RETURN NEXT`s
each element — `unnest()` is simply a highly-optimized, built-in instance
of the exact mechanism you just learned to write by hand. Recognizing this
demystifies a function you've likely already used (e.g., to expand an array
column, or to build a derived table from a literal list in a `JOIN`) without
necessarily knowing it was "just" a `SETOF` function.

### 20.6.4 Edge Cases

- A `SETOF`-returning function called in a scalar context (e.g., directly
  in a `SELECT` list without `FROM`) still works in PostgreSQL — it expands
  the set across output rows, one row per set element, effectively turning
  a 1-row query into N rows. This is legal but generally discouraged style;
  prefer calling set-returning functions in the `FROM` clause, where their
  row-producing nature is visually explicit.
- A function returning `SETOF sometype` with **zero** matching rows returns
  an empty set (0 rows) — not `NULL`, not an error. `SELECT *
  FROM get_department_roster(999);` (a nonexistent department) returns 0
  rows cleanly.

---

## 20.7 Function Volatility — `IMMUTABLE`, `STABLE`, `VOLATILE`

This is the single most consequential, most-skipped concept in this
chapter. Get it wrong, and your queries don't crash — they quietly return
**incorrect results**, which is far worse.

### 20.7.1 Simple Explanation

Volatility is a promise you make to the query planner about how
"predictable" your function's output is:

- **`IMMUTABLE`** — "give me the same inputs, any time, anywhere, and I
  promise the same output — I never look at the database or the clock."
- **`STABLE`** — "give me the same inputs *within one statement*, and I
  promise the same output — I might read the database, but I never change
  it, and my answer can differ between statements (or over time)."
- **`VOLATILE`** (the default) — "no promises at all — I might return a
  different answer every single time you call me, even with identical
  inputs, even within the same statement, and I might have side effects."

### 20.7.2 Technical Explanation

Volatility is a **declared contract**, not something PostgreSQL verifies by
inspecting your function's body. The planner takes your declaration at face
value and uses it to decide what optimizations are legal:

| Volatility | Planner may... |
|---|---|
| `IMMUTABLE` | Evaluate the function **once**, at plan time, if all arguments are constants (constant folding) — the call effectively disappears, replaced by its precomputed result. May be used in an **expression/functional index**. May be used in a `CHECK` constraint or a generated column. Safe to call once and reuse across an entire query, or even across queries, as long as inputs match. |
| `STABLE` | Call **once per statement** for a given set of arguments and reuse that result for the rest of that same statement (e.g., if the same call appears in both the `SELECT` list and a `WHERE` clause). Cannot be constant-folded across statements (the answer may differ tomorrow, or after an intervening write). **Cannot** be used in an expression/functional index — see §20.7.4. |
| `VOLATILE` | None of the above. Must be called **once per row**, in the exact order rows are processed, with no caching, no reuse, no reordering, and no early exit. This is required for anything with side effects (`INSERT`/`UPDATE`, sequence advancement) or genuinely unpredictable output (`random()`, `clock_timestamp()`). |

### 20.7.3 Why It Exists

The planner routinely needs to decide things like: *can I evaluate this
expression once instead of once per row? Can I use this expression as an
index key? Can I skip calling this function at all if I already know the
result from a previous identical call in the same query?* Answering "yes"
to any of these for a function that actually has side effects or truly
unpredictable output would be catastrophic — imagine the planner deciding
to call an `INSERT`-performing function only once instead of once per row,
because nothing told it not to. Volatility exists so the planner can make
these optimization decisions **safely**, based on your explicit promise,
rather than pessimistically treating every function call as unsafe to
optimize (which would leave enormous performance on the table for the vast
majority of functions, which really are pure or read-only).

### 20.7.4 Full Examples of Each Category

**`IMMUTABLE` — pure computation, no database, no clock:**

```sql
CREATE OR REPLACE FUNCTION calculate_order_tax(p_amount NUMERIC, p_tax_rate NUMERIC DEFAULT 0.18)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT ROUND(p_amount * p_tax_rate, 2);
$$;
```

Already introduced in §20.4.4 — correctly `IMMUTABLE` because its result
depends on nothing but its two numeric arguments.

**`STABLE` — reads a table, but never writes, and is consistent per
statement:**

```sql
CREATE OR REPLACE FUNCTION get_category_name(p_category_id INT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT category_name FROM categories WHERE category_id = p_category_id;
$$;
```

```sql
SELECT get_category_name(2);
```

```
 get_category_name
--------------------
 Mobiles
```

Correctly `STABLE`: it reads `categories`, so it can't be `IMMUTABLE` (the
category name could be renamed tomorrow); but it never writes anything, and
within one statement, `category_id = 2` will always resolve to the same row
— no `UPDATE` can happen *mid-statement* against a table this query is
reading (PostgreSQL's MVCC snapshot guarantees this — see Chapter 11).

**`VOLATILE` — result can differ even with identical inputs, in the same
statement:**

```sql
CREATE OR REPLACE FUNCTION generate_order_reference()
RETURNS TEXT
LANGUAGE sql
VOLATILE
AS $$
    SELECT 'ORD-' || to_char(now(), 'YYYYMMDD') || '-'
           || lpad((floor(random() * 100000))::int::text, 5, '0');
$$;
```

```sql
SELECT generate_order_reference(), generate_order_reference();
```

```
 generate_order_reference | generate_order_reference
--------------------------+--------------------------
 ORD-20260924-04821       | ORD-20260924-77390
```

Two calls in the *same* statement, *no arguments at all* (so "same inputs"
is trivially true), and two different results — the textbook `VOLATILE`
signature. `random()` itself is documented by PostgreSQL as `VOLATILE`,
which is exactly why any function that calls it must be `VOLATILE` too (see
the edge case in §20.7.6).

### 20.7.5 The Mistake: Mislabeling `IMMUTABLE`, and the Bug It Causes

> **⚠️ Warning — the most dangerous mistake in this chapter.** PostgreSQL
> does **not** verify that a function labeled `IMMUTABLE` actually behaves
> that way. It trusts the label completely. Mislabeling a
> database-dependent function as `IMMUTABLE` doesn't raise an error — it
> lets you build **incorrect optimizations, silently, on top of a false
> promise**, most dangerously an expression index that goes stale and never
> tells you.

Walk through the exact bug. Suppose a developer wants to index products by
their category *name* (not just `category_id`), and reaches for the lookup
function from §20.7.4 — but marks it `IMMUTABLE` "because it always returns
the same thing for the same `category_id`, right?":

```sql
-- WRONG: this function reads a mutable lookup table, but is mislabeled IMMUTABLE
CREATE OR REPLACE FUNCTION get_category_name_bad(p_category_id INT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE                                    -- LIE: category_name can change
AS $$
    SELECT category_name FROM categories WHERE category_id = p_category_id;
$$;

CREATE INDEX idx_products_category_name_bad
    ON products (get_category_name_bad(category_id));
```

> **Important Note.** This `CREATE INDEX` **succeeds only because of the
> mislabeling**. Had the function been correctly declared `STABLE` (as in
> §20.7.4), this exact statement would fail immediately with `ERROR:
> functions in index expression must be marked IMMUTABLE` — PostgreSQL's
> real safeguard against putting a non-deterministic-over-time expression
> into an index. Marking it `IMMUTABLE` is precisely what defeats that
> safeguard.

Now watch the bug appear:

```sql
-- Before any rename: correctly finds all 3 "Mobiles" products
SELECT product_id, product_name
FROM products
WHERE get_category_name_bad(category_id) = 'Mobiles';
```

| product_id | product_name |
|---|---|
| 1 | Galaxy Phone X |
| 2 | Pixel Lite |
| 9 | Wireless Earbuds |

```sql
-- The business renames the category:
UPDATE categories SET category_name = 'Smartphones' WHERE category_id = 2;

-- Logically, NO product should match 'Mobiles' anymore:
SELECT product_id, product_name
FROM products
WHERE get_category_name_bad(category_id) = 'Mobiles';
```

Because the planner believes the `IMMUTABLE` promise, it may satisfy this
`WHERE` clause using `idx_products_category_name_bad` — an index whose
entries were computed and stored **at the time each `products` row was
written**, and which PostgreSQL has no mechanism to re-derive just because
an unrelated table (`categories`) changed. Nothing about
`UPDATE categories ...` touches `products` rows, so nothing triggers the
index to recompute. The index still physically stores `'Mobiles'` for
`category_id = 2`, and a plan that trusts the index can return those 3
product rows — a result that is **now factually wrong**, and will stay
wrong until someone notices and runs `REINDEX`. Worse, this bug is
intermittent by nature: whether the planner actually chooses the stale
index for a given query depends on cost estimates that can change with
table size, `ANALYZE` statistics, or PostgreSQL version — so the same
"wrong" query might return correct results on a small test database and
wrong results in production, or correct results today and wrong results
after the table grows.

**The fix** is simply: label it correctly. The `STABLE` version from
§20.7.4 cannot be used in a functional index at all (PostgreSQL refuses at
`CREATE INDEX` time) — forcing the developer to solve the real problem
(denormalize `category_name` onto `products`, index the raw column instead,
or accept a plain non-indexed `JOIN` to `categories`) instead of building on
a broken shortcut.

### 20.7.6 Edge Case: a `STABLE`/`IMMUTABLE` Function That Calls a `VOLATILE` One

PostgreSQL does not check, at `CREATE FUNCTION` time, that your declared
volatility is consistent with what the function body actually calls. You
can absolutely mark a function `STABLE` while its body calls something
genuinely `VOLATILE`:

```sql
-- Edge case: this function lies about its own volatility
CREATE OR REPLACE FUNCTION get_order_summary_bad(p_order_id INT)
RETURNS TEXT
LANGUAGE sql
STABLE                                       -- WRONG: clock_timestamp() is VOLATILE
AS $$
    SELECT 'Order ' || p_order_id || ' summarized at ' || clock_timestamp();
$$;
```

`clock_timestamp()` — unlike `now()`/`CURRENT_TIMESTAMP`, which are fixed
for the whole transaction — advances on **every single call**, even within
one statement. By declaring the wrapper `STABLE`, you're telling the
planner it's safe to evaluate `get_order_summary_bad(5)` once and reuse
that value anywhere else the identical call `get_order_summary_bad(5)`
appears in the same query (e.g., once in the `SELECT` list and again in a
`WHERE` or `ORDER BY`). The planner is licensed to treat those two
call-sites as interchangeable and potentially reuse one evaluation for
both — but the real function, being secretly volatile, would have produced
two different timestamps if actually called twice. The result is a subtle,
plan-dependent inconsistency: the same logical "two calls" sometimes
silently collapse into one, and whether that happens depends on the exact
query shape and the PostgreSQL version's optimizer — a bug class that is
notoriously hard to reproduce because it depends on *how*, not just
*whether*, you called the function twice.

> **Important Note.** The general rule: **a function's declared volatility
> must be at least as restrictive as the volatility of everything it calls.**
> A function that calls anything `VOLATILE` must itself be `VOLATILE`. A
> function that only calls `STABLE`/`IMMUTABLE` things (and does no writes)
> may be `STABLE` or even `IMMUTABLE`, depending on whether it also touches
> the database.

### 20.7.7 Internal Behavior Summary

| | `IMMUTABLE` | `STABLE` | `VOLATILE` |
|---|---|---|---|
| Constant-folded at plan time (constant args) | Yes | No | No |
| Usable in an expression/functional index | **Yes — only this category** | No | No |
| Usable in a `CHECK` constraint / generated column | Yes | No (with narrow exceptions) | No |
| Result reused across multiple identical calls in one statement | Yes | Yes | No — called every time |
| Result reused across different statements | Yes | No | No |
| Must be called once per row when used per-row | No (may short-circuit) | Effectively yes, but may cache within the row's statement context | Yes, always |
| Default if unspecified | — | — | **This is the default** |

---

## 20.8 Function Inlining — Internal Behavior for `LANGUAGE SQL` Functions

A closely related planner behavior, specific to **`LANGUAGE sql`**
functions (not `plpgsql`): PostgreSQL can **inline** a simple SQL-language
function directly into the calling query, as if you had pasted its body in
by hand, instead of executing it as a separate, opaque call.

Inlining is possible when the function is `LANGUAGE sql`, its body is a
single SQL statement, it is not `SECURITY DEFINER`, and it has no attached
session-configuration (`SET ...`) clauses. When those conditions hold, the
planner substitutes the function's underlying query directly into the
outer query *before* optimization — which means:

- **Predicate pushdown works through it.** A `WHERE` clause applied to the
  outer call can be pushed down into the function's own internal query,
  potentially letting it use an index it otherwise couldn't.
- **Join reordering considers its internals.** The function's body stops
  being a black box and becomes just more query tree for the planner to
  optimize jointly with everything else.
- **`IMMUTABLE` SQL functions with constant arguments can be fully
  precomputed** at plan time, effectively vanishing from the executed plan.

`get_order_total` (§20.9.4 below) and `get_active_products` (§20.6.2) are
both inlining candidates precisely because they're single-statement
`LANGUAGE sql` functions.

**`plpgsql` functions are never inlined** — even a trivial one-line
`plpgsql` function is always executed as a separate, opaque call, once per
invocation the planner decides to make (per the volatility rules in
§20.7). This is a real, practical reason to prefer `LANGUAGE sql` over
`LANGUAGE plpgsql` for small, single-statement wrapper functions where
performance matters — `plpgsql`'s procedural flexibility (variables,
branching, loops, exceptions) comes at the cost of being permanently opaque
to the planner.

---

## 20.9 Function Security — `SECURITY DEFINER` vs. `SECURITY INVOKER`

### 20.9.1 Quick Recap from Chapter 19

Chapter 19 introduced `SECURITY DEFINER`/`SECURITY INVOKER` for procedures:
by default (`SECURITY INVOKER`), a routine runs with the privileges of
whoever calls it; `SECURITY DEFINER` makes it run with the privileges of
whoever *owns* it, regardless of who calls it. That mechanism is identical
for functions — nothing new to learn about the keyword itself. What's
worth focusing on here is a function-specific consequence: because
functions can be embedded *inside* arbitrary `SELECT` statements (unlike
procedures, which are only ever top-level `CALL`s), a `SECURITY DEFINER`
function can end up executing as a small, elevated-privilege island inside
a much larger query someone else wrote — making it even more important that
its logic is narrow, defensive, and doesn't trust its caller's intentions
implicitly.

### 20.9.2 Full Worked Example: Safe Self-Service Salary Lookup

**The problem:** `salaries` holds every employee's compensation history.
You don't want to `GRANT SELECT ON salaries` to ordinary employees — that
would let anyone see everyone's pay. But you *do* want each employee to be
able to look up their own current total compensation through the
application.

```sql
-- Ordinary employees have no direct access to the table at all:
REVOKE ALL ON salaries FROM employee_role;

CREATE OR REPLACE FUNCTION get_my_salary(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER                 -- runs as the function owner, who DOES have SELECT on salaries
STABLE
AS $$
DECLARE
    v_total_comp NUMERIC;
BEGIN
    -- Defensive check: the caller may only ask for THEIR OWN employee_id,
    -- read from a session variable the application sets after authentication.
    IF p_employee_id IS DISTINCT FROM current_setting('app.current_employee_id', true)::INT THEN
        RAISE EXCEPTION 'Access denied: you may only view your own salary.';
    END IF;

    SELECT base_salary + bonus
    INTO v_total_comp
    FROM salaries
    WHERE employee_id = p_employee_id
    ORDER BY effective_date DESC
    LIMIT 1;

    RETURN v_total_comp;
END;
$$;

-- Grant EXECUTE on the function only — never SELECT on the underlying table:
GRANT EXECUTE ON FUNCTION get_my_salary(INT) TO employee_role;
```

```sql
-- Application sets this per session, right after authenticating the user:
SET app.current_employee_id = '4';

SELECT get_my_salary(4);   -- Vikram checking his own salary: allowed
```

```
 get_my_salary
---------------
      152000.00
```

*(Vikram's latest row: `base_salary 140000 + bonus 12000`, effective
`2022-01-01` — the most recent of his two salary rows.)*

```sql
SELECT get_my_salary(5);   -- Vikram trying to look up Ananya's salary: denied
```

```
ERROR:  Access denied: you may only view your own salary.
```

*Line-by-line:* `employee_role` never receives `SELECT` on `salaries` at
all — the `REVOKE`/no-`GRANT` state means a query like
`SELECT * FROM salaries;` run directly by that role fails outright. The
**only** path to any salary data is through `get_my_salary`, which — thanks
to `SECURITY DEFINER` — executes with the function owner's (presumably an
admin/service role's) privileges internally, but wraps that elevated access
in an explicit, auditable check that rejects any `p_employee_id` other than
the caller's own. This is the general pattern for "safe controlled data
access": push the privilege boundary down into a narrow, reviewable
function instead of widening a table grant.

> **⚠️ Warning.** A `SECURITY DEFINER` function is only as safe as the code
> inside it. Forgetting the `IF ... RAISE EXCEPTION` check above would turn
> this into a function that lets **any** employee read **anyone's** salary,
> while still looking, from the outside, like a narrowly-scoped
> "self-service" API. Also pin the function's `search_path` explicitly
> (`SET search_path = pg_catalog, public` in the function definition) in
> real deployments — a `SECURITY DEFINER` function that resolves unqualified
> object names via a caller-influenced `search_path` is a classic
> privilege-escalation vector, covered in full in Chapter 27 (Security).

### 20.9.3 When to Reach for `SECURITY DEFINER` on a Function

Use it when you want to expose a **narrow, specific capability** (look up
your own salary; check whether a coupon code is valid; look up a masked
version of another user's contact info) without granting broad table
access. Prefer `SECURITY INVOKER` (the default) for the overwhelming
majority of functions — reporting functions, formatting helpers, business
computations — where there's no reason for the function to run with more
privilege than its caller already has.

---

## 20.10 Function Overloading

### 20.10.1 Simple Explanation

Overloading means two (or more) functions can share the same name, as long
as their parameter lists differ — the database picks the right one based on
how many arguments you pass, and of what types.

### 20.10.2 Example

```sql
CREATE OR REPLACE FUNCTION get_order_total(p_order_id INT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT SUM(quantity * unit_price)
    FROM order_items
    WHERE order_id = p_order_id;
$$;

CREATE OR REPLACE FUNCTION get_order_total(p_order_id INT, p_tax_rate NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT get_order_total(p_order_id) * (1 + p_tax_rate);
$$;
```

```sql
SELECT get_order_total(1);         -- resolves to the 1-argument version
SELECT get_order_total(1, 0.18);   -- resolves to the 2-argument version
```

| Call | Resolves to | Result |
|---|---|---|
| `get_order_total(1)` | `get_order_total(INT)` | `49498.00` |
| `get_order_total(1, 0.18)` | `get_order_total(INT, NUMERIC)` | `58407.64` |

*Line-by-line:* order 1's items are `product 1` (qty 1 @ 45999.00) and
`product 9` (qty 1 @ 3499.00), summing to `49498.00`. The two-argument
overload doesn't duplicate that logic — it **calls the single-argument
version** and multiplies by `(1 + tax_rate)`, giving `49498.00 × 1.18 =
58407.64`. This also demonstrates function composition: overloaded
functions of the same name can legally call each other's more-specific or
less-specific sibling.

### 20.10.3 How PostgreSQL Resolves Which Overload to Call

At call time, PostgreSQL matches the number of arguments first (an
immediate, unambiguous filter — a 2-argument call can never match a
1-argument function), then matches argument types, applying implicit casts
where needed (e.g., an untyped numeric literal will happily match either
`INT` or `NUMERIC` depending on which overload is otherwise viable). If
more than one candidate remains equally viable after casting rules are
applied, PostgreSQL raises `ERROR: function ... is not unique` rather than
silently guessing — ambiguous overloads are a hard error, not a
best-effort resolution.

> **⚠️ Warning — [MySQL] does not support function overloading at all.**
> MySQL (all current stable versions) treats a function name as globally
> unique in its schema — `CREATE FUNCTION get_order_total(...)` a second
> time, with any different parameter list, fails with
> `ERROR 1304: FUNCTION get_order_total already exists`. Code that relies
> on overloading (a very natural PostgreSQL/Oracle/SQL Server pattern) must
> be restructured for MySQL using distinct function names (e.g.,
> `get_order_total` and `get_order_total_with_tax`) or by using a single
> function with an optional parameter that has a sensible default.

| Dialect | Supports overloading by parameter signature? |
|---|---|
| **[PostgreSQL]** | Yes |
| **[Oracle]** | Yes (also supports overloading inside `PACKAGE`s, an Oracle-specific organizational unit) |
| **[SQL Server]** | Yes |
| **[MySQL]** | **No** — function names must be unique per schema regardless of parameter list |

---

## 20.11 Required Deep Dive: Procedure vs. Function, Precisely

This is the comparison every SQL developer eventually needs and rarely has
written down cleanly. Commit this table to memory.

| Dimension | `FUNCTION` | `PROCEDURE` |
|---|---|---|
| Callable from `SELECT`/inside an expression | **Yes** — `SELECT calculate_tenure_years(hire_date) FROM employees;` | **No** — must be invoked with a standalone `CALL proc_name(...);` statement |
| Can manage its own transaction (`COMMIT`/`ROLLBACK`) | **No** — a function always runs inside the transaction of its caller; it cannot commit or roll back independently | **Yes**, on PostgreSQL 11+ — a procedure may issue its own `COMMIT`/`ROLLBACK`, starting a fresh transaction afterward (Chapter 19) |
| Return mechanism | A `RETURNS` clause: scalar, composite, `TABLE`, `SETOF`, or `VOID` | `OUT`/`INOUT` parameters only — there is no `RETURNS` clause at all |
| Typical use case | Reusable computed values, validation predicates for `WHERE`/`CHECK`, reusable row/table shaping logic meant to be composed into larger queries | Multi-step business processes, batch/ETL jobs, anything that needs to commit partial progress, orchestration that calls several other routines |
| Must always produce output | Yes — every code path must `RETURN` something (or the function errors at runtime, §20.4.5) | No — a procedure with no `OUT` parameters simply performs actions and returns nothing to report |

### Dialect Notes — Where the Line Blurs

| Dialect | How the function/procedure line differs from PostgreSQL/Oracle's clean split |
|---|---|
| **[PostgreSQL]** | Cleanest split of the four: functions never manage transactions (no exceptions); procedures can, starting with version 11. This chapter and Chapter 19 describe this canonical model. |
| **[Oracle]** | Also maintains the split (functions can't commit/rollback when called from an SQL statement; standalone `PROCEDURE`s can) — but Oracle additionally enforces **purity rules** on functions called from within SQL: such a function is restricted from modifying database state at all when invoked in that context (enforced via `PRAGMA RESTRICT_REFERENCES` in older code, or automatically checked in modern PL/SQL), because SQL's read-consistency model doesn't tolerate a function silently mutating data mid-query. |
| **[MySQL]** | Functions **also** cannot manage transactions (no `COMMIT`/`ROLLBACK` inside a `FUNCTION` body — same restriction as PostgreSQL). MySQL additionally restricts **non-deterministic statements inside functions when binary logging is active**: a function must be declared `DETERMINISTIC`, `NO SQL`, or `READS SQL DATA` to be created at all under the default `binlog_format` settings; otherwise `CREATE FUNCTION` fails with an error pointing at `log_bin_trust_function_creators`, because statement-based replication can't safely replay a function whose result might differ on the replica. This is MySQL's closest analogue to PostgreSQL's `VOLATILE`/`STABLE`/`IMMUTABLE` system, though it's framed around replication safety rather than planner optimization. |
| **[SQL Server]** | Historically blurs the line the *other* direction: T-SQL functions (scalar and table-valued) are **more restrictive** than PostgreSQL's — they cannot perform `INSERT`/`UPDATE`/`DELETE` on physical (non-table-variable) tables at all, cannot execute dynamic SQL, and cannot call most non-deterministic built-ins (like `GETDATE()`) in contexts requiring determinism (e.g., a function backing a persisted computed column). Stored procedures, in contrast, can do all of that, plus manage transactions freely with `BEGIN TRAN`/`COMMIT`/`ROLLBACK`. So while PostgreSQL/Oracle draw the line mainly at "can you commit," SQL Server additionally draws it at "can you touch real tables or run dynamic SQL at all." |

---

## 20.12 Function vs. Procedure vs. View vs. Plain Query — When to Use What

| Tool | Reusable? | Parameterized? | Usable inside `SELECT`/`JOIN`? | Procedural logic (branching, loops)? | Own transaction control? | Best for |
|---|---|---|---|---|---|---|
| Plain ad hoc query | No | No (hand-edit each time) | N/A | No | N/A | One-off analysis, exploration |
| `VIEW` | Yes | No (fixed query; can be filtered from outside) | Yes — behaves like a table | No | N/A | A saved, named, reusable `SELECT` that always reflects live underlying data — see Chapter 15 |
| `FUNCTION` (scalar/table-valued) | Yes | Yes | **Yes** — this is its defining advantage | Yes (`plpgsql`) | **No** | Computed business metrics, reusable validation predicates, parameterized row/table shaping meant to be composed into other queries |
| `PROCEDURE` | Yes | Yes | No — `CALL` only | Yes (`plpgsql`) | **Yes** (PG 11+) | Multi-step business processes, batch jobs, anything needing partial commits or orchestration across multiple operations |

Rule of thumb: if the answer to "could I imagine writing `SELECT ...
this_thing(...) ... FROM ...`" is yes, it's a function. If the answer is
"no, this is a standalone action/process," it's a procedure. If it's just a
saved, parameterless-from-the-inside query you want to reuse and always see
fresh, it's a view.

---

## 20.13 Common Mistakes and Edge Cases — Roundup

- **Mislabeling volatility** (§20.7.5) — the single most damaging mistake in
  this chapter; produces silently wrong results, not errors.
- **Missing `RETURN` on every code path** (§20.4.5) — a runtime error
  (`control reached end of function without RETURN`), not a compile-time
  one; test every branch, especially `ELSE`/fallthrough cases.
- **A `STABLE`/`IMMUTABLE` function that calls a `VOLATILE` one internally**
  (§20.7.6) — PostgreSQL never checks this for you; the inconsistency it
  causes is plan-dependent and easy to miss in testing.
- **Assuming overloading works identically everywhere** — it doesn't; see
  the MySQL warning in §20.10.3.
- **Forgetting `SECURITY DEFINER` functions run with elevated privilege
  regardless of what a malicious or careless caller passes in** — always
  validate inputs defensively inside the function body itself (§20.9.2);
  never assume the caller is well-behaved just because they can only reach
  the function, not the table.
- **Reaching for `LANGUAGE plpgsql` out of habit for a trivial one-line
  computation** — a simple `LANGUAGE sql` function is often inlinable
  (§20.8) and therefore cheaper and more planner-friendly than an
  equivalent `plpgsql` version that will never be inlined.
- **Using a function where a view (or a plain query) would do** — if there's
  no parameter, no procedural branching, and no need to compose it inside
  other queries beyond what a view already offers, a function adds
  unnecessary indirection.

---

## 20.14 Real-World Use Cases

- **Computed business metrics.** `calculate_tenure_years`, `get_order_total`
  — turning a raw column into a business-meaningful number, reusable
  across every report and dashboard query that needs it, instead of
  re-deriving the same expression in a dozen places.
- **Reusable validation logic.** A scalar `BOOLEAN`-returning function
  (e.g., `is_valid_discount_code(p_code TEXT)`) usable directly in a `CHECK`
  constraint (if `IMMUTABLE`), an application-layer `WHERE` filter, or a
  trigger (Chapter 22) — one implementation, enforced everywhere instead of
  duplicated across the application and the database.
- **Safe, controlled data access.** The `get_my_salary` pattern (§20.9.2) —
  narrow, auditable, `SECURITY DEFINER` functions that expose exactly the
  slice of sensitive data a caller needs, without widening table-level
  grants.
- **Parameterized reporting.** `get_department_roster`,
  `get_active_products` — table-valued functions that replace a family of
  near-identical hand-written queries ("roster for department 1," "roster
  for department 2," ...) with one parameterized, testable, indexable unit.
- **Reusable set-generation utilities.** `unnest()`-style helpers for
  turning arrays, ranges, or generated sequences into query-able rows —
  the same mechanism behind calendar-table generation, tag-expansion, and
  bulk-parameter APIs.

---

## 20.15 Practice Questions

1. Explain, precisely, why `IMMUTABLE` functions may be used in an
   expression/functional index but `STABLE` functions may not, even though
   both promise "no side effects." What specifically does `IMMUTABLE` add
   that `STABLE` doesn't?
2. Write a scalar function `get_department_headcount(p_department_id INT)
   RETURNS INT` against `company_db` that counts active (`status =
   'ACTIVE'`) employees in a department. What is the correct volatility
   label for this function, and why?
3. A colleague marks a function `IMMUTABLE` because "it only does math, no
   table access" — but the math includes a call to `random()`. Explain
   exactly what will go wrong, and where in the planner's behavior the
   wrongness would actually surface.
4. Rewrite `get_department_roster` (§20.5.4) so that instead of
   `RETURNS TABLE (...)`, it uses `RETURNS SETOF employees`. What has to
   change about the function body, and what's lost by making this switch
   (hint: `full_name` isn't a real column)?
5. Explain the difference between a function marked `STRICT` and one using
   the default `CALLED ON NULL INPUT`. Give an example of a function where
   `STRICT` would silently produce the wrong behavior if the function is
   actually meant to treat `NULL` as meaningful input (e.g., "no manager").
6. You need a function that both looks up an employee's current salary
   *and* logs the fact that someone queried it, for audit purposes. Should
   this be a `FUNCTION` or a `PROCEDURE`? Justify your answer using the
   comparison table in §20.11.
7. Write two overloaded functions, both named `apply_discount`: one
   accepting `(p_price NUMERIC)` that applies a flat 10% discount, and one
   accepting `(p_price NUMERIC, p_percent NUMERIC)` that applies a custom
   percentage. Show the calls that resolve to each.
8. **[MySQL]** A team wants to port the `get_order_total` overload pair
   from §20.10.2 to MySQL. Explain why the direct port fails, and propose
   two different ways to restructure it for MySQL.
9. A `SECURITY DEFINER` function you wrote to let employees view their own
   attendance record is discovered to also let them view *anyone's*
   attendance record if they pass a different `employee_id`. What is the
   most likely missing piece of code, based on the pattern in §20.9.2?
10. Explain why a `LANGUAGE plpgsql` function performing a single `SELECT`
    with no branching is never inlined by the planner, while an equivalent
    `LANGUAGE sql` function is a strong inlining candidate. What concrete
    optimization opportunities does the `plpgsql` version lose as a
    result?
11. Design a `TABLE`-valued function `get_low_stock_products(p_warehouse
    VARCHAR)` against `ecommerce_db.inventory` that returns every product
    in a given warehouse where `quantity_on_hand < reorder_level`. What
    columns would you include in the `RETURNS TABLE(...)` clause, and what
    volatility would you assign?

---

## 20.16 Chapter Challenge

**Build `get_top_products` — a table-valued function using a window
function internally.**

Using `ecommerce_db`, write:

```sql
CREATE OR REPLACE FUNCTION get_top_products(p_category_id INT, p_top_n INT)
RETURNS TABLE (
    product_id          INT,
    product_name        TEXT,
    total_quantity_sold BIGINT,
    sales_rank          BIGINT
)
...
```

Requirements:

1. Only consider products belonging to `p_category_id` (join
   `order_items → products`, filtered on `products.category_id`).
2. Compute `total_quantity_sold` as the `SUM(quantity)` across all matching
   `order_items` rows for each product.
3. Rank products **within the category** by `total_quantity_sold`
   descending, using a window function — `RANK()` or `ROW_NUMBER()` (cross
   reference **Chapter 10 — Window Functions**) — assigned as
   `sales_rank`. Remember that a window function is computed *after*
   aggregation, so you'll need a CTE or subquery: aggregate first, rank
   second.
4. Return only the top `p_top_n` products by that rank.
5. Choose and justify a tiebreaker for products with identical
   `total_quantity_sold` (recall Chapter 4's lesson on why an
   `ORDER BY`/window `ORDER BY` needs a deterministic tiebreaker to avoid
   unspecified ordering among ties).

**Verify your function** against category 2 (Mobiles: products 1, 2, 9)
with `p_top_n = 2`, counting quantities across *all* `order_items`
regardless of order status:

```sql
SELECT * FROM get_top_products(2, 2);
```

| product_id | product_name     | total_quantity_sold | sales_rank |
|---|---|---|---|
| 9 | Wireless Earbuds | 4 | 1 |
| 1 | Galaxy Phone X   | 2 | 2 |

*(Product 2, Pixel Lite, has only 1 unit sold across all `order_items` and
correctly falls outside the top 2.)*

**Bonus design question:** order 5 (the only order containing product 2)
has `status = 'CANCELLED'`. Should a cancelled order's items count toward
"best-selling"? The verification table above deliberately counts them (the
simplest interpretation). Modify your function to exclude `CANCELLED`
orders instead, re-run it, and compare — does the top-2 list change for
category 2? Which interpretation would you ship to production, and why?

---

## Key Takeaways

- A function's defining superpower over a procedure is being usable
  **inside** SQL expressions — `SELECT`, `WHERE`, `JOIN` — because it
  returns a value the query can consume; a procedure can only be `CALL`ed
  standalone.
- `RETURNS TABLE(...)` is convenient syntax for an ad hoc, inline row
  shape; `RETURNS SETOF sometype` is the more general mechanism requiring
  an already-existing type. Both are populated with `RETURN QUERY`/`RETURN
  NEXT`, and `unnest()` is a built-in example of the same `SETOF`
  mechanism you already rely on.
- Volatility (`IMMUTABLE`/`STABLE`/`VOLATILE`) is a declared contract, not
  something PostgreSQL verifies — mislabeling it doesn't error, it produces
  silently incorrect results, most dangerously through a stale expression
  index built on a falsely `IMMUTABLE` function.
- Only `IMMUTABLE` functions may be used in an expression/functional index
  or a `CHECK` constraint — `STABLE` is not sufficient, even though both
  forbid database writes.
- `LANGUAGE sql` functions can be inlined into the calling query by the
  planner; `LANGUAGE plpgsql` functions never are — a real performance
  consideration when choosing between the two for simple logic.
- `SECURITY DEFINER` lets a function safely expose a narrow slice of
  otherwise-restricted data, but the function's own internal checks are the
  *entire* security boundary — validate defensively.
- PostgreSQL, Oracle, and SQL Server support function overloading by
  parameter signature; MySQL does not, and requires distinct function
  names instead.
- The procedure/function line is drawn slightly differently across
  dialects: PostgreSQL/Oracle split cleanly on transaction control; MySQL
  denies both transaction control *and* certain non-deterministic
  statements in functions (for replication safety); SQL Server additionally
  denies functions physical-table writes and dynamic SQL outright.

## What's Next

Functions and procedures both operate on whole result sets or single
computed values — but sometimes you genuinely need to process a query's
result **row by row**, imperatively, inside procedural code. Chapter 21
introduces cursors: explicit and implicit, how they relate to the
`RETURN QUERY`/`FOR ... IN SELECT` loops you've already used informally in
this chapter and Chapter 19, and — critically — when a set-based query
(the preference of nearly every chapter so far) is the better answer, and a
cursor is not.

**Next:** [Chapter 21 — Cursors](21-cursors.md)
