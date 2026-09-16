{
  hardware.bluetooth = {
    enable = true;
    settings.General = {
      # Allows simultaneous media audio and microphone usage on headsets
      MultiProfile = "multiple";
      # Faster reconnect times for sleeping wireless devices
      FastConnectable = true;
      # Enables LE privacy features to prevent local tracking
      Privacy = "device";
    };
  };
}
