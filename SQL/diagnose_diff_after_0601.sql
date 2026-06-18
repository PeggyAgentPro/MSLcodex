USE TEST;
GO

SET NOCOUNT ON;

DECLARE @since_date DATE = '2026-06-01';

-------------------------------------------------------------------------------
-- 1. 先看 pri 裡可能可用的日期欄位
-------------------------------------------------------------------------------
SELECT
    TABLE_NAME,
    COLUMN_NAME,
    DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('pri', 'asp', 'aspnum')
  AND
  (
      COLUMN_NAME LIKE '%date%'
      OR COLUMN_NAME LIKE '%time%'
      OR COLUMN_NAME LIKE '%create%'
      OR COLUMN_NAME LIKE '%modify%'
      OR COLUMN_NAME LIKE '%update%'
      OR COLUMN_NAME LIKE '%user%'
  )
ORDER BY TABLE_NAME, COLUMN_NAME;

-------------------------------------------------------------------------------
-- 2. 如果 pri_date 是可轉日期，先鎖定 2026/6/1 後的 Y1 資料
-------------------------------------------------------------------------------
SELECT
    COUNT(*) AS y1_rows_after_0601_by_pri_date,
    COUNT(DISTINCT pri_customerid + '|' + pri_assy) AS y1_groups_after_0601_by_pri_date
FROM dbo.pri
WHERE pri_newcostchk = 'Y1'
  AND TRY_CONVERT(DATE, pri_date) > @since_date;

SELECT TOP 100
    pri_customerid,
    pri_assy,
    COUNT(*) AS rows_count,
    MIN(TRY_CONVERT(DATE, pri_date)) AS min_pri_date,
    MAX(TRY_CONVERT(DATE, pri_date)) AS max_pri_date,
    COUNT(DISTINCT pri_part) AS distinct_part_count
FROM dbo.pri
WHERE pri_newcostchk = 'Y1'
  AND TRY_CONVERT(DATE, pri_date) > @since_date
GROUP BY pri_customerid, pri_assy
ORDER BY rows_count DESC;

-------------------------------------------------------------------------------
-- 3. 不靠日期，直接比 Price vs TEST：找 TEST 多出來的 Y1 明細
--    這比日期更可靠，因為舊單也可能在 6/1 後被改值。
-------------------------------------------------------------------------------
SELECT TOP 200
    'TEST_ONLY_Y1_ROW' AS diff_type,
    pri_nbr,
    pri_customerid,
    pri_assy,
    pri_part,
    pri_um,
    pri_newcostchk,
    pri_tbprice,
    pri_perqty,
    pri_cost,
    pri_clcost,
    pri_date
FROM
(
    SELECT
        pri_nbr,
        pri_customerid,
        pri_assy,
        pri_part,
        pri_um,
        pri_newcostchk,
        pri_tbprice,
        pri_perqty,
        pri_cost,
        pri_clcost,
        pri_date
    FROM TEST.dbo.pri
    WHERE pri_newcostchk = 'Y1'

    EXCEPT

    SELECT
        pri_nbr,
        pri_customerid,
        pri_assy,
        pri_part,
        pri_um,
        pri_newcostchk,
        pri_tbprice,
        pri_perqty,
        pri_cost,
        pri_clcost,
        pri_date
    FROM Price.dbo.pri
    WHERE pri_newcostchk = 'Y1'
) AS x
ORDER BY pri_customerid, pri_assy, pri_nbr;

-------------------------------------------------------------------------------
-- 4. 把差異資料收斂成 Step 3 的 assy/customer 群組
-------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#changed_y1_groups') IS NOT NULL DROP TABLE #changed_y1_groups;

SELECT DISTINCT
    pri_customerid,
    pri_assy
INTO #changed_y1_groups
FROM
(
    SELECT
        pri_nbr,
        pri_customerid,
        pri_assy,
        pri_part,
        pri_um,
        pri_newcostchk,
        pri_tbprice,
        pri_perqty,
        pri_cost,
        pri_clcost,
        pri_date
    FROM TEST.dbo.pri
    WHERE pri_newcostchk = 'Y1'

    EXCEPT

    SELECT
        pri_nbr,
        pri_customerid,
        pri_assy,
        pri_part,
        pri_um,
        pri_newcostchk,
        pri_tbprice,
        pri_perqty,
        pri_cost,
        pri_clcost,
        pri_date
    FROM Price.dbo.pri
    WHERE pri_newcostchk = 'Y1'
) AS d;

CREATE INDEX IX_changed_y1_groups ON #changed_y1_groups (pri_customerid, pri_assy);

SELECT COUNT(*) AS changed_y1_group_count
FROM #changed_y1_groups;

SELECT TOP 100
    g.pri_customerid,
    g.pri_assy,
    COUNT(p.pri_nbr) AS test_y1_rows_in_group,
    COUNT(DISTINCT p.pri_part) AS distinct_part_count,
    MIN(p.pri_date) AS min_pri_date,
    MAX(p.pri_date) AS max_pri_date
FROM #changed_y1_groups AS g
JOIN TEST.dbo.pri AS p
    ON p.pri_customerid = g.pri_customerid
   AND p.pri_assy = g.pri_assy
WHERE p.pri_newcostchk = 'Y1'
GROUP BY g.pri_customerid, g.pri_assy
ORDER BY test_y1_rows_in_group DESC;

-------------------------------------------------------------------------------
-- 5. 只針對差異群組跑 Step 3 材料價計算，看是否這些群組才會慢
-------------------------------------------------------------------------------
DECLARE @step_start DATETIME2(3) = SYSDATETIME();

SELECT COUNT(*) AS step3_rows_only_changed_groups
FROM
(
    SELECT DISTINCT
           c.pri_customerid,
           c.pri_assy,
           CASE
               WHEN c.pri_um = 'Feet' THEN
                   (c1.clsum + c2.a1 + c3.cost + c4.cost) / 3.28084
               ELSE
                   (c1.clsum + c2.a1 + c3.cost + c4.cost)
           END AS material_cost
    FROM TEST.dbo.pri AS c WITH (NOLOCK)
        JOIN #changed_y1_groups AS g
            ON g.pri_customerid = c.pri_customerid
           AND g.pri_assy = c.pri_assy
        LEFT JOIN
        (
            SELECT SUM(a.pri_cost) * b.pri_tbprice * b.pri_perqty AS clsum,
                   a.pri_customerid,
                   a.pri_assy
            FROM TEST.dbo.pri AS a WITH (NOLOCK)
                JOIN #changed_y1_groups AS g
                    ON g.pri_customerid = a.pri_customerid
                   AND g.pri_assy = a.pri_assy
                LEFT JOIN
                (
                    SELECT pri_tbprice,
                           pri_perqty,
                           pri_customerid,
                           pri_assy
                    FROM TEST.dbo.pri WITH (NOLOCK)
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
            SELECT SUM(p.pri_cost) / SUM(p.pri_perqty) AS a1,
                   p.pri_customerid,
                   p.pri_assy
            FROM TEST.dbo.pri AS p WITH (NOLOCK)
                JOIN #changed_y1_groups AS g
                    ON g.pri_customerid = p.pri_customerid
                   AND g.pri_assy = p.pri_assy
            WHERE p.pri_newcostchk = 'Y1'
              AND SUBSTRING(p.pri_part, 1, 2) NOT IN ('不良', '加工', '編織')
            GROUP BY p.pri_customerid,
                     p.pri_assy
        ) AS c2
            ON c2.pri_customerid = c.pri_customerid
           AND c2.pri_assy = c.pri_assy
        LEFT JOIN
        (
            SELECT SUM(p.pri_cost) AS cost,
                   p.pri_customerid,
                   p.pri_assy
            FROM TEST.dbo.pri AS p WITH (NOLOCK)
                JOIN #changed_y1_groups AS g
                    ON g.pri_customerid = p.pri_customerid
                   AND g.pri_assy = p.pri_assy
            WHERE LEFT(p.pri_part, 2) = '加工'
              AND p.pri_newcostchk = 'Y1'
            GROUP BY p.pri_customerid,
                     p.pri_assy
        ) AS c3
            ON c3.pri_customerid = c.pri_customerid
           AND c3.pri_assy = c.pri_assy
        LEFT JOIN
        (
            SELECT SUM(p.pri_cost) AS cost,
                   p.pri_customerid,
                   p.pri_assy
            FROM TEST.dbo.pri AS p WITH (NOLOCK)
                JOIN #changed_y1_groups AS g
                    ON g.pri_customerid = p.pri_customerid
                   AND g.pri_assy = p.pri_assy
            WHERE LEFT(p.pri_part, 2) = '編織'
              AND p.pri_newcostchk = 'Y1'
            GROUP BY p.pri_customerid,
                     p.pri_assy
        ) AS c4
            ON c4.pri_customerid = c.pri_customerid
           AND c4.pri_assy = c.pri_assy
    WHERE c.pri_newcostchk = 'Y1'
) AS ab,
TEST.dbo.pri AS ac
WHERE ac.pri_newcostchk = 'Y1'
  AND ac.pri_customerid = ab.pri_customerid
  AND ac.pri_assy = ab.pri_assy
  AND ac.pri_clcost <> ROUND(ab.material_cost, 6)
OPTION (RECOMPILE);

SELECT 'step3_only_changed_groups' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;
