#!/bin/bash
# Adds C64 file UPLOAD support to Q-Link Reloaded in /opt/qlink, rebuilds, restarts.
# Run as root on the Pi:  bash install-upload.sh
# Undo:                   bash install-upload.sh undo
set -e
Q=${QLINK_DIR:-/opt/qlink}
J=$Q/src/main/java/org/jbrain/qlink
JAR=$Q/target/qlink-0.1.0.jar

if [ "$1" = "undo" ]; then
    cp $JAR.before-upload $JAR && systemctl restart qlink && echo "Restored the server from before uploads were added."
    exit 0
fi

[ -f $JAR.before-upload ] || cp $JAR $JAR.before-upload
echo "==> Adding upload code"
cat > $J/cmd/action/ReadyForUpload.java <<'JAVA_EOF'
package org.jbrain.qlink.cmd.action;

/** KR from server: ready to receive the uploaded file. Parameter is copied by the client to $CE00. */
public class ReadyForUpload extends AbstractStringAction {
  public ReadyForUpload(String data) {
    super("KR", data);
  }
}
JAVA_EOF
cat > $J/cmd/action/UploadAbort.java <<'JAVA_EOF'
package org.jbrain.qlink.cmd.action;

import org.jbrain.qlink.cmd.CRCException;

/** FK: client canceled the upload. */
public class UploadAbort extends AbstractAction {
  public static final String MNEMONIC = "FK";

  public UploadAbort(byte[] data, int start, int len) throws CRCException {
    super(data, start, len);
  }
}
JAVA_EOF
cat > $J/cmd/action/UploadData.java <<'JAVA_EOF'
package org.jbrain.qlink.cmd.action;

import org.jbrain.qlink.cmd.CRCException;

/** F2 = first/next block of an uploaded file, F3 = last block (client to server). */
public class UploadData extends AbstractAction {
  public static final String MNEMONIC_NEXT = "F2";
  public static final String MNEMONIC_LAST = "F3";
  private byte[] _data;
  private boolean _bLast;

  public UploadData(byte[] data, int start, int len) throws CRCException {
    super(data, start, len);
    int n = Math.max(0, len - 10);
    _data = new byte[n];
    System.arraycopy(data, start + 10, _data, 0, n);
    _bLast = MNEMONIC_LAST.equals(getAction());
  }

  public byte[] getData() {
    return _data;
  }

  public boolean isLast() {
    return _bLast;
  }
}
JAVA_EOF
cat > $J/cmd/action/UploadDescLastLine.java <<'JAVA_EOF'
package org.jbrain.qlink.cmd.action;

import org.jbrain.qlink.cmd.CRCException;

/** KL: last line of a file upload description (client to server). */
public class UploadDescLastLine extends AbstractStringAction {
  public static final String MNEMONIC = "KL";

  public UploadDescLastLine(byte[] data, int start, int len) throws CRCException {
    super(data, start, len);
  }
}
JAVA_EOF
cat > $J/state/UploadFile.java <<'JAVA_EOF'
package org.jbrain.qlink.state;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.apache.log4j.Logger;
import org.jbrain.qlink.QSession;
import org.jbrain.qlink.cmd.action.*;
import org.jbrain.qlink.db.DBUtils;

/**
 * Receives a file uploaded from the C64 client and stores it as a download in the menu
 * that held the "Submit a New File" (type 0x8D) item.
 *
 * Flow seen from the client: K5 (filename) -> server KH -> K6..KL (description)
 * -> server KR -> FO -> F2... -> F3.
 */
public class UploadFile extends AbstractState {
  private static Logger _log = Logger.getLogger(UploadFile.class);
  private static final int ESCAPE = 0x5D;
  private static final int ESCAPE_XOR = 0x55;

  private QState _state;
  private int _iMenuID;
  private int _iFileID = -1;
  private String _sName;
  private StringBuffer _sbDesc = new StringBuffer();
  private ByteArrayOutputStream _data = new ByteArrayOutputStream();
  private boolean _bEscape = false;
  private int _iBlocks = 0;

  public UploadFile(QSession session, int menuID, String name) {
    super(session);
    _iMenuID = menuID;
    _sName = name;
    _log.debug("Starting UploadFile into menu " + menuID + ", filename from request: " + name);
  }

  public void activate() throws IOException {
    _state = _session.getState();
    super.activate();
    _session.send(new InitPosting(_session.getHandle().toString()));
  }

  public boolean execute(Action a) throws IOException {
    boolean rc = false;

    if (a instanceof NextPostingLine) {
      rc = true;
      String text = ((NextPostingLine) a).getData();
      _log.debug("Upload description: " + text);
      _sbDesc.append(text);
    } else if (a instanceof UploadDescLastLine || a instanceof LastPostingLine) {
      rc = true;
      String text = (a instanceof UploadDescLastLine)
          ? ((UploadDescLastLine) a).getData()
          : ((LastPostingLine) a).getData();
      _log.debug("Upload description end: " + text);
      _sbDesc.append(text);
      readyForUpload();
    } else if (_iFileID >= 0 && !_bVerified
        && (a instanceof StartDownload || a instanceof UnknownAction)) {
      // After KR the client searches its disk, then asks the host to verify the file
      // ("Please wait for verification"). Answer so it goes on to send the data.
      rc = true;
      _bVerified = true;
      _log.info("Upload verify request from client: " + a + " (" + a.getAction() + ")");
      sendVerifyReply();
    } else if (a instanceof StartDownload) {
      rc = true;
      _log.info("Client sent FO again during upload");
    } else if (a instanceof UploadData) {
      rc = true;
      UploadData d = (UploadData) a;
      addData(d.getData());
      _iBlocks++;
      _log.debug("Upload block " + _iBlocks + " (" + d.getData().length + " raw bytes), total "
          + _data.size() + " bytes" + (d.isLast() ? ", LAST" : ""));
      if (d.isLast()) finish();
    } else if (a instanceof UploadAbort || a instanceof AbortPosting || a instanceof AbortDownload) {
      rc = true;
      _log.debug("Upload canceled by client");
      cleanup();
      _session.setState(_state);
    }
    if (!rc) rc = super.execute(a);
    return rc;
  }

  private boolean _bVerified = false;

  // Reply to the verify request. Default: FD with a question. Override for testing with
  // /opt/qlink/upload-verify.txt, one line: MNEMONIC [parameter text], e.g.  FD Send this file?
  private void sendVerifyReply() throws IOException {
    String mnemonic = "FD";
    String param = "Ready to receive " + (_sName == null ? "file" : _sName) + ". Send it?";
    try {
      java.io.BufferedReader r =
          new java.io.BufferedReader(new java.io.FileReader("/opt/qlink/upload-verify.txt"));
      String line = r.readLine();
      r.close();
      if (line != null && line.trim().length() >= 2) {
        line = line.trim();
        mnemonic = line.substring(0, 2);
        param = line.length() > 3 ? line.substring(3) : "";
      }
    } catch (IOException e) {
    }
    _log.info("Sending verify reply " + mnemonic + " [" + param + "]");
    _session.send(new AbstractStringAction(mnemonic, param));
  }

  private void addData(byte[] b) {
    for (int i = 0; i < b.length; i++) {
      int c = b[i] & 0xff;
      if (_bEscape) {
        _data.write(c ^ ESCAPE_XOR);
        _bEscape = false;
      } else if (c == ESCAPE) {
        _bEscape = true;
      } else {
        _data.write(c);
      }
    }
  }

  private void readyForUpload() throws IOException {
    String desc = _sbDesc.toString();
    // Header looks like: "FILE: test      FROM: Ray61  10/24  S#: " then 0x7f, then the text
    Matcher m = Pattern.compile("FILE:\\s*(.*?)\\s*FROM:").matcher(desc);
    if (!m.find()) m = Pattern.compile("FILE:\\s*(\\S.*?)\\s{2,}").matcher(desc);
    else m.reset();
    if (m.find()) _sName = m.group(1).trim();
    if (_sName == null || _sName.length() == 0) _sName = "upload";
    _iFileID = DBUtils.getNextID(_iMenuID, MenuItem.DOWNLOAD, 0x7fffff);
    // What to send with KR is still being worked out. Pick with:
    //   echo name > /opt/qlink/upload-kr.txt   (shown as S#)
    //   echo id   > /opt/qlink/upload-kr.txt   (default: the new file ID, shown as S# on the C64)
    //   echo none > /opt/qlink/upload-kr.txt   (nothing)
    //   anything else is sent literally, with {name} and {id} replaced
    String mode = "id";
    try {
      java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader("/opt/qlink/upload-kr.txt"));
      String line = r.readLine();
      r.close();
      if (line != null && line.trim().length() > 0) mode = line.trim();
    } catch (IOException e) {
    }
    String param;
    if (mode.equals("name")) param = _sName;
    else if (mode.equals("id")) param = Integer.toString(_iFileID);
    else if (mode.equals("none")) param = "";
    else param = mode.replace("{name}", _sName).replace("{id}", Integer.toString(_iFileID));
    _log.info("Reserved ID " + _iFileID + " for upload '" + _sName + "'; sending KR with [" + param
        + "] (mode " + mode + ")");
    _session.send(new ReadyForUpload(param));
  }

  private void finish() throws IOException {
    String desc = _sbDesc.toString();
    int i = desc.indexOf(0x7f);
    String body = (i >= 0 ? desc.substring(i + 1) : desc).replace((char) 0x7f, '\n').trim();
    String name = _sName.toLowerCase();
    if (name.length() > 16) name = name.substring(0, 16);
    String title = _sName.length() > 36 ? _sName.substring(0, 36) : _sName;
    String type = name.endsWith(".seq") ? "seq" : "prg";
    byte[] data = _data.toByteArray();

    Connection conn = null;
    PreparedStatement ps = null;
    try {
      conn = DBUtils.getConnection();
      ps = conn.prepareStatement(
          "INSERT INTO toc (menu_id, reference_id, title, sort_order, active, create_date, last_update)"
              + " VALUES (?, ?, ?, 1, 'Y', NOW(), NOW())");
      ps.setInt(1, _iMenuID);
      ps.setInt(2, _iFileID);
      ps.setString(3, title);
      ps.execute();
      ps.close();
      ps = conn.prepareStatement(
          "INSERT INTO files (reference_id, name, filetype, description, data) VALUES (?, ?, ?, ?, ?)");
      ps.setInt(1, _iFileID);
      ps.setString(2, name);
      ps.setString(3, type);
      ps.setString(4, body + "\n\nUploaded by " + _session.getHandle());
      ps.setBytes(5, data);
      ps.execute();
      _log.info("Saved upload '" + name + "' (" + data.length + " bytes) as ID " + _iFileID
          + " in menu " + _iMenuID);
    } catch (SQLException e) {
      _log.error("SQL Exception saving upload", e);
    } finally {
      DBUtils.close(ps);
      DBUtils.close(conn);
    }
    _session.setState(_state);
  }

  private void cleanup() {
    if (_iFileID < 0) return;
    Connection conn = null;
    PreparedStatement ps = null;
    try {
      conn = DBUtils.getConnection();
      ps = conn.prepareStatement("DELETE FROM entry_types WHERE reference_id=?");
      ps.setInt(1, _iFileID);
      ps.execute();
    } catch (SQLException e) {
      _log.error("SQL Exception cleaning up upload", e);
    } finally {
      DBUtils.close(ps);
      DBUtils.close(conn);
    }
  }
}
JAVA_EOF
cat > /tmp/qlink-patch.py <<'PY_EOF'
import sys, re
root = sys.argv[1] + "/src/main/java/org/jbrain/qlink/"

# 1. Teach the command parser the upload commands
p = root + "cmd/action/ActionFactory.java"
s = open(p, newline="").read(); nl = "\r\n" if "\r\n" in s else "\n"; s = s.replace("\r\n", "\n")
if "UploadDescLastLine" not in s:
    add = '''    if (action.equals(UploadDescLastLine.MNEMONIC)) {
      return new UploadDescLastLine(b, start, len);
    }
    if (action.equals(UploadData.MNEMONIC_NEXT) || action.equals(UploadData.MNEMONIC_LAST)) {
      return new UploadData(b, start, len);
    }
    if (action.equals(UploadAbort.MNEMONIC)) {
      return new UploadAbort(b, start, len);
    }

    return new UnknownAction(b, start, len);'''
    assert s.count("    return new UnknownAction(b, start, len);") == 1
    s = s.replace("    return new UnknownAction(b, start, len);", add)
    open(p, "w", newline="").write(s.replace("\n", nl))
    print("patched ActionFactory")

# 2. Send "Submit a New File" (type 0x8D) items to the upload handler
p = root + "state/DepartmentMenu.java"
s = open(p, newline="").read(); nl = "\r\n" if "\r\n" in s else "\n"; s = s.replace("\r\n", "\n")
if "UploadFile" not in s:
    old = '''        bid = ((MenuEntry) _alMenu.get(index)).getID();
      }
      state = new PostMessage(_session, bid, pid, _iNextMessageID);
      state.activate();'''
    new = '''        bid = ((MenuEntry) _alMenu.get(index)).getID();
        if (((MenuEntry) _alMenu.get(index)).getType() == MenuItem.UPLOAD) {
          _log.debug("User requests a file upload into menu " + _iCurrMenuID);
          bid = -1;
        }
      }
      if (bid == -1) state = new UploadFile(_session, _iCurrMenuID, null);
      else state = new PostMessage(_session, bid, pid, _iNextMessageID);
      state.activate();'''
    assert s.count(old) == 1, "DepartmentMenu code not as expected"
    s = s.replace(old, new)
    open(p, "w", newline="").write(s.replace("\n", nl))
    print("patched DepartmentMenu")
PY_EOF
python3 /tmp/qlink-patch.py $Q
rm -f /tmp/qlink-patch.py

echo "==> Rebuilding (a few minutes)"
cd $Q
if ! mvn -q -o package 2>/tmp/qlink-build.log && ! mvn -q package 2>>/tmp/qlink-build.log; then
    echo "BUILD FAILED. Server left as it was. Last lines of the error:"
    grep -E "ERROR" /tmp/qlink-build.log | head -20
    exit 1
fi
chown -R qlink:qlink $Q
systemctl restart qlink
sleep 5
echo
echo "Done. Upload support installed and server restarted."
echo "Watch it live while you upload:  journalctl -u qlink -f | grep -iE 'upload|Received org'"
