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
