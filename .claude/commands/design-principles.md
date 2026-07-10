Read this file fully before producing any design output. It is the single source of truth for kwwhat brand and design principles.

If the user invokes this skill without other guidance, ask what they want to build, then act as an expert designer — outputting HTML artifacts for visual work or production-ready code for engineering work.



## Voice & Tone

- **Casual + technical**: speaks to data practitioners without condescending. Curious, energetic, direct.
- **"We"** for the project; **"you"** when addressing the user.
- **Lowercase brand name**: always `kwwhat` in prose. The logo has its own stylized casing.
- **Playful precision**: loves a good pun (kW = kilowatts + "kWwhat"). Technical rigor meets wordplay.
- **No jargon without context**: OCPP, EVSE, NEVI are explained on first use.
- **Tight copy**: no filler, no fluff. Metrics-first.

**Casing rules:**
- Headlines: Title Case; UI labels: sentence case
- CTAs: sentence case ("Get started", "View dashboard")
- Metric names: `snake_case` in code; plain English in UI ("visit success rate")

**Emoji:** ⚡ only — used sparingly in headers and CTAs. Not in dashboard data tables.

**Example copy:**
- "kWwhat turns raw charger logs into answers ⚡"
- "From raw OCPP logs to automated reliability reporting"
- "What happened? Why did it happen? What should we do next?"

---

## Visual Foundations

### Colors

| Token | Hex | Usage |
|---|---|---|
| `--kw-magenta` | `#C358AA` | Primary brand; logo bg, headlines, primary buttons |
| `--kw-cyan` | `#6AD8D7` | Secondary accent; logo text, highlights, info |
| `--kw-yellow` | `#FFD134` | Lightning / energy; success states, CTAs, bolt icon |
| `--kw-dark` | `#1E1E2E` | Near-black; sidebar bg, dark mode, mono logo |
| `--kw-charcoal` | `#3D3D4E` | Secondary text, table rows |
| `--kw-mid` | `#7A7A8E` | Muted text, labels, placeholders |
| `--kw-light` | `#FBF5FC` | Page background — warm pinkish white |
| `--kw-border` | `#E0DDE8` | Dividers, input borders |
| `--color-success` | `#3BB87A` | Available / successful |
| `--color-error` | `#E05050` | Faulted / failed |

Full token set: see `colors_and_type.css`.

### Typography

- **Display**: Barlow Condensed Black Italic — logo, hero headlines, large metric values
  - Google Fonts import: `family=Barlow+Condensed:ital,wght@1,900`
  - ⚠️ Substitution: original brand font is similar but commercial. Ask for files if pixel-perfect is needed.
- **Body**: DM Sans — all UI copy, labels, captions, buttons
- **Mono**: JetBrains Mono — metric names, SQL, IDs, code

**Type scale** (major third): `--text-xs` 10px → `--text-hero` 80px. See `colors_and_type.css`.

### Shapes & Layout

- **Parallelogram** is the signature brand shape — the logo lives in a skewed panel. Use `transform: skewX(-8deg)` for brand moments.
- Cards: white bg, `border-radius: 16px`, `box-shadow: 0 2px 8px rgba(30,30,46,0.10)`
- No gradient backgrounds — flat, bold color blocks only
- No colored left-border-only cards
- Sidebar: dark (`#1E1E2E`); main content: `--kw-light`

### Spacing

Base unit: 8px. Scale: 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64 / 96px.

Border radii: 4px (badges) · 8px (buttons/inputs) · 16px (cards) · 999px (pills)
