-- ============================================================================
-- analytics_db — canonical large-scale sample database for the SQL Mastery
-- Course. Used in: Window Functions (deep), Partitioning, Query Execution &
-- Planner, Performance Optimization, Advanced Patterns (cohorts/retention),
-- Project 4 (Large-Scale Analytics).
--
-- Unlike company_db/ecommerce_db/banking_db (hand-authored small seed data),
-- this database is POPULATED PROGRAMMATICALLY using generate_series so the
-- course can demonstrate behavior at realistic scale (millions of rows).
-- Dialect: PostgreSQL (primary) — generate_series is PostgreSQL-specific;
-- chapters note MySQL/Oracle/SQL Server equivalents where used.
-- ============================================================================

DROP SCHEMA IF EXISTS analytics_db CASCADE;
CREATE SCHEMA analytics_db;
SET search_path TO analytics_db;

-- ---------------------------------------------------------------------------
-- Star-schema dimension tables
-- ---------------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key     DATE PRIMARY KEY,
    year         INT NOT NULL,
    quarter      INT NOT NULL,
    month        INT NOT NULL,
    day          INT NOT NULL,
    day_of_week  INT NOT NULL,
    is_weekend   BOOLEAN NOT NULL
);

CREATE TABLE dim_customer (
    customer_key SERIAL PRIMARY KEY,
    customer_name VARCHAR(100) NOT NULL,
    segment       VARCHAR(20) NOT NULL,       -- 'CONSUMER','BUSINESS','ENTERPRISE'
    signup_date   DATE NOT NULL,
    country       VARCHAR(50) NOT NULL
);

CREATE TABLE dim_product (
    product_key   SERIAL PRIMARY KEY,
    product_name  VARCHAR(100) NOT NULL,
    category      VARCHAR(50) NOT NULL,
    unit_cost     NUMERIC(10,2) NOT NULL
);

CREATE TABLE dim_store (
    store_key    SERIAL PRIMARY KEY,
    store_name   VARCHAR(100) NOT NULL,
    region       VARCHAR(50) NOT NULL
);

-- ---------------------------------------------------------------------------
-- Fact table: sales_fact — RANGE partitioned by sale_date (see Ch. 27)
-- ---------------------------------------------------------------------------
CREATE TABLE sales_fact (
    sale_id      BIGSERIAL,
    sale_date    DATE NOT NULL,
    customer_key INT NOT NULL,
    product_key  INT NOT NULL,
    store_key    INT NOT NULL,
    quantity     INT NOT NULL CHECK (quantity > 0),
    amount       NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    PRIMARY KEY (sale_id, sale_date)
) PARTITION BY RANGE (sale_date);

CREATE TABLE sales_fact_2022 PARTITION OF sales_fact
    FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
CREATE TABLE sales_fact_2023 PARTITION OF sales_fact
    FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');
CREATE TABLE sales_fact_2024 PARTITION OF sales_fact
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

-- ---------------------------------------------------------------------------
-- Event log table (JSON payload) for cohort/retention/time-series examples
-- ---------------------------------------------------------------------------
CREATE TABLE events (
    event_id    BIGSERIAL PRIMARY KEY,
    user_id     INT NOT NULL,
    event_type  VARCHAR(30) NOT NULL,     -- 'SIGNUP','LOGIN','PURCHASE','CHURN'
    event_time  TIMESTAMP NOT NULL,
    payload     JSONB
);

-- ============================================================================
-- DATA GENERATION (set-based, no procedural loops — this itself is a good
-- early example of "prefer set-based SQL over row-by-row generation")
-- ============================================================================

-- dim_date: 2022-01-01 through 2025-12-31
INSERT INTO dim_date (date_key, year, quarter, month, day, day_of_week, is_weekend)
SELECT d::date,
       EXTRACT(YEAR FROM d)::int,
       EXTRACT(QUARTER FROM d)::int,
       EXTRACT(MONTH FROM d)::int,
       EXTRACT(DAY FROM d)::int,
       EXTRACT(ISODOW FROM d)::int,
       EXTRACT(ISODOW FROM d) IN (6,7)
FROM generate_series('2022-01-01'::date, '2025-12-31'::date, interval '1 day') AS d;

-- dim_customer: 5,000 customers
INSERT INTO dim_customer (customer_name, segment, signup_date, country)
SELECT 'Customer ' || i,
       (ARRAY['CONSUMER','BUSINESS','ENTERPRISE'])[1 + floor(random()*3)],
       ('2022-01-01'::date + (floor(random()*1460))::int),
       (ARRAY['India','USA','UK','Germany','UAE','Singapore'])[1 + floor(random()*6)]
FROM generate_series(1, 5000) AS i;

-- dim_product: 200 products across 10 categories
INSERT INTO dim_product (product_name, category, unit_cost)
SELECT 'Product ' || i,
       (ARRAY['Electronics','Fashion','Home','Sports','Books','Grocery','Toys','Beauty','Automotive','Garden'])[1 + floor(random()*10)],
       round((random()*4000 + 50)::numeric, 2)
FROM generate_series(1, 200) AS i;

-- dim_store: 25 stores across 5 regions
INSERT INTO dim_store (store_name, region)
SELECT 'Store ' || i,
       (ARRAY['North','South','East','West','Central'])[1 + floor(random()*5)]
FROM generate_series(1, 25) AS i;

-- sales_fact: ~5 million rows spread across 2022-2024
-- NOTE: This will take a few minutes and require notable disk space.
-- For quick local experimentation, reduce 5,000,000 to e.g. 200,000.
INSERT INTO sales_fact (sale_date, customer_key, product_key, store_key, quantity, amount)
SELECT
    ('2022-01-01'::date + floor(random()*1095)::int) AS sale_date,
    (1 + floor(random()*5000))::int AS customer_key,
    (1 + floor(random()*200))::int  AS product_key,
    (1 + floor(random()*25))::int   AS store_key,
    (1 + floor(random()*5))::int    AS quantity,
    round((random()*500 + 10)::numeric, 2) AS amount
FROM generate_series(1, 5000000);

-- events: 200,000 rows for ~20,000 synthetic users (cohort/retention demos)
INSERT INTO events (user_id, event_type, event_time, payload)
SELECT
    u AS user_id,
    e.event_type,
    signup_ts + (e.offset_days || ' days')::interval + (floor(random()*86400) || ' seconds')::interval,
    jsonb_build_object('source', (ARRAY['web','ios','android'])[1+floor(random()*3)])
FROM (
    SELECT gs AS u,
           ('2023-01-01'::date + floor(random()*365)::int)::timestamp AS signup_ts
    FROM generate_series(1, 20000) AS gs
) u
CROSS JOIN LATERAL (
    VALUES ('SIGNUP', 0),
           ('LOGIN', (floor(random()*60))::int),
           ('PURCHASE', (floor(random()*90))::int),
           ('LOGIN', (floor(random()*120))::int)
) AS e(event_type, offset_days)
WHERE random() < 0.85;  -- not every synthetic event fires, to create realistic gaps

-- Helpful indexes referenced later in Chapters 17/27
CREATE INDEX idx_sales_fact_customer ON sales_fact (customer_key);
CREATE INDEX idx_sales_fact_product  ON sales_fact (product_key);
CREATE INDEX idx_events_user_time    ON events (user_id, event_time);

ANALYZE;
