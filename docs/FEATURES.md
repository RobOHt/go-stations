# Features in detail

What GO Stations does, screen by screen. For the short version, see the
[README](../README.md); for how it's built, [ARCHITECTURE.md](ARCHITECTURE.md).

The app runs on iOS 18 and later, in Liquid Glass from iOS 26; on iOS 18 the
controls are frosted, as iOS drew them then. (The Xcode project and target are
named `Departures`; the app shows up as **GO Stations** on your home screen.)
Trains only for now.

- [The map](#the-map)
- [Search, and getting somewhere](#search-and-getting-somewhere)
- [A station's board](#a-stations-board)
- [Opening to the right board](#opening-to-the-right-board)
- [Any day this week](#any-day-this-week)
- [Tracking a train](#tracking-a-train)
- [Alerts](#alerts)
- [Every train at once](#every-train-at-once)
- [Privacy](#privacy)

## The map

Apple Maps with every GO rail line drawn thick in its official colour, and every
station a dot with a pin standing on it, its name on a tag you tap to open it
(home and work in blue and brown).

Where the stations crowd together, the ones that matter most keep their pins: the
one you have open, home, work, Union, then where lines meet and end, then the
stations the most trains stop at. Pins are laid out for the whole network at each
zoom, so they stay put as the map moves, coming on and off the screen with it like
the map's own names, and change only as you zoom in or out, open a station, or
move. They sit above the trains so a passing train never hides a name, and make way
for your location: standing at a station, its pin hangs below the dot instead.

Every change animates: pins pop up out of their dots and sink back in, slide aside
with their point staying on the dot, and fade to a new look as you zoom or open a
station; a pin keeps its side of the dot while it still fits there.

## Search, and getting somewhere

Type a station or a place (anything Apple Maps finds) and pick it. A station opens
its board, as on the map, with *Get here* in its bar at the bottom (left out when
you're at the station or it's the one nearest you).

*Get here*, a place, or a recent trip opens a card that shows how to get there by
train, starting from the station you'd get there soonest from (on foot if one is
within a 10-minute walk, otherwise by car, counting 5 minutes a change), or one you
pick, with a week strip to plan another day. Today, near enough to set off, it
offers the trip you'd make: "This trip will get you to Union Station in 1 h 5 min",
track it or not.

Below it, the day's trips, changes and all (up to two), each with its trains, how
long to change, and for a place the walk at the end. Trips that leave earlier but
get you there no sooner are left out, and today's go round trains GO has cancelled
(or that won't stop where you'd get on or off). The map draws the trip you open in
its lines' colours over the dimmed network, with its stations' names. Opened from a
board, the card has a button back to it. Where you planned trips to lately is
listed when you start typing.

## A station's board

A native bottom sheet opens with the departure screen as it looks in the station:
the same bilingual title, the Scheduled · Line · Platform headings as on GO's
departures page, colours, line badges, ⚡ express marker, platform numbers with ♿,
red cancellations, and Union's countdown to each train's platform, short as on
GO's own departures page ("29m", "-" for a train over an hour away).

It's adapted for portrait so nothing scrolls sideways: each train's stops go on one
line under where it's going, in a quieter grey so the time, line and platform stand
out, and the board starts right under the station's name, so the next few trains
show at half height.

With your home or work set, every board can show just the trains going your way:
*Toward work*, *Toward home* or *All directions*, picked from a menu in its bar.
Your home board starts out toward work and your work board toward home; a station
on the way between them toward work on weekday mornings and toward home otherwise
(afternoons, evenings, weekends); any other station, all directions.

The day, which way, and *Get here* sit in a bar at the bottom, where thumbs are:
the day on the left, which way and *Get here* on the right, each in its own glass
where iOS puts a toolbar's items (in from the screen's rounded corners), with the
board scrolling under them through the soft scroll edge. The bar stays put as the
sheet goes to full height and back.

When live data isn't available, the board shows the timetable's trains and says
so ("Scheduled times, not live: no delays or platforms"), with why.

## Opening to the right board

Set a home and a work station. On launch the app opens the board you most likely
want, worked out on the phone from the timetable, so it's instant:

- at home or work (within 1 km of the station), that station;
- on a train of your commute (judged from where the timetable puts the trains),
  where you get off it: the next station where you change (even going past home or
  work on the way there), or on the last train, home or work;
- near home or work otherwise, that station;
- anywhere else, the station you'd get home from soonest (on weekday mornings, to
  work), on foot if one is within a 10-minute walk, otherwise by car.

With neither set, it opens the nearest station (up to 25 km away), and a hint on
the board says how to make it home or work.

## Any day this week

The day button in each board's bottom bar has today and the next seven days: pick
one for that day's trains, all day, as timetabled. The day stays picked for every
board you open after it, until you tap Today (or come back to the app later).
Today's board runs on past the live trains to the rest of the day's. A day with
more than ten trains can narrow to its morning (to 11:00), noon (to 14:00) or
afternoon (to the last train), in the same menu.

## Tracking a train

Tap *Track this train* on a train's stops. It moves along its line on the map where
it really is, with a pointer showing which way it's going (one pin with your
location when you're on it), a button bottom left opens it again, and a Live
Activity on the Lock Screen and in the Dynamic Island counts down to its next stop,
with the stops either side of it.

Tracked from your station's board, it first counts down to the train getting to
you ("Your Lakeshore East line 08:12 westbound train to Union Station will arrive
in 6 minutes"). "Arrived" shows while the train actually stands at a station, from
when it's seen pulling in to when it's seen leaving, and the stops ahead are as late
as the train runs.

A train's stops show how fast it's going: the speed the map draws it moving at.
Running late, they say how late beside which way it goes ("25 min late") and each
stop's new time, kept current while they're open (to the end of its run, where
Metrolinx leaves the time blank), with GO's disruptions on its line after them
("Signal issue near Port Credit GO"), as on a station's board.

With push set up (see [SETUP.md](SETUP.md)), the Worker follows the train while it
runs and pushes the Live Activity an update when it pulls in at a stop or leaves
one, so it keeps up with the app closed. A trip tracked from search follows the
whole trip in one Live Activity: where to change and to which train, then the next
train once you're there.

When GO cancels the train (or it won't stop where you get on or off), the Live
Activity says *Cancelled* in place of the countdown, with the next train from your
station to your stop once the app finds one, and you're told (unless you asked not
to be): by the Worker with the Live Activity when the app is closed. It goes back to
normal if GO puts the train back on, and ends a few minutes after the train was
due. On a trip with changes, the train you'd change to is looked up too: cancelled
(or not stopping where you change to it or get off it), the Live Activity's change
line says so ("Your 08:10 from Union is cancelled"), you're told before you get
there, and the trip card offers *Plan another way*: the trips from where you
change, after you get there.

## Alerts

Tracking a trip asks whether you want to be told: 5 minutes before your train
leaves if you're not at the station yet (taken back once you get there, which needs
Always location), and 5 minutes before you change and before your stop (sent by the
Worker with the Live Activity, timed by where the train really is; scheduled on the
phone by the timetable when it can't). Once you've said yes, trains tracked from a
board get them too.

## Every train at once

The map shows every train running now moving along its line (turn off *Show all
trains* in Settings for just the one you track), from GO's live train positions
(the timetable when those aren't available). Trains fade in as they set off and
fade out a minute after their last stop. Tap one for its stops.

## Privacy

No accounts, no ads, no analytics. Home and work sync through iCloud key-value
storage. Live data comes from Metrolinx through a small Cloudflare Worker that
holds the API key, so nothing secret ships in the app. The Worker keeps a tracked
trip's push token and stop times only until the trip ends.
