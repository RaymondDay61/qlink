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
