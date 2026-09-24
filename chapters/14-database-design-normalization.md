# Chapter 14 — Database Design & Normalization

> Part IV — Advanced SQL & Database Engineering
> Previous: [Chapter 13 — Constraints](13-constraints.md) · Next: [Chapter 15 — Views & Materialized Views](15-views.md)

## 14.0 Learning Objectives

By the end of this chapter you will be able to:

- Define **entity**, **attribute**, and **relationship**, and draw an ER diagram by hand (ASCII, on a whiteboard, or in a real modeling tool).
- Read and write **cardinality** (1:1, 1:N, N:M) and **optionality** (mandatory/optional) notation.
- Explain the three classic **anomalies** — insertion, update, deletion — and recognize them in a real table.
- Define **functional dependency**, **partial dependency**, and **transitive dependency**, with correct arrow notation.
- Take a badly designed flat table all the way from unnormalized to **1NF → 2NF → 3NF → BCNF → 4NF → 5NF**, explaining exactly what breaks at each stage and how the fix works.
- Explain precisely how **BCNF differs from 3NF** (and why the difference rarely matters, until it does).
- Decide, with a defensible framework, **when to normalize and when to deliberately denormalize** — including the OLTP-vs-OLAP distinction that underlies almost every real schema decision.
- Design a normalized schema from a bad flat table on your own, as the chapter-ending challenge requires.

> **Where this fits in the book:** Chapter 13 gave you the tools to *enforce* correctness (`PRIMARY KEY`, `FOREIGN KEY`, `CHECK`, `UNIQUE`, `NOT NULL`). This chapter answers the question those tools assume you've already solved: **which tables should exist, and which columns belong in which table?** Get this chapter wrong and Chapter 13's constraints are just neatly enforcing a bad shape. Get it right, and Chapters 16-18 (indexes, the planner, performance) become about *speeding up* a correct design rather than working around a broken one.

---

## 14.1 Entities, Attributes, and Relationships

### 14.1.1 Entity

**Simple explanation:** An entity is a "thing" your database needs to remember — a noun. A customer, a product, an order, an employee, a department.

**Technical definition:** An entity is a distinguishable real-world or conceptual object that has an independent existence and is represented in the database as a table (in the relational model, an entity type becomes a table; each row is an entity *instance*).

**Why it exists:** Before you write a single `CREATE TABLE`, you have to decide what the "nouns" of your system are. Skipping this step is how you end up with a single 40-column spreadsheet-shaped table instead of a database — which is exactly the mistake this chapter spends most of its time undoing.

**Examples, simple → complex:**

| Domain | Entities |
|---|---|
| Bookstore | `Book`, `Author`, `Customer`, `Order` |
| E-commerce (this course's `ecommerce_db`) | `User`, `Product`, `Order`, `Payment`, `Review` |
| Banking (`banking_db`) | `Customer`, `Account`, `Transaction`, `Loan` |
| HR (`company_db`) | `Employee`, `Department`, `Project`, `Salary`, `Attendance` |

### 14.1.2 Attribute

**Simple explanation:** An attribute is a property of an entity — a column.

**Technical definition:** Attributes are categorized as:

- **Simple (atomic):** cannot be meaningfully subdivided — `email`, `order_date`.
- **Composite:** can be broken into sub-parts — `address` → `street`, `city`, `zip`. (Whether you model it as one column or several is a real design decision, revisited under 1NF.)
- **Derived:** computable from other attributes — `age` derived from `date_of_birth`; `order_total` derived from line items. Storing a derived attribute is a *denormalization* decision (§14.12).
- **Multi-valued:** an entity can have more than one value for the attribute — a person can have several `phone_numbers`. A multi-valued attribute must **not** be stored as repeating columns (`phone1`, `phone2`) — that is the canonical 1NF violation, and it's the very first thing we fix in the worked example.

**Why it matters:** The 1NF/4NF sections of this chapter are, at their core, about correctly handling composite, derived, and multi-valued attributes instead of flattening them into a wide table.

### 14.1.3 Relationship

**Simple explanation:** A relationship is how two entities are connected — a verb. A `Customer` *places* an `Order`. An `Employee` *works in* a `Department`.

**Technical definition:** A relationship is an association between entity instances, characterized by:
- **Cardinality** — how many instances of one entity relate to how many of the other (§14.4).
- **Optionality** — whether participation in the relationship is required (mandatory) or not (optional) (§14.5).

---

## 14.2 ER Diagrams (ASCII Notation)

Since this book is plain text, every ER diagram in this chapter is drawn with boxes and lines. Here is the notation used consistently from here on:

```
Legend
------
┌──────────────┐
│  ENTITY_NAME │   A box = one entity (one table)
├──────────────┤
│ PK  col_name │   PK = primary key column
│ FK  col_name │   FK = foreign key column (references another entity)
│ UK  col_name │   UK = unique key (candidate key, not chosen as PK)
│     col_name │   ordinary attribute
└──────────────┘

  A ───────< B        "one A, many B"        (crow's foot "<" = the MANY side)
  A ───────── B       "one A, one B"          (1:1)
  A >───────< B       "many A, many B"        (N:M — normally resolved via a junction table)

  Each end of a line is annotated with two things, written as  cardinality / optionality:
    1  / mandatory   → "exactly one, required"
    1  / optional    → "zero or one"
    N  / mandatory   → "one or more"
    N  / optional    → "zero or more"
```

A minimal example — `CUSTOMER` places `ORDER`:

```
┌────────────────────┐                                   ┌────────────────────┐
│      CUSTOMER      │                                   │        ORDER       │
├────────────────────┤     1            places       N   ├────────────────────┤
│ PK customer_id     │───────────────────────────────────<│ PK order_id        │
│    customer_name   │  (mandatory)          (mandatory)  │ FK customer_id     │
│    email           │                                    │    order_date      │
│    phone           │                                    │    status          │
└────────────────────┘                                    └────────────────────┘
```

Read the two ends separately:
- **Customer side: `1 / mandatory`** — every order belongs to exactly one customer, always. (This is the multiplicity of the *other* entity as seen when you stand on the ORDER row and ask "how many customers does this order have?" — exactly one, and it can't be missing.)
- **Order side: `N / mandatory`** in this specific business rule *if* the company requires "no customer record without at least one order" (e.g., customers are created only at checkout); more commonly it's **`N / optional`** — a customer may exist with zero orders (e.g., someone who registered but never bought anything). We'll be explicit about which one applies in every diagram in this chapter.

> **⚠️ Warning:** ER diagram notation is not perfectly standardized across textbooks and tools (Chen notation, Crow's Foot, UML class diagrams, IDEF1X all differ visually). What matters is not memorizing one vendor's icon set — it's being able to answer, for *every* relationship in your schema: **(1) what is the cardinality, and (2) is each side mandatory or optional?** Those two questions drive your foreign key design, your `NOT NULL` choices, and your `CHECK`/trigger-level business rules.

---

## 14.3 Cardinality — 1:1, 1:N, N:M

**Simple explanation:** Cardinality answers "how many of the other thing can one of these have?"

**Technical definition:** Cardinality constrains the number of entity instances on each side of a relationship. The relational model expresses cardinality entirely through **keys and foreign keys** — there is no separate "cardinality" SQL clause; cardinality is *implemented* by where you place a `UNIQUE` constraint and where you place a foreign key.

### 14.3.1 One-to-One (1:1)

**Example:** `EMPLOYEE` — `EMPLOYEE_BADGE` (each employee has exactly one active badge; each badge belongs to exactly one employee).

```
┌────────────────────┐                                   ┌────────────────────┐
│      EMPLOYEE       │                                   │   EMPLOYEE_BADGE    │
├────────────────────┤     1                          1   ├────────────────────┤
│ PK employee_id      │───────────────────────────────────│ PK badge_id         │
│    full_name        │  has              (optional)      │ FK employee_id (UK) │
│    hire_date        │  (mandatory)                       │    issued_date      │
└────────────────────┘                                   └────────────────────┘
```

**Implementation rule:** put the foreign key on the side that is optional/dependent, and mark it `UNIQUE` — a `UNIQUE` foreign key is precisely what turns a 1:N relationship into a 1:1 relationship at the SQL level.

```sql
-- [PostgreSQL]
CREATE TABLE employee (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    hire_date    DATE NOT NULL
);

CREATE TABLE employee_badge (
    badge_id     SERIAL PRIMARY KEY,
    employee_id  INT NOT NULL UNIQUE REFERENCES employee(employee_id),  -- UNIQUE = 1:1
    issued_date  DATE NOT NULL
);
```

**When 1:1 shows up in real schemas:** splitting a rarely-used or sensitive set of columns off a wide table (e.g., `employee_payroll_details` split from `employee` for access-control reasons), or subtype tables (see §14.15 edge cases).

### 14.3.2 One-to-Many (1:N) — the most common relationship

**Example:** `DEPARTMENT` — `EMPLOYEE` (one department has many employees; each employee belongs to one department).

```
┌────────────────────┐                                   ┌────────────────────┐
│     DEPARTMENT      │                                   │      EMPLOYEE       │
├────────────────────┤     1          employs         N   ├────────────────────┤
│ PK department_id    │───────────────────────────────────<│ PK employee_id      │
│    department_name  │  (mandatory)      (optional)       │ FK department_id    │
└────────────────────┘                                   │    full_name         │
                                                            └────────────────────┘
```

**Implementation rule:** the foreign key always lives on the **"many"** side.

```sql
-- [PostgreSQL]
CREATE TABLE department (
    department_id   SERIAL PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE employee (
    employee_id    SERIAL PRIMARY KEY,
    department_id  INT REFERENCES department(department_id),  -- no UNIQUE = many employees per dept
    full_name      VARCHAR(100) NOT NULL
);
```

### 14.3.3 Many-to-Many (N:M)

**Example:** `STUDENT` — `COURSE` (a student takes many courses; a course has many students).

```
┌────────────────────┐                                                    ┌────────────────────┐
│       STUDENT        │                                                    │       COURSE         │
├────────────────────┤     N                                          M   ├────────────────────┤
│ PK student_id        │>───────────────────────────────────────────────<│ PK course_id          │
│    student_name      │  enrolls_in      (via junction table)             │    course_title       │
└────────────────────┘                                                    └────────────────────┘
                          │
                          │  resolved as
                          ▼
              ┌──────────────────────────┐
              │        ENROLLMENT         │   <- junction / associative / bridge table
              ├──────────────────────────┤
              │ PK,FK student_id          │
              │ PK,FK course_id           │
              │    enrollment_date         │
              │    grade                   │
              └──────────────────────────┘
```

**Technical definition:** the relational model has no native way to represent N:M directly with a single foreign key (a foreign key column can only point to *one* row). N:M relationships are always resolved into **two 1:N relationships** via a **junction table** (also called associative/bridge/link table) whose primary key is usually the composite of both foreign keys.

```sql
-- [PostgreSQL]
CREATE TABLE student (
    student_id   SERIAL PRIMARY KEY,
    student_name VARCHAR(100) NOT NULL
);

CREATE TABLE course (
    course_id    SERIAL PRIMARY KEY,
    course_title VARCHAR(100) NOT NULL
);

CREATE TABLE enrollment (                    -- junction table
    student_id      INT NOT NULL REFERENCES student(student_id),
    course_id       INT NOT NULL REFERENCES course(course_id),
    enrollment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    grade           CHAR(2),
    PRIMARY KEY (student_id, course_id)      -- composite key: one enrollment per student per course
);
```

> **Important Note:** Every N:M relationship you *fail* to resolve into a junction table becomes a repeating-group problem — which is precisely the 1NF violation at the heart of §14.7's worked example (`product1`, `product2` columns are an attempt to fake a 1:N/N:M relationship using repeated columns instead of rows).

---

## 14.4 Optionality — Mandatory vs. Optional Participation

**Simple explanation:** Optionality asks: "does every row on this side *have to* participate in the relationship, or can it exist alone?"

**Technical definition:** A participation is **mandatory** (also called *total participation*) if every instance of the entity must be related to at least one instance of the other entity. It is **optional** (*partial participation*) if some instances may exist without any relationship.

**Why it matters:** Optionality is what decides whether a foreign key column is `NOT NULL` or nullable, and whether a relationship needs `ON DELETE CASCADE`/`RESTRICT`/`SET NULL` semantics (Chapter 13).

| Relationship | Side | Cardinality | Optionality | SQL consequence |
|---|---|---|---|---|
| Employee → Department | Employee | N | mandatory | `employee.department_id NOT NULL` |
| Employee → Department | Department | 1 | optional | a department can exist with 0 employees; no constraint needed on `department` |
| Order → Customer | Order | N | mandatory | `order.customer_id NOT NULL` |
| Customer → Order | Customer | 1 | optional | a customer can exist with 0 orders |
| Loan → Account (banking_db) | Loan | N | mandatory | every loan must reference a valid account |
| Employee → Badge | Employee | 1 | optional | not every employee has been issued a badge yet |

```
Mandatory participation (both sides required) is drawn with two hash marks or the word (mandatory):

┌────────────┐    1                          N    ┌────────────┐
│   ORDER    │────||──────────────────────||──────<│ ORDER_ITEM │
└────────────┘  (mandatory)          (mandatory)   └────────────┘
   An order must have >= 1 item; an order_item cannot exist without its order.

Optional participation is drawn with a small circle or the word (optional):

┌────────────┐    1                          N    ┌────────────┐
│  CUSTOMER  │────○───────────────────────────────<│   ORDER    │
└────────────┘  (optional)            (mandatory)  └────────────┘
   A customer may have 0 orders; every order must have exactly 1 customer.
```

---

## 14.5 The Three Anomalies — What Normalization Actually Prevents

Before touching 1NF/2NF/3NF definitions, you need to be able to *recognize* the three problems normalization exists to solve. Every normal form in this chapter is defined in terms of preventing one or more of these.

### 14.5.1 Insertion Anomaly

**Simple explanation:** You *cannot* record a valid, known fact because some *other*, unrelated fact isn't available yet.

**Technical definition:** An insertion anomaly occurs when the current table design forces you to either (a) supply data you don't have (or synthetic/NULL placeholders) in order to insert a fact you *do* have, or (b) makes it impossible to represent a valid fact at all because it depends on a row that doesn't exist yet.

**Example:** In a table `order_line(order_id, salesperson_name, salesperson_dept)`, you cannot record that a newly hired salesperson belongs to the "Support" department until that salesperson has made their first sale — because salesperson data only exists as a byproduct of an order row.

### 14.5.2 Update Anomaly

**Simple explanation:** The same fact is stored in more than one place, so updating it requires finding and changing *every* copy — and if you miss one, the database now contradicts itself.

**Technical definition:** An update anomaly occurs when a single logical fact is represented redundantly across multiple rows, such that a change to that fact requires multiple `UPDATE` statements (or a multi-row `UPDATE` with a `WHERE` clause that must match every redundant copy) to keep the database consistent.

**Example:** If `salesperson_dept` is repeated on every order row for that salesperson, renaming their department means updating N rows. Update only some of them, and the same salesperson now appears to work in two departments simultaneously.

### 14.5.3 Deletion Anomaly

**Simple explanation:** Deleting one fact accidentally erases a *different*, still-valid fact as an unwanted side effect.

**Technical definition:** A deletion anomaly occurs when deleting a row representing one entity (e.g., an order) causes the unintentional loss of information about a *different* entity (e.g., a customer or salesperson) that no other row preserves.

**Example:** If a salesperson's only order gets cancelled and deleted, and their department/office is only stored on order rows, deleting that one order erases all record that the salesperson exists, or which department they belong to.

> **Important Note:** All three anomalies share a single root cause: **a single table is being asked to represent more than one independent fact/entity at once.** Normalization is the systematic process of identifying which facts are actually about different entities and splitting them into separate tables, one entity per table, connected by foreign keys.

---

## 14.6 Functional Dependencies — the Formal Vocabulary

Every normal form from 2NF onward is defined precisely using **functional dependencies (FDs)**. Learn this vocabulary once, and every "why is this in violation" question becomes mechanical.

| Term | Definition |
|---|---|
| **Functional dependency `X → Y`** | For any two rows that have the same value of `X`, they must have the same value of `Y`. `X` is called the **determinant**. Read as "`X` determines `Y`." |
| **Candidate key** | A minimal set of attributes that uniquely identifies each row (uniqueness + no smaller subset also works). A table can have more than one candidate key. |
| **Primary key (PK)** | The candidate key chosen (by the designer) as the table's main identifier. |
| **Superkey** | *Any* set of attributes that uniquely identifies a row — not necessarily minimal. Every candidate key is a superkey; not every superkey is a candidate key. |
| **Prime attribute** | An attribute that is part of *at least one* candidate key. |
| **Non-prime attribute** | An attribute that is not part of *any* candidate key. |
| **Full functional dependency** | `Y` is fully dependent on composite key `K` if `Y` depends on the *entire* `K`, not on any proper subset of it. |
| **Partial dependency** | `Y` depends on only *part* of a composite candidate key (a proper subset). This is what 2NF outlaws. |
| **Transitive dependency** | `X → Y` and `Y → Z`, where `X` is the key, `Y` is a non-prime attribute, so `Z` depends on `X` only *through* `Y`, not directly. This is what 3NF outlaws. |

**Simple examples of FD notation:**

```
employee_id → employee_name, department_id      -- employee_id determines both
department_id → department_name                  -- department_id determines department_name
{order_id, product_id} → quantity                -- composite determinant
zip_code → city, state                           -- classic transitive-dependency trigger
```

> **Important Note:** A functional dependency is a *business rule*, not something SQL derives automatically. You (the designer) declare `zip_code → city` to be true because in your business domain a ZIP code always maps to exactly one city/state. SQL then only *enforces* it via constraints/foreign keys once you've modeled it as a separate table — SQL cannot discover the dependency for you.

---

## 14.7 The Worked Example: One Flat Table → 1NF → 2NF → 3NF → BCNF → 4NF → 5NF

This is the spine of the chapter. We start with a genuinely bad, denormalized table for a small fictional store, show the real anomalies it produces with real data, and progressively fix it one normal form at a time.

### 14.7.1 The Bad Table

```sql
-- [PostgreSQL] — DELIBERATELY BAD DESIGN. Do not copy this. This is the "before" picture.
CREATE TABLE messy_orders (
    order_id            INT,
    order_date          DATE,
    customer_name       VARCHAR(100),
    customer_email      VARCHAR(100),
    customer_phone      VARCHAR(20),
    product1_name       VARCHAR(100),
    product1_price      NUMERIC(10,2),
    product1_qty        INT,
    product2_name       VARCHAR(100),
    product2_price      NUMERIC(10,2),
    product2_qty        INT,
    salesperson_name    VARCHAR(100),
    salesperson_dept    VARCHAR(50),
    salesperson_office  VARCHAR(20)
);
```

Sample data:

| order_id | order_date | customer_name | customer_email | customer_phone | product1_name | product1_price | product1_qty | product2_name | product2_price | product2_qty | salesperson_name | salesperson_dept | salesperson_office |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1001 | 2024-01-05 | Asha Verma | asha@mail.com | 555-0101 | Wireless Mouse | 25.00 | 2 | USB-C Cable | 9.00 | 1 | Raj Malhotra | Electronics | Office-3 |
| 1002 | 2024-01-06 | Ben Carter | ben@mail.com | 555-0202 | Office Chair | 150.00 | 1 | NULL | NULL | NULL | Raj Malhotra | Electronics | Office-3 |
| 1003 | 2024-01-06 | Asha Verma | asha@mail.com | 555-0101 | Desk Lamp | 40.00 | 1 | Notebook | 5.00 | 3 | Priya Nair | Home Goods | Office-1 |
| 1004 | 2024-01-07 | Chidi Okafor | chidi@mail.com | 555-0303 | Wireless Mouse | 25.00 | 1 | NULL | NULL | NULL | Priya Nair | Home Goods | Office-1 |
| 1005 | 2024-01-08 | Ben Carter | ben@mail.com | 555-0202 | Monitor Stand | 35.00 | 2 | Keyboard | 60.00 | 1 | Raj Malhotra | Electronics | Office-3 |

At a glance this "works" — you can run `SELECT * FROM messy_orders` and get a report. That's exactly why this design is dangerous: it looks fine until you try to change anything.

### 14.7.2 Every Anomaly, Made Concrete

**1. Repeating-group ceiling (a 1NF symptom already visible):** Orders 1002 and 1004 have `NULL` padding across all of `product2_*` because they only contain one product. Now a customer wants to buy **three** products in one order — there is no `product3_name` column. You are forced to either (a) alter the table to add `product3_*` columns (a schema change driven by *data*, not by a new requirement), or (b) illegally split one logical order into two `order_id` rows, corrupting the meaning of "one order."

**2. Insertion anomaly:** The store hires a new salesperson, Tomás Reyes, in the Support department, office `Office-5`. He has not sold anything yet.
```sql
-- Cannot represent this fact — there is no order to attach it to.
-- The only way to "insert" it is to fabricate a fake order:
INSERT INTO messy_orders (order_id, salesperson_name, salesperson_dept, salesperson_office)
VALUES (NULL, 'Tomás Reyes', 'Support', 'Office-5');
-- order_id is required in a real schema (it's meant to be the PK) — this either fails
-- a NOT NULL constraint or, worse, silently creates a fake order in every report.
```
You cannot record a true, known fact (a new employee exists) without either violating the table's own key or inventing fictitious order data.

**3. Update anomaly:** Priya Nair's department is renamed from "Home Goods" to "Home & Living."
```sql
-- You must find and update EVERY row for Priya Nair:
UPDATE messy_orders
SET salesperson_dept = 'Home & Living'
WHERE salesperson_name = 'Priya Nair';
-- rows 1003 AND 1004 affected. Miss the WHERE clause, miss a row due to a typo
-- in salesperson_name ('Priya Nair ' with trailing space, 'priya nair' wrong case),
-- and Priya now appears to work in two departments at once — an internal contradiction
-- that no CHECK constraint on this table can catch, because the table has no way to
-- express "salesperson_dept is a property of the salesperson, not of the order."
```
Same problem for `customer_email`/`customer_phone` — Asha Verma's data is duplicated across rows 1001 and 1003; changing her phone number means updating both, or the database now has two different "correct" phone numbers for the same person.

**4. Deletion anomaly:** Order 1002 (Ben Carter's chair) is cancelled and the row is deleted.
```sql
DELETE FROM messy_orders WHERE order_id = 1002;
```
If this had been the *only* order Raj Malhotra ever appeared on, deleting it would silently erase every trace that Raj Malhotra works in Electronics out of Office-3 — a fact about an employee, destroyed as a side effect of deleting a fact about an order. (In this sample, Raj still appears on rows 1001/1005, so the *symptom* isn't visible yet — which is itself the danger: the bug is dormant until the "wrong" row gets deleted, at which point it fails silently, with no error.)

> **⚠️ Warning:** None of these four problems are hypothetical edge cases — they are the *guaranteed, mechanical consequence* of storing more than one entity's attributes in one table. Every one of them will eventually happen in production if this schema ships.

### 14.7.3 Step 1 — First Normal Form (1NF)

**Simple explanation:** Every column holds one, atomic, single value — no repeating groups, no multi-valued columns, no comma-separated lists in a cell.

**Technical/formal definition:** A relation is in 1NF if and only if every attribute's domain contains only atomic (indivisible) values, and there is no repeating group of attributes (no `product1_*`, `product2_*`, ... pattern; no attribute that logically holds a *set* of values).

**Anomaly it targets:** 1NF removes the structural cause of the insertion anomaly seen above (can't add a 3rd product) and stops the table from silently discarding information via NULL padding.

**Formal breakdown:** the violation is: `{product1_name, product1_price, product1_qty}` and `{product2_name, product2_price, product2_qty}` are two instances of the same repeating attribute group (both describe "a product on this order"), which should instead be **rows**, not **columns**.

**The fix — un-flatten the repeating group.** Each order/product pairing becomes its own row. We also introduce a `product_id`, since "the product on this line" is itself becoming a real, addressable fact.

```sql
-- [PostgreSQL] — 1NF stage: atomic values, no repeating groups. Still very redundant.
CREATE TABLE order_lines_1nf (
    order_id            INT,
    order_date          DATE,
    customer_name       VARCHAR(100),
    customer_email      VARCHAR(100),
    customer_phone      VARCHAR(20),
    product_id          INT,
    product_name        VARCHAR(100),
    product_price       NUMERIC(10,2),
    quantity            INT,
    salesperson_name    VARCHAR(100),
    salesperson_dept    VARCHAR(50),
    salesperson_office  VARCHAR(20),
    PRIMARY KEY (order_id, product_id)   -- composite key: one row per order+product
);
```

Resulting data (8 rows — orders with 2 products now correctly produce 2 rows):

| order_id | order_date | customer_name | customer_email | product_id | product_name | product_price | quantity | salesperson_name | salesperson_dept | salesperson_office |
|---|---|---|---|---|---|---|---|---|---|---|
| 1001 | 2024-01-05 | Asha Verma | asha@mail.com | 501 | Wireless Mouse | 25.00 | 2 | Raj Malhotra | Electronics | Office-3 |
| 1001 | 2024-01-05 | Asha Verma | asha@mail.com | 502 | USB-C Cable | 9.00 | 1 | Raj Malhotra | Electronics | Office-3 |
| 1002 | 2024-01-06 | Ben Carter | ben@mail.com | 503 | Office Chair | 150.00 | 1 | Raj Malhotra | Electronics | Office-3 |
| 1003 | 2024-01-06 | Asha Verma | asha@mail.com | 504 | Desk Lamp | 40.00 | 1 | Priya Nair | Home Goods | Office-1 |
| 1003 | 2024-01-06 | Asha Verma | asha@mail.com | 505 | Notebook | 5.00 | 3 | Priya Nair | Home Goods | Office-1 |
| 1004 | 2024-01-07 | Chidi Okafor | chidi@mail.com | 501 | Wireless Mouse | 25.00 | 1 | Priya Nair | Home Goods | Office-1 |
| 1005 | 2024-01-08 | Ben Carter | ben@mail.com | 506 | Monitor Stand | 35.00 | 2 | Raj Malhotra | Electronics | Office-3 |
| 1005 | 2024-01-08 | Ben Carter | ben@mail.com | 507 | Keyboard | 60.00 | 1 | Raj Malhotra | Electronics | Office-3 |

*(customer_phone omitted from the display for width; it's still a column, still duplicated.)*

**What we fixed:** a 3rd product on an order is now just a 3rd row — no schema change required, no NULL padding. **What's still broken:** notice `product_name`/`product_price` for `product_id = 501` (Wireless Mouse) is now duplicated on rows for order 1001 *and* order 1004 — that's a **new** redundancy 1NF introduced as a side effect of un-flattening, and it's exactly what 2NF exists to fix.

### 14.7.4 Step 2 — Second Normal Form (2NF)

**Simple explanation:** 2NF only has teeth when your primary key is *composite* (more than one column). The rule: every non-key column must depend on the **whole** key, not just part of it.

**Technical/formal definition:** A relation is in 2NF if it is in 1NF *and* every non-prime attribute is **fully functionally dependent** on every candidate key — i.e., no non-prime attribute has a **partial dependency** on a proper subset of a composite key.

**Anomaly it targets:** partial dependencies cause the exact redundancy we just saw (product facts duplicated per order) and reopen the update anomaly: change the price of "Wireless Mouse" and you must find and update it on both order 1001's row and order 1004's row.

**Formal breakdown of the violation in `order_lines_1nf`:** the key is `{order_id, product_id}`. Check each non-key column:

```
order_date, customer_name, customer_email, customer_phone,
salesperson_name, salesperson_dept, salesperson_office
    → depend only on order_id           (PARTIAL dependency — violates 2NF)

product_name, product_price
    → depend only on product_id          (PARTIAL dependency — violates 2NF)

quantity
    → depends on {order_id, product_id}  (FULL dependency — this one is fine)
```

**The fix — split off each partial dependency into its own table, keyed by the column it actually depends on.**

```sql
-- [PostgreSQL] — 2NF stage
CREATE TABLE orders_2nf (
    order_id            INT PRIMARY KEY,
    order_date          DATE NOT NULL,
    customer_name       VARCHAR(100) NOT NULL,
    customer_email      VARCHAR(100) NOT NULL,
    customer_phone      VARCHAR(20),
    salesperson_name    VARCHAR(100) NOT NULL,
    salesperson_dept    VARCHAR(50)  NOT NULL,
    salesperson_office  VARCHAR(20)  NOT NULL
);

CREATE TABLE products_2nf (
    product_id     INT PRIMARY KEY,
    product_name   VARCHAR(100) NOT NULL,
    product_price  NUMERIC(10,2) NOT NULL
);

CREATE TABLE order_items_2nf (
    order_id    INT NOT NULL REFERENCES orders_2nf(order_id),
    product_id  INT NOT NULL REFERENCES products_2nf(product_id),
    quantity    INT NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, product_id)   -- quantity is fully dependent on BOTH — stays here
);
```

Resulting data:

`products_2nf`

| product_id | product_name | product_price |
|---|---|---|
| 501 | Wireless Mouse | 25.00 |
| 502 | USB-C Cable | 9.00 |
| 503 | Office Chair | 150.00 |
| 504 | Desk Lamp | 40.00 |
| 505 | Notebook | 5.00 |
| 506 | Monitor Stand | 35.00 |
| 507 | Keyboard | 60.00 |

`order_items_2nf`

| order_id | product_id | quantity |
|---|---|---|
| 1001 | 501 | 2 |
| 1001 | 502 | 1 |
| 1002 | 503 | 1 |
| 1003 | 504 | 1 |
| 1003 | 505 | 3 |
| 1004 | 501 | 1 |
| 1005 | 506 | 2 |
| 1005 | 507 | 1 |

`orders_2nf` (5 rows — still has the salesperson/customer redundancy, next section's problem)

| order_id | order_date | customer_name | customer_email | salesperson_name | salesperson_dept | salesperson_office |
|---|---|---|---|---|---|---|
| 1001 | 2024-01-05 | Asha Verma | asha@mail.com | Raj Malhotra | Electronics | Office-3 |
| 1002 | 2024-01-06 | Ben Carter | ben@mail.com | Raj Malhotra | Electronics | Office-3 |
| 1003 | 2024-01-06 | Asha Verma | asha@mail.com | Priya Nair | Home Goods | Office-1 |
| 1004 | 2024-01-07 | Chidi Okafor | chidi@mail.com | Priya Nair | Home Goods | Office-1 |
| 1005 | 2024-01-08 | Ben Carter | ben@mail.com | Raj Malhotra | Electronics | Office-3 |

**Step-by-step what happened:** we identified two determinants smaller than the full key (`order_id` alone, `product_id` alone), gave each its own table keyed by that determinant, and left in the junction table (`order_items_2nf`) only the attribute(s) that genuinely need the *whole* composite key. The price you now change *once*, in `products_2nf`, and it's correct everywhere it's referenced.

**What's still broken:** in `orders_2nf`, the key is now the single column `order_id` — so by definition there can be no more *partial* dependency (2NF is automatically satisfied by any table with a non-composite primary key). But look closely: `salesperson_dept` and `salesperson_office` don't really describe the *order* — they describe the *salesperson*. That's not a partial dependency (the key isn't composite anymore); it's a **transitive** one. Same for `customer_email`/`customer_phone`, which describe the *customer*, not the order. That's 3NF's job.

### 14.7.5 Step 3 — Third Normal Form (3NF)

**Simple explanation:** Every non-key column must depend on the key, the whole key, **and nothing but the key**. If a column actually depends on *another non-key column*, it's in the wrong table.

**Technical/formal definition:** A relation is in 3NF if it is in 2NF *and* has no **transitive dependency** of a non-prime attribute on the primary key — i.e., there is no non-key attribute `Z` such that `key → Y → Z` for some other non-key attribute `Y` (Y ≠ key, Z ≠ Y).

**Anomaly it targets:** this is exactly the update anomaly (renaming a department requires updating every order row for that salesperson) and the deletion anomaly (deleting the last order for a salesperson erases the fact that they exist, and which department/office they belong to) demonstrated in §14.7.2.

**Formal breakdown of the violation in `orders_2nf`:**

```
order_id → salesperson_name → salesperson_dept, salesperson_office     (transitive)
order_id → customer_name     → customer_email, customer_phone          (transitive)
```

`salesperson_dept` doesn't depend on *which order this is* — it depends on *who the salesperson is*, which itself only happens to be reachable by first going through the order. Same logic for the customer's contact details.

**The fix — pull each transitively-dependent group into its own table, keyed by the attribute they actually depend on.**

```sql
-- [PostgreSQL] — 3NF stage (final normalized schema for this worked example)
CREATE TABLE customers (
    customer_id    SERIAL PRIMARY KEY,
    customer_name  VARCHAR(100) NOT NULL,
    customer_email VARCHAR(100) NOT NULL UNIQUE,
    customer_phone VARCHAR(20)
);

CREATE TABLE salespeople (
    salesperson_id     SERIAL PRIMARY KEY,
    salesperson_name   VARCHAR(100) NOT NULL,
    salesperson_dept   VARCHAR(50)  NOT NULL,
    salesperson_office VARCHAR(20)  NOT NULL
);

CREATE TABLE products (
    product_id     SERIAL PRIMARY KEY,
    product_name   VARCHAR(100) NOT NULL,
    product_price  NUMERIC(10,2) NOT NULL CHECK (product_price >= 0)
);

CREATE TABLE orders (
    order_id       SERIAL PRIMARY KEY,
    order_date     DATE NOT NULL DEFAULT CURRENT_DATE,
    customer_id    INT NOT NULL REFERENCES customers(customer_id),
    salesperson_id INT NOT NULL REFERENCES salespeople(salesperson_id)
);

CREATE TABLE order_items (
    order_id   INT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id INT NOT NULL REFERENCES products(product_id),
    quantity   INT NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, product_id)
);
```

Final ER diagram for the 3NF schema:

```
┌───────────────────┐          1                     N          ┌───────────────────┐
│    CUSTOMERS       │──────────────────────────────────────────<│      ORDERS         │
├───────────────────┤   (optional: 0+ orders)   (mandatory: 1)   ├───────────────────┤
│ PK customer_id      │                                            │ PK order_id          │
│    customer_name    │                                            │    order_date        │
│    customer_email   │                                            │ FK customer_id       │
│    customer_phone   │                                            │ FK salesperson_id    │
└───────────────────┘                                            └────────┬──────────┘
                                                                             │ 1
┌───────────────────┐          1                     N                    │ (mandatory)
│    SALESPEOPLE      │──────────────────────────────────────────<────────┘
├───────────────────┤   (optional: 0+ orders)   (mandatory: 1)
│ PK salesperson_id   │
│    salesperson_name │                                            ┌───────────────────┐
│    salesperson_dept │                                     N      │     ORDER_ITEMS     │
│    salesperson_office│───────────────────────────────────────────>├───────────────────┤
└───────────────────┘                                            │ PK,FK order_id      │
                                                                    │ PK,FK product_id    │
┌───────────────────┐          1                     N            │    quantity          │
│      PRODUCTS       │──────────────────────────────────────────<│                       │
├───────────────────┤   (optional: 0+ order_items) (mandatory: 1) └───────────────────┘
│ PK product_id        │
│    product_name      │
│    product_price     │
└───────────────────┘

  ORDERS ────< ORDER_ITEMS :  1 (mandatory) / N (mandatory — every order needs >= 1 item)
```

**Sample data at this final stage:**

`customers`

| customer_id | customer_name | customer_email | customer_phone |
|---|---|---|---|
| 1 | Asha Verma | asha@mail.com | 555-0101 |
| 2 | Ben Carter | ben@mail.com | 555-0202 |
| 3 | Chidi Okafor | chidi@mail.com | 555-0303 |

`salespeople`

| salesperson_id | salesperson_name | salesperson_dept | salesperson_office |
|---|---|---|---|
| 1 | Raj Malhotra | Electronics | Office-3 |
| 2 | Priya Nair | Home Goods | Office-1 |

`orders`

| order_id | order_date | customer_id | salesperson_id |
|---|---|---|---|
| 1001 | 2024-01-05 | 1 | 1 |
| 1002 | 2024-01-06 | 2 | 1 |
| 1003 | 2024-01-06 | 1 | 2 |
| 1004 | 2024-01-07 | 3 | 2 |
| 1005 | 2024-01-08 | 2 | 1 |

**Re-running the three anomalies against the 3NF schema:**

- **Insertion:** `INSERT INTO salespeople (salesperson_name, salesperson_dept, salesperson_office) VALUES ('Tomás Reyes', 'Support', 'Office-5');` — works immediately, zero orders required. Insertion anomaly gone.
- **Update:** `UPDATE salespeople SET salesperson_dept = 'Home & Living' WHERE salesperson_id = 2;` — **one row**, everywhere Priya Nair is referenced (via `salesperson_id`) automatically reflects the new department. Update anomaly gone.
- **Deletion:** `DELETE FROM orders WHERE order_id = 1002;` (with `order_items` cascading) removes only the order and its line items. `salespeople` and `customers` rows are untouched — Raj Malhotra's record survives regardless of how many of his orders get deleted. Deletion anomaly gone.

This 3NF schema is what most production OLTP systems target by default, and it's structurally the same shape as `ecommerce_db`'s `users` / `products` / `orders` / `order_items` split in this course.

### 14.7.6 Step 4 — Boyce-Codd Normal Form (BCNF)

**Simple explanation:** 3NF has a loophole: it only restricts dependencies that end in a *non-prime* (non-key) attribute. BCNF closes that loophole — *every* determinant of *any* nontrivial dependency must be a superkey, full stop, even if what it determines happens to be part of a candidate key.

**Technical/formal definition:** A relation is in BCNF if, for every nontrivial functional dependency `X → Y`, `X` is a superkey. (Compare to 3NF's definition, which adds the escape clause "...or Y is a prime attribute.")

**When this loophole actually gets exploited:** only when a table has **two or more overlapping composite candidate keys**. This is rare enough that most tables that satisfy 3NF also satisfy BCNF — but it does happen, and it's a classic interview question. Suppose the store also tracks staff training:

```sql
-- [PostgreSQL] — satisfies 3NF, but NOT BCNF
CREATE TABLE skill_training (
    employee_name VARCHAR(100),
    skill         VARCHAR(50),
    trainer       VARCHAR(100),
    PRIMARY KEY (employee_name, skill)
);
```

Business rules: an employee can learn several skills, each possibly from a different trainer (so `{employee_name, skill}` is a candidate key). But **each trainer teaches exactly one skill** (`trainer → skill`), while a skill can be taught by multiple trainers. Because `trainer → skill` holds and no employee is ever trained twice by the same trainer for different skills, `{employee_name, trainer}` is *also* a candidate key.

| employee_name | skill | trainer |
|---|---|---|
| Priya Nair | Excel | Wendy Lo |
| Priya Nair | SQL | Marco Diaz |
| Raj Malhotra | SQL | Marco Diaz |
| Chidi Okafor | Excel | Sam Osei |

**Why this is 3NF but not BCNF:** check the 3NF definition against `trainer → skill`. `skill` is a *prime* attribute here (it's part of the candidate key `{employee_name, skill}`), so 3NF's escape clause lets this dependency slide — **3NF is satisfied**. But BCNF has no escape clause: `trainer → skill` is a nontrivial dependency, and `trainer` alone is **not** a superkey (it doesn't determine `employee_name`). **BCNF is violated.**

**The redundancy this causes:** the fact "Marco Diaz teaches SQL" is stored twice (rows 2 and 3) and could drift out of sync if Marco is reassigned to teach a different skill and only one row gets updated.

**The fix — decompose on the violating determinant:**

```sql
-- [PostgreSQL] — BCNF fix
CREATE TABLE trainers (
    trainer VARCHAR(100) PRIMARY KEY,
    skill   VARCHAR(50) NOT NULL
);

CREATE TABLE employee_trainers (
    employee_name VARCHAR(100),
    trainer       VARCHAR(100) REFERENCES trainers(trainer),
    PRIMARY KEY (employee_name, trainer)
);
```

Now "Marco Diaz teaches SQL" is stored exactly once, in `trainers`, and `trainer` is a real primary key there (a superkey by construction) — BCNF restored.

### 14.7.7 Step 5 — Fourth Normal Form (4NF)

**Simple explanation:** don't store two *independent* multi-valued facts about the same entity in one table — you'll be forced to store every combination of them, even though they have nothing to do with each other.

**Technical/formal definition:** A relation is in 4NF if it is in BCNF and has no nontrivial **multivalued dependency (MVD)** unless that MVD is implied by a candidate key. Notation: `X ↠ Y` ("X multi-determines Y") means that for a given value of `X`, there is a set of `Y` values that is independent of any other attribute `Z` in the same relation.

**The classic trap — skills and languages stored together:**

```sql
-- [PostgreSQL] — satisfies BCNF (no non-trivial FDs at all!) but violates 4NF
CREATE TABLE employee_skills_languages (
    employee_name VARCHAR(100),
    skill         VARCHAR(50),
    language      VARCHAR(50),
    PRIMARY KEY (employee_name, skill, language)
);
```

Priya Nair knows 2 skills (`Excel`, `SQL`) and speaks 2 languages (`English`, `Hindi`) — and skills have *nothing to do with* languages. But to represent "Priya knows these 2 skills AND speaks these 2 languages" you're forced into the **cross product**:

| employee_name | skill | language |
|---|---|---|
| Priya Nair | Excel | English |
| Priya Nair | Excel | Hindi |
| Priya Nair | SQL | English |
| Priya Nair | SQL | Hindi |

That's `employee_name ↠ skill` and `employee_name ↠ language` — two independent multivalued dependencies colliding in one table. Note this table has **no nontrivial functional dependency at all** (no column, or combination smaller than the whole row, determines another) — so it is technically already in BCNF! This is exactly why 4NF exists as a *separate, later* normal form: **BCNF only looks at functional dependencies; it is blind to multivalued dependencies.** The redundancy is real (4 rows to express 2 facts) but BCNF cannot see it.

**Combinatorial cost:** add a 3rd skill and a 3rd language and you now need 9 rows to express 6 independent facts. This is multiplicative, not additive — it gets worse fast, and it invites exactly the update anomaly pattern (add one more language for Priya, and you must add it once *per existing skill row*, or the data becomes inconsistent about which languages she "really" knows for which skill, which is meaningless).

**The fix — split into two independent tables:**

```sql
-- [PostgreSQL] — 4NF fix
CREATE TABLE employee_skills (
    employee_name VARCHAR(100),
    skill         VARCHAR(50),
    PRIMARY KEY (employee_name, skill)
);

CREATE TABLE employee_languages (
    employee_name VARCHAR(100),
    language      VARCHAR(50),
    PRIMARY KEY (employee_name, language)
);
```

Now: 2 skill rows + 2 language rows = 4 rows total (additive, not multiplicative), and each independent fact is recorded exactly once.

### 14.7.8 Step 6 — Fifth Normal Form (5NF / PJNF)

**Simple explanation (conceptual, lighter treatment as real-world 5NF cases are rare):** occasionally a relationship genuinely involves **three (or more) entities together**, in a way that cannot be correctly rebuilt by joining any two of the three pairwise (binary) relationships — you need all three, or you get *spurious* combinations that were never actually true.

**Technical/formal definition:** A relation `R` is in 5NF (also called **Project-Join Normal Form**) if every **join dependency** in `R` is implied by its candidate keys. A join dependency `*(R1, R2, ..., Rn)` means `R` is always equal to the natural join of its projections onto `R1...Rn`. 5NF says: if `R` can be losslessly decomposed into smaller pieces, decompose it that way; if it genuinely cannot be decomposed without introducing spurious rows on rejoin, leave it as one (ternary) table.

**Conceptual example (store domain):** suppose the store tracks three independent binary facts:

- Which **agents** are authorized to sell which **products**: `(agent, product)`.
- Which **brands** each **agent** represents: `(agent, brand)`.
- Which **brands** make which **products**: `(brand, product)`.

If you tried to store this as one 3-column table `agent_brand_product(agent, brand, product)` and it turns out the valid combinations are *exactly* those implied by the three pairwise facts above (agent sells product X, agent represents brand Y, brand Y makes product X ⇒ the triple is valid, and *only* such triples are valid), then storing the ternary table directly is redundant and error-prone — three separate binary tables are sufficient, and joining all three back together reconstructs exactly the valid triples, with no extra rows and no lost ones.

```
              AGENT_PRODUCT              AGENT_BRAND              BRAND_PRODUCT
            (agent, product)           (agent, brand)           (brand, product)
                    │                         │                         │
                    └───────────┬─────────────┴────────────┬────────────┘
                                 │  natural join of all three │
                                 ▼                             ▼
                     reconstructs the true, valid agent–brand–product
                     triples — with NO spurious rows and no lost ones.
```

**⚠️ Warning — the trap:** if you naively split a *true* three-way dependency into only **two** of the three binary tables (say, just `agent_product` and `agent_brand`) and then join them to try to infer valid `(agent, brand, product)` triples, you can get **spurious tuples** — combinations that satisfy both binary facts individually but were never actually true together. This is precisely why the join-dependency condition matters: you need the *right* decomposition (here, all three binaries), not just *any* decomposition. 5NF is the formal statement of "you have found the correct, most fully decomposed, lossless set of projections — no more spurious joins are possible."

In practice: 5NF is almost never something you deliberately design toward from scratch. It typically surfaces as a *bug fix* — you discover spurious rows coming out of a join, trace it to an improperly decomposed multi-entity relationship, and correct it by identifying the real independent binary (or n-ary) facts. Most real-world schemas that are correctly modeled in 3NF/BCNF/4NF are, in practice, already in 5NF because their designers modeled each true independent relationship as its own table from the start.

---

## 14.8 Normal Forms — Summary Table

| Normal Form | Rule (plain English) | Formal condition | Anomaly primarily prevented |
|---|---|---|---|
| **1NF** | Atomic columns, no repeating groups | Every attribute holds a single, indivisible value; no multi-valued/composite-as-list columns | Insertion (can't add "one more" item), inconsistent row shape |
| **2NF** | No partial dependency on a composite key | 1NF + every non-prime attribute fully depends on the *entire* candidate key | Update (duplicated per-part-of-key facts), insertion |
| **3NF** | No transitive dependency through a non-key attribute | 2NF + no non-prime attribute depends on another non-prime attribute | Update, deletion (facts about a second entity tied to first entity's rows) |
| **BCNF** | Every determinant is a superkey | For every nontrivial FD `X → Y`, `X` is a superkey (no exception for prime `Y`) | Update anomalies from overlapping composite candidate keys |
| **4NF** | No independent multivalued facts mixed in one table | BCNF + no nontrivial MVD unless implied by a candidate key | Combinatorial redundancy/update anomalies from unrelated multi-valued attributes |
| **5NF (PJNF)** | Every join dependency is implied by candidate keys | No lossless decomposition remains that isn't already reflected in the table's keys | Spurious/missing rows from incorrectly modeled multi-entity relationships |

---

## 14.9 3NF vs. BCNF — the Precise Difference

This is one of the most commonly mis-explained topics in SQL interviews, so state it precisely:

| | 3NF | BCNF |
|---|---|---|
| Rule | No non-*prime* attribute may be transitively/partially dependent on the key | *No* attribute (prime or not) may be dependent on a non-superkey determinant |
| Escape clause | Yes — a dependency `X → Y` is allowed to violate the spirit of the rule if `Y` is a **prime** attribute (part of some candidate key) | None — every determinant of every nontrivial dependency must be a superkey |
| When they differ | Only when a table has **two or more overlapping composite candidate keys** that share an attribute, and a non-key part of one candidate key determines part of another | — |
| Practical frequency | Nearly all real schemas hit exactly this level | Genuinely rare — most 3NF tables are already BCNF |
| Trade-off of going to BCNF | Sometimes loses the ability to enforce certain FDs with simple foreign keys (a well-known theoretical caveat: not every BCNF decomposition preserves all original dependencies without adding a constraint elsewhere) | More redundancy-free, but occasionally requires giving up straightforward dependency-preservation |

**One-sentence version:** *3NF says "a non-key column can't depend on another non-key column"; BCNF says "no column — key or not — may be functionally determined by anything less than a full candidate key."* BCNF is strictly stronger; every BCNF relation is automatically in 3NF, but not vice versa.

---

## 14.10 Practical Implications — Normalization vs. Query Complexity

Normalizing the store example turned **one table** into **five** (`customers`, `salespeople`, `products`, `orders`, `order_items`). A query that used to be:

```sql
-- Denormalized: trivial, single-table
SELECT customer_name, product1_name, product1_price
FROM messy_orders
WHERE order_id = 1001;
```

now requires joins:

```sql
-- [PostgreSQL] — Normalized: correct, but requires 4 joins for the equivalent report
SELECT c.customer_name, p.product_name, p.product_price, oi.quantity
FROM orders o
JOIN customers c    ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p     ON p.product_id = oi.product_id
WHERE o.order_id = 1001;
```

This is the fundamental trade-off of this entire chapter: **normalization buys you correctness (no anomalies) at the cost of query complexity (more joins).** As you normalize further (3NF → BCNF → 4NF), the number of tables involved in a typical "show me everything about X" query keeps growing. This is exactly why:

- Chapter 16 (Indexes) matters enormously more once you've normalized — joins need indexed foreign keys to stay fast.
- Chapter 17 (Query Planner) exists — the planner's whole job is choosing efficient join strategies (nested loop / hash / merge) across your normalized tables.
- Chapter 18 (Performance Optimization) and this chapter's own §14.11 (Denormalization) exist as the release valve when normalization's join cost becomes a measured, real bottleneck.

Normalizing is not free, and denormalizing is not automatically wrong — they are two ends of one dial, and the rest of this chapter is about choosing where to set it.

---

## 14.11 Common Mistakes

**Under-normalizing (stopping too early, or never starting):**
- Storing comma-separated values in a column (`'Excel,SQL,Python'`) instead of a child table — a direct 1NF violation that makes filtering (`WHERE skills LIKE '%SQL%'`) slow and wrong (matches `'SQL'` inside `'MySQL'` too).
- Repeating "lookup" data (department name, category name, status label) as free text on every row instead of a foreign key to a reference table — invites the exact update anomaly from §14.7.2.
- Leaving `NULL`-heavy "just in case" columns (`product2_name`, `product3_name`) instead of a proper child table.

**Over-normalizing (going further than the workload justifies):**
- Splitting a table into so many pieces that a single, extremely common read (e.g., "show an order confirmation page") needs an 8-table join, when the data rarely changes and could tolerate one safely-denormalized read table.
- Normalizing genuinely immutable, rarely-updated reference data (e.g., country ISO codes) into multiple linked tables when a single small lookup table is entirely sufficient and the "anomaly" risk is effectively zero.
- Applying 4NF/5NF rigor to a reporting table that is *supposed* to be a wide, denormalized read model (see §14.12) — normal forms are a tool for OLTP integrity, not a universal aesthetic.

> **⚠️ Warning:** Normalization is a means (data integrity), not an end in itself. A schema that is "more normalized" is not automatically "better" — it's better *only if* the anomalies it prevents are actually a risk for that table's data and workload.

---

## 14.12 Edge Cases

- **Composite candidate keys hiding a BCNF violation:** always check for *more than one* candidate key before declaring a table 3NF-complete — the `skill_training` example (§14.7.6) is exactly this trap.
- **Derived/computed columns:** an attribute like `full_name` derived from `first_name || ' ' || last_name` is not a normalization violation per se, but storing it (rather than computing it in a view) is a deliberate, small-scale denormalization decision — apply the same cost/benefit reasoning as §14.13.
- **Optional 1:1 relationships modeled as subtype tables** (e.g., `vehicle`, with `car` and `truck` each 1:1-optional to `vehicle` for type-specific columns) are a *legitimate* use of 1:1 relationships, not an anomaly — this is "table-per-subtype" modeling, distinct from bad design.
- **Self-referencing relationships** (an `employee.manager_id` referencing `employee.employee_id`) are a valid 1:N relationship where both entities happen to be the same table — normal forms apply exactly the same way.
- **Temporal/history tables** (an `employee_salary_history` table with `effective_date`) can *look* like a 2NF violation (salary depending on `employee_id` alone, not the composite `{employee_id, effective_date}`) — but here the business fact genuinely is "the salary that was effective on this date," so `{employee_id, effective_date} → salary` is the correct, full functional dependency, not a partial one. Read the actual business rule carefully before applying a rule mechanically.

---

## 14.13 Denormalization

### 14.13.1 What and Why

**Simple explanation:** denormalization means deliberately re-introducing redundancy — duplicating or precomputing data — to make reads faster, in a context where you've decided the anomaly risk is acceptable or is mitigated another way.

**Technical explanation:** it is the intentional violation of one or more normal forms, typically to reduce the number of joins required for a known, high-frequency query pattern, or to store a precomputed aggregate instead of recalculating it from normalized source tables on every read.

**Why it exists:** normalization optimizes for **write correctness** (one place to update a fact). Some workloads are so overwhelmingly **read-heavy** that the join cost of full normalization measurably hurts performance, while the update-anomaly risk normalization protects against is either rare, low-stakes, or already controlled by a single, tightly governed write path (e.g., a nightly ETL job, not ad-hoc application code).

**The canonical example — caching an aggregate:**

```sql
-- Normalized: total must be recomputed from order_items every time it's needed
SELECT o.order_id, SUM(oi.quantity * p.product_price) AS total_amount
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p     ON p.product_id = oi.product_id
GROUP BY o.order_id;

-- Denormalized: store the computed total directly on the order
ALTER TABLE orders ADD COLUMN total_amount NUMERIC(12,2);

-- Now every read of "what did this order total?" is a single indexed lookup:
SELECT order_id, total_amount FROM orders WHERE order_id = 1001;
```

**The trade-off, explicitly:**

| | Normalized (`total_amount` computed) | Denormalized (`total_amount` stored) |
|---|---|---|
| Read cost | A join + aggregation on every read | A single column read |
| Write cost | None (nothing extra to keep in sync) | Must update `orders.total_amount` every time `order_items` changes (trigger, application code, or batch job) |
| Risk | None — always correct by construction | `total_amount` can drift out of sync with the real line items if the update path is missed |
| Best for | OLTP systems where `order_items` changes frequently | Read-heavy dashboards/reports where the order total is read far more often than the items change |

### 14.13.2 OLTP vs. OLAP

| | **OLTP** (Online Transaction Processing) | **OLAP** (Online Analytical Processing) |
|---|---|---|
| Purpose | Run the day-to-day business: place an order, update a balance, register a user | Analyze historical data: trends, aggregates, reports, dashboards |
| Typical workload | Many small, fast reads/writes; single-row or few-row transactions | Few, large, read-heavy queries scanning millions of rows and aggregating |
| Schema shape favored | **Normalized** (3NF/BCNF) — integrity and non-redundant writes matter most | **Denormalized** — star/snowflake schemas optimized for large aggregate reads |
| Example in this course | `company_db`, `ecommerce_db`, `banking_db` | `analytics_db` |
| Priority | Data integrity, concurrency correctness (Ch. 11-12), no anomalies | Query speed over huge scans, fewer joins, predictable aggregation paths |

**Why OLTP favors normalization:** an e-commerce checkout is a write-heavy, correctness-critical transaction — you cannot afford an update anomaly corrupting a customer's stored balance or duplicating an order line. The 3NF schema built in §14.7.5 is the right shape for exactly this reason.

**Why OLAP favors denormalization — the star schema:** this course's `analytics_db` (`databases/analytics_db.sql`) is a real, working example of a deliberately denormalized OLAP design:

```
                         ┌───────────────┐
                         │   dim_date     │
                         ├───────────────┤
                         │ PK date_key    │
                         │    year, quarter,
                         │    month, day, ...
                         └───────┬───────┘
                                 │ 1
┌───────────────┐               │ N                ┌───────────────┐
│  dim_customer  │ 1         N  ▼                  │  dim_product   │
├───────────────┤───────────>┌──────────────┐<─────┼───────────────┤
│ PK customer_key│            │  sales_fact   │  N 1 │ PK product_key │
│    customer_name│           ├──────────────┤      │    product_name│
│    segment      │           │ PK sale_id     │      │    category     │
│    country      │           │ FK customer_key│      │    unit_cost    │
└───────────────┘            │ FK product_key │      └───────────────┘
                                │ FK store_key   │
┌───────────────┐             │ FK date_key      1 N ┌───────────────┐
│   dim_store     │ 1       N │    quantity      ────>│   dim_store    │ (shown once, joins shown above)
├───────────────┤────────────>│    amount         │
│ PK store_key    │           └──────────────┘
│    store_name   │
│    region        │
└───────────────┘
```

This is a **star schema**: one large, append-mostly `sales_fact` table (millions of rows) surrounded by small **dimension** tables (`dim_date`, `dim_customer`, `dim_product`, `dim_store`) that each hold denormalized, pre-flattened descriptive attributes (e.g., `dim_customer.country` sits directly on the customer dimension rather than being normalized out into a separate `countries` table — a deliberate, acceptable redundancy because dimension data changes rarely and analytic queries benefit enormously from not having yet another join).

A typical OLAP query — "total sales amount by region and quarter" — needs exactly the number of joins the star schema was designed for (fact table joined once to each relevant dimension), never a chain of transitive joins through multiple normalized lookup layers:

```sql
-- [PostgreSQL] — a star-schema query: fact joined directly to two dimensions, no deeper chains
SELECT ds.region, dd.year, dd.quarter, SUM(sf.amount) AS total_sales
FROM sales_fact sf
JOIN dim_store ds ON ds.store_key = sf.store_key
JOIN dim_date  dd ON dd.date_key  = sf.sale_date
GROUP BY ds.region, dd.year, dd.quarter
ORDER BY dd.year, dd.quarter, ds.region;
```

> **Important Note:** OLTP-vs-OLAP is not "one database is better" — it's "different workloads need different trade-off points on the same normalize↔denormalize dial." Most real companies run **both**: a normalized OLTP system for transactions, and a denormalized OLAP warehouse (often fed by ETL from the OLTP system) for analytics — which is precisely why this course ships `company_db`/`ecommerce_db`/`banking_db` (OLTP-shaped) *and* `analytics_db` (OLAP-shaped) as separate databases.

### 14.13.3 Decision Framework — Normalize or Denormalize?

Ask these questions, in order:

1. **Is this table part of a transactional write path** (an order being placed, a balance being updated)? → Normalize. Correctness on write is non-negotiable here.
2. **Is the redundant value read far more often than the source data changes** (e.g., a computed total read 10,000 times for every 1 time the underlying items change)? → Denormalizing the cached value is likely worth it, *if* you also commit to a reliable way to keep it in sync (trigger, application transaction, scheduled reconciliation).
3. **Is this table primarily a reporting/analytics read model**, queried by BI tools or dashboards, rarely updated row-by-row? → Favor a denormalized (often star-schema) design.
4. **Would normalizing further require joining more than ~4-5 tables for the single most common read** in this table's actual usage pattern? → Consider whether that's acceptable (indexed, planned-for joins are often fine — see Ch. 16-17) or whether a denormalized reporting view/materialized view (Ch. 15) should sit alongside the normalized source of truth.
5. **Can you tolerate eventual, asynchronous consistency** for the denormalized copy (e.g., a dashboard number that's a few minutes stale), or does it need to be transactionally exact right now? → If exact-now is required, either keep it normalized or update the denormalized copy inside the same transaction (triggers, or application-level "write to both" logic).

**Rule of thumb:** normalize by default; denormalize deliberately, narrowly, and with a documented plan for keeping the duplicated data in sync — never as the starting design.

---

## 14.14 Real-World Use Cases

- **OLTP order/payment systems** (`ecommerce_db`, `banking_db` shape): normalized to 3NF/BCNF to guarantee that a balance, an order total, or an account status is stored exactly once and updated atomically (Ch. 11 transactions build directly on this).
- **Data warehouses / BI platforms** (`analytics_db` shape): star or snowflake schemas, denormalized dimensions, one wide fact table — optimized for `GROUP BY`-heavy analytical queries across millions/billions of rows.
- **Caching layers and read replicas**: precomputed, denormalized "read models" (e.g., a `product_search_index` table combining product + category + inventory + rating into one row) sitting alongside a fully normalized source of truth, refreshed on write or on a schedule.
- **Audit/history tables**: intentionally denormalized snapshots (storing the customer's name and address *as they were at the time of the transaction*, not just a foreign key to the current customer row) — required precisely *because* the normalized "current state" table is expected to change and the audit record must not.
- **Materialized views** (Chapter 15): a formal, engine-managed way to get denormalization's read-speed benefit without hand-maintaining the redundant copy yourself.

---

## 14.15 Practice Questions

1. Define insertion, update, and deletion anomalies in your own words, and give one example of each that is *not* from this chapter.
2. Write the functional dependency notation for: "an employee's `tax_id` always determines their `full_legal_name`" and for "a composite key of `{invoice_id, line_number}` determines `line_amount`."
3. A table `book_loans(patron_id, patron_name, book_isbn, book_title, due_date)` uses `PRIMARY KEY (patron_id, book_isbn)`. **Identify which normal form this violates, name the specific partial or transitive dependency, and rewrite it as a set of properly normalized tables.**
4. A table `flight_bookings(passenger_id, passenger_name, passenger_passport_no, flight_no, departure_city, arrival_city, airline_name, airline_country)` has a single-column primary key `booking_id`. **Identify every transitive dependency you can find, and redesign the schema to 3NF.**
5. Explain, precisely, why the `skill_training(employee_name, skill, trainer)` example in §14.7.6 satisfies 3NF but not BCNF. What specific condition in the BCNF definition does it fail?
6. Give an original example (not skills/languages) of a 4NF violation caused by two independent multivalued attributes stored in one table. Show the combinatorial row explosion with sample data.
7. Explain why a table can be in BCNF and still not be in 4NF. What kind of dependency does BCNF fail to account for?
8. You are designing a `product_reviews` table for a high-traffic e-commerce site. Reads (`SELECT` for the product page) outnumber writes (`INSERT` for a new review) by roughly 10,000:1, and the product page needs `AVG(rating)` and `COUNT(*)` for every page view. Using the decision framework in §14.13.3, would you (a) compute the average on every read via a join/aggregate, (b) store a denormalized `avg_rating`/`review_count` on the `products` table, or (c) something else? Justify your answer including how you'd keep any denormalized value in sync.
9. A junior developer stores a customer's shipping address as a single column: `'221B, Baker Street, London, NW1 6XE, UK'`. What normal form does this violate, and what problems does it cause for querying (e.g., "find all customers in London")?
10. Compare 3NF and BCNF precisely: under what specific structural condition (in terms of candidate keys) can a table satisfy 3NF but not BCNF? Can a table ever satisfy BCNF but not 3NF? Explain why or why not.

---

## 14.16 Chapter Challenge — Normalize a New Flat Schema to 3NF

> Try this yourself before reading the solution: sketch your own ER diagram and `CREATE TABLE` statements first, then compare against the walkthrough below.

### The bad table

A small tutoring clinic tracks patient-style "visit" records for its clients in one flat spreadsheet-turned-table:

```sql
-- [PostgreSQL] — DELIBERATELY BAD DESIGN
CREATE TABLE visit_records (
    patient_id            INT,
    patient_name          VARCHAR(100),
    patient_dob           DATE,
    patient_phone         VARCHAR(20),
    visit_date            DATE,
    doctor_id             INT,
    doctor_name           VARCHAR(100),
    doctor_specialty      VARCHAR(50),
    doctor_office_phone   VARCHAR(20),
    branch_name           VARCHAR(100),
    branch_address        VARCHAR(200),
    drug1_name            VARCHAR(100),
    drug1_dosage          VARCHAR(50),
    drug2_name            VARCHAR(100),
    drug2_dosage          VARCHAR(50)
);
```

Business rule: a patient can only have **one visit per day** (so `{patient_id, visit_date}` is the natural key, not a surrogate `visit_id`), and each doctor is permanently based out of exactly one branch.

Sample data:

| patient_id | patient_name | patient_dob | visit_date | doctor_id | doctor_name | doctor_specialty | branch_name | drug1_name | drug1_dosage | drug2_name | drug2_dosage |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Lena Fischer | 1990-03-11 | 2024-02-01 | 10 | Dr. Owusu | Cardiology | Downtown Clinic | Atorvastatin | 10mg | NULL | NULL |
| 1 | Lena Fischer | 1990-03-11 | 2024-03-15 | 11 | Dr. Kapoor | Dermatology | Uptown Clinic | Tretinoin | 0.05% | Clindamycin | 1% |
| 2 | Marco Silva | 1985-07-22 | 2024-02-01 | 10 | Dr. Owusu | Cardiology | Downtown Clinic | Lisinopril | 5mg | Aspirin | 81mg |

**Violations present:**
- **1NF:** `drug1_*`/`drug2_*` is a repeating group (a patient's prescriptions for a visit are a multi-valued fact forced into fixed columns).
- **2NF:** key is `{patient_id, visit_date}`; `patient_name`, `patient_dob`, `patient_phone` depend only on `patient_id` (partial dependency).
- **3NF:** `doctor_specialty`, `doctor_office_phone`, and (transitively, via `doctor_id`) `branch_name`/`branch_address` depend on `doctor_id`, not on the visit key at all (transitive dependency).

### The solution

**Step 1 (1NF):** move prescriptions to their own rows, keyed by `{patient_id, visit_date, drug_name}`.

**Step 2 (2NF):** split off `patient_id`-only attributes into `patients`; the remaining visit-level attributes stay keyed on `{patient_id, visit_date}`.

**Step 3 (3NF):** split off `doctor_id`-only attributes into `doctors`, and `branch`-only attributes (which are transitively reachable only through `doctor_id`) into `branches`.

Final ER diagram:

```
┌────────────────────┐        1                N        ┌────────────────────┐
│      PATIENTS        │────────────────────────────────<│       VISITS         │
├────────────────────┤   (optional: 0+ visits) (mandatory)├────────────────────┤
│ PK patient_id         │                                   │ PK,FK patient_id     │
│    patient_name       │                                   │ PK    visit_date     │
│    patient_dob        │                                   │ FK    doctor_id      │
│    patient_phone      │                                   └─────────┬──────────┘
└────────────────────┘                                             │ N
                                                                       │ (mandatory)
┌────────────────────┐        1                N                    │
│      DOCTORS          │────────────────────────────────────────────┘
├────────────────────┤   (optional: 0+ visits) (mandatory)
│ PK doctor_id           │
│    doctor_name         │                                   ┌────────────────────┐
│    doctor_specialty    │                             1  N  │    PRESCRIPTIONS     │
│    doctor_office_phone │                                   ├────────────────────┤
│ FK branch_id           │                                   │ PK,FK patient_id     │
└─────────┬──────────┘                                    │ PK,FK visit_date      │
             │ N                                              │ PK    drug_name       │
             │ (mandatory)                                    │    dosage             │
             │ 1                                              └────────────────────┘
┌────────────────────┐                                       (mandatory 1 / mandatory N
│      BRANCHES         │                                        with VISITS above)
├────────────────────┤
│ PK branch_id           │
│    branch_name         │
│    branch_address      │
└────────────────────┘
```

`CREATE TABLE` statements, fully normalized to 3NF:

```sql
-- [PostgreSQL] — final 3NF schema

CREATE TABLE branches (
    branch_id      SERIAL PRIMARY KEY,
    branch_name    VARCHAR(100) NOT NULL,
    branch_address VARCHAR(200) NOT NULL
);

CREATE TABLE doctors (
    doctor_id           SERIAL PRIMARY KEY,
    doctor_name         VARCHAR(100) NOT NULL,
    doctor_specialty    VARCHAR(50)  NOT NULL,
    doctor_office_phone VARCHAR(20),
    branch_id           INT NOT NULL REFERENCES branches(branch_id)
);

CREATE TABLE patients (
    patient_id    SERIAL PRIMARY KEY,
    patient_name  VARCHAR(100) NOT NULL,
    patient_dob   DATE NOT NULL,
    patient_phone VARCHAR(20)
);

CREATE TABLE visits (
    patient_id INT  NOT NULL REFERENCES patients(patient_id),
    visit_date DATE NOT NULL,
    doctor_id  INT  NOT NULL REFERENCES doctors(doctor_id),
    PRIMARY KEY (patient_id, visit_date)   -- one visit per patient per day
);

CREATE TABLE prescriptions (
    patient_id INT          NOT NULL,
    visit_date DATE         NOT NULL,
    drug_name  VARCHAR(100) NOT NULL,
    dosage     VARCHAR(50)  NOT NULL,
    PRIMARY KEY (patient_id, visit_date, drug_name),
    FOREIGN KEY (patient_id, visit_date) REFERENCES visits(patient_id, visit_date)
);
```

> **Practical note:** in a real system you would very likely also add a surrogate `visit_id SERIAL` to `visits` (with `UNIQUE (patient_id, visit_date)` preserving the business rule) purely for convenience as a foreign-key target elsewhere — this doesn't change the normalization analysis, it's an implementation convenience layered on top of a correctly normalized design.

Every original anomaly is now gone: a doctor can be added before their first visit (insertion), a doctor's specialty is updated in exactly one row (update), and deleting a patient's single visit does not erase the doctor's or branch's records (deletion) — the same reasoning walked through in full for the main worked example in §14.7.5.

---

## Key Takeaways

- **Entities, attributes, and relationships** are the vocabulary of data modeling; **cardinality** (1:1/1:N/N:M) and **optionality** (mandatory/optional) fully describe every relationship in an ER diagram, and translate directly into where foreign keys live and whether they're `NOT NULL`.
- Normalization exists to eliminate three concrete problems: **insertion, update, and deletion anomalies** — all three are symptoms of one table representing more than one entity's facts.
- **1NF** removes repeating groups; **2NF** removes partial dependencies on a composite key; **3NF** removes transitive dependencies through non-key attributes; **BCNF** closes 3NF's prime-attribute loophole (matters only with overlapping composite candidate keys); **4NF** separates independent multivalued facts; **5NF** ensures a multi-entity relationship isn't incorrectly decomposed (or left un-decomposed) in a way that produces spurious joins.
- Every normalization step is a mechanical response to a **functional dependency**: identify the determinant, check whether it's the whole key, and split accordingly.
- Normalization trades **write-time correctness** for **read-time join complexity** — this is the direct setup for indexing (Ch. 16), the query planner (Ch. 17), and performance tuning (Ch. 18).
- **Denormalization** is a deliberate, targeted trade-off — favored in read-heavy, analytics-style (**OLAP**) workloads and star schemas like `analytics_db`, while **OLTP** systems default to normalized designs for write integrity. Normalize by default; denormalize narrowly, and only with a plan for keeping duplicated data in sync.

## What's Next

Chapter 15 picks up exactly where this one's join-complexity trade-off leaves off: **Views & Materialized Views**. A view lets you wrap a normalized, multi-join schema behind a single, simple `SELECT` — giving application code the *ergonomics* of a flat table without sacrificing the underlying normalized design's integrity. A **materialized view** goes further, physically storing the joined/aggregated result (much like the `orders.total_amount` denormalization example in this chapter) so read-heavy queries skip the join entirely — with the engine, rather than your application code, responsible for keeping it in sync.

→ Continue to [Chapter 15 — Views & Materialized Views](15-views.md)
