# Gemstone V12.1 SQL Fix

The error occurred because the old `get_my_withdrawal_balance()` function
returned point-related columns, while V12 returns wallet-related columns.

PostgreSQL requires the old function to be dropped before changing its
returned column structure.

## If V12 already failed

Run:

```text
v12_1_withdrawal_function_patch.sql
```

Then run the corrected:

```text
v12_single_wallet_upgrade.sql
```

again.

The corrected full migration now drops the old function before recreating it.
Existing users, wallet balances, referral rewards, cash-ins, and withdrawal
requests are preserved.
