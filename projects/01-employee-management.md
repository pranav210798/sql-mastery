# Project 1 — Employee Management System

> **Part VII — Applied Mastery** · Chapter 32 — Real-World Projects · [Projects Overview](README.md) · Next: [Project 2 — Banking System](02-banking-system.md)

**Dialect: [PostgreSQL] only.** Every statement in this project is idiomatic PostgreSQL 15+ and runs directly against `company_db` as seeded in `databases/company_db.sql`, plus the handful of new objects this project layers on top of it (all given in full below). If you haven't loaded the base schema yet:

```bash
psql -f databases/company_db.sql
```

This project assumes you've completed Chapters 1–24 — CRUD, joins, subqueries, CTEs (including recursive CTEs), window functions, transactions, constraints, views, indexes, stored procedures, functions, triggers, and temporary tables. Nothing here introduces a new SQL *concept*; the point of a capstone project is to combine concepts you already know to solve one coherent, realistic problem end to end.

Every SQL statement below was executed against a live PostgreSQL 15 instance loaded from the exact `company_db.sql` in this repository, and every result table shown is the *real, unedited* output — not a mockup. If you run the statements in the order they appear in this document, you will get identical results, because later sections deliberately build on the mutations earlier sections make (a promotion in §3.6 changes what the recursive org chart in §3.8 looks like, exactly as it would in a real HR system).

> **⚠️ Warning — this document mutates data partway through.** Sections 3.1–3.5 read the database as originally seeded. Starting at §3.6 (`promote_employee`) and continuing through §3.7 (`give_raise`), the statements shown **actually change** `employees` and `salaries`. Every report from §3.8 onward — including all five reports in §4 — reflects the *post-change* state. If you want to reproduce the early, pristine-data output exactly, run the statements strictly in document order starting from a freshly loaded `company_db.sql`. If you want to re-run just the early sections in isolation, reload `company_db.sql` first.

---

## 1. Project Brief

**Client:** a 16-person, 5-department company (Engineering, Sales, HR, Finance, Marketing) that has outgrown spreadsheets for HR administration. Today, promotions are tracked in an email thread, raises are approved verbally and never logged, nobody can answer "who reports to whom" without asking around, and a departed employee got accidentally staffed on a new project last quarter because nobody checked their status first.

You've been asked to design and build the SQL layer of an internal **Employee Management System (EMS)**: a set of tables, views, functions, procedures, and triggers that sits directly on top of the existing `company_db` schema and gives HR, engineering managers, and finance a single source of truth for organizational structure, compensation history, attendance, and project staffing — with the business rules enforced *in the database*, not hoped for in application code.

You are explicitly **not** allowed to redesign `departments`, `employees`, `managers`, `salaries`, `attendance`, `projects`, or `employee_projects` — those are locked, in production, with real foreign keys pointing at them. Everything you build must sit *on top of* that schema.

### Functional Requirements

| # | Requirement |
|---|---|
| FR-1 | View the organizational hierarchy and per-department rosters |
| FR-2 | Track and report attendance (present / absent / late / remote / leave rates) |
| FR-3 | Compute an employee's tenure and current total compensation on demand |
| FR-4 | Track project staffing, department budgets, and budget utilization |
| FR-5 | Promote or transfer an employee (job title / department / manager) with full history retention |
| FR-6 | Give a raise with validation — raises above a threshold require explicit approval — and keep a full audit trail of every request and its outcome |
| FR-7 | Generate a "who reports to whom" org chart, computed recursively, not hand-maintained |
| FR-8 | Generate department headcount, attrition, and average-tenure reports |
| FR-9 | Flag employees with poor attendance for HR review |
| FR-10 | Enforce, at the database level, that only `ACTIVE` employees can be assigned to new projects |
| FR-11 | Rank and compare employee compensation within a department |
| FR-12 | Provide a single self-service "org directory" view for read-only lookups (name, title, department, manager, tenure, current pay) without exposing raw table joins to every consumer |

We'll implement all twelve, in roughly the order a real HR system would need them, and finish with five polished reports HR could actually run every Monday morning.

---

## 2. Schema Recap

### 2.1 The existing `company_db` schema (unchanged)

```
departments (department_id PK, department_name, location, created_at)
employees   (employee_id PK, first_name, last_name, email, hire_date, job_title,
             department_id FK -> departments, manager_id FK -> employees (self),
             status CHECK IN ('ACTIVE','ON_LEAVE','TERMINATED'), created_at)
managers    (manager_id PK/FK -> employees, department_id FK -> departments UNIQUE, appointed_date)
salaries    (salary_id PK, employee_id FK -> employees, base_salary, bonus, currency,
             effective_date, UNIQUE(employee_id, effective_date))
attendance  (attendance_id PK, employee_id FK -> employees, work_date, status
             CHECK IN ('PRESENT','ABSENT','LATE','REMOTE','LEAVE'), check_in, check_out,
             UNIQUE(employee_id, work_date))
projects    (project_id PK, project_name, department_id FK -> departments,
             start_date, end_date, budget)
employee_projects (employee_id FK, project_id FK, role, hours_allocated,
             PRIMARY KEY(employee_id, project_id))
```

Sixteen employees across five departments, 21 salary rows (five employees have received a raise since hire), ten attendance rows covering the first three days of January 2024 for four Engineering employees, five projects, and twelve `employee_projects` staffing rows. Every number quoted in this project traces back to those exact rows.

### 2.2 New objects this project adds

Nothing below touches or redefines an existing table. Two new tables, two functions, one view, one trigger (+ its function), and three procedures — that's the entire footprint.

| Object | Kind | Purpose |
|---|---|---|
| `employee_history` | table | Append-only log of every promotion/transfer, with before/after values |
| `salary_change_requests` | table | Append-only audit trail of every raise request — auto-approved, pending, approved, or rejected |
| `fn_tenure_years(employee_id)` | function | Years of service as of today, to 1 decimal place |
| `fn_current_compensation(employee_id)` | function | Base salary + bonus from the most recent salary row effective on or before today |
| `v_org_directory` | view | Flattened, self-service org directory (FR-1, FR-12) |
| `fn_check_active_before_project_assignment()` + `trg_check_active_before_project_assignment` | trigger | Blocks `INSERT`s into `employee_projects` for any employee whose `status <> 'ACTIVE'` (FR-10) |
| `promote_employee(...)` | procedure | Change job title / department / manager, with validation and history logging (FR-5) |
| `give_raise(...)` | procedure | Apply or queue a compensation change, with a percentage-based approval gate (FR-6) |
| `approve_salary_change_request(...)` | procedure | Approve a request `give_raise` queued as `PENDING` (FR-6) |

We'll introduce each one in context, in §3, with the full `CREATE` statement, an explanation, and real output. The two tables are shown together right now, since everything else depends on them existing first.

```sql
-- [PostgreSQL]
SET search_path TO company_db;

CREATE TABLE employee_history (
    history_id          SERIAL PRIMARY KEY,
    employee_id          INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    change_type          VARCHAR(20) NOT NULL CHECK (change_type IN ('PROMOTION','TRANSFER','STATUS_CHANGE')),
    old_job_title         VARCHAR(100),
    new_job_title         VARCHAR(100),
    old_department_id     INT REFERENCES departments(department_id),
    new_department_id     INT REFERENCES departments(department_id),
    old_manager_id         INT REFERENCES employees(employee_id),
    new_manager_id         INT REFERENCES employees(employee_id),
    old_status              VARCHAR(20),
    new_status               VARCHAR(20),
    changed_at                TIMESTAMP NOT NULL DEFAULT now(),
    note                        VARCHAR(255)
);

CREATE TABLE salary_change_requests (
    request_id             SERIAL PRIMARY KEY,
    employee_id             INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    old_base_salary          NUMERIC(10,2) NOT NULL,
    old_bonus                 NUMERIC(10,2) NOT NULL,
    requested_base_salary      NUMERIC(10,2) NOT NULL CHECK (requested_base_salary > 0),
    requested_bonus             NUMERIC(10,2) NOT NULL DEFAULT 0,
    pct_increase                 NUMERIC(6,2) NOT NULL,
    effective_date                DATE NOT NULL,
    status                         VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                                       CHECK (status IN ('PENDING','AUTO_APPROVED','APPROVED','REJECTED')),
    requested_at                    TIMESTAMP NOT NULL DEFAULT now(),
    decided_at                       TIMESTAMP,
    decided_by                        VARCHAR(100),
    reason                              VARCHAR(255)
);
```

**Design notes (cross-ref Chapter 13 — Constraints, Chapter 14 — Design & Normalization):**

- Both tables are **append-only audit logs**, not mutable state — you never `UPDATE` a row in `employee_history`, and the only `UPDATE` `salary_change_requests` ever gets is flipping `status` from `PENDING` to a terminal state. This is the same "event log" pattern the course uses for `banking_db`'s audit log: the current state (`employees`, `salaries`) is derived by replaying or simply reading the latest event, but the *history of how we got there* is preserved forever.
- `old_*`/`new_*` pairs are denormalized on purpose. A normalized "just diff the previous row" design would require a self-join against the row's own history to answer "what changed here," which is exactly the kind of query HR needs to run in under a second, not compute on the fly.
- `salary_change_requests.pct_increase` is a derived value we choose to *store*, not recompute — because the threshold that made a raise require approval is a business rule that can change in the future (see §5's "extend" ideas), and the audit trail should reflect the percentage that was true *at the time the request was made*, not whatever the current base salary happens to be today.
- Every foreign key reuses `ON DELETE CASCADE` / plain `REFERENCES` consistent with the base schema's own conventions (§13.1 of the course covers this).

---

## 3. Implementation

### 3.1 Organizational hierarchy & department rosters (FR-1)

Before building anything new, the most basic HR question is: *who works where, for whom, doing what?* This is a plain multi-table join (cross-ref **Chapter 7 — JOINs**) — no new objects needed yet.

```sql
-- [PostgreSQL]
SELECT
    d.department_name,
    e.employee_id,
    e.first_name || ' ' || e.last_name AS employee_name,
    e.job_title,
    m.first_name || ' ' || m.last_name AS manager_name,
    e.hire_date,
    e.status
FROM employees e
JOIN departments d ON d.department_id = e.department_id
LEFT JOIN employees m ON m.employee_id = e.manager_id
ORDER BY d.department_name, e.employee_id;
```

**Explanation.** `JOIN departments` is an inner join because every employee in this schema has a department (no orphans to worry about). `LEFT JOIN employees m` is deliberately a *left* join, aliasing `employees` a second time to resolve `manager_id` to a name — a left join because exactly one employee, the CTO, has `manager_id IS NULL` and must still appear in the roster with a blank manager rather than being silently dropped by an inner join.

**Expected output (16 rows, all departments):**

| department_name | employee_id | employee_name | job_title | manager_name | hire_date | status |
|---|---|---|---|---|---|---|
| Engineering | 1 | Aditi Rao | CTO | — | 2015-03-01 | ACTIVE |
| Engineering | 2 | Rahul Mehta | Engineering Manager | Aditi Rao | 2016-05-12 | ACTIVE |
| Engineering | 3 | Sneha Kulkarni | Senior Engineer | Rahul Mehta | 2017-01-20 | ACTIVE |
| Engineering | 4 | Vikram Joshi | Software Engineer | Rahul Mehta | 2018-07-15 | ACTIVE |
| Engineering | 5 | Ananya Singh | Software Engineer | Rahul Mehta | 2019-09-01 | ON_LEAVE |
| Engineering | 6 | Karan Verma | Junior Engineer | Sneha Kulkarni | 2020-02-10 | ACTIVE |
| Engineering | 16 | Aman Chawla | Software Engineer | Rahul Mehta | 2022-01-10 | ACTIVE |
| Finance | 12 | Nikhil Gupta | Finance Manager | Aditi Rao | 2016-12-01 | ACTIVE |
| Finance | 13 | Divya Shah | Accountant | Nikhil Gupta | 2018-06-25 | ACTIVE |
| HR | 10 | Rohan Kapoor | HR Manager | Aditi Rao | 2016-08-09 | ACTIVE |
| HR | 11 | Isha Bhatt | HR Executive | Rohan Kapoor | 2019-01-14 | ACTIVE |
| Marketing | 14 | Rajesh Iyer | Marketing Manager | Aditi Rao | 2017-09-30 | ACTIVE |
| Marketing | 15 | Pooja Reddy | Marketing Executive | Rajesh Iyer | 2020-10-05 | ACTIVE |
| Sales | 7 | Priya Nair | Sales Manager | Aditi Rao | 2015-11-05 | ACTIVE |
| Sales | 8 | Arjun Das | Sales Executive | Priya Nair | 2017-04-18 | ACTIVE |
| Sales | 9 | Meera Pillai | Sales Executive | Priya Nair | 2021-03-22 | TERMINATED |

> **Important Note:** Meera Pillai (`employee_id` 9) still appears here, `TERMINATED` status and all. A roster query should never silently exclude terminated employees — HR needs to see them precisely *because* they're terminated (final pay, offboarding checklist, etc.). Filtering by status is the caller's job (`WHERE e.status = 'ACTIVE'`), not something baked into a general-purpose roster query.

---

### 3.2 Functions: tenure and current compensation (FR-3)

Two small, reusable scalar functions save us from repeating the same "latest salary row" and "years since hire" logic in every query that follows (cross-ref **Chapter 20 — Advanced Functions**).

```sql
-- [PostgreSQL]
CREATE OR REPLACE FUNCTION fn_tenure_years(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT ROUND((CURRENT_DATE - hire_date) / 365.25, 1)
    FROM employees
    WHERE employee_id = p_employee_id;
$$;

CREATE OR REPLACE FUNCTION fn_current_compensation(p_employee_id INT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT base_salary + bonus
    FROM salaries
    WHERE employee_id = p_employee_id
      AND effective_date <= CURRENT_DATE
    ORDER BY effective_date DESC
    LIMIT 1;
$$;
```

**Explanation.**

- `fn_tenure_years` subtracts two dates (PostgreSQL `date - date` returns an integer day count) and divides by `365.25` to account for leap years, rounding to one decimal — good enough for HR reporting, not for legal contracts.
- `fn_current_compensation` is the piece of logic Chapter 6 warned you about: `salaries` is a **history** table, so "current salary" is never "the row," it's "the most recent row whose `effective_date` has actually arrived." The `effective_date <= CURRENT_DATE` filter is the whole point — a raise that's been entered with a *future* effective date (see §3.7) intentionally does **not** show up here until that date arrives. This mirrors real payroll systems, where a raise can be approved and scheduled weeks before it takes effect.
- Both are declared `LANGUAGE sql` (not `plpgsql`) because they're single-statement, and `STABLE` (not `IMMUTABLE`) because the result can change from one call to the next as time passes or new salary rows are inserted, but does **not** change twice within the same statement/transaction snapshot — exactly the volatility category the planner needs to know about to safely reuse the result across multiple rows in one query (cross-ref Chapter 20 §"Function Volatility").

**Demonstration, pristine data, three employees:**

```sql
SELECT
    e.employee_id,
    e.first_name || ' ' || e.last_name AS employee_name,
    fn_tenure_years(e.employee_id)        AS tenure_years,
    fn_current_compensation(e.employee_id) AS current_total_compensation
FROM employees e
WHERE e.employee_id IN (1, 3, 6)
ORDER BY e.employee_id;
```

| employee_id | employee_name | tenure_years | current_total_compensation |
|---|---|---|---|
| 1 | Aditi Rao | 11.6 | 620000.00 |
| 3 | Sneha Kulkarni | 9.7 | 235000.00 |
| 6 | Karan Verma | 6.6 | 85000.00 |

Aditi's compensation is her 2020-01-01 row (520000 + 100000 bonus); Sneha's is her 2022-01-01 row (210000 + 25000); Karan has only ever had one salary row (80000 + 5000) as of this pristine snapshot.

---

### 3.3 View: self-service org directory (FR-1, FR-12)

HR, managers, and (read-only) the rest of the company need to look someone up without writing a three-table join every time, and without being handed direct `SELECT` access to `salaries` (compensation is sensitive — Chapter 27's role/grant model would `GRANT SELECT` on this view to a broad `hr_readonly` role while keeping `salaries` itself locked to `hr_admin`).

```sql
-- [PostgreSQL]
CREATE OR REPLACE VIEW v_org_directory AS
SELECT
    e.employee_id,
    e.first_name || ' ' || e.last_name AS employee_name,
    e.job_title,
    d.department_name,
    d.location,
    m.first_name || ' ' || m.last_name AS manager_name,
    e.hire_date,
    fn_tenure_years(e.employee_id) AS tenure_years,
    e.status,
    fn_current_compensation(e.employee_id) AS current_total_compensation
FROM employees e
LEFT JOIN departments d ON d.department_id = e.department_id
LEFT JOIN employees m ON m.employee_id = e.manager_id;
```

**Explanation.** This is a plain (non-materialized) view — cross-ref **Chapter 15 — Views**. It's defined with `LEFT JOIN` on both `departments` and the self-join to `employees` so the view degrades gracefully (blank department/manager) rather than dropping a row if an employee is ever department-less or manager-less, even though today's data always has both. A view is the right tool here rather than a materialized view because the underlying data changes constantly (attendance doesn't factor in, but salaries and promotions do) and the query itself is cheap — no need to pay a refresh-staleness cost for something this fast.

```sql
SELECT employee_id, employee_name, job_title, department_name, manager_name,
       hire_date, tenure_years, status, current_total_compensation
FROM v_org_directory
ORDER BY employee_id;
```

**Expected output (pristine data, all 16 employees):**

| employee_id | employee_name | job_title | department_name | manager_name | hire_date | tenure_years | status | current_total_compensation |
|---|---|---|---|---|---|---|---|---|
| 1 | Aditi Rao | CTO | Engineering | — | 2015-03-01 | 11.6 | ACTIVE | 620000.00 |
| 2 | Rahul Mehta | Engineering Manager | Engineering | Aditi Rao | 2016-05-12 | 10.4 | ACTIVE | 370000.00 |
| 3 | Sneha Kulkarni | Senior Engineer | Engineering | Rahul Mehta | 2017-01-20 | 9.7 | ACTIVE | 235000.00 |
| 4 | Vikram Joshi | Software Engineer | Engineering | Rahul Mehta | 2018-07-15 | 8.2 | ACTIVE | 152000.00 |
| 5 | Ananya Singh | Software Engineer | Engineering | Rahul Mehta | 2019-09-01 | 7.1 | ON_LEAVE | 130000.00 |
| 6 | Karan Verma | Junior Engineer | Engineering | Sneha Kulkarni | 2020-02-10 | 6.6 | ACTIVE | 85000.00 |
| 7 | Priya Nair | Sales Manager | Sales | Aditi Rao | 2015-11-05 | 10.9 | ACTIVE | 370000.00 |
| 8 | Arjun Das | Sales Executive | Sales | Priya Nair | 2017-04-18 | 9.4 | ACTIVE | 140000.00 |
| 9 | Meera Pillai | Sales Executive | Sales | Priya Nair | 2021-03-22 | 5.5 | TERMINATED | 105000.00 |
| 10 | Rohan Kapoor | HR Manager | HR | Aditi Rao | 2016-08-09 | 10.1 | ACTIVE | 270000.00 |
| 11 | Isha Bhatt | HR Executive | HR | Rohan Kapoor | 2019-01-14 | 7.7 | ACTIVE | 108000.00 |
| 12 | Nikhil Gupta | Finance Manager | Finance | Aditi Rao | 2016-12-01 | 9.8 | ACTIVE | 285000.00 |
| 13 | Divya Shah | Accountant | Finance | Nikhil Gupta | 2018-06-25 | 8.2 | ACTIVE | 142000.00 |
| 14 | Rajesh Iyer | Marketing Manager | Marketing | Aditi Rao | 2017-09-30 | 9.0 | ACTIVE | 258000.00 |
| 15 | Pooja Reddy | Marketing Executive | Marketing | Rajesh Iyer | 2020-10-05 | 6.0 | ACTIVE | 114000.00 |
| 16 | Aman Chawla | Software Engineer | Engineering | Rahul Mehta | 2022-01-10 | 4.7 | ACTIVE | 101000.00 |

> **Important Note:** `tenure_years` and `current_total_compensation` are computed *at query time*, every time the view is read, because they call `fn_tenure_years`/`fn_current_compensation` rather than storing a snapshot. Run this query again next year and every `tenure_years` value increases automatically — there is nothing to "refresh."

---

### 3.4 Trigger: only `ACTIVE` employees can be staffed on projects (FR-10)

`employee_projects` has no column that, by itself, can enforce "the employee referenced by this row must currently be `ACTIVE`" — a `CHECK` constraint can only see columns *within the same row* (Chapter 13 covers this limitation explicitly), and `employee_projects` doesn't store `status` at all; it lives on `employees`. Enforcing a cross-table rule at write time requires a trigger (cross-ref **Chapter 22 — Triggers**).

```sql
-- [PostgreSQL]
CREATE OR REPLACE FUNCTION fn_check_active_before_project_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(20);
BEGIN
    SELECT status INTO v_status FROM employees WHERE employee_id = NEW.employee_id;
    IF v_status IS DISTINCT FROM 'ACTIVE' THEN
        RAISE EXCEPTION 'Employee % cannot be assigned to project %: status is %, must be ACTIVE',
            NEW.employee_id, NEW.project_id, v_status;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_active_before_project_assignment
BEFORE INSERT ON employee_projects
FOR EACH ROW
EXECUTE FUNCTION fn_check_active_before_project_assignment();
```

**Explanation.** `BEFORE INSERT ... FOR EACH ROW` fires once per inserted row, before it's written, with `NEW` bound to the row being inserted. We look up the referenced employee's current `status`; `IS DISTINCT FROM` (rather than `<>`) is used so the check still fires correctly even in the theoretical case of a `NULL` status (it can't happen here thanks to the base schema's `NOT NULL DEFAULT 'ACTIVE'`, but `IS DISTINCT FROM` is the defensively-correct comparison operator whenever `NULL` might be in play — plain `<>` against `NULL` would evaluate to `NULL`, which is *not* truthy, and the bad row would silently slip through). `RAISE EXCEPTION` aborts the entire statement (and, if it's running inside one, the whole transaction) rather than just skipping the row — the caller finds out immediately, with a message that names both the employee and the project.

**Demonstration — blocked case (Meera Pillai, `employee_id` 9, is `TERMINATED`):**

```sql
INSERT INTO employee_projects (employee_id, project_id, role, hours_allocated)
VALUES (9, 3, 'Sales Executive', 100);
```
```
ERROR:  Employee 9 cannot be assigned to project 3: status is TERMINATED, must be ACTIVE
CONTEXT:  PL/pgSQL function fn_check_active_before_project_assignment() line 7 at RAISE
```

**Demonstration — control case (Divya Shah, `employee_id` 13, is `ACTIVE`):**

```sql
INSERT INTO employee_projects (employee_id, project_id, role, hours_allocated)
VALUES (13, 3, 'Finance Analyst', 120);
```
```
INSERT 0 1
```

The row is inserted normally. We immediately remove it again so it doesn't skew the staffing reports in §4 — this is the *only* mutation in this document that we deliberately undo, precisely because it was a throwaway control-case check, not a real staffing decision:

```sql
DELETE FROM employee_projects WHERE employee_id = 13 AND project_id = 3;
```
```
DELETE 1
```

> **⚠️ Warning:** This trigger only fires on `INSERT`. It does **not** retroactively un-staff someone who was `ACTIVE` when assigned and is later terminated — that's a deliberate scope boundary (a terminated employee's historical project contributions are a fact of the past and shouldn't vanish from `employee_projects`), but it's worth stating explicitly rather than leaving it as an accidental gap. If you want termination to also trigger automatic removal from *future, unstarted* project work, that's exactly the kind of rule to add with an `AFTER UPDATE OF status ON employees` trigger — left as an extension in §5.

---

### 3.5 Procedure: `promote_employee` (FR-5)

Promotions and transfers are the same underlying operation — change `job_title`, `department_id`, and/or `manager_id` on `employees` — with the same audit requirement: keep a permanent record of what changed, when, and why. One procedure handles both, distinguishing them only for the audit log's `change_type` column (cross-ref **Chapter 19 — Stored Procedures**).

```sql
-- [PostgreSQL]
CREATE OR REPLACE PROCEDURE promote_employee(
    p_employee_id        INT,
    p_new_job_title       VARCHAR DEFAULT NULL,
    p_new_department_id   INT DEFAULT NULL,
    p_new_manager_id       INT DEFAULT NULL,
    p_note                  VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_old         employees%ROWTYPE;
    v_change_type VARCHAR(20);
BEGIN
    SELECT * INTO v_old FROM employees WHERE employee_id = p_employee_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee % does not exist', p_employee_id;
    END IF;

    IF v_old.status = 'TERMINATED' THEN
        RAISE EXCEPTION 'Cannot promote/transfer employee %: employee is TERMINATED', p_employee_id;
    END IF;

    IF p_new_manager_id = p_employee_id THEN
        RAISE EXCEPTION 'Employee % cannot report to themselves', p_employee_id;
    END IF;

    IF p_new_department_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM departments WHERE department_id = p_new_department_id) THEN
        RAISE EXCEPTION 'Department % does not exist', p_new_department_id;
    END IF;

    IF p_new_manager_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM employees WHERE employee_id = p_new_manager_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Manager % does not exist or is not ACTIVE', p_new_manager_id;
    END IF;

    IF p_new_job_title IS NOT NULL AND p_new_job_title <> v_old.job_title THEN
        v_change_type := 'PROMOTION';
    ELSE
        v_change_type := 'TRANSFER';
    END IF;

    UPDATE employees
    SET job_title     = COALESCE(p_new_job_title, job_title),
        department_id = COALESCE(p_new_department_id, department_id),
        manager_id    = COALESCE(p_new_manager_id, manager_id)
    WHERE employee_id = p_employee_id;

    INSERT INTO employee_history (
        employee_id, change_type,
        old_job_title, new_job_title,
        old_department_id, new_department_id,
        old_manager_id, new_manager_id,
        old_status, new_status, note
    ) VALUES (
        p_employee_id, v_change_type,
        v_old.job_title, COALESCE(p_new_job_title, v_old.job_title),
        v_old.department_id, COALESCE(p_new_department_id, v_old.department_id),
        v_old.manager_id, COALESCE(p_new_manager_id, v_old.manager_id),
        v_old.status, v_old.status, p_note
    );

    RAISE NOTICE 'Employee % updated: job_title % -> %',
        p_employee_id, v_old.job_title, COALESCE(p_new_job_title, v_old.job_title);
END;
$$;
```

**Explanation, top to bottom:**

1. `SELECT ... FOR UPDATE` both fetches the "before" row into the `v_old` record variable *and* row-locks it for the duration of the transaction (cross-ref Chapter 12 — Locks & Concurrency), so two concurrent promotions of the same employee can't race and silently lose one of the updates.
2. `IF NOT FOUND` — the standard PL/pgSQL idiom for "did that `SELECT INTO` actually match a row?" — guards against a bogus `employee_id`.
3. A `TERMINATED` employee can't be promoted or transferred — that's a business rule, not a database constraint, which is exactly the kind of validation a procedure exists to centralize (application code, a script, and a future developer all go through the same gate).
4. `p_new_manager_id = p_employee_id` catches the "reports to themselves" cycle at the shallowest level. (A `manager_id` chain that cycles two or three levels deep is a harder problem — see §5's extension ideas.) Note this comparison is naturally `NULL`-safe here: if `p_new_manager_id` is `NULL` (no manager change requested), `NULL = p_employee_id` evaluates to `NULL`, which `IF` treats as false, so the check is silently skipped exactly when it should be.
5. The new `department_id` and `manager_id`, if provided, are validated to actually exist (and the new manager must be `ACTIVE`) — you cannot transfer someone under a manager who doesn't exist or has since left the company.
6. `change_type` is inferred: a genuine title change is a `PROMOTION`; anything else (department and/or manager change with the same title) is a `TRANSFER`.
7. `COALESCE(p_new_X, X)` throughout means every parameter is optional — call this procedure with just a new department and nothing else changes but the department.
8. The `INSERT INTO employee_history` captures **both** old and new values in a single row, computed from `v_old` (captured before the `UPDATE`) and the same `COALESCE` expressions used in the `UPDATE` — guaranteeing the history row and the actual new state can never drift apart.

**Demonstration 1 — promote Karan Verma (title only):**

```sql
CALL promote_employee(6, 'Senior Engineer', NULL, NULL, 'Promoted after 2 strong review cycles');
```
```
NOTICE:  Employee 6 updated: job_title Junior Engineer -> Senior Engineer
CALL
```

```sql
SELECT employee_id, job_title, department_id, manager_id, status FROM employees WHERE employee_id = 6;
```

| employee_id | job_title | department_id | manager_id | status |
|---|---|---|---|---|
| 6 | Senior Engineer | 1 | 3 | ACTIVE |

```sql
SELECT * FROM employee_history WHERE employee_id = 6;
```

| history_id | employee_id | change_type | old_job_title | new_job_title | old_department_id | new_department_id | old_manager_id | new_manager_id | old_status | new_status | note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 6 | PROMOTION | Junior Engineer | Senior Engineer | 1 | 1 | 3 | 3 | ACTIVE | ACTIVE | Promoted after 2 strong review cycles |

**Demonstration 2 — transfer Aman Chawla to Marketing, under Rajesh Iyer:**

```sql
CALL promote_employee(16, NULL, 5, 14, 'Cross-functional transfer to Marketing to support Brand Relaunch tooling');
```
```
NOTICE:  Employee 16 updated: job_title Software Engineer -> Software Engineer
CALL
```

```sql
SELECT employee_id, job_title, department_id, manager_id FROM employees WHERE employee_id = 16;
```

| employee_id | job_title | department_id | manager_id |
|---|---|---|---|
| 16 | Software Engineer | 5 | 14 |

Note `job_title` is unchanged (`p_new_job_title` was `NULL`), so `change_type` correctly recorded as `TRANSFER`:

| history_id | employee_id | change_type | old_department_id | new_department_id | old_manager_id | new_manager_id | note |
|---|---|---|---|---|---|---|---|
| 2 | 16 | TRANSFER | 1 | 5 | 2 | 14 | Cross-functional transfer to Marketing to support Brand Relaunch tooling |

**Demonstration 3 — error case, attempting to promote a `TERMINATED` employee:**

```sql
CALL promote_employee(9, 'Senior Sales Executive');
```
```
ERROR:  Cannot promote/transfer employee 9: employee is TERMINATED
CONTEXT:  PL/pgSQL function promote_employee(integer,character varying,integer,integer,character varying) line 12 at RAISE
```

> **⚠️ Warning:** From this point forward, the database no longer matches the pristine seed data — Karan Verma is now a "Senior Engineer" and Aman Chawla now belongs to Marketing. Every query in §3.6 onward, and all of §4, reflects this new state.

---

### 3.6 Procedures: `give_raise` and `approve_salary_change_request` (FR-6)

A raise is not just "run an `UPDATE`." It needs validation (you can't "raise" someone into a *lower* salary), a business rule (large increases need sign-off before they take effect), and a permanent audit trail of who requested what and what happened to the request — three requirements that map to a second table (`salary_change_requests`, already created in §2.2) and two procedures.

```sql
-- [PostgreSQL]
CREATE OR REPLACE PROCEDURE give_raise(
    p_employee_id        INT,
    p_new_base_salary     NUMERIC,
    p_new_bonus            NUMERIC DEFAULT NULL,
    p_effective_date        DATE DEFAULT CURRENT_DATE,
    p_approved                BOOLEAN DEFAULT FALSE,
    p_reason                    VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status      VARCHAR(20);
    v_old_base    NUMERIC(10,2);
    v_old_bonus   NUMERIC(10,2);
    v_pct         NUMERIC(6,2);
    v_final_bonus NUMERIC(10,2);
    v_threshold   CONSTANT NUMERIC := 15.0;
BEGIN
    SELECT status INTO v_status FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee % does not exist', p_employee_id;
    END IF;
    IF v_status = 'TERMINATED' THEN
        RAISE EXCEPTION 'Cannot give a raise to employee %: employee is TERMINATED', p_employee_id;
    END IF;

    SELECT base_salary, bonus INTO v_old_base, v_old_bonus
    FROM salaries
    WHERE employee_id = p_employee_id
    ORDER BY effective_date DESC
    LIMIT 1;

    IF p_new_base_salary <= v_old_base THEN
        RAISE EXCEPTION 'New base salary (%) must be greater than current base salary (%)',
            p_new_base_salary, v_old_base;
    END IF;

    v_final_bonus := COALESCE(p_new_bonus, v_old_bonus);
    v_pct := ROUND((p_new_base_salary - v_old_base) / v_old_base * 100, 2);

    IF v_pct > v_threshold AND NOT p_approved THEN
        INSERT INTO salary_change_requests (
            employee_id, old_base_salary, old_bonus,
            requested_base_salary, requested_bonus,
            pct_increase, effective_date, status, reason
        ) VALUES (
            p_employee_id, v_old_base, v_old_bonus,
            p_new_base_salary, v_final_bonus,
            v_pct, p_effective_date, 'PENDING', p_reason
        );
        RAISE NOTICE 'Raise of % percent for employee % exceeds the % percent auto-approval threshold; logged as PENDING approval.',
            v_pct, p_employee_id, v_threshold;
        RETURN;
    END IF;

    INSERT INTO salaries (employee_id, base_salary, bonus, effective_date)
    VALUES (p_employee_id, p_new_base_salary, v_final_bonus, p_effective_date);

    INSERT INTO salary_change_requests (
        employee_id, old_base_salary, old_bonus,
        requested_base_salary, requested_bonus,
        pct_increase, effective_date, status, decided_at, decided_by, reason
    ) VALUES (
        p_employee_id, v_old_base, v_old_bonus,
        p_new_base_salary, v_final_bonus,
        v_pct, p_effective_date,
        CASE WHEN v_pct > v_threshold THEN 'APPROVED' ELSE 'AUTO_APPROVED' END,
        now(),
        CASE WHEN p_approved THEN 'HR_MANAGER' ELSE 'SYSTEM' END,
        p_reason
    );

    RAISE NOTICE 'Raise applied for employee %: % -> % (+% percent)',
        p_employee_id, v_old_base, p_new_base_salary, v_pct;
END;
$$;

CREATE OR REPLACE PROCEDURE approve_salary_change_request(
    p_request_id    INT,
    p_decided_by     VARCHAR DEFAULT 'HR_MANAGER'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_req salary_change_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_req FROM salary_change_requests WHERE request_id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Salary change request % does not exist', p_request_id;
    END IF;
    IF v_req.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Request % is not PENDING (current status: %)', p_request_id, v_req.status;
    END IF;

    INSERT INTO salaries (employee_id, base_salary, bonus, effective_date)
    VALUES (v_req.employee_id, v_req.requested_base_salary, v_req.requested_bonus, v_req.effective_date);

    UPDATE salary_change_requests
    SET status = 'APPROVED', decided_at = now(), decided_by = p_decided_by
    WHERE request_id = p_request_id;

    RAISE NOTICE 'Request % approved: employee % base salary now %',
        p_request_id, v_req.employee_id, v_req.requested_base_salary;
END;
$$;
```

**Explanation.**

- `give_raise` looks up the employee's *current* base salary/bonus the same way `fn_current_compensation` does (latest `salaries` row by `effective_date`), computes the percentage increase, and compares it against a hardcoded 15% threshold (`v_threshold CONSTANT NUMERIC := 15.0` — a `plpgsql` constant, meaning any accidental attempt to reassign it later in the procedure body would be a compile-time error, not a runtime bug).
- **Under the threshold**, or **at/over the threshold but called with `p_approved := TRUE`** (e.g., a VP pre-approved it verbally and HR is entering it directly), the raise is applied immediately: a new `salaries` row is inserted, and the audit trail records it as `AUTO_APPROVED` or `APPROVED` accordingly.
- **Over the threshold, not pre-approved**, the procedure does **not** touch `salaries` at all — it only inserts a `PENDING` row into `salary_change_requests` and returns. The raise does not exist yet as far as `fn_current_compensation` or anything else is concerned, until someone calls `approve_salary_change_request`.
- `p_new_base_salary <= v_old_base` is rejected outright — this procedure only ever gives raises, never pay cuts (a deliberate, named business rule, not an oversight; see §5 for extending it).
- `approve_salary_change_request` re-checks `status = 'PENDING'` (you cannot double-approve or approve a rejected request) and, on success, performs the *exact same* `INSERT INTO salaries` that `give_raise` would have done directly, using the values frozen in the request row at the time it was submitted — not whatever `salaries` happens to say now.

**Demonstration 1 — Karan Verma, +10%, under threshold, auto-approved and effective today:**

```sql
CALL give_raise(6, 88000, NULL, CURRENT_DATE, FALSE, 'Annual merit increase');
```
```
NOTICE:  Raise applied for employee 6: 80000.00 -> 88000 (+10.00 percent)
CALL
```

```sql
SELECT * FROM salaries WHERE employee_id = 6 ORDER BY effective_date;
```

| salary_id | employee_id | base_salary | bonus | currency | effective_date |
|---|---|---|---|---|---|
| 10 | 6 | 80000.00 | 5000.00 | USD | 2020-02-10 |
| 22 | 6 | 88000.00 | 5000.00 | USD | 2026-09-24 |

```sql
SELECT request_id, employee_id, old_base_salary, requested_base_salary, pct_increase, status, decided_by, reason
FROM salary_change_requests WHERE employee_id = 6;
```

| request_id | employee_id | old_base_salary | requested_base_salary | pct_increase | status | decided_by | reason |
|---|---|---|---|---|---|---|---|
| 1 | 6 | 80000.00 | 88000.00 | 10.00 | AUTO_APPROVED | SYSTEM | Annual merit increase |

Because `fn_current_compensation` filters on `effective_date <= CURRENT_DATE` and this raise is effective *today*, it is immediately visible: Karan's current total compensation is now `88000 + 5000 = 93000`.

**Demonstration 2 — Vikram Joshi, +25%, exceeds the 15% auto-approval threshold:**

```sql
CALL give_raise(4, 175000, NULL, CURRENT_DATE, FALSE, 'Promotion-linked raise pending VP approval');
```
```
NOTICE:  Raise of 25.00 percent for employee 4 exceeds the 15.0 percent auto-approval threshold; logged as PENDING approval.
CALL
```

```sql
SELECT * FROM salaries WHERE employee_id = 4 ORDER BY effective_date;
```

| salary_id | employee_id | base_salary | bonus | currency | effective_date |
|---|---|---|---|---|---|
| 7 | 4 | 120000.00 | 10000.00 | USD | 2018-07-15 |
| 8 | 4 | 140000.00 | 12000.00 | USD | 2022-01-01 |

**No new row.** `salaries` is untouched — Vikram's current compensation is still 152000 (140000 + 12000) until someone approves the request:

```sql
SELECT request_id, employee_id, old_base_salary, requested_base_salary, pct_increase, status
FROM salary_change_requests WHERE employee_id = 4;
```

| request_id | employee_id | old_base_salary | requested_base_salary | pct_increase | status |
|---|---|---|---|---|---|
| 2 | 4 | 140000.00 | 175000.00 | 25.00 | PENDING |

**Demonstration 3 — approve the pending request:**

```sql
CALL approve_salary_change_request(2, 'CTO');
```
```
NOTICE:  Request 2 approved: employee 4 base salary now 175000.00
CALL
```

```sql
SELECT * FROM salaries WHERE employee_id = 4 ORDER BY effective_date;
```

| salary_id | employee_id | base_salary | bonus | currency | effective_date |
|---|---|---|---|---|---|
| 7 | 4 | 120000.00 | 10000.00 | USD | 2018-07-15 |
| 8 | 4 | 140000.00 | 12000.00 | USD | 2022-01-01 |
| 23 | 4 | 175000.00 | 12000.00 | USD | 2026-09-24 |

```sql
SELECT request_id, employee_id, pct_increase, status, decided_by
FROM salary_change_requests WHERE employee_id = 4;
```

| request_id | employee_id | pct_increase | status | decided_by |
|---|---|---|---|---|
| 2 | 4 | 25.00 | APPROVED | CTO |

**Demonstration 4 — error case, a "raise" that isn't one:**

```sql
CALL give_raise(6, 80000);
```
```
ERROR:  New base salary (80000) must be greater than current base salary (88000.00)
CONTEXT:  PL/pgSQL function give_raise(integer,numeric,numeric,date,boolean,character varying) line 25 at RAISE
```

> **Important Note:** After this section, both Karan Verma (93000 total) and Vikram Joshi (187000 total) have visibly higher compensation than in §3.1–3.3, and Karan carries the "Senior Engineer" title from §3.5. Every query from here to the end of the document reflects this state.

---

### 3.7 Recursive CTE: the org chart, computed (FR-7)

HR should never hand-maintain an org chart in a slide deck — `employees.manager_id` already *is* the org chart; it just needs to be walked. This is a textbook recursive CTE (cross-ref **Chapter 9 — CTEs & Recursive CTEs**).

```sql
-- [PostgreSQL]
WITH RECURSIVE org_chart AS (
    -- anchor: the top of the tree (no manager)
    SELECT
        employee_id,
        (first_name || ' ' || last_name)::TEXT AS employee_name,
        job_title,
        manager_id,
        1 AS depth,
        ARRAY[employee_id] AS path
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    -- recursive step: each employee whose manager is already in org_chart
    SELECT
        e.employee_id,
        (e.first_name || ' ' || e.last_name)::TEXT,
        e.job_title,
        e.manager_id,
        oc.depth + 1,
        oc.path || e.employee_id
    FROM employees e
    JOIN org_chart oc ON e.manager_id = oc.employee_id
)
SELECT
    depth,
    REPEAT('    ', depth - 1) || employee_name AS org_chart,
    job_title
FROM org_chart
ORDER BY path;
```

**Explanation.**

- The **anchor member** selects the single row where `manager_id IS NULL` — Aditi Rao, the CTO — at `depth = 1`, and seeds `path` with her own `employee_id` as a one-element array.
- The **recursive member** joins `employees` back to `org_chart` **on `e.manager_id = oc.employee_id`**: "find every employee whose manager is someone we've already placed in the tree." PostgreSQL re-runs this join against only the *newly added* rows from the previous iteration until it produces zero new rows, then stops — this is `RECURSIVE`'s actual execution model, not a plain self-join (cross-ref Chapter 9 §"How Recursive CTEs Actually Execute").
- `path` accumulates the full chain of `employee_id`s from the root down to the current row as a PostgreSQL array. `ORDER BY path` exploits the fact that PostgreSQL compares arrays element-by-element, lexicographically — so ordering by `path` naturally produces a correct **depth-first** traversal (every manager immediately followed by all of their reports, recursively) without any extra sorting logic.
- `REPEAT('    ', depth - 1) || employee_name` is purely cosmetic — indenting by four spaces per level turns the flat result set into something that visually *looks* like an org chart when printed.

**Expected output (post-§3.5/§3.6 mutations — note Karan Verma's new title and Aman Chawla now under Rajesh Iyer):**

| depth | org_chart | job_title |
|---|---|---|
| 1 | Aditi Rao | CTO |
| 2 | &nbsp;&nbsp;&nbsp;&nbsp;Rahul Mehta | Engineering Manager |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Sneha Kulkarni | Senior Engineer |
| 4 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Karan Verma | Senior Engineer |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Vikram Joshi | Software Engineer |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Ananya Singh | Software Engineer |
| 2 | &nbsp;&nbsp;&nbsp;&nbsp;Priya Nair | Sales Manager |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Arjun Das | Sales Executive |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Meera Pillai | Sales Executive |
| 2 | &nbsp;&nbsp;&nbsp;&nbsp;Rohan Kapoor | HR Manager |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Isha Bhatt | HR Executive |
| 2 | &nbsp;&nbsp;&nbsp;&nbsp;Nikhil Gupta | Finance Manager |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Divya Shah | Accountant |
| 2 | &nbsp;&nbsp;&nbsp;&nbsp;Rajesh Iyer | Marketing Manager |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Pooja Reddy | Marketing Executive |
| 3 | &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Aman Chawla | Software Engineer |

Notice **Aman Chawla moved** — in the pristine data he was `depth 3` under Rahul Mehta in Engineering; after §3.5's `promote_employee(16, NULL, 5, 14, ...)` call, he's `depth 3` under Rajesh Iyer in Marketing. The recursive CTE required zero changes to reflect this — it always reads whatever `manager_id` currently says, which is the entire point of deriving the org chart instead of hand-maintaining it.

> **⚠️ Warning — infinite recursion risk.** If `employees.manager_id` ever contained a cycle (A reports to B, B reports to A), this query would loop forever, because there is no anchor-free "top." PostgreSQL doesn't detect this for you by default. A production version should carry `path` specifically so you can add `WHERE NOT e.employee_id = ANY(oc.path)` in the recursive member as a cycle guard — omitted here only because `promote_employee`'s self-report check (§3.5, step 4) already prevents the shallowest cycle, and the seed data has no others.

---

### 3.8 Window functions: ranking and tracking compensation (FR-11, FR-3)

Two related questions: *"how does this person's pay compare to peers in the same department?"* and *"how has any given employee's pay changed over time?"* Both are window-function questions (cross-ref **Chapter 10 — Window Functions**) — the first partitions by department, the second partitions by employee and looks backward with `LAG`.

**Query A — rank within department:**

```sql
-- [PostgreSQL]
SELECT
    d.department_name,
    e.first_name || ' ' || e.last_name AS employee_name,
    e.job_title,
    fn_current_compensation(e.employee_id) AS total_compensation,
    RANK() OVER (
        PARTITION BY e.department_id
        ORDER BY fn_current_compensation(e.employee_id) DESC
    ) AS dept_salary_rank,
    ROUND(AVG(fn_current_compensation(e.employee_id))
        OVER (PARTITION BY e.department_id), 2) AS dept_avg_compensation,
    ROUND(fn_current_compensation(e.employee_id)
        - AVG(fn_current_compensation(e.employee_id)) OVER (PARTITION BY e.department_id), 2)
        AS diff_from_dept_avg
FROM employees e
JOIN departments d ON d.department_id = e.department_id
WHERE e.status = 'ACTIVE'
ORDER BY d.department_name, dept_salary_rank;
```

**Explanation.** `RANK() OVER (PARTITION BY e.department_id ORDER BY ... DESC)` restarts the ranking at 1 for every department (that's what `PARTITION BY` does — it's the window-function equivalent of `GROUP BY`, except every input row survives instead of being collapsed). `RANK` (rather than `ROW_NUMBER` or `DENSE_RANK`) means genuine ties would share a rank and the next rank would skip — no ties happen to exist in this data, but `RANK` is still the semantically correct choice for "position by pay," since two people on identical pay should show the identical rank. The second window (`AVG(...) OVER (PARTITION BY e.department_id)`), with no `ORDER BY`, computes the department's average across the *entire partition* for every row in it — that's the mechanism (Chapter 10 §"Frame Clauses") that makes a per-row "difference from department average" column possible without a separate self-join or subquery.

**Expected output (post-mutation — 14 `ACTIVE` employees; `ON_LEAVE` Ananya and `TERMINATED` Meera excluded by the `WHERE`):**

| department_name | employee_name | job_title | total_compensation | dept_salary_rank | dept_avg_compensation | diff_from_dept_avg |
|---|---|---|---|---|---|---|
| Engineering | Aditi Rao | CTO | 620000.00 | 1 | 301000.00 | 319000.00 |
| Engineering | Rahul Mehta | Engineering Manager | 370000.00 | 2 | 301000.00 | 69000.00 |
| Engineering | Sneha Kulkarni | Senior Engineer | 235000.00 | 3 | 301000.00 | -66000.00 |
| Engineering | Vikram Joshi | Software Engineer | 187000.00 | 4 | 301000.00 | -114000.00 |
| Engineering | Karan Verma | Senior Engineer | 93000.00 | 5 | 301000.00 | -208000.00 |
| Finance | Nikhil Gupta | Finance Manager | 285000.00 | 1 | 213500.00 | 71500.00 |
| Finance | Divya Shah | Accountant | 142000.00 | 2 | 213500.00 | -71500.00 |
| HR | Rohan Kapoor | HR Manager | 270000.00 | 1 | 189000.00 | 81000.00 |
| HR | Isha Bhatt | HR Executive | 108000.00 | 2 | 189000.00 | -81000.00 |
| Marketing | Rajesh Iyer | Marketing Manager | 258000.00 | 1 | 157666.67 | 100333.33 |
| Marketing | Pooja Reddy | Marketing Executive | 114000.00 | 2 | 157666.67 | -43666.67 |
| Marketing | Aman Chawla | Software Engineer | 101000.00 | 3 | 157666.67 | -56666.67 |
| Sales | Priya Nair | Sales Manager | 370000.00 | 1 | 255000.00 | 115000.00 |
| Sales | Arjun Das | Sales Executive | 140000.00 | 2 | 255000.00 | -115000.00 |

Notice Engineering now shows only **5** active employees (Aman moved to Marketing in §3.5) and its average jumped to 301000 — both Vikram's and Karan's post-raise compensation feed into it, and Aman's 101000 no longer does.

**Query B — salary growth over time with `LAG`:**

```sql
-- [PostgreSQL]
SELECT
    e.first_name || ' ' || e.last_name AS employee_name,
    s.effective_date,
    s.base_salary,
    LAG(s.base_salary) OVER (PARTITION BY s.employee_id ORDER BY s.effective_date) AS previous_base_salary,
    s.base_salary - LAG(s.base_salary) OVER (PARTITION BY s.employee_id ORDER BY s.effective_date) AS change_amount,
    ROUND(
        (s.base_salary - LAG(s.base_salary) OVER (PARTITION BY s.employee_id ORDER BY s.effective_date))
        / LAG(s.base_salary) OVER (PARTITION BY s.employee_id ORDER BY s.effective_date) * 100
    , 2) AS pct_change
FROM salaries s
JOIN employees e ON e.employee_id = s.employee_id
ORDER BY employee_name, s.effective_date;
```

**Explanation.** `LAG(s.base_salary) OVER (PARTITION BY s.employee_id ORDER BY s.effective_date)` looks one row *back* within each employee's own salary history, ordered chronologically — for an employee's very first salary row, there is no prior row, so `LAG` correctly returns `NULL`, which then correctly propagates `NULL` through `change_amount` and `pct_change` for that row (there's nothing to compare the first salary against). This is the exact "before vs. after within the same result set, no self-join required" problem `LAG`/`LEAD` exist to solve (cross-ref Chapter 10 §"LAG and LEAD").

**Expected output (23 rows — 21 original seed rows + Karan's and Vikram's new raises from §3.6):**

| employee_name | effective_date | base_salary | previous_base_salary | change_amount | pct_change |
|---|---|---|---|---|---|
| Aditi Rao | 2015-03-01 | 450000.00 | — | — | — |
| Aditi Rao | 2020-01-01 | 520000.00 | 450000.00 | 70000.00 | 15.56 |
| Aman Chawla | 2022-01-10 | 95000.00 | — | — | — |
| Ananya Singh | 2019-09-01 | 120000.00 | — | — | — |
| Arjun Das | 2017-04-18 | 110000.00 | — | — | — |
| Divya Shah | 2018-06-25 | 130000.00 | — | — | — |
| Isha Bhatt | 2019-01-14 | 100000.00 | — | — | — |
| Karan Verma | 2020-02-10 | 80000.00 | — | — | — |
| Karan Verma | 2026-09-24 | 88000.00 | 80000.00 | 8000.00 | 10.00 |
| Meera Pillai | 2021-03-22 | 95000.00 | — | — | — |
| Nikhil Gupta | 2016-12-01 | 250000.00 | — | — | — |
| Pooja Reddy | 2020-10-05 | 105000.00 | — | — | — |
| Priya Nair | 2015-11-05 | 260000.00 | — | — | — |
| Priya Nair | 2021-01-01 | 300000.00 | 260000.00 | 40000.00 | 15.38 |
| Rahul Mehta | 2016-05-12 | 280000.00 | — | — | — |
| Rahul Mehta | 2021-01-01 | 320000.00 | 280000.00 | 40000.00 | 14.29 |
| Rajesh Iyer | 2017-09-30 | 230000.00 | — | — | — |
| Rohan Kapoor | 2016-08-09 | 240000.00 | — | — | — |
| Sneha Kulkarni | 2017-01-20 | 180000.00 | — | — | — |
| Sneha Kulkarni | 2022-01-01 | 210000.00 | 180000.00 | 30000.00 | 16.67 |
| Vikram Joshi | 2018-07-15 | 120000.00 | — | — | — |
| Vikram Joshi | 2022-01-01 | 140000.00 | 120000.00 | 20000.00 | 16.67 |
| Vikram Joshi | 2026-09-24 | 175000.00 | 140000.00 | 35000.00 | 25.00 |

Vikram Joshi's 25.00% jump is right there in the data — the same number `give_raise` computed and flagged as exceeding the threshold in §3.6.

---

### 3.9 Attendance tracking and the poor-attendance flag (FR-2, FR-9)

`attendance` is untouched by anything in §3.5–§3.6, so this section's numbers match the original seed exactly regardless of where it sits in the document. Attendance was only recorded for four Engineering employees over the first three days of January 2024 — a realistic constraint we work with honestly rather than inventing data.

**Per-employee attendance rate:**

```sql
-- [PostgreSQL]
SELECT
    e.first_name || ' ' || e.last_name AS employee_name,
    COUNT(*) AS days_recorded,
    COUNT(*) FILTER (WHERE a.status = 'PRESENT') AS present_days,
    COUNT(*) FILTER (WHERE a.status = 'LATE')    AS late_days,
    COUNT(*) FILTER (WHERE a.status = 'REMOTE')  AS remote_days,
    COUNT(*) FILTER (WHERE a.status = 'ABSENT')  AS absent_days,
    COUNT(*) FILTER (WHERE a.status = 'LEAVE')   AS leave_days,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.status IN ('PRESENT','LATE','REMOTE')) / COUNT(*), 1)
        AS attendance_rate_pct
FROM attendance a
JOIN employees e ON e.employee_id = a.employee_id
GROUP BY e.employee_id, employee_name
ORDER BY attendance_rate_pct ASC, employee_name;
```

| employee_name | days_recorded | present_days | late_days | remote_days | absent_days | leave_days | attendance_rate_pct |
|---|---|---|---|---|---|---|---|
| Ananya Singh | 2 | 0 | 0 | 0 | 0 | 2 | 0.0 |
| Vikram Joshi | 3 | 2 | 0 | 0 | 1 | 0 | 66.7 |
| Karan Verma | 2 | 1 | 0 | 1 | 0 | 0 | 100.0 |
| Sneha Kulkarni | 3 | 2 | 1 | 0 | 0 | 0 | 100.0 |

`attendance_rate_pct` counts `PRESENT`, `LATE`, and `REMOTE` as "showed up" (late is still attendance, just tardy) and treats `ABSENT` and `LEAVE` as "didn't." Ananya Singh's 0.0% looks alarming in isolation, but every one of her recorded days is `LEAVE` — pre-approved absence, not a disciplinary issue. That distinction matters for the next query.

**"Flag for HR review" — a deliberately narrower rule than raw attendance rate:**

```sql
-- [PostgreSQL]
WITH attendance_stats AS (
    SELECT
        employee_id,
        COUNT(*) AS days_recorded,
        COUNT(*) FILTER (WHERE status = 'ABSENT') AS absent_days,
        COUNT(*) FILTER (WHERE status = 'LATE')   AS late_days,
        COUNT(*) FILTER (WHERE status = 'LEAVE')  AS leave_days,
        COUNT(*) FILTER (WHERE status IN ('PRESENT','REMOTE')) AS present_days
    FROM attendance
    GROUP BY employee_id
)
SELECT
    e.employee_id,
    e.first_name || ' ' || e.last_name AS employee_name,
    d.department_name,
    ast.days_recorded, ast.present_days, ast.late_days, ast.absent_days, ast.leave_days,
    CASE
        WHEN ast.absent_days > 0 AND ast.late_days >= 2 THEN 'Unexcused absence + repeated lateness'
        WHEN ast.absent_days > 0 THEN 'Unexcused absence'
        WHEN ast.late_days >= 2 THEN 'Repeated lateness'
    END AS flag_reason
FROM attendance_stats ast
JOIN employees e ON e.employee_id = ast.employee_id
LEFT JOIN departments d ON d.department_id = e.department_id
WHERE ast.absent_days > 0 OR ast.late_days >= 2
ORDER BY ast.absent_days DESC, ast.late_days DESC;
```

**Expected output:**

| employee_id | employee_name | department_name | days_recorded | present_days | late_days | absent_days | leave_days | flag_reason |
|---|---|---|---|---|---|---|---|---|
| 4 | Vikram Joshi | Engineering | 3 | 2 | 0 | 1 | 0 | Unexcused absence |

> **Important Note:** This flag is deliberately built on `absent_days > 0 OR late_days >= 2` — **not** on the raw `attendance_rate_pct` from the query above it. If it were rate-based, Ananya Singh (0.0%) would incorrectly show up on an HR disciplinary review list for taking approved leave. Choosing the right *definition* of "poor attendance" — one that separates authorized absence from unauthorized absence — is a business-logic decision a query has to encode correctly, and it's exactly the kind of subtlety that separates a report someone trusts from one they learn to ignore.

---

### 3.10 Department headcount, attrition, and average tenure (FR-8)

```sql
-- [PostgreSQL]
SELECT
    d.department_name,
    COUNT(*) AS total_ever_hired,
    COUNT(*) FILTER (WHERE e.status = 'ACTIVE')     AS active_now,
    COUNT(*) FILTER (WHERE e.status = 'TERMINATED') AS terminated,
    ROUND(100.0 * COUNT(*) FILTER (WHERE e.status = 'TERMINATED') / COUNT(*), 1) AS attrition_rate_pct,
    ROUND(AVG(fn_tenure_years(e.employee_id)), 1) AS avg_tenure_years
FROM employees e
JOIN departments d ON d.department_id = e.department_id
GROUP BY d.department_name
ORDER BY attrition_rate_pct DESC, d.department_name;
```

**Explanation.** `total_ever_hired` is a plain `COUNT(*)` per department — *current* department assignment, so this counts Aman under Marketing now, not Engineering (§3.5 moved him). `attrition_rate_pct` divides terminated headcount by total-ever-hired-into-that-department; `avg_tenure_years` calls `fn_tenure_years` per row and averages it, folding in everyone regardless of current status (a terminated employee's tenure — the time they actually spent at the company — is still a real, countable number, and excluding them would understate how long people typically stay before leaving).

**Expected output:**

| department_name | total_ever_hired | active_now | terminated | attrition_rate_pct | avg_tenure_years |
|---|---|---|---|---|---|
| Sales | 3 | 2 | 1 | 33.3 | 8.6 |
| Engineering | 6 | 5 | 0 | 0.0 | 8.9 |
| Finance | 2 | 2 | 0 | 0.0 | 9.0 |
| HR | 2 | 2 | 0 | 0.0 | 8.9 |
| Marketing | 3 | 3 | 0 | 0.0 | 6.6 |

Sales carries the company's only attrition — Meera Pillai (`TERMINATED`) is one of only three people ever recorded against that department, for a startling-looking but entirely accurate 33.3%. Marketing's average tenure (6.6 years) is now visibly pulled down from what it would otherwise be, because Aman Chawla (4.7 years of tenure) transferred in from Engineering in §3.5 and is grouped by *current* department.

---

## 4. Reports

Five reports HR, Finance, and department leads would actually want on a recurring basis. All five reflect the database state as of the end of §3 (post-promotion, post-raises).

### Report 1 — Department Headcount & Budget Utilization

```sql
-- [PostgreSQL]
WITH dept_headcount AS (
    SELECT department_id,
        COUNT(*) FILTER (WHERE status = 'ACTIVE')     AS active_headcount,
        COUNT(*) FILTER (WHERE status = 'ON_LEAVE')   AS on_leave_headcount,
        COUNT(*) FILTER (WHERE status = 'TERMINATED') AS terminated_headcount
    FROM employees
    GROUP BY department_id
),
dept_projects AS (
    SELECT department_id,
        COUNT(*)     AS project_count,
        SUM(budget)  AS total_budget
    FROM projects
    GROUP BY department_id
),
dept_labor_cost AS (
    -- estimated labor cost = hours committed to the project x an hourly rate
    -- derived from each staffer's current annual compensation / 2080 (52 weeks x 40 hrs)
    SELECT p.department_id,
        SUM(ep.hours_allocated * fn_current_compensation(ep.employee_id) / 2080.0) AS estimated_labor_cost
    FROM employee_projects ep
    JOIN projects p ON p.project_id = ep.project_id
    GROUP BY p.department_id
)
SELECT
    d.department_name,
    COALESCE(dh.active_headcount, 0)     AS active_headcount,
    COALESCE(dh.on_leave_headcount, 0)   AS on_leave_headcount,
    COALESCE(dh.terminated_headcount, 0) AS terminated_headcount,
    COALESCE(dp.project_count, 0)        AS project_count,
    COALESCE(dp.total_budget, 0)         AS total_budget,
    ROUND(COALESCE(dl.estimated_labor_cost, 0), 2) AS estimated_labor_cost,
    ROUND(COALESCE(dl.estimated_labor_cost, 0) / NULLIF(dp.total_budget, 0) * 100, 2) AS budget_utilization_pct
FROM departments d
LEFT JOIN dept_headcount dh ON dh.department_id = d.department_id
LEFT JOIN dept_projects  dp ON dp.department_id = d.department_id
LEFT JOIN dept_labor_cost dl ON dl.department_id = d.department_id
ORDER BY d.department_name;
```

**Expected output:**

| department_name | active_headcount | on_leave_headcount | terminated_headcount | project_count | total_budget | estimated_labor_cost | budget_utilization_pct |
|---|---|---|---|---|---|---|---|
| Engineering | 5 | 1 | 0 | 2 | 8000000.00 | 279230.77 | 3.49 |
| Finance | 2 | 0 | 0 | 0 | 0 | 0.00 | — |
| HR | 2 | 0 | 0 | 1 | 250000.00 | 29855.77 | 11.94 |
| Marketing | 3 | 0 | 0 | 1 | 800000.00 | 47451.92 | 5.93 |
| Sales | 2 | 0 | 1 | 1 | 1200000.00 | 59134.62 | 4.93 |

**Reading it:** each department's budgets are large multi-year/multi-quarter project envelopes (Platform Migration alone is 5,000,000), so a 3–12% "labor cost as a fraction of total budget" is expected — most of a project's budget covers infrastructure, tooling, and non-labor spend, not just the hours logged in `employee_projects`. Finance shows `—` for utilization (not `0`) because `NULLIF(total_budget, 0)` turns a `0` budget into `NULL` before the division, correctly rendering "not applicable" rather than a misleading `0.00%` for a department with zero projects.

> **Important Note:** Engineering's `estimated_labor_cost` (279230.77) is higher than it would have been with the pristine seed data (269086.54) specifically because Vikram Joshi's and Karan Verma's raises from §3.6 are both effective *today* and both employees are staffed on Engineering projects — this report recalculates their hourly-rate contribution using their new, higher compensation.

### Report 2 — Salary Distribution by Department

```sql
-- [PostgreSQL]
SELECT
    d.department_name,
    COUNT(*) AS active_employees,
    MIN(fn_current_compensation(e.employee_id)) AS min_compensation,
    ROUND(AVG(fn_current_compensation(e.employee_id)), 2) AS avg_compensation,
    MAX(fn_current_compensation(e.employee_id)) AS max_compensation,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fn_current_compensation(e.employee_id)) AS median_compensation
FROM employees e
JOIN departments d ON d.department_id = e.department_id
WHERE e.status = 'ACTIVE'
GROUP BY d.department_name
ORDER BY avg_compensation DESC;
```

**Expected output:**

| department_name | active_employees | min_compensation | avg_compensation | max_compensation | median_compensation |
|---|---|---|---|---|---|
| Engineering | 5 | 93000.00 | 301000.00 | 620000.00 | 235000 |
| Sales | 2 | 140000.00 | 255000.00 | 370000.00 | 255000 |
| Finance | 2 | 142000.00 | 213500.00 | 285000.00 | 213500 |
| HR | 2 | 108000.00 | 189000.00 | 270000.00 | 189000 |
| Marketing | 3 | 101000.00 | 157666.67 | 258000.00 | 114000 |

`PERCENTILE_CONT(0.5)` is the standard "true median" ordered-set aggregate — unlike `AVG`, it isn't dragged around by outliers, which matters here: Engineering's *average* (301000) is skewed hard upward by the CTO's 620000, but the *median* (235000, Sneha Kulkarni's compensation, the true middle value of the five sorted salaries) is a far more representative "typical Engineering salary." Comparing `avg_compensation` to `median_compensation` in the same row is a quick, built-in check for how skewed a department's pay distribution is.

### Report 3 — Attendance Summary by Department

```sql
-- [PostgreSQL]
SELECT
    d.department_name,
    COUNT(*) AS days_recorded,
    COUNT(*) FILTER (WHERE a.status = 'PRESENT') AS present_days,
    COUNT(*) FILTER (WHERE a.status = 'LATE')    AS late_days,
    COUNT(*) FILTER (WHERE a.status = 'REMOTE')  AS remote_days,
    COUNT(*) FILTER (WHERE a.status = 'ABSENT')  AS absent_days,
    COUNT(*) FILTER (WHERE a.status = 'LEAVE')   AS leave_days,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.status IN ('PRESENT','LATE','REMOTE')) / COUNT(*), 1)
        AS attendance_rate_pct
FROM attendance a
JOIN employees e ON e.employee_id = a.employee_id
JOIN departments d ON d.department_id = e.department_id
GROUP BY d.department_name
ORDER BY attendance_rate_pct DESC;
```

**Expected output:**

| department_name | days_recorded | present_days | late_days | remote_days | absent_days | leave_days | attendance_rate_pct |
|---|---|---|---|---|---|---|---|
| Engineering | 10 | 5 | 1 | 1 | 1 | 2 | 70.0 |

> **Important Note:** Only one row. `company_db`'s seed data recorded attendance exclusively for four Engineering employees over January 1–3, 2024 — there is no attendance data at all for Sales, HR, Finance, or Marketing. Rather than paper over that with invented rows, this report shows exactly what the real data supports: a single department's snapshot. A production deployment of this EMS would need attendance capture rolled out company-wide before this report becomes company-wide too — worth calling out to stakeholders rather than letting an empty result silently look like "everyone else has perfect attendance."

### Report 4 — Project Staffing Utilization vs. `hours_allocated`

```sql
-- [PostgreSQL]
SELECT
    p.project_name,
    d.department_name,
    p.budget,
    COUNT(ep.employee_id) AS staff_count,
    SUM(ep.hours_allocated) AS total_hours_allocated,
    ROUND(SUM(ep.hours_allocated * fn_current_compensation(ep.employee_id) / 2080.0), 2) AS estimated_labor_cost,
    ROUND(SUM(ep.hours_allocated * fn_current_compensation(ep.employee_id) / 2080.0) / p.budget * 100, 2)
        AS budget_utilization_pct
FROM projects p
LEFT JOIN departments d ON d.department_id = p.department_id
LEFT JOIN employee_projects ep ON ep.project_id = p.project_id
GROUP BY p.project_id, p.project_name, d.department_name, p.budget
ORDER BY budget_utilization_pct DESC NULLS LAST;
```

**Expected output:**

| project_name | department_name | budget | staff_count | total_hours_allocated | estimated_labor_cost | budget_utilization_pct |
|---|---|---|---|---|---|---|
| Employee Wellness | HR | 250000.00 | 2 | 350 | 29855.77 | 11.94 |
| Brand Relaunch | Marketing | 800000.00 | 2 | 550 | 47451.92 | 5.93 |
| Q1 Sales Expansion | Sales | 1200000.00 | 2 | 550 | 59134.62 | 4.93 |
| Platform Migration | Engineering | 5000000.00 | 3 | 1500 | 183894.23 | 3.68 |
| Mobile App Revamp | Engineering | 3000000.00 | 3 | 1200 | 95336.54 | 3.18 |

Compare `Platform Migration`'s `estimated_labor_cost` (183894.23) here to what it would show against the pristine seed data (175480.77) — the ~8,400 difference is entirely attributable to Vikram Joshi's raise (he's staffed on this project for 500 of its 1,500 hours) landing effective today.

### Report 5 — Org Chart

This is the exact recursive CTE from §3.7, reproduced here as the finished report artifact rather than a walkthrough:

```sql
-- [PostgreSQL]
WITH RECURSIVE org_chart AS (
    SELECT
        employee_id,
        (first_name || ' ' || last_name)::TEXT AS employee_name,
        job_title, manager_id, 1 AS depth,
        ARRAY[employee_id] AS path
    FROM employees
    WHERE manager_id IS NULL
    UNION ALL
    SELECT
        e.employee_id,
        (e.first_name || ' ' || e.last_name)::TEXT,
        e.job_title, e.manager_id, oc.depth + 1,
        oc.path || e.employee_id
    FROM employees e
    JOIN org_chart oc ON e.manager_id = oc.employee_id
)
SELECT depth, REPEAT('    ', depth - 1) || employee_name AS org_chart, job_title
FROM org_chart
ORDER BY path;
```

**Expected output:** identical to §3.7's table — Aditi Rao at the top, five direct reports (Rahul Mehta, Priya Nair, Rohan Kapoor, Nikhil Gupta, Rajesh Iyer), and Aman Chawla now nested under Rajesh Iyer in Marketing rather than under Rahul Mehta in Engineering.

---

## 5. Things to Extend

The system above is complete enough to be genuinely useful, but a real HR platform keeps growing. Try these yourself — no solutions given:

1. **Leave-balance tracking.** Add a table that tracks an annual leave allowance per employee (e.g., 20 days/year), debits it whenever an `attendance` row of type `LEAVE` is inserted (via a trigger), and exposes a "leave balance remaining" query. What happens at year-end rollover — does unused leave expire, carry over, or partially carry over up to a cap?

2. **Prevent deleting a department that still has active employees.** Right now, `employees.department_id` is `ON DELETE SET NULL`, so deleting a department silently orphans its staff instead of failing loudly. Write a trigger (or reconsider whether a `CHECK`-adjacent approach is even possible) that blocks `DELETE FROM departments` while `EXISTS` an `ACTIVE` employee still assigned to it, with a clear error message telling the caller exactly how many employees are blocking the deletion.

3. **A monthly payroll run procedure.** Write a single procedure, `run_monthly_payroll(p_pay_month DATE)`, that computes each active employee's pay for a given month from `fn_current_compensation`, inserts one row per employee into a new `payroll_runs`/`payroll_line_items` pair of tables, and refuses to run twice for the same month (idempotency). What should happen to an employee who was `ACTIVE` for only part of the month (hired or terminated mid-month)?

4. **Manager-cycle detection for `promote_employee`.** §3.5's procedure only catches the shallowest cycle (an employee reporting to themselves). Extend the validation to walk the *entire* proposed manager chain (a recursive CTE, called from inside the procedure) and reject any transfer that would make someone their own manager three, four, or ten levels removed.

5. **A `reject_salary_change_request` procedure and a real approval role check.** `approve_salary_change_request` currently trusts whatever string is passed as `p_decided_by`. Design a `REJECTED` counterpart, and then (cross-ref Chapter 27 — Security) explore using PostgreSQL roles and `SESSION_USER`/`CURRENT_USER` instead of a free-text parameter, so the audit trail records *who actually ran the procedure*, not who they claim to be.

6. **A `v_headcount_trend` report driven by `employee_history` instead of a live snapshot.** Every report in §4 answers "what does the org look like *right now*." Using `employee_history` and `salary_change_requests` as your event sources, build a report that reconstructs "what did headcount / average compensation look like on any given past date" — a much harder, genuinely valuable slowly-changing-dimension-style problem (preview of Chapter 31's SCD patterns).

---

## What You Practiced

- **Chapter 7 — JOINs:** the department roster report (§3.1) and every report in §4 lean on inner and left joins, including a self-join of `employees` to itself to resolve manager names.
- **Chapter 9 — CTEs & Recursive CTEs:** a non-recursive CTE structuring Report 1's three-way aggregation (§4), and a full recursive CTE (§3.7, reused as Report 5) walking `manager_id` to build an org chart with no hardcoded depth limit.
- **Chapter 10 — Window Functions:** `RANK()` and `AVG() OVER (PARTITION BY ...)` for department-relative salary ranking, and `LAG()` for salary-history growth tracking (§3.8).
- **Chapter 12 — Locks & Concurrency:** `SELECT ... FOR UPDATE` inside `promote_employee` and `approve_salary_change_request` to row-lock the record being mutated for the duration of the procedure.
- **Chapter 13 — Constraints:** `CHECK` constraints on the two new tables' `status`/`change_type` enums, `NOT NULL`, `UNIQUE`-adjacent design decisions, and an explicit discussion of what a `CHECK` constraint *cannot* enforce (cross-table rules), motivating the trigger in §3.4.
- **Chapter 14 — Database Design & Normalization:** the deliberate append-only, denormalized-on-purpose design of `employee_history` and `salary_change_requests` as event logs sitting alongside normalized current-state tables.
- **Chapter 15 — Views:** `v_org_directory` (§3.3) as a self-service abstraction layer over a multi-table join and two function calls.
- **Chapter 19 — Stored Procedures:** three full `plpgsql` procedures (`promote_employee`, `give_raise`, `approve_salary_change_request`) with parameter defaults, `%ROWTYPE` variables, `FOUND`, validation, `RAISE EXCEPTION`/`RAISE NOTICE`, and a genuine two-step approval workflow spanning two procedure calls.
- **Chapter 20 — Advanced Functions:** two `STABLE`, `LANGUAGE sql` scalar functions (`fn_tenure_years`, `fn_current_compensation`) reused across nearly every other section of the project.
- **Chapter 22 — Triggers:** a `BEFORE INSERT ... FOR EACH ROW` trigger enforcing a cross-table business rule (`employee_projects` may only reference `ACTIVE` employees) that no `CHECK` constraint could express.
- **Chapter 6 — Aggregates:** `FILTER (WHERE ...)`, `PERCENTILE_CONT`, and the recurring "history table fan-out" trap, handled correctly throughout via `fn_current_compensation` rather than naive `AVG(base_salary)` over raw `salaries` rows.
- **Chapter 11 — Transactions:** the implicit all-or-nothing semantics of each `CALL` to a procedure — a failed validation (`RAISE EXCEPTION`) inside `promote_employee` or `give_raise` guarantees zero partial writes, since every statement in the procedure body runs inside the same transaction as the `CALL` itself.

---

> **Previous:** [Projects Overview](README.md) · **Next:** [Project 2 — Banking System](02-banking-system.md)
