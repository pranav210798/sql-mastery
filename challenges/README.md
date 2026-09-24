# Chapter 34 — SQL Challenges (Levels 1–6)

A graded, progressively difficult problem set built entirely around the four
canonical databases (`company_db`, `ecommerce_db`, `banking_db`,
`analytics_db`) used throughout this course. These are **not** syntax
drills — every challenge is framed as a realistic business ask, the way a
manager, analyst, or engineer would actually phrase it to you.

## How to use this chapter

Each challenge has five parts, but only the **Problem** is shown up front.
Work through them in order:

1. **Read the Problem.** Try to write the query yourself before looking at
   anything else. Open a `psql` session against the relevant database and
   actually run what you write.
2. **Stuck? Open the Hint.** It nudges you toward the right concept or
   technique without revealing the query.
3. **Still stuck, or want to sanity-check your plan? Open Expected
   Approach.** This is a plain-language strategy outline — no code — so you
   can compare your mental model to a working one before you commit to
   syntax.
4. **Only then open Solution.** It's the complete, runnable query.
5. **Always read Detailed Explanation**, even if your query already worked.
   It walks through *why* the query works, calls out common mistakes, and
   shows the actual output against the real seed data so you can check your
   own result set line for line.

> **Important Notes**
> - Challenges against `company_db`, `ecommerce_db`, and `banking_db` show
>   **actual, verified output** produced by running the query against the
>   exact seed data shipped in `databases/`. If your result set differs,
>   something in your query (or your understanding of the data) is off —
>   go find the discrepancy.
> - Challenges against `analytics_db` (Level 6, and anywhere else it's
>   used) are marked **[Illustrative]**. That database is populated with
>   `random()` via `generate_series`, so exact row counts and totals differ
>   on every fresh load and at every scale (200K rows vs. the full 5M-row
>   production load). The *query itself*, the *technique*, and the *shape*
>   of the plan/output shown are real and were verified against a live
>   PostgreSQL instance — only the specific numbers will vary for you.
> - All solutions target **PostgreSQL 15+**. Where a technique is
>   PostgreSQL-specific (e.g., `DISTINCT ON`, `generate_series`, native
>   partitioning), that's called out.
> - Difficulty is cumulative — Level 4+ assumes comfort with joins,
>   subqueries, and CTEs from Levels 1–3.

---

## Level 1 — Beginner

Single-table `SELECT` / `WHERE` / `ORDER BY` / basic functions against
`company_db` or `ecommerce_db`.

### Challenge 1.1: Engineering headcount tenure report **[PostgreSQL]**

**Problem:** The Engineering director is preparing for annual performance
reviews and wants a simple roster of everyone currently active in the
Engineering department (`department_id = 1`), ordered from longest-tenured
to newest hire, so she can prioritize senior staff conversations first.
Query `company_db.employees` to return `employee_id`, `first_name`,
`last_name`, `job_title`, and `hire_date` for active Engineering employees,
sorted by hire date ascending (oldest hire first).

<details>
<summary>Hint</summary>

You need two conditions in your `WHERE` clause combined with `AND`, and a
single-column `ORDER BY`. "Longest-tenured first" means the earliest
`hire_date` comes first — think about which sort direction that is.

</details>

<details>
<summary>Expected Approach</summary>

1. Select the required columns from `employees`.
2. Filter rows where `department_id = 1` (Engineering) **and**
   `status = 'ACTIVE'`.
3. Sort by `hire_date` ascending so the earliest hires appear first.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT employee_id, first_name, last_name, job_title, hire_date
FROM company_db.employees
WHERE status = 'ACTIVE'
  AND department_id = 1
ORDER BY hire_date ASC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `WHERE status = 'ACTIVE'` excludes the one Engineering row that's
  `ON_LEAVE` (Ananya Singh, employee 5).
- `WHERE ... AND department_id = 1` restricts to Engineering only, using
  the department's surrogate key rather than the name — this is both
  faster (an integer comparison) and safer (no risk of a typo in a string
  literal).
- `ORDER BY hire_date ASC` — the earliest date sorts first in ascending
  order, so the longest-tenured employee (Aditi Rao, hired 2015-03-01)
  appears at the top.

**Actual output:**

| employee_id | first_name | last_name | job_title            | hire_date  |
|---|---|---|---|---|
| 1  | Aditi  | Rao      | CTO                  | 2015-03-01 |
| 2  | Rahul  | Mehta    | Engineering Manager  | 2016-05-12 |
| 3  | Sneha  | Kulkarni | Senior Engineer      | 2017-01-20 |
| 4  | Vikram | Joshi    | Software Engineer    | 2018-07-15 |
| 6  | Karan  | Verma    | Junior Engineer      | 2020-02-10 |
| 16 | Aman   | Chawla   | Software Engineer    | 2022-01-10 |

Notice employee 5 (Ananya Singh, `ON_LEAVE`) is correctly excluded even
though she belongs to Engineering — this is the whole point of the
`status` filter.

</details>

---

### Challenge 1.2: Premium catalog listing **[PostgreSQL]**

**Problem:** The merchandising team is building a "premium products" banner
for the homepage and needs every product priced above ₹2,000, most
expensive first, so the highest-margin items get top placement.

<details>
<summary>Hint</summary>

A single numeric comparison in `WHERE`, and a descending sort on the same
column you filtered on.

</details>

<details>
<summary>Expected Approach</summary>

1. Select `product_name`, `sku`, `price` from `products`.
2. Filter for `price > 2000`.
3. Order by `price` descending.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT product_name, sku, price
FROM ecommerce_db.products
WHERE price > 2000
ORDER BY price DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

`price` is `NUMERIC(10,2)`, so the comparison `price > 2000` is an exact
decimal comparison (no floating-point surprises). Sorting `DESC` puts the
₹89,999 laptop first and the ₹2,499 pan set last among qualifying rows.

**Actual output:**

| product_name       | sku          | price    |
|---|---|---|
| UltraBook Pro 14   | SKU-LAP-001  | 89999.00 |
| GameBook 15        | SKU-LAP-002  | 74999.00 |
| Galaxy Phone X     | SKU-MOB-001  | 45999.00 |
| Pixel Lite         | SKU-MOB-002  | 29999.00 |
| Wireless Earbuds   | SKU-MOB-003  |  3499.00 |
| Non-stick Pan Set  | SKU-HOM-001  |  2499.00 |

Six of the ten seeded products qualify. Note the strict `>` excludes any
product priced at exactly 2000 — there happens to be none in the seed
data, but it's worth double-checking boundary behavior on real datasets.

</details>

---

### Challenge 1.3: Formatted employee directory **[PostgreSQL]**

**Problem:** IT is migrating to a new intranet directory tool that expects
names in `LASTNAME, Firstname` format (last name in caps) and wants the
email domain surfaced separately so they can flag any non-corporate
addresses later. Produce `employee_id`, a `display_name` column formatted
as `LASTNAME, Firstname`, an `email_domain` column, and `job_title`, sorted
alphabetically by last name.

<details>
<summary>Hint</summary>

You'll need string concatenation (`||`), a case-folding function
(`UPPER`), and a way to pull the part of the email after the `@` —
`SPLIT_PART` is built exactly for this.

</details>

<details>
<summary>Expected Approach</summary>

1. Build `display_name` by concatenating `UPPER(last_name)`, a literal
   `', '`, and `first_name`.
2. Extract the domain from `email` using `SPLIT_PART(email, '@', 2)`.
3. Select `employee_id`, `display_name`, `email_domain`, `job_title`.
4. Order by `last_name`.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT
    employee_id,
    UPPER(last_name) || ', ' || first_name AS display_name,
    LOWER(SPLIT_PART(email, '@', 2)) AS email_domain,
    job_title
FROM company_db.employees
ORDER BY last_name;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `UPPER(last_name) || ', ' || first_name` concatenates three pieces into
  one string per row — `||` is the standard SQL string-concatenation
  operator.
- `SPLIT_PART(email, '@', 2)` splits the email on `@` and returns the
  2nd piece (everything after the `@`); `LOWER()` normalizes case in case
  any addresses were entered inconsistently.
- The final `ORDER BY last_name` sorts on the *underlying column*, not the
  computed `display_name` alias — this matters because sorting on the
  already-uppercased alias vs. the raw column can behave identically here
  (since collation on this string doesn't depend on case for ordering
  purposes in the default locale), but sorting on the source column is the
  more explicit, dependable habit.

**Actual output (16 rows, first 5 shown):**

| employee_id | display_name    | email_domain | job_title            |
|---|---|---|---|
| 11 | BHATT, Isha     | company.com | HR Executive          |
| 16 | CHAWLA, Aman    | company.com | Software Engineer     |
| 8  | DAS, Arjun      | company.com | Sales Executive       |
| 12 | GUPTA, Nikhil   | company.com | Finance Manager       |
| 14 | IYER, Rajesh    | company.com | Marketing Manager     |

Every row shares the same `email_domain` (`company.com`) in this seed
data — that's expected, since IT's real question ("are there any
non-corporate addresses?") would only become interesting once external
contractor accounts are added.

</details>

---

### Challenge 1.4: Targeted re-engagement list **[PostgreSQL]**

**Problem:** Marketing wants to send a "we miss you" campaign to active
users who signed up in May 2023, to see whether early adopters from that
cohort are still engaged. Return `user_id`, `username`, `full_name`, and
`created_at` for active users created during May 2023, earliest sign-up
first.

<details>
<summary>Hint</summary>

`created_at` is a `TIMESTAMP`, not a `DATE` — think about how to express
"the whole month of May 2023" as a half-open range (`>=` start, `<` start
of next month) rather than trying to match on a formatted string.

</details>

<details>
<summary>Expected Approach</summary>

1. Filter `is_active = TRUE`.
2. Filter `created_at >= '2023-05-01'` and `created_at < '2023-06-01'`.
3. Select the four required columns, order by `created_at`.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT user_id, username, full_name, created_at
FROM ecommerce_db.users
WHERE created_at >= '2023-05-01'
  AND created_at <  '2023-06-01'
  AND is_active = TRUE
ORDER BY created_at;
```

</details>

<details>
<summary>Detailed Explanation</summary>

Using a half-open range (`>= start of month AND < start of next month`) is
the standard, index-friendly way to filter "all of May" on a `TIMESTAMP`
column — it correctly includes `2023-05-31 23:59:59.999...` without
needing to know the exact last instant of the month, and (unlike wrapping
the column in `EXTRACT(MONTH FROM created_at) = 5`) it doesn't prevent the
planner from using a B-tree index on `created_at` at scale.

**Actual output:**

| user_id | username | full_name    | created_at          |
|---|---|---|---|
| 5 | imran_s | Imran Sheikh | 2023-05-17 08:00:00 |

Only one user in the seed data was created in May 2023, and they're
active, so the filter correctly returns a single row.

</details>

---

### Challenge 1.5: Engineering-title pattern search **[PostgreSQL]**

**Problem:** HR is auditing job titles before a compensation-banding
project and wants every employee whose title suggests an engineering
role — "Engineer" anywhere in the title, regardless of seniority prefix or
case — so they can cross-check against the Engineering department
roster for mismatches (e.g., an "Engineer" title sitting outside
Engineering).

<details>
<summary>Hint</summary>

You need pattern matching, not an exact match, and it should be
case-insensitive without you having to manually `UPPER()`/`LOWER()` both
sides.

</details>

<details>
<summary>Expected Approach</summary>

1. Use a case-insensitive pattern match on `job_title` for the substring
   "engineer".
2. Select `employee_id`, `first_name`, `last_name`, `job_title`.
3. Order by `job_title` for readability.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT employee_id, first_name, last_name, job_title
FROM company_db.employees
WHERE job_title ILIKE '%engineer%'
ORDER BY job_title;
```

</details>

<details>
<summary>Detailed Explanation</summary>

`ILIKE` is PostgreSQL's case-insensitive `LIKE`. The `%` wildcards on both
sides mean "engineer" can appear anywhere in the string — at the start
("Engineering Manager"), middle, or as the whole trailing word ("Software
Engineer"). This correctly catches "Engineering Manager" even though it
doesn't literally contain the standalone word "Engineer" as a suffix — it
contains the substring "engineer" as a prefix of "Engineering", which is
exactly the loose, real-world matching HR asked for.

**Actual output:**

| employee_id | first_name | last_name | job_title            |
|---|---|---|---|
| 2  | Rahul  | Mehta    | Engineering Manager |
| 6  | Karan  | Verma    | Junior Engineer     |
| 3  | Sneha  | Kulkarni | Senior Engineer     |
| 4  | Vikram | Joshi    | Software Engineer   |
| 5  | Ananya | Singh    | Software Engineer   |
| 16 | Aman   | Chawla   | Software Engineer   |

All six matches happen to already sit in Engineering (`department_id = 1`)
in this seed data — a real audit would join against `departments` to
surface mismatches, which is exactly the kind of question Level 2/3
challenges build toward.

</details>

---

### Challenge 1.6: Negative review triage queue **[PostgreSQL]**

**Problem:** Customer support wants a daily queue of low-rated reviews (2
stars or fewer) that need a personal follow-up email, most recent
complaint first, so nothing sits unanswered.

<details>
<summary>Hint</summary>

Single-table filter on a numeric column, sorted by a timestamp — but pay
attention to which direction "most recent first" is.

</details>

<details>
<summary>Expected Approach</summary>

1. Filter `reviews` where `rating <= 2`.
2. Select `review_id`, `product_id`, `user_id`, `rating`, `review_text`,
   `review_date`.
3. Order by `review_date` descending.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT review_id, product_id, user_id, rating, review_text, review_date
FROM ecommerce_db.reviews
WHERE rating <= 2
ORDER BY review_date DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

`rating <= 2` catches both 1-star and 2-star reviews (the column is
constrained to 1–5, so this is safe without an explicit lower bound).
`ORDER BY review_date DESC` puts the newest complaint at the top of
support's queue.

**Actual output:**

| review_id | product_id | user_id | rating | review_text                  | review_date          |
|---|---|---|---|---|---|
| 6 | 1 | 7 | 2 | Received a defective unit. | 2024-02-16 11:00:00 |

Only one review in the seed data meets the "2 stars or fewer" bar — it's
a defective-unit complaint on the Galaxy Phone X, exactly the kind of row
support should see first.

</details>

---

## Level 2 — Basic

Aggregates, `GROUP BY`/`HAVING`, and simple two-table joins.

### Challenge 2.1: Department staffing report **[PostgreSQL]**

**Problem:** The COO wants to know which departments are "fully staffed"
by her informal rule of thumb — at least 3 active employees — along with
each department's office location, for a headcount-planning meeting.

<details>
<summary>Hint</summary>

Join the two tables, group by department, count active employees per
group, and filter *groups* (not rows) using the clause that runs after
`GROUP BY`.

</details>

<details>
<summary>Expected Approach</summary>

1. Join `departments` to `employees` on `department_id`.
2. Filter to `status = 'ACTIVE'` employees only.
3. Group by department name and location.
4. Use `HAVING COUNT(*) >= 3` to keep only qualifying departments.
5. Order by headcount descending.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT d.department_name, d.location, COUNT(*) AS active_headcount
FROM company_db.departments d
JOIN company_db.employees e ON e.department_id = d.department_id
WHERE e.status = 'ACTIVE'
GROUP BY d.department_name, d.location
HAVING COUNT(*) >= 3
ORDER BY active_headcount DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- The `WHERE e.status = 'ACTIVE'` filter runs **before** grouping, so
  terminated/on-leave employees never enter the count.
- `GROUP BY d.department_name, d.location` collapses all matching
  employee rows per department into one summary row.
- `HAVING COUNT(*) >= 3` is the key distinction from `WHERE`: `HAVING`
  filters on the *aggregated* result (the group's row count), which
  cannot be evaluated until after grouping happens — that's why it can't
  live in `WHERE`.

**Actual output:**

| department_name | location | active_headcount |
|---|---|---|
| Engineering | Pune | 6 |

Only Engineering clears the 3-person bar with active staff (5 active +
one who moved counts, Sales/HR/Finance/Marketing each have 1–2 active
employees). This is a real, if slightly anticlimactic, finding — it
correctly tells the COO that only one department currently meets her
threshold.

</details>

---

### Challenge 2.2: Project budget rollup by department **[PostgreSQL]**

**Problem:** Finance is reviewing which departments carry the largest
project-budget exposure this cycle and wants a rollup of total committed
budget by department, restricted to departments carrying more than
₹500,000 in aggregate, to prioritize the year-end audit.

<details>
<summary>Hint</summary>

This is the same join-then-group-then-filter-the-group pattern as 2.1, but
the aggregate is `SUM` instead of `COUNT`, and the join runs the other
direction (departments to their projects).

</details>

<details>
<summary>Expected Approach</summary>

1. Join `departments` to `projects` on `department_id`.
2. Group by department name.
3. Aggregate `COUNT(project_id)` and `SUM(budget)`.
4. Use `HAVING SUM(budget) > 500000`.
5. Order by total budget descending.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT d.department_name,
       COUNT(p.project_id) AS project_count,
       SUM(p.budget) AS total_budget
FROM company_db.departments d
JOIN company_db.projects p ON p.department_id = d.department_id
GROUP BY d.department_name
HAVING SUM(p.budget) > 500000
ORDER BY total_budget DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

An inner `JOIN` (rather than `LEFT JOIN`) is appropriate here because
departments with zero projects contribute nothing to a budget rollup and
would just show `NULL`/`0` noise — Finance only cares about departments
that actually have project spend. `SUM(p.budget)` adds up every matching
project row per department, and `HAVING` filters after that sum is
computed.

**Actual output:**

| department_name | project_count | total_budget |
|---|---|---|
| Engineering | 2 | 8000000.00 |
| Sales       | 1 | 1200000.00 |
| Marketing   | 1 | 800000.00  |

HR's single project (Employee Wellness, ₹250,000) falls below the
threshold and correctly drops out of the report.

</details>

---

### Challenge 2.3: Payment method reconciliation **[PostgreSQL]**

**Problem:** The finance team reconciling this quarter's gateway settlement
report wants total successfully collected revenue broken down by payment
method, but only wants to see methods that moved a meaningful volume
(over ₹5,000 total) to avoid cluttering the report with negligible
channels.

<details>
<summary>Hint</summary>

This one doesn't need a join at all — everything you need lives on a
single table. Filter rows first, then aggregate, then filter groups.

</details>

<details>
<summary>Expected Approach</summary>

1. Filter `payments` to `status = 'SUCCESS'`.
2. Group by `payment_method`.
3. Aggregate `COUNT(*)` and `SUM(amount)`.
4. Use `HAVING SUM(amount) > 5000`.
5. Order by total collected descending.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT payment_method,
       COUNT(*) AS successful_payments,
       SUM(amount) AS total_collected
FROM ecommerce_db.payments
WHERE status = 'SUCCESS'
GROUP BY payment_method
HAVING SUM(amount) > 5000
ORDER BY total_collected DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

Filtering `status = 'SUCCESS'` in `WHERE` (before grouping) is important —
it excludes the `FAILED` and `PENDING` payments (orders 5 and 7) so
they don't inflate "collected" revenue, which by definition should only
count money that actually landed.

**Actual output:**

| payment_method | successful_payments | total_collected |
|---|---|---|
| CARD       | 3 | 185496.00 |
| UPI        | 3 | 100893.00 |
| NETBANKING | 1 | 75798.00  |

`COD` and `WALLET` exist in the seed data too, but each only has one
successful payment under ₹5,000 (`WALLET` at 3897.00) or is still
`PENDING` (`COD`), so they're correctly filtered out by the `HAVING`
clause.

</details>

---

### Challenge 2.4: Repeat customer identification **[PostgreSQL]**

**Problem:** The loyalty program team wants to identify customers who have
placed 2 or more orders (regardless of status) so they can be enrolled in
a "valued customer" tier automatically.

<details>
<summary>Hint</summary>

Join users to orders, group by customer, and count orders per group —
then keep only groups above the threshold.

</details>

<details>
<summary>Expected Approach</summary>

1. Join `users` to `orders` on `user_id`.
2. Group by `user_id` (and `full_name` for display).
3. Count orders per group.
4. Filter with `HAVING COUNT(order_id) >= 2`.
5. Order by order count descending.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT u.user_id, u.full_name, COUNT(o.order_id) AS order_count
FROM ecommerce_db.users u
JOIN ecommerce_db.orders o ON o.user_id = u.user_id
GROUP BY u.user_id, u.full_name
HAVING COUNT(o.order_id) >= 2
ORDER BY order_count DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

Because `full_name` is functionally dependent on `user_id` (each user has
exactly one name), it's safe to include it in the `SELECT` and `GROUP BY`
list alongside `user_id` — PostgreSQL requires every non-aggregated
selected column to appear in `GROUP BY`. `COUNT(o.order_id)` counts
matching order rows per user after the join; `HAVING` then filters to
users with 2+ orders.

**Actual output:**

| user_id | full_name   | order_count |
|---|---|---|
| 1 | Arjun Kumar | 3 |

Arjun Kumar (user 1) placed orders 1, 3, and 8 — the only customer in
this small seed set who qualifies as a repeat customer under the 2+
threshold.

</details>

---

### Challenge 2.5: Category catalog pricing analysis **[PostgreSQL]**

**Problem:** The category management team wants an average-price snapshot
per category, but only for categories that actually have some product
depth (2 or more SKUs) — single-product categories aren't useful for a
pricing-strategy comparison.

<details>
<summary>Hint</summary>

Join categories to products, group by category, and compute both a count
and an average in the same query.

</details>

<details>
<summary>Expected Approach</summary>

1. Join `categories` to `products` on `category_id`.
2. Group by `category_name`.
3. Aggregate `COUNT(product_id)` and `AVG(price)`.
4. Filter with `HAVING COUNT(product_id) >= 2`.
5. Order by average price descending.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT c.category_name,
       COUNT(p.product_id) AS product_count,
       ROUND(AVG(p.price), 2) AS avg_price
FROM ecommerce_db.categories c
JOIN ecommerce_db.products p ON p.category_id = c.category_id
GROUP BY c.category_name
HAVING COUNT(p.product_id) >= 2
ORDER BY avg_price DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

`AVG(p.price)` naturally returns a value with more decimal places than
the underlying `NUMERIC(10,2)` column would suggest is meaningful, so
`ROUND(..., 2)` keeps the output in sensible currency precision. The
`HAVING COUNT(p.product_id) >= 2` filter drops "Men" (1 product: Men
Cotton Shirt) and "Women" (1 product: Women Kurta Set) from the report.

**Actual output:**

| category_name  | product_count | avg_price |
|---|---|---|
| Laptops        | 3 | 55265.67 |
| Mobiles        | 3 | 26499.00 |
| Home & Kitchen | 2 | 1999.00  |

</details>

---

### Challenge 2.6: Multi-account customer exposure **[PostgreSQL]**

**Problem:** The bank's relationship-management team wants a list of
customers holding more than one account, along with their combined
balance across all accounts, so relationship managers know who to invite
to the premium-banking pilot.

<details>
<summary>Hint</summary>

Join customers to accounts, group by customer, and use `HAVING` on the
count of accounts, while also summing balance in the same aggregation
pass.

</details>

<details>
<summary>Expected Approach</summary>

1. Join `customers` to `accounts` on `customer_id`.
2. Group by customer (id and a display name).
3. Aggregate `COUNT(account_id)` and `SUM(balance)`.
4. Filter with `HAVING COUNT(account_id) > 1`.
5. Order by combined balance descending.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name AS customer_name,
       COUNT(a.account_id) AS account_count,
       SUM(a.balance) AS combined_balance
FROM banking_db.customers c
JOIN banking_db.accounts a ON a.customer_id = c.customer_id
GROUP BY c.customer_id, customer_name
HAVING COUNT(a.account_id) > 1
ORDER BY combined_balance DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

Note that `customer_name` (the alias) is reused in `GROUP BY` — PostgreSQL
allows referencing a `SELECT`-list alias in `GROUP BY` (unlike in
`WHERE`), so you don't have to repeat the `||` expression. `SUM(a.balance)`
adds up every account row belonging to that customer post-join.

**Actual output:**

| customer_id | customer_name | account_count | combined_balance |
|---|---|---|---|
| 3 | Suresh Menon | 2 | 800000.00 |
| 1 | Ravi Shankar | 2 | 200000.00 |

Suresh Menon holds a SAVINGS (₹300,000) and a FIXED_DEPOSIT (₹500,000)
account; Ravi Shankar holds SAVINGS (₹150,000) and CURRENT (₹50,000).
Customers 2, 4, and 5 each hold exactly one account and are correctly
excluded.

</details>

---

## Level 3 — Intermediate

Multi-table joins (3+ tables), subqueries, and basic CTEs, walking the
`ecommerce_db` users → orders → order_items → products → payments chain
and the `company_db` employee/department/project chain.

### Challenge 3.1: Customer lifetime value leaderboard **[PostgreSQL]**

**Problem:** The VP of Growth wants a lifetime-value leaderboard: for every
customer, their total non-cancelled order value, ranked highest spender
first, so the top accounts can be handed to the key-accounts team.

<details>
<summary>Hint</summary>

Order value lives across two levels: `orders` and `order_items`
(quantity × unit price). Consider computing per-order totals first in a
CTE, then rolling those up per customer — that's cleaner than trying to
aggregate across the 3-table join directly with nested `SUM`s.

</details>

<details>
<summary>Expected Approach</summary>

1. In a CTE, join `orders` to `order_items`, exclude `CANCELLED` orders,
   and compute `SUM(quantity * unit_price)` per `order_id`.
2. Join that CTE's results back to `users`.
3. Group by customer, sum the per-order totals into a lifetime value,
   and count orders.
4. Order by lifetime value descending.

</details>

<details>
<summary>Solution</summary>

```sql
WITH order_totals AS (
  SELECT o.order_id, o.user_id, SUM(oi.quantity * oi.unit_price) AS order_total
  FROM ecommerce_db.orders o
  JOIN ecommerce_db.order_items oi ON oi.order_id = o.order_id
  WHERE o.status <> 'CANCELLED'
  GROUP BY o.order_id, o.user_id
)
SELECT u.user_id, u.full_name,
       COUNT(ot.order_id) AS orders_count,
       SUM(ot.order_total) AS lifetime_value
FROM ecommerce_db.users u
JOIN order_totals ot ON ot.user_id = u.user_id
GROUP BY u.user_id, u.full_name
ORDER BY lifetime_value DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- The CTE `order_totals` first collapses `order_items` (which has one row
  per product per order) down to one row per order, with `order_total`
  computed as the sum of `quantity * unit_price` across that order's
  line items. Filtering out `CANCELLED` orders here (before any
  aggregation) ensures cancelled purchases never count toward lifetime
  value.
- The outer query then joins `users` to this pre-aggregated CTE and
  performs a **second** aggregation — summing `order_total` per customer
  and counting how many orders contributed. Doing this in two stages
  avoids the classic "fan-out" bug where joining `orders` directly to
  `order_items` and then trying to `SUM` at the customer level in one
  pass would double-count values if a customer had multiple orders each
  with multiple items (the aggregation grain has to be resolved in
  stages).

**Actual output:**

| user_id | full_name      | orders_count | lifetime_value |
|---|---|---|---|
| 1 | Arjun Kumar    | 3 | 185496.00 |
| 7 | Farhan Ali     | 1 | 93498.00  |
| 5 | Imran Sheikh   | 1 | 75798.00  |
| 6 | Lakshmi Venkat | 1 | 6998.00   |
| 2 | Sara Patel     | 1 | 5097.00   |
| 8 | Tanya Bose     | 1 | 3897.00   |
| 3 | Dev Malhotra   | 1 | 3298.00   |

Note user 4 (Nita Rao) is absent entirely: her only order (order 5) was
`CANCELLED`, so she correctly drops out of a lifetime-value report.

</details>

---

### Challenge 3.2: Best-selling products by revenue **[PostgreSQL]**

**Problem:** Merchandising wants the top 5 products by revenue,
counting only orders that actually resulted in a committed sale (`PAID`,
`SHIPPED`, or `DELIVERED` — not `PENDING` or `CANCELLED`), to decide what
to feature in next month's catalog.

<details>
<summary>Hint</summary>

Three tables are involved: you need the product name (from `products`),
the line-item quantity/price (from `order_items`), and the order's
fulfillment status (from `orders`) to filter correctly.

</details>

<details>
<summary>Expected Approach</summary>

1. Join `order_items` to `orders` (for status) and to `products` (for
   name).
2. Filter `orders.status IN ('PAID','SHIPPED','DELIVERED')`.
3. Group by product, summing quantity and revenue.
4. Order by revenue descending, limit to 5.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT p.product_name,
       p.category_id,
       SUM(oi.quantity) AS units_sold,
       SUM(oi.quantity * oi.unit_price) AS revenue
FROM ecommerce_db.order_items oi
JOIN ecommerce_db.orders o ON o.order_id = oi.order_id
JOIN ecommerce_db.products p ON p.product_id = oi.product_id
WHERE o.status IN ('PAID', 'SHIPPED', 'DELIVERED')
GROUP BY p.product_name, p.category_id
ORDER BY revenue DESC
LIMIT 5;
```

</details>

<details>
<summary>Detailed Explanation</summary>

The `WHERE o.status IN (...)` filter is applied at the row level (per
order item, based on its parent order's status) before grouping, so a
`PENDING` order's items (order 7) and the `CANCELLED` order's item
(order 5) never contribute to `units_sold` or `revenue`. Grouping by both
`product_name` and `category_id` (rather than name alone) protects
against a theoretical case where two different products share a name —
here it doesn't change the result, but it's the more defensible habit
since `product_name` isn't the table's primary key.

**Actual output:**

| product_name       | category_id | units_sold | revenue   |
|---|---|---|---|
| UltraBook Pro 14   | 3 | 2 | 179998.00 |
| Galaxy Phone X     | 2 | 2 | 91998.00  |
| GameBook 15        | 3 | 1 | 74999.00  |
| Wireless Earbuds   | 2 | 2 | 6998.00   |
| Men Cotton Shirt   | 5 | 5 | 6495.00   |

Pixel Lite (Galaxy Phone X's competitor) doesn't appear in the top 5
because its only sale was on the `CANCELLED` order 5 — correctly excluded.

</details>

---

### Challenge 3.3: Ongoing-project staffing roster **[PostgreSQL]**

**Problem:** HR is scheduling mid-project performance check-ins and needs
a roster of everyone currently staffed on a project that hasn't concluded
yet (`end_date IS NULL`), including each person's role on the project and
their direct manager's name, so managers can be looped into the right
conversations.

<details>
<summary>Hint</summary>

This needs the project table, the employee-project bridge table, the
employee table (for the staffer), and the employee table *again* (for
their manager) — a self-join via `manager_id`. A `LEFT JOIN` for the
manager lookup is safer than an inner join in case someone has no
manager on file.

</details>

<details>
<summary>Expected Approach</summary>

1. Filter `projects` to `end_date IS NULL`.
2. Join to `employee_projects` to find who's staffed on those projects.
3. Join to `employees` to get the staffer's name.
4. Self-join `employees` again (as `mgr`) on `e.manager_id = mgr.employee_id`
   to pull the manager's name, using a `LEFT JOIN` since a manager might
   be missing.
5. Also join `departments` for context, and order the results sensibly.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT p.project_name,
       d.department_name,
       e.first_name || ' ' || e.last_name AS employee_name,
       ep.role,
       mgr.first_name || ' ' || mgr.last_name AS manager_name
FROM company_db.projects p
JOIN company_db.departments d ON d.department_id = p.department_id
JOIN company_db.employee_projects ep ON ep.project_id = p.project_id
JOIN company_db.employees e ON e.employee_id = ep.employee_id
LEFT JOIN company_db.employees mgr ON mgr.employee_id = e.manager_id
WHERE p.end_date IS NULL
ORDER BY p.project_name, ep.role;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `WHERE p.end_date IS NULL` identifies "still open" projects — in this
  schema, a `NULL` end date means the project hasn't been closed out yet.
- The self-join `LEFT JOIN employees mgr ON mgr.employee_id = e.manager_id`
  is the classic pattern for resolving a self-referencing foreign key: the
  same table is joined to itself under a different alias so each row can
  carry both "my own data" (`e.*`) and "my manager's data" (`mgr.*`)
  side by side. `LEFT JOIN` (rather than `JOIN`) is used here because,
  in general, a top-level executive could have `manager_id IS NULL`; it
  doesn't change this particular result set, but it's the correct
  defensive choice.

**Actual output:**

| project_name        | department_name | employee_name | role            | manager_name  |
|---|---|---|---|---|
| Brand Relaunch      | Marketing   | Pooja Reddy | Executive       | Rajesh Iyer  |
| Brand Relaunch      | Marketing   | Rajesh Iyer | Marketing Lead  | Aditi Rao    |
| Mobile App Revamp   | Engineering | Aman Chawla | Engineer        | Rahul Mehta  |
| Mobile App Revamp   | Engineering | Karan Verma | Engineer        | Sneha Kulkarni |
| Mobile App Revamp   | Engineering | Rahul Mehta | Tech Lead       | Aditi Rao    |

Only "Mobile App Revamp" and "Brand Relaunch" have `end_date IS NULL` in
the seed data — "Platform Migration", "Q1 Sales Expansion", and "Employee
Wellness" all have a concrete end date and are correctly excluded.

</details>

---

### Challenge 3.4: Above-average-paid department leadership **[PostgreSQL]**

**Problem:** The board wants to know which department managers are
currently leading teams whose average base salary exceeds the
company-wide average base salary — a proxy for "which teams carry the
most compensation weight" ahead of a budget review. Each employee's
**most recent** salary row should be used (salary history exists per
employee), not every historical row.

<details>
<summary>Hint</summary>

You need "the latest row per employee" from a table with multiple rows
per employee — PostgreSQL's `DISTINCT ON` is built exactly for this. Once
you have one current salary per employee, you'll need it twice: once to
compute each department's average, and once (as a subquery) to compute
the company-wide average for comparison.

</details>

<details>
<summary>Expected Approach</summary>

1. Build a CTE `latest_salary` using `DISTINCT ON (employee_id) ... ORDER
   BY employee_id, effective_date DESC` to get one current salary row per
   employee.
2. Build a second CTE (or scalar subquery) for the company-wide average
   base salary from `latest_salary`.
3. Join `managers` → `employees` (the manager) → `departments` → the
   department's active employees → `latest_salary`, group by department
   and manager, and compute each department's average base salary.
4. Filter with `HAVING` against the company-wide average.

</details>

<details>
<summary>Solution</summary>

```sql
WITH latest_salary AS (
  SELECT DISTINCT ON (employee_id) employee_id, base_salary, bonus
  FROM company_db.salaries
  ORDER BY employee_id, effective_date DESC
),
company_avg AS (
  SELECT AVG(base_salary) AS avg_salary FROM latest_salary
)
SELECT d.department_name,
       m.manager_id,
       e.first_name || ' ' || e.last_name AS manager_name,
       ROUND(AVG(ls.base_salary), 2) AS dept_avg_salary,
       (SELECT ROUND(avg_salary, 2) FROM company_avg) AS company_avg_salary
FROM company_db.managers m
JOIN company_db.employees e ON e.employee_id = m.manager_id
JOIN company_db.departments d ON d.department_id = m.department_id
JOIN company_db.employees te ON te.department_id = d.department_id AND te.status = 'ACTIVE'
JOIN latest_salary ls ON ls.employee_id = te.employee_id
GROUP BY d.department_name, m.manager_id, manager_name
HAVING AVG(ls.base_salary) > (SELECT avg_salary FROM company_avg)
ORDER BY dept_avg_salary DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `DISTINCT ON (employee_id) ... ORDER BY employee_id, effective_date
  DESC` is a PostgreSQL-specific idiom: for each distinct `employee_id`,
  it keeps only the first row after sorting by `effective_date DESC` —
  i.e., the most recent salary row. (Equivalent, more portable
  alternatives use a window function like `ROW_NUMBER() OVER (PARTITION
  BY employee_id ORDER BY effective_date DESC) = 1` — covered in Level 4.)
- `company_avg` computes one number: the average of everyone's *current*
  base salary company-wide.
- The main query joins each manager to their department's active
  employees (`te`, for "team employee") and those employees' current
  salaries, then groups by department/manager to get a department
  average.
- `HAVING AVG(ls.base_salary) > (SELECT avg_salary FROM company_avg)`
  keeps only departments whose average clears the company-wide bar.

**Actual output:**

| department_name | manager_id | manager_name | dept_avg_salary | company_avg_salary |
|---|---|---|---|---|
| Engineering | 1 | Aditi Rao  | 227500.00 | 190312.50 |
| Sales       | 7 | Priya Nair | 205000.00 | 190312.50 |

HR, Finance, and Marketing each average below the company-wide
₹190,312.50 baseline and are correctly excluded.

</details>

---

### Challenge 3.5: Zero-feedback product blind spot **[PostgreSQL]**

**Problem:** The product team is deciding what to feature in next
quarter's roadmap review and wants to know which products have **never
received a single customer review** — they're flying blind on customer
sentiment for these SKUs.

<details>
<summary>Hint</summary>

You want rows from one table that have *no match* in another — the
classic "anti-join" pattern. Think `LEFT JOIN ... WHERE <right side> IS
NULL`.

</details>

<details>
<summary>Expected Approach</summary>

1. `LEFT JOIN` `products` to `reviews` on `product_id`.
2. Filter to rows where the review side is `NULL` (no match found).
3. Select the product's id, name, and price.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT p.product_id, p.product_name, p.price
FROM ecommerce_db.products p
LEFT JOIN ecommerce_db.reviews r ON r.product_id = p.product_id
WHERE r.review_id IS NULL
ORDER BY p.product_id;
```

</details>

<details>
<summary>Detailed Explanation</summary>

A `LEFT JOIN` keeps every row from `products` regardless of whether a
matching `reviews` row exists; when no match exists, all columns from
`reviews` (including `review_id`, which can never legitimately be `NULL`
in a real review row since it's the primary key) come back as `NULL`.
Filtering `WHERE r.review_id IS NULL` therefore isolates exactly the
products with zero reviews — this is the standard "find the orphans"
anti-join pattern, and it's important to filter on a column that is
`NOT NULL` on the right-hand table so you can't accidentally match a
genuine (but null-valued) review.

**Actual output:**

| product_id | product_name       | price    |
|---|---|---|
| 2  | Pixel Lite         | 29999.00 |
| 6  | Women Kurta Set    | 1799.00  |
| 7  | Non-stick Pan Set  | 2499.00  |
| 8  | Electric Kettle    | 1499.00  |
| 10 | Laptop Sleeve 14"  | 799.00   |

Five of the ten products have no reviews at all — including a ₹29,999
laptop-tier phone (Pixel Lite), which is a genuinely useful, actionable
finding for the product team.

</details>

---

### Challenge 3.6: Order-total vs. payment-amount audit **[PostgreSQL]**

**Problem:** Finance suspects there may be a data-integrity gap between
what an order's line items say it's worth and what was actually recorded
as paid, and wants every order where those two numbers don't match,
flagged for manual review before the books are closed.

<details>
<summary>Hint</summary>

Compute the line-item total per order first (a CTE is a clean way to do
this), then compare it against the recorded payment amount for that same
order using a `LEFT JOIN` (some orders might have no payment row at all)
and an inequality check that also handles `NULL`s safely.

</details>

<details>
<summary>Expected Approach</summary>

1. In a CTE, group `order_items` by `order_id` and sum
   `quantity * unit_price` into `items_total`.
2. Join `orders` to that CTE, then `LEFT JOIN` to `payments`.
3. Keep rows where `payments.amount` is different from `items_total`
   (using a null-safe comparison, since a `LEFT JOIN` can produce `NULL`
   payments).

</details>

<details>
<summary>Solution</summary>

```sql
WITH order_totals AS (
  SELECT order_id, SUM(quantity * unit_price) AS items_total
  FROM ecommerce_db.order_items
  GROUP BY order_id
)
SELECT o.order_id, o.status, ot.items_total, pay.amount AS payment_amount,
       (ot.items_total - pay.amount) AS diff
FROM ecommerce_db.orders o
JOIN order_totals ot ON ot.order_id = o.order_id
LEFT JOIN ecommerce_db.payments pay ON pay.order_id = o.order_id
WHERE pay.amount IS DISTINCT FROM ot.items_total
ORDER BY o.order_id;
```

</details>

<details>
<summary>Detailed Explanation</summary>

`IS DISTINCT FROM` is a null-safe inequality operator in PostgreSQL: an
ordinary `<>` comparison against a `NULL` payment amount would evaluate
to `NULL` (and be silently dropped by `WHERE`), hiding orders that have
*no* payment row at all. `IS DISTINCT FROM` correctly treats "no payment"
as different from "a matching total" and surfaces it.

**Actual output:**

| order_id | status    | items_total | payment_amount | diff    |
|---|---|---|---|---|
| 2 | DELIVERED | 5097.00 | 4097.00 | 1000.00 |

This is a genuine discrepancy in the seed data: order 2's line items (2×
Men Cotton Shirt at ₹1,299 + 1× Non-stick Pan Set at ₹2,499 = ₹5,097) sum
to ₹1,000 more than the ₹4,097 payment on record — exactly the kind of
mismatch a real reconciliation query is meant to catch before month-end
close.

</details>

---

## Level 4 — Advanced

Window functions (running totals, ranking, top-N-per-group), recursive
CTEs, correlated subqueries, and transaction/locking scenarios using
`banking_db`.

### Challenge 4.1: Account activity running ledger **[PostgreSQL]**

**Problem:** A customer has disputed their current balance and support
needs to reconstruct, transaction by transaction, how the net movement on
each account accumulated over time — without collapsing any individual
transaction row (a plain `GROUP BY` would hide the play-by-play they
need).

<details>
<summary>Hint</summary>

You need a value that "keeps growing" row by row within each account
without merging rows together — that's exactly what a window function
with a frame does, as opposed to `GROUP BY` which merges rows. Treat
deposits/inbound transfers as positive movement and withdrawals/outbound
transfers as negative.

</details>

<details>
<summary>Expected Approach</summary>

1. Compute a signed amount per transaction: positive for `DEPOSIT` /
   `TRANSFER_IN`, negative for `WITHDRAWAL` / `TRANSFER_OUT`, using
   `CASE`.
2. Apply `SUM(...) OVER (PARTITION BY account_id ORDER BY
   transaction_date, transaction_id)` to get a running total per account
   without collapsing rows.
3. Select transaction detail columns alongside the running total.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT account_id, transaction_id, transaction_date, transaction_type, amount,
       SUM(
         CASE WHEN transaction_type IN ('DEPOSIT', 'TRANSFER_IN') THEN amount
              ELSE -amount END
       ) OVER (
         PARTITION BY account_id
         ORDER BY transaction_date, transaction_id
       ) AS running_net_movement
FROM banking_db.transactions
ORDER BY account_id, transaction_date, transaction_id;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `SUM(...) OVER (PARTITION BY account_id ORDER BY transaction_date,
  transaction_id)` is a window function: unlike `GROUP BY`, it does not
  reduce the number of rows returned. Each row still represents one
  transaction, but it additionally carries a running total computed over
  all rows in the same partition (`account_id`) up to and including the
  current row in the specified order — this is the default frame
  (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`).
- `transaction_id` is included as a tiebreaker in `ORDER BY` because two
  transactions on the same account share the exact same
  `transaction_date` (the linked transfer pair at `2024-01-15 15:00`
  affecting accounts 1 and 3) — without a tiebreaker, the running-total
  order for same-timestamp rows would be arbitrary.
- **Important:** this running total reflects the *net movement recorded
  in the transaction log*, starting from zero — it is **not** the
  account's live balance, since `accounts.balance` already includes an
  opening balance that predates this transaction history. Reconciling
  the two (opening balance + net movement = current balance) is a
  natural follow-up exercise.

**Actual output:**

| account_id | transaction_id | transaction_date    | transaction_type | amount   | running_net_movement |
|---|---|---|---|---|---|
| 1 | 1 | 2024-01-02 10:00:00 | DEPOSIT      | 20000.00 | 20000.00  |
| 1 | 2 | 2024-01-05 12:00:00 | WITHDRAWAL   | 5000.00  | 15000.00  |
| 1 | 5 | 2024-01-15 15:00:00 | TRANSFER_OUT | 10000.00 | 5000.00   |
| 2 | 3 | 2024-01-06 09:00:00 | DEPOSIT      | 8000.00  | 8000.00   |
| 3 | 4 | 2024-01-10 11:00:00 | DEPOSIT      | 15000.00 | 15000.00  |
| 3 | 6 | 2024-01-15 15:00:00 | TRANSFER_IN  | 10000.00 | 25000.00  |
| 4 | 7 | 2024-01-20 14:00:00 | WITHDRAWAL   | 25000.00 | -25000.00 |
| 6 | 8 | 2024-02-01 10:30:00 | DEPOSIT      | 5000.00  | 5000.00   |

Account 4's running net movement goes negative (-25000.00) purely because
its only logged transaction is a withdrawal — again, this is net
*movement*, not the account's actual balance (which is ₹300,000 and
includes history predating this log).

</details>

---

### Challenge 4.2: Intra-department salary ranking **[PostgreSQL]**

**Problem:** The compensation team wants every active employee ranked by
current base salary *within their own department* (not company-wide), so
department heads can see at a glance who's #1, #2, etc. on their team,
with ties handled fairly (equal salaries should get the equal rank).

<details>
<summary>Hint</summary>

You need each employee's most recent salary row first, then a ranking
window function partitioned by department — pick the ranking function
that assigns the *same* rank to ties rather than arbitrarily breaking
them.

</details>

<details>
<summary>Expected Approach</summary>

1. Build a `latest_salary` CTE (same `DISTINCT ON` pattern as 3.4).
2. Join employees + departments + latest_salary, filtering to active
   employees.
3. Apply `RANK() OVER (PARTITION BY department_id ORDER BY base_salary
   DESC)`.
4. Order the final output by department, then rank.

</details>

<details>
<summary>Solution</summary>

```sql
WITH latest_salary AS (
  SELECT DISTINCT ON (employee_id) employee_id, base_salary
  FROM company_db.salaries
  ORDER BY employee_id, effective_date DESC
)
SELECT d.department_name,
       e.first_name || ' ' || e.last_name AS employee_name,
       ls.base_salary,
       RANK() OVER (PARTITION BY d.department_id ORDER BY ls.base_salary DESC) AS salary_rank
FROM company_db.employees e
JOIN company_db.departments d ON d.department_id = e.department_id
JOIN latest_salary ls ON ls.employee_id = e.employee_id
WHERE e.status = 'ACTIVE'
ORDER BY d.department_name, salary_rank;
```

</details>

<details>
<summary>Detailed Explanation</summary>

`RANK()` assigns identical rank values to rows with equal `ORDER BY`
values within a partition, and then **skips** the next rank number(s) by
the count of tied rows (e.g., two employees tied at rank 1 means the next
distinct salary gets rank 3, not 2). This is different from
`DENSE_RANK()` (no gap after ties) and `ROW_NUMBER()` (arbitrary
tiebreak, always unique). Compensation reviews typically want `RANK()`'s
behavior — ties are visibly tied, but the ranking still reflects "how
many people are strictly ahead of me."

**Actual output (14 active employees across 5 departments):**

| department_name | employee_name  | base_salary | salary_rank |
|---|---|---|---|
| Engineering | Aditi Rao      | 520000.00 | 1 |
| Engineering | Rahul Mehta    | 320000.00 | 2 |
| Engineering | Sneha Kulkarni | 210000.00 | 3 |
| Engineering | Vikram Joshi   | 140000.00 | 4 |
| Engineering | Aman Chawla    | 95000.00  | 5 |
| Engineering | Karan Verma    | 80000.00  | 6 |
| Finance     | Nikhil Gupta   | 250000.00 | 1 |
| Finance     | Divya Shah     | 130000.00 | 2 |
| HR          | Rohan Kapoor   | 240000.00 | 1 |
| HR          | Isha Bhatt     | 100000.00 | 2 |
| Marketing   | Rajesh Iyer    | 230000.00 | 1 |
| Marketing   | Pooja Reddy    | 105000.00 | 2 |
| Sales       | Priya Nair     | 300000.00 | 1 |
| Sales       | Arjun Das      | 110000.00 | 2 |

Every department resets its ranking at 1 — that's the effect of
`PARTITION BY d.department_id`. No ties happen to occur in this seed
data, so `RANK()` behaves identically to `DENSE_RANK()`/`ROW_NUMBER()`
here; the distinction would only surface with equal salaries.

</details>

---

### Challenge 4.3: Top-2 flagship product per category **[PostgreSQL]**

**Problem:** Merchandising wants the two highest-priced products in each
category to feature as "flagship" items on category landing pages —
capped at exactly 2 per category, not just "products above some price."

<details>
<summary>Hint</summary>

"Top N per group" is the signature use case for `ROW_NUMBER()`: number
the rows within each partition by the ranking criterion, then filter the
outer query to numbers `<= N`. This has to happen in two steps — you
can't filter on a window function's result in the same `SELECT`'s
`WHERE` clause directly.

</details>

<details>
<summary>Expected Approach</summary>

1. In a subquery (or CTE), join `products` to `categories` and compute
   `ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY price DESC)`.
2. In the outer query, filter to rows where that row number is `<= 2`.
3. Order the final output by category, then rank.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT category_name, product_name, price, price_rank
FROM (
  SELECT c.category_name, p.product_name, p.price,
         ROW_NUMBER() OVER (PARTITION BY c.category_id ORDER BY p.price DESC) AS price_rank
  FROM ecommerce_db.products p
  JOIN ecommerce_db.categories c ON c.category_id = p.category_id
) ranked
WHERE price_rank <= 2
ORDER BY category_name, price_rank;
```

</details>

<details>
<summary>Detailed Explanation</summary>

A window function's result cannot be referenced in the `WHERE` clause of
the *same* `SELECT` — `WHERE` is logically evaluated before window
functions are computed. That's why the numbering has to happen in an
inner query (or CTE) and the `price_rank <= 2` filter has to happen in an
outer query wrapping it. `ROW_NUMBER()` (rather than `RANK()`) is the
right choice here because merchandising wants **exactly** 2 products per
category, even if there happened to be a price tie for 2nd place —
`RANK()` could return 3 rows in that case (two tied at rank 2), which
isn't what "top 2" means for a landing-page slot count.

**Actual output:**

| category_name  | product_name       | price    | price_rank |
|---|---|---|---|
| Home & Kitchen | Non-stick Pan Set | 2499.00  | 1 |
| Home & Kitchen | Electric Kettle   | 1499.00  | 2 |
| Laptops        | UltraBook Pro 14  | 89999.00 | 1 |
| Laptops        | GameBook 15       | 74999.00 | 2 |
| Men            | Men Cotton Shirt  | 1299.00  | 1 |
| Mobiles        | Galaxy Phone X    | 45999.00 | 1 |
| Mobiles        | Pixel Lite        | 29999.00 | 2 |
| Women          | Women Kurta Set   | 1799.00  | 1 |

"Men" and "Women" only have one product each in the seed catalog, so
they contribute a single row apiece rather than two — `ROW_NUMBER()`
never invents rows that don't exist.

</details>

---

### Challenge 4.4: Full organizational chart **[PostgreSQL]**

**Problem:** The new CEO's chief of staff wants a complete, indented
organization chart from the top down — everyone's reporting chain
visualized in one query — for an all-hands presentation, without
hardcoding a fixed number of management levels (the org could be
restructured to be deeper or shallower next quarter).

<details>
<summary>Hint</summary>

The reporting structure is a self-referencing hierarchy of unknown
depth — this is exactly what a recursive CTE is for. The "anchor" is
whoever has no manager; the "recursive" part walks down one level at a
time by joining each round's results back to `employees` on
`manager_id`.

</details>

<details>
<summary>Expected Approach</summary>

1. Anchor member: select employees where `manager_id IS NULL`, with
   `depth = 0`.
2. Recursive member: join `employees` to the working result set on
   `e.manager_id = (previous round).employee_id`, incrementing `depth`
   by 1 each round.
3. `UNION ALL` the anchor and recursive parts.
4. Select from the recursive CTE, using `depth` to indent the display
   name, and order by a path string so children appear directly under
   their parent.

</details>

<details>
<summary>Solution</summary>

```sql
WITH RECURSIVE org_chart AS (
  SELECT employee_id, first_name || ' ' || last_name AS employee_name,
         manager_id, job_title, 0 AS depth,
         (first_name || ' ' || last_name)::text AS chain
  FROM company_db.employees
  WHERE manager_id IS NULL

  UNION ALL

  SELECT e.employee_id, e.first_name || ' ' || e.last_name,
         e.manager_id, e.job_title, oc.depth + 1,
         oc.chain || ' -> ' || e.first_name || ' ' || e.last_name
  FROM company_db.employees e
  JOIN org_chart oc ON e.manager_id = oc.employee_id
)
SELECT employee_id, REPEAT('  ', depth) || employee_name AS org_tree, job_title, depth
FROM org_chart
ORDER BY chain;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- The anchor part (`manager_id IS NULL`) finds the top of the org — here,
  Aditi Rao (CTO), the only employee with no manager.
- The recursive part joins `employees e` to the CTE's own name
  (`org_chart`, referenced as `oc`) on `e.manager_id = oc.employee_id`:
  each iteration finds "everyone whose manager was found in the previous
  round," which is exactly how a tree is walked one level at a time
  without knowing its depth in advance. PostgreSQL keeps re-running the
  recursive term against only the newly-added rows from the previous
  iteration until it produces zero new rows, at which point recursion
  stops.
- `chain` accumulates the full path from the root, which is used purely
  to `ORDER BY` so that a manager's direct reports are grouped
  immediately beneath them, depth-first, in the final display.
- `REPEAT('  ', depth)` prepends two spaces per depth level, producing a
  simple ASCII-indented tree in the output.

**Actual output:**

```
Aditi Rao                (CTO,                   depth 0)
  Nikhil Gupta           (Finance Manager,       depth 1)
    Divya Shah           (Accountant,            depth 2)
  Priya Nair             (Sales Manager,         depth 1)
    Arjun Das            (Sales Executive,       depth 2)
    Meera Pillai         (Sales Executive,       depth 2)
  Rahul Mehta            (Engineering Manager,   depth 1)
    Aman Chawla          (Software Engineer,     depth 2)
    Ananya Singh         (Software Engineer,     depth 2)
    Sneha Kulkarni       (Senior Engineer,       depth 2)
      Karan Verma        (Junior Engineer,       depth 3)
    Vikram Joshi         (Software Engineer,     depth 2)
  Rajesh Iyer            (Marketing Manager,     depth 1)
    Pooja Reddy          (Marketing Executive,   depth 2)
  Rohan Kapoor           (HR Manager,            depth 1)
    Isha Bhatt           (HR Executive,          depth 2)
```

All 16 employees appear exactly once. Karan Verma is the only depth-3
employee — he reports to Sneha Kulkarni (Senior Engineer, depth 2), who
reports to Rahul Mehta (Engineering Manager, depth 1), who reports to
Aditi Rao (CTO, depth 0), making Engineering the only 4-level-deep branch
of the company.

</details>

---

### Challenge 4.5: Category tree with depth **[PostgreSQL]**

**Problem:** The catalog team is redesigning site navigation and needs
the full category hierarchy — top-level categories and their
subcategories — with an explicit depth number so the front-end team can
control indentation/nesting in the UI, without assuming the hierarchy is
only ever 2 levels deep.

<details>
<summary>Hint</summary>

Same recursive-CTE shape as the org chart, but walking
`parent_category_id` instead of `manager_id`.

</details>

<details>
<summary>Expected Approach</summary>

1. Anchor: categories where `parent_category_id IS NULL`, `depth = 0`.
2. Recursive: join `categories` to the working set on
   `c.parent_category_id = (previous round).category_id`, `depth + 1`.
3. `UNION ALL` and select with indentation based on `depth`.

</details>

<details>
<summary>Solution</summary>

```sql
WITH RECURSIVE category_tree AS (
  SELECT category_id, category_name, parent_category_id, 0 AS depth,
         category_name::text AS path
  FROM ecommerce_db.categories
  WHERE parent_category_id IS NULL

  UNION ALL

  SELECT c.category_id, c.category_name, c.parent_category_id, ct.depth + 1,
         ct.path || ' > ' || c.category_name
  FROM ecommerce_db.categories c
  JOIN category_tree ct ON c.parent_category_id = ct.category_id
)
SELECT category_id, REPEAT('  ', depth) || category_name AS category_tree, depth, path
FROM category_tree
ORDER BY path;
```

</details>

<details>
<summary>Detailed Explanation</summary>

Structurally identical to Challenge 4.4 — the only difference is which
self-referencing foreign key drives the walk (`parent_category_id`
instead of `manager_id`) and which table it walks (`categories` instead
of `employees`). This is worth internalizing: **any** self-referencing
hierarchy (org charts, category trees, bill-of-materials, folder
structures, comment threads) uses this exact recursive CTE shape.

**Actual output:**

| category_id | category_tree      | depth | path                    |
|---|---|---|---|
| 1 | Electronics       | 0 | Electronics             |
| 3 |   Laptops         | 1 | Electronics > Laptops   |
| 2 |   Mobiles         | 1 | Electronics > Mobiles   |
| 4 | Fashion           | 0 | Fashion                 |
| 5 |   Men             | 1 | Fashion > Men           |
| 6 |   Women           | 1 | Fashion > Women         |
| 7 | Home & Kitchen    | 0 | Home & Kitchen          |

The seed data only goes 2 levels deep (top-level + one tier of
subcategories), but the query itself makes no assumption about that — it
would correctly render a 5-level-deep hierarchy if one were added, with
no changes required.

</details>

---

### Challenge 4.6: Above-department-average earners (correlated subquery) **[PostgreSQL]**

**Problem:** As a sanity check ahead of the board comp review, leadership
wants to see which active employees currently earn more than their own
department's average salary — computed using a technique that doesn't
rely on pre-joining department-wide aggregates, since this is meant as an
independent cross-check against the Level 4.2 window-function ranking.

<details>
<summary>Hint</summary>

For each employee, you need to compare their salary against "the average
salary of everyone else in the same department" — a subquery that
references a column from the *outer* query (the employee's own
`department_id`) and re-runs conceptually once per outer row. That's a
correlated subquery, and it belongs in the `WHERE` clause this time, not
a `JOIN`.

</details>

<details>
<summary>Expected Approach</summary>

1. Build the `latest_salary` CTE as before.
2. In the outer query's `WHERE` clause, add a subquery that computes
   `AVG(base_salary)` for active employees in the *same* `department_id`
   as the current outer row.
3. Keep only employees whose own salary exceeds that subquery's result.

</details>

<details>
<summary>Solution</summary>

```sql
WITH latest_salary AS (
  SELECT DISTINCT ON (employee_id) employee_id, base_salary
  FROM company_db.salaries
  ORDER BY employee_id, effective_date DESC
)
SELECT e.employee_id, e.first_name || ' ' || e.last_name AS employee_name,
       d.department_name, ls.base_salary
FROM company_db.employees e
JOIN company_db.departments d ON d.department_id = e.department_id
JOIN latest_salary ls ON ls.employee_id = e.employee_id
WHERE e.status = 'ACTIVE'
  AND ls.base_salary > (
      SELECT AVG(ls2.base_salary)
      FROM company_db.employees e2
      JOIN latest_salary ls2 ON ls2.employee_id = e2.employee_id
      WHERE e2.department_id = e.department_id
        AND e2.status = 'ACTIVE'
  )
ORDER BY d.department_name, ls.base_salary DESC;
```

</details>

<details>
<summary>Detailed Explanation</summary>

The subquery `SELECT AVG(...) ... WHERE e2.department_id = e.department_id
AND e2.status = 'ACTIVE'` references `e.department_id` from the *outer*
query — this makes it a **correlated** subquery: conceptually,
PostgreSQL re-evaluates it once per candidate outer row (in practice, the
planner is often smart enough to rewrite this into a more efficient join
internally, but the logical semantics are "once per row"). This is a
different technique from Challenge 4.2's window function
(`RANK() OVER (PARTITION BY ...)`) or Challenge 3.4's pre-aggregated CTE
join, but for a single-level "compare to my group's average" question,
all three approaches can arrive at compatible answers — which is exactly
why this is presented as a cross-check.

**Actual output:**

| employee_id | employee_name | department_name | base_salary |
|---|---|---|---|
| 1  | Aditi Rao    | Engineering | 520000.00 |
| 2  | Rahul Mehta  | Engineering | 320000.00 |
| 12 | Nikhil Gupta | Finance     | 250000.00 |
| 10 | Rohan Kapoor | HR          | 240000.00 |
| 14 | Rajesh Iyer  | Marketing   | 230000.00 |
| 7  | Priya Nair   | Sales       | 300000.00 |

In this seed data, "above the department average" turns out to be
exactly the department head in every department — a direct consequence
of how top-heavy the salary distribution is in a 2–6-person department.

</details>

---

### Challenge 4.7: Deadlock-safe fund transfer **[PostgreSQL]**

**Problem:** Engineering is implementing the "transfer between accounts"
feature and needs a safe pattern: two concurrent transfers moving money
between the same pair of accounts (one A→B, another B→A) must never
deadlock, the source account must never go negative, and a frozen account
must reject the transfer outright. Demonstrate transferring ₹12,000 from
Ravi Shankar's savings account (account 1) to Neha Agarwal's savings
account (account 3), safely.

<details>
<summary>Hint</summary>

Deadlocks between two transactions each holding one lock and waiting on
the other's are caused by **inconsistent lock acquisition order**. If
every transaction that touches two accounts always locks them in the
same order (e.g., always the lower `account_id` first), two opposing
transfers can never form a circular wait. You'll want `SELECT ... FOR
UPDATE` to take that lock explicitly before checking balances.

</details>

<details>
<summary>Expected Approach</summary>

1. Start an explicit transaction (`BEGIN`).
2. Lock the two accounts in ascending `account_id` order using
   `SELECT ... FOR UPDATE`, regardless of which one is the "source" —
   this fixed ordering is what prevents deadlocks.
3. Re-check the source account's balance and status now that it's
   locked.
4. `UPDATE` both balances, and insert the paired `TRANSFER_OUT` /
   `TRANSFER_IN` rows into `transactions`.
5. `COMMIT` (or `ROLLBACK` if any check fails).

</details>

<details>
<summary>Solution</summary>

```sql
BEGIN;

-- Always lock in ascending account_id order (1 before 3 here),
-- independent of transfer direction, to prevent deadlocks against a
-- concurrent transfer moving money the opposite way between the same pair.
SELECT account_id, balance, status FROM banking_db.accounts WHERE account_id = 1 FOR UPDATE;
SELECT account_id, balance, status FROM banking_db.accounts WHERE account_id = 3 FOR UPDATE;

-- Application-level checks happen here, now that both rows are locked:
-- verify account 1 has status = 'ACTIVE' and balance >= 12000.

UPDATE banking_db.accounts
   SET balance = balance - 12000
 WHERE account_id = 1 AND balance >= 12000 AND status = 'ACTIVE';

UPDATE banking_db.accounts
   SET balance = balance + 12000
 WHERE account_id = 3 AND status = 'ACTIVE';

INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
VALUES (1, 'TRANSFER_OUT', 12000, 3, 'Transfer to Neha');

INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
VALUES (3, 'TRANSFER_IN', 12000, 1, 'Transfer from Ravi');

COMMIT;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `SELECT ... FOR UPDATE` acquires a row-level exclusive lock immediately,
  before any `UPDATE` is issued. This means a second, concurrent
  transaction trying to lock the same account has to wait — it cannot
  proceed to read a stale balance and race ahead.
- The critical deadlock-prevention detail is locking **account 1 before
  account 3, always** — even though this transfer happens to move money
  *from* 1 *to* 3. If a concurrent transfer moved money the opposite
  direction (3 → 1) and locked account 3 first, then account 1, you'd
  have transaction A holding lock 1 and waiting for lock 3, while
  transaction B holds lock 3 and waits for lock 1 — a classic deadlock.
  By always locking `LEAST(account_a, account_b)` first, both
  transactions attempt to acquire locks in the *same* global order, so
  one of them will always win the first lock and proceed to completion
  (or the second will simply queue behind it) — no circular wait is
  possible.
- The `UPDATE ... WHERE balance >= 12000 AND status = 'ACTIVE'` guard is
  a defense-in-depth check: even though the row is already locked, this
  makes the `UPDATE` a no-op (0 rows affected) if the balance/status
  precondition somehow doesn't hold, which the application code should
  check via `ROW_COUNT` before committing.
- Both `transactions` inserts happen in the same database transaction as
  the balance updates, so either the whole transfer (both balance changes
  and both ledger entries) commits atomically, or none of it does if
  anything fails before `COMMIT`.

**Verified result** (run inside a test transaction and rolled back to
preserve the seed data): before the transfer, account 1 = ₹150,000.00 and
account 3 = ₹80,000.00. After the `UPDATE`s (before `COMMIT`/`ROLLBACK`):
account 1 = ₹138,000.00, account 3 = ₹92,000.00 — exactly a ₹12,000 net
movement in each direction, confirming the logic is correct.

> **Important Notes**
> - In production, wrap the whole block in your application's retry logic
>   for `SQLSTATE 40P01` (`deadlock_detected`) as a defensive backstop —
>   consistent lock ordering *prevents* deadlocks in this specific
>   two-account pattern, but broader systems with more complex, multi-row
>   locking chains should still handle the error gracefully.
> - `SERIALIZABLE` isolation is an alternative strategy (let PostgreSQL
>   detect the conflict and force a retry) instead of explicit `FOR
>   UPDATE` locking — covered in Chapter 11/12.

</details>

---

## Level 5 — Expert

Stored-procedure-style logic (PL/pgSQL with error handling), triggers,
gaps-and-islands, cohort analysis, and index-design diagnosis.

### Challenge 5.1: Safe transfer procedure with full error handling **[PostgreSQL]**

**Problem:** Engineering wants the ad-hoc transfer logic from Challenge 4.7
turned into a reusable, callable procedure that the application layer can
invoke directly — one that validates both accounts exist, rejects
non-`ACTIVE` accounts, rejects non-positive or self-to-self transfers,
raises a clear error on insufficient funds, and logs a notice on success,
all while still preventing the cross-transfer deadlock scenario.

<details>
<summary>Hint</summary>

This is a `CREATE PROCEDURE` (not a function, since it performs
transactional side effects like `COMMIT`-able DML and is meant to be
invoked with `CALL`). Structure your validation as a sequence of `IF ...
THEN RAISE EXCEPTION` guards before touching any balances, and use an
`EXCEPTION WHEN OTHERS` block to log and re-raise so the caller still
sees the failure.

</details>

<details>
<summary>Expected Approach</summary>

1. Declare the procedure with `p_from_account`, `p_to_account`,
   `p_amount` parameters.
2. Validate: amount is positive; source ≠ destination.
3. Lock both accounts in `LEAST`/`GREATEST` order via `FOR UPDATE`.
4. Fetch source balance/status and destination status; raise a specific
   exception for each failure mode (missing account, frozen/closed
   account, insufficient funds).
5. Perform the two balance updates and two `transactions` inserts.
6. Wrap the body in an `EXCEPTION WHEN OTHERS` handler that logs via
   `RAISE NOTICE` and re-raises (`RAISE`) so the transaction still rolls
   back and the caller sees the error.

</details>

<details>
<summary>Solution</summary>

```sql
CREATE OR REPLACE PROCEDURE banking_db.transfer_funds(
    p_from_account INT,
    p_to_account   INT,
    p_amount       NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_from_balance  NUMERIC(14,2);
    v_from_status   VARCHAR(20);
    v_to_status     VARCHAR(20);
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive, got %', p_amount;
    END IF;

    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Source and destination accounts must differ (account %)', p_from_account;
    END IF;

    -- Lock accounts in a fixed order (lowest id first) to prevent deadlocks
    -- when two concurrent transfers involve the same pair of accounts.
    PERFORM 1 FROM banking_db.accounts WHERE account_id = LEAST(p_from_account, p_to_account) FOR UPDATE;
    PERFORM 1 FROM banking_db.accounts WHERE account_id = GREATEST(p_from_account, p_to_account) FOR UPDATE;

    SELECT balance, status INTO v_from_balance, v_from_status
    FROM banking_db.accounts WHERE account_id = p_from_account;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source account % does not exist', p_from_account;
    END IF;

    SELECT status INTO v_to_status FROM banking_db.accounts WHERE account_id = p_to_account;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Destination account % does not exist', p_to_account;
    END IF;

    IF v_from_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Source account % is % and cannot originate transfers', p_from_account, v_from_status;
    END IF;

    IF v_to_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Destination account % is % and cannot receive transfers', p_to_account, v_to_status;
    END IF;

    IF v_from_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds in account %: balance % < requested %',
            p_from_account, v_from_balance, p_amount;
    END IF;

    UPDATE banking_db.accounts SET balance = balance - p_amount WHERE account_id = p_from_account;
    UPDATE banking_db.accounts SET balance = balance + p_amount WHERE account_id = p_to_account;

    INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_from_account, 'TRANSFER_OUT', p_amount, p_to_account, 'Procedure transfer');
    INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_to_account, 'TRANSFER_IN', p_amount, p_from_account, 'Procedure transfer');

    RAISE NOTICE 'Transferred % from account % to account %', p_amount, p_from_account, p_to_account;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Transfer failed: %', SQLERRM;
        RAISE;
END;
$$;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `PERFORM 1 FROM ... FOR UPDATE` is used (instead of `SELECT ... INTO`)
  purely to acquire the lock without needing the column values yet — the
  actual balance/status read happens in the subsequent `SELECT ... INTO`
  statements, by which point the row is already locked.
- Each validation `IF` raises a distinct, descriptive exception message
  using `%`-style placeholders (PL/pgSQL's `RAISE` formatting) — this
  matters operationally, since a caller (or an ops engineer reading logs)
  needs to know *which* precondition failed, not just "something went
  wrong."
- The outer `EXCEPTION WHEN OTHERS THEN RAISE NOTICE ...; RAISE;` block
  logs a notice (visible in `psql`/application logs) and then
  **re-raises** the original exception with bare `RAISE` — this is
  important: if you swallowed the exception instead of re-raising it,
  the procedure would silently "succeed" from the caller's perspective
  even though the transfer never happened, which is a dangerous bug in
  financial code. Any exception (including the intentional validation
  ones above) automatically rolls back everything the procedure did
  since it started, since it's all one transaction.

**Verified behavior:**

1. `CALL banking_db.transfer_funds(1, 3, 12000);` — succeeds, logs
   `NOTICE: Transferred 12000 from account 1 to account 3`, and produces
   the same balance changes verified in Challenge 4.7 (account 1 →
   138000.00, account 3 → 92000.00).
2. `CALL banking_db.transfer_funds(6, 1, 999999);` — fails with `ERROR:
   Insufficient funds in account 6: balance 20000.00 < requested
   999999`, and account 6's balance is untouched.
3. `CALL banking_db.transfer_funds(7, 1, 100);` — fails with `ERROR:
   Source account 7 is FROZEN and cannot originate transfers`, correctly
   blocking a transfer from Manoj Tiwari's frozen current account.

</details>

---

### Challenge 5.2: Oversell-prevention inventory trigger **[PostgreSQL]**

**Problem:** The warehouse team keeps finding orders confirmed for
products with zero stock, because nothing currently stops an
`order_items` row from being inserted regardless of `inventory` levels.
Engineering needs a trigger that automatically checks and decrements
stock at insert time, across whichever warehouse can fulfil the
quantity, and hard-rejects the insert if no warehouse has enough stock.

<details>
<summary>Hint</summary>

This needs to run *before* the row is actually written, so a bad insert
can be rejected outright rather than corrected after the fact — think
about which trigger timing (`BEFORE` vs. `AFTER`) lets you cancel the
insert by raising an exception. You'll also want to lock the inventory
row you're about to decrement.

</details>

<details>
<summary>Expected Approach</summary>

1. Write a trigger function that runs `BEFORE INSERT ON order_items FOR
   EACH ROW`.
2. Inside it, `SELECT ... FOR UPDATE` an `inventory` row for
   `NEW.product_id` where `quantity_on_hand >= NEW.quantity`, picking the
   warehouse with the most stock as a simple fulfillment strategy.
3. If no such row is found, `RAISE EXCEPTION` to reject the insert.
4. Otherwise, decrement that warehouse's `quantity_on_hand` and
   `RETURN NEW` to let the original insert proceed.
5. Attach the function to `order_items` via `CREATE TRIGGER`.

</details>

<details>
<summary>Solution</summary>

```sql
CREATE OR REPLACE FUNCTION ecommerce_db.trg_check_and_decrement_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_inventory_id INT;
    v_qty          INT;
BEGIN
    -- Pick a warehouse that can fully cover this line item, locking it
    -- against concurrent order inserts for the same product.
    SELECT inventory_id, quantity_on_hand
      INTO v_inventory_id, v_qty
    FROM ecommerce_db.inventory
    WHERE product_id = NEW.product_id
      AND quantity_on_hand >= NEW.quantity
    ORDER BY quantity_on_hand DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cannot fulfil order_item: product % has insufficient stock for quantity %',
            NEW.product_id, NEW.quantity;
    END IF;

    UPDATE ecommerce_db.inventory
       SET quantity_on_hand = quantity_on_hand - NEW.quantity
     WHERE inventory_id = v_inventory_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_order_items_stock_check
BEFORE INSERT ON ecommerce_db.order_items
FOR EACH ROW
EXECUTE FUNCTION ecommerce_db.trg_check_and_decrement_inventory();
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `BEFORE INSERT ... FOR EACH ROW` is essential: a `BEFORE` trigger can
  inspect and modify `NEW`, and — critically — if it raises an exception,
  **the insert never happens at all**. An `AFTER` trigger would only let
  you react to a row that's already been written, which is too late to
  prevent an oversell.
- `SELECT ... FOR UPDATE ... LIMIT 1` both picks *and locks* one
  candidate inventory row in a single statement, closing the race window
  where two concurrent order inserts for the last unit of stock could
  otherwise both read "stock available" before either one decrements it.
- Choosing `ORDER BY quantity_on_hand DESC` (fulfil from the
  best-stocked warehouse first) is a simple, defensible default
  fulfillment strategy — a real system might instead pick the warehouse
  nearest the customer's shipping address, which would just change this
  one `ORDER BY` clause.
- `RETURN NEW` at the end is mandatory for a `BEFORE` row trigger: it
  tells PostgreSQL to proceed with inserting the (possibly modified)
  `NEW` row. Returning `NULL` instead would silently skip the insert
  without raising an error — not what's wanted here.

**Verified behavior:**

- Inserting `(order_id=7, product_id=10, quantity=3, unit_price=799.00)` —
  Laptop Sleeve 14" has 55 units at Pune-WH1 — succeeds, and that
  warehouse's `quantity_on_hand` drops from 55 to 52.
- Inserting `(order_id=7, product_id=9, quantity=1, unit_price=3499.00)` —
  Wireless Earbuds show `quantity_on_hand = 0` at their only warehouse
  row (Mumbai-WH1) — correctly fails with `ERROR: Cannot fulfil
  order_item: product 9 has insufficient stock for quantity 1`, and no
  `order_items` row is written.

</details>

---

### Challenge 5.3: Balance-change audit trail trigger **[PostgreSQL]**

**Problem:** Compliance requires every change to an account's balance to
be captured in `audit_log`, showing exactly what the balance (and status)
was before and after, without requiring every single place in the
codebase that might update `accounts.balance` to remember to write an
audit row manually (which is exactly how audit gaps happen in practice).

<details>
<summary>Hint</summary>

You want this captured automatically regardless of *which* statement
changed the balance — that argues for a database-level trigger rather
than application code. Since you need both the old and new values, and
you don't need to block the update (just record it), think about which
trigger timing fits, and how `OLD`/`NEW` map onto the `JSONB` columns on
`audit_log`.

</details>

<details>
<summary>Expected Approach</summary>

1. Write a trigger function for `AFTER UPDATE ON accounts FOR EACH ROW`.
2. Inside it, compare `OLD.balance` to `NEW.balance`; only insert an
   audit row if they actually differ (avoid noise from unrelated
   updates).
3. Build `old_data`/`new_data` as `JSONB` objects via
   `jsonb_build_object`, capturing at least `balance` and `status`.
4. Insert into `audit_log` with `table_name = 'accounts'`,
   `operation = 'UPDATE'`, and `row_pk` set to the account's id (cast to
   text, since `row_pk` is `TEXT`).

</details>

<details>
<summary>Solution</summary>

```sql
CREATE OR REPLACE FUNCTION banking_db.trg_audit_account_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.balance IS DISTINCT FROM OLD.balance THEN
        INSERT INTO banking_db.audit_log (table_name, operation, row_pk, old_data, new_data)
        VALUES (
            'accounts',
            'UPDATE',
            OLD.account_id::text,
            jsonb_build_object('balance', OLD.balance, 'status', OLD.status),
            jsonb_build_object('balance', NEW.balance, 'status', NEW.status)
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_accounts_balance_audit
AFTER UPDATE ON banking_db.accounts
FOR EACH ROW
EXECUTE FUNCTION banking_db.trg_audit_account_balance();
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `AFTER UPDATE` (rather than `BEFORE`) is the right timing here because
  the trigger's job is purely to *record* the change, not to validate or
  block it — by the time an `AFTER` trigger fires, the row is already
  committed-pending in the current transaction, and both `OLD` (the
  pre-update values) and `NEW` (the post-update values) are available.
- `IF NEW.balance IS DISTINCT FROM OLD.balance` guards against writing
  audit noise for updates that touch `accounts` but don't actually
  change the balance (e.g., an update that only changes `status`) — this
  keeps the audit log focused on what compliance actually asked for.
  (`IS DISTINCT FROM` again handles the edge case where either value
  could theoretically be `NULL` without misbehaving, though `balance` is
  `NOT NULL` in this schema.)
- Because the trigger is attached at the table level, **any** `UPDATE`
  statement that changes `accounts.balance` — whether from the
  `transfer_funds` procedure, an ad-hoc admin `UPDATE`, or a future
  feature nobody's written yet — is captured automatically. This is the
  core advantage of a trigger-based audit trail over relying on
  application code to remember to log changes.
- `row_pk` is declared as `TEXT` in the schema specifically so a single
  generic `audit_log` table can store primary keys from tables with
  different key types/shapes; `OLD.account_id::text` performs the
  necessary cast.

**Verified behavior:** running
`UPDATE banking_db.accounts SET balance = balance - 3000 WHERE
account_id = 6;` immediately produces this row in `audit_log`:

| audit_id | table_name | operation | row_pk | old_data | new_data |
|---|---|---|---|---|---|
| 1 | accounts | UPDATE | 6 | `{"status": "ACTIVE", "balance": 20000.00}` | `{"status": "ACTIVE", "balance": 17000.00}` |

</details>

---

### Challenge 5.4: Perfect-attendance streak detector (gaps and islands) **[PostgreSQL]**

**Problem:** HR wants to recognize employees who worked multiple
consecutive days without a break (counting `PRESENT`, `LATE`, and
`REMOTE` as "working" days, but not `ABSENT`/`LEAVE`) — specifically,
find every such streak of 2+ consecutive calendar days per employee, with
its start date, end date, and length.

<details>
<summary>Hint</summary>

This is the classic "gaps and islands" problem. The trick: flag each row
as working/not-working, then within the working rows only, subtract a
sequential row number (ordered by date) from the date itself. Rows that
are part of the same unbroken run of dates will all produce the *same*
resulting value — because consecutive dates minus consecutive row numbers
cancel out to a constant. That constant becomes your grouping key.

</details>

<details>
<summary>Expected Approach</summary>

1. Flag each attendance row as `is_working` (1 for `PRESENT`/`LATE`/
   `REMOTE`, 0 otherwise) via `CASE`.
2. Compute `work_date - ROW_NUMBER() OVER (PARTITION BY employee_id,
   is_working ORDER BY work_date)` as a "group key" (`grp`) — consecutive
   dates within the same `is_working` flag produce an identical `grp`
   value.
3. Filter to `is_working = 1` rows, group by `employee_id, grp`, and
   compute `MIN(work_date)`, `MAX(work_date)`, `COUNT(*)` per group.
4. Filter to groups with `COUNT(*) >= 2`.

</details>

<details>
<summary>Solution</summary>

```sql
WITH flagged AS (
  SELECT employee_id, work_date, status,
         CASE WHEN status IN ('PRESENT', 'LATE', 'REMOTE') THEN 1 ELSE 0 END AS is_working
  FROM company_db.attendance
),
grouped AS (
  SELECT *,
         work_date - (ROW_NUMBER() OVER (PARTITION BY employee_id, is_working ORDER BY work_date))::int AS grp
  FROM flagged
)
SELECT employee_id, MIN(work_date) AS streak_start, MAX(work_date) AS streak_end,
       COUNT(*) AS streak_length
FROM grouped
WHERE is_working = 1
GROUP BY employee_id, grp
HAVING COUNT(*) >= 2
ORDER BY employee_id, streak_start;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- The core trick: within a single unbroken run of consecutive calendar
  dates, `work_date` increases by exactly 1 each row, and
  `ROW_NUMBER()` (ordered the same way) also increases by exactly 1 each
  row — so `work_date - ROW_NUMBER()` stays **constant** for the whole
  run. The moment there's a gap (a skipped date, or a switch from
  `is_working = 1` to `0` and back), the row number keeps climbing by 1
  per row but the date jumps by more than 1, so the subtraction produces
  a *different* constant for the new run. Grouping by that constant
  (`grp`) therefore isolates each maximal run ("island") of consecutive
  working days.
- Partitioning `ROW_NUMBER()` by `(employee_id, is_working)` (not just
  `employee_id`) keeps each employee's working-days numbering and
  non-working-days numbering independent, and keeps different employees'
  streaks from ever being compared against each other.
- `HAVING COUNT(*) >= 2` is what turns "every working day" into
  specifically multi-day *streaks* — a lone working day surrounded by
  non-working days would form its own 1-row island and get filtered out.

**Actual output:**

| employee_id | streak_start | streak_end | streak_length |
|---|---|---|---|
| 3 | 2024-01-01 | 2024-01-03 | 3 |
| 6 | 2024-01-01 | 2024-01-02 | 2 |

Employee 3 (Sneha Kulkarni) worked 3 straight days (`PRESENT`,
`PRESENT`, `LATE` — all count as "working"). Employee 6 (Karan Verma)
worked 2 straight days (`REMOTE`, `PRESENT`). Employee 4 (Vikram Joshi)
has `PRESENT, ABSENT, PRESENT` — the `ABSENT` day breaks the streak into
two 1-day islands, both correctly excluded by the `HAVING` filter.
Employee 5 has two consecutive `LEAVE` days, which are excluded entirely
since `is_working = 0` for `LEAVE`.

</details>

---

### Challenge 5.5: Signup-cohort order-retention analysis **[PostgreSQL]**

**Problem:** Growth wants a classic cohort table: group customers by the
calendar month they signed up, then, for each cohort, show how many
distinct months after signup they went on to place a (non-cancelled)
order — the foundational retention view used to spot whether newer
cohorts are engaging faster or slower than older ones.

<details>
<summary>Hint</summary>

You need two derived facts per user: their signup month (a truncation of
`created_at`), and every distinct month in which they placed a
non-cancelled order. Then compute the numeric gap, in months, between
those two — `DATE_TRUNC` plus a bit of `EXTRACT`-based arithmetic (or
`AGE`) gets you there.

</details>

<details>
<summary>Expected Approach</summary>

1. Build a `cohorts` CTE: one row per user with `cohort_month =
   DATE_TRUNC('month', created_at)`.
2. Build a `user_orders` CTE: distinct `(user_id, order_month)` pairs
   from non-cancelled orders.
3. Join the two, compute `month_number` as the whole-month difference
   between `order_month` and `cohort_month`.
4. Group by `cohort_month, month_number` and count distinct users.

</details>

<details>
<summary>Solution</summary>

```sql
WITH cohorts AS (
  SELECT user_id, DATE_TRUNC('month', created_at)::date AS cohort_month
  FROM ecommerce_db.users
),
user_orders AS (
  SELECT o.user_id, DATE_TRUNC('month', o.order_date)::date AS order_month
  FROM ecommerce_db.orders o
  WHERE o.status <> 'CANCELLED'
  GROUP BY o.user_id, DATE_TRUNC('month', o.order_date)::date
),
cohort_activity AS (
  SELECT c.cohort_month, uo.order_month,
         (EXTRACT(YEAR FROM uo.order_month) - EXTRACT(YEAR FROM c.cohort_month)) * 12 +
         (EXTRACT(MONTH FROM uo.order_month) - EXTRACT(MONTH FROM c.cohort_month)) AS month_number,
         c.user_id
  FROM cohorts c
  JOIN user_orders uo ON uo.user_id = c.user_id
)
SELECT cohort_month, month_number, COUNT(DISTINCT user_id) AS active_users
FROM cohort_activity
GROUP BY cohort_month, month_number
ORDER BY cohort_month, month_number;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `DATE_TRUNC('month', created_at)` collapses every timestamp to the
  first day of its month, giving a clean grouping key per calendar month.
- `month_number` is computed manually as `(year diff * 12) + month diff`
  rather than subtracting dates directly, because subtracting two `date`
  values gives a day count, not a month count — cohort analysis
  conventionally buckets by whole months regardless of day-of-month, so
  this arithmetic is the standard way to get an integer "months since
  signup" value.
- `user_orders` groups by `(user_id, order_month)` *before* the join
  specifically to avoid counting the same user twice for two different
  orders placed in the same month — the final `COUNT(DISTINCT user_id)`
  is a second safety net for the same reason.

**Actual output:**

| cohort_month | month_number | active_users |
|---|---|---|
| 2023-01-01 | 12 | 1 |
| 2023-01-01 | 13 | 1 |
| 2023-02-01 | 11 | 1 |
| 2023-03-01 | 10 | 1 |
| 2023-05-01 | 9  | 1 |
| 2023-06-01 | 8  | 1 |
| 2023-07-01 | 7  | 1 |
| 2023-08-01 | 6  | 1 |

> **Important Notes**
> This seed dataset only has 8 users signed up across January–August
> 2023 and 10 orders concentrated in January–February 2024, so every
> cohort here produces a single, sparse data point rather than the dense
> multi-month retention curve you'd see with a real, larger user base.
> The *technique* — and every number shown — is real and correct for
> this seed data; a production cohort table with thousands of users per
> monthly cohort would show multiple `month_number` rows per
> `cohort_month`, and this exact query would produce it without any
> changes.

</details>

---

### Challenge 5.6: Diagnose and fix a slow transaction-history query **[PostgreSQL]**

**Problem:** The mobile app's "transaction history" screen — which
filters one customer's transactions by account and a date range, sorted
by date — is fast in testing but engineering has been warned it will
crawl once the `transactions` table holds millions of rows in
production, because there's currently no index beyond the primary key.
Diagnose the access pattern the query planner would fall back to at
scale, and design (and justify) the index that fixes it.

<details>
<summary>Hint</summary>

Look at the query's `WHERE` and `ORDER BY` together: it filters on one
column for equality and another for a range, then sorts by the range
column. A composite (multi-column) index's column order matters a lot —
think about which column should come first to support both the equality
filter *and* let the range/sort piggyback on the same index efficiently.

</details>

<details>
<summary>Expected Approach</summary>

1. Identify the query: filter `account_id = ?`, filter
   `transaction_date` between two bounds, `ORDER BY transaction_date`.
2. Note that today, only `transactions_pkey` (on `transaction_id`)
   exists — nothing supports filtering by `account_id`.
3. Reason about why, at scale, this forces a full sequential scan (or an
   expensive parallel one) that reads and discards nearly every row.
4. Design a composite index: `(account_id, transaction_date)` — equality
   column first, range/sort column second — and explain why that column
   order specifically is correct (an index on `(transaction_date,
   account_id)` would not serve the equality filter as efficiently).
5. Verify the fix by comparing execution plans before and after.

</details>

<details>
<summary>Solution</summary>

```sql
-- The query in question:
SELECT transaction_id, transaction_type, amount, transaction_date
FROM banking_db.transactions
WHERE account_id = 1
  AND transaction_date >= '2024-01-01'
  AND transaction_date <  '2024-02-01'
ORDER BY transaction_date;

-- The fix:
CREATE INDEX CONCURRENTLY idx_transactions_account_date
    ON banking_db.transactions (account_id, transaction_date);
```

</details>

<details>
<summary>Detailed Explanation</summary>

- **Why column order matters:** a B-tree index on `(account_id,
  transaction_date)` is physically sorted first by `account_id`, and
  *within* each `account_id`, by `transaction_date`. That means a query
  filtering `account_id = 1` can jump straight to that account's slice of
  the index, and within that slice, the rows are **already** sorted by
  `transaction_date` — so the range filter *and* the `ORDER BY` are both
  satisfied by a single, contiguous index range scan with no separate
  sort step. Flipping the column order to `(transaction_date,
  account_id)` would force the database to scan every date first and
  filter `account_id` afterward per matching date — far less selective
  for "one customer's history."
- **`CREATE INDEX CONCURRENTLY`** avoids taking a long-lived lock that
  would block writes to `transactions` while the index builds — important
  on a live, high-traffic banking table (it takes longer and can't run
  inside a transaction block, but production tables must not be locked
  for the duration of an index build).
- **Verifying the fix**, using a temporary, at-scale simulation (200,000
  synthetic transaction rows added and then rolled back, since the real
  seed table only has 8 rows and is too small for the planner to ever
  choose anything but a sequential scan):

  **Before the index** — `EXPLAIN (ANALYZE, COSTS OFF)`:
  ```
  Gather Merge (actual time=9.487..14.113 rows=584 loops=1)
    Workers Planned: 1
    Workers Launched: 1
    ->  Sort (actual time=6.142..6.167 rows=292 loops=2)
          Sort Key: transaction_date
          ->  Parallel Seq Scan on transactions (actual time=0.029..6.007 rows=292 loops=2)
                Filter: (transaction_date >= ... AND transaction_date < ... AND account_id = 1)
                Rows Removed by Filter: 99712
  Execution Time: 14.151 ms
  ```
  Every row in the table is read and then almost all of them
  (`Rows Removed by Filter: 99712` per worker) are thrown away — a
  sequential scan followed by an explicit sort.

  **After the index** — same query, `EXPLAIN (ANALYZE, COSTS OFF)`:
  ```
  Sort (actual time=0.725..0.739 rows=584 loops=1)
    Sort Key: transaction_date
    ->  Bitmap Heap Scan on transactions (actual time=0.107..0.644 rows=584 loops=1)
          Recheck Cond: (account_id = 1 AND transaction_date >= ... AND transaction_date < ...)
          ->  Bitmap Index Scan on idx_transactions_account_date (actual time=0.060..0.061 rows=584 loops=1)
                Index Cond: (account_id = 1 AND transaction_date >= ... AND transaction_date < ...)
  Execution Time: 0.770 ms
  ```
  The planner now uses the new composite index to jump directly to the
  matching rows, cutting execution time from **14.151 ms to 0.770 ms** —
  roughly an 18x improvement — on this 200K-row simulation. The gap
  widens further as table size grows, since the "before" plan's cost
  scales with total table size while the "after" plan's cost scales with
  the (much smaller) number of matching rows for one account.

> **Important Notes**
> This before/after comparison was run against a temporary, artificially
> inflated copy of `transactions` (200,000 synthetic rows inserted and
> then rolled back) purely to demonstrate planner behavior at a
> meaningful scale — the real seed data ships with only 8 transaction
> rows, on which PostgreSQL correctly (and cheaply) always chooses a
> sequential scan regardless of indexes. The index design and its
> justification apply directly to the real production table; the
> numbers above are illustrative of the *magnitude* of improvement to
> expect, not a guarantee of the exact millisecond figures at any given
> scale.

</details>

---

## Level 6 — Extreme

Genuinely hard synthesis problems: partition-aware query design, a
multi-CTE analytical report, a full concurrency-safe batch procedure, and
a query-optimization diagnosis, mostly against `analytics_db` at scale.

> **Important Notes — read before Level 6**
> `analytics_db` is generated with `random()` at load time (5,000
> customers, 200 products, 25 stores, ~5,000,000 fact rows, ~200,000
> events), so **exact figures below are illustrative** — every fresh load
> produces different specific numbers. Every query below was verified for
> correctness and plan shape against a live PostgreSQL 15 instance (using
> a reduced-scale load of the identical schema — 300,000 fact rows and
> 3,000 synthetic event users — purely so verification finishes in
> seconds instead of minutes); the *queries*, the *partition-pruning
> behavior*, and the *relative performance patterns* shown are real, not
> invented.

### Challenge 6.1: Partition-pruning-aware quarterly query **[PostgreSQL] [Illustrative]**

**Problem:** `sales_fact` is range-partitioned by `sale_date` into yearly
partitions (`sales_fact_2022`, `sales_fact_2023`, `sales_fact_2024`). An
analyst needs daily revenue totals for Q1 2024 only, and leadership has
asked engineering to confirm the query genuinely only touches the 2024
partition rather than scanning three years of history to answer a
three-month question.

<details>
<summary>Hint</summary>

Partition pruning in PostgreSQL is a planning-time (or, for parameterized
queries, execution-time) optimization that only works when the planner
can statically prove which partition(s) a filter could possibly match —
that means writing the date filter as a **direct, sargable comparison**
against the partition key column, not hiding it inside a function call.

</details>

<details>
<summary>Expected Approach</summary>

1. Write a plain, direct range filter on `sale_date` covering exactly Q1
   2024 (`>= '2024-01-01' AND < '2024-04-01'`), not a function-wrapped
   predicate like `EXTRACT(...)`.
2. Group by `sale_date` and sum `amount`.
3. Run `EXPLAIN` and confirm the plan references only
   `sales_fact_2024`, not `sales_fact_2022`/`sales_fact_2023`.

</details>

<details>
<summary>Solution</summary>

```sql
EXPLAIN (COSTS OFF)
SELECT sale_date, SUM(amount) AS daily_revenue
FROM analytics_db.sales_fact
WHERE sale_date >= '2024-01-01'
  AND sale_date <  '2024-04-01'
GROUP BY sale_date
ORDER BY sale_date;
```

</details>

<details>
<summary>Detailed Explanation</summary>

Because `sales_fact` is declared `PARTITION BY RANGE (sale_date)` with
non-overlapping yearly bounds, and the `WHERE` clause expresses a direct,
literal range entirely within `2024-01-01` to `2025-01-01`, the planner
can prove at plan time that rows satisfying the filter can only live in
the `sales_fact_2024` partition — it never even opens
`sales_fact_2022`/`sales_fact_2023`. This is "partition pruning" (also
called "constraint exclusion" in older PostgreSQL versions), and it's
the entire performance case for partitioning a table like this: a query
scoped to one quarter reads roughly 1/12th of one year's worth of data
instead of the whole multi-year table.

**Actual plan (verified, reduced-scale load):**

```
Limit
  ->  Sort
        Sort Key: sales_fact.sale_date
        ->  HashAggregate
              Group Key: sales_fact.sale_date
              ->  Seq Scan on sales_fact_2024 sales_fact
                    Filter: ((sale_date >= '2024-01-01'::date) AND (sale_date < '2024-04-01'::date))
```

Note the plan shows **only** `sales_fact_2024` — there's no `Append` node
fanning out across all three yearly partitions, confirming pruning
worked. (At full 5M-row production scale, the same plan shape holds, but
the `Seq Scan` on the single ~1.67M-row 2024 partition would likely
become an index-supported scan or benefit from adding an index on
`sale_date` within that partition, depending on selectivity —
partitioning and indexing are complementary, not substitutes for each
other.)

</details>

---

### Challenge 6.2: Regional category performance report with YoY growth **[PostgreSQL] [Illustrative]**

**Problem:** The VP of Sales wants one consolidated report for the
quarterly business review: for each region and product category, this
year's quarterly revenue, how much of that revenue came from weekend
sales specifically (a proxy for consumer vs. business buying patterns),
year-over-year growth versus the same quarter last year, and a rank
showing the top 2 region+category combinations by revenue within each
quarter — all in one query.

<details>
<summary>Hint</summary>

Break this into layers with CTEs: first, a base aggregation joining the
fact table to its dimensions and computing quarterly revenue plus a
conditional (weekend-only) revenue sum; second, a layer that applies
window functions (`LAG` for the prior year's same quarter, `RANK` for
the in-quarter leaderboard) on top of that pre-aggregated result — don't
try to mix raw fact-table joins and window functions in a single `SELECT`.

</details>

<details>
<summary>Expected Approach</summary>

1. CTE `quarterly`: join `sales_fact` to `dim_date`, `dim_store`, and
   `dim_product`; group by year, quarter, region, category; compute
   `SUM(amount)` as revenue and a `CASE`-conditional sum for
   weekend-only revenue.
2. CTE `ranked`: over `quarterly`, use `LAG(revenue) OVER (PARTITION BY
   region, category, quarter ORDER BY year)` to get the prior year's same
   quarter, and `RANK() OVER (PARTITION BY year, quarter ORDER BY revenue
   DESC)` for the in-quarter leaderboard.
3. Final `SELECT`: compute YoY growth percentage from the `LAG` value,
   filter to the target year and top-2 rank, order for readability.

</details>

<details>
<summary>Solution</summary>

```sql
WITH quarterly AS (
  SELECT dd.year, dd.quarter, ds.region, dp.category,
         SUM(sf.amount) AS revenue,
         SUM(CASE WHEN dd.is_weekend THEN sf.amount ELSE 0 END) AS weekend_revenue
  FROM analytics_db.sales_fact sf
  JOIN analytics_db.dim_date dd    ON dd.date_key = sf.sale_date
  JOIN analytics_db.dim_store ds   ON ds.store_key = sf.store_key
  JOIN analytics_db.dim_product dp ON dp.product_key = sf.product_key
  WHERE dd.year IN (2022, 2023)
  GROUP BY dd.year, dd.quarter, ds.region, dp.category
),
ranked AS (
  SELECT *,
         LAG(revenue) OVER (PARTITION BY region, category, quarter ORDER BY year) AS prev_year_revenue,
         RANK() OVER (PARTITION BY year, quarter ORDER BY revenue DESC) AS revenue_rank_in_quarter
  FROM quarterly
)
SELECT year, quarter, region, category, revenue, weekend_revenue, prev_year_revenue,
       ROUND(100.0 * (revenue - prev_year_revenue) / NULLIF(prev_year_revenue, 0), 2) AS yoy_growth_pct,
       revenue_rank_in_quarter
FROM ranked
WHERE revenue_rank_in_quarter <= 2
  AND year = 2023
ORDER BY quarter, revenue_rank_in_quarter;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- The `quarterly` CTE does all the heavy lifting against the fact table
  once — three dimension joins and one `GROUP BY` — collapsing what could
  be millions of fact rows down to a small number of (year, quarter,
  region, category) summary rows. Everything downstream operates on this
  small, pre-aggregated result, which is far cheaper than re-joining the
  fact table for every window calculation.
- `SUM(CASE WHEN dd.is_weekend THEN sf.amount ELSE 0 END)` is a
  **conditional aggregation** — a single pass that sums a different
  subset of rows into a separate column, avoiding a second query (or a
  second join) purely to isolate weekend revenue.
- `LAG(revenue) OVER (PARTITION BY region, category, quarter ORDER BY
  year)` looks *one row back* within a partition that's been sliced by
  everything **except** year, ordered *by* year — so for the 2023 Q1
  Central/Fashion row, it retrieves the 2022 Q1 Central/Fashion row's
  revenue, giving a true same-quarter year-over-year comparison rather
  than comparing against the *previous quarter*.
- `RANK() OVER (PARTITION BY year, quarter ORDER BY revenue DESC)`
  computes a completely independent ranking — the leaderboard of
  region+category combinations within each year-quarter — which is then
  filtered to `<= 2` in the final `WHERE`, the same top-N-per-group
  pattern from Challenge 4.3, layered on top of an already-aggregated CTE.
- `NULLIF(prev_year_revenue, 0)` guards the growth-percentage division
  against a divide-by-zero if a region/category had zero revenue in the
  prior year.

**Illustrative output (reduced-scale verification load; real production
numbers will differ but the shape/columns are exactly this):**

| year | quarter | region  | category | revenue   | weekend_revenue | prev_year_revenue | yoy_growth_pct | revenue_rank_in_quarter |
|---|---|---|---|---|---|---|---|---|
| 2023 | 1 | Central | Fashion | 236563.13 | 68756.18 | 232653.93 | 1.68  | 1 |
| 2023 | 1 | Central | Home    | 231030.60 | 66899.71 | 226814.29 | 1.86  | 2 |
| 2023 | 2 | Central | Fashion | 244388.92 | 63151.12 | 232825.65 | 4.97  | 1 |
| 2023 | 2 | North   | Fashion | 236256.41 | 69981.91 | 233816.56 | 1.04  | 2 |
| 2023 | 3 | Central | Fashion | 247832.59 | 69836.02 | 233148.54 | 6.30  | 1 |
| 2023 | 3 | North   | Fashion | 241653.98 | 67955.96 | 223315.28 | 8.21  | 2 |
| 2023 | 4 | Central | Home    | 244790.07 | 77170.32 | 218185.06 | 12.19 | 1 |
| 2023 | 4 | North   | Home    | 236543.85 | 68944.51 | 229179.81 | 3.21  | 2 |

With random, uniformly distributed synthetic data, revenue differences
across regions/categories are small (as expected — there's no real
"Central region loves Fashion" signal baked into the generator), which
is exactly why this is labeled illustrative; the query itself is
production-ready for real, non-random sales data.

</details>

---

### Challenge 6.3: High-value, recently-active customer decile **[PostgreSQL] [Illustrative]**

**Problem:** The retention team wants to identify the single most
valuable, most recently active decile of customers — the top 10% by
total spend **and** the top 10% by recency of last purchase,
simultaneously — as the target list for a white-glove account manager
outreach program.

<details>
<summary>Hint</summary>

`NTILE(n)` splits an ordered set of rows into `n` roughly equal-sized
buckets — bucket 1 always holds the "best" rows for whatever `ORDER BY`
you give it. You need two independent `NTILE(10)` computations over the
same customer set — one ordered by spend, one ordered by recency — and
then filter to customers who land in bucket 1 of *both*.

</details>

<details>
<summary>Expected Approach</summary>

1. Build a `customer_metrics` CTE: group `sales_fact` by
   `customer_key`, computing `MAX(sale_date)` (recency), `COUNT(*)`
   (frequency), and `SUM(amount)` (monetary) — a classic RFM setup.
2. Build a `scored` CTE joining to `dim_customer`, applying
   `NTILE(10) OVER (ORDER BY monetary DESC)` and `NTILE(10) OVER (ORDER
   BY last_purchase DESC)`.
3. Filter the final `SELECT` to rows where both decile columns equal 1.

</details>

<details>
<summary>Solution</summary>

```sql
WITH customer_metrics AS (
  SELECT sf.customer_key,
         MAX(sf.sale_date) AS last_purchase,
         COUNT(*) AS frequency,
         SUM(sf.amount) AS monetary
  FROM analytics_db.sales_fact sf
  GROUP BY sf.customer_key
),
scored AS (
  SELECT cm.*, dc.customer_name, dc.segment,
         NTILE(10) OVER (ORDER BY monetary DESC) AS spend_decile,
         NTILE(10) OVER (ORDER BY last_purchase DESC) AS recency_decile
  FROM customer_metrics cm
  JOIN analytics_db.dim_customer dc ON dc.customer_key = cm.customer_key
)
SELECT customer_key, customer_name, segment, frequency, monetary, last_purchase,
       spend_decile, recency_decile
FROM scored
WHERE spend_decile = 1 AND recency_decile = 1
ORDER BY monetary DESC
LIMIT 20;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- `customer_metrics` reduces the (potentially 5-million-row) fact table
  down to one row per customer — this is the aggregation that has to
  scan the fact table; everything after it operates on a much smaller
  (≤ 5,000-row) intermediate result.
- `NTILE(10)` divides its ordered input into 10 equally-sized (±1 row)
  buckets and labels each row with its bucket number. Two independent
  `NTILE(10)` calls with different `ORDER BY` clauses in the same
  `SELECT` are perfectly valid — each is its own independent window
  computation over the same partition (here, an implicit single
  partition covering all rows, since no `PARTITION BY` is given).
  `spend_decile = 1` means "top 10% by monetary value"; `recency_decile
  = 1` means "top 10% most recent purchasers." Requiring *both* to equal
  1 is a logical `AND` across two independently computed rankings — a
  customer could easily be in the top spend decile but not the top
  recency decile (a big past spender who's gone quiet), and this query
  deliberately excludes them.
- This is a lightweight, ad-hoc version of full RFM (Recency, Frequency,
  Monetary) segmentation — `frequency` is computed and carried through
  for context/display even though this particular filter doesn't
  threshold on it.

**Illustrative output (reduced-scale verification load, top 5 of the
qualifying set shown):**

| customer_key | customer_name | segment    | frequency | monetary | last_purchase | spend_decile | recency_decile |
|---|---|---|---|---|---|---|---|
| 4923 | Customer 4923 | BUSINESS   | 86 | 24147.74 | 2024-12-30 | 1 | 1 |
| 2667 | Customer 2667 | BUSINESS   | 81 | 21881.97 | 2024-12-29 | 1 | 1 |
| 3007 | Customer 3007 | BUSINESS   | 81 | 21669.39 | 2024-12-30 | 1 | 1 |
| 3041 | Customer 3041 | CONSUMER   | 70 | 21524.12 | 2024-12-29 | 1 | 1 |
| 4901 | Customer 4901 | ENTERPRISE | 76 | 21227.57 | 2024-12-30 | 1 | 1 |

At full production scale (5,000 customers), each decile would hold
~500 customers rather than the ~150–300 a 300K-row reduced load
produces — the query and its logic are identical either way.

</details>

---

### Challenge 6.4: Month-1/Month-3 login retention by signup cohort **[PostgreSQL] [Illustrative]**

**Problem:** Product wants to know, for each monthly signup cohort, what
percentage of users who signed up logged in again in their first month
versus their fourth month (`month_number` 0 through 3) — a standard
product-retention curve — using the raw `events` log rather than a
pre-built cohort table.

<details>
<summary>Hint</summary>

You need three logical pieces: (1) each user's signup month, from
`SIGNUP` events; (2) every (user, month) pair in which that same user
logged in, from `LOGIN` events; (3) the size of each cohort, to turn raw
counts into percentages. Compute the month-offset the same way as
Challenge 5.5, then divide.

</details>

<details>
<summary>Expected Approach</summary>

1. CTE `signups`: one row per user with their `SIGNUP` event's month,
   from `events WHERE event_type = 'SIGNUP'`.
2. CTE `activity`: join `events WHERE event_type = 'LOGIN'` to `signups`
   on `user_id`, computing the month-offset between the login's month
   and the signup month.
3. CTE `cohort_size`: count distinct users per cohort month from
   `signups`.
4. Final query: group `activity` by cohort month and month-offset,
   count distinct retained users, join to `cohort_size`, and compute a
   retention percentage.

</details>

<details>
<summary>Solution</summary>

```sql
WITH signups AS (
  SELECT user_id, DATE_TRUNC('month', event_time)::date AS cohort_month
  FROM analytics_db.events
  WHERE event_type = 'SIGNUP'
),
activity AS (
  SELECT e.user_id, s.cohort_month,
         (EXTRACT(YEAR FROM DATE_TRUNC('month', e.event_time)) - EXTRACT(YEAR FROM s.cohort_month)) * 12 +
         (EXTRACT(MONTH FROM DATE_TRUNC('month', e.event_time)) - EXTRACT(MONTH FROM s.cohort_month)) AS month_number
  FROM analytics_db.events e
  JOIN signups s ON s.user_id = e.user_id
  WHERE e.event_type = 'LOGIN'
),
cohort_size AS (
  SELECT cohort_month, COUNT(*) AS cohort_users FROM signups GROUP BY cohort_month
)
SELECT a.cohort_month, a.month_number,
       COUNT(DISTINCT a.user_id) AS retained_users,
       cs.cohort_users,
       ROUND(100.0 * COUNT(DISTINCT a.user_id) / cs.cohort_users, 1) AS retention_pct
FROM activity a
JOIN cohort_size cs ON cs.cohort_month = a.cohort_month
WHERE a.month_number BETWEEN 0 AND 3
GROUP BY a.cohort_month, a.month_number, cs.cohort_users
ORDER BY a.cohort_month, a.month_number;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- This is structurally the same cohort pattern as Challenge 5.5, applied
  to event-log data instead of order data, and extended with an explicit
  percentage calculation now that the cohorts are large enough (hundreds
  of synthetic users per month, at reduced scale — thousands at full
  scale) for a percentage to be meaningful rather than noise.
- `month_number = 0` represents "logged in during the same calendar
  month they signed up" (immediate/Day-0-ish activation), while
  `month_number = 3` represents "still logging in three months later" —
  the classic shape of a retention curve is a steep drop from month 0 to
  month 1, then a flattening.
- `COUNT(DISTINCT a.user_id)` is essential rather than plain `COUNT(*)`:
  a user could log in multiple times within the same `month_number`
  bucket (the seed generator can fire more than one `LOGIN` event per
  user), and retention asks "how many distinct users came back," not
  "how many login events happened."
- Dividing by `cs.cohort_users` (the total signups in that cohort, not
  the number of retained users in some other bucket) turns raw counts
  into a comparable percentage across cohorts of different sizes.

**Illustrative output (reduced-scale verification load, first cohorts
shown):**

| cohort_month | month_number | retained_users | cohort_users | retention_pct |
|---|---|---|---|---|
| 2023-01-01 | 0 | 73  | 215 | 34.0 |
| 2023-01-01 | 1 | 110 | 215 | 51.2 |
| 2023-01-01 | 3 | 82  | 215 | 38.1 |
| 2023-02-01 | 0 | 38  | 202 | 18.8 |
| 2023-02-01 | 1 | 126 | 202 | 62.4 |
| 2023-02-01 | 3 | 63  | 202 | 31.2 |

(`month_number = 2` is simply absent for some cohorts in this particular
random draw — with `WHERE random() < 0.85` gating which synthetic events
fire in the generator, not every user has an event in every offset
bucket; this is a real, if slightly noisy, artifact of the synthetic
data generation, not a query bug.)

</details>

---

### Challenge 6.5: Concurrency-safe batch settlement procedure **[PostgreSQL]**

**Problem:** The bank wants to move from one-transfer-at-a-time API calls
to a nightly batch settlement job that can process thousands of queued
transfers, potentially with multiple worker processes running the batch
job in parallel for throughput. The batch must: never deadlock even when
different workers happen to pick up transfers touching the same account
pair, never let one worker block on a row another worker already claimed
(workers should skip locked rows and move on), and ensure that one bad
transfer (insufficient funds, frozen account, etc.) fails and is
recorded **without aborting the rest of the batch**.

<details>
<summary>Hint</summary>

Three separate concurrency techniques need to combine here: (1) a
`FOR UPDATE SKIP LOCKED` queue-claiming pattern so parallel workers never
wait on each other for the *queue* rows; (2) the same fixed
lowest-id-first account locking order from Challenge 4.7/5.1 so
overlapping account pairs never deadlock; and (3) a nested `BEGIN ...
EXCEPTION WHEN OTHERS ... END` block *inside* the loop, so a single
transfer's failure only unwinds that one iteration (PL/pgSQL treats a
nested block with an `EXCEPTION` clause as an implicit savepoint) rather
than the whole procedure.

</details>

<details>
<summary>Expected Approach</summary>

1. Create a `transfer_queue` staging table (`queue_id`, `from_account`,
   `to_account`, `amount`, `status`, `error_message`, `processed_at`).
2. Write a procedure that loops over `PENDING` queue rows using
   `SELECT ... FOR UPDATE SKIP LOCKED LIMIT p_batch_size`, so concurrent
   invocations naturally partition the work instead of contending.
3. Inside the loop, wrap each transfer's logic in its own nested
   `BEGIN ... EXCEPTION WHEN OTHERS ... END` block.
4. Within that block: lock the two accounts in fixed (`LEAST`/`GREATEST`)
   order, validate status/balance, apply both balance updates, insert
   both ledger rows, and mark the queue row `COMPLETED`.
5. On any exception in that block, mark the queue row `FAILED` with the
   error message instead of propagating the exception out of the loop.

</details>

<details>
<summary>Solution</summary>

```sql
CREATE TABLE IF NOT EXISTS banking_db.transfer_queue (
    queue_id       SERIAL PRIMARY KEY,
    from_account   INT NOT NULL,
    to_account     INT NOT NULL,
    amount         NUMERIC(14,2) NOT NULL,
    status         VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','COMPLETED','FAILED')),
    error_message  TEXT,
    processed_at   TIMESTAMP
);

CREATE OR REPLACE PROCEDURE banking_db.process_transfer_batch(p_batch_size INT DEFAULT 100)
LANGUAGE plpgsql
AS $$
DECLARE
    r               RECORD;
    v_lo            INT;
    v_hi            INT;
    v_from_balance  NUMERIC(14,2);
    v_from_status   VARCHAR(20);
    v_to_status     VARCHAR(20);
BEGIN
    FOR r IN
        SELECT * FROM banking_db.transfer_queue
        WHERE status = 'PENDING'
        ORDER BY queue_id
        FOR UPDATE SKIP LOCKED
        LIMIT p_batch_size
    LOOP
        BEGIN  -- nested block = implicit savepoint: isolates one row's failure
            v_lo := LEAST(r.from_account, r.to_account);
            v_hi := GREATEST(r.from_account, r.to_account);

            -- Fixed lock ordering (always lowest account_id first) prevents
            -- deadlocks when concurrent workers process overlapping account pairs.
            PERFORM 1 FROM banking_db.accounts WHERE account_id = v_lo FOR UPDATE;
            PERFORM 1 FROM banking_db.accounts WHERE account_id = v_hi FOR UPDATE;

            SELECT balance, status INTO v_from_balance, v_from_status
            FROM banking_db.accounts WHERE account_id = r.from_account;
            SELECT status INTO v_to_status
            FROM banking_db.accounts WHERE account_id = r.to_account;

            IF v_from_status IS NULL OR v_to_status IS NULL THEN
                RAISE EXCEPTION 'One or both accounts (%, %) do not exist', r.from_account, r.to_account;
            ELSIF v_from_status <> 'ACTIVE' THEN
                RAISE EXCEPTION 'Source account % is %', r.from_account, v_from_status;
            ELSIF v_to_status <> 'ACTIVE' THEN
                RAISE EXCEPTION 'Destination account % is %', r.to_account, v_to_status;
            ELSIF v_from_balance < r.amount THEN
                RAISE EXCEPTION 'Insufficient funds in account %: % < %', r.from_account, v_from_balance, r.amount;
            END IF;

            UPDATE banking_db.accounts SET balance = balance - r.amount WHERE account_id = r.from_account;
            UPDATE banking_db.accounts SET balance = balance + r.amount WHERE account_id = r.to_account;

            INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
            VALUES (r.from_account, 'TRANSFER_OUT', r.amount, r.to_account, 'Batch settlement');
            INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
            VALUES (r.to_account, 'TRANSFER_IN', r.amount, r.from_account, 'Batch settlement');

            UPDATE banking_db.transfer_queue
               SET status = 'COMPLETED', processed_at = clock_timestamp(), error_message = NULL
             WHERE queue_id = r.queue_id;

        EXCEPTION WHEN OTHERS THEN
            -- Roll back only this row's partial work; keep the batch going.
            UPDATE banking_db.transfer_queue
               SET status = 'FAILED', processed_at = clock_timestamp(), error_message = SQLERRM
             WHERE queue_id = r.queue_id;
        END;
    END LOOP;
END;
$$;
```

</details>

<details>
<summary>Detailed Explanation</summary>

- **`FOR UPDATE SKIP LOCKED`** is the key to safe horizontal scaling of
  the batch job: if two `CALL process_transfer_batch()` invocations run
  concurrently (e.g., two worker processes), each one's `SELECT ... FOR
  UPDATE SKIP LOCKED LIMIT p_batch_size` claims a *different* set of
  `PENDING` rows — any row already locked by the other worker is simply
  skipped rather than waited on. Without `SKIP LOCKED`, both workers
  would serialize on each other's locked queue rows, defeating the
  purpose of running workers in parallel.
- **Fixed account-lock ordering** (`LEAST`/`GREATEST`, identical to
  Challenges 4.7 and 5.1) is still required *within* each transfer's
  logic, independently of the queue-locking above — `SKIP LOCKED`
  prevents workers from fighting over *queue rows*, but two different
  queue rows could still reference the *same pair of accounts*
  (e.g., one worker processing a queued A→B transfer while another
  processes a queued B→A transfer). Locking accounts in a single,
  consistent global order eliminates that deadlock risk exactly as it
  did in the two-account case.
- **The nested `BEGIN ... EXCEPTION WHEN OTHERS ... END` block inside the
  loop** is what makes per-row failure isolation possible: PL/pgSQL
  implicitly wraps any block containing an `EXCEPTION` clause in a
  savepoint. If an exception is raised inside that block, PostgreSQL
  rolls back to that savepoint — undoing only the account
  updates/ledger inserts attempted for *this* row — while the
  surrounding `FOR` loop and everything already committed for prior rows
  in this call remains intact. The `EXCEPTION WHEN OTHERS` handler then
  records the failure (`status = 'FAILED'`, `error_message = SQLERRM`)
  on the queue row and the loop simply continues to the next row.
- Because the whole `CALL` still runs inside one client transaction
  (unless the caller explicitly commits between iterations, which
  procedures support via `COMMIT`/`ROLLBACK` inside the loop for very
  large batches — an extension worth considering for truly huge batch
  sizes so long-running batches don't hold locks indefinitely), a crash
  mid-batch simply leaves the un-processed rows `PENDING` for the next
  run, and already-`COMPLETED` rows are safely done.

**Verified behavior**, run against the real seed data (four transfers
queued, then rolled back to preserve seed state):

| queue_id | from_account | to_account | amount    | status    | error_message                                          |
|---|---|---|---|---|---|
| 1 | 1 | 3 | 5000.00   | COMPLETED | |
| 2 | 4 | 6 | 10000.00  | COMPLETED | |
| 3 | 7 | 1 | 500.00    | FAILED    | Source account 7 is FROZEN                             |
| 4 | 6 | 1 | 999999.00 | FAILED    | Insufficient funds in account 6: 30000.00 < 999999.00   |

Resulting account balances after the batch: account 1 = ₹145,000.00
(150,000 − 5,000; the FROZEN-account transfer never touched it), account
3 = ₹85,000.00 (80,000 + 5,000), account 4 = ₹290,000.00 (300,000 −
10,000), account 6 = ₹30,000.00 (20,000 + 10,000; the oversized transfer
failed and left this balance untouched). Two of four queued transfers
succeeded and two failed with specific, actionable error messages — and
critically, the two failures did not prevent the two valid transfers
from completing.

</details>

---

### Challenge 6.6: Diagnose and fix a partition-pruning-defeating query **[PostgreSQL] [Illustrative]**

**Problem:** An analyst's dashboard query — "total 2023 revenue" —
computes `EXTRACT(YEAR FROM sale_date) = 2023` in its `WHERE` clause and
has been flagged by the DBA team as unexpectedly slow given that
`sales_fact` is partitioned specifically to make year-scoped queries
fast. Diagnose exactly why the partitioning isn't helping this query, and
rewrite it so it does.

<details>
<summary>Hint</summary>

Partition pruning requires the planner to statically determine which
partitions *could* contain matching rows, by matching the `WHERE` clause
against each partition's declared bounds. Ask yourself: can the planner
know, just by looking at the partition boundary `'2023-01-01' <= sale_date
< '2024-01-01'`, whether `EXTRACT(YEAR FROM sale_date) = 2023` is
possible or impossible for a *particular* partition, without evaluating
the function against actual row data?

</details>

<details>
<summary>Expected Approach</summary>

1. Run `EXPLAIN` on the original, function-wrapped query and observe
   that it produces an `Append`/`Parallel Append` over **all three**
   yearly partitions, each with its own `Filter` re-checking the
   `EXTRACT(...)` expression row by row.
2. Rewrite the predicate as a direct, sargable range comparison against
   `sale_date` covering exactly 2023 (`>= '2023-01-01' AND < '2024-01-01'`).
3. Re-run `EXPLAIN` and confirm the plan now touches only
   `sales_fact_2023`.
4. Explain, in general terms, why *any* function wrapped around a
   partition (or index) key column defeats this kind of static reasoning.

</details>

<details>
<summary>Solution</summary>

```sql
-- SLOW: function-wrapped predicate defeats partition pruning
SELECT COUNT(*), SUM(amount)
FROM analytics_db.sales_fact
WHERE EXTRACT(YEAR FROM sale_date) = 2023;

-- FIXED: sargable range predicate directly on the partition key
SELECT COUNT(*), SUM(amount)
FROM analytics_db.sales_fact
WHERE sale_date >= '2023-01-01'
  AND sale_date <  '2024-01-01';
```

</details>

<details>
<summary>Detailed Explanation</summary>

- **Why the original query is slow:** `EXTRACT(YEAR FROM sale_date)` is a
  function call wrapped around the partition key. PostgreSQL's
  partition-pruning logic (like most B-tree index reasoning) works by
  comparing the *literal boundary values* of each partition against the
  predicate to see if a match is even possible — it does this without
  executing the predicate against actual data. For a **direct** column
  comparison (`sale_date >= '2023-01-01'`), that boundary reasoning is
  straightforward. For `EXTRACT(YEAR FROM sale_date) = 2023`, the planner
  would have to know, in general, what date ranges could possibly produce
  `2023` when passed through `EXTRACT(YEAR FROM ...)` — and PostgreSQL's
  planner does not attempt to reverse-engineer arbitrary functions like
  that. So it falls back to treating **every partition as a candidate**,
  opening all three and applying the `EXTRACT(...) = 2023` filter as a
  row-by-row `Filter` condition inside each one, discarding non-matching
  rows only after reading them.
- **Why the fix works:** `sale_date >= '2023-01-01' AND sale_date <
  '2024-01-01'` is a direct comparison against the partition key using
  literal, static bounds — exactly the shape the planner's pruning logic
  is built to reason about. It can immediately see that
  `sales_fact_2022`'s bounds (`< '2023-01-01'`) and `sales_fact_2024`'s
  bounds (`>= '2024-01-01'`) cannot overlap the query's range at all, and
  excludes both partitions entirely — without opening them or reading a
  single row from either.
- **The general lesson:** *any* function wrapped around a partition key
  or an indexed column — `EXTRACT()`, `DATE_TRUNC()`, `UPPER()`,
  arithmetic like `price * 1.1`, implicit type casts — makes a predicate
  **non-sargable** and defeats both partition pruning and (separately)
  ordinary B-tree index usage on that expression, unless a matching
  expression index exists. The fix is almost always the same shape:
  rewrite the condition so the raw column sits alone on one side of the
  comparison and all the "work" happens on the literal/constant side
  instead.

**Verified plans and timings (reduced-scale load — real production scale
will show a larger absolute gap, since two full extra yearly partitions
of ~1.67M rows each would need to be scanned instead of ~300K):**

Before (function-wrapped, all 3 partitions scanned):
```
Finalize Aggregate (actual rows=1 loops=1)
  ->  Gather (actual rows=3 loops=1)
        Workers Planned: 2
        ->  Partial Aggregate (actual rows=1 loops=3)
              ->  Parallel Append (actual rows=33390 loops=3)
                    ->  Parallel Seq Scan on sales_fact_2022 (actual rows=0 loops=1)
                          Filter: (EXTRACT(year FROM sale_date) = '2023'::numeric)
                          Rows Removed by Filter: 100202
                    ->  Parallel Seq Scan on sales_fact_2023 (actual rows=33390 loops=3)
                          Filter: (EXTRACT(year FROM sale_date) = '2023'::numeric)
                    ->  Parallel Seq Scan on sales_fact_2024 (actual rows=0 loops=1)
                          Filter: (EXTRACT(year FROM sale_date) = '2023'::numeric)
                          Rows Removed by Filter: 99628
Execution Time: 41.351 ms
```

After (sargable range, only `sales_fact_2023` touched):
```
Aggregate (actual rows=1 loops=1)
  ->  Seq Scan on sales_fact_2023 (actual rows=100170 loops=1)
        Filter: ((sale_date >= '2023-01-01'::date) AND (sale_date < '2024-01-01'::date))
Execution Time: 27.595 ms
```

Even at this reduced scale, the fixed query is faster and does
structurally less work (one partition instead of three, no wasted reads
of `sales_fact_2022`/`sales_fact_2024`). At full production scale — where
`sales_fact_2022` and `sales_fact_2024` are each ~1.67M rows instead of
~100K — the "before" plan's wasted work scales up proportionally while
the "after" plan's cost stays pinned to the one relevant partition, so
the *relative* gap between the two plans widens substantially compared
to what's shown here.

</details>

---

## Summary

| Level | Focus | Challenges |
|---|---|---|
| 1 — Beginner | Single-table SELECT/WHERE/ORDER BY/functions | 6 |
| 2 — Basic | Aggregates, GROUP BY/HAVING, 2-table joins | 6 |
| 3 — Intermediate | 3+ table joins, subqueries, basic CTEs | 6 |
| 4 — Advanced | Window functions, recursive CTEs, correlated subqueries, transactions/locking | 7 |
| 5 — Expert | Procedures, triggers, gaps-and-islands, cohort analysis, index design | 6 |
| 6 — Extreme | Partition-aware design, multi-CTE analytics, concurrency-safe batch procedures, query diagnosis | 6 |
| **Total** | | **37** |

Once you've worked through all six levels, head to
[Chapter 35 — Capstone Challenge](capstone.md) for a single, cumulative
project that pulls techniques from every level above into one larger
build.
