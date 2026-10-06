import translations from "./translations.js";

export const state = {
  user: {},
  account: {},
  csrf: "",
  rooms: [],
  users: [],
  room: null,
  messages: [],
  socket: null,
  push_key: "",
  view: "chat",
};
export const $ = (selector, scope = document) => scope.querySelector(selector);
export const $$ = (selector, scope = document) => [
  ...scope.querySelectorAll(selector),
];
export const escape = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const iconNames = {
  plus: "add",
  code: "common-file-text",
  list: "text-options",
  sound: "notification-bell-everything",
};
export const icon = (name) =>
  `<span class="icon-wrap"><img class="icon" src="/assets/icons/${iconNames[name] || name}.svg" alt=""></span>`;
export const button = (action, label, image = "", extra = "") =>
  `<button type="button" data-action="${action}" ${extra}>${image ? icon(image) : ""}${label}</button>`;
export const avatar = (user) =>
  user.avatar_id
    ? `<img class="avatar" src="/avatar/${user.id}?v=${user.avatar_id}" alt="">`
    : `<span class="avatar initials" aria-hidden="true">${escape(
        (user.name || "?")
          .split(/\s+/)
          .slice(0, 2)
          .map((x) => [...x][0])
          .join(""),
      )}</span>`;
export const dateTime = (value) =>
  new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));

// getRandomValues also works on a plain HTTP development origin.
export const messageId = () =>
  [...crypto.getRandomValues(new Uint8Array(16))]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");

export async function api(path, options = {}) {
  const headers = { "X-CSRF-Token": state.csrf, ...options.headers };
  if (options.body && !(options.body instanceof FormData)) {
    headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(options.body);
  }
  const response = await fetch(path, { ...options, headers });
  let result;
  try {
    result = await response.json();
  } catch {
    throw new Error(
      `The server returned an unreadable response (${response.status}).`,
    );
  }
  if (!response.ok) {
    if (response.status === 401 && state.user.id) {
      state.user = {};
      state.socket?.close();
      state.restart?.();
    }
    throw new Error(result.error || `Request failed (${response.status}).`);
  }
  return result;
}

export async function loadUsers() {
  const users = [];
  for (let page = 0; ; page++) {
    const batch = await api(`/api/users?page=${page}`);
    users.push(...batch);
    if (batch.length < 500) return users;
  }
}

let toastTimer;
export function toast(message) {
  const target = $("#toast");
  target.textContent = message;
  target.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    target.hidden = true;
  }, 5500);
}

export function modal(title, contents, onSubmit, wide = false) {
  const dialog = $("#dialog");
  if (dialog.open) dialog.close();
  dialog.classList.toggle("wide", wide);
  dialog.innerHTML = `<header class="dialog-header"><h2 id="dialog-title">${escape(title)}</h2>${button("close-dialog", '<span class="sr-only">Close dialog</span>', "cancel")}</header>${contents}`;
  const form = $("form", dialog);
  if (form && onSubmit)
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      submit(form, () => onSubmit(new FormData(form), form));
    });
  dialog.showModal();
}

export async function submit(form, action) {
  const target = $('[type="submit"]', form);
  const error = $(".form-error", form);
  if (target?.disabled) return;
  if (target) target.disabled = true;
  if (error) error.textContent = "";
  try {
    await action();
  } catch (cause) {
    if (error) error.textContent = cause.message;
    else toast(cause.message);
  } finally {
    if (target) target.disabled = false;
  }
}

const fieldTranslations = {
  "Email address": "email_address",
  Email: "email_address",
  Password: "password",
  "New password": "update_password",
  "Your name": "user_name",
  Name: "user_name",
  "Workspace name": "account_name",
  "Room name": "room_name",
  "Bot name": "bot_name",
  "Webhook URL": "webhook_url",
};

export const field = (
  name,
  label,
  value = "",
  type = "text",
  attributes = "",
) =>
  `<div class="field"><div class="field-label"><label for="field-${name}">${label}</label>${translation(fieldTranslations[label])}</div><input id="field-${name}" name="${name}" type="${type}" value="${escape(value)}" ${attributes}></div>`;
export const formEnd = (label) =>
  `<p class="form-error" role="alert"></p><footer class="form-actions">${button("close-dialog", "Cancel")}<button type="submit" class="primary">${label}</button></footer>`;
export const admin = () => state.user.role === "administrator";
export const closeModal = () => $("#dialog").close();

export function translation(key) {
  const entries = translations[key];
  if (!entries) return "";
  return `<details class="translation"><summary aria-label="Translations">${icon("globe")}</summary><dl>${Object.entries(
    entries,
  )
    .map(([language, text]) => `<dt>${language}</dt><dd>${escape(text)}</dd>`)
    .join("")}</dl></details>`;
}

export async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast("Copied to clipboard.");
  } catch {
    modal(
      "Copy link",
      `${field("copy", "Link", text, "text", "readonly")}<p>Select and copy this link.</p>`,
    );
  }
}

export function confirmAction(title, description, action) {
  modal(
    title,
    `<form><p>${escape(description)}</p>${formEnd("Confirm")}</form>`,
    async () => {
      await action();
      closeModal();
    },
  );
}

export async function upload(file, progress) {
  if (!file || file.size === 0 || file.size > 16 * 1024 * 1024)
    throw new Error("Choose a file between 1 byte and 16 MiB.");
  const body = new FormData();
  body.append("file", file);
  if (!progress) return api("/api/uploads", { method: "POST", body });
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open("POST", "/api/uploads");
    request.setRequestHeader("X-CSRF-Token", state.csrf);
    request.responseType = "json";
    request.timeout = 60000;
    request.upload.onprogress = (event) => {
      if (event.lengthComputable)
        progress(Math.round((event.loaded * 100) / event.total));
    };
    request.onload = () => {
      if (request.status === 201) resolve(request.response);
      else
        reject(
          new Error(
            request.response?.error ||
              "The file could not be uploaded. Try again.",
          ),
        );
    };
    request.onerror = request.ontimeout = () =>
      reject(
        new Error("The upload was interrupted. Your file is ready to retry."),
      );
    request.send(body);
  });
}
