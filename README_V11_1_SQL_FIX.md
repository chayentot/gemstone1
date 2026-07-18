# Gemstone V11.1 SQL Fix

The Supabase error:

```text
cannot change return type of existing function
```

occurs because V10 already created the referral functions with a different set
of returned columns.

## New installation

Run the corrected:

```text
v11_referral_withdrawal_repair.sql
```

## If V11 already failed

Run:

```text
v11_1_referral_function_patch.sql
```

Then run the corrected full V11 migration again. The migration uses
`create table if not exists`, `drop policy if exists`, and replaceable
functions, so rerunning it is safe for this upgrade.
