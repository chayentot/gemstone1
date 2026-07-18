const profileMessage = document.getElementById("profileMessage");
let currentUser;

async function loadProfile() {
  currentUser = await requireUser();
  if (!currentUser) return;
  document.getElementById("profileEmail").textContent = currentUser.email;

  try {
    const [profile, walletResult, pointResult, memberResult] = await Promise.all([
      getProfile(currentUser.id),
      db.from("wallet_transactions").select("*").eq("user_id", currentUser.id).order("created_at", { ascending: false }).limit(20),
      db.from("point_transactions").select("*").eq("user_id", currentUser.id).order("created_at", { ascending: false }).limit(20),
      db.from("user_memberships").select("id,status").eq("user_id", currentUser.id)
    ]);
    if (walletResult.error) throw walletResult.error;
    if (pointResult.error) throw pointResult.error;
    if (memberResult.error) throw memberResult.error;

    document.getElementById("profileSummary").innerHTML = `
      <article class="stat-card"><span>Wallet balance</span><strong>${money(profile.wallet_balance)}</strong></article>
      <article class="stat-card"><span>Available points</span><strong>${points(profile.points_balance)}</strong></article>
      <article class="stat-card"><span>Total memberships</span><strong>${memberResult.data.length}</strong></article>`;

    document.getElementById("walletTransactions").innerHTML =
      walletResult.data.length ? walletResult.data.map(row => `
        <tr><td>${new Date(row.created_at).toLocaleString()}</td><td>${escapeHtml(row.type)}</td>
        <td>${money(row.amount)}</td><td>${escapeHtml(row.description || "")}</td></tr>`).join("")
      : '<tr><td colspan="4">No wallet activity yet.</td></tr>';

    document.getElementById("pointTransactions").innerHTML =
      pointResult.data.length ? pointResult.data.map(row => `
        <tr><td>${new Date(row.created_at).toLocaleString()}</td><td>${escapeHtml(row.type)}</td>
        <td>${points(row.points)}</td><td>${escapeHtml(row.description || "")}</td></tr>`).join("")
      : '<tr><td colspan="4">No point activity yet.</td></tr>';
  } catch (error) {
    showMessage(profileMessage, error.message);
  }
}

document.getElementById("cashInForm").addEventListener("submit", async event => {
  event.preventDefault();
  const amount = Number(document.getElementById("cashInAmount").value);
  if (!Number.isFinite(amount) || amount <= 0) return showMessage(profileMessage, "Enter a valid amount.");
  showMessage(profileMessage, "Adding demo funds...");
  const { error } = await db.rpc("demo_cash_in", { p_amount: amount });
  if (error) return showMessage(profileMessage, error.message);
  event.target.reset();
  showMessage(profileMessage, "Demo funds added.", true);
  await loadProfile();
});
loadProfile();
