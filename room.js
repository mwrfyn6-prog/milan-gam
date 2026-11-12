const roomCode = new URLSearchParams(window.location.search).get("code")?.trim().toUpperCase() || "";
const config = window.MILAN_SUPABASE_CONFIG;
const supabaseFactory = window.supabase && window.supabase.createClient;
const supabaseClient =
  config &&
  config.url &&
  config.anonKey &&
  supabaseFactory &&
  !config.url.includes("YOUR_PROJECT")
    ? supabaseFactory(config.url, config.anonKey)
    : null;

const gameContent = document.querySelector("#game-content");
const roomTitle = document.querySelector("#room-title");
const gameLabel = document.querySelector("#game-label");
const roomCodeDisplay = document.querySelector("#room-code");
const statusMessage = document.querySelector("#status-message");
const playerList = document.querySelector("#player-list");
const playerCount = document.querySelector("#player-count");
const leaveButton = document.querySelector("#leave-room");
const loginButton = document.querySelector("#room-login");
const resultOverlay = document.querySelector("#result-overlay");
const resultTitle = document.querySelector("#result-title");
const resultDescription = document.querySelector("#result-description");

const gameNames = {
  mafia: "مافيا",
  outsider: "مين برا السالفة",
  codenames: "كود نيمز",
  guess: "خمن واربح",
};
const winnerNames = {
  mafia: "المافيا",
  town: "أهل المدينة",
  spy: "اللاعبون خارج السالفة",
  crew: "أهل السالفة",
  red: "الفريق الأحمر",
  blue: "الفريق الأزرق",
  quiz: "الفائز",
};
const roleInfo = {
  mafia: { title: "المافيا", icon: "♟", description: "اختَروا هدفًا في الليل. اكسبوا ثقة المدينة نهارًا وتخلّصوا من خصومكم." },
  doctor: { title: "الطبيب", icon: "✚", description: "اختر لاعبًا تحميه هذه الليلة. إذا اختارته المافيا فلن يُقصى." },
  detective: { title: "المحقق", icon: "⌕", description: "تحقّق من لاعب في الليل؛ ستعرف سرًا إن كان من المافيا." },
  town: { title: "مواطن", icon: "✦", description: "ناقشوا نهارًا وصوّتوا لإخراج المشتبه به. انتصروا بإخراج كل أفراد المافيا." },
};

let currentUser = null;
let currentRoom = null;
let polling = false;
let commandBusy = false;
let pollTimer = null;
let lastStatus = null;
let roleRevealed = false;
let mafiaDealPlayed = false;
let lastAnimationKey = "";

function setMessage(text, kind = "") {
  statusMessage.textContent = text;
  statusMessage.className = `status-banner${kind ? ` ${kind}` : ""}`;
}

function appendMessage(parent, text, className = "muted-message") {
  const message = document.createElement("p");
  message.className = className;
  message.textContent = text;
  parent.append(message);
  return message;
}

function createButton(text, action, payload = {}, className = "secondary-button") {
  const button = document.createElement("button");
  button.type = "button";
  button.className = className;
  button.dataset.roomAction = action;
  button.dataset.payload = JSON.stringify(payload);
  button.textContent = text;
  button.disabled = commandBusy;
  return button;
}

function createPanel(title, text, className = "phase-card") {
  const panel = document.createElement("section");
  panel.className = className;
  const heading = document.createElement("h3");
  heading.textContent = title;
  panel.append(heading);
  if (text) appendMessage(panel, text);
  return panel;
}

function createAvatar(player) {
  const avatar = document.createElement("span");
  avatar.className = "avatar";
  avatar.textContent = (player.name || "م").trim().charAt(0) || "م";
  if (isSafeAvatarUrl(player.avatarUrl)) {
    const image = document.createElement("img");
    image.src = player.avatarUrl;
    image.alt = "";
    image.referrerPolicy = "no-referrer";
    image.addEventListener("error", () => image.remove(), { once: true });
    avatar.replaceChildren(image);
  }
  return avatar;
}

function isSafeAvatarUrl(value) {
  if (!value) return false;
  try {
    return new URL(value).protocol === "https:";
  } catch {
    return false;
  }
}

function addPlayerTag(container, text, className = "") {
  const tag = document.createElement("span");
  tag.className = `player-tag${className ? ` ${className}` : ""}`;
  tag.textContent = text;
  container.append(tag);
}

function renderPlayers(room) {
  const eliminated = room.public.eliminated || [];
  const qualified = room.public.qualified || [];
  const roles = room.public.roles || {};
  playerCount.textContent = `${new Intl.NumberFormat("ar").format(room.players.length)} / ${new Intl.NumberFormat("ar").format(room.maxPlayers)}`;
  playerList.replaceChildren();

  room.players.forEach((player) => {
    const item = document.createElement("li");
    item.className = "player-item";
    item.dataset.playerId = player.id;
    if (player.id === currentUser.id) item.classList.add("is-me");
    const isOut = eliminated.includes(player.id);
    if (isOut) item.classList.add("is-out");

    const info = document.createElement("div");
    info.className = "player-info";
    const name = document.createElement("div");
    name.className = "player-name";
    name.textContent = player.name + (player.id === currentUser.id ? " · أنت" : "");
    const badges = document.createElement("div");
    badges.className = "player-badges";
    if (player.isHost) addPlayerTag(badges, "المضيف");
    if (isOut) addPlayerTag(badges, room.game === "guess" ? "متفرج" : "مقصى", "out");
    else if (room.game === "guess" && qualified.includes(player.id)) addPlayerTag(badges, "متأهل", "safe");
    if (room.status === "finished" && roles[player.id]) addPlayerTag(badges, roleInfo[roles[player.id]]?.title || roles[player.id]);
    info.append(name, badges);
    item.append(createAvatar(player), info);
    playerList.append(item);
  });
}

function getPlayerName(room, userId) {
  return room.players.find((player) => player.id === userId)?.name || "لاعب";
}

function renderLobby(room) {
  const section = document.createElement("section");
  section.className = "game-intro";
  appendMessage(section, gameNames[room.game], "eyebrow");
  const heading = document.createElement("h2");
  heading.textContent = "الغرفة جاهزة";
  section.append(heading);
  appendMessage(section, "أرسلوا رمز الغرفة لأصحابكم. يقدرون ينضمون من صفحة ميلان، وبعد اكتمال الفريق يبدأ المضيف.");
  gameContent.append(section);

  if (room.game === "outsider" && room.hostId === currentUser.id) {
    const label = document.createElement("label");
    label.className = "setting-label";
    label.textContent = "عدد اللاعبين خارج السالفة";
    const select = document.createElement("select");
    select.id = "spy-count";
    for (let count = 1; count <= Math.max(1, Math.floor(room.players.length / 3)); count += 1) {
      const option = document.createElement("option");
      option.value = String(count);
      option.textContent = `${new Intl.NumberFormat("ar").format(count)} ${count === 1 ? "لاعب" : "لاعبين"}`;
      select.append(option);
    }
    label.append(select);
    gameContent.append(label);
  }

  const minimumPlayers = { mafia: 5, outsider: 3, codenames: 4, guess: 2 }[room.game];
  if (room.hostId === currentUser.id) {
    const actions = document.createElement("div");
    actions.className = "game-actions";
    const start = createButton("ابدأ الجولة", "start", {}, "primary-button");
    start.disabled = commandBusy || room.players.length < minimumPlayers;
    actions.append(start);
    gameContent.append(actions);
    if (room.players.length < minimumPlayers) {
      appendMessage(gameContent, `تحتاج هذه اللعبة إلى ${new Intl.NumberFormat("ar").format(minimumPlayers)} لاعبين على الأقل.`);
    }
  } else {
    appendMessage(gameContent, "انتظر المضيف حتى يبدأ الجولة.");
  }
  if (room.game === "guess") {
    appendMessage(gameContent, "كل جولة يتأهل الأسرع بالإجابة الصحيحة ويُقصى لاعب واحد، حتى يبقى فائز.");
    appendMessage(gameContent, `عدد الجولات المتوقع: ${new Intl.NumberFormat("ar").format(Math.max(1, room.players.length - 1))}.`);
  }
}

function renderMafia(room, state, me) {
  const eliminated = state.eliminated || [];
  const isOut = eliminated.includes(currentUser.id);
  const card = document.createElement("section");
  const role = roleInfo[me.role] || roleInfo.town;
  card.className = `role-card ${roleRevealed ? `${me.role}-role` : "back"}${mafiaDealPlayed ? "" : " deal-in"}`;
  mafiaDealPlayed = true;
  if (roleRevealed) {
    const icon = document.createElement("span");
    icon.className = "role-icon";
    icon.textContent = role.icon;
    const heading = document.createElement("h3");
    heading.textContent = role.title;
    const description = document.createElement("p");
    description.textContent = role.description;
    card.append(icon, heading, description);
    if (me.role === "mafia" && (me.teammates || []).length) {
      const teammates = document.createElement("p");
      teammates.textContent = `زملاؤك: ${me.teammates.map((id) => getPlayerName(room, id)).join("، ")}`;
      card.append(teammates);
    }
  } else {
    appendMessage(card, "بطاقة دورك", "eyebrow");
    const reveal = createButton("اكشف بطاقتك", "reveal-role", {}, "primary-button");
    card.append(reveal);
  }
  const roleWrap = document.createElement("div");
  roleWrap.className = "role-wrap";
  roleWrap.append(card);
  gameContent.append(roleWrap);

  if (room.status === "finished") {
    renderMafiaResult(room, state);
    return;
  }
  if (isOut) {
    appendMessage(gameContent, "تم إقصاؤك. تقدر تتابع بقية الجولة كمشاهد.", "muted-message");
    return;
  }

  if (state.phase === "night") {
    const phase = createPanel("حلّ الليل", "اختَر إجراءك السري. لن تظهر اختياراتك للاعبين الآخرين.");
    phase.classList.add("night");
    if (Number(me.actedRound) === Number(state.round)) {
      appendMessage(phase, "تم تسجيل إجراءك؛ ننتظر بقية أدوار الليل.");
    } else {
      const activePlayers = room.players.filter((player) => !eliminated.includes(player.id));
      let targets = activePlayers;
      if (me.role === "mafia") {
        const teammates = me.teammates || [];
        targets = activePlayers.filter((player) => player.id !== currentUser.id && !teammates.includes(player.id));
        appendMessage(phase, "اختاروا لاعبًا من أهل المدينة لإقصائه.");
      } else if (me.role === "doctor") {
        appendMessage(phase, "اختر لاعبًا تحميه الليلة. يمكنك حماية نفسك.");
      } else if (me.role === "detective") {
        targets = activePlayers.filter((player) => player.id !== currentUser.id);
        appendMessage(phase, "اختر لاعبًا للتحقق منه؛ ستظهر النتيجة لك وحدك.");
      } else {
        appendMessage(phase, "أنت من أهل المدينة؛ انتظروا طلوع النهار.");
      }
      if (["mafia", "doctor", "detective"].includes(me.role)) {
        const actions = document.createElement("div");
        actions.className = "game-actions";
        targets.forEach((player) => actions.append(createButton(
          `${me.role === "mafia" ? "استهدف" : me.role === "doctor" ? "احمِ" : "تحقّق من"} ${player.name}`,
          "night_action",
          { target: player.id },
        )));
        phase.append(actions);
      }
    }
    gameContent.append(phase);
  } else if (state.phase === "day") {
    const phase = createPanel("طلع النهار", state.nightEliminated
      ? `${getPlayerName(room, state.nightEliminated)} أُقصي في الليل${state.roleReveals?.[state.nightEliminated] ? ` وكان دوره: ${roleInfo[state.roleReveals[state.nightEliminated]]?.title || state.roleReveals[state.nightEliminated]}` : ""}.`
      : "لم يُقصَ أحد هذه الليلة.");
    phase.classList.add("day");
    appendMessage(phase, "ناقشوا النتيجة ثم صوّتوا لإخراج لاعب مشتبه به.");
    if (room.hostId === currentUser.id) {
      phase.append(createButton("ابدأ تصويت النهار", "begin_vote", {}, "primary-button"));
    } else {
      appendMessage(phase, "بانتظار المضيف لبدء التصويت.");
    }
    if (me.lastInvestigation?.round === state.round) {
      appendMessage(phase, me.lastInvestigation.isMafia ? "نتيجة تحقيقك: اللاعب الذي اخترته من المافيا." : "نتيجة تحقيقك: اللاعب الذي اخترته ليس من المافيا.", "round-result");
    }
    if (state.dayEliminated) {
      const roleName = roleInfo[state.roleReveals?.[state.dayEliminated]]?.title || "دور غير معروف";
      appendMessage(phase, `في تصويت النهار أُقصي ${getPlayerName(room, state.dayEliminated)} وكان دوره ${roleName}.`);
    }
    gameContent.append(phase);
  } else if (state.phase === "vote") {
    renderVote(room, state, true);
  } else if (state.phase === "night" && state.dayEliminated) {
    const roleName = roleInfo[state.roleReveals?.[state.dayEliminated]]?.title || "دور غير معروف";
    appendMessage(gameContent, `في تصويت النهار أُقصي ${getPlayerName(room, state.dayEliminated)} وكان دوره ${roleName}.`);
  }
}

function renderMafiaResult(room, state) {
  const winner = winnerNames[state.winner] || state.winner || "انتهت الجولة";
  const panel = createPanel("النتيجة", `الفائز: ${winner}. حصل الفائزون على ٢٥ XP وبقية اللاعبين على ٥ XP.`);
  const roles = state.roles || {};
  const list = document.createElement("ol");
  list.className = "score-list";
  room.players.forEach((player) => {
    const item = document.createElement("li");
    item.className = "score-item";
    const name = document.createElement("span");
    name.textContent = player.name;
    const roleName = document.createElement("strong");
    roleName.textContent = roleInfo[roles[player.id]]?.title || "—";
    item.append(name, roleName);
    list.append(item);
  });
  panel.append(list);
  gameContent.append(panel);
}

function renderVote(room, state, mafiaGame = false) {
  const phase = createPanel("التصويت مفتوح", "اختَر لاعبًا واحدًا. لا يمكن تغيير صوتك بعد إرساله.");
  const votes = state.votes || {};
  const eliminated = state.eliminated || [];
  const hasVoted = Object.prototype.hasOwnProperty.call(votes, currentUser.id);
  if (hasVoted) {
    appendMessage(phase, "تم تسجيل صوتك؛ ننتظر بقية اللاعبين.");
  } else {
    const candidates = room.players.filter((player) =>
      player.id !== currentUser.id &&
      (!mafiaGame || !eliminated.includes(player.id)) &&
      (!mafiaGame || !eliminated.includes(currentUser.id)),
    );
    const actions = document.createElement("div");
    actions.className = "game-actions";
    candidates.forEach((player) => actions.append(createButton(
      `${mafiaGame ? "صوّت لإخراج" : "صوّت على"} ${player.name}`,
      "vote",
      { target: player.id },
    )));
    phase.append(actions);
  }
  const voteCount = Object.keys(votes).length;
  appendMessage(phase, `الأصوات المسجّلة: ${new Intl.NumberFormat("ar").format(voteCount)}.`);
  gameContent.append(phase);
}

function renderOutsider(room, state, me) {
  const roleCard = createPanel(me.spy ? "أنت خارج السالفة" : "كلمتك السرية", me.spy
    ? "حاول تكتشف الكلمة من النقاش من دون ما ينكشف أمرك."
    : `الكلمة هي: ${me.word || "—"}`, "role-card");
  if (state.phase !== "result") gameContent.append(roleCard);

  if (state.phase === "discussion") {
    const phase = createPanel("وقت النقاش", "اسألوا بعض أسئلة تلميحية من دون قول الكلمة نفسها.");
    if (room.hostId === currentUser.id) phase.append(createButton("ابدأ التصويت", "begin_vote", {}, "primary-button"));
    else appendMessage(phase, "بانتظار المضيف لفتح التصويت.");
    gameContent.append(phase);
  } else if (state.phase === "vote") {
    renderVote(room, state);
  } else if (state.phase === "spy_guess") {
    const phase = createPanel("فرصة أخيرة", state.guessingSpy === currentUser.id
      ? "تم التصويت عليك. اكتب تخمينك للكلمة؛ إجابة صحيحة تمنح فريقك الفوز."
      : `${getPlayerName(room, state.guessingSpy)} يحاول تخمين الكلمة.`);
    if (state.guessingSpy === currentUser.id) {
      phase.append(createForm("guess_word", "اكتب تخمين الكلمة", "word", "إرسال التخمين"));
    }
    gameContent.append(phase);
  } else if (state.phase === "result") {
    const panel = createPanel("النتيجة", `الفائز: ${winnerNames[state.winner] || state.winner}.`);
    gameContent.append(panel);
  }
}

function createForm(action, placeholder, inputName, submitText, maxLength = 100) {
  const form = document.createElement("form");
  form.className = "text-form";
  form.dataset.roomForm = action;
  const input = document.createElement("input");
  input.name = inputName;
  input.required = true;
  input.maxLength = maxLength;
  input.placeholder = placeholder;
  const submit = document.createElement("button");
  submit.type = "submit";
  submit.className = "primary-button";
  submit.textContent = submitText;
  submit.disabled = commandBusy;
  form.append(input, submit);
  return form;
}

function renderCodenames(room, state, me) {
  const teamName = me.team === "red" ? "الأحمر" : "الأزرق";
  appendMessage(gameContent, `فريقك: ${teamName}${me.spymaster ? " · أنت قائد الفريق" : ""}`, "eyebrow");
  if (state.phase === "clue" && me.spymaster && me.team === state.turn) {
    const panel = createPanel("أعطِ تلميحًا", "اربط كلمات فريقك بتلميح من كلمة واحدة.");
    const form = document.createElement("form");
    form.className = "text-form";
    form.dataset.roomForm = "clue";
    const clue = document.createElement("input");
    clue.name = "text";
    clue.required = true;
    clue.maxLength = 40;
    clue.placeholder = "التلميح";
    const count = document.createElement("select");
    count.name = "count";
    count.className = "setting-label";
    for (let value = 1; value <= 4; value += 1) {
      const option = document.createElement("option");
      option.value = String(value);
      option.textContent = `${new Intl.NumberFormat("ar").format(value)} كلمات`;
      count.append(option);
    }
    const submit = document.createElement("button");
    submit.type = "submit";
    submit.className = "primary-button";
    submit.textContent = "إرسال التلميح";
    submit.disabled = commandBusy;
    form.append(clue, count, submit);
    panel.append(form);
    gameContent.append(panel);
  } else if (state.phase === "guess" && !me.spymaster && me.team === state.turn) {
    appendMessage(gameContent, `التلميح: ${state.clue.text} · التخمينات المتبقية: ${new Intl.NumberFormat("ar").format(state.guessesLeft)}`);
  } else if (state.phase === "clue") {
    appendMessage(gameContent, "انتظر دور قائد فريقك لإعطاء التلميح.");
  }

  const cards = document.createElement("div");
  cards.className = "word-board";
  (state.cards || []).forEach((card, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `word-card${card.revealed ? ` revealed ${card.color || ""}` : ""}`;
    button.textContent = card.word;
    button.disabled = commandBusy || card.revealed || state.phase !== "guess" || me.spymaster || me.team !== state.turn;
    button.dataset.roomAction = "guess_card";
    button.dataset.payload = JSON.stringify({ index });
    cards.append(button);
  });
  gameContent.append(cards);
  if (room.status === "finished") {
    appendMessage(gameContent, `الفائز: ${winnerNames[state.winner] || state.winner}.`, "round-result");
  }
}

function renderGuess(room, state) {
  const eliminated = state.eliminated || [];
  const qualified = state.qualified || [];
  const isOut = eliminated.includes(currentUser.id);
  const alreadyQualified = qualified.includes(currentUser.id);

  if (room.status === "finished") {
    renderGuessResult(room, state);
    return;
  }
  if (state.phase === "question") {
    appendMessage(gameContent, `الجولة ${new Intl.NumberFormat("ar").format(state.round)} من ${new Intl.NumberFormat("ar").format(state.roundLimit)} · الترتيب حسب سرعة الإجابة`, "eyebrow");
    const question = document.createElement("section");
    question.className = "question-card";
    appendMessage(question, "السؤال", "eyebrow");
    const heading = document.createElement("h2");
    heading.textContent = state.question?.q || "السؤال غير متاح";
    question.append(heading);
    gameContent.append(question);
    if (isOut) {
      appendMessage(gameContent, "تم إقصاؤك، لكن تقدر تتابع ترتيب بقية اللاعبين كمشاهد.");
    } else if (alreadyQualified) {
      const position = qualified.indexOf(currentUser.id) + 1;
      appendMessage(gameContent, `إجابة صحيحة! تأهلت بالترتيب ${new Intl.NumberFormat("ar").format(position)}. تابع الجولة كمشاهد.`, "round-result");
    } else {
      gameContent.append(createForm("answer", "اكتب إجابتك هنا", "answer", "إرسال الإجابة", 60));
    }
    if (qualified.length) {
      const names = qualified.map((id, index) => `${new Intl.NumberFormat("ar").format(index + 1)}. ${getPlayerName(room, id)}`).join(" · ");
      appendMessage(gameContent, `المتأهلون حتى الآن: ${names}`);
    }
    if (room.hostId === currentUser.id && !isOut) renderResolveControl(room, state);
  } else if (state.phase === "round_result") {
    const panel = createPanel("انتهت الجولة", `${getPlayerName(room, state.lastEliminated)} خرج من المنافسة. بقية المؤهلين يتابعون للجولة التالية.`);
    panel.classList.add("elimination-flash");
    renderQualifiedList(room, state, panel);
    if (room.hostId === currentUser.id) panel.append(createButton("ابدأ الجولة التالية", "next_question", {}, "primary-button"));
    else appendMessage(panel, "بانتظار المضيف لبدء الجولة التالية.");
    gameContent.append(panel);
  }
}

function renderResolveControl(room, state) {
  const qualified = state.qualified || [];
  const eliminated = state.eliminated || [];
  const candidates = room.players.filter((player) => !qualified.includes(player.id) && !eliminated.includes(player.id));
  if (!candidates.length) return;
  const panel = createPanel("تعذّر حسم الجولة؟", "إذا توقفت الإجابات، يقدر المضيف إنهاء الجولة وإقصاء لاعب لم يجب.");
  const form = document.createElement("form");
  form.className = "text-form";
  form.dataset.roomForm = "resolve_quiz_round";
  const select = document.createElement("select");
  select.name = "target";
  select.setAttribute("aria-label", "اللاعب الذي سيُقصى");
  candidates.forEach((player) => {
    const option = document.createElement("option");
    option.value = player.id;
    option.textContent = player.name;
    select.append(option);
  });
  const submit = document.createElement("button");
  submit.type = "submit";
  submit.className = "danger-button";
  submit.textContent = "إقصاء اللاعب المحدد";
  submit.disabled = commandBusy;
  form.append(select, submit);
  panel.append(form);
  gameContent.append(panel);
}

function renderQualifiedList(room, state, parent) {
  const list = document.createElement("ol");
  list.className = "score-list";
  (state.qualified || []).forEach((id) => {
    const item = document.createElement("li");
    item.className = "score-item";
    const name = document.createElement("span");
    name.textContent = getPlayerName(room, id);
    const status = document.createElement("strong");
    status.textContent = "متأهل";
    item.append(name, status);
    list.append(item);
  });
  const eliminated = room.players.find((player) => player.id === state.lastEliminated);
  if (eliminated) {
    const item = document.createElement("li");
    item.className = "score-item";
    const name = document.createElement("span");
    name.textContent = eliminated.name;
    const status = document.createElement("strong");
    status.textContent = "إقصاء";
    status.style.color = "var(--room-red)";
    item.append(name, status);
    list.append(item);
  }
  parent.append(list);
}

function renderGuessResult(room, state) {
  const winners = state.winners || [];
  const champion = winners[0];
  const panel = createPanel("بطل خمن واربح", `${getPlayerName(room, champion)} هو الفائز. تم احتساب XP للمشاركين.`);
  const ranking = document.createElement("ol");
  ranking.className = "score-list";
  const ordered = [champion, ...(state.eliminated || []).slice().reverse()];
  ordered.forEach((id, index) => {
    const item = document.createElement("li");
    item.className = "score-item";
    const name = document.createElement("span");
    name.textContent = getPlayerName(room, id);
    const place = document.createElement("strong");
    place.textContent = index === 0 ? "البطل" : `المركز ${new Intl.NumberFormat("ar").format(index + 1)}`;
    item.append(name, place);
    ranking.append(item);
  });
  panel.append(ranking);
  gameContent.append(panel);
}

function renderResult(room) {
  const state = room.public;
  if (room.game === "mafia") return renderMafiaResult(room, state);
  if (room.game === "guess") return renderGuessResult(room, state);
  const winner = winnerNames[state.winner] || state.winner || "انتهت الجولة";
  const panel = createPanel("انتهت الجولة", `الفائز: ${winner}. تم توزيع نقاط XP.`);
  gameContent.append(panel);
}

function renderRoom(room) {
  const previousStatus = lastStatus;
  currentRoom = room;
  leaveButton.hidden = false;
  roomTitle.textContent = gameNames[room.game] || "غرفة ميلان";
  gameLabel.textContent = room.status === "lobby" ? "بانتظار اللاعبين" : room.status === "finished" ? "انتهت الجولة" : "اللعب مستمر";
  roomCodeDisplay.textContent = room.code;
  renderPlayers(room);
  gameContent.replaceChildren();

  if (room.status === "lobby") renderLobby(room);
  else if (room.status === "finished" || room.public.phase === "result") renderResult(room);
  else if (room.game === "mafia") renderMafia(room, room.public, room.me);
  else if (room.game === "outsider") renderOutsider(room, room.public, room.me);
  else if (room.game === "codenames") renderCodenames(room, room.public, room.me);
  else renderGuess(room, room.public);

  const eliminatedId = room.public.lastEliminated || room.public.dayEliminated || room.public.nightEliminated;
  const animationKey = `${room.game}:${room.public.phase}:${room.public.round}:${eliminatedId || ""}`;
  if (eliminatedId && animationKey !== lastAnimationKey) {
    playerList.querySelectorAll(".player-item").forEach((item) => {
      if (item.dataset.playerId === eliminatedId) item.classList.add("elimination-flash");
    });
    lastAnimationKey = animationKey;
  }
  if (room.status === "finished" && previousStatus !== "finished") showResultOverlay(room);
  lastStatus = room.status;
  setMessage(room.status === "finished"
    ? `انتهت اللعبة · ${winnerNames[room.public.winner] || room.public.winner || ""}`
    : room.status === "lobby"
      ? "الغرفة مفتوحة، شاركوا الرمز مع أصدقائكم."
      : `${gameNames[room.game]} · الجولة ${new Intl.NumberFormat("ar").format(room.public.round || 1)} · ${phaseLabel(room.public.phase)}`,
  room.status === "finished" ? "success" : "");
}

function phaseLabel(phase) {
  return ({
    night: "الليل",
    day: "النهار",
    discussion: "النقاش",
    vote: "التصويت",
    spy_guess: "تخمين الكلمة",
    clue: "التلميح",
    guess: "التخمين",
    question: "السؤال",
    round_result: "نتيجة الجولة",
  })[phase] || phase || "";
}

function showResultOverlay(room) {
  const state = room.public;
  let winner;
  let didWin = false;
  if (room.game === "mafia") {
    didWin = (state.winner === "mafia" && room.me.role === "mafia") ||
      (state.winner === "town" && room.me.role !== "mafia");
    winner = winnerNames[state.winner] || state.winner;
  } else if (room.game === "outsider") {
    didWin = (state.winner === "spy" && room.me.spy) || (state.winner === "crew" && !room.me.spy);
    winner = winnerNames[state.winner] || state.winner;
  } else if (room.game === "codenames") {
    didWin = room.me.team === state.winner;
    winner = winnerNames[state.winner] || state.winner;
  } else {
    didWin = (state.winners || []).includes(currentUser.id);
    winner = getPlayerName(room, (state.winners || [])[0]);
  }
  resultTitle.textContent = didWin ? "مبروك الفوز!" : "انتهت الجولة";
  resultDescription.textContent = room.game === "guess"
    ? `${winner} حسم اللقب. ${didWin ? "أُضيفت لك نقاط XP." : "تابع ترتيبك في لوحة النتائج."}`
    : `الفائز: ${winner}. ${didWin ? "أُضيفت لك نقاط XP." : "جولة جديدة بانتظاركم."}`;
  resultOverlay.classList.toggle("is-victory", didWin);
  resultOverlay.classList.toggle("is-defeat", !didWin);
  resultOverlay.hidden = false;
}

function renderError(text) {
  roomTitle.textContent = "تعذّر فتح الغرفة";
  gameLabel.textContent = "غرفة ميلان";
  leaveButton.hidden = true;
  gameContent.replaceChildren();
  const panel = createPanel("تعذّر فتح الغرفة", text);
  const link = document.createElement("a");
  link.className = "primary-button";
  link.href = "index.html#games";
  link.textContent = "العودة إلى الألعاب";
  panel.append(link);
  gameContent.append(panel);
}

async function fetchSnapshot() {
  if (!supabaseClient || !currentUser || !roomCode || polling) return;
  polling = true;
  let data;
  let error;
  try {
    ({ data, error } = await supabaseClient.rpc("milan_room_snapshot", { p_code: roomCode }));
  } catch (requestError) {
    setMessage(requestError.message || "تعذّر الاتصال بالغرفة.", "error");
    return;
  } finally {
    polling = false;
  }
  if (error) {
    setMessage(error.message || "تعذّر تحديث الغرفة.", "error");
    if (/الغرفة غير موجودة|لست عضواً/i.test(error.message || "")) {
      renderError("لازم تنضم إلى الغرفة من صفحة الألعاب قبل فتح هذا الرابط.");
    }
    return;
  }
  renderRoom(data);
}

async function runCommand(action, payload = {}) {
  if (!supabaseClient || !currentUser || commandBusy) return;
  commandBusy = true;
  setMessage("جاري تسجيل الإجراء...", "");
  let data;
  let error;
  try {
    ({ data, error } = await supabaseClient.rpc("milan_room_command", {
      p_action: action,
      p_code: roomCode,
      p_display_name: currentUser.user_metadata?.global_name || currentUser.user_metadata?.name || "لاعب ميلان",
      p_payload: payload,
    }));
  } catch (requestError) {
    commandBusy = false;
    if (currentRoom) renderRoom(currentRoom);
    setMessage(requestError.message || "تعذّر الاتصال بالخادم.", "error");
    return;
  }
  commandBusy = false;
  if (error) {
    if (currentRoom) renderRoom(currentRoom);
    setMessage(error.message || "تعذّر تنفيذ الإجراء.", "error");
    return;
  }
  if (data?.left) {
    window.location.assign("index.html#games");
    return;
  }
  if (data?.code) {
    renderRoom(data);
  }
}

function beginPolling() {
  if (pollTimer) window.clearInterval(pollTimer);
  pollTimer = window.setInterval(() => void fetchSnapshot(), 1700);
}

document.querySelector("#copy-code").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(roomCode);
    setMessage("تم نسخ رمز الغرفة.", "success");
  } catch {
    setMessage(`انسخ رمز الغرفة يدويًا: ${roomCode}`, "error");
  }
});

document.querySelector("#result-close").addEventListener("click", () => {
  resultOverlay.hidden = true;
});

document.querySelector("#leave-room").addEventListener("click", () => {
  void runCommand("leave");
});

document.querySelector("#room-login").addEventListener("click", async () => {
  if (!supabaseClient) {
    setMessage("إعدادات Supabase غير موجودة في supabase-config.js.", "error");
    return;
  }
  const { error } = await supabaseClient.auth.signInWithOAuth({
    provider: "discord",
    options: { redirectTo: window.location.href, scopes: "identify email" },
  });
  if (error) setMessage(error.message, "error");
});

gameContent.addEventListener("click", (event) => {
  const button = event.target.closest("[data-room-action]");
  if (!button || commandBusy) return;
  const action = button.dataset.roomAction;
  let payload = {};
  try {
    payload = JSON.parse(button.dataset.payload || "{}");
  } catch {
    setMessage("تعذّر قراءة الإجراء. حدّث الصفحة وحاول مجددًا.", "error");
    return;
  }
  if (action === "reveal-role") {
    roleRevealed = true;
    if (currentRoom) renderRoom(currentRoom);
    return;
  }
  if (action === "start" && currentRoom?.game === "outsider") {
    payload.spyCount = Number(document.querySelector("#spy-count")?.value || 1);
  }
  if (action === "start" && currentRoom?.game === "mafia") {
    roleRevealed = false;
    mafiaDealPlayed = false;
  }
  void runCommand(action, payload);
});

gameContent.addEventListener("submit", (event) => {
  const form = event.target.closest("[data-room-form]");
  if (!form) return;
  event.preventDefault();
  const values = new FormData(form);
  const payload = Object.fromEntries(values.entries());
  if (payload.count) payload.count = Number(payload.count);
  void runCommand(form.dataset.roomForm, payload);
});

async function initialize() {
  if (!/^[A-F0-9]{6}$/.test(roomCode)) {
    setMessage("رابط الغرفة غير صالح. ارجع إلى الألعاب واستخدم رمزًا صحيحًا.", "error");
    renderError("تأكد من رمز الغرفة الموجود في الرابط.");
    return;
  }
  if (!supabaseClient) {
    setMessage("إعدادات Supabase غير مهيأة.", "error");
    renderError("أضف رابط Supabase ومفتاح النشر في supabase-config.js.");
    return;
  }
  roomCodeDisplay.textContent = roomCode;
  const { data, error } = await supabaseClient.auth.getSession();
  if (error) {
    setMessage(error.message, "error");
    return;
  }
  currentUser = data.session?.user || null;
  if (!currentUser) {
    loginButton.hidden = false;
    setMessage("سجّل الدخول عبر Discord لفتح الغرفة.", "error");
    gameContent.replaceChildren();
    const panel = createPanel("مرحبًا بك في ميلان", "سجّل الدخول بالحساب الذي انضم إلى هذه الغرفة. إذا لم تنضم بعد، استخدم صفحة الألعاب أولًا.");
    gameContent.append(panel);
    return;
  }
  await fetchSnapshot();
  beginPolling();
}

if (supabaseClient) {
  supabaseClient.auth.onAuthStateChange((_event, session) => {
    if (session?.user && (!currentUser || session.user.id !== currentUser.id)) {
      currentUser = session.user;
      void fetchSnapshot();
      beginPolling();
    }
  });
}

void initialize();
