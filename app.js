const gameGrid = document.querySelector("#game-grid");
const searchInput = document.querySelector("#game-search");
const emptyState = document.querySelector("#empty-state");
const dialog = document.querySelector("#room-dialog");
const dialogTitle = document.querySelector("#dialog-title");
const dialogDescription = document.querySelector("#dialog-description");
const dialogNote = document.querySelector("#dialog-note");
const roomForm = document.querySelector("#room-form");
const playerCount = document.querySelector("#player-count");
const joinFields = document.querySelector("#join-fields");
const roomCodeInput = document.querySelector("#room-code-input");
const lobby = document.querySelector("#room-lobby");
const playerList = document.querySelector("#player-list");
const lobbyMessage = document.querySelector("#lobby-message");
const roomCodeDisplay = document.querySelector("#room-code");
const playerTotal = document.querySelector("#player-total");
const gameBoard = document.querySelector("#game-board");
const startButton = document.querySelector("#start-game");
const loginButton = document.querySelector("#discord-login");
const profileBar = document.querySelector("#profile-bar");
const profileName = document.querySelector("#profile-name");
const profileXp = document.querySelector("#profile-xp");
const leaderboardList = document.querySelector("#leaderboard-list");
const supabaseFactory = window.supabase && window.supabase.createClient;
const config = window.MILAN_SUPABASE_CONFIG;
const winnerLabels = {
  mafia: "المافيا",
  town: "أهل المدينة",
  spy: "الجاسوس",
  crew: "أهل السالفة",
  red: "الفريق الأحمر",
  blue: "الفريق الأزرق",
};
const supabaseClient =
  config &&
  config.url &&
  config.anonKey &&
  supabaseFactory &&
  !config.url.includes("YOUR_PROJECT")
    ? supabaseFactory(config.url, config.anonKey)
    : null;

let currentSession = null;
let currentProfile = null;
let activeRoomCode = null;
let selectedGame = null;
let pollTimer = null;
let polling = false;
let lastFinishedCode = null;

document.querySelector("#year").textContent = new Date().getFullYear();

searchInput.addEventListener("input", () => {
  const query = searchInput.value.trim().toLocaleLowerCase("ar");
  const cards = [...gameGrid.querySelectorAll(".game-card")];
  let visibleCount = 0;
  cards.forEach((card) => {
    const matches = card.dataset.name.toLocaleLowerCase("ar").includes(query);
    card.hidden = !matches;
    if (matches) visibleCount += 1;
  });
  emptyState.hidden = visibleCount > 0;
});

function showStatus(message, isError = false) {
  dialogNote.textContent = message;
  dialogNote.className = isError ? "dialog-note error-message" : "dialog-note";
  dialogNote.hidden = false;
}

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

async function loadProfile(user) {
  const { data, error } = await supabaseClient
    .from("milan_profiles")
    .select("user_id,display_name,xp")
    .eq("user_id", user.id)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new Error("ملفك الشخصي ما تجهّز. أعد تسجيل الدخول بعد إعداد قاعدة البيانات.");
  currentProfile = data;
  profileName.textContent = data.display_name;
  profileXp.textContent = new Intl.NumberFormat("ar").format(data.xp);
  profileBar.hidden = false;
  loginButton.hidden = true;
  await loadLeaderboard();
}

async function loadLeaderboard() {
  if (!supabaseClient || !currentSession) return;
  const { data, error } = await supabaseClient
    .from("milan_profiles")
    .select("display_name,xp")
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
    const name = document.createElement("span");
    const score = document.createElement("strong");
    name.textContent = `${new Intl.NumberFormat("ar").format(index + 1)}. ${player.display_name}`;
    score.textContent = `${new Intl.NumberFormat("ar").format(player.xp)} XP`;
    item.append(name, score);
    leaderboardList.append(item);
  });
}

function addListText(list, text, className) {
  const item = document.createElement("li");
  item.className = className;
  item.textContent = text;
  list.append(item);
}

async function handleSession(session) {
  currentSession = session;
  currentProfile = null;
  profileBar.hidden = true;
  loginButton.hidden = false;
  if (!session) {
    leaderboardList.replaceChildren();
    addListText(leaderboardList, "سجّل دخولك وابدأ اللعب لتظهر النتائج هنا.", "leaderboard-placeholder");
    return;
  }
  try {
    await loadProfile(session.user);
  } catch (error) {
    showStatus(authErrorMessage(error), true);
  }
}

if (supabaseClient) {
  supabaseClient.auth.onAuthStateChange((_event, session) => {
    window.setTimeout(() => void handleSession(session), 0);
  });
  supabaseClient.auth.getSession().then(({ data, error }) => {
    if (error) showStatus(authErrorMessage(error), true);
    else void handleSession(data.session);
  });
} else {
  loginButton.disabled = true;
  loginButton.title = "أضف إعدادات Supabase أولاً";
}

loginButton.addEventListener("click", async () => {
  if (!supabaseClient) {
    window.alert("أضف رابط Supabase ومفتاح النشر في supabase-config.js أولاً.");
    return;
  }
  const { error } = await supabaseClient.auth.signInWithOAuth({
    provider: "discord",
    options: { redirectTo: `${window.location.origin}${window.location.pathname}` },
  });
  if (error) window.alert(authErrorMessage(error));
});

document.querySelector("#discord-logout").addEventListener("click", async () => {
  const { error } = await supabaseClient.auth.signOut();
  if (error) window.alert(authErrorMessage(error));
});

function callRoomCommand(action, options = {}) {
  return supabaseClient.rpc("milan_room_command", {
    p_action: action,
    p_code: options.code || activeRoomCode,
    p_game: options.game || selectedGame,
    p_max_players: options.maxPlayers || null,
    p_display_name: currentProfile ? currentProfile.display_name : null,
    p_payload: options.payload || {},
  });
}

async function runRoomCommand(action, options = {}) {
  if (!currentSession || !currentProfile) {
    showStatus("سجّل الدخول عبر Discord أولاً عشان تلعب.", true);
    return null;
  }
  showStatus("جاري تحديث الغرفة...", false);
  const { data, error } = await callRoomCommand(action, options);
  if (error) {
    showStatus(authErrorMessage(error), true);
    return null;
  }
  if (data && data.left) {
    stopRoomPolling();
    resetRoomView();
    return data;
  }
  if (data && data.code) {
    activeRoomCode = data.code;
    renderRoom(data);
    await loadProfile(currentSession.user);
  }
  return data;
}

function startRoomPolling() {
  stopRoomPolling();
  const poll = async () => {
    if (!activeRoomCode || !dialog.open || polling) return;
    polling = true;
    const { data, error } = await supabaseClient.rpc("milan_room_snapshot", { p_code: activeRoomCode });
    polling = false;
    if (error) {
      showStatus(authErrorMessage(error), true);
    } else {
      renderRoom(data);
    }
    if (activeRoomCode && dialog.open) pollTimer = window.setTimeout(poll, 1800);
  };
  pollTimer = window.setTimeout(poll, 1800);
}

function stopRoomPolling() {
  if (pollTimer) window.clearTimeout(pollTimer);
  pollTimer = null;
}

function resetRoomView() {
  activeRoomCode = null;
  lastFinishedCode = null;
  roomForm.hidden = false;
  lobby.hidden = true;
  joinFields.hidden = true;
  gameBoard.replaceChildren();
  showStatus("اختر لعبة وأنشئ غرفة خاصة أو انضم برمز.", false);
}

function addBoardMessage(text, className = "game-status") {
  const message = document.createElement("p");
  message.className = className;
  message.textContent = text;
  gameBoard.append(message);
}

function addActionButton(label, action, payload = {}, className = "secondary-button") {
  const button = document.createElement("button");
  button.type = "button";
  button.className = className;
  button.dataset.roomAction = action;
  button.dataset.payload = JSON.stringify(payload);
  button.textContent = label;
  gameBoard.append(button);
  return button;
}

function renderRoom(room) {
  roomCodeDisplay.textContent = room.code;
  roomForm.hidden = true;
  lobby.hidden = false;
  dialogNote.hidden = true;

  playerList.replaceChildren();
  room.players.forEach((player) => {
    const item = document.createElement("li");
    const name = document.createElement("span");
    const badge = document.createElement("span");
    name.textContent = player.name + (player.isHost ? " · المضيف" : "");
    badge.textContent = player.id === currentSession.user.id ? "أنت" : `${player.xp} XP`;
    item.append(name, badge);
    playerList.append(item);
  });
  playerTotal.textContent = `(${new Intl.NumberFormat("ar").format(room.players.length)}/${new Intl.NumberFormat("ar").format(room.maxPlayers)})`;

  const gameNames = { mafia: "مافيا", outsider: "مين برا السالفة", codenames: "كود نيمز", guess: "خمن واربح" };
  const phaseNames = {
    lobby: "بانتظار اللاعبين",
    discussion: "وقت النقاش",
    vote: "التصويت مفتوح",
    spy_guess: "فرصة أخيرة للجاسوس",
    clue: "دور قائد الفريق",
    guess: "خمنوا الكلمات",
    question: "السؤال مفتوح",
    reveal: "الإجابة الصحيحة",
    result: "انتهت الجولة",
  };
  const state = room.public;
  if (room.status === "finished" && lastFinishedCode !== room.code) {
    lastFinishedCode = room.code;
    void loadProfile(currentSession.user);
  }
  lobbyMessage.textContent = room.status === "finished"
    ? `${phaseNames.result} · ${state.winner === "quiz" ? "تم احتساب النقاط" : `الفائز: ${winnerLabels[state.winner] || state.winner}`}`
    : `${gameNames[room.game]} · ${phaseNames[state.phase] || state.phase}`;
  startButton.hidden = room.status !== "lobby" || room.hostId !== currentSession.user.id;
  const minimumPlayers = { mafia: 6, outsider: 3, codenames: 4, guess: 2 };
  startButton.disabled = room.players.length < minimumPlayers[room.game];
  document.querySelector("#leave-room").hidden = room.status !== "lobby";
  renderGameBoard(room);
}

function renderGameBoard(room) {
  gameBoard.replaceChildren();
  if (room.status === "lobby") {
    addBoardMessage(room.hostId === currentSession.user.id
      ? "شارك رمز الغرفة مع أصحابك، ثم ابدأ الجولة."
      : "أرسل لصاحب الغرفة طلب البدء عندما يكتمل الفريق.");
    return;
  }

  const state = room.public;
  const me = room.me;
  if (room.status === "finished" || state.phase === "result") {
    const winnerName = winnerLabels[state.winner] || "";
    addBoardMessage(state.winner === "quiz"
      ? "انتهت الأسئلة! نقاط XP أضيفت للفائزين."
      : `انتهت الجولة. الفائز: ${winnerName}. تم توزيع XP.`);
    return;
  }

  if (room.game === "mafia") renderMafia(room, state, me);
  else if (room.game === "outsider") renderOutsider(room, state, me);
  else if (room.game === "codenames") renderCodenames(room, state, me);
  else renderQuiz(room, state);
}

function renderMafia(room, state, me) {
  const role = me.role === "mafia" ? "أنت من المافيا" : "أنت من أهل المدينة";
  addBoardMessage(`دورك السري: ${role}`, "private-role");
  if (state.phase === "discussion") {
    addBoardMessage("ناقشوا سوا على مكالمة صوتية، وبعدها صوّتوا لإخراج مشتبه به.");
    if (room.hostId === currentSession.user.id) addActionButton("ابدأ التصويت", "begin_vote", {}, "primary-button");
  } else if (state.phase === "vote") {
    if (Object.prototype.hasOwnProperty.call(state.votes || {}, currentSession.user.id)) {
      addBoardMessage("صوّتت. ننتظر بقية اللاعبين.");
      return;
    }
    const eliminated = state.eliminated || [];
    room.players.filter((player) => player.id !== currentSession.user.id && !eliminated.includes(player.id)).forEach((player) => {
      addActionButton(`صوّت لإخراج ${player.name}`, "vote", { target: player.id });
    });
  }
}

function renderOutsider(room, state, me) {
  addBoardMessage(me.spy ? "أنت خارج السالفة! حاول تكتشف الكلمة." : `الكلمة السرية: ${me.word}`, "private-role");
  if (state.phase === "discussion") {
    addBoardMessage("اسألوا بعض أسئلة تلميحية، ثم يبدأ المضيف التصويت.");
    if (room.hostId === currentSession.user.id) addActionButton("ابدأ التصويت", "begin_vote", {}, "primary-button");
  } else if (state.phase === "vote") {
    if (Object.prototype.hasOwnProperty.call(state.votes || {}, currentSession.user.id)) {
      addBoardMessage("صوّتت. ننتظر بقية اللاعبين.");
      return;
    }
    room.players.filter((player) => player.id !== currentSession.user.id).forEach((player) => {
      addActionButton(`صوّت على ${player.name}`, "vote", { target: player.id });
    });
  } else if (state.phase === "spy_guess" && me.spy) {
    const form = document.createElement("form");
    form.className = "game-answer-form";
    const input = document.createElement("input");
    input.name = "word";
    input.required = true;
    input.maxLength = 40;
    input.placeholder = "وش تتوقع الكلمة؟";
    const submit = document.createElement("button");
    submit.className = "primary-button";
    submit.textContent = "إرسال التخمين";
    form.append(input, submit);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      void runRoomCommand("guess_word", { payload: { word: input.value } });
    });
    gameBoard.append(form);
  } else if (state.phase === "spy_guess") {
    addBoardMessage("الجاسوس يحاول تخمين الكلمة قبل إعلان النتيجة.");
  }
}

function renderCodenames(room, state, me) {
  addBoardMessage(`فريقك: ${me.team === "red" ? "الأحمر" : "الأزرق"}${me.spymaster ? " · أنت قائد الفريق" : ""}`, "private-role");
  if (state.phase === "clue" && me.spymaster && me.team === state.turn) {
    const form = document.createElement("form");
    form.className = "game-answer-form";
    const clue = document.createElement("input");
    clue.name = "clue";
    clue.required = true;
    clue.maxLength = 40;
    clue.placeholder = "اكتب تلميحًا من كلمة واحدة";
    const count = document.createElement("select");
    count.setAttribute("aria-label", "عدد الكلمات المرتبطة");
    for (let value = 1; value <= 4; value += 1) {
      const option = document.createElement("option");
      option.value = String(value);
      option.textContent = `${new Intl.NumberFormat("ar").format(value)} كلمات`;
      count.append(option);
    }
    const submit = document.createElement("button");
    submit.className = "primary-button";
    submit.textContent = "إرسال التلميح";
    form.append(clue, count, submit);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      void runRoomCommand("clue", { payload: { text: clue.value, count: Number(count.value) } });
    });
    gameBoard.append(form);
  } else if (state.phase === "guess" && !me.spymaster && me.team === state.turn) {
    addBoardMessage(`تلميح: ${state.clue.text} · حاولات متبقية: ${state.guessesLeft}`);
  } else if (state.phase === "clue") {
    addBoardMessage("انتظر دور قائد فريقك لإعطاء التلميح.");
  }

  const cards = document.createElement("div");
  cards.className = "word-board";
  (state.cards || []).forEach((card, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `word-card${card.revealed ? ` revealed ${card.color || ""}` : ""}`;
    button.textContent = card.word;
    button.disabled = card.revealed || state.phase !== "guess" || me.spymaster || me.team !== state.turn;
    button.addEventListener("click", () => void runRoomCommand("guess_card", { payload: { index } }));
    cards.append(button);
  });
  gameBoard.append(cards);
}

function renderQuiz(room, state) {
  const scores = state.scores || {};
  const sortedScores = room.players
    .map((player) => ({ name: player.name, score: Number(scores[player.id] || 0) }))
    .sort((a, b) => b.score - a.score);
  addBoardMessage(`السؤال ${new Intl.NumberFormat("ar").format(state.round)} من ٥`);
  const question = document.createElement("h3");
  question.className = "quiz-question";
  question.textContent = state.question.q;
  gameBoard.append(question);
  if (state.phase === "question") {
    if (Object.prototype.hasOwnProperty.call(state.answers || {}, currentSession.user.id)) {
      addBoardMessage("تم تسجيل إجابتك. ننتظر بقية اللاعبين.");
    } else {
      const answers = document.createElement("div");
      answers.className = "quiz-options";
      state.question.options.forEach((option, index) => {
        const button = document.createElement("button");
        button.className = "secondary-button";
        button.type = "button";
        button.textContent = option;
        button.addEventListener("click", () => void runRoomCommand("answer", { payload: { choice: index } }));
        answers.append(button);
      });
      gameBoard.append(answers);
    }
  } else if (state.phase === "reveal") {
    addBoardMessage(`الإجابة الصحيحة: ${state.question.options[state.correctAnswer]}`, "private-role");
    const scoreboard = document.createElement("ol");
    scoreboard.className = "round-scores";
    sortedScores.forEach((player) => addListText(scoreboard, `${player.name} — ${new Intl.NumberFormat("ar").format(player.score)} نقطة`, ""));
    gameBoard.append(scoreboard);
    if (room.hostId === currentSession.user.id) addActionButton("السؤال التالي", "next_question", {}, "primary-button");
  }
}

gameBoard.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-room-action]");
  if (!button) return;
  let payload = {};
  try {
    payload = JSON.parse(button.dataset.payload || "{}");
  } catch {
    showStatus("تعذر قراءة الإجراء. حدّث الصفحة وحاول مجددًا.", true);
    return;
  }
  await runRoomCommand(button.dataset.roomAction, { payload });
});

gameGrid.addEventListener("click", (event) => {
  const button = event.target.closest("[data-game-id]");
  if (!button) return;
  const card = button.closest(".game-card");
  selectedGame = button.dataset.gameId;
  dialogTitle.textContent = button.dataset.game;
  dialogDescription.textContent = card.dataset.description;
  roomForm.reset();
  roomForm.hidden = false;
  lobby.hidden = true;
  joinFields.hidden = true;
  showStatus(currentSession
    ? "أنشئ غرفة وشارك رمزها مع أصحابك، أو انضم برمز وصلك."
    : "سجّل دخولك باستخدام Discord قبل إنشاء غرفة أو الانضمام إليها.", !currentSession);
  playerCount.replaceChildren();
  for (let count = Number(card.dataset.minPlayers); count <= Number(card.dataset.maxPlayers); count += 1) {
    const option = document.createElement("option");
    option.value = String(count);
    option.textContent = `${new Intl.NumberFormat("ar").format(count)} لاعبين`;
    playerCount.append(option);
  }
  dialog.showModal();
});

roomForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const room = await runRoomCommand("create", { game: selectedGame, maxPlayers: Number(playerCount.value) });
  if (room) startRoomPolling();
});

document.querySelector("#show-join").addEventListener("click", () => {
  joinFields.hidden = !joinFields.hidden;
  if (!joinFields.hidden) roomCodeInput.focus();
});

document.querySelector("#join-room").addEventListener("click", async () => {
  const roomCode = roomCodeInput.value.trim().toUpperCase();
  if (!/^[A-F0-9]{6}$/.test(roomCode)) {
    showStatus("رمز الغرفة لازم يكون ٦ أحرف أو أرقام.", true);
    roomCodeInput.focus();
    return;
  }
  const room = await runRoomCommand("join", { code: roomCode });
  if (room) startRoomPolling();
});

startButton.addEventListener("click", async () => {
  await runRoomCommand("start");
});

document.querySelector("#copy-room-code").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(activeRoomCode);
    document.querySelector("#copy-room-code").textContent = "تم النسخ";
  } catch {
    showStatus(`انسخ رمز الغرفة يدويًا: ${activeRoomCode}`, true);
  }
});

document.querySelector("#leave-room").addEventListener("click", async () => {
  await runRoomCommand("leave");
});

document.querySelector("#dialog-close").addEventListener("click", () => dialog.close());
dialog.addEventListener("close", () => {
  stopRoomPolling();
  if (activeRoomCode && currentSession) void callRoomCommand("leave");
  resetRoomView();
});
