-- ============================================================================
-- banking_db — canonical sample database for the SQL Mastery Course
-- Used in: Transactions, Locks & Concurrency, Stored Procedures, Cursors,
-- Triggers (audit log), Project 2
-- Dialect: PostgreSQL (primary)
-- ============================================================================

DROP SCHEMA IF EXISTS banking_db CASCADE;
CREATE SCHEMA banking_db;
SET search_path TO banking_db;

CREATE TABLE customers (
    customer_id  SERIAL PRIMARY KEY,
    first_name   VARCHAR(50) NOT NULL,
    last_name    VARCHAR(50) NOT NULL,
    email        VARCHAR(150) NOT NULL UNIQUE,
    dob          DATE NOT NULL,
    created_at   TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
    account_id    SERIAL PRIMARY KEY,
    customer_id   INT NOT NULL REFERENCES customers(customer_id),
    account_type  VARCHAR(20) NOT NULL CHECK (account_type IN ('SAVINGS','CURRENT','FIXED_DEPOSIT')),
    balance       NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
    opened_date   DATE NOT NULL,
    status        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED'))
);

CREATE TABLE transactions (
    transaction_id     BIGSERIAL PRIMARY KEY,
    account_id         INT NOT NULL REFERENCES accounts(account_id),
    transaction_type   VARCHAR(20) NOT NULL CHECK (transaction_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT')),
    amount             NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    transaction_date   TIMESTAMP NOT NULL DEFAULT now(),
    related_account_id INT REFERENCES accounts(account_id),
    description        VARCHAR(250)
);

CREATE TABLE loans (
    loan_id        SERIAL PRIMARY KEY,
    customer_id    INT NOT NULL REFERENCES customers(customer_id),
    loan_amount    NUMERIC(14,2) NOT NULL CHECK (loan_amount > 0),
    interest_rate  NUMERIC(5,2) NOT NULL CHECK (interest_rate >= 0),
    start_date     DATE NOT NULL,
    term_months    INT NOT NULL CHECK (term_months > 0),
    status         VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CLOSED','DEFAULTED'))
);

-- Audit table used throughout the Triggers chapter
CREATE TABLE audit_log (
    audit_id     BIGSERIAL PRIMARY KEY,
    table_name   VARCHAR(50) NOT NULL,
    operation    VARCHAR(10) NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    row_pk       TEXT NOT NULL,
    changed_by   VARCHAR(100) NOT NULL DEFAULT current_user,
    changed_at   TIMESTAMP NOT NULL DEFAULT now(),
    old_data     JSONB,
    new_data     JSONB
);

-- ============================================================================
-- SEED DATA
-- ============================================================================

INSERT INTO customers (customer_id, first_name, last_name, email, dob) VALUES
(1,'Ravi','Shankar','ravi.shankar@mail.com','1985-04-12'),
(2,'Neha','Agarwal','neha.agarwal@mail.com','1990-08-25'),
(3,'Suresh','Menon','suresh.menon@mail.com','1978-11-02'),
(4,'Kavita','Desai','kavita.desai@mail.com','1995-01-30'),
(5,'Manoj','Tiwari','manoj.tiwari@mail.com','1988-06-18');
SELECT setval('customers_customer_id_seq', 5);

INSERT INTO accounts (account_id, customer_id, account_type, balance, opened_date, status) VALUES
(1, 1, 'SAVINGS', 150000.00, '2015-01-10', 'ACTIVE'),
(2, 1, 'CURRENT',  50000.00, '2018-03-15', 'ACTIVE'),
(3, 2, 'SAVINGS',  80000.00, '2019-07-22', 'ACTIVE'),
(4, 3, 'SAVINGS', 300000.00, '2012-02-05', 'ACTIVE'),
(5, 3, 'FIXED_DEPOSIT', 500000.00, '2020-01-01', 'ACTIVE'),
(6, 4, 'SAVINGS',  20000.00, '2022-05-10', 'ACTIVE'),
(7, 5, 'CURRENT',   5000.00, '2021-09-01', 'FROZEN');
SELECT setval('accounts_account_id_seq', 7);

INSERT INTO transactions (account_id, transaction_type, amount, transaction_date, related_account_id, description) VALUES
(1, 'DEPOSIT',      20000.00, '2024-01-02 10:00', NULL, 'Salary credit'),
(1, 'WITHDRAWAL',    5000.00, '2024-01-05 12:00', NULL, 'ATM withdrawal'),
(2, 'DEPOSIT',       8000.00, '2024-01-06 09:00', NULL, 'Client payment'),
(3, 'DEPOSIT',      15000.00, '2024-01-10 11:00', NULL, 'Salary credit'),
(1, 'TRANSFER_OUT', 10000.00, '2024-01-15 15:00', 3, 'Transfer to Neha'),
(3, 'TRANSFER_IN',  10000.00, '2024-01-15 15:00', 1, 'Transfer from Ravi'),
(4, 'WITHDRAWAL',   25000.00, '2024-01-20 14:00', NULL, 'Cash withdrawal'),
(6, 'DEPOSIT',       5000.00, '2024-02-01 10:30', NULL, 'Cash deposit');

INSERT INTO loans (loan_id, customer_id, loan_amount, interest_rate, start_date, term_months, status) VALUES
(1, 1, 500000.00, 8.50, '2022-01-01', 60, 'ACTIVE'),
(2, 3, 1200000.00, 7.75, '2021-06-01', 120, 'ACTIVE'),
(3, 4, 300000.00, 9.25, '2023-03-01', 36, 'ACTIVE'),
(4, 2, 150000.00, 8.00, '2019-01-01', 24, 'CLOSED');
SELECT setval('loans_loan_id_seq', 4);
