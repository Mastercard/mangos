#!/bin/bash
(git ls-tree -r HEAD --name-only ; echo mkosi.images/initrd/mkosi.extra/usr/lib/mangos/mangos-install) | grep '\.sh$' | xargs shellcheck -s bash
