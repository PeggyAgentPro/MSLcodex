# PROJECT_CONTEXT

## Background

This project contains SQL scripts and operational notes for the `Price` database cost update process, mainly around `updatepriclcost` / `updatepriclcost2` recovery and performance troubleshooting.

On 2026-07-01 00:00, the scheduled cost update started but failed around 03:00 due to a SQL Server deadlock. A manual recovery attempt started around 06:00, but it was stopped before 08:00 because new business data was already entering the system. The 08:15 scheduled run then ran for about 3 hours without finishing and was manually interrupted. By the afternoon, application latency was severe, and the recovery work in this thread began.

The incident was not just a single slow query. The main issue was that the cost update workflow can form a feedback loop:

```text
recalculate pri costs
-> update asp / aspnum
-> asp trigger updates downstream data such as pld / pri / odi
-> pri cost inputs change again
-> another cost update finds new differences
```

This made the system look like it was never finishing, especially after the initial deadlock and several interrupted runs left tables partially synchronized.

## Completed Work

- Diagnosed that some long-running sessions were not blocked by another user, but were head blockers themselves while running trigger-driven updates.
- Confirmed one heavy point was `asp` trigger activity leading to `UPDATE pld ...` with very high logical reads.
- Created and used a `skip asp` recovery flow to recalculate `pri` and `aspnum` while intentionally avoiding the high-risk `UPDATE asp` section.
- Built a manual `#asp_fix_candidates` process to identify `asp` rows whose price did not match `pri.pri_clcost`.
- Updated `asp` in small batches to avoid triggering too much downstream work at once.
- Handled a final single-row mismatch for:
  - `pri_customerid = 10U2-02206`
  - `pri_assy = A0U047-0057`
  - final synchronized price `23.133764`
- Re-ran the official cost update after manual convergence; it finally completed.
- Final verification showed:
  - `asp` not-synced rows: `0`
  - `aspnum` not-synced rows: `0`

## Important Files

- `updatepriclcost.sql`
  - Main cost update SQL/procedure script in this workspace.

- `updatepriclcost1.sql`
  - Related cost update script, includes `asp` / `aspnum` update logic.

- `run_updatepriclcost2_skip_asp.sql`
  - Recovery script created for this incident.
  - Recalculates Y2-related `pri_cost`, bad-rate cost, `pri_clcost`, and `aspnum`.
  - Intentionally skips `UPDATE asp` to avoid firing the heavy `asp` trigger during the first recovery pass.

- `diagnose_live_cost_update.sql`
  - DMV-style diagnostic script for checking active SQL requests, blocking, session state, and running statements in the `Price` database.

- `diagnose_odi_update_fanout.sql`
  - Diagnostic script for checking whether `odi` update logic may be amplified by joins to `pri_aspupdate1`.

- `updatepriclcost_deadlock_manual_recovery_sop.md`
  - New SOP documenting how to recover if cost update deadlocks or gets interrupted:
    - how to inspect DMV state
    - how to run the skip-asp recovery
    - how to create `#asp_fix_candidates`
    - how to batch-update `asp`
    - how to verify final convergence

- `updatepriclcost_performance_sop.md`
  - Older performance SOP. It may display as garbled text in PowerShell due to encoding/code page issues.

## Key Decisions

- Do not repeatedly run the full original cost update while `asp` / `aspnum` are out of sync.
- Use `run_updatepriclcost2_skip_asp.sql` first when recovering from a failed or interrupted cost update, so `pri` and `aspnum` can converge without immediately triggering `asp`.
- Abort the recovery when one Y2 `(pri_customerid, pri_assy)` key resolves to multiple six-decimal `pri_clcost` values; never let `asp` or `aspnum` choose an arbitrary source price.
- After `pri` and `aspnum` converge, update `asp` separately in small batches.
- Use `impact_pri_rows ASC` when batching `asp` updates so smaller-impact rows run first.
- If the last few rows are slow, reduce `@BatchSize` to `1`.
- Once `asp = 0` and `aspnum = 0` in the sync check, do not keep rerunning skip-asp unless there is a clear reason. Rerunning skip-asp can recalculate `pri_clcost` again and create new `asp` differences.
- For final verification, avoid `WITH (NOLOCK)` if an exact committed result is required.

## Useful Verification Query

Use this to confirm `asp` and `aspnum` match Y2 `pri_clcost`:

The `LEFT JOIN` is intentional: a missing `asp` or `aspnum` target row is also counted as not synchronized.

```sql
SELECT
    'asp' AS target_table,
    COUNT(*) AS not_synced_rows
FROM
(
    SELECT DISTINCT
        pri_customerid,
        pri_assy,
        ROUND(pri_clcost, 6) AS pri_clcost
    FROM pri
    WHERE pri_newcostchk = 'Y2'
) a
LEFT JOIN asp s
    ON s.asp_id = a.pri_customerid
   AND s.asp_vendormaterialno = a.pri_assy
WHERE s.asp_id IS NULL
   OR a.pri_clcost <> ROUND(s.asp_purprice, 6)
   OR (a.pri_clcost IS NULL AND s.asp_purprice IS NOT NULL)
   OR (a.pri_clcost IS NOT NULL AND s.asp_purprice IS NULL)

UNION ALL

SELECT
    'aspnum' AS target_table,
    COUNT(*) AS not_synced_rows
FROM
(
    SELECT DISTINCT
        pri_customerid,
        pri_assy,
        ROUND(pri_clcost, 6) AS pri_clcost
    FROM pri
    WHERE pri_newcostchk = 'Y2'
) a
LEFT JOIN aspnum n
    ON n.aspnum_id = a.pri_customerid
   AND n.aspnum_num = a.pri_assy
WHERE n.aspnum_id IS NULL
   OR a.pri_clcost <> ROUND(n.aspnum_price, 6)
   OR (a.pri_clcost IS NULL AND n.aspnum_price IS NOT NULL)
   OR (a.pri_clcost IS NOT NULL AND n.aspnum_price IS NULL);
```

Expected final result:

```text
asp       0
aspnum    0
```

## Open Items / TODO

- Review and commit the validation hardening added after the initial recovery commit.
- Review whether the production `asp` trigger should be optimized, especially the part that led to heavy `UPDATE pld` work.
- Review whether `updatepriclcost` should be made more resilient to deadlocks, for example with smaller internal batches, retry handling, or a safer separation between cost calculation and `asp` propagation.
- Review `odi` update fanout risk, especially joins involving `pri_aspupdate1`.
- Consider adding an official post-run validation job that checks `asp` / `aspnum` sync counts and alerts if either is non-zero.

## Operational Notes

- A true SQL Server deadlock usually fails with an error and chooses a victim. It does not normally run forever.
- A long-running update with `blocking_session_id = 0`, `status = runnable`, and increasing `logical_reads` is usually still doing work.
- If a recovery update appears stuck, first check DMV state. Do not immediately `KILL`; rollback can be expensive and make the situation harder to reason about.
- Prefer cancelling from the original SSMS window if the currently running statement must be stopped.
- When `asp` batch updates are running, short periods of blocking may happen because the `asp` trigger updates downstream data.
- The safest recovery pattern after an interrupted cost update is:

```text
1. Inspect active sessions / blocking.
2. Run skip-asp cost recovery.
3. Verify pri / aspnum remaining counts.
4. Build #asp_fix_candidates.
5. Batch-update asp.
6. Verify asp = 0 and aspnum = 0.
7. Run official update only after convergence.
8. Verify asp = 0 and aspnum = 0 again.
```

## Current Status

As of the end of this thread:

- Manual recovery completed.
- Official cost update completed.
- `asp` and `aspnum` synchronization checks were both `0`.
- Recovery scripts and SOP were committed locally; the validation hardening and handoff corrections are currently uncommitted.
- Local `main` is ahead of `origin/main`; no push has been performed.
