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
  submit,
  dateTime,
} from "./ui.js";
import { refreshRooms, renderSidebar, roomDialog } from "./chat.js";
import qrcode from "./vendor/qrcode.mjs";

function qr(url) {
  const code = qrcode(0, "M");
  code.addData(url);
  code.make();
  return code.createSvgTag({ cellSize: 4, margin: 16, scalable: true });
}

export async function invite() {
  const { account } = await api("/api/account");
  const url = `${location.origin}/join/${account.join_code}`;
  modal(
    "Bring your people together",
    `<p>Anyone with this link can join ${escape(account.name)}. Share it with the people you want here.</p>${field("invite-url", "Invitation link", url, "text", "readonly")}<div class="invite-actions">${button("copy-invite", "Copy invitation", "copy-paste")}${button("share-invite", "Share", "share")}</div><div class="qr">${qr(url)}</div>${admin() ? button("reset-invite", "Replace invitation link", "refresh", 'class="muted"') : ""}`,
  );
}

export async function profile() {
  const user = state.user;
  modal(
    "Your profile",
    `<form><div class="profile-avatar">${avatar(user)}<label class="file-label">Change photo<input name="avatar" type="file" accept="image/png,image/jpeg,image/gif,image/webp"></label>${user.avatar_id ? '<label class="checkbox"><input type="checkbox" name="remove_avatar">Remove photo</label>' : ""}</div>
    ${field("name", "Name", user.name, "text", 'required maxlength="100" autocomplete="name"')}${field("email", "Email", user.email, "email", 'required autocomplete="email"')}
    <label class="field" for="profile-bio"><span>About you</span><textarea id="profile-bio" name="bio" rows="2" maxlength="500">${escape(user.bio)}</textarea></label>
    ${field("password", "New password", "", "password", 'minlength="8" maxlength="72" autocomplete="new-password" placeholder="Leave blank to keep your password"')}${formEnd("Save profile")}</form>
    <div class="settings-links">${button("devices", "Devices & notifications", "laptop")}${button("transfer", "Sign in on another device", "transfer")}${button("hidden-rooms", "Hidden conversations", "messages")}${button("install", "Install Vampfire", "download")}${button("logout", "Sign out", "logout")}</div>`,
    async (data) => {
      let avatar_id = data.has("remove_avatar") ? 0 : user.avatar_id;
      const file = data.get("avatar");
      if (file?.size) avatar_id = (await upload(file)).id;
      state.user = await api("/api/profile", {
        method: "PATCH",
        body: {
          name: data.get("name"),
          email: data.get("email"),
          bio: data.get("bio"),
          password: data.get("password"),
          avatar_id,
        },
      });
      state.users = await loadUsers();
      closeModal();
      renderSidebar();
      toast("Profile saved.");
    },
  );
}

export async function people() {
  state.view = "settings";
  state.users = await loadUsers();
  document.body.classList.remove("sidebar-open");
  $("#main").innerHTML =
    `<header class="room-header">${button("menu", '<span class="sr-only">Open navigation</span>', "menu", 'class="mobile-only"')}<div class="room-heading"><h1>People & settings</h1><p>A good place for your people.</p></div>${button("back-chat", "Back to chat", "arrow-left")}</header>
    <div class="settings-page"><div class="settings-tabs">${button("invite", "Invite people", "person-add")}${admin() ? button("workspace", "Workspace settings", "settings") + button("bots", "Bots & integrations", "bot") : ""}</div>
    <label class="field" for="people-filter"><span class="sr-only">Filter people</span><input type="search" id="people-filter" name="filter" placeholder="Find someone…"></label>
    <div id="people-list" class="people-list">${state.users.map((user) => `<button type="button" class="person-row" data-action="show-person" data-id="${user.id}" data-name="${escape(user.name.toLowerCase())}">${avatar(user)}<span><strong>${escape(user.name)}</strong><small>${escape(user.bio || user.email || (user.role === "bot" ? "Bot" : "Member"))}</small></span><span class="role-badge">${user.status !== "active" ? escape(user.status) : user.role === "administrator" ? "Administrator" : user.role === "bot" ? "Bot" : ""}</span>${icon("arrow-right")}</button>`).join("")}</div></div>`;
  $("#people-filter").addEventListener("input", (event) =>
    $$(".person-row").forEach((row) => {
      row.hidden = !row.dataset.name.includes(event.target.value.toLowerCase());
    }),
  );
}

export function person(id) {
  const user = state.users.find((u) => u.id === id);
  if (!user) return;
  modal(
    user.name,
    `<div class="person-detail">${avatar(user)}<p>${escape(user.bio || "")}</p>${user.email ? `<p><a href="mailto:${escape(user.email)}">${escape(user.email)}</a></p>` : ""}<p class="muted">${escape(user.role)}${user.status !== "active" ? " · " + escape(user.status) : ""}</p></div>
    <div class="menu-list">${user.status === "active" ? button("ping-person", "Start a ping", "messages", `data-id="${id}"`) : ""}${id === state.user.id ? button("profile", "Edit your profile", "pencil") : ""}
    ${admin() && id !== state.user.id ? `${user.role !== "bot" ? button("change-role", user.role === "administrator" ? "Make a member" : "Make an administrator", "crown", `data-id="${id}"`) : ""}${button(user.status === "banned" ? "unban" : "ban", user.status === "banned" ? "Lift ban" : "Ban this person", "remove-circle", `data-id="${id}"`)}${user.status !== "deactivated" ? button("deactivate", "Deactivate account", "trash", `data-id="${id}"`) : ""}` : ""}</div>`,
  );
}

async function workspace() {
  const data = await api("/api/account");
  const account = data.account;
  modal(
    "Workspace settings",
    `<form>${field("name", "Workspace name", account.name, "text", 'required maxlength="100"')}
    <label class="field">Workspace logo<input type="file" name="logo" accept="image/png,image/jpeg,image/webp,image/gif"></label>
    ${account.logo_id ? '<label class="checkbox"><input type="checkbox" name="remove_logo">Remove current logo</label>' : ""}
    <label class="checkbox"><input type="checkbox" name="restrict_rooms" ${account.restrict_rooms ? "checked" : ""}>Only administrators can create rooms</label>
    <details><summary>Custom stylesheet</summary><p>Customize the workspace’s appearance for everyone.</p><label class="field" for="custom-css"><span class="sr-only">Custom CSS</span><textarea id="custom-css" name="custom_css" class="code-input" rows="8" spellcheck="false" maxlength="16000">${escape(data.custom_css)}</textarea></label></details>${formEnd("Save workspace")}</form>`,
    async (data) => {
      let logo_id = data.has("remove_logo") ? 0 : account.logo_id;
      if (data.get("logo")?.size) logo_id = (await upload(data.get("logo"))).id;
      const result = await api("/api/account", {
        method: "PATCH",
        body: {
          name: data.get("name"),
          restrict_rooms: data.has("restrict_rooms"),
          logo_id,
          custom_css: data.get("custom_css"),
        },
      });
      state.account = result.account;
      renderSidebar();
      $('link[href^="/custom.css"]').href = "/custom.css?v=" + Date.now();
      closeModal();
      toast("Workspace saved.");
    },
  );
}

async function devices() {
  const [sessions, subscriptions] = await Promise.all([
    api("/api/sessions"),
    api("/api/subscriptions"),
  ]);
  modal(
    "Devices & notifications",
    `<h3>Notifications</h3><p>Receive notifications when you’re away. Each room has its own notification preference.</p>
    ${state.push_key ? button("enable-push", "Enable on this device", "notification-bell-everything") : '<p class="muted">The server administrator needs to configure Web Push keys to enable notifications.</p>'}
    <ul role="list" class="device-list">${subscriptions.map((s) => `<li><p>${escape(s.agent)}<small>${dateTime(s.created_at * 1000)}</small></p><div>${button("test-push", "Test", "", 'data-id="' + s.id + '"')}${button("delete-push", "Remove", "trash", 'data-id="' + s.id + '"')}</div></li>`).join("")}</ul>
    <h3>Signed-in devices</h3><ul role="list" class="device-list">${sessions.map((s) => `<li><p>${s.current ? "<strong>This device</strong>" : "<strong>Other device</strong>"}<small>${escape(s.agent)}<br>${escape(s.ip)} · ${dateTime(s.active_at * 1000)}</small></p>${!s.current ? button("revoke-session", "Sign out", "logout", `data-token="${escape(s.token)}"`) : ""}</li>`).join("")}</ul>`,
    null,
    true,
  );
}

async function enablePush() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window))
    throw new Error(
      "This browser does not support push notifications. On iPhone or iPad, install the app first.",
    );
  const permission = await Notification.requestPermission();
  if (permission !== "granted")
    throw new Error("Allow notifications in your browser’s site settings.");
  const worker = await navigator.serviceWorker.ready;
  const key = Uint8Array.from(
    atob(state.push_key.replace(/-/g, "+").replace(/_/g, "/")),
    (c) => c.charCodeAt(0),
  );
  const subscription =
    (await worker.pushManager.getSubscription()) ||
    (await worker.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: key,
    }));
  const value = subscription.toJSON();
  await api("/api/subscriptions", {
    method: "POST",
    body: {
      endpoint: value.endpoint,
      p256dh: value.keys.p256dh,
      auth: value.keys.auth,
    },
  });
  toast("Notifications enabled.");
  await devices();
}

async function bots() {
  const values = await api("/api/bots");
  state.bots = values;
  modal(
    "Bots & integrations",
    `<p>Bots can post messages and boosts. Add a webhook to let a bot reply when mentioned or pinged.</p>${button("new-bot", "Create bot", "add")}<div class="people-list">${values.map((bot) => `<button type="button" class="person-row" data-action="edit-bot" data-id="${bot.user.id}">${avatar(bot.user)}<span><strong>${escape(bot.user.name)}</strong><small>${escape(bot.webhook || "No webhook configured")}</small></span>${icon("arrow-right")}</button>`).join("")}</div>`,
    null,
    true,
  );
}

function botForm(id = 0) {
  const bot = state.bots?.find((b) => b.user.id === id);
  modal(
    bot ? "Edit bot" : "Create bot",
    `<form>${field("name", "Bot name", bot?.user.name || "", "text", 'required maxlength="100"')}<label class="field">Bot picture<input type="file" name="avatar" accept="image/png,image/jpeg,image/webp,image/gif"></label>${bot?.user.avatar_id ? '<label class="checkbox"><input type="checkbox" name="remove_avatar">Remove picture</label>' : ""}${field("webhook", "Webhook URL", bot?.webhook || "", "url", 'placeholder="https://your-bot.example/webhook"')}<p class="muted">Optional. Vampfire sends a message payload to this URL and posts a text or file response back to the conversation.</p>${formEnd(bot ? "Save bot" : "Create bot")}</form>
    ${bot ? `<details open><summary>API access</summary><p>Keep this key private. It grants access to every room this bot can join.</p>${field("bot-key", "API key", bot.key, "text", "readonly")}<p class="code-example">POST ${location.origin}/api/bot/${escape(bot.key)}/rooms/ROOM_ID/messages</p><p>Send plain text or JSON with a <code>body</code> field.</p>${button("rotate-bot", "Replace API key", "key", `data-id="${id}"`)}</details>${button("deactivate", "Deactivate bot", "trash", `data-id="${id}"`)}` : ""}`,
    async (data) => {
      let avatar_id = data.has("remove_avatar") ? 0 : bot?.user.avatar_id || 0;
      if (data.get("avatar")?.size)
        avatar_id = (await upload(data.get("avatar"))).id;
      await api(bot ? "/api/bots/" + id : "/api/bots", {
        method: bot ? "PATCH" : "POST",
        body: {
          name: data.get("name"),
          webhook: data.get("webhook"),
          avatar_id,
        },
      });
      state.users = await loadUsers();
      await bots();
    },
    true,
  );
}

export async function settingsAction(action, element) {
  const id = Number(element.dataset.id),
    user = state.users.find((u) => u.id === id);
  if (action === "invite") await invite();
  else if (action === "profile") await profile();
  else if (action === "people") await people();
  else if (action === "show-person") person(id);
  else if (action === "workspace") await workspace();
  else if (action === "copy-invite") await copy($("#field-invite-url").value);
  else if (action === "share-invite") {
    const url = $("#field-invite-url").value;
    if (navigator.share)
      await navigator.share({ title: state.account.name, url });
    else await copy(url);
  } else if (action === "reset-invite")
    confirmAction(
      "Replace invitation link?",
      "The old link will stop working. Existing members keep their accounts.",
      async () => {
        await api("/api/account/invitation", { method: "POST" });
        setTimeout(() => invite(), 0);
      },
    );
  else if (action === "transfer") {
    const result = await api("/api/transfers", { method: "POST" }),
      url = `${location.origin}/transfer/${result.token}`;
    modal(
      "Sign in on another device",
      `<p>Scan this code on your other device. This sign-in link can be used once and expires in four hours.</p><div class="qr">${qr(url)}</div>${field("transfer-url", "Sign-in link", url, "text", "readonly")}${button("copy-transfer", "Copy sign-in link", "copy-paste")}`,
    );
  } else if (action === "copy-transfer")
    await copy($("#field-transfer-url").value);
  else if (action === "hidden-rooms")
    modal(
      "Hidden conversations",
      `<div class="menu-list">${
        state.rooms
          .filter((r) => r.involvement === "invisible")
          .map((r) =>
            button(
              "restore-room",
              escape(r.name),
              "messages",
              `data-id="${r.id}"`,
            ),
          )
          .join("") || "<p>No hidden conversations.</p>"
      }</div>`,
    );
  else if (action === "restore-room") {
    await api(`/api/rooms/${id}/involvement`, {
      method: "PATCH",
      body: { involvement: "mentions" },
    });
    closeModal();
    await refreshRooms();
    state.navigate("/rooms/" + id);
  } else if (action === "devices") await devices();
  else if (action === "enable-push") await enablePush();
  else if (action === "test-push") {
    await api(`/api/subscriptions/${id}/test`, { method: "POST" });
    toast("Test notification queued.");
  } else if (action === "delete-push") {
    await api("/api/subscriptions/" + id, { method: "DELETE" });
    await devices();
  } else if (action === "revoke-session") {
    await api("/api/sessions", {
      method: "DELETE",
      body: { token: element.dataset.token },
    });
    await devices();
  } else if (action === "ping-person") {
    const room = await api("/api/rooms", {
      method: "POST",
      body: { kind: "direct", members: [id] },
    });
    closeModal();
    await refreshRooms();
    state.navigate("/rooms/" + room.id);
  } else if (action === "change-role" && user)
    confirmAction(
      "Change role?",
      `Change ${user.name} to ${user.role === "administrator" ? "a member" : "an administrator"}?`,
      async () => {
        await api("/api/users/" + id, {
          method: "PATCH",
          body: {
            action: "role",
            role: user.role === "administrator" ? "member" : "administrator",
          },
        });
        await people();
      },
    );
  else if (["ban", "unban", "deactivate"].includes(action))
    confirmAction(
      action === "ban"
        ? "Ban this person?"
        : action === "unban"
          ? "Lift this ban?"
          : "Deactivate account?",
      action === "ban"
        ? "Their sessions and messages will be removed. Their recorded IP addresses will be blocked from signing in."
        : action === "deactivate"
          ? "They will lose access. Existing conversation history will remain."
          : "This person will be able to sign in again.",
      async () => {
        await api("/api/users/" + id, { method: "PATCH", body: { action } });
        await people();
      },
    );
  else if (action === "bots") await bots();
  else if (action === "new-bot") botForm();
  else if (action === "edit-bot") botForm(id);
  else if (action === "rotate-bot")
    confirmAction(
      "Replace API key?",
      "Requests using the old key will stop working.",
      async () => {
        await api("/api/bots/" + id, {
          method: "PATCH",
          body: { action: "rotate" },
        });
        setTimeout(() => bots(), 0);
      },
    );
  else if (action === "logout") {
    try {
      if ("serviceWorker" in navigator) {
        const worker = await navigator.serviceWorker.getRegistration();
        const subscription = await worker?.pushManager.getSubscription();
        await subscription?.unsubscribe();
      }
    } catch {
      /* Server-side session revocation also removes subscriptions. */
    }
    await api("/api/session", { method: "DELETE" });
    state.user = {};
    state.room = null;
    state.messages = [];
    state.socket?.close();
    closeModal();
    history.replaceState(null, "", "/");
    state.restart();
  } else if (action === "install") {
    if (state.installPrompt) {
      await state.installPrompt.prompt();
      state.installPrompt = null;
    } else
      modal(
        "Install Vampfire",
        "<p>In your browser menu, choose <strong>Install app</strong> or <strong>Add to Home Screen</strong>. On iPhone or iPad, open the Share menu in Safari and choose <strong>Add to Home Screen</strong>.</p>",
      );
  }
}
