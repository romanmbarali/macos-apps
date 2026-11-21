#!/bin/sh
# Lancé une seule fois en administrateur : autorise « pmset disablesleep 0/1 » sans mot de passe
# pour l'utilisateur donné (et rien d'autre).
set -e
U="$1"; [ -n "$U" ] || exit 1
T=$(mktemp)
echo "$U ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > "$T"
/usr/sbin/visudo -cf "$T" >/dev/null
/usr/bin/install -m 0440 -o root -g wheel "$T" /etc/sudoers.d/eveille
rm -f "$T"
