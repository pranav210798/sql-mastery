# Chapter 6 — Aggregate Functions, GROUP BY, HAVING

> **Part of:** Part II — SQL Fundamentals
> **Database used:** `company_db` (departments, employees, managers, salaries, attendance, projects, employee_projects)
> **Prerequisites:** Chapter 3 (CRUD/SELECT), Chapter 4 (Sorting & Pagination), Chapter 5 (Built-in Functions, NULL handling)
> **Sets up:** Chapter 7 (JOINs), Chapter 9 (CTEs), Chapter 10 (Window Functions)

---

## 6.0 Why This Chapter Matters

Every query you've written so far in this course answers a question about **individual rows**: "show me this employee," "sort these projects," "format this date." Real business questions rarely stop there. Nobody asks "what is Vikram Joshi's salary?" in a boardroom — they ask **"what is the average salary in Engineering?"**, **"how many employees are on leave right now?"**, **"which department has the highest total project budget?"**

Those questions require collapsing many rows into a single summary value, or into one summary value per group. That is exactly what **aggregate functions** and **`GROUP BY`** do. This is the chapter where SQL stops being a row-fetching tool and starts being a **reporting engine** — the foundation for every dashboard, KPI tile, and analytics query you will ever write.

Before you run anything in this chapter, make sure `company_db` is loaded:

```bash
psql -f databases/company_db.sql
```

All expected outputs below are computed against the exact seed data in that file, using PostgreSQL semantics (the primary dialect of this course).

---

## 6.1 Aggregate Functions — The Big Picture

### 1. Simple explanation

An **aggregate function** takes a *pile* of values (many rows) and boils them down into a *single* value. `COUNT` counts them. `SUM` adds them. `AVG` averages them. `MIN` and `MAX` find the smallest and largest. Think of an aggregate function as a calculator that eats a whole column and spits out one number.

### 2. Technical explanation

Formally, an aggregate function is a **set function**: it operates over a *multiset* of values produced by the rows currently "in scope" (either the whole result set, or one group at a time when `GROUP BY` is present) and returns a single scalar value. Aggregate functions are evaluated **after** row-level filtering (`WHERE`) and **after** rows have been partitioned into groups (`GROUP BY`), which is why they can appear in `SELECT`, `HAVING`, and `ORDER BY`, but never in `WHERE` directly (more on this in §6.4).

### 3. Why it exists / problem solved

Without aggregate functions, answering "how many employees do we have?" would require pulling every row back to the application and counting them in code — wasteful, slow, and impossible to scale to millions of rows. Aggregate functions push the summarization work down to the database engine, which can compute it far more efficiently (often without materializing every row) and return just the number(s) you need.

### 4. The five core aggregate functions

| Function | Purpose | Input | Ignores NULL? |
|---|---|---|---|
| `COUNT(*)` | Counts rows | any row | No — counts rows regardless of column content |
| `COUNT(column)` | Counts non-NULL values in a column | one column | **Yes** |
| `COUNT(DISTINCT column)` | Counts distinct non-NULL values | one column | Yes |
| `SUM(column)` | Adds numeric values | numeric column | Yes |
| `AVG(column)` | Arithmetic mean | numeric column | Yes |
| `MIN(column)` | Smallest value | any comparable column | Yes |
| `MAX(column)` | Largest value | any comparable column | Yes |

> **Important Note:** Every aggregate function in the table above — except `COUNT(*)` — **ignores NULL values** when computing its result. This single rule explains almost every "why is my average wrong" bug beginners hit. We'll dissect it precisely in §6.2 and §6.8.

### 5–7. `COUNT` — examples, output, and clause-order tracing

**5a. Simplest case — total headcount**

```sql
SELECT COUNT(*) AS total_employees
FROM employees;
```

**Expected output:**

| total_employees |
|---|
| 16 |

Line-by-line: `FROM employees` produces all 16 rows → no `WHERE` to filter → no `GROUP BY`, so the *entire result set* is treated as one implicit group → `COUNT(*)` counts every row in that group, regardless of NULLs in any column → `SELECT` returns the single summary row.

**5b. `COUNT(*)` vs `COUNT(column)` — the NULL-skipping distinction, with real data**

Look at `employees.manager_id`. It is nullable — Aditi Rao (`employee_id = 1`, the CTO) has `manager_id = NULL` because she reports to no one.

```sql
SELECT
    COUNT(*)          AS total_rows,
    COUNT(manager_id)  AS employees_with_a_manager
FROM employees;
```

**Expected output:**

| total_rows | employees_with_a_manager |
|---|---|
| 16 | 15 |

`COUNT(*)` counted all 16 rows. `COUNT(manager_id)` counted only rows where `manager_id IS NOT NULL` — 15 of them, because Aditi's row is skipped. This is the **precise mechanic**: `COUNT(column)` evaluates `column` for every row in the group and increments its counter only when the value is **not NULL**. It never errors, never substitutes zero — it simply doesn't count that row.

**5c. `COUNT(DISTINCT column)`**

```sql
SELECT
    COUNT(department_id)          AS total_employee_rows,
    COUNT(DISTINCT department_id) AS distinct_departments_used,
    COUNT(DISTINCT job_title)     AS distinct_job_titles
FROM employees;
```

**Expected output:**

| total_employee_rows | distinct_departments_used | distinct_job_titles |
|---|---|---|
| 16 | 5 | 13 |

`COUNT(DISTINCT department_id)` first de-duplicates the non-NULL `department_id` values (1,2,3,4,5 each appear multiple times, but collapse to 5 unique values), then counts what's left. `COUNT(DISTINCT job_title)` shows 13 distinct titles across 16 employees: exactly two titles are shared by more than one person — `Software Engineer` (Vikram, Ananya, and Aman — 3 employees) and `Sales Executive` (Arjun and Meera — 2 employees) — while the remaining 11 employees each hold a unique title. That accounts for the gap: 16 employees − 2 "extra" duplicates from Software Engineer − 1 "extra" duplicate from Sales Executive = 13 distinct titles.

**8. What happens internally.** Conceptually, `COUNT(DISTINCT x)` requires the engine to build a temporary set (often a hash set or a sort+dedupe pass) of the values seen so far, check membership before incrementing, and only increment on a value it has never seen in this group. This makes `COUNT(DISTINCT ...)` inherently more expensive than plain `COUNT`, because it needs extra memory/CPU to track uniqueness, not just a running tally.

### 6.1.1 `SUM` and `AVG`

**Simple explanation:** `SUM` adds up a column's values; `AVG` computes their arithmetic mean.

**Technical explanation:** `SUM(numeric_column)` returns `NULL` (not `0`) if every input value is `NULL` or if there are zero rows in the group; otherwise it returns the total of the non-NULL values. `AVG(numeric_column)` is computed as `SUM(non-NULL values) / COUNT(non-NULL values)` — critically, the denominator is the count of **non-NULL** values, not the count of all rows in the group. This distinction matters enormously and is covered in depth in §6.8.

**Example — average and total base salary across the whole company:**

```sql
SELECT
    COUNT(*)               AS salary_rows,
    SUM(base_salary)       AS total_base_salary,
    ROUND(AVG(base_salary), 2) AS avg_base_salary,
    MIN(base_salary)       AS min_base_salary,
    MAX(base_salary)       AS max_base_salary
FROM salaries;
```

**Expected output:**

| salary_rows | total_base_salary | avg_base_salary | min_base_salary | max_base_salary |
|---|---|---|---|---|
| 21 | 4335000.00 | 206428.57 | 80000.00 | 520000.00 |

> **⚠️ Warning:** `salaries` stores **salary history** — five employees (`employee_id` 1, 2, 3, 4, and 7) have two rows each because they received a raise, while the other eleven employees have exactly one row. That's `(5 × 2) + (11 × 1) = 21` salary records for only 16 employees. `COUNT(*)` here returns 21 *salary records*, not 16 *employees*. This is a preview of a very common real-world bug: aggregating across a history/log table double-counts entities that appear more than once. Keep this in mind — we revisit it in §6.9 (Common Mistakes) and solve it properly with window functions in Chapter 10.

### 6.1.2 `MIN` and `MAX`

**Simple explanation:** `MIN` finds the smallest value in a column; `MAX` finds the largest.

**Technical explanation:** `MIN`/`MAX` work on any data type that supports ordering comparisons — numbers, dates, times, and even text (lexicographic order). Like every other aggregate except `COUNT(*)`, they ignore `NULL`.

**Example — hire-date range of the company:**

```sql
SELECT
    MIN(hire_date) AS earliest_hire,
    MAX(hire_date) AS latest_hire
FROM employees;
```

**Expected output:**

| earliest_hire | latest_hire |
|---|---|
| 2015-03-01 | 2022-01-10 |

Aditi Rao (CTO) was the earliest hire (2015-03-01); Aman Chawla (Software Engineer) was the most recent (2022-01-10).

---

## 6.2 `GROUP BY` — Turning "One Number" into "One Number Per Category"

### 1. Simple explanation

`GROUP BY` sorts rows into buckets based on the value(s) of one or more columns, and then runs your aggregate functions **separately for each bucket** instead of once for the whole table.

### 2. Technical explanation

`GROUP BY column_list` partitions the rows produced by `FROM`/`WHERE` into disjoint groups, where every row in a group shares identical values for every column in `column_list`. Every expression in the `SELECT` list must then be either (a) one of the grouping columns, or (b) an aggregate function applied over the rows of each group. The query returns exactly one output row per distinct group.

### 3. Why it exists

Without `GROUP BY`, `COUNT(*)` can only tell you "16 employees total." The business question is almost always "16 employees, *broken down by what*?" `GROUP BY` is the mechanism that lets a single query answer "one row per department," "one row per manager," "one row per (department, status) pair," etc., instead of requiring a separate hand-written query for every department.

### 4. Full syntax

```sql
SELECT   grouping_column1, grouping_column2, aggregate_function(column), ...
FROM     table_name
[WHERE   row_filter_condition]
GROUP BY grouping_column1, grouping_column2
[HAVING  group_filter_condition]
[ORDER BY ...]
[LIMIT ...];
```

### 5–7. Examples, output, and line-by-line tracing

**Example A — headcount per department**

```sql
SELECT department_id, COUNT(*) AS headcount
FROM employees
GROUP BY department_id
ORDER BY department_id;
```

**Expected output:**

| department_id | headcount |
|---|---|
| 1 | 7 |
| 2 | 3 |
| 3 | 2 |
| 4 | 2 |
| 5 | 2 |

Line-by-line clause tracing:
1. `FROM employees` — 16 rows enter the pipeline.
2. No `WHERE` — all 16 survive.
3. `GROUP BY department_id` — rows are bucketed: `{1,2,3,4,5,6,16}` → dept 1, `{7,8,9}` → dept 2, `{10,11}` → dept 3, `{12,13}` → dept 4, `{14,15}` → dept 5.
4. `SELECT department_id, COUNT(*)` — for each bucket, emit the grouping key and the row count of that bucket.
5. `ORDER BY department_id` — sort the 5 resulting rows.

**Example B — average salary per department (join across salaries, employees, departments)**

```sql
SELECT
    d.department_id,
    d.department_name,
    COUNT(*)                       AS salary_rows,
    COUNT(DISTINCT s.employee_id)  AS employees_with_salary,
    ROUND(AVG(s.base_salary), 2)   AS avg_base_salary,
    MIN(s.base_salary)             AS min_base_salary,
    MAX(s.base_salary)             AS max_base_salary
FROM departments d
JOIN employees e ON e.department_id = d.department_id
JOIN salaries  s ON s.employee_id  = e.employee_id
GROUP BY d.department_id, d.department_name
ORDER BY avg_base_salary DESC;
```

**Expected output:**

| department_id | department_name | salary_rows | employees_with_salary | avg_base_salary | min_base_salary | max_base_salary |
|---|---|---|---|---|---|---|
| 1 | Engineering | 11 | 7 | 228636.36 | 80000.00 | 520000.00 |
| 2 | Sales | 4 | 3 | 191250.00 | 95000.00 | 300000.00 |
| 4 | Finance | 2 | 2 | 190000.00 | 130000.00 | 250000.00 |
| 3 | HR | 2 | 2 | 170000.00 | 100000.00 | 240000.00 |
| 5 | Marketing | 2 | 2 | 167500.00 | 105000.00 | 230000.00 |

> **⚠️ Warning — this is Chapter 6's most important pitfall to internalize.** Notice `salary_rows` (11) ≠ `employees_with_salary` (7) for Engineering. Joining `employees` to `salaries` multiplies rows for anyone with more than one salary record — in Engineering, Aditi, Rahul, Sneha, and Vikram (`employee_id` 1, 2, 3, 4) each have two rows: an original and a raise, which is why 7 Engineering employees produce 11 joined salary rows instead of 7. `COUNT(*)` counts *joined rows*, `COUNT(DISTINCT s.employee_id)` counts *distinct people*. `AVG(s.base_salary)` here is technically an average **over all historical salary records**, which over-weights employees who've had more raises. A fully correct "current salary per employee" average requires picking only the *latest* `effective_date` per employee — that needs a subquery or window function (`ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC)`), which we cover properly in Chapters 8 and 10. For now, the teaching point is: **`GROUP BY` runs on whatever rows the `FROM`/`JOIN` produced — if a join fans out rows, your aggregates fan out with it.**

Line-by-line clause tracing for Example B:
1. `FROM departments d` — start with 5 department rows.
2. `JOIN employees e ON e.department_id = d.department_id` — expands to 16 rows (one per employee, department repeated).
3. `JOIN salaries s ON s.employee_id = e.employee_id` — expands further to 21 rows (salary history fan-out).
4. No `WHERE` — nothing filtered.
5. `GROUP BY d.department_id, d.department_name` — the 20 rows collapse into 5 buckets, one per department.
6. Aggregate functions (`COUNT`, `COUNT DISTINCT`, `AVG`, `MIN`, `MAX`) are computed once per bucket.
7. `SELECT` projects the grouping columns plus the computed aggregates.
8. `ORDER BY avg_base_salary DESC` sorts the 5 output rows highest-average-first.

**Example C — employees per manager**

```sql
SELECT manager_id, COUNT(*) AS direct_reports
FROM employees
GROUP BY manager_id
ORDER BY manager_id NULLS FIRST;
```

**Expected output:**

| manager_id | direct_reports |
|---|---|
| NULL | 1 |
| 1 | 5 |
| 2 | 4 |
| 3 | 1 |
| 7 | 2 |
| 10 | 1 |
| 12 | 1 |
| 14 | 1 |

The `NULL` row is Aditi Rao herself (`employee_id = 1`), who has no manager — a `NULL` group, discussed formally in §6.8. `manager_id = 1` (5 reports) is Aditi's direct reports: Rahul, Priya, Rohan, Nikhil, and Rajesh — the five people who report straight to the CTO. `manager_id = 2` (4 reports) is Rahul Mehta's team: Sneha, Vikram, Ananya, and Aman.

> **Important Note [PostgreSQL] [Oracle]:** `ORDER BY column NULLS FIRST/LAST` is a PostgreSQL and Oracle extension. **[MySQL]** and **[SQL Server]** don't support this syntax directly; MySQL commonly uses `ORDER BY column IS NULL DESC, column` and SQL Server uses `ORDER BY CASE WHEN column IS NULL THEN 0 ELSE 1 END, column` to achieve the same placement. (Full detail was covered in Chapter 4.)

### 8. What happens internally (conceptual preview)

To execute a `GROUP BY`, the engine needs some way to bring identical group keys together so it can maintain one running aggregate state per key. There are two broad strategies:

- **Hash-based grouping (`HashAggregate`):** build an in-memory hash table keyed by the grouping columns; for each incoming row, hash the group key, look up (or create) its bucket, and update that bucket's running `COUNT`/`SUM`/`MIN`/`MAX` state. Fast when the number of distinct groups is small enough to fit in memory; no sorting required.
- **Sort-based grouping (`GroupAggregate`):** first sort the rows by the grouping columns (or exploit an existing sorted index), so identical keys become physically adjacent; then stream through once, closing out and emitting one group's aggregate as soon as the key changes. Useful when the data is already sorted (e.g., via an index) or when there are too many distinct groups to hash comfortably in memory.

You don't need to choose between these explicitly — the query planner picks one based on data size, available memory, and indexes. `EXPLAIN` will show you which strategy PostgreSQL chose (`HashAggregate` vs `GroupAggregate`). We do a full deep dive into reading these plans in **Chapter 17 — Query Execution & the Query Planner**. For now, the conceptual model to keep is simple: **rows get bucketed by group key, then each aggregate function is computed incrementally per bucket** — regardless of which physical strategy the engine picks, the logical result is identical.

---

## 6.3 The Logical Order of Query Execution

This is the single most important mental model in this chapter — and arguably in beginner SQL overall. SQL is **declarative**: you write clauses in one order (`SELECT ... FROM ... WHERE ... GROUP BY ... HAVING ... ORDER BY ... LIMIT`), but the engine **evaluates** them in a *different*, fixed logical order. Nearly every "why can't I use my alias here" or "why is this column not allowed" confusion traces back to not knowing this order.

### The logical order of execution

```
 ┌─────────────┐
 │  1. FROM    │   Identify the source table(s) — including JOINs
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │  2. WHERE   │   Filter individual rows (no aggregates allowed here yet —
 └──────┬──────┘   aggregates don't exist until grouping happens)
        ▼
 ┌─────────────┐
 │ 3. GROUP BY │   Bucket the surviving rows into groups by key
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │ 4. HAVING   │   Filter entire GROUPS, using aggregate results
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │ 5. SELECT   │   Compute the output columns/expressions (incl. aliases)
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │ 6. ORDER BY │   Sort the final rows (can reference SELECT aliases here)
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │  7. LIMIT   │   Trim to the requested number of rows
 └─────────────┘
```

**Written order you type:** `SELECT → FROM → WHERE → GROUP BY → HAVING → ORDER BY → LIMIT`
**Logical order the engine evaluates:** `FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY → LIMIT`

### Why this mismatch exists

SQL's written syntax was designed to read like an English sentence ("select these columns from this table where..."), for human readability. But the engine cannot compute `SELECT` first — it doesn't know what rows exist to select from until `FROM` has run, doesn't know which rows survive until `WHERE` has run, and (critically for this chapter) **cannot compute an aggregate value until it knows which rows belong to which group**, which requires `GROUP BY` to have already happened. This is precisely why aggregate functions cannot be referenced in `WHERE` — logically, `WHERE` runs *before* grouping and aggregation even exist yet — but they *can* be referenced in `HAVING`, which runs *after*.

### Worked trace of a full query

```sql
SELECT department_id, COUNT(*) AS headcount, AVG(base_salary) AS avg_pay
FROM employees e
JOIN salaries s ON s.employee_id = e.employee_id
WHERE e.status = 'ACTIVE'
GROUP BY department_id
HAVING COUNT(*) > 5
ORDER BY avg_pay DESC
LIMIT 3;
```

1. **FROM** — join `employees` to `salaries`, producing the combined row set.
2. **WHERE** — keep only rows where `status = 'ACTIVE'`; TERMINATED and ON_LEAVE rows are discarded *before* anything is counted or averaged.
3. **GROUP BY** — bucket the surviving rows by `department_id`.
4. **HAVING** — discard entire buckets whose `COUNT(*)` is not greater than 5 (note: this `COUNT(*)` is now counting only the ACTIVE rows that survived step 2, within each bucket).
5. **SELECT** — compute `department_id`, `COUNT(*)`, and `AVG(base_salary)` for each surviving bucket, and assign the aliases `headcount` and `avg_pay`.
6. **ORDER BY** — sort the surviving groups by `avg_pay` descending. (Note: `ORDER BY` runs *after* `SELECT`, which is exactly why it's legal to reference the alias `avg_pay` here — it didn't exist until step 5.)
7. **LIMIT** — keep only the top 3 rows.

> **Important Note:** Because `SELECT` (step 5) happens *after* `WHERE` and `GROUP BY` (steps 2–3), you cannot reference a `SELECT`-defined alias inside `WHERE` or `GROUP BY` in most dialects — those clauses run before the alias exists. **[PostgreSQL] [MySQL]** both allow referencing a `SELECT` alias in `GROUP BY` and `ORDER BY` as a convenience (not standard SQL, but supported), while `HAVING` in MySQL/PostgreSQL can also reference `SELECT` aliases. **[SQL Server] [Oracle]** are stricter about alias reuse in `GROUP BY`/`HAVING`. When in doubt, repeat the full expression rather than relying on alias reuse — it's portable across every dialect.

---

## 6.4 `WHERE` vs `HAVING`

### 1. Simple explanation

`WHERE` throws out individual rows *before* grouping happens. `HAVING` throws out entire *groups* *after* grouping and aggregation have already happened.

### 2. Technical explanation

`WHERE` operates on the row-level data produced by `FROM`, evaluating its condition once per input row, with no knowledge of groups or aggregates (because none exist yet at that stage of logical execution). `HAVING` operates on the *already-formed groups*, evaluating its condition once per group, and its condition is typically expressed in terms of aggregate function results (`COUNT(*) > 2`, `AVG(salary) > 200000`, etc.), though it may also reference grouping columns directly.

### 3. Why `HAVING` exists as a separate clause

This is the crux of the whole chapter, so let's be explicit: **`WHERE` is evaluated before `GROUP BY` in the logical order (§6.3), which means at the point `WHERE` runs, aggregate values like `COUNT(*)` or `AVG(salary)` don't exist yet** — there are no groups yet to aggregate over. If SQL let you write `WHERE COUNT(*) > 2`, the engine would have to answer "count of what, exactly?" before any grouping has occurred — a logical contradiction. `HAVING` was introduced specifically to give you a filter clause that runs *after* grouping/aggregation, where aggregate expressions are well-defined and meaningful.

Try to break this rule and see the error:

```sql
-- ❌ ILLEGAL — aggregate function in WHERE
SELECT department_id, COUNT(*) AS headcount
FROM employees
WHERE COUNT(*) > 2
GROUP BY department_id;
```

**[PostgreSQL]** raises: `ERROR: aggregate functions are not allowed in WHERE`. **[MySQL]** raises a nearly identical error (`Invalid use of group function`). **[SQL Server]** raises `Msg 147: An aggregate may not appear in the WHERE clause`. **[Oracle]** raises `ORA-00934: group function is not allowed here`. Every mainstream dialect rejects this — this is standard SQL behavior, not a dialect quirk.

### 4. Full syntax

```sql
SELECT   grouping_column, aggregate_function(column)
FROM     table_name
WHERE    row_level_condition        -- filters BEFORE grouping, no aggregates allowed
GROUP BY grouping_column
HAVING   group_level_condition;     -- filters AFTER grouping, aggregates allowed
```

### 5–7. Examples

**Example — departments with more than 2 ACTIVE employees**

```sql
SELECT department_id, COUNT(*) AS active_headcount
FROM employees
WHERE status = 'ACTIVE'
GROUP BY department_id
HAVING COUNT(*) > 2
ORDER BY department_id;
```

**Expected output:**

| department_id | active_headcount |
|---|---|
| 1 | 6 |

Trace: `WHERE status = 'ACTIVE'` removes Ananya (ON_LEAVE) and Meera (TERMINATED) *before* anything is grouped, leaving 14 rows. `GROUP BY department_id` buckets those 14 rows: dept 1→6, dept 2→2, dept 3→2, dept 4→2, dept 5→2. `HAVING COUNT(*) > 2` then discards every bucket whose count is 2 or fewer, leaving only Engineering (6). Note that department 2 (Sales) has an active headcount of 2 here — not 3 — precisely *because* the `WHERE` clause already removed Meera before grouping ever happened. This ordering is the whole point: **if you filtered `status = 'ACTIVE'` in a `HAVING` clause instead, you'd first group *all* 16 employees (including TERMINATED/ON_LEAVE) and then have no way to express "only count the ACTIVE ones" without conditional aggregation** (§6.6).

**Example — departments with total project budget over ₹1,000,000**

```sql
SELECT
    d.department_name,
    COUNT(p.project_id) AS project_count,
    SUM(p.budget)        AS total_budget
FROM departments d
JOIN projects p ON p.department_id = d.department_id
GROUP BY d.department_id, d.department_name
HAVING SUM(p.budget) > 1000000
ORDER BY total_budget DESC;
```

**Expected output:**

| department_name | project_count | total_budget |
|---|---|---|
| Engineering | 2 | 8000000.00 |
| Sales | 1 | 1200000.00 |

HR's Employee Wellness project (₹250,000) and Marketing's Brand Relaunch (₹800,000) both fall below the ₹1,000,000 `HAVING` threshold and are excluded. Finance has zero projects, so it never even forms a group here (a `JOIN`, not a `LEFT JOIN`, is used — Chapter 7 will show how `LEFT JOIN` would let Finance appear with `project_count = 0`).

### 11. When to use `WHERE` vs `HAVING` — decision guide

| Situation | Use |
|---|---|
| Filtering on a raw column value from the base table(s) (`status = 'ACTIVE'`, `hire_date > '2020-01-01'`) | `WHERE` |
| Filtering on the *result of an aggregate function* (`COUNT(*) > 5`, `AVG(salary) > 200000`) | `HAVING` |
| You want the filter applied **before** rows are counted/summed (excluding rows from the aggregate calculation itself) | `WHERE` |
| You want the filter applied **after** aggregation, to decide which groups are worth showing (but still counting all rows within a group) | `HAVING` |
| Performance: you can filter out rows early | `WHERE` (always prefer filtering as early as possible — fewer rows reach `GROUP BY`) |

> **Important Note:** `HAVING` can also filter on a **non-aggregated grouping column** (e.g., `HAVING department_id > 2`) — but if that's *all* you're doing, prefer `WHERE`, since `WHERE` filters rows before the (potentially expensive) grouping step, which is more efficient. Reserve `HAVING` specifically for conditions that genuinely require an aggregate result.

---

## 6.5 Grouping by Multiple Columns

### 1–2. Explanation

You can group by more than one column. Every unique **combination** of the listed columns' values forms its own group — not each column independently.

### 3. Why it exists

Real reports are frequently two-dimensional: "headcount by department **and** status," "sales by region **and** quarter." A single `GROUP BY` column can't express that; you need the Cartesian combination of two (or more) grouping keys, each producing its own bucket.

### 4. Syntax

```sql
SELECT col_a, col_b, aggregate_function(col_c)
FROM   table_name
GROUP BY col_a, col_b;
```

### 5–7. Example — employee count per department, per status

```sql
SELECT department_id, status, COUNT(*) AS employee_count
FROM employees
GROUP BY department_id, status
ORDER BY department_id, status;
```

**Expected output:**

| department_id | status | employee_count |
|---|---|---|
| 1 | ACTIVE | 6 |
| 1 | ON_LEAVE | 1 |
| 2 | ACTIVE | 2 |
| 2 | TERMINATED | 1 |
| 3 | ACTIVE | 2 |
| 4 | ACTIVE | 2 |
| 5 | ACTIVE | 2 |

Trace: `GROUP BY department_id, status` forms one bucket per *distinct pair*. Department 1 splits into two buckets (`ACTIVE`/6 and `ON_LEAVE`/1) because both statuses appear there; department 3, 4, and 5 each have only one status present in the data (`ACTIVE`), so each produces exactly one row.

> **Edge case:** Notice there is **no row** for `(department_id = 1, status = 'TERMINATED')`, or for `(department_id = 3, status = 'ON_LEAVE')`. `GROUP BY` never manufactures a row for a combination that doesn't exist in the underlying data — it only emits groups for combinations **actually present** among the surviving rows. If your report needs to show every department × every possible status (including zero-count combinations), you need a `CROSS JOIN` against a reference list of statuses plus a `LEFT JOIN`/conditional aggregation — a technique covered once we reach Chapter 7 (JOINs) and Chapter 8 (Subqueries).

---

## 6.6 Conditional Aggregation

### 1. Simple explanation

Conditional aggregation lets you compute **several different counts or sums in a single row**, each counting only the rows that match a specific condition — without writing a separate query per condition.

### 2. Technical explanation

The classic pattern wraps a `CASE` expression *inside* an aggregate function: `SUM(CASE WHEN condition THEN 1 ELSE 0 END)` evaluates the `CASE` expression per row (producing `1` or `0`), then sums those per-row results within the group — effectively counting how many rows in the group satisfied `condition`. **[PostgreSQL]** (and the SQL:2003 standard, adopted by few other engines) also offers the more direct `aggregate_function(...) FILTER (WHERE condition)` syntax, which applies the filter condition to restrict *which rows the aggregate considers*, without the `CASE`-to-integer translation step.

### 3. Why it exists / problem solved

Without conditional aggregation, "how many employees are ACTIVE vs ON_LEAVE vs TERMINATED, per department" would require three separate queries (one per status, each with its own `WHERE`) that you'd then have to stitch back together manually. Conditional aggregation collapses this into one query, one pass over the data, one result set — exactly the shape a dashboard or report needs.

### 4. Full syntax

```sql
-- Universally portable (CASE-based)
SELECT
    grouping_column,
    SUM(CASE WHEN condition1 THEN 1 ELSE 0 END) AS count_matching_condition1,
    SUM(CASE WHEN condition2 THEN 1 ELSE 0 END) AS count_matching_condition2
FROM table_name
GROUP BY grouping_column;

-- [PostgreSQL] FILTER clause (SQL:2003 standard, not universally implemented)
SELECT
    grouping_column,
    COUNT(*) FILTER (WHERE condition1) AS count_matching_condition1,
    COUNT(*) FILTER (WHERE condition2) AS count_matching_condition2
FROM table_name
GROUP BY grouping_column;
```

### 5–7. Example — ACTIVE / ON_LEAVE / TERMINATED counts per department

**CASE-based version (portable across PostgreSQL, MySQL, Oracle, SQL Server):**

```sql
SELECT
    d.department_name,
    COUNT(*) AS total_employees,
    SUM(CASE WHEN e.status = 'ACTIVE'     THEN 1 ELSE 0 END) AS active_count,
    SUM(CASE WHEN e.status = 'ON_LEAVE'   THEN 1 ELSE 0 END) AS on_leave_count,
    SUM(CASE WHEN e.status = 'TERMINATED' THEN 1 ELSE 0 END) AS terminated_count
FROM employees e
JOIN departments d ON d.department_id = e.department_id
GROUP BY d.department_id, d.department_name
ORDER BY d.department_name;
```

**[PostgreSQL] `FILTER`-based equivalent:**

```sql
SELECT
    d.department_name,
    COUNT(*) AS total_employees,
    COUNT(*) FILTER (WHERE e.status = 'ACTIVE')     AS active_count,
    COUNT(*) FILTER (WHERE e.status = 'ON_LEAVE')   AS on_leave_count,
    COUNT(*) FILTER (WHERE e.status = 'TERMINATED') AS terminated_count
FROM employees e
JOIN departments d ON d.department_id = e.department_id
GROUP BY d.department_id, d.department_name
ORDER BY d.department_name;
```

**Expected output (identical for both versions):**

| department_name | total_employees | active_count | on_leave_count | terminated_count |
|---|---|---|---|---|
| Engineering | 7 | 6 | 1 | 0 |
| Finance | 2 | 2 | 0 | 0 |
| HR | 2 | 2 | 0 | 0 |
| Marketing | 2 | 2 | 0 | 0 |
| Sales | 3 | 2 | 0 | 1 |

Line-by-line trace (CASE version): `FROM`/`JOIN` produce 16 employee rows joined to their department names → no `WHERE` → `GROUP BY d.department_id, d.department_name` buckets by department → within each bucket, for every row, each `CASE` expression evaluates to `1` or `0` depending on whether that row's `status` matches, and `SUM` adds those 1s/0s up per bucket → `SELECT` emits the department name plus the four aggregate columns → `ORDER BY d.department_name` sorts alphabetically.

> **Dialect notes on `FILTER`:** **[PostgreSQL]** supports `FILTER (WHERE ...)` on any aggregate function since version 9.4. **[MySQL]** has no `FILTER` clause — always use `CASE`/`IF()` (e.g., `SUM(IF(status = 'ACTIVE', 1, 0))` is a common MySQL-specific shorthand). **[SQL Server]** has no `FILTER` clause either — use `CASE`. **[Oracle]** also lacks `FILTER` — use `CASE`, or Oracle's `COUNT(CASE WHEN condition THEN 1 END)` idiom (omitting `ELSE`, which implicitly produces `NULL`, and `COUNT` ignores `NULL`s — an elegant shortcut that works in every dialect, not just Oracle).

> **Important Note:** `COUNT(CASE WHEN condition THEN 1 END)` (no `ELSE`) and `SUM(CASE WHEN condition THEN 1 ELSE 0 END)` produce the **same result**, via two different NULL-handling paths: the first relies on `COUNT` skipping the implicit `NULL` produced when `condition` is false; the second relies on `SUM` adding literal zeros. Both are idiomatic; pick whichever your team's style guide prefers, but `SUM(...ELSE 0 END)` is slightly more explicit for beginners.

---

## 6.7 Attendance Summary Per Employee — A Combined Worked Example

This example threads together `COUNT`, `COUNT(column)`, conditional aggregation, and `MIN`/`MAX` over a column that contains `NULL`s — a perfect bridge into §6.8.

```sql
SELECT
    employee_id,
    COUNT(*)                                              AS days_recorded,
    COUNT(check_in)                                       AS days_with_checkin,
    SUM(CASE WHEN status = 'PRESENT' THEN 1 ELSE 0 END)   AS present_days,
    SUM(CASE WHEN status = 'LATE'    THEN 1 ELSE 0 END)   AS late_days,
    SUM(CASE WHEN status = 'ABSENT'  THEN 1 ELSE 0 END)   AS absent_days,
    SUM(CASE WHEN status = 'REMOTE'  THEN 1 ELSE 0 END)   AS remote_days,
    SUM(CASE WHEN status = 'LEAVE'   THEN 1 ELSE 0 END)   AS leave_days,
    MIN(check_in)                                         AS earliest_check_in,
    MAX(check_in)                                         AS latest_check_in
FROM attendance
GROUP BY employee_id
ORDER BY employee_id;
```

**Expected output:**

| employee_id | days_recorded | days_with_checkin | present_days | late_days | absent_days | remote_days | leave_days | earliest_check_in | latest_check_in |
|---|---|---|---|---|---|---|---|---|---|
| 3 | 3 | 3 | 2 | 1 | 0 | 0 | 0 | 09:00:00 | 10:15:00 |
| 4 | 3 | 2 | 2 | 0 | 1 | 0 | 0 | 09:00:00 | 09:10:00 |
| 5 | 2 | 0 | 0 | 0 | 0 | 0 | 2 | NULL | NULL |
| 6 | 2 | 2 | 1 | 0 | 0 | 1 | 0 | 09:00:00 | 09:20:00 |

Walk through employee 5 (Ananya Singh) carefully, because it's the key edge case for §6.8: both of her attendance rows have `status = 'LEAVE'` and `check_in = NULL`. `days_recorded` (a plain `COUNT(*)`) is `2`, because it counts rows, not values. `days_with_checkin` (`COUNT(check_in)`) is `0`, because both `check_in` values are `NULL` and get skipped. `MIN(check_in)` and `MAX(check_in)` both return `NULL` — **not zero, not an error** — because there is not a single non-NULL value anywhere in the group for that column to compare.

Employee 4 (Vikram Joshi) shows the *partial*-NULL case: one of his three `check_in` values is `NULL` (the day he was `ABSENT`), so `days_with_checkin = 2` and `MIN`/`MAX` are computed only from the two real check-in times (`09:00` and `09:10`) — the `NULL` day contributes nothing to either the count or the comparison.

---

## 6.8 Aggregating Over `NULL` Values — The Precise Rules

This section formalizes what the previous examples already demonstrated. Get this exactly right, because it's the source of more subtle SQL bugs than almost any other single behavior.

### The rule, stated precisely

> **Every aggregate function except `COUNT(*)` first discards `NULL` values from its input, then computes its result over whatever non-NULL values remain.**

Concretely, per-group behavior:

| Function | Some rows NULL, some not | **All** rows in the group are NULL |
|---|---|---|
| `COUNT(*)` | Counts every row (NULLs irrelevant) | Counts every row (NULLs irrelevant) |
| `COUNT(column)` | Counts only non-NULL rows | Returns `0` |
| `SUM(column)` | Sums only non-NULL values | Returns `NULL` (not `0`) |
| `AVG(column)` | `SUM(non-NULL) / COUNT(non-NULL)` — NULLs excluded from **both** | Returns `NULL` |
| `MIN(column)` / `MAX(column)` | Smallest/largest among non-NULL values | Returns `NULL` |

The employee-5 attendance group in §6.7 is a real, verified demonstration of the rightmost column: `COUNT(check_in) = 0`, `MIN(check_in) = NULL`, `MAX(check_in) = NULL` — the group has rows (`COUNT(*) = 2`), but zero non-NULL values in that specific column.

> **⚠️ Warning — the `AVG` trap.** Beginners often assume `AVG(column)` divides by the total row count in the group. It does **not** — it divides by the count of *non-NULL* values. Concretely, if a group has 4 rows and the column being averaged is `NULL` in 1 of them, `AVG` computes `SUM(3 values) / 3`, not `SUM(3 values) / 4`. If you actually want NULLs treated as zero in the average (dividing by the full row count), you must convert them explicitly first — e.g. `AVG(COALESCE(column, 0))` — which changes the semantics from "average of the known values" to "average including missing values as zero." These are different business questions, and choosing the wrong one silently produces a plausible-looking but wrong number. (`COALESCE` was covered in Chapter 5.)

### `SUM`/`AVG` NULL-skipping — illustrative example

None of `company_db`'s numeric columns used for `SUM`/`AVG` in this course (`base_salary`, `bonus`, `budget`) happen to contain `NULL` in the seed data (`bonus` is even declared `NOT NULL DEFAULT 0`). To make the mechanic concrete anyway, consider this small illustrative table (not part of `company_db`, shown purely to demonstrate the rule):

| row | amount |
|---|---|
| 1 | 100 |
| 2 | NULL |
| 3 | 200 |

`SUM(amount)` → `300` (the `NULL` row contributes nothing, as if it weren't there). `AVG(amount)` → `150` (`300 / 2`, **not** `300 / 3`). `COUNT(amount)` → `2`. `COUNT(*)` → `3`. If every row were `NULL`, `SUM` and `AVG` would both return `NULL`, and `COUNT(amount)` would return `0` — the "all-NULL group" row of the table above.

### `GROUP BY` on a nullable column — `NULL` forms its own group

We already saw this with `employees.manager_id` in §6.2, Example C: `manager_id IS NULL` (Aditi Rao) formed its own legitimate group with `direct_reports = 1`, rather than being silently dropped or erroring. This is a formal, standard rule: **for grouping purposes, all `NULL` values in the grouping column(s) are treated as equal to one another** (even though, per three-valued logic, `NULL = NULL` evaluates to `UNKNOWN` everywhere else in SQL — `WHERE x = NULL` never matches). `GROUP BY` makes a deliberate, documented exception to standard NULL comparison semantics specifically so that rows with missing grouping-key data aren't silently discarded — they get their own bucket instead.

---

## 6.9 Common Mistakes

### Mistake 1 — Selecting a non-aggregated, non-grouped column

```sql
-- ❌ Illegal in strict dialects
SELECT department_id, first_name, COUNT(*)
FROM employees
GROUP BY department_id;
```

`first_name` is neither a grouping column nor wrapped in an aggregate function. For a department bucket containing 7 different employees, which `first_name` should the engine return? There is no single correct answer — the expression is **undefined**.

> **[PostgreSQL] [SQL Server] [Oracle]** all reject this at parse time with an explicit error (`ERROR: column "employees.first_name" must appear in the GROUP BY clause or be used in an aggregate function` in PostgreSQL; `ORA-00979: not a group by expression` in Oracle; `Msg 8120` in SQL Server). This is the **standard-compliant, safe** behavior — the query simply won't run.
>
> **[MySQL]** historically shipped with the `ONLY_FULL_GROUP_BY` SQL mode **disabled by default** (before 5.7.5). With it off, MySQL *permits* this query and silently returns **an arbitrary value** of `first_name` from *one unspecified row* in each group — not an error, but a landmine: the result looks plausible, is deterministic-seeming in testing, and can change between MySQL versions, storage engines, or even query plans. Since MySQL 5.7, `ONLY_FULL_GROUP_BY` is **enabled by default**, making MySQL behave like the strict dialects above. **Always verify `ONLY_FULL_GROUP_BY` is enabled** if you work with an older MySQL instance or one with custom server configuration — don't rely on the "it ran and gave me an answer" heuristic as proof of correctness.

The fix is always the same: either add the column to `GROUP BY` (which changes the grouping granularity — now one row per department *and* per first_name), or wrap it in an aggregate (`MIN(first_name)`, `STRING_AGG(first_name, ', ')`, etc.) if you genuinely want a representative/combined value.

### Mistake 2 — Putting an aggregate condition in `WHERE` instead of `HAVING`

Covered fully in §6.4. The symptom is always some flavor of "aggregate functions are not allowed in WHERE." The fix is to move the condition to `HAVING`, which runs after grouping.

### Mistake 3 — Assuming `AVG` divides by total row count, not non-NULL count

Covered fully in §6.8. Symptom: an average that looks suspiciously high when some rows have `NULL` in the averaged column, because the denominator silently shrank.

### Mistake 4 — Forgetting that a `JOIN` can fan out rows before `GROUP BY` sees them

Covered fully in §6.2, Example B. Symptom: `COUNT(*)` after a join returns a bigger number than you expected, because a one-to-many join multiplied rows before aggregation ever ran. Always ask "did my `JOIN` create duplicates for this entity?" before trusting a post-join `COUNT`.

### Mistake 5 — Expecting `GROUP BY` to produce a row for every possible combination

Covered in §6.5. `GROUP BY` only emits groups for combinations that actually exist in the filtered row set — it does not "fill in" zero-count combinations. If your report needs every category represented (including zeros), you need an outer join against a reference table (Chapter 7) or a generated series (later chapters).

---

## 6.10 Edge Cases

### `COUNT(*)` vs `COUNT(1)` vs `COUNT(column)`

```sql
SELECT
    COUNT(*)          AS count_star,
    COUNT(1)           AS count_literal_one,
    COUNT(manager_id)  AS count_manager_id
FROM employees;
```

**Expected output:**

| count_star | count_literal_one | count_manager_id |
|---|---|---|
| 16 | 16 | 15 |

`COUNT(*)` and `COUNT(1)` are functionally identical: `COUNT(1)` evaluates the constant `1` once per row (which is never `NULL`), so it counts every row — exactly like `COUNT(*)`. There is no meaningful performance difference in any modern optimizer (PostgreSQL, MySQL, SQL Server, and Oracle all recognize and optimize both identically). `COUNT(manager_id)`, by contrast, is semantically different — it counts only rows where that specific column is non-NULL, giving `15` instead of `16`. Prefer `COUNT(*)` for "how many rows" — it communicates intent clearly and avoids any ambiguity about which column is being checked for NULL.

### Empty result set — does `COUNT` return `0` or no row at all?

This depends entirely on whether `GROUP BY` is present.

**Without `GROUP BY`** — an aggregate query always returns **exactly one row**, even if zero source rows matched the filter:

```sql
SELECT COUNT(*) AS terminated_in_finance
FROM employees
WHERE status = 'TERMINATED' AND department_id = 4;
```

**Expected output:**

| terminated_in_finance |
|---|
| 0 |

One row, value `0`. There are zero TERMINATED employees in Finance, but `COUNT(*)` over an empty input set is well-defined and equals `0` — it does not return "no rows."

**With `GROUP BY`** — a group key that has zero matching rows simply never appears in the output at all:

```sql
SELECT department_id, COUNT(*) AS terminated_count
FROM employees
WHERE status = 'TERMINATED'
GROUP BY department_id;
```

**Expected output:**

| department_id | terminated_count |
|---|---|
| 2 | 1 |

Only Sales (department 2, Meera Pillai) appears. Engineering, HR, Finance, and Marketing have zero TERMINATED employees each, and **none of them produce a row with `terminated_count = 0`** — they are simply absent from the result set, because `GROUP BY` only forms groups from rows that actually survived `WHERE`.

> **Important Note:** This distinction — "no `GROUP BY` always yields exactly one summary row, even over zero matching rows" vs. "`GROUP BY` yields zero rows for a category with zero matches" — is one of the most common sources of "why did my dashboard silently drop a department" bugs. If a report needs to show every department even when its count is zero, you need a `LEFT JOIN` against the full department list (Chapter 7), not a plain `INNER JOIN` + `GROUP BY`.

---

## 6.11 Comparisons

### `COUNT(*)` vs `COUNT(column)` vs `COUNT(DISTINCT column)`

| | Counts | NULLs | Duplicates |
|---|---|---|---|
| `COUNT(*)` | Every row in the group | Irrelevant — rows count regardless of any column's NULL-ness | Counted (each row counts once, even if identical to another) |
| `COUNT(column)` | Rows where `column IS NOT NULL` | Skipped | Counted (two rows with the same non-NULL value both count) |
| `COUNT(DISTINCT column)` | Distinct non-NULL values of `column` | Skipped | **Not** counted — duplicates collapse to one |

### `GROUP BY` vs `DISTINCT`

```sql
SELECT DISTINCT department_id FROM employees ORDER BY department_id;
```

vs.

```sql
SELECT department_id, COUNT(*) FROM employees GROUP BY department_id ORDER BY department_id;
```

Both return 5 rows (one per unique `department_id`), but they answer different questions. `DISTINCT` only **deduplicates the exact rows of its `SELECT` list** — it has no concept of aggregation and cannot tell you *how many* rows collapsed into each unique value. `GROUP BY` deduplicates the same way *and* lets you compute a per-group summary (`COUNT`, `SUM`, `AVG`, etc.) alongside the deduplicated key. Rule of thumb: reach for `DISTINCT` when you only need the unique values themselves; reach for `GROUP BY` the moment you need any statistic *about* each group (even just `COUNT(*)`).

> **Important Note:** `SELECT DISTINCT department_id, status FROM employees` and `SELECT department_id, status FROM employees GROUP BY department_id, status` (with no aggregate function in the `SELECT` list) return **identical result sets** — `GROUP BY` with no aggregate function present is functionally equivalent to `DISTINCT` on those columns. This is a good conceptual bridge, but don't use `GROUP BY` as a `DISTINCT` substitute in real code — it signals intent poorly and typically costs the same or more to execute.

---

## 6.12 Real-World Use Cases

- **Executive dashboards:** "Total headcount," "Total active projects," "Total budget under management" — nearly every KPI tile on a dashboard is a single aggregate query, often with a `WHERE date >= ...` filter for a rolling time window.
- **Departmental reports:** "Headcount, average tenure, and average salary by department" is the `GROUP BY department_id` pattern from §6.2, wired directly into an HR reporting tool.
- **Status/funnel breakdowns:** "How many orders are Pending / Shipped / Delivered / Cancelled" (or, in `company_db` terms, "how many employees are ACTIVE / ON_LEAVE / TERMINATED per department") is exactly the conditional-aggregation pattern from §6.6 — the backbone of almost every operational dashboard's status-funnel widget.
- **Attendance/utilization tracking:** §6.7's per-employee attendance summary is the same query shape that powers payroll-adjacent "days present/absent/late" reports and project time-utilization dashboards (`SUM(hours_allocated)` per project in `employee_projects`).
- **Budget and finance rollups:** "Total and average project budget per department" (§6.4) is the query shape behind finance rollup reports and budget-vs-actuals tracking.
- **Org-structure analytics:** "Direct reports per manager" (§6.2, Example C) is the query behind span-of-control reports used in org design and headcount planning.

---

## 6.13 Practice Questions

Try each of these against `company_db` before moving on. No answers are provided — verify your own output against the seed data logic explained in this chapter.

1. Write a query that returns the total number of employees, and the number of employees who have a non-NULL `department_id`. (Hint: in the seed data these two numbers will match — explain in a comment *why* they'd differ if some employee had no department, and which `COUNT` variant would reveal it.)
2. For each department, return the number of *distinct job titles* used in that department.
3. For each manager (`manager_id`), return the number of direct reports and the average `base_salary` of those direct reports (join to `salaries`), ordered by average salary descending.
4. Using `employee_projects`, find the total `hours_allocated` per `project_id`, along with the number of distinct employees assigned to each project.
5. Find every department whose average project budget (from `projects`) exceeds ₹1,000,000, using `HAVING`.
6. Write a query that reports, per employee, the number of attendance days recorded and the number of days with a non-NULL `check_out`. Which employee(s) have `check_out` values missing for every recorded day?
7. Rewrite the ACTIVE/ON_LEAVE/TERMINATED conditional-aggregation query from §6.6 using **[PostgreSQL] `FILTER`** instead of `CASE`, but this time break it down `GROUP BY` department **and** job_title.
8. Explain, in your own words, why `SELECT department_id, job_title, COUNT(*) FROM employees GROUP BY department_id` fails in PostgreSQL but might silently "work" on an old MySQL server. What specifically would MySQL be guessing at?
9. Find the single department with the highest **total** salary payroll (`SUM(base_salary)` across the joined `salaries` history) — and separately, the department with the highest **average** payroll. Are they the same department? Why might a business care about the distinction?
10. Using `WHERE` and `HAVING` together, find every manager (`manager_id`) who has more than one direct report that is currently `ACTIVE`.

---

## 6.14 Chapter Challenge

> **Challenge — combine multi-column `GROUP BY`, `HAVING`, and conditional aggregation in one query.**
>
> Using the `employees` table, write a single query that reports, for every **(`department_id`, `job_title`)** combination:
> - `total_employees` — total headcount for that department + job title combination
> - `active_count` — how many of those employees are currently `ACTIVE`
> - `on_leave_count` — how many are `ON_LEAVE`
> - `terminated_count` — how many are `TERMINATED`
>
> Return **only** the (department, job_title) groups that have **more than one employee** *and* have **at least one `ACTIVE`** employee. Order the result by `department_id`.

Try it yourself before reading further.

<details>
<summary>Worked solution (click to expand)</summary>

```sql
SELECT
    department_id,
    job_title,
    COUNT(*)                                                AS total_employees,
    SUM(CASE WHEN status = 'ACTIVE'     THEN 1 ELSE 0 END)  AS active_count,
    SUM(CASE WHEN status = 'ON_LEAVE'   THEN 1 ELSE 0 END)  AS on_leave_count,
    SUM(CASE WHEN status = 'TERMINATED' THEN 1 ELSE 0 END)  AS terminated_count
FROM employees
GROUP BY department_id, job_title
HAVING COUNT(*) > 1
   AND SUM(CASE WHEN status = 'ACTIVE' THEN 1 ELSE 0 END) >= 1
ORDER BY department_id;
```

**Expected output:**

| department_id | job_title | total_employees | active_count | on_leave_count | terminated_count |
|---|---|---|---|---|---|
| 1 | Software Engineer | 3 | 2 | 1 | 0 |
| 2 | Sales Executive | 2 | 1 | 0 | 1 |

Trace: `GROUP BY department_id, job_title` forms one bucket per combination — e.g., `(1, 'Software Engineer')` groups Vikram (ACTIVE), Ananya (ON_LEAVE), and Aman (ACTIVE); `(2, 'Sales Executive')` groups Arjun (ACTIVE) and Meera (TERMINATED). Every other (department, job_title) combination in the seed data has exactly one employee (e.g., `(1, 'CTO')`, `(3, 'HR Manager')`), so `HAVING COUNT(*) > 1` eliminates all of them, leaving only these two multi-employee title groups. Both surviving groups also satisfy `active_count >= 1`, so both remain in the final result.

</details>

---

## Key Takeaways

- Aggregate functions (`COUNT`, `SUM`, `AVG`, `MIN`, `MAX`) collapse many rows into one summary value; every one of them **except `COUNT(*)`** skips `NULL` values when computing that summary.
- `COUNT(*)` counts rows; `COUNT(column)` counts non-NULL values in that column; `COUNT(DISTINCT column)` counts distinct non-NULL values. These three routinely produce three different numbers on the same data — know which one you actually need.
- `GROUP BY` partitions rows into buckets by shared key value(s) and computes aggregates once per bucket; grouping by multiple columns partitions by the *combination* of those columns, and only combinations actually present in the data get a row.
- `WHERE` filters individual rows **before** grouping and cannot reference aggregate results; `HAVING` filters entire groups **after** aggregation and is where aggregate conditions belong. This split exists because, logically, aggregates don't exist yet at the point `WHERE` runs.
- The logical order of execution — `FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY → LIMIT` — governs what's legal where, and differs from the order you type the clauses in. Internalizing this diagram resolves most "why won't my query run" confusion in this chapter and beyond.
- `AVG` divides by the count of non-NULL values, not the total row count — a frequent, silent source of wrong numbers.
- `NULL` forms its own legitimate group under `GROUP BY`, even though `NULL = NULL` is `UNKNOWN` everywhere else in SQL.
- Selecting a column that is neither grouped nor aggregated is illegal and rejected outright in PostgreSQL, SQL Server, and Oracle — but was historically permitted (and dangerous) in MySQL with `ONLY_FULL_GROUP_BY` disabled, silently returning an arbitrary row's value.
- Joining a one-to-many relationship (like `employees` → `salaries` history) before aggregating can fan out row counts and skew `SUM`/`AVG` — always sanity-check `COUNT(*)` against `COUNT(DISTINCT entity_id)` after a join.
- Conditional aggregation (`SUM(CASE WHEN ... THEN 1 ELSE 0 END)`, or `FILTER (WHERE ...)` in PostgreSQL) lets you compute multiple category-specific counts/sums in a single grouped query — the backbone pattern behind most status-breakdown dashboards.

## What's Next

Chapter 6 taught you how to summarize data *within* a single table. But `company_db`'s real power — connecting `employees` to `departments`, `salaries` to `employees`, `projects` to `employee_projects` — has only been hinted at through joins used as supporting plumbing so far. **Chapter 7 — JOINs (Extremely Detailed)** goes there directly: `INNER JOIN`, `LEFT`/`RIGHT`/`FULL OUTER JOIN`, `CROSS JOIN`, self-joins (finally giving every manager a *name*, not just an ID), multi-table joins, and the row-multiplication behavior you were warned about in §6.2 — explained fully, and turned into a tool instead of a trap.

