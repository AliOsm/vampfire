import { cleanClipboard, formatEditor, highlightMessages } from "./editor.js";
import {
  state,
  $,
  $$,
  escape,
  icon,
  button,
  avatar,
  api,
  loadUsers,
  toast,
  modal,
  closeModal,
  field,
  formEnd,
  copy,
  admin,
  confirmAction,
  upload,
  messageId,
} from "./ui.js";

const sounds = [
  "56k",
  "ballmer",
  "bell",
  "bezos",
  "bueller",
  "butts",
  "clowntown",
  "cottoneyejoe",
  "crickets",
  "curb",
  "dadgummit",
  "dangerzone",
  "danielsan",
  "deeper",
  "donotwant",
  "drama",
  "flawless",
  "glados",
  "gogogo",
  "greatjob",
  "greyjoy",
  "guarantee",
  "heygirl",
  "honk",
  "horn",
  "horror",
  "inconceivable",
  "letitgo",
  "live",
  "loggins",
  "makeitso",
  "noooo",
  "nyan",
  "ohmy",
  "ohyeah",
  "pushit",
  "rimshot",
  "rollout",
  "rumble",
  "sax",
  "secret",
  "sexyback",
  "story",
  "tada",
  "tmyk",
  "totes",
  "trololo",
  "trombone",
  "unix",
  "vuvuzela",
  "what",
  "whoomp",
  "wups",
  "yay",
  "yeah",
  "yodel",
];
let replyId = 0,
  editId = 0,
  sendingId = null,
  typingTimer,
  typingLast = 0,
  loadingOlder = false;
let currentRequest = 0;
let historical = false;
const fileQueues = new Map();
let suggestionIndex = 0;

export function clearPendingFiles() {
  for (const queue of fileQueues.values())
    for (const item of queue)
      if (item.preview) URL.revokeObjectURL(item.preview);
  fileQueues.clear();
}
const soundImages = {
  deeper: "top",
  ...Object.fromEntries(
    [
      "56k",
      "clowntown",
      "curb",
      "dangerzone",
      "donotwant",
      "drama",
      "greatjob",
      "loggins",
      "nyan",
      "pushit",
      "rumble",
      "what",
      "yay",
      "yeah",
    ].map((name) => [name, name]),
  ),
};
const typingPeople = new Map();

export function renderSidebar() {
  const section = (title, rooms, action) =>
    `<section class="room-group"><div class="section-label"><h2>${title}</h2>${action ? button(action, '<span class="sr-only">New ' + title.toLowerCase() + "</span>", "plus") : ""}</div><ul role="list">${rooms.map((room) => `<li><a href="/rooms/${room.id}" data-room="${room.id}" ${state.room?.id === room.id ? 'aria-current="page"' : ""}>${icon(room.kind === "direct" ? "messages" : room.kind === "closed" ? "lock" : "everyone")}<span class="room-name">${escape(room.name)}</span>${room.unread ? `<span class="badge" aria-label="${room.unread} unread messages">${room.unread > 99 ? "99+" : room.unread}</span>` : ""}</a></li>`).join("")}</ul>${rooms.length ? "" : `<p class="sidebar-hint">${title === "Pings" ? "A conversation, just for your people." : "No rooms yet."}</p>`}</section>`;
  const shared = state.rooms.filter(
    (r) => r.kind !== "direct" && r.involvement !== "invisible",
  );
  const directs = state.rooms.filter(
    (r) => r.kind === "direct" && r.involvement !== "invisible",
  );
  $("#sidebar").innerHTML =
    `<a class="brand" href="/" aria-label="Homepage"><img src="${state.account.logo_id ? "/logo" : "/assets/app-icon.png"}" alt=""><span>${escape(state.account.name)}</span></a>
    <button type="button" class="search-launch" data-action="search">${icon("search")}<span>Search messages</span><kbd>/</kbd></button>
    <nav aria-label="Conversations">${section("Rooms", shared, admin() || !state.account.restrict_rooms ? "new-room" : "")}${section("Pings", directs, "new-ping")}</nav>
    <div class="sidebar-bottom">${button("invite", "Invite people", "link")}${button("people", "People & settings", "everyone")}<button type="button" class="profile-launch" data-action="profile">${avatar(state.user)}<span><strong>${escape(state.user.name)}</strong><small>Your profile & preferences</small></span></button></div>`;
  const total = state.rooms.reduce(
    (sum, r) => sum + (r.involvement !== "invisible" ? r.unread : 0),
    0,
  );
  document.title = `${total ? "(" + total + ") " : ""}${state.room?.name ? state.room.name + " · " : ""}${state.account.name}`;
  if ("setAppBadge" in navigator)
    (total ? navigator.setAppBadge(total) : navigator.clearAppBadge()).catch(
      () => {},
    );
}

let roomsRefresh = null;
let roomsDirty = false;

export function refreshRooms() {
  roomsDirty = true;
  if (roomsRefresh) return roomsRefresh;
  const userId = state.user.id;
  roomsRefresh = (async () => {
    do {
      roomsDirty = false;
      await new Promise((resolve) => setTimeout(resolve, 40));
      const rooms = await api("/api/rooms");
      if (state.user.id !== userId) return;
      state.rooms = rooms;
      if (state.room)
        state.room = rooms.find((room) => room.id === state.room.id) || null;
      if ($("#sidebar")) renderSidebar();
    } while (roomsDirty);
  })().finally(() => {
    roomsRefresh = null;
  });
  return roomsRefresh;
}

export async function openRoom(id, at = 0) {
  historical = at > 0;
  const request = ++currentRequest;
  const room = state.rooms.find((r) => r.id === id);
  if (!room) {
    toast("That room is not available.");
    return;
  }
  saveDraft();
  replyId = 0;
  editId = 0;
  sendingId = null;
  typingPeople.clear();
  state.room = room;
  state.view = "chat";
  state.messages = [];
  renderSidebar();
  document.body.classList.remove("sidebar-open");
  $("#main").innerHTML =
    `<header class="room-header">${button("menu", '<span class="sr-only">Open navigation</span>', "menu", 'class="mobile-only"')}<div class="room-heading"><h1>${escape(room.name)}</h1><p id="presence">${room.kind === "open" ? "Open to everyone" : room.kind === "closed" ? "Private room" : "Private conversation"} · ${room.members.length} people</p></div>${button("room-settings", '<span class="sr-only">Room settings</span>', "menu-dots-horizontal")}</header>
    <div id="connection" class="connection" role="status" hidden>Reconnecting…</div>
    <div id="messages" class="messages" tabindex="0" aria-label="Messages"><p class="loading">Loading messages…</p></div>
    <div class="composer-wrap"><div id="typing" class="typing" aria-live="polite"></div><form id="composer"><div id="reply-bar" hidden></div><div id="pending-files" class="pending-files" hidden></div>
      <div id="editor" contenteditable="true" role="textbox" aria-label="Message" aria-multiline="true" data-placeholder="Write a message…" spellcheck="true"></div>
      <div id="suggestions" hidden></div><div class="composer-toolbar"><div class="format-tools">
      ${button("format-bold", '<span class="sr-only">Bold</span>', "", 'class="format-button" aria-keyshortcuts="Control+B"').replace("</button>", '<b aria-hidden="true">B</b></button>')}
      ${button("format-italic", '<span class="sr-only">Italic</span>', "", 'class="format-button"').replace("</button>", '<i aria-hidden="true">I</i></button>')}
      ${button("format-code", '<span class="sr-only">Code block</span>', "code")}${button("format-list", '<span class="sr-only">Bulleted list</span>', "list")}${button("format-table", '<span class="sr-only">Insert table</span>', "list")}${button("format-link", '<span class="sr-only">Insert link</span>', "link")}${button("format-more", '<span class="sr-only">More formatting</span>', "menu-dots-horizontal")}
      <span class="tool-divider"></span>${button("attach", '<span class="sr-only">Attach files</span>', "attachment")}${button("mention", '<span class="sr-only">Mention someone</span>', "everyone")}${button("sounds", '<span class="sr-only">Play a sound</span>', "sound")}
      </div><button type="submit" class="primary">Send ${icon("arrow-up")}</button></div><input type="file" id="file-picker" name="files" multiple hidden></form><p class="composer-help">Enter to send · Shift + Enter for a new line <span id="draft-status"></span></p></div>`;
  const editor = $("#editor");
  editor.innerHTML = localStorage.getItem(draftKey(id)) || "";
  localStorage.setItem(`last-room:${state.user.id}`, String(id));
  bindComposer();
  renderFiles();
  const messages = await api(
    `/api/rooms/${id}/messages${at ? "?around=" + at : ""}`,
  );
  if (request !== currentRequest) return;
  state.messages = messages;
  renderMessages();
  if (at) $("#message-" + at)?.scrollIntoView({ block: "center" });
  else scrollEnd();
  socketSend({ type: "subscribe", room_id: id });
  await markRead();
  if (matchMedia("(min-width: 768px)").matches) editor.focus();
}

function attachment(message) {
  const file = message.attachment;
  if (!file?.id) return "";
  const url = `/uploads/${file.id}`;
  const caption = `<a class="file-caption" href="${url}" download>${icon("download")}${escape(file.name)}<small>${(file.size / 1024).toFixed(1)} KB</small></a>`;
  if (file.mime.startsWith("image/"))
    return `<figure><button type="button" class="image-button" data-action="lightbox" data-id="${message.id}" aria-label="Open ${escape(file.name)}"><img class="message-image" src="${url}${file.thumb ? "?thumb=1" : ""}" alt="${escape(file.name)}" loading="lazy"></button>${caption}</figure>`;
  if (file.mime.startsWith("video/"))
    return `<figure><video controls preload="metadata" ${file.thumb ? `poster="${url}?thumb=1"` : ""} src="${url}"></video>${caption}</figure>`;
  if (file.mime.startsWith("audio/"))
    return `<figure><audio controls preload="metadata" src="${url}"></audio>${caption}</figure>`;
  return `<div class="file-attachment">${caption}</div>`;
}

export function messageHTML(message, search = false) {
  const person = {
    id: message.user_id,
    name: message.name,
    avatar_id: message.avatar_id,
  };
  const time = new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(message.created_at));
  const day = new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
  }).format(new Date(message.created_at));
  const sound = message.plain?.match(/^\/play (\w+)$/)?.[1];
  const body =
    sound && sounds.includes(sound)
      ? `<button type="button" class="sound-message" data-action="play-sound" data-sound="${sound}">${soundImages[sound] ? `<img src="/assets/sounds/${soundImages[sound]}.webp" alt="" loading="lazy">` : icon("sound")} Play ${escape(sound)}</button>`
      : `<div class="message-body prose">${message.body}</div>`;
  const preview = message.preview?.title
    ? `<a class="link-preview" href="${escape(message.preview.url)}" target="_blank" rel="noopener noreferrer">${message.preview.image_id ? `<img src="/uploads/${message.preview.image_id}?thumb=1" alt="" loading="lazy">` : ""}<div><strong>${escape(message.preview.title)}</strong><p>${escape(message.preview.description)}</p><small>${escape(new URL(message.preview.url).hostname)}</small></div></a>`
    : "";
  return `<article class="message" id="message-${message.id}" data-id="${message.id}"><button type="button" class="avatar-button" data-action="show-person" data-id="${message.user_id}" aria-label="View ${escape(message.name)}">${avatar(person)}</button><div class="message-content"><div class="message-meta"><button type="button" data-action="show-person" data-id="${message.user_id}">${escape(message.name)}</button><a href="/rooms/${message.room_id}?at=${message.id}" data-permalink="${message.id}" title="${day}"><time datetime="${new Date(message.created_at).toISOString()}">${search ? day + ", " : ""}${time}</time></a>${message.updated_at > message.created_at ? "<small>edited</small>" : ""}</div>
    ${message.reply_id ? `<button type="button" class="reply-reference" data-action="jump-message" data-id="${message.reply_id}" data-room-id="${message.room_id}">${icon("reply")} Reply to message #${message.reply_id}</button>` : ""}${body}${attachment(message)}${preview}
    <div class="boosts">${(message.boosts || []).map((boost) => `<button type="button" data-action="${boost.user_id === state.user.id ? "remove-boost" : "boost-info"}" data-id="${boost.id}" title="${escape(boost.name)}" aria-label="${escape(boost.name)} boosted: ${escape(boost.content)}">${escape(boost.content)}<span>${escape(boost.name.split(" ")[0])}</span></button>`).join("")}</div></div>
    <div class="message-actions" aria-label="Message actions">${button("reply", '<span class="sr-only">Reply</span>', "reply", `data-id="${message.id}"`)}${button("boost", '<span class="sr-only">Boost</span>', "boost", `data-id="${message.id}"`)}${button("message-menu", '<span class="sr-only">More message actions</span>', "menu-dots-horizontal", `data-id="${message.id}"`)}</div></article>`;
}

export function renderMessages() {
  const element = $("#messages");
  if (!element || state.view !== "chat") return;
  const bottom =
    element.scrollHeight - element.scrollTop - element.clientHeight < 120;
  const previous = element.scrollTop;
  let date = "";
  const contents = state.messages
    .map((message) => {
      const value = new Date(message.created_at).toLocaleDateString(undefined, {
        weekday: "long",
        month: "long",
        day: "numeric",
      });
      const separator =
        value !== date
          ? `<div class="day-divider"><span>${escape(value)}</span></div>`
          : "";
      date = value;
      return separator + messageHTML(message);
    })
    .join("");
  element.innerHTML = state.messages.length
    ? `<div class="history-control">${button("older", "Load earlier messages", "arrow-up")}</div>${contents}<div id="message-end"></div>${historical ? `<div class="history-control">${button("newer", "Load newer messages", "arrow-down")}${button("latest", "Go to latest messages", "arrow-down")}</div>` : ""}`
    : `<div class="empty-room"><img src="/assets/icons/messages-empty.svg" alt=""><h2>A little space to talk.</h2><p>Share an idea, ask a question, or say hello.<br>This is the beginning of ${escape(state.room.name)}.</p>${button("invite", "Invite your people", "link")}</div>`;
  highlightMessages(element);
  if (bottom) scrollEnd();
  else element.scrollTop = previous;
}

export function scrollEnd() {
  const element = $("#messages");
  if (element) element.scrollTop = element.scrollHeight;
}
function draftKey(id) {
  return `vampfire-draft-${state.user.id}-${id}`;
}
export function saveDraft() {
  if (state.room && $("#editor") && !editId)
    localStorage.setItem(draftKey(state.room.id), $("#editor").innerHTML);
}
function socketSend(value) {
  if (state.socket?.readyState === WebSocket.OPEN)
    state.socket.send(JSON.stringify(value));
}
export function updatePresence() {
  socketSend({
    type: "subscribe",
    room_id:
      !document.hidden && state.view === "chat" ? state.room?.id || 0 : 0,
  });
}

function bindComposer() {
  const editor = $("#editor");
  $("#composer").addEventListener("submit", (event) => {
    event.preventDefault();
    sendMessage().catch((e) => toast(e.message));
  });
  editor.addEventListener("input", () => {
    saveDraft();
    $("#draft-status").textContent = editor.textContent.trim()
      ? "Draft saved on this device"
      : "";
    clearTimeout(typingTimer);
    if (Date.now() - typingLast > 1500) {
      socketSend({ type: "typing" });
      typingLast = Date.now();
    }
    typingTimer = setTimeout(() => socketSend({ type: "stop_typing" }), 2000);
    suggestMentions();
  });
  editor.addEventListener("keydown", (event) => {
    if (event.isComposing) return;
    const suggestions = $("#suggestions");
    const choices = $$("button", suggestions);
    if (!suggestions.hidden && choices.length) {
      if (["ArrowDown", "ArrowUp"].includes(event.key)) {
        event.preventDefault();
        suggestionIndex =
          (suggestionIndex +
            (event.key === "ArrowDown" ? 1 : -1) +
            choices.length) %
          choices.length;
        choices.forEach((choice, index) =>
          choice.classList.toggle("selected", index === suggestionIndex),
        );
        return;
      }
      if (["Enter", "Tab"].includes(event.key)) {
        event.preventDefault();
        insertMention(Number(choices[suggestionIndex].dataset.id));
        return;
      }
      if (event.key === "Escape") {
        suggestions.hidden = true;
        return;
      }
    }
    if (event.key === "Enter" && !event.shiftKey && !event.altKey) {
      event.preventDefault();
      sendMessage().catch((e) => toast(e.message));
    }
    if (event.key === "ArrowUp" && !editor.textContent.trim() && !editId) {
      const own = state.messages.findLast((m) => m.user_id === state.user.id);
      if (own) editMessage(own);
    }
    if (event.key === "Escape") {
      $("#suggestions").hidden = true;
      cancelReply();
    }
  });
  editor.addEventListener("paste", (event) => {
    const files = [...(event.clipboardData?.files || [])];
    if (files.length) {
      event.preventDefault();
      queueFiles(files);
      return;
    }
    const html = event.clipboardData?.getData("text/html");
    if (html) {
      event.preventDefault();
      document.execCommand("insertHTML", false, cleanClipboard(html));
    }
  });
  $("#file-picker").addEventListener("change", (event) =>
    queueFiles([...event.target.files]),
  );
  $("#composer").addEventListener("dragover", (event) => {
    event.preventDefault();
    $("#composer")?.classList.add("dragover");
  });
  $("#composer").addEventListener("dragleave", () =>
    $("#composer")?.classList.remove("dragover"),
  );
  $("#composer").addEventListener("drop", (event) => {
    event.preventDefault();
    $("#composer")?.classList.remove("dragover");
    queueFiles([...event.dataTransfer.files]);
  });
}

function linkedContent(editor) {
  const fragment = editor.cloneNode(true);
  const walker = document.createTreeWalker(fragment, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  for (const node of nodes) {
    if (node.parentElement.closest("a,pre,code,[data-mention]")) continue;
    const replacement = document.createDocumentFragment();
    let end = 0;
    for (const match of node.textContent.matchAll(/https?:\/\/[^\s<>]+/g)) {
      let url = match[0].replace(/[.,!?;:]+$/, "");
      while (url.endsWith(")") && url.split(")").length > url.split("(").length)
        url = url.slice(0, -1);
      try {
        new URL(url);
      } catch {
        continue;
      }
      replacement.append(node.textContent.slice(end, match.index));
      const link = document.createElement("a");
      link.href = url;
      link.textContent = url;
      replacement.append(link);
      end = match.index + url.length;
    }
    if (end) {
      replacement.append(node.textContent.slice(end));
      node.replaceWith(replacement);
    }
  }
  return fragment.innerHTML;
}

async function sendMessage() {
  const editor = $("#editor");
  const roomId = state.room?.id;
  if (
    !editor ||
    (!editor.textContent.trim() && !fileQueues.get(roomId)?.length && !editId)
  )
    return;
  const target = $('#composer [type="submit"]');
  if (target.disabled) return;
  target.disabled = true;
  const content = linkedContent(editor);
  const editing = Boolean(editId);
  const editedMessage = editId,
    reply = replyId;
  editor.contentEditable = "false";
  sendingId ||= messageId();
  const clientId = sendingId;
  try {
    if (!editing) await sendFiles(roomId);
    const message = editedMessage
      ? await api("/api/messages/" + editedMessage, {
          method: "PATCH",
          body: { body: content },
        })
      : editor.textContent.trim()
        ? await api(`/api/rooms/${roomId}/messages`, {
            method: "POST",
            body: { body: content, client_id: clientId, reply_id: reply },
          })
        : null;
    if (message) upsertMessage(message, !editing);
    if (
      state.room?.id === roomId &&
      state.view === "chat" &&
      editor === $("#editor")
    ) {
      editor.innerHTML = "";
      localStorage.removeItem(draftKey(roomId));
      cancelReply();
      sendingId = null;
      $("#draft-status").textContent = "";
      if (historical && !editing) {
        await state.navigate("/rooms/" + roomId);
        return;
      }
      scrollEnd();
      editor.contentEditable = "true";
      editor.focus();
    }
    socketSend({ type: "stop_typing" });
    await markRead();
  } finally {
    target.disabled = false;
    editor.contentEditable = "true";
  }
}

function queueFiles(files) {
  const roomId = state.room?.id;
  if (!roomId) return;
  const queue = fileQueues.get(roomId) || [];
  for (const file of files) {
    if (!file.size || file.size > 16 * 1024 * 1024 || queue.length >= 10) {
      toast("Choose up to 10 files, each between 1 byte and 16 MiB.");
      continue;
    }
    queue.push({
      id: messageId(),
      file,
      preview: file.type.startsWith("image/") ? URL.createObjectURL(file) : "",
    });
  }
  fileQueues.set(roomId, queue);
  renderFiles();
  if ($("#file-picker")) $("#file-picker").value = "";
}

function renderFiles() {
  const target = $("#pending-files");
  if (!target) return;
  const queue = fileQueues.get(state.room.id) || [];
  target.hidden = !queue.length;
  target.innerHTML = queue
    .map(
      (item) =>
        `<div class="pending-file">${item.preview ? `<img src="${item.preview}" alt="">` : icon("attachment")}<span>${escape(item.file.name)}<small>${item.sending ? `Uploading ${item.progress || 0}%` : `${(item.file.size / 1024).toFixed(1)} KB · ready to send`}</small></span>${button("remove-file", '<span class="sr-only">Remove file</span>', "cancel", `data-file="${item.id}" ${item.sending ? "disabled" : ""}`)}</div>`,
    )
    .join("");
}

async function sendFiles(roomId) {
  const queue = fileQueues.get(roomId) || [];
  for (const item of [...queue]) {
    item.sending = true;
    renderFiles();
    try {
      item.upload ||= await upload(item.file, (percent) => {
        item.progress = percent;
        renderFiles();
      });
      const message = await api(`/api/rooms/${roomId}/messages`, {
        method: "POST",
        body: { upload_id: item.upload.id, client_id: item.id },
      });
      upsertMessage(message);
      if (item.preview) URL.revokeObjectURL(item.preview);
      queue.splice(queue.indexOf(item), 1);
    } finally {
      item.sending = false;
      renderFiles();
    }
  }
}

function cancelReply() {
  replyId = 0;
  editId = 0;
  if ($("#reply-bar")) $("#reply-bar").hidden = true;
}
function editMessage(message) {
  editId = message.id;
  replyId = 0;
  $("#editor").innerHTML = message.body;
  $("#reply-bar").hidden = false;
  $("#reply-bar").innerHTML =
    `<span>Editing your message</span>${button("cancel-reply", "Cancel", "cancel")}`;
  $("#editor").focus();
}

function suggestMentions() {
  const text = $("#editor").textContent;
  const match = text.match(/@([^@\n]{0,30})$/);
  const box = $("#suggestions");
  if (!match) {
    box.hidden = true;
    return;
  }
  const choices = state.users
    .filter(
      (u) =>
        state.room.members.includes(u.id) &&
        u.status === "active" &&
        u.name.toLowerCase().includes(match[1].toLowerCase()),
    )
    .slice(0, 6);
  box.innerHTML = choices
    .map((user) =>
      button("insert-mention", escape(user.name), "", `data-id="${user.id}"`),
    )
    .join("");
  box.hidden = !choices.length;
  suggestionIndex = 0;
  box.firstElementChild?.classList.add("selected");
}

function insertMention(id) {
  const user = state.users.find((u) => u.id === id);
  if (!user) return;
  $("#editor").focus();
  const selection = getSelection();
  if (selection.rangeCount) {
    const range = selection.getRangeAt(0);
    if (range.startContainer.nodeType === Node.TEXT_NODE) {
      const before = range.startContainer.textContent.slice(
        0,
        range.startOffset,
      );
      const at = before.lastIndexOf("@");
      if (at >= 0) {
        range.setStart(range.startContainer, at);
        range.deleteContents();
      }
    }
  }
  document.execCommand(
    "insertHTML",
    false,
    `<span data-mention="${id}" class="mention" contenteditable="false">@${escape(user.name)}</span>&nbsp;`,
  );
  $("#suggestions").hidden = true;
  saveDraft();
  closeModal();
}

export function upsertMessage(message, play = false) {
  if (state.view === "search") {
    const index = (state.searchMessages || []).findIndex(
      (item) => item.id === message.id,
    );
    if (index >= 0) {
      state.searchMessages[index] = message;
      const current = $("#message-" + message.id);
      if (current) current.outerHTML = messageHTML(message, true);
      highlightMessages($("#search-results"));
    }
    return;
  }
  if (state.room?.id !== message.room_id || state.view !== "chat") return;
  const index = state.messages.findIndex((m) => m.id === message.id);
  if (historical && index < 0) return;
  if (play && index < 0 && !document.hidden) {
    const sound = message.plain?.match(/^\/play (\w+)$/)?.[1];
    if (sounds.includes(sound))
      new Audio(`/assets/sounds/${sound}.mp3`).play().catch(() => {});
  }
  if (index >= 0) state.messages[index] = message;
  else state.messages.push(message);
  state.messages.sort((a, b) => a.id - b.id);
  const existing = $("#message-" + message.id);
  if (existing) {
    const template = document.createElement("template");
    template.innerHTML = messageHTML(message);
    const next = template.content.firstElementChild;
    // Preserve playback and image state when a boost or edit changes the message.
    const previousMedia = $("figure", existing),
      nextMedia = $("figure", next);
    if (
      previousMedia &&
      nextMedia &&
      previousMedia.innerHTML === nextMedia.innerHTML
    )
      nextMedia.replaceWith(previousMedia);
    existing.replaceWith(next);
  } else if ($("#message-end")) {
    const element = $("#messages"),
      bottom =
        element.scrollHeight - element.scrollTop - element.clientHeight < 120;
    const previous = state.messages.filter((m) => m.id < message.id).at(-1);
    if (
      previous &&
      new Date(previous.created_at).toDateString() ===
        new Date(message.created_at).toDateString()
    )
      $("#message-end").insertAdjacentHTML("beforebegin", messageHTML(message));
    else renderMessages();
    if (bottom) scrollEnd();
  } else renderMessages();
  const updated = $("#message-" + message.id);
  if (updated) highlightMessages(updated);
}

function removeMessage(id) {
  state.messages = state.messages.filter((message) => message.id !== id);
  if (state.view === "search") {
    state.searchMessages = (state.searchMessages || []).filter(
      (message) => message.id !== id,
    );
    const article = $("#message-" + id);
    if (article?.previousElementSibling?.classList.contains("search-room-link"))
      article.previousElementSibling.remove();
    article?.remove();
    if ($(".search-count"))
      $(".search-count").textContent =
        `${state.searchMessages.length} messages found`;
  } else renderMessages();
}

const readRequests = new Map();

export async function markRead() {
  if (!state.room || document.hidden || state.view !== "chat") return;
  const roomId = state.room.id;
  const current = readRequests.get(roomId);
  if (current) {
    current.dirty = true;
    return current.promise;
  }
  const entry = { dirty: false, promise: null };
  entry.promise = (async () => {
    do {
      entry.dirty = false;
      await new Promise((resolve) => setTimeout(resolve, 60));
      await api(`/api/rooms/${roomId}/read`, { method: "POST" });
      if (state.room?.id === roomId) state.room.unread = 0;
      if ($("#sidebar")) renderSidebar();
    } while (entry.dirty && state.room?.id === roomId && !document.hidden);
  })().finally(() => readRequests.delete(roomId));
  readRequests.set(roomId, entry);
  return entry.promise;
}

export function connectSocket() {
  state.socket?.close();
  const socket = new WebSocket(
    `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/ws`,
  );
  state.socket = socket;
  const timer = setInterval(() => {
    if (socket.readyState === WebSocket.OPEN) socket.send('{"type":"ping"}');
  }, 20000);
  socket.addEventListener("open", () => {
    if (state.socket !== socket) return;
    if ($("#connection")) $("#connection").hidden = true;
    updatePresence();
    const roomId = state.room?.id;
    const request = currentRequest;
    const top = $("#messages")?.getBoundingClientRect().top || 0;
    const anchor = historical
      ? $$("#messages .message").find(
          (item) => item.getBoundingClientRect().bottom > top,
        )
      : null;
    const anchorId = Number(anchor?.dataset.id);
    const offset = anchor ? anchor.getBoundingClientRect().top - top : 0;
    if (roomId && state.view === "chat")
      api(
        `/api/rooms/${roomId}/messages${anchorId ? "?around=" + anchorId : ""}`,
      )
        .then((messages) => {
          if (
            state.socket === socket &&
            request === currentRequest &&
            state.room?.id === roomId &&
            state.view === "chat"
          ) {
            state.messages = messages;
            renderMessages();
            if (anchorId && $("#message-" + anchorId))
              $("#messages").scrollTop +=
                $("#message-" + anchorId).getBoundingClientRect().top -
                $("#messages").getBoundingClientRect().top -
                offset;
            markRead().catch(() => {});
          }
        })
        .catch((e) => toast(e.message));
    refreshRooms()
      .then(() => {
        if (roomId && !state.room) state.navigate("/");
      })
      .catch(() => {});
  });
  socket.addEventListener("message", (event) => {
    if (state.socket !== socket) return;
    let data;
    try {
      data = JSON.parse(event.data);
    } catch {
      return;
    }
    if (data.kind === "message" || data.kind === "message_updated") {
      upsertMessage(data.message, data.kind === "message");
      if (data.kind === "message") {
        if (data.room_id === state.room?.id) markRead().catch(() => {});
        refreshRooms().catch(() => {});
      }
    }
    if (data.kind === "message_deleted") {
      removeMessage(data.message_id);
      refreshRooms().catch(() => {});
    }
    if (data.kind === "users")
      loadUsers()
        .then((users) => {
          state.users = users;
        })
        .catch(() => {});
    if (["rooms", "room_deleted", "read"].includes(data.kind))
      refreshRooms()
        .then(() => {
          if (!state.room && state.view === "chat") state.navigate("/");
        })
        .catch(() => {});
    if (data.kind === "refresh") state.restart();
    if (
      data.kind === "presence" &&
      data.room_id === state.room?.id &&
      $("#presence")
    )
      $("#presence").textContent =
        `${state.room.members.length} people · ${data.users.length} here now`;
    if (
      data.room_id === state.room?.id &&
      data.user_id !== state.user.id &&
      $("#typing")
    ) {
      if (data.kind === "typing") {
        typingPeople.set(data.user_id, {
          name: data.name,
          until: Date.now() + 3000,
        });
        renderTyping();
        setTimeout(renderTyping, 3100);
      }
      if (data.kind === "stop_typing") {
        typingPeople.delete(data.user_id);
        renderTyping();
      }
    }
  });
  socket.addEventListener("close", (event) => {
    clearInterval(timer);
    if (state.socket !== socket || !state.user.id) return;
    if (event.code === 4001) {
      saveDraft();
      state.restart();
      return;
    }
    if ($("#connection")) $("#connection").hidden = false;
    setTimeout(
      () => {
        if (state.socket === socket && state.user.id) connectSocket();
      },
      1800 + Math.random() * 1200,
    );
  });
}

function renderTyping() {
  for (const [id, person] of typingPeople)
    if (person.until < Date.now()) typingPeople.delete(id);
  const names = [...typingPeople.values()].map((person) => person.name);
  if ($("#typing"))
    $("#typing").textContent = names.length
      ? `${names.slice(0, 3).join(", ")} ${names.length === 1 ? "is" : "are"} typing…`
      : "";
}

export async function roomDialog(room = null, direct = false) {
  if (room?.kind === "direct") direct = true;
  const canManage = !room || admin() || room.creator_id === state.user.id;
  const people = state.users.filter(
    (u) =>
      u.status === "active" && (u.id !== state.user.id || (room && !direct)),
  );
  modal(
    room ? room.name : direct ? "Start a ping" : "Create a room",
    `<form>
    ${!direct ? field("name", "Room name", room?.name || "", "text", `required maxlength="120" ${canManage ? "" : "disabled"}`) : "<p>Pings are private conversations. Choose one person or a group.</p>"}
    ${!direct ? `<label class="field" for="room-kind">Who can join?<select name="kind" id="room-kind" ${canManage ? "" : "disabled"}><option value="open" ${room?.kind === "open" ? "selected" : ""}>Everyone — open room</option><option value="closed" ${room?.kind === "closed" ? "selected" : ""}>Selected people — private room</option></select></label>` : ""}
    <fieldset class="people-picker" ${room?.kind === "direct" || !canManage ? "disabled" : ""}><legend>${direct ? "People in this ping" : "People in a private room"}</legend>${people.map((user) => `<label><input type="checkbox" name="members" value="${user.id}" ${room?.members.includes(user.id) ? "checked" : ""}>${avatar(user)}<span>${escape(user.name)}${user.role === "bot" ? " <small>bot</small>" : ""}</span></label>`).join("")}</fieldset>
    ${
      room
        ? `<label class="field" for="involvement">Notify me<select id="involvement" name="involvement">${[
            ["everything", "For every message"],
            ["mentions", "When I’m mentioned"],
            ["nothing", "Never"],
            ["invisible", "Hide this conversation"],
          ]
            .map(
              ([value, label]) =>
                `<option value="${value}" ${room.involvement === value ? "selected" : ""}>${label}</option>`,
            )
            .join("")}</select></label>`
        : ""
    }
    ${formEnd(room ? "Save changes" : direct ? "Start ping" : "Create room")}
    ${room && (canManage || direct) ? button("delete-room", "Delete conversation", "trash", `class="danger-text" data-id="${room.id}"`) : ""}</form>`,
    async (data) => {
      let result = room;
      if (!room || (canManage && !direct)) {
        result = await api(room ? "/api/rooms/" + room.id : "/api/rooms", {
          method: room ? "PATCH" : "POST",
          body: {
            name: data.get("name") || "",
            kind: direct ? "direct" : data.get("kind"),
            members: data.getAll("members").map(Number),
          },
        });
      }
      if (room && result.members.includes(state.user.id))
        await api(`/api/rooms/${room.id}/involvement`, {
          method: "PATCH",
          body: { involvement: data.get("involvement") },
        });
      closeModal();
      await refreshRooms();
      state.navigate(
        state.rooms.some((room) => room.id === result.id)
          ? "/rooms/" + result.id
          : "/",
      );
    },
  );
}

export async function chatAction(action, element) {
  const id = Number(element.dataset.id);
  const message = (
    state.view === "search" ? state.searchMessages || [] : state.messages
  ).find((m) => m.id === id);
  if (
    message &&
    state.view === "search" &&
    ["reply", "quote-message", "edit-message"].includes(action)
  )
    await state.navigate(`/rooms/${message.room_id}?at=${id}`);
  if (action === "new-room") await roomDialog();
  else if (action === "remove-file") {
    const queue = fileQueues.get(state.room.id) || [];
    const index = queue.findIndex((item) => item.id === element.dataset.file);
    if (index >= 0 && !queue[index].sending) {
      URL.revokeObjectURL(queue[index].preview);
      queue.splice(index, 1);
      renderFiles();
    }
  } else if (action === "latest")
    await state.navigate("/rooms/" + state.room.id);
  else if (action === "newer" && !loadingOlder) {
    loadingOlder = true;
    const request = currentRequest;
    try {
      const newer = await api(
        `/api/rooms/${state.room.id}/messages?after=${state.messages.at(-1)?.id || 0}`,
      );
      if (request !== currentRequest || state.view !== "chat") return;
      historical = newer.length === 40;
      state.messages.push(...newer);
      renderMessages();
    } finally {
      loadingOlder = false;
    }
  } else if (action === "new-ping") await roomDialog(null, true);
  else if (action === "room-settings") await roomDialog(state.room);
  else if (action === "delete-room")
    confirmAction(
      "Delete conversation?",
      "This removes its entire message history for everyone. This cannot be undone.",
      async () => {
        await api("/api/rooms/" + id, { method: "DELETE" });
        await refreshRooms();
        state.navigate("/");
      },
    );
  else if (action === "attach") $("#file-picker").click();
  else if (action === "cancel-reply") {
    if (editId) $("#editor").innerHTML = "";
    cancelReply();
  } else if (action === "reply" && message) {
    replyId = id;
    editId = 0;
    $("#reply-bar").hidden = false;
    $("#reply-bar").innerHTML =
      `<span>Replying to ${escape(message.name)}: ${escape(message.plain.slice(0, 80))}</span>${button("cancel-reply", "Cancel", "cancel")}`;
    $("#editor").focus();
  } else if (action === "message-menu" && message)
    modal(
      "Message actions",
      `<div class="menu-list">${button("copy-message", "Copy link", "link", `data-id="${id}"`)}${button("quote-message", "Quote message", "reply", `data-id="${id}"`)}${admin() || message.user_id === state.user.id ? button("edit-message", "Edit message", "pencil", `data-id="${id}"`) + button("delete-message", "Delete message", "trash", `data-id="${id}"`) : ""}</div>`,
    );
  else if (action === "copy-message" && message) {
    closeModal();
    await copy(`${location.origin}/rooms/${message.room_id}?at=${id}`);
  } else if (action === "quote-message" && message) {
    closeModal();
    $("#editor").focus();
    document.execCommand(
      "insertHTML",
      false,
      `<blockquote>${escape(message.name)}: ${escape(message.plain)}</blockquote><p><br></p>`,
    );
  } else if (action === "edit-message" && message) {
    closeModal();
    editMessage(message);
  } else if (action === "delete-message" && message)
    confirmAction(
      "Delete this message?",
      "This removes the message for everyone.",
      async () => {
        await api("/api/messages/" + id, { method: "DELETE" });
        removeMessage(id);
      },
    );
  else if (action === "boost" && message)
    modal(
      "Give it a boost",
      `<form>${field("content", "A few words or an emoji", "", "text", 'required maxlength="32" autofocus')}${formEnd("Add boost")}</form>`,
      async (data) => {
        const updated = await api(`/api/messages/${id}/boosts`, {
          method: "POST",
          body: { content: data.get("content") },
        });
        upsertMessage(updated);
        closeModal();
      },
    );
  else if (action === "remove-boost") {
    await api("/api/boosts/" + id, { method: "DELETE" });
    const messages =
      state.view === "search" ? state.searchMessages || [] : state.messages;
    for (const message of messages) {
      if (message.boosts.some((boost) => boost.id === id))
        upsertMessage({
          ...message,
          boosts: message.boosts.filter((boost) => boost.id !== id),
        });
    }
  } else if (action === "boost-info") toast(element.title);
  else if (action === "lightbox" && message)
    modal(
      message.attachment.name,
      `<img class="lightbox" src="/uploads/${message.attachment.id}" alt="${escape(message.attachment.name)}"><a href="/uploads/${message.attachment.id}" download>Download original</a>`,
      null,
      true,
    );
  else if (action === "jump-message")
    state.navigate(
      `/rooms/${element.dataset.roomId || state.room.id}?at=${id}`,
    );
  else if (action === "older" && !loadingOlder && state.messages.length) {
    loadingOlder = true;
    const request = currentRequest;
    const element = $("#messages"),
      height = element.scrollHeight;
    try {
      const older = await api(
        `/api/rooms/${state.room.id}/messages?before=${state.messages[0].id}`,
      );
      if (request !== currentRequest || state.view !== "chat") return;
      if (!older.length) toast("You’ve reached the beginning.");
      else {
        state.messages = [...older, ...state.messages];
        renderMessages();
        element.scrollTop = element.scrollHeight - height;
      }
    } finally {
      loadingOlder = false;
    }
  } else if (action === "mention")
    modal(
      "Mention someone",
      `<div class="menu-list">${state.users
        .filter((u) => state.room.members.includes(u.id))
        .map((u) =>
          button("insert-mention", escape(u.name), "", `data-id="${u.id}"`),
        )
        .join("")}</div>`,
    );
  else if (action === "insert-mention") insertMention(id);
  else if (action === "sounds")
    modal(
      "Send a sound",
      `<p>Everyone in this conversation can play the sound.</p><div class="sound-grid">${sounds.map((sound) => button("send-sound", sound, "sound", `data-sound="${sound}"`)).join("")}</div>`,
    );
  else if (action === "send-sound") {
    closeModal();
    $("#editor").textContent = "/play " + element.dataset.sound;
    await sendMessage();
  } else if (action === "play-sound") {
    const sound = element.dataset.sound;
    if (sounds.includes(sound))
      new Audio(`/assets/sounds/${sound}.mp3`)
        .play()
        .catch(() => toast("Your browser could not play this sound."));
  } else if (action.startsWith("format-")) {
    formatEditor(action);
    saveDraft();
  }
}
