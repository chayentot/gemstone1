# Gemstone V14 — Admin User Directory Only

This version does not include hourly backups.

## New administrator user list

Run this file once in Supabase SQL Editor:

```text
v14_admin_user_directory.sql
```

The admin page shows:

- Total registered users
- User name and email
- Join date
- Wallet balance
- Referral code
- Referrer
- Total memberships
- Active memberships
- Number of referrals
- Pending cash-in amount
- Pending withdrawal amount
- User or administrator role
- Search by name, email, or referral code

## Install

1. Run `v14_admin_user_directory.sql` once.
2. Upload the website files to GitHub.
3. Preserve your existing values in `config.js`.
4. Refresh the deployed website with Ctrl + Shift + R.

No backup workflow is included in this package.
