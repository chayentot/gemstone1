const authGate = document.getElementById("authGate");
const dashboard = document.getElementById("dashboard");
const authMessage = document.getElementById("authMessage");
const homeMessage = document.getElementById("homeMessage");
let countdownTimer;

document.querySelectorAll(".tab").forEach(button => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach(x => x.classList.remove("active"));
    button.classList.add("active");
    const login = button.dataset.tab === "login";
    document.getElementById("loginForm").classList.toggle("hidden", !login);
    document.getElementById("registerForm").classList.toggle("hidden", login);
    showMessage(authMessage, "");
  });
});

document.getElementById("loginForm").addEventListener("submit", async event => {
  event.preventDefault();
  showMessage(authMessage, "Signing in...");
  const { error } = await db.auth.signInWithPassword({
    email: document.getElementById("loginEmail").value.trim(),
    password: document.getElementById("loginPassword").value
  });
  if (error) return showMessage(authMessage, error.message);
  await render();
});

document.getElementById("registerForm").addEventListener("submit", async event => {
  event.preventDefault();
  showMessage(authMessage, "Creating your account...");
  const { data, error } = await db.auth.signUp({
    email: document.getElementById("registerEmail").value.trim(),
    password: document.getElementById("registerPassword").value,
    options: { data: { full_name: document.getElementById("registerName").value.trim() } }
  });
  if (error) return showMessage(authMessage, error.message);
  if (!data.session) {
    showMessage(authMessage, "Account created. Check your email to confirm, then log in.", true);
    return;
  }
  await render();
});

async function render() {
  const { data: { session } } = await db.auth.getSession();
  const loggedIn = Boolean(session);
  authGate.classList.toggle("hidden", loggedIn);
  dashboard.classList.toggle("hidden", !loggedIn);
  document.getElementById("logoutBtn").classList.toggle("hidden", !loggedIn);
  if (!loggedIn) return;

  try {
    const [profile, membershipsResult] = await Promise.all([
      getProfile(session.user.id),
      db.from("user_memberships")
        .select("*, gemstones(*)")
        .eq("user_id", session.user.id)
        .order("purchased_at", { ascending: false })
    ]);
    if (membershipsResult.error) throw membershipsResult.error;
    const memberships = membershipsResult.data || [];

    document.getElementById("summaryCards").innerHTML = `
      <article class="stat-card"><span>Wallet balance</span><strong>${money(profile.wallet_balance)}</strong></article>
      <article class="stat-card"><span>Available points</span><strong>${points(profile.points_balance)}</strong></article>
      <article class="stat-card"><span>Active gemstones</span><strong>${memberships.filter(x => x.status === "active").length}</strong></article>`;

    const grid = document.getElementById("ownedGemstones");
    if (!memberships.length) {
      grid.innerHTML = '<div class="empty"><h2>No gemstones yet</h2><p class="muted">Visit Membership to buy your first gemstone.</p></div>';
      return;
    }
    grid.innerHTML = memberships.map(m => ownedCard(m)).join("");
    bindClaimButtons();
    startCountdowns();
  } catch (error) {
    showMessage(homeMessage, error.message);
  }
}

function ownedCard(m) {
  const gem = m.gemstones;
  const completed = m.status === "completed";
  return `
    <article class="gem-card">
      <div class="gem-top">${escapeHtml(gem.emoji)}</div>
      <div class="gem-body">
        <div class="gem-title"><h2>${escapeHtml(gem.name)}</h2><span class="price">${points(gem.points_per_claim)} pts</span></div>
        <div class="meta">
          <div><span>Claims</span><strong>${m.claims_completed}/${m.max_claims}</strong></div>
          <div><span>Total earned</span><strong>${points(m.claims_completed * gem.points_per_claim)}</strong></div>
        </div>
        <p class="status ${completed ? "" : "waiting"}" data-next="${m.next_redeem_at || ""}">
          ${completed ? "Membership completed" : "Checking timer…"}
        </p>
        <button class="primary claim-btn" data-id="${m.id}" ${completed ? "disabled" : ""}>Redeem points</button>
      </div>
    </article>`;
}

function startCountdowns() {
  clearInterval(countdownTimer);
  const update = () => {
    document.querySelectorAll("[data-next]").forEach(el => {
      if (!el.dataset.next) return;
      const seconds = Math.floor((new Date(el.dataset.next) - new Date()) / 1000);
      const button = el.parentElement.querySelector(".claim-btn");
      if (seconds <= 0) {
        el.textContent = "Ready to redeem";
        el.classList.remove("waiting");
        button.disabled = false;
      } else {
        const h = Math.floor(seconds / 3600);
        const m = Math.floor((seconds % 3600) / 60);
        const s = seconds % 60;
        el.textContent = `Ready in ${h}h ${m}m ${s}s`;
        el.classList.add("waiting");
        button.disabled = true;
      }
    });
  };
  update();
  countdownTimer = setInterval(update, 1000);
}

function bindClaimButtons() {
  document.querySelectorAll(".claim-btn").forEach(button => {
    button.addEventListener("click", async () => {
      button.disabled = true;
      showMessage(homeMessage, "Redeeming...");
      const { error } = await db.rpc("redeem_membership", { p_membership_id: button.dataset.id });
      if (error) {
        showMessage(homeMessage, error.message);
        button.disabled = false;
        return;
      }
      showMessage(homeMessage, "Points redeemed. Your next 24-hour cycle has started.", true);
      await render();
    });
  });
}

db.auth.onAuthStateChange(() => render());
render();
