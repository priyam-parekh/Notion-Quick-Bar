# Notion Quick Bar

A lightweight macOS menu bar app for your Notion task database. See what's due today at a glance, add tasks in plain English with smart dates, check them off instantly, and summon the panel from anywhere with **⌥T** — no browser tab required.

Built with SwiftUI and the Notion API. Requires **macOS 26** or later.

---

## Table of contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Installation](#installation)
- [First-time setup (onboarding)](#first-time-setup-onboarding)
- [Notion database setup](#notion-database-setup)
- [Using the widget](#using-the-widget)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Appearance modes](#appearance-modes)
- [How it works](#how-it-works)
- [Privacy & security](#privacy--security)
- [Development](#development)
- [Troubleshooting](#troubleshooting)

---

## Overview

Notion Quick Bar lives in your menu bar as a post-it note icon. The icon shows how many **Today** tasks you have (stacked notes for 1–9+ tasks).

Click the icon—or press **⌥T** anywhere on your Mac—to open a floating panel where you can:

- View tasks due today, overdue, or undated
- Add new tasks with natural-language dates (`email Sam Friday`, `buy milk tomorrow`)
- Mark tasks complete with a smooth animation and optional undo
- Star tasks as **Priority** (synced to Notion)
- Drag to reorder **Today** tasks (order is saved locally)
- Navigate and act on tasks entirely from the keyboard
- Open your Notion database or individual task pages in the browser

The widget syncs with Notion in the background and refreshes automatically every few minutes.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **macOS** | 26.0 or later |
| **Notion** | A database you can connect via an [internal integration](https://developers.notion.com/docs/create-a-notion-integration) |
| **Network** | Internet access to `api.notion.com` |
| **Apple Intelligence** (optional) | On-device language model improves date parsing when the built-in detector cannot find a date |

---

## Installation

### Option A — Build a menu bar app (recommended)

From the project root:

```bash
./Scripts/build_app.sh
```

This will:

1. Compile a release build with Swift Package Manager
2. Create `NotionMenuBar.app` in the project folder
3. Ad-hoc sign the bundle
4. Copy it to `/Applications/NotionMenuBar.app` (the built app bundle name; the product is **Notion Quick Bar**)

The app runs as a **menu bar agent** (no Dock icon). Add it to **Login Items** in System Settings if you want it to start at login.

### Option B — Run from source (development)

```bash
swift run NotionMenuBar
```

Use this while iterating on the project. The widget behaves the same, but runs as a terminal-launched process.

---

## First-time setup (onboarding)

When you open the widget for the first time without credentials configured, **Settings opens automatically**.

### Step 1 — Create a Notion integration

1. Go to [notion.so/my-integrations](https://www.notion.so/my-integrations)
2. Create a new **internal** integration
3. Copy the **Internal Integration Secret** (starts with `secret_…`)

### Step 2 — Connect your database

1. Open the Notion database you want to use as your task list
2. Click **⋯ → Connections** and add your integration
3. Copy the **database ID** from the database URL:
   - URL format: `https://www.notion.so/workspace/DATABASE_ID?v=…`
   - You can paste the full URL or just the 32-character ID

### Step 3 — Save in the widget

1. Click the **gear icon** in the widget header (or wait for Settings to open on first launch)
2. Paste your **Integration Token** and **Database ID**
3. Click **Save**

Credentials are stored in the macOS Keychain. After saving, the widget loads your open tasks from Notion.

To replace credentials later, open Settings again and enter new values. When already configured, the token field stays empty and the database field shows **“Saved securely”** until you type a replacement.

---

## Notion database setup

Notion Quick Bar works with a standard **table database** of tasks. Each row is one task; the app reads and writes a small set of properties.

### What your database should look like

A minimal working setup is a table with four columns:

| Name | Done | Date | Priority |
|------|------|------|----------|
| Email Sam about the proposal | ☐ | Jul 6, 2026 | Priority |
| Buy groceries | ☐ | Jul 7, 2026 | |
| Write blog post | ☐ | | |
| Old completed task | ☑ | Jul 1, 2026 | |

**Column types in Notion:**

| Column | Notion property type | Notes |
|--------|---------------------|-------|
| **Name** | Title | Every Notion database has one title column. This is the task text shown in the widget. |
| **Done** | Checkbox | Unchecked tasks appear in the widget; checked tasks are hidden. |
| **Date** | Date | Due date only (no time required). Drives Today / Tomorrow / Week grouping. |
| **Priority** | Select | Must include an option named exactly **Priority**. Starred tasks in the widget set this option. |

You can name columns differently—the app auto-detects types—but the recommended names above match what the app looks for first.

### Example in Notion

When creating properties in Notion, configure them like this:

1. **Name** — type: *Title* (default on new databases)
2. **Done** — type: *Checkbox*
3. **Date** — type: *Date* (date only, or date + time; the app uses the date portion)
4. **Priority** — type: *Select*, with one option: `Priority`

```
┌─────────────────────────────────┬──────┬────────────┬──────────┐
│ Name (Title)                    │ Done │ Date       │ Priority │
├─────────────────────────────────┼──────┼────────────┼──────────┤
│ Review PR                       │  ☐   │ Today      │ Priority │
│ Call dentist                    │  ☐   │ Tomorrow   │          │
│ Plan vacation                   │  ☐   │ Jul 12     │          │
│ Inbox zero                      │  ☐   │ (empty)    │          │
└─────────────────────────────────┴──────┴────────────┴──────────┘
```

**Tasks without a date** still show up—they appear in **Today** alongside due-today and overdue items.

**Tasks with Done checked** never appear in the widget (the app only fetches open tasks).

### Minimal vs. full setup

| Setup | Properties | What works |
|-------|------------|------------|
| **Minimal** | Title only | View and add tasks; no completion sync, no dates, no priority |
| **Recommended** | Title + Done + Date | Full task list, completion, date grouping |
| **Full** | Title + Done + Date + Priority (Select) | Everything, including star / overdue promotion |

### Property detection

The app discovers your database schema automatically. It looks for these property types:

| Property type | Purpose | Required? |
|---------------|---------|-----------|
| **Title** | Task name | Yes (every database has one) |
| **Checkbox** | Mark tasks done | Strongly recommended — without it, completion cannot sync |
| **Date** | Due date | Recommended — used for Today / Tomorrow / Week grouping |
| **Select** | Priority flag | Optional — option must be named **Priority** |

### Property name hints

If your database has multiple properties of the same type, the app prefers:

- Checkbox named **Done**
- Date named **Date** or **Due**
- Select named **Priority** or **Important**

Other property types (Status, Tags, Person, URL, etc.) are ignored and can stay on your database for use inside Notion—they won't affect the widget.

### What gets synced

| Action in widget | Notion effect |
|------------------|---------------|
| Add task | Creates a new page in the database |
| Mark complete | Sets the Done checkbox to `true` |
| Star / unstar | Sets or clears the **Priority** select option |
| Overdue task | Automatically promoted to Priority on sync |
| Drag reorder | **Local only** — Notion has no row order API |

---

## Using the widget

### Opening and closing

- **Click** the menu bar icon
- **⌥T** (Option + T) toggles the panel from anywhere (no Accessibility permission required)

Press **Esc** or click outside to close.

### Task sections

| Section | Shows |
|---------|-------|
| **Today** | Undated tasks, tasks due today, and overdue tasks |
| **Tomorrow** | Tasks due tomorrow (when any exist) |
| **Week** | Tasks due 2–7 days out (toggle with the calendar icon in the header) |

The menu bar badge counts **Today** tasks only.

### Adding a task

1. The add field is focused when the panel opens — start typing immediately
2. Press **Enter** to create the task
3. Include a date naturally: `Review PR tomorrow`, `Call dentist next Friday`, `Submit report by Mar 15`

**Date parsing:**

1. Apple’s built-in date detector runs first (fast, on-device)
2. If no date is found and Apple Intelligence is available, an on-device language model extracts the date
3. The task title is never rewritten—only the date phrase is removed

When a task is scheduled beyond tomorrow, a green **Added · Mar 15** label briefly appears in the field.

Press **Enter** on an empty field to close the widget.

### Completing a task

- Click the circle next to a task, or select it and press **Enter**
- A checkmark animation plays, then the task is removed locally and marked done in Notion
- An **undo** arrow appears in the header for ~5 seconds to reverse the action

### Priority (star)

- Hover a task to reveal the star, or select it and press **Tab**
- Starred tasks move to the **top** of Today; unstarred tasks fall to the **bottom**
- Overdue tasks are automatically starred on sync

### Reordering (Today only)

Drag a Today task up or down. A blue line shows the drop position. Order is saved on your Mac and persists across launches; it does not change order in Notion.

### Opening in Notion

- **↗** in the header opens your database in the browser
- Hover a task and click **↗** to open that specific page

### Settings

Open via the **gear icon** in the header:

- **Light Mode** / **Lunar** appearance toggles (mutually exclusive)
- Notion credentials
- **Restart** — relaunches the app (useful after updates)
- **Cancel** / **Save**

---

## Keyboard shortcuts

Shortcuts work while the widget panel is open (except in Settings):

| Key | Action |
|-----|--------|
| **↑ / ↓** | Move selection between tasks; **↓** from the last task focuses the add field |
| **Enter** | Mark selected task complete |
| **Tab** | Toggle Priority on selected task |
| **Esc** | Close the widget |
| **⌥T** | Toggle widget from anywhere (global) |

When typing in the add field, arrow keys behave normally until you navigate back into the task list.

---

## Appearance modes

Three visual styles are available. **Light Mode** and **Lunar** are mutually exclusive; the default follows your system appearance.

| Mode | Description |
|------|-------------|
| **Default** | Native macOS material panel; adapts to system light/dark |
| **Light Mode** | Forces a bright, frosted light appearance regardless of system theme |
| **Lunar** | Dark command-palette style: graphite panel, high-contrast text, purple selection glow |

Toggle modes in **Settings → Appearance**.

---

## How it works

```
Menu bar icon
     │
     ▼
ContentView (SwiftUI panel)
     │
     ▼
TaskStore (state + sync)
     ├── Keychain ── integration token, database ID
     ├── UserDefaults ── task order, appearance, week mode
     └── NotionClient ── HTTPS to api.notion.com
              │
              ▼
         Your Notion database
```

### Sync behavior

- Refreshes when you open the panel (if data is older than ~60 seconds)
- Background refresh every **5 minutes**
- Force refresh after adding a task, changing priority, or completing/undoing
- Optimistic UI: complete and star actions update locally first, then sync to Notion

### Task grouping

Tasks are grouped by due date relative to today:

- **Today** — no date, due before tomorrow, or overdue
- **Tomorrow** — due exactly tomorrow
- **Week sections** — one section per day, days 2–7 ahead (when Week mode is on)

### Menu bar icon

The icon is a custom-drawn post-it note stack:

- **0 tasks** — dashed outline with “0”
- **1–2 tasks** — stacked notes with count
- **9+** — displays “9+”

---

## Privacy & security

| Data | Storage |
|------|---------|
| Notion integration token | macOS Keychain (`When Unlocked, This Device Only`) |
| Database ID | macOS Keychain |
| Task order, appearance prefs | UserDefaults (local) |
| Task titles & content | Fetched from Notion over HTTPS; displayed in the panel only |

- Credentials are **never** hardcoded in source or logged to the console
- API errors are mapped to generic user-facing messages (raw Notion responses are not shown)
- Natural-language date parsing uses Apple’s on-device date detector; optional Apple Intelligence processing stays on your Mac
- Only `api.notion.com` is contacted

---

## Development

### Project structure

```
Sources/NotionMenuBar/
├── NotionMenuBarApp.swift   # App entry, MenuBarExtra scene
├── ContentView.swift        # Main widget UI
├── SettingsView.swift       # Credentials & appearance
├── TaskStore.swift          # State, sync, grouping
├── NotionClient.swift       # Notion REST API
├── TaskParser.swift         # Natural-language date parsing
├── TaskItem.swift           # Task model
├── KeychainHelper.swift     # Secure credential storage
├── HotKeyManager.swift      # ⌥T global shortcut
└── MenuBarIcon.swift        # Menu bar icon rendering
```

### Build & run

```bash
swift build          # Debug build
swift run NotionMenuBar
./Scripts/build_app.sh   # Release .app → /Applications
```

### Platform

Declared in `Package.swift`:

```swift
platforms: [.macOS(.v26)]
```

---

## Troubleshooting

| Problem | What to try |
|---------|-------------|
| **“Connect Notion in Settings”** | Open Settings and enter your token + database ID |
| **“Notion authentication failed”** | Verify the integration secret is correct and not revoked |
| **“Notion permission denied”** | Share the database with your integration (Connections) |
| **Tasks don’t complete** | Ensure the database has a **Checkbox** property (e.g. “Done”) |
| **Priority star doesn’t sync** | Add a **Select** property with an option named **Priority** |
| **Dates not parsed** | Try explicit phrasing (`tomorrow`, `Friday`, `Mar 15`); Apple Intelligence improves parsing on supported Macs |
| **Widget doesn’t open with ⌥T** | Another app may have captured Option+T; quit conflicting apps |
| **Changes after updating** | Use **Settings → Restart** or relaunch from `/Applications` |

---

## License

Add your license here before publishing to GitHub.
