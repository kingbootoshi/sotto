"""Tap-to-toggle / hold-to-talk state machine. Pure logic, no I/O."""


class TapHold:
    """Feed hotkey edges; returns an action string or None.

    Actions: 'start', 'stop', 'cancel'.
    - idle + down              -> start
    - recording + down         -> stop   (second tap of a toggle)
    - recording + up after hold>=threshold -> stop (push-to-talk release)
    - recording + esc          -> cancel
    """

    def __init__(self, hold_threshold=0.5):
        self.hold = hold_threshold
        self.recording = False
        self.down_at = None
        self.started_by_this_press = False

    def down(self, t):
        if not self.recording:
            self.recording = True
            self.down_at = t
            self.started_by_this_press = True
            return "start"
        self.recording = False
        self.started_by_this_press = False
        return "stop"

    def up(self, t):
        if not (self.recording and self.started_by_this_press):
            return None
        self.started_by_this_press = False
        if t - self.down_at >= self.hold:
            self.recording = False
            return "stop"
        return None  # quick tap: keep recording until next tap

    def esc(self):
        if not self.recording:
            return None
        self.recording = False
        self.started_by_this_press = False
        return "cancel"

    def force_idle(self):
        self.recording = False
        self.started_by_this_press = False
