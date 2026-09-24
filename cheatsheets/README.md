# SQL Mastery — Cheat Sheets (Chapter 37)

Quick-lookup companion to the full course. Every entry here is taught in
depth in its linked chapter — this page is deliberately terse: syntax
skeletons, tables, and one-liners only. Primary dialect is **PostgreSQL**;
divergences are flagged **[PostgreSQL]** **[MySQL]** **[Oracle]** **[SQL Server]**.

## Table of Contents

1. [SELECT](#select)
2. [WHERE](#where)
3. [JOIN](#join)
4. [GROUP BY / HAVING](#group-by--having)
5. [Subqueries](#subqueries)
6. [CTE](#cte)
7. [Window Functions](#window-functions)
8. [Transactions](#transactions)
9. [Stored Procedures](#stored-procedures)
10. [Functions](#functions)
11. [Cursors](#cursors)
12. [Triggers](#triggers)
13. [Indexes](#indexes)
14. [EXPLAIN](#explain)
15. [Performance Optimization](#performance-optimization)
16. [Security](#security)

---

## SELECT

*(see Chapters 2–4)*

### Syntax skeleton (written order vs. execution order differ — see [GROUP BY](#group-by--having))

```sql
SELECT   [DISTINCT] col1 [AS alias1], col2, expr, agg_fn(col3)
FROM     table1
JOIN     table2 ON ...
WHERE    condition
GROUP BY col1, col2
HAVING   agg_condition
ORDER BY col1 [ASC|DESC] [NULLS FIRST|LAST]
LIMIT    n OFFSET m;
```

### Clause order (as written)

| # | Clause | Required? |
|---|--------|-----------|
| 1 | `SELECT [DISTINCT]` | yes |
| 2 | `FROM` | no (except Oracle: `FROM dual`) |
| 3 | `JOIN ... ON` | no |
| 4 | `WHERE` | no |
| 5 | `GROUP BY` | no |
| 6 | `HAVING` | no (requires GROUP BY or full aggregation) |
| 7 | `ORDER BY` | no |
| 8 | `LIMIT/OFFSET` | no |

### DISTINCT

```sql
SELECT DISTINCT col1, col2 FROM t;             -- dedupe on (col1, col2)
SELECT DISTINCT ON (col1) *                    -- [PostgreSQL] first row per col1 group
FROM t ORDER BY col1, col2 DESC;
```

### Aliases

```sql
SELECT e.first_name AS fname, d.name dept_name  -- AS optional (not in Oracle for tables)
FROM employees AS e JOIN departments d ON e.dept_id = d.id;
```

### CASE (simple & searched)

```sql
SELECT
  CASE status WHEN 'A' THEN 'Active' WHEN 'I' THEN 'Inactive' ELSE 'Unknown' END,
  CASE WHEN salary > 100000 THEN 'High'
       WHEN salary > 50000  THEN 'Mid'
       ELSE 'Low' END AS band
FROM employees;
```

### Common patterns

| Pattern | Snippet |
|---|---|
| Top-N per group | `DISTINCT ON` [PostgreSQL] or `ROW_NUMBER()` window (all dialects) |
| Conditional column | `CASE WHEN ... END` |
| Null-safe default | `COALESCE(col, 0)` |
| Column-to-row pivot | `CASE` + `GROUP BY` or `CROSSTAB`/`PIVOT` |
| Random sample | `ORDER BY RANDOM() LIMIT n` [PostgreSQL/MySQL: `RAND()`] |

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Row limit | `LIMIT n OFFSET m` | `LIMIT m, n` | `FETCH FIRST n ROWS ONLY` | `TOP n` / `OFFSET...FETCH` |
| No-table SELECT | `SELECT 1;` | `SELECT 1;` | `SELECT 1 FROM dual;` | `SELECT 1;` |
| Top-N per group | `DISTINCT ON` | window fn only | window fn only | window fn only |

---

## WHERE

*(see Chapters 2–3)*

### Comparison operators

| Operator | Meaning |
|---|---|
| `=` `<>` / `!=` | equal / not equal |
| `<` `>` `<=` `>=` | ordering |
| `BETWEEN a AND b` | inclusive range |
| `IN (v1, v2, ...)` | set membership |
| `LIKE` / `ILIKE` [PostgreSQL] | pattern match (case-sensitive / insensitive) |
| `IS NULL` / `IS NOT NULL` | null test (never use `= NULL`) |

### Pattern-matching wildcards (LIKE)

| Wildcard | Meaning |
|---|---|
| `%` | zero or more characters |
| `_` | exactly one character |
| `ESCAPE '\'` | escape a literal `%`/`_` |
| `~` / `~*` [PostgreSQL] | regex match / case-insensitive regex |

### Logical operators & precedence (highest → lowest)

```
NOT  >  AND  >  OR
```

```sql
WHERE dept = 'IT' AND salary > 50000 OR dept = 'HR'
-- reads as: (dept = 'IT' AND salary > 50000) OR dept = 'HR'
-- always parenthesize when mixing AND/OR to avoid this trap
WHERE dept = 'IT' AND (salary > 50000 OR bonus > 5000)
```

### Snippets

```sql
WHERE hire_date BETWEEN '2023-01-01' AND '2023-12-31';
WHERE dept_id IN (1, 2, 3);
WHERE email LIKE '%@gmail.com';
WHERE name ILIKE 'jo%';          -- [PostgreSQL] case-insensitive
WHERE manager_id IS NULL;
WHERE NOT (status = 'CLOSED');
```

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Case-insensitive LIKE | `ILIKE` | `LIKE` (default collation-dependent) | `LIKE` + `UPPER()` | `LIKE` (collation-dependent) |
| Regex match | `~` / `~*` | `REGEXP` | `REGEXP_LIKE()` | `LIKE` only (no native regex) |
| Not-equal | `<>` or `!=` | `<>` or `!=` | `<>` or `!=` | `<>` or `!=` |

---

## JOIN

*(see Chapter 7)*

### Join type summary

| Join | Result set |
|---|---|
| `INNER JOIN` | only rows matching in both tables |
| `LEFT JOIN` | all left rows + matched right cols, unmatched right = NULL |
| `RIGHT JOIN` | all right rows + matched left cols, unmatched left = NULL |
| `FULL [OUTER] JOIN` | all rows from both, unmatched side = NULL |
| `CROSS JOIN` | Cartesian product (every row × every row) |
| `SELF JOIN` | table joined to itself via alias, for hierarchical/peer comparisons |

### Syntax

```sql
SELECT ... FROM a INNER JOIN b ON a.id = b.a_id;
SELECT ... FROM a LEFT  JOIN b ON a.id = b.a_id;
SELECT ... FROM a RIGHT JOIN b ON a.id = b.a_id;
SELECT ... FROM a FULL  JOIN b ON a.id = b.a_id;
SELECT ... FROM a CROSS JOIN b;
SELECT e.name, m.name AS manager
FROM employees e JOIN employees m ON e.manager_id = m.id;   -- self join
```

### ON vs WHERE gotcha

> Filtering the **right** table of a `LEFT JOIN` in `WHERE` silently turns it
> into an `INNER JOIN` (NULLs get filtered out). Put outer-join filters on
> the matched (right) table in the `ON` clause, not `WHERE`.

```sql
-- WRONG: kills unmatched rows
FROM orders o LEFT JOIN payments p ON o.id = p.order_id
WHERE p.status = 'PAID';

-- RIGHT: preserves unmatched orders
FROM orders o LEFT JOIN payments p ON o.id = p.order_id AND p.status = 'PAID';
```

### Anti-join / semi-join patterns

| Pattern | Purpose | Snippet |
|---|---|---|
| Semi-join | rows in A that HAVE a match in B (no B columns) | `WHERE EXISTS (SELECT 1 FROM b WHERE b.a_id = a.id)` |
| Anti-join | rows in A with NO match in B | `WHERE NOT EXISTS (SELECT 1 FROM b WHERE b.a_id = a.id)` |
| Anti-join (LEFT JOIN form) | same, join-based | `FROM a LEFT JOIN b ON a.id=b.a_id WHERE b.a_id IS NULL` |

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| `FULL OUTER JOIN` | yes | not supported (emulate: `LEFT JOIN UNION RIGHT JOIN`) | yes | yes |
| Old-style outer join | n/a | n/a | `(+)` operator (legacy) | n/a |
| `RIGHT JOIN` | yes | yes | yes | yes |

---

## GROUP BY / HAVING

*(see Chapter 6)*

### Logical query execution order

```
1. FROM / JOIN
2. WHERE            (row filter, before grouping — no aggregates allowed)
3. GROUP BY         (forms groups)
4. HAVING           (group filter — aggregates allowed)
5. SELECT           (incl. window functions)
6. DISTINCT
7. ORDER BY
8. LIMIT / OFFSET
```

### WHERE vs HAVING

| | WHERE | HAVING |
|---|---|---|
| Filters | individual rows | grouped/aggregated rows |
| Runs | before grouping | after grouping |
| Aggregates allowed? | no | yes |

### Conditional aggregation

```sql
SELECT
  dept_id,
  COUNT(*) FILTER (WHERE salary > 80000) AS high_earners,   -- [PostgreSQL]
  SUM(CASE WHEN salary > 80000 THEN 1 ELSE 0 END) AS high_earners_portable
FROM employees
GROUP BY dept_id
HAVING COUNT(*) > 5;
```

### COUNT variants

| Expression | Counts |
|---|---|
| `COUNT(*)` | all rows, including NULLs, in the group |
| `COUNT(col)` | non-NULL values of `col` only |
| `COUNT(DISTINCT col)` | distinct non-NULL values of `col` |

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| `FILTER (WHERE ...)` | yes | no (use `SUM(CASE...)`) | no | no |
| Non-aggregated column in SELECT w/ GROUP BY | error (must be grouped/functionally dependent) | allowed by default (nondeterministic!) unless `ONLY_FULL_GROUP_BY` | error | error |
| `GROUPING SETS`/`ROLLUP`/`CUBE` | yes | `ROLLUP` only (`WITH ROLLUP`) | yes | yes |

---

## Subqueries

*(see Chapter 8)*

### Syntax forms

```sql
-- Scalar subquery (must return exactly 1 row, 1 col)
SELECT name, (SELECT AVG(salary) FROM employees) AS company_avg FROM employees;

-- Correlated subquery (references outer query per row)
SELECT * FROM employees e
WHERE salary > (SELECT AVG(salary) FROM employees e2 WHERE e2.dept_id = e.dept_id);

-- EXISTS / NOT EXISTS
SELECT * FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);

-- IN / NOT IN
SELECT * FROM employees WHERE dept_id IN (SELECT id FROM departments WHERE region = 'US');

-- ANY / SOME (equivalent) / ALL
SELECT * FROM products WHERE price > ANY (SELECT price FROM products WHERE category = 'Book');
SELECT * FROM products WHERE price > ALL (SELECT price FROM products WHERE category = 'Book');
```

### The NOT IN + NULL trap

> `WHERE col NOT IN (subquery)` returns **zero rows** if the subquery result
> contains even one `NULL` — `NOT IN` becomes `col <> v1 AND col <> v2 AND col <> NULL`,
> and any comparison to `NULL` is `UNKNOWN`. Use `NOT EXISTS` instead.

### EXISTS vs IN — quick decision

| Situation | Prefer |
|---|---|
| Subquery column may contain NULLs | `EXISTS` / `NOT EXISTS` |
| Small, static, known-non-null list | `IN` |
| Correlated check ("does a matching row exist") | `EXISTS` (often faster, short-circuits) |
| Need anti-join | `NOT EXISTS` (never `NOT IN` unless column is `NOT NULL`) |

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| `ANY`/`SOME`/`ALL` | yes | yes | yes | yes |
| Correlated subquery in `UPDATE`/`DELETE` | yes | yes (needs derived table trick pre-8.0 for same-table) | yes | yes |
| Row constructor subqueries `(a,b) IN (SELECT...)` | yes | yes | yes | limited |

---

## CTE

*(see Chapter 9)*

### WITH syntax

```sql
WITH regional_sales AS (
  SELECT region, SUM(amount) AS total FROM sales GROUP BY region
), top_regions AS (
  SELECT region FROM regional_sales WHERE total > 1000000
)
SELECT * FROM sales s JOIN top_regions t ON s.region = t.region;
```

### Recursive CTE skeleton

```sql
WITH RECURSIVE org_chart AS (
  -- base term (anchor)
  SELECT id, name, manager_id, 1 AS level
  FROM employees WHERE manager_id IS NULL

  UNION ALL

  -- recursive term (joins back to the CTE itself)
  SELECT e.id, e.name, e.manager_id, oc.level + 1
  FROM employees e
  JOIN org_chart oc ON e.manager_id = oc.id
)
SELECT * FROM org_chart ORDER BY level;
```

### MATERIALIZED reminder

> [PostgreSQL 12+] CTEs are **NOT** auto-inlined by default only for
> `RECURSIVE`/side-effecting cases — otherwise the planner may inline
> (`NOT MATERIALIZED`) or optimization-fence (`MATERIALIZED`) a CTE. Force
> behavior explicitly when needed:

```sql
WITH cte1 AS MATERIALIZED (...)      -- always compute once, as an optimization fence
WITH cte1 AS NOT MATERIALIZED (...)  -- allow inlining into outer query
```

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Recursive CTE keyword | `WITH RECURSIVE` | `WITH RECURSIVE` (8.0+) | `WITH` (recursive implicit via `UNION ALL` + self-ref) | `WITH` (recursive implicit) |
| `MATERIALIZED` hint | yes (12+) | no | `/*+ MATERIALIZE */` hint | no |
| CTE reused multiple times | optimization varies | inlined each use (pre-8.0 no CTEs at all) | optimizer decides | optimizer decides |

---

## Window Functions

*(see Chapter 10)*

### Skeleton

```sql
function_name(...) OVER (
  [PARTITION BY col1, col2]
  [ORDER BY col3 [ASC|DESC]]
  [ROWS|RANGE BETWEEN frame_start AND frame_end]
)
```

Frame bounds: `UNBOUNDED PRECEDING`, `N PRECEDING`, `CURRENT ROW`, `N FOLLOWING`, `UNBOUNDED FOLLOWING`.

### Function reference

| Function | Description |
|---|---|
| `ROW_NUMBER()` | unique sequential number per row within partition, no ties |
| `RANK()` | rank with gaps after ties (1,1,3) |
| `DENSE_RANK()` | rank without gaps after ties (1,1,2) |
| `NTILE(n)` | bucket rows into `n` roughly equal groups |
| `LAG(col, n, default)` | value from `n` rows before current row |
| `LEAD(col, n, default)` | value from `n` rows after current row |
| `FIRST_VALUE(col)` | first value in the current frame |
| `LAST_VALUE(col)` | last value in the current frame (see gotcha below) |
| `SUM/AVG/COUNT(col) OVER (...)` | running/partitioned aggregate without collapsing rows |

### LAST_VALUE frame gotcha

> Default frame for `ORDER BY` windows is
> `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — so `LAST_VALUE`
> returns the **current row**, not the partition's true last row. Fix:

```sql
LAST_VALUE(col) OVER (
  PARTITION BY grp ORDER BY dt
  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
)
```

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Window functions | yes | 8.0+ | yes | 2012+ |
| `FILTER` inside window agg | yes | no | no | no |
| Named windows (`WINDOW w AS (...)`) | yes | yes (8.0+) | no | no |
| `IGNORE NULLS` on LAG/LEAD/FIRST/LAST | no (workaround needed) | no | yes | yes |

---

## Transactions

*(see Chapters 11–12)*

### Syntax

```sql
BEGIN;                          -- or START TRANSACTION;
  UPDATE accounts SET balance = balance - 100 WHERE id = 1;
  SAVEPOINT sp1;
  UPDATE accounts SET balance = balance + 100 WHERE id = 2;
  ROLLBACK TO SAVEPOINT sp1;    -- undo only work since sp1
  RELEASE SAVEPOINT sp1;
COMMIT;                         -- or ROLLBACK;
```

### ACID one-liners

| Property | Guarantee |
|---|---|
| **A**tomicity | all-or-nothing: entire transaction commits or none of it does |
| **C**onsistency | every commit leaves the DB satisfying all constraints/invariants |
| **I**solation | concurrent transactions don't see each other's uncommitted effects |
| **D**urability | once committed, survives crashes (via WAL/redo log) |

### Isolation levels × anomalies (condensed)

| Isolation Level | Dirty Read | Non-Repeatable Read | Phantom Read |
|---|---|---|---|
| Read Uncommitted | possible | possible | possible |
| Read Committed | prevented | possible | possible |
| Repeatable Read | prevented | prevented | possible (prevented in PostgreSQL) |
| Serializable | prevented | prevented | prevented |

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Default isolation | Read Committed | Repeatable Read | Read Committed | Read Committed |
| `Read Uncommitted` actual behavior | treated as Read Committed | true dirty reads | not supported (min is Read Committed) | true dirty reads |
| Set isolation | `SET TRANSACTION ISOLATION LEVEL ...` | `SET TRANSACTION ISOLATION LEVEL ...` | `SET TRANSACTION ISOLATION LEVEL ...` | `SET TRANSACTION ISOLATION LEVEL ...` |
| Serializable implementation | SSI (predicate locking) | true locking | true locking (+ read consistency) | true locking / snapshot |

---

## Stored Procedures

*(see Chapter 19)*

### Skeleton [PostgreSQL / PL/pgSQL]

```sql
CREATE OR REPLACE PROCEDURE transfer_funds(
  IN  p_from   INT,
  IN  p_to     INT,
  IN  p_amount NUMERIC,
  OUT p_status TEXT,
  INOUT p_ref  UUID DEFAULT gen_random_uuid()
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_balance NUMERIC;
BEGIN
  SELECT balance INTO v_balance FROM accounts WHERE id = p_from FOR UPDATE;

  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient funds for account %', p_from;
  END IF;

  UPDATE accounts SET balance = balance - p_amount WHERE id = p_from;
  UPDATE accounts SET balance = balance + p_amount WHERE id = p_to;

  p_status := 'OK';
EXCEPTION
  WHEN OTHERS THEN
    p_status := 'FAILED: ' || SQLERRM;
    ROLLBACK;
END;
$$;

CALL transfer_funds(1, 2, 100.00, NULL, NULL);
```

### Parameter modes

| Mode | Direction |
|---|---|
| `IN` | passed in, read-only (default) |
| `OUT` | returned to caller, not passed in |
| `INOUT` | passed in and modified/returned |

### Control-flow skeletons

```sql
-- IF
IF condition THEN ... ELSIF condition2 THEN ... ELSE ... END IF;

-- LOOP (infinite, needs EXIT)
LOOP
  EXIT WHEN v_count > 10;
  v_count := v_count + 1;
END LOOP;

-- WHILE
WHILE v_count < 10 LOOP
  v_count := v_count + 1;
END LOOP;

-- FOR (numeric)
FOR i IN 1..10 LOOP ... END LOOP;

-- FOR (query loop, implicit cursor)
FOR rec IN SELECT * FROM employees LOOP
  RAISE NOTICE '%', rec.name;
END LOOP;
```

### Exception handling skeleton

```sql
BEGIN
  ... risky code ...
EXCEPTION
  WHEN division_by_zero THEN RAISE NOTICE 'Div by zero';
  WHEN unique_violation  THEN RAISE NOTICE 'Duplicate key';
  WHEN OTHERS THEN RAISE NOTICE 'Error: %', SQLERRM;
END;
```

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Language | PL/pgSQL (default) | SQL/PSM | PL/SQL | T-SQL |
| Call syntax | `CALL proc(...)` | `CALL proc(...)` | `EXEC proc(...)` or `BEGIN proc(...); END;` | `EXEC proc ...` |
| Can procedures manage transactions? | yes (`COMMIT`/`ROLLBACK` inside) | limited | yes | yes |
| Exception construct | `EXCEPTION WHEN ...` | `DECLARE ... HANDLER FOR` | `EXCEPTION WHEN ...` | `TRY ... CATCH` |

---

## Functions

*(see Chapter 20)*

### Skeleton

```sql
CREATE OR REPLACE FUNCTION full_name(p_first TEXT, p_last TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN p_first || ' ' || p_last;
END;
$$;

-- Table-valued
CREATE OR REPLACE FUNCTION top_earners(p_limit INT)
RETURNS TABLE(id INT, name TEXT, salary NUMERIC)
LANGUAGE sql
AS $$
  SELECT id, name, salary FROM employees ORDER BY salary DESC LIMIT p_limit;
$$;

-- SETOF
CREATE FUNCTION active_users() RETURNS SETOF users AS $$
  SELECT * FROM users WHERE active = true;
$$ LANGUAGE sql;

-- VOID (side effect only)
CREATE FUNCTION log_event(p_msg TEXT) RETURNS VOID AS $$
BEGIN
  INSERT INTO event_log(msg) VALUES (p_msg);
END;
$$ LANGUAGE plpgsql;
```

### RETURNS variants

| Variant | Use for |
|---|---|
| scalar (`INT`, `TEXT`, ...) | single value |
| `TABLE(...)` | multiple named columns, multiple rows |
| `SETOF type` | multiple rows of an existing type/table |
| `VOID` | side effects only, no meaningful return |

### Volatility categories [PostgreSQL]

| Category | Meaning |
|---|---|
| `IMMUTABLE` | same inputs always produce same output, no DB access — safe to precompute/index |
| `STABLE` | same result within a single scan/statement, may read DB (e.g. `now()`-free lookups) |
| `VOLATILE` (default) | can return different results every call, may have side effects |

### Function vs procedure

> A **function** returns a value and can be used inside a query
> (`SELECT`/`WHERE`); a **procedure** performs actions, manages its own
> transactions, and is invoked standalone via `CALL` — it cannot be used
> inline in a query.

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Table-valued functions | yes (`RETURNS TABLE`/`SETOF`) | no native (use views/procs) | pipelined functions | yes (`RETURNS TABLE`) |
| Volatility hints | `IMMUTABLE/STABLE/VOLATILE` | `DETERMINISTIC` flag only | `DETERMINISTIC` flag only | not enforced (`SCHEMABINDING` helps) |
| Function can COMMIT? | no | no | no (unless autonomous txn) | no |

---

## Cursors

*(see Chapter 21)*

### Skeleton [PL/pgSQL]

```sql
DO $$
DECLARE
  c_emp CURSOR FOR SELECT id, name, salary FROM employees WHERE dept_id = 3;
  v_rec RECORD;
BEGIN
  OPEN c_emp;
  LOOP
    FETCH c_emp INTO v_rec;
    EXIT WHEN NOT FOUND;
    RAISE NOTICE '%: %', v_rec.name, v_rec.salary;
  END LOOP;
  -- MOVE FORWARD 1 FROM c_emp;   -- reposition without fetching
  CLOSE c_emp;
END;
$$;
```

### Cursor FOR loop (implicit open/fetch/close)

```sql
FOR v_rec IN SELECT id, name FROM employees WHERE dept_id = 3 LOOP
  RAISE NOTICE '%', v_rec.name;
END LOOP;
```

### Reminder

> Cursors process row-by-row and are almost always slower than an
> equivalent set-based query. Reach for a cursor only when logic truly
> cannot be expressed as a single set operation (rare) — prefer plain SQL.

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Explicit cursor keywords | `DECLARE/OPEN/FETCH/MOVE/CLOSE` | `DECLARE ... CURSOR FOR`, `FETCH`, `CLOSE` (no `MOVE`) | `OPEN/FETCH/CLOSE`, `%FOUND`/`%NOTFOUND` attrs | `DECLARE/OPEN/FETCH/CLOSE/DEALLOCATE` |
| Cursor scope | function/procedure body | stored routine body only | PL/SQL block | batch/procedure, can be global |

---

## Triggers

*(see Chapter 22)*

### Skeleton

```sql
CREATE OR REPLACE FUNCTION audit_salary_change() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.salary <> OLD.salary THEN
    INSERT INTO salary_audit(emp_id, old_salary, new_salary, changed_at)
    VALUES (OLD.id, OLD.salary, NEW.salary, now());
  END IF;
  RETURN NEW;   -- NULL to suppress the operation (BEFORE triggers only)
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_salary
  AFTER UPDATE OF salary ON employees      -- timing + event
  FOR EACH ROW                              -- level: ROW or STATEMENT
  WHEN (OLD.salary IS DISTINCT FROM NEW.salary)
  EXECUTE FUNCTION audit_salary_change();
```

### OLD / NEW availability

| Operation | `OLD` | `NEW` |
|---|---|---|
| `INSERT` | not available | available |
| `UPDATE` | available | available |
| `DELETE` | available | not available |

### Row-level vs statement-level

> Row-level (`FOR EACH ROW`) fires once per affected row and can access
> `OLD`/`NEW`; statement-level (`FOR EACH STATEMENT`) fires once per
> statement regardless of row count and cannot access `OLD`/`NEW` directly
> (only via transition tables in PostgreSQL: `REFERENCING OLD TABLE AS ...`).

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Trigger body | separate function, `EXECUTE FUNCTION` | inline body | inline PL/SQL block | inline T-SQL block |
| Statement-level transition tables | `REFERENCING NEW TABLE AS ...` | no | no | `inserted`/`deleted` pseudo-tables (always statement-level) |
| `INSTEAD OF` triggers (on views) | yes | no | yes | yes |
| Multiple triggers same event | ordered via `FOLLOWS`/`PRECEDES` (or alphabetical) | fires by creation order (5.7+ `FOLLOWS`) | undefined unless ordered | undefined unless ordered |

---

## Indexes

*(see Chapter 16)*

### Index type quick-reference

| Type | Use when |
|---|---|
| B-tree (default) | equality and range queries (`=`, `<`, `>`, `BETWEEN`, sorting) |
| Hash | pure equality lookups only, no range support |
| Partial | index only a filtered subset of rows (e.g. `WHERE active = true`) |
| Expression | index the result of a function/expression (e.g. `LOWER(email)`) |
| Covering (`INCLUDE`) | satisfy a query entirely from the index, avoiding a heap fetch |
| Composite (multi-column) | queries that filter/sort on multiple columns together |

### Leftmost-prefix rule

> A composite index on `(a, b, c)` can serve queries filtering on `a`,
> `(a, b)`, or `(a, b, c)` — but **not** on `b` or `c` alone. Order columns
> by: equality columns first, then the range/sort column.

### CREATE INDEX syntax variants

```sql
CREATE INDEX idx_emp_dept ON employees (dept_id);                       -- basic B-tree
CREATE INDEX idx_emp_dept_salary ON employees (dept_id, salary DESC);   -- composite
CREATE UNIQUE INDEX idx_emp_email ON employees (email);                 -- unique
CREATE INDEX idx_active_emp ON employees (dept_id) WHERE active = true; -- partial
CREATE INDEX idx_emp_lower_email ON employees (LOWER(email));           -- expression
CREATE INDEX idx_cover ON employees (dept_id) INCLUDE (name, salary);   -- covering
CREATE INDEX CONCURRENTLY idx_no_lock ON employees (dept_id);           -- [PostgreSQL] no write-lock
```

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Partial index | yes | no | via function-based index workaround | filtered index (`WHERE`) |
| Expression index | yes | 8.0+ (functional key parts) | function-based index | computed column + index |
| Covering index syntax | `INCLUDE (...)` | secondary index is auto-covering on InnoDB PK | `INCLUDE` not native | `INCLUDE (...)` |
| Online index build | `CREATE INDEX CONCURRENTLY` | `ALGORITHM=INPLACE` | `ONLINE` clause | `WITH (ONLINE = ON)` (Enterprise) |
| Default index type | B-tree | B-tree (InnoDB) | B-tree | B-tree |

---

## EXPLAIN

*(see Chapter 17)*

### EXPLAIN vs EXPLAIN ANALYZE

> `EXPLAIN` shows the planner's **estimated** plan and cost without running
> the query; `EXPLAIN ANALYZE` actually **executes** it and adds real
> timing/row counts — use `ANALYZE` with care on writes (wrap in a
> transaction and `ROLLBACK` for `INSERT/UPDATE/DELETE`).

### Reading a plan node

| Field | Meaning |
|---|---|
| `cost=0.00..12.50` | estimated (startup..total) cost in arbitrary planner units |
| `rows=100` | estimated rows this node will produce |
| `width=32` | estimated average row size in bytes |
| `actual time=0.010..0.045` | (ANALYZE only) real startup..total time in ms |
| `loops=1` | number of times this node executed (nested loop inner side reruns) |

### Common plan operators

| Operator | Meaning |
|---|---|
| Seq Scan | full table scan, reads every row |
| Index Scan | uses an index, then fetches matching heap rows |
| Bitmap Scan | builds a bitmap from an index, then batch-fetches heap pages |
| Nested Loop | for each outer row, scan/probe the inner side |
| Hash Join | build a hash table from one side, probe with the other |
| Merge Join | both inputs pre-sorted, merged in order |
| Sort | explicit sort step (watch for spills to disk) |
| Aggregate | plain aggregation (e.g. single `GROUP BY` group or scalar agg) |
| HashAggregate | aggregation via in-memory hash table, one bucket per group |

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Command | `EXPLAIN (ANALYZE, BUFFERS)` | `EXPLAIN ANALYZE` / `EXPLAIN FORMAT=JSON` | `EXPLAIN PLAN FOR` + `DBMS_XPLAN` | `SET STATISTICS XML/IO ON` or GUI "Actual Plan" |
| Visual plan tool | pgAdmin / `explain.depesz.com` | MySQL Workbench | SQL Developer | SSMS graphical plan |

---

## Performance Optimization

*(see Chapter 18)*

### Smell → fix quick reference

| Smell | Fix |
|---|---|
| `SELECT *` | select only needed columns (enables covering indexes, less I/O) |
| N+1 queries (one query per loop iteration) | batch into a single `JOIN`/`IN (...)` query |
| `OFFSET`-based pagination on large tables | keyset/seek pagination (`WHERE id > :last_id ORDER BY id LIMIT n`) |
| Missing index on filter/join/sort column | add targeted B-tree/composite index; check with `EXPLAIN` |
| Correlated subquery per row | rewrite as `JOIN` or window function |
| Unnecessary `ORDER BY` (no `LIMIT`, caller doesn't need order) | drop the sort or push down to consumer |
| Function on indexed column in `WHERE` (`WHERE UPPER(email)=...`) | expression index or store normalized column |
| Implicit type cast breaking index use | match literal type to column type |
| Wildcard prefix `LIKE '%x'` | full-text search / trigram index instead of B-tree |
| Large `IN (...)` list from app | temp table + `JOIN`, or array parameter |
| Fetching unbounded result sets | always paginate with `LIMIT` |
| `COUNT(*)` on huge table for existence check | `EXISTS` instead |
| Wide transactions holding locks | shorten transaction scope, batch writes |

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Query hints | discouraged (planner-driven); `pg_hint_plan` ext. | hints supported (`USE INDEX`) | hints supported (`/*+ ... */`) | hints supported (`OPTION`, `WITH (INDEX(...))`) |
| Stats refresh | `ANALYZE` / autovacuum | `ANALYZE TABLE` | `DBMS_STATS.GATHER_*` | `UPDATE STATISTICS` / auto |
| Query cache | none (removed concept) | removed in 8.0 | result cache (`RESULT_CACHE` hint) | plan cache (automatic) |

---

## Security

*(see Chapter 27)*

### GRANT / REVOKE skeleton

```sql
GRANT SELECT, INSERT, UPDATE ON employees TO app_user;
GRANT USAGE ON SCHEMA reporting TO analyst_role;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO analyst_role;
REVOKE INSERT, UPDATE ON employees FROM app_user;
```

### Role creation skeleton

```sql
CREATE ROLE analyst_role NOLOGIN;
CREATE ROLE app_user LOGIN PASSWORD 'strong_password' CONNECTION LIMIT 20;
GRANT analyst_role TO app_user;              -- role membership / inheritance
ALTER ROLE app_user SET statement_timeout = '5s';
```

### RLS policy skeleton [PostgreSQL]

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON orders
  FOR SELECT
  USING (tenant_id = current_setting('app.tenant_id')::INT);

CREATE POLICY tenant_write ON orders
  FOR INSERT
  WITH CHECK (tenant_id = current_setting('app.tenant_id')::INT);
```

### Least-privilege checklist

- [ ] App connects as a role with only the DML it needs — never as superuser/owner.
- [ ] Grant on specific tables/columns, not `ALL TABLES` blanket grants, unless truly needed.
- [ ] Separate roles for read-only reporting vs. read-write app traffic.
- [ ] Revoke `PUBLIC` default privileges on new schemas (`REVOKE ALL ON SCHEMA ... FROM PUBLIC`).
- [ ] Use RLS or view-based filtering for multi-tenant data instead of trusting app-layer filters alone.
- [ ] Parameterize all queries (prepared statements) — never string-concatenate SQL (injection).
- [ ] Rotate credentials, enforce password policy, and audit `GRANT`s periodically.

### Dialect differences

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Row-level security | native `CREATE POLICY` | not native (use views/app logic) | Virtual Private Database (`DBMS_RLS`) | `CREATE SECURITY POLICY` (filter predicates) |
| Roles vs. users | unified (roles can log in or not) | users + roles (8.0+) | users and roles distinct | logins (server) + users (DB) + roles |
| Column-level grants | `GRANT SELECT (col1, col2) ON t` | `GRANT SELECT (col1) ON t` | `GRANT SELECT (col1) ON t` | `GRANT SELECT ON t(col1)` |

---

*Cross-reference: full course [README](../README.md) · chapter source files in [`../chapters/`](../chapters/).*
