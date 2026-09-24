# Chapter 4 — Sorting, Pagination & Result Processing

> **Part II — SQL Fundamentals** · Previous: [Chapter 3 — CRUD](03-crud.md) · Next: [Chapter 5 — Built-in Functions](05-functions.md)

Every example in this chapter runs against `company_db`, specifically the
`employees` table (16 rows), unless stated otherwise. If you haven't already,
load the database:

```bash
psql -f databases/company_db.sql
```

```sql
SET search_path TO company_db;
```

For reference, here is the full `employees` table exactly as seeded, sorted
by `employee_id` (the physical insertion order). Keep this table open in a
second window — nearly every example in this chapter re-sorts, slices, or
pages through these same 16 rows, and you should be able to predict the
output before you scroll down to check it.

| employee_id | first_name | last_name | hire_date  | job_title            | department_id | manager_id | status     |
|---|---|---|---|---|---|---|---|
| 1  | Aditi  | Rao      | 2015-03-01 | CTO                  | 1 | NULL | ACTIVE     |
| 2  | Rahul  | Mehta    | 2016-05-12 | Engineering Manager  | 1 | 1    | ACTIVE     |
| 3  | Sneha  | Kulkarni | 2017-01-20 | Senior Engineer      | 1 | 2    | ACTIVE     |
| 4  | Vikram | Joshi    | 2018-07-15 | Software Engineer    | 1 | 2    | ACTIVE     |
| 5  | Ananya | Singh    | 2019-09-01 | Software Engineer    | 1 | 2    | ON_LEAVE   |
| 6  | Karan  | Verma    | 2020-02-10 | Junior Engineer      | 1 | 3    | ACTIVE     |
| 7  | Priya  | Nair     | 2015-11-05 | Sales Manager        | 2 | 1    | ACTIVE     |
| 8  | Arjun  | Das      | 2017-04-18 | Sales Executive      | 2 | 7    | ACTIVE     |
| 9  | Meera  | Pillai   | 2021-03-22 | Sales Executive      | 2 | 7    | TERMINATED |
| 10 | Rohan  | Kapoor   | 2016-08-09 | HR Manager           | 3 | 1    | ACTIVE     |
| 11 | Isha   | Bhatt    | 2019-01-14 | HR Executive         | 3 | 10   | ACTIVE     |
| 12 | Nikhil | Gupta    | 2016-12-01 | Finance Manager      | 4 | 1    | ACTIVE     |
| 13 | Divya  | Shah     | 2018-06-25 | Accountant           | 4 | 12   | ACTIVE     |
| 14 | Rajesh | Iyer     | 2017-09-30 | Marketing Manager    | 5 | 1    | ACTIVE     |
| 15 | Pooja  | Reddy    | 2020-10-05 | Marketing Executive  | 5 | 14   | ACTIVE     |
| 16 | Aman   | Chawla   | 2022-01-10 | Software Engineer    | 1 | 2    | ACTIVE     |

> **Important Note.** `department_id`s map to: 1 = Engineering, 2 = Sales,
> 3 = HR, 4 = Finance, 5 = Marketing. `manager_id` is a self-referencing
> foreign key to `employees.employee_id`; row 1 (Aditi Rao, the CTO) has no
> manager, hence `NULL`.

---

## 4.1 Why This Chapter Exists

`SELECT` without `ORDER BY` gives you *a* set of rows — correct in content,
but in no promised order. The moment a human reads a report, or an API
returns "page 2 of results," or a dashboard shows a "top 10" list, order
stops being cosmetic and becomes part of the correctness contract. Chapter 3
taught you how to get the right *rows*. This chapter teaches you how to get
them in the right *order*, and — because real tables have millions of rows,
not sixteen — how to hand them out in efficient, well-defined *chunks*
(pagination) instead of dumping the entire result set at once.

By the end of this chapter you will be able to:

- Sort result sets on one or many columns, ascending or descending, and
  predict exactly how ties are broken.
- Explain how `NULL` behaves in a sort, and why that behavior differs across
  PostgreSQL, Oracle, MySQL, and SQL Server.
- Use every major pagination syntax: `LIMIT`/`OFFSET`, `FETCH FIRST ... ROWS
  ONLY`, `TOP`, and Oracle's `ROWNUM`/`ROW_NUMBER()`.
- Explain — mechanically, not just "because someone told me" — why
  `OFFSET`-based pagination gets slower as the offset grows, and implement
  the alternative: keyset (seek/cursor) pagination.
- Choose the right pagination strategy for a given real-world scenario (API,
  infinite scroll, admin table, CSV export).

---

## 4.2 `ORDER BY` — Sorting Result Sets

### 4.2.1 Simple Explanation

`ORDER BY` tells the database *in what order* to hand you the rows of your
result set. Without it, rows come back in whatever order the database
engine finds convenient — which might look sorted by accident, but is not
guaranteed to be, and can change between runs.

### 4.2.2 Technical Explanation

`ORDER BY` is a clause evaluated **after** the `FROM`, `WHERE`, `GROUP BY`,
and `HAVING` clauses have produced the logical result set, but conceptually
before `LIMIT`/`OFFSET` slice it. It accepts one or more sort keys — column
names, column positions, or expressions — each with an optional sort
direction (`ASC`/`DESC`) and, in some dialects, an optional null-ordering
modifier. The database compares rows key-by-key, using the second key only
to break ties left by the first, the third only to break ties left by the
first two, and so on.

### 4.2.3 Why It Exists

Relational theory treats a table as an **unordered set** of rows — there is
no built-in "row 3" the way there's a "row 3" in a spreadsheet. Physical
storage order is an implementation detail (insertion order, index order,
page layout, vacuum/reorg history) that the engine is free to change at any
time — during a `VACUUM`, an index rebuild, a replica failover, or a query
plan change. `ORDER BY` is the only mechanism the SQL language gives you to
impose a specific, guaranteed order on output. Without it, "guaranteed
order" simply does not exist, no matter how consistent it looks in testing.

### 4.2.4 Full Syntax Breakdown

```sql
SELECT column1, column2, ...
FROM table_name
[WHERE condition]
ORDER BY sort_expression1 [ASC | DESC] [NULLS FIRST | NULLS LAST],
         sort_expression2 [ASC | DESC] [NULLS FIRST | NULLS LAST],
         ...
[LIMIT ...] [OFFSET ...];
```

| Piece | Meaning |
|---|---|
| `sort_expression` | A column name, a column's ordinal position in the `SELECT` list (e.g., `ORDER BY 2`), an alias defined in `SELECT`, or an arbitrary expression (`ORDER BY salary * 12`). |
| `ASC` | Ascending order (smallest/earliest first). This is the default if omitted. |
| `DESC` | Descending order (largest/latest first). |
| `NULLS FIRST` / `NULLS LAST` | **[PostgreSQL/Oracle]** Explicitly control where `NULL` values sort, independent of `ASC`/`DESC`. Not standard syntax in MySQL/SQL Server (see §4.4). |
| Multiple expressions (comma-separated) | Each is applied, left to right, only to break ties left by the previous ones. |

> **Important Note.** `ORDER BY` can reference columns that are **not** in
> the `SELECT` list (unless the query uses `DISTINCT`, `GROUP BY`, or set
> operators like `UNION`, which impose their own restrictions — covered in
> later chapters). You can sort by a column you never display.

### 4.2.5 Examples: Simple → Complex

**Example 1 — Sort by a single column, ascending (default).**

```sql
SELECT employee_id, first_name, last_name, hire_date
FROM employees
ORDER BY hire_date;
```

Expected output (all 16 rows, earliest hire first):

| employee_id | first_name | last_name | hire_date  |
|---|---|---|---|
| 1  | Aditi  | Rao      | 2015-03-01 |
| 7  | Priya  | Nair     | 2015-11-05 |
| 2  | Rahul  | Mehta    | 2016-05-12 |
| 10 | Rohan  | Kapoor   | 2016-08-09 |
| 12 | Nikhil | Gupta    | 2016-12-01 |
| 3  | Sneha  | Kulkarni | 2017-01-20 |
| 8  | Arjun  | Das      | 2017-04-18 |
| 14 | Rajesh | Iyer     | 2017-09-30 |
| 13 | Divya  | Shah     | 2018-06-25 |
| 4  | Vikram | Joshi    | 2018-07-15 |
| 11 | Isha   | Bhatt    | 2019-01-14 |
| 5  | Ananya | Singh    | 2019-09-01 |
| 6  | Karan  | Verma    | 2020-02-10 |
| 15 | Pooja  | Reddy    | 2020-10-05 |
| 9  | Meera  | Pillai   | 2021-03-22 |
| 16 | Aman   | Chawla   | 2022-01-10 |

*Line-by-line:* `ORDER BY hire_date` with no direction keyword defaults to
`ASC`, so the engine compares `hire_date` values and emits the smallest
(earliest) date first. Because every `hire_date` in this seed data happens
to be unique, this sort is already fully deterministic — no ties to break.

**Example 2 — `DESC`: most recently hired employees first.**

```sql
SELECT employee_id, first_name, last_name, hire_date
FROM employees
ORDER BY hire_date DESC
LIMIT 5;
```

| employee_id | first_name | last_name | hire_date  |
|---|---|---|---|
| 16 | Aman  | Chawla | 2022-01-10 |
| 9  | Meera | Pillai | 2021-03-22 |
| 15 | Pooja | Reddy  | 2020-10-05 |
| 6  | Karan | Verma  | 2020-02-10 |
| 5  | Ananya| Singh  | 2019-09-01 |

This is the "5 newest hires" report — a common real-world pattern (recent
signups, recent orders, recent activity).

**Example 3 — Sort by column position.**

```sql
SELECT employee_id, first_name, hire_date
FROM employees
ORDER BY 3 DESC   -- 3rd column in the SELECT list = hire_date
LIMIT 3;
```

Same first three rows as Example 2. Ordinal sorting works, but is
**fragile**: reordering the `SELECT` list silently changes what you sort by.
Prefer naming the column or alias explicitly in production code.

**Example 4 — Sort by an alias.**

```sql
SELECT employee_id, first_name || ' ' || last_name AS full_name, hire_date
FROM employees
ORDER BY full_name;
```

`full_name` is a computed alias; most dialects (including PostgreSQL) allow
`ORDER BY` to reference it directly, because `ORDER BY` is logically
evaluated after the `SELECT` list is computed.

### 4.2.6 Internal Behavior

Conceptually, to satisfy `ORDER BY`, the engine must:

1. Evaluate `FROM`/`WHERE` (and `GROUP BY`/`HAVING` if present) to produce
   the full matching row set.
2. **Sort that entire matching set** by the sort key(s) — unless an index
   already stores the rows in (or reverse of) the requested order, in which
   case the engine can read the index in order and skip a separate sort
   step entirely.
3. Return rows to the client in that order (optionally sliced by
   `LIMIT`/`OFFSET` — see §4.6).

Step 2 is the important one: **sorting is, by default, a full-set operation
performed on the entire matching row set before any `LIMIT` is applied** —
you cannot sort only "the first 10 rows," because you don't know which 10
rows are first until the whole set has been ordered. In PostgreSQL, you can
see this named explicitly as a `Sort` node in `EXPLAIN` output, with a `Sort
Method` of either `quicksort` (fits in `work_mem`) or `external merge`
(spills to disk when the set is too large to sort in memory). We revisit
this "sort node" mechanism, and how indexes let the planner avoid it
entirely, in **Chapter 16 (Indexes)** and **Chapter 17 (Query Execution &
the Query Planner)** — for now, remember the rule: *no index that already
provides the requested order → full sort of the matching rows, every time.*

### 4.2.7 Common Mistakes

> **⚠️ Warning — `LIMIT`/`TOP`/`FETCH FIRST` without `ORDER BY` is
> non-deterministic.** `SELECT * FROM employees LIMIT 5;` will almost always
> return *some* 5 rows, often in what looks like insertion order — but the
> SQL standard makes **no such guarantee**. The engine may return rows in
> heap order, index order, or an order determined by a parallel scan that
> merges worker output non-deterministically. That order can silently
> change after a `VACUUM`, an `UPDATE` that moves a row, a replanned query,
> a version upgrade, or a change in table statistics — with no error, no
> warning, just different rows on your "first page" tomorrow. **Always pair
> `LIMIT`/`TOP`/`FETCH FIRST`/`ROWNUM` with an `ORDER BY` that fully
> determines row order** (see §4.2.9 on ties).

> **⚠️ Warning — MySQL's comma form of `LIMIT` reverses the arguments.**
> **[MySQL]** `LIMIT 5, 10` means *skip 5, take 10* (i.e., `OFFSET 5 LIMIT
> 10`), while `LIMIT 10 OFFSET 5` means the same thing written the "normal"
> way. Mixing these up is a frequent source of off-by-a-page bugs. Prefer
> the explicit `LIMIT n OFFSET m` form for readability.

### 4.2.8 Edge Cases

- **`ORDER BY` on an expression that isn't in `SELECT`** is legal for plain
  `SELECT` queries: `SELECT employee_id FROM employees ORDER BY hire_date;`
  works even though `hire_date` isn't displayed.
- **Sorting text is collation-dependent.** `ORDER BY last_name` compares
  strings using the database/column's collation, which determines
  case-sensitivity and locale-specific ordering (e.g., whether `'Bhatt'`
  sorts before or after `'bhatt'`, or how accented characters compare).
  Collations are covered in depth in later chapters on internationalization
  and advanced types; for now, know that "alphabetical" is not one universal
  rule.
- **Sorting on a column with `NULL`s** requires the rules in §4.4 below.

---

## 4.3 Multi-Column Sorting and How Ties Are Broken

### 4.3.1 Simple Explanation

You can sort by more than one column. The first column decides the primary
order; any rows that tie on the first column get sorted among themselves by
the second column; any that still tie get sorted by the third; and so on.

### 4.3.2 Technical Explanation

Formally, `ORDER BY k1, k2, ..., kn` establishes a total order using
**lexicographic comparison** of the key tuples `(k1, k2, ..., kn)`: two rows
are compared on `k1` first; if and only if `k1` is equal do they get
compared on `k2`; and so forth. If, after exhausting all listed keys, two
rows are still equal on every key, their relative order is **unspecified**
— the engine may emit them in either order, and that order is not
guaranteed to be stable across executions.

### 4.3.3 Full Syntax Breakdown

```sql
ORDER BY column_a ASC, column_b DESC, column_c ASC
```

Each column gets its **own independent** `ASC`/`DESC` — you cannot apply one
direction to a whole comma-list; direction is per-key.

### 4.3.4 Examples

**Example 1 — Group by department, then by hire date within department.**

```sql
SELECT employee_id, first_name, department_id, hire_date
FROM employees
ORDER BY department_id ASC, hire_date ASC;
```

| employee_id | first_name | department_id | hire_date  |
|---|---|---|---|
| 1  | Aditi  | 1 | 2015-03-01 |
| 2  | Rahul  | 1 | 2016-05-12 |
| 3  | Sneha  | 1 | 2017-01-20 |
| 4  | Vikram | 1 | 2018-07-15 |
| 5  | Ananya | 1 | 2019-09-01 |
| 6  | Karan  | 1 | 2020-02-10 |
| 16 | Aman   | 1 | 2022-01-10 |
| 7  | Priya  | 2 | 2015-11-05 |
| 8  | Arjun  | 2 | 2017-04-18 |
| 9  | Meera  | 2 | 2021-03-22 |
| 10 | Rohan  | 3 | 2016-08-09 |
| 11 | Isha   | 3 | 2019-01-14 |
| 12 | Nikhil | 4 | 2016-12-01 |
| 13 | Divya  | 4 | 2018-06-25 |
| 14 | Rajesh | 5 | 2017-09-30 |
| 15 | Pooja  | 5 | 2020-10-05 |

*Line-by-line:* `department_id ASC` groups all of department 1 together,
then department 2, etc. (departments only "look grouped" here because
`department_id` is being sorted, not because `GROUP BY` was used — true
aggregation is Chapter 6). Within each department block, `hire_date ASC`
orders the tenure of employees, breaking every tie department 1's seven
rows would otherwise have on `department_id` alone.

**Example 2 — A real tie, broken deterministically.**

The `job_title` column has genuine duplicates: three employees hold
"Software Engineer" (4, 5, 16) and two hold "Sales Executive" (8, 9).

```sql
SELECT employee_id, first_name, job_title, hire_date
FROM employees
ORDER BY job_title ASC, hire_date ASC;
```

| employee_id | first_name | job_title            | hire_date  |
|---|---|---|---|
| 13 | Divya  | Accountant           | 2018-06-25 |
| 1  | Aditi  | CTO                  | 2015-03-01 |
| 2  | Rahul  | Engineering Manager  | 2016-05-12 |
| 12 | Nikhil | Finance Manager      | 2016-12-01 |
| 11 | Isha   | HR Executive         | 2019-01-14 |
| 10 | Rohan  | HR Manager           | 2016-08-09 |
| 6  | Karan  | Junior Engineer      | 2020-02-10 |
| 15 | Pooja  | Marketing Executive  | 2020-10-05 |
| 14 | Rajesh | Marketing Manager    | 2017-09-30 |
| 8  | Arjun  | Sales Executive      | 2017-04-18 |
| 9  | Meera  | Sales Executive      | 2021-03-22 |
| 7  | Priya  | Sales Manager        | 2015-11-05 |
| 3  | Sneha  | Senior Engineer      | 2017-01-20 |
| 4  | Vikram | Software Engineer    | 2018-07-15 |
| 5  | Ananya | Software Engineer    | 2019-09-01 |
| 16 | Aman   | Software Engineer    | 2022-01-10 |

*Line-by-line:* `job_title ASC` sorts alphabetically (`Accountant` before
`CTO` before `Engineering Manager`, ...). Where `job_title` ties — "Sales
Executive" (rows 8, 9) and "Software Engineer" (rows 4, 5, 16) — the second
key, `hire_date ASC`, breaks the tie, so within each duplicated title the
longer-tenured employee appears first. Because `hire_date` happens to be
unique across the whole table, this two-column sort is now **fully
deterministic**: run this query a thousand times, get this exact row order
every time.

**Example 3 — Sort that mixes directions per column.**

```sql
SELECT employee_id, first_name, status, hire_date
FROM employees
ORDER BY status ASC, hire_date DESC;
```

Groups rows by `status` alphabetically (`ACTIVE`, `ON_LEAVE`, `TERMINATED`
— 'A' < 'O' < 'T'), and *within* each status shows the most recently hired
employee first. `ACTIVE` sorts first with 14 rows (newest hire, employee 16,
first among them), followed by the single `ON_LEAVE` row (employee 5), then
the single `TERMINATED` row (employee 9) — since `DESC` only affects
ordering within a status group, not which group comes first.

### 4.3.5 Common Mistakes

> **⚠️ Warning — omitting a tiebreaker leaves order unspecified, even if it
> "looks" stable.** `ORDER BY department_id` alone, with 7 rows sharing
> `department_id = 1`, does not promise those 7 rows will appear in
> `employee_id` order every time — it only promises all department-1 rows
> come before or after other departments, per the sort direction. If your
> application logic (or your pagination scheme — see §4.9–§4.11) depends on
> a stable order among ties, **add an explicit, unique tiebreaker column**
> (commonly the primary key) as the last sort key.

### 4.3.6 Edge Cases

- If your last sort key is still not unique (e.g., two employees somehow
  share both `job_title` and `hire_date`), the order among those rows
  remains unspecified. The only bulletproof tiebreaker is a column (or
  column combination) with a `UNIQUE` or `PRIMARY KEY` constraint —
  `employee_id` in this schema.
- Sorting by more keys than necessary is not "more correct," just more
  explicit — but it costs nothing meaningful and removes ambiguity, so it's
  cheap insurance for pagination-critical queries.

---

## 4.4 `NULL` Ordering

### 4.4.1 Simple Explanation

`NULL` means "unknown/missing," so where should it sort — before the
smallest value, after the largest, or somewhere dialect-specific? SQL
dialects disagree, and this is one of the most common cross-database
portability surprises.

### 4.4.2 Technical Explanation

The SQL standard leaves default `NULL` placement implementation-defined but
requires that `NULLS FIRST`/`NULLS LAST` be honored when specified. In
practice, database vendors split into two camps:

| Dialect | Default: `NULL` treated as... | Default `ASC` places `NULL`... | Default `DESC` places `NULL`... | Explicit `NULLS FIRST/LAST` supported? |
|---|---|---|---|---|
| **[PostgreSQL]** | larger than any value | **last** | **first** | Yes — native syntax |
| **[Oracle]** | larger than any value | **last** | **first** | Yes — native syntax |
| **[MySQL]** | smaller than any value | **first** | **last** | No native syntax — emulate (see below) |
| **[SQL Server]** | smaller than any value | **first** | **last** | No native syntax — emulate (see below) |

> **⚠️ Warning.** This is a genuine, frequently-tested divergence: the exact
> same query, `SELECT ... ORDER BY manager_id;`, places `NULL` rows at
> **opposite ends** of the result set depending on whether it runs on
> PostgreSQL/Oracle versus MySQL/SQL Server. Never assume `NULL` placement;
> if it matters, make it explicit.

### 4.4.3 Why It Exists

`NULL` is not a value that can be compared with `<`/`>` (any comparison
against `NULL` yields `NULL`, not `true`/`false` — see Chapter 5's
three-valued logic discussion). Sorting, however, requires a total order,
so every engine must special-case `NULL` and pick *some* placement rule.
Postgres/Oracle chose to treat `NULL` as conceptually "larger than
everything" (consistent with `NULL` often meaning "not yet set / to be
determined, ranks at the end"); MySQL/SQL Server chose "smaller than
everything." Neither is more "correct" per the standard — it's a documented
vendor choice you must simply know.

### 4.4.4 Full Syntax Breakdown

```sql
ORDER BY column [ASC | DESC] [NULLS FIRST | NULLS LAST]
```

**[PostgreSQL/Oracle]** native. **[MySQL/SQL Server]** — no `NULLS
FIRST/LAST` keywords exist; emulate with an explicit "is this null" flag
sorted first:

```sql
-- MySQL / SQL Server emulation of "NULLS LAST"
ORDER BY (column IS NULL), column ASC        -- MySQL: FALSE=0 sorts before TRUE=1
```

```sql
-- SQL Server emulation of "NULLS LAST"
ORDER BY CASE WHEN column IS NULL THEN 1 ELSE 0 END, column ASC
```

### 4.4.5 Examples

`employees.manager_id` is `NULL` only for row 1 (Aditi Rao, the CTO — she
has no manager). This is our running example.

**Example 1 — Default ASC ordering [PostgreSQL].**

```sql
SELECT employee_id, first_name, manager_id
FROM employees
ORDER BY manager_id, employee_id;
```

(`employee_id` added purely as a tiebreaker — several employees share a
`manager_id`, per §4.3.5.)

| employee_id | first_name | manager_id |
|---|---|---|
| 2  | Rahul  | 1 |
| 7  | Priya  | 1 |
| 10 | Rohan  | 1 |
| 12 | Nikhil | 1 |
| 14 | Rajesh | 1 |
| 3  | Sneha  | 2 |
| 4  | Vikram | 2 |
| 5  | Ananya | 2 |
| 16 | Aman   | 2 |
| 6  | Karan  | 3 |
| 8  | Arjun  | 7 |
| 9  | Meera  | 7 |
| 11 | Isha   | 10 |
| 13 | Divya  | 12 |
| 15 | Pooja  | 14 |
| 1  | Aditi  | **NULL** |

*Line-by-line:* Non-`NULL` `manager_id` values sort ascending (1, 2, 3, 7,
10, 12, 14), and the one `NULL` row — Aditi, who reports to no one — lands
**last**, because PostgreSQL's default for `ASC` is `NULLS LAST`.

**Example 2 — Explicit `NULLS FIRST` [PostgreSQL/Oracle].**

```sql
SELECT employee_id, first_name, manager_id
FROM employees
ORDER BY manager_id NULLS FIRST, employee_id;
```

Identical to Example 1 except row 1 (Aditi, `NULL`) now appears **first**,
before manager_id = 1.

**Example 3 — Same query, MySQL/SQL Server default behavior.**

**[MySQL]** / **[SQL Server]**

```sql
SELECT employee_id, first_name, manager_id
FROM employees
ORDER BY manager_id, employee_id;
```

On these two engines, the exact same SQL text places Aditi (`manager_id
IS NULL`) **first**, not last — because both treat `NULL` as the smallest
possible value by default. The other 15 rows appear in the same relative
order as Example 1.

**Example 4 — Portable "NULLS LAST" on MySQL.**

```sql
-- MySQL: force NULL manager_id to sort last, matching Postgres's default
SELECT employee_id, first_name, manager_id
FROM employees
ORDER BY (manager_id IS NULL), manager_id, employee_id;
```

`(manager_id IS NULL)` evaluates to `0` for non-null rows and `1` for the
null row; sorting on that boolean expression first pushes all `NULL` rows
to the end, replicating PostgreSQL/Oracle's default without needing
`NULLS LAST` syntax that MySQL doesn't have.

### 4.4.6 Common Mistakes

- Assuming `NULL`s "just disappear" from a sort — they don't; they always
  land somewhere, and where depends on dialect and direction.
- Forgetting that `NULLS FIRST`/`NULLS LAST` is independent of `ASC`/`DESC`:
  you can write `ORDER BY col DESC NULLS LAST`, which is a legitimate and
  sometimes-needed combination (largest-to-smallest, but nulls still at the
  bottom).
- Porting a query from PostgreSQL to MySQL (or vice versa) without checking
  `NULL`-containing sort columns — a very common source of "works on my
  database, breaks in production" bugs when the target database differs.

### 4.4.7 Edge Cases

- A column that is `NOT NULL` (like `hire_date` in this schema) never
  triggers any of this — the rules only matter for nullable columns.
  `manager_id` is nullable; `hire_date` is not.
- Multiple `NULL`s in the same sort column are, among themselves,
  unordered — `NULL = NULL` is not `true` in SQL's three-valued logic, so
  ties among nulls still need a tiebreaker column if their relative order
  matters (not observable in this seed data, since only one row has a
  `NULL` `manager_id`, but common in larger tables).

---

## 4.5 `LIMIT` / `OFFSET`

### 4.5.1 Simple Explanation

`LIMIT` caps how many rows come back. `OFFSET` skips a number of rows before
starting to return them. Together, they let you carve a large sorted result
set into "pages."

### 4.5.2 Technical Explanation

**[PostgreSQL]** / **[MySQL]** implement `LIMIT`/`OFFSET` as a post-sort
row-count restriction: logically, the full ordered result set is computed,
`OFFSET` rows are skipped from the front, and up to `LIMIT` rows are
returned starting from there. (The *physical* execution can often be
smarter than "materialize everything then skip" — see the internal-behavior
and performance deep dive in §4.10 — but the *logical* semantics are always
"skip N, then take M from the ordered set.")

### 4.5.3 Full Syntax Breakdown

**[PostgreSQL]**

```sql
SELECT ...
FROM ...
ORDER BY ...
LIMIT { count | ALL }
OFFSET start;
```

- `LIMIT count` — return at most `count` rows. `LIMIT ALL` (or omitting
  `LIMIT`) means no cap.
- `OFFSET start` — skip the first `start` rows. `OFFSET 0` (or omitting
  `OFFSET`) means skip nothing.
- Either clause is optional and independent; PostgreSQL accepts them in
  either order in the query text, though `LIMIT ... OFFSET ...` is the
  conventional order.

**[MySQL]**

```sql
SELECT ...
ORDER BY ...
LIMIT count OFFSET start;      -- explicit form
-- or, equivalently:
LIMIT start, count;            -- comma form: start FIRST, count SECOND
```

> **⚠️ Warning.** The two MySQL forms put `start` and `count` in *opposite
> positions* relative to their keywords. `LIMIT 10 OFFSET 5` and
> `LIMIT 5, 10` are equivalent (skip 5, take 10) — but `LIMIT 10, 5` is
> **not** the same as either (it skips 10, takes 5). Prefer the
> `OFFSET`-keyword form for clarity.

### 4.5.4 Examples: Building a 5-Row-Per-Page Paginator

All examples use our fully-deterministic sort key from §4.2: `hire_date,
employee_id` (16 total rows → 4 pages of 5, last page partial).

**Page 1:**

```sql
SELECT employee_id, first_name, hire_date
FROM employees
ORDER BY hire_date, employee_id
LIMIT 5 OFFSET 0;
```

| employee_id | first_name | hire_date  |
|---|---|---|
| 1  | Aditi  | 2015-03-01 |
| 7  | Priya  | 2015-11-05 |
| 2  | Rahul  | 2016-05-12 |
| 10 | Rohan  | 2016-08-09 |
| 12 | Nikhil | 2016-12-01 |

**Page 2** (`OFFSET 5`):

```sql
SELECT employee_id, first_name, hire_date
FROM employees
ORDER BY hire_date, employee_id
LIMIT 5 OFFSET 5;
```

| employee_id | first_name | hire_date  |
|---|---|---|
| 3  | Sneha  | 2017-01-20 |
| 8  | Arjun  | 2017-04-18 |
| 14 | Rajesh | 2017-09-30 |
| 13 | Divya  | 2018-06-25 |
| 4  | Vikram | 2018-07-15 |

**Page 3** (`OFFSET 10`):

| employee_id | first_name | hire_date  |
|---|---|---|
| 11 | Isha   | 2019-01-14 |
| 5  | Ananya | 2019-09-01 |
| 6  | Karan  | 2020-02-10 |
| 15 | Pooja  | 2020-10-05 |
| 9  | Meera  | 2021-03-22 |

**Page 4** (`OFFSET 15`) — only 1 row remains:

```sql
SELECT employee_id, first_name, hire_date
FROM employees
ORDER BY hire_date, employee_id
LIMIT 5 OFFSET 15;
```

| employee_id | first_name | hire_date  |
|---|---|---|
| 16 | Aman | 2022-01-10 |

**Edge case — `OFFSET` beyond the result count:**

```sql
SELECT employee_id, first_name, hire_date
FROM employees
ORDER BY hire_date, employee_id
LIMIT 5 OFFSET 20;
```

Returns **zero rows** — not an error. This is important defensive-coding
knowledge: an API that lets a client request "page 5" of a 4-page result set
should treat an empty result as "past the end," not a bug.

### 4.5.5 Internal Behavior

`LIMIT`/`OFFSET` is evaluated logically *after* `ORDER BY` produces a fully
sorted set — meaning, absent an index that already provides the sort order,
the database still has to sort (or partially sort, via a top-N heap-sort
optimization many planners apply) the *entire* matching set, then discard
the first `OFFSET` rows, before it can return your `LIMIT` rows. This is
the seed of the performance problem explored in depth in §4.10 — skipped
rows are not free just because they're not returned to you.

### 4.5.6 Common Mistakes

> **⚠️ Warning — `LIMIT`/`OFFSET` without `ORDER BY` is doubly dangerous.**
> Not only is the row order unspecified (§4.2.7), but *which* rows land on
> which "page" can change between requests, meaning a client paging through
> "pages" 1, 2, 3 with no `ORDER BY` might see the same row twice, or miss a
> row entirely, purely because the server picked a different physical scan
> order for query #2.

### 4.5.7 Edge Cases

- `LIMIT 0` returns zero rows immediately; it's occasionally used as a fast
  way to validate query syntax/columns without pulling any data.
- Negative values for `LIMIT`/`OFFSET` are a syntax/runtime error in
  PostgreSQL (`OFFSET` must be `>= 0`, negative `LIMIT` values also error
  outside of `LIMIT ALL`/`LIMIT -1`-style engine-specific carve-outs).
- Pagination stability across pages **requires a stable sort** — if the
  underlying data changes between fetching page 1 and page 2 (a new row is
  inserted with a `hire_date` that lands in the already-returned range),
  offset-based paging can show duplicate or skipped rows across pages. This
  is discussed further in the OFFSET vs. keyset comparison (§4.12).

---

## 4.6 `FETCH FIRST ... ROWS ONLY` (Standard SQL)

### 4.6.1 Simple Explanation

This is the ANSI/ISO SQL-standard way to say "give me only the first N
rows," supported (in some form) by PostgreSQL, Oracle 12c+, and SQL Server
2012+.

### 4.6.2 Full Syntax Breakdown

**[PostgreSQL/Oracle/SQL Server]**

```sql
SELECT ...
FROM ...
ORDER BY ...
OFFSET start { ROW | ROWS }
FETCH { FIRST | NEXT } count { ROW | ROWS } ONLY;
```

- `OFFSET` is optional (defaults to 0) and must come *before* `FETCH` if
  both are present.
- `FIRST` and `NEXT` are interchangeable keywords (purely readability —
  "fetch the first 10" vs. "fetch the next 10 after an offset").
- `ROW`/`ROWS` are interchangeable singular/plural forms.
- `ONLY` is required in the standard form (a `WITH TIES` variant exists in
  some engines to include additional rows tied with the last row on the
  sort key — covered as an advanced pattern in Chapter 31).

### 4.6.3 Examples

**Example 1 — First 5 rows, standard syntax [PostgreSQL].**

```sql
SELECT employee_id, first_name, hire_date
FROM employees
ORDER BY hire_date, employee_id
FETCH FIRST 5 ROWS ONLY;
```

Produces the identical result to Page 1 in §4.5.4.

**Example 2 — Offset + fetch, page 2 equivalent.**

```sql
SELECT employee_id, first_name, hire_date
FROM employees
ORDER BY hire_date, employee_id
OFFSET 5 ROWS
FETCH NEXT 5 ROWS ONLY;
```

Produces the identical result to Page 2 in §4.5.4 — `OFFSET 5 ROWS FETCH
NEXT 5 ROWS ONLY` is the standard-SQL spelling of `LIMIT 5 OFFSET 5`.

**Example 3 — SQL Server, same pattern.**

**[SQL Server]** — note SQL Server *requires* an `ORDER BY` for
`OFFSET`/`FETCH` to be legal at all (it errors without one):

```sql
SELECT employee_id, first_name, hire_date
FROM company_db.employees
ORDER BY hire_date, employee_id
OFFSET 5 ROWS FETCH NEXT 5 ROWS ONLY;
```

> **Important Note.** SQL Server enforcing a mandatory `ORDER BY` for
> `OFFSET`/`FETCH` is a good design decision the standard doesn't force on
> everyone — it structurally prevents the "paginating an unordered result"
> mistake from §4.5.6.

### 4.6.4 When to Use

Prefer `OFFSET ... FETCH` over vendor-proprietary `LIMIT`/`TOP` when writing
SQL you intend to be portable across PostgreSQL, Oracle, and SQL Server —
it's understood natively by all three (Oracle since 12c, SQL Server since
2012). MySQL, notably, does **not** support this standard syntax as of
current stable releases and requires `LIMIT`/`OFFSET` instead.

---

## 4.7 `TOP` **[SQL Server]**

### 4.7.1 Simple Explanation

`TOP` is SQL Server's (and older Sybase-lineage) way of limiting row count —
conceptually similar to `LIMIT`, but positioned right after `SELECT`
instead of at the end of the query.

### 4.7.2 Full Syntax Breakdown

```sql
SELECT TOP (n) [PERCENT] [WITH TIES]
       column_list
FROM table_name
[WHERE ...]
ORDER BY ...;
```

- `TOP (n)` — return at most `n` rows.
- `TOP (n) PERCENT` — return the top `n` percent of the result set's rows
  (rounded up).
- `WITH TIES` — if the last included row is tied on the `ORDER BY` key with
  subsequent rows, include those too (can return more than `n` rows).
- `TOP` has **no built-in offset/skip** capability — it can only take from
  the front. To paginate with `TOP`, you must combine it with `OFFSET
  ... FETCH` (§4.6) instead, or use `ROW_NUMBER()` (§4.8.4).

### 4.7.3 Examples

**Example 1 — Top 5 earliest hires.**

```sql
SELECT TOP (5) employee_id, first_name, hire_date
FROM company_db.employees
ORDER BY hire_date, employee_id;
```

Same 5 rows as §4.5.4's Page 1.

**Example 2 — `WITH TIES` on a column that actually has duplicates.**

```sql
SELECT TOP (1) WITH TIES employee_id, first_name, job_title
FROM company_db.employees
ORDER BY job_title;   -- 'Accountant' is alphabetically first, and unique
```

On `job_title`, `'Accountant'` (Divya, employee 13) is alphabetically first
and unique, so `WITH TIES` returns just that one row here. Contrast with:

```sql
SELECT TOP (3) WITH TIES employee_id, first_name, job_title
FROM company_db.employees
ORDER BY job_title DESC;   -- 'Software Engineer' is alphabetically last, and NOT unique
```

Ordering `job_title DESC`, `'Software Engineer'` sorts last (alphabetically
highest) and is held by 3 employees (4, 5, 16). `TOP (3) WITH TIES` would
request 3 rows but must include *all* rows tied with the 3rd-ranked value —
since all three "Software Engineer" rows tie for ranks 1–3, exactly those 3
rows come back (4, 5, 16, order among them still needing `hire_date` as a
secondary key to be deterministic).

### 4.7.4 Common Mistakes

- Forgetting `TOP` needs parentheses around a variable/parameter in modern
  T-SQL (`TOP (@n)`) — the no-parens form (`TOP @n`) is legacy syntax.
- Assuming `TOP` supports skipping rows the way `LIMIT`/`OFFSET` does — it
  doesn't; reach for `OFFSET ... FETCH` for true pagination in SQL Server.

---

## 4.8 `ROWNUM` and `ROW_NUMBER()` **[Oracle]** — and the Generic Window-Function Pattern

### 4.8.1 Simple Explanation

Oracle historically had no `LIMIT`; instead it exposed a pseudo-column,
`ROWNUM`, numbering rows *as they are produced by the query*. This behaves
very differently from `LIMIT`, and misusing it is one of the most famous
Oracle gotchas.

### 4.8.2 Technical Explanation

`ROWNUM` is assigned to each row **as it is fetched from the source**,
before that row is necessarily placed into its final `ORDER BY` position in
the *same* query block. That means a `WHERE ROWNUM <= n` filter combined
with an `ORDER BY` in one query block filters on the pre-sort row number,
not the post-sort rank — a classic trap.

> **⚠️ Warning — the classic Oracle `ROWNUM` bug.**
> ```sql
> -- WRONG: does NOT return the 5 earliest hires
> SELECT employee_id, first_name, hire_date
> FROM employees
> WHERE ROWNUM <= 5
> ORDER BY hire_date;
> ```
> This filters to *some* 5 rows in whatever order Oracle happens to fetch
> them (e.g., table/heap scan order), assigns them `ROWNUM` 1–5, discards
> everything else, **and only then** sorts those already-arbitrary 5 rows by
> `hire_date`. The 5 rows you get are not guaranteed to be the 5 earliest
> hires at all.

**Correct pattern — sort first, in an inner query; apply `ROWNUM` in an
outer query:**

```sql
SELECT employee_id, first_name, hire_date
FROM (
    SELECT employee_id, first_name, hire_date
    FROM employees
    ORDER BY hire_date, employee_id
)
WHERE ROWNUM <= 5;
```

Here the inner query fully sorts all 16 rows first; the outer query then
applies `ROWNUM` to the *already-sorted* result, correctly yielding the 5
earliest hires (same output as §4.5.4 Page 1).

**Offset-style pagination with `ROWNUM` (pre-12c Oracle)** requires nesting
twice — once to sort and number, once to filter the range:

```sql
SELECT employee_id, first_name, hire_date
FROM (
    SELECT employee_id, first_name, hire_date,
           ROWNUM AS rn
    FROM (
        SELECT employee_id, first_name, hire_date
        FROM employees
        ORDER BY hire_date, employee_id
    )
    WHERE ROWNUM <= 10        -- upper bound of page 2 (rows 1-10)
)
WHERE rn > 5;                  -- lower bound: skip first 5 (page 1)
```

This gives exactly Page 2 from §4.5.4 (employees 3, 8, 14, 13, 4). Oracle
12c and later supports the much simpler standard `OFFSET ... FETCH` syntax
from §4.6 — use that instead of the double-nested `ROWNUM` pattern on
modern Oracle versions; the nested form exists mainly to read legacy code.

### 4.8.3 Why It Exists

`ROWNUM` predates Oracle's adoption of the ANSI `OFFSET`/`FETCH` standard
(introduced in Oracle 12c, 2013). It's a leftover of an earlier era of
Oracle SQL, kept for backward compatibility; you will still see it
constantly in legacy Oracle codebases and interview questions, which is why
it's covered here even though `FETCH FIRST` (§4.6) is the modern,
preferred syntax on Oracle 12c+.

### 4.8.4 `ROW_NUMBER()` — The Portable, Modern Alternative

`ROW_NUMBER()` is a **window function** (deep-dived in Chapter 10) available
in PostgreSQL, MySQL 8.0+, Oracle, and SQL Server alike. Unlike `ROWNUM`, it
is computed **after** the `ORDER BY` inside its own `OVER (...)` clause is
applied, so it does not have the pre-sort-numbering trap:

```sql
SELECT employee_id, first_name, hire_date, rn
FROM (
    SELECT employee_id, first_name, hire_date,
           ROW_NUMBER() OVER (ORDER BY hire_date, employee_id) AS rn
    FROM employees
) ranked
WHERE rn BETWEEN 6 AND 10;   -- "page 2" of 5-row pages
```

| employee_id | first_name | hire_date  | rn |
|---|---|---|---|
| 3  | Sneha  | 2017-01-20 | 6  |
| 8  | Arjun  | 2017-04-18 | 7  |
| 14 | Rajesh | 2017-09-30 | 8  |
| 13 | Divya  | 2018-06-25 | 9  |
| 4  | Vikram | 2018-07-15 | 10 |

Identical to Page 2 in §4.5.4 — confirming `ROW_NUMBER()`-based pagination,
`OFFSET`/`LIMIT`, and `FETCH`/`OFFSET` are all logically equivalent
expressions of the same "page 2" concept. `ROW_NUMBER()` becomes especially
valuable when you need pagination logic embedded *inside* a larger query
(e.g., "top 3 highest-paid employees per department" — impossible with
plain `LIMIT`, trivial with `ROW_NUMBER() OVER (PARTITION BY department_id
...)`, which is exactly what Chapter 10 covers).

---

## 4.9 General Pagination Patterns: Page Number vs. Cursor

Before the deep dive, it's worth naming the two *architectural* families
every pagination syntax above ultimately serves:

1. **Offset/page-number pagination** — the client says "give me page N" (or
   equivalently, "skip S rows"). Implemented via `LIMIT/OFFSET`,
   `OFFSET/FETCH`, `TOP` + manual offset tricks, or nested `ROWNUM`/
   `ROW_NUMBER()` range filters. Simple to reason about, supports "jump to
   page 7" directly, but — as §4.10 shows — degrades as the offset grows.

2. **Keyset (seek/cursor) pagination** — the client says "give me the rows
   that come after *this specific row* I already saw." Implemented with a
   `WHERE` filter on the sort key(s) plus `LIMIT`, no `OFFSET` at all.
   Doesn't support "jump to page 7" without extra bookkeeping, but its
   performance is **flat regardless of how deep into the result set you
   are** — this is the subject of the required deep dive below.

Most systems you'll encounter (REST API `page`/`per_page` query params vs.
`next_cursor` tokens; infinite-scroll feeds vs. numbered admin tables) map
directly onto one of these two families.

---

## 4.10 Deep Dive — Why `OFFSET` Pagination Becomes Slow

### 4.10.1 The Mechanical Problem

Consider paging deep into a large, hypothetical version of this same table
— imagine `employees` scaled up to 500,000 rows (the real seed table only
has 16, so the *cost* difference described here isn't observable on it
directly, but the *mechanism* is identical regardless of table size — only
the row count changes):

```sql
SELECT employee_id, first_name, last_name, hire_date
FROM employees
ORDER BY hire_date, employee_id
LIMIT 20 OFFSET 100000;
```

To satisfy this query, correctly, the engine must — conceptually —
perform every one of these steps, in order:

1. **Produce the full matching row set** — here, all 500,000 rows (no
   `WHERE` clause narrows it).
2. **Sort that entire set** by `(hire_date, employee_id)`, because nothing
   yet guarantees the rows arrive pre-sorted (see §4.10.3 for the index
   exception).
3. **Walk the sorted result and discard the first 100,000 rows one by
   one** — the engine has no shortcut to "skip ahead" in a sorted stream
   without an index that lets it seek directly; discarding is a real,
   metered cost, not a free pointer-jump.
4. **Return the next 20 rows** after that discard, and stop.

The rows discarded in step 3 were fully computed and fully sorted — the
engine did real work to place them in exact rank order — and then you asked
it to throw all 100,000 of them away. **The cost of `OFFSET n` grows
roughly linearly with `n`**, no matter how small your `LIMIT` is, because
steps 1–3 must run to completion before step 4 can even begin.

### 4.10.2 Conceptual `EXPLAIN`-Style Walkthrough

Here is what a plan for the 500,000-row scenario would conceptually look
like on PostgreSQL, if `employees` had no index covering
`(hire_date, employee_id)`:

```
Limit  (cost=21345.67..21349.98 rows=20 width=48)
        (actual time=185.221..185.360 rows=20 loops=1)
  ->  Sort  (cost=21150.00..22400.00 rows=500000 width=48)
             (actual time=142.003..178.556 rows=100020 loops=1)
        Sort Key: hire_date, employee_id
        Sort Method: external merge  Disk: 24576kB
        ->  Seq Scan on employees  (cost=0.00..9500.00 rows=500000 width=48)
                                     (actual time=0.012..45.221 rows=500000 loops=1)
Planning Time: 0.112 ms
Execution Time: 186.010 ms
```

Reading this from the bottom up (the order operations actually execute):

- **`Seq Scan on employees`** — read all 500,000 rows off disk/heap; no
  index helps here because there's no `WHERE` filter to use one against.
- **`Sort`** — sort all 500,000 rows by `(hire_date, employee_id)`. Note
  `Sort Method: external merge Disk: 24576kB` — the working set didn't fit
  in memory (`work_mem`), so PostgreSQL spilled intermediate sort runs to
  disk. This is expensive, and it happens *before* any rows are handed
  back.
- **`Limit`** — walks the sorted stream, silently passing over (not
  emitting) the first 100,000 rows, then emits the next 20 and stops
  pulling further rows from `Sort`.

The real, measured cost — ~186ms in this illustration — was overwhelmingly
spent sorting 500,000 rows and discarding 100,020 of them, to hand back 20.
Push the offset to 400,000 and the discard cost grows further; the `LIMIT
20` never changes, but the *response time* keeps climbing with page depth.
This is exactly the shape of complaint you'll see in production: "pagination
is fast on page 2, but page 500 times out."

> On the *actual* 16-row `company_db.employees` table, running `EXPLAIN` on
> this same query will show a trivial `Seq Scan` + tiny in-memory `Sort` +
> `Limit`, with no measurable difference between `OFFSET 0` and `OFFSET
> 10` — the mechanism above only becomes *visible* at realistic scale. This
> is precisely why the deep-dive is presented conceptually: the algorithm
> is identical at 16 rows and 16 million; only the wall-clock cost differs.

### 4.10.3 The Index Exception (Foreshadowing Chapter 16)

If an index exists on `(hire_date, employee_id)`, the planner can read rows
**in that exact order directly from the index**, without a separate `Sort`
step — but it still must **traverse and skip** the first `OFFSET` index
entries before it can start returning rows; an index removes the *sorting*
cost, not the *skipping* cost. `OFFSET`'s "walk and discard" behavior is
fundamental to the offset model itself, not just a symptom of a missing
index. We revisit index-assisted sorts and scan types (`Index Scan`,
`Index Only Scan`) in full in Chapter 16.

### 4.10.4 Keyset Pagination: Avoiding the Discard Entirely

Keyset (a.k.a. seek, or cursor-based) pagination replaces "skip N rows"
with "start from a known position." Instead of telling the database *how
many* rows to skip, you tell it the exact sort-key values of the **last row
you saw**, and ask for rows strictly after that point:

```sql
-- "Give me the next 20 employees after the one I last saw:
--  hire_date = 2021-06-15, employee_id = 4582"
SELECT employee_id, first_name, last_name, hire_date
FROM employees
WHERE (hire_date, employee_id) > ('2021-06-15', 4582)
ORDER BY hire_date, employee_id
LIMIT 20;
```

Conceptual plan, assuming a supporting index on `(hire_date, employee_id)`:

```
Limit  (cost=0.43..8.60 rows=20 width=48)
  ->  Index Scan using idx_employees_hire_date_id on employees
        Index Cond: (ROW(hire_date, employee_id) > ROW('2021-06-15'::date, 4582))
```

There is no `Sort` node at all, and critically, **no discard step**: the
index lets the engine *seek* directly to the first row greater than
`(2021-06-15, 4582)` and read the next 20 entries forward — the same amount
of work whether that starting point is row 21 or row 400,021 of the table.
This is why keyset pagination's cost is **flat with respect to page
depth**, while `OFFSET`'s cost is **linear** in the offset.

**On our actual `company_db.employees` table** — walk it concretely.
Suppose a client's "last seen row" on the previous page was employee 12
(Nikhil Gupta, `hire_date = 2016-12-01`) — i.e., the last row of Page 1 in
our earlier §4.5.4 walkthrough. The next page, via keyset:

```sql
SELECT employee_id, first_name, last_name, hire_date
FROM employees
WHERE (hire_date, employee_id) > ('2016-12-01', 12)
ORDER BY hire_date, employee_id
LIMIT 5;
```

| employee_id | first_name | last_name | hire_date  |
|---|---|---|---|
| 3  | Sneha  | Kulkarni | 2017-01-20 |
| 8  | Arjun  | Das      | 2017-04-18 |
| 14 | Rajesh | Iyer     | 2017-09-30 |
| 13 | Divya  | Shah     | 2018-06-25 |
| 4  | Vikram | Joshi    | 2018-07-15 |

This is **exactly** Page 2 from §4.5.4's `OFFSET 5 LIMIT 5` — proving
keyset and offset pagination are logically equivalent for retrieving "the
next page," while differing entirely in *how* the engine gets there.

*Line-by-line:* `(hire_date, employee_id) > ('2016-12-01', 12)` is a **row
value comparison**: it's true for a row if its `hire_date` is strictly
later than `2016-12-01`, OR its `hire_date` equals `2016-12-01` exactly but
its `employee_id` is greater than 12 (this second branch is why the
`employee_id` tiebreaker is included — it correctly handles the case where
multiple rows share the cursor row's `hire_date`, which doesn't occur in
this specific seed data but absolutely will in a real, larger table). The
`ORDER BY` must match the comparison's column order exactly, and the
`LIMIT` still applies only *after* the seek — but with no rows to discard,
because the seek itself started in the right place.

**To fetch the page *after* this one**, the client remembers the last row
returned here — employee 4, `hire_date = 2018-07-15` — and repeats the
pattern:

```sql
SELECT employee_id, first_name, last_name, hire_date
FROM employees
WHERE (hire_date, employee_id) > ('2018-07-15', 4)
ORDER BY hire_date, employee_id
LIMIT 5;
```

giving Page 3 from §4.5.4 (employees 11, 5, 6, 15, 9) — again identical
content, reached without ever computing or discarding the 10 rows that
came before it.

### 4.10.5 Trade-offs: What Keyset Pagination Gives Up

| Capability | `OFFSET` pagination | Keyset pagination |
|---|---|---|
| "Jump directly to page 500" | Yes — just set `OFFSET = 499 * page_size` | Hard — you'd need to have recorded (or separately compute) the cursor value at that exact position; there's no direct "skip to arbitrary page" without extra indexing/materialization work |
| Performance at large offsets | Degrades — cost grows with offset (§4.10.1–4.10.2) | Flat — cost is independent of how deep you are (§4.10.4) |
| Handles sort columns with duplicate values | Works, but ties need a tiebreaker column for stable ordering across pages (§4.3.5) | **Requires** a tiebreaker column in both the `ORDER BY` and the `WHERE` row-comparison, or duplicate sort-key values will break the seek logic (a row could be skipped or repeated) |
| Stable under concurrent inserts/deletes | No — a row inserted into an already-returned page shifts every subsequent offset by one, causing skipped or duplicated rows across page fetches | Yes — since each page's starting point is anchored to a specific row's key values, not a row *count*, insertions/deletions elsewhere in the table don't shift your position |
| Client-side simplicity | Simple: `page=3` | Slightly more complex: client must carry forward an opaque cursor (the last row's sort-key values, often base64-encoded) instead of a page number |
| "How many total pages/rows are there?" | Easy to compute alongside (a `COUNT(*)` gives total, divide by page size) | Requires a separate `COUNT(*)` query anyway — keyset itself gives no total, same as offset in this respect |

> **Important Note.** Keyset pagination's `WHERE` clause must exactly track
> your `ORDER BY` clause, column for column, including the tiebreaker. If
> you sort by `hire_date` alone but seek only on `hire_date` without the
> `employee_id` tiebreaker, two employees hired on the same date can be
> **skipped entirely** or **shown twice** across a page boundary — this is
> the single most common keyset-pagination bug.

---

## 4.11 `OFFSET` vs. Keyset — When to Use Which

**Use `OFFSET`/`LIMIT` (or `FETCH`/`TOP`) when:**

- The result set is small-to-moderate (the table itself, or the filtered
  `WHERE` result, is realistically bounded — thousands, not millions, of
  rows), so linear discard cost never becomes noticeable.
- Users genuinely need "jump to page N" — e.g., an admin table with visible
  page numbers (`1 2 3 ... 47`) and a "go to page" input.
- You need a simple, stateless request shape and total-row-count display
  ("Showing 21–40 of 1,204 results") is a hard requirement.

**Use keyset (seek) pagination when:**

- The table is large and users page deep, or page *very frequently*
  (infinite scroll, API polling, data export tools) — anywhere the linear
  discard cost of `OFFSET` would show up as real latency or database load.
- "Next page" / "load more" is the only navigation users need — no jump-to-
  page-N requirement.
- Data changes frequently between page loads and you need pagination that's
  stable against concurrent inserts/deletes (e.g., a live activity feed
  where new rows are constantly added at the "front").

### 4.11.1 `ORDER BY` Behavior Differences Across Dialects — Summary Table

| Behavior | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Pagination syntax | `LIMIT n OFFSET m`, `OFFSET m FETCH FIRST n ROWS ONLY` | `LIMIT n OFFSET m`, `LIMIT m, n` | `FETCH FIRST n ROWS ONLY` (12c+), `ROWNUM` (all versions) | `TOP (n)`, `OFFSET m ROWS FETCH NEXT n ROWS ONLY` (2012+) |
| `NULL` sorts (default `ASC`) | Last | First | Last | First |
| `NULLS FIRST/LAST` syntax | Native | Not supported (emulate) | Native | Not supported (emulate) |
| `ORDER BY` required for row-limiting clause | No (but should be, per §4.5.6) | No (but should be) | No for `ROWNUM`; standard SQL doesn't require it either | **Yes** — `OFFSET`/`FETCH` errors without `ORDER BY` |
| Deterministic tie order without explicit tiebreaker | No | No | No | No |

---

## 4.12 Real-World Use Cases

- **REST/GraphQL API pagination.** Public APIs (Stripe, GitHub, Slack) that
  expose large, frequently-updated collections almost universally use
  cursor/keyset pagination (`?after=<cursor>`) for exactly the reasons in
  §4.10 — deep pages must stay fast and stable regardless of collection
  size or concurrent writes.
- **Infinite scroll feeds.** Social feeds, notification lists, and activity
  logs are a textbook keyset use case: the user only ever asks for "more,"
  never "page 40," and new items are constantly inserted at the top.
- **Admin dashboards / back-office tables.** Internal tools that show a
  numbered table with "Page 1 2 3 ... 12" controls are a textbook
  `OFFSET`/`FETCH` use case — the dataset is usually modest, users
  genuinely want to jump around, and simplicity beats micro-optimized
  performance.
- **Bulk exports / ETL jobs.** Streaming an entire large table out to a
  file is best done with keyset pagination internally (fetch 10,000 rows
  at a time by advancing a cursor on the primary key or an indexed
  timestamp), even though the "user" here is a script, not a human clicking
  "next" — the same performance argument applies at any scale.
- **"Top N" reports.** `ORDER BY ... DESC LIMIT n` (or `TOP (n)` /
  `FETCH FIRST n ROWS ONLY`) for leaderboards, "most recent hires,"
  "highest earners," etc. — no pagination needed, just a bounded sort.

---

## 4.13 Practice Questions

1. Write a query that lists all employees ordered by `department_id`
   ascending, and within each department, by `hire_date` descending (most
   recently hired first within each department). Which employee appears
   first overall, and why?
2. `employees.manager_id` is `NULL` for exactly one row. Write a query,
   using explicit `NULLS FIRST`/`NULLS LAST` syntax, that places employees
   with no manager at the very top of the result, sorted by `employee_id`
   otherwise. Then write the MySQL-compatible equivalent that doesn't rely
   on that syntax.
3. Explain, in your own words, why `SELECT * FROM employees LIMIT 3;`
   (with no `ORDER BY`) is considered bad practice even if it "seems" to
   return the same 3 rows every time you've tried it so far.
4. Write a query returning the 3rd, 4th, and 5th most recently hired
   employees (i.e., skip the 2 most recent, then take the next 3) using
   (a) `LIMIT`/`OFFSET`, and (b) `FETCH FIRST ... ROWS ONLY` syntax.
5. A junior developer on your team writes this Oracle query and is
   confused why it doesn't return the 5 earliest-hired employees:
   `SELECT employee_id, hire_date FROM employees WHERE ROWNUM <= 5 ORDER
   BY hire_date;`. Explain precisely what this query actually does, and
   rewrite it correctly.
6. Two employees share the job title "Sales Executive": Arjun Das
   (employee_id 8, hired 2017-04-18) and Meera Pillai (employee_id 9, hired
   2021-03-22). Write a keyset pagination `WHERE` clause that correctly
   fetches the row(s) that come *after* Arjun Das when the sort order is
   `job_title, hire_date, employee_id`. Why is `employee_id` necessary in
   both the `ORDER BY` and the `WHERE` clause here, even though `job_title`
   and `hire_date` together are already almost enough to identify Arjun's
   position?
7. Explain, mechanically, why `OFFSET 50000 LIMIT 20` against a
   100,000-row table typically takes noticeably longer than `OFFSET 0
   LIMIT 20` against the same table — even though both return only 20
   rows. What specifically is the extra time being spent on?
8. Give one realistic scenario where `OFFSET`/`LIMIT` pagination is
   clearly the better choice over keyset pagination, and one where keyset
   is clearly better. Justify each with a concrete reason from this
   chapter, not just "it's faster."

---

## 4.14 Chapter Challenge

**Design a keyset-paginated "Employee Directory" API query.**

You're building the backend for an internal "Employee Directory" page. The
UI shows employees alphabetically by last name (ties broken by first name,
further ties broken by `employee_id`), 5 per screen, with a "Load more"
button — no numbered pages, no jump-to-page requirement.

Your task:

1. Write the SQL for the **first page** (no cursor yet) — 5 employees,
   sorted by `last_name, first_name, employee_id`, using `FETCH FIRST ...
   ROWS ONLY`.
2. Using the *last row* your first-page query returned, write the keyset
   `WHERE` clause for the **second page** — a query that fetches the next 5
   employees strictly after that row, in the same sort order.
3. Your API needs to tell the frontend whether a "Load more" button should
   still be shown (i.e., whether more rows exist beyond the current page).
   Describe (in SQL or in words) a technique that answers this **without**
   running a separate `COUNT(*)` query. (Hint: what happens if you request
   one more row than you plan to display?)
4. Name the index you would create to make both the initial sort and every
   subsequent keyset lookup efficient, and explain — referencing §4.10 —
   why that index removes the sorting cost but not necessarily every cost
   in the query.
5. Your product manager later asks for a "Jump to letter" feature (e.g.,
   clicking "M" jumps straight to employees whose last name starts with
   "M"). Explain whether this is easy or hard to support cleanly on top of
   your keyset design, and why.

---

## Key Takeaways

- `ORDER BY` is the *only* mechanism guaranteeing row order; without it, row
  order is unspecified and can silently change over time.
- Multi-column `ORDER BY` breaks ties left-to-right; without a unique final
  tiebreaker (typically the primary key), tied rows have unspecified
  relative order — a silent bug waiting to surface in pagination.
- `NULL` sort placement is dialect-dependent: PostgreSQL/Oracle sort `NULL`
  as the largest value by default (`NULLS LAST` on `ASC`); MySQL/SQL Server
  sort it as the smallest (`NULLS FIRST` on `ASC`). Only PostgreSQL/Oracle
  offer native `NULLS FIRST/LAST` syntax.
- `LIMIT`/`OFFSET`, `FETCH FIRST ... ROWS ONLY`, `TOP`, and `ROWNUM`/
  `ROW_NUMBER()` are four dialect-flavored ways of expressing the same two
  underlying ideas: "cap the row count" and "skip ahead."
- Sorting is, by default, a full-set operation completed before `LIMIT`
  can apply — unless an index already provides the needed order (previewed
  here, covered fully in Chapters 16–17).
- `OFFSET n` costs grow with `n` because the engine must produce, sort, and
  discard `n` rows before returning anything — a mechanical fact, not a
  vague "it's slow" rule of thumb.
- Keyset (seek) pagination replaces "skip N rows" with "start after this
  specific row's key," giving flat performance regardless of page depth,
  at the cost of losing arbitrary "jump to page N" and requiring a strict,
  unique sort key.
- Choose `OFFSET` pagination for small/moderate, jump-around-friendly UIs;
  choose keyset pagination for large, deep, or high-frequency, "next/load
  more"-style access patterns.

## What's Next

Chapter 5 moves from *ordering and slicing* result sets to *transforming*
the data inside them: string functions, numeric functions, date/time
functions, and `NULL`-handling functions (`COALESCE`, `NULLIF`, and the
three-valued logic that made §4.4's `NULL`-sorting rules necessary in the
first place). You'll use these functions to reshape columns like
`first_name`/`last_name`, `hire_date`, and `base_salary` before they ever
reach an `ORDER BY` or a report.

**Next:** [Chapter 5 — Built-in Functions](05-functions.md)
