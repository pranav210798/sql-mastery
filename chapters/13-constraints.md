# Chapter 13 — Constraints

> **Part IV — Advanced SQL & Database Engineering**
> Previous: [Chapter 12 — Locks & Concurrency](12-locks-concurrency.md) · Next: [Chapter 14 — Database Design & Normalization](14-database-design-normalization.md)

This chapter runs against `company_db`, `ecommerce_db`, and `banking_db`. If you haven't loaded them yet:

```bash
psql -f databases/company_db.sql
psql -f databases/ecommerce_db.sql
psql -f databases/banking_db.sql
```

---

## 13.0 What This Chapter Is Really About

Every table you've queried so far in this course — `employees`, `orders`, `accounts`, `reviews` — already has constraints on it. You've been relying on them without necessarily noticing: `employees.email` can never be duplicated, `accounts.balance` can never go negative, `reviews.rating` can never be `7`. None of that happened by accident, and none of it happened because the application code was careful. It happened because the schema itself refuses to store anything else.

That is the entire subject of this chapter: **constraints are rules the database enforces on every single write, no matter what wrote it** — your API, a teammate's one-off script, a bulk `COPY` import, a broken migration, a bug in a background job three years from now. A `SELECT` can only tell you what's currently true. A constraint tells the database what must *always* be true, and refuses any operation that would break it.

We'll work entirely from the constraints already declared in `company_db.sql`, `ecommerce_db.sql`, and `banking_db.sql`, adding a few new ones only where it helps teach a concept the existing schema doesn't demonstrate.

---

## 13.1 PRIMARY KEY

### 1. Simple explanation
A primary key is the column (or set of columns) that uniquely identifies each row in a table — like a national ID number for a person. No two rows can share one, and it can never be missing.

### 2. Technical explanation
`PRIMARY KEY` is a composite constraint: it is `UNIQUE` **and** `NOT NULL` combined, applied to one column or a group of columns, with the added semantic that a table may have **at most one** primary key. The database uses the primary key as the canonical row identity for internal bookkeeping (physical replication identity, default clustering candidate in some engines, and the natural target for foreign keys).

### 3. Why it exists
Every relational table needs an unambiguous way to say "this specific row, and only this row." Without a primary key you cannot reliably `UPDATE`, `DELETE`, or reference a single row from another table — you'd be forced to match on a combination of columns that might not actually be unique, risking updating or deleting more rows than intended. The primary key is also what a foreign key points *to*, so it's the anchor of every parent–child relationship in the schema.

### 4. Full syntax

**Column-level (single-column PK):**
```sql
CREATE TABLE departments (
    department_id   SERIAL PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE
);
```

**Table-level (needed for composite keys):**
```sql
CREATE TABLE employee_projects (
    employee_id     INT NOT NULL REFERENCES employees(employee_id) ON DELETE CASCADE,
    project_id      INT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    role            VARCHAR(100) NOT NULL,
    hours_allocated INT NOT NULL DEFAULT 0 CHECK (hours_allocated >= 0),
    PRIMARY KEY (employee_id, project_id)
);
```

**Adding after the fact:**
```sql
ALTER TABLE some_table
    ADD CONSTRAINT some_table_pkey PRIMARY KEY (id);
```

### 5. Real examples from the course databases

- `company_db.departments(department_id)` — single-column surrogate key, `SERIAL` (auto-incrementing).
- `company_db.employee_projects(employee_id, project_id)` — a genuine **composite primary key**. This bridge table models the many-to-many relationship between employees and projects; a single employee/project pair should exist at most once, but neither column alone is unique (one employee works on many projects, one project has many employees). The *pair* is what's unique.
- `banking_db.transactions(transaction_id)` — `BIGSERIAL` because transaction volume can exceed the range of a 32-bit `SERIAL` over the bank's lifetime.
- `company_db.managers(manager_id)` — the PK here is also a FK (`REFERENCES employees(employee_id)`), modeling a strict one-to-one relationship (Chapter 14 covers this pattern in depth).

### 6. Expected behavior when violated

```sql
INSERT INTO company_db.employee_projects (employee_id, project_id, role, hours_allocated)
VALUES (2, 1, 'Duplicate Tech Lead', 100);
```
```
ERROR:  duplicate key value violates unique constraint "employee_projects_pkey"
DETAIL:  Key (employee_id, project_id)=(2, 1) already exists.
```

```sql
INSERT INTO company_db.departments (department_id, department_name) VALUES (NULL, 'Legal');
```
```
ERROR:  null value in column "department_id" of relation "departments" violates not-null constraint
DETAIL:  Failing row contains (null, Legal, null, ...).
```

### 7. Line-by-line
- `PRIMARY KEY (employee_id, project_id)` at the table level declares the **pair** as the uniqueness unit, not each column independently.
- Every column listed in a primary key is implicitly forced `NOT NULL`, even if you didn't write it — PostgreSQL adds that internally.
- A table-level constraint clause is required whenever more than one column participates; column-level `PRIMARY KEY` only works for single-column keys.

### 8. Internal behavior
A `PRIMARY KEY` is not just a rule checked in application logic inside the engine — it is physically backed by a **unique index** (in PostgreSQL, a B-tree by default) created automatically the moment the constraint is added. That index is what makes the uniqueness check fast: instead of scanning the whole table on every insert, the database does an index lookup. This is also why primary keys are cheap to join on and why we foreshadow Chapter 16 (Indexes) here — the PK index is usually a query plan's best friend.

### 9. Common mistakes
- Choosing a "natural" key (email, SSN, product SKU) as the primary key and then discovering the business changes it — email addresses get reused, SKUs get revised. Surrogate keys (`SERIAL`/`IDENTITY`) avoid this by being purely internal and permanent. Note that `ecommerce_db.products.sku` is `UNIQUE`, not the primary key — `product_id` is — precisely for this reason.
- Forgetting that a composite primary key like `(employee_id, project_id)` does **not** let you efficiently look up "all projects for employee 6" using an index on `project_id` alone — the composite index is ordered by `employee_id` first (see Chapter 16 for column-order implications).

### 10. Edge cases
- A table can have zero primary keys (PostgreSQL allows PK-less tables), but then it also has no reliable single-row identity, no default target for foreign keys, and worse replication/upsert behavior. Not recommended, ever, for a real schema.
- Every column in a composite primary key must be `NOT NULL` — you cannot have `PRIMARY KEY (a, b)` with `b` nullable; the engine rejects the `CREATE TABLE` outright, or, if columns already exist, forces them `NOT NULL` as part of adding the constraint.

---

## 13.2 FOREIGN KEY

### 1. Simple explanation
A foreign key says "this value must already exist as a primary/unique key value in another table." It's how you connect a row in `orders` to the `user` who placed it, guaranteeing you can never have an order pointing to a nonexistent user.

### 2. Technical explanation
A `FOREIGN KEY` constraint restricts the values in one or more columns (the *referencing*/child columns) to values that currently exist in the primary key or a unique constraint of another table (the *referenced*/parent columns) — or to `NULL`, if the referencing columns are nullable. The database checks this on every `INSERT` and `UPDATE` to the child table, and (depending on the `ON DELETE`/`ON UPDATE` action) on every `DELETE` or key-changing `UPDATE` to the parent table.

### 3. Why it exists
Referential integrity is the guarantee that relationships in your data are never dangling. Without it, application bugs — a race condition, a bad migration, a forgotten `WHERE` clause — can silently leave an `order_items` row pointing at a `product_id` that was deleted, and every report joining those tables from then on either silently drops that row or crashes. A foreign key makes that class of bug *structurally impossible*: the database refuses the write in the first place.

### 4. Full syntax

**Column-level (inline):**
```sql
CREATE TABLE employees (
    employee_id   SERIAL PRIMARY KEY,
    department_id INT REFERENCES departments(department_id) ON DELETE SET NULL,
    manager_id    INT REFERENCES employees(employee_id) ON DELETE SET NULL
);
```

**Table-level (needed for composite FKs, or just for readability/naming):**
```sql
CREATE TABLE order_items (
    order_item_id SERIAL PRIMARY KEY,
    order_id      INT NOT NULL,
    product_id    INT NOT NULL,
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    CONSTRAINT fk_order_items_order   FOREIGN KEY (order_id)   REFERENCES orders(order_id)   ON DELETE CASCADE,
    CONSTRAINT fk_order_items_product FOREIGN KEY (product_id) REFERENCES products(product_id)
);
```

**Adding after the fact:**
```sql
ALTER TABLE ecommerce_db.reviews
    ADD CONSTRAINT fk_reviews_user FOREIGN KEY (user_id) REFERENCES ecommerce_db.users(user_id);
```

### 5. Real examples from the course databases

| Table.Column | References | On Delete | Meaning |
|---|---|---|---|
| `company_db.employees.department_id` | `departments(department_id)` | `SET NULL` | Deleting a department doesn't delete its employees — they just become department-less. |
| `company_db.employees.manager_id` | `employees(employee_id)` (self-referencing) | `SET NULL` | Deleting a manager doesn't delete their reports; reports lose their manager link. |
| `company_db.salaries.employee_id` | `employees(employee_id)` | `CASCADE` | An employee's salary history has no meaning without the employee — delete the employee, delete their history. |
| `ecommerce_db.inventory.product_id` | `products(product_id)` | `CASCADE` | No product, no inventory row for it. |
| `ecommerce_db.order_items.order_id` | `orders(order_id)` | `CASCADE` | Line items can't outlive their order. |
| `ecommerce_db.order_items.product_id` | `products(product_id)` | *(none — RESTRICT/NO ACTION by default)* | Deliberately **not** cascaded: you should not be able to delete a product that has been ordered, since that would corrupt historical order records. |
| `banking_db.accounts.customer_id` | `customers(customer_id)` | *(none)* | A customer with open accounts cannot simply be deleted — this is intentional; see §13.7. |
| `banking_db.transactions.related_account_id` | `accounts(account_id)` | *(none, nullable)* | Only set for transfers; `NULL` for deposits/withdrawals. |

### 6. Expected behavior when violated

Inserting a child row pointing at a nonexistent parent:
```sql
INSERT INTO ecommerce_db.orders (user_id, status) VALUES (9999, 'PENDING');
```
```
ERROR:  insert or update on table "orders" violates foreign key constraint "orders_user_id_fkey"
DETAIL:  Key (user_id)=(9999) is not present in table "users".
```

Deleting a parent row that a child still references, with no cascade/set-null action:
```sql
DELETE FROM ecommerce_db.products WHERE product_id = 1;
```
```
ERROR:  update or delete on table "products" violates foreign key constraint "order_items_product_id_fkey" on table "order_items"
DETAIL:  Key (product_id)=(1) is still referenced from table "order_items".
```

### 7. Line-by-line
- `department_id INT REFERENCES departments(department_id) ON DELETE SET NULL` — the column type (`INT`) must match the referenced column's type exactly; `REFERENCES table(column)` names the parent; `ON DELETE SET NULL` says what happens to this row when the parent row disappears.
- Omitting `ON DELETE ...` entirely defaults to `NO ACTION` (see §13.7) — the strictest, safest default. `ecommerce_db.order_items.product_id` and `banking_db.accounts.customer_id` rely on this default deliberately.
- The referenced column(s) must have a `UNIQUE` or `PRIMARY KEY` constraint on the parent table — you cannot have a foreign key point at an arbitrary, non-unique column.

### 8. Internal behavior
Every `INSERT` or `UPDATE` on the child table triggers a lookup against the parent table's key — in PostgreSQL, this is enforced by a system trigger backed by an index scan on the parent's PK/unique index, which is why that side is fast. The **child** side of the relationship (e.g., `order_items.product_id`) is *not* automatically indexed by the foreign key constraint itself — only the parent's key is guaranteed an index. On `DELETE`/`UPDATE` of the *parent* row, the database must find all matching child rows to either cascade, null out, or check for existence (to raise `RESTRICT`/`NO ACTION`) — and if there's no index on the child column, that becomes a full table scan of the child table. This is exactly the common mistake covered next.

### 9. Common mistakes

> **⚠️ Warning — Missing index on the FK column**
> `CREATE INDEX idx_order_items_product_id ON ecommerce_db.order_items(product_id);` is *not* created automatically by declaring the foreign key. Only the parent's key (`products.product_id`) gets an index for free (from its `PRIMARY KEY`). If you delete a row from `products` and there's no index on `order_items.product_id`, PostgreSQL must sequentially scan all of `order_items` to check whether any row still references that product. On a small seed table this is invisible; on a production `order_items` table with 50 million rows, a single `DELETE FROM products WHERE product_id = 42` can take minutes and hold locks the whole time. **Always index foreign key columns on the child side** — this is one of the single most common production performance bugs, and Chapter 16 covers it in more depth.

> **⚠️ Warning — Overusing `ON DELETE CASCADE`**
> `CASCADE` is easy to reach for because it "just works" and lets you delete a parent without errors. But cascades compose silently across multiple tables. If `customers` cascaded to `accounts`, and `accounts` cascaded to `transactions`, deleting one customer row could silently erase years of financial transaction history with a single `DELETE`. That's precisely why `banking_db` does **not** cascade `accounts.customer_id` or `transactions.account_id` — financial and audit-relevant data should almost never auto-delete. Reserve `CASCADE` for genuine ownership/composition relationships (a salary history row is meaningless without its employee; a line item is meaningless without its order) — not for every FK you write.

### 10. Edge cases

**NULL and foreign keys.** A nullable FK column with value `NULL` is exempt from the constraint entirely — `NULL` doesn't have to match anything, because it represents "no relationship," not "an invalid relationship." This is exactly how `employees.manager_id` works: the CEO (`Aditi Rao`, `employee_id = 1`) has `manager_id = NULL`, which is valid, not a constraint violation, even though there's no row anywhere with `employee_id = NULL`.

**NULL and composite foreign keys.** For a foreign key spanning multiple columns, PostgreSQL's default `MATCH SIMPLE` means the constraint is satisfied if **any** of the referencing columns is `NULL` — the whole check is skipped, even if the other column(s) hold a value that doesn't correspond to any real parent row. `MATCH FULL` tightens this: it requires *either all columns NULL or all columns non-NULL and matching* — a mix of NULL and non-NULL in a composite FK is rejected outright under `MATCH FULL`. This is a subtle, frequently-missed edge case in composite-key schemas.

---

## 13.3 UNIQUE

### 1. Simple explanation
A `UNIQUE` constraint says "no two rows may have the same value in this column (or combination of columns)" — but unlike a primary key, a table can have several of these, and (with caveats below) the column is still allowed to be `NULL`.

### 2. Technical explanation
`UNIQUE` creates a uniqueness constraint enforced via an index over one or more columns. Rows are compared for equality across the constrained column set; PostgreSQL treats `NULL` as *not equal to anything, including another NULL*, for uniqueness purposes (per the SQL standard's default treatment, which PostgreSQL follows).

### 3. Why it exists
Some attributes need to be unique but are not the row's *identity* — an employee's `email` uniquely identifies them for login purposes, but `employee_id` is still the identity every other table references. `UNIQUE` lets you protect business-level uniqueness rules (one email per user, one review per user per product, one SKU per product) independently of your primary key choice.

### 4. Full syntax

**Column-level:**
```sql
CREATE TABLE users (
    user_id  SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email    VARCHAR(150) NOT NULL UNIQUE
);
```

**Table-level (required for multi-column UNIQUE):**
```sql
CREATE TABLE inventory (
    inventory_id       SERIAL PRIMARY KEY,
    product_id         INT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    warehouse_location VARCHAR(100) NOT NULL,
    quantity_on_hand   INT NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
    UNIQUE (product_id, warehouse_location)
);
```

**Adding after the fact:**
```sql
ALTER TABLE company_db.salaries
    ADD CONSTRAINT uq_salaries_employee_effective UNIQUE (employee_id, effective_date);
```
(This is, in fact, exactly the constraint already declared inline in `company_db.sql`.)

### 5. Real examples from the course databases

- `company_db.departments.department_name UNIQUE` — single-column.
- `company_db.employees.email UNIQUE` — single-column.
- `company_db.salaries UNIQUE (employee_id, effective_date)` — multi-column: an employee can have many salary rows over time, but not two effective on the *same* date.
- `company_db.attendance UNIQUE (employee_id, work_date)` — one attendance record per employee per day.
- `ecommerce_db.inventory UNIQUE (product_id, warehouse_location)` — a product can exist in many warehouses, but only one stock row per product/warehouse pair.
- `ecommerce_db.order_items UNIQUE (order_id, product_id)` — a given product appears at most once per order (quantity is adjusted instead of adding duplicate lines).
- `ecommerce_db.reviews UNIQUE (product_id, user_id)` — one review per user per product.
- `ecommerce_db.products.sku UNIQUE` — business-unique identifier, distinct from the surrogate `product_id` primary key.

### 6. Expected behavior when violated

```sql
INSERT INTO ecommerce_db.reviews (product_id, user_id, rating, review_text)
VALUES (1, 1, 3, 'Trying to review the same product twice');
```
```
ERROR:  duplicate key value violates unique constraint "reviews_product_id_user_id_key"
DETAIL:  Key (product_id, user_id)=(1, 1) already exists.
```

### 7. Line-by-line
- `UNIQUE (product_id, warehouse_location)` at the table level treats the **pair** as the uniqueness unit — `(1, 'Mumbai-WH1')` and `(1, 'Delhi-WH2')` can coexist (same product, different warehouses; both already exist in the seed data), but a second `(1, 'Mumbai-WH1')` row is rejected.
- Column-level `UNIQUE` (e.g., `username VARCHAR(50) NOT NULL UNIQUE`) is shorthand for a single-column table-level constraint; the two forms are functionally identical for one column.

### 8. Internal behavior
Exactly like a primary key, `UNIQUE` is backed by a unique index — in fact, `PRIMARY KEY` *is* implemented as `UNIQUE + NOT NULL` under the hood in PostgreSQL, sharing the same index machinery. Every `INSERT`/`UPDATE` touching a unique-constrained column does an index probe before allowing the write. This is fast (logarithmic, not linear) precisely because of that index — another reason Chapter 16 matters: constraints and indexes are two faces of the same mechanism.

### 9. Common mistakes
- Assuming `UNIQUE` prevents multiple `NULL`s. It doesn't, by default, in PostgreSQL/SQL Server/Oracle (see the edge case below) — a mistake that surfaces when someone relies on `UNIQUE` alone to guarantee "at most one row with no value," and gets several.
- Adding a multi-column `UNIQUE` constraint expecting it to also make each column independently unique. `UNIQUE (product_id, warehouse_location)` does **not** make `product_id` unique by itself — `products.product_id = 1` legitimately appears twice in `inventory` (once per warehouse).

### 10. Edge cases

> **Important Note — NULL and UNIQUE**
> **[PostgreSQL, SQL Server, Oracle]**: Multiple rows with `NULL` in a `UNIQUE` column are allowed, because `NULL` is never considered equal to another `NULL` for uniqueness comparison (`NULL = NULL` evaluates to `UNKNOWN`, not `TRUE`). If `ecommerce_db.orders.shipping_address` were `UNIQUE` (it isn't, but hypothetically), you could have any number of orders with `NULL` shipping addresses.
> **[MySQL, InnoDB]**: also allows multiple `NULL`s in a `UNIQUE` column — same standard behavior here.
> **[SQL Server, pre-2008 caveat]**: a `UNIQUE` constraint (not a filtered index) still allows multiple NULLs identically to the others — no special divergence here, but note that only *one* `NULL` is allowed if the column is also the target of certain unique **filtered indexes**, which is a SQL-Server-specific nuance, not a general SQL rule.
> If you need "at most one NULL," you must express it differently — e.g., a partial/filtered unique index (`CREATE UNIQUE INDEX ... WHERE col IS NULL` in PostgreSQL) — which is beyond `UNIQUE` alone and belongs to Chapter 16.

---

## 13.4 NOT NULL

### 1. Simple explanation
`NOT NULL` means "this column must always have a value — leaving it blank is not allowed."

### 2. Technical explanation
`NOT NULL` is a column constraint (it cannot be composite across columns the way `CHECK` or `UNIQUE` can, though you can simulate multi-column "at least one non-null" logic with `CHECK`) that rejects any `INSERT` or `UPDATE` attempting to store `NULL` in that column.

### 3. Why it exists
Some attributes are simply mandatory to the meaning of the row: an employee must have a `hire_date`, an order must have a `user_id`, a transaction must have an `amount`. Allowing these to be `NULL` doesn't just risk bad data — it means every downstream query (aggregate, join, report) must remember to defensively handle the missing case, or silently produce wrong answers. `NOT NULL` eliminates an entire category of null-handling bugs at the source.

### 4. Full syntax

```sql
CREATE TABLE customers (
    customer_id  SERIAL PRIMARY KEY,
    first_name   VARCHAR(50) NOT NULL,
    last_name    VARCHAR(50) NOT NULL,
    email        VARCHAR(150) NOT NULL UNIQUE,
    dob          DATE NOT NULL,
    created_at   TIMESTAMP NOT NULL DEFAULT now()
);
```

**Adding after the fact** (requires that no existing row currently violates it):
```sql
ALTER TABLE ecommerce_db.orders
    ALTER COLUMN shipping_address SET NOT NULL;
```
```sql
-- to remove it:
ALTER TABLE ecommerce_db.orders
    ALTER COLUMN shipping_address DROP NOT NULL;
```

### 5. Real examples from the course databases
`banking_db.customers.dob`, `company_db.employees.hire_date`/`job_title`, `ecommerce_db.orders.user_id`, `banking_db.transactions.amount`, `company_db.salaries.base_salary` — all mandatory business attributes. Contrast with genuinely optional columns left nullable: `company_db.employees.department_id` (an employee can be between departments), `ecommerce_db.orders.shipping_address` (nullable — e.g. digital-goods orders), `banking_db.transactions.related_account_id` (only meaningful for transfers).

### 6. Expected behavior when violated

```sql
INSERT INTO banking_db.customers (first_name, last_name, email, dob)
VALUES ('Amit', 'Sharma', 'amit.sharma@mail.com', NULL);
```
```
ERROR:  null value in column "dob" of relation "customers" violates not-null constraint
DETAIL:  Failing row contains (6, Amit, Sharma, amit.sharma@mail.com, null, ...).
```

### 7. Line-by-line
- `dob DATE NOT NULL` — the constraint travels with the column type declaration; there is no equivalent "table-level" syntax for a single column's `NOT NULL` the way there is for `CHECK`/`UNIQUE`, because it only ever applies to exactly one column.
- `ALTER COLUMN ... SET NOT NULL` will itself fail if any existing row already has `NULL` in that column — you must clean up the data first (or provide a `DEFAULT` and backfill) before the constraint can be added.

### 8. Internal behavior
`NOT NULL` is the cheapest constraint to enforce — it's a flag checked per-column at write time with no index or cross-row lookup involved (unlike `UNIQUE`/`PRIMARY KEY`/`FOREIGN KEY`, which all require checking against other rows). PostgreSQL stores nullability as part of the column's catalog metadata and validates it inline during row construction.

### 9. Common mistakes
- Leaving a column nullable "just in case," then having every query downstream add `COALESCE`/`IS NOT NULL` defensive logic instead of fixing the schema. If a column is *always* supposed to have a value in your business logic, declare it `NOT NULL` — let the database catch the bug, not the report six months later.
- Adding `NOT NULL DEFAULT ...` and assuming existing rows automatically get the default. In PostgreSQL 11+, adding a column with both `NOT NULL` and a constant `DEFAULT` is fast (metadata-only) for new columns, but a plain `ALTER COLUMN ... SET NOT NULL` on an existing column with existing `NULL` rows will fail loudly until you fix or default those rows.

### 10. Edge cases
`NOT NULL` interacts with `CHECK` in a way many people miss — see §13.5.10 below, where a `CHECK` constraint on a nullable column does *not* implicitly enforce non-nullness, because `CHECK (x > 0)` evaluates to `UNKNOWN` (not `FALSE`) when `x IS NULL`, and `UNKNOWN` passes.

---

## 13.5 CHECK

### 1. Simple explanation
A `CHECK` constraint is a custom rule you write yourself — "this value must be between 1 and 5," "this end date must be on or after the start date" — and the database enforces it on every write, just like it enforces `NOT NULL` or `UNIQUE`.

### 2. Technical explanation
`CHECK (expression)` attaches a boolean expression to a column or table. On every `INSERT` and relevant `UPDATE`, the expression is evaluated against the new row; the write is allowed if the expression evaluates to `TRUE` **or `UNKNOWN`**, and rejected only if it evaluates to `FALSE`. This `UNKNOWN`-passes rule (covered in depth in §13.5.10) is a precise, standard-mandated behavior, not an implementation quirk.

### 3. Why it exists
`CHECK` is how you push arbitrary business rules — value ranges, allowed enumerations, cross-column relationships within the same row — down into the schema itself, so they hold true regardless of which application, script, or person is writing the data. This is the clearest expression of the chapter's core theme: **the database enforcing your business rules so bad data can never get in, even if application code has a bug.** An application-layer validation can be forgotten in one code path, skipped by a direct `psql` session, or bypassed by a bulk loader. A `CHECK` constraint cannot be bypassed by any of those, because it isn't optional at the point of writing.

### 4. Full syntax

**Column-level:**
```sql
CREATE TABLE reviews (
    review_id  SERIAL PRIMARY KEY,
    product_id INT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    user_id    INT NOT NULL REFERENCES users(user_id),
    rating     SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5)
);
```

**Table-level (needed when the expression spans multiple columns):**
```sql
CREATE TABLE projects (
    project_id   SERIAL PRIMARY KEY,
    project_name VARCHAR(150) NOT NULL,
    start_date   DATE NOT NULL,
    end_date     DATE,
    budget       NUMERIC(12,2) CHECK (budget >= 0),
    CHECK (end_date IS NULL OR end_date >= start_date)
);
```

**Adding after the fact:**
```sql
ALTER TABLE banking_db.accounts
    ADD CONSTRAINT chk_accounts_balance_nonnegative CHECK (balance >= 0);
```
(This is exactly the check already present inline in `banking_db.sql` — shown here as `ALTER TABLE` syntax for teaching purposes.)

### 5. Real examples from the course databases

| Table.Column(s) | Constraint | Business rule |
|---|---|---|
| `banking_db.accounts.balance` | `CHECK (balance >= 0)` | An account can never go negative (no overdraft modeled). |
| `ecommerce_db.reviews.rating` | `CHECK (rating BETWEEN 1 AND 5)` | Star ratings are bounded. |
| `company_db.employees.status` | `CHECK (status IN ('ACTIVE','ON_LEAVE','TERMINATED'))` | Enumeration — only these three states are valid. |
| `ecommerce_db.orders.status` | `CHECK (status IN ('PENDING','PAID','SHIPPED','DELIVERED','CANCELLED'))` | Order lifecycle enumeration. |
| `ecommerce_db.payments.payment_method` | `CHECK (payment_method IN ('CARD','UPI','NETBANKING','COD','WALLET'))` | Enumeration. |
| `banking_db.transactions.amount` | `CHECK (amount > 0)` | A transaction of zero or negative amount is meaningless (direction is captured by `transaction_type`, not sign). |
| `company_db.projects` | `CHECK (end_date IS NULL OR end_date >= start_date)` | Table-level, cross-column: a project may be ongoing (`end_date IS NULL`), but if it has ended, the end must not precede the start. |
| `company_db.employee_projects.hours_allocated` | `CHECK (hours_allocated >= 0)` | No negative hours. |
| `banking_db.loans.interest_rate` | `CHECK (interest_rate >= 0)` | No negative interest. |

### 6. Expected behavior when violated

```sql
UPDATE banking_db.accounts SET balance = -500 WHERE account_id = 7;
```
```
ERROR:  new row for relation "accounts" violates check constraint "accounts_balance_check"
DETAIL:  Failing row contains (7, 5, CURRENT, -500.00, 2021-09-01, FROZEN).
```

```sql
INSERT INTO ecommerce_db.reviews (product_id, user_id, rating) VALUES (2, 3, 7);
```
```
ERROR:  new row for relation "reviews" violates check constraint "reviews_rating_check"
DETAIL:  Failing row contains (7, 2, 3, 7, null, ...).
```

### 7. Line-by-line
- `CHECK (rating BETWEEN 1 AND 5)` is evaluated per-row, per-write; `BETWEEN` is inclusive on both ends, so `1` and `5` are valid, `0` and `6` are not.
- `CHECK (end_date IS NULL OR end_date >= start_date)` is a table-level check because it references two columns (`end_date`, `start_date`) in one expression — column-level `CHECK` syntax only has access to the single column it's attached to (though in practice PostgreSQL actually lets a column-level CHECK reference other columns too; the *convention* of putting cross-column checks at the table level is about readability, not a hard engine restriction).
- The `IS NULL OR ...` guard is deliberate: without it, a project with no end date yet (`end_date = NULL`) would make the whole expression evaluate to `UNKNOWN` — which, as covered below, actually still *passes*. The explicit `IS NULL OR` here is for clarity of intent, not strictly required for correctness, precisely because of the NULL-passes rule.

### 8. Internal behavior
Unlike `UNIQUE`/`PRIMARY KEY`/`FOREIGN KEY`, a `CHECK` constraint requires **no index and no cross-row lookup** — it's a pure, row-local expression evaluated at write time against only the row being written (or, for table-level checks, potentially against multiple columns of that same row). This makes `CHECK` constraints essentially free from a performance standpoint, no matter how large the table is — a meaningful contrast to foreign keys, which do require a lookup against another table.

### 9. Common mistakes
- Writing a `CHECK` that references another table's data (e.g., `CHECK (product_id IN (SELECT product_id FROM products))`) — PostgreSQL and the SQL standard **do not allow subqueries in `CHECK` constraints**. That's what `FOREIGN KEY` is for. `CHECK` is strictly row-local.
- Forgetting that `CHECK` constraints are evaluated on `UPDATE` too, not just `INSERT` — a common surprise when a legitimate historical row (inserted before the constraint existed) suddenly blocks an unrelated `UPDATE` to a different column on that same row, because the *whole row* is re-validated.
- Assuming a `CHECK` blocks `NULL`s. It does not — see the edge case immediately below. This is the single most misunderstood `CHECK` behavior.

### 10. Edge cases

> **Important Note — CHECK and NULL: the UNKNOWN-passes rule**
> SQL's three-valued logic means any comparison involving `NULL` evaluates to `UNKNOWN`, not `FALSE`. A `CHECK` constraint only **rejects** a row when the expression evaluates to `FALSE`. `UNKNOWN` is treated as "not proven false," so the row is **allowed through**.
>
> Concretely: `banking_db.loans.interest_rate` has `CHECK (interest_rate >= 0)`. If `interest_rate` were nullable (it isn't — it's also `NOT NULL` — but suppose it were, hypothetically, just `CHECK` with no `NOT NULL`), then:
> ```sql
> INSERT INTO banking_db.loans (customer_id, loan_amount, interest_rate, start_date, term_months)
> VALUES (2, 100000, NULL, '2024-01-01', 12);
> ```
> `NULL >= 0` evaluates to `UNKNOWN`, and the `CHECK` constraint **passes** — the row is inserted with a `NULL` interest rate, which is very likely *not* what you intended when you wrote the check. This is precisely why `banking_db.loans.interest_rate` is declared `NOT NULL` **in addition to** its `CHECK` — the two constraints are doing different jobs: `NOT NULL` rules out the missing-value case, `CHECK` rules out the invalid-but-present-value case. **A `CHECK` constraint is never a substitute for `NOT NULL` — combine them when both rules apply.**

---

## 13.6 DEFAULT

### 1. Simple explanation
`DEFAULT` supplies a value automatically when an `INSERT` doesn't specify one for that column — so callers don't have to think about every column every time.

### 2. Technical explanation
`DEFAULT expression` is evaluated (for volatile expressions like `now()`, at the moment of each row's insertion; for constants, trivially) whenever a column is omitted from the `INSERT` column list, or when `DEFAULT` is explicitly written as the value. It is not itself a validation constraint — it doesn't reject anything — but it works closely with `NOT NULL` to guarantee a column is always populated without forcing every caller to supply a value.

### 3. Full syntax

```sql
CREATE TABLE payments (
    payment_id     SERIAL PRIMARY KEY,
    order_id       INT NOT NULL REFERENCES orders(order_id),
    amount         NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    status         VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','SUCCESS','FAILED','REFUNDED'))
);
```

**Adding/changing after the fact:**
```sql
ALTER TABLE ecommerce_db.orders
    ALTER COLUMN status SET DEFAULT 'PENDING';

ALTER TABLE ecommerce_db.orders
    ALTER COLUMN status DROP DEFAULT;
```

### 4. Real examples from the course databases
- `created_at TIMESTAMP NOT NULL DEFAULT now()` — appears in `company_db.departments`, `company_db.employees`, `ecommerce_db.users`, `ecommerce_db.products`, `banking_db.customers`. `now()` is re-evaluated for each row at insert time, not fixed at table-creation time.
- `employees.status ... DEFAULT 'ACTIVE'` — a newly-hired employee is active unless told otherwise.
- `orders.status ... DEFAULT 'PENDING'`, `payments.status ... DEFAULT 'PENDING'`, `accounts.status ... DEFAULT 'ACTIVE'` — sensible lifecycle starting states.
- `accounts.balance NUMERIC(14,2) NOT NULL DEFAULT 0` — a freshly opened account starts at zero if not specified.
- `employee_projects.hours_allocated INT NOT NULL DEFAULT 0` — no hours logged yet, by default.
- `salaries.currency CHAR(3) NOT NULL DEFAULT 'USD'` — most rows won't need a different currency, so it's assumed.
- `audit_log.changed_by VARCHAR(100) NOT NULL DEFAULT current_user` — a `DEFAULT` can call a context function, not just a literal.

### 5. Line-by-line
`base_salary NUMERIC(10,2) NOT NULL CHECK (base_salary > 0)` has no `DEFAULT` — deliberately, since a salary must always be explicitly specified; there's no sensible default salary. Compare this to `bonus NUMERIC(10,2) NOT NULL DEFAULT 0` in the same table — a bonus is *usually* zero, so it's safe to default, while a base salary must always be a conscious decision. This contrast is worth noticing: **not every `NOT NULL` column needs, or should have, a `DEFAULT`.**

### 6. Internal behavior
For a constant `DEFAULT` added to an *existing* table (PostgreSQL 11+), adding the column is a fast metadata-only operation — the engine doesn't have to rewrite every existing row, it just records the default value and returns it for old rows that stored no value at that position. `DEFAULT now()` or other volatile defaults, however, are computed per-row, not stored once — a distinction that matters when reasoning about performance of bulk operations.

### 7. Common mistakes
- Confusing `DEFAULT` with a `CHECK` or `NOT NULL` — a `DEFAULT` value is not itself validated against any `CHECK` constraint at the point the default is *declared*; it's validated the same way any other value would be at insert time. If `banking_db.accounts.status DEFAULT 'ACTIVE'` conflicted with its own `CHECK (status IN (...))`, you'd only find out when a row actually gets inserted, not when the `ALTER TABLE` runs.
- Relying on `DEFAULT` to fix missing application logic instead of making the value explicit where it matters. Defaults are meant for genuinely-common cases (a new order is `PENDING`), not as a silent substitute for validation.

---

## 13.7 GENERATED Columns and Auto-Increment Identity

### 1. Simple explanation
Two different but related ideas: (a) a column whose value is auto-assigned by the database as an ever-increasing counter (used for surrogate primary keys), and (b) a column whose value is *computed* from other columns in the same row and stored automatically — you never write to it directly.

### 2. Technical explanation & dialect comparison — identity/auto-increment

| Dialect | Mechanism | Notes |
|---|---|---|
| **PostgreSQL** | `SERIAL` / `BIGSERIAL` (legacy, sequence-backed) or `GENERATED ALWAYS AS IDENTITY` (SQL-standard, PostgreSQL 10+) | Every table in this course's databases uses `SERIAL`/`BIGSERIAL` for brevity, but `GENERATED ... AS IDENTITY` is the modern, standard-conformant equivalent and is generally preferred in new schemas. |
| **MySQL** | `AUTO_INCREMENT` | Declared directly on the column: `id INT AUTO_INCREMENT PRIMARY KEY`. |
| **SQL Server** | `IDENTITY(seed, increment)` | `id INT IDENTITY(1,1) PRIMARY KEY`. |
| **Oracle** | Historically: a `SEQUENCE` + a `BEFORE INSERT` trigger to populate the PK. Oracle 12c+: `GENERATED ALWAYS AS IDENTITY`, matching the SQL standard directly and eliminating the need for the trigger. |

**PostgreSQL equivalent of every `SERIAL` column in this course's schema, written the modern way:**
```sql
-- as currently written in company_db.sql:
department_id SERIAL PRIMARY KEY

-- SQL-standard equivalent (PostgreSQL 10+), functionally near-identical:
department_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY
```
`GENERATED ALWAYS AS IDENTITY` is preferred in new PostgreSQL schemas over `SERIAL` because it's SQL-standard (portable in *concept*, if not exact syntax, to SQL Server's `IDENTITY`), and it prevents accidentally inserting an explicit conflicting value unless you override with `OVERRIDING SYSTEM VALUE`. `SERIAL` is really just a convenience macro around a `sequence` + `DEFAULT nextval(...)` + `NOT NULL`, with no such protection.

**MySQL:**
```sql
CREATE TABLE departments (
    department_id INT AUTO_INCREMENT PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE
);
```

**SQL Server:**
```sql
CREATE TABLE departments (
    department_id INT IDENTITY(1,1) PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE
);
```

**Oracle (12c+):**
```sql
CREATE TABLE departments (
    department_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    department_name VARCHAR2(100) NOT NULL UNIQUE
);
```

**Oracle, pre-12c (historical pattern, shown for context — you may encounter this in legacy systems):**
```sql
CREATE SEQUENCE departments_seq START WITH 1 INCREMENT BY 1;

CREATE TABLE departments (
    department_id NUMBER PRIMARY KEY,
    department_name VARCHAR2(100) NOT NULL UNIQUE
);

CREATE OR REPLACE TRIGGER trg_departments_bi
BEFORE INSERT ON departments
FOR EACH ROW
WHEN (NEW.department_id IS NULL)
BEGIN
    SELECT departments_seq.NEXTVAL INTO :NEW.department_id FROM dual;
END;
/
```

### 3. Technical explanation & dialect comparison — computed/generated columns

A **generated/computed column** stores a value derived from an expression over other columns in the same row, recalculated automatically whenever the row changes. None of the course's three databases currently use one, so here is an illustrative addition to `ecommerce_db.order_items` — computing the line total from `quantity * unit_price`:

**[PostgreSQL 12+]**
```sql
ALTER TABLE ecommerce_db.order_items
    ADD COLUMN line_total NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED;
```
PostgreSQL only supports `STORED` generated columns (computed once, at write time, and physically stored) — it does not support "virtual"/on-read computed columns the way SQL Server does.

**[MySQL 5.7+]**
```sql
ALTER TABLE order_items
    ADD COLUMN line_total DECIMAL(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED;
-- or VIRTUAL (computed on read, not stored) instead of STORED
```

**[SQL Server]**
```sql
ALTER TABLE order_items
    ADD line_total AS (quantity * unit_price) PERSISTED;
-- omit PERSISTED for a virtual (computed-on-read) column
```

**[Oracle]** — "virtual columns":
```sql
ALTER TABLE order_items
    ADD line_total NUMBER GENERATED ALWAYS AS (quantity * unit_price) VIRTUAL;
```

### 4. Why generated/identity columns exist
Surrogate keys need to come from *somewhere* consistent and collision-free without the application coordinating who gets which number — that's what identity/auto-increment solves. Computed columns exist so that derived values (totals, full names, normalized/lower-cased search columns) are guaranteed to always be in sync with their source columns — you cannot update `quantity` and forget to update `line_total`, because you're not allowed to write to `line_total` directly at all; the database recomputes it every time.

### 5. Expected behavior when violated
```sql
INSERT INTO ecommerce_db.order_items (order_id, product_id, quantity, unit_price, line_total)
VALUES (1, 1, 2, 100.00, 999.00);
```
```
ERROR:  cannot insert a non-DEFAULT value into column "line_total"
DETAIL:  Column "line_total" is a generated column.
```
You cannot supply your own value for a `STORED GENERATED` column, ever — not even one that happens to be arithmetically correct.

### 6. Internal behavior
A `STORED` generated column occupies physical space on disk exactly like a normal column — it is recalculated and rewritten whenever any of its source columns change, as part of the same `UPDATE`. This trades a small amount of write cost and storage for guaranteed consistency and (unlike a `VIRTUAL`/computed-on-read column in MySQL/SQL Server/Oracle) the ability to index the generated column directly, since it physically exists.

### 7. Common mistakes
- Trying to reference another table's data, run a subquery, or call a non-deterministic function (like `now()` or `random()`) inside a `GENERATED ALWAYS AS (...)` expression — generated columns must be **deterministic** functions of other columns in the *same row*; PostgreSQL rejects volatile expressions here.
- Forgetting `PRIMARY KEY`/sequence ownership pitfalls after bulk-loading data with explicit IDs (e.g., the `SELECT setval(...)` calls you can see at the bottom of each `*_db.sql` seed file) — if you insert explicit primary key values without advancing the underlying sequence, the next auto-generated insert will collide with an existing row and raise the same duplicate-key error shown in §13.1.6. This is exactly why every seed file in this course calls `setval()` after inserting explicit IDs.

---

## 13.8 Constraint Enforcement Timing

Not all constraints are checked at the same moment relative to a statement or transaction. Three timing models exist:

| Timing | What it means | Typical constraints |
|---|---|---|
| **Immediately, per-row** | Checked the instant each row is written, before the statement even finishes. | `NOT NULL`, `CHECK` — always immediate; cannot be deferred in any dialect. |
| **End of statement** | Checked after all rows affected by the statement have been written, not row-by-row. | `UNIQUE`, `PRIMARY KEY`, and `NOT DEFERRABLE` foreign keys, by default. |
| **End of transaction (deferred)** | Checked only at `COMMIT`, if explicitly declared `DEFERRABLE INITIALLY DEFERRED`. | `UNIQUE`, `PRIMARY KEY`, `FOREIGN KEY` — only when explicitly made deferrable. |

The "end of statement, not end of row" nuance matters more than it looks. Consider swapping two unique values in one statement:

```sql
UPDATE company_db.departments
SET department_name = CASE department_id
    WHEN 1 THEN 'Sales'
    WHEN 2 THEN 'Engineering'
END
WHERE department_id IN (1, 2);
```

If `UNIQUE` were checked row-by-row *during* the statement, this would fail the moment the first row is renamed to a value the second row currently holds. But PostgreSQL (like the SQL standard for non-deferred constraints) checks `UNIQUE`/`PRIMARY KEY` at the **end of the statement**, after all rows in that one `UPDATE` are applied — so this swap succeeds, because by the time the check runs, both names are once again distinct.

---

## 13.9 Cascading Behavior: ON DELETE / ON UPDATE Actions

### 1. Simple explanation
When a parent row is deleted or its key changes, `ON DELETE`/`ON UPDATE` tells the database what to do to the dependent child rows: delete them too, null out the link, block the operation entirely, or (in a subtly different way) also block it.

### 2. Technical explanation — the five actions

| Action | Behavior on parent DELETE/UPDATE |
|---|---|
| `CASCADE` | Automatically delete (or update) the matching child rows too. |
| `SET NULL` | Set the child's FK column to `NULL`. Requires the FK column to be nullable. |
| `SET DEFAULT` | Set the child's FK column to its column `DEFAULT` value. Rare in practice. |
| `RESTRICT` | Block the parent operation immediately if any child row references it. **Cannot be deferred**, even inside a transaction declared with deferrable constraints elsewhere. |
| `NO ACTION` (default if omitted) | Block the parent operation if any child row references it **by the end of the statement/transaction** — but *can* be deferred to `COMMIT` if the constraint is declared `DEFERRABLE`. |

### 3. RESTRICT vs NO ACTION — the precise distinction

This is one of the most consistently misunderstood pairs in SQL, because in *ordinary, non-deferred* use they behave identically — both block the delete/update if a child row exists. The difference only becomes visible when deferrability is involved:

- `NO ACTION` performs its check at the point mandated by the constraint's deferrability mode — by default, end-of-statement, but if the constraint is declared `DEFERRABLE INITIALLY DEFERRED`, the check is postponed until `COMMIT`. This means a transaction can *temporarily* violate the constraint mid-transaction (e.g., delete the parent first, insert a new parent with the same key later in the same transaction) as long as it's resolved by the time `COMMIT` runs.
- `RESTRICT` performs its check **immediately**, and this cannot be changed — `RESTRICT` constraints are never deferrable, under any circumstances, in any dialect that supports deferrability. If you need the flexibility to defer, you must use `NO ACTION`, not `RESTRICT`.

**[PostgreSQL default]**: if you write a `FOREIGN KEY` with no `ON DELETE`/`ON UPDATE` clause at all, the implicit behavior is `NO ACTION` — not `RESTRICT`. This is why `ecommerce_db.order_items.product_id` and `banking_db.accounts.customer_id` (both declared with no `ON DELETE` clause) are technically `NO ACTION`, and *could* in principle be made deferrable later via `ALTER TABLE ... ALTER CONSTRAINT ... DEFERRABLE`, whereas an explicitly-`RESTRICT` constraint never could be.

### 4. ON UPDATE actions

`ON UPDATE CASCADE` propagates a change to the *parent's key value itself* down to every child's FK column. This matters far less with surrogate keys (a `SERIAL`/`IDENTITY` primary key, like every PK in this course's databases, is never supposed to change once assigned), but it matters a great deal if a schema instead uses a natural key as a primary key — e.g., a hypothetical `countries(country_code CHAR(2) PRIMARY KEY)` referenced by `customers.country_code`, where a country code is reassigned (rare, but it has happened historically with real ISO codes). With `ON UPDATE CASCADE`, renaming the parent's key automatically updates every child row's reference in the same transaction; without it, renaming the parent key would raise the same "still referenced" foreign key error shown in §13.2.6, this time triggered by `UPDATE` instead of `DELETE`.

```sql
-- illustrative, natural-key example (not in the course schemas):
CREATE TABLE countries (
    country_code CHAR(2) PRIMARY KEY,
    country_name VARCHAR(100) NOT NULL
);

CREATE TABLE customers_intl (
    customer_id   SERIAL PRIMARY KEY,
    country_code  CHAR(2) REFERENCES countries(country_code) ON UPDATE CASCADE ON DELETE RESTRICT
);
```

### 5. Real examples from the course databases, re-examined through this lens

| FK | Action | Why this action specifically |
|---|---|---|
| `employees.department_id → departments` | `ON DELETE SET NULL` | Losing a department shouldn't erase the employee, only their department link — the employee record is independently meaningful. |
| `employees.manager_id → employees` | `ON DELETE SET NULL` | Same logic, self-referencing: if a manager leaves and is removed, direct reports shouldn't cascade-delete — they just become temporarily unmanaged. |
| `salaries.employee_id → employees` | `ON DELETE CASCADE` | A salary history row has *no independent meaning* without its employee — this is ownership/composition, not just association. |
| `order_items.order_id → orders` | `ON DELETE CASCADE` | Same composition logic — a line item cannot exist without its order. |
| `order_items.product_id → products` | *(NO ACTION, implicit)* | Deliberately protective: allowing product deletion to cascade into historical order data would corrupt financial/order records. The correct real-world fix for "discontinuing" a product is `products.is_discontinued = TRUE`, not deletion — which is exactly why that column exists in the schema. |
| `accounts.customer_id → customers` | *(NO ACTION, implicit)* | You must not be able to delete a bank customer who still has open accounts — this should require an explicit, deliberate account-closure process first. |

### 6. Expected behavior — RESTRICT/NO ACTION vs CASCADE side by side

```sql
-- CASCADE: succeeds, deletes dependent rows too
DELETE FROM company_db.employees WHERE employee_id = 6;
-- company_db.salaries rows for employee_id=6 are silently deleted too (CASCADE)
-- company_db.employee_projects rows for employee_id=6 are silently deleted too (CASCADE)

-- NO ACTION (default): blocked
DELETE FROM banking_db.customers WHERE customer_id = 1;
```
```
ERROR:  update or delete on table "customers" violates foreign key constraint "accounts_customer_id_fkey" on table "accounts"
DETAIL:  Key (customer_id)=(1) is still referenced from table "accounts".
```

### 7. Internal behavior
Every cascading action requires the database to locate every matching child row — the same lookup-on-parent-mutation cost described in §13.2.8. `CASCADE` does the extra work of then performing the delete/update on each of those rows too, which itself may cascade further if the child is also a parent to something else (multi-level cascades). This chained cost is invisible in small seed data and can be significant in production-sized tables — another reason to index every FK column on the child side.

---

## 13.10 Deferrable Constraints

### 1. Simple explanation
Normally, a constraint has to hold true after every single statement. A **deferrable** constraint lets you say "check this only at `COMMIT` time" — so you can temporarily break the rule in the middle of a transaction, as long as it's fixed before you commit.

### 2. Why this matters — the motivating problem

Two concrete scenarios where an *immediately-checked* constraint gets in the way even though the end result is perfectly valid:

**Scenario A — mutually referencing rows.** Suppose (hypothetically extending `company_db`) `departments` had a `head_employee_id` column referencing `employees`, and `employees.department_id` referenced `departments` — each table's row needs the other to already exist. In one transaction, you cannot insert the department before the employee (employee doesn't exist yet) or the employee before the department (department doesn't exist yet), if both foreign keys are checked immediately.

**Scenario B — reordering a self-referential hierarchy.** `company_db.employees.manager_id` references `employees.employee_id`. Imagine reorganizing the management chain so that employee A (currently reporting to B) becomes B's new manager, in one transaction: you'd need to set `B.manager_id = A` and `A.manager_id = B` — but at the moment you run the first `UPDATE`, the second hasn't happened yet, so intermediate states can visit values that look fine here (since both employees already exist, this particular self-reference is actually always satisfiable — a better illustration is a strict ordering/sequence hierarchy where item N's predecessor must exist, and you're renumbering the whole chain in one pass). If any intermediate `UPDATE` in that sequence would otherwise violate a *statement-level* immediate check, a deferred constraint checked only at `COMMIT` resolves the whole batch as one atomic unit, `NO ACTION`-consistent by the end, even if temporarily inconsistent mid-transaction.

The general principle: **deferrable constraints let a multi-statement transaction pass through temporarily-invalid intermediate states, as long as the final state (at `COMMIT`) is valid.** This connects directly back to Chapter 11's ACID guarantees — the *transaction*, not each individual statement, is the real unit of consistency.

### 3. Dialect support

> **⚠️ Warning — this is not portable SQL**
> **[PostgreSQL, Oracle]**: support `DEFERRABLE` / `DEFERRABLE INITIALLY DEFERRED` on `UNIQUE`, `PRIMARY KEY`, and `FOREIGN KEY` constraints.
> **[MySQL, SQL Server]**: **do not support deferrable constraints at all.** In these dialects, every constraint is always checked immediately (or, for FKs, at end-of-statement) — there is no `DEFERRABLE` keyword. Workarounds in MySQL/SQL Server typically involve temporarily disabling constraint checking (`SET FOREIGN_KEY_CHECKS=0` in MySQL — a blunt, session-wide, easy-to-misuse escape hatch, not a scoped per-constraint deferral), restructuring the transaction to avoid the intermediate invalid state, or using nullable columns populated in a second pass.

### 4. Full syntax **[PostgreSQL]**

```sql
CREATE TABLE example_parent (
    id INT PRIMARY KEY
);

CREATE TABLE example_child (
    id        INT PRIMARY KEY,
    parent_id INT REFERENCES example_parent(id)
        DEFERRABLE INITIALLY DEFERRED
);
```

Or added/altered after the fact:
```sql
ALTER TABLE example_child
    ALTER CONSTRAINT example_child_parent_id_fkey DEFERRABLE INITIALLY DEFERRED;
```

Constraint modes:
- `NOT DEFERRABLE` (default) — always checked at its normal timing point, no exceptions.
- `DEFERRABLE INITIALLY IMMEDIATE` — checked at end-of-statement by default, but *can* be deferred per-transaction with `SET CONSTRAINTS ... DEFERRED`.
- `DEFERRABLE INITIALLY DEFERRED` — always deferred to `COMMIT` unless overridden with `SET CONSTRAINTS ... IMMEDIATE`.

Within a transaction, you can also toggle a `DEFERRABLE` (but not `INITIALLY DEFERRED`-only) constraint's timing explicitly:
```sql
BEGIN;
SET CONSTRAINTS example_child_parent_id_fkey DEFERRED;
-- ... temporarily-inconsistent statements here ...
COMMIT;  -- constraint is checked here
```

### 5. Worked example — self-referential reordering, deferred

```sql
BEGIN;

SET CONSTRAINTS ALL DEFERRED;

UPDATE company_db.employees SET manager_id = 16 WHERE employee_id = 2;  -- Rahul now reports to Aman
UPDATE company_db.employees SET manager_id = 2  WHERE employee_id = 16; -- Aman now reports to Rahul... temporarily circular mid-transaction

-- resolve to a valid final state before committing:
UPDATE company_db.employees SET manager_id = 1 WHERE employee_id = 16; -- Aman reports to the CTO instead

COMMIT;  -- all FK checks run now; final state is valid
```
> **Note:** `company_db.employees.manager_id` in the actual schema is declared plainly (`INT REFERENCES employees(employee_id) ON DELETE SET NULL`) with **no** `DEFERRABLE` clause, so this exact `SET CONSTRAINTS ALL DEFERRED` example would have no deferring effect on it as currently written — it's shown here to illustrate the *mechanism*; to actually defer this specific FK, it would first need `ALTER TABLE employees ALTER CONSTRAINT employees_manager_id_fkey DEFERRABLE INITIALLY DEFERRED`.

### 6. Expected behavior when violated at COMMIT

```sql
BEGIN;
SET CONSTRAINTS ALL DEFERRED;
DELETE FROM example_parent WHERE id = 1;  -- child still points to it — allowed for now
COMMIT;
```
```
ERROR:  update or delete on table "example_parent" violates foreign key constraint "example_child_parent_id_fkey" on table "example_child"
DETAIL:  Key (id)=(1) is still referenced from table "example_child".
```
Notice the check still fires — it was only *postponed*, not skipped. If the transaction never fixes the dangling reference before `COMMIT`, PostgreSQL raises the exact same error as an immediate check would, just later, and the entire transaction rolls back.

---

## 13.11 When to Enforce at the Database Level vs Application Level

**The database should be the source of truth. Application-level validation is a UX layer, not a substitute.**

Concretely:
- **Database-level constraints** are the only thing that holds true regardless of *what* wrote the data — your web app, a background job, a data migration script, an analyst running an ad-hoc `UPDATE` in `psql`, or a bug in any of the above. If `banking_db.accounts.balance >= 0` is only checked in application code, a single bypassed code path (a retry bug, a bulk correction script, a direct database session during an incident) can put the account negative, and nothing will ever flag it again — the bad data is now indistinguishable from good data.
- **Application-level validation** exists for a different, legitimate reason: **fast feedback**. Telling a user "rating must be between 1 and 5" the instant they type `7` into a form, before a network round trip, is good UX. But that same rule should *also* exist as a `CHECK` constraint, because the application is not the only writer, and application code changes far more often (and far less carefully, in an emergency) than a production schema should.

> **Important Note**
> Treat the relationship as layered, not either/or: application validation for immediate user feedback → API-layer validation for structured error responses → database constraints as the final, non-negotiable guarantee. If those three layers ever disagree, the database's answer is the one that's actually true about what's stored.

---

## 13.12 Comparisons

### CHECK vs application validation vs trigger-based validation

| Approach | Enforced for every writer? | Can express cross-row/cross-table rules? | Performance | When to use |
|---|---|---|---|---|
| `CHECK` constraint | Yes, always | No — row-local only, no subqueries | Free (no index/lookup) | Any rule expressible purely from the row's own columns (ranges, enumerations, cross-column comparisons like `end_date >= start_date`). |
| Application validation | No — only for writes that go through that code path | Yes, arbitrarily complex | N/A (happens before the DB is even touched) | Fast user feedback; never the *only* line of defense. |
| Trigger-based validation | Yes, always (if attached correctly) | Yes — can query other tables, aggregate, compare against history | Slower — procedural code runs per row/statement | Rules `CHECK` cannot express: "the sum of all line items must equal the order total," "an account cannot process a withdrawal that would exceed available credit considering pending transactions." Chapter 22 (Triggers) covers this in depth — think of triggers as what you reach for only once `CHECK` genuinely cannot express the rule. |

### RESTRICT vs NO ACTION vs CASCADE vs SET NULL

| Action | Parent delete/update with dependent children | Deferrable? | Best for |
|---|---|---|---|
| `CASCADE` | Child rows deleted/updated automatically | Yes (PostgreSQL/Oracle) | True ownership/composition (`salaries` → `employees`, `order_items` → `orders`). |
| `SET NULL` | Child FK column set to `NULL` | Yes | Optional/loose association where the child survives independently (`employees.department_id`, `employees.manager_id`). |
| `NO ACTION` | Blocked, checked at statement end (or deferred to commit if declared deferrable) | Yes | The default, safest choice when you're not sure — protects data by default while still allowing deferred multi-statement transactions later if needed. |
| `RESTRICT` | Blocked, checked immediately, always | **No, never** | When you want to guarantee, with zero exceptions, that this check can never be postponed even inside a transaction using deferred constraints elsewhere. |

---

## 13.13 Real-World Use Cases

- **Financial integrity** — `banking_db.accounts.balance >= 0` is the last line of defense against an application bug that could otherwise let an account go negative; combined with row-level locking (Chapter 12) and transactions (Chapter 11), this is how banks actually guarantee books balance.
- **Preventing orphaned records** — `ecommerce_db.order_items.order_id → orders ON DELETE CASCADE` ensures you never end up with billing line items with no parent order, which would otherwise corrupt financial reporting.
- **Enumeration integrity without a separate lookup table** — `status IN (...)` checks on `employees`, `orders`, `payments`, `accounts`, `loans`, `audit_log.operation` keep state machines honest without the overhead of a full reference table (a trade-off explored further in Chapter 14).
- **One-per-relationship enforcement** — `reviews UNIQUE (product_id, user_id)` is exactly how real e-commerce platforms prevent review spam/duplicate reviews at the schema level, not just in the UI.
- **Preserving historical/audit data** — deliberately *not* cascading `order_items.product_id` or `accounts.customer_id` protects the historical record even when the "current" parent entity is removed or would otherwise be removable.
- **Safe multi-row reorganizations** — deferrable constraints are the standard mechanism behind bulk reordering operations (re-sequencing a priority/rank column with a `UNIQUE` constraint, re-parenting a hierarchy) that must pass through an intermediate, temporarily-duplicate or temporarily-dangling state within a single transaction.

---

## 13.14 Practice Questions

1. Explain why `company_db.employee_projects` needs a *composite* primary key rather than a single-column surrogate key, and what would break if you used a single auto-incrementing `id` as the only key instead (in terms of what invalid data it would then allow).
2. `ecommerce_db.inventory` has `UNIQUE (product_id, warehouse_location)`. Write the `INSERT` that would violate this constraint using existing seed data, and state the exact error PostgreSQL would raise.
3. Why does `company_db.employees.department_id` use `ON DELETE SET NULL` while `company_db.salaries.employee_id` uses `ON DELETE CASCADE`? Argue the business reasoning for each choice specifically, not just what the SQL keyword does.
4. `ecommerce_db.order_items.product_id` has no `ON DELETE` clause. What is its actual behavior, what is that behavior officially called, and why is it deliberately *not* `CASCADE`?
5. Precisely explain the difference between `RESTRICT` and `NO ACTION` in a database that supports deferrable constraints. Under what circumstance do they behave differently, and under what circumstance are they indistinguishable?
6. A colleague adds `CHECK (discount_percent > 0)` to a nullable `discount_percent` column, expecting it to reject rows where `discount_percent` is missing. Explain, using three-valued logic, why this will not do what they expect, and what additional constraint they need.
7. Can a `UNIQUE` column hold more than one `NULL`? Does the answer differ across PostgreSQL, MySQL, and SQL Server? Justify your answer from the definition of equality involving `NULL`.
8. You need to reorder a `display_order` column that has a `UNIQUE` constraint on it, swapping the order of several rows in one `UPDATE ... FROM (VALUES ...)` statement. Explain what timing behavior of `UNIQUE` (statement-end vs row-by-row) makes this possible even without declaring the constraint `DEFERRABLE`.
9. Why is a foreign key's *child* column not automatically indexed just because the constraint exists? Walk through, step by step, what PostgreSQL has to do to enforce `ON DELETE CASCADE` on a child table with no index on the FK column, for a parent table with 10 million child rows.
10. Give a concrete example (not in this chapter) of a business rule that a `CHECK` constraint *cannot* express, but a trigger could — and explain specifically why `CHECK`'s restriction to row-local, subquery-free expressions rules it out.

---

## 13.15 Chapter Challenge — Design the `coupons` Table

**Task:** Design a full `CREATE TABLE` statement for a new `ecommerce_db.coupons` table, supporting both storewide and product-specific discount coupons, and justify every constraint you choose.

**Requirements to satisfy:**
- Each coupon has a unique `code` customers type at checkout.
- A discount percentage between 0 and 100 (exclusive of 0, since a 0%-off coupon is meaningless; inclusive of 100 as a valid edge case for a "free" promotion).
- A validity window (`valid_from`, `valid_until`) where the end can never be before the start.
- Optionally tied to one specific product (for product-specific promotions) — `NULL` means storewide.
- Referential integrity to `products`, without allowing a coupon to silently disappear if the product is deleted (financial/promotional history should be preserved, echoing the `order_items.product_id` design decision already in the schema).

**Reference solution:**

```sql
CREATE TABLE ecommerce_db.coupons (
    coupon_id        SERIAL PRIMARY KEY,
    code             VARCHAR(30) NOT NULL UNIQUE,
    discount_percent NUMERIC(5,2) NOT NULL
                        CHECK (discount_percent > 0 AND discount_percent <= 100),
    product_id       INT REFERENCES ecommerce_db.products(product_id),
    valid_from       DATE NOT NULL,
    valid_until      DATE NOT NULL,
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMP NOT NULL DEFAULT now(),
    CHECK (valid_until >= valid_from)
);
```

**Justification, constraint by constraint:**

- **`coupon_id SERIAL PRIMARY KEY`** — a surrogate key, consistent with every other table in `ecommerce_db`. `code` is business-unique but not chosen as the PK for the same reason `products.sku` isn't the PK: coupon codes could theoretically be reissued/renamed by a marketing team, and every other table should reference the permanent `coupon_id`, not a value that might change.
- **`code VARCHAR(30) NOT NULL UNIQUE`** — mirrors `products.sku`'s pattern exactly: `NOT NULL` because a coupon without a code cannot be redeemed at all, `UNIQUE` because two coupons sharing a code would make checkout ambiguous about which discount applies.
- **`discount_percent NUMERIC(5,2) NOT NULL CHECK (discount_percent > 0 AND discount_percent <= 100)`** — `NOT NULL` because, per §13.5.10's lesson, a `CHECK` alone would let a missing discount slip through as `UNKNOWN`-passes; the range itself mirrors the bounded-range pattern already used in `reviews.rating BETWEEN 1 AND 5`, except intentionally exclusive at zero (open lower bound) since a coupon offering nothing isn't a coupon.
- **`product_id INT REFERENCES products(product_id)`** (nullable, no `ON DELETE` clause → implicit `NO ACTION`) — nullable because a storewide coupon has no single associated product, which is a legitimate business meaning for `NULL` here (not a missing value, but "applies to everything"), following the same nullable-FK pattern as `employees.department_id`. The **deliberate absence** of `ON DELETE CASCADE` follows the exact reasoning already established for `order_items.product_id`: a coupon tied to a discontinued/removed product is still meaningful historical/reporting data (e.g., "how many times was the LAUNCH20 coupon redeemed before we discontinued that product") and must not silently vanish when the product row is deleted. If product deletion needs to be supported at all, the correct pattern — again mirroring the existing schema's `products.is_discontinued` flag — would be to *retire* the product rather than delete it.
- **`valid_from DATE NOT NULL`, `valid_until DATE NOT NULL`** — both mandatory; an open-ended "valid forever" coupon should be modeled with an explicit, deliberately far-future `valid_until`, not `NULL`, so that every query comparing "is this coupon currently valid" can rely on both bounds always being present — avoiding exactly the `CHECK`-and-NULL trap from §13.5.10 if the validity check were later written as `CHECK (valid_until >= valid_from)` with a nullable column.
- **`CHECK (valid_until >= valid_from)`** — a table-level, cross-column check, directly modeled on `company_db.projects`' `CHECK (end_date IS NULL OR end_date >= start_date)`. Here there's no `IS NULL OR` guard needed, precisely because both columns are already `NOT NULL` — another illustration of how `NOT NULL` and `CHECK` are designed to work together, not redundantly.
- **`is_active BOOLEAN NOT NULL DEFAULT TRUE`** — allows a coupon to be manually disabled early (e.g., abused/leaked promo code) without deleting its row, which — again — preserves redemption history. Defaults to `TRUE` because a newly-created coupon is normally usable immediately, mirroring `products.is_discontinued NOT NULL DEFAULT FALSE`'s same "assume the common case" pattern.
- **`created_at TIMESTAMP NOT NULL DEFAULT now()`** — for audit/reporting, consistent with every other table in the three schemas that tracks row creation time.

**Extension exercise:** add a `max_redemptions INT CHECK (max_redemptions > 0)` (nullable = unlimited) and a `times_redeemed INT NOT NULL DEFAULT 0 CHECK (times_redeemed >= 0)` column, then explain in one paragraph why enforcing `times_redeemed <= max_redemptions` is **not** expressible as a `CHECK` constraint on this table alone (hint: it depends on counting redemption events recorded elsewhere — revisit this in Chapter 22, Triggers).

---

## Key Takeaways

- Constraints are the database enforcing your business rules at the point of writing, for *every* writer — application code, scripts, migrations, humans — not just the ones you remember to validate in code.
- `PRIMARY KEY` = `UNIQUE` + `NOT NULL`, plus "at most one per table"; composite primary keys (`employee_projects(employee_id, project_id)`) model many-to-many bridge tables correctly.
- `FOREIGN KEY` guarantees referential integrity and requires a matching `UNIQUE`/`PRIMARY KEY` on the parent; `NULL` in a nullable FK column is exempt from the check entirely.
- `UNIQUE` and `PRIMARY KEY` are both backed by an index internally — free performance, but a cost on every write, and the reason multi-column uniqueness (`inventory(product_id, warehouse_location)`) treats the *combination* as the unit.
- `NOT NULL` is the cheapest, most row-local constraint; `CHECK` is nearly as cheap but far more expressive — and critically, a `CHECK` alone does **not** reject `NULL`, because `UNKNOWN` passes.
- `DEFAULT` supplies a value when the caller omits one; it is not a validation mechanism and does not interact with `CHECK` until the row is actually written.
- Auto-increment surrogate keys (`SERIAL`/`IDENTITY`/`AUTO_INCREMENT`) and `GENERATED ALWAYS AS (...) STORED` computed columns solve two different problems — key assignment vs. derived-value consistency — and every major dialect names them differently.
- `RESTRICT` is always checked immediately and can never be deferred; `NO ACTION` behaves the same by default but *can* be deferred to `COMMIT` if declared `DEFERRABLE` — a distinction invisible until you actually need deferrability.
- `DEFERRABLE INITIALLY DEFERRED` (PostgreSQL/Oracle only — not MySQL/SQL Server) lets a transaction pass through temporarily-invalid intermediate states as long as the final state at `COMMIT` is valid.
- An unindexed foreign key child column is one of the most common, most expensive production mistakes; `ON DELETE CASCADE` used too liberally is one of the most common, most dangerous ones.
- Database-level constraints are the source of truth; application validation is a fast-feedback layer on top, never a replacement.

## What's Next

Chapter 13 covered the rules that keep individual tables honest, row by row. [Chapter 14 — Database Design & Normalization](14-database-design-normalization.md) zooms out: how to decide what tables should even exist in the first place, how to eliminate redundancy and update anomalies through normal forms, and when — deliberately — to break those rules through denormalization for performance. Constraints are what you enforce *once you've designed the schema correctly*; Chapter 14 is how you get to a correct schema in the first place.
