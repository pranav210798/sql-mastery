# Chapter 7 — JOINs (Extremely Detailed)

> **Part III — Intermediate SQL.** This is the chapter where SQL stops being "one table at a time" and starts being *relational*. Everything from here on — subqueries, CTEs, window functions, query planning — assumes you have internalized how joins actually behave, row by row, including the ways they silently go wrong. Take your time with this chapter; it is intentionally the longest and most detailed one so far.

## Table of Contents

- [7.0 Why Joins Are the Heart of Relational SQL](#70-why-joins-are-the-heart-of-relational-sql)
- [7.1 The Schemas We'll Use in This Chapter](#71-the-schemas-well-use-in-this-chapter)
- [7.2 Anatomy of a JOIN Clause](#72-anatomy-of-a-join-clause)
- [7.3 INNER JOIN](#73-inner-join)
- [7.4 LEFT JOIN (LEFT OUTER JOIN)](#74-left-join-left-outer-join)
- [7.5 RIGHT JOIN (RIGHT OUTER JOIN)](#75-right-join-right-outer-join)
- [7.6 FULL OUTER JOIN](#76-full-outer-join)
- [7.7 CROSS JOIN](#77-cross-join)
- [7.8 SELF JOIN](#78-self-join)
- [7.9 NATURAL JOIN — and Why You Should Avoid It in Production](#79-natural-join--and-why-you-should-avoid-it-in-production)
- [7.10 USING and Multi-Condition / Composite-Key Joins](#710-using-and-multi-condition--composite-key-joins)
- [7.11 ON vs WHERE — The Most Important Distinction in This Chapter](#711-on-vs-where--the-most-important-distinction-in-this-chapter)
- [7.12 Join Cardinality: One-to-One, One-to-Many, Many-to-Many](#712-join-cardinality-one-to-one-one-to-many-many-to-many)
- [7.13 Duplicate Rows Caused by Joins](#713-duplicate-rows-caused-by-joins)
- [7.14 NULL Behavior in Joins](#714-null-behavior-in-joins)
- [7.15 Anti-Joins](#715-anti-joins)
- [7.16 Semi-Joins](#716-semi-joins)
- [7.17 A First Look Under the Hood: Nested Loop, Hash, and Merge Joins](#717-a-first-look-under-the-hood-nested-loop-hash-and-merge-joins)
- [7.18 Dialect Cheat Sheet](#718-dialect-cheat-sheet)
- [7.19 Common Mistakes Recap](#719-common-mistakes-recap)
- [7.20 Practice Questions](#720-practice-questions)
- [7.21 Difficult Join Problems](#721-difficult-join-problems)
- [Key Takeaways](#key-takeaways)
- [What's Next](#whats-next)

---

## 7.0 Why Joins Are the Heart of Relational SQL

A relational database is deliberately **normalized**: instead of storing "customer name" on every order row, you store a `user_id` on the order and the name lives once, in `users`. This eliminates duplication and update anomalies (Chapter 14 covers normalization theory in depth). But it creates an immediate problem: the data you actually want to *report on* — "which customer bought which product, and did they pay for it?" — is now spread across multiple tables.

**JOIN is the operator that puts the data back together.** It is the mechanism by which normalized, scattered tables become a single, denormalized result set that answers a real business question. Every non-trivial SQL query you will ever write in a production system touches at least one join. Reporting dashboards, invoices, recommendation engines, fraud checks, churn analysis — all of it is joins.

This chapter is long because joins are also where the *majority* of real-world SQL bugs live:

- A `LEFT JOIN` that quietly turns into an `INNER JOIN` because of a misplaced filter.
- A report whose totals are double what they should be because of an unnoticed one-to-many join.
- A `NATURAL JOIN` that breaks the day someone adds a new column with the same name to two different tables.
- A dashboard that excludes an entire category of customers because someone forgot that `NULL` never equals `NULL`.

Every one of these is demonstrated in this chapter with **real, reproducible queries against the two seed databases**, not toy data invented for the example. If you run the query yourself against `company_db` or `ecommerce_db` as set up per the [README](../README.md), you will get exactly the row counts and values shown here.

> **Important Note**
> This chapter uses **PostgreSQL** as the primary dialect (per the course convention). Wherever another engine — MySQL, Oracle, SQL Server — behaves differently or lacks a feature, it is called out explicitly with a dialect tag: **[PostgreSQL]** **[MySQL]** **[Oracle]** **[SQL Server]**.

---

## 7.1 The Schemas We'll Use in This Chapter

Two of the four course databases are the workhorses for this chapter:

- **`ecommerce_db`** — the primary vehicle for join mechanics: multi-table chains, cardinality, duplicate-row bugs, anti-joins, semi-joins. It models a realistic `users → orders → order_items → products → payments` chain, plus `categories`, `inventory`, and `reviews`.
- **`company_db`** — the primary vehicle for self-joins and hierarchy, thanks to the self-referencing `employees.manager_id` column.

### 7.1.1 `ecommerce_db` — tables and relationships

```
users(user_id PK, username, email, full_name, created_at, is_active)
        │
        │ 1:N (a user places many orders)
        ▼
orders(order_id PK, user_id FK → users, order_date, status, shipping_address)
        │
        │ 1:N (an order has many line items)
        ▼
order_items(order_item_id PK, order_id FK → orders, product_id FK → products,
            quantity, unit_price)                       ▲
        ▲                                                │ N:1 (many line items reference one product)
        │ N:1                                             │
        │                                          products(product_id PK, product_name,
orders(order_id) ──── 1:1 ──── payments(payment_id PK,     category_id FK → categories,
                                order_id FK → orders,      price, sku, is_discontinued)
                                payment_date, amount,             │
                                payment_method, status)           │ 1:N
                                                                   ▼
                                                    inventory(inventory_id PK, product_id FK,
                                                    warehouse_location,
                                                    quantity_on_hand, reorder_level,
                                                    UNIQUE(product_id, warehouse_location))

products(product_id) ── 1:N ── reviews(review_id PK, product_id FK, user_id FK → users,
                                        rating, review_text, review_date,
                                        UNIQUE(product_id, user_id))

categories(category_id PK, category_name, parent_category_id FK → categories.category_id)
   -- self-referencing: a category can be the parent of other categories
```

**Seed data snapshot** (so you can sanity-check every result in this chapter against the source):

`users` (8 rows):

| user_id | username | full_name | is_active |
|---|---|---|---|
| 1 | arjun_k | Arjun Kumar | true |
| 2 | sara_p | Sara Patel | true |
| 3 | dev_m | Dev Malhotra | true |
| 4 | nita_r | Nita Rao | false |
| 5 | imran_s | Imran Sheikh | true |
| 6 | lakshmi_v | Lakshmi Venkat | true |
| 7 | farhan_a | Farhan Ali | true |
| 8 | tanya_b | Tanya Bose | true |

`orders` (10 rows):

| order_id | user_id | order_date | status |
|---|---|---|---|
| 1 | 1 | 2024-01-05 10:20:00 | DELIVERED |
| 2 | 2 | 2024-01-08 14:00:00 | DELIVERED |
| 3 | 1 | 2024-01-15 09:30:00 | SHIPPED |
| 4 | 3 | 2024-01-20 16:45:00 | PAID |
| 5 | 4 | 2024-01-22 11:00:00 | CANCELLED |
| 6 | 5 | 2024-02-01 08:15:00 | DELIVERED |
| 7 | 6 | 2024-02-03 19:20:00 | PENDING |
| 8 | 1 | 2024-02-10 12:00:00 | DELIVERED |
| 9 | 7 | 2024-02-14 15:30:00 | PAID |
| 10 | 8 | 2024-02-18 13:10:00 | DELIVERED |

`order_items` (15 rows — order_id, product_id, quantity, unit_price):

```
(1,1,1,45999.00) (1,9,1,3499.00)
(2,5,2,1299.00)  (2,7,1,2499.00)
(3,3,1,89999.00)
(4,6,1,1799.00)  (4,8,1,1499.00)
(5,2,1,29999.00)
(6,4,1,74999.00) (6,10,1,799.00)
(7,9,2,3499.00)
(8,1,1,45999.00)
(9,3,1,89999.00) (9,9,1,3499.00)
(10,5,3,1299.00)
```

`products` (10 rows), `categories` (7 rows), `inventory` (11 rows), `payments` (10 rows — one per order), `reviews` (6 rows) — full detail is introduced inline as each is used below. Refer to `databases/ecommerce_db.sql` for the authoritative seed script.

### 7.1.2 `company_db` — tables and relationships

```
departments(department_id PK, department_name, location)
        │
        │ 1:N
        ▼
employees(employee_id PK, first_name, last_name, email, hire_date, job_title,
          department_id FK → departments,
          manager_id FK → employees.employee_id,   -- SELF-REFERENCING
          status)
        │                    │
        │ 1:N                │ 1:N (self-join: a manager has many direct reports)
        ▼                    ▼
salaries(salary_id PK,   attendance(attendance_id PK,
         employee_id FK,           employee_id FK,
         base_salary, bonus,       work_date, status,
         effective_date)           check_in, check_out)

managers(manager_id PK/FK → employees, department_id UNIQUE FK → departments,
         appointed_date)                      -- one manager per department (1:1)

projects(project_id PK, project_name, department_id FK, start_date, end_date, budget)
        │
        │ M:N via bridge table
        ▼
employee_projects(employee_id FK, project_id FK, role, hours_allocated,
                   PRIMARY KEY(employee_id, project_id))
```

**Seed data snapshot:**

`departments` (5 rows): `1 Engineering (Pune)`, `2 Sales (Mumbai)`, `3 HR (Bengaluru)`, `4 Finance (Mumbai)`, `5 Marketing (Delhi)`.

`employees` (16 rows) — the manager hierarchy:

```
1  Aditi Rao       CTO                   dept 1   manager: NULL   (top of the org)
2  Rahul Mehta     Engineering Manager   dept 1   manager: 1 (Aditi)
3  Sneha Kulkarni  Senior Engineer       dept 1   manager: 2 (Rahul)
4  Vikram Joshi    Software Engineer     dept 1   manager: 2 (Rahul)
5  Ananya Singh    Software Engineer     dept 1   manager: 2 (Rahul)   [ON_LEAVE]
6  Karan Verma     Junior Engineer       dept 1   manager: 3 (Sneha)
7  Priya Nair      Sales Manager         dept 2   manager: 1 (Aditi)
8  Arjun Das       Sales Executive       dept 2   manager: 7 (Priya)
9  Meera Pillai    Sales Executive       dept 2   manager: 7 (Priya)   [TERMINATED]
10 Rohan Kapoor    HR Manager            dept 3   manager: 1 (Aditi)
11 Isha Bhatt      HR Executive          dept 3   manager: 10 (Rohan)
12 Nikhil Gupta    Finance Manager       dept 4   manager: 1 (Aditi)
13 Divya Shah      Accountant            dept 4   manager: 12 (Nikhil)
14 Rajesh Iyer     Marketing Manager     dept 5   manager: 1 (Aditi)
15 Pooja Reddy     Marketing Executive   dept 5   manager: 14 (Rajesh)
16 Aman Chawla     Software Engineer     dept 1   manager: 2 (Rahul)
```

This is the exact hierarchy we'll walk through with self-joins in §7.8.

---

## 7.2 Anatomy of a JOIN Clause

Before diving into each join type, here is the full grammar, so every later syntax box is just a specialization of this:

```sql
SELECT   <columns>
FROM     <left_table>  [AS] <left_alias>
[INNER | LEFT [OUTER] | RIGHT [OUTER] | FULL [OUTER] | CROSS] JOIN
         <right_table> [AS] <right_alias>
[ON      <join_condition>]      -- required for INNER/LEFT/RIGHT/FULL, forbidden for CROSS/NATURAL
[USING   (<shared_column_list>)]-- alternative to ON when column names match
WHERE    <row_filter>            -- applied AFTER the join produces its result set
GROUP BY <columns>
HAVING   <group_filter>
ORDER BY <columns>;
```

Key vocabulary used throughout this chapter:

- **Join key** — the column(s) used to match rows between the two tables (e.g., `orders.order_id = order_items.order_id`).
- **Driving table / probe table** — informal terms for which table is scanned first; relevant in §7.17.
- **Matched row** — a row from one side that satisfies the join condition against at least one row on the other side.
- **Unmatched row** — a row that satisfies no join condition on the other side; what happens to it depends entirely on which join type you used.

> **Important Note**
> A `JOIN` always operates conceptually on the **Cartesian product** of the two tables (every row of A paired with every row of B), then keeps only the pairs that satisfy the join condition (for `CROSS JOIN`, *all* pairs satisfy — there is no condition). This mental model — "cross product, then filter" — is exactly how the relational algebra defines joins, and it is the model we'll use to explain every join type's behavior precisely.

---

## 7.3 INNER JOIN

### Simple Explanation

**What I write:** `SELECT ... FROM orders o INNER JOIN payments p ON o.order_id = p.order_id`
**What the database logically does:** for every row in `orders`, look for row(s) in `payments` whose `order_id` matches. Keep the combined row only if a match is found. If no match is found, drop the `orders` row entirely from the output.
**What result is produced:** one row per matching pair — orders with no matching payment, and payments with no matching order, both disappear.

### Technical Explanation

`INNER JOIN` implements the relational algebra **natural-join-like equi-join** (or theta-join when using non-equality operators): it computes the Cartesian product of the two tables and retains only the tuples where the join predicate evaluates to `TRUE`. Rows where the predicate is `UNKNOWN` (which happens whenever a compared value is `NULL`) or `FALSE` are excluded. `INNER` is the default — writing plain `JOIN` means `INNER JOIN` in every dialect covered in this course.

### Why It Exists

Normalization spreads a real-world entity ("this order, fully paid, for these products") across multiple tables. `INNER JOIN` is the operator for "give me only the records that are complete on both sides" — the most common shape of business question: "show me orders **and** their payment info," where a payment is expected to exist.

### Full Syntax

```sql
SELECT columns
FROM table_a a
[INNER] JOIN table_b b
  ON a.key_column = b.key_column;
```

`INNER` is optional; `JOIN` alone means `INNER JOIN` in PostgreSQL, MySQL, SQL Server, and Oracle.

### Visual Diagram

Two small illustrative tables:

```
Table: A (customers)          Table: B (orders)
+----+---------+              +----+-------------+
| id | name    |              | id | customer_id |
+----+---------+              +----+-------------+
| 1  | Alice   |              | 1  | 1           |
| 2  | Bob     |              | 2  | 1           |
| 3  | Carol   |              | 3  | 4           |   <- customer_id 4 doesn't exist in A
+----+---------+              +----+-------------+
```

`A INNER JOIN B ON A.id = B.customer_id`:

```
+----+-------+----+-------------+
| id | name  | id | customer_id |
+----+-------+----+-------------+
| 1  | Alice | 1  | 1           |   matched
| 1  | Alice | 2  | 1           |   matched (Alice appears twice — 2 orders)
+----+-------+----+-------------+
```

Bob (no orders) and order 3 (customer_id 4, doesn't exist) both vanish. This is the defining trait of `INNER JOIN`: **only mutually matched rows survive.**

### Real Schema Examples

**Example 1 — simple two-table join.** Every user's orders:

```sql
SELECT u.username, o.order_id, o.order_date, o.status
FROM users u
INNER JOIN orders o ON u.user_id = o.user_id
WHERE u.user_id = 1
ORDER BY o.order_id;
```

Output:

| username | order_id | order_date | status |
|---|---|---|---|
| arjun_k | 1 | 2024-01-05 10:20:00 | DELIVERED |
| arjun_k | 3 | 2024-01-15 09:30:00 | SHIPPED |
| arjun_k | 8 | 2024-02-10 12:00:00 | DELIVERED |

**Example 2 — three-table chain.** Order line items with product names, for order 1:

```sql
SELECT o.order_id, pr.product_name, oi.quantity, oi.unit_price
FROM orders o
INNER JOIN order_items oi ON o.order_id = oi.order_id
INNER JOIN products pr    ON oi.product_id = pr.product_id
WHERE o.order_id = 1;
```

Output:

| order_id | product_name | quantity | unit_price |
|---|---|---|---|
| 1 | Galaxy Phone X | 1 | 45999.00 |
| 1 | Wireless Earbuds | 1 | 3499.00 |

**Example 3 — the full five-table chain the user asked for: Customers → Orders → Order Items → Products → Payments**, for `arjun_k` (user_id 1):

```sql
SELECT u.username,
       o.order_id,
       o.status       AS order_status,
       pr.product_name,
       oi.quantity,
       oi.unit_price,
       pay.status      AS payment_status,
       pay.amount
FROM users u
INNER JOIN orders      o   ON u.user_id    = o.user_id
INNER JOIN order_items oi  ON o.order_id   = oi.order_id
INNER JOIN products    pr  ON oi.product_id = pr.product_id
INNER JOIN payments    pay ON o.order_id   = pay.order_id
WHERE u.user_id = 1
ORDER BY o.order_id, pr.product_id;
```

Output (this is a **real, verified** result from the seed data):

| username | order_id | order_status | product_name | quantity | unit_price | payment_status | amount |
|---|---|---|---|---|---|---|---|
| arjun_k | 1 | DELIVERED | Galaxy Phone X | 1 | 45999.00 | SUCCESS | 49498.00 |
| arjun_k | 1 | DELIVERED | Wireless Earbuds | 1 | 3499.00 | SUCCESS | 49498.00 |
| arjun_k | 3 | SHIPPED | UltraBook Pro 14 | 1 | 89999.00 | SUCCESS | 89999.00 |
| arjun_k | 8 | DELIVERED | Galaxy Phone X | 1 | 45999.00 | SUCCESS | 45999.00 |

Notice `49498.00` appears **twice** — once for each line item of order 1. Hold that thought; it is the exact setup for the duplicate-row bug in §7.13.

### Line-by-Line Explanation (Example 3)

1. `FROM users u` — start with the driving table, aliased `u`.
2. `INNER JOIN orders o ON u.user_id = o.user_id` — for each user, attach every order they placed. A user with zero orders is dropped here (none exist in this seed — see §7.15).
3. `INNER JOIN order_items oi ON o.order_id = oi.order_id` — for each order, attach every line item. An order with 2 items produces 2 rows at this point (order 1 does exactly this).
4. `INNER JOIN products pr ON oi.product_id = pr.product_id` — enrich each line item with the product's name. This join is 1:1 from the `order_items` row's perspective (each line item references exactly one product), so it does not change the row count.
5. `INNER JOIN payments pay ON o.order_id = pay.order_id` — attach the one payment row per order. Also 1:1 from the order's perspective in this schema, so it does not change row count either — but it *repeats* the same payment values across however many line-item rows that order already produced.
6. `WHERE u.user_id = 1` — filters to one user, applied after all joins.

### What Happens Internally (preview)

Conceptually, the engine picks an order to execute these joins in (not necessarily left-to-right as written), and for each pair of tables it chooses one of three physical strategies: **nested loop join** (scan one side, probe the other per row — good for small/indexed lookups), **hash join** (build an in-memory hash table on one side's key, probe with the other — good for larger unsorted sets), or **merge join** (both inputs sorted on the key, walk them in lockstep — good when data is already sorted, e.g., by an index). The *logical* result is identical regardless of which physical strategy is chosen — this is the relational model's core guarantee. Chapter 17 (Query Execution & the Query Planner) covers this in full depth, including how to read `EXPLAIN ANALYZE` output to see which strategy PostgreSQL actually picked and why.

### Common Mistakes

- Forgetting the `ON` clause entirely, producing an accidental `CROSS JOIN` (in MySQL, `SELECT * FROM a, b` with no `WHERE` is a classic version of this bug).
- Joining on the wrong column that happens to have a compatible type (e.g., joining `order_items.order_id` to `products.product_id` — no syntax error, just wrong/empty results).
- Assuming `INNER JOIN` preserves row count 1:1 with the driving table — it does not, in either direction (rows can multiply *or* disappear).
- Using `INNER JOIN` when you actually need `LEFT JOIN` (e.g., "all users, whether or not they've ordered" — INNER silently drops the users with no orders).

### Edge Cases

- **NULL join keys never match.** If `orders.user_id` were `NULL` for some row (it can't be here — the column is `NOT NULL` — but consider a nullable FK elsewhere), that row would never satisfy `u.user_id = o.user_id` for any `u`, because `NULL = anything` evaluates to `UNKNOWN`, not `TRUE`. The row is silently excluded from an inner join, with no error.
- **Empty tables.** `INNER JOIN` against an empty table always yields zero rows, regardless of how many rows the other table has.
- **Self-join without aliasing** — covered fully in §7.8; using unqualified column names when both sides are the same table is ambiguous and will raise an error.

### When to Use / Not Use

- **Use** when a row is only meaningful in the presence of its counterpart — e.g., a `payments` row for an order that must have been placed.
- **Don't use** when you need to report on the *absence* of a relationship, or a full list regardless of whether a match exists (that's `LEFT JOIN`, §7.4).

### Compared to Other Joins

`INNER JOIN` is the intersection; `LEFT`/`RIGHT`/`FULL` are the intersection plus one or both sides' leftovers. An `INNER JOIN` is also exactly what a semi-join (§7.16) *conceptually* filters down to, except a semi-join never duplicates the left row even when there are multiple matches on the right.

### Real-World Use Cases

- Sales reports that only care about orders that were actually paid.
- Joining a fact table to dimension tables in a data warehouse (Chapter 31 revisits this as star-schema joins).
- Enforcing "only show fully-linked records" in any reporting layer.

---

## 7.4 LEFT JOIN (LEFT OUTER JOIN)

### Simple Explanation

**What I write:** `SELECT ... FROM users u LEFT JOIN orders o ON u.user_id = o.user_id`
**What the database logically does:** keep **every** row from `users` (the left table). For each one, attach matching `orders` rows if any exist; if none exist, attach a single row with all `orders` columns set to `NULL`.
**What result is produced:** all users, whether or not they've ordered — with order details filled in where available and `NULL` where not.

### Technical Explanation

`LEFT OUTER JOIN` (the `OUTER` keyword is optional and rarely written) computes the inner join, then **adds back** every unmatched row from the left table, padding the right table's columns with `NULL`. The left table's row count is a strict floor: every left row appears at least once in the output, no matter what.

### Why It Exists

Business questions are frequently about the *complete* population on one side, regardless of whether a related record exists — "list every product, with its review count if any," "list every employee, with their latest attendance record if any." `INNER JOIN` would silently drop the ones with no match; `LEFT JOIN` guarantees you never lose members of the left-hand set.

### Full Syntax

```sql
SELECT columns
FROM table_a a
LEFT [OUTER] JOIN table_b b
  ON a.key_column = b.key_column;
```

### Visual Diagram

```
Table: A (customers)          Table: B (orders)
+----+---------+              +----+-------------+
| id | name    |              | id | customer_id |
+----+---------+              +----+-------------+
| 1  | Alice   |              | 1  | 1           |
| 2  | Bob     |              | 2  | 1           |
| 3  | Carol   |              | 3  | 4           |
+----+---------+              +----+-------------+
```

`A LEFT JOIN B ON A.id = B.customer_id`:

```
+----+-------+------+-------------+
| id | name  | id   | customer_id |
+----+-------+------+-------------+
| 1  | Alice | 1    | 1           |   matched
| 1  | Alice | 2    | 1           |   matched
| 2  | Bob   | NULL | NULL        |   <- Bob preserved, right side padded with NULL
+----+-------+------+-------------+
```

Carol doesn't exist in this toy example (only Alice/Bob are in A), but note order 3 (`customer_id = 4`) is simply dropped because `LEFT JOIN` only guarantees the **left** table's rows survive — unmatched right-side rows are not shown by `LEFT JOIN` (that needs `RIGHT` or `FULL`).

### Real Schema Examples

**Example 1 — categories with product counts, including empty categories.**

```sql
SELECT c.category_id, c.category_name, p.product_id, p.product_name
FROM categories c
LEFT JOIN products p ON c.category_id = p.category_id
ORDER BY c.category_id;
```

Output (verified):

| category_id | category_name | product_id | product_name |
|---|---|---|---|
| 1 | Electronics | NULL | NULL |
| 2 | Mobiles | 1 | Galaxy Phone X |
| 2 | Mobiles | 2 | Pixel Lite |
| 2 | Mobiles | 9 | Wireless Earbuds |
| 3 | Laptops | 3 | UltraBook Pro 14 |
| 3 | Laptops | 4 | GameBook 15 |
| 3 | Laptops | 10 | Laptop Sleeve 14" |
| 4 | Fashion | NULL | NULL |
| 5 | Men | 5 | Men Cotton Shirt |
| 6 | Women | 6 | Women Kurta Set |
| 7 | Home & Kitchen | 7 | Non-stick Pan Set |
| 7 | Home & Kitchen | 8 | Electric Kettle |

`Electronics` and `Fashion` are top-level parent categories — no product is tagged to them *directly* (products are tagged to the subcategories `Mobiles`/`Laptops` and `Men`/`Women` instead). An `INNER JOIN` here would have silently dropped those two categories from the report entirely.

**Example 2 — departments and their projects, including departments with none:**

```sql
SELECT d.department_id, d.department_name, p.project_name
FROM departments d
LEFT JOIN projects p ON d.department_id = p.department_id
ORDER BY d.department_id;
```

Output (verified):

| department_id | department_name | project_name |
|---|---|---|
| 1 | Engineering | Platform Migration |
| 1 | Engineering | Mobile App Revamp |
| 2 | Sales | Q1 Sales Expansion |
| 3 | HR | Employee Wellness |
| 4 | Finance | NULL |
| 5 | Marketing | Brand Relaunch |

**Finance has zero projects** in the seed data — an `INNER JOIN` version of this query would simply omit the Finance row, which is a real bug class ("our department report is missing a department!").

### Line-by-Line Explanation (Example 2)

1. `FROM departments d` — the left/driving table; every row here is guaranteed to appear in the output.
2. `LEFT JOIN projects p ON d.department_id = p.department_id` — attach matching projects. Finance (`department_id = 4`) has no row in `projects` with that id, so it gets exactly one output row with `p.*` as `NULL`.
3. No `WHERE` clause — this matters enormously; see §7.11 for what happens the moment you add one carelessly.

### What Happens Internally (preview)

A `LEFT JOIN` is frequently implemented as a **hash join with an "outer" flag**: build a hash table on the right side's key, scan the left side, probe the hash table, and for any left row with zero probe hits, emit it once with nulls. Alternatively, for small inputs or when an index exists on the right key, the planner may pick a nested loop. Full mechanics and how to spot which one PostgreSQL chose live in Chapter 17.

### Common Mistakes

- Putting a filter on the right table's column in `WHERE` instead of `ON` — this is the single most common `LEFT JOIN` bug and gets its own full section: §7.11.
- Assuming `COUNT(right_table.column)` counts left rows — it doesn't; `COUNT()` on a specific column ignores `NULL`s, so unmatched left rows contribute 0, not 1, to that count. Use `COUNT(*)` if you want to count output rows, or `COUNT(DISTINCT left_table.pk)` if you want to count distinct left-side entities.
- Chaining several `LEFT JOIN`s and forgetting that a `NULL` produced by an early join will make every *subsequent* join on that column also fail to match (which is usually what you want — but you must design for it, especially when the second join condition itself references columns from the first `LEFT JOIN`ed table).

### Edge Cases

- **NULLs in the join key never match**, exactly as in INNER JOIN — but here it matters differently: a left-side `NULL` key means that row can *never* find a match, so it always appears padded with `NULL`s (as if it had no counterpart at all), even if some right-side row *also* has a `NULL` key (`NULL = NULL` is still `UNKNOWN`, not `TRUE`).
- **Empty right table** — every left row appears exactly once, entirely padded with `NULL`.
- **Empty left table** — the result is empty, full stop; there's nothing to preserve.

### When to Use / Not Use

- **Use** whenever the left-hand entity list must be complete regardless of match — "all customers," "all products," "all departments."
- **Don't use** it and then forget to handle the resulting `NULL`s in aggregates/`WHERE` — that's the #1 source of the "silently becomes INNER JOIN" bug (§7.11).

### Compared to Other Joins

`LEFT JOIN table_b` is exactly equivalent to `RIGHT JOIN table_a` with the table order swapped — the two are mirror images (§7.5). `LEFT JOIN ... WHERE right.key IS NULL` is the standard anti-join idiom (§7.15).

### Real-World Use Cases

- "Users who signed up but have not ordered" style dashboards (start from `LEFT JOIN`, then optionally filter to the anti-join case).
- Building a denormalized report table where some dimension is genuinely optional (e.g., not every order might yet have a payment recorded).
- Data-quality audits: "which rows in table A have no corresponding row in table B?"

---

## 7.5 RIGHT JOIN (RIGHT OUTER JOIN)

### Simple Explanation

**What I write:** `SELECT ... FROM products p RIGHT JOIN categories c ON p.category_id = c.category_id`
**What the database logically does:** keep every row from `categories` (the right table) this time; attach matching `products` rows, or `NULL` if none exist.
**What result is produced:** the mirror image of a `LEFT JOIN` with the table order flipped.

### Technical Explanation

`RIGHT OUTER JOIN` is defined identically to `LEFT OUTER JOIN` but with the roles of the two tables reversed: it guarantees every row of the *right* table appears at least once, padding the *left* table's columns with `NULL` for unmatched rows.

### Why It Exists

Purely for convenience/readability — anything expressible with `RIGHT JOIN` is expressible with `LEFT JOIN` by swapping the `FROM`/`JOIN` table order. It exists so you can keep a natural reading order ("start from the table I already established with `FROM` earlier in a long query, and *now* right-join in something else") without restructuring the whole query.

### Full Syntax

```sql
SELECT columns
FROM table_a a
RIGHT [OUTER] JOIN table_b b
  ON a.key_column = b.key_column;
```

### Visual Diagram

```
Table: A (orders)              Table: B (customers)
+----+-------------+           +----+---------+
| id | customer_id |           | id | name    |
+----+-------------+           +----+---------+
| 1  | 1           |           | 1  | Alice   |
| 2  | 4           |           | 2  | Bob     |
+----+-------------+           +----+---------+
```

`A RIGHT JOIN B ON A.customer_id = B.id`:

```
+------+-------------+----+-------+
| id   | customer_id | id | name  |
+------+-------------+----+-------+
| 1    | 1           | 1  | Alice |   matched
| NULL | NULL        | 2  | Bob   |   <- Bob preserved (right table), left side padded
+------+-------------+----+-------+
```

Order 2 (`customer_id = 4`, no matching customer) disappears — `RIGHT JOIN` only guarantees the right table's rows.

### Real Schema Examples

**Example — the exact mirror of the LEFT JOIN category example, proving the equivalence.**

```sql
SELECT c.category_id, c.category_name, p.product_id, p.product_name
FROM products p
RIGHT JOIN categories c ON p.category_id = c.category_id
ORDER BY c.category_id;
```

Output is **identical** to the `LEFT JOIN` version in §7.4 (verified) — same 12 rows, same `NULL`s for `Electronics` (1) and `Fashion` (4):

| category_id | category_name | product_id | product_name |
|---|---|---|---|
| 1 | Electronics | NULL | NULL |
| 2 | Mobiles | 1 | Galaxy Phone X |
| 2 | Mobiles | 2 | Pixel Lite |
| 2 | Mobiles | 9 | Wireless Earbuds |
| 3 | Laptops | 3 | UltraBook Pro 14 |
| 3 | Laptops | 4 | GameBook 15 |
| 3 | Laptops | 10 | Laptop Sleeve 14" |
| 4 | Fashion | NULL | NULL |
| 5 | Men | 5 | Men Cotton Shirt |
| 6 | Women | 6 | Women Kurta Set |
| 7 | Home & Kitchen | 7 | Non-stick Pan Set |
| 7 | Home & Kitchen | 8 | Electric Kettle |

`products p RIGHT JOIN categories c ON ...` and `categories c LEFT JOIN products p ON ...` are exactly the same query with the tables swapped — the same set of rows, same `NULL` placements.

### Line-by-Line Explanation

1. `FROM products p` — this table's rows are *not* guaranteed to survive.
2. `RIGHT JOIN categories c ON p.category_id = c.category_id` — this table's rows *are* guaranteed to survive; categories 1 and 4 have no matching product row, so `p.*` is padded with `NULL`.

### What Happens Internally (preview)

Most query planners, including PostgreSQL's, will often internally normalize a `RIGHT JOIN` by simply swapping the join inputs and executing it as a `LEFT JOIN` — the two are logically identical, so there's no separate "right join" execution strategy distinct from what's described in §7.17.

### Common Mistakes

- Writing a long chain of joins and using `RIGHT JOIN` in the middle — this is a well-known readability trap: everyone has to mentally track which table is "kept" at each step, and mixing `LEFT`/`RIGHT` in the same query makes that much harder than always using `LEFT JOIN` and choosing table order accordingly.
- Assuming `RIGHT JOIN` "adds more data" than `LEFT JOIN` in some general sense — it doesn't; it depends entirely on which table you name as the anchor.

### Edge Cases

Identical to `LEFT JOIN`'s edge cases, mirrored: NULL keys never match; an empty left table produces a fully-`NULL`-padded row per right row; an empty right table produces zero rows.

### When to Use / Not Use

- **Use** rarely, and mostly for readability in one specific case: when you've already built up a long `FROM`/`JOIN` chain anchored on table A, and you realize late that table Z (not A) is the one whose full population you need to preserve — `RIGHT JOIN` avoids restructuring the whole `FROM` clause.
- **Don't use** it as a habit. The overwhelming style convention in production SQL (and in this course going forward) is: **always prefer `LEFT JOIN` and put the "must-keep" table first.** Style guides at most companies flag `RIGHT JOIN` in code review specifically because of the readability cost above.

### Compared to Other Joins

`A RIGHT JOIN B` ≡ `B LEFT JOIN A` (with the selected columns re-ordered if needed) — a strict mechanical equivalence, always.

### Real-World Use Cases

Genuinely rare in hand-written production SQL for the readability reason above, but it appears frequently in **generated SQL** (ORMs, BI tools) that always emit tables in a fixed order and pick the join direction programmatically.

> **⚠️ Warning**
> Some engines historically had subtly different `RIGHT JOIN` optimizer behavior than `LEFT JOIN` for the equivalent query. Always verify with `EXPLAIN` if performance seems to differ between the two forms of the same logical query — see Chapter 17.

---

## 7.6 FULL OUTER JOIN

### Simple Explanation

**What I write:** `SELECT ... FROM a FULL OUTER JOIN b ON a.key = b.key`
**What the database logically does:** keep every row from **both** tables. Where a match exists, combine them. Where a left row has no right match, pad the right columns with `NULL`. Where a right row has no left match, pad the left columns with `NULL`.
**What result is produced:** the union of everything `LEFT JOIN` would show and everything `RIGHT JOIN` would show, with true matches counted only once.

### Technical Explanation

`FULL OUTER JOIN` = `LEFT OUTER JOIN` ∪ (the rows `RIGHT OUTER JOIN` would add that aren't already covered by matched pairs). Formally: it is the inner join, plus unmatched left rows padded with right-`NULL`s, plus unmatched right rows padded with left-`NULL`s.

### Why It Exists

Some questions genuinely need to see gaps **on both sides** at once — reconciliation problems: "which of my records in system A have no counterpart in system B, *and* which records in system B have no counterpart in system A?" That's a single, symmetric question that neither `LEFT` nor `RIGHT` alone can answer in one query.

### Full Syntax

```sql
SELECT columns
FROM table_a a
FULL [OUTER] JOIN table_b b
  ON a.key_column = b.key_column;
```

### Visual Diagram

```
Table: A                      Table: B
+----+------+                 +----+------+
| id | val  |                 | id | val  |
+----+------+                 +----+------+
| 1  | a1   |                 | 1  | b1   |
| 2  | a2   |                 | 3  | b3   |
+----+------+                 +----+------+
```

`A FULL OUTER JOIN B ON A.id = B.id`:

```
+------+------+------+------+
| id   | val  | id   | val  |
+------+------+------+------+
| 1    | a1   | 1    | b1   |   matched
| 2    | a2   | NULL | NULL |   <- A's unmatched row, B padded
| NULL | NULL | 3    | b3   |   <- B's unmatched row, A padded
+------+------+------+------+
```

### Real Schema Examples

Because foreign keys enforce referential integrity in both `ecommerce_db` and `company_db`, a **child** row (the "many" side of a 1:N relationship, e.g., `products.category_id → categories.category_id`) can never be "orphaned" — it is guaranteed by the FK to always match some parent row. That means in FK-backed parent↔child joins, unmatched rows can only ever appear on the **parent** side (a category with no products), never on the child side. This is itself an important, real lesson about `FULL OUTER JOIN`:

> **Important Note**
> `FULL OUTER JOIN`'s "unmatched on both sides" behavior is only interesting when **both** tables can independently have rows with no counterpart. A straightforward parent/child FK relationship will only ever show gaps on the parent side — for those, `LEFT JOIN` already tells you everything `FULL OUTER JOIN` would. To see genuine two-sided gaps, you need either two tables that are *not* directly FK-linked, or a self-join where the same table plays two different roles.

The `categories` table gives us exactly that second case for free, because it self-references (`parent_category_id → categories.category_id`), and a category can independently be "a child with no listed parent" *and* "a parent that nobody lists" at the same time:

```sql
SELECT c.category_id  AS child_id,   c.category_name AS child_name,
       p.category_id  AS parent_id,  p.category_name AS parent_name
FROM categories c
FULL OUTER JOIN categories p ON c.parent_category_id = p.category_id
ORDER BY c.category_id, p.category_id;
```

Output (verified — 12 rows total from only 7 source rows):

| child_id | child_name | parent_id | parent_name |
|---|---|---|---|
| NULL | NULL | 2 | Mobiles |
| NULL | NULL | 3 | Laptops |
| NULL | NULL | 5 | Men |
| NULL | NULL | 6 | Women |
| NULL | NULL | 7 | Home & Kitchen |
| 1 | Electronics | NULL | NULL |
| 2 | Mobiles | 1 | Electronics |
| 3 | Laptops | 1 | Electronics |
| 4 | Fashion | NULL | NULL |
| 5 | Men | 4 | Fashion |
| 6 | Women | 4 | Fashion |
| 7 | Home & Kitchen | NULL | NULL |

### Line-by-Line Explanation

1. **4 matched pairs** (`Mobiles`→`Electronics`, `Laptops`→`Electronics`, `Men`→`Fashion`, `Women`→`Fashion`) — real parent/child links.
2. **3 unmatched-child rows** (`child_id` populated, `parent_id` NULL): `Electronics`, `Fashion`, `Home & Kitchen` — these are the three top-level categories whose own `parent_category_id` is `NULL`, so scanning for a matching parent finds nothing.
3. **5 unmatched-parent rows** (`child_id` NULL, `parent_id` populated): `Mobiles`, `Laptops`, `Men`, `Women`, `Home & Kitchen` — these are the five **leaf** categories that are never listed as anyone else's parent, so when the engine scans for "does any child point to this category as its parent," it finds nothing.

Notice `Home & Kitchen` (category 7) appears in **both** groups — once as an unmatched child (row: `7, Home & Kitchen, NULL, NULL`), and once as an unmatched parent (row: `NULL, NULL, 7, Home & Kitchen`). That is not a duplicate or a bug: they are two genuinely different facts ("category 7 has no parent" and "nothing is a child of category 7"), and `FULL OUTER JOIN` is precisely the tool that surfaces both simultaneously.

### What Happens Internally (preview)

A common physical strategy is a **hash full join**: build a hash table on one side, probe with the other while marking each hash-table entry as "consumed" whenever it's matched, then at the end emit every unconsumed entry padded with `NULL` (this handles the unmatched-right-side rows), in addition to the unmatched-left-side rows found during the main probe phase. A **merge full join** (both sides pre-sorted) is the other common strategy, walking both streams and emitting unmatched runs from either side directly. Chapter 17 covers the mechanics of choosing between these.

### Common Mistakes

- Assuming `FULL OUTER JOIN` is available everywhere — see the **[MySQL]** dialect note below; it is not, and needs a workaround.
- Forgetting to `COALESCE()` the two sides' key columns when you need a single unified key column in the output (e.g., `COALESCE(c.category_id, p.category_id) AS category_id` above) — otherwise you have two half-`NULL` id columns instead of one clean one.
- Using `FULL OUTER JOIN` where a plain `LEFT JOIN` would already answer the question (as discussed above, this happens whenever one side is FK-guaranteed never to be orphaned) — needless extra planner work for identical results.

### Edge Cases

- If **both tables are empty**, the result is empty.
- If **one table is empty**, `FULL OUTER JOIN` degenerates into "every row of the other table, fully NULL-padded" — logically identical to what a `LEFT JOIN`/`RIGHT JOIN` against an empty table would already produce.
- **NULL join keys**: a row whose join-key value is `NULL` never matches anything from the other side (as always), so it always appears in its own "unmatched" half of the result — this is exactly how `Electronics`/`Fashion`/`Home & Kitchen` end up as unmatched children above (their `parent_category_id` is literally `NULL`).

### When to Use / Not Use

- **Use** for reconciliation: comparing two independently-populated sets and wanting to see every discrepancy in either direction in one result set.
- **Don't use** it as a default "safe" join — it's more expensive than it needs to be when you already know only one side can have gaps (use `LEFT`/`RIGHT` instead), and it is not portable to older MySQL without a rewrite.

### Compared to Other Joins

`FULL OUTER JOIN` = `LEFT JOIN` + the extra unmatched-right rows that `RIGHT JOIN` would have added. If you filter a `FULL OUTER JOIN` result down to `WHERE a.key IS NULL OR b.key IS NULL`, you get a "symmetric anti-join" — everything that fails to reconcile on either side.

### Real-World Use Cases

- Reconciling two data sources during a migration (e.g., "which records exist in the old system but not the new one, and vice versa").
- Comparing this month's product catalog snapshot to last month's to find additions and removals in one query.
- The category self-join example above: auditing a hierarchy for orphaned parents/children.

> **[MySQL] ⚠️ Warning**
> MySQL (through at least 8.0) does **not** support `FULL OUTER JOIN` syntax. The standard workaround is a `UNION` of a `LEFT JOIN` and a `RIGHT JOIN`, using `UNION` (not `UNION ALL`) to deduplicate the matched rows that both halves would otherwise produce twice, or explicitly filtering the right-join half to only its unmatched rows:
>
> ```sql
> -- [MySQL] FULL OUTER JOIN workaround
> SELECT c.category_id AS child_id, c.category_name AS child_name,
>        p.category_id AS parent_id, p.category_name AS parent_name
> FROM categories c
> LEFT JOIN categories p ON c.parent_category_id = p.category_id
> UNION
> SELECT c.category_id, c.category_name, p.category_id, p.category_name
> FROM categories c
> RIGHT JOIN categories p ON c.parent_category_id = p.category_id;
> ```
>
> `UNION` (not `UNION ALL`) is essential here — it deduplicates the rows that are matched (and therefore appear identically in both the `LEFT JOIN` and `RIGHT JOIN` halves), leaving only one copy of each matched pair plus both sets of unmatched rows.

> **[Oracle]** Oracle supports standard `FULL OUTER JOIN` syntax. It also has a legacy Oracle-only outer-join operator, `(+)`, used in the `WHERE` clause of pre-ANSI-92 Oracle SQL (e.g., `WHERE a.id = b.id(+)` for a left outer join). You will still encounter this in older Oracle codebases; it cannot express a full outer join at all (only left or right), which is one of several reasons Oracle itself recommends migrating to ANSI `JOIN` syntax.

> **[SQL Server]** Supports standard `FULL OUTER JOIN` — no workaround needed.

---

## 7.7 CROSS JOIN

### Simple Explanation

**What I write:** `SELECT ... FROM a CROSS JOIN b`
**What the database logically does:** pair every row of `a` with every row of `b`, with no condition at all.
**What result is produced:** `(rows in a) × (rows in b)` rows — the full Cartesian product.

### Technical Explanation

`CROSS JOIN` is the relational algebra Cartesian product itself, with no restriction predicate applied. It takes no `ON` clause (providing one is a syntax error in most dialects, since there is no condition to evaluate — PostgreSQL and MySQL do allow `CROSS JOIN ... ON true` as a degenerate case, but plain `CROSS JOIN` never takes `ON`). Every other join type in this chapter can be described as "cross join, then filter by the join predicate" — `CROSS JOIN` is that first step with the filter step skipped entirely.

### Why It Exists

Most of the time you don't want it directly — but it's essential for **generating combinations**: building a complete report grid, a calendar of dates × stores, or a matrix of all possible category × warehouse combinations for capacity planning, where you want every combination to appear (with zero-fill) even if no data exists for it yet.

### Full Syntax

```sql
SELECT columns
FROM table_a a
CROSS JOIN table_b b;

-- equivalent legacy comma-join form (works in PostgreSQL/MySQL/Oracle/SQL Server):
SELECT columns FROM table_a a, table_b b;
```

> **⚠️ Warning**
> The comma-join form (`FROM a, b`) is how most **accidental** cross joins happen in production: someone lists two tables in `FROM` separated by a comma intending to join them, forgets the `WHERE a.key = b.key` filter, and gets a full Cartesian product silently — no error, just a result set that's `(rows in a) × (rows in b)` rows too large, possibly returning what looks like plausible-but-wrong data. Prefer explicit `JOIN ... ON` syntax everywhere; it makes a missing condition a glaring, visible gap in the SQL text instead of an invisible omission.

### Visual Diagram

```
Table: A (sizes)     Table: B (colors)
+-------+            +--------+
| size  |            | color  |
+-------+            +--------+
| S     |            | Red    |
| M     |            | Blue   |
+-------+            +--------+
```

`A CROSS JOIN B`:

```
+------+-------+
| size | color |
+------+-------+
| S    | Red   |
| S    | Blue  |
| M    | Red   |
| M    | Blue  |
+------+-------+
```

2 sizes × 2 colors = 4 rows — every combination, whether or not it's a real product variant yet.

### Real Schema Examples

**Example — building a dense payment-method × order-status report grid**, so that combinations that never actually occurred still show up as `0` instead of being silently missing from the report:

```sql
SELECT pm.payment_method, os.status, COUNT(*) AS combo_count
FROM (SELECT DISTINCT payment_method FROM payments) pm
CROSS JOIN (SELECT DISTINCT status FROM orders) os
LEFT JOIN (
    SELECT o.status, p.payment_method
    FROM orders o JOIN payments p ON o.order_id = p.order_id
) actual ON actual.payment_method = pm.payment_method AND actual.status = os.status
GROUP BY pm.payment_method, os.status
ORDER BY pm.payment_method, os.status;
```

The `CROSS JOIN` here produces exactly **25 rows** (5 distinct payment methods × 5 distinct order statuses in the seed data — `CARD, UPI, NETBANKING, COD, WALLET` × `DELIVERED, SHIPPED, PAID, CANCELLED, PENDING`), guaranteeing the report has a row for every combination, whether or not it actually occurred (verified: `COUNT(*) FROM (5 methods) CROSS JOIN (5 statuses)` = 25).

### Line-by-Line Explanation

1. Two subqueries produce the distinct "axis" values for the grid: 5 payment methods, 5 order statuses.
2. `CROSS JOIN` between them produces every combination — 25 rows, unconditionally.
3. The `LEFT JOIN` back to actual order/payment data fills in real counts where they exist and `NULL`/0 (after `COUNT`) elsewhere — this is `CROSS JOIN` used specifically to guarantee grid completeness before enrichment.

### What Happens Internally (preview)

Physically, a `CROSS JOIN` is almost always executed as a **nested loop with no filter**: for every row on one side, emit a combined row for every row on the other side. There is nothing to hash or sort against, since there's no predicate — it's the one join type where nested loop is essentially always the only sensible strategy regardless of table size (though the planner will still choose which side to iterate as the outer loop for memory/row-count reasons).

### Common Mistakes

- Writing `FROM a, b` and forgetting the `WHERE` filter that was supposed to make it an inner join — the classic accidental cross join.
- Cross-joining two large tables by mistake (e.g., 10,000 rows × 10,000 rows = 100,000,000 rows) — this can exhaust memory or run for a very long time; always sanity-check row-count math before running an intentional cross join against real-sized tables.

### Edge Cases

- If **either** table is empty, the cross join result is empty (0 × N = 0), even though the intuition "cross join always keeps everything" might suggest otherwise — an empty side means there's nothing to pair anything with.
- `CROSS JOIN` never produces `NULL`-padded rows — there's no concept of "unmatched" since every pairing is automatically kept.

### When to Use / Not Use

- **Use** deliberately for combination-generation: report grids, calendars, all-possible-pairs setups, generating test data.
- **Don't use** it (even accidentally) between two tables of real business-entity rows unless you specifically intend every combination — it is almost never the right join for combining "related" data.

### Compared to Other Joins

Every other join in this chapter is a `CROSS JOIN` with a predicate applied afterward. If you write `INNER JOIN table_b ON true` (an always-true condition), you have written a `CROSS JOIN` by another name — some query linters flag this specifically.

### Real-World Use Cases

- Generating a full calendar-day table for time-series reports (`CROSS JOIN` a list of dates with a list of stores/products).
- Building an empty pivot-table shell before filling in real aggregates, as shown above.
- Test/demo data generation (all combinations of a small set of dimensions).

---

## 7.8 SELF JOIN

### Simple Explanation

**What I write:** `SELECT ... FROM employees e JOIN employees m ON e.manager_id = m.employee_id`
**What the database logically does:** treat the *same* table as if it were two independent tables — one playing the role "employee," the other playing the role "their manager" — and join them exactly like any two-table join.
**What result is produced:** each employee row paired with the row representing their manager (a different row in the *same underlying table*).

### Technical Explanation

A self-join is not a distinct join *type* — it's any `INNER`/`LEFT`/`RIGHT`/`FULL` join where both sides of the `FROM`/`JOIN` reference the same base table. Because SQL requires every column reference to be unambiguous, a self-join is **only legal with aliasing**: you must give each occurrence of the table a distinct alias so the engine (and the reader) can tell which "copy" a column reference belongs to.

### Why It Exists

Some relationships are *hierarchical or peer-to-peer within a single entity type*: an employee's manager is also an employee; a category's parent is also a category. Rather than needing a separate `managers` lookup table for every such relationship, a self-referencing foreign key plus a self-join expresses it directly and keeps the schema normalized (see `employees.manager_id → employees.employee_id` and `categories.parent_category_id → categories.category_id`).

### Full Syntax

```sql
SELECT columns
FROM table_x a
JOIN table_x b     -- SAME table, different alias
  ON a.some_column = b.other_column
 AND a.employee_id <> b.employee_id;   -- often needed to exclude "self-paired-with-self"
```

### Visual Diagram

```
Table: employees (single table, two roles)
+----+--------+------------+
| id | name   | manager_id |
+----+--------+------------+
| 1  | Aditi  | NULL       |
| 2  | Rahul  | 1          |
| 3  | Sneha  | 2          |
+----+--------+------------+
```

`employees e LEFT JOIN employees m ON e.manager_id = m.employee_id`:

```
+----+-------+------------+----+-------+
| id | name  | manager_id | id | name  |   <- "id"/"name" on the right = the manager's row
+----+-------+------------+----+-------+
| 1  | Aditi | NULL       |NULL| NULL  |   Aditi has no manager (LEFT JOIN preserves her)
| 2  | Rahul | 1          | 1  | Aditi |   Rahul's manager is Aditi
| 3  | Sneha | 2          | 2  | Rahul |   Sneha's manager is Rahul
+----+-------+------------+----+-------+
```

### Real Schema Examples

**Example 1 — every employee with their manager's name (LEFT JOIN self-join — the CTO has no manager):**

```sql
SELECT e.employee_id, e.first_name || ' ' || e.last_name AS employee, e.job_title,
       m.first_name || ' ' || m.last_name AS manager
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.employee_id
ORDER BY e.employee_id;
```

Output (verified, all 16 rows):

| employee_id | employee | job_title | manager |
|---|---|---|---|
| 1 | Aditi Rao | CTO | NULL |
| 2 | Rahul Mehta | Engineering Manager | Aditi Rao |
| 3 | Sneha Kulkarni | Senior Engineer | Rahul Mehta |
| 4 | Vikram Joshi | Software Engineer | Rahul Mehta |
| 5 | Ananya Singh | Software Engineer | Rahul Mehta |
| 6 | Karan Verma | Junior Engineer | Sneha Kulkarni |
| 7 | Priya Nair | Sales Manager | Aditi Rao |
| 8 | Arjun Das | Sales Executive | Priya Nair |
| 9 | Meera Pillai | Sales Executive | Priya Nair |
| 10 | Rohan Kapoor | HR Manager | Aditi Rao |
| 11 | Isha Bhatt | HR Executive | Rohan Kapoor |
| 12 | Nikhil Gupta | Finance Manager | Aditi Rao |
| 13 | Divya Shah | Accountant | Nikhil Gupta |
| 14 | Rajesh Iyer | Marketing Manager | Aditi Rao |
| 15 | Pooja Reddy | Marketing Executive | Rajesh Iyer |
| 16 | Aman Chawla | Software Engineer | Rahul Mehta |

Notice **Aditi Rao (employee 1, CTO) has `manager = NULL`.** This is the correct, expected result: her `manager_id` column is genuinely `NULL` (she reports to no one), so the join finds no match — the `LEFT JOIN` preserves her row anyway, padded with `NULL` on the "manager" side.

**Example 2 — a two-level self-join (grandmanager):** for Karan Verma (employee 6):

```sql
SELECT e.first_name AS employee, m.first_name AS manager, gm.first_name AS grandmanager
FROM employees e
LEFT JOIN employees m  ON e.manager_id = m.employee_id
LEFT JOIN employees gm ON m.manager_id = gm.employee_id
WHERE e.employee_id = 6;
```

Output (verified):

| employee | manager | grandmanager |
|---|---|---|
| Karan | Sneha | Rahul |

Three roles, one underlying table, three aliases (`e`, `m`, `gm`).

**Example 3 — peer self-join (non-hierarchical): employees who share the same manager as each other** (manager_id = 2, Rahul's team):

```sql
SELECT e1.first_name AS colleague_1, e2.first_name AS colleague_2, e1.manager_id
FROM employees e1
JOIN employees e2
  ON e1.manager_id = e2.manager_id
 AND e1.employee_id < e2.employee_id     -- avoids (A,B) AND (B,A) duplicates, and A paired with itself
WHERE e1.manager_id = 2
ORDER BY e1.employee_id, e2.employee_id;
```

Output (verified, Rahul manages Sneha(3), Vikram(4), Ananya(5), Aman(16) — 4 people → C(4,2) = 6 unique pairs):

| colleague_1 | colleague_2 | manager_id |
|---|---|---|
| Sneha | Vikram | 2 |
| Sneha | Ananya | 2 |
| Sneha | Aman | 2 |
| Vikram | Ananya | 2 |
| Vikram | Aman | 2 |
| Ananya | Aman | 2 |

### Line-by-Line Explanation (Example 3)

1. `FROM employees e1 JOIN employees e2` — the same table, two roles, two mandatory aliases.
2. `ON e1.manager_id = e2.manager_id` — the actual relationship: "same manager."
3. `AND e1.employee_id < e2.employee_id` — **critical.** Without this, every employee would match themselves (`e1.manager_id = e2.manager_id` is trivially true when `e1` and `e2` are the same row), and every real pair would appear twice, once as `(A, B)` and once as `(B, A)`. The `<` inequality both excludes self-pairing and de-duplicates symmetric pairs in one stroke.

### What Happens Internally (preview)

There is nothing physically special about a self-join — the engine has no notion that "both sides happen to be the same table." It is executed with the same nested-loop/hash-join/merge-join strategies as any two-table join (§7.17), just against two logically independent scans (or one scan materialized twice) of the same underlying storage.

### Common Mistakes

- **Forgetting to alias**, e.g. writing `SELECT manager_id, employee_id FROM employees JOIN employees ON manager_id = employee_id` — this fails outright with an ambiguous-table or "table name specified more than once" error in every mainstream dialect. You must alias both occurrences.
- Forgetting the self-pairing/duplicate-pairing guard (`e1.employee_id <> e2.employee_id` or `<`) in peer-comparison self-joins, producing nonsensical "employee paired with themselves" rows or double-counted symmetric pairs.
- Using `INNER JOIN` for a manager lookup when some rows (like the CTO) have `NULL` in the self-referencing FK — this silently drops the top of the hierarchy from the result. Use `LEFT JOIN` unless you specifically want to exclude people with no manager.

### Edge Cases

- **The root of a hierarchy** (`manager_id IS NULL`) can never match anything in an `INNER` self-join — it must be a `LEFT JOIN` to appear at all, as shown in Example 1.
- **Self-join without proper aliasing** is not just bad style — in every dialect covered here it is a hard syntax/semantic error, not merely ambiguous-but-legal.
- Multi-level hierarchies of arbitrary, unknown depth (e.g., "give me the entire chain from an employee up to the CTO, no matter how many levels") **cannot** be solved by chaining a fixed number of self-joins — you'd need to know the maximum depth in advance. That general case is solved by a **recursive CTE**, covered fully in Chapter 9.

### When to Use / Not Use

- **Use** for a fixed, known number of hierarchy levels ("employee + manager," "employee + manager + grandmanager") or for peer comparisons within the same table.
- **Don't use** repeated self-joins to walk an arbitrarily deep hierarchy — that doesn't scale to unknown depth and is exactly what recursive CTEs exist for (Chapter 9 revisits this exact `employees`/`manager_id` table for that purpose).

### Compared to Other Joins

A self-join uses the same `INNER`/`LEFT`/`RIGHT`/`FULL` semantics already covered — "self-join" describes *what the two tables are* (the same one), not a new kind of matching logic.

### Real-World Use Cases

- Organizational hierarchies (this exact `employees.manager_id` pattern).
- Category/product taxonomies (`categories.parent_category_id`, used throughout §7.6-7.7).
- "Find duplicate or near-duplicate rows" audits (self-join on a business key to find rows with the same natural key but different surrogate keys).
- Peer/cohort comparisons: "employees in the same department hired within 30 days of each other," "products in the same category priced within 10% of each other."

---

## 7.9 NATURAL JOIN — and Why You Should Avoid It in Production

### Simple Explanation

**What I write:** `SELECT * FROM orders NATURAL JOIN payments`
**What the database logically does:** automatically find **every column name that exists in both tables**, and join on the equality of *all* of them simultaneously — with no way for you to specify which columns that should be.
**What result is produced:** whatever falls out of matching on that automatically-discovered column set — which may not be the column set you intended at all.

### Technical Explanation

`NATURAL JOIN` performs an equi-join on the set of columns that have **identical names** in both tables (and, in the strict SQL standard, also compatible types), collapsing them into single output columns and requiring no `ON`/`USING` clause. It behaves like `INNER JOIN` by default (`NATURAL LEFT JOIN`, `NATURAL RIGHT JOIN`, and `NATURAL FULL JOIN` are also legal in dialects that support the keyword).

### Why It Exists

It exists to save typing when two tables share a single, obviously-correct join key with an identical name on both sides (e.g., both using `department_id`). In principle it also documents intent nicely for very small, stable schemas. In practice, it trades a small amount of typing for a large, silent risk — which is the entire point of this section.

### Full Syntax

```sql
SELECT columns
FROM table_a
NATURAL [INNER | LEFT | RIGHT | FULL] JOIN table_b;
-- no ON clause is permitted — the column set is determined implicitly
```

### Visual Diagram

```
Table: A                    Table: B
+----+------+               +----+--------+
| id | name |               | id | amount |
+----+------+               +----+--------+
| 1  | X    |               | 1  | 100    |
| 2  | Y    |               | 3  | 300    |
+----+------+               +----+--------+
```

`A NATURAL JOIN B` — shared column is `id`:

```
+----+------+--------+
| id | name | amount |
+----+------+--------+
| 1  | X    | 100    |
+----+------+--------+
```

This looks harmless — until a second shared column name appears that you didn't intend as part of the key.

### The Danger, Demonstrated With Real Seed Data

`orders` and `payments` both happen to have a column literally named **`status`** — but they mean completely different things: `orders.status` is one of `PENDING/PAID/SHIPPED/DELIVERED/CANCELLED`, while `payments.status` is one of `PENDING/SUCCESS/FAILED/REFUNDED`. Both tables also share `order_id`. A `NATURAL JOIN` between them will silently join on **both** `order_id` AND `status` together — because `NATURAL JOIN` matches on *every* identically-named column, with no way to tell it "only use `order_id`."

```sql
SELECT * FROM orders NATURAL JOIN payments;
```

Verified output — **only one row survives**, out of 10 orders that all have a corresponding payment:

| order_id | user_id | order_date | status | shipping_address | payment_id | payment_date | amount | payment_method |
|---|---|---|---|---|---|---|---|---|
| 7 | 6 | 2024-02-03 19:20:00 | PENDING | 21 Hill Rd, Chennai | 7 | NULL | 6998.00 | COD |

Compare with the correct, explicit join:

```sql
SELECT COUNT(*) FROM orders o JOIN payments p ON o.order_id = p.order_id;
-- 10
```

**What happened:** order 7's `orders.status` is `'PENDING'` and its `payments.status` is *also* `'PENDING'` — purely by coincidence, both string values match, so this one pair survives the implicit `AND status = status` condition that `NATURAL JOIN` silently added. Every other order — including order 1, whose `orders.status = 'DELIVERED'` and `payments.status = 'SUCCESS'` never match as strings — is **dropped entirely**, even though `order_id` matches perfectly. The correct data (9 out of 10 orders' payment records) simply vanishes, with no error, warning, or any other signal that anything went wrong.

> **⚠️ Warning — Why NATURAL JOIN is dangerous in production**
> The failure mode above is **schema-fragile**, not just "you have to be careful once." `NATURAL JOIN` re-evaluates which columns to join on *every time the query runs*, based on whatever columns currently exist. This means:
> - **A query that works correctly today can silently break the day someone adds a column.** If a future migration adds a `notes` column to *both* `orders` and `payments` for unrelated reasons, any existing `NATURAL JOIN` between them silently starts also requiring `notes` to match — with zero code change to the query itself and zero warning from the database.
> - There is **no error, no warning, and no obvious symptom** — just quietly wrong (usually *fewer*) rows, exactly like the `orders`/`payments` example above, where a working-looking query returns 1 row instead of 10.
> - It is essentially impossible to code-review safely: reviewing `NATURAL JOIN orders o, payments p` tells you nothing about which columns it actually joins on without separately checking both tables' current column lists.
> - **Recommendation for this course, and for production code in general: never use `NATURAL JOIN`. Always write explicit `ON` (or, when column names genuinely and permanently match and you're certain no future column could collide, `USING`) so the join key is visible directly in the query text and stable regardless of future schema changes.**

### Line-by-Line Explanation

1. `FROM orders NATURAL JOIN payments` — no `ON`/`USING` is written or even permitted; the engine inspects both tables' column lists at parse time.
2. It finds two identically-named columns: `order_id` and `status`.
3. It joins on `orders.order_id = payments.order_id AND orders.status = payments.status` — the second condition was never intended by whoever wrote this query, and is completely invisible in the query text.

### What Happens Internally (preview)

Once the engine has resolved the implicit column list, execution proceeds exactly like any other equi-join (nested loop / hash / merge — §7.17). The danger is entirely at the semantic/planning layer (which columns get chosen), not the execution layer.

### Common Mistakes

- Using `NATURAL JOIN` on any table pair where either table might ever have more than one shared column name, now or in the future — which, as shown, is essentially every real production table pair.
- Assuming `NATURAL JOIN` and `JOIN ... USING (shared_key)` are equivalent — `USING` at least lets you name and see the intended key column(s) directly in the query; `NATURAL JOIN` never shows you the key at all.
- Relying on `SELECT *` alongside `NATURAL JOIN`, compounding the danger — you also can't easily tell from the output which physical columns are even present, since `NATURAL JOIN` collapses the shared columns into single unlabeled-by-source output columns.

### Edge Cases

- If the two tables share **zero** column names, `NATURAL JOIN` degenerates into a `CROSS JOIN` (§7.7) — another silent, unannounced behavior change if a shared column is ever renamed or dropped.
- If the two tables share **only** the intended key column today, the query "looks correct" and passes all current tests — right up until a future migration adds another shared name.

### When to Use / Not Use

- **Use:** essentially never, in production. It may appear in textbooks/tutorials for brevity, or in truly one-off, throwaway, hand-verified ad hoc queries against a schema you have fully memorized in the moment — even then, prefer `USING` or explicit `ON` out of habit.
- **Don't use** it in application code, views, stored procedures, ETL pipelines, or anything that will be run again after the schema might change — which is nearly everything.

### Compared to Other Joins

`NATURAL JOIN` is `INNER JOIN ... USING (<implicitly discovered columns>)`. Everything `NATURAL JOIN` can do, explicit `ON`/`USING` can do — with the join key visible and stable. There is no capability `NATURAL JOIN` provides that explicit syntax doesn't; it only removes typing, at the cost described above.

### Real-World Use Cases

Practically none recommended. Its only legitimate niche is quick interactive/exploratory querying against a schema you're staring directly at, never in checked-in code.

> **[PostgreSQL]** Supports `NATURAL JOIN`, `NATURAL LEFT JOIN`, `NATURAL RIGHT JOIN`, `NATURAL FULL JOIN`.
> **[MySQL]** Supports `NATURAL JOIN` and `NATURAL LEFT/RIGHT JOIN` (no natural full join, matching MySQL's lack of `FULL OUTER JOIN`).
> **[Oracle]** Supports `NATURAL JOIN` and the outer-join variants.
> **[SQL Server]** Does **not** support `NATURAL JOIN` at all — there is no equivalent keyword; you must always write `ON` or `USING`-style logic manually (see the `USING` dialect note in §7.10 — SQL Server doesn't support `USING` either).

---

## 7.10 USING and Multi-Condition / Composite-Key Joins

### 7.10.1 The `USING` Clause

**Simple explanation.** `USING (order_id)` is a shorthand for `ON a.order_id = b.order_id` that also collapses the two `order_id` columns into a single output column — available only when the column name is identical on both sides, and only for that named column (unlike `NATURAL JOIN`, which grabs *every* matching name automatically).

```sql
SELECT order_id, product_id, quantity
FROM orders
JOIN order_items USING (order_id)
WHERE order_id = 1;
```

Output (verified):

| order_id | product_id | quantity |
|---|---|---|
| 1 | 1 | 1 |
| 1 | 9 | 1 |

This is exactly equivalent to `JOIN order_items oi ON orders.order_id = oi.order_id`, except `USING` also lets you refer to the shared column just once (`order_id`) instead of needing `o.order_id`/`oi.order_id` — and, critically, unlike `NATURAL JOIN`, **you explicitly name which column(s) participate**, so the join key is visible in the query text and won't silently change if the schema gains new shared column names later.

`USING` also supports composite (multi-column) keys directly: `JOIN table_b USING (col1, col2)` — this is the safe, explicit alternative to `NATURAL JOIN` whenever two tables genuinely share a multi-column natural key.

> **[SQL Server] ⚠️ Warning**
> SQL Server does **not** support the `USING` clause at all. You must always write the full `ON a.col = b.col [AND ...]` form.
> **[PostgreSQL] [MySQL] [Oracle]** all support `USING`, including multi-column `USING (col1, col2)`.

### 7.10.2 Multi-Condition Joins and Composite Keys

**Simple explanation.** Sometimes a single column isn't enough to identify a matching row — the real-world key is a *combination* of columns. `inventory` is a direct example in this schema: it's stock **per product per warehouse**, enforced by `UNIQUE (product_id, warehouse_location)`. A join that only matched on `product_id` would incorrectly pair a product with *every* warehouse row for that product, not the one specific stock record you meant.

**Technical explanation.** `ON` accepts an arbitrary boolean expression, not just a single equality — you combine conditions with `AND`/`OR` exactly as in a `WHERE` clause. This is how both composite-key equi-joins and inequality-augmented joins are expressed.

**Example 1 — a genuine composite-key self-join.** `inventory`'s natural key is `(product_id, warehouse_location)`. To find products stocked in **more than one warehouse**, self-join `inventory` on `product_id` while requiring the warehouse to differ — a two-condition `ON` clause:

```sql
SELECT i1.product_id, pr.product_name,
       i1.warehouse_location AS warehouse_a, i2.warehouse_location AS warehouse_b
FROM inventory i1
JOIN inventory i2 ON i1.product_id = i2.product_id
                 AND i1.warehouse_location < i2.warehouse_location   -- prevents self-pair + duplicate mirror pairs
JOIN products pr ON pr.product_id = i1.product_id;
```

Output (verified — of 10 products across 11 inventory rows, only one is split across two warehouses):

| product_id | product_name | warehouse_a | warehouse_b |
|---|---|---|---|
| 1 | Galaxy Phone X | Delhi-WH2 | Mumbai-WH1 |

Galaxy Phone X has 15 units in `Delhi-WH2` and 40 in `Mumbai-WH1` — the only product split across warehouses in this seed data. Every other product has exactly one inventory row, so it never produces a self-pair here.

**Example 2 — a key equality combined with an inequality condition, in the same `ON` clause.** Find products that are at or below their reorder level, joined together with which warehouse that applies to:

```sql
SELECT p.product_id, p.product_name, i.warehouse_location, i.quantity_on_hand, i.reorder_level
FROM products p
JOIN inventory i ON p.product_id = i.product_id
                AND i.quantity_on_hand <= i.reorder_level   -- second, non-key condition in the same ON
ORDER BY p.product_id;
```

Output (verified):

| product_id | product_name | warehouse_location | quantity_on_hand | reorder_level |
|---|---|---|---|---|
| 4 | GameBook 15 | Pune-WH1 | 3 | 5 |
| 9 | Wireless Earbuds | Mumbai-WH1 | 0 | 25 |

**Line-by-line explanation (Example 2):**
1. `p.product_id = i.product_id` — the actual join key, matching product to its stock record(s).
2. `AND i.quantity_on_hand <= i.reorder_level` — a second, non-equality condition evaluated as part of the *same* join, not filtered afterward in `WHERE`. Because this is in `ON` and the join is `INNER`, the practical effect here is identical to putting it in `WHERE` — but see §7.11 for exactly when that stops being true (the moment you switch this to a `LEFT JOIN`, it very much matters which clause holds the condition).

**Why put a second condition in `ON` instead of `WHERE`, if the result is sometimes identical?** For `INNER JOIN`, both placements can be logically equivalent — but readability matters: putting *join logic* (conditions about how the two tables relate) in `ON` and *result filtering logic* (conditions about the final rows you want) in `WHERE` keeps the query's intent clear. The moment you touch an outer join, this stops being a style preference and becomes a correctness issue — the entire subject of §7.11.

### Common Mistakes (USING / multi-condition joins)

- Forgetting the inequality guard (`i1.warehouse_location < i2.warehouse_location`) in a composite self-join, causing every row to also pair with itself and every pair to appear twice (mirrored).
- Writing a composite-key join with `OR` instead of `AND` by mistake — turning "must match on both product and warehouse" into "must match on product, or match on warehouse," which is a much looser (and almost always wrong) condition, typically causing a row explosion.
- Using `USING` when column names are only *coincidentally* the same but semantically different (this overlaps with the `NATURAL JOIN` danger in §7.9) — always double check both column meanings before collapsing them.

### Edge Cases

- Composite-key joins are exactly as vulnerable to `NULL`-never-matches as single-column joins — if *either* column in the composite key is `NULL` on a given row, that row cannot match anything, even if the other column would otherwise line up.
- A multi-condition `ON` clause that mixes an equality with a very loose inequality (e.g., a `BETWEEN` range) can produce a many-to-many join even when the equality half looks like a clean 1:1/1:N key — always verify resulting row counts (§7.12) rather than assuming.

### When to Use / Not Use

- **Use** composite-key/multi-condition joins whenever the real business key spans more than one column (as `inventory` genuinely does), or whenever you need to attach a business rule (like the reorder-level check) directly into the join logic for a `LEFT JOIN` where clause-placement matters (§7.11).
- **Don't** reach for `NATURAL JOIN` or bare `USING` as a shortcut for composite keys where the column names might not always mean the same thing everywhere they occur — be explicit.

---

## 7.11 ON vs WHERE — The Most Important Distinction in This Chapter

### Simple Explanation

**What I write (version A):** `LEFT JOIN payments p ON o.order_id = p.order_id AND p.status = 'SUCCESS'`
**What I write (version B):** `LEFT JOIN payments p ON o.order_id = p.order_id WHERE p.status = 'SUCCESS'`
**What the database logically does, differently in each case:**
- Version A evaluates `p.status = 'SUCCESS'` **as part of deciding what counts as a match**, *before* deciding whether to pad with `NULL`. An order whose only payment failed still appears — just with `NULL` payment columns — because the `LEFT JOIN`'s "always keep the left row" guarantee is untouched.
- Version B evaluates `o.order_id = p.order_id` first, produces the full `LEFT JOIN` result (including `NULL`-padded rows for genuinely unmatched orders), and **only then** applies `WHERE p.status = 'SUCCESS'` to that combined result. Since `NULL = 'SUCCESS'` and `'FAILED' = 'SUCCESS'` are both not `TRUE`, every row where the payment isn't a `SUCCESS` — *including the NULL-padded ones* — gets thrown away by `WHERE`. The `LEFT JOIN` has been effectively neutered into an `INNER JOIN`.

**What result is produced:** version A keeps every order (10 rows); version B silently drops any order without a successful payment (8 rows) — even orders that legitimately exist and that the query author almost certainly still wanted to see.

### Technical Explanation

The clauses in a `SELECT` are conceptually evaluated in this order: `FROM`/`JOIN` (including `ON`) → `WHERE` → `GROUP BY` → `HAVING` → `SELECT` (projection) → `ORDER BY`. This means:

- **`ON` conditions are part of the join operation itself** — they decide, row-pair by row-pair, whether a combination counts as a "match" *before* the outer join's NULL-padding rule for unmatched rows kicks in.
- **`WHERE` conditions are applied to the join's finished output** — by the time `WHERE` runs, the outer join has already decided which rows survived and which got `NULL`-padded; `WHERE` has no special awareness that some of those `NULL`s came from an outer join's padding rather than real data. It filters exactly like it would on a single table, and a `NULL` almost never survives a `WHERE` equality/inequality test (three-valued logic — Chapter 5 covers `NULL` comparison semantics in depth).

For `INNER JOIN`, this distinction is usually moot: there's no NULL-padding behavior to interfere with, so an extra condition behaves the same whether it's in `ON` or `WHERE` (modulo edge cases). **The distinction becomes critical the instant an outer join (`LEFT`/`RIGHT`/`FULL`) is involved.**

### Why This Matters / What Problem It Solves

This is, in practice, one of the most common real-world SQL correctness bugs: a developer writes a `LEFT JOIN` specifically to preserve rows with no match, then adds what looks like an innocuous filter on the right-hand table in `WHERE` — and unknowingly converts the query back into an `INNER JOIN`, silently losing exactly the rows the `LEFT JOIN` was written to protect. Understanding this distinction precisely is what separates "I got a `LEFT JOIN` to compile" from "I got a `LEFT JOIN` to do what I meant."

### Full Syntax Comparison

```sql
-- Condition in ON: filters what counts as a MATCH, preserves all left rows regardless
SELECT ...
FROM left_table l
LEFT JOIN right_table r ON l.key = r.key AND r.some_column = 'X';

-- Condition in WHERE: filters the FINISHED result, can silently drop left rows
SELECT ...
FROM left_table l
LEFT JOIN right_table r ON l.key = r.key
WHERE r.some_column = 'X';
```

### Demonstration With Real Data

`orders` and `payments` are in a true 1:1 relationship in this seed data (every one of the 10 orders has exactly one payment row), with payment statuses: orders 1,2,3,4,6,8,9,10 → `SUCCESS`; order 5 → `FAILED`; order 7 → `PENDING`.

**Version A — filter inside `ON`:**

```sql
SELECT o.order_id, o.status AS order_status, p.payment_id, p.status AS payment_status, p.amount
FROM orders o
LEFT JOIN payments p ON o.order_id = p.order_id AND p.status = 'SUCCESS'
ORDER BY o.order_id;
```

Output (verified, **10 rows** — every order preserved):

| order_id | order_status | payment_id | payment_status | amount |
|---|---|---|---|---|
| 1 | DELIVERED | 1 | SUCCESS | 49498.00 |
| 2 | DELIVERED | 2 | SUCCESS | 4097.00 |
| 3 | SHIPPED | 3 | SUCCESS | 89999.00 |
| 4 | PAID | 4 | SUCCESS | 3298.00 |
| 5 | CANCELLED | NULL | NULL | NULL |
| 6 | DELIVERED | 6 | SUCCESS | 75798.00 |
| 7 | PENDING | NULL | NULL | NULL |
| 8 | DELIVERED | 8 | SUCCESS | 45999.00 |
| 9 | PAID | 9 | SUCCESS | 93498.00 |
| 10 | DELIVERED | 10 | SUCCESS | 3897.00 |

Order 5 and order 7 **do** have a payment row each (`FAILED` and `PENDING` respectively) — but because that row doesn't satisfy `p.status = 'SUCCESS'`, it doesn't count as a match under this `ON` clause. Since there's no other candidate payment row for those orders, the `LEFT JOIN` falls back to its guarantee and emits the order once, with every `p.*` column `NULL` — *not* the FAILED/PENDING row's actual values. This is an important, precise detail: the unmatched-side padding happens per the join condition, not per the join key alone.

**Version B — the same filter, moved to `WHERE` (the bug):**

```sql
SELECT o.order_id, o.status AS order_status, p.payment_id, p.status AS payment_status, p.amount
FROM orders o
LEFT JOIN payments p ON o.order_id = p.order_id
WHERE p.status = 'SUCCESS'
ORDER BY o.order_id;
```

Output (verified, **8 rows** — orders 5 and 7 have vanished):

| order_id | order_status | payment_id | payment_status | amount |
|---|---|---|---|---|
| 1 | DELIVERED | 1 | SUCCESS | 49498.00 |
| 2 | DELIVERED | 2 | SUCCESS | 4097.00 |
| 3 | SHIPPED | 3 | SUCCESS | 89999.00 |
| 4 | PAID | 4 | SUCCESS | 3298.00 |
| 6 | DELIVERED | 6 | SUCCESS | 75798.00 |
| 8 | DELIVERED | 8 | SUCCESS | 45999.00 |
| 9 | PAID | 9 | SUCCESS | 93498.00 |
| 10 | DELIVERED | 10 | SUCCESS | 3897.00 |

**Row count: 10 vs 8 — a real, measurable, reproducible difference from moving one condition from `ON` to `WHERE`.**

### Line-by-Line Explanation

**Version A:** `LEFT JOIN payments p ON o.order_id = p.order_id AND p.status = 'SUCCESS'` — the engine considers a `(order, payment)` pair a "match" only when *both* conditions hold. For order 5, the only candidate payment row fails the second condition, so no match is found; the `LEFT JOIN`'s unconditional guarantee ("every left row appears at least once") then emits order 5 with `p.*` as `NULL`. The `WHERE`-less query never removes this row afterward.

**Version B:** `LEFT JOIN payments p ON o.order_id = p.order_id` first produces the *complete* left join — including order 5 and order 7's rows with their real `FAILED`/`PENDING` payment data attached (not `NULL` — a match on `order_id` alone *was* found for both). Then `WHERE p.status = 'SUCCESS'` runs against that finished result: for order 5, `p.status = 'FAILED'`, so `'FAILED' = 'SUCCESS'` is `FALSE` → row discarded. For order 7, `'PENDING' = 'SUCCESS'` is also `FALSE` → discarded. The net effect is indistinguishable from having written `INNER JOIN` in the first place.

### What Happens Internally (preview)

The planner is free to reorder physical operations for efficiency (e.g., it may push a `WHERE`-clause predicate down before the join in some cases when doing so is provably safe) — but it can **never** apply that optimization in a way that changes the outer join's logical semantics. The `ON`-clause version and the `WHERE`-clause version above are given genuinely different query plans because they are, in fact, different queries with different logical meaning — this isn't an optimizer quirk, it's the SQL standard's defined behavior for outer joins. Chapter 17 covers predicate pushdown and plan rewriting rules in depth.

### Common Mistakes

- Adding a filter on the "optional" side of a `LEFT JOIN` in `WHERE` without realizing it silently reintroduces `INNER JOIN` semantics — this is *the* canonical `LEFT JOIN` bug, common enough to be a standard interview question.
- The mirror-image mistake: putting a filter that's meant to restrict the **final result set** (e.g., "only show orders placed this year," which should apply regardless of match status) into the `ON` clause instead — this can cause an outer join to preserve *more* NULL-padded rows than intended, because now non-matches on that condition also get preserved rather than excluded from the join input entirely. As a rule of thumb: filters about **how the two tables relate** belong in `ON`; filters about **which final rows you want to keep** belong in `WHERE`, applied to a column that is guaranteed to be populated for every row you want to keep (typically a column from the "always preserved" left table, or `COALESCE`d appropriately).
- Believing this distinction "doesn't matter for `INNER JOIN`" and therefore never learning it — it doesn't matter for `INNER JOIN` today, until someone later changes the join type to `LEFT JOIN` during a refactor and inherits the exact bug shown here, because the filter was left in `WHERE`.

### Edge Cases

- If the right table has **zero** rows for a key, the `ON`-clause version and `WHERE`-clause version actually agree for that key (both produce a `NULL`-padded row in the `ON` version and both exclude it in the `WHERE` version) — the divergence specifically requires a row that **matches the join key but fails the extra condition**, exactly the `FAILED`/`PENDING` payment scenario above. If every order's payment had been `SUCCESS`, both versions would have produced identical 10-row results, hiding the bug entirely until a `FAILED` or `PENDING` payment eventually appeared in the data.
- This is precisely why the bug is so common in practice: **it can pass code review and testing against "happy path" data**, and only manifest once real-world edge cases (a failed payment, a returned order) show up in production.

### When to Use / Not Use

- Put a condition in **`ON`** when it defines what should count as a valid match for the purposes of preserving the outer side — "only consider a *successful* payment a match."
- Put a condition in **`WHERE`** when it should filter the final report regardless of join outcome — "only show orders from January 2024," applied on `o.order_date`, a column from the always-preserved left table.
- If you genuinely want an outer join **and then** to drop the rows that ended up unmatched (turning it into an inner join deliberately) — just use `INNER JOIN` directly; it says exactly what you mean and needs no outer-join machinery at all.

### Compared to Other Joins

This distinction is invisible for plain `INNER JOIN` (both placements are equivalent there, ignoring performance) and for `CROSS JOIN` (no `ON` at all). It applies symmetrically to `RIGHT JOIN` (with the roles of the "preserved" and "optional" table swapped) and to `FULL OUTER JOIN` (where a `WHERE`-clause filter on *either* side's column can eliminate that side's otherwise-preserved unmatched rows).

### Real-World Use Cases

- Any "all X, with optional Y info" report: all orders with successful-payment info if any; all employees with a Q1 bonus record if any; all products with their latest review if any (only when a `LEFT JOIN` with an in-`ON` condition is used correctly).
- This exact pattern is why experienced reviewers specifically look for `WHERE <right_table>.<column> = ...` immediately after any `LEFT JOIN` in a code review — it's a near-automatic "did you mean to put that in `ON`?" flag.

> **Important Note**
> A quick sanity check you can apply to any `LEFT JOIN` you write: **if a filter in `WHERE` references a column from the right-hand (optional) table using an equality/inequality that a `NULL` could never satisfy, ask whether you actually wanted an `INNER JOIN`.** If the answer is "no, I wanted to keep unmatched rows too," move the condition into `ON`.

---

## 7.12 Join Cardinality: One-to-One, One-to-Many, Many-to-Many

### Simple Explanation

**What I write:** any `JOIN` between two tables.
**What the database logically does:** for every row on one side, it looks for **all** matching rows on the other side — not just the first one. If there are 2 matches, you get 2 output rows for that one input row.
**What result is produced:** the output row count is **not** simply related to either input table's row count — it depends entirely on how many matches each row has, which is determined by the relationship's cardinality.

### Technical Explanation

Cardinality describes how many rows on one side of a relationship can correspond to how many rows on the other:

- **One-to-one (1:1):** at most one matching row on each side. Joining doesn't multiply rows — output row count ≈ the smaller/matching set.
- **One-to-many (1:N):** one row on the "one" side can match many rows on the "many" side. Joining the "one" side to the "many" side multiplies each "one" row by however many matches it has.
- **Many-to-many (M:N):** rows on either side can match multiple rows on the other, typically implemented via a bridge/junction table holding two foreign keys (like `employee_projects`). Joining through the bridge can multiply rows on *both* directions at once.

The general row-count law for an inner join: **output rows = Σ (for each left row) × (number of matching right rows).** This is not intuition — it's exactly what the "cross product, then filter" model from §7.2 predicts.

### Why It Matters

If you don't know a relationship's cardinality *before* you write the join, you cannot predict — and therefore cannot correctly verify — your output row count. This is the single most common root cause of "my report's numbers are too big" bugs (explored fully with a concrete case in §7.13).

### Cardinality in This Course's Schemas

| Relationship | Cardinality | Why |
|---|---|---|
| `users` → `orders` | 1:N | one user, many orders |
| `orders` → `order_items` | 1:N | one order, many line items |
| `order_items` → `products` | N:1 | many line items can reference the same product |
| `orders` → `payments` | 1:1 (in this seed data) | each order has exactly one payment row |
| `products` → `reviews` | 1:N | one product, many reviews |
| `products` → `inventory` | 1:N | one product can be stocked in multiple warehouses |
| `employees` → `employees` (via `manager_id`) | 1:N | one manager, many direct reports |
| `employees` ↔ `projects` (via `employee_projects`) | M:N | many employees per project, many projects per employee |

### Visual Diagram — One-to-Many, Walked Through Explicitly

```
orders                          order_items
+----------+                    +----------+------------+----------+
| order_id |                    | order_id | product_id | quantity |
+----------+                    +----------+------------+----------+
| 1        |                    | 1        | 1          | 1        |
+----------+                    | 1        | 9          | 1        |
                                 +----------+------------+----------+
```

`orders JOIN order_items ON orders.order_id = order_items.order_id`, for order 1:

```
+----------+------------+----------+
| order_id | product_id | quantity |
+----------+------------+----------+
| 1        | 1          | 1        |   <- order 1, row 1 of order_items
| 1        | 9          | 1        |   <- order 1, row 2 of order_items
+----------+------------+----------+
```

**One row of `orders` (order_id = 1) becomes TWO rows in the joined output**, because `order_items` has 2 matching rows for that order. This is the literal, mechanical meaning of "1:N join multiplies rows" — not a metaphor.

### Real Schema Example — Walking the Math Precisely

`order_items` row-counts per order in the full seed data:

```
order 1:  2 items (product 1, product 9)
order 2:  2 items (product 5, product 7)
order 3:  1 item  (product 3)
order 4:  2 items (product 6, product 8)
order 5:  1 item  (product 2)
order 6:  2 items (product 4, product 10)
order 7:  1 item  (product 9)
order 8:  1 item  (product 1)
order 9:  2 items (product 3, product 9)
order 10: 1 item  (product 5)
                    ----
Total:              15 order_items rows
```

```sql
SELECT COUNT(*) FROM orders;        -- 10
SELECT COUNT(*) FROM order_items;   -- 15
SELECT COUNT(*)
FROM orders o JOIN order_items oi ON o.order_id = oi.order_id;   -- 15
```

**Verified:** the join's output row count (15) equals `order_items`' row count exactly — because every `order_items` row has exactly one matching order (the foreign key guarantees this), and every order has at least one item, so this 1:N inner join's row count is simply the "many" side's row count. This is a useful general rule: **for a clean 1:N inner join where the "many" side's foreign key is `NOT NULL` and always valid, the joined row count equals the "many" side's row count** — not the "one" side's.

### Extending the Chain — Cardinality Compounds

Add `products` (N:1 from `order_items` — doesn't change row count, since each line item has exactly one product) and `payments` (1:1 from `orders` — also doesn't change row count on its own), and the row count of the full five-table chain in §7.3's Example 3 stays at exactly the `order_items` row count:

```sql
SELECT COUNT(*)
FROM users u
JOIN orders o        ON u.user_id     = o.user_id
JOIN order_items oi  ON o.order_id    = oi.order_id
JOIN products pr     ON oi.product_id = pr.product_id
JOIN payments pay    ON o.order_id    = pay.order_id;
-- 15
```

Verified: still **15** — but notice each order's `pay.amount` value now appears **once per line item of that order**, not once per order. Order 1's payment amount (`49498.00`) is repeated across its 2 line-item rows. This is the exact setup for the next section.

### Many-to-Many Example (`company_db`)

`employees` ↔ `projects` via the `employee_projects` bridge table:

```sql
SELECT e.first_name, p.project_name, ep.role
FROM employees e
JOIN employee_projects ep ON e.employee_id = ep.employee_id
JOIN projects p            ON ep.project_id  = p.project_id
WHERE e.employee_id IN (2, 16)
ORDER BY e.employee_id, p.project_id;
```

| first_name | project_name | role |
|---|---|---|
| Rahul | Platform Migration | Tech Lead |
| Rahul | Mobile App Revamp | Tech Lead |
| Aman | Mobile App Revamp | Engineer |

Rahul (employee 2) appears **twice** — once per project he's on — while Aman (employee 16) appears once. This is many-to-many cardinality in action: the same employee row can legitimately multiply across the output, and the same project could equally multiply if multiple employees were queried against it (e.g., "Mobile App Revamp" appears for both Rahul and Aman).

### Common Mistakes

- Assuming a join's output row count relates simply to either input table's count without first checking the actual cardinality of the relationship.
- Not distinguishing "this FK column is `UNIQUE`" (which forces 1:1 from that side) from "this FK column merely references the other table" (which allows 1:N) — always check constraints, not just foreign keys, when reasoning about cardinality (recall `payments.order_id` here has no `UNIQUE` constraint in the DDL — the 1:1 relationship in this seed data is a fact about the *data*, not something the *schema* enforces; a future insert of a second payment for the same order is entirely legal and would immediately turn this into a 1:N relationship).

### Edge Cases

- A relationship that is 1:1 **by coincidence in current data** (like `orders`/`payments` here) is not the same as a relationship that is 1:1 **by schema design** (enforced with a `UNIQUE` constraint on the FK column, like `managers.department_id`). Always verify which one you're actually relying on before assuming row counts won't multiply — see §7.13 for exactly what happens if that assumption turns out to be wrong.
- A many-to-many join through a bridge table with a *missing* row on one side behaves like any other join missing a match: use `LEFT JOIN` through the bridge if you need to preserve, say, "employees with zero project assignments" (see §7.15's anti-join example using exactly this table).

### When to Use / Not Use

Cardinality analysis isn't itself a join type to choose or avoid — it's a mandatory pre-flight check before writing (or reviewing) *any* join: identify whether each relationship in your chain is 1:1, 1:N, or M:N before you write the query, so the resulting row count is something you predicted, not something that surprises you.

### Real-World Use Cases

- Predicting/validating expected row counts before shipping a report query (a very effective, cheap correctness check: compute the expected count by hand from cardinality, run the query, compare).
- Deciding whether you need to pre-aggregate one side of a join before combining it with another (directly motivates §7.13).

---

## 7.13 Duplicate Rows Caused by Joins

### Simple Explanation

**What I write:** a naive `SUM()` of a column from the "one" side of a 1:N join, computed *after* joining to the "many" side.
**What the database logically does:** because the 1:N join has already multiplied the "one" side's row (and therefore its column values) once per match on the "many" side, summing that column now adds the same value in multiple times.
**What result is produced:** a total that is **too large** — inflated by exactly the amount of duplication the join introduced.

### Technical Explanation

This isn't a bug in `SUM()` or in joins — both are working exactly as specified. The bug is a **modeling mistake**: treating a column that logically belongs to the "one" side (like `payments.amount`, one value per order) as if it were still one-value-per-order *after* joining it through a table that multiplies rows (like `order_items`, many rows per order). Every duplicated row carries a duplicated copy of that "one"-side value, and `SUM()`/`COUNT()`/`AVG()` have no way to know those copies aren't independent facts.

### Why This Matters

This is, in practice, one of the most damaging classes of SQL bugs — because it doesn't error, doesn't warn, and often produces a number that's still *plausible-looking* (just wrong), meaning it can sail through code review and even production for a long time before someone notices a report total looks "a bit high."

### Demonstrated With Real Seed Data

Recall from §7.3/§7.12 that `arjun_k` (user 1) placed 3 orders: order 1 (2 line items, payment `49498.00`), order 3 (1 line item, payment `89999.00`), order 8 (1 line item, payment `45999.00`).

**The correct total** — computed directly from `payments`, which has exactly one row per order:

```sql
SELECT u.username, SUM(pay.amount) AS correct_total_paid
FROM users u
JOIN orders o   ON u.user_id  = o.user_id
JOIN payments pay ON o.order_id = pay.order_id AND pay.status = 'SUCCESS'
WHERE u.user_id = 1
GROUP BY u.username;
```

| username | correct_total_paid |
|---|---|
| arjun_k | 185496.00 |

(`49498.00 + 89999.00 + 45999.00 = 185496.00` — matches exactly.)

**The naive (WRONG) total** — the same `SUM(pay.amount)`, but computed after *also* joining through `order_items` (perhaps because the query also needed to show line-item detail, or a product filter, in the same result set):

```sql
SELECT u.username, SUM(pay.amount) AS naive_total_paid_WRONG
FROM users u
JOIN orders o      ON u.user_id     = o.user_id
JOIN order_items oi ON o.order_id   = oi.order_id
JOIN payments pay  ON o.order_id    = pay.order_id AND pay.status = 'SUCCESS'
WHERE u.user_id = 1
GROUP BY u.username;
```

| username | naive_total_paid_WRONG |
|---|---|
| arjun_k | 234994.00 |

**`234994.00` is `49498.00` too high** — exactly the amount of order 1's payment, counted one extra time, because order 1 has 2 line items and therefore appears twice in the joined result, each copy carrying the *same* `49498.00` payment value:

```sql
SELECT o.order_id, COUNT(oi.order_item_id) AS n_items, pay.amount
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN payments pay   ON o.order_id = pay.order_id
WHERE o.user_id = 1 AND pay.status = 'SUCCESS'
GROUP BY o.order_id, pay.amount;
```

| order_id | n_items | amount |
|---|---|---|
| 1 | 2 | 49498.00 |
| 3 | 1 | 89999.00 |
| 8 | 1 | 45999.00 |

Order 1's `amount` (49498.00) is attached to 2 physical rows once the `order_items` join is present. `SUM()` over those rows adds `49498.00` twice (`98996.00`) instead of once, inflating the total by `49498.00` — precisely accounting for the `234994.00 - 185496.00 = 49498.00` gap.

### How to Detect This Bug

1. **Compute an independent row-count/sum sanity check** before trusting any aggregate that follows a join: does `COUNT(*)` after the join equal what cardinality analysis (§7.12) predicts? If a "one row per order" total is computed after a join that's known to produce more than one row per order, that's your red flag.
2. **Compare the aggregate against a version computed without the multiplying join** — exactly as done above (join only as far as `payments`, skip `order_items` entirely, when the goal is a per-order total).

### How to Avoid This Bug

**Option 1 — Aggregate before joining (pre-aggregate the "many" side, or simply don't join through it if you don't need its columns).** The correct-total query above does exactly this: it never joins `order_items` at all, because the question ("total paid") doesn't need line-item detail.

**Option 2 — If you need both line-item detail AND an order-level total in the same result, aggregate the "many" side into a subquery first, then join once:**

```sql
SELECT u.username, o.order_id, item_totals.n_items, pay.amount
FROM users u
JOIN orders o ON u.user_id = o.user_id
JOIN (
    SELECT order_id, COUNT(*) AS n_items, SUM(quantity * unit_price) AS items_total
    FROM order_items
    GROUP BY order_id
) item_totals ON o.order_id = item_totals.order_id
JOIN payments pay ON o.order_id = pay.order_id AND pay.status = 'SUCCESS'
WHERE u.user_id = 1
ORDER BY o.order_id;
```

Because `item_totals` has already collapsed `order_items` down to exactly one row per order *before* it's joined, this join is a clean 1:1 (order → its own pre-computed totals), and `pay.amount` is never duplicated.

**Option 3 — Use `SELECT DISTINCT` on the order-level columns before aggregating, or use window functions** (covered fully in Chapter 10) to compute the per-order total in place without collapsing rows, e.g. `SUM(pay.amount) OVER (PARTITION BY o.order_id)` as a windowed value that you then take `MAX()`/`MIN()`/only the first occurrence of. This course revisits this exact scenario in Chapter 10 as a canonical window-function use case, and again in Chapter 9 for CTE-based pre-aggregation patterns.

> **Important Note**
> `SELECT DISTINCT` alone does **not** fix this bug if you're summing the payment amount directly in the same query as the multiplying join — `DISTINCT` operates on whole output rows (or the specific columns you select), and since each duplicated row still differs in its `order_items` columns (different `product_id`, `quantity`, etc.), `DISTINCT` won't collapse them. `DISTINCT` only helps once you've already projected down to just the columns that don't vary across the duplicates (e.g., `SELECT DISTINCT order_id, amount`), which is really just Option 2/3 in a different shape.

### Common Mistakes

- Joining in extra tables "just in case" or for an unrelated filter, and forgetting that doing so can silently change the cardinality of every column already in the `SELECT` list.
- Trusting a total that "looks plausible" without an independent sanity check — inflated-by-a-multiplying-join totals are rarely *obviously* wrong at a glance.
- Fixing this with `DISTINCT` in the wrong place (see the note above) rather than pre-aggregating.

### Edge Cases

- If every "one" side row happens to have exactly one match on the "many" side (no actual duplication in the current data), this bug is **completely invisible** until the data changes — e.g., the day an order gets a second line item. This is another instance of a class of bug that passes testing against "happy path" data and only appears later.
- Aggregating with `COUNT(DISTINCT o.order_id)` instead of `COUNT(*)` is a reasonable partial mitigation for *counting* orders correctly even across a duplicating join — but it does **not** fix a `SUM()` of a duplicated value; there is no `SUM(DISTINCT ...)` trick that reliably solves this in the general case (it happens to work only if the duplicated values are actually unique per order, which defeats the purpose of checking).

### When to Use / Not Use

This isn't a join-type choice — it's a design discipline: **always know, before writing `SUM()`/`AVG()`/`COUNT()` after a join, which side(s) of that join can have been multiplied, and pre-aggregate accordingly.**

### Real-World Use Cases

Nearly every real analytics/reporting bug report that says "these numbers don't match the other system" traces back to exactly this pattern — a join that fans out a value that was supposed to be counted once. This is a top-tier interview and code-review topic for a reason.

---

## 7.14 NULL Behavior in Joins

### Simple Explanation

**What I write:** any outer join (`LEFT`, `RIGHT`, `FULL`).
**What the database logically does:** for a row with no match on the other side, it fills every column that would have come from that other side with `NULL` — a genuine "no value," not a zero, not an empty string.
**What result is produced:** output rows that mix real data (from the preserved side) with `NULL` placeholders (for the unmatched side), which then interact with `WHERE`/aggregate functions in specific, learnable ways.

### Technical Explanation

Two entirely separate `NULL` behaviors are relevant to joins, and it's important not to conflate them:

1. **`NULL` in a join *key* never matches anything**, including another `NULL` — because SQL's join predicate is ordinary equality (`=`), and `NULL = NULL` evaluates to `UNKNOWN`, not `TRUE`, in three-valued logic (Chapter 5 covers this fully). A row whose join-key column is `NULL` behaves, for join purposes, as if it can never find a partner.
2. **`NULL` as *padding* for the unmatched side of an outer join** is a different, deliberate mechanism — the engine isn't evaluating any predicate here, it's simply filling in placeholders for columns that have no corresponding row to pull real values from.

### Where This Shows Up

Every `NULL` example already seen in this chapter is one of these two mechanisms:

- **Padding (mechanism 2):** `Electronics`/`Fashion` categories with `NULL` product columns (§7.4); Finance department with `NULL` project columns (§7.4); order 5/order 7 with `NULL` payment columns in the `ON`-clause version of the ON-vs-WHERE example (§7.11).
- **Key-never-matches (mechanism 1):** Aditi Rao's `manager_id` is genuinely `NULL`, so the self-join in §7.8 can never find her a manager, and the `LEFT JOIN` falls back to padding; `Electronics`'s `parent_category_id` is genuinely `NULL` in §7.6's self-join.

### How NULL Padding Interacts With WHERE

Because `WHERE` runs **after** the join has already decided its output rows, a `NULL`-padded column behaves exactly like any other `NULL` value once it reaches `WHERE` — three-valued logic applies without exception:

```sql
-- Departments with NULL-padded project columns (Finance) DISAPPEAR here,
-- because "p.budget > 0" evaluates to UNKNOWN, not TRUE, for a NULL budget
SELECT d.department_name, p.project_name, p.budget
FROM departments d
LEFT JOIN projects p ON d.department_id = p.department_id
WHERE p.budget > 0;
```

This drops Finance from the output — not because a real project row was disqualified, but because there was never a real project row for Finance at all, and the `NULL` placeholder fails the `p.budget > 0` test. **This is exactly the same underlying mechanism as the ON-vs-WHERE bug in §7.11** — a `WHERE` condition on the "optional" side's column silently reintroduces `INNER JOIN` semantics. The fix, as before: if you want Finance to still appear, either move the condition into `ON`, or explicitly account for `NULL` in `WHERE` (e.g., `WHERE p.budget > 0 OR p.budget IS NULL`) — though at that point, ask whether you actually meant to filter out unmatched rows in the first place.

### How NULL Padding Interacts With Aggregate Functions

`COUNT(*)` counts rows, full stop — including `NULL`-padded ones. `COUNT(column)` counts only **non-NULL** values of that specific column. This distinction is a frequent, subtle bug source right after a `LEFT JOIN`:

```sql
SELECT d.department_name,
       COUNT(*)          AS row_count,          -- counts output ROWS, including NULL-padded ones
       COUNT(p.project_id) AS project_count      -- counts only non-NULL project_id values
FROM departments d
LEFT JOIN projects p ON d.department_id = p.department_id
GROUP BY d.department_name
ORDER BY d.department_name;
```

For Finance (no projects), `row_count` = 1 (the single `NULL`-padded row the `LEFT JOIN` produced), but `project_count` = 0 (there is no real `project_id` to count). If you'd used `COUNT(*)` intending "how many projects does this department have," Finance would incorrectly show `1` instead of `0`. `SUM()`, `AVG()`, `MIN()`, `MAX()` all similarly ignore `NULL` inputs entirely — `SUM(p.budget)` for Finance yields `NULL` (not `0`) unless wrapped in `COALESCE(SUM(p.budget), 0)`.

> **⚠️ Warning**
> After any `LEFT JOIN`, always ask which specific column you're aggregating, and whether a `NULL`-padded row should count as `0`/excluded/something else for that particular business question. `COUNT(*)` and `COUNT(<a specific column>)` are **not interchangeable** the moment an outer join is in play.

### Common Mistakes

- Using `COUNT(*)` when `COUNT(<right_table_column>)` was needed (or vice versa) right after a `LEFT JOIN`.
- Writing `WHERE <right_table_column> IS NOT NULL` when the actual intent was `INNER JOIN` all along — this works, but it's a needlessly indirect way to express "I don't want unmatched rows"; just use `INNER JOIN` directly for clarity (this exact idiom, reversed, is the standard anti-join pattern in §7.15 — the *positive* form is arguably a code smell for "this should've been an INNER JOIN").
- Forgetting `COALESCE()` when a `NULL`-padded numeric column flows into further arithmetic (`NULL + 5` is `NULL`, silently propagating "no value" through an entire calculation).

### Edge Cases

- A column that is legitimately `NULL` in a **real, matched** row (e.g., `payments.payment_date IS NULL` for a `PENDING` payment that hasn't been charged yet — order 7 and order 5 both have this) looks *identical* to a `NULL` produced by outer-join padding once it's sitting in your result set. You cannot tell the two apart from the value alone — you must check whether the row's *key* column (e.g., `payment_id`) is also `NULL` (padding) or populated (a real row with a genuinely null field).
- `IS NULL` / `IS NOT NULL` are the only correct ways to test for `NULL` — `= NULL` always evaluates to `UNKNOWN` and silently matches nothing, a classic beginner mistake reinforced here because it's so easy to fall into right after an outer join.

### When to Use / Not Use

Not a join-type choice — a mandatory habit: whenever you write or read a query with an outer join, explicitly work out which output columns *can* be `NULL` because of padding, and verify every downstream `WHERE`/aggregate/arithmetic expression handles that correctly.

### Real-World Use Cases

Every outer-join-based report in existence needs this reasoning applied at least once — "how many orders have no payment yet," "average review rating including unreviewed products as some sentinel," "total budget across all departments including those with none" all hinge on getting `NULL`-vs-`WHERE`-vs-aggregate interaction right.

---

## 7.15 Anti-Joins

### Simple Explanation

**What I write:** `LEFT JOIN ... WHERE right.key IS NULL` (or the equivalent `NOT EXISTS`).
**What the database logically does:** find every row on the left that has **no** matching row at all on the right.
**What result is produced:** exactly the left-side rows that are "missing" a counterpart — the set-theoretic complement of an inner join.

### Technical Explanation

An anti-join isn't a distinct join keyword in standard SQL — it's a **pattern** built from an outer join plus a null-check, or from a `NOT EXISTS`/`NOT IN` correlated subquery. Both approaches compute the same logical result: rows from the left table for which zero rows exist in the right table satisfying the join condition.

### Why It Exists

"Which customers have never ordered," "which products have never sold," "which employees are on no project" — these are extremely common business questions, and they are fundamentally about **absence**, which `INNER JOIN`/`LEFT JOIN` alone can't isolate (a plain `LEFT JOIN` gives you matched *and* unmatched rows together; you need the extra filter step to isolate only the unmatched ones).

### Full Syntax — Two Equivalent Forms

```sql
-- Form 1: LEFT JOIN + IS NULL
SELECT l.*
FROM left_table l
LEFT JOIN right_table r ON l.key = r.key
WHERE r.key IS NULL;

-- Form 2: NOT EXISTS (correlated subquery)
SELECT l.*
FROM left_table l
WHERE NOT EXISTS (
    SELECT 1 FROM right_table r WHERE r.key = l.key
);
```

> **Important Note**
> Prefer `NOT EXISTS` over `NOT IN` for anti-joins whenever the right-hand column can contain `NULL` values. `NOT IN (SELECT ... )` has a notorious trap: if the subquery's result set contains even a single `NULL`, `NOT IN` returns **no rows at all** for the entire query (because `x NOT IN (1, 2, NULL)` requires `x <> NULL` to be evaluated, which is `UNKNOWN`, poisoning the whole `OR`-chain to `UNKNOWN`). `NOT EXISTS` has no such trap — it's the safer default. Chapter 8 (Subqueries) covers this `NOT IN`/`NULL` trap in full depth.

### Visual Diagram

```
Table: A (products)            Table: B (reviews)
+----+---------+               +----+------------+
| id | name    |                | id | product_id |
+----+---------+               +----+------------+
| 1  | Widget  |               | 1  | 1          |
| 2  | Gadget  |               +----+------------+
+----+---------+
```

`A LEFT JOIN B ON A.id = B.product_id WHERE B.id IS NULL` (anti-join — products with no review):

```
+----+--------+
| id | name   |
+----+--------+
| 2  | Gadget |    <- the only product with zero matching reviews
+----+--------+
```

### Real Schema Examples

**Example 1 — "users who have never placed an order."** Let's actually run it:

```sql
SELECT u.user_id, u.username
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id
WHERE o.order_id IS NULL;
```

Output (verified): **0 rows.** In this seed data, every one of the 8 users (`user_id` 1 through 8) has placed at least one order — the `orders` table's `user_id` values are `{1,2,1,3,4,5,6,1,7,8}`, which covers all 8 distinct users. This is a real, correct result: the anti-join pattern works exactly as intended, and it's telling you truthfully that the "missing" set is empty for this particular relationship in this particular dataset. **An anti-join returning zero rows is not a bug — it's information** ("nobody is missing"), and you should trust it exactly as much as a non-empty result.

**Example 2 — the same anti-join pattern, but against `reviews` instead of `orders`, which does produce a non-empty, illustrative result** — "users who have never written a review":

```sql
SELECT u.user_id, u.username
FROM users u
LEFT JOIN reviews r ON u.user_id = r.user_id
WHERE r.review_id IS NULL
ORDER BY u.user_id;
```

Output (verified):

| user_id | username |
|---|---|
| 3 | dev_m |
| 6 | lakshmi_v |
| 8 | tanya_b |

**Example 3 — "products that have never been reviewed"** (the mirror of the semi-join in §7.16):

```sql
SELECT p.product_id, p.product_name
FROM products p
LEFT JOIN reviews r ON p.product_id = r.product_id
WHERE r.review_id IS NULL
ORDER BY p.product_id;
```

Output (verified):

| product_id | product_name |
|---|---|
| 2 | Pixel Lite |
| 6 | Women Kurta Set |
| 7 | Non-stick Pan Set |
| 8 | Electric Kettle |
| 10 | Laptop Sleeve 14" |

Same query using `NOT EXISTS` instead, for comparison — identical result, different mechanism:

```sql
SELECT p.product_id, p.product_name
FROM products p
WHERE NOT EXISTS (
    SELECT 1 FROM reviews r WHERE r.product_id = p.product_id
)
ORDER BY p.product_id;
```

**Example 4 — `company_db`: "employees who have never been assigned to any project"** (anti-join through the M:N bridge table):

```sql
SELECT e.employee_id, e.first_name, e.last_name, e.job_title
FROM employees e
LEFT JOIN employee_projects ep ON e.employee_id = ep.employee_id
WHERE ep.employee_id IS NULL
ORDER BY e.employee_id;
```

Output (verified):

| employee_id | first_name | last_name | job_title |
|---|---|---|---|
| 1 | Aditi | Rao | CTO |
| 5 | Ananya | Singh | Software Engineer |
| 9 | Meera | Pillai | Sales Executive |
| 12 | Nikhil | Gupta | Finance Manager |
| 13 | Divya | Shah | Accountant |

### Line-by-Line Explanation (Form 1, Example 3)

1. `FROM products p LEFT JOIN reviews r ON p.product_id = r.product_id` — every product survives, matched products get review columns attached, unmatched products get `r.*` as `NULL`.
2. `WHERE r.review_id IS NULL` — this is the anti-join filter step: it keeps **only** the rows where the `LEFT JOIN` had to pad with `NULL`, i.e., exactly the products with zero matching reviews. Every matched row (where `r.review_id` is a real number) is excluded here.

### What Happens Internally (preview)

Modern query planners (including PostgreSQL's) recognize the `LEFT JOIN ... WHERE right.key IS NULL` pattern and the `NOT EXISTS` pattern as **logically equivalent to a dedicated anti-join operation**, and will typically execute both using the same physical strategy — often a **hash anti-join** (build a hash table of the right side's keys, scan the left side, emit rows whose key isn't found in the hash table) or a nested-loop anti-join for smaller inputs. You do not need to guess which form is "faster" by default; check `EXPLAIN` (Chapter 17) if in doubt, but don't assume one form is always better than the other.

### Common Mistakes

- Using `NOT IN` with a subquery that can produce `NULL` — the trap described above; silently returns zero rows for the *entire* query, not just the poisoned comparisons.
- Filtering on the wrong right-table column for the `IS NULL` check — you must check a column that is genuinely `NULL` only when the join found no match at all (typically the right table's primary key), not some arbitrary nullable column that could *also* be `NULL` on a real matched row (recall §7.14's warning about telling padding-NULL apart from real-NULL).
- Forgetting that an anti-join can legitimately return zero rows (Example 1) and treating that as a query bug rather than a true fact about the data.

### Edge Cases

- If the right table is **completely empty**, every left row is "unmatched" by definition, so the anti-join returns the entire left table.
- If the right table has a row with a `NULL` join-key value, that row can never match anything (per §7.14's mechanism 1) — it neither contributes to matches nor interferes with the anti-join logic; it's simply inert.

### When to Use / Not Use

- **Use** whenever the business question is fundamentally about absence: "which X have no Y."
- **Don't use** `NOT IN` for this when there's any chance the subquery can return `NULL` — always default to `NOT EXISTS` or the `LEFT JOIN ... IS NULL` form instead.

### Compared to Other Joins

Anti-join is the set complement of an inner join on the same condition: `(anti-join rows)` ∪ `(inner-join left-side rows)` = the complete left table, with no overlap. It is also exactly `LEFT JOIN` minus the semi-join's positive result (§7.16 covers the complementary "at least one match exists" pattern).

### Real-World Use Cases

- Churn/re-engagement analysis: "customers who haven't ordered in the relationship's entire history" (or, combined with a date filter, "...in the last 90 days").
- Data-quality audits: "orphaned records," "foreign keys pointing nowhere" (in systems without enforced FK constraints).
- Inventory/catalog audits: "products with no stock record in any warehouse," "products never reviewed."
- Workforce analysis: "employees not staffed on any active project," as in Example 4.

---

## 7.16 Semi-Joins

### Simple Explanation

**What I write:** `WHERE EXISTS (SELECT 1 FROM right_table r WHERE r.key = l.key)`
**What the database logically does:** check, for each left row, whether *at least one* matching row exists on the right — without ever actually attaching or returning any of that right-hand row's columns, and without ever duplicating the left row even if multiple matches exist.
**What result is produced:** exactly the left table's rows that have a match, each appearing **exactly once**, with none of the right table's columns in the output.

### Technical Explanation

A semi-join answers "does a match exist?" as a yes/no test per left row, which is subtly but importantly different from an `INNER JOIN`: an `INNER JOIN` would return one row **per matching right-hand row** (potentially duplicating the left row many times over, per §7.12's cardinality rules), while a semi-join returns the left row **at most once**, regardless of how many matches exist on the right.

### Why It Exists

"Show me products that have at least one review" should return each qualifying product **once** — you don't want `UltraBook Pro 14` to appear as many times as it has reviews just because you asked an existence question, not a "show me the reviews" question. `EXISTS`/`IN` give you that guarantee directly; a naive `INNER JOIN` followed by `DISTINCT` gets there too, but at the cost of computing (and then discarding) every duplicate row first.

### Full Syntax — Two Common Forms

```sql
-- Form 1: EXISTS (correlated subquery) — generally preferred, handles NULLs safely
SELECT l.*
FROM left_table l
WHERE EXISTS (
    SELECT 1 FROM right_table r WHERE r.key = l.key
);

-- Form 2: IN (subquery) — fine as long as the subquery's column is NOT NULL
SELECT l.*
FROM left_table l
WHERE l.key IN (SELECT r.key FROM right_table r);
```

### Visual Diagram

```
Table: A (products)            Table: B (reviews)
+----+---------+               +----+------------+--------+
| id | name    |               | id | product_id | rating |
+----+---------+               +----+------------+--------+
| 1  | Widget  |               | 1  | 1          | 5      |
| 2  | Gadget  |               | 2  | 1          | 4      |
+----+---------+               +----+------------+--------+
```

`A WHERE EXISTS (... B.product_id = A.id)` — semi-join:

```
+----+--------+
| id | name   |
+----+--------+
| 1  | Widget |    <- appears ONCE, even though it has 2 matching reviews
+----+--------+
```

Compare with what a plain `INNER JOIN` would have done instead:

```
+----+--------+----+------------+--------+
| id | name   | id | product_id | rating |
+----+--------+----+------------+--------+
| 1  | Widget | 1  | 1          | 5      |    <- Widget duplicated
| 1  | Widget | 2  | 1          | 4      |    <- once per review
+----+--------+----+------------+--------+
```

This side-by-side is the entire point of a semi-join: it answers an existence question without paying the row-multiplication cost of a real join.

### Real Schema Examples

**Example 1 — "products that have at least one review," without duplicating the product row per review:**

```sql
SELECT p.product_id, p.product_name
FROM products p
WHERE EXISTS (
    SELECT 1 FROM reviews r WHERE r.product_id = p.product_id
)
ORDER BY p.product_id;
```

Output (verified — exactly one row per qualifying product, even though some have multiple reviews):

| product_id | product_name |
|---|---|
| 1 | Galaxy Phone X |
| 3 | UltraBook Pro 14 |
| 4 | GameBook 15 |
| 5 | Men Cotton Shirt |
| 9 | Wireless Earbuds |

Product 1 (Galaxy Phone X) actually has **2** reviews in the seed data (from `arjun_k` and `farhan_a`) — an `INNER JOIN products p JOIN reviews r ON p.product_id = r.product_id` would have returned Galaxy Phone X **twice**. The semi-join returns it exactly once, because `EXISTS` stops caring the moment it finds the *first* match — it never needs to enumerate every match.

**Example 2 — the equivalent `IN` form** (safe here because `reviews.product_id` is `NOT NULL`):

```sql
SELECT p.product_id, p.product_name
FROM products p
WHERE p.product_id IN (SELECT product_id FROM reviews)
ORDER BY p.product_id;
```

Identical output to Example 1.

**Example 3 — `company_db`: "departments that have at least one active project"** (semi-join, no duplicate department rows even though some departments could have multiple projects):

```sql
SELECT d.department_id, d.department_name
FROM departments d
WHERE EXISTS (
    SELECT 1 FROM projects p WHERE p.department_id = d.department_id
)
ORDER BY d.department_id;
```

Output: `Engineering`, `Sales`, `HR`, `Marketing` — 4 of the 5 departments (Finance is excluded, matching what §7.4 already showed via `LEFT JOIN`). Engineering has *two* projects (`Platform Migration`, `Mobile App Revamp`) yet appears **exactly once** here — the semi-join advantage.

### Line-by-Line Explanation (Example 1)

1. `FROM products p` — the driving table; every row is a candidate.
2. `WHERE EXISTS (SELECT 1 FROM reviews r WHERE r.product_id = p.product_id)` — for each product, the engine checks whether the correlated subquery (`r.product_id = p.product_id`, referencing the outer `p`) returns **any** row at all. `SELECT 1` is idiomatic — the actual column selected inside `EXISTS` is irrelevant and never returned; only "does a row exist" matters. The moment one matching row is found, the engine can stop checking (short-circuit) and move to the next product.

### What Happens Internally (preview)

Just like anti-joins, planners recognize `EXISTS`/`IN` (semi-join) patterns and typically execute them using a dedicated **hash semi-join** or **nested-loop semi-join** strategy that is specifically optimized to stop probing as soon as one match is found per left row — it does not materialize all matches the way an `INNER JOIN` would, which is exactly why it avoids the duplication cost entirely rather than computing duplicates and throwing them away afterward. Chapter 17 shows how to confirm this in an actual `EXPLAIN` plan.

### Common Mistakes

- Using `INNER JOIN ... DISTINCT` where a semi-join (`EXISTS`/`IN`) was the actually-intended, more efficient, and more directly-expressive tool — this works but does strictly more work (compute all matches, then deduplicate) for the same final answer.
- Using `IN` with a subquery whose column can be `NULL` — the same `NOT IN` trap from §7.15 has a (milder, but still real) cousin here: plain `IN` with `NULL`s present in the list doesn't break *positive* matches, but combined incorrectly with `NOT` elsewhere in the same query it's easy to introduce the anti-join `NOT IN` trap by refactoring later. Default to `EXISTS` as the safer long-term habit.
- Selecting columns from the subquery's table inside an `EXISTS`/semi-join and expecting them in the outer result — semi-joins, by definition, **never expose the right-hand table's columns**. If you need any column from the right table in the output, you need a real join (deduplicated appropriately, e.g., via aggregation or `DISTINCT ON` — the latter is a PostgreSQL-specific extension covered later in the course), not a semi-join.

### Edge Cases

- If the right table is empty, every `EXISTS` check fails and the semi-join returns zero rows — as expected.
- Multiple matches on the right side never affect the semi-join's output row count — this is the entire defining property of the pattern, verified directly above with Galaxy Phone X's two reviews collapsing to one output row.

### When to Use / Not Use

- **Use** whenever the question is "does a match exist," not "show me the matches" — you want the left row's own columns only, exactly once.
- **Don't use** when you actually need columns from the right-hand table in your result — that calls for a real (usually aggregated or deduplicated) join instead.

### Compared to Other Joins

Semi-join is the complement of anti-join on the same condition (§7.15): together, `(semi-join rows)` ∪ `(anti-join rows)` = the entire left table, with zero overlap. Compared to `INNER JOIN`, a semi-join is "`INNER JOIN`'s left-side row set, deduplicated by construction" — it never needs a `DISTINCT` step because it never multiplies rows in the first place.

### Real-World Use Cases

- "Customers with at least one order" for eligibility checks (e.g., loyalty programs), where you don't need order details, just the yes/no fact.
- "Products with at least one review" for a "customer favorites" filter on a storefront.
- "Departments with active headcount" style existence checks feeding into downstream reports, without inflating department row counts.

---

## 7.17 A First Look Under the Hood: Nested Loop, Hash, and Merge Joins

Every join in this chapter — regardless of its logical type (`INNER`, `LEFT`, anti-join, semi-join, etc.) — must be executed by the database engine using one of a small number of **physical algorithms**. This is only a first, conceptual pass; Chapter 17 (Query Execution & the Query Planner) covers reading real `EXPLAIN ANALYZE` output, cost estimation, and how the planner chooses between these strategies, in full depth.

- **Nested loop join** — for each row in the "outer" (driving) input, scan (or index-probe) the "inner" input for matches. Simple, always correct, and often the best choice when one side is small or an index makes the inner lookup cheap (e.g., looking up a single order's payment by indexed `order_id`). Cost scales roughly with `(outer rows) × (cost of one inner lookup)`.
- **Hash join** — build an in-memory hash table keyed on the join column(s) from one input (usually the smaller one), then scan the other input once, probing the hash table for matches. Excellent for large, unsorted inputs where an index isn't available or useful; used heavily for equi-joins like the ones throughout this chapter.
- **Merge join** — if both inputs are already sorted on the join key (e.g., because of an index, or an earlier `ORDER BY`/sort step), walk both sorted streams in lockstep, advancing whichever pointer is behind. Very efficient when the sort is "free" (already available), less so if a sort has to be performed specifically for the join.

> **Important Note**
> All three strategies, when correctly implemented, produce the **exact same logical result** for the exact same query — the choice between them is a performance decision made by the query planner, invisible to the query's meaning. This is precisely why this chapter has been able to describe join *behavior* purely in terms of "what rows come out," without ever needing to specify which algorithm produces them — that separation of logical correctness from physical execution is one of the foundational ideas of the relational model, and it's why you can trust every result table in this chapter regardless of which physical strategy your specific PostgreSQL installation happens to choose.

---

## 7.18 Dialect Cheat Sheet

| Feature | PostgreSQL | MySQL | Oracle | SQL Server |
|---|---|---|---|---|
| `INNER JOIN` | Yes | Yes | Yes | Yes |
| `LEFT [OUTER] JOIN` | Yes | Yes | Yes | Yes |
| `RIGHT [OUTER] JOIN` | Yes | Yes | Yes | Yes |
| `FULL OUTER JOIN` | Yes | **No** — use `LEFT JOIN UNION RIGHT JOIN` workaround (§7.6) | Yes | Yes |
| `CROSS JOIN` | Yes | Yes | Yes | Yes |
| Comma-join (`FROM a, b`) as implicit cross join | Yes | Yes | Yes | Yes |
| `NATURAL JOIN` | Yes (avoid in production — §7.9) | Yes (avoid) | Yes (avoid) | **No** — no equivalent keyword |
| `USING (col [, col...])` | Yes, including composite | Yes, including composite | Yes, including composite | **No** — must use `ON` |
| Legacy `(+)` outer join operator | No | No | Yes (legacy, avoid — use ANSI `JOIN`) | No |
| Self-join | Yes (standard aliasing) | Yes | Yes | Yes |
| Recognizes `LEFT JOIN ... IS NULL` / `NOT EXISTS` as anti-join internally | Yes | Yes | Yes | Yes |
| Recognizes `EXISTS`/`IN` as semi-join internally | Yes | Yes | Yes | Yes |

> **[MySQL]** Recap of the `FULL OUTER JOIN` workaround from §7.6:
> ```sql
> SELECT ... FROM a LEFT JOIN b ON a.key = b.key
> UNION
> SELECT ... FROM a RIGHT JOIN b ON a.key = b.key;
> ```
> **[Oracle]** If you ever encounter `WHERE a.id = b.id(+)` in legacy code, that `(+)` marks the side that gets `NULL`-padded when no match is found — it's a pre-ANSI-92 way of writing a `LEFT JOIN` (the `(+)` goes on the "optional" side). It cannot express `FULL OUTER JOIN` at all. Always prefer ANSI `JOIN ... ON` syntax in new code.
> **[SQL Server]** No `USING`, no `NATURAL JOIN` — always write full `ON` conditions. This is arguably a feature: it makes SQL Server code immune by construction to both of this chapter's biggest "silent breakage" risks (§7.9's `NATURAL JOIN` danger simply cannot be expressed).

---

## 7.19 Common Mistakes Recap

A consolidated list of every join-related mistake called out across this chapter, for quick review:

1. Forgetting `ON`, accidentally producing a `CROSS JOIN` (§7.7).
2. Filtering the "optional" side of a `LEFT JOIN` in `WHERE` instead of `ON`, silently reverting to `INNER JOIN` semantics (§7.11) — the single most important mistake in this chapter.
3. Using `RIGHT JOIN` out of habit instead of `LEFT JOIN` with reordered tables, hurting readability in long join chains (§7.5).
4. Using `NATURAL JOIN` in any code meant to survive a future schema change (§7.9).
5. Not verifying a relationship's cardinality before joining, leading to unpredicted row-count blowups (§7.12).
6. Summing/aggregating a "one"-side column after joining through a "many"-side table without pre-aggregating, causing silent double-counting (§7.13).
7. Confusing `COUNT(*)` with `COUNT(<column>)` after an outer join (§7.14).
8. Using `NOT IN` with a subquery that can return `NULL`, silently zeroing out an entire anti-join query (§7.15).
9. Using `INNER JOIN` + `DISTINCT` where `EXISTS`/`IN` (a semi-join) would be both simpler and cheaper (§7.16).
10. Forgetting to alias both sides of a self-join, or forgetting the `<>`/`<` guard in a peer self-join, causing self-pairing or mirrored duplicate pairs (§7.8).
11. Forgetting a composite-key join's second condition, or using `OR` where `AND` was meant, causing an accidental row explosion (§7.10).
12. Trusting an aggregate total without an independent sanity check based on known cardinality (§7.12, §7.13).

---

## 7.20 Practice Questions

No answers are provided — this is a textbook. Run every query yourself against the seed databases described in the [README](../README.md) and verify your own results.

1. Write a query that lists every order together with the username of the customer who placed it, using an `INNER JOIN` between `orders` and `users`.
2. Using `LEFT JOIN`, list every product together with its category name, including products whose category might be missing (there are none in this seed data — verify that fact with your query).
3. Write a query using `RIGHT JOIN` that lists every category together with any products in it, ordered so that categories with no products are easy to spot.
4. Write the same result as question 3 but using `LEFT JOIN` with the table order swapped, and confirm the two queries produce identical output.
5. Using a `FULL OUTER JOIN` on `categories` (self-joined on `parent_category_id`), identify which categories are "childless" (never appear as anyone's parent) and which are "orphans" (have no parent themselves). Which category satisfies both conditions?
6. Write a `CROSS JOIN` that generates every combination of `payment_method` (from `payments`) and `warehouse_location` (from `inventory`), and count how many rows it produces.
7. Using a self-join on `employees`, list every employee together with their manager's job title (not just their manager's name).
8. Using `NOT EXISTS`, find every product in `ecommerce_db` that has never appeared in any `order_items` row. What do you expect the result to be, based on what you know about the seed data — and does the query confirm it?
9. Using `EXISTS`, find every department in `company_db` that has at least one employee earning a `base_salary` (from the most recent `salaries` row for that employee) above 200,000 — without duplicating a department row for each qualifying employee.
10. Write a query joining `orders`, `order_items`, and `products` for user `sara_p`, and manually verify the row count you expect before running it, based on how many order items her orders actually contain.
11. Demonstrate the `ON` vs `WHERE` distinction yourself: write a `LEFT JOIN` from `orders` to `payments` filtering `payment_method = 'CARD'` once in `ON` and once in `WHERE`, and explain in your own words why the row counts differ (or don't — check whether every `CARD` payment happens to also succeed, and what that implies about when this bug is visible versus hidden).
12. Using the `inventory` table's composite key, write a query that finds every product stocked in **exactly one** warehouse (the complement of the composite self-join example in §7.10).

---

## 7.21 Difficult Join Problems

These are intentionally harder than the practice questions above — several require chaining anti-joins, semi-joins, and multi-table joins together, or combining self-joins with aggregation. No answers are provided.

1. **Full chain, filtered by absence:** Find every user in `ecommerce_db` who has placed at least one order that was `DELIVERED`, but who has never written a single review for any product — combining a semi-join (on `orders`) with an anti-join (on `reviews`) in the same query.

2. **Fan-out audit:** For every order in `ecommerce_db`, compute the "naive" total (as in §7.13, by joining `orders` → `order_items` → `payments` and summing `payments.amount` without pre-aggregating) and the "correct" total (summing `order_items.quantity * order_items.unit_price` directly, grouped by order, with no `payments` join at all). Write a single query, using whichever combination of joins and grouping you need, that shows both totals side by side for every order and flags which orders would have been over-counted by the naive approach — i.e., which orders have more than one line item.

3. **Three-generation hierarchy with a twist:** Using `company_db`, for every employee, find their manager's manager (their "grandmanager") — but instead of using a fixed 2-level self-join chain, write the query so that it also correctly reports `NULL` for both `manager` and `grandmanager` in the case of employees who are missing one or both levels (i.e., don't let a missing manager silently exclude the employee, or a missing grandmanager silently exclude the whole row). Which employees have a `NULL` grandmanager despite having a real manager?

4. **Never-staffed departments, the hard way:** Using `company_db`, find every department where **every single employee** in that department has zero project assignments (in `employee_projects`) — not just departments with *some* unassigned employees, but departments where *nobody at all* is assigned to any project. (Hint: this requires combining an anti-join pattern per-employee with an aggregate/`HAVING` check per-department, or a `NOT EXISTS` correlated at the department level instead of the employee level.)

5. **Cross-schema-style reconciliation:** Using only `ecommerce_db`, treat `orders` and `payments` as if they were two independently-maintained systems that should reconcile 1:1. Write a `FULL OUTER JOIN`-based query (or the portable `UNION`-based equivalent from §7.6's MySQL workaround, even though you're on PostgreSQL) that would surface, in a single result set: (a) any order with no payment at all, and (b) any payment referencing an order that doesn't exist. Given the seed data's actual foreign key constraints, explain in a comment above your query why you should expect zero rows in category (b) specifically, and what would have to be true of the schema for that category to ever be non-empty.

6. **Composite-key completeness check:** Using the `inventory` table's composite key `(product_id, warehouse_location)`, find every product that is stocked in **fewer than all three** of the warehouses that appear anywhere in the `inventory` table (`Mumbai-WH1`, `Delhi-WH2`, `Pune-WH1`) — i.e., every product that is *missing* from at least one warehouse. This requires a `CROSS JOIN` (to generate the full product × warehouse grid) combined with an anti-join or semi-join against the real `inventory` rows.

7. **The double bug:** Write a query that combines *both* the ON-vs-WHERE bug (§7.11) *and* the duplicate-row bug (§7.13) in the same query — a `LEFT JOIN` chain from `orders` through `order_items` to `payments`, with a `payments.status = 'SUCCESS'` filter mistakenly placed in `WHERE`, that is then (incorrectly) used to `SUM(payments.amount)` per user. Compute the doubly-wrong total for at least one user with more than one multi-item order, and explain, step by step, both distinct ways this query's result diverges from the truly correct total.

---

## Key Takeaways

- A `JOIN` is conceptually a Cartesian product filtered by a predicate — every join type in this chapter is a variation on that single idea.
- `INNER JOIN` keeps only mutually matched rows; `LEFT`/`RIGHT` guarantee one side's rows always survive (padded with `NULL` where unmatched); `FULL OUTER` guarantees both sides do.
- `CROSS JOIN` has no predicate at all and is the deliberate tool for generating combinations — and the accidental result of a forgotten `WHERE` in a comma-join.
- Self-joins are not a distinct join type — they're any join where both sides reference the same table, requiring mandatory aliasing, and they're the standard tool for hierarchies and peer comparisons up to a fixed depth (arbitrary depth needs recursive CTEs, Chapter 9).
- **Never use `NATURAL JOIN` in production** — it silently redefines its join key based on whatever columns happen to share a name, which can (and, as shown with `orders`/`payments`' shared `status` column, does) silently corrupt results the moment a schema gains a new shared column name.
- `ON` decides what counts as a match, before outer-join padding happens; `WHERE` filters the join's already-finished output. A condition on the "optional" side of a `LEFT JOIN`, if placed in `WHERE`, silently turns it back into an `INNER JOIN` — verified with a real 10-row-vs-8-row example in this chapter.
- Join cardinality (1:1, 1:N, M:N) determines exactly how output row counts multiply — know it before you write the join, not after you're debugging a wrong total.
- A "one"-side value (like a payment amount) joined through a "many"-side table (like order line items) gets duplicated once per match — summing it afterward silently inflates totals; pre-aggregate the "many" side instead.
- `NULL` behaves two different ways in joins: it never matches as a join key, and it's used deliberately to pad the unmatched side of an outer join — both interact with `WHERE` and aggregate functions in specific, learnable, non-obvious ways.
- Anti-joins (`LEFT JOIN ... IS NULL`, `NOT EXISTS`) answer "what's missing"; semi-joins (`EXISTS`, `IN`) answer "does a match exist" without ever duplicating the left row. Prefer `NOT EXISTS` over `NOT IN` whenever `NULL`s might be present.
- The logical result of a join never depends on which physical algorithm (nested loop, hash, merge) the engine picks to execute it — that choice is purely a performance decision, covered in full in Chapter 17.

---

## What's Next

Chapter 8 moves from combining tables *side by side* (joins) to combining queries *inside* other queries: **Subqueries** — scalar, correlated, and uncorrelated subqueries in `SELECT`, `FROM`, and `WHERE`; the exact `NOT IN`/`NULL` trap flagged in this chapter's anti-join section, examined in full; and how a subquery-based semi-join/anti-join compares, mechanically and in performance, to the `JOIN`-based patterns you just learned here.

**Continue to [Chapter 8 — Subqueries](08-subqueries.md).**
