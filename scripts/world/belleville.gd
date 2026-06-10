class_name Belleville
extends RefCounted

# Shared palette + theme switch for the "Triplets of Belleville" visual theme —
# a vintage, hand-drawn, sepia/ochre/olive look (aged paper, ink lines,
# retro-1950s mood). Every system that recolors for the theme (terrain, sky,
# rider, scenery, HUD) pulls these exact colors so the game matches the website
# theme, which uses the same hexes.
#
# The look is a style homage: palette, linework, caricature, retro mood — not
# the film's specific characters or assets.
#
# is_active() is the single switch the visual code branches on; it reads the
# persisted GraphicsSettings.theme so the choice survives restarts and applies
# on the next ride.

const PAPER := Color("e3d8bc")       # parchment — light surfaces, sky horizon
const PAPER_LIGHT := Color("eae2cc")
const PAPER_DARK := Color("d6c9a8")
const INK := Color("2e2a24")         # near-black contour / text
const OCHRE := Color("c8a86a")       # warm accent, hazy sun
const BRONZE := Color("9c7b3e")      # mustard / dry grass
const OLIVE := Color("6f7a4e")       # grass / foliage
const TEAL := Color("44605e")        # smoky shadow / distance
const TERRACOTTA := Color("a85a3c")  # primary accent (jersey, brick)
const SAGE := Color("8fa08c")        # faded sky / haze
const UMBER := Color("5a4a33")       # shadow brown, trunks


const _GS_SCRIPT := preload("res://scripts/graphics_settings.gd")


static func is_active() -> bool:
	# Look the GraphicsSettings autoload up by node path rather than the global
	# identifier, so this also resolves in standalone --script render harnesses
	# (where autoload globals aren't bound at compile time). The enum value is
	# read off the preloaded script so it stays in sync with the source.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return false
	var gs := tree.root.get_node_or_null("GraphicsSettings")
	if gs == null:
		return false
	return int(gs.theme) == _GS_SCRIPT.VisualTheme.BELLEVILLE
