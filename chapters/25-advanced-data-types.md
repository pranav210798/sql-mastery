# Chapter 25 — Advanced Data Types (JSON/Array/UUID/ENUM/Full-Text)

> **Part VI — Database Internals & Production Engineering**
> Previous: [Chapter 24 — Temporary Tables](24-temporary-tables.md) · Next: [Chapter 26 — Partitioning](26-partitioning.md)

This chapter runs against `ecommerce_db`, `banking_db`, and `analytics_db`. If you haven't loaded them yet:

```bash
psql -f databases/ecommerce_db.sql
psql -f databases/banking_db.sql
psql -f databases/analytics_db.sql   # used for the JSONB events.payload examples in this chapter
```

> **Important Note**
> `analytics_db.events.payload` is populated using PostgreSQL's `random()` with no fixed seed (see the file header). That means the *exact* row counts and which specific `event_id`s match a given filter will differ slightly every time you reload that database. Every query shown against it in this chapter is real, runnable SQL — but where the output depends on that randomness, it's marked **(illustrative — your exact numbers will differ)**. Every example against `banking_db.audit_log`, by contrast, uses literal `INSERT` statements written out in this chapter, so those outputs are fully deterministic and reproducible exactly as shown.

---

## 25.0 What This Chapter Is Really About

Every table you've built so far in this course has used a small, disciplined set of types: integers, `VARCHAR`, `NUMERIC`, `DATE`, `TIMESTAMP`, `BOOLEAN`. That discipline was deliberate — Chapter 14 spent an entire chapter arguing for normalized, strongly-typed relational columns. This chapter is where that discipline meets its limits: what do you do when the data genuinely doesn't fit a fixed set of columns? A payment gateway's webhook payload has a different shape depending on which gateway sent it. A product's attributes differ wildly between a t-shirt (size, color) and a laptop (RAM, screen size). An audit trail needs to store "whatever the row looked like," for *any* table, without a different audit schema per table.

PostgreSQL's answer to these problems — and the reason it's the primary dialect of this course — is an unusually rich set of "advanced" types: `JSON`/`JSONB`, native arrays, `UUID`, `ENUM`, `XML`, dedicated network address types, and a full-text search engine built directly into the type system (`tsvector`/`tsquery`). No other mainstream RDBMS combines all of these natively. This chapter covers each one with the same rigor as Chapter 13's constraints, and — because dialect divergence here is unusually large — every section calls out exactly what MySQL, SQL Server, and Oracle can and cannot do instead.

**Quick reference — native type support across dialects:**

| Type | PostgreSQL | MySQL | SQL Server | Oracle |
|---|---|---|---|---|
| JSON | `JSON` (exact text) + `JSONB` (binary, indexable) | `JSON` (single type, binary-ish) | No native type — `NVARCHAR(MAX)` + `JSON_VALUE`/`JSON_QUERY`/`OPENJSON` | 12c+: `VARCHAR2`/`CLOB`/`BLOB` + `IS JSON`; native `JSON` type in 21c+ |
| Array | Native, any element type, GIN-indexable | None — simulate via `JSON` or a child table | None — simulate via `JSON` or a child table | `VARRAY` / nested tables (restrictive, rarely used for this) |
| UUID | Native `UUID` type + `gen_random_uuid()` | None — `CHAR(36)` or `BINARY(16)` | `UNIQUEIDENTIFIER` + `NEWID()`/`NEWSEQUENTIALID()` | `RAW(16)` + `SYS_GUID()` |
| ENUM | `CREATE TYPE ... AS ENUM` | Inline `ENUM(...)` column type | None — `CHECK` or lookup table | None — `CHECK` or lookup table |
| XML | `xml` type + `xpath()` | Limited — `ExtractValue()`/`UpdateXML()` on text | `xml` type + `.nodes()`/`.value()`/`.query()` | `XMLType` + `XMLTable`/`XMLQuery` |
| Network address | `INET`, `CIDR`, `MACADDR`/`MACADDR8`, subnet operators | None — plain `VARCHAR` | None — plain `VARCHAR` (or CLR type) | None — plain `VARCHAR2` |
| Full-text search | `tsvector`/`tsquery` + GIN index | `FULLTEXT` index + `MATCH...AGAINST` | Full-text index + `CONTAINS`/`FREETEXT` | Oracle Text |

Keep this table nearby — the rest of the chapter fills in every cell with syntax, behavior, and worked examples.

---

## 25.1 JSON and JSONB

### 1. Simple explanation
`JSON` and `JSONB` let a single column hold a whole structured document — objects, arrays, nested values — instead of forcing every possible field into its own rigid column. `JSON` keeps exactly what you typed in, character for character. `JSONB` re-organizes it into an efficient internal format the moment you store it, which makes it much faster to search but means it no longer remembers your original formatting.

### 2. Technical explanation — JSON vs JSONB, precisely

> **[PostgreSQL]** is the only mainstream dialect with two distinct JSON types, and the difference is one of the most commonly misunderstood facts in PostgreSQL. Get this exactly right:

| Property | `JSON` | `JSONB` |
|---|---|---|
| Storage format | Exact input text, stored as-is | Decomposed binary format |
| Re-parses on every read? | Yes — every access re-parses the raw text | No — parsed once at write time |
| Preserves whitespace/formatting? | Yes | No |
| Preserves key order? | Yes | No — reordered internally (see below) |
| Preserves duplicate keys? | Yes, in the raw text | No — only the **last** value for a duplicate key survives |
| Indexable (GIN)? | No | Yes |
| Supports containment/existence operators (`@>`, `?`, etc.)? | No (must cast to `jsonb` first) | Yes, natively |
| Write speed | Faster (no parsing/validation of structure beyond syntax) | Slightly slower (must decompose on write) |
| Read/query speed | Slower (re-parses every time) | Much faster |

The decisive, concrete demonstration of "preserves order" vs "reorders":

```sql
SELECT '{"customer_id": 1, "name": "Ravi Shankar", "email": "ravi.shankar@mail.com"}'::json  AS as_json,
       '{"customer_id": 1, "name": "Ravi Shankar", "email": "ravi.shankar@mail.com"}'::jsonb AS as_jsonb;
```
```
                                      as_json                                       |                                     as_jsonb
-------------------------------------------------------------------------------------+-----------------------------------------------------------------------------------
 {"customer_id": 1, "name": "Ravi Shankar", "email": "ravi.shankar@mail.com"}         | {"name": "Ravi Shankar", "email": "ravi.shankar@mail.com", "customer_id": 1}
```
The `json` column reproduces your exact input, key for key, in the order you wrote them. The `jsonb` column has reordered the keys — internally, `jsonb` stores object keys sorted by **key length first, then byte order**: `name` (4 chars) sorts before `email` (5 chars), which sorts before `customer_id` (11 chars). This is not a bug or a display quirk; it's how the decomposed binary format is physically laid out so that key lookups can use binary search instead of a linear scan.

The duplicate-key difference:
```sql
SELECT '{"status": "PENDING", "status": "PAID"}'::json  AS as_json,
       '{"status": "PENDING", "status": "PAID"}'::jsonb AS as_jsonb;
```
```
                as_json                 |     as_jsonb
-----------------------------------------+-------------------
 {"status": "PENDING", "status": "PAID"} | {"status": "PAID"}
```
`json` stores both keys verbatim, exactly as typed. `jsonb` collapses them at parse time, keeping only the **last** occurrence — the duplicate is gone permanently, not just hidden.

> **[MySQL]**: has a single `JSON` type. Internally MySQL stores it in an optimized binary format for fast key/path lookups — conceptually much closer in spirit to PostgreSQL's `JSONB` than to `JSON` (no exact-text preservation, no duplicate-key preservation). There is no MySQL equivalent of PostgreSQL's exact-text `JSON` type.
> **[SQL Server]**: has **no native JSON type at all**. JSON is stored as plain `NVARCHAR(MAX)` text; `ISJSON()` validates it's well-formed (usable in a `CHECK` constraint), and `JSON_VALUE()`, `JSON_QUERY()`, and `OPENJSON()` operate on that text at query time — meaning SQL Server re-parses the text on every access, much like PostgreSQL's `json` type, except SQL Server has only this one option.
> **[Oracle]**: 12c+ supports JSON stored in `VARCHAR2`, `CLOB`, or `BLOB` columns, validated with an `IS JSON` check constraint, and queried with `JSON_VALUE`/`JSON_QUERY`/`JSON_TABLE`. Oracle 21c+ introduces a genuine native `JSON` binary type (OSON format) that behaves much more like PostgreSQL's `JSONB` — decomposed storage, faster access, and function-based indexing support.

### 3. Why it exists
Relational columns assume you know the shape of your data in advance. Real systems constantly need to store things that don't have a fixed shape: a webhook payload from a third-party payment provider, a mobile app event with device-specific fields, an audit snapshot of "whatever this row's columns happened to be." Before native JSON types, teams either serialized this into a plain `TEXT` column (no validation, no querying without pulling every row into application code) or built brittle Entity-Attribute-Value (EAV) schemas (one row per attribute — technically relational, but painful to query and index). `JSON`/`JSONB` gives you a genuine middle ground: structured enough to validate, index, and query with real SQL operators, flexible enough to not require a schema migration every time a new field shows up.

### 4. Full syntax — construction

```sql
-- Build an object directly from key/value pairs
SELECT jsonb_build_object('source', 'ios', 'app_version', '4.2.0');
-- {"source": "ios", "app_version": "4.2.0"}

-- Build an array
SELECT jsonb_build_array(1, 2, 3, 'four');
-- [1, 2, 3, "four"]

-- Convert an existing SQL value (scalar, row, or array) into jsonb
SELECT to_jsonb(ARRAY['ios','android','web']);
-- ["ios", "android", "web"]

-- Convert an entire row into a jsonb object (column names become keys)
SELECT to_jsonb(c) FROM ecommerce_db.categories c WHERE category_id = 2;
-- {"category_id": 2, "category_name": "Mobiles", "parent_category_id": 1}
```

### 5. Full syntax — querying operators

| Operator | Meaning | Input | Output |
|---|---|---|---|
| `->` | Get JSON object field / array element by key or index | `jsonb`/`json` | `jsonb`/`json` |
| `->>` | Get JSON object field / array element **as text** | `jsonb`/`json` | `text` |
| `#>` | Get JSON value at the specified **path** (array of keys) | `jsonb`/`json` | `jsonb`/`json` |
| `#>>` | Get JSON value at the specified path **as text** | `jsonb`/`json` | `text` |
| `@>` | Left contains right (does the document contain this sub-structure?) | `jsonb` only | `boolean` |
| `<@` | Left is contained by right | `jsonb` only | `boolean` |
| `?` | Does the top-level key/element string exist? | `jsonb` only | `boolean` |
| `?\|` | Does *any* of these top-level keys exist? | `jsonb` only | `boolean` |
| `?&` | Do *all* of these top-level keys exist? | `jsonb` only | `boolean` |
| `\|\|` | Concatenate/merge two jsonb objects or arrays (right side wins on key conflicts) | `jsonb` only | `jsonb` |
| `-` | Delete a key (text) or array element (integer index) | `jsonb` only | `jsonb` |
| `#-` | Delete the value at the given path | `jsonb` only | `jsonb` |

### 6. Worked examples — `banking_db.audit_log`

`banking_db.audit_log.old_data`/`new_data` are `JSONB` columns, already declared in the canonical schema (Chapter 22's Triggers chapter is what will populate this table automatically going forward — it starts empty in the seed data). To have deterministic, reproducible rows to query in this chapter, insert four illustrative audit rows that model exactly what a trigger-based audit system would write:

```sql
INSERT INTO banking_db.audit_log (audit_id, table_name, operation, row_pk, changed_by, old_data, new_data) VALUES
(1, 'accounts', 'UPDATE', '7', 'app_user',
   '{"account_id": 7, "customer_id": 5, "account_type": "CURRENT", "balance": 5000.00, "status": "FROZEN"}'::jsonb,
   '{"account_id": 7, "customer_id": 5, "account_type": "CURRENT", "balance": 7500.00, "status": "ACTIVE"}'::jsonb),
(2, 'loans', 'INSERT', '5', 'loan_officer_3',
   NULL,
   '{"loan_id": 5, "customer_id": 5, "loan_amount": 200000.00, "status": "ACTIVE",
     "terms": {"interest_rate": 9.00, "term_months": 36}}'::jsonb),
(3, 'accounts', 'DELETE', '6', 'app_user',
   '{"account_id": 6, "customer_id": 4, "account_type": "SAVINGS", "balance": 0.00, "status": "CLOSED"}'::jsonb,
   NULL),
(4, 'customers', 'UPDATE', '2', 'app_user',
   '{"customer_id": 2, "email": "neha.agarwal@mail.com"}'::jsonb,
   '{"customer_id": 2, "email": "neha.a.new@mail.com"}'::jsonb);
SELECT setval('banking_db.audit_log_audit_id_seq', 4);
```

**Extracting a field with `->>`:**
```sql
SELECT audit_id,
       old_data ->> 'status' AS old_status,
       new_data ->> 'status' AS new_status
FROM banking_db.audit_log
WHERE table_name IN ('accounts');
```
```
 audit_id | old_status | new_status
----------+------------+------------
        1 | FROZEN     | ACTIVE
        3 | CLOSED     |
```
`audit_id = 3` shows `new_status` as blank/`NULL` — the row was deleted, so `new_data` itself is `NULL`, and `->>` applied to a SQL `NULL` simply returns `NULL` (it does not error).

**Extracting a nested field with `#>` and `#>>`:**
```sql
SELECT audit_id,
       new_data #> '{terms,interest_rate}'  AS rate_as_jsonb,
       new_data #>> '{terms,interest_rate}' AS rate_as_text
FROM banking_db.audit_log
WHERE audit_id = 2;
```
```
 audit_id | rate_as_jsonb | rate_as_text
----------+---------------+--------------
        2 | 9.00          | 9.00
```
The path `'{terms,interest_rate}'` is a text array literal meaning "go into the `terms` object, then get `interest_rate`." `#>` returns it still as `jsonb` (here, a JSON number); `#>>` returns the same value cast to `text`.

**Containment with `@>`:**
```sql
SELECT audit_id, table_name, operation
FROM banking_db.audit_log
WHERE new_data @> '{"status": "ACTIVE"}';
```
```
 audit_id | table_name | operation
----------+------------+-----------
        1 | accounts   | UPDATE
        2 | loans      | INSERT
```
`@>` asks "does `new_data`, as a whole, contain this key/value pair somewhere at the top level?" — it does not require an exact match of the whole document, just that the given fragment is a subset of it. Row 4 (`customers`) is correctly excluded — its `new_data` has no `status` key at all.

**Key existence with `?`, `?|`, `?&`:**
```sql
SELECT audit_id, table_name
FROM banking_db.audit_log
WHERE old_data ? 'balance';
```
```
 audit_id | table_name
----------+------------
        1 | accounts
        3 | accounts
```
```sql
-- ?| : at least one of these keys exists at the top level
SELECT audit_id FROM banking_db.audit_log WHERE new_data ?| ARRAY['terms', 'email'];
-- audit_id 2 (has "terms") and audit_id 4 (has "email")

-- ?& : ALL of these keys must exist at the top level
SELECT audit_id FROM banking_db.audit_log WHERE old_data ?& ARRAY['account_id', 'balance'];
-- audit_id 1 and 3 — both keys present in both rows
```

**Updating a JSONB field with `jsonb_set`:**
```sql
UPDATE banking_db.audit_log
SET new_data = jsonb_set(new_data, '{balance}', '8000.00', false)
WHERE audit_id = 1
RETURNING new_data ->> 'balance' AS updated_balance;
```
```
 updated_balance
------------------
 8000.00
```
`jsonb_set(target, path, new_value, create_missing)` takes: the source `jsonb`, a `text[]` path (`'{balance}'` here means the top-level `balance` key; for a nested field it would be `'{terms,interest_rate}'`), the replacement value (which must itself be valid `jsonb` — note the numeric literal `'8000.00'` is passed as a `jsonb` number, not a plain SQL numeric), and a boolean controlling whether to create the key if it's missing (the `false` here means "only update, never insert" — if `balance` didn't exist, this call would be a no-op).

### 7. Worked example — `analytics_db.events.payload`

Every row in `analytics_db.events` was generated with `jsonb_build_object('source', <one of 'web'/'ios'/'android'>)`, so `payload` is always a flat one-key object.

```sql
SELECT event_id, user_id, event_type, payload
FROM analytics_db.events
WHERE payload @> '{"source": "ios"}'
LIMIT 5;
```
```
 event_id | user_id | event_type |         payload
----------+---------+------------+--------------------------
     1042 |     301 | LOGIN      | {"source": "ios"}
     1055 |     302 | PURCHASE   | {"source": "ios"}
     ...
```
**(illustrative — exact `event_id`s and how many rows exist will differ on your machine, since `payload`'s `source` value is assigned with `random()` at load time)**. What *is* guaranteed regardless of randomness:

```sql
-- Every row's payload always has a "source" key by construction — this
-- returns the same row count as SELECT count(*) FROM events, deterministically.
SELECT count(*) FROM analytics_db.events WHERE payload ? 'source';
SELECT count(*) FROM analytics_db.events;
-- both queries return identical counts
```

**Indexing JSONB with GIN:**
```sql
CREATE INDEX idx_events_payload_gin ON analytics_db.events USING GIN (payload);

-- Now this containment query can use an index scan instead of a sequential scan:
EXPLAIN SELECT * FROM analytics_db.events WHERE payload @> '{"source": "ios"}';
```
The default GIN operator class for `jsonb` (`jsonb_ops`) indexes every key and every value, which supports `@>`, `?`, `?|`, and `?&` — but produces a larger index. If you know you will only ever use `@>` (the most common case in practice — "does this document contain this fragment"), the `jsonb_path_ops` operator class produces a smaller, faster index at the cost of not supporting `?`/`?|`/`?&`:
```sql
CREATE INDEX idx_events_payload_pathops ON analytics_db.events USING GIN (payload jsonb_path_ops);
```

### 8. Internal behavior
`JSONB`'s decomposed format stores each object's keys sorted (by length, then byte order, as shown above) so that key lookups (`->`, `->>`, `#>`) can use an internal binary-search-like scan instead of scanning every key sequentially — a real, measurable performance difference on documents with many keys. `JSON`, in contrast, is stored as literal text; every single access — even a lookup of one key — requires PostgreSQL to re-parse the entire text value from scratch on every row, every time. This is the entire reason `JSONB` is the default recommendation in modern PostgreSQL: you almost always query into a JSON document more often than you write it, and `JSONB` optimizes for exactly that access pattern at a small, one-time write-side cost.

### 9. Common mistakes
- Using `JSON` instead of `JSONB` "because it sounds more standard," then discovering you can't index it or use `@>`/`?` at all — you must explicitly `::jsonb` cast it first, which defeats the purpose.
- Comparing `jsonb` values with `=` when the object might have differently-ordered keys typed by a human or a different client library — remember, `jsonb` canonicalizes key order internally, so `'{"a":1,"b":2}'::jsonb = '{"b":2,"a":1}'::jsonb` is actually `TRUE` (both normalize to the same internal representation) — but this is *not* true for the `json` type, where the two differently-ordered literals are **not** equal as text.
- Forgetting that `->` returns `jsonb`/`json`, not `text` — `WHERE payload -> 'source' = 'ios'` will fail to match, because the left side is a JSON string (`"ios"` with quotes) being compared to a plain SQL text literal. Use `->>` for text comparisons: `WHERE payload ->> 'source' = 'ios'`.
- Passing a raw SQL value where `jsonb_set` expects a `jsonb` value for its `new_value` argument — `jsonb_set(new_data, '{balance}', 8000.00)` (an unquoted numeric) will error; it must be `to_jsonb(8000.00)` or the jsonb literal `'8000.00'`.

### 10. Edge cases
> **⚠️ Warning — `@>` is not "equals" or "is a subset of, at any depth"**
> `@>` containment only matches nested objects/arrays structurally, not partial array membership by "any level." `'{"a": {"b": 1, "c": 2}}'::jsonb @> '{"a": {"b": 1}}'::jsonb` is `TRUE` (nested object containment works), but `'{"tags": ["a","b","c"]}'::jsonb @> '{"tags": ["a"]}'::jsonb` is also `TRUE` — array containment checks "is this a subset of elements," not "is this an exact match," which trips people up in the opposite direction: don't assume `@>` on an array field guarantees the array *only* contains what you specified.

### 11. When to use / not use
Use `JSONB` when you need to query into the document (filter, index, extract fields) — which is the overwhelming majority of real use cases. Use plain `JSON` only in the rare case where you must preserve the exact original byte-for-byte document (e.g., a legal/compliance requirement to store precisely what a third party sent, including their formatting and any duplicate keys) and you will only ever retrieve it whole, never query into it. Do not use either as a substitute for columns you actually query, filter, join, or aggregate on regularly — see §25.9 for the full framework.

### 12. Real-world use cases
Webhook/event payload storage (`analytics_db.events.payload`), audit trails that must capture "whatever this row looked like" for any table without a bespoke schema per table (`banking_db.audit_log`), user preference/settings blobs, API response caching, feature flags with per-tenant overrides.

---

## 25.2 Arrays

### 1. Simple explanation
An array column stores a list of values — several tags, several phone numbers, several colors — directly inside one column of one row, instead of needing a separate table.

### 2. Technical explanation
> **[PostgreSQL]**: any base type (and most composite types) can be declared as an array by appending `[]` to the type — `TEXT[]`, `INT[]`, even multi-dimensional arrays (`INT[][]`). Arrays are a genuine, first-class type with dedicated operators, aggregate/expansion functions, and index support — this is unusually powerful compared to other RDBMSes.
> **[MySQL, SQL Server]**: **no native array type exists at all.** The two idiomatic workarounds are (a) a `JSON` array column, queried with JSON path functions, or (b) a proper child table (one row per element) joined back to the parent — which is almost always the better choice when the elements need independent querying (see the trade-off discussion below).
> **[Oracle]**: supports `VARRAY` (a fixed-maximum-size ordered collection, stored inline or out-of-line) and nested tables (an unordered collection stored in a separate segment), but both are considerably more restrictive than PostgreSQL arrays — `VARRAY` requires declaring a maximum size up front, and querying into individual elements with standard SQL (rather than PL/SQL) is comparatively awkward. In practice, most modern Oracle schemas reach for JSON over `VARRAY`/nested tables for this kind of requirement.

### 3. Why it exists
Some attributes are genuinely list-shaped and small — a handful of tags on a product, a list of phone numbers for a contact — where creating an entire separate table, with its own primary key, foreign key, and joins, feels like overhead disproportionate to the data. PostgreSQL's array type lets you model "a small, bounded, usually-together list" directly in one column, while still providing real operators to search, index, and expand that list when you need to.

### 4. Full syntax
```sql
-- Declaring an array column (illustrative addition — not part of the canonical schema)
ALTER TABLE ecommerce_db.products ADD COLUMN tags TEXT[] DEFAULT '{}';

-- Array literals
UPDATE ecommerce_db.products SET tags = '{bestseller,new-arrival}' WHERE product_id = 1;
UPDATE ecommerce_db.products SET tags = ARRAY['clearance', 'sale']  WHERE product_id = 5;

-- Reading them back
SELECT product_id, product_name, tags FROM ecommerce_db.products WHERE product_id IN (1, 5);
```
```
 product_id |  product_name   |          tags
------------+------------------+-------------------------
          1 | Galaxy Phone X   | {bestseller,new-arrival}
          5 | Men Cotton Shirt | {clearance,sale}
```

**`unnest()` — expanding an array into rows:**
```sql
SELECT product_id, product_name, unnest(tags) AS tag
FROM ecommerce_db.products
WHERE product_id IN (1, 5);
```
```
 product_id |   product_name   |    tag
------------+------------------+--------------
          1 | Galaxy Phone X   | bestseller
          1 | Galaxy Phone X   | new-arrival
          5 | Men Cotton Shirt | clearance
          5 | Men Cotton Shirt | sale
```
`unnest()` turns a one-row, one-array-valued column into many rows, one per element — a set-returning function, exactly the family covered in Chapter 20.

**Array operators:**
| Operator | Meaning | Example |
|---|---|---|
| `@>` | Left array contains all elements of right array | `tags @> ARRAY['sale']` |
| `<@` | Left array is contained by right array | `ARRAY['sale'] <@ tags` |
| `&&` | Arrays overlap (share at least one element) | `tags && ARRAY['sale','clearance']` |
| `= ANY(arr)` | Scalar equals any element in the array | `'sale' = ANY(tags)` |
| `= ALL(arr)` | Scalar equals every element in the array | rarely useful for tag-style columns |

```sql
SELECT product_id, product_name FROM ecommerce_db.products WHERE tags @> ARRAY['bestseller'];
-- product_id 1 (Galaxy Phone X)

SELECT product_id, product_name FROM ecommerce_db.products WHERE tags && ARRAY['sale', 'clearance'];
-- product_id 5 (Men Cotton Shirt) — matches on overlap, doesn't require both tags present

SELECT product_id, product_name FROM ecommerce_db.products WHERE 'sale' = ANY(tags);
-- product_id 5 — same result as the containment form above, different syntax
```

**Indexing arrays with GIN:**
```sql
CREATE INDEX idx_products_tags ON ecommerce_db.products USING GIN (tags);
```
This accelerates `@>`, `<@`, and `&&` lookups — without it, any array-containment query is a sequential scan evaluating the array on every row.

### 5. Line-by-line
- `TEXT[]` declares an array of `TEXT` — PostgreSQL does not enforce a fixed length or dimension at the type-declaration level; `'{bestseller,new-arrival}'` and `'{a,b,c,d,e}'` can both live in the same column.
- `'{bestseller,new-arrival}'` is the PostgreSQL array literal syntax — curly braces, comma-separated, quoted if elements contain commas/spaces/special characters (`'{"new arrival","end of season"}'`).
- `ARRAY['clearance', 'sale']` is the SQL-friendlier constructor form — functionally identical to the curly-brace literal, but more readable and safer when values come from parameters/variables.

### 6. Internal behavior
Small arrays are stored inline with the row; PostgreSQL's general TOAST mechanism (Chapter 29 covers storage internals) will compress or move large arrays out-of-line once they exceed roughly 2KB, exactly like it does for large `TEXT`/`JSONB` values. Each array access (`unnest`, an operator, an index lookup) walks or expands the whole array value — there's no way to fetch "just the third element" without pulling in the entire array from storage first.

### 7. Common mistakes
- Assuming `tags @> ARRAY['sale']` will use a plain B-tree index on `tags` — it won't; array containment operators need a GIN index specifically, not the default B-tree PostgreSQL would create otherwise.
- Trying to enforce that array elements are unique, non-null, or reference another table (e.g., "every tag in `tags` must exist in a `valid_tags` table") — none of that is expressible as a simple constraint on an array column. This is exactly the kind of integrity rule a proper join table gives you for free (a foreign key), and an array column cannot.
- Forgetting `unnest()` when you need to `GROUP BY`, `COUNT`, or join on individual elements — treating the whole array as a single value in an aggregate query silently produces the wrong answer (it aggregates over *arrays*, not over *tags*).

### 8. Edge cases
Array indices in PostgreSQL are **1-based**, not 0-based (`tags[1]` is the first element) — a frequent source of off-by-one bugs for anyone coming from most programming languages. An out-of-bounds index (`tags[99]` on a 2-element array) does not error; it simply returns `NULL`.

### 9. When to use / not use — arrays vs. a proper join table

> **Important Note — the real trade-off**
> Arrays are a fine, pragmatic choice for small, denormalized, rarely-independently-queried lists that conceptually "belong" entirely to one row — a handful of tags shown on a product page, a short list of aliases. A dedicated many-to-many join table is the better choice the moment **any** of the following becomes true:
> - You need to query "give me all products with tag X" efficiently and at scale (a join with an indexed foreign key beats scanning/GIN-probing an array column once the tag vocabulary or product count grows large).
> - You need to enforce referential integrity on the individual values (a `tag_id` foreign key guarantees the tag actually exists and is spelled consistently; an array of free-text strings has no such guarantee — `'bestseler'` typo included).
> - You need to aggregate or report by the individual element (count products per tag, find the most-used tag) — this requires `unnest()`-ing every row on every query with an array, versus a plain `GROUP BY` on an indexed column with a join table.
> - You need metadata *about* the relationship itself (e.g., "who added this tag, and when" — a join table can carry extra columns; an array element cannot).

**The join-table equivalent**, shown for comparison against the array design above:
```sql
CREATE TABLE ecommerce_db.tags (
    tag_id   SERIAL PRIMARY KEY,
    tag_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE ecommerce_db.product_tags (
    product_id INT NOT NULL REFERENCES ecommerce_db.products(product_id) ON DELETE CASCADE,
    tag_id     INT NOT NULL REFERENCES ecommerce_db.tags(tag_id) ON DELETE CASCADE,
    PRIMARY KEY (product_id, tag_id)
);

-- "all products tagged 'sale'" — an ordinary, indexable join:
SELECT p.product_id, p.product_name
FROM ecommerce_db.products p
JOIN ecommerce_db.product_tags pt ON pt.product_id = p.product_id
JOIN ecommerce_db.tags t          ON t.tag_id = pt.tag_id
WHERE t.tag_name = 'sale';
```
This is more verbose to write and requires an extra join for every tag lookup — but it gives you referential integrity on tag spelling, `COUNT(*) GROUP BY tag_id` for free, standard B-tree indexing, and no GIN index maintenance overhead. **Rule of thumb: reach for an array when the list is a display-only convenience; reach for a join table the moment the individual elements need to be queried, joined, counted, or validated on their own.**

### 10. Real-world use cases
Product tags/labels (display-only), a short list of alternate email addresses on a contact, a permissions bitmap-style list of feature flags per user, storing the days-of-week a recurring event repeats on (`INT[]` of 1–7).

---

## 25.3 UUID

### 1. Simple explanation
A `UUID` is a 128-bit value, almost always shown as 32 hex digits split into five groups (`a1b2c3d4-e5f6-4890-9abc-def012345678`), designed so that two different computers — with no coordination between them at all — can each generate one and be astronomically unlikely to ever produce the same value.

### 2. Technical explanation
A UUID (Universally Unique Identifier) is generated either randomly (version 4 — 122 random bits) or from a combination of a timestamp and other inputs (version 1, and the newer version 7). Its defining property is that uniqueness is achieved **without a central authority handing out the next number** — unlike `SERIAL`/`IDENTITY`, which requires a single sequence object (and therefore, implicitly, a single database) counting upward.

### 3. Why it exists — as a primary key alternative to `SERIAL`/`IDENTITY`
- **Distributed generation.** Multiple application servers, offline mobile clients, or entirely separate database shards can each generate primary keys independently, with no risk of collision when the data is later merged — impossible with an auto-incrementing integer, where two separate databases will both produce `id = 1`, `id = 2`, ... and collide the moment you try to combine them.
- **No leaked sequential information.** A `SERIAL` order ID of `48213` tells any competitor or curious customer, "this business has processed roughly 48,000 orders total." A UUID order ID leaks nothing about volume, growth rate, or order sequence.
- **Safe to assign before the row is inserted.** A client can generate the UUID locally (e.g., in the application layer or even offline) and know the final primary key value before the `INSERT` ever reaches the database — useful for constructing related rows in the same request without a round trip to fetch a generated ID back.

### 4. Full syntax and generation functions by dialect

**[PostgreSQL 13+]** — built into core, no extension required:
```sql
SELECT gen_random_uuid();
-- e.g. a1b2c3d4-e5f6-4890-9abc-def012345678   (illustrative — genuinely random each call)

CREATE TABLE ecommerce_db.orders_uuid_demo (
    order_uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    INT NOT NULL REFERENCES ecommerce_db.users(user_id),
    order_date TIMESTAMP NOT NULL DEFAULT now()
);
```
> **[PostgreSQL, pre-13]**: `gen_random_uuid()` required `CREATE EXTENSION pgcrypto;`. An alternative, `uuid_generate_v4()`, is provided by the older `uuid-ossp` extension (`CREATE EXTENSION "uuid-ossp";`) and produces the same style of random (v4) UUID.

**[MySQL]** — no native type:
```sql
CREATE TABLE orders_uuid_demo (
    order_uuid CHAR(36) PRIMARY KEY DEFAULT (UUID()),   -- readable but wastes space
    user_id    INT NOT NULL
);
-- more storage-efficient (MySQL 8.0+): store as BINARY(16), convert at the boundary
INSERT INTO orders_uuid_demo (order_uuid, user_id) VALUES (UUID_TO_BIN(UUID()), 42);
SELECT BIN_TO_UUID(order_uuid) FROM orders_uuid_demo;
```
A `CHAR(36)` UUID costs 36 bytes (plus overhead) per value versus 16 bytes for the equivalent binary form — a meaningful difference at scale, both in storage and in index size.

**[SQL Server]**:
```sql
CREATE TABLE orders_uuid_demo (
    order_uuid UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
    user_id    INT NOT NULL
);
-- or DEFAULT NEWSEQUENTIALID() — see the fragmentation discussion below
```

**[Oracle]**:
```sql
CREATE TABLE orders_uuid_demo (
    order_uuid RAW(16) DEFAULT SYS_GUID() PRIMARY KEY,
    user_id    NUMBER NOT NULL
);
```
> **⚠️ Warning**: Oracle's `SYS_GUID()` produces a 16-byte globally-unique value, but it is **not** RFC 4122-compliant (it does not set the version/variant bits a standard UUID requires), so it won't necessarily round-trip cleanly through libraries or systems expecting a strict RFC 4122 UUID string format.

### 5. The real performance trade-off — random UUIDs and index fragmentation

> **⚠️ Warning — random UUID primary keys hurt insert performance and index locality**
> An auto-incrementing integer key (`SERIAL`, `IDENTITY`, `AUTO_INCREMENT`) always produces the next value strictly greater than the last. Every new row's key is inserted at the **rightmost edge** of the primary key's B-tree — the same handful of index pages stay "hot" in the buffer cache, and new inserts mostly just append, causing minimal page splits.
>
> A **random** UUID (version 4) has no such ordering. Each new value lands at an essentially random position across the *entire* keyspace of the index. This means:
> - Inserts touch index pages scattered all over the table, not just the last page — far worse buffer-cache locality, more disk I/O under real (non-cached) working sets.
> - Random insert positions cause far more mid-tree page splits, leaving the index more fragmented and larger on disk than a sequential-key index holding the same number of rows.
> - This effect is dramatically worse for a **clustered index** (SQL Server, MySQL/InnoDB's primary key) where the *table's physical row order* follows the key — random UUIDs scatter the actual table rows across storage, not just the index.
>
> **Modern mitigation: time-ordered UUIDs (UUIDv7).** UUID version 7 (standardized in RFC 9562, 2024) embeds a 48-bit millisecond Unix timestamp as the *leading* bits of the value, with the remaining bits randomized. The result: UUIDs generated close together in time sort close together in value — giving back most of the sequential-integer insert locality while remaining globally unique and coordination-free to generate. **[PostgreSQL 18+]** ships a built-in `uuidv7()` function generating exactly this. Where it isn't yet available natively, ULIDs (a closely related, lexicographically-sortable identifier format) are a common application-layer substitute with the same goal.

### 6. Common mistakes
- Using `CHAR(36)`/`VARCHAR(36)` to store a UUID in a dialect with no native type, then comparing/sorting it as plain text — text comparison of hex strings is slower and larger than native 16-byte binary comparison, and offers none of a native type's format validation.
- Assuming a UUID primary key means you no longer need an index on a natural lookup column (e.g., `orders.order_number` shown to customers) — a UUID is a fine internal surrogate key, but you'll usually still want a separate, human-readable, indexed identifier for anything customers see or type.
- Blindly swapping every `SERIAL` primary key for a UUID "for security," without accounting for the insert-locality cost above, on a genuinely high-write-volume table.

### 7. When to use / not use
Use UUIDs when rows are created by multiple independent systems that must later be merged without collision (microservices, offline-first mobile apps, multi-region writes), or when the primary key value must not reveal sequence/volume information externally. Prefer `SERIAL`/`IDENTITY` (or a time-ordered UUIDv7 if you need both properties) for high-throughput, single-writer tables where insert locality and index compactness matter more than distributed generation.

### 8. Real-world use cases
Distributed microservice-generated entity IDs, public-facing API resource identifiers (a REST API returning `/orders/a1b2c3d4-...` reveals nothing about total order volume, unlike `/orders/48213`), offline-capable mobile app records created before ever reaching a server, event/message IDs in a distributed message queue.

---

## 25.4 ENUM

### 1. Simple explanation
An `ENUM` is a type that only accepts a fixed, named list of values — like a multiple-choice question where nothing outside the listed options is a valid answer.

### 2. Technical explanation and dialect comparison

> **[PostgreSQL]**: `ENUM` is a genuine user-defined type, created once and then reused across any number of columns/tables:
```sql
CREATE TYPE order_status_enum AS ENUM ('PENDING','PAID','SHIPPED','DELIVERED','CANCELLED');

-- illustrative alternative design for ecommerce_db.orders.status, which today
-- uses a CHECK constraint (Chapter 13) instead of a native ENUM:
CREATE TABLE ecommerce_db.orders_enum_demo (
    order_id INT PRIMARY KEY,
    status   order_status_enum NOT NULL DEFAULT 'PENDING'
);
```
> **[MySQL]**: `ENUM(...)` is declared **inline, per column** — there is no separate reusable named type the way PostgreSQL has:
```sql
CREATE TABLE orders_enum_demo (
    order_id INT PRIMARY KEY,
    status   ENUM('PENDING','PAID','SHIPPED','DELIVERED','CANCELLED') NOT NULL DEFAULT 'PENDING'
);
```
> Internally, MySQL stores each `ENUM` value as a small integer (1 or 2 bytes) representing its **position in the declared list** — meaning `ORDER BY status` sorts by declaration order, not alphabetically. This can be a genuine feature (lifecycle columns sort in lifecycle order for free) or a silent gotcha (someone assumes alphabetical sort and gets lifecycle order instead).
> **[SQL Server, Oracle]**: **no native `ENUM` type at all.** The only options are a `CHECK` constraint (exactly what `ecommerce_db.orders.status`, `payments.payment_method`, `banking_db.accounts.status`, etc. already use in this course's real schema — see Chapter 13) or a foreign-key lookup table.

### 3. Why it exists
Some attributes really do only ever take on a small, known set of values, and encoding that directly in the type system is both self-documenting (`order_status_enum` tells every reader exactly what's valid, right in the schema) and compact (MySQL's integer-backed storage; PostgreSQL's enum values are stored as 4-byte OIDs internally but compare via a cheap lookup rather than string comparison).

### 4. The real trade-off: ENUM vs CHECK vs lookup table

> **Important Note — modifying an ENUM is the crux of this trade-off**
> **Adding** a new PostgreSQL enum value is easy:
> ```sql
> ALTER TYPE order_status_enum ADD VALUE 'RETURNED' AFTER 'DELIVERED';
> ```
> But PostgreSQL provides **no way to remove or reorder** an existing enum value. If a value must be removed (a status is retired, a typo needs fixing), the only path is recreating the type entirely:
> ```sql
> BEGIN;
> ALTER TYPE order_status_enum RENAME TO order_status_enum_old;
> CREATE TYPE order_status_enum AS ENUM ('PENDING','PAID','SHIPPED','DELIVERED','CANCELLED');
> ALTER TABLE ecommerce_db.orders_enum_demo
>     ALTER COLUMN status TYPE order_status_enum USING status::text::order_status_enum;
> DROP TYPE order_status_enum_old;
> COMMIT;
> ```
> This rewrites every row's `status` column and requires an exclusive lock on the table for the duration — genuinely disruptive on a large, busy table. There is also a subtler restriction worth knowing: a newly `ADD VALUE`'d enum label cannot be used in the same transaction that added it (in PostgreSQL versions before 12, `ADD VALUE` could not even run inside a transaction block at all; PostgreSQL 12+ allows it inside a transaction, but the new value still only becomes usable once that transaction commits).
>
> **Recommendation:** reach for `ENUM` (or a plain `CHECK (col IN (...))`, which this course's schema already uses throughout — see Chapter 13) only for truly fixed, rarely-changing value sets defined by the business domain itself (a bank account's `SAVINGS`/`CURRENT`/`FIXED_DEPOSIT` types, a review's 1–5 star rating range). The moment a value set might need to grow, shrink, or be reordered **at runtime, by a non-developer** (e.g., an admin adding a new product category, a new shipping carrier, a new supported currency), use a proper foreign-key **lookup table** instead — adding a row to a `statuses` table requires no schema migration, no table lock, and no deployment at all.

```sql
-- Lookup-table equivalent — the recommended pattern for anything that might
-- need runtime-configurable values:
CREATE TABLE ecommerce_db.order_statuses (
    status_code VARCHAR(20) PRIMARY KEY,
    description VARCHAR(100) NOT NULL,
    sort_order  INT NOT NULL
);
INSERT INTO ecommerce_db.order_statuses VALUES
    ('PENDING', 'Order placed, awaiting payment', 1),
    ('PAID', 'Payment received', 2),
    ('SHIPPED', 'Order shipped', 3),
    ('DELIVERED', 'Order delivered', 4),
    ('CANCELLED', 'Order cancelled', 5);

-- orders.status would then be:
--   status VARCHAR(20) NOT NULL REFERENCES order_statuses(status_code)
-- Adding "RETURNED" later is a single INSERT — no ALTER TYPE, no table lock, no migration.
```

### 5. Common mistakes
- Treating MySQL's `ENUM` sort order (declaration order) as if it were alphabetical — a query relying on `ORDER BY status` to sort alphabetically will silently get lifecycle/declaration order instead.
- Reaching for `ENUM` for a value set business stakeholders will realistically want to change without a developer/deployment involved (shipping carriers, promotional categories) — this is precisely the case a lookup table exists for.
- In PostgreSQL, trying to `DROP VALUE` from an enum type expecting it to work like `ADD VALUE` — it does not exist as an operation at all.

### 6. When to use / not use
Use `ENUM`/`CHECK` for small, genuinely stable value sets tied to fixed business logic that the application code itself branches on (a transaction's `DEPOSIT`/`WITHDRAWAL`/`TRANSFER_IN`/`TRANSFER_OUT` type, as in `banking_db.transactions`). Use a lookup table the moment the value set is configuration data rather than business logic, needs additional attributes per value (a description, a display order, an "active" flag), or might need to change without a code deployment.

### 7. Real-world use cases
Fixed account/transaction type classifications in `banking_db` (already modeled via `CHECK` in this course's schema), a small set of well-known HTTP methods or log severity levels, a genuinely fixed rating scale.

---

## 25.5 XML (Brief)

> **Note on scope**: XML support is covered briefly here because JSON has largely superseded XML for new application development — smaller payloads, simpler parsing, native support in virtually every modern language and API framework. XML remains relevant mainly for **legacy systems** and **specific industry data-interchange formats** that were standardized before JSON's dominance (e.g., SOAP web services, financial messaging standards, healthcare document formats, and document-publishing formats requiring formal schema validation via XSD).

### 1. Simple explanation
`XML` stores a structured, tag-based document (`<order><item>...</item></order>`) and lets you query into it using path expressions, similar in spirit to how JSON path operators work.

### 2. Dialect comparison

> **[PostgreSQL]**: has a native `xml` type and an `xpath()` function returning an array of matched XML fragments:
```sql
-- illustrative — not part of the canonical schema
CREATE TABLE banking_db.loan_documents (
    document_id BIGSERIAL PRIMARY KEY,
    loan_id     INT NOT NULL REFERENCES banking_db.loans(loan_id),
    contract    XML NOT NULL
);

INSERT INTO banking_db.loan_documents (loan_id, contract) VALUES
(1, '<contract><borrower>Ravi Shankar</borrower><rate>8.50</rate></contract>');

SELECT xpath('/contract/rate/text()', contract) AS rate
FROM banking_db.loan_documents WHERE loan_id = 1;
-- {8.50}   -- a one-element text[] array
```
> **[SQL Server]**: has a native `xml` type with `.nodes()` (shred XML into a rowset), `.value()` (extract a scalar), `.query()` (run an XQuery expression), and `.exist()` (boolean existence check).
> **[Oracle]**: has `XMLType`, queried with `XMLTable`/`XMLQuery` (the modern, recommended approach) or the older `extract()`/`existsNode()` functions.
> **[MySQL]**: has comparatively limited native XML support — no dedicated XML column type; `ExtractValue()` and `UpdateXML()` operate on XML stored as plain text, and both are considered legacy/limited compared to MySQL's `JSON` support.

### 3. When to use / not use
Choose XML only when you're integrating with a system, standard, or legacy format that already mandates it (SOAP APIs, EDI/HL7-style industry interchange, documents requiring XSD schema validation). For new application development where you control both ends, JSON/JSONB is simpler, smaller, faster to parse, and better supported across the modern tooling ecosystem — there is very rarely a reason to choose XML for a brand-new schema today.

---

## 25.6 Network Types **[PostgreSQL]**

### 1. Simple explanation
`INET`, `CIDR`, and `MACADDR` store IP addresses, network ranges, and hardware addresses as their own real types — not as text — so the database can validate them, sort them correctly, and answer questions like "is this IP inside this subnet?" directly.

### 2. Technical explanation
| Type | Stores | Notes |
|---|---|---|
| `INET` | A single host IP address, optionally with a netmask (`192.168.1.5/24`) | Host bits may be non-zero — it represents "an address," not necessarily a whole network |
| `CIDR` | A network address strictly (`192.168.1.0/24`) | PostgreSQL **rejects** input where host bits are set (e.g., `192.168.1.5/24` is invalid as `CIDR` — it must be `192.168.1.0/24`) |
| `MACADDR` / `MACADDR8` | A 6-byte (or 8-byte, EUI-64) hardware MAC address | Validates the standard hex-colon format on input |

### 3. Why dedicated network types beat plain text
- **Built-in validation** — `INET`/`CIDR` reject malformed addresses at write time; a `VARCHAR` column storing IPs as text accepts `'not.an.ip'` just as happily as a real address.
- **Correct sorting** — as text, `'10.0.0.1' < '2.0.0.1'` (lexicographic string comparison), which is numerically backwards. As `INET`, addresses sort in true numeric address order.
- **Subnet-containment operators**, not available on text at all:

| Operator | Meaning |
|---|---|
| `<<` | Is strictly contained within (subnet of) |
| `<<=` | Is contained within or equal to |
| `>>` | Strictly contains |
| `>>=` | Contains or equal to |
| `&&` | Subnets overlap |

### 4. Worked example (illustrative table, real customer FK)
```sql
CREATE TABLE banking_db.login_attempts (
    attempt_id   BIGSERIAL PRIMARY KEY,
    customer_id  INT REFERENCES banking_db.customers(customer_id),
    ip_address   INET NOT NULL,
    attempted_at TIMESTAMP NOT NULL DEFAULT now(),
    success      BOOLEAN NOT NULL
);

INSERT INTO banking_db.login_attempts (customer_id, ip_address, success) VALUES
(1, '203.0.113.42',    TRUE),
(1, '198.51.100.7',    FALSE),
(3, '10.0.0.15',       TRUE),
(4, '10.0.0.201',      TRUE);

-- Find every login attempt originating from the internal 10.0.0.0/8 range:
SELECT attempt_id, customer_id, ip_address
FROM banking_db.login_attempts
WHERE ip_address <<= '10.0.0.0/8';
```
```
 attempt_id | customer_id | ip_address
------------+-------------+------------
          3 |           3 | 10.0.0.15
          4 |           4 | 10.0.0.201
```
`ip_address <<= '10.0.0.0/8'` is a single indexable comparison — the text equivalent would require fragile string-prefix matching (`ip_address LIKE '10.%'`, which also incorrectly matches `10.256.x.x`-style garbage that isn't even a valid address, and cannot express arbitrary subnet boundaries like a `/12`).

### 5. When to use / not use
Use `INET`/`CIDR`/`MACADDR` whenever you store IP addresses, network ranges, or hardware addresses at all — there is essentially no downside versus text, and you gain validation, correct sorting, and subnet operators for free. This is a genuine PostgreSQL-specific strength with no equivalent in MySQL/SQL Server/Oracle, which all fall back to plain `VARCHAR`.

### 6. Real-world use cases
Login/audit IP logging (as above), firewall/allow-list rule storage, network inventory/asset management, geo-IP and access-control systems that need "is this request from an allowed subnet" checks.

---

## 25.7 Full-Text Search **[PostgreSQL: `tsvector`/`tsquery`]**

### 1. Simple explanation
Full-text search lets you search for words inside a block of text the way a search engine does — matching different word forms (`"running"` matching a search for `"run"`), ranking better matches higher, and doing it fast even across millions of rows — instead of the blunt, slow substring matching of `LIKE '%word%'`.

### 2. Technical explanation
`to_tsvector(config, text)` converts a document into a `tsvector`: a sorted list of normalized **lexemes** (stemmed, lowercased word roots) with their word positions, stopwords removed. `to_tsquery(config, query)` parses a search query into a `tsquery` using the same normalization plus boolean operators (`&` AND, `|` OR, `!` NOT, `<->` "followed by," for phrase search). The `@@` operator matches a `tsvector` against a `tsquery`.

### 3. What full-text search adds over `LIKE '%word%'`
| | `LIKE '%word%'` | Full-text search |
|---|---|---|
| Matches word variants (run/running/ran)? | No — exact substring only | Yes — via stemming |
| Ignores common words (the, a, is)? | No | Yes — stopword removal |
| Relevance ranking (best match first)? | No | Yes — `ts_rank()` |
| Performance at scale | Full table scan, string-by-string, every query | Inverted index (GIN) lookup — logarithmic, not linear |
| Word-boundary aware? | No — `'%cat%'` also matches "categoric" | Yes — tokenized into whole words/lexemes |

### 4. Full syntax and worked example — `ecommerce_db.reviews.review_text`

```sql
SELECT review_id, review_text FROM ecommerce_db.reviews ORDER BY review_id;
```
```
 review_id |               review_text
-----------+-------------------------------------------
         1 | Excellent phone, great camera.
         2 | Good sound, battery could be better.
         3 | Nice fit and comfortable.
         4 | Blazing fast laptop.
         5 | Runs hot under load.
         6 | Received a defective unit.
```

**Turning text into a `tsvector`:**
```sql
SELECT to_tsvector('english', 'a fat cat sat on a mat - it ate a fat rats');
```
```
                to_tsvector
-------------------------------------------
 'ate':9 'cat':3 'fat':2,11 'mat':7 'rat':12 'sat':4
```
Notice: `a`, `on`, `it` (stopwords) are gone entirely; `rats` was stemmed to `rat`; `fat` appears at both positions `2` and `11` where it occurred in the original text.

**Matching with `@@`, against real seed data:**
```sql
SELECT review_id, review_text
FROM ecommerce_db.reviews
WHERE to_tsvector('english', review_text) @@ to_tsquery('english', 'camera');
```
```
 review_id |          review_text
-----------+---------------------------------
         1 | Excellent phone, great camera.
```

```sql
-- Stemming in action: searching "battery" also matches text containing "batteries",
-- because both reduce to the same lexeme ("batteri") — a LIKE query would miss this.
SELECT review_id, review_text
FROM ecommerce_db.reviews
WHERE to_tsvector('english', review_text) @@ to_tsquery('english', 'battery');
```
```
 review_id |               review_text
-----------+-------------------------------------------
         2 | Good sound, battery could be better.
```

**Indexing full-text search — with a generated `tsvector` column:**
```sql
ALTER TABLE ecommerce_db.reviews
    ADD COLUMN search_vector TSVECTOR
        GENERATED ALWAYS AS (to_tsvector('english', coalesce(review_text, ''))) STORED;

CREATE INDEX idx_reviews_search_vector ON ecommerce_db.reviews USING GIN (search_vector);

SELECT review_id, review_text
FROM ecommerce_db.reviews
WHERE search_vector @@ to_tsquery('english', 'defective | laptop');
```
```
 review_id |          review_text
-----------+---------------------------------
         4 | Blazing fast laptop.
         6 | Received a defective unit.
```
Storing the `tsvector` in a **generated, stored** column (rather than recomputing `to_tsvector()` inline in every query's `WHERE` clause) means the GIN index can index the physical column directly — this is the standard, recommended real-world pattern, and it ties directly into §25.8 below.

### 5. Dialect comparison
> **[MySQL]**: `FULLTEXT` indexes on `CHAR`/`VARCHAR`/`TEXT` columns, queried with `MATCH(column) AGAINST('search terms')` (natural language mode by default, boolean mode available with `IN BOOLEAN MODE` for explicit AND/OR/exclusion operators). Simpler to set up than PostgreSQL's two-step `tsvector`/`tsquery` model, but historically more limited in linguistic normalization (stemming support depends heavily on the configured parser/plugin).
> **[SQL Server]**: a `FULLTEXT INDEX` on a table, queried with `CONTAINS()` (precise boolean/proximity matching) or `FREETEXT()` (looser, meaning-based matching using its own linguistic thesaurus/stemming).
> **[Oracle]**: **Oracle Text**, a full-featured, separately-licensed-in-some-editions search engine integrated via `CONTAINS()` queries against a Oracle Text index — historically the most feature-rich of the four (linguistic stemming, fuzzy matching, thematic indexing), but also the most operationally heavyweight to administer.

### 6. Common mistakes
- Writing `WHERE to_tsvector('english', review_text) @@ to_tsquery('english', 'battery')` in production without a matching functional GIN index — this still works correctly, but re-runs `to_tsvector()` on every row on every query; without an index (or a generated+indexed column as shown above), it's a sequential scan, no faster than `LIKE` for large tables.
- Forgetting that the query side also needs `to_tsquery`/`plainto_tsquery`/`websearch_to_tsquery` — comparing a `tsvector` directly against a plain string will error, not silently do a substring match.
- Using `to_tsquery()` directly with raw, unsanitized user input — a literal search term containing `&`, `|`, or `!` will be interpreted as a boolean operator (and malformed syntax will raise an error). `plainto_tsquery()` (simple AND of all terms) or, in modern PostgreSQL, `websearch_to_tsquery()` (understands quoted phrases and `-exclude` syntax the way a web search box does) are the safer choices for direct user input.

### 7. When to use / not use
Use full-text search the moment you need to search free-text content by meaning/word-match rather than exact substring — product descriptions, review text, article bodies, support tickets. Don't reach for it for exact-match lookups (an email address, an order number, a SKU) — a plain indexed equality/`LIKE 'prefix%'` comparison is both simpler and faster for those.

### 8. Real-world use cases
Product/review search on an e-commerce site (directly modeled here on `ecommerce_db.reviews`), searching support ticket or log text, document/article search, "search as you type" combined with `websearch_to_tsquery()` for user-friendly query parsing.

---

## 25.8 Generated Columns, Revisited

Chapter 13 (§13.7) introduced `GENERATED ALWAYS AS (...) STORED` columns primarily in the context of a computed `line_total`. This chapter adds two more worked examples directly relevant to what you've just learned: a plain derived-value column, and the full-text-search generated column already shown in §25.7.4.

**Derived value — a `full_name` computed from `banking_db.customers`:**
```sql
ALTER TABLE banking_db.customers
    ADD COLUMN full_name TEXT GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED;

SELECT customer_id, full_name FROM banking_db.customers WHERE customer_id = 1;
```
```
 customer_id | full_name
-------------+--------------
           1 | Ravi Shankar
```
You can never `INSERT`/`UPDATE` `full_name` directly (attempting to will raise the exact "cannot insert a non-DEFAULT value into column" error shown in Chapter 13.7.5) — it is recomputed automatically the instant `first_name` or `last_name` changes on that row, so it can never silently drift out of sync.

**Search-vector generated column** — already shown in full in §25.7.4: `search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', coalesce(review_text,''))) STORED`. This combination — a generated `tsvector` column plus a GIN index on it — is the single most common real-world full-text search pattern in production PostgreSQL schemas, because it gives you an always-current, directly indexable search column without having to remember to recompute or re-index it in application code.

> **[PostgreSQL]**: only supports `STORED` generated columns (computed once and physically written to disk) — unlike SQL Server/MySQL/Oracle, which additionally support a "virtual"/computed-on-read variant. The trade-off is exactly what you'd expect: `STORED` costs disk space and a small write-time cost, but — critically for both examples above — only a physically stored column can be indexed. A virtual/computed-on-read column (available in the other three dialects) saves storage but cannot generally be indexed the same way, or requires the engine to maintain an entirely separate structure to do so.

---

## 25.9 Deep Dive: When Relational Columns Should Be Preferred Over JSON

This is the single most important judgment call this chapter asks you to make, and it comes up in real schema design constantly: **"should this be a column, or should it go in a JSONB blob?"**

### The framework

**Use proper relational columns/tables when:**
- The data has a **known, stable structure** — every row genuinely has the same fields (an order always has a `status`, an account always has a `balance`).
- You need to **filter, sort, join, or aggregate** on individual fields efficiently — `WHERE status = 'PAID'`, `JOIN ... ON account_id`, `GROUP BY category_id`, `SUM(amount)` are all fast and natural on real columns with real indexes; the same operations on a JSONB field require extracting the value on every row, every time, unless you build and maintain a separate expression/GIN index for that exact extraction.
- You need to **enforce constraints on individual fields** — `NOT NULL`, `CHECK (amount > 0)`, a foreign key to another table. JSONB has no equivalent of any of these for values *inside* the document; a JSONB "amount" field can silently be a string, a negative number, or simply absent, and the database will never notice.
- The data's shape is part of your **application's core domain model** — if your code has a hardcoded expectation that every row has a `status` and branches on its value, that expectation belongs in the schema as a real, typed, constrained column, not buried inside a document your code has to trust blindly.

**Use JSON/JSONB when:**
- The structure is **genuinely variable, sparse, or user-defined** — arbitrary event metadata that differs by event type (`analytics_db.events.payload`), a flexible "extra attributes" bag that varies per product category (§25.10's chapter challenge), per-tenant custom fields in a multi-tenant SaaS product.
- You will almost always **retrieve the value as a whole document**, rarely or never filtering into individual sub-fields — an audit snapshot (`banking_db.audit_log.old_data`/`new_data`) is read as "show me exactly what this row looked like," not queried field-by-field in `WHERE` clauses on a regular basis.
- Adding a new "field" happens so often, and so unpredictably, that a real schema migration for every new field would be a genuine operational bottleneck — a third-party webhook payload whose shape you don't control and which changes without notice.

### The anti-pattern to avoid

> **⚠️ Warning — the "just dump it all in a JSONB `data` column" anti-pattern**
> A common mistake, especially under time pressure, is designing an entire table as `id, created_at, data JSONB` and putting everything else — including perfectly well-structured, always-present, frequently-queried fields like `status`, `customer_id`, or `amount` — inside `data`, purely to avoid ever having to write another `ALTER TABLE`. This trades away, all at once:
> - **Type safety** — nothing stops `data->>'amount'` from silently containing `"one hundred"` instead of a number.
> - **Constraint enforcement** — no `NOT NULL`, `CHECK`, or foreign key can apply to a value buried inside a document.
> - **Query performance and indexability** — every filter on a JSONB field needs either a full scan or a bespoke expression/GIN index maintained by hand, versus a plain B-tree index that comes for free with a real column.
> - **Query readability** — compare `WHERE status = 'PAID' AND customer_id = 42` to `WHERE data->>'status' = 'PAID' AND (data->>'customer_id')::int = 42` — the second is slower to write, slower to read, and slower to run.
>
> Schema migrations (Chapter 26 onward touches on operating a live production database) are a normal, manageable part of running a real system — `ALTER TABLE ... ADD COLUMN` with a default is a fast, often metadata-only operation in modern PostgreSQL (Chapter 13.6.6). Avoiding migrations is not, on its own, a good enough reason to give up everything a relational column gives you. **The right question is never "JSON or columns, in general" — it's "for this specific field, is its structure stable and do I need to query into it efficiently?" Answer that per field, not per table.**

---

## 25.10 Practice Questions

1. Using literal example values, explain precisely why `'{"a": 1, "a": 2}'::json` and `'{"a": 1, "a": 2}'::jsonb` behave differently when displayed, and why that difference exists at the storage level.
2. Write a query against `banking_db.audit_log` that finds every audit row where `new_data` contains a `status` key with the value `'ACTIVE'`, using the containment operator. Then write an equivalent query using `->>` and `=` instead, and explain any difference in behavior between the two approaches when `new_data` is `NULL`.
3. Write a query against `analytics_db.events` that counts events per `source` value (web/ios/android) by extracting the field out of `payload`. Which SQL clause do you need in addition to the extraction expression, and why?
4. Given a hypothetical `products.tags TEXT[]` column, write a query using `unnest()` that returns one row per (product_id, tag) pair, then explain why this shape is necessary before you could `GROUP BY` tag to count how many products use each tag.
5. A colleague argues that adding a GIN index automatically makes `tags @> ARRAY['sale']` and `tags = ARRAY['sale']` equally fast. Explain why this is incorrect and what each operator actually checks.
6. You are designing a table that will receive rows from three independent regional services that occasionally need to be merged into one central database. Argue for or against using `UUID` primary keys for this table, addressing both the collision-avoidance benefit and the index-fragmentation cost.
7. Explain, step by step, why a random (version 4) UUID primary key causes more B-tree page splits on insert than a `BIGSERIAL` primary key does, and explain what property of UUIDv7 specifically addresses this.
8. A PostgreSQL `ENUM` type `shipping_carrier_enum` currently has three values. The business wants to remove one value that's no longer used and reorder the remaining two. Explain exactly why this cannot be done with a simple `ALTER TYPE` statement, and outline the migration steps required.
9. For a genuinely fixed, rarely-changing value set (e.g., ISO currency codes actively used by your system) versus a business-configurable value set (e.g., promotional campaign categories an admin can add through a UI), argue which one should use `ENUM`/`CHECK` and which should use a lookup table, and why.
10. Write a query against a hypothetical `login_attempts.ip_address INET` column that finds all attempts originating from the `172.16.0.0/12` private address range, and explain why this could not be correctly expressed with `LIKE` on a text column.
11. Explain, using a specific example, a search term for which `LIKE '%word%'` would fail to find a relevant matching row that `to_tsvector('english', ...) @@ to_tsquery('english', 'word')` would find — and a separate example where `LIKE` would incorrectly match a row that full-text search correctly excludes.
12. Why must a `tsvector` be stored in a **generated, stored** column (rather than computed inline in every query's `WHERE` clause) if you want to build a GIN index that actually gets used? What happens, performance-wise, if you index the raw text column instead?

---

## 25.11 Chapter Challenge — Design `product_variants`

**Task:** `ecommerce_db.products` currently models one row per distinct product, with no way to represent variants — a t-shirt that comes in multiple sizes, colors, and materials, each with its own SKU and stock level. Design a `product_variants` table that supports this, using a deliberate mix of proper relational columns and a JSONB column, and justify the split between the two.

**Requirements to satisfy:**
- Each variant belongs to exactly one parent product and has its own SKU and stock quantity.
- Common structured attributes — size, color, material — must be filterable, sortable, and validated (no free-text typos allowed for size).
- A variant may optionally override the parent product's price.
- Different product categories need genuinely different extra attributes (a t-shirt might need `sleeve_length`; a laptop variant might need `ram_gb` and `storage_gb`) that should not require a schema migration every time a new product category is introduced.

**Reference solution:**

```sql
CREATE TABLE ecommerce_db.product_variants (
    variant_id       SERIAL PRIMARY KEY,
    product_id       INT NOT NULL REFERENCES ecommerce_db.products(product_id) ON DELETE CASCADE,
    sku              VARCHAR(40) NOT NULL UNIQUE,
    size             VARCHAR(10) CHECK (size IN ('XS','S','M','L','XL','XXL')),
    color            VARCHAR(30),
    material         VARCHAR(30),
    price_override   NUMERIC(10,2) CHECK (price_override >= 0),
    stock_quantity   INT NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    extra_attributes JSONB NOT NULL DEFAULT '{}',
    created_at       TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (product_id, size, color, material)
);

CREATE INDEX idx_product_variants_extra_attrs ON ecommerce_db.product_variants USING GIN (extra_attributes);
CREATE INDEX idx_product_variants_product      ON ecommerce_db.product_variants (product_id);
```

**Justification, following the §25.9 framework exactly:**

- **`product_id`, `sku`, `stock_quantity`, `price_override` as real columns.** These fields exist, unambiguously and with the same meaning, on *every* variant of *every* product regardless of category — a stable, known structure. `stock_quantity` and `price_override` need real `CHECK` constraints (no negative stock, no negative price) and `stock_quantity` is exactly the kind of field you'll filter and aggregate on constantly ("show all variants below reorder level," "total stock across all variants of product X") — operations that need to be fast and indexable, not buried in JSON.
- **`size`, `color`, `material` as real columns, with `size` further constrained by `CHECK`.** These are the attributes a storefront's faceted search/filter UI needs to query and count by, directly and often ("show me all Medium, Blue variants across the whole catalog") — exactly the pattern §25.2.9 argues belongs in real, indexable columns rather than an array or a JSON field. `size` is additionally bounded to a genuinely fixed, small set of values, making it a legitimate `CHECK`/`ENUM` candidate per §25.4's framework; `color` and `material` are left as free `VARCHAR`, since the realistic set of colors/materials across an entire multi-category catalog is large and evolving enough that a rigid `CHECK`/`ENUM` would need constant maintenance (a lookup table would be a reasonable stronger alternative if strict validation of color/material spelling becomes a real business need).
- **`UNIQUE (product_id, size, color, material)`** prevents two identical variants of the same product from being created by accident — the same composite-uniqueness pattern already used by `ecommerce_db.inventory (product_id, warehouse_location)` in the real schema (Chapter 13.3.5).
- **`extra_attributes JSONB`** is exactly the §25.9 "genuinely variable, sparse, category-dependent" case: a t-shirt variant's document might be `{"sleeve_length": "long"}`, a laptop variant's might be `{"ram_gb": 16, "storage_gb": 512}`, and a book variant's might have no extra attributes at all (`{}`). Modeling this as real columns would force either dozens of nullable, mostly-empty columns (one per possible attribute across every product category the business will ever sell) or a full EAV redesign — both worse than a single flexible JSONB field for data that is inherently sparse and category-specific. The GIN index on `extra_attributes` still allows filtering into it when needed (`WHERE extra_attributes @> '{"ram_gb": 16}'`), just without the compile-time structural guarantees a real column would give — which is the correct trade-off, precisely because this data doesn't have a stable structure to enforce in the first place.

**A combined query showing the split at work:**
```sql
SELECT v.sku, v.size, v.color, v.stock_quantity, v.extra_attributes
FROM ecommerce_db.product_variants v
WHERE v.product_id = 5                      -- structured, indexed FK filter
  AND v.size = 'M'                          -- structured, constrained column filter
  AND v.extra_attributes @> '{"sleeve_length": "long"}';  -- flexible JSONB filter
```
This single query demonstrates the whole chapter's central lesson: the structured, always-present, frequently-filtered attributes (`product_id`, `size`) are real, constrained, indexed columns; the genuinely variable, category-specific attribute (`sleeve_length`) lives in JSONB — and both are queried together, each using the tool actually suited to its shape.

---

## Key Takeaways

- `JSON` preserves exact input text (order, whitespace, duplicate keys) and re-parses on every access; `JSONB` decomposes into an indexable binary format, reorders keys internally (by length, then byte order), and collapses duplicate keys to the last value — use `JSONB` unless you have a specific reason to need `JSON`'s exact-text preservation.
- JSONB's operators (`->`, `->>`, `#>`, `#>>`, `@>`, `?`, `?|`, `?&`) and GIN indexing make it genuinely queryable at scale — as demonstrated against `banking_db.audit_log` and `analytics_db.events.payload` — but none of it substitutes for real constraints on individual fields.
- PostgreSQL arrays are a real, powerful, indexable type unavailable natively in MySQL/SQL Server (and only awkwardly available in Oracle) — fine for small, display-only lists, but a proper many-to-many join table wins the moment you need to query, join, count, or validate individual elements.
- UUIDs solve distributed, coordination-free uniqueness and avoid leaking sequential volume information, but random (v4) UUIDs as a primary/clustered key cause real, measurable index fragmentation and worse insert locality than sequential integers — UUIDv7/time-ordered UUIDs are the modern fix.
- `ENUM` (PostgreSQL native type, MySQL inline column type) is compact and self-documenting but painful to shrink or reorder — PostgreSQL has no `DROP VALUE` at all, requiring a full type recreation. Prefer a lookup table for anything that might need runtime-configurable values.
- XML has been largely superseded by JSON for new development; it remains relevant mainly for legacy/industry-standard interchange formats.
- PostgreSQL's `INET`/`CIDR`/`MACADDR` types give real validation, correct numeric sorting, and subnet-containment operators (`<<`, `<<=`, `>>`, `>>=`) that plain text columns simply cannot express.
- Full-text search (`tsvector`/`tsquery`/`@@`, GIN-indexed) adds stemming, stopword removal, relevance ranking, and inverted-index performance that `LIKE '%word%'` cannot match at any scale — the standard production pattern is a `GENERATED ALWAYS AS (...) STORED` `tsvector` column with a GIN index on top of it.
- The central design question of this chapter is never "JSON or relational, as a whole-table decision" — it's "for this specific field, is its structure stable and do I need to query into it efficiently?" answered field by field, with a working framework and a named anti-pattern (the JSONB "dump everything" table) to avoid.

## What's Next

Every type in this chapter — JSONB documents, arrays, UUIDs — still lives inside ordinary tables that keep growing over time. [Chapter 26 — Partitioning](26-partitioning.md) covers what happens once a single table (like `analytics_db.sales_fact`, already partitioned by range in the canonical schema) grows too large for a single physical structure to manage efficiently, and how to split it into partitions while keeping every query you've learned so far working exactly as before.
