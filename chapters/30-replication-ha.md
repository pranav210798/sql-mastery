# Chapter 30 — Replication & High Availability

> **Prerequisites:** This chapter assumes you've read [Chapter 28 — Backup &
> Recovery Concepts](28-backup-recovery.md) (RPO/RTO, backup types, and WAL
> archiving as a recovery mechanism) and [Chapter 29 — Database Internals
> (Storage, MVCC, WAL, Vacuum)](29-database-internals.md) (how the
> write-ahead log records every change before it touches the data files).
> This chapter does **not** re-derive WAL from first principles — it assumes
> you already know that every committed change exists first as a WAL record.
> What's new here is what happens when you ship that WAL record to *another
> server* continuously, in near-real time, rather than only archiving it for
> disaster recovery. Every example runs against `banking_db` from
> `databases/banking_db.sql`. Dialect: **PostgreSQL** primary, with
> **[MySQL]**, **[Oracle]**, and **[SQL Server]** call-outs wherever behavior
> diverges.

## Learning Objectives

By the end of this chapter you will be able to:

- Explain the primary/replica architecture and why nearly every production
  RDBMS deployment uses some form of it
- Compare streaming (physical/WAL) replication, binlog replication, logical
  replication, Oracle Data Guard, and SQL Server Always On Availability Groups
- Explain the real trade-off between synchronous and asynchronous replication
  in terms of durability, latency, and availability
- Define replication lag precisely, list its causes, and describe how to
  monitor it
- Define failover, distinguish manual from automatic failover, and explain
  exactly how split-brain happens and why fencing/quorum prevents it
- Connect an HA architecture's replication and failover choices back to
  Chapter 28's RPO/RTO framework, and reason about "nines" of availability
- Explain how client connections actually find the new primary after a
  failover — because a promotion nobody's traffic reaches isn't a completed
  failover
- Design a complete, justified HA architecture for a banking-grade system

---

## 30.1 Why Replication Exists

**Simple explanation:** Right now, `banking_db` lives on one server. If that
one server's disk fails, catches fire, or the data center loses power, the
bank loses its only copy of every customer's balance — and the bank cannot
process a single deposit, withdrawal, or transfer until someone finds a
backup and restores it, which could take hours. Replication is the practice
of keeping one or more *continuously updated, near-live copies* of the
database on other servers, so that if the primary server dies, a copy is
already sitting there, seconds behind, ready to take over.

**Technical explanation:** Replication designates one node as the
**primary** (also called the **leader** or **master**) that accepts all
writes, and one or more **replica** nodes (also called **followers**,
**standbys**, or **secondaries**) that receive a continuous stream of the
primary's changes and apply them to maintain an equivalent copy of the data.
The mechanism that carries those changes is exactly the write-ahead log you
studied in Chapter 29 — instead of (or in addition to) writing WAL segments
to local disk and later archiving them for point-in-time recovery (Chapter
28), the primary also ships those same WAL records over a network connection
to one or more replicas, which replay them as they arrive.

**Why it exists — three distinct problems, one mechanism:**

1. **Survive hardware/site failure.** A copy that's already running and
   nearly caught up can be promoted to take over writes in seconds to
   minutes, instead of the hours a full backup restore takes.
2. **Scale read-heavy workloads.** Read queries (report generation, balance
   lookups, statement views) can be pointed at replicas, freeing the primary
   to spend its capacity on writes.
3. **Enable near-zero-downtime maintenance.** You can patch, upgrade, or
   reboot a replica without taking the primary — and therefore the whole
   application — offline, then repeat the process on the primary after
   promoting a fully-caught-up replica.

> **Important Note:** Replication is not one feature — it is the load-bearing
> mechanism underneath *three* separate concerns: **durability against
> failure** (this chapter's main focus), **read scaling**, and **operational
> flexibility**. A single replica can serve all three purposes at once, but
> as you'll see in §30.4, a replica optimized purely for read-scaling
> (asynchronous, possibly lagging) is not automatically suitable as your
> failover target for zero-data-loss durability.

### The banking_db motivation, concretely

`banking_db.accounts.balance` is money. If the primary server hosting
`banking_db` fails at 2:14 PM with no replica, every one of Ravi Shankar's
(`customer_id = 1`) accounts is unreachable — no ATM withdrawal, no online
transfer, no merchant card swipe can be authorized — until a human restores
a backup, and *any* transaction committed after the last backup but before
the crash is at risk of being lost entirely (this is exactly Chapter 28's
**RPO** — Recovery Point Objective — problem, and how long the bank stays
down is the **RTO** — Recovery Time Objective — problem). Replication is how
a real bank buys back both numbers: a replica that's already up to date
(RPO near zero) and already running (RTO measured in seconds) turns a
multi-hour outage into a brief, often invisible, failover.

---

## 30.2 Primary/Replica Architecture

**Simple explanation:** One main database that all writes go to, plus one
or more copies that continuously receive updates. Applications write to the
main one; they can read from the main one or from the copies.

**Technical explanation:** A **primary** node accepts all `INSERT`,
`UPDATE`, `DELETE`, and DDL statements. Its WAL (or binlog, depending on
dialect) is streamed to each **replica**, which applies (replays) those
changes locally, in the same order they were committed on the primary, to
maintain a copy that is either byte-identical (physical replication) or
logically equivalent (logical replication) to the primary.

```text
                         ┌─────────────────────┐
                         │       PRIMARY        │
                         │   banking_db (RW)     │
                         │  accepts ALL writes   │
                         └──────────┬───────────┘
                       WAL stream   │   WAL stream
                 ┌──────────────────┼──────────────────┐
                 │                                      │
       ┌─────────▼──────────┐              ┌────────────▼─────────┐
       │      REPLICA 1      │              │      REPLICA 2         │
       │  banking_db (RO)     │              │  banking_db (RO)        │
       │  same-DC, sync        │              │  cross-region, async    │
       │  read queries OK      │              │  read queries OK         │
       └────────────────────┘              └───────────────────────┘

  Applications:
    writes  ──────────────────────────────► PRIMARY only
    reads   ──────────────────────────────► PRIMARY or any REPLICA
```

Every replica applies changes **in the same commit order** the primary
committed them (this ordering guarantee is what lets a replica ever be
"caught up" to a well-defined point rather than an inconsistent jumble).
Replicas are normally **read-only** — they reject writes, both to prevent
accidental divergence from the primary and because accepting a write on a
replica would have nowhere consistent to go once the primary's next WAL
record arrives.

### Why this exists

A single-writer design is what makes correctness tractable: if two nodes
could both accept writes to the same row independently, you would need a
conflict-resolution scheme for every possible collision (this is precisely
what makes true multi-primary/multi-master systems hard, and why most
production RDBMS deployments — Postgres, MySQL, Oracle, SQL Server — default
to single-writer primary/replica rather than multi-primary). Read-only
replicas sidestep that entire class of problem while still delivering
redundancy and read scale.

---

## 30.3 How the Change Stream Actually Moves: Dialect by Dialect

All four major RDBMSes implement the same conceptual pattern — ship a
change log, replay it elsewhere — but the mechanics and terminology differ
enough to be worth a side-by-side pass.

### **[PostgreSQL]** Streaming (physical) replication

The primary streams its actual WAL records — the same byte-for-byte log
described in Chapter 29 — over a replication connection to each standby.
The standby continuously replays those WAL records against its own copy of
the data files, applying changes at the physical page level. Because it's
physical, a streaming replica is a block-for-block copy of the primary; it
must run the same major PostgreSQL version and cannot have a different
schema or extra indexes from the primary.

```text
PRIMARY                                    STANDBY
 WAL writer -> WAL segment  ──streamed──►  walreceiver -> WAL replay
 (fsync'd on commit)                       (continuously applying)
```

### **[MySQL]** Binlog replication — statement-based vs. row-based vs. mixed

MySQL ships a separate log, the **binary log (binlog)**, rather than its
InnoDB redo log. Historically there were two philosophies for what the
binlog records:

- **Statement-based replication (SBR):** the binlog records the literal SQL
  statement that ran (e.g., `UPDATE accounts SET balance = balance - 100
  WHERE account_id = 4`), and the replica re-executes that statement itself.
  This is compact, but dangerous: any statement containing a
  **non-deterministic** expression — `NOW()`, `RAND()`, `UUID()`,
  auto-increment values under some conditions — can produce a *different*
  result when re-executed on the replica at a slightly later time, silently
  causing the replica's data to diverge from the primary's.
- **Row-based replication (RBR):** the binlog records the actual **resulting
  row changes** (the before/after row images) rather than the statement
  text. The replica applies those exact row values instead of re-running
  any logic, so non-determinism on the primary can never cause divergence
  on the replica. This is safer and has been the default since MySQL 5.7+.
- **Mixed:** MySQL chooses statement-based by default and automatically
  switches to row-based for statements it determines are unsafe.

> **Why this matters for banking_db:** imagine a (hypothetical MySQL port
> of) `banking_db` with a trigger or default that stamps
> `transaction_date = NOW()`. Under statement-based replication, the
> replica could apply the same statement a few milliseconds later and record
> a *different* timestamp than the primary — a subtle but real audit-trail
> inconsistency. Row-based replication ships the already-computed value, so
> both copies agree exactly.

### **[Oracle]** Data Guard — physical standby vs. logical standby

Oracle's Data Guard offers two standby types:

- **Physical standby:** applies redo (Oracle's equivalent of WAL) at the
  block level — conceptually the same mechanism as PostgreSQL streaming
  replication. The standby is byte-identical to the primary.
- **Logical standby:** mines the redo stream, converts it into equivalent
  SQL, and applies that SQL — conceptually similar to logical/row-based
  replication. Because it applies actual SQL rather than raw blocks, a
  logical standby can have a different physical layout (extra indexes,
  materialized views) and can even remain open for read/write access to
  non-replicated objects while replicating the rest.

### **[SQL Server]** Always On Availability Groups

Built on top of **Windows Server Failover Clustering (WSFC)** for cluster
membership and quorum, an Availability Group ships transaction log records
to one or more **secondary replicas**, each of which can be configured for
**synchronous-commit** or **asynchronous-commit** mode independently. AGs
bundle failover orchestration (via WSFC) directly into the feature, which is
notably more turnkey than assembling Patroni or Orchestrator yourself (more
in §30.7).

### Side by side

| | Log shipped | Granularity | Cross-version? | Default safety |
|---|---|---|---|---|
| **[PostgreSQL]** Streaming replication | WAL | Physical (block-level) | No — same major version | N/A (always physically exact) |
| **[PostgreSQL]** Logical replication | Decoded WAL → row changes | Logical (row-level) | Yes | N/A (row-level by nature) |
| **[MySQL]** Binlog (statement-based) | SQL statement text | Statement | Yes | Unsafe with non-deterministic functions |
| **[MySQL]** Binlog (row-based) | Before/after row images | Row-level | Yes | Safe — the modern default |
| **[Oracle]** Data Guard physical standby | Redo | Physical (block-level) | No — same version/platform family | N/A |
| **[Oracle]** Data Guard logical standby | Redo mined into SQL | Logical (row-level) | Partial | Depends on SQL Apply support for the object type |
| **[SQL Server]** Always On AG | Transaction log records | Physical | No — same version | Depends on sync/async mode per replica |

---

## 30.4 Read Replicas

**Simple explanation:** If most of what your application does is *read*
data (show a balance, list recent transactions, generate a report), you can
point those reads at a replica instead of the primary, leaving the primary's
capacity free for the writes only it can do. It's like having several
tellers who can show you your balance, but only one vault that actually
moves the money.

**Technical explanation:** A read replica is a standby whose purpose is
serving `SELECT` traffic. Applications route write statements
(`INSERT`/`UPDATE`/`DELETE`) to the primary and route read statements to
one or more replicas, typically via a connection-routing layer (§30.9) or
application-level logic (e.g., a "read" datasource vs. a "write" datasource
in the app's configuration).

```text
                         Write traffic
     App  ───────────────────────────────────►  PRIMARY
      │
      │    Read traffic (SELECT reports,
      │    statement history, balance checks)
      └──────────────────────────────► REPLICA 1, REPLICA 2, REPLICA 3
```

### Why this exists

Reads and writes compete for the same finite resources — CPU, memory,
buffer cache, I/O bandwidth — on a single server. `banking_db` under real
load might run thousands of statement-history queries per minute alongside
a much smaller number of actual transfers; letting the read traffic pile
onto replicas keeps the primary responsive for the transfers that actually
must not be delayed.

### The real complication: replication lag and "read your own write"

Because replication is not instantaneous (§30.6), a read replica's data is
always *slightly behind* the primary. This is invisible for most reporting
queries, but it becomes a real correctness problem for **read-your-own-write**
scenarios.

**Banking_db scenario:** Neha Agarwal (`customer_id = 2`) transfers ₹10,000
from her savings account (`account_id = 3`) to Ravi's current account. Her
app writes this transfer to the primary — `transactions` gets a
`TRANSFER_OUT` row and `accounts.balance` is decremented — and the primary
confirms the commit. Neha's app immediately redirects her to a "My Accounts"
page, and that page's balance query happens to be routed to a read replica
that has not yet replayed the transfer's WAL record. Neha sees her **old,
pre-transfer balance** for a brief window (typically milliseconds to a few
seconds, but potentially longer under lag) even though the bank's own
primary has already durably recorded the debit. She may reasonably (and
alarmingly) conclude the transfer failed and attempt it again.

```sql
-- Written to the PRIMARY and committed:
UPDATE banking_db.accounts SET balance = balance - 10000 WHERE account_id = 3;
INSERT INTO banking_db.transactions (account_id, transaction_type, amount, related_account_id, description)
VALUES (3, 'TRANSFER_OUT', 10000.00, 1, 'Transfer to Ravi');

-- Milliseconds later, read from a REPLICA that hasn't caught up yet:
SELECT balance FROM banking_db.accounts WHERE account_id = 3;
-- returns the OLD balance — the transfer's WAL record hasn't replayed here yet
```

### Expected behavior and mitigations

- Route any query that must reflect the user's own just-completed write back
  to the **primary** for a short window after the write (common pattern:
  "read-after-write consistency" via session affinity to the primary, or a
  session variable the app sets after a write).
- **[PostgreSQL]** applications can check `pg_last_wal_replay_lsn()` on the
  replica against the LSN returned by the write, and fall back to the
  primary if the replica hasn't caught up.
- Some connection poolers/proxies support **causal reads**: the client
  supplies the LSN/GTID of its last write, and the proxy only routes the
  read to a replica that has confirmed it has replayed at least that point.
- For account balances specifically — the single most safety-critical read
  in a bank — many real systems simply **always** read balance from the
  primary and only send secondary data (transaction history older than a
  few minutes, statements, analytics) to replicas.

---

## 30.5 Synchronous vs. Asynchronous Replication

This is the single most consequential trade-off in replication design, and
the one the chapter challenge (§30.16) will ask you to justify explicitly
for `banking_db`.

### Precise definitions

- **Asynchronous replication:** the primary commits a transaction and
  returns success **to the client** as soon as the change is durable on the
  primary alone — it does not wait for any replica to receive or apply the
  corresponding WAL. The replica catches up whenever it can.
- **Synchronous replication:** the primary waits for **at least one
  replica** to confirm it has received (and, depending on configuration,
  applied) the WAL for a transaction *before* the primary reports that
  transaction as committed to the client. The client's "commit succeeded"
  response is delayed until that confirmation arrives.

```text
ASYNCHRONOUS                              SYNCHRONOUS
Client            Primary    Replica      Client            Primary    Replica
  │  COMMIT          │                      │  COMMIT          │
  ├─────────────────►│                      ├─────────────────►│
  │                  │──WAL──────────►│     │                  │──WAL──────────►│
  │◄── "committed" ──┤    (in flight)  │     │                  │            (received)
  │   (fast)         │                 │     │                  │◄── ACK ────────┤
  │                  │                 │     │◄── "committed" ──┤   (waits for ACK)
  │                  │                 │     │   (slower)       │
```

### Why each exists / the trade-off, precisely

| | Asynchronous | Synchronous |
|---|---|---|
| **Durability guarantee** | If the primary crashes immediately after commit, any transaction whose WAL hadn't yet reached a replica is **lost** — the client was told "committed" but the data may not exist anywhere else | Zero data loss on primary failure — a confirmed commit is guaranteed to exist on at least one replica |
| **Write latency** | Lower — commit returns as soon as the primary's own local durability is satisfied | Higher — every commit pays the round-trip time to at least one replica |
| **Availability impact** | A replica outage never blocks writes on the primary | Depending on configuration, if the required synchronous replica(s) become unreachable, writes on the primary can **stall** until a standby is available again (or until failed over to async, if configured to degrade) |
| **Best fit** | Read-scaling replicas, cross-region DR copies, high-throughput workloads that can tolerate a small loss window | The single most safety-critical write path — e.g., a bank's core ledger — where losing a confirmed transaction is unacceptable |

> **⚠️ Warning:** "Synchronous" does not automatically mean "zero risk of
> blocking." If your only synchronous replica goes down and your
> configuration requires a synchronous ACK before committing, **new writes
> on the primary will hang** until the replica returns or you reconfigure
> which node is required. This is a deliberate trade: you are choosing to
> sacrifice availability of writes to guarantee you never silently lose one.
> Whether that's the right trade depends entirely on the workload — for
> `banking_db`'s ledger, it usually is; for a comments feed, it usually
> isn't.

### **[PostgreSQL]** `synchronous_standby_names` and `synchronous_commit`

PostgreSQL controls this with two settings working together:

- `synchronous_standby_names` on the primary names which replica(s) are
  eligible to act as the synchronous standby (by application name), and how
  many must acknowledge (e.g., `'1 (replica_dc1, replica_dc2)'` means "any
  one of these two must ACK"). If this is empty, all replication is
  asynchronous.
- `synchronous_commit` controls **what** the primary waits for before
  telling the client "committed": common levels include `off` (don't even
  wait for local WAL flush — fastest, riskiest), `local` (wait for the
  primary's own WAL flush only — this is effectively async replication),
  `remote_write` (wait until the standby has *written* the WAL, but not
  necessarily flushed it to its own disk), and `on`/`remote_apply` (wait
  until the standby has flushed, or even fully replayed, the WAL) —
  progressively stronger guarantees at progressively higher latency cost.

```sql
-- [PostgreSQL] conceptual primary configuration for a
-- same-datacenter synchronous replica protecting the ledger:
-- synchronous_standby_names = '1 (banking_replica_dc1)'
-- synchronous_commit = on
```

### **[MySQL]** Semi-synchronous replication — the middle ground

MySQL's **semi-synchronous replication** waits for at least one replica to
**acknowledge receipt** of the transaction's binlog event (it has been
written to the replica's relay log) — but *not* necessarily that the
replica has finished **applying** it. This is a deliberate middle ground:
stronger than pure async (a crash on the primary right after commit doesn't
lose data that already reached a replica's relay log) but cheaper than
waiting for full apply, since applying can take noticeably longer than
receiving under heavy replica load.

### **[SQL Server]** and **[Oracle]** equivalents

Always On Availability Groups let you mark each secondary replica as
**synchronous-commit** or **asynchronous-commit** mode individually; Data
Guard offers **Maximum Availability**, **Maximum Performance**, and **Maximum
Protection** protection modes that map onto the same synchronous/async
spectrum (Maximum Protection is the strictest — it will actually shut the
primary database down rather than risk a transaction with no synchronously
confirmed standby, the most extreme expression of "durability over
availability").

---

## 30.6 Replication Lag

**Simple explanation:** Replication lag is how far behind a replica's copy
of the data is compared to the primary, measured in time (or occasionally
in bytes of WAL not yet applied).

**Technical explanation:** Replication lag is the delay between a write
**committing on the primary** and that same write becoming **visible on a
given replica** (i.e., replayed and queryable there). It's a per-replica
number — one replica can be milliseconds behind while another, further away
or more heavily loaded, is minutes behind.

### Causes

1. **Network latency** — the WAL/binlog has to physically travel to the
   replica; a cross-region replica (e.g., a disaster-recovery copy in
   another city) will structurally lag more than a same-datacenter one no
   matter how fast its hardware is.
2. **Replica under heavy read load** — if the replica is busy serving
   read-scaling `SELECT` traffic (§30.4), the CPU/I/O it needs to *apply*
   incoming WAL competes with the CPU/I/O the read queries are consuming.
3. **A single-threaded replication apply process unable to keep up** — a
   highly parallel primary can accept many concurrent writers, but older
   replication designs replayed WAL/binlog with a **single apply thread**,
   creating a bottleneck: the replica falls further behind the busier the
   primary gets. Modern versions address this directly — PostgreSQL's
   logical replication and MySQL's multi-threaded/parallel replica apply
   (parallelizing by schema, table, or write-set dependency) narrow this gap
   substantially, though a single hot table with heavy write contention can
   still serialize apply.

### Monitoring lag, conceptually

Lag is measured by comparing a position marker on the primary against the
same kind of marker on the replica:

- **[PostgreSQL]** compare `pg_current_wal_lsn()` on the primary against
  `pg_last_wal_replay_lsn()` on the replica (a byte-position/LSN
  comparison), or simply query `pg_stat_replication` on the primary, which
  reports `write_lag`, `flush_lag`, and `replay_lag` as time intervals
  directly.
- **[MySQL]** `SHOW REPLICA STATUS` reports `Seconds_Behind_Source`
  (formerly `Seconds_Behind_Master`), an approximate time-based lag metric.
- **[Oracle]** Data Guard reports **apply lag** and **transport lag**
  separately via `V$DATAGUARD_STATS`.
- **[SQL Server]** Always On dashboards expose **Redo Queue Size** and an
  estimated **Recovery Time** per secondary.

```sql
-- [PostgreSQL] on the PRIMARY: see every connected replica's lag
SELECT application_name, client_addr,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

> **Important Note:** Lag is not a single fixed number for a deployment —
> it's a live, fluctuating metric that should be **alerted on**, not just
> glanced at. A replica that is your designated synchronous failover
> candidate falling behind should page someone; a read-scaling replica
> quietly lagging a few hundred milliseconds during a traffic spike usually
> shouldn't.

---

## 30.7 Failover

**Simple explanation:** Failover is promoting one of the copies to become
the new "main" database when the original main database fails, so the
system can keep accepting writes.

**Technical explanation:** Failover is the process of **promoting a
replica to primary role** — it stops applying incoming WAL/binlog and
starts accepting write traffic directly — after the original primary
becomes unavailable (or is being deliberately taken offline for
maintenance, in which case it's usually called a **switchover** rather than
a failover, since it's planned and both nodes cooperate).

### Manual vs. automatic failover

| | Manual failover | Automatic failover |
|---|---|---|
| **Who decides** | A human, after confirming the primary is actually down | Orchestration software (Patroni, Orchestrator, WSFC, Data Guard Broker), based on health checks |
| **Speed** | Minutes at best — someone has to notice, confirm, and act, often at 3 AM | Seconds to low minutes |
| **Risk of a wrong call** | Lower — a human can confirm "the primary really is dead" rather than "the primary is just slow/network-partitioned" before acting | Higher unless the tooling uses proper quorum/fencing (see below) — an automated system can be fooled by a network partition into promoting a replica while the "dead" primary is actually still alive and serving traffic |
| **Typical use** | Smaller deployments, or as a deliberate safety choice for the most sensitive systems | Systems where RTO requirements are too tight for a human in the loop |

### Split-brain: how it actually happens

**Split-brain** is the failure mode where **two nodes simultaneously
believe they are the primary** and both accept writes independently,
causing the data to diverge in ways that cannot be automatically
reconciled.

Here's precisely how it happens: suppose `banking_db`'s primary and its
automatic-failover orchestrator lose network connectivity to each other —
not because the primary crashed, but because of a network partition (a
switch failure, a firewall misconfiguration, a fiber cut). From the
orchestrator's point of view, the primary is unreachable, indistinguishable
from "the primary is dead." The orchestrator, trying to protect
availability, promotes a replica to be the new primary. But the *original*
primary never actually crashed — it's still running, still has its disk,
and — critically — if nothing physically stops it, it will keep accepting
writes from any client that can still reach it (e.g., clients on the same
side of the network partition as the old primary).

```text
                     NETWORK PARTITION
   ┌──────────────────────┐  ╳╳╳╳╳╳╳╳  ┌──────────────────────┐
   │   OLD PRIMARY          │  ╳    ╳   │   ORCHESTRATOR          │
   │  (still running,       │  ╳    ╳   │  "I can't reach the      │
   │   still accepts        │  ╳    ╳   │   primary — promoting     │
   │   writes from any       │  ╳    ╳   │   Replica 1!"             │
   │   client that can        │  ╳    ╳   └──────────┬────────────┘
   │   still reach it)         │  ╳╳╳╳╳╳╳╳             │ promote
   └───────────┬─────────┘                       ┌───────▼───────┐
               │ writes                          │   REPLICA 1     │
               ▼                                 │  (NEW PRIMARY)   │
   accounts.balance = X                          │  accepts writes  │
        (diverging)                              └───────┬────────┘
                                                          │ writes
                                                          ▼
                                              accounts.balance = Y
                                                (diverging further)

   Result: TWO "primaries" both accepting writes to banking_db.
   Ravi's balance is now X on one node and Y on the other, with
   no clean way to know which transactions are "real."
```

For `banking_db`, this is catastrophic in a very concrete way: if the old
primary keeps accepting a withdrawal from `account_id = 4` while the newly
promoted node concurrently accepts a *different* withdrawal from the same
account, both succeed independently, both decrement a balance that the
other node knows nothing about, and the bank now has two histories of
`account_id = 4` that cannot be merged without manually deciding which
withdrawals actually happened and in what order — a reconciliation nightmare
that can mean either double-honoring a withdrawal or losing a legitimate
one.

### Why fencing/quorum prevents it

The fix is to make promotion require **proof that the old primary cannot
still be accepting writes**, not just "I can't currently reach it." Two
complementary mechanisms:

- **Fencing (STONITH — "Shoot The Other Node In The Head"):** before or as
  part of promoting a replica, the orchestration system forcibly cuts off
  the old primary's ability to accept writes or serve clients — powering it
  off, revoking its network access, or blocking it at a proxy layer —
  *before* traffic is redirected to the new primary. This guarantees at
  most one node can be accepting writes at any moment.
- **Quorum:** rather than letting any single orchestrator node (which
  might itself be on the wrong side of a partition) unilaterally decide to
  promote, a **majority** of an odd-sized set of independent observers must
  agree the primary is actually down before a promotion proceeds. This is
  exactly what a distributed consensus layer (etcd/Consul for Patroni,
  Windows Server Failover Clustering's quorum for Always On AGs) provides —
  it prevents a promotion decision from being made by a minority partition
  that has itself lost visibility of the majority of the cluster.

> **⚠️ Warning — split-brain risk:** never build "automatic failover" out of
> a naive health check ("if I can't ping the primary for 5 seconds, promote
> a replica") without a fencing or quorum mechanism behind it. That naive
> design is a split-brain generator, not an HA solution — it trades a
> availability problem (primary down) for a worse correctness problem
> (two primaries, diverging data) under the exact failure mode — network
> partitions — that HA is supposed to survive.

### Tooling: coordinate promotion, don't do it by hand under pressure

| Dialect | Common orchestration tooling | What it adds over "just promote a replica manually" |
|---|---|---|
| **[PostgreSQL]** | Patroni, repmgr | Health-check consensus (via etcd/Consul/ZooKeeper for Patroni), automatic fencing of the old primary, automatic client redirection hooks |
| **[MySQL]** | Orchestrator, Group Replication | Topology-aware automatic failover with detection of split-brain risk before promoting; Group Replication adds built-in consensus (Paxos-based) across the group itself |
| **[SQL Server]** | Always On Availability Groups | Automatic failover is a first-class built-in feature, using WSFC quorum for consensus, no separate tool needed |
| **[Oracle]** | Data Guard Fast-Start Failover (FSFO) | An Observer process monitors both primary and standby and can trigger fully automatic, pre-validated failover without manual intervention, while enforcing configured data-loss limits |

The unifying lesson: **manual, improvised failover under real incident
pressure is exactly when mistakes compound** — a tired on-call engineer
promoting the wrong replica, forgetting to fence the old primary, or
pointing the connection string at the wrong host. Orchestration tooling
exists to make the *safe* sequence (confirm quorum, fence the old primary,
promote the right replica, redirect clients) the *only* sequence that's
possible, rather than a checklist a human has to execute correctly at 3 AM.

---

## 30.8 High Availability as a Broader Concept

**Simple explanation:** High availability means the system keeps working —
at an acceptable level — even when individual pieces of it break.

**Technical explanation:** **High availability (HA)** is a system property,
not a single feature: it means the overall service continues operating,
within an acceptable service level, despite the failure of individual
components (a disk, a server, a network link, a data center). Replication
and failover (this chapter) are the primary *mechanism* for achieving HA in
a database tier specifically, but HA as a discipline also covers redundant
networking, redundant power, and application-tier statelessness — this
chapter focuses on the database piece.

### Direct connection to Chapter 28's RPO/RTO framework

Every choice in this chapter is, in effect, a dial that sets your
achievable RPO and RTO:

- **Synchronous replication** → RPO ≈ 0 (a confirmed transaction is
  guaranteed to exist on a replica), at the cost of write latency and
  potential write availability during a standby outage.
- **Asynchronous replication** → RPO = however much data can be in flight
  and unreplicated at the moment of failure (bounded by your current
  replication lag, §30.6) — nonzero, but usually small if lag is healthy.
- **Automatic failover with fencing** → RTO measured in seconds to low
  minutes.
- **Manual failover** → RTO measured in the time it takes a human to notice,
  confirm, and act — typically many minutes to hours.

A bank's ledger, by this framework, wants **RPO ≈ 0** (synchronous
replication to at least one standby) and **low RTO** (automatic,
fenced failover) — the chapter challenge in §30.16 asks you to state these
numbers explicitly for a concrete design.

### "Nines" of availability

Availability targets are conventionally expressed as a percentage of time
the system is required to be up over a year, informally called "the nines."
Each additional nine is an order-of-magnitude tighter downtime budget:

| Availability | Nickname | Downtime per year | Downtime per month | Downtime per day |
|---|---|---|---|---|
| 99% | "two nines" | ~3.65 days | ~7.3 hours | ~14.4 minutes |
| 99.9% | "three nines" | ~8.76 hours | ~43.8 minutes | ~1.44 minutes |
| 99.95% | "three and a half nines" | ~4.38 hours | ~21.9 minutes | ~43.2 seconds |
| 99.99% | "four nines" | ~52.6 minutes | ~4.38 minutes | ~8.64 seconds |
| 99.999% | "five nines" | ~5.26 minutes | ~26.3 seconds | ~0.86 seconds |

> **Important Note:** "Five nines" (≈5 minutes of downtime a year, total)
> essentially rules out **manual** failover as a strategy on its own — a
> human noticing, confirming, and acting can easily burn the entire annual
> budget on a single incident. Targets at that level require automatic,
> fenced failover (§30.7) and usually multiple redundant standbys, because
> the budget has to absorb not just planned maintenance but every
> unplanned failure combined, for the whole year.

---

## 30.9 Connection Routing: Getting Clients to the New Primary

**Simple explanation:** Promoting a replica to be the new primary doesn't
help anybody if the application is still sending write traffic to the old
server's address. Failover isn't done until the traffic actually moves.

**Technical explanation:** After a promotion, clients need a way to
discover which node is *currently* the writable primary — and that
mechanism has to work correctly even though the "currently correct answer"
just changed. Three common approaches:

1. **A virtual IP (VIP) that moves.** A single IP address is configured to
   always route to whichever node is currently primary; the failover
   process reassigns the VIP to the newly promoted node (or updates a
   DNS/ARP entry) as part of promotion. Simple, but the VIP mechanism
   itself becomes a single point that must be correctly re-pointed — and
   during a network partition, care is needed to ensure only the *fenced,
   confirmed* primary ever holds the VIP (tying directly back to §30.7's
   split-brain concern).
2. **A topology-aware proxy/load-balancer layer.** **[PostgreSQL]**
   PgBouncer paired with HAProxy, or pgpool-II, sits between the
   application and the database cluster, continuously tracks which node is
   currently primary (often by querying each node's role, or integrating
   with Patroni's REST API), and transparently routes write connections to
   whichever node currently holds that role — the application always
   connects to the proxy's fixed address and never needs to know which
   physical host is primary at any given moment.
3. **Driver-level multi-host connection strings.** Several dialects/drivers
   now support connection strings that list multiple candidate hosts and
   probe them to find the one that's currently writable, without any
   external proxy:

```text
-- [PostgreSQL] libpq multi-host connection string with target_session_attrs:
postgresql://app_user@host1,host2,host3:5432/banking_db?target_session_attrs=read-write
-- the driver tries each host in order and connects to whichever one
-- currently accepts read-write transactions
```

### The operational requirement, stated precisely

> **Important Note:** A failover is not complete when a replica has been
> successfully promoted — it is complete only when **client write traffic
> is actually reaching the new primary**. A promotion that succeeds while
> every application server still holds open connections (or a cached DNS
> entry, or a hardcoded IP) pointed at the old host has not restored
> service; it has only *prepared* the new host to receive traffic that
> isn't arriving yet. Real HA runbooks and orchestration tooling always
> include the connection-routing step as part of the failover procedure
> itself, not as an afterthought — and testing failover (§30.10) must
> verify this end-to-end, not just check that the new primary accepts
> `psql` connections from the ops laptop.

---

## 30.10 Logical Replication (Brief)

**Simple explanation:** Instead of copying the database byte-for-byte,
logical replication copies the *meaning* of each change — "this row was
inserted/updated/deleted with these values" — which is more flexible about
where and how it can be applied.

**Technical explanation:** **[PostgreSQL]** Logical replication decodes the
WAL into a stream of logical row-change events (insert/update/delete plus
the affected row values) rather than shipping raw physical WAL pages. This
independence from the physical WAL format is what enables capabilities
physical streaming replication cannot offer:

- Replicating between **different major versions** of PostgreSQL (useful
  for a near-zero-downtime major-version upgrade: bring up a logical replica
  on the new version, let it catch up, then cut over).
- Replicating only a **subset of tables** (e.g., replicate `banking_db.accounts`
  and `banking_db.transactions` to an analytics warehouse without
  replicating `audit_log`).
- A target that isn't purely read-only/passive — because it's logical row
  changes, not physical pages, the target can have different indexes or
  even receive its own independent writes to non-replicated tables.

**[MySQL]** row-based binlog replication is used for the same class of
purpose — selective/version-flexible replication — since it already ships
row-level change data rather than physical pages.

This is a deliberately brief treatment: logical replication for
version upgrades, selective replication, and change-data-capture pipelines
is developed in depth in Chapter 31 alongside other advanced patterns; this
chapter's job is only to make sure you can place it correctly relative to
physical/streaming replication.

---

## 30.11 Common Mistakes

> **⚠️ Warning — a replica is not a backup.** This is the single most
> important operational mistake to internalize from this chapter. A
> mistaken statement on the primary —
> `DELETE FROM banking_db.transactions WHERE account_id = 4;` run without a
> `WHERE` clause narrow enough, or a bad migration that drops a column —
> **replicates to every replica just as faithfully as a legitimate
> transaction does**, usually within milliseconds. A replica protects you
> from *hardware* failure; it does nothing to protect you from *logical*
> mistakes, because it is designed to copy exactly what happened on the
> primary, mistakes included. The actual protection against a bad `DELETE`
> is Chapter 28's real backup strategy — point-in-time recovery from WAL
> archives, or a periodic full/incremental backup — which lets you restore
> to a moment *before* the mistake, something no replica (by design) can
> ever do.

Other recurring mistakes:

- **Never testing failover until a real emergency.** A failover procedure
  that has only ever been read, never rehearsed, reliably breaks in some
  small way the first time it's run for real — a stale runbook step, a
  connection string nobody updated, a fencing script with a typo. Regular,
  scheduled failover drills (ideally including the connection-routing step
  from §30.9) are what make an incident-time failover boring instead of
  terrifying.
- **Ignoring replication lag when reads must be strongly consistent.**
  Routing a "read your own write" query (§30.4) — or worse, a
  regulatory/compliance report that must reflect exact-as-of-now state — to
  a replica without accounting for lag produces silently wrong answers, not
  errors. There's no exception thrown; the query just returns a slightly
  stale (or, under bad lag, very stale) truth.
- **Treating "synchronous" as a single on/off switch.** As §30.5 covered,
  synchronous replication has gradations (`remote_write` vs. `on` vs.
  `remote_apply` in PostgreSQL terms) — assuming "synchronous" always means
  "the standby has fully applied the change" when it only means "received
  it" can lead to reading stale data from a "synchronous" replica
  immediately after a failover.
- **Building automatic failover without fencing/quorum**, as covered in
  depth in §30.7 — worth repeating here because it's the mistake with the
  worst possible outcome (split-brain data corruption) for the least
  amount of extra engineering saved.

---

## 30.12 Edge Cases

- **A replica falls too far behind and needs to be rebuilt from scratch.**
  Every primary retains WAL/binlog only for a limited window (governed by
  disk space, `wal_keep_size`/replication slots in PostgreSQL, or binlog
  expiration in MySQL). If a replica is disconnected long enough (a
  prolonged network outage, a paused server) that the primary has already
  recycled the WAL segments the replica still needs, the replica cannot
  simply "catch up" — it is missing history it can never retrieve
  incrementally. The only fix is to **re-provision it from a fresh base
  backup** of the current primary and let it start streaming from that new
  baseline. **[PostgreSQL]** replication slots exist specifically to
  prevent this by telling the primary "don't recycle WAL this replica still
  needs" — at the cost of risking the primary's disk filling up if a slotted
  replica disconnects and is never reconnected or dropped.
- **Network partitions.** Covered in depth in §30.7 as the root cause of
  split-brain — but even without a failover being triggered, a partition
  that merely isolates a replica (without anyone promoting it) simply
  produces an increasingly lagging, eventually stale, read replica until
  connectivity restores and it replays its backlog.
- **A synchronous replica that becomes unreachable.** Depending on
  configuration, this can either (a) cause the primary to block new writes
  until the replica returns or the requirement is relaxed, or (b) if
  configured with a fallback list of acceptable synchronous standbys,
  transparently promote a different standby into the synchronous role. This
  distinction must be a deliberate configuration decision, not an
  accident discovered during an actual outage.

---

## 30.13 Choosing Synchronous vs. Asynchronous — Decision Framework

| Workload characteristic | Lean synchronous | Lean asynchronous |
|---|---|---|
| Cost of losing the most recent transaction(s) | Unacceptable (money, legal/compliance records) | Tolerable (a like/view count, a cached recommendation) |
| Write latency sensitivity | Can absorb the added round-trip cost | Needs the lowest possible write latency |
| Replica location | Same datacenter / low-latency link available | Cross-region, where round-trip time would make sync impractical |
| Example from this course | `banking_db.transactions` / `accounts.balance` — the core ledger | A read-heavy content site's page-view analytics, or a cross-region DR copy of `banking_db` itself |

A single deployment can — and, for a system like `banking_db`, typically
should — use **both at once**: one synchronous replica nearby for
zero-data-loss failover, and one or more asynchronous replicas further away
for read-scaling and geographic disaster recovery. This exact combination
is what the chapter challenge asks you to design.

---

## 30.14 Real-World Use Cases

- **Read scaling:** an e-commerce or content platform routes its heavy
  catalog/browse `SELECT` traffic to a fleet of read replicas, keeping the
  primary free for checkout writes — directly analogous to `banking_db`
  routing statement-history queries away from the primary in §30.4.
- **Zero-downtime failover for maintenance:** patch or upgrade a replica,
  confirm it's healthy and caught up, promote it (a planned switchover),
  then patch the old primary (now a replica) at leisure — no maintenance
  window visible to users.
- **Geographic distribution / disaster recovery sites:** an asynchronous
  replica in a different city or cloud region protects against an entire
  data center becoming unavailable (fire, regional power outage, natural
  disaster) — the scenario Chapter 28's disaster-recovery planning and this
  chapter's replication mechanics directly combine to solve.
- **Regulatory/compliance reporting** run against a dedicated replica so
  large, long-running analytical queries never compete with (or risk
  locking against) the live transactional workload on the primary.

---

## 30.15 Practice Questions

1. In your own words, explain why replicas are normally read-only rather
   than allowing writes on every node.
2. What specifically does PostgreSQL's streaming replication ship over the
   wire, and why does that make a streaming replica unable to run a
   different major version than its primary?
3. **[MySQL]** Explain precisely why statement-based replication can cause
   a replica's data to diverge from the primary's when a statement uses
   `NOW()`, and why row-based replication doesn't have that problem.
4. A `banking_db` customer transfers money and, on the very next page load,
   sees their old balance. Using the concepts in this chapter, explain
   exactly what happened and name two ways an engineering team could fix it.
5. Define synchronous and asynchronous replication precisely, in terms of
   what the primary waits for before reporting a commit to the client.
6. **[MySQL]** What does semi-synchronous replication guarantee that pure
   asynchronous replication does not, and what does it stop short of
   guaranteeing compared to fully synchronous, apply-confirmed replication?
7. Define replication lag precisely, and list three distinct causes of it.
8. Describe, step by step, exactly how a split-brain scenario can occur
   during a network partition, and explain what role fencing and quorum
   each play in preventing it.
9. Why is "the replica has been promoted" not sufficient, on its own, to
   say a failover is complete? What else has to happen?
10. A team argues that their nightly replica is "basically a backup," so
    they don't need a separate backup strategy. Explain precisely why
    they're wrong, using a concrete failure scenario.
11. Using the "nines" table in §30.8, explain why a 99.999% availability
    target effectively requires automatic rather than manual failover.
12. **[Oracle]** What is the practical difference between a physical
    standby and a logical standby in Data Guard, and when would you choose
    one over the other?
13. Why does a replica falling far enough behind sometimes require a full
    rebuild rather than simply "catching up," and what PostgreSQL feature
    exists specifically to try to prevent that situation?

---

## 30.16 Chapter Challenge — Design a Complete HA Architecture for banking_db

`banking_db` currently runs on a single PostgreSQL server with no
replication. The bank's leadership has told you: "This system cannot
tolerate long downtime, and it absolutely cannot silently lose a completed
transfer." Design a complete high-availability architecture, and justify
every choice using the concepts from this chapter (and, where relevant,
Chapter 28's RPO/RTO framework).

Your design must specify and justify:

1. **Replica count and placement.** Propose a specific topology — for
   example, one synchronous replica in the same datacenter (for zero-data-loss
   failover) plus one asynchronous replica in a different region (for
   disaster recovery against a full-site loss). Justify why *this* mix, and
   not (for example) two synchronous replicas, or zero asynchronous
   replicas.
2. **Synchronous vs. asynchronous choice, per replica.** State which
   replica(s) are synchronous and which are asynchronous, and justify each
   choice against §30.5's trade-offs and §30.13's decision framework, using
   `banking_db.accounts`/`transactions` specifically (not a generic
   argument).
3. **The `synchronous_commit` level** **[PostgreSQL]** you'd choose for the
   synchronous replica (`remote_write`, `on`, or `remote_apply`), and why.
4. **Failover mechanism.** Choose manual or automatic failover (or a hybrid
   — e.g., automatic detection with a human confirmation gate for the most
   destructive step), name the class of tooling you'd use (e.g., Patroni
   with a consensus store), and explain specifically how your design avoids
   split-brain (what provides fencing, what provides quorum).
5. **Connection routing.** State how application servers will discover the
   new primary after a failover, and confirm your design doesn't have a
   step where promotion succeeds but traffic doesn't move.
6. **Resulting RPO and RTO.** State concrete numbers (e.g., "RPO ≈ 0 for
   transactions that reached the synchronous replica; RPO up to N seconds
   of replication lag for the cross-region async replica in a full primary
   failure; RTO ≈ M seconds/minutes given automatic fenced failover") and
   justify why these numbers meet "this cannot tolerate long downtime or
   data loss."
7. **What you are explicitly NOT solving with this design**, and what
   still needs a separate answer — specifically, restate why this
   replication design does not replace Chapter 28's backup strategy, and
   name the one concrete failure mode (a mistaken `DELETE`/`UPDATE` on the
   primary) that only a real backup, not a replica, can recover from.

There is no single "correct" topology — grade your own answer by whether
every choice is justified against a specific trade-off from this chapter,
using `banking_db`'s actual tables and the bank's stated requirements,
rather than left as an unsupported assertion.

---

## Key Takeaways

- Replication keeps one or more continuously updated copies of the database
  on separate servers by streaming the primary's WAL/binlog and replaying
  it — the same change-logging mechanism from Chapter 29, extended across a
  network rather than only archived locally as in Chapter 28.
- **Streaming (physical) replication** ships raw WAL/redo and produces a
  block-identical copy, same-version only; **logical replication** ships
  decoded row changes, enabling cross-version and selective-table
  replication; **[MySQL]** row-based binlog replication is safer than
  statement-based because it ships actual row results instead of
  re-executable (and potentially non-deterministic) SQL text.
- **Read replicas** scale read-heavy workloads but introduce **replication
  lag**, which can cause read-your-own-write staleness — a real
  correctness hazard for something as sensitive as a just-completed bank
  transfer.
- **Synchronous replication** trades write latency (and potentially write
  availability) for zero data loss on primary failure; **asynchronous
  replication** trades a small, lag-bounded data-loss window for lower
  latency and no dependency on replica availability. **[MySQL]**
  semi-synchronous replication (ACK on receipt, not full apply) is a
  deliberate middle ground.
- **Failover** promotes a replica to primary; done manually it's slow but
  safer against ambiguous situations, done automatically it's fast but
  requires **fencing and quorum** to avoid **split-brain** — two nodes both
  accepting writes and silently diverging the data.
- **HA is a system property** — continued acceptable operation despite
  component failure — and your synchronous/async and manual/automatic
  choices directly set your achievable **RPO/RTO** from Chapter 28; "nines"
  of availability translate directly into a downtime budget that either
  does or doesn't leave room for a human in the failover loop.
- **Failover isn't complete until client traffic is actually routed to the
  new primary** — via a moving VIP, a topology-aware proxy, or a
  driver-level multi-host connection string.
- **A replica is never a substitute for a backup** — it faithfully
  replicates mistakes (a bad `DELETE`) just as reliably as legitimate
  writes; only Chapter 28's actual backup and point-in-time recovery
  strategy protects against that failure mode.

## What's Next

Chapter 31 shifts from *operating* a production database to a set of
**Advanced SQL Patterns** you'll reach for constantly once the database
itself is reliable: gaps-and-islands analysis, slowly changing dimensions
(SCD), cohort analysis, and `MERGE`/upsert patterns — the query-writing
techniques that turn a highly-available `banking_db` into one that also
answers hard analytical questions well.

**Next:** [Chapter 31 — Advanced SQL Patterns](31-advanced-patterns.md)
