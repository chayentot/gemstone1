# Gemstone V13 — Secure Withdrawal + 6% Fee

## Fee calculation

For a ₱1,000 withdrawal:

- Wallet deduction: ₱1,000
- Processing fee: ₱60
- Net GCash payout: ₱940

The minimum gross withdrawal remains ₱120.

## Security improvements

- Sensitive wallet operations run in Supabase database functions
- Browser clients cannot directly insert, update, or delete withdrawals
- Row Level Security remains enabled
- Functions use fixed `search_path`
- Function permissions are explicitly restricted
- Duplicate request protection through UUID request keys
- Maximum 3 withdrawal requests per 24 hours
- Maximum ₱100,000 per request
- Database row locks prevent concurrent double spending
- Approval is allowed only while status is pending
- Admin cannot approve their own withdrawal
- Immutable audit records for withdrawal requests, approvals, rejections, and paid confirmations
- Approval deducts the wallet exactly once

No system is completely hacker-proof. Keep Supabase keys separated correctly: only the publishable/anon key belongs in the website. Never upload the service-role key to GitHub.

## Install

1. Run `v13_secure_withdrawal_fee_upgrade.sql` once.
2. Upload the website files.
3. Preserve your Supabase URL, publishable key, and GCash details in `config.js`.
4. Enable CAPTCHA and review Auth rate limits in Supabase.
5. Enable MFA for administrator accounts.
6. Run the Supabase Security Advisor.
