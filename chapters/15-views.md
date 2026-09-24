# Chapter 15 — Views & Materialized Views

> Databases used in this chapter: `ecommerce_db` (primary) and `company_db`.
> Primary dialect: **PostgreSQL**. Divergences are marked
> **[PostgreSQL]** / **[MySQL]** / **[Oracle]** / **[SQL Server]**.
> Every output shown below is the real result of running the query against
> the exact seed data in `databases/ecommerce_db.sql` and `databases/company_db.sql`.

---

## 15.0 Why This Chapter Exists

Up to this point you've written every query from scratch: joining `orders`
to `order_items` to `products` to `users`, over and over, in slightly
different forms each time. Three problems show up immediately once a real
application or reporting team starts doing this:

1. **Repetition and drift.** Twelve analysts write twelve slightly different
   versions of "order total" and get twelve slightly different numbers.
2. **Overexposure.** Giving a reporting tool `SELECT` access to the
   `employees` table also gives it access to `salaries` joined against it —
   there's no SQL-level way to say "this column, not that one" with a raw
   `GRANT` on a table.
3. **Cognitive overload for consumers.** A BI tool, a junior developer, or a
   downstream microservice shouldn't need to understand a 6-table join just
   to ask "what did this customer buy?"

**Views** solve all three: a view is a saved, named `SELECT` statement that
you can query as if it were a table. **Materialized views** go one step
further and actually store the result physically, trading freshness for
speed. This chapter covers both in depth, plus the single most
interview-tested distinction in this space: view vs. table vs. materialized
view.

---

## 15.1 What Is a View?

### Simple explanation
A view is a stored question, not a stored answer. You save a `SELECT`
statement under a name, and every time someone queries that name, the
database re-runs the underlying `SELECT` and hands back fresh results.

### Technical explanation
A view is a named, schema-level object backed by a query definition stored
in the system catalog (`pg_class` / `pg_rewrite` in PostgreSQL,
`information_schema.views` everywhere). It has no independent storage for
rows — no heap, no pages of data. When a view is referenced in a query, the
query planner substitutes the view's defining query in place of the
reference (a process called **view expansion** or **query rewriting**) and
then optimizes the *combined* query as a whole.

### Why it exists
- **Reusable named queries** — write the join logic once, query it by name
  forever after.
- **Security abstraction** — grant access to a curated subset of columns/rows
  without touching the base table's grants.
- **Simplifying complex joins for consumers** — hide 4-table joins behind a
  single, simple-looking relation.
- **Logical independence** — if the underlying schema changes (a table is
  split, renamed, or restructured), you can often adjust only the view
  definition and every consumer keeps working unmodified.

---

## 15.2 CREATE VIEW — Simple Views

### Full syntax **[PostgreSQL]**

```sql
CREATE [ OR REPLACE ] [ TEMP | TEMPORARY ] VIEW view_name [ ( column_alias, ... ) ]
    [ WITH ( view_option = value [, ... ] ) ]
    AS
    SELECT ...
    [ WITH [ LOCAL | CASCADED ] CHECK OPTION ];
```

| Clause | Meaning |
|---|---|
| `OR REPLACE` | Redefine an existing view without dropping it (Section 15.4). |
| `TEMP`/`TEMPORARY` | View exists only for the current session. |
| `(column_alias, ...)` | Rename the output columns of the view. |
| `AS SELECT ...` | The defining query — this is the entire "body" of the view. |
| `WITH CHECK OPTION` | Restricts INSERT/UPDATE through the view (Section 15.6). |

MySQL, Oracle, and SQL Server all support `CREATE [OR REPLACE] VIEW ... AS
SELECT ...` with the same core shape; dialect differences are called out
where they occur.

### Example 1 — the simplest possible view

```sql
CREATE VIEW v_active_customers AS
SELECT user_id, username, email, full_name, created_at
FROM users
WHERE is_active = TRUE;
```

```sql
SELECT * FROM v_active_customers ORDER BY user_id;
```

**Output:**

| user_id | username | email | full_name | created_at |
|---|---|---|---|---|
| 1 | arjun_k | arjun.k@mail.com | Arjun Kumar | 2023-01-05 10:00:00 |
| 2 | sara_p | sara.p@mail.com | Sara Patel | 2023-02-11 12:30:00 |
| 3 | dev_m | dev.m@mail.com | Dev Malhotra | 2023-03-20 09:15:00 |
| 5 | imran_s | imran.s@mail.com | Imran Sheikh | 2023-05-17 08:00:00 |
| 6 | lakshmi_v | lakshmi.v@mail.com | Lakshmi Venkat | 2023-06-25 14:20:00 |
| 7 | farhan_a | farhan.a@mail.com | Farhan Ali | 2023-07-30 11:10:00 |
| 8 | tanya_b | tanya.b@mail.com | Tanya Bose | 2023-08-14 16:05:00 |

Notice `user_id = 4` (Nita Rao, `is_active = FALSE`) is missing — the view's
`WHERE` clause filtered her out, exactly as it would in a plain query.

### Line-by-line explanation
- `CREATE VIEW v_active_customers AS` — registers the name; nothing is
  executed or stored yet.
- `SELECT user_id, username, email, full_name, created_at FROM users` —
  the defining query; only these five columns are ever visible through the
  view, even though `users` has more (`is_active`).
- `WHERE is_active = TRUE` — baked into the view; every future query against
  `v_active_customers` implicitly carries this filter.
- `SELECT * FROM v_active_customers ORDER BY user_id;` — an ordinary query;
  as far as the caller is concerned, `v_active_customers` *is* a table.

### Internal behavior
PostgreSQL does not execute `SELECT ... FROM users WHERE is_active = TRUE`
at `CREATE VIEW` time and cache seven rows somewhere. It stores the *parse
tree* of that query. When you later run
`SELECT * FROM v_active_customers ORDER BY user_id;`, the planner rewrites
it internally into something equivalent to:

```sql
SELECT user_id, username, email, full_name, created_at
FROM users
WHERE is_active = TRUE
ORDER BY user_id;
```

and plans *that*. This is why a view is sometimes described as a
**macro** — it is textually inlined into the outer query before
optimization, not resolved as a separate materialized step.

> **Important Note**
> Because a view is inlined, the query planner can push predicates from the
> outer query *into* the view. `SELECT * FROM v_active_customers WHERE
> user_id = 1;` does not first compute all seven active users and then
> filter — the planner merges `user_id = 1` with `is_active = TRUE` and, if
> an index exists on `users(user_id)`, uses it directly. This is one of the
> few "views are secretly free" cases, and it's a planner optimization, not
> a property of the view itself.

---

## 15.3 Views That Join Multiple Tables

### Simple explanation
A view's defining query can be any valid `SELECT`, including one with joins,
subqueries, and aggregates. This is where views earn their keep — hiding a
multi-table join behind one name.

### Example 2 — `v_order_summary`: a line-item-level reporting view

```sql
CREATE VIEW v_order_summary AS
SELECT
    o.order_id,
    u.user_id,
    u.username,
    u.full_name,
    o.order_date,
    o.status        AS order_status,
    p.product_id,
    p.product_name,
    oi.quantity,
    oi.unit_price,
    (oi.quantity * oi.unit_price) AS line_total
FROM orders o
JOIN users u        ON u.user_id = o.user_id
JOIN order_items oi  ON oi.order_id = o.order_id
JOIN products p      ON p.product_id = oi.product_id;
```

```sql
SELECT order_id, username, order_status, product_name, quantity, unit_price, line_total
FROM v_order_summary
WHERE order_id = 1
ORDER BY product_name;
```

**Output:**

| order_id | username | order_status | product_name | quantity | unit_price | line_total |
|---|---|---|---|---|---|---|
| 1 | arjun_k | DELIVERED | Galaxy Phone X | 1 | 45999.00 | 45999.00 |
| 1 | arjun_k | DELIVERED | Wireless Earbuds | 1 | 3499.00 | 3499.00 |

### Line-by-line explanation
- Four tables (`orders`, `users`, `order_items`, `products`) are joined once,
  inside the view.
- Any consumer now writes `SELECT ... FROM v_order_summary WHERE order_id =
  1` — one relation, zero joins to get wrong.
- `line_total` is a **computed column** — it exists only in the view's
  output, not stored anywhere. It is recalculated every time the view is
  queried.

### Why it exists
This is the textbook "simplifying complex joins for consumers" use case:
a reporting analyst, a support engineer looking up an order, or an
application's order-history endpoint all get a single, self-explanatory
relation instead of having to know the schema's join graph.

> **⚠️ Warning**
> `v_order_summary` returns one row *per order line item*, not one row per
> order. `SELECT SUM(line_total) FROM v_order_summary WHERE order_id = 1;`
> correctly sums to `49498.00` (`45999.00 + 3499.00`) — but
> `SELECT COUNT(*) FROM v_order_summary;` counts line items across *all*
> orders, not orders. Views don't change cardinality rules; they just hide
> the join that produced that cardinality. Always know what one row of a
> view represents before aggregating over it.

### Example 3 — an aggregated, order-level view

```sql
CREATE VIEW v_order_totals AS
SELECT
    o.order_id,
    o.user_id,
    o.status AS order_status,
    COUNT(oi.order_item_id)            AS item_count,
    SUM(oi.quantity * oi.unit_price)   AS order_total
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY o.order_id, o.user_id, o.status;
```

```sql
SELECT * FROM v_order_totals ORDER BY order_id;
```

**Output:**

| order_id | user_id | order_status | item_count | order_total |
|---|---|---|---|---|
| 1 | 1 | DELIVERED | 2 | 49498.00 |
| 2 | 2 | DELIVERED | 2 | 5097.00 |
| 3 | 1 | SHIPPED | 1 | 89999.00 |
| 4 | 3 | PAID | 2 | 3298.00 |
| 5 | 4 | CANCELLED | 1 | 29999.00 |
| 6 | 5 | DELIVERED | 2 | 75798.00 |
| 7 | 6 | PENDING | 1 | 6998.00 |
| 8 | 1 | DELIVERED | 1 | 45999.00 |
| 9 | 7 | PAID | 2 | 93498.00 |
| 10 | 8 | DELIVERED | 1 | 3897.00 |

This is a genuinely useful reporting view — one row per order, correctly
aggregated — but as you'll see in Section 15.5, `GROUP BY` makes it
**not automatically updatable**.

---

## 15.4 CREATE OR REPLACE VIEW

### Simple explanation
`CREATE OR REPLACE VIEW` lets you redefine a view's query without dropping
it first — which matters because dropping a view can cascade-break every
grant and every dependent object built on top of it.

### Syntax

```sql
CREATE OR REPLACE VIEW v_order_summary AS
SELECT
    o.order_id,
    u.username,
    o.order_date,
    o.status AS order_status,
    p.product_name,
    oi.quantity,
    oi.unit_price,
    (oi.quantity * oi.unit_price) AS line_total,
    p.category_id                       -- new column appended
FROM orders o
JOIN users u        ON u.user_id = o.user_id
JOIN order_items oi  ON oi.order_id = o.order_id
JOIN products p      ON p.product_id = oi.product_id;
```

### The restriction that trips everyone up **[PostgreSQL]**

> **⚠️ Warning**
> `CREATE OR REPLACE VIEW` can only **append new columns to the end** of the
> column list, or change the query behind existing columns *without*
> altering their name, order, or data type. It cannot:
> - drop an existing output column,
> - reorder existing output columns,
> - change an existing column's data type.
>
> Any of these raise:
> `ERROR: cannot change name of view column "product_name" to "name"`
> or
> `ERROR: cannot drop columns from view`
>
> To make those changes you must `DROP VIEW` (optionally `CASCADE`) and
> `CREATE VIEW` again — which also drops any grants and dependent views,
> so they must be re-created too.

MySQL and SQL Server enforce similarly strict rules around
`CREATE OR REPLACE VIEW` / `ALTER VIEW`: you can change the query body, but
reshaping the output column list generally requires dropping and
recreating. Oracle's `CREATE OR REPLACE VIEW` is the most permissive of the
four — it will happily change column types and orders, invalidating (and
then transparently revalidating) dependent objects.

---

## 15.5 Updatable Views

### Simple explanation
Some views are just a thin, filtered window onto one table — for those, it
makes sense to let `INSERT`/`UPDATE`/`DELETE` pass straight through to the
underlying table. Other views combine, aggregate, or transform data in ways
that make "which underlying row do you mean?" ambiguous or undefined — those
cannot be automatically writable.

### Technical explanation — when a view is automatically updatable **[PostgreSQL]**

A view is automatically updatable if **all** of the following hold:

1. Exactly **one** table (or updatable view) in its `FROM` clause — no joins.
2. No `DISTINCT`, `GROUP BY`, `HAVING`, `LIMIT`/`OFFSET`, `UNION`/
   `INTERSECT`/`EXCEPT` at the top level.
3. No aggregate functions (`SUM`, `COUNT`, `AVG`, ...) or window functions
   in the select list.
4. No set-returning functions in the select list.
5. Every column being modified maps directly to a column of the base table
   (not an expression like `price * 1.1`).

`v_active_customers` (Section 15.2) qualifies on every count: one table,
no aggregation, no joins, plain columns. `v_order_summary` (a 4-table join)
and `v_order_totals` (`GROUP BY`) both fail rule 1 and rule 2/3
respectively.

### Per-dialect summary

| Dialect | Updatable view rule | Notes |
|---|---|---|
| **PostgreSQL** | Single relation in `FROM`, no aggregation/`DISTINCT`/`GROUP BY`/window functions/`UNION` | Multi-table views need an `INSTEAD OF` trigger or a rewrite rule to become writable. |
| **MySQL** | Similar core rule, but MySQL *does* allow updating a joined view's columns **if each column you touch maps to exactly one base table** | `INSERT` through a joined view is still disallowed. |
| **Oracle** | Allows "key-preserved" join views to be updated — a joined table is key-preserved if its primary/unique key is also unique in the joined result | More permissive than Postgres for multi-table views; still forbids updates that touch non-key-preserved tables. |
| **SQL Server** | Single base table per modified column; multi-table views generally require `INSTEAD OF` triggers | `WITH CHECK OPTION` supported identically to Postgres/MySQL syntax. |

### Example 4 — proving updatability

```sql
-- This works: v_active_customers is a single-table, unfiltered-column view
UPDATE v_active_customers
SET full_name = 'Arjun K. Kumar'
WHERE user_id = 1;
```

```sql
SELECT user_id, full_name FROM users WHERE user_id = 1;
```

**Output:**

| user_id | full_name |
|---|---|
| 1 | Arjun K. Kumar |

The `UPDATE` was issued against the view but landed in the real `users`
table — because the view's rewrite rule turns it into exactly that
`UPDATE users SET full_name = ... WHERE user_id = 1 AND is_active = TRUE`.

```sql
-- This fails: v_order_summary is a 4-table join
UPDATE v_order_summary
SET quantity = 2
WHERE order_id = 1 AND product_name = 'Galaxy Phone X';
```

```
ERROR:  cannot update view "v_order_summary"
DETAIL:  Views that do not select from a single table or view are not
         automatically updatable.
HINT:    To enable updating the view, provide an INSTEAD OF trigger or an
         unconditional ON UPDATE DO INSTEAD rule.
```

This is exactly the **edge case** called out in real-world view design:
updating through a join is ambiguous by nature. If you set `quantity = 2`
on a row of `v_order_summary`, does that mean "update `order_items.quantity`
for this order/product," or "update something in `orders`," or both? SQL
engines refuse to guess — you write an explicit `INSTEAD OF` trigger
(Chapter 22) if you truly need this.

---

## 15.6 WITH CHECK OPTION **[PostgreSQL / MySQL / SQL Server]**

### Simple explanation
`WITH CHECK OPTION` stops you from using a filtered view to sneak in rows
that the view's own `WHERE` clause would immediately hide. Without it, a
view can become a one-way door: you insert a row through it, and it
vanishes from that same view forever.

### Technical explanation
When a view is defined with a `WHERE` clause and marked `WITH CHECK
OPTION`, every `INSERT` or `UPDATE` performed *through the view* is
validated against that `WHERE` clause before being committed. If the new or
modified row would **not** appear in the view's result set, the statement
is rejected.

### Syntax

```sql
CREATE VIEW v_active_customers_checked AS
SELECT user_id, username, email, full_name, is_active
FROM users
WHERE is_active = TRUE
WITH CHECK OPTION;                 -- defaults to CASCADED
```

`LOCAL` vs `CASCADED` matters only when views are layered on top of other
views:

- **`CASCADED`** (the default) — checks this view's `WHERE` **and every
  underlying view's `WHERE`** in the chain.
- **`LOCAL`** — checks only this view's own `WHERE` clause; a violation of
  an *underlying* view's condition is allowed through if this view doesn't
  also filter on it.

```sql
-- Hypothetical layered view, illustrating LOCAL vs CASCADED
CREATE VIEW v_active_customers_pune AS
SELECT * FROM v_active_customers        -- inner view: is_active = TRUE
WHERE EXISTS (
    SELECT 1 FROM orders o
    WHERE o.user_id = v_active_customers.user_id
      AND o.shipping_address LIKE '%Pune%'
)
WITH LOCAL CHECK OPTION;
```

With `LOCAL`, an `INSERT` through `v_active_customers_pune` is only checked
against the Pune `EXISTS` condition — it would **not** be rejected for
setting `is_active = FALSE`, even though that violates the inner view's
filter, because `LOCAL` doesn't cascade the check downward. `CASCADED`
would reject it.

### Example 5 — WITH CHECK OPTION in action

```sql
-- Attempt to flip an active customer to inactive THROUGH the checked view
UPDATE v_active_customers_checked
SET is_active = FALSE
WHERE user_id = 1;
```

**PostgreSQL:**
```
ERROR:  new row violates check option for view "v_active_customers_checked"
DETAIL:  Failing row contains (1, arjun_k, arjun.k@mail.com,
         Arjun K. Kumar, f).
```

**MySQL:**
```
ERROR 1369 (HY000): CHECK OPTION failed
'ecommerce_db.v_active_customers_checked'
```

**SQL Server:**
```
The attempted insert or update failed because the target view either
specifies WITH CHECK OPTION or spans a view that specifies WITH CHECK
OPTION and one or more rows resulting from the operation did not qualify
under the CHECK OPTION constraint.
```

The row *would* be updated successfully in `users` (a plain `UPDATE users
SET is_active = FALSE WHERE user_id = 1` works fine) — the rejection is
specific to going through this particular view, precisely because the
resulting row would immediately disappear from the view's own result set.

```sql
-- Attempt to insert a row that would never appear in the view
INSERT INTO v_active_customers_checked (username, email, full_name, is_active)
VALUES ('ghost_user', 'ghost@mail.com', 'Ghost User', FALSE);
```
```
ERROR:  new row violates check option for view "v_active_customers_checked"
```

> **Important Note**
> `WITH CHECK OPTION` is only meaningful on views that are updatable in the
> first place (Section 15.5) and that have a `WHERE` clause. On a view with
> no `WHERE` clause, every row automatically satisfies the "check," so it's
> a no-op.

---

## 15.7 View Limitations — What You Cannot Do

| Limitation | Why |
|---|---|
| Can't `INSERT`/`UPDATE`/`DELETE` through multi-table (joined) views without an `INSTEAD OF` trigger (Postgres/SQL Server) | Ambiguous which base table/row is meant. |
| Can't `INSERT`/`UPDATE`/`DELETE` through aggregated/`DISTINCT`/`GROUP BY` views | No 1:1 mapping between a view row and a base-table row. |
| Can't `CREATE INDEX` directly on a plain view | A plain view has no storage of its own — see Section 15.9. |
| Can't reorder/drop/retype columns with `CREATE OR REPLACE VIEW` | See Section 15.4 — must drop and recreate. |
| Performance does not improve by wrapping a query in a view | See Section 15.11's common mistakes — a view is not a cache. |
| A view referencing a column that is later dropped will break | See Section 15.13 edge cases. |

---

## 15.8 Complex Views for Reporting

Real reporting layers are built from views that combine joins *and*
aggregation to answer a specific business question in one `SELECT *`.

### Example 6 — `v_customer_lifetime_value`

```sql
CREATE VIEW v_customer_lifetime_value AS
SELECT
    u.user_id,
    u.username,
    u.full_name,
    COUNT(DISTINCT o.order_id) FILTER (WHERE pm.status = 'SUCCESS')      AS successful_orders,
    COALESCE(SUM(pm.amount)   FILTER (WHERE pm.status = 'SUCCESS'), 0)   AS lifetime_value
FROM users u
LEFT JOIN orders o    ON o.user_id = u.user_id
LEFT JOIN payments pm ON pm.order_id = o.order_id
GROUP BY u.user_id, u.username, u.full_name;
```

> **[MySQL] / [SQL Server]** — `FILTER (WHERE ...)` is PostgreSQL/SQL
> standard syntax not supported by MySQL or SQL Server. Use conditional
> aggregation instead:
> ```sql
> COUNT(DISTINCT CASE WHEN pm.status = 'SUCCESS' THEN o.order_id END)        AS successful_orders,
> COALESCE(SUM(CASE WHEN pm.status = 'SUCCESS' THEN pm.amount END), 0)       AS lifetime_value
> ```

```sql
SELECT * FROM v_customer_lifetime_value ORDER BY lifetime_value DESC;
```

**Output:**

| user_id | username | successful_orders | lifetime_value |
|---|---|---|---|
| 1 | arjun_k | 3 | 185496.00 |
| 7 | farhan_a | 1 | 93498.00 |
| 5 | imran_s | 1 | 75798.00 |
| 2 | sara_p | 1 | 4097.00 |
| 8 | tanya_b | 1 | 3897.00 |
| 3 | dev_m | 1 | 3298.00 |
| 4 | nita_r | 0 | 0.00 |
| 6 | lakshmi_v | 0 | 0.00 |

### Line-by-line explanation
- `LEFT JOIN` (not `INNER JOIN`) from `users` keeps customers with zero
  orders in the result — `nita_r` and `lakshmi_v` both appear with
  `lifetime_value = 0` instead of disappearing.
- `FILTER (WHERE pm.status = 'SUCCESS')` only counts/sums payments that
  actually succeeded — order 5 (Nita Rao, `CANCELLED`/`FAILED` payment) and
  order 7 (Lakshmi Venkat, still `PENDING`) correctly contribute `0`.
- Notice `sara_p`'s `lifetime_value` is `4097.00`, while her order's line
  items (`order_id = 2`: 2 × Men Cotton Shirt @ 1299.00 + 1 × Non-stick Pan
  Set @ 2499.00 = 5097.00) sum to a *different*, higher number. This is
  intentional in the seed data and a real lesson: the **captured payment**
  (what actually settled) can legitimately differ from the **catalog order
  subtotal** (a coupon, rounding adjustment, or partial refund at checkout).
  This is exactly why `v_customer_lifetime_value` is built from `payments`,
  not from `order_items` — lifetime value should reflect real cash
  collected, not the theoretical cart total.

> **Important Note**
> This view is **not** automatically updatable (it has `GROUP BY` and
> aggregates) — and that's correct. Nobody should be able to
> `UPDATE v_customer_lifetime_value SET lifetime_value = 0`; this view
> exists purely for reading a computed rollup.

### Example 7 — `v_best_selling_products`

```sql
CREATE VIEW v_best_selling_products AS
SELECT
    p.product_id,
    p.product_name,
    SUM(oi.quantity)                   AS total_units_sold,
    SUM(oi.quantity * oi.unit_price)   AS total_revenue,
    COUNT(DISTINCT oi.order_id)        AS order_count
FROM products p
JOIN order_items oi ON oi.product_id = p.product_id
GROUP BY p.product_id, p.product_name;
```

```sql
SELECT * FROM v_best_selling_products ORDER BY total_units_sold DESC;
```

**Output:**

| product_id | product_name | total_units_sold | total_revenue | order_count |
|---|---|---|---|---|
| 5 | Men Cotton Shirt | 5 | 6495.00 | 2 |
| 9 | Wireless Earbuds | 4 | 13996.00 | 3 |
| 1 | Galaxy Phone X | 2 | 91998.00 | 2 |
| 3 | UltraBook Pro 14 | 2 | 179998.00 | 2 |
| 2 | Pixel Lite | 1 | 29999.00 | 1 |
| 4 | GameBook 15 | 1 | 74999.00 | 1 |
| 6 | Women Kurta Set | 1 | 1799.00 | 1 |
| 7 | Non-stick Pan Set | 1 | 2499.00 | 1 |
| 8 | Electric Kettle | 1 | 1499.00 | 1 |
| 10 | Laptop Sleeve 14" | 1 | 799.00 | 1 |

> **⚠️ Warning — don't `ORDER BY` inside a view definition**
> It is tempting to write `... GROUP BY ... ORDER BY total_units_sold DESC`
> as part of the view itself. Avoid it: the SQL standard does not guarantee
> a view's internal `ORDER BY` survives once the view is embedded in another
> query (PostgreSQL frequently preserves it in practice when there's no
> outer `ORDER BY`, but relying on that is fragile and non-portable; MySQL
> explicitly discourages it). Always add `ORDER BY` at the point where you
> actually query the view, as done above.

---

## 15.9 Security Through Views

### Simple explanation
Instead of granting `SELECT` on a sensitive table, grant `SELECT` on a view
that only shows the columns and rows a given role is allowed to see. The
role never even knows the sensitive table exists.

### Why it exists
`GRANT`/`REVOKE` (Chapter 27) operate at the table/column level, but
column-level grants are clunky and don't compose well with joins. A view
lets you express "this role sees name, title, and department — never salary
or email" as a single reusable object with one `GRANT`.

### Example 8 — hiding the salaries table entirely (`company_db`)

```sql
CREATE VIEW v_employee_directory AS
SELECT
    e.employee_id,
    e.first_name,
    e.last_name,
    e.job_title,
    d.department_name,
    e.hire_date,
    e.status
FROM employees e
LEFT JOIN departments d ON d.department_id = e.department_id;
```

This view never references `salaries` at all — a role granted access to
`v_employee_directory` cannot reach compensation data through it no matter
how it queries the view, because the underlying `salaries` table is simply
absent from the view's defining query.

```sql
CREATE ROLE directory_reader NOLOGIN;
GRANT SELECT ON v_employee_directory TO directory_reader;
-- directory_reader is never granted anything on employees or salaries directly
```

### Example 9 — an "HR-lite" view excluding sensitive columns

```sql
CREATE VIEW v_employee_public AS
SELECT
    employee_id,
    first_name,
    last_name,
    job_title,
    department_id,
    status
FROM employees;
-- email and (via omission) salaries are both unreachable through this view
```

### Example 10 — the sensitive counterpart, restricted to HR/Finance

```sql
CREATE VIEW v_employee_compensation AS
SELECT
    e.employee_id,
    e.first_name,
    e.last_name,
    d.department_name,
    s.base_salary,
    s.bonus,
    s.effective_date
FROM employees e
JOIN departments d ON d.department_id = e.department_id
JOIN salaries s     ON s.employee_id = e.employee_id
WHERE s.effective_date = (
    SELECT MAX(s2.effective_date)
    FROM salaries s2
    WHERE s2.employee_id = e.employee_id
);
```

```sql
SELECT * FROM v_employee_compensation ORDER BY employee_id LIMIT 5;
```

**Output:**

| employee_id | first_name | last_name | department_name | base_salary | bonus | effective_date |
|---|---|---|---|---|---|---|
| 1 | Aditi | Rao | Engineering | 520000.00 | 100000.00 | 2020-01-01 |
| 2 | Rahul | Mehta | Engineering | 320000.00 | 50000.00 | 2021-01-01 |
| 3 | Sneha | Kulkarni | Engineering | 210000.00 | 25000.00 | 2022-01-01 |
| 4 | Vikram | Joshi | Engineering | 140000.00 | 12000.00 | 2022-01-01 |
| 5 | Ananya | Singh | Engineering | 120000.00 | 10000.00 | 2019-09-01 |

```sql
CREATE ROLE hr_finance NOLOGIN;
GRANT SELECT ON v_employee_compensation TO hr_finance;
-- Only hr_finance (not directory_reader) can ever see this view or salaries directly
```

> **Important Note**
> This is **defense in depth via least privilege**, not encryption. If a
> role somehow also has raw `SELECT` on `salaries` or `employees`, the view
> provides zero protection — security through views only works when the
> underlying tables' grants are locked down and the view is the *only*
> path a role has to that data.

### Example 11 — a department-level rollup for wide reporting access

```sql
CREATE VIEW v_department_salary_summary AS
SELECT
    d.department_name,
    COUNT(e.employee_id)              AS headcount,
    SUM(s.base_salary)                AS total_base_salary,
    ROUND(AVG(s.base_salary), 2)      AS avg_base_salary
FROM departments d
JOIN employees e ON e.department_id = d.department_id
JOIN salaries s   ON s.employee_id = e.employee_id
WHERE s.effective_date = (
    SELECT MAX(s2.effective_date) FROM salaries s2 WHERE s2.employee_id = e.employee_id
)
GROUP BY d.department_name;
```

```sql
SELECT * FROM v_department_salary_summary ORDER BY department_name;
```

**Output:**

| department_name | headcount | total_base_salary | avg_base_salary |
|---|---|---|---|
| Engineering | 7 | 1485000.00 | 212142.86 |
| Finance | 2 | 380000.00 | 190000.00 |
| HR | 2 | 340000.00 | 170000.00 |
| Marketing | 2 | 335000.00 | 167500.00 |
| Sales | 3 | 505000.00 | 168333.33 |

This is a safe view to widely grant even to a general "executives" or
"all-managers" role — it exposes *aggregate* compensation cost per
department without revealing any individual's salary.

---

## 15.10 Materialized Views

### Simple explanation
A materialized view is a view that actually did its homework and wrote the
answer down. Instead of re-running the query every time, the database
stores the *result rows* on disk, like a table, and you explicitly tell it
when to redo the work and update that stored copy.

### Technical explanation
A materialized view has its own physical storage (its own heap/relation in
PostgreSQL terms, with its own `relfilenode`, statistics, and the ability
to carry indexes). Its contents are a **snapshot** taken at
`CREATE MATERIALIZED VIEW` time (or the last `REFRESH`), not a live view of
the base tables. Reading it is exactly as fast as reading any ordinary
table, because it *is* an ordinary table under the hood — the only
difference is metadata marking it as materialized and recording the query
used to (re)populate it.

### Why it exists
Some reporting queries are expensive: multi-table joins with aggregation
over large volumes, run by many users, where perfect real-time freshness is
not required (a "yesterday's numbers" dashboard, a nightly sales rollup).
Materialized views let you pay the expensive computation cost **once**, on
a schedule, instead of on every single read.

### Syntax **[PostgreSQL]**

```sql
CREATE MATERIALIZED VIEW mv_product_sales_summary AS
SELECT
    p.product_id,
    p.product_name,
    SUM(oi.quantity)                   AS total_units_sold,
    SUM(oi.quantity * oi.unit_price)   AS total_revenue,
    COUNT(DISTINCT oi.order_id)        AS order_count
FROM products p
JOIN order_items oi ON oi.product_id = p.product_id
GROUP BY p.product_id, p.product_name
WITH DATA;                       -- WITH DATA populates it immediately (default)
```

`WITH NO DATA` creates the object and its structure but leaves it empty and
**unqueryable** until the first `REFRESH MATERIALIZED VIEW` — useful when
you want to define the object during a migration but populate it later, in
a controlled maintenance window.

```sql
SELECT * FROM mv_product_sales_summary ORDER BY total_units_sold DESC;
```

**Output** (identical to `v_best_selling_products` at the moment of
creation, but now physically stored):

| product_id | product_name | total_units_sold | total_revenue | order_count |
|---|---|---|---|---|
| 5 | Men Cotton Shirt | 5 | 6495.00 | 2 |
| 9 | Wireless Earbuds | 4 | 13996.00 | 3 |
| 1 | Galaxy Phone X | 2 | 91998.00 | 2 |
| 3 | UltraBook Pro 14 | 2 | 179998.00 | 2 |
| 2 | Pixel Lite | 1 | 29999.00 | 1 |
| 4 | GameBook 15 | 1 | 74999.00 | 1 |
| 6 | Women Kurta Set | 1 | 1799.00 | 1 |
| 7 | Non-stick Pan Set | 1 | 2499.00 | 1 |
| 8 | Electric Kettle | 1 | 1499.00 | 1 |
| 10 | Laptop Sleeve 14" | 1 | 799.00 | 1 |

### Indexing a materialized view

Unlike a plain view, a materialized view genuinely has rows on disk — so
you **can** index it, and doing so speeds up reads exactly as it would on
any table:

```sql
CREATE INDEX idx_mv_product_sales_units ON mv_product_sales_summary (total_units_sold DESC);
```

A **unique** index is additionally required to support concurrent refresh
(next section):

```sql
CREATE UNIQUE INDEX idx_mv_product_sales_summary_pk
    ON mv_product_sales_summary (product_id);
```

### Dialect support for materialized views

| Dialect | Support |
|---|---|
| **PostgreSQL** | Native `CREATE MATERIALIZED VIEW` / `REFRESH MATERIALIZED VIEW [CONCURRENTLY]`, fully covered above. |
| **Oracle** | Full native materialized view support, including `REFRESH FAST` (incremental, via a materialized view log), `REFRESH COMPLETE`, `REFRESH FORCE`, and `ON COMMIT` refresh triggered automatically by transactions against the base tables. |
| **MySQL** | **No native materialized views.** Must be simulated with a real table plus a scheduled job (below). |
| **SQL Server** | No object literally called "materialized view"; the closest equivalent is an **indexed view** (below), which behaves quite differently. |

#### Oracle native materialized view **[Oracle]**

```sql
CREATE MATERIALIZED VIEW LOG ON products WITH ROWID;
CREATE MATERIALIZED VIEW LOG ON order_items WITH ROWID;

CREATE MATERIALIZED VIEW mv_product_sales_summary
BUILD IMMEDIATE
REFRESH FAST ON DEMAND
AS
SELECT
    p.product_id,
    p.product_name,
    SUM(oi.quantity)                 AS total_units_sold,
    SUM(oi.quantity * oi.unit_price) AS total_revenue
FROM products p
JOIN order_items oi ON oi.product_id = p.product_id
GROUP BY p.product_id, p.product_name;

-- Later:
EXEC DBMS_MVIEW.REFRESH('MV_PRODUCT_SALES_SUMMARY', 'FAST');
```

`REFRESH FAST` uses the materialized view log to apply only the *changes*
since the last refresh (an incremental refresh) rather than recomputing the
whole thing — Oracle's biggest edge in this space.

#### MySQL simulation via table + scheduled event **[MySQL]**

> **Important Note**
> MySQL genuinely has no materialized view object. The idiomatic
> workaround is a plain table that you refresh yourself, usually via the
> `EVENT` scheduler or an external cron/orchestration job. Be explicit in
> documentation that this is a simulation — nothing enforces that the table
> stays in sync automatically the way `REFRESH MATERIALIZED VIEW` does.

```sql
CREATE TABLE mv_product_sales_summary (
    product_id        INT PRIMARY KEY,
    product_name      VARCHAR(150),
    total_units_sold  INT,
    total_revenue     DECIMAL(12,2),
    order_count       INT,
    refreshed_at      TIMESTAMP
);

SET GLOBAL event_scheduler = ON;

DELIMITER $$
CREATE EVENT refresh_mv_product_sales_summary
ON SCHEDULE EVERY 1 HOUR
DO
BEGIN
    DELETE FROM mv_product_sales_summary;
    INSERT INTO mv_product_sales_summary
        (product_id, product_name, total_units_sold, total_revenue, order_count, refreshed_at)
    SELECT
        p.product_id, p.product_name,
        SUM(oi.quantity), SUM(oi.quantity * oi.unit_price),
        COUNT(DISTINCT oi.order_id), NOW()
    FROM products p
    JOIN order_items oi ON oi.product_id = p.product_id
    GROUP BY p.product_id, p.product_name;
END$$
DELIMITER ;
```

#### SQL Server indexed views **[SQL Server]**

An indexed view is a *regular* view that has a **unique clustered index**
built on it. Unlike a materialized view, an indexed view's storage is kept
**automatically and transactionally in sync** with the base tables (SQL
Server updates the index as part of every `INSERT`/`UPDATE`/`DELETE` on the
base tables) — there is no `REFRESH` step, but this also means write
overhead on the base tables goes up, unlike a Postgres materialized view
which only costs you at refresh time.

```sql
CREATE VIEW dbo.v_order_item_stats
WITH SCHEMABINDING
AS
SELECT
    oi.product_id,
    SUM(oi.quantity)                   AS total_units_sold,
    SUM(oi.quantity * oi.unit_price)   AS total_revenue,
    COUNT_BIG(*)                       AS line_count
FROM dbo.order_items oi
GROUP BY oi.product_id;
GO

CREATE UNIQUE CLUSTERED INDEX idx_v_order_item_stats
    ON dbo.v_order_item_stats (product_id);
```

Indexed views require `WITH SCHEMABINDING`, `COUNT_BIG` instead of
`COUNT`, fully-qualified (two-part) table names, and disallow correlated
subqueries and several other constructs — a considerably stricter set of
rules than a Postgres materialized view, in exchange for always-fresh data.

---

## 15.11 Refreshing Materialized Views **[PostgreSQL]**

### Full refresh

```sql
REFRESH MATERIALIZED VIEW mv_product_sales_summary;
```

This recomputes the entire defining query and replaces the materialized
view's contents. It takes an **`ACCESS EXCLUSIVE`** lock on the
materialized view for the duration — any query trying to read from it
**blocks** until the refresh completes.

### Concurrent refresh

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_product_sales_summary;
```

**Why `CONCURRENTLY` requires a unique index:** a plain refresh replaces
the entire storage in one atomic swap, so it has no notion of "this row" —
it doesn't need to identify individual rows. `CONCURRENTLY` works
differently: it computes the new result set into a temporary space, then
**diffs** it row-by-row against the existing materialized view contents to
figure out exactly which rows were inserted, deleted, or changed. To
perform that diff, PostgreSQL needs a way to uniquely identify each row —
which is exactly what a `UNIQUE` index gives it. Without one:

```
ERROR:  cannot refresh materialized view "mv_product_sales_summary" concurrently
HINT:   Create a unique index with no WHERE clause on one or more columns
        of the materialized view.
```

**What problem `CONCURRENTLY` solves:** without it, every refresh briefly
makes the materialized view completely unreadable — a dashboard querying it
mid-refresh simply hangs. With `CONCURRENTLY`, readers keep getting the
**old** snapshot throughout the refresh (no blocking, no waiting), and only
the identified changed rows are applied via targeted `UPDATE`/`INSERT`/
`DELETE` once the new snapshot is ready — a brief, row-level lock instead of
a whole-relation lock.

```sql
CREATE UNIQUE INDEX idx_mv_product_sales_summary_pk
    ON mv_product_sales_summary (product_id);

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_product_sales_summary;
```

> **⚠️ Warning**
> `CONCURRENTLY` is typically *slower* than a plain refresh (it has to
> compute the full new result set *and* diff it row by row) — you're
> trading refresh throughput for read availability. For an internal
> nightly batch job where nobody is querying at 3 AM, plain
> `REFRESH MATERIALIZED VIEW` is simpler and faster. For a materialized
> view backing a live dashboard that must never appear to "go blank,"
> `CONCURRENTLY` is worth the extra cost.

A typical production refresh strategy is a scheduled job (cron, `pg_cron`,
Airflow, etc.) running on a cadence matched to how stale the data is
allowed to be:

```sql
-- e.g., run every hour via pg_cron
SELECT cron.schedule(
    'refresh-product-sales-summary',
    '0 * * * *',
    $$REFRESH MATERIALIZED VIEW CONCURRENTLY mv_product_sales_summary$$
);
```

---

## 15.12 Deep Dive — View vs. Table vs. Materialized View

| Aspect | View | Materialized View | Table |
|---|---|---|---|
| **Storage** | None — stores only the query definition | Physical snapshot of rows, stored like a table | Live, physical rows — the source of truth |
| **Freshness** | Always current (re-runs live against base tables on every query) | Stale until explicitly refreshed | Always current by definition — it *is* the data |
| **Performance (read)** | Underlying query re-executes every time; adds planning/execution overhead of the full defining query | Fast — reading it is identical to reading any table | Fast — direct row access, benefits from indexes/statistics |
| **Performance (write)** | N/A for the view itself; writes go to base tables (if updatable) | No direct writes; maintenance cost is the refresh, done on a schedule | Normal write cost (subject to indexes, constraints, triggers) |
| **Can be indexed?** | No — only the underlying base tables can be indexed | Yes — behaves like a table for indexing purposes | Yes |
| **Maintenance burden** | None beyond keeping the query definition correct | Must schedule/monitor refreshes; risk of serving stale data | Normal (constraints, indexes, vacuum/maintenance) |
| **Best for** | Reusable logic, security abstraction, simplifying joins, always-correct small/medium reads | Expensive aggregations read far more often than the underlying data changes; dashboards, reports tolerant of some staleness | Data that must be written, and read with guaranteed correctness/currency |

> **Important Note — the single most common interview trap**
> "Does a view improve performance?" — **No.** A plain view is a saved
> query, not a saved result. `SELECT * FROM v_order_summary` does exactly
> the same join work as writing the join out by hand every time. Only a
> **materialized view** trades freshness for read speed by actually storing
> results.

---

## 15.13 View vs. CTE

A Common Table Expression (Chapter 9) and a view look similar — both name a
`SELECT` for reuse — but they differ in **scope and persistence**:

| Aspect | View | CTE (`WITH ... AS (...)`) |
|---|---|---|
| Persisted? | Yes — a schema object, survives across sessions | No — exists only for the duration of the single statement it's attached to |
| Reusable across queries? | Yes — any session, any query, any time, can `SELECT FROM` it | No — must be rewritten (or recursively referenced within the same query) every time |
| Needs privileges to create? | Yes (`CREATE VIEW` privilege on the schema) | No — any query author can write one inline |
| Can be granted access to independently? | Yes — this is the whole basis of security-through-views | No — access is governed by privileges on the underlying tables referenced inside it |
| Typical use | Stable, named business concepts ("active customers," "order summary") shared across an application/team | One-off readability/organization within a single complex query |

A good rule of thumb: if you find yourself copy-pasting the same `WITH
customer_totals AS (...)` CTE into a fifth different query, that's a strong
signal it should graduate into a view.

---

## 15.14 Common Mistakes

> **⚠️ Warning — Mistake 1: assuming a view improves performance**
> A view is a saved *question*, not a saved *answer*. Wrapping a slow
> 5-table join in `CREATE VIEW slow_report AS SELECT ...` produces a view
> that is exactly as slow, every single time it's queried. Only indexes on
> the base tables, query rewriting, or a materialized view actually change
> execution cost.

> **⚠️ Warning — Mistake 2: forgetting to refresh a materialized view**
> `mv_product_sales_summary` will confidently keep returning last week's
> numbers forever if nothing calls `REFRESH MATERIALIZED VIEW`. There is no
> automatic invalidation in PostgreSQL — unlike a plain view, it does *not*
> notice that `order_items` changed. Always pair a materialized view with an
> explicit, monitored refresh job, and consider exposing `refreshed_at` /
> `pg_stat_user_tables.last_autovacuum`-style metadata so consumers can tell
> how stale the data is.

> **⚠️ Warning — Mistake 3: trying to index a plain view**
> ```sql
> CREATE INDEX idx_v_order_summary_order_id ON v_order_summary (order_id);
> ```
> ```
> ERROR:  "v_order_summary" is not a table
> ```
> A plain view has no storage to attach an index to. If you need indexed
> access, either index the underlying base tables (`orders`, `order_items`,
> etc. — which speeds up the view too, since it's inlined into those
> tables' scans) or convert the reporting query into a materialized view
> and index that instead.

> **⚠️ Warning — Mistake 4: treating a view as a snapshot for auditing**
> Because a view always re-runs live, it is a poor tool for "what did this
> report look like on March 1st." If you need a point-in-time snapshot, you
> want either a materialized view refreshed and archived on that date, or
> an actual historized table (Chapter 26 territory).

---

## 15.15 Edge Cases

**Updating through a view with a JOIN.** As shown in Section 15.5, this is
ambiguous and rejected by default in PostgreSQL and SQL Server; MySQL
allows it only when every touched column maps unambiguously to a single
base table; Oracle allows it for "key-preserved" tables in the join. When
in doubt, write an explicit `INSTEAD OF` trigger (Chapter 22) that spells
out exactly what an `UPDATE`/`INSERT`/`DELETE` through the view should do.

**A view referencing a dropped or altered underlying column.**

```sql
ALTER TABLE products DROP COLUMN sku;
```
```
ERROR:  cannot drop column sku of table products because other objects
        depend on it
DETAIL: view v_order_summary depends on column sku of table products
HINT:   Use DROP ... CASCADE to drop the dependent objects too.
```

PostgreSQL protects you here by refusing the `DROP COLUMN` outright unless
you explicitly `CASCADE` — and `CASCADE` will silently `DROP` the dependent
view along with it. Renaming a column the view depends on
(`ALTER TABLE products RENAME COLUMN sku TO product_sku;`) is **allowed**
and PostgreSQL automatically updates the view's internal reference — no
break. But changing a column's **type** in an incompatible way, or a
downstream `CREATE OR REPLACE VIEW` that tries to shrink/reorder columns
(Section 15.4), will break or be rejected.

> **Important Note**
> This is a strong argument for `SELECT` explicit column lists instead of
> `SELECT *` inside view definitions — a `SELECT *` view silently changes
> its output shape whenever a column is added to the base table, which can
> break consumers who assumed a fixed column order.

---

## 15.16 View vs. Materialized View vs. Querying Directly vs. Denormalizing

| Situation | Best tool |
|---|---|
| You want a stable, reusable name for a join/filter that must always reflect live data | **View** |
| You want to hide sensitive columns/tables from a role | **View** |
| The underlying query is cheap and run occasionally | **Query the tables directly** — a view adds a name but no speed |
| The underlying query is expensive (large aggregation/joins), read far more often than the source data changes, and some staleness (minutes/hours) is acceptable | **Materialized view** |
| The underlying query is expensive **and** must always be perfectly fresh **and** write-side latency can absorb extra cost | **SQL Server indexed view** (auto-synced) or restructure the write path to maintain a real summary table via triggers |
| You need the computed values to be genuinely queryable at high volume with full transactional guarantees, foreign keys, and independent write paths | **Denormalize into a real table**, maintained by the application or triggers — this is a deliberate schema decision (Chapter 14), not something `CREATE VIEW`/`CREATE MATERIALIZED VIEW` alone gives you |

---

## 15.17 Real-World Use Cases

- **Reporting layers.** A `reporting` schema full of views (`v_order_totals`,
  `v_customer_lifetime_value`, `v_best_selling_products`) gives analysts a
  stable, documented "semantic layer" over a schema that keeps evolving
  underneath.
- **BI tool read models.** Tools like Metabase, Looker, or Tableau connect
  to views instead of raw tables so that join logic is defined once, in the
  database, not re-implemented (and re-broken) inside every dashboard.
- **Access control boundaries.** SaaS platforms expose a `public_api` schema
  of views to read-replicas or external analytics roles, keeping raw
  operational tables (with PII, secrets, or internal-only columns) entirely
  unreachable.
- **Backward compatibility during migrations.** Rename a column, then leave
  a view behind under the old name during a phased application rollout, so
  old and new application code can both run against the same database.
- **Expensive dashboard aggregates.** A materialized view refreshed hourly
  backs an executive sales dashboard, so a hundred people loading it don't
  each trigger the same expensive 5-table `GROUP BY` against live
  transactional tables.

---

## 15.18 Practice Questions

1. Explain, in your own words, why a plain `CREATE VIEW` never makes a
   query faster, and describe the one PostgreSQL planner behavior
   (predicate pushdown into the view) that can make it *look* faster in
   some cases.
2. Write a view `v_pending_payments` over `ecommerce_db` showing every
   order whose payment `status` is `'PENDING'` or `'FAILED'`, along with the
   customer's `username` and the `order_total`. Is it automatically
   updatable? Justify your answer using the rules in Section 15.5.
3. What specific column list restrictions does `CREATE OR REPLACE VIEW`
   enforce in PostgreSQL, and what must you do instead if you need to
   remove a column from a view's output?
4. Design a `WITH CHECK OPTION` view over `company_db.employees` that only
   exposes employees with `status = 'ACTIVE'`. Write the `INSERT` statement
   that would be rejected by the check option, and explain exactly why.
5. Explain the difference between `LOCAL` and `CASCADED` check options
   using two layered views of your own design.
6. A colleague indexes `v_department_salary_summary` directly with
   `CREATE INDEX ... ON v_department_salary_summary (...)` and it fails.
   What is the correct fix, and why does it fail in the first place?
7. Design a materialized view over `company_db` that reports headcount and
   average current base salary per department (you may reuse the logic
   from `v_department_salary_summary`). Then write the `CREATE UNIQUE
   INDEX` statement required to allow `REFRESH MATERIALIZED VIEW
   CONCURRENTLY` on it, and explain what column(s) you chose and why.
8. Why does `REFRESH MATERIALIZED VIEW CONCURRENTLY` typically take longer
   than a plain `REFRESH MATERIALIZED VIEW`, and under what operational
   circumstance is that trade-off worth it?
9. Compare a view and a CTE that both compute "customer lifetime value."
   Under what circumstance would you promote a CTE into a permanent view?
10. A materialized view was refreshed at 2:00 AM. At 9:00 AM, a support
    engineer insists the dashboard numbers are wrong because a return was
    processed at 8:45 AM. Diagnose what's actually happening and propose
    two different fixes with different trade-offs.

---

## 15.19 Chapter Challenge — Build a Reporting Layer for `ecommerce_db`

Design a small but production-credible reporting layer of **two or three
views plus one materialized view** on top of `ecommerce_db`. For each
object, write the full `CREATE VIEW`/`CREATE MATERIALIZED VIEW` statement
and a short justification of your design choices.

**Requirements:**

1. **`v_customer_lifetime_value`** — one row per customer, with total
   successful spend and successful order count (you may reuse Example 6).
   *Justify:* why is this a plain view and not materialized, given that
   `payments` and `orders` are relatively small and change frequently?

2. **`v_best_selling_products`** — one row per product, with units sold,
   revenue, and number of distinct orders (you may reuse Example 7).
   *Justify:* what role in the organization should be granted `SELECT` on
   this view versus direct access to `order_items`/`products`, and why?

3. **(Optional third view)** A view of your own design — for example,
   `v_customer_order_history` combining `v_order_summary`-style detail with
   customer identity, intended for a customer-support tool. *Justify:*
   what columns would you deliberately exclude to avoid leaking data a
   support agent shouldn't see (e.g., another customer's information via a
   missing `WHERE` clause, or internal cost data)?

4. **One materialized view** — pick the single most expensive, most
   frequently-read aggregate from your reporting layer (a natural choice is
   a category-level or daily sales rollup joining `products`,
   `categories`, `order_items`, and `orders`) and materialize it.
   - Write the `CREATE MATERIALIZED VIEW` statement.
   - Write the `CREATE UNIQUE INDEX` needed to support
     `REFRESH MATERIALIZED VIEW CONCURRENTLY`, and justify your choice of
     unique key.
   - Propose a concrete refresh cadence (e.g., hourly, nightly) and justify
     it in terms of how stale the business can tolerate this specific
     number being.
   - Explain what would go wrong for your dashboard's users if the refresh
     job silently stopped running for a week, and how you'd detect that
     before a stakeholder does.

There is no single correct answer — grade your own design against this
checklist: does every view/materialized view choice map to a stated
freshness requirement, a stated audience/security boundary, and a stated
read-frequency-vs-write-frequency trade-off, rather than being "materialized
because it seemed faster"?

---

## Key Takeaways

- A **view** is a stored query, not a stored result — it is inlined
  (rewritten) into whatever query references it and re-executes the
  underlying `SELECT` every time. It never improves performance by itself.
- A view is **automatically updatable** only when it selects from a single
  base table/view with no aggregation, `DISTINCT`, `GROUP BY`, or window
  functions; joined or aggregated views need an `INSTEAD OF` trigger to
  support writes.
- `WITH CHECK OPTION` **[PostgreSQL/MySQL/SQL Server]** prevents
  `INSERT`/`UPDATE` through a filtered view from creating rows that
  immediately vanish from that same view; `LOCAL` vs `CASCADED` controls
  whether the check propagates through layered views.
- `CREATE OR REPLACE VIEW` can only append columns or change logic behind
  existing columns — it cannot reorder, retype, or drop them; that requires
  `DROP VIEW`/`CREATE VIEW`.
- Views are a first-class **security tool**: grant `SELECT` on a view that
  hides sensitive tables/columns entirely, instead of granting broader
  access to the base tables.
- A **materialized view** genuinely stores rows on disk, can be indexed,
  and reads exactly as fast as a table — but it goes stale the moment the
  base data changes, and must be explicitly refreshed
  (`REFRESH MATERIALIZED VIEW [CONCURRENTLY]` in PostgreSQL).
  `CONCURRENTLY` requires a `UNIQUE` index so the engine can diff old vs.
  new rows and let readers keep querying the old snapshot without blocking.
- Materialized view support is **highly dialect-dependent**: native and
  rich in PostgreSQL and Oracle, entirely absent (simulate with a table +
  scheduled job) in MySQL, and approximated by auto-synced but stricter
  **indexed views** in SQL Server.
- A view is a persisted, schema-level, cross-session object; a CTE is
  scoped to a single statement — promote a repeatedly copy-pasted CTE into
  a view.

## What's Next

Chapter 16 turns to **Indexes** — the mechanism that actually makes queries
(including the ones hiding behind your views) fast. You'll learn how
B-tree, hash, and other index types work internally, how the planner
decides whether to use one, and why the materialized views and base tables
built in this chapter are the right (and, for plain views, the *only*)
place to put them.
