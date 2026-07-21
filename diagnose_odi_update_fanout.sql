USE Price;
GO

SET NOCOUNT ON;

-------------------------------------------------------------------------------
-- diagnose_odi_update_fanout
-- 目的：
--   成本更新卡在 dbo.odi_update_copy2 trigger 時，找出 updatepriclcost
--   裡三段 UPDATE odi 是否因 pri_aspupdate1 / odi join 放大。
--
-- 重點：
--   updatepriclcost 的 odi 更新條件只用 odi_customerid = pri_customerid，
--   如果 pri_aspupdate1 同一個 pri_customerid 有很多筆，且 odi 同客戶也很多筆，
--   join 結果會被放大，trigger 也會跟著被大量觸發。
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- 1. 三段 UPDATE odi 預計會 join / 更新多少列
-------------------------------------------------------------------------------
SELECT 'odi_4' AS step_name,
       COUNT_BIG(*) AS join_rows,
       COUNT(DISTINCT odi.odi_nbr) AS distinct_odi_rows,
       COUNT(DISTINCT pri_aspupdate1.pri_customerid) AS distinct_customerid
FROM odi WITH (NOLOCK)
JOIN pri_aspupdate1 WITH (NOLOCK)
    ON odi.odi_customerid = pri_aspupdate1.pri_customerid
WHERE pri_aspupdate1.pri_customer = '4'
  AND odi.odi_price <> pri_aspupdate1.pri_convcost

UNION ALL

SELECT 'odi_4_dash' AS step_name,
       COUNT_BIG(*) AS join_rows,
       COUNT(DISTINCT odi.odi_nbr) AS distinct_odi_rows,
       COUNT(DISTINCT pri_aspupdate1.pri_customerid) AS distinct_customerid
FROM odi WITH (NOLOCK)
JOIN pri_aspupdate1 WITH (NOLOCK)
    ON odi.odi_customerid = pri_aspupdate1.pri_customerid
WHERE SUBSTRING(pri_aspupdate1.pri_customer, 1, 2) = '4-'
  AND odi.odi_price <> pri_aspupdate1.pri_convcost

UNION ALL

SELECT 'odi_other' AS step_name,
       COUNT_BIG(*) AS join_rows,
       COUNT(DISTINCT odi.odi_nbr) AS distinct_odi_rows,
       COUNT(DISTINCT pri_aspupdate1.pri_customerid) AS distinct_customerid
FROM odi WITH (NOLOCK)
JOIN pri_aspupdate1 WITH (NOLOCK)
    ON odi.odi_customerid = pri_aspupdate1.pri_customerid
WHERE odi.odi_customer <> '4'
  AND SUBSTRING(odi.odi_customer, 1, 2) <> '4-'
  AND odi.odi_price <> pri_aspupdate1.pri_pricost;

-------------------------------------------------------------------------------
-- 2. 找 join 放大最大的客戶/材料
-------------------------------------------------------------------------------
SELECT TOP 50
       'odi_4' AS step_name,
       p.pri_customerid,
       COUNT_BIG(*) AS join_rows,
       COUNT(DISTINCT o.odi_nbr) AS odi_rows,
       COUNT(DISTINCT p.pri_assy) AS pri_assy_count,
       COUNT(DISTINCT p.pri_convcost) AS distinct_convcost,
       MIN(p.pri_convcost) AS min_convcost,
       MAX(p.pri_convcost) AS max_convcost
FROM odi AS o WITH (NOLOCK)
JOIN pri_aspupdate1 AS p WITH (NOLOCK)
    ON o.odi_customerid = p.pri_customerid
WHERE p.pri_customer = '4'
  AND o.odi_price <> p.pri_convcost
GROUP BY p.pri_customerid
ORDER BY join_rows DESC;

SELECT TOP 50
       'odi_4_dash' AS step_name,
       p.pri_customerid,
       COUNT_BIG(*) AS join_rows,
       COUNT(DISTINCT o.odi_nbr) AS odi_rows,
       COUNT(DISTINCT p.pri_assy) AS pri_assy_count,
       COUNT(DISTINCT p.pri_convcost) AS distinct_convcost,
       MIN(p.pri_convcost) AS min_convcost,
       MAX(p.pri_convcost) AS max_convcost
FROM odi AS o WITH (NOLOCK)
JOIN pri_aspupdate1 AS p WITH (NOLOCK)
    ON o.odi_customerid = p.pri_customerid
WHERE SUBSTRING(p.pri_customer, 1, 2) = '4-'
  AND o.odi_price <> p.pri_convcost
GROUP BY p.pri_customerid
ORDER BY join_rows DESC;

SELECT TOP 50
       'odi_other' AS step_name,
       p.pri_customerid,
       COUNT_BIG(*) AS join_rows,
       COUNT(DISTINCT o.odi_nbr) AS odi_rows,
       COUNT(DISTINCT p.pri_assy) AS pri_assy_count,
       COUNT(DISTINCT p.pri_pricost) AS distinct_pricost,
       MIN(p.pri_pricost) AS min_pricost,
       MAX(p.pri_pricost) AS max_pricost
FROM odi AS o WITH (NOLOCK)
JOIN pri_aspupdate1 AS p WITH (NOLOCK)
    ON o.odi_customerid = p.pri_customerid
WHERE o.odi_customer <> '4'
  AND SUBSTRING(o.odi_customer, 1, 2) <> '4-'
  AND o.odi_price <> p.pri_pricost
GROUP BY p.pri_customerid
ORDER BY join_rows DESC;

-------------------------------------------------------------------------------
-- 3. 檢查 pri_aspupdate1 是否同一 pri_customerid 有多筆不同成本
--    這會讓 odi 用 customerid join 時產生不確定/大量更新。
-------------------------------------------------------------------------------
SELECT TOP 100
       pri_customerid,
       COUNT(*) AS view_rows,
       COUNT(DISTINCT pri_assy) AS assy_count,
       COUNT(DISTINCT pri_convcost) AS distinct_convcost,
       COUNT(DISTINCT pri_pricost) AS distinct_pricost,
       MIN(pri_convcost) AS min_convcost,
       MAX(pri_convcost) AS max_convcost,
       MIN(pri_pricost) AS min_pricost,
       MAX(pri_pricost) AS max_pricost
FROM pri_aspupdate1 WITH (NOLOCK)
GROUP BY pri_customerid
HAVING COUNT(*) > 1
    OR COUNT(DISTINCT pri_convcost) > 1
    OR COUNT(DISTINCT pri_pricost) > 1
ORDER BY view_rows DESC, distinct_convcost DESC, distinct_pricost DESC;

-------------------------------------------------------------------------------
-- 4. 若昨天有材料異動，先用 pri 的日期欄位抓 2026-06-30 異動群組
--    視實際欄位意義，可改 pri_newdate / pri_confirmdate / pri_verifydate。
-------------------------------------------------------------------------------
DECLARE @changed_date DATE = '2026-06-30';

SELECT TOP 100
       pri_customerid,
       pri_assy,
       COUNT(*) AS pri_rows,
       MIN(pri_newdate) AS min_newdate,
       MAX(pri_newdate) AS max_newdate,
       MIN(pri_confirmdate) AS min_confirmdate,
       MAX(pri_confirmdate) AS max_confirmdate,
       MIN(pri_verifydate) AS min_verifydate,
       MAX(pri_verifydate) AS max_verifydate,
       COUNT(DISTINCT pri_part) AS part_count
FROM pri WITH (NOLOCK)
WHERE
    CONVERT(DATE, pri_newdate) = @changed_date
    OR CONVERT(DATE, pri_confirmdate) = @changed_date
    OR CONVERT(DATE, pri_verifydate) = @changed_date
GROUP BY pri_customerid, pri_assy
ORDER BY pri_rows DESC;
