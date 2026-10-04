// "Copy link" + "Email" share controls, reused by both the KPI home page
// (src/index.md) and the full System Performance Dashboard (src/spm/index.md)
// -- a small, page-chrome-agnostic pair next to each page's own theme toggle,
// not specific to either page's own data or layout.

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

const COPY_LABEL = "🔗 Copy link";
const COPY_DONE = "✓ Link copied";
const COPY_FAILED = "Couldn't copy -- copy from the address bar";

/**
 * A "Copy link" button and a "Email" mailto link for a page's header.
 * Both act on the current page's own URL at click/render time, so each
 * page (KPI home, full dashboard) gets its own link/subject without this
 * module needing to know which page it's on.
 *
 * @param {object} [options]
 * @param {string} [options.subject]  mailto subject line
 * @param {string} [options.body]     mailto body text (plain text); the
 *   current page URL is appended on its own line automatically
 */
export function renderShareControls({subject = "", body = ""} = {}) {
  const wrap = el("div", "share-controls");

  const copyButton = el("button", "share-copy-link", COPY_LABEL);
  copyButton.type = "button";
  copyButton.setAttribute("aria-live", "polite");
  let resetTimer;
  copyButton.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(location.href);
      copyButton.textContent = COPY_DONE;
    } catch {
      // Clipboard API unavailable (permissions, insecure context, old
      // browser) -- the address bar already has the link, so this is a
      // graceful fallback message, not a dead end.
      copyButton.textContent = COPY_FAILED;
    }
    clearTimeout(resetTimer);
    resetTimer = setTimeout(() => (copyButton.textContent = COPY_LABEL), 2500);
  });

  const mailLink = el("a", "share-email", "✉️ Email");
  const mailBody = body ? `${body}\r\n\r\n${location.href}` : location.href;
  mailLink.href = `mailto:?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(mailBody)}`;

  wrap.append(copyButton, mailLink);
  return wrap;
}
