USE TEST;
GO

SET NOCOUNT ON;
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

DECLARE @proc_start DATETIME2(3) = SYSDATETIME();
DECLARE @step_start DATETIME2(3);

DECLARE @msg VARCHAR(200);

SET @msg = 'step3 deep diagnose start: ' + CONVERT(VARCHAR(30), @proc_start, 121);
RAISERROR(@msg, 0, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#c') IS NOT NULL DROP TABLE #c;
IF OBJECT_ID('tempdb..#c1') IS NOT NULL DROP TABLE #c1;
IF OBJECT_ID('tempdb..#c2') IS NOT NULL DROP TABLE #c2;
IF OBJECT_ID('tempdb..#c3') IS NOT NULL DROP TABLE #c3;
IF OBJECT_ID('tempdb..#c4') IS NOT NULL DROP TABLE #c4;
IF OBJECT_ID('tempdb..#ab') IS NOT NULL DROP TABLE #ab;

-------------------------------------------------------------------------------
-- 1. Step 3 main source: c
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();
RAISERROR('build #c', 0, 1) WITH NOWAIT;

SELECT pri_customerid,
       pri_assy,
       pri_um
INTO #c
FROM pri WITH (NOLOCK)
WHERE pri_newcostchk = 'Y1';

CREATE INDEX IX_c ON #c (pri_customerid, pri_assy);

SELECT 'c_rows' AS item,
       COUNT(*) AS rows_count,
       COUNT(DISTINCT pri_customerid + '|' + pri_assy) AS group_count
FROM #c;

SELECT TOP 50
       pri_customerid,
       pri_assy,
       COUNT(*) AS c_rows,
       COUNT(DISTINCT pri_um) AS distinct_um
FROM #c
GROUP BY pri_customerid, pri_assy
HAVING COUNT(DISTINCT pri_um) > 1
ORDER BY c_rows DESC;

SELECT 'build_c' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 2. Step 3 c1: bad-rate aggregate
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();
RAISERROR('build #c1', 0, 1) WITH NOWAIT;

SELECT SUM(a.pri_cost) * b.pri_tbprice * b.pri_perqty AS clsum,
       a.pri_customerid,
       a.pri_assy
INTO #c1
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
OPTION (RECOMPILE);

CREATE INDEX IX_c1 ON #c1 (pri_customerid, pri_assy);

SELECT 'c1_rows' AS item,
       COUNT(*) AS rows_count,
       COUNT(DISTINCT pri_customerid + '|' + pri_assy) AS group_count
FROM #c1;

SELECT TOP 50
       pri_customerid,
       pri_assy,
       COUNT(*) AS c1_rows,
       COUNT(DISTINCT ROUND(clsum, 6)) AS distinct_clsum
FROM #c1
GROUP BY pri_customerid, pri_assy
HAVING COUNT(*) > 1
ORDER BY c1_rows DESC;

SELECT 'build_c1_bad_rate' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 3. Step 3 c2: normal material aggregate
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();
RAISERROR('build #c2', 0, 1) WITH NOWAIT;

SELECT SUM(pri_cost) / SUM(pri_perqty) AS a1,
       pri_customerid,
       pri_assy
INTO #c2
FROM pri WITH (NOLOCK)
WHERE pri_newcostchk = 'Y1'
      AND SUBSTRING(pri_part, 1, 2) NOT IN ('不良', '加工', '編織')
GROUP BY pri_customerid,
         pri_assy
OPTION (RECOMPILE);

CREATE INDEX IX_c2 ON #c2 (pri_customerid, pri_assy);

SELECT 'c2_rows' AS item,
       COUNT(*) AS rows_count,
       COUNT(DISTINCT pri_customerid + '|' + pri_assy) AS group_count
FROM #c2;

SELECT 'build_c2_normal' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 4. Step 3 c3: process aggregate
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();
RAISERROR('build #c3', 0, 1) WITH NOWAIT;

SELECT SUM(pri_cost) AS cost,
       pri_customerid,
       pri_assy
INTO #c3
FROM pri WITH (NOLOCK)
WHERE LEFT(pri_part, 2) = '加工'
      AND pri_newcostchk = 'Y1'
GROUP BY pri_customerid,
         pri_assy
OPTION (RECOMPILE);

CREATE INDEX IX_c3 ON #c3 (pri_customerid, pri_assy);

SELECT 'c3_rows' AS item,
       COUNT(*) AS rows_count,
       COUNT(DISTINCT pri_customerid + '|' + pri_assy) AS group_count
FROM #c3;

SELECT 'build_c3_process' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 5. Step 3 c4: weave aggregate
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();
RAISERROR('build #c4', 0, 1) WITH NOWAIT;

SELECT SUM(pri_cost) AS cost,
       pri_customerid,
       pri_assy
INTO #c4
FROM pri WITH (NOLOCK)
WHERE LEFT(pri_part, 2) = '編織'
      AND pri_newcostchk = 'Y1'
GROUP BY pri_customerid,
         pri_assy
OPTION (RECOMPILE);

CREATE INDEX IX_c4 ON #c4 (pri_customerid, pri_assy);

SELECT 'c4_rows' AS item,
       COUNT(*) AS rows_count,
       COUNT(DISTINCT pri_customerid + '|' + pri_assy) AS group_count
FROM #c4;

SELECT 'build_c4_weave' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 6. Build ab only. If this is fast, the slow point is the final join/update.
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();
RAISERROR('build #ab', 0, 1) WITH NOWAIT;

SELECT DISTINCT
       c.pri_customerid,
       c.pri_assy,
       CASE
           WHEN c.pri_um = 'Feet' THEN
               (c1.clsum + c2.a1 + c3.cost + c4.cost) / 3.28084
           ELSE
               (c1.clsum + c2.a1 + c3.cost + c4.cost)
       END AS material_cost
INTO #ab
FROM #c AS c
    LEFT JOIN #c1 AS c1
        ON c1.pri_customerid = c.pri_customerid
       AND c1.pri_assy = c.pri_assy
    LEFT JOIN #c2 AS c2
        ON c2.pri_customerid = c.pri_customerid
       AND c2.pri_assy = c.pri_assy
    LEFT JOIN #c3 AS c3
        ON c3.pri_customerid = c.pri_customerid
       AND c3.pri_assy = c.pri_assy
    LEFT JOIN #c4 AS c4
        ON c4.pri_customerid = c.pri_customerid
       AND c4.pri_assy = c.pri_assy
OPTION (RECOMPILE);

CREATE INDEX IX_ab ON #ab (pri_customerid, pri_assy);

SELECT 'ab_rows' AS item,
       COUNT(*) AS rows_count,
       COUNT(DISTINCT pri_customerid + '|' + pri_assy) AS group_count
FROM #ab;

SELECT TOP 50
       pri_customerid,
       pri_assy,
       COUNT(*) AS ab_rows,
       COUNT(DISTINCT ROUND(material_cost, 6)) AS distinct_material_cost,
       MIN(material_cost) AS min_material_cost,
       MAX(material_cost) AS max_material_cost
FROM #ab
GROUP BY pri_customerid, pri_assy
HAVING COUNT(*) > 1
    OR COUNT(DISTINCT ROUND(material_cost, 6)) > 1
ORDER BY ab_rows DESC;

SELECT 'build_ab' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 7. Final join count. If this is slow, it is the join back to pri/ac.
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();
RAISERROR('final join count', 0, 1) WITH NOWAIT;

SELECT COUNT(*) AS final_join_rows
FROM #ab AS ab
    INNER JOIN pri AS ac WITH (NOLOCK)
        ON ac.pri_customerid = ab.pri_customerid
       AND ac.pri_assy = ab.pri_assy
WHERE ac.pri_newcostchk = 'Y1'
      AND ac.pri_clcost <> ROUND(ab.material_cost, 6)
OPTION (RECOMPILE);

SELECT 'final_join_count' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 8. Same final join, but force hash join. Compare with step 7.
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();
RAISERROR('final join count HASH JOIN', 0, 1) WITH NOWAIT;

SELECT COUNT(*) AS final_join_rows_hash_join
FROM #ab AS ab
    INNER HASH JOIN pri AS ac WITH (NOLOCK)
        ON ac.pri_customerid = ab.pri_customerid
       AND ac.pri_assy = ab.pri_assy
WHERE ac.pri_newcostchk = 'Y1'
      AND ac.pri_clcost <> ROUND(ab.material_cost, 6)
OPTION (RECOMPILE);

SELECT 'final_join_count_hash_join' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

SELECT 'total' AS step_name,
       DATEDIFF(MILLISECOND, @proc_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

RAISERROR('step3 deep diagnose end', 0, 1) WITH NOWAIT;
