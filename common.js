(() => {
  const cfg = window.LAUNCHBOARD_CONFIG || {};
  if (!cfg.supabaseUrl || !cfg.supabaseKey ||
      cfg.supabaseUrl.includes("YOUR_") || cfg.supabaseKey.includes("YOUR_")) {
    document.body.insertAdjacentHTML("afterbegin",
      '<div style="padding:12px;background:#fff3cd;color:#7a5200;text-align:center;font-weight:700">Open <code>config.js</code> and add your Supabase URL and publishable/anon key.</div>');
  }

  window.db = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey);

  window.money = value =>
    new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(value || 0));

  window.points = value =>
    new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(Number(value || 0));

  window.escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;"
  }[c]));

  window.requireUser = async () => {
    const { data: { session } } = await window.db.auth.getSession();
    if (!session) {
      window.location.href = "index.html";
      return null;
    }
    return session.user;
  };

  window.getProfile = async userId => {
    const { data, error } = await window.db
      .from("profiles")
      .select("*")
      .eq("id", userId)
      .single();
    if (error) throw error;
    return data;
  };

  window.showMessage = (element, text, success = false) => {
    element.textContent = text || "";
    element.classList.toggle("success", success);
  };

  document.getElementById("logoutBtn")?.addEventListener("click", async () => {
    await window.db.auth.signOut();
    window.location.href = "index.html";
  });
})();
