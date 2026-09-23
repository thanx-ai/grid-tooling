# The browser tab belongs to Windmill — set the favicon and title on the TOP document

A deployed raw_app renders inside Windmill's `blob:` iframe, and the browser reads the tab **only** from the top-level document. Windmill's SvelteKit shell ships a static `<link rel="icon" href="/logo.svg">` in `app.html` and a title of `App <path> | Windmill`, so every Grid app shows the Windmill mark and a raw workspace path in the tab unless it reaches up and overwrites them. A `<link>` or a `document.title =` inside your own bundle is inert — it writes to the iframe's document, which nothing displays.

The iframe is same-origin and unsandboxed by default (`sandbox` attribute absent, `window.parent.document` readable), so walking up to the top document works. Only an app opted into Windmill's sandbox isolation gets an opaque origin, where the walk degrades to your own document and the write silently does nothing.

## The drop-in

Copy this into the app (e.g. `lib/grid-chrome.ts`). **Do not import it across raw_apps** — each one bundles standalone and the per-item Grid deploy can't resolve a cross-app import, so duplication is correct here.

```ts
/** Highest same-origin document: the Windmill page when deployed, our own in local dev. */
function topDocument(): Document {
  let doc: Document = document;
  try {
    let win: Window = window;
    while (win.parent && win.parent !== win) {
      const parent = win.parent;
      doc = parent.document; // throws if cross-origin → caught below
      win = parent;
    }
  } catch {
    /* cross-origin ancestor: keep the highest same-origin document reached */
  }
  return doc;
}

const FAVICON_MARKER = "data-grid-app-favicon";

export function setFavicon(href: string): void {
  if (typeof document === "undefined") return;
  applyFavicon(topDocument(), href);
}

/** Split out from setFavicon so it is unit-testable against happy-dom/jsdom. */
export function applyFavicon(doc: Document, href: string): void {
  if (!href) return;
  const head = doc.head;
  if (!head) return;

  let ours: Element | null = null;
  for (const link of Array.from(doc.querySelectorAll('link[rel~="icon"]'))) {
    if (link.getAttribute(FAVICON_MARKER) !== null && !ours) ours = link;
    else link.parentNode?.removeChild(link);
  }

  if (!ours) {
    const link = doc.createElement("link");
    link.setAttribute("rel", "icon");
    link.setAttribute(FAVICON_MARKER, "");
    head.appendChild(link);
    ours = link;
  }
  if (ours.getAttribute("href") !== href) ours.setAttribute("href", href);
}

export function setAppTitle(title: string): void {
  if (typeof document === "undefined") return;
  topDocument().title = title;
}
```

Call it from a `useEffect` once the icon is known. The Grid has no static file serving, so `href` is a `data:` URI out of your inlined asset map, never a `/public` path.

## Four things that look optional and are not

1. **Remove the shell's `<link>`, don't append beside it.** With two `rel="icon"` links the browser takes the first, which is Windmill's. Appending "works" — the node is in the DOM, a snapshot shows your href — and the tab does not change. Use `rel~="icon"`, which also catches a legacy `rel="shortcut icon"`.
2. **Reuse your own link across calls.** A `useEffect` that appends unconditionally stacks one link per render. The marker attribute is what makes the second call an update instead.
3. **No-op on an empty href.** Asset maps resolve async, so the first render passes `""`. Wiping the shell's icon to render nothing gives a blank tab for that beat; holding Windmill's mark a moment longer looks better and is one `if`.
4. **Never `instanceof` a node from the top document.** When the walk lands on the parent frame, its nodes belong to the *parent's* realm, so `el instanceof HTMLLinkElement` is `false` against your iframe's constructor and the write is skipped with no error. Stick to `getAttribute`/`setAttribute`/`removeChild`, which are realm-agnostic. This has bitten Grid chrome code before — see the same warning on the sidebar helper in `thanx-sales-demo`.

Also skip the `type` attribute. The href's format follows whatever asset is configured (WebP by default, PNG/JPEG once someone uploads their own), and a wrong declared MIME is worse than letting the browser sniff.

## How to verify

Load the deployed app and inspect the **top** document, not the iframe:

```js
JSON.stringify(Array.from(document.querySelectorAll('link[rel~="icon"]'))
  .map(l => ({ href: l.getAttribute("href"), marker: l.getAttribute("data-grid-app-favicon") })))
```

Exactly one entry, `href` your data URI, `marker` non-null. Two entries means you appended instead of replacing. A `marker` of `null` means your code never ran — check that the bundle actually deployed before debugging the logic.

Note the write survives in-app HashRouter navigation but **not** a reload, which re-runs `app.html` and restores Windmill's icon. That's fine, because your bundle remounts and re-applies. Don't add a `MutationObserver` for it.

Windmill also caches `bundle.js`, so hard-refresh (Cmd+Shift+R) before concluding a fresh deploy didn't take.

## How we got bit

September 2026, `f/sales/thanx_studio` (the sales demo): every surface of the app was branded to the prospect and the browser tab still read `App f/sales/thanx_studio | Windmill` beside the Windmill logo, in front of prospects for the length of a call. The first instinct — a `<link>` in the app's own `index.tsx` — is inert, for the same reason a CSS rule in the bundle can't touch the floating Edit button: it's the shell's document, not ours.
