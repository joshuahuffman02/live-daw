# Planning Center Scene Driving

AutoMix Native reads the order of service from Planning Center Services and maps
recognized plan items onto the existing native `MixScene` transition path. It does not
control audio directly from a network callback: the app fetches and parses the plan off
the realtime thread, then applies a scene through the same smoothed 1–2 second targets
used by operator scene changes.

## Credentials

For a single-organization appliance, create a Planning Center Personal Access Token at
<https://api.planningcenteronline.com/oauth/applications>. Enter its application ID and
secret in **Planning Center Scenes**. The secret is stored as a
`ThisDeviceOnly` macOS Keychain generic password; the venue profile stores only the
selected service-type ID and follow-mode preference.

Do not place the token in the venue profile, a service-proof bundle, shell history, or
the checked-in browser environment. Use a dedicated Planning Center user with only the
permissions required to read the applicable Services plans.

## Selection and mapping

- A configured service-type ID is used when present; otherwise the first visible
  service type is selected and its ID is saved in the venue profile.
- The next future plan is selected. If none is available, the most recent visible plan
  is used.
- Plan items are loaded in order with their included `item_times`.
- `service_position=pre` maps to **Pre-service** and `service_position=post` maps to
  **Post-service**, even if the title also contains “song” or “music.”
- Song/worship/praise titles map to **Worship**.
- Message/sermon/teaching/scripture/welcome/announcement/offering titles map to
  **Sermon**.
- Prayer/intercession/altar/response/communion titles map to **Prayer**.
- Unrecognized headers, notes, and technical items are ignored.

Automatic cue timing uses each non-excluded Planning Center
`ItemTime.live_start_at`. Items without a live start time remain available as manual
Previous/Next cues but do not drive timed changes.

## Rehearsal gate

1. Refresh the plan and confirm the service type, plan title, cue order, scene mapping,
   and displayed cue times.
2. Leave **Follow timed plan cues** disabled and step through every cue with
   **Previous** / **Next** while the engine is in SHADOW.
3. Confirm every candidate transition is appropriate. Rename ambiguous Planning Center
   items or keep those transitions manual.
4. Enable timed following in SHADOW and run the full service clock once.
5. Only enable live automation after the normal staged-rollout acceptance criteria
   pass. Planning Center connectivity is not a substitute for SAFE, FREEZE, or a human
   operator.

The native app refreshes the plan every five minutes. On network, authentication, or
parse failure it holds the current scene, logs a warning incident, and retries after
one minute. It never stops or restarts the audio engine because Planning Center is
unavailable.
