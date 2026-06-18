USE TEST;
GO

SET NOCOUNT ON;
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

DECLARE @step_start DATETIME2(3);
DECLARE @row_count INT;

-------------------------------------------------------------------------------
-- Probe 1: trigger baseline.
-- SQL Server DML trigger may fire even when an UPDATE affects 0 rows.
-- This test is wrapped in a transaction and rolled back.
-------------------------------------------------------------------------------
PRINT 'Probe 1: empty UPDATE trigger baseline';
SET @step_start = SYSDATETIME();

BEGIN TRAN;

UPDATE pri
SET pri_costflag = pri_costflag
WHERE 1 = 0;

SET @row_count = @@ROWCOUNT;

ROLLBACK TRAN;

SELECT 'probe1_empty_update' AS probe_name,
       @row_count AS affected_rows,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Probe 2: original Step 3 UPDATE, but with OPTION (RECOMPILE).
-- Wrapped in a transaction and rolled back.
-------------------------------------------------------------------------------
PRINT 'Probe 2: original Step 3 UPDATE with OPTION(RECOMPILE), rollback after test';
SET @step_start = SYSDATETIME();

BEGIN TRAN;

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
      AND ac.pri_clcost <> ROUND(ab.材料價, 6)
OPTION (RECOMPILE);

SET @row_count = @@ROWCOUNT;

ROLLBACK TRAN;

SELECT 'probe2_original_step3_recompile' AS probe_name,
       @row_count AS affected_rows,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;
