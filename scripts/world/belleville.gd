class_name Belleville
extends RefCounted

# Shared palette for the "Triplets of Belleville" look — a vintage, hand-drawn,
# sepia/ochre/olive aesthetic (aged paper, ink lines, retro-1950s mood). It's
# the game's single visual style; every system that paints the world (terrain,
# sky, rider, scenery, HUD) pulls these exact colors so the game matches the
# website theme, which uses the same hexes.
#
# A style homage: palette, linework, caricature, retro mood — not the film's
# specific characters or assets.

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
