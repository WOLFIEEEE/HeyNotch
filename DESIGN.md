# HeyNotch — a little more Mac

Subject: an independent macOS notch companion for people who want tasks, music, dictation and meeting notes close at hand. The site's job is to make that small workspace tangible, then give an honest next step for the current preview build.

Palette: ice `#f7f9fe`, paper `#ffffff`, ink `#172333`, mist `#68758a`, blue `#3975e7`, lilac `#e8e5f7`. Dark UI is confined to the notch demo. Display typography uses Avenir Next with system fallbacks; body uses the native system sans; small screen captions use the system monospace stack. No remote fonts or other external assets.

The signature is a dimensional, CSS-built MacBook with a working expanded-notch preview. An oversized, quiet headline introduces it. The rest of the site is deliberately more still: an asymmetrical task story, an open meeting transcript, a typography-led dictation section, and a scoped-agent example. Sections change composition as the subject changes; they do not repeat a feature-card template.

```
brand                 feature links                  source / get
                    A little more Mac.
                    a short explanation
                      two clear actions
                   [interactive demo tabs]
                  / dimensional MacBook /
                        sample caption
task story          spacious reminder / progress illustration
meeting story       two voices / one sample transcript
dictation           large words / own-provider choices
agent example       selected lists / explicit permissions
native FAQ disclosure rows
                 preview-build invitation / source
```

Critique before build: a floating dashboard with a blue glow could belong to any productivity site. Here the physical display, real notch geometry, local-vs-Reminders task states and browser-only interactive examples tie the signature to this app. Decorative glows and background motion are removed from the remaining sections. No invented launch numbers, testimonials, download links or production-readiness claims.

Motion: a small pointer tilt and a restrained scroll offset use event-driven animation frames. Scrolling remains native. Only the optional music preview animates continuously, using CSS; it pauses outside the viewport and while the document is hidden. Reduced Motion removes transforms, reveals and visualizer animation. Content is present without JavaScript.

Accessibility: native links, buttons, dialog and FAQ details; visible focus; arrow-key tabs; status announcements; persistent sample labels; responsive layouts down to 320 px. Demo changes live only in memory and make no requests.
