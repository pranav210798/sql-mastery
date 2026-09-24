# Project 3 — E-Commerce Order, Catalog & Inventory System

> Part of **Chapter 32 — Real-World Projects** (Part VII, Applied Mastery). This project
> assumes you have completed Chapters 1–26 — in particular Chapter 11 (Transactions & ACID),
> Chapter 12 (Locks & Concurrency), Chapter 15 (Views & Materialized Views), Chapter 16
> (Indexes), Chapter 19 (Stored Procedures), Chapter 22 (Triggers), Chapter 23 (Dynamic SQL),
> Chapter 24 (Temporary Tables), and Chapter 25 (Advanced Data Types: JSON/Array/UUID/ENUM/
> Full-Text). Every statement in this document runs against the **exact, unmodified** schema
> and seed data in `databases/ecommerce_db.sql`. We do not redefine `users`, `categories`,
> `products`, `inventory`, `orders`, `order_items`, `payments`, or `reviews` — we only *add*
> columns, indexes, triggers, procedures, and one materialized view on top of them, exactly
> the way a real engineering team evolves a schema over time via migrations.
>
> Primary dialect: **PostgreSQL 15+**. Dialect notes are called out with **[MySQL]**,
> **[Oracle]**, **[SQL Server]** only where the behavior genuinely diverges.

```bash
psql -f databases/ecommerce_db.sql
psql -f projects/03-ecommerce.md   # (informal — copy/paste the SQL blocks below in order,
                                    #  or extract them into a .sql file; see §2.3)
```

---

## 1. Project Brief

### 1.1 The scenario

You've joined the engineering team at a small online retailer. The company already has a
working relational schema — `users`, `categories`, `products`, `inventory`, `orders`,
`order_items`, `payments`, `reviews` — and a modest but real transaction history: 8
registered customers, 7 categories (2 of which are top-level with subcategories), 10 SKUs,
11 inventory rows spread across 3 warehouses (Mumbai, Delhi, Pune), 10 historical orders,
15 order line items, 10 payment attempts, and 6 product reviews.

The catalog and checkout flow currently exist only as raw tables — there is no application
logic in the database enforcing "don't sell what you don't have," no fast way to answer "what
are this customer's total lifetime purchases," and no index strategy tuned to how the site is
actually queried. Your job, as the database engineer on this team, is to design and build the
logic layer: safe checkout, safe cancellation, denormalized aggregates for performance,
merchandising/analytics reports, and an indexing strategy — all directly against this schema.

Everything below is built and verified against the *actual* rows already in
`ecommerce_db` — every total, average, and rank shown in this document is the real,
reproducible output of running the query against the seed data, not an illustrative
approximation.

### 1.2 Functional requirements

1. **FR1 — Atomic checkout.** Placing an order must validate stock availability, decrement
   inventory, and create the order header, order line items, and a `PENDING` payment row, all
   as a single all-or-nothing unit of work (Ch11 Transactions).
2. **FR2 — No overselling under concurrency.** If two customers try to buy the last unit(s) of
   the same product/warehouse at the same instant, exactly one must succeed and the other must
   receive a clean rejection with **no partial data left behind** (Ch12 Locks & Concurrency).
3. **FR3 — Order cancellation.** A `PENDING` or `PAID` order can be cancelled, which restores
   the reserved inventory to the warehouse it was picked from and updates order/payment status
   consistently.
4. **FR4 — Denormalized order total.** `orders.total_amount` must always reflect the current
   sum of that order's line items, maintained automatically — not recomputed on every read
   (Ch22 Triggers).
5. **FR5 — Fast product ratings.** A product's average rating and review count must be
   available without aggregating the `reviews` table on every product-page render
   (Ch15 Materialized Views).
6. **FR6 — Best sellers per category.** Merchandising needs a "top products by units sold,
   per category" report for the homepage and category pages (Ch10 Window Functions).
7. **FR7 — Customer lifetime value.** Report each customer's total realized spend, ranked, and
   the platform-wide repeat-purchase rate.
8. **FR8 — Low-stock / reorder report.** Operations needs a report of every inventory row at or
   below its `reorder_level`, to drive purchasing decisions.
9. **FR9 — Product search.** Customers must be able to search products by name, case-
   insensitively and with partial matches (Ch5 Functions, Ch25 Advanced Data Types).
10. **FR10 — Index strategy.** The top query patterns above must be backed by deliberately
    designed indexes, justified by selectivity and column order, including at least one
    partial index and one expression index (Ch16 Indexes).
11. **FR11 — Trend reporting.** Operations wants month-over-month order volume and value
    growth (Ch10 Window Functions — `LAG`).
12. **FR12 — Data integrity reconciliation.** Because `orders.total_amount` and
    `payments.amount` are captured independently, the system must be able to detect when they
    disagree (a real anomaly you will find in this very seed data — see §3.7.4).

### 1.3 Assumptions & non-goals

> **Important Note:** This project **adds** to `ecommerce_db` — it never `DROP`s or redefines
> a base table. All new objects (columns, indexes, triggers, procedures, the materialized
> view) are additive migrations, exactly as you'd write them against a live production
> database that already has real rows in it.

- We assume a single-currency, single-tax-jurisdiction store (no multi-currency, no tax
  engine) — out of scope, called out again in §5.
- We assume payment *capture* is handled by an external payment gateway; this project models
  only the order-side bookkeeping (`payments` rows transition `PENDING → SUCCESS/FAILED` via
  a webhook handler that is outside this schema).
- Every SKU in the seed data happens to live in exactly one warehouse except `product_id = 1`
  (Galaxy Phone X), which is split across Mumbai-WH1 (40 units) and Delhi-WH2 (15 units) —
  this is precisely why checkout must be warehouse-aware, not just product-aware.

---

## 2. Schema Recap & Additions

### 2.1 The base schema (unchanged)

```
users(user_id PK, username, email, full_name, created_at, is_active)
categories(category_id PK, category_name, parent_category_id → categories)
products(product_id PK, product_name, category_id → categories, price, sku, created_at, is_discontinued)
inventory(inventory_id PK, product_id → products, warehouse_location, quantity_on_hand, reorder_level)
          UNIQUE(product_id, warehouse_location)
orders(order_id PK, user_id → users, order_date, status, shipping_address)
order_items(order_item_id PK, order_id → orders, product_id → products, quantity, unit_price)
           UNIQUE(order_id, product_id)
payments(payment_id PK, order_id → orders, payment_date, amount, payment_method, status)
reviews(review_id PK, product_id → products, user_id → users, rating, review_text, review_date)
       UNIQUE(product_id, user_id)
```

Seed data at a glance (all numbers verified in §3):

| Table | Rows | Notes |
|---|---|---|
| `users` | 8 | 1 inactive (`nita_r`, `is_active = FALSE`) |
| `categories` | 7 | 2 top-level (Electronics, Fashion) + 5 leaf categories |
| `products` | 10 | all assigned to leaf categories (2, 3, 5, 6, 7) |
| `inventory` | 11 | product 1 spans 2 warehouses; product 9 has 0 on hand |
| `orders` | 10 | statuses: 5 DELIVERED, 1 SHIPPED, 2 PAID, 1 PENDING, 1 CANCELLED |
| `order_items` | 15 | |
| `payments` | 10 | 8 SUCCESS, 1 FAILED, 1 PENDING |
| `reviews` | 6 | only 5 of 10 products have any review |

### 2.2 New objects this project adds

| Object | Kind | Purpose |
|---|---|---|
| `orders.total_amount` | column (`ALTER TABLE`) | denormalized, trigger-maintained order total (FR4) |
| `order_items.warehouse_location` | column (`ALTER TABLE`) | records *which* warehouse fulfilled each line, so cancellation restocks the right place (FR1, FR3) |
| `fn_update_order_total` / `trg_order_items_update_total` | trigger | keeps `total_amount` in sync (FR4) |
| `place_order` | procedure | atomic checkout (FR1, FR2) |
| `cancel_order` | procedure | atomic cancellation (FR3) |
| `mv_product_ratings` | materialized view | fast rating aggregates (FR5) |
| `idx_orders_user_id`, `idx_orders_pending`, `idx_products_name_lower`, `idx_products_category_price`, `idx_order_items_product_id` | indexes | FR10 |

### 2.3 Load order

Run `databases/ecommerce_db.sql` first (unchanged), then apply the migration blocks in §3.1
and §3.2 in order, then the procedures in §3.3/§3.5, then the materialized view in §3.6. Every
block is idempotent-safe with `CREATE OR REPLACE` / `IF NOT EXISTS` where PostgreSQL supports
it, so re-running this file top-to-bottom against a freshly reloaded `ecommerce_db` reproduces
every number in this document exactly.

---

## 3. Implementation

### 3.1 Migration: `orders.total_amount`

```sql
SET search_path TO ecommerce_db;

-- Step 1: add the column, nullable-safe with a default so the ALTER doesn't
-- fail against existing rows.
ALTER TABLE orders
    ADD COLUMN total_amount NUMERIC(12,2) NOT NULL DEFAULT 0;

-- Step 2: backfill it from the order_items that already exist.
UPDATE orders o
SET total_amount = s.total
FROM (
    SELECT order_id, SUM(quantity * unit_price) AS total
    FROM order_items
    GROUP BY order_id
) s
WHERE o.order_id = s.order_id;
```

> **Important Note:** We add the column with `DEFAULT 0` and backfill in a second step rather
> than trying to compute the default from a subquery in the `ALTER TABLE` itself — PostgreSQL
> doesn't allow a correlated subquery as a column default, and even if it did, doing the
> backfill as an explicit, auditable `UPDATE` is exactly what you'd do against a production
> table with millions of rows so you can control batching, monitor progress, and roll back
> the backfill independently of the DDL. This mirrors the migration discipline from Ch22/Ch24.

After this runs, `SELECT order_id, total_amount FROM orders ORDER BY order_id;` returns:

| order_id | total_amount |
|---|---|
| 1 | 49498.00 |
| 2 | **5097.00** |
| 3 | 89999.00 |
| 4 | 3298.00 |
| 5 | 29999.00 |
| 6 | 75798.00 |
| 7 | 6998.00 |
| 8 | 45999.00 |
| 9 | 93498.00 |
| 10 | 3897.00 |

> **⚠️ Warning — a real anomaly, not a typo:** Order 2's line items (`2 × Men Cotton Shirt @
> 1299.00` + `1 × Non-stick Pan Set @ 2499.00` = `2598.00 + 2499.00 = 5097.00`) do **not**
> match the `4097.00` recorded in `payments` for that order. This is a genuine discrepancy
> already present in the seed data — we deliberately do not "fix" it, because it's the perfect
> real-world justification for FR4/FR12: once `total_amount` is independently and reliably
> maintained from the line items, a one-line reconciliation query (§3.7.4) finds this
> mismatch automatically instead of it silently costing the business money.

### 3.2 Migration: `order_items.warehouse_location` + the total-maintenance trigger

Cancelling an order needs to know *which warehouse* a line item was picked from so it can
restock the correct row (recall: `product_id = 1` exists in two warehouses). The base schema
doesn't capture that, so we add it:

```sql
-- Nullable first — safe against existing rows — then backfilled, then locked down.
ALTER TABLE order_items
    ADD COLUMN warehouse_location VARCHAR(100);

-- Backfill: for products stocked in exactly one warehouse this is unambiguous.
-- For product 1 (the one product split across two warehouses), we deterministically
-- pick the warehouse holding the larger quantity as the historical "most likely"
-- fulfillment source — a documented simplification for pre-migration rows only.
-- All NEW orders placed via place_order() (§3.3) record the real warehouse used.
UPDATE order_items oi
SET warehouse_location = pick.warehouse_location
FROM (
    SELECT DISTINCT ON (product_id) product_id, warehouse_location
    FROM inventory
    ORDER BY product_id, quantity_on_hand DESC
) pick
WHERE oi.product_id = pick.product_id
  AND oi.warehouse_location IS NULL;

ALTER TABLE order_items
    ALTER COLUMN warehouse_location SET NOT NULL;
```

> **Important Note:** This backfill heuristic only matters for historical rows. For
> `product_id = 1` (Mumbai-WH1: 40 units, Delhi-WH2: 15 units), the `DISTINCT ON ... ORDER BY
> quantity_on_hand DESC` picks **Mumbai-WH1** for both of its historical order lines
> (order 1 and order 8). Every other product has exactly one inventory row, so the backfill is
> unambiguous for them. This is a realistic illustration of a common migration problem:
> backfilling a column with information the original schema never captured always requires an
> explicit, documented assumption.

Now the trigger that keeps `orders.total_amount` correct going forward, satisfying FR4:

```sql
CREATE OR REPLACE FUNCTION fn_update_order_total()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_id INT;
BEGIN
    -- COALESCE handles all three trigger events: NEW is set for INSERT/UPDATE,
    -- OLD is set for UPDATE/DELETE. For a DELETE, NEW is NULL, so we fall back to OLD.
    v_order_id := COALESCE(NEW.order_id, OLD.order_id);

    UPDATE orders
    SET total_amount = COALESCE(
        (SELECT SUM(quantity * unit_price)
         FROM order_items
         WHERE order_id = v_order_id),
        0)
    WHERE order_id = v_order_id;

    RETURN NULL;  -- return value of an AFTER trigger is ignored by PostgreSQL
END;
$$;

CREATE TRIGGER trg_order_items_update_total
AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW
EXECUTE FUNCTION fn_update_order_total();
```

> **Important Note:** This is an `AFTER ... FOR EACH ROW` trigger (Ch22), not a `BEFORE`
> trigger, because it needs to see the *committed-within-transaction* state of `order_items`
> (via the `SELECT SUM(...)` re-query) after the triggering row has already been written. It
> deliberately recomputes the full sum rather than doing `total_amount = total_amount +
> NEW.quantity*NEW.unit_price` — the incremental version would be faster on very wide tables,
> but the full recompute is self-healing: if `total_amount` ever drifts (e.g., from a manual
> `UPDATE order_items` run by a DBA outside the app), the very next `order_items` write on that
> order silently repairs it. On a table with 15 rows total, the cost difference is irrelevant;
> at scale you would switch to the incremental form and accept the loss of self-healing.

### 3.3 `place_order` — atomic, concurrency-safe checkout

This is the core procedure for FR1 and FR2. It:

1. Validates the buyer exists and is active.
2. Inserts the order header (`status` defaults to `'PENDING'`).
3. For each requested `(product_id, quantity, warehouse_location)` line:
   a. Locks the specific inventory row with `SELECT ... FOR UPDATE`.
   b. Rejects the whole order if that row doesn't exist or doesn't have enough stock.
   c. Decrements `quantity_on_hand`.
   d. Inserts the `order_items` row (which fires the trigger from §3.2 and keeps
      `total_amount` correct automatically).
4. Inserts a `PENDING` payment row for the now-known `total_amount`.

```sql
CREATE OR REPLACE PROCEDURE place_order(
    IN    p_user_id           INT,
    IN    p_shipping_address  VARCHAR,
    IN    p_items             JSONB,   -- '[{"product_id":4,"quantity":2,"warehouse_location":"Pune-WH1"}, ...]'
    IN    p_payment_method    VARCHAR,
    INOUT p_order_id          INT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_item         JSONB;
    v_product_id   INT;
    v_qty          INT;
    v_warehouse    VARCHAR(100);
    v_unit_price   NUMERIC(10,2);
    v_available    INT;
    v_inventory_id INT;
    v_order_total  NUMERIC(12,2);
BEGIN
    -- (1) Guard clause: the buyer must exist and be an active account.
    PERFORM 1 FROM users WHERE user_id = p_user_id AND is_active = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'place_order: user % does not exist or is inactive', p_user_id;
    END IF;

    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'place_order: an order must contain at least one item';
    END IF;

    -- (2) Create the order header first. status defaults to 'PENDING' per the
    -- base schema's CHECK constraint. total_amount starts at 0 and will be
    -- filled in by the trigger as line items are inserted below.
    INSERT INTO orders (user_id, shipping_address)
    VALUES (p_user_id, p_shipping_address)
    RETURNING order_id INTO p_order_id;

    -- (3) Walk each requested line item.
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_product_id := (v_item ->> 'product_id')::INT;
        v_qty        := (v_item ->> 'quantity')::INT;
        v_warehouse  := v_item ->> 'warehouse_location';

        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'place_order: quantity for product % must be positive', v_product_id;
        END IF;

        -- (3a) THE LINCHPIN OF THIS ENTIRE PROCEDURE.
        -- FOR UPDATE takes an exclusive row lock on this exact (product_id,
        -- warehouse_location) inventory row *right now*, inside this open
        -- transaction. Any other session running this same SELECT ... FOR
        -- UPDATE against the same row will block here until we COMMIT or the
        -- procedure raises an exception (which rolls everything back). This is
        -- the direct, practical application of Ch12's "SELECT ... FOR UPDATE"
        -- section to the classic "two customers buy the last item" problem.
        SELECT inventory_id, quantity_on_hand
          INTO v_inventory_id, v_available
          FROM inventory
         WHERE product_id = v_product_id
           AND warehouse_location = v_warehouse
         FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'place_order: no inventory row for product % at warehouse %',
                v_product_id, v_warehouse;
        END IF;

        -- (3b) Stock check happens AFTER acquiring the lock, not before. Checking
        -- before locking would re-open the exact race condition FOR UPDATE exists
        -- to close (a "check-then-act" TOCTOU bug).
        IF v_available < v_qty THEN
            RAISE EXCEPTION
                'place_order: insufficient stock for product % at % (requested %, available %)',
                v_product_id, v_warehouse, v_qty, v_available;
        END IF;

        -- (3c) Decrement stock while still holding the row lock.
        UPDATE inventory
           SET quantity_on_hand = quantity_on_hand - v_qty
         WHERE inventory_id = v_inventory_id;

        -- (3d) Snapshot the current catalog price onto the line item — order
        -- history must never change retroactively just because a product's
        -- price changes later. This mirrors real order_items semantics already
        -- in the base schema (unit_price is stored per-line, not looked up live).
        SELECT price INTO v_unit_price FROM products WHERE product_id = v_product_id;

        INSERT INTO order_items (order_id, product_id, quantity, unit_price, warehouse_location)
        VALUES (p_order_id, v_product_id, v_qty, v_unit_price, v_warehouse);
        -- ^ This INSERT fires trg_order_items_update_total (§3.2), which
        --   recomputes orders.total_amount for p_order_id automatically.
    END LOOP;

    -- (4) The order total is now known and correct — read it back for the payment row.
    SELECT total_amount INTO v_order_total FROM orders WHERE order_id = p_order_id;

    INSERT INTO payments (order_id, amount, payment_method, status)
    VALUES (p_order_id, v_order_total, p_payment_method, 'PENDING');

EXCEPTION
    WHEN OTHERS THEN
        -- Log context, then RE-RAISE. We do NOT swallow the error here.
        RAISE NOTICE 'place_order: rolling back — user=%, error=%', p_user_id, SQLERRM;
        RAISE;
END;
$$;
```

> **⚠️ Warning — a classic PL/pgSQL gotcha:** An `EXCEPTION` block establishes an implicit
> savepoint at the *start of the block it's attached to*. Because the `EXCEPTION WHEN OTHERS`
> clause above is attached to the **outermost** `BEGIN` of the procedure — i.e., it wraps the
> entire body — catching an error there rolls back everything the procedure has done since it
> started (the order header insert, every inventory decrement, every `order_items` insert so
> far), not just the most recent statement. Then `RAISE;` re-raises the original error so the
> `CALL` itself fails. If you nested a *separate* inner `BEGIN ... EXCEPTION ... END` block
> around just the stock check, catching there would only roll back to the start of that inner
> block, leaving the order header (and any earlier line items) committed as garbage. Always be
> deliberate about exactly how much work an exception handler's implicit savepoint covers.

> **Important Note:** A bare `CALL place_order(...)` run outside an explicit `BEGIN`/`COMMIT`
> is still fully atomic in PostgreSQL — a top-level statement (including a `CALL`) runs inside
> its own implicit transaction. If the procedure raises an uncaught exception, PostgreSQL rolls
> back everything the call did, exactly like FR1 requires. You only need an explicit `BEGIN`
> around the `CALL` if you want to bundle it with *other* statements (e.g., logging) as one
> larger unit of work.

**Rejecting a request with zero stock (simple case, no concurrency needed):**

`product_id = 9` (Wireless Earbuds) currently has `quantity_on_hand = 0` at Mumbai-WH1 — every
unit sold historically (orders 1, 7, 9 — 4 units total) has already been decremented out of
this snapshot.

```sql
CALL place_order(
    2, '45 Park St, Kolkata',
    '[{"product_id": 9, "quantity": 1, "warehouse_location": "Mumbai-WH1"}]'::jsonb,
    'UPI', NULL
);
```

```
ERROR:  place_order: insufficient stock for product 9 at Mumbai-WH1 (requested 1, available 0)
NOTICE:  place_order: rolling back — user=2, error=place_order: insufficient stock for product 9 at Mumbai-WH1 (requested 1, available 0)
```

No order, no order_items, no payment row is left behind — verified by
`SELECT COUNT(*) FROM orders;` still returning `10` after the failed call.

### 3.4 The "last item in stock" race — a real two-session timeline

This is FR2, demonstrated exactly the way Chapter 12 teaches it. `product_id = 4` (GameBook
15) has only **3 units** on hand at Pune-WH1 (`reorder_level = 5` — it's already below reorder
threshold). Two customers, `dev_m` (`user_id = 3`) and `lakshmi_v` (`user_id = 6`), both try to
buy from this same row at effectively the same instant: dev_m wants all 3 remaining units,
lakshmi_v wants 2.

| Time | Session A (`dev_m`, terminal 1) | Session B (`lakshmi_v`, terminal 2) |
|---|---|---|
| T0 | `BEGIN;` (implicit via `CALL`) | `BEGIN;` (implicit via `CALL`) |
| T1 | `CALL place_order(3, '9 Lake View, Bengaluru', '[{"product_id":4,"quantity":3,"warehouse_location":"Pune-WH1"}]'::jsonb, 'CARD', NULL);` starts. Inserts order header (`order_id = 11`). Reaches `SELECT ... FOR UPDATE` on the `product_id=4 / Pune-WH1` inventory row. **Lock acquired.** Sees `quantity_on_hand = 3`. | `CALL place_order(6, '21 Hill Rd, Chennai', '[{"product_id":4,"quantity":2,"warehouse_location":"Pune-WH1"}]'::jsonb, 'UPI', NULL);` starts. Inserts order header (`order_id = 12`). Reaches the same `SELECT ... FOR UPDATE`. **Blocks** — row is locked by Session A. Terminal hangs, no error yet. |
| T2 | `3 <= 3` → check passes. `UPDATE inventory SET quantity_on_hand = 0`. Inserts `order_items` row (trigger sets `orders.total_amount = 74999.00` for order 11). Inserts `PENDING` payment. | *(still blocked)* |
| T3 | `COMMIT` (procedure returns normally). Row lock released. | Immediately unblocks. `SELECT ... FOR UPDATE` now returns the **post-commit** row: `quantity_on_hand = 0`. |
| T4 | — | `2 <= 0` is false → `RAISE EXCEPTION 'insufficient stock for product 4 at Pune-WH1 (requested 2, available 0)'`. |
| T5 | — | Exception handler fires `RAISE NOTICE`, then re-raises. Because this is inside the same procedure call/implicit transaction, **everything Session B did — including its own `order_id = 12` header insert — rolls back.** |
| Result | Order 11 exists, `PAID`-pending, 3 units of product 4 sold, inventory now 0. | No order, no order_items, no payment. Customer sees a clean "insufficient stock" error and can retry against a different warehouse or wait for restock. |

> **Important Note:** The key mechanism is that `SELECT ... FOR UPDATE` in Session B doesn't
> just *wait* — when it wakes up after Session A commits, it **re-reads the row's current
> committed value** (`quantity_on_hand = 0`), not the stale value it would have seen before
> blocking. This is exactly the guarantee Ch12 describes: `FOR UPDATE` combined with a
> post-lock re-check is what turns a "check-then-act" race into a safe, serialized sequence.
> If Session B's procedure had checked stock *before* requesting the lock (or used a plain
> `SELECT` without `FOR UPDATE`), both sessions could have read `quantity_on_hand = 3`
> simultaneously and both "succeeded," oversold by 2 units — the exact bug this design
> prevents.

> **⚠️ Warning:** This pattern (`FOR UPDATE` per-row, in a fixed order — here, always locking
> the single inventory row referenced by each JSON line in the order it appears) is also how
> you avoid **deadlocks** when an order has multiple line items: if two large orders both touch
> products 4 and 9, always locking rows in the same relative order (e.g., ascending
> `inventory_id`, or simply the order the client listed them) prevents the classic "A holds
> lock 1 waiting for lock 2, B holds lock 2 waiting for lock 1" deadlock cycle from Ch12.

### 3.5 `cancel_order` — restoring inventory correctly

```sql
CREATE OR REPLACE PROCEDURE cancel_order(IN p_order_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(20);
    v_item   RECORD;
BEGIN
    -- Lock the order row itself so a concurrent cancel/ship/pay on the same
    -- order can't race with this one.
    SELECT status INTO v_status FROM orders WHERE order_id = p_order_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'cancel_order: order % does not exist', p_order_id;
    END IF;

    IF v_status NOT IN ('PENDING', 'PAID') THEN
        RAISE EXCEPTION
            'cancel_order: order % cannot be cancelled from status %', p_order_id, v_status;
    END IF;

    -- Restore each line item's quantity to the exact warehouse it was picked
    -- from — this is why order_items.warehouse_location exists (§3.2).
    FOR v_item IN
        SELECT product_id, quantity, warehouse_location
        FROM order_items
        WHERE order_id = p_order_id
    LOOP
        UPDATE inventory
           SET quantity_on_hand = quantity_on_hand + v_item.quantity
         WHERE product_id = v_item.product_id
           AND warehouse_location = v_item.warehouse_location;
    END LOOP;

    UPDATE orders SET status = 'CANCELLED' WHERE order_id = p_order_id;

    -- A payment that was never collected (still PENDING) simply fails;
    -- a payment that was already collected (SUCCESS) must be refunded.
    UPDATE payments
       SET status = CASE status
                        WHEN 'SUCCESS' THEN 'REFUNDED'
                        WHEN 'PENDING' THEN 'FAILED'
                        ELSE status
                     END
     WHERE order_id = p_order_id;
END;
$$;
```

**Demonstration** — order 7 (`lakshmi_v`, `PENDING`, `product_id = 9 × 2` at Mumbai-WH1) is a
good candidate: it's still cancellable, and product 9 is currently the most out-of-stock item
in the whole catalog (`quantity_on_hand = 0`), so cancelling it visibly improves the low-stock
picture.

```sql
CALL cancel_order(7);

SELECT status FROM orders WHERE order_id = 7;
--   status
-- -----------
--  CANCELLED

SELECT status FROM payments WHERE order_id = 7;
--   status
-- ---------
--  FAILED     -- was PENDING before the cancel

SELECT product_id, warehouse_location, quantity_on_hand
FROM inventory WHERE product_id = 9;
--  product_id | warehouse_location | quantity_on_hand
-- ------------+---------------------+-------------------
--           9 | Mumbai-WH1          |                 2   -- was 0
```

> **Important Note:** `cancel_order` intentionally checks `status NOT IN ('PENDING','PAID')`
> and rejects everything else. A `SHIPPED` or `DELIVERED` order represents inventory that has
> physically left the warehouse — cancelling it in the database wouldn't un-ship it. That
> business flow belongs to a separate **return/refund workflow** (see §5).

### 3.6 `mv_product_ratings` — materialized product ratings (FR5)

```sql
CREATE MATERIALIZED VIEW mv_product_ratings AS
SELECT
    p.product_id,
    p.product_name,
    COUNT(r.review_id)          AS review_count,
    ROUND(AVG(r.rating), 2)     AS avg_rating
FROM products p
LEFT JOIN reviews r ON r.product_id = p.product_id
GROUP BY p.product_id, p.product_name
WITH DATA;

-- A unique index on the view is required for REFRESH ... CONCURRENTLY (Ch15).
CREATE UNIQUE INDEX idx_mv_product_ratings_product_id
    ON mv_product_ratings (product_id);
```

```sql
SELECT product_id, product_name, review_count, avg_rating
FROM mv_product_ratings
ORDER BY product_id;
```

| product_id | product_name | review_count | avg_rating |
|---|---|---|---|
| 1 | Galaxy Phone X | 2 | 3.50 |
| 2 | Pixel Lite | 0 | *(NULL)* |
| 3 | UltraBook Pro 14 | 1 | 5.00 |
| 4 | GameBook 15 | 1 | 3.00 |
| 5 | Men Cotton Shirt | 1 | 4.00 |
| 6 | Women Kurta Set | 0 | *(NULL)* |
| 7 | Non-stick Pan Set | 0 | *(NULL)* |
| 8 | Electric Kettle | 0 | *(NULL)* |
| 9 | Wireless Earbuds | 1 | 4.00 |
| 10 | Laptop Sleeve 14" | 0 | *(NULL)* |

Galaxy Phone X's `3.50` comes from its two reviews — a `5` (user 1: "Excellent phone, great
camera") and a `2` (user 7: "Received a defective unit") — `(5 + 2) / 2 = 3.5`.

**Refresh strategy.** Product ratings don't need sub-second freshness — a few minutes of
staleness on a product page is an acceptable trade-off for not aggregating `reviews` on every
page view. Two workable strategies, in increasing order of freshness/complexity:

1. **Scheduled batch refresh (recommended for this catalog's write volume).** A cron job or
   `pg_cron` job runs `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_product_ratings;` every few
   minutes. `CONCURRENTLY` (available because of the unique index above) rebuilds the view
   without taking an `ACCESS EXCLUSIVE` lock, so reads against the view are never blocked
   during a refresh — the trade-off is it takes roughly twice as long and needs that unique
   index (Ch15).
2. **Trigger-notified, asynchronously refreshed.** An `AFTER INSERT OR UPDATE OR DELETE`
   trigger on `reviews` issues `NOTIFY ratings_stale;`; a background worker listening on that
   channel debounces bursts of review activity and runs the same `REFRESH ... CONCURRENTLY`
   shortly after. This gets ratings fresh within seconds of a new review without refreshing on
   every single insert, which matters once review volume is high.

> **⚠️ Warning:** Do **not** refresh a materialized view synchronously inside the same trigger
> that fires on every `reviews` insert. `REFRESH MATERIALIZED VIEW` recomputes the *entire*
> view, so doing it once per review write turns an O(1) insert into an O(n) operation on every
> single review submitted — it will not scale past a small catalog.

### 3.7 Analytical reports

#### 3.7.1 Best-selling products per category (window functions, FR6)

```sql
WITH product_sales AS (
    SELECT
        p.product_id,
        p.product_name,
        p.category_id,
        c.category_name,
        SUM(oi.quantity)                 AS units_sold,
        SUM(oi.quantity * oi.unit_price) AS revenue
    FROM order_items oi
    JOIN products   p ON p.product_id  = oi.product_id
    JOIN categories c ON c.category_id = p.category_id
    GROUP BY p.product_id, p.product_name, p.category_id, c.category_name
),
ranked AS (
    SELECT *,
           RANK() OVER (PARTITION BY category_id ORDER BY units_sold DESC) AS category_rank
    FROM product_sales
)
SELECT category_name, product_name, units_sold, revenue, category_rank
FROM ranked
WHERE category_rank <= 2
ORDER BY category_id, category_rank, product_name;
```

| category_name | product_name | units_sold | revenue | category_rank |
|---|---|---|---|---|
| Mobiles | Wireless Earbuds | 4 | 13996.00 | 1 |
| Mobiles | Galaxy Phone X | 2 | 91998.00 | 2 |
| Laptops | UltraBook Pro 14 | 2 | 179998.00 | 1 |
| Laptops | GameBook 15 | 1 | 74999.00 | 2 |
| Laptops | Laptop Sleeve 14" | 1 | 799.00 | 2 |
| Men | Men Cotton Shirt | 5 | 6495.00 | 1 |
| Women | Women Kurta Set | 1 | 1799.00 | 1 |
| Home & Kitchen | Electric Kettle | 1 | 1499.00 | 1 |
| Home & Kitchen | Non-stick Pan Set | 1 | 2499.00 | 1 |

> **Important Note:** `RANK()` (not `ROW_NUMBER()`) is deliberate here — Laptops has a genuine
> tie for 2nd place (GameBook 15 and Laptop Sleeve 14" both sold exactly 1 unit), and Home &
> Kitchen has a tie for 1st (Electric Kettle and Non-stick Pan Set both sold 1 unit — the only
> two products in that category). `RANK()` correctly gives both tied rows the same rank and
> lets `WHERE category_rank <= 2` return both, which is the merchandising-correct behavior — a
> `ROW_NUMBER()` would have arbitrarily picked a "winner" between two products that actually
> sold identically.

> **Cross-reference:** `Electronics` (category 1) and `Fashion` (category 4) never appear in
> this report because every product in the seed data is assigned directly to a *leaf* category
> (2, 3, 5, 6, or 7) — the self-referencing `categories.parent_category_id` column exists
> precisely so a full category-tree rollup (including parent totals) can be built with the
> recursive `CTE` pattern from Chapter 9. That rollup is a good self-study extension of this
> report.

#### 3.7.2 Customer lifetime value, ranked (FR7)

```sql
WITH customer_orders AS (
    SELECT
        u.user_id,
        u.full_name,
        COUNT(DISTINCT o.order_id) AS total_orders,
        COALESCE(SUM(pay.amount) FILTER (WHERE pay.status = 'SUCCESS'), 0) AS lifetime_value
    FROM users u
    JOIN orders o           ON o.user_id  = u.user_id
    LEFT JOIN payments pay  ON pay.order_id = o.order_id
    GROUP BY u.user_id, u.full_name
)
SELECT *,
       RANK() OVER (ORDER BY lifetime_value DESC) AS ltv_rank
FROM customer_orders
ORDER BY ltv_rank, full_name;
```

| full_name | total_orders | lifetime_value | ltv_rank |
|---|---|---|---|
| Arjun Kumar | 3 | 185496.00 | 1 |
| Farhan Ali | 1 | 93498.00 | 2 |
| Imran Sheikh | 1 | 75798.00 | 3 |
| Sara Patel | 1 | 4097.00 | 4 |
| Tanya Bose | 1 | 3897.00 | 5 |
| Dev Malhotra | 1 | 3298.00 | 6 |
| Lakshmi Venkat | 1 | 0.00 | 7 |
| Nita Rao | 1 | 0.00 | 7 |

Arjun Kumar's `185496.00` is the sum of his three successful payments: order 1 (`49498.00`) +
order 3 (`89999.00`) + order 8 (`45999.00`) = `185496.00`. Lakshmi Venkat and Nita Rao tie at
`0.00` — Lakshmi's only order (7) has a `PENDING` payment (now `FAILED` after §3.5's
cancellation demo), and Nita's only order (5) has a `FAILED` payment — neither has *realized*
revenue, hence `RANK()` correctly ties them both at rank 7.

**Repeat-purchase rate:**

```sql
SELECT ROUND(
    100.0 * COUNT(*) FILTER (WHERE total_orders > 1) / COUNT(*), 2
) AS repeat_purchase_rate_pct
FROM customer_orders;
```

| repeat_purchase_rate_pct |
|---|
| 12.50 |

Only Arjun Kumar has placed more than one order (3 of the 8 customers who have ordered at
all), so `1 / 8 = 12.5%`.

#### 3.7.3 Month-over-month order volume & value (FR11)

```sql
WITH monthly AS (
    SELECT
        date_trunc('month', order_date)::date AS order_month,
        COUNT(*)          AS order_count,
        SUM(total_amount) AS gross_order_value
    FROM orders
    GROUP BY 1
)
SELECT
    order_month,
    order_count,
    gross_order_value,
    LAG(gross_order_value) OVER (ORDER BY order_month) AS prev_month_value,
    ROUND(
        100.0 * (gross_order_value - LAG(gross_order_value) OVER (ORDER BY order_month))
        / LAG(gross_order_value) OVER (ORDER BY order_month),
    2) AS mom_growth_pct
FROM monthly
ORDER BY order_month;
```

| order_month | order_count | gross_order_value | prev_month_value | mom_growth_pct |
|---|---|---|---|---|
| 2024-01-01 | 5 | 177891.00 | *(NULL)* | *(NULL)* |
| 2024-02-01 | 5 | 226190.00 | 177891.00 | 27.15 |

January's `177891.00` = orders 1–5's `total_amount` (`49498 + 5097 + 89999 + 3298 + 29999`,
including the cancelled order 5's item total, since `total_amount` reflects line items
regardless of order status — see the note below). February's `226190.00` = orders 6–10
(`75798 + 6998 + 45999 + 93498 + 3897`). Growth: `(226190 - 177891) / 177891 × 100 = 27.15%`.

> **Important Note:** This report uses **gross order value** (`total_amount`, independent of
> order/payment status) rather than *recognized revenue* (successful payments only) — they are
> different business metrics answering different questions. `SUM(total_amount)` answers "how
> much merchandise value moved through checkout," while the LTV report in §3.7.2 deliberately
> filters to `payments.status = 'SUCCESS'` to answer "how much money did we actually collect."
> Conflating the two is a common real-world reporting bug — always be explicit about which one
> a dashboard is showing. With only two months of history in this seed data, treat this report
> as a template: the same query scales unchanged to years of real order history.

#### 3.7.4 Reconciling `total_amount` against `payments` (FR12)

```sql
SELECT
    o.order_id,
    o.total_amount AS items_total,
    pay.amount     AS payment_amount,
    o.total_amount - pay.amount AS diff
FROM orders o
JOIN payments pay USING (order_id)
WHERE o.total_amount <> pay.amount;
```

| order_id | items_total | payment_amount | diff |
|---|---|---|---|
| 2 | 5097.00 | 4097.00 | 1000.00 |

This single query is the payoff of building `total_amount` as an independently, reliably
maintained column (§3.2/FR4): it finds the exact anomaly flagged in §3.1 — order 2's recorded
payment is `1000.00` short of what its line items add up to — automatically, in one scan,
instead of requiring a human to notice it. In production this query would run as a nightly
integrity check.

### 3.8 Product search (FR9)

```sql
SELECT product_id, product_name, price
FROM products
WHERE LOWER(product_name) LIKE '%' || LOWER('book') || '%'
ORDER BY price;
```

| product_id | product_name | price |
|---|---|---|
| 4 | GameBook 15 | 74999.00 |
| 3 | UltraBook Pro 14 | 89999.00 |

Both matches come from the substring `"Book"` appearing mid-word ("Game**Book**", "Ultra
**Book**") — a case-sensitive `LIKE '%Book%'` would also match these two by coincidence (both
happen to capitalize "Book"), but `LOWER(product_name) LIKE LOWER('%pro%')` demonstrates the
case-insensitivity requirement more clearly, matching `UltraBook Pro 14` regardless of how the
search term is capitalized by the user (`'PRO'`, `'Pro'`, `'pro'` all match identically).

> **Cross-reference:** For genuinely large catalogs, PostgreSQL's full-text search
> (`to_tsvector`/`to_tsquery`, `tsvector` columns, GIN indexes) from Chapter 25 is the correct
> tool — it handles stemming, ranking, and multi-word relevance in ways `LIKE` cannot. For a
> 10-row catalog, a `LOWER(...) LIKE` pattern backed by the expression index in §3.9 is simpler
> and entirely sufficient; the migration path to full-text search when the catalog grows is a
> good extension exercise (§5).

### 3.9 Index design (FR10)

Five indexes, chosen for the five query patterns this project actually runs most:

| # | Query pattern | Index | Why this shape |
|---|---|---|---|
| 1 | "Show this customer's order history" (`WHERE user_id = ?`) | `CREATE INDEX idx_orders_user_id ON orders(user_id);` | `orders.user_id` is a foreign key, and **PostgreSQL does not automatically index foreign key columns** (unlike the referenced primary key side). `user_id` has high selectivity relative to `orders` (8 distinct users), making an index scan far cheaper than a seq scan once the table has thousands of rows. |
| 2 | "List orders awaiting payment/fulfillment, oldest first" (`WHERE status = 'PENDING' ORDER BY order_date`) | `CREATE INDEX idx_orders_pending ON orders(order_date) WHERE status = 'PENDING';` | A **partial index** — `status = 'PENDING'` is a small, operationally "hot" sliver of the table (in this seed data, 1 of 10 rows; in production, still a small minority once orders move through their lifecycle). Indexing only those rows keeps the index tiny and cheap to maintain on every `INSERT`, while making the one query that scans exactly this slice essentially free. |
| 3 | "Find products whose name contains X, case-insensitively" (`WHERE LOWER(product_name) LIKE ...`) | `CREATE INDEX idx_products_name_lower ON products (LOWER(product_name));` | An **expression index**. A plain index on `product_name` cannot be used by a predicate wrapped in `LOWER(...)` — the planner needs an index built on the *exact expression* in the `WHERE` clause. Building the index on `LOWER(product_name)` lets an equality or prefix search on the lowercased value use an index scan instead of a seq scan. (Note: a leading-wildcard `LIKE '%book%'` still can't use a plain B-tree even with this expression index — see the warning below — but `LIKE 'ultrabook%'` or an exact `LOWER(product_name) = 'ultrabook pro 14'` can.) |
| 4 | "Browse a category, sorted/filtered by price" (`WHERE category_id = ? [AND price BETWEEN ...] ORDER BY price`) | `CREATE INDEX idx_products_category_price ON products(category_id, price);` | A **composite index** with `category_id` first because it's the equality predicate (highest selectivity gain per the leftmost-column rule from Ch16) and `price` second because it's the range/sort column — this single index can satisfy the `WHERE category_id = ?` filter *and* return rows already in `price` order, avoiding a separate sort step. |
| 5 | "Which orders contain this product" / best-seller aggregation (`WHERE product_id = ?`, `GROUP BY product_id`) | `CREATE INDEX idx_order_items_product_id ON order_items(product_id);` | Like `orders.user_id`, `order_items.product_id` is an unindexed foreign key that both the reorder/best-seller reports (§3.7.1) and any "show me every order containing product X" admin lookup filter or group on. |

```sql
CREATE INDEX idx_orders_user_id          ON orders(user_id);
CREATE INDEX idx_orders_pending          ON orders(order_date) WHERE status = 'PENDING';
CREATE INDEX idx_products_name_lower     ON products (LOWER(product_name));
CREATE INDEX idx_products_category_price ON products(category_id, price);
CREATE INDEX idx_order_items_product_id  ON order_items(product_id);
```

**Illustrative `EXPLAIN` reasoning.** As in Chapter 16: on this seed data's actual row counts
(10 products, 10 orders, 15 order_items), PostgreSQL's planner will honestly still choose a
**Seq Scan** for most of these queries — a sequential scan of 10–15 rows is *cheaper* than the
overhead of an index lookup, and that's the *correct* choice, not a sign the index is useless.
The value of each index becomes visible once the table holds thousands to millions of rows
(exactly as demonstrated against `analytics_db.sales_fact` in Chapter 16). Conceptually, for
`idx_orders_user_id` at production scale:

```
-- Without the index (illustrative, at scale — e.g. 5,000,000 orders):
EXPLAIN SELECT * FROM orders WHERE user_id = 1;
 Seq Scan on orders  (cost=0.00..97853.00 rows=612 width=72)
   Filter: (user_id = 1)
-- reads every page of the table to find the ~612 matching rows

-- With idx_orders_user_id:
EXPLAIN SELECT * FROM orders WHERE user_id = 1;
 Index Scan using idx_orders_user_id on orders  (cost=0.42..1024.10 rows=612 width=72)
   Index Cond: (user_id = 1)
-- walks a small B-tree straight to the matching rows, skipping everything else
```

The same reasoning applies to `idx_products_category_price`: without it, `WHERE category_id =
2 ORDER BY price` at scale requires a full scan plus an explicit `Sort` node; with the
composite index, the planner can do an `Index Scan` that returns rows already sorted by
`price`, eliminating the `Sort` node entirely — visible in a real `EXPLAIN` as the absence of a
`Sort` step above the scan.

> **⚠️ Warning:** A B-tree index — including the expression index in row 3 — **cannot**
> accelerate a `LIKE '%pattern%'` search where the wildcard is at the *start* of the string,
> because B-trees are ordered structures and a leading wildcard gives the planner no prefix to
> seek to. `LIKE 'pattern%'` (no leading `%`) *can* use a B-tree. For genuine substring search
> at scale, use the `pg_trgm` extension's trigram `GIN`/`GiST` index, or PostgreSQL full-text
> search (Ch25) — both are purpose-built for exactly this case.

### 3.10 Low-stock / reorder report (FR8)

```sql
SELECT
    p.product_id,
    p.product_name,
    i.warehouse_location,
    i.quantity_on_hand,
    i.reorder_level,
    (i.reorder_level - i.quantity_on_hand) AS units_needed
FROM inventory i
JOIN products p ON p.product_id = i.product_id
WHERE i.quantity_on_hand <= i.reorder_level
ORDER BY units_needed DESC;
```

**Before** the `cancel_order(7)` demonstration in §3.5:

| product_name | warehouse_location | quantity_on_hand | reorder_level | units_needed |
|---|---|---|---|---|
| Wireless Earbuds | Mumbai-WH1 | 0 | 25 | 25 |
| GameBook 15 | Pune-WH1 | 3 | 5 | 2 |

**After** `CALL cancel_order(7);` restores 2 units of Wireless Earbuds:

| product_name | warehouse_location | quantity_on_hand | reorder_level | units_needed |
|---|---|---|---|---|
| Wireless Earbuds | Mumbai-WH1 | 2 | 25 | 23 |
| GameBook 15 | Pune-WH1 | 3 | 5 | 2 |

Both rows remain flagged (still `quantity_on_hand <= reorder_level`), but the report correctly
reflects the improved position for Wireless Earbuds — a nice end-to-end confirmation that
`place_order`, `cancel_order`, and this report are all reading from the same consistent
inventory state.

> **Cross-reference:** Every other product/warehouse combination in the seed data has
> `quantity_on_hand` comfortably above its `reorder_level` (e.g., Pixel Lite: 60 vs. 15;
> Men Cotton Shirt: 200 vs. 30) — only these two rows qualify, which is exactly what you'd
> expect from a healthy catalog where only a couple of SKUs need operator attention at any
> given time.

---

## 4. Things to Extend

These are deliberately left unsolved — good self-study exercises once you're comfortable with
everything above.

1. **Coupon / discount system.** Add a `coupons` table (`code`, `discount_type`
   `PERCENT`/`FIXED`, `discount_value`, `valid_from`, `valid_until`, `max_redemptions`,
   `times_redeemed`) and extend `place_order` to accept an optional coupon code, validate its
   validity window and remaining redemptions, and apply the discount to `total_amount` — think
   carefully about whether the discount should be stored as a separate column
   (`orders.discount_amount`) rather than folded invisibly into `total_amount`.
2. **Wishlist feature.** Design a many-to-many `user_wishlist(user_id, product_id, added_at)`
   junction table and the queries to add/remove/list items, plus a report on "most-wishlisted
   products that are out of stock" — a natural merchandising signal.
3. **Return / refund workflow.** `cancel_order` only handles `PENDING`/`PAID` orders. Design a
   separate `returns` table and workflow for `SHIPPED`/`DELIVERED` orders — partial-item
   returns, a restocking-fee concept, and inventory that goes back to a "quarantine" location
   rather than directly to sellable stock.
4. **Multi-warehouse fulfillment optimization.** `place_order` currently requires the caller to
   specify `warehouse_location` per line item. Design logic that instead picks the
   *nearest-to-shipping-address* or *least-depleted* warehouse automatically when a product is
   stocked in more than one location (recall `product_id = 1`).
5. **Full-text product search.** Replace/augment §3.8's `LIKE`-based search with a proper
   `tsvector` column, a `GIN` index, and `ts_rank` relevance ordering across `product_name`
   and a new `description` column — and compare its behavior/index size against the `pg_trgm`
   trigram approach mentioned in §3.9's warning.
6. **Category-tree rollups.** Using the recursive CTE pattern from Chapter 9 and the
   self-referencing `categories.parent_category_id` column, extend §3.7.1's best-sellers
   report so that top-level categories (Electronics, Fashion) show the *rolled-up* sales of
   all their child categories' products.

---

## 5. What You Practiced

| Concept | Where in this project | Course chapter |
|---|---|---|
| Transactions, all-or-nothing atomicity | `place_order`, `cancel_order` | Ch11 — Transactions & ACID |
| `SELECT ... FOR UPDATE`, row locking, the "last item in stock" race | §3.3, §3.4 | Ch12 — Locks & Concurrency |
| `CHECK` constraints reused from the base schema (order/payment status) | throughout | Ch13 — Constraints |
| Materialized views + refresh strategy trade-offs | `mv_product_ratings`, §3.6 | Ch15 — Views & Materialized Views |
| Index selection: single-column, composite, partial, expression | §3.9 | Ch16 — Indexes |
| Reading/reasoning about query plans, Seq Scan vs. Index Scan | §3.9 | Ch17 — Query Execution & the Query Planner |
| Denormalization for read performance, and the cost of keeping it correct | `orders.total_amount` | Ch18 — Performance Optimization |
| Writing `PROCEDURE`s with `IN`/`INOUT` parameters and exception handling | `place_order`, `cancel_order` | Ch19 — Stored Procedures |
| `AFTER ... FOR EACH ROW` triggers maintaining a denormalized column | `fn_update_order_total` | Ch22 — Triggers |
| `JSONB` input parsing (`jsonb_array_elements`) for a variable-length order | `place_order`'s `p_items` | Ch25 — Advanced Data Types |
| `LOWER()`, `LIKE`, case-insensitive/pattern search, and its indexing limits | §3.8, §3.9 | Ch5 — Functions; Ch25 — Advanced Data Types |
| Window functions: `RANK()`, ties, partitioned Top-N, `LAG()` for trend deltas | §3.7.1–§3.7.3 | Ch10 — Window Functions |
| `CTE`s structuring multi-stage analytical queries | §3.7.1, §3.7.2, §3.7.3 | Ch9 — CTEs |
| Schema migrations: additive `ALTER TABLE`, safe backfill, `NOT NULL` after backfill | §3.1, §3.2 | Ch13/Ch14/Ch22 (design & constraints in practice) |
| Data-integrity reconciliation between independently captured facts | §3.7.4 | FR4/FR12, tying back to Ch11 (why atomicity matters) |

You now have a working, concurrency-safe checkout path, a self-maintaining denormalized total,
a materialized aggregate with a real refresh strategy, three genuinely different analytical
report shapes, a justified index set, and a reproducible demonstration of the exact
overselling bug that locking exists to prevent — all against real, verifiable numbers from
`ecommerce_db`'s seed data.
