# Chapter 35 — Capstone Challenge: NorthStar Retail & Logistics Platform

> This is the final, hardest deliverable in the SQL Mastery course. It is
> designed to force the synthesis of nearly every chapter: schema design and
> normalization (Ch 14), constraints (Ch 13), indexes and the planner
> (Ch 16-18), transactions and locking (Ch 11-12), procedures/functions/cursors
> (Ch 19-21), triggers and dynamic SQL safety (Ch 22-23), advanced types
> (Ch 25), partitioning (Ch 26), security/RLS (Ch 27), and the advanced
> patterns of Ch 31 (recursive hierarchies, window functions, upserts).
>
> Work Part 1 yourself before reading Part 2. Part 2 is a complete,
> defensible reference solution — not the only correct one, but every design
> decision in it is justified.

---

## Part 1 — Requirements (Project Brief)

### 1.1 Business context

**NorthStar** is a mid-size retail company that sells physical products
directly to consumers, fulfills orders out of its own regional warehouses,
ships via third-party carriers, and runs a points-based customer loyalty
program. You have been hired as the senior database engineer to design and
build the operational database that will power order management,
fulfillment, shipment tracking, and loyalty accounting.

Production scale: NorthStar processes on the order of **2-5 million shipment
tracking scan events per year** (every package generates 6-12 scan events
between creation and delivery) and tens of thousands of orders per month.
For this exercise you will not load millions of rows, but your schema,
partitioning strategy, and indexing **must be designed as if it will grow to
that scale**, and your seed data must be generated with **set-based
`generate_series`-style seeding** (no row-by-row `INSERT` scripts) at a
volume large enough (a few thousand rows in the highest-volume table) to make
index/partition-pruning behavior observable and to make a naive query
noticeably more expensive than an optimized one.

### 1.2 Required data model shape

Your schema must include, at minimum:

1. **15 or more tables** with genuinely complex relationships — this is not
   satisfied by 15 flat, independent tables.
2. At least one **one-to-one** relationship (with a real business reason for
   splitting it into two tables, not just for the sake of the requirement).
3. Multiple **one-to-many** relationships (order → line items, customer →
   addresses, etc.).
4. At least two **many-to-many** relationships, at least one of which carries
   its own attributes (i.e., is a proper associative/bridge entity, not a
   pure join table).
5. At least one **self-referencing hierarchy** (e.g., an employee/manager
   org chart, or a category tree) that is deep enough to require a
   **recursive CTE** to traverse (3+ levels).
6. At least one **high-volume, fact-style table** (append-mostly,
   time-stamped, referenced by a foreign key from a "parent" entity) that is
   the natural candidate for **range partitioning** and that realistically
   would reach tens of millions of rows in production.

### 1.3 Functional requirements (stakeholder user stories)

> These are written the way a product manager would actually hand them to
> you — some are vague on purpose. Part of the exercise is turning them into
> precise schema and query design decisions.

| # | Stakeholder | User story |
|---|---|---|
| FR-1 | VP of Operations | "When a customer places an order, we must never sell inventory we don't have — even if two customers check out for the last unit of a product at the exact same millisecond." |
| FR-2 | Finance | "Every change to an order, a payment, or inventory must be traceable — who changed it, when, and what the row looked like before and after — for audit and chargeback disputes." |
| FR-3 | Warehouse Ops Manager | "I need to see the full reporting chain / org chart for any warehouse employee, and a headcount rollup per manager, no matter how deep the management chain gets." |
| FR-4 | Loyalty Program Lead | "Every completed order should earn loyalty points, and a customer's tier (Bronze/Silver/Gold/Platinum) must update automatically as their points balance crosses tier thresholds — without ever letting the points balance go negative." |
| FR-5 | Customer Support | "Support agents should only be able to see and modify orders/shipments for the warehouse they are assigned to — not the whole company's data." |
| FR-6 | Data/BI Team | "We need a quarterly warehouse performance report: revenue, top 3 products, average delivery time, and the share of orders coming from our top-spending customers — and it has to run fast even as shipment tracking data grows into the millions." |
| FR-7 | Fulfillment Manager | "When a shipment is marked delivered, or when it logs an exception (damaged, lost, returned), downstream systems and staff need to know immediately and reliably — this must not depend on a batch job running later." |
| FR-8 | Payments Team | "Recording a payment and updating the order's status must be all-or-nothing. If anything fails partway through, nothing should be left half-applied, and the failure must be logged with enough detail to investigate later." |
| FR-9 | Loyalty Program Lead | "Once a month we recompute every loyalty account's tier in a batch job. A handful of accounts have bad/legacy data and will error out — one bad account must not stop the other thousands from being processed, and every failure must be recorded individually." |
| FR-10 | Executive Reporting | "I want to see monthly revenue per warehouse with a running year-to-date total and a trailing 3-month moving average, plus which customers are our top spenders per region." |

### 1.4 Technical requirements this schema/solution must force

- [ ] **Stored procedures** (`CREATE PROCEDURE`) — at least 3, each with
      input validation, explicit transaction control, row locking where
      concurrency correctness matters, and structured exception handling
      that writes a failure record to the audit trail.
- [ ] **Functions** (`CREATE FUNCTION`) — at least 2, each correctly labeled
      `IMMUTABLE`, `STABLE`, or `VOLATILE`.
- [ ] **A defensible cursor** — FR-9 (partial-failure-tolerant batch
      processing) is a legitimate cursor use case because a single set-based
      `UPDATE` cannot skip-and-log individual row failures. You must also
      demonstrate the **anti-pattern**: a naive row-by-row cursor solving a
      problem that has a correct, faster set-based rewrite — and explain why
      the set-based version wins.
- [ ] **Triggers** — at least 2: one generic **audit-logging trigger**
      capturing `OLD`/`NEW` as JSONB (FR-2), and at least one more that
      either maintains a denormalized aggregate (FR-4's points balance) or
      enforces a validation rule that a `CHECK` constraint cannot express.
- [ ] **Transactions with explicit isolation/locking** — FR-1 and FR-8 must
      be solved with real `SELECT ... FOR UPDATE` row locking and a stated
      isolation level, not "hope the app layer handles it."
- [ ] **CTEs and recursive CTEs** — FR-3 requires a recursive CTE over a
      self-referencing table.
- [ ] **Window functions** — at least 3 distinct analytical reports (FR-6,
      FR-10) using ranking, running totals/moving averages, and
      lag/lead-style comparisons.
- [ ] **Indexes** — composite, partial, and expression indexes, each tied to
      a specific requirement above (not "just in case" indexes).
- [ ] **A deliberately hard-to-optimize report** (FR-6) that naturally wants
      to do a correlated subquery per customer and a full scan of the
      high-volume fact table, and must be rewritten to be fast.
- [ ] **Partitioning** of the high-volume table (FR-6, FR-7) — range
      partitioned, 2-3 real partitions plus a catch-all, with a query shown
      to prune partitions.
- [ ] **Security** — role-based access control with least-privilege GRANTs,
      plus **row-level security** enforcing FR-5.
- [ ] **Audit logging with JSONB before/after snapshots** (FR-2).

### 1.5 Non-functional requirements

- **Concurrency correctness:** Under concurrent load, it must be
  impossible to oversell inventory (two transactions decrementing the same
  last unit must not both succeed) and impossible to double-apply a payment
  to an order. This must be demonstrated with real locking, not just
  assumed.
- **Audit trail completeness:** Every `INSERT`/`UPDATE`/`DELETE` on
  financially sensitive tables (`orders`, `payments`, `inventory`) must
  produce an audit row with both the before and after image, even when the
  change originates from a trigger-driven cascade, not just direct
  application writes.
- **Performance target:** The FR-6 quarterly warehouse performance report
  must execute in **under 500ms** against a `shipment_events` table sized
  for 5 million rows (simulated here at reduced scale, but the indexing and
  partitioning strategy must be one that holds at that size), verified by
  `EXPLAIN (ANALYZE, BUFFERS)` showing partition pruning and index usage
  rather than sequential scans of the fact table.
- **Data integrity under partial failure:** The FR-9 batch tier
  recalculation must guarantee that a failure on account N does not roll
  back successful work already committed for accounts 1..N-1, and every
  failure is individually attributable.

---

## Part 2 — Complete Reference Solution

Domain chosen: **NorthStar Retail & Logistics Platform** — a single coherent
system combining e-commerce order management, multi-warehouse inventory,
third-party-carrier shipment tracking, and a points-based loyalty program.
Schema name: `northstar`. **20 tables.**

### 2.1 Entity-Relationship Diagram

```
                                   ┌───────────────┐
                                   │   regions     │◄───────────┐ self-ref
                                   │ (hierarchy)   │─────────────┘ (parent_region_id)
                                   └───────┬───────┘
                     ┌─────────────────────┼───────────────────────┐
                     │1:N                  │1:N                    │1:N
                     ▼                     ▼                       ▼
              ┌─────────────┐       ┌─────────────┐        ┌───────────────────┐
              │ warehouses  │       │ suppliers   │        │ customer_addresses │
              └──────┬──────┘       └──────┬──────┘        └─────────┬──────────┘
                1:N   │  1:N               │1:N                      │N:1
       ┌──────────────┼───────┐            ▼                         ▼
       ▼               ▼      ▼      ┌───────────┐            ┌────────────┐
┌────────────┐  ┌────────────┐│      │ products  │            │ customers  │
│ employees  │  │ inventory  ││      └─────┬─────┘            └──────┬─────┘
│(self-ref:  │  │(bridge:    ││ M:N        │ M:N                     │
│ manager_id)│  │ product x  │└───────────►│◄──────────┐        1:1  │  1:N
└─────┬──────┘  │ warehouse) │       ┌─────┴──────┐     │       ┌────┴──────────┐
      │self-ref  └────────────┘      │product_    │     │       │loyalty_       │
      └──────────────┐               │categories  │     │       │accounts       │
                      │(1:N to self) └─────┬──────┘     │       └──────┬────────┘
                      ▼                    ▼            │              │1:N
              (reports to)          ┌────────────┐      │              ▼
                                    │ categories │      │       ┌───────────────┐
                                    │(self-ref)  │      │       │loyalty_tiers  │
                                    └────────────┘      │       └───────────────┘
                                                          │
   ┌─────────────┐   1:N    ┌───────────┐   N:1  ┌───────┴────┐
   │  customers  ├─────────►│  orders   │◄────────┤ employees  │ (handled_by, optional)
   └─────────────┘          └─────┬─────┘         └────────────┘
                                   │1:N        1:N│         1:N│
                        ┌──────────┼──────────────┼────────────┼───────────┐
                        ▼          ▼               ▼            ▼
                 ┌────────────┐ ┌──────────┐ ┌───────────┐ ┌───────────────┐
                 │order_items │ │ payments │ │ shipments │ │ loyalty_ledger│
                 └─────┬──────┘ └──────────┘ └─────┬─────┘ └───────────────┘
                       │N:1                    1:N │     N:1        N:1
                       ▼                            ▼      ▲          ▲
                 ┌───────────┐              ┌────────────────┐   ┌─────────┐
                 │  products │              │ shipment_events │   │carriers │
                 └───────────┘              │ (PARTITIONED,   │   └─────────┘
                                             │  high-volume)   │
                                             └────────────────┘

                                 ┌───────────────────────┐
                                 │      audit_log         │  (referenced logically
                                 │ (table_name, record_id,│   from every trigger;
                                 │  action, old/new JSONB)│   no FK — polymorphic)
                                 └───────────────────────┘
```

**Cardinality summary**

| Relationship | Type |
|---|---|
| `regions` → `regions` | 1:N self-referencing hierarchy |
| `categories` → `categories` | 1:N self-referencing hierarchy |
| `employees` → `employees` | 1:N self-referencing hierarchy (org chart) |
| `regions` → `warehouses`, `suppliers`, `customer_addresses` | 1:N |
| `warehouses` → `employees`, `inventory`, `orders`, `shipments` | 1:N |
| `suppliers` → `products` | 1:N |
| `products` ↔ `categories` (`product_categories`) | M:N (pure bridge) |
| `products` ↔ `warehouses` (`inventory`) | M:N with attributes (qty, reorder threshold) |
| `customers` → `customer_addresses`, `orders`, `loyalty_ledger` (via account) | 1:N |
| `customers` → `loyalty_accounts` | **1:1** |
| `loyalty_tiers` → `loyalty_accounts` | 1:N |
| `loyalty_accounts` → `loyalty_ledger` | 1:N |
| `orders` → `order_items`, `payments`, `shipments`, `loyalty_ledger` | 1:N |
| `orders` → `products` (via `order_items`) | M:N with attributes (qty, unit price) |
| `shipments` → `shipment_events` | 1:N (high-volume, partitioned) |
| `carriers` → `shipments` | 1:N |
| `employees` → `orders` | 1:N (handled_by, nullable) |

### 2.2 DDL

> **Design note:** `record_id` in `audit_log` is `TEXT`, not a typed FK,
> because the audit table is intentionally polymorphic (one table logs
> changes from many source tables) — this is a deliberate denormalization,
> not an oversight; see §2.9.

```sql
-- ============================================================================
-- NorthStar Retail & Logistics Platform — Capstone reference schema
-- Dialect: PostgreSQL 15+
-- ============================================================================

DROP SCHEMA IF EXISTS northstar CASCADE;
CREATE SCHEMA northstar;
SET search_path TO northstar;

-- ----------------------------------------------------------------------------
-- regions — self-referencing geographic hierarchy (country -> state -> city)
-- ----------------------------------------------------------------------------
CREATE TABLE regions (
    region_id        SERIAL PRIMARY KEY,
    region_code      VARCHAR(10)  NOT NULL UNIQUE,
    region_name      VARCHAR(100) NOT NULL,
    region_type      VARCHAR(20)  NOT NULL
                        CHECK (region_type IN ('COUNTRY','STATE','CITY')),
    parent_region_id INT REFERENCES regions(region_id),
    created_at       TIMESTAMP NOT NULL DEFAULT now(),
    -- a COUNTRY must not have a parent; STATE/CITY must
    CONSTRAINT chk_region_parent CHECK (
        (region_type = 'COUNTRY' AND parent_region_id IS NULL) OR
        (region_type <> 'COUNTRY' AND parent_region_id IS NOT NULL)
    )
);

-- ----------------------------------------------------------------------------
-- carriers — third-party shipping carriers
-- ----------------------------------------------------------------------------
CREATE TABLE carriers (
    carrier_id            SERIAL PRIMARY KEY,
    carrier_code          VARCHAR(10)  NOT NULL UNIQUE,
    carrier_name          VARCHAR(100) NOT NULL,
    tracking_url_template TEXT,
    is_active             BOOLEAN NOT NULL DEFAULT TRUE
);

-- ----------------------------------------------------------------------------
-- warehouses
-- ----------------------------------------------------------------------------
CREATE TABLE warehouses (
    warehouse_id   SERIAL PRIMARY KEY,
    warehouse_code VARCHAR(10)  NOT NULL UNIQUE,
    warehouse_name VARCHAR(100) NOT NULL,
    region_id      INT NOT NULL REFERENCES regions(region_id),
    capacity_units INT NOT NULL CHECK (capacity_units > 0),
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- suppliers
-- ----------------------------------------------------------------------------
CREATE TABLE suppliers (
    supplier_id   SERIAL PRIMARY KEY,
    supplier_name VARCHAR(150) NOT NULL,
    region_id     INT REFERENCES regions(region_id),
    contact_email VARCHAR(150) UNIQUE,
    rating        NUMERIC(2,1) CHECK (rating BETWEEN 0 AND 5),
    created_at    TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- employees — self-referencing org chart (FR-3's recursive-CTE table)
-- ----------------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    first_name   VARCHAR(50)  NOT NULL,
    last_name    VARCHAR(50)  NOT NULL,
    email        VARCHAR(150) NOT NULL UNIQUE,
    job_title    VARCHAR(100) NOT NULL,
    manager_id   INT REFERENCES employees(employee_id),
    warehouse_id INT REFERENCES warehouses(warehouse_id),
    hire_date    DATE NOT NULL,
    status       VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','ON_LEAVE','TERMINATED')),
    -- an employee cannot be their own manager
    CONSTRAINT chk_not_own_manager CHECK (employee_id <> manager_id)
);

-- ----------------------------------------------------------------------------
-- categories — self-referencing product category tree
-- ----------------------------------------------------------------------------
CREATE TABLE categories (
    category_id        SERIAL PRIMARY KEY,
    category_name      VARCHAR(100) NOT NULL,
    parent_category_id INT REFERENCES categories(category_id),
    created_at         TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- products
-- ----------------------------------------------------------------------------
CREATE TABLE products (
    product_id      SERIAL PRIMARY KEY,
    sku             VARCHAR(30)  NOT NULL UNIQUE,
    product_name    VARCHAR(150) NOT NULL,
    supplier_id     INT NOT NULL REFERENCES suppliers(supplier_id),
    unit_price      NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    weight_kg       NUMERIC(6,2) CHECK (weight_kg > 0),
    is_discontinued BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- product_categories — pure M:N bridge (no attributes of its own)
-- ----------------------------------------------------------------------------
CREATE TABLE product_categories (
    product_id  INT NOT NULL REFERENCES products(product_id)   ON DELETE CASCADE,
    category_id INT NOT NULL REFERENCES categories(category_id) ON DELETE CASCADE,
    PRIMARY KEY (product_id, category_id)
);

-- ----------------------------------------------------------------------------
-- inventory — M:N bridge WITH attributes (product x warehouse stock levels)
-- ----------------------------------------------------------------------------
CREATE TABLE inventory (
    inventory_id      SERIAL PRIMARY KEY,
    product_id        INT NOT NULL REFERENCES products(product_id),
    warehouse_id      INT NOT NULL REFERENCES warehouses(warehouse_id),
    quantity_on_hand  INT NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
    reorder_threshold INT NOT NULL DEFAULT 10 CHECK (reorder_threshold >= 0),
    updated_at        TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (product_id, warehouse_id)
);

-- ----------------------------------------------------------------------------
-- customers
-- ----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  SERIAL PRIMARY KEY,
    email        VARCHAR(150) NOT NULL UNIQUE,
    first_name   VARCHAR(50)  NOT NULL,
    last_name    VARCHAR(50)  NOT NULL,
    phone        VARCHAR(20),
    signup_date  DATE NOT NULL DEFAULT CURRENT_DATE,
    status       VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED'))
);

-- ----------------------------------------------------------------------------
-- customer_addresses — 1:N (a customer can have many shipping addresses)
-- ----------------------------------------------------------------------------
CREATE TABLE customer_addresses (
    address_id   SERIAL PRIMARY KEY,
    customer_id  INT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    region_id    INT NOT NULL REFERENCES regions(region_id),
    line1        VARCHAR(150) NOT NULL,
    line2        VARCHAR(150),
    postal_code  VARCHAR(20)  NOT NULL,
    is_default   BOOLEAN NOT NULL DEFAULT FALSE
);

-- ----------------------------------------------------------------------------
-- loyalty_tiers — reference table for the loyalty program (FR-4)
-- ----------------------------------------------------------------------------
CREATE TABLE loyalty_tiers (
    tier_id       SERIAL PRIMARY KEY,
    tier_name     VARCHAR(30) NOT NULL UNIQUE,
    min_points    INT NOT NULL UNIQUE CHECK (min_points >= 0),
    discount_pct  NUMERIC(4,2) NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100)
);

-- ----------------------------------------------------------------------------
-- loyalty_accounts — the 1:1 relationship.
-- Design note: kept as a separate table (not columns on customers) because
-- (a) most customers never enroll, so this avoids nullable-column bloat on
-- the hot `customers` table, and (b) it is written far more often (every
-- order changes points_balance) than `customers`, so separating it reduces
-- lock/row-churn contention and MVCC bloat on the customer identity table.
-- ----------------------------------------------------------------------------
CREATE TABLE loyalty_accounts (
    loyalty_account_id SERIAL PRIMARY KEY,
    customer_id        INT NOT NULL UNIQUE REFERENCES customers(customer_id) ON DELETE CASCADE,
    tier_id             INT NOT NULL REFERENCES loyalty_tiers(tier_id) DEFAULT 1,
    points_balance      INT NOT NULL DEFAULT 0 CHECK (points_balance >= 0),
    updated_at          TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- orders
-- ----------------------------------------------------------------------------
CREATE TABLE orders (
    order_id             SERIAL PRIMARY KEY,
    customer_id          INT NOT NULL REFERENCES customers(customer_id),
    shipping_address_id  INT NOT NULL REFERENCES customer_addresses(address_id),
    warehouse_id         INT NOT NULL REFERENCES warehouses(warehouse_id),
    handled_by_employee  INT REFERENCES employees(employee_id),
    order_date           TIMESTAMP NOT NULL DEFAULT now(),
    status                VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING','PAID','FULFILLING','SHIPPED',
                                               'DELIVERED','CANCELLED','REFUNDED')),
    subtotal_amount       NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (subtotal_amount >= 0),
    discount_amount       NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    total_amount          NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    created_at            TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- order_items — 1:N to orders, N:1 to products (order<->product is M:N
-- realized through this associative table, with quantity/price attributes)
-- ----------------------------------------------------------------------------
CREATE TABLE order_items (
    order_item_id BIGSERIAL PRIMARY KEY,
    order_id      INT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id    INT NOT NULL REFERENCES products(product_id),
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    line_total    NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    UNIQUE (order_id, product_id)
);

-- ----------------------------------------------------------------------------
-- payments — 1:N to orders (retries/partial refunds create multiple rows)
-- ----------------------------------------------------------------------------
CREATE TABLE payments (
    payment_id     SERIAL PRIMARY KEY,
    order_id       INT NOT NULL REFERENCES orders(order_id),
    amount         NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    payment_method VARCHAR(20) NOT NULL
                    CHECK (payment_method IN ('CREDIT_CARD','DEBIT_CARD','PAYPAL','GIFT_CARD','WALLET')),
    status         VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING','SUCCEEDED','FAILED','REFUNDED')),
    processed_at   TIMESTAMP,
    created_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- shipments — 1:N to orders (an order may ship in multiple packages)
-- ----------------------------------------------------------------------------
CREATE TABLE shipments (
    shipment_id     SERIAL PRIMARY KEY,
    order_id        INT NOT NULL REFERENCES orders(order_id),
    warehouse_id    INT NOT NULL REFERENCES warehouses(warehouse_id),
    carrier_id      INT NOT NULL REFERENCES carriers(carrier_id),
    tracking_number VARCHAR(50) UNIQUE,
    status          VARCHAR(20) NOT NULL DEFAULT 'PREPARING'
                     CHECK (status IN ('PREPARING','SHIPPED','IN_TRANSIT','DELIVERED','EXCEPTION','RETURNED')),
    shipped_at      TIMESTAMP,
    delivered_at    TIMESTAMP,
    created_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- shipment_events — HIGH-VOLUME FACT TABLE. Every tracking scan. In
-- production this grows by millions of rows/year, is append-mostly, and is
-- almost always queried by a recent time window -> textbook RANGE
-- partitioning candidate. The partition key (event_time) MUST be part of
-- the primary key in PostgreSQL declarative partitioning, so the PK here
-- is a composite (event_id, event_time) rather than event_id alone.
-- ----------------------------------------------------------------------------
CREATE TABLE shipment_events (
    event_id      BIGSERIAL,
    shipment_id   INT NOT NULL REFERENCES shipments(shipment_id),
    event_type    VARCHAR(20) NOT NULL
                    CHECK (event_type IN ('CREATED','PICKED_UP','IN_TRANSIT',
                                           'OUT_FOR_DELIVERY','DELIVERED','EXCEPTION','RETURNED')),
    event_time    TIMESTAMP NOT NULL DEFAULT now(),
    location_text VARCHAR(150),
    notes         TEXT,
    PRIMARY KEY (event_id, event_time)
) PARTITION BY RANGE (event_time);

-- Three real quarterly partitions covering the seeded data window, plus a
-- DEFAULT catch-all so inserts never fail if they land outside the planned
-- ranges (a real operational safety net, not just a teaching prop).
CREATE TABLE shipment_events_2026_q1 PARTITION OF shipment_events
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE shipment_events_2026_q2 PARTITION OF shipment_events
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE shipment_events_2026_q3 PARTITION OF shipment_events
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');
CREATE TABLE shipment_events_default PARTITION OF shipment_events DEFAULT;

-- ----------------------------------------------------------------------------
-- loyalty_ledger — 1:N to loyalty_accounts; append-only point movements.
-- ----------------------------------------------------------------------------
CREATE TABLE loyalty_ledger (
    ledger_id          BIGSERIAL PRIMARY KEY,
    loyalty_account_id INT NOT NULL REFERENCES loyalty_accounts(loyalty_account_id),
    order_id           INT REFERENCES orders(order_id) ON DELETE SET NULL,
    points_delta       INT NOT NULL,
    reason             VARCHAR(20) NOT NULL
                        CHECK (reason IN ('ORDER_EARN','REDEMPTION','ADJUSTMENT','EXPIRATION')),
    created_at         TIMESTAMP NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- audit_log — polymorphic audit trail (FR-2). record_id is TEXT on purpose:
-- this one table logs changes from many source tables with different PK
-- types/widths, and audit rows must never be blocked by a source-table FK
-- constraint (e.g., logging a DELETE after the row is already gone).
-- ----------------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id    BIGSERIAL PRIMARY KEY,
    table_name  VARCHAR(50) NOT NULL,
    record_id   TEXT NOT NULL,
    action      VARCHAR(10) NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    old_data    JSONB,
    new_data    JSONB,
    changed_by  TEXT NOT NULL DEFAULT current_user,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
```

### 2.3 Seed Data (set-based)

```sql
SET search_path TO northstar;

-- ---- Reference/dimension data (hand-written; small, meaningful) ----------
INSERT INTO regions (region_code, region_name, region_type, parent_region_id) VALUES
    ('US', 'United States', 'COUNTRY', NULL),
    ('CA', 'Canada', 'COUNTRY', NULL);
INSERT INTO regions (region_code, region_name, region_type, parent_region_id) VALUES
    ('US-CA', 'California', 'STATE', 1),
    ('US-TX', 'Texas', 'STATE', 1),
    ('US-NY', 'New York', 'STATE', 1),
    ('CA-ON', 'Ontario', 'STATE', 2);
INSERT INTO regions (region_code, region_name, region_type, parent_region_id) VALUES
    ('US-CA-LA', 'Los Angeles', 'CITY', 3),
    ('US-CA-SF', 'San Francisco', 'CITY', 3),
    ('US-TX-AUS', 'Austin', 'CITY', 4),
    ('US-NY-NYC', 'New York City', 'CITY', 5),
    ('CA-ON-TOR', 'Toronto', 'CITY', 6);

INSERT INTO carriers (carrier_code, carrier_name, tracking_url_template) VALUES
    ('UPS', 'United Parcel Service', 'https://ups.example/track/{tracking}'),
    ('FDX', 'FedEx', 'https://fedex.example/track/{tracking}'),
    ('USPS', 'US Postal Service', 'https://usps.example/track/{tracking}');

INSERT INTO warehouses (warehouse_code, warehouse_name, region_id, capacity_units) VALUES
    ('WH-LA', 'Los Angeles DC', 7, 500000),
    ('WH-AUS', 'Austin DC', 9, 350000),
    ('WH-NYC', 'New York DC', 10, 400000);

INSERT INTO suppliers (supplier_name, region_id, contact_email, rating) VALUES
    ('Pacific Components Ltd', 7, 'sales@pacificcomp.example', 4.5),
    ('Lonestar Textiles', 9, 'orders@lonestartex.example', 4.1),
    ('Atlantic Home Goods', 10, 'contact@atlantichome.example', 4.7),
    ('Northern Outfitters', 11, 'hello@northernoutfit.example', 4.3);

INSERT INTO employees (first_name, last_name, email, job_title, manager_id, warehouse_id, hire_date) VALUES
    ('Dana', 'Whitfield', 'dana.whitfield@northstar.example', 'VP of Operations', NULL, NULL, '2018-02-01');
INSERT INTO employees (first_name, last_name, email, job_title, manager_id, warehouse_id, hire_date) VALUES
    ('Marcus', 'Ibe', 'marcus.ibe@northstar.example', 'Warehouse Director', 1, 1, '2019-03-15'),
    ('Priya', 'Nadar', 'priya.nadar@northstar.example', 'Warehouse Director', 1, 2, '2019-06-01'),
    ('Owen', 'Sacks', 'owen.sacks@northstar.example', 'Warehouse Director', 1, 3, '2020-01-10');
INSERT INTO employees (first_name, last_name, email, job_title, manager_id, warehouse_id, hire_date) VALUES
    ('Lena', 'Fischer', 'lena.fischer@northstar.example', 'Fulfillment Lead', 2, 1, '2021-04-01'),
    ('Ravi', 'Kapoor', 'ravi.kapoor@northstar.example', 'Fulfillment Lead', 2, 1, '2021-07-20'),
    ('Sofia', 'Marquez', 'sofia.marquez@northstar.example', 'Fulfillment Lead', 3, 2, '2021-09-05'),
    ('Tom', 'Bergstrom', 'tom.bergstrom@northstar.example', 'Fulfillment Lead', 4, 3, '2022-02-14');
INSERT INTO employees (first_name, last_name, email, job_title, manager_id, warehouse_id, hire_date) VALUES
    ('Alicia', 'Grant', 'alicia.grant@northstar.example', 'Fulfillment Associate', 5, 1, '2023-01-09'),
    ('Ben', 'Ortiz', 'ben.ortiz@northstar.example', 'Fulfillment Associate', 5, 1, '2023-03-22'),
    ('Chen', 'Wu', 'chen.wu@northstar.example', 'Fulfillment Associate', 6, 1, '2023-05-11'),
    ('Deepa', 'Rao', 'deepa.rao@northstar.example', 'Fulfillment Associate', 7, 2, '2023-06-30'),
    ('Ethan', 'Cole', 'ethan.cole@northstar.example', 'Fulfillment Associate', 8, 3, '2023-08-17');

INSERT INTO categories (category_name, parent_category_id) VALUES
    ('Electronics', NULL), ('Home & Kitchen', NULL), ('Apparel', NULL);
INSERT INTO categories (category_name, parent_category_id) VALUES
    ('Audio', 1), ('Computer Accessories', 1),
    ('Cookware', 2), ('Furniture', 2),
    ('Men''s Clothing', 3), ('Women''s Clothing', 3);

INSERT INTO loyalty_tiers (tier_name, min_points, discount_pct) VALUES
    ('Bronze', 0, 0),
    ('Silver', 500, 2.5),
    ('Gold', 2000, 5.0),
    ('Platinum', 5000, 10.0);

-- ---- Products (set-based, driven from suppliers/categories) --------------
INSERT INTO products (sku, product_name, supplier_id, unit_price, weight_kg)
SELECT
    'SKU-' || LPAD(g::TEXT, 5, '0'),
    'Product ' || g,
    1 + (g % 4),
    ROUND((10 + (g % 90) + random() * 10)::NUMERIC, 2),
    ROUND((0.1 + (g % 20) * 0.3)::NUMERIC, 2)
FROM generate_series(1, 200) AS g;

INSERT INTO product_categories (product_id, category_id)
SELECT p.product_id, 4 + (p.product_id % 6)
FROM products p;
INSERT INTO product_categories (product_id, category_id)
SELECT p.product_id, 1 + (p.product_id % 3)
FROM products p
WHERE p.product_id % 2 = 0;

INSERT INTO inventory (product_id, warehouse_id, quantity_on_hand, reorder_threshold)
SELECT p.product_id, w.warehouse_id,
       20 + (p.product_id * w.warehouse_id) % 500,
       10 + (p.product_id % 20)
FROM products p CROSS JOIN warehouses w;

-- ---- Customers (set-based, a few hundred) ---------------------------------
INSERT INTO customers (email, first_name, last_name, phone, signup_date)
SELECT
    'customer' || g || '@example.com',
    'First' || g,
    'Last' || g,
    '555-01' || LPAD((g % 10000)::TEXT, 4, '0'),
    (DATE '2024-01-01' + (g % 700) * INTERVAL '1 day')::DATE
FROM generate_series(1, 600) AS g;

INSERT INTO customer_addresses (customer_id, region_id, line1, postal_code, is_default)
SELECT c.customer_id,
       6 + (c.customer_id % 5),
       (100 + c.customer_id) || ' Market St',
       LPAD((10000 + c.customer_id)::TEXT, 5, '0'),
       TRUE
FROM customers c;

INSERT INTO loyalty_accounts (customer_id, tier_id, points_balance)
SELECT customer_id, 1, 0 FROM customers;

-- ---- Orders + order_items (set-based, spread across 2026 Q1-Q3) ----------
INSERT INTO orders (customer_id, shipping_address_id, warehouse_id, handled_by_employee,
                     order_date, status, subtotal_amount, discount_amount, total_amount)
SELECT
    c.customer_id,
    a.address_id,
    1 + (g % 3),
    5 + (g % 8),
    TIMESTAMP '2026-01-01' + (g % 265) * INTERVAL '1 day' + (g % 24) * INTERVAL '1 hour',
    (ARRAY['DELIVERED','DELIVERED','DELIVERED','SHIPPED','PAID','CANCELLED'])[1 + (g % 6)],
    0, 0, 0
FROM generate_series(1, 4000) AS g
JOIN customers c ON c.customer_id = 1 + (g % 600)
JOIN customer_addresses a ON a.customer_id = c.customer_id;

INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT o.order_id,
       p.product_id,
       1 + (o.order_id % 4),
       p.unit_price
FROM orders o
JOIN products p ON p.product_id = 1 + ((o.order_id * 7 + 3) % 200);

INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT o.order_id,
       p.product_id,
       1 + (o.order_id % 2),
       p.unit_price
FROM orders o
JOIN products p ON p.product_id = 1 + ((o.order_id * 13 + 11) % 200)
WHERE o.order_id % 3 = 0
ON CONFLICT (order_id, product_id) DO NOTHING;

UPDATE orders o
SET subtotal_amount = t.sum_total,
    discount_amount = ROUND(t.sum_total * 0.02, 2),
    total_amount = ROUND(t.sum_total * 0.98, 2)
FROM (SELECT order_id, SUM(line_total) AS sum_total FROM order_items GROUP BY order_id) t
WHERE o.order_id = t.order_id;

INSERT INTO payments (order_id, amount, payment_method, status, processed_at)
SELECT order_id, total_amount,
       (ARRAY['CREDIT_CARD','DEBIT_CARD','PAYPAL','WALLET'])[1 + (order_id % 4)],
       'SUCCEEDED',
       order_date + INTERVAL '5 minutes'
FROM orders
WHERE status <> 'CANCELLED';

INSERT INTO shipments (order_id, warehouse_id, carrier_id, tracking_number, status, shipped_at, delivered_at)
SELECT o.order_id, o.warehouse_id, 1 + (o.order_id % 3),
       'TRK' || LPAD(o.order_id::TEXT, 8, '0'),
       CASE WHEN o.status = 'DELIVERED' THEN 'DELIVERED'
            WHEN o.status = 'SHIPPED' THEN 'IN_TRANSIT'
            ELSE 'PREPARING' END,
       o.order_date + INTERVAL '1 day',
       CASE WHEN o.status = 'DELIVERED' THEN o.order_date + INTERVAL '1 day' +
            ((1 + (o.order_id % 5)) || ' days')::INTERVAL ELSE NULL END
FROM orders o
WHERE o.status IN ('DELIVERED','SHIPPED','PAID');

-- ---- shipment_events — THE high-volume table: set-based generate_series --
-- Each shipment gets 3-7 scan events spread from creation to delivery/now.
INSERT INTO shipment_events (shipment_id, event_type, event_time, location_text)
SELECT s.shipment_id,
       et.event_type,
       s.shipped_at + (et.seq * INTERVAL '8 hours') + (random() * INTERVAL '3 hours'),
       (ARRAY['LA Hub','Dallas Hub','Chicago Hub','Newark Hub','Local Depot'])[1 + (et.seq % 5)]
FROM shipments s
CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
        (0, 'CREATED'), (1, 'PICKED_UP'), (2, 'IN_TRANSIT'),
        (3, 'IN_TRANSIT'), (4, 'OUT_FOR_DELIVERY'), (5, 'DELIVERED')
    ) AS v(seq, event_type)
    WHERE s.status IN ('DELIVERED') OR v.seq <= 3
) et
WHERE s.shipped_at IS NOT NULL;

-- Sprinkle a small number of EXCEPTION events (for the hard report's filter)
INSERT INTO shipment_events (shipment_id, event_type, event_time, location_text, notes)
SELECT shipment_id, 'EXCEPTION', shipped_at + INTERVAL '2 days', 'Sort Facility', 'Damaged in transit'
FROM shipments
WHERE shipment_id % 37 = 0 AND shipped_at IS NOT NULL;

-- ---- Loyalty ledger: earn 1 point per $10 spent on delivered orders ------
INSERT INTO loyalty_ledger (loyalty_account_id, order_id, points_delta, reason)
SELECT la.loyalty_account_id, o.order_id, FLOOR(o.total_amount / 10)::INT, 'ORDER_EARN'
FROM orders o
JOIN loyalty_accounts la ON la.customer_id = o.customer_id
WHERE o.status = 'DELIVERED';

-- points balance is maintained by trigger trg_loyalty_ledger_apply (see 2.9);
-- backfilling seed rows above fires it row-by-row automatically.
```

> **⚠️ Warning:** `generate_series`-based seeding as shown produces roughly
> **4,000 orders, ~6,000 order_items, ~3,000 shipments, and 12,000-18,000
> `shipment_events` rows** — enough for `EXPLAIN` plans and partition
> pruning to be observable, but far below production scale. Do not mistake
> "the demo dataset is small" for "the schema doesn't need to survive at 5M
> rows" — the indexing and partitioning design below is written for the
> production volume, not the demo volume.

### 2.4 Indexes

| Index | Definition | Requirement it satisfies |
|---|---|---|
| Composite: order lookup by customer, recent-first | `CREATE INDEX idx_orders_customer_date ON orders (customer_id, order_date DESC);` | FR-6/FR-10 lifetime-spend and per-customer order history lookups |
| Composite: warehouse reporting | `CREATE INDEX idx_orders_warehouse_date ON orders (warehouse_id, order_date);` | FR-6 quarterly warehouse report — enables index range scan instead of seq scan + filter |
| FK support | `CREATE INDEX idx_order_items_product ON order_items (product_id);` | FR-6 top-N products by revenue join |
| FK support | `CREATE INDEX idx_payments_order ON payments (order_id);` | FR-8 payment-per-order lookups under lock |
| Composite | `CREATE INDEX idx_shipments_warehouse_carrier ON shipments (warehouse_id, carrier_id);` | Carrier performance / warehouse ops dashboards |
| FK support | `CREATE INDEX idx_shipments_order ON shipments (order_id);` | Order → shipment traversal in hard report |
| Composite (local, per-partition) | `CREATE INDEX idx_shipment_events_shipment_time ON shipment_events (shipment_id, event_time);` | FR-6/FR-7 — fetch a shipment's event history in time order; automatically created on every partition |
| **Partial** | `CREATE INDEX idx_shipment_events_exceptions ON shipment_events (shipment_id) WHERE event_type = 'EXCEPTION';` | FR-6/FR-7 — exception lookups only ever filter `event_type = 'EXCEPTION'`, ~1/37th of rows; a partial index keeps this tiny and fast forever, unlike a full index on `event_type` |
| **Partial** | `CREATE INDEX idx_loyalty_accounts_nonzero ON loyalty_accounts (customer_id) WHERE points_balance > 0;` | FR-9 batch job only ever processes accounts with points; skips the (likely large) zero-balance population |
| **Partial** | `CREATE INDEX idx_orders_active ON orders (warehouse_id, order_date) WHERE status NOT IN ('CANCELLED','REFUNDED');` | FR-6 report explicitly excludes cancelled/refunded orders — partial index matches the report predicate exactly |
| **Expression** | `CREATE INDEX idx_customers_email_lower ON customers (lower(email));` | Case-insensitive login/lookup (a de facto requirement of any customer-facing auth flow) |
| **Expression** | `CREATE UNIQUE INDEX idx_products_sku_upper ON products (upper(sku));` | Guarantees SKU uniqueness independent of case entered by suppliers' catalogs |
| Hierarchy support | `CREATE INDEX idx_employees_manager ON employees (manager_id);` | FR-3 recursive CTE traversal — without this, each recursive step is a seq scan |
| Hierarchy support | `CREATE INDEX idx_categories_parent ON categories (parent_category_id);` | Category-tree traversal |
| Hierarchy support | `CREATE INDEX idx_regions_parent ON regions (parent_region_id);` | Region-tree traversal for address rollups |
| **GIN (JSONB)** | `CREATE INDEX idx_audit_log_new_data ON audit_log USING GIN (new_data jsonb_path_ops);` | FR-2 — support "find every audit row where field X changed to value Y" investigations |
| Composite unique (already declared) | `UNIQUE (product_id, warehouse_id)` on `inventory` | FR-1 — the row that `SELECT ... FOR UPDATE` locks per (product, warehouse) pair |

```sql
CREATE INDEX idx_orders_customer_date ON orders (customer_id, order_date DESC);
CREATE INDEX idx_orders_warehouse_date ON orders (warehouse_id, order_date);
CREATE INDEX idx_order_items_product ON order_items (product_id);
CREATE INDEX idx_payments_order ON payments (order_id);
CREATE INDEX idx_shipments_warehouse_carrier ON shipments (warehouse_id, carrier_id);
CREATE INDEX idx_shipments_order ON shipments (order_id);
CREATE INDEX idx_shipment_events_shipment_time ON shipment_events (shipment_id, event_time);
CREATE INDEX idx_shipment_events_exceptions ON shipment_events (shipment_id) WHERE event_type = 'EXCEPTION';
CREATE INDEX idx_loyalty_accounts_nonzero ON loyalty_accounts (customer_id) WHERE points_balance > 0;
CREATE INDEX idx_orders_active ON orders (warehouse_id, order_date) WHERE status NOT IN ('CANCELLED','REFUNDED');
CREATE INDEX idx_customers_email_lower ON customers (lower(email));
CREATE UNIQUE INDEX idx_products_sku_upper ON products (upper(sku));
CREATE INDEX idx_employees_manager ON employees (manager_id);
CREATE INDEX idx_categories_parent ON categories (parent_category_id);
CREATE INDEX idx_regions_parent ON regions (parent_region_id);
CREATE INDEX idx_audit_log_new_data ON audit_log USING GIN (new_data jsonb_path_ops);
```

> **Important:** Indexes declared on a **partitioned** table
> (`shipment_events`) are propagated automatically to every existing and
> future partition when declared on the parent — there is no need to create
> `idx_shipment_events_shipment_time` on each partition separately.

### 2.5 Roles & Security (RBAC + Row-Level Security)

```sql
-- ---- Roles (least privilege) ----------------------------------------------
CREATE ROLE ns_readonly   NOLOGIN;
CREATE ROLE ns_app_writer NOLOGIN;
CREATE ROLE ns_admin      NOLOGIN;
CREATE ROLE ns_warehouse_staff NOLOGIN;

REVOKE ALL ON SCHEMA northstar FROM PUBLIC;
GRANT USAGE ON SCHEMA northstar TO ns_readonly, ns_app_writer, ns_admin, ns_warehouse_staff;

-- Read-only reporting/BI role: SELECT everywhere, nothing else.
GRANT SELECT ON ALL TABLES IN SCHEMA northstar TO ns_readonly;

-- Application writer: normal operational CRUD, but NEVER delete audit rows
-- and NEVER touch audit_log directly (only triggers/SECURITY DEFINER
-- procedures write to it).
GRANT SELECT, INSERT, UPDATE ON
    customers, customer_addresses, orders, order_items, payments,
    shipments, shipment_events, loyalty_accounts, loyalty_ledger, inventory
TO ns_app_writer;
GRANT SELECT ON ALL TABLES IN SCHEMA northstar TO ns_app_writer;
REVOKE INSERT, UPDATE, DELETE ON audit_log FROM ns_app_writer;

-- Admin: full control, including DDL-adjacent maintenance.
GRANT ALL ON ALL TABLES IN SCHEMA northstar TO ns_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA northstar TO ns_admin, ns_app_writer;

-- Warehouse staff: FR-5 — must only see/modify orders & shipments for the
-- warehouse they are assigned to. Enforced with row-level security below.
GRANT SELECT, UPDATE ON orders, shipments TO ns_warehouse_staff;
GRANT SELECT ON warehouses, employees, inventory, products TO ns_warehouse_staff;

-- ---- Row-level security: FR-5 ---------------------------------------------
-- The app sets a session variable identifying the logged-in staff member's
-- warehouse after authenticating: SET app.current_warehouse_id = '2';
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipments ENABLE ROW LEVEL SECURITY;

CREATE POLICY orders_warehouse_isolation ON orders
    FOR ALL
    TO ns_warehouse_staff
    USING (warehouse_id = current_setting('app.current_warehouse_id', true)::INT)
    WITH CHECK (warehouse_id = current_setting('app.current_warehouse_id', true)::INT);

CREATE POLICY shipments_warehouse_isolation ON shipments
    FOR ALL
    TO ns_warehouse_staff
    USING (warehouse_id = current_setting('app.current_warehouse_id', true)::INT)
    WITH CHECK (warehouse_id = current_setting('app.current_warehouse_id', true)::INT);

-- ns_readonly and ns_admin are unaffected by RLS by default unless RLS is
-- forced; BYPASSRLS-equivalent behavior for admins:
ALTER TABLE orders FORCE ROW LEVEL SECURITY;   -- applies even to table owner
GRANT ns_admin TO CURRENT_USER;                -- (illustrative — real deploy
                                                --  scripts assign role membership
                                                --  to real login roles, not superuser)
```

```sql
-- Usage from the application connection pool, per request, after auth:
SET app.current_warehouse_id = '2';
SELECT * FROM orders;  -- only warehouse 2's orders are visible/updatable
```

> **⚠️ Warning:** `current_setting('app.current_warehouse_id', true)` uses
> `missing_ok = true` so the policy evaluates to `NULL` (no rows visible)
> rather than raising an error if the session variable was never set —
> fail-closed, not fail-open. Always verify RLS policies fail closed.

### 2.6 Stored Procedures

**Procedure 1 — `sp_place_order` (FR-1: no overselling, row locking, full transaction).**

```sql
CREATE OR REPLACE PROCEDURE sp_place_order(
    IN  p_customer_id  INT,
    IN  p_address_id   INT,
    IN  p_warehouse_id INT,
    IN  p_items        JSONB,      -- [{"product_id":1,"quantity":2}, ...]
    OUT p_order_id     INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_item        RECORD;
    v_available   INT;
    v_subtotal    NUMERIC(12,2) := 0;
    v_unit_price  NUMERIC(10,2);
BEGIN
    -- ---- input validation --------------------------------------------
    IF p_customer_id IS NULL OR p_address_id IS NULL OR p_warehouse_id IS NULL THEN
        RAISE EXCEPTION 'sp_place_order: customer_id, address_id, warehouse_id are required';
    END IF;
    IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'sp_place_order: p_items must be a non-empty JSON array';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'sp_place_order: customer % not found or inactive', p_customer_id;
    END IF;

    -- Explicit transaction boundary (a CALL to a procedure is already
    -- transactional per invocation; this block additionally demonstrates
    -- the isolation level required for the concurrency guarantee in FR-1).
    -- READ COMMITTED is sufficient here BECAUSE we take an explicit row
    -- lock below rather than relying on the isolation level alone.
    BEGIN
        INSERT INTO orders (customer_id, shipping_address_id, warehouse_id, status)
        VALUES (p_customer_id, p_address_id, p_warehouse_id, 'PENDING')
        RETURNING order_id INTO p_order_id;

        FOR v_item IN SELECT * FROM jsonb_to_recordset(p_items) AS x(product_id INT, quantity INT)
        LOOP
            IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
                RAISE EXCEPTION 'sp_place_order: invalid quantity for product %', v_item.product_id;
            END IF;

            -- *** THE concurrency-correctness line for FR-1 ***
            -- SELECT ... FOR UPDATE locks this exact (product,warehouse) row
            -- until COMMIT/ROLLBACK. A second concurrent transaction trying
            -- to sell the same last unit BLOCKS here until the first
            -- transaction commits (and sees the decremented quantity) or
            -- rolls back (and sees the original quantity) -- it can never
            -- see a stale value and oversell.
            SELECT quantity_on_hand, unit_price INTO v_available, v_unit_price
            FROM inventory i
            JOIN products p ON p.product_id = i.product_id
            WHERE i.product_id = v_item.product_id AND i.warehouse_id = p_warehouse_id
            FOR UPDATE;

            IF v_available IS NULL THEN
                RAISE EXCEPTION 'sp_place_order: product % not stocked at warehouse %',
                    v_item.product_id, p_warehouse_id;
            END IF;
            IF v_available < v_item.quantity THEN
                RAISE EXCEPTION 'sp_place_order: insufficient stock for product % (have %, need %)',
                    v_item.product_id, v_available, v_item.quantity;
            END IF;

            UPDATE inventory
               SET quantity_on_hand = quantity_on_hand - v_item.quantity,
                   updated_at = now()
             WHERE product_id = v_item.product_id AND warehouse_id = p_warehouse_id;

            INSERT INTO order_items (order_id, product_id, quantity, unit_price)
            VALUES (p_order_id, v_item.product_id, v_item.quantity, v_unit_price);

            v_subtotal := v_subtotal + (v_unit_price * v_item.quantity);
        END LOOP;

        UPDATE orders
           SET subtotal_amount = v_subtotal, total_amount = v_subtotal
         WHERE order_id = p_order_id;

    EXCEPTION WHEN OTHERS THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
        VALUES ('orders', COALESCE(p_order_id::TEXT, 'unknown'), 'INSERT',
                NULL,
                jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE,
                                    'customer_id', p_customer_id, 'items', p_items),
                current_user);
        RAISE;  -- re-raise so the CALLer's transaction rolls back (nothing left half-applied)
    END;
END;
$$;
```

**Procedure 2 — `sp_process_payment` (FR-8: all-or-nothing payment + status update).**

```sql
CREATE OR REPLACE PROCEDURE sp_process_payment(
    IN p_order_id INT,
    IN p_amount   NUMERIC,
    IN p_method   VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_order_total  NUMERIC(12,2);
    v_order_status VARCHAR(20);
    v_before       JSONB;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'sp_process_payment: amount must be positive';
    END IF;

    BEGIN
        -- Lock the order row so a concurrent duplicate payment call (e.g. a
        -- retried webhook) cannot both see status='PENDING' and both apply.
        SELECT total_amount, status, to_jsonb(o.*) INTO v_order_total, v_order_status, v_before
        FROM orders o
        WHERE order_id = p_order_id
        FOR UPDATE;

        IF v_order_status IS NULL THEN
            RAISE EXCEPTION 'sp_process_payment: order % not found', p_order_id;
        END IF;
        IF v_order_status NOT IN ('PENDING') THEN
            RAISE EXCEPTION 'sp_process_payment: order % is not payable (status=%)',
                p_order_id, v_order_status;
        END IF;
        IF p_amount <> v_order_total THEN
            RAISE EXCEPTION 'sp_process_payment: amount % does not match order total %',
                p_amount, v_order_total;
        END IF;

        INSERT INTO payments (order_id, amount, payment_method, status, processed_at)
        VALUES (p_order_id, p_amount, p_method, 'SUCCEEDED', now());

        UPDATE orders SET status = 'PAID' WHERE order_id = p_order_id;

    EXCEPTION WHEN OTHERS THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
        VALUES ('payments', p_order_id::TEXT, 'INSERT', v_before,
                jsonb_build_object('error', SQLERRM, 'attempted_amount', p_amount), current_user);
        RAISE;
    END;
END;
$$;
```

**Procedure 3 — `sp_batch_recalculate_tiers` (FR-9: the defensible cursor — see §2.8).**

**Procedure 4 — `sp_ship_order` (fulfillment transition, illustrates locking + trigger interplay).**

```sql
CREATE OR REPLACE PROCEDURE sp_ship_order(
    IN p_order_id     INT,
    IN p_carrier_id   INT,
    OUT p_shipment_id INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_warehouse_id INT;
    v_status       VARCHAR(20);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM carriers WHERE carrier_id = p_carrier_id AND is_active) THEN
        RAISE EXCEPTION 'sp_ship_order: carrier % is not a valid active carrier', p_carrier_id;
    END IF;

    BEGIN
        SELECT warehouse_id, status INTO v_warehouse_id, v_status
        FROM orders WHERE order_id = p_order_id FOR UPDATE;

        IF v_status IS NULL THEN
            RAISE EXCEPTION 'sp_ship_order: order % not found', p_order_id;
        END IF;
        IF v_status <> 'PAID' THEN
            RAISE EXCEPTION 'sp_ship_order: order % must be PAID to ship (is %)', p_order_id, v_status;
        END IF;

        INSERT INTO shipments (order_id, warehouse_id, carrier_id, tracking_number, status, shipped_at)
        VALUES (p_order_id, v_warehouse_id, p_carrier_id,
                'TRK' || to_char(now(), 'YYYYMMDDHH24MISS') || p_order_id,
                'SHIPPED', now())
        RETURNING shipment_id INTO p_shipment_id;

        INSERT INTO shipment_events (shipment_id, event_type, event_time, location_text)
        VALUES (p_shipment_id, 'CREATED', now(), 'Warehouse ' || v_warehouse_id);

        UPDATE orders SET status = 'SHIPPED' WHERE order_id = p_order_id;

    EXCEPTION WHEN OTHERS THEN
        INSERT INTO audit_log (table_name, record_id, action, new_data, changed_by)
        VALUES ('shipments', p_order_id::TEXT, 'INSERT',
                jsonb_build_object('error', SQLERRM, 'carrier_id', p_carrier_id), current_user);
        RAISE;
    END;
END;
$$;
```

### 2.7 Functions

```sql
-- STABLE: reads the database (order_items) but does not modify it, and
-- returns the same result for the same order_id within one statement/snapshot.
CREATE OR REPLACE FUNCTION fn_calculate_order_total(p_order_id INT)
RETURNS NUMERIC(12,2)
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(line_total), 0)
    FROM order_items
    WHERE order_id = p_order_id;
$$;

-- STABLE: pure lookup + read of loyalty_tiers; no side effects, but result
-- depends on table contents so it cannot be IMMUTABLE.
CREATE OR REPLACE FUNCTION fn_tier_for_points(p_points INT)
RETURNS INT
LANGUAGE sql
STABLE
AS $$
    SELECT tier_id
    FROM loyalty_tiers
    WHERE min_points <= p_points
    ORDER BY min_points DESC
    LIMIT 1;
$$;

-- IMMUTABLE: pure arithmetic on inputs only, no table access, same inputs
-- always produce same output -- safe to use in an index expression or to
-- let the planner constant-fold/cache across a statement.
CREATE OR REPLACE FUNCTION fn_estimate_shipping_days(p_distance_km NUMERIC, p_is_express BOOLEAN)
RETURNS INT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_distance_km IS NULL OR p_distance_km < 0 THEN
        RAISE EXCEPTION 'fn_estimate_shipping_days: distance must be non-negative';
    END IF;
    RETURN GREATEST(1, CEIL(p_distance_km / (CASE WHEN p_is_express THEN 800 ELSE 400 END)))::INT;
END;
$$;
```

### 2.8 Cursors: the defensible use case, and the anti-pattern to avoid

**Defensible cursor — FR-9, batch tier recalculation that must tolerate
per-row failure without aborting the whole batch.** A single set-based
`UPDATE ... FROM` cannot skip one bad row and keep going — if any row in a
statement throws (e.g., a malformed/legacy account referencing a
since-deleted tier), the **entire statement** rolls back. Per-row commit
control is exactly what a cursor buys us here.

```sql
CREATE OR REPLACE PROCEDURE sp_batch_recalculate_tiers()
LANGUAGE plpgsql
AS $$
DECLARE
    acct_cur CURSOR FOR
        SELECT loyalty_account_id, points_balance, tier_id FROM loyalty_accounts FOR UPDATE;
    v_rec        RECORD;
    v_new_tier   INT;
    v_processed  INT := 0;
    v_failed     INT := 0;
BEGIN
    OPEN acct_cur;
    LOOP
        FETCH acct_cur INTO v_rec;
        EXIT WHEN NOT FOUND;

        BEGIN
            v_new_tier := fn_tier_for_points(v_rec.points_balance);
            IF v_new_tier IS NULL THEN
                RAISE EXCEPTION 'no matching tier for % points', v_rec.points_balance;
            END IF;

            IF v_new_tier <> v_rec.tier_id THEN
                UPDATE loyalty_accounts
                   SET tier_id = v_new_tier, updated_at = now()
                 WHERE loyalty_account_id = v_rec.loyalty_account_id;
            END IF;
            v_processed := v_processed + 1;

        EXCEPTION WHEN OTHERS THEN
            -- Log and CONTINUE -- this per-row isolation is the entire
            -- reason a cursor is justified over a single set-based UPDATE.
            v_failed := v_failed + 1;
            INSERT INTO audit_log (table_name, record_id, action, new_data, changed_by)
            VALUES ('loyalty_accounts', v_rec.loyalty_account_id::TEXT, 'UPDATE',
                    jsonb_build_object('error', SQLERRM, 'points_balance', v_rec.points_balance),
                    current_user);
        END;
    END LOOP;
    CLOSE acct_cur;

    RAISE NOTICE 'sp_batch_recalculate_tiers: % processed, % failed', v_processed, v_failed;
END;
$$;
```

**Anti-pattern — naive cursor doing what a `GROUP BY` should do.** A common
mistake is using a cursor to build an aggregate report row-by-row:

```sql
-- ❌ NAIVE: cursor-driven per-warehouse revenue totals (RBAR -- "row by
-- agonizing row"). This issues one query per warehouse loop iteration,
-- can't use a single index-optimized aggregate scan, and its cost grows
-- linearly with warehouse count PLUS the cost of N separate SUM() scans.
DO $$
DECLARE
    wh_cur CURSOR FOR SELECT warehouse_id FROM warehouses;
    v_wh RECORD;
    v_total NUMERIC;
BEGIN
    OPEN wh_cur;
    LOOP
        FETCH wh_cur INTO v_wh;
        EXIT WHEN NOT FOUND;
        SELECT SUM(total_amount) INTO v_total
        FROM orders WHERE warehouse_id = v_wh.warehouse_id;
        RAISE NOTICE 'Warehouse %: %', v_wh.warehouse_id, v_total;
    END LOOP;
    CLOSE wh_cur;
END;
$$;
```

```sql
-- ✅ SET-BASED REWRITE: one single aggregate scan, one index range scan per
-- warehouse group via idx_orders_warehouse_date, computed by the engine's
-- own aggregate machinery instead of N round trips through PL/pgSQL.
SELECT warehouse_id, SUM(total_amount) AS total_revenue
FROM orders
GROUP BY warehouse_id
ORDER BY warehouse_id;
```

**Why the rewrite wins:** the cursor version does `N` separate planned
queries (one per warehouse) plus PL/pgSQL loop overhead and cannot share
work across iterations; the set-based version is a single execution plan
that the planner can satisfy with one pass over `idx_orders_warehouse_date`
(or a single sequential scan with a hash aggregate at larger scale) —
strictly less I/O, no interpreter loop overhead, and it parallelizes under
PostgreSQL's parallel query executor, which the cursor loop never can.

### 2.9 Triggers

**Trigger 1 — generic JSONB audit-logging trigger (FR-2).**

```sql
CREATE OR REPLACE FUNCTION trg_fn_audit_generic()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
        VALUES (TG_TABLE_NAME, (to_jsonb(NEW) ->> TG_ARGV[0]), 'INSERT', NULL, to_jsonb(NEW), current_user);
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
        VALUES (TG_TABLE_NAME, (to_jsonb(NEW) ->> TG_ARGV[0]), 'UPDATE', to_jsonb(OLD), to_jsonb(NEW), current_user);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
        VALUES (TG_TABLE_NAME, (to_jsonb(OLD) ->> TG_ARGV[0]), 'DELETE', to_jsonb(OLD), NULL, current_user);
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_orders
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_generic('order_id');

CREATE TRIGGER trg_audit_payments
    AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_generic('payment_id');

CREATE TRIGGER trg_audit_inventory
    AFTER INSERT OR UPDATE OR DELETE ON inventory
    FOR EACH ROW EXECUTE FUNCTION trg_fn_audit_generic('inventory_id');
```

**Trigger 2 — denormalized-aggregate maintenance (FR-4: points balance).**

```sql
CREATE OR REPLACE FUNCTION trg_fn_loyalty_ledger_apply()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_balance INT;
BEGIN
    UPDATE loyalty_accounts
       SET points_balance = points_balance + NEW.points_delta,
           updated_at = now()
     WHERE loyalty_account_id = NEW.loyalty_account_id
     RETURNING points_balance INTO v_new_balance;

    IF v_new_balance < 0 THEN
        RAISE EXCEPTION 'loyalty_ledger: resulting balance % is negative for account %',
            v_new_balance, NEW.loyalty_account_id;
    END IF;

    UPDATE loyalty_accounts
       SET tier_id = fn_tier_for_points(v_new_balance)
     WHERE loyalty_account_id = NEW.loyalty_account_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loyalty_ledger_apply
    AFTER INSERT ON loyalty_ledger
    FOR EACH ROW EXECUTE FUNCTION trg_fn_loyalty_ledger_apply();
```

**Trigger 3 — validation trigger that a `CHECK` constraint cannot express
(cross-row: inventory can never go negative even under a raw `UPDATE`, not
just through `sp_place_order`).**

```sql
CREATE OR REPLACE FUNCTION trg_fn_inventory_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.quantity_on_hand < 0 THEN
        RAISE EXCEPTION 'inventory: quantity_on_hand cannot go negative (product %, warehouse %)',
            NEW.product_id, NEW.warehouse_id;
    END IF;
    IF NEW.quantity_on_hand <= NEW.reorder_threshold AND OLD.quantity_on_hand > OLD.reorder_threshold THEN
        RAISE NOTICE 'inventory: product % at warehouse % crossed reorder threshold',
            NEW.product_id, NEW.warehouse_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inventory_guard
    BEFORE UPDATE ON inventory
    FOR EACH ROW EXECUTE FUNCTION trg_fn_inventory_guard();
```

> **Important:** the `CHECK (quantity_on_hand >= 0)` constraint on
> `inventory` already blocks a *single-row* negative value. The trigger adds
> nothing there — it exists because the reorder-threshold **cross-column,
> old-vs-new comparison** (`NEW.quantity_on_hand <= NEW.reorder_threshold AND
> OLD... > OLD...`) cannot be expressed as a stateless `CHECK` constraint at
> all, since `CHECK` cannot reference `OLD`.

### 2.10 Recursive CTE — Employee Org Chart (FR-3)

```sql
-- Full downward reporting chain + depth + headcount, from any root manager.
WITH RECURSIVE org_chart AS (
    SELECT employee_id, first_name, last_name, manager_id, job_title,
           1 AS depth,
           ARRAY[employee_id] AS path,
           first_name || ' ' || last_name AS chain
    FROM employees
    WHERE manager_id IS NULL                 -- root(s) of the hierarchy

    UNION ALL

    SELECT e.employee_id, e.first_name, e.last_name, e.manager_id, e.job_title,
           oc.depth + 1,
           oc.path || e.employee_id,
           oc.chain || ' -> ' || e.first_name || ' ' || e.last_name
    FROM employees e
    JOIN org_chart oc ON e.manager_id = oc.employee_id
    WHERE NOT e.employee_id = ANY(oc.path)   -- cycle guard
)
SELECT employee_id, chain, depth, job_title
FROM org_chart
ORDER BY path;
```

```sql
-- Headcount rollup per manager (direct + indirect reports), using the same
-- recursive traversal as a subquery.
WITH RECURSIVE org_chart AS (
    SELECT employee_id, manager_id, employee_id AS root_manager
    FROM employees
    WHERE manager_id IS NOT NULL
    UNION ALL
    SELECT oc.employee_id, e.manager_id, e.manager_id
    FROM org_chart oc
    JOIN employees e ON oc.manager_id = e.employee_id
    WHERE e.manager_id IS NOT NULL
)
SELECT m.employee_id, m.first_name, m.last_name,
       COUNT(DISTINCT oc.employee_id) AS total_reports_all_levels
FROM employees m
LEFT JOIN org_chart oc ON oc.root_manager = m.employee_id OR oc.manager_id = m.employee_id
GROUP BY m.employee_id, m.first_name, m.last_name
ORDER BY total_reports_all_levels DESC;
```

### 2.11 Window-Function Analytical Reports (FR-6, FR-10)

**Report A — monthly revenue per warehouse, running YTD total + trailing
3-month moving average (FR-10).**

```sql
WITH monthly AS (
    SELECT warehouse_id,
           date_trunc('month', order_date)::DATE AS month,
           SUM(total_amount) AS revenue
    FROM orders
    WHERE status NOT IN ('CANCELLED','REFUNDED')
    GROUP BY warehouse_id, date_trunc('month', order_date)
)
SELECT warehouse_id, month, revenue,
       SUM(revenue) OVER (PARTITION BY warehouse_id ORDER BY month) AS ytd_running_total,
       ROUND(AVG(revenue) OVER (
           PARTITION BY warehouse_id ORDER BY month
           ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
       ), 2) AS trailing_3mo_avg
FROM monthly
ORDER BY warehouse_id, month;
```

**Report B — customer spend ranking + quartile segmentation per region.**

```sql
WITH customer_spend AS (
    SELECT c.customer_id, c.first_name, c.last_name, a.region_id,
           SUM(o.total_amount) AS lifetime_spend
    FROM customers c
    JOIN customer_addresses a ON a.customer_id = c.customer_id AND a.is_default
    JOIN orders o ON o.customer_id = c.customer_id
    WHERE o.status NOT IN ('CANCELLED','REFUNDED')
    GROUP BY c.customer_id, c.first_name, c.last_name, a.region_id
)
SELECT customer_id, first_name, last_name, region_id, lifetime_spend,
       RANK() OVER (PARTITION BY region_id ORDER BY lifetime_spend DESC) AS spend_rank_in_region,
       NTILE(4) OVER (PARTITION BY region_id ORDER BY lifetime_spend DESC) AS spend_quartile
FROM customer_spend
ORDER BY region_id, spend_rank_in_region;
```

**Report C — order cadence: days since a customer's previous order (LAG).**

```sql
SELECT customer_id, order_id, order_date,
       LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS previous_order_date,
       order_date - LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS days_since_previous
FROM orders
WHERE status NOT IN ('CANCELLED')
ORDER BY customer_id, order_date;
```

**Report D — top 3 products by revenue per category (ROW_NUMBER top-N per group).**

```sql
WITH product_revenue AS (
    SELECT pc.category_id, p.product_id, p.product_name,
           SUM(oi.line_total) AS revenue
    FROM order_items oi
    JOIN products p ON p.product_id = oi.product_id
    JOIN product_categories pc ON pc.product_id = p.product_id
    GROUP BY pc.category_id, p.product_id, p.product_name
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY revenue DESC) AS rn
    FROM product_revenue
)
SELECT category_id, product_id, product_name, revenue
FROM ranked
WHERE rn <= 3
ORDER BY category_id, revenue DESC;
```

### 2.12 The Hard Reporting Requirement (FR-6), Optimized

**Requirement:** for the most recently completed calendar quarter, per
warehouse: total revenue, top 3 products by revenue, average delivery time
in hours, and the percentage of that revenue coming from customers in the
**top spending quartile company-wide** — counting only shipments with
**zero** `EXCEPTION` events. Today is 2026-09-24, so the most recently
*completed* quarter is **Q2 2026 (Apr 1 – Jun 30)**.

**Step 1 — the naive version (what a report-writer would write first).**

```sql
-- ❌ NAIVE: correlated subquery per order to test "is this customer top
-- quartile" (recomputing the ENTIRE company's lifetime spend distribution
-- once per row), and a NOT EXISTS against the full, unpruned fact table
-- because the date predicate is only implied, never stated, against
-- shipment_events itself.
SELECT o.warehouse_id,
       SUM(o.total_amount) AS revenue,
       AVG(EXTRACT(EPOCH FROM (s.delivered_at - s.shipped_at)) / 3600) AS avg_delivery_hours
FROM orders o
JOIN shipments s ON s.order_id = o.order_id
WHERE o.order_date >= '2026-04-01' AND o.order_date < '2026-07-01'
  AND o.status NOT IN ('CANCELLED','REFUNDED')
  AND NOT EXISTS (
        SELECT 1 FROM shipment_events se
        WHERE se.shipment_id = s.shipment_id AND se.event_type = 'EXCEPTION'
      )
  AND (
        SELECT PERCENT_RANK() OVER (ORDER BY t.lifetime_spend)
        FROM (SELECT SUM(total_amount) AS lifetime_spend
              FROM orders o2 WHERE o2.customer_id = o.customer_id) t
      ) >= 0.75   -- ⚠️ this correlated-subquery-with-window-function per outer
                  --    row is not even guaranteed by the standard to be
                  --    meaningful as written (a window function over a
                  --    single-row derived table is degenerate) -- it is
                  --    included here precisely because it is the kind of
                  --    query a report-writer under deadline pressure
                  --    actually submits, and it must be caught in review.
GROUP BY o.warehouse_id;
```

**Step 2 — `EXPLAIN` diagnosis (illustrative plan on the seeded dataset,
scaled up in the narrative to the 5M-row production case).**

```
Illustrative EXPLAIN (ANALYZE, BUFFERS) findings on the naive query:

 HashAggregate  (cost=very high) (actual time=large)
   -> Nested Loop  (actual rows ≈ one iteration PER ORDER)
        -> Seq Scan on orders o             <- date filter not sargable
                                                against an index that also
                                                orders by warehouse; combined
                                                with the correlated subquery
                                                this becomes O(orders × orders)
        -> SubPlan (re-executed once per outer row)
             -> Aggregate  (Seq Scan on orders o2)   <- recomputed per row!
        -> Seq Scan on shipment_events se    <- NOT EXISTS scans ALL THREE
                                                 quarterly partitions plus
                                                 the default partition,
                                                 because no predicate on
                                                 se.event_time exists to let
                                                 the planner prune partitions

 Planning Time: ...   Execution Time: seconds, not milliseconds, and grows
                       QUADRATICALLY with order count because of the
                       per-row correlated lifetime-spend subquery.
```

Three distinct problems: (1) the correlated per-row lifetime-spend subquery
turns an O(n) report into O(n²); (2) `NOT EXISTS` against `shipment_events`
has no time predicate, so **every partition is scanned** even though we only
care about Q2 2026 shipments; (3) no index supports `orders` filtered by
date range grouped by warehouse together.

**Step 3 — the rewritten, indexed, partition-pruned version.**

```sql
-- ✅ OPTIMIZED
-- 1. Lifetime spend + quartile computed ONCE, up front, with a window
--    function over the whole customer base -- O(n log n), not O(n^2).
-- 2. The exception check adds an explicit event_time predicate matching
--    the quarter, so the planner can prune to just the Q2 2026 partition.
-- 3. idx_orders_active (partial, warehouse_id, order_date) and
--    idx_shipment_events_exceptions (partial) are both usable.
WITH customer_quartiles AS (
    SELECT customer_id,
           SUM(total_amount) AS lifetime_spend,
           NTILE(4) OVER (ORDER BY SUM(total_amount) DESC) AS spend_quartile
    FROM orders
    WHERE status NOT IN ('CANCELLED','REFUNDED')
    GROUP BY customer_id
),
q2_orders AS (
    SELECT o.order_id, o.warehouse_id, o.customer_id, o.total_amount
    FROM orders o
    WHERE o.order_date >= '2026-04-01' AND o.order_date < '2026-07-01'
      AND o.status NOT IN ('CANCELLED','REFUNDED')
),
clean_shipments AS (
    SELECT s.shipment_id, s.order_id, s.shipped_at, s.delivered_at
    FROM shipments s
    WHERE s.shipped_at >= '2026-04-01' AND s.shipped_at < '2026-07-01'
      AND NOT EXISTS (
            SELECT 1 FROM shipment_events se
            WHERE se.shipment_id = s.shipment_id
              AND se.event_type = 'EXCEPTION'
              -- vvv this predicate is what enables partition pruning: the
              -- planner now knows only the 2026_q2 partition can match.
              AND se.event_time >= '2026-04-01' AND se.event_time < '2026-07-01'
          )
),
warehouse_revenue AS (
    SELECT qo.warehouse_id,
           SUM(qo.total_amount) AS total_revenue,
           SUM(qo.total_amount) FILTER (WHERE cq.spend_quartile = 1) AS top_quartile_revenue,
           AVG(EXTRACT(EPOCH FROM (cs.delivered_at - cs.shipped_at)) / 3600) AS avg_delivery_hours
    FROM q2_orders qo
    JOIN clean_shipments cs ON cs.order_id = qo.order_id
    JOIN customer_quartiles cq ON cq.customer_id = qo.customer_id
    GROUP BY qo.warehouse_id
),
top_products AS (
    SELECT warehouse_id, product_id, product_name, revenue,
           ROW_NUMBER() OVER (PARTITION BY warehouse_id ORDER BY revenue DESC) AS rn
    FROM (
        SELECT qo.warehouse_id, p.product_id, p.product_name,
               SUM(oi.line_total) AS revenue
        FROM q2_orders qo
        JOIN order_items oi ON oi.order_id = qo.order_id
        JOIN products p ON p.product_id = oi.product_id
        GROUP BY qo.warehouse_id, p.product_id, p.product_name
    ) x
)
SELECT wr.warehouse_id, wr.total_revenue,
       ROUND(100.0 * wr.top_quartile_revenue / NULLIF(wr.total_revenue, 0), 1) AS pct_from_top_quartile,
       ROUND(wr.avg_delivery_hours, 1) AS avg_delivery_hours,
       jsonb_agg(jsonb_build_object('product', tp.product_name, 'revenue', tp.revenue)
                 ORDER BY tp.revenue DESC) FILTER (WHERE tp.rn <= 3) AS top_3_products
FROM warehouse_revenue wr
JOIN top_products tp ON tp.warehouse_id = wr.warehouse_id
GROUP BY wr.warehouse_id, wr.total_revenue, wr.top_quartile_revenue, wr.avg_delivery_hours
ORDER BY wr.warehouse_id;
```

**Why this meets the < 500ms target at 5M-row scale:**

1. `customer_quartiles` is computed **once** with a single windowed
   aggregate pass over `orders` (using `idx_orders_customer_date`) instead
   of once per row — turns O(n²) into O(n log n).
2. `clean_shipments`'s `NOT EXISTS` now carries an `event_time` predicate
   that matches a partition boundary exactly, so the planner performs
   **partition pruning** and only ever touches `shipment_events_2026_q2`
   (roughly one-quarter of the fact table, and shrinking further via the
   `idx_shipment_events_exceptions` partial index, which only indexes the
   ~2-3% of rows that are actually `EXCEPTION` events).
3. `q2_orders` uses `idx_orders_active` (the partial index on
   `(warehouse_id, order_date) WHERE status NOT IN ('CANCELLED','REFUNDED')`),
   which matches both the report's `WHERE` clause and its `GROUP BY`
   column, letting the planner do an index range scan instead of a
   sequential scan with a filter.
4. No step recomputes a whole-table aggregate more than once, so total work
   is linear in the size of Q2's data plus one linear pass over all
   customers for the quartile calculation — both bounded and cheap even as
   `shipment_events` grows to 5M+ rows, because pruning keeps the relevant
   partition roughly constant-sized per quarter regardless of how many
   *other* quarters' history accumulates.

### 2.13 Requirements Traceability

| Part 1 requirement | Satisfied by |
|---|---|
| 15+ tables, complex relationships | §2.1 ER diagram, §2.2 DDL — 20 tables |
| Self-referencing hierarchy | `employees.manager_id` (§2.2); traversed in §2.10 |
| High-volume fact table + partitioning | `shipment_events`, RANGE-partitioned by quarter (§2.2); pruning demonstrated in §2.12 |
| 1:1 relationship | `customers` ↔ `loyalty_accounts` (§2.2, design note) |
| M:N with attributes | `inventory` (product×warehouse+qty), `order_items` (order×product+qty/price) |
| M:N pure bridge | `product_categories` |
| Set-based seeding, few thousand rows | §2.3 — `generate_series`-driven seeding of products, customers, orders, order_items, shipments, shipment_events |
| FR-1 (no overselling) | `sp_place_order`, `SELECT ... FOR UPDATE` on `inventory` (§2.6) |
| FR-2 (audit trail, JSONB before/after) | `trg_fn_audit_generic` + `audit_log` (§2.9) |
| FR-3 (org chart, recursive) | §2.10 recursive CTEs |
| FR-4 (auto tier updates, no negative balance) | `trg_fn_loyalty_ledger_apply` (§2.9), `CHECK (points_balance >= 0)` |
| FR-5 (warehouse-scoped access) | `ns_warehouse_staff` role + RLS policies (§2.5) |
| FR-6 (quarterly report, performant) | §2.11 Report A/D contribute pieces; full hard report + optimization in §2.12 |
| FR-7 (real-time shipment status) | `AFTER INSERT` semantics of `shipment_events`/triggers fire synchronously in the same transaction, no batch delay |
| FR-8 (atomic payment + status) | `sp_process_payment`, `FOR UPDATE` lock + single transaction (§2.6) |
| FR-9 (partial-failure-tolerant batch) | `sp_batch_recalculate_tiers` cursor with per-row exception handling (§2.8) |
| FR-10 (running total / moving avg, top spenders) | §2.11 Report A, Report B |
| Stored procedures (3+) | §2.6 — `sp_place_order`, `sp_process_payment`, `sp_ship_order`, plus `sp_batch_recalculate_tiers` in §2.8 |
| Functions (2+, volatility labeled) | §2.7 — `fn_calculate_order_total` (STABLE), `fn_tier_for_points` (STABLE), `fn_estimate_shipping_days` (IMMUTABLE) |
| Cursor + naive-vs-set-based teaching moment | §2.8 |
| Triggers (2+, audit + other) | §2.9 — audit trigger, ledger-balance trigger, inventory-guard trigger |
| Transactions/isolation/locking | `FOR UPDATE` row locks in §2.6 procedures; isolation-level rationale inline |
| CTEs / recursive CTEs | §2.10, and CTEs used throughout §2.11-2.12 |
| Window functions (3+ reports) | §2.11 Reports A-D |
| Indexes: composite/partial/expression | §2.4 |
| Hard-to-optimize report + optimization narrative | §2.12 |
| Partitioning (2-3 partitions) | §2.2 `shipment_events` — 3 quarterly + 1 default |
| Security: roles + RLS | §2.5 |
| Audit logging with JSONB | §2.9 Trigger 1, `audit_log.old_data`/`new_data` |
| NFR: concurrency correctness | `FOR UPDATE` locking in `sp_place_order`/`sp_process_payment` (§2.6) |
| NFR: audit completeness | Trigger-based (not app-layer) audit on `orders`, `payments`, `inventory` — fires even on direct/cascading writes |
| NFR: performance target (<500ms) | §2.12 optimization narrative |

> **Important:** in a real interview or take-home setting, walk through this
> traceability table out loud — it is the single fastest way to prove to a
> reviewer that nothing on the requirements list was silently dropped.
