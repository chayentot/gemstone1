# Gemstone V6 — Secure Admin, GCash, and Referral

Run `v6_secure_admin_referral_upgrade.sql` once in Supabase SQL Editor. It removes the recursive profile policy without deleting your existing data.

After your administrator account is registered, run:

```sql
insert into public.admins(user_id)
select id from auth.users where email = 'YOUR_ADMIN_EMAIL@gmail.com'
on conflict(user_id) do nothing;
```

Edit `config.js` with your GCash account name and number. Upload all website files to GitHub.

Referral rule: a direct referrer receives 8% of each successfully purchased gemstone price in wallet balance. The buyer pays the full price. Self-referrals are blocked and a user can apply only one referral code.
