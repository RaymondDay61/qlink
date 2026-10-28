# Q-Link Reloaded

**This fork adds C64 file uploads and downloads to the Q-Link Reloaded server.** Users on a real Commodore 64 (or C64 Ultimate, or VICE) running the original QuantumLink disk can:

- **Download** files from the software libraries (select a file, press **F7**).
- **Upload** files from their own disk into a library, using the original "Submit a New File" flow.
- **Comment** on files (comments are stored as replies to the file).

Tested October 2026 on a Raspberry Pi (Raspberry Pi OS Bookworm, OpenJDK 17, MariaDB 10.11) with a C64 Ultimate and with VICE 3.x.

## Quick setup on a Raspberry Pi / Debian

```
sudo apt install -y git default-jdk maven mariadb-server
sudo git clone -b upload-download https://github.com/RaymondDay61/qlink.git /opt/qlink
cd /opt/qlink
sudo mvn -q install:install-file -Dfile=./lib/martyr-1.0.jar -DgroupId=f00f.net.irc \
     -DartifactId=martyr -Dversion=1.0 -Dpackaging=jar -DgeneratePom=true
sudo mvn -q clean package
sudo ./bootstrap          # creates the qlink database (WARNING: wipes an existing one)
java -jar target/qlink-0.1.0.jar
```

The server listens on port **5190**. `pom.xml` in this branch targets Java 8 so it builds with current JDKs (the original targeted Java 6, which modern JDKs can't compile for).

`scripts/install-upload.sh` is only needed to add upload support to an **unmodified** copy of the original project; this branch already includes it.

## Managing file libraries: `scripts/qlink-files.sh`

Run as root on the server. Copy it somewhere on your PATH, e.g. `/usr/local/bin/`.

| Command | What it does |
|---|---|
| `qlink-files.sh list [menu_id]` | Show a menu's contents (default 500 = "Browse C64 Software") |
| `qlink-files.sh addmenu <parent_id> "Title"` | Create a library folder |
| `qlink-files.sh add <menu_id> file.prg "Title" "Description"` | Add a `.prg` or `.seq` file as a download |
| `qlink-files.sh remove <id>` | Remove a file or an empty folder |
| `qlink-files.sh comments <id>` | Show comments posted on a file |
| `qlink-files.sh export <id> [outfile]` | Save a file back out of the database |

New items get IDs from 7000000 up, away from the original Q-Link IDs.

### Letting users upload into a folder

Add a "Submit a New File" item (menu entry type 141 / `0x8D`) to any folder. Uploaded files appear in that same folder. Example for folder 7000000 (pick an unused ID for the item):

```
mysql -uroot qlink -e "INSERT INTO entry_types (reference_id,entry_type,cost,create_date,last_update) VALUES (7000500,141,'NOCHARGE',NOW(),NOW()); INSERT INTO toc (menu_id,reference_id,title,sort_order,active,create_date,last_update) VALUES (7000000,7000500,'Submit a New File',1,'Y',NOW(),NOW());"
```

## Uploading from the C64

1. Use a **1541 disk image (`.d64`) on a 1541 drive**. The Q-Link client searches the 1541 directory track directly, so **uploads fail with "The specified file is not on the disk" on a `.d81`/1581** even though Q-Link itself runs fine from one.
2. Put the program you want to upload on the disk in drive 8 (on a PC, VICE's `c1541 QuantumLink.d64 -write game.prg game`).
3. In a library folder, choose **Submit a New File**, type the file name **exactly as in the directory, in lowercase**, then type a description and finish it.
4. Q-Link searches the disk, waits for verification, sends the file and reports **"The file has been sent to Q-Link."**

## Connecting with VICE (3.x)

- **Settings → Peripheral devices → RS232**: tick *Enable userport RS232 emulation*, Device *Serial 1*, Baud *1200*; set **Serial 1** to `your-server-ip:5190` with Baud 1200 and *IP232 unticked*.
- **Userport devices**: *Userport RS232/Modem*.
- Attach `QuantumLink.d64` to drive 8 (1541). In Q-Link's modem setup choose *Other command driven modems*, 1200 baud, **Dial: Manual**, then just press **F1** at "Type commands to modem".

## How the upload protocol works (for developers)

Worked out from the client's command tables, a memory snapshot of the running client and server logs:

| Step | Direction | Command | Meaning |
|---|---|---|---|
| 1 | C64 → server | `K5` | Post request on a type `0x8D` menu item; parameter includes the typed file name |
| 2 | server → C64 | `KH` | Enter the text editor for the description |
| 3 | C64 → server | `K6` … `KL` | Description lines; first line has the header `FILE: <name> FROM: <handle> …`; `KL` = last line |
| 4 | server → C64 | `KR` | Ready; the parameter is displayed as the **S#** (we send the new file's ID) |
| 5 | C64 | (`SS`/`SG`) | Client suspends the link, its disk helper (overlay `0208`) searches drive 8, then resumes |
| 6 | C64 → server | `FO` | Asks the host to verify ("Please wait for verification") |
| 7 | server → C64 | `FD` | Go-ahead; client then loads and sends the file |
| 8 | C64 → server | `F2` … `F3` | File data blocks; `F3` = last block. Bytes are escaped like downloads: `0x5D` followed by (byte XOR `0x55`) |

The server code is in `src/main/java/org/jbrain/qlink/state/UploadFile.java` (state machine and saving into the `files`/`toc`/`entry_types` tables), with the new commands in `cmd/action/Upload*.java` and `ReadyForUpload.java`. For experiments, `/opt/qlink/upload-kr.txt` (`id`/`name`/`none`/literal) and `/opt/qlink/upload-verify.txt` (`MNEMONIC parameter`) override the `KR` and verify replies without rebuilding.

Uploads are published immediately (the original service reviewed them first).

## Credits

Q-Link Reloaded server by Jim Brain and contributors ([ssalevan/qlink](https://github.com/ssalevan/qlink)), GPL v2. Upload support, library tool and Raspberry Pi notes added by RaymondDay61.

---

# Original deployment instructions

## Deployment instructions

These have only really been tested on Ubuntu 14.04, but they should generalize readily to other environments.

### Step 1: Install prerequisites

On Ubuntu, you can do this with the command

```
apt-get install openjdk-7-jdk maven mysql-server nodejs
```

Elsewhere, you will need:

 * A Java development kit
 * Maven installed
 * MySQL installed and running with default configuration
 * node.js installed

### Step 2: Configure database

There are two SQL files that will set up the "qlink" database the server needs. The "bootstrap" script will run them both. **WARNING!** Running this script will *delete any previous database* and as such will invalidate any QLink disks you were using to connect to it.

### Step 3: Build

There's a "package" script that does this, or you can just type

```
mvn package
```

### Step 4: Run

There's a "run" script, or you can also fire up the executable jar file produced in the "target" directory.

If you want to play with the "wafer-thin" Habitat proxy, you will need to first run

```
nodejs src/fake_server/wafer.js
```

### Step 5: Connect with QLink!

You're now running Q-Link Reloaded listening on port 5190. You should be able to point your Commodore 64 client at that port and then do your normal Q-Link connection techniques.
