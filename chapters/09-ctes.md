# Chapter 9 — Common Table Expressions & Recursive CTEs

> **Part III — Intermediate SQL** · Previous: [Chapter 8 — Subqueries](08-subqueries.md) · Next: [Chapter 10 — Window Functions](10-window-functions.md)

All queries in this chapter run against `company_db` and `ecommerce_db` exactly
as seeded in `databases/company_db.sql` and `databases/ecommerce_db.sql`. Every
result table shown is the *real* output you get from PostgreSQL 15+ after
running:

```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
```

## 9.0 Why This Chapter Exists

Chapter 8 showed you how to nest queries inside queries. That works, but past
two or three levels of nesting, subqueries become unreadable — you end up
scrolling past parentheses to find where a filter actually applies. **Common
Table Expressions (CTEs)**, introduced with the `WITH` clause, solve the
readability problem by letting you name an intermediate result and reference
it later in the query, top to bottom, like a sequence of readable steps.

But CTEs do something a plain subquery structurally *cannot* do: reference
**themselves**. That capability — a **recursive CTE** — is the only
standard, set-based way to walk a hierarchy (an org chart, a category tree,
a folder structure) or traverse a graph (a network, a dependency chain)
without writing a procedural loop. This chapter covers both halves: CTEs as
a readability tool, and recursive CTEs as a hierarchy/graph-traversal engine.

---

## 9.1 The `WITH` Clause: CTE Basics

### Simple Explanation

A CTE is a temporary, named result set that exists only for the duration of
one query. Think of it as giving a subquery a name and moving it *above* the
main query, so you read the query top-to-bottom like a recipe: "first compute
this, then use it here."

### Technical Explanation

A CTE is defined with the `WITH` keyword followed by a name, an optional
column list, `AS`, and a parenthesized query. The named result can then be
referenced in the `FROM` or `JOIN` clause of the statement that follows,
exactly as if it were a table or view — except it is not persisted anywhere;
it lives only for the one statement.

### Why It Exists

- **Readability** — breaks a complex query into named, logical steps instead
  of deeply nested parentheses.
- **Reuse within one statement** — a CTE can be joined to more than once in
  the same query without repeating its SQL text (a subquery would have to be
  copy-pasted or joined redundantly).
- **Enabling recursion** — this is the big one, covered from §9.5 onward. A
  bare subquery cannot reference itself; a CTE can.

### Full Syntax

```sql
WITH cte_name [ (column1, column2, ...) ] AS (
    SELECT ...
)
SELECT ...
FROM cte_name
[ JOIN ... ];
```

- The column list is optional — if omitted, the CTE's columns take the names
  from the inner `SELECT`.
- A CTE is visible to the main query and to any CTE defined *after* it, but
  **not** to CTEs defined before it (unless you chain deliberately — see
  §9.3–9.4).

### Example 1 — Basic `WITH` (Simple)

**Goal:** list each department with its count of `ACTIVE` employees.

```sql
WITH active_employees AS (
    SELECT department_id, employee_id
    FROM employees
    WHERE status = 'ACTIVE'
)
SELECT
    d.department_name,
    COUNT(ae.employee_id) AS active_headcount
FROM departments d
LEFT JOIN active_employees ae ON ae.department_id = d.department_id
GROUP BY d.department_name
ORDER BY active_headcount DESC, d.department_name;
```

**Expected output:**

| department_name | active_headcount |
|---|---|
| Engineering | 6 |
| Finance | 2 |
| HR | 2 |
| Marketing | 2 |
| Sales | 2 |

**Line-by-line explanation**

1. `WITH active_employees AS (...)` — defines a named result set: every
   `(department_id, employee_id)` pair for employees currently `ACTIVE`.
2. The inner query filters `employees.status = 'ACTIVE'` — of the 16 seeded
   employees, `Ananya Singh` (`ON_LEAVE`) and `Meera Pillai` (`TERMINATED`)
   are excluded, leaving 14 rows.
3. The outer `SELECT` treats `active_employees` exactly like a table, joining
   it back to `departments` with a `LEFT JOIN` so departments with zero
   active employees would still appear (none do here, but the `LEFT JOIN`
   makes the query correct even if that changes).
4. `GROUP BY` + `COUNT` produce the headcount per department.

Without the CTE, you'd write the identical logic as a derived subquery in the
`FROM` clause — functionally equivalent, but with the filter buried inside
parentheses instead of named up front.

> **Important Note:** A CTE is **not** a materialized table you can index,
> and it is **not visible outside the single statement it's attached to**.
> Run it again in a new statement and it is recomputed from scratch — there
> is no caching across queries. If you need a reusable, persisted definition,
> use a **view** (Chapter 15); if you need a large intermediate result reused
> across multiple statements, use a **temp table** (Chapter 24).

---

## 9.2 Multiple CTEs in One Query

You can define more than one CTE in the same `WITH` clause, separated by
commas. Each is available to the main query (and to any CTE defined after
it).

### Full Syntax

```sql
WITH cte_one AS (
    SELECT ...
),
cte_two AS (
    SELECT ...
)
SELECT ...
FROM cte_one
JOIN cte_two ON ...;
```

### Example — Two Independent CTEs Combined

**Goal:** for each department, show active headcount *and* total project
budget, side by side.

```sql
WITH dept_headcount AS (
    SELECT department_id, COUNT(*) AS active_employees
    FROM employees
    WHERE status = 'ACTIVE'
    GROUP BY department_id
),
dept_budget AS (
    SELECT department_id, SUM(budget) AS total_project_budget
    FROM projects
    GROUP BY department_id
)
SELECT
    d.department_name,
    COALESCE(h.active_employees, 0)     AS active_employees,
    COALESCE(b.total_project_budget, 0) AS total_project_budget
FROM departments d
LEFT JOIN dept_headcount h ON h.department_id = d.department_id
LEFT JOIN dept_budget    b ON b.department_id = d.department_id
ORDER BY d.department_id;
```

**Expected output:**

| department_name | active_employees | total_project_budget |
|---|---|---|
| Engineering | 6 | 8000000.00 |
| Sales | 2 | 1200000.00 |
| HR | 2 | 250000.00 |
| Finance | 2 | 0 |
| Marketing | 2 | 800000.00 |

**Explanation:** `dept_headcount` and `dept_budget` are computed
independently (neither references the other) and are only brought together
in the final `SELECT`'s two `LEFT JOIN`s. Finance has no rows in `projects`,
so `dept_budget` contributes no row for `department_id = 4`; `COALESCE`
turns that missing value into `0`.

---

## 9.3 CTE Chaining — One CTE Referencing Another

CTEs defined later in the same `WITH` clause can reference CTEs defined
earlier. This lets you build a multi-step pipeline: step 1 computes a base
metric, step 2 filters or aggregates on top of step 1, and so on.

### Example — Employees Earning Above Their Department's Average

**Goal:** find each employee's *current* (latest `effective_date`) salary,
compute each department's average current salary, then list employees whose
current salary exceeds their own department's average.

```sql
WITH latest_salary AS (                                   -- step 1
    SELECT DISTINCT ON (employee_id)
        employee_id,
        base_salary
    FROM salaries
    ORDER BY employee_id, effective_date DESC
),
dept_avg AS (                                              -- step 2: uses step 1
    SELECT e.department_id, AVG(ls.base_salary) AS avg_base_salary
    FROM employees e
    JOIN latest_salary ls ON ls.employee_id = e.employee_id
    GROUP BY e.department_id
)
SELECT                                                       -- main query: uses steps 1 & 2
    e.employee_id,
    e.first_name || ' ' || e.last_name AS employee_name,
    d.department_name,
    ls.base_salary,
    ROUND(da.avg_base_salary, 2) AS dept_avg_salary
FROM employees e
JOIN latest_salary ls ON ls.employee_id = e.employee_id
JOIN dept_avg da      ON da.department_id = e.department_id
JOIN departments d    ON d.department_id = e.department_id
WHERE ls.base_salary > da.avg_base_salary
ORDER BY e.department_id, ls.base_salary DESC;
```

**Expected output:**

| employee_id | employee_name | department_name | base_salary | dept_avg_salary |
|---|---|---|---|---|
| 1 | Aditi Rao | Engineering | 520000.00 | 212142.86 |
| 2 | Rahul Mehta | Engineering | 320000.00 | 212142.86 |
| 7 | Priya Nair | Sales | 300000.00 | 168333.33 |
| 10 | Rohan Kapoor | HR | 240000.00 | 170000.00 |
| 12 | Nikhil Gupta | Finance | 250000.00 | 190000.00 |
| 14 | Rajesh Iyer | Marketing | 230000.00 | 167500.00 |

**Line-by-line explanation**

1. `latest_salary` **[PostgreSQL]** uses `DISTINCT ON (employee_id)` ordered
   by `effective_date DESC` to keep only each employee's most recent salary
   row — e.g. employee 1 (Aditi Rao) has two rows (`450000` effective
   2015-03-01, `520000` effective 2020-01-01); `DISTINCT ON` keeps `520000`.
   `DISTINCT ON` is Postgres-only; Chapter 10 shows the portable
   `ROW_NUMBER() OVER (PARTITION BY ...)` equivalent for MySQL/Oracle/SQL
   Server.
2. `dept_avg` **chains onto `latest_salary`** — it joins `employees` to the
   *already-computed* `latest_salary` CTE, then averages by department. This
   is only possible because `dept_avg` is defined *after* `latest_salary` in
   the same `WITH` clause.
3. The main query joins all three named sets together and filters
   `ls.base_salary > da.avg_base_salary`. Every department's top earner here
   happens to be its manager — which is exactly what you'd expect from the
   seed data.

> **Important Note:** Chaining CTEs is still just "define A, then define B in
> terms of A, then query B" — there is no special syntax for chaining beyond
> ordering your `WITH` list correctly. The real leap in capability comes next:
> a CTE referencing **itself**.

---

## 9.4 Recursive CTEs — Concept & Anatomy

### Simple Explanation

A recursive CTE is a query that runs repeatedly, each time using the result
of the *previous* run as its new starting point, until a run produces no new
rows. It's how SQL expresses "keep following this relationship until you run
out of things to follow" — exactly what you need for org charts, folder
trees, category trees, and graphs.

### Technical Explanation

A recursive CTE is a `WITH RECURSIVE` (or, in some dialects, plain `WITH`)
clause whose query body has two parts joined by `UNION` or `UNION ALL`:

1. A **base term** (also called the *anchor* or *seed*) — a non-recursive
   query that produces the starting row(s).
2. A **recursive term** — a query that references the CTE's own name and is
   re-executed against only the rows produced by the *previous* iteration
   (this working set is often called the **working table**), until it
   returns zero rows.

The database executes this as a loop internally: run the base term once to
seed the working table; then repeatedly run the recursive term against the
current working table, append (`UNION ALL`) or merge-with-dedup (`UNION`)
the new rows into the final result, and replace the working table with just
the newly produced rows; stop when an iteration produces no rows at all.

### Why It Exists

Nothing else in standard, set-based SQL can express "repeat until no more
rows appear." Without recursive CTEs, walking an arbitrarily deep hierarchy
requires either a fixed number of hand-written self-joins (breaks if the tree
gets deeper), a procedural loop in application code or a stored procedure
with a cursor (Chapter 21), or vendor-specific hierarchical syntax (Oracle's
`CONNECT BY`, covered below). Recursive CTEs give every major database a
portable, declarative answer.

### Full Syntax Breakdown

```sql
WITH RECURSIVE cte_name AS (
    -- 1. BASE TERM (anchor): produces the starting row(s), no self-reference
    SELECT ...
    FROM some_table
    WHERE <starting condition>

    UNION ALL                       -- 2. UNION ALL (keep all rows) or UNION (dedup every iteration)

    -- 3. RECURSIVE TERM: references cte_name itself, joined to the base table
    SELECT ...
    FROM some_table s
    JOIN cte_name c ON <s relates to c>
    -- 4. TERMINATION: implicit — recursion stops the moment this term
    --    returns zero new rows for the current working table
)
SELECT * FROM cte_name;
```

| Piece | Purpose |
|---|---|
| `RECURSIVE` keyword | Tells the engine this `WITH` clause may reference itself **[PostgreSQL, MySQL 8+]** |
| Base term | Seeds the very first working table (iteration 0) |
| `UNION ALL` | Keep every row from every iteration, no dedup — the normal, efficient choice |
| `UNION` | Dedup by comparing each new row against **all** rows accumulated so far — slower, and (see §9.9) does *not* reliably stop cyclic recursion if a `level`/`path` column makes every row unique |
| Recursive term | Re-runs once per iteration, but only against the *previous* iteration's new rows, not the whole accumulated result |
| Termination | Implicit: the moment the recursive term produces 0 rows, the loop stops. There is **no explicit "stop" keyword** — you engineer termination through your `WHERE`/`JOIN` conditions |

### Dialect Differences at a Glance

| Dialect | Keyword / mechanism | Notes |
|---|---|---|
| **PostgreSQL** | `WITH RECURSIVE cte AS (...)` | `RECURSIVE` is mandatory even if only one of several CTEs in the statement is recursive |
| **MySQL 8.0+** | `WITH RECURSIVE cte AS (...)` | Same ANSI syntax as PostgreSQL; MySQL 5.7 and earlier have **no** recursive CTE support at all |
| **SQL Server** | `WITH cte AS (...)` | No `RECURSIVE` keyword exists or is needed — SQL Server detects the self-reference automatically. Uses `OPTION (MAXRECURSION n)` as a runaway-recursion guard (default 100, `0` = unlimited) |
| **Oracle** | `CONNECT BY PRIOR` / `START WITH` (traditional), or ANSI `WITH cte AS (...)` (11gR2+) | Oracle predates the ANSI recursive CTE standard by decades and still favors `CONNECT BY` idiomatically; the pseudo-column `LEVEL` and `ORDER SIBLINGS BY` are unique to this syntax |

> **⚠️ Warning:** Forgetting `RECURSIVE` in PostgreSQL or MySQL 8+ does not
> silently do the wrong thing — it raises an error such as
> `relation "cte_name" does not exist` (Postgres) the moment the recursive
> term tries to reference the CTE's own name, because without `RECURSIVE`
> the parser doesn't allow a CTE to see itself. The fix is simply adding the
> keyword, but the error message confuses many beginners into thinking they
> misspelled the CTE name.

---

## 9.5 Worked Example 1 — Employee/Manager Hierarchy (Org Chart)

**Goal:** starting from the CEO, **Aditi Rao** (`employee_id = 1`,
`manager_id IS NULL`), produce a full org chart with a computed depth
(`level`) and an indented display name.

```sql
WITH RECURSIVE org_chart AS (
    -- Base term: the CEO, level 1, path = [1]
    SELECT
        employee_id,
        first_name || ' ' || last_name AS employee_name,
        manager_id,
        1                              AS level,
        ARRAY[employee_id]             AS path
    FROM employees
    WHERE employee_id = 1

    UNION ALL

    -- Recursive term: every employee whose manager is already in org_chart
    SELECT
        e.employee_id,
        e.first_name || ' ' || e.last_name,
        e.manager_id,
        oc.level + 1,
        oc.path || e.employee_id
    FROM employees e
    JOIN org_chart oc ON e.manager_id = oc.employee_id
)
SELECT
    employee_id,
    level,
    repeat('  ', level - 1) || employee_name AS org_chart_display,
    manager_id
FROM org_chart
ORDER BY path;
```

### Expected Output

```
 employee_id | level |          org_chart_display          | manager_id
-------------+-------+--------------------------------------+------------
           1 |     1 | Aditi Rao                             |
           2 |     2 |   Rahul Mehta                         |          1
           3 |     3 |     Sneha Kulkarni                    |          2
           6 |     4 |       Karan Verma                     |          3
           4 |     3 |     Vikram Joshi                      |          2
           5 |     3 |     Ananya Singh                      |          2
          16 |     3 |     Aman Chawla                       |          2
           7 |     2 |   Priya Nair                          |          1
           8 |     3 |     Arjun Das                         |          7
           9 |     3 |     Meera Pillai                      |          7
          10 |     2 |   Rohan Kapoor                        |          1
          11 |     3 |     Isha Bhatt                        |         10
          12 |     2 |   Nikhil Gupta                        |          1
          13 |     3 |     Divya Shah                        |         12
          14 |     2 |   Rajesh Iyer                         |          1
          15 |     3 |     Pooja Reddy                       |         14
(16 rows)
```

### Line-by-Line Explanation

1. **Base term** selects only `employee_id = 1` (Aditi Rao), sets `level = 1`,
   and seeds `path` as a one-element array `[1]`. `path` is not required for
   correctness of the recursion itself, but it gives us a deterministic,
   tree-shaped sort order at the end (see step 5).
2. **Recursive term** joins the real `employees` table to `org_chart`,
   matching `e.manager_id = oc.employee_id` — "find employees whose manager
   is a row already in the working table." Each match increments `level` by
   1 and appends the new `employee_id` to `path`.
3. `UNION ALL` is required, not `UNION` — see §9.9 for why using `UNION` here
   would be both slower and semantically wrong (every row already has a
   unique `path`, so `UNION`'s deduplication would never trigger, but it
   would still pay the cost of comparing every row against every other row
   on every iteration).
4. The outer `SELECT` builds `org_chart_display` using `repeat('  ', level - 1)`
   **[PostgreSQL]** (`REPLICATE` in **[SQL Server]**) to prepend two spaces
   per level of depth below the CEO.
5. `ORDER BY path` sorts by PostgreSQL's built-in lexicographic array
   comparison: `[1,2,3,6]` sorts immediately after `[1,2,3]` and before
   `[1,2,4]`, which is exactly what produces a proper **depth-first,
   pre-order tree printout** — every employee's entire subtree is printed
   before moving on to the next sibling. This is why Karan Verma (path
   `[1,2,3,6]`) appears directly under Sneha Kulkarni rather than after all
   of Rahul Mehta's other direct reports.

### Iteration-by-Iteration Trace (the "working table" at each step)

| Iteration | New rows added (employee_id → level) | Cumulative row count |
|---|---|---|
| 0 (base term) | `1` → level 1 | 1 |
| 1 | `2, 7, 10, 12, 14` → level 2 (children of employee 1) | 6 |
| 2 | `3, 4, 5, 16` (children of 2), `8, 9` (children of 7), `11` (children of 10), `13` (children of 12), `15` (children of 14) → level 3 | 15 |
| 3 | `6` → level 4 (only child of employee 3) | 16 |
| 4 | *(no employee has manager_id = 6)* → **0 new rows → recursion stops** | 16 |

Five iterations total (iteration 0 through the empty iteration 4), 16 rows
in the final result — every employee in `company_db.employees` is reachable
from the CEO, so no rows are left out.

### Internal Behavior

Unlike a non-recursive CTE (§9.10 covers when those get inlined), a
recursive CTE is **always** evaluated iteratively against an explicit
working table — the database cannot "flatten" or inline a self-referencing
query into a single plan the way it can a simple filter. Under the hood,
PostgreSQL builds this as a `WorkTable Scan` / `Recursive Union` node in the
plan (visible via `EXPLAIN`), repeatedly scanning only the rows produced by
the prior step, not the whole accumulated result — this is what makes
recursive CTEs efficient even over moderately deep hierarchies.

---

## 9.6 Worked Example 2 — All Direct & Indirect Reports of a Given Manager

A very common variant of the same pattern: instead of starting at the root
of the whole tree, start at an arbitrary manager and find everyone beneath
them.

**Goal:** every employee, direct or indirect, who reports up to
**Rahul Mehta** (`employee_id = 2`).

```sql
WITH RECURSIVE subordinates AS (
    -- Base term: direct reports of Rahul Mehta
    SELECT
        employee_id,
        first_name || ' ' || last_name AS employee_name,
        manager_id,
        1                               AS depth
    FROM employees
    WHERE manager_id = 2

    UNION ALL

    -- Recursive term: reports of anyone already found
    SELECT
        e.employee_id,
        e.first_name || ' ' || e.last_name,
        e.manager_id,
        s.depth + 1
    FROM employees e
    JOIN subordinates s ON e.manager_id = s.employee_id
)
SELECT * FROM subordinates
ORDER BY depth, employee_id;
```

**Expected output:**

| employee_id | employee_name | manager_id | depth |
|---|---|---|---|
| 3 | Sneha Kulkarni | 2 | 1 |
| 4 | Vikram Joshi | 2 | 1 |
| 5 | Ananya Singh | 2 | 1 |
| 16 | Aman Chawla | 2 | 1 |
| 6 | Karan Verma | 3 | 2 |

**Explanation:** the only structural difference from Worked Example 1 is the
base term's filter — `WHERE manager_id = 2` instead of
`WHERE employee_id = 1`. Karan Verma (`employee_id = 6`) is Rahul Mehta's
only *indirect* report, reached through Sneha Kulkarni at `depth = 2`. This
"reports of X" query is the shape you'll reuse constantly: swap the anchor
manager, and you get the reporting tree under any employee in the company.

> **Real-world tip:** this exact pattern — "give me an id, walk downward" —
> is also how you'd implement "show me this manager's total team size"
> (`SELECT COUNT(*) FROM subordinates`) or "is employee X anywhere under
> manager Y" (`SELECT EXISTS (SELECT 1 FROM subordinates WHERE employee_id = X)`).

---

## 9.7 Worked Example 3 — Category Tree with Full Paths

`ecommerce_db.categories` has a self-referencing `parent_category_id`,
seeded as a small forest (three separate root categories, not one single
root):

| category_id | category_name | parent_category_id |
|---|---|---|
| 1 | Electronics | NULL |
| 2 | Mobiles | 1 |
| 3 | Laptops | 1 |
| 4 | Fashion | NULL |
| 5 | Men | 4 |
| 6 | Women | 4 |
| 7 | Home & Kitchen | NULL |

**Goal:** produce a human-readable full path for every category, e.g.
`"Electronics > Mobiles"`.

```sql
WITH RECURSIVE category_tree AS (
    -- Base term: every root category (no parent)
    SELECT
        category_id,
        category_name,
        parent_category_id,
        category_name::text AS full_path,
        1                    AS level,
        ARRAY[category_id]   AS path
    FROM categories
    WHERE parent_category_id IS NULL

    UNION ALL

    -- Recursive term: children of any category already in category_tree
    SELECT
        c.category_id,
        c.category_name,
        c.parent_category_id,
        ct.full_path || ' > ' || c.category_name,
        ct.level + 1,
        ct.path || c.category_id
    FROM categories c
    JOIN category_tree ct ON c.parent_category_id = ct.category_id
)
SELECT category_id, full_path, level
FROM category_tree
ORDER BY path;
```

**Expected output:**

| category_id | full_path | level |
|---|---|---|
| 1 | Electronics | 1 |
| 2 | Electronics > Mobiles | 2 |
| 3 | Electronics > Laptops | 2 |
| 4 | Fashion | 1 |
| 5 | Fashion > Men | 2 |
| 6 | Fashion > Women | 2 |
| 7 | Home & Kitchen | 1 |

### Iteration Trace

| Iteration | New rows | Notes |
|---|---|---|
| 0 (base) | `Electronics`, `Fashion`, `Home & Kitchen` (level 1) | Three separate roots — a *forest*, not a single tree; `WHERE parent_category_id IS NULL` naturally handles any number of roots |
| 1 | `Mobiles`, `Laptops` (children of Electronics), `Men`, `Women` (children of Fashion) — level 2 | `full_path` is built by string-concatenating the parent's already-computed `full_path` with `' > '` and the child's name |
| 2 | *(no category has a parent among level-2 rows — all are leaves)* → 0 new rows, recursion stops | |

**Line-by-line explanation:** the pattern is structurally identical to the
org chart — a base term for "no parent," a recursive term joining child rows
to already-found parent rows — but here the accumulated recursive column is
a `full_path` **string** built by concatenation instead of a `level` integer
alone, demonstrating that the recursive term can carry forward arbitrary
computed state, not just a counter.

---

## 9.8 Illustrative Example — File-System-Like Structures

Folder trees (a folder containing folders, containing folders...) follow the
*exact same recursive pattern* as the category tree above. This isn't part
of the canonical course schemas, so here is a tiny, self-contained example —
built entirely from inline `VALUES`, so you can paste this block directly
into `psql` against any database and see it run standalone:

```sql
WITH RECURSIVE folders (folder_id, folder_name, parent_folder_id) AS (
    VALUES
        (1, 'root',      NULL::int),
        (2, 'Documents', 1),
        (3, 'Photos',    1),
        (4, 'Invoices',  2),
        (5, '2024',      4),
        (6, 'Vacation',  3)
),
folder_tree AS (
    SELECT folder_id, folder_name, parent_folder_id,
           folder_name::text AS full_path,
           1                  AS level
    FROM folders
    WHERE parent_folder_id IS NULL

    UNION ALL

    SELECT f.folder_id, f.folder_name, f.parent_folder_id,
           ft.full_path || '/' || f.folder_name,
           ft.level + 1
    FROM folders f
    JOIN folder_tree ft ON f.parent_folder_id = ft.folder_id
)
SELECT folder_id, full_path, level
FROM folder_tree
ORDER BY full_path;
```

**Expected output:**

| folder_id | full_path | level |
|---|---|---|
| 1 | root | 1 |
| 2 | root/Documents | 2 |
| 4 | root/Documents/Invoices | 3 |
| 5 | root/Documents/Invoices/2024 | 4 |
| 3 | root/Photos | 2 |
| 6 | root/Photos/Vacation | 3 |

This is the identical mechanism behind "breadcrumb" navigation in a file
manager, an operating system's `ls -R`, or a cloud storage app's folder
picker — a self-referencing `parent_id` walked recursively, with a `/`-joined
path instead of a `>`-joined one.

---

## 9.9 Graph Traversal, Reachability & Cycle Detection

So far every example has been a strict **tree** — every node has exactly one
parent, so cycles are structurally impossible. Recursive CTEs are more
general than that: they can walk *any* directed graph, including ones with
cycles (a directed edge that eventually leads back to a node already
visited). That generality is powerful — and dangerous.

> **⚠️ Warning — Infinite Recursion Risk:** if the underlying data contains a
> cycle and your recursive term has no guard against revisiting a node, the
> query **will not terminate on its own**. PostgreSQL has no built-in
> recursion depth limit by default — the query will keep running, consuming
> memory and CPU, until it hits `statement_timeout`, exhausts `work_mem`, or
> you cancel it manually. Always design a termination guard *before* running
> a recursive CTE over graph data that isn't provably acyclic.

### Illustrative Example

Consider a tiny directed graph of nodes `A`–`E` with a cycle
(`A → B → C → A`):

```sql
WITH RECURSIVE edges (from_node, to_node) AS (
    VALUES ('A','B'), ('B','C'), ('C','A'), ('C','D'), ('D','E')
),
reachable (node, path, is_cycle) AS (
    -- Base term: start at A
    SELECT 'A'::text, ARRAY['A'::text], FALSE

    UNION ALL

    -- Recursive term: walk one edge further, but stop extending
    -- any branch that has already produced a cycle
    SELECT
        e.to_node,
        r.path || e.to_node,
        e.to_node = ANY(r.path)          -- has this node already been visited on this path?
    FROM edges e
    JOIN reachable r ON e.from_node = r.node
    WHERE NOT r.is_cycle                 -- the guard: don't expand past a detected cycle
)
SELECT node, path, is_cycle
FROM reachable
ORDER BY array_length(path, 1), node;
```

**Expected output:**

| node | path | is_cycle |
|---|---|---|
| A | {A} | false |
| B | {A,B} | false |
| C | {A,B,C} | false |
| A | {A,B,C,A} | true |
| D | {A,B,C,D} | false |
| E | {A,B,C,D,E} | false |

**How the guard works, iteration by iteration:**

1. Start at `A`, `path = [A]`.
2. `A → B`: `B` not in `[A]` → `is_cycle = false`, path becomes `[A,B]`.
3. `B → C`: `C` not in `[A,B]` → `is_cycle = false`, path becomes `[A,B,C]`.
4. From `C`, two edges exist: `C → A` and `C → D`.
   - `C → A`: `A` **is already** in `[A,B,C]` → `is_cycle = true`. This row
     is still added to the result (so you can see the cycle was found), but
     because of `WHERE NOT r.is_cycle` in the recursive term, **this branch
     is never expanded further** — nothing else joins onto it.
   - `C → D`: `D` not in `[A,B,C]` → `is_cycle = false`, expansion continues.
5. `D → E`: `E` not in `[A,B,C,D]` → `is_cycle = false`.
6. `E` has no outgoing edges → 0 new rows → recursion terminates naturally.

The result answers two questions at once: **reachability** (nodes `A`
through `E` are all reachable from `A`) and **cycle detection** (the row
`A, {A,B,C,A}, true` flags exactly where the graph loops back on itself).

Without the `path`/`is_cycle` bookkeeping and the `WHERE NOT r.is_cycle`
guard, the exact same query would alternate `A → B → C → A → B → C → ...`
forever, because the recursive term has no way to know it has already been
at node `A`.

### Guarding Against Infinite Recursion — Your Options

| Technique | How | Dialect |
|---|---|---|
| **Visited-path array** (shown above) | Carry an array of every node visited so far; in the recursive term, check `new_node = ANY(path)` and stop expanding once true | Portable pattern, works anywhere arrays or a JSON list are available |
| **Depth limit** | Add `WHERE level < N` to the recursive term as a hard cap, regardless of whether a cycle exists | Portable — simplest safety net for "I don't fully trust this data" |
| `MAXRECURSION` hint | `OPTION (MAXRECURSION 100)` — SQL Server aborts the query with an error once the cap is hit (default 100; `0` disables the cap entirely — use with extreme caution) | **[SQL Server]** |
| `cte_max_recursion_depth` session variable | Similar automatic cap, default 1000 | **[MySQL 8+]** |
| `NOCYCLE` clause | `CONNECT BY NOCYCLE PRIOR ...` automatically stops following a branch once a repeated row is detected | **[Oracle]** |
| `CYCLE` clause | ANSI SQL:1999 standard syntax: `... CYCLE column SET is_cycle TO 'Y' DEFAULT 'N' USING path_col` — automatically maintains the visited-row bookkeeping for you | **[Oracle, SQL Server 2016+, some PostgreSQL-compatible engines]**; note PostgreSQL itself does not implement the ANSI `CYCLE` clause as of PG 16 — you build the guard manually as shown above |

---

## 9.10 Deep Dive: When Do CTEs Help vs. Hurt Performance?

This is the single most misunderstood aspect of CTEs, and it differs
meaningfully by database version.

### The Historical PostgreSQL Behavior (pre-12): the "Optimization Fence"

Before PostgreSQL 12, **every** CTE referenced in a query — recursive or
not — was always fully **materialized**: the database computed the CTE's
entire result set once, stored it in a temporary work area, and only then
ran the outer query against that stored copy. This had a specific, important
consequence: the query planner could **not** push predicates from the outer
query down into the CTE, and could not reorder joins across the CTE
boundary. This earned pre-12 CTEs the nickname **"optimization fence."**

This was sometimes a deliberate feature: DBAs who understood the fence would
wrap a subquery in a CTE specifically *to force* Postgres to compute it
first, in isolation, when they didn't trust the optimizer to make a good
choice on its own — an old-school manual query-tuning trick.

### Modern PostgreSQL (12+): CTEs Can Be Inlined

Since PostgreSQL 12, the planner treats a **non-recursive**, side-effect-free
CTE referenced **exactly once** the same way it treats a subquery: it may
choose to **inline** it directly into the surrounding query, enabling
predicate pushdown and join reordering across the former "fence." A CTE
referenced multiple times, or one that is recursive, is still always
materialized (a recursive CTE structurally *has* to be — its working table
is inherent to the algorithm).

You can override the planner's default choice explicitly:

```sql
-- Force materialization: compute this CTE's result exactly once,
-- in isolation, regardless of how the outer query might want to use it
WITH big_filtered_orders AS MATERIALIZED (
    SELECT * FROM orders WHERE order_date >= '2024-01-01'
)
SELECT ...
FROM big_filtered_orders o
JOIN order_items oi ON oi.order_id = o.order_id;

-- Force inlining: let the planner merge this CTE into the outer
-- query even if it's used more than once
WITH recent_users AS NOT MATERIALIZED (
    SELECT * FROM users WHERE created_at >= '2024-01-01'
)
SELECT ...
```

**[PostgreSQL 12+]** only. Earlier Postgres versions and other dialects do
not have this hint syntax.

### Why This Matters in Practice

Imagine a CTE that pre-filters a huge table (say, `orders` with 10 million
rows) down to a smaller set, before joining it to something else:

- If the planner **inlines** the CTE and the outer join has a highly
  selective condition, inlining can be *faster* — the selective filter gets
  pushed down and Postgres never materializes rows it doesn't need.
- If the planner **inlines** the CTE but the CTE is referenced from inside a
  loop-like construct (e.g., a correlated subquery, or joined many times),
  inlining can cause the same expensive filter logic to be **re-evaluated
  repeatedly** — this is the scenario where explicit `MATERIALIZED` protects
  you, by guaranteeing the filter runs exactly once.
- Always verify with `EXPLAIN (ANALYZE, BUFFERS)` rather than assuming either
  behavior — the planner's default choice is usually right, but "usually"
  is not "always."

### Contrast with Subqueries

A plain subquery (in `FROM`, or as a scalar/`IN`/`EXISTS` predicate) has
never carried the "materialize me" contract that pre-12 Postgres CTEs did —
the optimizer has always been free to merge, flatten, or rewrite a subquery
into the surrounding plan however it sees fit (subject to correctness). This
is precisely why, historically, some Postgres performance guides advised
"prefer subqueries over CTEs when you just want the planner to have maximum
freedom" — advice that is now largely obsolete for non-recursive CTEs on
PostgreSQL 12+, but still applies verbatim to pre-12 Postgres and to any
database whose optimizer still always materializes CTEs.

### Other Dialects, Briefly

| Dialect | Default CTE materialization behavior |
|---|---|
| **PostgreSQL 12+** | May inline non-recursive, single-reference CTEs; `MATERIALIZED`/`NOT MATERIALIZED` override the default |
| **PostgreSQL < 12** | Always materializes every CTE (the "optimization fence") |
| **MySQL 8+** | Optimizer may inline (merge) a non-recursive CTE similarly to a derived table, but is more likely to materialize a CTE referenced more than once |
| **Oracle** | Optimizer may inline `WITH` clause subqueries; `/*+ MATERIALIZE */` hint forces materialization when you need it |
| **SQL Server** | Treats non-recursive CTEs like derived tables/views for planning purposes — no separate "materialize" concept exposed to the query author; the optimizer decides per-plan |

### Guidance

- Use CTEs primarily for **readability** and for **recursion** — that's what
  they're for, and on any modern engine the non-recursive case carries
  little to no inherent performance penalty versus a subquery.
- If you suspect a CTE that pre-filters a large table is being
  re-evaluated more times than you want (or, conversely, is blocking a
  predicate pushdown that would help), **check the actual plan** with
  `EXPLAIN ANALYZE` before reaching for `MATERIALIZED`/`NOT MATERIALIZED` —
  don't guess.
- Recursive CTEs are always materialized by necessity; there is nothing to
  tune here beyond making the recursive term itself efficient (index the
  join column — e.g., `employees.manager_id` — so each iteration's join is
  an index scan, not a sequential scan).

---

## 9.11 Common Mistakes

1. **`UNION` instead of `UNION ALL` in a recursive CTE.** `UNION` deduplicates
   by comparing every new row against the *entire* accumulated result set on
   every iteration — expensive, and it does **not** reliably prevent
   infinite recursion: if your recursive term carries a `level` or `path`
   column (as most useful recursive CTEs do), every row is already unique,
   so `UNION`'s deduplication never actually triggers, and cyclic data will
   still recurse forever while paying extra comparison cost the whole way.
   Default to `UNION ALL` and build your own cycle guard (§9.9) when needed.
2. **Forgetting the `RECURSIVE` keyword** **[PostgreSQL, MySQL 8+]** — the
   query fails with a "relation does not exist" style error the moment the
   recursive term tries to reference the CTE's own name.
3. **No termination condition on cyclic data** — the classic infinite loop.
   Always ask "could this data legitimately contain a cycle?" before writing
   a recursive query over a self-referencing table that isn't guaranteed to
   be a strict tree.
4. **Column mismatch between the base and recursive terms.** Like any
   `UNION`/`UNION ALL`, both `SELECT`s in a recursive CTE must return the
   same number of columns, in the same order, with compatible types. A
   common slip is adding a computed column (like `level`) to the recursive
   term's `SELECT` but forgetting to seed it in the base term.
5. **Trying to `ORDER BY`, use aggregates, `DISTINCT`, `GROUP BY`, or window
   functions inside the recursive term itself.** PostgreSQL explicitly
   disallows these inside the recursive term — they'd break the incremental,
   row-by-row semantics the working table depends on. Sort, aggregate, or
   deduplicate in the **final** `SELECT` that wraps the whole CTE, not inside
   the recursive term.
6. **Referencing the CTE's own name more than once in the recursive term,**
   or referencing it from the nullable side of an outer join, or from inside
   a subquery — PostgreSQL requires exactly one, unconditional, top-level
   self-reference in the recursive term.
7. **Assuming row order is preserved without an explicit `ORDER BY`.** The
   order rows are produced in (roughly breadth-first, iteration by
   iteration) is an implementation detail, not a guarantee. Always add an
   explicit `ORDER BY` on the final `SELECT` — the `path`-array technique
   from §9.5 is a reliable way to get a proper depth-first tree ordering.

---

## 9.12 Edge Cases

- **A row that is its own manager** (`manager_id = employee_id`) creates an
  immediate single-node cycle — the base/recursive join would keep
  "finding" the same row forever without a guard.
- **`NULL` as the root condition.** The base term must filter
  `manager_id IS NULL` (or `parent_category_id IS NULL`), never
  `manager_id = NULL` — the latter is never true in SQL's three-valued logic
  and would silently produce zero base rows (and therefore zero total rows).
- **A forest, not a single tree** — `ecommerce_db.categories` has three
  separate roots (`Electronics`, `Fashion`, `Home & Kitchen`). A base term
  filtering on `IS NULL` naturally handles any number of roots at once; you
  don't need to special-case "there might be more than one tree."
- **Dangling references.** `employees.manager_id` and
  `categories.parent_category_id` are enforced by foreign keys here, so true
  orphans can't exist in this seed data — but `ON DELETE SET NULL` on
  `employees.manager_id` means deleting a manager turns their direct reports
  into *new roots*, which your recursive query should handle gracefully
  (and will, automatically, since they'll simply satisfy the base term's
  `IS NULL` filter after the deletion).
- **An anchor filter that matches nothing** (e.g., a typo like
  `WHERE employee_id = 999`) doesn't error — it silently returns zero rows,
  which can be mistaken for "this employee has no reports" rather than "this
  employee doesn't exist."
- **Legitimately deep hierarchies hitting a default recursion cap** — SQL
  Server's default `MAXRECURSION 100` or MySQL's default
  `cte_max_recursion_depth = 1000` can truncate a correct, non-cyclic result
  if your real hierarchy is deeper than the default cap; raise the limit
  deliberately rather than assuming the shallow default is safe for all data.

---

## 9.13 CTEs vs. Subqueries vs. Temp Tables vs. Views

| | Scope | Reusable across statements? | Can be recursive? | Indexable? | Best for |
|---|---|---|---|---|---|
| **Subquery** | One clause of one statement | No | No | No | A simple, one-off filter; maximum optimizer freedom to merge/rewrite |
| **CTE** | One statement | No | **Yes** | No | Naming intermediate steps for readability; the *only* portable, declarative option for hierarchy/graph recursion |
| **Temp table** | Session/transaction (Chapter 24) | Yes, within the session | No (but can be built by an iterative/procedural loop) | Yes | A large intermediate result scanned multiple times, or needed across several separate statements |
| **View** | Persisted schema object (Chapter 15) | Yes, across sessions and applications | Yes (a view can itself contain a recursive CTE) | Only if materialized | Reusable business logic that many different queries/users need over time |

**Rule of thumb:** reach for a CTE by default when you want to name a step
for readability or when you need recursion; reach for a plain subquery when
the logic is small and one-off; reach for a temp table when the intermediate
result is large, reused many times, or needs its own index; reach for a view
when the logic needs to outlive a single query and be shared by other code.

---

## 9.14 Real-World Use Cases

- **Org charts** — exactly as shown in §9.5–9.6: reporting structure,
  span-of-control reports, "who is N levels below the CEO."
- **Bill-of-materials (BOM) explosion** — a manufactured product composed of
  sub-assemblies, which are themselves composed of parts. Structurally
  identical to the category tree in §9.7: a `parts` table with a
  `parent_part_id`, recursively expanded to compute "everything that goes
  into product X" or "total quantity of raw material Y needed."
- **Threaded/nested comments** — a `comments` table with
  `parent_comment_id`, recursively expanded to render a comment thread in
  proper nested display order (see Practice Question 10).
- **Category/menu trees** — as in §9.7: e-commerce category navigation,
  CMS menu structures, permission/role inheritance hierarchies.
- **File systems** — as in §9.8: folder trees, breadcrumb navigation.
- **Graph reachability and dependency analysis** — as in §9.9: "which
  services would be affected if this one goes down," "which tasks must
  finish before this one can start," social-network "friends of friends"
  queries.
- **Sequence/series generation as a loop substitute** — recursive CTEs are
  also commonly used to generate a calendar of dates, a numeric sequence, or
  an amortization/compounding schedule, one row per iteration, without a
  procedural loop.

---

## 9.15 Practice Questions

No answers are provided — work through these against `company_db` and
`ecommerce_db` as seeded.

1. Write a recursive CTE that lists every employee reporting, directly or
   indirectly, to **Nikhil Gupta** (`employee_id = 12`), with a `depth`
   column.
2. Using one non-recursive CTE to compute each department's average current
   salary, and a second, chained CTE, list only the departments whose
   average exceeds the *company-wide* average current salary.
3. Write a recursive CTE that computes, for every employee, the total number
   of people below them in the hierarchy (direct plus indirect reports).
4. Extend the category-tree recursive CTE (§9.7) so it also returns, for
   every leaf category, the name of its top-level root category.
5. Write a recursive CTE that starts at the **`Women`** category and walks
   *upward* to the root — i.e., reverse the direction of the recursive
   term's join compared to §9.7.
6. Describe (in a SQL comment) what row you would need to insert into
   `employees` to create a cycle in the `manager_id` hierarchy, then write a
   guarded recursive CTE (using the visited-path technique from §9.9) that
   would survive it without infinite recursion.
7. Pick a three-level nested subquery you wrote for a Chapter 8 exercise and
   rewrite it as a chain of two or three named CTEs. Compare the readability
   of the two versions.
8. **[PostgreSQL 12+]** Write two versions of a query that pre-filters
   `orders` inside a CTE before joining to `order_items` — one using
   `MATERIALIZED`, one using `NOT MATERIALIZED` — and compare the plans with
   `EXPLAIN`.
9. Using `orders` and `order_items`, write a CTE that computes total revenue
   per user, then a second, chained CTE that ranks users by that revenue,
   then select only the top 3 users.
10. Design (on paper — no seed data required) a `comments` table schema for
    a threaded-comments feature (self-referencing `parent_comment_id`), and
    sketch the recursive CTE you would use to fetch an entire comment thread
    in proper nested display order.

---

## 9.16 Chapter Challenge

**Build a recursive CTE report that shows every employee's full management
chain, from the CEO down to themselves, as a single string** — for example:

```
Aditi Rao > Rahul Mehta > Sneha Kulkarni > Karan Verma
```

The CEO's own row should simply read `"Aditi Rao"`. Order the results so the
report reads as a properly nested tree (reuse the `path`-array `ORDER BY`
technique from §9.5).

### Solution

```sql
WITH RECURSIVE management_chain AS (
    -- Base term: the CEO — chain is just their own name
    SELECT
        employee_id,
        first_name || ' ' || last_name AS employee_name,
        manager_id,
        (first_name || ' ' || last_name)::text AS chain,
        ARRAY[employee_id]                       AS path
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    -- Recursive term: append this employee's name to their manager's chain
    SELECT
        e.employee_id,
        e.first_name || ' ' || e.last_name,
        e.manager_id,
        mc.chain || ' > ' || e.first_name || ' ' || e.last_name,
        mc.path || e.employee_id
    FROM employees e
    JOIN management_chain mc ON e.manager_id = mc.employee_id
)
SELECT employee_id, employee_name, chain
FROM management_chain
ORDER BY path;
```

### Expected Output

| employee_id | employee_name | chain |
|---|---|---|
| 1 | Aditi Rao | Aditi Rao |
| 2 | Rahul Mehta | Aditi Rao > Rahul Mehta |
| 3 | Sneha Kulkarni | Aditi Rao > Rahul Mehta > Sneha Kulkarni |
| 6 | Karan Verma | Aditi Rao > Rahul Mehta > Sneha Kulkarni > Karan Verma |
| 4 | Vikram Joshi | Aditi Rao > Rahul Mehta > Vikram Joshi |
| 5 | Ananya Singh | Aditi Rao > Rahul Mehta > Ananya Singh |
| 16 | Aman Chawla | Aditi Rao > Rahul Mehta > Aman Chawla |
| 7 | Priya Nair | Aditi Rao > Priya Nair |
| 8 | Arjun Das | Aditi Rao > Priya Nair > Arjun Das |
| 9 | Meera Pillai | Aditi Rao > Priya Nair > Meera Pillai |
| 10 | Rohan Kapoor | Aditi Rao > Rohan Kapoor |
| 11 | Isha Bhatt | Aditi Rao > Rohan Kapoor > Isha Bhatt |
| 12 | Nikhil Gupta | Aditi Rao > Nikhil Gupta |
| 13 | Divya Shah | Aditi Rao > Nikhil Gupta > Divya Shah |
| 14 | Rajesh Iyer | Aditi Rao > Rajesh Iyer |
| 15 | Pooja Reddy | Aditi Rao > Rajesh Iyer > Pooja Reddy |

**Why it works:** the base term seeds `chain` with just the CEO's own name
(the only row with `manager_id IS NULL`). Every recursive step takes the
*already-built* chain string from the parent row (`mc.chain`) and appends
`' > '` plus the current employee's own name — so by the time the recursion
reaches a leaf employee like Karan Verma, `chain` has accumulated every
ancestor's name in root-to-leaf order, exactly once each, with no possibility
of missing a link or looping (the tree structure of `manager_id` guarantees
no cycles here, unlike the illustrative graph in §9.9).

---

## Key Takeaways

- A **CTE** (`WITH ... AS (...)`) names an intermediate result for one
  statement — it exists purely for readability and does not persist,
  materialize as a table you can index, or get reused across queries.
- Multiple CTEs in one `WITH` clause can be independent, or **chained**,
  where a later CTE references an earlier one — build multi-step pipelines
  this way instead of nesting nine levels of subqueries.
- A **recursive CTE** (`WITH RECURSIVE` **[PostgreSQL/MySQL 8+]**, plain
  `WITH` **[SQL Server]**, or `CONNECT BY PRIOR` **[Oracle]**) is the only
  portable, declarative tool for walking a hierarchy or graph of unknown
  depth: a base term seeds the starting rows, a recursive term repeatedly
  joins back to the CTE's own name, and `UNION ALL` accumulates every row
  until an iteration produces none.
- Always use `UNION ALL`, not `UNION`, in recursive CTEs, and always design
  a termination guard (a depth cap, or a visited-path array) whenever the
  underlying data could contain a cycle — recursive CTEs do not stop on
  their own over cyclic data.
- Since PostgreSQL 12, non-recursive CTEs referenced once may be **inlined**
  by the planner like a subquery; older Postgres, and CTEs referenced
  multiple times or that are recursive, are always **materialized**. Use
  `MATERIALIZED`/`NOT MATERIALIZED` **[PostgreSQL 12+]** to force a choice
  when `EXPLAIN ANALYZE` shows the default isn't ideal.
- Choose CTEs for readability and recursion, subqueries for small one-off
  filters, temp tables for large reused intermediate results, and views for
  logic that needs to outlive a single query.

## What's Next

Chapter 10 moves from *naming* intermediate results to computing values
**across rows without collapsing them** — `ROW_NUMBER()`, `RANK()`,
`LAG()`/`LEAD()`, running totals, and the `OVER (PARTITION BY ... ORDER BY ...)`
clause. You'll also see the portable, standard way to get "latest row per
group" (replacing this chapter's PostgreSQL-only `DISTINCT ON` trick from
§9.3) using `ROW_NUMBER()` — one of the most common real-world uses of window
functions.

**Next:** [Chapter 10 — Window Functions](10-window-functions.md)
