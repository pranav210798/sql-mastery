# Chapter 27 — Security (Roles, Grants, RLS, Injection)

> **Part VI — Database Internals & Production Engineering**
> Previous: [Chapter 26 — Partitioning](26-partitioning.md) · Next: [Chapter 28 — Backup & Recovery Concepts](28-backup-recovery.md)

This chapter runs against `company_db`, `banking_db`, and `ecommerce_db`. If you haven't loaded them yet:

```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
psql -f databases/banking_db.sql
```

You'll need a superuser or database-owner connection (e.g. the default `postgres` role) to run the `CREATE ROLE`/`GRANT`/`REVOKE` statements in this chapter — that's normal for administrative work, and it is itself part of the lesson: the person *granting* privileges needs elevated rights; the application that later *uses* those privileges should not.

---

## 27.0 What This Chapter Is Really About

Every chapter before this one assumed a single, all-powerful connection to the database — you, running `SELECT`, `INSERT`, `CREATE TABLE`, whatever you liked, with no one ever telling you no. Production databases are never used that way. A real system has many different callers touching the same data with wildly different levels of trust: a reporting dashboard that should only ever read a curated subset of columns, a customer-facing API that should only ever touch its own customer's rows, a background job that needs to write but never delete, and a human DBA who occasionally needs to run migrations and nothing else, ever, while the application is running.

This chapter is about the mechanisms PostgreSQL (and other engines) give you to make those distinctions *structural* — enforced by the database engine itself on every single query, the same way Chapter 13's constraints made data-integrity rules structural rather than optional. Three big ideas, in order:

1. **Who is allowed to do what** — roles, privileges, `GRANT`/`REVOKE`, and how privileges compose through role membership and schemas.
2. **Which rows they're allowed to see or touch** — row-level security (RLS), which pushes a `WHERE`-clause-shaped rule into the engine itself so it's applied transparently to every query, no matter who wrote it.
3. **How attackers subvert all of this from the outside** — SQL injection, and the one defense (parameterized queries) that eliminates the mechanism entirely rather than trying to filter around it.

The theme connecting all three: **the database should refuse the wrong thing on its own, structurally, rather than relying on every application, script, and developer to remember to check first.** That is exactly the same philosophy Chapter 13 built around constraints — this chapter applies it to *access*, not just *data validity*.

---

## 27.1 Users and Roles

### 1. Simple explanation
A role is an identity the database knows about — something that can be told "you're allowed to do X" or "you're not." Some roles can actually log in and run queries (these look like "users"); others exist purely as labeled bundles of privileges that get handed out to real users (these look like "groups").

### 2. Technical explanation

**[PostgreSQL]** unifies the concept: there is only one kind of object, `ROLE`. A role becomes a "user" simply by having the `LOGIN` attribute; a role becomes a "group" simply by *not* having it. `CREATE USER` is literally defined as an alias for `CREATE ROLE ... LOGIN` — they create the exact same catalog row in `pg_authid`. This is a deliberate simplification versus older SQL implementations: instead of two separate object types (users and groups) with separate grant machinery, PostgreSQL has one graph of roles that can be members of other roles, and login capability is just one attribute among several (`LOGIN`/`NOLOGIN`, `SUPERUSER`/`NOSUPERUSER`, `CREATEDB`, `CREATEROLE`, `INHERIT`/`NOINHERIT`, `CONNECTION LIMIT`, `VALID UNTIL`, password).

The other three major dialects keep the distinction PostgreSQL merged, each in its own way:

| Dialect | Model |
|---|---|
| **[PostgreSQL]** | One object type: `ROLE`. `LOGIN`/`NOLOGIN` attribute decides whether it behaves like a "user" or a "group." `CREATE USER` = `CREATE ROLE ... LOGIN`. |
| **[MySQL]** | `CREATE USER` (an account, always tied to a `'user'@'host'` pair) is separate from `CREATE ROLE` (a pure privilege bundle, added only in **MySQL 8.0**). Roles are granted to users with `GRANT role TO user`, and a user must `SET DEFAULT ROLE` or `SET ROLE` to activate granted roles in a session. |
| **[Oracle]** | Users and roles have always been distinct object types. A **user** is a schema-owning login account; a **role** is a named collection of privileges with no login capability and no owned objects, granted to users (or to other roles) purely to bundle privileges. |
| **[SQL Server]** | A genuinely **two-tier** model — this is the one that trips people up most, so read carefully below. |

> **Important Note — SQL Server's two-tier login/user model**
> **[SQL Server]** separates authentication from authorization into two distinct object types that live in two different places:
> - A **login** is created at the **server** level (`CREATE LOGIN app_login WITH PASSWORD = '...'`) and controls whether you can connect to the SQL Server *instance* at all. Logins are not scoped to any one database.
> - A **user** is created inside a **specific database** (`CREATE USER app_user FOR LOGIN app_login`) and is what actually gets granted permissions on tables, views, and procedures *within that database*.
>
> A login with no corresponding user in a given database can connect to the server but has no permissions inside that database at all. A login can map to differently-named (or differently-permissioned) users in different databases on the same server. This is precisely why a SQL Server DBA talks about "the login" and "the user" as two separate troubleshooting steps — "can this person connect to the server?" (login problem) versus "can this person do anything once connected to *this* database?" (user/permission problem) are genuinely different questions, unlike in PostgreSQL/MySQL/Oracle where one login identity carries its privileges wherever it goes.

### 3. Why it exists
Without named identities to attach privileges to, there is no way to distinguish callers at all — every connection to the database would be equally trusted, which is the same failure mode Chapter 13 solved for data (a schema with no constraints trusts every writer equally, which is exactly what goes wrong). Splitting "can this identity log in and run queries" from "what is this identity allowed to do" lets you build reusable privilege bundles (roles-as-groups) once, then hand them to many actual login identities without re-declaring the same set of grants over and over.

### 4. Full syntax **[PostgreSQL]**

```sql
-- A role that can log in ("a user")
CREATE ROLE hr_admin
    LOGIN
    PASSWORD 'ChangeMe123!'
    VALID UNTIL '2027-01-01'
    CONNECTION LIMIT 5;

-- Shorthand for the same thing
CREATE USER hr_admin_2 WITH PASSWORD 'ChangeMe123!';

-- A role that cannot log in ("a group" / pure privilege bundle)
CREATE ROLE reporting_role NOLOGIN;

-- Altering attributes later
ALTER ROLE hr_admin CONNECTION LIMIT 10;
ALTER ROLE hr_admin VALID UNTIL '2028-01-01';

-- Removing a role (it must first own nothing and have no remaining grants)
DROP ROLE IF EXISTS hr_admin_2;
```

### 5. Real examples we'll build in this chapter

| Role | LOGIN? | Purpose |
|---|---|---|
| `reporting_role` | `NOLOGIN` | Privilege bundle: read-only access to curated views (§27.10). |
| `hr_full_access_role` | `NOLOGIN` | Privilege bundle: full read access to `employees` + `salaries` (§27.10). |
| `app_service_role` | `NOLOGIN` | Privilege bundle for the running e-commerce application (§27.11). |
| `customer_role` | `NOLOGIN` | Privilege bundle enforcing row-level security on `banking_db.accounts` (§27.12). |
| `dba_migration_role` | `NOLOGIN` | Full DDL rights, used only for deployments (§27.9, §27.20). |
| `alice_hr` | `LOGIN` | An actual person, made a *member* of `hr_full_access_role` (§27.3). |

We deliberately make the privilege-bundle roles `NOLOGIN` and grant them *to* login roles, rather than attaching every privilege directly to a person's login — this is the standard pattern and is covered in §27.3.

### 6. Expected behavior

Trying to connect as a `NOLOGIN` role:
```
psql -U reporting_role -d mydb
```
```
FATAL:  role "reporting_role" is not permitted to log in
```

### 7. Line-by-line
- `PASSWORD 'ChangeMe123!'` is hashed (SCRAM-SHA-256 by default in modern PostgreSQL) before storage in `pg_authid.rolpassword` — it is never stored in plaintext.
- `VALID UNTIL` sets an absolute expiry after which the role can no longer authenticate, independent of the password itself remaining correct — useful for contractor accounts with a known end date.
- `CONNECTION LIMIT 5` caps concurrent sessions for that role, which is a coarse but useful defense against a compromised or buggy client opening unbounded connections.

### 8. Internal behavior
Every role — login or not — is one row in the shared, cluster-wide catalog `pg_authid` (roles are not per-database; a role created in one database is visible, and can be granted privileges, in every database in the same PostgreSQL cluster). Role membership itself (who is a member of whom) lives in `pg_auth_members`, a simple graph. When you authenticate, PostgreSQL resolves your login role's full set of `INHERIT`ed memberships once per session (walking that graph) to determine your effective privilege set; `SET ROLE` (§27.3) re-walks part of that graph on demand mid-session.

### 9. Common mistakes
- Creating a separate, hand-tuned set of `GRANT` statements for every individual employee instead of creating one `NOLOGIN` role per job function and granting *that* to people. This is the single most common privilege-management mistake in real organizations — it turns "what can Priya access" into an unanswerable question after two years of ad hoc grants, because there's no single place that defines "what an HR person can do."
- Assuming `CREATE USER` and `CREATE ROLE` are different kinds of objects in PostgreSQL. They are not — `\du` in `psql` lists both under the same "List of roles" heading, distinguished only by the `Login` column being `yes` or `no`.

### 10. Edge cases
- A role can simultaneously be `LOGIN` **and** a group other roles are also members of — there is nothing stopping a real person's login role from itself being granted to someone else. This is legal but confusing in practice, which is exactly why the convention in this chapter (and in real systems) is: privilege-bundle roles are `NOLOGIN`, and login roles are members of them, never the reverse.
- Dropping a role that still owns objects or still has grants fails outright (`ERROR: role "x" cannot be dropped because some objects depend on it`) — you must `REASSIGN OWNED BY x TO someone_else; DROP OWNED BY x;` first, then `DROP ROLE x`.

---

## 27.2 Privileges: GRANT and REVOKE

### 1. Simple explanation
`GRANT` gives a role permission to do a specific thing to a specific object — read a table, insert into it, run a function. `REVOKE` takes that permission back. Nothing is allowed by default except to the object's owner and to superusers.

### 2. Technical explanation
Every database object (table, view, sequence, function, schema, and more) carries an **access control list (ACL)** — internally, PostgreSQL stores this as an array of `role=privileges/grantor` entries directly on the object's catalog row (`pg_class.relacl` for tables/views, `pg_proc.proacl` for functions, `pg_namespace.nspacl` for schemas, and so on). `GRANT`/`REVOKE` are simply the SQL-level interface for editing those ACL arrays. A privilege check is a lookup against this ACL for the requesting role (and every role it transitively inherits from) at the time the object is accessed.

### 3. Why it exists
Without an explicit grant mechanism, either everyone would have equal access to everything (unworkable for anything beyond a single-developer toy database) or access would have to be enforced entirely outside the database — in application code, which, per Chapter 13's central lesson, is exactly the kind of enforcement that a bypassed code path, a direct `psql` session, or a bulk script can silently skip. `GRANT`/`REVOKE` make access control a property of the *object itself*, checked by the engine on every access, regardless of what's asking.

### 4. Full syntax

```sql
-- Table-level privileges (the common ones)
GRANT SELECT ON banking_db.accounts TO reporting_role;
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.orders TO app_service_role;
GRANT ALL PRIVILEGES ON company_db.employees TO hr_full_access_role;   -- ALL = SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER

-- Column-level privileges — restrict which columns are visible/writable
GRANT SELECT (employee_id, first_name, last_name, job_title, department_id)
    ON company_db.employees TO reporting_role;
-- reporting_role can SELECT those five columns only, never base_salary/email

-- Privileges on multiple tables/roles at once
GRANT SELECT ON ecommerce_db.products, ecommerce_db.categories TO app_service_role, reporting_role;

-- Privileges on functions/procedures
GRANT EXECUTE ON FUNCTION banking_db.get_account_balance(INT) TO app_service_role;

-- Privileges on schemas (covered in depth in §27.4)
GRANT USAGE ON SCHEMA banking_db TO customer_role;

-- Privileges on sequences (needed for INSERT into SERIAL-backed tables — see §27.2.9)
GRANT USAGE, SELECT ON SEQUENCE ecommerce_db.orders_order_id_seq TO app_service_role;

-- Revoking mirrors GRANT syntax exactly
REVOKE INSERT, UPDATE ON ecommerce_db.orders FROM app_service_role;
REVOKE ALL PRIVILEGES ON company_db.employees FROM hr_full_access_role;
REVOKE SELECT (base_salary) ON company_db.salaries FROM reporting_role;
```

`GRANT`/`REVOKE` also support `WITH GRANT OPTION` (lets the grantee re-grant the privilege to others) and `CASCADE`/`RESTRICT` on `REVOKE` (whether revoking from a grantor also revokes privileges that grantor, in turn, granted to others) — both are edge-case tools, covered further in §27.15.

### 5. Real examples against the course databases

```sql
-- Reporting can read the whole product catalog and public categories
GRANT SELECT ON ecommerce_db.products, ecommerce_db.categories TO reporting_role;

-- HR can see everything about employees and their pay history
GRANT SELECT, UPDATE ON company_db.employees TO hr_full_access_role;
GRANT SELECT, INSERT, UPDATE ON company_db.salaries TO hr_full_access_role;

-- The application service account for the bank's transaction service
GRANT SELECT, INSERT ON banking_db.transactions TO app_service_role;
GRANT SELECT, UPDATE ON banking_db.accounts TO app_service_role;
-- deliberately no GRANT ... DELETE anywhere near banking_db — you don't delete money movements
```

### 6. Expected behavior when a privilege is missing

```sql
SET ROLE reporting_role;
SELECT * FROM banking_db.accounts;
```
```
ERROR:  permission denied for table accounts
```

```sql
SET ROLE reporting_role;
DELETE FROM ecommerce_db.products WHERE product_id = 1;
```
```
ERROR:  permission denied for table products
```

Column-level denial looks similar but is column-scoped:
```sql
SET ROLE reporting_role;
SELECT employee_id, base_salary FROM company_db.employees;
```
```
ERROR:  permission denied for table employees
```
Note this fails for the **entire query**, not just the `base_salary` column — PostgreSQL does not silently return `NULL` for a column you lack privilege on; if *any* referenced column is unauthorized, the whole statement is rejected.

### 7. Line-by-line
- `GRANT SELECT (col1, col2) ON table TO role` — the parenthesized column list after the privilege name (not after the table name) is what makes this column-level rather than table-level; omitting it grants the privilege on all current and future columns.
- `GRANT ALL PRIVILEGES ON t TO r` — `ALL PRIVILEGES` is shorthand for every privilege type applicable to that object kind; for a table that's `SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER`. It is **not** the same as making `r` the owner — an owner additionally can `ALTER`/`DROP` the object and (by default) bypasses row-level security, neither of which `ALL PRIVILEGES` confers.
- `REVOKE SELECT (base_salary) ON ... FROM reporting_role` mirrors the grant syntax exactly — you revoke exactly the column-level grant you gave, leaving the table-level `SELECT` on other columns intact if it was granted separately.

### 8. Internal behavior
A privilege check happens at two points in a query's life: (1) at **parse/rewrite time**, PostgreSQL resolves which relations and columns a query actually touches; (2) at the start of **execution**, it checks the current effective role's ACL entry for each of those relations/columns (via functions like `has_table_privilege()`/`has_column_privilege()` internally) before any row is read or written. This check is not a filter applied after the fact — a denied query never runs at all; it errors out before touching the table's data or its indexes. Prepared statements and plan caching do not bypass this: if privileges change between preparing and executing a statement, PostgreSQL re-validates and will invalidate cached plans that depended on now-revoked access.

### 9. Common mistakes

> **⚠️ Warning — Granting SELECT on a table without USAGE on its schema**
> `GRANT SELECT ON banking_db.accounts TO customer_role;` alone is **not enough** for `customer_role` to query that table. PostgreSQL requires `USAGE` on the containing **schema** as a separate, prerequisite privilege — without it, the role cannot even "see into" the schema to resolve `banking_db.accounts` as a name at all. This is covered in full depth in §27.4; it is listed here because it is, by a wide margin, the single most common "why isn't my grant working" support ticket in real PostgreSQL deployments.

> **⚠️ Warning — Forgetting `ALTER DEFAULT PRIVILEGES`**
> Grants in PostgreSQL apply to objects that **already exist** at the moment you run `GRANT`. A table created *after* the grant gets none of it automatically — `reporting_role` will be unable to `SELECT` from a table created next week unless someone remembers to `GRANT` on it individually, or unless `ALTER DEFAULT PRIVILEGES` was set up in advance to auto-apply grants to future objects. This is covered in full in §27.13; it is one of the most common causes of "it worked yesterday, why can't the reporting role see the new table I just created."

### 10. Edge cases
- **Table owners always have full privileges implicitly**, without ever needing a `GRANT` — ownership itself is the privilege. This matters enormously for row-level security, covered in §27.15: an owner bypasses RLS policies by default too.
- **Superusers bypass every ACL check entirely**, on every object, including RLS policies — `GRANT`/`REVOKE` and `CREATE POLICY` are simply irrelevant to a superuser connection. This is precisely why §27.9 argues the running application should never connect as a superuser: every privilege boundary this chapter teaches you to build becomes meaningless the moment the connecting role is a superuser.

---

## 27.3 Role Inheritance and Membership

### 1. Simple explanation
Instead of granting every individual privilege to every individual person, you grant privileges to a role that represents a *job function* (`hr_full_access_role`), then make specific people *members* of that role. They automatically get everything the role has — and if the role's privileges change later, every member's effective access changes with it, with no per-person updates needed.

### 2. Technical explanation
`GRANT role_a TO role_b` makes `role_b` a **member** of `role_a`. This is a completely different statement from `GRANT SELECT ON table TO role`, even though the syntax looks similar — one grants an *object privilege*, the other grants *role membership*. Once `role_b` is a member of `role_a`, `role_b` automatically has every privilege `role_a` has been granted, **provided `role_b` has the `INHERIT` attribute** (the default in modern PostgreSQL). Membership composes transitively: if `role_b` is a member of `role_a`, and `role_c` is a member of `role_b`, then `role_c` inherits `role_a`'s privileges too, through the chain.

### 3. Why it exists
This is what makes role-based access control actually manageable at scale. Without it, granting "everything HR needs" to 15 different HR employees means writing (and, worse, *maintaining*) 15 sets of near-identical `GRANT` statements, and forgetting one when the 16th HR hire joins. With role membership, you define the privilege set exactly once, on `hr_full_access_role`, and onboarding a new HR employee is a single `GRANT hr_full_access_role TO new_hire;` statement.

### 4. Full syntax

```sql
-- Make login role alice_hr a member of hr_full_access_role
CREATE ROLE alice_hr LOGIN PASSWORD 'AlicePw123!';
GRANT hr_full_access_role TO alice_hr;

-- Role hierarchies compose: hr_full_access_role also gets basic reporting access
GRANT reporting_role TO hr_full_access_role;

-- WITH ADMIN OPTION lets the grantee themselves grant this role membership onward
GRANT hr_full_access_role TO hr_team_lead WITH ADMIN OPTION;

-- Revoking membership
REVOKE hr_full_access_role FROM alice_hr;
```

**[PostgreSQL] INHERIT / NOINHERIT — the role attribute that controls automatic vs. explicit activation:**

```sql
-- Default: alice_hr automatically has hr_full_access_role's privileges on every query
ALTER ROLE alice_hr INHERIT;

-- NOINHERIT: alice_hr is a member, but does NOT automatically get the privileges —
-- she must explicitly SET ROLE hr_full_access_role first, in that session, to use them
ALTER ROLE alice_hr NOINHERIT;
```

```sql
-- With NOINHERIT, this fails even though alice_hr IS a member of hr_full_access_role:
SET SESSION AUTHORIZATION alice_hr;
SELECT base_salary FROM company_db.salaries;   -- ERROR: permission denied for table salaries

-- She must explicitly switch into the role first:
SET ROLE hr_full_access_role;
SELECT base_salary FROM company_db.salaries;   -- now succeeds
RESET ROLE;   -- back to alice_hr's own (non-elevated) privileges
```

### 5. Real examples against the course databases

```sql
CREATE ROLE reporting_role NOLOGIN;
CREATE ROLE hr_full_access_role NOLOGIN;

GRANT SELECT (employee_id, first_name, last_name, job_title, department_id, hire_date, status)
    ON company_db.employees TO reporting_role;

GRANT SELECT, UPDATE ON company_db.employees TO hr_full_access_role;
GRANT SELECT, INSERT, UPDATE ON company_db.salaries TO hr_full_access_role;
GRANT reporting_role TO hr_full_access_role;   -- HR can see everything reporting can, plus more

CREATE ROLE alice_hr LOGIN PASSWORD 'AlicePw123!';
GRANT hr_full_access_role TO alice_hr;

CREATE ROLE bob_analyst LOGIN PASSWORD 'BobPw123!';
GRANT reporting_role TO bob_analyst;
```

`bob_analyst` (via `reporting_role`) can see the non-salary employee columns; `alice_hr` (via `hr_full_access_role`, which itself includes `reporting_role`) can see and modify both employee records and salary history. Neither role's privileges were declared twice.

### 6. Expected behavior

```sql
SET SESSION AUTHORIZATION bob_analyst;
SELECT base_salary FROM company_db.salaries;
```
```
ERROR:  permission denied for table salaries
```

```sql
SET SESSION AUTHORIZATION alice_hr;
SELECT employee_id, base_salary FROM company_db.salaries JOIN company_db.employees USING (employee_id) LIMIT 3;
```
```
 employee_id | base_salary
-------------+-------------
           1 |   520000.00
           2 |    320000.00
           3 |    210000.00
```

### 7. Line-by-line
- `GRANT hr_full_access_role TO alice_hr` — reads as "make `alice_hr` a member of `hr_full_access_role`," not "give `alice_hr`'s privileges to `hr_full_access_role`." The direction is: privileges flow *from* the role named right after `GRANT`, *to* the role/user named after `TO`.
- `GRANT reporting_role TO hr_full_access_role` — role membership can be granted to another role, not just to a login role; this is exactly how privilege hierarchies compose without duplicating grants.
- `SET SESSION AUTHORIZATION alice_hr` changes both the *session user* and *current user* to `alice_hr` for the rest of the session (used here to simulate "connecting as" her without a separate connection); `SET ROLE` (used in the `NOINHERIT` example) changes only the *current user*, which is the lighter-weight, more common tool for temporarily assuming a role's privileges mid-session.

### 8. Internal behavior
Role membership lives entirely in the `pg_auth_members` catalog as `(role, member, grantor, admin_option)` rows — a directed graph. On each query, if the connecting role has `INHERIT` set, PostgreSQL computes the transitive closure of that graph (every role reachable by following membership edges) once, and privilege checks succeed if *any* role in that closure has the needed grant. `NOINHERIT` roles stop that automatic traversal — membership still exists in the graph, but it is only "activated" for privilege purposes after an explicit `SET ROLE`, which re-walks the graph starting from the newly assumed role.

### 9. Common mistakes
- Forgetting that `NOINHERIT` (rare, but used intentionally for extra-sensitive roles requiring a deliberate "step-up" action) means simple membership isn't enough — many teams discover this only when a person who was "definitely granted access" still gets `permission denied` until they remember to `SET ROLE` first.
- Building deep, tangled role hierarchies (roles granted to roles granted to roles, five levels deep) that nobody can reason about anymore. Keep hierarchies shallow and named after job functions, not after individual grants.

### 10. Edge cases
- Circular role membership (`GRANT a TO b; GRANT b TO a;`) is rejected outright by PostgreSQL with `ERROR: circular role membership` — the membership graph must remain a DAG.
- `WITH ADMIN OPTION` on a role grant is analogous to `WITH GRANT OPTION` on an object privilege grant — it lets the grantee extend membership to others, which is powerful and should be reserved for team leads, not routine team members, since it lets someone widen the membership circle without going back to whoever manages roles centrally.

---

## 27.4 Schema-Level Permissions

### 1. Simple explanation
A schema is a namespace — a folder that groups tables together (`company_db`, `banking_db`, `ecommerce_db` are each a schema in this course's single database). Being allowed to read a *table* is not the same as being allowed to even "enter" the *schema* it lives in — you need both.

### 2. Technical explanation
`USAGE` on a schema is the privilege that allows a role to look up (resolve) object names within that schema at all — without it, `banking_db.accounts` is simply not resolvable for that role, regardless of what privileges exist on the `accounts` table itself. `USAGE` does not itself grant access to any object inside the schema; it only permits the *namespace lookup* step. Table-level (or column-level) privileges are then a completely separate, second layer, checked only after the schema-usage check has already passed.

### 3. Why it exists
Splitting "can you see into this namespace" from "what can you do to objects inside it" gives administrators a coarse, single on/off switch to hide an entire schema's worth of objects from a role in one statement, independent of managing dozens of individual table grants — useful when a schema is meant to be entirely invisible to a class of users (e.g., an internal `admin` schema that a reporting role should never even be aware exists).

### 4. Full syntax

```sql
GRANT USAGE ON SCHEMA banking_db TO customer_role;
GRANT USAGE ON SCHEMA ecommerce_db TO app_service_role, reporting_role;

-- CREATE privilege on a schema (separate from USAGE) allows creating new objects in it —
-- almost never granted to application/reporting roles, reserved for migration roles:
GRANT CREATE ON SCHEMA ecommerce_db TO dba_migration_role;

REVOKE USAGE ON SCHEMA banking_db FROM customer_role;
```

### 5. Worked example of the gotcha

```sql
CREATE ROLE customer_role NOLOGIN;
GRANT SELECT ON banking_db.accounts TO customer_role;   -- table privilege granted...
-- ...but USAGE on the schema was never granted:

SET ROLE customer_role;
SELECT * FROM banking_db.accounts;
```
```
ERROR:  permission denied for schema banking_db
LINE 1: SELECT * FROM banking_db.accounts;
                       ^
```

Notice the error explicitly names the **schema**, not the table — PostgreSQL never even got far enough to check the table-level ACL, because the schema-usage check runs first and failed. Fixing it:

```sql
GRANT USAGE ON SCHEMA banking_db TO customer_role;
SET ROLE customer_role;
SELECT * FROM banking_db.accounts;   -- now succeeds (table privilege was already correct)
```

### 6. Line-by-line
- The error message format `permission denied for schema X` (as opposed to `permission denied for table X`) is your direct diagnostic signal for exactly this mistake — if you ever see the word "schema" in a permission-denied error, the fix is a `GRANT USAGE ON SCHEMA`, not a table-level grant.
- `search_path` interacts with this too: even with `USAGE` granted, if a role's `search_path` doesn't include the schema, unqualified table names (`SELECT * FROM accounts` instead of `banking_db.accounts`) won't resolve — this is a name-resolution issue, distinct from (but easily confused with) the privilege issue.

### 7. Internal behavior
Schema `USAGE` is checked via the schema's ACL, stored in `pg_namespace.nspacl`, exactly parallel to how table ACLs live in `pg_class.relacl`. The check order for any qualified reference is: resolve/authorize the schema first (`USAGE`), then authorize the specific object and, if applicable, specific columns within it. This ordering is why the error names the schema — the engine never reaches the table-level check at all when the schema check fails first.

### 8. Common mistakes
- Granting table privileges generously and schema `USAGE` inconsistently — e.g., remembering `USAGE` for `ecommerce_db` but forgetting it for `banking_db` on the same role, producing a confusing "works for some tables, not others" bug report that actually has nothing to do with the tables themselves.
- Assuming `REVOKE`ing `USAGE` on a schema also revokes the underlying table grants. It does not — the table-level ACL entries remain; they're simply unreachable while `USAGE` is missing, and reappear in effect the moment `USAGE` is re-granted. If you intend to fully remove a role's access to a schema's contents, revoking `USAGE` alone is a reasonable coarse block, but for a clean audit trail you should also revoke the specific object grants.

### 9. Real examples in this course
Every practical example from §27.10 onward will pair a schema `USAGE` grant with its object-level grants — treat that pairing as mandatory boilerplate for any new role in this course's databases, since all three databases (`company_db`, `banking_db`, `ecommerce_db`) are PostgreSQL schemas, not separate databases.

---

## 27.5 Row-Level Security — PostgreSQL Deep Dive

### 1. Simple explanation
Normal `GRANT`s control access to whole tables or whole columns. **Row-level security (RLS)** controls access to individual *rows* within a table a role otherwise has permission to query — so two different roles running the exact same `SELECT * FROM accounts` can see two entirely different sets of rows, transparently, with no `WHERE` clause written by either of them.

### 2. Technical explanation
**[PostgreSQL]** RLS is enabled per-table with `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`, then one or more **policies** are attached with `CREATE POLICY`. Each policy defines a boolean expression (`USING`, for rows being *read*, and/or `WITH CHECK`, for rows being *written*) that must evaluate to `TRUE` for a given row to be visible/writable to a given role, for a given command type (`SELECT`/`INSERT`/`UPDATE`/`DELETE`/`ALL`). Once RLS is enabled on a table with at least one policy applying to a role, that role sees the **intersection** of "rows it would normally have `SELECT`/`UPDATE`/etc. privilege on" and "rows that satisfy at least one applicable policy" — if RLS is enabled but *no* policy applies to a given role for a given command, the default is **deny all rows**, not allow all.

### 3. Why it exists
Before RLS, "customers can only see their own accounts" had to be enforced entirely in application code — every single query in every code path had to remember to add `WHERE customer_id = :current_customer`. Miss it once (a new endpoint, a reporting script, a raw admin query run against production) and you have a serious data leak, exactly the same class of "one forgotten code path breaks everything" problem Chapter 13 solved for data integrity. RLS moves that `WHERE` condition into the database itself, where it is applied to *every* query against the table, automatically, regardless of what wrote the query.

### 4. Full syntax

```sql
ALTER TABLE banking_db.accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY policy_name
    ON table_name
    [ AS { PERMISSIVE | RESTRICTIVE } ]
    [ FOR { ALL | SELECT | INSERT | UPDATE | DELETE } ]
    [ TO role_name [, ...] ]
    [ USING ( boolean_expression ) ]
    [ WITH CHECK ( boolean_expression ) ];
```

- **`USING`** filters which *existing* rows the command is even allowed to see/touch — applies to `SELECT`, and to the "find the row" half of `UPDATE`/`DELETE`.
- **`WITH CHECK`** validates what the *new/resulting* row is allowed to look like — applies to `INSERT`'s new row, and to the "after the change" half of `UPDATE`. If omitted on a policy that has `USING`, PostgreSQL reuses the `USING` expression as the `WITH CHECK` expression too.
- **`PERMISSIVE`** (default) policies are OR'd together — a row passes if *any* permissive policy matches. **`RESTRICTIVE`** policies are AND'd on top of that — a row must also pass *every* restrictive policy, used for extra conditions layered on top of permissive access (e.g., "and only during business hours").

### 5. Worked example — `banking_db.accounts`, customers restricted to their own rows

```sql
-- 1. Create the role that will be subject to RLS
CREATE ROLE customer_role NOLOGIN;
GRANT USAGE ON SCHEMA banking_db TO customer_role;
GRANT SELECT, UPDATE ON banking_db.accounts TO customer_role;

-- 2. Turn on row-level security for the table
ALTER TABLE banking_db.accounts ENABLE ROW LEVEL SECURITY;

-- 3. A policy governing which rows customer_role can SELECT
CREATE POLICY customer_select_own_accounts
    ON banking_db.accounts
    FOR SELECT
    TO customer_role
    USING (customer_id = current_setting('app.current_customer_id')::int);

-- 4. A policy governing which rows customer_role can UPDATE, and what they can update them to
CREATE POLICY customer_update_own_accounts
    ON banking_db.accounts
    FOR UPDATE
    TO customer_role
    USING (customer_id = current_setting('app.current_customer_id')::int)
    WITH CHECK (customer_id = current_setting('app.current_customer_id')::int);
```

**Setting the session context and querying as the role** — this is the multi-tenant "current customer" pattern:

```sql
SET ROLE customer_role;
SET app.current_customer_id = '1';   -- normally set by the application right after authenticating Ravi Shankar (customer_id = 1)

SELECT account_id, customer_id, account_type, balance, status
FROM banking_db.accounts;
```
```
 account_id | customer_id | account_type | balance   | status
------------+-------------+--------------+-----------+--------
          1 |           1 | SAVINGS      | 150000.00 | ACTIVE
          2 |           1 | CURRENT      |  50000.00 | ACTIVE
```
Ravi Shankar (`customer_id = 1`) owns `account_id` 1 and 2 in the seed data (`banking_db.sql`) — every other row (Neha Agarwal's, Suresh Menon's, and so on) is silently absent. No error, no warning: the query genuinely behaves, from `customer_role`'s point of view, as if the other rows don't exist.

**Switching the session variable changes what's visible, with no change to the query itself:**
```sql
SET app.current_customer_id = '3';   -- now impersonating Suresh Menon (customer_id = 3)
SELECT account_id, customer_id, balance FROM banking_db.accounts;
```
```
 account_id | customer_id | balance
------------+-------------+-----------
          4 |           3 | 300000.00
          5 |           3 | 500000.00
```

**The `WITH CHECK` clause blocking an attempted cross-customer write:**
```sql
SET app.current_customer_id = '1';
UPDATE banking_db.accounts SET customer_id = 2 WHERE account_id = 1;
```
```
ERROR:  new row violates row-level security policy for table "accounts"
```
Ravi (`customer_id = 1`) is allowed to `UPDATE` `account_id = 1` because `USING` matches it — but the `WITH CHECK` expression re-evaluates against the *resulting* row, and `customer_id = 2` no longer equals `current_setting('app.current_customer_id')::int` (still `'1'`), so PostgreSQL rejects the write entirely, rolling back the statement.

> **Important Note — `SET` vs `SET LOCAL` with connection pooling**
> In a real application using a connection pooler (e.g., PgBouncer in transaction-pooling mode), a plain `SET app.current_customer_id = '1'` persists on the *physical* connection after your logical "session" ends, and the next unrelated request that happens to reuse that same pooled connection could inherit the wrong customer context — a serious cross-tenant data leak. The safer pattern is `SET LOCAL app.current_customer_id = '1';` issued **inside a transaction** (`BEGIN; SET LOCAL ...; ... queries ...; COMMIT;`), because `SET LOCAL` automatically resets at the end of the transaction no matter what, so it can never leak into a different logical request sharing the same pooled connection.

### 6. Line-by-line
- `current_setting('app.current_customer_id')` reads a **custom, application-defined session/transaction parameter** — PostgreSQL doesn't know or care what `app.current_customer_id` "means"; any GUC name with a `.` in it is treated as an extensible custom setting, which is exactly how applications pass tenant/user context into the session for RLS to consume.
- `::int` casts the setting (always returned as `text`) to `int` for comparison against `accounts.customer_id`, which is an `INT` column.
- `TO customer_role` scopes the policy to exactly that role — other roles querying the same table (e.g., a bank teller role, or the table owner) are entirely unaffected by this policy unless a policy naming *them* also exists (or RLS is force-enabled — see §27.15).

### 7. Internal behavior
Conceptually, PostgreSQL rewrites every applicable query against an RLS-enabled table by **transparently AND-ing the matching policy's `USING` expression onto the query's `WHERE` clause** (and analogously folding `WITH CHECK` into the write path), *before* the planner chooses an execution plan — not as a separate row-by-row filter applied after retrieval. Because the policy predicate becomes part of the query the planner actually optimizes, an index on the policy's filter column (here, `accounts.customer_id`) is used exactly as it would be for a hand-written `WHERE customer_id = $1`, so RLS by itself does not have to mean "slow" — a well-chosen policy column with a supporting index performs like ordinary filtered `SELECT`s.

### 8. Common mistakes
- Enabling RLS and expecting existing roles/queries to keep working unchanged. The moment `ENABLE ROW LEVEL SECURITY` runs, **any role with no matching policy sees zero rows** for that command type — this is a hard behavior change, not a soft one, and it silently "breaks" every query from a role nobody thought to write a policy for (including, easy to forget, the table owner's own ordinary queries once `FORCE ROW LEVEL SECURITY` is added — see §27.15).
- Writing a `USING` clause but forgetting `WITH CHECK` on an `UPDATE`/`INSERT`-applicable policy. Without an explicit `WITH CHECK`, PostgreSQL reuses `USING` — which is usually fine — but if you intended different read vs. write rules (e.g., "can read all of the branch's accounts, can only write to their own"), forgetting to state `WITH CHECK` explicitly means you silently get the `USING` rule applied to writes too, not the stricter rule you meant to write.
- Testing RLS policies while connected as the table owner or a superuser and concluding "the policy doesn't work," when in fact it never ran at all for that connection (see §27.15).

### 9. Edge cases — covered fully in §27.15
Table owners and superusers bypass RLS by default. This is significant enough, and surprising enough, that it gets its own dedicated section rather than being buried here.

---

## 27.6 Row-Level Security Across Dialects

RLS is far from universal. Each engine takes a different position on it:

**[SQL Server]** — native support via **Security Policies** built on inline table-valued functions used as predicates:

```sql
-- 1. A predicate function returning 1 row when access should be allowed
CREATE FUNCTION dbo.fn_accountAccessPredicate(@customer_id INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT 1 AS fn_result
       WHERE @customer_id = CAST(SESSION_CONTEXT(N'current_customer_id') AS INT);

-- 2. A security policy attaching that predicate to a table, for both reads and writes
CREATE SECURITY POLICY AccountFilter
    ADD FILTER PREDICATE dbo.fn_accountAccessPredicate(customer_id) ON dbo.Accounts,
    ADD BLOCK PREDICATE dbo.fn_accountAccessPredicate(customer_id) ON dbo.Accounts AFTER INSERT
    WITH (STATE = ON);
```
The application sets context per session with `EXEC sp_set_session_context 'current_customer_id', 1;` — conceptually the SQL Server equivalent of PostgreSQL's `current_setting('app.current_customer_id')`. `FILTER PREDICATE` behaves like PostgreSQL's `USING`; `BLOCK PREDICATE` behaves like `WITH CHECK`.

**[Oracle]** — **Virtual Private Database (VPD)** / Fine-Grained Access Control, implemented as a PL/SQL function returning a `WHERE`-clause fragment as a string, attached to a table via `DBMS_RLS.ADD_POLICY`:

```sql
CREATE OR REPLACE FUNCTION account_security_predicate(
    schema_name IN VARCHAR2, table_name IN VARCHAR2
) RETURN VARCHAR2 IS
BEGIN
    RETURN 'customer_id = SYS_CONTEXT(''APP_CTX'', ''current_customer_id'')';
END;
/

BEGIN
    DBMS_RLS.ADD_POLICY(
        object_schema   => 'BANKING',
        object_name     => 'ACCOUNTS',
        policy_name     => 'ACCOUNT_OWNER_POLICY',
        function_schema => 'BANKING',
        policy_function => 'ACCOUNT_SECURITY_PREDICATE',
        statement_types => 'SELECT,UPDATE,DELETE'
    );
END;
/
```
Oracle's VPD predates PostgreSQL's `CREATE POLICY` by many years and works on the same principle: Oracle transparently appends the returned predicate string to the `WHERE` clause of every qualifying query against the protected table.

**[MySQL]** — **no native row-level security mechanism exists**, in any edition, as of MySQL 8.x. This is a genuine, structural limitation, not a configuration gap you can enable. Teams on MySQL simulate row-level filtering with:

```sql
-- Simulated RLS via a view, filtering on a session variable
CREATE VIEW v_my_accounts AS
SELECT account_id, customer_id, account_type, balance, status
FROM accounts
WHERE customer_id = @current_customer_id;
```
This "works" only if application code (a) always sets `@current_customer_id` at the start of every session and (b) the customer-facing role is granted access to the view **but never granted direct access to the underlying `accounts` table** — because a user with direct table privileges can trivially bypass the view entirely by querying `accounts` straight. The other common MySQL workaround is enforcing the filter **entirely in application code** (every ORM/query layer call is required to inject `WHERE customer_id = ?`) — which reintroduces exactly the "every code path must remember to do this" fragility that RLS exists to eliminate in the first place.

> **Important Note — RLS support summary**
>
> | Dialect | Native RLS? | Mechanism |
> |---|---|---|
> | **PostgreSQL** | Yes | `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + `CREATE POLICY` |
> | **SQL Server** | Yes | `CREATE SECURITY POLICY` + inline table-valued function predicates |
> | **Oracle** | Yes | Virtual Private Database / `DBMS_RLS.ADD_POLICY` |
> | **MySQL** | **No** | Must simulate with views + `WHERE`, or enforce entirely in application code |

---

## 27.7 SQL Injection

### 1. Simple explanation
SQL injection happens when untrusted input (something a user typed) gets pasted directly into a SQL query's text instead of being treated as pure data — letting an attacker write characters that change what the query actually *means*, not just what it searches for.

### 2. Technical explanation
When application code builds a query by string concatenation, the database receives one single string and cannot tell which parts were the developer's intended SQL structure and which parts were user-supplied data — both are, by the time they reach the database, just characters in the same SQL text. If user input contains SQL metacharacters (`'`, `--`, `;`, `OR`, etc.), those characters are parsed as *SQL syntax*, not as literal data, because the database has no way to distinguish "this quote is part of the query" from "this quote came from a text box." This chapter gives the application-level view of the same underlying mechanism Chapter 23 covers in depth from the dynamic-SQL/`EXECUTE` side inside stored procedures — the vulnerability is identical in both settings; only *where* the concatenation happens differs.

### 3. Why it's dangerous — a self-contained example against `ecommerce_db`

Suppose a (hypothetical, insecure) login check for the `ecommerce_db` application, extended with a `password_hash` column for this example (the real seed schema doesn't store credentials — this mirrors how Chapter 13 extended the schema hypothetically for its own teaching examples):

**Naive, vulnerable application code (Python/Node-style pseudocode):**
```python
email = request.form["email"]           # attacker-controlled
password = request.form["password"]     # attacker-controlled

query = (
    "SELECT user_id, username, full_name FROM ecommerce_db.users "
    "WHERE email = '" + email + "' AND password_hash = '" + password + "'"
)
result = db.execute(query)
if result:
    log_in_as(result[0])
```

If a legitimate user submits `arjun.k@mail.com` / `correcthorsebattery`, the string sent to the database is:
```sql
SELECT user_id, username, full_name FROM ecommerce_db.users
WHERE email = 'arjun.k@mail.com' AND password_hash = 'correcthorsebattery'
```
— exactly the intended query. But an attacker can submit, as the **password** field, the string `' OR '1'='1`, with any (or no) real password. The concatenated string becomes:
```sql
SELECT user_id, username, full_name FROM ecommerce_db.users
WHERE email = 'arjun.k@mail.com' AND password_hash = '' OR '1'='1'
```
The attacker's input closed the `password_hash` string literal early with their own `'`, then appended `OR '1'='1'` — a condition that is unconditionally `TRUE`. Because of operator precedence, this is parsed as `(email = '...' AND password_hash = '') OR ('1'='1')`, and `'1'='1'` is always true, so the `WHERE` clause matches **every row in the table**, regardless of the actual password. The application receives a non-empty result and logs the attacker in as the first user returned — bypassing authentication entirely, with no valid credentials at all. A more targeted attacker can even skip guessing an email and instead break out of the whole query, e.g. submitting `nobody@x.com' OR '1'='1' --` as the email, which comments out the rest of the original query (including the password check) entirely.

The exact same mechanism, pushed further, is how injection escalates beyond authentication bypass into data exfiltration (`' UNION SELECT credit_card_number, NULL, NULL FROM payments --`) or destructive commands (`'; DROP TABLE ecommerce_db.orders; --`) — the attacker isn't limited to boolean tricks; once they can inject arbitrary text into the query, they can inject *any* valid SQL the database will parse and the application's database role has privileges to run. (This is also exactly why the least-privilege discussion in §27.9 matters as a *second* layer of defense: even if injection occurs, a properly-scoped application role without `DROP`/DDL rights limits how much damage that injected SQL can actually do.)

### 4. Cross-reference
Chapter 23 walks through this same mechanism from inside PL/pgSQL, where `EXECUTE 'SELECT ... ' || user_input` is the equivalent vulnerable pattern for dynamic SQL built inside a stored procedure or function, and covers `format(%L)`/`quote_literal()` as PostgreSQL-specific escaping tools for cases where parameterization genuinely isn't possible (e.g., dynamic identifiers). This chapter's job is the *application-code* angle and the *primary, structural* defense — parameterized queries — covered next.

---

## 27.8 Parameterized Queries — The Primary Defense

### 1. Simple explanation
Instead of building a query as one big string that includes the user's input, you send the query's *structure* and the user's *data* to the database **separately**, with placeholders marking where the data goes. The database fills in the placeholders itself, as literal values, never as SQL syntax.

### 2. Technical explanation — precisely why this eliminates injection
With a parameterized (also called "prepared") query, the SQL text sent to the database contains only placeholders (`$1, $2` in PostgreSQL's protocol, `?` in many client libraries, `:name` in others) — it contains **zero** characters derived from user input. The database parses and plans that fixed, placeholder-containing text exactly once. Only *afterward*, in a separate protocol message, are the actual parameter values sent — and at that point, the database already knows the query's complete grammatical structure; it is no longer parsing SQL syntax at all when it receives the values. It simply binds each value, verbatim, as the *content* of whatever data type the placeholder is being compared against. A value like `' OR '1'='1` sent as a bound parameter is treated as the literal, sixteen-character string `' OR '1'='1'` — compared for equality against a column value, exactly like comparing against `"correcthorsebattery"` would be — never re-interpreted as `'`, `OR`, `1`, `=`, `1` as separate SQL tokens, because parameter binding happens strictly *after* parsing is already complete. There is no stage in this process where user input and SQL grammar occupy the same string at the same time, which is the exact precondition injection depends on.

### 3. The same login check, done safely

**Parameterized query (pseudocode, applies near-identically to psycopg2/Python, node-postgres/JS, JDBC/Java, etc.):**
```python
email = request.form["email"]
password = request.form["password"]

query = (
    "SELECT user_id, username, full_name FROM ecommerce_db.users "
    "WHERE email = %s AND password_hash = %s"
)
result = db.execute(query, (email, password))   # values passed separately, never concatenated
if result:
    log_in_as(result[0])
```
Even if `password` is exactly the string `' OR '1'='1`, the query sent to PostgreSQL never changes — it is always `WHERE email = $1 AND password_hash = $2` — and the malicious string is simply compared, as literal text, against `password_hash`, matching nothing. The login correctly fails.

> **Important Note** — in a real application, the password itself should also never be compared as plaintext at all (it should be hashed with a slow, salted hash like bcrypt/argon2 and compared via a verification function, not a `WHERE password_hash = $2` equality check against a raw input). That's a separate authentication-design concern from injection safety; parameterization protects the *query structure*, not the *cryptographic soundness* of how credentials are stored — both matter, independently.

### 4. The equivalent safe PL/pgSQL form **[PostgreSQL]**

If this same lookup were built as dynamic SQL inside a PL/pgSQL function (the scenario Chapter 23 covers in full depth), the safe equivalent uses `EXECUTE ... USING`, which binds parameters the same protocol-level way:

```sql
CREATE OR REPLACE FUNCTION ecommerce_db.check_login(p_email TEXT, p_password_hash TEXT)
RETURNS TABLE(user_id INT, username VARCHAR, full_name VARCHAR)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT user_id, username, full_name FROM ecommerce_db.users
         WHERE email = $1 AND password_hash = $2'
        USING p_email, p_password_hash;
END;
$$;
```
`USING p_email, p_password_hash` binds those values into `$1`/`$2` of the dynamically-executed string exactly as a client-side parameterized query does — the string handed to `EXECUTE` never contains the caller's actual email/password text, only placeholders, so this remains just as safe as a non-dynamic, ordinary parameterized `SELECT` would be. Contrast this with the **unsafe** version Chapter 23 dissects in depth:
```sql
-- UNSAFE — do not do this — shown only for contrast
EXECUTE 'SELECT user_id FROM ecommerce_db.users WHERE email = ''' || p_email || '''';
```
which reintroduces string concatenation, and with it, the entire vulnerability.

### 5. Why parameterization is the *primary* defense, not just *a* defense
Input validation, allow-listing characters, and escaping quotes are all secondary, imperfect mitigations — they require correctly anticipating every dangerous character/encoding an attacker might use (multi-byte encoding tricks, alternate quote characters, second-order injection through data written by one query and later concatenated unsafely by another) and re-implementing that correctly at every single call site. Parameterized queries instead remove the *mechanism* injection relies on — string concatenation into SQL text — entirely, so there's no character-escaping arms race to win or lose in the first place.

---

## 27.9 The Principle of Least Privilege

### 1. Simple explanation
Give every role exactly the access it needs to do its job, and nothing more — not "might need someday," not "it's easier to just grant everything."

### 2. Technical explanation
Least privilege is the design discipline of minimizing each identity's *blast radius*: the set of things that can go wrong (accidentally or maliciously, from that identity) is bounded by the set of things that identity is *able* to do at all, regardless of intent. A role with `SELECT`-only access cannot corrupt data even if fully compromised; a role with no `DROP` privilege cannot destroy a table even via a successful SQL injection attack (§27.7) against code running under that role. Least privilege doesn't prevent every attack, but it caps the *damage* any single compromised credential, buggy script, or successful injection can cause.

### 3. Why it exists
Every additional privilege a role holds is additional risk that provides zero benefit unless that role actually exercises it. A reporting dashboard that only ever runs `SELECT` statements gains nothing from also holding `DELETE`/`DROP` rights — but if that dashboard's database credentials ever leak (a checked-in config file, a compromised dependency, an SSRF vulnerability), the *unused* privileges are exactly what determines how bad the resulting incident is. Least privilege trades a small amount of upfront design effort (deciding precisely what each role needs) for a large reduction in worst-case damage.

### 4. A concrete layered example — 3-tier `ecommerce_db` application

| Tier | Role | Rights | Never has |
|---|---|---|---|
| **Reporting** | `reporting_role` | `SELECT` only, and only on a small set of curated views (not raw tables) | Any write privilege; access to raw `users`/`payments` tables |
| **Application** | `app_service_role` | `SELECT`/`INSERT`/`UPDATE` on exactly the tables the running service needs (`orders`, `order_items`, `users`); `SELECT`-only on `products` | Any DDL (`CREATE`/`ALTER`/`DROP`); `DELETE` on audit-relevant tables (`orders`, `payments`) |
| **Admin / Migrations** | `dba_migration_role` | Full DDL — `CREATE`/`ALTER`/`DROP` on all objects in the schema, used **only** by the deployment pipeline | Any use by the *running* application at any time |

```sql
CREATE ROLE reporting_role     NOLOGIN;
CREATE ROLE app_service_role   NOLOGIN;
CREATE ROLE dba_migration_role NOLOGIN;

GRANT USAGE ON SCHEMA ecommerce_db TO reporting_role, app_service_role, dba_migration_role;

-- Reporting: views only (built in §27.10), never raw tables
GRANT SELECT ON ecommerce_db.v_product_catalog TO reporting_role;

-- Application: exactly what the CRUD service needs, nothing else
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.orders, ecommerce_db.order_items TO app_service_role;
GRANT SELECT ON ecommerce_db.products TO app_service_role;
GRANT USAGE, SELECT ON SEQUENCE ecommerce_db.orders_order_id_seq, ecommerce_db.order_items_order_item_id_seq
    TO app_service_role;

-- Admin/migrations: full DDL, deployment pipeline only
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ecommerce_db TO dba_migration_role;
GRANT CREATE ON SCHEMA ecommerce_db TO dba_migration_role;
```

### 5. Why the running application should almost never connect as a superuser/owner role

> **⚠️ Warning — Never run the application as a superuser or table owner**
> It is tempting, especially early in a project, to have the application connect using the same role that created the schema (the owner) — everything "just works" with no permission errors to debug. This is precisely backwards, for several concrete, compounding reasons:
> 1. **No blast-radius limit.** If the application has a SQL injection bug (§27.7), an attacker inherits *every* privilege the connecting role has. As the table owner or a superuser, that's unrestricted `DROP TABLE`, `DELETE FROM` on every table, even reading/writing other schemas entirely unrelated to the app.
> 2. **RLS becomes meaningless.** As covered in §27.5 and detailed next in §27.15, table owners (and superusers) **bypass row-level security policies by default**. If your application connects as the owner, every `CREATE POLICY` you write is silently irrelevant to that connection — you could have "customers can only see their own accounts" fully configured and it would do nothing, because the app itself never goes through the policy check at all.
> 3. **No defense in depth.** Least privilege is the layer that still protects you *after* another layer has already failed — after a code review missed a bug, after a WAF was bypassed, after a dependency was compromised. A superuser application connection has no such layer left; a successful attack is immediately a total compromise.
> 4. **Auditing and blame become impossible.** Every action taken by the application is indistinguishable, in logs, from every action a human DBA could have taken with that same super-privileged role — you lose the ability to reason about "what could this component possibly have done" after an incident.
>
> The application should connect as a narrowly-scoped service role like `app_service_role` above — never as the schema owner, never as a superuser — full stop.

---

## 27.10 Practical Example 1 — Read-Only Reporting Role via Curated Views

This builds directly on Chapter 15's "security through views" pattern: a view is itself a privilege boundary, because granting `SELECT` on a view does not require (or imply) any privilege on the view's underlying base tables — the view runs with the privileges of its **owner**, not its caller, by default.

```sql
-- A general-purpose directory view: no salary, no email
CREATE VIEW company_db.v_employee_directory AS
SELECT
    e.employee_id,
    e.first_name,
    e.last_name,
    e.job_title,
    d.department_name,
    e.hire_date,
    e.status
FROM company_db.employees e
LEFT JOIN company_db.departments d ON d.department_id = e.department_id;

-- General reporting role: sees the directory view only, never raw tables
CREATE ROLE reporting_role NOLOGIN;
GRANT USAGE ON SCHEMA company_db TO reporting_role;
GRANT SELECT ON company_db.v_employee_directory TO reporting_role;

-- HR gets a separate role with full underlying access, including salaries
CREATE ROLE hr_full_access_role NOLOGIN;
GRANT SELECT, UPDATE ON company_db.employees TO hr_full_access_role;
GRANT SELECT, INSERT, UPDATE ON company_db.salaries TO hr_full_access_role;
```

```sql
SET ROLE reporting_role;
SELECT * FROM company_db.v_employee_directory LIMIT 3;
```
```
 employee_id | first_name | last_name | job_title            | department_name | hire_date  | status
-------------+------------+-----------+----------------------+------------------+------------+--------
           1 | Aditi      | Rao       | CTO                  | Engineering      | 2015-03-01 | ACTIVE
           2 | Rahul      | Mehta     | Engineering Manager  | Engineering      | 2016-05-12 | ACTIVE
           3 | Sneha      | Kulkarni  | Senior Engineer      | Engineering      | 2017-01-20 | ACTIVE
```

```sql
SET ROLE reporting_role;
SELECT * FROM company_db.employees;
```
```
ERROR:  permission denied for table employees
```
`reporting_role` was never granted anything on `company_db.employees` directly — only on the view. It genuinely cannot query the base table, cannot see `email`, and has no path to `salaries` at all.

```sql
SET ROLE hr_full_access_role;
SELECT e.first_name, e.last_name, s.base_salary
FROM company_db.employees e JOIN company_db.salaries s USING (employee_id)
WHERE e.employee_id = 1;
```
```
 first_name | last_name | base_salary
------------+-----------+-------------
 Aditi      | Rao       |   520000.00
```

---

## 27.11 Practical Example 2 — Application Role for `ecommerce_db` CRUD

A typical order-processing service needs to create orders and order lines, update their status, and read (never modify) the product catalog — and must never be able to delete historical orders or run any DDL.

```sql
CREATE ROLE app_service_role NOLOGIN;
GRANT USAGE ON SCHEMA ecommerce_db TO app_service_role;

-- Full CRUD (minus DELETE) on the tables the order flow actually writes
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.orders       TO app_service_role;
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.order_items  TO app_service_role;

-- Read-only on the product catalog — the service never modifies prices/stock itself
GRANT SELECT ON ecommerce_db.products   TO app_service_role;
GRANT SELECT ON ecommerce_db.categories TO app_service_role;

-- Sequences backing the SERIAL columns must be usable too, or INSERT fails (see §27.14)
GRANT USAGE, SELECT ON SEQUENCE
    ecommerce_db.orders_order_id_seq,
    ecommerce_db.order_items_order_item_id_seq
    TO app_service_role;

-- Explicitly nothing else: no DELETE anywhere, no DDL of any kind
```

```sql
SET ROLE app_service_role;

INSERT INTO ecommerce_db.orders (user_id, status, shipping_address)
VALUES (2, 'PENDING', '45 Park St, Kolkata')
RETURNING order_id;
```
```
 order_id
----------
       11
```

```sql
SET ROLE app_service_role;
DELETE FROM ecommerce_db.orders WHERE order_id = 11;
```
```
ERROR:  permission denied for table orders
```

```sql
SET ROLE app_service_role;
UPDATE ecommerce_db.products SET price = 0 WHERE product_id = 1;
```
```
ERROR:  permission denied for table products
```

```sql
SET ROLE app_service_role;
CREATE TABLE ecommerce_db.rogue_table (id INT);
```
```
ERROR:  permission denied for schema ecommerce_db
```
The last error is a schema-level `CREATE` denial (§27.4) — `app_service_role` has `USAGE` (to resolve object names) but never `CREATE` on the schema, so it cannot make new objects at all, only operate on the ones it was explicitly granted.

---

## 27.12 Practical Example 3 — Full Row-Level Security on `banking_db.accounts`

This assembles everything from §27.5 into one complete, runnable script — role, schema usage, table grants, RLS enable, both policies, and the session-variable pattern for passing "current customer" context in.

```sql
-- Role setup
CREATE ROLE customer_role NOLOGIN;
GRANT USAGE ON SCHEMA banking_db TO customer_role;
GRANT SELECT, UPDATE ON banking_db.accounts TO customer_role;

-- Enable RLS and define policies
ALTER TABLE banking_db.accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY customer_select_own_accounts
    ON banking_db.accounts
    FOR SELECT
    TO customer_role
    USING (customer_id = current_setting('app.current_customer_id')::int);

CREATE POLICY customer_update_own_accounts
    ON banking_db.accounts
    FOR UPDATE
    TO customer_role
    USING (customer_id = current_setting('app.current_customer_id')::int)
    WITH CHECK (customer_id = current_setting('app.current_customer_id')::int);
```

**Application login flow, per request (multi-tenant "current customer" pattern):**
```sql
BEGIN;
SET LOCAL ROLE customer_role;
SET LOCAL app.current_customer_id = '4';   -- Kavita Desai authenticated as customer_id = 4

SELECT account_id, account_type, balance, status
FROM banking_db.accounts;
```
```
 account_id | account_type | balance  | status
------------+--------------+----------+--------
          6 | SAVINGS      | 20000.00 | ACTIVE
```
```sql
COMMIT;   -- SET LOCAL values automatically expire here
```

**Attempting to read someone else's account by ID directly — RLS still applies, even with a specific `WHERE`:**
```sql
BEGIN;
SET LOCAL ROLE customer_role;
SET LOCAL app.current_customer_id = '4';

SELECT * FROM banking_db.accounts WHERE account_id = 4;   -- belongs to customer_id = 3, not 4
COMMIT;
```
```
 account_id | customer_id | account_type | balance | opened_date | status
------------+-------------+--------------+---------+-------------+--------
(0 rows)
```
No error — the row simply isn't there, from this role's point of view, exactly as if it had been filtered by an invisible, un-bypassable `AND customer_id = 4` appended to the query.

---

## 27.13 Practical Example 4 — Hardening `PUBLIC` Default Privileges

### The historical gotcha
**[PostgreSQL, pre-15]** every newly created database automatically contained a `public` schema that granted `CREATE` and `USAGE` **to the special pseudo-role `PUBLIC`** — meaning *every* role in the entire cluster, with no explicit grant needed, could create objects in `public` and use whatever was already there. Combined with the fact that many applications default to using the `public` schema for everything, this meant any authenticated (even very low-privileged) role could create tables in a shared namespace, and — more subtly — any object you create is, by default, immediately readable structure-wise (though not automatically `SELECT`-able on data, since table-level privileges are a separate layer) to any role that has `USAGE` on the schema, which `PUBLIC` already had.

> **Important Note — PostgreSQL 15+ changed this**
> As of **PostgreSQL 15**, newly created databases no longer grant `CREATE` on the `public` schema to `PUBLIC` by default — the `public` schema is now owned by a new predefined role, `pg_database_owner`, and ordinary roles can no longer create objects there unless explicitly granted. This closed the most dangerous half of the historical gotcha for *new* databases. **`USAGE` on `public` is still granted to `PUBLIC` by default**, even in PostgreSQL 15+, and **any database upgraded/migrated from an older version keeps its old, more permissive grants** unless someone explicitly revokes them — so this hardening step remains relevant and worth applying explicitly, rather than assumed.

### The hardening pattern

```sql
-- Revoke the ability for arbitrary roles to create objects in (or, pre-15, use) the public schema
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Then explicitly re-grant USAGE only to the roles that legitimately need it
GRANT USAGE ON SCHEMA public TO app_service_role, reporting_role;
```

The same principle applies to **objects**, not just the schema — `REVOKE`ing default `PUBLIC` grants on tables:
```sql
REVOKE ALL ON ALL TABLES IN SCHEMA ecommerce_db FROM PUBLIC;
```

### `ALTER DEFAULT PRIVILEGES` — making the fix apply to *future* objects too

`REVOKE`/`GRANT` only affects objects that already exist. If someone creates a new table in `ecommerce_db` next month, it will **not** automatically carry the intended grants for `reporting_role` or `app_service_role` unless `ALTER DEFAULT PRIVILEGES` was set up in advance:

```sql
-- From now on, any NEW table created by dba_migration_role in ecommerce_db
-- automatically grants SELECT to reporting_role and app_service_role, with no manual step
ALTER DEFAULT PRIVILEGES FOR ROLE dba_migration_role IN SCHEMA ecommerce_db
    GRANT SELECT ON TABLES TO reporting_role;

ALTER DEFAULT PRIVILEGES FOR ROLE dba_migration_role IN SCHEMA ecommerce_db
    GRANT SELECT, INSERT, UPDATE ON TABLES TO app_service_role;

-- And make sure PUBLIC never gets anything on future objects either
ALTER DEFAULT PRIVILEGES IN SCHEMA ecommerce_db
    REVOKE ALL ON TABLES FROM PUBLIC;
```

> **Important Note** — `ALTER DEFAULT PRIVILEGES FOR ROLE X` only affects objects **subsequently created by role X**. If your migration pipeline sometimes runs as `dba_migration_role` and sometimes as a different role, you need a matching `ALTER DEFAULT PRIVILEGES FOR ROLE ...` clause for each role that might create objects, or the "forgot to grant on the new table" problem from §27.2.9 resurfaces exactly as before, just for a subset of tables instead of all of them.

### Verifying the fix

```sql
SET ROLE some_unrelated_role;   -- a role with no explicit grants at all
CREATE TABLE public.rogue (id INT);
```
```
ERROR:  permission denied for schema public
```

---

## 27.14 Common Mistakes — Consolidated

| Mistake | Why it happens | Fix |
|---|---|---|
| Granting `SELECT` on a table but not `USAGE` on its schema | Easy to forget the schema is a separate privilege layer at all | `GRANT USAGE ON SCHEMA x TO role;` alongside every object grant |
| Forgetting `ALTER DEFAULT PRIVILEGES` | Grants only ever apply to objects that exist *at grant time* | Set up `ALTER DEFAULT PRIVILEGES FOR ROLE <migration-role> IN SCHEMA ...` once, up front |
| Granting `INSERT` on a `SERIAL`-backed table without `USAGE`/`SELECT` on its sequence | The sequence is a separate object with its own ACL, invisible unless you think to look | `GRANT USAGE, SELECT ON SEQUENCE schema.table_col_seq TO role;` |
| Running the application as a superuser/table-owner role | "Everything just works," no permission debugging | Always use a narrowly-scoped service role; see §27.9's warning |
| Assuming `ENABLE ROW LEVEL SECURITY` alone protects data | RLS with zero matching policies denies **all** rows for non-owners, which can look like it "isn't doing anything" during testing if you're connected as owner | Always test policies from the actual restricted role (`SET ROLE`), never as owner/superuser |
| Forgetting `WITH CHECK` on a write-applicable policy | `USING` alone is reused for checks, which is *usually* fine but not always what you meant | State `WITH CHECK` explicitly whenever read and write rules should differ |
| Treating input validation/escaping as sufficient injection defense | Feels like "we handled it" without removing the actual mechanism | Parameterized queries / `EXECUTE ... USING`, always, as the primary defense |
| Building deep, tangled role-membership hierarchies | Grown ad hoc over years, no single owner of "what does this role mean" | Keep role hierarchies shallow, named by job function, documented in one place |

---

## 27.15 Edge Cases

> **⚠️ Warning — Table owners bypass row-level security by default**
> This is the single most surprising RLS behavior, and it catches almost everyone the first time: **the owner of a table is exempt from that table's RLS policies**, even after `ENABLE ROW LEVEL SECURITY`, unless the table is *additionally* altered with `FORCE ROW LEVEL SECURITY`:
> ```sql
> ALTER TABLE banking_db.accounts FORCE ROW LEVEL SECURITY;
> ```
> Without `FORCE`, if your application happens to connect as the table's owner (exactly the anti-pattern §27.9 warns against), every policy you painstakingly wrote is **silently never evaluated** for that connection — `SELECT * FROM accounts` as the owner returns every row in the table, policies or no policies, and this can look, superficially, like "RLS just isn't working," when what actually happened is that RLS was never in scope for that particular role at all. `FORCE ROW LEVEL SECURITY` closes this gap by making policies apply to the owner too (superusers remain exempt regardless, even with `FORCE`, since no ACL/RLS mechanism ever restricts a superuser). The practical takeaway compounds directly with §27.9: **connect the application as a non-owner, non-superuser role, and consider `FORCE ROW LEVEL SECURITY` for genuinely sensitive tables even then**, as defense against a future connection accidentally using the owner role.

- **Zero matching policies ≠ unrestricted access — it means zero rows.** Once RLS is enabled on a table, any role with no applicable policy for a given command sees nothing for that command, not everything. This is the opposite default from `GRANT`, where "no grant" also means "no access" — so the two systems agree in spirit, but it's worth stating precisely because RLS's "deny by default once enabled" is a stronger, table-wide switch that many people expect to behave more like an opt-in filter than an opt-in *unlock*.
- **`RESTRICTIVE` policies compose with AND, `PERMISSIVE` policies compose with OR.** Mixing both types on the same table is powerful (e.g., a permissive "see your own accounts" policy plus a restrictive "only during business hours" policy layered on top) but easy to reason about incorrectly if you forget which combinator applies to which kind.
- **`REVOKE ... CASCADE`** can revoke privileges that were, in turn, granted onward by the role you're revoking from — a chain reaction worth checking with `\dp`/`\z` in `psql` before running in production, since it can silently remove more access than intended.

---

## 27.16 RLS vs Application-Level Filtering vs Separate Schemas per Tenant

| Approach | Enforced for every caller? | Performance | Best for |
|---|---|---|---|
| **Row-level security** | Yes — enforced by the engine itself, on every query, regardless of caller | Good, if the policy column is indexed (§27.5.7) | Shared-table multi-tenancy where tenants are numerous and rows are naturally interleaved (e.g., `banking_db.accounts` shared across all customers) |
| **Application-level filtering** (manually adding `WHERE tenant_id = ...` everywhere) | No — only for code paths that remember to add it | Identical to any other filtered query | Simple systems with very few, trusted call sites; acceptable *temporarily*, never as the sole long-term control for sensitive data |
| **Separate schema (or database) per tenant** | Yes — structurally impossible to cross tenants without literally connecting to a different schema/database | Best isolation, worst operational overhead (migrations/backups multiply per tenant) | Small numbers of large, high-value tenants (e.g., enterprise SaaS customers each needing dedicated resources/compliance boundaries) |

The general guidance: prefer RLS for the common "many small tenants sharing tables" shape (this is exactly `banking_db`'s shape — many customers, one `accounts` table); reserve schema-per-tenant for the much smaller "few, large, high-isolation tenants" shape; treat pure application-level filtering as a stopgap, never as the only defense for sensitive data, for the same "one forgotten code path" reason argued throughout this chapter.

---

## 27.17 Dialect Comparison Summary

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| User/role model | Unified `ROLE` (LOGIN/NOLOGIN) | `CREATE USER` + `CREATE ROLE` (8.0+), separate | Distinct `USER` and `ROLE` objects | Two-tier: server `LOGIN` + database `USER` |
| Column-level GRANT | Yes | Yes | Yes | Yes |
| Role inheritance | `GRANT role TO role`, `INHERIT`/`NOINHERIT` | `GRANT role TO user`, `SET (DEFAULT) ROLE` | `GRANT role TO role/user` | `sp_addrolemember` / `ALTER ROLE ... ADD MEMBER` |
| Native row-level security | Yes — `CREATE POLICY` | **No** — simulate via views/app logic | Yes — VPD / `DBMS_RLS` | Yes — `CREATE SECURITY POLICY` |
| Table owner bypasses RLS by default | Yes (unless `FORCE ROW LEVEL SECURITY`) | N/A | No — VPD applies regardless of ownership by default | No — security policies apply regardless of ownership |
| Deferred/default privileges for future objects | `ALTER DEFAULT PRIVILEGES` | No direct equivalent — must re-grant per object | Default roles/privileges via `DEFAULT ROLE`, distinct mechanism | No direct equivalent — must re-grant per object |

---

## 27.18 Real-World Use Cases

- **Multi-tenant SaaS platforms** — RLS on a shared `accounts`/`orders`/`documents` table keyed by `tenant_id`/`customer_id`, exactly the `banking_db.accounts` pattern in §27.12, is the standard way to serve many customers from one set of tables without giving every application code path the responsibility of remembering a `WHERE` clause.
- **HR/payroll data segregation** — the `reporting_role` vs `hr_full_access_role` split in §27.10 mirrors real organizations exactly: general staff-directory lookups are broadly available, but compensation data is restricted to a small, explicitly-granted group, enforced at the database layer regardless of which internal tool or script is querying it.
- **Reporting/analytics access tiers** — a `reporting_role` limited to `SELECT` on curated views is how most companies expose data to BI tools (Looker, Metabase, Tableau) safely: the BI tool's database credentials can never accidentally run a write, and can never see columns the view doesn't expose, no matter what the BI tool's query builder lets an analyst construct.
- **Regulatory compliance (PCI-DSS, HIPAA, SOX)** — many compliance frameworks explicitly require least-privilege access controls and audit trails of who can access sensitive fields (cardholder data, health records, financial records); column-level `GRANT`/`REVOKE` and RLS policies are frequently the literal mechanism auditors ask to see evidence of.
- **Defense against SQL injection in legacy code** — even in a codebase where some legacy dynamic-SQL code path can't be fully rewritten immediately, running that code path under a tightly-scoped, least-privilege role (§27.9) limits the damage a successful injection against it can do, buying time to fix the actual vulnerability.

---

## 27.19 Practice Questions

1. Explain, precisely, why `GRANT SELECT ON banking_db.accounts TO customer_role;` alone is not sufficient for `customer_role` to query that table, and name the exact additional statement required.
2. A colleague creates a new table in `ecommerce_db` and reports that `reporting_role` — which has worked fine on every other table for months — suddenly can't see it. What is the most likely cause, and what one-time setup would have prevented this from ever happening again?
3. Explain the difference between `USING` and `WITH CHECK` in a `CREATE POLICY` statement. Give a concrete scenario (not from this chapter) where a role should be allowed to *read* more rows than it's allowed to *write*.
4. Why does `ALTER TABLE banking_db.accounts ENABLE ROW LEVEL SECURITY` with no policies at all result in `customer_role` seeing zero rows, rather than all rows? Contrast this with what `GRANT`'s default (no grant) also means, and explain why the two defaults are conceptually consistent even though the mechanisms are different.
5. A table owner runs `SELECT * FROM banking_db.accounts` and sees every row, despite RLS being enabled and policies being correctly written. Explain exactly why, and name the one `ALTER TABLE` statement that would change this.
6. Precisely explain why a parameterized query prevents SQL injection, in terms of *when* the SQL text is parsed relative to *when* user-supplied values are bound. Do not just say "it escapes quotes" — explain why escaping is not actually the mechanism at work.
7. Rewrite this vulnerable PL/pgSQL fragment as safe dynamic SQL using `EXECUTE ... USING`: `EXECUTE 'SELECT * FROM ecommerce_db.users WHERE username = ''' || p_username || '''';`
8. Why is `MySQL`'s lack of native row-level security a genuine structural limitation rather than a minor inconvenience? Describe the two common workarounds and the specific weakness of each.
9. Explain the two-tier login/user model in SQL Server. Give a concrete scenario where a login can successfully connect to the SQL Server instance but fail every query against a specific database, and explain why that isn't a contradiction.
10. Why should the running application never connect to the database as its schema owner, even if doing so is "simpler" during development? List at least three independent reasons, not just one.
11. `GRANT INSERT ON ecommerce_db.orders TO app_service_role;` was run, but inserts still fail with a permission error referencing a sequence. Explain what's missing and write the statement that fixes it.
12. Design (in words, not SQL) a `RESTRICTIVE` policy that could be layered on top of the `customer_select_own_accounts` permissive policy from §27.12, to additionally block all account access outside business hours — explain why it must be declared `RESTRICTIVE` rather than `PERMISSIVE` to have the intended effect.

---

## 27.20 Chapter Challenge — Design a Complete Role/Privilege Matrix for a 4-Role `ecommerce_db` Application

**Task:** Design the full privilege matrix for four roles serving one `ecommerce_db` application, and write every `GRANT` statement needed to implement it.

**The four roles:**
1. `public_reporting_role` — powers an external-facing analytics dashboard (catalog browsing stats, category performance). Must never see any customer PII or payment data.
2. `customer_support_role` — used by human support agents who need to look up a customer's orders, order lines, and payment status to answer questions, and occasionally cancel a pending order on the customer's behalf.
3. `app_service_role` — the running e-commerce application itself, exactly as built in §27.11, extended here to also handle payments and reviews.
4. `dba_migration_role` — used only by the deployment pipeline for schema changes; never used by any running service.

**Privilege matrix:**

| Table | `public_reporting_role` | `customer_support_role` | `app_service_role` | `dba_migration_role` |
|---|---|---|---|---|
| `users` | – | SELECT | SELECT, INSERT, UPDATE | ALL (DDL) |
| `categories` | SELECT | SELECT | SELECT | ALL (DDL) |
| `products` | SELECT | SELECT | SELECT | ALL (DDL) |
| `inventory` | – | SELECT | SELECT | ALL (DDL) |
| `orders` | – | SELECT, UPDATE (status only) | SELECT, INSERT, UPDATE | ALL (DDL) |
| `order_items` | – | SELECT | SELECT, INSERT, UPDATE | ALL (DDL) |
| `payments` | – | SELECT | SELECT, INSERT, UPDATE | ALL (DDL) |
| `reviews` | SELECT (aggregated via view) | SELECT | SELECT, INSERT, UPDATE, DELETE | ALL (DDL) |
| Schema `ecommerce_db` (`USAGE`) | Yes | Yes | Yes | Yes |
| Schema `ecommerce_db` (`CREATE`) | No | No | No | Yes |

Notes on the design decisions baked into this matrix:
- **No role except `dba_migration_role` ever gets `DELETE` on `orders`, `order_items`, or `payments`** — these are the audit-relevant financial records; even the application itself only ever transitions their `status` column, it never removes rows. `reviews` is the one exception where `app_service_role` gets `DELETE`, since a user deleting their own review is a legitimate, non-financial, non-audit-relevant action.
- **`customer_support_role`'s `UPDATE` on `orders` is scoped to the status column only**, via column-level grant — a support agent can cancel an order (`status = 'CANCELLED'`) but cannot rewrite its `shipping_address` or fabricate a different `user_id` on it.
- **`public_reporting_role` never touches `users`, `orders`, `order_items`, or `payments` at all** — it only sees the product catalog and aggregate review data through a view, never anything that could identify a customer or a purchase.

**Reference GRANT statements:**

```sql
-- ============================================================
-- Roles
-- ============================================================
CREATE ROLE public_reporting_role NOLOGIN;
CREATE ROLE customer_support_role NOLOGIN;
CREATE ROLE app_service_role      NOLOGIN;
CREATE ROLE dba_migration_role    NOLOGIN;

-- ============================================================
-- Schema usage (every role needs this; only migrations get CREATE)
-- ============================================================
GRANT USAGE ON SCHEMA ecommerce_db
    TO public_reporting_role, customer_support_role, app_service_role, dba_migration_role;
GRANT CREATE ON SCHEMA ecommerce_db TO dba_migration_role;

-- ============================================================
-- public_reporting_role — catalog + aggregate reviews only
-- ============================================================
CREATE VIEW ecommerce_db.v_product_catalog AS
    SELECT product_id, product_name, category_id, price, is_discontinued
    FROM ecommerce_db.products;

CREATE VIEW ecommerce_db.v_product_rating_summary AS
    SELECT product_id, ROUND(AVG(rating), 2) AS avg_rating, COUNT(*) AS review_count
    FROM ecommerce_db.reviews
    GROUP BY product_id;

GRANT SELECT ON ecommerce_db.categories TO public_reporting_role;
GRANT SELECT ON ecommerce_db.v_product_catalog TO public_reporting_role;
GRANT SELECT ON ecommerce_db.v_product_rating_summary TO public_reporting_role;

-- ============================================================
-- customer_support_role — read broadly, narrow write on order status
-- ============================================================
GRANT SELECT ON ecommerce_db.users, ecommerce_db.products, ecommerce_db.categories,
                 ecommerce_db.inventory, ecommerce_db.orders, ecommerce_db.order_items,
                 ecommerce_db.payments, ecommerce_db.reviews
    TO customer_support_role;
GRANT UPDATE (status) ON ecommerce_db.orders TO customer_support_role;

-- ============================================================
-- app_service_role — the running application
-- ============================================================
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.users        TO app_service_role;
GRANT SELECT                 ON ecommerce_db.products     TO app_service_role;
GRANT SELECT                 ON ecommerce_db.categories   TO app_service_role;
GRANT SELECT                 ON ecommerce_db.inventory    TO app_service_role;
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.orders       TO app_service_role;
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.order_items  TO app_service_role;
GRANT SELECT, INSERT, UPDATE ON ecommerce_db.payments     TO app_service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ecommerce_db.reviews TO app_service_role;

GRANT USAGE, SELECT ON SEQUENCE
    ecommerce_db.users_user_id_seq,
    ecommerce_db.orders_order_id_seq,
    ecommerce_db.order_items_order_item_id_seq,
    ecommerce_db.payments_payment_id_seq,
    ecommerce_db.reviews_review_id_seq
    TO app_service_role;

-- ============================================================
-- dba_migration_role — full DDL, deployment pipeline only
-- ============================================================
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ecommerce_db TO dba_migration_role;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ecommerce_db TO dba_migration_role;

ALTER DEFAULT PRIVILEGES FOR ROLE dba_migration_role IN SCHEMA ecommerce_db
    GRANT SELECT ON TABLES TO public_reporting_role;
ALTER DEFAULT PRIVILEGES FOR ROLE dba_migration_role IN SCHEMA ecommerce_db
    GRANT SELECT ON TABLES TO customer_support_role;
ALTER DEFAULT PRIVILEGES FOR ROLE dba_migration_role IN SCHEMA ecommerce_db
    GRANT SELECT, INSERT, UPDATE ON TABLES TO app_service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA ecommerce_db
    REVOKE ALL ON TABLES FROM PUBLIC;

-- Hardening: no role should ever get anything through PUBLIC by accident
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA ecommerce_db FROM PUBLIC;
```

**Extension exercise:** Add row-level security so `customer_support_role` can only see orders and payments for customers **not flagged as VIP** (imagine a hypothetical `users.is_vip BOOLEAN` column, escalated instead to a dedicated `vip_support_role`), and explain, referencing §27.15, exactly which grant statement (`FORCE ROW LEVEL SECURITY` or not) is needed for this restriction to actually apply if `dba_migration_role` happens to own the `orders` table.

---

## Key Takeaways

- PostgreSQL unifies "users" and "groups" into one `ROLE` object distinguished only by the `LOGIN` attribute; MySQL, Oracle, and especially SQL Server's two-tier login/user model keep the concepts more separate — know which model you're working in.
- `GRANT`/`REVOKE` operate at table, column, function, sequence, and schema granularity; **schema `USAGE` is a separate, prerequisite privilege** to any object privilege inside it — the most common "why doesn't my grant work" mistake in this whole chapter.
- Role membership (`GRANT role_a TO role_b`) plus `INHERIT`/`NOINHERIT` is how privilege sets compose without duplicating grants across every individual person.
- Row-level security (`ENABLE ROW LEVEL SECURITY` + `CREATE POLICY ... USING ... WITH CHECK ...`) transparently appends a `WHERE`-clause-shaped predicate to every query against a table, for every caller, with no application code able to forget it — the `banking_db.accounts` / `customer_role` / `current_setting('app.current_customer_id')` pattern is the canonical multi-tenant shape.
- **Table owners (and superusers) bypass RLS by default** unless `FORCE ROW LEVEL SECURITY` is set — this is the single most surprising RLS behavior and the reason the application must never connect as the table owner.
- MySQL has **no native row-level security**; it must be simulated with views (with direct table access revoked) or enforced entirely in application code, both weaker than a database-enforced policy.
- SQL injection works because untrusted input, concatenated into SQL text, is parsed as SQL syntax rather than treated as data; parameterized queries eliminate the mechanism entirely by sending SQL structure and data values separately, so user input is never parsed as syntax, only bound as a literal.
- Least privilege bounds the blast radius of any single compromised credential, bug, or successful injection — reporting roles get `SELECT` on curated views only, application roles get exactly the CRUD they need with no DDL and no `DELETE` on audit-relevant tables, and migration/admin roles are never used by the running application.
- Historical `PUBLIC` default grants on the `public` schema (loosened further before PostgreSQL 15) and forgetting `ALTER DEFAULT PRIVILEGES` for future objects are the two most common "silent over-permissioning" gotchas in real PostgreSQL deployments.

## What's Next

This chapter secured *who can do what, to which rows* — but privileges and policies don't help you if the data itself is lost: a dropped table, a failed disk, a bad migration with no way back. [Chapter 28 — Backup & Recovery Concepts](28-backup-recovery.md) covers how to make sure that, no matter what goes wrong, you can always get the data back — logical vs. physical backups, point-in-time recovery, and the backup strategies that turn "we lost production data" from a catastrophe into an inconvenience.
