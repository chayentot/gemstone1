const dashboard = document.getElementById("adminDashboard");
const denied = document.getElementById("adminDenied");
const adminMessage = document.getElementById("adminMessage");
const dialog = document.getElementById("reviewDialog");
let currentRequest = null;

async function checkAdmin() {
  const user = await requireUser();
  if (!user) return false;

  const { data, error } = await db.from("profiles").select("is_admin").eq("id", user.id).single();
  if (error || !data?.is_admin) {
    denied.classList.remove("hidden");
    dashboard.classList.add("hidden");
    return false;
  }

  denied.classList.add("hidden");
  dashboard.classList.remove("hidden");
  return true;
}

async function loadAdmin() {
  if (!(await checkAdmin())) return;

  const selected = document.getElementById("statusFilter").value;
  let query = db.from("cash_in_requests")
    .select("*, profiles!cash_in_requests_user_id_fkey(full_name)")
    .order("created_at", { ascending: false });

  if (selected !== "all") query = query.eq("status", selected);

  const [requestsResult, allResult] = await Promise.all([
    query.limit(100),
    db.from("cash_in_requests").select("status,amount")
  ]);

  if (requestsResult.error) return showMessage(adminMessage, requestsResult.error.message);
  if (allResult.error) return showMessage(adminMessage, allResult.error.message);

  const all = allResult.data || [];
  document.getElementById("adminSummary").innerHTML = `
    <article class="stat-card"><span>Pending review</span><strong>${all.filter(x => x.status === "pending_review").length}</strong></article>
    <article class="stat-card"><span>Approved requests</span><strong>${all.filter(x => x.status === "approved").length}</strong></article>
    <article class="stat-card"><span>Total approved</span><strong>${money(all.filter(x => x.status === "approved").reduce((s,x) => s + Number(x.amount), 0)).replace("$","₱")}</strong></article>`;

  const rows = requestsResult.data || [];
  document.getElementById("adminCashIns").innerHTML = rows.length ? rows.map(row => `
    <tr>
      <td>${new Date(row.reference_submitted_at || row.created_at).toLocaleString()}</td>
      <td>
        <strong>${escapeHtml(row.profiles?.full_name || "Unnamed user")}</strong>
        <small class="block muted">${escapeHtml(row.user_id)}</small>
      </td>
      <td>${money(row.amount).replace("$","₱")}</td>
      <td><code>${escapeHtml(row.reference_number || "Not submitted")}</code></td>
      <td><span class="request-status ${escapeHtml(row.status)}">${escapeHtml(row.status.replaceAll("_"," "))}</span></td>
      <td>${escapeHtml(row.admin_note || "")}</td>
      <td>
        ${row.status === "pending_review"
          ? `<button class="primary review-btn"
               data-id="${row.id}"
               data-amount="${row.amount}"
               data-reference="${escapeHtml(row.reference_number || "")}"
               data-user="${escapeHtml(row.profiles?.full_name || "User")}">Review</button>`
          : "—"}
      </td>
    </tr>`).join("")
  : '<tr><td colspan="7">No requests under this filter.</td></tr>';

  document.querySelectorAll(".review-btn").forEach(button => {
    button.addEventListener("click", () => {
      currentRequest = {
        id: button.dataset.id,
        amount: button.dataset.amount,
        reference: button.dataset.reference,
        user: button.dataset.user
      };
      document.getElementById("dialogTitle").textContent = `Review ${currentRequest.user}`;
      document.getElementById("dialogDetails").textContent =
        `Amount: ₱${Number(currentRequest.amount).toLocaleString(undefined,{minimumFractionDigits:2})} · Reference: ${currentRequest.reference}`;
      document.getElementById("adminNote").value = "";
      dialog.showModal();
    });
  });
}

dialog.addEventListener("close", async () => {
  if (!currentRequest || !["approve","reject"].includes(dialog.returnValue)) return;
  const approve = dialog.returnValue === "approve";
  const note = document.getElementById("adminNote").value.trim();

  if (!approve && !note) {
    showMessage(adminMessage, "A rejection reason is required.");
    currentRequest = null;
    return;
  }

  showMessage(adminMessage, approve ? "Approving and crediting wallet..." : "Rejecting request...");
  const { error } = await db.rpc("review_cash_in_request", {
    p_request_id: currentRequest.id,
    p_approve: approve,
    p_admin_note: note || null
  });

  currentRequest = null;
  if (error) return showMessage(adminMessage, error.message);

  showMessage(adminMessage, approve ? "Cash-in approved and wallet credited." : "Cash-in rejected.", true);
  await loadAdmin();
});

document.getElementById("refreshAdmin").addEventListener("click", loadAdmin);
document.getElementById("statusFilter").addEventListener("change", loadAdmin);
loadAdmin();
