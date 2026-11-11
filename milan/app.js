const gameGrid = document.querySelector("#game-grid");
const searchInput = document.querySelector("#game-search");
const emptyState = document.querySelector("#empty-state");
const dialog = document.querySelector("#room-dialog");
const dialogTitle = document.querySelector("#dialog-title");
const dialogDescription = document.querySelector("#dialog-description");
const dialogNote = document.querySelector("#dialog-note");
const roomForm = document.querySelector("#room-form");
const playerNameInput = document.querySelector("#player-name");
const playerCount = document.querySelector("#player-count");
const joinFields = document.querySelector("#join-fields");
const roomCodeInput = document.querySelector("#room-code-input");
const lobby = document.querySelector("#room-lobby");
const playerList = document.querySelector("#player-list");
const lobbyMessage = document.querySelector("#lobby-message");
const roomCodeDisplay = document.querySelector("#room-code");
const playerTotal = document.querySelector("#player-total");

document.querySelector("#year").textContent = new Date().getFullYear();

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

let activeChannel = null;
let activeRoomCode = null;
let localPlayer = null;
let selectedGame = null;

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

function showStatus(message, isError) {
  dialogNote.textContent = message;
  dialogNote.className = isError ? "dialog-note error-message" : "dialog-note";
}

function createRoomCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const randomValues = new Uint8Array(6);
  crypto.getRandomValues(randomValues);
  return [...randomValues].map((value) => alphabet[value % alphabet.length]).join("");
}

function updatePlayerList() {
  if (!activeChannel) return;

  const presence = activeChannel.presenceState();
  const players = Object.values(presence).flat().filter((player) => player && player.id);
  const uniquePlayers = [...new Map(players.map((player) => [player.id, player])).values()];

  playerList.replaceChildren();
  uniquePlayers.forEach((player) => {
    const item = document.createElement("li");
    const name = document.createElement("span");
    const badge = document.createElement("span");
    name.textContent = player.name;
    badge.textContent = player.id === localPlayer.id ? "أنت" : "";
    item.append(name, badge);
    playerList.append(item);
  });
  playerTotal.textContent = `(${uniquePlayers.length})`;

  const host = uniquePlayers.find((player) => player.isHost);
  lobbyMessage.textContent = host
    ? `${uniquePlayers.length} من ${host.maxPlayers} لاعبين · ${host.game}`
    : `بانتظار صاحب الغرفة · ${selectedGame}`;
}

async function leaveActiveRoom() {
  if (!activeChannel) return;

  const channel = activeChannel;
  activeChannel = null;
  activeRoomCode = null;
  localPlayer = null;
  await supabaseClient.removeChannel(channel);
}

function connectToRoom(roomCode, name, maxPlayers, isHost) {
  if (!supabaseClient) {
    showStatus(
      "الاتصال غير مهيأ بعد. أضيفوا رابط مشروع Supabase ومفتاح anon في ملف supabase-config.js.",
      true,
    );
    return;
  }

  if (!name.trim()) {
    showStatus("اكتب اسمك عشان أصحابك يعرفونك في الغرفة.", true);
    playerNameInput.focus();
    return;
  }

  if (activeChannel) {
    showStatus("فيه اتصال بغرفة مفتوحة بالفعل. غادرها أولًا.", true);
    return;
  }

  activeRoomCode = roomCode;
  localPlayer = {
    id: crypto.randomUUID(),
    name: name.trim(),
    maxPlayers,
    isHost,
    game: selectedGame,
  };
  showStatus("جاري الاتصال بالغرفة...", false);

  activeChannel = supabaseClient.channel(`milan-room-${roomCode}`, {
    config: { presence: { key: localPlayer.id } },
  });
  activeChannel
    .on("presence", { event: "sync" }, updatePlayerList)
    .subscribe(async (status, error) => {
      if (status === "SUBSCRIBED") {
        try {
          const result = await activeChannel.track(localPlayer);
          if (result !== "ok") throw new Error("تعذر تسجيل اللاعب في الغرفة.");

          roomCodeDisplay.textContent = activeRoomCode;
          roomForm.hidden = true;
          lobby.hidden = false;
          dialogNote.hidden = true;
          updatePlayerList();
        } catch (connectionError) {
          showStatus(connectionError.message || "تعذر الانضمام للغرفة.", true);
          await leaveActiveRoom();
        }
        return;
      }

      if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
        showStatus(error?.message || "فشل الاتصال بالغرفة. تحققوا من إعدادات Supabase وحاولوا مجددًا.", true);
        await leaveActiveRoom();
      }
    });
}

function resetRoomDialog() {
  void leaveActiveRoom();
  roomForm.hidden = false;
  lobby.hidden = true;
  joinFields.hidden = true;
  dialogNote.hidden = false;
  showStatus("أدخلوا بيانات مشروع Supabase لتفعيل الغرف الأونلاين.", false);
  roomCodeInput.value = "";
}

gameGrid.addEventListener("click", (event) => {
  const button = event.target.closest("[data-game]");
  if (!button) return;

  const card = button.closest(".game-card");
  selectedGame = button.dataset.game;
  dialogTitle.textContent = selectedGame;
  dialogDescription.textContent = card.dataset.description;
  roomForm.reset();
  roomForm.hidden = false;
  lobby.hidden = true;
  joinFields.hidden = true;
  dialogNote.hidden = false;
  showStatus(
    supabaseClient
      ? "أنشئ غرفة وشارك رمزها مع أصحابك، أو انضم برمز وصلك."
      : "أضيفوا رابط مشروع Supabase ومفتاح anon في supabase-config.js لتفعيل اللعب أونلاين.",
    !supabaseClient,
  );
  playerCount.replaceChildren();
  for (let count = Number(card.dataset.minPlayers); count <= Number(card.dataset.maxPlayers); count += 1) {
    const option = document.createElement("option");
    option.value = String(count);
    option.textContent = `${new Intl.NumberFormat("ar").format(count)} لاعبين`;
    playerCount.append(option);
  }
  dialog.showModal();
});

roomForm.addEventListener("submit", (event) => {
  event.preventDefault();
  connectToRoom(
    createRoomCode(),
    playerNameInput.value,
    Number(playerCount.value),
    true,
  );
});

document.querySelector("#show-join").addEventListener("click", () => {
  joinFields.hidden = !joinFields.hidden;
  if (!joinFields.hidden) roomCodeInput.focus();
});

document.querySelector("#join-room").addEventListener("click", () => {
  const roomCode = roomCodeInput.value.trim().toUpperCase();
  if (!/^[A-HJ-NP-Z2-9]{6}$/.test(roomCode)) {
    showStatus("رمز الغرفة لازم يكون ٦ أحرف أو أرقام.", true);
    roomCodeInput.focus();
    return;
  }
  connectToRoom(roomCode, playerNameInput.value, null, false);
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
  await leaveActiveRoom();
  resetRoomDialog();
});

document.querySelector("#dialog-close").addEventListener("click", () => {
  dialog.close();
});

dialog.addEventListener("close", resetRoomDialog);
