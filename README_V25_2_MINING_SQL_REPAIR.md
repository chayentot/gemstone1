# Gemstone V25.2 — Mining SQL Repair

This update fixes:

`column reference "gemstone_id" is ambiguous`

## Cause

The Home mining RPC returned a field named `gemstone_id` while also querying database columns with the same name. PostgreSQL treated the unqualified reference as ambiguous.

## Installation

1. Open Supabase → SQL Editor.
2. Run `v25_2_ambiguous_gemstone_id_repair.sql`.
3. Reload the Home page.

Website re-upload is optional because this repair changes only the database RPC. The full V25.2 package is included for backup and clean deployment.

## Preserved

- Existing memberships
- Wallet balances
- Redeem rewards
- Referral commissions
- Withdrawals
- Mining materials and unlock progress
- Admin functions
