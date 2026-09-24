# Beginner Interview Questions (Chapters 1–6)

This is the first of four tiers in the SQL Mastery interview bank (Beginner →
Intermediate → Advanced → Expert). It covers everything a candidate should be
able to answer confidently after finishing **Chapters 1–6**: database
foundations, SQL syntax, CRUD, sorting/pagination, built-in functions, and
aggregates/`GROUP BY`. No `JOIN`s, subqueries, or window functions are used
here on purpose — those belong to the Intermediate tier (Ch. 7+).

Every coding question is written and verified against the two canonical
databases from this course:

- **`company_db`** — `departments`, `employees`, `managers`, `salaries`,
  `attendance`, `projects`, `employee_projects`
- **`ecommerce_db`** — `users`, `categories`, `products`, `inventory`,
  `orders`, `order_items`, `payments`, `reviews`

All query results shown are the *actual* rows returned when the query is run
against the seed data shipped in `databases/company_db.sql` and
`databases/ecommerce_db.sql`. Primary dialect is **[PostgreSQL]**; dialect
notes are called out wherever a beginner is likely to hit a real syntax
difference (e.g., `LIMIT` vs `TOP`, string concatenation).

Each question follows the same six-part structure: **Answer**, **Why it
works**, **Alternative approaches**, **Performance considerations**, and
**Common mistakes**.

---

## A. Foundations & Concepts (Chapter 1)

The mental model questions — what a database actually is, what keys and
relationships mean, and how `company_db`/`ecommerce_db` embody those ideas.
These rarely require writing SQL, but they're asked in nearly every SQL
interview to filter out candidates who memorized syntax without understanding
the underlying model.

### Q1. What is the difference between data, a database, a DBMS, and an RDBMS?

**Answer:**
- **Data** is raw facts (e.g., `'Aditi'`, `45999.00`, `2024-01-05`) with no
  structure or meaning attached.
- A **database** is an organized, persistent collection of related data —
  e.g., `company_db` is a database holding employees, departments, salaries.
- A **DBMS** (Database Management System) is the software that creates,
  manages, secures, and lets you query databases (PostgreSQL, MySQL, Oracle,
  SQL Server are all DBMS products).
- An **RDBMS** (Relational DBMS) is a DBMS that specifically stores data in
  tables (relations) made of rows and columns, and enforces relationships
  between them via keys — PostgreSQL, MySQL, Oracle are RDBMSs; MongoDB is a
  DBMS but not an RDBMS.

**Why it works:**
Each term is a narrower subset of the one before it: data ⊂ organized into a
database ⊂ managed by a DBMS ⊂ (if relational) an RDBMS. `company_db` is a
concrete example — it's a *database* (schema + rows), managed by *PostgreSQL*
(the DBMS), which is relational (an *RDBMS*) because `employees` and
`departments` are separate tables linked by `department_id` rather than one
giant nested document.

**Alternative approaches:**
Some candidates draw the distinction via "can it enforce a foreign key?" —
if yes, it's relational. That's a useful practical test but is really a
consequence of the definition, not the definition itself.

**Performance considerations:**
None — this is a definitional question.

> **Common mistakes:**
> - Using "database" and "DBMS" interchangeably (e.g., saying "I use MySQL
>   database" when MySQL is the DBMS, not the database).
> - Assuming all DBMSs are relational (NoSQL stores like Redis or MongoDB are
>   DBMSs, not RDBMSs).

---

### Q2. What is a primary key, and what makes it different from a unique key?

**Answer:**
A **primary key** uniquely identifies each row in a table, cannot be `NULL`,
and a table can have only one. A **unique key** (a `UNIQUE` constraint) also
enforces uniqueness but *can* allow one `NULL` (in PostgreSQL), and a table
can have several unique keys. In `employees`, `employee_id` is the primary
key; `email` has a separate `UNIQUE` constraint — it's a unique key, not the
primary key, even though it also identifies a row unambiguously.

```sql
-- from company_db.sql
employee_id     SERIAL PRIMARY KEY,
...
email           VARCHAR(150) NOT NULL UNIQUE,
```

**Why it works:**
The primary key is the table's single canonical identity, used by foreign
keys elsewhere (e.g., `salaries.employee_id REFERENCES employees(employee_id)`).
A unique key just guarantees "no two rows share this value" without being the
table's canonical identity.

**Alternative approaches:**
A table could use `email` as its primary key instead of a surrogate
`employee_id` — this is a **natural key** approach. It's avoided here because
emails can change, and a numeric surrogate key is smaller/faster to index and
join on.

**Performance considerations:**
PostgreSQL automatically creates a unique B-tree index for both a primary key
and any `UNIQUE` constraint, so lookups by either `employee_id` or `email` are
equally fast. Extra unique indexes do add small overhead to `INSERT`/`UPDATE`.

> **Common mistakes:**
> - Saying a table can have "multiple primary keys" (it can have one primary
>   key that is *composite* — multiple columns — but only one primary key).
> - Forgetting that `UNIQUE` columns can accept `NULL` (and in PostgreSQL,
>   multiple `NULL`s, since `NULL <> NULL`), while a primary key column
>   never can.

---

### Q3. What is a foreign key, and what does `ON DELETE SET NULL` do?

**Answer:**
A foreign key is a column (or set of columns) in one table that references
the primary key of another table, enforcing that any non-`NULL` value in it
must already exist in the referenced table. In `company_db`:

```sql
department_id INT REFERENCES departments(department_id) ON DELETE SET NULL,
```

This means `employees.department_id` must match an existing
`departments.department_id`, and if that department row is deleted, every
employee that pointed to it has `department_id` automatically set to `NULL`
instead of the delete being blocked or the employees being deleted too.

**Why it works:**
The foreign key gives PostgreSQL a rule to enforce **referential integrity**
— you can never have an employee pointing at a department that doesn't
exist. The `ON DELETE SET NULL` action tells the engine what to do to the
*child* rows when the *parent* row disappears; without specifying an action,
the default is `ON DELETE NO ACTION`, which raises an error if any child
rows still reference the parent.

**Alternative approaches:**
`ON DELETE CASCADE` (used on `salaries.employee_id` and `attendance.employee_id`
in this schema) deletes the child rows too instead of nulling them —
appropriate when the child data is meaningless without the parent (a salary
history row makes no sense once the employee record is gone). `ON DELETE
RESTRICT`/`NO ACTION` is safest when you never want an accidental delete to
cascade silently.

**Performance considerations:**
Foreign keys are checked on every `INSERT`/`UPDATE` to the referencing table
and on every `DELETE`/`UPDATE` to the referenced table's key — for large
tables, an unindexed foreign key column can make deletes on the parent table
slow because PostgreSQL has to scan the child table to check for references.
`employee_id` columns here are indexed implicitly by being primary/foreign
keys used in joins later, but it's worth explicitly indexing high-traffic FK
columns.

> **Common mistakes:**
> - Thinking `ON DELETE SET NULL` deletes the child row (it doesn't — it
>   nulls the FK column, leaving the row intact).
> - Forgetting the referenced column *must itself* be a primary key or have a
>   unique constraint — you cannot reference an arbitrary non-unique column.

---

### Q4. What is a composite primary key? Give an example from `company_db`.

**Answer:**
A composite primary key is a primary key made of two or more columns, where
the *combination* must be unique even if individual columns repeat. The
bridge table `employee_projects` uses one:

```sql
CREATE TABLE employee_projects (
    employee_id     INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    project_id      INT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    role            VARCHAR(100) NOT NULL,
    hours_allocated INT NOT NULL DEFAULT 0,
    PRIMARY KEY (employee_id, project_id)
);
```

Employee `2` (Rahul) appears twice in this table (on project 1 and project 2)
and project `1` appears with multiple employees — neither column alone is
unique, but the *pair* `(employee_id, project_id)` is, because one employee
can't be assigned to the same project twice.

**Why it works:**
The composite key models the natural real-world constraint of a many-to-many
relationship: "an employee can be on many projects, a project can have many
employees, but a given employee/project pairing should exist at most once."

**Alternative approaches:**
An alternative design adds a surrogate `employee_project_id SERIAL PRIMARY
KEY` column and instead enforces the same rule with `UNIQUE(employee_id,
project_id)`. That's often preferred when a third table will need to
reference *this specific assignment row* (foreign keys pointing at a
composite key are more awkward to write).

**Performance considerations:**
A composite primary key on `(employee_id, project_id)` builds one composite
index good for lookups filtered by `employee_id` first, but not efficient for
"find all rows for this `project_id`" alone — that would need a separate
index on `project_id`.

> **Common mistakes:**
> - Assuming each column of a composite key must be unique on its own (only
>   the combination has to be).
> - Forgetting to also index the second column separately when queries
>   frequently filter on it alone.

---

### Q5. Explain one-to-many and many-to-many relationships using `company_db` and `ecommerce_db`.

**Answer:**
- **One-to-many (1:N):** one `departments` row relates to many `employees`
  rows (`employees.department_id` FK) — a department has many employees, but
  each employee belongs to (at most) one department.
- **Many-to-many (M:N):** `employees` and `projects` — one employee can work
  on many projects, and one project has many employees. This needs a bridge
  (junction) table, `employee_projects`, because neither table can hold a
  foreign key that stores "many" values directly.

In `ecommerce_db`, `orders` and `products` are similarly M:N, resolved by the
`order_items` bridge table.

**Why it works:**
A plain foreign key column can only store a single value, so it can naturally
express "many rows point to one row" (1:N) but not "many rows point to many
rows" (M:N) — that requires an intermediate table holding one row per valid
pairing, each with its own foreign keys back to both sides.

**Alternative approaches:**
1:1 relationships (like `managers`, one row per department identifying its
managing employee) are modeled by putting a `UNIQUE` foreign key on one side
— `managers.department_id` is both `NOT NULL` and `UNIQUE`, guaranteeing at
most one manager row per department.

**Performance considerations:**
Bridge tables like `employee_projects` and `order_items` are usually the
highest-row-count tables in an OLTP schema (every pairing is its own row),
so their foreign key columns are prime indexing targets once you start
joining (Chapter 7).

> **Common mistakes:**
> - Trying to model M:N by putting a comma-separated list of IDs in a single
>   column (breaks normalization, foreign keys, and indexing).
> - Confusing "one department has one manager" (1:1, via the `managers`
>   table) with "one department has many employees" (1:N, via
>   `employees.department_id`) — they look similar but are different
>   cardinalities on purpose in this schema.

---

### Q6. What is `NULL`, and how is it different from `0` or an empty string `''`?

**Answer:**
`NULL` represents the *absence* of a value — "unknown" or "not applicable" —
not zero, not an empty string, and not false. In `employees`, `manager_id` is
`NULL` for employee `1` (Aditi, the CTO) because she genuinely has no
manager — it isn't that her manager's ID is `0` or blank, there simply is no
value.

**Why it works:**
SQL uses **three-valued logic**: any comparison involving `NULL` (`=`, `<>`,
`<`, `>`) evaluates to `UNKNOWN`, not `TRUE` or `FALSE`, and rows where a
`WHERE` condition evaluates to `UNKNOWN` are excluded from the result — which
is why `WHERE manager_id = NULL` never matches anything (see Q23).

**Alternative approaches:**
Some schemas use a sentinel value (e.g., `manager_id = 0` meaning "no
manager") instead of `NULL` to avoid three-valued-logic surprises, but this
requires a fake row `0` to exist for the foreign key to be valid and is
generally considered worse practice than using `NULL` correctly.

**Performance considerations:**
`NULL`s are cheap to store (a bitmap flag internally in PostgreSQL) but
`IS NULL` checks cannot use a plain B-tree index range scan as efficiently as
equality on a real value in some plans — partial indexes (`WHERE col IS NOT
NULL`) are a Ch. 16 technique for this.

> **Common mistakes:**
> - Treating `NULL`, `0`, and `''` as equivalent "empty" markers.
> - Writing `column = NULL` or `column != NULL` instead of `IS NULL` /
>   `IS NOT NULL`.

---

### Q7. Why does `company_db` store salaries in a separate `salaries` table instead of adding a `salary` column to `employees`?

**Answer:**
Because an employee's salary changes over time, and `employees` should only
describe the employee, not their entire compensation history. `salaries` has
its own primary key and a `UNIQUE(employee_id, effective_date)` constraint,
so it can hold multiple rows per employee — e.g., employee `1` (Aditi) has
two rows: `450000` effective `2015-03-01` and `520000` effective
`2020-01-01`. A single `salary` column on `employees` could only ever hold
the *current* value and would lose all history.

**Why it works:**
This is a basic application of **normalization**: each fact should be stored
once, in the table that matches its true "grain" (one row per
employee-per-effective-date, not one row per employee). Mixing repeating,
time-varying facts into a fixed one-row-per-entity table causes either data
loss (only the latest value survives) or awkward multi-column hacks
(`salary_2020`, `salary_2021`, …).

**Alternative approaches:**
A denormalized approach — keeping `current_salary` directly on `employees`
for fast reads, *in addition to* the full history table — is a legitimate
performance trade-off used in reporting/read-heavy systems, at the cost of
needing to keep the two in sync (usually via a trigger, Ch. 22).

**Performance considerations:**
Splitting salary history out keeps `employees` narrow and fast to scan for
non-salary queries, at the cost of needing a query (with `ORDER BY
effective_date DESC LIMIT 1`, or a window function later) to get "current"
salary rather than a plain column read.

> **Common mistakes:**
> - Assuming `SELECT base_salary FROM salaries WHERE employee_id = 3` always
>   returns one row — for employees with a raise, it returns the *entire*
>   history unless filtered/sorted.
> - Adding new columns per year/period instead of new rows (a normalization
>   anti-pattern).

---

### Q8. What's the difference between a candidate key, a natural key, and a surrogate key?

**Answer:**
- A **candidate key** is any column (or column set) that *could* uniquely
  identify a row — a table can have several. In `employees`, both
  `employee_id` and `email` are candidate keys.
- The **natural key** is a candidate key made of real-world, business-meaningful
  data — `email` is a natural key here.
- The **surrogate key** is an artificial, system-generated identifier with no
  business meaning — `employee_id` (a `SERIAL`) is the surrogate key, chosen
  as the *primary* key.

**Why it works:**
Of all candidate keys, the schema designer picks one as the primary key.
`company_db` picks the surrogate (`employee_id`) over the natural key
(`email`) because surrogate keys are smaller, never need to change, and don't
leak business data (an email) into every foreign key reference across the
schema.

**Alternative approaches:**
Some schemas do use natural keys as primary keys when the natural key is
truly immutable and simple — e.g., a `country_code CHAR(2)` primary key on a
small reference table of countries. `company_db`'s own `departments` table
uses a surrogate `department_id` even though `department_name` is `UNIQUE`
and could have served as a natural key.

**Performance considerations:**
Integer surrogate keys are narrower and faster to index/join than a
`VARCHAR(150)` natural key like `email`, and they don't need to be updated
everywhere if the natural value changes (e.g., an employee changing their
email would be a nightmare to propagate if `email` were the primary key
referenced by other tables).

> **Common mistakes:**
> - Believing a "natural key" and a "primary key" are always the same thing.
> - Choosing a natural key that later turns out to be mutable (people's
>   names, emails, even government IDs in some countries have been reissued)
>   — a classic real-world modeling bug.

---

### Q9. What is referential integrity, and how does `company_db` enforce it?

**Answer:**
Referential integrity is the guarantee that relationships between tables
always point to something that actually exists — no "orphan" foreign key
values. `company_db` enforces it via the `REFERENCES` clauses on
`employees.department_id`, `employees.manager_id`, `salaries.employee_id`,
`attendance.employee_id`, `projects.department_id`, and both columns of
`employee_projects` — PostgreSQL rejects any `INSERT`/`UPDATE` that would
create a foreign key value with no matching row in the parent table.

**Why it works:**
Every `REFERENCES` clause creates a constraint the query planner checks on
write. Attempting, say, `INSERT INTO employees (..., department_id, ...)
VALUES (..., 99, ...)` fails immediately because department `99` doesn't
exist in `departments` — the database refuses to let the data become
inconsistent, rather than relying on application code to remember to check.

**Alternative approaches:**
Referential integrity can be enforced in the application layer instead
(check the parent exists before inserting the child), but this is fragile —
any other process or script touching the database directly (or a bug in one
code path) can silently create orphans. Database-level constraints protect
data integrity regardless of which application or script writes to it.

**Performance considerations:**
Enforcing FK constraints costs a lookup against the parent table's index on
every write to the child table — cheap when the parent key is indexed
(always true for a primary key), but it is real overhead that bulk-loading
tools sometimes temporarily disable and re-validate afterward for speed.

> **Common mistakes:**
> - Disabling foreign key constraints "to make inserts faster" during normal
>   application operation (not just bulk loads) and never re-enabling them.
> - Assuming referential integrity also guarantees *business* correctness —
>   it only guarantees the referenced row exists, not that the relationship
>   makes logical sense (e.g., it won't stop an employee from managing
>   themselves unless you add an explicit check for that).

---

## B. SQL Syntax Basics (Chapter 2)

Baseline mechanics of the language itself: sublanguages, identifiers, data
types, comments, and how a query is actually structured before we get into
writing real `SELECT`s.

### Q10. What are DDL, DML, DCL, and TCL? Classify `CREATE TABLE`, `INSERT`, `GRANT`, and `COMMIT`.

**Answer:**
- **DDL** (Data Definition Language) — defines/alters structure:
  `CREATE`, `ALTER`, `DROP`, `TRUNCATE`.
- **DML** (Data Manipulation Language) — manipulates rows: `SELECT`,
  `INSERT`, `UPDATE`, `DELETE`.
- **DCL** (Data Control Language) — manages permissions: `GRANT`, `REVOKE`.
- **TCL** (Transaction Control Language) — manages transactions: `COMMIT`,
  `ROLLBACK`, `SAVEPOINT`.

So: `CREATE TABLE` → DDL, `INSERT` → DML, `GRANT` → DCL, `COMMIT` → TCL.

**Why it works:**
This grouping reflects *what kind of change* a statement makes: schema
shape (DDL), the data within that shape (DML), who's allowed to act on it
(DCL), or how a group of statements is committed atomically (TCL). It's the
standard taxonomy used across virtually every relational database.

**Alternative approaches:**
Some textbooks separate `SELECT` into its own category, **DQL** (Data Query
Language), since it reads but never modifies data — both classifications are
accepted in interviews; just be consistent about which one you use.

**Performance considerations:**
DDL statements like `CREATE TABLE`/`ALTER TABLE` in PostgreSQL take an
exclusive lock on the table (Ch. 12), which is why they're normally run in
low-traffic windows, unlike routine DML.

> **Common mistakes:**
> - Classifying `TRUNCATE` as DML because "it deletes rows" — it's DDL-like
>   in PostgreSQL (it deallocates the underlying storage pages) and cannot be
>   rolled back the same way `DELETE` can in some databases.
> - Forgetting `COMMIT`/`ROLLBACK` exist as their own category (TCL) and
>   lumping them into DML.

---

### Q11. Are SQL keywords and identifiers case-sensitive in PostgreSQL?

**Answer:**
Keywords (`SELECT`, `FROM`, `WHERE`) are never case-sensitive. Unquoted
identifiers (table/column names) are automatically **folded to lowercase**
by PostgreSQL, so `SELECT * FROM Employees` and `select * from employees` are
identical and both work against `company_db`'s `employees` table. If you
*quote* an identifier with double quotes, e.g. `"Employees"`, PostgreSQL
treats it as case-sensitive and literally looks for a table named
`Employees` (which doesn't exist here, since the table was created as
lowercase `employees`).

```sql
SELECT * FROM employees;      -- works
SELECT * FROM EMPLOYEES;      -- works (folded to lowercase)
SELECT * FROM "Employees";    -- ERROR: relation "Employees" does not exist
```

**Why it works:**
The SQL standard says unquoted identifiers should be case-*insensitive*, and
PostgreSQL implements that by lowercasing them at parse time before matching
against the catalog, where `employees` was stored in lowercase because it
was created without quotes.

**Alternative approaches:**
Some teams standardize on quoting *and* consistently using `CamelCase` table
names (`"Employees"`) to preserve case — this works but forces every future
query to also use double quotes, which is why most PostgreSQL style guides
recommend sticking to unquoted, lowercase, snake_case identifiers (as this
course's schemas do).

**Performance considerations:**
None — this is purely a naming/parsing rule with no runtime cost.

> **Common mistakes:**
> - Assuming MySQL's case-sensitivity rules (which vary by OS/filesystem)
>   apply identically in PostgreSQL.
> - Copy-pasting a `CREATE TABLE "Users" (...)` from another tool and then
>   being confused why `SELECT * FROM users` fails.

---

### Q12. What's the difference between `--` and `/* */` comments, and does every statement need a semicolon?

**Answer:**
`--` starts a single-line comment (everything after it on that line is
ignored); `/* ... */` is a multi-line block comment. A semicolon `;`
terminates a statement — required when running multiple statements in one
script or `psql` session (as `databases/company_db.sql` does, statement after
statement), but often optional for a single statement typed interactively in
a client.

```sql
-- get all active engineers
SELECT * FROM employees
WHERE status = 'ACTIVE';   /* filters out TERMINATED and ON_LEAVE rows */
```

**Why it works:**
The semicolon tells the SQL parser "this statement is complete, execute it
before reading further" — critical when a script contains many statements
back to back, exactly like the seed files in `databases/`.

**Alternative approaches:**
Some dialects (T-SQL with `GO` batches) use a different statement-separator
convention entirely — a dialect nuance worth knowing if you move between
SQL Server and PostgreSQL.

**Performance considerations:**
None — purely syntactic.

> **Common mistakes:**
> - Nesting `/* */` comments (not supported the way you'd expect in most
>   dialects — PostgreSQL does support nested block comments, but many other
>   engines don't, so avoid relying on it for portability).
> - Forgetting the semicolon between two statements pasted into a single
>   `psql` execution, causing them to be parsed as one malformed statement.

---

### Q13. What's the practical difference between `CHAR(n)`, `VARCHAR(n)`, and `TEXT`?

**Answer:**
- `CHAR(n)` — fixed-length, blank-padded to exactly `n` characters.
  `salaries.currency CHAR(3)` always stores exactly 3 characters (`'USD'`).
- `VARCHAR(n)` — variable-length with a maximum of `n` characters, e.g.
  `employees.first_name VARCHAR(50)`.
- `TEXT` — variable-length with no length limit at all.

**Why it works:**
In PostgreSQL, all three are stored using the same underlying variable-length
text representation — `CHAR(n)` is the only one with a real behavioral
difference (it pads with trailing spaces to reach length `n`), and in
practice PostgreSQL's `VARCHAR(n)` and `TEXT` have **identical performance**;
`VARCHAR(n)` just adds a length check on write.

**Alternative approaches:**
Because PostgreSQL doesn't penalize `TEXT` performance-wise, some schema
designers use `TEXT` everywhere and rely on a `CHECK (length(col) <= n)`
constraint instead of `VARCHAR(n)` if they want length enforcement decoupled
from the column's declared type (easier to change without an `ALTER
COLUMN`-style rewrite in some cases). This schema uses `VARCHAR(n)` for
column-level self-documentation of intended length.

**Performance considerations:**
`CHAR(n)` wastes storage and, more importantly, comparison surprises (trailing
spaces) make it a poor fit for anything joined/compared frequently — hence
this schema reserves it only for genuinely fixed-width codes like currency.
`VARCHAR(n)` vs `TEXT` has no meaningful performance difference in
PostgreSQL, unlike some other RDBMSs.

> **Common mistakes:**
> - Assuming `VARCHAR` is always faster than `TEXT` in PostgreSQL (a
>   MySQL/SQL Server habit that doesn't transfer).
> - Forgetting `CHAR(3)` pads short values with spaces, which can break an
>   `=` comparison against a value built elsewhere without the padding in
>   some client drivers.

---

### Q14. What is the difference between a database and a schema? What does `SET search_path` do?

**Answer:**
A **database** is the top-level container in PostgreSQL (you connect to one
specific database at a time). A **schema** is a namespace *within* a
database that groups related tables. This course's setup script creates
`company_db` and `ecommerce_db` as **schemas**, not separate databases:

```sql
CREATE SCHEMA company_db;
SET search_path TO company_db;
```

`SET search_path` tells PostgreSQL which schema(s) to look in, in order,
when a query references a table without a schema prefix — after that
`SET`, `SELECT * FROM employees` resolves to `company_db.employees` without
needing to type the schema name every time.

**Why it works:**
Table name resolution in PostgreSQL walks the `search_path` schema list in
order and uses the first matching table found — this lets two schemas each
have their own `employees`-style table without colliding, as long as you're
careful about which schema is active.

**Alternative approaches:**
You can always fully qualify a table name (`company_db.employees`) instead
of relying on `search_path`, which is more explicit and safer in scripts
that touch multiple schemas, at the cost of more typing.

**Performance considerations:**
None directly, but an unexpected `search_path` can silently make a query hit
the *wrong* table of the same name in a different schema — a correctness
risk more than a performance one.

> **Common mistakes:**
> - Confusing "schema" (a namespace inside one database) with "database" (a
>   separate connection target) — a very common point of confusion for
>   people coming from MySQL, where "database" and "schema" are synonyms.
> - Forgetting to `SET search_path` (or fully qualify) and getting a
>   "relation does not exist" error even though the table clearly exists in
>   some schema.

---

### Q15. What does `SELECT *` do, and why is it discouraged in production code?

**Answer:**
`SELECT *` returns every column of a table, in whatever order they're
defined. E.g., `SELECT * FROM departments;` returns all four columns
(`department_id, department_name, location, created_at`) for all 5 rows. It's
fine for ad hoc exploration but discouraged in application code and views
because it's fragile and often wasteful.

**Why it works:**
The parser expands `*` to the full column list of the table (or all tables
in a join) at execution/plan time — which is exactly the problem: that
expansion isn't fixed at write-time, so it silently changes if the table's
structure changes later.

**Alternative approaches:**
Always list only the columns you need:
```sql
SELECT department_name, location FROM departments;
```
This is self-documenting, resilient to future `ALTER TABLE ADD COLUMN`
changes, and avoids pulling large/irrelevant columns (like a `TEXT`
`review_text` in `reviews`) across the network when you don't need them.

**Performance considerations:**
`SELECT *` can defeat **covering index** optimizations (Ch. 16) — a query
that only needs 2 of 8 columns might be answerable entirely from an index
without touching the table, but only if you actually name those 2 columns.
It also increases network I/O and application memory unnecessarily, and
silently breaks client code that expects a specific column order/count if
the table schema changes.

> **Common mistakes:**
> - Using `SELECT *` inside a view or application query that's expected to
>   remain stable — a later `ALTER TABLE ADD COLUMN` changes its output
>   unexpectedly.
> - Assuming `SELECT *` is "simpler" and therefore faster — it's often
>   slower due to unnecessary data transfer.

---

### Q16. What is the *logical order of execution* of a `SELECT` statement, and how is it different from the order you type the clauses?

**Answer:**
You *write* a query as `SELECT … FROM … WHERE … GROUP BY … HAVING … ORDER BY
… LIMIT …`, but the database *conceptually* processes clauses in this order:

```
1. FROM        (identify source tables)
2. WHERE       (filter individual rows)
3. GROUP BY    (form groups)
4. HAVING      (filter groups)
5. SELECT      (compute the output columns/expressions)
6. ORDER BY    (sort the result)
7. LIMIT/OFFSET (trim the result)
```

**Why it works:**
This explains several beginner "surprises" at once: you can't reference a
`SELECT`-list alias in `WHERE` (because `WHERE` runs before `SELECT` is
evaluated), but you *can* usually reference one in `ORDER BY` (because
`ORDER BY` runs after `SELECT`). It also explains why `WHERE` can't filter on
an aggregate (aggregates aren't computed yet at that stage) while `HAVING`
can.

**Alternative approaches:**
Not applicable — this is how the standard defines query semantics; a
specific optimizer (the query planner, Ch. 17) is still free to *physically*
execute steps in a different order or combine them, as long as the result is
identical to this logical order.

**Performance considerations:**
Understanding this order is what tells you to filter as early as possible —
a `WHERE` clause that removes 99% of rows *before* an expensive `GROUP BY` is
far cheaper than grouping everything and filtering afterward with `HAVING`
(see Q54).

> **Common mistakes:**
> - Trying to use a `SELECT`-list alias inside the same query's `WHERE`
>   clause and getting a "column does not exist" error.
> - Putting a row-level filter in `HAVING` instead of `WHERE` "because it
>   comes after `GROUP BY` in my head" — this works but is needlessly slow
>   (see Q54).

---

## C. SELECT & WHERE (Chapter 3 — reading data)

Filtering, comparison, and pattern-matching are the daily bread of SQL. This
section mixes definitional questions with hands-on `WHERE`-clause problems
against real rows.

### Q17. Write a query to list all distinct job titles in `employees`. How many are there?

**Answer:** **[PostgreSQL]**
```sql
SELECT DISTINCT job_title
FROM employees
ORDER BY job_title;
```
Result — **13 distinct titles** (out of 16 employees):
```
 Accountant
 CTO
 Engineering Manager
 Finance Manager
 HR Executive
 HR Manager
 Junior Engineer
 Marketing Executive
 Marketing Manager
 Sales Executive
 Sales Manager
 Senior Engineer
 Software Engineer
```

**Why it works:**
`DISTINCT` removes duplicate rows from the result set *after* the column
list is projected — since three employees (`Vikram`, `Ananya`, `Aman`) all
share the title `'Software Engineer'`, that value collapses to a single
output row instead of three.

**Alternative approaches:**
`SELECT job_title, COUNT(*) FROM employees GROUP BY job_title;` achieves the
same de-duplication *and* tells you how many employees hold each title —
strictly more informative when you actually care about the counts, not just
the distinct list (see Q52 for `COUNT(DISTINCT …)`).

**Performance considerations:**
`DISTINCT` requires either a sort or a hash-based de-duplication pass over
the entire result before returning it — on a small 16-row table this is free,
but on a large table without a supporting index, it's an extra full pass
that `GROUP BY` (with the same underlying execution strategy) doesn't avoid
either.

> **Common mistakes:**
> - Writing `SELECT DISTINCT job_title, employee_id` expecting duplicate
>   *titles* to collapse — `DISTINCT` applies to the whole row of selected
>   columns, so adding a unique column like `employee_id` defeats the
>   de-duplication entirely.

---

### Q18. Write a query to list all ACTIVE employees in the Engineering department, ordered by hire date.

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, first_name, last_name, hire_date, job_title
FROM employees
WHERE department_id = 1
  AND status = 'ACTIVE'
ORDER BY hire_date ASC;
```
Result (6 rows):
```
 employee_id | first_name | last_name |  hire_date | job_title
-------------+------------+-----------+------------+---------------------
           1 | Aditi      | Rao       | 2015-03-01 | CTO
           2 | Rahul      | Mehta     | 2016-05-12 | Engineering Manager
           3 | Sneha      | Kulkarni  | 2017-01-20 | Senior Engineer
           4 | Vikram     | Joshi     | 2018-07-15 | Software Engineer
           6 | Karan      | Verma     | 2020-02-10 | Junior Engineer
          16 | Aman       | Chawla    | 2022-01-10 | Software Engineer
```
(Employee 5, Ananya, is excluded — she's `department_id = 1` but
`status = 'ON_LEAVE'`, not `'ACTIVE'`.)

**Why it works:**
Both conditions are joined with `AND`, so a row must satisfy *both* to be
included — `department_id = 1` narrows to Engineering, `status = 'ACTIVE'`
then excludes Ananya (`ON_LEAVE`). `ORDER BY hire_date ASC` sorts oldest
hires first, which is why the CTO (2015) appears first.

**Alternative approaches:**
`WHERE department_id = 1 AND status <> 'ON_LEAVE' AND status <> 'TERMINATED'`
would give the same result here but is more fragile — it depends on knowing
every non-active status rather than checking for the one you want.

**Performance considerations:**
With a composite index on `(department_id, status)`, this query could be
answered with a single index range scan instead of a full table scan — worth
knowing conceptually now, even though indexing itself is a Ch. 16 topic.

> **Common mistakes:**
> - Using `OR` instead of `AND` (`WHERE department_id = 1 OR status =
>   'ACTIVE'`) — this returns *every* Engineering employee regardless of
>   status, *plus* every active employee in every other department, which is
>   a much larger and wrong result set.
> - Forgetting `ORDER BY` and assuming rows come back in hire-date order by
>   default (row order without `ORDER BY` is never guaranteed).

---

### Q19. Write a query to find products priced between ₹1,000 and ₹50,000, most expensive first.

**Answer:** **[PostgreSQL]**
```sql
SELECT product_name, price
FROM products
WHERE price BETWEEN 1000 AND 50000
ORDER BY price DESC;
```
Result (7 rows):
```
   product_name    |  price
--------------------+----------
 Galaxy Phone X     | 45999.00
 Pixel Lite         | 29999.00
 Wireless Earbuds   |  3499.00
 Non-stick Pan Set  |  2499.00
 Women Kurta Set    |  1799.00
 Electric Kettle    |  1499.00
 Men Cotton Shirt   |  1299.00
```
(`UltraBook Pro 14` at 89999 and `GameBook 15` at 74999 are excluded — over
the upper bound; `Laptop Sleeve 14"` at 799 is excluded — under the lower
bound.)

**Why it works:**
`BETWEEN 1000 AND 50000` is inclusive on both ends, equivalent to
`price >= 1000 AND price <= 1000000`... i.e. `price >= 1000 AND price <=
50000`. Since both boundary products (none priced at exactly 1000 or 50000
here) don't exist, the visible effect is just a normal inclusive range
filter.

**Alternative approaches:**
```sql
WHERE price >= 1000 AND price <= 50000
```
is functionally identical and arguably clearer about inclusivity to a reader
unfamiliar with `BETWEEN`'s inclusive convention; `BETWEEN` is simply more
concise for a straightforward closed range.

**Performance considerations:**
Both forms produce the same query plan in PostgreSQL — the planner
recognizes `BETWEEN` as sugar for the two-sided range comparison, so there's
no performance difference; a supporting index on `price` would allow an
efficient index range scan either way.

> **Common mistakes:**
> - Assuming `BETWEEN` is exclusive on the bounds (it's inclusive — a common
>   source of off-by-one bugs, especially with dates, e.g. `BETWEEN
>   '2024-01-01' AND '2024-01-31'` silently excludes any time-of-day after
>   midnight on the 31st if the column is a `TIMESTAMP` rather than `DATE`).
> - Writing the bounds in the wrong order (`BETWEEN 50000 AND 1000`), which
>   returns zero rows in PostgreSQL rather than automatically reversing them.

---

### Q20. Write a query to find employees in the Sales or Finance departments using `IN`. Why prefer `IN` over chained `OR`?

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, first_name, last_name, department_id
FROM employees
WHERE department_id IN (2, 4)
ORDER BY department_id, employee_id;
```
Result (5 rows):
```
 employee_id | first_name | last_name | department_id
-------------+------------+-----------+---------------
           7 | Priya      | Nair      |             2
           8 | Arjun      | Das       |             2
           9 | Meera      | Pillai    |             2
          12 | Nikhil     | Gupta     |             4
          13 | Divya      | Shah      |             4
```

**Why it works:**
`IN (2, 4)` is logically equivalent to `department_id = 2 OR department_id =
4` but reads better and scales cleanly as the list grows — `IN (2, 4, 5, 9,
11)` stays just as readable, while the equivalent `OR` chain becomes
unwieldy and error-prone (easy to accidentally type `AND` instead of `OR`
somewhere in a long chain).

**Alternative approaches:**
```sql
WHERE department_id = 2 OR department_id = 4
```
produces an identical result and an identical query plan in PostgreSQL — the
planner treats `IN` on a literal list as a rewrite to `OR`-equality
internally, so this is purely a readability/maintainability choice, not a
performance one, for a short literal list.

**Performance considerations:**
For a *large* literal list, `IN` is still just as fast as the equivalent
`OR` chain (both use the same plan). Where `IN` performance genuinely
differs is when the list comes from a **subquery** (`IN (SELECT …)`,
Chapter 8) rather than literals — that's a materially different execution
path.

> **Common mistakes:**
> - Writing `WHERE department_id = 2 AND department_id = 4`, expecting both
>   departments — no row can simultaneously equal both 2 *and* 4, so this
>   always returns zero rows (a very common logic slip, see Q24).
> - Forgetting `IN` works with `NOT IN` too, but `NOT IN (SELECT …)` has a
>   dangerous `NULL` pitfall covered in the Intermediate tier.

---

### Q21. Write a query to find all employees whose job title contains "Engineer". What's a hidden trap here?

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, first_name, last_name, job_title
FROM employees
WHERE job_title LIKE '%Engineer%'
ORDER BY employee_id;
```
Result (6 rows) — note **Rahul Mehta**, an "Engineering **Manager**", is
included even though his title isn't literally "Engineer":
```
 employee_id | first_name | last_name |      job_title
-------------+------------+-----------+---------------------
           2 | Rahul      | Mehta     | Engineering Manager
           3 | Sneha      | Kulkarni  | Senior Engineer
           4 | Vikram     | Joshi     | Software Engineer
           5 | Ananya     | Singh     | Software Engineer
           6 | Karan      | Verma     | Junior Engineer
          16 | Aman       | Chawla    | Software Engineer
```

**Why it works:**
`%` matches any sequence of zero or more characters, so `'%Engineer%'`
matches any title that *contains* the substring `"Engineer"` anywhere —
`"Engineer**ing**"` contains that substring, which is exactly why it's
caught here even though semantically an "Engineering Manager" is a
management role, not an individual-contributor engineering role. This is the
"hidden trap": naive substring matching over-matches on shared word stems.

**Alternative approaches:**
`WHERE job_title = ANY (ARRAY['Senior Engineer','Software Engineer','Junior
Engineer'])` (or the equivalent `IN (...)`) would exactly match only the
intended titles without the substring collision, at the cost of needing to
enumerate every exact title and maintain that list as titles are added.
`~* '\yEngineer\y'` (regex word-boundary match, PostgreSQL-specific `~*`
case-insensitive regex operator) is a more surgical fix for the substring
problem itself.

**Performance considerations:**
A leading-wildcard pattern like `'%Engineer%'` cannot use a standard B-tree
index efficiently (the wildcard at the *start* prevents an index range scan)
— PostgreSQL falls back to a full scan unless a `pg_trgm` trigram index
exists (Ch. 16), which matters once `employees` has millions of rows instead
of 16.

> **Common mistakes:**
> - Not realizing `LIKE '%X%'` matches `X` as a substring of a *larger* word,
>   not just as a whole word — leading to over-inclusive results exactly
>   like `"Engineering Manager"` above.
> - Forgetting `LIKE` is case-sensitive in PostgreSQL by default (`ILIKE` or
>   `LOWER(job_title) LIKE LOWER('%pattern%')` is needed for
>   case-insensitive matching).

---

### Q22. Write a query to find employees with no manager. Why must you use `IS NULL` instead of `= NULL`?

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, first_name, last_name, job_title
FROM employees
WHERE manager_id IS NULL;
```
Result (1 row):
```
 employee_id | first_name | last_name | job_title
-------------+------------+-----------+-----------
           1 | Aditi      | Rao       | CTO
```
Only Aditi (the CTO) has no manager — every other employee's `manager_id`
points to a real employee row.

**Why it works:**
`manager_id = NULL` would evaluate to `UNKNOWN` for *every* row (comparing
anything to `NULL` with `=` is always `UNKNOWN`, never `TRUE`), and rows
where the `WHERE` predicate is `UNKNOWN` are excluded — so `= NULL` returns
**zero rows**, always, regardless of the data. `IS NULL` is a special
predicate designed specifically to test for the absence of a value, and it
does return `TRUE` for `NULL` values.

**Alternative approaches:**
`COALESCE(manager_id, -1) = -1` is a hacky workaround that technically works
but is far less readable and risks colliding with a real value of `-1` —
always prefer `IS NULL` directly. `manager_id IS DISTINCT FROM 1` is the
`NULL`-safe alternative to `<>` when you need it, relevant once inequality
comparisons involving possibly-`NULL` columns come up.

**Performance considerations:**
`IS NULL` can be served by a **partial index** (`CREATE INDEX ... WHERE
manager_id IS NULL`, Ch. 16) far more efficiently than a full scan when only
a tiny fraction of rows are `NULL`, which is exactly the shape of this data
(1 out of 16).

> **Common mistakes:**
> - Writing `WHERE manager_id = NULL` and being confused why it silently
>   returns nothing instead of erroring (SQL doesn't reject it — it just
>   never matches).
> - Using `<> NULL`/`!= NULL` to find "employees *with* a manager" — same
>   problem, always zero rows; the correct form is `WHERE manager_id IS NOT
>   NULL`.

---

### Q23. What's wrong with this query, and how do you fix it?

```sql
SELECT * FROM employees WHERE department_id = NULL;
```

**Answer:**
This query is *syntactically* valid but *logically* broken — it will always
return **zero rows**, no matter what data is in the table, because `=` with
`NULL` never evaluates to `TRUE`. The fix, depending on intent:
```sql
-- If looking for employees with NO department assigned:
SELECT * FROM employees WHERE department_id IS NULL;

-- If a literal parameter happened to be NULL by mistake and a real
-- department_id was intended, fix the value being passed in, not the query.
```

**Why it works:**
As covered in Q6/Q22, `NULL` represents "unknown," and SQL's three-valued
logic means any equality test against `NULL` yields `UNKNOWN`, which
`WHERE` treats as "exclude this row." `IS NULL` is the only predicate that
correctly detects `NULL` values.

**Alternative approaches:**
None genuinely different — `IS NULL` is the standard, portable, correct way
to express this across every SQL dialect.

**Performance considerations:**
Not applicable to the bug itself, but see Q22 for how `IS NULL` on a mostly
non-`NULL` column can benefit from a partial index.

> **Common mistakes:**
> - This exact bug is extremely common in generated/dynamic SQL, where an
>   application builds `WHERE column = :param` and `:param` happens to be
>   `NULL` at runtime — the query "succeeds" (no error) but silently returns
>   nothing, which is often harder to debug than an outright error.

---

### Q24. What does this query return, and why?

```sql
SELECT product_id, product_name, category_id, price
FROM products
WHERE category_id = 2 OR category_id = 3 AND price > 50000;
```

**Answer:**
It returns **5 rows** — every product in `category_id = 2` (Mobiles),
*plus* products in `category_id = 3` (Laptops) that also cost more than
50,000:
```
 product_id |   product_name   | category_id |  price
------------+-------------------+-------------+----------
          1 | Galaxy Phone X    |           2 | 45999.00
          2 | Pixel Lite        |           2 | 29999.00
          3 | UltraBook Pro 14  |           3 | 89999.00
          4 | GameBook 15       |           3 | 74999.00
          9 | Wireless Earbuds  |           2 |  3499.00
```
Note `Laptop Sleeve 14"` (`category_id = 3`, price 799.00) is correctly
**excluded** — it's a laptop accessory under 50,000.

**Why it works:**
`AND` has higher precedence than `OR` in SQL, exactly like in most
programming languages — so this is evaluated as:
```sql
WHERE category_id = 2 OR (category_id = 3 AND price > 50000)
```
not as `(category_id = 2 OR category_id = 3) AND price > 50000`, which is
what many candidates assume at first glance.

**Alternative approaches:**
If the intent really was "category 2 or 3, AND over 50000," the correct,
unambiguous way to write it is with explicit parentheses:
```sql
WHERE (category_id = 2 OR category_id = 3) AND price > 50000;
```
which returns only the two laptops over 50,000 (`UltraBook Pro 14`,
`GameBook 15`) — a completely different, smaller result.

**Performance considerations:**
Not performance-related — this is purely a correctness/precedence trap, but
it's a very expensive one in production if it silently returns the wrong
row set for a report or a billing calculation.

> **Common mistakes:**
> - Assuming `OR` and `AND` are evaluated strictly left-to-right (they're
>   not — `AND` binds tighter).
> - Not using parentheses to make mixed `AND`/`OR` logic explicit, even when
>   you *do* understand the precedence rule — always parenthesize mixed
>   conditions for the next reader (including future you).

---

### Q25. Write a query that aliases `product_name` as `name` and `price` as `cost`.

**Answer:** **[PostgreSQL]**
```sql
SELECT product_name AS name, price AS cost
FROM products
ORDER BY product_id
LIMIT 3;
```
Result:
```
      name       |   cost
------------------+----------
 Galaxy Phone X   | 45999.00
 Pixel Lite       | 29999.00
 UltraBook Pro 14 | 89999.00
```

**Why it works:**
`AS` renames a column (or expression) *in the output only* — it does not
rename the underlying column in the table, and every subsequent reference to
that output column (e.g., in `ORDER BY`) can use the new alias.

**Alternative approaches:**
The `AS` keyword is actually optional in PostgreSQL — `SELECT product_name
name, price cost FROM products;` works identically. Most style guides
recommend always writing `AS` explicitly for readability, since omitting it
can be mistaken for a typo (missing comma between two column names).

**Performance considerations:**
None — aliasing is purely cosmetic in the result set and has zero effect on
the query plan.

> **Common mistakes:**
> - Trying to use the alias inside the *same* query's `WHERE` clause (`WHERE
>   cost > 1000`) — this fails, because per the logical order of execution
>   (Q16), `WHERE` runs before the `SELECT` list (and its aliases) are
>   evaluated. `HAVING` and `ORDER BY` *can* reference `SELECT`-list aliases
>   in PostgreSQL because they execute later.
> - Forgetting to quote an alias that isn't a valid unquoted identifier,
>   e.g. `AS "unit price"` (with a space) needs double quotes.

---

### Q26. Write a query to find inventory rows that are below their reorder level (a "low stock" alert).

**Answer:** **[PostgreSQL]**
```sql
SELECT inventory_id, product_id, warehouse_location,
       quantity_on_hand, reorder_level
FROM inventory
WHERE quantity_on_hand < reorder_level;
```
Result (2 rows):
```
 inventory_id | product_id | warehouse_location | quantity_on_hand | reorder_level
--------------+------------+---------------------+-------------------+----------------
            5 |          4 | Pune-WH1            |                 3 |              5
           10 |          9 | Mumbai-WH1          |                 0 |             25
```
Product `4` (GameBook 15, Pune) has only 3 units left against a reorder
threshold of 5, and product `9` (Wireless Earbuds, Mumbai) is completely out
of stock.

**Why it works:**
This compares two *columns of the same row* to each other rather than a
column to a fixed literal — `WHERE quantity_on_hand < reorder_level`
evaluates that expression independently for every row, which is exactly why
it correctly flags different absolute thresholds (5 for product 4, 25 for
product 9).

**Alternative approaches:**
`WHERE quantity_on_hand - reorder_level < 0` is mathematically equivalent
but less direct to read. Adding `is_urgent` as a computed/generated column,
or wrapping this in a `VIEW` (Ch. 15), are the natural next steps once this
check is reused often.

**Performance considerations:**
Comparing two columns of the same row can't use a plain single-column index
efficiently the way `quantity_on_hand < 10` could — PostgreSQL must
evaluate the expression per row (a filter, not an index condition) unless
you build an expression index specifically for it.

> **Common mistakes:**
> - Hardcoding a single threshold like `WHERE quantity_on_hand < 10` instead
>   of comparing against the row's own `reorder_level`, which varies by
>   product/warehouse in this schema (5, 10, 15, 20, 25, 30 all appear).

---

### Q27. Write a query to find all products whose name contains the word "Laptop".

**Answer:** **[PostgreSQL]**
```sql
SELECT product_id, product_name
FROM products
WHERE product_name LIKE '%Laptop%';
```
Result (1 row):
```
 product_id |   product_name
------------+-------------------
         10 | Laptop Sleeve 14"
```
Note that `UltraBook Pro 14` and `GameBook 15` — both genuinely laptops by
category (`category_id = 3`) — are **not** returned, because `LIKE` matches
the literal text of `product_name`, not the semantic category.

**Why it works:**
`%Laptop%` matches any string containing the exact substring `"Laptop"`
(case-sensitive) anywhere in it. Only `"Laptop Sleeve 14\""` contains that
literal word; the other laptop-category products just don't happen to use
the word "Laptop" in their name.

**Alternative approaches:**
`WHERE category_id = 3` is the *correct* way to find "all laptops" by
category rather than by name text — this question exists specifically to
highlight that text search (`LIKE`) and categorical filtering
(`category_id =`) answer different questions and shouldn't be confused.
`ILIKE '%laptop%'` would make the text match case-insensitive.

**Performance considerations:**
Same leading-wildcard caveat as Q21 — `LIKE '%Laptop%'` can't use a
standard B-tree index range scan; a trigram (`pg_trgm`) or full-text index
(Ch. 25) is the production-grade answer for substring search at scale.

> **Common mistakes:**
> - Using `LIKE` to search for something that's actually a structured
>   attribute (category, type, tag) rather than free text — leading to
>   missed rows exactly like the two laptops above.

---

## D. INSERT / UPDATE / DELETE (Chapter 3 — writing data)

Now the write-side of CRUD: adding, changing, and removing rows safely, and
the classic "no `WHERE` clause" disasters interviewers love to probe for.

### Q28. What's the difference between `DELETE`, `TRUNCATE`, and `DROP`?

**Answer:**
- `DELETE FROM table [WHERE ...]` — removes rows (optionally filtered),
  row-by-row, can be rolled back inside a transaction, fires triggers, and
  keeps the table structure.
- `TRUNCATE TABLE table` — removes **all** rows at once by deallocating the
  table's storage pages; much faster than an unfiltered `DELETE`, but cannot
  be filtered with `WHERE`, and keeps the table structure.
- `DROP TABLE table` — removes the table **and its structure entirely**
  (columns, constraints, indexes, data — everything).

**Why it works:**
`DELETE` is DML and operates transactionally and logically, row by row —
which is why it *can* be filtered and *can* fire `AFTER DELETE` triggers per
row. `TRUNCATE` is closer to DDL — it resets the table to empty by
truncating its physical storage, which is why it's fast but all-or-nothing.
`DROP` removes the object definition itself, not just its contents.

**Alternative approaches:**
`DELETE FROM attendance;` (no `WHERE`) achieves the same *end state* as
`TRUNCATE attendance;` for a small table like this course's seed data, but
`TRUNCATE` is dramatically faster on large tables and resets `SERIAL`
sequences by default (`RESTART IDENTITY` option) in a way plain `DELETE`
does not.

**Performance considerations:**
`TRUNCATE` is near-instant regardless of table size because it doesn't scan
or log individual row deletions; `DELETE` without a `WHERE` on a
multi-million-row table can take minutes and bloats the table's dead-tuple
count until `VACUUM` runs (Ch. 29).

> **Common mistakes:**
> - Assuming `TRUNCATE` can be filtered like `DELETE` (it can't — it's
>   all rows or none).
> - Assuming `TRUNCATE` is "always safe" because it's fast — it still
>   requires an exclusive lock and, in PostgreSQL, is **transactional** (can
>   be rolled back if inside an uncommitted transaction), but is *not*
>   undoable once committed, exactly like `DELETE`.
> - Confusing `DROP` (removes the table definition) with `TRUNCATE`/`DELETE`
>   (only remove data, keep the table).

---

### Q29. Write an `INSERT` statement to add a new "Legal" department in Chennai, and a version that inserts two departments at once.

**Answer:** **[PostgreSQL]**
```sql
-- single row
INSERT INTO departments (department_name, location)
VALUES ('Legal', 'Chennai');

-- multiple rows in one statement
INSERT INTO departments (department_name, location)
VALUES ('Legal', 'Chennai'),
       ('R&D',   'Hyderabad');
```
Since `departments` currently has 5 rows (`department_id` 1–5, with the
sequence already advanced to 5 by the seed script's
`SELECT setval('departments_department_id_seq', 5);`), the new "Legal" row
is automatically assigned `department_id = 6`.

**Why it works:**
`department_id` is `SERIAL`, meaning it's backed by a PostgreSQL sequence
that auto-generates the next integer whenever a row is inserted without an
explicit value for that column — which is why the `INSERT` only needs to
supply `department_name` and `location`.

**Alternative approaches:**
Explicitly listing every column, including the surrogate key
(`INSERT INTO departments (department_id, department_name, location) VALUES
(6, 'Legal', 'Chennai')`), is possible but discouraged for `SERIAL` columns —
it bypasses the sequence and can desynchronize it from the actual max ID,
causing future auto-generated inserts to collide (a real, common bug).

**Performance considerations:**
Multi-row `INSERT ... VALUES (...), (...), (...)` is meaningfully faster
than issuing separate single-row `INSERT` statements, because it's one
parse/plan/network round trip and one set of constraint checks instead of
many — a standard technique for bulk-loading in application code.

> **Common mistakes:**
> - Manually specifying a value for a `SERIAL` primary key without also
>   advancing the sequence, causing a `duplicate key value violates unique
>   constraint` error the next time an auto-generated insert collides with
>   it.
> - Forgetting the column list and relying on positional `VALUES` matching
>   the full table's column order — fragile if the table is ever altered.

---

### Q30. Write an `UPDATE` to promote employee 6 (Karan Verma, currently "Junior Engineer") to "Software Engineer".

**Answer:** **[PostgreSQL]**
```sql
UPDATE employees
SET job_title = 'Software Engineer'
WHERE employee_id = 6;
```
Before:
```
 employee_id | first_name | last_name |   job_title
-------------+------------+-----------+----------------
           6 | Karan      | Verma     | Junior Engineer
```
After:
```
 employee_id | first_name | last_name |   job_title
-------------+------------+-----------+-------------------
           6 | Karan      | Verma     | Software Engineer
```

**Why it works:**
`UPDATE` rewrites the specified columns (`job_title`) for every row matching
the `WHERE` clause. Because `employee_id` is the primary key, `WHERE
employee_id = 6` matches exactly one row — the update is precise and
predictable.

**Alternative approaches:**
Wrapping the statement in an explicit transaction and verifying with a
`SELECT` first is the safer real-world pattern:
```sql
BEGIN;
SELECT job_title FROM employees WHERE employee_id = 6;  -- verify current state
UPDATE employees SET job_title = 'Software Engineer' WHERE employee_id = 6;
SELECT job_title FROM employees WHERE employee_id = 6;  -- verify new state
COMMIT;
```
(Transactions are covered fully in Chapter 11 — mentioned here because it's
the professional habit that prevents Q31's disaster.)

**Performance considerations:**
An `UPDATE` filtered by the primary key is as fast as a single-row lookup —
essentially free even on a huge table, since the primary key is always
indexed.

> **Common mistakes:**
> - Updating multiple columns but forgetting a comma between `SET`
>   assignments (`SET job_title = 'X' salary = 'Y'` is a syntax error;
>   correct is `SET job_title = 'X', department_id = 2`).
> - Assuming `UPDATE` returns the updated rows by default — in plain
>   PostgreSQL SQL it doesn't (`psql` just reports `UPDATE 1`); you need
>   `RETURNING` to get the changed rows back (see Q33).

---

### Q31. What's dangerous about this statement, and how would you prevent the mistake?

```sql
UPDATE employees SET status = 'TERMINATED';
```

**Answer:**
This has **no `WHERE` clause**, so it updates `status` to `'TERMINATED'` for
**every single row** in `employees` — all 16 employees, including the CTO,
every manager, everyone — not just the one employee presumably intended.
The fix is simply to always include a `WHERE` clause that isolates the
intended row(s):
```sql
UPDATE employees SET status = 'TERMINATED' WHERE employee_id = 9;
```

**Why it works:**
`UPDATE`'s `WHERE` clause is *optional* by design (so you genuinely can
update every row when that's the intent, e.g., a one-time data migration) —
but that means the database will never stop you from accidentally omitting
it. There's no implicit "did you mean just one row?" safeguard at the SQL
level.

**Alternative approaches:**
1. Run the equivalent `SELECT` first (`SELECT * FROM employees WHERE
   employee_id = 9;`) to confirm exactly which rows will be affected before
   converting it to an `UPDATE`.
2. Wrap the statement in a transaction (`BEGIN; ... ; ROLLBACK;` to test, or
   `COMMIT;` once verified) so a mistake can be undone before it's
   permanent.
3. Many `psql`/GUI clients (and CI lint tools) can be configured to warn or
   block on `UPDATE`/`DELETE` without a `WHERE` clause.

**Performance considerations:**
Not the point here, but worth noting: an unfiltered `UPDATE` on a huge table
also rewrites every row's tuple (PostgreSQL's MVCC model creates a new row
version per update, Ch. 29), which is both a correctness *and* a
performance disaster at scale.

> **Common mistakes:**
> - This is one of the most common real-world production incidents:
>   forgetting `WHERE` on an `UPDATE` or `DELETE`. Always write and verify
>   the `WHERE`/`SELECT` version of the filter *first*, then convert it to
>   the write statement.

---

### Q32. Write a `DELETE` statement to remove attendance records where the employee was marked `ABSENT`.

**Answer:** **[PostgreSQL]**
```sql
DELETE FROM attendance
WHERE status = 'ABSENT';
```
Only **1 row** matches in the seed data and is removed:
```
 attendance_id | employee_id | work_date  | status | check_in | check_out
---------------+-------------+------------+--------+----------+-----------
             5 |           4 | 2024-01-02 | ABSENT |          |
```

**Why it works:**
`DELETE ... WHERE status = 'ABSENT'` removes exactly the rows matching the
predicate — scanning all 10 attendance rows, only employee 4's Jan-2 record
has `status = 'ABSENT'`.

**Alternative approaches:**
If the goal is to *archive* rather than permanently remove absent records,
a safer alternative is copying them to an `attendance_archive` table first
(`INSERT INTO attendance_archive SELECT * FROM attendance WHERE status =
'ABSENT';`) before deleting — a common pattern for auditable data.

**Performance considerations:**
`DELETE` filtered on a non-indexed column (`status` here has no index in
this schema) requires a full table scan to find matching rows — fine at 10
rows, but on a large `attendance` table you'd want an index on `status` (or
better, a composite one matching your actual query patterns) before running
this kind of filtered delete regularly.

> **Common mistakes:**
> - Forgetting that `DELETE` here doesn't just hide the row — it's gone
>   permanently once committed (no `is_deleted` soft-delete flag exists in
>   this schema).
> - Not checking whether other tables have a foreign key referencing the
>   rows being deleted — not an issue here since nothing references
>   `attendance`, but it would raise a foreign key violation error if
>   something did (unless `ON DELETE CASCADE`/`SET NULL` were configured on
>   that other table).

---

### Q33. What does the `RETURNING` clause do? Use it while inserting a new department.

**Answer:** **[PostgreSQL]**
```sql
INSERT INTO departments (department_name, location)
VALUES ('Legal', 'Chennai')
RETURNING department_id, department_name;
```
Result:
```
 department_id | department_name
---------------+------------------
             6 | Legal
```
`RETURNING` hands back the newly generated `department_id` (6, from the
`SERIAL` sequence) in the same round trip as the `INSERT` — no separate
`SELECT` needed to discover the auto-generated key.

**Why it works:**
`RETURNING` is a PostgreSQL (and modern SQL standard-adjacent) extension
that outputs a result set from an `INSERT`, `UPDATE`, or `DELETE` statement,
computed *after* the write and any `DEFAULT`/sequence values have been
applied — exactly what you need when the database, not the client, is
responsible for generating the primary key.

**Alternative approaches:**
Without `RETURNING`, the traditional (and more portable, since not every
database supports `RETURNING`) approach is a follow-up query using
`currval()`/`lastval()` in PostgreSQL, or `LAST_INSERT_ID()` in MySQL, or
`SCOPE_IDENTITY()` in SQL Server — all more verbose and dialect-specific
than `RETURNING`. **[MySQL]** doesn't support `RETURNING` on `INSERT` before
MySQL 8.0.21 (and even there it's more limited); **[SQL Server]** uses the
`OUTPUT` clause instead of `RETURNING`.

**Performance considerations:**
`RETURNING` saves a full extra round trip to the database compared to
`INSERT` followed by a separate `SELECT ... WHERE id = lastval()` — a small
but real win, especially at high insert volume.

> **Common mistakes:**
> - Forgetting `RETURNING` is also valid on `UPDATE`/`DELETE`, not just
>   `INSERT` — e.g. `DELETE FROM attendance WHERE status='ABSENT' RETURNING
>   *;` returns the deleted row(s) before they're gone.
> - Assuming `RETURNING` re-queries the table afterward — it actually
>   returns the exact rows affected by that specific statement, computed as
>   part of executing it.

---

### Q34. If you `INSERT` a new employee and omit the `manager_id` column entirely, what value does it get? Is that different from explicitly inserting `NULL`?

**Answer:**
Omitting `manager_id` and explicitly inserting `NULL` produce the **exact
same result** here: the column ends up `NULL`, because `manager_id` has no
`DEFAULT` clause defined in the schema, and a column's implicit default
(when omitted) is always `NULL` unless a `DEFAULT` was declared.
```sql
INSERT INTO employees (first_name, last_name, email, hire_date, job_title, department_id)
VALUES ('Test', 'User', 'test.user@company.com', '2026-09-24', 'Intern', 1);
-- manager_id -> NULL (omitted, no DEFAULT declared)

INSERT INTO employees (first_name, last_name, email, hire_date, job_title, department_id, manager_id)
VALUES ('Test2', 'User2', 'test2.user@company.com', '2026-09-24', 'Intern', 1, NULL);
-- manager_id -> NULL (explicit)
```
By contrast, `status` behaves *differently* if omitted vs. given an explicit
value, because it **does** have a `DEFAULT`:
```sql
status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','ON_LEAVE','TERMINATED')),
```
Omitting `status` inserts `'ACTIVE'` (the declared default); explicitly
inserting `NULL` for `status` would instead **fail** the `NOT NULL`
constraint, since `status` is `NOT NULL` and has no implicit fallback for an
explicit `NULL`.

**Why it works:**
"Omit the column" and "declared `DEFAULT`" are two different mechanisms that
happen to coincide when there's no explicit default (defaulting to `NULL`).
Once a column has both `NOT NULL` and an explicit `DEFAULT`, omitting the
column uses the default, but explicitly supplying `NULL` bypasses the
default and hits the `NOT NULL` check directly — hence the error.

**Alternative approaches:**
Using `DEFAULT` explicitly in the `VALUES` list (`VALUES (..., DEFAULT)`)
makes the intent to "use the column's default" unambiguous in code review,
functionally identical to omitting the column from the list.

**Performance considerations:**
None — this is a correctness/semantics question, not a performance one.

> **Common mistakes:**
> - Assuming "omit the column" and "insert NULL" always behave the same —
>   they only coincide when the column has no `DEFAULT`.
> - Forgetting that a `NOT NULL` column with a `DEFAULT` still rejects an
>   *explicit* `NULL` — the default only kicks in when the column is left
>   out of the `INSERT` entirely.

---

### Q35. What is an "upsert," and how would you use `ON CONFLICT` on the `products` table?

**Answer:** **[PostgreSQL]**
An "upsert" is an insert that becomes an update if it would otherwise
violate a uniqueness constraint — "insert, or update if it already exists."
`products.sku` is `UNIQUE`, so re-inserting an existing SKU with a new price
can be handled in one statement:
```sql
INSERT INTO products (product_name, category_id, price, sku)
VALUES ('Wireless Earbuds v2', 2, 3999.00, 'SKU-MOB-003')
ON CONFLICT (sku)
DO UPDATE SET price = EXCLUDED.price;
```
Since `'SKU-MOB-003'` already belongs to product 9 ("Wireless Earbuds",
price 3499.00), this doesn't insert a new row — it updates product 9's
`price` to `3999.00` instead (note: `product_name` is *not* touched, because
the `DO UPDATE SET` only listed `price`).

**Why it works:**
`ON CONFLICT (sku) DO UPDATE` tells PostgreSQL: if the `INSERT` would
violate the unique constraint on `sku`, run this `UPDATE` against the
conflicting row instead of raising an error. `EXCLUDED.price` refers to the
value that *would have been* inserted (`3999.00`), letting you use it inside
the fallback `UPDATE`.

**Alternative approaches:**
Without `ON CONFLICT`, the same effect requires an explicit two-step
"check-then-act": `SELECT ... WHERE sku = ...` to see if it exists, then
branch to `INSERT` or `UPDATE` in application code — which is slower (extra
round trip) and, without a transaction and appropriate locking, is
vulnerable to a race condition if two processes do this concurrently.
`ON CONFLICT DO NOTHING` is a simpler variant when you just want to silently
skip duplicates rather than update them.

**Performance considerations:**
`ON CONFLICT` performs the conflict check and resolution atomically in a
single statement, avoiding both the extra round trip and the race condition
of the manual "check-then-act" approach — meaningfully better under
concurrent writers (a topic that connects directly to Chapter 12, Locks &
Concurrency).

> **Common mistakes:**
> - Trying to use `ON CONFLICT` without specifying a conflict target that
>   actually has a unique constraint or index (`ON CONFLICT (product_name)`
>   would fail here, since `product_name` isn't unique).
> - Assuming `DO UPDATE SET price = EXCLUDED.price` also updates other
>   columns automatically — only the columns explicitly listed in `SET` are
>   touched; `category_id` from the attempted insert is silently discarded
>   if not listed.

---

## E. Sorting & Pagination (Chapter 4)

`ORDER BY` and `LIMIT`/`OFFSET` control what order rows come back in and how
you slice a result set into pages — deceptively simple clauses with a
surprising number of edge cases interviewers probe.

### Q36. Write a query listing employees by hire date, most recently hired first.

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, first_name, last_name, hire_date
FROM employees
ORDER BY hire_date DESC
LIMIT 5;
```
Result (5 most recent hires):
```
 employee_id | first_name | last_name | hire_date
-------------+------------+-----------+------------
          16 | Aman       | Chawla    | 2022-01-10
           9 | Meera      | Pillai    | 2021-03-22
          15 | Pooja      | Reddy     | 2020-10-05
           6 | Karan      | Verma     | 2020-02-10
           5 | Ananya     | Singh     | 2019-09-01
```

**Why it works:**
`ORDER BY hire_date DESC` sorts rows from the largest (most recent) date to
the smallest (oldest) — `DESC` reverses the default ascending sort order.
`LIMIT 5` then trims the sorted result to the first 5 rows.

**Alternative approaches:**
`ORDER BY hire_date` alone defaults to `ASC` (oldest first) — the "most
recent first" requirement specifically requires the explicit `DESC` keyword;
there's no way to get descending order implicitly.

**Performance considerations:**
Without a supporting index on `hire_date`, PostgreSQL must read and sort all
16 rows before returning the top 5 — on a huge table, an index on
`hire_date` (especially one already stored in descending order, `CREATE
INDEX ... ON employees (hire_date DESC)`) lets the planner skip the sort
step entirely and just walk the index from the top.

> **Common mistakes:**
> - Forgetting `DESC` and getting the oldest hires instead of the newest
>   (the default `ASC` direction silently gives the opposite of what was
>   intended).
> - Applying `LIMIT` before mentally confirming the `ORDER BY` — `LIMIT`
>   without any deterministic sort is essentially "some arbitrary 5 rows"
>   (see Q42).

---

### Q37. Write a query that sorts employees by department (ascending), then by hire date within each department (descending).

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, first_name, department_id, hire_date
FROM employees
ORDER BY department_id ASC, hire_date DESC;
```
First 8 rows (departments 1 and 2, most-recent-hire-first within each):
```
 employee_id | first_name | department_id | hire_date
-------------+------------+---------------+------------
          16 | Aman       |             1 | 2022-01-10
           6 | Karan      |             1 | 2020-02-10
           5 | Ananya     |             1 | 2019-09-01
           4 | Vikram     |             1 | 2018-07-15
           3 | Sneha      |             1 | 2017-01-20
           2 | Rahul      |             1 | 2016-05-12
           1 | Aditi      |             1 | 2015-03-01
           9 | Meera      |             2 | 2021-03-22
```

**Why it works:**
Multi-column `ORDER BY` sorts by the *first* column first, then uses the
*second* column only to break ties within groups of equal first-column
values — each column can independently be `ASC` or `DESC`. Here,
`department_id ASC` groups all of department 1's rows together (before
department 2, 3, …), and within department 1, `hire_date DESC` puts the
newest hire (Aman, 2022) at the top of that group.

**Alternative approaches:**
`ORDER BY department_id, hire_date DESC` (omitting the explicit `ASC` on the
first column) is functionally identical, since `ASC` is the default — some
style guides prefer always writing the direction explicitly for clarity even
when it matches the default.

**Performance considerations:**
A composite index `(department_id, hire_date DESC)` matches this exact sort
order and lets PostgreSQL avoid an in-memory sort entirely for large tables
— one of the most common index-design decisions once query patterns are
known (Ch. 16).

> **Common mistakes:**
> - Assuming `ORDER BY department_id, hire_date DESC` applies `DESC` to
>   *both* columns — direction keywords apply only to the column
>   immediately preceding them; each column needs its own direction if you
>   want mixed sort orders.

---

### Q38. What is PostgreSQL's default `NULL` ordering, and how does it affect `ORDER BY manager_id ASC`?

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, first_name, manager_id
FROM employees
ORDER BY manager_id ASC;
```
PostgreSQL's default is **`NULLS LAST` for `ASC`** and **`NULLS FIRST` for
`DESC`** — the opposite of what many candidates assume. So Aditi
(`manager_id IS NULL`) appears at the **very end** of this ascending sort,
not the beginning:
```
 employee_id | first_name | manager_id
-------------+------------+------------
           2 | Rahul      |          1
           7 | Priya      |          1
          10 | Rohan      |          1
          12 | Nikhil     |          1
          14 | Rajesh     |          1
           3 | Sneha      |          2
          ...
          15 | Pooja      |         14
           1 | Aditi      |     (NULL)   -- last, not first
```

**Why it works:**
PostgreSQL treats `NULL` as conceptually "larger than any value" for sort
purposes by default — so an ascending sort (smallest to largest) puts `NULL`
last, and a descending sort (largest to smallest) puts it first. This is a
PostgreSQL/Oracle default, not a universal SQL standard behavior.

**Alternative approaches:**
You can always override the default explicitly:
```sql
ORDER BY manager_id ASC NULLS FIRST;   -- Aditi appears first instead
```
**[MySQL]** treats `NULL` as the *smallest* possible value, so `ORDER BY
manager_id ASC` in MySQL puts Aditi *first* by default — the exact opposite
of PostgreSQL's default — which is why explicit `NULLS FIRST/LAST` matters
for portability.

**Performance considerations:**
None significant at this scale; explicit `NULLS FIRST/LAST` has no
meaningful cost difference from the default in PostgreSQL.

> **Common mistakes:**
> - Assuming `NULL` always sorts first (true in MySQL, false by default in
>   PostgreSQL) — a genuine cross-database portability trap.
> - Not realizing this default can silently put important `NULL`-valued
>   rows (e.g., "unassigned" records) at the bottom of a report where they
>   go unnoticed, when the intent was to surface them first.

---

### Q39. Write a query to paginate the `departments` table, 2 rows per page, returning page 2.

**Answer:** **[PostgreSQL]**
```sql
SELECT department_id, department_name, location
FROM departments
ORDER BY department_id
LIMIT 2 OFFSET 2;
```
Result (page 2 = rows 3–4 of 5, since page 1 was `OFFSET 0`):
```
 department_id | department_name | location
---------------+------------------+-----------
             3 | HR               | Bengaluru
             4 | Finance          | Mumbai
```

**Why it works:**
`LIMIT 2` caps the result to 2 rows; `OFFSET 2` skips the first 2 rows
(page 1's rows: `Engineering`, `Sales`) before starting to count those 2.
In general, page `N` with page size `S` uses `OFFSET (N-1) * S`.

**Alternative approaches:**
**[PostgreSQL / SQL Standard]** `FETCH FIRST 2 ROWS ONLY OFFSET 2 ROWS` is
the SQL-standard-compliant equivalent of `LIMIT ... OFFSET ...`, supported
by PostgreSQL, Oracle, and SQL Server (2012+); `LIMIT`/`OFFSET` itself is a
PostgreSQL/MySQL convention, not part of the ANSI standard. **[SQL Server
pre-2012]** uses `TOP` instead, which only supports "first N rows," not
`OFFSET`, without a separate `ROW_NUMBER()` trick (a Ch. 10 window-function
technique).

**Performance considerations:**
`OFFSET` is a genuine performance trap at scale: PostgreSQL still has to
scan and discard the first `OFFSET` rows every time, so `OFFSET 100000` on a
large table is *slow*, even though it returns few rows. **Keyset
pagination** (`WHERE department_id > :last_seen_id ORDER BY department_id
LIMIT 2`) avoids this by jumping directly to the right starting point using
an index, and is the standard production fix for deep pagination.

> **Common mistakes:**
> - Pagination without a deterministic `ORDER BY` (see Q42) — `LIMIT`/
>   `OFFSET` guarantees nothing about *which* rows you get without a stable
>   sort.
> - Using `OFFSET`-based pagination for a user-facing infinite-scroll feed
>   at high page numbers, not realizing it degrades badly compared to
>   keyset pagination as the offset grows.

---

### Q40. What's the beginner-relevant dialect difference between `LIMIT`, `TOP`, and `FETCH FIRST`?

**Answer:**
- **[PostgreSQL / MySQL]**: `SELECT ... LIMIT n [OFFSET m];` — placed at the
  *end* of the query.
- **[SQL Server]**: `SELECT TOP (n) ... FROM ...;` — placed right after
  `SELECT`, and classic `TOP` alone (pre-2012) has no built-in `OFFSET`
  equivalent (needs `ROW_NUMBER()` for true pagination, or `OFFSET ...
  FETCH NEXT ...` in SQL Server 2012+).
- **[SQL Standard / Oracle 12c+ / SQL Server 2012+]**:
  `SELECT ... OFFSET m ROWS FETCH NEXT n ROWS ONLY;` — the portable,
  standards-based form.

```sql
-- PostgreSQL
SELECT product_name, price FROM products ORDER BY price DESC LIMIT 3;

-- SQL Server
SELECT TOP (3) product_name, price FROM products ORDER BY price DESC;

-- ANSI standard (also works in PostgreSQL)
SELECT product_name, price FROM products ORDER BY price DESC FETCH FIRST 3 ROWS ONLY;
```

**Why it works:**
These are three different syntactic conventions the respective vendors
adopted before/alongside the ANSI SQL:2008 standard settled on
`OFFSET ... FETCH ...`; PostgreSQL supports both its native `LIMIT/OFFSET`
and the standard `FETCH` form, which is why the third example above also
runs fine in PostgreSQL.

**Alternative approaches:**
When writing SQL meant to be portable across databases, prefer the
`OFFSET ... FETCH NEXT ... ROWS ONLY` standard form since it's supported
by the widest range of modern engines; use `LIMIT` for PostgreSQL-specific
code where brevity is preferred (and this course does, as PostgreSQL is the
primary dialect).

**Performance considerations:**
Identical performance characteristics regardless of syntax — these are just
different spellings of the same "limit the result set" operation; the
`OFFSET`-scan cost problem from Q39 applies equally to all three forms.

> **Common mistakes:**
> - Writing `SELECT * FROM products LIMIT 3` against SQL Server (syntax
>   error — SQL Server doesn't support `LIMIT` at all) or `SELECT TOP 3 *
>   FROM products` against PostgreSQL (also a syntax error).
> - Forgetting `TOP` needs parentheses when combined with a `PERCENT`
>   modifier in SQL Server, but not otherwise (a minor SQL Server-specific
>   detail).

---

### Q41. Write a query using `ORDER BY 2` instead of a column name. Why is this generally discouraged?

**Answer:** **[PostgreSQL]**
```sql
SELECT product_name, price
FROM products
ORDER BY 2 DESC;   -- "2" refers to the 2nd column in the SELECT list: price
```
This returns the same result as `ORDER BY price DESC` — products sorted
most expensive first, starting with `UltraBook Pro 14` at 89999.00.

**Why it works:**
`ORDER BY` accepts a positional integer referring to the Nth column of the
`SELECT` list, evaluated after the list is projected — position `2` here
means the second selected expression, `price`.

**Alternative approaches:**
`ORDER BY price DESC` (naming the column explicitly) achieves the identical
result and is almost always the better choice for readability and safety.

**Performance considerations:**
None — purely a maintainability concern, not a performance one.

> **Common mistakes:**
> - Relying on positional `ORDER BY` in queries that get modified later —
>   if someone inserts a new column at the front of the `SELECT` list,
>   `ORDER BY 2` now silently refers to a *different* column than intended,
>   a subtle bug that produces no error, just wrong output.
> - Confusing positional `ORDER BY N` with `GROUP BY N` (also positional in
>   PostgreSQL) — both exist, both have the same maintainability risk.

---

### Q42. What's wrong with paginating like this across repeated calls?

```sql
-- "page 1"
SELECT product_id, product_name FROM products LIMIT 3;
-- "page 2"
SELECT product_id, product_name FROM products LIMIT 3 OFFSET 3;
```

**Answer:**
There's no `ORDER BY` in either query. Without one, SQL does **not**
guarantee any particular row order — the database is free to return rows in
whatever order is physically convenient (often insertion order in practice
on a small, unmodified table, but this is never a guarantee), which means
"page 1" and "page 2" can overlap or skip rows entirely, especially after
any concurrent `INSERT`/`UPDATE`/`DELETE`, a `VACUUM`, or even just a
different query plan being chosen.

**Why it works (fix):**
```sql
SELECT product_id, product_name FROM products ORDER BY product_id LIMIT 3;
SELECT product_id, product_name FROM products ORDER BY product_id LIMIT 3 OFFSET 3;
```
Adding a deterministic, unique-column-based `ORDER BY` guarantees a stable,
repeatable total order to slice pages from — `product_id` is the primary
key here, so ties are impossible and every row has one unambiguous position.

**Alternative approaches:**
If sorting by a non-unique column (e.g., `price`, where ties exist —
`UltraBook Pro 14` and no other product currently ties, but it's easy to
imagine two products at the same price), add the primary key as a
tiebreaker: `ORDER BY price DESC, product_id ASC` — this guarantees a fully
deterministic order even when the primary sort column has duplicates.

**Performance considerations:**
Beyond correctness, a stable `ORDER BY` on an indexed column also usually
makes `LIMIT`/`OFFSET` cheaper to execute (an index scan instead of a full
table scan followed by an unindexed sort).

> **Common mistakes:**
> - Assuming rows always come back "in the order I inserted them" without
>   an `ORDER BY` — true often enough in casual testing to give false
>   confidence, but not guaranteed by the SQL standard or by PostgreSQL.
> - Sorting by a column with duplicate values without a tiebreaker,
>   producing pages that can non-deterministically repeat or drop rows that
>   share the sort value at a page boundary.

---

## F. Functions (Chapter 5)

Built-in string, numeric, date, and NULL-handling functions turn raw column
values into the shapes reports and applications actually need.

### Q43. Write a query producing each HR employee's full name and their job title in uppercase.

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id,
       first_name || ' ' || last_name AS full_name,
       UPPER(job_title) AS job_title_upper
FROM employees
WHERE department_id = 3;
```
Result:
```
 employee_id |  full_name   | job_title_upper
-------------+--------------+-----------------
          10 | Rohan Kapoor | HR MANAGER
          11 | Isha Bhatt   | HR EXECUTIVE
```

**Why it works:**
`||` is PostgreSQL's string concatenation operator, joining `first_name`, a
literal space, and `last_name` into one string per row. `UPPER()` converts
`job_title` to all uppercase, independent of the concatenation.

**Alternative approaches:**
`CONCAT(first_name, ' ', last_name)` is a portable function-call alternative
to `||` that works the same way and additionally treats `NULL` arguments as
empty strings rather than making the whole result `NULL` (a real behavioral
difference — see Q46 for why that matters). **[SQL Server]** historically
used `+` for string concatenation instead of `||` (modern SQL Server also
supports `CONCAT()`); **[MySQL]** requires `CONCAT()` since `||` means
logical OR there by default.

**Performance considerations:**
Negligible for small result sets; string concatenation and case-conversion
are cheap, row-local operations with no indexing implications unless you
filter/sort *on* the concatenated expression at scale (in which case an
expression index could help, Ch. 16).

> **Common mistakes:**
> - Using `||` with a `NULL` operand and being surprised the *entire*
>   concatenated result becomes `NULL` (e.g., an employee with a `NULL`
>   `last_name` would produce a `NULL` `full_name` with `||`, but not with
>   `CONCAT()`).
> - Forgetting the literal space `' '` between `first_name` and `last_name`,
>   producing `"RohanKapoor"` instead of `"Rohan Kapoor"`.

---

### Q44. Write a query showing each product's price alongside its price after a 10% discount, rounded to 2 decimal places.

**Answer:** **[PostgreSQL]**
```sql
SELECT product_name, price, ROUND(price * 0.9, 2) AS discounted_price
FROM products
ORDER BY product_id
LIMIT 5;
```
Result:
```
   product_name    |  price   | discounted_price
--------------------+----------+-------------------
 Galaxy Phone X     | 45999.00 |          41399.10
 Pixel Lite         | 29999.00 |          26999.10
 UltraBook Pro 14   | 89999.00 |          80999.10
 GameBook 15        | 74999.00 |          67499.10
 Men Cotton Shirt   |  1299.00 |           1169.10
```

**Why it works:**
`price * 0.9` computes 90% of the original price (i.e., a 10% discount);
`ROUND(expression, 2)` rounds the result to 2 decimal places, matching the
`NUMERIC(10,2)` precision the `price` column itself uses for currency
values.

**Alternative approaches:**
`price - (price * 0.1)` is mathematically identical to `price * 0.9` and
sometimes preferred for readability when the discount rate itself is a named
variable/parameter elsewhere in the application. `CEIL()`/`FLOOR()` would be
used instead of `ROUND()` if the business rule is "always round up" or
"always round down" rather than round-to-nearest.

**Performance considerations:**
None — arithmetic and rounding are computed per row with negligible cost
regardless of table size.

> **Common mistakes:**
> - Forgetting the second argument to `ROUND()` (`ROUND(price * 0.9)`
>   rounds to the nearest *whole number*, not 2 decimal places — a real bug
>   for currency values).
> - Applying the discount as `price * 0.1` (10% *of* the price) when the
>   intent was "the price *after* a 10% discount" (`price * 0.9`) — an easy
>   sign/direction mixup.

---

### Q45. Write a query showing each employee's tenure (years of service) using `AGE()` and `EXTRACT()`, most senior first.

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, first_name, last_name, hire_date,
       EXTRACT(YEAR FROM AGE(CURRENT_DATE, hire_date)) AS years_of_service
FROM employees
ORDER BY hire_date ASC
LIMIT 5;
```
Result (run against `CURRENT_DATE`, so the exact numbers depend on when you
run it — shown here as of 2026-09-24):
```
 employee_id | first_name | last_name |  hire_date | years_of_service
-------------+------------+-----------+------------+-------------------
           1 | Aditi      | Rao       | 2015-03-01 |                11
           7 | Priya      | Nair      | 2015-11-05 |                10
           2 | Rahul      | Mehta     | 2016-05-12 |                10
          10 | Rohan      | Kapoor    | 2016-08-09 |                10
          12 | Nikhil     | Gupta     | 2016-12-01 |                 9
```

**Why it works:**
`AGE(CURRENT_DATE, hire_date)` returns an `INTERVAL` representing the exact
calendar difference (years, months, days) between today and the hire date —
correctly calendar-aware, so it accounts for leap years and variable month
lengths rather than naively dividing days by 365. `EXTRACT(YEAR FROM ...)`
then pulls out just the whole-years component of that interval.

**Alternative approaches:**
`DATE_PART('year', AGE(CURRENT_DATE, hire_date))` is functionally
equivalent to `EXTRACT(YEAR FROM ...)` in PostgreSQL (`DATE_PART` is
PostgreSQL's function-call spelling of the same operation `EXTRACT`
expresses with special syntax). A rougher approximation,
`EXTRACT(YEAR FROM CURRENT_DATE) - EXTRACT(YEAR FROM hire_date)`, is
*wrong* — it only subtracts calendar years and doesn't account for whether
the hire's month/day has occurred yet this year (e.g., it would say Aditi,
hired March 1, has served 11 years even on February 28th of the 11th
year, which is incorrect by one day).

**Performance considerations:**
Date/interval arithmetic is computed per row and is cheap; if this
calculation were filtered on frequently (e.g., "find employees with more
than 5 years of service"), it's more efficient to compare `hire_date`
directly against a computed cutoff date (`WHERE hire_date <= CURRENT_DATE -
INTERVAL '5 years'`) than to compute `AGE()` for every row and filter on the
result, since the former can use an index on `hire_date` and the latter
cannot.

> **Common mistakes:**
> - Using naive year subtraction (`EXTRACT(YEAR FROM CURRENT_DATE) -
>   EXTRACT(YEAR FROM hire_date)`) instead of `AGE()`, producing an
>   off-by-one error for employees whose hire anniversary hasn't occurred
>   yet this calendar year.
> - Filtering with `AGE()`/`EXTRACT()` in a `WHERE` clause instead of
>   rewriting the condition in terms of `hire_date` directly, which loses
>   the ability to use an index (see Performance considerations).

---

### Q46. Write a query showing each order's payment date, substituting `'NOT PAID YET'` when it's `NULL`. What's the difference between `COALESCE` and `NULLIF`?

**Answer:** **[PostgreSQL]**
```sql
SELECT order_id, COALESCE(payment_date::text, 'NOT PAID YET') AS payment_date_display, status
FROM payments
ORDER BY order_id;
```
Result:
```
 order_id | payment_date_display |  status
----------+-----------------------+---------
        1 | 2024-01-05 10:25:00   | SUCCESS
        2 | 2024-01-08 14:05:00   | SUCCESS
        3 | 2024-01-15 09:35:00   | SUCCESS
        4 | 2024-01-20 16:50:00   | SUCCESS
        5 | NOT PAID YET          | FAILED
        6 | 2024-02-01 08:20:00   | SUCCESS
        7 | NOT PAID YET          | PENDING
        8 | 2024-02-10 12:05:00   | SUCCESS
        9 | 2024-02-14 15:35:00   | SUCCESS
       10 | 2024-02-18 13:15:00   | SUCCESS
```
Orders 5 (`FAILED`) and 7 (`PENDING`) have a `NULL` `payment_date` in the
seed data (no successful payment was ever recorded), so they get the
fallback text.

**Why it works:**
`COALESCE(expr1, expr2, ...)` returns the first non-`NULL` argument from
left to right — here, `payment_date` if it exists, otherwise the literal
string. (The `::text` cast is needed because `COALESCE` requires all
arguments to share a compatible type, and a `TIMESTAMP` can't mix with a
plain string literal directly without one side being cast.)

`NULLIF(a, b)` is the conceptual *opposite* operation: it returns `NULL` if
`a = b`, otherwise returns `a` — useful for turning a specific sentinel
value *into* `NULL` (e.g., `NULLIF(discount_code, '')` turns an empty string
into a proper `NULL`), rather than turning `NULL` into a fallback value.

**Alternative approaches:**
`CASE WHEN payment_date IS NULL THEN 'NOT PAID YET' ELSE payment_date::text
END` is a more verbose, but equivalent, way to write the same `COALESCE`
logic — useful to know `COALESCE` is really syntactic sugar over a `CASE`
expression.

**Performance considerations:**
`COALESCE` and `NULLIF` are cheap row-local expressions with no indexing
implications for a `SELECT`-list use like this; they become performance-
relevant mainly if used inside a `WHERE` clause, where wrapping an indexed
column in a function generally prevents the planner from using a plain
index on that column (a Ch. 16/18 topic).

> **Common mistakes:**
> - Confusing `COALESCE` (NULL → fallback value) with `NULLIF` (specific
>   value → NULL) — they solve opposite problems and are easy to mix up by
>   name alone.
> - Forgetting `COALESCE` requires all arguments to be a compatible/castable
>   type, causing a type-mismatch error when mixing a `TIMESTAMP` column
>   with a plain string literal without an explicit cast.

---

### Q47. Write a query to find the product with the longest product name.

**Answer:** **[PostgreSQL]**
```sql
SELECT product_name, LENGTH(product_name) AS name_length
FROM products
ORDER BY name_length DESC
LIMIT 3;
```
Result — a tie for first place at 17 characters:
```
   product_name    | name_length
--------------------+-------------
 Non-stick Pan Set  |          17
 Laptop Sleeve 14"  |          17
 UltraBook Pro 14   |          16
```

**Why it works:**
`LENGTH()` returns the number of characters in a string. Sorting
descending by that computed length and taking the top rows surfaces the
longest name(s) — and this data happens to have a genuine tie between
`"Non-stick Pan Set"` and `"Laptop Sleeve 14\""`, both 17 characters.

**Alternative approaches:**
`CHAR_LENGTH(product_name)` is the ANSI-standard-named equivalent of
PostgreSQL's `LENGTH()` for text — both work identically in PostgreSQL for
plain text columns; `LENGTH()` is also overloaded in PostgreSQL to compute
byte length for `bytea` binary data, which is a distinction that matters
once you're outside plain-text columns.

**Performance considerations:**
Computing `LENGTH()` for every row and sorting requires a full table scan
and in-memory sort at any scale — there's no way to index "the longest
string" generically, since it's an aggregate-like question over an
expression rather than a simple equality/range filter.

> **Common mistakes:**
> - Assuming there's a single "longest" name and missing that a tie exists
>   — using `LIMIT 1` alone here silently picks just one of the two tied
>   rows depending on internal row order, which is exactly the "not
>   deterministic without `ORDER BY` on a full tiebreaker" issue from Q42.

---

### Q48. What do `TRIM`, `LTRIM`, and `RTRIM` do? Show an example.

**Answer:** **[PostgreSQL]**
```sql
SELECT TRIM('   Engineering   ')  AS trimmed,
       LTRIM('   Engineering   ') AS left_trimmed,
       RTRIM('   Engineering   ') AS right_trimmed;
```
Result:
```
   trimmed    |     left_trimmed     |     right_trimmed
--------------+-----------------------+------------------------
 Engineering  | Engineering           |    Engineering
```
(Quotes above are illustrative — `trimmed` has no leading/trailing spaces at
all; `left_trimmed` still has trailing spaces; `right_trimmed` still has
leading spaces.)

**Why it works:**
`TRIM()` removes leading *and* trailing whitespace (by default; it can also
strip a specified character instead of whitespace, e.g. `TRIM(BOTH 'x' FROM
'xxhixx')`). `LTRIM()` removes only leading whitespace; `RTRIM()` removes
only trailing whitespace.

**Alternative approaches:**
`TRIM(LEADING FROM col)` / `TRIM(TRAILING FROM col)` is the ANSI-standard
long-form syntax equivalent to `LTRIM`/`RTRIM` respectively, supported in
PostgreSQL alongside the shorter function names.

**Performance considerations:**
None at the row level; if trimmed values are compared frequently (e.g.,
matching user-submitted text with stray whitespace against stored values),
consider trimming and normalizing data *on write* rather than trimming on
every read, so comparisons/indexes work against clean, canonical values.

> **Common mistakes:**
> - Confusing `TRIM` with removing *internal* whitespace (`'a   b'` stays
>   `'a   b'` after `TRIM` — only leading/trailing whitespace is removed,
>   never whitespace in the middle of the string).
> - Assuming `CHAR(n)`'s trailing-space padding (Q13) is automatically
>   removed on comparison without an explicit `TRIM` or `RTRIM` — it isn't,
>   in every dialect.

---

### Q49. Write a query showing each product's SKU alongside just its category prefix (the first 7 characters).

**Answer:** **[PostgreSQL]**
```sql
SELECT sku, SUBSTRING(sku FROM 1 FOR 7) AS sku_prefix
FROM products
ORDER BY product_id
LIMIT 5;
```
Result:
```
     sku     | sku_prefix
--------------+------------
 SKU-MOB-001 | SKU-MOB
 SKU-MOB-002 | SKU-MOB
 SKU-LAP-001 | SKU-LAP
 SKU-LAP-002 | SKU-LAP
 SKU-MEN-001 | SKU-MEN
```

**Why it works:**
`SUBSTRING(string FROM start FOR length)` extracts a substring starting at
position `start` (1-indexed) for `length` characters — position 1 through 7
of `'SKU-MOB-001'` is `'SKU-MOB'`, cleanly separating the category code from
the numeric suffix by construction of this SKU scheme.

**Alternative approaches:**
`LEFT(sku, 7)` is a more concise PostgreSQL function that directly extracts
the leftmost N characters — functionally identical to `SUBSTRING(sku FROM 1
FOR 7)` for this specific "from the start" case, and generally the more
idiomatic choice when you specifically want a prefix (vs. `SUBSTRING`, which
is more general-purpose for extracting from any position).
`SUBSTR(sku, 1, 7)` (positional-argument form) is another PostgreSQL-
supported spelling of the same operation.

**Performance considerations:**
Cheap per-row string slicing; if this prefix were queried/filtered on
often, storing it as a separate generated column (Ch. 25) or splitting the
category code into its own column at insert time would be a cleaner,
faster long-term design than re-deriving it on every read.

> **Common mistakes:**
> - Off-by-one errors with 1-indexed positions (`SUBSTRING` position 1 is
>   the *first* character, not the "zeroth," unlike some programming
>   languages' string-slicing conventions).
> - Assuming this prefix extraction is robust to SKU format changes — it's
>   brittle by construction (relies on every SKU following the exact
>   `XXX-YYY-###` pattern).

---

### Q50. Write a query that classifies each product into a price tier ("Budget" under 2000, "Mid-range" 2000–50000, "Premium" above 50000) using `CASE`.

**Answer:** **[PostgreSQL]**
```sql
SELECT product_name, price,
       CASE
           WHEN price < 2000                   THEN 'Budget'
           WHEN price BETWEEN 2000 AND 50000    THEN 'Mid-range'
           ELSE 'Premium'
       END AS price_tier
FROM products
ORDER BY price;
```
Result (10 rows):
```
   product_name    |  price   | price_tier
--------------------+----------+------------
 Laptop Sleeve 14"  |   799.00 | Budget
 Men Cotton Shirt   |  1299.00 | Budget
 Electric Kettle    |  1499.00 | Budget
 Women Kurta Set    |  1799.00 | Budget
 Non-stick Pan Set  |  2499.00 | Mid-range
 Wireless Earbuds   |  3499.00 | Mid-range
 Pixel Lite         | 29999.00 | Mid-range
 Galaxy Phone X     | 45999.00 | Mid-range
 GameBook 15        | 74999.00 | Premium
 UltraBook Pro 14   | 89999.00 | Premium
```

**Why it works:**
This is a **searched `CASE`** expression: PostgreSQL evaluates each `WHEN`
condition top to bottom for every row and returns the result of the first
one that's `TRUE`, falling through to `ELSE` if none match. Order matters —
because conditions are checked in sequence, a product priced 500 correctly
hits the first branch (`price < 2000`) and never even gets checked against
the second.

**Alternative approaches:**
A **simple `CASE`** (`CASE price WHEN 500 THEN ... END`, comparing one
expression against a list of exact values) doesn't fit this problem, since
the tiers are *ranges*, not exact values — searched `CASE` (with a boolean
condition per `WHEN`) is the correct tool whenever ranges, `AND`/`OR` logic,
or multiple columns are involved. `width_bucket()` is a PostgreSQL function
for evenly-spaced numeric bucketing, but doesn't naturally express three
unevenly-sized custom tiers like this.

**Performance considerations:**
`CASE` is evaluated per row with negligible cost; if this tier logic is
reused across many queries/reports, consider materializing it as a
generated column or a view (Ch. 15) instead of repeating the `CASE`
expression everywhere, both for consistency and to avoid re-deriving it
redundantly.

> **Common mistakes:**
> - Ordering the `WHEN` branches incorrectly for overlapping conditions
>   (e.g., checking `price < 50000` before `price < 2000` would make the
>   "Budget" branch unreachable, since everything under 50000 already
>   matches first) — always order from most specific/narrow to broadest.
> - Forgetting the `ELSE` branch, which makes any row not matching any
>   `WHEN` return `NULL` for that column instead of a sensible default.

---

## G. Aggregates & GROUP BY (Chapter 6)

Turning many rows into a small number of summary numbers — the foundation
of every report, dashboard, and KPI query.

### Q51. Write a query computing the count, minimum, maximum, average, and total of all product prices.

**Answer:** **[PostgreSQL]**
```sql
SELECT COUNT(*)          AS product_count,
       MIN(price)        AS min_price,
       MAX(price)        AS max_price,
       ROUND(AVG(price), 2) AS avg_price,
       SUM(price)        AS total_price
FROM products;
```
Result:
```
 product_count | min_price | max_price | avg_price  | total_price
---------------+-----------+-----------+------------+--------------
            10 |    799.00 |  89999.00 |   25239.00 |    252390.00
```

**Why it works:**
These are the five core aggregate functions, each collapsing all 10 rows of
`products` into a single scalar value: `COUNT(*)` counts rows, `MIN`/`MAX`
find the extremes, `AVG` computes the arithmetic mean, and `SUM` totals the
column. `ROUND(AVG(price), 2)` is applied because `AVG` over `NUMERIC(10,2)`
values can produce more decimal places than the source precision.

**Alternative approaches:**
Computing these separately with five different `SELECT` statements (one per
aggregate) would give the same numbers but requires five full scans of the
table instead of one — always prefer combining aggregates that share the
same `FROM`/`WHERE` into a single query.

**Performance considerations:**
All five aggregates here can be computed in a **single pass** over the
table (PostgreSQL doesn't need five separate scans to answer this one
query) — this is one of the cheapest possible query shapes, and an index on
`price` isn't required for correctness, though `MIN`/`MAX` alone (without
the other aggregates) *can* be answered instantly from a B-tree index on
`price` without scanning the table at all.

> **Common mistakes:**
> - Assuming `AVG(price)` returns a value at the same precision as the
>   column's declared `NUMERIC(10,2)` — PostgreSQL's `AVG` on `NUMERIC`
>   types can return extra decimal digits unless explicitly `ROUND()`ed.
> - Running `SUM(price)` on a table with `NULL` prices (not the case here,
>   since `price` is `NOT NULL`) without realizing `SUM` silently ignores
>   `NULL`s rather than making the whole sum `NULL` — see Q59 for the
>   general rule that aggregates ignore `NULL`.

---

### Q52. What's the difference between `COUNT(*)`, `COUNT(column)`, and `COUNT(DISTINCT column)`? Demonstrate with `employees.manager_id`.

**Answer:** **[PostgreSQL]**
```sql
SELECT COUNT(*)         AS total_employees,
       COUNT(manager_id) AS employees_with_manager
FROM employees;
```
Result:
```
 total_employees | employees_with_manager
------------------+-------------------------
               16 |                      15
```
And for distinct-value counting:
```sql
SELECT COUNT(*) AS total_products, COUNT(DISTINCT category_id) AS distinct_categories
FROM products;
```
Result:
```
 total_products | distinct_categories
-----------------+-----------------------
              10 |                    5
```

**Why it works:**
`COUNT(*)` counts **rows**, unconditionally, `NULL`s and all — there are 16
employee rows and 10 product rows, period. `COUNT(column)` counts only rows
where that specific *column* is **non-`NULL`** — `manager_id` is `NULL` for
exactly 1 employee (Aditi, Q22), so `COUNT(manager_id)` returns 15, not 16.
`COUNT(DISTINCT column)` counts the number of **unique non-`NULL` values**
in that column — the 10 products span only 5 distinct `category_id` values
(2, 3, 5, 6, 7), even though there are 10 rows total.

**Alternative approaches:**
`COUNT(1)` is a common alternative spelling of `COUNT(*)` some developers
use out of habit from other databases — in PostgreSQL, the query planner
treats `COUNT(*)` and `COUNT(1)` identically, so there's no performance
difference between them here (this differs from some older database
engines/versions where `COUNT(1)` was believed, often incorrectly, to be
faster).

**Performance considerations:**
`COUNT(*)` on a full table in PostgreSQL requires a full table (or index)
scan regardless — unlike some databases, PostgreSQL's MVCC design means it
cannot answer `COUNT(*)` from metadata alone, because visibility of rows
depends on the querying transaction's snapshot (Ch. 29). `COUNT(DISTINCT
column)` is more expensive than `COUNT(column)` because it must additionally
de-duplicate values (typically via a sort or hash), not just check for
non-`NULL`.

> **Common mistakes:**
> - Assuming `COUNT(column)` behaves like `COUNT(*)` and always equals the
>   row count — it under-counts by exactly however many `NULL`s exist in
>   that column.
> - Writing `COUNT(DISTINCT column)` and expecting it to also count `NULL`
>   as one of the distinct values — it doesn't; `NULL`s are excluded from
>   `COUNT(DISTINCT ...)` the same way they're excluded from `COUNT(column)`.

---

### Q53. Write a query showing how many orders exist for each status.

**Answer:** **[PostgreSQL]**
```sql
SELECT status, COUNT(*) AS order_count
FROM orders
GROUP BY status
ORDER BY order_count DESC;
```
Result (5 rows):
```
   status   | order_count
------------+-------------
 DELIVERED  |           5
 PAID       |           2
 SHIPPED    |           1
 PENDING    |           1
 CANCELLED  |           1
```

**Why it works:**
`GROUP BY status` partitions the 10 rows of `orders` into one group per
distinct `status` value, and `COUNT(*)` is then computed *per group* rather
than over the whole table — 5 orders share `'DELIVERED'`, 2 share `'PAID'`,
and the remaining 3 statuses each have exactly 1 order.

**Alternative approaches:**
Conditional aggregation (see Q56) can produce the same counts *pivoted into
columns* instead of rows (`SUM(CASE WHEN status = 'DELIVERED' THEN 1 ELSE 0
END) AS delivered_count, ...`) — useful when a report needs one row overall
with a column per status, rather than one row per status.

**Performance considerations:**
`GROUP BY` on a small table like this (10 rows) is essentially free; at
scale, an index on `status` doesn't help `GROUP BY`/`COUNT(*)` much on its
own (PostgreSQL still needs to visit every row to count it), though it can
help if combined with a `WHERE` filter that narrows the input first.

> **Common mistakes:**
> - Selecting an extra column that isn't in `GROUP BY` and isn't wrapped in
>   an aggregate function (e.g., `SELECT status, order_date, COUNT(*) ...
>   GROUP BY status`) — PostgreSQL rejects this with a "column must appear
>   in the GROUP BY clause or be used in an aggregate function" error,
>   unlike some looser dialects (older MySQL) that silently pick an
>   arbitrary value.
> - Forgetting `ORDER BY` after `GROUP BY` and assuming groups come back
>   sorted by count or alphabetically by default (neither is guaranteed).

---

### Q54. Write a query to find departments with more than 3 employees. Why must this use `HAVING` instead of `WHERE`?

**Answer:** **[PostgreSQL]**
```sql
SELECT department_id, COUNT(*) AS employee_count
FROM employees
GROUP BY department_id
HAVING COUNT(*) > 3
ORDER BY department_id;
```
Result — only Engineering qualifies:
```
 department_id | employee_count
----------------+-----------------
              1 |               7
```
(For reference, the full per-department breakdown is Engineering=7,
Sales=3, HR=2, Finance=2, Marketing=2 — only department 1 exceeds 3.)

**Why it works:**
`WHERE` filters individual **rows** *before* grouping happens (per the
logical order of execution, Q16) — at that stage, `COUNT(*)` doesn't exist
yet as a value to filter on. `HAVING` filters **groups** *after* `GROUP BY`
has produced them, which is the only point in the query where a group-level
aggregate like `COUNT(*) > 3` is even meaningful to evaluate.

**Alternative approaches:**
There is no way to express a group-level filter using `WHERE` alone —
`WHERE` and `HAVING` serve genuinely different stages of execution, not
just stylistic alternatives. However, any **row-level** filter that could
be applied *before* grouping should always go in `WHERE`, not `HAVING`
(e.g., "only count ACTIVE employees per department" should filter with
`WHERE status = 'ACTIVE'`, not compute `COUNT(*)` over everyone and then try
to fix it in `HAVING`).

**Performance considerations:**
This is a genuine performance distinction, not just a syntax rule: a
`WHERE` clause reduces the row set *before* the (often expensive) grouping
and aggregation work happens, while `HAVING` only discards *already-computed*
groups afterward. Filtering early with `WHERE` whenever the condition is
row-level (not aggregate-level) is strictly more efficient — pushing a
condition into `HAVING` when it could have been a `WHERE` clause means doing
unnecessary aggregation work on rows that get thrown away anyway.

> **Common mistakes:**
> - Writing `WHERE COUNT(*) > 3` directly — this is a syntax/semantic error
>   in PostgreSQL (`aggregate functions are not allowed in WHERE`), because
>   aggregates aren't computed at the `WHERE` stage.
> - Using `HAVING` for a condition that doesn't involve an aggregate at all
>   (e.g., `HAVING department_id = 1` instead of `WHERE department_id = 1`)
>   — it produces the correct *result* here, but does unnecessary work by
>   grouping every department before filtering, instead of filtering to
>   department 1 first.

---

### Q55. Write a query showing how many days each of employees 3 and 4 had each attendance status.

**Answer:** **[PostgreSQL]**
```sql
SELECT employee_id, status, COUNT(*) AS days
FROM attendance
WHERE employee_id IN (3, 4)
GROUP BY employee_id, status
ORDER BY employee_id, status;
```
Result:
```
 employee_id |  status | days
--------------+---------+------
            3 | LATE    |    1
            3 | PRESENT |    2
            4 | ABSENT  |    1
            4 | PRESENT |    2
```

**Why it works:**
Grouping by **two** columns, `(employee_id, status)`, creates one group per
*unique combination* of the two — not one group per `employee_id` and
separately one per `status`. Employee 3 has 3 attendance rows in the seed
data (2 `PRESENT`, 1 `LATE`), which collapse into 2 groups; employee 4 has 3
rows (2 `PRESENT`, 1 `ABSENT`), also collapsing into 2 groups — 4 groups
total.

**Alternative approaches:**
Conditional aggregation with `SUM(CASE WHEN status = 'PRESENT' THEN 1 ELSE
0 END)` per status, grouped only by `employee_id`, would pivot this into one
row per employee with a column per status instead of one row per
employee/status pair — better for a wide report table, worse for further
programmatic processing of an arbitrary/unknown set of statuses.

**Performance considerations:**
The `WHERE employee_id IN (3, 4)` filter runs *before* grouping, so
PostgreSQL only ever groups the 6 relevant rows (3 rows per employee), not
all 10 attendance rows — always filter what you can with `WHERE` before
`GROUP BY`, exactly as discussed in Q54.

> **Common mistakes:**
> - Grouping by only `employee_id` while also selecting `status` in the
>   list — rejected by PostgreSQL for the same reason as Q53 (a
>   non-aggregated, non-grouped column can't appear in `SELECT`).
> - Assuming `GROUP BY employee_id, status` is the same as `GROUP BY
>   status, employee_id` in terms of *output row order* — the grouping
>   result is the same set of groups either way, but without an explicit
>   `ORDER BY`, the returned row order is not guaranteed to match the
>   `GROUP BY` column order.

---

### Q56. Write a single query showing, per department, how many employees are ACTIVE, ON_LEAVE, and TERMINATED (one row per department, one column per status).

**Answer:** **[PostgreSQL]**
```sql
SELECT department_id,
       SUM(CASE WHEN status = 'ACTIVE'     THEN 1 ELSE 0 END) AS active_count,
       SUM(CASE WHEN status = 'ON_LEAVE'   THEN 1 ELSE 0 END) AS on_leave_count,
       SUM(CASE WHEN status = 'TERMINATED' THEN 1 ELSE 0 END) AS terminated_count
FROM employees
GROUP BY department_id
ORDER BY department_id;
```
Result:
```
 department_id | active_count | on_leave_count | terminated_count
----------------+---------------+------------------+--------------------
              1 |             6 |               1 |                 0
              2 |             2 |               0 |                 1
              3 |             2 |               0 |                 0
              4 |             2 |               0 |                 0
              5 |             2 |               0 |                 0
```
This correctly shows department 1 (Engineering) has Ananya `ON_LEAVE` and
department 2 (Sales) has Meera `TERMINATED`, alongside everyone else being
`ACTIVE`.

**Why it works:**
This is **conditional aggregation**: each `CASE` expression evaluates to
`1` for a row matching the target status and `0` otherwise, and wrapping
that in `SUM()` effectively counts how many rows in the group matched that
specific condition — three separate `CASE`/`SUM` pairs "pivot" the single
`status` column into three separate output columns, all computed within one
`GROUP BY department_id` pass.

**Alternative approaches:**
`COUNT(CASE WHEN status = 'ACTIVE' THEN 1 END)` (letting the `ELSE` branch
implicitly return `NULL` instead of `0`) works identically to
`SUM(CASE ... THEN 1 ELSE 0 END)`, since `COUNT` only counts non-`NULL`
values — a matter of style preference. PostgreSQL's `FILTER` clause is a
more modern, readable alternative: `COUNT(*) FILTER (WHERE status =
'ACTIVE') AS active_count` — arguably clearer than nesting a `CASE` inside
an aggregate, though it's PostgreSQL-specific syntax not universally
portable.

**Performance considerations:**
All three conditional sums are computed in a single pass over the grouped
data — much better than running three separate `GROUP BY ... HAVING
status = 'X'`-style queries and stitching the results together in
application code.

> **Common mistakes:**
> - Using `COUNT(*)` instead of `SUM(CASE ...)`/`COUNT(CASE ...)` inside
>   each column — plain `COUNT(*)` would just repeat the *group's total row
>   count* in every column, not the count for that specific status.
> - Forgetting the `ELSE 0` in the `SUM(CASE ...)` form — without it, `CASE`
>   implicitly returns `NULL` for non-matching rows, which is actually fine
>   for `SUM` (it ignores `NULL`s) but would be wrong if the outer function
>   were something other than `SUM`/`COUNT`/`AVG`.

---

### Q57. What's wrong with this query, and how do you fix it?

```sql
SELECT department_id, COUNT(*)
FROM employees;
```

**Answer:**
This is missing a `GROUP BY department_id` clause. In PostgreSQL it fails
outright with an error like:
```
ERROR: column "employees.department_id" must appear in the GROUP BY clause
or be used in an aggregate function
```
because mixing a plain (non-aggregated) column, `department_id`, with an
aggregate function, `COUNT(*)`, in the same `SELECT` list is only valid when
every non-aggregated column is also listed in `GROUP BY`. The fix:
```sql
SELECT department_id, COUNT(*)
FROM employees
GROUP BY department_id;
```

**Why it works:**
`COUNT(*)` without a `GROUP BY` collapses the *entire table* into one
summary row — there'd be exactly one `COUNT(*)` value (16, the total number
of employees) but PostgreSQL has no way to decide which single
`department_id` value to show alongside that one row, since 16 different
`department_id` values exist across the table. Requiring `GROUP BY` forces
you to say explicitly "one row per this column" so the pairing is
unambiguous.

**Alternative approaches:**
If the actual intent was a grand total with no department breakdown at all,
drop `department_id` from the `SELECT` list entirely:
`SELECT COUNT(*) FROM employees;` → returns a single row, `16`.

**Performance considerations:**
Not applicable — this is a strict correctness error PostgreSQL refuses to
execute, not a slow-but-valid query.

> **Common mistakes:**
> - Expecting PostgreSQL to silently pick "some" `department_id` value per
>   row like older/looser MySQL configurations historically did
>   (`ONLY_FULL_GROUP_BY` was off by default in older MySQL versions) —
>   PostgreSQL has always enforced strict `GROUP BY` rules and will error
>   instead.
> - Adding the missing column to `GROUP BY` without thinking about whether
>   that's actually the intended grain of the report (sometimes the bug is
>   that the wrong column was selected in the first place, not that
>   `GROUP BY` was omitted).

---

### Q58. Do aggregate functions include or ignore `NULL` values? Demonstrate using product reviews.

**Answer:** **[PostgreSQL]**
```sql
SELECT product_id,
       COUNT(*)            AS review_count,
       ROUND(AVG(rating), 2) AS avg_rating,
       MIN(rating)         AS min_rating,
       MAX(rating)         AS max_rating
FROM reviews
GROUP BY product_id
HAVING COUNT(*) > 1;
```
Result — only product 1 (Galaxy Phone X) has more than one review:
```
 product_id | review_count | avg_rating | min_rating | max_rating
-------------+---------------+-------------+-------------+-------------
           1 |             2 |        3.50 |           2 |           5
```
(Product 1 received a 5-star review from user 1 and a 2-star review from
user 7, averaging to 3.50 — every other reviewed product currently has
exactly one review, so it's excluded by `HAVING COUNT(*) > 1`.)

To directly demonstrate `NULL`-ignoring behavior: `reviews.review_text` is
nullable, but no seed rows happen to have a `NULL` review_text — the general
rule, stated precisely, is that **every standard aggregate function
(`COUNT(column)`, `SUM`, `AVG`, `MIN`, `MAX`) ignores `NULL` values** in the
column being aggregated; only `COUNT(*)` counts rows regardless of `NULL`s
in any column.

**Why it works:**
Aggregate functions are defined by the SQL standard to skip `NULL`s when
computing their result — this is why `AVG(rating)` divides the sum of
*known* ratings by the *count of known* ratings, not by the total row count;
if a rating were `NULL` (impossible here due to the `CHECK (rating BETWEEN 1
AND 5)` and `NOT NULL` constraint on `reviews.rating`), it simply wouldn't
contribute to the sum or the count.

**Alternative approaches:**
If you specifically need to know how many rows had a `NULL` in some
column (the opposite of what aggregates normally tell you), use
`COUNT(*) - COUNT(column)` to derive the `NULL` count, since `COUNT(*)`
includes them and `COUNT(column)` excludes them (see Q52).

**Performance considerations:**
None beyond the standard cost of `GROUP BY`/aggregation discussed in Q53
— `NULL`-skipping is a computational rule, not a performance concern.

> **Common mistakes:**
> - Assuming `AVG()` over a column with `NULL`s treats them as `0`, which
>   would incorrectly *lower* the average — `NULL`s are excluded from both
>   the numerator and denominator, not treated as zero.
> - Forgetting that `MIN`/`MAX` also ignore `NULL`s, so `MIN(rating)` over
>   a column that's entirely `NULL` returns `NULL` itself (not `0` or an
>   error), and `COUNT(*)` still correctly reports the row count in that
>   scenario even though every aggregate on that column returns `NULL`.

---

## Summary

That's **58 questions** across Foundations & Concepts, SQL Syntax Basics,
SELECT/WHERE, INSERT/UPDATE/DELETE, Sorting & Pagination, Functions, and
Aggregates & GROUP BY — with 30+ of them requiring a hands-on query written
and verified against the real `company_db`/`ecommerce_db` seed data. Once
comfortable with all of these, move on to
[Intermediate (75+)](02-intermediate.md), which starts with `JOIN`s.
