package org.jbrain.qlink.cmd.action;

import org.jbrain.qlink.cmd.CRCException;

/** KL: last line of a file upload description (client to server). */
public class UploadDescLastLine extends AbstractStringAction {
  public static final String MNEMONIC = "KL";

  public UploadDescLastLine(byte[] data, int start, int len) throws CRCException {
    super(data, start, len);
  }
}
