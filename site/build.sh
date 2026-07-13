#!/bin/bash
#
# Builds the deployable site from src/ templates.
# The product name lives HERE and nowhere else — change it once, rebuild,
# and every page, meta tag, and FAQ answer follows.
#
# Usage:  ./build.sh   (then `vercel deploy --prod` to ship)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Besties"

# index.html = head wrapper + templated landing page body
{
cat <<HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${APP_NAME} — a time machine for your messages</title>
<meta name="description" content="${APP_NAME} turns your iMessage and WhatsApp history into a timeline you can travel. Scrub to any month of your life, see who you were closest to, and drop into the exact conversation. 100% private — nothing ever leaves your Mac.">
<meta property="og:title" content="${APP_NAME} — a time machine for your messages">
<meta property="og:description" content="Scrub back through years of iMessage and WhatsApp. See who mattered, jump to any moment, read it like it was. Entirely on-device.">
<meta property="og:image" content="https://time-capsule-one-liart.vercel.app/icon.png">
<meta name="color-scheme" content="light">
<link rel="icon" type="image/png" href="/icon.png">
<link rel="apple-touch-icon" href="/icon.png">
</head>
<body>
HEAD
sed -e "s/__APP_NAME__/${APP_NAME}/g" -e '/^<title>/d' src/landing.html
printf '</body>\n</html>\n'
} > index.html

# thanks.html is a complete page; just substitute the name
sed "s/__APP_NAME__/${APP_NAME}/g" src/thanks.html > thanks.html

echo "✅ Built index.html + thanks.html as ${APP_NAME}"
