# Project Context

This repository contains SQL scripts and diagnostics for the Price/MSL work.

## Current Repository Layout

- `updatepriclcost.sql` - main SQL script.
- `updatepriclcost1.sql` - alternate or revised SQL script.
- `diagnose_*.sql` - diagnostic scripts used to inspect differences and specific update segments.
- `updatepriclcost_performance_sop.md` - performance SOP and notes.

## Codex Handoff Notes

The original working folder on Windows was:

```text
D:\Price\SQL
```

This Git repository was created from that folder. Clone it directly into a folder named `SQL` on another computer to recreate the same project folder shape:

```text
SQL/
  PROJECT_CONTEXT.md
  updatepriclcost.sql
  updatepriclcost1.sql
  diagnose_*.sql
  updatepriclcost_performance_sop.md
```

Git does not preserve Codex conversation history. To continue from another computer, clone this repo and ask Codex to read this file first.

Suggested first prompt on another machine:

```text
Please read PROJECT_CONTEXT.md and continue working in this repository.
```
