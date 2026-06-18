# Project Context

This repository contains SQL scripts and diagnostics for the Price/MSL work.

## Current Repository Layout

- `SQL/updatepriclcost.sql` - main SQL script.
- `SQL/updatepriclcost1.sql` - alternate or revised SQL script.
- `SQL/diagnose_*.sql` - diagnostic scripts used to inspect differences and specific update segments.
- `SQL/updatepriclcost_performance_sop.md` - performance SOP and notes.

## Codex Handoff Notes

The original working folder on Windows was:

```text
D:\Price\SQL
```

This Git repository was created from that folder. The files were later moved into a top-level `SQL/` directory so that a fresh clone has the expected structure:

```text
MSLcodex/
  PROJECT_CONTEXT.md
  SQL/
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

