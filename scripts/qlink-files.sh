#!/bin/bash
# qlink-files.sh - manage Q-Link Reloaded download libraries from the command line
# Run as root on the Q-Link Pi.
#
#   qlink-files.sh list [menu_id]                       show what's in a menu (default 500 = Browse C64 Software)
#   qlink-files.sh addmenu <parent_menu_id> "Title"     make a new library folder
#   qlink-files.sh add <menu_id> <file> "Title" ["Description"]   add a .prg or .seq file
#   qlink-files.sh remove <id>                          remove a file or empty folder
#   qlink-files.sh comments <id>                        show comments people posted on a file
#   qlink-files.sh export <id> [outfile]                save a file back out of the database

set -e
DB="mysql -uroot qlink"
ID_START=7000000      # our own number range, well away from the original Q-Link IDs
ID_MAX=8388607        # 0x7FFFFF, highest ID the server uses

esc() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g"; }

next_id() {
    $DB -N -e "SELECT GREATEST($ID_START, IFNULL(MAX(reference_id),0)+1) FROM entry_types WHERE reference_id BETWEEN $ID_START AND $ID_MAX;"
}

type_name() {
    case "$1" in
        129) echo "folder";; 138) echo "download";; 130) echo "text";;
        131) echo "msgboard";; 132) echo "message";; *) echo "type$1";;
    esac
}

cmd="$1"; shift || true
case "$cmd" in
list)
    m="${1:-500}"
    echo "Menu $m: $($DB -N -e "SELECT title FROM toc WHERE reference_id=$m LIMIT 1;")"
    echo "-------------------------------------------------------------"
    $DB -N -e "SELECT t.reference_id, e.entry_type, t.title,
                      IFNULL(LENGTH(f.data),''), IFNULL(f.name,''),
                      (SELECT COUNT(*) FROM messages WHERE parent_id=t.reference_id)
               FROM toc t JOIN entry_types e ON e.reference_id=t.reference_id
               LEFT JOIN files f ON f.reference_id=t.reference_id
               WHERE t.menu_id=$m AND t.active='Y' ORDER BY t.sort_order, t.toc_id;" |
    while IFS=$'\t' read -r id et title size name ncom; do
        tn=$(type_name "$et")
        extra=""
        [ "$tn" = "download" ] && extra="  [$name, $size bytes, $ncom comments]"
        printf "%8s  %-9s %s%s\n" "$id" "$tn" "$title" "$extra"
    done
    ;;

addmenu)
    parent="$1"; title="$2"
    [ -n "$parent" ] && [ -n "$title" ] || { echo "usage: $0 addmenu <parent_menu_id> \"Title\""; exit 1; }
    [ ${#title} -le 40 ] || { echo "Title must be 40 characters or less."; exit 1; }
    id=$(next_id)
    $DB -e "INSERT INTO entry_types (reference_id, entry_type, cost, create_date, last_update)
              VALUES ($id, 129, 'NOCHARGE', NOW(), NOW());
            INSERT INTO toc (menu_id, reference_id, title, sort_order, active, create_date, last_update)
              VALUES ($parent, $id, '$(esc "$title")', 1, 'Y', NOW(), NOW());"
    echo "Created folder \"$title\" with ID $id inside menu $parent."
    echo "Add files to it with:  $0 add $id myfile.prg \"Title\" \"Description\""
    ;;

add)
    menu="$1"; file="$2"; title="$3"; desc="${4:-$3}"
    [ -n "$menu" ] && [ -f "$file" ] && [ -n "$title" ] || {
        echo "usage: $0 add <menu_id> <file.prg|file.seq> \"Title\" [\"Description\"]"; exit 1; }
    [ ${#title} -le 40 ] || { echo "Title must be 40 characters or less."; exit 1; }
    base=$(basename "$file" | tr 'A-Z' 'a-z')
    case "$base" in *.seq) ftype=seq;; *) ftype=prg;; esac
    name="${base:0:16}"
    size=$(stat -c %s "$file")
    [ "$size" -gt 0 ] || { echo "File is empty."; exit 1; }
    if [ "$ftype" = prg ]; then
        la=$(od -An -N2 -tu2 "$file" | tr -d ' ')
        echo "Load address: \$$(printf '%04X' "$la")  (a normal BASIC program is \$0801)"
    fi
    id=$(next_id)
    tmp=$(mktemp)
    {
        echo "INSERT INTO entry_types (reference_id, entry_type, cost, create_date, last_update)"
        echo "  VALUES ($id, 138, 'NOCHARGE', NOW(), NOW());"
        echo "INSERT INTO toc (menu_id, reference_id, title, sort_order, active, create_date, last_update)"
        echo "  VALUES ($menu, $id, '$(esc "$title")', 1, 'Y', NOW(), NOW());"
        printf "INSERT INTO files (reference_id, name, filetype, description, data) VALUES (%s, '%s', '%s', '%s', 0x" \
            "$id" "$(esc "$name")" "$ftype" "$(esc "$desc")"
        od -An -v -tx1 "$file" | tr -d ' \n'
        echo ");"
    } > "$tmp"
    $DB < "$tmp"
    rm -f "$tmp"
    echo "Added \"$title\" ($name, $ftype, $size bytes) as ID $id in menu $menu."
    ;;

remove)
    id="$1"; [ -n "$id" ] || { echo "usage: $0 remove <id>"; exit 1; }
    kids=$($DB -N -e "SELECT COUNT(*) FROM toc WHERE menu_id=$id;")
    [ "$kids" -eq 0 ] || { echo "ID $id still has $kids items in it. Remove those first."; exit 1; }
    $DB -e "DELETE FROM files WHERE reference_id=$id;
            DELETE FROM toc WHERE reference_id=$id;
            DELETE FROM entry_types WHERE reference_id=$id;"
    echo "Removed $id."
    ;;

comments)
    id="$1"; [ -n "$id" ] || { echo "usage: $0 comments <id>"; exit 1; }
    $DB -e "SELECT date, author, title, text FROM messages WHERE parent_id=$id ORDER BY date\G"
    ;;

export)
    id="$1"; out="$2"; [ -n "$id" ] || { echo "usage: $0 export <id> [outfile]"; exit 1; }
    [ -n "$out" ] || out=$($DB -N -e "SELECT name FROM files WHERE reference_id=$id;")
    $DB -N -e "SELECT HEX(data) FROM files WHERE reference_id=$id;" |
      python3 -c "import sys,binascii; sys.stdout.buffer.write(binascii.unhexlify(sys.stdin.read().strip()))" > "$out"
    echo "Saved $(stat -c %s "$out") bytes to $out"
    ;;

*)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
