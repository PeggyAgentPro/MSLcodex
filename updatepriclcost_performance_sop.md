# updatepriclcost 成本更新變慢排查紀錄與 SOP

日期：2026-06-03  
資料庫：Price / TEST  
相關程序：

- `updatepriclcost`
- `updateBOM`
- `updatepriclcost1`

## 問題現象

原本正式區 `Price` 在 2026/6/1 執行成本更新約 20 秒完成，但同樣資料在 `TEST` 或後續 `Price` 執行時，成本更新變成 8-9 小時。

一開始懷疑是資料異常，例如：

- `Y1` / `N` 筆數異常
- 某個 `pri_assy + pri_customerid` 群組資料暴增
- `不良率`、`加工`、`編織` 等材料資料造成 JOIN 放大
- 6/1 後新增或異動資料造成成本更新卡住

經查後，上述方向皆排除。

## 已確認的資料狀況

`Price` 與 `TEST` 的主要資料量接近或相同：

- `pri_newcostchk = 'Y1'` 筆數相同
- `Y1` 的 `(pri_customerid, pri_assy)` 群組數相同
- 最大子項數相同
- Step 3 使用到的 `Y1` 資料差異為 0

針對 `updatepriclcost1` Step 3 拆解後，中間資料量很小：

- `#c`：2389 筆，193 組
- `#c1`：193 筆，193 組
- `#c2`：193 筆，193 組
- `#c3`：192 筆，192 組
- `#c4`：191 筆，191 組
- `#ab`：193 筆，193 組
- `final_join_rows = 0`
- 拆成暫存表後 total 約 1 秒完成

所以問題不是資料內容異常，也不是 Step 3 材料價計算本身資料量太大。

## 關鍵證據

當原始 Step 3 UPDATE 長時間執行時，使用 DMV 查詢：

```sql
SELECT
    r.session_id,
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
    ) AS running_statement
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.database_id = DB_ID('Price')
ORDER BY r.total_elapsed_time DESC;
```

當時觀察到：

- `wait_type = NULL`
- `blocking_session_id = 0`
- CPU time 持續增加
- logical reads 快速暴增，曾達近 1 億
- running statement 為 `UPDATE pri SET pri_clcost ...`

這代表 SQL Server 沒有被鎖住，也不是等磁碟或 log，而是在用錯誤的執行計畫反覆讀取 `pri`。

另外也使用 `SHOWPLAN_XML` 比較 `Price` 與 `TEST` 的預估執行計畫。這一步很直覺，因為不用真的執行 UPDATE，就可以看出兩個資料庫的計畫差異。

### 產生 Price 的預估執行計畫

```sql
USE Price;
GO

SET SHOWPLAN_XML ON;
GO

UPDATE pri
SET pri_clcost = ROUND(ab.材料價, 6),
    pri_costflag = 'N'
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
           END AS 材料價
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
) AS ab,
pri AS ac
WHERE ac.pri_newcostchk = 'Y1'
  AND ac.pri_customerid = ab.pri_customerid
  AND ac.pri_assy = ab.pri_assy
  AND ac.pri_clcost <> ROUND(ab.材料價, 6);

GO

SET SHOWPLAN_XML OFF;
GO
```

### 產生 TEST 的預估執行計畫

把第一行改成 `USE TEST;`，其餘 SQL 保持完全相同：

```sql
USE TEST;
GO

SET SHOWPLAN_XML ON;
GO

-- 貼上與 Price 完全相同的 Step 3 UPDATE

GO

SET SHOWPLAN_XML OFF;
GO
```

注意事項：

- `SET SHOWPLAN_XML ON` 只產生預估計畫，不會真的執行 UPDATE。
- 不要使用 SSMS 的「包含實際執行計畫」去跑，實際執行計畫會真的執行 UPDATE。
- Price 與 TEST 貼上的 Step 3 SQL 必須完全相同，只能改 `USE Price` / `USE TEST`。

看圖重點：

- Price 與 TEST 是否使用不同 Join 策略。
- TEST 是否出現多個 `Nested Loops`。
- TEST 是否反覆對 `pri` 做 `Clustered Index Seek` / `Index Seek`。
- TEST 的 Estimated Rows 是否明顯估錯。
- 哪個節點 Estimated Cost 最大。

本次案例中，TEST 的圖形計畫可明顯看到多層 `Nested Loops`，並反覆讀取 `pri`，這與 DMV 查到的 logical reads 暴增相互吻合。

## 根因

根因是：

> `pri` 統計資料或快取執行計畫失準，導致 SQL Server 在 `updatepriclcost1` Step 3 選到極差的 Nested Loops 執行計畫，反覆掃描 `pri`，造成 logical reads 暴增。

這不是：

- 資料內容壞掉
- 程式進入無限迴圈
- trigger 卡住
- blocking 鎖定
- 備份資料壞掉

而是 SQL Server 對資料分布估算錯誤，導致選錯執行計畫。

## 已驗證的解法

執行以下 SQL 後，成本更新恢復正常速度：

```sql
USE Price;
GO

UPDATE STATISTICS dbo.pri WITH FULLSCAN;
GO

EXEC sp_recompile 'updatepriclcost';
EXEC sp_recompile 'updateBOM';
EXEC sp_recompile 'updatepriclcost1';
GO
```

`UPDATE STATISTICS dbo.pri WITH FULLSCAN` 會重新完整掃描 `pri`，更新統計資料。  
`sp_recompile` 會讓相關 stored procedure 下次執行時重新編譯執行計畫。

## 緊急處理 SOP

如果日後成本更新突然從數十秒變成數小時，先不要急著找資料異常，依序檢查。

### 1. 查是否被鎖住

```sql
SELECT
    r.session_id,
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
    ) AS running_statement
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.database_id = DB_ID('Price')
ORDER BY r.total_elapsed_time DESC;
```

判斷方式：

- `wait_type LIKE 'LCK_M_%'` 且 `blocking_session_id <> 0`：被鎖住
- `wait_type = 'WRITELOG'`：交易記錄檔寫入慢
- `wait_type LIKE 'PAGEIOLATCH_%'`：磁碟讀取慢
- `wait_type IS NULL` 且 CPU / logical reads 持續增加：高度懷疑壞執行計畫

### 2. 若確認是壞執行計畫，執行修復

```sql
USE Price;
GO

UPDATE STATISTICS dbo.pri WITH FULLSCAN;
GO

EXEC sp_recompile 'updatepriclcost';
EXEC sp_recompile 'updateBOM';
EXEC sp_recompile 'updatepriclcost1';
GO
```

### 3. 再重新執行成本更新

```sql
USE Price;
GO

UPDATE pub SET pub_aimlocked = 1;
EXEC updatepriclcost;
GO
```

## TEST 還原後建議

如果是 TEST 還原、匯入大量資料、或測試成本更新前，建議先執行：

```sql
USE TEST;
GO

UPDATE STATISTICS dbo.pri WITH FULLSCAN;
GO

EXEC sp_recompile 'updatepriclcost';
EXEC sp_recompile 'updateBOM';
EXEC sp_recompile 'updatepriclcost1';
GO
```

這不會修改成本資料內容，只是更新 SQL Server 的統計資訊與重編譯執行計畫。

## 每日自動排程建議

正式區 `Price` 不建議每天固定執行 `UPDATE STATISTICS dbo.pri WITH FULLSCAN`，除非確認每天都有大量異動且常發生執行計畫失準。

原因：

- `FULLSCAN` 會完整掃描 `pri`，本身有成本
- 正常情況下 SQL Server 自動統計可維持運作
- 每天強制 fullscan 不一定必要

若想加輕量保險，可在每日成本更新前只加：

```sql
USE Price;
GO

EXEC sp_recompile 'updatepriclcost';
EXEC sp_recompile 'updateBOM';
EXEC sp_recompile 'updatepriclcost1';
GO
```

但若正式區已經發生明顯變慢，則直接執行 `FULLSCAN + sp_recompile` 作為急救。

## 本次結論

本次成本更新變慢的原因不是資料異常，而是：

> `Price / TEST` 的 `pri` 統計資料或快取執行計畫失準，導致 `updatepriclcost1` Step 3 選錯 Nested Loops 計畫，造成大量 logical reads。

執行：

```sql
UPDATE STATISTICS dbo.pri WITH FULLSCAN;
EXEC sp_recompile 'updatepriclcost';
EXEC sp_recompile 'updateBOM';
EXEC sp_recompile 'updatepriclcost1';
```

後，執行速度恢復正常。
