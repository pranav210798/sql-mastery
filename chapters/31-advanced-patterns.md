# Chapter 31 — Advanced SQL Patterns

## Learning Objectives

By the end of this chapter you will be able to:

- Recognize a catalog of recurring, name-able SQL problems the moment you see them in a ticket or a design doc, instead of re-deriving a solution from scratch every time.
- Build cohort and retention analyses using self-referential window functions and CTEs — genuinely one of the hardest "plain SQL" analytical patterns to get right on the first try.
- Deduplicate rows correctly using three different techniques (`ROW_NUMBER()`, `DISTINCT ON`, `GROUP BY`) and choose between them based on portability and clarity.
- Design and populate a Slowly Changing Dimension (Type 1, 2, and 3) to preserve history the business actually cares about.
- Model valid-time ("as of") data correctly, including PostgreSQL's exclusion constraints to enforce non-overlapping time periods at the database level.
- Reconstruct historical state from an audit trail and from an append-only event log.
- Reason about soft deletes as a genuine design trade-off, not just "add a boolean column."
- Write safe, atomic upserts (`ON CONFLICT`, `ON DUPLICATE KEY UPDATE`, `MERGE`) and understand exactly why they close a race-condition window that naive check-then-act code leaves open.
- Design idempotent write operations that are safe to retry after a network failure — a non-negotiable requirement for reliable production systems.

## 31.0 Why This Chapter Exists

Every chapter so far has taught you a *tool*: a join type, a window function, an index type, a locking clause. This chapter is different — it teaches you **patterns**: named, recurring shapes of business problem that show up over and over across industries, each with a known-good SQL solution and known failure modes.

The difference matters because of how senior engineers actually work. A junior engineer facing "show me how many customers came back and ordered again" starts from a blank query editor. A senior engineer recognizes "this is cohort analysis" within seconds, recalls the shape of the solution (bucket by acquisition period, self-compare against subsequent activity, pivot by offset), and spends their thinking budget on the business-specific details, not on reinventing the technique. That recognition — pattern-matching a business ask to a known SQL shape — is most of what separates "writes queries" from "designs systems," and it is the last skill this book will build before you move into full projects and interview preparation.

Several of these patterns (top-N per group, gaps and islands, running totals) were already taught in full depth as **window function techniques** in Chapter 10, because they are fundamentally about `OVER (PARTITION BY ... ORDER BY ...)`. This chapter references those briefly and does not re-derive them — re-reading the same derivation twice would waste your time. The other patterns here (cohorts, retention, dedup, SCD, temporal modeling, event logs, soft deletes, upserts, idempotency) are either new techniques or new *applications* of techniques you already know, assembled the way you'll actually meet them in a real system.

> **Important Note:** This chapter deliberately mixes real data from `ecommerce_db`, `company_db`, `banking_db`, and `analytics_db` with a small number of **clearly labeled illustrative examples** where the canonical seed data is either too clean (no duplicates exist, so we manufacture some to teach deduplication) or too small in volume to show a pattern's value at realistic scale (cohort/retention tables look far more interesting with thousands of users than with the 8 hand-authored rows in `ecommerce_db.users`). Every illustrative block is marked **ILLUSTRATIVE DATA** so you never confuse it with the canonical schema.

---

## 31.1 Top-N Per Group *(covered in depth in Chapter 10)*

**The problem, in one line:** "Show me the top 3 highest-paid employees in each department" or "the best-selling product in each category." Naive solutions (`LIMIT` per group with a loop, or a self-join with a `COUNT` of how many rows outrank each candidate) are either procedural or quadratic.

**The pattern:** `ROW_NUMBER()` (or `RANK()`/`DENSE_RANK()` if ties should share a place) partitioned by the group column and ordered by the ranking metric, wrapped in an outer query that filters `WHERE rn <= N`. Chapter 10, §10.x ("Top-N Per Group") derives this fully against `company_db.employees`/`salaries` and `ecommerce_db.products`/`order_items`, including the `RANK()` vs `DENSE_RANK()` vs `ROW_NUMBER()` tie-breaking decision and why a plain `LIMIT` cannot do this at all once you need "top N *per group*" rather than "top N overall." If you have not read that section yet, do so before continuing — the rest of this chapter assumes you're fluent with it, because cohort analysis (§31.4) and event-table current-state derivation (§31.11) both reuse the exact same `ROW_NUMBER() ... WHERE rn = 1` idiom.

**Where it resurfaces in this chapter:** §31.5 (retention), §31.6 (deduplication), and §31.11 (event tables) are all, structurally, "top-1-per-group" in disguise — picking one row per partition by a tiebreaker. Recognizing that family resemblance is the whole point of a patterns catalog.

---

## 31.2 Gaps and Islands *(covered in depth in Chapter 10)*

**The problem, in one line:** given a sequence of dates or numbers, find the contiguous runs ("islands" — e.g., an employee's consecutive days of `PRESENT` attendance, or a sequence of order IDs with no missing numbers) and the missing values between them ("gaps" — e.g., days an employee was scheduled but has no attendance row at all).

**The pattern:** the classic solution subtracts a `ROW_NUMBER()` (ordered by the sequence column) from the sequence column itself (when the sequence is numeric/date-like); rows in the same island produce the same constant difference, which becomes a free grouping key. Chapter 10 derives this fully against `company_db.attendance`, including the row-number-subtraction trick, the `LAG()`-based alternative for detecting where a new island starts, and the difference between an "island" (a run of present values) and a "gap" (a run of absent/missing values) — they are two views of the same computation.

**Where it resurfaces in this chapter:** §31.9 (temporal reconstruction from an audit trail) and §31.10 (valid-time modeling) are conceptually gaps-and-islands problems turned inside out — instead of finding runs in a value column, you're finding (and must prevent) *gaps or overlaps* in a time-range column.

---

## 31.3 Running Totals *(covered in depth in Chapter 10)*

**The problem, in one line:** a cumulative sum (or cumulative count, min, max) as of each row — "running account balance after each transaction," "cumulative revenue by day."

**The pattern:** `SUM(amount) OVER (PARTITION BY account_id ORDER BY transaction_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`, with the frame clause controlling exactly which rows participate. Chapter 10 derives this fully against `banking_db.transactions`, including the difference between the default frame (`RANGE UNBOUNDED PRECEDING`, which behaves unexpectedly with ties on the `ORDER BY` column) and an explicit `ROWS` frame, and the related "moving average" variant (`ROWS BETWEEN N PRECEDING AND CURRENT ROW`).

**Where it resurfaces in this chapter:** the Type 2 SCD design in §31.7 and the temporal modeling in §31.10 both need to reconstruct "the value as of a point in time," which is the *inverse* query of a running total — instead of accumulating forward, you're picking the most recent prior value, typically with `ROW_NUMBER() ... ORDER BY effective_date DESC` rather than a `SUM`.

---

## 31.4 Cohort Analysis

### The business problem

Marketing and product teams constantly ask a version of this question: *"Of the users who signed up in a given month, how many came back and ordered again — one month later, two months later, and so on?"* This is **cohort analysis**: group ("cohort") users by a shared acquisition period (usually their signup month), then measure their subsequent behavior relative to that acquisition point, bucketed by how much time has elapsed ("month offset" or "period offset").

The output is normally displayed as a matrix: cohort month down the rows, month offset across the columns, and a count (or retention percentage) in each cell. This single view answers "are newer cohorts behaving better or worse than older ones?" — one of the most important questions a subscription or e-commerce business can ask.

### Why this is genuinely hard to write

Cohort analysis is harder than it looks for a specific structural reason: it requires comparing **each user's own first/anchor event against every one of their own subsequent events**, and only then aggregating across users. That's two levels of self-reference stacked on top of each other:

1. **Self-reference #1 — find the anchor.** You need, per user, either their signup date (easy — it's a column on `users`) or, in variants of this pattern, their *first order date* (requires `MIN(order_date)` per user — a self-referential aggregate over the same `orders` table you're about to scan again for repeat activity).
2. **Self-reference #2 — classify every other row relative to the anchor.** For every order a user places, you must compute *how far after their signup* it occurred, not how far after some fixed calendar date. This is a per-row, per-user calculation — the same `order_date` column is being compared against a different reference point (`created_at`) for every single user.
3. **Only after both self-references are resolved** does a normal `GROUP BY` become possible, because "cohort" and "month offset" are *derived* columns computed per row, not columns that exist in the schema.

A naive attempt — `GROUP BY DATE_TRUNC('month', o.order_date)` — throws away exactly the information the business asked for (it groups by *calendar* month, not by *months since signup*), and produces a report that cannot answer "how do 3-month-old cohorts compare to 1-month-old cohorts," which is the entire point of the exercise.

### Building the solution against `ecommerce_db`

We'll use `ecommerce_db.users.created_at` as the signup/acquisition date and `ecommerce_db.orders.order_date` as the activity we're measuring, and we'll define "repeat order" precisely as **any order that is not that user's very first order** — which is exactly the self-referential comparison described above.

```sql
-- Step 1: each user's cohort (signup month) and first-order date
WITH user_cohorts AS (
    SELECT
        user_id,
        DATE_TRUNC('month', created_at)::date AS cohort_month
    FROM ecommerce_db.users
),
first_orders AS (
    SELECT
        user_id,
        MIN(order_date) AS first_order_date
    FROM ecommerce_db.orders
    WHERE status <> 'CANCELLED'          -- a cancelled order was never fulfilled; don't count it as activity
    GROUP BY user_id
),

-- Step 2: classify every (non-cancelled) order as first vs. repeat, and compute its month offset from signup
classified_orders AS (
    SELECT
        o.order_id,
        o.user_id,
        uc.cohort_month,
        o.order_date,
        (fo.first_order_date = o.order_date)                                    AS is_first_order,
        ( (EXTRACT(YEAR  FROM o.order_date) - EXTRACT(YEAR  FROM uc.cohort_month)) * 12
        + (EXTRACT(MONTH FROM o.order_date) - EXTRACT(MONTH FROM uc.cohort_month))
        )::int                                                                   AS month_offset
    FROM ecommerce_db.orders o
    JOIN user_cohorts  uc ON uc.user_id = o.user_id
    JOIN first_orders  fo ON fo.user_id = o.user_id
    WHERE o.status <> 'CANCELLED'
)

-- Step 3: aggregate REPEAT orders only, by cohort and month offset
SELECT
    cohort_month,
    month_offset,
    COUNT(DISTINCT user_id) AS repeat_customers
FROM classified_orders
WHERE is_first_order = FALSE
GROUP BY cohort_month, month_offset
ORDER BY cohort_month, month_offset;
```

**Line-by-line:**

- `user_cohorts` truncates every user's `created_at` down to the first of the month — this is the cohort key. Two users who signed up on Jan 5 and Jan 28 both land in the `2023-01-01` cohort.
- `first_orders` computes, per user, the earliest non-cancelled order date. This is the anchor for "is this order a repeat?" It is a completely separate aggregation pass over `orders` from the one in Step 3 — this is self-reference #1.
- `classified_orders` joins both back to the raw order rows and computes two derived facts per order: whether it *is* the first order (`is_first_order`), and how many calendar months separate it from the user's *signup* (not their first order — note the offset is computed against `cohort_month`, i.e., signup, per the business question "months after signup," matching this pattern's typical framing). The month-offset arithmetic (`(year diff)*12 + (month diff)`) is the standard way to get an integer "months between two dates" in SQL, since there's no native `MONTHS_BETWEEN` in PostgreSQL (Oracle has `MONTHS_BETWEEN` natively — see the dialect note below).
- The final `SELECT` throws away every user's first order (`WHERE is_first_order = FALSE`) and counts, per cohort and offset, how many *distinct* users placed at least one repeat order in that offset. `COUNT(DISTINCT user_id)` matters — without `DISTINCT`, a user with two repeat orders in the same month offset would be double-counted.

### Real output against the canonical seed data

Run against the actual `ecommerce_db` seed rows, this query returns:

| cohort_month | month_offset | repeat_customers |
|---|---|---|
| 2023-01-01 | 12 | 1 |
| 2023-01-01 | 13 | 1 |

Only **user 1** (`arjun_k`, signed up 2023-01-05) ever placed more than one order: order #1 (2024-01-05, their first), order #3 (2024-01-15, a repeat 12 months after signup), and order #8 (2024-02-10, a repeat 13 months after signup). Every other user in the seed data placed exactly one order, so they contribute nothing to the repeat-order table — which is the *correct* answer for this dataset, not a bug in the query.

> **Important Note:** The offsets here (12 and 13) look unusual because the seed data is hand-authored for readability, not generated to simulate a realistic acquisition funnel — signups are spread across all of 2023 while all order activity is concentrated in Jan–Feb 2024. In a real production dataset with continuous signups and continuous order activity, month offsets naturally cluster around 0, 1, 2, 3 — this is a byproduct of our small teaching dataset, not a flaw in the technique.

### What this looks like at realistic scale — **ILLUSTRATIVE DATA**

To see why this pattern earns its keep in a real business, imagine the same query run against a store with thousands of monthly signups and continuous ordering activity. A typical resulting cohort **retention matrix** (repeat customers as a % of the cohort's original size) looks like this:

| cohort_month | size | month 0 | month 1 | month 2 | month 3 |
|---|---|---|---|---|---|
| 2024-01 | 1,200 | 100% | 34% | 22% | 18% |
| 2024-02 | 1,450 | 100% | 38% | 24% | — |
| 2024-03 | 1,600 | 100% | 41% | — | — |

Reading this matrix diagonally (down-and-right) shows whether retention is *improving* release over release — e.g., the March 2024 cohort retaining 41% into month 1 versus January's 34% suggests a product or marketing change between those cohorts is working. This is the entire commercial value of the pattern, and it is invisible in a flat "total repeat orders per month" report — which is precisely why product analytics teams build cohort dashboards rather than simple month-over-month totals.

### Common mistakes

> **⚠️ Warning — Common cohort-analysis mistakes:**
> 1. **Grouping by calendar month of the order instead of month offset from signup.** This produces a report where every cohort's activity bleeds into the same few calendar-month columns, making it impossible to compare cohorts of different ages on equal footing.
> 2. **Forgetting to exclude cancelled/failed orders** (or, depending on the business question, forgetting to *include* them) — decide explicitly and document it; this query filters `status <> 'CANCELLED'`, which is a judgment call, not a universal rule.
> 3. **Using `COUNT(user_id)` instead of `COUNT(DISTINCT user_id)`** in the final aggregation, silently inflating cohort sizes whenever a user has multiple orders in the same offset.
> 4. **Computing "months since signup" with date subtraction instead of the year/month arithmetic shown above.** `order_date - created_at` returns an `interval`/number of *days*, not calendar months, and gives wrong, non-uniform bucket boundaries (a 28-day gap and a 31-day gap can straddle a month boundary differently).

**Dialect note:** Oracle's `MONTHS_BETWEEN(date1, date2)` computes this directly (and returns a fractional value for partial months, so it's typically wrapped in `TRUNC()` or `FLOOR()`); SQL Server has no built-in month-diff function and commonly uses `DATEDIFF(month, date1, date2)`, which — like the manual arithmetic above — counts calendar-month *boundaries* crossed, not full 30-day periods elapsed.

### Practice variations

1. Rewrite the query to bucket by **week offset** instead of month offset (using `banking_db.customers.created_at` and `banking_db.transactions.transaction_date` as the cohort/activity pair instead).
2. Extend the query to also report cohort *size* (`COUNT(DISTINCT user_id)` from `user_cohorts`, independent of whether they ever ordered) alongside `repeat_customers`, so you can compute a percentage rather than a raw count.

---

## 31.5 Retention Analysis

### The business problem

Retention analysis answers a narrower, more operational version of the cohort question: *"Of the users who were active in week N, what fraction were still active in week N+1?"* This is the classic "N-day" or "N-week retention" metric that dashboards report as a single trending number (e.g., "week-1 retention is 42% this month, down from 45% last month"). Unlike cohort analysis, which segments by acquisition date, retention analysis here segments purely by **activity week relative to a fixed reference point per user** (typically their own signup), and measures the *transition rate* from one period to the next.

We'll compute this against `analytics_db.events`, using `SIGNUP` and `LOGIN` rows as the definition of "active."

### Why the naive approach fails

The tempting naive query is `SELECT week, COUNT(DISTINCT user_id) FROM events GROUP BY week` — but that only tells you *how many users were active each week*, not *what fraction of last week's active users came back this week*. Those are different questions: total weekly actives can stay flat even while retention collapses, if new signups exactly replace churned users every week. Answering the real question requires comparing **the same user's presence across two adjacent week buckets**, which means you need each user's activity weeks as a *set* you can self-join against a shifted copy of itself.

### Building the solution

```sql
-- Step 1: each user's signup timestamp (the reference point for "week number")
WITH signups AS (
    SELECT user_id, MIN(event_time) AS signup_time
    FROM analytics_db.events
    WHERE event_type = 'SIGNUP'
    GROUP BY user_id
),

-- Step 2: every (user, week_number) pair in which the user had a SIGNUP or LOGIN event
--         week_number 0 = the week of signup, 1 = one week later, etc.
user_active_weeks AS (
    SELECT DISTINCT
        e.user_id,
        FLOOR(EXTRACT(EPOCH FROM (e.event_time - s.signup_time)) / (7 * 86400))::int AS week_number
    FROM analytics_db.events e
    JOIN signups s ON s.user_id = e.user_id
    WHERE e.event_type IN ('SIGNUP', 'LOGIN')
      AND e.event_time >= s.signup_time
),

-- Step 3: self-join each user's week N against the SAME user's week N+1
week_transitions AS (
    SELECT
        w0.week_number,
        w0.user_id,
        (w1.user_id IS NOT NULL) AS retained_next_week
    FROM user_active_weeks w0
    LEFT JOIN user_active_weeks w1
           ON w1.user_id = w0.user_id
          AND w1.week_number = w0.week_number + 1
)

-- Step 4: aggregate the transition rate per week
SELECT
    week_number,
    COUNT(*)                                  AS active_users_week_n,
    SUM(CASE WHEN retained_next_week THEN 1 ELSE 0 END) AS retained_into_week_n_plus_1,
    ROUND(
        100.0 * SUM(CASE WHEN retained_next_week THEN 1 ELSE 0 END) / COUNT(*), 1
    ) AS retention_pct
FROM week_transitions
GROUP BY week_number
ORDER BY week_number;
```

**Line-by-line:**

- `signups` establishes, per user, the timestamp everything else is measured against — the reference point for "week 0."
- `user_active_weeks` converts every qualifying event into a `(user_id, week_number)` pair. `DISTINCT` matters: a user with three `LOGIN` events in the same week must contribute exactly one row for that week, or later counts would be inflated. The arithmetic (`EXTRACT(EPOCH FROM ...) / (7*86400)`, floored) converts a time difference into an integer week bucket — an alternative, arguably more readable form is `DATE_TRUNC('week', e.event_time) - DATE_TRUNC('week', s.signup_time)`.
- `week_transitions` is the self-join that makes the whole pattern work: for every `(user, week N)` row, it looks for a matching `(same user, week N+1)` row. A `LEFT JOIN` is essential here — an `INNER JOIN` would silently drop every user who was active in week N but *not* week N+1, which is exactly the churn we're trying to measure, not exclude.
- The final aggregation groups by `week_number` and computes, for each week, how many users were active (`active_users_week_n`) and what fraction of them showed up again the following week (`retention_pct`).

### Expected output — **illustrative (analytics_db uses `random()`)**

`analytics_db.events` is populated programmatically using PostgreSQL's `random()` function (see the file header in `databases/analytics_db.sql`), so the exact row set differs every time the database is regenerated. Because of that, the query above will return different precise numbers on your machine than on anyone else's — this is expected, not a bug. A representative shape of the output looks like:

| week_number | active_users_week_n | retained_into_week_n_plus_1 | retention_pct |
|---|---|---|---|
| 0 | 17,842 | 6,213 | 34.8 |
| 1 | 6,213 | 2,850 | 45.9 |
| 2 | 2,850 | 1,190 | 41.8 |
| 3 | 1,190 | 402 | 33.8 |

The classic real-world shape this reveals is a steep initial drop-off (week 0 → week 1) followed by a much shallower, roughly stable decline among the users who survive the first week — the users who make it past week 1 tend to be meaningfully "stickier" than the average signup, which is why so many product teams track "week-1 retention" as a headline metric.

### Common mistakes

> **⚠️ Warning — Retention-analysis mistakes:**
> 1. **Using `INNER JOIN` instead of `LEFT JOIN`** in the self-join step, which silently excludes churned users from the denominator and makes retention look artificially high.
> 2. **Forgetting `DISTINCT` when building the active-weeks set**, which inflates `active_users_week_n` for any user with multiple events in the same week.
> 3. **Measuring from a fixed calendar week instead of a per-user relative week.** "What % of users active in the calendar week of March 3rd were also active the week of March 10th" is a *different, weaker* metric than per-user relative retention, because it mixes users at very different points in their own lifecycle.
> 4. **Conflating retention with the running-total/window-function techniques from Chapter 10.** Retention is fundamentally a self-join (or, equivalently, a `LAG`/`LEAD` window function partitioned by user and ordered by week — an acceptable and often faster alternative to the explicit self-join shown here) — not a running aggregate.

### Practice variations

1. Rewrite `week_transitions` using `LEAD(week_number) OVER (PARTITION BY user_id ORDER BY week_number)` instead of the self-join, and compare readability and (via `EXPLAIN ANALYZE`, Chapter 17) performance on the full 200,000-row `events` table.
2. Extend the query to compute "N-week retention" for N = 1 through 4 in a single result set (i.e., "retained at all into *any* future week," not just the immediate next one).

---

## 31.6 Deduplication

### The business problem

Duplicate rows creep into production tables constantly: a retried ETL job re-inserts a batch, a form double-submits because a user double-clicked "Submit Review," a data migration runs twice against the same source. `ecommerce_db.reviews` even has a `UNIQUE (product_id, user_id)` constraint specifically to *prevent* this — but that constraint only stops *future* duplicates; it does nothing for rows that were already duplicated before the constraint existed, or in tables that were never protected by one in the first place.

Because the canonical schemas are (deliberately) clean, we'll construct a small **illustrative** duplicated dataset shaped like `ecommerce_db.reviews` to demonstrate three real techniques for finding — and removing — duplicates.

```sql
-- ILLUSTRATIVE DATA — simulating a review table before a UNIQUE constraint was added,
-- or after a buggy ETL re-ran and re-inserted the same reviews with a later ingested_at.
CREATE TEMP TABLE reviews_dirty (
    review_id    SERIAL PRIMARY KEY,
    product_id   INT,
    user_id      INT,
    rating       SMALLINT,
    review_text  TEXT,
    review_date  TIMESTAMP,
    ingested_at  TIMESTAMP
);

INSERT INTO reviews_dirty (product_id, user_id, rating, review_text, review_date, ingested_at) VALUES
(1, 1, 5, 'Excellent phone, great camera.',        '2024-01-12 10:00', '2024-01-12 10:01'),
(1, 1, 5, 'Excellent phone, great camera.',        '2024-01-12 10:00', '2024-01-14 03:00'),  -- ETL re-run duplicate
(9, 1, 4, 'Good sound, battery could be better.',  '2024-01-12 10:05', '2024-01-12 10:06'),
(5, 2, 4, 'Nice fit and comfortable.',              '2024-01-10 09:00', '2024-01-10 09:01'),
(5, 2, 3, 'Actually, fit runs small — correction.', '2024-01-11 08:00', '2024-01-11 08:01'), -- same reviewer edited, second row
(3, 4, 5, 'Blazing fast laptop.',                   '2024-01-25 18:00', '2024-01-25 18:02');
```

Here, `(product_id=1, user_id=1)` appears twice — an identical duplicate from an ETL re-run — and `(product_id=5, user_id=2)` appears twice with *different* content (a later "corrected" review), which is a common real-world variant: not a byte-for-byte duplicate, but a logical duplicate the business rule ("one review per user per product") should still collapse to one row.

### (a) `ROW_NUMBER()` in a CTE — the general-purpose, portable technique

```sql
WITH ranked AS (
    SELECT
        review_id,
        ROW_NUMBER() OVER (
            PARTITION BY product_id, user_id
            ORDER BY ingested_at DESC          -- tiebreaker: keep the most recently ingested row
        ) AS rnum
    FROM reviews_dirty
)
DELETE FROM reviews_dirty
WHERE review_id IN (SELECT review_id FROM ranked WHERE rnum > 1);
```

`PARTITION BY (product_id, user_id)` groups rows that represent "the same logical review." `ORDER BY ingested_at DESC` decides *which* duplicate survives — here, the most recently ingested row, which is usually the right call for ETL re-runs (the newer data supersedes the old) but would be the *wrong* call if you instead wanted to keep the *original* (`ORDER BY ingested_at ASC`) or the *highest-rated* review, etc. **The tiebreaker is a business decision, not a technical default** — always be explicit about it.

To find (rather than delete) duplicates first — always do this before running a `DELETE` in production — run just the `ranked` CTE as a `SELECT ... WHERE rnum > 1` and review the rows.

> **⚠️ Warning:** You cannot `DELETE FROM ranked` directly — `ranked` is a CTE, not a table, and window functions cannot appear in a `WHERE` clause. This is why the pattern is always "compute ranks in a CTE, then `DELETE`/`UPDATE` the *base table* using a subquery or CTE reference to identify which primary keys to touch," never a direct `DELETE ... WHERE rnum > 1` in one step.

### (b) `DISTINCT ON` — the concise PostgreSQL-specific alternative

```sql
-- [PostgreSQL only]
SELECT DISTINCT ON (product_id, user_id) *
FROM reviews_dirty
ORDER BY product_id, user_id, ingested_at DESC;
```

`DISTINCT ON (product_id, user_id)` keeps exactly one row per distinct `(product_id, user_id)` pair — the *first* row PostgreSQL encounters for that pair after sorting by the `ORDER BY` clause. This is why the `ORDER BY` **must** start with the same columns as the `DISTINCT ON` list (PostgreSQL requires this) followed by the tiebreaker — here, `ingested_at DESC` again selects "most recent."

This reads as a single, self-contained `SELECT` and is significantly more concise than the `ROW_NUMBER()` CTE for the read-only "give me the deduplicated view" case. To actually delete the losers with `DISTINCT ON`, you'd still typically wrap it: `DELETE ... WHERE review_id NOT IN (SELECT DISTINCT ON (...) review_id FROM ... ORDER BY ...)`.

> **⚠️ Warning — `DISTINCT ON` is not standard SQL.** It is a **PostgreSQL-specific** extension. It does not exist in MySQL, SQL Server, or Oracle at all — porting a query that relies on it to any other engine requires rewriting it as the `ROW_NUMBER()` pattern in (a). If portability across database engines is a project requirement, prefer (a) even on PostgreSQL, so the query doesn't need to be rewritten later.

### (c) `GROUP BY` with `MIN`/`MAX` — the aggregate-and-rejoin technique

```sql
-- Step 1: find the surviving review_id per duplicate group
WITH keepers AS (
    SELECT product_id, user_id, MAX(ingested_at) AS keep_ingested_at
    FROM reviews_dirty
    GROUP BY product_id, user_id
)
-- Step 2: rejoin to pull back the full row for each surviving key
SELECT r.*
FROM reviews_dirty r
JOIN keepers k
  ON k.product_id = r.product_id
 AND k.user_id    = r.user_id
 AND k.keep_ingested_at = r.ingested_at;
```

This works, but notice the extra step: `GROUP BY` with `MAX()` can only tell you the *value of the tiebreaker column* for the surviving row (`MAX(ingested_at)`), not the surviving row's *other* columns (`rating`, `review_text`) — those belong to a specific row, and `GROUP BY` collapses rows, discarding that association unless you explicitly rejoin. If two rows in the same group happened to share the exact same `ingested_at` (a real risk if a batch insert stamps every row with the same timestamp), the rejoin in Step 2 would return *both* of them, silently reintroducing the duplicate you were trying to remove.

### Comparing the three approaches

| Technique | Portability | Clarity | Performance | Handles ties safely? |
|---|---|---|---|---|
| `ROW_NUMBER()` in a CTE | Standard SQL — works on PostgreSQL, MySQL 8+, SQL Server, Oracle | High — explicit ranking, easy to inspect before deleting | One sort pass per partition; scales well with an index on the partition/order columns | Yes — add a deterministic final tiebreaker (e.g., `review_id`) to `ORDER BY` |
| `DISTINCT ON` | **PostgreSQL only** | Highest — single, short statement for the read case | Comparable to `ROW_NUMBER()`; PostgreSQL implements it efficiently via the same sort/unique machinery | Yes, with the same caveat — add a final tiebreaker column |
| `GROUP BY` + `MIN`/`MAX` | Standard SQL — most portable, oldest technique, works everywhere | Lowest — requires a second join to recover the full row, easy to get subtly wrong | An extra join versus the other two; can be worse on large tables | **No** — ties on the aggregated column silently reintroduce duplicates unless the join key is provably unique |

**Recommendation:** use `ROW_NUMBER()` as the default, portable answer; reach for `DISTINCT ON` when you're certain the code will only ever run on PostgreSQL and want the shortest possible query; avoid the `GROUP BY`/rejoin technique for anything beyond very simple cases, since it's the easiest of the three to get subtly wrong on tie-breaking.

### Common mistakes

> **⚠️ Warning — Deduplication mistakes:**
> 1. **Running the `DELETE` before reviewing the `SELECT`.** Always run the `ranked`/`DISTINCT ON` query as a read first and inspect the rows flagged for removal.
> 2. **No deterministic final tiebreaker.** If two duplicate rows have the *exact same* `ingested_at` (very possible after a batch load), `ROW_NUMBER()`'s ordering among them is arbitrary unless you add a final, guaranteed-unique tiebreaker column (e.g., `ORDER BY ingested_at DESC, review_id DESC`) — otherwise which row survives can vary between runs.
> 3. **Deduplicating and then forgetting to add the `UNIQUE` constraint that should have existed all along** — cleaning up existing duplicates without adding `UNIQUE (product_id, user_id)` (as `ecommerce_db.reviews` correctly does) just means the same duplicates will reappear.
> 4. **Not wrapping the `DELETE` in a transaction** (Chapter 11) when deduplicating a large or important table — a single `BEGIN ... DELETE ... SELECT COUNT(*) ... COMMIT/ROLLBACK` lets you verify the row count dropped by exactly the expected amount before committing.

### Practice variations

1. Rewrite technique (a) to keep the **oldest** review per `(product_id, user_id)` instead of the newest, and explain in one sentence which real-world scenario (ETL re-run vs. "user edited their review") each tiebreaker direction corresponds to.
2. Using `company_db.salaries`, write a `ROW_NUMBER()`-based query that, for each employee, keeps only their **most recent** salary row per `effective_date` — even though `salaries` already has a `UNIQUE (employee_id, effective_date)` constraint, write the query as if it didn't, to practice the general pattern.

---

## 31.7 Slowly Changing Dimensions (SCD)

### The business problem

`company_db.employees.job_title` and `department_id` change over an employee's tenure — promotions, transfers, reorgs. The question "what was Karan Verma's job title on 2021-06-01?" cannot be answered if the `employees` table simply **overwrites** `job_title` in place every time it changes — the old value is gone the instant the `UPDATE` commits. This is a data-warehousing problem so common it has a standard name and three standard solutions, called **Slowly Changing Dimensions (SCD)**.

### Type 1 — Overwrite (no history)

```sql
UPDATE company_db.employees
SET job_title = 'Senior Software Engineer'
WHERE employee_id = 4;   -- Vikram Joshi, promoted
```

This is what most tables do by default, including `company_db.employees` as currently modeled. It's simple and cheap, and it's the **correct** choice whenever the business genuinely does not need history — e.g., correcting a typo in someone's `email` is a Type 1 change; nobody needs to know the old (wrong) email was ever there. The cost: the moment someone asks a historical question ("what was this person's title when they worked on the Platform Migration project?"), the answer is unrecoverable.

### Type 2 — Add a new row, keep full history (the industry-standard default)

Type 2 is the right default whenever the *history itself* has business value — payroll audits, promotion timelines, compliance reporting. Instead of overwriting, every change **closes out** the current row and **inserts** a new one, with explicit validity bounds.

```sql
CREATE TABLE company_db.employee_job_history (
    history_id      SERIAL PRIMARY KEY,
    employee_id     INT NOT NULL REFERENCES company_db.employees(employee_id),
    job_title       VARCHAR(100) NOT NULL,
    department_id   INT REFERENCES company_db.departments(department_id),
    valid_from      DATE NOT NULL,
    valid_until     DATE,                  -- NULL means "still current"
    is_current      BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (employee_id, valid_from)
);

-- Seed with each employee's current row as of today
INSERT INTO company_db.employee_job_history (employee_id, job_title, department_id, valid_from, valid_until, is_current)
SELECT employee_id, job_title, department_id, hire_date, NULL, TRUE
FROM company_db.employees;
```

**Recording a promotion (Vikram Joshi, `employee_id = 4`, promoted on 2024-06-01) — the correct two-step pattern inside one transaction:**

```sql
BEGIN;

-- Step 1: close out the currently-open row
UPDATE company_db.employee_job_history
SET valid_until = DATE '2024-06-01' - INTERVAL '1 day',
    is_current   = FALSE
WHERE employee_id = 4
  AND is_current  = TRUE;

-- Step 2: insert the new current row
INSERT INTO company_db.employee_job_history
    (employee_id, job_title, department_id, valid_from, valid_until, is_current)
VALUES
    (4, 'Senior Software Engineer', 1, DATE '2024-06-01', NULL, TRUE);

COMMIT;
```

**Why both steps must be in one transaction:** if step 1 commits but step 2 fails (or the process crashes between them), the employee now has *no current row at all* — every "who currently works as what" query silently loses them. Chapter 11's ACID guarantees exist precisely to make this two-step "close old, open new" pattern atomic — either both rows end up correct, or neither statement's effect is kept.

**Querying "as of a point in time" is now possible:**

```sql
SELECT employee_id, job_title, department_id
FROM company_db.employee_job_history
WHERE employee_id = 4
  AND valid_from <= DATE '2021-06-01'
  AND (valid_until IS NULL OR valid_until >= DATE '2021-06-01');
```

**Querying "current state" is a plain filter:**

```sql
SELECT employee_id, job_title, department_id
FROM company_db.employee_job_history
WHERE is_current = TRUE;
```

> Chapter 22 (Triggers) builds a **trigger-based history table** for exactly this purpose — a trigger on `employees` that automatically writes the Type-2-style row on every `UPDATE`, so application code never has to remember to run the two-step pattern manually. The manual version shown here is what that trigger does under the hood; understanding it by hand first is what makes the trigger version make sense.

### Type 3 — Keep only the previous value (rarely used, briefly)

Type 3 adds one or two extra columns to hold *only the immediately preceding* value, without a full history table:

```sql
ALTER TABLE company_db.employees
    ADD COLUMN previous_job_title VARCHAR(100),
    ADD COLUMN title_changed_on   DATE;

UPDATE company_db.employees
SET previous_job_title = job_title,      -- capture the outgoing value before overwriting
    title_changed_on   = CURRENT_DATE,
    job_title           = 'Senior Software Engineer'
WHERE employee_id = 4;
```

Type 3 answers "what was this person's title *before* the current one?" but cannot answer "what was it two changes ago?" — each new change overwrites `previous_job_title` again. It's a narrow, low-overhead compromise, appropriate only when the business explicitly only cares about "current vs. immediately-prior" (e.g., "show me who got promoted this quarter and what their old title was") and has no interest in deeper history — Type 2 is the safer default whenever you're unsure.

### Comparison

| Type | History kept | Storage cost | Query complexity | When to use |
|---|---|---|---|---|
| Type 1 (overwrite) | None | Lowest | Trivial | Corrections/typos, or the business truly never needs history |
| Type 2 (new row + validity) | Full | Highest (grows forever) | Requires `valid_from`/`valid_until` filtering | Default choice for any dimension with real audit/compliance/analytics value |
| Type 3 (extra column) | Only the immediately previous value | Low | Trivial | Narrow "current vs. prior" comparisons only |

### Common mistakes

> **⚠️ Warning — SCD mistakes:**
> 1. **Forgetting to close out the old row** when inserting the new one in Type 2 — leaves two rows both marked `is_current = TRUE`, which breaks every "current state" query silently (it becomes a one-to-many join where one-to-one was assumed).
> 2. **Using `valid_until IS NULL` as the only signal for "current"** without also maintaining an explicit `is_current` flag — it works, but makes "give me only current rows" queries less self-documenting and easy to get subtly wrong (e.g., forgetting the `IS NULL` and writing `= NULL`, which never matches).
> 3. **Choosing Type 1 by default out of inertia.** Most home-grown "just add a column" schemas default to Type 1 without anyone deciding that history doesn't matter — it's worth asking explicitly at design time (Chapter 14) whether a dimension needs Type 2 semantics before the data (and the need for the history) has already been lost.

### Practice variations

1. Extend the `employee_job_history` table with a `base_salary` column and adapt the two-step transaction pattern to also version salary changes from `company_db.salaries` — note that `salaries` *already* stores multiple `effective_date` rows per employee, making it a natural, pre-existing Type-2-style table once you add an explicit `valid_until`/`is_current` pair.
2. Write the "as of a point in time" query for **every** employee simultaneously (not just one `employee_id`), returning each employee's job title as of `2022-06-01` — think about what happens for employees hired *after* that date (they should not appear in the result at all).

---

## 31.8 Hierarchical Data *(covered in depth in Chapter 9)*

**The problem, in one line:** modeling and querying tree-shaped data — an org chart (`company_db.employees.manager_id` self-references `employees.employee_id`) or a product category tree (`ecommerce_db.categories.parent_category_id` self-references `categories.category_id`) — where the depth of the hierarchy isn't known in advance.

**The pattern:** a recursive CTE (`WITH RECURSIVE`) with a base term (the root(s) of the hierarchy — `manager_id IS NULL`, or `parent_category_id IS NULL`) and a recursive term that repeatedly joins the CTE back to the base table, one level deeper each iteration, until no new rows are produced. Chapter 9, §9.5–§9.9 builds this fully — the org-chart traversal with a computed depth column, "all direct and indirect reports of a given manager," a full category tree with materialized path strings, and general graph reachability/cycle-detection guards (`WHERE NOT path && ARRAY[next_node]` style guards for graphs that aren't guaranteed acyclic). If you need to walk any parent-child structure of unknown depth, that's the chapter to reference — this pattern doesn't need re-deriving here.

**Where hierarchical data connects to this chapter:** an org chart or category tree is frequently *also* a dimension with SCD Type 2 history (§31.7) — e.g., "what did the org chart look like on a given date" combines the recursive-CTE traversal from Chapter 9 with the valid-time filtering technique from §31.7/§31.9, applied to a `manager_id` that itself changes over time (a report chain being reorganized).

---

## 31.9 Audit History *(trigger mechanics covered in Chapter 22)*

**The problem, in one line:** regulated and financial systems need an immutable record of every change made to sensitive data — who changed what, when, and what the value was before and after. `banking_db.audit_log` (`table_name`, `operation`, `row_pk`, `changed_by`, `changed_at`, `old_data JSONB`, `new_data JSONB`) is the canonical example.

**The pattern (recap):** a trigger fires on every `INSERT`/`UPDATE`/`DELETE` of a sensitive table (in this book, typically `banking_db.accounts` and `banking_db.transactions`) and writes a row into `audit_log` capturing the full before/after row state as JSONB. Chapter 22 builds this trigger in full, including the `AFTER` vs. `BEFORE` trigger timing decision and how to serialize `OLD`/`NEW` row values to JSONB (`to_jsonb(OLD)`, `to_jsonb(NEW)`) generically enough to reuse across tables. That mechanism is not re-derived here.

### The new angle: temporal reconstruction from the audit trail

Once an audit log exists, it becomes a general-purpose **point-in-time reconstruction tool** — you can answer "what did this account's balance look like at any point in the past" purely from `audit_log`, without any dedicated history table, because every `UPDATE` to `accounts.balance` left behind a JSONB snapshot of the row *after* that change.

```sql
-- What was account 1's balance at the close of business on 2024-01-10?
SELECT
    (new_data ->> 'balance')::numeric AS balance_as_of
FROM banking_db.audit_log
WHERE table_name = 'accounts'
  AND row_pk      = '1'                       -- row_pk is stored as TEXT
  AND operation IN ('INSERT', 'UPDATE')
  AND changed_at <= TIMESTAMP '2024-01-10 23:59:59'
ORDER BY changed_at DESC
LIMIT 1;
```

**How this works:** every row in `audit_log` for `table_name = 'accounts'` and a given `row_pk` (the account's primary key, stored generically as `TEXT` so the same audit table can serve every table in the schema) is a timestamped snapshot. Filtering to `changed_at <= <the point in time you care about>`, ordering by `changed_at DESC`, and taking the top row is exactly the "top-1-per-group" pattern from §31.1 — the "group" here is implicitly fixed to a single account by the `WHERE row_pk = '1'` filter, and the "ranking" is by recency. To do this for *every* account at once (rather than one account at a time), wrap the same idea in a `ROW_NUMBER() OVER (PARTITION BY row_pk ORDER BY changed_at DESC)` and filter `WHERE changed_at <= :as_of AND rn = 1`, giving a full "balance sheet as of any historical date" for every account in one query.

> **⚠️ Warning:** This reconstruction only works for **columns the trigger actually captured** — if the audit trigger only fires on `accounts` and not on `transactions`, you cannot reconstruct a transaction-level history this way, only whatever full-row snapshots the trigger took. An audit log is a record of *what changed*, not a substitute for a purpose-built Type 2 history table (§31.7) when you know in advance that structured, indexed point-in-time queries against a specific column are a first-class requirement — JSONB extraction (`->>'balance'`) has no index-friendly equivalent to a plain `WHERE valid_from <= ... AND valid_until >= ...` range filter on typed columns unless you add a functional/expression index on the JSONB path.

### Practice variations

1. Write a query that reconstructs **every** account's balance as of `2024-01-16 00:00:00` in one result set, using the `ROW_NUMBER()`-per-`row_pk` technique described above.
2. Using `old_data` instead of `new_data`, write a query that finds every account whose balance ever *decreased* by more than ₹20,000 in a single audited change (compare `(old_data->>'balance')::numeric` to `(new_data->>'balance')::numeric` on the same audit row).

---

## 31.10 Temporal Data

### Valid time vs. system time

The Type 2 SCD table in §31.7 introduced `valid_from`/`valid_until` columns without naming the underlying concept: **valid-time modeling** (also called "application time" or "business time"). A row's valid-time period is when the fact was *true in the real world* — Vikram Joshi's job title of "Senior Software Engineer" was true starting 2024-06-01, regardless of when someone got around to typing that change into the database.

This is a genuinely different axis from **system time** (also called "transaction time") — the timestamp the database itself recorded the row (an `INSERT`/`UPDATE` timestamp, or the `changed_at` column in `banking_db.audit_log`). The two frequently diverge: an HR administrator might enter a promotion effective *last* Monday into the system *today*. The row's valid-time `valid_from` is last Monday; its system-time "recorded at" is today. A table that only tracks one of these two can't answer both "what was true on date X" and "what did we *believe* was true, as recorded on date X" — and those are genuinely different questions in domains like finance and insurance, where corrections to past records happen routinely and both "the corrected truth" and "what we told a regulator on a given date" matter.

Most application schemas — including everything built in this book — track only valid time (via `valid_from`/`valid_until` in a Type 2 table) or only system time (via `created_at`/`updated_at` or an audit log's `changed_at`), which is sufficient for the overwhelming majority of real systems. **Bitemporal** modeling (tracking both axes simultaneously, so every fact has independent valid-time and system-time ranges) is a genuinely advanced technique reserved for systems with strict regulatory replay requirements, and is out of scope for this book beyond naming it here so you recognize the term if you encounter it.

### Enforcing non-overlapping valid periods — PostgreSQL exclusion constraints

A hazard in any hand-rolled Type 2 table is a data-entry bug that creates **overlapping** valid periods for the same entity — e.g., two rows for the same employee both claiming to be valid from 2024-03-01 through 2024-08-01. A `UNIQUE` constraint cannot express "no overlap," because overlap is a *range* relationship, not an equality. PostgreSQL solves this elegantly with **exclusion constraints** over range types:

```sql
-- [PostgreSQL] Requires the btree_gist extension for the equality part of the constraint
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE company_db.employee_job_periods (
    history_id    SERIAL PRIMARY KEY,
    employee_id   INT NOT NULL REFERENCES company_db.employees(employee_id),
    job_title     VARCHAR(100) NOT NULL,
    valid_period  tstzrange NOT NULL,

    EXCLUDE USING gist (
        employee_id WITH =,
        valid_period WITH &&
    )
);
```

`tstzrange` is PostgreSQL's built-in range type over `timestamptz` values (a row like `'[2024-06-01, 2024-11-30)'`). The `EXCLUDE USING gist (employee_id WITH =, valid_period WITH &&)` clause tells PostgreSQL: **reject any `INSERT`/`UPDATE` that would leave two rows with the same `employee_id` and *overlapping* (`&&`) `valid_period` ranges** — enforced by the database itself, at write time, the same way a `UNIQUE` constraint enforces "no duplicate values" but generalized to "no overlapping ranges." This closes a hole that the manual two-step "close old row, insert new row" pattern from §31.7 relies entirely on application discipline to avoid — with an exclusion constraint, a bug in that application code (e.g., forgetting Step 1, leaving the old row open) is caught and rejected by the database instead of silently corrupting the history table.

```sql
INSERT INTO company_db.employee_job_periods (employee_id, job_title, valid_period) VALUES
(4, 'Software Engineer',        '[2018-07-15, 2024-06-01)'),
(4, 'Senior Software Engineer', '[2024-06-01,)');            -- open-ended = "current"

-- This INSERT is REJECTED by the exclusion constraint — it overlaps the second row above:
INSERT INTO company_db.employee_job_periods (employee_id, job_title, valid_period) VALUES
(4, 'Staff Engineer', '[2024-08-01,)');
-- ERROR: conflicting key value violates exclusion constraint
```

> **Important Note:** This is a genuinely advanced, PostgreSQL-specific technique — no other major dialect has an equivalent single-constraint mechanism for "no overlapping ranges per key" as of this writing; SQL Server, MySQL, and Oracle require enforcing this rule procedurally (a trigger, or a check performed inside the application transaction) rather than declaratively. It is exactly the kind of database-level integrity guarantee Chapter 13 (Constraints) argues you should prefer over application-level discipline whenever the database can express the rule directly.

### Practice variations

1. Model `banking_db.accounts.status` (`ACTIVE`/`FROZEN`/`CLOSED`) as a valid-time history using `tstzrange` and an exclusion constraint, so "was this account frozen on a specific date" becomes answerable.
2. Attempt to insert two overlapping FIXED_DEPOSIT interest-rate periods for the same `banking_db.loans.loan_id` into a similarly-designed table, and confirm the exclusion constraint rejects the second insert — then fix the range to abut rather than overlap (`'[2023-01-01, 2024-01-01)'` followed by `'[2024-01-01,)'`, not `'[2023-06-01,)'`).

---

## 31.11 Event Tables

### Append-only event logs vs. mutable "current state" tables

`analytics_db.events` (`event_id`, `user_id`, `event_type` — `SIGNUP`/`LOGIN`/`PURCHASE`/`CHURN` — `event_time`, `payload JSONB`) exemplifies a design philosophy fundamentally different from every other table in this book's schemas: it is **append-only**. Nothing in a well-behaved event-log design ever `UPDATE`s or `DELETE`s a row — every fact about what happened is captured once, at the moment it happened, and stays there forever. Contrast this with `ecommerce_db.orders.status`, which is **mutable current state** — the same row is `UPDATE`d in place as an order moves from `PENDING` to `PAID` to `SHIPPED` to `DELIVERED`, and once it reaches `DELIVERED`, there is no stored record of *when* it was `PENDING` unless something else (a trigger-based audit log, §31.9) captured that transition separately.

The event-log approach trades storage (every state transition is a new row, forever) for two things a mutable table cannot give you without extra machinery: a complete, naturally-ordered history of everything that happened (no audit trigger required — the log *is* the history), and the ability to answer "what was true as of any past moment" by simply filtering `event_time <= :as_of` and taking the latest matching row — the exact same "top-1-per-group" idiom used throughout this chapter.

### Deriving current state from an event log

If you need "this user's current status" and only have the append-only `events` table (no separate `users.status` column to read), you derive it as **the `event_type` of the user's most recent event**:

```sql
-- [PostgreSQL] DISTINCT ON version
SELECT DISTINCT ON (user_id)
    user_id,
    event_type AS current_status,
    event_time AS as_of
FROM analytics_db.events
ORDER BY user_id, event_time DESC;
```

```sql
-- Portable ROW_NUMBER() version (any dialect)
WITH latest_event AS (
    SELECT
        user_id,
        event_type,
        event_time,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_time DESC) AS rn
    FROM analytics_db.events
)
SELECT user_id, event_type AS current_status, event_time AS as_of
FROM latest_event
WHERE rn = 1;
```

Both queries answer the same question — "what is the most recent thing we know about this user" — using the exact top-1-per-group idiom from §31.1/§31.6, applied here to derive *state* from a *log* rather than to deduplicate or reconstruct history. This is the general recipe for building "current state" read models (dashboards, user profile pages) on top of an event-sourced system without maintaining a separate mutable table that could drift out of sync with the log.

### When to choose which design

| | Event log (append-only) | Mutable current-state table |
|---|---|---|
| History | Free — it's the whole point | Requires a separate mechanism (audit log, SCD Type 2) |
| "Current state" query | Requires deriving it (top-1-per-group) | Trivial — just read the row |
| Storage growth | Unbounded, grows with every event forever | Bounded by number of entities |
| Concurrent writers | Naturally safe — every write is an `INSERT`, no lost-update risk | Needs locking discipline (Chapter 12) to avoid lost updates |
| Best fit | Analytics, audit trails, event-sourced systems, anything where "what happened and when" matters as much as "what's true now" | Operational systems where reads vastly outnumber the need for history |

### Common mistakes

> **⚠️ Warning — Event-table mistakes:**
> 1. **Querying an event log for "current state" with a plain `GROUP BY user_id, MAX(event_time)`** and forgetting to rejoin to recover `event_type` — the same `GROUP BY`/`MIN`/`MAX` pitfall from §31.6(c) applies here identically.
> 2. **Treating an event log as mutable** — issuing `UPDATE`s to "correct" a past event instead of appending a new corrective event. This destroys the audit value that was the entire reason to choose an event log in the first place; the correct fix is always a new row (e.g., a `CHURN` event followed later by a new `SIGNUP` event if the user returns), never an edit to history.
> 3. **Letting an unbounded event log grow without a partitioning or archival strategy** — Chapter 26 (Partitioning) is the natural next step once an event table like this reaches production scale (`analytics_db.sales_fact` is partitioned by `sale_date` for exactly this reason).

### Practice variations

1. Using `analytics_db.events`, derive each user's **first** event (not most recent) and its `event_type` — this answers "what was each user's very first recorded action," a common onboarding-funnel question.
2. Write a query that flags users whose most recent event is `CHURN` but who have a *later*-timestamped `SIGNUP` event from a second signup — i.e., a "win-back" — and explain why this is only answerable at all because the log is append-only.

---

## 31.12 Soft Deletes

### The pattern

A **soft delete** replaces a physical `DELETE FROM table WHERE ...` with an `UPDATE` that marks a row as logically gone, typically via a nullable `deleted_at TIMESTAMP` column (`NULL` = still active; a timestamp = when it was "deleted") or a boolean `is_deleted`. `ecommerce_db.products.is_discontinued` and `ecommerce_db.users.is_active` are both already examples of this exact philosophy in the canonical schema, even though neither is named `deleted_at` — the underlying idea (flag instead of physically remove) is identical.

```sql
-- Soft-delete a discontinued product instead of DELETE FROM products WHERE product_id = 4
UPDATE ecommerce_db.products
SET is_discontinued = TRUE
WHERE product_id = 4;
```

### Why teams use it

1. **Referential integrity and history.** `ecommerce_db.order_items.product_id REFERENCES products(product_id)` — a real `DELETE` on a product that has ever been ordered would either be blocked by the foreign key (the default, safe behavior) or, if the FK were set to `ON DELETE CASCADE`, would silently destroy historical order line items along with it. A soft delete keeps every past order's line items intact and readable, while still hiding the product from "browse our current catalog" queries.
2. **Undo.** A soft-deleted row is trivially "undeleted" — `UPDATE ... SET deleted_at = NULL` — where a physically deleted row is gone unless you have a very recent backup (Chapter 28).
3. **Audit requirements.** Some compliance regimes require retaining a record that something *existed and was later removed*, which a physical `DELETE` cannot satisfy without an external audit log (§31.9) recording the deletion.

### The real cost: every query must remember to filter

This convenience is not free. The moment a table has a `deleted_at`/`is_discontinued`-style column, **every** query against it that shouldn't show deleted rows must remember to add `WHERE deleted_at IS NULL` (or `WHERE NOT is_discontinued`) — and forgetting it, even once, in one report or one API endpoint, silently leaks "deleted" data back into view. Two techniques from earlier chapters exist specifically to make this consistent instead of relying on every developer remembering:

```sql
-- Option 1: a view that bakes the filter in once (Chapter 15)
CREATE VIEW ecommerce_db.active_products AS
SELECT * FROM ecommerce_db.products
WHERE is_discontinued = FALSE;
-- Application code queries active_products, never the raw products table directly for "catalog" use cases.
```

```sql
-- Option 2: a partial index that both speeds up AND documents the common filter (Chapter 16, §16.8)
CREATE INDEX idx_products_active
    ON ecommerce_db.products (product_id)
    WHERE is_discontinued = FALSE;
-- Queries filtering WHERE is_discontinued = FALSE benefit from a smaller, faster index —
-- and the index definition itself is a form of executable documentation of the convention.
```

A view enforces the filter *correctly* by construction (you cannot forget it if the view already applied it), while a partial index enforces it *efficiently* — the two are complementary, not alternatives, and using both is common practice.

### The foreign-key question a soft delete forces you to answer explicitly

If `orders.user_id` references a user who is later soft-deleted (`is_active = FALSE`), what should happen to that user's *existing* orders — do they still display the customer's name, or should the UI now show "Deleted User"? A physical `DELETE` forces this question via the `ON DELETE` clause (`RESTRICT`/`CASCADE`/`SET NULL`) at schema-design time (Chapter 13); a soft delete does **not** force it — the foreign key is completely unaffected, the referenced row still physically exists, and it is entirely possible to ship a soft-delete feature without ever explicitly deciding how "orders belonging to a soft-deleted user" should be displayed. Treat this as a deliberate design decision to make up front, not an afterthought discovered in production.

### When hard deletes are still the right choice

> **⚠️ Warning — Soft deletes are not always appropriate.** Data-protection regulations (GDPR's "right to be forgotten," and similar laws elsewhere) can create a **legal obligation** to physically and irrecoverably remove specific personal data on request — a `deleted_at` flag that leaves the underlying row (and its PII) intact in the table, in backups, and potentially in the audit log from §31.9 does **not** satisfy that requirement. Chapter 27 (Security) covers this compliance dimension in depth; the short version for this chapter is: **soft delete is a UX/history feature, not a compliance feature** — systems with a real "right to be forgotten" obligation need a genuine hard-delete (or cryptographic-erasure) path for the specific regulated data, layered *on top of* whatever soft-delete convention the rest of the system uses for everyday "undo"-able deletes.

### Common mistakes

> **⚠️ Warning — Soft-delete mistakes:**
> 1. **Adding `deleted_at` without a view or consistent query convention**, leaving every developer to remember the filter by hand — this is the single most common cause of "deleted" records reappearing in a report months later.
> 2. **Applying `UNIQUE` constraints that don't account for soft deletes** — e.g., `UNIQUE (username)` on a soft-deletable `users` table prevents a *new* user from ever reusing a soft-deleted user's old username, which may or may not be the intended behavior; a partial unique index (`CREATE UNIQUE INDEX ... ON users(username) WHERE deleted_at IS NULL`) fixes this by only enforcing uniqueness among *active* rows.
> 3. **Forgetting soft-deleted rows in aggregate reports** — a `COUNT(*)` or `SUM()` that doesn't filter `deleted_at IS NULL` silently includes logically-gone rows in totals.

### Practice variations

1. Add a `deleted_at TIMESTAMP` column to `ecommerce_db.users` (conceptually — do not modify the canonical schema file), write the `active_users` view, and write a partial unique index that allows a soft-deleted user's `email` to be reused by a new signup.
2. Design the `ON DELETE`/soft-delete interaction explicitly for `ecommerce_db.reviews.user_id` — should a soft-deleted user's product reviews still display, and if so, under what displayed name?

---

## 31.13 Upserts / MERGE

### The business problem

`ecommerce_db.inventory` has `UNIQUE (product_id, warehouse_location)`. A warehouse stock-sync job receives a feed of `(product_id, warehouse_location, quantity_on_hand)` readings and needs to: **update** `quantity_on_hand` if that product/warehouse combination already has a row, or **insert** a new row if it doesn't — without knowing in advance which case applies for any given input row. This "insert-or-update" operation is called an **upsert**.

### Why the naive "check, then act" approach is unsafe

```sql
-- DO NOT DO THIS — naive check-then-act, illustrative only
SELECT inventory_id FROM ecommerce_db.inventory
WHERE product_id = 9 AND warehouse_location = 'Mumbai-WH1';
-- (application code checks: does a row exist?)
-- if yes: UPDATE ... SET quantity_on_hand = 25 WHERE inventory_id = ...;
-- if no:  INSERT INTO inventory (...) VALUES (9, 'Mumbai-WH1', 25, ...);
```

This is the **exact same class of race condition** as the "two customers buying the last item" problem worked through in full in Chapter 12, §12.5: between the `SELECT` that checks for existence and the `INSERT`/`UPDATE` that acts on the result, another concurrent process can perform the same check, get the same "no row exists" answer, and also decide to `INSERT` — producing a duplicate row that violates (or worse, if there's no `UNIQUE` constraint, silently corrupts) the intended one-row-per-product-per-warehouse invariant. Chapter 12's fix for the "last item" problem was `SELECT ... FOR UPDATE` to close the window between check and act; for upserts specifically, every major dialect instead offers a single **atomic statement** that performs the check-and-branch entirely inside the database, with no window for a race at all.

### `INSERT ... ON CONFLICT DO UPDATE` — **[PostgreSQL]**

```sql
INSERT INTO ecommerce_db.inventory (product_id, warehouse_location, quantity_on_hand, reorder_level)
VALUES (9, 'Mumbai-WH1', 25, 25)
ON CONFLICT (product_id, warehouse_location)
DO UPDATE SET quantity_on_hand = EXCLUDED.quantity_on_hand;
```

`ON CONFLICT (product_id, warehouse_location)` names the constraint (the `UNIQUE (product_id, warehouse_location)` already on `inventory`) that would be violated by a plain `INSERT`. Instead of raising an error, PostgreSQL runs the `DO UPDATE` clause on the existing conflicting row. `EXCLUDED` is a special pseudo-table referring to the row that *would have been* inserted — `EXCLUDED.quantity_on_hand` is the `25` from the `VALUES` clause, letting the `UPDATE` reference the incoming value directly.

```sql
-- A common refinement: only replace quantity_on_hand, never accidentally reset reorder_level
INSERT INTO ecommerce_db.inventory (product_id, warehouse_location, quantity_on_hand, reorder_level)
VALUES (9, 'Mumbai-WH1', 25, 25)
ON CONFLICT (product_id, warehouse_location)
DO UPDATE SET quantity_on_hand = EXCLUDED.quantity_on_hand;
-- reorder_level is intentionally left untouched on conflict — only the fields
-- the feed is actually authoritative for should be overwritten.
```

`ON CONFLICT (...) DO NOTHING` (no `SET` clause at all) is the other common form — used when you simply want to ignore a duplicate rather than update anything, which is exactly the shape used for idempotency in §31.14.

### `INSERT ... ON DUPLICATE KEY UPDATE` — **[MySQL]**

```sql
-- [MySQL]
INSERT INTO inventory (product_id, warehouse_location, quantity_on_hand, reorder_level)
VALUES (9, 'Mumbai-WH1', 25, 25)
ON DUPLICATE KEY UPDATE quantity_on_hand = VALUES(quantity_on_hand);
```

MySQL's equivalent doesn't name the constraint explicitly — it fires whenever *any* unique key or primary key on the table would be violated — and refers to the incoming row's values via `VALUES(column_name)` rather than PostgreSQL's `EXCLUDED.column_name`. (Note: MySQL 8.0.19+ deprecates this exact `VALUES()` form in favor of a row alias, e.g. `AS new_row ... UPDATE quantity_on_hand = new_row.quantity_on_hand`, but `VALUES()` remains widely used and supported.)

### Standard `MERGE` — **[SQL Server / Oracle, and PostgreSQL 15+]**

```sql
-- [SQL Server / Oracle / PostgreSQL 15+]
MERGE INTO inventory AS target
USING (SELECT 9 AS product_id, 'Mumbai-WH1' AS warehouse_location, 25 AS quantity_on_hand) AS source
ON target.product_id = source.product_id
   AND target.warehouse_location = source.warehouse_location
WHEN MATCHED THEN
    UPDATE SET quantity_on_hand = source.quantity_on_hand
WHEN NOT MATCHED THEN
    INSERT (product_id, warehouse_location, quantity_on_hand, reorder_level)
    VALUES (source.product_id, source.warehouse_location, source.quantity_on_hand, 25);
```

`MERGE` is the ANSI-standard, most general form: it names a `target` table, a `source` (which can be a single-row constant set as shown, a whole other table, or a query — making it especially powerful for bulk syncing an entire feed of rows in one statement, not just a single upsert), an explicit join condition, and separate `WHEN MATCHED` / `WHEN NOT MATCHED` branches, optionally including `WHEN MATCHED ... DELETE` for a three-way sync (update, insert, *and* delete rows no longer present in the source) that neither `ON CONFLICT` nor `ON DUPLICATE KEY UPDATE` can express in a single statement.

> **⚠️ Warning — `MERGE` had real, well-documented concurrency bugs on some platforms** in earlier versions (notably, `MERGE` in SQL Server has documented edge cases around race conditions and duplicate inserts under high concurrency without additional locking hints, and Oracle's `MERGE` has its own historical quirks) — it is not automatically as bulletproof against races as `ON CONFLICT` on PostgreSQL just because it looks atomic. Always check the current documentation and, for high-concurrency upserts, test under real concurrent load (Chapter 12's guidance on never trusting untested concurrent code applies to `MERGE` as much as to hand-rolled check-then-act code).

### Why the atomic form matters: the race-condition-safety benefit

All three forms above share the same essential property: the existence-check and the insert-or-update decision happen **inside a single statement, under a single lock acquisition**, with no gap in which another transaction can interleave — exactly closing the window that made the naive check-then-act approach in Chapter 12's "last item in stock" case unsafe. Two concurrent stock-sync jobs both upserting `(product_id=9, warehouse_location='Mumbai-WH1')` at the same instant will not create two rows or lose one job's update; the database serializes the two atomic upserts against each other automatically (one waits briefly for the other's row lock, exactly as described in Chapter 12's row-locking mechanics), and both jobs' effects are correctly reflected in sequence.

### Common mistakes

> **⚠️ Warning — Upsert mistakes:**
> 1. **Naming the wrong constraint (or no constraint at all) in `ON CONFLICT`.** `ON CONFLICT (product_id, warehouse_location)` only works because that exact composite `UNIQUE` constraint exists; `ON CONFLICT (product_id)` alone would fail (no such constraint exists) or, worse, silently match the wrong intended uniqueness scope if a different constraint happened to exist on just that column.
> 2. **Overwriting columns the incoming feed doesn't actually own.** The refined example above deliberately leaves `reorder_level` untouched — a careless `DO UPDATE SET *` (not valid syntax, but the mistake of listing every column indiscriminately) would blow away business-configured values like `reorder_level` every time a stock-quantity feed runs.
> 3. **Assuming `MERGE` is universally atomic and race-free without checking the specific engine's documented behavior and testing under concurrency**, as the warning above describes.

### Practice variations

1. Write the PostgreSQL `ON CONFLICT` upsert for `ecommerce_db.reviews` (unique on `product_id, user_id`) that inserts a new review, or updates `rating`/`review_text`/`review_date` if the user has already reviewed that product — i.e., "resubmitting a review edits the existing one."
2. Using `MERGE`, sync an entire batch of incoming inventory readings (a multi-row `source`, e.g., a temp table) against `ecommerce_db.inventory` in one statement, including a `WHEN NOT MATCHED BY SOURCE THEN DELETE` branch for warehouse/product combinations no longer present in the feed at all.

---

## 31.14 Idempotent Operations

### The concept

An operation is **idempotent** if applying it multiple times produces exactly the same end state as applying it once. `UPDATE accounts SET balance = 1000 WHERE account_id = 1` is idempotent — running it five times leaves the balance at exactly 1000, same as running it once. `UPDATE accounts SET balance = balance + 100 WHERE account_id = 1` is **not** idempotent — running it five times adds 500, not 100.

### Why it matters for reliable systems

Networks fail in a specific, maddening way: a client sends a "record this payment" request, the server processes it successfully and commits the transaction, but the *response* is lost in transit (a timeout, a dropped connection). The client has no way to distinguish this from "the request never arrived at all" — from its point of view, both failures look identical: no response. The only safe client behavior is to **retry**. If the underlying operation is not idempotent, that retry double-processes the payment — exactly the kind of bug that turns into a customer support incident and a manual refund.

### Building an idempotent "record a payment" operation

The fix combines the upsert technique from §31.13 with a **unique idempotency key** supplied by the *client*, generated once per logical operation (not once per HTTP attempt) — typically a UUID the client generates before the first attempt and reuses on every retry of that same logical request.

```sql
-- Conceptual extension of banking_db.transactions with an idempotency key
ALTER TABLE banking_db.transactions
    ADD COLUMN idempotency_key UUID UNIQUE;
```

```sql
-- [PostgreSQL] Safe to call this exact statement any number of times with the same idempotency_key
INSERT INTO banking_db.transactions
    (account_id, transaction_type, amount, transaction_date, description, idempotency_key)
VALUES
    (1, 'DEPOSIT', 20000.00, now(), 'Salary credit', 'a1b2c3d4-0001-4a2b-9c3d-000000000001')
ON CONFLICT (idempotency_key) DO NOTHING;
```

**Why this is safe to retry:** the first attempt inserts the row and returns success. If the response is lost and the client retries with the *same* `idempotency_key`, the second `INSERT` collides with the `UNIQUE` constraint, `ON CONFLICT (idempotency_key) DO NOTHING` silently no-ops instead of erroring or inserting a duplicate row, and the client can safely treat "no error" as "the payment is recorded" regardless of whether this particular attempt was the one that actually did the work. The balance is credited exactly once no matter how many times the client retries.

To also let the client *confirm* what happened (rather than just silently succeeding), combine this with a `RETURNING` clause and check whether a row came back:

```sql
INSERT INTO banking_db.transactions
    (account_id, transaction_type, amount, transaction_date, description, idempotency_key)
VALUES
    (1, 'DEPOSIT', 20000.00, now(), 'Salary credit', 'a1b2c3d4-0001-4a2b-9c3d-000000000001')
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING transaction_id;
-- Application logic: if a row is returned, this call performed the insert.
-- If zero rows are returned, an earlier attempt with this key already succeeded — fetch it by idempotency_key instead.
```

### Common mistakes

> **⚠️ Warning — Idempotency mistakes:**
> 1. **Generating a new idempotency key on every retry** instead of reusing the same key across retries of the same logical request — this defeats the entire mechanism, since each retry then looks like a brand-new operation to `ON CONFLICT`.
> 2. **Relying only on client-side "don't double-submit" logic (e.g., disabling a submit button)** instead of a server-side unique constraint — client-side guards don't protect against retries issued by the network layer itself, a mobile app resuming after being backgrounded, or a naive retry loop in an upstream service.
> 3. **Treating idempotency as a substitute for the atomic-upsert safety in §31.13, rather than a complement to it.** Idempotency (same key → same result, safe to repeat) and atomicity (no race window between concurrent *different* requests) solve two related but distinct problems — a production payment-recording endpoint typically needs both.

### Practice variations

1. Design the idempotency key strategy for `ecommerce_db.orders` placement — where should the key be generated (client or server), and what should happen if a retry arrives with the same key but *different* order contents (a legitimate error case the naive `ON CONFLICT DO NOTHING` doesn't handle)?
2. Rewrite the payment-recording insert so that, instead of silently doing nothing on conflict, it returns the *original* transaction's details on a duplicate retry (hint: `ON CONFLICT (idempotency_key) DO UPDATE SET idempotency_key = EXCLUDED.idempotency_key RETURNING *` — a common trick to force `RETURNING` to yield the existing row even though nothing logically changed).

---

## Chapter-Ending Challenge

Design and implement a complete, production-style **price history system for `ecommerce_db.products`**, combining at least four patterns from this chapter:

1. **Deduplication (§31.6):** Before building the history table, you're handed a `price_updates_raw` staging table (construct it as illustrative data, shaped like `(product_id, price, source_system, received_at)`) that has been fed by two upstream systems and contains duplicate `(product_id, price)` submissions for the same logical price change, with different `received_at` timestamps. Write the `ROW_NUMBER()`-based query that produces a clean, deduplicated set of genuine price changes (keep the *earliest* `received_at` per `(product_id, price)` pair, treating the first system to report a given price as authoritative).

2. **Slowly Changing Dimension, Type 2 (§31.7):** Design a `product_price_history` table with `product_id`, `price`, `valid_from`, `valid_until`, `is_current`, and implement the two-step "close old row, insert new row" transaction pattern to load each deduplicated price change from step 1 in chronological order per product.

3. **Idempotent, upsert-based load process (§31.12/§31.13/§31.14):** The load job that populates `product_price_history` from the staging table must be safe to re-run (e.g., after a partial failure) without creating duplicate history rows for a price change that was already recorded. Add a natural idempotency key (e.g., `UNIQUE (product_id, valid_from)` is already a natural fit here — decide whether that alone is sufficient, or whether the load process additionally needs an explicit "have I already processed this staging row" marker) and write the `INSERT ... ON CONFLICT DO NOTHING` (or equivalent) form of the load.

4. **Soft delete for discontinued products (§31.12):** `ecommerce_db.products.is_discontinued` already exists — extend the design so that discontinuing a product both sets `is_discontinued = TRUE` on `products` **and** closes out the currently-open row in `product_price_history` (a discontinued product has no "current" price going forward). Write the query that lists every currently-current price in `product_price_history` for products that are *not* discontinued — this is the "what should the storefront display right now" view.

There is no single correct schema here — the goal is to make and justify the same category of design decisions a senior engineer makes when a "just add a price history table" ticket turns out to require dedup, transactional history-versioning, safe re-runs, and a lifecycle end-state, all at once.

---

## Key Takeaways

- This chapter is a **catalog**, not a single technique — the skill it builds is pattern recognition: matching a business ask ("show returning customers," "sync this feed," "what did this look like last month") to a known SQL shape before writing a single line.
- Top-N-per-group, gaps-and-islands, and running totals are foundational window-function patterns fully covered in Chapter 10 — cohort analysis, retention analysis, deduplication, and event-table state derivation in this chapter are all built from the *same* `PARTITION BY`/`ROW_NUMBER()` primitives, applied to new problems.
- Cohort and retention analysis are hard specifically because they require **self-referential comparison** — a user's own anchor event (signup, first order) compared against their own subsequent activity — before a normal `GROUP BY` becomes possible at all.
- Deduplication has three standard techniques with a real trade-off: `ROW_NUMBER()` (portable, always safe), `DISTINCT ON` (concise, **PostgreSQL-only**), and `GROUP BY`/`MIN`/`MAX` (most portable, but the easiest to get subtly wrong on ties).
- Slowly Changing Dimensions give history-tracking three named shapes — Type 1 (overwrite), Type 2 (full history via new rows + validity ranges, the safe default), Type 3 (previous-value-only) — and the Type 2 "close old row, insert new row" pattern must always run inside one transaction.
- Valid-time modeling (SCD Type 2's `valid_from`/`valid_until`) is a distinct axis from system-time/audit history — PostgreSQL's `EXCLUDE USING gist (entity_id WITH =, valid_period WITH &&)` is a genuinely elegant, dialect-specific way to make "no overlapping periods" a database-enforced guarantee rather than an application-level hope.
- Append-only event logs and mutable current-state tables are two different philosophies with real trade-offs; deriving "current state" from a log reuses the same top-1-per-group idiom as deduplication and audit reconstruction.
- Soft deletes trade query discipline (every query must filter, ideally via a view and/or partial index) for undo-ability and history — and are explicitly **not** sufficient for legal "right to be forgotten" obligations, which require a genuine hard-delete path.
- Atomic upserts (`ON CONFLICT`, `ON DUPLICATE KEY UPDATE`, `MERGE`) close the exact same race-condition window as `SELECT ... FOR UPDATE` does for the "last item in stock" problem in Chapter 12 — never implement insert-or-update as a naive check-then-act sequence in application code.
- Idempotency keys plus atomic upserts (`ON CONFLICT (idempotency_key) DO NOTHING`) are what make a write operation safe to retry after a network failure — a non-negotiable requirement any time a client cannot be certain whether a previous attempt actually succeeded.

## What's Next

This closes Part VI — Database Internals & Production Engineering, and with it, the last *new technique* this book teaches. Chapter 32 (Real-World Projects) shifts the mode of learning entirely: instead of a new concept per chapter, you'll build four complete, realistic systems — an Employee Management System, a Banking System, an E-Commerce Database, and a Large-Scale Analytics Database — pulling together everything from Chapter 1's foundational modeling through this chapter's advanced patterns into single, coherent, production-shaped builds. If this chapter was the reference card for "what pattern am I looking at," Chapter 32 is where you practice reaching for the right one under realistic, multi-constraint conditions, the same way you would on the job.
