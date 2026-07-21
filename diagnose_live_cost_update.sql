USE Price;
GO

SET NOCOUNT ON;

-------------------------------------------------------------------------------
-- 即時診斷成本更新卡在哪裡
-- 使用方式：
-- 1. 成本更新正在執行很久時，另開 SSMS 視窗執行本檔。
-- 2. 先看 section 1 的 wait_type / blocking_session_id / logical_reads。
-- 3. 若有 blocking_session_id，再看 section 2。
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- 1. 目前 Price 正在執行的 SQL
-------------------------------------------------------------------------------
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

-------------------------------------------------------------------------------
-- 2. 如果 section 1 有 blocking_session_id，查誰擋住它
-------------------------------------------------------------------------------
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

-------------------------------------------------------------------------------
-- 3. Price 目前開著交易的 session
-------------------------------------------------------------------------------
SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    s.status,
    s.open_transaction_count,
    r.command,
    r.wait_type,
    r.blocking_session_id,
    r.total_elapsed_time / 1000 AS elapsed_sec,
    ib.event_info AS last_command
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_requests r
    ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_input_buffer(s.session_id, NULL) ib
WHERE s.database_id = DB_ID('Price')
   OR r.database_id = DB_ID('Price')
ORDER BY s.open_transaction_count DESC, elapsed_sec DESC;

-------------------------------------------------------------------------------
-- 4. pri 統計資料狀態
-------------------------------------------------------------------------------
SELECT
    DB_NAME() AS dbname,
    s.name AS stats_name,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.modification_counter
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID('dbo.pri')
ORDER BY sp.modification_counter DESC, s.name;

-------------------------------------------------------------------------------
-- 5. 快速判斷 Y1 / N / Y2 筆數是否異常
-------------------------------------------------------------------------------
SELECT
    pri_newcostchk,
    COUNT(*) AS rows_count
FROM dbo.pri WITH (NOLOCK)
GROUP BY pri_newcostchk
ORDER BY rows_count DESC;

-------------------------------------------------------------------------------
-- 6. updatepriclcost1 Step 3 是否應該更新資料
-- 若 rows_to_update = 0，但原 UPDATE 還跑很久，通常是執行計畫問題。
-------------------------------------------------------------------------------
SELECT COUNT(*) AS rows_to_update_step3_clcost
FROM
(
    SELECT DISTINCT
           c.pri_customerid,
           c.pri_assy,
           CASE
               WHEN pri_um = 'Feet' THEN
                   (c1.clsum + c2.a1 + c3.cost + c4.cost) / 3.28084
               ELSE
                   (c1.clsum + c2.a1 + c3.cost + c4.cost)
           END AS material_cost
    FROM pri AS c WITH (NOLOCK)
        LEFT JOIN
        (
            SELECT SUM(a.pri_cost) * b.pri_tbprice * b.pri_perqty AS clsum,
                   a.pri_customerid,
                   a.pri_assy
            FROM pri AS a WITH (NOLOCK)
                LEFT JOIN
                (
                    SELECT pri_tbprice,
                           pri_perqty,
                           pri_customerid,
                           pri_assy
                    FROM pri WITH (NOLOCK)
                    WHERE LEFT(pri_part, 2) = '不良'
                      AND pri_newcostchk = 'Y1'
                ) AS b
                    ON a.pri_customerid = b.pri_customerid
                   AND a.pri_assy = b.pri_assy
            WHERE a.pri_newcostchk = 'Y1'
              AND LEFT(a.pri_part, 2) <> '不良'
            GROUP BY a.pri_customerid,
                     a.pri_assy,
                     b.pri_tbprice,
                     b.pri_perqty
        ) AS c1
            ON c1.pri_customerid = c.pri_customerid
           AND c1.pri_assy = c.pri_assy
        LEFT JOIN
        (
            SELECT SUM(pri_cost) / SUM(pri_perqty) AS a1,
                   pri_customerid,
                   pri_assy
            FROM pri WITH (NOLOCK)
            WHERE pri_newcostchk = 'Y1'
              AND SUBSTRING(pri_part, 1, 2) NOT IN ('不良', '加工', '編織')
            GROUP BY pri_customerid,
                     pri_assy
        ) AS c2
            ON c2.pri_customerid = c.pri_customerid
           AND c2.pri_assy = c.pri_assy
        LEFT JOIN
        (
            SELECT SUM(pri_cost) AS cost,
                   pri_customerid,
                   pri_assy
            FROM pri WITH (NOLOCK)
            WHERE LEFT(pri_part, 2) = '加工'
              AND pri_newcostchk = 'Y1'
            GROUP BY pri_customerid,
                     pri_assy
        ) AS c3
            ON c3.pri_customerid = c.pri_customerid
           AND c3.pri_assy = c.pri_assy
        LEFT JOIN
        (
            SELECT SUM(pri_cost) AS cost,
                   pri_customerid,
                   pri_assy
            FROM pri WITH (NOLOCK)
            WHERE LEFT(pri_part, 2) = '編織'
              AND pri_newcostchk = 'Y1'
            GROUP BY pri_customerid,
                     pri_assy
        ) AS c4
            ON c4.pri_customerid = c.pri_customerid
           AND c4.pri_assy = c.pri_assy
) AS ab
JOIN pri AS ac WITH (NOLOCK)
    ON ac.pri_customerid = ab.pri_customerid
   AND ac.pri_assy = ab.pri_assy
WHERE ac.pri_newcostchk = 'Y1'
  AND ac.pri_clcost <> ROUND(ab.material_cost, 6)
OPTION (RECOMPILE);
