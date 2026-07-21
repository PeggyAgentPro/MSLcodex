# 專案交接紀錄

更新日期：2026-07-21

## 目前狀態

- SQL Server 成本更新事故已完成恢復，最終驗證為 `asp = 0`、`aspnum = 0`。
- Git 分支為 `main`，本機比 `origin/main` 多 2 個 commit，尚未 push。
- 工作區正在修正驗證 JOIN、來源價格唯一性防護及交接狀態，尚未 commit。
- `asp`／`aspnum` 驗證改用 `LEFT JOIN`，缺少目標列也會列為不同步。
- recovery script 在任何更新前檢查同一 Y2 `(pri_customerid, pri_assy)` 是否存在多個六位小數價格；有衝突即列出明細並中止。

## 未完成工作

- 審查並驗證本次 JOIN、來源唯一性與文件狀態修正。
- 若能連線生產資料庫，將 recovery script 與實際 `dbo.updatepriclcost2` 再比對一次。

## 阻斷與注意事項

- 未經使用者確認，不執行 Git commit、push 或 pull。

## 下次開工

1. 在測試或生產唯讀查詢確認 Y2 每個 `(pri_customerid, pri_assy)` 的價格唯一性。
2. 若可連線生產資料庫，將 recovery script 與實際 `dbo.updatepriclcost2` 比對。
3. 確認本次差異後，再由使用者決定是否 commit 與 push。
