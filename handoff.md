# 專案交接紀錄

更新日期：2026-07-21

## 目前狀態

- SQL Server 成本更新事故已完成恢復，最終驗證為 `asp = 0`、`aspnum = 0`。
- Git 分支為 `main`，與 `origin/main` 同步。
- 已暫存 5 個新檔案，尚未 commit 或 push。
- `updatepriclcost_deadlock_manual_recovery_sop.md` 同時有未暫存的新版修訂。
- 已在 macOS 工作區修正 `aspnum_price` 為 `NULL` 時不會更新、remaining 驗證漏算的問題。
- 已修正 `aspnum` 寫入 6 位小數、卻以未 ROUND 原值比較所造成的重複更新／remaining 不收斂風險。
- 已同步修正 SOP 與 `PROJECT_CONTEXT.md` 的 `asp` / `aspnum` NULL-safe 比較；尚未重新暫存。

## 未完成工作

- 將 SOP 最新工作區版本重新暫存前，先審查差異。
- 若能連線生產資料庫，將 recovery script 與實際 `dbo.updatepriclcost2` 再比對一次。

## 阻斷與注意事項

- 先前 Windows `G:` 虛擬磁碟的 patch helper 阻斷不適用於目前 macOS 工作區；本次已可正常套用修正。
- 未經使用者確認，不執行 Git commit、push 或 pull。

## 下次開工

1. 審查 SQL、SOP 與 `PROJECT_CONTEXT.md` 的 NULL-safe 比較差異。
2. 若可連線生產資料庫，將 recovery script 與實際 `dbo.updatepriclcost2` 比對。
3. 確認暫存範圍後，再由使用者決定是否 commit。
