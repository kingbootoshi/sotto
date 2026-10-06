from sotto.hotkey import ComboTracker, parse_key
from sotto.statemachine import TapHold


def test_quick_tap_toggles_until_second_tap():
    sm = TapHold(0.5)
    assert sm.down(0.0) == "start"
    assert sm.up(0.1) is None
    assert sm.down(3.0) == "stop"
    assert sm.up(3.1) is None
    assert not sm.recording


def test_hold_is_push_to_talk():
    sm = TapHold(0.5)
    assert sm.down(0.0) == "start"
    assert sm.up(2.0) == "stop"


def test_esc_cancels_only_while_recording():
    sm = TapHold(0.5)
    assert sm.esc() is None
    sm.down(0); sm.up(0.1)
    assert sm.esc() == "cancel"
    assert sm.down(1) == "start"


def test_combo_edges():
    c = ComboTracker(["rmenu", "rcontrol"])
    assert c.feed(0xA5, 0, True) == (True, None)
    assert c.feed(0xA5, 0, True) == (True, None)  # autorepeat
    assert c.feed(0xA3, 0, True) == (True, "down")
    assert c.feed(0x41, 0, True) == (False, None)
    assert c.feed(0xA3, 0, False) == (True, "up")


def test_single_key_and_scancode():
    c = ComboTracker(["rmenu"])
    assert c.feed(0xA5, 0x38, True)[1] == "down"
    assert c.feed(0xA5, 0x38, False)[1] == "up"
    assert parse_key("sc:0xE063") == ("sc", 0xE063)
