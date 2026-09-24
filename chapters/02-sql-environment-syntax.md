# Chapter 2 — SQL Environment & Syntax

> **Database used in this chapter:** `company_db` (see `databases/company_db.sql`).
> Load it first: `psql -f databases/company_db.sql`. Every query in this
> chapter runs against that exact schema and seed data, so the "Expected
> Output" blocks are the real rows you will see, in the same order, if you
> run the statements yourself in `psql` immediately after loading the file.

Chapter 1 gave you the mental model: what a database, a table, a row, a
column, and a key are. This chapter gives you the *language* itself — not
individual commands like `SELECT` or `INSERT` yet (that's Chapter 3), but the
grammar, vocabulary, and environment that every SQL statement, in every
dialect, is built from. Think of Chapter 1 as learning what a sentence is
for, and this chapter as learning the alphabet, punctuation, and grammar
rules before you write your first sentence in Chapter 3.

By the end of this chapter you will be able to:

- Correctly classify any SQL statement as DDL, DML, DCL, or TCL and explain why the distinction matters operationally.
- Read and write identifiers, literals, operators, and expressions without ambiguity.
- Explain exactly how PostgreSQL, MySQL, Oracle, and SQL Server disagree on case folding, quoting, and several core syntax points — a reference you'll return to for the rest of the course.
- Choose defensible naming conventions for tables, columns, and aliases, and justify the choice.
- Explain what a schema is, what `search_path` does, and what a session/connection actually is under the hood.

## Table of Contents

1. [SQL Statement Categories: DDL, DML, DCL, TCL](#21-sql-statement-categories-ddl-dml-dcl-tcl)
2. [Keywords](#22-keywords)
3. [Identifiers](#23-identifiers)
4. [Literals](#24-literals)
5. [Operators](#25-operators)
6. [Expressions](#26-expressions)
7. [Comments](#27-comments)
8. [Statement Termination](#28-statement-termination)
9. [Case Sensitivity](#29-case-sensitivity)
10. [Naming Conventions](#210-naming-conventions)
11. [Aliases](#211-aliases)
12. [Schemas](#212-schemas)
13. [Sessions and Connections](#213-sessions-and-connections)
14. [The SQL Dialect Landscape](#214-the-sql-dialect-landscape)
15. [Chapter Challenge](#chapter-challenge)

---

## 2.1 SQL Statement Categories: DDL, DML, DCL, TCL

### Simple explanation

SQL is not one language with one job — it's four little languages wearing
one syntax. One part builds the containers (tables), one part moves data in
and out of those containers, one part controls who's allowed to touch them,
and one part controls what "sticks" and what can be undone. Learning which
bucket a statement falls into tells you, instantly, how dangerous it is, whether
it can be rolled back, and who in your organization should be allowed to run it.

### Technical explanation

SQL statements are conventionally grouped into four (sometimes five)
sub-languages:

| Category | Full name | Purpose | Core statements |
|---|---|---|---|
| **DDL** | Data Definition Language | Defines/alters the *structure* of database objects | `CREATE`, `ALTER`, `DROP`, `TRUNCATE`, `RENAME`, `COMMENT` |
| **DML** | Data Manipulation Language | Reads/writes the *data* inside objects | `SELECT`*, `INSERT`, `UPDATE`, `DELETE`, `MERGE` |
| **DCL** | Data Control Language | Manages permissions/access | `GRANT`, `REVOKE` |
| **TCL** | Transaction Control Language | Manages the boundaries of a unit of work | `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `SET TRANSACTION` |

\* Many textbooks (and this course, where it matters) further split `SELECT`
into its own category, **DQL — Data Query Language**, because `SELECT` reads
data but never writes it, and it behaves differently around transactions and
locking than `INSERT`/`UPDATE`/`DELETE` do. You'll see both conventions in
the wild; know that `SELECT` is *retrieval only* regardless of which bucket
your source calls it.

### Why this classification exists

The split isn't academic — it maps directly onto three things that matter in
production:

1. **Transactionality.** In PostgreSQL, DDL is transactional — you can wrap
   `CREATE TABLE` in a transaction and roll it back. In Oracle and MySQL,
   most DDL statements trigger an **implicit commit**, ending any open
   transaction whether you wanted that or not. Knowing a statement is DDL
   tells you to expect this behavior difference (see §2.14).
2. **Permission granularity.** Real-world role systems grant DDL rights
   (schema owners/DBAs), DML rights (application users), and DCL rights
   (superusers/security admins) separately. A junior analyst account is
   commonly granted `SELECT`-only DML and nothing else.
3. **Blast radius / recoverability.** DDL changes structure and is often hard
   to undo cleanly (`DROP TABLE` loses data immediately unless you have
   backups). DML changes rows and, inside a transaction, can usually be
   rolled back. TCL statements are what make that rollback possible at all.

### Full syntax breakdown

```sql
-- DDL: define/alter structure
CREATE TABLE table_name ( column_definitions );
ALTER TABLE table_name ADD COLUMN column_name data_type;
DROP TABLE table_name;
TRUNCATE TABLE table_name;

-- DML: manipulate data
SELECT column_list FROM table_name WHERE condition;
INSERT INTO table_name (column_list) VALUES (value_list);
UPDATE table_name SET column = value WHERE condition;
DELETE FROM table_name WHERE condition;

-- DCL: control access
GRANT privilege_list ON object TO role_or_user;
REVOKE privilege_list ON object FROM role_or_user;

-- TCL: control transaction boundaries
BEGIN;                 -- start a transaction ([PostgreSQL]/[MySQL] spelling; [Oracle] transactions start implicitly)
COMMIT;                -- make changes permanent
ROLLBACK;              -- undo changes since BEGIN/last SAVEPOINT
SAVEPOINT name;        -- mark a point to roll back to, within a transaction
```

### Examples, simple → complex (using `company_db`)

**Example 1 — DDL: the schema itself.**
Everything in `databases/company_db.sql` before the `INSERT` statements is
DDL:

```sql
CREATE SCHEMA company_db;

CREATE TABLE departments (
    department_id   SERIAL PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE,
    location        VARCHAR(100),
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);
```

**Example 2 — DML: reading data.**

```sql
SELECT department_name, location
FROM departments;
```

Expected output:

```
 department_name | location  
------------------+-----------
 Engineering      | Pune
 Sales            | Mumbai
 HR               | Bengaluru
 Finance          | Mumbai
 Marketing        | Delhi
(5 rows)
```

**Example 3 — DML: writing data.**

```sql
INSERT INTO departments (department_name, location)
VALUES ('Legal', 'Chennai');
```

**Example 4 — DCL: granting access.**

```sql
GRANT SELECT ON employees TO reporting_role;
GRANT SELECT, INSERT, UPDATE ON salaries TO payroll_app;
REVOKE INSERT ON salaries FROM payroll_app;
```

**Example 5 — TCL: a full unit of work.**

```sql
BEGIN;

UPDATE employees
SET status = 'TERMINATED'
WHERE employee_id = 9;

INSERT INTO attendance (employee_id, work_date, status)
VALUES (9, CURRENT_DATE, 'ABSENT');

COMMIT;
```

**Example 6 — combining categories in one script (realistic pattern).**

```sql
BEGIN;                                    -- TCL

ALTER TABLE employees
    ADD COLUMN termination_date DATE;      -- DDL, but transactional in PostgreSQL

UPDATE employees
SET termination_date = '2024-02-01'
WHERE status = 'TERMINATED';               -- DML

COMMIT;                                    -- TCL
```

### Line-by-line explanation (Example 5)

1. `BEGIN;` — opens an explicit transaction block; every following statement is provisional until `COMMIT` or `ROLLBACK`.
2. `UPDATE employees SET status = 'TERMINATED' WHERE employee_id = 9;` — a DML statement; changes one row in memory/WAL but is not yet durable.
3. `INSERT INTO attendance ...` — a second DML statement, part of the same unit of work.
4. `COMMIT;` — a TCL statement that makes both changes durable and visible to other sessions atomically; if the process crashed before this line, both changes would vanish on restart.

### Internal behavior: how the engine "sees" the category

When the database receives a statement string, the **parser** performs
*lexical analysis* first: it breaks the raw text into a stream of tokens
(keywords, identifiers, literals, operators, punctuation). The **first
keyword token** (or, for compound cases like `INSERT INTO`, the first
keyword pair) is what the parser's grammar rules use to decide which
statement-type sub-grammar to apply next — a `SELECT` token routes into
query-parsing rules (looking for `FROM`, `WHERE`, `GROUP BY`, …), a `CREATE`
token routes into DDL object-definition rules, and so on. This is also why
the classification (DDL/DML/DCL/TCL) is not just a teaching convenience — the
database engine itself dispatches internally along nearly the same lines:
DDL touches the system catalog (metadata tables describing your schema), DML
touches the data pages/heap, DCL touches the privilege catalog, and TCL
touches the transaction manager directly rather than any table at all.

### Common mistakes

- Assuming `TRUNCATE` behaves like `DELETE` and can be freely rolled back — in **[MySQL]** and **[Oracle]**, `TRUNCATE` is DDL and causes an implicit commit; you cannot roll it back once issued.
- Running ad-hoc `GRANT`/`REVOKE` statements directly in application code instead of managing them as versioned DDL/DCL migration scripts.
- Forgetting that in **[Oracle]** and **[MySQL]** (with the default `autocommit` setting), a `CREATE TABLE` or other DDL statement silently commits whatever DML you had pending in the same session.
- Treating `MERGE` (a DML upsert statement covered in Chapter 31) as if it were purely an `INSERT` or purely an `UPDATE` when reasoning about locks and triggers.

### Edge cases

- `TRUNCATE` is classified as DDL by the SQL standard (it resets identity/auto-increment counters and doesn't fire row-level `DELETE` triggers by default), yet it operationally *feels* like DML because its only visible effect is "the rows are gone." Always check per-dialect trigger behavior before assuming.
- `SELECT ... FOR UPDATE` is technically DML (a query) but acquires row locks like a write — a reminder that the DDL/DML/DCL/TCL labels describe *intent*, not always *locking behavior*.
- `CREATE TABLE AS SELECT` (CTAS) is DDL (it creates an object) that also contains a full DML query and copies data — a hybrid worth knowing about before Chapter 15 (Views) and Chapter 24 (Temporary Tables).

### When to use / not use

Use this classification when you're designing **permission models** (grant DML-only to app roles, DDL/DCL only to migration/admin roles), when you're deciding **whether an operation is safe to run mid-transaction**, and when you're writing migration tooling that needs to detect "is this script structural or data-only."

### Comparisons with related concepts

DDL/DML/DCL/TCL is a *statement-level* classification. It's often confused
with **normalization** (a *schema-design* concept, Chapter 14) and with
**CRUD** (an *application-level* mental model — Create/Read/Update/Delete —
that maps onto DML statements almost 1:1, covered fully in Chapter 3). CRUD
is what your application does; DML is the SQL vocabulary it does it with.

### Real-world use cases

- A company's `payroll_app` database role is granted DML only on `salaries` and `attendance`, never DDL — so the application can never accidentally drop or alter a table, only read/write rows.
- A CI/CD pipeline separates "migration" scripts (DDL, run once, versioned) from "seed data" scripts (DML, re-runnable) — exactly the structure you see in `company_db.sql` itself.
- An auditor reviewing a breach asks "was any DCL issued in the last 24 hours?" — because a `GRANT` to an unexpected role is one of the loudest signals of a privilege-escalation attack.

### Practice questions

1. Classify each of the following as DDL, DML, DCL, or TCL: `ALTER TABLE`, `DELETE`, `SAVEPOINT`, `REVOKE`, `TRUNCATE`, `MERGE`, `ROLLBACK`, `COMMENT ON COLUMN`.
2. Why does the SQL standard treat `TRUNCATE TABLE attendance` as DDL rather than DML, even though its user-visible effect (all rows removed) looks like `DELETE FROM attendance`?
3. A colleague grants `payroll_app` the ability to run `ALTER TABLE salaries ...`. Explain, in terms of statement category and blast radius, why this is a risky grant even if the role never abuses it.
4. In **[Oracle]**, if you run `UPDATE employees SET status = 'ACTIVE' WHERE employee_id = 9;` followed immediately by `CREATE INDEX idx_test ON employees(job_title);` without an explicit `COMMIT` in between, what happens to the `UPDATE`? Why?
5. Write one example each of a DDL, DML, DCL, and TCL statement that would make sense to run against the `projects` table.
6. Some textbooks add a fifth category, DQL, containing only `SELECT`. Argue for and against this split.
7. Why might a DBA prefer to review DDL changes through a mandatory pull-request/migration process, but allow DML from applications to run freely?

---

## 2.2 Keywords

### Simple explanation

A keyword is a word that SQL has reserved for itself to describe *what to
do* — words like `SELECT`, `FROM`, `WHERE`, `AND`, `NULL`. They are the verbs
and connectors of the language. You don't get to redefine what `WHERE` means
any more than you get to redefine what "if" means in English.

### Technical explanation

A keyword is a token recognized by the SQL parser's grammar as having a
fixed syntactic role, independent of any specific database's contents.
Keywords fall into two groups:

- **Reserved keywords** — cannot be used as an identifier (table/column
  name) at all, or only if quoted, because the parser would otherwise be
  unable to tell whether the word is a keyword or a name (e.g. `SELECT`,
  `FROM`, `WHERE`, `TABLE`, `ORDER`, `GROUP`).
- **Non-reserved keywords** — have special meaning in certain syntactic
  positions but can still be used as ordinary identifiers elsewhere, because
  the grammar can disambiguate them from context (e.g. in PostgreSQL, `NAME`,
  `VALUE`, `TEXT`, and `DATA` are non-reserved).

Keywords are **case-insensitive** in every major dialect: `SELECT`,
`select`, and `SeLeCt` are the same token to the parser. This is *unrelated*
to identifier case-folding (§2.9), which is a completely different rule that
people frequently confuse with keyword case-insensitivity.

### Why keywords exist

A parser needs an unambiguous, finite vocabulary of control words so it can
tell "this token starts a clause" apart from "this token names your data."
Without reserving some words, `SELECT SELECT FROM SELECT` would be
catastrophically ambiguous if you had a column literally named `select`.
Reserving a defined keyword list is the tradeoff every SQL dialect makes to
keep its grammar parseable.

### Syntax / style convention

SQL does not *require* a particular capitalization of keywords. This course
follows the near-universal professional convention:

```sql
SELECT department_name, location   -- keywords UPPERCASE
FROM departments                   -- identifiers lowercase snake_case
WHERE location = 'Mumbai';
```

> **Important Note:** Uppercasing keywords is a *style convention*, not a
> syntax rule. `select department_name from departments;` is 100% valid SQL
> in every dialect. The convention exists purely for human readability — it
> lets your eye instantly separate "language" from "your data's names."

### Examples

```sql
-- All four are functionally identical to the parser:
SELECT * FROM employees WHERE department_id = 1;
select * from employees where department_id = 1;
SeLeCt * FrOm employees WhErE department_id = 1;
SELECT * FROM employees where department_id = 1;
```

Expected output (any of the four):

```
 employee_id | first_name | last_name | ... | department_id | manager_id | status
-------------+------------+-----------+ ... +---------------+------------+--------
           1 | Aditi      | Rao       | ... |             1 |            | ACTIVE
           2 | Rahul      | Mehta     | ... |             1 |          1 | ACTIVE
           ...
(7 rows)
```

### Common mistakes

- Using a reserved keyword as a column or table name unquoted (`CREATE TABLE order (...)`) and being confused by a syntax error — covered fully with identifiers in §2.3.
- Assuming case-insensitivity of keywords also applies to string *data* — it does not. `WHERE status = 'active'` will **not** match rows where `status = 'ACTIVE'` (see §2.9).
- Mixing capitalization inconsistently within a team codebase, making diffs noisy and reviews harder.

### Edge cases

- The *same word* can be reserved in one dialect and non-reserved (or entirely unused) in another. `USER` is a reserved keyword and a built-in function in PostgreSQL and Oracle, but an ordinary identifier is fine in other contexts in MySQL. Always check the target dialect's reserved-word list before finalizing schema names meant to be portable.
- New SQL standard versions periodically reserve *new* keywords (e.g., window-function keywords like `OVER`, `PARTITION` became meaningful later in SQL's history). Code written before a standard revision can break after an engine upgrade if it happened to use a newly-reserved word as an identifier.

### When to use / not use

You don't "choose" to use keywords — they're mandatory vocabulary. The
actionable guidance is the inverse: **avoid choosing identifier names that
collide with keywords**, reserved or not (see §2.10).

### Comparisons with related concepts

Keywords vs. identifiers: a keyword names an *operation or structural role*;
an identifier names *your data's containers* (tables, columns, aliases).
Keywords vs. functions: `NULL` is a keyword/literal, not a function; `NOW()`
is a function call, not a keyword — the parenthesis is your visual cue.

### Real-world use cases

Linters and formatters (e.g., `sqlfluff`) enforce keyword-casing rules
(`--rules capitalisation.keywords`) as part of CI, precisely because
consistent keyword casing is one of the highest-leverage, lowest-effort
readability wins in a shared codebase.

### Practice questions

1. Is `SELECT` case-sensitive? Is `Rao` (a value in `last_name`) case-sensitive? Explain the difference.
2. Name three reserved keywords and explain, from the parser's point of view, why they must be reserved.
3. Find one keyword that is non-reserved in PostgreSQL but commonly avoided as an identifier anyway. Why might a team avoid it regardless of its "legal" status?
4. Why doesn't SQL simply reserve every English word it might ever use as a keyword in a future version?
5. Rewrite `select first_name, last_name from employees where status = 'active';` fixing only the keyword casing, per this course's convention.

---

## 2.3 Identifiers

### Simple explanation

An identifier is a *name* — the name of a table, a column, a schema, an
alias, a constraint. `departments`, `employee_id`, `e` (an alias) are all
identifiers. Unlike keywords, identifiers are *your* vocabulary: you invent
them when you design a schema.

### Technical explanation

An identifier is a token that names a database object. SQL distinguishes
two identifier forms:

- **Unquoted (regular) identifiers** — must start with a letter or
  underscore, followed by letters, digits, or underscores; cannot be a
  reserved keyword; are **case-folded** by the engine (see §2.9 for exactly
  how each dialect folds them).
- **Quoted (delimited) identifiers** — wrapped in a dialect-specific
  quoting character, can contain almost any character (spaces, reserved
  words, mixed case, even keywords), and are used **verbatim, case-preserved,
  case-sensitive** by every dialect.

| Dialect | Quoting character | Example |
|---|---|---|
| **[PostgreSQL]** | Double quotes `"..."` | `"Department Name"` |
| **[Oracle]** | Double quotes `"..."` | `"Department Name"` |
| **[MySQL]** | Backticks `` `...` `` (double quotes only in ANSI_QUOTES mode) | `` `Department Name` `` |
| **[SQL Server]** | Square brackets `[...]` (or double quotes in `SET QUOTED_IDENTIFIER ON` mode) | `[Department Name]` |

### Why this rule exists

The engine needs an unambiguous way to let you name an object *anything*,
including a word that would otherwise be a keyword or contain characters the
grammar would normally treat as syntax (spaces, punctuation). Quoting is the
"escape hatch" that says: "everything between these delimiters is a literal
name, not grammar." The tradeoff is that once you opt into quoting, you also
opt into exact-case matching forever — a decision with long-term
maintenance consequences (see the warning below).

### Full syntax breakdown

```sql
-- Unquoted identifier (recommended default)
SELECT department_name FROM departments;

-- Quoted identifier, [PostgreSQL]/[Oracle]
SELECT "department_name" FROM "departments";        -- fine: lowercase matches folded default

SELECT "Department_Name" FROM departments;           -- ERROR: no column literally named Department_Name exists

-- Quoted identifier containing a space and mixed case
CREATE TABLE "Employee Archive" (
    "Employee ID"  INT,
    "Full Name"    VARCHAR(100)
);
SELECT "Full Name" FROM "Employee Archive";           -- must quote, every time, exact case
```

### Examples, simple → complex

**Example 1 — ordinary unquoted identifiers (the normal, recommended case).**

```sql
SELECT employee_id, first_name, last_name
FROM employees
WHERE department_id = 1;
```

**Example 2 — a reserved-word collision, illustrated with a hypothetical column.**
Suppose a report table needed a column literally called `order` (as in,
display order). This is legal only if quoted, everywhere, forever:

```sql
CREATE TABLE report_rows (
    row_id  SERIAL PRIMARY KEY,
    "order" INT NOT NULL,
    label   VARCHAR(100)
);

SELECT "order", label
FROM report_rows
ORDER BY "order";                 -- must quote here too, or you get a syntax error
```

> **⚠️ Warning:** Without the quotes, `SELECT order FROM report_rows;`
> fails to parse — the parser reads `order` and expects the `ORDER BY`
> clause structure to follow, not a column reference. This is exactly why
> §2.10 recommends never naming a column after a reserved word in the first
> place; `display_order` avoids the entire problem.

**Example 3 — case sensitivity forced by quoting.**

```sql
CREATE TABLE "Departments_Backup" AS
SELECT * FROM departments;

SELECT * FROM Departments_Backup;    -- [PostgreSQL] ERROR: relation "departments_backup" does not exist
SELECT * FROM "Departments_Backup";  -- works: exact case required because it was created quoted
SELECT * FROM "departments_backup";  -- ERROR: this exact-case string doesn't exist either
```

Expected output for the failing case in **[PostgreSQL]**:

```
ERROR:  relation "departments_backup" does not exist
LINE 1: SELECT * FROM Departments_Backup;
                       ^
```

### Line-by-line explanation (Example 3)

1. `CREATE TABLE "Departments_Backup" AS SELECT * FROM departments;` — because the name is double-quoted with mixed case, PostgreSQL stores the catalog entry with the exact string `Departments_Backup`, case preserved.
2. `SELECT * FROM Departments_Backup;` — unquoted, so PostgreSQL folds this to lowercase `departments_backup` before catalog lookup, which does not match the stored mixed-case name → error.
3. `SELECT * FROM "Departments_Backup";` — quoted with matching exact case → succeeds.
4. `SELECT * FROM "departments_backup";` — quoted but wrong case, and quoting disables folding entirely, so this also fails.

### Internal behavior

During lexical analysis, the tokenizer recognizes a leading quote character
as the start of a **delimited identifier token**; it consumes characters
literally (including what would otherwise be keywords or whitespace) until
the matching closing delimiter, then hands the *exact* string to the parser
as a single identifier token, tagging it "already resolved, do not fold."
An unquoted identifier token, by contrast, is tagged "foldable," and the
engine's name-resolution phase applies its case-folding rule (§2.9) before
looking the name up in the system catalog. This is also why the catalog
comparison in Example 3 fails: the *stored* catalog string and the *folded*
lookup string are different byte sequences.

### Common mistakes

- Copy-pasting a Java/C#-style `PascalCase` or `camelCase` schema design into PostgreSQL, quoting every `CREATE TABLE "Employees" ("EmployeeId" ...)`, and then forgetting to quote it consistently in every subsequent query — leading to a wave of "relation does not exist" errors for beginners.
- Believing quoting is only cosmetic; it is not — it changes actual lookup semantics.
- Naming a table or column after a keyword without realizing it, discovering it only when a query mysteriously fails to parse (`group`, `order`, `user`, `check`, `level`, `date` are frequent offenders).

### Edge cases

- Identifiers longer than the dialect's maximum are silently truncated or rejected: **[PostgreSQL]** truncates unquoted identifiers over 63 bytes; **[Oracle]** (pre-12.2) capped identifiers at 30 bytes, raised to 128 bytes from 12.2 onward; **[MySQL]** allows up to 64 characters for most object names; **[SQL Server]** allows up to 128 characters. Cross-dialect portability of long, descriptive names is not guaranteed.
- Some characters are legal in a quoted identifier but pose real risk: embedding a closing quote itself requires doubling it (`"He said ""hi"""` in PostgreSQL/Oracle-style double-quote escaping) — a frequent source of dynamic-SQL bugs (Chapter 23).
- Unicode identifiers are permitted, quoted, in most modern engines, but portability and tooling support vary — avoid them in production schemas without a specific reason.

### When to use / not use quoting

**Use quoting** only when you must interoperate with an existing schema that
already used mixed-case/reserved-word/space-containing names (e.g., a
legacy import, or a spreadsheet-derived table). **Do not use quoting** as a
stylistic choice for new schema design — it creates a permanent tax on every
future query, migration, and ORM mapping. `company_db.sql` never quotes a
single identifier, by design; every table and column name is unquoted,
lowercase, `snake_case`. This is deliberate best practice, not an accident,
and §2.10 explains exactly why.

### Comparisons with related concepts

Identifiers vs. string literals: `'departments'` (single-quoted) is a
**string value**, while `"departments"` or `departments` (unquoted) is an
**object name**. Confusing single and double quotes is one of the single
most common beginner errors — `WHERE "status" = "ACTIVE"` is a very
different (and often erroring) statement from `WHERE status = 'ACTIVE'` in
**[PostgreSQL]**, because the first tries to compare a column named `status`
to *another column* literally named `ACTIVE`.

### Real-world use cases

- Migrating a legacy Microsoft Access or Excel-derived database (columns like `Employee Name`, `Hire Date`) into PostgreSQL — you must either quote every identifier forever, or (the recommended path) rename everything to `snake_case` once, up front, during migration.
- ORMs (Django, SQLAlchemy, ActiveRecord) generate quoted identifiers automatically when your model attribute names don't match the unquoted-folding convention of the target database — understanding this section explains *why* your ORM's generated SQL sometimes has quotes you didn't write.

### Practice questions

1. Why does `SELECT * FROM "Employees";` fail in a fresh `company_db` database, while `SELECT * FROM employees;` succeeds?
2. What must you do to create and later query a table literally named `Order`?
3. Explain, precisely, the difference between `'Engineering'` and `"Engineering"` in a PostgreSQL `WHERE` clause.
4. A teammate insists on naming a new table `"UserAccount"` (quoted, PascalCase). List two concrete maintenance costs this decision imposes on every future developer.
5. What is the maximum unquoted identifier length in PostgreSQL? What happens if you exceed it?
6. Why is quoting an identifier sometimes described as "opting out of case folding" rather than merely "changing its case"?
7. Give one legitimate, defensible reason to use a quoted identifier in a brand-new schema design.

---

## 2.4 Literals

### Simple explanation

A literal is a value written directly into your SQL, exactly as-is — like
writing the number `5` in a math expression instead of a variable. `'Rao'`,
`42`, `2024-01-01`, `TRUE`, and `NULL` are all literals.

### Technical explanation

A literal is a token representing a fixed data value of a specific type,
recognized directly by the lexer from its textual form (as opposed to a
column reference or expression, whose value is only known at execution
time). SQL defines several literal categories:

| Literal type | Syntax | Example |
|---|---|---|
| String | Single-quoted text | `'Aditi'`, `'O''Brien'` |
| Numeric (integer) | Digits, optional sign | `42`, `-7` |
| Numeric (decimal) | Digits with a decimal point | `95000.50` |
| Numeric (scientific) | Mantissa + exponent | `5e6` (= 5,000,000) |
| Date | Depends on dialect; ISO form widely supported | `DATE '2024-01-01'` |
| Time | Depends on dialect | `TIME '09:00:00'` |
| Timestamp | Depends on dialect | `TIMESTAMP '2024-01-01 09:00:00'` |
| Boolean | Keyword literal (not universal — see below) | `TRUE`, `FALSE` |
| Null | Keyword literal representing "unknown/absent" | `NULL` |

### Why literals exist

Every query needs to compare or insert *concrete* values, not just column
names — you need a way to say "find the employee named `Sneha`," not merely
"find employees where `first_name` equals *something*." Literals are how you
embed a fixed value directly into the parse tree.

### Full syntax breakdown

**String literals.** Always single-quoted in standard SQL. A literal single
quote inside a string is escaped by doubling it:

```sql
SELECT 'Sneha' AS name;
SELECT 'O''Brien' AS name;           -- represents: O'Brien
```

> **⚠️ Warning [MySQL]:** MySQL, by default, also accepts double-quoted
> strings (`"Sneha"`) as string literals unless `ANSI_QUOTES` SQL mode is
> enabled — a major portability trap, because in every other dialect double
> quotes mean *identifier*, not *string*. Never rely on this MySQL default
> in code meant to be portable.

**Numeric literals.**

```sql
SELECT 42;                 -- integer
SELECT -7;                 -- signed integer
SELECT 95000.50;           -- decimal / numeric
SELECT 5e6;                -- scientific notation, evaluates to 5000000
```

**Date/time literals.** The SQL standard form uses a **typed literal**: a
type name followed by a quoted string.

```sql
SELECT DATE '2024-01-01';
SELECT TIME '09:00:00';
SELECT TIMESTAMP '2024-01-01 09:00:00';
```

Most dialects, including **[PostgreSQL]**, also accept a plain string in a
date/time context and implicitly cast it:

```sql
SELECT * FROM employees WHERE hire_date = '2015-03-01';   -- implicit cast, string -> date
```

**Boolean literals.**

```sql
SELECT TRUE, FALSE;             -- [PostgreSQL]: native boolean literals
```

> **Important Note:** Boolean literals are **not** part of core SQL-92 and
> are **not** uniformly supported. **[PostgreSQL]** has a genuine `BOOLEAN`
> type with `TRUE`/`FALSE`/`UNKNOWN` literals. **[MySQL]** treats `TRUE`/`FALSE`
> as synonyms for `1`/`0` on its `TINYINT(1)`-based boolean convention.
> **[SQL Server]** has no `TRUE`/`FALSE` keyword at all in older versions —
> you use the `BIT` type with literal `1`/`0` (this was only partially
> addressed in recent versions). **[Oracle]** had no native boolean literal
> usable in a table column at all until Oracle 23c introduced a `BOOLEAN`
> column type; PL/SQL has long had a `BOOLEAN` variable type, but SQL-level
> table columns traditionally simulate booleans with `CHAR(1)` (`'Y'`/`'N'`)
> or `NUMBER(1)` (`1`/`0`).

**Null literal.**

```sql
SELECT NULL;
SELECT * FROM employees WHERE manager_id IS NULL;   -- correct
SELECT * FROM employees WHERE manager_id = NULL;    -- WRONG: always returns zero rows (see below)
```

### Examples, simple → complex (using `company_db`)

**Example 1 — string and numeric literals together.**

```sql
SELECT first_name, last_name, job_title
FROM employees
WHERE job_title = 'Software Engineer';
```

Expected output:

```
 first_name | last_name | job_title
------------+-----------+-------------------
 Vikram     | Joshi     | Software Engineer
 Ananya     | Singh     | Software Engineer
 Aman       | Chawla    | Software Engineer
(3 rows)
```

**Example 2 — a date literal in a comparison.**

```sql
SELECT first_name, last_name, hire_date
FROM employees
WHERE hire_date < DATE '2017-01-01';
```

Expected output:

```
 first_name | last_name | hire_date  
------------+-----------+------------
 Aditi      | Rao       | 2015-03-01
 Rahul      | Mehta     | 2016-05-12
 Priya      | Nair      | 2015-11-05
 Rohan      | Kapoor    | 2016-08-09
 Nikhil     | Gupta     | 2016-12-01
(5 rows)
```

**Example 3 — the NULL literal, and why `= NULL` is a trap.**

```sql
-- Correct: IS NULL
SELECT employee_id, work_date, check_in
FROM attendance
WHERE check_in IS NULL;
```

Expected output:

```
 employee_id | work_date  | check_in
-------------+------------+----------
           4 | 2024-01-02 |
           5 | 2024-01-01 |
           5 | 2024-01-02 |
(3 rows)
```

```sql
-- Incorrect: this NEVER matches anything, on any row, in any dialect
SELECT employee_id, work_date, check_in
FROM attendance
WHERE check_in = NULL;
```

Expected output:

```
 employee_id | work_date | check_in
-------------+-----------+----------
(0 rows)
```

**Example 4 — numeric literals in arithmetic (previewing §2.5).**

```sql
SELECT employee_id, base_salary, bonus, base_salary + bonus AS total_comp
FROM salaries
WHERE employee_id = 1;
```

Expected output:

```
 employee_id | base_salary | bonus  | total_comp
-------------+-------------+--------+------------
           1 |   450000.00 | 90000.00 |   540000.00
           1 |   520000.00 | 100000.00 |  620000.00
(2 rows)
```

### Line-by-line explanation (Example 3, `= NULL` case)

1. `WHERE check_in = NULL` asks the engine to evaluate the equality predicate for every row.
2. `NULL` represents "unknown," not a comparable value. Comparing *anything* — including another `NULL` — to `NULL` with `=` produces the three-valued-logic result `UNKNOWN`, never `TRUE`.
3. `WHERE` keeps only rows where the predicate is `TRUE`. Since the predicate is `UNKNOWN` for every row, zero rows are returned — even the rows that visibly have a `NULL` `check_in`.
4. `IS NULL` is a dedicated predicate, not an equality comparison, specifically designed to test for the "unknown/absent" marker correctly.

### Internal behavior

The lexer classifies a literal purely from its lexical form: a token opening
with a digit (or sign+digit) becomes a numeric literal token immediately
carrying an inferred type (integer vs. numeric/decimal, based on presence of
a decimal point or exponent); a token opening with a single quote becomes a
string literal token, scanned char-by-char until an unescaped closing quote;
`NULL` is tokenized as its own reserved keyword, not as a "value of some
type" — its type is only resolved later, contextually, during semantic
analysis (e.g. `NULL` in a numeric column context is a *typed* null of that
column's type internally). This is why `SELECT NULL;` on its own returns a
value the engine reports as `text`/`unknown` type in PostgreSQL until context
forces a type.

### Common mistakes

- `WHERE column = NULL` instead of `WHERE column IS NULL` (by far the most common literal-related bug in this chapter).
- Forgetting to escape an embedded single quote in a string literal (`'O'Brien'` — a syntax error, because the parser sees the string end after `O'`).
- Assuming `TRUE`/`FALSE` are portable literals across all four dialects (they are not — see the Important Note above).
- Relying on implicit string-to-date casting (`WHERE hire_date = '2015-03-01'`) inside application code that later runs against a stricter dialect/configuration where the implicit cast is disallowed.

### Edge cases

- An empty string `''` is **not** the same as `NULL` in **[PostgreSQL]**, **[MySQL]**, and **[SQL Server]** — but **[Oracle]** famously (and controversially) treats an inserted empty string in a `VARCHAR2` column as `NULL`. This is one of the most-cited Oracle quirks in the industry.
- Numeric literals with leading zeros or unusual formatting (`007`) are simply the integer `7` — SQL has no octal/hex literal notation in the core standard, though some dialects add extensions (e.g., **[MySQL]** supports `0x1A` hex literals).
- Very large or high-precision numeric literals may silently lose precision if inserted into a narrower column type than the literal implies — always check target column precision/scale.

### When to use / not use

Use literals for fixed, known-at-write-time values. Do **not** hardcode
values that should be *parameters* in application code — always use bound
parameters (`$1`, `?`, `:name` depending on driver) instead of
string-concatenating literals into dynamic SQL, which is the root cause of
SQL injection (covered in depth in Chapter 23).

### Comparisons with related concepts

Literals vs. identifiers: `'employees'` (quoted with single quotes) is a
*string value* that happens to spell a table name; `employees` (unquoted) is
the *identifier* referring to the actual table. Literals vs. bind
parameters: a literal is baked into the SQL text itself; a parameter is a
placeholder resolved at execution time — parameters are almost always
preferable in application code for both security and query-plan caching
reasons.

### Real-world use cases

- Seed/reference data scripts (exactly like `company_db.sql`'s `INSERT`
  statements) are built entirely from literals.
- Reporting filters ("show me everyone hired before 2017") are literal-driven
  `WHERE` clauses.
- Data-quality checks frequently hunt for `NULL` literals via `IS NULL` to
  find incomplete records (e.g., attendance rows missing `check_in`/`check_out`).

### Practice questions

1. Why does `SELECT * FROM attendance WHERE check_out = NULL;` return zero rows even when such rows visibly exist?
2. Write a string literal representing the single word `Mumbai's` (including the apostrophe), properly escaped.
3. What data type does the literal `5e3` represent, and what value does it hold?
4. Explain why `TRUE` is not a safe, portable literal to use in code intended to also run on SQL Server.
5. What is the (in)famous Oracle-specific behavior regarding empty string literals, and why does it surprise developers coming from PostgreSQL or MySQL?
6. Write a query against `salaries` that finds every row where `currency` literally equals `'USD'` using a string literal.
7. What is the difference, if any, between `DATE '2024-01-01'` and `'2024-01-01'` used in a context expecting a date, in PostgreSQL?

---

## 2.5 Operators

### Simple explanation

Operators are the symbols that combine or compare values — `+` adds
numbers, `=` checks equality, `AND` requires two conditions to both be true.
They are the verbs of expressions.

### Technical explanation

SQL operators fall into four groups relevant here:

| Category | Operators | Purpose |
|---|---|---|
| Arithmetic | `+ - * / %` (modulo; not universal) | Numeric computation |
| Comparison | `= <> != < > <= >=` | Produce a boolean (three-valued) result |
| Logical | `AND OR NOT` | Combine boolean predicates |
| Concatenation | `\|\|` (standard), `+` **[SQL Server]**, `CONCAT()` function everywhere | Join strings together |

Comparison and logical operators don't return simple `TRUE`/`FALSE` in
SQL — they return one of **three** truth values: `TRUE`, `FALSE`, or
`UNKNOWN` (produced whenever `NULL` is involved). This "three-valued logic"
is one of the most important, most under-taught mechanics in all of SQL, and
it's why §2.4's `NULL` discussion and this section are tightly linked.

### Why operators exist, and why three-valued logic exists

Operators let you build arbitrarily complex conditions from simple pieces —
without them, every possible filter would need its own dedicated keyword.
Three-valued logic exists because SQL needs a principled way to express "I
don't know" when a value is missing (`NULL`) — pretending a missing value is
either definitely true or definitely false would silently produce wrong
answers in real data, so SQL makes "unknown" a first-class outcome instead.

### Full syntax breakdown

```sql
-- Arithmetic
expr1 + expr2
expr1 - expr2
expr1 * expr2
expr1 / expr2
expr1 % expr2        -- modulo; [PostgreSQL]/[MySQL]/[SQL Server]; [Oracle] uses MOD(expr1, expr2)

-- Comparison
expr1 = expr2
expr1 <> expr2        -- standard "not equal"
expr1 != expr2        -- widely supported alias, non-standard
expr1 < expr2
expr1 > expr2
expr1 <= expr2
expr1 >= expr2

-- Logical
cond1 AND cond2
cond1 OR cond2
NOT cond1

-- Concatenation
str1 || str2           -- [PostgreSQL]/[Oracle]/[MySQL with PIPES_AS_CONCAT]
CONCAT(str1, str2)     -- portable, works everywhere including [MySQL] default and [SQL Server]
str1 + str2            -- [SQL Server] only
```

### Truth table for AND / OR / NOT with UNKNOWN

| A | B | A AND B | A OR B |
|---|---|---|---|
| TRUE | TRUE | TRUE | TRUE |
| TRUE | FALSE | FALSE | TRUE |
| TRUE | UNKNOWN | UNKNOWN | TRUE |
| FALSE | FALSE | FALSE | FALSE |
| FALSE | UNKNOWN | FALSE | UNKNOWN |
| UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN |

| A | NOT A |
|---|---|
| TRUE | FALSE |
| FALSE | TRUE |
| UNKNOWN | UNKNOWN |

### Examples, simple → complex (using `company_db`)

**Example 1 — arithmetic operator.**

```sql
SELECT employee_id, base_salary, bonus, base_salary + bonus AS total_comp
FROM salaries
WHERE employee_id = 3;
```

Expected output:

```
 employee_id | base_salary | bonus   | total_comp
-------------+-------------+---------+------------
           3 |   180000.00 | 20000.00 |  200000.00
           3 |   210000.00 | 25000.00 |  235000.00
(2 rows)
```

**Example 2 — comparison operator.**

```sql
SELECT first_name, last_name, hire_date
FROM employees
WHERE hire_date >= DATE '2020-01-01';
```

Expected output:

```
 first_name | last_name | hire_date  
------------+-----------+------------
 Karan      | Verma     | 2020-02-10
 Meera      | Pillai    | 2021-03-22
 Pooja      | Reddy     | 2020-10-05
 Aman       | Chawla    | 2022-01-10
(4 rows)
```

**Example 3 — logical AND.**

```sql
SELECT first_name, last_name, status
FROM employees
WHERE department_id = 1
  AND status = 'ACTIVE';
```

Expected output:

```
 first_name | last_name | status
------------+-----------+--------
 Aditi      | Rao       | ACTIVE
 Rahul      | Mehta     | ACTIVE
 Sneha      | Kulkarni  | ACTIVE
 Vikram     | Joshi     | ACTIVE
 Karan      | Verma     | ACTIVE
 Aman       | Chawla    | ACTIVE
(6 rows)
```

Notice employee 5 (Ananya Singh, `ON_LEAVE`) is correctly excluded — she is
in `department_id = 1` but fails the `status = 'ACTIVE'` half of the `AND`.

**Example 4 — logical OR.**

```sql
SELECT department_name
FROM departments
WHERE department_name = 'HR'
   OR department_name = 'Finance';
```

Expected output:

```
 department_name
------------------
 HR
 Finance
(2 rows)
```

**Example 5 — NOT and three-valued logic interacting.**

```sql
SELECT employee_id, first_name, last_name, status
FROM employees
WHERE NOT status = 'ACTIVE';
```

Expected output:

```
 employee_id | first_name | last_name | status
-------------+------------+-----------+-------------
           5 | Ananya     | Singh     | ON_LEAVE
           9 | Meera      | Pillai    | TERMINATED
(2 rows)
```

**Example 6 — string concatenation.**

```sql
SELECT first_name || ' ' || last_name AS full_name
FROM employees
WHERE department_id = 3;
```

Expected output:

```
 full_name
-------------
 Rohan Kapoor
 Isha Bhatt
(2 rows)
```

**Example 7 — combining arithmetic, comparison, and logical operators.**

```sql
SELECT e.employee_id, e.first_name, e.last_name, s.base_salary, s.bonus
FROM employees e
JOIN salaries s ON s.employee_id = e.employee_id
WHERE (s.base_salary + s.bonus) > 300000
  AND e.status = 'ACTIVE';
```

> Note: this example uses a `JOIN`, formally introduced in Chapter 7 — it is
> shown here only to demonstrate operators working together across a
> realistic multi-table expression. Don't worry yet about the join syntax
> itself.

### Line-by-line explanation (Example 5)

1. `WHERE NOT status = 'ACTIVE'` first evaluates the inner predicate `status = 'ACTIVE'` for each row.
2. For most rows this is `TRUE` or `FALSE`; `NOT` flips it. Rows with `status = 'ON_LEAVE'` or `'TERMINATED'` evaluate the inner predicate to `FALSE`, so `NOT FALSE = TRUE` — kept.
3. No row in `employees.status` is `NULL` (the column is `NOT NULL` with a `CHECK` constraint), so `UNKNOWN` never actually arises here — but if it could, `NOT UNKNOWN` would still be `UNKNOWN`, and the row would be **excluded**, not included. This is a critical, frequently-missed distinction from `<> 'ACTIVE'`, which behaves the same way in this case but diverges from `IS DISTINCT FROM` in nullable columns (covered in Chapter 5).

### Internal behavior

The parser builds an **expression tree** (abstract syntax tree) from
operators and their operands, with each operator's documented **precedence**
determining tree shape when parentheses are absent. Standard SQL precedence,
highest to lowest, is roughly: unary `-` → `* / %` → binary `+ -` → `||` →
comparison operators (`= <> < > <= >=`) → `NOT` → `AND` → `OR`. The optimizer
later may reorder or transform this tree (e.g., pushing predicates down
before a join) but must preserve its logical result. Comparisons involving a
column typed `NOT NULL` (like `employees.status`) can sometimes be proven by
the optimizer to never yield `UNKNOWN`, which can enable simplifications —
one small reason `NOT NULL` constraints (Chapter 13) aren't just a
data-quality tool but occasionally a performance one too.

### Common mistakes

- Forgetting operator precedence and omitting parentheses: `WHERE department_id = 1 OR department_id = 2 AND status = 'ACTIVE'` does **not** mean "(dept 1 or 2) and active" — because `AND` binds tighter than `OR`, it means "dept 1, OR (dept 2 AND active)." Always parenthesize mixed `AND`/`OR` explicitly.
- Using `+` for string concatenation outside **[SQL Server]**, expecting it to work everywhere.
- Using `!=` in strict-standard contexts that only guarantee `<>` (rare in practice, but `<>` is the only operator guaranteed by the SQL standard itself).
- Forgetting that `%` (modulo) is not available in **[Oracle]** — you must use `MOD(a, b)`.

### Edge cases

- Dividing two integers with `/` performs **integer division** (truncating) in **[PostgreSQL]**, **[MySQL]** (for integer types), and **[SQL Server]**; e.g. `SELECT 7 / 2;` yields `3`, not `3.5`, unless at least one operand is cast to a decimal/float type. **[Oracle]**'s `NUMBER` type instead performs true division by default, so `SELECT 7 / 2 FROM dual;` yields `3.5`. This single difference has caused real production bugs during dialect migrations.
- Concatenating a `NULL` with `||` yields `NULL` for the *entire* expression in standard SQL (`'a' || NULL` = `NULL`), but **[MySQL]**'s `CONCAT()` function instead skips/ignores `NULL` arguments by default in some configurations — always test the specific function/operator/dialect combination.
- Chained comparisons like `1 < x < 10` do **not** mean what they mean in mathematics or Python — SQL evaluates left-to-right as binary operators, so `1 < x` first produces a boolean, which is then (nonsensically, and often a type error) compared with `< 10`. Use `x BETWEEN 1 AND 10` or `x > 1 AND x < 10` instead.

### When to use / not use

Use explicit parentheses any time you mix `AND` and `OR` in the same
`WHERE` clause — never rely on memorized precedence in production code, even
though you (now) know the rule. Prefer `CONCAT()` over `||`/`+` when writing
SQL meant to run unchanged across multiple dialects.

### Comparisons with related concepts

Operators vs. functions: `base_salary + bonus` is operator syntax;
`SUM(base_salary)` (Chapter 6) is a function call — functions always use
`name(arguments)` syntax, operators are infix/prefix symbols. `<>` vs
`IS DISTINCT FROM`: both test inequality, but `IS DISTINCT FROM` treats
`NULL` as a comparable value (`NULL IS DISTINCT FROM NULL` is `FALSE`),
sidestepping three-valued logic entirely — useful in edge cases covered in
Chapter 5.

### Real-world use cases

- Payroll systems constantly use arithmetic operators to derive `total_comp` from `base_salary + bonus`, exactly as in Example 1/7.
- Access-control and reporting logic relies heavily on combined `AND`/`OR` predicates (`department_id = 1 AND (status = 'ACTIVE' OR status = 'ON_LEAVE')`).
- Report labels and exports frequently concatenate `first_name || ' ' || last_name AS full_name` for display.

### Practice questions

1. Evaluate, by hand, the three-valued result of `TRUE AND UNKNOWN`, `FALSE OR UNKNOWN`, and `NOT UNKNOWN`.
2. Rewrite `WHERE department_id = 1 OR department_id = 2 AND status = 'ACTIVE'` with parentheses so it means "either department, but only if active."
3. Why does `SELECT 7 / 2;` return `3` in PostgreSQL but `3.5` in Oracle by default? How would you force decimal division in PostgreSQL?
4. Write a query against `employees` that returns everyone hired in 2017 or later, whose `status` is not `'TERMINATED'`, using `AND`/`OR`/comparison operators correctly and with unambiguous parentheses.
5. What is the portable, cross-dialect way to concatenate strings, given that `||` and `+` are not universal?
6. Explain why `x BETWEEN 1 AND 10` is preferred over `1 < x AND x < 10`-style manual chains, in terms of both correctness and readability.
7. Using `employee_projects`, write (on paper) an expression using a comparison and a logical operator that would find rows where `hours_allocated` is between 200 and 500 inclusive, without using `BETWEEN`.

---

## 2.6 Expressions

### Simple explanation

An expression is anything that can be *evaluated down to a single value* —
a literal alone (`42`), a column alone (`base_salary`), or a combination of
columns, literals, operators, and functions (`base_salary + bonus`,
`first_name || ' ' || last_name`). If keywords are verbs and identifiers are
nouns, an expression is a full noun phrase: something that resolves to one
value per row.

### Technical explanation

Formally, an expression is any syntactic construct that the grammar allows
wherever "a value" is expected: the `SELECT` list, a `WHERE`/`HAVING`
condition, an `ORDER BY` key, a column default, a `CHECK` constraint body,
function arguments, and more. Expressions are built recursively:

- **Atoms**: a literal, a column reference, a bind parameter, `NULL`.
- **Compound expressions**: atoms combined with operators (§2.5) or wrapped in function calls.
- **Conditional expressions**: `CASE WHEN ... THEN ... ELSE ... END`, which itself evaluates to a single value per row, chosen by a set of boolean conditions.

A **predicate** (like `status = 'ACTIVE'`) is technically a special case of
expression — one that always evaluates to a boolean (`TRUE`/`FALSE`/`UNKNOWN`).

### Why expressions exist

Real questions rarely map to bare column values. "What's each employee's
total compensation" needs `base_salary + bonus`. "Is this employee currently
active" needs a boolean expression. SQL's expression grammar is what lets a
single `SELECT` list compute derived values instead of forcing you to
post-process raw columns in application code.

### Full syntax breakdown

```sql
-- Expression in the SELECT list (a "computed column")
SELECT column_expr [AS alias] FROM table_name;

-- Expression in WHERE (a predicate)
SELECT * FROM table_name WHERE boolean_expr;

-- CASE expression (a value chosen conditionally)
CASE
    WHEN condition1 THEN result1
    WHEN condition2 THEN result2
    ELSE default_result
END
```

### Examples, simple → complex (using `company_db`)

**Example 1 — the simplest possible expression: a bare literal.**

```sql
SELECT 1 + 1 AS answer;
```

Expected output:

```
 answer
--------
      2
(1 row)
```

**Example 2 — a column reference is itself an expression.**

```sql
SELECT department_name FROM departments WHERE department_id = 1;
```

**Example 3 — a compound arithmetic expression.**

```sql
SELECT employee_id, base_salary, bonus, base_salary + bonus AS total_comp
FROM salaries
WHERE employee_id = 7;
```

Expected output:

```
 employee_id | base_salary | bonus   | total_comp
-------------+-------------+---------+------------
           7 |   260000.00 | 60000.00 |  320000.00
           7 |   300000.00 | 70000.00 |  370000.00
(2 rows)
```

**Example 4 — a conditional (`CASE`) expression.**

```sql
SELECT first_name, last_name, status,
       CASE
           WHEN status = 'ACTIVE'     THEN 'Currently working'
           WHEN status = 'ON_LEAVE'   THEN 'Temporarily away'
           WHEN status = 'TERMINATED' THEN 'No longer employed'
       END AS status_description
FROM employees
WHERE department_id = 2;
```

Expected output:

```
 first_name | last_name | status     | status_description
------------+-----------+------------+---------------------
 Priya      | Nair      | ACTIVE     | Currently working
 Arjun      | Das       | ACTIVE     | Currently working
 Meera      | Pillai    | TERMINATED | No longer employed
(3 rows)
```

> `CASE` is introduced fully with the rest of conditional/control-flow
> expressions in Chapter 5. It's previewed here only as the canonical
> example of a *conditional expression*.

### Line-by-line explanation (Example 4)

1. `CASE` opens a conditional expression evaluated once per row.
2. Each `WHEN condition THEN result` pair is tested top-to-bottom; the first `condition` that evaluates `TRUE` determines the `result` used, and evaluation stops there.
3. `END` closes the expression; the whole construct is now a single value, exactly like a column, and is given the alias `status_description`.
4. Because every possible `status` value is covered here, no `ELSE` is strictly needed — but omitting `ELSE` means any *uncovered* value would silently produce `NULL`, which is worth flagging as a common mistake below.

### Internal behavior

The parser treats the entire `SELECT` list as a list of expression subtrees,
each rooted at whatever top-level construct appears (a bare column, an
operator tree, a function call, or a `CASE` tree). During query planning,
the engine determines, for each expression, whether it can be evaluated
using only per-row data (safe to compute anywhere in the plan) or whether it
depends on aggregation/grouping state (must be evaluated after `GROUP BY`,
Chapter 6). This distinction is invisible to you as a beginner but explains
why some expressions are legal in `WHERE` and illegal in the same position
in `HAVING`, and vice versa.

### Common mistakes

- Omitting `ELSE` in a `CASE` expression and being surprised by unexpected `NULL`s for unanticipated input values.
- Writing an expression in `WHERE` that references a `SELECT`-list alias (`WHERE total_comp > 300000` when `total_comp` was only defined in the `SELECT` list) — this fails in most dialects because `WHERE` is logically evaluated *before* the `SELECT` list's aliases exist (query clause evaluation order is covered fully in Chapter 4).
- Mixing incompatible types in an expression and relying on implicit conversion rather than being explicit (`'5' + 3` behaves differently, or errors outright, across dialects).

### Edge cases

- Division-by-zero inside an expression (`base_salary / 0`) raises an error in most dialects rather than returning `NULL` or infinity — a frequent source of runtime failures in computed columns; guard with `NULLIF(divisor, 0)` (Chapter 5).
- An expression that references only literals (no columns) is still legal anywhere a column expression is — `SELECT 'hello' AS greeting;` needs no `FROM` clause at all in **[PostgreSQL]**/**[MySQL]**/**[SQL Server]**, but **[Oracle]** requires `SELECT 'hello' AS greeting FROM dual;` because Oracle's grammar mandates a `FROM` clause — `dual` is a permanent one-row, one-column dummy table that exists purely to satisfy this rule.

### When to use / not use

Use expressions to push simple, per-row computation into the database,
close to the data — this is usually faster and more consistent than pulling
raw values into application code and computing there. Avoid extremely
complex nested expressions in performance-critical queries without checking
the execution plan (Chapter 17); sometimes a computed column, view (Chapter
15), or generated column is clearer and more maintainable.

### Comparisons with related concepts

Expressions vs. predicates: every predicate is an expression, but not every
expression is a predicate (only boolean-valued ones are). Expressions vs.
statements: a statement (`SELECT ...`) is a complete, executable unit;
expressions are the *building blocks* used inside a statement's clauses.

### Real-world use cases

- Payroll reports compute `total_comp` as an expression rather than storing it redundantly, keeping the source of truth in `base_salary`/`bonus` alone.
- Status-labeling dashboards use `CASE` expressions constantly to translate internal codes (`'ACTIVE'`, `'ON_LEAVE'`) into human-facing text.

### Practice questions

1. Is `department_name` alone a valid expression? Is `1 = 1` an expression? Is `SELECT 1;` an expression?
2. Why does Oracle require `FROM dual` for a literal-only query, while PostgreSQL does not require a `FROM` clause at all?
3. Write a `CASE` expression against `attendance.status` that labels `'PRESENT'` and `'REMOTE'` as `'Worked'`, and everything else as `'Not worked'`.
4. What happens to rows whose value isn't covered by any `WHEN` clause, if the `CASE` expression has no `ELSE`?
5. Why can't you typically reference a `SELECT`-list alias inside the same query's `WHERE` clause?
6. Give an example of an expression that could raise a runtime error rather than return a value, and explain how to defend against it.

---

## 2.7 Comments

### Simple explanation

Comments are notes to humans that the database completely ignores. They
exist so you (and your teammates, and future-you) can explain *why* a query
does what it does.

### Technical explanation

SQL supports two comment forms, both stripped out during lexical analysis
before parsing ever sees them:

- **Single-line comment**: `--` through the end of the physical line.
- **Block comment**: `/* ... */`, spanning any number of lines, ending at the first matching `*/`.

**[MySQL]** additionally supports `#` for single-line comments (a MySQL-only
extension, not standard SQL).

### Why comments exist

SQL scripts, especially DDL migrations and complex reporting queries,
accumulate business logic that isn't self-evident from syntax alone ("why
is this filtered to `status <> 'TERMINATED'`? because payroll excludes
terminated staff from this report per policy X"). Comments are the only
mechanism SQL gives you to preserve that reasoning in the same file as the
code it explains.

### Full syntax breakdown

```sql
-- This is a single-line comment
SELECT * FROM departments; -- inline comment after code

/* This is a
   multi-line
   block comment */
SELECT * FROM employees;

SELECT *
FROM employees
/* filtering out terminated staff per HR policy 2023-11 */
WHERE status <> 'TERMINATED';
```

### Examples

**Example 1 — documenting intent directly from `company_db.sql`.**

```sql
-- ----------------------------------------------------------------------------
-- Table: managers
-- One row per department identifying the managing employee.
-- (Deliberately denormalized vs. employees.manager_id so we have a real
-- one-to-one relationship to teach 1:1 modelling and its trade-offs.)
-- ----------------------------------------------------------------------------
CREATE TABLE managers (
    manager_id      INT PRIMARY KEY REFERENCES employees(employee_id),
    department_id   INT NOT NULL UNIQUE REFERENCES departments(department_id),
    appointed_date  DATE NOT NULL
);
```

This block, taken verbatim from the course's own schema file, is a
textbook-quality use of comments: it explains a *design decision*
(deliberate denormalization) that the DDL alone could never communicate.

**Example 2 — commenting out a clause during debugging.**

```sql
SELECT employee_id, first_name, last_name
FROM employees
WHERE department_id = 1
-- AND status = 'ACTIVE'   -- temporarily disabled while debugging a report discrepancy
;
```

### Internal behavior

During lexical analysis, the tokenizer treats `--` and `/*` as the start of
a "skip zone": everything up to the terminating newline (for `--`) or
matching `*/` (for block comments) is discarded before any keyword,
identifier, or literal tokenization happens. This means a comment can never
accidentally "contain" real SQL that gets executed — but it also means a
comment can accidentally swallow code you didn't intend to disable, if you
miscount a block comment's boundaries (see below).

> **Important Note [PostgreSQL]:** PostgreSQL, as a documented extension
> beyond the SQL standard, supports **nested** block comments —
> `/* outer /* inner */ still outer */` is legal and the whole thing is
> treated as one comment. Most other dialects, including **[MySQL]** and
> **[SQL Server]**, do **not** nest block comments — in those dialects, the
> first `*/` closes the comment, and `still outer */` becomes live SQL,
> almost always producing a syntax error.

### Common mistakes

- Forgetting to close a block comment (`/* note...` with no `*/`) — everything after it, potentially the rest of the file, silently becomes a comment and is never executed. This is one of the nastiest classes of "why didn't my script do anything" bugs because there's no error — just silence.
- Relying on nested block comments in code meant to be portable to MySQL/SQL Server, where they don't nest.
- Leaving large blocks of commented-out old code in production migration scripts instead of deleting them (version control, not comments, should be your history mechanism).

### Edge cases

- A `--` comment inside a string literal is **not** a comment — `SELECT '-- not a comment' AS note;` correctly returns the literal text, because the lexer is inside a string-literal scan state and doesn't reinterpret `--` there.
- A comment can appear almost anywhere whitespace is allowed, including mid-statement, which is occasionally used to "annotate" individual clauses in long queries.

### When to use / not use

Use comments to explain **why**, not **what** — `-- exclude terminated staff
per payroll policy` is valuable; `-- select employees` above a `SELECT *
FROM employees;` is noise. Avoid using comments as a substitute for clear
naming or for storing large chunks of dead code long-term — that's what
version control history is for.

### Comparisons with related concepts

Comments vs. `NULL`: unrelated, but frequently confused by absolute
beginners as "things SQL ignores." `NULL` is a real, meaningful data value;
comments are text the parser never sees at all.

### Real-world use cases

- Every serious migration tool (Flyway, Liquibase, Alembic) encourages
  header comments in migration files recording author, ticket number, and
  intent — exactly the pattern shown in `company_db.sql`'s section banners.
- Temporarily disabling a clause with `--` while debugging a report is one
  of the most common day-to-day uses of comments for working analysts.

### Practice questions

1. What happens if you forget to close a `/* ... */` block comment partway through a long migration script?
2. Does PostgreSQL support nested block comments? Does MySQL?
3. Write a query against `projects` with a block comment explaining why rows with `end_date IS NULL` represent "still in progress" projects.
4. Why is `SELECT '-- not a comment';` not actually treated as a comment by the parser?
5. Give one good and one bad example of comment usage, and explain the difference in terms of long-term maintainability.

---

## 2.8 Statement Termination

### Simple explanation

The semicolon (`;`) marks "this statement is finished." It's the SQL
equivalent of a period at the end of a sentence.

### Technical explanation

The semicolon is the standard **statement terminator**, telling the parser
(or, in interactive tools, the client) where one statement ends and the next
begins. This matters most when multiple statements are sent together in one
script or one string, because without an unambiguous terminator the parser
would have no reliable way to know where a `CREATE TABLE`'s column list
"really" ends versus where a new statement begins (whitespace alone is not a
safe delimiter, since SQL is free-form with respect to line breaks).

### Why it exists

SQL statements can span multiple lines and contain arbitrary internal
whitespace, so line breaks cannot be used as a terminator. A dedicated,
unambiguous character is needed, and `;` was standardized for this role.

### Full syntax breakdown

```sql
STATEMENT_1;
STATEMENT_2;
STATEMENT_3;
```

- A single statement executed alone via an API/driver call often does **not** strictly require a trailing semicolon (many drivers accept `SELECT 1` with no `;`).
- A **script** containing multiple statements (like `company_db.sql`) requires a semicolon after every statement, because that's the only signal separating them.
- Interactive clients (`psql`, the `mysql` CLI) use the semicolon as the trigger to actually *send* the buffered statement to the server — until they see it, they assume you're still typing the same statement (visible as a continuation prompt, e.g. `company_db=#` becomes `company_db-#`).

### Examples

**Example 1 — multiple statements in one script (from `company_db.sql`).**

```sql
CREATE SCHEMA company_db;
SET search_path TO company_db;

CREATE TABLE departments (
    department_id   SERIAL PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE,
    location        VARCHAR(100),
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);
```

Three complete statements, three semicolons — remove any one and the parser
will keep reading into the next statement's tokens, almost always producing
a confusing syntax error far from the actual mistake.

**Example 2 — a missing semicolon causing a misleading error.**

```sql
SELECT * FROM departments
SELECT * FROM employees;
```

Expected behavior in **[PostgreSQL]**:

```
ERROR:  syntax error at or near "SELECT"
LINE 2: SELECT * FROM employees;
        ^
```

The parser was still trying to complete the *first* `SELECT`'s grammar (it
can legally be followed by more clauses like `WHERE`, `ORDER BY`, etc.) when
it hit a second `SELECT` keyword where it expected either a clause keyword
or a terminator — hence the error pointing at line 2, not the real omission
on line 1.

### Line-by-line explanation (Example 2)

1. The parser begins parsing `SELECT * FROM departments` as a query.
2. Reaching the newline, it does not stop — SQL statements are free-form across whitespace, so the parser simply keeps consuming tokens looking for a valid continuation (`WHERE`, `ORDER BY`, `;`, or end-of-input).
3. It then encounters the keyword `SELECT` again, which is not a valid continuation of the first query's grammar at that point, and raises a syntax error.
4. The fix is a semicolon after `departments`.

### Internal behavior [MySQL specific: DELIMITER]

The semicolon convention breaks down for one important, chapter-relevant
case: writing a **stored procedure/function body** (Chapter 19) that itself
needs to contain semicolons for its own internal statements. **[MySQL]**'s
interactive client solves this with the `DELIMITER` command, which
temporarily changes what string the client treats as "end of a
statement-to-send", purely a **client-side** convenience — it is not part
of the SQL language itself:

```sql
DELIMITER //

CREATE PROCEDURE example_proc()
BEGIN
    SELECT COUNT(*) FROM employees;      -- this semicolon no longer ends the statement sent to the server
END //

DELIMITER ;
```

**[SQL Server]**'s tools (`sqlcmd`, SSMS) solve a related problem with the
`GO` batch separator, which is also purely a client-tool convention, not a
T-SQL keyword — `GO` tells the tool "send everything since the last `GO` as
one batch," which matters for statements that must be the first/only
statement in a batch (like `CREATE PROCEDURE` in some SQL Server versions).

> **⚠️ Warning:** Neither `DELIMITER` nor `GO` is part of the SQL language
> itself — they are client-tool conventions. Sending the literal text
> `DELIMITER //` to a raw database connection via a driver/API (as opposed
> to the `mysql` CLI) will fail; it's meaningful only to the interactive
> client program.

### Common mistakes

- Forgetting the final semicolon on the last statement in a script — most engines are lenient about a *trailing* missing semicolon at true end-of-input, but do not rely on this across all clients/dialects.
- Pasting multi-statement scripts into tools/APIs that only accept a single statement per call, expecting the semicolons to "split" it for you.
- Assuming `GO` or `DELIMITER` are part of standard SQL syntax and using them inside application code that talks to the database driver directly rather than through the interactive CLI tool.

### Edge cases

- Some drivers/APIs explicitly disallow multiple semicolon-separated statements in a single call, specifically as an anti-SQL-injection defense — a batch of statements arriving where only one was expected is itself a red flag (Chapter 23).
- An empty statement (just `;` with nothing before it) is typically a harmless no-op, silently accepted by most clients.

### When to use / not use

Always terminate every statement with `;` in scripts, migrations, and
saved queries, even when a particular tool would tolerate omitting it on
the last line — consistency avoids an entire category of copy-paste bugs
when someone appends a new statement after yours later.

### Comparisons with related concepts

The semicolon terminates a *statement*; it has nothing to do with clause
separation *within* a statement (commas separate column lists, `AND`/`OR`
separate predicates). Don't confuse the client-only `GO`/`DELIMITER`
conventions with the SQL-standard semicolon.

### Real-world use cases

- Migration files are, structurally, nothing more than an ordered list of semicolon-terminated DDL/DML statements executed in sequence.
- Bulk data-load scripts and seed files (like every file in `databases/`) rely entirely on correct semicolon placement to run as a coherent sequence.

### Practice questions

1. Why does the parser report the error location on line 2 in Example 2, when the actual mistake is a missing semicolon on line 1?
2. What is `DELIMITER` in MySQL, and why is it needed only for procedure/function bodies?
3. Is `GO` a T-SQL keyword? What is it, technically?
4. Why might a database driver reject a query string containing two semicolon-separated statements even though the SQL itself is valid?
5. Rewrite `company_db.sql`'s three-statement excerpt in Example 1 with one semicolon deliberately removed, and describe, precisely, what error you'd expect and why.

---

## 2.9 Case Sensitivity

### Simple explanation

SQL has three separate, easily-confused rules about "does capitalization
matter here": one for keywords (never matters), one for identifiers
(matters *sometimes*, depending on quoting and dialect), and one for the
actual text *data* stored in your tables (matters according to the
column's collation, usually yes by default).

### Technical explanation

**1. Keywords** are always case-insensitive in every SQL dialect covered in
this course. `WHERE`, `where`, and `Where` are identical tokens.

**2. Identifiers** are case-sensitive *only when quoted*; unquoted
identifiers are **case-folded** by the engine to a dialect-specific default
before comparison/storage — and this default is the single most consequential
cross-dialect difference in this entire chapter:

| Dialect | Unquoted identifier folding | Quoted identifier behavior |
|---|---|---|
| **[PostgreSQL]** | Folded to **lowercase** | Case-sensitive, exact, stored as-typed |
| **[MySQL]** | Not folded at the character level; but **table name** case-sensitivity on disk depends on the OS filesystem and the `lower_case_table_names` server setting (0 = case-sensitive, 1 = stored lowercase, compared case-insensitively, 2 = stored as typed, compared case-insensitively) | Backtick-quoting doesn't change folding behavior in MySQL the way it does elsewhere — quoting there is mainly for reserved words/special characters |
| **[Oracle]** | Folded to **UPPERCASE** | Case-sensitive, exact, stored as-typed |
| **[SQL Server]** | Not folded; case-*sensitivity* of comparisons depends entirely on the database's **collation** (the default collation on most installs is case-*insensitive*, so `Employees` and `employees` are typically treated as the same identifier even though the original typed case is preserved for display) | Bracket- or quote-delimited identifiers don't change collation-driven comparison behavior |

**3. String data** (values stored inside `VARCHAR`/`TEXT` columns) is
compared according to the column's/database's **collation** — a set of
rules governing how strings sort and compare. Most default collations
(e.g. PostgreSQL's typical `en_US.UTF-8`, SQL Server's common
`SQL_Latin1_General_CP1_CI_AS`) make string *sorting* locale-aware but
`=` comparisons are usually still exact/case-sensitive by default in
**[PostgreSQL]** and **[Oracle]** (`'ACTIVE' <> 'active'`), while SQL
Server's very common `_CI_` ("case-insensitive") collations make `'ACTIVE' =
'active'` `TRUE` by default. MySQL's common `utf8mb4_general_ci` /
`utf8mb4_0900_ai_ci` collations are also case-insensitive by default. This
means **the exact same query and the exact same data can return different
results on different default installations** — always know your collation.

### Why these rules exist

Case folding for identifiers exists because the SQL-92 standard actually
mandates folding unquoted identifiers to **uppercase** by default (this is
where Oracle's behavior comes from — it follows the letter of the original
standard). PostgreSQL deliberately deviated to lowercase decades ago for
practical/implementation reasons and never changed it, becoming a
widely-copied convention among newer open-source databases. Collation-driven
string comparison exists because human languages sort text differently
(accents, case, locale-specific ordering), and a database needs a
configurable, well-defined answer rather than "the C library's opinion."

### Full syntax breakdown / demonstration

```sql
-- [PostgreSQL] case folding demonstration
CREATE TABLE Test_Case (Test_Column INT);
-- Actually stored in the catalog as: test_case (test_column)

SELECT * FROM TEST_CASE;      -- works: folds to test_case, matches
SELECT * FROM "Test_Case";    -- FAILS: quoted, exact-case match required, but stored name is lowercase
SELECT * FROM "test_case";    -- works: quoted, but happens to match the folded stored name exactly
```

### Examples, simple → complex (using `company_db`)

**Example 1 — unquoted identifiers, any case, all resolve the same way.**

```sql
SELECT department_name FROM DEPARTMENTS WHERE DEPARTMENT_ID = 1;
SELECT department_name FROM departments WHERE department_id = 1;
SELECT DEPARTMENT_NAME FROM Departments WHERE Department_Id = 1;
```

All three are equivalent in **[PostgreSQL]** — each unquoted token is
lowercased before catalog lookup, and `company_db`'s actual stored names are
already all-lowercase.

**Example 2 — string data case sensitivity (the part beginners get wrong most).**

```sql
SELECT * FROM employees WHERE status = 'active';
```

Expected output in **[PostgreSQL]** with its typical default collation:

```
 employee_id | first_name | last_name | ... | status
-------------+------------+-----------+ ... +--------
(0 rows)
```

Zero rows — because every seeded value is literally `'ACTIVE'` (uppercase),
and PostgreSQL's default `=` comparison on text is case-sensitive. Compare:

```sql
SELECT * FROM employees WHERE status = 'ACTIVE';
```

This correctly returns the 13 active employees.

> **Important Note:** To do a case-*insensitive* string comparison
> deliberately in PostgreSQL, use `LOWER(status) = LOWER('active')` or the
> `ILIKE` operator (both covered in Chapter 5) — never assume `=` on text is
> case-insensitive without checking your collation.

**Example 3 — cross-dialect identifier folding, side by side.**

```sql
-- Same DDL statement, run on each engine:
CREATE TABLE Employee_Archive (Employee_Id INT);
```

| Dialect | Actual stored/catalog name |
|---|---|
| **[PostgreSQL]** | `employee_archive` (`employee_id`) — folded to lowercase |
| **[Oracle]** | `EMPLOYEE_ARCHIVE` (`EMPLOYEE_ID`) — folded to uppercase |
| **[MySQL]** (Linux, default `lower_case_table_names=0`) | `Employee_Archive` — stored and compared exactly as typed |
| **[SQL Server]** | `Employee_Archive` — stored as typed; usually compared case-insensitively due to default collation |

This means `SELECT * FROM employee_archive;` (all lowercase) works
unmodified on PostgreSQL, fails to find the table on a case-sensitive MySQL
install, works on Oracle only if Oracle also folds your query's reference to
uppercase (it does, so it still matches), and typically works on SQL Server
due to its default case-insensitive collation.

### Line-by-line explanation (Example 2)

1. `WHERE status = 'active'` — `status` is an unquoted column identifier, folded to lowercase `status` for lookup; this matches the real column fine.
2. `'active'` is a **string literal**, not an identifier — it is never folded by any rule in this section; it is compared verbatim against stored data according to collation.
3. Because the seed data stores `'ACTIVE'` (uppercase) and PostgreSQL's default collation performs an exact, case-sensitive `=` comparison on text, `'active' = 'ACTIVE'` evaluates `FALSE` for every row.
4. Zero rows satisfy the `WHERE` clause, so zero rows are returned — this is completely correct, expected behavior, not a bug.

### Internal behavior

During semantic analysis (after parsing, before execution), the engine
resolves every identifier token against its system catalog. For unquoted
tokens, this resolution step first applies the dialect's folding function
(`lower()` in PostgreSQL, `upper()` in Oracle) to the token text, then
performs an exact byte-comparison lookup against catalog entries — which
themselves were folded/stored the same way at `CREATE` time. This is a pure,
deterministic text transformation with **zero awareness of your data** — it
happens purely at the metadata layer. String **data** comparison, by
contrast, happens at the *execution* layer, per-row, using the
collation-defined comparison routine attached to the column's/expression's
type — a completely separate code path from identifier resolution, which is
exactly why beginners find it so counter-intuitive that "case doesn't
matter for my table name but does matter for my WHERE value."

### Common mistakes

- Assuming that because table/column names "don't care about case," string *data* comparisons don't either — this is the single most common case-sensitivity bug in this section, illustrated directly in Example 2.
- Writing PascalCase-quoted schemas in PostgreSQL out of habit from a language like C# or Java, then fighting case-folding/quoting friction for the life of the project (see §2.3 and §2.10).
- Assuming MySQL's identifier case-sensitivity is fixed/predictable — it depends on the underlying OS and the `lower_case_table_names` setting, so the *same* CREATE TABLE script can behave differently on a Linux MySQL server versus a Windows or macOS one.
- Assuming SQL Server string comparisons are always case-insensitive — this depends entirely on the configured collation, which can be overridden per-database or even per-column.

### Edge cases

- Changing a MySQL server's `lower_case_table_names` setting after tables already exist is unsupported/dangerous — it must be set before the data directory is initialized, making it effectively a permanent, install-time decision.
- Two identifiers differing only by quoted case can coexist as *genuinely different objects* in PostgreSQL/Oracle: `"Employee"` and `"employee"` (and unquoted `employee`, which folds to match the latter) can all be separate tables simultaneously — a source of extremely confusing bugs if ever created accidentally.
- Comparing values across columns with *different* collations (e.g., joining a case-sensitive column to a case-insensitive one) can produce collation-conflict errors or silently inconsistent results in **[SQL Server]**.

### When to use / not use

Never rely on case-insensitive string matching by default — always use
explicit case-insensitive constructs (`LOWER()`, `UPPER()`, `ILIKE`,
collation-aware comparison functions covered in Chapter 5) when the business
requirement is genuinely "match regardless of case." Never mix
capitalization styles for identifiers within one schema, regardless of
dialect — pick one convention (this course recommends lowercase
`snake_case`, unquoted, everywhere — see §2.10) and apply it universally to
sidestep folding/quoting inconsistency entirely.

### Comparisons with related concepts

Case sensitivity is often confused with **quoting** (§2.3) — they are
related (quoting is *what triggers* case-preservation for identifiers) but
distinct: quoting is a syntax choice; case folding/sensitivity is the
*semantic consequence* of that choice, or of the dialect's default behavior
when no quoting is used at all.

### Real-world use cases

- A team migrating a MySQL application (developed on a case-insensitive macOS laptop) to a case-sensitive Linux production MySQL server discovers table-name lookups suddenly failing — a well-known, very real MySQL cross-platform migration gotcha directly caused by `lower_case_table_names` differing by platform default.
- A login/search feature needs `WHERE LOWER(email) = LOWER(:input)` explicitly, because relying on the database's default collation behavior for "did the user's email match, regardless of how they capitalized it" is not portable or safe to assume.

### Practice questions

1. Explain, precisely, why `SELECT * FROM Employees;` succeeds in PostgreSQL against `company_db`'s `employees` table, but `SELECT * FROM "Employees";` does not.
2. Why does `WHERE status = 'active'` return 0 rows against `company_db.employees`, even though many rows are clearly "active" conceptually?
3. What does Oracle fold unquoted identifiers to? What does PostgreSQL fold them to? Why the historical divergence?
4. What MySQL server setting controls table-name case sensitivity, and why is it dangerous to change after tables already exist?
5. In SQL Server, what single configuration setting determines whether `'ACTIVE' = 'active'` evaluates true or false?
6. Write a case-insensitive query, in PostgreSQL, that correctly matches `status` values regardless of how a user typed them.
7. Can two distinct tables named `"Employee"` and `"employee"` exist simultaneously in the same PostgreSQL schema? Why or why not?

---

## 2.10 Naming Conventions

### Simple explanation

Naming conventions are the agreed-upon style rules a team uses for naming
tables, columns, and other objects — consistent casing, consistent
singular/plural choice, and avoiding names that fight the database's own
syntax rules.

### Technical explanation

There is no SQL-standard-mandated naming convention; naming style is purely
a human/organizational discipline layered on top of the identifier rules
in §2.3 and the case-folding rules in §2.9. The recurring decisions every
schema designer faces are:

1. **Casing style**: `snake_case` (`department_name`) vs. `PascalCase`
   (`DepartmentName`) vs. `camelCase` (`departmentName`).
2. **Reserved-word avoidance**: never naming an object after a keyword.
3. **Singular vs. plural table names**: `employee` vs. `employees`.

### Why conventions matter

Consistency reduces cognitive load (you stop having to remember, per table,
"was this one plural?") and — critically in SQL specifically — the *wrong*
choice interacts badly with the case-folding rules from §2.9. A `PascalCase`
name is only preserved by quoting it, and quoting must then be repeated
**exactly**, forever, in every single query, migration, ORM mapping, and ad
hoc report anyone ever writes against that object. Teams that pick
`PascalCase` in PostgreSQL are choosing to pay a permanent, compounding
quoting tax; teams that pick `snake_case` are choosing to never think about
quoting again.

### This course's recommendation, and why

> **Recommendation:** Use lowercase `snake_case`, unquoted, for every table
> and column name. Use **plural** table names for tables representing
> collections of entities (`employees`, `departments`, `salaries`,
> `projects`), and use singular or mass-noun names only where they read more
> naturally (`attendance` is a mass noun, like "furniture" — pluralizing it
> to "attendances" would be linguistically wrong, not just stylistically
> unusual). Never name a column or table after a reserved keyword. This is
> not an arbitrary preference — it is exactly what `company_db.sql` itself
> does throughout, and this course adopts it as the default for a reason:

- **`snake_case`, unquoted** sidesteps the entire case-folding minefield from §2.9 — because it's already lowercase, PostgreSQL's folding is a no-op, Oracle's uppercase folding doesn't visually clash with how you type it either way, and there is never a reason to quote it. It is also the most common convention across the PostgreSQL and broader open-source SQL ecosystem, and is what most SQL style guides and linters (e.g. `sqlfluff`) default to.
- **Plural table names** read naturally in the most common sentence you'll ever construct about a table: "this table contains many *employees*," not "this table contains many *employee*." It also matches the default pluralization behavior of major ORMs (Rails ActiveRecord, Django by convention, Sequelize), meaning schemas built this way integrate with less friction. The alternative (singular table names, argued for on the grounds that a table is "a template for one entity" or to match some CASE-tool conventions) is a legitimate, defensible convention some serious shops do use — the important thing is picking **one** and applying it with zero exceptions, not which one.
- **Avoiding reserved words entirely** avoids the permanent quoting requirement demonstrated in §2.3's `"order"` example — `display_order`, `user_role`, `order_date` cost nothing and buy you a lifetime of never hitting a confusing syntax error over a column name.

> **⚠️ Warning:** Whatever convention you pick, the worst outcome is
> **inconsistency** — a schema with `employees` (plural, snake_case) next to
> `ProjectAssignment` (singular, PascalCase) is worse than either pure
> convention applied uniformly, because every developer now has to check,
> per table, which rule applies.

### Full syntax breakdown / comparison table

| Aspect | Recommended | Alternative(s) | Cost of the alternative |
|---|---|---|---|
| Casing | `snake_case`, unquoted | `PascalCase`/`camelCase`, quoted | Permanent mandatory quoting everywhere; fights §2.9 folding |
| Plurality | Plural (`employees`) | Singular (`employee`) | Neither is "wrong"; inconsistency between the two within one schema is the real risk |
| Reserved words | Never use as identifiers | Use, quoted (`"order"`) | Mandatory quoting forever; frequent, confusing syntax errors when forgotten |
| Foreign key columns | `<singular_table>_id` (e.g. `department_id`) | Inconsistent/ambiguous names | Harder to infer join columns without checking documentation |
| Booleans/flags | `is_active`, `has_manager` | Ambiguous names (`active`, `flag`) | Unclear whether the column is boolean-like without checking the type |

### Examples, simple → complex (using `company_db`)

**Example 1 — `company_db` following every recommendation simultaneously.**

```sql
CREATE TABLE employee_projects (
    employee_id     INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    project_id      INT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    role            VARCHAR(100) NOT NULL,
    hours_allocated INT NOT NULL DEFAULT 0 CHECK (hours_allocated >= 0),
    PRIMARY KEY (employee_id, project_id)
);
```

Notice: plural bridge-table name built from its two plural parent tables
(`employee` + `projects` → `employee_projects`, itself a widely-used bridge
table naming pattern), `snake_case` throughout, foreign key columns named
`<parent>_id` matching the parent's primary key column name exactly
(`employee_id` in both `employees` and `employee_projects`) — which, as
you'll see repeatedly starting in Chapter 7, makes `JOIN ... ON`
clauses far easier to read and write correctly.

**Example 2 — a naming decision that would have caused problems.**

Imagine `company_db.sql` had instead named the salary-history table's
percentage-increase column `increase` and the currency column's default
`default`. Both are reserved or near-reserved words in multiple dialects,
and both would require quoting on every reference. The actual schema avoids
this entirely (`base_salary`, `bonus`, `currency`) — no column in the entire
schema requires quoting in any of the four dialects this course tracks.

### Common mistakes

- Mixing plural and singular table names within one schema (`employees` next to `department` instead of `departments`).
- Choosing `PascalCase`, quoted, "because it looks like my C# model classes," without weighing the permanent quoting cost.
- Naming a foreign key column something unrelated to the parent table's primary key (e.g., naming the column referencing `departments.department_id` as just `dept` instead of `department_id`), making joins and self-documentation harder.
- Using generic, ambiguous names like `data`, `value`, `info`, `type` that don't survive contact with a second table needing a similarly generic column.

### Edge cases

- Bridge/junction tables (many-to-many, like `employee_projects`) are a special naming case: the widely-adopted convention is `<table_a_singular>_<table_b_plural>` or simply `<table_a>_<table_b>` — `company_db` uses `employee_projects`, matching the pattern used throughout the Rails/Django ecosystem.
- Self-referencing tables (like `employees` with its own `manager_id` column referencing `employees.employee_id`) don't need any special naming convention beyond a clear foreign-key column name — the self-reference is expressed structurally, not lexically.
- Historical/legacy databases you don't control may violate every recommendation here; in that situation, the practical guidance is to *not* fight the existing convention mid-schema — consistency with what's already there beats a "correct" convention applied inconsistently.

### When to use / not use

Apply this course's recommended convention to every **new** schema you
design, without exception. When working against an **existing** schema that
uses a different (but internally consistent) convention, follow that
schema's existing convention rather than introducing a second style.

### Comparisons with related concepts

Naming conventions are downstream of, but distinct from, identifier rules
(§2.3, purely about what's syntactically legal) and case-folding (§2.9,
purely about engine behavior) — conventions are a *human* discipline layered
on top of both.

### Real-world use cases

- Every serious engineering organization has a written SQL/database style guide (even if informal) covering exactly the three decisions in this section — this is one of the most common topics in schema-design code review.
- ORM framework defaults (Rails, Django, SQLAlchemy declarative naming conventions) are built around exactly the `snake_case`, plural-table convention this course recommends, which is part of why it has become the de facto industry default in the PostgreSQL/MySQL ecosystem.

### Practice questions

1. Why does choosing `PascalCase` for PostgreSQL table names impose a permanent cost, in terms of §2.3 and §2.9?
2. Is `attendance` (singular/mass-noun) in `company_db` a violation of the "use plural table names" recommendation? Justify your answer.
3. Propose a naming convention for a new bridge table connecting `projects` and a hypothetical `vendors` table, following the pattern used by `employee_projects`.
4. List three reserved or near-reserved words a careless schema designer might pick as column names, and propose a safe alternative for each.
5. Why does naming a foreign key column `department_id` (matching the parent table's primary key name) make future `JOIN` clauses easier to write correctly?
6. Is there an objectively "correct" choice between singular and plural table names? What is the actual, practically important rule?
7. A legacy schema you've inherited uses singular, quoted `PascalCase` table names throughout. Should you rename everything to match this course's convention? Why or why not?

---

## 2.11 Aliases

### Simple explanation

An alias is a temporary nickname you give a column or table, just for the
duration of one query — usually to make output more readable or to let you
refer to the same table twice.

### Technical explanation

SQL supports two kinds of aliases:

- **Column aliases**: rename a `SELECT`-list expression's output label, via `AS` (optional in most dialects) or simple juxtaposition.
- **Table aliases**: give a table (or subquery, or CTE) a short name usable elsewhere in the same statement, via `AS` (optional in most dialects, but **forbidden** for table aliases in Oracle) or juxtaposition.

Aliases exist only for the lifetime of the single statement they appear in
— they are not persistent objects, unlike views (Chapter 15).

### Why aliases exist

Two independent problems create the need for aliases:

1. **Readability** — `base_salary + bonus` as a raw output column header is ugly and uninformative; `AS total_comp` gives it a meaningful name.
2. **Ambiguity resolution and self-reference** — once a query involves two or more tables (Chapter 7), or the *same* table twice (a self-join), you need a way to say "which occurrence of this table, and which occurrence's `employee_id`, do you mean?" Without aliases, a self-join against `employees` twice would be flatly impossible to write, because `employees.employee_id` would be ambiguous between the two occurrences.

### Full syntax breakdown

```sql
-- Column alias, with AS (recommended, most readable)
SELECT column_expr AS alias_name FROM table_name;

-- Column alias, without AS (legal everywhere, less explicit)
SELECT column_expr alias_name FROM table_name;

-- Table alias, with AS
SELECT t.column FROM table_name AS t;

-- Table alias, without AS (legal in PostgreSQL/MySQL/SQL Server; required style in Oracle)
SELECT t.column FROM table_name t;
```

> **⚠️ Warning [Oracle]:** Oracle does **not** allow the `AS` keyword before
> a **table** alias (though it does allow, and generally expects, `AS`
> before a **column** alias). `SELECT e.first_name FROM employees AS e;`
> raises `ORA-00933: SQL command not properly ended` in Oracle. Always write
> `FROM employees e` (no `AS`) for table aliases if your SQL needs to run on
> Oracle.

### Examples, simple → complex (using `company_db`)

**Example 1 — column alias, with and without `AS`.**

```sql
SELECT first_name AS given_name, last_name AS family_name
FROM employees
WHERE employee_id = 3;

SELECT first_name given_name, last_name family_name   -- equivalent, AS omitted
FROM employees
WHERE employee_id = 3;
```

Expected output (both queries):

```
 given_name | family_name
------------+-------------
 Sneha      | Kulkarni
(1 row)
```

**Example 2 — table alias, shortening a qualified reference.**

```sql
SELECT e.first_name, e.last_name, e.job_title
FROM employees AS e
WHERE e.department_id = 1;
```

**Example 3 — why aliases matter: the self-join, resolving the manager hierarchy.**
`employees.manager_id` references `employees.employee_id` — the *same*
table. To show each employee next to their manager's name, the table must
be referenced twice in one `FROM` clause, and only aliases make that
possible:

```sql
SELECT e.first_name || ' ' || e.last_name AS employee_name,
       m.first_name || ' ' || m.last_name AS manager_name
FROM employees e
JOIN employees m ON e.manager_id = m.employee_id
ORDER BY e.employee_id
LIMIT 5;
```

Expected output:

```
   employee_name   |   manager_name
--------------------+-------------------
 Rahul Mehta        | Aditi Rao
 Sneha Kulkarni     | Rahul Mehta
 Vikram Joshi       | Rahul Mehta
 Ananya Singh       | Rahul Mehta
 Karan Verma        | Sneha Kulkarni
(5 rows)
```

> This uses `JOIN` (Chapter 7) and `LIMIT` (Chapter 4) ahead of their formal
> introduction, purely to demonstrate *why* aliases are indispensable — try
> writing this query's `FROM`/`ON`/`SELECT` clauses without `e`/`m` aliases
> and you'll find it's not just harder to read, it's **impossible**: without
> an alias, `employees.employee_id` in the `ON` clause would be a flatly
> ambiguous reference to two identical, unaliased occurrences of the same
> table.

### Line-by-line explanation (Example 3)

1. `FROM employees e` — the first occurrence of `employees` is given the alias `e`, standing in for "the employee being described."
2. `JOIN employees m` — a second, independent occurrence of the *same table* is given the alias `m`, standing in for "that employee's manager."
3. `ON e.manager_id = m.employee_id` — this is only expressible because `e` and `m` disambiguate which occurrence's columns are meant; without aliases, the engine (and you) would have no way to distinguish `employees.employee_id` (the manager side) from `employees.employee_id` (the report-line side).
4. `e.first_name || ' ' || e.last_name AS employee_name` and the equivalent `m.*` expression are column aliases, applied to computed concatenation expressions, giving the output meaningful headers.
5. `ORDER BY e.employee_id LIMIT 5` restricts and orders the output for a readable example (both covered fully in Chapter 4).

### Internal behavior

During parsing, each `FROM`-clause table reference (with or without an
alias) is registered in the query's **range table** (the internal list of
"named row sources" available to the rest of the statement) under either
its own name or its alias, if one is given. Crucially, **when an alias is
present, the original table name becomes invisible to the rest of the
statement** — you cannot refer to `employees.first_name` in Example 3's
query; only `e.first_name` or `m.first_name` are valid, because the range
table entries are keyed by alias, not by original name, the moment an alias
is introduced. Column aliases, by contrast, are resolved later and are
purely cosmetic for the output row descriptor — they don't participate in
the range table or in the query's own internal `WHERE`/`JOIN` logic at all
(which is also *why* you generally can't reference a `SELECT`-list column
alias inside the same statement's `WHERE` clause, as noted in §2.6).

### Common mistakes

- Writing `AS` before a table alias in Oracle SQL (`FROM employees AS e`) — a guaranteed syntax error there, even though it's fine in PostgreSQL/MySQL/SQL Server.
- Forgetting that once you alias a table, the original name is no longer usable anywhere else in that statement.
- Reusing the same alias for two different tables in one query (an outright ambiguity error) or aliasing so tersely (`a`, `b`, `x`) that the query becomes harder, not easier, to read — a table alias like `e` for `employees` and `m` for `employees-as-manager` is meaningful; `a`/`b` conveys nothing.
- Forgetting an alias is scoped to a single statement — you cannot reuse it in a subsequent, separate query expecting it to still mean something.

### Edge cases

- Correlated subqueries (Chapter 8) *require* table aliases to distinguish an inner query's table reference from an outer query's reference to the same table — another case, like the self-join, where aliases aren't optional style but functionally mandatory.
- Some dialects allow a column alias to be *referenced* in a later clause of the very same query (e.g., **[MySQL]** and **[PostgreSQL]** permit referencing a `SELECT`-list alias inside `GROUP BY`/`ORDER BY`, though not in `WHERE`); this is a dialect-specific extension, not guaranteed standard behavior — verify before relying on it in portable code.

### When to use / not use

Use table aliases whenever a query involves more than one table (virtually
always, from Chapter 7 onward) — even when not strictly required, short
aliases make multi-table SQL dramatically easier to scan. Use column
aliases whenever an expression's default output header would be unclear (an
arithmetic expression, a function call, a `CASE` expression) or whenever the
raw column name isn't the label you want a report/API consumer to see. Skip
column aliases for simple, already-clear single-column references
(`SELECT department_name FROM departments;` needs no alias).

### Comparisons with related concepts

Aliases vs. views (Chapter 15): a view is a **named, persistent, reusable**
query definition; an alias is a **throwaway, statement-scoped** nickname. Aliases
vs. renaming a column/table via DDL (`ALTER TABLE ... RENAME COLUMN`): DDL
renaming is **permanent** and affects every future query; an alias affects
only the one statement it's written in.

### Real-world use cases

- Every non-trivial join query in production reporting SQL uses table aliases — it's close to universal practice from intermediate SQL onward.
- Self-joins for hierarchical data (employee/manager, category/parent-category, comment/parent-comment) are impossible to express without table aliases, and are extremely common in real schemas.
- Business-facing reports consistently use column aliases to turn internal engineering names (`base_salary`, `hours_allocated`) into presentation-ready labels (`"Base Salary"`, `"Hours"`).

### Practice questions

1. Why is a table alias functionally *required*, not merely stylistic, in a self-join against `employees`?
2. Rewrite `SELECT department_name AS name FROM departments;` without using the `AS` keyword.
3. Why does `SELECT e.first_name FROM employees AS e;` fail in Oracle specifically?
4. In the self-join example (Example 3), what would happen if both occurrences of `employees` were left unaliased?
5. Once you write `FROM employees e`, can you still reference `employees.first_name` elsewhere in that same statement? Why or why not?
6. Write a self-join query (conceptually, using `employees`) that lists pairs of employees who share the same `manager_id`, using two aliases.
7. What is the key difference between a table alias and a view, in terms of persistence and scope?

---

## 2.12 Schemas

### Simple explanation

A schema is a named folder inside a database that groups related tables,
views, and other objects together — like a directory groups files.

### Technical explanation

A **schema** is a namespace within a database: a logical container that
holds tables, views, sequences, functions, and other objects, and whose name
becomes part of an object's fully-qualified reference
(`schema_name.table_name`). A single database can contain many schemas.
Schemas exist one level *below* the database itself and one level *above*
individual objects in the standard SQL object hierarchy:

```
server / instance
  └── database
        └── schema
              └── table / view / sequence / function / ...
```

`company_db.sql` demonstrates this directly:

```sql
CREATE SCHEMA company_db;
SET search_path TO company_db;
```

This creates a schema named `company_db` (the name is a coincidence of this
course's example — a schema is not a database, even though this one happens
to share the sample database's conceptual name) and tells the current
session to look inside it by default.

### Why schemas exist

Without schemas, every table name in an entire database would have to be
globally unique — impossible at scale, and a constant naming headache even
at small scale (multiple teams both wanting a table called `users` or
`logs`). Schemas let you namespace objects by team, module, or purpose
(`sales.orders` vs. `inventory.orders`), and let you manage permissions at
the schema level (grant a role access to an entire schema at once) rather
than object-by-object.

### Full syntax breakdown

```sql
-- Create a schema
CREATE SCHEMA schema_name;

-- Fully-qualified object reference
SELECT * FROM schema_name.table_name;

-- [PostgreSQL] search_path: an ordered list of schemas searched,
-- in order, for any unqualified object name
SET search_path TO schema_name, public;

-- Inspect the current search_path
SHOW search_path;
```

### `search_path` [PostgreSQL] vs. the "default schema" in other dialects

| Dialect | Concept | Behavior |
|---|---|---|
| **[PostgreSQL]** | `search_path` | An ordered **list** of schemas searched, in order, for any unqualified name; configurable per-session, per-role, or per-database. Default is typically `"$user", public`. |
| **[MySQL]** | No separate schema/database distinction | In MySQL, **"schema" is literally a synonym for "database"** — `CREATE SCHEMA` and `CREATE DATABASE` are the same operation. There is no extra namespace layer beneath the database; a session's "current database," set via `USE database_name;`, is the equivalent concept. |
| **[Oracle]** | Schema = user | Every Oracle **user** automatically owns exactly one schema, sharing its name; there is no independent `CREATE SCHEMA` step for ordinary use — creating a user implicitly creates its schema. Unqualified references default to the connected user's own schema, plus explicit synonyms. |
| **[SQL Server]** | Default schema per user, typically `dbo` | SQL Server (like PostgreSQL) supports genuinely independent, multiple schemas per database, decoupled from user accounts; each login has a configurable **default schema** (`dbo` unless changed), used to resolve unqualified object names. |

> **Important Note:** This is a genuinely confusing area across dialects
> because the *word* "schema" means different things: in PostgreSQL and SQL
> Server it's an independent namespace layer inside a database; in MySQL
> it's just another word for "database" itself; in Oracle it's tied 1:1 to a
> user account. When reading cross-dialect documentation or Stack Overflow
> answers, always check which meaning is intended.

### Examples, simple → complex

**Example 1 — the schema setup in `company_db.sql` itself.**

```sql
DROP SCHEMA IF EXISTS company_db CASCADE;
CREATE SCHEMA company_db;
SET search_path TO company_db;
```

This drops any pre-existing schema of the same name (and everything inside
it, via `CASCADE`), creates a fresh one, and points the current session's
`search_path` at it so that every subsequent unqualified `CREATE TABLE
departments (...)` in the file lands inside `company_db`, not the default
`public` schema.

**Example 2 — querying with and without schema qualification.**

```sql
-- Unqualified: relies on search_path already including company_db
SELECT * FROM departments;

-- Fully qualified: works regardless of the current search_path
SELECT * FROM company_db.departments;
```

**Example 3 — inspecting and temporarily changing `search_path`.**

```sql
SHOW search_path;
-- e.g. "$user", public

SET search_path TO company_db, public;
SELECT * FROM departments;    -- now resolves against company_db first

SET search_path TO public;
SELECT * FROM departments;    -- ERROR: relation "departments" does not exist, if no such table exists in public
```

### Line-by-line explanation (Example 3)

1. `SHOW search_path;` reveals the ordered list of schemas the current session searches, in order, for any unqualified object reference.
2. `SET search_path TO company_db, public;` overrides that order for the current session only (not persisted beyond the session unless configured at the role/database level).
3. With `company_db` first in the path, `SELECT * FROM departments;` resolves to `company_db.departments`.
4. After resetting `search_path TO public;`, the same unqualified query now looks only inside `public`, and fails if no `departments` table exists there — demonstrating that unqualified names are not fixed, they're resolved dynamically, per session, against whatever the current `search_path` happens to be.

### Internal behavior

When the parser encounters an unqualified table reference, name resolution
does not simply "look it up globally" — it iterates the session's
`search_path` list (in PostgreSQL) in order, checking each schema in turn
for a matching object name, and uses the **first** match found. This means
the same unqualified query text can resolve to entirely different physical
tables depending purely on session state, which is a deliberate feature (it
enables multi-tenant patterns and staging/shadow-schema tricks) but also a
real footgun if `search_path` is ever set unexpectedly.

### Common mistakes

- Assuming `CREATE SCHEMA` in MySQL creates a *sub-namespace* inside a database, when it actually just creates another *database* — a common trip-up for people moving between PostgreSQL/SQL Server and MySQL.
- Forgetting to set/check `search_path` and being confused when an unqualified query "can't find" a table that clearly exists (just in a different schema).
- Relying on a mutable session-level `search_path` inside application code without pinning it explicitly, leading to non-deterministic behavior if the connection pool reuses sessions with different prior `SET search_path` calls (see §2.13).
- In Oracle, trying to `CREATE SCHEMA` as a standalone action the way you would in PostgreSQL, rather than understanding schemas are implicitly created alongside users.

### Edge cases

- If two schemas in the `search_path` both contain a same-named table, the unqualified reference silently resolves to whichever schema appears **first** in the path — a subtle, dangerous ambiguity if not well understood, since no error or warning is raised.
- `public` is a special, pre-existing default schema in vanilla PostgreSQL installs, but as of PostgreSQL 15, newly created databases no longer grant `CREATE` on `public` to all users by default — a security hardening change worth knowing about if you ever wonder why a `CREATE TABLE` inside `public` unexpectedly fails with a permissions error on a fresh install.
- Fully-qualifying every object reference (`company_db.departments`) sidesteps `search_path` ambiguity entirely, at the cost of more verbose SQL — a real, common tradeoff production codebases make deliberately.

### When to use / not use

Use multiple schemas to logically separate concerns within one database
(e.g., `reporting`, `staging`, `audit` alongside your main application
schema) once a project grows past a single-team, single-purpose scale. For
a small project or course-scale example like `company_db`, one schema is
entirely sufficient — don't over-engineer schema separation prematurely.
Always fully-qualify object references in shared, production application
code where `search_path` might not be guaranteed — don't rely on
unqualified resolution across environments you don't fully control.

### Comparisons with related concepts

A schema is not a database — a **database** is the top-level container
managed by the server/instance (with its own connections, its own
transaction log in most engines); a **schema** is a namespace *inside* one
database. Don't confuse `CREATE SCHEMA` (PostgreSQL/SQL Server: a true
sub-namespace) with `CREATE SCHEMA`/`CREATE DATABASE` (MySQL: identical
operations, same concept).

### Real-world use cases

- Multi-tenant SaaS applications sometimes give each tenant its own schema within one shared PostgreSQL database, using `search_path` switching per request to isolate tenant data logically while sharing infrastructure.
- Separating `reporting` (read-heavy, possibly denormalized/materialized views) from the core transactional schema is a common production pattern enabled directly by schemas.
- Database migration tooling frequently uses a dedicated schema (e.g., a `flyway_schema_history` table inside its own or a designated schema) to track applied migrations separately from application tables.

### Practice questions

1. What does `CREATE SCHEMA` actually do in MySQL, compared to what it does in PostgreSQL?
2. In Oracle, how is a schema related to a user account?
3. What is `search_path`, and what happens if two schemas in it both contain a table with the same name?
4. Why might production application code choose to fully-qualify every table reference (`schema.table`) rather than relying on `search_path`?
5. Explain, using `company_db.sql`'s own opening three lines, exactly what `SET search_path TO company_db;` accomplishes and why it's necessary before the subsequent unqualified `CREATE TABLE` statements.
6. What is SQL Server's default schema called, and how is it configured per login?
7. Why did PostgreSQL 15 change default permissions on the `public` schema, and what practical error might this cause on a fresh install if unaccounted for?

---

## 2.13 Sessions and Connections

### Simple explanation

A **connection** is the actual network link your client opens to the
database server. A **session** is everything the server remembers *about*
that connection while it's open — which transaction is in progress, which
schema you're pointed at, which settings you've changed. Closing the
connection ends the session; nothing you set only persists beyond that.

### Technical explanation

- A **connection** is a low-level, authenticated network/socket link between a client process and the database server process, established via a specific protocol (e.g., PostgreSQL's wire protocol, MySQL's protocol, Oracle's Net8/TNS, SQL Server's Tabular Data Stream/TDS). Establishing one typically involves a TCP handshake, authentication (credentials, certificates, or other mechanisms), and negotiation of protocol parameters.
- A **session** is the server-side logical context layered on top of a connection: the current user/role, the current database and schema search context, any open transaction and its isolation level, session-local settings (timezone, `search_path`, locale, temp table visibility), and any temporary objects created during that session's lifetime.
- In most simple setups, one connection maps to exactly one session, ending together — but this is **not universal**: connection poolers (like PgBouncer in **transaction pooling mode**) can multiplex many logical client "sessions" over a smaller number of actual physical database connections, meaning session-local state (like a `SET search_path` from one logical client) can leak into, or be lost between, unrelated subsequent uses of the underlying physical connection. This is one of the most important, most under-appreciated operational facts in production PostgreSQL deployments.

### Why this distinction matters

Understanding the connection/session split explains real, otherwise-mysterious
behavior: why a `SET` statement's effect vanishes when your connection pool
hands you a "fresh" logical connection; why temporary tables (Chapter 24)
disappear between requests in a pooled web application; why one client's
`SET search_path` can seemingly "bleed into" another client's queries when
transaction-mode pooling is misconfigured.

### Full syntax breakdown

```sql
-- Session-scoped settings ([PostgreSQL])
SET search_path TO company_db;
SET TIME ZONE 'Asia/Kolkata';
SHOW search_path;
SHOW TIME ZONE;

-- Session-scoped autocommit behavior
SET autocommit = ON;     -- [MySQL] session variable
SET AUTOCOMMIT = 1;      -- [Oracle] / SQL*Plus internal setting (SQL*Plus-specific spelling)

-- Ending a session
-- (no single universal SQL keyword — typically a client/driver-level "disconnect" action)
```

### Autocommit, compared across dialects

**Autocommit** determines whether each individual statement is committed to
the database immediately and independently (autocommit ON, the common
default) or whether statements accumulate inside an implicit/open
transaction until an explicit `COMMIT` is issued (autocommit OFF).

| Dialect | Default autocommit behavior |
|---|---|
| **[PostgreSQL]** | ON by default — every standalone statement commits immediately unless you explicitly `BEGIN` a transaction |
| **[MySQL]** | ON by default — same behavior, controllable via the session/global `autocommit` variable |
| **[SQL Server]** | ON by default ("autocommit transaction mode") — same behavior, unless overridden with `SET IMPLICIT_TRANSACTIONS ON` or explicit `BEGIN TRANSACTION` |
| **[Oracle]** | Historically **OFF by default** in tools like SQL*Plus — DML you run is *not* durable until you explicitly `COMMIT`, and many tools implicitly commit on a graceful `EXIT`/disconnect but not on a crash. Many modern GUI tools (SQL Developer, etc.) default their own autocommit setting ON for convenience, which is a *tool* choice layered on top of Oracle's underlying transactional behavior, not a change to the database engine's own default. |

> **⚠️ Warning [Oracle]:** Because of this historical default, a common
> real-world incident is: an analyst runs an `UPDATE` in a raw Oracle
> session via a script or minimal client, the process is killed or the
> connection drops abnormally before an explicit `COMMIT`, and the change is
> silently lost — with no error at all, because from the database's point
> of view nothing was ever finalized. Always know your specific client
> tool's autocommit default before assuming a change is durable.

### Examples

**Example 1 — a session-scoped setting affecting query behavior.**

```sql
SET search_path TO company_db;
SELECT * FROM departments;     -- resolves against company_db for the rest of this session
```

If this session ends and a new connection is opened, `search_path` reverts
to whatever the role/database default is — the `SET` was never persistent,
only session-local.

**Example 2 — autocommit ON (default) vs. an explicit transaction.**

```sql
-- Autocommit ON (default): each statement is durable immediately
UPDATE employees SET status = 'ON_LEAVE' WHERE employee_id = 6;
-- Already committed. No further action needed or possible to "undo" via ROLLBACK.

-- Explicit transaction: suspends autocommit for these statements only
BEGIN;
UPDATE employees SET status = 'ON_LEAVE' WHERE employee_id = 6;
-- Not yet durable; visible only within this session until COMMIT.
ROLLBACK;   -- change is fully undone
```

**Example 3 — inspecting session settings.**

```sql
SHOW search_path;
SHOW TIME ZONE;
SELECT current_user, current_database(), current_schema();
```

Expected output (illustrative — exact values depend on your local setup):

```
 current_user | current_database |  current_schema
---------------+-------------------+------------------
 pthube        | postgres          | company_db
(1 row)
```

### Line-by-line explanation (Example 2)

1. Under default autocommit, the first `UPDATE` is treated as its own complete, one-statement transaction — the instant it succeeds, it is durable, full stop.
2. `BEGIN;` explicitly suspends autocommit for the following statements, opening a multi-statement transaction.
3. The second `UPDATE` inside that block is provisional — visible to the current session, invisible to other sessions, and reversible.
4. `ROLLBACK;` discards it entirely, as if it never ran; had the block ended with `COMMIT;` instead, it would have become just as durable as the first `UPDATE`.

### Internal behavior

Each session on the server maintains its own **session state** structure:
current transaction ID/snapshot, current settings (a layered set of
GUC/session variables in PostgreSQL terms), and a list of session-local
temporary objects. A connection pooler operating in *session mode* maps one
client to one backend session for the connection's full lifetime — safe for
all session-state assumptions. A pooler operating in *transaction mode*
(common for scaling web applications) instead returns the physical backend
connection to a shared pool **between transactions**, potentially handing it
to a completely different logical client next — meaning any session-level
`SET` (like `search_path` or a session variable) issued outside of a
transaction can "stick" to the wrong physical connection and be seen,
incorrectly, by an unrelated subsequent client. This is precisely why
production guidance for tools like PgBouncer in transaction mode explicitly
warns against relying on session-level state at all.

### Common mistakes

- Assuming a `SET search_path` or session variable persists across reconnects — it never does; it must be re-applied per session (often via a startup parameter, connection string option, or `init` hook in your driver/pool config instead of an ad hoc `SET`).
- Working in Oracle SQL*Plus, making changes, and disconnecting abruptly (killing the terminal) without an explicit `COMMIT`, then being surprised the changes are gone.
- Assuming that because autocommit is ON, wrapping several related statements without an explicit `BEGIN`/`COMMIT` still gives you "all or nothing" behavior — it does not; each statement commits independently, so a failure partway through a multi-statement script under autocommit can leave your data in a partially-updated state (this is precisely why Chapter 11 on Transactions matters so much).
- Confusing "connection" and "session" as always being 1:1, leading to real production bugs under connection pooling.

### Edge cases

- Temporary tables (Chapter 24) are, in most dialects, session-scoped by default — they vanish automatically when the session ends, which interacts directly with pooling: a temp table created in one "logical request" under transaction-mode pooling may unexpectedly still exist (or not) for the next request depending on pooling mode.
- Some session settings (like PostgreSQL's `search_path`) can be set as a **per-role default** (`ALTER ROLE myuser SET search_path TO company_db;`), which reapplies automatically at the start of every future session for that role — a good way to get "persistent-feeling" behavior without relying on a fragile ad hoc `SET` per connection.
- Long-idle sessions holding open transactions (forgotten `BEGIN` with no `COMMIT`/`ROLLBACK`) can block maintenance operations (like `VACUUM` in PostgreSQL, discussed in Chapter 29) — a real operational hazard, not just a theoretical concern.

### When to use / not use

Rely on session-level `SET` commands for genuinely session-scoped
adjustments (temporary debugging, a one-off analysis session's timezone).
For anything that must be reliably true for **every** connection your
application ever opens, configure it at the role or database level instead
(`ALTER ROLE ... SET ...`, or driver/connection-string parameters), because
you cannot guarantee session-level `SET` calls survive pooling or
reconnection.

### Comparisons with related concepts

A session is not a transaction — a single session commonly contains many
sequential transactions over its lifetime (each autocommitted statement is
technically its own tiny transaction). A connection is not a user/role — one
role can have many simultaneous connections/sessions open at once, from
different client machines or application instances.

### Real-world use cases

- Web application connection pools are configured with an explicit understanding of session vs. transaction pooling mode specifically because of the state-leakage risk described above.
- DBAs regularly query system views (`pg_stat_activity` in PostgreSQL) to inspect *live sessions* — separate from raw connection counts — to diagnose long-running transactions or idle-in-transaction sessions blocking maintenance.
- Setting a role-level default `search_path` (`ALTER ROLE reporting_user SET search_path TO reporting, public;`) is a standard production pattern to guarantee consistent schema resolution regardless of how a session was opened.

### Practice questions

1. Define, in your own words, the difference between a connection and a session.
2. Why does a `SET search_path TO company_db;` issued in one `psql` session have no effect on a separate, simultaneously open `psql` session?
3. What is Oracle's historically distinctive default regarding autocommit, and what real-world incident can result from not knowing it?
4. Why is autocommit being "ON" not the same guarantee as "my multi-statement script will apply all-or-nothing"?
5. Explain why connection poolers running in "transaction mode" pose a specific risk to session-level `SET` statements.
6. How could you make a `search_path` setting effectively "permanent" for a given database role, without relying on a per-session `SET` call?
7. Why might a long-idle session with an open, uncommitted transaction be an operational problem for a DBA, beyond just "using up a connection slot"?

---

## 2.14 The SQL Dialect Landscape

### Simple explanation

"SQL" is a standard, but no database implements it exactly the same way —
each major product ("dialect") follows the shared core closely while adding
its own extensions, quirks, and historical baggage. Knowing the landscape
means knowing what's truly universal versus what's dialect-specific, so you
never get blindsided moving between systems.

### Technical explanation

The SQL standard is maintained jointly by ISO and ANSI (formally
ISO/IEC 9075, colloquially "ANSI SQL"), revised periodically (SQL-86, SQL-89,
SQL-92, SQL:1999, SQL:2003, SQL:2008, SQL:2011, SQL:2016, SQL:2023 being
the most-referenced milestones). No commercial or open-source database
implements the full standard, and every one of them adds proprietary
extensions. "Standards compliance" is therefore always a matter of degree,
not an absolute.

### Why dialects diverge at all

Divergence happens for a mix of historical, competitive, and technical
reasons: some engines predate a given standard revision and never fully
retrofitted it; some deliberately add proprietary features as a competitive
moat (procedural extensions like Oracle's PL/SQL or Microsoft's T-SQL);
some make pragmatic implementation choices the standard left underspecified
(identifier case folding is technically standard-mandated to fold to
uppercase, yet PostgreSQL deliberately folds to lowercase instead, a
divergence that has stood for decades because changing it now would break
enormous amounts of existing code).

### The Big Four, one-liner histories

- **[PostgreSQL]** — Descended from the academic POSTGRES project at UC Berkeley (Michael Stonebraker, mid-1980s); gained SQL support and was renamed Postgres95, then PostgreSQL, in 1996; fully open-source (PostgreSQL License) ever since, with no single controlling company; widely regarded as the most standards-compliant of the four, and the one with the most active adoption of newer SQL-standard features (window functions, CTEs, `MERGE`, and JSON support all arrived comparatively early or comprehensively).
- **[MySQL]** — Released in 1995 by MySQL AB (Sweden); became the "M" in the once-ubiquitous LAMP stack (Linux/Apache/MySQL/PHP); acquired by Sun Microsystems in 2008, then by Oracle Corporation in 2010 (Oracle now owns both MySQL and its own eponymous database); historically looser standards compliance and permissive default behaviors (though modern versions, especially 8.0+, have tightened significantly, adding window functions, CTEs, and stricter default SQL modes); the open-source fork **MariaDB**, created by MySQL's original author after the Oracle acquisition, is a closely related but independently evolving dialect.
- **[Oracle]** — Oracle Database traces to 1979's Oracle V2, one of the very first commercially available relational databases (from what was then Relational Software Inc., later Oracle Corporation); dominant in large enterprise/mission-critical deployments for decades; known for its powerful procedural extension **PL/SQL**, deep tooling, and historically strict, standard-hewing behaviors that predate many later standard revisions (hence quirks like uppercase identifier folding and the mandatory `FROM dual`).
- **[SQL Server]** — Microsoft SQL Server originated from a mid-1980s partnership with Sybase (whose own engine, Sybase SQL Server, is a distant technical cousin); Microsoft took over sole development after the partnership ended in the early 1990s; historically Windows-only, but has shipped on Linux and in containers since SQL Server 2017; uses the procedural extension **T-SQL** (Transact-SQL), broadly comparable in role to Oracle's PL/SQL.

### Standards-compliance notes

> **Important Note:** None of the four is "fully SQL-standard compliant" —
> the standard itself is enormous, and every vendor implements a practical
> subset plus extensions. As a rough, defensible generalization for this
> course: **PostgreSQL** tracks the modern standard most closely and adds
> the fewest surprising proprietary deviations; **Oracle** and **SQL
> Server** are both very mature, standards-aware, but carry significant
> proprietary procedural ecosystems (PL/SQL, T-SQL) and some long-standing
> historical quirks; **MySQL** has historically prioritized ease-of-use and
> performance over strict standards adherence, though this gap has narrowed
> substantially in MySQL 8.0+.

### Key syntactic differences reference table

You will reference this table repeatedly throughout the rest of this
course. Bookmark it.

| Feature | **[PostgreSQL]** | **[MySQL]** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Row limiting | `LIMIT n OFFSET m` | `LIMIT m, n` or `LIMIT n OFFSET m` | `FETCH FIRST n ROWS ONLY` (12c+); `ROWNUM` (legacy, pre-12c) | `TOP (n)`; `OFFSET m ROWS FETCH NEXT n ROWS ONLY` (2012+) |
| String concatenation | `\|\|` | `CONCAT(a, b)` (`\|\|` is logical OR unless `PIPES_AS_CONCAT` mode) | `\|\|` | `+` (also `CONCAT(a, b)`) |
| Identifier quoting | `"double quotes"` | `` `backticks` `` (or `"..."` with `ANSI_QUOTES` mode) | `"double quotes"` | `[square brackets]` (or `"..."` with `QUOTED_IDENTIFIER ON`) |
| Unquoted identifier folding | lowercase | not folded (case-sensitivity depends on OS / `lower_case_table_names`) | UPPERCASE | not folded; comparisons typically case-insensitive by default collation |
| Auto-increment | `SERIAL` / `GENERATED ... AS IDENTITY` | `AUTO_INCREMENT` | `GENERATED ... AS IDENTITY` (12c+); `SEQUENCE` + trigger (pre-12c) | `IDENTITY(seed, increment)` |
| Boolean type | native `BOOLEAN` (`TRUE`/`FALSE`) | `TINYINT(1)` convention (`TRUE`/`FALSE` are aliases for `1`/`0`) | no native table-column boolean before 23c; simulated via `CHAR(1)`/`NUMBER(1)` | `BIT` (`1`/`0`) |
| "Dummy" one-row table requirement | not required (`SELECT 1;` is valid) | not required | **required**: `SELECT 1 FROM dual;` | not required |
| Default schema/namespace concept | `search_path` (ordered schema list) | schema = database (no extra layer) | schema = user (1:1) | default schema per login, typically `dbo` |
| Comment syntax | `--`, `/* */` (nested block comments allowed) | `--`, `/* */`, `#` | `--`, `/* */` | `--`, `/* */` |
| Statement/batch separator quirks | plain `;` | `;`; `DELIMITER` needed for routine bodies in the CLI client | plain `;` (`/` used in SQL*Plus to execute a buffered PL/SQL block) | plain `;`; `GO` batch separator in client tools (not a T-SQL keyword) |
| Case-insensitive `LIKE` | `ILIKE` (PostgreSQL extension) | `LIKE` is case-insensitive by default under common `_ci` collations | `LIKE` is case-sensitive by default | `LIKE` case-sensitivity follows database/column collation |
| Upsert syntax | `INSERT ... ON CONFLICT DO UPDATE` | `INSERT ... ON DUPLICATE KEY UPDATE` | `MERGE` | `MERGE` |

> **⚠️ Warning:** This table is intentionally focused on the differences
> most likely to trip you up while working through *this* course's later
> chapters (pagination in Chapter 4, upserts in Chapter 31, auto-increment
> in Chapter 13, etc.). It is not an exhaustive dialect reference — treat it
> as a first-stop cheat sheet, not the final word; Chapter 37's cheat sheets
> revisit and expand this material.

### Examples across dialects: the same intent, four ways

**Intent: get the 3 most recently hired employees.**

```sql
-- [PostgreSQL] / [MySQL]
SELECT first_name, last_name, hire_date
FROM employees
ORDER BY hire_date DESC
LIMIT 3;

-- [SQL Server]
SELECT TOP (3) first_name, last_name, hire_date
FROM employees
ORDER BY hire_date DESC;

-- [Oracle] (12c+)
SELECT first_name, last_name, hire_date
FROM employees
ORDER BY hire_date DESC
FETCH FIRST 3 ROWS ONLY;

-- [Oracle] (legacy ROWNUM pattern, pre-12c — note ROWNUM is applied
-- BEFORE ORDER BY unless wrapped in a subquery, a classic Oracle gotcha)
SELECT first_name, last_name, hire_date
FROM (
    SELECT first_name, last_name, hire_date
    FROM employees
    ORDER BY hire_date DESC
)
WHERE ROWNUM <= 3;
```

Expected output (PostgreSQL/MySQL/Oracle 12c+/SQL Server, same logical result):

```
 first_name | last_name | hire_date  
------------+-----------+------------
 Aman       | Chawla    | 2022-01-10
 Meera      | Pillai    | 2021-03-22
 Pooja      | Reddy     | 2020-10-05
(3 rows)
```

**Intent: concatenate an employee's full name.**

```sql
-- [PostgreSQL] / [Oracle]
SELECT first_name || ' ' || last_name AS full_name FROM employees WHERE employee_id = 1;

-- [MySQL]
SELECT CONCAT(first_name, ' ', last_name) AS full_name FROM employees WHERE employee_id = 1;

-- [SQL Server]
SELECT first_name + ' ' + last_name AS full_name FROM employees WHERE employee_id = 1;
```

All four produce: `Aditi Rao`.

### Line-by-line explanation (ROWNUM legacy pattern)

1. The inner query performs the actual `ORDER BY hire_date DESC` first, as its own complete, independent result set.
2. The outer query then applies `WHERE ROWNUM <= 3` against that already-sorted result.
3. This two-level wrapping is necessary because, in legacy Oracle, `ROWNUM` is assigned to rows **as they are produced**, before any `ORDER BY` in the *same* query level is applied — applying `WHERE ROWNUM <= 3` directly alongside `ORDER BY hire_date DESC` in one query level would filter to 3 arbitrary pre-sort rows and *then* sort just those 3, which is almost never the intended result.
4. Oracle 12c's `FETCH FIRST n ROWS ONLY` was introduced specifically to eliminate the need for this error-prone subquery pattern.

### Internal behavior note

Every dialect's parser is built from the same conceptual family of grammar
rules (an SQL-92/SQL:2016-derived grammar), but each vendor's grammar is an
independently maintained, extended fork — which is precisely why a
syntactically valid `LIMIT 3` clause is a hard parse error in Oracle
(`ORA-00933`) even though the *concept* it expresses (row limiting) exists
in every dialect. There is no shared parser across vendors; "SQL" is a
specification multiple independent teams each implement their own way.

### Common mistakes

- Writing `LIMIT`/`TOP`/`ROWNUM` code and assuming it's portable without checking the target dialect.
- Applying `WHERE ROWNUM <= n` alongside `ORDER BY` in the same Oracle query level, expecting it to mean "the top n after sorting" (it does not, as shown above).
- Assuming `||` works everywhere (it silently means logical OR by default in MySQL, not concatenation).
- Assuming a schema built with unquoted `PascalCase` identifiers will "just work" identically when migrated between PostgreSQL (folds lowercase) and Oracle (folds uppercase) — the identifiers won't match without explicit remediation.

### Edge cases

- MySQL's `PIPES_AS_CONCAT` SQL mode can be enabled to make `||` behave as string concatenation there too — but relying on a non-default mode setting in shared/portable code is fragile unless you fully control server configuration.
- Oracle's `dual` table requirement is so ingrained that even a `SELECT 5 + 3;` with no real table involved needs `SELECT 5 + 3 FROM dual;` — a detail that surprises almost everyone coming from another dialect for the first time.
- SQL Server's `TOP` without `ORDER BY` returns an arbitrary, storage-order-dependent set of rows — always pair `TOP`/`LIMIT`/`FETCH FIRST` with an explicit `ORDER BY` in every dialect if you need deterministic results (formally covered in Chapter 4).

### When to use / not use

When writing code meant to run on exactly one target dialect (typical in a
single production application), use that dialect's native, idiomatic
syntax freely — don't over-engineer portability you don't need. When
writing code, documentation, or teaching material meant to generalize
across dialects (like this course), always call out the dialect-specific
form explicitly, exactly as this chapter's `[PostgreSQL]`/`[MySQL]`/
`[Oracle]`/`[SQL Server]` tags do throughout.

### Comparisons with related concepts

The "dialect" concept is orthogonal to everything else in this chapter —
every rule about identifiers, literals, operators, and case sensitivity
discussed above is *itself* dialect-flavored, which is exactly why this
section exists as a capstone reference tying all of it together.

### Real-world use cases

- Companies migrating from Oracle to PostgreSQL (a very common, often
  cost-driven migration) run into nearly every difference in the table
  above: `ROWNUM`/`FETCH FIRST` → `LIMIT`, `dual`-table queries needing
  cleanup, identifier case-folding direction flipping from uppercase to
  lowercase, and `MERGE` syntax differences.
- Multi-database application frameworks and query builders (e.g., ORMs)
  exist largely *to* abstract over this exact table — understanding it
  directly explains why ORM-generated SQL looks different depending on
  which database driver you configure.
- Interview questions at the intermediate level very frequently probe this
  table directly ("how do you get the top N rows in Oracle vs. PostgreSQL"
  is a genuinely common real-world/interview question, revisited in
  Chapter 33's interview bank).

### Practice questions

1. Name the row-limiting syntax for PostgreSQL, MySQL, Oracle (12c+), and SQL Server.
2. Why does `WHERE ROWNUM <= 3 ORDER BY hire_date DESC` in a single Oracle query level not reliably return "the 3 most recently hired employees"? What's the fix?
3. What does `||` mean in MySQL by default, and why is this dangerous for code ported from PostgreSQL or Oracle?
4. Why does Oracle require `FROM dual` for a query with no real table involved?
5. Fill in this table's "Auto-increment" row from memory, for all four dialects, without looking back.
6. Give one concrete reason "schema" means something different in MySQL than it does in PostgreSQL or SQL Server.
7. Explain why no single "SQL parser" exists across all four dialects, even though they all claim to implement "SQL."
8. A recruiter asks: "Which of the four dialects is most standards-compliant, and why does that claim need to be qualified rather than absolute?" Answer in 3–4 sentences.

---

## Chapter Challenge

Using only `company_db` and only the concepts introduced in this chapter
(no `GROUP BY`, no window functions, no subqueries beyond what's shown
above — those come later), write a single, well-commented SQL script that:

1. Opens with a **block comment** header explaining the script's purpose (e.g., "ad hoc report: management chain for Engineering department").
2. Uses an explicit **transaction** (`BEGIN` / `COMMIT`) around a harmless housekeeping `UPDATE` — set `employees.status` for `employee_id = 6` to `'ACTIVE'` (it already is, so this is a safe no-op change) — purely to demonstrate correct TCL usage; **roll it back** instead of committing, to prove you understand `ROLLBACK` restores the prior state.
3. Outside that transaction, writes a **read-only** query (proper DML/DQL) that:
   - Uses a **self-join** with clear, meaningful **table aliases** (not `a`/`b`) to pair every employee in `department_id = 1` with their manager's name.
   - Uses a **column alias** (with `AS`) to label the concatenated full-name columns.
   - Uses a **`CASE` expression** to label each employee's `status` as a human-readable phrase (reusing the pattern from §2.6).
   - Filters using at least one **comparison operator** and one **logical operator** together, with unambiguous parentheses, to include only employees hired on or after `2016-01-01` **and** whose status is not `'TERMINATED'`.
   - Orders the output by `hire_date` (ordering syntax itself is fully covered in Chapter 4, but a simple `ORDER BY column;` is fair game here).
4. Includes at least one **single-line comment** explaining *why* the `NOT status = 'TERMINATED'` filter is written that way rather than `status <> 'TERMINATED'` (they behave identically here — explain why, referencing §2.5's three-valued logic discussion and the fact that `employees.status` is `NOT NULL`).
5. Ends with a short comment block noting **one concrete syntax difference** this exact script would need if it were rewritten to run on **[Oracle]**, and one it would need for **[SQL Server]** — referencing §2.14's table directly.

There is no single correct script — the challenge is testing whether you
can combine statement categories, aliases, expressions, operators,
comments, and transaction control correctly and legibly in one piece of
real SQL. As with the rest of this course, answers and worked solutions
live in the companion challenge/answer materials, not in this chapter.

---

## Key Takeaways

- SQL statements fall into four (or five, counting `SELECT`/DQL separately) categories — **DDL, DML, DCL, TCL** — and knowing which category a statement belongs to tells you its transactionality, permission model, and blast radius.
- **Keywords** are always case-insensitive; **identifiers** are case-sensitive only when quoted, and each dialect folds *unquoted* identifiers differently (PostgreSQL → lowercase, Oracle → UPPERCASE, MySQL/SQL Server → largely unfolded but with their own case-sensitivity quirks).
- **Literals** (string, numeric, date, boolean, null) are the fixed values you embed directly in SQL text; `NULL` is not comparable with `=` — always use `IS NULL`/`IS NOT NULL`.
- **Operators** combine into **expressions**; SQL's comparison and logical operators use **three-valued logic** (`TRUE`/`FALSE`/`UNKNOWN`), which is essential to understanding how `NULL` propagates through conditions.
- **Comments** (`--`, `/* */`) and consistent **statement termination** (`;`) are small mechanics with outsized real-world debugging consequences (unterminated comments, missing semicolons).
- **Case sensitivity** has three independent layers — keywords, identifiers, and string data — and confusing them is one of the most common beginner mistakes in all of SQL.
- This course's recommended **naming convention** — lowercase `snake_case`, plural table names, no reserved words as identifiers — is exactly what `company_db.sql` itself follows, and exists to sidestep the case-folding and quoting issues covered earlier in the chapter.
- **Aliases** are not just cosmetic — table aliases are functionally required for self-joins and correlated subqueries, and Oracle specifically forbids `AS` before a table alias.
- A **schema** is a namespace inside a database, resolved via `search_path` in PostgreSQL, and means something different (database, user, or independent namespace) in each of the other three dialects.
- A **connection** is the network link; a **session** is the server-side state layered on top of it; **autocommit** defaults differ meaningfully across dialects (notably Oracle's historical off-by-default behavior).
- The **SQL Dialect Landscape** table in §2.14 (row limiting, concatenation, quoting, auto-increment, and more) is a reference you'll return to constantly for the rest of this course.

## What's Next

Chapter 3 puts this vocabulary to work: **CRUD — SELECT, INSERT, UPDATE,
DELETE**. You now know what a statement, identifier, literal, operator,
expression, alias, and schema are; Chapter 3 teaches the four core DML
statements in full syntactic depth — every clause of `SELECT`, safe and
unsafe `INSERT` patterns, `UPDATE`/`DELETE` with and without a `WHERE`
clause (and why forgetting one is one of the most infamous mistakes in all
of SQL) — all built directly on the `company_db` schema you've now seen in
full.
