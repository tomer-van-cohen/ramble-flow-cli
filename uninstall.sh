#!/bin/bash
# Same as ./install.sh --uninstall. Never touches recordings or transcripts.
exec "$(dirname "$0")/install.sh" --uninstall "$@"
