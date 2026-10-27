# Contributing to XP[d]

Thanks for wanting to help. XP[d] is a free, one-person hobby project, so
every change is reviewed by hand before it is merged. Small, focused pull
requests are the quickest to review.

## Before you start

- **Bugs:** open an issue first. Say your macOS version, your remote model
  (for example ACK05-B), cable or Bluetooth, what you did, what you expected
  and what happened.
- **New features:** open an issue to discuss the idea before writing code, so
  you don't spend time on something that may not fit.
- **Small fixes** (typos, clear bugs): a pull request on its own is fine.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Build and test on your Mac (macOS 14 or later, Swift 6):

   ```sh
   swift build
   swift test
   ```

3. To try the app itself, run `bash script/build_and_run.sh`.
4. Keep the change about one thing, and follow the style of the code around
   it. Add or update tests when behaviour changes.
5. Open a pull request against `main` and fill in the template.

GitHub runs the same build and tests automatically on every pull request.
For first-time contributors this starts only after the maintainer approves it.

## What will not be accepted

- XPPen's own driver, firmware or other files from XPPen. They are not ours to
  redistribute.
- New third-party dependencies without a strong reason (XP[d] has none today).
- Personal data: your key layouts, exported configurations, logs with
  personal information, or account details.
- Changes that disable a safety check, for example letting imported scripts
  run without approval, or letting "Open link or file" launch apps or scripts.
- Large rewrites or reformatting mixed into a fix.

## Review and merging

The maintainer reviews every pull request and may ask for changes, or decline
it if it does not fit the project. Please be patient; this is done in spare
time. Only the maintainer merges.

## Licence of contributions

XP[d] is released under the [PolyForm Noncommercial License 1.0.0](LICENSE).
By opening a pull request you confirm that:

- the work is your own (or you have the right to submit it), and
- your contribution is licensed under the same PolyForm Noncommercial
  License 1.0.0, like the rest of XP[d].

Your code stays yours. The original XP[d] code remains the maintainer's own
(dmssoftres). If XP[d] is ever offered under different terms, contributed code
will not be included without its author's permission; it will be removed or
rewritten from scratch instead. Git history keeps a record of who wrote what.

## Security problems

Please do not report security problems in a public issue. Use GitHub's
**Security › Report a vulnerability** on this repository instead.
