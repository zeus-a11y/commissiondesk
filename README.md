# CommissionDesk

**Life-insurance agent commission engine in Oracle PL/SQL.** Oracle Database 23,
Flyway migrations, utPLSQL unit tests, a Spring Boot 3 / Java 21 API over the
packages, and a CI pipeline that tests the database code on a real Oracle
container.

Every month an insurer has to work out what each agent earned on every renewal
and first-year premium it collected, pay overrides up the sales hierarchy,
recover commission on policies that lapsed early, deduct tax and produce a
statement per agent. That is a set-based batch job over the whole premium book,
which is why it belongs in the database. CommissionDesk models it end to end.

## The monthly run (`pkg_commission.calculate`)

| Step | How |
| --- | --- |
| **Lifecycle guard** | A month is `CALCULATED`, then `APPROVED` and locked. Named exceptions (`RAISE_APPLICATION_ERROR` -20001 to -20004) refuse a future month, a locked month, or a month whose predecessor is unapproved. Recalculating an unapproved month is idempotent. |
| **Base commission** | Cursor over the month's receipts joined to the effective-dated rate table, fetched with `BULK COLLECT ... LIMIT 2000` and inserted with `FORALL ... SAVE EXCEPTIONS`. A receipt with no configured rate fails the `NOT NULL` on its own row; the rest of the batch is paid and the failure goes to an **exceptions queue** instead of stopping the run. |
| **Orphan policies** | Renewals paid after an agent's termination date earn nobody commission and are queued for reassignment (set-based `INSERT ... SELECT`). |
| **Overrides** | 10% to the parent and 5% to the grandparent on first-year business, found with a `CONNECT BY` walk up the hierarchy inside `CROSS APPLY`. |
| **Clawback** | A policy that lapses in policy year 1 returns 100% of its first-year commission from every recipient, 50% in year 2. Function-based unique indexes make a double clawback impossible. |
| **Bonus** | Volume tiers on the month's first-year premium (Rs 1.5 lakh: 5%, Rs 4 lakh: 10% of first-year commission). |
| **Statement** | One `MERGE` per run: postings + debit brought forward, **TDS under section 194D** at 2% (20% with no PAN, s.206AA) only once FY credits pass Rs 20,000, with catch-up on crossing; a negative balance is carried forward; GST under reverse charge is shown as the insurer's liability. |
| **Logging** | `run_log` written by an `AUTONOMOUS_TRANSACTION`, so a failed and rolled-back run still leaves its error and backtrace. |
| **Scheduling** | `DBMS_SCHEDULER` job runs last month at 02:00 on the 2nd; operations review and approve. |

Also in the database: a **compound trigger** that rejects overlapping rate
windows (avoiding ORA-04091 mutating table), a cycle check on the agent
hierarchy, an audit trigger that masks PANs, and report views built on analytic
functions (`RANK`, `RATIO_TO_REPORT`, running FY totals) and hierarchical queries
(`SYS_CONNECT_BY_PATH`, `CONNECT_BY_ISLEAF`).

The rates are illustrative: since the IRDAI (Payment of Commission) Regulations,
2023, insurers set commission in a board-approved policy, which the
effective-dated `commission_rate` table models.

## Demo book (synthetic, seeded by PL/SQL)

`pkg_demo_data` builds a reproducible book: 57 agents in three branches
(manager, 3 seniors, 15 advisors each), 6,000 policies issued over three years,
47,664 premium receipts with late payers and early lapses (703 lapsed), two
advisors without a PAN and one who left mid-year. It loads in about 5 s and
calculates and approves 35 months of history in about 13 s; a single month
(about 2,400 receipts) runs in under 0.2 s.

## Tests

- **utPLSQL, 21 tests** (`db/test`): first-year and renewal rates, a dated rate
  change, the April financial year, both override levels, the exceptions queue
  (missing rate, orphan policies), clawback at 100% and 50% and never twice,
  bonus tiers, the TDS threshold catch-up and no-PAN rate, debit carry-forward,
  locked, out-of-order and future months, idempotent recalculation, and the
  overlap, cycle and PAN-masking triggers. Planting bugs in the package
  (override 4% instead of 5%, clawback 60% instead of 50%, no TDS catch-up)
  makes them fail.
- **JUnit + Spring Boot, 6 tests** against real Oracle (Testcontainers):
  every run's total equals its postings and its statements; every BASE posting
  equals an independent Java recomputation from the rate table; calculate,
  approve and lock October over HTTP with PL/SQL errors mapped to 409/400/404;
  the team tree; and nothing in the exceptions queue was also paid.
- **Deployment guard**: a Flyway `afterMigrate` callback fails the deployment
  if any PL/SQL object is invalid. Oracle compiles broken packages with only a
  warning, so without it a bad package would deploy "successfully".

## CI

`.github/workflows/ci.yml` runs three jobs: starts Oracle 23 Free, applies the
migrations to a clean schema, installs utPLSQL (checksum-verified) and runs the
PL/SQL tests; runs the JUnit suite on Testcontainers; and builds the Docker
image and smoke-tests the Compose stack over HTTP.

## Run it

Needs Docker and JDK 21+.

```
docker compose up -d oracle          # Oracle 23 Free on localhost:1522, creates the schema user
mvn spring-boot:run                  # migrations, demo book, UI and API on http://localhost:8080
```

Or everything in containers: `docker compose up --build`. PL/SQL tests against
the running container:

```
db/test/install_utplsql.sh commissiondesk-oracle-1
db/test/run_tests.sh commissiondesk-oracle-1
```

## API

| Method | Path | |
| --- | --- | --- |
| GET | `/api/runs` | run history with totals |
| POST | `/api/runs` `{"period":"2026-10"}` | calculate a month |
| GET | `/api/runs/{id}` | run detail and exceptions queue |
| POST | `/api/runs/{id}/approve` `{"approvedBy":"..."}` | approve and lock |
| GET | `/api/runs/{id}/statements?branch=` | statements ranked within branch |
| GET | `/api/runs/{id}/statements/{agent}/lines` | one agent's postings |
| GET | `/api/agents`, `/api/agents/{code}` | hierarchy, team tree, statement history |
| GET | `/api/rates`, `/api/reports/persistency` | commission policy, 13-month persistency |

All names and figures are synthetic, and the commission rates are illustrative.
