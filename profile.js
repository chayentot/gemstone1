const profileMessage=document.getElementById("profileMessage");
const cfg=window.LAUNCHBOARD_CONFIG||{};let currentUser;
function statusBadge(status){const labels={awaiting_reference:"Awaiting reference",pending_review:"Pending review",approved:"Approved",rejected:"Rejected",cancelled:"Cancelled"};return `<span class="request-status ${escapeHtml(status)}">${escapeHtml(labels[status]||status)}</span>`;}
async function loadProfile(){
  currentUser=await requireUser();if(!currentUser)return;document.getElementById("profileEmail").textContent=currentUser.email;
  try{
    const [profile,walletResult,pointResult,memberResult,cashInResult,referralResult]=await Promise.all([
      getProfile(currentUser.id),
      db.from("wallet_transactions").select("*").eq("user_id",currentUser.id).order("created_at",{ascending:false}).limit(20),
      db.from("point_transactions").select("*").eq("user_id",currentUser.id).order("created_at",{ascending:false}).limit(20),
      db.from("user_memberships").select("id,status").eq("user_id",currentUser.id),
      db.from("cash_in_requests").select("*").eq("user_id",currentUser.id).order("created_at",{ascending:false}).limit(30),
      db.from("referral_rewards").select("*").eq("referrer_id",currentUser.id).order("created_at",{ascending:false}).limit(30)
    ]);
    for(const r of [walletResult,pointResult,memberResult,cashInResult,referralResult])if(r.error)throw r.error;
    document.getElementById("profileSummary").innerHTML=`<article class="stat-card"><span>Wallet balance</span><strong>₱${Number(profile.wallet_balance).toLocaleString(undefined,{minimumFractionDigits:2})}</strong></article><article class="stat-card"><span>Available points</span><strong>${points(profile.points_balance)}</strong></article><article class="stat-card"><span>Total memberships</span><strong>${memberResult.data.length}</strong></article>`;
    document.getElementById("myReferralCode").textContent=profile.referral_code||"—";
    const referralUrl = new URL("index.html", window.location.href);
    referralUrl.searchParams.set("ref", profile.referral_code || "");
    document.getElementById("myReferralLink").value = referralUrl.href;
    if(profile.referred_by)document.getElementById("applyReferralForm").innerHTML='<p class="status">A referral code has already been applied to your account.</p>';
    document.getElementById("referralRewards").innerHTML=referralResult.data.length?referralResult.data.map(row=>`<tr><td>${new Date(row.created_at).toLocaleString()}</td><td>₱${Number(row.purchase_amount).toLocaleString(undefined,{minimumFractionDigits:2})}</td><td>${Number(row.reward_rate)*100}%</td><td>₱${Number(row.reward_amount).toLocaleString(undefined,{minimumFractionDigits:2})}</td></tr>`).join(""):'<tr><td colspan="4">No referral rewards yet.</td></tr>';
    document.getElementById("cashInRequests").innerHTML=cashInResult.data.length?cashInResult.data.map(row=>`<tr><td>${new Date(row.created_at).toLocaleString()}</td><td>₱${Number(row.amount).toLocaleString(undefined,{minimumFractionDigits:2})}</td><td>${escapeHtml(row.reference_number||"Not submitted")}</td><td>${statusBadge(row.status)}</td><td>${escapeHtml(row.admin_note||"")}</td></tr>`).join(""):'<tr><td colspan="5">No cash-in requests yet.</td></tr>';
    document.getElementById("walletTransactions").innerHTML=walletResult.data.length?walletResult.data.map(row=>`<tr><td>${new Date(row.created_at).toLocaleString()}</td><td>${escapeHtml(row.type)}</td><td>₱${Number(row.amount).toLocaleString(undefined,{minimumFractionDigits:2})}</td><td>${escapeHtml(row.description||"")}</td></tr>`).join(""):'<tr><td colspan="4">No wallet activity yet.</td></tr>';
    document.getElementById("pointTransactions").innerHTML=pointResult.data.length?pointResult.data.map(row=>`<tr><td>${new Date(row.created_at).toLocaleString()}</td><td>${escapeHtml(row.type)}</td><td>${points(row.points)}</td><td>${escapeHtml(row.description||"")}</td></tr>`).join(""):'<tr><td colspan="4">No point activity yet.</td></tr>';
  }catch(error){showMessage(profileMessage,error.message);}
}
document.getElementById("cashInForm").addEventListener("submit",async event=>{event.preventDefault();const amount=Number(document.getElementById("cashInAmount").value);if(!Number.isFinite(amount)||amount<50||amount>100000)return showMessage(profileMessage,"Enter an amount from ₱50 to ₱100,000.");showMessage(profileMessage,"Creating your pending cash-in request...");const {data,error}=await db.rpc("create_cash_in_request",{p_amount:amount});if(error)return showMessage(profileMessage,error.message);document.getElementById("cashInRequestId").value=data;document.getElementById("paymentAmount").textContent=`₱${amount.toLocaleString(undefined,{minimumFractionDigits:2})}`;document.getElementById("gcashName").textContent=cfg.gcashName||"Configure gcashName";document.getElementById("gcashNumber").textContent=cfg.gcashNumber||"Configure gcashNumber";document.getElementById("paymentInstructions").classList.remove("hidden");showMessage(profileMessage,"Request created. Pay through GCash, then submit the reference number.",true);await loadProfile();});
document.getElementById("referenceForm").addEventListener("submit",async event=>{event.preventDefault();const requestId=document.getElementById("cashInRequestId").value,reference=document.getElementById("referenceNumber").value.trim().replace(/\s+/g,"");if(!requestId)return showMessage(profileMessage,"Create a cash-in request first.");if(reference.length<6)return showMessage(profileMessage,"Enter a valid GCash reference number.");showMessage(profileMessage,"Submitting your reference number...");const {error}=await db.rpc("submit_cash_in_reference",{p_request_id:requestId,p_reference_number:reference});if(error)return showMessage(profileMessage,error.message);event.target.reset();document.getElementById("paymentInstructions").classList.add("hidden");document.getElementById("cashInForm").reset();showMessage(profileMessage,"Reference submitted. Your request is waiting for admin verification.",true);await loadProfile();});
document.getElementById("copyReferralLink")?.addEventListener("click", async () => {
  const link = document.getElementById("myReferralLink").value;
  if (!link || link === "Loading…") return;
  await navigator.clipboard.writeText(link);
  showMessage(profileMessage, "Referral link copied.", true);
});

document.getElementById("shareReferralLink")?.addEventListener("click", async () => {
  const link = document.getElementById("myReferralLink").value;
  if (!link || link === "Loading…") return;
  if (navigator.share) {
    await navigator.share({
      title: "Join Gemstone Membership",
      text: "Register using my referral link.",
      url: link
    });
  } else {
    await navigator.clipboard.writeText(link);
    showMessage(profileMessage, "Referral link copied. You can now share it.", true);
  }
});
document.getElementById("applyReferralForm")?.addEventListener("submit",async event=>{event.preventDefault();const code=document.getElementById("referralCodeInput").value.trim();if(!code)return showMessage(profileMessage,"Enter a referral code.");const {error}=await db.rpc("apply_referral_code",{p_referral_code:code});if(error)return showMessage(profileMessage,error.message);showMessage(profileMessage,"Referral code applied successfully.",true);await loadProfile();});
loadProfile();
