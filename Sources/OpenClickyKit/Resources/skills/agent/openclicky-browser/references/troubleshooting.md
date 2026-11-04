# When a call fails

| The tool says | What to do |
|---|---|
| The browser isn't connected, so OpenClicky asked the user to connect Chrome | Finish the parts that don't need a website, then end your turn saying the website steps are waiting. You'll hear when it connects. |
| No browser is connected | Finish the parts of the job that don't need the browser. Report that the user needs Chrome (or another Chromium browser) running with the OpenClicky extension. Don't retry. |
| The agent turn ended. | Your turn is over; nothing more can happen in the browser until your next turn. |
| Browser connection changed. Start a new turn. | The browser reconnected and your tabs and refs may be gone. Finish the turn and report where you got to. |
| Browser access ended for this turn after an action timed out | Don't touch the browser again this turn. Say what you were doing so the user can check the page. |
| The browser bridge isn't running | OpenClicky's browser bridge is off. Report it; don't retry. |
| The user pressed Stop in the OpenClicky extension | Stop using the browser for this job. Say what is left to do in the browser. |
| The page didn't answer in time. Nothing was changed | Reads change nothing, so retry once. If a background tab seems asleep, `open` the same URL in a tab of your own. |
| Browser action timed out. Its outcome is unknown | The action may have happened. Don't repeat it; access ends for this turn (see above). |
| Ref … is unknown or no longer on the page | The page changed. `snapshot` again (with `query`) and use the new ref. |
| … isn't visible; scroll or open the section that holds it | `scroll {ref}` or open the menu or section, then snapshot again. |
| … is covered by … Close or dismiss it first | Close the banner, dialog or cookie notice, then retry. |
| … is disabled | Something earlier in the form is missing. Read the page for error text. |
| … is a list; use select / isn't a native list | Use `select` for native lists; for custom ones, click, read, click the option. |
| No option matches … | Use one of the option texts listed in the error. |
| doesn't type into / doesn't fill password, one-time-code or payment fields | That field is the user's. Ask them to fill it in. |
| The editor … didn't take the text | Click the editor, then try `type`; if it still fails, report it. |
| Step N: … Nothing ran. | One batch step was malformed; nothing happened. Fix that step and send the batch again. |
| Stopped at step N of M | The steps before N ran; the rest didn't. Look at the change list, fix the cause, and continue from step N. |
| The batch ran out of time | Fewer steps per batch, or a `wait_for` with a shorter timeout. |
| close only closes tabs this job opened | That tab is the user's (or another job's). Leave it open. |
| belongs to another OpenClicky job | Leave that tab alone and open your own. |
| keep needs why | Pass `why: "result"` or `why: "waiting"`. |
| Not saved: only a job's screenshots are kept in its folder | The screenshot came back but wasn't saved; describe what it shows instead. |
| There is no tab … / No tab is focused | Call `tabs` and use a listed id. |
| Only http(s) pages can be opened / can't work inside … pages | Browser settings, extension and file pages are off limits. Use an http(s) URL. |
| doesn't work in private windows | Use a normal window's tab. |
| The page didn't finish loading / is showing an error page | Check the URL; try once more; then report the site as unreachable. |
| Waited … never appeared | Read the page: the text may differ from what you expected, or the action didn't happen. |
| The screenshot is too large to send | Use `snapshot` or `extract` instead. |
| Unsupported browser operation | Use one of: status, tabs, open, navigate, read, snapshot, extract, click, fill, type, select, scroll, press, back, wait_for, batch, screenshot, close, keep. |
