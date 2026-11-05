# HeyNotch website

The marketing website is hosted on **GitHub Pages only** at
**https://wolfieeee.github.io/HeyNotch/**.

Website source lives on the `gh-pages` branch of `WOLFIEEEE/HeyNotch`. The app
continues to live on `main`; publishing the website does not publish app changes.
The entire website is static HTML, CSS and JavaScript in `dist/`. There is no build
step, dependency installation, external font, CDN, analytics or form backend.

## Local preview

```sh
python3 -m http.server 8080 --bind 127.0.0.1 --directory dist
```

Open `http://localhost:8080`. The laptop is a browser-only product illustration:
sample tasks, silent music controls, an illustrative transcript and a preset agent
command. It does not connect to the app, call providers, capture media, store
browser data or change Reminders.

“Get HeyNotch” opens a dialog explaining that the app is a development preview and
links to the fork's source, which may not yet contain every feature illustrated.
No downloadable app release is advertised.

## Publish

Push reviewed website changes to **`WOLFIEEEE/HeyNotch:gh-pages`**. The
`.github/workflows/pages.yml` workflow validates the site and publishes only
`dist/` through GitHub Actions. Its official actions are pinned to full commit
SHAs. It needs no personal deployment token or third-party hosting account.

```sh
git push origin HEAD:gh-pages
```

Repository Settings → Pages must use **GitHub Actions**. The `github-pages`
environment permits the `gh-pages` branch only. The inherited `static.yml`
workflow, which publishes `updater/` from `main`, is disabled so it cannot replace
this site. Leave that workflow disabled. Do not enable a second Pages publishing
workflow from the app branch.

The workflow runs on pushes to `gh-pages`. Because the website is deliberately
separate from the default app branch, updates use pushes and retries use the
existing run's **Re-run jobs** action. No manual-dispatch workflow is assumed on
`main`. Never force push or target the original upstream repository.

All assets use relative paths so they work under GitHub Pages' `/HeyNotch/`
project path. Canonical and social-image URLs point to the GitHub Pages origin.
If the project path ever changes, update those absolute metadata URLs too.
CSS and JavaScript URLs in `index.html` include content-version queries. Update
those values after editing either asset so returning visitors get matching files.

## Validation

```sh
node --check dist/app.js
node --test tests/*.test.cjs
python3 scripts/check-site.py
```

Browser checks cover desktop and 320 px mobile layouts, scroll-linked depth,
one-time section reveals, smooth anchors, task movement, keyboard tabs, music,
sample transcript, agent sample creation, mobile navigation, dialog focus/Escape,
FAQ disclosures, Reduced Motion and content visibility without JavaScript.

Motion uses native scrolling and transform/opacity effects. It never intercepts
wheel or touch input. Visual changes are coalesced into animation frames only
while needed; offscreen and background scenes stop moving. Reduced Motion removes
the decorative movement and smooth scrolling. See `DESIGN.md` for motion choices.

## Files and license

- `dist/index.html`: content, accessible demo, FAQ and preview dialog.
- `dist/style.css`: responsive layout, CSS laptop and motion.
- `dist/app.js`: demo controls, navigation, reveals and scene movement.
- `dist/favicon.svg`, `dist/social.svg`: original artwork.
- `.github/workflows/pages.yml`: GitHub Pages publishing.
- `tests/`, `scripts/`: verification without installed dependencies.

GPL-3.0. `LICENSE` and `THIRD_PARTY_LICENSES` are retained from the app project.
This website does not bundle the app's third-party native dependencies. All
project links target `WOLFIEEEE/HeyNotch`.
