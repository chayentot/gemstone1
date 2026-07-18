# V7 Referral Links

Each user now gets a referral URL on the Profile page:

```text
https://YOUR_USERNAME.github.io/YOUR_REPOSITORY/index.html?ref=USERCODE
```

## Flow

1. User copies or shares their referral link.
2. Visitor opens the link.
3. The site stores the referral code in the visitor browser and opens Register.
4. After registration/login, the site securely calls `apply_referral_code`.
5. The referral can be applied only once and self-referrals remain blocked.
6. The referrer receives the existing 8% wallet commission when the referred user buys a gemstone.

No new SQL migration is required when V6 is already installed.

Upload the updated `index.html`, `home.js`, `profile.html`, `profile.js`, and `style.css`. Keep your current `config.js` values.
