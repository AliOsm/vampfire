import { highlightMessages } from "./editor.js";
import {
  state,
  $,
  $$,
  escape,
  icon,
  button,
  field,
  api,
  loadUsers,
  toast,
  submit,
  closeModal,
} from "./ui.js";
import {
  refreshRooms,
  renderSidebar,
  openRoom,
  messageHTML,
  connectSocket,
  markRead,
  chatAction,
  saveDraft,
  updatePresence,
  clearPendingFiles,
} from "./chat.js";
import { people, settingsAction } from "./settings.js";

state.restart = start;
state.navigate = navigate;

async function start() {
  try {
    const bootstrap = await api("/api/bootstrap");
    Object.assign(state, bootstrap);
    if (!state.user.id) {
      renderAuth(bootstrap.setup);
      return;
    }
    $("#app").innerHTML =
      '<div class="app-layout"><aside id="sidebar"></aside><button type="button" class="nav-scrim" data-action="menu" aria-label="Close navigation"></button><main id="main"></main></div>';
    [state.rooms, state.users] = await Promise.all([
      api("/api/rooms"),
      loadUsers(),
    ]);
    renderSidebar();
    await route();
    connectSocket();
    if ("serviceWorker" in navigator)
      navigator.serviceWorker
        .register("/service-worker.js")
        .catch((error) => console.warn("Service worker:", error));
  } catch (error) {
    $("#app").innerHTML =
      `<main class="error-page"><h1>We couldn’t open Vampfire.</h1><p>${escape(error.message)}</p>${button("retry", "Try again")}</main>`;
  }
}

function renderAuth(setup) {
  clearPendingFiles();
  const join = location.pathname.match(/^\/join\/([^/]+)$/)?.[1];
  const transfer = location.pathname.match(/^\/transfer\/([^/]+)$/)?.[1];
  const create = setup || Boolean(join);
  document.title = setup
    ? "Welcome to Vampfire"
    : state.account.name || "Vampfire";
  $("#app").innerHTML =
    `<main class="auth-page"><a class="auth-brand" href="/" aria-label="Homepage"><img src="${state.account.logo_id ? "/logo" : "/assets/app-icon.png"}" alt=""><span>${escape(state.account.name || "Vampfire")}</span></a>
    <div class="auth-card"><p class="eyebrow">A place to be together</p><h1>${setup ? "Make room for your people." : transfer ? "Welcome to your other device." : join ? "Come on in." : "Good to see you."}</h1><p class="auth-description">${setup ? "A simple, welcoming home for your conversations. Start by setting up your workspace." : transfer ? "Use your secure sign-in link to continue." : join ? "Create your account and join the conversation." : "Sign in and pick up where you left off."}</p>
    <form id="auth-form">${transfer ? "" : `${setup ? field("account_name", "Workspace name", "Vampfire", "text", 'required maxlength="100"') : ""}${create ? field("name", "Your name", "", "text", 'required autocomplete="name" maxlength="100"') : ""}${field("email", "Email address", "", "email", 'required autocomplete="username"')}${field("password", "Password", "", "password", `required ${create ? 'minlength="8"' : ""} maxlength="72" autocomplete="${create ? "new-password" : "current-password"}"`)}`}
    <p class="form-error" role="alert"></p><button type="submit" class="primary auth-submit">${setup ? "Create your workspace" : transfer ? "Sign in on this device" : join ? "Join the conversation" : "Sign in"} ${icon("arrow-right")}</button></form>
    <p class="auth-footer">${join ? '<a href="/">Already have an account? Sign in</a>' : setup ? "Your first room, All Talk, is waiting." : "Need an account or a new password? Ask a workspace administrator."}</p></div><p class="auth-tagline">Less noise. More conversation.</p></main>`;
  $("#auth-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    submit(form, async () => {
      const data = Object.fromEntries(new FormData(form));
      let endpoint = setup
        ? "/api/setup"
        : join
          ? "/api/join"
          : transfer
            ? "/api/transfers/redeem"
            : "/api/session";
      if (join) data.join_code = join;
      if (transfer) data.token = transfer;
      const result = await api(endpoint, { method: "POST", body: data });
      Object.assign(state, result);
      if (join || setup || transfer) history.replaceState(null, "", "/");
      await start();
    });
  });
}

async function navigate(url) {
  saveDraft();
  history.pushState(null, "", url);
  await route();
  updatePresence();
}

async function route() {
  if (!state.user.id) return;
  if (location.pathname === "/search") {
    await searchPage();
    return;
  }
  if (location.pathname === "/settings") {
    await people();
    return;
  }
  const id =
    Number(location.pathname.match(/^\/rooms\/(\d+)/)?.[1]) ||
    state.room?.id ||
    state.rooms.find(
      (room) =>
        room.id ===
          Number(localStorage.getItem(`last-room:${state.user.id}`)) &&
        room.involvement !== "invisible",
    )?.id ||
    state.rooms.find((r) => r.involvement !== "invisible")?.id;
  if (id && state.rooms.some((r) => r.id === id))
    await openRoom(id, Number(new URLSearchParams(location.search).get("at")));
  else
    $("#main").innerHTML =
      `<div class="empty-room"><h1>Find your people.</h1><p>Start a conversation to make yourself at home.</p>${button("new-ping", "Start a ping", "messages")}${button("new-room", "Create a room", "add")}</div>`;
}

async function searchPage(query = "") {
  state.view = "search";
  document.body.classList.remove("sidebar-open");
  $("#main").innerHTML =
    `<header class="room-header">${button("menu", '<span class="sr-only">Open navigation</span>', "menu", 'class="mobile-only"')}<div class="room-heading"><h1>Find a conversation</h1><p>Search messages and filenames across your rooms.</p></div>${button("back-chat", "Back to chat", "arrow-left")}</header><div class="search-page"><form id="search-form"><label class="field grow" for="search-query"><span class="sr-only">Search query</span><input type="search" id="search-query" name="q" placeholder="What are you looking for?" value="${escape(query)}" maxlength="200" autofocus></label><label class="field" for="search-room"><span class="sr-only">Room</span><select id="search-room" name="room"><option value="0">All conversations</option>${state.rooms.map((r) => `<option value="${r.id}">${escape(r.name)}</option>`).join("")}</select></label><button type="submit" class="primary">Search</button></form><div id="search-results"></div></div>`;
  let request = 0;
  async function run(record = false, before = 0) {
    const generation = ++request;
    const data = new FormData($("#search-form")),
      q = data.get("q");
    const result = await api(
      `/api/search?q=${encodeURIComponent(q)}&room=${data.get("room")}&before=${before}`,
    );
    if (
      generation !== request ||
      state.view !== "search" ||
      state.runSearch !== run
    )
      return;
    const hasMore = result.messages.length === 40;
    state.searchMessages = before
      ? [...state.searchMessages, ...result.messages]
      : result.messages;
    result.messages = state.searchMessages;
    if (record && q.trim())
      await api("/api/search", { method: "POST", body: { query: q } });
    $("#search-results").innerHTML = q
      ? `<p class="search-count">${result.messages.length} ${result.messages.length === 1 ? "message" : "messages"} found</p>${result.messages.map((m) => `<a class="search-room-link" href="/rooms/${m.room_id}?at=${m.id}" data-room="${m.room_id}" data-at="${m.id}">${escape(state.rooms.find((r) => r.id === m.room_id)?.name || "Conversation")}</a>${messageHTML(m, true)}`).join("")}${!result.messages.length ? '<p class="empty-note">No messages matched. Try a different word or room.</p>' : ""}`
      : `<h2 class="small-heading">Recent searches</h2><div class="recent-searches">${result.recent.map((q) => button("recent-search", escape(q), "search", `data-query="${escape(q)}"`)).join("") || "<p>Your recent searches will appear here.</p>"}</div>${result.recent.length ? button("clear-searches", "Clear history", "broom") : ""}`;
    highlightMessages($("#search-results"));
    if (q && hasMore)
      $("#search-results").insertAdjacentHTML(
        "beforeend",
        button("more-search", "Load older results", "arrow-down"),
      );
  }
  $("#search-form").addEventListener("submit", (event) => {
    event.preventDefault();
    submit(event.currentTarget, () => run(true));
  });
  state.runSearch = run;
  await run();
  $("#search-query").focus();
}

document.addEventListener("click", async (event) => {
  const action = event.target.closest("[data-action]");
  const room = event.target.closest("[data-room]");
  const permalink = event.target.closest("[data-permalink]");
  try {
    if (room) {
      event.preventDefault();
      await navigate(
        "/rooms/" +
          room.dataset.room +
          (room.dataset.at ? "?at=" + room.dataset.at : ""),
      );
      return;
    }
    if (permalink) {
      event.preventDefault();
      await navigate(permalink.getAttribute("href"));
      return;
    }
    if (!action) return;
    const name = action.dataset.action;
    if (name === "close-dialog") closeModal();
    else if (name === "menu") document.body.classList.toggle("sidebar-open");
    else if (name === "search") await navigate("/search");
    else if (name === "people") await navigate("/settings");
    else if (name === "back-chat") await navigate("/");
    else if (name === "retry") await start();
    else if (name === "recent-search") {
      $("#search-query").value = action.dataset.query;
      await state.runSearch(true);
    } else if (name === "clear-searches") {
      await api("/api/search", { method: "DELETE" });
      await state.runSearch();
    } else if (name === "more-search") {
      action.disabled = true;
      try {
        await state.runSearch(false, state.searchMessages.at(-1).id);
      } finally {
        action.disabled = false;
      }
    } else {
      await chatAction(name, action);
      await settingsAction(name, action);
    }
  } catch (error) {
    if (error.name !== "AbortError") toast(error.message);
  }
});

window.addEventListener("popstate", () => {
  saveDraft();
  route()
    .then(updatePresence)
    .catch((e) => toast(e.message));
});
window.addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  state.installPrompt = event;
});
document.addEventListener("visibilitychange", () => {
  updatePresence();
  if (!document.hidden) markRead().catch(() => {});
});
document.addEventListener("keydown", (event) => {
  if (
    event.key === "/" &&
    !event.target.closest('input,textarea,[contenteditable="true"]') &&
    !$("#dialog").open &&
    state.user.id
  ) {
    event.preventDefault();
    navigate("/search");
  }
  if (event.key === "Escape") document.body.classList.remove("sidebar-open");
});
$("#dialog").addEventListener("click", (event) => {
  if (event.target === $("#dialog")) {
    const r = event.target.getBoundingClientRect();
    if (
      event.clientX < r.left ||
      event.clientX > r.right ||
      event.clientY < r.top ||
      event.clientY > r.bottom
    )
      closeModal();
  }
});
start();
