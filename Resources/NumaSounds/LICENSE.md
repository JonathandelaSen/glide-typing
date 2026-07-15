# Numa sound assets — provenance and license

The eight AIFF files in this directory are original procedural sounds generated
by `Tools/NumaSounds/generate.py`. They do not contain samples copied from
macOS, Siri, commercial sound libraries, recordings, speech or third-party
works.

Copyright (c) 2026 Jonathan de la Sen.

The generated audio assets are dedicated to the public domain under
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).
The generator source follows the repository's source-code license.

Generation contract:

- mono PCM16 big-endian AIFF;
- 16 kHz;
- activation duration no longer than 250 ms;
- finish duration no longer than 500 ms;
- byte-for-byte deterministic for a given generator revision;
- activation and finish are distinct for every theme.
