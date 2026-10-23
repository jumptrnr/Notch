# Notch

A macOS menu-bar companion that lives in the MacBook notch. Hover it to expand. It shows Now
Playing with lyrics, surfaces verification codes from your inbox, and holds a drop shelf for files.

## Build and install

Requires macOS 14 or later and Xcode's Swift toolchain.

```
./run.sh
```

This builds the package in release mode, wraps the binary in `Notch.app`, signs it, installs it
into `/Applications` (replacing the copy there) and launches it. The login item follows the
installed copy. Set `INSTALL_DIR` to install somewhere else.

By default the bundle is ad-hoc signed. Set `CODESIGN_IDENTITY` to a certificate name from
`security find-identity -v -p codesigning` to sign with it instead, so macOS treats each rebuild
as the same app for Automation and Local Network permissions:

```
CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./run.sh
```

To make it stick, put that line in a `run.local` file next to `run.sh` (gitignored); `run.sh` sources it.

## Now Playing sources

Notch polls every enabled source every two seconds and shows whichever one is playing. If nothing
is playing anywhere, it shows a paused source. Play, pause, skip and scrubbing go to the source
being shown. The caption under the artist names it.

| Source | What it covers | Setup |
| --- | --- | --- |
| Spotify account | Anything the account plays on any device: Sonos, phone, desktop | Connect in Settings (below) |
| Sonos | Music started from the Sonos app on any speaker on your network | Switch on in Settings |
| Local app | The Spotify or Music app on this Mac, via AppleScript | Allow the Automation prompt |

### Spotify account

Spotify's Web API only hands out tokens to a registered app, so you create one once:

1. Open the [Spotify developer dashboard](https://developer.spotify.com/dashboard) and click
   **Create app**. Any name and description.
2. Under **Redirect URIs** add exactly `http://127.0.0.1:47391/callback` and click Add. Tick
   **Web API**. Save.
3. Copy the app's **Client ID** from its settings page.
4. Right-click the notch, choose **Settings…**, paste the Client ID, and click **Connect Spotify**.
   Your browser opens Spotify's consent page; approve it.

The sign-in uses Authorization Code with PKCE, so there is no client secret. Notch opens the
consent page in your default browser and catches the redirect on a short-lived listener bound to
127.0.0.1. Only a refresh token is kept, in an owner-only file under
`~/Library/Application Support/Notch/`. It is not placed in the Keychain because the Keychain
re-prompts for your login password every time a side-loaded binary changes.

Reading what is playing works on any account. Play, pause, skip and seek through the API require
Spotify Premium; Spotify answers 403 otherwise and Settings shows the reason.

Spotify Connect sessions on a Sonos speaker show up through this source. Music started from the
Sonos app does not, because the speaker streams Spotify directly and the account never sees it.
That is what the Sonos source is for. When both report the same track, which happens for a queue
Notch itself started through the account linked in the Sonos app, the Sonos source is shown, so
the queue, rooms and volumes are at hand.

### Sonos

Notch finds speakers with one SSDP search, then reads the zone-group topology from the first
speaker that answers. Only group coordinators are polled, since the other members of a group or
stereo pair carry no transport state. Transport commands go to the coordinator of the group being
shown.

macOS asks once whether Notch may find devices on the local network. If you decline, enable it
under System Settings › Privacy & Security › Local Network. Settings lists the groups found and
has a Scan Again button. The Sonos source is off until you switch it on there.

Home-theatre inputs and Spotify Connect sessions are skipped by this source, since Sonos exposes
no track metadata for them over polling.

**Speakers and volume.** While music is on Sonos speakers, whether started from the Sonos app or
as a Spotify Connect session on a room, the chip under the progress bar names the group ("Living
Room + 2 · Sonos", "Family Room · Spotify"). Click it and a panel opens in the lyrics panel's
slot, laid out like the Sonos app's room picker: a Group slider that scales every room together,
then every room in the house with a tick. The group's rooms are ticked and carry a mute button, a
volume slider and their level; the rest sit below, with the group they are in if they're playing
elsewhere. Tick a room to pull it in, untick it to split it off. Unticking the room doing the
streaming (marked with a small waveform) hands the music to another room in the group first, as
the Sonos app does; the last room can't be unticked. Ticks apply at once and the speakers' own
topology replaces them a moment later. Volume is read from the speakers only while the panel is
open. The same list sits behind the "Play on" chip in the library, where clicking the name of a
room outside the group switches to that room's group instead.

**Queue.** While a Sonos group is what's showing, a numbered-list button sits beside the lyrics
button. It opens the group's queue in the same slot: every song with the one playing marked and
kept in view; click any other to play from there. The list is read while the panel is open and
again when the track number runs past what was listed. If the group is on a radio stream rather
than its queue, the header says so. Starting a made playlist opens the queue by itself.

**Starting music.** The list button at the bottom right opens the library; with nothing playing,
the Now Playing tab shows the first few My Sonos items as tiles and a Browse all tile instead.
The library has a search field, filter chips (My Sonos is everything starred in the Sonos app;
Sonos playlists; the connected Spotify account's playlists) and a grid of artwork. Pick a group
in the speaker chip and click a tile; it loads into that group's queue and plays, exactly as the
Sonos app would start it. Spotify playlists start through the Spotify account linked in the
Sonos app, so they need neither Spotify Connect nor Premium; listing them does need the playlist
scopes, which Notch asks for at connect time, so a Spotify connection made with an older build
has to be redone in Settings for the Spotify chip to appear.

**Making a playlist.** Type a description into the library's search field ("johnny marr plays
guitar") and press Return, or click the Make a playlist row. Notch sends the prompt to the
playlist service at play.lysne.com, which asks an AI for songs and confirms each on Spotify;
songs appear as they are found, then Play loads them into the chosen group's queue through
the Spotify account linked in the Sonos app. Nothing is written to Spotify. The service limits
each address to a few playlists a day; a key issued for the app, saved in an owner-only file
`playlist-generate-key` next to the Spotify token, is sent as `X-Generate-Key` for a larger
allowance. Sonos doesn't publish the linked Spotify account's number, so Notch reads it off a
starred Spotify item: star any Spotify playlist or album in the Sonos app once.

Settings is the gear at the right of the tab bar, and also in the right-click menu. Its Notch
section has a text size setting (Default, Larger, Largest); every font in the panel scales with
it and the panel grows to match. It is remembered.

## Plug-ins

Tabs that only some users have live under `Sources/NotchApp/Plugins/`. A plug-in is one class
adopting `NotchPlugin`: it says whether it is configured, and supplies a settings section and a
tab. It can also supply the tab's label, for a reading that belongs in the bar. Until it is set up in Settings its tab doesn't exist, so everyone else sees the same three
tabs as before. To add one, write the class and append it to the list in `AppDelegate`.

Plug-in tabs get the tall panel (the height the lyrics panel opens to). The notch tells each
configured plug-in when it opens, which is the moment to refresh anything stale; nothing is
fetched for a shut panel.

### WindSensei

Favourite kiting spots from a [WindSensei](https://windsensei.com) account, laid out like its
Mac app. The first favourite gets a card: the wind large in the grade's colour with the gust
beside it, direction in degrees and compass points, temperature, the grade word and when the
block ends, tomorrow's best block, and the session window as a bar per hour coloured by the
server's grade with the gust above it, the hour under way outlined, and each hour's direction.
Each other favourite is a row with the same reading and a thumbnail of its window. The station's
reading is shown while it is fresh, named and aged, amber once it goes stale; otherwise this
hour's forecast with a tilde. Once today's window has passed the strip shows tomorrow's.

Create an API key under Dashboard › Profile on windsensei.com, paste it into the WindSensei
section of Settings, and a Wind tab appears. Its label is the first spot's wind as the WindSensei
menu bar item shows it: a disc in the grade's colour when it's rideable, then speed and compass
direction ("10 ENE"), from the station while its reading is fresh and from the forecast after. The key goes in an owner-only file next to the
Spotify token and is sent as `X-API-Key` to the widget endpoint. Data refreshes every 15 minutes
and when the notch opens on data older than five minutes. Wind is in knots.

## Lyrics

Time-synced lyrics come from [LRCLIB](https://lrclib.net), a keyless community API, requested per
track. Toggle the panel with the note button above play.

## Verification codes

Settings takes an iCloud or Gmail address with an app-specific password. Notch reads the inbox
over IMAP, extracts verification codes from new mail, and shows them in the Codes tab, optionally
copying each new one to the clipboard. Passwords are stored in the Keychain.

## Diagnostics

Source selection, Spotify sign-in, Sonos topology and command failures are written to the unified
log under one subsystem:

```
/usr/bin/log show --last 5m --predicate 'subsystem == "com.robin.notch"' --style compact
```

Each change in what the notch shows is logged, so a "Nothing playing" is explained there.
