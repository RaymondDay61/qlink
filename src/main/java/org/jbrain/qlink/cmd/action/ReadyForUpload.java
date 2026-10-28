package org.jbrain.qlink.cmd.action;

/** KR from server: ready to receive the uploaded file. Parameter is copied by the client to $CE00. */
public class ReadyForUpload extends AbstractStringAction {
  public ReadyForUpload(String data) {
    super("KR", data);
  }
}
