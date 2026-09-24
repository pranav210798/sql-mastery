# Chapter 16 — Indexes (Very Deep)

> Part of **Part IV — Advanced SQL & Database Engineering**. Prerequisite: Chapters 1–15
> (especially Chapter 14, Database Design & Normalization, and Chapter 13, Constraints).
> This chapter feeds directly into Chapter 17 (Query Execution & the Query Planner) and
> Chapter 18 (Performance Optimization) — indexes are the *structure*, the planner is the
> *decision-maker* that chooses whether to use them, and performance tuning is the
> *discipline* of making those two things work together.

Every example in this chapter runs against the real schemas already loaded by
`databases/ecommerce_db.sql` and `databases/analytics_db.sql`. If you haven't loaded them yet:

```bash
psql -f databases/ecommerce_db.sql
psql -f databases/analytics_db.sql   # ~5,000,000-row sales_fact table — see file header to shrink it
```

Primary dialect is **PostgreSQL**. Every place behavior diverges is tagged
**[PostgreSQL]**, **[MySQL]**, **[Oracle]**, **[SQL Server]**.

---

## 16.0 The Running Mental Model

This entire chapter is built around one repeating five-question frame. Every time you meet a
new kind of index, ask these five questions in this exact order — by the end of the chapter
it should be automatic:

1. **What problem does it solve?** — What query pattern is slow without it?
2. **How is the data organized?** — What structure does the database build and maintain on disk?
3. **How does the database find rows with it?** — What is the actual lookup algorithm?
4. **Why can it make a query faster?** — What work does it let the database *skip*?
5. **Why can it sometimes make things worse?** — What does it cost on writes, storage, and planning?

Keep this frame in your head. Indexes are not free magic — they are a deliberate trade of
**write cost and storage** for **read speed**, and the entire discipline of indexing well is
knowing exactly when that trade is worth making.

---

## 16.1 Why Indexes Exist: The Fundamental Problem

### Simple explanation

Imagine a phone book with a million names, printed in the order people signed up for phone
service — completely unsorted. You want to find "Sara Patel's" number. Your only option is to
read every single entry, top to bottom, until you find it (or reach the end and conclude she
isn't listed). That's a **linear search**. Now imagine the phone book is instead sorted
alphabetically by last name. To find "Patel, Sara" you open to the middle, see you're in the
"M"s, flip forward, land in "R", flip back a bit, land in "P", and within 4–5 flips you've
found her. That's the difference an index makes.

### Technical explanation

A relational table's rows live in a heap — an unordered (or arbitrarily ordered) collection of
pages on disk. Without any extra structure, the only way to answer `WHERE email = 'sara.p@mail.com'`
is a **full table scan / sequential scan**: read every page, every row, and test the predicate.
For a table with `N` rows, this is `O(N)` work regardless of how many rows match. On the
5,000,000-row `analytics_db.sales_fact` table, a predicate like `WHERE customer_key = 1842`
without an index means physically reading all 5 million rows to find the (roughly) 1,000 that
match.

An index is a **separate, auxiliary data structure** that stores a sorted (or otherwise
organized) copy of one or more columns' values, paired with a pointer back to the exact
physical location of the full row in the heap. The database can search this smaller, ordered
structure far faster than it can scan the heap, then jump directly to the matching rows.

### Why it exists

Every general-purpose database engine (PostgreSQL, MySQL, Oracle, SQL Server) faces the same
problem: tables grow to millions or billions of rows, but users still expect sub-second
answers to `WHERE`, `JOIN`, and `ORDER BY`. Indexes exist because **re-reading the entire table
for every query does not scale**, and because sorting data once (when it's inserted) is far
cheaper than re-sorting it on every single query.

### The row-location mechanism (heap pointer)

- **[PostgreSQL]** every row has a `ctid` (Current Tuple ID) — a `(page_number, tuple_offset)`
  pair identifying its exact physical slot in the heap. Index entries store this `ctid`.
- **MySQL/Oracle/SQL Server** analogues: a **RowID** (Oracle), an internal **row identifier /
  page-slot pointer** (SQL Server heap tables), or — critically for **[MySQL]** InnoDB — the
  *primary key value itself*, because InnoDB tables are always organized as a clustered index
  keyed on the primary key (more in §16.10).

```sql
-- [PostgreSQL] ctid is a real, queryable pseudo-column — you can see the heap pointer directly
SET search_path TO ecommerce_db;
SELECT ctid, user_id, email FROM users WHERE user_id = 3;
--   ctid   | user_id |     email
-- ---------+---------+---------------
--  (0,3)   |       3 | dev.m@mail.com
```

### Example: the problem, concretely

```sql
SET search_path TO ecommerce_db;

-- Without an index on email, this must scan every row in `users`
SELECT user_id, full_name
FROM users
WHERE email = 'sara.p@mail.com';
```

On an 8-row seed table this is instant either way — the *problem only becomes visible at
scale*. That's exactly why `analytics_db.sales_fact` (5,000,000 rows) exists in this course: to
make the cost of a missing index tangible.

```sql
SET search_path TO analytics_db;

-- Without an index on customer_key, PostgreSQL must read all 5,000,000 rows
SELECT SUM(amount)
FROM sales_fact
WHERE customer_key = 1842;
```

### Expected behavior (conceptual, full EXPLAIN syntax in Chapter 17)

Without an index, the planner has no choice but a **Seq Scan**:

```
Seq Scan on sales_fact  (cost=0.00..97835.00 rows=1000 width=10)
  Filter: (customer_key = 1842)
```

`cost=0.00..97835.00` roughly means "start-up cost 0, total estimated cost ~97,835 abstract
units" — proportional to reading the *entire* table, not just the matching rows.

### Common mistakes

- Assuming a small table needs the same indexing strategy as a huge one — on an 8-row table, a
  sequential scan **is** the optimal plan; adding an index there adds overhead for zero benefit.
- Believing indexes "search the table" — they don't; they search *themselves*, then jump into
  the table only for the rows that matched.

### When you don't need one yet

Tables under a few thousand rows, or columns that are always fully scanned anyway (e.g., a
tiny lookup/reference table), rarely benefit from indexing. This chapter's techniques become
essential once tables cross tens of thousands to millions of rows — which is precisely why
`analytics_db` exists in this course.

---

## 16.2 How Indexes Work Conceptually

### What problem it solves

Turning an `O(N)` linear search into something close to `O(log N)`.

### How the data is organized

An index is a **sorted mapping from key values to row locations**. Conceptually it's a table
with two columns: `(indexed_column_value, pointer_to_row)`, kept sorted by
`indexed_column_value` at all times, and automatically re-sorted/rebalanced as rows are
inserted, updated, or deleted in the underlying table.

```
Index on users(email)                 Heap (users table, unordered)
------------------------              --------------------------------
email                 → ctid          ctid   | user_id | email          | ...
'arjun.k@mail.com'    → (0,1)         (0,5)  |    5    | imran.s@...    | ...
'dev.m@mail.com'      → (0,3)         (0,1)  |    1    | arjun.k@...    | ...
'farhan.a@mail.com'   → (0,7)         (0,8)  |    8    | tanya.b@...    | ...
'imran.s@mail.com'    → (0,5)         (0,3)  |    3    | dev.m@...      | ...
...                                   ...
```

Notice the index is sorted by `email`; the heap underneath is in arbitrary (often
insertion) order.

### How the database finds rows with it

1. Parse the predicate: `WHERE email = 'imran.s@mail.com'`.
2. Do a **binary-search-like descent** through the sorted index structure to locate the
   matching key (details of *how* that descent works are the subject of §16.3 — it's a B-tree,
   not literally an array binary search, but the complexity class is the same: `O(log N)`).
3. Read the pointer (`ctid`/RowID) stored next to that key.
4. Jump directly to that page/slot in the heap and read the full row.

### Why it can make a query faster

Step 2 touches a tiny number of index pages (a B-tree of 5,000,000 entries is typically only
3–4 levels deep — see §16.3) instead of every heap page. Step 4 is one targeted read instead of
a full scan.

### Why it can sometimes make things worse

The index itself must be kept up to date. Every `INSERT`, `UPDATE` (of an indexed column), and
`DELETE` must also modify the index's sorted structure — this is real, measurable extra work on
every write, covered in full in §16.13.

> **Important Note:** an index is a *second copy of data*, reorganized for fast lookup. It
> costs disk space and write time in exchange for read time. There is no such thing as a free
> index — only ones whose trade-off is worth it for your actual query workload.

---

## 16.3 B-Tree Indexes — In Real Depth

### 1. Simple explanation

A B-tree index is like a well-organized filing cabinet with folders inside folders. The
top drawer tells you which folder to open; that folder tells you which sub-folder; the
sub-folder finally holds the actual sorted documents. You never touch a document you don't
need, and you never have to look through more than a few drawers to get to the right one.

### 2. Technical explanation

**B-tree** (technically most databases use a **B+tree** variant, though it's universally
called "B-tree" in SQL documentation) is a **self-balancing, sorted tree structure** with three
levels of node:

- **Root node** — the single entry point; holds a small number of keys that divide the entire
  key range into child ranges.
- **Internal (branch) nodes** — hold keys purely for *navigation*: "go left if the key is less
  than X, go right otherwise." They do not store row pointers.
- **Leaf nodes** — hold the actual `(key value, row pointer)` pairs, sorted in key order, and
  **linked to each other** (each leaf points to its next sibling in sorted order).

### 3. Why it exists (why B-tree specifically, not a plain sorted array)

A plain sorted array supports binary search (`O(log N)`) for *reads*, but inserting or
deleting a value in the middle requires shifting every subsequent element (`O(N)`) — completely
impractical for a live, constantly-written database table. A B-tree gets the same `O(log N)`
lookup performance while supporting `O(log N)` inserts/deletes/updates too, because it
rebalances locally (splitting/merging individual nodes) instead of shifting the whole
structure. It is the structure that satisfies **both** "fast to search" and "cheap to keep
sorted under constant writes" — which is exactly what a live database index needs.

### 4. Syntax

```sql
-- [PostgreSQL] B-tree is the DEFAULT index type — you don't even need to name it
CREATE INDEX idx_users_email ON users (email);
-- equivalent, explicit:
CREATE INDEX idx_users_email ON users USING BTREE (email);
```

```sql
-- [MySQL] B-tree is also the default (and, for InnoDB, essentially the only user-facing type)
CREATE INDEX idx_users_email ON users (email);
```

```sql
-- [Oracle]
CREATE INDEX idx_users_email ON users (email);
```

```sql
-- [SQL Server] non-clustered B-tree by default
CREATE NONCLUSTERED INDEX idx_users_email ON users (email);
```

### 5. Examples (against ecommerce_db)

```sql
SET search_path TO ecommerce_db;

CREATE INDEX idx_users_email ON users (email);

CREATE INDEX idx_orders_order_date ON orders (order_date);
```

### 6. Expected behavior

```sql
SELECT user_id, full_name FROM users WHERE email = 'imran.s@mail.com';
```

Before the index: `Seq Scan on users` reading all 8 rows (trivial here, but at 5,000,000 rows
this is the difference between milliseconds and seconds).
After the index: `Index Scan using idx_users_email on users` — the planner descends the B-tree
directly to the matching leaf entry.

Range and sort queries benefit too, because B-tree leaves are **linked in sorted order**:

```sql
SELECT order_id, order_date FROM orders
WHERE order_date BETWEEN '2024-01-01' AND '2024-01-31'
ORDER BY order_date;
```

With `idx_orders_order_date` in place, the engine finds the leaf entry for `'2024-01-01'` and
then simply **walks the linked list of leaf nodes forward** until it passes `'2024-01-31'` —
no re-sorting needed, and no need to revisit the root for each row. This is the single biggest
reason B-trees (not hash indexes) are the default: they serve equality, range, *and* ordering
from one structure.

### 7. Line-by-line (of the lookup algorithm)

For `WHERE order_date = '2024-01-15'` against a B-tree:

1. Start at the **root node**. It holds a handful of separator keys, e.g. `[2024-01-10, 2024-01-20]`.
2. `'2024-01-15'` falls between `2024-01-10` and `2024-01-20`, so follow the **middle child
   pointer** to the corresponding internal node.
3. Repeat: the internal node has its own separator keys; follow the pointer for the range that
   contains `'2024-01-15'`.
4. Arrive at a **leaf node**. Leaf entries are sorted, so a quick in-page search (binary search
   within the page, which is small — one disk block) finds the exact match.
5. Read the row pointer (`ctid`) stored beside the key.
6. Fetch the actual row from the heap at that `ctid` (unless it's an **index-only scan** — see
   §16.6).

### 8. Internal mechanics

**Balance.** A B-tree stays balanced because every leaf is always at the *same depth* from the
root. When a leaf node fills up and a new key must be inserted, the leaf **splits** into two
half-full leaves, and a new separator key is pushed up into the parent internal node. If the
parent is also full, *it* splits too, and the split can propagate all the way up to the root —
in the rare case the root itself splits, the tree grows by exactly one level, and *every* leaf
becomes one level deeper simultaneously. This is why a B-tree never becomes lopsided: growth
happens uniformly from the root down, not by chaining unbalanced branches.

**Depth vs. row count.** Because each node holds many keys (often hundreds, since a database
page is typically 8 KB and a key + pointer pair might be a few dozen bytes), the tree stays
extremely shallow even at huge scale:

| Rows in table | Approx. B-tree depth (fan-out ≈ 200) |
|---|---|
| 1,000 | 2 |
| 1,000,000 | 3 |
| 5,000,000 (sales_fact) | 3–4 |
| 1,000,000,000 | 4–5 |

That is the entire reason `O(log N)` matters in practice: even at a billion rows, a lookup
touches only 4–5 pages, not a billion.

**Deletes and merges.** Deleting a key can leave a leaf under-filled; implementations either
merge it with a sibling or simply tolerate some emptiness until a maintenance operation
(`VACUUM`, `REINDEX` — see §16.13, fully covered in Chapter 29) reclaims the space. This is the
origin of **index bloat**.

### ASCII diagram of a small B-tree

A B-tree built on `orders.order_id` (values 10–140), fan-out kept small for readability:

```
                                    ┌────────────────────┐
                                    │      ROOT NODE      │
                                    │     [ 50 | 100 ]    │
                                    └──┬────────┬────────┬┘
                    ┌───────────────────┘        │        └───────────────────┐
                    ▼                            ▼                            ▼
        ┌─────────────────────┐      ┌─────────────────────┐      ┌─────────────────────┐
        │   INTERNAL NODE      │      │   INTERNAL NODE      │      │   INTERNAL NODE      │
        │    [ 20 | 35 ]       │      │    [ 65 | 82 ]       │      │   [ 115 | 130 ]      │
        └──┬─────────┬────────┬┘      └──┬─────────┬────────┬┘      └──┬─────────┬────────┬┘
           ▼         ▼        ▼          ▼         ▼        ▼          ▼         ▼        ▼
       ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐
LEAVES:│10 → ct│ │20 → ct│ │35 → ct│ │50 → ct│ │65 → ct│ │82 → ct│ │100→ ct│ │115→ ct│ │130→ ct│
       │15 → ct│ │28 → ct│ │40 → ct│ │58 → ct│ │70 → ct│ │90 → ct│ │108→ ct│ │120→ ct│ │140→ ct│
       └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘
           └────────►└────────►└────────►└────────►└────────►└────────►└────────►└────────►
             (leaf nodes are linked left-to-right — this sorted linked list is what makes
              range scans and ORDER BY nearly free once you've found the starting leaf)
```

- **Root**: two keys (`50`, `100`) divide everything into three ranges.
- **Internal nodes**: pure navigation — no row pointers, just "which leaf range to descend into."
- **Leaves**: hold the actual `(order_id → ctid)` pairs, and are chained together in sorted
  order.

To find `order_id = 82`: root says "between 50 and 100 → middle child"; that internal node says
"between 65 and 82 → its right leaf"; the leaf is scanned (tiny, in-page) and `82 → ctid` is
returned. Three hops total, regardless of how many rows are in the table.

### 9. Common mistakes

- Indexing a column and then filtering with a function applied to it without a matching
  expression index: `WHERE UPPER(email) = 'X'` **cannot** use a plain B-tree index on `email`
  (see §16.9).
- Assuming an index on `(a, b)` helps a query that filters only on `b` (leftmost prefix rule,
  §16.5).
- Creating a B-tree index and expecting it to help `LIKE '%pattern%'` (leading wildcard) — a
  B-tree can use a range like `LIKE 'pattern%'` (a prefix) because that's still a contiguous
  sorted range, but a *leading* `%` makes the search pattern match anywhere in the string,
  which has no representable contiguous range in a value-sorted tree.

### 10. Edge cases

- **NULLs**: B-tree indexes do store NULLs (unlike Oracle's default, see below), typically
  sorted at one end (`NULLS LAST` by default in PostgreSQL ascending indexes). `WHERE col IS
  NULL` *can* use a B-tree index in PostgreSQL/SQL Server/MySQL.
- **[Oracle]** a crucial, famous Oracle-specific exception: a standard Oracle B-tree index
  entry is **not created at all for rows where every indexed column is NULL**. So `WHERE col IS
  NULL` in Oracle typically **cannot** use a single-column B-tree index on `col` — this trips up
  even experienced developers moving between dialects.
- Very low-cardinality columns waste B-tree structure — see §16.11.

### 11. When to use / not use

**Use** a B-tree for: equality lookups, range queries (`BETWEEN`, `<`, `>`, `<=`, `>=`),
`ORDER BY`, prefix pattern matches (`LIKE 'abc%'`), and as the default choice unless you have a
specific reason to consider an alternative structure.

**Don't rely on it** for: leading-wildcard text search (`LIKE '%abc%'` — needs full-text or
trigram indexes, Chapter 25), pure equality on huge random-looking keys where hash *might* be
marginally smaller (rarely worth the trade-off, see §16.4), or as a substitute for a partial
index when only a small slice of rows are ever queried (§16.8).

### 12. Comparisons

| Structure | Equality (`=`) | Range (`<`, `BETWEEN`) | `ORDER BY` | Typical use |
|---|---|---|---|---|
| B-tree | Yes | Yes | Yes | Default, general-purpose |
| Hash | Yes (best case O(1)) | No | No | Pure equality workloads only |
| Bitmap (Oracle index type) | Yes, esp. combined with AND/OR | Limited | No | Low-cardinality warehouse columns |

### 13. Real-world use cases

- `ecommerce_db.users(email)` — login lookups (`WHERE email = ?`).
- `ecommerce_db.orders(order_date)` — date-range sales reports.
- `analytics_db.sales_fact(customer_key)` (already created in the seed script as
  `idx_sales_fact_customer`) — per-customer rollups across 5,000,000 rows.

### 14. Practice questions (B-tree)

See the consolidated practice question list in §16.17 — questions 1–4 target this section.

---

## 16.4 Hash Indexes

### 1. Simple explanation

A hash index is like a coat-check counter: you hand over your coat (the key), get a number
(the hash), and the attendant walks straight to the labeled rack (the bucket) instead of
searching every coat in the building. But a coat-check number tells you nothing about whether
your coat is "near" someone else's — there's no useful order, so you can't ask "give me every
coat with a number between 100 and 200" and expect a fast answer.

### 2. Technical explanation

A hash index applies a **hash function** to the indexed value, producing a fixed-size hash
code. That hash code determines which **bucket** the entry is stored in, alongside the row
pointer. Looking up a value means: hash it, jump straight to that bucket, and scan the
(typically very short) list of entries in that bucket for an exact match.

### 3. Why it exists

For pure equality lookups on very large tables, hashing offers close to **O(1)** average-case
lookup — no tree descent at all, just "compute hash, go to bucket." The trade-off: hash codes
deliberately scramble ordering, so there is no way to answer a range query or satisfy an
`ORDER BY` from a hash index. This is precisely why hash indexes are a narrow, special-purpose
tool rather than the default.

### 4. Syntax

```sql
-- [PostgreSQL] explicit hash index
CREATE INDEX idx_orders_status_hash ON orders USING HASH (status);
```

```sql
-- [MySQL] no user-facing CREATE INDEX ... USING HASH for InnoDB.
-- USING HASH is only honored by the MEMORY storage engine:
CREATE TABLE session_cache (
    session_key VARCHAR(64) PRIMARY KEY,
    payload     TEXT
) ENGINE=MEMORY;
CREATE INDEX idx_session_key ON session_cache (session_key) USING HASH;
```

```sql
-- [SQL Server] hash indexes exist only for memory-optimized (In-Memory OLTP) tables
CREATE TABLE dbo.SessionCache (
    SessionKey VARCHAR(64) NOT NULL PRIMARY KEY NONCLUSTERED HASH WITH (BUCKET_COUNT = 1000000),
    Payload    VARCHAR(MAX)
) WITH (MEMORY_OPTIMIZED = ON);
```

```sql
-- [Oracle] no direct "hash index" type on ordinary heap tables. The closest analogue is
-- a HASH CLUSTER — a table storage structure (not a plain index) that hashes the cluster
-- key to decide the physical data block:
CREATE CLUSTER order_cluster (order_id NUMBER) HASHKEYS 1000;
CREATE TABLE orders_clustered (
    order_id NUMBER PRIMARY KEY,
    order_date DATE
) CLUSTER order_cluster (order_id);
```

### 5–6. Examples & expected behavior

```sql
-- [PostgreSQL]
SET search_path TO ecommerce_db;
CREATE INDEX idx_orders_status_hash ON orders USING HASH (status);

SELECT * FROM orders WHERE status = 'PENDING';   -- can use the hash index (equality)
SELECT * FROM orders WHERE status > 'PENDING';   -- CANNOT use it — no ordering in a hash
SELECT * FROM orders ORDER BY status;            -- CANNOT be satisfied by the hash index
```

### 7. Line-by-line

1. `status = 'PENDING'` → compute `hash('PENDING')`.
2. Locate the bucket that hash maps to.
3. Scan that bucket's (short) entry list for an exact match on `'PENDING'` (a hash collision
   means two different values land in the same bucket — the engine still compares actual values
   to filter out false positives).
4. Follow the row pointer(s) to the heap.

### 8. Internal mechanics

Hash indexes typically use a fixed or dynamically-resizable array of buckets; when the
table grows and buckets become overloaded (too many collisions), the index must **rehash** —
redistributing entries across a larger bucket array. This rehashing is analogous to a B-tree
split but tends to be a bigger, less incremental operation, which is one reason hash indexes
historically had a reputation for being harder to maintain efficiently under heavy write load.

### 9. Common mistakes

- Choosing a hash index "for speed" without checking that the workload is **pure equality,
  never range, never sort** — the moment a single query in your access pattern needs
  `ORDER BY` or `BETWEEN` on that column, a B-tree is required anyway, and maintaining both
  is rarely worth it.
- **[PostgreSQL]** assuming hash indexes are unsafe — this was true before PostgreSQL 10 (hash
  indexes weren't WAL-logged, so they could be silently corrupted after a crash and weren't
  replicated to standbys). **Since PostgreSQL 10, hash indexes are fully WAL-logged and
  crash-safe.** They're still rarely recommended over B-tree in practice because a B-tree
  already handles equality nearly as fast while *also* covering range/sort — so the narrow
  win of hash rarely justifies giving up that flexibility.

### 10. Edge cases

- Hash indexes cannot enforce meaningful ordering-based uniqueness checks the way a B-tree can
  participate in range-based constraint checks.
- **[PostgreSQL]** prior to PG 10, hash indexes could not even be used for building unique
  constraints reliably and were excluded from replication guarantees — legacy documentation
  reflects this; always check the target version.

### 11. When to use / not use

**Use**: a narrow equality-only access pattern on a very large column of long, unordered
values (e.g., a session token cache) where you have measured a real benefit.
**Don't use**: as a general-purpose default, or whenever range/sort is needed, or when you
haven't benchmarked against a plain B-tree (which is usually close enough on equality and far
more flexible).

### 12. Dialect summary table

| Dialect | User-facing hash index? | Where it actually appears |
|---|---|---|
| **PostgreSQL** | Yes — `USING HASH`, WAL-logged & crash-safe since PG10 | Any table, rarely recommended over B-tree |
| **MySQL (InnoDB)** | No explicit `HASH` index type | InnoDB auto-builds an internal, non-configurable **Adaptive Hash Index** in the buffer pool for hot pages; user-visible `USING HASH` only applies to the `MEMORY` engine |
| **SQL Server** | Yes, but only for memory-optimized (In-Memory OLTP) tables | `HASH WITH (BUCKET_COUNT = ...)` on `MEMORY_OPTIMIZED = ON` tables |
| **Oracle** | No plain hash index type | Closest analogue is a **hash cluster** (`CREATE CLUSTER ... HASHKEYS`), a physical storage technique, not an index |

### 13. Real-world use case

A session-token or API-key lookup table where every query is `WHERE token = ?` and range/sort
never happens — a legitimate (if narrow) candidate for a hash index in PostgreSQL, though many
teams still default to B-tree here simply for uniformity and tooling familiarity.

---

## 16.5 Composite (Multi-Column) Indexes & the Leftmost Prefix Rule

### 1. Simple explanation

Think of a phone book sorted by **last name, then first name**. If you want "Patel, Sara," this
sort order is perfect — you find all the Patels, then find Sara within that group. But if you
only know a first name — "Sara," any last name — the last-name-first sort order doesn't help
at all: Saras are scattered across every letter of the alphabet.

### 2. Technical explanation

A composite index is a single B-tree built over **multiple columns concatenated in a fixed,
declared order**. It is sorted first by the first column, then, *within each value of the
first column*, by the second column, and so on. This is the **leftmost prefix rule**: the index
can efficiently support any query that filters on a *contiguous prefix* of the indexed columns
starting from the leftmost one — but not on the trailing columns alone.

### 3. Why it exists

A single composite index can serve many queries (all prefixes of its column list), which is
far more space- and write-efficient than creating a separate single-column index per column
combination.

### 4. Syntax

```sql
-- [PostgreSQL / MySQL / Oracle / SQL Server] — same syntax
SET search_path TO ecommerce_db;
CREATE INDEX idx_orders_user_date ON orders (user_id, order_date);
```

### 5. Concrete example: which queries CAN vs CANNOT use `idx_orders_user_date`

The index is logically sorted like this (conceptually, one customer's orders grouped together,
sorted by date within each group):

```
user_id | order_date           → ctid
--------+-----------------------------
   1    | 2024-01-05            → ...
   1    | 2024-01-15            → ...
   1    | 2024-02-01            → ...
   2    | 2024-01-08            → ...
   3    | 2024-01-20            → ...
   3    | 2024-03-10            → ...
   4    | 2024-01-22            → ...
```

```sql
-- ✅ CAN use idx_orders_user_date efficiently — filters on the leftmost column
SELECT * FROM orders WHERE user_id = 1;

-- ✅ CAN use it efficiently — leftmost column, then the second column (a valid prefix)
SELECT * FROM orders WHERE user_id = 1 AND order_date > '2024-01-10';

-- ✅ CAN also use it to satisfy ORDER BY within a user_id group
SELECT * FROM orders WHERE user_id = 1 ORDER BY order_date;

-- ❌ CANNOT use it efficiently — order_date alone is not a leftmost prefix
SELECT * FROM orders WHERE order_date = '2024-01-20';
```

### 6. Expected behavior

The first three queries get an `Index Scan` (or `Index Only Scan`) on `idx_orders_user_date`.
The fourth query forces a full `Seq Scan` — PostgreSQL *could* theoretically scan the whole
index instead of the whole heap, but that offers no advantage (it would still have to inspect
every entry), so the planner correctly chooses to scan the heap directly instead.

### 7. Why, via the tree-structure mental model

Picture the B-tree diagram from §16.3, except the "key" at every leaf is now the pair
`(user_id, order_date)`. The tree is physically sorted **first** by `user_id`. All rows for
`user_id = 3` sit contiguously in the tree, sorted by `order_date` *within* that block. But rows
where `order_date = '2024-01-20'` are scattered across many different `user_id` blocks — one
matching row sits in the `user_id = 3` block, another might sit in the `user_id = 47` block,
another in `user_id = 900`. There's no way to descend the tree using only `order_date`, because
the tree's root and internal nodes make branching decisions based on `user_id` first. The
index has no useful global ordering on `order_date` alone — only a *local* ordering within each
`user_id` group.

### 8. Internal mechanics

Internally, the composite key is stored as a single concatenated sort key: conceptually
`(user_id, order_date)` compares as a tuple — first by `user_id`, ties broken by `order_date`.
This is exactly how tuple comparison works in an `ORDER BY user_id, order_date` clause, which
is not a coincidence: **a composite index physically encodes exactly one sort order**, and only
queries compatible with that sort order (or a prefix of it) benefit.

### 9. Common mistakes

- Creating `(user_id, order_date)` when the dominant query filters on `order_date` alone —
  should have been `(order_date, user_id)` or two separate indexes.
- Assuming column *order* in a composite index doesn't matter — it is the single most
  consequential design decision for a composite index.
- Believing a composite index on `(a, b)` is equivalent to two indexes, one on `a` and one on
  `b` — it is not; it only truly substitutes for a standalone index on `a` (the leftmost
  column), not on `b`.

### 10. Edge cases

- Equality on the leftmost column *combined with* a range on the second column still uses the
  index efficiently (`user_id = 1 AND order_date > '2024-01-10'`), because within the `user_id
  = 1` block, `order_date` is contiguously sorted.
- A range on the *leftmost* column followed by an equality on the second column is **less**
  efficient than the reverse: `WHERE user_id > 100 AND order_date = '2024-01-15'` can only use
  the index to narrow down `user_id > 100`, then must filter `order_date` row-by-row within
  that (potentially huge) range, because once you're inside a range instead of a single equality
  value, the second column's local sort order spans multiple `user_id` groups.
- **[PostgreSQL]** the query planner can sometimes still use a composite index for a
  non-leftmost predicate via an **Index Scan with a Filter** (scanning the whole index and
  filtering in-memory) if that's cheaper than a full table scan — but this is not a genuine
  leftmost-prefix lookup, just the planner picking "least bad" plan; don't rely on it.

### 11. When to use / not use

**Use** composite indexes to match your *actual, dominant WHERE-clause patterns* — design them
around real queries, not around "index everything that might get filtered."

**Design rule of thumb**: put the column used in **equality** predicates first, and the column
used in **range** predicates or `ORDER BY` last. If you commonly run
`WHERE user_id = ? ORDER BY order_date`, then `(user_id, order_date)` is exactly right — it
satisfies the equality filter *and* delivers rows pre-sorted for the `ORDER BY`, with zero
additional sort step.

### 12. Comparison: existing example already in the schema

`ecommerce_db.order_items` already has `UNIQUE (order_id, product_id)`, which PostgreSQL
implements as a composite unique B-tree index. By leftmost-prefix logic:

```sql
-- ✅ Uses the unique index on (order_id, product_id) — leftmost column
SELECT * FROM order_items WHERE order_id = 3;

-- ❌ Cannot use that index efficiently — product_id alone is not a prefix
SELECT * FROM order_items WHERE product_id = 9;
```

If per-product lookups across all orders are also common, you'd add a **second**, separate
index: `CREATE INDEX idx_order_items_product ON order_items (product_id);`

### 13. Real-world use cases

- `orders(user_id, order_date)` — "show me this customer's order history, most recent first."
- `analytics_db.events(user_id, event_time)` — already created in the seed data as
  `idx_events_user_time`; supports "all of this user's events, in time order" (cohort/retention
  queries in Chapter 31).

---

## 16.6 Covering Indexes & Index-Only Scans

### 1. Simple explanation

Imagine the index card catalog at a library not only tells you which shelf a book is on, but
also lists the author and page count right there on the card. If all you needed was the
author and page count, you'd never have to walk to the shelf at all.

### 2. Technical explanation

A **covering index** is an index that contains **every column a query needs** — both the
columns used to filter/sort (the searchable key) and the columns the query actually selects.
When every needed column is present in the index itself, the engine can answer the query
**without visiting the heap at all**. This execution strategy is called an **Index-Only Scan**.

### 3. Why it exists

Even after an Index Scan finds matching keys quickly, each match traditionally still requires
a **separate random-I/O trip to the heap** to fetch the actual row (the "bookmark lookup").
For queries that touch many rows, those heap trips dominate the cost. A covering index
eliminates them entirely.

### 4. Syntax

```sql
-- [PostgreSQL] plain composite covering index — all needed columns are part of the key
CREATE INDEX idx_sales_fact_cust_date_amt
    ON analytics_db.sales_fact (customer_key, sale_date, amount);

-- [PostgreSQL / SQL Server] INCLUDE — add non-key "payload" columns without making them
-- part of the searchable/sortable key (smaller, cheaper index maintenance)
CREATE INDEX idx_sales_fact_cust_date
    ON analytics_db.sales_fact (customer_key, sale_date) INCLUDE (amount);
```

```sql
-- [SQL Server] identical concept
CREATE NONCLUSTERED INDEX idx_sales_fact_cust_date
    ON dbo.sales_fact (customer_key, sale_date) INCLUDE (amount);
```

```sql
-- [MySQL] no INCLUDE syntax — achieve "covering" purely by adding the needed columns
-- into the composite key itself:
CREATE INDEX idx_sales_fact_cust_date_amt ON sales_fact (customer_key, sale_date, amount);
-- EXPLAIN will report "Using index" when this covering condition is met.
```

```sql
-- [Oracle] no INCLUDE clause either — same approach as MySQL, add all needed columns
-- to the index key, or consider an Index-Organized Table for extreme cases.
CREATE INDEX idx_sales_fact_cust_date_amt ON sales_fact (customer_key, sale_date, amount);
```

### 5–6. Example & expected behavior

```sql
SET search_path TO analytics_db;

CREATE INDEX idx_sales_fact_cust_date_incl_amt
    ON sales_fact (customer_key, sale_date) INCLUDE (amount);

SELECT sale_date, amount
FROM sales_fact
WHERE customer_key = 1842
  AND sale_date BETWEEN '2024-01-01' AND '2024-03-31';
```

Every column the query needs — `customer_key` (filter), `sale_date` (filter + output),
`amount` (output) — is present in the index. PostgreSQL can produce the entire result from the
index leaves:

```
Index Only Scan using idx_sales_fact_cust_date_incl_amt on sales_fact
  Index Cond: (customer_key = 1842 AND sale_date BETWEEN '2024-01-01' AND '2024-03-31')
```

Compare that to the same query with only `(customer_key, sale_date)` and no `INCLUDE`:

```
Index Scan using idx_sales_fact_cust_date on sales_fact
  Index Cond: (customer_key = 1842 AND sale_date BETWEEN '2024-01-01' AND '2024-03-31')
```

The only textual difference is "Index Scan" vs "**Index Only** Scan" — but the difference in
actual I/O is enormous once `customer_key = 1842` matches thousands of rows: Index Scan does a
heap fetch per row; Index Only Scan does zero.

### 7. Line-by-line

`INCLUDE (amount)` tells PostgreSQL: store `amount` in the leaf nodes alongside the
`(customer_key, sale_date)` key, but do **not** use it for sorting or tree navigation. This
keeps the searchable key small (cheap comparisons during descent) while still letting the leaf
satisfy `SELECT amount` directly.

### 8. Internal mechanics — the PostgreSQL visibility map / MVCC caveat

> **⚠️ Warning — [PostgreSQL]-specific caveat**: an Index-Only Scan is only possible when
> PostgreSQL can also confirm the row is **visible** to the current transaction *without*
> reading the heap. PostgreSQL uses MVCC (Multi-Version Concurrency Control — full depth in
> Chapter 29): a row's visibility depends on transaction IDs (`xmin`/`xmax`) stored in the heap
> tuple, not in the index. To avoid consulting the heap for every row, PostgreSQL maintains a
> **visibility map** — one bit per heap page, marking whether *all* rows on that page are
> known-visible to all current/future transactions (i.e., no pending updates/deletes need
> checking). If a page's visibility-map bit is set, PostgreSQL trusts it and skips the heap
> entirely for rows on that page. **If the bit is not set** (typically because the page has
> recent, unvacuumed changes), PostgreSQL must still visit the heap for those rows to check
> visibility — even though every needed column is technically in the index! This means a
> freshly, heavily updated table can show `Index Only Scan` in the plan yet still perform a
> surprising number of "Heap Fetches" (visible in `EXPLAIN (ANALYZE, BUFFERS)`, taught in
> Chapter 17). Running `VACUUM` updates the visibility map and restores the full benefit —
> foreshadowing Chapter 29's deep dive into MVCC/VACUUM.

### 9. Common mistakes

- Adding *every* column of a wide table to `INCLUDE` "just in case" — this bloats the index to
  nearly the size of the table itself, defeating the point (a covering index should cover a
  *specific, known* query, not attempt to cover all possible future queries).
- Forgetting the visibility-map caveat and being confused when an "Index Only Scan" still shows
  heap fetches in `EXPLAIN ANALYZE`.
- **[MySQL/Oracle]** trying to write `INCLUDE (...)` syntax — it doesn't exist in either
  dialect; the equivalent is simply adding those columns to the composite key list.

### 10. Edge cases

- A covering index still must be maintained on every write to any of its columns (key *or*
  included) — it is not "free" just because it's non-key.
- `SELECT *` defeats covering-index optimization unless the index happens to include literally
  every column of the table (almost never sensible) — covering indexes are only as good as how
  precisely they match the query's actual `SELECT` list.

### 11. When to use / not use

**Use** for hot, narrow, frequently-run queries (dashboard widgets, per-customer summaries)
where the exact set of selected columns is small and stable.
**Avoid** over-covering: if you find yourself including 6+ extra columns, ask whether the
query itself, or the schema, should change instead.

### 13. Real-world use case

A per-customer sales dashboard hitting `analytics_db.sales_fact` millions of times a day for
`(customer_key, sale_date, amount)` is the textbook covering-index candidate.

---

## 16.7 Unique Indexes

### Simple explanation

A unique index is a sorted structure with an extra rule bolted on: "no two entries may have the
same key." It gets the speed benefits of a normal index *and* enforces a data-integrity rule at
the same time.

### Technical explanation & why it exists

Enforcing uniqueness requires checking "does this value already exist?" before allowing an
`INSERT`/`UPDATE` — which is exactly the lookup an index is built for. Rather than building a
separate uniqueness-checking mechanism, every mainstream RDBMS **implements `PRIMARY KEY` and
`UNIQUE` constraints internally as a unique index**.

```sql
SET search_path TO ecommerce_db;
-- \d users shows:
--   "users_pkey" PRIMARY KEY, btree (user_id)
--   "users_email_key" UNIQUE CONSTRAINT, btree (email)
--   "users_username_key" UNIQUE CONSTRAINT, btree (username)
```

Every one of those constraint lines is backed by a real, physical B-tree index you could
otherwise have created by hand with `CREATE UNIQUE INDEX`. `products.sku` (`UNIQUE`) and
`order_items (order_id, product_id)` (composite `UNIQUE`) work the same way.

### Syntax

```sql
CREATE UNIQUE INDEX idx_products_sku ON products (sku);
```

> **Important Note:** declaring `PRIMARY KEY` or `UNIQUE` in `CREATE TABLE` is functionally
> equivalent to creating the table *and then* running `CREATE UNIQUE INDEX` on those columns —
> the constraint is the intent; the unique index is the enforcement mechanism.

### Common mistakes / edge cases

- Believing you need to separately index a `UNIQUE` or `PRIMARY KEY` column for performance —
  you don't; the constraint already gave you a fully functional B-tree index for free.
- NULL handling differs subtly: standard SQL (and PostgreSQL/SQL Server) treats multiple NULLs
  in a `UNIQUE` column as **not violating uniqueness** (`NULL <> NULL`), so several rows can
  each have a NULL `sku` — worth knowing when you assume "unique" means "no duplicates
  including NULL."

---

## 16.8 Partial Indexes (and Filtered Indexes)

### 1. Simple explanation

Instead of indexing every row in a huge table, a partial index only indexes the *slice* of
rows you actually query often — like putting a bookmark only in the chapters you re-read, not
gluing a tab onto every single page.

### 2. Technical explanation

A partial index (**[PostgreSQL]** term) or filtered index (**[SQL Server]** term) is created
with a `WHERE` clause. Only rows matching that condition are added to the index at all.

### 3. Why it exists

Many real tables have a small "hot" subset (unprocessed queue items, active users, pending
orders) buried inside a much larger "cold" majority (completed/historical rows). Indexing the
whole column wastes space and write time maintaining entries for rows you'll never query that
way.

### 4. Syntax

```sql
-- [PostgreSQL]
CREATE INDEX idx_orders_pending ON orders (order_id) WHERE status = 'PENDING';
```

```sql
-- [SQL Server] "filtered index" — same idea, different name
CREATE NONCLUSTERED INDEX idx_orders_pending
    ON dbo.orders (order_id)
    WHERE status = 'PENDING';
```

```sql
-- [MySQL] no true partial-index syntax. Approximate with a generated column that
-- is NULL for rows you don't want indexed, and index that instead:
ALTER TABLE orders
    ADD COLUMN pending_order_id INT
    GENERATED ALWAYS AS (CASE WHEN status = 'PENDING' THEN order_id END) VIRTUAL;
CREATE INDEX idx_orders_pending ON orders (pending_order_id);
-- Non-PENDING rows store NULL in pending_order_id and (being NULL) contribute
-- almost nothing useful to the index; queries must filter on pending_order_id, not status.
```

```sql
-- [Oracle] also no direct partial-index syntax, but Oracle B-tree indexes never store
-- entries for rows where ALL indexed columns are NULL — this is exploited as the classic
-- "NULL trick" to build a pseudo-partial index:
CREATE INDEX idx_orders_pending
    ON orders (CASE WHEN status = 'PENDING' THEN order_id END);
-- Rows where status <> 'PENDING' evaluate to NULL and are simply never indexed.
```

### 5–6. Example & expected behavior

```sql
SET search_path TO ecommerce_db;

CREATE INDEX idx_orders_pending ON orders (order_id) WHERE status = 'PENDING';

-- A queue-processing worker repeatedly runs:
SELECT order_id FROM orders WHERE status = 'PENDING' ORDER BY order_id LIMIT 20;
```

If `orders` has 50,000,000 historical rows but only 300 are currently `PENDING`, a full index
on `status` would have to store and maintain 50,000,000 entries, the overwhelming majority of
which (`DELIVERED`, `CANCELLED`, etc.) are never queried this way. `idx_orders_pending` instead
contains **only the ~300 `PENDING` rows** — dramatically smaller, faster to scan, faster to
maintain, and it stays small forever regardless of how large the historical table grows
(assuming the queue itself stays small).

### 7. Why it's efficient (mental model)

Picture the same B-tree diagram from §16.3, except only ~300 leaf entries exist instead of 50
million — a shallower tree, fewer pages to read, and every write to a `DELIVERED` or
`CANCELLED` row **never touches this index at all** (the planner/executor checks the `WHERE
status = 'PENDING'` predicate at write time to decide whether the row even belongs in this
index).

### 9. Common mistakes

- Forgetting that a partial index can only be used by queries whose `WHERE` clause **matches or
  logically implies** the index's predicate. `WHERE status = 'PENDING' AND user_id = 5` can use
  `idx_orders_pending`; `WHERE status = 'SHIPPED'` cannot — it isn't in there at all, so the
  planner falls back to a full scan or a different index.
- Using a partial index predicate that changes shape over time (e.g., `WHERE created_at >
  NOW() - INTERVAL '7 days'`) — **not allowed**; the predicate must be an immutable expression
  evaluable at index-build/row-write time, not something whose truth value silently drifts as
  time passes without the index being rebuilt.

### 11. When to use / not use

**Use** when a query pattern always targets a small, well-defined, stable subset of rows
(status queues, soft-delete `WHERE deleted_at IS NULL`, active-flag lookups).
**Don't use** when the subset isn't stable or predictable, or when most queries against the
table don't share that same filter — you'd just be building a second, oddly-shaped index that
helps almost nothing.

### 13. Real-world use case

Exactly the `orders(status) WHERE status = 'PENDING'` example above — a background worker
polling for unprocessed orders is one of the single most common real-world partial-index use
cases in e-commerce systems.

---

## 16.9 Expression (Functional) Indexes

### 1. Simple explanation

If you always look people up by their name in lowercase, but the phone book stores names
mixed-case, you'd want a *second* phone book pre-sorted by the lowercase version — otherwise
you're stuck manually lowercasing every name as you flip through, which defeats the sorted
order entirely.

### 2. Technical explanation

An expression (functional) index doesn't index a raw column — it indexes the **result of an
expression** evaluated on that column. The index is built and kept sorted by the *computed*
value, not the stored one.

### 3. Why it exists

`WHERE LOWER(email) = 'sara.p@mail.com'` cannot use a plain index on `email`, because the index
is sorted by the *raw, stored* values of `email` (mixed case), while the query is filtering on
a *transformed* value. The planner cannot assume `LOWER(email)` preserves the stored sort
order (it doesn't, in general) so it can't use the plain B-tree to narrow the search at all —
it must fall back to evaluating `LOWER(email)` for every row. An expression index solves this
by storing the transformed values directly, pre-sorted.

### 4. Syntax

```sql
-- [PostgreSQL]
CREATE INDEX idx_users_email_lower ON users (LOWER(email));
```

```sql
-- [MySQL 8.0.13+] functional key parts require double parentheses
CREATE INDEX idx_users_email_lower ON users ((LOWER(email)));
```

```sql
-- [SQL Server] no direct expression index — use a persisted computed column, then index it
ALTER TABLE dbo.users ADD email_lower AS LOWER(email) PERSISTED;
CREATE INDEX idx_users_email_lower ON dbo.users (email_lower);
```

```sql
-- [Oracle] function-based index, directly supported
CREATE INDEX idx_users_email_lower ON users (LOWER(email));
```

### 5–6. Example & expected behavior

```sql
SET search_path TO ecommerce_db;
CREATE INDEX idx_users_email_lower ON users (LOWER(email));

-- ✅ CAN use idx_users_email_lower — expression matches exactly
SELECT * FROM users WHERE LOWER(email) = 'sara.p@mail.com';

-- ❌ CANNOT use idx_users_email_lower (nor the plain email index in a case-sensitive way)
--    because the expression on the left doesn't match what's indexed
SELECT * FROM users WHERE email = 'Sara.P@Mail.com';

-- ❌ Also cannot use a plain index on email (if one existed) for the LOWER() query,
--    since email is stored mixed-case and the plain index is sorted on that raw casing
```

### 7. Line-by-line

PostgreSQL's planner performs a syntactic match: it checks whether the *exact expression* used
in the query (`LOWER(email)`) matches the *exact expression* the index was built on. If they
match textually (after normalization), the expression index's B-tree can be used exactly like
a normal column index — descend, find `'sara.p@mail.com'`, follow the pointer to the heap.

### 8. Internal mechanics

Internally there is no real difference between a plain B-tree index and an expression index —
PostgreSQL evaluates the expression once per row at index-build/maintenance time and stores
the *result* as the key, exactly as if that were a real stored column. The only special part is
planner-side expression matching during query planning.

### 9. Common mistakes

- Case/whitespace mismatches between the indexed expression and the query predicate — even
  `Lower(email)` vs `lower(email)` (same function, different case in the SQL text) is fine
  because SQL identifiers are typically case-insensitive for function names, but a
  *semantically different* expression (`TRIM(LOWER(email))` vs `LOWER(email)`) will **not**
  match and the planner will not use the index.
- Building the expression index but continuing to query the raw column — the index sits
  there, fully maintained, and unused.

### 11. When to use / not use

**Use** for case-insensitive lookups, indexing a derived value used in every query (e.g.,
`DATE(created_at)` when you always filter by calendar day), or normalizing formats (stripping
punctuation from phone numbers before comparison).
**Don't use** when a simple `CITEXT` type **[PostgreSQL]** or collation setting **[SQL
Server/MySQL: case-insensitive collations]** could solve case-insensitivity more transparently
for the whole column — sometimes the schema-level fix is cleaner than a query-side expression
index (a design trade-off, not a hard rule).

### 13. Real-world use case

Case-insensitive login by email — extremely common, and `idx_users_email_lower` on
`ecommerce_db.users` is exactly the pattern production auth systems use.

---

## 16.10 Clustered vs. Non-Clustered Indexes — A Major Dialect Divide

This is one of the most commonly confused, most commonly *tested* distinctions in all of SQL.
Get this section fully internalized.

### Precise definitions

- **Clustered index**: an index whose **leaf level *is* the actual table data**, physically
  stored in the index's key order. There is at most **one** clustered index per table, because
  a table's rows can only be physically stored in one order at a time.
- **Non-clustered (secondary) index**: a separate structure whose leaves store the indexed
  key **plus a pointer** back to the row's location (either a physical row locator, or — in
  engines where the table itself is clustered — the clustering key). The underlying table's
  physical row order is untouched. A table can have many non-clustered indexes.

### Dialect-by-dialect

- **[SQL Server]**: `PRIMARY KEY` creates a **clustered index by default** (you can override
  this: `PRIMARY KEY NONCLUSTERED`, and separately declare a different column
  `CLUSTERED`). The table's rows are physically sorted by the clustered index's key. Every
  non-clustered index's leaf stores the **clustering key** as its row locator (or a physical
  RID if the table is a heap with no clustered index at all).
- **[MySQL — InnoDB]**: the `PRIMARY KEY` **is always the clustered index** — this is not
  optional in InnoDB. The table's actual row data lives in the leaf pages of the primary key's
  B-tree. If you don't declare a `PRIMARY KEY`, InnoDB picks the first `UNIQUE NOT NULL` index
  as a substitute clustering key, or — failing that — silently generates a hidden, internal
  6-byte row ID and clusters on that instead. Every **secondary** index in InnoDB (e.g., a
  plain `CREATE INDEX` on `email`) stores the **primary key value**, not a raw disk pointer, as
  its row locator. This means a secondary-index lookup in InnoDB is a **two-step process**:
  first find the primary key value in the secondary index, then do a second B-tree lookup into
  the clustered (primary key) index to fetch the full row — this is exactly why InnoDB
  primary keys should be short (e.g., `SERIAL`/`INT`/`BIGINT`), never a large text column: every
  single secondary index carries a full copy of the primary key in every leaf entry.
- **[PostgreSQL]**: **there is no true, maintained clustered index at all, by default.**
  PostgreSQL tables are stored as an unordered **heap**; *every* index — including the one
  backing the `PRIMARY KEY` — is a genuinely separate, non-clustered structure that points back
  into the heap via `ctid`. PostgreSQL does offer a one-time `CLUSTER` command:
  ```sql
  CLUSTER orders USING orders_pkey;
  ```
  This physically rewrites the table's heap so rows are ordered to match the named index —
  **once**. It does **not** keep that order maintained afterward: subsequent `INSERT`s go
  wherever there's free space, and `UPDATE`s that don't fit in-place can relocate rows
  arbitrarily, so the physical order gradually "decays" back toward unordered until you run
  `CLUSTER` again. This is fundamentally different from SQL Server/MySQL, where the clustered
  index order is **continuously, automatically maintained** on every write, not just
  reordered once on request.
- **[Oracle]**: heap-organized tables (the default) behave like PostgreSQL — unordered heap,
  `ROWID`-based pointers, no clustering by default. Oracle's closest equivalent to a true,
  continuously-maintained clustered index is an **Index-Organized Table (IOT)**:
  ```sql
  CREATE TABLE orders_iot (
      order_id NUMBER PRIMARY KEY,
      order_date DATE,
      status VARCHAR2(20)
  ) ORGANIZATION INDEX;
  ```
  An IOT stores the entire row directly inside the primary key's B-tree leaf — conceptually
  identical to InnoDB's clustered-by-primary-key behavior — but it's an explicit, opt-in table
  organization choice in Oracle, not the automatic default the way it is in MySQL/InnoDB.
  (Oracle also has an unrelated, older feature literally called a "table cluster" —
  `CREATE CLUSTER`, seen in §16.4 — which physically co-locates rows from *multiple* tables that
  share a cluster key; don't confuse that with IOT or with SQL Server's "clustered index.")

### Comparison table

| Dialect | Default table storage | What (if anything) is clustered by default | How to get true, maintained clustering |
|---|---|---|---|
| **PostgreSQL** | Unordered heap | Nothing — no default clustered index at all | `CLUSTER table USING index;` (one-time only, decays over time) |
| **MySQL (InnoDB)** | Clustered on primary key **always** | The `PRIMARY KEY` (or InnoDB's auto-generated hidden row ID if none declared) | Automatic — inherent to InnoDB; not optional |
| **SQL Server** | Heap **unless** a clustered index exists | `PRIMARY KEY` by default (overridable) | `CREATE CLUSTERED INDEX` / `PRIMARY KEY CLUSTERED` |
| **Oracle** | Unordered heap by default | Nothing, unless explicitly declared | `ORGANIZATION INDEX` (Index-Organized Table) |

> **Important Note:** because InnoDB secondary indexes store the primary key as their row
> locator, and PostgreSQL indexes store a physical `ctid`, the same-looking `CREATE INDEX`
> statement has **meaningfully different storage and lookup behavior** across these two
> engines. This is exactly why keeping primary keys short and stable matters more in MySQL
> than in PostgreSQL — in InnoDB, a bloated primary key value is silently duplicated into every
> secondary index leaf entry.

### Common mistakes

- Assuming PostgreSQL has "a clustered index on the primary key" the way MySQL/SQL Server do —
  it does not, by default, ever.
- Assuming `CLUSTER` in PostgreSQL is a persistent setting — it is a one-time physical
  reordering; new rows are not kept in that order automatically.
- Choosing a large `VARCHAR` or UUID-heavy primary key in MySQL/InnoDB without realizing every
  secondary index now silently carries a copy of that large value.

---

## 16.11 Index Selectivity and Cardinality

### Precise definitions

- **Cardinality**: the number of **distinct values** present in a column, independent of the
  total row count. `ecommerce_db.users.email` has cardinality 8 (one per current row, since
  it's `UNIQUE`); `orders.status` has cardinality 5 (`PENDING`, `PAID`, `SHIPPED`, `DELIVERED`,
  `CANCELLED`); `users.is_active` has cardinality 2 (`TRUE`/`FALSE`).
- **Selectivity**: the **fraction of rows a given predicate returns**, expressed 0 to 1 (or as
  a percentage). For a roughly uniform distribution, the selectivity of an equality predicate
  on a column is approximately `1 / cardinality`. A column where `WHERE col = value` typically
  returns a tiny slice of the table is **highly selective**; a column where it returns a large
  chunk is **poorly selective**.

### Why it matters — the mental model

Ask: *what problem does an index solve?* Skipping rows you don't need. If a predicate matches
90% of the table anyway, an index barely helps — you'd still end up fetching almost every row,
plus now you're paying for both the index traversal *and* the heap fetches, which can be
**slower** than simply scanning the heap directly in physical order.

### Concrete example: bad candidate (low cardinality)

```sql
SET search_path TO ecommerce_db;
CREATE INDEX idx_users_is_active ON users (is_active);

SELECT * FROM users WHERE is_active = TRUE;
```

`is_active` has cardinality 2. If 7 of 8 users are active (87.5% selectivity — meaning "poor"
selectivity, since it matches almost everything), the planner will very likely **ignore this
index** and run a `Seq Scan` anyway — fetching 87.5% of rows via an index means paying for the
B-tree traversal *and* almost as many random heap fetches as a full scan would need
sequentially. This is not a planner bug; it is the *correct* cost-based decision.

### Concrete example: good candidate (high cardinality)

```sql
CREATE INDEX idx_orders_order_id ON orders (order_id);  -- already the primary key, for illustration
SELECT * FROM orders WHERE order_id = 42;
```

`order_id` is unique — cardinality equals row count, selectivity of an equality predicate is
`1/N` — the best possible case. The planner will essentially always choose an Index Scan here.

### Common mistakes

- Indexing booleans or small enumerated `status`/`type` columns in isolation, expecting a
  speedup, then being confused when `EXPLAIN` shows a `Seq Scan` anyway.
- **The fix, when a low-cardinality column genuinely needs fast lookups on one specific value**:
  don't index the whole column — use a **partial index** (§16.8) on just the rare/important
  value (e.g., `orders(status) WHERE status = 'PENDING'` is high-value *precisely because*
  `'PENDING'` is a small slice of an otherwise low-selectivity column).
- Ignoring **stale statistics**: the planner's selectivity estimates come from table statistics
  (`ANALYZE` in PostgreSQL, foreshadowed in Chapter 29). If statistics are stale after a large
  data change, the planner can misjudge selectivity and choose a bad plan even when the index
  itself is well-designed.

### When low cardinality is *fine* to index anyway

Combined into a **composite** index where it's not the leading/only column (e.g.,
`(customer_key, sale_date)` where `sale_date` alone is not super selective but narrows a
`customer_key`-filtered result nicely), or as a partial-index predicate rather than the
searchable key.

---

## 16.12 Scan Types (Introduced Here, Fully Taught in Chapter 17)

Understanding these terms now is essential because they are the *visible proof* of everything
above — you will read them constantly in `EXPLAIN` output starting next chapter.

| Scan type | What it means | Triggered by |
|---|---|---|
| **Sequential / Table Scan** | Reads every page of the heap, top to bottom, testing the predicate on every row | No usable index, or the predicate/column isn't selective enough to make an index worthwhile |
| **Index Scan** | Traverses a B-tree (or other index) to find matching keys, then fetches each matching row individually from the heap | A selective predicate with a matching index, where the query also needs columns not stored in the index |
| **Index-Only Scan** **[PostgreSQL naming]** | Same tree traversal, but every needed column is already in the index — no heap visit needed (subject to the visibility-map caveat, §16.6) | A covering index exists for the query |
| **Bitmap Index Scan / Bitmap Heap Scan** **[PostgreSQL]** | A two-phase strategy: first build an in-memory bitmap of *which heap pages* contain matching rows (by scanning one or more indexes), then visit only those heap pages, in physical page order, fetching all matching rows per page in one pass | Medium selectivity — too many matching rows for a plain Index Scan's per-row heap fetch to be efficient, but still worth using the index rather than a full Seq Scan; also used to combine multiple indexes with AND/OR |

> **⚠️ Warning — do not confuse this with Oracle's Bitmap *Index* (a stored index **type**)**:
> **[PostgreSQL]**'s "Bitmap Index Scan"/"Bitmap Heap Scan" are **execution strategies** built
> dynamically at query time from an ordinary B-tree index — nothing is stored on disk as a
> "bitmap." **[Oracle]**, by contrast, has an actual **`CREATE BITMAP INDEX`** — a genuinely
> different, persistently stored index *structure*, purpose-built for very **low-cardinality**
> columns in read-heavy data-warehouse/star-schema contexts (the opposite of when a B-tree
> shines). These are two completely different concepts that happen to share the word "bitmap" —
> a favorite trick question in interviews.

Full `EXPLAIN`/`EXPLAIN ANALYZE` syntax, reading cost estimates, and choosing between these
plans belongs to **Chapter 17**; this chapter only needs you to recognize *why* each one
exists as a direct consequence of the index concepts above.

---

## 16.13 When Indexes Help vs. Hurt

Return to the running mental model's fifth question: **why can an index sometimes make things
worse?**

### Reads: unambiguously helped

`SELECT`/`WHERE`/`JOIN`/`ORDER BY` can all be accelerated by the right index — everything
covered so far in this chapter.

### Writes: unavoidably slowed down

Every `INSERT` must add an entry to **every** index on that table. Every `UPDATE` that touches
an indexed column must remove the old index entry and insert a new one (and, in MVCC engines
like PostgreSQL, an `UPDATE` to *any* column can still require new index entries for all
indexes, because a new row version is created — full detail in Chapter 29). Every `DELETE`
must remove entries from every index.

### The concrete narrative: 15 indexes, 16 writes

Imagine `orders` accumulated 15 indexes over time — one added for each new report a different
team needed ("index by status," "index by user and date," "index by shipping city," "index by
payment method," and so on). Every single `INSERT INTO orders` now does:

1. One physical write to the heap (the actual row).
2. **Fifteen** additional physical writes/updates — one B-tree insertion per index.

That's **16 total physical writes for one logical `INSERT`**. If this table takes heavy write
traffic (a busy storefront), those 15 extra writes:

- Multiply disk I/O and WAL volume (**[PostgreSQL]**) or redo-log volume (**[Oracle/MySQL]**)
  for every transaction.
- Hold row/page locks longer, increasing contention (Chapter 12).
- Make `VACUUM` (PostgreSQL) or index maintenance in general take longer and run more often.

This is the textbook explanation of **"too many indexes are bad"** — not because indexes are
inherently bad, but because **each one is a recurring tax on every future write**, paid
whether or not that index is ever actually used to answer a read.

> **Important Note:** an unused index is pure cost with zero benefit — it still has to be
> maintained on every write, but never helps a single query. Production teams periodically
> audit index usage (PostgreSQL's `pg_stat_user_indexes`, covered operationally in Chapter 18)
> specifically to find and drop these.

### Disk space

Every index consumes its own storage — a composite index over several columns, especially wide
`TEXT`/`VARCHAR` columns, can rival or exceed the size of the table itself. `sales_fact` at 5
million rows with a 3-column covering index is not a rounding error; it's real, measurable
storage that must be provisioned, backed up, and kept in cache to stay fast.

**Extreme case — indexing a hash of a large value**: if you must support equality lookups on a
huge value (e.g., a full document body, a large JSON blob, or a very long URL) and a full
expression/functional index on that value would be too large or too slow to maintain, a common
expert technique is to index a **fixed-size hash of the value** instead:

```sql
-- [PostgreSQL] instead of indexing a huge TEXT column directly:
ALTER TABLE some_table ADD COLUMN payload_hash BYTEA
    GENERATED ALWAYS AS (digest(large_payload::bytea, 'sha256')) STORED;
CREATE INDEX idx_payload_hash ON some_table (payload_hash);

-- Lookups compare the hash first (cheap, fixed-size), then verify the actual value
-- if an exact-value guarantee is required (to rule out the astronomically rare hash collision):
SELECT * FROM some_table
WHERE payload_hash = digest('the exact large value', 'sha256')
  AND large_payload = 'the exact large value';
```

### Misleading the planner: stale statistics

An index's mere existence doesn't guarantee it's used well — the planner's decision to use (or
skip) an index depends on **statistics** (row counts, distinct-value estimates, data
distribution histograms) gathered by `ANALYZE` (**[PostgreSQL]**; other engines have
equivalents — `ANALYZE TABLE` **[MySQL]**, `DBMS_STATS` **[Oracle]**, `UPDATE STATISTICS`
**[SQL Server]**). If a table changes drastically (bulk load, mass delete) and statistics
aren't refreshed, the planner may keep using outdated selectivity assumptions — choosing a
Seq Scan when an index would now be far better, or vice versa. This is foreshadowed here and
covered operationally in **Chapter 29** (VACUUM/ANALYZE) and **Chapter 17/18** (reading plans
to detect this).

### Index maintenance and bloat

Over time, especially under heavy `UPDATE`/`DELETE` traffic, B-tree pages accumulate
half-empty or "dead" entries (rows deleted or old MVCC row-versions no longer visible to any
transaction) — this is **index bloat**. PostgreSQL's `VACUUM` reclaims some of this
automatically; a more aggressive fix is:

```sql
-- [PostgreSQL] rebuild an index from scratch, compacting it
REINDEX INDEX idx_orders_user_date;
-- or, to avoid a long exclusive lock in production:
REINDEX INDEX CONCURRENTLY idx_orders_user_date;
```

```sql
-- [MySQL] rebuilding effectively happens via:
ALTER TABLE orders ENGINE=InnoDB;   -- forces a table (and index) rebuild
-- or, for a targeted index rebuild in modern MySQL:
ALTER TABLE orders DROP INDEX idx_orders_user_date, ADD INDEX idx_orders_user_date (user_id, order_date);
```

```sql
-- [Oracle]
ALTER INDEX idx_orders_user_date REBUILD;
```

```sql
-- [SQL Server]
ALTER INDEX idx_orders_user_date ON dbo.orders REBUILD;
```

Full internals of bloat, `VACUUM`, and autovacuum tuning are Chapter 29's subject — this
section only needs to plant the vocabulary and the *why*.

---

## 16.14 Three Full Before/After Scenarios

### (a) Unindexed WHERE clause → indexed

**Before:**

```sql
SET search_path TO analytics_db;
-- (assume idx_sales_fact_customer does not yet exist)
EXPLAIN
SELECT * FROM sales_fact WHERE customer_key = 1842;
```
```
Seq Scan on sales_fact  (cost=0.00..97835.00 rows=1000 width=42)
  Filter: (customer_key = 1842)
```
Every one of ~5,000,000 rows is read and tested; cost is proportional to table size regardless
of how selective `customer_key = 1842` actually is.

**After** (this index is, in fact, already created by `databases/analytics_db.sql`):

```sql
CREATE INDEX idx_sales_fact_customer ON sales_fact (customer_key);

EXPLAIN
SELECT * FROM sales_fact WHERE customer_key = 1842;
```
```
Index Scan using idx_sales_fact_customer on sales_fact  (cost=0.43..842.17 rows=1000 width=42)
  Index Cond: (customer_key = 1842)
```
Cost drops from ~97,835 to ~842 — roughly two orders of magnitude — because the engine now
descends a shallow B-tree instead of reading the entire heap.

### (b) Composite index leftmost-prefix demonstration

```sql
SET search_path TO ecommerce_db;
CREATE INDEX idx_orders_user_date ON orders (user_id, order_date);

-- Uses the leftmost prefix — fast
EXPLAIN SELECT * FROM orders WHERE user_id = 1 AND order_date > '2024-01-01';
-- Index Scan using idx_orders_user_date on orders
--   Index Cond: ((user_id = 1) AND (order_date > '2024-01-01'))

-- Cannot use the leftmost prefix — order_date is the second column, not the first
EXPLAIN SELECT * FROM orders WHERE order_date > '2024-01-01';
-- Seq Scan on orders
--   Filter: (order_date > '2024-01-01')
```
Same index, two queries — one gets full benefit, the other gets none, purely because of which
column is being filtered relative to the index's declared column order.

### (c) Covering index turning an Index Scan into an Index-Only Scan

```sql
SET search_path TO analytics_db;

CREATE INDEX idx_sales_fact_cust_date ON sales_fact (customer_key, sale_date);

EXPLAIN SELECT sale_date, amount
FROM sales_fact
WHERE customer_key = 1842 AND sale_date >= '2024-01-01';
-- Index Scan using idx_sales_fact_cust_date on sales_fact
--   Index Cond: ((customer_key = 1842) AND (sale_date >= '2024-01-01'))
-- (amount isn't in the index, so every matching row needs a heap fetch)

DROP INDEX idx_sales_fact_cust_date;
CREATE INDEX idx_sales_fact_cust_date_incl ON sales_fact (customer_key, sale_date) INCLUDE (amount);

EXPLAIN SELECT sale_date, amount
FROM sales_fact
WHERE customer_key = 1842 AND sale_date >= '2024-01-01';
-- Index Only Scan using idx_sales_fact_cust_date_incl on sales_fact
--   Index Cond: ((customer_key = 1842) AND (sale_date >= '2024-01-01'))
-- (amount is now stored in the index leaves — zero heap fetches, assuming the
--  visibility map is up to date; see the §16.6 warning)
```

---

## 16.15 Quick-Reference: Index Types at a Glance

| Index type | Solves | Key syntax (PostgreSQL) | Best for | Weak for |
|---|---|---|---|---|
| B-tree | General-purpose lookup/sort | `CREATE INDEX ... (col)` | Equality, range, `ORDER BY` | Leading-wildcard text |
| Hash | Fast pure equality | `... USING HASH (col)` | Equality only, huge unordered keys | Range, sort |
| Composite | Multi-column filters | `... (col1, col2)` | Queries matching a leftmost prefix | Filtering on trailing columns alone |
| Covering (`INCLUDE`) | Avoid heap visits | `... (k) INCLUDE (payload)` | Hot, narrow, stable `SELECT` lists | Over-including columns |
| Unique | Uniqueness + lookup | `CREATE UNIQUE INDEX` | PK/UNIQUE constraint backing | N/A — always appropriate for its purpose |
| Partial | Small hot subset | `... WHERE condition` | Queue/status/soft-delete patterns | Unstable or unpredictable filters |
| Expression | Derived-value lookup | `... (LOWER(col))` | Case-insensitive / normalized search | Mismatched expressions at query time |

---

## 16.16 Practice Questions

1. Explain, in plain language, why a full table scan on `analytics_db.sales_fact` (5,000,000
   rows) is expensive, and what specifically an index changes about that cost.
2. What is stored in a PostgreSQL heap tuple's `ctid`, and what role does it play in every
   index lookup?
3. Draw (in words or ASCII) what happens to a B-tree when a leaf node fills up and a new key
   must be inserted into it.
4. Why do B-tree leaf nodes need to be linked to each other in sorted order? Which two query
   patterns specifically depend on that linking?
5. Why can't a hash index support `ORDER BY` or `BETWEEN`, even in principle?
6. Given `CREATE INDEX idx_orders_user_date ON orders (user_id, order_date);`, write one query
   that uses this index efficiently and one that cannot, and explain why for each.
7. What's the difference between a covering index created by simply listing extra columns in
   the key vs. using `INCLUDE` **[PostgreSQL/SQL Server]** — what specifically does `INCLUDE`
   avoid?
8. Explain the PostgreSQL visibility-map caveat: why can `EXPLAIN` say "Index Only Scan" and
   the query still perform heap fetches?
9. Is `PRIMARY KEY` a different mechanism from `UNIQUE INDEX`, or the same mechanism under a
   different name? Justify your answer.
10. Design a partial index for `ecommerce_db.orders` that would help a background job looking
    for orders stuck in `'PAID'` status for follow-up shipping, and explain why it would stay
    small even as the `orders` table grows into the millions.
11. Why can't `WHERE LOWER(email) = 'x@mail.com'` use a plain B-tree index on `email`? What
    index would fix it, and in which dialects does the syntax differ?
12. A junior developer says "PostgreSQL clusters the table by its primary key, just like SQL
    Server." Correct this statement precisely, including what `CLUSTER` actually does and does
    not guarantee over time.
13. `orders.status` has 5 distinct values out of thousands of rows. Explain why a plain index
    on `status` alone is a poor design choice, and describe a better alternative for a query
    that specifically needs fast access to `'PENDING'` orders.
14. What is the difference between Oracle's `CREATE BITMAP INDEX` and PostgreSQL's "Bitmap
    Index Scan" / "Bitmap Heap Scan" in `EXPLAIN` output? Why is this a common point of
    confusion?
15. A table has 15 indexes and receives heavy `INSERT` traffic. Explain, step by step, what
    happens physically when one row is inserted, and why this workload might benefit from
    dropping some of those indexes.

---

## 16.17 Chapter-Ending Challenge

**Scenario.** The following report query against `ecommerce_db` has become unacceptably slow
in production as the tables have grown:

```sql
SELECT
    o.order_id,
    u.full_name,
    o.order_date,
    o.status,
    SUM(oi.quantity * oi.unit_price) AS order_total
FROM orders o
JOIN users u        ON u.user_id = o.user_id
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p      ON p.product_id = oi.product_id
WHERE o.order_date BETWEEN '2024-01-01' AND '2024-03-31'
  AND o.status IN ('PAID', 'SHIPPED', 'DELIVERED')
GROUP BY o.order_id, u.full_name, o.order_date, o.status
ORDER BY order_total DESC
LIMIT 50;
```

**Your task.** Using only concepts covered in this chapter (full `EXPLAIN` mechanics are
Chapter 17 — reason about it conceptually here), design the index(es) you'd add, and justify
each choice explicitly against the mental model: what problem it solves, how the data will be
organized, how the database will find rows with it, why it should make this query faster, and
what write-side cost it adds.

At minimum, address:

1. **The date-range + status filter on `orders`.** Should `order_date` and `status` be in one
   composite index, or should `status` instead drive a partial index? Consider `status`'s
   cardinality (5 distinct values, and the query only cares about 3 of them) against
   `order_date`'s much higher cardinality and its role in a range predicate — which column
   belongs in the leading position, if you build a composite index, and why does leftmost-prefix
   ordering (§16.5) make that choice consequential?
2. **The `orders → order_items` join.** `order_items` already has `UNIQUE (order_id,
   product_id)` — walk through, using the leftmost-prefix rule, whether that existing index
   already supports "find all items for a given `order_id`" efficiently, and whether you need
   anything additional.
3. **`ORDER BY order_total DESC LIMIT 50`.** `order_total` is a computed aggregate — explain
   why no index can directly pre-sort a value computed at query time via `SUM(...)`, and what
   that implies about where an index can and cannot help this particular clause.
4. **Whether a covering index (§16.6) is worth it** for the columns read from `order_items`
   (`order_id`, `product_id`, `quantity`, `unit_price`) to enable an Index-Only Scan there, and
   what you'd need to weigh (index size vs. heap-fetch savings) given `order_items` is
   read here for every matching order.
5. **The write-side cost.** `orders` and `order_items` are written to constantly (every new
   purchase). For every index you propose adding, explicitly state the extra write cost it
   imposes (§16.13's "16 writes instead of 1" narrative) and argue why the read benefit is
   worth it for *this specific* query pattern — don't propose an index you can't justify.

There is a defensible, well-reasoned answer here, not one single "correct" index set — the
grading criterion is whether your justification for each index correctly applies the concepts
from §16.3, §16.5, §16.8, §16.11, and §16.13.

---

## Key Takeaways

- An index trades **write cost and disk space** for **read speed** — never assume it's free;
  always ask whether the trade is worth it for your actual workload (§16.0, §16.13).
- **B-tree** is the default, general-purpose index structure because its balanced tree and
  linked leaf nodes serve equality, range, *and* sort from one structure (§16.3).
- **Hash indexes** beat B-tree only for pure equality lookups, and cannot serve range or sort
  at all; exposure differs sharply across dialects (§16.4).
- **Composite indexes** obey the **leftmost prefix rule** — a query can only exploit a
  contiguous prefix of the indexed columns, starting from the first one (§16.5).
- **Covering indexes** (and `INCLUDE` **[PostgreSQL/SQL Server]**) let a query skip the heap
  entirely via an **Index-Only Scan** — but in PostgreSQL this is gated by the **visibility
  map**, an MVCC-specific caveat (§16.6).
- `PRIMARY KEY`/`UNIQUE` constraints are **implemented as unique indexes** internally — you get
  a fully functional index "for free" when you declare one (§16.7).
- **Partial indexes** **[PostgreSQL]** / **filtered indexes** **[SQL Server]** index only a
  meaningful subset of rows; MySQL/Oracle approximate this with generated columns or the
  NULL-trick, since neither has true partial-index syntax (§16.8).
- **Expression indexes** let predicates like `WHERE LOWER(email) = ...` use an index at all,
  because the index must be built on the *exact expression* the query uses (§16.9).
- **Clustered vs. non-clustered is a major dialect fault line**: MySQL/InnoDB always clusters
  on the primary key; SQL Server clusters on the primary key by default but it's changeable;
  PostgreSQL and Oracle heap tables have **no automatically maintained clustering at all** by
  default (§16.10).
- **Selectivity and cardinality** determine whether an index candidate is good (high
  cardinality, e.g. `email`, `order_id`) or poor in isolation (low cardinality, e.g. `is_active`,
  `status`) — low-cardinality columns are often better served by a partial index than a plain
  one (§16.11).
- Recognize **Seq Scan, Index Scan, Index-Only Scan, and Bitmap Index/Heap Scan** on sight —
  they are the visible evidence of everything in this chapter, and the subject of Chapter 17
  (§16.12).

## What's Next

Chapter 16 taught you the *structures*. **Chapter 17 — Query Execution & the Query Planner**
teaches you how the database actually *decides* whether to use them: reading `EXPLAIN` and
`EXPLAIN ANALYZE` output in full, understanding cost estimation, join algorithms (nested loop,
hash join, merge join), and why the planner sometimes ignores an index you were certain it
would use — turning everything conceptual in this chapter into something you can observe,
measure, and diagnose directly.
