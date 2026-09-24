# Chapter 28 — Backup & Recovery Concepts

> **Part VI — Database Internals & Production Engineering**
> Previous: [Chapter 27 — Security](27-security.md) · Next: [Chapter 29 — Database Internals](29-database-internals.md)

This chapter is conceptual and operational rather than query-syntax-heavy. It
runs against `banking_db` as its motivating example throughout — a schema
holding customers, accounts, transactions, and loans is the clearest possible
illustration of *why* backup and recovery discipline exists: this is data
that represents real money, is subject to regulatory retention requirements,
and can never be casually "lost and re-entered." If you haven't loaded it:

```bash
psql -f databases/banking_db.sql
```

Most of the commands shown in this chapter are **shell/CLI-level operations**
(`pg_dump`, `pg_basebackup`, `psql`, `pg_restore`), not SQL statements — they
are shown in ```bash blocks. A handful of dialect-specific SQL statements
(Oracle RMAN scripts, SQL Server `BACKUP`/`RESTORE`) are shown in ```sql
blocks where that's how the tool is actually invoked.

---

## 28.0 Why This Chapter Exists

Every chapter before this one has assumed the database is simply *there*:
you write a query, it runs against live data, you get an answer. This chapter
is about the uncomfortable question none of those chapters asked: **what
happens when the data itself is threatened?**

There are exactly two categories of threat, and they require different
defenses:

1. **Physical/infrastructure failure** — a disk fails, a server catches fire,
   a datacenter loses power, a cloud region goes down. The data files
   themselves become unavailable or corrupted. Nothing about the *content*
   of the data was wrong — the *medium* holding it failed.
2. **Logical/human error** — someone (a person, a script, a buggy
   deployment) runs `DELETE FROM banking_db.accounts;` with no `WHERE`
   clause, or a migration drops the wrong column, or a batch job double-
   charges every customer. The infrastructure is perfectly healthy; the
   *content* is now wrong, and it's wrong in every replica and every disk
   almost instantly, because a correctly-functioning database faithfully
   replicates mistakes just as fast as it replicates good writes.

A backup strategy that only defends against #1 (e.g., a replica with
synchronous failover) leaves you completely exposed to #2 — the replica will
cheerfully apply the same erroneous `DELETE`. A backup strategy that only
defends against #2 (e.g., a nightly logical dump with no faster recovery
path) leaves you exposed to #1 in the sense that if the failure happens at
4:59pm and the last dump was at midnight, you've lost a full business day of
transactions. Real backup/DR strategy design is about layering defenses so
that *both* categories are covered, at a cost (storage, engineering time,
restore speed) proportional to how bad the outcome would be if you didn't.

For a bank, the outcome of getting this wrong is not "an inconvenienced
user" — it's "a customer's account balance is wrong, and there is no
independent record of the truth." That is the standard this chapter is
teaching you to design against.

> **⚠️ Warning — the single most important sentence in this chapter**
> **An untested backup is not a backup. It is an unverified hope.** Section
> 28.9 covers why, in detail — but hold that sentence in your head through
> every other section, because every backup mechanism described below has
> ways to silently fail while still *looking* successful.

---

## 28.1 Logical Backups

### 1. Simple explanation
A logical backup is your database's content re-expressed as portable
instructions — SQL `INSERT`/`COPY` statements, or an equivalent structured
data format — that, if run against an empty database, would recreate the
same tables, rows, and (optionally) schema objects. Think of it as "the
recipe," not "a photograph of the finished cake."

### 2. Technical explanation
A logical backup tool connects to the database like a client, reads the
schema definitions and row data through the normal query interface (or an
internal equivalent), and serializes that into a format — plain SQL text, a
compressed custom archive, or a vendor-specific export format — that is
independent of the database engine's on-disk file layout. Restoring means
*re-creating* the objects and *re-inserting* the rows: every table is
built from `CREATE TABLE`, every row is written via `INSERT` or a bulk-load
equivalent (`COPY`), and every index/constraint is rebuilt from scratch
afterward.

### 3. Why it exists
Because on-disk file formats are tied to a specific engine version, storage
engine, operating system, and sometimes CPU architecture (byte order), you
cannot always just copy files between two different servers and expect them
to work — a physical backup restored onto a different major version can
outright fail to start. Logical backups solve exactly this: they express
*what* the data is, not *how* it happens to be laid out on disk right now,
so they can move across versions, across operating systems, and even across
different database *products* (with translation).

### 4. Syntax — taking a logical backup

**[PostgreSQL]**
```bash
# Single-schema logical backup, custom format (compressed, supports
# selective restore of individual tables — see §28.1.7)
pg_dump -h localhost -U postgres -d sql_mastery -n banking_db \
        -F custom -f banking_db_2026-09-24.dump

# Plain SQL text — human-readable, diffable, portable to any psql
pg_dump -h localhost -U postgres -d sql_mastery -n banking_db \
        -F plain -f banking_db_2026-09-24.sql

# Every database + roles + tablespaces on the whole server ("cluster")
pg_dumpall -h localhost -U postgres -f full_cluster_2026-09-24.sql
```

**[MySQL]**
```bash
# --single-transaction gives a consistent snapshot for InnoDB tables
# without locking the whole database (see the consistency discussion
# in §28.3.9 — this is the logical-backup equivalent of that concern)
mysqldump -u root -p --single-transaction --routines --triggers \
          banking_db > banking_db_2026-09-24.sql
```

**[Oracle]**
```bash
expdp system/password DIRECTORY=backup_dir \
      DUMPFILE=banking_db_%U.dmp SCHEMAS=BANKING_DB \
      LOGFILE=banking_export.log
```

**[SQL Server]** — SQL Server's native `BACKUP DATABASE` produces a
proprietary `.bak` file tied to SQL Server's own page format; that is a
*physical* backup mechanism in spirit and is covered in §28.2. For a
genuinely portable, logical export of table data, use `bcp` per table, or a
scripting tool:
```bash
bcp banking_db.dbo.accounts out accounts.dat -c -T -S localhost
mssql-scripter -S localhost -d banking_db --data-only > banking_db_data.sql
```

### 5. Expected output (illustrative)
```text
$ pg_dump -v -h localhost -U postgres -d sql_mastery -n banking_db -F custom -f banking_db_2026-09-24.dump
pg_dump: reading schemas
pg_dump: reading user-defined tables
pg_dump: reading user-defined functions
pg_dump: reading table structure for table "banking_db.customers"
pg_dump: reading table structure for table "banking_db.accounts"
pg_dump: reading table structure for table "banking_db.transactions"
pg_dump: reading table structure for table "banking_db.loans"
pg_dump: reading table structure for table "banking_db.audit_log"
pg_dump: dumping contents of table "banking_db.customers"
pg_dump: dumping contents of table "banking_db.accounts"
pg_dump: dumping contents of table "banking_db.transactions"
pg_dump: dumping contents of table "banking_db.loans"
pg_dump: dumping contents of table "banking_db.audit_log"
```

### 6. Restoring a logical backup

```bash
# Full restore into a fresh, empty database. Notice what actually happens
# here: every row is re-inserted, and then every index/constraint on
# accounts, transactions, and loans is rebuilt from nothing — this is the
# "replay all the work" cost mentioned in §28.1.8.
createdb sql_mastery_restore
pg_restore -h localhost -U postgres -d sql_mastery_restore \
           banking_db_2026-09-24.dump

# Restore ONLY the accounts table — a capability physical backups
# fundamentally cannot offer (§28.4 compares this directly)
pg_restore -h localhost -U postgres -d sql_mastery_restore \
           -t accounts banking_db_2026-09-24.dump

# Plain-SQL restore
psql -h localhost -U postgres -d sql_mastery_restore -f banking_db_2026-09-24.sql
```

### 7. Pros and cons

| Pros | Cons |
|---|---|
| Portable across PostgreSQL versions, OS, and architecture | Slow on large databases — every row is re-inserted, every index rebuilt |
| Human-inspectable (plain-text format can be read/diffed/greped) | Does not capture the exact physical/on-disk state (no WAL, no bloat, no page layout) |
| Selective restore — pull back a single table, e.g. just `banking_db.accounts`, without touching `transactions` or `loans` | Restore time grows with data volume, not just file size — a 500GB logical dump can take dramatically longer to *restore* than to *back up* |
| Can move data between different major engine versions | No point-in-time granularity by itself — a dump is a single instant, not a stream (contrast with §28.5) |

### 8. Internal mechanics
A logical restore isn't "loading data" in the sense a physical restore is —
it is **literally re-executing work**: `CREATE TABLE customers (...)`, then
potentially millions of `COPY customers FROM stdin` rows, then `CREATE INDEX
customers_pkey`, then re-validating every `CHECK` and `FOREIGN KEY`
constraint (e.g., every `accounts.customer_id` must resolve against the
freshly-loaded `customers` table). All of that CPU and I/O work that the
original database did over its entire history — one row, one index update at
a time — gets redone, in one sitting, during restore. This is precisely why
logical restores of large databases can be dramatically slower than physical
restores of the same data.

### 9. Common mistakes
- Assuming dump *time* tells you anything about restore *time* — a
  compressed `pg_dump` of a 200GB `banking_db.transactions` table might
  finish backing up in 40 minutes but take 8+ hours to restore once you add
  back every index.
- Forgetting `--single-transaction` **[MySQL]** or not using a
  consistent-snapshot flag, and getting a dump where `accounts` and
  `transactions` were read at slightly different moments under concurrent
  writes — internally inconsistent even though each table individually
  dumped fine.
- Relying solely on logical backups for a genuinely huge production
  database and discovering, only during a real outage, that the restore
  takes 30 hours against a business that cannot be down for 30 hours. This
  is a decision that must be made and tested *before* the outage, not
  discovered during it.

### 10. Edge cases
- Schema-only (`pg_dump --schema-only`) and data-only (`pg_dump
  --data-only`) dumps are useful for migrating structure separately from
  content — e.g., standing up an empty staging copy of `banking_db` with the
  same constraints but synthetic data.
- Selective restore of `banking_db.accounts` alone, post-incident, only
  works cleanly if you also understand its foreign-key dependents
  (`transactions.account_id`) — restoring one table in isolation can violate
  referential integrity against data that's already there, or leave you
  needing to also restore related tables.

---

## 28.2 Physical Backups

### 1. Simple explanation
A physical backup is a byte-for-byte copy of the actual files the database
engine stores data in — not a description of the data, but the data's exact
storage representation. Think of it as "a photograph of the finished cake,"
not the recipe.

### 2. Technical explanation
A physical backup copies the data directory (or equivalent storage, e.g.
tablespace files, control files, and — critically — enough write-ahead log
to reach a consistent state) exactly as the engine has it on disk: the same
page layout, the same index B-tree structures, the same free space maps.
Restoring means putting those exact files back where the engine expects
them and starting the engine — there is no re-insertion of rows and no index
rebuilding, because the indexes are *already built*, byte-for-byte, inside
the copied files.

### 3. Why it exists
For large databases, logical backup/restore's "redo all the work" cost
becomes operationally unacceptable — a bank cannot tolerate a 30-hour
restore window after a hardware failure. Physical backups exist to make
backup and restore proportional to *storage size and I/O throughput*
instead of *row count and index complexity*, which is dramatically faster
for large datasets, and produces an exact reproduction of the original
database's physical state.

### 4. Syntax — taking a physical backup

**[PostgreSQL]**
```bash
# Physical base backup taken while PostgreSQL keeps serving live reads
# and writes — consistency is guaranteed by WAL, not by freezing the
# filesystem (see §28.2.9 and §28.6 for why this is safe).
pg_basebackup -h localhost -U replicator -D /backups/base_2026-09-24 \
              -Ft -z -Xs -P
# -D   target directory
# -Ft -z   tar format, gzip-compressed
# -Xs  stream the WAL generated DURING the backup alongside it
# -P   show progress
```
Expected output:
```text
26186/26186 kB (100%), 1/1 tablespace
```

**[SQL Server]**
```sql
BACKUP DATABASE banking_db
TO DISK = 'D:\backups\banking_db_full.bak'
WITH INIT, COMPRESSION;
```

**[Oracle]** (RMAN)
```bash
rman target /
RMAN> BACKUP DATABASE PLUS ARCHIVELOG;
```

**[MySQL]** — physical hot backup via Percona XtraBackup (InnoDB `.ibd`
files copied while the server keeps running):
```bash
xtrabackup --backup --target-dir=/backups/base_2026-09-24 \
           --user=root --password=***
xtrabackup --prepare --target-dir=/backups/base_2026-09-24
```

### 5. Restoring a physical backup

**[PostgreSQL]**
```bash
systemctl stop postgresql
rm -rf /var/lib/postgresql/15/main/*
tar -xzf /backups/base_2026-09-24/base.tar.gz -C /var/lib/postgresql/15/main/
chown -R postgres:postgres /var/lib/postgresql/15/main
systemctl start postgresql
```

**[SQL Server]**
```sql
RESTORE DATABASE banking_db
FROM DISK = 'D:\backups\banking_db_full.bak'
WITH REPLACE;
```

**[MySQL]** (XtraBackup)
```bash
# Stop mysqld and empty the data directory first, then:
xtrabackup --copy-back --target-dir=/backups/base_2026-09-24
chown -R mysql:mysql /var/lib/mysql
```

### 6. Pros and cons

| Pros | Cons |
|---|---|
| Much faster backup *and* restore for large databases — proportional to storage size, not row count | Larger on disk (no logical compression of redundant index structures the way a rebuild would produce) |
| Exact reproduction — every index, every bit of physical layout, identical | Not portable across engine major versions, OS, or CPU architecture — a PostgreSQL 15 data directory will not start under PostgreSQL 12, and rarely survives an OS/architecture change |
| No CPU cost to "rebuild" anything — files are already built | Typically all-or-nothing restore (you generally cannot restore just `banking_db.accounts` out of a physical backup) |
| Can be taken hot (live, under load) with the right tooling | Requires care to reach a *consistent* point — see edge case below |

### 7. Internal mechanics — reaching a consistent state under live writes
This is the single most important technical detail of physical backups, and
it's worth stating precisely: **a physical backup taken while the database is
being written to is not simply "copy the files."** Files are large, copying
takes time, and a table's data file might be copied at 10:00:00 while its
index file is copied at 10:00:07 — if writes happened in between, the copied
files are internally inconsistent (the index might point at rows the data
file doesn't yet have written that way, or vice versa).

Tools like `pg_basebackup`, RMAN, and XtraBackup solve this by recording the
WAL/redo-log position (an LSN — log sequence number) at the *start* of the
copy and the position at the *end*, then including all WAL/redo generated
during that window as part of the backup. On restore, the engine replays
that WAL forward over the raw copied files until they reach a single
mutually consistent point — the same mechanism that powers crash recovery
(§28.6).

### 8. Common mistakes
- Restoring a physical backup onto a different major version, OS, or CPU
  architecture and being surprised the database won't start — physical
  backups have zero cross-version/cross-platform portability by design.
- Forgetting file ownership/permissions after a raw copy-back (`chown` steps
  above are not decorative — the engine typically refuses to start as the
  wrong OS user).
- Storing the physical backup on the same physical infrastructure (same
  disk array, same datacenter, same cloud region) as the primary database.
  A datacenter-level event — fire, flood, regional outage — destroys the
  primary *and* the backup simultaneously. This is why the classic **3-2-1
  rule** exists: at least 3 copies of the data, on at least 2 different
  types of storage media, with at least 1 copy offsite/off-infrastructure.

### 9. Edge case — the naive filesystem copy trap
```bash
# DO NOT DO THIS against a live, running database:
cp -r /var/lib/postgresql/15/main /backups/naive_copy
```
A plain recursive file copy of a *live* data directory has no concept of a
WAL-consistent window. Different files get copied at different wall-clock
moments while the engine keeps writing underneath the copy operation —
the result can be a data directory that looks complete but is internally
torn: some pages reflect transactions that others don't. On restore, this
can manifest as anything from silent wrong query results to the engine
refusing to start at all. The difference between this and `pg_basebackup`
is exactly the WAL bracketing described in §28.2.7 — never substitute a raw
`cp`/`rsync` of a running data directory for purpose-built backup tooling.

### 10. When to use physical vs. hot backup tooling
Always use the vendor/ecosystem tool designed for hot physical backups
(`pg_basebackup`, RMAN, XtraBackup, SQL Server's native `BACKUP DATABASE`
which already handles this correctly) rather than ad hoc file copying. These
tools exist specifically to solve the consistency problem described above.

---

## 28.3 Logical vs. Physical — Decision Framework

| Factor | Favor Logical | Favor Physical |
|---|---|---|
| Database size | Small–medium (dump/restore completes in an acceptable window) | Large (restore time must be proportional to storage, not row count) |
| Cross-version / cross-platform migration | Yes — this is logical backup's core strength | No — physical backups are tied to engine version/OS/architecture |
| Granularity of restore needed | Need to restore a single table (e.g., just `banking_db.loans` after a bad migration) | Need to restore the entire database as a unit |
| Restore speed under outage pressure | Acceptable if RTO is generous | Required if RTO is tight (see §28.7) |
| Human inspection / auditing of backup content | Plain-SQL dumps are readable/diffable | Not human-readable |
| Foundation for PITR | Not directly (a dump is a single snapshot) | Yes — physical base backup + WAL/log archive is the PITR mechanism (§28.5) |

> **Important Note**
> These are not mutually exclusive in a real strategy. A common, well-designed
> production setup for something like `banking_db` uses **physical backups +
> continuous WAL archiving as the primary recovery mechanism** (fast restore,
> PITR capability), while *also* taking periodic **logical dumps of specific
> tables** for portability, auditing, or migrating a subset of data into a
> reporting environment.

---

## 28.4 Point-in-Time Recovery (PITR)

### 1. Simple explanation
PITR lets you restore a database not just to "the last backup," but to
**any exact moment in time** between that backup and now — including one
second before a mistake happened.

### 2. Technical explanation
PITR works by combining two things: (a) a full **physical base backup**
taken at some point, and (b) a **continuous, unbroken archive** of every
change recorded in the write-ahead log (WAL) **[PostgreSQL]**, binary log
**[MySQL]**, or redo log/archive log **[Oracle]** / transaction log
**[SQL Server]** from that base backup's timestamp forward. To recover to a
chosen instant, you restore the base backup, then **replay the logged
changes forward**, one committed transaction at a time, stopping exactly at
the requested timestamp (or transaction ID/LSN) — before, not after, the
unwanted change.

### 3. Why it matters — a concrete `banking_db` disaster
Imagine a nightly physical backup of `banking_db` runs at midnight. At
**2:47:00pm**, an engineer runs a migration script with a bug:

```sql
DELETE FROM banking_db.accounts;
```

No `WHERE` clause. Every row in `accounts` — including Ravi Shankar's
savings account, Suresh Menon's fixed deposit — is gone, and every
downstream `transactions` row referencing those accounts is now orphaned
from the customer's perspective. Without PITR, your only recovery option is
last night's backup: you lose **every transaction from midnight to
2:47pm** — deposits, withdrawals, transfers — real money movements that
happened and now have no record.

With PITR, you restore the midnight base backup and replay WAL forward to
`2026-09-24 14:46:59` — one second *before* the `DELETE` committed. Every
legitimate transaction between midnight and 2:46:59pm is recovered exactly
as it happened. The mistake, and only the mistake, is undone.

### 4. Syntax — setting up and using PITR

**[PostgreSQL]** — enable WAL archiving ahead of time:
```ini
# postgresql.conf
archive_mode = on
archive_command = 'cp %p /archive/wal/%f'
```
Recovering to a point in time:
```bash
# 1. Restore the most recent base backup taken before the incident
tar -xzf /backups/base_2026-09-24.tar.gz -C /var/lib/postgresql/15/main/

# 2. Tell PostgreSQL where the WAL archive lives and where to stop
cat >> /var/lib/postgresql/15/main/postgresql.auto.conf <<EOF
restore_command = 'cp /archive/wal/%f %p'
recovery_target_time = '2026-09-24 14:46:59'
EOF
touch /var/lib/postgresql/15/main/recovery.signal

systemctl start postgresql
```
Expected log output (illustrative):
```text
LOG:  starting point-in-time recovery to 2026-09-24 14:46:59+00
LOG:  restored log file "000000010000000000000047" from archive
LOG:  redo starts at 0/47000028
LOG:  recovery stopping before commit of transaction 88213, time 2026-09-24 14:47:03.221+00
LOG:  recovery has completed
LOG:  database system is ready to accept connections
```

**[MySQL]** — base backup + binlog replay to a stop point:
```bash
mysqlbinlog --start-datetime="2026-09-24 00:00:00" \
            --stop-datetime="2026-09-24 14:46:59" \
            mysql-bin.000045 | mysql -u root -p banking_db
```

**[Oracle]** — RMAN recovery until time, then reset the online logs:
```sql
RUN {
  SET UNTIL TIME "TO_DATE('2026-09-24 14:46:59','YYYY-MM-DD HH24:MI:SS')";
  RESTORE DATABASE;
  RECOVER DATABASE;
}
ALTER DATABASE OPEN RESETLOGS;
```

**[SQL Server]** — restore chain: full backup, then transaction log
backups, stopping mid-log:
```sql
RESTORE DATABASE banking_db
FROM DISK = 'D:\backups\banking_db_full.bak'
WITH NORECOVERY;

RESTORE LOG banking_db
FROM DISK = 'D:\backups\banking_db_log1.trn'
WITH STOPAT = '2026-09-24T14:46:59', RECOVERY;
```

### 5. Internal mechanics
See §28.6 for the full WAL model. The essential point for PITR: WAL records
are appended **sequentially, in commit order**, so "replay everything up to
timestamp X" is well-defined and deterministic — the log itself *is* the
ordered history of every change ever committed. PITR is really just "start
from a known-good full snapshot, then fast-forward through history, and
stop wherever you say."

### 6. Common mistakes
- **Gaps in the WAL/log archive.** If `archive_command` silently fails for
  even one segment (disk full, permissions error) and nobody notices,
  recovery cannot cross that gap — you can only recover up to the last
  successfully archived segment, and you may not discover this until the
  moment you desperately need it.
- **Recovery target boundary confusion.** `recovery_target_time` stops
  recovery *before* the first transaction that committed after that
  timestamp — but timestamp precision (seconds vs. microseconds) and clock
  skew between the application server and database server can make "one
  second before" ambiguous. When precision matters, target a specific
  transaction ID/LSN instead of a wall-clock timestamp.
- **Treating replication as PITR.** A synchronous replica gives you
  failover, not "go back in time" — it faithfully applies the same
  `DELETE FROM accounts;` a fraction of a second after the primary does
  (§28.6 covers this distinction directly).

### 7. Edge cases
- Recovering "up to but not including transaction 88213" (by XID) is more
  precise than a timestamp when multiple transactions commit within the
  same second — a real concern on a busy `transactions` table.
- PITR is only as far back as your retention window allows: if WAL archives
  are only kept for 7 days, you cannot PITR to something 10 days ago — you'd
  need an older base backup that no longer exists either. Retention policy
  design is part of RPO planning (§28.7).

---

## 28.5 WAL: Just Enough for Backup/Recovery Purposes

> A full architectural deep dive into WAL, MVCC, and storage internals is
> Chapter 29. This section covers only what backup/recovery needs.

### Simple explanation
Before the database changes a data file on disk, it first writes down *what
it's about to do* in a separate, sequential log. Only after that log entry
is safely on disk does the actual data file get modified (and often that
modification is deferred and batched for efficiency).

### Technical explanation
**Write-Ahead Logging (WAL)** guarantees that no data file modification is
considered durable until the corresponding log record describing that
change is durably written first. Because the log is append-only and
strictly ordered, it forms a complete, replayable history of every change
made to the database, in the exact order those changes were committed.

### Why it exists
WAL exists to serve two purposes simultaneously, both essential to this
chapter:

1. **Crash recovery.** If the server loses power mid-operation, data files
   on disk may reflect a half-finished state. On restart, the engine reads
   the WAL from the last checkpoint and *replays* any logged changes that
   hadn't yet been fully applied to the data files — bringing the database
   back to a consistent, correct state without losing any transaction that
   had actually committed.
2. **PITR and replication.** Because WAL is a sequential, ordered record of
   every change, it can be archived (§28.5) and shipped to another location
   entirely — either replayed later during recovery, or streamed
   continuously to a standby server (§28.6) to keep it up to date in near
   real time.

### Illustration with `banking_db`
When a customer transfers ₹10,000 from Ravi's savings account to Neha's
account (as seen in the `transactions` seed data), the engine does not
directly rewrite the `accounts.balance` pages on disk as its first act.
Conceptually:

1. WAL records are written describing: debit account 1's balance, credit
   account 3's balance, insert the `TRANSFER_OUT` row, insert the
   `TRANSFER_IN` row.
2. Those WAL records are flushed to durable storage — **this** is what
   makes the transaction's `COMMIT` durable.
3. The actual heap pages for `accounts` and `transactions` are updated in
   memory (and eventually written to disk by the background writer), but
   even if the server crashes immediately after commit, the WAL already has
   everything needed to reconstruct that exact change.

This is also why a physical base backup taken mid-write is rescued by
including the WAL generated during the copy window (§28.2.7) — the WAL
*is* the mechanism that makes an otherwise-inconsistent set of copied files
resolvable into one consistent point.

### Common mistakes
- Assuming WAL/binlog archiving happens "automatically" without checking —
  it must be explicitly enabled and monitored (`archive_mode`,
  `archive_command` **[PostgreSQL]**; binary logging **[MySQL]**; archive
  log mode **[Oracle]**), and a failed archive step is a silent PITR outage
  waiting to be discovered during an actual incident.
- Confusing "WAL is being generated" with "WAL is being safely archived
  somewhere durable and separate from the primary." A full disk on the
  primary that stops WAL archiving, unnoticed, is a classic real-world
  failure mode.

Chapter 29 covers checkpointing, WAL segment recycling, and MVCC's use of
this same log in far more depth.

---

## 28.6 Replication and Its Role in Backup/DR Strategy

> Full replication topology and mechanics are Chapter 30. Here, the
> connection to backup/DR strategy specifically.

A **replica** is a second copy of the database that continuously receives
and applies the same WAL/binlog stream discussed above, keeping it a few
milliseconds-to-seconds behind the primary. This matters to this chapter in
two concrete ways:

1. **Backup source offloading.** Taking a `pg_basebackup` or `mysqldump`
   directly against a busy primary competes for I/O and CPU with real
   customer traffic — every `SELECT` a backup tool issues against
   `banking_db.transactions` is a query the production workload has to wait
   behind. Taking the same backup from a replica instead removes that
   contention entirely, at the cost of the backup being a few seconds (or
   whatever the replication lag is) behind the true primary state.
2. **Fast failover target.** If the primary server dies (hardware failure,
   not human error), a replica can be promoted to primary in seconds to
   minutes, which is dramatically faster than restoring any backup from
   scratch. This is the backbone of a low-RTO strategy (§28.7).

> **⚠️ Warning**
> A replica is **not a substitute for a backup**. Replication faithfully
> propagates every write, including catastrophic ones — the accidental
> `DELETE FROM banking_db.accounts;` from §28.4.3 replicates to every
> standby almost immediately. Replicas defend against *infrastructure*
> failure (category 1 in §28.0); they do essentially nothing against
> *logical* failure (category 2) unless paired with either a deliberately
> **delayed** replica (one that applies WAL/binlog with an intentional lag,
> giving you a window to intervene) or a genuine PITR-capable backup chain.

---

## 28.7 Disaster Recovery: RPO and RTO

### Definitions
- **RPO (Recovery Point Objective)** — the maximum acceptable amount of
  data loss, measured in *time*. An RPO of 5 minutes means: however you
  design backups/WAL archiving, you must never be in a position to lose
  more than the last 5 minutes of committed transactions, no matter when
  disaster strikes.
- **RTO (Recovery Time Objective)** — the maximum acceptable *downtime*
  during a recovery. An RTO of 1 hour means: from the moment disaster is
  declared to the moment `banking_db` is back online and correct, the
  entire process — including detection, decision-making, and the technical
  restore itself — must complete within one hour, and this must be a
  *tested*, not theoretical, number (§28.9).

### Mapping RPO/RTO to strategy

| Target RPO | Target RTO | Required Strategy | Why |
|---|---|---|---|
| 24 hours | 8+ hours | Nightly logical dump (`pg_dump`) | Acceptable only for low-stakes/small data; a full day of banking transactions lost is normally unacceptable, shown here only as the baseline |
| 1 hour | 2–4 hours | Nightly physical base backup + hourly WAL/log archiving, PITR-capable | Restore is a base backup + a bounded amount of WAL replay; still a from-scratch restore, so RTO includes restore time |
| 5 minutes | 1 hour | Continuous WAL/binlog streaming archival + periodic physical base backups + tested PITR runbook | This is the realistic target for a bank's core ledger tables (`accounts`, `transactions`) — see justification below |
| Near-zero (seconds) | Minutes | Synchronous (or near-synchronous) replica with automated failover, *in addition to* independent backups for logical-error protection | Failover to a hot standby is far faster than any restore process; backups are still mandatory for category-2 failures |

> **Important Note**
> RPO and RTO are business decisions translated into engineering
> requirements, not the other way around. For `banking_db`, an RPO of 5
> minutes means: "a customer's deposit or withdrawal, once confirmed to
> them, must never be more than 5 minutes away from being durably archived
> somewhere recoverable" — which directly dictates that WAL archiving
> cannot be daily or hourly; it must be continuous/streaming. An RTO of 1
> hour means the *whole* restore runbook — provisioning a server, restoring
> the base backup, replaying WAL, validating data, cutting traffic over —
> must complete in 60 minutes, tested end-to-end, not estimated.

### Real-world use cases
- **A bank's regulatory retention requirement.** Financial regulators
  typically mandate that transaction records be retained and recoverable
  for a period of years, not just "until the next backup rotates it out."
  This drives both backup *retention* policy (how long dumps/base backups
  are kept, separate from how long WAL is kept for PITR) and, separately,
  audit-log durability (Chapter 22's `audit_log` table is itself something
  that must be backed up, not just the primary tables).
- **An e-commerce site's DR runbook.** A retailer with a hard RTO around
  peak sales events (e.g., a flash sale) might accept a slightly higher RPO
  (a few minutes of lost orders is bad but survivable) in exchange for an
  extremely tight RTO (any downtime during the sale is catastrophic to
  revenue and reputation) — driving investment toward a hot standby/fast
  failover topology over pure backup-and-restore.

---

## 28.8 Restore Testing

### Why an untested backup should be assumed broken
A backup is a *process* with many independent steps, and any one of them
can fail silently while the backup job itself reports "success":

- **Corruption** introduced during copy, compression, or storage that
  isn't detected until you try to read the file back.
- **Incomplete WAL/log archives** — a gap nobody noticed (§28.4.6) that
  makes PITR impossible past a certain point.
- **Missing permissions** on the restore target that only surface when
  someone actually tries to run the restore.
- **Forgotten runbook steps** — a manual step ("also re-apply this GRANT,"
  "also re-create this extension") that lived only in someone's memory and
  was never written down or automated.
- **Silent version drift** — the backup tool, the restore target, and the
  original server versions have quietly diverged since the backup was last
  tested.

None of these show up in "the `pg_dump`/`pg_basebackup` command exited
with status 0." A successful backup *command* and a *usable* backup are
different claims, and only a real restore proves the second one.

> **⚠️ Warning — restated because it matters**
> **Assume any backup that has never been restored does not work.** This is
> not pessimism; it is the only defensible operating assumption, because the
> failure modes above are specifically the kind that hide until the worst
> possible moment — during an actual outage, under pressure, with the
> business waiting.

### Practical restore drill process
1. On a schedule (e.g., weekly for critical systems like `banking_db`,
   monthly at minimum), restore the most recent backup into a **separate**
   environment — not the primary, not even the same physical
   infrastructure.
2. Verify data integrity after every drill, not just "the restore command
   didn't error":

```sql
-- Row count sanity check against a known reference count
SELECT count(*) FROM banking_db.accounts;
SELECT count(*) FROM banking_db.transactions;

-- Smoke-test query: does the restored data behave sensibly?
SELECT a.account_id, a.balance,
       (SELECT COALESCE(SUM(CASE WHEN t.transaction_type IN ('DEPOSIT','TRANSFER_IN')
                                  THEN t.amount ELSE -t.amount END), 0)
        FROM banking_db.transactions t WHERE t.account_id = a.account_id) AS derived_balance_delta
FROM banking_db.accounts a
ORDER BY a.account_id;
```

```bash
# Checksum comparison against the primary, where feasible
psql -d banking_db -c "SELECT md5(string_agg(t.*::text, '' ORDER BY transaction_id)) FROM banking_db.transactions t;"
```

3. Time the entire drill from "restore started" to "verification query
   passed" — this is your *actual, tested* RTO, not the number written in a
   planning document.
4. Record and review results; treat a failed drill as a production
   incident, because it reveals that a real disaster would also have
   failed.

---

## 28.9 Common Mistakes — Chapter Recap

- Treating "the backup job ran without error" as equivalent to "the backup
  works" (§28.9).
- Choosing logical-only backups for a database whose size makes restore
  time incompatible with the required RTO, and discovering this only during
  a real outage.
- Storing backups on the same physical infrastructure (disk array,
  datacenter, cloud region) as the primary — violating the 3-2-1 rule and
  turning a datacenter-level disaster into total data loss.
- Treating a replica as a backup, when it only defends against
  infrastructure failure, not human/logical error.
- Letting WAL/binlog archiving fail silently, quietly capping how far back
  PITR can actually reach.
- Never rehearsing the restore runbook end-to-end, so tribal knowledge
  (manual steps, credentials, exact command flags) is missing exactly when
  it's needed most.

---

## 28.10 Practice Questions

1. `banking_db` is 2GB today and growing slowly. What backup strategy
   (logical, physical, or both) would you choose, and why?
2. Now assume `banking_db.transactions` alone has grown to 4TB over ten
   years of operation. Does your answer to Q1 change? What specifically
   breaks about a pure logical-backup strategy at this size?
3. An engineer says "we have replication set up between two servers, so we
   don't need backups." Explain precisely what failure mode this leaves the
   bank exposed to, using the `accounts` table as your example.
4. Define, in your own words and using banking-specific numbers, what an
   RPO of 15 minutes requires from the backup/WAL-archiving pipeline. What
   does it *not* guarantee?
5. A `DELETE FROM banking_db.loans WHERE customer_id = 3;` was run by
   mistake at 9:14am, deleting Suresh Menon's loan record. The last full
   physical backup was Sunday at 2am; WAL has been continuously archived
   since. Walk through, step by step, how you'd recover just this row
   without losing any other write made since Sunday.
6. Why does a `pg_basebackup` (or RMAN, or XtraBackup) taken while the
   database is under heavy write load produce a consistent result, while a
   plain `cp -r` of the same live data directory does not? Be specific
   about what mechanism resolves the inconsistency.
7. Your organization currently only tests restores once a year. List at
   least four specific failure modes this schedule would fail to catch in
   time, drawing on §28.9.
8. A colleague proposes storing nightly `banking_db` backups in the same
   cloud region, same availability zone, as the production database "to
   keep restore times fast." What's the tradeoff being made here, and what
   would you propose instead?
9. Explain why a logical dump restore of `banking_db` rebuilds indexes from
   scratch, while a physical restore does not — and why that difference
   directly affects restore time at scale.
10. Given a bank's regulatory requirement to retain and be able to recover
    transaction records for 7 years, what does that imply about backup
    *retention* policy versus WAL/PITR *retention* policy — are these the
    same thing? Why or why not?
11. A restore drill against a staging copy of `banking_db` completes
    without errors, but the row count in `accounts` is off by exactly the
    number of rows inserted in the last 6 hours before the backup was
    taken. Is this a bug, or expected? How would you confirm which?
12. Design (in words) a scenario where choosing an RTO of 5 minutes, rather
    than 1 hour, changes your entire backup architecture — not just "do it
    faster," but a fundamentally different mechanism.

---

## 28.11 Chapter-Ending Challenge

Design a complete backup/DR strategy document for `banking_db`. Your
document should specify, with justification for each choice (not just a
bare answer):

1. **Backup frequency and type** — what combination of logical and physical
   backups you'll run, how often, and why, given `banking_db`'s role as a
   financial system of record.
2. **WAL/log archiving approach** — how continuously changes are archived,
   where they're stored, and how you'll detect and alert on archiving
   failures before they become a silent PITR gap.
3. **Replica topology for failover** — how many replicas, synchronous or
   asynchronous, and how they relate to (but do not replace) your backup
   strategy.
4. **Target RPO and RTO, with justification** — pick concrete numbers for
   `banking_db` specifically (not a generic system) and justify them in
   terms of what a violation would mean for a real customer's account.
5. **A restore-testing schedule** — how often you'll run full restore
   drills, what environment they run against, and what specific integrity
   checks (row counts, checksums, smoke-test queries against `accounts` and
   `transactions`) must pass for a drill to count as successful.

There is no single correct answer — the goal is a document that a new DBA
joining the team could read and understand exactly what would happen, and
why, in every failure scenario covered in this chapter.

---

## Key Takeaways

- Backup/DR strategy defends against two fundamentally different failure
  modes — physical/infrastructure failure and logical/human error — and a
  complete strategy must cover both; replication alone only covers the
  first.
- **Logical backups** (`pg_dump`, `mysqldump`, `expdp`) express data as
  portable instructions: version/platform-portable, human-inspectable, and
  capable of selective restore, at the cost of restore speed that scales
  with row count and index complexity, not just storage size.
- **Physical backups** (`pg_basebackup`, RMAN, XtraBackup, native `BACKUP
  DATABASE`) copy the actual on-disk representation: fast at any scale and
  an exact reproduction, at the cost of cross-version/cross-platform
  portability and (typically) all-or-nothing restore.
- **Point-in-time recovery (PITR)** combines a physical base backup with a
  continuous WAL/binlog/redo-log archive, letting you restore to any exact
  moment — including one second before an accidental
  `DELETE FROM accounts;` — instead of losing everything since the last
  backup.
- **WAL** (full depth in Ch. 29) is the append-only, sequential log written
  *before* data files are modified; it underlies both crash recovery and
  PITR/replication because it is a complete, ordered, replayable history of
  every committed change.
- **Replication** (full depth in Ch. 30) turns a standby into both a
  backup-load offload target and a fast failover target — but it is not a
  backup, because it replicates mistakes just as faithfully as good writes.
- **RPO** bounds acceptable data loss in time; **RTO** bounds acceptable
  downtime. Both must be concrete, tested numbers tied to real business
  consequences, not aspirational targets in a document nobody has verified.
- **An untested backup should be assumed broken.** Corruption, WAL
  archiving gaps, missing permissions, and forgotten runbook steps all hide
  behind a backup job that reports success — only a real, scheduled restore
  drill with integrity verification proves a backup actually works.
- The **3-2-1 rule** (3 copies, 2 media types, 1 offsite) exists
  specifically to prevent a single infrastructure-level disaster from
  destroying both the primary database and its backups at once.

---

## What's Next

Chapter 29 goes underneath everything covered so far — **Database
Internals**: how storage is actually organized on disk, how MVCC
(multi-version concurrency control) gives every transaction a consistent
snapshot without blocking readers against writers, the full mechanics of
WAL introduced briefly here, checkpointing, and vacuum/garbage collection.
Understanding these internals is what turns "I can restore a backup" into
"I understand exactly what state the engine was in when it needed one."
