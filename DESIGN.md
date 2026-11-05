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

Motion: the MacBook is the single scroll-linked scene. As it passes through the viewport, it shifts by at most 18 px (9 px on narrow screens), changes pitch by at most 1.8 degrees, and changes scale by at most 1.2%. Its wallpaper and halo move a few pixels in the opposite direction to suggest depth. Mouse tilt stays subtle; touch never drives tilt. Native anchor scrolling remains smooth, without wheel interception, artificial scroll duration, pinned sections, or scroll snapping.

The feature stories reveal their copy and illustration separately, once, with an 18 px rise (12 px on narrow screens), a 650–750 ms settle, and a 90 ms second beat (45 ms on narrow screens). Initial viewport content is immediately readable. Keyboard focus and anchor navigation reveal their targets immediately. The code prepares only below-the-fold elements and removes each from observation after its reveal; all content is visible with JavaScript disabled or IntersectionObserver unavailable.

Scene motion shares one event-driven animation frame, reads geometry once, and writes only transform variables that actually changed. No frame schedules another frame. Modern browsers skip scene work while offscreen; hiding the page or leaving it cancels pending work. CSS handles the short settle after input. Only the optional silent music preview animates continuously; it pauses offscreen and while the document is hidden. Reduced Motion disables scroll smoothing, scene depth, pointer tilt, reveals, transitions, and visualizer animation, including when changed during a visit. There are no animation dependencies or additional network requests.

Motion limits: depth deliberately stays small to keep the live demo easy to click. The non-IntersectionObserver fallback does one scene geometry read for each batch of scroll events to determine visibility. Reveals do not replay on reverse scrolling. Changing Reduced Motion on reveals all content permanently for the visit rather than re-hiding it when the preference is turned off.

Accessibility: native links, buttons, dialog and FAQ details; visible focus; arrow-key tabs; status announcements; persistent sample labels; responsive layouts down to 320 px. Demo changes live only in memory and make no requests.

Approved identity: the blue notch-shaped H with its raised upper-right shoulder and the supplied dark HeyNotch wordmark replace the earlier CSS placeholder marks. Header and footer use the complete approved lockup. The symbol alone appears in compact product and decorative positions, with no recoloring, filters, tracing, or new interpretation. Browser and home-screen icons use proportional PNG derivatives; social sharing uses the approved artwork in a dedicated 1200 × 630 composition. The masters are raster images, so fine edge detail is limited by their original resolution. The buildless website does not ship the large masters.
