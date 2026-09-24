# Chapter 5 — Built-in Functions (String, Numeric, Date/Time & NULL-Handling)

> **Part II — SQL Fundamentals** · Previous: [Chapter 4 — Sorting, Pagination & Result Processing](04-sorting-pagination.md) · Next: [Chapter 6 — Aggregate Functions, GROUP BY, HAVING](06-aggregates.md)

All examples in this chapter run against `company_db` (see [`databases/company_db.sql`](../databases/company_db.sql)). Load it once per the [README](../README.md) setup instructions, then follow along in `psql`. The primary dialect is **PostgreSQL 15+**; every place another engine behaves differently is called out with **[MySQL]**, **[Oracle]**, or **[SQL Server]** tags.

A handful of examples in this chapter depend on `CURRENT_DATE` (tenure calculations). Those are explicitly marked with the date they were computed against — **2026-09-24** — so you can verify the arithmetic even though your own `CURRENT_DATE` will differ when you run them.

---

## 5.0 Why This Chapter Exists

Chapters 3 and 4 taught you how to retrieve and order rows. But raw column values are rarely what a report, an API response, or a business user actually needs. `first_name` and `last_name` need to become "Rao, Aditi". A `DATE` needs to become "3 years, 2 months on the job". A `NUMERIC(10,2)` needs to be rounded to 2 decimal places for a payslip. A `NULL` manager needs to render as "—" instead of breaking a report.

**Scalar functions** are the tools that transform one input value into one output value, row by row, without collapsing multiple rows into one (that's what aggregate functions in Chapter 6 do). This chapter covers the four families you will use in nearly every query you ever write: string functions, numeric functions, date/time functions, and NULL-handling functions — plus the conceptual foundation (three-valued logic) that makes NULL-handling necessary in the first place.

---

## 5.1 String Functions

### 5.1.1 Overview Table

| Function | Signature | Description | Dialect Notes |
|---|---|---|---|
| `CONCAT` | `CONCAT(str1, str2, ...)` | Joins strings; `NULL` arguments are treated as empty string | All 4 dialects support it; **[Oracle]** `CONCAT` only takes exactly 2 arguments |
| `\|\|` | `str1 \|\| str2` | ANSI concatenation operator; `NULL` in **any** operand makes the whole result `NULL` | **[PostgreSQL]** ✓, **[Oracle]** ✓; **[MySQL]** `\|\|` is logical OR by default (unless `PIPES_AS_CONCAT` SQL mode is set) — use `CONCAT()` instead; **[SQL Server]** uses `+` for string concatenation, not `\|\|` |
| `SUBSTRING` | `SUBSTRING(str FROM start FOR len)` or `SUBSTRING(str, start, len)` | Extracts a substring | **[Oracle]** uses `SUBSTR(str, start, len)`; **[SQL Server]** uses `SUBSTRING(str, start, len)` (positional only, no `FROM/FOR`) |
| `LENGTH` / `CHAR_LENGTH` | `LENGTH(str)`, `CHAR_LENGTH(str)` | Number of characters | **[MySQL]** `LENGTH()` returns **bytes**, `CHAR_LENGTH()` returns **characters** — they differ for multi-byte UTF-8 text; **[SQL Server]** function is `LEN()` (not `LENGTH`) and **strips trailing spaces** before counting; **[Oracle]** `LENGTH()` counts characters |
| `LOWER` / `UPPER` | `LOWER(str)`, `UPPER(str)` | Case folding | Identical across all 4 dialects |
| `TRIM` / `LTRIM` / `RTRIM` | `TRIM([LEADING\|TRAILING\|BOTH] [chars FROM] str)` | Removes leading/trailing characters (default: whitespace) | **[SQL Server]** pre-2022 `LTRIM`/`RTRIM` cannot take a custom character list (whitespace only); SQL Server 2022 added a `TRIM(chars FROM str)` form |
| `REPLACE` | `REPLACE(str, from_str, to_str)` | Replaces **all** occurrences of `from_str` | Identical across all 4 dialects |
| `POSITION` / `STRPOS` | `POSITION(substr IN str)`, `STRPOS(str, substr)` | 1-based index of first occurrence, `0` if not found | **[PostgreSQL]** has both; **[MySQL]** has `POSITION()` and `LOCATE(substr, str[, start])`; **[Oracle]** uses `INSTR(str, substr[, start[, occurrence]])`; **[SQL Server]** uses `CHARINDEX(substr, str[, start])` |

> **Important Note:** `POSITION`/`STRPOS` argument order is easy to get backwards. `POSITION(substring IN string)` — the needle comes first, the haystack second. `STRPOS(string, substring)` — reversed: haystack first, needle second.

### 5.1.2 CONCAT and `||`

**Simple explanation:** Both stick strings together. `CONCAT('A','B')` and `'A' || 'B'` both give `'AB'`.

**Technical explanation:** `||` is the SQL-standard concatenation operator. It is a strict (non-null-propagating-safe) operator: if *any* operand is `NULL`, the entire expression evaluates to `NULL`, following the general SQL rule that operators applied to `NULL` produce `NULL`. `CONCAT()` is a *function*, and PostgreSQL and MySQL both special-cased it to silently substitute an empty string for any `NULL` argument, specifically so report-building doesn't blow up on a single missing value.

**Why it exists:** Building display strings (full names, formatted addresses, log lines) from multiple columns is one of the most common query tasks. `||`/`CONCAT` cover it in one operator/function instead of nested string manipulation.

**Full syntax:**
```sql
str1 || str2 || str3 ...              -- operator form, chainable, any number of operands
CONCAT(str1, str2, str3, ...)         -- function form, variadic
```

**Examples**

```sql
-- Simple: full name for Engineering department employees
SELECT employee_id, first_name || ' ' || last_name AS full_name
FROM   employees
WHERE  department_id = 1
ORDER BY employee_id;
```

Expected output:

| employee_id | full_name |
|---|---|
| 1 | Aditi Rao |
| 2 | Rahul Mehta |
| 3 | Sneha Kulkarni |
| 4 | Vikram Joshi |
| 5 | Ananya Singh |
| 6 | Karan Verma |
| 16 | Aman Chawla |

Line-by-line: `first_name || ' ' || last_name` concatenates first name, a literal space, and last name into one string, aliased `full_name`. `WHERE department_id = 1` filters to Engineering. `ORDER BY employee_id` gives deterministic row order.

**The `NULL` divergence between `||` and `CONCAT` — demonstrated directly:**

```sql
-- Aditi (employee_id 1) has manager_id = NULL (she's the CTO, top of the hierarchy)
SELECT
    first_name,
    manager_id,
    first_name || ' reports to employee #' || manager_id  AS pipe_version,
    CONCAT(first_name, ' reports to employee #', manager_id) AS concat_version
FROM employees
WHERE employee_id = 1;
```

Expected output:

| first_name | manager_id | pipe_version | concat_version |
|---|---|---|---|
| Aditi | NULL | NULL | Aditi reports to employee #|

Line-by-line: `manager_id` is `NULL` for Aditi. The `||` chain has a `NULL` operand, so the **entire result is `NULL`** — even the parts that had real values are discarded. `CONCAT()` treats the `NULL` as an empty string, so it silently produces `'Aditi reports to employee #'` with nothing after the `#`. Neither is "correct" — this is exactly why `COALESCE` (§5.4.1) exists: to make the missing-value substitution *explicit* rather than relying on function-specific silent behavior.

> **⚠️ Warning:** Never assume `CONCAT` and `||` behave the same on `NULL`. A report that "loses" entire rows of text because one join column was `NULL` is a `||`-with-`NULL` bug. A report that silently prints incomplete text with no indication a value was missing is a `CONCAT`-with-`NULL` bug. Prefer explicit `COALESCE(col, 'fallback')` inside the concatenation when a column can be `NULL`.

**Common mistakes:** forgetting the literal space between concatenated columns (`'AditiRao'`); using `||` for numbers without casting (works via implicit cast in Postgres for `||` with non-text on one side is *not* actually allowed for all types — see below).

**Edge case:** In PostgreSQL, `||` requires the operands to be text or castable; `1 || 2` errors ("operator does not exist") unless at least one side is already text (`'x' || 2` works because Postgres has a `text || anyelement` overload that stringifies the non-text side). To be safe, explicitly cast: `salary_id::text || '-' || employee_id::text`.

**When to use:** `||` for standard-SQL portability and strict correctness signaling (you *want* `NULL` to propagate so bad data is visible); `CONCAT` for defensive report-building where a missing value shouldn't nuke the whole string but you still want to see it.

---

### 5.1.3 SUBSTRING

**Simple explanation:** Cuts out a piece of a string starting at some position, for some length.

**Technical explanation:** `SUBSTRING` takes a source string, a 1-based starting position, and an optional length. If the length is omitted, it returns everything to the end of the string. If `start` is beyond the string length, it returns an empty string. If `start + length` exceeds the string, it just returns what's available (no error, no padding).

**Why it exists:** Extracting structured sub-parts of a larger text field (a username from an email, an area code from a phone number, a year from a fixed-width code) without needing regular expressions for simple, fixed-pattern cases.

**Full syntax:**
```sql
SUBSTRING(string FROM start_position [FOR length])   -- SQL-standard form
SUBSTRING(string, start_position [, length])          -- positional form (also valid in PostgreSQL/MySQL/SQL Server)
```
**[Oracle]** `SUBSTR(string, start_position [, length])` — note negative `start_position` in Oracle counts from the end of the string.

**Examples**

```sql
-- Simple: first 4 characters of each department name
SELECT department_name, SUBSTRING(department_name FROM 1 FOR 4) AS short_code
FROM departments
ORDER BY department_id;
```

| department_name | short_code |
|---|---|
| Engineering | Engi |
| Sales | Sale |
| HR | HR |
| Finance | Fina |
| Marketing | Mark |

Line-by-line: `SUBSTRING(department_name FROM 1 FOR 4)` starts at character 1, takes up to 4 characters. `'HR'` has only 2 characters, so `FOR 4` simply returns what exists — no padding, no error.

**Combining SUBSTRING with POSITION — extracting an email username:**

```sql
SELECT
    employee_id,
    email,
    SUBSTRING(email FROM 1 FOR POSITION('@' IN email) - 1) AS username
FROM employees
WHERE employee_id IN (1, 3, 16)
ORDER BY employee_id;
```

| employee_id | email | username |
|---|---|---|
| 1 | aditi.rao@company.com | aditi.rao |
| 3 | sneha.kulkarni@company.com | sneha.kulkarni |
| 16 | aman.chawla@company.com | aman.chawla |

Line-by-line: `POSITION('@' IN email)` finds the 1-based index of `@` (e.g., 10 for `aditi.rao@company.com`, since `a-d-i-t-i-.-r-a-o` is 9 characters and `@` is the 10th). `SUBSTRING(email FROM 1 FOR 9)` then takes everything before it. Subtracting 1 from the position is the classic off-by-one you must remember: the `@` itself must be excluded.

**Common mistakes:** forgetting the `-1` and including the delimiter in the result; assuming `SUBSTRING` errors on out-of-range indices (it doesn't — it just clamps).

**Edge case:** `SUBSTRING('hello' FROM 0 FOR 3)` — a starting position of `0` or negative is legal in PostgreSQL; the function conceptually treats the string as starting at position 1 and a `FOR` length window that can extend before position 1 is simply truncated at the real start. `SUBSTRING('hello' FROM 0 FOR 3)` returns `'he'` (not an error), because the requested window is positions 0–2, and only positions 1–2 exist within that window inclusive of the 3-char span starting at 0.

**When to use:** fixed-pattern extraction (codes, prefixes, suffixes with known structure). **When not to use:** variable/complex patterns — use regular-expression functions (`REGEXP_SUBSTR`/`SUBSTRING(... FROM pattern)` with a POSIX regex, covered alongside pattern matching in later chapters) instead of chaining multiple `POSITION`/`SUBSTRING` calls.

---

### 5.1.4 LENGTH / CHAR_LENGTH

**Simple explanation:** Counts how many characters are in a string.

**Technical explanation:** PostgreSQL's `LENGTH(text)` counts characters (it is encoding-aware for `text`; there's a separate `LENGTH(bytea)` overload and `OCTET_LENGTH()` for raw byte counts). `CHAR_LENGTH()`/`CHARACTER_LENGTH()` are the SQL-standard spellings and behave identically to `LENGTH()` on text in Postgres.

**Why it exists:** Validating field lengths, truncating display text, computing padding — anywhere the character count of a value matters.

**Full syntax:** `LENGTH(string)`, `CHAR_LENGTH(string)`, `CHARACTER_LENGTH(string)`.

**Example**

```sql
SELECT first_name, LENGTH(first_name) AS name_length
FROM employees
WHERE employee_id IN (1, 11, 16)
ORDER BY employee_id;
```

| first_name | name_length |
|---|---|
| Aditi | 5 |
| Isha | 4 |
| Aman | 4 |

**Dialect divergence table (this is a genuine trap):**

| Dialect | Function | What it counts |
|---|---|---|
| PostgreSQL | `LENGTH(text)` | Characters |
| MySQL | `LENGTH(str)` | **Bytes** (differs from character count for multi-byte UTF-8) |
| MySQL | `CHAR_LENGTH(str)` | Characters |
| SQL Server | `LEN(str)` | Characters, **but strips trailing spaces first** |
| SQL Server | `DATALENGTH(str)` | Bytes |
| Oracle | `LENGTH(str)` | Characters |
| Oracle | `LENGTHB(str)` | Bytes |

> **⚠️ Warning:** On MySQL, `LENGTH('café')` (a 4-character string, but `é` is 2 bytes in UTF-8) returns `5`, not `4`. If you need character count on MySQL, you must use `CHAR_LENGTH()`, never `LENGTH()`.

**Edge case:** `LENGTH('')` returns `0`. `LENGTH(NULL)` returns `NULL` — not `0` — because any function applied to `NULL` propagates `NULL` (see §5.6). This distinction between "empty string" and "NULL" trips up a huge number of validation queries (`WHERE LENGTH(middle_name) = 0` will silently skip every row where `middle_name` is `NULL`, even though both "no middle name provided" cases probably should be treated the same by the business logic).

---

### 5.1.5 LOWER / UPPER

**Simple explanation:** Converts text to all-lowercase or all-uppercase.

**Technical explanation:** Case folding based on the database's collation/locale. For ASCII text this is unambiguous; for some locales, case folding of accented or multi-codepoint characters can behave differently, which is a genuinely deep Unicode topic outside this chapter's scope — for `company_db`'s ASCII data, this doesn't matter.

**Why it exists:** Case-insensitive comparison and consistent display formatting (headers in `UPPER`, normalized keys in `LOWER`).

**Syntax:** `LOWER(string)`, `UPPER(string)`. Identical everywhere.

**Example — report headers:**

```sql
SELECT UPPER(department_name) AS department, location
FROM departments
ORDER BY department_id;
```

| department | location |
|---|---|
| ENGINEERING | Pune |
| SALES | Mumbai |
| HR | Bengaluru |
| FINANCE | Mumbai |
| MARKETING | Delhi |

**Common mistake:** using `LOWER()`/`UPPER()` on both sides of a `WHERE` filter as a substitute for a proper case-insensitive collation or index — it works but defeats a plain B-tree index on the unmodified column (covered in Chapter 16). For one-off reports it's completely fine; for hot filter paths on large tables, prefer a functional index or a citext column type (Chapter 25).

---

### 5.1.6 TRIM / LTRIM / RTRIM

**Simple explanation:** Removes unwanted characters (usually spaces) from the start and/or end of a string. It never touches characters in the *middle*.

**Technical explanation:** `TRIM([LEADING | TRAILING | BOTH] [characters FROM] string)` is the SQL-standard form. `characters` defaults to a single space if omitted. `LTRIM`/`RTRIM` are shorthand for `TRIM(LEADING ...)`/`TRIM(TRAILING ...)`.

**Why it exists:** Data entered by humans or imported from files routinely carries stray leading/trailing whitespace. Trimming is the first step of almost every data-normalization pipeline.

**Full syntax:**
```sql
TRIM([LEADING | TRAILING | BOTH] [characters] FROM string)   -- SQL-standard
TRIM(string)                                                  -- shorthand: BOTH, whitespace
TRIM(characters FROM string)                                  -- shorthand: BOTH, custom chars
LTRIM(string [, characters])                                  -- [PostgreSQL]/[Oracle] allow custom chars
RTRIM(string [, characters])
```
**[SQL Server]** (pre-2022) `LTRIM`/`RTRIM` take **only** the string argument — whitespace only, no custom character list. SQL Server 2022+ added `TRIM([characters FROM] string)`.

**Examples — normalizing messy email input (constructed sample data, since the seed emails are already clean):**

```sql
WITH dirty_input (raw_email) AS (
    VALUES
        ('  Sneha.Kulkarni@Company.com  '),
        ('VIKRAM.JOSHI@COMPANY.COM'),
        ('ananya.singh@company.com')
)
SELECT
    raw_email,
    LOWER(TRIM(raw_email)) AS normalized_email
FROM dirty_input;
```

| raw_email | normalized_email |
|---|---|
| `  Sneha.Kulkarni@Company.com  ` | `sneha.kulkarni@company.com` |
| `VIKRAM.JOSHI@COMPANY.COM` | `vikram.joshi@company.com` |
| `ananya.singh@company.com` | `ananya.singh@company.com` |

Line-by-line: the `VALUES` clause builds a tiny throwaway table of dirty input. `TRIM(raw_email)` removes the leading/trailing spaces from row 1 (rows 2 and 3 have none, so `TRIM` is a no-op for them). `LOWER(...)` then folds case. The result matches the actual clean values already stored in `employees.email` for these three people — proving the normalization logic is correct.

**Custom-character trim:**
```sql
SELECT TRIM(BOTH '*' FROM '***Aditi Rao***') AS cleaned;   -- 'Aditi Rao'
SELECT TRIM(LEADING '0' FROM '00042') AS cleaned;          -- '42'
```

**Common mistakes:** assuming `TRIM` removes internal whitespace too (it does not — `'a  b'` stays `'a  b'`; use `REPLACE`/regex functions for that); assuming `TRIM(NULL)` returns `''` (it returns `NULL`).

**Edge cases:**
- `TRIM('')` → `''` (empty string is not `NULL`; trimming it still yields an empty string).
- `TRIM(NULL)` → `NULL` (propagation, not empty string).
- **[Oracle]-specific gotcha:** Oracle treats an empty string `''` as `NULL` at the storage level for `VARCHAR2`. So on Oracle, a column holding what looks like `''` is actually `NULL`, and `TRIM(that_column)` returns `NULL`, and `WHERE that_column = ''` never matches anything (must use `IS NULL`). This is a famous Oracle-only divergence from the SQL standard — Postgres/MySQL/SQL Server all distinguish `''` from `NULL` correctly.

**When to use:** always trim free-text user input before storing or comparing it. **When not to use:** don't trim inside a hot-path `WHERE` clause on an indexed column without a matching functional index — same caveat as `LOWER`/`UPPER`.

---

### 5.1.7 REPLACE

**Simple explanation:** Swaps every occurrence of one substring for another.

**Technical explanation:** `REPLACE(string, from_str, to_str)` performs a literal (non-regex) global substitution. If `from_str` is not found, the original string is returned unchanged. If `from_str` is an empty string, PostgreSQL returns the original string unchanged (it does not insert `to_str` between every character).

**Why it exists:** Simple find-and-replace cleanup — masking data, fixing known bad substrings, rewriting domains — without pulling in full regex machinery.

**Syntax:** `REPLACE(string, from_str, to_str)`. Identical across all four dialects.

**Example — simulating a company domain migration:**

```sql
SELECT
    employee_id,
    email,
    REPLACE(email, '@company.com', '@corp.io') AS new_email
FROM employees
WHERE employee_id IN (2, 7, 12);
```

| employee_id | email | new_email |
|---|---|---|
| 2 | rahul.mehta@company.com | rahul.mehta@corp.io |
| 7 | priya.nair@company.com | priya.nair@corp.io |
| 12 | nikhil.gupta@company.com | nikhil.gupta@corp.io |

**Common mistake:** using `REPLACE` for case-insensitive substitution — it's case-sensitive by default (`REPLACE('Company', 'company', 'X')` does **not** match), so you must `LOWER()` both sides first if the casing is unpredictable.

**Edge case:** nested/multi-pass replacement — `REPLACE(REPLACE(str, 'a', 'b'), 'c', 'd')` applies left-to-right; be careful that the first replacement doesn't create new matches for the second (`REPLACE(REPLACE('aab','a','ab'),'ab','c')` is a classic footgun — always trace through what the intermediate string looks like).

---

### 5.1.8 POSITION / STRPOS

Covered inline with `SUBSTRING` above (§5.1.3), but as a standalone reference:

```sql
SELECT POSITION('@' IN 'aditi.rao@company.com');   -- 10
SELECT STRPOS('aditi.rao@company.com', '@');       -- 10  (PostgreSQL-only convenience function)
SELECT POSITION('x' IN 'aditi.rao@company.com');   -- 0  (not found)
```

**Dialect equivalents:**

| Dialect | Function |
|---|---|
| PostgreSQL | `POSITION(substr IN str)`, `STRPOS(str, substr)` |
| MySQL | `POSITION(substr IN str)`, `LOCATE(substr, str[, start])` |
| SQL Server | `CHARINDEX(substr, str[, start])` |
| Oracle | `INSTR(str, substr[, start[, occurrence]])` |

**Edge case:** all of these return `0` when not found — **not** `NULL` and **not** `-1`. Only `NULL` input propagates `NULL`.

---

### 5.1.9 Splitting Strings (dialect-divergent)

**Simple explanation:** Breaking one string into pieces on a delimiter — e.g., turning `'aditi.rao@company.com'` into `['aditi.rao', 'company.com']`.

**Technical explanation:** Unlike the functions above, string-splitting has **no ANSI standard** and every dialect solves it differently — some return an array, some return a table, some return one piece at a time.

| Dialect | Function | Returns |
|---|---|---|
| **[PostgreSQL]** | `STRING_TO_ARRAY(str, delimiter)` | An array (`text[]`) of all pieces |
| **[PostgreSQL]** | `SPLIT_PART(str, delimiter, n)` | The n-th piece as a scalar string |
| **[MySQL]** | `SUBSTRING_INDEX(str, delimiter, count)` | Everything before the `count`-th delimiter (or after, if `count` negative) |
| **[SQL Server]** (2016+) | `STRING_SPLIT(str, delimiter)` | A **table** (one row per piece), used with `SELECT value FROM STRING_SPLIT(...)` |
| **[Oracle]** | `REGEXP_SUBSTR(str, pattern, position, occurrence)` | One piece, selected by occurrence, via regex |

**Examples — splitting an email at `@`:**

```sql
-- PostgreSQL: array
SELECT STRING_TO_ARRAY(email, '@') AS parts
FROM employees WHERE employee_id = 1;
-- {aditi.rao,company.com}

-- PostgreSQL: scalar piece
SELECT SPLIT_PART(email, '@', 1) AS username,
       SPLIT_PART(email, '@', 2) AS domain
FROM employees WHERE employee_id = 1;
-- username: aditi.rao   domain: company.com
```

```sql
-- [MySQL]
SELECT SUBSTRING_INDEX(email, '@', 1)  AS username,   -- 'aditi.rao'
       SUBSTRING_INDEX(email, '@', -1) AS domain       -- 'company.com'
FROM employees WHERE employee_id = 1;
```

```sql
-- [SQL Server]
SELECT value
FROM STRING_SPLIT('aditi.rao@company.com', '@');
-- two rows: 'aditi.rao', 'company.com' (order not guaranteed pre-2022 without enable_ordinal)
```

```sql
-- [Oracle]
SELECT REGEXP_SUBSTR('aditi.rao@company.com', '[^@]+', 1, 1) AS username,  -- 'aditi.rao'
       REGEXP_SUBSTR('aditi.rao@company.com', '[^@]+', 1, 2) AS domain     -- 'company.com'
FROM dual;
```

> **Important Note:** `STRING_SPLIT` in SQL Server is a **table-valued function** — it cannot be used as a scalar expression inside a `SELECT` list directly; it must appear in the `FROM` clause (optionally with `CROSS APPLY` against another table). This is fundamentally different from the other three, which are scalar/array functions usable anywhere an expression is allowed.

**When to use:** `SPLIT_PART`/`SUBSTRING_INDEX` for a single known piece (e.g., always want the domain); `STRING_TO_ARRAY`/`STRING_SPLIT` when you need *all* pieces, especially an unknown number of them.

---

## 5.2 Numeric Functions

### 5.2.1 Overview Table

| Function | Signature | Description | Dialect Notes |
|---|---|---|---|
| `ROUND` | `ROUND(n [, precision])` | Rounds to `precision` decimal places (default 0); negative precision rounds left of the decimal point | Behavior consistent across all 4 for `NUMERIC`/`DECIMAL` types |
| `CEIL`/`CEILING` | `CEIL(n)` | Smallest integer ≥ n | **[SQL Server]** only has `CEILING` (no `CEIL`); **[Oracle]** only has `CEIL` (no `CEILING`); PostgreSQL/MySQL have both |
| `FLOOR` | `FLOOR(n)` | Largest integer ≤ n | Identical everywhere |
| `ABS` | `ABS(n)` | Absolute value | Identical everywhere |
| `MOD` / `%` | `MOD(a,b)`, `a % b` | Remainder of a/b, sign follows dividend `a` | **[SQL Server]** `%` operator only, no `MOD()` function; **[Oracle]** `MOD()` function only, no `%` operator; PostgreSQL/MySQL support both |
| `POWER` | `POWER(base, exponent)` | Exponentiation | All 4 support `POWER()`; PostgreSQL also has `^` operator |
| `SQRT` | `SQRT(n)` | Square root | Identical everywhere; errors/`NaN` on negative input depending on dialect |
| `CAST` | `CAST(expr AS type)` | Explicit type conversion | PostgreSQL adds `expr::type` shorthand; **[SQL Server]** also has `CONVERT(type, expr, style)` |

### 5.2.2 ROUND

**Simple explanation:** Rounds a number to a given number of decimal places.

**Technical explanation:** `ROUND(numeric_expr, precision)` rounds `numeric_expr` to `precision` digits after the decimal point. For PostgreSQL's `NUMERIC` type, `ROUND` uses **round-half-away-from-zero** (arithmetic rounding: `2.5 → 3`, `-2.5 → -3`). A negative `precision` rounds to the left of the decimal point (`ROUND(1234, -2) = 1200`).

**Why it exists:** Currency and measurement values must be presented (and sometimes stored) at a fixed number of decimal places; raw division routinely produces long repeating decimals that need controlled rounding, not truncation.

**Full syntax:** `ROUND(numeric_expression [, precision_integer])`. Omitting `precision` rounds to the nearest whole number.

**Examples — simple to complex:**

```sql
-- Simple
SELECT ROUND(9166.666, 2) AS rounded;   -- 9166.67

-- Applied: monthly pay for Arjun Das (employee 8), whose base_salary is 110000
SELECT employee_id, base_salary, ROUND(base_salary / 12.0, 2) AS monthly_pay
FROM salaries
WHERE employee_id = 8;
```

| employee_id | base_salary | monthly_pay |
|---|---|---|
| 8 | 110000.00 | 9166.67 |

Line-by-line: `base_salary / 12.0` divides the annual figure by 12; the `.0` on `12` forces the divisor to be treated as a decimal so the division isn't accidentally performed as integer division (see the integer-division edge case below). `ROUND(..., 2)` then rounds `9166.6666...` to 2 decimal places using round-half-away-from-zero, giving `9166.67`.

**Rounding to a negative precision (bucketing budgets to the nearest lakh-adjacent thousand):**

```sql
SELECT project_name, budget, ROUND(budget, -5) AS rounded_to_lakh
FROM projects
ORDER BY project_id;
```

| project_name | budget | rounded_to_lakh |
|---|---|---|
| Platform Migration | 5000000.00 | 5000000 |
| Mobile App Revamp | 3000000.00 | 3000000 |
| Q1 Sales Expansion | 1200000.00 | 1200000 |
| Employee Wellness | 250000.00 | 300000 |
| Brand Relaunch | 800000.00 | 800000 |

Line-by-line: `ROUND(250000, -5)` rounds to the nearest 100,000. `250000` sits exactly halfway between `200000` and `300000`; round-half-away-from-zero rounds it up to `300000`.

**Common mistakes:** rounding intermediate results in a multi-step calculation and then rounding again at the end, compounding rounding error (round once, at the final output step); assuming `ROUND` on a `FLOAT`/`DOUBLE PRECISION` value behaves identically to `NUMERIC` — floating-point binary representation can make some "exact" decimal values (like `2.675`) actually stored as slightly less than the value, causing `ROUND(2.675, 2)` to yield `2.67` instead of the "expected" `2.68`. **This is why `salaries.base_salary` in `company_db` is declared `NUMERIC(10,2)` and not `FLOAT`** — exact decimal arithmetic matters for money.

**Edge case — negative numbers:** `ROUND(-2.5, 0)` → `-3` in PostgreSQL (away from zero, not toward positive infinity and not banker's rounding). Some other languages/tools round `-2.5` to `-2` (round-half-to-even) — always verify in your specific engine and never assume rounding conventions transfer between SQL and application code.

**When to use:** final display/output formatting, financial calculations. **When not to use:** as a replacement for proper `NUMERIC(p,s)` column typing — rounding at query time doesn't fix imprecise storage.

---

### 5.2.3 CEIL / CEILING and FLOOR

**Simple explanation:** `CEIL` always rounds up to the next whole number; `FLOOR` always rounds down.

**Technical explanation:** Unlike `ROUND`, these are direction-based, not nearest-based. `CEIL(4.01) = 5`; `FLOOR(4.99) = 4`. For negative numbers, "up" and "down" mean toward positive/negative infinity respectively, not toward/away from zero: `CEIL(-4.5) = -4`, `FLOOR(-4.5) = -5`.

**Why they exist:** Any scenario needing whole-unit counts from a fractional quantity — "how many trucks do I need," "how many full days did this take," "how many pages of 20 results each" — where you cannot have a fractional unit and must commit to either the ceiling or floor, not the nearest value.

**Syntax:** `CEIL(n)` / `CEILING(n)`, `FLOOR(n)`.

**Example — how many 8-hour working days does a project allocation need?**

```sql
SELECT
    employee_id, project_id, hours_allocated,
    hours_allocated / 8.0            AS exact_days,
    CEIL(hours_allocated / 8.0)      AS days_needed_if_committing_full_days,
    FLOOR(hours_allocated / 8.0)     AS full_days_completed
FROM employee_projects
WHERE employee_id = 4 AND project_id = 1;
```

| employee_id | project_id | hours_allocated | exact_days | days_needed_if_committing_full_days | full_days_completed |
|---|---|---|---|---|---|
| 4 | 1 | 500 | 62.5 | 63 | 62 |

Line-by-line: 500 hours ÷ 8 = 62.5 days exactly. `CEIL(62.5) = 63` — you cannot schedule half a day if you must round up to guarantee capacity. `FLOOR(62.5) = 62` — the number of *whole* days fully covered.

**Dialect table:**

| Dialect | Available names |
|---|---|
| PostgreSQL | `CEIL`, `CEILING` (aliases) |
| MySQL | `CEIL`, `CEILING` (aliases) |
| SQL Server | `CEILING` only |
| Oracle | `CEIL` only |

**Common mistake:** using `ROUND` when you actually need `CEIL` (e.g., computing "number of pages needed" as `ROUND(total_rows / page_size)` under-allocates whenever the remainder is less than half a page).

**Edge case:** `CEIL`/`FLOOR` applied to an already-whole number return that number unchanged (`CEIL(5) = 5`), and applied to negative fractions round *toward* the respective infinity, not toward zero — this trips people up (`FLOOR(-2.1)` is `-3`, not `-2`).

---

### 5.2.4 ABS

**Simple explanation:** Strips the sign, returning the positive magnitude of a number.

**Technical explanation:** `ABS(n)` returns `n` if `n ≥ 0`, and `-n` if `n < 0`.

**Why it exists:** Measuring the *size* of a difference or deviation when direction doesn't matter — variance from a target, magnitude of a change, distance calculations.

**Example — magnitude of salary change for Aditi Rao (employee 1) between her two salary records:**

```sql
SELECT
    s1.base_salary AS earlier_salary,
    s2.base_salary AS later_salary,
    s1.base_salary - s2.base_salary AS raw_difference,
    ABS(s1.base_salary - s2.base_salary) AS change_magnitude
FROM salaries s1, salaries s2
WHERE s1.employee_id = 1 AND s1.effective_date = '2015-03-01'
  AND s2.employee_id = 1 AND s2.effective_date = '2020-01-01';
```

| earlier_salary | later_salary | raw_difference | change_magnitude |
|---|---|---|---|
| 450000.00 | 520000.00 | -70000.00 | 70000.00 |

Line-by-line: `raw_difference` (earlier minus later) is negative because pay increased over time. `ABS()` converts it to a plain magnitude of `70000.00`, useful when a report only cares "how much did it change" rather than the direction.

**When to use:** deviation/variance reporting. **When not to use:** don't use `ABS` to paper over a sign error in your query logic — if the sign matters (increase vs. decrease), keep it and label it, don't discard it with `ABS`.

---

### 5.2.5 MOD and the `%` Operator

**Simple explanation:** Gives the remainder left over after integer division.

**Technical explanation:** `MOD(a, b)` (equivalently `a % b` where supported) computes `a - (b * FLOOR(a/b))`... except PostgreSQL/most SQL engines actually define it as `a - (b * TRUNC(a/b))`, meaning **the result's sign follows the sign of the dividend `a`**, not the divisor. This differs from Python's `%` (which follows the divisor's sign).

**Why it exists:** Cyclic bucketing — assigning rows to N groups round-robin, detecting even/odd, checking divisibility, wrapping values within a fixed range (e.g., day-of-week arithmetic).

**Full syntax:** `MOD(dividend, divisor)`, `dividend % divisor`.

**Examples:**

```sql
-- Sign follows the dividend, not the divisor
SELECT MOD(-7, 3) AS a,   -- -1
       MOD(7, -3) AS b,   --  1
       MOD(7, 3)  AS c,   --  1
       MOD(-7,-3) AS d;   -- -1
```

**Applied — splitting all active employees into 2 round-robin on-call rotations:**

```sql
SELECT
    employee_id, first_name,
    CASE WHEN MOD(employee_id, 2) = 0 THEN 'Rotation B' ELSE 'Rotation A' END AS on_call_group
FROM employees
WHERE status = 'ACTIVE'
ORDER BY employee_id
LIMIT 6;
```

| employee_id | first_name | on_call_group |
|---|---|---|
| 1 | Aditi | Rotation A |
| 2 | Rahul | Rotation B |
| 3 | Sneha | Rotation A |
| 4 | Vikram | Rotation B |
| 6 | Karan | Rotation B |
| 7 | Priya | Rotation A |

(Note employee 5, Ananya, is skipped — she's `ON_LEAVE`, filtered out by `status = 'ACTIVE'`.)

**Dialect table:**

| Dialect | `MOD()` function | `%` operator |
|---|---|---|
| PostgreSQL | ✓ | ✓ |
| MySQL | ✓ | ✓ |
| SQL Server | ✗ | ✓ (only option) |
| Oracle | ✓ (only option) | ✗ |

**Common mistake:** assuming `MOD(-7, 3)` is `2` (the mathematically "clean" positive-remainder convention used in some other languages/contexts) — in SQL it is `-1`. If you need a strictly non-negative bucket index regardless of sign, wrap it: `MOD(MOD(a, b) + b, b)`.

**Edge case:** `MOD(a, 0)` / `a % 0` raises a division-by-zero error in every dialect — always guard with `NULLIF(divisor, 0)` if the divisor could be zero (ties directly into §5.4.2).

---

### 5.2.6 POWER (and a note on SQRT)

**Simple explanation:** Raises a number to an exponent. `SQRT` is the special case of raising to the power ½.

**Technical explanation:** `POWER(base, exponent)` returns `base^exponent`, computed in floating point (or numeric, depending on input types and dialect). `SQRT(n)` returns the non-negative square root; passing a negative number raises an error in most dialects (SQL has no native complex-number type).

**Why they exist:** Compound growth/decay modeling, geometric calculations, and (as a preview of Chapter 6) the mathematical basis of standard deviation (`SQRT` of variance).

**Syntax:** `POWER(base, exponent)`, `SQRT(n)`. PostgreSQL also supports the `^` operator for exponentiation and `|/ n` / `SQRT(n)` for roots.

**Example — hypothetical "what if" salary projection for Karan Verma (employee 6, current base salary 80000) at 8% annual compound growth over 3 years:**

```sql
SELECT
    80000::numeric                                AS current_salary,
    POWER(1.08, 3)                                 AS growth_factor,
    ROUND(80000 * POWER(1.08, 3), 2)               AS projected_salary_3yr
;
```

| current_salary | growth_factor | projected_salary_3yr |
|---|---|---|
| 80000 | 1.259712 | 100776.96 |

Line-by-line: `POWER(1.08, 3)` computes `1.08 × 1.08 × 1.08 = 1.259712` (an 8% raise compounded 3 times). Multiplying the current salary by that factor and rounding to 2 decimals gives the projected figure. This is illustrative — `company_db`'s actual raise history for employee 6 is a single flat salary row, not a compounding series; the example demonstrates the function, not a real projection from stored data.

**Common mistake:** using `POWER(x, 0.5)` instead of `SQRT(x)` — mathematically equivalent, but `SQRT` is clearer intent and can be cheaper to evaluate.

**A brief note on `CAST` and numeric precision:** integer arithmetic can silently truncate. `SELECT 7 / 2;` in PostgreSQL returns `3` (integer division — both operands are integers, so the result is floored to an integer), not `3.5`. To get a fractional result you must force at least one operand to a non-integer type: `SELECT 7::numeric / 2;` or `SELECT 7 / 2.0;` both return `3.5000...`. This single distinction — integer vs. numeric/float division — is one of the most common silent bugs in reporting queries (a division that "worked" in testing with round numbers, then produced truncated garbage once real fractional data arrived). `CAST(expr AS NUMERIC(p,s))` (or PostgreSQL's `expr::NUMERIC(p,s)` shorthand) is the explicit fix — always cast at least one operand before dividing if you expect a fractional result.

---

## 5.3 Date/Time Functions

### 5.3.1 CURRENT_DATE and CURRENT_TIMESTAMP/NOW()

**Simple explanation:** `CURRENT_DATE` gives today's date; `CURRENT_TIMESTAMP`/`NOW()` gives the current date **and** time.

**Technical explanation:** `CURRENT_DATE` and `CURRENT_TIMESTAMP` are SQL-standard keywords evaluated **once per statement** (not once per row) — every row in a single query sees the identical value, which matters for consistency in a query that both filters and computes on "now." `NOW()` is PostgreSQL's/MySQL's function-call spelling of the same thing as `CURRENT_TIMESTAMP` (with parentheses, since it's a function, not a keyword).

**Why they exist:** Any time-relative calculation — age, tenure, "is this record stale," "how many days until deadline" — needs a stable reference point for "now."

**Syntax:**
```sql
CURRENT_DATE                 -- no parentheses (it's a reserved keyword, not a function call)
CURRENT_TIMESTAMP[(precision)]
NOW()                        -- [PostgreSQL]/[MySQL] function-call equivalent of CURRENT_TIMESTAMP
```
**[SQL Server]** uses `GETDATE()` for current date+time and `CAST(GETDATE() AS DATE)` for date-only (no native `CURRENT_DATE` keyword until SQL Server offers `SYSDATETIME()`/newer aliases — `GETDATE()` remains the idiomatic choice). **[Oracle]** uses `SYSDATE` (date+time, no parentheses) and `CURRENT_DATE`/`CURRENT_TIMESTAMP` are also available and session-timezone-aware, unlike `SYSDATE` which uses the OS/database server timezone.

> **Important Note:** `CURRENT_DATE`/`NOW()` are evaluated once per statement execution, so their value is stable within a query — but different every time you *run* the query. Every example below that uses `CURRENT_DATE` is explicitly annotated with the date it was computed against so you can verify the arithmetic; your own results will differ by however many days have passed.

---

### 5.3.2 Date Arithmetic

**Simple explanation:** Adding or subtracting days/months/years from a date, or finding the number of days between two dates.

**Technical explanation:** In PostgreSQL, `DATE + integer` adds that many days and returns a `DATE`; `DATE - DATE` returns an `integer` (days); `DATE ± INTERVAL` returns a `TIMESTAMP`. This "dates are basically integers with calendar awareness" model is elegant but is **PostgreSQL/Oracle-specific** — MySQL and SQL Server require explicit functions.

**Full syntax and dialect comparison:**

| Operation | **[PostgreSQL]** | **[MySQL]** | **[SQL Server]** | **[Oracle]** |
|---|---|---|---|---|
| Add N days | `date + 90` or `date + INTERVAL '90 days'` | `DATE_ADD(date, INTERVAL 90 DAY)` | `DATEADD(day, 90, date)` | `date + 90` |
| Add N months | `date + INTERVAL '3 months'` | `DATE_ADD(date, INTERVAL 3 MONTH)` | `DATEADD(month, 3, date)` | `ADD_MONTHS(date, 3)` |
| Subtract dates (days) | `date2 - date1` (returns integer) | `DATEDIFF(date2, date1)` (returns days, always) | `DATEDIFF(day, date1, date2)` (unit is a required parameter) | `date2 - date1` (returns number) |
| Subtract N days | `date - 90` | `DATE_SUB(date, INTERVAL 90 DAY)` | `DATEADD(day, -90, date)` | `date - 90` |

**Example — probation end date (hire_date + 90 days) for Karan Verma (employee 6, hired 2020-02-10):**

```sql
SELECT
    employee_id, hire_date,
    hire_date + 90                  AS probation_end_integer_days,
    hire_date + INTERVAL '90 days'  AS probation_end_interval
FROM employees
WHERE employee_id = 6;
```

| employee_id | hire_date | probation_end_integer_days | probation_end_interval |
|---|---|---|---|
| 6 | 2020-02-10 | 2020-05-10 | 2020-05-10 00:00:00 |

Line-by-line: 2020 is a leap year. From Feb 10, 19 days remain in February (11th–29th), then 31 (March) + 30 (April) = 80 days, leaving 10 more days into May → May 10, 2020. `hire_date + 90` (plain integer) returns a `DATE`. `hire_date + INTERVAL '90 days'` returns a `TIMESTAMP` (midnight) because adding an `INTERVAL` to a `DATE` in PostgreSQL always promotes the result to `TIMESTAMP` — a subtle type-change worth knowing about if you chain further date-only operations afterward.

**Example — exact project duration using date subtraction (fully reproducible, no `CURRENT_DATE` involved):**

```sql
SELECT project_name, start_date, end_date,
       end_date - start_date AS duration_days
FROM projects
WHERE project_id = 1;
```

| project_name | start_date | end_date | duration_days |
|---|---|---|---|
| Platform Migration | 2023-01-01 | 2023-12-31 | 364 |

**Example — projects with no end date, using `COALESCE` to avoid a `NULL` duration:**

```sql
SELECT project_name, start_date, end_date,
       COALESCE(end_date, CURRENT_DATE) - start_date AS days_elapsed_or_total
FROM projects
ORDER BY project_id;
```

For `project_id = 2` ('Mobile App Revamp', `start_date = 2024-01-15`, `end_date IS NULL`), `end_date - start_date` alone would be `NULL` (NULL propagation). Wrapping in `COALESCE(end_date, CURRENT_DATE)` substitutes today's date for ongoing projects, so the subtraction always produces a number.

**Tenure using `AGE()` — [PostgreSQL]-specific, calendar-aware (computed as of 2026-09-24):**

```sql
SELECT employee_id, first_name, hire_date, AGE(CURRENT_DATE, hire_date) AS tenure
FROM employees
WHERE employee_id IN (1, 2, 3)
ORDER BY employee_id;
```

| employee_id | first_name | hire_date | tenure (as of 2026-09-24) |
|---|---|---|---|
| 1 | Aditi | 2015-03-01 | 11 years 6 mons 23 days |
| 2 | Rahul | 2016-05-12 | 10 years 4 mons 12 days |
| 3 | Sneha | 2017-01-20 | 9 years 8 mons 4 days |

Line-by-line: `AGE(CURRENT_DATE, hire_date)` computes a calendar-aware breakdown (years, months, days) rather than a raw day count, which is what makes "9 years, 8 months, 4 days" more readable than "3532 days." `AGE()` has no direct equivalent in MySQL/SQL Server/Oracle — those dialects require manual computation via `DATEDIFF`/`EXTRACT` combinations (typically `TIMESTAMPDIFF(YEAR, hire_date, CURRENT_DATE)` in MySQL, or subtracting and formatting an interval expression).

> **⚠️ Warning:** Because `CURRENT_DATE` changes daily, any query using it (directly or via `AGE()`) is **not reproducible** across days. If you need a stable "as of" snapshot for a report, parameterize the reference date explicitly (`AGE(:as_of_date, hire_date)`) rather than relying on `CURRENT_DATE`.

**Common mistakes:** mixing up `date2 - date1` vs `date1 - date2` and getting a negative duration; in MySQL, forgetting `DATEDIFF()` always returns **days** regardless of argument order convention elsewhere — `DATEDIFF(date2, date1)` in MySQL is `date2 - date1` in days, whereas in **[SQL Server]** `DATEDIFF(unit, startdate, enddate)` takes the unit *first* and computes `enddate - startdate` in that unit — the argument order and meaning are genuinely different between MySQL and SQL Server despite the identical function name.

**Edge case — DST (Daylight Saving Time):** date-only (`DATE`) arithmetic is unaffected by DST since there's no time-of-day component. But `TIMESTAMP`/`TIMESTAMPTZ` arithmetic across a DST boundary can produce surprising results: adding `INTERVAL '1 day'` to a `TIMESTAMPTZ` just before a "spring forward" transition advances the *calendar day* by one, which may actually be 23 (not 24) wall-clock hours later in that timezone. `INTERVAL` arithmetic on `TIMESTAMPTZ` in PostgreSQL is calendar-based (day/month/year components applied first, respecting DST), while adding a plain number of seconds (`+ 86400 * INTERVAL '1 second'`) is a fixed-duration addition that ignores DST and can land on a different wall-clock hour than expected. This distinction — **calendar-based interval addition vs. fixed-duration addition** — is a genuine, hard-to-debug production issue for scheduling systems.

---

### 5.3.3 DATE_TRUNC and Its Equivalents

**Simple explanation:** Rounds a date/timestamp *down* to the start of a given unit — the start of its week, month, year, hour, etc.

**Technical explanation:** `DATE_TRUNC(unit, value)` zeroes out every field smaller than the specified unit. Truncating to `'month'` sets the day to 1 and the time to midnight; truncating to `'week'` in PostgreSQL moves the date back to the **Monday** of that ISO-8601 week (PostgreSQL always uses Monday as the start of the week for `DATE_TRUNC`, regardless of `DateStyle` or locale — this is a fixed, non-configurable convention worth memorizing).

**Why it exists:** Time-bucketing for reporting ("attendance per week," "hires per year," "sales per month") is one of the most common analytical query patterns, and `DATE_TRUNC` does it in one function call instead of manual date-math.

**Full syntax:** `DATE_TRUNC(field, source)` where `field` is one of `'microseconds'`, `'milliseconds'`, `'second'`, `'minute'`, `'hour'`, `'day'`, `'week'`, `'month'`, `'quarter'`, `'year'`, `'decade'`, `'century'`, `'millennium'`.

**Example — bucketing hire dates by year (onboarding cohorts):**

```sql
SELECT employee_id, first_name, hire_date, DATE_TRUNC('year', hire_date) AS hire_cohort
FROM employees
ORDER BY hire_date
LIMIT 5;
```

| employee_id | first_name | hire_date | hire_cohort |
|---|---|---|---|
| 1 | Aditi | 2015-03-01 | 2015-01-01 00:00:00 |
| 7 | Priya | 2015-11-05 | 2015-01-01 00:00:00 |
| 2 | Rahul | 2016-05-12 | 2016-01-01 00:00:00 |
| 10 | Rohan | 2016-08-09 | 2016-01-01 00:00:00 |
| 12 | Nikhil | 2016-12-01 | 2016-01-01 00:00:00 |

Line-by-line: regardless of which month/day someone was hired within a year, `DATE_TRUNC('year', ...)` collapses it to `January 1` of that year, which is exactly the value you'd `GROUP BY` in Chapter 6 to count hires per cohort. Note the result type is `TIMESTAMP`, not `DATE` — `DATE_TRUNC` always returns a timestamp even when given a plain `DATE` input.

**Example — bucketing attendance by week:**

```sql
SELECT employee_id, work_date, DATE_TRUNC('week', work_date) AS week_start
FROM attendance
WHERE employee_id = 3
ORDER BY work_date;
```

| employee_id | work_date | week_start |
|---|---|---|
| 3 | 2024-01-01 | 2024-01-01 00:00:00 |
| 3 | 2024-01-02 | 2024-01-01 00:00:00 |
| 3 | 2024-01-03 | 2024-01-01 00:00:00 |

**Internal behavior — why this matters:** January 1, 2024 was itself a **Monday**, which is why all three attendance rows (Mon/Tue/Wed of that same ISO week) truncate to the identical `2024-01-01`. If the seed data's attendance rows had spanned into the following Monday (2024-01-08), that row would truncate to `2024-01-08`, giving you a second, distinct week bucket. Understanding this "always rounds back to a fixed calendar boundary, never a rolling N-day window" behavior is essential — `DATE_TRUNC('week', ...)` is **not** "the last 7 days," it's "the fixed calendar week this date falls in," and the boundary (Monday) is a hardcoded convention in PostgreSQL, not something you configure per-query.

**Dialect equivalents (no dialect besides PostgreSQL has a function literally named `DATE_TRUNC` prior to recent versions):**

| Dialect | Equivalent |
|---|---|
| **[PostgreSQL]** | `DATE_TRUNC('month', ts)` |
| **[MySQL]** | No native equivalent; emulate with `DATE_FORMAT(ts, '%Y-%m-01')` (month) or `DATE(ts)` (day); week-truncation typically via `DATE_SUB(ts, INTERVAL WEEKDAY(ts) DAY)` |
| **[SQL Server]** (2022+) | `DATE_TRUNC(datepart, date)` — same name, added natively in SQL Server 2022; pre-2022, emulate with `DATEADD(month, DATEDIFF(month, 0, date), 0)` style tricks |
| **[Oracle]** | `TRUNC(date, format_model)` — e.g., `TRUNC(date, 'MM')` for month, `TRUNC(date, 'YYYY')` for year, `TRUNC(date, 'IW')` for ISO week |

**Common mistakes:** assuming `DATE_TRUNC('week', ...)` starts on Sunday (it doesn't — it's always Monday, ISO convention, in PostgreSQL) — if your business reporting weeks start Sunday, you need a manual offset, not `DATE_TRUNC('week', ...)` directly. Also, comparing a `DATE_TRUNC` result (a `TIMESTAMP`) directly against a `DATE` literal without being aware of the type promotion can cause subtle off-by-one confusion in edge cases involving time components.

---

### 5.3.4 EXTRACT

**Simple explanation:** Pulls out one specific piece (year, month, hour, day-of-week, etc.) from a date/time value as a plain number.

**Technical explanation:** `EXTRACT(field FROM source)` returns a numeric value for a named field. Some fields are calendar-based (`YEAR`, `MONTH`, `DAY`), some are clock-based (`HOUR`, `MINUTE`, `SECOND`), and one (`EPOCH`) returns the total number of seconds since 1970-01-01 UTC — useful for computing raw durations from `INTERVAL` values.

**Full syntax:** `EXTRACT(field FROM source)` where `field` includes `CENTURY, DECADE, YEAR, QUARTER, MONTH, WEEK, DAY, HOUR, MINUTE, SECOND, DOW (day of week, Sun=0..Sat=6), ISODOW (Mon=1..Sun=7), DOY (day of year), EPOCH, TIMEZONE`.

**Example — day-of-week for attendance records:**

```sql
SELECT work_date,
       EXTRACT(DOW FROM work_date)  AS dow_sun0,
       EXTRACT(ISODOW FROM work_date) AS isodow_mon1
FROM attendance
WHERE employee_id = 3
ORDER BY work_date;
```

| work_date | dow_sun0 | isodow_mon1 |
|---|---|---|
| 2024-01-01 | 1 | 1 |
| 2024-01-02 | 2 | 2 |
| 2024-01-03 | 3 | 3 |

(Both columns agree here only because Jan 1–3, 2024 fall Monday–Wednesday, where the two numbering schemes happen to coincide; they would diverge for a Sunday, which is `0` under `DOW` but `7` under `ISODOW`.)

**Example — computing hours worked from `check_in`/`check_out` using `EXTRACT(EPOCH ...)`:**

```sql
SELECT
    employee_id, work_date, check_in, check_out,
    check_out - check_in                                    AS raw_interval,
    ROUND(EXTRACT(EPOCH FROM (check_out - check_in)) / 3600.0, 2) AS hours_worked
FROM attendance
WHERE employee_id = 3 AND work_date = '2024-01-01';
```

| employee_id | work_date | check_in | check_out | raw_interval | hours_worked |
|---|---|---|---|---|---|
| 3 | 2024-01-01 | 09:05:00 | 18:10:00 | 09:05:00 | 9.08 |

Line-by-line: `check_out - check_in` on two `TIME` values yields an `INTERVAL` of `9 hours 5 minutes`. `EXTRACT(EPOCH FROM ...)` converts that interval to its total number of **seconds** (32,700), because internally PostgreSQL represents an interval's sub-day component as a count of microseconds — `EPOCH` is the escape hatch for turning that internal representation into a single comparable number. Dividing by `3600.0` converts seconds to hours (the `.0` again forces non-integer division), and `ROUND(..., 2)` gives a clean `9.08`.

**Dialect equivalents:** MySQL has direct field-extraction functions (`YEAR(date)`, `MONTH(date)`, `DAYOFWEEK(date)`, `HOUR(time)`) instead of a generic `EXTRACT`, though MySQL *also* supports `EXTRACT(unit FROM date)` syntax. SQL Server uses `DATEPART(datepart, date)` (numeric) or `DATENAME(datepart, date)` (text). Oracle supports `EXTRACT(field FROM date)` natively, matching PostgreSQL closely.

**Common mistake:** confusing `DOW` and `ISODOW` (0-indexed-from-Sunday vs. 1-indexed-from-Monday) — a "is this a weekend" check written as `EXTRACT(DOW FROM d) IN (6,7)` is wrong (Sunday is `0` under `DOW`, not `7`); it should be `EXTRACT(DOW FROM d) IN (0,6)` or, more robustly, `EXTRACT(ISODOW FROM d) IN (6,7)`.

---

### 5.3.5 The INTERVAL Type

**Simple explanation:** An `INTERVAL` is a *duration* — "3 days," "2 hours 30 minutes," "1 month" — as opposed to a `DATE`/`TIMESTAMP`, which is a *point in time*.

**Technical explanation:** PostgreSQL's `INTERVAL` stores three independent components internally: months, days, and microseconds. They are kept separate (not all converted to a single unit) specifically because calendar durations are not fixed-length — "1 month" can mean 28, 29, 30, or 31 days depending on which month, so PostgreSQL defers that resolution until the interval is actually *applied* to a specific date.

**Why it exists:** Representing "3 months from now" unambiguously requires more than a fixed day-count, because the correct number of days depends on which months are being spanned.

**Syntax and literals:**
```sql
INTERVAL '3 days'
INTERVAL '2 hours 30 minutes'
INTERVAL '1 month'
INTERVAL '1 year 2 months 3 days'
```
**[Oracle]** interval literals: `INTERVAL '90' DAY`, `INTERVAL '3' MONTH` (note the unit is unquoted and follows the quoted number, a different syntax shape than PostgreSQL's single quoted phrase).

**Example — probation end using an explicit `INTERVAL`:**

```sql
SELECT hire_date, hire_date + INTERVAL '3 months' AS three_month_mark
FROM employees WHERE employee_id = 16;   -- Aman Chawla, hired 2022-01-10
```

| hire_date | three_month_mark |
|---|---|
| 2022-01-10 | 2022-04-10 00:00:00 |

**When to use `INTERVAL '1 month'` vs. a fixed `+30` days:** always prefer `INTERVAL '1 month'` for calendar-meaningful durations (probation periods, subscription renewals, "same day next month") — `+30` days silently drifts across months of different lengths. Use fixed-day arithmetic only when the business rule genuinely means "exactly N days," not "N calendar months/years."

---

### 5.3.6 Time Zones: Storage vs. Display

This is one of the most consequential — and most misunderstood — topics in practical SQL work, so it's worth slowing down for.

**Simple explanation:** A timestamp can either carry timezone information (it knows what instant in absolute time it refers to) or not (it's just a naive combination of a date and a clock reading, with no idea which timezone that clock was in).

**Technical explanation — PostgreSQL's two timestamp types:**

| Type | What is stored | What changes on display |
|---|---|---|
| `TIMESTAMP` (a.k.a. `TIMESTAMP WITHOUT TIME ZONE`) | The literal date/time exactly as written, with **no** timezone context at all | Nothing — it always displays exactly as stored |
| `TIMESTAMPTZ` (a.k.a. `TIMESTAMP WITH TIME ZONE`) | Internally normalized to and stored as **UTC** | The **session's `TimeZone` setting** is applied at read time to render it in local wall-clock terms |

**Why this exists:** A single instant in time (say, "the moment this order was placed") is an absolute, unambiguous fact — it happened once, everywhere, simultaneously. But *displaying* that instant meaningfully to a human requires knowing what timezone that human is in. PostgreSQL's `TIMESTAMPTZ` design cleanly separates these two concerns: **store the absolute instant once** (as UTC internally), and **apply the timezone conversion only at input-parsing time and output-rendering time**, never in between. This means the stored value never has to be "the right timezone" — there is no such thing as a "timezone" attached to the stored bytes at all; the conversion is purely a display-layer operation driven by whatever `TimeZone` the *current session* has set.

**Full syntax:**
```sql
SET TIME ZONE 'Asia/Kolkata';                 -- change the session's display timezone
SHOW TIME ZONE;                                -- see the current session's setting
SELECT NOW();                                  -- current instant, rendered in session TimeZone
SELECT ts_column AT TIME ZONE 'UTC';           -- convert/reinterpret across timestamp/timestamptz
```

**Walking through what actually happens, step by step:**

1. A client with session `TimeZone = 'Asia/Kolkata'` (UTC+5:30) runs `INSERT INTO some_table (event_at) VALUES (NOW())` into a `TIMESTAMPTZ` column.
2. `NOW()` produces the current absolute instant. Before storage, PostgreSQL converts that instant to UTC and stores *only* the UTC value (there is no "which timezone was this in" flag saved alongside it — UTC is the canonical, timezone-agnostic wire format).
3. Later, a **different** client connects with session `TimeZone = 'America/New_York'` (UTC-4 during EDT) and runs `SELECT event_at FROM some_table`.
4. PostgreSQL takes the stored UTC value and converts it *at that moment, for that display*, into New York local time before sending it back.
5. Both clients saw the *same absolute instant* — they just saw two different clock-face renderings of it, entirely correctly, because a `TIMESTAMPTZ` never "belongs" to a timezone; only its *display* does.

**Now contrast with `TIMESTAMP` (no time zone) — which is exactly the type `company_db` uses for `departments.created_at` and `employees.created_at`:**

```sql
-- from databases/company_db.sql
created_at TIMESTAMP NOT NULL DEFAULT now()
```

`now()` returns a `TIMESTAMPTZ` (an absolute instant), but assigning it into a `TIMESTAMP` (no-timezone) column **silently strips the timezone information**, keeping only whatever the wall-clock reading happened to be *in the inserting session's timezone at that moment*. If two different application servers with two different session timezones both insert rows into this table, their `created_at` values are **not comparable as absolute instants** — one might be "14:00 as observed in UTC+5:30" and the other "14:00 as observed in UTC-4," and the column has no way of telling them apart or converting between them, because the timezone context was thrown away at insert time.

> **⚠️ Warning:** This is a genuine, real-world design smell present in `company_db`'s schema, kept here deliberately as a teaching example. For any timestamp that represents "when did this absolute event occur" (audit timestamps, `created_at`/`updated_at` columns, event logs) in a system that might ever run across multiple timezones or servers, `TIMESTAMPTZ` is almost always the correct choice over plain `TIMESTAMP`. Plain `TIMESTAMP` is appropriate for values that are deliberately timezone-agnostic by business meaning — e.g., "this employee's `hire_date`" (a `DATE`, no time component at all, correctly modeled) or a recurring wall-clock schedule ("gym opens at 09:00 local, wherever local is").

**The `AT TIME ZONE` operator** is the tool for converting between the two worlds:
```sql
-- Reinterpret a naive TIMESTAMP as having been recorded in a specific zone, producing a TIMESTAMPTZ:
created_at AT TIME ZONE 'Asia/Kolkata'

-- Convert a TIMESTAMPTZ into a naive local wall-clock TIMESTAMP for a given zone:
event_at_tz AT TIME ZONE 'America/New_York'
```

**Dialect comparison:**

| Dialect | Timezone-aware type | Naive type | Notes |
|---|---|---|---|
| **[PostgreSQL]** | `TIMESTAMPTZ` (stores as UTC, converts on display per session `TimeZone`) | `TIMESTAMP` | As described above |
| **[MySQL]** | `TIMESTAMP` (confusingly, MySQL's `TIMESTAMP` type *does* store as UTC and converts per session `time_zone` — behaves like Postgres's `TIMESTAMPTZ`) | `DATETIME` (naive, no conversion) | MySQL's naming is the **opposite** of PostgreSQL's — don't assume `TIMESTAMP` means the same thing across the two engines |
| **[SQL Server]** | `DATETIMEOFFSET` (stores an explicit UTC offset alongside the value) | `DATETIME`, `DATETIME2` | SQL Server's offset-aware type stores the *offset*, not a resolved timezone name, so it doesn't automatically handle DST rule changes the way an IANA-zone-aware system does |
| **[Oracle]** | `TIMESTAMP WITH TIME ZONE`, `TIMESTAMP WITH LOCAL TIME ZONE` | `TIMESTAMP`, `DATE` | `WITH LOCAL TIME ZONE` normalizes to the database's zone on storage and converts to the session zone on retrieval, conceptually close to Postgres's `TIMESTAMPTZ` |

**Common mistakes:** assuming `TIMESTAMP` and `TIMESTAMPTZ` "look the same so they must behave the same" — they only *display* similarly when your session timezone happens to match the timezone the naive value was implicitly recorded in; comparing a `TIMESTAMP` column against a `TIMESTAMPTZ` literal and getting an implicit, easy-to-miss conversion using the *current* session timezone (which may not be the timezone the naive data was actually recorded in); assuming changing `SET TIME ZONE` changes the *stored* data — it never does, for `TIMESTAMPTZ`; it only changes how subsequent reads *render* the already-stored UTC value.

---

## 5.4 NULL-Handling Functions

### 5.4.1 COALESCE

**Simple explanation:** Returns the first value in a list that isn't `NULL`.

**Technical explanation:** `COALESCE(expr1, expr2, ..., exprN)` evaluates its arguments and returns the first one that is not `NULL`; if all are `NULL`, it returns `NULL`. It is defined by the SQL standard as syntactic sugar equivalent to a `CASE` expression:
```sql
CASE
  WHEN expr1 IS NOT NULL THEN expr1
  WHEN expr2 IS NOT NULL THEN expr2
  ...
  ELSE NULL
END
```

**Why it exists:** Substituting a default/fallback value for missing data is such a universal need that it earned its own dedicated, terse syntax instead of always requiring a full `CASE`.

**Full syntax:** `COALESCE(expr1, expr2, ..., exprN)` — accepts 2 or more arguments of compatible types.

**Example — displaying "Top of hierarchy" instead of a `NULL` manager reference:**

```sql
SELECT
    employee_id, first_name, manager_id,
    COALESCE(manager_id::text, 'Top of hierarchy') AS manager_display
FROM employees
WHERE employee_id IN (1, 2, 3)
ORDER BY employee_id;
```

| employee_id | first_name | manager_id | manager_display |
|---|---|---|---|
| 1 | Aditi | NULL | Top of hierarchy |
| 2 | Rahul | 1 | 1 |
| 3 | Sneha | 2 | 2 |

Line-by-line: `manager_id::text` casts the integer to text so it's type-compatible with the literal fallback string (`COALESCE` requires all arguments to share a common type). For Aditi, `manager_id` is `NULL`, so `COALESCE` skips it and returns the second argument, `'Top of hierarchy'`. For Rahul and Sneha, `manager_id` is not `NULL`, so it's returned as-is (cast to text).

**Multi-fallback chain example (projects without an `end_date`, falling back through several candidate sources):**

```sql
SELECT project_name, end_date,
       COALESCE(end_date, DATE '2099-12-31') AS effective_end
FROM projects
ORDER BY project_id;
```

**Common mistake:** assuming `COALESCE` short-circuits guaranteed evaluation order for *volatile* expressions with side effects — the SQL standard permits, but doesn't strictly mandate, left-to-right short-circuiting; in practice PostgreSQL does evaluate left-to-right and stops at the first non-null, but this is only guaranteed to matter for advanced cases (e.g., a subquery in a later argument that would error if evaluated) — don't rely on later arguments never being touched for correctness-critical logic.

**Dialect comparison — `COALESCE` vs. dialect-proprietary equivalents:**

| Function | Dialect | Behavior |
|---|---|---|
| `COALESCE(a, b, ...)` | All 4 (ANSI standard) | First non-null of N arguments |
| `ISNULL(a, b)` | **[SQL Server]** | Exactly 2 arguments only; also a different, unrelated `ISNULL()` in MySQL (see NULLIF-adjacent note below) |
| `IFNULL(a, b)` | **[MySQL]** | Exactly 2 arguments only |
| `NVL(a, b)` | **[Oracle]** | Exactly 2 arguments only |

> **Important Note:** `COALESCE` is the only one of these that is both ANSI-standard *and* variadic (accepts any number of arguments). Prefer it for portability; reach for `ISNULL`/`IFNULL`/`NVL` only when you have a specific dialect-native reason to (e.g., minor performance characteristics in a specific engine's older versions).

---

### 5.4.2 NULLIF

**Simple explanation:** Returns `NULL` if two values are equal; otherwise returns the first value unchanged.

**Technical explanation:** `NULLIF(a, b)` is defined as `CASE WHEN a = b THEN NULL ELSE a END`. Because `a = b` involving a `NULL` operand evaluates to `UNKNOWN` (not `TRUE`), `NULLIF(NULL, 5)` returns `NULL` (the `ELSE` branch fires, returning `a`, which is `NULL`), and `NULLIF(5, NULL)` returns `5` for the same reason.

**Why it exists:** The single most common use is guarding against division by zero: `x / NULLIF(y, 0)` converts a would-be divide-by-zero error into a clean `NULL` result instead. It's also useful for "blank out a known placeholder/sentinel value" logic.

**Full syntax:** `NULLIF(expr1, expr2)` — exactly 2 arguments.

**Example — using `NULLIF` to blank out the "boring" default status in a report so only exceptions stand out:**

```sql
SELECT employee_id, first_name, status, NULLIF(status, 'ACTIVE') AS flagged_status
FROM employees
WHERE employee_id IN (1, 5, 9)
ORDER BY employee_id;
```

| employee_id | first_name | status | flagged_status |
|---|---|---|---|
| 1 | Aditi | ACTIVE | NULL |
| 5 | Ananya | ON_LEAVE | ON_LEAVE |
| 9 | Meera | TERMINATED | TERMINATED |

Line-by-line: Aditi's `status` equals the comparison value `'ACTIVE'`, so `NULLIF` returns `NULL` — visually, a report ordered/filtered to show only non-`NULL` `flagged_status` values immediately surfaces just the exceptional cases. Ananya and Meera have statuses different from `'ACTIVE'`, so `NULLIF` returns them unchanged.

**Divide-by-zero guard (illustrative, since no zero-hour rows exist in the seed data):**
```sql
SELECT project_id, budget, hours_allocated,
       budget / NULLIF(hours_allocated, 0) AS budget_per_hour
FROM projects p JOIN employee_projects ep ON ...  -- (join mechanics: Chapter 7)
```
If `hours_allocated` were `0`, `NULLIF(hours_allocated, 0)` returns `NULL`, and `budget / NULL` returns `NULL` (a clean missing value) instead of PostgreSQL raising a hard `division_by_zero` error that would abort the whole query.

**Common mistake:** reversing the arguments — `NULLIF(0, hours_allocated)` does **not** do the same thing as `NULLIF(hours_allocated, 0)`; the first argument is always what gets returned (or nulled), so argument order matters.

---

### 5.4.3 CASE as a NULL-Handling Tool

**Simple explanation:** `COALESCE` and `NULLIF` are convenient shorthand for two very specific `CASE` patterns; when your NULL-handling logic is more elaborate than "first non-null" or "null out one specific match," reach directly for `CASE`.

**Example — combining multiple NULL-related conditions attendance can't express with `COALESCE`/`NULLIF` alone:**

```sql
SELECT
    employee_id, work_date, status, check_in,
    CASE
        WHEN status IN ('ABSENT', 'LEAVE') THEN 'No check-in expected'
        WHEN check_in IS NULL              THEN 'Check-in missing (data issue)'
        ELSE check_in::text
    END AS check_in_display
FROM attendance
WHERE employee_id IN (4, 5)
ORDER BY employee_id, work_date;
```

| employee_id | work_date | status | check_in | check_in_display |
|---|---|---|---|---|
| 4 | 2024-01-01 | PRESENT | 09:10:00 | 09:10:00 |
| 4 | 2024-01-02 | ABSENT | NULL | No check-in expected |
| 4 | 2024-01-03 | PRESENT | 09:00:00 | 09:00:00 |
| 5 | 2024-01-01 | LEAVE | NULL | No check-in expected |
| 5 | 2024-01-02 | LEAVE | NULL | No check-in expected |

Line-by-line: this logic distinguishes *why* `check_in` is `NULL` — a `NULL` accompanying `'ABSENT'`/`'LEAVE'` is expected and unremarkable, whereas a `NULL` accompanying `'PRESENT'` would indicate a genuine data-entry problem (not present in this particular result set, but the second `WHEN` branch exists to catch it if it occurred). Neither `COALESCE` nor `NULLIF` alone can express "the meaning of this NULL depends on another column" — that's squarely `CASE` territory.

**Comparison table — when to reach for which:**

| Tool | Best for | Cannot do |
|---|---|---|
| `COALESCE(a, b, c, ...)` | "Use the first available value" | Conditional logic based on *other* columns |
| `NULLIF(a, b)` | "Treat this one specific sentinel value as missing" | Multiple conditions, non-equality logic |
| `CASE WHEN ... THEN ... END` | Arbitrary conditional logic, including NULL-dependent branching on other columns | Nothing — it's the general-purpose tool; `COALESCE`/`NULLIF` are just its common shorthand forms |

---

## 5.5 Deep Dive: How SQL Handles NULL, and Why `NULL = NULL` Is Not `TRUE`

This section is conceptually the most important one in the chapter. Nearly every subtle SQL bug involving "missing rows in my results" or "my filter isn't working" traces back to a misunderstanding of what's explained here.

### 5.5.1 What NULL *Is*

`NULL` does not mean zero, does not mean an empty string, and is not a value at all in the conventional sense — it represents the **absence of a known value**. It could mean "not applicable" (Aditi has no manager because she's the CTO — there genuinely is no value), "not yet known" (a project's `end_date` before it finishes), or "not recorded" (an attendance system that failed to log a check-in). SQL deliberately does not distinguish *why* a value is missing — all three cases are represented identically as `NULL`.

### 5.5.2 Three-Valued Logic

Because `NULL` represents "unknown," any comparison involving it can't honestly be answered `TRUE` or `FALSE` — the honest answer is **`UNKNOWN`**. SQL's boolean logic therefore has **three** truth values, not two: `TRUE`, `FALSE`, and `UNKNOWN`.

`5 = 5` → `TRUE`. `5 = 6` → `FALSE`. `5 = NULL` → **`UNKNOWN`** — not `FALSE`. We genuinely don't know what the missing value equals, so SQL refuses to guess, and returns `UNKNOWN` instead of committing to either `TRUE` or `FALSE`.

This is why `NULL = NULL` is **also `UNKNOWN`, not `TRUE`** — comparing "an unknown quantity" to "another unknown quantity" cannot honestly be asserted equal, even though intuitively you might expect two `NULL`s to "match." SQL's equality operator is not in the business of guessing.

### 5.5.3 Truth Tables: AND, OR, NOT with UNKNOWN

| AND | TRUE | FALSE | UNKNOWN |
|---|---|---|---|
| **TRUE** | TRUE | FALSE | UNKNOWN |
| **FALSE** | FALSE | FALSE | FALSE |
| **UNKNOWN** | UNKNOWN | FALSE | UNKNOWN |

| OR | TRUE | FALSE | UNKNOWN |
|---|---|---|---|
| **TRUE** | TRUE | TRUE | TRUE |
| **FALSE** | TRUE | FALSE | UNKNOWN |
| **UNKNOWN** | TRUE | UNKNOWN | UNKNOWN |

| NOT | Result |
|---|---|
| **TRUE** | FALSE |
| **FALSE** | TRUE |
| **UNKNOWN** | UNKNOWN |

**Reading the tables:** `AND` is only `TRUE` if both sides are `TRUE`; it "short-circuits" to `FALSE` if *either* side is `FALSE`, regardless of the other side (even if the other side is `UNKNOWN`) — a single definite `FALSE` is enough to make the whole `AND` `FALSE`. Symmetrically, `OR` short-circuits to `TRUE` if *either* side is `TRUE`, regardless of `UNKNOWN` on the other side. `UNKNOWN` only "wins" (propagates as the final result) when it's mixed with something that isn't decisive enough to override it (`UNKNOWN AND TRUE = UNKNOWN`, `UNKNOWN OR FALSE = UNKNOWN`). `NOT UNKNOWN` stays `UNKNOWN` — negating "we don't know" is still "we don't know."

### 5.5.4 Why `WHERE` Filters Out `UNKNOWN`

A `WHERE` clause (and a `JOIN ... ON` clause, and a `HAVING` clause) keeps a row **only if its condition evaluates to exactly `TRUE`**. Rows where the condition evaluates to `FALSE` *or* `UNKNOWN` are both excluded — SQL treats "definitely not" and "can't tell" identically for filtering purposes.

**Live demonstration against `company_db`:**

```sql
-- Aditi (employee_id 1) genuinely has manager_id = NULL
SELECT employee_id, first_name, manager_id
FROM employees
WHERE manager_id = NULL;
```
Returns **0 rows** — even though Aditi's `manager_id` is, in fact, `NULL`. `manager_id = NULL` evaluates to `UNKNOWN` for every single row in the table (comparing anything to `NULL` is always `UNKNOWN`), and `WHERE` discards every `UNKNOWN` row, so the result set is empty regardless of what data exists.

```sql
-- The correct way to test for NULL:
SELECT employee_id, first_name, manager_id
FROM employees
WHERE manager_id IS NULL;
```
Returns exactly 1 row: `(1, 'Aditi', NULL)`. `IS NULL` is a special predicate — not an equality comparison — that directly tests the actual presence/absence of a value and always returns a definite `TRUE` or `FALSE`, never `UNKNOWN`.

> **⚠️ Warning:** `= NULL` and `<> NULL` are two of the most common beginner mistakes in all of SQL. Neither ever matches anything, ever, in any dialect, and — worse — neither one raises an error, so the mistake silently produces "no rows found" instead of an obvious failure. Always use `IS NULL` / `IS NOT NULL`.

### 5.5.5 NULL in DISTINCT, GROUP BY, and ORDER BY

This is the part that surprises people who've internalized "NULL never equals NULL": for the specific, narrow purposes of **grouping** and **de-duplication**, the SQL standard explicitly makes an exception and treats all `NULL`s as equal to each other.

**`DISTINCT` collapses multiple `NULL`s into one:**

```sql
-- Employee 5 (Ananya) was on LEAVE both days; check_in is NULL both times
SELECT DISTINCT check_in FROM attendance WHERE employee_id = 5;
```

| check_in |
|---|
| NULL |

Even though there are 2 underlying rows, both with `check_in = NULL`, `DISTINCT` returns a **single** `NULL` row — for de-duplication purposes only, `NULL` is treated as "equal to" another `NULL`, which directly contradicts the `NULL = NULL → UNKNOWN` rule from §5.5.2/5.5.4. This isn't a contradiction in the language so much as a deliberately different, narrower rule that applies specifically to grouping/set operations, not to boolean comparison.

**`GROUP BY` groups all `NULL`s into a single group**, for the identical reason — every row with `manager_id IS NULL` would land in one group together if you ran `GROUP BY manager_id` (previewed here; full mechanics in Chapter 6).

**`ORDER BY` — where `NULL`s sort is dialect-dependent** (this is a genuine, frequently-surprising divergence):

```sql
SELECT employee_id, work_date, check_in
FROM attendance
WHERE employee_id IN (4, 5)
ORDER BY check_in;          -- ascending, default NULLS position
```

| employee_id | work_date | check_in |
|---|---|---|
| 4 | 2024-01-03 | 09:00:00 |
| 4 | 2024-01-01 | 09:10:00 |
| 4 | 2024-01-02 | NULL |
| 5 | 2024-01-01 | NULL |
| 5 | 2024-01-02 | NULL |

In PostgreSQL, **ascending order defaults to `NULLS LAST`** — non-null values sort first in their natural order, and every `NULL` row is pushed to the end (the relative order *among* the `NULL` rows themselves is not guaranteed unless you add a secondary `ORDER BY` column). You can always override this explicitly:

```sql
ORDER BY check_in NULLS FIRST;
ORDER BY check_in DESC NULLS LAST;   -- override the descending default too
```

| Dialect | Default position of `NULL` in `ASC` order | Default position in `DESC` order |
|---|---|---|
| **[PostgreSQL]** | LAST | FIRST |
| **[Oracle]** | LAST | FIRST |
| **[MySQL]** | FIRST (NULLs are treated as the lowest possible value) | LAST |
| **[SQL Server]** | FIRST (same "lowest value" treatment) | LAST |

> **Important Note:** PostgreSQL and Oracle agree with each other; MySQL and SQL Server agree with each other; the two pairs disagree with each other. Never assume `ORDER BY` NULL placement is portable across engines — if it matters to your report, specify `NULLS FIRST`/`NULLS LAST` explicitly (supported directly in PostgreSQL/Oracle; MySQL/SQL Server require a `CASE WHEN col IS NULL THEN 1 ELSE 0 END` trick as an extra leading sort key to force a specific placement).

### 5.5.6 Tying It Back to COALESCE / NULLIF / CASE

Everything in §5.4 exists specifically to work around the consequences of §5.5.1–5.5.5:

- `COALESCE` exists because you frequently need a **definite value** in place of an "unknown" for display, sorting, or arithmetic — turning `UNKNOWN`'s downstream effects into something predictable.
- `NULLIF` exists because you sometimes need to deliberately **manufacture** an `UNKNOWN`/`NULL` from a known sentinel value, specifically to trigger `NULL`'s propagation behavior on purpose (e.g., so a division "fails softly" into `NULL` instead of erroring).
- `CASE ... IS NULL ...` exists because sometimes the fix isn't "substitute a default" or "manufacture a NULL" but "branch the query's logic explicitly around the three-valued outcome," which neither of the other two tools can express.
- `IS NULL`/`IS NOT NULL` are the *only* correct way to test for `NULL` in a `WHERE`/`ON`/`HAVING` clause, precisely because `=`/`<>` can never return `TRUE` against `NULL` by design.

---

## 5.6 Function Category Cheat Sheet

| Category | Function | One-line purpose |
|---|---|---|
| String | `CONCAT`, `\|\|` | Join strings |
| String | `SUBSTRING`/`SUBSTR` | Extract a piece |
| String | `LENGTH`/`CHAR_LENGTH` | Count characters |
| String | `LOWER`/`UPPER` | Case-fold |
| String | `TRIM`/`LTRIM`/`RTRIM` | Strip edge characters |
| String | `REPLACE` | Global find-and-replace |
| String | `POSITION`/`STRPOS` | Locate a substring |
| String | `STRING_TO_ARRAY`/`SPLIT_PART`/`SUBSTRING_INDEX`/`STRING_SPLIT`/`REGEXP_SUBSTR` | Split on a delimiter (dialect-specific) |
| Numeric | `ROUND` | Round to N decimal places |
| Numeric | `CEIL`/`FLOOR` | Round up/down to a whole unit |
| Numeric | `ABS` | Magnitude, sign discarded |
| Numeric | `MOD`/`%` | Remainder |
| Numeric | `POWER`/`SQRT` | Exponentiation / root |
| Numeric | `CAST`/`::` | Explicit type conversion |
| Date/Time | `CURRENT_DATE`/`NOW()` | Current moment |
| Date/Time | `+`/`-`/`INTERVAL` | Date arithmetic |
| Date/Time | `DATE_TRUNC` | Round down to a calendar boundary |
| Date/Time | `EXTRACT` | Pull out one field |
| Date/Time | `AT TIME ZONE` | Convert between naive and zone-aware |
| NULL | `COALESCE` | First non-null of N |
| NULL | `NULLIF` | Turn a specific value into NULL |
| NULL | `CASE` | General conditional/NULL logic |
| NULL | `IS NULL`/`IS NOT NULL` | The only correct way to test for NULL |

---

## 5.7 Real-World Use Cases

- **Payroll/finance reports**: `ROUND` for currency display, `TRIM`/`LOWER` for normalizing bank-provided reference codes, `COALESCE` for defaulting missing bonus fields to zero before totalling.
- **Customer-facing directories**: `CONCAT`/`||` for display names, `INITCAP`-style formatting (dialect-specific, not covered here), `SUBSTRING`/`POSITION` for deriving initials or usernames.
- **Data migration/ETL**: `TRIM`, `LOWER`, `REPLACE` as the first normalization pass on every incoming text field; `COALESCE` to fill required-but-sometimes-missing target columns with sane defaults.
- **Scheduling and SLAs**: `DATE_TRUNC` for weekly/monthly rollups, `INTERVAL` arithmetic for deadline calculation, careful `TIMESTAMPTZ` handling for any system with users or servers in more than one timezone.
- **Cohort/retention analysis**: `DATE_TRUNC('month', signup_date)` or `DATE_TRUNC('week', hire_date)` (as previewed in §5.3.3) is the standard first step before the `GROUP BY` work in Chapter 6.
- **Data-quality auditing**: `IS NULL`/`IS NOT NULL` checks, `LENGTH(TRIM(col)) = 0` checks (with the earlier caveat about `NULL` vs. `''`), `NULLIF` guards around any division in a computed metric.

---

## 5.8 Practice Questions

No answers are provided — work these out against `company_db` and verify the row counts/values yourself.

1. Write a query that formats every Sales-department (`department_id = 2`) employee's name as `"Last, First"` using string concatenation.
2. Using `SUBSTRING` and `POSITION`, extract the domain portion (everything after `@`) of every employee's email address, then use `DISTINCT` to list the unique domains that appear.
3. For every project in the `projects` table, compute its duration in days using date subtraction. For projects where `end_date IS NULL`, display the text `'Ongoing'` instead of a number (hint: this needs `CASE`, since `COALESCE` alone can't switch data types from number to text within one expression cleanly — think about why, and what type the whole column would need to be).
4. Using `ROUND`, round every `salaries.bonus` value to the nearest thousand (hint: think about what precision argument achieves "nearest 1,000" rather than "nearest 1").
5. Using `MOD`, divide all employees into 3 rotating groups (0, 1, 2) based on `employee_id`, and count (informally, by eye — `GROUP BY`/`COUNT` are next chapter) how many `ACTIVE` employees land in each group.
6. Using `EXTRACT`, write a query against `attendance` that returns the hour portion of every non-null `check_in` value.
7. Using `DATE_TRUNC`, bucket every row of `attendance` first by week, then separately by month, and describe in one sentence why the two groupings produce the same buckets or different buckets for this particular seed data.
8. Predict, without running it, what `SELECT * FROM attendance WHERE check_out = NULL;` returns. Then run it, confirm your prediction, and rewrite the query to return what was probably intended.
9. Using `COALESCE` and `NULLIF` together in a single expression, write a query against `projects` that would display `'N/A'` for any project whose `budget` is either `NULL` or exactly `0` (there are no zero-budget rows in the seed data — reason through the logic anyway).
10. Write a query that lists every employee's tenure in whole years (using `AGE()`/`EXTRACT`), sorted from longest tenure to shortest. Then explain, using what you learned in §5.5.5, what would happen to a row with a `NULL` `hire_date` if one existed, under both `ORDER BY tenure ASC` and `ORDER BY tenure DESC`.

---

## 5.9 Chapter Challenge

**Build a single-query "Employee Master Report"** that combines string, numeric, date, and NULL-handling functions in one `SELECT`, using only the `employees` table.

Requirements:
- A formatted `full_name` column (`"First Last"`).
- A normalized `email` column (defensively `LOWER(TRIM(...))`, even though the seed data is already clean).
- A `username` column extracted from the email using `SUBSTRING`/`POSITION`.
- A `hire_year` column using `EXTRACT`.
- A `tenure_years` column: a single decimal number of years (e.g., `11.5`), computed from `AGE(CURRENT_DATE, hire_date)` and `ROUND`ed to 1 decimal place.
- A `manager_display` column using `COALESCE` to show `'Top of hierarchy'` in place of a `NULL` `manager_id`.
- A `status_flag` column using `NULLIF` that is `NULL` for `'ACTIVE'` employees and shows the actual status otherwise.
- A `batch` column using `MOD(employee_id, 2)` inside a `CASE` to label employees `'Batch A'`/`'Batch B'`.

```sql
SELECT
    employee_id,
    first_name || ' ' || last_name                                    AS full_name,
    LOWER(TRIM(email))                                                 AS email,
    SUBSTRING(email FROM 1 FOR POSITION('@' IN email) - 1)             AS username,
    EXTRACT(YEAR FROM hire_date)                                       AS hire_year,
    ROUND(
        EXTRACT(YEAR  FROM AGE(CURRENT_DATE, hire_date))
      + EXTRACT(MONTH FROM AGE(CURRENT_DATE, hire_date)) / 12.0
    , 1)                                                                AS tenure_years,
    COALESCE(manager_id::text, 'Top of hierarchy')                     AS manager_display,
    NULLIF(status, 'ACTIVE')                                           AS status_flag,
    CASE WHEN MOD(employee_id, 2) = 0 THEN 'Batch B' ELSE 'Batch A' END AS batch
FROM employees
ORDER BY employee_id
LIMIT 5;
```

Expected output (computed as of **2026-09-24** — only `tenure_years` will differ if you run this on a later date):

| employee_id | full_name | email | username | hire_year | tenure_years | manager_display | status_flag | batch |
|---|---|---|---|---|---|---|---|---|
| 1 | Aditi Rao | aditi.rao@company.com | aditi.rao | 2015 | 11.5 | Top of hierarchy | NULL | Batch A |
| 2 | Rahul Mehta | rahul.mehta@company.com | rahul.mehta | 2016 | 10.3 | 1 | NULL | Batch B |
| 3 | Sneha Kulkarni | sneha.kulkarni@company.com | sneha.kulkarni | 2017 | 9.7 | 2 | NULL | Batch A |
| 4 | Vikram Joshi | vikram.joshi@company.com | vikram.joshi | 2018 | 8.2 | 2 | NULL | Batch B |
| 5 | Ananya Singh | ananya.singh@company.com | ananya.singh | 2019 | 7.0 | 2 | ON_LEAVE | Batch A |

Once you can produce this exact output (modulo `tenure_years`), remove the `LIMIT 5` and run it against all 16 employees to complete the full report.

---

## Key Takeaways

- String functions (`CONCAT`/`\|\|`, `SUBSTRING`, `TRIM`, `REPLACE`, `POSITION`) transform and extract text; `||` propagates `NULL` while `CONCAT` treats it as empty — never assume they're interchangeable.
- Numeric functions (`ROUND`, `CEIL`/`FLOOR`, `ABS`, `MOD`, `POWER`) each have a distinct rounding *direction* (nearest, up, down, sign-discarding) — picking the wrong one is a common source of quietly-wrong financial and capacity reports.
- Integer division truncates; always cast or use a decimal literal (`/ 12.0`) when a fractional result is expected.
- Date arithmetic diverges sharply by dialect (`date + integer`/`INTERVAL` in PostgreSQL/Oracle vs. `DATE_ADD`/`DATEDIFF` functions in MySQL/SQL Server); `DATE_TRUNC` always rounds down to a fixed calendar boundary (Monday for weeks in PostgreSQL), never a rolling window.
- `TIMESTAMP` stores a naive wall-clock reading with no timezone context; `TIMESTAMPTZ` stores an absolute UTC instant and converts only at input/output time based on the session's `TimeZone` — conflating the two is a frequent, hard-to-diagnose production bug.
- SQL uses **three-valued logic**: `TRUE`, `FALSE`, and `UNKNOWN`. Any comparison against `NULL` — including `NULL = NULL` — evaluates to `UNKNOWN`, and `WHERE`/`ON`/`HAVING` discard both `FALSE` and `UNKNOWN` rows. `IS NULL`/`IS NOT NULL` are the only correct NULL tests.
- `DISTINCT`, `GROUP BY`, and (with a dialect-dependent default position) `ORDER BY` all treat multiple `NULL`s as equal to each other for grouping/sorting purposes — a deliberate, narrow exception to the "NULL never equals NULL" rule.
- `COALESCE`, `NULLIF`, and `CASE` are the three practical tools for working around NULL's propagation and comparison behavior — use `COALESCE` for defaults, `NULLIF` to manufacture a NULL from a sentinel, and `CASE` for anything more conditional than either.

## What's Next

Chapter 6 moves from **per-row** scalar transformations to **per-group** aggregate functions — `COUNT`, `SUM`, `AVG`, `MIN`, `MAX` — combined with `GROUP BY` and `HAVING`. You'll immediately reuse this chapter's `DATE_TRUNC` and `EXTRACT` patterns as the grouping keys for cohort and time-bucketed reports, and you'll see exactly how `NULL`'s special "grouping" behavior from §5.5.5 plays out once real `GROUP BY` queries are in front of you.

→ [Chapter 6 — Aggregate Functions, GROUP BY, HAVING](06-aggregates.md)
