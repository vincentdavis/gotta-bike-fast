class_name MenuTheme
extends RefCounted

# Palette + Theme for the in-game menu, matching the website's "belleville"
# DaisyUI theme: aged paper surfaces, ink text, terracotta primary. The web and
# game share these exact hexes (see scripts/world/belleville.gd for the
# world-side palette). build() returns a Theme assigned to the menu root so the
# whole tabbed UI inherits the look; the colour constants are used for the few
# inline text colours that need to be semantic (status, links, errors).

const PAGE := Color("e3d8bc")           # base-200 — page background
const SURFACE := Color("eae2cc")        # base-100 — cards / inputs / buttons
const SURFACE_ALT := Color("d6c9a8")    # base-300 — hover / darker surface
const INK := Color("2e2a24")            # base-content — text
const INK_MUTED := Color(0.180, 0.165, 0.141, 0.62)  # muted ink (secondary text)
const PRIMARY := Color("a85a3c")        # terracotta — primary action
const PRIMARY_CONTENT := Color("f3e9d2")  # cream — text on primary
const SECONDARY := Color("44605e")      # smoky teal
const ACCENT := Color("c8a86a")         # ochre
const SUCCESS := Color("6f7a4e")        # olive
const WARNING := Color("9c7b3e")        # mustard
const ERROR := Color("8c4a33")          # burnt red
const BORDER := Color(0.180, 0.165, 0.141, 0.20)  # ink line


static func _box(
	bg: Color, radius: int = 4, border: int = 0, border_col: Color = BORDER,
	pad_h: int = 10, pad_v: int = 6
) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	if border > 0:
		s.border_width_left = border
		s.border_width_right = border
		s.border_width_top = border
		s.border_width_bottom = border
		s.border_color = border_col
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	return s


# Terracotta CTA — apply to the few primary actions (Solo Ride, Sign in).
static func primary_button_style(btn: Button) -> void:
	btn.add_theme_stylebox_override("normal", _box(PRIMARY, 4, 0, BORDER, 16, 12))
	btn.add_theme_stylebox_override("hover", _box(PRIMARY.lightened(0.07), 4, 0, BORDER, 16, 12))
	btn.add_theme_stylebox_override("pressed", _box(PRIMARY.darkened(0.10), 4, 0, BORDER, 16, 12))
	btn.add_theme_stylebox_override("disabled", _box(Color(PRIMARY, 0.45), 4, 0, BORDER, 16, 12))
	btn.add_theme_color_override("font_color", PRIMARY_CONTENT)
	btn.add_theme_color_override("font_hover_color", PRIMARY_CONTENT)
	btn.add_theme_color_override("font_pressed_color", PRIMARY_CONTENT)
	btn.add_theme_color_override("font_disabled_color", Color(PRIMARY_CONTENT, 0.7))


# Flat text link in terracotta.
static func link_button_style(btn: Button) -> void:
	btn.add_theme_color_override("font_color", PRIMARY)
	btn.add_theme_color_override("font_hover_color", PRIMARY.darkened(0.12))
	btn.add_theme_color_override("font_pressed_color", PRIMARY.darkened(0.20))
	btn.add_theme_color_override("font_focus_color", PRIMARY)


static func build() -> Theme:
	var t := Theme.new()

	# Text
	t.set_color("font_color", "Label", INK)

	# Default button — paper surface, ink line, ink text.
	t.set_stylebox("normal", "Button", _box(SURFACE, 4, 1))
	t.set_stylebox("hover", "Button", _box(SURFACE_ALT, 4, 1))
	t.set_stylebox("pressed", "Button", _box(SURFACE_ALT, 4, 1))
	t.set_stylebox("disabled", "Button", _box(Color(SURFACE, 0.5), 4, 1, Color(BORDER, 0.5)))
	t.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), 4, 1, PRIMARY))
	t.set_color("font_color", "Button", INK)
	t.set_color("font_hover_color", "Button", INK)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_focus_color", "Button", INK)
	t.set_color("font_disabled_color", "Button", Color(INK, 0.40))

	# Text inputs
	t.set_stylebox("normal", "LineEdit", _box(SURFACE, 4, 1, BORDER, 10, 8))
	t.set_stylebox("focus", "LineEdit", _box(SURFACE, 4, 1, PRIMARY, 10, 8))
	t.set_color("font_color", "LineEdit", INK)
	t.set_color("font_placeholder_color", "LineEdit", Color(INK, 0.45))
	t.set_color("caret_color", "LineEdit", INK)
	t.set_color("font_selected_color", "LineEdit", PRIMARY_CONTENT)
	t.set_color("selection_color", "LineEdit", Color(PRIMARY, 0.85))

	# Cards / panels
	var card := _box(SURFACE, 5, 1, BORDER, 0, 0)
	t.set_stylebox("panel", "PanelContainer", card)
	t.set_stylebox("panel", "Panel", card)

	# Tabs
	t.set_stylebox("panel", "TabContainer", _box(SURFACE, 5, 1, BORDER, 0, 0))
	t.set_stylebox("tabbar_background", "TabContainer", _box(Color(0, 0, 0, 0), 0))
	t.set_stylebox("tab_selected", "TabContainer", _box(SURFACE, 4, 1, BORDER, 14, 8))
	t.set_stylebox("tab_unselected", "TabContainer", _box(Color(0, 0, 0, 0), 4, 0, BORDER, 14, 8))
	t.set_stylebox("tab_hovered", "TabContainer", _box(Color(SURFACE, 0.55), 4, 0, BORDER, 14, 8))
	t.set_color("font_selected_color", "TabContainer", PRIMARY)
	t.set_color("font_unselected_color", "TabContainer", INK_MUTED)
	t.set_color("font_hovered_color", "TabContainer", INK)

	# Scrollbars — visible grabber on a light background.
	for sb in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb, _box(Color(INK, 0.06), 3))
		t.set_stylebox("grabber", sb, _box(Color(INK, 0.28), 3))
		t.set_stylebox("grabber_highlight", sb, _box(Color(INK, 0.45), 3))
		t.set_stylebox("grabber_pressed", sb, _box(Color(INK, 0.55), 3))

	return t
