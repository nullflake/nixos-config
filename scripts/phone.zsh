phone() {
  local pin="$1"
  shift 2>/dev/null

  adb shell input keyevent 26 82 && \
  sleep 0.3 && \
  adb shell input text "$pin" && \
  adb shell input keyevent 66 && \
  nohup scrcpy --turn-screen-off --stay-awake "$@" &> /dev/null & disown
}
