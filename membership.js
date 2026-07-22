const grid = document.getElementById("membershipGrid");
const message = document.getElementById("membershipMessage");

async function loadMemberships() {
  const user = await requireUser();
  if (!user) return;
  try {
    const [profile, gemsResult] = await Promise.all([
      getProfile(user.id),
      db.from("gemstones").select("*").eq("is_active", true).order("price")
    ]);
    if (gemsResult.error) throw gemsResult.error;
    document.getElementById("walletBalance").textContent = money(profile.wallet_balance);
    grid.innerHTML = gemsResult.data.map(gem => `
      <article class="gem-card">
        <div class="gem-top"><img src="${escapeHtml(gem.image_url || gemImage(gem.name))}" alt="${escapeHtml(gem.name)} gemstone" loading="lazy"></div>
        <div class="gem-body">
          <div class="gem-title"><h2>${escapeHtml(gem.name)}</h2><span class="price">${money(gem.price)}</span></div>
          <p class="muted">${escapeHtml(gem.description)}</p>
          <div class="meta">
            <div><span>Per claim</span><strong>${points(gem.points_per_claim)} pts</strong></div>
            <div><span>Maximum claims</span><strong>${gem.max_claims}</strong></div>
          </div>
          <button class="primary buy-btn" data-id="${gem.id}">Buy membership</button>
        </div>
      </article>`).join("");
    bindBuyButtons();
  } catch (error) {
    showMessage(message, error.message);
  }
}

function bindBuyButtons() {
  document.querySelectorAll(".buy-btn").forEach(button => {
    button.addEventListener("click", async () => {
      if (!confirm("Buy this gemstone using your wallet balance?")) return;
      button.disabled = true;
      showMessage(message, "Processing purchase...");
      const { error } = await db.rpc("buy_gemstone", { p_gemstone_id: button.dataset.id });
      if (error) {
        showMessage(message, error.message);
        button.disabled = false;
        return;
      }
      showMessage(message, "Purchase successful. This gemstone is unlocked and ready to mine and redeem immediately.", true);
      await loadMemberships();
    });
  });
}
loadMemberships();
