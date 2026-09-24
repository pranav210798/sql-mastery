# Chapter 33 — Interview Preparation: Intermediate Tier (75+ Q&A)

> **Scope:** This tier maps to Chapters 7–14 of the course — Joins, Subqueries,
> CTEs & Recursive CTEs, Window Functions (basics), Transactions & ACID,
> Locks & Concurrency, Constraints, and Database Design & Normalization.
> Every coding question runs against the three canonical databases —
> `company_db`, `ecommerce_db`, `banking_db` — and every result shown is the
> **actual output** you get from the seed data in `databases/`. Primary
> dialect is **PostgreSQL**; dialect notes call out MySQL / SQL Server /
> Oracle divergence where it genuinely matters at this level.
>
> Each question follows the same structure: **Question → Answer → Why it
> works → Alternative approaches → Performance considerations → Common
> mistakes**.
>
> Session setup used throughout (already done for you by the seed scripts,
> shown here for clarity):
> ```sql
> \i databases/company_db.sql
> \i databases/ecommerce_db.sql
> \i databases/banking_db.sql
> -- then, per section:
> SET search_path TO company_db;   -- or ecommerce_db / banking_db
> ```

---

## Table of Contents

1. [Joins](#1-joins) (Q1–Q19)
2. [Subqueries](#2-subqueries) (Q20–Q31)
3. [CTEs & Recursive CTEs](#3-ctes--recursive-ctes) (Q32–Q43)
4. [Window Functions Basics](#4-window-functions-basics) (Q44–Q55)
5. [Transactions & ACID](#5-transactions--acid) (Q56–Q64)
6. [Locks & Concurrency](#6-locks--concurrency) (Q65–Q73)
7. [Constraints](#7-constraints) (Q74–Q81)
8. [Database Design & Normalization](#8-database-design--normalization) (Q82–Q89)

---

## 1. Joins

Joins are where most real-world SQL bugs live: silent row duplication from
fan-out, accidental row loss from filtering a `LEFT JOIN` in the `WHERE`
clause, and confusion about `ON` vs `WHERE` semantics. This section drills
the mechanics using `company_db` and `ecommerce_db`.

### Q1. What is the difference between `ON` and `WHERE` in a query with an outer join?

**Answer:** `ON` decides which rows are *matched* while the join is being
built — it runs *before* outer rows get NULL-padded. `WHERE` filters the
*result* of the join — it runs *after* NULL-padding has already happened.
For an `INNER JOIN` the two are logically equivalent (any condition can be
written in either place with the same result), but for `LEFT`/`RIGHT`/`FULL`
joins they are **not** interchangeable, because a `WHERE` condition that
references the nullable (outer) side will discard the very padded-NULL rows
the outer join was written to preserve.

```sql
-- ON: still keeps every department, even ones with 0 matching employees
SELECT d.department_name, e.first_name
FROM departments d
LEFT JOIN employees e ON d.department_id = e.department_id AND e.status = 'ACTIVE';

-- WHERE: silently degrades to an INNER JOIN
SELECT d.department_name, e.first_name
FROM departments d
LEFT JOIN employees e ON d.department_id = e.department_id
WHERE e.status = 'ACTIVE';
```

**Why it works:** The join algorithm evaluates `ON` per candidate pair to
decide match/no-match; unmatched left rows are still emitted once, padded
with NULLs on the right. `WHERE` then evaluates against the *already
produced* rows, including those NULL-padded ones — and `NULL = 'ACTIVE'` is
`UNKNOWN`, which `WHERE` treats as "exclude."

**Alternative approaches:** Some engines let you express the same "keep
outer rows" intent with `WHERE (e.status = 'ACTIVE' OR e.employee_id IS
NULL)`, but this is fragile and hard to read — always prefer moving the
condition into `ON`.

**Performance considerations:** Putting selective filters in `ON` for the
*inner* (non-preserved) side can also help the planner choose a more
efficient join order/algorithm (e.g., hash join building a smaller hash
table from a pre-filtered inner relation) — see Q2 for a full worked example
with real numbers.

> **Common mistakes**
> - Assuming `ON` vs `WHERE` never matters — it matters specifically for
>   outer joins.
> - Writing an outer join and then "fixing" unexpected row loss by adding
>   `OR column IS NULL` instead of moving the predicate to `ON`.
> - Forgetting the rule applies to *any* right-table predicate, not just
>   equality — `WHERE e.department_id > 0` after a `LEFT JOIN` has the same
>   degrading effect.

---

### Q2. Diagnostic: this query is supposed to show every department's count of employees hired after 2020-01-01 (including departments with zero such hires), but it silently drops two departments. Find and fix the bug.

```sql
-- BUGGY
SELECT d.department_name, COUNT(e.employee_id) AS new_hires
FROM departments d
LEFT JOIN employees e ON d.department_id = e.department_id
WHERE e.hire_date > '2020-01-01'
GROUP BY d.department_name
ORDER BY d.department_name;
```

Running this returns only **3 rows** — Engineering, Marketing, Sales — HR
and Finance vanish entirely, even though the requirement was to show them
with `0`.

**Answer:** The bug is exactly the Q1 pattern: `hire_date > '2020-01-01'` is
a predicate on the nullable (right) side, applied in `WHERE`. HR and Finance
employees were all hired before 2020, so the `LEFT JOIN` produces rows for
them but `WHERE` then filters every one of those rows out — leaving no row
at all for HR or Finance to `GROUP BY`. Fix by moving the condition into
`ON`:

```sql
-- [PostgreSQL] FIXED
SELECT d.department_name, COUNT(e.employee_id) AS new_hires
FROM departments d
LEFT JOIN employees e
       ON d.department_id = e.department_id
      AND e.hire_date > '2020-01-01'
GROUP BY d.department_name
ORDER BY d.department_name;
```

**Actual output:**

| department_name | new_hires |
|---|---|
| Engineering | 2 |
| Finance | 0 |
| HR | 0 |
| Marketing | 1 |
| Sales | 1 |

(Engineering = Karan Verma 2020-02-10 + Aman Chawla 2022-01-10; Sales = Meera
Pillai 2021-03-22; Marketing = Pooja Reddy 2020-10-05; HR's Rohan/Isha and
Finance's Nikhil/Divya were all hired 2016–2019.)

**Why it works:** Moving the date filter into `ON` means it only decides
*which employee rows match*, not *which department rows survive*. Every
department row is preserved by the outer join regardless of how many (or
zero) employees satisfy the extra condition; `COUNT(e.employee_id)` correctly
returns `0` for a department whose only joined row is the NULL-padded one
(`COUNT` on a column skips NULLs, `COUNT(*)` would not).

**Alternative approaches:** Use a scalar subquery per department instead of
a join: `SELECT d.department_name, (SELECT COUNT(*) FROM employees e WHERE
e.department_id = d.department_id AND e.hire_date > '2020-01-01') FROM
departments d;` — avoids the join pitfall entirely at the cost of one
subquery execution per department row (fine at this table size, poor at
scale without an index on `(department_id, hire_date)`).

**Performance considerations:** `COUNT(e.employee_id)` vs `COUNT(*)` matters
here specifically because of the outer join — always count a *nullable*
join-column when the goal is "count only real matches." An index on
`employees(department_id, hire_date)` would let the planner do an efficient
index range scan per department in the correlated-subquery alternative.

> **Common mistakes**
> - Not noticing the row count dropped from 5 to 3 departments — always
>   sanity-check output cardinality against the known dimension table size.
> - "Fixing" it by adding `OR e.employee_id IS NULL` to `WHERE`, which
>   happens to work only because there's exactly one join column check —
>   it breaks the moment a second condition is added.
> - Using `COUNT(*)` instead of `COUNT(e.employee_id)`, which would report
>   `1` (counting the NULL-padded row itself) instead of `0` for HR/Finance.

---

### Q3. The classic gotcha: why does `NOT IN` sometimes return zero rows even when you're sure some rows should match?

```sql
SELECT employee_id, first_name, last_name
FROM employees
WHERE employee_id NOT IN (SELECT manager_id FROM employees);
```

**Answer:** This returns **0 rows** on `company_db.employees`, even though 9
of the 16 employees have never managed anyone. The trap: `employees.manager_id`
contains a `NULL` for Aditi Rao (the CTO, who has no manager). The subquery
`SELECT manager_id FROM employees` therefore returns the set
`{1,2,3,7,10,12,14, NULL}`. SQL's `NOT IN (list)` is defined as `x <> v1 AND
x <> v2 AND ... AND x <> NULL`. Any comparison to `NULL` yields `UNKNOWN`,
and `UNKNOWN` in an `AND` chain poisons the whole expression to `UNKNOWN` —
which `WHERE` treats as "not true," so **every row is excluded**, regardless
of `employee_id`.

```sql
-- FIXED: filter the NULL out of the subquery
SELECT employee_id, first_name, last_name
FROM employees
WHERE employee_id NOT IN (SELECT manager_id FROM employees WHERE manager_id IS NOT NULL)
ORDER BY employee_id;
```

**Actual output** (9 rows): `4 Vikram Joshi, 5 Ananya Singh, 6 Karan Verma,
8 Arjun Das, 9 Meera Pillai, 11 Isha Bhatt, 13 Divya Shah, 15 Pooja Reddy,
16 Aman Chawla`.

**Why it works:** Filtering `manager_id IS NOT NULL` removes the poisoning
`NULL` from the candidate list, restoring normal three-valued-logic behavior
for every real comparison.

**Alternative approaches:** `NOT EXISTS` is immune to this trap by
construction and is the idiomatic fix:
```sql
SELECT employee_id, first_name, last_name
FROM employees e
WHERE NOT EXISTS (SELECT 1 FROM employees m WHERE m.manager_id = e.employee_id)
ORDER BY employee_id;
```
This returns the identical 9 rows without needing to remember to filter
NULLs. A `LEFT JOIN ... WHERE right.key IS NULL` anti-join is a third
equivalent, join-based formulation.

**Performance considerations:** Modern Postgres often rewrites `NOT IN`
against a `NOT NULL` column into an anti-join automatically, but when the
subquery column is nullable (as here) it **cannot** safely do that rewrite
and typically falls back to a slower correlated-style evaluation. `NOT
EXISTS` and anti-join `LEFT JOIN` forms give the planner an unambiguous
anti-join to optimize regardless of nullability, and both can use an index
on the referenced column (`employees(manager_id)`).

> **Common mistakes**
> - Using `NOT IN` against any subquery column that isn't declared
>   `NOT NULL` — this is one of the highest-frequency real production bugs.
> - Believing the fix is "always use `NOT EXISTS`" without understanding
>   *why* — interviewers routinely ask you to explain the three-valued logic.
> - Confusing this with the (harmless) fact that plain `IN` does **not**
>   have this problem — `x IN (1,2,NULL)` correctly returns rows where
>   `x=1` or `x=2`; only the *negated* form breaks.

---

### Q4. `EXISTS` vs `IN` — when do they differ, and which should you default to?

**Answer:** Semantically, for well-behaved (non-NULL) columns, `IN` and
`EXISTS` return the same rows. The practical differences:

- **NULL-safety:** `NOT EXISTS` never falls into the Q3 trap; `NOT IN` does.
- **Correlation:** `EXISTS` subqueries are typically *correlated* (reference
  the outer row) and can short-circuit on the first match; `IN` subqueries
  are usually evaluated once into a full list/hash set.
- **Row shape:** `EXISTS` only cares about *presence*, so `SELECT 1` inside
  it is idiomatic and the column list is irrelevant to the result.

```sql
-- [PostgreSQL] Customers (banking_db) who have at least one loan
SELECT c.customer_id, c.first_name, c.last_name
FROM customers c
WHERE EXISTS (SELECT 1 FROM loans l WHERE l.customer_id = c.customer_id)
ORDER BY c.customer_id;
```

**Actual output:** customers 1 (Ravi Shankar), 2 (Neha Agarwal), 3 (Suresh
Menon), 4 (Kavita Desai) — Manoj Tiwari (5) is excluded (no loan row).

**Why it works:** The correlated subquery is evaluated per outer row and
returns as soon as one matching `loans` row is found (or none), which is
exactly the presence-test semantics `EXISTS` was designed for.

**Alternative approaches:**
```sql
SELECT DISTINCT c.customer_id, c.first_name, c.last_name
FROM customers c JOIN loans l ON l.customer_id = c.customer_id
ORDER BY c.customer_id;
```
gives the same 4 rows via a join + `DISTINCT`, or:
```sql
SELECT customer_id, first_name, last_name FROM customers
WHERE customer_id IN (SELECT customer_id FROM loans);
```
gives the same result with `IN` (safe here because `loans.customer_id` is
`NOT NULL`).

**Performance considerations:** With a good index on `loans(customer_id)`,
`EXISTS` typically wins for large outer tables + small/selective matches
because of the short-circuit; the `JOIN + DISTINCT` form risks fan-out row
bloat before the `DISTINCT` collapses it (wasteful if a customer has many
loans) and requires an extra sort/hash for de-duplication. The optimizer
often produces the same semi-join plan for all three on Postgres, but
`EXISTS`/`NOT EXISTS` remain the safest to *write* correctly.

> **Common mistakes**
> - Defaulting to `JOIN + DISTINCT` for pure existence checks, causing
>   avoidable row multiplication before de-duplication.
> - Using `NOT IN` for the negative case out of habit (see Q3).
> - Believing `EXISTS` requires `SELECT *` — the selected columns inside
>   `EXISTS` are never materialized; `SELECT 1` is the idiom.

---

### Q5. What's the difference between `INNER JOIN`, `LEFT JOIN`, `RIGHT JOIN`, and `FULL OUTER JOIN`? Demonstrate with real row counts.

**Answer:** Using `company_db.departments` (5 rows) and `company_db.projects`
(5 rows, all with non-NULL `department_id`, all department IDs 1–5 covered):

```sql
SELECT COUNT(*) FROM departments d INNER JOIN projects p ON d.department_id = p.department_id;      -- 5
SELECT COUNT(*) FROM departments d LEFT  JOIN projects p ON d.department_id = p.department_id;      -- 5
SELECT COUNT(*) FROM departments d RIGHT JOIN projects p ON d.department_id = p.department_id;      -- 5
SELECT COUNT(*) FROM departments d FULL  JOIN projects p ON d.department_id = p.department_id;      -- 5
```

Every join type returns 5 here because the relationship happens to be
perfectly 1:1 in this seed (each of the 5 departments sponsors exactly one
project). To see the types actually diverge, join `departments` (5 rows)
against `employee_projects` filtered to **project managers only** — or more
simply, join `employees` (16 rows) to `managers` (5 rows, one row per
department head):

```sql
SELECT COUNT(*) FROM employees e INNER JOIN managers m ON e.employee_id = m.manager_id; -- 5  (only the 5 managers)
SELECT COUNT(*) FROM employees e LEFT  JOIN managers m ON e.employee_id = m.manager_id; -- 16 (all employees, 11 NULL-padded)
SELECT COUNT(*) FROM employees e FULL  JOIN managers m ON e.employee_id = m.manager_id; -- 16 (managers is a subset of employees, so FULL = LEFT here)
```

**Why it works:** `INNER JOIN` keeps only rows with a match on both sides.
`LEFT JOIN` keeps every left row, NULL-padding unmatched right columns.
`RIGHT JOIN` is the mirror image. `FULL JOIN` keeps every row from both
sides, NULL-padding whichever side didn't match — it's the union of what
`LEFT` and `RIGHT` would each produce.

**Alternative approaches:** `RIGHT JOIN` is rarely used in practice because
you can always rewrite it as a `LEFT JOIN` by swapping table order — most
style guides ban `RIGHT JOIN` for readability.

**Performance considerations:** `INNER JOIN` gives the planner the most
freedom (it can reorder tables and pick either side to drive the scan);
outer joins constrain join order because the "preserved" side must remain
on its designated side of the operation, which can prevent otherwise
attractive plans.

> **Common mistakes**
> - Assuming `FULL OUTER JOIN` is universally supported — **MySQL has no
>   `FULL OUTER JOIN`** syntax; emulate it with
>   `LEFT JOIN ... UNION ALL LEFT JOIN ... ` swapped, filtered to
>   unmatched right rows only (or `UNION` of `LEFT` and `RIGHT` results).
> - Using `RIGHT JOIN` and then reasoning about it as if it were a `LEFT
>   JOIN` with tables in the written order — it isn't; the *right* table is
>   the one preserved.

---

### Q6. Coding: for each employee, show their full name, department name, and their manager's full name (self-join), ordered by department then employee name.

```sql
-- [PostgreSQL]
SELECT e.first_name || ' ' || e.last_name AS employee,
       d.department_name,
       COALESCE(m.first_name || ' ' || m.last_name, '— (no manager)') AS manager
FROM employees e
JOIN departments d ON e.department_id = d.department_id
LEFT JOIN employees m ON e.manager_id = m.employee_id
ORDER BY d.department_name, e.first_name;
```

**Actual output (16 rows):**

| employee | department_name | manager |
|---|---|---|
| Aditi Rao | Engineering | — (no manager) |
| Aman Chawla | Engineering | Rahul Mehta |
| Ananya Singh | Engineering | Rahul Mehta |
| Karan Verma | Engineering | Sneha Kulkarni |
| Rahul Mehta | Engineering | Aditi Rao |
| Sneha Kulkarni | Engineering | Rahul Mehta |
| Vikram Joshi | Engineering | Rahul Mehta |
| Nikhil Gupta | Finance | Aditi Rao |
| Divya Shah | Finance | Nikhil Gupta |
| Isha Bhatt | HR | Rohan Kapoor |
| Rohan Kapoor | HR | Aditi Rao |
| Pooja Reddy | Marketing | Rajesh Iyer |
| Rajesh Iyer | Marketing | Aditi Rao |
| Arjun Das | Sales | Priya Nair |
| Meera Pillai | Sales | Priya Nair |
| Priya Nair | Sales | Aditi Rao |

**Why it works:** `employees` is joined to itself under two aliases (`e` for
the "employee" role, `m` for the "manager" role). The manager side must be a
`LEFT JOIN` because Aditi Rao's `manager_id` is `NULL` — an `INNER JOIN`
here would silently drop the CTO from the results, which is the same
class of bug as Q2.

**Alternative approaches:** A correlated scalar subquery,
`(SELECT first_name || ' ' || last_name FROM employees m WHERE m.employee_id
= e.manager_id) AS manager`, avoids the extra join entirely and reads well
for a single derived column, but doesn't generalize if you need more than
one manager attribute.

**Performance considerations:** Self-joins on a foreign key that's indexed
(the PK of `employees` is indexed automatically) are cheap even at scale —
this is effectively a lookup join. For deep hierarchies (more than one level
up), a recursive CTE (Q32) is the right tool instead of chaining more
self-joins.

> **Common mistakes**
> - Using `INNER JOIN` for the manager side and losing top-of-hierarchy rows.
> - Forgetting table aliases and getting "ambiguous column" errors on
>   `employee_id`/`first_name`, which exist in both roles of the self-join.

---

### Q7. Diagnostic / fan-out trap: what's wrong with this query, and what's the *actual* number it returns vs. the *intended* number?

```sql
-- Intent: total historical base salary ever recorded for Rahul Mehta (employee_id 2)
SELECT e.employee_id, SUM(s.base_salary) AS total_salary
FROM employees e
JOIN employee_projects ep ON e.employee_id = ep.employee_id
JOIN salaries s ON e.employee_id = s.employee_id
WHERE e.employee_id = 2
GROUP BY e.employee_id;
```

**Answer:** This returns `total_salary = 1,200,000`, but the real sum of
Rahul's two salary rows (`280000` + `320000`) is `600,000` — the query is
**double** the correct value.

**Why it works (the bug):** Rahul has 2 rows in `employee_projects`
(Tech Lead on project 1 and project 2) and 2 rows in `salaries` (effective
2016 and 2021). Both are independent one-to-many relationships hanging off
`employees` with no relationship *to each other*. Joining both directly to
`employees` produces their **cross product** for that employee: 2 × 2 = 4
result rows — `(project1,280000), (project1,320000), (project2,280000),
(project2,320000)` — and summing `base_salary` over those 4 rows counts each
salary figure twice.

```sql
-- FIXED: pre-aggregate one side before joining
WITH total_salary AS (
    SELECT employee_id, SUM(base_salary) AS total_salary
    FROM salaries
    GROUP BY employee_id
)
SELECT e.employee_id, ts.total_salary
FROM employees e
JOIN total_salary ts ON e.employee_id = ts.employee_id
WHERE e.employee_id = 2;
-- total_salary = 600000
```

**Alternative approaches:** If you only need distinct salary rows and they
happen to be distinct values, `SUM(DISTINCT s.base_salary)` would coincidentally
give the right answer here (`280000 + 320000 = 600000`) — but this is a trap
in itself: it silently breaks the moment two genuinely distinct salary rows
share the same value. The robust fix is always to pre-aggregate one
many-side in a CTE/derived table (as above) or to use a window function
(`SUM(base_salary) OVER (PARTITION BY employee_id)`) computed *before* the
second join is introduced, e.g. inside a subquery.

**Performance considerations:** Fan-out joins are a common cause of
mysteriously wrong dashboard numbers and mysteriously *slow* queries at
scale (an accidental N×M cross product on large tables can turn a
million-row query into a billion-row one). Always ask "are these two joined
tables independent one-to-many relationships off the same parent?" before
trusting a `SUM`/`COUNT` across a multi-join query.

> **Common mistakes**
> - Joining two independent child tables directly to a shared parent and
>   aggregating without first collapsing one side.
> - "Fixing" the symptom with `SUM(DISTINCT ...)` instead of the structural
>   cause — works by accident, breaks on real-world data.
> - Not noticing the row count itself is wrong (`4` rows for one employee)
>   before even looking at the aggregate.

---

### Q8. Coding: total revenue and distinct-product count per customer, but only counting `DELIVERED` orders, including customers with zero delivered orders.

```sql
-- [PostgreSQL]
SELECT u.user_id, u.full_name,
       COALESCE(SUM(oi.quantity * oi.unit_price), 0) AS delivered_revenue,
       COUNT(DISTINCT oi.product_id) AS distinct_products
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id AND o.status = 'DELIVERED'
LEFT JOIN order_items oi ON o.order_id = oi.order_id
GROUP BY u.user_id, u.full_name
ORDER BY u.user_id;
```

**Actual output (8 rows):**

| user_id | full_name | delivered_revenue | distinct_products |
|---|---|---|---|
| 1 | Arjun Kumar | 95497.00 | 2 |
| 2 | Sara Patel | 5097.00 | 2 |
| 3 | Dev Malhotra | 0.00 | 0 |
| 4 | Nita Rao | 0.00 | 0 |
| 5 | Imran Sheikh | 75798.00 | 2 |
| 6 | Lakshmi Venkat | 0.00 | 0 |
| 7 | Farhan Ali | 0.00 | 0 |
| 8 | Tanya Bose | 3897.00 | 1 |

(User 1's delivered orders are #1 (₹49,498: Galaxy Phone X + Wireless
Earbuds) and #8 (₹45,999: Galaxy Phone X again) = ₹95,497 across 2 distinct
products.)

**Why it works:** The status filter is placed in the **first** `ON` clause
(not `WHERE`) so that users with *no* delivered orders still survive as one
row (Q1/Q2 pattern, chained two joins deep). `COALESCE` turns the resulting
`NULL` sum into `0` for readability, and `COUNT(DISTINCT ...)` on a nullable
column correctly returns `0` (not 1) when there are no matching rows.

**Alternative approaches:** Aggregate `order_items` first in a CTE keyed by
`order_id`, then join that to `orders`/`users` — avoids a three-table join
fan-out concern entirely and is easier to reason about:
```sql
WITH order_totals AS (
    SELECT order_id, SUM(quantity*unit_price) AS revenue, COUNT(DISTINCT product_id) AS n_products
    FROM order_items GROUP BY order_id
)
SELECT u.user_id, u.full_name,
       COALESCE(SUM(ot.revenue), 0) AS delivered_revenue,
       COALESCE(SUM(ot.n_products), 0) AS distinct_products  -- approximate if a user has >1 delivered order
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id AND o.status = 'DELIVERED'
LEFT JOIN order_totals ot ON o.order_id = ot.order_id
GROUP BY u.user_id, u.full_name;
```
Note the CTE version's `distinct_products` is only correct because no user
here has 2+ delivered orders sharing a product — for a fully general
solution, keep `COUNT(DISTINCT oi.product_id)` on the ungrouped join as in
the primary answer.

**Performance considerations:** Indexes on `orders(user_id, status)` and
`order_items(order_id)` (already the implicit FK index) make both joins
cheap. Because `order_items` fans out under `orders`, `COUNT(DISTINCT ...)`
must scan every matched row — fine at this scale, but on a huge orders
table pre-aggregating `order_items` once (CTE/materialized view) before
joining to `users` avoids repeating that work per report run.

> **Common mistakes**
> - Filtering `status = 'DELIVERED'` in `WHERE`, which drops users 3, 4, 6,
>   7 entirely instead of showing them with `0`.
> - Using `COUNT(oi.product_id)` (not `DISTINCT`) and reporting *line items*
>   instead of distinct products.
> - Forgetting `COALESCE` and reporting `NULL` instead of `0` for the
>   revenue of users with no delivered orders — breaks downstream `SUM`/sorting.

---

### Q9. Coding: revenue per product category, ranked highest to lowest, using `order_items → products → categories`.

```sql
-- [PostgreSQL]
SELECT c.category_name,
       SUM(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN products p   ON oi.product_id = p.product_id
JOIN categories c ON p.category_id = c.category_id
GROUP BY c.category_name
ORDER BY revenue DESC;
```

**Actual output:**

| category_name | revenue |
|---|---|
| Laptops | 255798.00 |
| Mobiles | 135993.00 |
| Men | 6495.00 |
| Home & Kitchen | 3998.00 |
| Women | 1799.00 |

(Total = 404,081.00, matching the sum of all 10 orders' line items.)

**Why it works:** Two straightforward inner joins walk the FK chain
`order_items → products → categories`; grouping on the category name
collapses all line items for every product in that category into one row.

**Alternative approaches:** If some category had **zero** sales, an inner
join would hide it — use `LEFT JOIN` from `categories` outward instead
(`categories c LEFT JOIN products p ... LEFT JOIN order_items oi ...`) to
guarantee every category appears, with `COALESCE(SUM(...), 0)`. In this
seed every category has at least one sale, so both forms currently agree.

**Performance considerations:** This is a classic star-schema-style rollup;
an index on `order_items(product_id)` and `products(category_id)` lets the
planner use index/hash joins instead of nested loops as row counts grow.
Pre-computing this into a materialized view (Chapter 15) is the standard
production answer once `order_items` reaches millions of rows.

> **Common mistakes**
> - Grouping by `category_id` but selecting `category_name` without adding
>   it to `GROUP BY` — Postgres will reject this outright (see Q17), unlike
>   MySQL's permissive mode.
> - Using `oi.unit_price` inconsistently with `p.price` — always use the
>   *transaction-time* price stored on `order_items`, not the current
>   catalog price on `products`, which can change after the sale.

---

### Q10. Coding: which departments have at least one project with a budget over ₹1,000,000? (`EXISTS` semi-join)

```sql
-- [PostgreSQL]
SELECT d.department_name
FROM departments d
WHERE EXISTS (
    SELECT 1 FROM projects p
    WHERE p.department_id = d.department_id
      AND p.budget > 1000000
)
ORDER BY d.department_name;
```

**Actual output:** `Engineering` (Platform Migration ₹5,000,000, Mobile App
Revamp ₹3,000,000), `Sales` (Q1 Sales Expansion ₹1,200,000).

**Why it works:** `EXISTS` performs a semi-join — for each department it
asks "does at least one qualifying project row exist?" without ever
duplicating the department row even if multiple projects qualify (Engineering
has two).

**Alternative approaches:** `JOIN + DISTINCT`:
```sql
SELECT DISTINCT d.department_name
FROM departments d JOIN projects p ON d.department_id = p.department_id
WHERE p.budget > 1000000;
```
gives the same 2 rows but must first materialize both Engineering project
rows before `DISTINCT` collapses them — semantically fine, just more work
for the same answer.

**Performance considerations:** A semi-join lets the planner stop scanning
`projects` for a department as soon as one qualifying row is found, whereas
`JOIN + DISTINCT` must produce and then de-duplicate every matching row —
noticeable when a department can have many qualifying projects.

> **Common mistakes**
> - Using `IN (SELECT department_id FROM projects WHERE budget > 1000000)`
>   — logically fine here (`projects.department_id` allows NULL, but no NULL
>   is present in the seed), yet fragile: add one project row with a `NULL`
>   `department_id` and the *negated* form (`NOT IN`) would break per Q3.
> - Forgetting `ORDER BY` and assuming department order is guaranteed —
>   it never is without one.

---

### Q11. Coding: for every job title held by more than one employee, list the pairs of employees who share it (self-join, avoiding duplicate/mirrored pairs).

```sql
-- [PostgreSQL]
SELECT e1.job_title,
       e1.first_name || ' ' || e1.last_name AS employee_a,
       e2.first_name || ' ' || e2.last_name AS employee_b
FROM employees e1
JOIN employees e2
  ON e1.job_title = e2.job_title
 AND e1.employee_id < e2.employee_id
ORDER BY e1.job_title, employee_a, employee_b;
```

**Actual output (4 rows):**

| job_title | employee_a | employee_b |
|---|---|---|
| Sales Executive | Arjun Das | Meera Pillai |
| Software Engineer | Vikram Joshi | Ananya Singh |
| Software Engineer | Vikram Joshi | Aman Chawla |
| Software Engineer | Ananya Singh | Aman Chawla |

**Why it works:** Joining `employees` to itself on matching `job_title`
would (without the ID inequality) produce every ordered pair including an
employee paired with themselves and each real pair listed twice (A,B and
B,A). `e1.employee_id < e2.employee_id` keeps exactly one direction per
unordered pair and removes self-pairs.

**Alternative approaches:** Compute this with `window` functions instead —
`array_agg(employee) OVER (PARTITION BY job_title)` then explode combinations
client-side — more complex for no benefit here; the self-join is the
idiomatic SQL answer for "all pairs sharing an attribute."

**Performance considerations:** Self-joins on a non-indexed text column
(`job_title` has no index here) force a hash or sort-merge join over the
full table; fine at 16 rows, but at scale you'd want an index on
`job_title` or to pre-bucket by title in a CTE before pairing.

> **Common mistakes**
> - Omitting the `<` (or using `<=` / `!=` alone), yielding self-pairs or
>   duplicate mirrored pairs.
> - Forgetting this only finds titles with **2+ holders** implicitly (a
>   title held by exactly one person naturally produces zero pairs) — no
>   `HAVING COUNT(*) > 1` needed because the self-join already encodes it.

---

### Q12. Diagnostic: `UNION` vs `UNION ALL` — show the row-count difference concretely.

```sql
-- Query A: everyone in Engineering (dept_id = 1)
SELECT email FROM employees WHERE department_id = 1;      -- 7 rows

-- Query B: everyone whose job title contains 'Manager'
SELECT email FROM employees WHERE job_title LIKE '%Manager%'; -- 5 rows
```

**Answer:**
```sql
SELECT email FROM employees WHERE department_id = 1
UNION
SELECT email FROM employees WHERE job_title LIKE '%Manager%';
-- returns 11 distinct rows
```
```sql
SELECT email FROM employees WHERE department_id = 1
UNION ALL
SELECT email FROM employees WHERE job_title LIKE '%Manager%';
-- returns 12 rows (rahul.mehta@company.com appears twice)
```

**Why it works:** Query A returns Aditi, Rahul, Sneha, Vikram, Ananya,
Karan, Aman (7 Engineering employees). Query B returns Rahul (Engineering
Manager), Priya, Rohan, Nikhil, Rajesh (5 managers by title; "CTO" doesn't
match `%Manager%`). Rahul Mehta appears in **both** sets. `UNION`
de-duplicates the combined 12 rows down to 11 distinct emails; `UNION ALL`
performs no de-duplication and keeps all 12, including Rahul's email twice.

**Alternative approaches:** `SELECT DISTINCT email FROM (... UNION ALL ...)
x` is functionally identical to plain `UNION` but makes the de-duplication
step explicit — occasionally clearer in a long pipeline of set operations.

**Performance considerations:** `UNION` must sort or hash the combined
result to remove duplicates — real cost on large sets. `UNION ALL` is a
simple concatenation with no such cost. **Default to `UNION ALL`** unless
you specifically need de-duplication; reaching for `UNION` out of habit is
a common source of avoidable sort/hash overhead in production queries.

> **Common mistakes**
> - Using `UNION` reflexively, paying de-duplication cost for two queries
>   that are already known to be disjoint.
> - Assuming column names/types don't need to line up — both branches must
>   have the same number of columns with compatible types; the final
>   column names come from the **first** `SELECT`.
> - Forgetting `ORDER BY` only applies once, at the very end of the whole
>   set operation, not per branch (unless wrapped in parentheses per-branch
>   with `LIMIT`, which changes semantics).

---

### Q13. Coding: what is a `CROSS JOIN` actually useful for? Build a coverage matrix of departments × attendance statuses to spot statuses never recorded per department.

```sql
-- [PostgreSQL]
WITH statuses(status) AS (
    VALUES ('PRESENT'), ('ABSENT'), ('LATE'), ('REMOTE'), ('LEAVE')
)
SELECT d.department_name, s.status,
       COUNT(a.attendance_id) AS occurrences
FROM departments d
CROSS JOIN statuses s
LEFT JOIN employees e ON e.department_id = d.department_id
LEFT JOIN attendance a ON a.employee_id = e.employee_id AND a.status = s.status
GROUP BY d.department_name, s.status
ORDER BY d.department_name, s.status;
```

**Answer (excerpt — attendance only exists for employees 3, 4, 5, 6, all in
Engineering):** Engineering shows non-zero counts for `ABSENT` (1), `LATE`
(1), `LEAVE` (2), `PRESENT` (5), `REMOTE` (1); every other department ×
status combination returns `0`. This makes the *absence* of data explicit
and queryable, rather than simply missing rows.

**Why it works:** `CROSS JOIN` produces the full Cartesian product of
departments (5) × statuses (5) = 25 template rows first — this is the one
scenario where a deliberate Cartesian product is exactly the goal, because
it guarantees every combination is represented before left-joining in
actual data.

**Alternative approaches:** Generate the status list from an actual
`CHECK` constraint enum table if one existed, or use
`unnest(ARRAY['PRESENT','ABSENT','LATE','REMOTE','LEAVE'])` instead of a
`VALUES` CTE — equivalent, different syntax.

**Performance considerations:** `CROSS JOIN` cardinality is multiplicative —
safe here (5×5=25) but catastrophic if applied to two large tables by
accident (a missing join predicate is the most common cause of runaway
query cost in production incidents). Always cross-join small, bounded
dimension sets, never fact tables.

> **Common mistakes**
> - Writing `FROM a, b` (old comma-join syntax) and forgetting a `WHERE`
>   predicate, accidentally creating a `CROSS JOIN` — this is the classic
>   "why does my join have a million rows" incident.
> - Believing `CROSS JOIN` is "always wrong" — it's the correct tool for
>   exactly this kind of coverage-matrix/date-spine template generation.

---

### Q14. Diagnostic: `NATURAL JOIN` — why is it dangerous, and what would go wrong if used between `orders` and `order_items`?

**Answer:** `NATURAL JOIN` automatically joins on **every column with a
matching name** in both tables, with no explicit `ON` clause. Between
`orders` and `order_items`, both tables happen to share `order_id` — so a
`NATURAL JOIN` would work *today*:

```sql
SELECT * FROM orders NATURAL JOIN order_items;  -- happens to work: joins on order_id
```

But this is fragile: if someone later adds an unrelated `status` column to
both tables (plausible — both already conceptually have "state"), or a
shared `created_at` audit column, `NATURAL JOIN` would silently start
joining on *those* columns too, changing the query's meaning with zero
syntax error and no warning.

**Why it works (when it "works"):** `NATURAL JOIN` is sugar for
`JOIN ... USING (<all identically-named columns>)`. It only produces correct
results by coincidence of the current schema shape.

**Alternative approaches:** `JOIN ... USING (order_id)` gets the convenience
of not repeating the table alias for the shared key, while being explicit
about *which* column drives the join — the safe middle ground between
verbose `ON` and dangerous `NATURAL JOIN`. Prefer explicit `ON` for anything
that will be read/maintained by others.

**Performance considerations:** No inherent performance difference from an
equivalent explicit join — the risk here is entirely correctness, not
speed.

> **Common mistakes**
> - Using `NATURAL JOIN` in production code at all — most style guides and
>   linters ban it outright for the reason above.
> - Confusing `NATURAL JOIN` with `JOIN ... USING`, which is explicit about
>   the join column(s) and does not silently change behavior when the
>   schema evolves.

---

### Q15. Coding: recursive-safe department report — list every department alongside its employee count *and* its highest current base salary, in one query.

```sql
-- [PostgreSQL]
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary
    FROM salaries
    ORDER BY employee_id, effective_date DESC
)
SELECT d.department_name,
       COUNT(e.employee_id) AS headcount,
       MAX(cs.base_salary)  AS top_base_salary
FROM departments d
LEFT JOIN employees e ON e.department_id = d.department_id
LEFT JOIN current_salary cs ON cs.employee_id = e.employee_id
GROUP BY d.department_name
ORDER BY d.department_name;
```

**Actual output:**

| department_name | headcount | top_base_salary |
|---|---|---|
| Engineering | 7 | 520000.00 |
| Finance | 2 | 250000.00 |
| HR | 2 | 240000.00 |
| Marketing | 2 | 230000.00 |
| Sales | 3 | 300000.00 |

**Why it works:** `DISTINCT ON (employee_id) ... ORDER BY employee_id,
effective_date DESC` is Postgres's idiom for "one row per employee, the
latest by `effective_date`" — it collapses the salary-history table to a
current-snapshot table *before* it's joined, avoiding the Q7 fan-out trap
entirely (this join is now 1:1 per employee, not 1:many).

**Alternative approaches:** Without `DISTINCT ON` (a Postgres-only
extension), use a window function instead:
```sql
current_salary AS (
    SELECT employee_id, base_salary,
           ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY effective_date DESC) AS rn
    FROM salaries
)
-- then filter rn = 1 in the outer query or a further CTE layer
```
This form is portable to MySQL 8+, SQL Server, and Oracle, none of which
support `DISTINCT ON`.

**Performance considerations:** `DISTINCT ON` with a matching `ORDER BY`
prefix can use an index on `salaries(employee_id, effective_date)`
efficiently (index skip-scan style); the window-function alternative
typically requires a full sort of the partition unless a similar index
exists.

> **Common mistakes**
> - Joining `salaries` directly without collapsing to "current" first,
>   reproducing the Q7 fan-out bug against `headcount` and `MAX`.
> - Using `MAX(effective_date)` and then a second join back to `salaries`
>   on that max date — works, but two round trips through the table instead
>   of one `DISTINCT ON`/window pass.

---

### Q16. Coding: `LEFT JOIN` anti-pattern check — find every product that has **never** appeared in an order (the "products with 0 sales" report).

```sql
-- [PostgreSQL]
SELECT p.product_id, p.product_name
FROM products p
LEFT JOIN order_items oi ON p.product_id = oi.product_id
WHERE oi.order_item_id IS NULL;
```

**Actual output:** **0 rows.** Every one of the 10 seeded products appears
in at least one `order_items` row (verified: distinct `product_id` values
across all 10 orders cover the full set `{1..10}`).

**Why it works:** This is the canonical, *correct* anti-join pattern:
`LEFT JOIN` to preserve every product, then filter in `WHERE` on the
right-side key being `NULL` — which is safe (unlike Q2) because we're
checking the join key itself, not an unrelated attribute, so an unmatched
product's `oi.order_item_id` is guaranteed `NULL` and nothing else could
produce that NULL by coincidence.

**Alternative approaches:** `WHERE p.product_id NOT IN (SELECT product_id
FROM order_items)` — safe here because `order_items.product_id` is
`NOT NULL`, but structurally identical to the Q3 trap the moment that
column becomes nullable; `NOT EXISTS` is the future-proof choice:
```sql
SELECT p.product_id, p.product_name FROM products p
WHERE NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.product_id = p.product_id);
```

**Performance considerations:** All three forms typically compile to the
same anti-join plan in Postgres when the referenced column is `NOT NULL`.
An index on `order_items(product_id)` (present implicitly via the FK) makes
the anti-join efficient even as `order_items` grows large.

> **Common mistakes**
> - Filtering on a column other than the join key in this exact pattern —
>   e.g., `WHERE oi.quantity IS NULL` would be wrong/meaningless here since
>   `quantity` is `NOT NULL` and never appears in unmatched rows anyway, but
>   picking the *wrong* nullable column to test is a frequent copy-paste bug.
> - Expecting non-zero results without first checking the actual seed data
>   — always verify assumptions about "surely some rows don't match."

---

### Q17. Diagnostic: why does Postgres reject this query outright, while some other engines might silently run it?

```sql
SELECT department_id, first_name, COUNT(*)
FROM employees
GROUP BY department_id;
```

**Answer:** PostgreSQL raises:
```
ERROR:  column "employees.first_name" must appear in the GROUP BY clause
or be used in an aggregate function
```
Standard SQL (and Postgres strictly) requires every selected column to
either be in `GROUP BY` or wrapped in an aggregate — `first_name` is
neither, so which employee's first name would even be returned for a
department with 7 members is genuinely ambiguous.

**Why it works (the rule):** Once you `GROUP BY department_id`, each output
row represents a whole *group* of underlying rows, not a single one — any
non-aggregated, non-grouped column has no well-defined single value to
show.

**Alternative approaches:** Either add `first_name` to `GROUP BY` (now every
distinct `(department_id, first_name)` pair gets its own row — probably not
the intent), or aggregate it explicitly:
```sql
SELECT department_id, COUNT(*), array_agg(first_name) AS names
FROM employees GROUP BY department_id;
```
or use a window function instead of `GROUP BY` if you want per-row detail
*plus* a group-level aggregate side-by-side (Q44+).

**Performance considerations:** N/A — this is a correctness/standards issue,
not a performance one.

> **⚠️ Dialect note:** MySQL, unless `ONLY_FULL_GROUP_BY` mode is enabled
> (it is the default since MySQL 5.7.5), historically allowed this and
> silently picked an **arbitrary** row's `first_name` per group — a
> long-standing source of "works in MySQL, breaks in Postgres" bug reports.
> Always assume strict `GROUP BY` semantics; never rely on permissive
> behavior.

> **Common mistakes**
> - Porting a query from a permissive MySQL setup to Postgres and being
>   surprised it "suddenly" errors — it was always semantically ambiguous.
> - Silencing the error by wrapping the column in `MAX()`/`MIN()` without
>   thinking about whether that's actually the desired value.

---

### Q18. Coding: `FULL OUTER JOIN` — find the "reconciliation" mismatch between `orders` and `payments`: orders with no payment row, and (if any existed) payments with no order.

```sql
-- [PostgreSQL]
SELECT o.order_id, o.status AS order_status,
       p.payment_id, p.status AS payment_status
FROM orders o
FULL OUTER JOIN payments p ON o.order_id = p.order_id
WHERE o.order_id IS NULL OR p.payment_id IS NULL;
```

**Actual output: 0 rows.** Every one of the 10 orders has exactly one
matching payment row (by design of this seed's 1:1 order↔payment
relationship), and there are no orphaned payment rows.

**Why it works:** `FULL OUTER JOIN` preserves unmatched rows from *both*
sides, NULL-padding whichever side didn't match; filtering for either side's
key being `NULL` isolates exactly the reconciliation exceptions — the
standard "find what doesn't line up between two tables" pattern used
constantly in finance/data-quality work.

**Alternative approaches:** Two separate anti-joins unioned together is
equivalent and portable to engines without `FULL OUTER JOIN`:
```sql
SELECT o.order_id, 'missing payment' AS issue FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.order_id)
UNION ALL
SELECT p.order_id, 'orphan payment' AS issue FROM payments p
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = p.order_id);
```

**Performance considerations:** `FULL OUTER JOIN` in Postgres is typically
implemented via a merge or hash-based full-outer algorithm and can be more
expensive than two targeted anti-joins on well-indexed columns, especially
if only one direction of mismatch is actually possible by schema design
(here, `payments.order_id` is `NOT NULL` and FK-constrained, so "orphan
payment" is structurally impossible — the anti-join-union form lets you
skip that half of the check entirely).

> **⚠️ Dialect note:** MySQL does not support `FULL OUTER JOIN` syntax at
> all — use the `UNION` of two anti-joins (or `LEFT JOIN ... UNION RIGHT
> JOIN ...`) shown above.

> **Common mistakes**
> - Reaching for `FULL OUTER JOIN` when the FK constraints already
>   guarantee one direction can never mismatch — wasted generality.
> - Forgetting `WHERE o.order_id IS NULL OR p.payment_id IS NULL` and just
>   eyeballing a full join's output for gaps manually.

---

### Q19. Coding: multi-table join spanning three tables with an aggregate filter — departments where the *average* current base salary exceeds ₹200,000.

```sql
-- [PostgreSQL]
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary
    FROM salaries
    ORDER BY employee_id, effective_date DESC
)
SELECT d.department_name,
       ROUND(AVG(cs.base_salary), 2) AS avg_base_salary
FROM departments d
JOIN employees e       ON e.department_id = d.department_id
JOIN current_salary cs ON cs.employee_id = e.employee_id
GROUP BY d.department_name
HAVING AVG(cs.base_salary) > 200000
ORDER BY avg_base_salary DESC;
```

**Actual output:**

| department_name | avg_base_salary |
|---|---|
| Engineering | 212142.86 |
| Finance | 190000.00 → *(excluded, not shown)* |

Only **Engineering** clears the ₹200,000 bar
(`(520000+320000+210000+140000+120000+80000+95000)/7 = 212142.86`); Sales
averages 168,333.33, HR 170,000.00, Finance 190,000.00, Marketing 167,500.00
— all below the threshold and correctly excluded by `HAVING`.

**Why it works:** `HAVING` filters *after* grouping/aggregation, which is
the only place a condition on an aggregate function (`AVG(...)`) can
legally go — `WHERE` runs before grouping and cannot reference `AVG(...)`.

**Alternative approaches:** A CTE that computes department averages first,
then a plain `WHERE` on the pre-aggregated column, is equivalent and
sometimes more readable in a longer pipeline:
```sql
WITH dept_avg AS (
    SELECT d.department_name, AVG(cs.base_salary) AS avg_sal
    FROM departments d JOIN employees e ON e.department_id = d.department_id
    JOIN current_salary cs ON cs.employee_id = e.employee_id
    GROUP BY d.department_name
)
SELECT * FROM dept_avg WHERE avg_sal > 200000 ORDER BY avg_sal DESC;
```

**Performance considerations:** `HAVING` still requires computing the
aggregate for *every* group before discarding the ones that don't qualify
— for a highly selective `HAVING` predicate over many groups, pushing as
much filtering as possible into `WHERE` (on ungrouped columns) before the
`GROUP BY` reduces the work the aggregation itself has to do.

> **Common mistakes**
> - Writing `WHERE AVG(cs.base_salary) > 200000` — a syntax error in every
>   major SQL engine; aggregates are illegal in `WHERE`.
> - Forgetting `HAVING` operates on the *grouped* result and cannot filter
>   individual rows before grouping — that's still `WHERE`'s job.

---

## 2. Subqueries

A subquery is a query nested inside another. This section covers scalar,
row, and table subqueries in `WHERE`/`SELECT`/`FROM`, correlated vs.
non-correlated evaluation, and the semantic traps interviewers love to
probe (this is where Q3/Q4 above properly belong conceptually too).

### Q20. What's the difference between a correlated and a non-correlated subquery?

**Answer:** A **non-correlated** subquery can run completely on its own —
it doesn't reference anything from the outer query and is (conceptually)
evaluated once. A **correlated** subquery references a column from the
outer query and must, conceptually, be re-evaluated once per outer row.

```sql
-- Non-correlated: computed once, reused for every row
SELECT product_name, price
FROM products
WHERE price > (SELECT AVG(price) FROM products);

-- Correlated: references p (the outer row) inside the subquery
SELECT p.product_name, p.price
FROM products p
WHERE p.price > (
    SELECT AVG(p2.price) FROM products p2 WHERE p2.category_id = p.category_id
);
```

**Why it works:** In the first query the inner `SELECT AVG(price) FROM
products` has no dependency on the outer `products` row, so the planner can
compute it exactly once (a constant) and reuse it. In the second, `p2.category_id
= p.category_id` ties the inner computation to whichever outer row is
currently being evaluated, so conceptually it re-runs per distinct
`category_id`.

**Alternative approaches:** The correlated version above is more clearly
and often more efficiently written with a window function:
`AVG(price) OVER (PARTITION BY category_id)` computed once alongside each
row (see Section 4) — window functions frequently replace what would
otherwise be a correlated subquery.

**Performance considerations:** A truly correlated subquery evaluated
naively is O(outer rows × inner query cost) — expensive without an index
supporting the correlation predicate. Postgres's planner can often
transform simple correlated subqueries into joins/semi-joins internally,
but this isn't guaranteed for arbitrary expressions; prefer explicit joins
or window functions when performance matters and the transformation isn't
obviously happening (check with `EXPLAIN`).

> **Common mistakes**
> - Assuming every correlated subquery is automatically "optimized away" by
>   the planner — verify with `EXPLAIN ANALYZE` rather than assuming.
> - Writing a correlated subquery in `SELECT` (a "lateral" scalar subquery
>   per row) when a window function would compute the same thing in one
>   pass over the data.

---

### Q21. Coding: products priced above the overall average product price.

```sql
-- [PostgreSQL]
SELECT product_name, price
FROM products
WHERE price > (SELECT AVG(price) FROM products)
ORDER BY price DESC;
```

**Actual output:** Overall average price = `252,390.00 / 10 = 25,239.00`.

| product_name | price |
|---|---|
| UltraBook Pro 14 | 89999.00 |
| GameBook 15 | 74999.00 |
| Galaxy Phone X | 45999.00 |
| Pixel Lite | 29999.00 |

**Why it works:** The scalar subquery `SELECT AVG(price) FROM products`
returns a single number (`25239.00`); `WHERE price > 25239.00` then filters
normally. This only works because the subquery is guaranteed to return
exactly one row and one column — a scalar subquery that unexpectedly
returns multiple rows raises a runtime error.

**Alternative approaches:** A window function keeps per-row detail *and*
the average side by side without needing a second query at all:
```sql
SELECT product_name, price, AVG(price) OVER () AS overall_avg
FROM products
WHERE price > (SELECT AVG(price) FROM products); -- still needs one scalar reference for WHERE
```
(Window functions cannot be referenced directly in `WHERE`/`HAVING` — see
Q47 — so the scalar subquery in `WHERE` is still needed even if you also
display the average via a window function in `SELECT`.)

**Performance considerations:** With only 10 rows this is trivial; at scale,
`AVG(price)` requires a full scan of `products` regardless of approach —
if this filter runs frequently, consider caching the aggregate or
maintaining it incrementally rather than recomputing it per query.

> **Common mistakes**
> - Forgetting the subquery must return a scalar — `WHERE price > (SELECT
>   price FROM products)` without a `LIMIT 1`/aggregate raises "more than
>   one row returned by a subquery used as an expression."
> - Confusing this with a correlated "above the average *of its category*"
>   requirement (Q20's second example) — read the requirement carefully.

---

### Q22. Coding: employees earning more than their own department's average current base salary (correlated subquery).

```sql
-- [PostgreSQL]
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary
    FROM salaries ORDER BY employee_id, effective_date DESC
)
SELECT e.employee_id, e.first_name, e.last_name, d.department_name, cs.base_salary
FROM employees e
JOIN departments d ON e.department_id = d.department_id
JOIN current_salary cs ON cs.employee_id = e.employee_id
WHERE cs.base_salary > (
    SELECT AVG(cs2.base_salary)
    FROM employees e2
    JOIN current_salary cs2 ON cs2.employee_id = e2.employee_id
    WHERE e2.department_id = e.department_id
)
ORDER BY d.department_name, cs.base_salary DESC;
```

**Actual output (6 rows):**

| employee_id | name | department_name | base_salary |
|---|---|---|---|
| 1 | Aditi Rao | Engineering | 520000.00 |
| 2 | Rahul Mehta | Engineering | 320000.00 |
| 12 | Nikhil Gupta | Finance | 250000.00 |
| 10 | Rohan Kapoor | HR | 240000.00 |
| 14 | Rajesh Iyer | Marketing | 230000.00 |
| 7 | Priya Nair | Sales | 300000.00 |

(Department averages: Engineering 212,142.86; Sales 168,333.33; HR
170,000.00; Finance 190,000.00; Marketing 167,500.00 — exactly one employee
per department clears the bar except Engineering, which has two.)

**Why it works:** The outer and inner queries both reference
`e.department_id`/`e2.department_id`; the correlation forces the inner
`AVG` to be recomputed per department as the outer row's department
changes, giving each employee the *right* department's average to compare
against.

**Alternative approaches:** A window function avoids the correlated
subquery and the repeated join entirely:
```sql
SELECT * FROM (
    SELECT e.employee_id, e.first_name, e.last_name, d.department_name, cs.base_salary,
           AVG(cs.base_salary) OVER (PARTITION BY d.department_id) AS dept_avg
    FROM employees e
    JOIN departments d ON e.department_id = d.department_id
    JOIN current_salary cs ON cs.employee_id = e.employee_id
) x
WHERE base_salary > dept_avg
ORDER BY department_name, base_salary DESC;
```
This computes each department's average exactly once per partition in a
single pass, rather than once per outer row.

**Performance considerations:** The correlated-subquery form is
O(employees × departments-worth-of-recomputation) unless the planner
recognizes and flattens it; the window-function form is a single sort +
partition pass, generally faster and is the idiomatic modern-SQL choice for
"compare each row to its group's aggregate."

> **Common mistakes**
> - Forgetting to alias the outer and inner instances of `employees`
>   differently, causing incorrect self-correlation or ambiguous-column
>   errors.
> - Reusing `current_salary` without re-deriving it per department context —
>   it's fine to reuse the same CTE twice as long as both usages are
>   correctly joined/aliased, as shown.

---

### Q23. Coding: banking — accounts whose balance is above the average balance for their own `account_type`.

```sql
-- [PostgreSQL]
SELECT a.account_id, c.first_name, c.last_name, a.account_type, a.balance
FROM accounts a
JOIN customers c ON a.customer_id = c.customer_id
WHERE a.balance > (
    SELECT AVG(a2.balance) FROM accounts a2 WHERE a2.account_type = a.account_type
)
ORDER BY a.account_type, a.balance DESC;
```

**Actual output (3 rows):**

| account_id | name | account_type | balance |
|---|---|---|---|
| 2 | Ravi Shankar | CURRENT | 50000.00 |
| 4 | Suresh Menon | SAVINGS | 300000.00 |
| 1 | Ravi Shankar | SAVINGS | 150000.00 |

(SAVINGS average = `(150000+80000+300000+20000)/4 = 137,500.00` → accounts 1
& 4 qualify. CURRENT average = `(50000+5000)/2 = 27,500.00` → account 2
qualifies. FIXED_DEPOSIT has only one account, `500,000.00`, which cannot be
*above* its own average — correctly excluded.)

**Why it works:** Same correlated-subquery mechanism as Q22, correlated on
`account_type` instead of `department_id` — demonstrates the pattern
generalizes to any "compare row to its own group's aggregate" requirement.

**Alternative approaches:** `AVG(balance) OVER (PARTITION BY account_type)`
in a derived table, filtered in an outer `WHERE`, exactly mirrors Q22's
window-function alternative.

**Performance considerations:** With only 7 accounts this is free either
way; at scale, an index on `accounts(account_type, balance)` would let a
window-function plan avoid a full extra sort for the partition.

> **Common mistakes**
> - Expecting the single-row `FIXED_DEPOSIT` group to produce a result —
>   a single value can never be strictly greater than its own average
>   (they're equal), which trips up people who don't consider group size 1.
> - Using `>=` instead of `>`, which would incorrectly include that
>   `FIXED_DEPOSIT` account.

---

### Q24. Coding: banking — customers who have never taken a loan (`NOT EXISTS`, safe form of the Q3 pattern).

```sql
-- [PostgreSQL]
SELECT customer_id, first_name, last_name
FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM loans l WHERE l.customer_id = c.customer_id);
```

**Actual output (1 row):** `5, Manoj, Tiwari`.

**Why it works:** `NOT EXISTS` is immune to the NULL trap because it never
constructs an `IN`-style comparison list — it purely asks "is there zero
matching rows," which is well-defined regardless of NULLs anywhere in
`loans`.

**Alternative approaches:** `WHERE customer_id NOT IN (SELECT customer_id
FROM loans)` gives the same single row here because `loans.customer_id` is
`NOT NULL` — but per Q3, this form is one schema change away from silently
returning zero rows. `LEFT JOIN loans l ON l.customer_id = c.customer_id
WHERE l.loan_id IS NULL` is a third, join-based equivalent.

**Performance considerations:** All three forms typically produce the same
anti-join plan here; `NOT EXISTS`/anti-join `LEFT JOIN` remain preferable
defaults because they don't rely on a nullability guarantee holding forever.

> **Common mistakes**
> - Reaching for `NOT IN` by habit — always ask "can this column ever be
>   NULL, now or in the future?" before using it.
> - Forgetting the result is intentionally a **single** row and treating an
>   accidental multi-row result as a sign something else is wrong.

---

### Q25. Coding: scalar subquery in `SELECT` — show each department alongside the name of its single highest-paid employee (a "correlated subquery in the select list").

```sql
-- [PostgreSQL]
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary
    FROM salaries ORDER BY employee_id, effective_date DESC
)
SELECT d.department_name,
       (SELECT e.first_name || ' ' || e.last_name
        FROM employees e
        JOIN current_salary cs ON cs.employee_id = e.employee_id
        WHERE e.department_id = d.department_id
        ORDER BY cs.base_salary DESC
        LIMIT 1) AS top_earner
FROM departments d
ORDER BY d.department_name;
```

**Actual output:**

| department_name | top_earner |
|---|---|
| Engineering | Aditi Rao |
| Finance | Nikhil Gupta |
| HR | Rohan Kapoor |
| Marketing | Rajesh Iyer |
| Sales | Priya Nair |

**Why it works:** `LIMIT 1` after `ORDER BY ... DESC` guarantees the
subquery returns at most one row, satisfying the scalar-subquery
requirement, while the correlation (`e.department_id = d.department_id`)
re-targets it per outer department row.

**Alternative approaches:** A `LATERAL` join expresses the same "top-1 per
outer row" intent more explicitly and lets you pull back *multiple*
columns (not just one scalar) in a single pass:
```sql
SELECT d.department_name, top.first_name, top.last_name, top.base_salary
FROM departments d
CROSS JOIN LATERAL (
    SELECT e.first_name, e.last_name, cs.base_salary
    FROM employees e JOIN current_salary cs ON cs.employee_id = e.employee_id
    WHERE e.department_id = d.department_id
    ORDER BY cs.base_salary DESC LIMIT 1
) top;
```
`LATERAL` is the right tool the moment you need more than one column back
from a per-row "top-N" subquery.

**Performance considerations:** A scalar subquery in `SELECT` is
conceptually re-executed once per outer row (5 departments here — trivial);
at scale this pattern doesn't parallelize as well as a single window-
function pass (`ROW_NUMBER() OVER (PARTITION BY department_id ORDER BY
base_salary DESC)` filtered to rank 1), which is generally the preferred
production approach for "top-N per group" (see Q51).

> **Common mistakes**
> - Forgetting `LIMIT 1`, causing a runtime "more than one row returned by a
>   subquery used as an expression" error whenever a department has a
>   salary tie or multiple employees.
> - Using this pattern for "top 3 per group" instead of top-1 — scalar
>   subqueries in `SELECT` can only return one row; use `LATERAL` or a
>   window function for anything beyond top-1.

---

### Q26. Coding: derived table (subquery in `FROM`) — top 3 products by total revenue, with their category.

```sql
-- [PostgreSQL]
SELECT ranked.product_name, ranked.category_name, ranked.revenue
FROM (
    SELECT p.product_name, c.category_name,
           SUM(oi.quantity * oi.unit_price) AS revenue
    FROM order_items oi
    JOIN products p ON oi.product_id = p.product_id
    JOIN categories c ON p.category_id = c.category_id
    GROUP BY p.product_name, c.category_name
) ranked
ORDER BY ranked.revenue DESC
LIMIT 3;
```

**Actual output:**

| product_name | category_name | revenue |
|---|---|---|
| UltraBook Pro 14 | Laptops | 179998.00 |
| Galaxy Phone X | Mobiles | 91998.00 |
| GameBook 15 | Laptops | 74999.00 |

**Why it works:** The inner query (a *derived table*, an unnamed subquery
in `FROM`) computes per-product revenue first; the outer query then simply
sorts and limits that already-aggregated result — separating "compute the
metric" from "rank/limit the metric" into two clear stages.

**Alternative approaches:** A CTE (`WITH ranked AS (...)`) is functionally
identical and generally more readable for anything beyond a one-off
derived table — see Section 3. A window function (`RANK() OVER (ORDER BY
revenue DESC)`) inside the same derived table would let you keep *all* rows
with their rank visible, rather than physically discarding rows 4+ via
`LIMIT`.

**Performance considerations:** Postgres can often "flatten" simple derived
tables into the outer query plan (predicate/limit pushdown), but an
aggregate derived table like this one must fully compute the `GROUP BY`
before the outer `ORDER BY ... LIMIT` can act on it — there's no way to
avoid scanning all of `order_items` at least once for a global top-N.

> **Common mistakes**
> - Applying `LIMIT 3` *inside* the derived table instead of outside —
>   would arbitrarily limit to 3 unaggregated line items before the
>   `GROUP BY` even ran, producing a nonsensical result.
> - Forgetting a derived table (unlike a CTE) **must** have an alias in
>   Postgres (`) ranked` here) — omitting it is a syntax error.

---

### Q27. Coding: subquery with `ALL` / `ANY` — find the department with the single largest project budget using `= ALL`/`>= ALL` instead of `MAX()` + join-back.

```sql
-- [PostgreSQL]
SELECT department_id, project_name, budget
FROM projects p1
WHERE budget >= ALL (SELECT budget FROM projects p2 WHERE p2.budget IS NOT NULL);
```

**Actual output:** `1, Platform Migration, 5000000.00` (Engineering).

**Why it works:** `budget >= ALL (subquery)` is true only for a row whose
value is greater than or equal to *every* value the subquery returns —
equivalent to `budget = (SELECT MAX(budget) FROM projects)` here, but
demonstrating the `ALL`/`ANY` quantifier form directly instead of via an
aggregate function.

**Alternative approaches:** The idiomatic, far more common way to write
this is simply:
```sql
SELECT department_id, project_name, budget FROM projects
ORDER BY budget DESC LIMIT 1;
```
or `WHERE budget = (SELECT MAX(budget) FROM projects)`. `>= ALL` /
`> ANY` are worth knowing for reading legacy code and for cases with no
single clean aggregate equivalent (e.g., `WHERE budget > ANY (SELECT
budget FROM projects WHERE department_id = 3)` — "beats at least one HR
project" has no single-aggregate one-liner as clean as `MAX`).

**Performance considerations:** `= ALL`/`>= ALL` over a subquery generally
performs worse than an equivalent `MAX()` comparison because many engines
can't optimize the quantified comparison as well as a pre-aggregated
scalar; prefer `MAX()`/`ORDER BY ... LIMIT` when a direct aggregate
equivalent exists.

> **Common mistakes**
> - Confusing `= ALL` with `= ANY` — `= ANY (subquery)` is exactly
>   equivalent to `IN (subquery)`, while `= ALL` almost never means what
>   people expect (it's true only if the subquery returns a single value
>   or is empty, or every row is identical) and is rarely the right
>   quantifier for equality checks — `>=`/`>`/`<=`/`<` with `ALL`/`ANY`
>   are the genuinely useful combinations.
> - Forgetting `NULL` handling inside the subquery — a `NULL` in the
>   `ALL`-compared set can make the whole predicate `UNKNOWN` for borderline
>   rows, similar in spirit to the `NOT IN` trap.

---

### Q28. Diagnostic: what's wrong with this attempt to find "employees who earn more than every Sales employee"?

```sql
SELECT employee_id, first_name
FROM employees e
JOIN (SELECT DISTINCT ON (employee_id) employee_id, base_salary FROM salaries ORDER BY employee_id, effective_date DESC) cs
  ON cs.employee_id = e.employee_id
WHERE cs.base_salary > (
    SELECT base_salary FROM (SELECT DISTINCT ON (employee_id) employee_id, base_salary
                              FROM salaries ORDER BY employee_id, effective_date DESC) cs2
    JOIN employees e2 ON e2.employee_id = cs2.employee_id
    WHERE e2.department_id = 2
);
```

**Answer:** This raises a runtime error: **"more than one row returned by a
subquery used as an expression."** Sales (`department_id = 2`) has 3
employees, so the inner scalar subquery tries to return 3 rows
(`300000.00, 110000.00, 95000.00`) where exactly one value is required.

**Why it works (the bug):** A bare `(subquery)` used where a single value is
expected must return 0 or 1 rows; the author needed a *quantified*
comparison (`> ALL`) or an aggregate (`> MAX(...)`), not a plain scalar
subquery, because the intent ("more than *every* Sales employee") is
inherently multi-row.

```sql
-- FIXED using MAX (clearest)
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary
    FROM salaries ORDER BY employee_id, effective_date DESC
)
SELECT e.employee_id, e.first_name, cs.base_salary
FROM employees e JOIN current_salary cs ON cs.employee_id = e.employee_id
WHERE cs.base_salary > (
    SELECT MAX(cs2.base_salary) FROM employees e2
    JOIN current_salary cs2 ON cs2.employee_id = e2.employee_id
    WHERE e2.department_id = 2
);
```

**Actual output:** Every employee earning more than Sales's top earner
(₹300,000 — Priya Nair) — that's just **Aditi Rao (₹520,000)**, since the
next-highest company-wide, Rahul Mehta at ₹320,000, also qualifies:
`320000 > 300000` is true. So the correct result is **2 rows**: Aditi Rao
and Rahul Mehta.

**Alternative approaches:** `WHERE cs.base_salary > ALL (SELECT
cs2.base_salary FROM ... WHERE e2.department_id = 2)` is the direct
quantified-comparison fix and avoids the intermediate `MAX()` aggregation
conceptually, though it typically compiles to similar work.

**Performance considerations:** `MAX()` as a pre-aggregated scalar is
usually the cheapest and most portable option; it also reads unambiguously
to future maintainers, unlike a bare subquery that "usually" returns one
row until the data changes.

> **Common mistakes**
> - Using a bare scalar subquery where the underlying relationship is
>   actually one-to-many, and getting away with it in testing purely
>   because the test data happened to have one row.
> - Not immediately recognizing "more than every X" / "less than every Y"
>   language in a requirement as a signal to reach for `MAX`/`MIN`/`ALL`/`ANY`.

---

### Q29. Coding: subquery-based existence check across three tables — find products that have inventory below their `reorder_level` in **every** warehouse they're stocked in.

```sql
-- [PostgreSQL]
SELECT p.product_id, p.product_name
FROM products p
WHERE EXISTS (SELECT 1 FROM inventory i WHERE i.product_id = p.product_id)
  AND NOT EXISTS (
      SELECT 1 FROM inventory i
      WHERE i.product_id = p.product_id AND i.quantity_on_hand >= i.reorder_level
  );
```

**Actual output (2 rows):** `4, GameBook 15` (Pune-WH1: 3 on hand, reorder
level 5 — below), `9, Wireless Earbuds` (Mumbai-WH1: 0 on hand, reorder
level 25 — below). Every other product has at least one warehouse row
meeting or exceeding its reorder level.

**Why it works:** The first `EXISTS` guards against products with zero
inventory rows at all (none in this seed, but good defensive practice); the
`NOT EXISTS` then rules out any product that has *even one* warehouse row
where stock is healthy — leaving only products where **every** stocked
warehouse is below reorder level. This "not exists a counter-example" shape
is the standard SQL idiom for universal ("for all") quantification, since
SQL has no native `FOR ALL` operator.

**Alternative approaches:** An aggregate form works too, and is often more
intuitive to write:
```sql
SELECT product_id, product_name FROM products p
WHERE product_id IN (
    SELECT product_id FROM inventory
    GROUP BY product_id
    HAVING BOOL_AND(quantity_on_hand < reorder_level)
);
```
`BOOL_AND` (Postgres) returns true only if the condition holds for *every*
grouped row — a direct, aggregate-based expression of "for all."

**Performance considerations:** The double-`EXISTS` form can short-circuit
per product without materializing all inventory rows; the `HAVING
BOOL_AND` form must group all inventory rows for a product before deciding
— roughly equivalent cost at this scale, but the `EXISTS` form scales
better when most products have many warehouse rows and fail fast.

> **⚠️ Dialect note:** `BOOL_AND` is PostgreSQL-specific; the equivalent in
> MySQL is `MIN(condition) = 1` (booleans as 0/1) or `SUM(condition) =
> COUNT(*)`, and in SQL Server there's no boolean aggregate at all — use
> `MIN(CASE WHEN ... THEN 1 ELSE 0 END) = 1`.

> **Common mistakes**
> - Only writing the `NOT EXISTS` half and forgetting products with **zero**
>   inventory rows would then incorrectly match ("vacuously true" — there's
>   no counter-example because there's no example at all).
> - Confusing "below reorder level in *every* warehouse" (this question)
>   with "below reorder level in *any* warehouse" (a much simpler single
>   `EXISTS`, no `NOT EXISTS` needed).

---

### Q30. Coding: subquery inside `IN` vs a join — banking customers with a loan whose interest rate is above the average interest rate across all active loans.

```sql
-- [PostgreSQL]
SELECT DISTINCT c.customer_id, c.first_name, c.last_name
FROM customers c
JOIN loans l ON l.customer_id = c.customer_id
WHERE l.status = 'ACTIVE'
  AND l.interest_rate > (
      SELECT AVG(interest_rate) FROM loans WHERE status = 'ACTIVE'
  );
```

**Actual output:** Active loans: loan1 (Ravi, 8.50%), loan2 (Suresh, 7.75%),
loan3 (Kavita, 9.25%) — loan4 (Neha) is `CLOSED` and excluded from both the
average and the result set. Average active rate = `(8.50+7.75+9.25)/3 =
8.5%`. Only **Kavita Desai (9.25%)** is strictly above average.

**Why it works:** The subquery is restricted to `status = 'ACTIVE'` to
match the requirement's scope exactly — a common real-world subtlety: the
filter inside the subquery (defining the average's population) and the
filter in the outer query (defining which rows to return) must agree on
scope, or the comparison is meaningless.

**Alternative approaches:** `WHERE l.loan_id IN (SELECT loan_id FROM loans
WHERE status='ACTIVE' AND interest_rate > (SELECT AVG(...) ...))` restructures
the same logic through `IN`, with identical results — a matter of style
here since there's no correlation to complicate it either way.

**Performance considerations:** Two passes over `loans` are unavoidable
(one to compute the average, one to compare) unless the average is
precomputed/cached; with an index on `loans(status)`, both passes are cheap
range/filter scans.

> **Common mistakes**
> - Computing the average over **all** loans (including the closed one)
>   while filtering the outer query to active-only — a scope mismatch that
>   silently skews the threshold (here, including the closed 8.00% loan
>   would change the average to `(8.5+7.75+9.25+8.0)/4 = 8.375%`, an
>   entirely different, incorrect cutoff).
> - Forgetting `DISTINCT` when a customer could have multiple qualifying
>   loans (not an issue in this seed, but good defensive habit for a
>   `JOIN`-based formulation).

---

### Q31. Coding: `NOT IN` vs `NOT EXISTS` side-by-side on the *same* nullable column, to see the trap and the fix produce different actual outputs.

Suppose we want employees who are **not** currently the `related_account_id`
target of any transaction... that's banking-specific and unrelated to
employees, so instead we reuse the truest nullable FK in `company_db`:
`employees.manager_id`. Find every employee who is *not* the manager of
Vikram Joshi's peers — i.e., not any of Rahul Mehta's (`employee_id = 2`)
direct reports' managers. More directly, let's contrast the two forms on
the exact same nullable-column query from Q3, viewed side by side:

```sql
-- Form A: NOT IN (the trap)
SELECT COUNT(*) FROM employees
WHERE employee_id NOT IN (SELECT manager_id FROM employees);        -- 0

-- Form B: NOT EXISTS (the fix)
SELECT COUNT(*) FROM employees e
WHERE NOT EXISTS (SELECT 1 FROM employees m WHERE m.manager_id = e.employee_id); -- 9
```

**Answer:** Form A returns `0`; Form B returns `9`. Same underlying
question, same table, same column — different answers, because the
subquery in Form A materializes a list containing a `NULL` (Aditi Rao's
missing manager), and `NOT IN` against a list containing `NULL` can never
be `TRUE` for *any* row (Q3). Form B never builds a list at all — it asks a
per-row existence question, which is unaffected by NULLs anywhere else in
the table.

**Why it works:** This is deliberately the same example as Q3, shown as a
minimal side-by-side to make the point unambiguous in an interview setting:
**the presence of a single NULL in the subquery's result column silently
breaks `NOT IN` for the entire outer query, with no error raised.**

**Alternative approaches:** `LEFT JOIN employees m ON m.manager_id =
e.employee_id WHERE m.manager_id IS NULL` (anti-join) is a third form,
equally safe, returning the same 9 rows: `GROUP BY`-free, index-friendly,
and often the fastest of the three in practice.

**Performance considerations:** Because Form A returns a wrong answer
*silently* (no error, no warning), it's more dangerous than a slow query —
always test `NOT IN` subqueries against columns you haven't explicitly
verified are `NOT NULL`, and prefer `NOT EXISTS`/anti-join by default in
code review.

> **⚠️ Warning:** This exact bug class has caused real production incidents
> (reports silently showing zero rows, "all users are compliant" dashboards
> that are actually just broken). Treat any `NOT IN (SELECT nullable_col
> ...)` you encounter in code review as a bug until proven otherwise.

> **Common mistakes**
> - Trusting that because a query "runs without error," its result is
>   correct — this class of bug produces a *plausible-looking* empty or
>   undercounted result, not an error.
> - Fixing it locally with `WHERE manager_id IS NOT NULL` inside one query
>   but not applying the same defensive filter everywhere else the same
>   nullable column is used with `NOT IN` in the codebase.

---

## 3. CTEs & Recursive CTEs

Common Table Expressions (`WITH ... AS (...)`) turn multi-stage logic into
readable, named steps, and recursive CTEs are the standard SQL tool for
hierarchies (org charts, category trees) and gap-filling (date spines).
`company_db.employees` (self-referencing `manager_id`) and
`ecommerce_db.categories` (self-referencing `parent_category_id`) exist in
this course specifically to teach recursion.

### Q32. What is a CTE, and how is it different from a derived (subquery-in-`FROM`) table?

**Answer:** A CTE is a named, `WITH`-prefixed query that can be referenced
later in the same statement, potentially more than once. Functionally, a
non-recursive CTE is equivalent to a derived table — but a CTE reads
top-to-bottom like a sequence of named steps, can be referenced multiple
times without repeating its definition, and (uniquely) can be recursive.

```sql
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary
    FROM salaries ORDER BY employee_id, effective_date DESC
)
SELECT d.department_name, COUNT(*) AS above_avg_count
FROM employees e
JOIN departments d ON e.department_id = d.department_id
JOIN current_salary cs ON cs.employee_id = e.employee_id
WHERE cs.base_salary > (SELECT AVG(base_salary) FROM current_salary)
GROUP BY d.department_name;
```

**Why it works:** `current_salary` is defined once and referenced twice
(the join, and inside the scalar subquery) — without the CTE you'd either
repeat the `DISTINCT ON` logic twice or nest subqueries awkwardly.

**Alternative approaches:** A derived table would require duplicating the
`DISTINCT ON` subquery text everywhere it's needed, or nesting one
subquery inside another — functionally possible but harder to read and
maintain.

**Performance considerations:** In Postgres 12+, a non-recursive CTE that's
referenced exactly once is, by default, **inlined** into the outer query
just like a derived table (the old "CTE is an optimization fence" behavior
from Postgres ≤11 is gone unless you add `MATERIALIZED`). A CTE referenced
**multiple times**, as above, is evaluated once and its result reused —
which is a genuine performance win over a derived table, which would be
recomputed at each point it's textually repeated (or which the optimizer
may or may not deduplicate depending on the engine).

> **⚠️ Dialect note:** MySQL (8.0+) and SQL Server support CTEs similarly.
> Older MySQL (<8.0) has **no CTE support at all** — derived tables are the
> only option pre-8.0.

> **Common mistakes**
> - Assuming a CTE always materializes (true in Postgres ≤11 by default,
>   not true in 12+ unless `MATERIALIZED` is specified).
> - Using a chain of nested derived tables when a sequence of CTEs would
>   be far more readable — a purely stylistic mistake, but one that hurts
>   maintainability significantly at this course's complexity level.

---

### Q33. `WITH ... AS MATERIALIZED` vs the default — when would you force materialization?

**Answer:** `WITH x AS MATERIALIZED (...)` (Postgres 12+) forces the CTE to
be fully computed and spilled to a temporary result **before** the outer
query runs against it, instead of letting the planner potentially inline/
fold its logic into the surrounding query.

```sql
WITH expensive_calc AS MATERIALIZED (
    SELECT employee_id, base_salary, bonus,
           base_salary + bonus AS total_comp
    FROM salaries
)
SELECT * FROM expensive_calc WHERE total_comp > 300000;
```

**Why it works:** Forcing materialization is useful when (a) the CTE is
genuinely expensive and you want to guarantee it runs exactly once even if
referenced multiple times with different filters downstream, or (b) the
CTE contains a **volatile function** (e.g., `random()`, a sequence-consuming
`nextval()`) where you specifically need one consistent computed value
reused everywhere, not re-evaluated per reference.

**Alternative approaches:** A temp table (Chapter 24) achieves a similar
"compute once, reuse" effect but persists for the whole session/transaction
rather than one statement, and requires explicit `CREATE`/`DROP` overhead.

**Performance considerations:** Forcing materialization when it *isn't*
needed can actively hurt performance by preventing the planner from pushing
outer `WHERE` filters down into the CTE (predicate pushdown), which the
default (non-materialized) behavior allows. Default to **not** specifying
`MATERIALIZED` unless you have a concrete reason (volatility, multiple
heavy re-uses, or debugging an unexpected plan).

> **Common mistakes**
> - Adding `MATERIALIZED` everywhere out of Postgres-11-era habit, blocking
>   filter pushdown and making queries slower than the plain default.
> - Not realizing `NOT MATERIALIZED` can also be forced explicitly when you
>   want to guarantee inlining even in cases the planner might otherwise
>   choose to materialize (e.g., a CTE referenced many times).

---

### Q34. Coding: recursive CTE — print the full management chain (org chart) from the CTO down, with a `level` column.

```sql
-- [PostgreSQL]
WITH RECURSIVE org_chart AS (
    -- anchor: the top of the hierarchy (no manager)
    SELECT employee_id, first_name, last_name, manager_id, 0 AS level
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    -- recursive step: join each next level to the previous
    SELECT e.employee_id, e.first_name, e.last_name, e.manager_id, oc.level + 1
    FROM employees e
    JOIN org_chart oc ON e.manager_id = oc.employee_id
)
SELECT level, REPEAT('  ', level) || first_name || ' ' || last_name AS name
FROM org_chart
ORDER BY level, name;
```

**Actual output (16 rows, 4 levels):**

```
0 Aditi Rao
1   Nikhil Gupta
1   Priya Nair
1   Rahul Mehta
1   Rajesh Iyer
1   Rohan Kapoor
2     Aman Chawla
2     Ananya Singh
2     Arjun Das
2     Divya Shah
2     Isha Bhatt
2     Meera Pillai
2     Pooja Reddy
2     Sneha Kulkarni
2     Vikram Joshi
3       Karan Verma
```

(Level counts: 1 CTO + 5 direct reports + 9 second-level reports + 1
third-level report (Karan Verma, under Sneha Kulkarni) = 16, matching the
full employee table.)

**Why it works:** The **anchor** member seeds the recursion with the row(s)
having no manager. The **recursive** member joins `employees` back to the
*previous* iteration's result (`org_chart`, referenced by name inside its
own definition — legal only inside a `RECURSIVE` CTE), each pass finding
the next level down. Postgres repeats the recursive term until it produces
zero new rows, then stops (implicit termination — see Q35 for the explicit
guard).

**Alternative approaches:** Without recursion, you could hand-write one
`LEFT JOIN` per known hierarchy depth (`employees e1 LEFT JOIN employees e2
ON e2.manager_id = e1.employee_id LEFT JOIN employees e3 ON ...`) — this
only works if you know the maximum depth in advance and becomes unreadable
past 2–3 levels; recursive CTEs are the only approach that scales to
arbitrary, data-driven depth.

**Performance considerations:** Recursive CTEs process one level per
iteration; for a hierarchy with `N` levels, expect `N` passes over the
relevant subset of rows. An index on `employees(manager_id)` is essential —
without it, each recursive step is a full table scan. Postgres also
supports `UNION` (not `ALL`) in the recursive definition to auto-deduplicate
cycles, at extra cost; prefer `UNION ALL` with an explicit cycle guard (Q35)
when cycles are a real risk.

> **Common mistakes**
> - Forgetting the `RECURSIVE` keyword — `WITH org_chart AS (...)` without
>   it is a syntax error the moment the recursive term references itself.
> - Swapping the join direction (`oc.manager_id = e.employee_id` instead of
>   `e.manager_id = oc.employee_id`), which walks the hierarchy **upward**
>   (toward the CTO) instead of downward.

---

### Q35. Coding: recursive CTE with an explicit depth guard/cycle-prevention — count total direct + indirect reports for Rahul Mehta (`employee_id = 2`).

```sql
-- [PostgreSQL]
WITH RECURSIVE reports AS (
    SELECT employee_id, manager_id, 1 AS depth
    FROM employees
    WHERE manager_id = 2

    UNION ALL

    SELECT e.employee_id, e.manager_id, r.depth + 1
    FROM employees e
    JOIN reports r ON e.manager_id = r.employee_id
    WHERE r.depth < 20   -- explicit safety guard against runaway recursion
)
SELECT COUNT(*) AS total_reports FROM reports;
```

**Actual output:** `total_reports = 5` — Sneha Kulkarni, Vikram Joshi,
Ananya Singh, Aman Chawla (direct reports) + Karan Verma (Sneha's report,
indirect).

**Why it works:** The `depth < 20` guard in the recursive term's `WHERE`
clause is a defensive cap — even if the underlying `manager_id` data
somehow contained a cycle (A manages B manages A), the recursion would
still terminate after 20 iterations instead of looping forever.

**Alternative approaches:** Postgres also supports `CYCLE` clause syntax
(`WITH RECURSIVE reports(...) AS (...) CYCLE employee_id SET is_cycle USING
path`, PG 14+) for explicit cycle *detection* rather than a depth cap —
more precise, but a depth guard is simpler, portable, and sufficient for a
tree that is guaranteed acyclic by a `FOREIGN KEY` (as this one effectively
is, since `manager_id` can't point to a descendant without a data-integrity
violation elsewhere).

**Performance considerations:** Without a depth cap, a genuinely cyclic
graph would make `UNION ALL` recursion loop indefinitely, consuming memory
and CPU until manually cancelled — always add a guard when the acyclic
property isn't enforced by a constraint you trust completely.

> **Common mistakes**
> - Assuming self-referencing FKs automatically prevent cycles — a plain
>   `REFERENCES employees(employee_id)` FK (as in this schema) does **not**
>   prevent A→B→A; only application logic or a check constraint/trigger
>   would.
> - Using `UNION` instead of `UNION ALL` "just in case," which silently
>   masks the performance cost of a real cycle instead of surfacing it —
>   a depth guard is the more honest safeguard.

---

### Q36. Coding: recursive CTE over `ecommerce_db.categories` — print the full category tree with materialized path.

```sql
-- [PostgreSQL]
WITH RECURSIVE category_tree AS (
    SELECT category_id, category_name, parent_category_id,
           category_name::TEXT AS path, 0 AS depth
    FROM categories
    WHERE parent_category_id IS NULL

    UNION ALL

    SELECT c.category_id, c.category_name, c.parent_category_id,
           ct.path || ' > ' || c.category_name, ct.depth + 1
    FROM categories c
    JOIN category_tree ct ON c.parent_category_id = ct.category_id
)
SELECT depth, path FROM category_tree ORDER BY path;
```

**Actual output (7 rows):**

```
0 Electronics
1 Electronics > Laptops
1 Electronics > Mobiles
0 Fashion
1 Fashion > Men
1 Fashion > Women
0 Home & Kitchen
```

**Why it works:** Same anchor/recursive pattern as Q34, but the recursive
term additionally builds up a human-readable `path` string by concatenating
each level's name onto the parent's accumulated path — a very common
real-world use of recursive CTEs (breadcrumb generation).

**Alternative approaches:** For only 2 levels of depth (as this category
tree happens to have), a simple self-join (`categories c1 LEFT JOIN
categories c2 ON c2.parent_category_id = c1.category_id`) could produce
similar output without recursion — but it doesn't generalize if a third
level of subcategory is added later, whereas the recursive CTE requires no
changes at all.

**Performance considerations:** Path-string concatenation in the recursive
term adds string-building cost per level; for very deep trees, storing an
`INT[]` array of ancestor IDs (`ct.id_path || c.category_id`) is cheaper
and more useful for later filtering (`WHERE 5 = ANY(id_path)`) than a
display string.

> **Common mistakes**
> - Forgetting `::TEXT` (or an equivalent cast) on the anchor term's path
>   column — Postgres requires the anchor and recursive term's column types
>   to match exactly, and `category_name` alone (already `VARCHAR`) vs. the
>   concatenated expression can trip up type-matching in stricter cases.
> - Ordering final output by `depth` alone instead of `path` — siblings at
>   the same depth would then interleave with unrelated branches.

---

### Q37. Coding: recursive CTE as a "date spine" — generate every calendar day in the first 5 days of January 2024, then find which days employee 3 (Sneha) has no attendance record.

```sql
-- [PostgreSQL]
WITH RECURSIVE date_spine AS (
    SELECT DATE '2024-01-01' AS work_date
    UNION ALL
    SELECT work_date + 1 FROM date_spine WHERE work_date < DATE '2024-01-05'
)
SELECT ds.work_date
FROM date_spine ds
LEFT JOIN attendance a ON a.work_date = ds.work_date AND a.employee_id = 3
WHERE a.attendance_id IS NULL
ORDER BY ds.work_date;
```

**Actual output (2 rows):** `2024-01-04`, `2024-01-05` — Sneha has real
attendance rows for Jan 1–3 only (`PRESENT, PRESENT, LATE`); the spine
exposes the two missing days that a simple `SELECT * FROM attendance WHERE
employee_id = 3` would never reveal, because there's simply no row to find.

**Why it works:** The recursive CTE here has nothing to do with hierarchical
data — it generates a synthetic, gapless sequence of dates (the anchor is
day 1, the recursive term adds one day per iteration until the stop
condition), which is then `LEFT JOIN`ed against real data specifically to
find **absences of rows**, the general "gaps and islands" problem
(Chapter 31 goes much deeper on this pattern).

**Alternative approaches:** `generate_series(DATE '2024-01-01', DATE
'2024-01-05', INTERVAL '1 day')` is PostgreSQL's dedicated, more efficient
built-in for exactly this purpose — prefer it over a recursive CTE whenever
available:
```sql
SELECT gs::date FROM generate_series(DATE '2024-01-01', DATE '2024-01-05', INTERVAL '1 day') gs
LEFT JOIN attendance a ON a.work_date = gs::date AND a.employee_id = 3
WHERE a.attendance_id IS NULL;
```

**Performance considerations:** `generate_series` is a set-returning
function purpose-built for this and is both faster and clearer than a
recursive CTE for date/number spines; reserve recursive CTEs for genuinely
hierarchical/graph-shaped data (Q34–Q36) where no built-in generator
exists.

> **⚠️ Dialect note:** MySQL and SQL Server have no `generate_series`
> equivalent built in (SQL Server has no native version either, though
> `GENERATE_SERIES` was added in Azure SQL/Fabric) — a recursive CTE is the
> standard portable way to build a date spine there.

> **Common mistakes**
> - Reaching for a recursive CTE for date spines in Postgres specifically,
>   when `generate_series` is simpler and faster — know your engine's
>   built-ins before recursing manually.
> - Getting the recursion boundary condition wrong (`<=` vs `<`), silently
>   generating one day too few or looping one extra time.

---

### Q38. Coding: multi-step CTE pipeline — rank customers by total active loan amount using a CTE + window function together.

```sql
-- [PostgreSQL]
WITH loan_totals AS (
    SELECT c.customer_id, c.first_name, c.last_name,
           COALESCE(SUM(l.loan_amount) FILTER (WHERE l.status = 'ACTIVE'), 0) AS active_loan_total
    FROM customers c
    LEFT JOIN loans l ON l.customer_id = c.customer_id
    GROUP BY c.customer_id, c.first_name, c.last_name
)
SELECT customer_id, first_name, last_name, active_loan_total,
       RANK() OVER (ORDER BY active_loan_total DESC) AS loan_rank
FROM loan_totals
ORDER BY loan_rank;
```

**Actual output:**

| customer_id | name | active_loan_total | loan_rank |
|---|---|---|---|
| 3 | Suresh Menon | 1200000.00 | 1 |
| 1 | Ravi Shankar | 500000.00 | 2 |
| 4 | Kavita Desai | 300000.00 | 3 |
| 2 | Neha Agarwal | 0.00 | 4 |
| 5 | Manoj Tiwari | 0.00 | 4 |

(Neha's only loan is `CLOSED`, so her `active_loan_total` is `0`, tying her
with Manoj who has no loan at all — both correctly share `RANK` 4, with no
rank 5 assigned, per `RANK()`'s gap behavior.)

**Why it works:** The CTE stage handles the aggregation (with `FILTER` to
restrict the sum to `ACTIVE` loans only, without needing a separate `WHERE`
that would drop customers with zero active loans from the `LEFT JOIN`
entirely); the outer query then applies a window function purely for
ranking, over the already-clean per-customer totals.

**Alternative approaches:** `SUM(CASE WHEN l.status = 'ACTIVE' THEN
l.loan_amount ELSE 0 END)` is the portable equivalent of `FILTER (WHERE
...)` for engines without `FILTER` support.

**Performance considerations:** Splitting aggregation and ranking into two
CTE stages (or a CTE + outer query, as here) keeps each stage simple and
lets the planner optimize them independently; cramming both into one
expression with nested window-function-inside-aggregate syntax is not even
legal SQL (window functions can't be arguments to aggregates in the same
`SELECT` level) — this pipeline shape is the correct one, not just a style
preference.

> **⚠️ Dialect note:** `FILTER (WHERE ...)` on aggregates is standard SQL
> supported by Postgres and SQLite; MySQL and SQL Server require the
> `CASE WHEN` form instead.

> **Common mistakes**
> - Filtering `WHERE l.status = 'ACTIVE'` before the `LEFT JOIN`'s
>   aggregation (i.e., in the join's `ON` is fine, but in an outer `WHERE`
>   after the join, it degrades to an inner join and drops Manoj Tiwari,
>   the same Q1/Q2 bug transplanted into aggregation).
> - Expecting `RANK()` to assign `5` after two rows tie at `4` — that's
>   `DENSE_RANK()`'s behavior, not `RANK()`'s (see Q46).

---

### Q39. Coding: CTE used to pre-filter before an expensive join — active users' average order value, computed cleanly in stages.

```sql
-- [PostgreSQL]
WITH active_users AS (
    SELECT user_id, full_name FROM users WHERE is_active = TRUE
),
order_totals AS (
    SELECT order_id, user_id, SUM(quantity * unit_price) AS order_total
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    GROUP BY order_id, user_id
)
SELECT au.full_name, ROUND(AVG(ot.order_total), 2) AS avg_order_value, COUNT(ot.order_id) AS order_count
FROM active_users au
JOIN order_totals ot ON ot.user_id = au.user_id
GROUP BY au.full_name
ORDER BY avg_order_value DESC;
```

**Actual output (7 rows — Nita Rao, the one inactive user, is correctly
excluded):** Arjun Kumar (user 1) has 3 orders (#1 = 49498.00, #3 = 89999.00,
#8 = 45999.00) → average `(49498+89999+45999)/3 = 61,832.00`; every other
active user has exactly one order.

| full_name | avg_order_value | order_count |
|---|---|---|
| Farhan Ali | 93498.00 | 1 |
| Dev Malhotra | 93498.00 | 1 |
| Imran Sheikh | 75798.00 | 1 |
| Arjun Kumar | 61832.00 | 3 |
| Lakshmi Venkat | 5097.00 | 1 |
| Sara Patel | 5097.00 | 1 |
| Tanya Bose | 3897.00 | 1 |

**Why it works:** `active_users` filters the dimension once; `order_totals`
aggregates `order_items` to one row per order once; the final join and
`GROUP BY` combine two already-clean intermediate results instead of
tangling the `is_active` filter and the line-item aggregation into one
dense query.

**Alternative approaches:** Everything here could be one large query with
nested subqueries — the CTE staging is purely for readability/maintainability,
not a different result.

**Performance considerations:** Computing `order_totals` once as a CTE
(rather than repeating `SUM(quantity*unit_price)` inline per usage) avoids
recomputation if referenced more than once downstream; since it's
referenced only once here, Postgres 12+ will inline it with no separate
materialization cost by default.

> **Common mistakes**
> - Averaging `unit_price` directly instead of `SUM(quantity * unit_price)`
>   per order first — conflates per-line-item price with per-order value.
> - Forgetting to filter `is_active` at all, silently including Nita Rao
>   (whose account is inactive) in an "active users" report.

---

### Q40. Diagnostic: what's wrong with referencing a CTE recursively without the `RECURSIVE` keyword, or referencing it from an *earlier* CTE in the same `WITH` chain?

```sql
-- Attempt 1: recursive reference, missing RECURSIVE keyword
WITH org_chart AS (
    SELECT employee_id, manager_id, 0 AS level FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.employee_id, e.manager_id, oc.level + 1
    FROM employees e JOIN org_chart oc ON e.manager_id = oc.employee_id
)
SELECT * FROM org_chart;
```

**Answer:** Attempt 1 fails with `relation "org_chart" does not exist`
inside its own definition — Postgres only allows a CTE to reference itself
if the statement is introduced with `WITH RECURSIVE`, not plain `WITH`.

```sql
-- Attempt 2: CTE B trying to reference CTE C, defined *after* it
WITH b AS (SELECT * FROM c),      -- ERROR: relation "c" does not exist
     c AS (SELECT 1 AS x)
SELECT * FROM b;
```

**Why it works (the rule):** In standard (non-recursive) `WITH`, each CTE
can only reference CTEs defined **earlier** in the same `WITH` list (or
tables, or itself only under `RECURSIVE`) — the list is strictly
sequential, top to bottom, not resolved as a bag of mutually visible names.

```sql
-- FIXED order
WITH c AS (SELECT 1 AS x),
     b AS (SELECT * FROM c)
SELECT * FROM b;
```

**Alternative approaches:** If two CTEs genuinely need to reference each
other bidirectionally, that's a sign the logic should be restructured
(e.g., combined into one CTE, or one made a subquery inside the other)
rather than fought with ordering tricks.

**Performance considerations:** N/A — purely a syntax/semantics rule, not a
performance concern.

> **Common mistakes**
> - Assuming `WITH` clauses behave like a set of named views all visible to
>   each other regardless of order — they don't; order matters exactly like
>   sequential variable declarations.
> - Adding `RECURSIVE` to fix Attempt 2's ordering problem — `RECURSIVE`
>   only relaxes the self-reference rule for *one* CTE referencing itself
>   (and permits forward-referencing *within that recursive definition's
>   own scope*), it does not make arbitrary out-of-order CTE references legal.

---

### Q41. Coding: CTE-based top-N-per-group without a window function (contrast with Q51) — cheapest product in each category via a correlated-subquery-in-CTE hybrid.

```sql
-- [PostgreSQL]
WITH cheapest_per_category AS (
    SELECT c.category_id, c.category_name,
           (SELECT p.product_name FROM products p
            WHERE p.category_id = c.category_id
            ORDER BY p.price ASC LIMIT 1) AS cheapest_product,
           (SELECT MIN(p.price) FROM products p WHERE p.category_id = c.category_id) AS min_price
    FROM categories c
)
SELECT category_name, cheapest_product, min_price
FROM cheapest_per_category
WHERE cheapest_product IS NOT NULL
ORDER BY category_name;
```

**Actual output:**

| category_name | cheapest_product | min_price |
|---|---|---|
| Home & Kitchen | Electric Kettle | 1499.00 |
| Laptops | Laptop Sleeve 14" | 799.00 |
| Men | Men Cotton Shirt | 1299.00 |
| Mobiles | Pixel Lite | 29999.00 |
| Women | Women Kurta Set | 1799.00 |

(Electronics and Fashion are parent categories with no *directly assigned*
products — they're excluded by the `IS NOT NULL` filter, since no product
row has `category_id` pointing at them directly.)

**Why it works:** The CTE wraps two correlated scalar subqueries per
category — cheapest is safe here because `ORDER BY ... LIMIT 1` guarantees
a single row regardless of ties (an arbitrary but deterministic-per-run
pick if multiple products tie on the minimum price, since no tiebreaker is
specified).

**Alternative approaches:** `RANK()`/`ROW_NUMBER() OVER (PARTITION BY
category_id ORDER BY price ASC)` filtered to rank 1 (Q51's pattern) is the
more standard, single-pass way to solve "top/bottom-1 per group" and
handles ties explicitly if you add a tiebreaker column to `ORDER BY`.

**Performance considerations:** Two correlated subqueries per category row
means the `products` table is scanned (or index-probed) twice per category
here; a single window-function pass over `products` computes the same
thing in one scan regardless of how many categories exist — prefer the
window-function form at any real scale.

> **Common mistakes**
> - Forgetting parent categories with no directly-assigned products will
>   produce `NULL` for both subqueries, and either mishandling that (an
>   `INNER`-style expectation) or forgetting to filter it as shown.
> - Not adding a deterministic tiebreaker to `ORDER BY` when multiple
>   products in a category could share the minimum price.

---

### Q42. Coding: recursive CTE to validate hierarchy integrity — find any employee who is (incorrectly) recorded as their **own** manager, directly or transitively (a cycle check).

```sql
-- [PostgreSQL]
WITH RECURSIVE chain AS (
    SELECT employee_id AS start_id, employee_id, manager_id, 1 AS depth
    FROM employees
    WHERE manager_id IS NOT NULL

    UNION ALL

    SELECT c.start_id, e.employee_id, e.manager_id, c.depth + 1
    FROM employees e
    JOIN chain c ON e.employee_id = c.manager_id
    WHERE c.depth < 20
)
SELECT DISTINCT start_id
FROM chain
WHERE manager_id = start_id;
```

**Actual output: 0 rows.** `company_db`'s seeded management hierarchy is a
clean, acyclic tree (verified by Q34's successful top-down traversal
terminating at exactly 16 rows with no runaway growth) — this query is the
integrity check you'd run *before* trusting that traversal in a real
system, especially after bulk data loads or manual `UPDATE`s to
`manager_id`.

**Why it works:** The recursive term walks *upward* from each employee
through successive `manager_id` links, carrying the original starting
`employee_id` (`start_id`) along for the whole climb. If any employee's
chain of managers eventually loops back to include their own
`employee_id` as someone's `manager_id` in that chain, `manager_id =
start_id` catches it.

**Alternative approaches:** A `CHECK` constraint cannot express "no cycles
transitively" (constraints only see one row at a time); a `BEFORE INSERT/
UPDATE` trigger that walks the chain on every write is the standard
production defense (Chapter 22) — this recursive CTE is the *ad hoc audit*
version you'd run periodically or after suspicious bulk changes.

**Performance considerations:** This is an O(depth × employees) style scan
in the worst case; fine for organizational hierarchies (bounded, shallow
depth) but not a pattern to run per-transaction on a hot path — reserve it
for periodic integrity audits or pre-migration validation.

> **Common mistakes**
> - Only checking `manager_id = employee_id` directly (self-reference) and
>   missing longer cycles (A manages B, B manages A) — the recursive walk
>   is required to catch transitive cycles, not just direct self-reference.
> - Not capping `depth`, which would cause genuinely cyclic data to spin
>   forever instead of surfacing the problem.

---

### Q43. Coding: CTE + `LATERAL` join — for every department, the 2 most recent hires, using a CTE for department listing plus a `LATERAL` subquery per department.

```sql
-- [PostgreSQL]
WITH dept_list AS (SELECT department_id, department_name FROM departments)
SELECT d.department_name, recent.first_name, recent.last_name, recent.hire_date
FROM dept_list d
CROSS JOIN LATERAL (
    SELECT first_name, last_name, hire_date
    FROM employees e
    WHERE e.department_id = d.department_id
    ORDER BY hire_date DESC
    LIMIT 2
) recent
ORDER BY d.department_name, recent.hire_date DESC;
```

**Actual output (10 rows — 2 per department):**

| department_name | first_name last_name | hire_date |
|---|---|---|
| Engineering | Aman Chawla | 2022-01-10 |
| Engineering | Karan Verma | 2020-02-10 |
| Finance | Divya Shah | 2018-06-25 |
| Finance | Nikhil Gupta | 2016-12-01 |
| HR | Isha Bhatt | 2019-01-14 |
| HR | Rohan Kapoor | 2016-08-09 |
| Marketing | Pooja Reddy | 2020-10-05 |
| Marketing | Rajesh Iyer | 2017-09-30 |
| Sales | Meera Pillai | 2021-03-22 |
| Sales | Arjun Das | 2017-04-18 |

**Why it works:** `LATERAL` allows the subquery on the right side of the
join to reference columns from the row currently being processed on the
left (`d.department_id`) — something an ordinary (non-lateral) subquery in
`FROM` cannot do. `CROSS JOIN LATERAL` here effectively runs the "top 2
most recent hires" subquery once per department, exactly like Q25's
scalar-subquery-in-`SELECT` pattern but able to return **multiple rows and
columns** per outer row instead of a single scalar.

**Alternative approaches:** `ROW_NUMBER() OVER (PARTITION BY department_id
ORDER BY hire_date DESC)` filtered to `<= 2` (Q51) solves the same "top-N
per group" problem in a single window-function pass without `LATERAL` —
generally the more idiomatic and often faster approach; `LATERAL` shines
when the per-group logic is more complex than a simple rank filter (e.g.,
needs its own multi-table join or aggregation per group).

**Performance considerations:** `LATERAL` executes its subquery once per
outer row — for 5 departments that's 5 small index-supported scans against
`employees(department_id, hire_date)`; the window-function alternative
does one single sorted pass over the whole table. At small dimension
cardinality (5 departments) the difference is negligible; at high
cardinality (thousands of groups), the window-function form usually wins.

> **Common mistakes**
> - Using a plain (non-`LATERAL`) subquery in `FROM` and expecting it to
>   see `d.department_id` — without `LATERAL`, this is a hard "column does
>   not exist" / correlation error.
> - Forgetting `ORDER BY ... LIMIT 2` inside the lateral subquery, which
>   would return *all* employees per department instead of just the 2 most
>   recent.

---

## 4. Window Functions Basics

Window functions compute a value across a set of related rows **without**
collapsing them into one output row, unlike `GROUP BY`. This section covers
`PARTITION BY`/`ORDER BY`, ranking functions, offset functions (`LAG`/
`LEAD`), running aggregates, and `NTILE` — the essential basics before
Chapter 10's deep dive.

### Q44. What's the fundamental difference between a window function and `GROUP BY`?

**Answer:** `GROUP BY` collapses N rows into 1 row per group — you lose
row-level detail. A window function computes an aggregate/ranking **per
row**, using a "window" (defined by `OVER (...)`) of related rows, while
keeping every original row intact.

```sql
-- GROUP BY: 5 rows out (one per department)
SELECT department_id, AVG(base_salary) FROM employees e
JOIN salaries s ON s.employee_id = e.employee_id GROUP BY department_id;

-- Window function: 16 rows out (one per employee), each annotated with its department's average
SELECT e.employee_id, e.department_id, s.base_salary,
       AVG(s.base_salary) OVER (PARTITION BY e.department_id) AS dept_avg
FROM employees e JOIN salaries s ON s.employee_id = e.employee_id;
```

**Why it works:** `OVER (PARTITION BY department_id)` tells Postgres "compute
this aggregate over all rows sharing this row's `department_id`," but emit
the result **on every one of those rows individually**, rather than folding
them into one.

**Alternative approaches:** You can get the same "row + group aggregate"
shape with `GROUP BY` plus a self-join back to a pre-aggregated subquery —
strictly more verbose and requires an extra join the window function form
doesn't need.

**Performance considerations:** A window function typically requires one
sort/partition pass over the data (often reusable across multiple window
functions with the same `PARTITION BY`/`ORDER BY`); the join-back-to-
aggregate alternative requires a full separate aggregation *plus* a join,
generally more expensive for the same result.

> **Common mistakes**
> - Believing window functions reduce row count — they never do; `LIMIT`
>   or an outer `WHERE`/CTE filter is still needed to trim rows afterward.
> - Forgetting window functions **cannot** appear in a `WHERE` clause
>   directly (see Q47) — a common first-attempt error.

---

### Q45. Coding: rank employees by current base salary within their department (`RANK() OVER (PARTITION BY ... ORDER BY ...)`).

```sql
-- [PostgreSQL]
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary
    FROM salaries ORDER BY employee_id, effective_date DESC
)
SELECT d.department_name, e.first_name, e.last_name, cs.base_salary,
       RANK() OVER (PARTITION BY d.department_id ORDER BY cs.base_salary DESC) AS salary_rank
FROM employees e
JOIN departments d ON e.department_id = d.department_id
JOIN current_salary cs ON cs.employee_id = e.employee_id
ORDER BY d.department_name, salary_rank;
```

**Actual output (Engineering excerpt, 7 rows; full result has all 16):**

| department_name | employee | base_salary | salary_rank |
|---|---|---|---|
| Engineering | Aditi Rao | 520000.00 | 1 |
| Engineering | Rahul Mehta | 320000.00 | 2 |
| Engineering | Sneha Kulkarni | 210000.00 | 3 |
| Engineering | Vikram Joshi | 140000.00 | 4 |
| Engineering | Ananya Singh | 120000.00 | 5 |
| Engineering | Aman Chawla | 95000.00 | 6 |
| Engineering | Karan Verma | 80000.00 | 7 |

(No ties exist within any department's salaries in this seed, so `RANK`,
`DENSE_RANK`, and `ROW_NUMBER` would all currently agree here — see Q46 for
where they diverge.)

**Why it works:** `PARTITION BY d.department_id` resets the ranking
independently for each department; `ORDER BY cs.base_salary DESC` within
that partition determines rank order — rank 1 is the highest earner *in
that department*, not company-wide.

**Alternative approaches:** A correlated subquery counting "how many
employees in this department earn more than me, plus 1" reproduces `RANK`
manually — technically possible, needlessly expensive, and a good
"why window functions exist" talking point in an interview.

**Performance considerations:** One sort per partition key + order key
combination; an index on `(department_id, base_salary)` (were `base_salary`
directly on `employees`, which it isn't in this normalized schema) could
avoid an explicit sort — as designed, this query must materialize
`current_salary` and sort within it regardless.

> **Common mistakes**
> - Omitting `PARTITION BY` and getting a single company-wide rank instead
>   of a per-department one.
> - Forgetting `DESC` and ranking lowest-to-highest when "highest paid"
>   was intended.

---

### Q46. Diagnostic: `RANK()` vs `DENSE_RANK()` vs `ROW_NUMBER()` — construct a real tie in the data and show all three side by side.

**Answer:** Ranking all 16 employees company-wide by current bonus produces
a genuine tie at **₹30,000** between Arjun Das (`employee_id 8`) and Rohan
Kapoor (`employee_id 10`):

```sql
-- [PostgreSQL]
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, bonus
    FROM salaries ORDER BY employee_id, effective_date DESC
)
SELECT e.first_name, e.last_name, cs.bonus,
       RANK()       OVER (ORDER BY cs.bonus DESC) AS rnk,
       DENSE_RANK() OVER (ORDER BY cs.bonus DESC) AS dense_rnk,
       ROW_NUMBER() OVER (ORDER BY cs.bonus DESC, e.employee_id) AS row_num
FROM employees e JOIN current_salary cs ON cs.employee_id = e.employee_id
ORDER BY cs.bonus DESC, e.employee_id
LIMIT 7;
```

**Actual output (top 7 by bonus):**

| first_name last_name | bonus | rnk | dense_rnk | row_num |
|---|---|---|---|---|
| Aditi Rao | 100000.00 | 1 | 1 | 1 |
| Priya Nair | 70000.00 | 2 | 2 | 2 |
| Rahul Mehta | 50000.00 | 3 | 3 | 3 |
| Nikhil Gupta | 35000.00 | 4 | 4 | 4 |
| Arjun Das | 30000.00 | 5 | 5 | 5 |
| Rohan Kapoor | 30000.00 | 5 | 5 | 6 |
| Rajesh Iyer | 28000.00 | 7 | 6 | 7 |

**Why it works:** `RANK()` gives Arjun Das and Rohan Kapoor the **same**
rank (`5`, since both are tied at ₹30,000) and then **skips** rank `6`
entirely for the next distinct value — Rajesh Iyer lands on rank `7`, not
`6`, because two rows already occupied rank `5`. `DENSE_RANK()` also gives
both tied employees rank `5`, but **never skips** — Rajesh Iyer gets
dense rank `6`, the very next integer. `ROW_NUMBER()` never ties at all —
it assigns strictly increasing values (`5, 6`) even to the tied pair, with
the tie-break order between Arjun and Rohan determined only by the
secondary `ORDER BY e.employee_id` in the window's own `ORDER BY`
(otherwise undefined, since employee_id 8 < 10 here happens to put Arjun
first).

**Alternative approaches:** None — these three functions are the standard
set precisely because they answer three genuinely different questions
("rank with gaps," "rank without gaps," "unique sequence").

**Performance considerations:** All three cost the same to compute (one
sort pass) — the choice is purely semantic, not a performance trade-off.

> **Common mistakes**
> - Using `ROW_NUMBER()` for "top N per group" when ties should share a
>   rank (e.g., "top 3 highest-paid" should probably include ties at rank 3,
>   which only `RANK()` naturally supports, not `ROW_NUMBER()`).
> - Assuming `RANK()` and `DENSE_RANK()` are interchangeable — they only
>   agree when there are zero ties.
> - Forgetting `ROW_NUMBER()`'s tie-break order is **undefined** without an
>   explicit secondary `ORDER BY` column — relying on "whatever order it
>   happens to come out in" is a latent bug.

---

### Q47. Diagnostic: why does this query fail, and how do you fix it?

```sql
SELECT employee_id, base_salary,
       RANK() OVER (ORDER BY base_salary DESC) AS salary_rank
FROM salaries
WHERE salary_rank <= 3;
```

**Answer:** Fails with `column "salary_rank" does not exist`. Window
functions are evaluated **after** `WHERE` (and after `GROUP BY`/`HAVING`)
in SQL's logical processing order, but **before** the final `ORDER BY`/
`SELECT`-list aliasing is available to earlier clauses — so a `WHERE`
clause can never reference a window function's output, whether by alias or
by repeating the expression.

```sql
-- FIXED: wrap in a subquery/CTE, then filter the *outer* query
SELECT * FROM (
    SELECT employee_id, base_salary,
           RANK() OVER (ORDER BY base_salary DESC) AS salary_rank
    FROM salaries
) ranked
WHERE salary_rank <= 3;
```

**Why it works:** The window function now executes fully inside the derived
table/CTE; the outer query's `WHERE` operates on its already-materialized
output columns, including `salary_rank`, which is now an ordinary column
like any other.

**Alternative approaches:** Postgres also allows `QUALIFY`-like filtering
in some dialects (Snowflake, BigQuery have a native `QUALIFY` clause for
exactly this) — **standard SQL and PostgreSQL have no `QUALIFY`**; the
wrap-in-a-subquery pattern shown is the portable, universal fix.

**Performance considerations:** No extra cost versus what the query would
have needed anyway — the window function still only computes once; the
outer `WHERE` is just an ordinary post-filter over already-computed rows.

> **⚠️ Dialect note:** Snowflake, BigQuery, and Databricks SQL support
> `QUALIFY salary_rank <= 3` directly, avoiding the subquery wrapper.
> PostgreSQL, MySQL, and SQL Server do **not** support `QUALIFY` — always
> use the subquery/CTE wrapper there.

> **Common mistakes**
> - Trying to filter a window function's result in `HAVING` instead of
>   `WHERE` — same failure, same reason; `HAVING` also runs before window
>   functions in logical order.
> - Not realizing this is a **logical query processing order** issue
>   (`FROM/JOIN → WHERE → GROUP BY → HAVING → window functions → SELECT →
>   DISTINCT → ORDER BY → LIMIT`), which is one of the single most-tested
>   SQL fundamentals at the intermediate/advanced boundary.

---

### Q48. Coding: top 2 highest-paid employees per department using `ROW_NUMBER()` filtered in an outer query.

```sql
-- [PostgreSQL]
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary
    FROM salaries ORDER BY employee_id, effective_date DESC
),
ranked AS (
    SELECT d.department_name, e.first_name, e.last_name, cs.base_salary,
           ROW_NUMBER() OVER (PARTITION BY d.department_id ORDER BY cs.base_salary DESC) AS rn
    FROM employees e
    JOIN departments d ON e.department_id = d.department_id
    JOIN current_salary cs ON cs.employee_id = e.employee_id
)
SELECT department_name, first_name, last_name, base_salary
FROM ranked WHERE rn <= 2
ORDER BY department_name, base_salary DESC;
```

**Actual output (10 rows):**

| department_name | employee | base_salary |
|---|---|---|
| Engineering | Aditi Rao | 520000.00 |
| Engineering | Rahul Mehta | 320000.00 |
| Finance | Nikhil Gupta | 250000.00 |
| Finance | Divya Shah | 130000.00 |
| HR | Rohan Kapoor | 240000.00 |
| HR | Isha Bhatt | 100000.00 |
| Marketing | Rajesh Iyer | 230000.00 |
| Marketing | Pooja Reddy | 105000.00 |
| Sales | Priya Nair | 300000.00 |
| Sales | Arjun Das | 110000.00 |

(HR, Finance, and Marketing each have exactly 2 employees, so "top 2"
trivially includes everyone in those departments — a good reminder to
sanity-check group sizes before assuming a top-N filter is doing
meaningful work.)

**Why it works:** `ROW_NUMBER()` is preferred over `RANK()` for "exactly N
rows per group" requirements because it never returns more than N rows for
a partition even with ties (whereas `RANK()` could return more than 2 rows
if two employees tied for 2nd place) — the choice between them here encodes
a real business decision ("exactly 2, tie-broken somehow" vs. "everyone
tied for a qualifying rank").

**Alternative approaches:** `RANK() <= 2` instead of `ROW_NUMBER() <= 2`
would return **3+** rows for a department with a tie at rank 2 — a
legitimate alternative if "include ties" is the actual business
requirement.

**Performance considerations:** Same single-sort-per-partition cost as
Q45; the choice of ranking function doesn't change performance, only which
rows survive the filter.

> **Common mistakes**
> - Using `LIMIT 2` per department without `PARTITION BY` — `LIMIT` applies
>   to the whole result set, not per group; it would return only the
>   overall top 2 rows across *all* departments combined.
> - Choosing `ROW_NUMBER()` vs `RANK()` without considering whether ties
>   should expand or truncate the result.

---

### Q49. Coding: running total of transactions on account 1, ordered by date (`SUM() OVER` as a cumulative window).

```sql
-- [PostgreSQL]
SELECT transaction_date, transaction_type,
       CASE WHEN transaction_type IN ('DEPOSIT','TRANSFER_IN') THEN amount ELSE -amount END AS signed_amount,
       SUM(CASE WHEN transaction_type IN ('DEPOSIT','TRANSFER_IN') THEN amount ELSE -amount END)
           OVER (ORDER BY transaction_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM transactions
WHERE account_id = 1
ORDER BY transaction_date;
```

**Actual output (3 rows):**

| transaction_date | transaction_type | signed_amount | running_total |
|---|---|---|---|
| 2024-01-02 10:00 | DEPOSIT | 20000.00 | 20000.00 |
| 2024-01-05 12:00 | WITHDRAWAL | -5000.00 | 15000.00 |
| 2024-01-15 15:00 | TRANSFER_OUT | -10000.00 | 5000.00 |

**Why it works:** `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` defines
a **frame** that grows to include every prior row up through the current
one, in `ORDER BY` order — the standard "running total" frame. Note this
running total tracks only the 2024 activity captured in this seed's
`transactions` log; it is **not** meant to reconcile with `accounts.balance`
(150,000.00), which reflects the account's full history back to 2015.

**Alternative approaches:** In Postgres, `SUM(...) OVER (ORDER BY
transaction_date)` **without** an explicit frame clause defaults to `RANGE
BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` when an `ORDER BY` is present
— functionally similar for distinct dates, but `RANGE` (unlike `ROWS`)
treats **peer rows with equal `ORDER BY` values** as a single group, all
receiving the *same* cumulative total (including rows that come "after"
them within the tie) — a subtle difference that matters the moment two
transactions share an identical timestamp.

**Performance considerations:** A single sorted pass computes the running
total for the whole partition; for very large transaction histories,
ensure an index supports the `ORDER BY` column (`transactions(account_id,
transaction_date)`) so the window function's required sort can be avoided
or minimized.

> **Common mistakes**
> - Omitting the explicit frame and assuming `ROWS` semantics when the
>   default is actually `RANGE` — usually harmless with unique ordering
>   values, but a real bug the moment ties exist.
> - Forgetting to sign the amount (`transactions.amount` is always
>   positive per its `CHECK (amount > 0)` constraint) — summing raw
>   `amount` would treat every transaction as inflating the balance,
>   including withdrawals.

---

### Q50. Coding: `LAG()`/`LEAD()` — for each transaction on account 1, show the previous transaction's amount and the number of days since it.

```sql
-- [PostgreSQL]
SELECT transaction_date, transaction_type, amount,
       LAG(amount) OVER (ORDER BY transaction_date) AS prev_amount,
       (transaction_date::date - LAG(transaction_date::date) OVER (ORDER BY transaction_date)) AS days_since_prev
FROM transactions
WHERE account_id = 1
ORDER BY transaction_date;
```

**Actual output (3 rows):**

| transaction_date | transaction_type | amount | prev_amount | days_since_prev |
|---|---|---|---|---|
| 2024-01-02 10:00 | DEPOSIT | 20000.00 | NULL | NULL |
| 2024-01-05 12:00 | WITHDRAWAL | 5000.00 | 20000.00 | 3 |
| 2024-01-15 15:00 | TRANSFER_OUT | 10000.00 | 5000.00 | 10 |

**Why it works:** `LAG(column) OVER (ORDER BY ...)` looks *backward* one row
(by default) within the ordered window, returning `NULL` when there is no
such row (the first transaction has no predecessor). `LEAD()` is the
mirror, looking forward. Subtracting two `date`-cast timestamps in Postgres
yields an integer number of days directly.

**Alternative approaches:** A self-join (`t1 JOIN t2 ON t2.transaction_date
= (SELECT MAX(transaction_date) FROM transactions t3 WHERE t3.account_id =
t1.account_id AND t3.transaction_date < t1.transaction_date)`) computes the
same "previous row" relationship without window functions — dramatically
more verbose and typically slower (a correlated subquery per row vs. one
sorted window pass).

**Performance considerations:** `LAG`/`LEAD` require the same single sort
as any other window function with an `ORDER BY`; they are far cheaper than
the self-join alternative, which effectively re-sorts/re-scans per row.

> **Common mistakes**
> - Forgetting `LAG`/`LEAD` default to an offset of `1` and a `NULL`
>   default value — `LAG(amount, 1, 0)` would return `0` instead of `NULL`
>   for the first row, which is sometimes what you want and sometimes a
>   silent misrepresentation of "no prior data."
> - Not partitioning when multiple accounts are in scope — without
>   `PARTITION BY account_id`, `LAG` would incorrectly pull the previous
>   row from a *different* account when accounts are interleaved by date.

---

### Q51. Coding: divide all 16 employees into salary quartiles company-wide using `NTILE(4)`.

```sql
-- [PostgreSQL]
WITH current_salary AS (
    SELECT DISTINCT ON (employee_id) employee_id, base_salary, bonus
    FROM salaries ORDER BY employee_id, effective_date DESC
)
SELECT e.first_name, e.last_name, (cs.base_salary + cs.bonus) AS total_comp,
       NTILE(4) OVER (ORDER BY (cs.base_salary + cs.bonus) DESC, e.employee_id) AS quartile
FROM employees e JOIN current_salary cs ON cs.employee_id = e.employee_id
ORDER BY quartile, total_comp DESC;
```

**Actual output (16 rows, grouped by quartile):**

| quartile | employees (total_comp) |
|---|---|
| 1 | Aditi Rao (620000), Rahul Mehta (370000), Priya Nair (370000), Nikhil Gupta (285000) |
| 2 | Rohan Kapoor (270000), Rajesh Iyer (258000), Sneha Kulkarni (235000), Vikram Joshi (152000) |
| 3 | Divya Shah (142000), Arjun Das (140000), Ananya Singh (130000), Pooja Reddy (114000) |
| 4 | Isha Bhatt (108000), Meera Pillai (105000), Aman Chawla (101000), Karan Verma (85000) |

**Why it works:** `NTILE(4)` divides the ordered partition into 4
(as-equal-as-possible) buckets — with exactly 16 rows and 4 buckets, each
bucket gets precisely 4 rows. Rahul Mehta and Priya Nair tie at `370000`
total comp; the secondary `ORDER BY e.employee_id` makes their relative
placement (and therefore which bucket boundary they fall on, if any)
deterministic rather than arbitrary.

**Alternative approaches:** `WIDTH_BUCKET()` divides a range into
equal-*width* buckets based on value, as opposed to `NTILE`'s equal-*count*
buckets — a genuinely different statistical grouping, useful when you care
about salary bands of equal dollar width rather than equal headcount per
band.

**Performance considerations:** `NTILE` requires knowing the total row
count of the partition up front to compute bucket boundaries, so (like
other window functions needing `ORDER BY`) it requires a full sort of the
partition before assignment — there's no way to stream this incrementally.

> **Common mistakes**
> - Expecting `NTILE(4)` to give exactly equal-size groups when the row
>   count isn't evenly divisible by 4 — Postgres distributes the remainder
>   to the *earliest* buckets one extra row at a time (e.g., 17 rows into 4
>   buckets → sizes 5,4,4,4, not 5,5,5,2 or an error).
> - Confusing "quartile 1" with "top quartile" vs. "bottom quartile" —
>   entirely dependent on `ASC` vs `DESC` in the `ORDER BY`; always state
>   which direction "quartile 1" represents.

---

### Q52. Coding: rank all 10 products by total revenue company-wide, and show each product's percentage of total revenue using window functions.

```sql
-- [PostgreSQL]
WITH product_revenue AS (
    SELECT p.product_name, SUM(oi.quantity * oi.unit_price) AS revenue
    FROM order_items oi JOIN products p ON p.product_id = oi.product_id
    GROUP BY p.product_name
)
SELECT product_name, revenue,
       RANK() OVER (ORDER BY revenue DESC) AS revenue_rank,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 2) AS pct_of_total
FROM product_revenue
ORDER BY revenue_rank;
```

**Actual output (10 rows):**

| product_name | revenue | revenue_rank | pct_of_total |
|---|---|---|---|
| UltraBook Pro 14 | 179998.00 | 1 | 44.55 |
| Galaxy Phone X | 91998.00 | 2 | 22.77 |
| GameBook 15 | 74999.00 | 3 | 18.56 |
| Pixel Lite | 29999.00 | 4 | 7.43 |
| Wireless Earbuds | 13996.00 | 5 | 3.46 |
| Men Cotton Shirt | 6495.00 | 6 | 1.61 |
| Non-stick Pan Set | 2499.00 | 7 | 0.62 |
| Women Kurta Set | 1799.00 | 8 | 0.45 |
| Electric Kettle | 1499.00 | 9 | 0.37 |
| Laptop Sleeve 14" | 799.00 | 10 | 0.20 |

(Total revenue = 404,081.00 across all products; percentages sum to
`100.00` allowing for rounding.)

**Why it works:** `SUM(revenue) OVER ()` — an **empty** `OVER ()` — computes
the aggregate across the **entire result set** (no partitioning at all),
giving every row access to the grand total alongside its own value, which
is exactly what's needed for a percent-of-total calculation without a
second query or self-join.

**Alternative approaches:** `SUM(revenue) OVER () ` could be replaced with a
`CROSS JOIN (SELECT SUM(revenue) AS total FROM product_revenue) t` and
dividing by `t.total` — equivalent result, one extra join instead of a
zero-argument window function; the window form is simpler and avoids a
second scan.

**Performance considerations:** An empty `OVER ()` still requires
materializing/aggregating the whole partition (here, the whole result) once
before any row's percentage can be computed — unavoidable for any
"percentage of total" calculation regardless of technique.

> **Common mistakes**
> - Writing `SUM(revenue)` (a plain aggregate) in the same `SELECT` as
>   non-aggregated, non-grouped columns without either `GROUP BY` or `OVER
>   ()` — this is exactly the Q17 error resurfacing; `OVER ()` is what
>   makes it legal to mix a full-set aggregate with per-row detail.
> - Forgetting `100.0 *` (or an explicit numeric cast) before dividing,
>   causing integer-style truncation in some type contexts.

---

### Q53. Coding: first and last order per user using `FIRST_VALUE()`/`LAST_VALUE()` with an explicit frame.

```sql
-- [PostgreSQL]
SELECT DISTINCT user_id,
       FIRST_VALUE(order_id) OVER w AS first_order,
       LAST_VALUE(order_id)  OVER w AS last_order
FROM orders
WINDOW w AS (PARTITION BY user_id ORDER BY order_date
             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING);
```

**Actual output (excerpt, user 1 who has 3 orders):** `user_id 1,
first_order 1, last_order 8` (Arjun Kumar's orders in date order are #1
2024-01-05, #3 2024-01-15, #8 2024-02-10 — first is #1, last is #8).

**Why it works:** `FIRST_VALUE`/`LAST_VALUE` need an explicit frame
extending to the **end** of the partition (`UNBOUNDED FOLLOWING`) — the
default frame for an `ORDER BY`'d window is only `UNBOUNDED PRECEDING AND
CURRENT ROW`, which would make `LAST_VALUE` return the *current* row's own
value on every row (a famously confusing default). The named `WINDOW w AS
(...)` clause lets both function calls share one frame definition instead
of repeating it.

**Alternative approaches:** `MIN(order_id) FILTER (...)`-style tricks don't
generalize as cleanly; the more common alternative is
`FIRST_VALUE/LAST_VALUE` alongside `ROW_NUMBER() = 1` and `ROW_NUMBER() =
COUNT(*) OVER (PARTITION BY ...)` filters — more verbose for the same
result.

**Performance considerations:** Sharing one `WINDOW` definition across
multiple function calls (as done here) lets Postgres compute the
underlying sort/partition once and reuse it for both `FIRST_VALUE` and
`LAST_VALUE`, rather than potentially re-deriving the same window twice.

> **Common mistakes**
> - Forgetting the frame extension and getting `LAST_VALUE` == the current
>   row's own value every time — the single most common `LAST_VALUE` bug
>   report in the wild.
> - Not using `DISTINCT` (or an outer `GROUP BY`) when the goal is one row
>   per user — without it, every order row for a user repeats the same
>   `first_order`/`last_order` pair redundantly.

---

### Q54. Coding: `COUNT(*) OVER (PARTITION BY ...)` to annotate each order item with how many total line items its order has — a lightweight way to detect single-item vs. multi-item orders.

```sql
-- [PostgreSQL]
SELECT order_id, product_id, quantity, unit_price,
       COUNT(*) OVER (PARTITION BY order_id) AS items_in_order
FROM order_items
ORDER BY order_id, product_id;
```

**Actual output (excerpt):** Order 1 → 2 rows, both showing `items_in_order
= 2` (products 1 and 9). Order 3 → 1 row, `items_in_order = 1` (product 3
only). Order 9 → 2 rows (products 3, 9), both `items_in_order = 2`.
Full breakdown across all 10 orders: multi-item orders are #1, #2, #4, #6,
#9 (2 items each); single-item orders are #3, #5, #7, #8, #10.

**Why it works:** `COUNT(*) OVER (PARTITION BY order_id)` — with **no**
`ORDER BY` inside `OVER (...)` — defaults to a frame covering the **entire
partition** for every row (there's no ordering to make a running/growing
frame meaningful), so every line item in an order sees the *same* total
count for that order.

**Alternative approaches:** A self-join to a `GROUP BY order_id` derived
table (`order_items oi JOIN (SELECT order_id, COUNT(*) c FROM order_items
GROUP BY order_id) x ON x.order_id = oi.order_id`) achieves the same
annotation with an explicit join instead of a window function — more
verbose, same result.

**Performance considerations:** Because there's no `ORDER BY` inside this
particular `OVER (...)`, Postgres only needs a hash-based partitioning
pass (no sort required) — cheaper than the `ORDER BY`-driven window
functions in Q45–Q53, which do require sorting.

> **Common mistakes**
> - Adding an unnecessary `ORDER BY` inside this `OVER (...)` clause,
>   which would (with the default frame) turn this into a **running**
>   count up to the current row instead of the whole-partition total —
>   a subtle correctness bug caused purely by an extraneous `ORDER BY`.
> - Confusing `COUNT(*) OVER (PARTITION BY order_id)` with `COUNT(*) OVER
>   ()` (no partition) — the latter would report the *grand total* row
>   count across all orders on every row, not each order's own item count.

---

### Q55. Diagnostic: what's wrong with computing a moving average using `AVG() OVER (ORDER BY ...)` **without** specifying a frame, when the intent was "average of this row and the 2 preceding"?

```sql
-- Intent: 3-day moving average of transaction amounts on account 1 (this + 2 prior)
SELECT transaction_date, amount,
       AVG(amount) OVER (ORDER BY transaction_date) AS moving_avg
FROM transactions
WHERE account_id = 1
ORDER BY transaction_date;
```

**Answer:** Without an explicit `ROWS`/`RANGE` frame, an `ORDER BY`'d
window defaults to `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` —
a **cumulative** average from the start of the partition through the
current row, not a fixed 3-row moving window. On account 1's 3 transactions
this produces `20000.00, 12500.00, 11666.67` (cumulative averages of
`20000`; `(20000+5000)/2`; `(20000+5000+10000)/3`) — not a "last 3 rows"
moving average (which, with only 3 rows total, would coincidentally look
similar here, making the bug easy to miss on small data and only surface
once a 4th transaction is added).

```sql
-- FIXED: explicit ROWS frame for a true moving average
SELECT transaction_date, amount,
       AVG(amount) OVER (ORDER BY transaction_date
                          ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg_3
FROM transactions WHERE account_id = 1
ORDER BY transaction_date;
```

**Why it works:** `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` explicitly caps
the frame at exactly 3 physical rows (the current one plus the two
immediately before it in sort order), regardless of how many total rows
exist in the partition — genuinely different from the cumulative default
the moment a 4th+ row is added.

**Alternative approaches:** `RANGE` instead of `ROWS` with a numeric/interval
offset (`RANGE BETWEEN INTERVAL '2 days' PRECEDING AND CURRENT ROW`) defines
a *time-based* moving window instead of a *row-count-based* one — genuinely
useful, and a different answer again (would include a variable number of
rows depending on how many transactions fall within 2 days of the current
one).

**Performance considerations:** Bounded frames (`N PRECEDING`) can, in some
engines/plans, avoid re-scanning the *entire* preceding partition for every
row (unlike `UNBOUNDED PRECEDING`), making them cheaper for very large
partitions — though Postgres's actual implementation still generally
processes rows in order incrementally either way.

> **Common mistakes**
> - Assuming the default frame is "all rows in the partition" (`ROWS
>   BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`) — it is **not**;
>   the default changes specifically based on whether `ORDER BY` is present
>   inside `OVER (...)` (no `ORDER BY` → whole partition; with `ORDER BY` →
>   cumulative through current row).
> - Confusing `ROWS` (physical row count) with `RANGE`/`GROUPS` (logical
>   value-based or peer-group-based) framing — they can produce different
>   results the moment `ORDER BY` values repeat.

---

## 5. Transactions & ACID

A transaction groups statements into one atomic unit of work. This section
uses `banking_db` — the textbook domain for transactions — to make ACID
concrete: money must never be created or destroyed by a partial failure.

### Q56. Explain ACID with a concrete example from `banking_db`.

**Answer:**
- **Atomicity:** A transfer of ₹10,000 from account 1 to account 3 must
  either fully apply both the debit and the credit, or apply neither — never
  just one leg.
- **Consistency:** Before and after the transaction, every constraint must
  still hold — e.g., `accounts.balance CHECK (balance >= 0)` must never be
  violated, even transiently in a way that's externally visible.
- **Isolation:** A concurrent transaction reading account 1's balance mid-
  transfer must not see a "half-applied" state (debited but not yet
  credited) unless the isolation level explicitly permits it.
- **Durability:** Once the transfer's `COMMIT` returns successfully, the new
  balances survive a server crash a millisecond later — guaranteed by
  Postgres's write-ahead log (WAL, Chapter 29).

```sql
-- [PostgreSQL]
BEGIN;
UPDATE accounts SET balance = balance - 10000 WHERE account_id = 1;
UPDATE accounts SET balance = balance + 10000 WHERE account_id = 3;
INSERT INTO transactions (account_id, transaction_type, amount, related_account_id, description)
VALUES (1, 'TRANSFER_OUT', 10000, 3, 'Transfer to Neha'),
       (3, 'TRANSFER_IN', 10000, 1, 'Transfer from Ravi');
COMMIT;
```

**Why it works:** Wrapping all four statements in `BEGIN ... COMMIT` makes
them one atomic unit — if any statement fails (e.g., the debit would push
account 1's balance below `0`, violating the `CHECK` constraint), Postgres
rolls back *everything* in the transaction, leaving both accounts exactly
as they were.

**Alternative approaches:** Without an explicit transaction, Postgres runs
each statement in its **own** implicit auto-commit transaction — the debit
could succeed and commit while the credit fails, leaving money "vanished."
This is precisely why multi-statement money movement must never rely on
autocommit.

**Performance considerations:** Keep transactions **short** — every lock
acquired (Section 6) is held until `COMMIT`/`ROLLBACK`, so a long-running
transaction holding row locks on `accounts` blocks other transfers touching
the same rows.

> **Common mistakes**
> - Running the debit and credit as two separate autocommitted statements
>   "because it's simpler" — the single most classic transactions
>   interview trap.
> - Forgetting Durability is about **committed** data only — an
>   uncommitted transaction's changes are never guaranteed to survive a
>   crash, by design.

---

### Q57. Coding: demonstrate atomicity by intentionally violating a constraint mid-transaction and observing the rollback.

```sql
-- [PostgreSQL] Account 7 (Manoj... actually customer 5, balance 5000.00) attempts an over-withdrawal
BEGIN;
UPDATE accounts SET balance = balance - 5000 WHERE account_id = 6;   -- Kavita, 20000 -> 15000, fine
UPDATE accounts SET balance = balance - 8000 WHERE account_id = 7;   -- 5000 -> -3000, violates CHECK (balance >= 0)
COMMIT;
```

**Answer:** The second `UPDATE` raises
`ERROR: new row for relation "accounts" violates check constraint
"accounts_balance_check"` and the transaction is aborted. Because
`COMMIT` never runs (and even if it were attempted, Postgres would refuse
since the transaction is now in a failed state), **the first `UPDATE` to
account 6 is also rolled back** — its balance remains `20000.00`, unchanged.

**Why it works:** Once any statement inside a transaction errors, Postgres
marks the whole transaction as **aborted** — every subsequent statement
(including `COMMIT`) is rejected with "current transaction is aborted,
commands ignored until end of transaction block" until an explicit
`ROLLBACK` is issued. This guarantees the all-or-nothing property even
though the first statement individually "succeeded."

**Alternative approaches:** A `SAVEPOINT` before the risky statement allows
partial rollback *within* a larger transaction instead of aborting the
whole thing:
```sql
BEGIN;
UPDATE accounts SET balance = balance - 5000 WHERE account_id = 6;
SAVEPOINT before_risky;
UPDATE accounts SET balance = balance - 8000 WHERE account_id = 7; -- fails
ROLLBACK TO SAVEPOINT before_risky;   -- undoes only the failed statement's effects
COMMIT;  -- account 6's debit is preserved
```

**Performance considerations:** `SAVEPOINT`s have a small overhead per
nesting level and should be used sparingly (typically in application code
implementing retry/compensating logic), not as a routine substitute for
correct application logic that avoids the error in the first place.

> **⚠️ Warning:** Application code that ignores a statement-level error and
> "continues anyway" without issuing `ROLLBACK` (or a `SAVEPOINT` recovery)
> will find every subsequent statement in that transaction silently
> rejected — a common source of confusing "why didn't my later `UPDATE`
> apply" bug reports.

> **Common mistakes**
> - Assuming a failed statement only undoes *itself*, not realizing the
>   entire enclosing transaction is now aborted without a `SAVEPOINT`.
> - Not checking for/handling errors in application code between `BEGIN`
>   and `COMMIT`, leading to a hung or misapplied transaction.

---

### Q58. What are the four standard SQL isolation levels, and what does PostgreSQL actually implement for each?

**Answer:**

| Isolation Level | Dirty Read | Non-Repeatable Read | Phantom Read | Postgres implementation |
|---|---|---|---|---|
| Read Uncommitted | Possible (spec) | Possible | Possible | Treated identically to Read Committed — Postgres **never** allows dirty reads at any level |
| Read Committed (Postgres default) | Prevented | Possible | Possible | Each statement sees a fresh snapshot as of its own start |
| Repeatable Read | Prevented | Prevented | Prevented (via snapshot, not lock-based) | One snapshot for the whole transaction; write conflicts detected via serialization checks |
| Serializable | Prevented | Prevented | Prevented | True serializable via Serializable Snapshot Isolation (SSI) |

**Why it works:** PostgreSQL's MVCC architecture (Chapter 29) makes dirty
reads structurally impossible regardless of requested isolation level —
readers never see another transaction's uncommitted rows, so `READ
UNCOMMITTED` is accepted as a syntax but silently behaves like `READ
COMMITTED`. `REPEATABLE READ` in Postgres is stronger than the SQL standard
minimum requires (it also prevents phantom reads via its snapshot model,
whereas the standard only mandates that at `SERIALIZABLE`).

**Alternative approaches:** N/A — this is a definitional/architectural
question about the standard vs. Postgres's specific implementation.

**Performance considerations:** Higher isolation levels trade concurrency
for correctness guarantees: `SERIALIZABLE` can abort transactions with a
serialization failure (`ERROR: could not serialize access due to
concurrent update`) that the application must be prepared to **retry** —
this is a normal, expected part of using `SERIALIZABLE`, not a bug.

> **⚠️ Dialect note:** MySQL/InnoDB's **default** isolation level is
> `REPEATABLE READ` (not `READ COMMITTED`), and unlike Postgres, InnoDB's
> `REPEATABLE READ` uses next-key locking that *does* prevent some phantom
> reads via locking rather than pure snapshot isolation. SQL Server and
> Oracle both default to `READ COMMITTED`. Always verify the default for
> whichever engine a job/interview targets — this specific fact is a
> favorite trick question.

> **Common mistakes**
> - Assuming `READ UNCOMMITTED` causes dirty reads in Postgres — it never
>   does, by architecture.
> - Assuming every engine defaults to the same isolation level as Postgres.
> - Confusing "prevents phantom reads" with "prevents all write skew" —
>   `REPEATABLE READ` in Postgres still permits certain write-skew
>   anomalies that only `SERIALIZABLE` rules out.

---

### Q59. Diagnostic: identify the anomaly — Transaction A reads account 1's balance twice within the same transaction and gets two different values.

```sql
-- Transaction A (isolation: READ COMMITTED, the Postgres default)
BEGIN;
SELECT balance FROM accounts WHERE account_id = 1;  -- returns 150000.00
-- (meanwhile, Transaction B commits: UPDATE accounts SET balance = 140000 WHERE account_id = 1; COMMIT;)
SELECT balance FROM accounts WHERE account_id = 1;  -- returns 140000.00
COMMIT;
```

**Answer:** This is a **non-repeatable read** — the same row, queried twice
in the same transaction, returns different values because another
transaction committed a change to it in between. This is explicitly
**permitted** at `READ COMMITTED` (Postgres's default) because each
individual statement gets its own fresh snapshot as of *that statement's*
start time, not one snapshot for the whole transaction.

**Why it works:** `READ COMMITTED` guarantees you never see *uncommitted*
data (no dirty reads), but makes no promise that re-reading the same row
later in the same transaction reflects the *same* snapshot — only that
whatever you see was, at some point, actually committed.

**Alternative approaches:** Running Transaction A under `REPEATABLE READ`
instead eliminates this anomaly — both `SELECT`s would return `150000.00`,
because the entire transaction operates against one fixed snapshot taken
at `BEGIN`:
```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance FROM accounts WHERE account_id = 1;  -- 150000.00
-- Transaction B commits its update here
SELECT balance FROM accounts WHERE account_id = 1;  -- still 150000.00
COMMIT;
```

**Performance considerations:** `REPEATABLE READ`'s fixed snapshot avoids
non-repeatable reads for free (no extra locking needed, thanks to MVCC),
but any *write* Transaction A attempts against a row that Transaction B
already modified and committed will raise a serialization error requiring
a retry — a real trade-off for read-modify-write workflows.

> **Common mistakes**
> - Assuming `READ COMMITTED` means "you can't see stale data" — it means
>   the opposite in a sense: each statement sees the *latest* committed
>   data, which is exactly why re-reads can differ.
> - Confusing non-repeatable reads (same row, different value) with
>   phantom reads (same *query predicate*, different **set of rows**,
>   typically due to concurrent `INSERT`/`DELETE` rather than `UPDATE`).

---

### Q60. What is a phantom read, and how does it differ from a non-repeatable read? Give a `banking_db` example.

**Answer:** A **phantom read** occurs when a transaction re-runs the same
*range/filter query* twice and gets a **different set of rows** the second
time, because another transaction inserted or deleted rows matching that
filter in between — as opposed to a non-repeatable read, which is about an
*existing* row's value changing.

```sql
-- Transaction A (READ COMMITTED)
BEGIN;
SELECT COUNT(*) FROM loans WHERE status = 'ACTIVE';  -- returns 3
-- (meanwhile, Transaction B commits: INSERT INTO loans (...) VALUES (..., 'ACTIVE'); COMMIT;)
SELECT COUNT(*) FROM loans WHERE status = 'ACTIVE';  -- returns 4
COMMIT;
```

**Why it works:** Under `READ COMMITTED`, each `SELECT` re-evaluates the
`WHERE status = 'ACTIVE'` predicate against the *current* committed state
at that statement's start — a newly committed matching row is a "phantom"
that appears where it wasn't before.

**Alternative approaches:** `REPEATABLE READ` in Postgres (via its
snapshot-based MVCC implementation) also prevents this specific phantom-
read scenario, which is actually **stronger** than the SQL standard
requires at that level (the standard only guarantees phantom-read
prevention at `SERIALIZABLE`) — a genuinely important Postgres-specific
fact worth stating explicitly in an interview.

**Performance considerations:** Preventing phantoms via snapshot isolation
(Postgres's approach) is generally cheaper than preventing them via
predicate/range locking (the traditional locking-based approach some other
engines use), but any transaction relying on Postgres's `REPEATABLE READ`
must still handle serialization failures on conflicting writes.

> **Common mistakes**
> - Conflating "phantom read" with "non-repeatable read" — they're
>   distinguished by *row appearance/disappearance* (phantom) vs. *row
>   value change* (non-repeatable), a distinction interviewers frequently
>   probe directly.
> - Assuming phantom reads require `DELETE`s specifically — `INSERT`s
>   causing new matching rows to "appear" are the more common real-world
>   cause.

---

### Q61. Coding: use `SERIALIZABLE` to prevent a subtle write-skew anomaly — two loan officers each check "is total active lending under ₹2,000,000" before approving a new loan, and both approve simultaneously.

**Answer:** Suppose the bank's policy is "total active loan exposure must
stay under ₹2,000,000." Current active loans: ₹500,000 (Ravi) + ₹1,200,000
(Suresh) + ₹300,000 (Kavita) = ₹2,000,000 already at the cap (no headroom
at all, but assume a hypothetical cap of ₹2,500,000 for this example,
giving ₹500,000 of headroom). Two officers concurrently each try to approve
a new ₹400,000 loan:

```sql
-- Officer 1 and Officer 2, each running this concurrently under SERIALIZABLE:
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT SUM(loan_amount) FROM loans WHERE status = 'ACTIVE';  -- both read 2000000.00
-- both independently conclude: 2000000 + 400000 = 2400000 <= 2500000, OK to proceed
INSERT INTO loans (customer_id, loan_amount, interest_rate, start_date, term_months, status)
VALUES (2, 400000, 8.0, CURRENT_DATE, 36, 'ACTIVE');
COMMIT;
```

If both transactions run concurrently under `READ COMMITTED` or
`REPEATABLE READ`, **both could commit**, pushing total exposure to
₹2,800,000 — over the cap, even though each transaction individually
"checked" the rule (this is **write skew**: each transaction's write
doesn't conflict with the other's write at the row level, since they insert
*different* new loan rows, but their *combined* effect violates an
invariant neither one alone violated).

**Why it works (the fix):** `SERIALIZABLE` in Postgres uses Serializable
Snapshot Isolation (SSI) to detect this exact pattern — dependencies
between the read (checking the sum) and the write (inserting a new loan
that affects that same sum) across the two concurrent transactions — and
will abort **one** of them with `ERROR: could not serialize access due to
read/write dependencies among transactions`, forcing that officer's
application to retry (at which point it will correctly see the updated
total and refuse the second loan).

**Alternative approaches:** An explicit `SELECT ... FOR UPDATE` on some
representative "lock row" (a manual advisory serialization point), or a
`CHECK` constraint/trigger enforcing the aggregate invariant directly, are
more traditional lock-based fixes — `SERIALIZABLE` is the "let the database
detect the anomaly automatically" alternative, at the cost of needing
application-level retry logic.

**Performance considerations:** `SERIALIZABLE` transactions can abort under
contention that `REPEATABLE READ` would have silently allowed to
(incorrectly) succeed — this is a **feature**, not a bug, but it means
`SERIALIZABLE` workloads must always be paired with automatic retry logic
in the application layer, and tend to see more aborts under high
concurrency on hot rows.

> **Common mistakes**
> - Believing row-level locking alone (e.g., `SELECT ... FOR UPDATE` on the
>   `loans` table) automatically prevents write skew — it only helps if
>   every transaction locks the *same* row(s), which an aggregate-based
>   check across a whole table doesn't naturally do.
> - Deploying `SERIALIZABLE` without retry logic, then treating the
>   resulting serialization-failure errors as unexpected bugs rather than
>   expected, handle-and-retry conditions.

---

### Q62. What does `SAVEPOINT` do, and when is it genuinely useful?

**Answer:** `SAVEPOINT name` marks a point within a transaction that you can
later `ROLLBACK TO SAVEPOINT name`, undoing only the effects of statements
issued after that point — without aborting or losing the rest of the
transaction (see Q57 for a worked example).

**Why it works:** Internally, Postgres tracks a nested sub-transaction
boundary at each savepoint; rolling back to it discards the sub-
transaction's changes while preserving the outer transaction's still-valid
state, then allows further statements to continue normally.

**Alternative approaches:** Structuring application logic to validate
*before* attempting a risky statement (rather than attempting it and
recovering via `SAVEPOINT`) avoids the need for savepoints entirely in many
cases — prefer "check first" when the check is cheap and reliable;
reserve `SAVEPOINT` for genuinely exceptional/retry-driven flows (e.g.,
"attempt an `INSERT`, and if it hits a unique-constraint conflict, fall
back to an `UPDATE`" — the classic emulate-upsert-with-savepoint pattern
predating native `MERGE`/`ON CONFLICT`).

**Performance considerations:** Each active savepoint adds bookkeeping
overhead; deeply nested savepoints in a hot loop (e.g., one per row in a
large batch "try each row, skip failures" pattern) can be markedly slower
than a set-based approach (like `INSERT ... ON CONFLICT DO NOTHING`) that
needs no savepoints at all.

> **Common mistakes**
> - Using `SAVEPOINT`-per-row loops for bulk "skip bad rows" imports when a
>   single `ON CONFLICT`/`MERGE` statement would do the same job in one
>   pass, far faster.
> - Forgetting a `SAVEPOINT` is only meaningful **inside** an existing
>   transaction block — issuing it in autocommit mode with no open
>   transaction is a no-op error context.

---

### Q63. Diagnostic: why does this "safe-looking" balance transfer still have a bug, even though it's wrapped in a transaction?

```sql
BEGIN;
SELECT balance FROM accounts WHERE account_id = 1;              -- app reads: 150000.00
-- app-layer logic: 150000 - 10000 = 140000, is >= 0, proceed
UPDATE accounts SET balance = 140000 WHERE account_id = 1;
UPDATE accounts SET balance = balance + 10000 WHERE account_id = 3;
COMMIT;
```

**Answer:** The bug: `UPDATE accounts SET balance = 140000 ...` **hardcodes**
the computed value from the application's earlier `SELECT`, instead of
expressing the update relative to the current row (`balance = balance -
10000`). Between the `SELECT` and the `UPDATE`, another committed
transaction could have already changed account 1's balance (e.g., a
separate withdrawal bringing it to `145000.00`) — the hardcoded `UPDATE`
would silently **overwrite** that other change, setting the balance to
`140000.00` and effectively erasing the concurrent withdrawal, a classic
**lost update** anomaly.

**Why it works (the fix):** Always express updates as a function of the
*current* row's value evaluated atomically by the database, not a value
computed earlier in application code:
```sql
BEGIN;
UPDATE accounts SET balance = balance - 10000 WHERE account_id = 1;
UPDATE accounts SET balance = balance + 10000 WHERE account_id = 3;
COMMIT;
```
This lets Postgres's row-level locking (Section 6) naturally serialize
concurrent updates to the same row — each `UPDATE ... SET x = x - n`
reads-and-writes atomically under the row's current lock, with no
window for a stale read to overwrite a newer value.

**Alternative approaches:** If the application genuinely must read a value
into application code first (e.g., for business-rule validation beyond
what SQL conveniently expresses), use `SELECT ... FOR UPDATE` to lock the
row at read time, preventing any concurrent modification until the
transaction completes — turning the read-then-write into a safe sequence.

**Performance considerations:** Relative updates (`balance = balance - n`)
require no extra locking beyond the `UPDATE`'s own row lock; `SELECT ...
FOR UPDATE` followed by a separate `UPDATE` holds the lock for longer
(from the `SELECT` through the `COMMIT`), reducing concurrency more than
necessary when a simple relative update would suffice.

> **⚠️ Warning:** The lost-update anomaly is possible under `READ
> COMMITTED` specifically because each statement re-reads current data —
> this is not prevented merely by "being inside a transaction"; it's
> prevented by *how the update is expressed* (relative vs. absolute) or by
> explicit locking.

> **Common mistakes**
> - Believing `BEGIN ... COMMIT` alone prevents lost updates — it prevents
>   *partial* application of multiple statements (atomicity), not stale
>   read-then-write races within application logic.
> - Computing a new value in the application tier and writing it back with
>   an absolute `SET` instead of letting the database compute it relatively
>   in one atomic statement.

---

### Q64. What's the difference between `ROLLBACK` and `ROLLBACK TO SAVEPOINT`, and what happens to sequence values (like `SERIAL` columns) on rollback?

**Answer:** `ROLLBACK` (bare) discards the **entire** transaction back to
its `BEGIN`. `ROLLBACK TO SAVEPOINT name` discards only the work done since
that named savepoint, leaving everything before it intact and the
transaction still open for more statements. Separately: any `SERIAL`/
`IDENTITY` sequence values **consumed** by `INSERT`s inside a rolled-back
transaction are **not** returned to the sequence — sequences are
deliberately non-transactional in Postgres (and most engines) specifically
so concurrent transactions never block waiting for each other's sequence
allocations.

```sql
BEGIN;
INSERT INTO customers (first_name, last_name, email, dob)
VALUES ('Test', 'User', 'test.user@mail.com', '2000-01-01');  -- consumes customer_id 6
ROLLBACK;
-- customer_id 6 is now "burned" — the next successful INSERT gets customer_id 7, not 6
```

**Why it works:** Sequences use their own internal, non-transactional
counter specifically to avoid contention — if sequence allocation were
transactional, every concurrent `INSERT` into the same table would have to
wait for earlier transactions to commit or roll back before knowing which
ID to use, destroying concurrency for high-throughput insert workloads.

**Alternative approaches:** If gap-free IDs are a hard business requirement
(rare, but occurs in some invoicing/compliance contexts), sequences are
the wrong tool entirely — a separate, explicitly locked "counter" table
updated inside the same transaction (accepting the serialization cost) is
the standard workaround.

**Performance considerations:** Non-transactional sequences are a
deliberate, important performance design choice — don't "fix" the resulting
gaps by trying to reuse skipped IDs; that reintroduces contention for no
real benefit in the vast majority of applications.

> **Common mistakes**
> - Being surprised by gaps in `SERIAL` id sequences after rollbacks or
>   failed inserts, and treating it as a bug rather than expected behavior.
> - Trying to "reclaim" skipped sequence values manually, which can
>   introduce race conditions and duplicate-key errors under concurrency.

---

## 6. Locks & Concurrency

Transactions get their isolation guarantees partly through locking.
This section covers PostgreSQL's row/table lock modes, `SELECT ... FOR
UPDATE`, deadlocks, and optimistic vs. pessimistic concurrency control,
again grounded in `banking_db`'s transfer scenarios.

### Q65. What is a deadlock? Construct one concretely using `banking_db.accounts`.

**Answer:** A deadlock occurs when two (or more) transactions each hold a
lock the other needs, and each is waiting for the other to release it —
neither can proceed, so the database must forcibly abort one of them.

```sql
-- Transaction A                          -- Transaction B
BEGIN;                                    BEGIN;
UPDATE accounts SET balance = balance - 1000
  WHERE account_id = 1;                   UPDATE accounts SET balance = balance - 1000
                                             WHERE account_id = 3;
-- A now holds a lock on row 1            -- B now holds a lock on row 3
UPDATE accounts SET balance = balance + 1000
  WHERE account_id = 3;   -- A waits for B's lock on row 3
                                           UPDATE accounts SET balance = balance + 1000
                                             WHERE account_id = 1;  -- B waits for A's lock on row 1
-- DEADLOCK: neither can proceed
```

**Why it works:** A locked row 1 (held by A) and row 3 (held by B) form a
**cycle**: A wants row 3, which B holds; B wants row 1, which A holds.
PostgreSQL's deadlock detector periodically (default every 1 second,
`deadlock_timeout`) scans for such wait cycles and, upon finding one,
**aborts one of the transactions** (the "victim," typically whichever is
cheaper to roll back) with `ERROR: deadlock detected`, allowing the other
to proceed.

**Alternative approaches:** The standard prevention technique is
**consistent lock ordering** — always acquire locks on accounts in a fixed
order (e.g., by ascending `account_id`) regardless of which is the "from"
or "to" account:
```sql
-- Both transactions now always touch the lower account_id first
BEGIN;
UPDATE accounts SET balance = balance - 1000 WHERE account_id = LEAST(1,3);  -- account 1 first
UPDATE accounts SET balance = balance + 1000 WHERE account_id = GREATEST(1,3); -- account 3 second
COMMIT;
```
If every transfer transaction acquires locks in ascending `account_id`
order, the cyclic-wait condition above becomes structurally impossible.

**Performance considerations:** Deadlock detection itself has a small
periodic scanning cost; the real performance concern is **application-level
retry logic** — any code issuing multi-row updates across shared resources
must be prepared to catch a deadlock error and retry the whole transaction,
exactly like a `SERIALIZABLE` failure (Q61).

> **Common mistakes**
> - Writing transfer logic where the "from" and "to" account order depends
>   on user input (whoever initiates the transfer determines lock order),
>   which is exactly what creates deadlock potential — always normalize to
>   a fixed order internally.
> - Not implementing retry logic for deadlock errors, causing sporadic,
>   hard-to-reproduce transaction failures in production.

---

### Q66. What's the difference between a row-level lock and a table-level lock? When does Postgres take each automatically?

**Answer:** A **row-level** lock affects only the specific row(s) a
statement touches — e.g., `UPDATE accounts SET balance = ... WHERE
account_id = 1` locks only account 1's row, leaving every other account
fully available to concurrent transactions. A **table-level** lock affects
the entire table, blocking classes of operations against it regardless of
which specific rows they'd touch. Postgres takes row-level locks
automatically for `UPDATE`/`DELETE`/`SELECT ... FOR UPDATE`; it takes
various table-level locks automatically for DDL (`ALTER TABLE`,
`TRUNCATE`, `CREATE INDEX` without `CONCURRENTLY`) and for explicit `LOCK
TABLE` statements.

```sql
-- Row-level: only account 1 is locked
UPDATE accounts SET balance = balance - 100 WHERE account_id = 1;

-- Table-level: the WHOLE accounts table is locked against most other operations
LOCK TABLE accounts IN ACCESS EXCLUSIVE MODE;
```

**Why it works:** Postgres's lock manager tracks locks at whatever
granularity the operation logically requires — row-level locks are
implemented via tuple-level visibility/lock info that only affects readers/
writers of that exact tuple, while table-level locks are tracked against
the relation itself, blocking even operations that would have touched
unrelated rows.

**Alternative approaches:** `ALTER TABLE ... ADD COLUMN ... DEFAULT
<constant>` in modern Postgres (11+) avoids a full table rewrite/long
exclusive lock for simple cases, but many DDL operations still require
`ACCESS EXCLUSIVE` — always check documentation/`EXPLAIN`-adjacent lock
behavior for the specific DDL operation before running it against a live,
high-traffic table.

**Performance considerations:** Table-level locks (especially `ACCESS
EXCLUSIVE`, taken by most schema-changing DDL) block **all** concurrent
reads and writes to that table for the lock's duration — running DDL
against a hot production table during peak traffic is a common cause of
application-wide outages, even for a seemingly "instant" `ALTER TABLE`.

> **Common mistakes**
> - Assuming all locks in Postgres are row-level — schema changes very
>   much are not, and this distinction is frequently tested.
> - Running long-held `LOCK TABLE` statements or long transactions holding
>   implicit table-level locks during business hours without realizing the
>   blast radius.

---

### Q67. What does `SELECT ... FOR UPDATE` do, and why would you use it over a plain `SELECT`?

**Answer:** `SELECT ... FOR UPDATE` reads a row **and** takes a row-level
exclusive lock on it within the current transaction, preventing any other
transaction from modifying (or also `FOR UPDATE`-locking) that row until
the current transaction commits or rolls back — turning a plain read into
a "read with intent to write" that's safe from concurrent interference.

```sql
-- [PostgreSQL] Safely check-then-act on account 7 (FROZEN status) before allowing a withdrawal
BEGIN;
SELECT balance, status FROM accounts WHERE account_id = 7 FOR UPDATE;
-- application checks: status = 'FROZEN' -> reject the withdrawal
ROLLBACK;  -- or COMMIT if proceeding after validation
```

**Why it works:** Without `FOR UPDATE`, a plain `SELECT` takes no lock at
all — a concurrent transaction could freeze the account (or drain its
balance) between this `SELECT` and a later `UPDATE`, reproducing the Q63
lost-update/stale-check class of bug. `FOR UPDATE` closes that window by
holding the row locked from the moment it's read.

**Alternative approaches:** `SELECT ... FOR SHARE` takes a weaker lock that
allows other transactions to also read-lock the same row (for share) but
blocks anyone trying to `FOR UPDATE`-lock or modify it — useful when
multiple readers need to guarantee a row *won't change* without needing
exclusive write intent themselves. `SERIALIZABLE` isolation (Q61) is a
lock-free alternative that detects the same class of anomaly after the
fact rather than preventing it via explicit locking up front.

**Performance considerations:** `FOR UPDATE` locks are held until the
transaction ends — a long-running transaction that `SELECT ... FOR UPDATE`s
a row early and does unrelated slow work afterward needlessly blocks other
transactions from touching that row; keep the window between `FOR UPDATE`
and `COMMIT`/`ROLLBACK` as short as possible.

> **Common mistakes**
> - Using a plain `SELECT` for a check-then-act pattern that's later
>   followed by an `UPDATE`, leaving a race-condition window open.
> - Holding a `FOR UPDATE` lock across a slow external call (e.g., an
>   HTTP request to a payment gateway) inside the same transaction —
>   a major source of production lock contention and timeouts.

---

### Q68. What is the difference between optimistic and pessimistic concurrency control?

**Answer:** **Pessimistic** concurrency control assumes conflicts are
likely and prevents them up front by acquiring locks before doing any work
(`SELECT ... FOR UPDATE`, Q67). **Optimistic** concurrency control assumes
conflicts are rare, does the work without locking, and only checks for a
conflict at write time — typically via a version number or timestamp
column that must match what was originally read, aborting/retrying if it
doesn't.

```sql
-- Optimistic: version column approach
-- Step 1: read
SELECT balance, version FROM accounts WHERE account_id = 1;  -- e.g., balance=150000, version=4
-- Step 2 (application computes new balance), then write conditionally:
UPDATE accounts
SET balance = 140000, version = version + 1
WHERE account_id = 1 AND version = 4;
-- if 0 rows affected, someone else updated it first -> re-read and retry
```

**Why it works:** The `WHERE ... AND version = 4` clause ensures the update
only applies if no one else has modified the row (and bumped its version)
since it was read — if another transaction already updated it (version is
now 5), this `UPDATE` matches zero rows, signaling a conflict the
application must detect (`rowcount == 0`) and handle by retrying.

**Alternative approaches:** Postgres has no built-in `version` column —
this pattern requires adding one explicitly (`banking_db.accounts` has no
such column today; adding it would be a schema change, Chapter 13/14).
`FOR UPDATE` (pessimistic) requires no schema change but holds locks and
reduces concurrency proactively rather than reactively.

**Performance considerations:** Optimistic concurrency scales better under
**low-contention** workloads (most updates succeed on the first try, no
locks held while "thinking") but degrades under **high-contention**
workloads (many wasted retries on the same hot row); pessimistic locking
is more predictable under high contention but serializes access even when
conflicts would have been rare.

> **Common mistakes**
> - Choosing optimistic concurrency for a genuinely hot, highly contended
>   row (e.g., a single global counter) where most attempts will conflict
>   and retry repeatedly — pessimistic locking is usually better there.
> - Forgetting to actually check the affected row count after an optimistic
>   `UPDATE` — silently proceeding as if it succeeded even when it matched
>   zero rows defeats the whole mechanism.

---

### Q69. Coding: demonstrate a "phantom-safe" withdrawal that respects `FROZEN` account status, using explicit locking to avoid a race with a concurrent status change.

```sql
-- [PostgreSQL]
BEGIN;
SELECT account_id, balance, status
FROM accounts
WHERE account_id = 7
FOR UPDATE;
-- returns: account_id=7, balance=5000.00, status='FROZEN'

-- Application logic sees status = 'FROZEN' and aborts the withdrawal:
ROLLBACK;
```

**Answer:** Because account 7 (Manoj Tiwari's `CURRENT` account) is
seeded with `status = 'FROZEN'`, any correctly written withdrawal flow
must reject this transaction — and by locking the row with `FOR UPDATE`
first, no concurrent transaction can un-freeze (or drain) the account
between the check and the decision to abort.

**Why it works:** The lock acquired by `FOR UPDATE` is held for the
duration of the transaction; even though this example ultimately
`ROLLBACK`s (no actual write happens), the *read* itself was safe from
interference for as long as the transaction was open, which is exactly
the guarantee needed for a correct check-then-decide flow, even when the
decision is "do nothing."

**Alternative approaches:** A `CHECK` constraint cannot express "block
withdrawal transactions against frozen accounts" (constraints validate a
single row's shape, not the *type of operation* being attempted) — this
kind of business rule belongs in application logic or a trigger (Chapter
22), with locking ensuring the check isn't racing a concurrent status
change.

**Performance considerations:** Because this transaction only ever reads
(and rolls back), the lock's practical impact is minimal and short-lived —
but the same pattern in a longer-lived transaction that proceeds to
`UPDATE` after the check should still `COMMIT`/`ROLLBACK` promptly to
release the lock.

> **Common mistakes**
> - Checking `status = 'FROZEN'` with a plain `SELECT` (no `FOR UPDATE`),
>   allowing a race where the account is frozen by a fraud-detection
>   process microseconds after the check passes but before the withdrawal
>   commits.
> - Forgetting `ROLLBACK` (or `COMMIT`) after a `FOR UPDATE` read-only
>   check — leaving the transaction open holds the lock indefinitely.

---

### Q70. Diagnostic: two transactions each try to withdraw ₹4,000 from account 7 (balance ₹5,000) at nearly the same time, both checking "balance >= amount" in application code first. What goes wrong without locking, and how does `FOR UPDATE` fix it?

```sql
-- WITHOUT locking — both transactions run this concurrently:
-- Transaction A                              -- Transaction B
BEGIN;                                        BEGIN;
SELECT balance FROM accounts WHERE account_id = 7;   SELECT balance FROM accounts WHERE account_id = 7;
-- both read 5000.00, both see 5000 >= 4000 -> both proceed
UPDATE accounts SET balance = balance - 4000
  WHERE account_id = 7;                       UPDATE accounts SET balance = balance - 4000
                                                 WHERE account_id = 7;
COMMIT;                                       COMMIT;
```

**Answer:** Without locking, **both** transactions can pass the
application-level `balance >= amount` check (each independently sees
`5000.00`), and both `UPDATE`s eventually apply — because `balance =
balance - 4000` is evaluated relative to whatever the row holds at the time
each `UPDATE` actually executes (Postgres will serialize the two `UPDATE`s
against each other at the row-lock level, so they don't corrupt each other
arithmetically), the account ends at `5000 - 4000 - 4000 = -3000.00`,
which is only stopped by the `CHECK (balance >= 0)` constraint — the
**second** `UPDATE` to actually execute fails with a check violation, and
that transaction rolls back. So the constraint saves you from negative
balances here, but the account was still allowed to reach an inconsistent
in-flight state where **both application-level checks passed
incorrectly** — pure luck (the `CHECK` constraint) prevented actual data
corruption, not correct locking.

```sql
-- FIXED: FOR UPDATE serializes the check-then-act
BEGIN;
SELECT balance FROM accounts WHERE account_id = 7 FOR UPDATE;  -- Transaction B blocks here until A commits/rolls back
-- Transaction A: sees 5000, proceeds
UPDATE accounts SET balance = balance - 4000 WHERE account_id = 7;
COMMIT;
-- Transaction B now acquires the lock, re-reads: balance is now 1000.00, 1000 < 4000 -> correctly rejects
```

**Why it works:** `FOR UPDATE` forces Transaction B to **wait** for
Transaction A's lock on account 7's row to release (at `COMMIT`) before
even reading the balance — by the time B's `SELECT ... FOR UPDATE` actually
returns a value, it reflects A's already-applied withdrawal, so B's
application-level check correctly sees `1000.00` and rejects the second
withdrawal *before* attempting any `UPDATE`, rather than relying on a
`CHECK` constraint as an accidental last line of defense.

**Alternative approaches:** A single atomic conditional `UPDATE` avoids the
separate `SELECT` entirely and is often the cleanest fix for exactly this
class of problem:
```sql
UPDATE accounts SET balance = balance - 4000
WHERE account_id = 7 AND balance >= 4000;
-- check the affected row count: 0 rows updated means "insufficient funds," handled without any explicit lock statement
```

**Performance considerations:** The single atomic `UPDATE ... WHERE balance
>= amount` approach avoids holding an explicit lock across a round trip to
application code entirely (the check and the write happen in one
statement), generally the highest-throughput and simplest-to-reason-about
fix for this exact pattern — prefer it over `SELECT ... FOR UPDATE` +
separate `UPDATE` whenever the business logic is expressible as a single
conditional statement.

> **⚠️ Warning:** Relying on a `CHECK` constraint to "catch" a race
> condition after the fact (as in the unfixed example) means the failure
> mode is an ugly, hard-to-explain error for one of the two users, instead
> of a clean, correct "insufficient funds" rejection — never treat a
> constraint violation as your concurrency-control strategy.

> **Common mistakes**
> - Performing balance checks in application code against a value read
>   without any lock, then issuing a separate `UPDATE` — the canonical
>   TOCTOU (time-of-check to time-of-use) bug in financial systems.
> - Not realizing that a `CHECK` constraint happening to catch the
>   resulting invalid state is *not* the same as the concurrency being
>   handled correctly.

---

### Q71. What is `pg_locks`, and how would you use it to diagnose a "query seems to be hanging" report?

**Answer:** `pg_locks` is a system view exposing every lock currently held
or awaited by active sessions, alongside the resource (relation, tuple,
transaction ID) it targets. Combined with `pg_stat_activity`, it lets you
identify **which** session is blocking **which**.

```sql
-- Find blocked sessions and what's blocking them
SELECT blocked.pid AS blocked_pid, blocked.query AS blocked_query,
       blocking.pid AS blocking_pid, blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted
JOIN pg_locks kl ON kl.locktype = bl.locktype
                 AND kl.database IS NOT DISTINCT FROM bl.database
                 AND kl.relation IS NOT DISTINCT FROM bl.relation
                 AND kl.tuple    IS NOT DISTINCT FROM bl.tuple
                 AND kl.granted
JOIN pg_stat_activity blocking ON blocking.pid = kl.pid
WHERE blocked.pid <> blocking.pid;
```

**Why it works:** Every session waiting on a lock has an **ungranted**
entry in `pg_locks`; cross-referencing it against the **granted** lock on
the same resource identifies the exact session holding it — turning "the
app is stuck" into "session 4821, which ran this exact query 40 minutes
ago and never committed, is blocking session 5103."

**Alternative approaches:** `pg_blocking_pids(pid)` (a built-in Postgres
function, 9.6+) does the same lookup far more concisely:
`SELECT pid, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pg_blocking_pids(pid) != '{}';`

**Performance considerations:** Once identified, a genuinely stuck blocking
session can be terminated with `SELECT pg_terminate_backend(pid);` — a
last-resort operational action, not something to script automatically
without understanding why the session was open that long in the first
place (application bug? forgotten interactive transaction? a genuinely
long-running batch job?).

> **Common mistakes**
> - Immediately killing blocking sessions in production without
>   investigating root cause — often the blocking transaction represents
>   real, in-progress work that shouldn't simply be discarded.
> - Not knowing `pg_blocking_pids()` exists and manually joining `pg_locks`
>   every time — fine to know how to do it by hand for the interview, but
>   use the built-in in practice.

---

### Q72. Diagnostic: `SELECT ... FOR UPDATE SKIP LOCKED` — what problem does it solve, and where would `banking_db` benefit from it?

**Answer:** `FOR UPDATE SKIP LOCKED` tells Postgres to lock and return only
the rows that are **not already locked** by another transaction, silently
skipping any that are — instead of the default `FOR UPDATE` behavior of
**waiting** for a lock to become available.

```sql
-- A worker process picking one FROZEN account to review, without blocking on
-- an account another worker is already processing:
SELECT account_id, customer_id, balance
FROM accounts
WHERE status = 'FROZEN'
ORDER BY account_id
FOR UPDATE SKIP LOCKED
LIMIT 1;
```

**Why it works:** Multiple concurrent "review worker" processes running
this exact query will each get a **different** frozen account (or none, if
all are currently claimed), because any account row another worker has
already locked is simply skipped rather than causing this worker to queue
up and wait for it — this is the standard SQL pattern behind job-queue/
work-queue implementations built directly on top of a regular table.

**Alternative approaches:** A dedicated message queue (e.g., a proper task
queue system) is the "right" tool for high-throughput job dispatch at
scale; `FOR UPDATE SKIP LOCKED` is the correct, idiomatic *SQL-native*
answer when you specifically want a lightweight queue without introducing
new infrastructure.

**Performance considerations:** `SKIP LOCKED` avoids the throughput
collapse that would occur if every worker queued up waiting for the same
few contended rows — without it, N workers competing for FOR UPDATE would
mostly just block each other; with it, they fan out across available work
immediately.

> **Common mistakes**
> - Using plain `FOR UPDATE` for a multi-worker job-queue pattern, causing
>   workers to serialize on lock waits instead of processing in parallel.
> - Forgetting `ORDER BY` before `LIMIT 1` — without a deterministic order,
>   "pick one row" has no defined meaning and different workers could
>   behave unpredictably (though `SKIP LOCKED` itself still prevents them
>   from picking the *same* row).

---

### Q73. Conceptual: what is MVCC, and why does it mean `SELECT` never blocks on a concurrent `UPDATE` in PostgreSQL?

**Answer:** MVCC (Multi-Version Concurrency Control) means PostgreSQL never
overwrites a row in place for an `UPDATE` — instead, it writes a **new**
row version and marks the old version as superseded (visible only to
transactions whose snapshot predates the update), later reclaimed by
`VACUUM`. Because a `SELECT` always reads against a consistent snapshot of
*already-committed* row versions, it never needs to wait for a writer to
finish — it simply sees whichever version was valid as of its own
snapshot.

```sql
-- Session A: long-running transaction holding a row lock via UPDATE, not yet committed
BEGIN;
UPDATE accounts SET balance = balance - 1000 WHERE account_id = 1;
-- (not yet committed)

-- Session B, concurrently, with NO lock wait at all:
SELECT balance FROM accounts WHERE account_id = 1;  -- returns the OLD, pre-update value instantly
```

**Why it works:** Session B's plain `SELECT` never blocks because it isn't
requesting a lock at all — it's reading whichever row version is visible
to its own transaction snapshot, and Session A's in-progress (uncommitted)
new version simply isn't part of that snapshot yet. Only writers competing
for the *same row* (another `UPDATE`, or a `SELECT ... FOR UPDATE`) ever
actually block on each other.

**Alternative approaches:** Traditional lock-based concurrency control
(as used by some other database engines historically) makes readers block
behind writers (and vice versa) by default — "readers don't block writers,
writers don't block readers" is specifically an MVCC property, not
universal across all RDBMS architectures.

**Performance considerations:** MVCC's "keep old row versions around"
approach is exactly why long-running transactions are dangerous in
Postgres beyond just holding locks — old row versions can't be vacuumed
away while any transaction's snapshot might still need them, leading to
table/index bloat under sustained long-transaction + high-write-rate
conditions (Chapter 29 covers `VACUUM` and bloat in depth).

> **Common mistakes**
> - Assuming Postgres uses simple lock-based concurrency where readers
>   always block on writer locks — this is one of the most consequential
>   misunderstandings for reasoning correctly about Postgres concurrency.
> - Not connecting "why does a long transaction cause table bloat" back to
>   MVCC's old-version-retention mechanism.

---

## 7. Constraints

Constraints are the database's enforcement mechanism for data integrity —
`NOT NULL`, `UNIQUE`, `CHECK`, `PRIMARY KEY`, `FOREIGN KEY`, and `DEFAULT`.
This section uses the real `ON DELETE`/`ON UPDATE` rules and `CHECK`
clauses already defined across all three schemas.

### Q74. List the constraint types present in `company_db` and what each one enforces.

**Answer:**
- `PRIMARY KEY` — `employees.employee_id`: uniquely identifies a row, implies `NOT NULL` + `UNIQUE`, backed by an automatic index.
- `UNIQUE` — `employees.email`, `departments.department_name`: no two rows may share this value.
- `NOT NULL` — `employees.first_name`, `hire_date`, etc.: the column may never be `NULL`.
- `FOREIGN KEY` — `employees.department_id REFERENCES departments`: every non-NULL value must exist in the referenced table.
- `CHECK` — `employees.status IN ('ACTIVE','ON_LEAVE','TERMINATED')`, `salaries.base_salary > 0`, `projects.CHECK (end_date IS NULL OR end_date >= start_date)`: an arbitrary boolean condition every row must satisfy.
- `DEFAULT` — `employees.status DEFAULT 'ACTIVE'`, `departments.created_at DEFAULT now()`: supplies a value when none is given.

**Why it works:** Each constraint type enforces a different *shape* of
integrity rule — identity (`PRIMARY KEY`), uncontrolled duplication
(`UNIQUE`), presence (`NOT NULL`), cross-table referential validity
(`FOREIGN KEY`), and arbitrary business rules confined to a single row
(`CHECK`) — together they push data-quality enforcement down into the
database itself, rather than relying solely on application code (which can
have bugs, or be bypassed by a different application, script, or manual
fix entirely).

**Alternative approaches:** Enforcing the same rules purely in application
code is possible but fragile — any direct SQL access (migrations, admin
scripts, a second service sharing the database) bypasses application-layer
validation entirely; database constraints are enforced **regardless of
which client** issues the write.

**Performance considerations:** `UNIQUE` and `PRIMARY KEY` constraints
require an index (created automatically) to enforce efficiently — this
speeds up lookups on that column but adds write overhead (the index must
be maintained on every `INSERT`/`UPDATE`). `CHECK` constraints add small
per-row evaluation cost but no index; they're essentially free unless the
expression itself is expensive.

> **Common mistakes**
> - Treating constraints as "just documentation" and relying solely on
>   application-level validation, which real-world direct-database access
>   (migrations, other services, manual fixes) will eventually bypass.
> - Assuming a `CHECK` constraint can reference another table or another
>   row — it cannot; `CHECK` is evaluated against a single row's own
>   column values only (multi-row/cross-table rules need a trigger).

---

### Q75. Diagnostic: attempt to delete Engineering (`department_id = 1`) from `departments`. What happens, and why?

```sql
DELETE FROM departments WHERE department_id = 1;
```

**Answer:** This **fails** with a foreign key violation — specifically
referencing either `managers.department_id` or `projects.department_id`
(whichever the engine reports first), both of which reference
`departments(department_id)` with the **default** `ON DELETE NO ACTION`
(no `ON DELETE` clause was specified for either FK). Even though
`employees.department_id` **does** specify `ON DELETE SET NULL`, that
alone doesn't save the deletion — **every** referencing FK must permit the
delete for it to succeed, and `managers`/`projects` don't.

**Why it works:** Postgres checks all foreign keys referencing a row before
allowing its deletion; with `NO ACTION`/`RESTRICT` (the default when no
`ON DELETE` clause is given), any existing referencing row blocks the
delete outright. Department 1 has a `managers` row (`manager_id = 1`) and
two `projects` rows referencing it — either alone is sufficient to block
the delete.

**Alternative approaches:** To actually remove a department, you'd need to
either (a) reassign or delete the dependent `managers`/`projects` rows
first, in the correct order, or (b) redesign those specific FKs with
`ON DELETE CASCADE`/`SET NULL` if that's genuinely the desired business
behavior — a schema change, not something to do casually given the very
different semantics (`CASCADE` on `projects` would delete real project
records; `SET NULL` would orphan projects from any department).

**Performance considerations:** FK constraint checks on `DELETE` require
Postgres to scan (or, ideally, index-probe) every referencing table for
matching rows — an index on the referencing FK column (auto-created for
declared FKs in modern Postgres is *not* automatic, actually — Postgres
does **not** automatically index FK columns, unlike the referenced PK
side) is essential for this check to be fast; an unindexed FK column can
make deletes on the referenced table's parent unexpectedly slow at scale.

> **Common mistakes**
> - Assuming `employees.department_id ON DELETE SET NULL` means the whole
>   delete will "just work" — one permissive FK doesn't override a
>   restrictive one elsewhere in the schema.
> - Not realizing Postgres does **not** automatically create an index on
>   the referencing (child) side of a foreign key — only explicit indexing
>   (or the automatic PK/UNIQUE index on the *referenced* side) exists
>   unless you add one yourself.

---

### Q76. Coding/diagnostic: delete employee 2 (Rahul Mehta) from `employees`. Trace exactly what happens across every dependent table.

```sql
DELETE FROM employees WHERE employee_id = 2;
```

**Answer:** This **succeeds**, and cascades as follows:
- `salaries` (`ON DELETE CASCADE`): Rahul's 2 salary history rows are deleted.
- `attendance` (`ON DELETE CASCADE`): no rows (Rahul has no attendance records in this seed) — no-op.
- `employee_projects` (`ON DELETE CASCADE`): his 2 rows (Tech Lead on projects 1 and 2) are deleted.
- `employees.manager_id` (declared `ON DELETE SET NULL`): every employee whose `manager_id = 2` (Sneha, Vikram, Ananya, Aman — 4 rows) has `manager_id` set to `NULL`.
- `managers` (`REFERENCES employees(employee_id)`, no `ON DELETE` clause → default `RESTRICT`): Rahul is **not** in the `managers` table (only employees 1, 7, 10, 12, 14 are), so no conflict here.

**Why it works:** Each FK's `ON DELETE` clause independently determines its
own behavior when the referenced row disappears — `CASCADE` propagates the
deletion, `SET NULL` orphans the referencing column, and (had Rahul been in
`managers`) the default `RESTRICT` would have blocked the whole delete, the
same way Q75 was blocked.

**Alternative approaches:** If the business rule is "a manager can never be
deleted while still assigned as a department head," the current schema
already enforces that correctly via `managers`' default `RESTRICT` — no
change needed; this question is really testing whether you can trace
*multiple independent* FK behaviors correctly for one `DELETE`, not
proposing a fix.

**Performance considerations:** A single `DELETE` triggering `CASCADE`
across two tables and a `SET NULL` across a third means Postgres must
scan/index-probe `salaries`, `employee_projects`, and `employees` (for the
`manager_id` self-reference) — again, indexes on the referencing FK
columns (`salaries.employee_id`, `employee_projects.employee_id`,
`employees.manager_id`) make each of these cheap; their absence makes a
single seemingly simple `DELETE` scan multiple full tables.

> **Common mistakes**
> - Assuming `ON DELETE CASCADE` and `ON DELETE SET NULL` are
>   interchangeable — they have very different blast radii (cascade
>   *deletes more data*; set null *orphans data in place*) and picking the
>   wrong one is a common, sometimes catastrophic modeling mistake.
> - Forgetting to check **every** table referencing the row being deleted
>   before assuming the operation is safe — as this question shows, three
>   different tables with three different behaviors are all involved in one
>   `DELETE`.

---

### Q77. Diagnostic: why does this `INSERT` fail, and what's the actual constraint being violated?

```sql
INSERT INTO salaries (employee_id, base_salary, bonus, effective_date)
VALUES (3, -50000, 0, '2024-06-01');
```

**Answer:** Fails with
`ERROR: new row for relation "salaries" violates check constraint
"salaries_base_salary_check"` — the `CHECK (base_salary > 0)` constraint on
`salaries.base_salary` rejects the negative value outright, before the row
is ever written.

**Why it works:** `CHECK` constraints are evaluated on every `INSERT`/
`UPDATE` attempting to write a value into the constrained column(s); a
value failing the boolean expression aborts the statement (and, absent a
`SAVEPOINT`, the enclosing transaction — Q57) immediately, with zero
partial effect.

**Alternative approaches:** If the true intent was "record a salary
*reduction* of ₹50,000" rather than "set the absolute salary to
-₹50,000," the correct row would compute the new absolute value (e.g.,
Sneha's prior base of ₹210,000 minus ₹50,000 = ₹160,000, still positive)
— `salaries` is a history table of absolute snapshot values, not deltas,
so this constraint is correctly catching a probable application-logic bug
(sending a delta where an absolute value was expected), not being overly
strict.

**Performance considerations:** `CHECK` constraint evaluation cost is
negligible (a simple per-row boolean expression) — there's no performance
argument for skipping them; the cost of *not* having this constraint (bad
data reaching downstream reports/payroll systems) vastly exceeds its
near-zero enforcement cost.

> **Common mistakes**
> - Sending a *relative* value into a column that stores an *absolute*
>   snapshot value, especially common when application logic mixes up
>   "adjustment amount" vs. "new total" semantics.
> - Believing constraint violations always indicate malicious/corrupt
>   input — very often, as here, they indicate a legitimate application
>   bug caught early instead of silently corrupting data.

---

### Q78. What's the difference between `UNIQUE` and `PRIMARY KEY`? Why does `banking_db.accounts` not need a separate `UNIQUE` constraint on anything besides its primary key?

**Answer:** Both `UNIQUE` and `PRIMARY KEY` enforce no-duplicate-values and
both are backed by an automatic index — the differences: a table can have
**only one** `PRIMARY KEY` but **multiple** `UNIQUE` constraints; a
`PRIMARY KEY` column is implicitly `NOT NULL`, while a plain `UNIQUE`
column **may** contain `NULL` (and, critically, multiple `NULL`s are
*not* considered duplicates of each other in standard SQL — `NULL <>
NULL` is `UNKNOWN`, not `TRUE`, so `UNIQUE` never rejects multiple `NULL`s).
`banking_db.accounts` has no natural secondary unique attribute (no
account number field distinct from the surrogate `account_id`, no email,
nothing else that must be globally unique) — its business rules
(`account_id` uniqueness, one row per account) are fully satisfied by the
`PRIMARY KEY` alone.

```sql
-- Illustrating the NULL-uniqueness quirk on a hypothetical nullable UNIQUE column
CREATE TABLE demo (id SERIAL PRIMARY KEY, external_ref TEXT UNIQUE);
INSERT INTO demo (external_ref) VALUES (NULL);  -- OK
INSERT INTO demo (external_ref) VALUES (NULL);  -- ALSO OK — two NULLs don't violate UNIQUE
```

**Why it works:** The SQL standard treats `NULL` as "unknown," and a
`UNIQUE` constraint's job is to reject rows that are provably equal to an
existing row — two `NULL`s can never be *proven* equal, so they're allowed
to coexist under `UNIQUE`. `PRIMARY KEY` sidesteps this entirely by
requiring `NOT NULL` in the first place.

**Alternative approaches:** If a nullable column truly needs "at most one
NULL" semantics, a **partial unique index** achieves it explicitly:
`CREATE UNIQUE INDEX ON demo (id) WHERE external_ref IS NULL;` is not quite
right either — the idiomatic Postgres approach is a partial unique index on
an expression that's constant for NULL rows, or simply redesigning to avoid
the need.

**Performance considerations:** Both `UNIQUE` and `PRIMARY KEY` indexes
add the same per-write maintenance overhead; there's no performance
difference between the two for equivalent enforcement — the choice is
purely about NULL-handling and "one PK per table" semantics.

> **Common mistakes**
> - Assuming `UNIQUE` rejects multiple `NULL`s the way it rejects multiple
>   identical non-NULL values — a frequently-tested gotcha.
> - Adding a redundant `UNIQUE` constraint on a column that's already the
>   `PRIMARY KEY` (harmless but pointless — the PK's index already
>   enforces it).

---

### Q79. Coding/diagnostic: what happens when you try to insert an `order_items` row referencing a non-existent `product_id`, and what happens to existing `order_items` rows when a referenced product is deleted?

```sql
-- Attempt 1: non-existent product
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
VALUES (1, 999, 1, 500.00);
-- ERROR: insert or update on table "order_items" violates foreign key
-- constraint — Key (product_id)=(999) is not present in table "products".

-- Attempt 2: delete a referenced product
DELETE FROM products WHERE product_id = 1;  -- Galaxy Phone X
```

**Answer:** Attempt 1 fails immediately — the FK constraint on
`order_items.product_id REFERENCES products(product_id)` requires the
referenced product to exist, with **no** default `ON DELETE` behavior
relevant here (this is an `INSERT`, not affected by `ON DELETE` at all).
Attempt 2 also **fails**: `order_items.product_id REFERENCES
products(product_id)` has no `ON DELETE` clause specified (default
`RESTRICT`), and product 1 has existing `order_items` rows (orders #1 and
#8) — Postgres refuses the delete with a foreign key violation, protecting
historical order data from silently losing its product reference.

**Why it works:** This is a deliberate, important design choice: unlike
`inventory.product_id` (which has `ON DELETE CASCADE`, since inventory
rows are meaningless without their product), `order_items.product_id`
correctly defaults to `RESTRICT` — you should **never** be able to delete
a product that has ever been sold, because that would silently corrupt
historical financial/order records. The right operation for a
discontinued product is `UPDATE products SET is_discontinued = TRUE`, not
`DELETE`.

**Alternative approaches:** If a product truly must be removable from
`products` while preserving historical order data, the standard pattern is
"soft delete" (`is_discontinued`/`deleted_at` flag, already present here as
`is_discontinued`) rather than a hard `DELETE` — this is precisely why
`is_discontinued BOOLEAN` exists on `products` in this schema.

**Performance considerations:** The `RESTRICT` check on `DELETE FROM
products` requires probing `order_items` (and `reviews`, and `inventory`
minus its cascade) for matching rows — an index on `order_items(product_id)`
(present via the FK, though again not automatically created by Postgres —
verify it explicitly) keeps this check fast.

> **Common mistakes**
> - Trying to hard-delete a "discontinued" product instead of using the
>   `is_discontinued` flag that exists exactly for this purpose.
> - Assuming all FKs in a schema share the same `ON DELETE` behavior —
>   this schema deliberately mixes `CASCADE` (`inventory`), default
>   `RESTRICT` (`order_items`), and (elsewhere) `SET NULL`, each chosen
>   for the specific referencing table's semantics.

---

### Q80. What's the difference between a `CHECK` constraint and a `NOT NULL` constraint being enforced via a trigger instead? When would you actually need a trigger?

**Answer:** `NOT NULL` and `CHECK` are **declarative** constraints — the
database engine enforces them natively and efficiently as part of its
constraint-checking machinery, with no procedural code to write or
maintain. A **trigger** is **procedural** — arbitrary code (PL/pgSQL,
Chapter 22) that runs on `INSERT`/`UPDATE`/`DELETE` and can enforce rules
declarative constraints structurally cannot express, most importantly:
rules spanning **multiple rows or multiple tables**.

```sql
-- CHECK cannot express this (needs to see OTHER rows): "an employee's total
-- allocated project hours across employee_projects must not exceed 2000"
-- This requires a trigger:
CREATE OR REPLACE FUNCTION check_total_hours() RETURNS TRIGGER AS $$
BEGIN
    IF (SELECT SUM(hours_allocated) FROM employee_projects WHERE employee_id = NEW.employee_id) > 2000 THEN
        RAISE EXCEPTION 'Employee % would exceed 2000 total allocated hours', NEW.employee_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_total_hours
BEFORE INSERT OR UPDATE ON employee_projects
FOR EACH ROW EXECUTE FUNCTION check_total_hours();
```

**Why it works:** A `CHECK` constraint's expression can only reference
columns of the **row currently being written** — it has no way to query
other rows or other tables. A trigger function, by contrast, can run
arbitrary SQL (including aggregates across the whole table) before
deciding whether to allow the write, at the cost of being slower and more
complex to maintain than a declarative constraint.

**Alternative approaches:** For genuinely cross-row invariants at scale,
some teams prefer enforcing the rule at the application/service layer
(with the trigger as a defense-in-depth backstop) rather than relying
solely on a trigger, specifically because trigger logic executing on every
write can become a hidden performance bottleneck if not carefully written
and indexed.

**Performance considerations:** Every trigger invocation adds per-row
overhead to the triggering statement — a trigger that runs an aggregate
query (like the example above) on every single-row `INSERT` is
`O(rows_in_employee_projects)` per insert unless well-indexed, which can
turn a bulk-load of many rows into a quadratic-time operation. Declarative
constraints, by contrast, have engine-optimized, typically O(1)-per-row
enforcement.

> **Common mistakes**
> - Trying to force a cross-row business rule into a `CHECK` constraint —
>   Postgres will reject `CHECK` expressions containing subqueries
>   entirely (`ERROR: cannot use subquery in check constraint`).
> - Writing a trigger for a rule a plain `CHECK`/`UNIQUE`/`FOREIGN KEY`
>   could express — always prefer the cheapest, most declarative
>   mechanism that actually captures the rule.

---

### Q81. Coding/diagnostic: composite `UNIQUE` constraints — explain what `UNIQUE (employee_id, effective_date)` on `salaries` and `UNIQUE (product_id, warehouse_location)` on `inventory` actually prevent, with a concrete failing `INSERT`.

```sql
-- salaries already has a row for (employee_id=3, effective_date='2022-01-01')
INSERT INTO salaries (employee_id, base_salary, bonus, effective_date)
VALUES (3, 999999, 0, '2022-01-01');
-- ERROR: duplicate key value violates unique constraint "salaries_employee_id_effective_date_key"
-- Key (employee_id, effective_date)=(3, 2022-01-01) already exists.
```

**Answer:** A **composite** `UNIQUE` constraint enforces uniqueness across
the **combination** of columns, not each column individually — Sneha
Kulkarni (`employee_id = 3`) can have many `salaries` rows (one per
`effective_date`, which is exactly the salary-history design), and many
different employees can share the same `effective_date` (e.g., a
company-wide raise date) — what's forbidden is **the same employee having
two salary rows effective on the same date**, which would be genuinely
ambiguous (which one is "current" for that date?). Identically,
`inventory`'s `UNIQUE (product_id, warehouse_location)` allows a product to
have stock rows in many warehouses and a warehouse to stock many products,
but forbids **two separate inventory rows for the same product in the same
warehouse** — exactly the invariant a stock-tracking table needs (there
should be exactly one "quantity on hand" figure per product-per-location).

**Why it works:** Postgres builds a single multi-column index backing the
constraint and checks the **tuple** `(employee_id, effective_date)` (or
`(product_id, warehouse_location)`) as the unit of uniqueness — neither
column alone needs to be unique, only their pairing.

**Alternative approaches:** Without the composite constraint, application
code could accidentally insert two conflicting salary rows for the same
employee/date (e.g., a retried API call after a timeout, unaware the first
attempt actually succeeded) — the constraint turns that scenario into a
clean, catchable error (`ON CONFLICT (employee_id, effective_date) DO
NOTHING`/`DO UPDATE`) instead of silent duplicate data.

**Performance considerations:** The composite unique index also
accelerates queries filtering on both columns together (or on the leading
column, `employee_id`, alone, per standard B-tree leftmost-prefix rules) —
a nice secondary benefit beyond pure constraint enforcement.

> **Common mistakes**
> - Assuming a composite `UNIQUE` constraint means each individual column
>   must also be unique on its own — it doesn't; only the combination is
>   constrained.
> - Not using `ON CONFLICT (employee_id, effective_date) DO UPDATE` for
>   idempotent retry-safe upserts against a table with exactly this kind
>   of composite natural key, and instead handling the resulting error
>   awkwardly in application code.

---

## 8. Database Design & Normalization

Good schema design prevents entire categories of bugs before a single
query is written. This section covers normal forms, functional
dependencies, key selection, and relationship modeling — using the
`company_db`/`ecommerce_db` schemas as worked examples of *already-
normalized* design, plus two hands-on "normalize this" exercises.

### Q82. Define 1NF, 2NF, and 3NF, each with a concrete violation and fix.

**Answer:**

**1NF (First Normal Form):** every column holds a single, atomic value —
no repeating groups or comma-separated lists in one field.
```sql
-- VIOLATION
CREATE TABLE bad_orders (order_id INT, product_names TEXT); -- 'Galaxy Phone X, Wireless Earbuds'
-- FIX: one row per (order, product) — exactly what order_items already does
```

**2NF (Second Normal Form):** 1NF, plus every non-key column depends on
the **whole** primary key, not just part of a composite key.
```sql
-- VIOLATION: composite PK (employee_id, project_id), but employee_name only depends on employee_id
CREATE TABLE bad_assignments (
    employee_id INT, project_id INT, employee_name TEXT, hours_allocated INT,
    PRIMARY KEY (employee_id, project_id)
);
-- FIX: exactly what employee_projects + employees already do — employee_name
-- lives in employees, keyed by employee_id alone; employee_projects keeps
-- only columns that genuinely depend on the (employee_id, project_id) pair.
```

**3NF (Third Normal Form):** 2NF, plus no **transitive** dependency — a
non-key column may not depend on another non-key column.
```sql
-- VIOLATION: department_location depends on department_id, not directly on employee_id
CREATE TABLE bad_employees (
    employee_id INT PRIMARY KEY, department_id INT, department_location TEXT
);
-- FIX: exactly what company_db already does — department_location lives in
-- departments, keyed by department_id; employees only stores the FK.
```

**Why it works:** Each successive normal form eliminates a specific kind of
**redundancy-driven update anomaly**: 1NF prevents needing to parse a
packed field to update one value; 2NF prevents duplicating
partially-key-dependent facts across every row of a composite-key table;
3NF prevents duplicating facts that actually belong to a *different*
entity (department) across every row of *this* entity (employee).

**Alternative approaches:** Deliberately **denormalizing** past 3NF (e.g.,
storing `department_name` directly on `employees` for read performance) is
a valid engineering trade-off in specific read-heavy scenarios — but it
must be a conscious choice with a plan for keeping the duplicated value in
sync (trigger, application logic, accepted staleness), not an accident of
poor initial design.

**Performance considerations:** Fully normalized schemas minimize storage
and eliminate update anomalies but require more `JOIN`s at query time;
`company_db`/`ecommerce_db`/`banking_db` are all designed to roughly 3NF,
which is the standard target for transactional (OLTP) systems — analytical
(OLAP) systems often deliberately denormalize into star schemas (Chapter
26/31) for query performance.

> **Common mistakes**
> - Confusing "the primary key" with "any unique column" when evaluating
>   2NF/3NF — normal forms are defined specifically in terms of *functional
>   dependency on the key*.
> - Treating normalization as an all-or-nothing religious rule rather than
>   an engineering trade-off against query complexity and read performance.

---

### Q83. Normalize this table exercise #1: a denormalized `order_report` flat table.

Given this single, unnormalized table a junior developer proposed for
reporting:

```sql
CREATE TABLE order_report (
    order_id        INT,
    order_date      DATE,
    customer_name   TEXT,
    customer_email  TEXT,
    product_name    TEXT,
    product_category TEXT,
    unit_price      NUMERIC,
    quantity        INT,
    payment_method  TEXT,
    payment_status  TEXT
);
```

Identify every normalization problem and redesign it to 3NF.

**Answer:** Problems:
1. **Repeating groups per order** — if an order has 3 products, this table
   needs 3 rows, each redundantly repeating `order_id`, `order_date`,
   `customer_name`, `customer_email`, `payment_method`, `payment_status`.
2. **Transitive dependency** — `customer_email` depends on `customer_name`
   (really, on a customer identity), not on `order_id` directly; likewise
   `product_category` depends on `product_name`/product identity, not on
   the order.
3. **Update anomaly** — if a customer's email changes, every historical
   order row for them must be updated, or the data silently diverges.
4. **Insertion anomaly** — you cannot record a new product in the catalog
   until someone orders it, since `product_name`/`product_category` only
   exist attached to an order row.
5. **Deletion anomaly** — deleting the only order a customer ever placed
   deletes all record that customer ever existed.

**Fix (exactly `ecommerce_db`'s actual design):**
```sql
users(user_id PK, username, email, full_name, ...)
categories(category_id PK, category_name, parent_category_id FK)
products(product_id PK, product_name, category_id FK, price, sku, ...)
orders(order_id PK, user_id FK, order_date, status, shipping_address)
order_items(order_item_id PK, order_id FK, product_id FK, quantity, unit_price)
payments(payment_id PK, order_id FK, payment_date, amount, payment_method, status)
```

**Why it works:** Every fact now lives in exactly one place, keyed by its
true identity: a customer's email lives once in `users`, a product's
category lives once in `products`/`categories`, and `order_items` captures
the *transaction-time* `unit_price` (correctly **not** normalized away,
because it's a fact about the sale, not the current product catalog —
prices change, but historical orders must reflect what was actually
charged).

**Alternative approaches:** A reporting/analytics layer can still expose a
single flat, denormalized *view* or materialized view joining all of this
back together for BI tool convenience — the normalization happens in the
storage schema; a deliberately denormalized read model on top is a
legitimate, separate design decision (Chapter 15, Chapter 26/31).

**Performance considerations:** The normalized design requires 5–6 table
joins to reconstruct the original flat report — entirely reasonable for a
transactional schema, and exactly why `order_items.unit_price` is
deliberately **not** further normalized (looking it up from `products`
would lose historical accuracy and add no genuine benefit).

> **Common mistakes**
> - "Normalizing" `unit_price` away entirely and always joining to
>   `products.price` for historical orders — silently rewrites history
>   every time a product's price changes.
> - Missing the `categories.parent_category_id` self-reference need and
>   instead flattening categories into a single `category_name` text
>   column, losing the ability to model subcategories.

---

### Q84. Normalize this table exercise #2: a denormalized `employee_flat` table with multi-valued project assignments.

```sql
CREATE TABLE employee_flat (
    employee_id      INT,
    employee_name    TEXT,
    manager_name     TEXT,
    department_name  TEXT,
    department_location TEXT,
    project_1_name   TEXT,
    project_1_hours  INT,
    project_2_name   TEXT,
    project_2_hours  INT,
    current_salary   NUMERIC
);
```

Identify every problem and redesign to 3NF.

**Answer:** Problems:
1. **1NF violation via "numbered columns"** — `project_1_*`/`project_2_*`
   is a repeating group spread across columns instead of rows; an employee
   on 3 projects has nowhere to go, and an employee on 1 project wastes
   `project_2_*` as `NULL`.
2. **Transitive dependency** — `department_location` depends on
   `department_name`, not on `employee_id`.
3. **Manager stored as a name, not a reference** — `manager_name` is
   free text with no guarantee it matches an actual employee, and provides
   no way to look up the manager's *other* attributes (email, department)
   without a fragile text match.
4. **`current_salary` conflates "current" with history** — no way to see
   how salary changed over time, and every raise requires an `UPDATE`
   that destroys the previous value rather than an `INSERT` of a new
   history row.

**Fix (exactly `company_db`'s actual design):**
```sql
departments(department_id PK, department_name, location)
employees(employee_id PK, first_name, last_name, ..., department_id FK, manager_id FK REFERENCES employees)
salaries(salary_id PK, employee_id FK, base_salary, bonus, effective_date)  -- one row per change, history preserved
projects(project_id PK, project_name, department_id FK, ...)
employee_projects(employee_id FK, project_id FK, role, hours_allocated, PRIMARY KEY(employee_id, project_id))  -- many-to-many bridge, unlimited projects per employee
```

**Why it works:** The numbered-column repeating group becomes a proper
many-to-many bridge table (`employee_projects`) supporting **any** number
of project assignments per employee with zero wasted columns.
`manager_id` becomes a real self-referencing foreign key, giving you actual
referential integrity and the ability to join back to the full manager
record. `salaries` becomes a history table, an explicit modeling choice
that preserves every past value rather than destructively overwriting.

**Alternative approaches:** If "current salary" truly needs to be queried
extremely frequently and the history join is a genuine bottleneck, a
`current_salary` denormalized column *could* be added to `employees` as a
deliberately maintained cache (kept in sync via trigger on `salaries`
insert) — a legitimate, explicit denormalization for performance, distinct
from the *accidental* denormalization in the original flat table.

**Performance considerations:** The bridge-table design (`employee_projects`)
costs one extra join versus the flat numbered-column design, but scales to
any number of projects per employee — the flat design's apparent
"performance win" (no join) is illusory since it can't even represent 3+
projects correctly.

> **Common mistakes**
> - "Fixing" the numbered columns by simply adding `project_3_name`,
>   `project_4_name`, etc. as the business grows — treating the symptom
>   instead of the actual repeating-group problem.
> - Storing `manager_name` as text and considering that "good enough"
>   because it's rarely wrong in practice — referential integrity failures
>   from text-matching are silent and cumulative.

---

### Q85. What is a functional dependency, and how does it formally justify the normal-form rules from Q82?

**Answer:** A functional dependency `X → Y` means: for any two rows with
the same value of `X`, they must also have the same value of `Y` — `Y`'s
value is fully determined by `X`. In `company_db.departments`,
`department_id → department_name` and `department_id → location` both
hold; in `employees`, `employee_id → department_id`, `employee_id →
hire_date`, etc. all hold.

**Why it works:** Normalization is formally the process of decomposing a
table so that **every** functional dependency present is "on the key" —
2NF eliminates dependencies on only *part* of a composite key; 3NF
eliminates dependencies on non-key columns (transitive dependencies). A
table is in 3NF precisely when every non-trivial functional dependency
`X → Y` has `X` as a superkey (or `Y` is part of some candidate key,
the BCNF-adjacent exception) — this is the rigorous definition underlying
the "no partial/transitive dependency" descriptions from Q82.

**Alternative approaches:** Boyce-Codd Normal Form (BCNF) is a slightly
stricter version of 3NF closing a narrow edge case where a table has
**multiple overlapping candidate keys** — genuinely rare in practical
schema design, but worth knowing exists for exhaustive interview coverage
(the standard textbook example involves a table where a course, teacher,
and textbook interrelate with more than one plausible key).

**Performance considerations:** N/A — functional dependency is a
theoretical/design-time concept, not a runtime performance concern
directly, though the schemas it produces have all the performance
implications discussed in Q82–Q84.

> **Common mistakes**
> - Trying to memorize normal-form definitions as disconnected rules
>   rather than understanding they all reduce to "eliminate functional
>   dependencies not anchored on a key" — the underlying concept makes the
>   specific rules easy to re-derive rather than memorize.
> - Confusing a functional dependency (`X → Y`, a data-modeling fact) with
>   a foreign key (`X REFERENCES other_table`, a specific enforcement
>   mechanism) — related but not the same thing; a functional dependency
>   can exist entirely within one table.

---

### Q86. Surrogate key vs. natural key — why does every table in these three schemas use a `SERIAL`/`BIGSERIAL` surrogate primary key instead of a natural one?

**Answer:** A **natural key** is a real-world attribute (or combination)
that's already unique — e.g., `employees.email`. A **surrogate key** is an
artificial, meaningless identifier generated purely to serve as a primary
key — `employee_id SERIAL`. All three schemas use surrogate keys
everywhere, even where a plausible natural key exists (`email` is `UNIQUE`
but **not** the primary key).

**Why it works:** Surrogate keys are immune to real-world change — if an
employee's email changes (a natural key would), every foreign key
referencing them across `salaries`, `attendance`, `employee_projects`,
`managers` would need to cascade-update under a natural-key design; with a
surrogate key, the email can change freely without touching a single
foreign key anywhere, since nothing references it by value. Surrogate
keys are also typically smaller/faster to index (an `INT`/`BIGINT` vs. a
`VARCHAR(150)` email) and never carry accidental business meaning that
might later prove not-actually-unique (a "natural" key like a national ID
number can turn out to have real-world duplicates/reassignment cases).

**Alternative approaches:** Natural keys are still appropriate as
**secondary** `UNIQUE` constraints (exactly how `email` and
`department_name` are handled here) — you get uniqueness enforcement
without paying the propagation cost of using them as the primary/foreign
key value everywhere.

**Performance considerations:** Integer surrogate keys are more compact
(smaller indexes, faster joins/comparisons) than typical natural keys
like emails or composite business identifiers — a genuine, measurable
performance argument beyond the maintainability one.

> **Common mistakes**
> - Using a natural key as the primary key and later discovering it
>   wasn't actually immutable/unique after all (a common real-world
>   failure mode: "surely a national ID is unique and permanent" turns out
>   false in edge cases).
> - Believing surrogate keys mean you can skip `UNIQUE` constraints on the
>   real natural-key candidates — you still need `UNIQUE (email)` to
>   enforce the actual business rule; the surrogate key alone doesn't do
>   that.

---

### Q87. Model the three canonical relationship cardinalities (1:1, 1:N, N:M) using real tables from these schemas.

**Answer:**
- **One-to-one (1:1):** `departments` ↔ `managers` — each department has
  **exactly one** managing employee, and `managers.department_id` is
  declared `UNIQUE` (not just indexed), which is precisely what turns an
  otherwise-1:N-looking FK into a true 1:1 relationship. Without that
  `UNIQUE`, nothing would stop two different employees from both being
  recorded as department 1's manager.
- **One-to-many (1:N):** `departments` → `employees` — one department has
  many employees, but each employee belongs to (at most) one department;
  the FK lives on the "many" side (`employees.department_id`), which is
  the universal rule for modeling 1:N.
- **Many-to-many (N:M):** `employees` ↔ `projects` via `employee_projects`
  — one employee can work on many projects, and one project can have many
  employees; **no** direct FK can express this alone, requiring a bridge
  table whose composite primary key (`employee_id, project_id`) itself
  guarantees no duplicate assignment rows.

**Why it works:** The `UNIQUE` constraint is the specific mechanism that
distinguishes 1:1 from 1:N when both are implemented as "a foreign key on
one side" — without it, `managers` would silently permit multiple
employees claiming to manage the same department (breaking the intended
1:1 semantics) while still looking syntactically identical to a correct
1:1 design.

**Alternative approaches:** A 1:1 relationship could also be modeled by
simply adding the manager's `employee_id` directly as a column on
`departments` itself (`departments.manager_id FK`), rather than a separate
`managers` table — a legitimate alternative; the separate-table approach
(as actually used here) is preferable when the 1:1 relationship carries
its **own** additional attributes (here, `appointed_date`), which
wouldn't have an obvious home directly on `departments`.

**Performance considerations:** N:M bridge tables benefit from an index on
each individual FK column in addition to the composite PK (which only
efficiently supports lookups starting from `employee_id`, the leading
column) — querying "which employees are on project 3" via
`employee_projects` benefits from an index on `project_id` alone, which
the composite PK `(employee_id, project_id)` does **not** provide by
itself.

> **Common mistakes**
> - Modeling a 1:1 relationship as a plain FK without `UNIQUE`, silently
>   allowing it to degrade into a 1:N relationship as data grows.
> - Trying to model N:M with a comma-separated ID list in one column
>   (violates 1NF, Q82) instead of a proper bridge table.
> - Forgetting to add a standalone index on the *non-leading* column of a
>   many-to-many bridge table's composite primary key.

---

### Q88. Denormalization trade-offs — when, specifically, is it correct to deliberately break 3NF?

**Answer:** Denormalization is justified when read performance genuinely
requires avoiding expensive joins/aggregations at query time, and the team
explicitly accepts the corresponding write-side complexity of keeping
duplicated data in sync. Concrete scenarios relevant to these schemas:

- **Materialized aggregate:** storing `products.total_units_sold` directly
  on `products` (instead of always computing `SUM(quantity) FROM
  order_items GROUP BY product_id`) to make a frequently-hit "best
  sellers" page fast — requires a trigger or scheduled job to keep it
  correct as new orders arrive.
- **Star schema for analytics** (Chapter 26/31, `analytics_db`): fact
  tables deliberately duplicate dimension attributes (e.g., a
  `date_key`'s year/month/quarter directly in the fact row) to avoid
  joining a `dim_date` table for every analytical query at massive scale.
- **Read replicas / caching layers**: technically outside the schema
  itself, but the same trade-off — accept staleness/duplication for read
  speed.

**Why it works:** In each case, the *cost* of denormalization (extra
storage, a synchronization mechanism, potential temporary staleness) is
weighed explicitly against a *measured* read-performance benefit — this is
categorically different from the Q83/Q84 flat tables, which weren't a
deliberate trade-off at all, just poor initial design with **no**
compensating performance benefit (they were slower to maintain *and*
harder to query correctly).

**Alternative approaches:** A materialized view (Chapter 15) is often the
safer middle ground — it looks and is queried like a denormalized table,
but is mechanically `REFRESH`ed from the normalized source of truth rather
than manually kept in sync by scattered application/trigger code, reducing
the risk of the duplicated value silently drifting out of sync.

**Performance considerations:** This is inherently a performance question
— the entire justification for denormalizing is a measured query-latency
or throughput problem that joins/aggregation alone can't solve at the
required scale; denormalizing *without* first measuring that the
normalized form is actually a bottleneck is premature optimization.

> **Common mistakes**
> - Denormalizing preemptively "for performance" without first measuring
>   that the normalized/joined query is actually too slow for the real
>   workload.
> - Denormalizing without any mechanism (trigger, scheduled job,
>   materialized view refresh) to keep the duplicated value in sync,
>   guaranteeing eventual data drift.

---

### Q89. Conceptual capstone: walk through why `company_db`'s `managers` table is *not* redundant with `employees.manager_id`, even though both seem to encode "who manages whom."

**Answer:** They encode **different relationships** despite the surface
similarity: `employees.manager_id` answers "who is *this employee's*
direct supervisor?" (a 1:N relationship — many employees can share one
manager, modeled as an FK on the "many" side, and it's a **self**-
reference within `employees`). `managers` answers a completely different
question: "who is the **official head of this department**?" (a 1:1
relationship between `departments` and a specific `employees` row, with
its own attribute, `appointed_date`, that has no natural home on either
`employees` or `departments` directly).

The two can, and in this seed data do, mostly agree (Aditi is department 1's
`managers` head *and* is the `manager_id` for department 1's direct
reports) — but they're **not required to agree**, and that's the whole
point: a department's official head (`managers`) doesn't have to be the
same person as any given employee's direct line manager
(`employees.manager_id`) in a real org where matrix reporting, interim
leadership, or dotted-line structures exist.

**Why it works:** This is a textbook example of the modeling principle
"don't conflate two relationships just because they're usually correlated
in your current data" — collapsing them into one structure would work
fine until the business rule inevitably diverges (an interim department
head who isn't yet anyone's formal line manager, for instance), at which
point the conflated design couldn't express the real-world state at all.

**Alternative approaches:** A smaller schema might reasonably decide the
distinction isn't worth the extra table and just use `employees.manager_id`
for both purposes, accepting the limitation — a legitimate simplification
for a smaller/simpler domain, but the course deliberately keeps both to
teach the modeling distinction explicitly.

**Performance considerations:** N/A — this is a pure data-modeling
correctness question, not a performance one; the "cost" of keeping them
separate is one small extra table and one extra join when you need
"official department head" specifically, which is cheap relative to the
correctness gained.

> **Common mistakes**
> - Assuming any two columns/tables that are usually in agreement in
>   sample/test data must therefore be redundant and safe to merge — real
>   schemas should be designed around what the business rule *can*
>   express, not what today's data happens to show.
> - Missing that `managers.department_id UNIQUE` is what actually encodes
>   the 1:1 "one head per department" rule — without it, `managers` could
>   not even guarantee that invariant, undermining the whole reason for
>   its separate existence.

---

## Summary

This bank covered **89 questions** across Joins, Subqueries, CTEs &
Recursive CTEs, Window Functions, Transactions & ACID, Locks &
Concurrency, Constraints, and Database Design & Normalization — every
coding answer computed against the real seed data in `company_db`,
`ecommerce_db`, and `banking_db`. Continue to
[Advanced (75+)](03-advanced.md) for query planning, indexing internals,
and deeper concurrency/design scenarios.

