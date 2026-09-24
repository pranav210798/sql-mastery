# Chapter 1 — Database Foundations

> **Before you start:** No SQL is required to read this chapter — it is entirely conceptual. Every example still uses the real `company_db` schema and seed data from `databases/company_db.sql`, so once you reach Chapter 2 and start typing queries, the tables, columns, and rows you already reasoned about here will be sitting in front of you unchanged.

## How to read this chapter

Each major idea is explained in five layers: a plain-language analogy, a precise technical definition, the *problem it solves*, worked examples against `company_db`, and then common mistakes, edge cases, and when (not) to use it. Practice questions sit at the end of each section — this is a book, not an answer key, so work them out on paper or in your head before Chapter 2 lets you check yourself by actually running queries.

The `company_db` schema has seven tables, and you will see all of them repeatedly in this chapter:

```
company_db
├── departments        (5 rows)   department_id, department_name, location, created_at
├── employees          (16 rows)  employee_id, first_name, last_name, email, hire_date,
│                                 job_title, department_id, manager_id, status, created_at
├── managers            (5 rows)  manager_id, department_id, appointed_date
├── salaries            (20 rows) salary_id, employee_id, base_salary, bonus, currency,
│                                 effective_date
├── attendance          (10 rows) attendance_id, employee_id, work_date, status,
│                                 check_in, check_out
├── projects             (5 rows) project_id, project_name, department_id, start_date,
│                                 end_date, budget
└── employee_projects   (12 rows) employee_id, project_id, role, hours_allocated
```

Keep this map nearby; every example below refers back to it.

---

## 1.1 What Is Data?

**In plain language:** Data is just *raw facts* — numbers, words, dates — before anyone has explained what they mean. `"Sneha"`, `180000`, `2017-01-20` are data. They are true, but on their own they don't tell you a story.

**In technical terms:** Data is the smallest recorded representation of a fact — a value with no context attached. Once data is organized, labeled, and given meaning (relationships, structure, interpretation), it becomes **information**.

**Why this distinction matters:** Every database exists to turn scattered data into queryable information. If I hand you the bare value `210000`, it's meaningless. If I tell you "`210000` is `base_salary` for `employee_id = 3` (Sneha Kulkarni) effective `2022-01-01`," it becomes information you can act on — that's exactly what the `salaries` table row does:

```sql
-- One row = data given context = information
salary_id | employee_id | base_salary | bonus | currency | effective_date
----------+-------------+-------------+-------+----------+---------------
    6     |      3      |  210000.00  | 25000 |   USD    |  2022-01-01
```

**Examples, simple to complex:**
1. Raw data: `'Rao'`, `1`, `'CTO'` — three unconnected fragments.
2. Structured into a row: `(1, 'Aditi', 'Rao', 'aditi.rao@company.com', '2015-03-01', 'CTO', 1, NULL, 'ACTIVE')` — now it's clearly one employee record.
3. Aggregated into information: "Engineering (`department_id = 1`) has 6 active employees" — a fact *derived* from many rows of data, which is what SQL's `GROUP BY` (Chapter 6) will let you compute.

**Common mistakes:** Beginners often say "data" and "information" interchangeably in casual speech — harmless day to day, but in database design the distinction matters because your job as a schema designer is literally "decide how raw facts get structured into meaningful, queryable information."

**When it matters:** Whenever you design a table, you're deciding which raw facts (columns) deserve to be recorded, and how they relate to each other so that meaning (information) can be reconstructed later via queries.

**Practice questions:**
1. Classify each as "raw data" or "information": `'Mumbai'`; "Priya Nair manages the Sales department located in Mumbai"; `450000`; "Aditi Rao's base salary increased from 450000 to 520000 in 2020."
2. List five raw data values you can see directly in the `employees` table's seed rows.
3. Explain, in your own words, why a spreadsheet cell containing `16` is "data" but the sentence "Employee 16, Aman Chawla, joined Engineering in 2022" is "information."
4. Why can't a database engine understand *meaning* on its own — what has to be added by the schema designer (you) to make raw values meaningful?
5. Give a real-world (non-company_db) example of data becoming information after aggregation.

---

## 1.2 What Is a Database?

**In plain language:** A database is an organized container for related facts — think of it as a well-organized filing cabinet, where every drawer (table) holds a specific kind of form (row), and every form has the same fields (columns) filled in a consistent way. Compare that to a messy pile of sticky notes: same information, but useless when you need to find one fact quickly.

**In technical terms:** A database is a structured, persistent collection of related data, organized so it can be efficiently stored, retrieved, modified, and secured. "Persistent" means it survives after the program that created it closes — unlike a variable in memory.

**Why it exists:** Before databases, applications stored data in flat files (think plain `.txt` or `.csv` files). That works until you need to: find one record quickly, prevent two people from corrupting the same file at once, guarantee that related facts stay consistent (e.g., you never have a salary row pointing to an employee that doesn't exist), or query across huge volumes of data. A database engine solves all of that.

**Example — `company_db` as a database:** It is one coherent unit containing seven related tables. You never have to manually keep `employees` and `salaries` "in sync" yourself — the database's referential integrity (Section 1.12) does it. Compare that to keeping employees in one spreadsheet and salaries in another: nothing stops someone from deleting a row from one and forgetting the other, silently corrupting your records.

**What happens internally:** A database is not just "the data" — it is data files on disk (heap pages, index pages), a transaction log (WAL in PostgreSQL) for durability and crash recovery, and metadata (catalogs) that describe the very structure of the database (which tables exist, what their columns are, which constraints apply). When you run `psql -f databases/company_db.sql`, PostgreSQL writes all of this to disk under the hood — you only see the logical CREATE TABLE/INSERT statements.

**Common mistakes:**
- Confusing "the database" with "the DBMS software" — PostgreSQL is the *software*; `company_db` is a *schema of data* living inside a PostgreSQL-managed database.
- Assuming a database is just "a big Excel file." Excel has no built-in mechanism to enforce that `employees.department_id` always points to a real row in `departments` — a real database does, via foreign keys.

**Edge cases:** A database can have zero rows and still be a valid, fully-defined database — structure (schema) and data (content) are separate concerns. `company_db` before its `INSERT` statements run is a real, valid, empty database.

**When to use / not use:** Use a database when data must be shared across users/processes, must remain consistent under concurrent access, must survive crashes, or is queried in flexible/unplanned ways. A flat file is still fine for a one-off, single-user, throwaway dataset with no relationships to preserve.

**Real-world use cases:** Payroll systems (our `salaries` table), e-commerce catalogs, banking ledgers, hospital records, social media graphs — anything where facts must stay correct and queryable at scale.

**Practice questions:**
1. In your own words, what does "persistent" mean, and why does it matter for `company_db`?
2. Name three problems a flat CSV file of employees would have that the `employees` + `departments` + `salaries` design avoids.
3. Is `company_db` (as created by the SQL script) a "database" or a "schema" in PostgreSQL's terminology? (Hint: re-read the `CREATE SCHEMA` line at the top of the file — you'll formalize this in Section 1.7.)
4. What component of a database is responsible for surviving a server crash without losing committed data?
5. Give an example of a real organization-wide need (not company_db) that would be poorly served by a plain text file.

---

## 1.3 What Is a DBMS?

**In plain language:** If the database is the filing cabinet, the DBMS is the librarian — the software that knows how to file things correctly, retrieve them fast, stop two people from grabbing the same folder and tearing it, and rebuild the cabinet if the building catches fire.

**In technical terms:** A **Database Management System (DBMS)** is software that creates, reads, updates, deletes, and manages databases — providing a controlled interface between users/applications and the raw stored data, while handling concurrency, security, integrity, and recovery.

**Why it exists:** Applications shouldn't have to reinvent "how do I safely write to disk without corrupting data if the power goes out mid-write" or "how do I stop two people from double-booking the same seat." The DBMS provides these as reusable guarantees so every application built on top of it inherits them for free.

**What a DBMS actually does (its responsibilities):**
| Responsibility | What it means for `company_db` |
|---|---|
| Data storage & retrieval | Physically stores `employees` rows on disk pages and finds them again on request |
| Data definition | Lets you `CREATE TABLE employees (...)` and defines the schema |
| Data manipulation | Lets you `INSERT`/`UPDATE`/`DELETE`/`SELECT` rows |
| Concurrency control | Stops two transactions from corrupting `salaries` if both update it at once (Chapter 12) |
| Integrity enforcement | Rejects an `employees` row whose `status` isn't `'ACTIVE'`, `'ON_LEAVE'`, or `'TERMINATED'` (the `CHECK` constraint) |
| Security | Controls who can even see or modify `salaries.base_salary` |
| Backup & recovery | Lets you restore `company_db` if disk fails (Chapter 28) |

**Examples of DBMS software:** PostgreSQL, MySQL, Oracle Database, Microsoft SQL Server, SQLite, MongoDB (a *non*-relational DBMS). Note: some of these are RDBMSs specifically (Section 1.4); MongoDB is a DBMS but not an RDBMS.

**Internals, briefly:** When you run `SELECT * FROM employees WHERE department_id = 1;`, the DBMS's *query parser* checks syntax, the *planner/optimizer* decides how to fetch the rows (scan the whole table? use an index?), the *executor* runs that plan against the *storage engine*, and the result is streamed back to you. You'll go deep on every one of these stages in Chapters 16–18 and 29.

**Common mistakes:** Saying "MySQL is a database" — it's a DBMS; the databases are the things you create *inside* it. Similarly, "PostgreSQL is a database" is a very common but imprecise phrase people use loosely; be precise in this course.

**When to use / not use:** You always want a DBMS once more than one process/user touches the data, once you need guarantees against corruption, or once your querying needs are non-trivial. For a single script reading a one-time 10-row CSV, a full DBMS is overkill.

**Real-world use cases:** Every product you've used with an account, a cart, a feed, or a transaction history is backed by a DBMS.

**Practice questions:**
1. List the six responsibilities of a DBMS given above, in your own words, using a `company_db` example for each.
2. Why can't an application safely "just write directly to files" instead of using a DBMS when multiple users are involved?
3. Name three real DBMS products.
4. Is a DBMS software, hardware, or data? Justify your answer.
5. What DBMS-provided guarantee stops a half-completed transfer of an employee to a new department from corrupting the `employees` table if the server crashes mid-update? (You'll learn the formal name — ACID — in Chapter 11.)

---

## 1.4 What Is an RDBMS?

**In plain language:** An RDBMS is a DBMS that insists on organizing everything into *tables* — neat grids of rows and columns — and lets those tables *relate* to each other through shared values (like `department_id` appearing in both `departments` and `employees`).

**In technical terms:** A **Relational Database Management System** is a DBMS based on the *relational model* (proposed by E.F. Codd in 1970): data is represented as **relations** (tables), each relation is a set of **tuples** (rows) with named **attributes** (columns), and relationships between relations are expressed through shared key values rather than physical pointers.

**Why it exists / what problem it solves:** Before the relational model, databases used hierarchical or network models where relationships were hard-coded as physical links — brittle and hard to query flexibly. The relational model decouples *logical structure* (tables, keys) from *physical storage*, and gives you a declarative query language (SQL) to ask *what* you want without specifying *how* to fetch it.

**`company_db` is a textbook RDBMS example:**

```
departments ──< employees ──< salaries
     │              │  └────< attendance
     │              └────1:1─ managers
     └──< projects ──< employee_projects >── employees
```

Every relationship here is expressed purely through key values (`department_id`, `employee_id`, `project_id`) — there is no physical pointer; the DBMS resolves relationships at query time via joins (Chapter 7).

**Core relational-model rules you'll rediscover through this course:**
- Each table has a well-defined set of columns with defined data types.
- Row order is not meaningful (a table represents a *set*, not a list) — if you need order, you must `ORDER BY` explicitly (Chapter 4).
- Every row should be uniquely identifiable (motivates primary keys, Section 1.9.1).
- Values in a column should be atomic under classical relational theory (this is the seed of **normalization**, Chapter 14).

**Compare RDBMS vs. non-relational (NoSQL) DBMS:**

| Aspect | RDBMS (PostgreSQL, MySQL, Oracle, SQL Server) | Non-relational (MongoDB, Redis, Cassandra) |
|---|---|---|
| Structure | Fixed schema, tables/rows/columns | Flexible/schemaless (documents, key-value, wide-column, graph) |
| Relationships | First-class, enforced via foreign keys | Usually application-enforced or denormalized/embedded |
| Query language | SQL (standardized) | Varies per product |
| Strong consistency | Default, deep support (ACID) | Varies; often eventual consistency for scale |
| Best fit | Structured, relationship-heavy data (this course's domain) | Very high write throughput, flexible/nested documents, massive horizontal scale |

**Common mistakes:** Assuming "RDBMS" and "SQL" are synonyms — SQL is the *language* used to talk to an RDBMS; the RDBMS is the *engine*. Also assuming all NoSQL databases have no schema at all — many enforce schema at the application or validation layer even without a rigid table definition.

**When to use / not use:** Use an RDBMS when your data is naturally structured, relationships matter (as in `company_db`, where an orphaned salary row with no employee would be a real bug), and you need strong consistency guarantees. Consider non-relational options when you need extreme horizontal write scale with loosely structured, rapidly evolving documents and relationships are shallow or rare.

**Real-world use cases:** Payroll (our exact domain), banking ledgers, inventory systems, order management, healthcare records — anywhere referential correctness between entities is a hard requirement.

**Practice questions:**
1. Name the three relational-model terms and their everyday-language equivalents (relation/tuple/attribute vs. table/row/column).
2. Explain why `company_db`'s `salaries` table pointing to `employees` via `employee_id` (a value), rather than a physical memory address, is an advantage.
3. Give one reason a normalized relational design (departments and employees as separate tables) is better than cramming department name and location directly into every employee row.
4. Name two RDBMS products and two non-relational DBMS products.
5. Why is "row order is not guaranteed" an important rule to internalize before Chapter 4 (Sorting)?

---

## 1.5 What Is SQL?

**In plain language:** SQL is the language you use to *talk to* an RDBMS — to ask for data, add data, change data, or change the structure itself. It's not a general-purpose programming language like Python; it's a specialized language for one job: working with relational data.

**In technical terms:** **SQL (Structured Query Language)** is a declarative, standardized (ISO/IEC 9075) language for defining, manipulating, querying, and controlling access to data in a relational database. "Declarative" means you state *what* result you want; the DBMS's query planner figures out *how* to compute it.

**Why it exists:** Before SQL (and its ancestor, IBM's SEQUEL, from Codd's relational model), querying data required writing procedural code that manually navigated records. SQL let people describe the *desired result* in a form close to English/math (relational algebra), while the DBMS optimizes execution — a massive productivity and portability win.

**SQL's sub-languages (you'll live in all of these across this course):**

| Category | Stands for | Commands | Purpose | Chapter |
|---|---|---|---|---|
| DDL | Data Definition Language | `CREATE`, `ALTER`, `DROP` | Define/change structure (tables, schemas) | Ch2, 13, 14 |
| DML | Data Manipulation Language | `SELECT`, `INSERT`, `UPDATE`, `DELETE` | Work with the data itself | Ch3–10 |
| DCL | Data Control Language | `GRANT`, `REVOKE` | Control permissions | Ch27 |
| TCL | Transaction Control Language | `COMMIT`, `ROLLBACK`, `SAVEPOINT` | Control transaction boundaries | Ch11 |

**A first (preview) example against `company_db`** — don't worry about syntax yet, that's Chapter 2 and 3:

```sql
SELECT first_name, last_name, job_title
FROM employees
WHERE department_id = 1;
```

Expected output (Engineering employees, `department_id = 1`):

```
first_name | last_name | job_title
-----------+-----------+----------------------
Aditi      | Rao       | CTO
Rahul      | Mehta     | Engineering Manager
Sneha      | Kulkarni  | Senior Engineer
Vikram     | Joshi     | Software Engineer
Ananya     | Singh     | Software Engineer
Karan      | Verma     | Junior Engineer
Aman       | Chawla    | Software Engineer
```

Notice the statement says *what* (employees where `department_id = 1`, showing three columns), not *how* (which index to use, which order to scan rows). That's the declarative nature of SQL in action.

**Internally:** Every SQL statement you type is parsed into an internal representation, validated against the catalog (do these tables/columns exist? are types compatible?), turned into a query plan, and executed. You'll study this pipeline in depth in Chapter 17.

**Common mistakes:** Thinking SQL syntax is 100% identical everywhere — the *core* (`SELECT`, `WHERE`, joins) is standardized and portable, but many features diverge by vendor (see Section 1.6). Also, treating SQL as case-sensitive for keywords — it isn't (`SELECT` = `select`), though identifiers can be case-sensitive depending on quoting and DBMS.

**When to use / not use:** Use SQL whenever you're working with a relational database. It is not designed for general application logic, complex branching business workflows, or non-tabular data manipulation — those live in your application code (or in stored procedures, Chapter 19, when the logic truly belongs next to the data).

**Real-world use cases:** Virtually every backend service, reporting dashboard, and data pipeline in the industry issues SQL against an RDBMS at some point.

**Practice questions:**
1. Name the four SQL sub-languages and one command belonging to each.
2. Why is SQL called "declarative"? Contrast it with how you'd fetch "all Engineering employees" using a procedural loop in a general-purpose language.
3. Which sub-language would `ALTER TABLE employees ADD COLUMN phone VARCHAR(20);` belong to?
4. Which sub-language would `GRANT SELECT ON salaries TO hr_readonly;` belong to?
5. True or false: SQL keywords are case-sensitive. Justify.

---

## 1.6 SQL vs. MySQL vs. PostgreSQL vs. Oracle vs. SQL Server

**In plain language:** SQL is the *language*. MySQL, PostgreSQL, Oracle Database, and SQL Server are *products* — different companies' software that all understand SQL, but each adds its own extensions, quirks, and personality, the way "English" is a language but British, American, and Australian English each have their own spellings and idioms.

**In technical terms:** SQL is a standard defined by ISO/IEC and ANSI. No real-world RDBMS implements the standard 100% purity — each vendor implements a **dialect**: the standard core, plus proprietary extensions, plus a few deliberate deviations for performance or compatibility reasons.

**Why this distinction matters:** If you only ever learn "PostgreSQL SQL" you will write code that breaks silently or loudly on MySQL/Oracle/SQL Server. This course is anchored on **PostgreSQL** as the primary dialect, and calls out every place another product diverges with explicit tags: **[PostgreSQL]**, **[MySQL]**, **[Oracle]**, **[SQL Server]**.

**Head-to-head comparison:**

| | **PostgreSQL** | **MySQL** | **Oracle Database** | **SQL Server** |
|---|---|---|---|---|
| Type | Open-source object-relational DBMS | Open-source (Oracle-owned) RDBMS | Commercial enterprise RDBMS | Commercial RDBMS (Microsoft) |
| License | PostgreSQL License (permissive) | GPL (community) / commercial | Proprietary, paid | Proprietary, paid (free Express edition exists) |
| Auto-increment PK | `SERIAL` / `GENERATED ... AS IDENTITY` | `AUTO_INCREMENT` | `IDENTITY` columns (12c+) or `SEQUENCE` + trigger (pre-12c) | `IDENTITY` property |
| String concatenation | `\|\|` | `CONCAT()` (also allows `\|\|` in ANSI mode) | `\|\|` | `+` (or `CONCAT()`) |
| Limit rows | `LIMIT n OFFSET m` | `LIMIT n OFFSET m` | `FETCH FIRST n ROWS ONLY` (12c+) or `ROWNUM` | `TOP n` or `OFFSET/FETCH` |
| Boolean type | Native `BOOLEAN` | No true boolean (`TINYINT(1)`) | No native `BOOLEAN` in SQL (pre-23c); use `NUMBER(1)`/`CHAR(1)` | `BIT` |
| Case sensitivity of identifiers | Case-*insensitive* unless double-quoted | Depends on OS/config | Case-*insensitive* unless double-quoted | Case-insensitive by default collation |
| JSON support | `JSON` and `JSONB` (binary, indexable) | `JSON` native type | `JSON` type (21c+) | No native type pre-2025; `NVARCHAR` + `JSON_VALUE()`/`OPENJSON` |
| Typical strength | Standards compliance, extensibility, advanced features | Simplicity, huge web-hosting ecosystem | Enterprise scale, mission-critical features, PL/SQL | Deep Windows/.NET integration, T-SQL, BI tooling |

**Worked example of the same intent, four dialects** — "give me the 3 highest-paid current salary rows":

```sql
-- [PostgreSQL] and [MySQL]
SELECT employee_id, base_salary
FROM salaries
ORDER BY base_salary DESC
LIMIT 3;

-- [SQL Server]
SELECT TOP 3 employee_id, base_salary
FROM salaries
ORDER BY base_salary DESC;

-- [Oracle] (12c+)
SELECT employee_id, base_salary
FROM salaries
ORDER BY base_salary DESC
FETCH FIRST 3 ROWS ONLY;
```

All four are "SQL." None of the three vendor-specific forms are portable to each other without translation — that is precisely the dialect problem this table exists to make visible early.

**Common mistakes:** Calling MySQL/PostgreSQL/Oracle/SQL Server "different versions of SQL" — they are different *products* that each implement (most of) the SQL *standard* plus their own extensions. Another common mistake: assuming code tested on PostgreSQL will "just work" on production Oracle without review.

**When you'll care about this in practice:** Any time you change employers/projects and the shop uses a different RDBMS, migrate a database between vendors, or write portable application code targeting multiple databases (via an ORM, for instance).

**Practice questions:**
1. Is SQL itself owned by any one company? What does "ISO/IEC standard" mean in this context?
2. Write, from memory, the PostgreSQL and SQL Server ways to fetch the top 5 rows of `employees` ordered by `hire_date`.
3. Name one feature PostgreSQL has natively that MySQL and (pre-23c) Oracle lack.
4. If you were told a legacy system uses `ROWNUM <= 5` to limit results, which product does that hint at?
5. Why does this course pick PostgreSQL as the primary dialect rather than teaching all four equally throughout?

---

## 1.7 Database vs. Schema

**In plain language:** If a *database* is a whole building, a *schema* is one floor of labeled offices inside it. You can have multiple floors (schemas) inside the same building (database), each with its own set of offices (tables), and two floors can even have an office with the same name (e.g., two schemas can each have a table called `logs`) without conflict, because the floor name disambiguates them.

**In technical terms:** A **database** is the top-level, isolated storage unit managed by a DBMS instance (in PostgreSQL, you connect to exactly one database per session). A **schema** is a namespace *inside* a database that groups related objects (tables, views, functions) and prevents naming collisions. The fully qualified name of a table is `database.schema.table` (PostgreSQL/SQL Server) — though a session already targets one database, so you usually just write `schema.table`.

**Why it exists:** Namespacing. A single company database might have a `hr` schema, a `finance` schema, and an `audit` schema, each with its own `employees`-like table, without collision. It also enables access control at the namespace level (grant a team access to one schema, not the whole database) and organizational clarity.

**How this literally shows up in `company_db.sql`:**

```sql
DROP SCHEMA IF EXISTS company_db CASCADE;
CREATE SCHEMA company_db;
SET search_path TO company_db;
```

This is important and easy to miss: **`company_db` is technically a *schema*, not a separate PostgreSQL database.** All the tables (`departments`, `employees`, ...) live inside this schema, inside whatever PostgreSQL *database* you ran the script against (e.g., the default `postgres` database). The fully qualified name of the employees table is really `company_db.employees`. `SET search_path TO company_db;` tells PostgreSQL "when I say `employees` unqualified, look inside the `company_db` schema first."

**Vendor differences — this is one of the most confusing terminology clashes in SQL:**

- **[PostgreSQL]** Strict separation: one database can contain many schemas (default schema is `public`). A client connection targets exactly one database at a time; cross-database queries require extensions like `dblink` or `postgres_fdw`.
- **[MySQL]** `DATABASE` and `SCHEMA` are **synonyms** — `CREATE DATABASE x;` and `CREATE SCHEMA x;` do exactly the same thing. MySQL has no separate "schema-inside-a-database" concept the way PostgreSQL does.
- **[Oracle]** Historically, a schema is tightly bound to a *user* — creating user `HR` implicitly creates schema `HR`, and `HR.EMPLOYEES` means "the `EMPLOYEES` table owned by user `HR`." Oracle 12c+ also introduced pluggable databases (PDBs) as a further container layer.
- **[SQL Server]** A database can contain multiple schemas (default is `dbo`). Fully qualified references look like `CompanyDb.dbo.Employees` or, if you created a named schema, `CompanyDb.hr.Employees`.

**Examples:**
```sql
-- Fully qualified reference to a company_db table (rarely needed once search_path is set)
SELECT * FROM company_db.departments;

-- Equivalent, relying on search_path already being set to company_db
SELECT * FROM departments;
```

**Common mistakes:** Saying "the `company_db` database" when it is, strictly, the `company_db` *schema* inside whatever PostgreSQL database you're connected to. This mistake is extremely common in casual speech (this course's own README does it for readability) — but you should know the precise distinction, especially when working across MySQL (where "database" is accurate) versus PostgreSQL (where "schema" is the precise term here).

**Edge cases:** Two schemas in the same PostgreSQL database can each have a table named `employees` with completely different columns — no conflict, because they're addressed as `schema_a.employees` and `schema_b.employees`. If your `search_path` includes both and you query unqualified `employees`, PostgreSQL resolves it using search order — a classic source of "wrong table" bugs in multi-schema systems.

**When to use multiple schemas:** Organizing a large database by team/domain (`sales`, `hr`, `finance`), isolating tenant data, or separating staging/reporting objects from core operational tables.

**Real-world use cases:** A single company Postgres instance might have `app` (production tables), `analytics` (reporting views), and `audit` (compliance logs) as three schemas in one database.

**Practice questions:**
1. Precisely: is `company_db` a database or a schema, per the actual `CREATE SCHEMA` statement in `databases/company_db.sql`?
2. What does `SET search_path TO company_db;` do, and what would happen to an unqualified `SELECT * FROM employees;` if you never ran it and no other schema had an `employees` table on the path?
3. In MySQL, is there a meaningful difference between `CREATE DATABASE payroll;` and `CREATE SCHEMA payroll;`? Why or why not?
4. In Oracle, what user-related concept is a schema tightly coupled to?
5. Give a practical reason a company might split one PostgreSQL database into `hr`, `finance`, and `audit` schemas rather than three separate databases.

---

## 1.8 Table, Row, Column, Record, Field

**In plain language:** A table is a grid, like a spreadsheet tab. Each horizontal line in the grid is one row — one specific "thing" (like one employee). Each vertical line is a column — one specific *kind* of fact recorded about every thing in the table (like everyone's `hire_date`).

**In technical terms:** A **table** (relation) is a named, two-dimensional structure of rows and columns, where every row shares the same column definitions. A **row** (tuple) is one instance of the entity the table represents. A **column** (attribute) is a named, typed slot present in every row. **Record** is a near-synonym for *row* (favored in application/file-processing contexts), and **field** is a near-synonym for *column* (favored when talking about one specific value within one specific row) — you'll hear all four terms used interchangeably in the wild; this course uses "table/row/column" as the precise relational terms and "record/field" when speaking loosely or from an application-code point of view.

**ASCII diagram — the `departments` table:**

```
                  department_id   department_name    location     created_at
                 ┌─────────────┬──────────────────┬───────────┬─────────────────────┐
        Row 1 →  │      1      │   Engineering    │   Pune    │ 2026-... (timestamp) │
        Row 2 →  │      2      │      Sales       │  Mumbai   │ 2026-... (timestamp) │
        Row 3 →  │      3      │       HR         │ Bengaluru │ 2026-... (timestamp) │
        Row 4 →  │      4      │     Finance      │  Mumbai   │ 2026-... (timestamp) │
        Row 5 →  │      5      │    Marketing     │   Delhi   │ 2026-... (timestamp) │
                 └─────────────┴──────────────────┴───────────┴─────────────────────┘
                        ↑               ↑                ↑               ↑
                     Column          Column           Column          Column

        One "cell" — e.g., "Mumbai" for department_id = 2 — is a single FIELD/VALUE.
        The whole row (2, 'Sales', 'Mumbai', <timestamp>) is one RECORD.
```

**Terminology cross-reference table:**

| Relational term | Everyday/application term | `company_db` example |
|---|---|---|
| Table (Relation) | — | `employees` |
| Row (Tuple) | Record | The single row for `employee_id = 5` (Ananya Singh) |
| Column (Attribute) | Field (as a *definition*) | `job_title` |
| Cell value | Field (as a *value*) | `'Software Engineer'` (Ananya's `job_title` value) |

**Multiple examples:**
1. In `employees`, the table has 9 columns (`employee_id`, `first_name`, `last_name`, `email`, `hire_date`, `job_title`, `department_id`, `manager_id`, `status`, `created_at` — actually 10; count them in the DDL) and (after seeding) 16 rows.
2. In `salaries`, one employee (e.g., `employee_id = 1`, Aditi Rao) has **two rows** — `(1, 450000, 90000, 'USD', '2015-03-01')` and `(1, 520000, 100000, 'USD', '2020-01-01')` — because `salaries` models salary *history*, not a single current value. This is a critical, non-obvious design point: "one row per employee" is **not** a rule of tables in general; a table's row-per-entity granularity depends entirely on what the table represents. `salaries` represents "a salary that was effective starting on some date," and an employee can have many of those over time.
3. In `employee_projects`, a single row like `(2, 1, 'Tech Lead', 400)` records a *fact about a relationship* (Rahul Mehta's role and hours on the Platform Migration project) rather than a fact about a single entity — this table exists specifically to hold facts that belong to neither `employees` nor `projects` alone (Section 1.11, many-to-many).

**What happens internally:** In PostgreSQL, a table's rows are physically stored in fixed-size disk pages (default 8KB) as a *heap* — rows are not stored in any guaranteed order. Each column's data type and constraints are recorded once, in the system catalog (`pg_attribute`, `pg_class`), not duplicated per row. This is why row order is never guaranteed unless you explicitly `ORDER BY`.

**Common mistakes:**
- Assuming a table must have "one row per real-world thing" — `salaries` deliberately doesn't (Section above).
- Using "field" to mean "column" in a design document, then later meaning "value" in a debugging conversation, without noticing the ambiguity — be explicit in professional writing.
- Assuming column order matters for meaning — it doesn't relationally (a table is a set of named attributes), though `SELECT *` will return them in the order defined in the `CREATE TABLE` statement, which trips people up when they rely on positional column access.

**Edge cases:** A table can legally have zero rows (an empty `projects` table before any `INSERT` is still "the `projects` table"). A row can have `NULL` in most columns (Section 1.13) — a row is not required to have *every* field meaningfully filled in.

**When to use / not use:** Every RDBMS interaction happens through tables — there's no "not using tables" in an RDBMS. The design decision that *does* vary is what a row should represent (Chapter 14, normalization, formalizes this).

**Real-world use cases:** Literally every RDBMS-backed application; the concepts here are the atomic vocabulary of the entire remaining course.

**Practice questions:**
1. How many rows does `departments` have after seeding? How many columns?
2. Why does `salaries` have more rows than `employees`, even though every salary row references exactly one employee?
3. What is the relational term for what application developers usually call a "record"?
4. Name one column in `attendance` that is allowed to be `NULL`, and explain (from the DDL) why.
5. True or false: the order of columns in `SELECT *` output is guaranteed to match the order they were declared in `CREATE TABLE`. Justify from what you know so far.
6. What is stored once in the system catalog rather than once per row?

---

## 1.9 Keys

Keys are how a relational database identifies rows precisely and links tables together. This is the single most important conceptual toolkit in this chapter — nearly every later chapter (joins, indexes, constraints, normalization) assumes you have internalized these distinctions cold.

### 1.9.1 Primary Key

**In plain language:** A primary key is a value guaranteed to be different for every single row — like an employee ID badge number. Two employees might share a first name (there is only one "Sneha" here, but imagine there were two), but no two employees ever share an employee ID.

**In technical terms:** A **primary key (PK)** is a column (or set of columns) chosen to be the single, official, unique, non-null identifier for every row in a table. A table may have only **one** primary key, though that key can span multiple columns (a **composite** primary key, Section 1.9.4).

**Why it exists:** Without a guaranteed unique identifier, you cannot reliably reference "this exact row" — not from application code, not from another table (foreign keys depend on primary keys existing), and not even from a `WHERE` clause with full confidence, because non-unique columns could match multiple rows.

**Syntax, broken down (`departments`):**
```sql
CREATE TABLE departments (
    department_id   SERIAL PRIMARY KEY,
    ...
);
```
- `SERIAL` — PostgreSQL shorthand that creates an auto-incrementing integer column backed by a sequence (details in Section 1.14).
- `PRIMARY KEY` — the constraint keyword: tells PostgreSQL "enforce uniqueness AND non-null on this column, and treat it as this table's canonical identifier."

**Examples, simple to complex:**
1. Single-column PK: `departments.department_id` — values `1, 2, 3, 4, 5`, each unique.
2. Single-column PK on a self-referencing table: `employees.employee_id` — even though `employees.manager_id` points back into the *same* table, `employee_id` alone still uniquely identifies each of the 16 rows.
3. Composite PK (covered fully in 1.9.4): `employee_projects (employee_id, project_id)` — neither column alone is unique (`employee_id = 2` appears twice, for `project_id` 1 and 2), but the *pair* is.

**Expected output — proving uniqueness:**
```sql
SELECT department_id, COUNT(*)
FROM departments
GROUP BY department_id
HAVING COUNT(*) > 1;
```
```
(0 rows)
```
Zero rows returned is the expected — and only valid — outcome for any primary key column; if this ever returns rows, your primary key constraint has been violated or bypassed (which a correctly-defined PK should never allow).

**What happens internally:** When PostgreSQL executes `PRIMARY KEY`, it does two things: (1) adds a `NOT NULL` constraint on the column(s), and (2) creates a **unique B-tree index** on the column(s) automatically. That index is what makes `WHERE department_id = 3` extremely fast (an index seek) instead of scanning all rows, and it's also the mechanism that physically rejects a duplicate insert. You'll study B-tree indexes in depth in Chapter 16 — for now, remember: **primary key → automatic unique index, always.**

**Common mistakes:**
- Thinking you must manually create an index on your primary key column — PostgreSQL (and every major RDBMS) does this automatically.
- Choosing a primary key that *could* change over time (e.g., using `email` as the PK and then needing to support email changes) — this complicates every foreign key pointing at it. This is exactly why `company_db` uses `employee_id` (a surrogate key, Section 1.9.6) rather than `email` as the employees PK.
- Assuming a primary key must be numeric — it can be any data type that supports equality comparison (though numeric surrogate keys are the most common convention).

**Edge cases:** A composite primary key (`employee_projects`) means the *combination* must be unique, but individual columns within it can repeat many times across different rows — this is different from a `UNIQUE` constraint on a single column.

**When to use / not use:** Every table should have a primary key — even a pure log or event table typically benefits from one (for replication, deduplication, and referencing individual rows). The rare exception is certain append-only, high-throughput staging tables where uniqueness is deliberately not enforced for ingestion speed — an advanced, situational trade-off you'll meet in Chapters 24 and 26.

**Compare with related concepts:** See the summary table at the end of Section 1.9.7 comparing all key types side by side.

**Real-world use cases:** Order IDs, customer IDs, employee IDs, invoice numbers — any "the one true identifier for this row" scenario.

**Practice questions:**
1. What are the primary keys of `departments`, `employees`, `salaries`, `attendance`, and `projects`?
2. `employee_projects` doesn't have a single-column primary key. What is its primary key instead?
3. What two guarantees does `PRIMARY KEY` add to a column, mechanically?
4. What internal structure does PostgreSQL automatically create to enforce a primary key?
5. Why would using `employees.email` as the primary key (instead of `employee_id`) be a riskier design choice?
6. Can a table have two primary keys? Can a primary key span two columns?

### 1.9.2 Candidate Key

**In plain language:** A candidate key is any column (or column combination) that *could have been* chosen as the primary key — any "good enough to uniquely identify a row" option, even if it wasn't the one picked.

**In technical terms:** A **candidate key** is a minimal set of one or more columns whose values are guaranteed unique (and non-null, in strict theory) for every row in a table — a *candidate* for being the primary key. A table can have many candidate keys but only one becomes the actual primary key; the rest become **alternate keys** (Section 1.9.3).

**Why it exists as a concept:** Design discussions need a vocabulary for "this column happens to be unique too, even though we didn't choose it as the PK." Recognizing all candidate keys during design is exactly what lets you place `UNIQUE` constraints correctly (Section 1.10) to protect data integrity beyond just the primary key.

**Example — `employees`:**
- `employee_id` — unique, not null → candidate key (and the chosen primary key).
- `email` — declared `NOT NULL UNIQUE` in the DDL → also unique and not null → **also a candidate key**, just not the one chosen as PK.

```sql
email VARCHAR(150) NOT NULL UNIQUE
```

Both `employee_id` and `email` could correctly identify any one of the 16 employee rows. `employee_id` was chosen as the *primary* key; `email` remains a candidate key that was implemented as a `UNIQUE` constraint — this makes it an **alternate key** in practice (next section).

**Example — `departments`:** `department_id` (PK) and `department_name` (`NOT NULL UNIQUE`) are both candidate keys.

**Example — `managers`:** `manager_id` (PK) and `department_id` (`NOT NULL UNIQUE`) are both candidate keys — each department has exactly one manager row, and each manager row belongs to exactly one department.

**Common mistakes:** Assuming only the primary key column is "special" — every candidate key deserves a `UNIQUE` constraint even if it never becomes the PK, otherwise the database won't actually enforce the uniqueness that made it a candidate in the first place.

**Edge cases:** A composite set of columns can be a candidate key even if no single column in it is unique alone — e.g., in `salaries`, neither `employee_id` nor `effective_date` alone is unique, but the DDL's `UNIQUE (employee_id, effective_date)` declares the *pair* as a candidate key (an employee cannot have two different salary rows effective on the same date).

**When to use / not use:** Identify *all* candidate keys during schema design, even ones you won't use as the PK — each one is a real-world uniqueness rule worth enforcing with a constraint.

**Compare:** Candidate key is the umbrella category; Primary Key and Alternate Key are the two roles a candidate key can end up playing (see 1.9.7 table).

**Practice questions:**
1. Name two candidate keys in `employees`.
2. Is `(employee_id, effective_date)` in `salaries` a candidate key? Why?
3. In `managers`, name both candidate keys and explain what real-world rule each one enforces.
4. Why should a candidate key that isn't chosen as the primary key still get a `UNIQUE` constraint?
5. Is `first_name` a candidate key in `employees`? Why or why not (hint: check the seed data for repeats or think about whether uniqueness is *guaranteed* by any constraint)?

### 1.9.3 Alternate Key

**In plain language:** An alternate key is "the candidate key(s) that lost the vote" — still fully capable of identifying a row uniquely, just not the one chosen as the star of the show (the primary key).

**In technical terms:** An **alternate key** is any candidate key of a table that was *not* selected as the primary key. It is typically enforced in SQL with a `UNIQUE` constraint (rather than `PRIMARY KEY`).

**Why it exists / what problem it solves:** Real-world entities often have more than one naturally unique attribute (an employee has both an internal ID and a unique email; a department has both an ID and a unique name). The database should still protect the uniqueness of *all* of them, not just the chosen PK — that's exactly what `UNIQUE` constraints on alternate keys do.

**Examples from `company_db`:**

| Table | Primary Key | Alternate Key(s) |
|---|---|---|
| `departments` | `department_id` | `department_name` (`UNIQUE`) |
| `employees` | `employee_id` | `email` (`UNIQUE`) |
| `managers` | `manager_id` | `department_id` (`UNIQUE`) |
| `salaries` | `salary_id` | `(employee_id, effective_date)` composite (`UNIQUE`) |
| `attendance` | `attendance_id` | `(employee_id, work_date)` composite (`UNIQUE`) |

**Expected behavior — an alternate key violation:**
```sql
INSERT INTO employees (first_name, last_name, email, hire_date, job_title, department_id)
VALUES ('Test', 'Duplicate', 'aditi.rao@company.com', '2024-01-01', 'Analyst', 1);
```
```
ERROR:  duplicate key value violates unique constraint "employees_email_key"
DETAIL:  Key (email)=(aditi.rao@company.com) already exists.
```
Note this is rejected even though `employee_id` (the primary key) was never specified as a duplicate — the *alternate* key's `UNIQUE` constraint independently protects `email`.

**What happens internally:** Exactly like a primary key, a `UNIQUE` constraint in PostgreSQL is backed by a unique B-tree index — the only structural difference from a primary key's index is that a `UNIQUE` column is still allowed to contain `NULL` (and, importantly, in standard SQL multiple `NULL`s are considered "not equal to each other," so multiple `NULL`s are typically permitted in a `UNIQUE` column — a subtlety worth remembering).

**Common mistakes:** Forgetting to add `UNIQUE` on true alternate keys, relying only on application code to check "is this email already taken?" — a race condition under concurrent inserts can slip two duplicate emails past application-level checks, but never past a real database `UNIQUE` constraint.

**Edge cases:** A `UNIQUE` constraint on a nullable column allows any number of rows with `NULL` in that column (in PostgreSQL and most RDBMSs) since `NULL <> NULL` semantics mean no two `NULL`s are considered "duplicates" of each other — contrast this with a primary key, which never allows `NULL` at all.

**When to use / not use:** Add alternate keys (`UNIQUE`) for every real-world uniqueness rule that isn't the chosen PK. Don't over-apply `UNIQUE` to columns whose real-world uniqueness isn't actually guaranteed (e.g., don't make `job_title` unique — many employees legitimately share a title, as `'Software Engineer'` does for employees 4, 5, and 16).

**Compare:** Primary Key = the *chosen* unique identifier, enforced as PK. Alternate Key = every *other* candidate key, enforced as UNIQUE. Both are candidate keys; the difference is purely which one a designer picked to be "the" identifier.

**Real-world use cases:** Username *and* email both unique on a `users` table; SKU *and* barcode both unique on a `products` table.

**Practice questions:**
1. Give the alternate key for `departments` and explain the real-world rule it enforces.
2. Why is `(employee_id, effective_date)` in `salaries` an alternate key rather than an arbitrary constraint?
3. What SQL constraint keyword is typically used to implement an alternate key?
4. Can a `UNIQUE` column contain multiple `NULL` values in PostgreSQL? Contrast with a `PRIMARY KEY` column.
5. Why shouldn't `job_title` be declared `UNIQUE` on `employees`, based on the seed data?

### 1.9.4 Composite Key

**In plain language:** Sometimes no single fact is enough to tell two things apart, but *two facts together* are. Knowing only "Rahul" doesn't identify a unique seat at a theater, but "Row 2, Seat 14" does. A composite key is exactly that: two or more columns that only become unique when combined.

**In technical terms:** A **composite key** (or compound key) is a key — primary, candidate, or alternate — made up of two or more columns, where no single column in the set is individually unique, but the *combination* is.

**Why it exists:** Many real-world facts are inherently about a *pairing* rather than a single entity — "this employee's involvement in this project," "this employee's attendance on this date." A single-column key would be artificial (and less self-documenting) for such tables; the natural identifier really is the pair.

**Example — `employee_projects` composite primary key:**
```sql
CREATE TABLE employee_projects (
    employee_id     INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    project_id      INT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    role            VARCHAR(100) NOT NULL,
    hours_allocated INT NOT NULL DEFAULT 0 CHECK (hours_allocated >= 0),
    PRIMARY KEY (employee_id, project_id)
);
```
- `employee_id = 2` appears in two rows (projects 1 and 2 — Rahul Mehta is Tech Lead on both "Platform Migration" and "Mobile App Revamp").
- `project_id = 1` appears in three rows (employees 2, 3, 4 all work on "Platform Migration").
- Neither column alone is unique, but the **pair** `(employee_id, project_id)` is: Rahul Mehta appears on project 1 exactly once, never twice.

**Expected output:**
```sql
SELECT employee_id, project_id, role FROM employee_projects WHERE employee_id = 2;
```
```
employee_id | project_id |    role
------------+------------+----------
     2      |     1      | Tech Lead
     2      |     2      | Tech Lead
```
Two rows for the same `employee_id` — proof that `employee_id` alone is not a key here, but `(employee_id, project_id)` is, since no third row exists with `(2, 1)` or `(2, 2)` repeated.

**Composite alternate key example — `salaries`:**
```sql
UNIQUE (employee_id, effective_date)
```
This is a composite *alternate* key (the table's primary key is still the single-column `salary_id`) — it enforces "an employee cannot have two salary rows effective on the exact same date," while still allowing many rows per employee across *different* dates (which is the entire point of the salary-history design).

**What happens internally:** PostgreSQL builds a single multi-column B-tree index over the composite key's columns, in the order they were declared. Column order in a composite key matters for which queries can use the index efficiently (a topic you'll study in depth in Chapter 16) — `(employee_id, project_id)` efficiently supports "find all projects for employee X" but is less directly useful for "find all employees on project Y" without a secondary index.

**Common mistakes:** Declaring `employee_id` and `project_id` as two *separate* single-column unique constraints instead of one composite `PRIMARY KEY (employee_id, project_id)` — that would incorrectly forbid an employee from being on more than one project at all, and would forbid a project from having more than one employee, which is the opposite of what a many-to-many bridge table needs.

**Edge cases:** Composite keys can combine more than two columns; the general theoretical rule for a candidate key is *minimality* — every column in the set must be necessary (removing any one column would break uniqueness). If you added a redundant third column to `(employee_id, project_id)` that didn't add discriminating power, the key would no longer be minimal, hence not a true candidate key in the strict theoretical sense.

**When to use / not use:** Use composite keys for genuine bridge/junction tables (Section 1.11's many-to-many) and for tables whose natural identity really is a pairing (like `(employee_id, work_date)` in `attendance`). Avoid composite keys purely as a workaround when a clean surrogate single-column key (Section 1.9.6) would be simpler for foreign keys elsewhere to reference — composite foreign keys are more verbose everywhere they're used.

**Compare:** A composite key is a *shape* (multi-column), independent of whether it plays the *role* of primary key (`employee_projects`) or alternate key (`salaries`'s `(employee_id, effective_date)`).

**Real-world use cases:** Order line items `(order_id, line_number)`, seat bookings `(showtime_id, seat_number)`, translations `(text_id, language_code)`.

**Practice questions:**
1. What is the composite primary key of `employee_projects`?
2. Is `(employee_id, effective_date)` in `salaries` a primary key or an alternate key? How do you know from the DDL?
3. Why would two separate single-column `UNIQUE` constraints on `employee_id` and `project_id` in `employee_projects` be wrong?
4. Name the composite alternate key in `attendance` and the real-world rule it protects.
5. In a composite key `(employee_id, project_id)`, is `employee_id` alone guaranteed unique? Prove your answer using the seed data for `employee_id = 2`.

### 1.9.5 Foreign Key

**In plain language:** A foreign key is a "this points to that" label. When an employee row says `department_id = 1`, it's pointing at the Engineering row in `departments` — like writing someone else's ID number on a form to reference them, instead of retyping their whole record.

**In technical terms:** A **foreign key (FK)** is a column (or column set) in one table whose values must match values of a candidate key (usually the primary key) in another table (or the same table, for self-references) — or be `NULL`, if the column is nullable. It is the mechanism that implements relationships (Section 1.11) and enforces referential integrity (Section 1.12).

**Why it exists:** Without foreign keys, nothing stops `employees.department_id` from containing `99` when no department `99` exists — a silent, undetectable data-corruption bug that would only surface later as a confusing application error or a wrong report. A foreign key constraint makes such corruption *structurally impossible*.

**Syntax, broken down:**
```sql
employees (
    ...
    department_id   INT REFERENCES departments(department_id) ON DELETE SET NULL,
    manager_id      INT REFERENCES employees(employee_id) ON DELETE SET NULL,
    ...
);
```
- `INT` — the column's data type must be compatible with the referenced column's type (`departments.department_id` is also an integer, via `SERIAL`).
- `REFERENCES departments(department_id)` — declares the foreign key: this column's non-null values must exist in `departments.department_id`.
- `ON DELETE SET NULL` — the referential action (Section 1.12): if the referenced department row is deleted, set this column to `NULL` instead of blocking the delete or cascading it.
- `REFERENCES employees(employee_id)` on `manager_id` — a **self-referencing** foreign key: `employees` references itself, since a manager is also an employee. This is exactly what enables the org-chart hierarchy you'll query with recursive CTEs in Chapter 9.

**Examples, simple to complex:**
1. Simple: `employees.department_id = 1` → must exist as `departments.department_id = 1`. It does (Engineering). Valid.
2. Self-referencing: `employees.manager_id = 2` for Sneha Kulkarni (`employee_id = 3`) → must exist as `employees.employee_id = 2`. It does (Rahul Mehta). Valid.
3. Nullable FK, legitimately unset: `employees.manager_id = NULL` for Aditi Rao (`employee_id = 1`, the CTO) — she has no manager, which is valid *because* `manager_id` is nullable.
4. Composite-key-adjacent FK pair: `employee_projects.employee_id → employees.employee_id` and `employee_projects.project_id → projects.project_id` — two separate single-column foreign keys, combined with the composite primary key, is what makes this table a proper many-to-many bridge (Section 1.11).

**Expected output — a foreign key violation:**
```sql
INSERT INTO employees (first_name, last_name, email, hire_date, job_title, department_id)
VALUES ('New', 'Hire', 'new.hire@company.com', '2024-06-01', 'Analyst', 99);
```
```
ERROR:  insert or update on table "employees" violates foreign key constraint "employees_department_id_fkey"
DETAIL:  Key (department_id)=(99) is not present in table "departments".
```

**What happens internally:** PostgreSQL enforces a foreign key by checking, on every `INSERT`/`UPDATE` to the referencing column, that a matching row exists in the referenced table (using the referenced table's index — which is why the referenced column should always be a primary/unique key with an index already in place). On `DELETE`/`UPDATE` of the *referenced* row, PostgreSQL also checks the constraint's `ON DELETE`/`ON UPDATE` action to decide what to do to dependent rows — this is Section 1.12 in full detail.

**Common mistakes:**
- Forgetting that a nullable foreign key column can legitimately be `NULL` — this is *not* a violation; it just means "no relationship for this row" (e.g., Aditi Rao's `manager_id IS NULL`).
- Assuming foreign keys must reference a primary key only — they can reference *any* column with a `UNIQUE` (or PK) constraint, e.g., `managers.department_id REFERENCES departments(department_id)` references a column that happens to be the departments PK, but FKs to non-PK unique columns are equally valid in general.
- Trying to insert a child row before the parent row exists (e.g., inserting a salary row for `employee_id = 17` before employee 17 exists) — always insert parents before children.

**Edge cases:** A self-referencing foreign key (`employees.manager_id → employees.employee_id`) means you must insert Aditi Rao (no manager) *before* Rahul Mehta (`manager_id = 1`) — an ordering dependency within a single table.

**When to use / not use:** Use a foreign key any time one table's values are meant to correspond to another table's identity — which, in a well-designed relational schema, is *almost always* when you have a "this ID belongs to that table" column. The rare exception is deliberately denormalized reporting/staging tables (Chapter 26) where enforcement overhead is intentionally skipped for load performance, with correctness responsibility shifted to the ETL process.

**Compare:** A primary key identifies rows *within* a table; a foreign key references a primary/unique key *across* (or within, self-referencing) tables. A foreign key column is not itself required to be unique in its own table (`employees.department_id` repeats for every Engineering employee) — only the *referenced* column must be unique.

**Real-world use cases:** `orders.customer_id → customers.customer_id`, `payments.order_id → orders.order_id`, and every hierarchy (`employees.manager_id`, category trees, comment threads) via self-referencing FKs.

**Practice questions:**
1. Name all the foreign key columns in `employees`, `salaries`, `attendance`, `projects`, `managers`, and `employee_projects`, and what each one references.
2. Which foreign key in `company_db` is self-referencing, and what real-world relationship does it model?
3. What error would you expect from inserting a `salaries` row with `employee_id = 999`?
4. Is it valid for `employees.manager_id` to be `NULL`? For which real employee in the seed data is it actually `NULL`, and why does that make sense?
5. Must a foreign key always reference a primary key specifically, or can it reference any unique column? Give a `company_db` example either way.
6. What ordering constraint does the self-referencing FK on `employees` impose on how you insert rows 1 and 2 into that table?
7. Why should the referenced column of a foreign key already have an index (and does a primary key already guarantee one)?

### 1.9.6 Natural Key vs. Surrogate Key

**In plain language:** A natural key is an identifier that already exists in the real world and carries real meaning (an email address, a national ID number, a product's barcode). A surrogate key is an identifier the database invents purely for its own bookkeeping purposes, with no meaning outside the database (a plain incrementing number like `employee_id`).

**In technical terms:** A **natural key** is a candidate key composed of attributes that have independent, real-world business meaning. A **surrogate key** is an artificial, system-generated identifier (commonly an auto-incrementing integer or a UUID) with no business meaning, introduced solely to serve as a stable primary key.

**Why surrogate keys are the default in `company_db` (and in most modern schema design):** Real-world "natural" identifiers are surprisingly unstable — emails change when people get married or switch providers, department names get rebranded, product SKUs get reissued. If a natural key is the primary key, then every foreign key across your entire schema that references it must also change whenever the natural value changes — an expensive, error-prone cascade. A surrogate key never needs to change, because it was never tied to a real-world fact in the first place.

**Direct evidence in the schema:**
```sql
CREATE TABLE employees (
    employee_id     SERIAL PRIMARY KEY,          -- surrogate key: meaningless integer, PK
    ...
    email           VARCHAR(150) NOT NULL UNIQUE, -- natural key: real-world meaning, alternate key
    ...
);
```
Every design decision in `company_db` follows this pattern: `department_id`, `employee_id`, `salary_id`, `attendance_id`, `project_id` are all surrogate `SERIAL` primary keys, while `department_name` and `email` are natural candidate keys demoted to alternate (`UNIQUE`) status.

**Examples, simple to complex:**
1. `departments.department_id = 1` (surrogate) vs. `departments.department_name = 'Engineering'` (natural) — both identify the same row; only the surrogate is the PK.
2. If "Engineering" were ever renamed to "Platform Engineering" (a realistic, non-hypothetical event in any real company), every foreign-key-based join to `departments` using `department_id` (as `company_db` actually does) is completely unaffected. Had the schema instead used `department_name` as the primary key referenced by `employees.department_name`, that rename would have required cascading the update through every dependent row — messy and risky.
3. `employees.email` is a natural key that *can* change (an employee could get a new email); because it is only an alternate key (not what `salaries`, `attendance`, `employee_projects`, and `managers` reference), those tables are completely insulated from any future email change.

**What happens internally:** `SERIAL` (Section 1.14) is PostgreSQL's mechanism for auto-generating surrogate key values via a backing sequence — every `INSERT` without an explicit `employee_id` pulls the next integer from `employees_employee_id_seq`, guaranteeing uniqueness without you or the application ever having to compute it.

**Common mistakes:**
- Using a natural key as a primary key "because it's convenient right now," then being forced into a painful migration later when that value turns out to be mutable after all (the classic real-world case: using a Social Security Number or email as a PK, then a legal name/data-correction requirement forces an update cascade).
- Assuming surrogate keys mean you can skip declaring natural-key uniqueness constraints — you still need `UNIQUE` on `email` and `department_name` even though they're not the PK (Section 1.9.3).

**Edge cases:** Some genuinely immutable, universally standardized real-world values (e.g., ISO country codes like `'IN'`, `'US'`) are stable enough to safely serve as natural primary keys — the instability argument doesn't apply equally to *every* natural key, only to ones with realistic change risk.

**When to use / not use:** Default to surrogate keys for entities whose "natural" identifying attributes could plausibly change or be reissued (people, products, organizational units — exactly `company_db`'s pattern). Natural keys can be reasonable primary keys for genuinely stable, standardized reference data (currency codes, country codes) — though even then, many teams still prefer surrogate keys for absolute consistency across the schema.

**Compare — full summary table:**

| Key type | Definition | `company_db` example |
|---|---|---|
| Candidate Key | Any column set that could uniquely identify a row | `employee_id`, `email` (both, in `employees`) |
| Primary Key | The candidate key chosen as the table's official identifier | `employee_id` |
| Alternate Key | Every candidate key *not* chosen as primary | `email` |
| Composite Key | A key spanning 2+ columns | `(employee_id, project_id)` in `employee_projects` |
| Natural Key | A key with real-world business meaning | `email`, `department_name` |
| Surrogate Key | A system-generated, meaningless key | `employee_id`, `department_id`, `salary_id` |
| Foreign Key | A column referencing a key in another (or the same) table | `employees.department_id → departments.department_id` |

**Real-world use cases:** Nearly every modern schema (banking, e-commerce, HR systems) defaults to surrogate integer or UUID primary keys, reserving natural-value uniqueness for `UNIQUE` constraints — this is exactly the `company_db` pattern, and you'll see it repeated in `ecommerce_db` and `banking_db` later in the course.

**Practice questions:**
1. List every surrogate key in `company_db` and the table it belongs to.
2. List every natural key (whether or not it's the PK) in `company_db`.
3. Why does using `employee_id` instead of `email` as the primary key protect `salaries`, `attendance`, and `employee_projects` from a hypothetical future email change?
4. Give a real-world natural key that is stable enough to reasonably serve as a primary key, and explain why it's an exception to the general "avoid natural keys as PKs" guidance.
5. Is `department_name` a natural key, a surrogate key, or both? Is it a primary key? Justify from the DDL.
6. Fill in a key-type classification table (candidate/primary/alternate/composite/natural/surrogate — some rows will have more than one label) for `managers.manager_id` and `managers.department_id`.

---

## 1.10 Constraints (Overview)

**In plain language:** Constraints are the database's rulebook — promises about the data that it will *never* let be broken, no matter what application code tries to insert. Think of them as guardrails on a mountain road: they don't drive the car, but they make certain crashes physically impossible.

**In technical terms:** A **constraint** is a rule attached to a column or table that the DBMS enforces on every `INSERT`/`UPDATE`/`DELETE`, rejecting any operation that would violate it. This chapter introduces them at a conceptual level; Chapter 13 covers syntax, `ALTER TABLE` constraint management, deferred constraints, and enforcement internals in full depth.

**Why constraints exist:** Application-level validation (e.g., a web form's JavaScript check) is easy to bypass — a direct database write, a bug in a different code path, a bulk import script, or a second application sharing the same database can all skip it. Constraints are the *last line of defense*, enforced by the engine itself, regardless of which code path produced the write.

**The constraint types you've already met implicitly in this chapter, previewed here:**

| Constraint | Purpose | `company_db` example |
|---|---|---|
| `NOT NULL` | Column must always have a value | `employees.first_name NOT NULL` |
| `UNIQUE` | No two rows may share this value (candidate/alternate key) | `departments.department_name UNIQUE` |
| `PRIMARY KEY` | `NOT NULL` + `UNIQUE`, and the table's chosen identifier | `employees.employee_id` |
| `FOREIGN KEY` / `REFERENCES` | Value must exist in another (or the same) table | `employees.department_id REFERENCES departments` |
| `CHECK` | Arbitrary boolean condition on the row | `salaries.base_salary > 0` |
| `DEFAULT` | Value auto-filled if none supplied (not a validation rule, but closely related) | `employees.status DEFAULT 'ACTIVE'` |

**Examples straight from the DDL, each explained:**
```sql
status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
    CHECK (status IN ('ACTIVE','ON_LEAVE','TERMINATED')),
```
- `NOT NULL` — every employee must have *some* status; it can never be left blank.
- `DEFAULT 'ACTIVE'` — if an `INSERT` doesn't specify `status`, PostgreSQL fills in `'ACTIVE'` automatically.
- `CHECK (status IN (...))` — even if a value *is* supplied, it must be one of exactly three allowed strings; `'RETIRED'` would be rejected.

```sql
budget NUMERIC(12,2) CHECK (budget >= 0),
CHECK (end_date IS NULL OR end_date >= start_date)
```
- The first `CHECK` is a column-level rule (budget can't be negative).
- The second is a **table-level** `CHECK` spanning two columns — it isn't attached to one column's definition because it compares `end_date` to `start_date`. This is a good example of why some constraints must be declared at the table level rather than the column level.

**Expected output — a `CHECK` violation:**
```sql
INSERT INTO projects (project_name, department_id, start_date, end_date, budget)
VALUES ('Bad Project', 1, '2024-01-01', '2023-01-01', 100000);
```
```
ERROR:  new row for relation "projects" violates check constraint "projects_check"
DETAIL:  Failing row contains (..., 2024-01-01, 2023-01-01, 100000.00).
```
The end date is *before* the start date, violating `CHECK (end_date IS NULL OR end_date >= start_date)`.

**What happens internally:** `NOT NULL` and `CHECK` constraints are evaluated per-row at write time with no extra index needed — cheap boolean checks. `UNIQUE` and `PRIMARY KEY` are backed by an index (Section 1.9.1) so the engine can *efficiently* detect a duplicate rather than scanning the whole table on every insert. `FOREIGN KEY` constraints require a lookup into the referenced table's index on every write to the referencing column (and, depending on the `ON DELETE`/`ON UPDATE` action, on every write to the referenced table too).

**Common mistakes:** Relying only on application-level validation and skipping database constraints "because the app already checks it" — this breaks the moment a second application, a manual `psql` fix, or a bulk loader touches the same table. Also: forgetting that a table-level, multi-column `CHECK` (like the `projects` date check) cannot be expressed as a column-level constraint on either column alone.

**Edge cases:** A `NOT NULL` column can still receive a value through `DEFAULT` even if the `INSERT` statement never mentions the column at all. A `CHECK` constraint is *not* violated by `NULL` — in `CHECK (base_salary > 0)`, a `NULL` `base_salary` would actually pass the check (because the expression evaluates to `UNKNOWN`, not `FALSE`) *unless* the column also has `NOT NULL` — which is precisely why `salaries.base_salary` is declared `NOT NULL CHECK (base_salary > 0)`, using both together deliberately.

**When to use / not use:** Add every real-world business rule you can express declaratively as a constraint — it is dramatically cheaper to prevent bad data than to clean it up later. Reserve genuinely complex, multi-table, or workflow-dependent rules for application logic or triggers (Chapter 22), since `CHECK` constraints in standard SQL cannot reference other tables.

**Real-world use cases:** Preventing negative prices, negative inventory, invalid status enums, orphaned foreign keys, and duplicate business identifiers — constraints are the reason a well-designed database is far harder to corrupt than a spreadsheet.

**Practice questions:**
1. Name the six constraint types introduced in this section and give one `company_db` example of each.
2. Why is the `projects` end-date-after-start-date rule a table-level `CHECK` rather than a column-level one?
3. Would `CHECK (base_salary > 0)` alone (without `NOT NULL`) stop someone from inserting a `NULL` `base_salary`? Why or why not?
4. What does `DEFAULT 'ACTIVE'` do if an `INSERT` statement explicitly supplies `status = 'ON_LEAVE'`?
5. Why is it risky to rely solely on application code to enforce "an employee's `department_id` must reference a real department"?
6. Which constraint type requires an index to be efficiently enforced, and which two constraint types generally do not?

---

## 1.11 Relationships

Tables rarely stand alone — the entire point of the relational model is that facts about the same real-world story live in different tables and get *related* to each other through keys. There are exactly three cardinalities you need to master.

### 1.11.1 One-to-One (1:1)

**In plain language:** One-to-one means each thing on one side pairs with exactly one thing on the other side, and vice versa — like each passport pairing with exactly one citizen.

**In technical terms:** A **one-to-one relationship** exists when a row in Table A corresponds to at most one row in Table B, and a row in Table B corresponds to at most one row in Table A.

**Why it exists / when it's used:** 1:1 relationships usually model either (a) an optional or occasional "extension" of an entity that most rows don't need, or (b) a deliberate separation of concerns/security boundary (e.g., splitting sensitive columns into a separately-permissioned table). `company_db` uses it for exactly the second reason: `managers` is a *deliberately separate* table from `employees`, even though every manager is also an employee, so that "who currently manages department X" is its own clean, small, independently-constrained fact.

**The `company_db` example — `employees` ↔ `managers`:**
```sql
CREATE TABLE managers (
    manager_id      INT PRIMARY KEY REFERENCES employees(employee_id),
    department_id   INT NOT NULL UNIQUE REFERENCES departments(department_id),
    appointed_date  DATE NOT NULL
);
```
- `manager_id` is both the **primary key** of `managers` *and* a **foreign key** to `employees.employee_id` — this double role is exactly what forces "at most one `managers` row per employee" (since `manager_id` is a PK, it can't repeat).
- `department_id` is declared `UNIQUE` (and `NOT NULL`) — this forces "at most one `managers` row per department" too.
- Together, these two constraints make this a genuine 1:1 relationship in **two directions at once**: one employee ↔ one manager-role-row, and one department ↔ one manager-row.

**ASCII diagram:**
```
   employees                         managers                       departments
 ┌──────────────┐                 ┌──────────────┐                ┌──────────────┐
 │ employee_id 1│ ←── PK/FK ───── │ manager_id  1│                │department_id1│
 │ Aditi Rao     │                 │ department_id1│ ── FK,UNIQUE ─→│ Engineering  │
 └──────────────┘                 │ appointed_date│                └──────────────┘
                                   └──────────────┘
        1 employee  ───────────────  1 manager row  ───────────────  1 department
              (exactly one-to-one in both directions)
```

**Expected output:**
```sql
SELECT m.manager_id, e.first_name, e.last_name, d.department_name, m.appointed_date
FROM managers m
JOIN employees e ON e.employee_id = m.manager_id
JOIN departments d ON d.department_id = m.department_id
ORDER BY m.manager_id;
```
```
manager_id | first_name | last_name |  department_name | appointed_date
-----------+------------+-----------+-------------------+---------------
     1     |   Aditi    |    Rao    |    Engineering    |  2015-03-01
     7     |   Priya    |    Nair   |       Sales       |  2015-11-05
    10     |   Rohan    |   Kapoor  |         HR        |  2016-08-09
    12     |   Nikhil   |   Gupta   |      Finance      |  2016-12-01
    14     |   Rajesh   |    Iyer   |     Marketing     |  2017-09-30
```
Five rows — exactly one manager per department, no more, no less, which is the visible proof of the 1:1 constraint in action. (Chapter 7 will teach the `JOIN` syntax used here in full; for now, just read the result.)

**Common mistakes:** Modeling a 1:1 relationship by simply duplicating all of an employee's columns into a second table "for managers" — that's redundant and risks the two copies drifting out of sync. The `company_db` design instead keeps `managers` lean (only manager-specific facts: `department_id`, `appointed_date`) and reuses `employees` for everything else via the FK.

**Edge cases:** Not every employee has a corresponding `managers` row (only 5 of the 16 employees are managers) — a 1:1 relationship does not require *every* row on one side to have a partner; it only forbids more than one partner. This is sometimes called an "optional" one-to-one, as opposed to a "mandatory" one-to-one where every row on both sides must be paired.

**When to use / not use:** Use 1:1 modeling when a subset of rows in a table needs additional, optionally-present facts, or when you want to separate access control/permissions on sensitive extra columns. Don't split a table into two 1:1 tables "just because" if every row would need a matching row anyway with no security or optionality benefit — that's usually just added join overhead for no design benefit (Chapter 14 will cover this trade-off formally).

**Real-world use cases:** `users` and `user_security_settings` (split for security), `employees` and `employee_medical_records` (split for access control), or, as here, `employees` and `managers` (split to isolate a role-specific fact set).

### 1.11.2 One-to-Many (1:N)

**In plain language:** One-to-many is "one parent, many children" — one department has many employees, but each employee belongs to only one department at a time.

**In technical terms:** A **one-to-many relationship** exists when one row in Table A (the "one" side) can be referenced by *many* rows in Table B (the "many" side), but each row in Table B references only *one* row in Table A. It is implemented with a foreign key placed on the "many" side, pointing to the "one" side's primary key.

**`company_db` has four one-to-many relationships:**

| "One" side | "Many" side | FK column | Real-world meaning |
|---|---|---|---|
| `departments` | `employees` | `employees.department_id` | A department has many employees |
| `employees` | `salaries` | `salaries.employee_id` | An employee has many salary-history rows |
| `employees` | `attendance` | `attendance.employee_id` | An employee has many attendance days |
| `departments` | `projects` | `projects.department_id` | A department runs many projects |
| `employees` | `employees` (self) | `employees.manager_id` | A manager (employee) has many direct reports (employees) |

**ASCII diagram — `departments` to `employees`:**
```
   departments                              employees
 ┌───────────────┐                 ┌──────────────────────────────┐
 │department_id 1│ ─────────┐      │employee_id 1 │department_id 1│
 │ Engineering    │          ├────→│employee_id 2 │department_id 1│
 └───────────────┘          ├────→│employee_id 3 │department_id 1│
        "one"               ├────→│employee_id 4 │department_id 1│
                             ├────→│employee_id 5 │department_id 1│
                             ├────→│employee_id 6 │department_id 1│
                             └────→│employee_id16 │department_id 1│
                                   └──────────────────────────────┘
                                                "many"
```

**Expected output:**
```sql
SELECT d.department_name, COUNT(e.employee_id) AS employee_count
FROM departments d
LEFT JOIN employees e ON e.department_id = d.department_id
GROUP BY d.department_name
ORDER BY employee_count DESC;
```
```
department_name | employee_count
-----------------+---------------
Engineering      |       7
Sales            |       3
HR               |       2
Finance          |       2
Marketing        |       2
```
(This counts all 16 employees regardless of `status`; Engineering has 7 because employees 1–6 and 16 all belong to `department_id = 1`.)

**Common mistakes:** Placing the foreign key on the wrong side — the FK column always lives on the "many" side. `departments` never has an `employee_id` column; `employees` has `department_id`. Also, confusing "one department, many employees currently" with "one employee, one department forever" — the relationship as modeled is one department *per employee at any given time*, not a historical record of every department an employee ever worked in (that would require yet another table, a common real-world enhancement).

**Edge cases:** Because `employees.department_id` is nullable and `ON DELETE SET NULL`, an employee can transiently have `department_id = NULL` (if their department were deleted) — meaning the "many" side does not strictly require a matching "one" side row at all times, unless the FK column is also declared `NOT NULL`. Compare this with `salaries.employee_id`, which is `NOT NULL` — every salary row *must* belong to a real, existing employee, with no such escape hatch.

**When to use / not use:** One-to-many is the single most common relationship in relational design — use it whenever one entity naturally "owns" or "contains" many instances of another. There isn't really a "don't use it" case; the design decision is usually about *which* two entities have this relationship, not whether to use the pattern at all.

**Real-world use cases:** Customer → orders, blog post → comments, and — as shown twice above — department → employees and employee → salary history.

### 1.11.3 Many-to-Many (M:N)

**In plain language:** Many-to-many is "many of these can relate to many of those" — one employee can work on several projects, and one project can have several employees. Neither side can simply hold a single foreign key value, because each side needs to point at *multiple* rows on the other side.

**In technical terms:** A **many-to-many relationship** is implemented via a **junction (bridge/associative) table** that sits between the two entity tables, holding a foreign key to each, typically with a composite primary key across both foreign keys (Section 1.9.4). This decomposes the M:N relationship into two 1:N relationships — Table A to the junction, and Table B to the junction.

**The `company_db` example — `employees` ↔ `projects` via `employee_projects`:**
```sql
CREATE TABLE employee_projects (
    employee_id     INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    project_id      INT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    role            VARCHAR(100) NOT NULL,
    hours_allocated INT NOT NULL DEFAULT 0 CHECK (hours_allocated >= 0),
    PRIMARY KEY (employee_id, project_id)
);
```
Notice `employee_projects` also carries extra columns (`role`, `hours_allocated`) that describe the *relationship itself*, not either entity alone — Rahul Mehta isn't "Tech Lead" in general, he's "Tech Lead *on the Platform Migration project specifically*." This is a hallmark of a well-designed junction table: it's the natural home for facts that only make sense in the context of the pairing.

**ASCII diagram:**
```
   employees            employee_projects              projects
 ┌────────────┐      ┌─────────────────────────┐    ┌─────────────────┐
 │employee_id2│─────→│employee_id2 project_id1  │←───│project_id1       │
 │Rahul Mehta │──┐   │  role: Tech Lead          │    │Platform Migration│
 └────────────┘  │   └─────────────────────────┘    └─────────────────┘
                  │   ┌─────────────────────────┐    ┌─────────────────┐
                  └──→│employee_id2 project_id2  │←───│project_id2       │
                      │  role: Tech Lead          │    │Mobile App Revamp │
                      └─────────────────────────┘    └─────────────────┘
     "many"                    junction                    "many"
```

**Expected output:**
```sql
SELECT e.first_name, e.last_name, p.project_name, ep.role, ep.hours_allocated
FROM employee_projects ep
JOIN employees e ON e.employee_id = ep.employee_id
JOIN projects p  ON p.project_id  = ep.project_id
WHERE p.project_id = 1
ORDER BY e.employee_id;
```
```
first_name | last_name |   project_name    |      role       | hours_allocated
-----------+-----------+--------------------+------------------+----------------
  Rahul    |   Mehta   | Platform Migration |   Tech Lead      |      400
  Sneha    | Kulkarni  | Platform Migration | Senior Engineer  |      600
  Vikram   |   Joshi   | Platform Migration |    Engineer      |      500
```
Three employees on one project — the "many" side of employees. And Rahul Mehta himself appears on two different projects elsewhere in the table — the "many" side of projects. Both directions of "many" are visible across the full `employee_projects` table.

**Common mistakes:** Trying to model M:N with a single foreign key on either entity table directly (e.g., adding one `project_id` column to `employees`) — this only allows each employee to be on *one* project at a time, which contradicts the real-world requirement (Rahul Mehta is genuinely on two projects at once in the seed data) and is the single most common beginner modeling error.

**Edge cases:** A junction table's composite primary key (`employee_id, project_id`) inherently prevents the *same* employee from being recorded on the *same* project twice — if your business rules actually need to allow that (e.g., someone leaves and rejoins a project with a new role), you'd need a surrogate key on the junction table instead, plus a date range, to distinguish the separate stints.

**When to use / not use:** Any time two entities can each relate to multiple instances of the other, a junction table is mandatory — there's no valid way to model true M:N with foreign keys alone on the two entity tables. Don't over-engineer a junction table for a relationship that's actually 1:N in reality (verify real-world cardinality carefully before designing).

**Real-world use cases:** Students ↔ courses (via enrollments), actors ↔ movies (via a cast table), tags ↔ articles, and — exactly as here — employees ↔ projects.

### 1.11.4 Full Entity-Relationship Diagram of `company_db`

```
                              ┌───────────────┐
                              │  departments  │
                              │───────────────│
                              │ department_id │◄─────────────┐
                              │ department_name│              │
                              │ location       │              │
                              └───────┬───────┘              │
                     1  │             │ 1            1        │ 1
                        │             │                       │
                        ▼ N           ▼ N                     ▼ N
              ┌─────────────────┐  ┌───────────┐        ┌───────────┐
              │    employees    │  │  managers │        │  projects │
              │─────────────────│  │───────────│        │───────────│
   ┌──────────┤ employee_id     │◄─┤ manager_id│        │project_id │
   │  self-FK │ department_id   │  │department_│───(1:1)┘start_date │
   │ manager_id (nullable)      │  │ id (UNIQUE)│        │end_date   │
   └─────────►│ ...             │  │appointed_date       │budget     │
              └───┬────────┬────┘  └───────────┘        └─────┬─────┘
              1│           │1                                  │1
               │           │                                   │
              ▼N          ▼N                                  ▼N
     ┌─────────────┐ ┌────────────┐              ┌─────────────────────┐
     │  salaries   │ │ attendance │              │  employee_projects  │
     │─────────────│ │────────────│              │──────────────────────│
     │salary_id    │ │attendance_ │      ┌───────►│employee_id (FK, PK1) │
     │employee_id  │ │id          │      │        │project_id  (FK, PK2)│
     │base_salary  │ │employee_id │      │        │role                  │
     │bonus        │ │work_date   │      │        │hours_allocated       │
     │effective_date│ │status      │      │        └──────────────────────┘
     └─────────────┘ │check_in/out│      │
                      └────────────┘      │
                                            │
                          employees ───────┘ (many-to-many bridge back to employees)
```

**Reading the diagram:** `departments` is the hub — it's the "one" side of three separate relationships (to `employees`, to `managers`, and to `projects`). `employees` is itself a hub for `salaries` and `attendance` (both 1:N, employee-history tables), has a 1:1 relationship out to `managers`, has a self-referencing 1:N relationship for the org hierarchy (`manager_id`), and reaches `projects` only indirectly, through the `employee_projects` M:N bridge.

**Practice questions (relationships, combined):**
1. Classify each of these as 1:1, 1:N, or M:N: `departments`↔`employees`; `employees`↔`managers`; `employees`↔`salaries`; `employees`↔`projects`; `departments`↔`managers`.
2. Which table would you query to find every project a given employee has ever worked on, and why can't you answer that with just `employees` and `projects`?
3. Why is `manager_id` on `employees` itself (rather than `managers`) the correct place to model "who is this employee's manager" as a 1:N relationship, distinct from the 1:1 `managers` table?
4. Give a real-world scenario (not company_db) that is genuinely 1:1, and justify why it isn't secretly 1:N.
5. Why does `employee_projects` need its own `role` and `hours_allocated` columns rather than just being a bare list of `(employee_id, project_id)` pairs?
6. Suppose the business now requires tracking every department an employee has *ever* belonged to (job-history), not just the current one. What kind of relationship change would that require, and what new table might you introduce?
7. Which relationship in `company_db` allows a row on the "many" side to have `NULL` as its foreign key value, and why does that make sense there specifically?
8. Draw (on paper) the 1:N relationship between `departments` and `projects` using the ASCII style shown above, substituting in the actual five departments and five projects from the seed data.

---

## 1.12 Referential Integrity

**In plain language:** Referential integrity is the rule that every "pointer" in your database must point to something that actually exists — no employee can belong to department `99` if department `99` was never created, and no salary row can survive pointing at an employee who no longer exists.

**In technical terms:** **Referential integrity** is the guarantee that foreign key values always correspond to an existing (or `NULL`, if nullable) primary/unique key value in the referenced table — maintained automatically by the DBMS through foreign key constraints and their referential actions.

**Why it exists:** Without it, deleting a department would silently leave behind employees whose `department_id` points to nothing — a "dangling reference." Every later query joining `employees` to `departments` for that row would either mysteriously drop the row (`INNER JOIN`) or show a broken/missing department (`LEFT JOIN`), and no error would ever have been raised at the time of the actual damage — the classic symptom of *silent data corruption*, one of the worst categories of production bugs because it's invisible until much later.

**The four referential actions, all present in `company_db`:**

| Action | Meaning | `company_db` example |
|---|---|---|
| `CASCADE` | Deleting/updating the parent automatically deletes/updates matching child rows | `salaries.employee_id ON DELETE CASCADE` — delete an employee, their salary history goes too |
| `SET NULL` | Deleting the parent sets the child's FK column to `NULL` instead of deleting the child | `employees.department_id ON DELETE SET NULL` — delete a department, its employees remain but become departmentless |
| `RESTRICT` / `NO ACTION` (default) | Deleting the parent is blocked entirely if any child rows still reference it | `projects.department_id` — declared with no `ON DELETE` clause at all, so PostgreSQL defaults to `NO ACTION` |
| `SET DEFAULT` | Deleting the parent resets the child's FK column to a declared default value | *(not used anywhere in `company_db`, but common in other schemas)* |

**Worked example 1 — `CASCADE` on `salaries`:**
```sql
employee_id INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
```
```sql
DELETE FROM employees WHERE employee_id = 6;  -- Karan Verma
```
Effect: Karan Verma's row in `employees` is removed, **and** PostgreSQL automatically also deletes his two dependent rows: the `salaries` row (`salary_id` for `employee_id = 6`, base 80000) and his `attendance` rows, and his `employee_projects` row (project 2, Engineer) — all `ON DELETE CASCADE`. Nothing is left dangling.

**Worked example 2 — `SET NULL` on `employees.department_id`:**
```sql
department_id INT REFERENCES departments(department_id) ON DELETE SET NULL,
```
```sql
DELETE FROM departments WHERE department_id = 5;  -- Marketing
```
Effect: The `departments` row for Marketing is removed. Employees Rajesh Iyer and Pooja Reddy are **not deleted** — instead, their `department_id` becomes `NULL`. They remain employees of the company with no assigned department, which is a deliberate business decision baked into the schema (people aren't deleted just because their department was dissolved).

**Worked example 3 — default `NO ACTION` (`RESTRICT`-like) on `projects.department_id`:**
```sql
department_id   INT REFERENCES departments(department_id),   -- no ON DELETE clause at all
```
```sql
DELETE FROM departments WHERE department_id = 1;  -- Engineering, has projects 1 and 2
```
Expected output:
```
ERROR:  update or delete on table "departments" violates foreign key constraint "projects_department_id_fkey" on table "projects"
DETAIL:  Key (department_id)=(1) is still referenced from table "projects".
```
Because no `ON DELETE` action was specified, PostgreSQL's default (`NO ACTION`) simply **blocks** the delete outright while dependent `projects` rows still exist — it neither cascades nor nulls anything; it refuses the operation.

**What happens internally:** Every write to a table with an outgoing foreign key triggers a lookup against the referenced table's unique index to confirm the referenced value exists. Every delete/update on a table that is *referenced by* other tables' foreign keys triggers a check (and, if applicable, a cascading action) against every dependent table's rows — PostgreSQL implements this via internal trigger-like mechanisms attached to the constraint, invisible in your DDL but very real in execution cost, which is why cascading deletes on large, heavily-referenced tables are a genuine performance concern (revisited in Chapter 16 and Chapter 26).

**Common mistakes:**
- Choosing `CASCADE` when you actually meant `SET NULL` (or vice versa) — accidentally cascading a delete can wipe out far more data than intended. Always ask "if the parent disappears, should the child disappear too, or just lose its reference?" before picking an action.
- Assuming "no `ON DELETE` clause" means "nothing happens" — it actually means the strictest option (block the delete), which is the safest default but can be surprising if you expected silence.
- Forgetting that referential integrity constraints apply to `UPDATE`s of the referenced key too (`ON UPDATE`), not just `DELETE`s — `company_db` doesn't declare explicit `ON UPDATE` actions, so they default to `NO ACTION` as well, meaning you technically cannot change a `department_id`'s value once employees reference it, without first handling dependents.

**Edge cases:** Cascading deletes can ripple multiple levels deep — deleting an employee cascades to their `salaries`, `attendance`, and `employee_projects` rows, but does *not* cascade further "sideways" to, say, other employees who report to them (`manager_id` uses `SET NULL`, not `CASCADE`), so a deleted manager's direct reports survive with `manager_id` reset to `NULL` rather than being deleted themselves. Study each foreign key's action independently — don't assume uniform behavior across a schema.

**When to use / not use each action:**
- `CASCADE`: child rows have no independent meaning without the parent (a salary history row means nothing once its employee is gone).
- `SET NULL`: child rows are independently meaningful and should survive (an employee is still a real person/record even without a department).
- `RESTRICT`/`NO ACTION`: you want to force an explicit, deliberate cleanup decision before allowing the parent to be removed (you should not be able to casually delete a department that still has active projects).

**Real-world use cases:** Deleting a customer cascades to their shopping cart items but not to their historical orders (which might use `RESTRICT` or a soft-delete instead, precisely to preserve financial history) — referential integrity design choices like this directly encode business policy, not just technical plumbing.

**Practice questions:**
1. Name every foreign key in `company_db` and its `ON DELETE` action (including ones with no explicit clause, which default to `NO ACTION`).
2. If you deleted `employee_id = 2` (Rahul Mehta, who is also a manager), what would happen to the `managers` row where `manager_id = 2`? (Hint: check what `ON DELETE` action, if any, is declared on `managers.manager_id`.)
3. If you deleted `department_id = 2` (Sales), what happens to `employees` rows currently in Sales? What happens to the `managers` row for Sales? Are these two outcomes consistent, and if not, why not?
4. Why does `salaries.employee_id` use `CASCADE` while `employees.department_id` uses `SET NULL`, given they're conceptually similar "child depends on parent" relationships?
5. What SQL error would you expect if you tried to delete `department_id = 1` (Engineering) directly, given the current seed data?
6. Explain, from first principles, why referential integrity prevents "silent" data corruption specifically (as opposed to just any data corruption).

---

## 1.13 NULL

**In plain language:** `NULL` means "we don't know" or "not applicable" — it is not zero, not an empty string, not "false." It's the database's way of saying "there is genuinely no value here," the same way an empty box on a paper form (never filled in) is different from a box where someone deliberately wrote "0" or "N/A."

**In technical terms:** `NULL` represents the *absence* of a value in SQL's three-valued logic system (`TRUE`, `FALSE`, `UNKNOWN`). Any comparison involving `NULL` (e.g., `NULL = NULL`, `5 = NULL`) evaluates to `UNKNOWN`, not `TRUE` or `FALSE` — this is the single most important, most frequently misunderstood fact in all of SQL, and it will resurface in nearly every future chapter (`WHERE`, joins, aggregates, `CASE`).

**Why it exists:** Real-world data legitimately has gaps. An employee who hasn't been assigned a manager yet (the CTO, Aditi Rao) has no `manager_id` — writing `0` would falsely imply "manager with ID 0 exists," and writing an empty string would be nonsensical for an integer column anyway. `NULL` is the only semantically correct way to represent "this fact does not exist for this row."

**Where `NULL` appears in `company_db`:**
```sql
manager_id      INT REFERENCES employees(employee_id) ON DELETE SET NULL,  -- nullable
department_id   INT REFERENCES departments(department_id) ON DELETE SET NULL,  -- nullable
check_in        TIME,   -- nullable, no default, no NOT NULL
check_out       TIME,   -- nullable
end_date        DATE,   -- nullable
```
- Aditi Rao (`employee_id = 1`): `manager_id IS NULL` — the CTO reports to no one; there's no meaningful manager to record.
- Employee 4 on `2024-01-02`, status `'ABSENT'`: `check_in IS NULL` and `check_out IS NULL` — there is no check-in time because the employee didn't come in at all; recording `00:00` would be actively wrong (it would claim they checked in at midnight).
- Project 2 ("Mobile App Revamp"): `end_date IS NULL` — the project hasn't ended; there is no end date yet, which is different from an end date of "today" or any specific placeholder date.

**Expected output — `NULL` in query results:**
```sql
SELECT employee_id, first_name, manager_id FROM employees WHERE manager_id IS NULL;
```
```
employee_id | first_name | manager_id
------------+------------+-----------
     1      |   Aditi    |    NULL
```
Notice the comparison `WHERE manager_id IS NULL` — not `WHERE manager_id = NULL`. This is not a stylistic choice.

```sql
SELECT employee_id, first_name, manager_id FROM employees WHERE manager_id = NULL;
```
```
(0 rows)
```
**This returns zero rows, even for Aditi Rao, whose `manager_id` genuinely is `NULL`.** This is the most common `NULL`-related bug in all of SQL: `= NULL` never matches anything, because `x = NULL` always evaluates to `UNKNOWN`, and `WHERE` only keeps rows where the condition is `TRUE` (rows evaluating to `UNKNOWN` are filtered out, exactly like `FALSE` rows). You must use `IS NULL` / `IS NOT NULL` to test for `NULL` correctly. Chapter 5 covers `NULL`-safe functions (`COALESCE`, `NULLIF`) in depth.

**NULL vs. 0 vs. empty string (`''`) — the three are fundamentally different concepts:**

| | `NULL` | `0` | `''` (empty string) |
|---|---|---|---|
| Meaning | Unknown / not applicable / absent | A real, known numeric value: zero | A real, known string value: zero-length text |
| Applies to which types | Any nullable column, any type | Numeric types | Character types only (`VARCHAR`, `TEXT`, `CHAR`) |
| `= comparison behavior` | `x = NULL` is always `UNKNOWN` | `x = 0` behaves like any normal comparison | `x = ''` behaves like any normal comparison |
| `company_db` example | `employees.manager_id` for Aditi Rao | `salaries.bonus` defaults to `0` when no bonus is given — a **known fact**: "this person's bonus is exactly zero" | *(not used in `company_db`'s seed data, but e.g. a `middle_name` column *could* validly hold `''` to mean "explicitly recorded as having none," distinct from `NULL` meaning "we never asked")* |
| Storage | Takes (almost) no space; stored as a presence bitmap in PostgreSQL, not as a value | Stored as an actual value | Stored as an actual (zero-length) value |
| Counted by `COUNT(column)`? | No — `COUNT(column)` skips `NULL`s | Yes | Yes |

**Concrete illustration using `salaries.bonus`:**
```sql
bonus NUMERIC(10,2) NOT NULL DEFAULT 0,
```
Every single `bonus` value in `company_db` is a known number (possibly `0`, as would be the case for an employee with no bonus that period) — never `NULL`, because the column is declared `NOT NULL`. This is a deliberate design choice: the schema author decided "we always know the bonus amount; if there isn't one, it's factually zero, not unknown." Contrast that with `check_in`/`check_out` on `attendance`, which *are* nullable, because "what time did an absent employee check in?" has no factual answer at all — not even zero.

**What happens internally:** PostgreSQL stores `NULL` using a per-row null bitmap alongside the row's data, rather than storing an actual zero-length or zero-value payload for that column — this is why `NULL` is typically cheaper to store than an actual empty string or zero, and why `NULL` in an index behaves specially (in a B-tree index, `NULL`s are typically grouped together, and most operators don't match against them, again due to `UNKNOWN` semantics).

**Common mistakes:**
1. Writing `WHERE column = NULL` instead of `WHERE column IS NULL` (shown above) — silently returns zero rows instead of erroring, which makes this bug especially dangerous.
2. Using `0` as a substitute for "unknown" in a numeric column (e.g., recording a missing salary as `0` instead of leaving it `NULL` or refusing the insert) — this corrupts aggregates like `AVG()`, since a real `0` pulls the average down as if that person truly earns nothing, while a `NULL` is correctly excluded from `AVG()`'s calculation.
3. Using `''` to mean "unknown" in a text column when you actually mean `NULL` — these have different semantics for uniqueness constraints (recall from 1.9.3 that multiple `NULL`s are allowed in a `UNIQUE` column, but multiple `''`s are treated as duplicate *values* and would violate uniqueness).
4. Forgetting that string concatenation with `NULL` produces `NULL` in standard SQL: `'Hello ' || NULL` evaluates to `NULL`, not `'Hello '` — **[PostgreSQL]**/**[Oracle]** both follow this standard behavior with `||`; **[MySQL]**'s `CONCAT()` function is a notable exception — `CONCAT('Hello ', NULL)` returns `'Hello '` in MySQL, silently treating `NULL` as an empty string, which is a real, frequently-cited cross-dialect gotcha.

**Edge cases:**
- `NULL` in arithmetic: `5 + NULL` is `NULL` (unknown plus anything is still unknown).
- `NULL` in aggregates: `COUNT(*)` counts all rows including those with `NULL`s, but `COUNT(column_name)` counts only non-`NULL` values in that column — a very common point of confusion covered fully in Chapter 6.
- `NULL` and `UNIQUE`: as covered in 1.9.3, most RDBMSs (including PostgreSQL) allow multiple `NULL`s in a `UNIQUE` column, because `NULL` is never considered equal to another `NULL` for uniqueness-checking purposes. **[SQL Server]** historically only allows a single `NULL` in a column with a `UNIQUE` *index* prior to filtered indexes being used to work around it — a genuine cross-dialect divergence worth remembering.
- Sorting: `NULL` sorts *last* by default in `ORDER BY ... ASC` in PostgreSQL, but this default placement differs across RDBMSs (Chapter 4 covers `NULLS FIRST`/`NULLS LAST` explicitly).

**When to use / not use `NULL`:** Use `NULL` exactly when a fact is genuinely unknown, not-yet-determined, or not applicable to this row — never as a stand-in for a real, known "zero" or "empty" value. If a column should never legitimately lack a value (like `first_name` or `email`), declare it `NOT NULL` so the constraint itself documents and enforces that expectation.

**Compare with related concepts:** `NULL` vs. `DEFAULT` — a `DEFAULT` clause supplies a real, known value automatically; it is a way to *avoid* `NULL`, not a form of it. `NULL` vs. `0`/`''` — covered fully in the table above; the short version is "`NULL` means unknown, `0`/`''` mean known-and-empty/zero."

**Real-world use cases:** A `middle_name` column left `NULL` for someone who was never asked, versus `''` for someone who was asked and confirmed they have none; a `cancelled_at` timestamp that is `NULL` for every order that hasn't been cancelled (rather than some sentinel date like `'9999-12-31'`, which is a common and much worse anti-pattern).

**Practice questions:**
1. Name every column in `company_db`'s DDL that is nullable (i.e., has no `NOT NULL`), across all seven tables.
2. Why does `WHERE manager_id = NULL` return zero rows even though Aditi Rao's `manager_id` is genuinely `NULL`? What should be used instead?
3. Explain, using `salaries.bonus`, why `NOT NULL DEFAULT 0` was the right design choice rather than leaving `bonus` nullable.
4. Why can't a missing `check_in` time on an absent day be reasonably represented as `00:00` instead of `NULL`?
5. What does `COUNT(check_in)` return for `attendance` rows where the employee was `'ABSENT'`, compared to `COUNT(*)` on the same rows? (Reason it out conceptually — you'll verify by running it once you reach Chapter 6.)
6. In standard SQL, what does `'Rahul ' || NULL` evaluate to? What would the equivalent MySQL `CONCAT()` call return instead?
7. Can two different `employees` rows both have `email = NULL`, given the current schema? Why or why not (hint: check the `NOT NULL` on `email`)?
8. If `department_id` were changed to `NOT NULL` on `employees`, what would happen the next time a referenced department was deleted, given the FK's current `ON DELETE SET NULL` action? Would the schema become internally inconsistent?

---

## 1.14 Data Types — The Landscape

**In plain language:** A data type is a label that tells the database "this column only holds numbers," or "this column only holds text," or "this column only holds a date" — the same way a form field labeled "Age" implicitly rejects "purple" as an answer.

**In technical terms:** A **data type** constrains the set of valid values a column can hold, determines how those values are stored on disk (fixed vs. variable width, byte layout), and determines which operators and functions are valid against the column (you can't take the square root of a string). This section is a landscape overview only — deep dives on numeric precision, string encoding, date arithmetic, and semi-structured types (JSON, arrays, UUID, ENUM) come in Chapter 25; for now, the goal is to recognize the major families and how the same *idea* is spelled differently across products.

**Why data types exist:** Without them, every column would just be an untyped blob, and the database could never validate input (`'abc'` in a salary column), optimize storage (a `TIME` value is much more compact than a text representation of it), or provide type-appropriate operations (date arithmetic, numeric aggregation, pattern matching).

### Integer types

Used for whole numbers with no fractional part — `company_db` uses this family for every surrogate key (Section 1.9.6) and every count-like value (`hours_allocated`).

```sql
department_id   SERIAL PRIMARY KEY,   -- effectively an INTEGER, auto-incrementing
hours_allocated INT NOT NULL DEFAULT 0 CHECK (hours_allocated >= 0),
```

| | **[PostgreSQL]** | **[MySQL]** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Small | `SMALLINT` (2 bytes) | `TINYINT`, `SMALLINT` | `NUMBER(38)` (no true small-int type) | `tinyint`, `smallint` |
| Standard | `INTEGER`/`INT` (4 bytes) | `INT`/`INTEGER` | `NUMBER(38)` or `INTEGER` (alias for `NUMBER`) | `int` |
| Large | `BIGINT` (8 bytes) | `BIGINT` | `NUMBER(38)` | `bigint` |
| Auto-increment PK | `SERIAL`/`BIGSERIAL` or `GENERATED ... AS IDENTITY` (SQL-standard, preferred in modern PostgreSQL) | `AUTO_INCREMENT` | `IDENTITY` column (12c+) or manual `SEQUENCE` + trigger (pre-12c) | `IDENTITY(seed, increment)` property |

> **Important Note:** `SERIAL` in PostgreSQL is not really a distinct *type* — it's shorthand that expands to an `INTEGER` column, a backing sequence object, and a `DEFAULT nextval(...)` clause. `department_id SERIAL PRIMARY KEY` is equivalent to manually creating an `INTEGER` column, a sequence, wiring the default, and marking the sequence as "owned by" the column. Modern PostgreSQL style increasingly favors the SQL-standard `GENERATED ALWAYS AS IDENTITY` syntax over `SERIAL`, though `company_db.sql` (and much real-world code) still uses `SERIAL` for brevity — you'll see both across this course.

Oracle notably has **no dedicated integer storage type** at all — everything numeric is `NUMBER(precision, scale)` internally, and `INTEGER`/`INT` are just aliases mapped to `NUMBER(38)` with scale 0.

### Numeric / Decimal (exact, fixed-precision numbers)

Used for money and any value where floating-point rounding error is unacceptable — `company_db` uses this for every currency amount.

```sql
base_salary   NUMERIC(10,2) NOT NULL CHECK (base_salary > 0),
bonus         NUMERIC(10,2) NOT NULL DEFAULT 0,
budget        NUMERIC(12,2) CHECK (budget >= 0),
```
`NUMERIC(10,2)` means "up to 10 total digits, 2 of them after the decimal point" — so `520000.00` (Aditi Rao's later salary) fits comfortably, and any attempt to store a value needing more than 8 digits before the decimal point would be rejected.

| | **[PostgreSQL]** | **[MySQL]** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Exact decimal type | `NUMERIC(p,s)` / `DECIMAL(p,s)` (identical, exact) | `DECIMAL(p,s)` / `NUMERIC(p,s)` (identical, exact) | `NUMBER(p,s)` | `DECIMAL(p,s)` / `NUMERIC(p,s)` |

> **⚠️ Warning:** Never use floating-point types (`REAL`/`FLOAT`/`DOUBLE PRECISION`) for money. They cannot represent many decimal fractions exactly (a classic example: `0.1 + 0.2` does not equal exactly `0.3` in binary floating point), which is precisely why `company_db` uses `NUMERIC` for every salary, bonus, and budget column instead.

### Character / String types (`VARCHAR`, `TEXT`, `CHAR`)

Used for names, titles, emails, statuses — `company_db` uses `VARCHAR(n)` throughout and `CHAR(3)` once, for a fixed-width currency code.

```sql
first_name  VARCHAR(50) NOT NULL,
email       VARCHAR(150) NOT NULL UNIQUE,
currency    CHAR(3) NOT NULL DEFAULT 'USD',
```
- `VARCHAR(n)` — variable-length string, up to `n` characters; only uses as much storage as the actual content requires (plus a small length header).
- `CHAR(n)` — fixed-length string, always padded to exactly `n` characters; ideal for genuinely fixed-width codes like ISO currency codes (`'USD'`, `'INR'`) or country codes.

| | **[PostgreSQL]** | **[MySQL]** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Variable length | `VARCHAR(n)`, `TEXT` (no perf penalty vs. `VARCHAR`, no length limit) | `VARCHAR(n)` (row-size limits apply), `TEXT`/`MEDIUMTEXT`/`LONGTEXT` for large content | `VARCHAR2(n)` (byte or char semantics depending on setting), `CLOB` for large content | `VARCHAR(n)`, `VARCHAR(MAX)`; `NVARCHAR(n)` for Unicode |
| Fixed length | `CHAR(n)` | `CHAR(n)` | `CHAR(n)` | `CHAR(n)`, `NCHAR(n)` |

> **Important Note:** In **[PostgreSQL]** specifically, there is no meaningful performance difference between `VARCHAR(n)` and `TEXT` — `VARCHAR(n)` is really just `TEXT` with an added length check constraint. This is *not* true in every product; **[MySQL]**, **[Oracle]**, and **[SQL Server]** all have real structural/performance distinctions between their bounded and unbounded text types.

### Date / Time types

Used for `hire_date`, `effective_date`, `work_date`, `check_in`/`check_out`, `appointed_date`, `start_date`/`end_date`, and audit timestamps like `created_at`.

```sql
hire_date    DATE NOT NULL,
check_in     TIME,
created_at   TIMESTAMP NOT NULL DEFAULT now(),
```

| | **[PostgreSQL]** | **[MySQL]** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Date only | `DATE` | `DATE` | `DATE` (⚠️ actually always includes a time component internally, defaulting to midnight) | `DATE` |
| Time only | `TIME [WITHOUT/WITH TIME ZONE]` | `TIME` | *(no dedicated TIME-only type; modeled via `DATE` or `INTERVAL`)* | `TIME` |
| Date + time | `TIMESTAMP [WITHOUT/WITH TIME ZONE]` | `DATETIME`, `TIMESTAMP` (narrower range, auto-updates available) | `TIMESTAMP` | `DATETIME`, `DATETIME2` (higher precision, wider range), `DATETIMEOFFSET` (with timezone) |

> **⚠️ Warning:** **[Oracle]**'s `DATE` type is a well-known trap for people coming from other dialects — it always stores a time-of-day component (defaulting to midnight if unspecified), unlike PostgreSQL/MySQL/SQL Server's `DATE`, which genuinely stores no time information at all.

`company_db`'s `attendance.check_in`/`check_out` deliberately use `TIME` (not `TIMESTAMP`) because only the time-of-day matters for a check-in — the date is already captured separately in `work_date`, and duplicating it inside `check_in` would be redundant (a preview of normalization principles from Chapter 14).

### Boolean

`company_db` doesn't happen to use a boolean column (it models `status` as a `VARCHAR` with a `CHECK` constraint instead, deliberately, to support three states rather than two — `'ACTIVE'`, `'ON_LEAVE'`, `'TERMINATED'`), but boolean support differs sharply across products and you will need it constantly in later chapters and in `ecommerce_db`/`banking_db`.

| | **[PostgreSQL]** | **[MySQL]** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Native boolean type | Yes — `BOOLEAN` (`TRUE`/`FALSE`/`NULL`) | No true type — `BOOLEAN` is an alias for `TINYINT(1)` (`0`/`1`) | No native SQL `BOOLEAN` before 23c — conventionally modeled as `NUMBER(1)` or `CHAR(1)` (`'Y'`/`'N'`) | No native `BOOLEAN` — `BIT` (`0`/`1`/`NULL`) fills the role |

> **Important Note:** `company_db`'s three-state `status` column (`'ACTIVE'`/`'ON_LEAVE'`/`'TERMINATED'`) is a good real-world illustration of *why* you shouldn't reach for boolean too quickly — "is this employee active?" is really a three-valued business question, not a true/false one, and modeling it as `is_active BOOLEAN` would have lost the `'ON_LEAVE'` distinction entirely.

### UUID

Not used in `company_db` (which uses integer surrogate keys throughout), but extremely common in modern distributed systems and used elsewhere in this course.

| | **[PostgreSQL]** | **[MySQL]** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Native type | Yes — `UUID`, generate with `gen_random_uuid()` (built-in since PG13) or the `uuid-ossp` extension | No native type — typically `CHAR(36)` (text form) or `BINARY(16)` (compact); generate with `UUID()` | No native type — `RAW(16)`; generate with `SYS_GUID()` | `UNIQUEIDENTIFIER`; generate with `NEWID()`/`NEWSEQUENTIALID()` |

Integer surrogate keys (`company_db`'s approach) are compact and naturally sortable by creation order; UUID surrogate keys avoid ever leaking a guessable sequential ID and make it trivial to generate a unique ID *before* inserting a row (useful in distributed systems) — a genuine, situational trade-off you'll examine more closely in Chapter 25.

### JSON

Not used in `company_db` either, but worth knowing the landscape now since Chapter 25 covers it deeply.

| | **[PostgreSQL]** | **[MySQL]** | **[Oracle]** | **[SQL Server]** |
|---|---|---|---|---|
| Native type | `JSON` (text-preserving) and `JSONB` (binary, indexable, generally preferred) | `JSON` (native, validated, since 5.7) | `JSON` (native since 21c; earlier versions used `CLOB` + `IS JSON` check constraint) | No dedicated storage type historically — `NVARCHAR` + `JSON_VALUE()`/`JSON_QUERY()`/`OPENJSON()` functions; a native `JSON` type has been introduced in newer SQL Server/Azure SQL releases |

**Summary landscape table (quick reference):**

| Family | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| Integer | `SMALLINT`/`INTEGER`/`BIGINT` | `TINYINT`…`BIGINT` | `NUMBER(38)` | `tinyint`…`bigint` |
| Exact decimal | `NUMERIC`/`DECIMAL` | `DECIMAL`/`NUMERIC` | `NUMBER(p,s)` | `DECIMAL`/`NUMERIC` |
| Variable string | `VARCHAR`/`TEXT` | `VARCHAR`/`TEXT` family | `VARCHAR2`/`CLOB` | `VARCHAR`/`NVARCHAR` |
| Date | `DATE` | `DATE` | `DATE` (has time!) | `DATE` |
| Timestamp | `TIMESTAMP`/`TIMESTAMPTZ` | `DATETIME`/`TIMESTAMP` | `TIMESTAMP` | `DATETIME2`/`DATETIMEOFFSET` |
| Boolean | `BOOLEAN` | `TINYINT(1)` alias | `NUMBER(1)`/`CHAR(1)` | `BIT` |
| UUID | `UUID` | `CHAR(36)`/`BINARY(16)` | `RAW(16)` | `UNIQUEIDENTIFIER` |
| JSON | `JSON`/`JSONB` | `JSON` | `JSON` (21c+) | `NVARCHAR` + functions (native type in newest releases) |

**Common mistakes:** Choosing `FLOAT`/`REAL` for money (covered above); choosing `VARCHAR` with an arbitrarily tiny length limit that later truncates real data (e.g., `VARCHAR(20)` for `email`, when `company_db` correctly uses `VARCHAR(150)`); assuming boolean logic is available identically everywhere (it isn't — see above).

**Edge cases:** A `CHAR(3)` column like `currency` will silently space-pad shorter input in some products' internal storage representation, though comparisons generally still behave as expected; always prefer `VARCHAR` unless the field is genuinely fixed-width by definition (like a 3-letter currency code).

**When to use / not use:** Use the narrowest, most semantically correct type available (an integer for counts, `NUMERIC` for money, `DATE` for dates without times, `BOOLEAN`/appropriate equivalent for true two-state flags, a constrained `VARCHAR` + `CHECK` for small fixed enumerations as `company_db` does for `status`). Avoid "stringly-typed" columns (storing numbers or dates as plain text) purely for convenience — you lose validation, indexing efficiency, and correct sorting/arithmetic.

**Real-world use cases:** Every column in `company_db` is itself a real-world use case — this table is a map you'll refer back to for the rest of the course, especially once Chapter 25 returns to JSON, arrays, ENUM, and UUID in full depth.

**Practice questions:**
1. Why does `company_db` use `NUMERIC(10,2)` instead of a floating-point type for `base_salary` and `bonus`?
2. What does the `(10,2)` in `NUMERIC(10,2)` mean, precisely?
3. Why is `currency` declared `CHAR(3)` rather than `VARCHAR(3)`, and would `VARCHAR(3)` have worked functionally?
4. Explain why `check_in`/`check_out` use `TIME` rather than `TIMESTAMP`, given that `work_date` already exists as a separate column.
5. What is `SERIAL` actually shorthand for, internally, in PostgreSQL?
6. Why does `company_db` model `status` as a `VARCHAR` with a `CHECK` constraint rather than a `BOOLEAN`, and what would be lost if it were boolean instead?
7. Name the closest MySQL and SQL Server equivalents to PostgreSQL's native `BOOLEAN` type.
8. Which of the four RDBMS products in this course has no dedicated integer storage type, using a single numeric type for everything instead?

---

## Challenge Problem — Bringing It All Together

Without writing or running any SQL yet (that begins in Chapter 2), work through the following using only the `company_db.sql` DDL and seed data, and your own reasoning:

> A new business requirement arrives: **"We need to track every department an employee has ever belonged to, with start and end dates for each assignment, not just their current department."**
>
> 1. Explain why the *current* schema (`employees.department_id` as a single nullable foreign key) cannot represent this requirement, using the concepts of one-to-many relationships from Section 1.11.
> 2. Design (on paper, in prose or an ASCII diagram — no SQL required) a new table that would satisfy this requirement. Decide: What should its primary key be — natural, surrogate, or composite? What foreign key(s) does it need, and to which tables? What `NOT NULL` and `CHECK` constraints would meaningfully protect this data (hint: think about what invalid date ranges would look like, drawing on the `projects.CHECK (end_date IS NULL OR end_date >= start_date)` pattern)?
> 3. Explain what should happen to rows in your new table if an employee is deleted (`CASCADE`, `SET NULL`, or `RESTRICT`) and justify your choice using the referential integrity vocabulary from Section 1.12.
> 4. Explain what should happen to rows in your new table if a department is deleted, and justify it the same way.
> 5. Identify whether `NULL` should be allowed in your new table's "end date" column, and explain precisely what `NULL` would mean there versus a real date value — tying back to Section 1.13's NULL-vs-known-value distinction.
> 6. Is the relationship your new table introduces between `employees` and `departments` still one-to-many, or has it become many-to-many? Justify carefully — an employee can now have *multiple* department-history rows, but does that necessarily make it M:N, or could it still be modeled as two separate 1:N relationships? (Revisit Section 1.11.3's definition of what actually makes a relationship many-to-many before answering.)

This problem deliberately has no single graded "correct" SQL answer in this chapter — the goal is to prove you can reason about keys, relationships, constraints, referential integrity, and `NULL` together, as a designer, before you ever type `CREATE TABLE`. You'll revisit this exact scenario with real SQL once you reach Chapter 13 (Constraints) and Chapter 14 (Database Design & Normalization).

---

## Key Takeaways

> - **Data** is raw, uninterpreted facts; a **database** organizes data into structured, persistent, queryable **information**; a **DBMS** is the software that manages databases; an **RDBMS** is a DBMS built on the relational model (tables, rows, columns, keys); **SQL** is the standardized language used to talk to an RDBMS.
> - **PostgreSQL, MySQL, Oracle, and SQL Server** are competing RDBMS *products*, each implementing SQL as a *dialect* with real, memorable differences (`LIMIT` vs. `TOP` vs. `FETCH FIRST`, `SERIAL` vs. `AUTO_INCREMENT` vs. `IDENTITY`, native `BOOLEAN`/`JSON`/`UUID` support or the lack of it).
> - A **database** and a **schema** are different containment levels; in PostgreSQL, `company_db` is technically a *schema*, and MySQL uniquely treats "database" and "schema" as synonyms — always check which product you're in.
> - A **table** is rows (records) of named columns (fields); the same table can legitimately hold *many* rows per real-world entity (`salaries` holds full salary history, not one row per employee).
> - **Candidate keys** are every column set capable of uniquely identifying a row; one becomes the **primary key**, the rest become **alternate keys**; keys spanning multiple columns are **composite keys**; **natural keys** carry real-world meaning and can change, while **surrogate keys** are meaningless, stable, system-generated identifiers — `company_db` defaults to surrogate PKs (`employee_id`, `department_id`, ...) precisely to insulate the schema from real-world change.
> - **Foreign keys** implement relationships and are the mechanism behind **referential integrity** — enforced through `CASCADE`, `SET NULL`, and `RESTRICT`/`NO ACTION`, each encoding a real business decision about what should happen when a parent row disappears.
> - Relationships come in three shapes: **one-to-one** (`employees` ↔ `managers`), **one-to-many** (`departments` → `employees`), and **many-to-many** (`employees` ↔ `projects`, via the `employee_projects` junction table).
> - **`NULL`** means "unknown/not applicable" and is never equal to `0`, `''`, or even another `NULL` — always test it with `IS NULL`/`IS NOT NULL`, never `= NULL`.
> - **Data types** constrain and describe every column's valid values and storage; the same conceptual type (integer, decimal, string, date, boolean, UUID, JSON) is spelled differently — and sometimes behaves differently — across PostgreSQL, MySQL, Oracle, and SQL Server.

## What's Next

Chapter 2 — **SQL Environment & Syntax** — moves from concepts to keyboard: installing/connecting to PostgreSQL, `psql` basics, the anatomy of a SQL statement (clauses, keywords, identifiers, literals, comments), statement terminators, case-sensitivity and quoting rules, and how to actually load and explore the `company_db` schema you've been reasoning about throughout this chapter. Everything you just learned conceptually — tables, keys, constraints, relationships, NULL — becomes something you can type and see for yourself.
