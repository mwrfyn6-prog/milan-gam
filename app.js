(function () {
const gameGrid = document.querySelector("#game-grid");
const searchInput = document.querySelector("#game-search");
const emptyState = document.querySelector("#empty-state");
const dialog = document.querySelector("#room-dialog");
const dialogTitle = document.querySelector("#dialog-title");
const dialogDescription = document.querySelector("#dialog-description");
const dialogNote = document.querySelector("#dialog-note");
const roomForm = document.querySelector("#room-form");
const playerCount = document.querySelector("#player-count");
const quickJoinForm = document.querySelector("#quick-join-form");
const quickJoinCode = document.querySelector("#quick-join-code");
const quickJoinStatus = document.querySelector("#quick-join-status");
const loginButton = document.querySelector("#discord-login");
const logoutButton = document.querySelector("#discord-logout");
const profileBar = document.querySelector("#profile-bar");
const profileName = document.querySelector("#profile-name");
const profileXp = document.querySelector("#profile-xp");
const profileAvatar = document.querySelector("#profile-avatar");
const profileAvatarFallback = document.querySelector("#profile-avatar-fallback");
const leaderboardList = document.querySelector("#leaderboard-list");
const supabaseFactory = window.supabase && window.supabase.createClient;
const config = window.MILAN_SUPABASE_CONFIG;
const supabaseClient =
  config &&
  config.url &&
  config.anonKey &&
  supabaseFactory &&
  !config.url.includes("YOUR_PROJECT")
    ? supabaseFactory(config.url, config.anonKey)
    : null;
window.MilanSupabaseClient = supabaseClient;

let currentSession = null;
let currentProfile = null;
let selectedGame = null;

document.querySelector("#year").textContent = String(new Date().getFullYear());

searchInput.addEventListener("input", () => {
  const query = searchInput.value.trim().toLocaleLowerCase("ar");
  let visibleCount = 0;
  gameGrid.querySelectorAll(".game-card").forEach((card) => {
    const matches = card.dataset.name.toLocaleLowerCase("ar").includes(query);
    card.hidden = !matches;
    if (matches) visibleCount += 1;
  });
  emptyState.hidden = visibleCount > 0;
});

function authErrorMessage(error) {
  const message = error && error.message ? error.message : "صار خطأ غير متوقع.";
  if (/not found|does not exist|schema cache/i.test(message)) {
    return "قاعدة بيانات ميلان غير مجهزة. نفّذ ملف supabase-schema.sql من SQL Editor في Supabase.";
  }
  if (/jwt|expired|unauthorized/i.test(message)) {
    return "انتهت جلسة الدخول. سجّل خروج ثم ادخل عبر Discord مرة ثانية.";
  }
  return message;
}

function getDisplayName(user, profile) {
  const metadata = user.user_metadata || {};
  const discordName =
    metadata.global_name ||
    (metadata.custom_claims && metadata.custom_claims.global_name) ||
    metadata.full_name ||
    metadata.name ||
    metadata.preferred_username;
  return profile.display_name === "لاعب ميلان" && discordName
    ? discordName
    : profile.display_name || discordName || "لاعب ميلان";
}

function isSafeAvatarUrl(value) {
  if (!value) return false;
  try {
    return new URL(value).protocol === "https:";
  } catch {
    return false;
  }
}

function setProfileAvatar(url, name) {
  const hasAvatar = isSafeAvatarUrl(url);
  profileAvatarFallback.textContent = (name || "م").trim().charAt(0) || "م";
  profileAvatar.hidden = !hasAvatar;
  profileAvatarFallback.hidden = hasAvatar;
  profileAvatar.onerror = () => {
    profileAvatar.hidden = true;
    profileAvatarFallback.hidden = false;
  };
  if (hasAvatar) profileAvatar.src = url;
  else profileAvatar.removeAttribute("src");
}

function createAvatar(url, name) {
  const avatar = document.createElement("span");
  avatar.className = "avatar-shell leaderboard-avatar";
  const fallback = document.createElement("span");
  fallback.textContent = (name || "م").trim().charAt(0) || "م";
  fallback.setAttribute("aria-hidden", "true");
  avatar.append(fallback);
  if (isSafeAvatarUrl(url)) {
    const image = document.createElement("img");
    image.src = url;
    image.alt = "";
    image.referrerPolicy = "no-referrer";
    image.loading = "lazy";
    image.addEventListener("error", () => image.remove(), { once: true });
    avatar.prepend(image);
  }
  return avatar;
}

function addListText(list, text, className) {
  const item = document.createElement("li");
  item.className = className;
  item.textContent = text;
  list.append(item);
}

async function loadLeaderboard() {
  if (!supabaseClient || !currentSession) return;
  const { data, error } = await supabaseClient
    .from("milan_profiles")
    .select("display_name,xp,avatar_url")
    .order("xp", { ascending: false })
    .limit(10);
  if (error) {
    leaderboardList.replaceChildren();
    addListText(leaderboardList, "تعذّر تحميل لوحة المتصدرين.", "leaderboard-placeholder");
    return;
  }
  leaderboardList.replaceChildren();
  if (!data.length) {
    addListText(leaderboardList, "كونوا أول أبطال ميلان!", "leaderboard-placeholder");
    return;
  }
  data.forEach((player, index) => {
    const item = document.createElement("li");
    const identity = document.createElement("span");
    identity.className = "leaderboard-identity";
    const rank = document.createElement("span");
    rank.className = "leaderboard-rank";
    rank.textContent = new Intl.NumberFormat("ar").format(index + 1);
    const name = document.createElement("span");
    name.className = "leaderboard-name";
    name.textContent = player.display_name || "لاعب ميلان";
    const score = document.createElement("strong");
    score.textContent = `${new Intl.NumberFormat("ar").format(player.xp || 0)} XP`;
    identity.append(rank, createAvatar(player.avatar_url, name.textContent), name);
    item.append(identity, score);
    leaderboardList.append(item);
  });
}

function setQuickJoinStatus(message, isError = false) {
  quickJoinStatus.textContent = message;
  quickJoinStatus.className = `quick-join-status${isError ? " error" : ""}`;
  quickJoinStatus.hidden = false;
}

function setDialogStatus(message, isError = false) {
  dialogNote.textContent = message;
  dialogNote.className = `dialog-note${isError ? " error-message" : ""}`;
  dialogNote.hidden = false;
}

async function loadProfile(user) {
  const { data, error } = await supabaseClient
    .from("milan_profiles")
    .select("user_id,display_name,xp,avatar_url")
    .eq("user_id", user.id)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new Error("ملفك الشخصي ما تجهّز. أعد تسجيل الدخول بعد إعداد قاعدة البيانات.");
  const displayName = getDisplayName(user, data);
  const metadata = user.user_metadata || {};
  currentProfile = {
    ...data,
    display_name: displayName,
    avatar_url: data.avatar_url || metadata.avatar_url || metadata.picture || null,
  };
  profileName.textContent = displayName;
  profileXp.textContent = new Intl.NumberFormat("ar").format(data.xp || 0);
  setProfileAvatar(currentProfile.avatar_url, displayName);
  profileBar.hidden = false;
  loginButton.hidden = true;
  await loadLeaderboard();
}

async function handleSession(session) {
  currentSession = session;
  currentProfile = null;
  profileBar.hidden = true;
  profileAvatar.hidden = true;
  profileAvatarFallback.hidden = false;
  loginButton.hidden = false;
  if (!session) {
    leaderboardList.replaceChildren();
    addListText(leaderboardList, "سجّل دخولك وابدأ اللعب لتظهر النتائج هنا.", "leaderboard-placeholder");
    return;
  }
  try {
    await loadProfile(session.user);
  } catch (error) {
    setQuickJoinStatus(authErrorMessage(error), true);
    setDialogStatus(authErrorMessage(error), true);
  }
}

async function signInWithDiscord() {
  if (!supabaseClient) {
    window.alert("أضف رابط Supabase ومفتاح النشر في supabase-config.js أولاً.");
    return;
  }
  const { error } = await supabaseClient.auth.signInWithOAuth({
    provider: "discord",
    options: {
      redirectTo: `${window.location.origin}${window.location.pathname}`,
      scopes: "identify email",
    },
  });
  if (error) window.alert(authErrorMessage(error));
}

async function runRoomCommand(action, options = {}, source = "dialog") {
  const report = source === "quick" ? setQuickJoinStatus : setDialogStatus;
  if (!supabaseClient) {
    report("الاتصال غير مهيأ. أضف إعدادات Supabase في supabase-config.js.", true);
    return;
  }
  if (!currentSession || !currentProfile) {
    report("سجّل الدخول عبر Discord أولاً عشان تلعب.", true);
    return;
  }
  report("جاري الاتصال بالغرفة...");
  const { data, error } = await supabaseClient.rpc("milan_room_command", {
    p_action: action,
    p_code: options.code || null,
    p_game: options.game || selectedGame || null,
    p_max_players: options.maxPlayers || null,
    p_display_name: currentProfile.display_name,
    p_payload: options.payload || {},
  });
  if (error) {
    report(authErrorMessage(error), true);
    return;
  }
  if (!data || !data.code) {
    report("لم يتمكن الموقع من فتح الغرفة. حاول مرة أخرى.", true);
    return;
  }
  if (!window.MilanRoom) {
    report("تعذّر فتح واجهة الغرفة. حدّث الصفحة وحاول مرة أخرى.", true);
    return;
  }
  void window.MilanRoom.open(data.code);
}

gameGrid.addEventListener("click", (event) => {
  const button = event.target.closest("[data-game-id]");
  if (!button) return;
  const card = button.closest(".game-card");
  selectedGame = button.dataset.gameId;
  dialogTitle.textContent = button.dataset.game;
  dialogDescription.textContent = card.dataset.description;
  roomForm.reset();
  playerCount.replaceChildren();
  for (let count = Number(card.dataset.minPlayers); count <= Number(card.dataset.maxPlayers); count += 1) {
    const option = document.createElement("option");
    option.value = String(count);
    option.textContent = `${new Intl.NumberFormat("ar").format(count)} لاعبين`;
    playerCount.append(option);
  }
  setDialogStatus(currentSession
    ? "أنشئ غرفة وشارك رمزها مع أصحابك."
    : "سجّل دخولك باستخدام Discord قبل إنشاء غرفة.", !currentSession);
  dialog.showModal();
});

roomForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const submit = roomForm.querySelector('[type="submit"]');
  submit.disabled = true;
  await runRoomCommand("create", {
    game: selectedGame,
    maxPlayers: Number(playerCount.value),
  });
  submit.disabled = false;
});

quickJoinForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const code = quickJoinCode.value.trim().toUpperCase();
  if (!/^[A-F0-9]{6}$/.test(code)) {
    setQuickJoinStatus("رمز الغرفة لازم يكون ٦ أحرف أو أرقام.", true);
    quickJoinCode.focus();
    return;
  }
  const button = quickJoinForm.querySelector('[type="submit"]');
  button.disabled = true;
  await runRoomCommand("join", { code }, "quick");
  button.disabled = false;
});

loginButton.addEventListener("click", () => void signInWithDiscord());
logoutButton.addEventListener("click", async () => {
  if (!supabaseClient) return;
  const { error } = await supabaseClient.auth.signOut();
  if (error) window.alert(authErrorMessage(error));
});

document.querySelector("#dialog-close").addEventListener("click", () => dialog.close());

if (supabaseClient) {
  supabaseClient.auth.onAuthStateChange((_event, session) => {
    window.setTimeout(() => void handleSession(session), 0);
  });
  supabaseClient.auth.getSession().then(({ data, error }) => {
    if (error) setQuickJoinStatus(authErrorMessage(error), true);
    else void handleSession(data.session);
  });
} else {
  loginButton.disabled = true;
  loginButton.title = "أضف إعدادات Supabase أولاً";
  leaderboardList.replaceChildren();
  addListText(leaderboardList, "أضف إعدادات Supabase لعرض المتصدرين.", "leaderboard-placeholder");
}
})();
