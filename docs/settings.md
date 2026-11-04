# Settings

The Settings window (`SettingsWindowController`, `SettingsView`) has one sidebar page per area. The app owns the window
instead of SwiftUI's `Settings` scene: since macOS 14 that scene only opens from a view's `openSettings` action, and links,
Home, launch and the menu all need to open it on a given page (`HomeServices.openSettings(_:)`). With Show in Dock on,
the app menu's Settings… (⌘,) opens the same window.

| page | what it sets | stored in (`~/Library/Application Support/OpenClicky/`) |
|---|---|---|
| General | Launch at login, Show in Dock, Show in screen recordings, the install-location note, Home, the welcome tour, Reset local data | `app-preferences.json` |
| Models | The provider and model for each slot | `config.json` |
| Voice | Voice, speed, previews, answer and take-over switches | `voice.json`, `voice-loop.json` |
| Microphone | The input device (by CoreAudio UID) and a three-second mic test | `microphone.json` |
| Dictation | Language or automatic detection, the dictionary (50 words) and learned corrections, dictation switches | `dictation.json`, `dictation-vocabulary.json` |
| Talk keys | Four keys: talk, type, dictate, and an optional hands-free dictation key; each one a held chord or a double tap (see below) | `talk-keys.json` (a held dictation chord also in `dictation.json`) |
| Permissions | Microphone, Screen Recording, Accessibility, Speech Recognition and Input Monitoring with their state, and What agents can reach (see below) | the request log in `app-preferences.json` (`permissionRequests`) |
| Providers & keys | Providers, their keys, and every saved key with Delete | `config.json`, the login Keychain |
| Agents | Agent folder, autonomy (approval mode), reasoning effort, announcements, suggestions, grouping old jobs into kept agents, developer preview of file diffs (with the diff viewer) | `agent-settings.json` (`developerFileDiffs`); effort in `config.json`'s agent slot; `organizer.json` |
| Routines | Each routine with Run now, Pause/Resume, Delete, its last failure and its runs | `routines.json` (runs come from the job records) |
| Browser | Connection with a badge (Off, Waiting, Setup failed with the reason, Connected), a first-connection notice, the profile agents use, browser helper manifests, Load unpacked steps | `BrowserBridge/preferences.json` (also `hasEverConnected`, `firstConnectedAt`) |
| Memory, Connected apps, Services, Skills | As before | |
| Usage, Developer | Spending limits and the usage ledger; feature flags, brain stats, provider checks, Report a Bug | `Usage/limits.json`, `flags.json` |

## Launch behaviour

At launch the app, in this order: applies Show in Dock (regular or accessory activation policy); registers the login
item with `SMAppService.mainApp` on the first launch from an Applications folder only (`LoginItemPolicy`; never with
`OPENCLICKY_NO_LOGIN_ITEM` set; macOS then asks the user to approve it in System Settings → General → Login Items);
starts `WindowCaptureRegistrar`, which gives every window a role in `OwnWindowCapturePolicy` as it appears
(`WindowCaptureRoles`: click-through untitled windows are left out of OpenClicky's own screenshots, other untitled
panels are ambient chrome, titled windows are standalone; Show in screen recordings off sets the first two to
`sharingType = .none`); refreshes the browser helper manifests from the app bundle (`BundledHostInstall`, refused
outside a real `.app`); and, for a translocated or disk-image copy, says once that it should move to Applications.

## Permissions

`PermissionsCenter` reads each permission through injectable probes (`PermissionProbes`) and maps the reading with
`PermissionStateMapping`:

| state | when | the page shows |
|---|---|---|
| granted | macOS says so | Allowed |
| notDetermined | never asked (macOS says so, or Screen Recording and Accessibility are off and OpenClicky never asked) | Allow… |
| denied | macOS says so (microphone, speech, Input Monitoring), or Screen Recording and Accessibility are still off after OpenClicky asked | Open System Settings, with where to switch it on |
| restartRequired | Screen Recording is allowed in System Settings but this process's `CGPreflightScreenCaptureAccess` still says no | Quit & Reopen |

Screen Recording and Accessibility only answer yes or no, so each request is logged with its time in
`app-preferences.json` (`permissionRequests`, written by re-reading the file so General's switches stay). A second,
live Screen Recording check (`SCShareableContent`) runs only after OpenClicky asked, only while the preflight says
no, and at most every three seconds; when it succeeds the state is restart-required. **Quit & Reopen** starts a small
shell that waits for this process to exit and then runs `open` on the bundle (`RelaunchCommand`), so two copies never
run at once. Input Monitoring is read with `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` and asked for with
`IOHIDRequestAccess`; it is optional (the talk keys need it only when the event tap can only listen). Onboarding's
permissions step shows the same restart and denied states.

**What agents can reach** lists Automation (Apple Events) per installed browser OpenClicky scripts, checked with
`AEDeterminePermissionToAutomateTarget` without prompting (`AutomationProbe`, shared with the page reader), and which
protected folders (Desktop, Documents, Downloads, iCloud Drive, cloud storage, external volumes) OpenClicky has read
from before (`GuardedFolderLedger`), with links to the Automation and Files & Folders panes.

## Talk keys

Each slot stores its own kind (`TalkKeyTrigger.kind`): `hold`, a chord of two to four modifiers, or `doubleTap`, one
modifier tapped twice. The page has a Hold keys / Double-tap switch per slot; choosing the other kind records a key of
that kind. What each kind does (`TalkKeyGestureMachine`):

| slot | held chord | double tap |
|---|---|---|
| Talk | hold while talking, let go to send (brushes and shortcuts cancel) | double-tap to start; one more tap ends the question |
| Type | press and let go (no other key in between) | double tap; a triple tap toggles always-on voice |
| Dictate | hold while speaking (dictation's own hold and lock rules) | double-tap to start, again to finish |
| Hands-free | press and let go to start or finish | double-tap to start or finish |

The clash rules are the same for every slot (the same key twice, or held chords inside each other). Saved keys
migrate: files written when each slot had one fixed kind load unchanged, a key without a kind takes the slot's
default, and HeyClicky's kind names (`holdCombo`, `doubleTapModifier`) are read. `dictation.json` keeps only a held
chord, so a double-tap dictation key leaves it alone. HeyClicky's optional non-modifier `keyCode` is not supported.

## Reset local data

`LocalDataReset` deletes every entry directly inside the support folder and every Keychain item under
`com.openclicky.credentials`, removes the app's defaults and browser helper manifests, then quits. A custom agent folder
is kept. The confirmation lists what will go.

## Links

One Apple Event handler (`kAEGetURL`) receives `openclicky://` links; in-app `openclicky:` links in Home, Settings and
the jobs panel go through SwiftUI's `openURL` to the same `AppURLRouter`. `OpenClickyURLRouter` parses and checks each
link and logs the result (subsystem `app.openclicky`, category `url`, query values hidden). `occtl url <link>` shows how
a link parses; `--open` sends it to the app.

| link | goes to |
|---|---|
| `openclicky://settings/<page>` | Settings on that page, every page including `usage` and `developer` (`occtl url --list`; also `talk-keys`, `connected-apps`, `chrome`, `shortcuts`, `limits`, `dev`, `flags`) |
| `openclicky://home[/chat\|agents\|drawings\|skills]` | Home |
| `openclicky://job/<id>` | Home → Agents and the jobs panel |
| `openclicky://routine/<id>` | Settings → Routines with the routine open |
| `openclicky://onboarding` | The welcome tour |
| `openclicky://file?path=/abs/path` | Shows the file in Finder, only inside the agent folders |

The in-app form drops the slashes: `openclicky:job/<id>`. Result cards, the jobs panel, Home and Settings all route
these through the app's router (the result-card panel installs `openURL` like the jobs panel), and the background
agents' instructions tell them to link jobs, Settings pages and the files they made this way. Anything else is refused: another scheme, a user, password or
port, unknown pages or sections, ids that aren't short and plain, a query on any route but `file`, and relative or
`..` paths. Connected-app sign-in returns through a loopback listener, so it needs no route.

## occtl

- `occtl routines list|show|add|run|pause|resume|delete`: the routines page from a terminal. `run` uses the app's
  agent settings (approval mode, agent folder, the agent slot's model and effort). The app's scheduler rereads
  `routines.json` before each pass and edit, so edits made here while the app runs are kept.
- `occtl url <link> [--open]`, `occtl url --list`.
- `occtl browser status` now also counts each browser's profiles from `Local State`.
