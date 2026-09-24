# Chapter 3 — CRUD: SELECT, INSERT, UPDATE, DELETE

> **Part II — SQL Fundamentals.** This chapter is the foundation everything else in this book stands on. Roughly 80% of the SQL you will ever write in a real job is some combination of SELECT, INSERT, UPDATE, and DELETE — CRUD (Create, Read, Update, Delete). Chapters 4 through 31 add power tools around this core; they do not replace it.

Every example below runs against `company_db`, exactly as created by `databases/company_db.sql`. If you haven't loaded it yet:

```bash
psql -f databases/company_db.sql
psql -d your_database -c "SET search_path TO company_db;"
```

## 3.0 Before You Begin

### 3.0.1 Schema recap

| Table | Purpose | Key columns |
|---|---|---|
| `departments` | 5 seed rows: Engineering, Sales, HR, Finance, Marketing | `department_id` PK, `department_name` UNIQUE, `location` |
| `employees` | 16 seed rows, self-referencing hierarchy | `employee_id` PK, `department_id` FK, `manager_id` FK → `employees`, `status` CHECK IN ('ACTIVE','ON_LEAVE','TERMINATED') |
| `managers` | 1 row per department, 1:1 with the managing employee | `manager_id` PK/FK → `employees`, `department_id` FK UNIQUE |
| `salaries` | Salary **history** — multiple rows per employee over time | `salary_id` PK, `employee_id` FK, `base_salary` CHECK > 0, `bonus`, `effective_date` |
| `attendance` | Daily check-in/out records, only Jan 2024 for a handful of employees | `employee_id` FK, `work_date`, `status` CHECK, `check_in`, `check_out` |
| `projects` | 5 seed rows | `project_id` PK, `department_id` FK, `start_date`, `end_date` (nullable), `budget` |
| `employee_projects` | Many-to-many bridge, employee ↔ project | composite PK (`employee_id`, `project_id`), `role`, `hours_allocated` |

> **⚠️ Warning — this is the first chapter that mutates data.** Every subsequent chapter (4 onward) assumes `company_db` is in its **original, freshly-loaded state**. Once you start running the `INSERT`/`UPDATE`/`DELETE` examples in this chapter, your data will drift from what later chapters expect.
>
> Pick one of these two habits before you start typing along:
> 1. **Wrap every mutating example in a transaction** and roll it back when you're done experimenting:
>    ```sql
>    BEGIN;
>    -- try the example here
>    ROLLBACK;   -- undoes it, database is back to the seed state
>    ```
> 2. **Reload the seed file** after finishing this chapter's hands-on practice: `psql -f databases/company_db.sql`.
>
> Every expected-output table shown below assumes you are running that example against a **freshly loaded** `company_db` — not a database that has accumulated every earlier example in this chapter. Where an example intentionally builds on a previous one, the text says so explicitly.

---

## 3.1 SELECT — Retrieving Data

**Simple explanation:** `SELECT` asks the database to hand you rows of data. You tell it *what columns* you want and, optionally, *which rows* (via `WHERE`, covered in 3.2).

**Technical explanation:** `SELECT` is a Data Query Language (DQL) statement (some group it under DML). It does not modify data — it reads it, applies any requested transformations (aliasing, expressions, filtering, deduplication), and returns a *result set*, which is itself a table-shaped, transient, read-only structure that exists only for the life of the query (or a cursor over it).

**Why it exists:** Data is useless if you can't get it back out in the shape you need. `SELECT` is the retrieval half of CRUD; without it, `INSERT`, `UPDATE`, and `DELETE` would have no way to be verified or acted upon.

### 3.1.1 SELECT * — All Columns

**Full syntax:**
```sql
SELECT * FROM table_name;
```
`*` means "every column, in the table's defined column order."

**Example:**
```sql
SELECT * FROM departments;
```

**Expected output:**

| department_id | department_name | location | created_at |
|---|---|---|---|
| 1 | Engineering | Pune | *(load timestamp)* |
| 2 | Sales | Mumbai | *(load timestamp)* |
| 3 | HR | Bengaluru | *(load timestamp)* |
| 4 | Finance | Mumbai | *(load timestamp)* |
| 5 | Marketing | Delhi | *(load timestamp)* |

> **Important Note:** `created_at` uses `DEFAULT now()`, so its value depends on the exact moment you ran the seed script — it is the one column in this book whose literal value won't match between two readers. Every other value shown in this chapter is deterministic and reproducible.

**What happens internally:** The planner resolves `*` to the table's actual column list from the system catalog (`pg_attribute` in PostgreSQL) at parse time, then produces a plan — here, a full **sequential scan** of `departments` since there is no `WHERE` clause to use an index against.

**Common mistakes:**
- Using `SELECT *` in production application code — if someone adds a column later, your app may break (column-count mismatch in a positional binding) or silently start doing more work than intended.
- Using `SELECT *` on wide/joined tables and shipping unnecessary columns (e.g., long `TEXT` columns) over the network.

**When to use / not use:** Fine for ad-hoc exploration in a psql/DBeaver session. Avoid in application code, views meant to be stable, and any query embedded in a report or ETL pipeline — name your columns explicitly there.

### 3.1.2 Selecting Specific Columns

**Syntax:**
```sql
SELECT column1, column2, ... FROM table_name;
```

**Example — engineers only their name and title:**
```sql
SELECT first_name, last_name, job_title
FROM employees
WHERE department_id = 1;
```

**Expected output:**

| first_name | last_name | job_title |
|---|---|---|
| Aditi | Rao | CTO |
| Rahul | Mehta | Engineering Manager |
| Sneha | Kulkarni | Senior Engineer |
| Vikram | Joshi | Software Engineer |
| Ananya | Singh | Software Engineer |
| Karan | Verma | Junior Engineer |
| Aman | Chawla | Software Engineer |

**Line-by-line:** `SELECT first_name, last_name, job_title` picks 3 of the 10 `employees` columns. `FROM employees` names the source table. `WHERE department_id = 1` (covered fully in 3.2) restricts rows to Engineering.

**Why it exists / when to use:** Naming columns is self-documenting, is immune to future `ALTER TABLE ADD COLUMN`, and lets the engine avoid reading/transmitting columns you don't need (relevant for wide tables or column-store engines).

### 3.1.3 Column Aliases

**Simple explanation:** An alias renames a column (or expression) in the *output* only — it never changes the underlying table.

**Syntax:**
```sql
SELECT column_name AS alias_name FROM table_name;
SELECT column_name alias_name  FROM table_name;      -- AS is optional in most dialects
SELECT expr AS "Alias With Spaces" FROM table_name;  -- quote to preserve case/spaces
```

**Examples:**
```sql
SELECT first_name AS given_name, last_name AS family_name
FROM employees
WHERE employee_id = 1;
```

| given_name | family_name |
|---|---|
| Aditi | Rao |

```sql
SELECT first_name || ' ' || last_name AS "Full Name"
FROM employees
WHERE employee_id = 7;
```

| Full Name |
|---|
| Priya Nair |

> **Dialect note:** `||` is the ANSI SQL / **[PostgreSQL]** / **[Oracle]** string concatenation operator. **[SQL Server]** uses `+` (`first_name + ' ' + last_name`). **[MySQL]** requires the `CONCAT()` function (`CONCAT(first_name, ' ', last_name)`) because `||` is treated as logical OR unless `PIPES_AS_CONCAT` SQL mode is enabled. Concatenation functions in depth are covered in Chapter 5.

**Common mistakes:** Forgetting to quote an alias that contains spaces or mixed case in dialects where identifiers fold to lowercase by default (PostgreSQL folds unquoted identifiers to lowercase — `AS Full Name` without quotes becomes `full` followed by a syntax error on the stray `name`, not a column literally named `Full Name`).

**When to use:** Always alias calculated/expression columns (`total_comp` instead of the default `?column?` PostgreSQL would otherwise show) — anyone reading the output or building on the query needs a name.

### 3.1.4 DISTINCT

**Simple explanation:** `DISTINCT` removes duplicate rows from the result set.

**Technical explanation:** After the row set is projected onto the selected columns, the engine performs a deduplication step — typically implemented as a sort-then-dedupe or a hash-based dedupe — comparing the *entire selected row*, not just one column, unless only one column is selected.

**Syntax:**
```sql
SELECT DISTINCT column1[, column2, ...] FROM table_name;
```

**Example 1 — distinct department IDs actually in use:**
```sql
SELECT DISTINCT department_id FROM employees ORDER BY department_id;
```

| department_id |
|---|
| 1 |
| 2 |
| 3 |
| 4 |
| 5 |

**Example 2 — distinct job titles (16 employee rows collapse to 13 titles):**
```sql
SELECT DISTINCT job_title FROM employees ORDER BY job_title;
```

| job_title |
|---|
| Accountant |
| CTO |
| Engineering Manager |
| Finance Manager |
| HR Executive |
| HR Manager |
| Junior Engineer |
| Marketing Executive |
| Marketing Manager |
| Sales Executive |
| Sales Manager |
| Senior Engineer |
| Software Engineer |

Only 13 rows come back because "Software Engineer" appears 3 times (Vikram, Ananya, Aman) and "Sales Executive" appears twice (Arjun, Meera) — `DISTINCT` collapses each set to one row.

**Example 3 — DISTINCT on multiple columns (distinct department/status combinations):**
```sql
SELECT DISTINCT department_id, status
FROM employees
ORDER BY department_id, status;
```

| department_id | status |
|---|---|
| 1 | ACTIVE |
| 1 | ON_LEAVE |
| 2 | ACTIVE |
| 2 | TERMINATED |
| 3 | ACTIVE |
| 4 | ACTIVE |
| 5 | ACTIVE |

7 distinct pairs out of 16 rows — `DISTINCT` here treats `(department_id, status)` as a compound value.

> **⚠️ Warning:** `SELECT DISTINCT` gives you **no guaranteed order** without `ORDER BY`. Two runs of the same query can legally return rows in different order (the optimizer may pick a hash-based dedupe one time and a sort-based one another time, e.g., after `ANALYZE` changes statistics). Never rely on incidental ordering.

**Internals:** In PostgreSQL, `EXPLAIN` on a `DISTINCT` query typically shows either a `HashAggregate` (dedupe via hash table, no sort needed, used when the data/groups fit in `work_mem`) or a `Sort` + `Unique` node (sorts first, then walks adjacent rows dropping duplicates).

**Common mistakes:** Using `DISTINCT` to paper over a bad join that produces duplicate rows, instead of fixing the join. This hides the real bug and can silently drop legitimately distinct-looking rows that happen to have identical selected columns.

**When to use / not use:** Use for genuine deduplication (e.g., "which departments have at least one employee"). Don't reach for it reflexively — `DISTINCT` forces an extra sort/hash pass, which costs performance on large result sets; if you understand why duplicates appear, fixing the query is usually better than masking it.

### 3.1.5 Expressions and Calculated Columns

**Simple explanation:** You can compute new values right inside `SELECT`, not just read stored ones.

**Example — total compensation from a specific salary snapshot:**
```sql
SELECT employee_id, base_salary, bonus, base_salary + bonus AS total_comp
FROM salaries
WHERE effective_date = '2022-01-01';
```

| employee_id | base_salary | bonus | total_comp |
|---|---|---|---|
| 3 | 210000.00 | 25000.00 | 235000.00 |
| 4 | 140000.00 | 12000.00 | 152000.00 |

**Example — percentage bonus of base salary:**
```sql
SELECT employee_id, base_salary, bonus,
       ROUND(bonus / base_salary * 100, 2) AS bonus_pct
FROM salaries
WHERE effective_date = '2022-01-01';
```

| employee_id | base_salary | bonus | bonus_pct |
|---|---|---|---|
| 3 | 210000.00 | 25000.00 | 11.90 |
| 4 | 140000.00 | 12000.00 | 8.57 |

**What happens internally:** The expression is evaluated per output row, after the row passes any `WHERE` filter, as part of the projection step. It is **not** a stored value — recompute it every time, or persist it via `UPDATE`/a generated column if you need it materialized (generated columns are covered in Chapter 13).

**Common mistakes:**
- Integer division surprises: in most dialects, `5 / 2` between two integer columns yields `2`, not `2.5` — you must cast (`5::numeric / 2` in PostgreSQL, `CAST(5 AS DECIMAL)/2` elsewhere) to get a fractional result. `salaries.base_salary` and `bonus` are `NUMERIC`, so this specific table doesn't trip the bug, but it's one of the most common early-career SQL mistakes.
- Referring to a `SELECT`-list alias inside the same `SELECT` list's other expressions (`SELECT base_salary+bonus AS total_comp, total_comp*12 ...`) — this fails in most dialects (including PostgreSQL) because all expressions in the `SELECT` list are conceptually evaluated in parallel against the source row, not sequentially. **[MySQL]** is a notable exception that *does* allow referencing an earlier alias in some contexts.

**Real-world use case:** Computing derived business metrics on the fly for a report — total compensation, discount amounts, tax-inclusive prices — without needing a stored, always-in-sync column.

### 3.1.6 CASE Expressions

**Simple explanation:** `CASE` is SQL's if/else-if/else, but it returns a *value*, so it fits inside a `SELECT` list (or `WHERE`, `ORDER BY`, anywhere an expression is legal).

**Technical explanation:** There are two forms:
- **Simple CASE** — compares one expression against a list of values.
- **Searched CASE** — evaluates independent boolean conditions, in order, and returns the value tied to the first one that's `TRUE`.

**Full syntax:**
```sql
-- Simple CASE
CASE expression
    WHEN value1 THEN result1
    WHEN value2 THEN result2
    [ELSE default_result]
END

-- Searched CASE
CASE
    WHEN condition1 THEN result1
    WHEN condition2 THEN result2
    [ELSE default_result]
END
```
If no `ELSE` is given and no `WHEN` matches, the expression returns `NULL`.

**Example 1 — simple CASE, grouping departments:**
```sql
SELECT department_id, department_name,
       CASE department_id
           WHEN 1 THEN 'Tech'
           WHEN 2 THEN 'Revenue'
           ELSE 'Support Function'
       END AS dept_group
FROM departments
ORDER BY department_id;
```

| department_id | department_name | dept_group |
|---|---|---|
| 1 | Engineering | Tech |
| 2 | Sales | Revenue |
| 3 | HR | Support Function |
| 4 | Finance | Support Function |
| 5 | Marketing | Support Function |

**Example 2 — searched CASE, human-readable status:**
```sql
SELECT first_name, last_name, status,
       CASE
           WHEN status = 'ACTIVE'     THEN 'Currently employed'
           WHEN status = 'ON_LEAVE'   THEN 'Temporarily away'
           WHEN status = 'TERMINATED' THEN 'No longer employed'
       END AS status_description
FROM employees
WHERE employee_id IN (1, 5, 9)
ORDER BY employee_id;
```

| first_name | last_name | status | status_description |
|---|---|---|---|
| Aditi | Rao | ACTIVE | Currently employed |
| Ananya | Singh | ON_LEAVE | Temporarily away |
| Meera | Pillai | TERMINATED | No longer employed |

**Example 3 — searched CASE with ranges (salary banding):**
```sql
SELECT employee_id, base_salary,
       CASE
           WHEN base_salary >= 300000 THEN 'Senior'
           WHEN base_salary >= 150000 THEN 'Mid'
           ELSE 'Junior'
       END AS pay_band
FROM salaries
WHERE base_salary IN (450000, 80000, 250000);
```

| employee_id | base_salary | pay_band |
|---|---|---|
| 1 | 450000.00 | Senior |
| 6 | 80000.00 | Junior |
| 12 | 250000.00 | Mid |

**Line-by-line (Example 3):** For each row from `salaries` matching the `WHERE` filter, `CASE` checks conditions **top to bottom** and stops at the first true one — order matters. If you wrote `WHEN base_salary >= 150000` **before** `WHEN base_salary >= 300000`, the 450000 row would incorrectly land in "Mid" because the first matching branch wins.

**Internally:** `CASE` short-circuits: once a `WHEN` matches, later conditions in the same `CASE` are not evaluated for that row. This matters if a later condition would error (e.g., division by zero) — ordering a safe check first can avoid it.

**Common mistakes:**
- Forgetting `ELSE`, silently getting `NULL` for unmatched rows instead of a sensible default.
- Putting broader/overlapping conditions before narrower ones (band example above).
- Mixing incompatible return types across branches (`THEN 1` in one branch, `THEN 'one'` in another) — most dialects require all branches to resolve to a common type and will either implicitly cast or error.

**Edge cases:** `CASE` used in `WHERE`/`ORDER BY`/`GROUP BY` is fully legal — e.g., `ORDER BY CASE WHEN status='ACTIVE' THEN 0 ELSE 1 END` to sort active employees first, a very common real-world pattern.

**Real-world use cases:** Bucketing continuous values into bands (salary bands, age groups), translating codes to labels, conditional aggregation (pairs with `SUM(CASE WHEN ... THEN 1 ELSE 0 END)` — previewed here, covered fully with `GROUP BY` in Chapter 6).

### 3.1.7 NULL Handling in SELECT Output

**Simple explanation:** `NULL` means "unknown / not applicable / absent" — it is not zero, not an empty string, and not equal to anything, including another `NULL`.

**Example — projects without an end date yet:**
```sql
SELECT project_name, start_date, end_date FROM projects ORDER BY project_id;
```

| project_name | start_date | end_date |
|---|---|---|
| Platform Migration | 2023-01-01 | 2023-12-31 |
| Mobile App Revamp | 2024-01-15 | *(NULL)* |
| Q1 Sales Expansion | 2024-01-01 | 2024-03-31 |
| Employee Wellness | 2023-06-01 | 2023-09-30 |
| Brand Relaunch | 2024-02-01 | *(NULL)* |

`Mobile App Revamp` and `Brand Relaunch` are ongoing (no `end_date` was ever set) — `psql` renders this as a blank cell by default, or literally the word `NULL` depending on your client's `\pset null` setting.

> **Important Note:** `NULL <> NULL` is not `TRUE` — it's `NULL` (unknown). This is why `WHERE end_date = NULL` **never** matches anything (covered in depth in 3.2.6) — you must use `IS NULL`. Arithmetic and concatenation involving `NULL` also propagate `NULL`: `bonus + NULL` is `NULL`, `'a' || NULL` is `NULL` in PostgreSQL. Functions to substitute default values for `NULL` (`COALESCE`, `NULLIF`) are covered in Chapter 5 — for now, know that a `CASE WHEN col IS NULL THEN ...` expression (3.1.6) can achieve the same thing manually.

**Common mistakes:** Assuming `bonus` can be blank/`NULL` in this schema — it can't; `salaries.bonus` is `NOT NULL DEFAULT 0`. But `check_in`/`check_out` in `attendance` *are* nullable and are genuinely `NULL` for `ABSENT`/`LEAVE` rows — a classic real-world case of "the column exists but doesn't apply to this row."

### 3.1.8 Practice Questions — SELECT

1. Write a query that returns every column from `projects`.
2. Return only `project_name` and `budget` for all projects, aliasing `budget` as `project_budget`.
3. Return the distinct list of `location` values from `departments`.
4. Return `first_name`, `last_name`, and a calculated column `email_domain` — hint: you'll need string functions from Chapter 5 for a robust answer, but for now try it with `||` and see what you can produce.
5. Using a searched `CASE`, label every project as `'Completed'` if `end_date` is not null and in the past relative to `'2024-06-01'`, `'Ongoing'` if `end_date` is null, or `'Scheduled to End'` otherwise.
6. Write a query returning `employee_id`, `base_salary`, `bonus`, and a `total_comp` calculated column, for every row in `salaries` where `effective_date = '2021-01-01'`.
7. Return the distinct combinations of `department_id` and `job_title` from `employees`.
8. Write a query that shows `first_name`, `last_name`, `manager_id`, and a `CASE` column that prints `'Top of hierarchy'` when `manager_id IS NULL` and `'Has a manager'` otherwise.
9. Return every column of `attendance`, and explain out loud (no SQL needed) why `check_in`/`check_out` show as blank for two of the rows.
10. Challenge: without using `DISTINCT`, is there another way you could get one row per `department_id`? (Hint: think ahead to Chapter 6 — `GROUP BY`.)

---

## 3.2 WHERE — Filtering Rows

**Simple explanation:** `WHERE` decides which rows make it into the result. Every row is tested against the condition; only rows where it evaluates to `TRUE` survive.

**Technical explanation:** `WHERE` operates on individual rows **before** any grouping/aggregation (contrast with `HAVING` in Chapter 6, which filters *after* grouping). Its condition is a boolean expression using **three-valued logic**: `TRUE`, `FALSE`, or `UNKNOWN` (from `NULL` comparisons). Only rows evaluating to `TRUE` are kept — `FALSE` and `UNKNOWN` rows are both dropped.

**Why it exists:** Without filtering, every query would return the entire table, forcing you to filter client-side after transferring all the data — wasteful and, for large tables, infeasible.

**Full syntax:**
```sql
SELECT column_list
FROM table_name
WHERE condition;
```

### 3.2.1 Comparison Operators

| Operator | Meaning | Also written as |
|---|---|---|
| `=` | equal to | — |
| `<>` | not equal to | `!=` (widely supported, non-ANSI) |
| `<` | less than | |
| `>` | greater than | |
| `<=` | less than or equal to | |
| `>=` | greater than or equal to | |

**Example:**
```sql
SELECT first_name, last_name, hire_date
FROM employees
WHERE hire_date < '2017-01-01'
ORDER BY hire_date;
```

| first_name | last_name | hire_date |
|---|---|---|
| Aditi | Rao | 2015-03-01 |
| Priya | Nair | 2015-11-05 |
| Rahul | Mehta | 2016-05-12 |
| Rohan | Kapoor | 2016-08-09 |
| Nikhil | Gupta | 2016-12-01 |

**Line-by-line:** PostgreSQL compares the `DATE` column `hire_date` against the string literal `'2017-01-01'`, implicitly casting the literal to `DATE`. Only rows strictly before that date qualify — note Sneha Kulkarni (`2017-01-20`) is correctly excluded.

**Common mistakes:** Comparing dates as strings across mismatched formats (`'01-01-2017'` vs `'2017-01-01'`) — always use ISO 8601 (`YYYY-MM-DD`) literals to avoid locale-dependent parsing ambiguity.

### 3.2.2 AND, OR, NOT and Operator Precedence

**Simple explanation:** `AND` requires both sides true, `OR` requires at least one side true, `NOT` flips a condition.

**Precedence (highest to lowest): `NOT` → `AND` → `OR`.** This mirrors math (`*`/`/` before `+`/`-`) and is one of the most under-appreciated sources of SQL bugs.

**Example — the precedence trap:**
```sql
SELECT employee_id, first_name, department_id, status
FROM employees
WHERE department_id = 1 AND status = 'ACTIVE' OR department_id = 2
ORDER BY employee_id;
```

Because `AND` binds tighter than `OR`, this is parsed as:
```
(department_id = 1 AND status = 'ACTIVE') OR (department_id = 2)
```

**Expected output (9 rows):**

| employee_id | first_name | department_id | status |
|---|---|---|---|
| 1 | Aditi | 1 | ACTIVE |
| 2 | Rahul | 1 | ACTIVE |
| 3 | Sneha | 1 | ACTIVE |
| 4 | Vikram | 1 | ACTIVE |
| 6 | Karan | 1 | ACTIVE |
| 7 | Priya | 2 | ACTIVE |
| 8 | Arjun | 2 | ACTIVE |
| 9 | Meera | 2 | TERMINATED |
| 16 | Aman | 1 | ACTIVE |

Notice employee 9, Meera Pillai, is `TERMINATED` — she's included anyway because `department_id = 2` alone satisfies the `OR`, regardless of status. Ananya Singh (5, `ON_LEAVE`, dept 1) is correctly excluded because she fails *both* the `AND` clause and the `OR` clause.

**Now with explicit parentheses to get the *other* intended meaning ("Engineering employees who are either active, or in Sales" was probably not the real intent — probably the intent was "active employees in Engineering or Sales"):**
```sql
SELECT employee_id, first_name, department_id, status
FROM employees
WHERE department_id = 1 AND (status = 'ACTIVE' OR department_id = 2)
ORDER BY employee_id;
```
Because `department_id = 1` is fixed by the outer `AND`, `department_id = 2` inside the parentheses can never be true for a surviving row — this reduces to plain `department_id = 1 AND status = 'ACTIVE'`.

**Expected output (6 rows):** employees 1, 2, 3, 4, 6, 16 — same as above minus every dept-2 row.

> **⚠️ Warning:** If your intent was "active employees, and they must be in Engineering **or** Sales," the correct query is:
> ```sql
> WHERE (department_id = 1 OR department_id = 2) AND status = 'ACTIVE'
> ```
> which is *also* different from both queries above (it would return 1, 2, 3, 4, 6, 16, 7, 8 — 8 rows, excluding terminated Meera). **Always parenthesize explicitly when mixing `AND` and `OR`** — never rely on a reader (including future you) correctly recalling precedence rules.

**NOT example:**
```sql
SELECT first_name, last_name, status
FROM employees
WHERE NOT status = 'ACTIVE'
ORDER BY employee_id;
```

| first_name | last_name | status |
|---|---|---|
| Ananya | Singh | ON_LEAVE |
| Meera | Pillai | TERMINATED |

**Common mistakes:** Chaining many `OR`s instead of `IN` (`status = 'A' OR status = 'B' OR status = 'C'` — see 3.2.4 for the cleaner `IN` form). Forgetting that `NOT (A AND B)` is **not** the same as `NOT A AND NOT B` (De Morgan's law: it's `NOT A OR NOT B`).

### 3.2.3 BETWEEN

**Simple explanation:** `BETWEEN low AND high` is shorthand for `>= low AND <= high` — **inclusive on both ends**.

**Syntax:**
```sql
column BETWEEN low_value AND high_value
column NOT BETWEEN low_value AND high_value
```

**Example:**
```sql
SELECT first_name, last_name, hire_date
FROM employees
WHERE hire_date BETWEEN '2017-01-01' AND '2018-12-31'
ORDER BY hire_date;
```

| first_name | last_name | hire_date |
|---|---|---|
| Sneha | Kulkarni | 2017-01-20 |
| Arjun | Das | 2017-04-18 |
| Rajesh | Iyer | 2017-09-30 |
| Divya | Shah | 2018-06-25 |
| Vikram | Joshi | 2018-07-15 |

> **⚠️ Warning:** `BETWEEN` is inclusive. `hire_date BETWEEN '2017-01-01' AND '2018-12-31'` **would** include a hire on exactly `2018-12-31`, and does include `2017-01-20` because the lower bound `2017-01-01` is included. A common date-range bug: `BETWEEN '2024-01-01' AND '2024-01-31'` against a `TIMESTAMP` column silently excludes anything after midnight on the 31st (e.g., `2024-01-31 14:00:00`) — because the upper bound is treated as midnight, not end-of-day. This doesn't affect `hire_date`, which is a plain `DATE`, but will matter the moment you work with `TIMESTAMP` columns.

**When to use / not use:** Use for a clean, readable inclusive range on a single column. Don't use it across two *different* columns' meanings (e.g., don't try to fake "is `today` between `start_date` and `end_date`" with `BETWEEN` unless you write it as `'2024-06-01' BETWEEN start_date AND end_date` — that direction works, but is less readable than `start_date <= '2024-06-01' AND end_date >= '2024-06-01'` when `end_date` can be `NULL`, since `BETWEEN` involving a `NULL` bound returns `UNKNOWN`, silently dropping the row).

### 3.2.4 IN and NOT IN

**Simple explanation:** `IN` checks membership in a list; `NOT IN` checks the opposite.

**Syntax:**
```sql
column IN (value1, value2, ...)
column NOT IN (value1, value2, ...)
```

**Example — IN:**
```sql
SELECT department_id, department_name
FROM departments
WHERE department_id IN (1, 3, 5);
```

| department_id | department_name |
|---|---|
| 1 | Engineering |
| 3 | HR |
| 5 | Marketing |

**Example — NOT IN:**
```sql
SELECT department_id, department_name
FROM departments
WHERE department_id NOT IN (1, 3, 5);
```

| department_id | department_name |
|---|---|
| 2 | Sales |
| 4 | Finance |

**The NOT IN NULL trap (foreshadowing Chapter 8):** `NOT IN` silently returns **zero rows** if the list contains even one `NULL`. Watch:

```sql
SELECT employee_id, first_name, manager_id
FROM employees
WHERE manager_id NOT IN (2, NULL);
```

**Expected output: 0 rows** — even though 13 of the 16 employees clearly have a `manager_id` that is neither `2` nor `NULL`.

**Why:** `x NOT IN (2, NULL)` expands to `NOT (x = 2 OR x = NULL)`. For any row where `x <> 2`, `x = 2` is `FALSE`, but `x = NULL` is always `UNKNOWN` — never `TRUE` or `FALSE`. `FALSE OR UNKNOWN` is `UNKNOWN`, and `NOT UNKNOWN` is still `UNKNOWN`. A `WHERE` clause only keeps rows that evaluate to `TRUE`, so every single row is discarded, including the one where `manager_id` actually *is* `2` (`FALSE OR TRUE = TRUE`, `NOT TRUE = FALSE` — still excluded, for a different reason). This bites hardest when the list comes from a **subquery** that can silently produce a `NULL` (e.g., `WHERE manager_id NOT IN (SELECT manager_id FROM employees)` — since employee 1's `manager_id` is `NULL`, this subquery poisons the entire `NOT IN` and returns zero rows). Chapter 8 (Subqueries) covers the fix (`NOT EXISTS`) in depth.

> **Important Note:** Plain `IN` does **not** have this problem — `x IN (2, NULL)` for a non-matching row is `FALSE OR UNKNOWN = UNKNOWN` (correctly excluded, not silently wrong), and for a matching row is `TRUE OR UNKNOWN = TRUE` (correctly included). The danger is specific to `NOT IN`.

**Common mistakes:** Using `NOT IN` against any column or subquery that could contain `NULL`, without first filtering `NULL`s out (`... NOT IN (SELECT manager_id FROM employees WHERE manager_id IS NOT NULL)` fixes the specific example above).

### 3.2.5 LIKE, ILIKE, and Pattern Matching

**Simple explanation:** `LIKE` matches text against a pattern using two wildcards: `%` (any sequence of characters, including none) and `_` (exactly one character).

**Syntax:**
```sql
column LIKE 'pattern'
column NOT LIKE 'pattern'
column ILIKE 'pattern'          -- [PostgreSQL] case-insensitive LIKE
```

**Example — last names starting with "K":**
```sql
SELECT first_name, last_name
FROM employees
WHERE last_name LIKE 'K%'
ORDER BY employee_id;
```

| first_name | last_name |
|---|---|
| Sneha | Kulkarni |
| Rohan | Kapoor |

**Example — case sensitivity, LIKE vs ILIKE [PostgreSQL]:**
```sql
SELECT first_name FROM employees WHERE first_name LIKE 'a%'  ORDER BY employee_id;  -- 0 rows
SELECT first_name FROM employees WHERE first_name ILIKE 'a%' ORDER BY employee_id;  -- 4 rows
```

`LIKE 'a%'` (lowercase `a`) returns **0 rows** — PostgreSQL's `LIKE` is case-sensitive by default, and every seed name is capitalized (`Aditi`, not `aditi`). `ILIKE 'a%'` returns:

| first_name |
|---|
| Aditi |
| Ananya |
| Arjun |
| Aman |

> **Dialect comparison — case-insensitive matching:**
> - **[PostgreSQL]** has a native `ILIKE` operator (shown above), plus the `citext` extension for always-case-insensitive columns.
> - **[MySQL]** — `LIKE` is case-insensitive *by default* on the common `utf8mb4_general_ci`/`utf8mb4_0900_ai_ci` collations (the `_ci` suffix = case-insensitive); to force case-sensitivity you'd need a `_bin` or `_cs` collation. There's no `ILIKE` keyword; behavior is collation-driven.
> - **[Oracle]** — `LIKE` is case-sensitive by default (like PostgreSQL). Case-insensitive matching is done with `UPPER(column) LIKE UPPER('pattern')`, `LOWER(...)`, or by setting `NLS_COMP=LINGUISTIC` with a case-insensitive `NLS_SORT`.
> - **[SQL Server]** — case sensitivity depends entirely on the column/database **collation** (most default installs use a case-insensitive `_CI` collation, so plain `LIKE` "just works" case-insensitively out of the box); to force sensitivity, apply `COLLATE Latin1_General_CS_AS` or similar to the expression.
> - **Portable pattern** across all four: `WHERE LOWER(column) LIKE LOWER('pattern')` (or `LOWER(column) LIKE 'a%'`) always works regardless of dialect/collation defaults — string functions arrive in Chapter 5.

**Wildcards in detail:**

| Wildcard | Matches | Example |
|---|---|---|
| `%` | zero or more of any character | `'K%'` → Kulkarni, Kapoor, K, Kxyz... |
| `_` | exactly one of any character | `'_a%'` → 2nd character is `a` |

**Example — `_` wildcard, second letter is "a":**
```sql
SELECT first_name FROM employees WHERE first_name LIKE '_a%' ORDER BY employee_id;
```

| first_name |
|---|
| Rahul |
| Karan |
| Rajesh |

(`R-a-hul`, `K-a-ran`, `R-a-jesh` all have `a` as the 2nd character; `Aditi` doesn't — its 2nd character is `d`.)

**Escaping wildcards:** If you need to match a *literal* `%` or `_` in the data (e.g., a job title of `"50%_Remote"`), escape it with the `ESCAPE` clause:
```sql
SELECT * FROM employees WHERE job_title LIKE '%\_Remote%' ESCAPE '\';
```
No row in `company_db` contains a literal `%` or `_`, so this particular query correctly returns an **empty result set** — the point here is the syntax, which you'll need the moment real data contains those characters (product SKUs, discount strings, escaped file paths, etc.). **[PostgreSQL]**'s default escape character is already `\`, so `ESCAPE '\'` is often omittable, but writing it explicitly is portable and self-documenting. **[SQL Server]**/**[Oracle]**/**[MySQL]** all support the same `ESCAPE` clause syntax.

**Common mistakes:**
- Forgetting `%` on both sides for a "contains" search: `LIKE 'Engineer'` only matches the exact string; you want `LIKE '%Engineer%'`.
- Leading-wildcard patterns (`LIKE '%Manager'`) can't use a standard B-tree index efficiently — the engine must scan every row (this becomes very relevant in Chapter 16, Indexes; PostgreSQL's `pg_trgm` extension solves it).
- Using `LIKE` for exact equality checks — plain `=` is clearer and faster when there's no actual pattern.

**When to use / not use:** Use `LIKE`/`ILIKE` for genuine partial/pattern text search on small-to-medium result sets. For serious full-text search (ranking, stemming, multi-word relevance) use PostgreSQL's full-text search (`tsvector`/`tsquery`, Chapter 25) instead.

### 3.2.6 IS NULL / IS NOT NULL

**Simple explanation:** The *only* correct way to test for `NULL` — never `= NULL` or `<> NULL`, both of which always evaluate to `UNKNOWN` and therefore never match any row.

**Syntax:**
```sql
column IS NULL
column IS NOT NULL
```

**Example:**
```sql
SELECT first_name, last_name FROM employees WHERE manager_id IS NULL;
```

| first_name | last_name |
|---|---|
| Aditi | Rao |

Only Aditi Rao (the CTO) has no manager — everyone else reports to someone.

```sql
SELECT project_name FROM projects WHERE end_date IS NULL;
```

| project_name |
|---|
| Mobile App Revamp |
| Brand Relaunch |

> **⚠️ Warning:** `SELECT * FROM projects WHERE end_date = NULL;` returns **zero rows**, silently — no error, no warning, just an empty (and wrong) result. This is one of the single most common beginner bugs in all of SQL. If a query filtering on possibly-`NULL` data mysteriously returns nothing, check for `= NULL`/`<> NULL` first.

**Common mistakes:** Writing `WHERE column <> NULL` intending "give me rows where this column is set" — always `IS NOT NULL` instead.

### 3.2.7 Practice Questions — WHERE

1. Find all employees hired in the year 2019 or later.
2. Find all employees who are **not** in department 1 and **not** `TERMINATED`, using explicit parentheses so the intent is unambiguous.
3. Find every project with a `budget` between 500,000 and 2,000,000 inclusive.
4. Find every department whose `department_id` is in `(2, 4)`.
5. Find every employee whose `email` contains the substring `"kapoor"` (any case) using `ILIKE`.
6. Find every employee whose `first_name` ends in the letter `"a"`.
7. Find every attendance row where `check_in` is missing.
8. Find every employee who has a manager (i.e., is not the top of the hierarchy).
9. Explain (no SQL required) why `SELECT * FROM employees WHERE manager_id NOT IN (SELECT manager_id FROM employees)` returns zero rows, and rewrite it so it returns the employee(s) who manage nobody... (hint: that's actually the wrong direction — think about what the subquery really returns, then decide what condition you actually want).
10. Find all `ACTIVE` employees in department 1 whose `hire_date` is before `2019-01-01`, combining `AND` correctly.

---

## 3.3 INSERT — Creating Data

**Simple explanation:** `INSERT` adds new rows to a table.

**Technical explanation:** `INSERT` is a DML statement that appends one or more new tuples to a table's heap (in PostgreSQL's MVCC storage model, a brand-new row version is created; nothing is ever "written into" existing space). Every `NOT NULL` column without a usable default must receive an explicit value or the statement is rejected; every constraint (`UNIQUE`, `CHECK`, `FOREIGN KEY`) is validated before the row is committed.

**Why it exists:** It's the "C" in CRUD — the only way new facts (a new employee, a new salary record, a new project) enter the database.

### 3.3.1 Single-Row Insert

**Syntax:**
```sql
INSERT INTO table_name (column1, column2, ...)
VALUES (value1, value2, ...);
```

**Example:**
```sql
INSERT INTO departments (department_name, location)
VALUES ('Legal', 'Chennai')
RETURNING department_id, department_name, location;
```

**Expected output** (assuming a freshly loaded database, where the `departments_department_id_seq` sequence is currently at 5):

| department_id | department_name | location |
|---|---|---|
| 6 | Legal | Chennai |

**Line-by-line:** `INSERT INTO departments (department_name, location)` names only the two columns we're supplying — `department_id` is omitted because it's `SERIAL` (auto-generated from a sequence) and `created_at` is omitted because it has `DEFAULT now()`. `VALUES ('Legal', 'Chennai')` supplies the values positionally, matching the column list order. `RETURNING ...` (3.3.4) hands back the row as actually stored, including the auto-generated `department_id`.

**Common mistakes:** Relying on column *position* without naming columns (`INSERT INTO departments VALUES (6, 'Legal', 'Chennai', now())`) — this breaks the instant someone adds/reorders a column. Always name columns explicitly in production code.

### 3.3.2 Multi-Row Insert

**Syntax:**
```sql
INSERT INTO table_name (column1, column2, ...)
VALUES
    (value1a, value2a, ...),
    (value1b, value2b, ...),
    (value1c, value2c, ...);
```

**Example (fresh database):**
```sql
INSERT INTO departments (department_name, location) VALUES
    ('Legal', 'Chennai'),
    ('IT Support', 'Hyderabad'),
    ('Customer Success', 'Pune')
RETURNING department_id, department_name, location;
```

**Expected output:**

| department_id | department_name | location |
|---|---|---|
| 6 | Legal | Chennai |
| 7 | IT Support | Hyderabad |
| 8 | Customer Success | Pune |

**Why it exists / when to use:** A single multi-row `INSERT` is dramatically faster than N single-row `INSERT`s from application code, because it's one network round trip and one parse/plan cycle instead of N. Prefer this form whenever you're loading a known batch of rows.

**What happens internally:** PostgreSQL still creates the rows one at a time internally and evaluates constraints per row, but it does so within a single statement — one transaction, one WAL flush pattern, one trip through the planner — which is where the performance win comes from versus N round trips.

### 3.3.3 INSERT ... SELECT

**Simple explanation:** Instead of typing literal values, you can populate a table directly from the result of a `SELECT` against another table (or the same table).

**Syntax:**
```sql
INSERT INTO target_table (column1, column2, ...)
SELECT expr1, expr2, ...
FROM source_table
WHERE condition;
```

**Example — assign every HR department employee to the Mobile App Revamp project as a support engineer:**
```sql
INSERT INTO employee_projects (employee_id, project_id, role, hours_allocated)
SELECT employee_id, 2, 'Support Engineer', 100
FROM employees
WHERE department_id = 3
RETURNING employee_id, project_id, role, hours_allocated;
```

**Expected output:**

| employee_id | project_id | role | hours_allocated |
|---|---|---|---|
| 10 | 2 | Support Engineer | 100 |
| 11 | 2 | Support Engineer | 100 |

**Line-by-line:** The `SELECT` finds the two HR-department employees (Rohan Kapoor, Isha Bhatt). For each row it returns, `INSERT` supplies `employee_id` from that row, and the constant literals `2`, `'Support Engineer'`, `100` for the other three target columns. Since neither employee already has a row for `project_id = 2` in `employee_projects`, the composite primary key `(employee_id, project_id)` isn't violated.

**When to use:** Bulk-copying/deriving data — archiving old rows into a history table, seeding a new table from an existing one, denormalizing a snapshot. Far more efficient than `SELECT`ing into your application and looping `INSERT`s back.

**Edge case:** If the `SELECT` returns zero rows, `INSERT ... SELECT` simply inserts zero rows — no error.

### 3.3.4 RETURNING / OUTPUT / LAST_INSERT_ID

**Why it exists:** After an `INSERT`, you very often need to know what was actually stored — especially auto-generated values like a new `employee_id` — without a separate round-trip query (which would also be racy under concurrent inserts).

| Dialect | Mechanism | Example |
|---|---|---|
| **[PostgreSQL]** | `RETURNING` clause, any column/expression, returns a full result set | `INSERT INTO employees (...) VALUES (...) RETURNING employee_id;` |
| **[Oracle]** | `RETURNING ... INTO` clause, binds into PL/SQL variables (not a free-standing result set in plain SQL) | `INSERT INTO employees (...) VALUES (...) RETURNING employee_id INTO :new_id;` |
| **[SQL Server]** | `OUTPUT` clause, references `inserted`/`deleted` pseudo-tables | `INSERT INTO employees (...) OUTPUT inserted.employee_id VALUES (...);` |
| **[MySQL]** | No equivalent clause. For a single auto-increment column, query `SELECT LAST_INSERT_ID();` immediately after, in the same session/connection | `INSERT INTO employees (...) VALUES (...); SELECT LAST_INSERT_ID();` |

**Example [PostgreSQL] — returning multiple columns and an expression:**
```sql
INSERT INTO employees (first_name, last_name, email, hire_date, job_title, department_id, manager_id)
VALUES ('Tara', 'Nambiar', 'tara.nambiar@company.com', '2024-03-01', 'Software Engineer', 1, 2)
RETURNING employee_id, status, first_name || ' ' || last_name AS full_name;
```

**Expected output (fresh database, `employees_employee_id_seq` currently at 16):**

| employee_id | status | full_name |
|---|---|---|
| 17 | ACTIVE | Tara Nambiar |

Note `status` comes back as `'ACTIVE'` even though we never supplied it — it was filled in by the column's `DEFAULT 'ACTIVE'`, and `RETURNING` shows the row exactly as stored, defaults included.

> **Important Note:** `LAST_INSERT_ID()` **[MySQL]** is scoped to the current session/connection and reflects the last auto-increment value generated by *that connection*, so it is safe under concurrency (each connection sees only its own last ID) — but it only tracks a single auto-increment column, and only from the most recent `INSERT` statement (a multi-row insert gives you the *first* generated ID of that statement, from which you can compute the rest since they're normally sequential — fragile if `AUTO_INCREMENT` isn't gapless, which it often isn't after failed transactions).

### 3.3.5 Defaults, Explicit NULL vs. Omitted Columns

**Simple explanation:** *Omitting* a column from an `INSERT` lets its default (if any) apply. *Explicitly* inserting `NULL` bypasses the default entirely and stores `NULL` — which is only legal if the column allows `NULL`.

**Example — omitting `status` (uses the default):**
```sql
INSERT INTO employees (first_name, last_name, email, hire_date, job_title, department_id)
VALUES ('Ingrid', 'Fischer', 'ingrid.fischer@company.com', '2024-04-01', 'Consultant', NULL)
RETURNING employee_id, department_id, status;
```

| employee_id | department_id | status |
|---|---|---|
| 17 | *(NULL)* | ACTIVE |

`department_id` is nullable with no default, so explicitly passing `NULL` for it is perfectly legal (it just means "not yet assigned to a department"). `status` was omitted entirely, so its `DEFAULT 'ACTIVE'` kicked in.

**Example — explicit NULL where a default exists but the column is NOT NULL (this fails):**
```sql
INSERT INTO employees (first_name, last_name, email, hire_date, job_title, status)
VALUES ('Test', 'User', 'test.user@company.com', '2024-01-01', 'Intern', NULL);
```

**Expected result:**
```
ERROR:  null value in column "status" of relation "employees" violates not-null constraint
DETAIL:  Failing row contains (..., Test, User, test.user@company.com, 2024-01-01, Intern, null, null, null, ...).
```

**Why:** `status` is declared `NOT NULL DEFAULT 'ACTIVE'`. The `DEFAULT` clause only fires when the column is **omitted** from the `INSERT` column list. If you explicitly write `NULL` for a `NOT NULL` column, the engine tries to store `NULL` as you asked, and the `NOT NULL` constraint rejects it — the default never gets a chance to apply. This distinction — *omitted* triggers the default, *explicit NULL* does not — is one of the most important and most frequently misunderstood rules in `INSERT` semantics across every mainstream dialect.

### 3.3.6 Constraint Violations on Insert

| Constraint type | Example statement | Resulting error (PostgreSQL wording) |
|---|---|---|
| `UNIQUE` | `INSERT INTO departments (department_name, location) VALUES ('Engineering', 'Chennai');` | `ERROR: duplicate key value violates unique constraint "departments_department_name_key"` — `DETAIL: Key (department_name)=(Engineering) already exists.` |
| `CHECK` | `INSERT INTO salaries (employee_id, base_salary, bonus, effective_date) VALUES (3, -5000, 0, '2024-01-01');` | `ERROR: new row for relation "salaries" violates check constraint "salaries_base_salary_check"` |
| `FOREIGN KEY` | `INSERT INTO employees (first_name, last_name, email, hire_date, job_title, department_id) VALUES ('Zoe', 'Fox', 'zoe.fox@company.com', '2024-01-01', 'Analyst', 99);` | `ERROR: insert or update on table "employees" violates foreign key constraint` — `DETAIL: Key (department_id)=(99) is not present in table "departments".` |
| `NOT NULL` (column omitted entirely, no default) | `INSERT INTO employees (first_name, email, hire_date, job_title) VALUES ('Zoe', 'zoe.fox@company.com', '2024-01-01', 'Analyst');` | `ERROR: null value in column "last_name" of relation "employees" violates not-null constraint` |

**What happens internally:** PostgreSQL validates constraints **per row**, generally in this order: `NOT NULL` → data-type/cast checks → `CHECK` → `UNIQUE`/`PRIMARY KEY` (via a unique index insert) → `FOREIGN KEY` (via a lookup against the referenced table, often deferred to end-of-statement or end-of-transaction if the constraint is declared `DEFERRABLE`). The **entire statement** fails and rolls back if any row fails any constraint — a multi-row `INSERT` is atomic: it's all-or-nothing by default (no partial inserts), unless you're using an `ON CONFLICT` clause (Chapter 31) to handle conflicts row-by-row.

**Common mistakes:** Assuming a multi-row `INSERT` will insert the "good" rows and skip the "bad" one — it won't; one bad row fails the whole statement.

**Edge case:** Because `salaries` has `UNIQUE (employee_id, effective_date)`, re-running the exact same historical `INSERT` seed line twice would violate that composite unique constraint even though neither column alone is unique.

### 3.3.7 Practice Questions — INSERT

1. Insert a new department `'Legal'` in `'Chennai'`, and use `RETURNING` to get back its generated `department_id`.
2. Insert three new departments in one statement.
3. Insert a new employee into Engineering (`department_id = 1`) reporting to Rahul Mehta (`employee_id = 2`), omitting `status` so it defaults, and return the generated `employee_id` plus the default `status`.
4. Try inserting an employee with `department_id = 999`. What error do you get, and which constraint caused it?
5. Try inserting a `salaries` row with `base_salary = 0`. What error do you get, and why?
6. Using `INSERT ... SELECT`, copy every `ACTIVE` employee in Marketing (`department_id = 5`) into `employee_projects` for `project_id = 5` with `role = 'Contributor'` and `hours_allocated = 50`.
7. What is the difference in outcome between omitting `bonus` entirely in an insert into `salaries`, versus explicitly writing `bonus = NULL`? Try both and compare.
8. Explain why `INSERT INTO managers (manager_id, department_id, appointed_date) VALUES (99, 1, '2024-01-01')` fails, referencing the exact constraint involved.

---

## 3.4 UPDATE — Modifying Data

**Simple explanation:** `UPDATE` changes the values of existing rows.

**Technical explanation:** `UPDATE` is a DML statement that, for every row matching its `WHERE` clause (or every row, if `WHERE` is omitted), replaces the specified column values. Under PostgreSQL's MVCC model, this is implemented as creating a **new row version** and marking the old one as dead (to be reclaimed later by `VACUUM`) — it is not an in-place byte-level overwrite, which is why `UPDATE` can be more expensive than it looks, and why heavily updated tables need regular vacuuming (Chapter 29).

**Full syntax:**
```sql
UPDATE table_name
SET column1 = value1, column2 = value2, ...
[WHERE condition];
```

### 3.4.1 Updating One Row

**Example:**
```sql
UPDATE employees
SET job_title = 'Staff Engineer'
WHERE employee_id = 3;
```

**Before:**

| employee_id | first_name | last_name | job_title |
|---|---|---|---|
| 3 | Sneha | Kulkarni | Senior Engineer |

**After:**

| employee_id | first_name | last_name | job_title |
|---|---|---|---|
| 3 | Sneha | Kulkarni | Staff Engineer |

PostgreSQL reports `UPDATE 1` — exactly one row matched `employee_id = 3` (the primary key guarantees at most one match here).

### 3.4.2 Updating Multiple Rows

**Example — every salary row currently in USD (all 21 seed rows) gets its currency normalized:**
```sql
UPDATE salaries
SET currency = 'INR'
WHERE currency = 'USD';
```

**Expected result:** `UPDATE 21` — every one of the 21 seed `salaries` rows has `currency = 'USD'` by default, so all 21 are matched and updated in a single statement.

**Example — bring the one ON_LEAVE employee back to ACTIVE:**
```sql
UPDATE employees
SET status = 'ACTIVE'
WHERE status = 'ON_LEAVE';
```

**Expected result:** `UPDATE 1` (only Ananya Singh, `employee_id = 5`, currently has `status = 'ON_LEAVE'`). This demonstrates that "multiple-row `UPDATE`" is really about the **shape** of the `WHERE` clause — it will affect however many rows happen to match, from zero to every row in the table.

### 3.4.3 UPDATE Using Joins/Subqueries

**Simple explanation:** Sometimes the rows you want to update, and the condition that decides *which* rows, live in *different* tables. All four major dialects support this, but the syntax differs meaningfully.

**Scenario:** Give a 10% bonus increase to every Engineering-department (`department_id = 1`) employee's salary record dated on or after `2022-01-01`.

First, work out by hand which rows qualify — `employees` with `department_id = 1`: 1, 2, 3, 4, 5, 6, 16. Of their `salaries` rows, which have `effective_date >= '2022-01-01'`?

| employee_id | effective_date | bonus (before) |
|---|---|---|
| 3 | 2022-01-01 | 25000.00 |
| 4 | 2022-01-01 | 12000.00 |
| 16 | 2022-01-10 | 6000.00 |

(Employee 1's most recent row is `2020-01-01`, employee 2's is `2021-01-01`, employee 5's only row is `2019-09-01`, employee 6's only row is `2020-02-10` — none of those qualify.)

**[PostgreSQL] — `UPDATE ... FROM`:**
```sql
UPDATE salaries s
SET bonus = ROUND(s.bonus * 1.10, 2)
FROM employees e
WHERE s.employee_id = e.employee_id
  AND e.department_id = 1
  AND s.effective_date >= '2022-01-01'
RETURNING s.employee_id, s.effective_date, s.bonus;
```

**[MySQL] — `UPDATE ... JOIN`:**
```sql
UPDATE salaries s
JOIN employees e ON s.employee_id = e.employee_id
SET s.bonus = ROUND(s.bonus * 1.10, 2)
WHERE e.department_id = 1
  AND s.effective_date >= '2022-01-01';
```

**[SQL Server] — `UPDATE ... FROM ... JOIN`:**
```sql
UPDATE s
SET s.bonus = ROUND(s.bonus * 1.10, 2)
FROM salaries s
JOIN employees e ON s.employee_id = e.employee_id
WHERE e.department_id = 1
  AND s.effective_date >= '2022-01-01';
```

**[Oracle] — correlated subquery (Oracle has no `UPDATE...JOIN`/`FROM` form for multi-table updates):**
```sql
UPDATE salaries s
SET s.bonus = ROUND(s.bonus * 1.10, 2)
WHERE s.effective_date >= DATE '2022-01-01'
  AND EXISTS (
        SELECT 1
        FROM employees e
        WHERE e.employee_id = s.employee_id
          AND e.department_id = 1
      );
```

**Expected result (all four, same logical outcome — 3 rows updated):**

| employee_id | effective_date | bonus (after) |
|---|---|---|
| 3 | 2022-01-01 | 27500.00 |
| 4 | 2022-01-01 | 13200.00 |
| 16 | 2022-01-10 | 6600.00 |

**Line-by-line (PostgreSQL version):** `UPDATE salaries s` names the table being modified and gives it an alias. `SET bonus = ROUND(s.bonus * 1.10, 2)` computes the new value from the row's *current* value. `FROM employees e` brings a second table into scope purely to help filter/compute — it does not get modified. `WHERE s.employee_id = e.employee_id` is the join condition connecting the two tables; without it, `FROM` would produce a full cross join and every `salaries` row would be updated once per matching `employees` row (a classic and dangerous mistake). The remaining `AND` clauses are ordinary filters.

**⚠️ Warning:** In the `FROM`-based forms (PostgreSQL, SQL Server), **forgetting the join condition** between the updated table and the `FROM` table causes a cross join — every row in `salaries` gets updated once for *every* matching row in `employees`, and if multiple `employees` rows match, the final value depends on **whichever one the engine happens to apply last** (undefined/unspecified order) — a serious silent-correctness bug.

### 3.4.4 Safe Update Practices

1. **Always write and run the `SELECT` first**, using the exact same `WHERE` clause you intend to `UPDATE` with, and eyeball the row count and contents before switching `SELECT ... ` to `UPDATE ... SET ...`.
2. **Wrap it in a transaction:**
   ```sql
   BEGIN;
   UPDATE employees SET status = 'ACTIVE' WHERE status = 'ON_LEAVE';
   -- check row count reported, spot-check with a SELECT
   COMMIT;   -- or ROLLBACK; if something looks wrong
   ```
3. **Use `RETURNING`** (PostgreSQL/Oracle) or `OUTPUT` (SQL Server) to see exactly what changed, in the same statement, instead of trusting the change happened correctly.
4. **Count before you commit** — compare the row count `UPDATE` reports against your mental/`SELECT`-verified expectation.
5. In tools that support it (e.g., MySQL Workbench's "Safe Updates" mode), leave safety switches **on** in production-adjacent environments — they exist specifically to reject `UPDATE`/`DELETE` statements without a `WHERE` clause on a key column.

### 3.4.5 Common Mistakes

> **⚠️ Warning — the single most catastrophic UPDATE mistake:** forgetting `WHERE`.
> ```sql
> UPDATE employees SET status = 'TERMINATED';
> ```
> This has **no `WHERE` clause**, so it matches *every* row in the table — `UPDATE 16`, and all 16 employees, including the CTO, are now marked `TERMINATED`. There is no dialect-level guardrail against this by default; it is syntactically 100% valid. This is precisely why safe-update habits (3.4.4) exist.

Other common mistakes:
- Updating a column used in a `UNIQUE`/`CHECK` constraint without accounting for the constraint (e.g., trying to set two employees' `email` to the same value — will fail with a unique violation, same error shapes as 3.3.6).
- Using `=` when you meant a range, updating one row when you intended many (or vice versa) because the `WHERE` predicate was more/less selective than you thought — always verify with a `SELECT COUNT(*)` first.
- Forgetting that `UPDATE` re-evaluates `SET` expressions against the **pre-update** row values — `SET bonus = bonus * 1.10` is always based on the value *before* this statement ran, never a value set earlier in the same statement for a different row.

### 3.4.6 Practice Questions — UPDATE

1. Update Vikram Joshi's (`employee_id = 4`) `job_title` to `'Senior Software Engineer'`.
2. Give every `ACTIVE` employee in the Sales department (`department_id = 2`) the `job_title` suffix `' (Sales)'` — hint: you'll want string concatenation from Chapter 5, or try it with `||` now.
3. Set `status = 'ON_LEAVE'` for `employee_id = 6`, then write the `SELECT` you'd run first, before actually running the `UPDATE`, to confirm exactly one row would be affected.
4. Using a cross-table `UPDATE` (your dialect of choice), increase `hours_allocated` by 50 for every `employee_projects` row belonging to `project_id = 1`, but only for employees whose `job_title` is `'Software Engineer'`.
5. What would `UPDATE attendance SET status = 'PRESENT';` do if run with no `WHERE` clause? State the exact row count affected against the seed data, and why that's dangerous.
6. Write an `UPDATE` that corrects a typo: change `department_name` from `'HR'` to `'Human Resources'` for `department_id = 3`, and use `RETURNING` to confirm the change.
7. Using the Oracle-style correlated-subquery pattern, write an `UPDATE` that sets `bonus = 0` for every `salaries` row belonging to a `TERMINATED` employee.
8. Explain, in your own words, why `UPDATE ... FROM` without a join condition between the two tables is dangerous, referencing what a cross join does to row counts.

---

## 3.5 DELETE — Removing Data

**Simple explanation:** `DELETE` removes existing rows from a table.

**Technical explanation:** `DELETE` is a DML, row-oriented, fully transactional and (in PostgreSQL) trigger-aware statement. Like `UPDATE`, under MVCC it doesn't physically erase bytes immediately — it marks the row version as dead so it becomes invisible to new transactions, with space reclaimed later by `VACUUM`.

**Full syntax:**
```sql
DELETE FROM table_name
[WHERE condition];
```

### 3.5.1 Basic DELETE and DELETE with Conditions

**Example — remove one specific project assignment:**
```sql
DELETE FROM employee_projects
WHERE employee_id = 11 AND project_id = 4
RETURNING *;
```

**Expected output:**

| employee_id | project_id | role | hours_allocated |
|---|---|---|---|
| 11 | 4 | Coordinator | 200 |

This removes Isha Bhatt's `'Coordinator'` role on the `'Employee Wellness'` project — exactly the one row matching the composite condition.

**Example — DELETE driven by a subquery:**
```sql
DELETE FROM salaries
WHERE employee_id IN (SELECT employee_id FROM employees WHERE status = 'TERMINATED')
RETURNING *;
```

**Expected output:**

| salary_id | employee_id | base_salary | bonus | currency | effective_date |
|---|---|---|---|---|---|
| *(varies)* | 9 | 95000.00 | 10000.00 | USD | 2021-03-22 |

Only Meera Pillai (`employee_id = 9`) is `TERMINATED`, so only her one `salaries` row is removed.

> **⚠️ Warning:** Exactly like `UPDATE`, a `DELETE` with **no `WHERE` clause** removes **every row** in the table: `DELETE FROM attendance;` deletes all 10 seed rows. Syntactically valid, catastrophic if unintended. Apply the same safe-practice habits from 3.4.4 (run the equivalent `SELECT` first, wrap in a transaction, check the row count).

### 3.5.2 DELETE Using Joins/Subqueries

**Scenario:** Remove all `attendance` records belonging to employees currently `ON_LEAVE` (employee 5, Ananya Singh, has two such rows: `2024-01-01` and `2024-01-02`, both `status = 'LEAVE'`).

**[PostgreSQL] — `DELETE ... USING`:**
```sql
DELETE FROM attendance a
USING employees e
WHERE a.employee_id = e.employee_id
  AND e.status = 'ON_LEAVE'
RETURNING a.*;
```

**[MySQL] — multi-table DELETE:**
```sql
DELETE a
FROM attendance a
JOIN employees e ON a.employee_id = e.employee_id
WHERE e.status = 'ON_LEAVE';
```

**[SQL Server] — DELETE ... FROM ... JOIN:**
```sql
DELETE a
FROM attendance a
JOIN employees e ON a.employee_id = e.employee_id
WHERE e.status = 'ON_LEAVE';
```

**[Oracle] — correlated subquery:**
```sql
DELETE FROM attendance a
WHERE EXISTS (
    SELECT 1 FROM employees e
    WHERE e.employee_id = a.employee_id
      AND e.status = 'ON_LEAVE'
);
```

**Expected result (all four):** 2 rows deleted — both `attendance` rows for `employee_id = 5`.

**Line-by-line (PostgreSQL):** `USING employees e` is analogous to `UPDATE`'s `FROM` — it brings a second table into scope for the `WHERE` clause without deleting from it. The join condition `a.employee_id = e.employee_id` is essential for the same reason as in `UPDATE...FROM`: omit it, and every `attendance` row would be matched against every `ON_LEAVE` employee, deleting far more than intended (or erroring/duplicating depending on match cardinality).

### 3.5.3 Foreign Key Cascades

`salaries.employee_id`, `attendance.employee_id`, and `employee_projects.employee_id` are all declared `REFERENCES employees(employee_id) ON DELETE CASCADE` — deleting an employee automatically deletes their dependent rows in those tables. `employees.department_id` and `employees.manager_id`, by contrast, are `ON DELETE SET NULL` — deleting a department or a manager doesn't delete employees, it nulls out the reference.

**Example:**
```sql
DELETE FROM employees WHERE employee_id = 9 RETURNING *;
```

**What happens:** Meera Pillai's `employees` row is deleted directly. Because of `ON DELETE CASCADE`, PostgreSQL **automatically** also deletes her one `salaries` row (`95000.00` base, `10000.00` bonus, effective `2021-03-22`) — no separate `DELETE FROM salaries` statement needed, and no error about a dangling foreign key. She has no rows in `attendance`, `employee_projects`, or `managers`, so nothing else is touched.

> **Important Note:** Cascading deletes are powerful and dangerous in equal measure — a single `DELETE FROM employees WHERE department_id = 1;` would silently cascade-delete every Engineering employee's entire salary history and every attendance/project-assignment row tied to them, with **no separate confirmation step**. Always know your schema's `ON DELETE` behavior (Chapter 13, Constraints, covers this in full) before deleting from a table that other tables reference.

### 3.5.4 TRUNCATE

**Simple explanation:** `TRUNCATE` empties an entire table in one fast operation — it's `DELETE FROM table;` with no `WHERE` support, optimized for speed instead of row-by-row processing.

**Syntax:**
```sql
TRUNCATE TABLE table_name;
TRUNCATE TABLE table_name RESTART IDENTITY;   -- [PostgreSQL] also reset the SERIAL/IDENTITY sequence
TRUNCATE TABLE table_name CASCADE;            -- [PostgreSQL] also truncate tables with FKs pointing here
```

**Example:**
```sql
TRUNCATE TABLE attendance;
```
Removes all 10 seed `attendance` rows in a single, near-instant operation, regardless of table size.

### 3.5.5 DROP

**Simple explanation:** `DROP TABLE` removes the table **and its data and its definition** — after this, the table simply does not exist.

**Syntax:**
```sql
DROP TABLE table_name;
DROP TABLE IF EXISTS table_name;        -- no error if it doesn't exist
DROP TABLE table_name CASCADE;          -- [PostgreSQL] also drop dependent views/FKs
```

**Example:**
```sql
DROP TABLE attendance;
```
After this, `SELECT * FROM attendance;` fails with `ERROR: relation "attendance" does not exist` — the table, its rows, its indexes, and its constraints are all gone. If any other object (a view, a foreign key from another table) depends on it, PostgreSQL refuses the `DROP` unless you add `CASCADE`, which then drops those dependents too.

### 3.5.6 Practice Questions — DELETE

1. Delete the `employee_projects` row for `employee_id = 6, project_id = 2`, and verify with `RETURNING`.
2. Delete every `salaries` row with `effective_date` before `'2016-01-01'`.
3. Using a subquery, delete every `attendance` row belonging to an employee in the `Engineering` department.
4. Using your dialect of choice, write a cross-table `DELETE` that removes every `employee_projects` row for employees whose `status` is `'TERMINATED'`.
5. If you ran `DELETE FROM employees WHERE department_id = 4;`, list every table where rows would be cascade-deleted as a side effect, and every table where a column would instead become `NULL`.
6. What is the exact row count removed by `TRUNCATE TABLE attendance;` against the seed data?
7. After `DROP TABLE projects;`, what would happen if you then tried `SELECT * FROM employee_projects;`? (Consider the foreign key relationship — would the `DROP` even succeed without `CASCADE`?)
8. Explain the difference in outcome between `DELETE FROM salaries;` and `TRUNCATE TABLE salaries;` if your goal is simply "empty this table as fast as possible and I don't care about triggers."

---

## 3.6 DELETE vs. TRUNCATE vs. DROP — Deep Dive

These three are constantly confused by beginners because they can all "get rid of data," but they operate at completely different levels and have very different consequences.

| Aspect | `DELETE` | `TRUNCATE` | `DROP` |
|---|---|---|---|
| **Statement type** | DML | DDL (PostgreSQL treats it as DDL-like; MySQL/Oracle treat it fully as DDL) | DDL |
| **Supports `WHERE`** | Yes — can remove a subset | No — always all rows | N/A — removes the whole table |
| **Removes** | Matching rows only | All rows | Rows **and** the table structure itself |
| **Table/indexes/constraints survive?** | Yes, untouched | Yes, untouched — table still exists, empty | No — everything is gone |
| **Transactional / rollback-able** | Always (standard DML) | **[PostgreSQL]** yes, fully transactional. **[SQL Server]** yes, within an explicit transaction. **[MySQL]** no — causes an implicit commit, cannot be rolled back. **[Oracle]** no — DDL causes an implicit commit, cannot be rolled back. | Same pattern as `TRUNCATE`: transactional in PostgreSQL/SQL Server, auto-committing in MySQL/Oracle. |
| **Fires row-level triggers** | Yes | No, in every mainstream dialect (may fire statement-level triggers in PostgreSQL if explicitly defined `FOR EACH STATEMENT`) | No — table (and its triggers) cease to exist |
| **Effect on auto-increment / identity / sequence** | No effect — counter keeps climbing | **[PostgreSQL]** unchanged unless you say `RESTART IDENTITY`. **[MySQL]** always resets `AUTO_INCREMENT` to 1. **[SQL Server]** always resets the `IDENTITY` seed. **[Oracle]** identity columns are reset by default (behavior can vary by storage option/version). | Sequence/identity object tied to the table is dropped along with it entirely |
| **Locking** | Row-level locks, acquired incrementally as rows are processed | A single strong table-level lock (`ACCESS EXCLUSIVE` in PostgreSQL) — blocks all concurrent access, but only briefly | Same strong table-level lock, held for the duration of dropping the object |
| **Logging / WAL overhead** | Full row-by-row logging (every deleted row is individually logged, needed for MVCC/point-in-time recovery and to let triggers fire per row) | Minimal — logs page/file deallocation, not each row | Minimal — logs catalog/metadata changes, not row data |
| **Performance at scale (10M+ rows)** | Slow — proportional to row count, plus index maintenance per row | Near-instant regardless of table size | Near-instant regardless of table size |
| **Space reclaimed immediately?** | Not necessarily — PostgreSQL marks rows dead; `VACUUM` reclaims space later | Yes — file/pages deallocated immediately | Yes — the underlying storage is released |
| **Required privilege** | `DELETE` privilege on the table | `TRUNCATE` privilege **[PostgreSQL]** (a distinct grantable privilege from `DELETE`) or equivalent DDL-level permission in other engines | `DROP`/ownership privilege — typically the highest bar of the three |
| **Can be undone after commit?** | No (unless you have backups/point-in-time recovery) | No | No, and structurally harder to recover than the other two since metadata is gone too |

### Decision table — which one do I actually want?

| You want to... | Use |
|---|---|
| Remove a specific subset of rows matching a condition | `DELETE ... WHERE ...` |
| Remove all rows but keep using the table (and its structure) immediately afterward, and you don't need row-level triggers to fire | `TRUNCATE` |
| Remove all rows, but you need row-level `DELETE` triggers to fire for each row (e.g., an audit log trigger) | `DELETE` (no `WHERE`) — accept the performance cost, or restructure the trigger logic |
| Remove all rows and need it to be fully rollback-able mid-transaction, and you're on MySQL/Oracle | `DELETE`, not `TRUNCATE` (which auto-commits there) |
| Decommission a feature/table entirely — it should no longer exist | `DROP TABLE` |
| Reset an auto-increment counter back to 1 as part of clearing a table | `TRUNCATE ... RESTART IDENTITY` **[PostgreSQL]**, or plain `TRUNCATE` **[MySQL]/[SQL Server]** |
| Wipe a huge (100M-row) table as fast as possible and don't care about per-row triggers | `TRUNCATE` |

> **Important Note:** In PostgreSQL specifically, `TRUNCATE` and `DROP` ARE fully transactional (unlike MySQL/Oracle) — you genuinely can `BEGIN; TRUNCATE TABLE attendance; ROLLBACK;` and get every row back, because PostgreSQL supports transactional DDL. This is a notable and often-surprising PostgreSQL advantage; don't assume it carries over if you switch dialects.

---

## 3.7 Chapter Challenge — A Full CRUD Workflow

Put every concept from this chapter together in one realistic scenario. Work through it in order — each step depends on the previous one leaving the database in the expected state. Start from a **freshly loaded** `company_db` (reload the seed file if you've been experimenting).

**Scenario:** A new employee, **Kabir Malhotra**, joins the Engineering department (`department_id = 1`) on `2024-05-01` as a `'Software Engineer'`, reporting to Rahul Mehta (`employee_id = 2`). His email is `kabir.malhotra@company.com`. Track him through his first few months.

1. **INSERT** Kabir into `employees`, letting `status` default. Use `RETURNING` to capture his generated `employee_id`.
2. **INSERT** his starting salary into `salaries`: base salary `130000`, bonus `8000`, effective `2024-05-01`.
3. **INSERT** him into `employee_projects` for the `'Mobile App Revamp'` project (`project_id = 2`) with role `'Engineer'` and `hours_allocated = 200`.
4. **SELECT** a single row summarizing Kabir: his full name (as one calculated column), `job_title`, `department_id`, his salary's `base_salary + bonus AS total_comp`, and the `role` he holds on his project — joins aren't required yet if you query each table separately; a multi-table version is fair game once you've read Chapter 7.
5. After 3 months, Kabir gets a raise. **INSERT** a *new* `salaries` row for him (do not `UPDATE` the old one — remember, `salaries` is a history table) dated `2024-08-01` with base salary `145000`, bonus `10000`.
6. Using a `CASE` expression, **SELECT** Kabir's employment tenure bucket as of `'2024-09-24'`: `'New hire'` if hired within the last 6 months, `'Established'` otherwise. (You'll get exact date arithmetic in Chapter 5 — for now, reason it out by comparing `hire_date` to a literal cutoff date with `>=`/`<`.)
7. Kabir decides to go `ON_LEAVE`. **UPDATE** his `status` accordingly — write the confirming `SELECT` first, then the `UPDATE`.
8. Unfortunately, the `'Mobile App Revamp'` project assignment was a data-entry error — he was actually meant to be on `'Platform Migration'` (`project_id = 1`). **DELETE** the incorrect `employee_projects` row and **INSERT** the correct one (role `'Engineer'`, `hours_allocated = 200`).
9. Six months later, Kabir leaves the company. **UPDATE** his `status` to `'TERMINATED'` — do **not** delete his `employees` row (real systems almost never hard-delete people; they retain history).
10. Finally, write the **single `SELECT`** you'd run to prove the whole workflow succeeded: Kabir's current `status`, his most recent `salaries` row (by `effective_date`), and his current project assignment(s).

There is no answer key — this challenge is meant to be checked by running it yourself against a live `company_db` and confirming the row counts and values match what you expect at each step.

---

## Key Takeaways

- `SELECT` reads data and never modifies it; `*`, column lists, aliases, `DISTINCT`, expressions, and `CASE` all shape the **shape** of the output without touching stored data.
- `WHERE` filters rows using three-valued logic (`TRUE`/`FALSE`/`UNKNOWN`) — `NULL` comparisons are the single biggest source of "why did my query return nothing/everything" bugs. Always use `IS NULL`/`IS NOT NULL`, never `= NULL`.
- `AND` binds tighter than `OR`. When you mix them, **always** use explicit parentheses — don't trust memory (yours or a reviewer's).
- `NOT IN` silently returns zero rows the instant its list contains a `NULL` — treat it as unsafe against any nullable column or subquery until you've read Chapter 8.
- `INSERT` supports single-row, multi-row, and `INSERT ... SELECT` forms. **Omitting** a column lets its `DEFAULT` apply; explicitly inserting `NULL` bypasses the default and requires the column to be nullable.
- `RETURNING` **[PostgreSQL/Oracle]**, `OUTPUT` **[SQL Server]**, and `LAST_INSERT_ID()` **[MySQL]** all solve the same problem — getting back what was actually inserted — with meaningfully different capabilities.
- `UPDATE` and `DELETE` without a `WHERE` clause affect **every row** in the table, silently and validly. This is the single most dangerous CRUD mistake — always `SELECT` first, and prefer running inside a transaction you can `ROLLBACK`.
- Cross-table `UPDATE`/`DELETE` syntax genuinely differs by dialect: `UPDATE...FROM` **[PostgreSQL/SQL Server]**, `UPDATE...JOIN` **[MySQL]**, and correlated subqueries **[Oracle]** all express the same intent.
- `DELETE`, `TRUNCATE`, and `DROP` are three different tools at three different levels of destruction — row subset vs. all rows vs. the table itself — with real differences in transactionality, trigger behavior, locking, identity-counter resets, and performance at scale. Use the decision table in 3.6 to choose correctly.
- Foreign keys with `ON DELETE CASCADE`/`SET NULL` (as seen throughout `company_db`) mean a single `DELETE` can silently ripple across several tables — know your schema's cascade rules before you delete anything upstream of them.

## What's Next

Chapter 4 — **Sorting, Pagination & Result Processing** — picks up exactly where `SELECT` left off: you now know how to shape and filter a result set, but not yet how to control the **order** it comes back in (`ORDER BY`, sorting by multiple columns, `NULL` ordering, sorting by expressions/aliases) or how to slice it into pages (`LIMIT`/`OFFSET` **[PostgreSQL/MySQL]**, `FETCH FIRST` **[SQL Server/Oracle ANSI]**, `TOP` **[SQL Server]**, `ROWNUM`/`FETCH` **[Oracle]**) — essential for any application that shows data one screen at a time instead of dumping an entire table at once.
