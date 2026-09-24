# SQL Mastery — The Complete Course & Reference Book

A self-contained, hands-on SQL curriculum that goes from **absolute beginner**
to **expert / extreme-advanced**, built around four consistent sample
databases so that concepts compound instead of resetting with every example.

Primary dialect: **PostgreSQL**. Every chapter calls out `[PostgreSQL]`,
`[MySQL]`, `[Oracle]`, `[SQL Server]` wherever syntax or behavior diverges.

## How this book is organized

```
sql-mastery/
├── README.md                 ← you are here: roadmap + table of contents
├── databases/                ← run these first, in this order
│   ├── company_db.sql        (Employees/Departments/Salaries/Attendance/Projects)
│   ├── ecommerce_db.sql      (Users/Products/Orders/Payments/Reviews)
│   ├── banking_db.sql        (Customers/Accounts/Transactions/Loans/AuditLog)
│   └── analytics_db.sql      (star schema + 5M-row fact table, generated data)
├── chapters/                 ← Chapters 1-31 (the core curriculum)
├── projects/                 ← Chapter 33: 4 complete real-world builds
├── interview/                ← Chapter 34: 250+ interview Q&A
├── challenges/               ← Chapter 35-36: graded challenges + capstone
└── cheatsheets/              ← Chapter 37: quick-reference sheets
```

**Setup:** install PostgreSQL 15+, then:
```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
psql -f databases/banking_db.sql
psql -f databases/analytics_db.sql   # optional, large — see file header for how to shrink it
```
Every query example in every chapter runs against these exact schemas and
seed rows, so expected outputs shown in the text are the *real* outputs
you'll get by running the query yourself.

---

## Learning Roadmap

```
Beginner
  │  Ch 1-2   Database Foundations, SQL Environment & Syntax
  ▼
SQL Fundamentals
  │  Ch 3-7   CRUD, Sorting/Pagination, Functions, Aggregates
  ▼
Intermediate SQL
  │  Ch 8-10  Joins (deep), Subqueries, CTEs
  ▼
Advanced SQL
  │  Ch 11-18 Transactions, Locks, Constraints, Design/Normalization,
  │           Views, Indexes, Query Planner, Performance Optimization
  ▼
Stored Procedures
  │  Ch 19    PL/pgSQL procedures, T-SQL/PL-SQL/MySQL equivalents
  ▼
Functions
  │  Ch 20    Scalar/table-valued/set-returning UDFs, volatility
  ▼
Cursors
  │  Ch 21    Explicit/implicit cursors, set-based alternatives
  ▼
Transactions & Concurrency
  │  Ch 11-12 revisited with procedures: isolation, locks, deadlocks
  ▼
Indexes & Query Optimization
  │  Ch 16-18 revisited: EXPLAIN ANALYZE, plan operators, tuning
  ▼
Database Internals
  │  Ch 22-30 Triggers, Dynamic SQL, Temp Tables, Advanced Types,
  │           Partitioning, Security, Backup/Recovery, Internals (MVCC/WAL)
  ▼
Advanced Database Engineering
  │  Ch 31    Replication & HA, Advanced Patterns (gaps/islands, SCD,
  │           cohort analysis, upserts/MERGE)
  ▼
Expert / Extreme SQL
     Ch 33    4 full projects → Ch 34 interview bank → Ch 35 graded
              challenges L1-L6 → Ch 36 capstone (15+ tables) → Ch 37 cheatsheets
```

| Stage | What you learn | Why it matters | Prerequisites | You'll be able to... | Practice | Difficulty |
|---|---|---|---|---|---|---|
| Beginner | Data/DB/DBMS/RDBMS concepts, keys, relationships, NULL | Every later concept is built on this mental model | None | Explain what a database *is* before writing a line of SQL | Ch1-2 exercises | ★ |
| Fundamentals | SELECT/INSERT/UPDATE/DELETE, sorting, functions, aggregates | This is 80% of daily SQL usage | Beginner | Write real single-table queries and reports | Ch3-7 exercises | ★★ |
| Intermediate | Joins, subqueries, CTEs | Multi-table reasoning is where most SQL bugs live | Fundamentals | Combine data across a schema correctly, avoid duplicate-row bugs | Ch8-10 challenges | ★★★ |
| Advanced | Transactions, locks, design/normalization, views, indexes, planner, perf | This separates "writes queries" from "designs systems" | Intermediate | Design a normalized schema, diagnose a slow query, reason about concurrency | Ch11-18 challenges | ★★★★ |
| Procedural SQL | Procedures, functions, cursors | Needed for business logic that must live in the DB | Advanced | Write PL/pgSQL procedures with error handling and transactions | Ch19-21 progressive exercises | ★★★★ |
| Internals & Engineering | Triggers, dynamic SQL, partitioning, security, MVCC/WAL, replication | Production databases fail (or scale) based on these | Procedural SQL | Operate and reason about a production RDBMS, not just query it | Ch22-31 challenges | ★★★★★ |
| Expert/Extreme | Full projects, interview bank, L1-L6 challenges, capstone | Synthesis under realistic constraints | Everything above | Build, tune, and defend a complete production-grade schema | Ch33-37 | ★★★★★★ |

---

## Table of Contents

### Part I — Foundations
- [Chapter 1 — Database Foundations](chapters/01-database-foundations.md)
- [Chapter 2 — SQL Environment & Syntax](chapters/02-sql-environment-syntax.md)

### Part II — SQL Fundamentals
- [Chapter 3 — CRUD: SELECT, INSERT, UPDATE, DELETE](chapters/03-crud.md)
- [Chapter 4 — Sorting, Pagination & Result Processing](chapters/04-sorting-pagination.md)
- [Chapter 5 — Built-in Functions (String/Numeric/Date/NULL)](chapters/05-functions.md)
- [Chapter 6 — Aggregate Functions, GROUP BY, HAVING](chapters/06-aggregates.md)

### Part III — Intermediate SQL
- [Chapter 7 — JOINs (Extremely Detailed)](chapters/07-joins.md)
- [Chapter 8 — Subqueries](chapters/08-subqueries.md)
- [Chapter 9 — Common Table Expressions & Recursive CTEs](chapters/09-ctes.md)
- [Chapter 10 — Window Functions (Very Deep)](chapters/10-window-functions.md)

### Part IV — Advanced SQL & Database Engineering
- [Chapter 11 — Transactions & ACID](chapters/11-transactions.md)
- [Chapter 12 — Locks & Concurrency](chapters/12-locks-concurrency.md)
- [Chapter 13 — Constraints](chapters/13-constraints.md)
- [Chapter 14 — Database Design & Normalization](chapters/14-database-design-normalization.md)
- [Chapter 15 — Views & Materialized Views](chapters/15-views.md)
- [Chapter 16 — Indexes (Very Deep)](chapters/16-indexes.md)
- [Chapter 17 — Query Execution & the Query Planner](chapters/17-query-execution-planner.md)
- [Chapter 18 — SQL Performance Optimization](chapters/18-performance-optimization.md)

### Part V — Procedural SQL
- [Chapter 19 — Stored Procedures (Extremely Detailed)](chapters/19-stored-procedures.md)
- [Chapter 20 — Advanced Functions (UDFs, table-valued, volatility)](chapters/20-functions-advanced.md)
- [Chapter 21 — Cursors (Extremely Detailed)](chapters/21-cursors.md)

### Part VI — Database Internals & Production Engineering
- [Chapter 22 — Triggers](chapters/22-triggers.md)
- [Chapter 23 — Dynamic SQL & Injection Safety](chapters/23-dynamic-sql.md)
- [Chapter 24 — Temporary Tables](chapters/24-temporary-tables.md)
- [Chapter 25 — Advanced Data Types (JSON/Array/UUID/ENUM/Full-Text)](chapters/25-advanced-data-types.md)
- [Chapter 26 — Partitioning](chapters/26-partitioning.md)
- [Chapter 27 — Security (Roles, Grants, RLS, Injection)](chapters/27-security.md)
- [Chapter 28 — Backup & Recovery Concepts](chapters/28-backup-recovery.md)
- [Chapter 29 — Database Internals (Storage, MVCC, WAL, Vacuum)](chapters/29-database-internals.md)
- [Chapter 30 — Replication & High Availability](chapters/30-replication-ha.md)
- [Chapter 31 — Advanced SQL Patterns](chapters/31-advanced-patterns.md)

### Part VII — Applied Mastery
- [Chapter 32 — Real-World Projects](projects/README.md)
  - [Project 1 — Employee Management System](projects/01-employee-management.md)
  - [Project 2 — Banking System](projects/02-banking-system.md)
  - [Project 3 — E-Commerce Database](projects/03-ecommerce.md)
  - [Project 4 — Large-Scale Analytics Database](projects/04-analytics.md)
- [Chapter 33 — Interview Preparation (250+ Q&A)](interview/README.md)
  - [Beginner (50+)](interview/01-beginner.md)
  - [Intermediate (75+)](interview/02-intermediate.md)
  - [Advanced (75+)](interview/03-advanced.md)
  - [Expert (50+)](interview/04-expert.md)
- [Chapter 34 — SQL Challenges (Levels 1–6)](challenges/README.md)
- [Chapter 35 — Capstone Challenge](challenges/capstone.md)
- [Chapter 36 — Cheat Sheets](cheatsheets/README.md)

---

## Status

**Complete.** All 31 chapters, all 4 projects, the full 287-question interview
bank, the 6-level challenge set, the 20-table capstone, and the cheat sheets
are written and verified against the canonical databases (~540,000 words
total across the course).

- [x] Roadmap, TOC, and canonical databases (this file + `databases/`)
- [x] Part I — Foundations (Ch 1–2)
- [x] Part II — SQL Fundamentals (Ch 3–6)
- [x] Part III — Intermediate SQL (Ch 7–10)
- [x] Part IV — Advanced SQL & Database Engineering (Ch 11–18)
- [x] Part V — Procedural SQL (Ch 19–21)
- [x] Part VI — Database Internals & Production Engineering (Ch 22–31)
- [x] Part VII — Applied Mastery (4 projects, interview bank, challenges, capstone, cheat sheets)
