#!/usr/bin/env bash

set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo $0 <admin_user> <user2> <user3>"; exit 1; }
[ $# -eq 3 ]      || { echo "Usage: sudo $0 <admin_user> <user2> <user3>"; exit 1; }

USERS=("$@"); ADMIN="$1"
GROUP=devteam
SHARED=/shared/project
TEMP_PASS='Welcome@123'
REPORT="$PWD/verification.txt"

getent group "$GROUP" >/dev/null || groupadd "$GROUP"
for u in "${USERS[@]}"; do
  id "$u" &>/dev/null || useradd -m -d "/home/$u" -s /bin/bash -U "$u"
  usermod -aG "$GROUP" "$u"
  echo "$u:$TEMP_PASS" | chpasswd
  chage -M 60 -W 7 "$u"
done

F="/etc/sudoers.d/90-${ADMIN//./_}"
echo "$ADMIN ALL=(ALL) ALL" > "$F"
chmod 440 "$F"
visudo -cf "$F" >/dev/null || { rm -f "$F"; echo "sudoers syntax error"; exit 1; }

mkdir -p "$SHARED"; chmod 755 /shared
chown root:"$GROUP" "$SHARED"
chmod 3770 "$SHARED"

cat > /etc/profile.d/devteam-umask.sh <<'EOT'
case " $(id -Gn) " in *" devteam "*) umask 007 ;; esac
EOT

: > "$REPORT"
hdr()  { printf '\n===== %s =====\n' "$*" >> "$REPORT"; }
show() { { echo "# $*"; eval "$*" 2>&1 || true; echo; } >> "$REPORT"; }        # as root
run()  { local w=$1; shift; { echo "[$w]\$ $*"; su - "$w" -c "$*" 2>&1 || true; echo; } >> "$REPORT"; }  # real login as user

U1=${USERS[0]}; U2=${USERS[1]}; U3=${USERS[2]}

hdr "1. Users and group membership (id)"
for u in "${USERS[@]}"; do run "$u" id; done

hdr "2. Superuser access (sudo -l): only $ADMIN allowed"
show "ls -l $F; cat $F"
for u in "${USERS[@]}"; do show "sudo -l -U $u"; done

hdr "3. Shared folder permissions (ls -ld): expect drwxrws--T root devteam"
show "ls -ld $SHARED"

hdr "4. SGID + umask: $U1 creates a file (expect group devteam, mode -rw-rw----)"
for u in "${USERS[@]}"; do run "$u" umask; done
run "$U1" "echo 'created by $U1' > $SHARED/a.txt; ls -l $SHARED/a.txt"

hdr "5. Group-writable: $U2 edits $U1's file"
run "$U2" "echo 'edited by $U2' >> $SHARED/a.txt && cat $SHARED/a.txt"

hdr "6. Sticky bit: $U2 and $U3 cannot delete/rename $U1's file"
run "$U2" "rm $SHARED/a.txt"
run "$U3" "mv $SHARED/a.txt $SHARED/b.txt"
show "ls -l $SHARED"

hdr "7. Others are locked out (user 'nobody')"
show "runuser -u nobody -- ls $SHARED"

rm -f "$SHARED"/*

for u in "${USERS[@]}"; do chage -d 0 "$u"; done

hdr "8. Password policy (chage -l): max 60, warn 7, must change at first login"
for u in "${USERS[@]}"; do show "chage -l $u"; done

echo "Done. Verification saved to $REPORT"
