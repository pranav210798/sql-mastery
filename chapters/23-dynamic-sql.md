# Chapter 23 — Dynamic SQL & Injection Safety

> **Part VI — Database Internals & Production Engineering**
> Previous: [Chapter 22 — Triggers](22-triggers.md) · Next: [Chapter 24 — Temporary Tables](24-temporary-tables.md)

> **Prerequisite:** This chapter assumes [Chapter 19 — Stored Procedures](19-stored-procedures.md).
> Chapter 19 briefly used `EXECUTE`/`format()` inside one procedure so that
> example could work; this chapter treats **dynamic SQL** as a complete topic
> in its own right — what it is, why plain bind parameters cannot replace it
> for certain problems, and, most importantly, how to write it without opening
> a SQL injection hole. If you have not run the sample databases yet:

```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
```

This chapter runs primarily against `ecommerce_db`, with a couple of
utility examples general enough to run against either database. Dialect:
**PostgreSQL** primary (PL/pgSQL), with **[MySQL]**, **[Oracle]**, and
**[SQL Server]** call-outs wherever the mechanism diverges.

---

## Learning Objectives

By the end of this chapter you will be able to:

- Explain precisely why a bind parameter can stand in for a *value* but never
  for an *identifier* (table name, column name, `ORDER BY` target) — the
  single fact that makes dynamic SQL necessary at all
- Use `EXECUTE`, `EXECUTE ... INTO`, and `EXECUTE ... USING` correctly in
  PL/pgSQL
- Use `format()` with `%I`, `%L`, and `%s`, and the standalone
  `quote_ident()` / `quote_literal()` functions, to build SQL text safely
- Identify, reproduce, and explain a SQL injection vulnerability in a
  hand-rolled dynamic SQL function
- Fix an injectable function using `USING` (for values) and `%I`/`quote_ident()`
  (for identifiers)
- Build a safe, generic "count any table," "distinct values of any column,"
  and "flexible product search" utility
- Explain why dynamic SQL forfeits query plan caching, and when that
  trade-off is (and isn't) worth it
- Build a safe, allow-list-validated, dynamically sortable/filterable report
  function

---

## 23.1 What Dynamic SQL Is

### Simple explanation

Every query you've written so far in this course has its structure fixed
the moment you write it: the table names, the column names, and the shape of
the `WHERE` clause are all typed out in the source. Only the *values* change
between runs — a `$1` parameter, an argument to a function. **Dynamic SQL**
is what you reach for when even the *structure* of the query needs to change
at runtime: when you don't know, until the code is actually running, which
table to query, which column to sort by, or which combination of filters
the caller wants applied.

Think of the difference between a form letter with blanks for a name and
address (static SQL with parameters — the letter's wording never changes,
only the filled-in blanks) versus a letter that is *typed from scratch* each
time, because which paragraphs it contains depends on who's receiving it
(dynamic SQL — the text itself is assembled per call).

### Technical explanation

Dynamic SQL is the practice of **constructing a SQL statement as a string
value inside your program (or procedure) at runtime, and then explicitly
handing that string to the database engine to be parsed, planned, and
executed** — as opposed to writing a SQL statement directly in your source
that the engine parses and plans once when the enclosing function/procedure
is compiled (or once per prepared statement, in the client-driver sense).

In PL/pgSQL, this "hand it to the engine" step is the `EXECUTE` statement.
A static SQL statement embedded directly in a function body (`SELECT ...
INTO v_result FROM orders WHERE order_id = p_id;`) is checked for basic
syntax validity when the function is created, and PostgreSQL's planner
builds an execution plan for it using the normal query-planning machinery
tied to the function's cached plan. A dynamic statement built as text
(`v_sql := 'SELECT ... FROM ' || v_table_name; EXECUTE v_sql;`) is invisible
to that mechanism entirely — as far as PostgreSQL is concerned at
function-creation time, `v_sql` is just a `TEXT` variable holding whatever
characters end up in it. Parsing and planning happen only when `EXECUTE`
actually runs, against whatever string is in the variable *at that moment*.

### Why it's needed — the core reason, precisely

This is the single fact the rest of the chapter builds on, so state it
exactly:

> **A bind parameter (`$1`, `USING`, a placeholder `?`) can only ever stand
> in for a VALUE — a piece of data being compared, inserted, or computed
> with. It can never stand in for an IDENTIFIER — a table name, a column
> name, or a schema name — because identifiers are part of the SQL
> statement's *grammar*, not its *data*. The query planner needs to know
> which table and columns it's dealing with in order to parse the statement
> at all, long before any parameter values are supplied.**

Try to write this with a plain parameter and watch it fail conceptually
before you even run it:

```sql
-- This is NOT valid — you cannot parameterize a table name or column name.
PREPARE bad_idea AS
SELECT * FROM $1 WHERE $2 = $3;
```

PostgreSQL cannot plan this statement, because until it knows what `$1`
*is*, it doesn't know what columns exist, what indexes are available, or
even whether `$2` is a valid column reference — the entire shape of the
query is undetermined. Contrast that with a parameter standing in for a
value, which is completely fine because the shape of the query never
changes, only the data being compared:

```sql
-- This is valid. The TABLE and COLUMN are fixed; only the VALUE varies.
PREPARE good_idea AS
SELECT * FROM ecommerce_db.orders WHERE status = $1;
```

There are exactly four categories of problem that force you into dynamic
SQL, because each one requires varying something a bind parameter cannot
touch:

| Problem | Why a bind parameter can't solve it |
|---|---|
| Table name varies at runtime (e.g., per-tenant tables, admin tool that queries "any table") | Table identity must be known before the query can be parsed/planned |
| Column name varies at runtime (e.g., generic "get distinct values of column X") | Same reason — column identity is part of the query's grammar |
| `ORDER BY` column/direction chosen by the caller | `ORDER BY` targets a column reference, which is an identifier, not a value |
| A variable-length `IN (...)` list | The number of comma-separated value slots itself varies — a fixed parameterized statement has a fixed number of `$n` placeholders |
| An arbitrary combination of optional filters (a flexible search/report endpoint) | The number and shape of `WHERE` conditions changes per call, not just their values |

> **Important Note:** Dynamic SQL is not "SQL that changes." Every
> parameterized query changes its *behavior* per call by accepting different
> values — that's normal and doesn't require dynamic SQL. Dynamic SQL is
> specifically for when the *text* of the statement itself must differ
> between calls, because something other than a value needs to vary.

---

## 23.2 The `EXECUTE` Statement in PL/pgSQL

### Simple explanation

`EXECUTE` is the command that says "here is a string — treat it as SQL and
run it right now." Everything else in this chapter is about building that
string safely and getting results back out of it.

### Technical explanation

`EXECUTE` takes an expression that evaluates to `TEXT`, hands it to the SQL
parser/planner/executor as if it had been submitted directly, and (optionally)
routes returned data into variables. It exists as a distinct PL/pgSQL
statement — separate from writing SQL directly in the function body —
precisely because PL/pgSQL needs an explicit signal that "this text is not
known until runtime; parse and plan it now, not when the function was
created."

### Full syntax

```plpgsql
-- 1. Fire-and-forget: run the statement, discard/ignore any result set
EXECUTE sql_string;

-- 2. Capture a single-row result into variable(s)
EXECUTE sql_string INTO variable [, variable2, ...];
EXECUTE sql_string INTO STRICT variable;   -- error if not exactly one row

-- 3. Bind parameter values safely (the key safety mechanism — see §23.4)
EXECUTE sql_string USING value1 [, value2, ...];

-- 4. INTO and USING combine freely
EXECUTE sql_string INTO variable USING value1, value2;

-- 5. Returning a full result set from a set-returning function
RETURN QUERY EXECUTE sql_string [USING value1, ...];
```

- `sql_string` — any expression producing `TEXT`: a literal, a variable, or
  (most commonly) the result of `format(...)`.
- `INTO variable` — works exactly like static `SELECT ... INTO`: the dynamic
  statement must return at most one row, and each output column populates
  one variable positionally.
- `USING value1, value2, ...` — the values are bound as `$1`, `$2`, ...
  inside `sql_string`, **exactly like a parameterized query**. This is not
  string interpolation; the text of `sql_string` is fixed and parsed first,
  and the `USING` values are supplied to the executor as data afterward.
- `RETURN QUERY EXECUTE` — used inside a function that returns `SETOF`
  something, to stream every row the dynamic query produces back to the
  caller, instead of capturing just one row with `INTO`.

### Examples, simple → complex

```plpgsql
-- 1. Simplest possible dynamic SQL: a fixed string, no variation at all
--    (contrived — you'd never actually do this; it's here to show the
--     bare mechanics before anything gets dynamic)
DO $$
BEGIN
    EXECUTE 'SELECT 1';
END;
$$;
```

```plpgsql
-- 2. Capture a computed value with INTO
DO $$
DECLARE
    v_count BIGINT;
BEGIN
    EXECUTE 'SELECT count(*) FROM ecommerce_db.orders' INTO v_count;
    RAISE NOTICE 'Order count: %', v_count;
END;
$$;
```
```
NOTICE:  Order count: 10
```

```plpgsql
-- 3. Bind a VALUE safely with USING — the table/column are fixed in the
--    string, only the comparison value is supplied dynamically
DO $$
DECLARE
    v_status TEXT := 'DELIVERED';
    v_count  BIGINT;
BEGIN
    EXECUTE 'SELECT count(*) FROM ecommerce_db.orders WHERE status = $1'
        INTO v_count
        USING v_status;
    RAISE NOTICE 'Delivered orders: %', v_count;
END;
$$;
```
```
NOTICE:  Delivered orders: 5
```

```plpgsql
-- 4. Vary the STRUCTURE (table name) — this is where dynamic SQL earns
--    its keep, because $1 could never stand in for "orders" here
DO $$
DECLARE
    v_table TEXT := 'orders';
    v_count BIGINT;
BEGIN
    EXECUTE format('SELECT count(*) FROM ecommerce_db.%I', v_table)
        INTO v_count;
    RAISE NOTICE 'Row count in %: %', v_table, v_count;
END;
$$;
```
```
NOTICE:  Row count in orders: 10
```

### Line-by-line (example 4)

- `v_table TEXT := 'orders'` — an ordinary variable; in a real utility
  function this would be a parameter supplied by the caller.
- `format('SELECT count(*) FROM ecommerce_db.%I', v_table)` — builds the
  SQL text. `%I` (covered fully in §23.3) tells `format()` to treat
  `v_table`'s value as an **identifier**: quote it correctly and escape it
  if needed, rather than treating it as a plain substring.
- `EXECUTE ... INTO v_count` — the built string is parsed and planned for
  the first time right here, at this specific call, then executed, and its
  single returned row/column is placed into `v_count`.

### Internal behavior

Every `EXECUTE` of a dynamic string triggers PostgreSQL's full parse →
rewrite → plan → execute pipeline for that exact string, via `SPI_execute`
under the hood (the same internal interface PL/pgSQL uses for every SQL
statement, static or dynamic). For a **static** query written directly in a
function body, PostgreSQL still parses it once (at function creation, for
syntax) and plans it per-session the first time the function runs, then
**caches that plan** for reuse on subsequent calls in the same session
(this is the "generic plan" / "custom plan" caching PL/pgSQL performs
automatically). For a **dynamic** `EXECUTE`, no such caching happens by
default — a new string can be different every single call, so PostgreSQL
has no reusable plan to fall back on; the engine must assume the text might
be different every time and re-parse/re-plan from scratch on every
invocation, even if in practice the text turns out identical to last time.
This is a real, measurable performance cost — covered in depth in §23.8 —
and it is the primary reason dynamic SQL should be reserved for problems
that genuinely require it (§23.1's four categories), not used as a default
style of writing queries.

---

## 23.3 Building SQL Text Safely: `format()`, `quote_ident()`, `quote_literal()`

### Simple explanation

If dynamic SQL means "build a string, then run it," then the single most
important skill in this chapter is *how* you build that string without
accidentally letting a piece of data change the *meaning* of the SQL rather
than just its *content*. PostgreSQL gives you purpose-built tools for this:
`format()` with special placeholders, and two standalone escaping functions.

### Technical explanation

- **`format(format_string, arg1, arg2, ...)`** — works like `printf`/string
  interpolation, but with placeholders that are SQL-aware:
  - `%s` — plain string substitution, **no escaping at all**. Treats the
    argument as literal text to insert as-is. Safe only for values you
    already fully control (e.g., a hardcoded keyword you wrote yourself),
    never for anything derived from user input.
  - `%I` — **identifier** placeholder. Wraps the argument in double quotes
    and escapes any embedded double quotes by doubling them, exactly as
    PostgreSQL requires for a quoted identifier. Use this for table names,
    column names, schema names — anything that needs to be a valid,
    unambiguous SQL identifier.
  - `%L` — **literal** placeholder. Wraps the argument in single quotes,
    escapes embedded single quotes (and backslashes, if `standard_conforming_strings`
    is off), and renders `NULL` correctly for actual SQL `NULL` values. Use
    this for *values* when, for some structural reason, you cannot use
    `USING` (see the callout below — this should be rare).
- **`quote_ident(text)`** — a standalone function doing exactly what `%I`
  does: given any string, returns it as a properly double-quoted, escaped
  SQL identifier (or unquoted, if it's already a safe lowercase simple
  identifier that needs no quoting at all).
- **`quote_literal(text)`** — a standalone function doing exactly what `%L`
  does: given any string, returns it as a properly single-quoted, escaped
  SQL string literal.

### Why they exist

Because naive string concatenation (`'...' || user_value || '...'`) has no
concept of "this is untrusted data" — it just glues characters together.
If `user_value` itself contains a quote character, a semicolon, or SQL
keywords, concatenation happily lets that content merge into the
surrounding SQL grammar. `%I`/`quote_ident()` and `%L`/`quote_literal()`
exist to make that impossible for identifiers and literals respectively, by
always producing a self-contained, correctly delimited token no matter what
characters the input contains.

### Full syntax and behavior

```sql
-- %I / quote_ident(): identifier escaping
SELECT quote_ident('products');                       --> products            (no quoting needed)
SELECT quote_ident('Products');                        --> "Products"          (mixed case needs quoting)
SELECT quote_ident('order date');                      --> "order date"        (space needs quoting)
SELECT quote_ident('products"; DROP TABLE users; --'); --> "products""; DROP TABLE users; --"

-- %L / quote_literal(): value escaping
SELECT quote_literal('Galaxy Phone X');                --> 'Galaxy Phone X'
SELECT quote_literal(E'O''Brien');                     --> 'O''Brien'          (embedded quote doubled)
SELECT quote_literal('x''; DROP TABLE products; --');  --> 'x''; DROP TABLE products; --'

-- format() combining both
SELECT format('SELECT * FROM %I WHERE product_name = %L', 'products', 'Galaxy Phone X');
--> SELECT * FROM products WHERE product_name = 'Galaxy Phone X'
```

Look closely at the last `quote_ident()` example:
`products"; DROP TABLE users; --` is a deliberately hostile string
pretending to be a table name. `quote_ident()` does not try to detect or
reject it — it simply does its one job, faithfully: wrap the *entire*
input in double quotes, doubling any embedded double quote so it can never
terminate the quoting early. The result, `"products""; DROP TABLE users; --"`,
is one single (bizarre, 34-character) **identifier name**, syntactically
inert as SQL — if you actually use it as a table name, PostgreSQL will look
for a table literally named that and fail with `relation "products""; DROP
TABLE users; --" does not exist`, never touching the real `users` table.
The semicolon and `DROP TABLE` never escape the identifier's quotes to
become their own statement. That's the entire safety guarantee: **it makes
injected syntax structurally impossible to break out of the quoting**, not
by inspecting the string for "bad words."

> **⚠️ Warning — `%I`/`quote_ident()` guarantee syntactic safety, not
> semantic safety.** They guarantee the resulting identifier can never break
> out of its quotes to inject extra SQL. They do **not** guarantee that the
> identifier refers to a table/column you actually intended to allow. If
> your function does `EXECUTE format('SELECT * FROM %I', p_table_name)` and
> `p_table_name` is attacker- or caller-controlled with no further
> restriction, a value like `'payment_methods_internal'` or
> `'employee_salaries'` is **completely safe from injection** and will
> happily run — because it's a real, valid identifier, just not one you
> meant to expose. This is why an **allow-list** (checking the identifier
> against a fixed, known-good set before using it) is a separate, additional
> control on top of `%I`/`quote_ident()`, not a substitute for it. The
> chapter challenge (§23.16) builds exactly this.

> **Important Note — prefer `USING` over `%L` for values.** `%L` exists for
> cases where a value must be embedded directly into text you're also
> manipulating as a string (for example, building a default clause inside a
> dynamically generated `CREATE TABLE` statement, where `USING` isn't
> available because `CREATE TABLE` isn't a parameterizable DML statement).
> For ordinary `SELECT`/`INSERT`/`UPDATE`/`DELETE` dynamic SQL, `EXECUTE ...
> USING` is strictly better than `%L`: it hands the value to the executor as
> real bound data (never re-parsed as text at all), it avoids a whole class
> of subtle type-formatting bugs (see §23.9), and it's what lets PostgreSQL
> potentially reuse work across parameter values. Treat `%L` as a documented
> last resort, not a first choice.

---

## 23.4 SQL Injection: Unsafe vs. Safe Dynamic SQL

This is the centerpiece of the chapter. Everything above exists in service
of getting this exactly right.

### 23.4.1 An UNSAFE function

Here is a "search products by exact name" function, written the way
someone reaches for it instinctively — by gluing the parameter straight
into the SQL text:

```plpgsql
-- ⚠️ DO NOT USE — vulnerable to SQL injection. Shown for teaching purposes.
CREATE OR REPLACE FUNCTION ecommerce_db.find_product_by_name_unsafe(p_name TEXT)
RETURNS SETOF ecommerce_db.products
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql TEXT;
BEGIN
    v_sql := 'SELECT * FROM ecommerce_db.products WHERE product_name = ''' || p_name || '''';
    RETURN QUERY EXECUTE v_sql;
END;
$$;
```

Called normally, it looks completely reasonable:

```sql
SELECT * FROM ecommerce_db.find_product_by_name_unsafe('Galaxy Phone X');
```

The generated string is:
```sql
SELECT * FROM ecommerce_db.products WHERE product_name = 'Galaxy Phone X'
```
...and it returns the one matching row. Nothing looks wrong — until someone
supplies input that was never meant to be *just data*.

### 23.4.2 The attack, walked through exactly

**Attack 1 — filter bypass (`OR '1'='1'`).** Call the function with:

```sql
SELECT * FROM ecommerce_db.find_product_by_name_unsafe($$x' OR '1'='1$$);
```

`p_name` now holds the literal text `x' OR '1'='1`. Watch what
concatenation does to it, character by character:

```
'SELECT * FROM ecommerce_db.products WHERE product_name = ''' || p_name || ''''
```
becomes
```
SELECT * FROM ecommerce_db.products WHERE product_name = 'x' OR '1'='1'
```

The single quote inside `p_name` was supposed to be *data* — part of the
name being searched for — but concatenation placed it directly in the SQL
text, where it acts as a real quote character. It **closes** the string
literal that was opened right before `x`. Everything after that closing
quote is no longer inside a string at all; it is parsed as ordinary SQL:
`OR '1'='1'` becomes a second condition, always true, `OR`'d onto the
first. The `WHERE` clause is now `product_name = 'x' OR '1'='1'`, which is
true for **every row in the table**, regardless of `product_name`. The
function silently returns the entire `products` table instead of "no
match," even though `'x'` matches nothing.

**Attack 2 — stacked statement (`'; DROP TABLE ...; --`).** Call it with:

```sql
SELECT * FROM ecommerce_db.find_product_by_name_unsafe(
    $$nonexistent'; DROP TABLE ecommerce_db.products; --$$
);
```

The generated string becomes:
```sql
SELECT * FROM ecommerce_db.products WHERE product_name = 'nonexistent'; DROP TABLE ecommerce_db.products; --'
```

Trace it exactly:
1. `'nonexistent'` closes cleanly as a normal (harmless, non-matching)
   string literal — the first `SELECT` statement is now syntactically
   complete.
2. The `;` that follows is not inside any string — it is a genuine
   statement terminator.
3. `DROP TABLE ecommerce_db.products;` is now parsed as a **second,
   independent SQL statement**.
4. The trailing `--'` comments out the stray leftover quote from the
   original template, so nothing downstream fails on unbalanced quotes.

Because `EXECUTE` in PL/pgSQL runs the entire string through `SPI_execute`,
which — like PostgreSQL's simple query protocol — accepts and runs
multiple `;`-separated statements in one call, **both statements execute**.
The function that was supposed to only ever run a read-only `SELECT` has
just dropped the `products` table.

> **⚠️ WARNING — this is the single most important lesson in this chapter.**
> The vulnerability was never "not validating the input for bad words."
> It was **concatenating a runtime value directly into a SQL string that is
> then executed**. There is no reliable blocklist of "dangerous characters"
> or "dangerous words" — legitimate product names can contain apostrophes
> (`O'Brien's Coffee Table`), and attackers don't need recognizable keywords
> to break things. The fix is structural, not a filter: **never build
> executable SQL text by concatenating a value into it.**

### 23.4.3 The SAFE fix — `EXECUTE ... USING`

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.find_product_by_name_safe(p_name TEXT)
RETURNS SETOF ecommerce_db.products
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE 'SELECT * FROM ecommerce_db.products WHERE product_name = $1'
        USING p_name;
END;
$$;
```

Run the exact same attacks against it:

```sql
SELECT * FROM ecommerce_db.find_product_by_name_safe($$x' OR '1'='1$$);
-- returns zero rows: no product is literally named  x' OR '1'='1

SELECT * FROM ecommerce_db.find_product_by_name_safe(
    $$nonexistent'; DROP TABLE ecommerce_db.products; --$$
);
-- returns zero rows: no product is literally named that entire string;
-- the products table is untouched
```

**Why this is immune, precisely:** the SQL text handed to `EXECUTE` is now
a fixed, constant string — `'SELECT * FROM ecommerce_db.products WHERE
product_name = $1'` — that never changes no matter what `p_name` contains.
PostgreSQL parses and plans **that exact text** first, establishing once
and for all that `$1` is a single parameter of a specific expected type in
one specific position in the grammar. Only *after* parsing is complete does
`USING p_name` hand over the actual value, and it is delivered to the
executor as a bound data value for the already-fixed `$1` slot — never
substituted back into the string, never re-parsed as characters that could
form new SQL syntax. A value like `x' OR '1'='1` is compared,
character-for-character, against every `product_name` in the table as one
opaque string; it does not — cannot — reopen or close any quote, because
there is no quote-based text-splicing happening at all anymore. The
apostrophes inside it are just two of the fourteen characters in the value
being compared, nothing more.

### 23.4.4 The safe pattern for dynamic IDENTIFIERS

`USING` only solves the *value* half of the problem. It cannot help when
the thing that needs to vary is a table or column name, because `$1` can
never be substituted for an identifier position (§23.1). For that, combine
`%I` (structure) with `USING` (values) in the same statement:

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.get_column_equals(
    p_table_name  TEXT,
    p_column_name TEXT,
    p_value       TEXT
)
RETURNS SETOF RECORD
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE format(
        'SELECT * FROM %I WHERE %I = $1',
        p_table_name,
        p_column_name
    ) USING p_value;
END;
$$;
```

- `format('SELECT * FROM %I WHERE %I = $1', p_table_name, p_column_name)`
  builds the *structure* — which table, which column — safely: each `%I`
  quotes and escapes its argument as an identifier, so even a hostile
  `p_table_name` like `products; DROP TABLE users; --` becomes one
  syntactically inert quoted identifier (§23.3), not executable syntax.
- `$1` is left as a genuine bind placeholder in the generated text — not
  filled in by `format()` at all — because it stands for a *value*, not an
  identifier.
- `USING p_value` binds that value the same immune way as §23.4.3.

This is the general template for the rest of the chapter: **identifiers go
through `%I`/`quote_ident()`; values go through `USING`; the two are never
interchangeable and never substitute for each other.**

> **Important Note — table return type.** `RETURNS SETOF RECORD` with a
> fully dynamic table shape has no fixed column list, so PostgreSQL cannot
> know the output columns in advance; callers must supply a column
> definition list at call time (`SELECT * FROM get_column_equals(...) AS
> t(user_id INT, username TEXT, ...)`). This is a real ergonomic cost of
> fully generic dynamic SQL — see §23.11 for when that trade-off is worth
> making.

---

## 23.5 Worked Example — Dynamic Table Names: `count_rows()`

A generic "how many rows are in this table" utility — the simplest
realistic case where the table name itself must vary.

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.count_rows(p_table_name TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_count BIGINT;
BEGIN
    EXECUTE format('SELECT count(*) FROM ecommerce_db.%I', p_table_name)
        INTO v_count;
    RETURN v_count;
END;
$$;
```

```sql
SELECT ecommerce_db.count_rows('products');   -- 10
SELECT ecommerce_db.count_rows('orders');     -- 10
SELECT ecommerce_db.count_rows('reviews');    -- 6
```

**Line-by-line**
- `p_table_name TEXT` — the caller supplies only the bare table name;
  the schema (`ecommerce_db`) is hardcoded in the template, which is
  deliberately restrictive: this function can only ever count tables
  inside `ecommerce_db`, never an arbitrary schema.
- `format('SELECT count(*) FROM ecommerce_db.%I', p_table_name)` — `%I`
  quotes/escapes the table name only; the schema is a literal, trusted
  string written by the developer, not user input.
- `EXECUTE ... INTO v_count` — a single scalar row is expected back
  (`count(*)` always returns exactly one row), captured directly.

**Attempted attack:**
```sql
SELECT ecommerce_db.count_rows('products; DROP TABLE orders; --');
```
generates `SELECT count(*) FROM ecommerce_db."products; DROP TABLE orders; --"`,
which fails with `relation "ecommerce_db.products; DROP TABLE orders; --"
does not exist` — a clean error, not a dropped table.

**Edge case:** this simple version does not support schema-qualified input
(`count_rows('ecommerce_db.products')`) — `%I` would quote the entire dotted
string as one identifier (`"ecommerce_db.products"`), which does not exist,
and the call would fail. Supporting caller-chosen schemas safely needs two
separate `%I` slots (`format('SELECT count(*) FROM %I.%I', p_schema,
p_table)`) plus, per the warning in §23.3, an allow-list of schemas the
function is willing to touch at all — never let both the schema *and* the
table be fully open-ended in one generic utility meant to be exposed to
less-trusted callers.

---

## 23.6 Worked Example — Dynamic Column Names: distinct values of any column

A generic "show me the distinct values that exist in this column" utility —
common in admin tools and lightweight reporting UIs.

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.get_distinct_values(
    p_table_name  TEXT,
    p_column_name TEXT
)
RETURNS SETOF TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE format(
        'SELECT DISTINCT %I::TEXT FROM ecommerce_db.%I ORDER BY 1',
        p_column_name,
        p_table_name
    );
END;
$$;
```

```sql
SELECT * FROM ecommerce_db.get_distinct_values('orders', 'status');
```
```
 get_distinct_values
----------------------
 CANCELLED
 DELIVERED
 PAID
 PENDING
 SHIPPED
(5 rows)
```

```sql
SELECT * FROM ecommerce_db.get_distinct_values('payments', 'payment_method');
```
```
 get_distinct_values
----------------------
 CARD
 COD
 NETBANKING
 UPI
 WALLET
(5 rows)
```

**Line-by-line**
- `%I::TEXT` — the column name is quoted as an identifier by `%I`; the
  `::TEXT` cast is applied to *every row's value* after the query runs, so
  the function can return `SETOF TEXT` regardless of the column's real
  type (`VARCHAR`, `NUMERIC`, `BOOLEAN`, ...). This is what lets one
  function work generically across differently-typed columns.
- `RETURN QUERY EXECUTE` (not `INTO`) — because the result can be any
  number of rows, not one.
- No `USING` is needed here at all — there are no *values* being
  filtered on, only identifiers being selected from; this function has
  nothing to bind.

**Common mistake:** forgetting the `::TEXT` cast and instead declaring the
function `RETURNS SETOF <specific type>` — that hardcodes an assumption
about which columns the function will ever be pointed at, defeating the
entire purpose of making it generic.

---

## 23.7 Worked Example — Dynamic Filtering: Flexible Product Search

This is the realistic case from §23.1's fourth category: a search endpoint
where several filters are all **optional**, and the caller may supply any
combination of them (including none). Building one static query with
`AND (p_x IS NULL OR column = p_x)` for every filter works for a *few*
filters (and is often the better choice — see §23.9), but as the number of
optional filters and the complexity of "how to combine them" grows, teams
often reach for dynamic SQL that appends only the conditions actually
needed. Here it is, built safely from the ground up:

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.search_products(
    p_name_pattern TEXT    DEFAULT NULL,   -- matched with ILIKE, e.g. '%phone%'
    p_min_price    NUMERIC DEFAULT NULL,
    p_max_price    NUMERIC DEFAULT NULL,
    p_category_id  INT     DEFAULT NULL
)
RETURNS SETOF ecommerce_db.products
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql TEXT := 'SELECT * FROM ecommerce_db.products WHERE 1=1';
BEGIN
    IF p_name_pattern IS NOT NULL THEN
        v_sql := v_sql || ' AND product_name ILIKE $1';
    END IF;

    IF p_min_price IS NOT NULL THEN
        v_sql := v_sql || ' AND price >= $2';
    END IF;

    IF p_max_price IS NOT NULL THEN
        v_sql := v_sql || ' AND price <= $3';
    END IF;

    IF p_category_id IS NOT NULL THEN
        v_sql := v_sql || ' AND category_id = $4';
    END IF;

    v_sql := v_sql || ' ORDER BY product_id';

    RETURN QUERY EXECUTE v_sql
        USING p_name_pattern, p_min_price, p_max_price, p_category_id;
END;
$$;
```

### Why fixed `$1`..`$4` positions work even though conditions are skipped

This is the detail that makes the function both safe *and* simple: **every
call always passes all four values through `USING`, in the same fixed
order, regardless of which ones are `NULL`.** `EXECUTE ... USING` only
binds a `$n` placeholder to a value if `$n` actually *appears somewhere in
the generated text* — an unused `USING` value (say, `$2` was never
appended to `v_sql` because `p_min_price` was `NULL`) is simply never
referenced and causes no error. This means the `IF` blocks only ever need
to decide *whether a placeholder appears in the text*, never renumber
anything, and every value — used or not — is still bound the fully safe
way, never concatenated.

### Walking through the generated SQL for different inputs

**Call 1 — only a name pattern:**
```sql
SELECT * FROM ecommerce_db.search_products(p_name_pattern => '%book%');
```
Generated text:
```sql
SELECT * FROM ecommerce_db.products WHERE 1=1 AND product_name ILIKE $1 ORDER BY product_id
```
bound with `USING '%book%', NULL, NULL, NULL` — `$1` is the only
placeholder present, so it's the only one that matters; matches
`UltraBook Pro 14`, `GameBook 15`, `Laptop Sleeve 14"`.

**Call 2 — price range only:**
```sql
SELECT * FROM ecommerce_db.search_products(p_min_price => 1000, p_max_price => 3000);
```
Generated text:
```sql
SELECT * FROM ecommerce_db.products WHERE 1=1 AND price >= $2 AND price <= $3 ORDER BY product_id
```
bound with `USING NULL, 1000, 3000, NULL` — returns `Men Cotton Shirt`
(1299), `Women Kurta Set` (1799), `Non-stick Pan Set` (2499), `Wireless
Earbuds` (3499 — excluded, above max).

**Call 3 — category plus a price ceiling:**
```sql
SELECT * FROM ecommerce_db.search_products(p_max_price => 50000, p_category_id => 2);
```
Generated text:
```sql
SELECT * FROM ecommerce_db.products WHERE 1=1 AND price <= $3 AND category_id = $4 ORDER BY product_id
```
returns `Galaxy Phone X` (45999) and `Wireless Earbuds` (3499) from
category 2 (Mobiles); `Pixel Lite` (29999) also qualifies.

**Call 4 — no filters at all:**
```sql
SELECT * FROM ecommerce_db.search_products();
```
Generated text:
```sql
SELECT * FROM ecommerce_db.products WHERE 1=1 ORDER BY product_id
```
returns all 10 products — the `WHERE 1=1` scaffold (a harmless
always-true condition used purely so every subsequent clause can start
with a uniform `AND`) means "no filters" degrades gracefully to "everything".

> **Important Note:** Every single condition above only ever varies a
> *value* being compared (`ILIKE $1`, `>= $2`, `<= $3`, `= $4`) — never a
> table or column name. That's why this function needs `USING` throughout
> and never needs `%I`/`quote_ident()` at all. Compare this to §23.4.4 and
> §23.16, where the thing varying genuinely is an identifier.

---

## 23.8 Performance: Why Dynamic SQL Forgoes Plan Caching

A static, parameterized statement inside a PL/pgSQL function is planned
once per backend session and that plan is reused on subsequent calls
(PostgreSQL calls this a "cached plan," and after five calls it decides
whether a single generic plan is cheap enough to keep reusing, or whether
custom plans per parameter value are worth re-planning for). This reuse is
a real, meaningful performance saving on hot code paths — parsing and
planning are not free, and skipping them on the 10,000th call of a
frequently-invoked function is exactly the kind of thing that shows up
favorably in a profiler.

**Dynamic SQL forfeits this by construction.** Every `EXECUTE` hands
PostgreSQL a string that, as far as the planner is concerned, could be
completely different from the one it saw last time — because it *can* be:
nothing stops the next call from producing different SQL text via
different `IF` branches (exactly as in §23.7). PostgreSQL has no way to
know in advance whether today's string equals yesterday's, so it never even
tries to reuse a plan across `EXECUTE` calls by default: **every `EXECUTE`
re-parses and re-plans the statement text from scratch, every single
time**, regardless of whether the text happens to be identical to the
previous call.

For a utility function called occasionally in an admin tool, this cost is
irrelevant. For a function sitting in the hot path of a high-throughput API
— called thousands of times per second — the repeated parse/plan overhead
is a genuine, measurable tax, and it's one of the strongest reasons to
prefer static parameterized SQL (§23.11) whenever the query's *shape*
doesn't actually need to vary.

> **Important Note:** This cost applies to the *text your `EXECUTE`
> statement receives*, not to the underlying table's statistics or indexes.
> A dynamically built query still benefits from indexes, still gets a
> genuinely cost-based plan chosen for it, and still executes efficiently
> once planned — the tax is purely the *repeated planning step itself*,
> not worse execution once planned.

---

## 23.9 Common Mistakes

1. **Concatenating any value directly into an `EXECUTE` string.** This is
   the #1 mistake in this entire chapter, already demonstrated in full in
   §23.4.1–§23.4.2. If you ever find yourself writing `'...' || some_variable
   || '...'` immediately before an `EXECUTE`, stop and ask whether
   `some_variable` is a value (route it through `USING`) or an identifier
   (route it through `%I`/`quote_ident()`). There is no third category and
   no safe shortcut.
2. **Assuming `%L`/`quote_literal()` makes any data type automatically
   safe.** `%L` correctly escapes *text content*, but it does not validate
   that the resulting literal is even the right *type* for the column it's
   compared against, nor does it protect you from locale/formatting
   surprises (e.g., a `NUMERIC` value formatted with a comma-as-decimal
   separator in some client locale, then quoted as a string and compared
   against a numeric column via implicit cast). `USING` avoids this
   entirely because the value is passed as a real, already-typed parameter
   — never round-tripped through text formatting and re-parsed.
3. **Reaching for dynamic SQL when a static `CASE`/`COALESCE` query would
   do.** A very common over-application: writing dynamic string-building
   code for something like "sort ascending or descending" when a static
   query already handles it cleanly:
   ```sql
   SELECT * FROM ecommerce_db.orders
   ORDER BY CASE WHEN $1 = 'asc' THEN order_date END ASC,
            CASE WHEN $1 = 'desc' THEN order_date END DESC;
   ```
   or an optional filter with:
   ```sql
   SELECT * FROM ecommerce_db.products
   WHERE ($1::NUMERIC IS NULL OR price >= $1)
     AND ($2::NUMERIC IS NULL OR price <= $2);
   ```
   Both stay static, parameterized, and plan-cacheable — no `EXECUTE`
   needed. Reach for dynamic SQL only once you hit one of §23.1's four
   genuine categories (identifiers varying, or a filter combination too
   open-ended for a `CASE`/`COALESCE` static query to express cleanly).
4. **Forgetting that `USING` positions are literal `$n` references in the
   text, not "the next unused slot."** If your generated text references
   `$2` but your `USING` list only has one value, you get `ERROR: there is
   no parameter $2`. Keep the numbering scheme (as in §23.7, fixed slots
   per named filter) simple and consistent rather than trying to
   dynamically renumber placeholders as conditions are added.
5. **Building `%I`-quoted identifiers from values that were never meant to
   be identifiers**, e.g., accidentally passing a whole user-supplied
   search phrase into a spot intended for a column name. `%I` will
   "succeed" (produce a syntactically valid, if bizarre, quoted
   identifier) and then fail loudly with "column does not exist" — a
   correctness bug disguised as a runtime error, not a security hole, but
   worth catching in testing rather than production.

---

## 23.10 Edge Cases

- **A dynamic statement referencing a nonexistent table or column fails
  only at *execution* time, never at function-creation time.** `CREATE
  OR REPLACE FUNCTION` for a PL/pgSQL function containing `EXECUTE
  format('SELECT * FROM %I', p_table_name)` succeeds unconditionally —
  PostgreSQL has no idea what `p_table_name` will be until the function
  actually runs, so there is nothing to validate yet. Contrast this with
  *static* SQL in a function body, which is not fully validated against
  the schema at creation time either (PL/pgSQL is not statically typed
  against schema objects — a static `SELECT` referencing a column that
  gets dropped later will also only fail the next time the function runs)
  — but dynamic SQL takes this further: even a same-session, immediately
  prior call to `CREATE FUNCTION` gives you *zero* signal, because the
  string manipulation itself (`format(...)`, string concatenation) is
  syntax-checked as PL/pgSQL, while the SQL text it *produces* is opaque to
  the compiler entirely. This makes dynamic SQL effectively invisible to
  most schema-linting tools, dependency graphs (`pg_depend`), and "what
  breaks if I drop this column" tooling — a real maintenance cost, not
  just an academic one.
- **Multiple statements in one `EXECUTE` string.** As shown in §23.4.2,
  PL/pgSQL's `EXECUTE` (via `SPI_execute`) will run a semicolon-separated
  string as multiple statements in sequence. This is exactly what makes
  the "stacked query" injection possible, and it also means a legitimate
  dynamic-SQL author must never accidentally concatenate untrusted text
  that could contain a stray `;`.
- **`NULL` propagation through `format()`.** `format('... %L ...', NULL)`
  renders the SQL keyword `NULL` (unquoted), not the four-character string
  `'NULL'` — this is correct and intentional, but easy to get wrong if you
  assume `%L` always produces a quoted string.
- **Case sensitivity surprises from `%I`.** `format('SELECT * FROM %I',
  'Products')` (capital P) produces `"Products"`, which will fail against
  `ecommerce_db.products` (lowercase, unquoted at creation, therefore
  folded to lowercase) with "relation does not exist" — a reminder that
  `%I` faithfully preserves whatever case you give it rather than
  guessing your intent.

---

## 23.11 When to Use (and Not Use) Dynamic SQL

**Use it when:**
- The table or column identity genuinely varies per call (generic admin
  tooling, multi-tenant per-tenant tables, "distinct values of any
  column" utilities like §23.6).
- The set and combination of optional filters is large/open-ended enough
  that a static `CASE`/`COALESCE` query becomes unreadable or forces every
  possible filter to always be evaluated even when unused.
- The sort column/direction must be caller-chosen (§23.16) — `ORDER BY`
  cannot be parameterized with a plain bind variable at all.
- You're building a genuinely generic library/framework function meant to
  operate across many tables you can't enumerate in advance.

**Avoid it when:**
- A static, parameterized query already expresses the logic cleanly (most
  optional-filter cases with a small, fixed number of filters — see the
  `CASE`/`COALESCE` pattern in §23.9, mistake 3).
- The function sits on a high-throughput hot path where the lost plan
  caching (§23.8) is measurable.
- You're tempted to use dynamic SQL only to avoid writing a few extra
  lines of static SQL — the loss of tooling visibility (§23.10) and the
  added injection-surface responsibility are a bad trade for pure
  convenience.

---

## 23.12 Comparisons

| Approach | Structure can vary? | Plan caching | Injection risk | Tooling visibility |
|---|---|---|---|---|
| **Static parameterized SQL** (`WHERE col = $1`) | No — fixed at write time | Full — plan cached and reused | None (values never touch SQL grammar) | Full — linters, `pg_depend`, static analysis all see it |
| **Dynamic SQL, done safely** (`%I` + `USING`) | Yes — identifiers and filter shape can change per call | None — re-parsed/re-planned every call | None, *if* every value goes through `USING` and every identifier through `%I`/`quote_ident()` | Poor — the real SQL text is invisible until runtime |
| **Dynamic SQL, done unsafely** (concatenation) | Yes | None | **Severe** — arbitrary SQL execution, as shown in §23.4 | Poor |
| **Application-level query builder / ORM** | Yes — built in host language, often type-checked | Depends on driver (most parameterize final SQL, similar to static) | Low, if the builder always parameterizes values and validates identifiers against a schema model — high if raw string fragments are still allowed through | Better than in-database dynamic SQL (host-language IDE support, type checking) but SQL itself is still generated, not written |

A query builder or ORM in application code (Chapter 32's projects touch on
this at the architecture level) solves the same structural problem dynamic
SQL solves in the database — varying table/column choice, optional filters
— but does it in the host language, with host-language type checking and
IDE support, at the cost of moving that logic out of the database and
typically issuing one more network round-trip's worth of query-building
work per request. Dynamic SQL inside the database is appropriate when the
logic must live close to the data (a generic admin function reachable only
via `psql`/internal tooling, or a case where moving it to the app tier
would mean shipping raw table/column names to a client that shouldn't see
them).

---

## 23.13 Dialect Notes

### **[PostgreSQL]** — recap
`EXECUTE sql_string [INTO ...] [USING ...]` inside PL/pgSQL, as covered
throughout this chapter. `format()`/`quote_ident()`/`quote_literal()` are
PostgreSQL-specific helper functions; there is also a SQL-level `EXECUTE
prepared_statement_name (args)` for previously-`PREPARE`d statements at the
client/session level, distinct from PL/pgSQL's `EXECUTE`.

### **[MySQL]** — `PREPARE` / `EXECUTE` / `DEALLOCATE PREPARE`
MySQL has no PL/pgSQL-style `EXECUTE sql_string` inside a stored routine
body directly; instead, dynamic SQL is **session-level, statement-based**:

```sql
-- UNSAFE — concatenation
SET @sql = CONCAT(
    'SELECT * FROM products WHERE product_name = ''', p_name, ''''
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- SAFE — bind parameter via a user variable
SET @sql = 'SELECT * FROM products WHERE product_name = ?';
PREPARE stmt FROM @sql;
SET @name = p_name;
EXECUTE stmt USING @name;
DEALLOCATE PREPARE stmt;
```

`PREPARE` parses/plans the string once under a session-scoped name;
`EXECUTE stmt USING @name` runs it with a bound value (same "value bound
after parsing" safety guarantee as PostgreSQL's `USING`); `DEALLOCATE
PREPARE` frees the prepared statement. Identifiers still cannot be bound —
table/column names must be concatenated (escaped with backtick-quoting,
MySQL's equivalent role to `%I`) before the `PREPARE` step, same principle
as `quote_ident()`.

### **[Oracle]** — `EXECUTE IMMEDIATE`, `USING`, `BULK COLLECT`
```sql
-- Dynamic table name, single scalar result
EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_table_name INTO v_count;

-- Safe value binding
EXECUTE IMMEDIATE
    'SELECT * FROM employees WHERE department_id = :1'
    INTO v_row
    USING p_dept_id;

-- BULK COLLECT — fetch an entire dynamic result set into a collection at once
EXECUTE IMMEDIATE
    'SELECT employee_id FROM employees WHERE department_id = :1'
    BULK COLLECT INTO v_id_list
    USING p_dept_id;
```
`EXECUTE IMMEDIATE` is Oracle PL/SQL's direct equivalent of PL/pgSQL's
`EXECUTE`; `USING :1, :2, ...` binds values the same immune way as
PostgreSQL's `USING $1, $2`. `BULK COLLECT INTO` is Oracle's mechanism for
pulling an entire dynamic result set into a PL/SQL collection variable in
one round trip, roughly analogous to PostgreSQL's `RETURN QUERY EXECUTE`
for streaming a full result set, though Oracle materializes it into memory
as a collection rather than streaming rows.

### **[SQL Server]** — `sp_executesql` (safe) vs. raw `EXEC()` (unsafe)
```sql
-- UNSAFE — string concatenation, directly analogous to §23.4.1
DECLARE @sql NVARCHAR(MAX) =
    N'SELECT * FROM Products WHERE ProductName = ''' + @Name + N'''';
EXEC(@sql);

-- SAFE — sp_executesql with a declared parameter, directly analogous to USING
DECLARE @sql NVARCHAR(MAX) = N'SELECT * FROM Products WHERE ProductName = @Name';
EXEC sp_executesql
    @sql,
    N'@Name NVARCHAR(100)',
    @Name = @Name;
```
This is the exact same lesson as §23.4, in SQL Server's vocabulary: raw
`EXEC(@sql)` executes whatever text ends up in `@sql`, so concatenating
`@Name` into it is exactly as vulnerable as §23.4.1. `sp_executesql`
accepts the SQL text as a **fixed, parameterized string** plus a separate
parameter declaration and value list — the text is parsed once with
`@Name` as a genuine placeholder, and the value is bound afterward, immune
to injection for the identical structural reason `USING` is immune in
PostgreSQL. `sp_executesql` also allows SQL Server's plan cache to reuse
the compiled plan across calls with different parameter values (unlike raw
`EXEC()`, which — like PostgreSQL's `EXECUTE` — is reparsed/replanned
whenever the text differs), making it strictly better on both the safety
and performance axes.

---

## 23.14 Real-World Use Cases

- **Generic admin/reporting tools.** An internal dashboard that lets staff
  "pick any table, pick any column, see distinct values / row counts /
  basic stats" is exactly §23.5/§23.6 — a small number of generic dynamic
  SQL utilities replacing what would otherwise be dozens of near-identical
  hand-written functions.
- **Multi-tenant systems with per-tenant tables.** Some multi-tenant
  architectures physically isolate tenants into separate tables or schemas
  (`tenant_1042_orders`, `tenant_1042_invoices`, ...) rather than a shared
  table with a `tenant_id` column. Any query layer serving such a system
  must build the table name dynamically per request — a direct, high-stakes
  application of §23.4.4's `%I` pattern, since a mistake here can leak one
  tenant's identifiers or data into another tenant's context.
- **Flexible search/report APIs.** §23.7's product search, or a
  "build me a report with whatever combination of date range, region,
  status, and sort order the user picked in a UI" endpoint — the
  motivating case for the whole "variable-length optional filter"
  category in §23.1.
- **Schema-evolution and migration tooling.** Scripts that loop over
  `information_schema.tables` and run the same maintenance statement
  (e.g., `VACUUM`, index rebuilds, adding a column) against every table
  matching a pattern necessarily build each statement's table name
  dynamically.

---

## 23.15 Practice Questions

1. In your own words, explain precisely why `PREPARE p AS SELECT * FROM $1`
   is invalid, using the distinction between identifiers and values.
2. What is the exact difference between `EXECUTE sql_string` and
   `EXECUTE sql_string INTO v_result`?
3. Write the safe, `USING`-based version of: "return every row from
   `ecommerce_db.reviews` with `rating` equal to a caller-supplied value."
4. Explain what `%I` does to the string `He said "hello"` when passed
   through `format('%I', ...)`, and why the doubled quotes matter.
5. Why does `%L`/`quote_literal()` still require care with data types, even
   though it correctly escapes quote characters? Give a concrete example
   of a bug that could slip through `%L` but not through `USING`.
6. A colleague argues that `quote_ident()` alone is sufficient protection
   for a dynamic table-name parameter in a function exposed to end users.
   Explain what specific risk remains even after `quote_ident()` is
   applied correctly.
7. Rewrite this optional-filter dynamic SQL function as a single static
   parameterized query using `CASE`/`COALESCE`, and explain why the static
   version is preferable here:
   ```plpgsql
   v_sql := 'SELECT * FROM ecommerce_db.orders WHERE 1=1';
   IF p_status IS NOT NULL THEN
       v_sql := v_sql || format(' AND status = %L', p_status);
   END IF;
   RETURN QUERY EXECUTE v_sql;
   ```
8. Explain why a function containing `EXECUTE format('SELECT * FROM %I',
   p_table)` can be created successfully even if `p_table` will later be
   passed a nonexistent table name. At what point does the error actually
   surface?
9. Describe, in terms of PostgreSQL's plan caching behavior, why a
   frequently-called dynamic SQL function is more expensive per call than
   an equivalent static parameterized function, even when both ultimately
   run the identical query plan.
10. **[MySQL]** What are the three statements needed to run one dynamic
    query safely with a bound parameter, and what does each one do?
11. **[SQL Server]** Contrast `EXEC(@sql)` and `sp_executesql` on both the
    injection-safety axis and the plan-reuse axis.
12. **Spot the vulnerability (1).** Identify exactly what is wrong with
    this function and describe a concrete input that exploits it:
    ```plpgsql
    CREATE OR REPLACE FUNCTION ecommerce_db.orders_by_status(p_status TEXT)
    RETURNS SETOF ecommerce_db.orders
    LANGUAGE plpgsql
    AS $$
    DECLARE
        v_sql TEXT;
    BEGIN
        v_sql := 'SELECT * FROM ecommerce_db.orders WHERE status = ''' || p_status || '''';
        RETURN QUERY EXECUTE v_sql;
    END;
    $$;
    ```
13. **Spot the vulnerability (2).** This one "fixes" the previous function
    by switching to `%L`. Is it actually safe? Identify exactly what is
    still wrong and describe a concrete input that exploits it:
    ```plpgsql
    CREATE OR REPLACE FUNCTION ecommerce_db.report_by_column(
        p_column_name TEXT,
        p_value       TEXT
    )
    RETURNS SETOF ecommerce_db.orders
    LANGUAGE plpgsql
    AS $$
    DECLARE
        v_sql TEXT;
    BEGIN
        v_sql := format('SELECT * FROM ecommerce_db.orders WHERE %s = %L', p_column_name, p_value);
        RETURN QUERY EXECUTE v_sql;
    END;
    $$;
    ```

---

## 23.16 Chapter Challenge — A Safe, Sortable, Filterable Orders Report

Build a single PL/pgSQL function,
`ecommerce_db.orders_report(p_status TEXT, p_sort_column TEXT, p_sort_dir TEXT)`,
that:

1. Optionally filters `ecommerce_db.orders` by `status` when `p_status` is
   not `NULL` (value — must go through `USING`).
2. Sorts by a **caller-chosen column**, `p_sort_column` — a genuine
   identifier that cannot be a bind parameter (§23.1) — but restricts it to
   an explicit **allow-list**: only `order_id`, `order_date`, `status`, or
   `user_id` may be chosen. Any other input must raise a clear exception
   rather than silently doing something unexpected or erroring obscurely.
3. Sorts in a caller-chosen direction, `p_sort_dir` — restricted to `ASC`
   or `DESC` only (case-insensitive), same allow-list reasoning.
4. Returns the matching rows.

Skeleton to complete:

```plpgsql
CREATE OR REPLACE FUNCTION ecommerce_db.orders_report(
    p_status      TEXT DEFAULT NULL,
    p_sort_column TEXT DEFAULT 'order_id',
    p_sort_dir    TEXT DEFAULT 'ASC'
)
RETURNS SETOF ecommerce_db.orders
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql          TEXT := 'SELECT * FROM ecommerce_db.orders WHERE 1=1';
    v_sort_column  TEXT;
    v_sort_dir     TEXT;
BEGIN
    -- Step 1: validate p_sort_column against an allow-list BEFORE quoting it.
    -- Step 2: validate p_sort_dir against an allow-list ('ASC'/'DESC' only).
    -- Step 3: append the optional status filter using USING, not concatenation.
    -- Step 4: append ORDER BY using %I for the column and a validated,
    --         directly-interpolated ASC/DESC keyword (never user text as-is).
    -- Step 5: EXECUTE ... USING and RETURN QUERY.
END;
$$;
```

Then answer, in writing:

1. Why is checking `p_sort_column` against an allow-list **still
   necessary** even though every value that reaches `%I`/`quote_ident()`
   comes out syntactically safe? What could a caller do with `orders_report`
   if the allow-list check were removed but `%I` were kept?
2. Why can't `p_sort_dir` be handled with `USING`, and why is a small
   allow-list (`'ASC'`/`'DESC'`) a completely adequate substitute for
   `%I`/`quote_ident()` in this one specific case (hint: think about
   whether `ASC`/`DESC` are identifiers at all).
3. What should the function do if `p_sort_column` fails the allow-list
   check — return an empty result set, silently fall back to a default
   column, or raise an exception? Justify your choice in terms of how a
   caller (application code) should be expected to react.
4. Extend your design (in prose, no need to fully code it) to also accept
   an optional `p_user_id INT` filter and an optional `LIMIT`/`OFFSET` pair
   for pagination, without weakening any of the safety properties above.

---

## Key Takeaways

- Dynamic SQL is SQL text built and executed at runtime, via `EXECUTE`,
  instead of being fixed and pre-planned when a function is written.
- Dynamic SQL exists because **a bind parameter can only ever stand in for
  a value, never for an identifier** — table names, column names, and
  `ORDER BY` targets cannot be parameterized, and variable-length/optional
  filter combinations often don't fit a single fixed static shape either.
- `EXECUTE sql_string USING value1, value2` is the core safety mechanism:
  values are bound to the already-parsed statement text as real data,
  never re-inserted into the string and reparsed — this is what makes it
  immune to injection.
- `format()` with `%I` (identifiers) and `%L` (literals), plus standalone
  `quote_ident()`/`quote_literal()`, are how you safely build the *structural*
  parts of dynamic SQL that `USING` cannot reach.
- **Never concatenate a runtime value directly into an `EXECUTE` string.**
  This is the #1 mistake in dynamic SQL and the entire cause of the classic
  SQL injection attack, demonstrated in full in §23.4.
- `%I`/`quote_ident()` make an injected identifier syntactically inert, but
  they do **not** restrict *which* real identifier is acceptable — an
  allow-list is a separate, necessary control whenever a dynamic identifier
  is exposed to less-trusted callers.
- Dynamic SQL forfeits plan caching: every `EXECUTE` re-parses and
  re-plans its text from scratch, a real performance cost that static
  parameterized SQL doesn't pay.
- Prefer static, parameterized SQL (`CASE`/`COALESCE` patterns) whenever
  it can express the same logic — reserve dynamic SQL for problems that
  genuinely require varying structure, not as a default style.
- The same unsafe-concatenation-vs-safe-binding lesson holds across
  engines: PostgreSQL's `USING`, MySQL's `PREPARE ... EXECUTE ... USING`,
  Oracle's `EXECUTE IMMEDIATE ... USING`, and SQL Server's `sp_executesql`
  with declared parameters are all the safe pattern; naive `||`/`CONCAT`/`+`
  concatenation into `EXECUTE`/`EXEC()` is the unsafe one, everywhere.

## What's Next

Chapter 23 covered how to build and execute SQL as text safely at runtime.
Chapter 24 shifts to a different kind of runtime construct: **Temporary
Tables** — tables that exist only for the duration of a session or
transaction, used to stage intermediate results, break a complex report
into readable steps, or hold data a dynamic SQL function (like the ones
you just built) might generate on the fly before returning it. You'll see
how temp tables interact with transactions, why their scope matters for
concurrent sessions, and how they compare to CTEs and views for organizing
multi-step logic.

**Next:** [Chapter 24 — Temporary Tables](24-temporary-tables.md)
