# Security

## Reporting a problem

Please report security problems privately, not in a public issue:

1. On the repository's **Security** tab, choose **Report a vulnerability**, and
   describe the problem and how to reproduce it.
2. If that option isn't there, open an issue titled "Security contact" with no
   details, and the maintainer will get in touch.

The maintainer will reply as soon as they can. Please allow a reasonable time for a
fix before saying anything in public.

## What's in scope

- **The Worker** (`worker/`): the Metrolinx proxy, `/v1/live/*`, `/v1/activity`,
  and the Durable Object that follows tracked trains. For example: a way to get the
  Metrolinx or Apple push keys, to send pushes to someone else's Live Activity, to
  read another rider's tracked trip, or to get around the rate limits.
- **The app**: anything that exposes a rider's data (home and work stations,
  location, push tokens) or runs code it shouldn't.
- **The workflows**: anything that could leak a repository secret.

Metrolinx's own API and data are out of scope; report problems there to Metrolinx.

## Keys and personal data

The repository never holds keys or anyone's personal data (see
[CONTRIBUTING.md](CONTRIBUTING.md)). If you find either in the code, its history,
an issue or a workflow log, report it as above, and don't repeat it in the report:
say where it is.
