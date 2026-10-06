import {
  $,
  $$,
  state,
  escape,
  button,
  field,
  formEnd,
  modal,
  closeModal,
} from "./ui.js";
import hljs from "./vendor/highlight/core.js";
import plaintext from "./vendor/highlight/plaintext.min.js";
import rust from "./vendor/highlight/rust.min.js";
import ruby from "./vendor/highlight/ruby.min.js";
import javascript from "./vendor/highlight/javascript.min.js";
import typescript from "./vendor/highlight/typescript.min.js";
import python from "./vendor/highlight/python.min.js";
import bash from "./vendor/highlight/bash.min.js";
import json from "./vendor/highlight/json.min.js";
import sql from "./vendor/highlight/sql.min.js";
import xml from "./vendor/highlight/xml.min.js";
import css from "./vendor/highlight/css.min.js";
import go from "./vendor/highlight/go.min.js";
import java from "./vendor/highlight/java.min.js";
import c from "./vendor/highlight/c.min.js";
import cpp from "./vendor/highlight/cpp.min.js";
import yaml from "./vendor/highlight/yaml.min.js";
import markdown from "./vendor/highlight/markdown.min.js";

const languages = {
  plaintext,
  rust,
  ruby,
  javascript,
  typescript,
  python,
  bash,
  json,
  sql,
  xml,
  css,
  go,
  java,
  c,
  cpp,
  yaml,
  markdown,
};
for (const [name, grammar] of Object.entries(languages))
  hljs.registerLanguage(name, grammar);

export function highlightMessages(container) {
  for (const block of $$(
    "pre[data-language]:not([data-highlighted])",
    container,
  )) {
    const language = block.dataset.language;
    if (!hljs.getLanguage(language) || language === "plaintext") continue;
    block.innerHTML = hljs.highlight(block.textContent, {
      language,
      ignoreIllegals: true,
    }).value;
    block.dataset.highlighted = "true";
  }
}

const allowed = new Set(
  "p div br strong b em i u s del mark code pre blockquote ul ol li h1 h2 h3 a span table thead tbody tfoot tr th td hr".split(
    " ",
  ),
);
const blocked = new Set(
  "script style iframe object embed svg math template form input".split(" "),
);

export function cleanClipboard(source) {
  const template = document.createElement("template");
  template.innerHTML = source;
  const render = (node, depth = 0) => {
    if (depth > 32) return "";
    if (node.nodeType === Node.TEXT_NODE) return escape(node.textContent);
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    const tag = node.tagName.toLowerCase();
    if (blocked.has(tag)) return "";
    let attributes = "";
    if (tag === "a") {
      const href = node.getAttribute("href") || "";
      if (/^(https?:\/\/|mailto:)/i.test(href))
        attributes = ` href="${escape(href)}"`;
    }
    if (tag === "pre" && languages[node.dataset.language])
      attributes = ` data-language="${node.dataset.language}"`;
    if (tag === "span" && node.dataset.mention) {
      const user = state.users.find(
        (item) => item.id === Number(node.dataset.mention),
      );
      if (user && state.room?.members.includes(user.id))
        return `<span data-mention="${user.id}" contenteditable="false" class="mention">@${escape(user.name)}</span>`;
    }
    const children = [...node.childNodes]
      .map((child) => render(child, depth + 1))
      .join("");
    if (!allowed.has(tag)) return children;
    return `<${tag}${attributes}>${children}${["br", "hr"].includes(tag) ? "" : `</${tag}>`}`;
  };
  return [...template.content.childNodes].map((node) => render(node)).join("");
}

let selection;
function captureSelection() {
  const current = getSelection();
  if (current.rangeCount && $("#editor").contains(current.anchorNode))
    selection = current.getRangeAt(0).cloneRange();
}
function restoreSelection() {
  $("#editor").focus();
  if (selection && $("#editor").contains(selection.commonAncestorContainer)) {
    getSelection().removeAllRanges();
    getSelection().addRange(selection);
  }
}
function selectedElement() {
  const node = selection?.startContainer;
  return node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
}
function insert(html) {
  closeModal();
  restoreSelection();
  document.execCommand("insertHTML", false, html);
  $("#editor").dispatchEvent(new Event("input", { bubbles: true }));
}

export function formatEditor(action) {
  captureSelection();
  if (action === "format-more") {
    const cell = selectedElement()?.closest("td,th");
    modal(
      "Format message",
      `<div class="menu-list">${[
        ["underline", "Underline"],
        ["strike", "Strikethrough"],
        ["mark", "Highlight"],
        ["ordered", "Numbered list"],
        ["quote", "Block quote"],
        ["heading", "Heading"],
        ["clear", "Clear formatting"],
        ...(cell
          ? [
              ["row", "Add table row"],
              ["column", "Add table column"],
              ["remove-row", "Remove table row"],
              ["remove-column", "Remove table column"],
            ]
          : []),
      ]
        .map(([name, label]) => button("format-" + name, label))
        .join("")}</div>`,
    );
    return;
  }
  if (action === "format-code") {
    const existing = selectedElement()?.closest("pre");
    const text = existing?.textContent || getSelection().toString();
    modal(
      "Code block",
      `<form><label class="field">Language<select name="language">${Object.keys(
        languages,
      )
        .map(
          (name) =>
            `<option value="${name}" ${name === existing?.dataset.language ? "selected" : ""}>${name === "plaintext" ? "Plain text" : name}</option>`,
        )
        .join(
          "",
        )}</select></label><label class="field">Code<textarea name="code" rows="8" class="code-input" maxlength="24000" required spellcheck="false">${escape(text)}</textarea></label>${formEnd("Insert code")}</form>`,
      async (data) => {
        const language = data.get("language");
        if (!languages[language]) throw new Error("Choose a language.");
        const html = `<pre data-language="${language}"><code>${escape(data.get("code"))}</code></pre>`;
        if (existing?.isConnected) {
          closeModal();
          existing.outerHTML = html;
          $("#editor").focus();
          $("#editor").dispatchEvent(new Event("input", { bubbles: true }));
        } else insert(html + "<p><br></p>");
      },
    );
    return;
  }
  if (action === "format-table") {
    modal(
      "Insert a table",
      `<form>${field("rows", "Rows", 3, "number", 'min="1" max="20" required')}${field("columns", "Columns", 2, "number", 'min="1" max="10" required')}${formEnd("Insert table")}</form>`,
      async (data) => {
        const rows = Number(data.get("rows")),
          columns = Number(data.get("columns"));
        if (
          !Number.isInteger(rows) ||
          !Number.isInteger(columns) ||
          rows < 1 ||
          rows > 20 ||
          columns < 1 ||
          columns > 10
        )
          throw new Error("Choose 1–20 rows and 1–10 columns.");
        insert(
          `<table><tbody>${Array.from({ length: rows }, (_, row) => `<tr>${Array.from({ length: columns }, () => (row ? "<td><br></td>" : "<th>Heading</th>")).join("")}</tr>`).join("")}</tbody></table><p><br></p>`,
        );
      },
    );
    return;
  }
  if (action === "format-link") {
    modal(
      "Insert a link",
      `<form>${field("url", "URL", "", "url", 'required placeholder="https://"')}${formEnd("Insert link")}</form>`,
      async (data) => {
        const url = new URL(data.get("url"));
        if (!["http:", "https:"].includes(url.protocol))
          throw new Error("Use an HTTP or HTTPS URL.");
        insert(
          `<a href="${escape(url.href)}">${escape(selection?.toString() || url.href)}</a>`,
        );
      },
    );
    return;
  }
  closeModal();
  restoreSelection();
  const commands = {
    "format-bold": "bold",
    "format-italic": "italic",
    "format-list": "insertUnorderedList",
    "format-ordered": "insertOrderedList",
    "format-underline": "underline",
    "format-strike": "strikeThrough",
    "format-clear": "removeFormat",
  };
  if (commands[action]) document.execCommand(commands[action]);
  if (action === "format-quote")
    document.execCommand("formatBlock", false, "blockquote");
  if (action === "format-heading")
    document.execCommand("formatBlock", false, "h2");
  if (action === "format-mark" && getSelection().toString())
    document.execCommand(
      "insertHTML",
      false,
      `<mark>${escape(getSelection().toString())}</mark>`,
    );
  const cell = selectedElement()?.closest("td,th"),
    row = cell?.parentElement,
    table = cell?.closest("table");
  if (cell && action === "format-row") {
    const next = row.cloneNode(true);
    for (const item of next.cells) item.innerHTML = "<br>";
    row.after(next);
  }
  if (cell && action === "format-column")
    for (const line of table.rows)
      line.insertCell(
        Math.min(cell.cellIndex + 1, line.cells.length),
      ).innerHTML = "<br>";
  if (cell && action === "format-remove-row") row.remove();
  if (cell && action === "format-remove-column") {
    const index = cell.cellIndex;
    for (const line of table.rows)
      if (line.cells[index]) line.deleteCell(index);
  }
  $("#editor").dispatchEvent(new Event("input", { bubbles: true }));
}
