# updatepriclcost Deadlock / Interrupted Run Manual Recovery SOP

文件日期：2026-07-02
適用資料庫：`Price`
適用情境：`updatepriclcost` 或相關成本更新程序發生 deadlock、被人工中斷、執行時間異常過長，造成 `pri`、`asp`、`aspnum` 成本資料不同步時的人工恢復流程。

## 1. 目的與原則

本 SOP 的目的是讓成本更新流程在異常中斷後，可以用可控、可驗證、低風險的方式恢復一致狀態。

本次事件顯示，問題不只是單一 SQL 執行慢，而是成本更新流程可能形成下列回饋循環：

```text
重算 pri 成本
-> 更新 asp / aspnum
-> asp trigger 更新 pld / pri / odi 等下游資料
-> pri 成本輸入再次改變
-> 下一輪成本更新又找到新的差異
```

恢復時請遵守以下原則：

- 先診斷目前 SQL Server 狀態，不要直接重跑完整成本更新。
- 不要在 `asp` / `aspnum` 明顯不同步時反覆執行完整 `updatepriclcost`。
- 先讓 `pri` 與 `aspnum` 收斂，再用小批次處理 `asp`。
- 更新 `asp` 時必須假設 trigger 會帶動大量下游更新，因此批次要小、要能觀察、要能停止。
- 最終驗證以 `asp = 0` 且 `aspnum = 0` 為準。

## 2. 先確認目前是否仍有執行中的成本更新

在 SSMS 執行以下查詢，確認 `Price` 資料庫內目前執行中的 SQL、等待狀態與 blocking 狀況。

```sql
USE Price;
GO

SELECT
    r.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    r.status,
    r.command,
    r.wait_type,
    r.wait_time / 1000 AS wait_sec,
    r.blocking_session_id,
    r.cpu_time / 1000 AS cpu_sec,
    r.total_elapsed_time / 1000 AS elapsed_sec,
    r.reads,
    r.writes,
    r.logical_reads,
    DB_NAME(r.database_id) AS dbname,
    SUBSTRING(
        t.text,
        (r.statement_start_offset / 2) + 1,
        CASE
            WHEN r.statement_end_offset = -1
                THEN LEN(CONVERT(NVARCHAR(MAX), t.text))
            ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1
        END
    ) AS running_statement,
    t.text AS full_batch_text
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s
    ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.database_id = DB_ID('Price')
ORDER BY r.total_elapsed_time DESC;
```

判讀重點：

- `blocking_session_id <> 0`：此 session 正被其他 session 阻擋，需找出 blocker。
- `blocking_session_id = 0` 且 `status = runnable`：通常代表 SQL 仍在工作，不一定是卡死。
- `logical_reads` 持續增加：通常代表查詢仍在掃描或更新大量資料。
- `running_statement` 若為 `UPDATE pld`、`UPDATE asp`、`UPDATE pri`，需特別注意是否為 trigger 帶出的下游更新。

如有 blocking，使用下列查詢找出 blocker：

```sql
SELECT
    r.session_id AS blocked_session_id,
    r.blocking_session_id,
    blocker.login_name AS blocker_login,
    blocker.host_name AS blocker_host,
    blocker.program_name AS blocker_program,
    blocker.status AS blocker_status,
    blocker.open_transaction_count AS blocker_open_tran_count,
    ib.event_info AS blocker_last_command
FROM sys.dm_exec_requests r
LEFT JOIN sys.dm_exec_sessions blocker
    ON blocker.session_id = r.blocking_session_id
OUTER APPLY sys.dm_exec_input_buffer(r.blocking_session_id, NULL) ib
WHERE r.database_id = DB_ID('Price')
  AND r.blocking_session_id <> 0;
```

若必須停止正在執行的語句，優先從原本的 SSMS 視窗按 Cancel。不要第一時間使用 `KILL`，因為 rollback 可能很久，且會讓現場狀態更難判斷。

## 3. 執行 skip-asp 恢復腳本

確認沒有仍需等待的成本更新後，先執行：

```text
run_updatepriclcost2_skip_asp.sql
```

此腳本用途是重算 Y2 相關資料，但刻意跳過 `UPDATE asp`，避免立即觸發高成本的 `asp` trigger。

此腳本會處理：

- Y2 一般 `pri_cost`
- Y2 不良率 `pri_cost`
- Y2 「才」類型 `pri_cost`
- Y2 `pri_clcost`
- Y2 `aspnum`

此腳本刻意不處理：

```sql
UPDATE asp
SET asp_location = 'S',
    asp_purprice = ...
```

腳本開始時會先檢查每個 Y2 `(pri_customerid, pri_assy)` 是否只對應一個六位小數的 `pri_clcost`（`NULL` 也視為一種狀態）。若同一鍵有多個價格，腳本會列出衝突資料並在任何更新前中止。必須先釐清正確價格，不可任選 `MIN`、`MAX` 或任一筆繼續更新。

執行後確認腳本輸出的 remaining 檢查，預期如下：

```text
remaining_pri_cost   0
remaining_bad_rate   0
remaining_cai        0
remaining_aspnum     0
```

注意：當 `pri` 與 `aspnum` 已收斂後，不要無理由反覆執行 skip-asp。重跑可能再次改變 `pri_clcost`，使 `asp` 又出現新的差異。

## 4. 驗證 asp / aspnum 同步狀態

使用下列查詢確認 `asp` 與 `aspnum` 是否已等於 Y2 的 `pri.pri_clcost`。

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

判讀方式：

- `asp = 0` 且 `aspnum = 0`：同步完成。
- `aspnum > 0`：先確認 skip-asp 是否完成，必要時只處理 `aspnum` 收斂問題。
- `asp > 0`：進入下一節，建立 `asp` 修復候選清單並小批次更新。
- 若差異來自缺少對應的 `asp`／`aspnum` 列，現有復原腳本不會自動新增資料；需先依正式建檔流程補齊，不可將缺列當成價格更新處理。

## 5. 建立 asp 修復候選清單

若 `asp` 與 `pri_clcost` 仍有差異，先建立候選清單。`impact_pri_rows` 用來估計該組客戶料號可能牽動多少 `pri` 資料，後續批次更新時會優先處理影響較小的資料。

建立候選清單前，必須先確認來源唯一；若查詢回傳任何資料，停止操作並先釐清正確價格：

```sql
SELECT
    pri_customerid,
    pri_assy,
    COUNT(*) AS pri_rows,
    COUNT(DISTINCT ROUND(pri_clcost, 6)) AS distinct_nonnull_prices,
    SUM(CASE WHEN pri_clcost IS NULL THEN 1 ELSE 0 END) AS null_price_rows,
    MIN(ROUND(pri_clcost, 6)) AS min_price,
    MAX(ROUND(pri_clcost, 6)) AS max_price
FROM pri
WHERE pri_newcostchk = 'Y2'
GROUP BY pri_customerid, pri_assy
HAVING COUNT(DISTINCT ROUND(pri_clcost, 6)) > 1
    OR (COUNT(pri_clcost) > 0 AND COUNT(pri_clcost) < COUNT(*));
```

```sql
IF OBJECT_ID('tempdb..#asp_fix_candidates') IS NOT NULL
    DROP TABLE #asp_fix_candidates;

SELECT
    a.pri_customerid,
    a.pri_assy,
    a.pri_clcost AS new_price,
    COUNT(p.pri_nbr) AS impact_pri_rows
INTO #asp_fix_candidates
FROM
(
    SELECT DISTINCT
        pri_customerid,
        pri_assy,
        ROUND(pri_clcost, 6) AS pri_clcost
    FROM pri
    WHERE pri_newcostchk = 'Y2'
) a
JOIN asp s
    ON s.asp_id = a.pri_customerid
   AND s.asp_vendormaterialno = a.pri_assy
LEFT JOIN pri p
    ON p.pri_customerid = a.pri_customerid
   AND p.pri_assy = a.pri_assy
   AND p.pri_newcostchk = 'Y2'
WHERE a.pri_clcost <> ROUND(s.asp_purprice, 6)
   OR (a.pri_clcost IS NULL AND s.asp_purprice IS NOT NULL)
   OR (a.pri_clcost IS NOT NULL AND s.asp_purprice IS NULL)
GROUP BY
    a.pri_customerid,
    a.pri_assy,
    a.pri_clcost;

SELECT COUNT(*) AS candidates
FROM #asp_fix_candidates;
```

查看影響較大的候選資料：

```sql
SELECT TOP 200
    pri_customerid,
    pri_assy,
    new_price,
    impact_pri_rows
FROM #asp_fix_candidates
ORDER BY impact_pri_rows DESC, pri_customerid, pri_assy;
```

## 6. 小批次更新 asp

建議批次大小：

- 一般先從 `50` 開始。
- 若觀察到 `UPDATE pld` 或 trigger 下游更新明顯很重，降為 `20`。
- 若只剩少數筆但單筆仍很慢，降為 `1`。

```sql
DECLARE @BatchSize INT = 50;
DECLARE @Rows INT = 1;

WHILE @Rows > 0
BEGIN
    ;WITH b AS
    (
        SELECT TOP (@BatchSize)
            pri_customerid,
            pri_assy,
            new_price
        FROM #asp_fix_candidates
        ORDER BY impact_pri_rows ASC, pri_customerid, pri_assy
    )
    UPDATE asp
    SET asp_location = 'S',
        asp_purprice = b.new_price,
        asp_pricecal = LTRIM(STR(b.new_price, 100, 6)),
        asp_currency = N'臺幣',
        asp_user = N'成本恢復'
    FROM asp
    JOIN b
        ON asp.asp_id = b.pri_customerid
       AND asp.asp_vendormaterialno = b.pri_assy
    WHERE ROUND(asp.asp_purprice, 6) <> b.new_price
       OR (asp.asp_purprice IS NULL AND b.new_price IS NOT NULL)
       OR (asp.asp_purprice IS NOT NULL AND b.new_price IS NULL);

    SET @Rows = @@ROWCOUNT;

    DELETE c
    FROM #asp_fix_candidates c
    JOIN asp
        ON asp.asp_id = c.pri_customerid
       AND asp.asp_vendormaterialno = c.pri_assy
    WHERE ROUND(asp.asp_purprice, 6) = c.new_price
       OR (asp.asp_purprice IS NULL AND c.new_price IS NULL);

    SELECT
        GETDATE() AS batch_time,
        @Rows AS updated_rows,
        (SELECT COUNT(*) FROM #asp_fix_candidates) AS remaining_candidates;

    WAITFOR DELAY '00:00:02';
END;
```

批次執行期間，建議另開 SSMS 視窗定期執行第 2 節 DMV 查詢。若看到目前 session 是 head blocker 且 `status = runnable`、`logical_reads` 持續增加，通常代表 trigger 仍在處理資料，不要立刻中止。

## 7. 處理最後少數異常資料

若最後只剩 1 到數筆資料，先列出明細：

```sql
SELECT
    a.pri_customerid,
    a.pri_assy,
    a.pri_clcost AS expected_price,
    ROUND(s.asp_purprice, 6) AS current_price,
    a.pri_clcost - ROUND(s.asp_purprice, 6) AS diff
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
   OR (a.pri_clcost IS NOT NULL AND s.asp_purprice IS NULL);
```

若需單筆處理，建議使用交易包住，先確認 `asp`、`pri`、`aspnum` 結果一致後再 `COMMIT`。

```sql
BEGIN TRAN;

UPDATE asp
SET asp_location = 'S',
    asp_purprice = <new_price>,
    asp_pricecal = LTRIM(STR(<new_price>, 100, 6)),
    asp_currency = N'臺幣',
    asp_user = N'成本恢復'
WHERE asp_id = '<pri_customerid>'
  AND asp_vendormaterialno = '<pri_assy>'
  AND
  (
      ROUND(asp_purprice, 6) <> <new_price>
      OR (asp_purprice IS NULL AND <new_price> IS NOT NULL)
      OR (asp_purprice IS NOT NULL AND <new_price> IS NULL)
  );

SELECT @@ROWCOUNT AS updated_rows;

SELECT
    'asp' AS src,
    ROUND(asp_purprice, 6) AS price
FROM asp
WHERE asp_id = '<pri_customerid>'
  AND asp_vendormaterialno = '<pri_assy>';

SELECT
    'pri' AS src,
    ROUND(pri_clcost, 6) AS price,
    COUNT(*) AS rows_count
FROM pri
WHERE pri_newcostchk = 'Y2'
  AND pri_customerid = '<pri_customerid>'
  AND pri_assy = '<pri_assy>'
GROUP BY ROUND(pri_clcost, 6);

SELECT
    'aspnum' AS src,
    ROUND(aspnum_price, 6) AS price
FROM aspnum
WHERE aspnum_id = '<pri_customerid>'
  AND aspnum_num = '<pri_assy>';

-- 確認無誤後執行：
-- COMMIT;

-- 若結果不符合預期：
-- ROLLBACK;
```

## 8. 最終驗證

若使用 `#asp_fix_candidates`，先確認候選清單已清空：

```sql
SELECT COUNT(*) AS remaining_candidates
FROM #asp_fix_candidates;
```

再執行同步驗證：

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

預期結果：

```text
asp       0
aspnum    0
```

只有在上述結果都為 0 後，才建議重新執行官方成本更新。官方成本更新完成後，必須再次執行本節同步驗證。

正式驗證時避免使用 `WITH (NOLOCK)`，以免 dirty read 造成誤判。

## 9. 異常處理注意事項

- SQL Server deadlock 通常會選出 victim 並回傳錯誤，不會無限執行。
- 長時間執行、`blocking_session_id = 0`、`status = runnable` 且 `logical_reads` 持續增加，通常代表仍在工作。
- 若 `asp` batch update 期間出現短暫 blocking，可能是 `asp` trigger 正在更新下游資料。
- 若必須停止目前語句，優先從原 SSMS 視窗 Cancel。只有在確認必要且理解 rollback 成本後，才考慮 `KILL`。
- 不要在 `asp` / `aspnum` 已同步為 0 後繼續反覆執行 skip-asp。

## 10. 建議後續改善

- 檢查並優化 `asp` trigger，尤其是造成大量 `UPDATE pld` logical reads 的段落。
- 評估將 `updatepriclcost` 的成本計算與 `asp` propagation 拆開，降低單次流程的風險。
- 評估加入 deadlock retry、內部分批、或明確的恢復點。
- 檢查 `odi` 更新邏輯是否因 `pri_aspupdate1` join 造成 fanout 放大。
- 建立 post-run validation job，定期檢查 `asp` / `aspnum` 不同步筆數，若非 0 則告警。

## 11. 本次事件已知恢復結果

本次人工恢復已完成，後續官方成本更新也已完成。

最後驗證結果：

```text
asp       0
aspnum    0
```

最後一筆人工處理的差異資料：

```text
pri_customerid = 10U2-02206
pri_assy       = A0U047-0057
final price    = 23.133764
```
