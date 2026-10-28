package org.jbrain.qlink.cmd.action;

import org.jbrain.qlink.cmd.CRCException;

/** FK: client canceled the upload. */
public class UploadAbort extends AbstractAction {
  public static final String MNEMONIC = "FK";

  public UploadAbort(byte[] data, int start, int len) throws CRCException {
    super(data, start, len);
  }
}
