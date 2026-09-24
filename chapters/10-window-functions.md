# Chapter 10 — Window Functions (Very Deep)

> **Part of:** Part III — Intermediate SQL
> **Databases used:** `company_db` (`departments`, `employees`, `salaries`, `attendance`) and `ecommerce_db` (`categories`, `products`, `orders`, `order_items`)
> **Prerequisites:** Chapter 6 (Aggregate Functions, `GROUP BY`, `HAVING`), Chapter 7 (JOINs), Chapter 8 (Subqueries), Chapter 9 (CTEs & Recursive CTEs)
> **Sets up:** Chapter 11 (Transactions & ACID), Chapter 17 (Query Execution & the Query Planner — where we revisit the sort cost this chapter foreshadows), Chapter 31 (Advanced SQL Patterns — gaps/islands, cohorts, and SCD revisited at production scale)

Before running anything in this chapter, load both databases:

```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
```

Every query and every result table in this chapter was mechanically verified against the exact seed rows in those two files (cross-checked on a SQL engine with full window-function support, using PostgreSQL's documented semantics for frame defaults and `NULL` ordering). If you type these queries yourself against a freshly loaded `company_db`/`ecommerce_db`, you will get exactly the outputs shown.

---

## 10.0 Why This Chapter Matters

Chapter 6 taught you `GROUP BY`: collapse many rows into one summary row per group. That's an enormously powerful tool, but it has a hard limitation baked into its design — **the moment you group, you lose the individual row.** If you ask "what is the average salary per department?" with `GROUP BY`, you get back 5 rows (one per department) and the 16 individual employees are gone from the result. You can no longer show *Aditi's* salary next to *her department's* average in the same row, because `GROUP BY` fundamentally *replaces* the detail rows with the summary rows.

But an enormous number of real business questions need **both at once**:

- "Show every employee, their salary, **and** their department's average salary, side by side." (Can't collapse — need every employee row *plus* a group-level number attached to each.)
- "Show every order, plus a running total of revenue up to that point." (Needs every order row, in order, with an accumulating value.)
- "Rank employees by salary *within* their department, without hiding anyone." (Needs every employee row, plus a rank number computed relative to their peers.)
- "For each employee, what did they earn last quarter compared to this quarter?" (Needs to look at a *different row* — the previous one — without a self-join.)

**Window functions** are SQL's answer to exactly this class of problem. A window function computes an aggregate-like value — a rank, a running total, an average, a reference to a neighboring row — **per row**, using a calculated "window" of related rows, **while returning every original row untouched**. Nothing is collapsed. This is the single idea this entire chapter builds on, and it's why window functions are sometimes called "analytic functions" (their name in Oracle and several other systems).

This chapter is deliberately the deepest one in the course so far, because window functions are simultaneously (a) one of the highest-leverage tools in professional SQL — leaderboards, dashboards, financial running balances, cohort analysis, top-N reports — and (b) one of the most misunderstood, because the "frame clause" that controls exactly which rows a function sees is subtle, has silently different defaults depending on whether `ORDER BY` is present, and produces the single most common "why did `LAST_VALUE` give me the wrong answer" bug in all of SQL. We will not rush past any of that.

---

## 10.1 The Core Idea — What Is a Window Function?

### 1. Simple explanation

A window function looks at a "window" — a defined slice of rows related to the current row (for example, "all rows in the same department," or "all rows from the start of the table up to this one") — and computes a value from that window, **without erasing the current row**. Every row you started with is still there in the output; it just now has an extra computed column attached to it.

### 2. Technical explanation

A window function is any function invoked with an `OVER` clause. The `OVER` clause defines the **window** — the set of rows, relative to the current row, that the function is allowed to look at — via three optional components: `PARTITION BY` (which rows count as "related" to this one), `ORDER BY` (what order those related rows are considered in), and a **frame clause** (exactly which subset of the ordered, partitioned rows are visible to the function *for this particular row*). The function is evaluated once per row of the query's result set, each time potentially looking at a different window, but it never reduces the number of rows returned.

### 3. Why it exists — the problem `GROUP BY` cannot solve

`GROUP BY` answers "one row per group." Window functions answer "one row per *original* row, annotated with something computed from its group (or its neighbors, or the whole result set)." These are fundamentally different shapes of answer, and no amount of clever `GROUP BY`/`JOIN` combination fully replaces a window function without resorting to a self-join or correlated subquery — both of which are typically far more verbose and, for many of these patterns (running totals, `LAG`/`LEAD`, ranking with ties), cannot be expressed at all without a window function or a recursive/iterative workaround. We give this comparison its own full deep-dive section (§10.9), because understanding precisely when you need `GROUP BY` versus when you need a window function is the single most practically useful judgment call this chapter teaches.

### 4. Full syntax of `OVER()`

```sql
function_name(argument, ...) OVER (
    [PARTITION BY partition_expression, ...]
    [ORDER BY sort_expression [ASC | DESC] [NULLS FIRST | NULLS LAST], ...]
    [frame_clause]
)
```

- **`function_name(argument)`** — any of the ranking functions (`ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE`), the offset/value functions (`LAG`, `LEAD`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE`), or a regular aggregate function used in window mode (`SUM`, `AVG`, `COUNT`, `MIN`, `MAX`, etc.).
- **`PARTITION BY`** — optional. Splits the result set into independent groups, exactly like `GROUP BY` does for aggregation, **except rows are not collapsed**. If omitted, the entire result set is treated as one single partition.
- **`ORDER BY`** (inside `OVER`, distinct from any outer query `ORDER BY`) — optional, but *required* for anything involving sequence: running totals, `LAG`/`LEAD`, ranking. Defines the order in which rows within each partition are considered "before" or "after" the current row.
- **frame_clause** — optional, and this is where most of the confusion in this topic lives. It further restricts *which rows within the current partition* are visible to the function, relative to the current row. We give this its own full section (§10.2).

The parentheses after `OVER` can also be empty — `OVER ()` — meaning "no partitioning, no ordering, the whole result set is one window." You will use this constantly for things like "total row count alongside every row" or "grand total alongside every detail row."

### 5–7. A first example, with output and a trace

**Simplest possible window function — attach the grand total row count to every row:**

```sql
SELECT order_id, user_id, status,
       COUNT(*) OVER () AS total_orders_in_result
FROM ecommerce_db.orders
ORDER BY order_id
LIMIT 4;
```

**Expected output:**

| order_id | user_id | status | total_orders_in_result |
|---|---|---|---|
| 1 | 1 | DELIVERED | 10 |
| 2 | 2 | DELIVERED | 10 |
| 3 | 1 | SHIPPED | 10 |
| 4 | 3 | PAID | 10 |

Line-by-line trace: `FROM orders` produces all 10 order rows. There is no `WHERE`, no `GROUP BY`. `COUNT(*) OVER ()` has an empty `OVER ()` — no `PARTITION BY`, no `ORDER BY`, no frame — which means its window is *the entire result set*, for *every single row*. So every one of the 10 output rows gets the same value, `10`, attached to it as an ordinary extra column, while all 10 original rows survive untouched. Compare this to `SELECT COUNT(*) FROM orders`, which would have collapsed those same 10 rows into a single summary row containing just `10` — the window-function version keeps every row **and** attaches the aggregate.

**A second example — introduce `PARTITION BY`:**

```sql
SELECT order_id, user_id, status,
       COUNT(*) OVER (PARTITION BY user_id) AS orders_by_this_user
FROM ecommerce_db.orders
ORDER BY user_id, order_id;
```

**Expected output (first 4 rows):**

| order_id | user_id | status | orders_by_this_user |
|---|---|---|---|
| 1 | 1 | DELIVERED | 3 |
| 3 | 1 | SHIPPED | 3 |
| 8 | 1 | DELIVERED | 3 |
| 2 | 2 | DELIVERED | 1 |

**Conceptual trace of the "window" visible to two specific rows:**

- For the row `order_id = 1` (user 1): its window, under `PARTITION BY user_id`, is *every row in the result set that shares `user_id = 1`* — that's orders 1, 3, and 8 (user 1 placed three orders total, per the seed data). `COUNT(*)` over that 3-row window returns `3`, and that `3` is attached to *this* row only, not merged with anyone else's row.
- For the row `order_id = 2` (user 2): its window is *every row that shares `user_id = 2`* — only order 2 itself, since user 2 has just one order in the seed data. `COUNT(*)` over that 1-row window returns `1`.

Every row still individually exists in the output; each one simply carries a number describing its own group.

### 8. Internal behavior — logical query processing order (precise)

This is one of the two most important diagrams in this chapter (the frame clause diagram in §10.2 is the other). SQL's logical order of execution, extended to show exactly where window functions sit, is:

```
 ┌───────────────┐
 │ 1. FROM/JOIN  │  Identify and combine source tables
 └───────┬───────┘
         ▼
 ┌───────────────┐
 │ 2. WHERE      │  Filter individual rows (no aggregates, no window functions here)
 └───────┬───────┘
         ▼
 ┌───────────────┐
 │ 3. GROUP BY   │  Bucket surviving rows into groups (if GROUP BY is present)
 └───────┬───────┘
         ▼
 ┌───────────────┐
 │ 4. HAVING     │  Filter entire groups using aggregate results
 └───────┬───────┘
         ▼
 ┌────────────────────────┐
 │ 5. WINDOW FUNCTIONS     │  Compute OVER(...) values, once per row that
 │    (evaluated here)     │  survived steps 1-4 — this is AFTER GROUP BY/HAVING
 └───────┬────────────────┘
         ▼
 ┌───────────────┐
 │ 6. SELECT     │  Compute output expressions/aliases (may reference window results)
 └───────┬───────┘
         ▼
 ┌───────────────┐
 │ 7. DISTINCT   │  De-duplicate rows, if SELECT DISTINCT is used
 └───────┬───────┘
         ▼
 ┌───────────────┐
 │ 8. ORDER BY   │  Sort the final rows (may reference SELECT aliases, including
 └───────┬───────┘  window-function aliases)
         ▼
 ┌───────────────┐
 │ 9. LIMIT      │  Trim to the requested row count
 └───────────────┘
```

**Written order you type:** `SELECT → FROM → WHERE → GROUP BY → HAVING → ORDER BY → LIMIT`
**Logical order the engine evaluates, with window functions placed precisely:** `FROM/JOIN → WHERE → GROUP BY → HAVING → WINDOW FUNCTIONS → SELECT → DISTINCT → ORDER BY → LIMIT`

Three consequences fall directly out of this diagram, and every one of them is a real, common source of bugs:

1. **Window functions can see the results of `GROUP BY`/`HAVING`**, if those are present — you can partition/order a window function by a grouping column or even by an aggregate computed in that same query, because grouping has already happened by the time window functions run.
2. **Window functions cannot be referenced in `WHERE` or `HAVING`**, because both of those clauses run *before* step 5, at which point no window function has been computed yet. This is precisely the same logical reason aggregate functions can't be used in `WHERE` (Chapter 6, §6.4) — you cannot filter on a value that doesn't exist yet at that stage of evaluation. We dedicate a full worked example to this in §10.14, because it is the single most common "how do I get top-N per group" stumbling block.
3. **Window functions *can* be referenced in `ORDER BY`**, since `ORDER BY` runs after step 5/6 — the window-function alias already exists by then.

**Performance foreshadowing:** to compute most window functions correctly, the engine typically has to **sort the rows within each partition** by the `ORDER BY` expression given inside `OVER(...)` (or, for pure aggregate window functions without an `ORDER BY`, it still generally needs to group rows by partition key). This sort is genuinely real work — for large tables, it is frequently the single most expensive operation in a query plan that uses window functions, and it is a separate sort from any `ORDER BY` on the outer query (they can, but don't have to, be the same sort). We will look at exactly how to read this in `EXPLAIN ANALYZE` output — as a `WindowAgg` node with a `Sort` feeding into it — in **Chapter 17 — Query Execution & the Query Planner**, and how to optimize it (matching indexes to the partition/order expressions to let the planner skip the explicit sort) in **Chapter 18 — SQL Performance Optimization**. For now, the mental model to keep is: *window functions are not free* — every `PARTITION BY ... ORDER BY ...` you add is a hint to the planner that it needs an ordered view of that partition, and ordering is not a constant-time operation.

### 9. Common mistake — using a window function directly in `WHERE`

```sql
-- ❌ ILLEGAL
SELECT employee_id, department_id, base_salary,
       ROW_NUMBER() OVER (PARTITION BY department_id ORDER BY base_salary DESC) AS rn
FROM current_salary_view
WHERE rn = 1;
```

**[PostgreSQL]** rejects this with: `ERROR: column "rn" does not exist` (if `rn` isn't a real column) or, if you try the window function expression directly in `WHERE`, `ERROR: window functions are not allowed in WHERE`. This is not a PostgreSQL quirk — it is standard SQL behavior enforced by every mainstream dialect, for exactly the logical-order reason explained in point 8 above: at the point `WHERE` is evaluated, window functions haven't run yet. The fix — wrapping the window function in a subquery or CTE and filtering the *outer* query — is the entire subject of §10.14 (Top-N Per Group).

### 10–13. Edge cases, when to use, comparisons, real-world use cases

These are covered in full depth as each specific function is introduced (§10.4 onward) and consolidated in §10.16–10.20. The rest of this chapter builds outward from this foundation, function by function and pattern by pattern.

---

## 10.2 Anatomy of `OVER()`: `PARTITION BY`, `ORDER BY`, and the Frame Clause

This section is the technical core of the chapter. If you understand everything here precisely, every subsequent function and pattern will make sense mechanically, not just "by example."

### `PARTITION BY` — restating precisely

`PARTITION BY expr1, expr2, ...` divides the rows visible to the window function into independent groups sharing identical values of `expr1, expr2, ...` — mechanically identical to how `GROUP BY` forms groups, **except no rows are removed or merged**. Every row keeps its own identity; it simply "sees" only the other rows in its own partition when the window function looks around. Omitting `PARTITION BY` entirely means there is exactly one partition: the whole result set.

### `ORDER BY` inside `OVER()` — restating precisely

`ORDER BY` inside `OVER(...)` establishes a **sequence** within each partition. This has two distinct effects, and beginners frequently only notice one of them:

1. It defines "before" and "after" for sequence-aware functions like `LAG`, `LEAD`, `ROW_NUMBER`, `RANK`, running totals, and moving averages — without it, "the previous row" or "row #3" is meaningless.
2. **It silently changes the default frame** (explained fully below) from "the whole partition" to "from the start of the partition up to the current row's peer group." This second effect is the source of the single most notorious window-function bug in SQL, and we dissect it completely in this section and again with the `LAST_VALUE` example in §10.7.

### The frame clause — full syntax and precise semantics

```sql
function_name(...) OVER (
    PARTITION BY ...
    ORDER BY ...
    { ROWS | RANGE | GROUPS } BETWEEN frame_start AND frame_end
)
```

where `frame_start` and `frame_end` are each one of:

| Frame bound | Meaning |
|---|---|
| `UNBOUNDED PRECEDING` | The very first row of the partition |
| `N PRECEDING` | `N` units before the current row (unit depends on `ROWS`/`RANGE`/`GROUPS` — see below) |
| `CURRENT ROW` | The current row itself (or its whole peer group, for `RANGE`/`GROUPS`) |
| `N FOLLOWING` | `N` units after the current row |
| `UNBOUNDED FOLLOWING` | The very last row of the partition |

`frame_start` must not be logically "after" `frame_end` (e.g., `BETWEEN CURRENT ROW AND 3 PRECEDING` is invalid — the start must be at or before the end).

**The frame clause answers one very specific question: *of all the rows in this row's partition, exactly which ones is the function allowed to look at, for this particular row?*** That sub-window (the "frame") can — and usually does — change for every single row as the current row moves through the partition. This is the single hardest idea in this whole chapter to hold in your head, so we now walk it through concretely with `ROWS`, then `RANGE`, then `GROUPS`.

#### `ROWS` — counts physical rows, ignoring ties entirely

`ROWS BETWEEN N PRECEDING AND CURRENT ROW` means "exactly the `N` physical rows immediately before this one (by sort position), plus this row — regardless of whether any of them have the same `ORDER BY` value as each other." This is a purely positional frame: it counts rows, full stop.

#### `RANGE` — counts by *value* of the `ORDER BY` expression, treating ties as one unit

`RANGE BETWEEN ... AND ...` does **not** count physical rows — it defines the frame in terms of the *value* of the `ORDER BY` expression. Critically: **if two or more rows share the exact same `ORDER BY` value (a "peer group" / tie), `RANGE` treats them as a single indivisible unit** — either all of them are inside the frame, or none of them are. You cannot use `RANGE` to split a tie down the middle. This is precisely the mechanism behind the ties-in-`SUM()` gotcha we verify with real data in §10.10.

#### `GROUPS` **[PostgreSQL 11+]** — counts by *distinct peer groups*, not rows or values

`GROUPS BETWEEN N PRECEDING AND CURRENT ROW` counts `N` **distinct `ORDER BY` value groups** before the current one — so if the group immediately before the current row's group happens to contain 5 tied rows, `1 PRECEDING` under `GROUPS` pulls in all 5 of those rows as a single unit, the same way `RANGE`'s `CURRENT ROW` bound does, but now applied to an *offset* count rather than only to `CURRENT ROW`.

**Dialect availability of `GROUPS`: [PostgreSQL] 11+ only** among our four primary dialects. **[MySQL]** 8.0+ supports `ROWS` and `RANGE` but **not** `GROUPS`. **[SQL Server]** supports `ROWS` fully and `RANGE` only in its limited `UNBOUNDED PRECEDING`/`CURRENT ROW` form (no arbitrary `N PRECEDING` under `RANGE`); it does not support `GROUPS` at all. **[Oracle]** supports `ROWS` and `RANGE` but not `GROUPS`. If you need portable code across all four, stick to `ROWS`, and only use `RANGE`'s `UNBOUNDED PRECEDING AND CURRENT ROW` form (the default) if you need tie-aware behavior.

### A single concrete, verified example showing all three frame types side by side

Take five real rows from `salaries`, ordered by `effective_date`, where two real ties exist in the seed data (`2021-01-01`: employee 2 and 7; `2022-01-01` appears further down but we isolate a clean five-row slice here):

```sql
SELECT employee_id, effective_date, bonus,
       SUM(bonus) OVER (ORDER BY effective_date
           GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) AS groups_frame_sum,
       SUM(bonus) OVER (ORDER BY effective_date
           ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)   AS rows_frame_sum
FROM salaries
WHERE effective_date IN ('2020-10-05','2021-01-01','2021-03-22','2022-01-01','2022-01-10')
ORDER BY effective_date, employee_id;
```

**Expected output:**

| employee_id | effective_date | bonus | groups_frame_sum | rows_frame_sum |
|---|---|---|---|---|
| 15 | 2020-10-05 | 9000 | 9000 | 9000 |
| 2 | 2021-01-01 | 50000 | 129000 | 59000 |
| 7 | 2021-01-01 | 70000 | 129000 | 120000 |
| 9 | 2021-03-22 | 10000 | 130000 | 80000 |
| 3 | 2022-01-01 | 25000 | 47000 | 35000 |
| 4 | 2022-01-01 | 12000 | 47000 | 37000 |
| 16 | 2022-01-10 | 6000 | 43000 | 18000 |

**Conceptual trace, row by row, for the `2021-01-01` pair (employee 2 and employee 7):**

- **`rows_frame_sum`** counts *physical rows*: for employee 2's row, "1 PRECEDING AND CURRENT ROW" is exactly the row before it (employee 15, `9000`) plus itself (`50000`) = `59000`. For employee 7's row, one physical row later, its "1 PRECEDING" is now employee 2's row (`50000`), plus itself (`70000`) = `120000`. Each row gets a *different* answer, because `ROWS` only cares about physical position — it has no idea the two rows share a date.
- **`groups_frame_sum`** counts *distinct value-groups*: both employee 2 and employee 7 belong to the *same* `ORDER BY` group (`effective_date = 2021-01-01`), so for *both* of them, "current row" actually means "the entire `2021-01-01` peer group" (both rows), and "1 preceding group" means "the entire `2020-10-05` group" (employee 15's single row). So both employee 2 and employee 7 see the identical frame — `{9000, 50000, 70000}` — and both get the identical sum, `129000`. This is the defining behavior of tie-aware frames: **peers always get the same answer.**

This single table is worth re-reading until the distinction is completely mechanical, because it is the direct cause of the `RANGE`-with-ties warning in §10.10 and the `LAST_VALUE` gotcha in §10.7.

### The default frame — the rule almost nobody states precisely enough

> **The default frame, if you don't write one explicitly, depends on whether `ORDER BY` is present inside `OVER(...)`:**
> - **If `ORDER BY` is present:** the default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`.
> - **If `ORDER BY` is absent:** the default frame is the entire partition — equivalent to `RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`.

This asymmetry is *intentional* standard SQL behavior, and it is the root cause of nearly every "my window function gave a weird answer" bug you will ever encounter:

- **Without `ORDER BY`**, there's no meaningful concept of "before" or "after" a row, so the only sensible default is "see everything in the partition." `AVG(base_salary) OVER (PARTITION BY department_id)` with no `ORDER BY` gives every employee in a department the *same* department-wide average, because every row's default frame is the whole partition.
- **With `ORDER BY`**, SQL assumes you probably want a *running/cumulative* computation (since you bothered to specify an order), so the default frame stops accumulating at the current row's peer group — `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. This is exactly right for running totals (§10.10). It is exactly *wrong*, and famously surprising, for `LAST_VALUE` (§10.7), because "current row" as an upper bound means `LAST_VALUE` can never see past the current row — it will always just return the current row's own value.

> **⚠️ Warning — this is the most important single sentence in this chapter.** Adding `ORDER BY` inside `OVER(...)` silently changes the default frame from "whole partition" to "start of partition through current row's peers." If you add an `ORDER BY` to a window function for one reason (say, to control tie-breaking in `RANK()`) without intending a cumulative/running calculation, you may unintentionally turn a `SUM`/`AVG`/`LAST_VALUE` into a running or truncated calculation. Always ask: "do I want the *whole partition*, or a *running frame up to this row*?" and write the frame clause explicitly rather than relying on the default, especially for `SUM`, `AVG`, and `LAST_VALUE`.

---

## 10.3 Ranking Functions: `ROW_NUMBER`, `RANK`, `DENSE_RANK`

### 1. Simple explanation

All three functions assign a position number to each row within its partition, based on the `ORDER BY` you give them. The only difference between them is **what happens when two or more rows tie** on that `ORDER BY` value.

### 2. Technical explanation

`ROW_NUMBER()` assigns a strictly increasing integer (`1, 2, 3, 4, ...`) to every row in partition order, with **no regard for ties** — even identical values get different, arbitrary-among-themselves numbers. `RANK()` assigns the same number to tied rows, then **skips** the number(s) that would have been used by those tied rows before continuing (e.g., two rows tied at rank 3 means the next distinct row is rank 5, not 4). `DENSE_RANK()` also assigns the same number to tied rows, but does **not** skip — the next distinct value always gets `previous_rank + 1`. None of the three take arguments; all three require an `ORDER BY` inside their `OVER(...)` to be meaningful (without one, every row is arbitrarily "tied" with every other row, which is legal but almost never useful).

### 3. Why these exist — the problem `GROUP BY` cannot solve

`GROUP BY` can tell you "the maximum salary in Engineering is 520000." It cannot, in the same query, tell you "and Aditi is #1, Rahul is #2, Sneha is #3..." — that requires an ordering *within* a group that is attached back to each individual row, which is precisely a per-row, non-collapsing computation. Ranking functions exist to answer "where does this row stand relative to its peers?" without discarding any row to do it.

### 4. Syntax

```sql
ROW_NUMBER() OVER ( [PARTITION BY ...] ORDER BY sort_expr [ASC|DESC] )
RANK()       OVER ( [PARTITION BY ...] ORDER BY sort_expr [ASC|DESC] )
DENSE_RANK() OVER ( [PARTITION BY ...] ORDER BY sort_expr [ASC|DESC] )
```

None of these accept a frame clause meaningfully — ranking is inherently defined relative to the *entire* ordered partition, not a sliding sub-window, so engines ignore or reject an explicit frame clause on these functions.

### 5–7. Examples, output, and a full tie comparison

**The seed data's real employee salaries have no exact ties within a single department** (a useful, realistic situation — most of the time your ranking data won't be perfectly tied either). To show precisely how `ROW_NUMBER`, `RANK`, and `DENSE_RANK` diverge, we use this illustrative snapshot of Engineering-department salaries with two intentionally tied values (Sneha Kulkarni and Vikram Joshi both at ₹210,000) — reproducible exactly as written:

```sql
WITH engineering_salary_demo(employee_name, salary) AS (
    VALUES ('Aditi Rao',      520000),
           ('Rahul Mehta',    320000),
           ('Sneha Kulkarni', 210000),
           ('Vikram Joshi',   210000),   -- intentionally tied with Sneha, for this illustration
           ('Ananya Singh',   140000),
           ('Aman Chawla',     95000),
           ('Karan Verma',     80000)
)
SELECT employee_name, salary,
       ROW_NUMBER() OVER (ORDER BY salary DESC) AS row_num,
       RANK()       OVER (ORDER BY salary DESC) AS rnk,
       DENSE_RANK() OVER (ORDER BY salary DESC) AS dense_rnk
FROM engineering_salary_demo;
```

**Expected output:**

| employee_name | salary | row_num | rnk | dense_rnk |
|---|---|---|---|---|
| Aditi Rao | 520000 | 1 | 1 | 1 |
| Rahul Mehta | 320000 | 2 | 2 | 2 |
| Sneha Kulkarni | 210000 | 3 | **3** | **3** |
| Vikram Joshi | 210000 | 4 | **3** | **3** |
| Ananya Singh | 140000 | 5 | **5** | **4** |
| Aman Chawla | 95000 | 6 | 6 | 5 |
| Karan Verma | 80000 | 7 | 7 | 6 |

**Line-by-line trace of exactly where the three diverge:**

1. Aditi (520000) and Rahul (320000) have no ties above them, so all three functions agree: `1, 2` and `2, 3`... they all just count up normally.
2. Sneha and Vikram both have `salary = 210000` — a tie. `ROW_NUMBER()` doesn't care about the tie at all; it simply continues the running count, giving Sneha `3` and Vikram `4` (which one gets `3` versus `4` among exact ties is **not guaranteed** without a tiebreaker column — see §10.3's edge cases below). `RANK()` gives *both* of them `3` (the position where the tie starts), because that's the correct "if you sorted this list, where would they land" answer for two people sharing 3rd place. `DENSE_RANK()` also gives both of them `3`, for the same reason.
3. Now look at Ananya (140000), the very next distinct value after the tie. This is where `RANK` and `DENSE_RANK` diverge from each other: `RANK()` gives Ananya `5` — it **skipped** `4` entirely, because two rows already "used up" positions 3 and 4 (that's literally what "rank" means in a leaderboard: if two people tie for 3rd, the next person is 5th, not 4th). `DENSE_RANK()` gives Ananya `4` — it never skips; the next *distinct* salary value always gets exactly `previous + 1`, regardless of how many rows shared the previous value.
4. From Ananya onward, `RANK` and `DENSE_RANK` stay permanently offset by one from each other (6-vs-5, 7-vs-6) for the rest of the partition — a single tie anywhere in the data permanently shifts every `RANK()` below it, while `DENSE_RANK()` never has gaps at all, ever, by definition.

### 8. Internal behavior

To compute any of these three functions, the engine conceptually needs the partition's rows **sorted by the `ORDER BY` expression** before it can assign positions — there is no way to know a row is "3rd" without having established a total order first. This is the sort cost foreshadowed in §10.1; for `RANK`/`DENSE_RANK` the engine additionally needs to detect exact value equality between adjacent sorted rows to know when to hold a rank steady versus advance it.

### 9. Common mistakes

- **Forgetting a tiebreaker column, then being surprised the "same" query returns rows in a different order on a re-run.** If two rows are exactly tied on your `ORDER BY` expression, `ROW_NUMBER()` is *allowed* to assign either one `1` and the other `2`, in either order — the SQL standard does not guarantee which. Two runs of the identical query, even against identical data, are not guaranteed to break the tie the same way unless you add a deterministic secondary sort key (commonly a primary key column) to the `ORDER BY`. This bites hardest in the Top-N pattern (§10.14), where "pick the row with `rn = 1`" can silently pick a *different* row on a different day if salaries ever tie exactly.
- **Using `RANK()` when you actually wanted `DENSE_RANK()` (or vice versa) for a "top N distinct tiers" report.** If you want "the top 3 *salary levels*" (regardless of how many people share each level), `DENSE_RANK() <= 3` is correct; `RANK() <= 3` is not, because a tie at level 1 could make level 2 start at rank 3, silently excluding an entire second-place tier.

### 10. Edge cases

- **Ties without a tiebreaker.** As above — always add a deterministic secondary `ORDER BY` column (typically a primary key) if you need `ROW_NUMBER()` to be reproducible, e.g. `ORDER BY salary DESC, employee_id ASC`.
- **`NULL` values in the `ORDER BY` expression.** `NULL`s participate in ranking like any other value once placed by the `NULLS FIRST`/`NULLS LAST` rule (§10.16 covers this rule precisely) — a group of `NULL`s ties with each other exactly like any other tied value, and gets a single shared `RANK`/`DENSE_RANK`.
- **Empty partitions.** There is no such thing as an "empty partition" appearing in the output — if a `PARTITION BY` key value has zero surviving rows (e.g., because `WHERE` removed them all beforehand), that partition simply never appears; there is no row to attach a rank to.
- **Single-row partitions.** A partition with exactly one row always gets `ROW_NUMBER = 1`, `RANK = 1`, `DENSE_RANK = 1` for that row — there's nothing to compare it against.

### 11. When to use / not use

Use ranking functions whenever the business question contains the word "rank," "top N," "position," "tier," or "leaderboard," *and* you need to retain every underlying row (or at least be able to filter down from all of them, as in §10.14). Don't reach for a ranking function if you only need the single best/worst row per group with no need to see its rank number — a `DISTINCT ON` **[PostgreSQL]** or a correlated subquery with `MAX`/`MIN` can sometimes be simpler for a "just give me the top 1" case with no tie-handling nuance required.

### 12. Comparison table

| | Ties: what happens | Sequence after a tie of size *k* | Guaranteed no gaps? | Typical use |
|---|---|---|---|---|
| `ROW_NUMBER()` | Ignored — each row gets a unique, arbitrary-among-ties number | Always `previous + 1` | Yes (no gaps, but ties broken arbitrarily) | Pagination, deduplication, "pick exactly one row per group" |
| `RANK()` | Tied rows share the same rank | Jumps by *k* after a tie of size *k* (Olympic-style ranking) | No — gaps appear after ties | Leaderboards where "how many people are strictly better than me" matters |
| `DENSE_RANK()` | Tied rows share the same rank | Always `previous + 1`, regardless of tie size | Yes | "How many distinct performance tiers exist" / top-N *distinct levels* |

### 13. Real-world use cases

Sales leaderboards ("rank reps by revenue this quarter"), academic rank-in-class reports, deduplication (`ROW_NUMBER() = 1` to pick one canonical row per duplicate key — covered again in Chapter 31), pagination with stable ordering, and the Top-N-per-group pattern (§10.14) that powers almost every "top 5 products," "top 3 employees," or "top 10 customers" report you will ever be asked to build.

---

## 10.4 `NTILE` — Bucketing Rows into Equal-Sized Groups

### 1–2. Explanation

`NTILE(n)` divides the rows of a partition into `n` roughly equal-sized, ordered buckets (a "salary quartile" report uses `NTILE(4)`), numbering each row `1` through `n` according to which bucket it falls in, based on the `ORDER BY` order.

### 3. Why it exists

Percentile-style bucketing ("top 25%," "bottom quartile," "decile 3 of 10") is a common analytics request that `GROUP BY` cannot express at all, because the bucket boundaries depend on the *rank order* of the data, not on any existing column value.

### 4. Syntax

```sql
NTILE(bucket_count) OVER ( [PARTITION BY ...] ORDER BY sort_expr )
```

### 5–7. Example: salary quartiles across the whole company

```sql
WITH current_salary AS (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
)
SELECT e.first_name || ' ' || e.last_name AS employee_name,
       cs.base_salary,
       NTILE(4) OVER (ORDER BY cs.base_salary DESC) AS salary_quartile
FROM employees e
JOIN current_salary cs ON cs.employee_id = e.employee_id AND cs.rn = 1
ORDER BY cs.base_salary DESC;
```

*(The `current_salary` CTE picks each employee's most recent salary row by `effective_date` — the same "latest row per group" pattern we build formally in §10.13/§10.14; `salaries` is a history table with up to two rows per employee.)*

**Expected output (16 employees, 4 per quartile):**

| employee_name | base_salary | salary_quartile |
|---|---|---|
| Aditi Rao | 520000 | 1 |
| Rahul Mehta | 320000 | 1 |
| Priya Nair | 300000 | 1 |
| Nikhil Gupta | 250000 | 1 |
| Rohan Kapoor | 240000 | 2 |
| Rajesh Iyer | 230000 | 2 |
| Sneha Kulkarni | 210000 | 2 |
| Vikram Joshi | 140000 | 2 |
| Divya Shah | 130000 | 3 |
| Ananya Singh | 120000 | 3 |
| Arjun Das | 110000 | 3 |
| Pooja Reddy | 105000 | 3 |
| Isha Bhatt | 100000 | 4 |
| Meera Pillai | 95000 | 4 |
| Aman Chawla | 95000 | 4 |
| Karan Verma | 80000 | 4 |

With exactly 16 rows and `NTILE(4)`, the split is perfectly even — 4 rows per quartile. `NTILE` computes this by dividing the partition's row count by the bucket count (`16 / 4 = 4`) and assigning that many rows to each bucket in order; quartile 1 is the *highest*-paid group here specifically because we ordered `DESC`.

### Uneven splits — what `NTILE` actually does with a remainder

When the row count doesn't divide evenly by the bucket count, `NTILE` does not error or leave a bucket short — it distributes the remainder rows to the **earliest** buckets, one extra row each, until the remainder is used up. For example, `NTILE(3)` over Engineering's 7 employees (`7 / 3 = 2` remainder `1`) gives bucket 1 three rows (2 base + 1 extra) and buckets 2 and 3 two rows each — never a bucket with zero rows unless the bucket count exceeds the row count.

### 10. Edge cases

If `n` (the bucket count) is larger than the number of rows in the partition, some buckets simply get **zero rows** (e.g., `NTILE(4)` over Finance's 2 employees produces only buckets 1 and 2 populated — buckets 3 and 4 never appear, because there's no third or fourth row to assign to them). This is different from ranking functions, which always produce a value for every existing row — `NTILE` can "run out" of rows before it runs out of buckets, in which case the unused bucket numbers are simply never emitted.

### 11–13. When to use / real-world use cases

Use `NTILE` for percentile-bucketing reports (salary quartiles, customer value deciles, performance tiers) where you want roughly equal *group sizes* rather than equal *value ranges*. It is a coarse, cheap approximation of a percentile/median calculation — for an *exact* median or percentile, see the `PERCENTILE_CONT` **[PostgreSQL]** discussion in Challenge 4 (§10.22).

---

## 10.5 `LAG` and `LEAD` — Looking at Neighboring Rows

### 1. Simple explanation

`LAG` lets a row "look backward" at an earlier row's value (by default, the row immediately before it in the specified order); `LEAD` lets it "look forward" at a later row's value. Both let you compare a row to its neighbor without writing a self-join.

### 2. Technical explanation

`LAG(expression, offset, default)` and `LEAD(expression, offset, default)` are offset functions: for the current row, they evaluate `expression` on the row that is `offset` positions before (`LAG`) or after (`LEAD`) it, within the same partition, according to the `ORDER BY`. `offset` defaults to `1` if omitted. `default` (also optional) is the value returned when the requested offset falls outside the partition's bounds (e.g., `LAG` on the very first row of a partition, or `LEAD` on the very last) — if `default` is omitted, `NULL` is returned in that case.

### 3. Why these exist

Without `LAG`/`LEAD`, comparing a row to "the previous row" (period-over-period growth, detecting a status change from the prior record, computing a difference between consecutive readings) requires a self-join on some computed "previous key" — verbose, error-prone, and typically much slower than a single ordered pass the window function performs internally.

### 4. Syntax

```sql
LAG(expression [, offset [, default]])  OVER ( [PARTITION BY ...] ORDER BY sort_expr )
LEAD(expression [, offset [, default]]) OVER ( [PARTITION BY ...] ORDER BY sort_expr )
```

### 5–7. Worked example: order-over-order revenue change

Using `ecommerce_db`, compute each order's total revenue (`orders` joined to `order_items`), then compare it to the previous and next order chronologically:

```sql
WITH order_revenue AS (
    SELECT o.order_id, o.order_date, SUM(oi.quantity * oi.unit_price) AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    GROUP BY o.order_id, o.order_date
)
SELECT order_id, order_date, revenue,
       LAG(revenue)    OVER (ORDER BY order_date)     AS prev_revenue,
       LEAD(revenue)   OVER (ORDER BY order_date)     AS next_revenue,
       LAG(revenue, 1, 0) OVER (ORDER BY order_date)  AS prev_revenue_or_zero,
       revenue - LAG(revenue) OVER (ORDER BY order_date) AS diff_from_prev
FROM order_revenue
ORDER BY order_date;
```

**Expected output:**

| order_id | order_date | revenue | prev_revenue | next_revenue | prev_revenue_or_zero | diff_from_prev |
|---|---|---|---|---|---|---|
| 1 | 2024-01-05 10:20 | 49498 | NULL | 5097 | 0 | NULL |
| 2 | 2024-01-08 14:00 | 5097 | 49498 | 89999 | 49498 | -44401 |
| 3 | 2024-01-15 09:30 | 89999 | 5097 | 3298 | 5097 | 84902 |
| 4 | 2024-01-20 16:45 | 3298 | 89999 | 29999 | 89999 | -86701 |
| 5 | 2024-01-22 11:00 | 29999 | 3298 | 75798 | 3298 | 26701 |
| 6 | 2024-02-01 08:15 | 75798 | 29999 | 6998 | 29999 | 45799 |
| 7 | 2024-02-03 19:20 | 6998 | 75798 | 45999 | 75798 | -68800 |
| 8 | 2024-02-10 12:00 | 45999 | 6998 | 93498 | 6998 | 39001 |
| 9 | 2024-02-14 15:30 | 93498 | 45999 | 3897 | 45999 | 47499 |
| 10 | 2024-02-18 13:10 | 3897 | 93498 | NULL | 93498 | -89601 |

**Line-by-line trace, two rows:**

- **Order 1 (the first row, by date):** `LAG(revenue)` looks for "1 row before this one" — but there is no row before the first row of the partition, so it returns `NULL` (the default default). `LAG(revenue, 1, 0)` explicitly says "if there's no previous row, use `0` instead" — so this column shows `0` for order 1 specifically. `LEAD(revenue)` correctly finds order 2's revenue (`5097`), since there *is* a next row. `diff_from_prev` becomes `NULL` because subtracting from a `NULL` `LAG` propagates `NULL`.
- **Order 10 (the last row):** the situation flips — `LAG(revenue)` correctly finds order 9's revenue (`93498`), but `LEAD(revenue)` has no row after it and returns `NULL`.

### 8. Internal behavior

Both functions require the partition to be sorted by the `ORDER BY` expression (same sort cost as §10.1/§10.3), after which the engine can walk the sorted sequence once, referencing an offset position directly — this is typically implemented efficiently as a single ordered scan with a small sliding buffer, not a repeated lookup per row.

### 9–10. Common mistakes and edge cases

- **Forgetting the `default` argument and getting unexpected `NULL`s at partition boundaries** — if you intend to treat "no previous row" as zero (e.g., computing a difference from a baseline of zero for the first period), you must supply the third `default` argument explicitly; otherwise arithmetic against the `NULL` result (as seen in `diff_from_prev` for order 1 above) silently propagates `NULL`.
- **Omitting `PARTITION BY` when you actually need it.** If this same `LAG` query were computed per-customer (e.g., "each customer's previous order revenue"), forgetting `PARTITION BY user_id` would let `LAG` reach across *different customers'* rows — comparing customer A's order to whatever customer happened to place the immediately preceding order chronologically, which is almost never the intended comparison.
- **`NULL`s inside the `expression` argument itself** (not the offset falling outside the partition, but an actual `NULL` value stored in the referenced row) — `LAG`/`LEAD` faithfully return that stored `NULL`, indistinguishable at a glance from an out-of-bounds `NULL`. If this ambiguity matters for your logic, check the row's existence separately (e.g., with `ROW_NUMBER()`).

### 11–13. When to use / comparisons / real-world use cases

`LAG`/`LEAD` are the correct tool whenever the question is phrased as "compared to the previous/next X" — period-over-period revenue growth, detecting a change in status between consecutive log entries, computing the gap between consecutive event timestamps, or (combined with `PARTITION BY`) "each customer's month-over-month spend change." We use `LAG` again, partitioned by year *and* department, for real year-over-year growth analysis in Challenge 2 (§10.22).

---

## 10.6 `FIRST_VALUE` and `LAST_VALUE` — and the Frame Gotcha

### 1. Simple explanation

`FIRST_VALUE` returns the value of an expression from the *first* row of the current window; `LAST_VALUE` returns it from the *last* row. They sound perfectly symmetric — and that apparent symmetry is exactly what makes `LAST_VALUE` so notorious, because "last row of the window" depends entirely on the frame clause, and the *default* frame (§10.2) makes "last row of the window" mean something almost nobody expects.

### 2. Technical explanation

`FIRST_VALUE(expression) OVER (...)` and `LAST_VALUE(expression) OVER (...)` evaluate `expression` on the first and last row, respectively, **of the current row's frame** (not necessarily the whole partition — the frame, exactly as defined in §10.2). `NTH_VALUE(expression, n) OVER (...)` **[PostgreSQL]** generalizes this to "the `n`th row of the frame."

### 3. Why they exist

They answer "what was the starting value" or "what is the most-recent/final value" for a group, attached to every row of that group — e.g., "show every employee alongside the first-hired person in their department" (a fixed reference point per partition) without a separate subquery per partition.

### 4. Syntax

```sql
FIRST_VALUE(expression) OVER ( [PARTITION BY ...] ORDER BY sort_expr [frame_clause] )
LAST_VALUE(expression)  OVER ( [PARTITION BY ...] ORDER BY sort_expr [frame_clause] )
```

### 5–7. `FIRST_VALUE` — a correct example first

```sql
SELECT d.department_name,
       e.first_name || ' ' || e.last_name AS employee_name,
       e.hire_date,
       FIRST_VALUE(e.first_name || ' ' || e.last_name)
           OVER (PARTITION BY d.department_id ORDER BY e.hire_date) AS first_hired_in_dept
FROM employees e
JOIN departments d ON d.department_id = e.department_id
ORDER BY d.department_name, e.hire_date;
```

**Expected output (Engineering rows shown; all departments follow the same pattern):**

| department_name | employee_name | hire_date | first_hired_in_dept |
|---|---|---|---|
| Engineering | Aditi Rao | 2015-03-01 | Aditi Rao |
| Engineering | Rahul Mehta | 2016-05-12 | Aditi Rao |
| Engineering | Sneha Kulkarni | 2017-01-20 | Aditi Rao |
| Engineering | Vikram Joshi | 2018-07-15 | Aditi Rao |
| Engineering | Ananya Singh | 2019-09-01 | Aditi Rao |
| Engineering | Karan Verma | 2020-02-10 | Aditi Rao |
| Engineering | Aman Chawla | 2022-01-10 | Aditi Rao |

`FIRST_VALUE` works exactly as expected here, **without needing any explicit frame clause**, because the default frame (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`) *always* includes the first row of the partition, no matter which row is "current" — so `FIRST_VALUE` is safe under the default frame. `LAST_VALUE` has no such luck, as we now show.

### The `LAST_VALUE` gotcha — precisely why it "doesn't work"

```sql
-- ⚠️ THIS LOOKS REASONABLE BUT IS WRONG
SELECT order_id, order_date, revenue,
       FIRST_VALUE(revenue) OVER (ORDER BY order_date) AS first_val,
       LAST_VALUE(revenue)  OVER (ORDER BY order_date) AS last_val_WRONG
FROM order_revenue   -- from the CTE defined in §10.5
ORDER BY order_date;
```

**Expected (verified) output:**

| order_id | order_date | revenue | first_val | last_val_WRONG |
|---|---|---|---|---|
| 1 | 2024-01-05 10:20 | 49498 | 49498 | 49498 |
| 2 | 2024-01-08 14:00 | 5097 | 49498 | 5097 |
| 3 | 2024-01-15 09:30 | 89999 | 49498 | 89999 |
| 4 | 2024-01-20 16:45 | 3298 | 49498 | 3298 |
| 5 | 2024-01-22 11:00 | 29999 | 49498 | 29999 |
| 6 | 2024-02-01 08:15 | 75798 | 49498 | 75798 |
| 7 | 2024-02-03 19:20 | 6998 | 49498 | 6998 |
| 8 | 2024-02-10 12:00 | 45999 | 49498 | 45999 |
| 9 | 2024-02-14 15:30 | 93498 | 49498 | 93498 |
| 10 | 2024-02-18 13:10 | 3897 | 49498 | 3897 |

> **⚠️ Warning — the most common `LAST_VALUE` bug in SQL, explained precisely.** Look at the `last_val_WRONG` column: every row shows its **own** revenue, not the final order's revenue (`3897`). This is not a bug in the database — it is the frame default working *exactly as documented*, just not as most people intuitively expect. `ORDER BY order_date` inside `OVER(...)` triggers the default frame `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (§10.2). That frame's *upper* bound is always `CURRENT ROW` — meaning, for every single row, the window this function can see stops exactly at itself. So `LAST_VALUE`, whose entire job is "return the value at the end of the window," ends up returning **the current row's own value**, every single time, because the current row *is* the end of its own frame. `LAST_VALUE` isn't broken; the *frame* simply never extends past "now."

**The fix — extend the frame explicitly to the end of the partition:**

```sql
SELECT order_id, order_date, revenue,
       LAST_VALUE(revenue) OVER (
           ORDER BY order_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) AS last_val_fixed
FROM order_revenue
ORDER BY order_date;
```

**Expected output:**

| order_id | order_date | revenue | last_val_fixed |
|---|---|---|---|
| 1 | 2024-01-05 10:20 | 49498 | 3897 |
| 2 | 2024-01-08 14:00 | 5097 | 3897 |
| 3 | 2024-01-15 09:30 | 89999 | 3897 |
| 4 | 2024-01-20 16:45 | 3298 | 3897 |
| 5 | 2024-01-22 11:00 | 29999 | 3897 |
| 6 | 2024-02-01 08:15 | 75798 | 3897 |
| 7 | 2024-02-03 19:20 | 6998 | 3897 |
| 8 | 2024-02-10 12:00 | 45999 | 3897 |
| 9 | 2024-02-14 15:30 | 93498 | 3897 |
| 10 | 2024-02-18 13:10 | 3897 | 3897 |

Every row now correctly shows `3897` — order 10's revenue, the actual last row of the entire (unpartitioned) result set — because `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` explicitly widens the frame's upper bound to "the end of the partition," for every row, regardless of its own position.

> **Important Note:** The same real, verified pair of tables above using department-scoped `FIRST_VALUE`/`LAST_VALUE` by `hire_date` shows the fix combined with `PARTITION BY`: `LAST_VALUE(...) OVER (PARTITION BY department_id ORDER BY hire_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` correctly returns Aman Chawla as the most-recently-hired Engineering employee on every Engineering row, Divya Shah for every Finance row, and so on — one fixed reference value per partition, attached to every row in it, exactly like `FIRST_VALUE` already did without needing the fix.

### 9. Common mistakes (consolidated)

- **Using `LAST_VALUE` with an `ORDER BY` and no explicit frame** — the single most common mistake with this function, shown above.
- **Assuming `FIRST_VALUE` needs the same fix** — it does not, precisely because `UNBOUNDED PRECEDING` (the default frame's lower bound) already always includes the true first row, regardless of which row is "current."
- **Forgetting that ties change what "first"/"last" mean.** If the `ORDER BY` expression has ties at the very boundary of the partition, `FIRST_VALUE`/`LAST_VALUE` still return a specific, single row's value from among the tied rows — but which physical row within a tie is picked is implementation-defined unless a deterministic tiebreaker is added to `ORDER BY`.

### 11–13. When to use / when not to / use cases

Use `FIRST_VALUE`/`LAST_VALUE` when you need a fixed per-partition reference value (first purchase price, most recent status, opening/closing balance) attached to every detail row, so you can compare each row against that anchor (e.g., "how much has the price changed since the first sale"). If you only need the anchor value in isolation (not attached to every row), a simple `MIN`/`MAX` with `GROUP BY`, or the Top-N pattern (§10.14), is simpler and avoids the frame subtlety entirely.

---

## 10.7 Aggregate Window Functions: `SUM() OVER`, `AVG() OVER`, `COUNT() OVER`

### 1–2. Explanation

Any ordinary aggregate function — `SUM`, `AVG`, `COUNT`, `MIN`, `MAX` — can be used as a window function simply by adding an `OVER(...)` clause. The aggregate computation itself doesn't change; what changes is that the result is attached to **every row of the window** instead of collapsing them into one output row.

### 3. Why this matters distinctly from ranking/offset functions

This is the category of window function most directly compared to `GROUP BY` (full deep dive next, §10.9), and it is the workhorse behind three of the four required worked patterns in this chapter: running totals, moving averages, and percentage-of-total.

### 4. Syntax

```sql
SUM(expr)   OVER ( [PARTITION BY ...] [ORDER BY ...] [frame_clause] )
AVG(expr)   OVER ( [PARTITION BY ...] [ORDER BY ...] [frame_clause] )
COUNT(expr) OVER ( [PARTITION BY ...] [ORDER BY ...] [frame_clause] )
```

Exactly the same NULL-skipping rules from Chapter 6 (§6.8) apply: `SUM`/`AVG` ignore `NULL` values in `expr`; `COUNT(*)` counts every row in the window regardless of NULLs; `COUNT(column)` counts only non-NULL values of `column` within the window.

### 5–7. Two contrasting basic examples

**Without `ORDER BY` (whole-partition aggregate, same value repeated per row):**

```sql
SELECT employee_id, department_id, base_salary,
       COUNT(*) OVER (PARTITION BY department_id) AS dept_headcount,
       SUM(base_salary) OVER (PARTITION BY department_id) AS dept_total_salary
FROM current_salary_with_dept   -- illustrative alias for the CTE pattern used throughout
ORDER BY department_id, base_salary DESC;
```

Every row in a department sees the *entire* partition (no `ORDER BY` present → default frame is the whole partition, per §10.2), so `dept_headcount` and `dept_total_salary` are identical for every row within a department.

**With `ORDER BY` (frame stops at current row's peers — a running calculation, covered fully in §10.10):**

Adding `ORDER BY base_salary DESC` to the same `SUM(...) OVER(...)` above would turn it into a running total *within* each department, ordered highest-to-lowest salary — a completely different, and easy to accidentally trigger, computation. This is the default-frame trap from §10.2 in action again, and it's why §10.10 treats running totals as its own fully worked pattern.

### `COUNT() OVER ()` — a quick, extremely common idiom

```sql
SELECT order_id, status, COUNT(*) OVER () AS total_orders
FROM orders
LIMIT 3;
```

**Expected output:**

| order_id | status | total_orders |
|---|---|---|
| 1 | DELIVERED | 10 |
| 2 | DELIVERED | 10 |
| 3 | SHIPPED | 10 |

This idiom — an empty `OVER ()` — is how you attach a grand total (of rows matching whatever `WHERE` already ran) to every detail row, most commonly for "row X of Y" pagination displays or "% of grand total" calculations at the unfiltered/whole-result-set level, as opposed to per-group percentages (§10.11).

The rest of this function family's depth is best taught through the four required worked patterns, starting now.

---

## 10.8 Deep Dive: `GROUP BY` vs. Window Functions

This is one of the most important conceptual sections in the entire chapter — get this exactly right and nearly every future window-function query you write will be intentional rather than accidental.

### The precise distinction

> **`GROUP BY` collapses many rows into one row per group — the original row-level detail is permanently gone from the result.**
> **A window function computes an aggregate-like value per row, while preserving every original row — nothing is collapsed, and every row can still be inspected individually alongside its group's computed value.**

### Side-by-side: the exact same business question, two different answer shapes

**Business question: "What is the average base salary per department?"**

**Form 1 — `GROUP BY` (one row per department; individual employees are gone):**

```sql
SELECT d.department_name,
       ROUND(AVG(cs.base_salary), 2) AS avg_dept_salary
FROM employees e
JOIN (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
) cs ON cs.employee_id = e.employee_id AND cs.rn = 1
JOIN departments d ON d.department_id = e.department_id
GROUP BY d.department_name
ORDER BY d.department_name;
```

**Expected output — 5 rows, one per department:**

| department_name | avg_dept_salary |
|---|---|
| Engineering | 212142.86 |
| Finance | 190000.00 |
| HR | 170000.00 |
| Marketing | 167500.00 |
| Sales | 168333.33 |

Sixteen employees went in; five summary rows came out. There is no way, from this result alone, to answer "and how does Aditi's own salary compare to that average?" — her row no longer exists in the output.

**Form 2 — `AVG() OVER (PARTITION BY ...)` (every employee row retained, department average attached to each):**

```sql
WITH current_salary AS (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
)
SELECT e.employee_id,
       e.first_name || ' ' || e.last_name AS employee_name,
       d.department_name,
       cs.base_salary,
       ROUND(AVG(cs.base_salary) OVER (PARTITION BY e.department_id), 2) AS dept_avg_salary,
       CASE WHEN cs.base_salary > AVG(cs.base_salary) OVER (PARTITION BY e.department_id)
            THEN 'ABOVE_AVG' ELSE 'AT_OR_BELOW_AVG' END AS vs_avg
FROM employees e
JOIN current_salary cs ON cs.employee_id = e.employee_id AND cs.rn = 1
JOIN departments d ON d.department_id = e.department_id
ORDER BY d.department_name, cs.base_salary DESC;
```

**Expected output — all 16 employee rows, each carrying its department's average:**

| employee_id | employee_name | department_name | base_salary | dept_avg_salary | vs_avg |
|---|---|---|---|---|---|
| 12 | Nikhil Gupta | Finance | 250000 | 190000.00 | ABOVE_AVG |
| 13 | Divya Shah | Finance | 130000 | 190000.00 | AT_OR_BELOW_AVG |
| 1 | Aditi Rao | Engineering | 520000 | 212142.86 | ABOVE_AVG |
| 2 | Rahul Mehta | Engineering | 320000 | 212142.86 | ABOVE_AVG |
| 3 | Sneha Kulkarni | Engineering | 210000 | 212142.86 | AT_OR_BELOW_AVG |
| 4 | Vikram Joshi | Engineering | 140000 | 212142.86 | AT_OR_BELOW_AVG |
| 5 | Ananya Singh | Engineering | 120000 | 212142.86 | AT_OR_BELOW_AVG |
| 16 | Aman Chawla | Engineering | 95000 | 212142.86 | AT_OR_BELOW_AVG |
| 6 | Karan Verma | Engineering | 80000 | 212142.86 | AT_OR_BELOW_AVG |
| 10 | Rohan Kapoor | HR | 240000 | 170000.00 | ABOVE_AVG |
| 11 | Isha Bhatt | HR | 100000 | 170000.00 | AT_OR_BELOW_AVG |
| 14 | Rajesh Iyer | Marketing | 230000 | 167500.00 | ABOVE_AVG |
| 15 | Pooja Reddy | Marketing | 105000 | 167500.00 | AT_OR_BELOW_AVG |
| 7 | Priya Nair | Sales | 300000 | 168333.33 | ABOVE_AVG |
| 8 | Arjun Das | Sales | 110000 | 168333.33 | AT_OR_BELOW_AVG |
| 9 | Meera Pillai | Sales | 95000 | 168333.33 | AT_OR_BELOW_AVG |

*(Reordered above by department for readability; run with `ORDER BY d.department_name, cs.base_salary DESC` exactly as written for this exact row order.)*

Notice the `dept_avg_salary` numbers are **identical** to Form 1's `avg_dept_salary` numbers (212142.86 for Engineering, 190000.00 for Finance, and so on) — both forms compute exactly the same aggregate. The only difference is *what happened to the individual rows*: Form 1 threw them away after computing the aggregate; Form 2 kept every one of them and simply attached the aggregate as an extra column, which is precisely what makes the `vs_avg` comparison column possible — Sneha Kulkarni now sits right next to the number she's being compared to (`210000` against `212142.86`), a comparison Form 1 cannot express at all in a single query.

### Trace: what's visible to the engine for two specific rows in Form 2

- **Aditi Rao's row:** `PARTITION BY e.department_id` restricts her window to *only* Engineering rows (herself + Rahul + Sneha + Vikram + Ananya + Aman + Karan — 7 rows). `AVG(base_salary)` over that 7-row window is `212142.86`. Her own `base_salary` (`520000`) is compared against that window-computed average, correctly landing `ABOVE_AVG`.
- **Divya Shah's row:** her window is Finance-only (herself + Nikhil — 2 rows), giving `190000.00`. Her own salary (`130000`) is below that, correctly landing `AT_OR_BELOW_AVG`.

### 11. When you need Form 1 vs. Form 2 — the decision rule

| You need... | Use |
|---|---|
| A report with exactly one row per group (a departmental summary table, a dashboard KPI tile per category) | `GROUP BY` (Form 1) |
| To compare each individual row against its own group's aggregate ("who's above average," "what % of the group total is this row") | Window function (Form 2) |
| Both — a summary table **and** the detail rows in the same result | Not possible in a single `GROUP BY` query; either run both queries, or use Form 2 and let the caller/reporting tool aggregate further if a pure summary view is also needed |
| To filter which *groups* appear based on an aggregate condition (`HAVING COUNT(*) > 5`) | `GROUP BY` + `HAVING` — window functions cannot be filtered with `HAVING`/`WHERE` directly (§10.14 shows the correct workaround for filtering on a window result) |

> **Important Note:** You can also use `GROUP BY` and window functions **together** in one query — window functions are evaluated after `GROUP BY`/`HAVING` in the logical order (§10.1, step 5), so you can, for example, `GROUP BY` to first compute one row per (department, job_title), and then apply a window function like `RANK() OVER (PARTITION BY department_id ORDER BY avg_salary DESC)` on top of *those already-grouped* rows, to rank job titles within each department by their average pay. Window functions and `GROUP BY` are not mutually exclusive tools — they compose.

---

## 10.9 Worked Pattern: Running Totals

**Business question:** "What is the cumulative bonus paid out by the company, in the order it was paid, running from the very first bonus onward?"

This uses the real `salaries` history table (21 rows total across 16 employees — 5 employees have two rows each from receiving a raise). Crucially, the seed data contains **two genuine ties** on `effective_date` (`2021-01-01`: employees 2 and 7; `2022-01-01`: employees 3 and 4) — real data that lets us demonstrate the `ROWS`-vs-`RANGE` tie behavior from §10.2 without inventing anything.

### The correct query — `ROWS` frame with an explicit tiebreaker

```sql
SELECT employee_id, effective_date, bonus,
       SUM(bonus) OVER (
           ORDER BY effective_date, employee_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS running_total_bonus
FROM salaries
ORDER BY effective_date, employee_id;
```

**Expected output (all 21 rows):**

| employee_id | effective_date | bonus | running_total_bonus |
|---|---|---|---|
| 1 | 2015-03-01 | 90000 | 90000 |
| 7 | 2015-11-05 | 60000 | 150000 |
| 2 | 2016-05-12 | 40000 | 190000 |
| 10 | 2016-08-09 | 30000 | 220000 |
| 12 | 2016-12-01 | 35000 | 255000 |
| 3 | 2017-01-20 | 20000 | 275000 |
| 8 | 2017-04-18 | 30000 | 305000 |
| 14 | 2017-09-30 | 28000 | 333000 |
| 13 | 2018-06-25 | 12000 | 345000 |
| 4 | 2018-07-15 | 10000 | 355000 |
| 11 | 2019-01-14 | 8000 | 363000 |
| 5 | 2019-09-01 | 10000 | 373000 |
| 1 | 2020-01-01 | 100000 | 473000 |
| 6 | 2020-02-10 | 5000 | 478000 |
| 15 | 2020-10-05 | 9000 | 487000 |
| 2 | 2021-01-01 | 50000 | **537000** |
| 7 | 2021-01-01 | 70000 | **607000** |
| 9 | 2021-03-22 | 10000 | 617000 |
| 3 | 2022-01-01 | 25000 | **642000** |
| 4 | 2022-01-01 | 12000 | **654000** |
| 16 | 2022-01-10 | 6000 | 660000 |

**Line-by-line trace:** `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` means, for every row, "sum every physical row from the start of the (unpartitioned, whole-table) window up to and including this exact row, in the order given by `ORDER BY effective_date, employee_id`." The secondary sort key, `employee_id`, exists purely to **break the tie deterministically** — without it, the two `2021-01-01` rows (and the two `2022-01-01` rows) could be processed in either order on different runs, making the intermediate running values (`537000` then `607000`, versus `607000` then `537000`) non-reproducible, even though the *final* total (`660000`) would be unaffected either way. The final row's running total, `660000`, is the grand total bonus paid across the entire company's history — you can verify this independently by summing every `bonus` value in the seed data.

### The gotcha, demonstrated with the same real ties: `RANGE`'s default behavior

```sql
-- Same query, but relying on the RANGE default (no explicit ROWS)
SELECT employee_id, effective_date, bonus,
       SUM(bonus) OVER (ORDER BY effective_date) AS running_total_range_default
FROM salaries
ORDER BY effective_date, employee_id;
```

**Expected output (only the divergent rows shown; everywhere else matches the `ROWS` version exactly):**

| employee_id | effective_date | bonus | running_total_range_default |
|---|---|---|---|
| 2 | 2021-01-01 | 50000 | **607000** |
| 7 | 2021-01-01 | 70000 | **607000** |
| 9 | 2021-03-22 | 10000 | 617000 |
| 3 | 2022-01-01 | 25000 | **654000** |
| 4 | 2022-01-01 | 12000 | **654000** |
| 16 | 2022-01-10 | 6000 | 660000 |

> **⚠️ Warning — this is the real-data proof of the default-frame ties gotcha introduced in §10.2.** With no explicit `ROWS`, `SUM(bonus) OVER (ORDER BY effective_date)` falls back to the default frame, `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. Because `RANGE` treats same-date rows as a single indivisible peer group, **both** employee 2 and employee 7 (tied at `2021-01-01`) get the *combined* running total as of the end of that whole peer group (`607000`) — not `537000` then `607000`, as the row-by-row `ROWS` version correctly showed. The same thing happens again at `2022-01-01`: both employee 3 and employee 4 show `654000`. If your business question is "give me the running total *as of processing each individual salary record, in a stable order*" (the far more common real-world need — e.g., an audit trail or a payroll ledger), the `RANGE` default is **wrong**, silently double-crediting tied rows with each other's amounts before either one has actually happened, from a strict "this is the Nth record processed" point of view. Always use an explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (with a deterministic tiebreaker in `ORDER BY`) for row-by-row running totals, and reserve the `RANGE` default only for when you deliberately want tied rows to share one combined cumulative value.

### `PARTITION BY` a running total: per-department, with the *same* real tie

```sql
SELECT e.department_id, s.employee_id, s.effective_date, s.bonus,
       SUM(s.bonus) OVER (
           PARTITION BY e.department_id
           ORDER BY s.effective_date, s.employee_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS dept_running_total
FROM salaries s
JOIN employees e ON e.employee_id = s.employee_id
WHERE e.department_id = 1   -- Engineering
ORDER BY s.effective_date, s.employee_id;
```

**Expected output — Engineering department only (11 salary rows, including the real 2022-01-01 tie between employee 3 and employee 4, both Engineering):**

| department_id | employee_id | effective_date | bonus | dept_running_total |
|---|---|---|---|---|
| 1 | 1 | 2015-03-01 | 90000 | 90000 |
| 1 | 2 | 2016-05-12 | 40000 | 130000 |
| 1 | 3 | 2017-01-20 | 20000 | 150000 |
| 1 | 4 | 2018-07-15 | 10000 | 160000 |
| 1 | 5 | 2019-09-01 | 10000 | 170000 |
| 1 | 1 | 2020-01-01 | 100000 | 270000 |
| 1 | 6 | 2020-02-10 | 5000 | 275000 |
| 1 | 2 | 2021-01-01 | 50000 | 325000 |
| 1 | 3 | 2022-01-01 | 25000 | 350000 |
| 1 | 4 | 2022-01-01 | 12000 | 362000 |
| 1 | 16 | 2022-01-10 | 6000 | 368000 |

This is a **partitioned running total with ties** — the exact scenario named as Challenge 1 in §10.22, solved here in full: `PARTITION BY` restarts the running total independently for each department (Engineering's total tops out at `368000`, entirely separate from Sales/HR/Finance/Marketing's own running totals), while the `ROWS`-plus-tiebreaker technique keeps the within-department tie (employee 3 and 4, both `2022-01-01`) deterministic and sequential rather than combined.

---

## 10.10 Worked Pattern: Moving Averages

**Business question:** "What is the trailing 3-order moving average of order revenue, as orders come in chronologically?"

```sql
WITH order_revenue AS (
    SELECT o.order_id, o.order_date, SUM(oi.quantity * oi.unit_price) AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    GROUP BY o.order_id, o.order_date
)
SELECT order_id, order_date, revenue,
       ROUND(AVG(revenue) OVER (
           ORDER BY order_date
           ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
       ), 2) AS moving_avg_3_orders
FROM order_revenue
ORDER BY order_date;
```

**Expected output:**

| order_id | order_date | revenue | moving_avg_3_orders |
|---|---|---|---|
| 1 | 2024-01-05 10:20 | 49498 | 49498.00 |
| 2 | 2024-01-08 14:00 | 5097 | 27297.50 |
| 3 | 2024-01-15 09:30 | 89999 | 48198.00 |
| 4 | 2024-01-20 16:45 | 3298 | 32798.00 |
| 5 | 2024-01-22 11:00 | 29999 | 41098.67 |
| 6 | 2024-02-01 08:15 | 75798 | 36365.00 |
| 7 | 2024-02-03 19:20 | 6998 | 37598.33 |
| 8 | 2024-02-10 12:00 | 45999 | 42931.67 |
| 9 | 2024-02-14 15:30 | 93498 | 48831.67 |
| 10 | 2024-02-18 13:10 | 3897 | 47798.00 |

**Conceptual trace of the window visible to two specific rows:**

- **Order 1 (the very first row):** the frame `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` asks for "2 rows before this one, plus this one" — but there are no rows before the first row. SQL does **not** error or return `NULL` here; the frame simply shrinks to whatever rows *do* exist within its bounds — in this case, just order 1 itself. So the "3-period" moving average for order 1 is really a 1-period average: itself (`49498.00`).
- **Order 2:** the frame wants 2 rows before plus current — only 1 row (order 1) exists before it, so the frame again shrinks, this time to 2 rows: `{49498, 5097}`, averaging to `27297.50`.
- **Order 5 (and every row from here on):** now a full 3-row frame is available — `{89999 (order 3), 3298 (order 4), 29999 (order 5)}` — averaging to `41098.67`. From this point forward every row has a genuine, full 3-order trailing window, sliding forward one order at a time.

> **Important Note:** This "the frame silently shrinks near the boundary rather than erroring or padding with `NULL`/zero" behavior applies to **every** `N PRECEDING`/`N FOLLOWING` frame, for every aggregate window function, not just `AVG`. It is standard, well-defined SQL behavior — but it means moving averages near the very start (or, with a `FOLLOWING` frame, the very end) of your ordered data are computed over *fewer* periods than requested, which can understate volatility in a "smoothed" chart if you don't account for it (e.g., by discarding the first `N-1` rows of a moving-average report, or clearly labeling them as partial-window values).

Change `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` to `ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING` for a **centered** 3-period moving average instead of a trailing one — the same mechanical shrink-at-the-boundary rule applies at both ends in that case.

---

## 10.11 Worked Pattern: Percentage of Total

**Business question:** "What percentage of its department's total salary spend does each employee's salary represent?"

```sql
WITH current_salary AS (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
)
SELECT e.employee_id,
       e.first_name || ' ' || e.last_name AS employee_name,
       d.department_name,
       cs.base_salary,
       SUM(cs.base_salary) OVER (PARTITION BY e.department_id) AS dept_total_salary,
       ROUND(
           100.0 * cs.base_salary / SUM(cs.base_salary) OVER (PARTITION BY e.department_id),
           2
       ) AS pct_of_dept_total
FROM employees e
JOIN current_salary cs ON cs.employee_id = e.employee_id AND cs.rn = 1
JOIN departments d ON d.department_id = e.department_id
ORDER BY d.department_name, cs.base_salary DESC;
```

**Expected output:**

| employee_id | employee_name | department_name | base_salary | dept_total_salary | pct_of_dept_total |
|---|---|---|---|---|---|
| 12 | Nikhil Gupta | Finance | 250000 | 380000 | 65.79 |
| 13 | Divya Shah | Finance | 130000 | 380000 | 34.21 |
| 1 | Aditi Rao | Engineering | 520000 | 1485000 | 35.02 |
| 2 | Rahul Mehta | Engineering | 320000 | 1485000 | 21.55 |
| 3 | Sneha Kulkarni | Engineering | 210000 | 1485000 | 14.14 |
| 4 | Vikram Joshi | Engineering | 140000 | 1485000 | 9.43 |
| 5 | Ananya Singh | Engineering | 120000 | 1485000 | 8.08 |
| 16 | Aman Chawla | Engineering | 95000 | 1485000 | 6.40 |
| 6 | Karan Verma | Engineering | 80000 | 1485000 | 5.39 |
| 10 | Rohan Kapoor | HR | 240000 | 340000 | 70.59 |
| 11 | Isha Bhatt | HR | 100000 | 340000 | 29.41 |
| 14 | Rajesh Iyer | Marketing | 230000 | 335000 | 68.66 |
| 15 | Pooja Reddy | Marketing | 105000 | 335000 | 31.34 |
| 7 | Priya Nair | Sales | 300000 | 505000 | 59.41 |
| 8 | Arjun Das | Sales | 110000 | 505000 | 21.78 |
| 9 | Meera Pillai | Sales | 95000 | 505000 | 18.81 |

**The core technique, isolated:** `SUM(cs.base_salary) OVER (PARTITION BY e.department_id)` computes the department's total **without collapsing any row** (§10.8's Form 2), which lets you use it directly as the denominator of a per-row division — `100.0 * row_value / SUM(...) OVER(...)`. This is the canonical "percentage of group total" pattern, and it composes directly with everything from §10.8: the `SUM() OVER()` call is identical whether you're computing a percentage, a "how far above/below the average" flag, or any other per-row-vs-group comparison.

Sanity-check the arithmetic for Engineering: `520000 + 320000 + 210000 + 140000 + 120000 + 95000 + 80000 = 1,485,000`, matching `dept_total_salary`; and `520000 / 1485000 = 35.017...% ≈ 35.02%`, matching `pct_of_dept_total` for Aditi Rao.

> **Important Note:** Multiplying by `100.0` (not `100`) forces floating/decimal division rather than integer division in dialects where `100 * int_column / int_column` could otherwise truncate — always use an explicit decimal literal (`100.0`) when computing percentages from integer or `NUMERIC` columns to avoid silent truncation. This is the same integer-division caution from Chapter 5's arithmetic-functions coverage, resurfacing here.

---

## 10.12 Worked Pattern: Ranking Within Groups

**Business question:** "Rank every employee by salary, within their own department, without hiding anyone."

```sql
WITH current_salary AS (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
)
SELECT d.department_name,
       e.first_name || ' ' || e.last_name AS employee_name,
       cs.base_salary,
       RANK() OVER (PARTITION BY e.department_id ORDER BY cs.base_salary DESC) AS salary_rank_in_dept
FROM employees e
JOIN current_salary cs ON cs.employee_id = e.employee_id AND cs.rn = 1
JOIN departments d ON d.department_id = e.department_id
ORDER BY d.department_name, salary_rank_in_dept;
```

**Expected output:**

| department_name | employee_name | base_salary | salary_rank_in_dept |
|---|---|---|---|
| Engineering | Aditi Rao | 520000 | 1 |
| Engineering | Rahul Mehta | 320000 | 2 |
| Engineering | Sneha Kulkarni | 210000 | 3 |
| Engineering | Vikram Joshi | 140000 | 4 |
| Engineering | Ananya Singh | 120000 | 5 |
| Engineering | Aman Chawla | 95000 | 6 |
| Engineering | Karan Verma | 80000 | 7 |
| Finance | Nikhil Gupta | 250000 | 1 |
| Finance | Divya Shah | 130000 | 2 |
| HR | Rohan Kapoor | 240000 | 1 |
| HR | Isha Bhatt | 100000 | 2 |
| Marketing | Rajesh Iyer | 230000 | 1 |
| Marketing | Pooja Reddy | 105000 | 2 |
| Sales | Priya Nair | 300000 | 1 |
| Sales | Arjun Das | 110000 | 2 |
| Sales | Meera Pillai | 95000 | 3 |

**Conceptual trace:** `PARTITION BY e.department_id` gives Sneha Kulkarni a window containing only her 6 Engineering colleagues (plus herself) — she never competes against Priya Nair (Sales) for a rank number, even though Priya's salary (`300000`) is higher than Sneha's (`210000`). Within that 7-row Engineering window, `RANK() OVER (... ORDER BY base_salary DESC)` places her exactly 3rd, and every department restarts its rank numbering independently from `1` — notice HR, Finance, Marketing, and Sales each have their own `rank = 1` row, one per department, which would be impossible to express with a single un-partitioned `RANK()`.

This exact result set — every employee kept, each carrying a rank relative only to their own department — is precisely what `GROUP BY` alone can never produce (§10.8): the closest a `GROUP BY` query could get is `MAX(base_salary)` per department, telling you *what* the top salary is, but never *who* holds every rank position while still showing everyone else too.

---

## 10.13 Worked Pattern: Top-N Per Group

### Why you can't just put `ROW_NUMBER()` in `WHERE`

Recall the logical query processing order from §10.1: window functions are computed at step 5, *after* `WHERE` (step 2). This means the following is illegal and will not run:

```sql
-- ❌ ILLEGAL — ROW_NUMBER() doesn't exist yet when WHERE is evaluated
SELECT employee_id, department_id, base_salary,
       ROW_NUMBER() OVER (PARTITION BY department_id ORDER BY base_salary DESC) AS rn
FROM current_salary_view
WHERE rn <= 2;
```

**[PostgreSQL]** rejects this with `ERROR: column "rn" does not exist` (since `rn` is a `SELECT`-list alias for an expression that, from `WHERE`'s point of view, has not been computed yet and cannot be referenced by name at that stage). If you instead write the full window-function expression directly inside `WHERE`, PostgreSQL is even more explicit: `ERROR: window functions are not allowed in WHERE`. Every mainstream dialect enforces this same restriction, because it is standard SQL, not an implementation gap.

**The fix — wrap it in a subquery or CTE, and filter the *outer* query:**

```sql
WITH current_salary AS (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
),
ranked AS (
    SELECT d.department_name,
           e.first_name || ' ' || e.last_name AS employee_name,
           cs.base_salary,
           ROW_NUMBER() OVER (PARTITION BY e.department_id ORDER BY cs.base_salary DESC) AS rn_in_dept
    FROM employees e
    JOIN current_salary cs ON cs.employee_id = e.employee_id AND cs.rn = 1
    JOIN departments d ON d.department_id = e.department_id
)
SELECT department_name, employee_name, base_salary, rn_in_dept
FROM ranked
WHERE rn_in_dept <= 2
ORDER BY department_name, rn_in_dept;
```

This works because, by the time the *outer* query's `WHERE rn_in_dept <= 2` runs, `ranked` is a fully materialized (logically speaking) set of rows in which `rn_in_dept` is now just an ordinary column value, computed and finished in the inner query — there is no window function left to evaluate at the point this `WHERE` runs. **This is the general pattern for filtering on any window function's result: compute it in a CTE or subquery, then filter in the query layered on top.**

**Expected output — top 2 highest-paid employees per department:**

| department_name | employee_name | base_salary | rn_in_dept |
|---|---|---|---|
| Engineering | Aditi Rao | 520000 | 1 |
| Engineering | Rahul Mehta | 320000 | 2 |
| Finance | Nikhil Gupta | 250000 | 1 |
| Finance | Divya Shah | 130000 | 2 |
| HR | Rohan Kapoor | 240000 | 1 |
| HR | Isha Bhatt | 100000 | 2 |
| Marketing | Rajesh Iyer | 230000 | 1 |
| Marketing | Pooja Reddy | 105000 | 2 |
| Sales | Priya Nair | 300000 | 1 |
| Sales | Arjun Das | 110000 | 2 |

No department in this data has a tie at the rank-2 boundary, so `ROW_NUMBER()` and `RANK()` would have produced identical results here — the next example shows real seed data where they genuinely diverge.

### Top 3 best-selling products per category — where `RANK()` and `ROW_NUMBER()` genuinely disagree

```sql
WITH product_sales AS (
    SELECT p.product_id, p.product_name, c.category_name,
           COALESCE(SUM(oi.quantity), 0) AS units_sold
    FROM products p
    JOIN categories c ON c.category_id = p.category_id
    LEFT JOIN order_items oi ON oi.product_id = p.product_id
    GROUP BY p.product_id, p.product_name, c.category_name
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY category_name ORDER BY units_sold DESC) AS rn,
           RANK()       OVER (PARTITION BY category_name ORDER BY units_sold DESC) AS rnk
    FROM product_sales
)
SELECT category_name, product_name, units_sold, rn, rnk
FROM ranked
WHERE rnk <= 3
ORDER BY category_name, rnk, product_name;
```

**Expected output:**

| category_name | product_name | units_sold | rn | rnk |
|---|---|---|---|---|
| Home & Kitchen | Non-stick Pan Set | 1 | 1 | 1 |
| Home & Kitchen | Electric Kettle | 1 | 2 | **1** |
| Laptops | UltraBook Pro 14 | 2 | 1 | 1 |
| Laptops | GameBook 15 | 1 | 2 | **2** |
| Laptops | Laptop Sleeve 14" | 1 | 3 | **2** |
| Men | Men Cotton Shirt | 5 | 1 | 1 |
| Mobiles | Wireless Earbuds | 4 | 1 | 1 |
| Mobiles | Galaxy Phone X | 2 | 2 | 2 |
| Mobiles | Pixel Lite | 1 | 3 | 3 |
| Women | Women Kurta Set | 1 | 1 | 1 |

**Trace the real tie in the Laptops category:** `GameBook 15` and `Laptop Sleeve 14"` both sold exactly `1` unit — a genuine tie in the real seed data. `ROW_NUMBER()` arbitrarily breaks the tie, giving them `2` and `3`. `RANK()` correctly gives them **both** `2`, reflecting that they are, in fact, tied for 2nd place in Laptops sales. Because we filtered `WHERE rnk <= 3` (using `RANK`, not `ROW_NUMBER`), **both** tied products correctly appear in the "top 3" — and this is exactly why the filter column matters: had we filtered `WHERE rn <= 3` instead, we'd have kept whichever one of the two tied products `ROW_NUMBER` happened to place 3rd (and lost nothing here, since both fit within 3 anyway) — but similarly, filtering `WHERE rnk <= 2` on this same tie would have kept **both** tied 2nd-place products, legitimately returning *more than 2* rows for "top 2," because `RANK()` never artificially truncates a tie.

> **Important Note — a hypothetical to make this vivid:** imagine a category with 5 products where the 3rd, 4th, and 5th all tie on units sold. `RANK() <= 3` would correctly return **all 5** products (positions 1, 2, 3, 3, 3) — a legitimate "everyone genuinely tied for 3rd place is included" answer. `ROW_NUMBER() <= 3` would arbitrarily keep only 3 of those 5 tied products and silently drop the other 2, even though they earned an identical result. **Choosing `RANK` vs. `ROW_NUMBER` for a Top-N filter is a real business decision, not a stylistic one** — decide up front whether ties should all be included (`RANK`) or whether you need an exact, fixed row count no matter what (`ROW_NUMBER`, accepting that ties are broken arbitrarily unless you add more tiebreaker columns to `ORDER BY`).

---

## 10.14 Worked Pattern: Gaps and Islands

**Business question:** "Find every consecutive run ('island') of `PRESENT` days per employee."

The real `attendance` seed data only spans 2–3 days per employee, which is too sparse to show an interesting multi-day streak. To demonstrate the technique properly, we use this **extended illustrative dataset**, built with the exact same table shape (`employee_id`, `work_date`, `status`) as the real `attendance` table, reproducible exactly as written via an inline `VALUES` list:

```sql
WITH ext_attendance(employee_id, work_date, status) AS (
    VALUES
        (3,'2024-01-01','PRESENT'), (3,'2024-01-02','PRESENT'), (3,'2024-01-03','PRESENT'),
        (3,'2024-01-04','ABSENT'),  (3,'2024-01-05','PRESENT'), (3,'2024-01-08','PRESENT'),
        (3,'2024-01-09','PRESENT'), (3,'2024-01-10','LATE'),
        (4,'2024-01-01','PRESENT'), (4,'2024-01-02','ABSENT'),  (4,'2024-01-03','PRESENT'),
        (4,'2024-01-04','PRESENT'), (4,'2024-01-05','PRESENT'), (4,'2024-01-08','PRESENT'),
        (4,'2024-01-09','ABSENT'),  (4,'2024-01-10','PRESENT'),
        (6,'2024-01-01','PRESENT'), (6,'2024-01-02','PRESENT'), (6,'2024-01-03','PRESENT'),
        (6,'2024-01-04','PRESENT'), (6,'2024-01-05','PRESENT'), (6,'2024-01-08','ABSENT'),
        (6,'2024-01-09','PRESENT'), (6,'2024-01-10','PRESENT')
),
present_only AS (
    SELECT employee_id, work_date,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY work_date) AS rn
    FROM ext_attendance
    WHERE status = 'PRESENT'
),
islands AS (
    SELECT employee_id, work_date, rn,
           (work_date - rn) AS island_key   -- [PostgreSQL]: DATE minus INTEGER subtracts N days
    FROM present_only
)
SELECT employee_id,
       MIN(work_date) AS streak_start,
       MAX(work_date) AS streak_end,
       COUNT(*) AS days_present_in_streak
FROM islands
GROUP BY employee_id, island_key
ORDER BY employee_id, streak_start;
```

**Expected output:**

| employee_id | streak_start | streak_end | days_present_in_streak |
|---|---|---|---|
| 3 | 2024-01-01 | 2024-01-03 | 3 |
| 3 | 2024-01-05 | 2024-01-05 | 1 |
| 3 | 2024-01-08 | 2024-01-09 | 2 |
| 4 | 2024-01-01 | 2024-01-01 | 1 |
| 4 | 2024-01-03 | 2024-01-05 | 3 |
| 4 | 2024-01-08 | 2024-01-08 | 1 |
| 4 | 2024-01-10 | 2024-01-10 | 1 |
| 6 | 2024-01-01 | 2024-01-05 | 5 |
| 6 | 2024-01-09 | 2024-01-10 | 2 |

**The technique, explained mechanically, for employee 3 specifically:**

| work_date | status | rn (row number among PRESENT rows only) | island_key = work_date − rn |
|---|---|---|---|
| 2024-01-01 | PRESENT | 1 | 2023-12-31 |
| 2024-01-02 | PRESENT | 2 | 2023-12-31 |
| 2024-01-03 | PRESENT | 3 | 2023-12-31 |
| *(2024-01-04 ABSENT — filtered out before `rn` is even assigned)* | | | |
| 2024-01-05 | PRESENT | 4 | 2024-01-01 |
| 2024-01-08 | PRESENT | 5 | 2024-01-03 |
| 2024-01-09 | PRESENT | 6 | 2024-01-03 |

**The core insight:** among rows that are *already filtered down to only `PRESENT` days*, if the days are truly consecutive calendar dates, then `work_date` increases by exactly 1 for each row, and `rn` (the row number within that filtered set) *also* increases by exactly 1 for each row — so `work_date − rn` stays **constant** for the whole run. The moment a day is skipped (because it wasn't `PRESENT`, so it never got a `rn` at all), `work_date` jumps ahead by more than 1 while `rn` only advances by 1, so `work_date − rn` **shifts to a new value** — a brand new "island key." Grouping by `(employee_id, island_key)` therefore groups exactly the rows belonging to the same unbroken run, and `MIN`/`MAX(work_date)` gives you that run's start and end dates. Employee 3's first three `PRESENT` days (`01-01` through `01-03`) all land on `island_key = 2023-12-31`, forming one 3-day island; `01-05` gets its own key (`2024-01-01`) because `01-04` was `ABSENT` and broke the run; `01-08` and `01-09` share a third key, forming a 2-day island (note: `01-06`/`01-07` simply have no rows at all in this dataset, which has exactly the same gap-creating effect as an explicit `ABSENT` row would).

> **Important Note [dialect]:** The `work_date - rn` subtraction (a `DATE` minus an `INTEGER`, yielding a `DATE`) works directly in **[PostgreSQL]** and **[MySQL]** (`DATE_SUB(work_date, INTERVAL rn DAY)` is the more explicit MySQL form). **[SQL Server]** requires `DATEADD(day, -rn, work_date)`. **[Oracle]** supports the same direct `date_column - integer` arithmetic as PostgreSQL. If your date column also carries a time component, cast/truncate to a pure date first, or the arithmetic will still work but the grouping key will carry the time component along, which is usually harmless but worth being aware of.

This is the same "row-number-difference" technique referenced by name at the top of this chapter, applied to real, consecutive-date island detection — and it generalizes directly to Challenge 5 (§10.22), where we extend it to find each employee's *longest* streak and then rank employees by it.

---

## 10.15 Common Mistakes

1. **Putting a window function directly in `WHERE` or `HAVING`.** Covered fully in §10.1 and §10.13. Symptom: `ERROR: window functions are not allowed in WHERE` (or the equivalent in your dialect). Fix: wrap the window function in a CTE/subquery and filter the outer query.

2. **Not realizing that adding `ORDER BY` to `OVER(...)` silently changes the default frame.** Covered fully in §10.2 and demonstrated with real ties in §10.9. Symptom: a `SUM`/`AVG` that looks like a per-partition total suddenly starts behaving like a running total the moment you add an `ORDER BY` (often added only to control a *different* function in the same query, or out of habit). Fix: always write the frame clause explicitly for `SUM`/`AVG`/`COUNT` when `ORDER BY` is present and you don't want a running calculation — use `RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` (or omit `ORDER BY` entirely, if ordering isn't otherwise needed) to force "whole partition" behavior.

3. **Using `LAST_VALUE` without an explicit frame.** Covered fully and verified with real data in §10.6. This is common enough, and surprising enough, that it deserves restating on its own: `LAST_VALUE(...) OVER (ORDER BY x)`, with no frame clause, will (almost) always just return the current row's own value, because the default frame's upper bound is `CURRENT ROW`. Always pair `LAST_VALUE` with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` (or a deliberately chosen `... AND N FOLLOWING`) unless you specifically want the running/truncated behavior.

4. **Forgetting a deterministic tiebreaker column in `ORDER BY` for `ROW_NUMBER()`, then relying on "row 1" being a specific, stable row.** Covered in §10.3. Symptom: a Top-N-per-group query (§10.13) that returns a *different* row for a tied group on a re-run, a schema change, or a different query plan, even though the underlying data hasn't changed. Fix: always add a unique column (typically a primary key) as a final `ORDER BY` tiebreaker whenever ties are even remotely possible.

5. **Confusing `PARTITION BY` with `GROUP BY` and expecting rows to collapse.** A surprisingly common first encounter — a beginner writes `SELECT department_id, AVG(salary) OVER (PARTITION BY department_id) FROM employees` expecting one row per department, and is confused to see every individual employee row still present. This is *correct*, expected window-function behavior (§10.8) — if you want collapsed rows, you need `GROUP BY`, not `PARTITION BY`.

6. **Mixing up `RANK()` and `ROW_NUMBER()` for a Top-N filter without thinking about ties.** Covered fully with real data in §10.13 (the Laptops tie). Decide deliberately whether ties should expand your "Top N" beyond N rows (`RANK`) or be arbitrarily truncated to exactly N (`ROW_NUMBER`).

---

## 10.16 Edge Cases

### Ties in `ORDER BY` affecting determinism

Already covered at length (§10.3, §10.15) — restated here as the formal rule: **the SQL standard does not guarantee which physical row receives which `ROW_NUMBER()` value among exactly-tied rows.** Two engines, two query plans, or even the same engine on a re-run after a data reorganization, may break the tie differently unless you add a deterministic secondary sort key.

### `NULL`s in the `ORDER BY` of a window function

`NULL` values need a placement rule within an `ORDER BY`, exactly as in a regular top-level `ORDER BY` (Chapter 4). Using a real seed-data example — `attendance.check_in` on `2024-01-01`, where employee 5 (Ananya Singh, status `LEAVE`) has `check_in = NULL`:

```sql
SELECT employee_id, check_in,
       LAG(check_in) OVER (ORDER BY check_in) AS prev_checkin
FROM attendance
WHERE work_date = '2024-01-01'
ORDER BY check_in;
```

**[PostgreSQL]** and **[Oracle]** default to **`NULLS LAST`** for `ASC` ordering (and `NULLS FIRST` for `DESC`). Under that rule, employee 5's `NULL` sorts to the *end* of the sequence:

| employee_id | check_in | prev_checkin |
|---|---|---|
| 6 | 09:00 | NULL |
| 3 | 09:05 | 09:00 |
| 4 | 09:10 | 09:05 |
| 5 | NULL | 09:10 |

**[MySQL]** and **[SQL Server]** instead default to **`NULLS FIRST`** for `ASC` ordering (treating `NULL` as the smallest possible value), which flips the sequence entirely — employee 5 would sort *first*, changing every single `LAG` result:

| employee_id | check_in | prev_checkin |
|---|---|---|
| 5 | NULL | NULL |
| 6 | 09:00 | NULL |
| 3 | 09:05 | 09:00 |
| 4 | 09:10 | 09:05 |

> **⚠️ Warning:** The *same query, same data* produces genuinely different `LAG`/`LEAD`/ranking results depending on your dialect's default `NULL` ordering. **[PostgreSQL]** and **[Oracle]** support explicit `NULLS FIRST`/`NULLS LAST` syntax directly inside `ORDER BY` (including inside `OVER(...)`) to make this unambiguous and portable-in-intent: `ORDER BY check_in NULLS LAST`. **[MySQL]** and **[SQL Server]** lack this syntax and require a workaround, most commonly `ORDER BY (check_in IS NULL), check_in` (MySQL — `IS NULL` evaluates to `0`/`1`, sorting non-NULLs first) or `ORDER BY CASE WHEN check_in IS NULL THEN 1 ELSE 0 END, check_in` (SQL Server). If a query's correctness depends on where `NULL`s land in a window's `ORDER BY`, **always make the `NULL` placement explicit** rather than relying on the dialect default.

### Empty partitions

There is no such thing as a window function "outputting" an empty partition — if a `PARTITION BY` key has zero rows after `WHERE`/`JOIN`/`GROUP BY` have run, that partition contributes zero rows to the result, exactly like a `GROUP BY` group that never forms (Chapter 6, §6.10). You will never see a row with a `NULL` or zero-filled window-function result "representing" a partition that doesn't exist — the partition key itself simply never appears.

### Single-row partitions

A partition with exactly one row is well-defined for every window function covered in this chapter: `ROW_NUMBER`/`RANK`/`DENSE_RANK` all return `1`; `LAG`/`LEAD` return the `default` argument (or `NULL`); `FIRST_VALUE`/`LAST_VALUE`/aggregate functions all simply return that single row's own value, since it is simultaneously the first, last, minimum, maximum, and entire sum of a one-row window.

---

## 10.17 When to Use / Not Use Window Functions

| Use a window function when... | Don't reach for a window function when... |
|---|---|
| You need a per-row rank, running total, moving average, or "vs. group" comparison, while keeping every original row | You only need one collapsed summary row per group — plain `GROUP BY` is simpler and, in most engines, at least as fast |
| You need to compare a row to a neighboring row (previous/next) without a self-join | You need to filter which rows appear based on a group-level condition without touching row-level detail — `HAVING` is the right tool |
| You need Top-N-per-group, gaps/islands, or cohort-style analysis | You need `DISTINCT` values only, with no per-row context needed at all |
| The report genuinely needs "detail + aggregate side by side" in one result set | You're on a very old engine without window-function support (pre-8.0 MySQL, for example — see the dialect note in §10.19) and must fall back to correlated subqueries or self-joins |

---

## 10.18 Comparisons

### `RANK()` vs. `DENSE_RANK()` vs. `ROW_NUMBER()` — concrete recap

| | Sneha & Vikram (tied at 210000) | Ananya (next distinct value, 140000) |
|---|---|---|
| `ROW_NUMBER()` | `3`, `4` (arbitrary among themselves) | `5` |
| `RANK()` | `3`, `3` | `5` (skips `4`) |
| `DENSE_RANK()` | `3`, `3` | `4` (no skip) |

### `GROUP BY` vs. window functions — recap

| | `GROUP BY` | Window function |
|---|---|---|
| Row count in output | One row per group | Same as input row count |
| Can reference individual row's own column alongside the aggregate? | No — that column no longer exists per-group | Yes — that's the entire point |
| Can filter the *result* using the aggregate? | Yes, via `HAVING` | Not directly — must wrap in a CTE/subquery (§10.13) |
| Typical use | Dashboard summary tiles, category breakdowns | Rankings, running totals, moving averages, "vs. average" flags, Top-N |

### `ROWS` vs. `RANGE` vs. `GROUPS` frame types

| | Counts by | Ties treated as | Dialect support |
|---|---|---|---|
| `ROWS` | Physical row position | Independent — no special tie handling | **[PostgreSQL] [MySQL 8.0+] [SQL Server] [Oracle]** — universal |
| `RANGE` | Value of the `ORDER BY` expression | One indivisible peer group | **[PostgreSQL] [MySQL 8.0+] [Oracle]** full support; **[SQL Server]** only the `UNBOUNDED PRECEDING`/`CURRENT ROW` default form |
| `GROUPS` | Count of distinct peer groups | One indivisible peer group, but counted as a single "step" for offsets | **[PostgreSQL] 11+ only** among the four primary dialects |

### `FIRST_VALUE`/`LAST_VALUE` default frame vs. fixed frame

| | Frame | `FIRST_VALUE` result | `LAST_VALUE` result |
|---|---|---|---|
| Default (`ORDER BY` present, no explicit frame) | `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` | Correct — always includes row 1 | **Wrong for most intents** — always equals current row |
| Explicit fix | `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` | Still correct | Correct — always the true last row of the partition |

---

## 10.19 Real-World Use Cases

- **Leaderboards and gamification:** `RANK()`/`DENSE_RANK()` power "top players this week," handling ties the way a real scoreboard would.
- **Financial running balances:** `SUM(amount) OVER (PARTITION BY account_id ORDER BY transaction_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` is the exact query shape behind a bank statement's running balance column — we revisit this precise pattern with actual transaction data in **Chapter 11 (Transactions)**'s sibling database, `banking_db`.
- **Sales and performance dashboards:** period-over-period growth (`LAG`), percentage-of-team-total (`SUM() OVER (PARTITION BY team)`), and rep rankings all rely directly on the patterns built in this chapter.
- **Analytics/BI "trend line" smoothing:** moving averages (§10.10) are the standard technique for smoothing noisy day-to-day metrics into a readable trend on a dashboard chart.
- **Cohort analysis:** `MIN(order_date) OVER (PARTITION BY user_id)` (§10.22, Challenge 3) identifies each customer's first-ever purchase date, the anchor point for retention/cohort reporting.
- **Deduplication and "pick one row per key":** `ROW_NUMBER() OVER (PARTITION BY natural_key ORDER BY updated_at DESC) = 1` is the standard technique for collapsing a history/log table down to "the current row per entity" — exactly the `current_salary` CTE used repeatedly throughout this chapter, and a pattern we return to formally in Chapter 31 (Slowly Changing Dimensions).
- **Attendance/operations monitoring:** gaps-and-islands (§10.14) detects consecutive-day patterns — perfect attendance streaks, consecutive server outages, consecutive failed login attempts — from nothing but a timestamped event log.

---

## 10.20 Practice Questions

Try each of these against `company_db` and `ecommerce_db` before moving on. No answers are provided — verify your own output against the mechanics explained in this chapter.

1. Using `salaries`, write a query that shows every salary record along with a `ROW_NUMBER()` numbering each employee's own salary history from oldest to newest (i.e., `1` for their first-ever recorded salary, `2` for their second, etc.).
2. For each employee in `employees`, compute their `hire_date` alongside the average `hire_date`... actually, compute their `base_salary` (using only their most recent salary row) alongside the **company-wide** average base salary (no `PARTITION BY` at all) — and a column flagging `ABOVE_COMPANY_AVG` / `AT_OR_BELOW_COMPANY_AVG`.
3. Using `order_items` and `products`, compute a running total of `quantity * unit_price` per `order_id`, ordered by `order_item_id`, so each line item shows the order's cumulative value up to and including that item.
4. Rank departments (not employees) by their total current payroll (`SUM` of each employee's latest `base_salary`), using `DENSE_RANK()`. Are any two departments tied?
5. Using `LAG`, compute the number of days between each employee's `hire_date` and the previous employee's `hire_date`, company-wide, ordered by `hire_date`. (Hint: date subtraction returns an interval/number of days depending on dialect.)
6. Write a query using `NTILE(3)` to split all products in `ecommerce_db` into three price tiers ("budget," "mid," "premium"), ordered by `price` ascending, and label each tier accordingly with a `CASE` expression on the `NTILE` result.
7. For each product category, find the *least*-popular product (fewest units sold) using the Top-N-per-group pattern from §10.13 — this time ordering `ASC` instead of `DESC`.
8. Using `FIRST_VALUE` and `LAST_VALUE` (with the correct explicit frame), show, for every order, the very first order date and the very last order date in the entire `orders` table, attached to every row.
9. Explain, in your own words, why `SUM(bonus) OVER (ORDER BY effective_date)` (no explicit frame, relying on the `RANGE` default) gives a different answer than `SUM(bonus) OVER (ORDER BY effective_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` specifically at `2021-01-01` and `2022-01-01` in the real `salaries` table, but gives the *same* answer everywhere else.
10. Using the attendance gaps-and-islands technique from §10.14, but applied to `ABSENT` days instead of `PRESENT` days on the extended illustrative dataset, find every consecutive run of absences per employee.
11. Write a query that computes each employee's salary as a percentage of the **company-wide** total (not their department's total) — a small but important variation on §10.11's pattern (hint: what does the `PARTITION BY` clause need to look like for a "whole result set" denominator?).
12. Using `RANK()` and a `HAVING`-style filter (wrapped correctly per §10.13), find every product category that has **more than one** product tied for the top sales position.

---

## 10.21 Difficult Analytical Challenges

These combine multiple concepts from this chapter. Try each one yourself first — a full worked solution with verified output follows each problem statement.

### Challenge 1 — Partitioned running total with ties

**Problem:** Using the real `salaries` table joined to `employees`, compute a running total of `bonus` **per department**, ordered by `effective_date`, using a deterministic `ROWS`-based frame — for the Engineering department specifically, which contains a genuine tie (`employee_id = 3` and `employee_id = 4`, both `effective_date = 2022-01-01`).

<details>
<summary>Worked solution</summary>

This is solved in full, with verified output, in **§10.9** ("`PARTITION BY` a running total: per-department, with the *same* real tie"). The key techniques combined: `PARTITION BY department_id` to restart the running total per department, `ORDER BY effective_date, employee_id` for a deterministic tiebreak, and `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` to avoid the `RANGE`-with-ties trap. Engineering's running total correctly reaches `368000` as its final (11th) row.

</details>

### Challenge 2 — Year-over-year growth using `LAG` across a date-partitioned window

**Problem:** For each department, compute the total bonus paid per calendar year (extracted from `salaries.effective_date`), then compute each year's percentage growth over that *same department's* prior year, using `LAG` partitioned by department and ordered by year.

<details>
<summary>Worked solution</summary>

```sql
WITH dept_year AS (
    SELECT e.department_id,
           EXTRACT(YEAR FROM s.effective_date)::int AS yr,
           SUM(s.bonus) AS total_bonus
    FROM salaries s
    JOIN employees e ON e.employee_id = s.employee_id
    GROUP BY e.department_id, EXTRACT(YEAR FROM s.effective_date)
)
SELECT d.department_name, dy.yr, dy.total_bonus,
       LAG(dy.total_bonus) OVER (PARTITION BY dy.department_id ORDER BY dy.yr) AS prev_yr_bonus,
       ROUND(
           100.0 * (dy.total_bonus - LAG(dy.total_bonus) OVER (PARTITION BY dy.department_id ORDER BY dy.yr))
           / LAG(dy.total_bonus) OVER (PARTITION BY dy.department_id ORDER BY dy.yr),
       2) AS pct_growth
FROM dept_year dy
JOIN departments d ON d.department_id = dy.department_id
ORDER BY d.department_name, dy.yr;
```

**Expected output (verified):**

| department_name | yr | total_bonus | prev_yr_bonus | pct_growth |
|---|---|---|---|---|
| Engineering | 2015 | 90000 | NULL | NULL |
| Engineering | 2016 | 40000 | 90000 | -55.56 |
| Engineering | 2017 | 20000 | 40000 | -50.00 |
| Engineering | 2018 | 10000 | 20000 | -50.00 |
| Engineering | 2019 | 10000 | 10000 | 0.00 |
| Engineering | 2020 | 105000 | 10000 | 950.00 |
| Engineering | 2021 | 50000 | 105000 | -52.38 |
| Engineering | 2022 | 43000 | 50000 | -14.00 |
| Finance | 2016 | 35000 | NULL | NULL |
| Finance | 2018 | 12000 | 35000 | -65.71 |
| HR | 2016 | 30000 | NULL | NULL |
| HR | 2019 | 8000 | 30000 | -73.33 |
| Marketing | 2017 | 28000 | NULL | NULL |
| Marketing | 2020 | 9000 | 28000 | -67.86 |
| Sales | 2015 | 60000 | NULL | NULL |
| Sales | 2017 | 30000 | 60000 | -50.00 |
| Sales | 2021 | 80000 | 30000 | 166.67 |

**Trace:** `PARTITION BY dy.department_id` ensures `LAG` never crosses department boundaries — Sales' 2017 value never accidentally becomes "the previous year" for HR. Note also that **years with no salary activity for a department simply don't appear as rows at all** (e.g., Engineering has no 2021→2022... wait, it does; but Finance jumps straight from 2016 to 2018, with no 2017 row) — `LAG` still correctly treats `2018` as "the row before this one *in the partition*," which is 2016's value, even though the years aren't literally adjacent integers. This is an important, generalizable lesson: **`LAG`/`LEAD` operate on row position within the ordered partition, not on the literal numeric/date gap between values** — if you need true calendar-aware "same time last year" comparisons even when a year is completely missing, you must join against a generated calendar/year series rather than relying on `LAG`.

</details>

### Challenge 3 — Cohort-style first-purchase-date analysis using `MIN() OVER`

**Problem:** For every order in `ecommerce_db`, determine whether it was that customer's very first order, using `MIN(order_date) OVER (PARTITION BY user_id)` as the cohort anchor point.

<details>
<summary>Worked solution</summary>

```sql
SELECT o.order_id, o.user_id, o.order_date,
       MIN(o.order_date) OVER (PARTITION BY o.user_id) AS first_order_date,
       CASE WHEN o.order_date = MIN(o.order_date) OVER (PARTITION BY o.user_id)
            THEN 'FIRST_ORDER' ELSE 'REPEAT_ORDER' END AS order_type
FROM orders o
ORDER BY o.user_id, o.order_date;
```

**Expected output (verified):**

| order_id | user_id | order_date | first_order_date | order_type |
|---|---|---|---|---|
| 1 | 1 | 2024-01-05 10:20 | 2024-01-05 10:20 | FIRST_ORDER |
| 3 | 1 | 2024-01-15 09:30 | 2024-01-05 10:20 | REPEAT_ORDER |
| 8 | 1 | 2024-02-10 12:00 | 2024-01-05 10:20 | REPEAT_ORDER |
| 2 | 2 | 2024-01-08 14:00 | 2024-01-08 14:00 | FIRST_ORDER |
| 4 | 3 | 2024-01-20 16:45 | 2024-01-20 16:45 | FIRST_ORDER |
| 5 | 4 | 2024-01-22 11:00 | 2024-01-22 11:00 | FIRST_ORDER |
| 6 | 5 | 2024-02-01 08:15 | 2024-02-01 08:15 | FIRST_ORDER |
| 7 | 6 | 2024-02-03 19:20 | 2024-02-03 19:20 | FIRST_ORDER |
| 9 | 7 | 2024-02-14 15:30 | 2024-02-14 15:30 | FIRST_ORDER |
| 10 | 8 | 2024-02-18 13:10 | 2024-02-18 13:10 | FIRST_ORDER |

Only user 1 has repeat business in the seed data (3 orders total); every other user in `ecommerce_db` has placed exactly one order so far, so they each show a single `FIRST_ORDER` row. `MIN(order_date) OVER (PARTITION BY user_id)` finds each customer's earliest order **without collapsing any of their other orders** — this is the anchor value a real cohort-retention report would group customers by (e.g., "cohort month = the month of `first_order_date`"), then measure what fraction of each cohort placed a *repeat* order in subsequent months.

</details>

### Challenge 4 — Median approximation via `NTILE` vs. exact median via `PERCENTILE_CONT` **[PostgreSQL]**

**Problem:** Compute the median current base salary for each department two ways: (a) an approximate method using `NTILE`, and (b) the exact method using PostgreSQL's `PERCENTILE_CONT`.

<details>
<summary>Worked solution</summary>

**(a) `NTILE`-based approximation** buckets each department's employees into 2 groups by salary; the median sits somewhere near the boundary between bucket 1 and bucket 2, but `NTILE` alone can't pinpoint it exactly — it only tells you which "half" each row falls in:

```sql
WITH current_salary AS (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
)
SELECT e.department_id, cs.base_salary,
       NTILE(2) OVER (PARTITION BY e.department_id ORDER BY cs.base_salary) AS half
FROM employees e
JOIN current_salary cs ON cs.employee_id = e.employee_id AND cs.rn = 1
ORDER BY e.department_id, cs.base_salary;
```

This tells you *which employees* are in the lower/upper half per department, but for an *exact* median value, standard SQL provides a dedicated ordered-set aggregate function:

**(b) `PERCENTILE_CONT` [PostgreSQL] — exact median, computed with linear interpolation:**

```sql
WITH current_salary AS (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
)
SELECT d.department_name,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cs.base_salary) AS median_base_salary
FROM employees e
JOIN current_salary cs ON cs.employee_id = e.employee_id AND cs.rn = 1
JOIN departments d ON d.department_id = e.department_id
GROUP BY d.department_name
ORDER BY d.department_name;
```

**Expected output (hand-verified against the sorted salary lists per department):**

| department_name | median_base_salary |
|---|---|
| Engineering | 140000 |
| Finance | 190000 |
| HR | 170000 |
| Marketing | 167500 |
| Sales | 110000 |

And, company-wide (dropping the `GROUP BY`, over all 16 current salaries: sorted, the middle two values are `130000` and `140000`):

```sql
SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cs.base_salary) AS company_median_salary
FROM ( /* same current_salary CTE joined to employees, as above */ ) cs;
```

**Expected result:** `135000` — the average of the 8th and 9th values (`130000` and `140000`) in the sorted list of 16 current salaries, exactly matching `PERCENTILE_CONT`'s documented linear-interpolation definition for an even-sized dataset.

> **Important Note [PostgreSQL] [dialect availability]:** `PERCENTILE_CONT`/`PERCENTILE_DISC` are **ordered-set aggregate functions**, invoked with the special `WITHIN GROUP (ORDER BY ...)` syntax rather than a normal argument list. **PostgreSQL does not support using them with an `OVER()` clause** — they can only be used as regular (`GROUP BY`-style) aggregates, which is exactly why this solution groups by department rather than partitioning per-row. **[MySQL]** has no built-in `PERCENTILE_CONT` (must be approximated manually, e.g. via `NTILE` combined with `AVG` of the boundary rows, or via a user-defined aggregate in 8.0+). **[SQL Server]** supports `PERCENTILE_CONT` but, notably, *only* as a window function requiring `OVER (PARTITION BY ...)` with an **empty** parentheses `OVER()` — it cannot be combined with `GROUP BY` the way PostgreSQL's aggregate form can; SQL Server also offers `PERCENTILE_DISC`. **[Oracle]** supports both the aggregate `WITHIN GROUP` form (like PostgreSQL) and a windowed form via `OVER (PARTITION BY ...)`. Always check your specific engine's syntax before assuming portability — this is one of the least portable areas of window/aggregate functions across dialects.

</details>

### Challenge 5 — Longest consecutive `PRESENT` streak per employee, then ranked

**Problem:** Using the extended illustrative attendance dataset from §10.14, find each employee's *longest* consecutive-`PRESENT` streak (not just every streak), and then rank employees by that longest streak length using `RANK()`.

<details>
<summary>Worked solution</summary>

```sql
WITH ext_attendance(employee_id, work_date, status) AS (
    VALUES
        (3,'2024-01-01','PRESENT'), (3,'2024-01-02','PRESENT'), (3,'2024-01-03','PRESENT'),
        (3,'2024-01-04','ABSENT'),  (3,'2024-01-05','PRESENT'), (3,'2024-01-08','PRESENT'),
        (3,'2024-01-09','PRESENT'), (3,'2024-01-10','LATE'),
        (4,'2024-01-01','PRESENT'), (4,'2024-01-02','ABSENT'),  (4,'2024-01-03','PRESENT'),
        (4,'2024-01-04','PRESENT'), (4,'2024-01-05','PRESENT'), (4,'2024-01-08','PRESENT'),
        (4,'2024-01-09','ABSENT'),  (4,'2024-01-10','PRESENT'),
        (6,'2024-01-01','PRESENT'), (6,'2024-01-02','PRESENT'), (6,'2024-01-03','PRESENT'),
        (6,'2024-01-04','PRESENT'), (6,'2024-01-05','PRESENT'), (6,'2024-01-08','ABSENT'),
        (6,'2024-01-09','PRESENT'), (6,'2024-01-10','PRESENT')
),
present_only AS (
    SELECT employee_id, work_date,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY work_date) AS rn
    FROM ext_attendance
    WHERE status = 'PRESENT'
),
streaks AS (
    SELECT employee_id, COUNT(*) AS streak_len
    FROM present_only
    GROUP BY employee_id, (work_date - rn)
),
longest AS (
    SELECT employee_id, MAX(streak_len) AS longest_streak
    FROM streaks
    GROUP BY employee_id
)
SELECT employee_id, longest_streak,
       RANK() OVER (ORDER BY longest_streak DESC) AS streak_rank
FROM longest
ORDER BY streak_rank;
```

**Expected output (verified):**

| employee_id | longest_streak | streak_rank |
|---|---|---|
| 6 | 5 | 1 |
| 3 | 3 | 2 |
| 4 | 3 | **2** |

This combines the gaps-and-islands technique (§10.14, producing `streaks`), a nested aggregation (`MAX` per employee, producing `longest`), and a ranking function (`RANK()`, producing `streak_rank`) — three separate window/aggregate techniques from this chapter chained together. Note the real tie at rank 2: both employee 3 and employee 4 top out at a 3-day streak, and `RANK()` correctly reflects that shared position rather than arbitrarily picking a "winner."

</details>

### Challenge 6 — Largest salary increase per employee, ranked, using `FIRST_VALUE`/`LAST_VALUE`

**Problem:** For every employee with more than one salary record, compute the difference between their most recent and their original `base_salary`, then rank employees by the size of that increase.

<details>
<summary>Worked solution</summary>

```sql
WITH salary_bounds AS (
    SELECT DISTINCT employee_id,
           FIRST_VALUE(base_salary) OVER (
               PARTITION BY employee_id ORDER BY effective_date
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
           ) AS first_salary,
           LAST_VALUE(base_salary) OVER (
               PARTITION BY employee_id ORDER BY effective_date
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
           ) AS last_salary
    FROM salaries
)
SELECT e.first_name || ' ' || e.last_name AS employee_name,
       sb.first_salary, sb.last_salary,
       (sb.last_salary - sb.first_salary) AS raise_amount,
       RANK() OVER (ORDER BY (sb.last_salary - sb.first_salary) DESC) AS raise_rank
FROM salary_bounds sb
JOIN employees e ON e.employee_id = sb.employee_id
WHERE sb.last_salary > sb.first_salary
ORDER BY raise_rank;
```

**Expected output (verified — only employees with more than one salary row, and a genuine increase, appear):**

| employee_name | first_salary | last_salary | raise_amount | raise_rank |
|---|---|---|---|---|
| Aditi Rao | 450000 | 520000 | 70000 | 1 |
| Rahul Mehta | 280000 | 320000 | 40000 | 2 |
| Priya Nair | 260000 | 300000 | 40000 | **2** |
| Sneha Kulkarni | 180000 | 210000 | 30000 | 4 |
| Vikram Joshi | 120000 | 140000 | 20000 | 5 |

Note the **explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame on both `FIRST_VALUE` and `LAST_VALUE`** — this is the §10.6 fix applied without hesitation, because by now you know the default frame would have made `LAST_VALUE` return each row's own value rather than the true final salary. Also note the real tie at rank 2 (Rahul Mehta and Priya Nair both received exactly a `40000` raise) — `RANK()` correctly shares the position and skips rank `3`, landing Sneha Kulkarni at `4`, exactly per the mechanics established in §10.3.

</details>

---

## Key Takeaways

- A window function computes an aggregate-like value **per row** while preserving every original row — this is the fundamental capability `GROUP BY` cannot offer, because `GROUP BY` permanently collapses rows into one per group.
- `OVER(...)` has three components: `PARTITION BY` (which rows are "related" to this one, without collapsing them), `ORDER BY` (sequence, and — critically — a trigger that changes the default frame), and the **frame clause** (`ROWS`/`RANGE`/`GROUPS BETWEEN ... AND ...`), which defines exactly which rows within the partition are visible to the function for each specific row.
- The default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` **when `ORDER BY` is present**, and the whole partition **when it is not**. This single asymmetric rule is the direct cause of the `LAST_VALUE` gotcha and the `RANGE`-with-ties running-total surprise — both fully demonstrated with real, verified seed data in this chapter (§10.6, §10.9).
- `ROWS` counts physical rows; `RANGE` treats tied `ORDER BY` values as one indivisible peer group; `GROUPS` **[PostgreSQL 11+]** counts by distinct peer-group offsets. Real ties in the `salaries` seed data (`2021-01-01` and `2022-01-01`) let us verify all three behave differently on the exact same rows.
- `ROW_NUMBER`, `RANK`, and `DENSE_RANK` differ **only** in tie-handling: `ROW_NUMBER` ignores ties entirely, `RANK` shares a rank and then skips ahead, `DENSE_RANK` shares a rank and never skips.
- `LAG`/`LEAD` compare a row to a neighboring row without a self-join; `FIRST_VALUE`/`LAST_VALUE` anchor every row in a window to a fixed reference row — but `LAST_VALUE` requires an explicit frame extending to `UNBOUNDED FOLLOWING`, or it will almost always just return the current row.
- Window functions are evaluated in logical query order **after** `WHERE`/`GROUP BY`/`HAVING` but **before** `SELECT DISTINCT`/`ORDER BY`/`LIMIT` — this is precisely why they cannot be filtered directly in `WHERE`, and why the Top-N-per-group pattern always requires wrapping the window function in a CTE or subquery.
- Computing most window functions requires the engine to sort rows within each partition — real, non-free work that we will learn to read in `EXPLAIN ANALYZE` output (`WindowAgg` + `Sort` nodes) in Chapter 17, and optimize in Chapter 18.
- The four required worked patterns — running totals, moving averages, percentage of total, and ranking within groups — are all variations on the same core technique: an aggregate or ranking function with a carefully chosen `PARTITION BY`/`ORDER BY`/frame combination, applied without collapsing rows.
- Gaps-and-islands (finding consecutive runs) is solved with the classic technique: filter to the status of interest, take `ROW_NUMBER()` over the filtered rows ordered by date, then subtract — rows in the same unbroken run share the same `date − row_number` key.
- **[MySQL]** added window function support only in **version 8.0** (2018) — earlier MySQL versions cannot run any query in this chapter at all and must fall back to self-joins or correlated subqueries. Always confirm your MySQL version before assuming window-function syntax is available.

## What's Next

Every query in this chapter has been a `SELECT` — read-only analysis over data that was simply *there*. **Chapter 11 — Transactions & ACID** shifts to the other half of SQL: what happens when multiple statements need to succeed or fail *together* (a bank transfer that must both debit one account and credit another, or nothing at all), how the database guarantees Atomicity, Consistency, Isolation, and Durability, and how `COMMIT`/`ROLLBACK`/`SAVEPOINT` give you explicit control over that guarantee. You'll see the `SUM() OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` running-balance pattern from this chapter's real-world use cases (§10.19) again almost immediately — this time computed over `banking_db`'s actual transaction ledger, with the added twist of needing to be correct even while concurrent transactions are being written to that same ledger.
