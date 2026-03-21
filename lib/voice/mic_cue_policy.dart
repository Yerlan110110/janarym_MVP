enum MicCueEvent {
  wakeAccepted,
  startupArm,
  commandListeningStarted,
  commandListeningStopped,
  followUpStart,
  routeConfirmationStart,
  directFallbackStart,
  uiPanelOpened,
  uiPanelClosed,
  manualStop,
  voiceEnrollmentAction,
}

bool shouldPlayMicCue(MicCueEvent event) {
  return event == MicCueEvent.wakeAccepted;
}
