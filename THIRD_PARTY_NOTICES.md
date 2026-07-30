# Third-party notices

## rclone

Nafi can bundle rclone 1.74.4 as its remote communications engine.

Copyright (C) 2012 by Nick Craig-Wood http://www.craig-wood.com/nick/

Licensed under the MIT License. The full license text is regenerated at build time from rclone's COPYING into `Vendor/rclone/LICENSE.rclone.txt` and is embedded in the built app as `Contents/Resources/LICENSE.rclone.txt`.

rclone is a separate executable. Nafi communicates with it through rclone's documented Remote
Control HTTP API on a loopback-only endpoint protected by random per-launch credentials.
