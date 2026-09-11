module panerule

// THE PERSISTED DIVIDER, AS A RULE. Six panes keep a dragged height or width across frames —
// the System panel's ECU panes, Discover's interface list, the Script editor, and the DBC
// editor's messages box, properties region and left pane — and the decision "how tall is it
// THIS frame, and what does a drag change" had been written per pane, in two shapes. One of
// them was codex #305 r2's finding on the System panel: the clamp ran AFTER the panes had taken
// the stored height, so a dock shorter than that left the section below a few pixels; and the
// clamp was written back, so one frame in a short slot collapsed the pane for good. The DBC
// editor's three still had that shape. Here it is once, pure, with the scenario as its test.
//
// The stored value is UNSCALED px (a UI-scale change keeps the proportion) and 0 means unset.
// V passes scalars by value, so each rule RETURNS the stored value; the caller keeps it.

// drawn is the pane's extent for this frame and the stored value after seeding: `stored`, or
// `dflt` when unset, scaled by `sc` and clamped to [min_px, max_px] — asked BEFORE the pane is
// drawn, from what the container has now, so a short dock reclaims the room in the same
// frame. When max_px is below min_px (a very short dock) the minimum wins, as the splitter
// widget itself floors its max at its min. The clamp is NOT in the returned stored value: see
// dragged.
pub fn drawn(stored f32, dflt f32, sc f32, min_px f32, max_px f32) (f32, f32) {
	kept := if stored <= 0 { dflt } else { stored }
	want := kept * sc
	hi := if max_px > min_px { max_px } else { min_px }
	if want > hi {
		return hi, kept
	}
	if want < min_px {
		return min_px, kept
	}
	return want, kept
}

// dragged is the stored value after the splitter answered `moved` for a pane drawn at
// `drawn_px`: a DRAG (moved differs from what was drawn) persists, unscaled; anything else —
// including every frame a short dock clamps the pane below what is stored — keeps what the
// operator last chose, so the pane comes back when the room does.
pub fn dragged(stored f32, drawn_px f32, moved f32, sc f32) f32 {
	if moved != drawn_px {
		return moved / sc
	}
	return stored
}
