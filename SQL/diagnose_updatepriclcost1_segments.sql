USE TEST;
GO

SET NOCOUNT ON;

DECLARE @t DATETIME2(3);
DECLARE @step_start DATETIME2(3);
DECLARE @proc_start DATETIME2(3) = SYSDATETIME();

PRINT 'diagnose_updatepriclcost1_segments start: ' + CONVERT(VARCHAR(30), @proc_start, 121);

-------------------------------------------------------------------------------
-- Step 1: 更新材料單單身成本
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step1_rows
FROM pri
WHERE pri_cost <> ROUND(pri_tbprice * pri_perqty, 6)
      AND LEFT(pri_part, 3) <> '不良率'
      AND LEFT(pri_part, 2) <> '佣金'
      AND LEFT(pri_firstname, 1) <> '其'
      AND RIGHT(pri_part, 1) <> '才'
      AND pri_newcostchk = 'Y1';

SELECT 'step1_base_cost' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Step 2: 更新不良率金額
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step2_rows
FROM
(
    SELECT a.pri_customerid,
           a.pri_assy,
           ROUND(SUM(a.pri_cost) * b.pri_tbprice * b.pri_perqty, 6) AS clsum
    FROM pri AS a WITH (NOLOCK)
        LEFT JOIN
        (
            SELECT pri_tbprice,
                   pri_perqty,
                   pri_customerid,
                   pri_assy
            FROM pri WITH (NOLOCK)
            WHERE LEFT(pri_part, 3) = '不良率'
                  AND pri_newcostchk = 'Y1'
        ) AS b
            ON a.pri_customerid = b.pri_customerid
           AND a.pri_assy = b.pri_assy
    WHERE a.pri_newcostchk = 'Y1'
          AND LEFT(a.pri_part, 3) <> '不良率'
    GROUP BY a.pri_customerid,
             a.pri_assy,
             b.pri_tbprice,
             b.pri_perqty
) AS aa,
pri AS bb
WHERE LEFT(bb.pri_part, 3) = '不良率'
      AND bb.pri_newcostchk = 'Y1'
      AND bb.pri_customerid = aa.pri_customerid
      AND bb.pri_assy = aa.pri_assy
      AND aa.clsum <> bb.pri_cost;

SELECT 'step2_bad_rate_cost' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Step 3: 更新材料價 pri_clcost
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step3_rows
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
) AS ab,
pri AS ac
WHERE ac.pri_newcostchk = 'Y1'
      AND ac.pri_customerid = ab.pri_customerid
      AND ac.pri_assy = ab.pri_assy
      AND ac.pri_clcost <> ROUND(ab.material_cost, 6);

SELECT 'step3_material_clcost' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Step 3A: 拆解 Step 3 的 c1 不良率彙總
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step3_c1_groups
FROM
(
    SELECT a.pri_customerid,
           a.pri_assy,
           b.pri_tbprice,
           b.pri_perqty,
           SUM(a.pri_cost) * b.pri_tbprice * b.pri_perqty AS clsum
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
) AS x;

SELECT 'step3a_c1_bad_rate_group' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Step 3B: 拆解 Step 3 的 c2 一般材料彙總
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step3_c2_groups
FROM
(
    SELECT pri_customerid,
           pri_assy,
           SUM(pri_cost) / SUM(pri_perqty) AS a1
    FROM pri WITH (NOLOCK)
    WHERE pri_newcostchk = 'Y1'
          AND SUBSTRING(pri_part, 1, 2) NOT IN ('不良', '加工', '編織')
    GROUP BY pri_customerid,
             pri_assy
) AS x;

SELECT 'step3b_c2_normal_group' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Step 3C: 拆解 Step 3 的 c3 加工彙總
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step3_c3_groups
FROM
(
    SELECT pri_customerid,
           pri_assy,
           SUM(pri_cost) AS cost
    FROM pri WITH (NOLOCK)
    WHERE LEFT(pri_part, 2) = '加工'
          AND pri_newcostchk = 'Y1'
    GROUP BY pri_customerid,
             pri_assy
) AS x;

SELECT 'step3c_c3_process_group' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Step 3D: 拆解 Step 3 的 c4 編織彙總
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step3_c4_groups
FROM
(
    SELECT pri_customerid,
           pri_assy,
           SUM(pri_cost) AS cost
    FROM pri WITH (NOLOCK)
    WHERE LEFT(pri_part, 2) = '編織'
          AND pri_newcostchk = 'Y1'
    GROUP BY pri_customerid,
             pri_assy
) AS x;

SELECT 'step3d_c4_weave_group' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Step 4: 更新 asp 火車頭單價
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step4_rows
FROM
(
    SELECT DISTINCT
           pri_customerid,
           pri_assy,
           pri_clcost
    FROM pri
    WHERE pri_newcostchk = 'Y1'
) AS a01,
asp
WHERE asp_id = a01.pri_customerid
      AND asp_vendormaterialno = a01.pri_assy
      AND a01.pri_clcost <> asp_purprice;

SELECT 'step4_update_asp' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Step 5: 更新 aspnum 火車頭內層單價
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

SELECT COUNT(*) AS step5_rows
FROM
(
    SELECT DISTINCT
           pri_customerid,
           pri_assy,
           pri_clcost
    FROM pri
    WHERE pri_newcostchk = 'Y1'
) AS a02,
aspnum
WHERE aspnum_id = a02.pri_customerid
      AND aspnum_num = a02.pri_assy
      AND a02.pri_clcost <> aspnum_price;

SELECT 'step5_update_aspnum' AS step_name,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

SELECT 'total' AS step_name,
       DATEDIFF(MILLISECOND, @proc_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

PRINT 'diagnose_updatepriclcost1_segments end: ' + CONVERT(VARCHAR(30), SYSDATETIME(), 121);
