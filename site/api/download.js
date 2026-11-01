// The app is free: send everyone straight to the current DMG (its path is an
// env var so new releases don't need a code change). Old purchase links —
// /api/download?session_id=… from past receipts — keep working; the query
// string is simply ignored.
module.exports = (req, res) => {
  res.redirect(302, process.env.DOWNLOAD_PATH);
};
