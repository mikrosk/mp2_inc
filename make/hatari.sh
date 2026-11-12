#!/bin/sh
# Build decoder.dsp and mp2inc.bin in Hatari via hatari-falcon.sh.
# The project directory becomes drive C: and TOMSHELL.TOS is started
# automatically; it runs TOMSHELL.TOM. Close Hatari once TomShell has
# finished. Extra arguments are passed to Hatari.
set -e
cd "$(dirname "$0")/.."
hatari-falcon.sh --harddrive "$PWD" --gemdos-case lower \
	--auto 'C:\TOMSHELL.TOS' "$@"
