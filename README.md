# HeyNotch marketing site

Serve the `dist` directory with any static file server. There is no build step, dependency installation, external font, CDN, analytics service or form backend.

```sh
python3 -m http.server 8080 --directory dist
```

Open `http://localhost:8080`. The interactive laptop is a browser-only product illustration with sample tasks, a silent music visualizer, a sample transcript and a preset agent command. It does not connect to the installed app, call providers, capture media, store browser data or change Reminders.

“Get HeyNotch” opens a native dialog explaining that the project is a preview and linking to the fork's public source, which may not contain every feature shown in the development preview. No downloadable release is advertised. All repository links target `WOLFIEEEE/HeyNotch`.

Files:

- `dist/index.html`: content, accessible demo panels, FAQ and preview dialog.
- `dist/style.css`: responsive design, CSS laptop and contained motion.
- `dist/app.js`: tabs, sample interactions, dialog, navigation and event-driven scene movement.
- `dist/favicon.svg`: original notch mark.
- `dist/social.svg`: original social-preview artwork.

Validate JavaScript with `node --check dist/app.js`. Browser checks should cover 320 px, tablet and desktop widths; task movement; keyboard tab navigation; silent play/pause; transcript preview; agent sample creation; mobile navigation; dialog focus/Escape; FAQ disclosures; Reduced Motion; and JavaScript disabled. Canonical and social-image URLs use the site origin supplied during registration: `https://heynotch.remotemars.chatgpt.site/`. Registration is not a claim that the site has been deployed.
