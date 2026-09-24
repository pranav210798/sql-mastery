# Project 2 — Core Banking System

> **Database:** `banking_db` (see `/databases/banking_db.sql`)
> **Dialect:** PostgreSQL (primary). Notes on Oracle/SQL Server/MySQL divergences are called out where the syntax genuinely differs (mostly around procedures, `FOR UPDATE`, and JSON types).

---

## 1. Project Brief

You are the database engineer for **Sahyadri Retail Bank**, a mid-sized bank rolling out a new core-banking data layer. The application team has already built the customer-facing web and mobile apps; your job is the transactional heart of the system — the part that must never lose a rupee, never double-spend, and never let two tellers overdraw the same account at the same instant.

The bank's compliance officer has given you ten hard functional requirements. Every one of them exists because something similar has gone wrong at a real bank at some point in history.

| # | Requirement | Why it matters |
|---|---|---|
| FR-1 | **Open an account** with an initial deposit, validating the deposit is positive and the customer exists. | Prevents "ghost" zero-value or negative-balance accounts from ever being created. |
| FR-2 | **Atomic fund transfer** between two accounts, rejecting the transfer if funds are insufficient or either account is frozen. | A transfer must be all-or-nothing — money must never vanish or be duplicated. |
| FR-3 | **Deposit / withdraw** with overdraft rules that differ per account type. | CURRENT accounts are working-capital accounts and may dip slightly negative; SAVINGS and FIXED_DEPOSIT must never go negative. |
| FR-4 | **Monthly interest** credited to all eligible active accounts in a single batch job. | Interest posting runs against tens of thousands of accounts nightly — it must be efficient, not row-by-row. |
| FR-5 | **Loan application** processing with an eligibility check before the loan is created. | The bank must not create loan records for customers who fail basic underwriting rules. |
| FR-6 | **Freeze / unfreeze** an account, and guarantee that a frozen account rejects all deposits, withdrawals, and transfers. | Used for fraud holds and legal holds — must be airtight. |
| FR-7 | **Account statement** for an arbitrary date range. | The single most common customer support and self-service request. |
| FR-8 | **Full audit trail** of every balance-changing update, with before/after values. | Regulatory requirement — every balance change must be forensically reconstructable. |
| FR-9 | **Prevent concurrent double-spending** — two simultaneous withdrawals must never both succeed if only one can be covered by the balance. | The classic "two ATM withdrawals at the same second" race condition. |
| FR-10 | **Detect at-risk loans** — loans that are behind schedule, past maturity while still open, or otherwise need a collections review. | Feeds the collections team's daily worklist. |

Everything below is built against the exact schema and seed data already loaded by `banking_db.sql`.

---

## 2. Schema Recap

We use `banking_db` exactly as defined — no changes to `customers`, `accounts`, `transactions`, `loans`, or `audit_log`.

```
customers(customer_id PK, first_name, last_name, email UNIQUE, dob, created_at)
accounts(account_id PK, customer_id FK, account_type CHECK IN (SAVINGS,CURRENT,FIXED_DEPOSIT),
         balance NUMERIC(14,2) CHECK (>=0), opened_date, status CHECK IN (ACTIVE,FROZEN,CLOSED))
transactions(transaction_id PK, account_id FK, transaction_type CHECK IN (DEPOSIT,WITHDRAWAL,TRANSFER_IN,TRANSFER_OUT),
             amount CHECK (>0), transaction_date, related_account_id FK, description)
loans(loan_id PK, customer_id FK, loan_amount, interest_rate, start_date, term_months, status CHECK IN (ACTIVE,CLOSED,DEFAULTED))
audit_log(audit_id PK, table_name, operation CHECK IN (INSERT,UPDATE,DELETE), row_pk, changed_by, changed_at, old_data JSONB, new_data JSONB)
```

**Seed data reminder** (used throughout the worked examples below):

| account_id | customer | type | balance | status |
|---|---|---|---|---|
| 1 | Ravi Shankar | SAVINGS | 150,000.00 | ACTIVE |
| 2 | Ravi Shankar | CURRENT | 50,000.00 | ACTIVE |
| 3 | Neha Agarwal | SAVINGS | 80,000.00 | ACTIVE |
| 4 | Suresh Menon | SAVINGS | 300,000.00 | ACTIVE |
| 5 | Suresh Menon | FIXED_DEPOSIT | 500,000.00 | ACTIVE |
| 6 | Kavita Desai | SAVINGS | 20,000.00 | ACTIVE |
| 7 | Manoj Tiwari | CURRENT | 5,000.00 | **FROZEN** |

| loan_id | customer | amount | rate | term | status |
|---|---|---|---|---|---|
| 1 | Ravi Shankar | 500,000.00 | 8.50% | 60 mo | ACTIVE |
| 2 | Suresh Menon | 1,200,000.00 | 7.75% | 120 mo | ACTIVE |
| 3 | Kavita Desai | 300,000.00 | 9.25% | 36 mo | ACTIVE |
| 4 | Neha Agarwal | 150,000.00 | 8.00% | 24 mo | CLOSED |

### One proposed supporting table: `fraud_flags`

`accounts`/`transactions`/`loans`/`audit_log` cover everything the requirements ask for except one operational nicety: a place to park suspicious activity flagged by FR-9's concurrency guard or FR-10's loan-risk job, so a human can triage it without mining `audit_log` JSON. This is optional scaffolding, not a schema change to the given tables.

```sql
CREATE TABLE fraud_flags (
    flag_id         BIGSERIAL PRIMARY KEY,
    account_id      INT NOT NULL REFERENCES accounts(account_id),
    transaction_id  BIGINT REFERENCES transactions(transaction_id),
    flag_reason     VARCHAR(200) NOT NULL,
    flagged_at      TIMESTAMP NOT NULL DEFAULT now(),
    resolved        BOOLEAN NOT NULL DEFAULT FALSE
);
```

> **Important Note:** `fraud_flags` is a *suggested extension*, not required by any of the ten FRs. Every procedure below works correctly without it. It's included so you can see where an operational team would hook in.

---

## 3. Implementation

### 3.1 `transfer_funds` — atomic transfer with deadlock-safe locking (FR-2, FR-6, FR-8, FR-9)

This is the single most important procedure in the project. A transfer touches **two rows** in `accounts` and inserts **two rows** in `transactions`, and it must never leave the books unbalanced, and it must never deadlock against another transfer running the opposite direction at the same moment.

```plpgsql
CREATE OR REPLACE PROCEDURE transfer_funds(
    p_from_account INT,
    p_to_account   INT,
    p_amount       NUMERIC(14,2),
    p_changed_by   VARCHAR DEFAULT current_user
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_lock_first  INT;
    v_lock_second INT;
    v_from_bal    NUMERIC(14,2);
    v_from_status VARCHAR(20);
    v_from_type   VARCHAR(20);
    v_to_bal      NUMERIC(14,2);
    v_to_status   VARCHAR(20);
    v_min_balance NUMERIC(14,2);
BEGIN
    -- 1. Basic input validation, fails fast before any locks are taken.
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Source and destination account cannot be the same (account %).', p_from_account;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive, got %.', p_amount;
    END IF;

    -- 2. Always lock the LOWER account_id first. This is the deadlock-avoidance
    --    rule: every session, regardless of transfer direction, acquires locks
    --    in the same global order (ascending account_id). See 3.1.1 below for why.
    v_lock_first  := LEAST(p_from_account, p_to_account);
    v_lock_second := GREATEST(p_from_account, p_to_account);

    PERFORM 1 FROM accounts WHERE account_id = v_lock_first  FOR UPDATE;
    PERFORM 1 FROM accounts WHERE account_id = v_lock_second FOR UPDATE;

    -- 3. Re-read both rows now that we hold row locks on them — nobody else
    --    can change these balances underneath us until we COMMIT.
    SELECT balance, status, account_type INTO v_from_bal, v_from_status, v_from_type
      FROM accounts WHERE account_id = p_from_account;
    SELECT balance, status INTO v_to_bal, v_to_status
      FROM accounts WHERE account_id = p_to_account;

    IF v_from_bal IS NULL THEN
        RAISE EXCEPTION 'Source account % does not exist.', p_from_account;
    END IF;
    IF v_to_bal IS NULL THEN
        RAISE EXCEPTION 'Destination account % does not exist.', p_to_account;
    END IF;

    -- 4. Frozen/closed accounts reject every transaction (FR-6).
    IF v_from_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Source account % is % — transfer rejected.', p_from_account, v_from_status;
    END IF;
    IF v_to_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Destination account % is % — transfer rejected.', p_to_account, v_to_status;
    END IF;

    -- 5. Overdraft rule (shared with withdraw(), see 3.2): CURRENT accounts may
    --    go to -10,000; SAVINGS/FIXED_DEPOSIT must stay >= 0.
    v_min_balance := CASE WHEN v_from_type = 'CURRENT' THEN -10000.00 ELSE 0.00 END;
    IF v_from_bal - p_amount < v_min_balance THEN
        RAISE EXCEPTION 'Insufficient funds in account %: balance %, requested %, floor %.',
            p_from_account, v_from_bal, p_amount, v_min_balance;
    END IF;

    -- 6. Apply both sides of the transfer.
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_from_account;
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_to_account;

    -- 7. Two transaction legs, cross-referenced via related_account_id.
    INSERT INTO transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_from_account, 'TRANSFER_OUT', p_amount, p_to_account,
            format('Transfer to account %s', p_to_account));

    INSERT INTO transactions (account_id, transaction_type, amount, related_account_id, description)
    VALUES (p_to_account, 'TRANSFER_IN', p_amount, p_from_account,
            format('Transfer from account %s', p_from_account));

    -- 8. Audit trail (FR-8) — one row per account touched, with before/after JSON.
    INSERT INTO audit_log (table_name, operation, row_pk, changed_by, old_data, new_data)
    VALUES ('accounts', 'UPDATE', p_from_account::TEXT, p_changed_by,
            jsonb_build_object('balance', v_from_bal),
            jsonb_build_object('balance', v_from_bal - p_amount));

    INSERT INTO audit_log (table_name, operation, row_pk, changed_by, old_data, new_data)
    VALUES ('accounts', 'UPDATE', p_to_account::TEXT, p_changed_by,
            jsonb_build_object('balance', v_to_bal),
            jsonb_build_object('balance', v_to_bal + p_amount));

EXCEPTION
    WHEN OTHERS THEN
        -- Any failure anywhere above rolls back every change made in this
        -- procedure invocation (Postgres wraps a called procedure's statements
        -- in the caller's transaction, or its own if called at top level).
        RAISE NOTICE 'transfer_funds failed: %', SQLERRM;
        RAISE;
END;
$$;
```

**Line-by-line explanation**

1. **Same-account / non-positive amount checks** run before touching the database at all — cheapest possible rejection.
2. **`LEAST`/`GREATEST`** compute a canonical lock order independent of which account is "source" and which is "destination." This is the crux of the deadlock fix — see 3.1.1.
3. **Two `SELECT ... FOR UPDATE` statements**, issued in ascending `account_id` order, take row-level exclusive locks. `PERFORM 1 ... FOR UPDATE` is used purely to acquire the lock; the actual values are re-read immediately after in a second pass so the variable names stay attached to "from"/"to" rather than "first"/"second."
4. Re-select `balance`, `status`, `account_type` **after** the lock is held — this is the value guaranteed to be up to date, not whatever a caller might have read earlier.
5. **NULL checks** catch a non-existent account_id (a plain `SELECT` into a variable silently leaves it `NULL` when no row matches — you must check for this explicitly in PL/pgSQL).
6. **Status checks** enforce FR-6: FROZEN or CLOSED accounts fail every transfer, on either leg.
7. **Overdraft rule** shared with `withdraw()` — CURRENT accounts may float to −10,000; everything else must stay non-negative (also backstopped by the table's own `CHECK (balance >= 0)` for SAVINGS/FIXED_DEPOSIT, since those never get a negative floor here).
8. **Two balance updates** — debit then credit. Because we hold `FOR UPDATE` locks on both rows from step 2 onward, no concurrent transaction can read a stale balance in between.
9. **Two transaction rows**, `TRANSFER_OUT` / `TRANSFER_IN`, cross-linked with `related_account_id`, mirroring the seed data's own pattern (see transactions 5 and 6 in the seed).
10. **Two audit rows** capture old and new balance as JSONB, one per account touched — this is a manual audit insert inside business logic; §3.5 shows the trigger-based alternative that fires automatically for *any* UPDATE to `accounts`, including ones this procedure wouldn't know to log itself.
11. The `EXCEPTION WHEN OTHERS` block logs the error and **re-raises** it (`RAISE;` with no arguments re-raises the caught exception), which rolls back all work done in this call — nothing partially applied ever survives a failure.

> **⚠️ Warning:** Never lock accounts in "source, then destination" order. That order flips depending on which account initiated the transfer, and is exactly what causes deadlocks between two transfers running in opposite directions. Always normalize to ascending `account_id` (or another table-wide, direction-independent order) before locking.

#### 3.1.1 Why ascending-order locking prevents deadlock — a two-session timeline

Imagine Ravi transfers ₹5,000 from account 1 to account 3 (Session A), at the same moment Neha transfers ₹2,000 from account 3 to account 1 (Session B) — two transfers in **opposite directions between the same two accounts**, arriving within milliseconds of each other.

**Without** the ascending-order rule (each session locks "source" first):

| Time | Session A (1 → 3) | Session B (3 → 1) |
|---|---|---|
| t0 | `BEGIN` | `BEGIN` |
| t1 | `SELECT ... WHERE account_id=1 FOR UPDATE` → locks account 1 | |
| t2 | | `SELECT ... WHERE account_id=3 FOR UPDATE` → locks account 3 |
| t3 | `SELECT ... WHERE account_id=3 FOR UPDATE` → **blocks**, waiting on B's lock | |
| t4 | | `SELECT ... WHERE account_id=1 FOR UPDATE` → **blocks**, waiting on A's lock |
| t5 | **DEADLOCK**: A waits on B, B waits on A. Postgres's deadlock detector eventually kills one session with `ERROR: deadlock detected`. | |

**With** the ascending-order rule (both sessions always lock the lower `account_id` first, regardless of transfer direction):

| Time | Session A (1 → 3) | Session B (3 → 1) |
|---|---|---|
| t0 | `BEGIN` | `BEGIN` |
| t1 | `SELECT ... WHERE account_id=1 FOR UPDATE` → locks account 1 (LEAST(1,3)=1) | |
| t2 | | `SELECT ... WHERE account_id=1 FOR UPDATE` → **blocks**, waiting for A |
| t3 | `SELECT ... WHERE account_id=3 FOR UPDATE` → locks account 3 (GREATEST(1,3)=3) | *(still waiting)* |
| t4 | ...applies balances, inserts rows, `COMMIT` → releases both locks | *(still waiting)* |
| t5 | | lock on account 1 granted → proceeds to lock account 3 → completes normally |

No cycle can ever form, because every session that wants both locks approaches them in the same order — the second session simply queues behind the first for the *first* lock it needs, rather than each session holding one lock the other needs. This is the standard "lock ordering" deadlock-prevention technique, and it generalizes beyond two accounts: always sort every resource you're about to lock and acquire in that fixed order.

---

### 3.2 `deposit` / `withdraw` — overdraft rules per account type (FR-3, FR-6, FR-9)

```plpgsql
CREATE OR REPLACE PROCEDURE deposit(
    p_account_id INT,
    p_amount     NUMERIC(14,2),
    p_changed_by VARCHAR DEFAULT current_user
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status  VARCHAR(20);
    v_balance NUMERIC(14,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Deposit amount must be positive, got %.', p_amount;
    END IF;

    SELECT status, balance INTO v_status, v_balance
      FROM accounts WHERE account_id = p_account_id
      FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Account % does not exist.', p_account_id;
    ELSIF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Account % is % — deposits are rejected.', p_account_id, v_status;
    END IF;

    UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_account_id;

    INSERT INTO transactions (account_id, transaction_type, amount, description)
    VALUES (p_account_id, 'DEPOSIT', p_amount, 'Deposit');

    INSERT INTO audit_log (table_name, operation, row_pk, changed_by, old_data, new_data)
    VALUES ('accounts', 'UPDATE', p_account_id::TEXT, p_changed_by,
            jsonb_build_object('balance', v_balance),
            jsonb_build_object('balance', v_balance + p_amount));
END;
$$;


CREATE OR REPLACE PROCEDURE withdraw(
    p_account_id INT,
    p_amount     NUMERIC(14,2),
    p_changed_by VARCHAR DEFAULT current_user
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status      VARCHAR(20);
    v_type        VARCHAR(20);
    v_balance     NUMERIC(14,2);
    v_min_balance NUMERIC(14,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Withdrawal amount must be positive, got %.', p_amount;
    END IF;

    -- FOR UPDATE here is what makes FR-9 (no double-spend) hold — see 3.6.
    SELECT status, account_type, balance INTO v_status, v_type, v_balance
      FROM accounts WHERE account_id = p_account_id
      FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Account % does not exist.', p_account_id;
    ELSIF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Account % is % — withdrawals are rejected.', p_account_id, v_status;
    END IF;

    -- Overdraft rule (FR-3): CURRENT accounts may float to -10,000;
    -- SAVINGS and FIXED_DEPOSIT must never go below 0.
    v_min_balance := CASE WHEN v_type = 'CURRENT' THEN -10000.00 ELSE 0.00 END;

    IF v_balance - p_amount < v_min_balance THEN
        RAISE EXCEPTION 'Insufficient funds: account % balance %, requested %, floor %.',
            p_account_id, v_balance, p_amount, v_min_balance;
    END IF;

    UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_account_id;

    INSERT INTO transactions (account_id, transaction_type, amount, description)
    VALUES (p_account_id, 'WITHDRAWAL', p_amount, 'Withdrawal');

    INSERT INTO audit_log (table_name, operation, row_pk, changed_by, old_data, new_data)
    VALUES ('accounts', 'UPDATE', p_account_id::TEXT, p_changed_by,
            jsonb_build_object('balance', v_balance),
            jsonb_build_object('balance', v_balance - p_amount));
END;
$$;
```

**Worked overdraft examples**, against seed data:

| Call | Account | Type | Balance before | Floor | Result |
|---|---|---|---|---|---|
| `CALL withdraw(2, 55000)` | 2 | CURRENT | 50,000.00 | −10,000.00 | **Succeeds** → new balance −5,000.00 (within floor) |
| `CALL withdraw(2, 65000)` | 2 | CURRENT | 50,000.00 | −10,000.00 | **Fails** → −15,000.00 would breach the −10,000 floor |
| `CALL withdraw(1, 160000)` | 1 | SAVINGS | 150,000.00 | 0.00 | **Fails** → SAVINGS cannot go negative at all |
| `CALL deposit(7, 1000)` | 7 | CURRENT | 5,000.00 | n/a | **Fails** → account 7 is FROZEN, rejected before the overdraft check even runs |

> **Important Note:** The overdraft floor check happens *after* the frozen/closed check and *after* the row is locked — order matters. Locking first (via `FOR UPDATE`) means the balance you check against is guaranteed current; checking status before the floor means a frozen account never even gets an overdraft evaluation, it's just flatly rejected.

---

### 3.3 `apply_monthly_interest` — set-based batch interest posting (FR-4)

```sql
CREATE OR REPLACE PROCEDURE apply_monthly_interest()
LANGUAGE plpgsql
AS $$
BEGIN
    -- One UPDATE, one pass over the table, rate keyed off account_type via CASE.
    -- CURRENT accounts are excluded entirely (no interest on transactional accounts).
    UPDATE accounts
       SET balance = ROUND(
             balance * (1 + CASE account_type
                               WHEN 'SAVINGS'       THEN 0.0050   -- 0.50% / month
                               WHEN 'FIXED_DEPOSIT' THEN 0.0058   -- 0.58% / month
                               ELSE 0
                             END), 2)
     WHERE status = 'ACTIVE'
       AND account_type IN ('SAVINGS', 'FIXED_DEPOSIT');

    -- One audit row per interest run per account, using a set-based INSERT ... SELECT
    -- rather than looping — same principle applied to the audit write.
    INSERT INTO audit_log (table_name, operation, row_pk, changed_by, old_data, new_data)
    SELECT 'accounts', 'UPDATE', account_id::TEXT, current_user,
           jsonb_build_object('balance', balance / (1 + CASE account_type
                                   WHEN 'SAVINGS' THEN 0.0050 WHEN 'FIXED_DEPOSIT' THEN 0.0058 ELSE 0 END)),
           jsonb_build_object('balance', balance)
      FROM accounts
     WHERE status = 'ACTIVE' AND account_type IN ('SAVINGS', 'FIXED_DEPOSIT');
END;
$$;
```

**Expected effect on seed data** (illustrative, one run):

| account_id | type | balance before | rate | balance after |
|---|---|---|---|---|
| 1 | SAVINGS | 150,000.00 | 0.50% | 150,750.00 |
| 3 | SAVINGS | 80,000.00 | 0.50% | 80,400.00 |
| 4 | SAVINGS | 300,000.00 | 0.50% | 301,500.00 |
| 6 | SAVINGS | 20,000.00 | 0.50% | 20,100.00 |
| 5 | FIXED_DEPOSIT | 500,000.00 | 0.58% | 502,900.00 |
| 2, 7 | CURRENT | — | — | unchanged |

**Set-based vs. cursor: why the `UPDATE` wins here**

A naive first draft of this job looks like:

```plpgsql
-- NAIVE — do not use for a batch job
DECLARE
    v_rec RECORD;
    v_rate NUMERIC;
BEGIN
    FOR v_rec IN SELECT account_id, account_type, balance FROM accounts
                  WHERE status = 'ACTIVE' AND account_type IN ('SAVINGS','FIXED_DEPOSIT')
    LOOP
        v_rate := CASE v_rec.account_type WHEN 'SAVINGS' THEN 0.0050 ELSE 0.0058 END;
        UPDATE accounts SET balance = ROUND(balance * (1 + v_rate), 2)
         WHERE account_id = v_rec.account_id;
        -- ...plus a per-row audit_log INSERT here
    END LOOP;
END;
```

Both versions are logically correct on this seed data — the difference is entirely about *cost at scale*:

- The cursor version issues **one `UPDATE` statement per account** — for a real bank with millions of savings accounts, that's millions of round trips through the planner/executor, millions of separate index lookups by `account_id`, and millions of separate row locks taken and released one at a time.
- The set-based `UPDATE` issues **one statement**, planned once, executed as a single scan (or index scan on `status`/`account_type` if indexed) that acquires all its row locks together and writes once. The database's executor is specifically optimized for bulk row-at-a-time internal processing — it's the *client-server round trip and per-statement overhead* the cursor version pays for uselessly.
- The set-based version is also **easier to reason about transactionally**: it's one atomic statement — either the whole batch applies or none of it does (barring an explicit savepoint scheme in the cursor version to get the same guarantee).

> **Important Note:** Reach for a cursor only when a row's processing genuinely depends on procedural logic that can't be expressed as a single set-based expression (e.g., calling out to an external service per row, or a recursive dependency between rows). Interest posting by a simple rate table is the textbook case *against* a cursor — Chapter 21 covers exactly this trade-off in depth.

---

### 3.4 `process_loan_application` — eligibility check with OUT parameters (FR-5, FR-8)

```plpgsql
CREATE OR REPLACE PROCEDURE process_loan_application(
    p_customer_id   INT,
    p_loan_amount   NUMERIC(14,2),
    p_interest_rate NUMERIC(5,2),
    p_term_months   INT,
    OUT p_success   BOOLEAN,
    OUT p_message   VARCHAR,
    OUT p_loan_id   INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_active_balance   NUMERIC(14,2);
    v_defaulted_count  INT;
    v_active_loan_cnt  INT;
BEGIN
    p_success := FALSE;
    p_loan_id := NULL;

    -- Basic input validation
    IF p_loan_amount IS NULL OR p_loan_amount <= 0 THEN
        p_message := 'Loan amount must be positive.';
        RETURN;
    END IF;
    IF p_term_months IS NULL OR p_term_months <= 0 THEN
        p_message := 'Loan term must be a positive number of months.';
        RETURN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
        p_message := format('Customer %s does not exist.', p_customer_id);
        RETURN;
    END IF;

    -- Eligibility rule 1: no customer with a DEFAULTED loan on record may borrow again.
    SELECT COUNT(*) INTO v_defaulted_count
      FROM loans WHERE customer_id = p_customer_id AND status = 'DEFAULTED';
    IF v_defaulted_count > 0 THEN
        p_message := 'Customer has a defaulted loan on record — application declined.';
        RETURN;
    END IF;

    -- Eligibility rule 2: cap total requested loan at 5x the customer's combined
    -- active-account balance (a simple affordability proxy).
    SELECT COALESCE(SUM(balance), 0) INTO v_active_balance
      FROM accounts WHERE customer_id = p_customer_id AND status = 'ACTIVE';

    IF v_active_balance = 0 THEN
        p_message := 'Customer has no active accounts on file — cannot assess affordability.';
        RETURN;
    END IF;

    IF p_loan_amount > v_active_balance * 5 THEN
        p_message := format(
            'Requested amount %s exceeds 5x active balance %s — application declined.',
            p_loan_amount, v_active_balance);
        RETURN;
    END IF;

    -- Eligibility rule 3: no more than 2 concurrently ACTIVE loans per customer.
    SELECT COUNT(*) INTO v_active_loan_cnt
      FROM loans WHERE customer_id = p_customer_id AND status = 'ACTIVE';
    IF v_active_loan_cnt >= 2 THEN
        p_message := 'Customer already has 2 active loans — application declined.';
        RETURN;
    END IF;

    -- All checks passed — create the loan.
    INSERT INTO loans (customer_id, loan_amount, interest_rate, start_date, term_months, status)
    VALUES (p_customer_id, p_loan_amount, p_interest_rate, CURRENT_DATE, p_term_months, 'ACTIVE')
    RETURNING loan_id INTO p_loan_id;

    INSERT INTO audit_log (table_name, operation, row_pk, changed_by, new_data)
    VALUES ('loans', 'INSERT', p_loan_id::TEXT, current_user,
            jsonb_build_object('customer_id', p_customer_id, 'loan_amount', p_loan_amount,
                                'interest_rate', p_interest_rate, 'term_months', p_term_months));

    p_success := TRUE;
    p_message := format('Loan % created successfully.', p_loan_id);
END;
$$;
```

Example calls against seed data:

```sql
-- Manoj Tiwari (customer 5) has one account (7, CURRENT, 5,000, FROZEN — not ACTIVE)
-- => no active-balance on file => declined
CALL process_loan_application(5, 100000, 9.00, 24, NULL, NULL, NULL);
-- p_success = FALSE, p_message = 'Customer has no active accounts on file...'

-- Suresh Menon (customer 3) already has 1 ACTIVE loan and active balances of
-- 300,000 + 500,000 = 800,000 => 5x cap = 4,000,000
CALL process_loan_application(3, 2000000, 8.25, 84, NULL, NULL, NULL);
-- p_success = TRUE (2,000,000 <= 4,000,000, and only 1 active loan so far)
```

---

### 3.5 Trigger-based audit logging on `accounts` (FR-8)

The manual `INSERT INTO audit_log` calls inside §3.1–3.3 only fire for balance changes that happen to go through *those* procedures. A trigger closes the gap for **every** update to `accounts`, no matter how it's made (including an ad-hoc `UPDATE` run directly by a DBA).

```sql
CREATE OR REPLACE FUNCTION fn_audit_accounts()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit_log (table_name, operation, row_pk, changed_by, old_data, new_data)
    VALUES (
        'accounts',
        'UPDATE',
        OLD.account_id::TEXT,
        current_user,
        to_jsonb(OLD),
        to_jsonb(NEW)
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_accounts_audit
AFTER UPDATE ON accounts
FOR EACH ROW
WHEN (OLD.* IS DISTINCT FROM NEW.*)
EXECUTE FUNCTION fn_audit_accounts();
```

- **`AFTER UPDATE ... FOR EACH ROW`**: fires once per row actually changed, after the update has been applied (so `NEW` reflects the final committed values within the transaction).
- **`to_jsonb(OLD)` / `to_jsonb(NEW)`**: captures the *entire row*, not just `balance` — useful because a status change (`ACTIVE → FROZEN`) is just as auditable as a balance change, and this trigger catches both without extra code.
- **`WHEN (OLD.* IS DISTINCT FROM NEW.*)`**: skips no-op updates (e.g., an `UPDATE accounts SET balance = balance` that changes nothing) so the audit log doesn't fill with rows that record no real change. `IS DISTINCT FROM` (rather than `<>`) correctly treats `NULL = NULL` as "not distinct," which matters for nullable columns.

> **⚠️ Warning:** If both the procedure-level manual audit insert (§3.1–3.3) *and* this trigger are active at the same time, every balance change gets logged **twice** — once by the procedure's explicit `INSERT`, once by the trigger firing on the `UPDATE` the procedure just issued. In a real deployment, pick one mechanism, not both. This project shows both because each is the idiomatic answer to a different chapter (procedures vs. triggers) — treat the manual inserts in §3.1–3.4 as illustrating the audit *pattern*, and the trigger here as the production-grade way to guarantee full coverage.

---

### 3.6 Two concurrent withdrawals from account 1 — how `FOR UPDATE` prevents overdraft (FR-9)

Account 1 (Ravi, SAVINGS) has a balance of **150,000.00** and a floor of **0** (SAVINGS cannot go negative). Suppose two withdrawal requests for **100,000.00 each** arrive within the same millisecond — only one can possibly be honored, since 200,000 > 150,000.

**Without locking** (reading balance with a plain `SELECT`, no `FOR UPDATE`):

| Time | Session A: `withdraw(1, 100000)` | Session B: `withdraw(1, 100000)` |
|---|---|---|
| t0 | `SELECT balance FROM accounts WHERE account_id=1` → reads 150,000.00 | |
| t1 | | `SELECT balance FROM accounts WHERE account_id=1` → **also** reads 150,000.00 (A hasn't committed yet) |
| t2 | Check: 150,000 − 100,000 = 50,000 ≥ 0 → **passes** | Check: 150,000 − 100,000 = 50,000 ≥ 0 → **passes** |
| t3 | `UPDATE accounts SET balance = 50000` | |
| t4 | `COMMIT` | `UPDATE accounts SET balance = 50000` (overwrites A's result, unaware of it) |
| t5 | | `COMMIT` |
| Result | **Both withdrawals succeeded.** Final balance: 50,000.00 — but 200,000.00 left the bank against a 150,000.00 balance. **This is the double-spend race**, and it also silently lost A's debit (a lost update). |

**With `SELECT ... FOR UPDATE`** (as written in §3.2's `withdraw` procedure):

| Time | Session A: `withdraw(1, 100000)` | Session B: `withdraw(1, 100000)` |
|---|---|---|
| t0 | `SELECT ... WHERE account_id=1 FOR UPDATE` → acquires row lock, reads 150,000.00 | |
| t1 | | `SELECT ... WHERE account_id=1 FOR UPDATE` → **blocks**, waiting for A's lock |
| t2 | Check: 150,000 − 100,000 = 50,000 ≥ 0 → passes; `UPDATE ... balance = 50000`; inserts transaction/audit rows | *(still blocked)* |
| t3 | `COMMIT` → releases the lock | lock granted → re-reads balance, now sees the **committed** 50,000.00 |
| t4 | | Check: 50,000 − 100,000 = −50,000 < 0 → **fails**, `RAISE EXCEPTION 'Insufficient funds...'` |
| Result | **Exactly one withdrawal succeeds.** Final balance: 50,000.00, matching the one transaction actually recorded. The second request is correctly and safely rejected. | |

The lock doesn't prevent B from *attempting* the withdrawal — it prevents B from evaluating the balance check against a **stale** value. B is forced to wait until A's transaction fully commits (or rolls back), and then B's `SELECT` re-reads the truth as it now stands. This is exactly why every balance-mutating procedure in this project (`deposit`, `withdraw`, `transfer_funds`) takes its `FOR UPDATE` lock **before** evaluating any balance check, never after.

---

### 3.7 Reporting query 1 — full account statement for a date range (FR-7)

```sql
-- Account 1's statement for January 2024
SELECT
    a.account_id,
    a.account_type,
    c.first_name || ' ' || c.last_name AS account_holder,
    t.transaction_id,
    t.transaction_type,
    t.amount,
    t.transaction_date,
    t.related_account_id,
    t.description,
    -- running balance within the statement window, oldest first
    SUM(
        CASE WHEN t.transaction_type IN ('DEPOSIT','TRANSFER_IN')  THEN  t.amount
             WHEN t.transaction_type IN ('WITHDRAWAL','TRANSFER_OUT') THEN -t.amount
        END
    ) OVER (PARTITION BY t.account_id ORDER BY t.transaction_date, t.transaction_id) AS running_change
FROM accounts a
JOIN customers c    ON c.customer_id = a.customer_id
JOIN transactions t ON t.account_id = a.account_id
WHERE a.account_id = 1
  AND t.transaction_date >= '2024-01-01'
  AND t.transaction_date <  '2024-02-01'
ORDER BY t.transaction_date, t.transaction_id;
```

Against the seed data, account 1's January 2024 statement returns exactly three rows: the `DEPOSIT` of 20,000.00 (Jan 2), the `WITHDRAWAL` of 5,000.00 (Jan 5), and the `TRANSFER_OUT` of 10,000.00 to account 3 (Jan 15) — with `running_change` showing +20,000.00, +15,000.00, +5,000.00 respectively (the net effect of that month's activity; it is *not* the account's absolute balance, since the statement window doesn't know the balance carried in from before Jan 1).

> **Important Note:** This query reports the **net change over the window**, not the account's all-time balance — a real statement also prints an "opening balance" line computed from all transactions *before* the window start, which is a good extension exercise (§4).

### 3.8 Reporting query 2 — at-risk loans (FR-10)

"At risk" here means either of two conditions on a still-`ACTIVE` loan:

1. **Past its scheduled maturity date but never closed** — the strongest possible signal something is wrong (a loan that should have finished amortizing hasn't been closed out).
2. **More than 85% of its term elapsed** — approaching maturity, worth a proactive check even if not yet overdue.

```sql
SELECT
    l.loan_id,
    c.first_name || ' ' || c.last_name           AS customer_name,
    l.loan_amount,
    l.interest_rate,
    l.start_date,
    l.term_months,
    (l.start_date + (l.term_months || ' months')::INTERVAL)::DATE AS maturity_date,
    -- whole months elapsed since the loan started, computed via date arithmetic
    (EXTRACT(YEAR  FROM age(CURRENT_DATE, l.start_date)) * 12
     + EXTRACT(MONTH FROM age(CURRENT_DATE, l.start_date)))::INT   AS months_elapsed,
    ROUND(
        100.0 * (EXTRACT(YEAR  FROM age(CURRENT_DATE, l.start_date)) * 12
                + EXTRACT(MONTH FROM age(CURRENT_DATE, l.start_date)))
        / l.term_months, 1)                                        AS pct_term_elapsed,
    CASE
        WHEN CURRENT_DATE > (l.start_date + (l.term_months || ' months')::INTERVAL)::DATE
            THEN 'PAST MATURITY — STILL ACTIVE'
        ELSE 'APPROACHING MATURITY'
    END AS risk_reason
FROM loans l
JOIN customers c ON c.customer_id = l.customer_id
WHERE l.status = 'ACTIVE'
  AND (
        CURRENT_DATE > (l.start_date + (l.term_months || ' months')::INTERVAL)::DATE
        OR
        (EXTRACT(YEAR  FROM age(CURRENT_DATE, l.start_date)) * 12
         + EXTRACT(MONTH FROM age(CURRENT_DATE, l.start_date))) / l.term_months::NUMERIC > 0.85
      )
ORDER BY pct_term_elapsed DESC;
```

Run on **2026-09-24**, against the seed data, this returns:

| loan_id | customer | amount | term | maturity_date | months_elapsed | pct_term_elapsed | risk_reason |
|---|---|---|---|---|---|---|---|
| 3 | Kavita Desai | 300,000.00 | 36 mo | 2026-03-01 | 42 | 116.7% | **PAST MATURITY — STILL ACTIVE** |
| 1 | Ravi Shankar | 500,000.00 | 60 mo | 2027-01-01 | 56 | 93.3% | APPROACHING MATURITY |

Loan 2 (Suresh Menon, 52.5% elapsed) and loan 4 (CLOSED, excluded by the `WHERE` clause) are correctly left off the worklist. Loan 3 is the headline finding: it matured six months ago and is still marked `ACTIVE` — exactly the kind of record a collections team needs surfaced immediately, and exactly why the report doesn't just filter on `pct_term_elapsed` alone (a loan can be short-term *and* already overdue, as here).

> **Important Note:** Because this query drives off `CURRENT_DATE`, the exact `months_elapsed` and `pct_term_elapsed` values will differ depending on the day you run it — the *shape* of the output (loan 3 flagged as past-maturity, loan 1 flagged as approaching) is what to focus on, not the literal percentages.

---

## 4. Things to Extend

Five follow-on exercises — no solutions provided, work them out yourself:

1. **Opening-balance statements.** Extend the account-statement query (§3.7) to compute a true opening balance (sum of all transactions strictly before the window start) and a true closing balance, so the statement reads like a real bank statement rather than just a net change over the window.
2. **Interest tiers.** Replace the flat 0.50%/0.58% rates in `apply_monthly_interest` with a tiered rate that pays a higher percentage above a balance threshold (e.g., 0.50% up to ₹1,00,000, 0.65% above that) — and think about whether this can still be done as a single set-based `UPDATE`.
3. **Standing instructions.** Design a table and a procedure for recurring scheduled transfers (e.g., "transfer ₹5,000 from account 2 to account 6 on the 1st of every month"), including what should happen if the source account can't cover it on the scheduled date.
4. **Loan repayment schedule.** `loans` currently has no amortization or repayment tracking at all. Design a `loan_repayments` table and a procedure that records a monthly EMI payment, and rework the at-risk report (§3.8) to use actual missed-payment data instead of the term-elapsed proxy used here.
5. **Row-level security for tellers.** Using PostgreSQL row-level security policies, restrict a "teller" database role so it can only view/modify accounts belonging to customers assigned to its branch (you'll need to imagine/add a `branch_id` somewhere), while a "manager" role can see everything.

---

## 5. What You Practiced

| Section | Concept | Course Chapter |
|---|---|---|
| §3.1 `transfer_funds`, §3.1.1 timeline | Multi-statement atomicity, `EXCEPTION` blocks, commit/rollback semantics | **Ch. 11 — Transactions** |
| §3.1.1 timeline, §3.6 concurrent withdrawals | Row-level locking, `SELECT ... FOR UPDATE`, deadlock avoidance via lock ordering | **Ch. 12 — Locks & Concurrency** |
| §3.1–§3.4 all procedures | `PROCEDURE` design, `IN`/`OUT` parameters, parameter validation, `RAISE EXCEPTION` | **Ch. 19 — Stored Procedures** |
| §3.3 `apply_monthly_interest` (set-based vs. naive loop) | Cursors vs. set-based `UPDATE`, when procedural row-by-row logic is (and isn't) justified | **Ch. 21 — Cursors** |
| §3.5 `trg_accounts_audit` | `AFTER UPDATE` row-level triggers, `to_jsonb(OLD/NEW)`, `IS DISTINCT FROM` in trigger conditions | **Ch. 22 — Triggers** |
| §3.7, §3.8 reporting queries | Window functions (`SUM() OVER`), date/interval arithmetic, multi-condition risk filtering | Cumulative — SQL fundamentals + aggregation chapters |

---

*End of Project 2. Project 3 builds on this same `banking_db` foundation to add reporting/analytics workloads (window functions, CTEs, and query performance tuning) on top of the transactional core built here.*
