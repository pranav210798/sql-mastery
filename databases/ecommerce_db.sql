-- ============================================================================
-- ecommerce_db — canonical sample database for the SQL Mastery Course
-- Used in: Joins deep-dive, Window Functions, Views, Indexes, Triggers,
-- Advanced Data Types, Advanced Patterns, Project 3
-- Dialect: PostgreSQL (primary)
-- ============================================================================

DROP SCHEMA IF EXISTS ecommerce_db CASCADE;
CREATE SCHEMA ecommerce_db;
SET search_path TO ecommerce_db;

CREATE TABLE users (
    user_id      SERIAL PRIMARY KEY,
    username     VARCHAR(50) NOT NULL UNIQUE,
    email        VARCHAR(150) NOT NULL UNIQUE,
    full_name    VARCHAR(150) NOT NULL,
    created_at   TIMESTAMP NOT NULL DEFAULT now(),
    is_active    BOOLEAN NOT NULL DEFAULT TRUE
);

-- Self-referencing FK enables category tree / recursive CTE examples
CREATE TABLE categories (
    category_id        SERIAL PRIMARY KEY,
    category_name      VARCHAR(100) NOT NULL,
    parent_category_id INT REFERENCES categories(category_id)
);

CREATE TABLE products (
    product_id     SERIAL PRIMARY KEY,
    product_name   VARCHAR(150) NOT NULL,
    category_id    INT REFERENCES categories(category_id),
    price          NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    sku            VARCHAR(30) NOT NULL UNIQUE,
    created_at     TIMESTAMP NOT NULL DEFAULT now(),
    is_discontinued BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE inventory (
    inventory_id       SERIAL PRIMARY KEY,
    product_id         INT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    warehouse_location VARCHAR(100) NOT NULL,
    quantity_on_hand   INT NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
    reorder_level      INT NOT NULL DEFAULT 10,
    UNIQUE (product_id, warehouse_location)
);

CREATE TABLE orders (
    order_id         SERIAL PRIMARY KEY,
    user_id          INT NOT NULL REFERENCES users(user_id),
    order_date       TIMESTAMP NOT NULL DEFAULT now(),
    status           VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','PAID','SHIPPED','DELIVERED','CANCELLED')),
    shipping_address VARCHAR(250)
);

CREATE TABLE order_items (
    order_item_id  SERIAL PRIMARY KEY,
    order_id       INT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id     INT NOT NULL REFERENCES products(product_id),
    quantity       INT NOT NULL CHECK (quantity > 0),
    unit_price     NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    UNIQUE (order_id, product_id)
);

CREATE TABLE payments (
    payment_id     SERIAL PRIMARY KEY,
    order_id       INT NOT NULL REFERENCES orders(order_id),
    payment_date   TIMESTAMP,
    amount         NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    payment_method VARCHAR(30) NOT NULL CHECK (payment_method IN ('CARD','UPI','NETBANKING','COD','WALLET')),
    status         VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','SUCCESS','FAILED','REFUNDED'))
);

CREATE TABLE reviews (
    review_id    SERIAL PRIMARY KEY,
    product_id   INT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    user_id      INT NOT NULL REFERENCES users(user_id),
    rating       SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    review_text  TEXT,
    review_date  TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (product_id, user_id)
);

-- ============================================================================
-- SEED DATA
-- ============================================================================

INSERT INTO users (user_id, username, email, full_name, created_at, is_active) VALUES
(1,'arjun_k','arjun.k@mail.com','Arjun Kumar','2023-01-05 10:00',TRUE),
(2,'sara_p','sara.p@mail.com','Sara Patel','2023-02-11 12:30',TRUE),
(3,'dev_m','dev.m@mail.com','Dev Malhotra','2023-03-20 09:15',TRUE),
(4,'nita_r','nita.r@mail.com','Nita Rao','2023-04-02 18:45',FALSE),
(5,'imran_s','imran.s@mail.com','Imran Sheikh','2023-05-17 08:00',TRUE),
(6,'lakshmi_v','lakshmi.v@mail.com','Lakshmi Venkat','2023-06-25 14:20',TRUE),
(7,'farhan_a','farhan.a@mail.com','Farhan Ali','2023-07-30 11:10',TRUE),
(8,'tanya_b','tanya.b@mail.com','Tanya Bose','2023-08-14 16:05',TRUE);
SELECT setval('users_user_id_seq', 8);

INSERT INTO categories (category_id, category_name, parent_category_id) VALUES
(1,'Electronics', NULL),
(2,'Mobiles',     1),
(3,'Laptops',     1),
(4,'Fashion',     NULL),
(5,'Men',         4),
(6,'Women',       4),
(7,'Home & Kitchen', NULL);
SELECT setval('categories_category_id_seq', 7);

INSERT INTO products (product_id, product_name, category_id, price, sku) VALUES
(1,'Galaxy Phone X',      2, 45999.00, 'SKU-MOB-001'),
(2,'Pixel Lite',          2, 29999.00, 'SKU-MOB-002'),
(3,'UltraBook Pro 14',    3, 89999.00, 'SKU-LAP-001'),
(4,'GameBook 15',         3, 74999.00, 'SKU-LAP-002'),
(5,'Men Cotton Shirt',    5,  1299.00, 'SKU-MEN-001'),
(6,'Women Kurta Set',     6,  1799.00, 'SKU-WOM-001'),
(7,'Non-stick Pan Set',   7,  2499.00, 'SKU-HOM-001'),
(8,'Electric Kettle',     7,  1499.00, 'SKU-HOM-002'),
(9,'Wireless Earbuds',    2,  3499.00, 'SKU-MOB-003'),
(10,'Laptop Sleeve 14"',  3,   799.00, 'SKU-LAP-003');
SELECT setval('products_product_id_seq', 10);

INSERT INTO inventory (product_id, warehouse_location, quantity_on_hand, reorder_level) VALUES
(1,'Mumbai-WH1', 40, 10), (1,'Delhi-WH2', 15, 10),
(2,'Mumbai-WH1', 60, 15),
(3,'Pune-WH1',   12,  5),
(4,'Pune-WH1',    3,  5),
(5,'Delhi-WH2', 200, 30),
(6,'Delhi-WH2', 150, 30),
(7,'Mumbai-WH1', 80, 20),
(8,'Mumbai-WH1', 90, 20),
(9,'Mumbai-WH1',  0, 25),
(10,'Pune-WH1',  55, 10);

INSERT INTO orders (order_id, user_id, order_date, status, shipping_address) VALUES
(1, 1, '2024-01-05 10:20', 'DELIVERED', '12 MG Road, Pune'),
(2, 2, '2024-01-08 14:00', 'DELIVERED', '45 Park St, Kolkata'),
(3, 1, '2024-01-15 09:30', 'SHIPPED',   '12 MG Road, Pune'),
(4, 3, '2024-01-20 16:45', 'PAID',      '9 Lake View, Bengaluru'),
(5, 4, '2024-01-22 11:00', 'CANCELLED', '3 Green Ave, Hyderabad'),
(6, 5, '2024-02-01 08:15', 'DELIVERED', '77 Sea Road, Mumbai'),
(7, 6, '2024-02-03 19:20', 'PENDING',   '21 Hill Rd, Chennai'),
(8, 1, '2024-02-10 12:00', 'DELIVERED', '12 MG Road, Pune'),
(9, 7, '2024-02-14 15:30', 'PAID',      '5 Central Ave, Delhi'),
(10,8, '2024-02-18 13:10', 'DELIVERED', '8 River Rd, Ahmedabad');
SELECT setval('orders_order_id_seq', 10);

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
(1, 1, 1, 45999.00), (1, 9, 1, 3499.00),
(2, 5, 2,  1299.00), (2, 7, 1, 2499.00),
(3, 3, 1, 89999.00),
(4, 6, 1,  1799.00), (4, 8, 1, 1499.00),
(5, 2, 1, 29999.00),
(6, 4, 1, 74999.00), (6, 10,1,  799.00),
(7, 9, 2,  3499.00),
(8, 1, 1, 45999.00),
(9, 3, 1, 89999.00), (9, 9, 1, 3499.00),
(10,5, 3,  1299.00);

INSERT INTO payments (order_id, payment_date, amount, payment_method, status) VALUES
(1, '2024-01-05 10:25', 49498.00, 'CARD', 'SUCCESS'),
(2, '2024-01-08 14:05',  4097.00, 'UPI',  'SUCCESS'),
(3, '2024-01-15 09:35', 89999.00, 'CARD', 'SUCCESS'),
(4, '2024-01-20 16:50',  3298.00, 'UPI',  'SUCCESS'),
(5, NULL,               29999.00, 'CARD', 'FAILED'),
(6, '2024-02-01 08:20', 75798.00, 'NETBANKING', 'SUCCESS'),
(7, NULL,                6998.00, 'COD',  'PENDING'),
(8, '2024-02-10 12:05', 45999.00, 'CARD', 'SUCCESS'),
(9, '2024-02-14 15:35', 93498.00, 'UPI',  'SUCCESS'),
(10,'2024-02-18 13:15',  3897.00, 'WALLET','SUCCESS');

INSERT INTO reviews (product_id, user_id, rating, review_text, review_date) VALUES
(1, 1, 5, 'Excellent phone, great camera.', '2024-01-12 10:00'),
(9, 1, 4, 'Good sound, battery could be better.', '2024-01-12 10:05'),
(5, 2, 4, 'Nice fit and comfortable.', '2024-01-10 09:00'),
(3, 4, 5, 'Blazing fast laptop.', '2024-01-25 18:00'),
(4, 5, 3, 'Runs hot under load.', '2024-02-05 20:00'),
(1, 7, 2, 'Received a defective unit.', '2024-02-16 11:00');
