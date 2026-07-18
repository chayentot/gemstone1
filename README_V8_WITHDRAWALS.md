# Gemstone V8 — Point Withdrawals

This upgrade adds point withdrawals with administrator approval.

## Rules

- Minimum withdrawal: 120 points
- User enters:
  - Points amount
  - GCash account name
  - GCash mobile number
- Request begins as `pending_review`
- Points are not deducted when the request is submitted
- Pending requests are included when checking available points, preventing over-requesting
- Administrator verifies the request and payout details
- Approval deducts points exactly once
- Rejection requires a reason and does not deduct points

## Install

1. Keep your existing website and Supabase database.
2. Run `v8_withdrawal_upgrade.sql` once in Supabase SQL Editor.
3. Upload the updated website files to GitHub.
4. Keep your existing values in `config.js`.
5. Open `admin.html` using your registered administrator account.

Do not rerun the original reset schema.
