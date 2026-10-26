# SubScreen Studio — Widget Candidates

Use the ID column to choose what should be built next. Difficulty includes the UI, data connection, permissions, and graceful offline behavior.

## Best next additions

| ID | Widget | What it would show | Difficulty | Notes |
|---|---|---|---|---|
| 1 | Now Playing | Artwork, song, artist, progress, playback state | Medium | Start with Apple Music; add Spotify later. |
| 2 | Synced Lyrics | Current line, previous/next line, karaoke-style progress | High | Safest first version reads user-supplied `.lrc` files. Streaming-service lyric text is not generally exposed through a simple public macOS API. |
| 3 | Notification Banner | App icon, title, message, priority, auto-dismiss | Medium | Recommended input is a local webhook/Shortcuts action with an allow-list. Reading every macOS notification is not provided by the normal public notification API. |
| 4 | Calendar | Next meeting, countdown, location, all-day events | Medium | Apple Calendar first; Google/Outlook can follow. Add a privacy mode that hides event titles. |
| 5 | Reminders / Tasks | Next tasks, due time, completion progress | Medium | Apple Reminders is a natural first source on macOS. |
| 6 | Focus Timer | Pomodoro, countdown, stopwatch, session progress | Easy | Fully local and reliable. Can switch scenes when focus starts or ends. |
| 7 | System Monitor | CPU, memory pressure, disk, network, battery, temperature | Medium | Local-only and privacy-friendly. Use small history graphs. |
| 8 | Codex Live Status | Usage windows, resets, active task, completion/failure banner | Medium–High | Usage needs a supported local feed; task events can be delivered through a local integration. |
| 9 | Weather Plus | Hourly forecast, rain alert, AQI, sunrise/sunset | Medium | Extends the existing Open-Meteo widget. |
| 10 | Scene Scheduler | Rotate scenes by time/day, app, Focus mode, or sunrise | Medium | This is a platform feature rather than a visual widget, but greatly improves an always-on display. |

## More useful candidates

| ID | Widget | Function | Difficulty |
|---|---|---|---|
| 11 | RSS / Headlines | Rotating headlines from chosen feeds | Easy–Medium |
| 12 | Stocks / Crypto | Price, daily change, compact sparkline | Medium |
| 13 | Sports | Live score, match clock, upcoming game | Medium |
| 14 | Transit / Commute | Next departures, delays, travel time | Medium–High |
| 15 | World Clocks | Several cities, daylight indicator | Easy |
| 16 | GitHub / Build Status | Pull requests, CI status, deployments, commits | Medium |
| 17 | Smart Home | Temperature, lights, locks, energy, Home Assistant status | Medium–High |
| 18 | Chat Status | Slack/Teams/Discord unread count or presence | High |
| 19 | Creator Counters | YouTube/Twitch followers, viewers, milestones | Medium |
| 20 | Audio Visualizer | Spectrum, waveform, volume meter | High; requires audio-capture permission |
| 21 | Photo Album | Rotate a folder/Photos album with transitions | Medium |
| 22 | Web Snapshot | Periodically capture a chosen dashboard or webpage | High; needs secure login handling |
| 23 | Package Tracker | Carrier, current state, expected delivery | High; provider APIs vary |
| 24 | Environment | AQI, pollen, UV, moon phase, tides | Medium |
| 25 | Message Board | Local text, QR code, webhook-fed messages | Easy |

## Suggested build order

1. Now Playing, Focus Timer, Calendar, and Notification Banner.
2. Local `.lrc` Lyrics, System Monitor, and Weather Plus.
3. Scene Scheduler, Reminders, and Codex Live Status.
4. Add cloud/service integrations only after the local widget framework and permission screens are stable.

## Product patterns worth borrowing

- A searchable widget gallery with preview cards.
- Multiple saved configurations of the same widget.
- Per-widget refresh intervals and visible “last updated” state.
- Scheduling, pinning, muting, and automatic scene rotation.
- Privacy controls for calendar titles, messages, and notifications.
- A local webhook so Shortcuts and other apps can push data without a cloud account.
- Clear offline/error states rather than blank widgets.
