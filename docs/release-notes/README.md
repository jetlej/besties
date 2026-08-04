# Release notes

One HTML fragment per release, named `<marketing-version>.html` (e.g. `1.1.html`) — no DOCTYPE or `<body>`, just a short `<ul>` of what changed.

`release.sh` copies the matching file next to the update zip so `generate_appcast` embeds it as the release notes Sparkle shows in the update dialog. Missing file = the release ships with no notes (the script warns but continues).
