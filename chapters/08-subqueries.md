# Chapter 8 — Subqueries

> **Part III — Intermediate SQL** · Previous: [Chapter 7 — JOINs](07-joins.md) · Next: [Chapter 9 — Common Table Expressions & Recursive CTEs](09-ctes.md)

## Setup

Every example in this chapter runs against the two canonical schemas from
`databases/`. Load them once, then point your session at whichever schema
an example uses:

```sql
\i databases/company_db.sql
\i databases/ecommerce_db.sql

SET search_path TO ecommerce_db;   -- for e-commerce examples
-- or
SET search_path TO company_db;     -- for company examples
```

Every query below is written against the real seed data, and every "expected
output" table shown is the *actual* result you will get by running the query
yourself — copy, paste, verify.

---

## 8.1 What Is a Subquery?

### Simple explanation

A subquery is a query written **inside** another query, used to produce a
value (or a set of values) that the outer query needs. Think of it as
"answer a smaller question first, then use that answer to answer the bigger
question."

> "Find products priced above the *average* product price" first requires
> knowing the average — a number you don't have yet. A subquery computes
> that number for you, inline, in the same statement.

### Technical explanation

A subquery (also called an **inner query** or **nested query**) is a
`SELECT` statement enclosed in parentheses and embedded inside another SQL
statement (the **outer query**). The outer query can be a `SELECT`,
`INSERT`, `UPDATE`, or `DELETE`. A subquery can appear in several clause
positions:

| Location | Role | Must return |
|---|---|---|
| `SELECT` list | Computed column | Exactly 1 row, 1 column (scalar) per outer row |
| `FROM` clause | Derived table / inline view | Any rowset (aliased, treated like a table) |
| `WHERE` clause | Filter condition | Scalar, list, or rowset depending on operator |
| `HAVING` clause | Filter after grouping | Same as `WHERE`, but operates on aggregated groups |

Subqueries are classified along two independent axes:

1. **By cardinality of the result**: scalar (1 row × 1 column), column/list
   (many rows × 1 column), row (1 row × many columns), or table (many rows
   × many columns).
2. **By dependency on the outer query**: **non-correlated** (runs
   independently, once) vs. **correlated** (references a column from the
   outer query, conceptually re-evaluated per outer row).

### Why subqueries exist

SQL is declarative — you describe *what* you want, not *how* to compute it
step by step. Many real questions are naturally two-step ("what's the
average, and which rows beat it?"), but SQL has no variables or scripting in
plain `SELECT`. Subqueries let you express a two-step (or N-step) logical
question as a single, self-contained statement, without needing a stored
procedure, a temp table, or a client-side round trip. They also let the
query planner see the whole computation at once and optimize it as a unit
(e.g., rewriting an `IN`/`EXISTS` subquery into a semi-join).

### Full syntax skeleton

```sql
-- (1) Subquery in WHERE (filter)
SELECT column_list
FROM   table_a
WHERE  column_x <operator> (SELECT single_column FROM table_b [WHERE ...]);

-- (2) Subquery in SELECT list (computed column, must be scalar)
SELECT column_list,
       (SELECT aggregate_or_column
        FROM   table_b
        WHERE  table_b.fk_column = table_a.pk_column) AS alias
FROM   table_a;

-- (3) Subquery in FROM clause (derived table — needs an alias in PostgreSQL/MySQL)
SELECT dt.column
FROM   (SELECT ... FROM table_b GROUP BY ...) AS dt
WHERE  dt.some_column > 100;

-- (4) Subquery in HAVING (filter on aggregated groups)
SELECT grouping_column, aggregate_fn(column)
FROM   table_a
GROUP BY grouping_column
HAVING aggregate_fn(column) <operator> (SELECT ... );
```

`<operator>` can be `=`, `<>`, `>`, `<`, `>=`, `<=` (scalar comparison),
`IN`/`NOT IN` (membership), `EXISTS`/`NOT EXISTS` (existence), or
`ANY`/`ALL`/`SOME` (quantified comparison). Each is covered in depth below.

---

## 8.2 Categories of Subqueries at a Glance

| Category | Returns | Typical operator | Example |
|---|---|---|---|
| Scalar | 1 row, 1 column | `=`, `>`, `<`, etc. | `WHERE price > (SELECT AVG(price) FROM products)` |
| Multi-row (column) | N rows, 1 column | `IN`, `NOT IN`, `ANY`, `ALL` | `WHERE category_id IN (SELECT category_id FROM categories WHERE ...)` |
| Multi-column (row) | 1 row, N columns | `= (col1, col2)` | `WHERE (a, b) = (SELECT x, y FROM ...)` |
| Table (derived table) | N rows, N columns | used as a `FROM` source | `FROM (SELECT ...) AS t` |
| Correlated | Any of the above | Any operator, references outer query | `WHERE price > (SELECT AVG(p2.price) FROM products p2 WHERE p2.category_id = p.category_id)` |
| Existence | N/A (boolean test) | `EXISTS`, `NOT EXISTS` | `WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.user_id)` |

---

## 8.3 Scalar Subqueries

### Simple explanation

A scalar subquery returns a **single value** — one row, one column — that
gets used just like a literal number or string would be.

### Technical explanation

The database executes the inner query, confirms it produced at most one row
and one column, and substitutes that single value into the outer query.
If the subquery is non-correlated, PostgreSQL typically executes it **once**
(often materialized as an `InitPlan` in `EXPLAIN` output) and reuses the
result for every outer row — this is a major performance advantage over a
correlated subquery, which must be considered separately per outer row.

### Why they exist

Comparisons like `price > average price` need a number computed from the
same or another table before the row-by-row filter can run. A scalar
subquery computes that number inline instead of requiring a separate query
and a hard-coded constant.

### Example 1 — Scalar subquery in `WHERE` (simple)

**Question:** Which products cost more than the average price of all
products?

```sql
SELECT product_name, price
FROM   products
WHERE  price > (SELECT ROUND(AVG(price), 2) FROM products)
ORDER  BY price DESC;
```

**Expected output:**

| product_name      | price     |
|-------------------|-----------|
| UltraBook Pro 14   | 89999.00 |
| GameBook 15        | 74999.00 |
| Galaxy Phone X      | 45999.00 |
| Pixel Lite          | 29999.00 |

**Line-by-line:**
1. Inner query: `SELECT ROUND(AVG(price), 2) FROM products` scans all 10
   products, sums their prices (252390.00), divides by 10, rounds → `25239.00`.
2. That single number replaces the subquery, so the outer query effectively
   becomes `WHERE price > 25239.00`.
3. The outer query scans `products`, keeps the four rows priced above
   25239.00, and sorts them descending by price.

### Example 2 — Scalar subquery finding an extreme value (single-row)

**Question:** Which product is the single most expensive product?

```sql
SELECT product_name, price
FROM   products
WHERE  price = (SELECT MAX(price) FROM products);
```

**Expected output:**

| product_name    | price     |
|-----------------|-----------|
| UltraBook Pro 14 | 89999.00 |

This is called a **single-row subquery**: the inner query is guaranteed
(by the aggregate `MAX`) to return exactly one row, one column, so `=` is a
safe comparison operator.

### Example 3 — Scalar subquery in the `SELECT` list

**Question:** For each payment, show its amount next to the overall average
payment amount, so you can eyeball how it compares.

```sql
SELECT order_id,
       amount,
       (SELECT ROUND(AVG(amount), 2) FROM payments) AS overall_avg_payment
FROM   payments
ORDER  BY order_id;
```

**Expected output (first 4 rows shown):**

| order_id | amount   | overall_avg_payment |
|----------|----------|----------------------|
| 1        | 49498.00 | 40308.10             |
| 2        | 4097.00  | 40308.10             |
| 3        | 89999.00 | 40308.10             |
| 4        | 3298.00  | 40308.10             |
| ...      | ...      | 40308.10             |

**Line-by-line:** The subquery in the `SELECT` list is evaluated once
(it's non-correlated — it doesn't reference `payments.order_id` or any
outer column) and the same scalar value, `40308.10`, is repeated on every
output row. This is a common reporting pattern: "this row's value vs. the
benchmark."

### Example 4 (HAVING + nested subqueries) — orders above the average order total

**Question:** Which orders have a total value (sum of line items) greater
than the average order total across all orders?

```sql
SELECT order_id, SUM(quantity * unit_price) AS order_total
FROM   order_items
GROUP  BY order_id
HAVING SUM(quantity * unit_price) > (
    SELECT ROUND(AVG(order_total), 2)
    FROM (
        SELECT SUM(quantity * unit_price) AS order_total
        FROM   order_items
        GROUP  BY order_id
    ) AS order_totals
)
ORDER  BY order_total DESC;
```

**Expected output:**

| order_id | order_total |
|----------|-------------|
| 9        | 93498.00    |
| 3        | 89999.00    |
| 6        | 75798.00    |
| 1        | 49498.00    |
| 8        | 45999.00    |

**Line-by-line:**
1. The innermost derived table (`order_totals`) collapses `order_items`
   into one row per order, each with its `SUM(quantity * unit_price)`.
2. The scalar subquery in `HAVING` averages those ten order totals:
   `403081.00 / 10 = 40308.10`.
3. The outer query groups `order_items` by `order_id` again (independently)
   and keeps only groups whose total exceeds `40308.10`.

> **Important Note.** This example nests three levels: a derived table,
> wrapped in a scalar subquery, used inside `HAVING`. It's correct but
> repetitive — the same `GROUP BY order_id` logic appears twice. Chapter 9
> (CTEs) solves exactly this kind of repetition with `WITH order_totals AS
> (...)`, computed once and referenced twice.

### Internal / execution-model note

For a **non-correlated** scalar subquery, PostgreSQL's planner typically
evaluates it once, ahead of the outer scan, and shows it in `EXPLAIN` output
as an `InitPlan` (executed once) rather than a `SubPlan` (potentially
executed repeatedly). This is why non-correlated scalar subqueries are
cheap even against large tables — the cost is the subquery's own cost, paid
once, not once per outer row.

### Common mistake — multi-row subquery where a scalar is expected

If the inner query can return more than one row, using it with a
single-row operator (`=`, `>`, `<`, etc.) is a **runtime error**, not a
silent bug — the engine cannot collapse two rows into one comparison value.

```sql
-- BROKEN: category2 (Mobiles) and category3 (Laptops) are both children of category 1,
-- so the subquery returns TWO rows.
SELECT product_name
FROM   products
WHERE  category_id = (
    SELECT category_id FROM categories WHERE parent_category_id = 1
);
```

**Result:**

```
ERROR:  more than one row returned by a subquery used as an expression
```

| Dialect | Error you will see |
|---|---|
| **[PostgreSQL]** | `ERROR: more than one row returned by a subquery used as an expression` |
| **[MySQL]** | `ERROR 1242 (21000): Subquery returns more than 1 row` |
| **[Oracle]** | `ORA-01427: single-row subquery returns more than one row` |
| **[SQL Server]** | `Msg 512, Level 16: Subquery returned more than 1 value. This is not permitted when the subquery follows =, !=, <, <= , >, >= or when the subquery is used as an expression.` |

**Fix:** either add a condition that guarantees one row (e.g. `LIMIT 1` with
an `ORDER BY`), switch to `IN`/`ANY`/`ALL` if you genuinely want to compare
against a *set*, or restructure with a `JOIN`.

### Edge case — scalar subquery returning zero rows

A scalar subquery that matches **no rows** does not error — it evaluates to
`NULL`.

```sql
SELECT (SELECT price FROM products WHERE product_id = 9999) AS missing_price;
```

**Expected output:**

| missing_price |
|---------------|
| NULL          |

> **⚠️ Warning.** This is different from an empty result set at the
> *outer* query level. A scalar subquery returning zero rows quietly
> becomes `NULL`, and any comparison against `NULL` (`>`, `<`, `=`) is
> `UNKNOWN`, which `WHERE` treats as "exclude this row." A filter like
> `WHERE price > (SELECT price FROM products WHERE product_id = 9999)`
> will silently return **zero rows**, with no error, no warning — because
> `price > NULL` is `UNKNOWN` for every row. Always consider whether your
> scalar subquery could legitimately return nothing.

---

## 8.4 Multi-Row Subqueries: `IN` and `NOT IN`

### Simple explanation

`IN` checks whether a value belongs to a list. `NOT IN` checks whether it
doesn't. When the list comes from a subquery instead of a literal list, the
subquery is a **multi-row (column) subquery** — it's allowed to return many
rows, as long as it's exactly one column.

### Technical explanation

`x IN (subquery)` is evaluated as a chain of `OR`-connected equalities:
`x = v1 OR x = v2 OR x = v3 ...` for every value `v` the subquery returns.
`x NOT IN (subquery)` is the negation, evaluated as a chain of
`AND`-connected inequalities: `x <> v1 AND x <> v2 AND x <> v3 ...`.
That `AND`-chain is exactly what makes `NOT IN` dangerous with `NULL` —
see §8.8.

### Why it exists

`IN` is the natural way to express "matches any value from this other set,"
without manually writing out `OR` conditions or knowing the set in advance.

### Full syntax

```sql
SELECT column_list
FROM   table_a
WHERE  column_x [NOT] IN (SELECT single_column FROM table_b [WHERE ...]);
```

### Example 1 — `IN` (simple)

**Question:** Which products belong to the Mobiles or Laptops categories?

```sql
SELECT product_name, category_id
FROM   products
WHERE  category_id IN (
    SELECT category_id FROM categories WHERE category_name IN ('Mobiles', 'Laptops')
)
ORDER  BY category_id, product_name;
```

**Expected output:**

| product_name       | category_id |
|--------------------|-------------|
| Galaxy Phone X      | 2           |
| Pixel Lite          | 2           |
| Wireless Earbuds    | 2           |
| GameBook 15         | 3           |
| Laptop Sleeve 14"   | 3           |
| UltraBook Pro 14    | 3           |

### Example 2 — `NOT IN` (safe case — subquery column is never `NULL`)

**Question:** Which categories have no products directly assigned to them
(only sub-categories do)?

```sql
SELECT category_id, category_name
FROM   categories
WHERE  category_id NOT IN (SELECT category_id FROM products)
ORDER  BY category_id;
```

**Expected output:**

| category_id | category_name |
|-------------|----------------|
| 1           | Electronics    |
| 4           | Fashion        |

**Line-by-line:** `products.category_id` is populated for every one of the
10 seed rows (no `NULL`s), so the subquery's result list is a clean
`{2, 3, 5, 6, 7}` with no `NULL` in it. `NOT IN` behaves exactly as expected
here — this is the *safe* shape of `NOT IN`. Keep this example in mind;
§8.8 shows the same-looking query breaking completely once the subquery
column can contain `NULL`.

### Example 3 — Nested `IN` (multi-row subquery inside another subquery)

**Question:** Which employees work on a project with a budget over
1,000,000?

```sql
SELECT DISTINCT e.first_name, e.last_name
FROM   employees e
WHERE  e.employee_id IN (
    SELECT ep.employee_id
    FROM   employee_projects ep
    WHERE  ep.project_id IN (
        SELECT project_id FROM projects WHERE budget > 1000000
    )
)
ORDER  BY e.last_name;
```

**Expected output:**

| first_name | last_name |
|------------|-----------|
| Arjun      | Das       |
| Aman       | Chawla    |
| Vikram     | Joshi     |
| Sneha      | Kulkarni  |
| Rahul      | Mehta     |
| Priya      | Nair      |
| Karan      | Verma     |

**Line-by-line:**
1. Innermost subquery: `projects` with `budget > 1000000` →
   *Platform Migration* (5,000,000), *Mobile App Revamp* (3,000,000),
   *Q1 Sales Expansion* (1,200,000) → project IDs `{1, 2, 3}`.
2. Middle subquery: `employee_projects` rows whose `project_id` is in
   `{1, 2, 3}` → employee IDs `{2, 3, 4, 6, 7, 8, 16}`.
3. Outer query: `employees` whose `employee_id` is in that set, deduplicated
   with `DISTINCT` (an employee could theoretically appear twice if
   assigned to two qualifying projects) and sorted by last name.

> **Important Note.** `DISTINCT` is needed here because a subquery `IN`
> membership test does not itself introduce duplicates — but if you later
> rewrite this as a `JOIN` (see §8.14), duplicates *will* appear and you'll
> need `DISTINCT` there for a different reason.

---

## 8.5 `ANY` and `ALL`

### Simple explanation

`ANY` means "true if the comparison holds against **at least one** value in
the set." `ALL` means "true if the comparison holds against **every**
value in the set." They extend comparison operators (`>`, `<`, `=`, `<>`,
etc.) to work against a multi-row subquery, not just `=`/`<>`.

### Technical explanation

`expr operator ANY (subquery)` is `TRUE` if `expr operator v` is `TRUE` for
at least one row `v` returned by the subquery. `expr operator ALL
(subquery)` is `TRUE` only if `expr operator v` is `TRUE` for every row `v`.
`SOME` is a synonym for `ANY` in every major dialect.

| Expression | Equivalent to |
|---|---|
| `x = ANY (subquery)` | `x IN (subquery)` |
| `x <> ALL (subquery)` | `x NOT IN (subquery)` |
| `x > ANY (subquery)` | `x` greater than the **minimum** value returned |
| `x > ALL (subquery)` | `x` greater than the **maximum** value returned |
| `x < ANY (subquery)` | `x` less than the **maximum** value returned |
| `x < ALL (subquery)` | `x` less than the **minimum** value returned |

### Why they exist

`IN`/`NOT IN` only give you equality/inequality membership. Sometimes you
need "greater than the cheapest item in that category" or "cheaper than
everything in that category," which `IN` cannot express — `ANY`/`ALL` fill
that gap without forcing you to pre-aggregate with `MIN`/`MAX` yourself
(though, as the equivalence table shows, `MIN`/`MAX` is usually clearer —
see Common Mistakes).

### Full syntax

```sql
SELECT column_list
FROM   table_a
WHERE  column_x <operator> ANY|SOME (SELECT single_column FROM table_b [WHERE ...]);

SELECT column_list
FROM   table_a
WHERE  column_x <operator> ALL (SELECT single_column FROM table_b [WHERE ...]);
```

### Example 1 — `ANY`

**Question:** Which products are priced higher than at least one product in
the Home & Kitchen category?

```sql
SELECT product_name, price
FROM   products
WHERE  price > ANY (
    SELECT price FROM products WHERE category_id =
        (SELECT category_id FROM categories WHERE category_name = 'Home & Kitchen')
)
ORDER  BY price DESC;
```

Home & Kitchen contains *Non-stick Pan Set* (2499.00) and *Electric Kettle*
(1499.00). `> ANY` is satisfied by anything greater than the **smaller** of
the two (1499.00).

**Expected output:**

| product_name    | price     |
|-----------------|-----------|
| UltraBook Pro 14 | 89999.00 |
| GameBook 15      | 74999.00 |
| Galaxy Phone X    | 45999.00 |
| Pixel Lite        | 29999.00 |
| Wireless Earbuds  | 3499.00  |
| Non-stick Pan Set | 2499.00  |
| Women Kurta Set   | 1799.00  |

*(Men Cotton Shirt 1299.00, Electric Kettle 1499.00 itself, and Laptop
Sleeve 799.00 are excluded — none of them beats even the smaller reference
value.)*

### Example 2 — `ALL`

**Question:** Which products are priced higher than **every** product in
the Home & Kitchen category?

```sql
SELECT product_name, price
FROM   products
WHERE  price > ALL (
    SELECT price FROM products WHERE category_id =
        (SELECT category_id FROM categories WHERE category_name = 'Home & Kitchen')
)
ORDER  BY price DESC;
```

`> ALL` requires beating the **larger** reference value (2499.00).

**Expected output:**

| product_name    | price     |
|-----------------|-----------|
| UltraBook Pro 14 | 89999.00 |
| GameBook 15      | 74999.00 |
| Galaxy Phone X    | 45999.00 |
| Pixel Lite        | 29999.00 |
| Wireless Earbuds  | 3499.00  |

*(Women Kurta Set at 1799.00 no longer qualifies — it beats 1499.00 but not
2499.00.)*

**[PostgreSQL] [MySQL] [Oracle] [SQL Server]** — `ANY`/`SOME`/`ALL` with
subqueries are part of the ANSI SQL standard and are supported, with
identical semantics, across all four dialects. MySQL and PostgreSQL both
accept `SOME` as an exact synonym for `ANY`.

> **⚠️ Warning — `<> ALL` inherits the `NOT IN` NULL trap.** Since
> `x <> ALL (subquery)` is defined identically to `x NOT IN (subquery)`, if
> the subquery can return a `NULL`, `<> ALL` silently returns zero matching
> rows for exactly the same reason `NOT IN` does. See §8.8 — the trap is
> not specific to the `IN` keyword, it's specific to the `<>`/`AND`-chain
> logic underneath it.

---

## 8.6 `EXISTS` and `NOT EXISTS`

### Simple explanation

`EXISTS` asks a yes/no question: "does the subquery produce **any** row at
all?" It doesn't care what columns the subquery selects or what values they
hold — only whether at least one row comes back.

### Technical explanation

`EXISTS (subquery)` evaluates to `TRUE` if the subquery's result set is
non-empty, `FALSE` if it's empty. It never returns `UNKNOWN` — existence is
never ambiguous, even if every column of every matching row is `NULL`. This
is the single most important structural difference from `IN`/`NOT IN`,
which compare actual values and can produce `UNKNOWN`.

Because only *existence* matters, the conventional style is
`SELECT 1` or `SELECT *` inside an `EXISTS` subquery — the column list is
discarded by the engine and has zero effect on the result or (in every
modern optimizer) on performance.

### Why it exists

Business questions are frequently existence questions — "has this customer
ever ordered," "does this employee have an assigned project," "is there any
review for this product" — not "give me the matching rows." `EXISTS`
expresses that directly and lets the engine stop looking the moment it
finds one match.

### Full syntax

```sql
SELECT column_list
FROM   table_a AS outer_alias
WHERE  [NOT] EXISTS (
    SELECT 1
    FROM   table_b AS inner_alias
    WHERE  inner_alias.fk_column = outer_alias.pk_column   -- the correlation
      [AND  additional_conditions]
);
```

Note `EXISTS` subqueries are almost always **correlated** — an
uncorrelated `EXISTS (SELECT 1 FROM some_table)` is either always `TRUE`
(table non-empty) or always `FALSE` (table empty) for every outer row,
which is rarely useful.

### Example 1 — `EXISTS`

**Question:** Which categories have at least one product directly assigned?

```sql
SELECT c.category_name
FROM   categories c
WHERE  EXISTS (
    SELECT 1 FROM products p WHERE p.category_id = c.category_id
)
ORDER  BY c.category_name;
```

**Expected output:**

| category_name    |
|------------------|
| Home & Kitchen   |
| Laptops          |
| Men              |
| Mobiles          |
| Women            |

*(Electronics and Fashion are excluded — they're parent categories with
sub-categories, but no directly-assigned products.)*

### Example 2 — `NOT EXISTS`

**Question:** Which employees are not currently assigned to any project?

```sql
SELECT e.first_name, e.last_name, e.status
FROM   employees e
WHERE  NOT EXISTS (
    SELECT 1 FROM employee_projects ep WHERE ep.employee_id = e.employee_id
)
ORDER  BY e.employee_id;
```

**Expected output:**

| first_name | last_name | status     |
|------------|-----------|------------|
| Aditi      | Rao       | ACTIVE     |
| Ananya     | Singh     | ON_LEAVE   |
| Meera      | Pillai    | TERMINATED |
| Nikhil     | Gupta     | ACTIVE     |
| Divya      | Shah      | ACTIVE     |

### Execution model — why `EXISTS` can short-circuit

Conceptually, for each outer row, the engine runs the inner query **only
until it finds the first matching row**, then stops — it never needs a
second match, a count, or the actual column values. This is the "short
circuit." Contrast with `IN (subquery)` in its *naive* logical form, which
conceptually needs the *entire* candidate list materialized before testing
membership.

> **Important Note.** In practice, modern PostgreSQL (and MySQL 8+, Oracle,
> SQL Server) query planners frequently rewrite both `IN (subquery)` and
> `EXISTS (subquery)` into the **same internal plan shape** — a semi-join —
> when the subquery is a simple correlated lookup. So the "EXISTS is always
> faster" folklore is often not true on indexed columns in a modern
> optimizer. What genuinely differs between them, unconditionally, and
> across every dialect, is **NULL semantics** (§8.8) — that's the reason to
> choose one over the other, not raw speed.

---

## 8.7 Deep Dive: `EXISTS` vs. `IN`

### How each is logically evaluated

| | `IN (subquery)` | `EXISTS (subquery)` |
|---|---|---|
| Logical form | `x = v1 OR x = v2 OR ... OR x = vN` | Boolean: does the subquery return ≥ 1 row? |
| Cares about subquery's column values? | Yes — compares them to `x` | No — only whether rows exist |
| Can be uncorrelated? | Yes, commonly | Rarely useful uncorrelated |
| Behavior with `NULL` in subquery result | Can poison the whole expression (`NOT IN` case) | Never poisoned — existence is binary |
| Typical use | "value is a member of this set" | "a matching row exists for this outer row" |

### When they produce identical results

For **positive** membership (`IN`, not `NOT IN`), `IN (subquery)` and the
equivalent correlated `EXISTS (subquery)` produce the same result set as
long as the subquery's column has no `NULL`s relevant to the comparison.

```sql
-- Using IN
SELECT DISTINCT e.first_name, e.last_name
FROM   employees e
WHERE  e.employee_id IN (
    SELECT ep.employee_id
    FROM   employee_projects ep
    JOIN   projects p ON p.project_id = ep.project_id
    WHERE  p.budget > 1000000
);

-- Using EXISTS — same result set
SELECT e.first_name, e.last_name
FROM   employees e
WHERE  EXISTS (
    SELECT 1
    FROM   employee_projects ep
    JOIN   projects p ON p.project_id = ep.project_id
    WHERE  ep.employee_id = e.employee_id
      AND  p.budget > 1000000
);
```

Both return the same 7 employees shown in §8.4 Example 3 (Rahul Mehta,
Sneha Kulkarni, Vikram Joshi, Karan Verma, Priya Nair, Arjun Das, Aman
Chawla) — no `DISTINCT` needed in the `EXISTS` version, since `EXISTS`
never introduces duplicate outer rows in the first place (it's a boolean
test, not a join).

### When/why one may be more efficient

- **Conceptually**, `EXISTS` can stop at the first match; a naive `IN` must
  materialize the full candidate set first. On an unindexed, large inner
  table, this can matter.
- **In practice**, PostgreSQL's planner (and modern MySQL/Oracle/SQL
  Server) typically optimizes simple correlated `IN` and `EXISTS`
  subqueries into the same semi-join plan when there's a supporting index —
  run `EXPLAIN ANALYZE` on both forms and compare (Chapter 17 covers reading
  plans in depth).
- **The real, dialect-independent reason to prefer one over the other is
  NULL correctness, not speed** — covered next.

---

## 8.8 THE `NOT IN` / `NOT EXISTS` NULL TRAP

> **⚠️ WARNING — This is one of the most common production SQL bugs in
> existence.** `NOT IN (subquery)` silently returns **zero rows** —
> not an error, not a warning, just an empty (or wrongly small) result —
> the moment the subquery's result list contains even a single `NULL`.
> This has shipped real bugs to production at real companies. Read this
> section carefully and default to `NOT EXISTS` for "does not match"
> queries unless you have specifically verified the subquery column can
> never be `NULL`.

### The safe case, revisited

Recall Example 2 from §8.4:

```sql
SELECT category_id, category_name
FROM   categories
WHERE  category_id NOT IN (SELECT category_id FROM products);
```

This worked correctly (`Electronics`, `Fashion`) because `products.category_id`
is populated for every row in the seed data — the subquery's result list
never contains `NULL`.

### The broken query

Now look at `categories.parent_category_id`, which **is** `NULL` for every
top-level category (Electronics, Fashion, Home & Kitchen have no parent).
Suppose we want "leaf" categories — categories that are never used as
someone else's parent:

```sql
-- BROKEN — do not use NOT IN like this
SELECT category_id, category_name
FROM   categories
WHERE  category_id NOT IN (SELECT parent_category_id FROM categories);
```

**Expected output:**

| category_id | category_name |
|-------------|----------------|
| *(no rows)* |                |

**Zero rows.** Every single category — including obvious leaves like
Mobiles, Laptops, Men, Women, and Home & Kitchen — is silently excluded.

### Why it's broken — three-valued logic, step by step

1. The subquery `SELECT parent_category_id FROM categories` scans all 7
   category rows and returns: `NULL, 1, 1, NULL, 4, 4, NULL` (as a set:
   `{NULL, 1, 4}`).
2. `NOT IN` unfolds into an `AND`-chain of inequalities against **every**
   value the subquery returned:
   ```
   category_id <> NULL  AND  category_id <> 1  AND  category_id <> 4
   ```
3. In SQL's three-valued logic, any comparison against `NULL` — including
   `<>` — evaluates to `UNKNOWN`, never `TRUE` or `FALSE`.
   `category_id <> NULL` is `UNKNOWN` **regardless of what `category_id`
   is.**
4. `UNKNOWN AND anything` can only ever be `UNKNOWN` or `FALSE` — it can
   **never become `TRUE`**, no matter how the other two conditions
   evaluate.
5. `WHERE` keeps a row only when its condition evaluates to `TRUE`.
   `UNKNOWN` and `FALSE` are both discarded.
6. Therefore **every row's `WHERE` condition evaluates to `UNKNOWN` or
   `FALSE`, never `TRUE`** — the query returns nothing, for every category,
   regardless of whether it's actually a leaf or not.

This is not a PostgreSQL quirk — it is the ANSI SQL standard's three-valued
logic (`TRUE`/`FALSE`/`UNKNOWN`), and it reproduces identically in every
dialect:

| Dialect | Same bug reproduces? |
|---|---|
| **[PostgreSQL]** | Yes — 0 rows |
| **[MySQL]** | Yes — 0 rows |
| **[Oracle]** | Yes — 0 rows |
| **[SQL Server]** | Yes — 0 rows |

### The fix — `NOT EXISTS`

```sql
SELECT c.category_id, c.category_name
FROM   categories c
WHERE  NOT EXISTS (
    SELECT 1 FROM categories child
    WHERE  child.parent_category_id = c.category_id
)
ORDER  BY c.category_id;
```

**Expected output:**

| category_id | category_name    |
|-------------|-------------------|
| 2           | Mobiles           |
| 3           | Laptops           |
| 5           | Men               |
| 6           | Women             |
| 7           | Home & Kitchen    |

**Why this works:** `NOT EXISTS` never compares `c.category_id` against a
`NULL` value directly. It asks, per outer row, "is there any row in
`categories` whose `parent_category_id` equals *this specific*
`category_id`?" For categories 1 (Electronics) and 4 (Fashion), the answer
is yes (they have children), so they're excluded. For every other category,
the answer is no, so they're included. The `NULL` parent values belonging
to the *top-level* rows themselves never enter into the comparison at all —
`NOT EXISTS` only cares about matching rows, and `NULL <> anything` never
becomes a spurious "match" or a poisoning `UNKNOWN` that propagates outward.

### Alternative fix — filter `NULL` out of the `IN` list

If you want to keep using `NOT IN`, you can neutralize the trap by
explicitly excluding `NULL` from the subquery:

```sql
SELECT category_id, category_name
FROM   categories
WHERE  category_id NOT IN (
    SELECT parent_category_id FROM categories WHERE parent_category_id IS NOT NULL
)
ORDER  BY category_id;
```

This returns the same correct 5-row result. It works, but it depends on
you (or every future maintainer of this query) remembering to add the
`IS NOT NULL` guard — one missed guard on one similar query, and the bug is
back. `NOT EXISTS` has no such trap to remember, which is why it's the
generally recommended default for "does-not-match" queries.

### A second, classic example (company_db)

The textbook version of this bug: "find employees who are not managers."

```sql
-- BROKEN: employees.manager_id is NULL for Aditi Rao (no manager) —
-- the subquery's result list contains NULL, so this returns 0 rows.
SELECT employee_id, first_name, last_name
FROM   employees
WHERE  employee_id NOT IN (SELECT manager_id FROM employees);
```

```sql
-- CORRECT
SELECT e.employee_id, e.first_name, e.last_name
FROM   employees e
WHERE  NOT EXISTS (
    SELECT 1 FROM employees m WHERE m.manager_id = e.employee_id
)
ORDER  BY e.employee_id;
```

The broken version returns zero rows even though most of the 16 employees
(everyone except Aditi Rao, Rahul Mehta, Sneha Kulkarni, Priya Nair, Rohan
Kapoor, Nikhil Gupta, and Rajesh Iyer — the people who appear as someone's
`manager_id`) are, in fact, not managers.

> **Important Note.** Positive `IN` (not negated) does **not** have this
> problem: `x IN (v1, v2, NULL)` can still correctly evaluate to `TRUE` if
> `x` matches `v1` or `v2` — a `NULL` in the list just contributes an
> `UNKNOWN` disjunct that's harmlessly ignored once another disjunct is
> `TRUE`. It's specifically the **negation** (`NOT IN`, `<> ALL`) that turns
> "harmless extra `UNKNOWN`" into "poisons the entire `AND`-chain."

---

## 8.9 Correlated Subqueries

### Simple explanation

A correlated subquery is a subquery that reaches **outside itself** and
uses a value from the current row of the outer query. Because that outer
value changes from row to row, the subquery's answer can change from row to
row too — conceptually, it has to be "re-asked" for every outer row.

### Technical explanation

A correlated subquery references a column from a table defined in the
enclosing (outer) query. It cannot be evaluated independently, because its
`WHERE` clause depends on a value that only exists in the context of "the
current outer row." Formally, the outer query's from-list is in scope for
the inner query's `WHERE`/`SELECT` clauses.

### Why they exist

Some comparisons are inherently row-relative: "more than the average of
*my own* department," "priced above the average of *my own* category,"
"has *this specific customer* reviewed *this specific product*." These
questions can't be answered by a single global scalar — the reference
point itself depends on which row you're looking at.

### Full syntax

```sql
SELECT outer_alias.column_list
FROM   table_a AS outer_alias
WHERE  outer_alias.column_x <operator> (
    SELECT aggregate_or_column
    FROM   table_a AS inner_alias        -- can be the same table, different alias
    WHERE  inner_alias.grouping_column = outer_alias.grouping_column   -- the correlation
);
```

### Conceptual execution trace

Take the classic example: **find products priced above the average price
in their own category.**

```sql
SELECT p.product_name, c.category_name, p.price
FROM   products p
JOIN   categories c ON c.category_id = p.category_id
WHERE  p.price > (
    SELECT ROUND(AVG(p2.price), 2)
    FROM   products p2
    WHERE  p2.category_id = p.category_id
)
ORDER  BY c.category_name, p.price DESC;
```

Logically — **not necessarily how the optimizer actually executes it, but
how you should reason about correctness** — the engine walks through the
10 outer rows one at a time:

| Outer row (`p`) | Category | Inner query re-runs as... | Category avg | `p.price > avg`? |
|---|---|---|---|---|
| Galaxy Phone X (45999.00) | Mobiles | `AVG(price)` WHERE `category_id = 2` → (45999+29999+3499)/3 | 26499.00 | 45999.00 > 26499.00 → **TRUE** |
| Pixel Lite (29999.00) | Mobiles | same subquery, `category_id = 2` | 26499.00 | 29999.00 > 26499.00 → **TRUE** |
| Wireless Earbuds (3499.00) | Mobiles | same subquery, `category_id = 2` | 26499.00 | 3499.00 > 26499.00 → FALSE |
| UltraBook Pro 14 (89999.00) | Laptops | `AVG(price)` WHERE `category_id = 3` → (89999+74999+799)/3 | 55265.67 | 89999.00 > 55265.67 → **TRUE** |
| GameBook 15 (74999.00) | Laptops | same subquery, `category_id = 3` | 55265.67 | 74999.00 > 55265.67 → **TRUE** |
| Laptop Sleeve 14" (799.00) | Laptops | same subquery, `category_id = 3` | 55265.67 | 799.00 > 55265.67 → FALSE |
| Men Cotton Shirt (1299.00) | Men | `AVG(price)` WHERE `category_id = 5` → 1299.00 (only product) | 1299.00 | 1299.00 > 1299.00 → FALSE |
| Women Kurta Set (1799.00) | Women | `AVG(price)` WHERE `category_id = 6` → 1799.00 (only product) | 1799.00 | 1799.00 > 1799.00 → FALSE |
| Non-stick Pan Set (2499.00) | Home & Kitchen | `AVG(price)` WHERE `category_id = 7` → (2499+1499)/2 | 1999.00 | 2499.00 > 1999.00 → **TRUE** |
| Electric Kettle (1499.00) | Home & Kitchen | same subquery, `category_id = 7` | 1999.00 | 1499.00 > 1999.00 → FALSE |

**Expected output:**

| product_name       | category_name    | price     |
|--------------------|-------------------|-----------|
| Non-stick Pan Set   | Home & Kitchen    | 2499.00   |
| UltraBook Pro 14    | Laptops           | 89999.00  |
| GameBook 15         | Laptops           | 74999.00  |
| Galaxy Phone X       | Mobiles           | 45999.00  |
| Pixel Lite           | Mobiles           | 29999.00  |

**Line-by-line:** For each row in the outer `products p`, the inner query
`SELECT ROUND(AVG(p2.price),2) FROM products p2 WHERE p2.category_id =
p.category_id` re-runs with `p.category_id` bound to that specific row's
category — Mobiles' rows get Mobiles' average, Laptops' rows get Laptops'
average, and so on. Note that Men and Women each have only one product, so
that product *is* the category average — and a single value is never
strictly greater than itself, so single-product categories never produce a
match with a strict `>` comparison.

### Internal / execution-model explanation

Logically, a correlated subquery is a per-row loop: bind the outer row's
value, execute the inner query, use the result, move to the next outer row.
This is genuinely how simple, unindexed nested-loop execution works, and
it's the right mental model for *reasoning about correctness*.

In practice, PostgreSQL's planner often **decorrelates** simple correlated
subqueries like the one above — rewriting them internally into a join
against a pre-aggregated derived table (group by `category_id`, compute
`AVG`, join back), so the average is computed once per *category*, not once
per *product row*. Run `EXPLAIN ANALYZE` on the query above (Chapter 17
covers plan-reading) to see whether your PostgreSQL version performs this
rewrite. Either way, **the logical result is identical** — the execution
model only affects performance, never correctness.

> **⚠️ Warning — correlated subqueries can be a serious performance trap
> on large tables**, specifically when the optimizer *cannot* decorrelate
> them (complex conditions, non-equality correlations, certain aggregate
> shapes). In the worst case, a correlated subquery that the planner
> cannot rewrite executes once per outer row — an "N+1 query" problem
> inside a single SQL statement. Always check `EXPLAIN ANALYZE` (Chapter 17)
> before shipping a correlated subquery against a large table.

### A correlated scalar subquery in the `SELECT` list

**Question:** For each order, show how many distinct line items it
contains.

```sql
SELECT o.order_id,
       (SELECT COUNT(*) FROM order_items oi WHERE oi.order_id = o.order_id) AS item_count
FROM   orders o
ORDER  BY o.order_id;
```

**Expected output:**

| order_id | item_count |
|----------|------------|
| 1        | 2          |
| 2        | 2          |
| 3        | 1          |
| 4        | 2          |
| 5        | 1          |
| 6        | 2          |
| 7        | 1          |
| 8        | 1          |
| 9        | 2          |
| 10       | 1          |

**Line-by-line:** For each of the 10 orders, the correlated subquery
`COUNT(*) FROM order_items WHERE order_id = o.order_id` is conceptually
re-evaluated with `o.order_id` bound to that row's ID, counting only that
order's line items.

### Advanced example — employees earning more than their department's current average salary

`salaries` stores **history** (multiple rows per employee over time), so
"current salary" itself requires a subquery: the row with the latest
`effective_date` per employee.

**Step 1 — a correlated scalar subquery to isolate each employee's most
recent salary row:**

```sql
SELECT s.employee_id, s.base_salary, s.effective_date
FROM   salaries s
WHERE  s.effective_date = (
    SELECT MAX(s2.effective_date) FROM salaries s2 WHERE s2.employee_id = s.employee_id
)
ORDER  BY s.employee_id;
```

**Expected output (16 rows, one per employee):**

| employee_id | base_salary | effective_date |
|---|---|---|
| 1 | 520000.00 | 2020-01-01 |
| 2 | 320000.00 | 2021-01-01 |
| 3 | 210000.00 | 2022-01-01 |
| 4 | 140000.00 | 2022-01-01 |
| 5 | 120000.00 | 2019-09-01 |
| 6 | 80000.00  | 2020-02-10 |
| 7 | 300000.00 | 2021-01-01 |
| 8 | 110000.00 | 2017-04-18 |
| 9 | 95000.00  | 2021-03-22 |
| 10 | 240000.00 | 2016-08-09 |
| 11 | 100000.00 | 2019-01-14 |
| 12 | 250000.00 | 2016-12-01 |
| 13 | 130000.00 | 2018-06-25 |
| 14 | 230000.00 | 2017-09-30 |
| 15 | 105000.00 | 2020-10-05 |
| 16 | 95000.00  | 2022-01-10 |

**Step 2 — wrap that as a derived table (a subquery in `FROM`, previewing
§8.10), then filter against the department's own average of those current
salaries** (another correlated subquery):

```sql
SELECT e.first_name, e.last_name, d.department_name, cs.base_salary AS current_salary
FROM   employees e
JOIN   departments d ON d.department_id = e.department_id
JOIN  (
    SELECT s.employee_id, s.base_salary
    FROM   salaries s
    WHERE  s.effective_date = (SELECT MAX(s2.effective_date) FROM salaries s2 WHERE s2.employee_id = s.employee_id)
) AS cs ON cs.employee_id = e.employee_id
WHERE cs.base_salary > (
    SELECT ROUND(AVG(cs2.base_salary), 2)
    FROM   employees e2
    JOIN  (
        SELECT s.employee_id, s.base_salary
        FROM   salaries s
        WHERE  s.effective_date = (SELECT MAX(s2.effective_date) FROM salaries s2 WHERE s2.employee_id = s.employee_id)
    ) AS cs2 ON cs2.employee_id = e2.employee_id
    WHERE e2.department_id = e.department_id
)
ORDER  BY d.department_name, current_salary DESC;
```

**Expected output:**

| first_name | last_name | department_name | current_salary |
|---|---|---|---|
| Aditi   | Rao    | Engineering | 520000.00 |
| Rahul   | Mehta  | Engineering | 320000.00 |
| Nikhil  | Gupta  | Finance     | 250000.00 |
| Rohan   | Kapoor | HR          | 240000.00 |
| Rajesh  | Iyer   | Marketing   | 230000.00 |
| Priya   | Nair   | Sales       | 300000.00 |

**Department averages used (for reference):** Engineering 212142.86 (7
employees), Sales 168333.33 (3), HR 170000.00 (2), Finance 190000.00 (2),
Marketing 167500.00 (2). Note Sneha Kulkarni (210000.00, Engineering) is
*close* to her department's average (212142.86) but does not clear it —
a good reminder to compare against the *exact* computed average, not a
rounded eyeball figure.

> **Important Note.** This query nests the same "latest salary per
> employee" derived table **twice** — once for the outer employee, once
> inside the department-average subquery. That repetition is not a style
> mistake; it's a structural limitation of plain subqueries: there's no way
> to compute something once and refer to it twice within a single query.
> This exact pain point is what Chapter 9's CTEs (`WITH current_salaries
> AS (...)`) are built to solve — keep this example in mind when you get
> there.

---

## 8.10 Subqueries in the `FROM` Clause (Derived Tables)

A subquery can act as a table source in `FROM`. It is often called a
**derived table** or **inline view**. PostgreSQL and MySQL require it to
have an alias.

```sql
SELECT dt.category_id, dt.avg_price
FROM (
    SELECT category_id, ROUND(AVG(price), 2) AS avg_price
    FROM   products
    GROUP  BY category_id
) AS dt
WHERE dt.avg_price > 20000
ORDER BY dt.avg_price DESC;
```

**Expected output:**

| category_id | avg_price |
|-------------|-----------|
| 3           | 55265.67  |
| 2           | 26499.00  |

This is functionally identical to a Chapter 9 CTE (`WITH dt AS (...)
SELECT ...`) — the difference is purely syntactic and readability-related:
a derived table is defined inline, nested where it's used, and cannot be
referenced a second time in the same query without repeating its full
definition (as seen in the advanced salary example above). A CTE is named
once, up front, and can be referenced multiple times. Chapter 9 covers this
trade-off in full.

---

## 8.11 Common Mistakes

1. **Using a multi-row subquery where a scalar is expected.** Covered in
   §8.3 — causes a hard runtime error (`more than one row returned...`),
   not a silent wrong answer. Easy to catch in testing, but easy to
   introduce by adding a `WHERE` filter to a table you thought was
   unique-keyed and no longer is.
2. **`NOT IN` with a subquery column that can be `NULL`.** Covered in
   depth in §8.8 — silently returns too few (often zero) rows. This is the
   costliest mistake in this chapter because it produces no error at all.
3. **Forgetting `DISTINCT` when converting a semi-join question into a
   `JOIN`.** `IN`/`EXISTS` never duplicate outer rows; an inner `JOIN`
   will, once per matching inner row. See §8.14.
4. **Reaching for a subquery when a plain `JOIN` is clearer and faster.**
   If you need columns *from* the related table in your final output (not
   just a filter), a `JOIN` is usually the right tool — a subquery in
   `WHERE` cannot project columns from the inner query into the outer
   result set.
5. **Writing a correlated subquery when a window function would be
   simpler and faster.** "Price vs. category average" (§8.9) can also be
   written with `AVG(price) OVER (PARTITION BY category_id)` (Chapter 10) —
   often computed in a single pass instead of one sub-evaluation per
   category.
6. **Ambiguous aliasing that accidentally self-correlates (or fails to
   correlate).** If you forget to alias the inner and outer references to
   the same table distinctly, column references can resolve to the wrong
   scope. Always alias both sides explicitly (`p` vs. `p2`, `e` vs. `e2`)
   even when it feels redundant — it prevents a whole class of subtle
   bugs.
7. **Assuming `EXISTS` is always faster than `IN`, or vice versa, without
   checking `EXPLAIN ANALYZE`.** Modern planners frequently produce
   identical plans for both. Optimize based on measurement, not folklore.

---

## 8.12 Edge Cases

| Scenario | Behavior |
|---|---|
| Scalar subquery returns 0 rows | Evaluates to `NULL` — no error (§8.3) |
| Scalar subquery returns >1 row, used with `=`/`>`/`<` | Runtime error (§8.3) |
| `IN (subquery)` where subquery returns 0 rows | `WHERE x IN ()` is always `FALSE` — outer query returns 0 rows, no error |
| `NOT IN (subquery)` where subquery returns 0 rows | Always `TRUE` — outer query returns **all** rows (the opposite of the NULL trap — an empty list poisons nothing) |
| `NOT IN (subquery)` where subquery returns any `NULL` | Always `FALSE` for every row — 0 rows, silently (§8.8) |
| `EXISTS (subquery)` where subquery's selected columns are all `NULL` | Still `TRUE` — existence, not value, is what's tested |
| Correlated subquery whose correlation column is `NULL` in the outer row | The inner `WHERE ... = NULL` is `UNKNOWN` for every inner row, so the subquery returns 0 rows for that outer row (or `NULL` in scalar position) |

> **Important Note.** The "`NOT IN` on an empty subquery returns all rows"
> case is easy to confuse with the NULL trap, but it's the opposite
> failure mode: an empty list is harmless (`NOT IN ()` is vacuously true
> for everything), while a list *containing* `NULL` is catastrophic
> (`NOT IN (..., NULL)` is `UNKNOWN`/false for everything). Know which one
> your data can actually produce.

---

## 8.13 Subqueries vs. Joins vs. CTEs — When to Use What

| Use a **subquery** when... | Use a **JOIN** when... | Use a **CTE** (Chapter 9) when... |
|---|---|---|
| You only need a filter or a single computed value, not extra columns from the related table | You need to display/select columns from both tables | The same subquery logic is needed more than once in a statement |
| The relationship is naturally existence- or aggregate-based (`EXISTS`, `AVG` comparison) | The relationship is naturally a row-for-row combination | You want a name and a horizontal separation of "steps" for readability |
| The query is a one-off filter, unlikely to be reused | Performance is critical and the planner handles joins more predictably than deeply nested subqueries | You need recursion (impossible with a plain subquery) — Chapter 9 |
| You want to keep the outer query's grain (one row per outer row) unchanged | You're fine with (or want) duplicate outer rows per match | You're building a multi-stage transformation pipeline |

**Rule of thumb:** if you find yourself writing the *same* subquery twice
in one statement (as happened in the advanced salary example, §8.9), that's
a strong signal to reach for a CTE instead — same logic, computed once,
referenced by name. Chapter 9 picks up exactly there.

---

## 8.14 `EXISTS` vs. `IN` vs. `JOIN` (Semi-Join) — Result Set Equivalence and Divergence

**Question:** Which users have placed at least one order?

**Using `EXISTS` (a true semi-join — never duplicates):**

```sql
SELECT u.username
FROM   users u
WHERE  EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.user_id)
ORDER  BY u.username;
```

**Expected output — 8 rows, one per user:**

| username |
|---|
| arjun_k |
| dev_m |
| farhan_a |
| imran_s |
| lakshmi_v |
| nita_r |
| sara_p |
| tanya_b |

**Using `IN` — identical result:**

```sql
SELECT username
FROM   users
WHERE  user_id IN (SELECT user_id FROM orders)
ORDER  BY username;
```

Same 8 rows — `orders.user_id` is `NOT NULL` (a required foreign key), so
this `IN` is safe and produces the exact same semi-join result as `EXISTS`.

**Using an inner `JOIN` — diverges (duplicates!):**

```sql
SELECT u.username
FROM   users u
JOIN   orders o ON o.user_id = u.user_id
ORDER  BY u.username;
```

**Expected output — 10 rows (one per order, not per user):**

| username |
|---|
| arjun_k |
| arjun_k |
| arjun_k |
| dev_m |
| farhan_a |
| imran_s |
| lakshmi_v |
| nita_r |
| sara_p |
| tanya_b |

**Why they differ:** `arjun_k` (user 1) has placed 3 orders (orders 1, 3,
8), so the `JOIN` produces 3 output rows for that single user — one per
matching order. `EXISTS`/`IN` are **semi-joins**: they test membership and
return the outer row **at most once**, no matter how many inner rows match.
If you need the `JOIN`'s columns but the `EXISTS`/`IN` cardinality, add
`SELECT DISTINCT` to the `JOIN` version — but that's strictly more work
(and, on unindexed data, potentially more expensive) than writing the
semi-join directly.

**A third alternative for the negative case — `LEFT JOIN ... WHERE ... IS
NULL` (anti-join):**

```sql
SELECT u.username
FROM   users u
LEFT JOIN orders o ON o.user_id = u.user_id
WHERE  o.order_id IS NULL;
```

This is the `JOIN`-based equivalent of `NOT EXISTS`, and it shares
`NOT EXISTS`'s immunity to the `NULL` trap — it tests for the *absence of a
matching row*, not for membership in a value list, so it never runs into
three-valued-logic poisoning. In this dataset, every user has at least one
order, so this particular query returns 0 rows (correctly).

| Approach | Duplicates possible? | Safe with `NULL`s in the "other side" column? |
|---|---|---|
| `EXISTS` / `NOT EXISTS` | No | Yes, always |
| `IN` | No | Yes (positive `IN` is safe even with `NULL`s in the list) |
| `NOT IN` | No | **No — see §8.8** |
| `JOIN` (inner) | Yes, one row per match | N/A (not an existence test) |
| `LEFT JOIN ... IS NULL` (anti-join) | No | Yes, always |

---

## 8.15 Real-World Use Cases

- **Anomaly / outlier detection**: "orders priced far above the average
  order value," "employees paid well above their department's norm" —
  scalar and correlated subqueries.
- **Data quality / orphan-row detection**: "products that were never
  ordered," "payments with no matching order" — `NOT EXISTS` /
  anti-joins, run as scheduled data-quality checks.
- **Business rule gating**: "does this customer already have a pending
  order before we let them check out again" — `EXISTS` used inside
  application-level guard queries.
- **Cohort/reporting comparisons**: "this row vs. the company-wide
  average" — scalar subquery in the `SELECT` list, common in dashboards.
- **Eligibility / compliance checks**: "employees who have never taken
  attendance in the system" or "customers who have an active order but no
  successful payment" — correlated `NOT EXISTS` checks.
- **Catalog curation**: "categories with no products" (§8.4/§8.6), used to
  find dead navigation entries in an e-commerce admin panel.
- **Engagement analysis**: the chapter challenge below — "customers who
  purchased but never reviewed" — a very common retention/engagement query
  in real e-commerce analytics.

---

## 8.16 Practice Questions

No answers are provided — write and run each query against the seed data,
then verify the row counts and values yourself.

1. **(Scalar)** Using `company_db`, find all employees whose most recent
   `base_salary` (see §8.9 for the "latest row per employee" pattern) is
   above the company-wide average of *all* employees' most recent
   salaries.
2. **(Scalar, SELECT list)** For each product in `ecommerce_db`, show its
   price alongside the overall average product price, and a third column
   that's the difference between the two.
3. **(Single-row)** Find the department in `company_db` with the
   smallest total project budget (hint: you'll need to aggregate
   `projects.budget` by `department_id` before comparing).
4. **(Multi-row / IN)** Find all products in `ecommerce_db` that belong
   to a category whose `category_name` starts with the letter `M`.
5. **(Multi-row / NOT IN — safe case)** Find all employees in
   `company_db` who have never appeared in the `attendance` table. Confirm
   the subquery column (`employee_id` in `attendance`) can never be
   `NULL` before trusting `NOT IN` here.
6. **(The trap, explicitly)** Using `company_db.managers`, write a query
   using `NOT IN` to find employees who are not department managers by
   comparing `employee_id` against `managers.manager_id`. Is
   `managers.manager_id` ever `NULL`? Now do the same comparison against
   `employees.manager_id` instead — does the result change, and why?
   Rewrite both using `NOT EXISTS` and confirm which version(s) were
   actually correct to begin with.
7. **(ANY / ALL)** Using `ecommerce_db`, find all products priced lower
   than **any** product in the Laptops category, and separately, all
   products priced lower than **all** products in the Laptops category.
   Explain in your own words why the two results differ.
8. **(EXISTS)** Find all categories in `ecommerce_db` that have at least
   one product priced above 50000.
9. **(NOT EXISTS)** Find all products in `ecommerce_db` that have never
   appeared in any `order_items` row (i.e., never been ordered).
10. **(Correlated)** Find every order in `ecommerce_db` whose total value
    (sum of `quantity * unit_price` from `order_items`) exceeds the
    average total value of *all other orders placed by the same user*
    (careful — "other orders by the same user" is a correlation on
    `user_id`, not `order_id`).
11. **(EXISTS vs. JOIN)** Write a query that returns each department in
    `company_db` that has at least one employee with `status = 'ON_LEAVE'`,
    once using `EXISTS`, once using an inner `JOIN` with `DISTINCT`.
    Confirm both return the same set, then remove the `DISTINCT` from the
    `JOIN` version and explain what changes.
12. **(Mixed / capstone-style)** Find all users in `ecommerce_db` who have
    a `DELIVERED` order but have never left a review for *any* product at
    all (not necessarily the product they bought — a broader, easier
    version of the chapter challenge below).

---

## 8.17 Chapter Challenge

**Scenario:** The product team wants a retention/engagement report: which
customers have bought something but never reviewed **that specific
product**? This is a genuinely common e-commerce query — it drives
"leave a review" reminder emails.

**Your task:** write a single query against `ecommerce_db` that returns
the distinct `username` of every user who has purchased at least one
product (via `orders` → `order_items`) for which that *same user* has never
submitted a row in `reviews` for that *same product*.

**Requirements:**
- Must use a **correlated subquery** (via `NOT EXISTS`) to check, per
  purchased product per user, whether a matching review row is missing.
- Must **not** use `NOT IN` for this check — think about why: could the
  `reviews` table (or your subquery's projection of it) ever put a `NULL`
  into a `NOT IN` list here, and would you always be sure?
- Think through, and be ready to justify, these edge cases before you
  write the final query:
  - Should a `CANCELLED` order still count as a "purchase" for this
    report? Justify your choice either way.
  - If a user bought the *same* product in two different orders, does
    that create any duplicate-row risk in your final `SELECT DISTINCT`?
  - Is the check "reviewed *that* product" or "reviewed *anything at
    all*"? Make sure your `NOT EXISTS` subquery correlates on **both**
    `user_id` and `product_id`, not just one.

No solution is provided here — this chapter has already given you every
building block (correlated `NOT EXISTS`, multi-table joins from Chapter 7,
and the semi-join reasoning from §8.14) needed to construct it yourself.

---

## Key Takeaways

- A subquery is a `SELECT` nested inside another statement; it can appear
  in the `SELECT` list, `FROM`, `WHERE`, or `HAVING` clauses.
- **Scalar subqueries** must return exactly one row and one column;
  returning zero rows yields `NULL` (no error), returning multiple rows
  with a single-row operator is a **runtime error**.
- **`IN`/`NOT IN`** test set membership using `OR`/`AND` chains of
  equality/inequality respectively — and that `AND`-chain is exactly why
  **`NOT IN` breaks silently (returns nothing useful) if its subquery can
  return `NULL`.** Default to `NOT EXISTS` for "does not match" logic.
- **`ANY`/`ALL`** generalize comparisons against a multi-row subquery;
  `= ANY` behaves like `IN`, and `<> ALL` behaves like — and inherits the
  same `NULL` trap as — `NOT IN`.
- **`EXISTS`/`NOT EXISTS`** test only for row existence, never compare
  actual values, and are therefore immune to the `NULL`-poisoning that
  plagues `NOT IN`. They're the safe, idiomatic default for existence
  checks.
- **Correlated subqueries** reference an outer column and are conceptually
  re-evaluated per outer row; modern planners often decorrelate simple
  cases into joins/aggregates, but you should reason about correctness
  using the per-row mental model regardless of the actual execution plan.
- `EXISTS`, `IN`, and `JOIN` can return the *same* rows for existence-style
  questions, but an inner `JOIN` **duplicates** the outer row once per
  matching inner row, while `EXISTS`/`IN` (true semi-joins) never do.
- Repeated subquery logic within one statement (seen in the advanced
  salary example) is the clearest signal that a CTE — not a nested
  subquery — is the right tool. That's exactly where Chapter 9 begins.

---

## What's Next

[Chapter 9 — Common Table Expressions & Recursive CTEs](09-ctes.md) takes
the exact pain points from this chapter — repeated subquery logic, deeply
nested derived tables, unreadable multi-level nesting like the department
salary example in §8.9 — and solves them with `WITH` clauses: named,
reusable, and (with `RECURSIVE`) capable of walking hierarchies like the
`employees.manager_id` chain or the `categories.parent_category_id` tree
that this chapter's `NOT IN`/`NOT EXISTS` examples were built on.
