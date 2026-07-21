USE [Price]
GO

SET NOCOUNT ON;

-------------------------------------------------------------------------------
-- run_updatepriclcost2_skip_asp
--
-- Purpose:
--   Backfill the same cost calculation logic as dbo.updatepriclcost2,
--   but intentionally skip the UPDATE asp statement to avoid firing asp triggers.
--
-- Kept from dbo.updatepriclcost2:
--   1. Y2 normal pri_cost
--   2. Y2 bad-rate pri_cost
--   3. Y2 "才" pri_cost
--   4. Y2 pri_clcost
--   5. Y2 aspnum
--
-- Skipped:
--   UPDATE asp SET asp_location = 'S', asp_purprice = ...
-------------------------------------------------------------------------------

DECLARE @fmtdate VARCHAR(19);
DECLARE @step_start DATETIME2(3);
DECLARE @rows INT;

SET @fmtdate = CONVERT(VARCHAR(4), DATEPART(yyyy, GETDATE())) + '/'
             + CONVERT(VARCHAR(2), DATEPART(mm, GETDATE())) + '/'
             + CONVERT(VARCHAR(2), DATEPART(dd, GETDATE())) + ' '
             + CONVERT(VARCHAR(2), DATEPART(hh, GETDATE())) + ':'
             + CONVERT(VARCHAR(2), DATEPART(mi, GETDATE())) + ':'
             + CONVERT(VARCHAR(2), DATEPART(ss, GETDATE()));

SELECT 'run_updatepriclcost2_skip_asp_start' AS step_name,
       @fmtdate AS fmtdate,
       SYSDATETIME() AS run_time;

-------------------------------------------------------------------------------
-- Preflight: asp / aspnum are keyed by customer + assy, so every Y2 key must
-- resolve to exactly one six-decimal pri_clcost (NULL is also a distinct state).
-- Abort before making any changes when the source is ambiguous.
-------------------------------------------------------------------------------
IF EXISTS
(
    SELECT 1
    FROM pri
    WHERE pri_newcostchk = 'Y2'
    GROUP BY pri_customerid, pri_assy
    HAVING COUNT(DISTINCT ROUND(pri_clcost, 6)) > 1
        OR
        (
            COUNT(pri_clcost) > 0
            AND COUNT(pri_clcost) < COUNT(*)
        )
)
BEGIN
    SELECT pri_customerid,
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
        OR
        (
            COUNT(pri_clcost) > 0
            AND COUNT(pri_clcost) < COUNT(*)
        )
    ORDER BY pri_customerid, pri_assy;

    RAISERROR (
        'Recovery aborted: one or more Y2 customer/assy keys have ambiguous pri_clcost values.',
        16,
        1
    );
    RETURN;
END;

-------------------------------------------------------------------------------
-- 1. Same as updatepriclcost2: Y2 normal pri_cost
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

UPDATE pri
SET pri_cost = ROUND(pri_tbprice * pri_perqty, 6),
    pri_costflag = 'Y'
WHERE pri_cost <> ROUND(pri_tbprice * pri_perqty, 6)
  AND LEFT(pri_part, 3) <> '不良率'
  AND LEFT(pri_part, 2) <> '佣金'
  AND LEFT(pri_firstname, 1) <> '其'
  AND RIGHT(pri_part, 1) <> '才'
  AND pri_newcostchk = 'Y2';

SET @rows = @@ROWCOUNT;
SELECT 'step1_pri_cost' AS step_name,
       @rows AS affected_rows,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 2. Same as updatepriclcost2: Y2 bad-rate pri_cost
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

UPDATE pri
SET pri_cost = ROUND(c.qt * pri_tbprice * pri_perqty, 6),
    pri_costflag = 'Y'
FROM
(
    SELECT a.nbr AS ab,
           b.qty AS qt
    FROM
    (
        SELECT pri_nbr AS nbr,
               pri_assy,
               pri_date,
               pri_customer,
               pri_length,
               pri_customerid
        FROM pri
        WHERE LEFT(pri_part, 3) = '不良率'
          AND pri_newcostchk = 'Y2'
    ) AS a
    LEFT OUTER JOIN
    (
        SELECT pri_assy,
               pri_date,
               pri_customer,
               pri_length,
               pri_customerid,
               SUM(pri_cost) AS qty
        FROM pri
        WHERE LEFT(pri_part, 1) NOT IN ('包', '裝', '運', '不', '調')
          AND RIGHT(pri_part, 1) <> '才'
          AND pri_newcostchk = 'Y2'
        GROUP BY pri_assy,
                 pri_date,
                 pri_customer,
                 pri_length,
                 pri_customerid
    ) AS b
        ON a.pri_assy = b.pri_assy
       AND a.pri_date = b.pri_date
       AND a.pri_customer = b.pri_customer
       AND a.pri_length = b.pri_length
       AND a.pri_customerid = b.pri_customerid
) AS c,
pri
WHERE pri_nbr = c.ab
  AND ROUND(pri_cost, 6) <> ROUND(c.qt * pri_tbprice * pri_perqty, 6)
  AND pri_newcostchk = 'Y2';

SET @rows = @@ROWCOUNT;
SELECT 'step2_bad_rate' AS step_name,
       @rows AS affected_rows,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 3. Same as updatepriclcost2: Y2 "才" pri_cost
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

UPDATE pri
SET pri_cost = ROUND(pri_tbprice / pri_perqty, 6)
WHERE RIGHT(pri_part, 1) = '才'
  AND pri_newcostchk = 'Y2'
  AND pri_cost <> ROUND(pri_tbprice / pri_perqty, 6);

SET @rows = @@ROWCOUNT;
SELECT 'step3_cai' AS step_name,
       @rows AS affected_rows,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 4. Same as updatepriclcost2: Y2 pri_clcost
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

UPDATE pri
SET pri_clcost = ROUND(c.ccost, 6),
    pri_costflag = 'N'
FROM
(
    SELECT a.pri_nbr AS nbr,
           CASE
               WHEN a.pri_um = 'Feet'
                AND a.pri_newcostchk = 'Y2'
                   THEN b.cost / 3.28084
               ELSE b.cost
           END AS ccost
    FROM pri AS a
    LEFT OUTER JOIN
    (
        SELECT pri_assy AS assy,
               pri_customer AS customer,
               pri_date AS dat,
               pri_length AS length,
               pri_customerid AS customerid,
               SUM(pri_cost) AS cost
        FROM pri WITH (NOLOCK)
        GROUP BY pri_assy,
                 pri_customer,
                 pri_date,
                 pri_length,
                 pri_customerid
    ) AS b
        ON a.pri_assy = b.assy
       AND a.pri_customer = b.customer
       AND a.pri_date = b.dat
       AND a.pri_length = b.length
       AND a.pri_customerid = b.customerid
       AND pri_newcostchk = 'Y2'
) AS c,
pri
WHERE c.nbr = pri_nbr
  AND pri_newcostchk = 'Y2'
  AND pri_clcost <> ROUND(c.ccost, 6);

SET @rows = @@ROWCOUNT;
SELECT 'step4_pri_clcost' AS step_name,
       @rows AS affected_rows,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- 5. Skipped from updatepriclcost2 on purpose:
-- UPDATE asp
-- SET asp_location = 'S',
--     asp_purprice = ROUND(a01.pri_clcost, 6),
--     asp_pricecal = LTRIM(STR(ROUND(a01.pri_clcost, 6), 100, 6)),
--     asp_currency = '臺幣',
--     asp_user = '系統更新'
-- FROM (SELECT DISTINCT pri_customerid, pri_assy, pri_clcost
--       FROM pri
--       WHERE pri_newcostchk = 'Y2') AS a01,
--      asp
-- WHERE asp_id = a01.pri_customerid
--   AND asp_vendormaterialno = a01.pri_assy
--   AND a01.pri_clcost <> asp_purprice;
-------------------------------------------------------------------------------
SELECT 'step5_asp_skipped' AS step_name,
       0 AS affected_rows,
       'Skipped intentionally to avoid asp trigger' AS note;

-------------------------------------------------------------------------------
-- 6. Same as updatepriclcost2: Y2 aspnum
-------------------------------------------------------------------------------
SET @step_start = SYSDATETIME();

UPDATE aspnum
SET aspnum_price = ROUND(a01.pri_clcost, 6),
    aspnum_pricecal = LTRIM(STR(ROUND(a01.pri_clcost, 6), 100, 6)),
    aspnum_currency = '臺幣'
FROM
(
    SELECT DISTINCT pri_customerid,
           pri_assy,
           pri_clcost
    FROM pri
    WHERE pri_newcostchk = 'Y2'
) AS a01,
aspnum
WHERE aspnum_id = a01.pri_customerid
  AND aspnum_num = a01.pri_assy
  AND
  (
      ROUND(a01.pri_clcost, 6) <> ROUND(aspnum_price, 6)
      OR (a01.pri_clcost IS NULL AND aspnum_price IS NOT NULL)
      OR (a01.pri_clcost IS NOT NULL AND aspnum_price IS NULL)
  );

SET @rows = @@ROWCOUNT;
SELECT 'step6_aspnum' AS step_name,
       @rows AS affected_rows,
       DATEDIFF(MILLISECOND, @step_start, SYSDATETIME()) / 1000.0 AS elapsed_sec;

-------------------------------------------------------------------------------
-- Remaining checks for the same updated targets.
-------------------------------------------------------------------------------
SELECT 'remaining_pri_cost' AS item,
       COUNT(*) AS rows_count
FROM pri WITH (NOLOCK)
WHERE pri_cost <> ROUND(pri_tbprice * pri_perqty, 6)
  AND LEFT(pri_part, 3) <> '不良率'
  AND LEFT(pri_part, 2) <> '佣金'
  AND LEFT(pri_firstname, 1) <> '其'
  AND RIGHT(pri_part, 1) <> '才'
  AND pri_newcostchk = 'Y2'

UNION ALL

SELECT 'remaining_bad_rate',
       COUNT(*)
FROM
(
    SELECT a.nbr AS ab,
           b.qty AS qt
    FROM
    (
        SELECT pri_nbr AS nbr,
               pri_assy,
               pri_date,
               pri_customer,
               pri_length,
               pri_customerid
        FROM pri WITH (NOLOCK)
        WHERE LEFT(pri_part, 3) = '不良率'
          AND pri_newcostchk = 'Y2'
    ) AS a
    LEFT OUTER JOIN
    (
        SELECT pri_assy,
               pri_date,
               pri_customer,
               pri_length,
               pri_customerid,
               SUM(pri_cost) AS qty
        FROM pri WITH (NOLOCK)
        WHERE LEFT(pri_part, 1) NOT IN ('包', '裝', '運', '不', '調')
          AND RIGHT(pri_part, 1) <> '才'
          AND pri_newcostchk = 'Y2'
        GROUP BY pri_assy,
                 pri_date,
                 pri_customer,
                 pri_length,
                 pri_customerid
    ) AS b
        ON a.pri_assy = b.pri_assy
       AND a.pri_date = b.pri_date
       AND a.pri_customer = b.pri_customer
       AND a.pri_length = b.pri_length
       AND a.pri_customerid = b.pri_customerid
) AS c
JOIN pri WITH (NOLOCK)
    ON pri.pri_nbr = c.ab
WHERE ROUND(pri.pri_cost, 6) <> ROUND(c.qt * pri.pri_tbprice * pri.pri_perqty, 6)
  AND pri.pri_newcostchk = 'Y2'

UNION ALL

SELECT 'remaining_cai',
       COUNT(*)
FROM pri WITH (NOLOCK)
WHERE RIGHT(pri_part, 1) = '才'
  AND pri_newcostchk = 'Y2'
  AND pri_cost <> ROUND(pri_tbprice / pri_perqty, 6)

UNION ALL

SELECT 'remaining_aspnum',
       COUNT(*)
FROM
(
    SELECT DISTINCT pri_customerid,
           pri_assy,
           pri_clcost
    FROM pri WITH (NOLOCK)
    WHERE pri_newcostchk = 'Y2'
) AS a01
LEFT JOIN aspnum WITH (NOLOCK)
    ON aspnum_id = a01.pri_customerid
   AND aspnum_num = a01.pri_assy
WHERE aspnum_id IS NULL
   OR ROUND(a01.pri_clcost, 6) <> ROUND(aspnum_price, 6)
   OR (a01.pri_clcost IS NULL AND aspnum_price IS NOT NULL)
   OR (a01.pri_clcost IS NOT NULL AND aspnum_price IS NULL);

SELECT 'run_updatepriclcost2_skip_asp_end' AS step_name,
       SYSDATETIME() AS run_time;
